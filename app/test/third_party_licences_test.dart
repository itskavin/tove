import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/third_party_licences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every bundled code licence is an asset with the MIT text', () async {
    for (final path in kCodeLicences.values) {
      final text = await rootBundle.loadString(path);
      expect(text, contains('Permission is hereby granted'));
    }
  });

  test('the OpenUI notice reaches the licence page', () async {
    registerCodeLicences();
    final entries = await LicenseRegistry.licenses.toList();
    expect(
      entries.any((e) => e.packages.any((p) => p.startsWith('OpenUI Lang'))),
      isTrue,
    );
  });
}
