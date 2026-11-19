import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config.dart';
import '../platform/refresh_policy.dart';
import '../sync/settings_sync.dart';
import 'appearance.dart';
import 'profile.dart';
import 'prefs_store.dart';

export 'appearance.dart' show AccentColour, TextSize;
export 'prefs_store.dart';

/// Where the access key lives. Implementations must never log the value.
abstract interface class KeyStore {
  Future<String?> read();
  Future<void> write(String key);
  Future<void> delete();
}

/// Keychain (iOS/macOS), Android Keystore-backed storage, libsecret (Linux),
/// Windows Credential Manager, and WebCrypto-encrypted storage on the web.
class SecureKeyStore implements KeyStore {
  SecureKeyStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // Readable after first unlock so delegated-task polling keeps
            // working while the phone is locked during a call.
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
            webOptions: WebOptions(
              dbName: 'HermesLive',
              publicKey: 'HermesLive',
            ),
          );

  static const _name = 'hermes_live_access_key';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _name);

  @override
  Future<void> write(String key) => _storage.write(key: _name, value: key);

  @override
  Future<void> delete() => _storage.delete(key: _name);
}

enum AppTheme { light, dark, system }

/// Reply effort for text turns (spec §4.7). Sent to the bridge only when its
/// capabilities say effort is supported.
enum ReplyEffort {
  instant('Instant'),
  medium('Medium'),
  high('High');

  const ReplyEffort(this.label);
  final String label;
}

/// The tone preset Hermes is asked to use (`personalization.style`).
enum ReplyStyle {
  standard('default', 'Default', 'Hermes’ usual style.'),
  concise('concise', 'Concise', 'Short and to the point.'),
  detailed('detailed', 'Detailed', 'Thorough, with context and examples.'),
  friendly('friendly', 'Friendly', 'Warm and conversational.'),
  professional('professional', 'Professional', 'Precise and formal.');

  const ReplyStyle(this.wire, this.label, this.description);

  /// The value the bridge accepts.
  final String wire;
  final String label;
  final String description;

  static ReplyStyle parse(Object? v) =>
      values.where((s) => s.wire == v).firstOrNull ?? standard;
}

/// Builds the sync API for a server address and key.
typedef SettingsApiFactory = SettingsApi Function(Uri baseUrl, String key);

/// The production [SettingsApiFactory].
SettingsApi httpSettingsApi(Uri baseUrl, String key) =>
    HttpSettingsApi(baseUrl: baseUrl, accessKey: key);

/// A voice id the bridge accepts (`A-Z a-z 0-9 _ -`, at most 40).
final _voiceId = RegExp(r'^[A-Za-z0-9_-]{1,40}$');

/// App settings. The access key is held in memory only after it was read from
/// [KeyStore]; it is never written to preferences or logs.
///
/// Preferences marked "synced" below go to the server's settings object
/// (`GET`/`PUT /api/settings`) when the bridge supports it ([sync]); the
/// rest stay on this device. Either way every preference is also kept in
/// [prefs], so the app starts with the last values before the server
/// answers.
class SettingsController extends ChangeNotifier implements SyncSlice {
  SettingsController({
    required this.keys,
    required this.prefs,
    SettingsApiFactory? syncApi,
    SettingsSync? sync,
  }) : _syncApi = syncApi,
       sync =
           sync ?? SettingsSync(store: prefs, watchLifecycle: syncApi != null) {
    this.sync.register(this);
  }

  final KeyStore keys;
  final PrefsStore prefs;
  final SettingsApiFactory? _syncApi;

  /// Syncs the synced preferences across devices; local only without a
  /// [SettingsApiFactory] or on old bridges.
  final SettingsSync sync;

  /// The longest custom instructions and "about you" texts (the server's
  /// `settings_limits.text_chars` once known).
  int get textLimit => sync.support.supported ? sync.support.textChars : 1500;

  bool _loaded = false;
  String? _key;
  String _url = defaultBridgeUrl();

  // Synced.
  String _voice = kDefaultVoice;
  AppTheme _theme = AppTheme.dark;
  ReplyEffort _effort = ReplyEffort.medium;
  AccentColour _accent = AccentColour.blue;
  bool _sendWithEnter = true;
  bool _suggestions = true;
  String _customInstructions = '';
  String _aboutYou = '';
  String _nickname = '';
  String _occupation = '';
  ReplyStyle _style = ReplyStyle.standard;
  Profile _profile = Profile.empty;

  // This device only.
  bool _reduceMotion = false;
  bool _sounds = true;
  bool _haptics = true;
  bool _pullToLive = true;
  bool _locationAnswers = false;
  bool _sidebarCollapsed = false;
  TextSize _textSize = TextSize.standard;
  bool _highContrast = false;
  RefreshMode _refreshRate = RefreshMode.auto;
  String? loadError;

  bool get loaded => _loaded;
  bool get hasKey => (_key ?? '').isNotEmpty;
  String get accessKey => _key ?? '';
  String get url => _url;

  /// Live voice (synced: `voice`).
  String get voice => _voice;

  /// Appearance (synced: `theme`).
  AppTheme get theme => _theme;

  /// Default reply effort (synced: `effort_default`).
  ReplyEffort get effort => _effort;

  /// Accent colour (synced: `tove.accent`).
  AccentColour get accent => _accent;

  /// Enter sends on desktop and web; off, Enter adds a line (synced:
  /// `tove.send_with_enter`).
  bool get sendWithEnter => _sendWithEnter;

  /// Starter suggestions on a new chat (synced: `tove.suggestions`).
  bool get showSuggestions => _suggestions;

  /// How Hermes should respond (synced: `custom_instructions`; the bridge
  /// adds it to every chat).
  String get customInstructions => _customInstructions;

  /// What Hermes should know about you (synced: `about_you`).
  String get aboutYou => _aboutYou;

  /// What Hermes calls you (synced: `personalization.nickname`).
  String get nickname => _nickname;

  /// Name and photo for the avatar (synced: `app.profile`).
  Profile get profile => _profile;

  /// The name the avatar shows: the profile's, else the nickname.
  String get displayName =>
      _profile.name.isNotEmpty ? _profile.name : _nickname;

  /// Synced: `personalization.occupation`.
  String get occupation => _occupation;

  /// Tone preset (synced: `personalization.style`).
  ReplyStyle get style => _style;

  /// True when anything personalises Hermes' replies.
  bool get personalized =>
      _customInstructions.isNotEmpty ||
      _aboutYou.isNotEmpty ||
      _nickname.isNotEmpty ||
      _occupation.isNotEmpty ||
      _style != ReplyStyle.standard;

  bool get reduceMotion => _reduceMotion;
  bool get sounds => _sounds;
  bool get haptics => _haptics;

  /// Pulling up from the composer starts a live call (on by default).
  bool get pullToLive => _pullToLive;

  /// "Use my approximate location for local answers" (off by default): the
  /// app sends a coarse position (about 1 km) with each chat message.
  bool get locationAnswers => _locationAnswers;

  /// Text size on this device.
  TextSize get textSize => _textSize;

  /// Stronger secondary text and dividers on this device.
  bool get highContrast => _highContrast;

  /// Display refresh rate on this device (see `RefreshPolicy`).
  RefreshMode get refreshRate => _refreshRate;

  /// Wide layouts show the chat list as a narrow icon rail (this device
  /// only; phones always use the drawer).
  bool get sidebarCollapsed => _sidebarCollapsed;

  static T _pick<T extends Enum>(List<T> values, String? name, T fallback) =>
      values.asNameMap()[name] ?? fallback;

  Future<void> load() async {
    try {
      _url = await prefs.get('url') ?? _url;
      final v = await prefs.get('voice');
      if (v != null && _voiceId.hasMatch(v)) _voice = v;
      _theme = _pick(AppTheme.values, await prefs.get('theme'), _theme);
      _reduceMotion = await prefs.get('reduceMotion') == 'true';
      _effort = _pick(ReplyEffort.values, await prefs.get('effort'), _effort);
      _sounds = await prefs.get('sounds') != 'false';
      _haptics = await prefs.get('haptics') != 'false';
      _pullToLive = await prefs.get('pullToLive') != 'false';
      _locationAnswers = await prefs.get('location_answers') == 'true';
      _sidebarCollapsed = await prefs.get('sidebarCollapsed') == 'true';
      _accent = _pick(AccentColour.values, await prefs.get('accent'), _accent);
      _textSize = _pick(
        TextSize.values,
        await prefs.get('textSize'),
        _textSize,
      );
      _highContrast = await prefs.get('highContrast') == 'true';
      _refreshRate = _pick(
        RefreshMode.values,
        await prefs.get('refreshRate'),
        _refreshRate,
      );
      _sendWithEnter = await prefs.get('sendWithEnter') != 'false';
      _suggestions = await prefs.get('suggestions') != 'false';
      _customInstructions = await prefs.get('customInstructions') ?? '';
      _aboutYou = await prefs.get('aboutYou') ?? '';
      _nickname = await prefs.get('nickname') ?? '';
      _occupation = await prefs.get('occupation') ?? '';
      _profile = _decodeProfile(await prefs.get('profile'));
      _style = ReplyStyle.parse(await prefs.get('style'));
    } catch (_) {
      // Preferences are optional; defaults are fine.
    }
    try {
      _key = await keys.read();
    } catch (e) {
      _key = null;
      loadError =
          'The saved access key could not be read from secure storage. '
          'Enter it again.';
    }
    _loaded = true;
    notifyListeners();
    unawaited(_connectSync());
  }

  /// Points [sync] at the current server and key (or stops it).
  Future<void> _connectSync() async {
    final factory = _syncApi;
    final base = Uri.tryParse(_url);
    if (factory == null || !hasKey || base == null || !base.hasScheme) {
      await sync.connect(null, server: _url);
      return;
    }
    await sync.connect(factory(base, accessKey), server: _url);
  }

  /// Saves the address and key together (onboarding and "change key").
  Future<void> saveConnection({
    required String url,
    required String key,
  }) async {
    await keys.write(key);
    _key = key;
    _url = url;
    loadError = null;
    await _setPref('url', url);
    notifyListeners();
    unawaited(_connectSync());
  }

  Future<void> forgetKey() async {
    await keys.delete();
    _key = null;
    notifyListeners();
    unawaited(_connectSync());
  }

  Future<void> setVoice(String v) async {
    if (!_voiceId.hasMatch(v) || v == _voice) return;
    _voice = v;
    notifyListeners();
    sync.set('voice', v);
    await _setPref('voice', v);
  }

  Future<void> setTheme(AppTheme t) async {
    if (t == _theme) return;
    _theme = t;
    notifyListeners();
    sync.set('theme', t.name);
    await _setPref('theme', t.name);
  }

  Future<void> setEffort(ReplyEffort e) async {
    if (e == _effort) return;
    _effort = e;
    notifyListeners();
    sync.set('effort_default', e.name);
    await _setPref('effort', e.name);
  }

  Future<void> setAccent(AccentColour a) async {
    if (a == _accent) return;
    _accent = a;
    notifyListeners();
    sync.set('tove.accent', a.name);
    await _setPref('accent', a.name);
  }

  Future<void> setSendWithEnter(bool on) async {
    if (on == _sendWithEnter) return;
    _sendWithEnter = on;
    notifyListeners();
    sync.set('tove.send_with_enter', on);
    await _setPref('sendWithEnter', '$on');
  }

  Future<void> setShowSuggestions(bool on) async {
    if (on == _suggestions) return;
    _suggestions = on;
    notifyListeners();
    sync.set('tove.suggestions', on);
    await _setPref('suggestions', '$on');
  }

  String _clip(String s, int max) {
    final t = s.trim();
    return t.length <= max ? t : t.substring(0, max);
  }

  Future<void> setCustomInstructions(String text) async {
    final v = _clip(text, textLimit);
    if (v == _customInstructions) return;
    _customInstructions = v;
    notifyListeners();
    sync.set('custom_instructions', v.isEmpty ? null : v);
    await _setPref('customInstructions', v);
  }

  Future<void> setAboutYou(String text) async {
    final v = _clip(text, textLimit);
    if (v == _aboutYou) return;
    _aboutYou = v;
    notifyListeners();
    sync.set('about_you', v.isEmpty ? null : v);
    await _setPref('aboutYou', v);
  }

  Future<void> setNickname(String text) async {
    final v = _clip(text, 60);
    if (v == _nickname) return;
    _nickname = v;
    notifyListeners();
    sync.set('personalization/nickname', v.isEmpty ? null : v);
    await _setPref('nickname', v);
  }

  Future<void> setProfile(Profile p) async {
    final v = Profile(
      name: _clip(p.name, 60),
      photoId: p.photoId,
      thumb: p.thumb,
    );
    if (v == _profile) return;
    _profile = v;
    notifyListeners();
    sync.set(Profile.syncKey, v.toJson());
    await _setPref('profile', jsonEncode(v.toJson()));
  }

  static Profile _decodeProfile(String? raw) {
    if (raw == null || raw.isEmpty) return Profile.empty;
    try {
      return Profile.fromJson(jsonDecode(raw));
    } catch (_) {
      return Profile.empty;
    }
  }

  Future<void> setOccupation(String text) async {
    final v = _clip(text, 100);
    if (v == _occupation) return;
    _occupation = v;
    notifyListeners();
    sync.set('personalization/occupation', v.isEmpty ? null : v);
    await _setPref('occupation', v);
  }

  Future<void> setStyle(ReplyStyle s) async {
    if (s == _style) return;
    _style = s;
    notifyListeners();
    sync.set('personalization/style', s == ReplyStyle.standard ? null : s.wire);
    await _setPref('style', s.wire);
  }

  /// Clears every personalisation field at once.
  Future<void> resetPersonalization() async {
    await setCustomInstructions('');
    await setAboutYou('');
    await setNickname('');
    await setOccupation('');
    await setStyle(ReplyStyle.standard);
  }

  Future<void> setReduceMotion(bool on) async {
    _reduceMotion = on;
    notifyListeners();
    await _setPref('reduceMotion', '$on');
  }

  Future<void> setSounds(bool on) async {
    _sounds = on;
    notifyListeners();
    await _setPref('sounds', '$on');
  }

  /// Set by the chat home on devices that can share a location: asks for
  /// the permission and a first position, then turns the setting on.
  Future<bool> Function()? enableLocation;

  /// Whether the location setting can be offered (Android with the chat
  /// home running).
  bool get locationSupported => enableLocation != null;

  /// The settings switch: on asks first (false when declined).
  Future<bool> requestLocationAnswers(bool on) async {
    if (!on) {
      await setLocationAnswers(false);
      return true;
    }
    final ask = enableLocation;
    return ask != null && await ask();
  }

  Future<void> setLocationAnswers(bool on) async {
    if (on == _locationAnswers) return;
    _locationAnswers = on;
    notifyListeners();
    await _setPref('location_answers', '$on');
  }

  Future<void> setPullToLive(bool on) async {
    if (on == _pullToLive) return;
    _pullToLive = on;
    notifyListeners();
    await _setPref('pullToLive', '$on');
  }

  Future<void> setHaptics(bool on) async {
    _haptics = on;
    notifyListeners();
    await _setPref('haptics', '$on');
  }

  Future<void> setTextSize(TextSize s) async {
    if (s == _textSize) return;
    _textSize = s;
    notifyListeners();
    await _setPref('textSize', s.name);
  }

  Future<void> setRefreshRate(RefreshMode m) async {
    if (m == _refreshRate) return;
    _refreshRate = m;
    notifyListeners();
    await _setPref('refreshRate', m.name);
  }

  Future<void> setHighContrast(bool on) async {
    if (on == _highContrast) return;
    _highContrast = on;
    notifyListeners();
    await _setPref('highContrast', '$on');
  }

  Future<void> setSidebarCollapsed(bool on) async {
    if (on == _sidebarCollapsed) return;
    _sidebarCollapsed = on;
    notifyListeners();
    await _setPref('sidebarCollapsed', '$on');
  }

  Future<void> _setPref(String name, String value) async {
    try {
      await prefs.set(name, value);
    } catch (_) {
      // Keep the in-memory value; it applies until the app restarts.
    }
  }

  // --- sync ----------------------------------------------------------------

  /// The synced values that differ from the defaults (the first upload).
  @override
  Map<String, Object?> syncValues() => {
    'theme': _theme.name,
    'voice': _voice,
    'effort_default': _effort.name,
    if (_accent != AccentColour.blue) 'tove.accent': _accent.name,
    if (!_sendWithEnter) 'tove.send_with_enter': false,
    if (!_suggestions) 'tove.suggestions': false,
    if (_customInstructions.isNotEmpty)
      'custom_instructions': _customInstructions,
    if (_aboutYou.isNotEmpty) 'about_you': _aboutYou,
    if (_profile.toJson() != null) Profile.syncKey: _profile.toJson(),
    'personalization': {
      if (_nickname.isNotEmpty) 'nickname': _nickname,
      if (_occupation.isNotEmpty) 'occupation': _occupation,
      if (_style != ReplyStyle.standard) 'style': _style.wire,
    },
  };

  @override
  void applySynced(Map<String, Object?> view) {
    String text(Object? v) => v is String ? v : '';
    final p = view['personalization'];
    final pers = p is Map ? p : const {};
    final voice = view['voice'];
    final next = (
      theme: _pick(AppTheme.values, view['theme'] as String?, AppTheme.dark),
      voice: voice is String && _voiceId.hasMatch(voice)
          ? voice
          : kDefaultVoice,
      effort: _pick(
        ReplyEffort.values,
        view['effort_default'] as String?,
        ReplyEffort.medium,
      ),
      accent: _pick(
        AccentColour.values,
        view['tove.accent'] is String ? view['tove.accent'] as String : null,
        AccentColour.blue,
      ),
      enter: view['tove.send_with_enter'] != false,
      suggestions: view['tove.suggestions'] != false,
      instructions: text(view['custom_instructions']),
      about: text(view['about_you']),
      nickname: text(pers['nickname']),
      occupation: text(pers['occupation']),
      style: ReplyStyle.parse(pers['style']),
      profile: Profile.fromJson(view[Profile.syncKey]),
    );
    final changed =
        next.theme != _theme ||
        next.voice != _voice ||
        next.effort != _effort ||
        next.accent != _accent ||
        next.enter != _sendWithEnter ||
        next.suggestions != _suggestions ||
        next.instructions != _customInstructions ||
        next.about != _aboutYou ||
        next.nickname != _nickname ||
        next.occupation != _occupation ||
        next.style != _style ||
        next.profile != _profile;
    if (!changed) return;
    _theme = next.theme;
    _voice = next.voice;
    _effort = next.effort;
    _accent = next.accent;
    _sendWithEnter = next.enter;
    _suggestions = next.suggestions;
    _customInstructions = next.instructions;
    _aboutYou = next.about;
    _nickname = next.nickname;
    _occupation = next.occupation;
    _style = next.style;
    _profile = next.profile;
    notifyListeners();
    // Keep the local copies current for the next start.
    unawaited(() async {
      await _setPref('theme', _theme.name);
      await _setPref('voice', _voice);
      await _setPref('effort', _effort.name);
      await _setPref('accent', _accent.name);
      await _setPref('sendWithEnter', '$_sendWithEnter');
      await _setPref('suggestions', '$_suggestions');
      await _setPref('customInstructions', _customInstructions);
      await _setPref('aboutYou', _aboutYou);
      await _setPref('nickname', _nickname);
      await _setPref('occupation', _occupation);
      await _setPref('style', _style.wire);
      await _setPref('profile', jsonEncode(_profile.toJson()));
    }());
  }

  @override
  void dispose() {
    sync.dispose();
    super.dispose();
  }
}

/// In-memory stores for tests and previews.
class MemoryKeyStore implements KeyStore {
  MemoryKeyStore([this.value]);
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String key) async => value = key;
  @override
  Future<void> delete() async => value = null;
}
