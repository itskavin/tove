import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/settings/accessibility_about_sections.dart';

import 'test_harness.dart';

/// The in-app privacy policy (About › Privacy policy), bundled with the app.
void main() {
  test('the bundled policy is complete and has a real contact', () {
    final bundled = File(PrivacyPolicyPage.asset).readAsStringSync();
    expect(bundled, contains('collects nothing'));
    expect(bundled, contains('https://github.com/itskavin/tove/issues'));
    expect(bundled, isNot(contains('[DEVELOPER')), reason: 'no placeholder');
    expect(bundled, isNot(contains('Google Play')));
  });

  testWidgets('the page renders the policy', (tester) async {
    phoneSize(tester);
    await tester.pumpWidget(
      themed(
        PrivacyPolicyPage(
          load: () async =>
              '# Tove privacy policy\n\nThe developer collects nothing.',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(
      find.textContaining('collects nothing', findRichText: true),
      findsOneWidget,
    );
  });
}
