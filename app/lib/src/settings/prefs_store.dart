import 'package:shared_preferences/shared_preferences.dart';

/// Non-secret preferences.
abstract interface class PrefsStore {
  Future<String?> get(String name);
  Future<void> set(String name, String value);
}

class SharedPrefsStore implements PrefsStore {
  final _prefs = SharedPreferencesAsync();

  @override
  Future<String?> get(String name) => _prefs.getString(name);

  @override
  Future<void> set(String name, String value) => _prefs.setString(name, value);
}

class MemoryPrefsStore implements PrefsStore {
  final Map<String, String> values = {};
  @override
  Future<String?> get(String name) async => values[name];
  @override
  Future<void> set(String name, String value) async => values[name] = value;
}
