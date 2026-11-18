import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../speech/dictation/dictation_engine.dart' as speech;
import '../../speech/dictation_controller.dart' as speech;
import 'dictation.dart';

/// Binds the speech module's [speech.DictationController] to the composer:
/// `Composer(dictation: SpeechComposerDictation(controller))`.
///
/// The controller stays owned by whoever created it; this adapter only
/// reads its state and forwards start, stop and cancel.
class SpeechComposerDictation implements ComposerDictation {
  SpeechComposerDictation(this.controller, {this.available = true});

  final speech.DictationController controller;

  /// The controller only knows asynchronously
  /// ([speech.DictationController.availability]); an `unavailable` error
  /// at start falls back to the keyboard anyway.
  @override
  final bool available;

  /// The finished session whose text the composer already took.
  speech.DictationState? _acknowledged;

  speech.DictationState get _s => controller.value;

  @override
  ComposerDictationPhase get phase => switch (_s.status) {
    speech.DictationStatus.starting => ComposerDictationPhase.starting,
    speech.DictationStatus.listening => ComposerDictationPhase.listening,
    speech.DictationStatus.finishing => ComposerDictationPhase.stopping,
    speech.DictationStatus.idle ||
    speech.DictationStatus.error => ComposerDictationPhase.idle,
  };

  @override
  String get partial => _s.text;

  @override
  String get stablePrefix => _s.committed;

  @override
  String? get finalText {
    final s = _s;
    if (s.status != speech.DictationStatus.idle ||
        identical(s, _acknowledged)) {
      return null;
    }
    final t = s.committed.trim();
    return t.isEmpty ? null : t;
  }

  @override
  double get level => _s.level;

  @override
  ComposerDictationError? get error {
    final s = _s;
    final e = s.error;
    if (s.status != speech.DictationStatus.error ||
        e == null ||
        identical(s, _acknowledged)) {
      return null;
    }
    return ComposerDictationError(switch (e.kind) {
      speech.DictationErrorKind.noMatch ||
      speech.DictationErrorKind.speechTimeout =>
        ComposerDictationErrorKind.noMatch,
      speech.DictationErrorKind.permissionDenied =>
        ComposerDictationErrorKind.permissionDenied,
      speech.DictationErrorKind.permissionPermanentlyDenied =>
        ComposerDictationErrorKind.permissionBlocked,
      speech.DictationErrorKind.unavailable =>
        ComposerDictationErrorKind.unavailable,
      _ => ComposerDictationErrorKind.other,
    }, e.message);
  }

  @override
  Future<void> start({bool continuous = false}) =>
      controller.start(continuous: continuous);

  @override
  set continuous(bool on) => controller.continuous = on;

  @override
  void warmUp() => unawaited(controller.warmUp());

  @override
  Future<void> stop() => controller.stop();

  @override
  Future<void> cancel() => controller.cancel();

  @override
  void acknowledge() {
    _acknowledged = _s;
    if (_s.status == speech.DictationStatus.error) controller.dismissError();
  }

  @override
  void addListener(VoidCallback listener) => controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      controller.removeListener(listener);
}
