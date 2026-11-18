import 'dart:async';
import 'dart:convert';

import 'chat_errors.dart';
import 'sse.dart';

/// One event of the bridge's notification stream (API.md "Events",
/// capability `events`): `reply.done`, `task.started`, `task.done`, `notify`,
/// `test`, plus the stream's own `hello`. Events never carry steps or tool
/// input/output, only ids, a status, the chat title and a short preview.
class BridgeEvent {
  const BridgeEvent({
    required this.type,
    this.id,
    this.conversationId,
    this.messageId,
    this.status,
    this.title,
    this.preview,
    this.kind,
    this.watched = false,
    this.session,
    this.job,
    this.request,
    this.created,
    this.lastId,
    this.reset,
    this.heartbeat,
    this.origin,
    this.conversation,
    this.message,
    this.changes = const [],
  });

  /// From an SSE event; null for bad JSON.
  static BridgeEvent? fromSse(SseEvent e) {
    try {
      final j = jsonDecode(e.data);
      if (j is! Map<String, dynamic>) return null;
      return fromJson(e.event, int.tryParse(e.id?.trim() ?? ''), j);
    } catch (_) {
      return null;
    }
  }

  static BridgeEvent fromJson(String type, int? id, Map<String, dynamic> j) {
    String? s(String k) =>
        j[k] is String && (j[k] as String).isNotEmpty ? j[k] as String : null;
    int? n(String k) => j[k] is num ? (j[k] as num).toInt() : null;
    final created = n('created') ?? n('time');
    return BridgeEvent(
      type: type,
      id: id,
      conversationId: s('conversation_id'),
      messageId: s('message_id'),
      status: s('status'),
      title: s('title'),
      preview: s('preview'),
      kind: s('kind'),
      watched: j['watched'] == true,
      session: s('session'),
      job: s('job'),
      request: s('request'),
      created: created == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(created),
      lastId: type == 'hello' ? n('last_id') : null,
      reset: s('reset'),
      heartbeat: type == 'hello' ? n('heartbeat_s') : null,
      origin: s('origin'),
      conversation: j['conversation'] is Map<String, dynamic>
          ? j['conversation'] as Map<String, dynamic>
          : null,
      message: j['message'] is Map<String, dynamic>
          ? j['message'] as Map<String, dynamic>
          : null,
      changes: [
        for (final c in (j['changes'] is List ? j['changes'] as List : []))
          if (c is String) c,
      ],
    );
  }

  /// The wire shape the Android service forwards: `{"type", "id", "data"}`.
  static BridgeEvent? fromForwarded(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map || j['type'] is! String || j['data'] is! Map) return null;
      final id = j['id'];
      return fromJson(
        j['type'] as String,
        id is num ? id.toInt() : null,
        Map<String, dynamic>.from(j['data'] as Map),
      );
    } catch (_) {
      return null;
    }
  }

  final String type;

  /// The event id (resume cursor); null for `hello`.
  final int? id;
  final String? conversationId;
  final String? messageId;

  /// `done`, `failed`, `stopped` or `interrupted` (`reply.done`, `task.done`).
  final String? status;

  /// The chat title, and the plain-text start of the reply.
  final String? title;
  final String? preview;

  /// `notify`: `alert`, `briefing` or `note`.
  final String? kind;

  /// A stream reader (on some device) followed the reply or task to its end:
  /// that reader announces it, so this event stays quiet.
  final bool watched;

  /// Live tasks: the call and job, and the spoken request (`task.started`).
  final String? session;
  final String? job;
  final String? request;
  final DateTime? created;

  /// `hello` only.
  final int? lastId;
  final String? reset;
  final int? heartbeat;

  /// Sync events (API.md "Sync events"): the `X-Device-Id` of the request
  /// that caused the change; null when the server made it.
  final String? origin;

  /// The full conversation after the change, and the new message (without
  /// steps, tools or usage), when the event carries them.
  final Map<String, dynamic>? conversation;
  final Map<String, dynamic>? message;

  /// `conversation.updated`: `pinned`, `kind` or `messages`.
  final List<String> changes;

  bool get isHello => type == 'hello';
  bool get failed => status == 'failed' || status == 'interrupted';

  @override
  String toString() => 'BridgeEvent($type #$id $conversationId $status)';
}

/// The answer of `GET /api/events?once=1` (the background poll).
class EventsPage {
  const EventsPage({
    required this.events,
    required this.lastId,
    this.reset,
    this.more = false,
  });

  factory EventsPage.fromJson(Map<String, dynamic> j) => EventsPage(
    events: [
      for (final e in (j['events'] is List ? j['events'] as List : const []))
        if (e is Map && e['type'] is String && e['data'] is Map)
          BridgeEvent.fromJson(
            e['type'] as String,
            e['id'] is num ? (e['id'] as num).toInt() : null,
            Map<String, dynamic>.from(e['data'] as Map),
          ),
    ],
    lastId: j['last_id'] is num ? (j['last_id'] as num).toInt() : 0,
    reset: j['reset'] is String ? j['reset'] as String : null,
    more: j['more'] == true,
  );

  final List<BridgeEvent> events;
  final int lastId;
  final String? reset;
  final bool more;
}

/// One open `GET /api/events` stream. [events] ends with an error when the
/// connection fails or goes silent for longer than the idle limit; reconnect
/// with the last id ([lastId]).
class EventsConnection {
  EventsConnection.internal();

  final _controller = StreamController<BridgeEvent>();
  final abort = Completer<void>();
  StreamSubscription<SseEvent>? sub;
  Timer? idle;
  bool _closed = false;
  int? _lastId;

  Stream<BridgeEvent> get events => _controller.stream;
  int? get lastId => _lastId;
  bool get closed => _closed;

  void add(BridgeEvent e) {
    if (_closed) return;
    if (e.id != null) _lastId = e.id;
    _controller.add(e);
  }

  void fail(ChatException e) {
    if (_closed) return;
    _closed = true;
    idle?.cancel();
    sub?.cancel().ignore();
    _controller.addError(e);
    _controller.close().ignore();
  }

  /// Closes the connection (leaving the screen, sign-out).
  void cancel() {
    if (_closed) return;
    _closed = true;
    idle?.cancel();
    sub?.cancel().ignore();
    if (!abort.isCompleted) abort.complete();
    _controller.close().ignore();
  }
}
