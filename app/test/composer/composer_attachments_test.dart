import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/attachments/attachments.dart';
import 'package:tove_chat/src/ui/composer/attachment_strip.dart';
import 'package:material_ui/material_ui.dart';

import '../attachments/fakes.dart';
import 'harness.dart';

void main() {
  late FakeUploader up;
  late AttachmentController c;
  late ComposerRig rig;

  setUp(() {
    up = FakeUploader();
    c = AttachmentController(
      uploader: up,
      picker: FakePicker(),
      preparer: FakePreparer(),
      capabilities: const AttachmentCapabilities(attachments: true),
    );
    rig = ComposerRig(attachments: c);
  });
  tearDown(() {
    c.dispose();
    rig.dispose();
  });

  Future<void> stage(WidgetTester tester, List<AttachmentSource> s) async {
    c.add(s);
    await tester.pump();
    await tester.pump();
    // Past the pill's 120 ms resize.
    await tester.pump(const Duration(milliseconds: 300));
  }

  semanticsTest('chips: image thumbnail and file chip with name and size', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(rig.build());
    expect(find.byType(AttachmentStrip), findsNothing);
    await stage(tester, [
      fakeImage('cat.jpg'),
      fakeFile('quarterly-report-final-v2-2026.pdf', 1258291),
    ]);
    expect(find.byType(AttachmentStrip), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(
      find.text(middleEllipsis('quarterly-report-final-v2-2026.pdf')),
      findsOneWidget,
    );
    expect(find.text('1.2 MB'), findsOneWidget);
    expect(find.byIcon(Icons.picture_as_pdf_outlined), findsOneWidget);
    expect(find.bySemanticsLabel('Remove cat.jpg'), findsOneWidget);
    // The strip sits inside the pill, above the field.
    final strip = tester.getRect(find.byType(AttachmentStrip));
    final field = tester.getRect(find.byType(TextField));
    expect(strip.bottom, lessThanOrEqualTo(field.top + 1));
  });

  semanticsTest('progress per item; send waits for every upload', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(rig.build());
    await stage(tester, [fakeImage('a.jpg'), fakeFile('b.txt')]);
    // Attachments alone can be sent, so the action is send, but disabled.
    expect(find.bySemanticsLabel('Send message'), findsOneWidget);
    // The file uploads first: the image is prepared before it uploads.
    FakeUpload call(String name) => up.calls.firstWhere((u) => u.name == name);
    call('a.jpg').progress(0.4);
    call('b.txt').progress(0.7);
    await tester.pump();
    final ring = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(ring.value, closeTo(0.4, 0.01));
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.7, 0.01));
    expect(
      find.bySemanticsLabel(RegExp(r'Photo a\.jpg, uploading 40 %')),
      findsOneWidget,
    );
    await tester.tap(find.bySemanticsLabel('Send message'));
    await tester.pump();
    expect(rig.sent, isEmpty, reason: 'still uploading');

    call('a.jpg').succeed();
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Send message'));
    await tester.pump();
    expect(rig.sent, isEmpty, reason: 'one still uploading');

    call('b.txt').succeed();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.enterText(find.byType(TextField), 'look');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Send message'));
    await tester.pump();
    final m = rig.sent.single;
    expect(m.text, 'look');
    expect(m.attachments.map((a) => a.name), ['a.jpg', 'b.txt']);
    expect(c.isEmpty, isTrue, reason: 'cleared after sending');
    expect(up.deleted, isEmpty, reason: 'sent uploads are kept');
    expect(find.byType(AttachmentStrip), findsNothing);
  });

  semanticsTest('attachments alone can be sent', (tester) async {
    phoneSize(tester);
    up.autoComplete = true;
    await tester.pumpWidget(rig.build());
    await stage(tester, [fakeFile('b.txt')]);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Send message'));
    await tester.pump();
    expect(rig.sent.single.text, isEmpty);
    expect(rig.sent.single.attachments.single.name, 'b.txt');
  });

  semanticsTest('remove takes the item out of the strip', (tester) async {
    phoneSize(tester);
    await tester.pumpWidget(rig.build());
    await stage(tester, [fakeImage('a.jpg'), fakeFile('b.txt')]);
    await tester.tap(find.bySemanticsLabel('Remove a.jpg'));
    await tester.pumpAndSettle();
    expect(c.items.single.name, 'b.txt');
    expect(find.byType(Image), findsNothing);
    await tester.tap(find.bySemanticsLabel('Remove b.txt'));
    await tester.pumpAndSettle();
    expect(find.byType(AttachmentStrip), findsNothing);
    expect(
      find.bySemanticsLabel('Start live voice'),
      findsOneWidget,
      reason: 'empty again: the live button returns',
    );
  });

  semanticsTest('a failed upload shows a retry badge that retries', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(rig.build());
    await stage(tester, [fakeFile('b.txt')]);
    up.calls.single.fail();
    await tester.pumpAndSettle();
    expect(find.text('Upload failed (test)'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Send message'));
    await tester.pump();
    expect(rig.sent, isEmpty, reason: 'failed items block sending');

    await tester.tap(find.bySemanticsLabel('Retry b.txt'));
    await tester.pump();
    await tester.pump();
    expect(up.calls, hasLength(2));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    up.calls.last.succeed();
    await tester.pumpAndSettle();
    expect(find.text('2.0 KB'), findsOneWidget);
  });

  semanticsTest('limits: a fifth item is refused with a notice', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(rig.build());
    final picker = c.picker! as FakePicker;
    picker.next = [for (var i = 0; i < 5; i++) fakeImage('$i.jpg')];
    await tester.tap(find.bySemanticsLabel('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Photos'));
    await tester.pumpAndSettle();
    expect(picker.asked, ['photos:4'], reason: 'asks only for what fits');
    expect(c.items, hasLength(4));
    await tester.tap(find.bySemanticsLabel('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Limit reached'), findsNWidgets(3));
    await tester.tap(find.bySemanticsLabel('Close add menu'));
    await tester.pumpAndSettle();
    expect(c.add([fakeFile('x.txt')]), [
      'You can attach up to 4 items to a message',
    ]);
  });

  semanticsTest('picker errors become notices', (tester) async {
    phoneSize(tester);
    await tester.pumpWidget(rig.build());
    (c.picker! as FakePicker).error = const PickException(
      PickErrorKind.permissionDenied,
      'Camera access is off',
    );
    await tester.tap(find.bySemanticsLabel('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Camera'));
    await tester.pumpAndSettle();
    expect(rig.notices, ['Camera access is off']);
  });

  semanticsTest('without onSubmit, attachments stay off (old shell wiring)', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(rig.build(withSubmit: false));
    await tester.tap(find.bySemanticsLabel('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Needs a newer server'), findsNWidgets(3));
    await tester.tap(find.bySemanticsLabel('Close add menu'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'hi');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Send message'));
    await tester.pump();
    expect(rig.events, ['send:hi'], reason: 'onSend keeps working');
  });

  semanticsTest('large text: file chips grow, nothing overflows', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(rig.build(textScale: 2));
    await stage(tester, [fakeImage('a.jpg'), fakeFile('report.pdf')]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(AttachmentStrip)).height,
      greaterThan(AttachmentStrip.chipH * 2),
    );
  });
}
