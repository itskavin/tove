import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native speech services from `SpeechChannel.kt` (Android only).
///
/// One method channel and one event channel:
///
///  * `io.github.tovechat.tove/speech` (methods): recogniser, microphone
///    permission, raw microphone capture (for the offline engine), a streaming
///    PCM player, audio focus, network and free-space queries.
///  * `io.github.tovechat.tove/speech_events` (events): maps with a `type` of
///    `stt`, `mic`, `pcm`, `focus` or `noisy`.
///
/// Everything goes through this interface so controllers can be tested with
/// fakes. On platforms without the channel, [UnsupportedSpeechPlatform] answers
/// "not available" without throwing.
abstract interface class SpeechPlatform {
  bool get isSupported;

  /// Native events, already decoded. Broadcast.
  Stream<SpeechPlatformEvent> get events;

  // ---- Recogniser ----------------------------------------------------------

  Future<RecognizerAvailability> recognizerAvailability();

  /// Starts the platform recogniser. Returns which recogniser was used.
  /// Throws [PlatformException] with code `unavailable` when none can be used.
  Future<RecognizerStartInfo> startRecognizer({
    String? language,
    required bool preferOnDevice,
    required bool allowNetwork,
  });
  Future<void> stopRecognizer();
  Future<void> cancelRecognizer();

  /// Installed and downloadable on-device languages (Android 13+), or null.
  Future<RecognizerLanguages?> recognizerLanguages(String? language);

  /// Asks the system to download an on-device language pack (Android 13+).
  Future<bool> downloadRecognizerLanguage(String language);

  // ---- Permission ----------------------------------------------------------

  Future<MicPermission> micPermission();

  /// Shows the system prompt when it can; resolves with the new state.
  Future<MicPermission> requestMicPermission();

  // ---- Raw microphone (offline dictation) ----------------------------------

  /// Starts 16-bit mono capture; chunks arrive as [MicChunkEvent].
  Future<void> startMic({int sampleRate = 16000});
  Future<void> stopMic();

  // ---- PCM player (Kokoro) -------------------------------------------------

  Future<void> pcmOpen({required int sampleRate});

  /// Queues 16-bit little-endian mono samples. A [PcmDoneEvent] with [id]
  /// arrives once they have been heard.
  Future<void> pcmWrite(int id, Uint8List pcm16);
  Future<void> pcmPause();
  Future<void> pcmResume();

  /// Drops everything queued and releases the player.
  Future<void> pcmStop();

  // ---- Audio focus ---------------------------------------------------------

  /// `true` when granted. [mayDuck] lets other apps keep playing quietly.
  Future<bool> requestAudioFocus({bool mayDuck = false});
  Future<void> abandonAudioFocus();

  // ---- Environment ---------------------------------------------------------

  Future<NetworkInfo> networkInfo();

  /// Free bytes on the volume holding [path], or null when unknown.
  Future<int?> freeBytes(String path);
}

// ---------------------------------------------------------------------------
// Value types

enum MicPermission {
  granted,
  denied,

  /// Denied with "don't ask again"; only Settings can change it.
  permanentlyDenied,
  unsupported,
}

class RecognizerAvailability {
  const RecognizerAvailability({
    required this.available,
    required this.onDeviceAvailable,
    this.sdk,
  });

  const RecognizerAvailability.none()
    : available = false,
      onDeviceAvailable = false,
      sdk = null;

  /// A recogniser of any kind exists.
  final bool available;

  /// `createOnDeviceSpeechRecognizer` can be used (Android 12+).
  final bool onDeviceAvailable;
  final int? sdk;

  factory RecognizerAvailability.fromMap(Map<Object?, Object?> m) =>
      RecognizerAvailability(
        available: m['available'] == true,
        onDeviceAvailable: m['onDevice'] == true,
        sdk: (m['sdk'] as num?)?.toInt(),
      );
}

class RecognizerStartInfo {
  const RecognizerStartInfo({required this.onDevice});

  /// `false` means the system default recogniser, which may send audio to a
  /// server (the Android docs say it is "likely to stream audio to remote
  /// servers").
  final bool onDevice;
  bool get mayUseNetwork => !onDevice;
}

class RecognizerLanguages {
  const RecognizerLanguages({
    this.installed = const [],
    this.pending = const [],
    this.supported = const [],
    this.online = const [],
  });

  final List<String> installed;
  final List<String> pending;
  final List<String> supported;
  final List<String> online;

  factory RecognizerLanguages.fromMap(Map<Object?, Object?> m) {
    List<String> list(String k) =>
        ((m[k] as List?) ?? const []).whereType<String>().toList();
    return RecognizerLanguages(
      installed: list('installed'),
      pending: list('pending'),
      supported: list('supported'),
      online: list('online'),
    );
  }
}

class NetworkInfo {
  const NetworkInfo({
    required this.connected,
    required this.unmetered,
    this.wifi = false,
  });

  const NetworkInfo.unknown() : connected = true, unmetered = false, wifi = false;

  final bool connected;

  /// Wi-Fi, Ethernet or another network the system does not meter.
  final bool unmetered;
  final bool wifi;
}

// ---------------------------------------------------------------------------
// Events

sealed class SpeechPlatformEvent {
  const SpeechPlatformEvent();

  static SpeechPlatformEvent? decode(Object? raw) {
    if (raw is! Map) return null;
    final type = raw['type'];
    switch (type) {
      case 'stt':
        return RecognizerEvent(
          event: raw['event'] as String? ?? '',
          text: raw['text'] as String?,
          rmsDb: (raw['rms'] as num?)?.toDouble(),
          errorCode: (raw['code'] as num?)?.toInt(),
        );
      case 'mic':
        final data = raw['pcm'];
        if (data is Uint8List) return MicChunkEvent(data);
        final err = raw['error'];
        if (err is String) return MicErrorEvent(err);
        return null;
      case 'pcm':
        final id = (raw['id'] as num?)?.toInt();
        if (raw['event'] == 'done' && id != null) return PcmDoneEvent(id);
        if (raw['event'] == 'error') {
          return PcmErrorEvent(raw['message'] as String? ?? 'Playback failed.');
        }
        return null;
      case 'focus':
        return AudioFocusEvent(switch (raw['change']) {
          'gain' => AudioFocusChange.gain,
          'loss' => AudioFocusChange.loss,
          'lossTransient' => AudioFocusChange.lossTransient,
          'duck' => AudioFocusChange.duck,
          _ => AudioFocusChange.loss,
        });
      case 'noisy':
        return const AudioBecomingNoisyEvent();
    }
    return null;
  }
}

/// Raw `RecognitionListener` callback. [event] is one of `ready`, `begin`,
/// `rms`, `partial`, `final`, `end`, `error`.
class RecognizerEvent extends SpeechPlatformEvent {
  const RecognizerEvent({
    required this.event,
    this.text,
    this.rmsDb,
    this.errorCode,
  });

  final String event;
  final String? text;
  final double? rmsDb;

  /// `SpeechRecognizer.ERROR_*`, or -1 for "no recogniser".
  final int? errorCode;
}

class MicChunkEvent extends SpeechPlatformEvent {
  const MicChunkEvent(this.pcm16);
  final Uint8List pcm16;
}

class MicErrorEvent extends SpeechPlatformEvent {
  const MicErrorEvent(this.message);
  final String message;
}

class PcmDoneEvent extends SpeechPlatformEvent {
  const PcmDoneEvent(this.id);
  final int id;
}

class PcmErrorEvent extends SpeechPlatformEvent {
  const PcmErrorEvent(this.message);
  final String message;
}

enum AudioFocusChange {
  gain,

  /// Another app took audio for good (music started).
  loss,

  /// A call, an alarm or a navigation prompt; focus usually comes back.
  lossTransient,

  /// A notification; the native player lowers its own volume.
  duck,
}

class AudioFocusEvent extends SpeechPlatformEvent {
  const AudioFocusEvent(this.change);
  final AudioFocusChange change;
}

/// Headphones unplugged or Bluetooth audio dropped.
class AudioBecomingNoisyEvent extends SpeechPlatformEvent {
  const AudioBecomingNoisyEvent();
}

// ---------------------------------------------------------------------------
// Implementations

/// The Android channel. Construct once; [events] is shared.
class MethodChannelSpeechPlatform implements SpeechPlatform {
  MethodChannelSpeechPlatform({
    MethodChannel? methods,
    EventChannel? eventChannel,
  }) : _m = methods ?? const MethodChannel(channelName),
       _e = eventChannel ?? const EventChannel(eventChannelName);

  static const channelName = 'io.github.tovechat.tove/speech';
  static const eventChannelName = 'io.github.tovechat.tove/speech_events';

  final MethodChannel _m;
  final EventChannel _e;
  Stream<SpeechPlatformEvent>? _events;

  @override
  bool get isSupported => true;

  @override
  Stream<SpeechPlatformEvent> get events => _events ??= _e
      .receiveBroadcastStream()
      .map(SpeechPlatformEvent.decode)
      .where((e) => e != null)
      .cast<SpeechPlatformEvent>()
      .asBroadcastStream();

  Future<Map<Object?, Object?>> _map(String method, [Object? args]) async =>
      (await _m.invokeMapMethod<Object?, Object?>(method, args)) ?? const {};

  @override
  Future<RecognizerAvailability> recognizerAvailability() async {
    try {
      return RecognizerAvailability.fromMap(await _map('sttAvailability'));
    } on MissingPluginException {
      return const RecognizerAvailability.none();
    }
  }

  @override
  Future<RecognizerStartInfo> startRecognizer({
    String? language,
    required bool preferOnDevice,
    required bool allowNetwork,
  }) async {
    final m = await _map('sttStart', {
      'language': language,
      'preferOnDevice': preferOnDevice,
      'allowNetwork': allowNetwork,
    });
    return RecognizerStartInfo(onDevice: m['onDevice'] == true);
  }

  @override
  Future<void> stopRecognizer() => _m.invokeMethod('sttStop');

  @override
  Future<void> cancelRecognizer() => _m.invokeMethod('sttCancel');

  @override
  Future<RecognizerLanguages?> recognizerLanguages(String? language) async {
    final m = await _m.invokeMapMethod<Object?, Object?>('sttLanguages', {
      'language': language,
    });
    return m == null ? null : RecognizerLanguages.fromMap(m);
  }

  @override
  Future<bool> downloadRecognizerLanguage(String language) async =>
      await _m.invokeMethod<bool>('sttDownloadLanguage', {
        'language': language,
      }) ??
      false;

  static MicPermission _perm(String? s) => switch (s) {
    'granted' => MicPermission.granted,
    'permanentlyDenied' => MicPermission.permanentlyDenied,
    'denied' => MicPermission.denied,
    _ => MicPermission.unsupported,
  };

  @override
  Future<MicPermission> micPermission() async {
    try {
      return _perm(await _m.invokeMethod<String>('micPermission'));
    } on MissingPluginException {
      return MicPermission.unsupported;
    }
  }

  @override
  Future<MicPermission> requestMicPermission() async =>
      _perm(await _m.invokeMethod<String>('requestMicPermission'));

  @override
  Future<void> startMic({int sampleRate = 16000}) =>
      _m.invokeMethod('micStart', {'sampleRate': sampleRate});

  @override
  Future<void> stopMic() => _m.invokeMethod('micStop');

  @override
  Future<void> pcmOpen({required int sampleRate}) =>
      _m.invokeMethod('pcmOpen', {'sampleRate': sampleRate});

  @override
  Future<void> pcmWrite(int id, Uint8List pcm16) =>
      _m.invokeMethod('pcmWrite', {'id': id, 'pcm': pcm16});

  @override
  Future<void> pcmPause() => _m.invokeMethod('pcmPause');

  @override
  Future<void> pcmResume() => _m.invokeMethod('pcmResume');

  @override
  Future<void> pcmStop() => _m.invokeMethod('pcmStop');

  @override
  Future<bool> requestAudioFocus({bool mayDuck = false}) async =>
      await _m.invokeMethod<bool>('requestFocus', {'mayDuck': mayDuck}) ??
      false;

  @override
  Future<void> abandonAudioFocus() => _m.invokeMethod('abandonFocus');

  @override
  Future<NetworkInfo> networkInfo() async {
    try {
      final m = await _map('networkInfo');
      return NetworkInfo(
        connected: m['connected'] != false,
        unmetered: m['unmetered'] == true,
        wifi: m['wifi'] == true,
      );
    } on MissingPluginException {
      return const NetworkInfo.unknown();
    }
  }

  @override
  Future<int?> freeBytes(String path) async {
    try {
      return (await _m.invokeMethod<num>('freeBytes', {'path': path}))?.toInt();
    } on MissingPluginException {
      return null;
    }
  }
}

/// iOS, web and desktop: nothing native yet. Every query answers "no".
///
/// TODO(ios): SFSpeechRecognizer (`requiresOnDeviceRecognition`) and an
/// AVAudioEngine PCM player need a Swift channel with the same contract.
class UnsupportedSpeechPlatform implements SpeechPlatform {
  const UnsupportedSpeechPlatform();

  @override
  bool get isSupported => false;
  @override
  Stream<SpeechPlatformEvent> get events => const Stream.empty();
  @override
  Future<RecognizerAvailability> recognizerAvailability() async =>
      const RecognizerAvailability.none();
  @override
  Future<RecognizerStartInfo> startRecognizer({
    String? language,
    required bool preferOnDevice,
    required bool allowNetwork,
  }) => throw PlatformException(code: 'unavailable');
  @override
  Future<void> stopRecognizer() async {}
  @override
  Future<void> cancelRecognizer() async {}
  @override
  Future<RecognizerLanguages?> recognizerLanguages(String? language) async =>
      null;
  @override
  Future<bool> downloadRecognizerLanguage(String language) async => false;
  @override
  Future<MicPermission> micPermission() async => MicPermission.unsupported;
  @override
  Future<MicPermission> requestMicPermission() async =>
      MicPermission.unsupported;
  @override
  Future<void> startMic({int sampleRate = 16000}) =>
      throw PlatformException(code: 'unavailable');
  @override
  Future<void> stopMic() async {}
  @override
  Future<void> pcmOpen({required int sampleRate}) =>
      throw PlatformException(code: 'unavailable');
  @override
  Future<void> pcmWrite(int id, Uint8List pcm16) async {}
  @override
  Future<void> pcmPause() async {}
  @override
  Future<void> pcmResume() async {}
  @override
  Future<void> pcmStop() async {}
  @override
  Future<bool> requestAudioFocus({bool mayDuck = false}) async => true;
  @override
  Future<void> abandonAudioFocus() async {}
  @override
  Future<NetworkInfo> networkInfo() async => const NetworkInfo.unknown();
  @override
  Future<int?> freeBytes(String path) async => null;
}

/// The platform for the current target.
SpeechPlatform defaultSpeechPlatform() =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
    ? MethodChannelSpeechPlatform()
    : const UnsupportedSpeechPlatform();
