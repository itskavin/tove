import 'dart:convert';

import '../bridge/bridge_api.dart';
import '../brand.dart';

/// What went wrong, in terms the UI can act on. Codes come from
/// `infra/core/gpt-live-bridge/API.md` ("read `code`").
enum ChatErrorKind {
  /// 429 `usage_limit`: the ChatGPT plan's limit. [ChatException.retryAfter]
  /// holds the wait when the server knows it.
  usageLimit,

  /// 502 `login_expired`: the server's ChatGPT login must be renewed by the
  /// operator. Not the app's key (that is [unauthorized]).
  loginExpired,

  /// 401: the app's access key is wrong or missing.
  unauthorized,

  /// 429 `busy` (two replies already streaming) or `hermes_busy`.
  busy,

  /// The server could not be reached, the connection dropped, or it stopped
  /// answering in time.
  network,

  /// 404 `not_found`: the chat or message no longer exists.
  notFound,

  /// 400/409/413: the request was refused as invalid (too long, duplicate…).
  invalid,

  /// The feature is off: an old bridge, `chat: false`, or 503
  /// `history_unavailable` / `hermes_unconfigured`.
  unavailable,

  /// Hermes itself failed while replying (`hermes_error`, `hermes_auth`,
  /// `timeout`, `hermes_incomplete`, …).
  hermes,

  /// Any other server failure or an unreadable answer.
  server,
}

/// A failed chat request. Extends [BridgeException] so existing handling of
/// `unauthorized` / `unreachable` keeps working.
class ChatException extends BridgeException {
  const ChatException(
    this.kind,
    super.message, {
    super.status,
    super.code,
    super.retryAfter,
  });

  /// [code] is the bridge's stable machine code, when it sent one;
  /// [retryAfter] the usage-limit wait, when known.
  final ChatErrorKind kind;

  /// Whether sending the same thing again later may work.
  bool get retryable => switch (kind) {
    ChatErrorKind.network ||
    ChatErrorKind.busy ||
    ChatErrorKind.hermes ||
    ChatErrorKind.server => true,
    _ => false,
  };

  static const network = ChatException(
    ChatErrorKind.network,
    'Could not reach the ${Brand.serverName}',
  );

  static const timeout = ChatException(
    ChatErrorKind.network,
    'The ${Brand.serverName} did not answer in time',
    code: 'client_timeout',
  );

  static const cutOff = ChatException(
    ChatErrorKind.network,
    'The connection dropped before the reply finished',
    code: 'stream_ended',
  );

  /// Maps a non-2xx response. [body] is the raw text; aiohttp's plain 404 for
  /// unknown routes has no JSON and maps by status alone.
  static ChatException fromHttp(
    int status,
    String body, {
    Map<String, String> headers = const {},
  }) {
    Map<String, dynamic> json = const {};
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {}
    final code = _str(json['code']) ?? _str(json['error']);
    final serverMessage = _str(json['message']) ?? _str(json['error']);
    Duration? retryAfter;
    final ra = json['retry_after_s'];
    if (ra is num && ra > 0) {
      retryAfter = Duration(milliseconds: (ra * 1000).round());
    } else {
      final h = int.tryParse(headers['retry-after']?.trim() ?? '');
      if (h != null && h > 0) retryAfter = Duration(seconds: h);
    }
    final kind = kindFor(code, status: status);
    return ChatException(
      kind,
      _friendly(kind, serverMessage, status),
      status: status,
      code: code,
      retryAfter: kind == ChatErrorKind.usageLimit ? retryAfter : null,
    );
  }

  /// An `event: error` inside the stream.
  static ChatException fromStream(String? code, String? message) {
    final kind = kindFor(code);
    return ChatException(kind, _friendly(kind, message, null), code: code);
  }

  /// Classifies a bridge code; [status] decides when the code is unknown.
  static ChatErrorKind kindFor(String? code, {int? status}) {
    switch (code) {
      case 'usage_limit':
        return ChatErrorKind.usageLimit;
      case 'login_expired':
        return ChatErrorKind.loginExpired;
      case 'unauthorized':
        return ChatErrorKind.unauthorized;
      case 'busy':
      case 'hermes_busy':
        return ChatErrorKind.busy;
      case 'hermes_unreachable':
        return ChatErrorKind.hermes;
      case 'not_found':
        return ChatErrorKind.notFound;
      case 'history_unavailable':
      case 'hermes_unconfigured':
        return ChatErrorKind.unavailable;
      case 'hermes_error':
      case 'hermes_auth':
      case 'hermes_incomplete':
      case 'timeout':
        return ChatErrorKind.hermes;
    }
    if (status == null) return ChatErrorKind.hermes;
    if (status == 401) return ChatErrorKind.unauthorized;
    if (status == 404) return ChatErrorKind.notFound;
    if (status == 429) return ChatErrorKind.busy;
    if (status == 503) return ChatErrorKind.unavailable;
    if (status >= 400 && status < 500) return ChatErrorKind.invalid;
    return ChatErrorKind.server;
  }

  static String _friendly(ChatErrorKind kind, String? server, int? status) {
    switch (kind) {
      case ChatErrorKind.usageLimit:
        return 'Usage limit reached';
      case ChatErrorKind.loginExpired:
        return 'The server\'s ChatGPT login has expired. Sign in again on the server';
      case ChatErrorKind.unauthorized:
        return 'Wrong or missing access key';
      case ChatErrorKind.busy:
        return '${Brand.assistantName} is busy with other replies. Try again in a moment';
      case ChatErrorKind.network:
        return 'Could not reach the ${Brand.serverName}';
      default:
        if (server != null && server.isNotEmpty && server != 'not found') {
          return server;
        }
        return switch (kind) {
          ChatErrorKind.notFound => 'This chat no longer exists',
          ChatErrorKind.unavailable =>
            'Text chat is not available on this server',
          ChatErrorKind.hermes => 'Couldn\'t get a reply',
          _ => status == null ? 'Request failed' : 'HTTP $status',
        };
    }
  }

  static String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;
}
