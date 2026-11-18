import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Thrown when the archive could not reach the server or it refused.
class ChatArchiveException implements Exception {
  const ChatArchiveException(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => 'ChatArchiveException($message, status: $status)';
}

/// Progress of an export or a delete-all: [done] of [total] chats.
typedef ArchiveProgress = void Function(int done, int total);

/// Settings › Data controls: every chat on the server, exported as one JSON
/// file or deleted, using the existing conversation routes (the bridge has
/// no bulk route yet; bridge-requests.md round 3 asks for one).
class ChatArchive {
  ChatArchive({
    required Uri baseUrl,
    required String accessKey,
    http.Client? client,
    this.pageSize = 100,
    this.messagesPage = 200,
    this.timeout = const Duration(seconds: 20),
  }) : _base = _normalise(baseUrl),
       _key = accessKey,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final Uri _base;
  final String _key;
  final http.Client _client;
  final bool _ownsClient;

  /// `limits.page_max` and `limits.messages_page_max`.
  final int pageSize, messagesPage;
  final Duration timeout;

  static Uri _normalise(Uri u) {
    final path = u.path.endsWith('/')
        ? u.path.substring(0, u.path.length - 1)
        : u.path;
    return u.replace(path: path, query: null, fragment: null);
  }

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, String>? query,
  ]) async {
    final req = http.Request(
      'GET',
      _base.replace(path: '${_base.path}$path', queryParameters: query),
    )..headers['Authorization'] = 'Bearer $_key';
    final http.Response r;
    try {
      r = await http.Response.fromStream(await _client.send(req))
          .timeout(timeout);
    } catch (_) {
      throw const ChatArchiveException('Couldn’t reach the server.');
    }
    if (r.statusCode != 200) {
      throw ChatArchiveException(
        'The server answered ${r.statusCode}.',
        status: r.statusCode,
      );
    }
    try {
      final j = jsonDecode(r.body);
      if (j is Map<String, dynamic>) return j;
    } catch (_) {}
    throw const ChatArchiveException('The server sent an invalid answer.');
  }

  static List<Map<String, dynamic>> _list(Object? v) => [
    for (final e in (v is List ? v : const []))
      if (e is Map<String, dynamic>) e,
  ];

  /// Every conversation (newest first), all pages.
  Future<List<Map<String, dynamic>>> conversations() async {
    final out = <Map<String, dynamic>>[];
    String? cursor;
    final seen = <String>{};
    do {
      final j = await _get('/api/conversations', {
        'limit': '$pageSize',
        'cursor': ?cursor,
      });
      out.addAll(_list(j['conversations']));
      final next = j['next_cursor'];
      cursor = next is String && next.isNotEmpty && seen.add(next)
          ? next
          : null;
    } while (cursor != null);
    return out;
  }

  /// One conversation with all of its messages, oldest first.
  Future<Map<String, dynamic>> conversation(String id) async {
    final enc = Uri.encodeComponent(id);
    final j = await _get('/api/conversations/$enc', {'limit': '$messagesPage'});
    final conv = j['conversation'] is Map<String, dynamic>
        ? Map<String, dynamic>.of(j['conversation'] as Map<String, dynamic>)
        : <String, dynamic>{'id': id};
    final messages = _list(j['messages']);
    var more = j['has_more'] == true;
    while (more && messages.isNotEmpty) {
      final before = messages.first['id'];
      if (before is! String) break;
      final page = await _get('/api/conversations/$enc/messages', {
        'before': before,
        'limit': '$messagesPage',
      });
      final older = _list(page['messages']);
      if (older.isEmpty) break;
      messages.insertAll(0, older);
      more = page['has_more'] == true;
    }
    conv['messages'] = messages;
    return conv;
  }

  /// Every chat with its messages, as the export file's JSON object.
  Future<Map<String, dynamic>> export({
    ArchiveProgress? onProgress,
    DateTime? now,
  }) async {
    final list = await conversations();
    final chats = <Map<String, dynamic>>[];
    for (var i = 0; i < list.length; i++) {
      onProgress?.call(i, list.length);
      final id = list[i]['id'];
      if (id is! String) continue;
      chats.add(await conversation(id));
    }
    onProgress?.call(list.length, list.length);
    return {
      'format': 'tove-chats',
      'version': 1,
      'exported': (now ?? DateTime.now()).millisecondsSinceEpoch,
      // The address only, never the key.
      'server': _base.replace(userInfo: '').toString(),
      'conversations': chats,
    };
  }

  /// [export] as pretty-printed UTF-8 bytes.
  static Uint8List encode(Map<String, dynamic> export) => Uint8List.fromList(
    utf8.encode(const JsonEncoder.withIndent('  ').convert(export)),
  );

  /// A file name like `tove-chats-2026-11-16.json`.
  static String fileName(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'tove-chats-${now.year}-${two(now.month)}-${two(now.day)}.json';
  }

  /// Deletes every chat with [delete] (the conversations controller, so the
  /// chat list follows). Returns how many were deleted; stops at the first
  /// failure and rethrows it.
  Future<int> deleteAll(
    Future<void> Function(String id) delete, {
    ArchiveProgress? onProgress,
  }) async {
    final ids = [
      for (final c in await conversations())
        if (c['id'] is String) c['id'] as String,
    ];
    var done = 0;
    for (final id in ids) {
      onProgress?.call(done, ids.length);
      await delete(id);
      done++;
    }
    onProgress?.call(done, ids.length);
    return done;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
