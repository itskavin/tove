import 'dart:async';

import 'package:flutter/services.dart';

import '../speech_platform.dart';
import 'dictation_engine.dart';

/// Android `SpeechRecognizer` through `SpeechChannel.kt`.
///
/// Uses the default (online) recogniser unless `onDeviceOnly`: Google's
/// server models handle accented English (en-IN) far better than the small
/// on-device ones, which also fall back to en-US when the language pack is
/// missing. When the network fails before anything was heard, it retries
/// once on the device; when the on-device pack is missing and the network
/// is allowed, once online.
class SystemDictationEngine implements DictationEngine {
  SystemDictationEngine(this._platform) {
    _sub = _platform.events.listen(_onEvent);
  }

  final SpeechPlatform _platform;
  late final StreamSubscription<SpeechPlatformEvent> _sub;
  final _events = StreamController<DictationEvent>.broadcast();
  bool _active = false;

  // The running session, for the one transparent retry.
  String? _language;
  bool _onDeviceOnly = false;
  bool _onDevice = false;
  bool _heard = false;
  bool _retried = false;

  @override
  DictationEngineKind get kind => DictationEngineKind.system;

  @override
  Stream<DictationEvent> get events => _events.stream;

  @override
  Future<DictationAvailability> availability({bool onDeviceOnly = false}) async {
    if (!_platform.isSupported) {
      return const DictationAvailability(
        available: false,
        reason: 'Dictation is not available on this platform yet.',
      );
    }
    final a = await _platform.recognizerAvailability();
    if (a.onDeviceAvailable) {
      return const DictationAvailability(available: true, onDevice: true);
    }
    if (a.available && !onDeviceOnly) {
      return const DictationAvailability(available: true);
    }
    return DictationAvailability(
      available: false,
      reason: a.available
          ? 'On-device recognition is not available on this device.'
          : 'No speech recogniser on this device.',
    );
  }

  @override
  Future<DictationStart> start({
    String? language,
    bool onDeviceOnly = false,
    bool continuous = false,
  }) async {
    _language = language;
    _onDeviceOnly = onDeviceOnly;
    _heard = false;
    _retried = false;
    try {
      final info = await _platform.startRecognizer(
        language: language,
        preferOnDevice: onDeviceOnly,
        allowNetwork: !onDeviceOnly,
      );
      _active = true;
      _onDevice = info.onDevice;
      return DictationStart(onDevice: info.onDevice);
    } on PlatformException catch (e) {
      throw DictationException(switch (e.code) {
        'unavailable' => DictationError.fromAndroid(-1),
        'permission' => const DictationError(
          DictationErrorKind.permissionDenied,
          'Microphone permission is off.',
        ),
        'onDeviceUnavailable' => const DictationError(
          DictationErrorKind.unavailable,
          'On-device recognition is not available. Allow network '
          'recognition in Voice settings, or download offline dictation.',
        ),
        _ => DictationError(
          DictationErrorKind.other,
          e.message ?? 'Dictation could not start.',
        ),
      });
    }
  }

  void _onEvent(SpeechPlatformEvent e) {
    if (e is! RecognizerEvent || !_active) return;
    switch (e.event) {
      case 'ready':
        _events.add(const DictationReady());
      case 'begin':
        _events.add(const DictationSpeechStarted());
      case 'rms':
        // Android reports roughly -2 dB (silence) to 10 dB (loud speech).
        final db = e.rmsDb ?? -2;
        _events.add(DictationLevel(((db + 2) / 12).clamp(0.0, 1.0)));
      case 'partial':
        final t = e.text?.trim() ?? '';
        if (t.isNotEmpty) {
          _heard = true;
          _events.add(DictationPartial(t));
        }
      case 'final':
        _active = false;
        final t = e.text?.trim() ?? '';
        if (t.isNotEmpty) _events.add(DictationFinal(t));
        _events.add(const DictationEnded());
      case 'error':
        final code = e.errorCode ?? 0;
        if (_retry(code)) return;
        _active = false;
        _events.add(DictationFailed(DictationError.fromAndroid(code)));
        _events.add(const DictationEnded());
      case 'end':
        break; // End of speech; results follow.
    }
  }

  /// Online failed before any words (no network): try the device. The
  /// device has no pack for the language: try online, when allowed.
  bool _retry(int code) {
    if (_retried || _heard) return false;
    final bool onDevice;
    if ((code == 1 || code == 2) && !_onDevice) {
      onDevice = true;
    } else if ((code == 12 || code == 13) && _onDevice && !_onDeviceOnly) {
      onDevice = false;
    } else {
      return false;
    }
    _retried = true;
    unawaited(
      _platform
          .startRecognizer(
            language: _language,
            preferOnDevice: onDevice,
            allowNetwork: !onDevice,
          )
          .then((info) => _onDevice = info.onDevice)
          .catchError((Object _) {
            if (!_active) return _onDevice;
            _active = false;
            _events.add(DictationFailed(DictationError.fromAndroid(code)));
            _events.add(const DictationEnded());
            return _onDevice;
          }),
    );
    return true;
  }

  /// The recogniser always ends at a pause; [DictationController] restarts
  /// it while continuous.
  @override
  set continuous(bool on) {}

  @override
  Future<void> stop() => _platform.stopRecognizer();

  @override
  Future<void> cancel() async {
    _active = false;
    await _platform.cancelRecognizer();
    _events.add(const DictationEnded());
  }

  @override
  Future<void> dispose() async {
    await _sub.cancel();
    await _events.close();
  }
}
