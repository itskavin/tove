import 'dart:async';

import 'package:flutter/widgets.dart';

import '../chat/chat_api.dart';
import '../chat/chat_errors.dart';
import '../chat/models.dart';
import 'background_replies.dart' show defaultReplyBackoff;
import 'reply_task.dart';

/// Follows the live-call tasks of the chat on screen (API.md "Live tasks in
/// the chat", capability `task_messages`).
///
/// The bridge writes a task delegated in a linked call into its chat as an
/// assistant message (`source: task`, `status: streaming`) from the moment it
/// starts, and streams it like a reply. This follows such messages with
/// `GET /api/chat/{id}/stream` (resuming with `Last-Event-ID` after a drop),
/// so the thread's work line and the Tasks panel show its steps and text
/// while it runs, during the call, after it and after an app restart.
///
/// Unlike typed replies (`BackgroundReplies`) there can be several per chat,
/// they never block sending, and they are only followed while their chat is
/// on screen and the app is visible: elsewhere the events stream (or a push)
/// announces the end, and the chat shows the saved result when opened.
class TaskStreams extends ChangeNotifier {
  TaskStreams({
    required this.api,
    this.backoff = defaultReplyBackoff,
    this.giveUpAfter = const Duration(minutes: 20),
    this.keepFinished = 16,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final ChatApi api;
  final Duration Function(int attempt) backoff;

  /// After this long without getting the stream back, stop trying (the
  /// chat's next refresh shows the saved state).
  final Duration giveUpAfter;
  final int keepFinished;
  final DateTime Function() _now;

  final Map<String, ReplyTask> _active = {};
  final List<ReplyTask> _recent = [];
  final _finished = StreamController<ReplyTask>.broadcast();
  String? _focus;
  bool _foreground = true;
  bool _disposed = false;
  AppLifecycleListener? _lifecycle;

  /// Tasks being followed now.
  Iterable<ReplyTask> get active => _active.values;

  /// Each followed task once, when it reaches its end.
  Stream<ReplyTask> get finished => _finished.stream;

  bool get foreground => _foreground;

  /// The task following [messageId] (running, or finished this session).
  ReplyTask? byMessage(String? messageId) {
    if (messageId == null) return null;
    final a = _active[messageId];
    if (a != null) return a;
    for (final t in _recent.reversed) {
      if (t.messageId == messageId) return t;
    }
    return null;
  }

  /// Follows every streaming task message in [messages] of the chat
  /// [conversationId] (which becomes the focus: tasks of other chats are
  /// let go; they keep running on the bridge).
  void sync(String? conversationId, Iterable<ChatMessage> messages) {
    if (_disposed) return;
    focus(conversationId);
    if (conversationId == null) return;
    for (final m in messages) {
      if (m.isTask && m.isStreaming && !m.isLocal) follow(m);
    }
  }

  /// Only the chat on screen is followed.
  void focus(String? conversationId) {
    if (_focus == conversationId) return;
    _focus = conversationId;
    for (final t in List.of(_active.values)) {
      if (t.conversationId != conversationId) _drop(t);
    }
    notifyListeners();
  }

  /// Follows one streaming task message. Harmless when already followed.
  ReplyTask? follow(ChatMessage m) {
    if (_disposed || !m.isTask || !m.isStreaming) return null;
    final existing = _active[m.id];
    if (existing != null) return existing;
    final t = ReplyTask.internal(
      localId: 'task-${m.id}',
      api: api,
      created: m.created,
      conversationId: m.conversationId,
      messageId: m.id,
      seedText: m.text,
      resumed: true,
    );
    _active[m.id] = t;
    if (_foreground) _attach(t);
    notifyListeners();
    return t;
  }

  /// The message as the thread should show it: the server copy, with the
  /// live text, status and progress while this device follows it (and the
  /// final state until the chat is re-read).
  ChatMessage overlay(ChatMessage m) {
    if (!m.isTask || !m.isStreaming) return m;
    final t = byMessage(m.id);
    if (t == null) return m;
    final live = t.build(fallbackConversation: m.conversationId);
    return m.copyWith(
      text: live.text.length >= m.text.length || t.finished
          ? live.text
          : m.text,
      status: live.status,
      progress: live.progress,
      clearProgress: live.progress == null,
      error: live.error,
      meta: {
        ...m.meta,
        if (t.finished) 'seconds': _now().difference(m.created).inSeconds,
      },
    );
  }

  /// Stops a running task on the bridge (`POST /api/chat/{id}/stop`).
  Future<void> stop(String messageId) async {
    final t = _active[messageId];
    try {
      final r = await api.stopReply(messageId);
      if (t != null && !t.finished) {
        if (r.text != null) t.replaceText(r.text!);
        _finish(t, ReplyPhase.stopped, stopReason: 'user');
      }
    } on ChatException {
      // The next refresh shows how it ended.
    }
  }

  /// Follows the app lifecycle. Call once from the app (not in tests).
  void bindLifecycle() {
    _lifecycle ??= AppLifecycleListener(
      onStateChange: (s) => setForeground(
        s == AppLifecycleState.resumed || s == AppLifecycleState.inactive,
      ),
    );
  }

  /// Leaving the screen closes every reader, so the bridge knows nobody is
  /// watching and notifies; returning reconnects them at once.
  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    for (final t in List.of(_active.values)) {
      if (foreground) {
        t.attempt = 0;
        t.dropSince = null;
        _attach(t);
      } else {
        _detach(t);
        t.setPhase(ReplyPhase.reconnecting);
      }
    }
    notifyListeners();
  }

  // --- streams ---------------------------------------------------------------

  void _attach(ReplyTask t) {
    if (t.reader != null || t.finished || _disposed) return;
    final id = t.messageId!;
    final s = api.resume(id, lastEventId: t.lastEventId);
    t.reader = s;
    t.itemsSinceAttach = 0;
    t.subscription = s.items.listen(
      (item) => _onItem(t, s, item),
      onError: (Object e) =>
          _onDrop(t, s, e is ChatException ? e : ChatException.network),
    );
  }

  void _detach(ReplyTask t) {
    t.retryTimer?.cancel();
    t.retryTimer = null;
    final r = t.reader;
    t.reader = null;
    t.subscription?.cancel().ignore();
    t.subscription = null;
    r?.cancel();
  }

  void _drop(ReplyTask t) {
    _detach(t);
    _active.remove(t.messageId);
  }

  void _onItem(ReplyTask t, ChatStream s, ChatStreamItem item) {
    if (!identical(t.reader, s) || t.finished) return;
    final e = item.event;
    final id = item.id;
    t.itemsSinceAttach++;
    if (id != null &&
        e is! ChatSnapshotEvent &&
        t.lastEventId != null &&
        id <= t.lastEventId!) {
      return;
    }
    if (id != null) t.noteEventId(id);
    if (t.phase != ReplyPhase.streaming) {
      t.setPhase(ReplyPhase.streaming);
      t.attempt = 0;
      t.dropSince = null;
    }
    final now = _now();
    switch (e) {
      case ChatMetaEvent():
        t.applyMeta(e);
      case ChatDeltaEvent():
        t.appendText(e.text);
      case ChatProgressEvent():
        t.setProgress(e.progress);
        t.tools.record(e.progress, t.text.length, now);
      case ChatStepEvent():
        t.steps.start(e.step);
      case ChatStepDeltaEvent():
        t.steps.delta(e.id, e.text);
      case ChatSnapshotEvent():
        t.replaceText(e.text);
        if (e.lastStatus != null) t.setProgress(e.lastStatus);
        if (e.steps != null) t.steps.replaceAll(e.steps!);
      case ChatDoneEvent():
        _finish(t, ReplyPhase.done, done: e);
        return;
      case ChatFailedEvent():
        _finish(
          t,
          e.error.code == 'interrupted'
              ? ReplyPhase.interrupted
              : ReplyPhase.failed,
          error: e.error,
        );
        return;
      case ChatStoppedEvent():
        _finish(t, ReplyPhase.stopped, stopReason: e.reason ?? 'user');
        return;
    }
    notifyListeners();
  }

  void _onDrop(ReplyTask t, ChatStream s, ChatException e) {
    if (!identical(t.reader, s) || t.finished) return;
    t.reader = null;
    t.subscription = null;
    final http = e.status;
    if (http == 404 || http == 401) {
      // Deleted (or the key changed): nothing to follow any more.
      _drop(t);
      notifyListeners();
      return;
    }
    if (http == 400) t.resetEventId();
    if (!_foreground) return; // Reconnects on return.
    final now = _now();
    t.dropSince ??= now;
    if (now.difference(t.dropSince!) > giveUpAfter) {
      _drop(t);
      notifyListeners();
      return;
    }
    t.setPhase(ReplyPhase.reconnecting);
    t.retryTimer?.cancel();
    t.retryTimer = Timer(backoff(t.attempt++), () {
      t.retryTimer = null;
      if (_foreground && _active.containsKey(t.messageId)) _attach(t);
    });
    notifyListeners();
  }

  void _finish(
    ReplyTask t,
    ReplyPhase phase, {
    ChatException? error,
    ChatDoneEvent? done,
    String? stopReason,
  }) {
    _detach(t);
    final now = _now();
    t.tools.finish(now, failed: phase != ReplyPhase.done);
    t.steps.finish(now, failed: phase != ReplyPhase.done);
    if (!t.finish(phase, error: error, done: done, stopReason: stopReason)) {
      return;
    }
    _active.remove(t.messageId);
    _recent.add(t);
    while (_recent.length > keepFinished) {
      _recent.removeAt(0);
    }
    if (!_finished.isClosed) _finished.add(t);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _lifecycle?.dispose();
    for (final t in _active.values) {
      _detach(t);
    }
    _active.clear();
    _finished.close();
    super.dispose();
  }
}
