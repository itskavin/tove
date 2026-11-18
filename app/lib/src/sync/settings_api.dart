import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// The server's copy of the synced settings (`GET /api/settings`).
class RemoteSettings {
  const RemoteSettings({
    required this.version,
    required this.settings,
    this.updated,
  });

  /// Before the first save on this server.
  static const empty = RemoteSettings(version: 0, settings: {});

  factory RemoteSettings.fromJson(Map<String, dynamic> j) => RemoteSettings(
    version: j['version'] is int ? j['version'] as int : 0,
    settings: j['settings'] is Map<String, dynamic>
        ? Map.unmodifiable(j['settings'] as Map<String, dynamic>)
        : const {},
    updated: j['updated'] is int ? j['updated'] as int : null,
  );

  final int version;
  final Map<String, Object?> settings;

  /// Unix milliseconds of the last save, or null before the first.
  final int? updated;

  Map<String, Object?> toJson() => {
    'version': version,
    'settings': settings,
    'updated': updated,
  };
}

/// What `GET /api/capabilities` says about settings sync.
class SettingsSupport {
  const SettingsSupport({
    required this.supported,
    this.maxBytes = 32768,
    this.textChars = 1500,
  });

  static const none = SettingsSupport(supported: false);

  final bool supported;

  /// The largest settings object the server keeps, as compact JSON.
  final int maxBytes;

  /// The limit of `custom_instructions` and `about_you`.
  final int textChars;
}

/// Why a settings request failed.
enum SettingsErrorKind {
  /// No connection, a timeout or a 5xx: try again later.
  offline,

  /// 409: another device saved first; [SettingsApiException.current] holds
  /// the server's state.
  conflict,

  /// 400 `bad_setting`: [SettingsApiException.key] names the refused key.
  rejected,

  /// 413: over the server's size limit.
  tooLarge,

  /// 401: the access key is wrong.
  unauthorized,

  /// 404: the bridge has no settings route.
  unsupported,

  /// Anything else.
  other,
}

class SettingsApiException implements Exception {
  const SettingsApiException(this.kind, {this.current, this.key, this.status});

  final SettingsErrorKind kind;
  final RemoteSettings? current;
  final String? key;
  final int? status;

  @override
  String toString() => 'SettingsApiException($kind, status: $status)';
}

/// The bridge routes the sync engine needs. Implemented over HTTP by
/// [HttpSettingsApi] and by fakes in tests.
abstract interface class SettingsApi {
  /// `GET /api/capabilities`: whether `settings_sync` is on, and its limits.
  /// A 404 (old bridge) is [SettingsSupport.none]; a network failure throws
  /// [SettingsApiException] (`offline`).
  Future<SettingsSupport> support();

  /// `GET /api/settings`. Returns null for `304 Not Modified` when [etag]
  /// still matches.
  Future<RemoteSettings?> fetch({String? etag});

  /// `PUT /api/settings`: replaces the whole object when [version] is still
  /// current.
  Future<RemoteSettings> put(int version, Map<String, Object?> settings);

  void close();
}

/// [SettingsApi] over `package:http`, with the app's base URL and key.
class HttpSettingsApi implements SettingsApi {
  HttpSettingsApi({
    required Uri baseUrl,
    required String accessKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _base = _normalise(baseUrl),
       _key = accessKey,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  final Uri _base;
  final String _key;
  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  static Uri _normalise(Uri u) {
    final path = u.path.endsWith('/')
        ? u.path.substring(0, u.path.length - 1)
        : u.path;
    return u.replace(path: path, query: null, fragment: null);
  }

  Uri _url(String path) => _base.replace(path: '${_base.path}$path');

  Future<http.Response> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String> headers = const {},
  }) async {
    final req = http.Request(method, _url(path))
      ..headers.addAll({
        'Authorization': 'Bearer $_key',
        'Content-Type': 'application/json',
        ...headers,
      });
    if (body != null) req.body = jsonEncode(body);
    try {
      return await http.Response.fromStream(await _client.send(req))
          .timeout(timeout);
    } catch (_) {
      throw const SettingsApiException(SettingsErrorKind.offline);
    }
  }

  static Map<String, dynamic> _decode(http.Response r) {
    try {
      final j = jsonDecode(r.body);
      if (j is Map<String, dynamic>) return j;
    } catch (_) {}
    return const {};
  }

  static SettingsApiException _error(http.Response r) {
    final j = _decode(r);
    final kind = switch (r.statusCode) {
      401 => SettingsErrorKind.unauthorized,
      404 => SettingsErrorKind.unsupported,
      409 => SettingsErrorKind.conflict,
      400 => SettingsErrorKind.rejected,
      413 => SettingsErrorKind.tooLarge,
      >= 500 => SettingsErrorKind.offline,
      _ => SettingsErrorKind.other,
    };
    final current = j['current'];
    return SettingsApiException(
      kind,
      status: r.statusCode,
      key: j['key'] is String ? j['key'] as String : null,
      current: current is Map<String, dynamic>
          ? RemoteSettings.fromJson(current)
          : null,
    );
  }

  @override
  Future<SettingsSupport> support() async {
    final r = await _send('GET', '/api/capabilities');
    if (r.statusCode == 404) return SettingsSupport.none;
    if (r.statusCode != 200) throw _error(r);
    final j = _decode(r);
    if (j['settings_sync'] != true) return SettingsSupport.none;
    final limits = j['settings_limits'];
    int limit(String k, int d) =>
        limits is Map && limits[k] is int ? limits[k] as int : d;
    return SettingsSupport(
      supported: true,
      maxBytes: limit('bytes', 32768),
      textChars: limit('text_chars', 1500),
    );
  }

  @override
  Future<RemoteSettings?> fetch({String? etag}) async {
    final r = await _send(
      'GET',
      '/api/settings',
      headers: {'If-None-Match': ?etag},
    );
    if (r.statusCode == 304) return null;
    if (r.statusCode != 200) throw _error(r);
    return RemoteSettings.fromJson(_decode(r));
  }

  @override
  Future<RemoteSettings> put(int version, Map<String, Object?> settings) async {
    final r = await _send(
      'PUT',
      '/api/settings',
      body: {'version': version, 'settings': settings},
    );
    if (r.statusCode != 200) throw _error(r);
    return RemoteSettings.fromJson(_decode(r));
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}
