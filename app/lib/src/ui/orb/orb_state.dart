import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// What the orb shows (spec §6.1).
///
/// [idle] looks like [listening] and also covers "connecting" outside a call
/// (onboarding, empty thread); use [connecting] while a call is being set up.
enum OrbState {
  idle,
  connecting,
  listening,
  userSpeaking,
  thinking,
  assistantSpeaking,
  muted,
  ended,
  error;

  /// Alias kept for callers that name the assistant's turn "speaking".
  static const OrbState speaking = assistantSpeaking;
}

/// Alias for code written against the earlier `OrbMode` name.
typedef OrbMode = OrbState;

const double _deg = math.pi / 180;

/// Static (non-audio) targets for one state, from the §6.1 table. Each value
/// is cross-faded with a spring (stiffness 120, ζ 1.0, ≈ 450 ms) when the
/// state changes; the audio-driven terms are added on top per frame.
@immutable
class OrbTargets {
  const OrbTargets({
    required this.scale,
    this.breatheAmp = 0,
    this.breathePeriod = 4.2,
    this.cloudLevel = 0.55,
    this.swayAmp = 0,
    this.swayPeriod = 9,
    this.swaySpeed = 1,
    this.rollRate = 0,
    this.drift = 0.035,
    this.turbulence = 0.5,
    this.saturation = 1,
    this.errorMix = 0,
    this.inputReact = 0,
    this.outputReact = 0,
  });

  /// Diameter multiplier around the rest size `D`.
  final double scale;

  /// Breathing: ± amplitude on [scale] and its period in seconds.
  final double breatheAmp;
  final double breathePeriod;

  /// Horizon height: 0 = clouds at the bottom, 1 = clouds fill the orb.
  final double cloudLevel;

  /// Slow horizon sway (radians) and its period in seconds.
  final double swayAmp;
  final double swayPeriod;

  /// 0 freezes the sway where it is (muted: "frozen tilt").
  final double swaySpeed;

  /// Rotation of the noise field, radians per second.
  final double rollRate;

  /// Noise scroll, diameters per second.
  final double drift;
  final double turbulence;

  /// 1 normal, 0.35 muted.
  final double saturation;

  /// 0 normal sky, 1 error tint.
  final double errorMix;

  /// How strongly the user's level (e_in) and Hermes' level (e_out) move the
  /// orb, 0..1.
  final double inputReact;
  final double outputReact;

  /// The §6.1 table.
  static OrbTargets of(OrbState s) => switch (s) {
    OrbState.connecting => const OrbTargets(
      scale: 0.86,
      breatheAmp: 0.03,
      breathePeriod: 1.6,
      cloudLevel: 0.50,
      rollRate: 15 * _deg,
      drift: 0.03,
      turbulence: 0.4,
      saturation: 0.7,
    ),
    OrbState.idle || OrbState.listening => const OrbTargets(
      scale: 0.80,
      breatheAmp: 0.012,
      breathePeriod: 4.2,
      swayAmp: 6 * _deg,
      swayPeriod: 9,
      inputReact: 1,
    ),
    OrbState.userSpeaking => const OrbTargets(
      scale: 0.80,
      breatheAmp: 0.012,
      swayAmp: 6 * _deg,
      inputReact: 1,
    ),
    OrbState.assistantSpeaking => const OrbTargets(
      scale: 0.80,
      breatheAmp: 0.006,
      drift: 0.05,
      turbulence: 0.6,
      outputReact: 1,
    ),
    // The reference's pre-answer roll (§0, video 5.0–6.8 s): the noise field
    // turns at 45°/s and the horizon swings ±32° (peak ≈ 48°/s), so it tilts
    // the measured 35–40° within about 0.75 s.
    OrbState.thinking => const OrbTargets(
      scale: 0.80,
      breatheAmp: 0.008,
      cloudLevel: 0.50,
      swayAmp: 32 * _deg,
      swayPeriod: 4.2,
      rollRate: 45 * _deg,
      drift: 0.05,
      turbulence: 0.7,
    ),
    OrbState.muted => const OrbTargets(
      scale: 0.76,
      breatheAmp: 0.008,
      swayAmp: 6 * _deg,
      swaySpeed: 0,
      drift: 0.015,
      turbulence: 0.3,
      saturation: 0.35,
      outputReact: 1,
    ),
    OrbState.error => const OrbTargets(
      scale: 0.78,
      cloudLevel: 0.45,
      drift: 0.01,
      turbulence: 0.2,
      errorMix: 1,
    ),
    // The ended fade (opacity and scale → 0, 220 ms) is a separate timeline
    // in the engine; the parameters hold still underneath it.
    OrbState.ended => const OrbTargets(
      scale: 0.80,
      drift: 0.01,
      turbulence: 0.3,
    ),
  };
}
