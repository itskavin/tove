import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../chat/chat_api.dart';
import '../chat/chat_errors.dart';
import '../chat/events.dart';
import 'reply_notice.dart';

/// What a bridge event announces; null when it needs no notice: a stopped
/// reply, a task starting, the stream's `hello`, or an end that a stream
/// reader (on some device) already saw (`watched`).
ReplyNotice? noticeForEvent(BridgeEvent e) {
  final kind = switch (e.type) {
    'reply.done' when e.watched || e.status == 'stopped' => null,
    'reply.done' => e.failed ? ReplyNoticeKind.failed : ReplyNoticeKind.reply,
    'task.done' when e.watched || e.status == 'stopped' => null,
    'task.done' => e.failed ? ReplyNoticeKind.taskFailed : ReplyNoticeKind.task,
    'notify' => ReplyNoticeKind.reply,
    'test' => ReplyNoticeKind.test,
    _ => null,
  };
  if (kind == null) return null;
  return ReplyNotice(
    kind: kind,
    conversationId: e.conversationId,
    messageId: e.messageId,
    title: e.title,
    preview: e.preview,
  );
}

/// The app's view of the bridge's notification stream (API.md "Events").
///
/// Events come from one of two places:
/// - on Android with instant notifications on, the native service holds the
///   connection and forwards events here while the app is on screen
///   ([handle]);
/// - otherwise (web, desktop, Android with instant notifications off) this
///   holds a stream itself, but only while the app is visible
///   ([setForeground]). Web shows notifications only while its tab is open.
///
/// Each event is handled once (by id): its notice goes to [announce] (the
/// in-app banner for another chat, a system notification when the app is
/// not visible), and [onEvent] lets the chat and the chat list refresh.
class EventsHub {
  EventsHub({
    required this.api,
    required this.announce,
    this.onEvent,
    this.useOwnStream = _always,
    this.keepWhenHidden = kIsWeb,
    this.heartbeat = 80,
    this.deviceId,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static bool _always() => true;

  final ChatApi api;
  final NoticeTarget Function(ReplyNotice? notice) announce;
  final void Function(BridgeEvent e)? onEvent;

  /// False while the Android service holds the connection (no second one).
  final bool Function() useOwnStream;

  /// Web: keep the stream while the tab is open but hidden, so a browser
  /// notification can show (nothing arrives once the tab is closed).
  final bool keepWhenHidden;
  final int heartbeat;
  final String? Function()? deviceId;
  final DateTime Function() _now;

  final _events = StreamController<BridgeEvent>.broadcast();
  final List<int> _seen = [];
  EventsConnection? _conn;
  StreamSubscription<BridgeEvent>? _sub;
  Timer? _retry;
  int _attempt = 0;
  int? _lastId;
  bool _foreground = false;
  bool _disposed = false;
  bool _supported = false;
  DateTime? _connectedAt;
  AppLifecycleListener? _lifecycle;

  /// Every new event, after it was handled.
  Stream<BridgeEvent> get events => _events.stream;

  /// This hub's own stream is open.
  bool get connected => _conn != null && _connectedAt != null;
  int? get lastId => _lastId;

  /// Call once the capabilities are known (`events` present).
  void setSupported(bool supported) {
    if (_supported == supported) return;
    _supported = supported;
    _sync();
  }

  void bindLifecycle() {
    _lifecycle ??= AppLifecycleListener(
      onStateChange: (s) => setForeground(
        s == AppLifecycleState.resumed || s == AppLifecycleState.inactive,
      ),
    );
    final s = WidgetsBinding.instance.lifecycleState;
    setForeground(s == null || s == AppLifecycleState.resumed);
  }

  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    _sync();
  }

  /// Re-checks whether this hub should hold its own stream (after the
  /// instant-notification setting changed).
  void refresh() => _sync();

  /// One event, from this hub's stream or from the Android service.
  void handle(BridgeEvent e) {
    if (_disposed) return;
    if (e.isHello) return;
    final id = e.id;
    if (id != null) {
      if (_seen.contains(id)) return;
      _seen.add(id);
      if (_seen.length > 200) _seen.removeAt(0);
      if (_lastId == null || id > _lastId!) _lastId = id;
    }
    onEvent?.call(e);
    final notice = noticeForEvent(e);
    if (notice != null) announce(notice);
    if (!_events.isClosed) _events.add(e);
  }

  // --- own stream ---------------------------------------------------------

  bool get _wanted =>
      !_disposed &&
      _supported &&
      (_foreground || keepWhenHidden) &&
      useOwnStream();

  void _sync() {
    if (_wanted) {
      if (_conn == null && _retry == null) _open();
    } else {
      _close();
    }
  }

  void _open() {
    _retry?.cancel();
    _retry = null;
    final c = api.events(
      after: _lastId,
      heartbeat: heartbeat,
      deviceId: deviceId?.call(),
    );
    _conn = c;
    _sub = c.events.listen(
      (e) {
        if (!identical(_conn, c)) return;
        if (e.isHello) {
          _connectedAt = _now();
          _attempt = 0;
          // A fresh cursor: start from now. A gap: some events were trimmed
          // while away; the chat list refresh covers what they said.
          if (_lastId == null || e.reset == 'unknown_id') _lastId = e.lastId;
          if (e.reset != null) onEvent?.call(e);
          return;
        }
        handle(e);
      },
      onError: (Object err) => _dropped(c, err),
      onDone: () => _dropped(c, ChatException.cutOff),
    );
  }

  void _dropped(EventsConnection c, Object err) {
    if (!identical(_conn, c)) return;
    _conn = null;
    _sub = null;
    _connectedAt = null;
    final status = err is ChatException ? err.status : null;
    if (status == 401 || status == 404 || !_wanted) return;
    // 2 s doubling to 2 min, with jitter; only while the app is visible.
    final base = min(120000, 2000 * (1 << min(_attempt++, 6)));
    final jitter = 0.8 + Random().nextDouble() * 0.4;
    _retry = Timer(Duration(milliseconds: (base * jitter).round()), () {
      _retry = null;
      if (_wanted) _open();
    });
  }

  void _close() {
    _retry?.cancel();
    _retry = null;
    _sub?.cancel().ignore();
    _sub = null;
    _conn?.cancel();
    _conn = null;
    _connectedAt = null;
  }

  @visibleForTesting
  EventsConnection? get connection => _conn;

  void dispose() {
    _disposed = true;
    _lifecycle?.dispose();
    _close();
    _events.close();
  }
}
