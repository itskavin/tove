import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/rtc/voice_transport.dart';
import 'package:tove_chat/src/ui/orb/orb.dart';

const double _deg = math.pi / 180;

/// Advances [e] by [seconds] of fake time in steps of [dt].
void run(OrbEngine e, double seconds, {double dt = 1 / 1000}) {
  final n = (seconds / dt).round();
  for (var i = 0; i < n; i++) {
    e.step(dt);
  }
}

/// Fake time (seconds) until [done] holds, stepping 1 ms; null if never.
double? timeUntil(OrbEngine e, bool Function() done, {double limit = 3}) {
  var t = 0.0;
  while (t < limit) {
    e.step(0.001);
    t += 0.001;
    if (done()) return t;
  }
  return null;
}

void main() {
  group('audio', () {
    test('normalises raw levels as min(1, sqrt(level × 3.2))', () {
      expect(OrbEngine.normalise(null), 0);
      expect(OrbEngine.normalise(-1), 0);
      expect(OrbEngine.normalise(0.05), closeTo(0.4, 1e-9));
      expect(OrbEngine.normalise(0.3125), closeTo(1, 1e-9));
      expect(OrbEngine.normalise(4), 1);
    });

    test('attack reaches 63 % in ≈ 60 ms', () {
      final e = OrbEngine(state: OrbState.assistantSpeaking)..setLevel(1);
      final t = timeUntil(e, () => e.levelOut >= 1 - math.exp(-1));
      expect(t, closeTo(0.060, 0.003));
      // The reference's ≈ 80 ms lag: most of the rise is in by then.
      expect(e.levelOut, lessThan(0.75));
    });

    test('release falls to 37 % in ≈ 350 ms', () {
      final e = OrbEngine(state: OrbState.assistantSpeaking)..setLevel(1);
      run(e, 1);
      expect(e.levelOut, closeTo(1, 1e-3));
      e.setLevel(0);
      final t = timeUntil(e, () => e.levelOut <= math.exp(-1));
      expect(t, closeTo(0.350, 0.005));
    });

    test(
      'assistant speech peaks at 0.80 + 0.22 and shrinks back in ≈ 0.9 s',
      () {
        final e = OrbEngine(state: OrbState.assistantSpeaking)..setLevel(1);
        run(e, 1);
        expect(e.frame.scale, closeTo(1.02, 0.007));
        expect(e.frame.cloudLevel, closeTo(0.82, 0.01));
        expect(e.frame.brightness, closeTo(0.06, 0.002));
        e.setLevel(0);
        run(e, 0.9);
        // 180 → 144 px in the video: at most 10 % of the swing is left.
        expect(e.frame.scale - 0.80, lessThan(0.022 + 0.007));
      },
    );

    test(
      'user speech: + 0.06 scale, tilt up to 18° alternating per utterance',
      () {
        final e = OrbEngine(state: OrbState.listening)..setLevel(1);
        run(e, 0.6);
        expect(e.frame.scale, closeTo(0.86, 0.013));
        final first = e.frame.tilt;
        expect(first.abs(), greaterThan(10 * _deg));
        expect(first.abs(), lessThan(18 * _deg + 6 * _deg + 1e-6));
        e.setLevel(0);
        run(e, 1.5);
        e.setLevel(1);
        run(e, 0.6);
        expect(e.frame.tilt.sign, -first.sign);
      },
    );

    test('unknown levels never fake speech motion', () {
      final e = OrbEngine(state: OrbState.listening)
        ..setLevels(AudioLevels.unknown);
      for (var i = 0; i < 200; i++) {
        e.step(0.01);
        expect(e.frame.scale, closeTo(0.80, 0.012 + 1e-9));
        expect(e.frame.turbulence, closeTo(0.5, 1e-9));
      }
      expect(e.levelIn, 0);
      expect(e.levelOut, 0);
    });

    test('muted ignores the microphone but still reacts to Hermes', () {
      final e = OrbEngine(state: OrbState.muted)
        ..setLevels(const AudioLevels(input: 1, output: 0));
      run(e, 1);
      expect(e.frame.scale, closeTo(0.76, 0.009));
      expect(e.frame.saturation, closeTo(0.35, 1e-3));
      e.setLevels(const AudioLevels(input: 0, output: 1));
      run(e, 1);
      expect(e.frame.scale, greaterThan(0.95));
    });

    test('thinking and error ignore the level', () {
      for (final s in [OrbState.thinking, OrbState.error]) {
        final e = OrbEngine(state: s)..setLevel(1);
        run(e, 1);
        expect(e.frame.scale, lessThan(0.81), reason: s.name);
      }
    });
  });

  group('state transitions', () {
    test('cross-fade with a spring (≈ 450 ms), no jumps', () {
      final e = OrbEngine(state: OrbState.listening);
      run(e, 0.5);
      e.state = OrbState.error;
      var prev = e.frame.cloudLevel;
      var t = 0.0;
      while (t < 0.45) {
        e.step(1 / 60);
        t += 1 / 60;
        expect((e.frame.cloudLevel - prev).abs(), lessThan(0.01));
        prev = e.frame.cloudLevel;
      }
      // 0.55 → 0.45: within 5 % of the swing after 450 ms.
      expect(e.frame.cloudLevel, closeTo(0.45, 0.005));
      expect(e.frame.errorMix, greaterThan(0.95));
    });

    test('error tint is mostly in after 300 ms', () {
      final e = OrbEngine(state: OrbState.listening);
      e.state = OrbState.error;
      run(e, 0.3);
      expect(e.frame.errorMix, greaterThan(0.8));
    });

    test('error entry shudders 0.78 → 0.76 → 0.78 over 240 ms', () {
      final e = OrbEngine(state: OrbState.error);
      run(e, 1);
      e
        ..state = OrbState.listening
        ..state = OrbState.error;
      var low = 1.0;
      var t = 0.0;
      while (t < 0.24) {
        e.step(0.001);
        t += 0.001;
        low = math.min(low, e.frame.scale);
      }
      expect(low, closeTo(0.76, 0.002));
      run(e, 0.01);
      expect(e.frame.scale, closeTo(0.78, 0.002));
    });

    test('thinking rolls the clouds at 45°/s', () {
      final e = OrbEngine(state: OrbState.thinking);
      run(e, 1);
      final a = e.frame.roll;
      run(e, 1);
      final turned = (e.frame.roll - a) % (2 * math.pi);
      expect(turned, closeTo(45 * _deg, 0.5 * _deg));
    });

    test('connecting breathes ±0.03 around 0.86 at 1.6 s', () {
      final e = OrbEngine(state: OrbState.connecting);
      var lo = 9.0, hi = 0.0;
      for (var i = 0; i < 1600; i++) {
        e.step(0.001);
        lo = math.min(lo, e.frame.scale);
        hi = math.max(hi, e.frame.scale);
      }
      expect(lo, closeTo(0.83, 0.002));
      expect(hi, closeTo(0.89, 0.002));
      expect(e.frame.saturation, closeTo(0.7, 1e-3));
    });

    test('listening rests at 0.80 (144/180) ± 0.012', () {
      final e = OrbEngine(state: OrbState.listening);
      var lo = 9.0, hi = 0.0;
      for (var i = 0; i < 4200; i++) {
        e.step(0.001);
        lo = math.min(lo, e.frame.scale);
        hi = math.max(hi, e.frame.scale);
      }
      expect(lo, closeTo(0.788, 0.001));
      expect(hi, closeTo(0.812, 0.001));
    });
  });

  group('dock', () {
    test('docks to 0.41 × in 260 ms and undocks in 320 ms', () {
      final e = OrbEngine(state: OrbState.listening)..setDocked(true);
      run(e, 0.130);
      expect(e.frame.dock, inExclusiveRange(0.3, 0.95));
      run(e, 0.120);
      expect(e.frame.dock, lessThan(1));
      run(e, 0.012);
      expect(e.frame.dock, 1);
      expect(e.frame.diameter, closeTo(e.frame.scale * 0.41, 1e-9));

      e.setDocked(false);
      run(e, 0.310);
      expect(e.frame.dock, greaterThan(0));
      run(e, 0.012);
      expect(e.frame.dock, 0);
    });

    test('a caller-driven dock factor overrides the animation', () {
      final e = OrbEngine()..dockOverride = 0.5;
      e.step(0);
      expect(e.frame.dock, 0.5);
      e.dockOverride = null;
      e.step(0);
      expect(e.frame.dock, 0);
    });

    test('setDocked(animate: false) jumps', () {
      final e = OrbEngine()..setDocked(true, animate: false);
      e.step(0);
      expect(e.frame.dock, 1);
    });
  });

  group('ended', () {
    test('fades out in 220 ms, then needs no more frames', () {
      final e = OrbEngine(state: OrbState.listening);
      run(e, 0.2);
      e.state = OrbState.ended;
      expect(e.needsFrames, isTrue);
      run(e, 0.2);
      expect(e.frame.opacity, greaterThan(0));
      run(e, 0.021);
      expect(e.frame.opacity, 0);
      expect(e.frame.diameter, 0);
      expect(e.needsFrames, isFalse);
      expect(e.finished, isTrue);
    });

    test('coming back from ended fades in again', () {
      final e = OrbEngine(state: OrbState.ended);
      expect(e.needsFrames, isFalse);
      e.state = OrbState.connecting;
      expect(e.needsFrames, isTrue);
      run(e, 0.1);
      expect(e.frame.opacity, inExclusiveRange(0, 1));
      run(e, 0.15);
      expect(e.frame.opacity, 1);
    });
  });

  test('settle() is a still frame at rest scale with the level as a ring', () {
    final e = OrbEngine(state: OrbState.thinking)..setLevel(0.7);
    run(e, 1);
    e.settle();
    expect(e.frame.tilt, 0);
    expect(e.frame.roll, 0);
    expect(e.frame.time, 0);
    expect(e.frame.drift, 0);
    expect(e.frame.scale, 0.80);
    expect(e.frame.ring, 0); // thinking ignores the level
    e
      ..state = OrbState.assistantSpeaking
      ..settle();
    expect(e.frame.scale, 0.80);
    expect(e.frame.ring, closeTo(0.7, 1e-9));
  });

  test('OrbState.speaking and OrbMode alias the new names', () {
    expect(OrbState.speaking, OrbState.assistantSpeaking);
    const OrbMode m = OrbMode.thinking;
    expect(m, OrbState.thinking);
  });
}
