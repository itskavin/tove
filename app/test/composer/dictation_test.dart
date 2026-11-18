import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/composer/composer.dart';
import 'package:tove_chat/src/ui/composer/dictation_mic.dart';
import 'package:tove_chat/src/ui/feedback.dart';
import 'package:material_ui/material_ui.dart';

import 'harness.dart';

void main() {
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

  semanticsTest('start, live partial text, tap to stop keeps the words', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(rig.build());
    await tester.tap(find.bySemanticsLabel('Dictate'));
    await tester.pump();
    expect(d.calls, ['start']);
    expect(rig.sink.haptics, [Haptic.light]);
    expect(find.byType(DictationMicButton), findsOneWidget);
    expect(find.text('Listening…'), findsOneWidget, reason: 'placeholder');
    expect(find.bySemanticsLabel('Cancel dictation'), findsOneWidget);

    d.hear('turn on the');
    await tester.pump();
    expect(rig.text.text, 'turn on the');
    expect(rig.text.pending, const TextRange(start: 0, end: 11));
    // Text: the action button is send, and the mic stays to stop.
    expect(find.bySemanticsLabel('Send message'), findsOneWidget);
    expect(find.byType(DictationMicButton), findsOneWidget);

    d.hear('turn on the lights');
    await tester.pump();
    expect(
      rig.text.text,
      'turn on the lights',
      reason: 'replaced, not appended',
    );

    await tester.tap(find.bySemanticsLabel('Stop dictation'));
    await tester.pumpAndSettle();
    expect(d.calls, ['start', 'stop']);
    expect(rig.text.text, 'turn on the lights');
    expect(rig.text.pending, isNull, reason: 'final text is not muted');
    expect(rig.sink.haptics, [Haptic.light, Haptic.selection]);
    expect(find.byType(DictationMicButton), findsNothing);
    expect(find.text('Listening…'), findsNothing);
  });

  semanticsTest('cancel restores the text from before dictation', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(rig.build());
    await tester.tap(find.bySemanticsLabel('Dictate'));
    await tester.pump();
    d.hear('never mind this');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Cancel dictation'));
    await tester.pumpAndSettle();
    expect(d.calls, ['start', 'cancel']);
    expect(rig.text.text, isEmpty);
    expect(find.bySemanticsLabel('Start live voice'), findsOneWidget);
    expect(find.bySemanticsLabel('Add'), findsOneWidget);
  });

  semanticsTest('sending while listening ends dictation and sends the words', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(rig.build());
    await tester.tap(find.bySemanticsLabel('Dictate'));
    await tester.pump();
    d.hear('what time is it');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Send message'));
    await tester.pumpAndSettle();
    expect(rig.sent.single.text, 'what time is it');
    expect(d.calls, ['start', 'cancel']);
    expect(rig.text.text, isEmpty, reason: 'no late final text is re-inserted');
  });

  semanticsTest('the level ring follows the input level, then settles', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(rig.build());
    await tester.tap(find.bySemanticsLabel('Dictate'));
    await tester.pump();
    d.hear('a', level: 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    CustomPaint ring() => tester.widget<CustomPaint>(
      find
          .descendant(
            of: find.byType(DictationMicButton),
            matching: find.byType(CustomPaint),
          )
          .first,
    );
    final loud = ring().painter!;
    d.hear('a', level: 0);
    await tester.pumpAndSettle();
    expect(ring().painter, isNot(same(loud)));
    expect(tester.hasRunningAnimations, isFalse, reason: 'ticker idles');
  });

  semanticsTest('errors: no match, permission, and a missing recogniser', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(rig.build());
    await tester.tap(find.bySemanticsLabel('Dictate'));
    await tester.pump();
    d.failWith(
      const ComposerDictationError(ComposerDictationErrorKind.noMatch),
    );
    await tester.pump();
    expect(rig.notices, ["Couldn't hear that"]);
    expect(d.error, isNull, reason: 'acknowledged');
    expect(find.byType(DictationMicButton), findsNothing);

    d.startError = const ComposerDictationError(
      ComposerDictationErrorKind.permissionDenied,
    );
    await tester.tap(find.bySemanticsLabel('Dictate'));
    await tester.pump();
    expect(rig.notices.last, 'Hermes needs microphone access to dictate');

    d.startError = const ComposerDictationError(
      ComposerDictationErrorKind.permissionBlocked,
    );
    await tester.tap(find.bySemanticsLabel('Dictate'));
    await tester.pump();
    expect(rig.notices.last, contains('Settings › Apps'));

    d.startError = const ComposerDictationError(
      ComposerDictationErrorKind.unavailable,
    );
    await tester.tap(find.bySemanticsLabel('Dictate'));
    await tester.pump();
    expect(rig.focus.hasFocus, isTrue, reason: 'keyboard voice key fallback');
  });

  semanticsTest('without a recogniser the mic just focuses the field', (
    tester,
  ) async {
    phoneSize(tester);
    d.available = false;
    await tester.pumpWidget(rig.build());
    await tester.tap(find.bySemanticsLabel('Dictate'));
    await tester.pump();
    expect(d.calls, isEmpty);
    expect(rig.focus.hasFocus, isTrue);
  });

  semanticsTest('starting live voice cancels dictation', (tester) async {
    phoneSize(tester);
    await tester.pumpWidget(rig.build());
    await tester.tap(find.bySemanticsLabel('Dictate'));
    await tester.pump();
    await tester.pumpWidget(rig.build(live: true));
    await tester.pumpAndSettle();
    expect(d.calls, ['start', 'cancel']);
  });
}
