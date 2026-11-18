import 'dart:async';

import 'package:flutter/foundation.dart';

enum DictationEngineKind {
  /// The user's own Tove server (`POST /api/transcribe`, capability
  /// `transcribe`): gpt-4o-transcribe through the server's ChatGPT login.
  /// The most accurate for accented English (voice-models.md "Dictation
  /// accuracy"); needs the server and a connection.
  server,

  /// Android `SpeechRecognizer`: Google's online recogniser by default (much
  /// better with accents), the on-device one with "On this device only".
  system,

  /// sherpa-onnx with Moonshine tiny (English), fully offline after a 30 MB
  /// download.
  moonshine,
}

enum DictationErrorKind {
  /// Nothing recognisable was said ("Couldn't hear that").
  noMatch,

  /// No speech before the timeout.
  speechTimeout,
  permissionDenied,

  /// Denied with "don't ask again": only Settings can change it.
  permissionPermanentlyDenied,
  network,
  audio,
  busy,
  languageNotSupported,

  /// The on-device language pack is missing (Android 13+ can download it).
  languageUnavailable,

  /// No recogniser on this device or platform. Fall back to the keyboard.
  unavailable,

  /// The offline model is not downloaded.
  modelMissing,
  server,
  other,
}

@immutable
class DictationError {
  const DictationError(this.kind, this.message, {this.code});

  final DictationErrorKind kind;

  /// Short, user-facing.
  final String message;

  /// The platform error code, when there was one.
  final int? code;

  /// Errors after which the composer should just focus the text field.
  bool get fallBackToKeyboard =>
      kind == DictationErrorKind.unavailable ||
      kind == DictationErrorKind.modelMissing;

  /// Errors whose fix is in system settings.
  bool get needsSettings => kind == DictationErrorKind.permissionPermanentlyDenied;

  /// Maps `SpeechRecognizer.ERROR_*` to a clear message.
  factory DictationError.fromAndroid(int code) => switch (code) {
    1 || 2 => DictationError(
      DictationErrorKind.network,
      'Speech recognition needs a connection.',
      code: code,
    ),
    3 => DictationError(
      DictationErrorKind.audio,
      'The microphone could not be read.',
      code: code,
    ),
    4 || 11 => DictationError(
      DictationErrorKind.server,
      'The speech service had a problem. Try again.',
      code: code,
    ),
    6 => DictationError(
      DictationErrorKind.speechTimeout,
      "Didn't hear anything.",
      code: code,
    ),
    7 => DictationError(DictationErrorKind.noMatch, "Couldn't hear that.", code: code),
    8 => DictationError(
      DictationErrorKind.busy,
      'Speech recognition is busy. Try again.',
      code: code,
    ),
    9 => DictationError(
      DictationErrorKind.permissionDenied,
      'Microphone permission is off.',
      code: code,
    ),
    10 => DictationError(
      DictationErrorKind.busy,
      'Too many requests. Wait a moment and try again.',
      code: code,
    ),
    12 => DictationError(
      DictationErrorKind.languageNotSupported,
      "This language isn't supported for dictation.",
      code: code,
    ),
    13 => DictationError(
      DictationErrorKind.languageUnavailable,
      'The speech pack for this language is not on the device yet.',
      code: code,
    ),
    -1 => DictationError(
      DictationErrorKind.unavailable,
      'No speech recogniser on this device. Use the keyboard mic instead.',
      code: code,
    ),
    _ => DictationError(
      DictationErrorKind.other,
      'Dictation stopped unexpectedly.',
      code: code,
    ),
  };

  @override
  String toString() => 'DictationError($kind, $message)';
}

class DictationException implements Exception {
  const DictationException(this.error);
  final DictationError error;
  @override
  String toString() => error.message;
}

sealed class DictationEvent {
  const DictationEvent();
}

/// The recogniser is listening.
class DictationReady extends DictationEvent {
  const DictationReady();
}

class DictationSpeechStarted extends DictationEvent {
  const DictationSpeechStarted();
}

/// Input level 0–1, for the pulsing ring.
class DictationLevel extends DictationEvent {
  const DictationLevel(this.level);
  final double level;
}

/// Unstable text for the current utterance; replaces the previous partial.
class DictationPartial extends DictationEvent {
  const DictationPartial(this.text);
  final String text;
}

/// Stable text for an utterance. Engines that segment long dictation emit
/// several; each is appended.
class DictationFinal extends DictationEvent {
  const DictationFinal(this.text);
  final String text;
}

/// The engine stopped listening (silence, [DictationEngine.stop], or after
/// an error).
class DictationEnded extends DictationEvent {
  const DictationEnded();
}

class DictationFailed extends DictationEvent {
  const DictationFailed(this.error);
  final DictationError error;
}

class DictationAvailability {
  const DictationAvailability({
    required this.available,
    this.onDevice = false,
    this.reason,
  });

  final bool available;

  /// Audio stays on the device.
  final bool onDevice;

  /// Why it is unavailable, user-facing.
  final String? reason;
}

class DictationStart {
  const DictationStart({required this.onDevice});

  /// False for the system default recogniser, which "is likely to stream
  /// audio to remote servers" (Android docs). Show that in the UI.
  final bool onDevice;
  bool get mayUseNetwork => !onDevice;
}

/// A speech-to-text backend for [DictationController].
abstract class DictationEngine {
  DictationEngineKind get kind;

  Stream<DictationEvent> get events;

  Future<DictationAvailability> availability({bool onDeviceOnly = false});

  /// Starts listening. Throws [DictationException].
  ///
  /// [continuous]: keep listening through pauses until [stop] (press and
  /// hold, hands-free lock). Engines that cannot do it natively end as usual
  /// and [DictationController] starts them again.
  Future<DictationStart> start({
    String? language,
    bool onDeviceOnly = false,
    bool continuous = false,
  });

  /// Switches [start]'s `continuous` while listening (a tap that became a
  /// hold).
  set continuous(bool on);

  /// Stops listening and delivers what was heard.
  Future<void> stop();

  /// Stops listening and drops what was heard.
  Future<void> cancel();

  Future<void> dispose();
}
