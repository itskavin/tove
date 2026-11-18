import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'attachment.dart';

/// Why an upload failed, in terms the composer can show.
enum UploadErrorKind {
  /// 413 `too_large`.
  tooLarge,

  /// 415 `unsupported_type`.
  unsupported,

  /// 507 `quota_exceeded`: the conversation's upload budget is used up.
  quota,

  /// 401.
  unauthorized,

  /// 404 on the route: the bridge has no uploads.
  unavailable,

  /// No connection, timeout, or a dropped request. Worth retrying.
  network,

  /// Anything else from the server.
  server,
}

class UploadException implements Exception {
  const UploadException(this.kind, this.message, {this.status, this.code});

  final UploadErrorKind kind;
  final String message;
  final int? status;
  final String? code;

  bool get retryable =>
      kind == UploadErrorKind.network || kind == UploadErrorKind.server;

  @override
  String toString() => message;
}

/// Cancels a running [AttachmentUploader.upload].
class UploadCancel {
  final _c = Completer<void>();
  bool get cancelled => _c.isCompleted;
  Future<void> get future => _c.future;
  void cancel() {
    if (!_c.isCompleted) _c.complete();
  }
}

/// Sends one attachment to the bridge. [onProgress] gets 0…1.
abstract interface class AttachmentUploader {
  Future<UploadedAttachment> upload({
    required String name,
    required String mime,
    required Uint8List bytes,
    String? conversationId,
    void Function(double progress)? onProgress,
    UploadCancel? cancel,
  });

  /// Drops an upload no message references yet (the user removed it).
  /// Best effort: the bridge also expires unreferenced uploads.
  Future<void> delete(String id);
}

/// `POST /api/uploads` (multipart, one file per request) and
/// `DELETE /api/uploads/{id}`, as proposed in
/// `docs/design/bridge-requests.md`. Same base URL and key as `ChatApi`.
class BridgeUploadClient implements AttachmentUploader {
  BridgeUploadClient({
    required Uri baseUrl,
    required String accessKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 120),
    this.chunkSize = 64 * 1024,
  }) : _base = _normalise(baseUrl),
       _key = accessKey,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final Uri _base;
  final String _key;
  final http.Client _client;
  final bool _ownsClient;

  /// For the whole request, headers and body.
  final Duration timeout;
  final int chunkSize;

  static Uri _normalise(Uri u) {
    final path = u.path.endsWith('/')
        ? u.path.substring(0, u.path.length - 1)
        : u.path;
    return u.replace(path: path, query: null, fragment: null);
  }

  Uri _url(String path) => _base.replace(path: '${_base.path}$path');

  /// The absolute URL of a `preview_url` the bridge returned.
  Uri resolve(String path) =>
      path.startsWith('/') ? _url(path) : _base.resolve(path);

  /// Headers for fetching previews (`Image.network(..., headers:)`).
  Map<String, String> get authHeaders => {'Authorization': 'Bearer $_key'};

  static final _rand = math.Random.secure();

  static String _boundary() =>
      'hermes-${List.generate(24, (_) => _rand.nextInt(36).toRadixString(36)).join()}';

  /// A header-safe file name: quotes, backslashes and line breaks are
  /// replaced; the full name also goes as RFC 5987 `filename*`.
  static String _disposition(String name) {
    final safe = name.replaceAll(RegExp(r'["\\\r\n]'), '_');
    final ascii = safe.replaceAll(RegExp(r'[^\x20-\x7E]'), '_');
    final star = Uri.encodeComponent(name);
    return 'form-data; name="file"; filename="$ascii"; '
        "filename*=UTF-8''$star";
  }

  @override
  Future<UploadedAttachment> upload({
    required String name,
    required String mime,
    required Uint8List bytes,
    String? conversationId,
    void Function(double progress)? onProgress,
    UploadCancel? cancel,
  }) async {
    final boundary = _boundary();
    final head = StringBuffer();
    if (conversationId != null) {
      head
        ..write('--$boundary\r\n')
        ..write('Content-Disposition: form-data; name="conversation_id"')
        ..write('\r\n\r\n$conversationId\r\n');
    }
    head
      ..write('--$boundary\r\n')
      ..write('Content-Disposition: ${_disposition(name)}\r\n')
      ..write('Content-Type: $mime\r\n\r\n');
    final headBytes = utf8.encode(head.toString());
    final tailBytes = utf8.encode('\r\n--$boundary--\r\n');
    final total = headBytes.length + bytes.length + tailBytes.length;

    final req = _UploadRequest(
      _url('/api/uploads'),
      parts: [headBytes, bytes, tailBytes],
      chunkSize: chunkSize,
      abortTrigger: cancel?.future,
      onSent: onProgress == null
          ? null
          // The server's answer is the last 5 %.
          : (sent) => onProgress(0.95 * sent / total),
    );
    req.headers.addAll({
      ...authHeaders,
      'Content-Type': 'multipart/form-data; boundary=$boundary',
      'Accept': 'application/json',
    });
    req.contentLength = total;

    onProgress?.call(0);
    final response = _client.send(req);

    final http.Response r;
    try {
      r = await http.Response.fromStream(await response).timeout(timeout);
    } on http.RequestAbortedException {
      throw const UploadException(UploadErrorKind.network, 'Upload cancelled');
    } on TimeoutException {
      throw const UploadException(
        UploadErrorKind.network,
        'The upload took too long',
      );
    } catch (_) {
      if (cancel?.cancelled == true) {
        throw const UploadException(
          UploadErrorKind.network,
          'Upload cancelled',
        );
      }
      throw const UploadException(
        UploadErrorKind.network,
        "Couldn't reach the Hermes server",
      );
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw errorFor(r.statusCode, r.body);
    }
    try {
      final j = jsonDecode(r.body);
      if (j is Map<String, dynamic>) {
        final up = UploadedAttachment.fromJson(j);
        onProgress?.call(1);
        return up;
      }
    } catch (_) {}
    throw const UploadException(
      UploadErrorKind.server,
      'The Hermes server sent an invalid answer',
    );
  }

  @override
  Future<void> delete(String id) async {
    try {
      final req = http.Request(
        'DELETE',
        _url('/api/uploads/${Uri.encodeComponent(id)}'),
      )..headers.addAll(authHeaders);
      final r = await _client.send(req).timeout(const Duration(seconds: 15));
      await r.stream.drain<void>();
    } catch (_) {
      // Unreferenced uploads expire on the server.
    }
  }

  /// Maps a bridge error answer (`{"error", "code", "message"}`).
  static UploadException errorFor(int status, String body) {
    String? code;
    String? message;
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        code = j['code'] is String ? j['code'] as String : null;
        message = j['message'] is String ? j['message'] as String : null;
      }
    } catch (_) {}
    final kind = switch ((status, code)) {
      (_, 'too_large') || (413, _) => UploadErrorKind.tooLarge,
      (_, 'unsupported_type') || (415, _) => UploadErrorKind.unsupported,
      (_, 'quota_exceeded') || (507, _) => UploadErrorKind.quota,
      (401, _) => UploadErrorKind.unauthorized,
      (404, _) || (405, _) => UploadErrorKind.unavailable,
      _ => UploadErrorKind.server,
    };
    final text = switch (kind) {
      UploadErrorKind.tooLarge => 'Too large for the server',
      UploadErrorKind.unsupported => "The server doesn't accept this type",
      UploadErrorKind.quota => 'Upload space for this chat is used up',
      UploadErrorKind.unauthorized => 'The access key was refused',
      UploadErrorKind.unavailable => 'This server has no uploads',
      _ => message ?? 'Upload failed',
    };
    return UploadException(kind, text, status: status, code: code);
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

/// A request whose body is a pull-based stream: `IOClient` pauses it while
/// the socket drains, so [onSent] follows the bytes actually written. On the
/// web the browser buffers the whole body first.
class _UploadRequest extends http.BaseRequest with http.Abortable {
  _UploadRequest(
    Uri url, {
    required this.parts,
    required this.chunkSize,
    this.abortTrigger,
    this.onSent,
  }) : super('POST', url);

  final List<List<int>> parts;
  final int chunkSize;
  final void Function(int sent)? onSent;

  @override
  final Future<void>? abortTrigger;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_body());
  }

  Stream<List<int>> _body() async* {
    var sent = 0;
    for (final part in parts) {
      for (var i = 0; i < part.length; i += chunkSize) {
        final end = math.min(i + chunkSize, part.length);
        final chunk = part is Uint8List
            ? Uint8List.sublistView(part, i, end)
            : part.sublist(i, end);
        yield chunk;
        sent += chunk.length;
        onSent?.call(sent);
      }
    }
  }
}
