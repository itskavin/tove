import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/attachments/attachments.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/ui/composer/plus_tray.dart';
import 'package:tove_chat/src/ui/feedback.dart';
import 'package:material_ui/material_ui.dart';

import '../attachments/fakes.dart';
import 'harness.dart';

void main() {
  late ComposerRig rig;
  tearDown(() => rig.dispose());

  Future<void> openTray(WidgetTester tester) async {
    await tester.tap(find.bySemanticsLabel('Add'));
    await tester.pumpAndSettle();
  }

  testWidgets('+ opens the tray; + again, outside and Back close it', (
    tester,
  ) async {
    phoneSize(tester);
    final h = tester.ensureSemantics();
    rig = ComposerRig();
    await tester.pumpWidget(rig.build());
    expect(find.byType(PlusTray), findsNothing);

    await openTray(tester);
    expect(find.byType(PlusTray), findsOneWidget);
    for (final l in ['Camera', 'Photos', 'Files']) {
      expect(find.text(l), findsOneWidget);
    }
    expect(find.text('Think longer'), findsOneWidget);
    expect(find.text('Think harder'), findsNothing, reason: 'trade dress §7.5');
    expect(find.text('Search the web'), findsNothing, reason: 'round 6 B4');
    expect(find.text('Read replies aloud'), findsOneWidget);
    expect(find.text('Voice and speech settings'), findsOneWidget);
    // The + has turned into ×, named for what it does now.
    final plus = tester.widget<Transform>(
      find
          .ancestor(
            of: find.byIcon(Icons.add_rounded),
            matching: find.byType(Transform),
          )
          .first,
    );
    expect(plus.transform.getRotation().entry(1, 0), closeTo(0.7071, 0.01));
    expect(rig.sink.haptics, [Haptic.light]);

    await tester.tap(find.bySemanticsLabel('Close add menu'));
    await tester.pumpAndSettle();
    expect(find.byType(PlusTray), findsNothing);

    await openTray(tester);
    await tester.tapAt(const Offset(200, 100));
    await tester.pumpAndSettle();
    expect(find.byType(PlusTray), findsNothing, reason: 'tap outside');

    await openTray(tester);
    final popped = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(popped, isTrue, reason: 'Back is used by the tray');
    expect(find.byType(PlusTray), findsNothing);
    h.dispose();
  });

  testWidgets('tray opens with a spring and sits flush on the pill', (
    tester,
  ) async {
    phoneSize(tester);
    rig = ComposerRig();
    await tester.pumpWidget(rig.build());
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final mid = tester.getSize(find.byType(PlusTray)).height;
    await tester.pumpAndSettle();
    final full = tester.getSize(find.byType(PlusTray)).height;
    expect(mid, lessThan(full), reason: 'grows out of the composer');
    final tray = tester.getRect(find.byType(PlusTray));
    final pill = tester.getRect(
      find
          .ancestor(
            of: find.byType(TextField),
            matching: find.byType(RepaintBoundary),
          )
          .first,
    );
    expect(pill.height, 52);
    expect(tray.bottom, closeTo(pill.top, 1.5), reason: 'joined to the pill');
    expect(tray.left, pill.left);
    expect(tray.width, pill.width);
  });

  testWidgets('reduced motion: the tray fades in without growing', (
    tester,
  ) async {
    phoneSize(tester);
    rig = ComposerRig();
    await tester.pumpWidget(rig.build(reduce: true));
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final mid = tester.getSize(find.byType(PlusTray)).height;
    final fade = tester.widget<Opacity>(
      find
          .descendant(of: find.byType(PlusTray), matching: find.byType(Opacity))
          .first,
    );
    expect(fade.opacity, inExclusiveRange(0.0, 1.0));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(PlusTray)).height, mid);
  });

  testWidgets('Think longer toggles effort High and back', (tester) async {
    phoneSize(tester);
    rig = ComposerRig();
    await tester.pumpWidget(rig.build());
    await openTray(tester);
    await tester.tap(find.text('Think longer'));
    await tester.pumpAndSettle();
    expect(rig.effort, ReplyEffort.high);
    expect(
      find.byType(PlusTray),
      findsOneWidget,
      reason: 'switches keep it open',
    );
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);
    await tester.tap(find.text('Think longer'));
    await tester.pumpAndSettle();
    expect(rig.effort, ReplyEffort.medium);
  });

  testWidgets('no web search switch; read aloud is a setting', (
    tester,
  ) async {
    phoneSize(tester);
    rig = ComposerRig(
      attachments: AttachmentController(
        uploader: FakeUploader(),
        capabilities: const AttachmentCapabilities(attachments: true),
      ),
    );
    await tester.pumpWidget(rig.build());
    await openTray(tester);
    expect(find.text('Search the web'), findsNothing);
    await tester.tap(find.text('Read replies aloud'));
    await tester.pumpAndSettle();
    expect(rig.events, ['aloud:true']);
    await tester.tap(find.text('Voice and speech settings'));
    await tester.pumpAndSettle();
    expect(rig.events.last, 'voice-settings');
    expect(find.byType(PlusTray), findsNothing, reason: 'a row closes it');

    await tester.enterText(find.byType(TextField), 'news?');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Send message'));
    await tester.pump();
    expect(rig.sent.single.text, 'news?');
    expect(rig.sent.single.webSearch, isFalse, reason: 'the model decides');
    rig.attachments!.dispose();
  });

  testWidgets('without the capability the search row is hidden', (
    tester,
  ) async {
    phoneSize(tester);
    rig = ComposerRig(webSearchSupported: false);
    await tester.pumpWidget(rig.build());
    await openTray(tester);
    expect(find.text('Search the web'), findsNothing);
  });

  testWidgets('capability gating: tiles say "Needs a newer server"', (
    tester,
  ) async {
    phoneSize(tester);
    final h = tester.ensureSemantics();
    final picker = FakePicker();
    final c = AttachmentController(
      uploader: FakeUploader(),
      picker: picker,
      capabilities: const AttachmentCapabilities(attachments: true),
    );
    rig = ComposerRig(attachments: c, attachmentsSupported: false);
    await tester.pumpWidget(rig.build());
    await openTray(tester);
    expect(find.text(kNeedsNewerServer), findsNWidgets(3));
    expect(find.text('Coming soon'), findsNothing);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Camera')),
      isSemantics(
        label: 'Camera',
        hint: kNeedsNewerServer,
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    await tester.tap(find.text('Photos'));
    await tester.pumpAndSettle();
    expect(picker.asked, isEmpty);
    c.dispose();
    h.dispose();
  });

  testWidgets('no controller wired also counts as unsupported', (tester) async {
    phoneSize(tester);
    rig = ComposerRig();
    await tester.pumpWidget(rig.build());
    await openTray(tester);
    expect(find.text(kNeedsNewerServer), findsNWidgets(3));
  });

  testWidgets('a supported tile closes the tray and opens the picker', (
    tester,
  ) async {
    phoneSize(tester);
    final picker = FakePicker()..next = [fakeFile('notes.pdf')];
    final up = FakeUploader();
    final c = AttachmentController(
      uploader: up,
      picker: picker,
      preparer: FakePreparer(),
      capabilities: const AttachmentCapabilities(attachments: true),
    );
    rig = ComposerRig(attachments: c);
    await tester.pumpWidget(rig.build());
    await openTray(tester);
    expect(find.text(kNeedsNewerServer), findsNothing);
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    expect(find.byType(PlusTray), findsNothing);
    expect(picker.asked, ['files:4']);
    expect(find.text('notes.pdf'), findsOneWidget);
    up.calls.single.succeed();
    await tester.pumpAndSettle();
    c.dispose();
  });

  testWidgets('at 2× text the tray fits and scrolls instead of overflowing', (
    tester,
  ) async {
    phoneSize(tester, size: const Size(360, 640));
    rig = ComposerRig();
    await tester.pumpWidget(rig.build(textScale: 2));
    await openTray(tester);
    expect(tester.takeException(), isNull);
    final tray = tester.getRect(find.byType(PlusTray));
    expect(tray.top, greaterThanOrEqualTo(0));
    expect(find.text('Camera'), findsOneWidget);
  });

  testWidgets('keyboard: tiles and rows are focusable and activate', (
    tester,
  ) async {
    phoneSize(tester);
    final picker = FakePicker();
    final c = AttachmentController(
      uploader: FakeUploader(),
      picker: picker,
      capabilities: const AttachmentCapabilities(attachments: true),
    );
    rig = ComposerRig(attachments: c);
    await tester.pumpWidget(rig.build());
    await openTray(tester);
    Focus.of(tester.element(find.text('Camera'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picker.asked, ['camera']);
    c.dispose();
  });
}
