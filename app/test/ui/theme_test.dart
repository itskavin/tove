import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/ui/common/group_card.dart';
import 'package:tove_chat/src/ui/theme/fonts.dart';
import 'package:tove_chat/src/ui/theme/theme.dart';
import 'package:material_ui/material_ui.dart';

import 'test_harness.dart';

Widget _sampleCard() => Builder(
  builder: (context) {
    final t = HermesTokens.of(context);
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Hermes', style: t.display),
            Text('What can I do for you?', style: t.headline),
            const SizedBox(height: 8),
            Text('Body text with **weight** in HermesSans.', style: t.body),
            Text('code()', style: t.code),
            const SizedBox(height: 12),
            const GroupCard(
              children: [
                GroupRow(
                  label: 'Voice',
                  icon: Icons.graphic_eq_rounded,
                  value: 'Cove',
                  trailing: Icon(Icons.chevron_right_rounded),
                ),
                GroupRow(label: 'Audio output', value: 'Speaker'),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: () {}, child: const Text('Connect')),
          ],
        ),
      ),
    );
  },
);

void main() {
  setUpAll(loadAppFonts);

  for (final b in Brightness.values) {
    testWidgets('sample card golden, ${b.name}', (tester) async {
      phoneSize(tester, size: const Size(412, 520));
      await tester.pumpWidget(themed(_sampleCard(), brightness: b));
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/theme_card_${b.name}.png'),
      );
    });
  }

  test('token contrast pairs meet WCAG AA', () {
    double ratio(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
      return (hi + 0.05) / (lo + 0.05);
    }

    for (final t in [HermesTokens.darkTokens, HermesTokens.lightTokens]) {
      expect(ratio(t.text, t.bgRaised), greaterThan(4.5));
      expect(ratio(t.textMuted, t.surface), greaterThan(4.5));
      expect(ratio(t.textFaint, t.surface), greaterThan(3.0));
      expect(ratio(t.onAccent, t.accent), greaterThan(4.5));
      expect(ratio(t.onClose, t.closeFill), greaterThan(7));
      expect(ratio(t.danger, t.bg), greaterThan(4.5));
    }
    // The placeholder ratio the spec lists for dark (5.2:1).
    expect(
      ratio(HermesTokens.darkTokens.textFaint, HermesTokens.darkTokens.surface),
      greaterThan(4.5),
    );
  });

  test('the theme uses the bundled families', () {
    final theme = buildTheme(Brightness.dark);
    expect(theme.textTheme.bodyLarge!.fontFamily, 'HermesSans');
    expect(theme.scaffoldBackgroundColor, const Color(0xFF000000));
    expect(HermesTokens.darkTokens.code.fontFamily, 'JetBrainsMono');
  });

  testWidgets('font licences are registered', (tester) async {
    registerFontLicences();
    final names = <String>{};
    await tester.runAsync(() async {
      await for (final l in LicenseRegistry.licenses) {
        names.addAll(l.packages);
      }
    });
    expect(names, containsAll(kFontLicences.keys));
  });

  test('dark is the default appearance', () async {
    final s = SettingsController(
      keys: MemoryKeyStore(),
      prefs: MemoryPrefsStore(),
    );
    await s.load();
    expect(s.theme, AppTheme.dark);
    expect(s.effort, ReplyEffort.medium);
    expect(s.sounds, isTrue);
    expect(s.haptics, isTrue);
  });
}
