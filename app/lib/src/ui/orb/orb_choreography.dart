import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show EdgeInsets, Offset, Size;

import '../theme/tokens.dart';

/// Where the orb wants to be (live mode, spec §2.3, §4.1, §4.2, §6.2).
enum OrbStage {
  /// Idle, connecting, listening, speaking with nothing to read: the orb is
  /// large and centred.
  centred,

  /// Rich content is on screen: the orb shrinks to 0.41 × and sits above
  /// the composer, over the text.
  docked,
}

/// The orb's centre and dock factor (0 centred size … 1 docked size).
@immutable
class OrbPose {
  const OrbPose(this.centre, this.dock);

  final Offset centre;
  final double dock;

  @override
  bool operator ==(Object other) =>
      other is OrbPose && other.centre == centre && other.dock == dock;

  @override
  int get hashCode => Object.hash(centre, dock);

  @override
  String toString() =>
      'OrbPose(${centre.dx.toStringAsFixed(1)}, '
      '${centre.dy.toStringAsFixed(1)}, dock ${dock.toStringAsFixed(2)})';
}

/// The geometry the poses are computed from, in the live layer's
/// coordinates.
@immutable
class OrbStageLayout {
  const OrbStageLayout({
    required this.size,
    required this.padding,
    required this.topInset,
    required this.composerTop,
    this.cardsExtent = 0,
    this.labelShown = false,
  });

  /// The live layer's size.
  final Size size;

  /// The safe-area padding (status bar, navigation bar).
  final EdgeInsets padding;

  /// The bottom of the app bar (the content starts 8 dp under it).
  final double topInset;

  /// The composer's top edge.
  final double composerTop;

  /// Height of the task-card stack drawn above the orb (0 when none).
  final double cardsExtent;

  /// A status label is shown under the orb: the docked orb lifts by
  /// [OrbChoreography.labelLift] to make room (§6.2).
  final bool labelShown;

  /// The rest diameter `D` (`orbCentered`, §3.5) and the orb's layout box.
  double get diameter => Sz.orbCentered(size.width);

  @override
  bool operator ==(Object other) =>
      other is OrbStageLayout &&
      other.size == size &&
      other.padding == padding &&
      other.topInset == topInset &&
      other.composerTop == composerTop &&
      other.cardsExtent == cardsExtent &&
      other.labelShown == labelShown;

  @override
  int get hashCode => Object.hash(
    size,
    padding,
    topInset,
    composerTop,
    cardsExtent,
    labelShown,
  );
}

/// The live-mode orb choreography: where the orb sits per stage, and the
/// constants used to move it there.
abstract final class OrbChoreography {
  /// The centred orb's centre sits at this fraction of the safe height (§3.5).
  static const double centreFraction = 0.46;

  /// Gap between the docked orb's box and the composer top (§3.5).
  static const double dockGap = 40;

  /// The docked orb lifts this much while a status label shows (§6.2).
  static const double labelLift = 8;

  /// Gap between the task cards and the orb, and above the cards.
  static const double cardsGap = 12;

  /// Space kept under the centred orb for the status label.
  static const double labelRoom = 48;

  /// Springs, `SpringDescription.withDampingRatio(mass: 1, k, ζ)`. Critically
  /// damped travel settles to 98 % in ≈ 5.8 / √k s, so the dock spring lands
  /// in the measured 260 ms and the undock spring in 320 ms (§6.2). Springs
  /// keep their velocity when retargeted mid-flight.
  static const double dockStiffness = 500, undockStiffness = 330;

  /// Moves within a stage (cards appear, the label shows, the window
  /// resizes): ≈ 360 ms.
  static const double moveStiffness = 260;

  /// The speaker nudge: a soft, slightly bouncy spring (ζ 0.6).
  static const double nudgeStiffness = 220, nudgeDamping = 0.6;

  /// The interruption "flinch" on the orb's scale (ζ 0.5).
  static const double pulseStiffness = 420, pulseDamping = 0.5;

  /// Nudge sizes as fractions of `D` (the docked orb uses 40 % of these).
  /// The user speaking pulls the orb towards the microphone (down) and
  /// sideways, alternating per utterance like the tilt (§6.1); Hermes
  /// speaking lifts it a little.
  static const double userPull = 0.05, userSway = 0.025, hermesLift = 0.03;

  /// Barge-in: the user starts talking over Hermes. Velocity kicks, in D/s
  /// for the position and 1/s for the scale.
  static const double interruptKick = 1.6, interruptSquash = 0.9;

  /// The visible orb's radius bound used to place cards and labels around
  /// it: 0.46·D centred (speech peaks reach 0.5·D), 0.2·D docked.
  static double radius(double diameter, double dock) =>
      diameter * (0.46 + (0.2 - 0.46) * dock.clamp(0.0, 1.0));

  /// The pose for [stage] in [layout].
  static OrbPose pose(OrbStage stage, OrbStageLayout layout) {
    final w = layout.size.width, h = layout.size.height;
    final d = layout.diameter;
    final safeH = h - layout.padding.top - layout.padding.bottom;
    switch (stage) {
      case OrbStage.centred:
        var y = layout.padding.top + safeH * centreFraction;
        if (layout.cardsExtent > 0) {
          // Keep the cards (stacked above the orb) under the app bar.
          final minY =
              layout.topInset +
              8 +
              layout.cardsExtent +
              cardsGap +
              radius(d, 0);
          y = math.max(y, minY);
        }
        // Never into the composer: leave the label its room.
        final maxY = layout.composerTop - labelRoom - d / 2;
        y = math.min(y, maxY);
        return OrbPose(Offset(w / 2, y), 0);
      case OrbStage.docked:
        var y = layout.composerTop - dockGap - d * Sz.dockRatio / 2;
        if (layout.labelShown) y -= labelLift;
        return OrbPose(Offset(w / 2, y), 1);
    }
  }
}

/// A 1-D damped spring, integrated with semi-implicit Euler substeps.
class _Spring {
  _Spring(this.x) : target = x;

  double x, target;
  double v = 0;
  double k = OrbChoreography.moveStiffness, zeta = 1;

  void snap(double to) {
    x = to;
    target = to;
    v = 0;
  }

  bool get settled => (x - target).abs() < 0.01 && v.abs() < 0.05;

  void step(double dt) {
    final c = 2 * zeta * math.sqrt(k);
    var left = dt;
    while (left > 0) {
      final h = math.min(left, 1 / 240);
      v += (-k * (x - target) - c * v) * h;
      x += v * h;
      left -= h;
    }
    if (settled) {
      x = target;
      v = 0;
    }
  }
}

/// Moves the orb between poses with springs, plus small audio-driven nudges
/// and an interruption flinch. Pure Dart: [step] advances it.
///
/// It has no ticker of its own: attach it to the orb's [OrbEngine]
/// (`engine.choreographer = c`) and the orb's single ticker steps it every
/// frame. Listeners (the live layer's `FlowDelegate`) repaint; nothing
/// rebuilds or relayouts per frame.
///
/// With [reduced] motion there is no travel: poses snap, nudges and
/// flinches are off (spec §8.2).
class OrbChoreographer extends ChangeNotifier {
  OrbChoreographer();

  final _x = _Spring(0), _y = _Spring(0), _dock = _Spring(0);
  final _nx = _Spring(0), _ny = _Spring(0), _pulse = _Spring(1);
  final _tx = _Spring(0), _ty = _Spring(0), _press = _Spring(0);
  OrbPose? _target;
  double _diameter = 200;
  bool _reduced = false;
  bool _userWas = false;
  double _swayDir = 1;
  int _interruptions = 0;

  /// The pose being moved to, or null before the first [moveTo].
  OrbPose? get target => _target;

  /// Times a barge-in was seen (for tests and diagnostics).
  int get interruptions => _interruptions;

  /// No travel, no nudges (spec §8.2).
  bool get reduced => _reduced;
  set reduced(bool v) {
    if (v == _reduced) return;
    _reduced = v;
    if (v) {
      _nx.snap(0);
      _ny.snap(0);
      _pulse.snap(1);
      _tx.snap(0);
      _ty.snap(0);
      _press.snap(0);
      final t = _target;
      if (t != null) _snapTo(t);
      notifyListeners();
    }
  }

  /// The orb's centre now, nudges included.
  Offset get centre => Offset(_x.x + _nx.x + _tx.x, _y.x + _ny.x + _ty.x);

  /// Direct manipulation is independent of the audio nudges.
  Offset get touchOffset => Offset(_tx.x, _ty.x);
  double get touchPressure => _press.x.clamp(0.0, 1.0);
  double get touchTilt => _tx.x / _diameter * 0.65;
  double get touchStretch => (_ty.x.abs() / _diameter * 0.25).clamp(0.0, 0.10);

  /// Follows the finger immediately, with resistance near the travel limit.
  void touch(Offset delta) {
    if (_reduced) return;
    final limit = _diameter * (0.65 - 0.35 * dock);
    final resisted = delta / (1 + delta.distance / limit);
    _tx.snap(resisted.dx);
    _ty.snap(resisted.dy);
    _press.snap(1);
    notifyListeners();
  }

  /// A soft spring returns the orb to its audio-driven resting pose.
  void releaseTouch([Offset velocity = Offset.zero]) {
    if (_reduced) {
      _tx.snap(0);
      _ty.snap(0);
      _press.snap(0);
      return;
    }
    for (final s in [_tx, _ty, _press]) {
      s
        ..target = 0
        ..k = 240
        ..zeta = 0.64;
    }
    _tx.v = velocity.dx.clamp(-700.0, 700.0) * 0.15;
    _ty.v = velocity.dy.clamp(-700.0, 700.0) * 0.15;
    notifyListeners();
  }

  /// The dock factor now, 0..1.
  double get dock => _dock.x.clamp(0.0, 1.0);

  /// A scale multiplier around 1 (the interruption flinch).
  double get pulse => _pulse.x;

  /// The base pose now, without nudges.
  OrbPose get pose => OrbPose(Offset(_x.x, _y.x), dock);

  /// True when nothing is moving.
  bool get settled =>
      _x.settled &&
      _y.settled &&
      _dock.settled &&
      _nx.settled &&
      _ny.settled &&
      _pulse.settled &&
      _tx.settled &&
      _ty.settled &&
      _press.settled;

  /// Glides to [to]. The first call, `animate: false` and reduced motion
  /// jump. Docking uses the dock spring (≈ 260 ms), undocking the undock
  /// spring (≈ 320 ms), other moves the move spring. Velocity carries over.
  void moveTo(OrbPose to, {double? diameter, bool animate = true}) {
    if (diameter != null) _diameter = diameter;
    final from = _target;
    if (from == to) return;
    _target = to;
    if (from == null || !animate || _reduced) {
      _snapTo(to);
      notifyListeners();
      return;
    }
    final k = to.dock > from.dock
        ? OrbChoreography.dockStiffness
        : to.dock < from.dock
        ? OrbChoreography.undockStiffness
        : OrbChoreography.moveStiffness;
    for (final s in [_x, _y, _dock]) {
      s
        ..k = k
        ..zeta = 1;
    }
    _x.target = to.centre.dx;
    _y.target = to.centre.dy;
    _dock.target = to.dock;
  }

  void _snapTo(OrbPose p) {
    _x.snap(p.centre.dx);
    _y.snap(p.centre.dy);
    _dock.snap(p.dock);
  }

  /// Feeds the conversation: smoothed 0..1 energies and who is speaking.
  /// The user pulls the orb down and to one side (alternating per
  /// utterance); Hermes lifts it. The user starting to speak while Hermes
  /// speaks is an interruption: the orb flinches.
  void react({
    double userLevel = 0,
    double hermesLevel = 0,
    bool userSpeaking = false,
    bool hermesSpeaking = false,
  }) {
    final user = userSpeaking || userLevel > 0.08;
    if (user && !_userWas) {
      _swayDir = -_swayDir;
      if (hermesSpeaking) _interrupt();
    }
    _userWas = user;
    if (_reduced) return;
    final d = _diameter * (1 - 0.6 * dock);
    final eIn = userLevel.clamp(0.0, 1.0);
    final eOut = hermesLevel.clamp(0.0, 1.0);
    double nx = 0, ny = 0;
    if (user) {
      final s = 0.5 + 0.5 * eIn;
      ny += OrbChoreography.userPull * d * s;
      nx += _swayDir * OrbChoreography.userSway * d * s;
    }
    if (hermesSpeaking) {
      ny -= OrbChoreography.hermesLift * d * (0.4 + 0.6 * eOut);
    }
    for (final s in [_nx, _ny]) {
      s
        ..k = OrbChoreography.nudgeStiffness
        ..zeta = OrbChoreography.nudgeDamping;
    }
    _nx.target = nx;
    _ny.target = ny;
  }

  void _interrupt() {
    _interruptions++;
    if (_reduced) return;
    final d = _diameter * (1 - 0.6 * dock);
    _ny
      ..k = OrbChoreography.nudgeStiffness
      ..zeta = OrbChoreography.nudgeDamping
      ..v += OrbChoreography.interruptKick * d;
    _pulse
      ..k = OrbChoreography.pulseStiffness
      ..zeta = OrbChoreography.pulseDamping
      ..v -= OrbChoreography.interruptSquash;
  }

  /// Advances by [dt] seconds; notifies when something moved.
  void step(double dt) {
    if (dt.isNaN || dt <= 0) return;
    if (settled) return;
    dt = math.min(dt, 0.1);
    for (final s in [_x, _y, _dock, _nx, _ny, _pulse, _tx, _ty, _press]) {
      s.step(dt);
    }
    notifyListeners();
  }
}
