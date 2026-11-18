import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/theme/motion.dart';
import 'package:tove_chat/src/ui/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

bool _fontsLoaded = false;

/// Loads the bundled families (and Material icons) so goldens show real
/// glyphs: HermesSans (Roboto Flex), JetBrains Mono, Roboto.
Future<void> loadReplyFonts() async {
  if (_fontsLoaded) return;
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(rootBundle.load(f));
    }
    await loader.load();
  }

  await load('HermesSans', ['assets/fonts/RobotoFlex-Hermes.ttf']);
  await load('JetBrainsMono', [
    'assets/fonts/JetBrainsMono-Regular.ttf',
    'assets/fonts/JetBrainsMono-SemiBold.ttf',
  ]);
  await load('Roboto', [
    'assets/fonts/Roboto-Regular.ttf',
    'assets/fonts/Roboto-Medium.ttf',
    'assets/fonts/Roboto-Bold.ttf',
  ]);
  await load('MaterialIcons', ['fonts/MaterialIcons-Regular.otf']);
  _fontsLoaded = true;
}

const goldenKey = ValueKey('golden');

/// A 412 dp phone column with the 16 dp thread gutter, in [brightness], at
/// [textScale]. The golden captures [goldenKey] (gutter included, so tables
/// can be seen bleeding to the edges).
Widget replyFrame(
  Widget child, {
  Brightness brightness = Brightness.dark,
  double textScale = 1,
  bool reduceMotion = true,
}) {
  final theme = buildTheme(brightness);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (context, c) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: MotionScope(reduce: reduceMotion, child: c!),
    ),
    home: Scaffold(
      body: SelectionArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: RepaintBoundary(
            key: goldenKey,
            child: Container(
              width: 412,
              color: theme.scaffoldBackgroundColor,
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Runs [body] for dark/light × 100 %/200 % text, naming goldens
/// `<name>_<theme>_<scale>.png`.
void goldenMatrix(
  String name,
  Widget Function() build, {
  String dir = 'goldens',
  Future<void> Function(WidgetTester tester)? before,
}) {
  for (final b in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      final tag = '${name}_${b.name}_${(scale * 100).round()}';
      testWidgets('golden $tag', (tester) async {
        await loadReplyFonts();
        tester.view.physicalSize = Size(412, scale > 1 ? 4000 : 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          replyFrame(build(), brightness: b, textScale: scale),
        );
        await tester.pump(const Duration(milliseconds: 500));
        if (before != null) await before(tester);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('$dir/$tag.png'),
        );
      });
    }
  }
}
