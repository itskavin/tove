import 'dart:convert';

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/composer/composer.dart';
import 'package:tove_chat/src/ui/composer/dictation_hold.dart';
import 'package:tove_chat/src/ui/composer/mic_hold.dart';
import 'package:tove_chat/src/ui/feedback.dart';
import 'package:material_ui/material_ui.dart';

import 'harness.dart';

Future<void> _loadFonts() async {
  final manifest = await rootBundle.loadString('FontManifest.json');
  for (final f in (jsonDecode(manifest) as List).cast<Map<String, dynamic>>()) {
    final loader = FontLoader(f['family'] as String);
    for (final a in (f['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(a['asset'] as String));
    }
    await loader.load();
  }
}

void main() {
  group('MicHoldMachine', () {
    late MicHoldMachine m;
    setUp(() => m = MicHoldMachine());

    test('a release before the hold delay is a tap', () {
      m.down(const Offset(300, 800));
      expect(m.phase, MicHoldPhase.pressed);
      expect(m.move(const Offset(290, 795)), isNull);
      expect(m.up(), MicHoldOutcome.tap);
      expect(m.phase, MicHoldPhase.idle);
    });

    test('hold, then release sends', () {
      m.down(const Offset(300, 800));
      expect(m.holdElapsed(), MicHoldOutcome.holdStarted);
      expect(m.phase, MicHoldPhase.holding);
      expect(m.up(), MicHoldOutcome.send);
      expect(m.holdElapsed(), isNull, reason: 'a late timer does nothing');
    });

    test('sliding left cancels, with progress on the way', () {
      m.down(const Offset(300, 800));
      m.holdElapsed();
      expect(m.move(const Offset(245, 802)), isNull);
      expect(m.cancelProgress, closeTo(0.5, 0.01));
      expect(m.lockProgress, 0);
      expect(m.move(const Offset(300 - 111, 800)), MicHoldOutcome.cancel);
      expect(m.phase, MicHoldPhase.idle);
      expect(m.up(), isNull, reason: 'nothing is sent after a cancel');
    });

    test('sliding up locks hands-free; release keeps recording', () {
      m.down(const Offset(300, 800));
      m.holdElapsed();
      m.move(const Offset(302, 760));
      expect(m.lockProgress, closeTo(0.5, 0.01));
      expect(m.move(const Offset(300, 715)), MicHoldOutcome.lock);
      expect(m.phase, MicHoldPhase.locked);
      expect(m.up(), isNull);
      expect(m.phase, MicHoldPhase.locked);
      m.reset();
      expect(m.phase, MicHoldPhase.idle);
    });

    test('only the dominant direction counts; right and down are ignored', () {
      m.down(const Offset(300, 800));
      m.holdElapsed();
      m.move(const Offset(260, 790));
      expect(m.offset, const Offset(-40, 0));
      m.move(const Offset(380, 900));
      expect(m.offset, Offset.zero);
      expect(m.cancelProgress, 0);
    });

    test('a slide made before the delay acts when the hold begins', () {
      m.down(const Offset(300, 800));
      expect(m.move(const Offset(150, 800)), isNull, reason: 'still a press');
      expect(m.holdElapsed(), MicHoldOutcome.cancel);
    });

    test('a pointer cancel: press → tap, hold → hands-free', () {
      m.down(Offset.zero);
      expect(m.pointerCancelled(), MicHoldOutcome.tap);
      m.down(Offset.zero);
      m.holdElapsed();
      expect(m.pointerCancelled(), MicHoldOutcome.lock);
      expect(m.phase, MicHoldPhase.locked);
    });
  });

  group('composer press and hold', () {
    late FakeDictation d;
    late ComposerRig rig;

    setUp(() {
      d = FakeDictation();
      rig = ComposerRig(dictation: d);
    });
    tearDown(() {
      rig.dispose();
      d.dispose();
    });

    Finder mic() => find.bySemanticsLabel('Dictate');

    semanticsTest('a short press is a tap: dictation into the field', (
      tester,
    ) async {
      phoneSize(tester);
      await tester.pumpWidget(rig.build());
      expect(d.warmUps, 1, reason: 'the server is looked up ahead');
      final g = await tester.startGesture(tester.getCenter(mic()));
      await tester.pump(const Duration(milliseconds: 150));
      expect(d.calls, ['start'], reason: 'listening starts on the press');
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(d.calls, ['start'], reason: 'no hold: stays tap mode');
      expect(find.byType(DictationHoldPanel), findsNothing);
      d.hear('turn on the lights');
      await tester.pump();
      expect(rig.text.text, 'turn on the lights');
      // Tap the mic again to stop; nothing is sent.
      await tester.tap(find.bySemanticsLabel('Stop dictation'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(d.calls, ['start', 'stop']);
      expect(rig.sent, isEmpty);
      expect(rig.text.text, 'turn on the lights');
    });

    semanticsTest('hold: live words, release sends them', (tester) async {
      phoneSize(tester);
      await tester.pumpWidget(rig.build());
      final g = await tester.startGesture(tester.getCenter(mic()));
      await tester.pump(const Duration(milliseconds: 320));
      expect(d.calls, ['start', 'continuous:true']);
      expect(rig.sink.haptics, [Haptic.light, Haptic.medium]);
      expect(find.byType(DictationHoldPanel), findsOneWidget);
      expect(find.textContaining('Release to send'), findsOneWidget);
      expect(find.text('Listening…'), findsWidgets);

      d.hear('remind me to call Ramesh');
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.descendant(
          of: find.byType(DictationHoldPanel),
          matching: find.textContaining('call Ramesh', findRichText: true),
        ),
        findsOneWidget,
      );
      expect(rig.text.text, 'remind me to call Ramesh');

      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(d.calls.last, 'stop');
      expect(rig.sent.single.text, 'remind me to call Ramesh');
      expect(rig.text.text, isEmpty);
      expect(find.byType(DictationHoldPanel), findsNothing);
      expect(rig.notices, isEmpty);
    });

    semanticsTest('slide left cancels: nothing sent, text restored', (
      tester,
    ) async {
      phoneSize(tester);
      await tester.pumpWidget(rig.build());
      final start = tester.getCenter(mic());
      final g = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 320));
      d.hear('never mind');
      await tester.pump();
      await g.moveBy(const Offset(-60, 0));
      await tester.pump();
      expect(find.textContaining('Release to send'), findsNothing);
      expect(find.textContaining('keep sliding to cancel'), findsOneWidget);
      await g.moveBy(const Offset(-60, 0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(d.calls, contains('cancel'));
      expect(find.byType(DictationHoldPanel), findsNothing);
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(rig.sent, isEmpty);
      expect(rig.text.text, isEmpty);
      expect(d.calls.where((c) => c == 'stop'), isEmpty);
    });

    semanticsTest('slide up locks hands-free; Send sends', (tester) async {
      phoneSize(tester);
      await tester.pumpWidget(rig.build());
      final g = await tester.startGesture(tester.getCenter(mic()));
      await tester.pump(const Duration(milliseconds: 320));
      await g.moveBy(const Offset(0, -90));
      await tester.pump();
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(d.calls, isNot(contains('stop')), reason: 'still recording');
      expect(find.text('Hands-free'), findsOneWidget);
      d.hear('book a table for four');
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Send recording').first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(rig.sent.single.text, 'book a table for four');
    });

    semanticsTest('hands-free Cancel throws the words away', (tester) async {
      phoneSize(tester);
      await tester.pumpWidget(rig.build());
      final g = await tester.startGesture(tester.getCenter(mic()));
      await tester.pump(const Duration(milliseconds: 320));
      await g.moveBy(const Offset(0, -90));
      await g.up();
      await tester.pump();
      d.hear('scratch that');
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Cancel recording'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(d.calls, contains('cancel'));
      expect(rig.sent, isEmpty);
      expect(rig.text.text, isEmpty);
    });

    semanticsTest('release with nothing heard: a notice, nothing sent', (
      tester,
    ) async {
      phoneSize(tester);
      await tester.pumpWidget(rig.build());
      final g = await tester.startGesture(tester.getCenter(mic()));
      await tester.pump(const Duration(milliseconds: 320));
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(rig.sent, isEmpty);
      expect(rig.notices, ["Didn't catch that. Nothing was sent."]);
    });

    semanticsTest('errors while holding close the panel and explain', (
      tester,
    ) async {
      phoneSize(tester);
      await tester.pumpWidget(rig.build());
      final g = await tester.startGesture(tester.getCenter(mic()));
      await tester.pump(const Duration(milliseconds: 320));
      d.failWith(
        const ComposerDictationError(
          ComposerDictationErrorKind.other,
          'Couldn’t reach the Tove server to transcribe.',
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(DictationHoldPanel), findsNothing);
      expect(rig.notices, ['Couldn’t reach the Tove server to transcribe.']);
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(rig.sent, isEmpty);
    });

    semanticsTest('no permission on a press: the reason is shown', (
      tester,
    ) async {
      phoneSize(tester);
      d.startError = const ComposerDictationError(
        ComposerDictationErrorKind.permissionDenied,
      );
      await tester.pumpWidget(rig.build());
      final g = await tester.startGesture(tester.getCenter(mic()));
      await tester.pump(const Duration(milliseconds: 320));
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(rig.notices, ['Hermes needs microphone access to dictate']);
      expect(rig.sent, isEmpty);
    });

    semanticsTest('a press on the mic never reaches a parent drag (swipe up '
        'to live)', (tester) async {
      phoneSize(tester);
      var parentDrags = 0;
      await tester.pumpWidget(
        GestureDetector(
          onVerticalDragStart: (_) => parentDrags++,
          onHorizontalDragStart: (_) => parentDrags++,
          child: rig.build(),
        ),
      );
      final g = await tester.startGesture(tester.getCenter(mic()));
      await tester.pump(const Duration(milliseconds: 320));
      await g.moveBy(const Offset(0, -40));
      await g.moveBy(const Offset(-40, 0));
      await tester.pump();
      expect(parentDrags, 0);
      expect(find.byType(DictationHoldPanel), findsOneWidget);
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
    });

    semanticsTest('screen readers: long press records hands-free', (
      tester,
    ) async {
      phoneSize(tester);
      await tester.pumpWidget(rig.build());
      final node = tester.getSemantics(mic());
      expect(node.hint, 'Hold to talk and send');
      tester.semantics.performAction(
        find.semantics.byLabel('Dictate'),
        SemanticsAction.longPress,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(d.calls.first, 'start:continuous');
      expect(d.calls, isNot(contains('stop')));
      expect(find.text('Hands-free'), findsOneWidget);
      expect(find.bySemanticsLabel('Send recording'), findsWidgets);
      expect(find.bySemanticsLabel('Cancel recording'), findsOneWidget);
    });

    semanticsTest('works with the keyboard open', (tester) async {
      phoneSize(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(rig.build());
      rig.focus.requestFocus();
      await tester.pump();
      final g = await tester.startGesture(tester.getCenter(mic()));
      await tester.pump(const Duration(milliseconds: 320));
      expect(find.byType(DictationHoldPanel), findsOneWidget);
      d.hear('hello there');
      await tester.pump();
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(rig.sent.single.text, 'hello there');
      expect(rig.focus.hasFocus, isTrue, reason: 'the keyboard stays');
    });

    semanticsTest('reduced motion: same flow, no growing mic', (tester) async {
      phoneSize(tester);
      await tester.pumpWidget(rig.build(reduce: true));
      final g = await tester.startGesture(tester.getCenter(mic()));
      await tester.pump(const Duration(milliseconds: 320));
      expect(find.byType(DictationHoldPanel), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(HeldMic),
          matching: find.byType(TweenAnimationBuilder<double>),
        ),
        findsNothing,
      );
      d.hear('quiet please');
      await tester.pump();
      await g.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(rig.sent.single.text, 'quiet please');
    });
  });

  group('goldens', () {
    setUpAll(_loadFonts);

    for (final (name, reduce, b) in [
      ('dark', false, Brightness.dark),
      ('light', false, Brightness.light),
      ('reduced', true, Brightness.dark),
    ]) {
      testWidgets('golden: holding the mic ($name)', (tester) async {
        phoneSize(tester, size: const Size(412, 600));
        final d = FakeDictation();
        final rig = ComposerRig(dictation: d);
        addTearDown(() {
          rig.dispose();
          d.dispose();
        });
        await tester.pumpWidget(rig.build(brightness: b, reduce: reduce));
        final g = await tester.startGesture(
          tester.getCenter(find.byIcon(Icons.mic_none_rounded)),
        );
        await tester.pump(const Duration(milliseconds: 320));
        d.stablePrefix = 'Remind me to call Ramesh';
        d.hear('Remind me to call Ramesh at six thirty', level: 0.7);
        for (var i = 0; i < 12; i++) {
          d.level = 0.2 + 0.6 * ((i * 7) % 10) / 10;
          d.notifyListeners();
          await tester.pump(const Duration(milliseconds: 80));
        }
        await g.moveBy(const Offset(-30, 0));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 80));
        }
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/mic_hold_$name.png'),
        );
        await g.up();
        await tester.pump(const Duration(milliseconds: 300));
      });
    }

    testWidgets('golden: hands-free', (tester) async {
      phoneSize(tester, size: const Size(412, 600));
      final d = FakeDictation();
      final rig = ComposerRig(dictation: d);
      addTearDown(() {
        rig.dispose();
        d.dispose();
      });
      await tester.pumpWidget(rig.build());
      final g = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.mic_none_rounded)),
      );
      await tester.pump(const Duration(milliseconds: 320));
      await g.moveBy(const Offset(0, -90));
      await g.up();
      d.hear('Book a table for four near Koramangala', level: 0.4);
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/mic_hold_locked.png'),
      );
    });
  });
}
