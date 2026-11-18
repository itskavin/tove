import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/theme/fonts.dart';
import 'package:tove_chat/src/ui/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

import '../markdown/golden_harness.dart';

double _wght(TextStyle s) =>
    s.fontVariations!.firstWhere((v) => v.axis == 'wght').value;
double _opsz(TextStyle s) =>
    s.fontVariations!.firstWhere((v) => v.axis == 'opsz').value;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const d = HermesTokens.darkTokens;
  const l = HermesTokens.lightTokens;

  test('reply tokens match chat-rendering-v2 §1.3', () {
    void check(TextStyle s, double size, double line, double wght, double tr) {
      expect(s.fontFamily, 'HermesSans');
      expect(s.fontFamilyFallback, ['Roboto']);
      expect(s.fontSize, size);
      expect(s.fontSize! * s.height!, closeTo(line, 1e-9));
      expect(_wght(s), wght);
      expect(_opsz(s), size);
      expect(s.letterSpacing, tr);
      expect(s.leadingDistribution, TextLeadingDistribution.even);
      expect(s.fontWeight, FontWeight.values[(wght / 100).round() - 1]);
    }

    check(d.body, 17, 26, 400, 0);
    check(d.bodyStrong, 17, 26, 700, 0);
    check(d.h1, 26, 32, 700, -0.4);
    check(d.h2, 23, 30, 650, -0.3);
    check(d.h3, 20, 27, 650, -0.2);
    check(d.h4, 17, 26, 700, 0);
    check(d.caption, 14, 20, 400, 0);
    check(d.table, 14.5, 20, 400, 0);
    check(d.tableHeader, 14.5, 20, 700, 0);
    check(d.widgetLabel, 17, 24, 700, -0.15);
    check(d.statValue, 28, 34, 700, -0.4);
    check(d.statLabel, 14.5, 20, 400, 0);
    check(d.chip, 13, 16, 500, 0);
    expect(d.code.fontFamily, 'JetBrainsMono');
    expect(d.bodyEm.fontVariations, contains(const FontVariation('slnt', -10)));
  });

  test('colours: pure white text and #B4B4B8 captions in dark', () {
    expect(d.text, const Color(0xFFFFFFFF));
    expect(d.textMuted, const Color(0xFFB4B4B8));
    expect(d.body.color, d.text);
    expect(d.caption.color, d.textMuted);
    expect(l.text, const Color(0xFF16161A));
    expect(l.textMuted, const Color(0xFF68686F));
    expect(l.body.color, l.text);
    // Light uses the same sizes and weights.
    expect(_wght(l.body), 400);
    expect(l.h2.fontSize, d.h2.fontSize);
  });

  test('caption and muted text keep AA contrast on their canvases', () {
    double lum(Color c) {
      double ch(double v) => v <= 0.03928
          ? v / 12.92
          : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
    }

    double ratio(Color a, Color b) {
      final x = lum(a), y = lum(b);
      return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
    }

    for (final t in [d, l]) {
      expect(ratio(t.textMuted, t.bg), greaterThan(4.5));
      expect(ratio(t.text, t.surface), greaterThan(7));
    }
    // Source chips: muted text on surfaceHigh. Dark is comfortable; light
    // (#6B6B72 on #E9E9EC, both unchanged by the spec) is 4.36:1, just
    // under AA for small text. Flagged for the designer; guarded here so
    // it does not get worse.
    expect(ratio(d.textMuted, d.surfaceHigh), greaterThan(4.5));
    expect(ratio(l.textMuted, l.surfaceHigh), greaterThanOrEqualTo(4.5));
  });

  test('weight and slant helpers keep the variable axes in step', () {
    final b = d.body.hermesWeight(700);
    expect(b.fontWeight, FontWeight.w700);
    expect(_wght(b), 700);
    expect(_opsz(b), 17);
    expect(b.fontVariations!.where((v) => v.axis == 'wght'), hasLength(1));
    final small = d.body.hermesSize(14, line: 20);
    expect(_opsz(small), 14);
    expect(small.fontSize! * small.height!, closeTo(20, 1e-9));
    // Non-variable families are left alone.
    expect(d.code.hermesWeight(600).fontVariations, isNull);
    expect(d.code.hermesOblique().fontStyle, FontStyle.italic);
  });

  test('the theme uses HermesSans', () {
    final theme = buildTheme(Brightness.dark);
    expect(theme.textTheme.bodyLarge!.fontFamily, 'HermesSans');
    expect(Sp.thread, 16);
  });

  test('every shipped font has its licence; Inter is gone', () {
    expect(
      kFontLicences.keys,
      containsAll(['Roboto Flex', 'JetBrains Mono', 'Roboto']),
    );
    expect(kFontLicences.keys, isNot(contains('Inter')));
    for (final f in kFontLicences.values) {
      expect(File(f).existsSync(), isTrue, reason: f);
    }
    expect(
      File('assets/fonts/RobotoFlex_LICENSE.txt').readAsStringSync(),
      contains('SIL Open Font License, Version 1.1'),
    );
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, isNot(contains('Inter')));
    expect(pubspec, contains('RobotoFlex_LICENSE.txt'));
    expect(
      Directory('assets/fonts')
          .listSync()
          .map((e) => e.path)
          .where((p) => p.contains('Inter')),
      isEmpty,
    );
    // The subset stays small.
    expect(
      File('assets/fonts/RobotoFlex-Hermes.ttf').lengthSync(),
      lessThan(500 * 1024),
    );
  });

  testWidgets('font licences register', (tester) async {
    registerFontLicences();
    final names = <String>{};
    await tester.runAsync(() async {
      await for (final l in LicenseRegistry.licenses) {
        names.addAll(l.packages);
      }
    });
    expect(names, contains('Roboto Flex'));
  });

  test('the tracking check line (spec §1.3) stays where measured', () async {
    // chat-rendering-v2 §1.3: the reference line in `body` at 1.0 scale.
    await loadReplyFonts();
    final tp = TextPainter(
      text: TextSpan(
        text: "For your own AI voice assistant, I'd compare them",
        style: d.body,
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // The spec's acceptance width: 366 dp ± 1 %. Roboto Flex at opsz 17 is
    // narrower than the spec assumed, so body tracking is 0 (not −0.15,
    // which measured 359.5 dp).
    expect(tp.width, closeTo(366, 366 * 0.01));
    tp.dispose();
  });
}
