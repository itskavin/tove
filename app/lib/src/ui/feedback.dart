import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../platform/device.dart';
import '../settings/settings.dart';

enum Haptic { light, medium, heavy, selection }

enum Cue {
  /// Two soft rising tones, 120 ms (live connected).
  connected,

  /// One falling tone, 140 ms (live ended).
  ended,
}

/// Where feedback goes. Tests use a recording sink.
abstract interface class FeedbackSink {
  void haptic(Haptic h);
  void cue(Cue c);
}

class PlatformFeedbackSink implements FeedbackSink {
  PlatformFeedbackSink(this.device);
  final DeviceServices device;

  /// Android goes through the device channel first (vibrator primitives):
  /// the framework's view constants are silently dropped on many devices,
  /// which made haptics seem to fire only sometimes.
  @override
  void haptic(Haptic h) {
    if (!device.android) return _framework(h);
    unawaited(
      device.haptic(h.name).then((played) {
        if (!played) _framework(h);
      }),
    );
  }

  static void _framework(Haptic h) {
    switch (h) {
      case Haptic.light:
        HapticFeedback.lightImpact();
      case Haptic.medium:
        HapticFeedback.mediumImpact();
      case Haptic.heavy:
        HapticFeedback.heavyImpact();
      case Haptic.selection:
        HapticFeedback.selectionClick();
    }
  }

  @override
  void cue(Cue c) {
    device.playTone(switch (c) {
      Cue.connected => const [(660.0, 55), (880.0, 65)],
      Cue.ended => const [(620.0, 140)],
    });
  }
}

/// Haptics (mobile only) and sounds (live mode only), each behind its
/// setting (spec §7.1, §7.2).
class AppFeedback {
  AppFeedback({required this.settings, required this.sink, bool? mobile})
    : _mobile =
          mobile ??
          (!kIsWeb &&
              (defaultTargetPlatform == TargetPlatform.android ||
                  defaultTargetPlatform == TargetPlatform.iOS));

  final SettingsController settings;
  final FeedbackSink sink;
  final bool _mobile;

  void haptic(Haptic h) {
    if (_mobile && settings.haptics) sink.haptic(h);
  }

  void cue(Cue c) {
    if (settings.sounds) sink.cue(c);
  }
}

class FeedbackScope extends InheritedWidget {
  const FeedbackScope({
    super.key,
    required this.feedback,
    required super.child,
  });

  final AppFeedback? feedback;

  static AppFeedback? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FeedbackScope>()?.feedback;

  /// Fires [h] if feedback is available here.
  static void haptic(BuildContext context, Haptic h) => context
      .getInheritedWidgetOfExactType<FeedbackScope>()
      ?.feedback
      ?.haptic(h);

  @override
  bool updateShouldNotify(FeedbackScope old) => old.feedback != feedback;
}
