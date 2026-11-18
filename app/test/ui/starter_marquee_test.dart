import 'dart:math';

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/ui/thread/empty_thread.dart';
import 'package:tove_chat/src/ui/thread/starter_marquee.dart';
import 'package:tove_chat/src/ui/thread/starter_prompts.dart';

import 'test_harness.dart';

final _prompts = StarterPrompts(random: Random(4))
    .next(now: DateTime(2026, 11, 16, 10));

void main() {
  setUpAll(() async {
    await loadAppFonts();
    await loadEmojiFont();
  });

  StarterMarqueeState state(WidgetTester tester) =>
      tester.state<StarterMarqueeState>(find.byType(StarterMarquee));

  Future<void> pumpMarquee(
    WidgetTester tester, {
    List<StarterPrompt>? prompts,
    ValueChanged<StarterPrompt>? onPick,
    bool reduce = false,
    bool active = true,
    Brightness brightness = Brightness.light,
    double top = 300,
  }) async {
    phoneSize(tester);
    await tester.pumpWidget(
      themed(
        Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: top,
                child: StarterMarquee(
                  prompts: prompts ?? _prompts,
                  onPick: onPick ?? (_) {},
                  active: active,
                ),
              ),
            ],
          ),
        ),
        reduce: reduce,
        brightness: brightness,
      ),
    );
    await tester.pump();
  }

  group('model', () {
    test('twelve prompts, two rows of six; fewer than four is one row', () {
      expect(_prompts, hasLength(12));
      final rows = StarterMarquee.split(_prompts);
      expect(rows.map((r) => r.length), [6, 6]);
      expect(StarterMarquee.split(_prompts.take(3).toList()), hasLength(1));
    });

    test('every local prompt has its own emoji', () {
      expect(starterPool.every((p) => p.emoji != '✨'), isTrue);
    });

    test('bridge suggestions: their emoji, else the category’s, else the '
        'fallback set', () {
      final got = StarterPrompts.parse({
        'suggestions': [
          {'title': 'Own', 'category': 'media', 'emoji': '🎧'},
          {'title': 'Category', 'category': 'food'},
          {'title': 'Neither', 'category': 'unheard-of'},
          'Plain',
        ],
      });
      expect(got.map((p) => p.emoji), [
        '🎧',
        StarterPrompts.categoryEmoji['food'],
        StarterPrompts.fallbackEmoji[2],
        StarterPrompts.fallbackEmoji[3],
      ]);
    });
  });

  group('motion', () {
    testWidgets('one ticker; the rows drift in opposite directions by time, '
        'not by frame count', (tester) async {
      await pumpMarquee(tester);
      final s = state(tester);
      expect(s.isTicking, isTrue);
      final before = s.offsets;
      // 1 s at 60 Hz and 1 s at 120 Hz move the same distance.
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(microseconds: 16667));
      }
      final mid = s.offsets;
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(microseconds: 8333));
      }
      final after = s.offsets;
      expect(mid[0] - before[0], closeTo(24, 1.5));
      expect(mid[1] - before[1], closeTo(-19, 1.5));
      expect(after[0] - mid[0], closeTo(24, 0.5));
      expect(after[1] - mid[1], closeTo(-19, 0.5));
      // Exactly one ticker for both rows.
      expect(tester.binding.transientCallbackCount, 1);
    });

    testWidgets('moving a row repaints only: no rebuild, no relayout', (
      tester,
    ) async {
      await pumpMarquee(tester);
      await tester.pump(const Duration(milliseconds: 100));
      var builds = 0;
      final chip = find.byKey(ValueKey('starter-${_prompts.first.text}'));
      final box = tester.renderObject<RenderBox>(chip);
      final before = tester.getTopLeft(chip);
      debugOnRebuildDirtyWidget = (_, _) => builds++;
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      debugOnRebuildDirtyWidget = null;
      expect(builds, 0, reason: 'no widget rebuilds while drifting');
      expect(box.debugNeedsLayout, isFalse);
      expect(tester.getTopLeft(chip).dx, lessThan(before.dx));
    });

    testWidgets('a finger holds the row; a sideways drag scrolls it with '
        'the finger (round 8); the drift resumes after release', (
      tester,
    ) async {
      await pumpMarquee(tester);
      await tester.pump(const Duration(milliseconds: 100));
      final row = find.byKey(const ValueKey('starter-row-0'));
      final g = await tester.startGesture(tester.getCenter(row));
      await tester.pump(const Duration(milliseconds: 100));
      final held = state(tester).offsets[0];
      await tester.pump(const Duration(milliseconds: 500));
      expect(state(tester).offsets[0], held, reason: 'held: no drift');
      // Drag right by 120 dp: the content follows the finger (offset falls).
      for (var i = 0; i < 6; i++) {
        await g.moveBy(const Offset(20, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(state(tester).offsets[0], lessThan(held - 90));
      final dragged = state(tester).offsets[0];
      await tester.pump(const Duration(milliseconds: 300));
      await g.up();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 600));
      final rest = state(tester).offsets[0];
      expect((rest - dragged).abs(), lessThan(30), reason: 'slow release');
      expect(state(tester).fingers, 0);
      await tester.pump(const Duration(milliseconds: 600));
      expect(state(tester).offsets[0], closeTo(rest, 0.5), reason: 'paused');
      // After the pause the drift eases back in.
      for (var i = 0; i < 150; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(state(tester).offsets[0], greaterThan(rest + 5));
    });

    for (final dir in [-1.0, 1.0]) {
      testWidgets('a fast fling ${dir < 0 ? 'left' : 'right'} carries the '
          'row, then it drifts again', (tester) async {
        await pumpMarquee(tester);
        await tester.pump(const Duration(milliseconds: 100));
        final before = state(tester).offsets[0];
        await tester.fling(
          find.byKey(const ValueKey('starter-row-0')),
          Offset(160 * dir, 0),
          1500,
        );
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final flung = state(tester).offsets[0];
        // Finger left (dir −1) moves the content left: the offset grows.
        expect((flung - before) * -dir, greaterThan(160));
        for (var i = 0; i < 220; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final a = state(tester).offsets[0];
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(state(tester).offsets[0], greaterThan(a + 3), reason: 'drift');
        expect(state(tester).isTicking, isTrue);
      });
    }

    testWidgets('never stalls: a lost "up" (row rebuilt under the finger) '
        'still releases it', (tester) async {
      await pumpMarquee(tester);
      await tester.pump(const Duration(milliseconds: 100));
      final g = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('starter-row-1'))),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(state(tester).fingers, 1);
      // The finger lifts somewhere else entirely (the row moved away).
      await g.moveTo(const Offset(5, 5));
      await g.up();
      await tester.pump(const Duration(milliseconds: 16));
      expect(state(tester).fingers, 0);
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final a = state(tester).offsets[1];
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(state(tester).offsets[1], lessThan(a - 3), reason: 'drift');
    });

    testWidgets('pauses while inactive, off screen and in the background', (
      tester,
    ) async {
      await pumpMarquee(tester, active: false);
      expect(state(tester).isTicking, isFalse);
      await pumpMarquee(tester);
      expect(state(tester).isTicking, isTrue);

      // Off screen: the ticker stops; back on screen it starts again.
      await pumpMarquee(tester, top: 2000);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      expect(state(tester).isTicking, isFalse);
      await pumpMarquee(tester, top: 300);
      await tester.pump(const Duration(milliseconds: 600));
      expect(state(tester).isTicking, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(state(tester).isTicking, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(state(tester).isTicking, isTrue);
    });

    testWidgets('reduced motion: still rows that scroll, no frames', (
      tester,
    ) async {
      await pumpMarquee(tester, reduce: true);
      expect(state(tester).isTicking, isFalse);
      expect(SchedulerBinding.instance.hasScheduledFrame, isFalse);
      final row = find.byKey(const ValueKey('starter-row-0'));
      expect(row, findsOneWidget);
      expect(tester.widget(row), isA<SingleChildScrollView>());
      final last = _prompts[10];
      final chip = find.byKey(ValueKey('starter-${last.text}'));
      expect(tester.getRect(chip).left, greaterThan(412));
      await tester.drag(row, const Offset(-3000, 0));
      await tester.pumpAndSettle();
      expect(tester.getRect(chip).right, lessThanOrEqualTo(412));
    });
  });

  group('picking', () {
    testWidgets('tapping a chip picks its prompt', (tester) async {
      final picked = <StarterPrompt>[];
      await pumpMarquee(tester, onPick: picked.add, reduce: true);
      await tester.tap(find.byKey(ValueKey('starter-${_prompts[0].text}')));
      expect(picked, [_prompts[0]]);
    });

    testWidgets('Surprise me glides a random chip to the middle, lights it '
        'and then picks it', (tester) async {
      final picked = <StarterPrompt>[];
      await pumpMarquee(tester, onPick: picked.add);
      await tester.pump(const Duration(milliseconds: 100));
      state(tester).surprise(random: Random(5));
      await tester.pump(const Duration(milliseconds: 16));
      expect(picked, isEmpty);
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 300));
      expect(picked, hasLength(1));
      // The chosen chip (one of its copies) sits in the middle.
      final centres = [
        for (final e in find.text(picked.single.text).evaluate())
          tester.getCenter(find.byWidget(e.widget)).dx,
      ];
      expect(
        centres.any((x) => (x - 206).abs() < 60),
        isTrue,
        reason: '$centres',
      );
    });

    testWidgets('Surprise me with reduced motion picks at once', (
      tester,
    ) async {
      final picked = <StarterPrompt>[];
      await pumpMarquee(tester, onPick: picked.add, reduce: true);
      await tester.tap(find.bySemanticsLabel('Surprise me'));
      expect(picked, hasLength(1));
      expect(_prompts, contains(picked.single));
    });

    testWidgets('screen readers: the chips on screen are buttons', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpMarquee(tester);
      final first = _prompts.first;
      expect(
        tester.getSemantics(
          find
              .descendant(
                of: find.byKey(ValueKey('starter-${first.text}')),
                matching: find.byType(InkWell),
              )
              .first,
        ),
        matchesSemantics(
          label: first.text,
          hint: 'Sends this message',
          isButton: true,
          hasTapAction: true,
        ),
      );
      // Only chips on screen are announced, each once.
      final labels = <String>[];
      bool visit(SemanticsNode n) {
        if (n.label.isNotEmpty) labels.add(n.label);
        n.visitChildren(visit);
        return true;
      }

      visit(
        tester
            .binding
            .renderViews
            .first
            .owner!
            .semanticsOwner!
            .rootSemanticsNode!,
      );
      expect(labels, contains(first.text));
      expect(labels, isNot(contains(_prompts[10].text)));
      expect(labels.where((l) => l == first.text), hasLength(1));
      handle.dispose();
    });
  });

  testWidgets('200% text: rows grow, nothing overflows', (tester) async {
    phoneSize(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      themed(
        Scaffold(
          body: EmptyThread(
            topInset: 64,
            bottomInset: 96,
            chatEnabled: true,
            prompts: _prompts,
            onSuggestion: (_) {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('starter-row-0'))).height,
      greaterThan(StarterMarquee.chipHeight),
    );
  });

  group('goldens', () {
    for (final b in Brightness.values) {
      testWidgets('starter screen frame, ${b.name}', (tester) async {
        phoneSize(tester);
        await tester.pumpWidget(
          themed(
            Scaffold(
              body: EmptyThread(
                topInset: 64,
                bottomInset: 96,
                chatEnabled: true,
                prompts: _prompts,
                onSuggestion: (_) {},
              ),
            ),
            brightness: b,
          ),
        );
        // A frame part way through the drift.
        for (var i = 0; i < 90; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/starter_marquee_${b.name}.png'),
        );
      });
    }
  });
}
