import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'settings_harness.dart';
import 'test_harness.dart';

void main() {
  setUpAll(loadAppFonts);

  Future<SettingsHarness> make() async {
    final h = SettingsHarness();
    await h.setUp();
    addTearDown(h.dispose);
    // Show filled personalization in the renders.
    await h.settings.setNickname('Kay');
    await h.settings.setCustomInstructions(
      'Keep answers short. Use metric units and 24-hour times.',
    );
    return h;
  }

  Future<void> golden(WidgetTester tester, String name) => expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/settings_$name.png'),
  );

  for (final b in Brightness.values) {
    testWidgets('hub ${b.name}', (tester) async {
      final h = await make();
      await h.open(tester, brightness: b);
      await golden(tester, 'hub_${b.name}');
    });

    testWidgets('general ${b.name}', (tester) async {
      final h = await make();
      await h.open(tester, brightness: b);
      await openSection(tester, 'General');
      await golden(tester, 'general_${b.name}');
    });

    testWidgets('personalization ${b.name}', (tester) async {
      final h = await make();
      await h.open(tester, brightness: b);
      await openSection(tester, 'Personalization');
      await golden(tester, 'personalization_${b.name}');
    });
  }

  testWidgets('wide dark', (tester) async {
    final h = await make();
    await h.open(tester, size: const Size(1280, 800));
    await tester.tap(find.byKey(const ValueKey('settings-nav-data')));
    await tester.pumpAndSettle();
    await golden(tester, 'wide_data_dark');
  });
}
