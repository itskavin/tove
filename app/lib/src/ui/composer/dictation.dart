import 'package:flutter/foundation.dart';

/// Where in-app dictation is (spec §5.3).
enum ComposerDictationPhase {
  /// Not listening.
  idle,

  /// Asked to start: waiting for the permission or the recogniser.
  starting,

  /// Listening; [ComposerDictation.partial] and [ComposerDictation.level]
  /// update.
  listening,

  /// Stopped by the user or silence; the last result is being finalised.
  stopping,
}

/// Why dictation could not run.
enum ComposerDictationErrorKind {
  /// The microphone permission was refused.
  permissionDenied,

  /// Permanently refused: only the system settings can turn it back on.
  permissionBlocked,

  /// No speech recogniser on this device (fall back to the keyboard).
  unavailable,

  /// Nothing was understood.
  noMatch,

  /// Network or engine failure.
  other,
}

@immutable
class ComposerDictationError {
  const ComposerDictationError(this.kind, [this.message]);
  final ComposerDictationErrorKind kind;
  final String? message;
}

/// What the composer needs from the speech module's dictation.
///
/// The composer binds to this interface only. The speech module's
/// `DictationController` is adapted to it by `SpeechComposerDictation`
/// (`speech_dictation.dart`), so the two can change independently.
///
/// Contract:
/// - [start] moves `idle → starting → listening`; on failure it ends `idle`
///   with [error] set.
/// - While listening, [partial] holds the words heard so far in this
///   session (replaced, not appended, on each update) and [level] the input
///   level in 0…1.
/// - [stop] keeps the words; the session ends `idle` with [finalText] set.
/// - [cancel] throws the words away and ends `idle`.
/// - [start] with `continuous` (press and hold, hands-free) keeps listening
///   through pauses until [stop]; [continuous] switches it while listening.
/// - Listeners are notified on every change.
abstract class ComposerDictation implements Listenable {
  ComposerDictationPhase get phase;

  /// Words heard so far in this session.
  String get partial;

  /// The start of [partial] the engine has already made final; only the
  /// rest is drawn muted. Empty when the engine does not say.
  String get stablePrefix => '';

  /// The final transcript after a [stop] (or the silence timeout), or null.
  String? get finalText;

  /// Input level, 0 (silence) … 1 (loud).
  double get level;

  ComposerDictationError? get error;

  /// False when the device has no recogniser: the mic then focuses the
  /// field so the keyboard's own voice key can be used.
  bool get available;

  Future<void> start({bool continuous = false});

  /// See [start]. A tap that turned into a hold sets it.
  set continuous(bool on);

  /// Looks up what dictation needs (the server's capability) ahead of the
  /// first press. Cheap; may be called often.
  void warmUp();

  Future<void> stop();
  Future<void> cancel();

  /// Clears [error] and [finalText] once the composer has used them.
  void acknowledge();
}
