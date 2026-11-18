import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';

import '../../rtc/voice_transport.dart';
import '../theme/motion.dart';
import 'orb_choreography.dart';
import 'orb_state.dart';

export 'orb_state.dart';

const double _deg = math.pi / 180;

/// One frame of the orb, read by the painters. Mutated in place by
/// [OrbEngine.step] so a frame allocates nothing.
class OrbFrame {
  /// State scale around the rest diameter `D`, including breathing, audio
  /// and the error shudder (not the dock or the ended fade).
  double scale = 0.8;
  double cloudLevel = 0.55;
  double tilt = 0;
  double roll = 0;
  double drift = 0;
  double turbulence = 0.5;
  double saturation = 1;
  double errorMix = 0;
  double brightness = 0;
  double opacity = 1;
  double time = 0;

  /// Dock progress, 0 centred, 1 docked (eased).
  double dock = 0;

  /// The ended fade multiplier on size, 1 → 0.
  double endScale = 1;

  /// Reduced motion: opacity of the 2 dp outer level ring (§8.2).
  double ring = 0;

  /// Diameter of the visible circle as a fraction of `D`.
  double get diameter =>
      scale * (1 + (OrbEngine.dockScale - 1) * dock) * endScale;
}

/// A critically damped spring (stiffness 120, ζ 1.0) towards a target.
class _Spring {
  _Spring(this.x);
  double x;
  double v = 0;
  static const double _k = 120;
  static final double _c = 2 * math.sqrt(_k);

  void step(double target, double dt) {
    var left = dt;
    while (left > 1e-9) {
      final h = math.min(left, 1 / 240);
      v += (-_k * (x - target) - _c * v) * h;
      x += v * h;
      left -= h;
    }
  }

  void snap(double target) {
    x = target;
    v = 0;
  }
}

/// A timed tween from the current value to a target, restartable mid-way.
class _Tween {
  _Tween(this.value) : _from = value, _to = value;
  double value;
  double _from, _to;
  double _elapsed = 0, _duration = 0;
  Curve _curve = Curves.linear;

  double get target => _to;
  bool get done => value == _to;

  void retarget(double to, double seconds, Curve curve) {
    if (to == _to) return;
    _from = value;
    _to = to;
    _elapsed = 0;
    _duration = seconds;
    _curve = curve;
    if (seconds <= 0) value = to;
  }

  void step(double dt) {
    if (done) return;
    _elapsed += dt;
    final t = _duration <= 0 ? 1.0 : (_elapsed / _duration).clamp(0.0, 1.0);
    value = t >= 1 ? _to : _from + (_to - _from) * _curve.transform(t);
  }

  void snap() {
    value = _to;
    _from = _to;
  }
}

/// Turns the orb state, the dock target and the measured audio into
/// per-frame parameters. Pure Dart: tests drive it with [step] and fake time.
///
/// Audio: levels are 0..1 energies. Raw WebRTC levels go through [normalise]
/// (`min(1, sqrt(level × 3.2))`, §5.1). They are smoothed here, per frame,
/// with attack τ [attackTau] and release τ [releaseTau]; the shader only sees
/// the result. Unknown levels count as silence: the orb never fakes speech.
class OrbEngine extends ChangeNotifier {
  OrbEngine({OrbState state = OrbState.idle, bool docked = false})
    : _state = state,
      _dock = _Tween(docked ? 1 : 0),
      _end = _Tween(state == OrbState.ended ? 1 : 0) {
    final t = OrbTargets.of(state);
    _scale = _Spring(t.scale);
    _breatheAmp = _Spring(t.breatheAmp);
    _breathePeriod = _Spring(t.breathePeriod);
    _cloud = _Spring(t.cloudLevel);
    _swayAmp = _Spring(t.swayAmp);
    _swayPeriod = _Spring(t.swayPeriod);
    _swaySpeed = _Spring(t.swaySpeed);
    _rollRate = _Spring(t.rollRate);
    _drift = _Spring(t.drift);
    _turb = _Spring(t.turbulence);
    _sat = _Spring(t.saturation);
    _err = _Spring(t.errorMix);
    _inReact = _Spring(t.inputReact);
    _outReact = _Spring(t.outputReact);
    _apply();
  }

  /// Audio smoothing time constants, seconds (§5.1).
  static const double attackTau = 0.060, releaseTau = 0.350;

  /// e_in above this counts as user speech (direction flips per utterance).
  static const double speechThreshold = 0.08;

  /// Docked diameter as a fraction of the centred one (§3.5).
  static const double dockScale = 0.41;
  static const Duration dockDuration = Duration(milliseconds: 260);
  static const Duration undockDuration = Duration(milliseconds: 320);
  static const Curve dockCurve = Motion.dock;
  static const Curve undockCurve = Motion.standard;

  /// Ended: opacity and size → 0 over 220 ms on the exit curve (§6.1).
  static const Duration endDuration = Duration(milliseconds: 220);

  /// Error entry shudder: scale −0.02 and back over 240 ms.
  static const Duration shudderDuration = Duration(milliseconds: 240);

  /// Largest step taken at once; a longer hitch is treated as this.
  static const double maxStep = 0.1;

  /// `min(1, sqrt(level × 3.2))`; null (unknown) and ≤ 0 map to 0.
  static double normalise(double? level) {
    if (level == null || level.isNaN || level <= 0) return 0;
    return math.min(1, math.sqrt(level * 3.2));
  }

  final OrbFrame frame = OrbFrame();
  OrbState _state;
  late final _Spring _scale, _breatheAmp, _breathePeriod, _cloud, _swayAmp;
  late final _Spring _swayPeriod, _swaySpeed, _rollRate, _drift, _turb;
  late final _Spring _sat, _err, _inReact, _outReact;
  final _Tween _dock, _end;
  double? _dockOverride;

  double _rawIn = 0, _rawOut = 0;
  double _eIn = 0, _eOut = 0;
  double _clock = 0, _breathePhase = 0, _swayPhase = 0, _driftPos = 0;
  double _roll = 0, _userTilt = 0, _tiltDir = 1;
  bool _wasSpeaking = false;
  double _shudder = 1;

  OrbState get state => _state;

  /// Changes the state; parameters cross-fade on the next [step]s.
  set state(OrbState s) {
    if (s == _state) return;
    if (s == OrbState.error) _shudder = 0;
    _state = s;
    _end.retarget(
      s == OrbState.ended ? 1 : 0,
      endDuration.inMicroseconds / 1e6,
      Curves.linear,
    );
  }

  /// Smoothed user (input) and Hermes (output) energy, 0..1.
  double get levelIn => _eIn;
  double get levelOut => _eOut;

  /// Sets one 0..1 energy. Its meaning follows the state: the user's voice
  /// in idle/listening/userSpeaking, Hermes' voice in assistantSpeaking and
  /// muted. Thinking, connecting, error and ended ignore it.
  void setLevel(double energy) {
    final e = energy.isNaN ? 0.0 : energy.clamp(0.0, 1.0);
    _rawIn = e;
    _rawOut = e;
  }

  /// Sets the raw WebRTC levels (normalised here). Unknown sides are 0.
  void setLevels(AudioLevels l) {
    _rawIn = normalise(l.input);
    _rawOut = normalise(l.output);
  }

  bool get docked => _dock.target == 1;

  /// Animates to the docked (0.41 ×) or centred size: 260 ms on the dock
  /// curve, 320 ms standard back (§6.2). [animate] false jumps.
  void setDocked(bool docked, {bool animate = true}) {
    final to = docked ? 1.0 : 0.0;
    if (to == _dock.target) return;
    _dock.retarget(
      to,
      animate
          ? (docked ? dockDuration : undockDuration).inMicroseconds / 1e6
          : 0,
      docked ? dockCurve : undockCurve,
    );
  }

  /// A 0..1 dock factor driven by the caller (for example its own
  /// AnimationController that also moves the orb). Null uses [setDocked].
  double? get dockOverride => _dockOverride;
  set dockOverride(double? v) {
    _dockOverride = v?.clamp(0.0, 1.0);
  }

  /// Live-mode placement, stepped by this engine's ticks (the orb's single
  /// ticker) and, when set, the source of the dock factor. See
  /// [OrbChoreographer].
  OrbChoreographer? choreographer;

  /// False once the ended fade has finished: nothing moves any more.
  bool get needsFrames => !(_state == OrbState.ended && _end.done);

  /// True when the ended fade has completed.
  bool get finished => _state == OrbState.ended && _end.done;

  /// Advances by [dt] seconds and notifies listeners (the painter).
  void step(double dt) {
    if (dt.isNaN || dt < 0) dt = 0;
    dt = math.min(dt, maxStep);
    final t = OrbTargets.of(_state);
    _scale.step(t.scale, dt);
    _breatheAmp.step(t.breatheAmp, dt);
    _breathePeriod.step(t.breathePeriod, dt);
    _cloud.step(t.cloudLevel, dt);
    _swayAmp.step(t.swayAmp, dt);
    _swayPeriod.step(t.swayPeriod, dt);
    _swaySpeed.step(t.swaySpeed, dt);
    _rollRate.step(t.rollRate, dt);
    _drift.step(t.drift, dt);
    _turb.step(t.turbulence, dt);
    _err.step(t.errorMix, dt);
    _inReact.step(t.inputReact, dt);
    _outReact.step(t.outputReact, dt);
    // Saturation: ≈ 250 ms into muted, ≈ 400 ms back (§6.1).
    _sat.step(t.saturation, dt * (t.saturation < _sat.x ? 1.6 : 1.0));
    _dock.step(dt);
    _end.step(dt);
    choreographer?.step(dt);

    _eIn = _smooth(_eIn, _rawIn, dt);
    _eOut = _smooth(_eOut, _rawOut, dt);

    final eIn = _eIn * _inReact.x.clamp(0.0, 1.0);
    final speaking = eIn > speechThreshold;
    if (speaking && !_wasSpeaking) _tiltDir = -_tiltDir;
    _wasSpeaking = speaking;

    final eOut = _eOut * _outReact.x.clamp(0.0, 1.0);
    _clock += dt;
    _breathePhase += dt * 2 * math.pi / math.max(0.5, _breathePeriod.x);
    _swayPhase += dt * _swaySpeed.x * 2 * math.pi / math.max(1, _swayPeriod.x);
    _roll = (_roll + dt * _rollRate.x) % (2 * math.pi);
    _driftPos += dt * (_drift.x + 0.06 * eIn + 0.08 * eOut);
    final userTilt = _tiltDir * 18 * _deg * eIn;
    _userTilt += (userTilt - _userTilt) * (1 - math.exp(-dt / 0.12));
    if (_shudder < 1) {
      _shudder = math.min(
        1,
        _shudder + dt / (shudderDuration.inMicroseconds / 1e6),
      );
    }
    _apply();
    notifyListeners();
  }

  static double _smooth(double e, double target, double dt) {
    final tau = target > e ? attackTau : releaseTau;
    return e + (target - e) * (1 - math.exp(-dt / tau));
  }

  void _apply() {
    final f = frame;
    final eIn = _eIn * _inReact.x.clamp(0.0, 1.0);
    final eOut = _eOut * _outReact.x.clamp(0.0, 1.0);
    final shudder = _shudder < 1 ? -0.02 * math.sin(_shudder * math.pi) : 0.0;
    // Hermes: 0.80 + 0.22·e_out (180/144 at peak); user: + 0.06·e_in.
    f.scale =
        _scale.x +
        _breatheAmp.x * math.sin(_breathePhase) +
        0.22 * eOut +
        0.06 * eIn +
        shudder;
    // Clouds rise towards 0.82 with Hermes' voice (eased); + 0.05·e_in.
    f.cloudLevel = _cloud.x + (0.82 - _cloud.x) * _easeOut(eOut) + 0.05 * eIn;
    f.tilt = _swayAmp.x * math.sin(_swayPhase) * (1 - eOut) + _userTilt;
    final touch = choreographer;
    f.tilt += touch?.touchTilt ?? 0;
    f.cloudLevel += (touch?.touchOffset.dy ?? 0) / 600;
    f.turbulence =
        _turb.x + 0.8 * eIn + 0.6 * eOut + (touch?.touchPressure ?? 0) * 0.35;
    f.roll = _roll + (touch?.touchOffset.dx ?? 0) / 140;
    f.drift = _driftPos % 4096;

    f.saturation = _sat.x.clamp(0.0, 1.0);
    f.errorMix = _err.x.clamp(0.0, 1.0);
    f.brightness = 0.06 * eOut;
    f.time = _clock % 4096;
    f.dock = choreographer?.dock ?? _dockOverride ?? _dock.value;
    final end = 1 - Motion.exit.transform(_end.value.clamp(0.0, 1.0));
    f.endScale = end;
    f.opacity = end;
    f.ring = math.max(eIn, eOut);
  }

  /// Reduced motion (§8.2): jumps to the current targets and shows a still
  /// sphere at rest scale. No breathing, drift, roll or audio movement;
  /// audio shows only as the outer ring's opacity. Notifies listeners.
  void settle() {
    final t = OrbTargets.of(_state);
    _scale.snap(t.scale);
    _breatheAmp.snap(t.breatheAmp);
    _breathePeriod.snap(t.breathePeriod);
    _cloud.snap(t.cloudLevel);
    _swayAmp.snap(t.swayAmp);
    _swayPeriod.snap(t.swayPeriod);
    _swaySpeed.snap(t.swaySpeed);
    _rollRate.snap(t.rollRate);
    _drift.snap(t.drift);
    _turb.snap(t.turbulence);
    _sat.snap(t.saturation);
    _err.snap(t.errorMix);
    _inReact.snap(t.inputReact);
    _outReact.snap(t.outputReact);
    _dock.snap();
    _end.snap();
    _shudder = 1;
    _eIn = 0;
    _eOut = 0;
    _userTilt = 0;
    _apply();
    frame
      ..scale = t.scale
      ..cloudLevel = t.cloudLevel
      ..tilt = 0
      ..roll = 0
      ..drift = 0
      ..time = 0
      ..brightness = 0
      ..ring = math.max(_rawIn * t.inputReact, _rawOut * t.outputReact);
    notifyListeners();
  }
}

double _easeOut(double x) {
  final t = x.clamp(0.0, 1.0);
  return 1 - (1 - t) * (1 - t);
}
