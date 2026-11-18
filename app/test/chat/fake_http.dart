import 'dart:async';
import 'dart:convert';

import 'package:tove_chat/src/chat/chat.dart';
import 'package:http/http.dart' as http;

const chatTestKey = 'chat-test-key-not-a-secret-000';
final chatTestBase = Uri.parse('https://bridge.test:9476/');

class FakeRequest {
  FakeRequest(this.method, this.url, this.headers, this.rawBody);
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String rawBody;
  bool aborted = false;

  String get path => url.path;
  Map<String, String> get query => url.queryParameters;
  Map<String, dynamic> get body =>
      rawBody.isEmpty ? const {} : jsonDecode(rawBody) as Map<String, dynamic>;
}

typedef FakeHandler = FutureOr<http.StreamedResponse> Function(FakeRequest req);

/// A fake bridge behind `http.BaseClient`: routes by "METHOD /path".
class FakeHttp extends http.BaseClient {
  final requests = <FakeRequest>[];
  final routes = <String, FakeHandler>{};

  /// Thrown for every request when set (simulates no network).
  Object? failWith;

  void on(String route, FakeHandler h) => routes[route] = h;

  FakeRequest last(String route) =>
      requests.lastWhere((r) => '${r.method} ${r.path}' == route);

  int count(String route) =>
      requests.where((r) => '${r.method} ${r.path}' == route).length;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final raw = await request.finalize().bytesToString();
    final req = FakeRequest(
      request.method,
      request.url,
      Map.of(request.headers),
      raw,
    );
    requests.add(req);
    if (request case http.Abortable(:final abortTrigger?)) {
      abortTrigger.whenComplete(() => req.aborted = true).ignore();
    }
    if (failWith != null) throw failWith!;
    final h = routes['${request.method} ${request.url.path}'];
    if (h == null) {
      return http.StreamedResponse(
        Stream.value(utf8.encode('404: Not Found')),
        404,
        headers: {'content-type': 'text/plain'},
      );
    }
    return h(req);
  }
}

http.StreamedResponse jsonResponse(
  Object body, {
  int status = 200,
  Map<String, String> headers = const {},
}) => http.StreamedResponse(
  Stream.value(utf8.encode(jsonEncode(body))),
  status,
  headers: {'content-type': 'application/json', ...headers},
);

http.StreamedResponse errorResponse(
  int status,
  String code, {
  String? message,
  Map<String, dynamic> extra = const {},
  Map<String, String> headers = const {},
}) => jsonResponse(
  {'error': code, 'code': code, 'message': message ?? code, ...extra},
  status: status,
  headers: headers,
);

/// An SSE body the test pushes into; records whether the client cancelled.
class SseBody {
  SseBody() {
    controller = StreamController<List<int>>(onCancel: () => cancelled = true);
  }

  late final StreamController<List<int>> controller;
  bool cancelled = false;

  http.StreamedResponse response() => http.StreamedResponse(
    controller.stream,
    200,
    headers: {'content-type': 'text/event-stream; charset=utf-8'},
  );

  void raw(String s) => controller.add(utf8.encode(s));
  void bytes(List<int> b) => controller.add(b);
  void event(String name, Map<String, dynamic> data) =>
      raw('event: $name\ndata: ${jsonEncode(data)}\n\n');
  void meta({
    String conv = 'conv1',
    String msg = 'a1',
    String user = 'u1',
    String? client,
    bool created = false,
    String title = 'Hello',
  }) => event('meta', {
    'conversation_id': conv,
    'message_id': msg,
    'user_message_id': user,
    'client_msg_id': client,
    'created_conversation': created,
    'title': title,
  });
  void delta(String t) => event('delta', {'text': t});

  /// An event with an SSE `id:` line (resumable bridges).
  void idEvent(int id, String name, Map<String, dynamic> data) =>
      raw('id: $id\nevent: $name\ndata: ${jsonEncode(data)}\n\n');

  void done({
    String conv = 'conv1',
    String msg = 'a1',
    String title = 'Hello',
    bool titlePending = false,
  }) => event('done', {
    'conversation_id': conv,
    'message_id': msg,
    'finish_reason': 'stop',
    'usage': {'prompt_tokens': 1, 'completion_tokens': 2, 'total_tokens': 3},
    'title': title,
    'title_pending': titlePending,
  });
  Future<void> close() => controller.close();
}

Map<String, dynamic> conversationJson(
  String id, {
  String title = 'Chat',
  bool pinned = false,
  int updated = 1794691024435,
  String kind = 'text',
}) => {
  'id': id,
  'title': title,
  'title_source': 'auto',
  'pinned': pinned,
  'kind': kind,
  'created': 1794691021626,
  'updated': updated,
  'preview': 'preview of $id',
  'message_count': 2,
};

Map<String, dynamic> messageJson(
  String id, {
  String conv = 'conv1',
  String role = 'user',
  String text = 'hi',
  String source = 'text',
  String status = 'complete',
  Map<String, dynamic> meta = const {},
}) => {
  'id': id,
  'conversation_id': conv,
  'role': role,
  'text': text,
  'source': source,
  'status': status,
  'created': 1794691021626,
  'client_id': null,
  'meta': meta,
};

const fullCapabilities = <String, dynamic>{
  'version': 2,
  'chat': true,
  'history': true,
  'search': true,
  'effort': true,
  'efforts': ['instant', 'medium', 'high'],
  'attachments': false,
  'language': false,
  'status_events': true,
  'live_link': true,
  'live_transcript': true,
  'titles': 'hermes',
  'error_codes': true,
  'stream': 'sse',
  'voices': ['cove', 'sol'],
  'default_voice': 'cove',
  'limits': {
    'message_chars': 8000,
    'title_chars': 120,
    'query_chars': 200,
    'page_max': 100,
    'messages_page_max': 200,
    'concurrent_chats': 2,
    'transcript_turns': 500,
    'transcript_tasks': 50,
    'task_chars': 32000,
    'keepalive_s': 15.0,
    'chat_timeout_s': 900,
    'live_jobs': 2,
  },
};

/// [fullCapabilities] plus the 15 Nov 2026 resumable-stream and push flags.
const resumableCapabilities = <String, dynamic>{
  ...fullCapabilities,
  'resumable_stream': true,
  'stop_endpoint': true,
  'disconnect_cancels': false,
  'push': 'unifiedpush',
  'push_previews': true,
};

ChatApi fakeApi(FakeHttp http, {Duration? idleTimeout}) => ChatApi(
  baseUrl: chatTestBase,
  accessKey: chatTestKey,
  client: http,
  requestTimeout: const Duration(seconds: 2),
  connectTimeout: const Duration(seconds: 2),
  idleTimeout: idleTimeout ?? const Duration(seconds: 5),
);

/// Lets queued microtasks and stream events run.
Future<void> settle([int rounds = 5]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
