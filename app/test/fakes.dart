import 'dart:async';
import 'dart:convert';

import 'package:tove_chat/src/bridge/bridge_api.dart';
import 'package:tove_chat/src/config.dart';
import 'package:tove_chat/src/platform/call_platform.dart';
import 'package:tove_chat/src/rtc/voice_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const testKey = 'test-key-not-a-real-secret-0000';
const fastTimings = CallTimings(
  microphone: Duration(seconds: 2),
  nativeStart: Duration(milliseconds: 300),
  iceGathering: Duration(milliseconds: 10),
  session: Duration(seconds: 2),
  connect: Duration(milliseconds: 400),
  disconnectGrace: Duration(milliseconds: 100),
  stop: Duration(milliseconds: 300),
  request: Duration(milliseconds: 500),
  jobPoll: Duration(milliseconds: 5),
  levelPoll: Duration(milliseconds: 20),
  maxPollFailures: 3,
  farewellReply: Duration(milliseconds: 300),
  farewellMin: Duration(milliseconds: 100),
  farewellQuiet: Duration(milliseconds: 150),
  farewellMax: Duration(milliseconds: 600),
);

/// A recorded bridge request.
class Req {
  Req(this.method, this.path, this.body, this.auth);
  final String method;
  final String path;
  final Map<String, dynamic> body;
  final String? auth;
}

/// Fake gpt-live-bridge behind an http MockClient.
class FakeBridge {
  final List<Req> requests = [];

  /// When set, `/api/session` waits for it.
  Completer<void>? holdSession;
  int sessionStatus = 200;

  /// Error body for a failing `/api/session` (API v2 shape).
  Map<String, dynamic> sessionError = const {'error': 'could not start'};
  int delegateStatus = 200;
  int jobs = 0;

  /// Job id -> remaining "running" polls before [jobResult].
  final Map<String, int> runningPolls = {};
  int defaultRunningPolls = 1;
  String jobResult = 'done';
  String jobAnswer = 'The **disk** is 40% full.';

  /// Job id -> the `status_event` its running polls report (API.md
  /// `job_progress`), if any.
  final Map<String, Map<String, dynamic>> jobStatusEvents = {};

  late final http.Client client = MockClient(_handle);

  /// Behave like an API v2 bridge (capabilities, chat, history).
  bool chatEnabled = false;
  final List<Map<String, dynamic>> conversations = [];
  final Map<String, List<Map<String, dynamic>>> stored = {};
  String reply = 'The **disk** is 40% full.';

  /// Results for `/api/conversations/search` (API v2 shape).
  List<Map<String, dynamic>> searchHits = [];
  int _ids = 0;

  Map<String, dynamic> _conv(String id, String title) => {
    'id': id,
    'title': title,
    'title_source': 'auto',
    'pinned': false,
    'kind': 'text',
    'created': 1794691021626,
    'updated': 1794691021626 + _ids,
    'preview': '',
    'message_count': stored[id]?.length ?? 0,
  };

  Map<String, dynamic> _msg(
    String conv,
    String role,
    String text, {
    String source = 'text',
  }) => {
    'id': 'm${++_ids}',
    'conversation_id': conv,
    'role': role,
    'text': text,
    'source': source,
    'status': 'complete',
    'created': 1794691021626 + _ids,
    'client_id': null,
    'meta': <String, dynamic>{},
  };

  http.Response? _chat(http.Request r, Map<String, dynamic> body) {
    http.Response json(Object o, [int status = 200]) => http.Response(
      jsonEncode(o),
      status,
      headers: {'content-type': 'application/json'},
    );
    final path = r.url.path;
    if (path == '/api/capabilities') {
      if (!chatEnabled) return http.Response('404: Not Found', 404);
      return json({
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
        'titles': 'simple',
        'error_codes': true,
        'stream': 'sse',
        'voices': ['cove', 'juniper'],
        'default_voice': 'cove',
        'limits': {'message_chars': 8000},
      });
    }
    if (!chatEnabled) return null;
    if (path == '/api/conversations' && r.method == 'GET') {
      return json({'conversations': conversations, 'next_cursor': null});
    }
    if (path == '/api/conversations' && r.method == 'POST') {
      final c = _conv('c${++_ids}', 'New chat');
      conversations.insert(0, c);
      stored[c['id'] as String] = [];
      return json({'conversation': c}, 201);
    }
    if (path == '/api/conversations/search') {
      return json({'results': searchHits});
    }
    final m = RegExp(r'^/api/conversations/([^/]+)(/live-transcript)?$')
        .firstMatch(path);
    if (m != null && m[2] != null) {
      final id = m[1]!;
      final turns = (body['turns'] as List).cast<Map<String, dynamic>>();
      for (final t in turns) {
        stored[id]!.add(
          _msg(id, t['role'] as String, t['text'] as String, source: 'voice'),
        );
      }
      return json({
        'added': turns.length,
        'skipped': 0,
        'conversation': conversations.firstWhere((c) => c['id'] == id),
      });
    }
    if (m != null && m[2] == null && r.method == 'PATCH') {
      final c = conversations.firstWhere((c) => c['id'] == m[1]);
      for (final k in ['title', 'pinned']) {
        if (body.containsKey(k)) c[k] = body[k];
      }
      return json({'conversation': c});
    }
    if (m != null && r.method == 'GET') {
      final id = m[1]!;
      return json({
        'conversation': conversations.firstWhere((c) => c['id'] == id),
        'messages': stored[id] ?? [],
        'has_more': false,
      });
    }
    if (path == '/api/chat') {
      var id = body['conversation_id'] as String?;
      final text = ((body['message'] as Map?)?['text'] ?? '') as String;
      if (id == null) {
        final c = _conv('c${++_ids}', text);
        conversations.insert(0, c);
        stored[c['id'] as String] = [];
        id = c['id'] as String;
      }
      final user = _msg(id, 'user', text);
      final answer = _msg(id, 'assistant', reply);
      stored[id]!
        ..add(user)
        ..add(answer);
      String ev(String name, Object data) =>
          'event: $name\ndata: ${jsonEncode(data)}\n\n';
      final half = reply.length ~/ 2;
      return http.Response(
        ev('meta', {
              'conversation_id': id,
              'message_id': answer['id'],
              'user_message_id': user['id'],
              'client_msg_id': body['client_msg_id'],
              'created_conversation': true,
              'title': text,
            }) +
            ev('delta', {'text': reply.substring(0, half)}) +
            ev('delta', {'text': reply.substring(half)}) +
            ev('done', {
              'conversation_id': id,
              'message_id': answer['id'],
              'finish_reason': 'stop',
              'usage': null,
              'title': text,
              'title_pending': false,
            }),
        200,
        headers: {'content-type': 'text/event-stream; charset=utf-8'},
      );
    }
    return null;
  }

  /// Requests to [path] or below it; `/api/session` itself excludes its
  /// warm-up (`/api/session/warm`, round 8).
  List<Req> to(String path) => requests
      .where(
        (r) =>
            path == '/api/session' ? r.path == path : r.path.startsWith(path),
      )
      .toList();

  BridgeApi api() => BridgeApi(
    baseUrl: Uri.parse('https://bridge.test:9476'),
    accessKey: testKey,
    client: client,
  );

  Future<http.Response> _handle(http.Request r) async {
    final body = r.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(r.body) as Map<String, dynamic>;
    requests.add(Req(r.method, r.url.path, body, r.headers['Authorization']));
    final chat = _chat(r, body);
    if (chat != null) return chat;
    http.Response json(Object o, [int status = 200]) => http.Response(
      jsonEncode(o),
      status,
      headers: {'content-type': 'application/json'},
    );
    switch (r.url.path) {
      case '/api/session/warm':
        return json({'warm': true, 'ready': false, 'ttl_s': 180});
      case '/api/session':
        if (holdSession != null) await holdSession!.future;
        if (sessionStatus != 200) {
          return json(sessionError, sessionStatus);
        }
        return json({
          'session': 'sid1',
          'answer': 'v=0 answer',
          'conversation_id': body['conversation_id'],
        });
      case '/api/delegate':
        if (delegateStatus != 200) {
          return json({'error': 'busy'}, delegateStatus);
        }
        final id = 'job${++jobs}';
        runningPolls[id] = defaultRunningPolls;
        return json({'job': id});
      case '/api/stop':
        return json({'ok': true});
    }
    if (r.url.path.startsWith('/api/job/')) {
      final id = r.url.pathSegments.last;
      final left = runningPolls[id];
      if (left == null) return json({'error': 'no such job'}, 404);
      if (left > 0) {
        runningPolls[id] = left - 1;
        return json({
          'status': 'running',
          'answer': '',
          'seconds': 3,
          if (jobStatusEvents[id] != null) 'status_event': jobStatusEvents[id],
        });
      }
      return json({
        'status': jobResult,
        'answer': jobResult == 'done' ? jobAnswer : '',
        'seconds': 7,
      });
    }
    return json({'error': 'not found'}, 404);
  }
}

class FakeTransport implements VoiceTransport {
  final events$ = StreamController<Map<String, dynamic>>.broadcast();
  final link$ = StreamController<TransportLink>.broadcast();
  final List<Map<String, dynamic>> sent = [];
  Completer<void>? holdMic;
  Object? micError;
  bool muted = false;
  bool closed = false;
  bool channelOpen = true;
  bool speakerRoute = false;
  final List<bool> speaker = [];
  String? answer;
  final List<String> calls = [];
  AudioLevels levels = const AudioLevels(input: 0.1, output: 0.0);

  void emit(Map<String, dynamic> m) => events$.add(m);

  @override
  Future<void> openMicrophone() async {
    calls.add('mic');
    if (holdMic != null) await holdMic!.future;
    if (micError != null) throw micError!;
  }

  @override
  Future<String> createOffer({required Duration iceTimeout}) async {
    calls.add('offer');
    return 'v=0 offer';
  }

  @override
  Future<void> applyAnswer(String sdp) async {
    calls.add('answer');
    answer = sdp;
  }

  @override
  void setMuted(bool m) => muted = m;

  @override
  bool get supportsSpeakerRoute => speakerRoute;

  @override
  Future<void> setSpeaker(bool on) async => speaker.add(on);

  @override
  Stream<Map<String, dynamic>> get events => events$.stream;

  @override
  Stream<TransportLink> get link => link$.stream;

  @override
  bool send(Map<String, dynamic> message) {
    if (closed || !channelOpen) return false;
    sent.add(message);
    return true;
  }

  @override
  Future<AudioLevels> readLevels() async => levels;

  @override
  Future<void> close() async {
    calls.add('close');
    closed = true;
  }
}

class FakePlatform implements CallPlatform {
  FakePlatform({this.supported = true});

  @override
  final bool supported;

  final List<String> calls = [];
  Completer<void>? holdStart;
  Object? startError;
  String? startWarning;
  bool Function(bool)? onMute;
  void Function()? onEnd;

  @override
  String? get backgroundNote => null;

  @override
  void setHandlers({
    required bool Function(bool muted) onMute,
    required void Function() onEnd,
  }) {
    this.onMute = onMute;
    this.onEnd = onEnd;
  }

  @override
  Future<String?> startCall({required bool muted}) async {
    calls.add('start:$muted');
    if (holdStart != null) await holdStart!.future;
    if (startError != null) throw startError!;
    return startWarning;
  }

  @override
  Future<void> updateCall({required bool muted}) async =>
      calls.add('update:$muted');

  @override
  Future<void> endCall() async => calls.add('end');
}

/// Lets pending microtasks and short timers run.
Future<void> settle([int ms = 30]) =>
    Future<void>.delayed(Duration(milliseconds: ms));
