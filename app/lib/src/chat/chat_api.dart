import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'chat_errors.dart';
import 'events.dart';
import 'steps.dart';
import 'models.dart';
import 'sse.dart';
import 'usage_limits.dart';
import '../brand.dart';

/// One stream event with its SSE `id:` (null on bridges before 15 Nov 2026,
/// and on resume events of replies saved before then).
class ChatStreamItem {
  const ChatStreamItem(this.event, this.id);
  final ChatEvent event;
  final int? id;
}

/// A running `/api/chat` reply, or a resumed one
/// (`GET /api/chat/{id}/stream`).
///
/// [events] yields [ChatMetaEvent] first (on resume only from id 0), then
/// [ChatDeltaEvent] / [ChatProgressEvent] / [ChatSnapshotEvent], and ends
/// after [ChatDoneEvent], [ChatFailedEvent] or [ChatStoppedEvent]. Failures
/// before or outside the stream (HTTP errors, dropped connection, timeouts)
/// arrive as a [ChatException] stream error. After [cancel] the stream just
/// closes. Listen to either [events] or [items], once.
class ChatStream {
  ChatStream._();

  final _controller = StreamController<ChatStreamItem>();
  final _abort = Completer<void>();
  StreamSubscription<SseEvent>? _sub;
  Timer? _idle;
  bool _closed = false;
  bool _cancelled = false;
  int? _lastId;

  Stream<ChatEvent> get events => _controller.stream.map((i) => i.event);

  /// The events with their SSE ids.
  Stream<ChatStreamItem> get items => _controller.stream;

  /// The newest SSE id received so far.
  int? get lastEventId => _lastId;

  /// True once [cancel] was called.
  bool get cancelled => _cancelled;

  /// True once the stream ended for any reason.
  bool get closed => _closed;

  /// Closes the connection. On bridges without `resumable_stream` (or with
  /// `disconnect_cancels`) that also stops the reply; otherwise the reply
  /// keeps running and only this reader ends (use [ChatApi.stopReply]).
  void cancel() {
    if (_closed) return;
    _cancelled = true;
    _finish();
  }

  void _add(ChatEvent e, int? id) {
    if (_closed) return;
    if (id != null) _lastId = id;
    _controller.add(ChatStreamItem(e, id));
  }

  void _fail(Object error) {
    if (_closed) return;
    _controller.addError(error);
    _finish();
  }

  void _finish() {
    if (_closed) return;
    _closed = true;
    _idle?.cancel();
    if (!_abort.isCompleted) _abort.complete();
    _sub?.cancel().ignore();
    _controller.close();
  }
}

/// Client for the bridge's chat, history and capabilities routes
/// (`infra/core/gpt-live-bridge/API.md`). Uses the same base URL and key as
/// `BridgeApi`.
///
/// Streaming uses `http.Client.send`: `IOClient` on native and, with
/// package:http ≥ 1.5, the fetch-based `BrowserClient` on web, which reads the
/// body through a `ReadableStream` reader, so deltas arrive incrementally.
/// Both honour `AbortableRequest`, which is how [ChatStream.cancel] closes the
/// connection.
class ChatApi {
  ChatApi({
    required Uri baseUrl,
    required String accessKey,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 15),
    this.connectTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 50),
  }) : _base = _normalise(baseUrl),
       _key = accessKey,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final Uri _base;
  final String _key;

  /// The bridge this client talks to (no trailing slash).
  Uri get baseUrl => _base;
  final http.Client _client;
  final bool _ownsClient;

  /// Any non-streaming request.
  final Duration requestTimeout;

  /// Until `/api/chat` answers with headers.
  final Duration connectTimeout;

  /// Longest silence inside the stream. The bridge sends a keep-alive every
  /// 15 s, so a longer gap means the connection is dead.
  final Duration idleTimeout;

  Capabilities? _caps;
  Future<Capabilities>? _capsPending;

  static Uri _normalise(Uri u) {
    final path = u.path.endsWith('/')
        ? u.path.substring(0, u.path.length - 1)
        : u.path;
    return u.replace(path: path, query: null, fragment: null);
  }

  Uri _url(String path, [Map<String, String?>? query]) {
    final q = <String, String>{
      for (final e in (query ?? const <String, String?>{}).entries)
        if (e.value != null) e.key: e.value!,
    };
    return _base.replace(
      path: '${_base.path}$path',
      queryParameters: q.isEmpty ? null : q,
    );
  }

  /// This install's id, sent as `X-Device-Id` on every request so sync
  /// events caused here carry it as `origin` (API.md "Sync events").
  String? deviceId;

  Map<String, String> get _auth => {
    'Authorization': 'Bearer $_key',
    'X-Device-Id': ?deviceId,
  };

  Map<String, String> get _headers => {
    ..._auth,
    'Content-Type': 'application/json',
  };

  static String _id(String id) => Uri.encodeComponent(id);

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, String?>? query,
    Map<String, dynamic>? body,
  }) async {
    final req = http.Request(method, _url(path, query))
      ..headers.addAll(_headers);
    if (body != null) req.body = jsonEncode(body);
    final http.Response r;
    try {
      r = await http.Response.fromStream(await _client.send(req))
          .timeout(requestTimeout);
    } on TimeoutException {
      throw ChatException.timeout;
    } catch (_) {
      throw ChatException.network;
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ChatException.fromHttp(r.statusCode, r.body, headers: r.headers);
    }
    try {
      final decoded = jsonDecode(r.body);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    throw const ChatException(
      ChatErrorKind.server,
      'The ${Brand.serverName} sent an invalid answer',
    );
  }

  static List<Map<String, dynamic>> _list(Object? v) => [
    for (final e in (v is List ? v : const []))
      if (e is Map<String, dynamic>) e,
  ];

  static Conversation _conversation(Map<String, dynamic> j) {
    final c = j['conversation'];
    if (c is Map<String, dynamic>) return Conversation.fromJson(c);
    throw const ChatException(
      ChatErrorKind.server,
      'The ${Brand.serverName} sent an invalid answer',
    );
  }

  // --- capabilities --------------------------------------------------------

  /// The last capabilities fetched, if any.
  Capabilities? get cachedCapabilities => _caps;

  /// `GET /api/capabilities`, cached after the first definite answer.
  ///
  /// - 404 (old bridge): live only, `known: true`, cached.
  /// - Network failure or timeout: live only, `known: false`, not cached.
  /// - 401: throws [ChatException] (`unauthorized`).
  /// - Other HTTP errors: live only, `known: false`, not cached.
  Future<Capabilities> capabilities({bool refresh = false}) {
    if (!refresh && _caps != null && _caps!.known) return Future.value(_caps);
    return _capsPending ??= _fetchCapabilities().whenComplete(
      () => _capsPending = null,
    );
  }

  Future<Capabilities> _fetchCapabilities() async {
    Capabilities caps;
    try {
      caps = Capabilities.fromJson(await _json('GET', '/api/capabilities'));
    } on ChatException catch (e) {
      if (e.status == 404) {
        caps = const Capabilities.liveOnly(known: true);
      } else if (e.kind == ChatErrorKind.unauthorized) {
        rethrow;
      } else {
        caps = const Capabilities.liveOnly(known: false);
      }
    }
    _caps = caps;
    return caps;
  }

  // --- conversations -------------------------------------------------------

  /// Newest `updated` first.
  Future<ConversationPage> listConversations({
    int? limit,
    String? cursor,
    bool? pinned,
  }) async {
    final j = await _json(
      'GET',
      '/api/conversations',
      query: {
        'limit': limit?.toString(),
        'cursor': (cursor == null || cursor.isEmpty) ? null : cursor,
        'pinned': pinned?.toString(),
      },
    );
    return ConversationPage(
      [for (final c in _list(j['conversations'])) Conversation.fromJson(c)],
      j['next_cursor'] is String && (j['next_cursor'] as String).isNotEmpty
          ? j['next_cursor'] as String
          : null,
    );
  }

  /// Without [title] the server names it "New chat" until the first message.
  Future<Conversation> createConversation({String? title}) async =>
      _conversation(
        await _json('POST', '/api/conversations', body: {'title': ?title}),
      );

  /// The conversation with its newest [limit] messages (oldest first).
  Future<ConversationDetail> getConversation(String id, {int? limit}) async {
    final j = await _json(
      'GET',
      '/api/conversations/${_id(id)}',
      query: {'limit': limit?.toString()},
    );
    return ConversationDetail(_conversation(j), [
      for (final m in _list(j['messages'])) ChatMessage.fromJson(m),
    ], j['has_more'] == true);
  }

  /// The [limit] messages just older than [before] (oldest first).
  Future<MessagePage> messages(
    String conversationId, {
    String? before,
    int? limit,
  }) async {
    final j = await _json(
      'GET',
      '/api/conversations/${_id(conversationId)}/messages',
      query: {'before': before, 'limit': limit?.toString()},
    );
    return MessagePage([
      for (final m in _list(j['messages'])) ChatMessage.fromJson(m),
    ], j['has_more'] == true);
  }

  Future<Conversation> renameConversation(String id, String title) async =>
      _conversation(
        await _json(
          'PATCH',
          '/api/conversations/${_id(id)}',
          body: {'title': title},
        ),
      );

  Future<Conversation> setPinned(String id, bool pinned) async => _conversation(
    await _json(
      'PATCH',
      '/api/conversations/${_id(id)}',
      body: {'pinned': pinned},
    ),
  );

  Future<void> deleteConversation(String id) async {
    await _json('DELETE', '/api/conversations/${_id(id)}');
  }

  Future<void> deleteMessage(String conversationId, String messageId) async {
    await _json(
      'DELETE',
      '/api/conversations/${_id(conversationId)}/messages/${_id(messageId)}',
    );
  }

  /// Reports a reply to the bridge (API.md "Reports"); returns the report id.
  /// The bridge only logs it for its operator. A 404 (an older bridge)
  /// throws [ChatException] with kind `notFound`.
  Future<String?> reportMessage({
    required String messageId,
    String? conversationId,
    required String reason,
    String note = '',
    bool hidden = false,
  }) async {
    final j = await _json(
      'POST',
      '/api/report',
      body: {
        'message_id': messageId,
        'conversation_id': ?conversationId,
        'reason': reason,
        if (note.trim().isNotEmpty) 'note': note.trim(),
        'hidden': hidden,
      },
    );
    final id = j['id'];
    return id is String ? id : null;
  }

  /// Title matches first, then message matches. Snippets are plain text.
  Future<List<SearchResult>> search(String query, {int? limit}) async {
    final j = await _json(
      'GET',
      '/api/conversations/search',
      query: {'q': query, 'limit': limit?.toString()},
    );
    return [for (final r in _list(j['results'])) SearchResult.fromJson(r)];
  }

  // --- live calls ----------------------------------------------------------

  /// Posts a finished call's voice turns (and, for calls that were not
  /// linked, its task results). Splits into requests of at most
  /// [ChatLimits.transcriptTurns] turns / [ChatLimits.transcriptTasks] tasks;
  /// turn ids keep a retried post from duplicating turns.
  Future<TranscriptImportResult> saveLiveTranscript(
    String conversationId, {
    String? session,
    required List<LiveTurn> turns,
    List<LiveTask> tasks = const [],
  }) async {
    final limits = _caps?.limits ?? const ChatLimits();
    final turnStep = limits.transcriptTurns.clamp(1, 1 << 20);
    final taskStep = limits.transcriptTasks.clamp(1, 1 << 20);
    var added = 0, skipped = 0;
    Conversation? conversation;
    var ti = 0, ki = 0;
    do {
      final turnBatch = turns.sublist(
        ti,
        (ti + turnStep).clamp(0, turns.length),
      );
      final taskBatch = tasks.sublist(
        ki,
        (ki + taskStep).clamp(0, tasks.length),
      );
      ti += turnBatch.length;
      ki += taskBatch.length;
      final j = await _json(
        'POST',
        '/api/conversations/${_id(conversationId)}/live-transcript',
        body: {
          'session': ?session,
          'turns': [for (final t in turnBatch) t.toJson()],
          if (taskBatch.isNotEmpty)
            'tasks': [for (final t in taskBatch) t.toJson()],
        },
      );
      added += (j['added'] is num) ? (j['added'] as num).round() : 0;
      skipped += (j['skipped'] is num) ? (j['skipped'] as num).round() : 0;
      if (j['conversation'] is Map<String, dynamic>) {
        conversation = Conversation.fromJson(j['conversation']);
      }
    } while (ti < turns.length || ki < tasks.length);
    return TranscriptImportResult(added, skipped, conversation);
  }

  // --- streaming chat ------------------------------------------------------

  /// Sends [text] and streams the reply. Without [conversationId] the server
  /// creates a conversation (see [ChatMetaEvent.createdConversation]).
  ChatStream send({
    String? conversationId,
    required String text,
    ChatEffort? effort,
    String? clientMsgId,
    List<String> attachments = const [],
    bool webSearch = false,
  }) => _stream({
    'conversation_id': ?conversationId,
    'message': {
      'text': text,
      if (attachments.isNotEmpty) 'attachments': attachments,
    },
    'effort': ?effort?.wire,
    'client_msg_id': ?clientMsgId,
    if (webSearch) 'web_search': true,
    // The UI prompt this app renders (see [uiBlocksVersion]); bridges
    // without the feature ignore the field.
    'ui': uiBlocksVersion,
  });

  /// The UI prompt version this app renders, sent as `ui` on `/api/chat`
  /// and `/api/session`. 2 = OpenUI's chat library is the only rich format
  /// (the bridge sends markdown rules plus `openui-chat-prompt.md`); older
  /// hermes-ui, hermes-html and artifact fences in saved chats still render.
  static const uiBlocksVersion = 2;

  /// Answers the conversation's newest user message again. The server first
  /// deletes the text replies after it.
  ChatStream retry({required String conversationId, ChatEffort? effort}) =>
      _stream({
        'conversation_id': conversationId,
        'effort': ?effort?.wire,
        'retry': true,
        'ui': uiBlocksVersion,
      });

  ChatStream _stream(Map<String, dynamic> body) {
    final s = ChatStream._();
    final req =
        http.AbortableRequest(
            'POST',
            _url('/api/chat'),
            abortTrigger: s._abort.future,
          )
          ..headers.addAll(_headers)
          ..headers['Accept'] = 'text/event-stream'
          ..body = jsonEncode(body);
    _run(s, req);
    return s;
  }

  /// `GET /api/chat/{messageId}/stream`: the events after [lastEventId]
  /// (the whole reply, `meta` included, when null or 0), then the live ones.
  /// Needs `resumable_stream`. A reply that ended long ago comes back as a
  /// [ChatSnapshotEvent] plus its terminal event.
  ChatStream resume(String messageId, {int? lastEventId}) {
    final s = ChatStream._();
    final req =
        http.AbortableRequest(
            'GET',
            _url('/api/chat/${_id(messageId)}/stream'),
            abortTrigger: s._abort.future,
          )
          ..headers.addAll(_auth)
          ..headers['Accept'] = 'text/event-stream';
    if (lastEventId != null && lastEventId > 0) {
      req.headers['Last-Event-ID'] = '$lastEventId';
    }
    _run(s, req);
    return s;
  }

  /// `POST /api/chat/{messageId}/stop` (needs `stop_endpoint`). Stopping a
  /// reply that already ended is harmless ([StopResult.stopped] is false).
  Future<StopResult> stopReply(String messageId) async => StopResult.fromJson(
    await _json('POST', '/api/chat/${_id(messageId)}/stop'),
  );

  // --- push ----------------------------------------------------------------

  /// `POST /api/push/register` (capability `push: "unifiedpush"`): where the
  /// bridge sends a push when a reply or live task ends while no client is
  /// reading it. [deviceId] is stable for the install; register again
  /// whenever the distributor hands out a new [endpoint]. Returns the
  /// bridge's `previews` setting (false: pushes carry no title or text).
  Future<bool> registerPush({
    required String deviceId,
    required String endpoint,
    String? appVersion,
  }) async {
    final j = await _json(
      'POST',
      '/api/push/register',
      body: {
        'device_id': deviceId,
        'endpoint': endpoint,
        'app_version': ?appVersion,
      },
    );
    return j['previews'] != false;
  }

  /// `DELETE /api/push/register/{device_id}`: stop pushing to this install
  /// (notifications turned off, sign out). Harmless twice; 404 counts as done.
  Future<void> unregisterPush(String deviceId) async {
    try {
      await _json('DELETE', '/api/push/register/${_id(deviceId)}');
    } on ChatException catch (e) {
      if (e.kind != ChatErrorKind.notFound) rethrow;
    }
  }

  /// `POST /api/push/test`: one `test` push to this install. True when the
  /// distributor accepted it.
  Future<bool> testPush(String deviceId) async {
    final j = await _json(
      'POST',
      '/api/push/test',
      body: {'device_id': deviceId},
    );
    return j['delivered'] == true;
  }

  // --- events (API.md "Events") -------------------------------------------

  /// `GET /api/events` (capability `events`): the bridge's notification
  /// stream. With [after] it resumes after that event id, otherwise it starts
  /// with new events. [deviceId] (the UnifiedPush id) tells the bridge not to
  /// push to this device while the stream is open. A stream silent for more
  /// than twice [heartbeat] plus 20 s fails with a timeout.
  EventsConnection events({int? after, int heartbeat = 80, String? deviceId}) {
    final c = EventsConnection.internal();
    final req =
        http.AbortableRequest(
            'GET',
            _url('/api/events', {
              'heartbeat': '$heartbeat',
              'device_id': deviceId,
            }),
            abortTrigger: c.abort.future,
          )
          ..headers.addAll(_auth)
          ..headers['Accept'] = 'text/event-stream';
    if (after != null && after > 0) req.headers['Last-Event-ID'] = '$after';
    unawaited(_runEvents(c, req, Duration(seconds: heartbeat * 2 + 20)));
    return c;
  }

  Future<void> _runEvents(
    EventsConnection c,
    http.BaseRequest req,
    Duration idleLimit,
  ) async {
    final http.StreamedResponse resp;
    try {
      resp = await _client.send(req).timeout(connectTimeout);
    } on TimeoutException {
      c.fail(ChatException.timeout);
      return;
    } catch (_) {
      c.fail(ChatException.network);
      return;
    }
    if (c.closed) {
      resp.stream.listen(null, onError: (_) {}).cancel().ignore();
      return;
    }
    if (resp.statusCode != 200) {
      var text = '';
      try {
        text = await resp.stream.bytesToString().timeout(requestTimeout);
      } catch (_) {}
      c.fail(
        ChatException.fromHttp(resp.statusCode, text, headers: resp.headers),
      );
      return;
    }
    void arm() {
      c.idle?.cancel();
      c.idle = Timer(idleLimit, () => c.fail(ChatException.timeout));
    }

    arm();
    c.sub = resp.stream
        .map((chunk) {
          arm(); // Heartbeat comments count as life.
          return chunk;
        })
        .transform(const SseDecoder())
        .listen(
          (e) {
            final event = BridgeEvent.fromSse(e);
            if (event != null) c.add(event);
          },
          onError: (Object _) => c.fail(ChatException.cutOff),
          onDone: () => c.fail(ChatException.cutOff),
          cancelOnError: true,
        );
  }

  /// `GET /api/events?once=1`: the events after [after] (the background
  /// check). `after: 0` asks from the start, which on a first run only tells
  /// where the stream is.
  Future<EventsPage> eventsSince(int after) async => EventsPage.fromJson(
    await _json('GET', '/api/events', query: {'after': '$after', 'once': '1'}),
  );

  /// `GET /api/usage/limits`: every account's quota. [refresh] asks the
  /// providers again (the bridge allows that every 15 s).
  Future<UsageLimits> usageLimits({bool refresh = false}) async =>
      UsageLimits.fromJson(
        await _json(
          'GET',
          '/api/usage/limits',
          query: {'refresh': refresh ? '1' : null},
        ),
      );

  /// `POST /api/events/test`: one `test` event; returns how many streams are
  /// open on the bridge (0: nobody will hear it now).
  Future<int> testEvents() async {
    final j = await _json('POST', '/api/events/test');
    return j['readers'] is num ? (j['readers'] as num).toInt() : 0;
  }

  Future<void> _run(ChatStream s, http.BaseRequest req) async {
    final http.StreamedResponse resp;
    try {
      resp = await _client.send(req).timeout(connectTimeout);
    } on TimeoutException {
      s._fail(ChatException.timeout);
      return;
    } catch (_) {
      s._fail(ChatException.network);
      return;
    }
    if (s.closed) {
      resp.stream.listen(null, onError: (_) {}).cancel().ignore();
      return;
    }

    if (resp.statusCode != 200) {
      String text = '';
      try {
        text = await resp.stream.bytesToString().timeout(requestTimeout);
      } catch (_) {}
      s._fail(
        ChatException.fromHttp(resp.statusCode, text, headers: resp.headers),
      );
      return;
    }
    final type = resp.headers['content-type'] ?? '';
    if (!type.contains('text/event-stream')) {
      resp.stream.listen(null, onError: (_) {}).cancel().ignore();
      s._fail(
        const ChatException(
          ChatErrorKind.server,
          'The ${Brand.serverName} sent an invalid answer',
        ),
      );
      return;
    }

    void armIdle() {
      s._idle?.cancel();
      s._idle = Timer(idleTimeout, () => s._fail(ChatException.timeout));
    }

    armIdle();
    var terminal = false;
    s._sub = resp.stream
        .map((chunk) {
          armIdle();
          return chunk;
        })
        .transform(const SseDecoder())
        .listen(
          (e) {
            final event = parseChatEvent(e);
            if (event == null) return;
            s._add(event, int.tryParse(e.id?.trim() ?? ''));
            if (event is ChatDoneEvent ||
                event is ChatFailedEvent ||
                event is ChatStoppedEvent) {
              terminal = true;
              s._finish();
            }
          },
          onError: (Object _) {
            if (!terminal) s._fail(ChatException.cutOff);
          },
          onDone: () {
            if (!terminal) s._fail(ChatException.cutOff);
          },
          cancelOnError: true,
        );
  }

  /// Maps one SSE event to a [ChatEvent]; unknown events and bad JSON are null.
  static ChatEvent? parseChatEvent(SseEvent e) {
    Map<String, dynamic> j;
    try {
      final d = jsonDecode(e.data);
      if (d is! Map<String, dynamic>) return null;
      j = d;
    } catch (_) {
      return null;
    }
    return switch (e.event) {
      'meta' => ChatMetaEvent.fromJson(j),
      'delta' =>
        j['text'] is String ? ChatDeltaEvent(j['text'] as String) : null,
      'status' => ChatProgressEvent(ChatProgress.fromJson(j)),
      'step.start' || 'step.end' => switch (ReplyStep.fromJson(j['step'])) {
        final s? => ChatStepEvent(s, end: e.event == 'step.end'),
        null => null,
      },
      'step.delta' =>
        j['id'] is String && j['text'] is String
            ? ChatStepDeltaEvent(j['id'] as String, j['text'] as String)
            : null,
      'done' => ChatDoneEvent.fromJson(j),
      'error' => ChatFailedEvent.fromJson(j),
      'stopped' => ChatStoppedEvent.fromJson(j),
      'snapshot' => ChatSnapshotEvent.fromJson(j),
      _ => null,
    };
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

/// The answer of `POST /api/chat/{id}/stop`.
class StopResult {
  const StopResult({
    required this.stopped,
    this.status,
    this.text,
    this.conversationId,
    this.messageId,
  });

  factory StopResult.fromJson(Map<String, dynamic> j) => StopResult(
    stopped: j['stopped'] == true,
    status: j['status'] is String ? MessageStatus.fromWire(j['status']) : null,
    text: j['text'] is String ? j['text'] as String : null,
    conversationId: j['conversation_id'] is String
        ? j['conversation_id'] as String
        : null,
    messageId: j['message_id'] is String ? j['message_id'] as String : null,
  );

  /// True when this call stopped a running reply; false when it had ended.
  final bool stopped;

  /// The saved status (`cancelled` → stopped, or the final one).
  final MessageStatus? status;

  /// The saved text.
  final String? text;
  final String? conversationId;
  final String? messageId;
}
