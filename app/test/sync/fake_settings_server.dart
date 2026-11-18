import 'dart:convert';

import 'package:tove_chat/src/sync/settings_sync.dart';

/// An in-memory `/api/settings` with the bridge's versioning rules.
class FakeSettingsServer {
  FakeSettingsServer({this.supported = true});

  bool supported;
  bool offline = false;
  int version = 0;
  Map<String, Object?> settings = {};

  /// Keys the server refuses with `400 bad_setting`.
  final Set<String> refuse = {};
  int maxBytes = 32768;

  int puts = 0;
  int gets = 0;
  final putBodies = <Map<String, Object?>>[];

  /// Runs before a PUT is checked (another device saving first).
  void Function()? beforePut;

  /// Another device saves.
  void saveElsewhere(Map<String, Object?> next) {
    settings = jsonDecode(jsonEncode(next)) as Map<String, Object?>;
    version++;
  }

  RemoteSettings get state => RemoteSettings(
    version: version,
    settings: jsonDecode(jsonEncode(settings)) as Map<String, Object?>,
    updated: version == 0 ? null : 1794771640683 + version,
  );

  FakeSettingsApi api() => FakeSettingsApi(this);
}

class FakeSettingsApi implements SettingsApi {
  FakeSettingsApi(this.server);
  final FakeSettingsServer server;
  bool closed = false;

  void _net() {
    if (server.offline) {
      throw const SettingsApiException(SettingsErrorKind.offline);
    }
  }

  @override
  Future<SettingsSupport> support() async {
    _net();
    return server.supported
        ? SettingsSupport(supported: true, maxBytes: server.maxBytes)
        : SettingsSupport.none;
  }

  @override
  Future<RemoteSettings?> fetch({String? etag}) async {
    _net();
    server.gets++;
    if (etag == '"s${server.version}"') return null;
    return server.state;
  }

  @override
  Future<RemoteSettings> put(int version, Map<String, Object?> settings) async {
    _net();
    server.beforePut?.call();
    server.beforePut = null;
    server.puts++;
    server.putBodies.add(settings);
    if (version != server.version) {
      throw SettingsApiException(
        SettingsErrorKind.conflict,
        status: 409,
        current: server.state,
      );
    }
    for (final k in server.refuse) {
      final top = k.split('.').first;
      final hit =
          settings.containsKey(k) ||
          (settings[top] is Map &&
              (settings[top] as Map).containsKey(k.split('.').last));
      if (hit) {
        throw SettingsApiException(
          SettingsErrorKind.rejected,
          status: 400,
          key: k,
        );
      }
    }
    server.saveElsewhere(settings);
    return server.state;
  }

  @override
  void close() => closed = true;
}
