import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The "Reply notifications" switch (system notifications and push; the
/// in-app banner always shows). Stored with shared_preferences so the push
/// and WorkManager background isolates read the same value.
///
/// The settings screen renders it ([enabled] + [setEnabled]); the push
/// registrar listens and unregisters from the bridge when it goes off.
class ReplyNotificationPrefs extends ChangeNotifier {
  ReplyNotificationPrefs({SharedPreferencesAsync? prefs})
    : _prefs = prefs ?? SharedPreferencesAsync();

  static const enabledKey = 'notify.replies.enabled';

  final SharedPreferencesAsync _prefs;
  bool _enabled = true;
  bool _loaded = false;

  bool get enabled => _enabled;
  bool get loaded => _loaded;

  Future<void> load() async {
    try {
      _enabled = await _prefs.getBool(enabledKey) ?? true;
    } catch (_) {
      _enabled = true;
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value && _loaded) return;
    _enabled = value;
    _loaded = true;
    notifyListeners();
    try {
      await _prefs.setBool(enabledKey, value);
    } catch (_) {}
  }

  /// Reads the switch without a listener (background isolates).
  static Future<bool> read({SharedPreferencesAsync? prefs}) async {
    try {
      return await (prefs ?? SharedPreferencesAsync()).getBool(enabledKey) ??
          true;
    } catch (_) {
      return true;
    }
  }
}
