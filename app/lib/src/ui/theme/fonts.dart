import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bundled font families and their licence files (spec §3.2). All fonts ship
/// with the app; no build fetches them.
const Map<String, String> kFontLicences = {
  'Roboto Flex': 'assets/fonts/RobotoFlex_LICENSE.txt',
  'JetBrains Mono': 'assets/fonts/JetBrainsMono_LICENSE.txt',
  'Roboto': 'assets/fonts/Roboto_LICENSE.txt',
};

/// Adds the font licences to the app's licence page.
void registerFontLicences() {
  LicenseRegistry.addLicense(() async* {
    for (final e in kFontLicences.entries) {
      yield LicenseEntryWithLineBreaks([
        e.key,
      ], await rootBundle.loadString(e.value));
    }
  });
}
