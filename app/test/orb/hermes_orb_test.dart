import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/rtc/voice_transport.dart';
import 'package:tove_chat/src/ui/orb/orb.dart';
import 'package:tove_chat/src/ui/orb/orb_demo.dart';
import 'package:tove_chat/src/ui/theme/render_policy.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp;

Widget host(Widget orb, {bool reduce = false, RenderPolicy? policy}) {
  final child = MediaQuery(
    data: MediaQueryData(disableAnimations: reduce),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: orb),
    ),
  );
  return policy == null
      ? child
      : RenderPolicyScope(policy: policy, child: child);
}

HermesOrbState orbState(WidgetTester tester) =>
    tester.state<HermesOrbState>(find.byType(HermesOrb));

Future<void> frames(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 16) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<ui.FragmentProgram> failingLoader() async =>
    throw Exception('no runtime effects here');

void main() {
  setUp(() => OrbShader.debugReset(loader: failingLoader));
  tearDown(OrbShader.debugReset);

  group('renderer choice', () {
    OrbRenderer pick({
      OrbRenderer requested = OrbRenderer.auto,
      bool reduce = false,
      bool web = false,
      bool policy = true,
      OrbShaderStatus status = OrbShaderStatus.ready,
    }) => OrbRenderer.resolve(
      requested: requested,
      reduceMotion: reduce,
      isWeb: web,
      policyAllowsShader: policy,
      status: status,
    );

    test('shader only when loaded, allowed, native and motion is on', () {
      expect(pick(), OrbRenderer.shader);
      expect(pick(web: true), OrbRenderer.fallback);
      expect(pick(policy: false), OrbRenderer.fallback);
      expect(pick(reduce: true), OrbRenderer.fallback);
      expect(pick(requested: OrbRenderer.fallback), OrbRenderer.fallback);
      for (final s in [
        OrbShaderStatus.notLoaded,
        OrbShaderStatus.loading,
        OrbShaderStatus.failed,
      ]) {
        expect(pick(status: s), OrbRenderer.fallback, reason: s.name);
      }
      // An explicit request still needs a loaded program.
      expect(
        pick(requested: OrbRenderer.shader, web: true),
        OrbRenderer.shader,
      );
      expect(
        pick(requested: OrbRenderer.shader, status: OrbShaderStatus.failed),
        OrbRenderer.fallback,
      );
    });
  });

  testWidgets('falls back to the painter when the shader fails to load', (
    tester,
  ) async {
    final policy = RenderPolicy(monitor: false, shaderOrb: true);
    addTearDown(policy.dispose);
    await tester.pumpWidget(
      host(
        const HermesOrb(state: OrbState.listening, size: 200),
        policy: policy,
      ),
    );
    await tester.pump();
    expect(OrbShader.status, OrbShaderStatus.failed);
    expect(orbState(tester).renderer, OrbRenderer.fallback);
    expect(orbState(tester).usesShader, isFalse);
    expect(policy.shaderOrb, isFalse, reason: 'policy told about the failure');
    await frames(tester, 100);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses the shader once it has loaded', (tester) async {
    OrbShader.debugReset();
    final program = await tester.runAsync(OrbShader.precache);
    if (program == null) {
      markTestSkipped('flutter test cannot load shaders/orb.frag here');
      return;
    }
    final policy = RenderPolicy(monitor: false, shaderOrb: true);
    addTearDown(policy.dispose);
    await tester.pumpWidget(
      host(
        const HermesOrb(state: OrbState.assistantSpeaking, size: 200),
        policy: policy,
      ),
    );
    expect(orbState(tester).usesShader, isTrue);
    await frames(tester, 100);
    expect(tester.takeException(), isNull);
  });

  testWidgets('layout box is the rest size; painting may overflow it', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(const HermesOrb(state: OrbState.listening, size: 180)),
    );
    expect(tester.getSize(find.byType(HermesOrb)), const Size(180, 180));
    expect(
      find.descendant(
        of: find.byType(HermesOrb),
        matching: find.byType(RepaintBoundary),
      ),
      findsOneWidget,
    );
  });

  testWidgets('state changes animate instead of jumping', (tester) async {
    await tester.pumpWidget(
      host(const HermesOrb(state: OrbState.listening, size: 200)),
    );
    await frames(tester, 200);
    await tester.pumpWidget(
      host(const HermesOrb(state: OrbState.error, size: 200)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    final f = orbState(tester).engine.frame;
    expect(f.cloudLevel, inExclusiveRange(0.45, 0.55));
    expect(f.errorMix, inExclusiveRange(0.0, 1.0));
    await frames(tester, 600);
    expect(f.cloudLevel, closeTo(0.45, 0.005));
  });

  testWidgets('audio levels are smoothed per frame (attack ≈ 60 ms)', (
    tester,
  ) async {
    final level = ValueNotifier(0.0);
    addTearDown(level.dispose);
    await tester.pumpWidget(
      host(
        HermesOrb(state: OrbState.assistantSpeaking, size: 200, level: level),
      ),
    );
    await frames(tester, 100);
    level.value = 1;
    // Ticks at 16 ms: after 4 ticks (64 ms) about 1 − e^(−64/60).
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(orbState(tester).engine.levelOut, closeTo(0.656, 0.03));
  });

  testWidgets('AudioLevels input drives user reactions, output Hermes', (
    tester,
  ) async {
    final levels = ValueNotifier(const AudioLevels(input: 0, output: 0.3125));
    addTearDown(levels.dispose);
    await tester.pumpWidget(
      host(
        HermesOrb(state: OrbState.assistantSpeaking, size: 200, levels: levels),
      ),
    );
    await frames(tester, 1000);
    final e = orbState(tester).engine;
    expect(e.levelOut, closeTo(1, 0.01));
    expect(e.levelIn, 0);
    expect(e.frame.scale, greaterThan(0.99));
  });

  testWidgets('docked animates to 0.41 × over 260 ms', (tester) async {
    await tester.pumpWidget(
      host(const HermesOrb(state: OrbState.listening, size: 200)),
    );
    await frames(tester, 100);
    await tester.pumpWidget(
      host(const HermesOrb(state: OrbState.listening, size: 200, docked: true)),
    );
    final f = orbState(tester).engine.frame;
    await frames(tester, 128);
    expect(f.dock, inExclusiveRange(0.2, 0.95));
    await frames(tester, 144);
    expect(f.dock, 1);
  });

  testWidgets('the ticker stops once ended has faded out', (tester) async {
    await tester.pumpWidget(
      host(const HermesOrb(state: OrbState.listening, size: 200)),
    );
    await frames(tester, 50);
    expect(orbState(tester).isTicking, isTrue);
    await tester.pumpWidget(
      host(const HermesOrb(state: OrbState.ended, size: 200)),
    );
    await frames(tester, 260);
    expect(orbState(tester).engine.frame.opacity, 0);
    expect(orbState(tester).isTicking, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);

    // A new call brings it back.
    await tester.pumpWidget(
      host(const HermesOrb(state: OrbState.connecting, size: 200)),
    );
    expect(orbState(tester).isTicking, isTrue);
  });

  testWidgets('inactive (hidden) orbs do not tick', (tester) async {
    await tester.pumpWidget(
      host(const HermesOrb(state: OrbState.thinking, size: 200, active: false)),
    );
    expect(orbState(tester).isTicking, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('TickerMode off mutes the ticker', (tester) async {
    await tester.pumpWidget(
      TickerMode(
        enabled: false,
        child: host(const HermesOrb(state: OrbState.thinking, size: 200)),
      ),
    );
    expect(orbState(tester).isTicking, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  group('reduced motion', () {
    testWidgets('no continuous motion and no scheduled frames', (tester) async {
      await tester.pumpWidget(
        host(
          const HermesOrb(state: OrbState.thinking, size: 200),
          reduce: true,
        ),
      );
      final s = orbState(tester);
      expect(s.isTicking, isFalse);
      expect(s.renderer, OrbRenderer.fallback);
      expect(tester.binding.hasScheduledFrame, isFalse);
      final f = s.engine.frame;
      await tester.pump(const Duration(seconds: 1));
      expect(f.roll, 0);
      expect(f.tilt, 0);
      expect(f.time, 0);
      expect(f.scale, 0.80);
    });

    testWidgets('state feedback steps; the level shows as a ring', (
      tester,
    ) async {
      final level = ValueNotifier(0.0);
      addTearDown(level.dispose);
      Widget orb(OrbState s) =>
          host(HermesOrb(state: s, size: 200, level: level), reduce: true);
      await tester.pumpWidget(orb(OrbState.listening));
      await tester.pumpWidget(orb(OrbState.muted));
      final f = orbState(tester).engine.frame;
      expect(f.scale, 0.76);
      expect(f.saturation, 0.35);

      await tester.pumpWidget(orb(OrbState.assistantSpeaking));
      level.value = 0.6;
      expect(f.ring, closeTo(0.6, 1e-9));
      expect(f.scale, 0.80, reason: 'no audio-driven size change');
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('the reduceMotion override wins over MediaQuery', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const HermesOrb(
            state: OrbState.listening,
            size: 200,
            reduceMotion: true,
          ),
        ),
      );
      expect(orbState(tester).isTicking, isFalse);
    });
  });

  testWidgets('a shared engine survives the widget and keeps its motion', (
    tester,
  ) async {
    final engine = OrbEngine(state: OrbState.listening);
    addTearDown(engine.dispose);
    await tester.pumpWidget(
      host(HermesOrb(state: OrbState.thinking, size: 200, engine: engine)),
    );
    await frames(tester, 500);
    final roll = engine.frame.roll;
    expect(roll, greaterThan(0));
    // Moved to another place in the tree (centred → docked layout).
    await tester.pumpWidget(
      host(
        Padding(
          padding: const EdgeInsets.only(top: 300),
          child: HermesOrb(
            state: OrbState.thinking,
            size: 200,
            engine: engine,
            docked: true,
          ),
        ),
      ),
    );
    expect(engine.frame.roll, roll);
    await frames(tester, 50);
    expect(engine.frame.roll, greaterThan(roll));
    await tester.pumpWidget(const SizedBox());
    engine.step(0.016); // not disposed by the widget
  });

  testWidgets('demo page cycles every state', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: OrbDemoPage(stepDuration: Duration(milliseconds: 200)),
      ),
    );
    final seen = <OrbState>{};
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      seen.add(orbState(tester).engine.state);
    }
    expect(seen, containsAll(OrbState.values.toSet()..remove(OrbState.idle)));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
