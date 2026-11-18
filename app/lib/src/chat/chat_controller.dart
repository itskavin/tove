import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../background/background_replies.dart';
import '../background/task_streams.dart';
import 'chat_api.dart';
import 'chat_errors.dart';
import 'conversations_controller.dart';
import 'fork.dart';
import 'models.dart';
import 'voice_turns.dart';
import 'steps.dart';
import 'throttle.dart';
import 'tool_calls.dart';

/// The current thread: messages, the streaming reply, send / stop / retry,
/// live-call linking and transcript import. UI-agnostic.
///
/// Replies belong to [replies] (`BackgroundReplies`), not to this
/// controller: opening another chat, starting a new one, or the app going to
/// the background never cancels or fails a reply. It reappears, still
/// streaming or finished, when the user comes back to its chat. Only [stop]
/// stops a reply. A failure is reported in [error] only for the chat on
/// screen; a reply finishing elsewhere is announced by the notify module.
///
/// Notifications while a reply streams are throttled to one per
/// [notifyInterval] (about 30 per second by default); structural changes
/// (meta, done, error, stop) notify at once.
class ChatController extends ChangeNotifier {
  ChatController({
    required this.api,
    this.conversations,
    this.defaultEffort,
    BackgroundReplies? replies,
    TaskStreams? tasks,
    this.notifyInterval = const Duration(milliseconds: 33),
    this.titleRefreshDelay = const Duration(seconds: 6),
    this.pageSize = 50,
    String Function()? newClientId,
    DateTime Function()? now,
  }) : replies = replies ?? BackgroundReplies(now: now),
       _ownsReplies = replies == null,
       tasks = tasks ?? TaskStreams(api: api, now: now),
       _ownsTasks = tasks == null,
       _newClientId = newClientId ?? _randomClientId,
       _now = now ?? DateTime.now {
    _throttle = Throttle(notifyInterval, _notify);
    this.replies.addListener(_onReplyChange);
    this.tasks.addListener(_onTasksChange);
    _taskEnds = this.tasks.finished.listen(_onTaskFinished);
  }

  final ChatApi api;

  /// Kept in sync with new chats, titles and the current id, when given.
  final ConversationsController? conversations;

  /// The effort used when [send] gets none (the settings value).
  final ChatEffort? Function()? defaultEffort;

  /// Owns the replies. Pass `BackgroundReplies.instance` in the app; without
  /// one the controller makes a private manager and closes it on dispose.
  final BackgroundReplies replies;
  final bool _ownsReplies;

  /// Follows the chat's live-call tasks while they run (capability
  /// `task_messages`): they are chat messages from their start.
  final TaskStreams tasks;
  final bool _ownsTasks;
  late final StreamSubscription<ReplyTask> _taskEnds;
  final Duration notifyInterval;

  /// How long after `done` with `title_pending` the chat is re-read.
  final Duration titleRefreshDelay;

  /// Messages per page when opening a chat or loading older ones.
  final int pageSize;

  final String Function() _newClientId;
  final DateTime Function() _now;
  late final Throttle _throttle;

  Capabilities _caps = const Capabilities.liveOnly(known: false);
  Conversation? _conversation;
  final List<ChatMessage> _messages = [];
  bool _hasOlder = false;
  bool _loading = false;
  bool _loadingOlder = false;
  ChatException? _error;
  int _epoch = 0;
  int _localSeq = 0;
  bool _disposed = false;
  final List<Timer> _timers = [];

  /// A reply sent from a new (not yet created) chat, and the epoch it was
  /// sent in: it is "this chat" until meta names the conversation.
  ReplyTask? _pending;
  int _pendingEpoch = -1;

  /// The optimistic user message of each task sent from here.
  final Map<ReplyTask, String> _userLocal = {};
  final Expando<bool> _handled = Expando();

  /// Tool calls of finished replies, by message id, for this session only
  /// (the bridge does not persist them yet; see bridge-requests.md).
  final Map<String, List<ToolCall>> _toolLog = {};

  /// The same for the bridge's steps (the stored copy arrives on reload).
  final Map<String, List<ReplyStep>> _stepLog = {};

  // --- state ---------------------------------------------------------------

  Capabilities get capabilities => _caps;

  /// `POST /api/chat` works.
  bool get textChatAvailable => _caps.chat;

  /// Chats are stored on the server. When false the thread is local only
  /// (live transcripts are still appended so they can be read after a call).
  bool get historyAvailable => _caps.history;
  bool get localOnly => !_caps.history;

  Conversation? get conversation => _conversation;
  String? get currentConversationId => _conversation?.id;
  String? get title => _conversation?.title;

  /// The in-flight reply shown in this thread, if any.
  ReplyTask? get _shown {
    final p = _pending;
    if (p != null && p.inFlight && _pendingEpoch == _epoch) return p;
    final t = replies.byConversation(_conversation?.id);
    return t != null && !t.stopAfterMeta ? t : null;
  }

  /// The task of the reply on screen (for "reconnecting" indicators).
  ReplyTask? get activeReply => _shown;

  /// The reply on screen is reconnecting after a drop or the background
  /// (it keeps running on the bridge). The thread can show a quiet
  /// "Reconnecting…" instead of an error.
  bool get reconnecting => _shown?.phase == ReplyPhase.reconnecting;

  /// Oldest first, including the streaming reply when it belongs here.
  /// Voice-turn fragments saved by older app versions are left out
  /// ([collapseVoiceFragments]).
  List<ChatMessage> get messages {
    final a = _shown;
    if (a == null) {
      return List.unmodifiable(
        collapseVoiceFragments([for (final m in _messages) tasks.overlay(m)]),
      );
    }
    final live = a.build(fallbackConversation: _conversation?.id);
    final out = <ChatMessage>[];
    var placed = false;
    for (final m in _messages) {
      if (a.messageId != null && m.id == a.messageId) {
        out.add(live);
        placed = true;
      } else {
        out.add(tasks.overlay(m));
      }
    }
    if (!placed) out.add(live);
    return List.unmodifiable(collapseVoiceFragments(out));
  }

  /// The reply being written in this thread, if any.
  ChatMessage? get streamingMessage =>
      _shown?.build(fallbackConversation: _conversation?.id);

  /// The Hermes tool calls made while writing [m], oldest first: live for
  /// a reply in flight (in any chat), kept in memory for replies finished
  /// this session, or read from a persisted `meta.tools` when the bridge
  /// sends one.
  List<ToolCall> toolCallsFor(ChatMessage m) {
    final a = _shown;
    if (a != null && (a.messageId ?? a.localId) == m.id) {
      return List.unmodifiable(a.tools.calls);
    }
    final t = replies.byMessage(m.id) ?? tasks.byMessage(m.id);
    if (t != null && t.inFlight) return List.unmodifiable(t.tools.calls);
    final kept = _toolLog[m.id];
    if (kept != null) return List.unmodifiable(kept);
    final stored = m.meta['tools'];
    if (stored is List) {
      return List.unmodifiable(stored.map(ToolCall.fromJson).nonNulls);
    }
    return const [];
  }

  void _keepTools(ReplyTask t) {
    if (!t.tools.isEmpty) {
      _toolLog[t.messageId ?? t.localId] = List.of(t.tools.calls);
    }
    if (!t.steps.isEmpty) {
      // A reply resumed after a restart only folded the steps after its
      // Last-Event-ID; the server copy read earlier holds the ones before.
      final id = t.messageId ?? t.localId;
      var stored = const <ReplyStep>[];
      for (final m in _messages) {
        if (m.id == id) {
          stored = stepsFromJson(m.meta['steps']);
          break;
        }
      }
      _stepLog[id] = mergeSteps(stored, List.of(t.steps.steps));
    }
  }

  /// The thinking and tool timeline of [m], oldest first (API.md "Steps").
  ///
  /// The one place where the two data sources meet: the bridge's steps (live
  /// `step.*` events, kept for replies finished this session, or a stored
  /// `meta.steps`), and for bridges without steps the tool calls rebuilt from
  /// `status` events and `meta.tools` ([stepsFromToolCalls]).
  List<ReplyStep> stepsFor(ChatMessage m) {
    final a = _shown;
    ReplyTask? live;
    if (a != null && (a.messageId ?? a.localId) == m.id) {
      live = a;
    } else {
      final t = replies.byMessage(m.id);
      if (t != null && t.inFlight) live = t;
      final task = tasks.byMessage(m.id);
      if (task != null && task.inFlight) live = task;
    }
    // A resumed reply's own list may lack the steps before its Last-Event-ID
    // (round 6 B1), so the stored `meta.steps` is always merged in.
    var stored = stepsFromJson(m.meta['steps']);
    if (stored.isEmpty && live != null) {
      // The streaming copy is built from the task; the server's copy (read
      // when the chat opened) holds what the bridge had saved by then.
      for (final s in _messages) {
        if (s.id == m.id) {
          stored = stepsFromJson(s.meta['steps']);
          break;
        }
      }
    }
    if (live != null && !live.steps.isEmpty) {
      return List.unmodifiable(mergeSteps(stored, live.steps.steps));
    }
    final kept = _stepLog[m.id];
    if (kept != null) return List.unmodifiable(mergeSteps(stored, kept));
    if (stored.isNotEmpty) return List.unmodifiable(stored);
    return List.unmodifiable(stepsFromToolCalls(toolCallsFor(m)));
  }

  /// A reply is streaming in this thread.
  bool get streaming => _shown != null;

  /// A reply is streaming in another chat.
  bool get streamingElsewhere =>
      replies.active.any((t) => !t.stopAfterMeta && !_visible(t));

  /// Chats (by id) with a reply in flight, for drawer indicators.
  Set<String> get streamingConversations => {
    for (final t in replies.active)
      if (t.conversationId != null && !t.stopAfterMeta) t.conversationId!,
  };

  /// Sending is possible: chat works, no reply runs in this thread, and the
  /// bridge's global reply limit (`concurrent_chats`) is not reached.
  bool get canSend =>
      _caps.chat && _shown == null && replies.active.length < _maxReplies;

  int get _maxReplies => max(1, _caps.limits.concurrentChats);

  /// Older messages can be loaded with [loadOlder].
  bool get hasOlder => _hasOlder;
  bool get loading => _loading;
  bool get loadingOlder => _loadingOlder;

  /// The latest failure, for a toast. Message failures also stay on the
  /// message ([ChatMessage.error]). Never set for a chat that is not on
  /// screen.
  ChatException? get error => _error;

  void clearError() {
    if (_error == null) return;
    _error = null;
    _notifyNow();
  }

  bool _visible(ReplyTask t) =>
      (identical(t, _pending) && _pendingEpoch == _epoch) ||
      (t.conversationId != null && t.conversationId == _conversation?.id);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _notifyNow() {
    if (!_disposed) _throttle.flush();
  }

  // --- setup and navigation ------------------------------------------------

  /// Reads capabilities and, when history exists, the first history page.
  Future<void> init() async {
    await refreshCapabilities();
    if (_caps.resumableStream) unawaited(replies.restore(api));
    if (_caps.history) await conversations?.refresh();
  }

  /// Re-reads `/api/capabilities`. A 401 is reported in [error]; a network
  /// failure leaves `capabilities.known` false so the app can retry.
  /// Calls made while a read is in flight share it.
  Future<Capabilities> refreshCapabilities() =>
      _capsRead ??= _readCapabilities().whenComplete(() => _capsRead = null);

  Future<Capabilities>? _capsRead;

  Future<Capabilities> _readCapabilities() async {
    try {
      _caps = await api.capabilities(refresh: true);
    } on ChatException catch (e) {
      _error = e;
    }
    conversations?.setAvailable(_caps.history);
    _notifyNow();
    return _caps;
  }

  /// Starts an empty thread. The server creates the chat on the first send.
  void newChat() {
    _epoch++;
    tasks.focus(null);
    _conversation = null;
    _messages.clear();
    _hasOlder = false;
    _loading = false;
    conversations?.currentId = null;
    _notifyNow();
  }

  /// Opens a stored chat with its newest messages.
  Future<void> load(String conversationId) async {
    final epoch = ++_epoch;
    tasks.focus(conversationId);
    _conversation =
        conversations?.byId(conversationId) ??
        (_conversation?.id == conversationId ? _conversation : null);
    _messages.clear();
    _hasOlder = false;
    _loading = true;
    conversations?.currentId = conversationId;
    _notifyNow();
    // A cold start from a notification tap opens the chat before init()
    // has read the capabilities: wait for them, or the chat shows empty.
    if (!_caps.known) {
      await refreshCapabilities();
      if (epoch != _epoch) return;
    }
    if (!_caps.history) {
      _loading = false;
      _notifyNow();
      return;
    }
    try {
      final d = await api.getConversation(conversationId, limit: pageSize);
      if (epoch != _epoch) return;
      _conversation = d.conversation;
      _messages
        ..clear()
        ..addAll(d.messages);
      _hasOlder = d.hasMore;
      conversations?.upsert(d.conversation);
      _resumeIfStreaming(conversationId, d.messages);
      _followTasks();
    } on ChatException catch (e) {
      if (epoch != _epoch) return;
      _error = e;
      if (e.kind == ChatErrorKind.notFound) {
        conversations?.remove(conversationId);
        _conversation = null;
      }
    }
    _loading = false;
    _notifyNow();
  }

  /// Re-reads the chat on screen without clearing it (a live-call task or a
  /// reply finished elsewhere and was saved to it). Skipped while a reply is
  /// shown streaming here or a load is running; failures stay quiet.
  Future<void> refreshCurrent() async {
    final id = _conversation?.id;
    if (id == null || !_caps.history || _loading || _shown != null) return;
    final epoch = _epoch;
    try {
      final d = await api.getConversation(id, limit: pageSize);
      if (epoch != _epoch || _shown != null || _conversation?.id != id) return;
      final local = [
        for (final m in _messages)
          if (m.isLocal) m,
      ];
      _conversation = d.conversation;
      _messages
        ..clear()
        ..addAll(d.messages)
        ..addAll(local);
      _hasOlder = d.hasMore;
      conversations?.upsert(d.conversation);
      _followTasks();
      _notifyNow();
    } on ChatException {
      // Quiet: the next open or refresh tries again.
    }
  }

  /// Loads the page before the oldest loaded message.
  Future<void> loadOlder() async {
    final id = _conversation?.id;
    if (id == null || !_hasOlder || _loadingOlder) return;
    String? before;
    for (final m in _messages) {
      if (!m.isLocal) {
        before = m.id;
        break;
      }
    }
    if (before == null) return;
    final epoch = _epoch;
    _loadingOlder = true;
    _notifyNow();
    try {
      final page = await api.messages(id, before: before, limit: pageSize);
      if (epoch != _epoch) return;
      final known = {for (final m in _messages) m.id};
      _messages.insertAll(0, [
        for (final m in page.messages)
          if (!known.contains(m.id)) m,
      ]);
      _hasOlder = page.hasMore;
    } on ChatException catch (e) {
      if (epoch == _epoch) _error = e;
    } finally {
      if (epoch == _epoch) {
        _loadingOlder = false;
        _notifyNow();
      }
    }
  }

  /// API.md: open a chat whose newest reply has `status: streaming` and no
  /// reader on this device → resume it.
  void _resumeIfStreaming(String conversationId, List<ChatMessage> msgs) {
    if (!_caps.resumableStream) return;
    ChatMessage? last;
    for (final m in msgs.reversed) {
      if (m.isAssistant && m.source == MessageSource.text) {
        last = m;
        break;
      }
    }
    if (last == null || !last.isStreaming) return;
    if (replies.byMessage(last.id)?.inFlight ?? false) return;
    final saved = replies.stored(last.id);
    final pair = saved?.text != null && saved?.lastEventId != null;
    replies.resume(
      api,
      messageId: last.id,
      conversationId: conversationId,
      lastEventId: pair ? saved!.lastEventId : null,
      seedText: pair ? saved!.text! : last.text,
      title: _conversation?.title,
    );
  }

  // --- sending -------------------------------------------------------------

  /// Sends [text] (optimistic user message) and streams the reply. Completes
  /// when the reply has ended. Problems are reported in [error] and on the
  /// messages; it does not throw.
  Future<void> send(
    String text, {
    ChatEffort? effort,
    List<MessageAttachment> attachments = const [],
    bool webSearch = false,
  }) async {
    final body = text.trim();
    // Attachments may go without text (bridge-requests.md §4.4).
    if (body.isEmpty && attachments.isEmpty) return;
    if (!_caps.chat) {
      _error = const ChatException(
        ChatErrorKind.unavailable,
        'Text chat is not available on this server',
      );
      _notifyNow();
      return;
    }
    if (_shown != null) {
      _error = const ChatException(
        ChatErrorKind.busy,
        'Wait for the current reply to finish',
        code: 'busy',
      );
      _notifyNow();
      return;
    }
    if (replies.active.length >= _maxReplies) {
      _error = const ChatException(
        ChatErrorKind.busy,
        'Wait for a reply in another chat to finish',
        code: 'busy',
      );
      _notifyNow();
      return;
    }
    if (body.length > _caps.limits.messageChars) {
      _error = ChatException(
        ChatErrorKind.invalid,
        'Messages can be at most ${_caps.limits.messageChars} characters',
        code: 'too_long',
      );
      _notifyNow();
      return;
    }
    final eff = _caps.effort ? (effort ?? defaultEffort?.call()) : null;
    final clientId = _newClientId();
    final convId = _conversation?.id;
    final user = ChatMessage(
      id: 'local-${++_localSeq}',
      conversationId: convId ?? '',
      role: MessageRole.user,
      text: body,
      status: MessageStatus.sending,
      created: _now(),
      clientId: clientId,
      meta: {'effort': ?eff?.wire, if (webSearch) 'web_search': true},
      attachments: attachments,
    );
    _messages.add(user);
    _error = null;
    final task = _track(
      () => replies.send(
        api,
        conversationId: convId,
        text: body,
        effort: eff,
        clientMsgId: clientId,
        title: _conversation?.title,
        attachments: [for (final a in attachments) a.id],
        webSearch: webSearch && _caps.webSearch,
      ),
      newChat: convId == null,
      userLocalId: user.id,
    );
    return _watch(task);
  }

  /// Starts a task with this controller's bookkeeping in place before the
  /// manager's synchronous `started` change fires.
  ReplyTask _track(
    ReplyTask Function() start, {
    required bool newChat,
    String? userLocalId,
  }) {
    late ReplyTask t;
    void claim(ReplyChange c) {
      if (c.kind != ReplyChangeKind.started) return;
      t = c.task;
      if (newChat) {
        _pending = t;
        _pendingEpoch = _epoch;
      }
      if (userLocalId != null) _userLocal[t] = userLocalId;
    }

    replies.addListener(claim);
    try {
      start();
    } finally {
      replies.removeListener(claim);
    }
    _notifyNow();
    return t;
  }

  Future<void> _watch(ReplyTask t) async {
    await t.whenFinished;
    _onFinished(t);
  }

  /// Stops the reply in this thread (the stop route on current bridges).
  /// The partial text stays, marked [MessageStatus.stopped].
  void stop() {
    final t = _shown;
    if (t == null) return;
    unawaited(replies.stop(t));
  }

  /// Asks again for the newest reply. A user message the server never
  /// acknowledged is sent again; otherwise the server re-answers the newest
  /// user message and the text replies after it are replaced. [message] is
  /// accepted for the UI's convenience; only the newest exchange can be
  /// retried.
  Future<void> retry([ChatMessage? message]) async {
    if (!_caps.chat || !canSend) return;
    final i = _messages.lastIndexWhere((m) => m.isUser);
    if (i < 0) return;
    final user = _messages[i];
    final eff = _caps.effort
        ? (ChatEffort.parse(user.meta['effort']) ?? defaultEffort?.call())
        : null;
    final convId = _conversation?.id;
    if (user.isLocal || convId == null) {
      _messages.removeRange(i, _messages.length);
      return send(user.text, effort: eff);
    }
    for (var j = _messages.length - 1; j > i; j--) {
      final m = _messages[j];
      if (m.isAssistant && m.source == MessageSource.text) {
        _messages.removeAt(j);
      }
    }
    _error = null;
    final task = _track(
      () => replies.retry(
        api,
        conversationId: convId,
        effort: eff,
        title: _conversation?.title,
      ),
      newChat: false,
    );
    return _watch(task);
  }

  /// The user message [reply] answers: the nearest user turn before it.
  ChatMessage? questionFor(ChatMessage reply) {
    final i = _messages.indexWhere((m) => m.id == reply.id);
    for (var j = i - 1; j >= 0; j--) {
      if (_messages[j].isUser) return _messages[j];
    }
    return null;
  }

  /// Asks [reply]'s question again as a new turn with `web_search` on
  /// (the reply's More menu; the model otherwise decides by itself).
  Future<void> searchWeb(ChatMessage reply) async {
    final q = questionFor(reply);
    if (q == null || q.text.trim().isEmpty) return;
    return send(q.text, webSearch: true);
  }

  /// Forks the chat at [reply]: a new chat seeded with the conversation up
  /// to it ([forkSeed]), named after this one.
  Future<void> fork(ChatMessage reply) async {
    if (!canSend) return;
    final i = _messages.indexWhere((m) => m.id == reply.id);
    if (i < 0) return;
    final from = title;
    final seed = forkSeed(
      _messages.sublist(0, i + 1),
      title: from,
      limit: _caps.limits.messageChars,
    );
    newChat();
    await send(seed);
    final id = _conversation?.id;
    if (id == null || from == null || from.trim().isEmpty) return;
    try {
      final c = await api.renameConversation(id, '${from.trim()} (fork)');
      conversations?.upsert(c);
      if (_conversation?.id == id) {
        _conversation = c;
        _notifyNow();
      }
    } on ChatException {
      // The bridge's own title stays.
    }
  }

  /// Deletes one message (locally only when it never reached the server).
  Future<void> deleteMessage(String messageId) async {
    final i = _messages.indexWhere((m) => m.id == messageId);
    if (i < 0) return;
    final m = _messages[i];
    final convId = _conversation?.id;
    if (!m.isLocal && convId != null && _caps.history) {
      try {
        await api.deleteMessage(convId, messageId);
      } on ChatException catch (e) {
        if (e.kind != ChatErrorKind.notFound) {
          _error = e;
          _notifyNow();
          return;
        }
      }
    }
    _messages.removeWhere((e) => e.id == messageId);
    _notifyNow();
  }

  // --- reply events --------------------------------------------------------

  void _onReplyChange(ReplyChange c) {
    if (_disposed) return;
    final t = c.task;
    switch (c.kind) {
      case ReplyChangeKind.started || ReplyChangeKind.phase:
        if (_visible(t)) _notifyNow();
      case ReplyChangeKind.meta:
        _onMeta(t);
      case ReplyChangeKind.content:
        if (_visible(t)) _throttle();
      case ReplyChangeKind.finished:
        _onFinished(t);
      case ReplyChangeKind.revised:
        if (t.messageId != null && _visible(t)) {
          _merge(t.build(fallbackConversation: _conversation?.id));
        }
        _notifyNow();
    }
  }

  void _onMeta(ReplyTask t) {
    if (!_visible(t) || t.stopAfterMeta) {
      _notifyNow();
      return;
    }
    final convId = t.conversationId!;
    _updateUser(
      t,
      (u) => u.copyWith(
        id: t.userMessageId,
        conversationId: convId,
        status: MessageStatus.done,
      ),
    );
    if (_conversation == null || _conversation!.id != convId) {
      final now = _now();
      _conversation = Conversation(
        id: convId,
        title: t.title ?? 'New chat',
        created: now,
        updated: now,
        preview: _lastUserText(),
        messageCount: _messages.length + 1,
      );
      conversations?.currentId = convId;
    } else {
      _conversation = _conversation!.copyWith(
        title: t.title,
        updated: _now(),
        messageCount: _messages.length + 1,
      );
    }
    conversations?.upsert(_conversation!);
    _notifyNow();
  }

  void _onFinished(ReplyTask t) {
    if (_disposed || _handled[t] == true) return;
    _handled[t] = true;
    final visible = _visible(t);
    if (identical(_pending, t)) _pending = null;
    _keepTools(t);
    switch (t.phase) {
      case ReplyPhase.done:
        _onDone(t, visible);
      case ReplyPhase.failed:
        final error = t.error ?? ChatException.network;
        if (visible) {
          if (t.messageId != null) {
            _merge(t.build(fallbackConversation: _conversation?.id));
          } else {
            _updateUser(
              t,
              (u) => u.copyWith(status: MessageStatus.failed, error: error),
            );
          }
          _error = error;
        }
      case ReplyPhase.stopped || ReplyPhase.interrupted:
        if (visible) {
          if (t.messageId != null && !t.stopAfterMeta) {
            _merge(t.build(fallbackConversation: _conversation?.id));
          } else if (t.messageId == null || t.stopAfterMeta) {
            _updateUser(t, (m) => m.copyWith(status: MessageStatus.stopped));
          }
        }
      default:
        break;
    }
    _userLocal.remove(t);
    _notifyNow();
  }

  void _onDone(ReplyTask t, bool visible) {
    final d = t.doneEvent;
    final convId = d?.conversationId ?? t.conversationId;
    final msg = t.build(fallbackConversation: convId);
    if (visible) _merge(msg);
    if (convId == null) return;
    final known = _conversation?.id == convId
        ? _conversation
        : conversations?.byId(convId);
    if (known != null) {
      final updated = known.copyWith(
        title: d?.title,
        updated: _now(),
        preview: _preview(msg.text),
      );
      if (_conversation?.id == convId) _conversation = updated;
      conversations?.upsert(updated);
    }
    if (d?.titlePending ?? false) _scheduleTitleRefresh(convId);
  }

  void _updateUser(ReplyTask t, ChatMessage Function(ChatMessage) f) {
    final id = _userLocal[t];
    if (id == null) return;
    final i = _messages.indexWhere((m) => m.id == id);
    if (i < 0) return;
    final m = f(_messages[i]);
    _messages[i] = m;
    _userLocal[t] = m.id;
  }

  void _merge(ChatMessage m) {
    final i = _messages.indexWhere((e) => e.id == m.id);
    if (i >= 0) {
      _messages[i] = m;
    } else {
      _messages.add(m);
    }
  }

  String _lastUserText() {
    for (var i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i].isUser) return _preview(_messages[i].text);
    }
    return '';
  }

  static String _preview(String text) {
    final t = text.trim();
    return t.length > 160 ? t.substring(0, 160) : t;
  }

  void _scheduleTitleRefresh(String id) {
    late final Timer t;
    t = Timer(titleRefreshDelay, () async {
      _timers.remove(t);
      if (_disposed) return;
      try {
        final d = await api.getConversation(id, limit: 1);
        if (_disposed) return;
        conversations?.upsert(d.conversation);
        if (_conversation?.id == id) {
          _conversation = _conversation!.copyWith(
            title: d.conversation.title,
            titleSource: d.conversation.titleSource,
          );
          _notifyNow();
        }
      } on ChatException {
        // Keep the rule-based title.
      }
    });
    _timers.add(t);
  }

  // --- live calls ----------------------------------------------------------

  /// The chat id to pass as `conversation_id` to `POST /api/session`, creating
  /// an empty chat when the thread is new. Null when the server cannot link
  /// calls (start the call unlinked then) or the chat could not be created.
  Future<String?> conversationIdForLive() async {
    if (!_caps.history || !_caps.liveLink) return null;
    return _ensureConversation();
  }

  Future<String?> _ensureConversation() async {
    final current = _conversation?.id;
    if (current != null) return current;
    final epoch = _epoch;
    try {
      final c = await api.createConversation();
      conversations?.upsert(c);
      if (epoch == _epoch && _conversation == null) {
        _conversation = c;
        conversations?.currentId = c.id;
        _notifyNow();
      }
      return c.id;
    } on ChatException catch (e) {
      _error = e;
      _notifyNow();
      return null;
    }
  }

  /// Saves a finished call's turns into the chat. With history support it
  /// posts them to the server (creating the chat if needed) and reloads the
  /// thread, which also brings in task results the bridge saved for a linked
  /// call. Otherwise, or if the post fails, the turns are appended locally so
  /// they stay readable. Pass [tasks] only for calls that were not linked.
  Future<TranscriptImportResult?> importLiveTranscript(
    List<LiveTurn> turns, {
    List<LiveTask> tasks = const [],
    String? session,
    String? conversationId,
  }) async {
    final cleaned = [
      for (final t in turns)
        if (t.text.trim().isNotEmpty) t,
    ];
    if (cleaned.isEmpty && tasks.isEmpty) return null;
    if (_caps.history && _caps.liveTranscript) {
      final target = conversationId ?? await _ensureConversation();
      if (target != null) {
        try {
          final r = await api.saveLiveTranscript(
            target,
            session: session,
            turns: cleaned,
            tasks: tasks,
          );
          if (r.conversation != null) {
            conversations?.upsert(r.conversation!);
            if (_conversation?.id == target) _conversation = r.conversation;
          }
          if (_conversation?.id == target) await _reloadCurrent();
          return r;
        } on ChatException catch (e) {
          _error = e;
        }
      }
    }
    if (conversationId == null || conversationId == _conversation?.id) {
      _appendLocal(cleaned, tasks);
    }
    _notifyNow();
    return null;
  }

  void _appendLocal(List<LiveTurn> turns, List<LiveTask> tasks) {
    final conv = _conversation?.id ?? '';
    for (final t in turns) {
      _messages.add(
        ChatMessage(
          id: 'local-${++_localSeq}',
          conversationId: conv,
          role: t.role,
          text: t.text.trim(),
          source: MessageSource.voice,
          created: t.created ?? _now(),
          clientId: t.id == null ? null : 'turn:${t.id}',
        ),
      );
    }
    for (final t in tasks) {
      _messages.add(
        ChatMessage(
          id: 'local-${++_localSeq}',
          conversationId: conv,
          role: MessageRole.assistant,
          text: t.answer,
          source: MessageSource.task,
          status: t.done ? MessageStatus.done : MessageStatus.failed,
          created: t.created ?? _now(),
          meta: {'task': t.request, 'seconds': t.seconds},
        ),
      );
    }
  }

  Future<void> _reloadCurrent() async {
    final id = _conversation?.id;
    if (id == null) return;
    final epoch = _epoch;
    try {
      final d = await api.getConversation(id, limit: pageSize);
      if (epoch != _epoch) return;
      _conversation = d.conversation;
      _messages
        ..clear()
        ..addAll(d.messages);
      _hasOlder = d.hasMore;
      _followTasks();
    } on ChatException catch (e) {
      if (epoch == _epoch) _error = e;
    }
    _notifyNow();
  }

  // --- live-call tasks -----------------------------------------------------

  /// Follows the streaming task messages of the chat on screen.
  void _followTasks() {
    if (!_caps.taskMessages || !_caps.resumableStream) return;
    tasks.sync(_conversation?.id, _messages);
  }

  void _onTasksChange() => _notify();

  /// A task ended: re-read the chat so the saved answer (with its usage,
  /// steps and seconds) replaces the streamed copy.
  void _onTaskFinished(ReplyTask t) {
    _keepTools(t); // Until the saved copy with `meta.steps` is read.
    if (t.conversationId != null && t.conversationId == _conversation?.id) {
      unawaited(refreshCurrent());
    }
    _notifyNow();
  }

  /// A running live-call task can be stopped from the Tasks panel
  /// (`POST /api/chat/{id}/stop`); its partial answer stays.
  Future<void> stopTask(String messageId) async {
    await tasks.stop(messageId);
    await refreshCurrent();
  }

  /// The chat has a live-call task running now (Tasks glyph dot).
  bool get taskRunning => messages.any((m) => m.isTask && m.isStreaming);

  @override
  void dispose() {
    _disposed = true;
    _throttle.dispose();
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    replies.removeListener(_onReplyChange);
    tasks.removeListener(_onTasksChange);
    _taskEnds.cancel();
    if (_ownsTasks) tasks.dispose();
    // A shared manager keeps the replies running; a private one closes its
    // readers (on resumable bridges the replies still finish server-side).
    if (_ownsReplies) replies.dispose();
    super.dispose();
  }

  static final _rng = Random.secure();

  static String _randomClientId() {
    final r = List.generate(4, (_) => _rng.nextInt(1 << 16).toRadixString(36));
    return 'c-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-${r.join()}';
  }
}
