import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Third-party code compiled into the app whose licence no pub package adds to
/// the licence page. Fonts are in `ui/theme/fonts.dart`, speech models in
/// `speech/licenses.dart`.
const Map<String, String> kCodeLicences = {
  // lib/src/ui/openui/lang/ is a Dart port of @openuidev/lang-core.
  'OpenUI Lang (@openuidev/lang-core, ported to Dart)':
      'assets/licenses/OpenUI_LICENSE.txt',
};

/// Adds [kCodeLicences] to the app's licence page.
void registerCodeLicences() {
  LicenseRegistry.addLicense(() async* {
    for (final e in kCodeLicences.entries) {
      yield LicenseEntryWithLineBreaks([
        e.key,
      ], await rootBundle.loadString(e.value));
    }
  });
}
