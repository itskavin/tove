import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../brand.dart';
import '../chat/events.dart';

/// Where the Android service's connection is (channel `tove/events`).
enum InstantState {
  /// Not on this platform, or the bridge has no events stream.
  unsupported,
  off,
  connecting,
  connected,
  reconnecting,
  waitingNetwork,

  /// The bridge refused the key: sign in again.
  unauthorized,

  /// Android did not allow the service to start (it starts next time the
  /// app opens).
  blocked;

  static InstantState fromNative(String? s) => switch (s) {
    'connected' => connected,
    'connecting' => connecting,
    'reconnecting' => reconnecting,
    'waiting_network' => waitingNetwork,
    'unauthorized' => unauthorized,
    'unsupported' => unsupported,
    'blocked' => blocked,
    _ => off,
  };
}

/// What the settings page shows about instant notifications.
class InstantStatus {
  const InstantStatus({
    this.state = InstantState.off,
    this.connectedAt,
    this.heartbeatAt,
    this.lastId = 0,
    this.batteryExempt = true,
    this.notificationsAllowed = true,
  });

  factory InstantStatus.fromMap(Map<Object?, Object?> m) {
    DateTime? t(String k) {
      final v = m[k];
      return v is num && v > 0
          ? DateTime.fromMillisecondsSinceEpoch(v.toInt())
          : null;
    }

    return InstantStatus(
      state: m['enabled'] == true || m['status'] == 'unauthorized'
          ? InstantState.fromNative(m['status'] as String?)
          : InstantState.off,
      connectedAt: t('connectedAt'),
      heartbeatAt: t('heartbeatAt'),
      lastId: m['lastId'] is num ? (m['lastId'] as num).toInt() : 0,
      batteryExempt: m['batteryExempt'] != false,
      notificationsAllowed: m['notificationsAllowed'] != false,
    );
  }

  final InstantState state;
  final DateTime? connectedAt;

  /// The last sign of life on the connection (heartbeat or event).
  final DateTime? heartbeatAt;
  final int lastId;

  /// Battery optimisation is off for the app (Doze then never delays a
  /// reconnect).
  final bool batteryExempt;

  /// The system lets the app post notifications (Android 13+ permission).
  final bool notificationsAllowed;

  bool get running =>
      state == InstantState.connected ||
      state == InstantState.connecting ||
      state == InstantState.reconnecting ||
      state == InstantState.waitingNetwork;
}

/// The native side, as a seam for tests.
abstract class InstantPlatform {
  Future<Map<Object?, Object?>?> invoke(String method, [Object? args]);
  void setHandler(Future<Object?> Function(MethodCall call)? handler);
}

class ChannelInstantPlatform implements InstantPlatform {
  static const channel = MethodChannel('tove/events');

  @override
  Future<Map<Object?, Object?>?> invoke(String method, [Object? args]) async {
    final r = await channel.invokeMethod<Object?>(method, args);
    if (r is Map) return Map<Object?, Object?>.from(r);
    return r == null ? null : {'value': r};
  }

  @override
  void setHandler(Future<Object?> Function(MethodCall call)? handler) =>
      channel.setMethodCallHandler(handler);
}

/// "Instant notifications (keeps a small connection open)": Android only.
///
/// When on, a low-importance foreground service holds the bridge's
/// `GET /api/events` stream, so notifications arrive with only Tove on the
/// phone (no Google services, no distributor app). Off, the app checks the
/// bridge about every 15 minutes in the background (WorkManager; Doze can
/// stretch that) and UnifiedPush still works for people with a distributor.
///
/// The switch is on unless the user turns it off (an unset preference counts
/// as on, so installs that never touched it get it back); the service only runs
/// while the bridge offers `events`, reply notifications are on and the
/// system allows notifications.
class InstantNotifications extends ChangeNotifier {
  InstantNotifications({
    InstantPlatform? platform,
    SharedPreferencesAsync? prefs,
    bool? supported,
  }) : _platform = platform ?? ChannelInstantPlatform(),
       _prefs = prefs ?? SharedPreferencesAsync(),
       supported = supported ?? supportedHere;

  static const enabledKey = 'notify.instant.enabled';

  /// The service exists on this platform (Android).
  static bool get supportedHere =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  final InstantPlatform _platform;
  final SharedPreferencesAsync _prefs;

  /// Android: the service exists on this platform.
  final bool supported;

  bool _enabled = true;
  bool _loaded = false;
  bool _bridgeOffers = false;
  InstantStatus _status = const InstantStatus();
  _Config? _last;
  final _events = StreamController<BridgeEvent>.broadcast();
  final _opens = StreamController<String>.broadcast();

  /// The user's switch (default on).
  bool get enabled => _enabled;
  bool get loaded => _loaded;

  /// The bridge has the events stream (capability `events`).
  bool get bridgeOffers => _bridgeOffers;
  InstantStatus get status => _status;

  /// The service holds the connection now (the app then opens none itself).
  bool get active => supported && _enabled && _bridgeOffers && _status.running;

  /// Events the service forwarded while the app is on screen.
  Stream<BridgeEvent> get events => _events.stream;

  /// Chats to open from taps on the service's notifications.
  Stream<String> get opens => _opens.stream;

  Future<void> load() async {
    try {
      _enabled = await _prefs.getBool(enabledKey) ?? true;
    } catch (_) {}
    _loaded = true;
    if (supported) {
      _platform.setHandler((call) async {
        switch (call.method) {
          case 'event':
            final e = call.arguments is String
                ? BridgeEvent.fromForwarded(call.arguments as String)
                : null;
            if (e != null && !_events.isClosed) _events.add(e);
          case 'open':
            if (call.arguments is String && !_opens.isClosed) {
              _opens.add(call.arguments as String);
            }
        }
        return null;
      });
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool on) async {
    if (_enabled == on) return;
    _enabled = on;
    notifyListeners();
    try {
      await _prefs.setBool(enabledKey, on);
    } catch (_) {}
    final c = _last;
    if (c != null) await _apply(c);
  }

  /// Starts or stops the service for this bridge. Call from the visible app
  /// (Android allows starting it only then): at start, after settings change.
  Future<void> configure({
    required bool bridgeOffers,
    required String url,
    required String accessKey,
    required bool systemEnabled,
    String? deviceId,
    int heartbeat = 80,
  }) async {
    _bridgeOffers = bridgeOffers;
    await _apply(_Config(url, accessKey, systemEnabled, deviceId, heartbeat));
  }

  /// Signed out: stop and forget the key.
  Future<void> signOut() async {
    _last = null;
    if (!supported) return;
    try {
      await _platform.invoke('configure', {'enabled': false});
    } catch (_) {}
  }

  Future<void> _apply(_Config c) async {
    _last = c;
    if (!supported) return;
    final on = _enabled && _bridgeOffers && c.systemEnabled;
    try {
      final r = await _platform.invoke('configure', {
        'enabled': on,
        'url': on ? c.url : '',
        'key': on ? c.key : '',
        'deviceId': c.deviceId,
        'heartbeat': c.heartbeat,
        'systemEnabled': c.systemEnabled,
        'assistantName': Brand.assistantName,
        'appName': Brand.appName,
      });
      if (r != null) _status = InstantStatus.fromMap(r);
    } catch (e) {
      debugPrint('Instant notifications unavailable: $e');
    }
    notifyListeners();
  }

  /// Re-reads the service status (the settings page polls this).
  Future<InstantStatus> refreshStatus() async {
    if (!supported) return _status;
    try {
      final r = await _platform.invoke('status');
      if (r != null) _status = InstantStatus.fromMap(r);
    } catch (_) {}
    notifyListeners();
    return _status;
  }

  /// The chat a tap on one of the service's notifications launched the app
  /// with, once.
  Future<String?> launchChat() async {
    if (!supported) return null;
    try {
      final r = await _platform.invoke('launchChat');
      final v = r?['value'];
      return v is String && v.isNotEmpty ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// Shows Android's "Let app always run in background?" dialog (falls back
  /// to the battery-optimisation list).
  Future<void> requestBatteryExemption() async {
    if (!supported) return;
    try {
      await _platform.invoke('requestBatteryExemption');
    } catch (_) {}
  }

  /// Opens the system's battery-optimisation list.
  Future<void> openBatterySettings() async {
    if (!supported) return;
    try {
      await _platform.invoke('openBatterySettings');
    } catch (_) {}
  }

  Future<void> openNotificationSettings() async {
    if (!supported) return;
    try {
      await _platform.invoke('openNotificationSettings');
    } catch (_) {}
  }

  @override
  void dispose() {
    if (supported) _platform.setHandler(null);
    _events.close();
    _opens.close();
    super.dispose();
  }
}

class _Config {
  const _Config(
    this.url,
    this.key,
    this.systemEnabled,
    this.deviceId,
    this.heartbeat,
  );
  final String url;
  final String key;
  final bool systemEnabled;
  final String? deviceId;
  final int heartbeat;
}
