import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/orb/orb.dart';

/// 412 × 915 phone, 24 dp status bar, 16 dp gesture bar, app bar to 72,
/// composer top at 915 − 16 − 12 − 52.
const _layout = OrbStageLayout(
  size: Size(412, 915),
  padding: EdgeInsets.only(top: 24, bottom: 16),
  topInset: 72,
  composerTop: 835,
);

void _run(OrbChoreographer c, double seconds, {double fps = 120}) {
  final dt = 1 / fps;
  for (var t = 0.0; t < seconds - 1e-9; t += dt) {
    c.step(dt);
  }
}

void main() {
  group('poses', () {
    test('centred: orbCentered, centre at 46 % of the safe height', () {
      final p = OrbChoreography.pose(OrbStage.centred, _layout);
      expect(_layout.diameter, 206);
      expect(p.dock, 0);
      expect(p.centre.dx, 206);
      expect(p.centre.dy, closeTo(24 + (915 - 40) * 0.46, 1e-9));
    });

    test('docked: 0.41 ×, 40 dp above the composer; lifts for a label', () {
      final p = OrbChoreography.pose(OrbStage.docked, _layout);
      expect(p.dock, 1);
      expect(p.centre.dx, 206);
      expect(p.centre.dy, closeTo(835 - 40 - 206 * 0.41 / 2, 1e-9));
      final lifted = OrbChoreography.pose(
        OrbStage.docked,
        const OrbStageLayout(
          size: Size(412, 915),
          padding: EdgeInsets.only(top: 24, bottom: 16),
          topInset: 72,
          composerTop: 835,
          labelShown: true,
        ),
      );
      expect(p.centre.dy - lifted.centre.dy, OrbChoreography.labelLift);
    });

    test('cards above a centred orb push it down, never into the composer', () {
      OrbPose withCards(double extent) => OrbChoreography.pose(
        OrbStage.centred,
        OrbStageLayout(
          size: const Size(412, 915),
          padding: const EdgeInsets.only(top: 24, bottom: 16),
          topInset: 72,
          composerTop: 835,
          cardsExtent: extent,
        ),
      );
      final base = OrbChoreography.pose(OrbStage.centred, _layout);
      // Three 48 dp cards fit between the app bar and the orb.
      expect(withCards(156).centre, base.centre);
      final pushed = withCards(260);
      expect(pushed.centre.dy, greaterThan(base.centre.dy));
      final top =
          pushed.centre.dy -
          OrbChoreography.radius(206, 0) -
          OrbChoreography.cardsGap -
          260;
      expect(top, closeTo(72 + 8, 1e-9));
      final capped = withCards(2000);
      expect(capped.centre.dy, 835 - OrbChoreography.labelRoom - 206 / 2);
    });
  });

  group('motion', () {
    final centred = OrbChoreography.pose(OrbStage.centred, _layout);
    final docked = OrbChoreography.pose(OrbStage.docked, _layout);

    test('the first pose is placed, not animated', () {
      final c = OrbChoreographer()..moveTo(centred, diameter: 206);
      expect(c.centre, centred.centre);
      expect(c.dock, 0);
      expect(c.settled, isTrue);
    });

    test('docks in the measured ≈ 260 ms, without overshoot', () {
      final c = OrbChoreographer()..moveTo(centred, diameter: 206);
      c.moveTo(docked);
      var peak = 0.0;
      for (var i = 0; i < 16; i++) {
        c.step(1 / 120);
        peak = c.dock > peak ? c.dock : peak;
      }
      // Halfway (≈ 130 ms) it is clearly moving but not there.
      expect(c.dock, inInclusiveRange(0.3, 0.85));
      for (var i = 0; i < 15; i++) {
        c.step(1 / 120);
        peak = c.dock > peak ? c.dock : peak;
      }
      // 260 ms: within 3 % of the dock pose.
      expect(c.dock, greaterThan(0.97));
      final travel = docked.centre.dy - centred.centre.dy;
      expect(
        (c.pose.centre.dy - centred.centre.dy) / travel,
        greaterThan(0.97),
      );
      _run(c, 0.5);
      expect(peak, lessThanOrEqualTo(1.0));
      expect(c.dock, 1);
      expect(c.centre, docked.centre);
      expect(c.settled, isTrue);
    });

    test('undocks in ≈ 320 ms', () {
      final c = OrbChoreographer()..moveTo(docked, diameter: 206);
      c.moveTo(centred);
      _run(c, 0.2);
      expect(c.dock, greaterThan(0.1));
      _run(c, 0.12);
      expect(c.dock, lessThan(0.03));
    });

    test('retargeting mid-flight keeps the position continuous', () {
      final c = OrbChoreographer()..moveTo(centred, diameter: 206);
      c.moveTo(docked);
      _run(c, 0.1);
      final before = c.centre;
      c.moveTo(centred);
      c.step(1 / 120);
      expect((c.centre - before).distance, lessThan(12));
      // It was still moving down: the velocity carries a little further.
      expect(c.centre.dy, greaterThanOrEqualTo(before.dy - 0.5));
      _run(c, 1);
      expect(c.centre, centred.centre);
    });

    test('60 and 120 Hz end in the same place', () {
      final a = OrbChoreographer()..moveTo(centred, diameter: 206);
      final b = OrbChoreographer()..moveTo(centred, diameter: 206);
      a.moveTo(docked);
      b.moveTo(docked);
      _run(a, 0.2, fps: 60);
      _run(b, 0.2, fps: 120);
      expect((a.centre - b.centre).distance, lessThan(1));
      expect((a.dock - b.dock).abs(), lessThan(0.01));
    });
  });

  group('reactions', () {
    final centred = OrbChoreography.pose(OrbStage.centred, _layout);

    test(
      'touch is immediate, bounded, independent of audio, and springs back',
      () {
        final c = OrbChoreographer()..moveTo(centred, diameter: 206);
        c.touch(const Offset(5000, 5000));
        expect(c.touchOffset.distance, lessThan(206 * 0.65));
        expect(c.touchPressure, 1);
        final touch = c.touchOffset;
        c.react(userLevel: 0.8, userSpeaking: true);
        _run(c, 0.4);
        expect(c.touchOffset, touch);
        c.releaseTouch(const Offset(300, 200));
        _run(c, 2);
        expect(c.touchOffset, Offset.zero);
        expect(c.touchPressure, 0);
        expect(c.centre.dy, greaterThan(centred.centre.dy));
        c.reduced = true;
        c.touch(const Offset(100, 100));
        expect(c.touchOffset, Offset.zero);
        c.releaseTouch(const Offset(500, 900));
        c.reduced = false;
        _run(c, 0.1);
        expect(c.touchOffset, Offset.zero);
      },
    );

    test('the user speaking pulls the orb down; Hermes lifts it', () {
      final c = OrbChoreographer()..moveTo(centred, diameter: 206);
      c.react(userLevel: 0.8, userSpeaking: true);
      _run(c, 0.6);
      expect(c.centre.dy, greaterThan(centred.centre.dy + 5));
      expect(c.centre.dx, isNot(centred.centre.dx));
      // The base pose (used for the label and the cards) does not move.
      expect(c.pose.centre, centred.centre);
      c.react(hermesLevel: 0.8, hermesSpeaking: true);
      _run(c, 0.8);
      expect(c.centre.dy, lessThan(centred.centre.dy - 2));
      c.react();
      _run(c, 2);
      expect(c.centre, centred.centre);
      expect(c.settled, isTrue);
    });

    test('sideways sway alternates per utterance', () {
      final c = OrbChoreographer()..moveTo(centred, diameter: 206);
      c.react(userLevel: 0.5, userSpeaking: true);
      _run(c, 0.6);
      final first = c.centre.dx - centred.centre.dx;
      c.react();
      _run(c, 1.5);
      c.react(userLevel: 0.5, userSpeaking: true);
      _run(c, 0.6);
      final second = c.centre.dx - centred.centre.dx;
      expect(first.sign, -second.sign);
    });

    test('talking over Hermes is an interruption: the orb flinches', () {
      final c = OrbChoreographer()..moveTo(centred, diameter: 206);
      c.react(hermesLevel: 0.6, hermesSpeaking: true);
      _run(c, 0.5);
      c.react(userLevel: 0.6, userSpeaking: true, hermesSpeaking: true);
      expect(c.interruptions, 1);
      _run(c, 0.05);
      expect(c.pulse, lessThan(0.99));
      _run(c, 2);
      expect(c.pulse, closeTo(1, 0.001));
    });
  });

  group('reduced motion', () {
    final centred = OrbChoreography.pose(OrbStage.centred, _layout);
    final docked = OrbChoreography.pose(OrbStage.docked, _layout);

    test('no travel: poses snap, nudges and flinches are off', () {
      final c = OrbChoreographer()
        ..reduced = true
        ..moveTo(centred, diameter: 206);
      var notified = 0;
      c.addListener(() => notified++);
      c.moveTo(docked);
      expect(notified, 1);
      expect(c.centre, docked.centre);
      expect(c.dock, 1);
      expect(c.settled, isTrue);
      c.react(hermesLevel: 1, hermesSpeaking: true);
      c.react(userLevel: 1, userSpeaking: true, hermesSpeaking: true);
      expect(c.interruptions, 1, reason: 'still counted');
      c.step(1 / 60);
      expect(c.centre, docked.centre);
      expect(c.pulse, 1);
    });

    test('turning it on mid-flight lands at once', () {
      final c = OrbChoreographer()..moveTo(centred, diameter: 206);
      c.moveTo(docked);
      _run(c, 0.05);
      c.reduced = true;
      expect(c.centre, docked.centre);
      expect(c.dock, 1);
    });
  });

  test('the orb engine steps the choreographer and reads its dock', () {
    final engine = OrbEngine(state: OrbState.listening);
    final c = OrbChoreographer()
      ..moveTo(OrbChoreography.pose(OrbStage.centred, _layout), diameter: 206);
    engine.choreographer = c;
    c.moveTo(OrbChoreography.pose(OrbStage.docked, _layout));
    for (var i = 0; i < 60; i++) {
      engine.step(1 / 60);
    }
    expect(c.dock, 1);
    expect(engine.frame.dock, 1);
    engine.dispose();
    c.dispose();
  });
}
