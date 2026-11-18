import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/theme/motion.dart';
import 'package:tove_chat/src/ui/theme/render_policy.dart';
import 'package:tove_chat/src/ui/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

/// Loads every bundled font family from the asset manifest, so goldens show
/// real glyphs and a font swap in the pubspec needs no change here.
Future<void> loadAppFonts() async {
  final manifest = await rootBundle.loadString('FontManifest.json');
  for (final f in (jsonDecode(manifest) as List).cast<Map<String, dynamic>>()) {
    final loader = FontLoader(f['family'] as String);
    for (final a in (f['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(a['asset'] as String));
    }
    await loader.load();
  }
}

/// Wraps [child] in the app theme with a fixed render policy (no blur, so
/// goldens do not depend on the backdrop).
Widget themed(
  Widget child, {
  Brightness brightness = Brightness.dark,
  bool reduce = false,
  RenderPolicy? policy,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(brightness),
    home: MotionScope(
      reduce: reduce,
      child: RenderPolicyScope(
        policy:
            policy ??
            RenderPolicy(
              blur: false,
              shaderOrb: false,
              liveMask: true,
              monitor: false,
            ),
        child: child,
      ),
    ),
  );
}

void phoneSize(WidgetTester tester, {Size size = const Size(412, 915)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Loads the colour emoji font shipped with the Flutter engine sources, so
/// goldens show the chips' emoji (the platforms bring their own).
Future<void> loadEmojiFont() async {
  final home = Platform.environment['HOME'];
  final root = Platform.environment['FLUTTER_ROOT'];
  for (final p in [
    if (root != null)
      '$root/engine/src/flutter/txt/third_party/fonts/NotoColorEmoji.ttf',
    '$home/.local/share/hermes-build-tools/flutter/engine/src/flutter/txt/'
        'third_party/fonts/NotoColorEmoji.ttf',
  ]) {
    final f = File(p);
    if (f.existsSync()) {
      final loader = FontLoader('Noto Color Emoji')
        ..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      return;
    }
  }
}
