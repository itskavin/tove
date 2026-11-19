import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../brand.dart';
import '../chat/chat_api.dart' show ChatApi;

/// A failed bridge request. [status] is the HTTP status, or null when the
/// server was not reached at all.
class BridgeException implements Exception {
  const BridgeException(
    this.message, {
    this.status,
    this.code,
    this.retryAfter,
  });

  final String message;
  final int? status;

  /// The server's machine-readable `error` value, such as `usage_limit`,
  /// `login_expired` or `busy`.
  final String? code;

  /// From `retry_after_s` on usage-limit errors.
  final Duration? retryAfter;

  bool get unauthorized => status == 401;
  bool get busy => status == 429 && code != 'usage_limit';
  bool get unreachable => status == null;

  /// GPT-Live's usage or rate limit was reached (`429 usage_limit`).
  bool get usageLimit => code == 'usage_limit';

  /// The voice service's ChatGPT login was revoked (`502 login_expired`).
  bool get loginExpired => code == 'login_expired';

  @override
  String toString() => message;
}

class SessionAnswer {
  const SessionAnswer({
    required this.session,
    required this.answer,
    this.conversationId,
  });
  final String session;
  final String answer;

  /// The chat the call is linked to (API v2), or null.
  final String? conversationId;
}

enum JobState { running, done, failed }

class JobStatus {
  const JobStatus({
    required this.state,
    required this.answer,
    required this.seconds,
    this.markdown,
    this.statusEvent,
  });
  final JobState state;

  /// Hermes' newest tool step while the job runs (`status_event`, shaped like
  /// the chat `status` event), or null when the bridge sent none.
  final Map<String, dynamic>? statusEvent;

  /// Voice-ready plain text.
  final String answer;

  /// Hermes' original markdown (API v2), for the live canvas.
  final String? markdown;
  final int seconds;
}

/// The HTTP side of Tove (`gpt-live-bridge.py`). The server only brokers
/// SDP and runs delegated Hermes tasks; audio flows peer to peer.
class BridgeApi {
  BridgeApi({
    required Uri baseUrl,
    required String accessKey,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 15),
  }) : _base = _normalise(baseUrl),
       _key = accessKey,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final Uri _base;
  final String _key;
  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;

  static Uri _normalise(Uri u) {
    final path = u.path.endsWith('/')
        ? u.path.substring(0, u.path.length - 1)
        : u.path;
    return u.replace(path: path, query: null, fragment: null);
  }

  /// Parses user input into a bridge URL, or returns null if it is not one.
  static Uri? parseUrl(String input) {
    final text = input.trim();
    if (text.isEmpty) return null;
    final u = Uri.tryParse(text.contains('://') ? text : 'https://$text');
    if (u == null || u.host.isEmpty) return null;
    if (u.scheme != 'https' && u.scheme != 'http') return null;
    return u;
  }

  Uri _url(String path) => _base.replace(path: '${_base.path}$path');

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $_key',
    'Content-Type': 'application/json',
  };

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration? timeout,
  }) async {
    final http.Response r;
    try {
      final future = method == 'GET'
          ? _client.get(_url(path), headers: _headers)
          : _client.post(_url(path), headers: _headers, body: jsonEncode(body));
      r = await future.timeout(timeout ?? requestTimeout);
    } on TimeoutException {
      throw const BridgeException(
        'The ${Brand.serverName} did not answer in time',
      );
    } catch (_) {
      throw const BridgeException('Could not reach the ${Brand.serverName}');
    }
    if (r.statusCode == 401) {
      throw const BridgeException('Wrong or missing access key', status: 401);
    }
    Map<String, dynamic> json = const {};
    try {
      final decoded = jsonDecode(r.body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {}
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw errorFrom(r.statusCode, json);
    }
    return json;
  }

  /// Builds the exception for an error response body.
  static BridgeException errorFrom(int status, Map<String, dynamic> json) {
    // API v2: `code` is the stable machine code; `error` holds the old human
    // text on old routes and equals `code` on new ones (API.md, deviation 1).
    String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
    final code = str(json['code']) ?? str(json['error']);
    final legacy = str(json['error']);
    final retry = json['retry_after_s'];
    final human = legacy != null && legacy != code ? legacy : null;
    return BridgeException(
      human ?? str(json['message']) ?? code ?? 'HTTP $status',
      status: status,
      code: code,
      retryAfter: retry is num && retry > 0
          ? Duration(seconds: retry.round())
          : null,
    );
  }

  /// Checks the key without side effects: an unknown job is 404 when the key
  /// is right and 401 when it is wrong.
  Future<void> verifyKey() async {
    try {
      await _send('GET', '/api/job/check/check');
    } on BridgeException catch (e) {
      if (e.status == 404) return;
      rethrow;
    }
  }

  /// `POST /api/session/warm` (round 8): the bridge prepares a live session
  /// ahead of a likely call; free (no realtime session). False when the
  /// bridge has no warm start (an older bridge's 404, another backend).
  Future<bool> warmSession() async {
    try {
      final j = await _send(
        'POST',
        '/api/session/warm',
        body: const {},
        timeout: const Duration(seconds: 6),
      );
      return j['warm'] == true;
    } on BridgeException {
      return false;
    }
  }

  Future<SessionAnswer> createSession({
    required String offer,
    required String voice,
    String? conversationId,
    Duration? timeout,
  }) async {
    final j = await _send(
      'POST',
      '/api/session',
      body: {
        'offer': offer,
        'voice': voice,
        'conversation_id': ?conversationId,
        // Task results of this call render in this app: same UI prompt.
        'ui': ChatApi.uiBlocksVersion,
      },
      timeout: timeout,
    );
    final session = j['session'], answer = j['answer'];
    if (session is! String || answer is! String || session.isEmpty) {
      throw const BridgeException(
        'The ${Brand.serverName} sent an invalid answer',
      );
    }
    final cid = j['conversation_id'];
    return SessionAnswer(
      session: session,
      answer: answer,
      conversationId: cid is String && cid.isNotEmpty ? cid : null,
    );
  }

  /// Starts a Hermes task for the call [session]. [context] is the call's
  /// newest transcript turns (`{role: user|assistant, text}`, oldest first):
  /// the voice model hands over only its task text, so Hermes would not
  /// know what the call was about. [location] as on `/api/chat`.
  Future<String> delegate({
    required String session,
    required String text,
    List<Map<String, String>> context = const [],
    Map<String, Object?>? location,
  }) async {
    final j = await _send(
      'POST',
      '/api/delegate',
      body: {
        'session': session,
        'text': text,
        if (context.isNotEmpty) 'context': context,
        'location': ?location,
      },
    );
    final job = j['job'];
    if (job is! String || job.isEmpty) {
      throw const BridgeException(
        'The ${Brand.serverName} sent an invalid job',
      );
    }
    return job;
  }

  Future<JobStatus> job({required String session, required String job}) async {
    final j = await _send(
      'GET',
      '/api/job/${Uri.encodeComponent(session)}/${Uri.encodeComponent(job)}',
    );
    final state = switch (j['status']) {
      'running' => JobState.running,
      'done' => JobState.done,
      _ => JobState.failed,
    };
    final secs = j['seconds'];
    final md = j['markdown'];
    final ev = j['status_event'];
    return JobStatus(
      state: state,
      answer: (j['answer'] ?? '').toString(),
      markdown: md is String && md.trim().isNotEmpty ? md : null,
      seconds: secs is num ? secs.round() : 0,
      statusEvent: ev is Map<String, dynamic> ? ev : null,
    );
  }

  Future<void> stop({required String session, Duration? timeout}) async {
    await _send(
      'POST',
      '/api/stop',
      body: {'session': session},
      timeout: timeout,
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
