import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'refresh_policy.dart';
import 'tone_web.dart' if (dart.library.io) 'tone_stub.dart' as web_tone;

export 'refresh_policy.dart' show RefreshMode, RefreshPolicy;

/// Small device services (spec §6.10, §7.2, §7.3), channel
/// `io.github.tovechat.tove/device` on Android:
///  * `info {}` → `{sdk: int, refreshRates: [double], hardwareKeyboard: bool}`
///  * `setHighRefresh {on: bool}` → refresh status (older builds; replaced
///    by `setRefreshRate`).
///  * `refreshStatus {}` → `{supportedHz, currentHz, requestedHz,
///    peakSettingHz, powerSave}`: what was asked for and what caps it.
///  * `playTone {tones: [[hz, ms], …], gain: double}`: short sine cues on the
///    voice-call audio stream, so they follow the call's route.
///  * `share {text, subject?}` → `bool`: the system share sheet with plain
///    text.
///  * `moveTaskToBack {}` → `bool`: Back at the root minimises the app.
///  * `haptic {kind}` → `bool`: vibrator primitives with touch usage, so
///    haptics fire even where the legacy view constants are ignored.
///  * `setRefreshRate {hz}` → refresh status: the mode closest to `hz`
///    (0 = the system's choice); see `RefreshPolicy`.
/// Other platforms: tones use Web Audio on the web; everything else is a
/// no-op (iOS sets `CADisableMinimumFrameDurationOnPhone` in Info.plist).
class DeviceServices {
  DeviceServices({MethodChannel? channel, bool? android})
    : _channel = channel ?? const MethodChannel(channelName),
      _android =
          android ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static const channelName = 'io.github.tovechat.tove/device';
  final MethodChannel _channel;
  final bool _android;
  final Set<String> _highReasons = {};

  /// Whether these services reach Android (the only platform with a
  /// channel).
  bool get android => _android;

  /// Sends the app to the background like Home (Android). False elsewhere
  /// or when the platform refused, so the caller can fall back.
  Future<bool> moveTaskToBack() async {
    if (!_android) return false;
    try {
      return await _channel.invokeMethod<bool>('moveTaskToBack') == true;
    } catch (_) {
      return false;
    }
  }

  /// Plays a native haptic of [kind] (`light`, `medium`, `heavy`,
  /// `selection`). False when it could not, so the caller falls back to
  /// [HapticFeedback].
  Future<bool> haptic(String kind) async {
    if (!_android || _hapticsUnavailable) return false;
    try {
      return await _channel.invokeMethod<bool>('haptic', {'kind': kind}) ==
          true;
    } on MissingPluginException {
      _hapticsUnavailable = true;
      return false;
    } catch (_) {
      return false;
    }
  }

  bool _hapticsUnavailable = false;

  double? _rate;

  /// Asks for the display mode closest to [hz]; 0 gives the choice back to
  /// the system. Repeats are dropped. Normally chosen by [RefreshPolicy].
  Future<void> setRefreshRate(double hz) async {
    if (!_android || _rate == hz) return;
    // Nothing requested yet and nothing to request: no call.
    if (_rate == null && hz == 0) return;
    _rate = hz;
    try {
      final r = await _channel.invokeMethod<Map<Object?, Object?>>(
        'setRefreshRate',
        {'hz': hz},
      );
      _report(r, 'rate $hz');
    } catch (_) {}
  }

  /// The last status the platform reported (Android only).
  RefreshStatus? lastRefreshStatus;

  /// The Android API level, or null elsewhere / when unknown.
  Future<int?> androidSdk() async {
    if (!_android) return null;
    try {
      final r = await _channel.invokeMethod<Map<Object?, Object?>>('info');
      final sdk = r?['sdk'];
      return sdk is int ? sdk : null;
    } catch (_) {
      return null;
    }
  }

  /// Boosts to the panel's highest rate while any reason holds (for example
  /// `live`, `scroll`, `gesture`) under [RefreshMode.auto]; see
  /// [RefreshPolicy].
  Future<void> requestHighRefresh(String reason, bool on) {
    final changed = on ? _highReasons.add(reason) : _highReasons.remove(reason);
    return changed ? _applyRefresh() : Future.value();
  }

  RefreshMode _refreshMode = RefreshMode.auto;

  /// The Display setting; applied at once.
  RefreshMode get refreshMode => _refreshMode;
  set refreshMode(RefreshMode m) {
    if (m == _refreshMode) return;
    _refreshMode = m;
    unawaited(_applyRefresh());
  }

  List<double>? _supportedHz;
  bool _active = false;
  DateTime _lastTouch = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _idleTimer;
  Timer? _gestureTail;
  bool _routeAdded = false;

  /// Follows touches app-wide (a global pointer route, Android only): any
  /// touch makes Auto active for [RefreshPolicy.idleAfter], and a moving
  /// finger boosts until [RefreshPolicy.boostTail] after it lifts. Added only
  /// once the display reports its modes, so tests and other platforms never
  /// get timers.
  Future<void> watchTouches() async {
    if (!_android || _routeAdded) return;
    await _loadSupported();
    if ((_supportedHz ?? const []).length < 2 || _routeAdded) return;
    _routeAdded = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    await _applyRefresh();
  }

  void _onPointer(PointerEvent e) {
    switch (e) {
      case PointerDownEvent():
        _noteTouch();
      case PointerMoveEvent():
        _lastTouch = DateTime.now();
        _gestureTail?.cancel();
        _gestureTail = null;
        unawaited(requestHighRefresh('gesture', true));
      case PointerUpEvent() || PointerCancelEvent():
        _lastTouch = DateTime.now();
        _gestureTail?.cancel();
        _gestureTail = Timer(RefreshPolicy.boostTail, () {
          _gestureTail = null;
          unawaited(requestHighRefresh('gesture', false));
        });
      default:
    }
  }

  void _noteTouch() {
    _lastTouch = DateTime.now();
    _idleTimer ??= Timer(RefreshPolicy.idleAfter, _checkIdle);
    if (_active) return;
    _active = true;
    unawaited(_applyRefresh());
  }

  void _checkIdle() {
    _idleTimer = null;
    final since = DateTime.now().difference(_lastTouch);
    if (since < RefreshPolicy.idleAfter) {
      _idleTimer = Timer(RefreshPolicy.idleAfter - since, _checkIdle);
      return;
    }
    _active = false;
    unawaited(_applyRefresh());
  }

  Future<void> _loadSupported() async {
    if (_supportedHz != null) return;
    try {
      final r = await _channel.invokeMethod<Map<Object?, Object?>>('info');
      final rates = r?['refreshRates'];
      _supportedHz = [
        if (rates is List)
          for (final x in rates)
            if (x is num) x.toDouble(),
      ];
    } catch (_) {
      _supportedHz = const [];
    }
  }

  Future<void> _applyRefresh() async {
    if (!_android) return;
    await _loadSupported();
    final hz = RefreshPolicy.pick(
      mode: _refreshMode,
      supported: _supportedHz ?? const [],
      boosting: _highReasons.isNotEmpty,
      active: _active,
    );
    await setRefreshRate(hz);
  }

  /// Whether a physical keyboard is attached (Android); null when unknown.
  Future<bool?> hardwareKeyboard() async {
    if (!_android) return null;
    try {
      final r = await _channel.invokeMethod<Map<Object?, Object?>>('info');
      final k = r?['hardwareKeyboard'];
      return k is bool ? k : null;
    } catch (_) {
      return null;
    }
  }

  /// Whether an email app can take a draft ([package] only: Gmail is
  /// `com.google.android.gm`). False off Android.
  Future<bool> emailApp({String? package}) async {
    if (!_android) return false;
    try {
      final r = await _channel.invokeMethod<bool>('emailApp', {
        'package': ?package,
      });
      return r == true;
    } catch (_) {
      return false;
    }
  }

  /// Opens an email app's compose screen with the draft; false when none
  /// opened (other platforms, an older build, no app).
  Future<bool> composeEmail({
    String? package,
    required List<String> to,
    required String subject,
    required String body,
  }) async {
    if (!_android) return false;
    try {
      final r = await _channel.invokeMethod<bool>('composeEmail', {
        'package': ?package,
        'to': to,
        'subject': subject,
        'body': body,
      });
      return r == true;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system share sheet with [text]; false when there is none
  /// (other platforms, or an older build), so the caller can copy instead.
  Future<bool> shareText(String text, {String? subject}) async {
    if (!_android) return false;
    try {
      final r = await _channel.invokeMethod<bool>('share', {
        'text': text,
        'subject': ?subject,
      });
      return r == true;
    } catch (_) {
      return false;
    }
  }

  /// What the display can do, what the app asked for and what caps it.
  Future<RefreshStatus?> refreshStatus() async {
    if (!_android) return null;
    try {
      final r = await _channel.invokeMethod<Map<Object?, Object?>>(
        'refreshStatus',
      );
      return _report(r, 'status');
    } catch (_) {
      return null;
    }
  }

  RefreshStatus? _report(Map<Object?, Object?>? r, String what) {
    if (r == null) return null;
    final s = RefreshStatus.fromMap(r);
    lastRefreshStatus = s;
    // Debug builds only: lets on-device checks read the request in logcat.
    if (kDebugMode) debugPrint('HermesRefresh $what: $s');
    return s;
  }

  /// Plays [tones] (Hz, ms) at about −18 dBFS.
  Future<void> playTone(List<(double, int)> tones) async {
    const gain = 0.125; // −18 dBFS
    if (kIsWeb) {
      web_tone.play(tones, gain);
      return;
    }
    if (!_android) return;
    try {
      await _channel.invokeMethod<void>('playTone', {
        'tones': [
          for (final (hz, ms) in tones) [hz, ms],
        ],
        'gain': gain,
      });
    } catch (_) {}
  }
}

/// The display's refresh-rate state as Android reports it.
@immutable
class RefreshStatus {
  const RefreshStatus({
    this.supportedHz = const [],
    this.currentHz,
    this.requestedHz,
    this.peakSettingHz,
    this.powerSave = false,
  });

  factory RefreshStatus.fromMap(Map<Object?, Object?> m) {
    double? d(Object? v) => v is num ? v.toDouble() : null;
    final rates = m['supportedHz'];
    return RefreshStatus(
      supportedHz: [
        if (rates is List)
          for (final r in rates)
            if (r is num) r.toDouble(),
      ],
      currentHz: d(m['currentHz']),
      requestedHz: d(m['requestedHz']),
      peakSettingHz: d(m['peakSettingHz']),
      powerSave: m['powerSave'] == true,
    );
  }

  final List<double> supportedHz;
  final double? currentHz;

  /// The rate of the mode the app asked for; null when it asks for none.
  final double? requestedHz;

  /// The system's "peak refresh rate" setting (Smooth display, Bedtime or
  /// other modes lower it), when readable.
  final double? peakSettingHz;
  final bool powerSave;

  double? get maxHz =>
      supportedHz.isEmpty ? null : supportedHz.reduce((a, b) => a > b ? a : b);

  /// Why the display cannot reach [maxHz], or null when nothing caps it.
  String? get systemCap {
    final max = maxHz;
    if (max == null) return null;
    if (powerSave) return 'battery saver';
    final peak = peakSettingHz;
    if (peak != null && peak > 0 && peak + 1 < max) {
      return 'system peak refresh setting ${peak.round()} Hz';
    }
    return null;
  }

  @override
  String toString() =>
      'supported=${supportedHz.map((r) => r.round()).toList()} '
      'current=${currentHz?.round()} requested=${requestedHz?.round()} '
      'peakSetting=${peakSettingHz?.round()} powerSave=$powerSave '
      'cap=${systemCap ?? 'none'}';
}
