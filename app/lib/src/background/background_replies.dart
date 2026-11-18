import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../chat/chat_api.dart';
import '../chat/chat_errors.dart';
import '../chat/models.dart';
import 'reply_store.dart';
import 'reply_task.dart';

export 'reply_task.dart';

/// What changed on a [ReplyTask].
enum ReplyChangeKind {
  /// A new task (send, retry or resume).
  started,

  /// `meta` arrived: conversation and message ids are known.
  meta,

  /// Text, progress or a snapshot.
  content,

  /// Connecting, streaming or reconnecting.
  phase,

  /// It reached a terminal phase.
  finished,

  /// A finished task was corrected (a stop that raced the end of the reply).
  revised,
}

class ReplyChange {
  const ReplyChange(this.task, this.kind);
  final ReplyTask task;
  final ReplyChangeKind kind;
}

typedef ReplyListener = void Function(ReplyChange change);

/// Backoff before reconnect attempt [attempt] (0-based): 1 s, 2 s, 4 s … 30 s.
Duration defaultReplyBackoff(int attempt) =>
    Duration(milliseconds: min(30000, 1000 * (1 << min(attempt, 5))));

/// Owns every reply being written, across chats and independent of which
/// chat is on screen or whether a `ChatController` exists at all.
///
/// - **Never cancels on navigation.** Only [stop] stops a reply.
/// - **Reconnects** a dropped stream with `Last-Event-ID` and backoff when
///   the bridge has `resumable_stream`; the reply shows as streaming
///   meanwhile, never failed.
/// - **App in the background:** with push registered ([pushActive]) on a
///   resumable bridge, readers are closed so the bridge pushes the result
///   (API.md "Push notifications"), and resumed on return. Otherwise the
///   reader stays open for as long as the OS lets the app run, and the
///   stream is resumed on return.
/// - **Persists** each in-flight reply's message id and last event id, so
///   [restore] resumes them after a cold start.
/// - **Old bridges** (no `resumable_stream`): closing the connection stops
///   the reply, so nothing is closed on purpose; a drop while the app is in
///   the background is reconciled with the saved message instead of being
///   shown as a failure.
class BackgroundReplies {
  BackgroundReplies({
    ReplyStore? store,
    DateTime Function()? now,
    this.backoff = defaultReplyBackoff,
    this.giveUpAfter = const Duration(minutes: 20),
    this.persistDelay = const Duration(seconds: 2),
    this.staleAfter = const Duration(seconds: 25),
    this.resumeGrace = const Duration(seconds: 15),
    this.forgetAfter = const Duration(hours: 24),
    this.keepFinished = 32,
  }) : store = store ?? MemoryReplyStore(),
       _now = now ?? DateTime.now;

  static BackgroundReplies? _instance;

  /// The process-wide manager, persisting to shared_preferences. Pass it to
  /// every `ChatController` and call [bindLifecycle] once.
  static BackgroundReplies get instance =>
      _instance ??= BackgroundReplies(store: PrefsReplyStore());

  /// For tests: replaces (or clears) [instance].
  @visibleForTesting
  static set instance(BackgroundReplies? value) => _instance = value;

  final ReplyStore store;
  final Duration Function(int attempt) backoff;

  /// After this long without getting a stream back, a dropped reply fails.
  final Duration giveUpAfter;
  final Duration persistDelay;

  /// On resume, a reader silent for this long is treated as dead (the
  /// process was frozen) and reconnected at once instead of waiting for the
  /// idle timeout.
  final Duration staleAfter;

  /// A drop this soon after returning to the foreground counts as caused by
  /// the background (old bridges: reconciled, not failed).
  final Duration resumeGrace;

  /// Persisted replies older than this are dropped.
  final Duration forgetAfter;

  /// Finished tasks kept for [byMessage] lookups.
  final int keepFinished;
  final DateTime Function() _now;

  final List<ReplyTask> _active = [];
  final List<ReplyTask> _recent = [];
  final List<ReplyListener> _listeners = [];
  final _finished = StreamController<ReplyTask>.broadcast();
  final ValueNotifier<int> inFlightCount = ValueNotifier(0);
  final ValueNotifier<bool> keepAlive = ValueNotifier(false);

  int _seq = 0;
  bool _foreground = true;
  DateTime? _resumedAt;
  bool _pushActive = false;
  bool _disposed = false;
  Timer? _persistTimer;
  Future<void> _persisting = Future.value();
  List<InFlightReply> _foreign = [];
  final Map<String, InFlightReply> _known = {};
  final Set<String> _restored = {};
  AppLifecycleListener? _lifecycle;

  // --- state ---------------------------------------------------------------

  /// Replies being written, oldest first.
  List<ReplyTask> get active => List.unmodifiable(_active);

  /// Any reply in flight.
  bool get busy => _active.isNotEmpty;

  /// The app is in the foreground (as last told by [setForeground]).
  bool get foreground => _foreground;

  /// Push is registered with the current bridge (set by the push registrar).
  bool get pushActive => _pushActive;
  set pushActive(bool v) {
    if (_pushActive == v) return;
    _pushActive = v;
    _updateCounts();
  }

  /// Some in-flight reply depends on its open connection in the background
  /// (no push, or an old bridge). Informational: Tove runs no foreground
  /// service for replies.
  bool get needsKeepAlive => _active.any((t) => !_parkable(t));

  /// Each task once, when it reaches a terminal phase (for notifications).
  Stream<ReplyTask> get finished => _finished.stream;

  /// The in-flight reply of [conversationId], if any.
  ReplyTask? byConversation(String? conversationId) {
    if (conversationId == null) return null;
    for (final t in _active.reversed) {
      if (t.conversationId == conversationId) return t;
    }
    return null;
  }

  /// The task writing (or recently finished writing) [messageId].
  ReplyTask? byMessage(String? messageId) {
    if (messageId == null) return null;
    for (final t in [..._active.reversed, ..._recent.reversed]) {
      if (t.messageId == messageId || t.localId == messageId) return t;
    }
    return null;
  }

  /// Synchronous change listener (the controller's view).
  void addListener(ReplyListener l) => _listeners.add(l);
  void removeListener(ReplyListener l) => _listeners.remove(l);

  void _emit(ReplyTask t, ReplyChangeKind kind) {
    for (final l in List.of(_listeners)) {
      l(ReplyChange(t, kind));
    }
  }

  // --- starting ------------------------------------------------------------

  /// Sends [text] and follows the reply.
  ReplyTask send(
    ChatApi api, {
    String? conversationId,
    required String text,
    ChatEffort? effort,
    String? clientMsgId,
    String? title,
    List<String> attachments = const [],
    bool webSearch = false,
  }) => _start(
    api,
    api.send(
      conversationId: conversationId,
      text: text,
      effort: effort,
      clientMsgId: clientMsgId,
      attachments: attachments,
      webSearch: webSearch,
    ),
    conversationId: conversationId,
    effort: effort,
    clientMsgId: clientMsgId,
    title: title,
  );

  /// Re-answers the newest user message of [conversationId].
  ReplyTask retry(
    ChatApi api, {
    required String conversationId,
    ChatEffort? effort,
    String? title,
  }) {
    // The bridge stops the chat's running reply first; mirror that here.
    final old = byConversation(conversationId);
    if (old != null) {
      _detach(old);
      _finish(old, ReplyPhase.stopped, stopReason: 'retry');
    }
    return _start(
      api,
      api.retry(conversationId: conversationId, effort: effort),
      conversationId: conversationId,
      effort: effort,
      title: title,
    );
  }

  /// Follows a reply that is already running on the bridge (needs
  /// `resumable_stream`). Returns the existing task if one follows it.
  ///
  /// With [lastEventId], [seedText] must be the text up to that id (a
  /// persisted pair) and only later events are fetched. Without it the reply
  /// replays from the start and [seedText] (the server's saved copy) is
  /// shown until the replay has caught up.
  ReplyTask resume(
    ChatApi api, {
    required String messageId,
    required String conversationId,
    int? lastEventId,
    String seedText = '',
    String? title,
    bool alreadyNotified = false,
  }) {
    final existing = byMessage(messageId);
    if (existing != null && existing.inFlight) return existing;
    final t = ReplyTask.internal(
      localId: 'reply-${++_seq}',
      api: api,
      created: _now(),
      conversationId: conversationId,
      messageId: messageId,
      title: title,
      seedText: lastEventId == null ? seedText : '',
      lastEventId: lastEventId,
      resumed: true,
      alreadyNotified: alreadyNotified,
    );
    if (lastEventId != null && seedText.isNotEmpty) t.replaceText(seedText);
    _add(t);
    _attach(t, api.resume(messageId, lastEventId: lastEventId));
    return t;
  }

  ReplyTask _start(
    ChatApi api,
    ChatStream stream, {
    String? conversationId,
    ChatEffort? effort,
    String? clientMsgId,
    String? title,
  }) {
    final t = ReplyTask.internal(
      localId: 'reply-${++_seq}',
      api: api,
      created: _now(),
      conversationId: conversationId,
      effort: effort,
      clientMsgId: clientMsgId,
      title: title,
    );
    _add(t);
    _attach(t, stream);
    return t;
  }

  void _add(ReplyTask t) {
    _active.add(t);
    _updateCounts();
    _emit(t, ReplyChangeKind.started);
  }

  // --- stream handling -----------------------------------------------------

  void _attach(ReplyTask t, ChatStream s) {
    t.reader = s;
    t.itemsSinceAttach = 0;
    t.lastItemAt = _now();
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

  void _onItem(ReplyTask t, ChatStream s, ChatStreamItem item) {
    if (!identical(t.reader, s)) return;
    final e = item.event;
    final id = item.id;
    t.itemsSinceAttach++;
    t.lastItemAt = _now();
    if (id != null &&
        e is! ChatSnapshotEvent &&
        t.lastEventId != null &&
        id <= t.lastEventId!) {
      return; // Already processed before the reconnect.
    }
    if (id != null) t.noteEventId(id);

    if (t.stopAfterMeta) {
      // Stopped before the ids were known: stop it on the bridge now.
      if (e is ChatMetaEvent) {
        t.applyMeta(e);
        _detach(t);
        _callStop(t);
      }
      return;
    }
    if (t.finished) return;

    if (t.phase != ReplyPhase.streaming) {
      final wasReconnecting = t.phase == ReplyPhase.reconnecting;
      t.setPhase(ReplyPhase.streaming);
      t.attempt = 0;
      t.dropSince = null;
      if (wasReconnecting) t.countReconnect();
      _emit(t, ReplyChangeKind.phase);
    }

    switch (e) {
      case ChatMetaEvent():
        t.applyMeta(e);
        _persistNow();
        _emit(t, ReplyChangeKind.meta);
      case ChatDeltaEvent():
        t.appendText(e.text);
        _persistSoon();
        _emit(t, ReplyChangeKind.content);
      case ChatProgressEvent():
        t.setProgress(e.progress);
        t.tools.record(e.progress, t.text.length, _now());
        _persistSoon();
        _emit(t, ReplyChangeKind.content);
      case ChatStepEvent():
        t.steps.start(e.step);
        _persistSoon();
        _emit(t, ReplyChangeKind.content);
      case ChatStepDeltaEvent():
        t.steps.delta(e.id, e.text);
        _emit(t, ReplyChangeKind.content);
      case ChatSnapshotEvent():
        t.replaceText(e.text);
        if (e.lastStatus != null) t.setProgress(e.lastStatus);
        if (e.steps != null) t.steps.replaceAll(e.steps!);
        _persistSoon();
        _emit(t, ReplyChangeKind.content);
      case ChatDoneEvent():
        t.setIds(conversationId: e.conversationId, messageId: e.messageId);
        t.setTitle(e.title);
        _finish(t, ReplyPhase.done, done: e);
      case ChatFailedEvent():
        if (e.error.code == 'interrupted') {
          _finish(t, ReplyPhase.interrupted, error: e.error);
        } else {
          _finish(t, ReplyPhase.failed, error: e.error);
        }
      case ChatStoppedEvent():
        _finish(t, ReplyPhase.stopped, stopReason: e.reason ?? 'user');
    }
  }

  bool _resumable(ReplyTask t) {
    final c = t.api.cachedCapabilities;
    return c != null && c.resumableStream;
  }

  bool _parkable(ReplyTask t) {
    final c = t.api.cachedCapabilities;
    return _pushActive &&
        c != null &&
        c.resumableStream &&
        !c.disconnectCancels &&
        t.messageId != null;
  }

  bool get _backgroundRelated {
    if (!_foreground) return true;
    final r = _resumedAt;
    return r != null && _now().difference(r) < resumeGrace;
  }

  void _onDrop(ReplyTask t, ChatStream s, ChatException e) {
    if (!identical(t.reader, s) || t.finished) return;
    t.reader = null;
    t.subscription = null;
    if (t.stopAfterMeta) return; // Locally stopped; ids never arrived.

    final http = e.status;
    if (t.messageId == null) {
      // No id to resume with: the request itself failed.
      _finish(t, ReplyPhase.failed, error: e);
      return;
    }
    if (!_resumable(t)) {
      if (_backgroundRelated) {
        unawaited(_reconcile(t, fallback: ReplyPhase.interrupted));
      } else {
        _finish(t, ReplyPhase.failed, error: e);
      }
      return;
    }
    if (http != null) {
      if (http == 400) {
        t.resetEventId(); // bad_last_event_id: start over from the beginning.
      } else if (http == 401 || http == 404) {
        _finish(t, ReplyPhase.failed, error: e);
        return;
      }
    } else if (t.itemsSinceAttach == 0 && e.code == ChatException.cutOff.code) {
      // An empty resume: the reply ended and we had every event already.
      unawaited(_reconcile(t, fallback: ReplyPhase.interrupted));
      return;
    }
    _scheduleReconnect(t);
  }

  void _scheduleReconnect(ReplyTask t, {Duration? delay}) {
    if (t.finished || _disposed) return;
    final now = _now();
    t.dropSince ??= now;
    if (now.difference(t.dropSince!) > giveUpAfter) {
      _finish(t, ReplyPhase.failed, error: ChatException.cutOff);
      return;
    }
    if (t.phase != ReplyPhase.reconnecting) {
      t.setPhase(ReplyPhase.reconnecting);
      _emit(t, ReplyChangeKind.phase);
    }
    t.retryTimer?.cancel();
    t.retryTimer = Timer(delay ?? backoff(t.attempt++), () {
      t.retryTimer = null;
      _reconnect(t);
    });
  }

  void _reconnect(ReplyTask t) {
    if (t.finished || _disposed || t.reader != null) return;
    final id = t.messageId;
    if (id == null) return;
    _attach(t, t.api.resume(id, lastEventId: t.lastEventId));
  }

  /// Reads the saved message to learn how a reply we lost track of ended.
  Future<void> _reconcile(ReplyTask t, {required ReplyPhase fallback}) async {
    final conv = t.conversationId, id = t.messageId;
    if (conv == null || id == null) {
      _finish(t, fallback);
      return;
    }
    if (t.phase != ReplyPhase.reconnecting) {
      t.setPhase(ReplyPhase.reconnecting);
      _emit(t, ReplyChangeKind.phase);
    }
    ChatMessage? saved;
    try {
      final d = await t.api.getConversation(conv, limit: 20);
      for (final m in d.messages) {
        if (m.id == id) saved = m;
      }
    } on ChatException catch (e) {
      if (t.finished) return;
      if (_resumable(t) && e.kind == ChatErrorKind.network) {
        _scheduleReconnect(t);
      } else {
        _finish(t, fallback);
      }
      return;
    }
    if (t.finished) return;
    if (saved == null) {
      _finish(t, fallback);
      return;
    }
    if (saved.text.length >= t.text.length) t.replaceText(saved.text);
    switch (saved.status) {
      case MessageStatus.streaming || MessageStatus.sending:
        if (_resumable(t)) {
          _scheduleReconnect(t);
        } else {
          _finish(t, ReplyPhase.interrupted);
        }
      case MessageStatus.done:
        _finish(
          t,
          ReplyPhase.done,
          done: ChatDoneEvent(
            conversationId: conv,
            messageId: id,
            finishReason: saved.meta['finish_reason'] as String?,
          ),
        );
      case MessageStatus.stopped:
        _finish(
          t,
          ReplyPhase.stopped,
          stopReason: saved.meta['stop_reason'] as String? ?? 'disconnect',
        );
      case MessageStatus.failed:
        _finish(
          t,
          ReplyPhase.failed,
          error: saved.error ?? ChatException.fromStream(null, null),
        );
      case MessageStatus.interrupted:
        _finish(t, ReplyPhase.interrupted);
    }
  }

  void _finish(
    ReplyTask t,
    ReplyPhase phase, {
    ChatException? error,
    ChatDoneEvent? done,
    String? stopReason,
    bool keepReader = false,
  }) {
    if (!keepReader) _detach(t);
    t.tools.finish(_now(), failed: phase != ReplyPhase.done);
    t.steps.finish(_now(), failed: phase != ReplyPhase.done);
    if (!t.finish(phase, error: error, done: done, stopReason: stopReason)) {
      return;
    }
    _active.remove(t);
    _recent.add(t);
    while (_recent.length > keepFinished) {
      _recent.removeAt(0);
    }
    _updateCounts();
    _persistNow();
    _emit(t, ReplyChangeKind.finished);
    if (!_finished.isClosed) _finished.add(t);
  }

  // --- stop ----------------------------------------------------------------

  /// Stops [t] on purpose. The partial text stays, as stopped. Uses the stop
  /// route when the bridge has one (closing is not a stop there); on old
  /// bridges closing the connection is the stop. Never throws.
  Future<void> stop(ReplyTask t) async {
    if (t.finished) return;
    final caps = t.api.cachedCapabilities;
    final routed = caps != null && (caps.stopEndpoint || caps.resumableStream);
    if (!routed) {
      _finish(t, ReplyPhase.stopped, stopReason: 'user');
      return;
    }
    if (t.messageId == null) {
      // Keep reading until meta names the message, then stop it there.
      t.stopAfterMeta = true;
      _finish(t, ReplyPhase.stopped, stopReason: 'user', keepReader: true);
      return;
    }
    _finish(t, ReplyPhase.stopped, stopReason: 'user');
    await _callStop(t);
  }

  Future<void> _callStop(ReplyTask t) async {
    final id = t.messageId;
    if (id == null) return;
    StopResult r;
    try {
      r = await t.api.stopReply(id);
    } on ChatException {
      try {
        r = await t.api.stopReply(id); // One retry; the next refetch tells.
      } on ChatException {
        return;
      }
    }
    var changed = false;
    if (!r.stopped && r.status == MessageStatus.done && r.text != null) {
      t.reviseToDone(r.text!);
      changed = true;
    } else if (r.text != null && r.text!.length > t.text.length) {
      t.replaceText(r.text!);
      changed = true;
    }
    if (changed) _emit(t, ReplyChangeKind.revised);
  }

  // --- lifecycle -----------------------------------------------------------

  /// Follows the app lifecycle through an [AppLifecycleListener]. Call once,
  /// after `WidgetsFlutterBinding.ensureInitialized()`.
  void bindLifecycle() {
    _lifecycle ??= AppLifecycleListener(
      onStateChange: (s) => setForeground(
        s == AppLifecycleState.resumed || s == AppLifecycleState.inactive,
      ),
    );
  }

  /// The app became visible ([foreground] true) or left the screen.
  ///
  /// Leaving: readers of replies the bridge can push are closed (so it
  /// pushes). Returning: every parked or dropped reply reconnects at once,
  /// and a reader that went silent while the process was frozen is replaced.
  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (!foreground) {
      for (final t in List.of(_active)) {
        if (_parkable(t) && t.reader != null && !t.stopAfterMeta) {
          _detach(t);
          t.setPhase(ReplyPhase.reconnecting);
          t.attempt = 0;
          t.dropSince = null;
          _emit(t, ReplyChangeKind.phase);
        }
      }
      _persistNow();
      return;
    }
    final now = _now();
    _resumedAt = now;
    for (final t in List.of(_active)) {
      if (t.stopAfterMeta || !_resumable(t) || t.messageId == null) continue;
      final stale =
          t.reader != null &&
          t.lastItemAt != null &&
          now.difference(t.lastItemAt!) > staleAfter;
      if (t.reader == null || stale) {
        if (stale) _detach(t);
        t.attempt = 0;
        t.dropSince = null;
        if (t.phase != ReplyPhase.reconnecting) {
          t.setPhase(ReplyPhase.reconnecting);
          _emit(t, ReplyChangeKind.phase);
        }
        t.retryTimer?.cancel();
        t.retryTimer = null;
        _reconnect(t);
      }
    }
  }

  // --- persistence ---------------------------------------------------------

  /// Resumes the replies a previous run left in flight on [api]'s bridge
  /// (once per bridge). Returns how many were resumed. Needs
  /// `resumable_stream`; on other bridges the entries are dropped.
  Future<int> restore(ChatApi api) async {
    final server = api.baseUrl.toString();
    if (!_restored.add(server)) return 0;
    Capabilities caps;
    try {
      caps = await api.capabilities();
    } on ChatException {
      _restored.remove(server);
      return 0;
    }
    if (!caps.known) {
      _restored.remove(server);
      return 0;
    }
    final all = await store.load();
    final now = _now();
    _foreign = [
      for (final e in all)
        if (e.server != server && now.difference(e.started) < forgetAfter) e,
    ];
    var n = 0;
    for (final e in all) {
      if (e.server != server) continue;
      if (now.difference(e.started) >= forgetAfter) continue;
      if (!caps.resumableStream) continue;
      if (byMessage(e.messageId)?.inFlight ?? false) continue;
      _known[e.messageId] = e;
      resume(
        api,
        messageId: e.messageId,
        conversationId: e.conversationId,
        lastEventId: e.text == null ? null : e.lastEventId,
        seedText: e.text ?? '',
        title: e.title,
        alreadyNotified: e.notified,
      );
      n++;
    }
    _persistNow();
    return n;
  }

  /// The persisted entry for [messageId] (for a resume when a chat opens).
  InFlightReply? stored(String messageId) => _known[messageId];

  void _persistSoon() {
    if (_persistTimer != null || _disposed) return;
    _persistTimer = Timer(persistDelay, () {
      _persistTimer = null;
      _persistNow();
    });
  }

  void _persistNow() {
    _persistTimer?.cancel();
    _persistTimer = null;
    if (_disposed) return;
    final entries = <InFlightReply>[..._foreign];
    for (final t in _active) {
      final id = t.messageId, conv = t.conversationId;
      if (id == null || conv == null || t.stopAfterMeta) continue;
      final raw = t.rawText;
      final pair =
          !t.hasSeed &&
          t.lastEventId != null &&
          raw.length <= InFlightReply.maxText;
      final e = InFlightReply(
        server: t.api.baseUrl.toString(),
        messageId: id,
        conversationId: conv,
        started: _known[id]?.started ?? t.created,
        lastEventId: pair ? t.lastEventId : null,
        text: pair ? raw : null,
        title: t.title,
        notified: t.alreadyNotified,
      );
      _known[id] = e;
      entries.add(e);
    }
    _persisting = _persisting
        .then((_) => store.save(entries))
        .catchError((Object _) {});
  }

  /// Waits for pending writes (tests, shutdown).
  Future<void> flush() {
    _persistNow();
    return _persisting;
  }

  void _updateCounts() {
    inFlightCount.value = _active.length;
    keepAlive.value = needsKeepAlive;
  }

  /// Closes every reader without stopping the replies (they keep running on
  /// resumable bridges). With [forget], the persisted entries of [server]
  /// (all when null) are dropped too: use it on sign-out.
  Future<void> detachAll({bool forget = false, String? server}) async {
    for (final t in List.of(_active)) {
      if (server != null && t.api.baseUrl.toString() != server) continue;
      _detach(t);
      t.finish(ReplyPhase.interrupted);
      _active.remove(t);
    }
    _updateCounts();
    if (forget) {
      _foreign = [
        for (final e in _foreign)
          if (server != null && e.server != server) e,
      ];
      _known.clear();
      _restored.clear();
    }
    await flush();
  }

  void dispose() {
    if (_disposed) return;
    for (final t in List.of(_active)) {
      _detach(t);
    }
    _persistNow();
    _disposed = true;
    _lifecycle?.dispose();
    _lifecycle = null;
    _listeners.clear();
    _finished.close();
    inFlightCount.dispose();
    keepAlive.dispose();
    if (identical(_instance, this)) _instance = null;
  }
}
