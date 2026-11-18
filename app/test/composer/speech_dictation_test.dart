import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/speech/speech.dart';
import 'package:tove_chat/src/ui/composer/speech_dictation.dart';
import 'package:material_ui/material_ui.dart';

import '../speech/speech_fakes.dart';
import 'harness.dart';

/// The composer driven by the real speech `DictationController` through
/// [SpeechComposerDictation], with the speech module's own fakes.
void main() {
  late FakeSpeechPlatform platform;
  late FakeDictationEngine engine;
  late DictationController controller;
  late ComposerRig rig;

  setUp(() {
    platform = FakeSpeechPlatform();
    engine = FakeDictationEngine();
    controller = DictationController(
      platform: platform,
      engines: () => [engine],
    );
    rig = ComposerRig(dictation: null);
  });
  // The composer cancels dictation when it is unmounted, so the widget
  // tree goes before the controller.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    rig.dispose();
    controller.dispose();
  }

  Widget build() =>
      rig.build(dictationOverride: SpeechComposerDictation(controller));

  semanticsTest('partial words stream in muted, final words turn normal', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(build());
    await tester.tap(find.bySemanticsLabel('Dictate'));
    await tester.pumpAndSettle();
    expect(controller.value.status, DictationStatus.listening);
    expect(find.text('Listening…'), findsOneWidget);

    engine.emit(const DictationPartial('hello'));
    await tester.pump();
    expect(rig.text.text, 'hello');
    expect(rig.text.pending, const TextRange(start: 0, end: 5));

    engine.emit(const DictationFinal('hello'));
    await tester.pump();
    expect(rig.text.pending, isNull, reason: 'committed words are final');

    engine.emit(const DictationPartial('world'));
    await tester.pump();
    expect(rig.text.text, 'hello world');
    expect(rig.text.pending, const TextRange(start: 6, end: 11));

    await tester.tap(find.bySemanticsLabel('Stop dictation'));
    await tester.pump();
    engine.emit(const DictationEnded());
    await tester.pumpAndSettle();
    expect(rig.text.text, 'hello world');
    expect(rig.text.pending, isNull);
    expect(find.text('Listening…'), findsNothing);
    await unmount(tester);
  });

  semanticsTest('a blocked microphone becomes a notice', (tester) async {
    phoneSize(tester);
    platform.permission = MicPermission.permanentlyDenied;
    await tester.pumpWidget(build());
    await tester.tap(find.bySemanticsLabel('Dictate'));
    await tester.pumpAndSettle();
    expect(rig.notices.single, contains('Settings › Apps'));
    expect(controller.value.status, DictationStatus.idle, reason: 'dismissed');
    await unmount(tester);
  });

  semanticsTest('no match: "Couldn\'t hear that"', (tester) async {
    phoneSize(tester);
    await tester.pumpWidget(build());
    await tester.tap(find.bySemanticsLabel('Dictate'));
    await tester.pumpAndSettle();
    engine.emit(DictationFailed(DictationError.fromAndroid(7)));
    await tester.pumpAndSettle();
    expect(rig.notices, ["Couldn't hear that"]);
    expect(rig.text.text, isEmpty);
    await unmount(tester);
  });
}
