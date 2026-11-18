import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Only Android and iOS give each app its own temporary directory; on
/// desktops it is the shared system one (`/tmp`, `%TEMP%`), which is never
/// counted or touched.
bool get _ownTemp => Platform.isAndroid || Platform.isIOS;

/// The size of the app's temporary directory, or null when it has none.
Future<int?> temporaryBytes() async {
  if (!_ownTemp) return null;
  try {
    final dir = await getTemporaryDirectory();
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {}
      }
    }
    return total;
  } catch (_) {
    return null;
  }
}

/// Deletes what is in the temporary directory (the directory stays).
Future<void> clearTemporary() async {
  if (!_ownTemp) return;
  try {
    final dir = await getTemporaryDirectory();
    if (!await dir.exists()) return;
    await for (final e in dir.list(followLinks: false)) {
      try {
        await e.delete(recursive: true);
      } catch (_) {
        // In use; it goes next time.
      }
    }
  } catch (_) {}
}
