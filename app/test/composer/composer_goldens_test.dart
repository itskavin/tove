import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/attachments/attachments.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/ui/composer/attachment_strip.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';

import '../attachments/fakes.dart';
import 'harness.dart';

/// A 4:3 gradient "photo" so the thumbnail shows real pixels.
AttachmentSource _photo(String name) {
  final p = img.Image(width: 120, height: 90);
  for (final px in p) {
    px
      ..r = 40 + px.x
      ..g = 90 + px.y
      ..b = 200 - px.x ~/ 2;
  }
  return AttachmentSource.bytes(
    name,
    img.encodePng(p),
    mime: 'image/png',
    origin: AttachmentOrigin.photos,
  );
}

/// The fonts the theme uses now (read from the pubspec families, so a font
/// swap by the theme owner does not break these goldens).
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
  setUpAll(_loadFonts);

  Future<void> settleImages(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  for (final b in Brightness.values) {
    testWidgets('golden: + tray open (${b.name})', (tester) async {
      phoneSize(tester, size: const Size(412, 600));
      final c = AttachmentController(
        uploader: FakeUploader(),
        capabilities: const AttachmentCapabilities(attachments: true),
      );
      final rig = ComposerRig(attachments: c)..effort = ReplyEffort.high;
      addTearDown(() {
        c.dispose();
        rig.dispose();
      });
      await tester.pumpWidget(rig.build(brightness: b));
      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/tray_open_${b.name}.png'),
      );
    });
  }

  testWidgets('golden: tray without upload support', (tester) async {
    phoneSize(tester, size: const Size(412, 600));
    final rig = ComposerRig(webSearchSupported: false);
    addTearDown(rig.dispose);
    await tester.pumpWidget(rig.build());
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/tray_needs_newer_server.png'),
    );
  });

  testWidgets('golden: staged attachments (uploading, ready, failed)', (
    tester,
  ) async {
    phoneSize(tester, size: const Size(412, 360));
    final up = FakeUploader();
    final c = AttachmentController(
      uploader: up,
      preparer: FakePreparer(),
      capabilities: const AttachmentCapabilities(attachments: true),
    );
    final rig = ComposerRig(attachments: c);
    addTearDown(() {
      c.dispose();
      rig.dispose();
    });
    await tester.pumpWidget(rig.build());
    c.add([
      _photo('beach.png'),
      fakeFile('server-logs.txt', 48211),
      _photo('receipt.png'),
      fakeFile('quarterly-report-final-v2-2026.pdf', 1258291),
    ]);
    await tester.pump();
    await tester.pump();
    FakeUpload call(String n) => up.calls.firstWhere((u) => u.name == n);
    call('beach.jpg').progress(0.62);
    call('receipt.jpg').succeed();
    call('quarterly-report-final-v2-2026.pdf').progress(0.35);
    call('server-logs.txt').fail();
    await settleImages(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/attachments_strip.png'),
    );
  });

  testWidgets('golden: attachments at 2× text', (tester) async {
    phoneSize(tester, size: const Size(412, 400));
    final up = FakeUploader()..autoComplete = true;
    final c = AttachmentController(
      uploader: up,
      preparer: FakePreparer(),
      capabilities: const AttachmentCapabilities(attachments: true),
    );
    final rig = ComposerRig(attachments: c);
    addTearDown(() {
      c.dispose();
      rig.dispose();
    });
    await tester.pumpWidget(rig.build(textScale: 2));
    c.add([_photo('beach.png'), fakeFile('notes.md', 3100)]);
    await tester.pump();
    await tester.pump();
    await settleImages(tester);
    expect(find.byType(AttachmentStrip), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/attachments_large_text.png'),
    );
  });
}
