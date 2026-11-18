import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../app.dart' show kAppVersion;

/// The repository whose GitHub Releases carry the signed APK.
const kReleaseRepo = 'itskavin/tove';

/// The newest published (non-draft, non-prerelease) release.
final kLatestReleaseApi = Uri.parse(
  'https://api.github.com/repos/$kReleaseRepo/releases/latest',
);

/// Where people download Tove (README, About).
const kReleasesPage = 'https://github.com/$kReleaseRepo/releases/latest';

/// An app version: `1.2.3` with an optional build number (`1.2.3+7`).
///
/// Release tags follow the pubspec version with a `v` prefix: `v1.2.3+7`
/// (app/README.md "Releasing"). The build number is the Android
/// versionCode; a tag without one compares by `1.2.3` alone.
@immutable
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, [this.build]);

  final int major;
  final int minor;
  final int patch;
  final int? build;

  static final _pattern = RegExp(
    r'^[vV]?(\d+)\.(\d+)\.(\d+)(?:[-.][0-9A-Za-z.-]*)?(?:\+(\d+))?$',
  );

  /// `1.2.3`, `v1.2.3+7`, `1.2.3+7`; null for anything else.
  static AppVersion? tryParse(String? text) {
    final m = _pattern.firstMatch((text ?? '').trim());
    if (m == null) return null;
    return AppVersion(
      int.parse(m[1]!),
      int.parse(m[2]!),
      int.parse(m[3]!),
      m[4] == null ? null : int.parse(m[4]!),
    );
  }

  /// The version from an APK asset name (`tove-1.2.3.apk`, `tove-1.2.3+7.apk`).
  static AppVersion? fromApkName(String name) {
    final m = RegExp(
      r'^tove-(.+)\.apk$',
      caseSensitive: false,
    ).firstMatch(name);
    return m == null ? null : tryParse(m[1]);
  }

  /// `1.2.3` (what people see).
  String get name => '$major.$minor.$patch';

  @override
  int compareTo(AppVersion o) {
    for (final (a, b) in [
      (major, o.major),
      (minor, o.minor),
      (patch, o.patch),
    ]) {
      if (a != b) return a.compareTo(b);
    }
    // Build numbers only decide when both sides have one.
    final b1 = build, b2 = o.build;
    return b1 == null || b2 == null ? 0 : b1.compareTo(b2);
  }

  bool isNewerThan(AppVersion o) => compareTo(o) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => build == null ? name : '$name+$build';
}

/// A newer release than the one installed.
@immutable
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.tag,
    required this.notes,
    required this.downloadUrl,
    required this.pageUrl,
    this.title,
  });

  final AppVersion version;
  final String tag;
  final String? title;

  /// The release notes (Markdown as written on GitHub), trimmed.
  final String notes;

  /// The APK asset, or the release page when the release has no APK.
  final Uri downloadUrl;
  final Uri pageUrl;

  /// Reads `GET /repos/{repo}/releases/latest`; null when it is not usable.
  static ReleaseInfo? fromJson(Map<String, Object?> j) {
    if (j['draft'] == true || j['prerelease'] == true) return null;
    final tag = j['tag_name'];
    final page = Uri.tryParse(j['html_url'] as String? ?? '');
    if (tag is! String || page == null || !page.isScheme('https')) return null;
    Uri? apk;
    AppVersion? apkVersion;
    final assets = j['assets'];
    if (assets is List) {
      // Prefer tove-X.Y.Z.apk; any other .apk is a fallback.
      for (final a in assets.whereType<Map>()) {
        final name = a['name'], url = a['browser_download_url'];
        if (name is! String || url is! String) continue;
        if (!name.toLowerCase().endsWith('.apk')) continue;
        final u = Uri.tryParse(url);
        if (u == null || !u.isScheme('https')) continue;
        final v = AppVersion.fromApkName(name);
        if (apk == null || (apkVersion == null && v != null)) {
          apk = u;
          apkVersion = v;
        }
      }
    }
    final version = AppVersion.tryParse(tag) ?? apkVersion;
    if (version == null) return null;
    final body = j['body'];
    final name = j['name'];
    return ReleaseInfo(
      version: version,
      tag: tag,
      title: name is String && name.trim().isNotEmpty ? name.trim() : null,
      notes: body is String ? body.trim() : '',
      downloadUrl: apk ?? page,
      pageUrl: page,
    );
  }
}

/// What a check found.
enum UpdateStatus {
  /// No check yet (or the check is off).
  unknown,
  checking,
  upToDate,
  available,

  /// No connection; nothing to say.
  offline,

  /// GitHub's unauthenticated limit (60 an hour per address) was reached.
  rateLimited,
  failed,
}

/// Checks GitHub Releases for a newer Tove APK.
///
/// - At start, at most once a day ([checkIfDue]), unless turned off in
///   Settings › About. Failures (offline, rate limit, GitHub down) stay
///   quiet; the next day's check tries again.
/// - From Settings › About › Check for updates ([checkNow]) any time.
/// - Nothing is downloaded or installed in the app: "Download" opens the
///   APK's URL in the browser.
///
/// The request goes to api.github.com without credentials; it carries no
/// data about the user (only the usual request headers and the address).
class UpdateChecker extends ChangeNotifier {
  UpdateChecker({
    http.Client? client,
    SharedPreferencesAsync? prefs,
    String installed = kAppVersion,
    DateTime Function()? now,
    bool? supported,
  }) : _http = client,
       _prefs = prefs ?? SharedPreferencesAsync(),
       installed = AppVersion.tryParse(installed) ?? const AppVersion(0, 0, 0),
       _now = now ?? DateTime.now,
       supported = supported ?? supportedHere;

  static const enabledKey = 'update.check.enabled';
  static const lastCheckKey = 'update.check.last';
  static const dismissedKey = 'update.check.dismissed';
  static const interval = Duration(days: 1);
  static const timeout = Duration(seconds: 12);

  /// Releases carry an APK, so only Android checks.
  static bool get supportedHere =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  final http.Client? _http;
  final SharedPreferencesAsync _prefs;
  final DateTime Function() _now;
  final AppVersion installed;
  final bool supported;

  bool _enabled = true;
  bool _loaded = false;
  DateTime? _lastCheck;
  String? _dismissed;
  UpdateStatus _status = UpdateStatus.unknown;
  ReleaseInfo? _available;
  Future<UpdateStatus>? _running;

  /// The automatic daily check (default on).
  bool get enabled => _enabled;
  bool get loaded => _loaded;
  UpdateStatus get status => _status;
  DateTime? get lastCheck => _lastCheck;

  /// The newer release, when the last check found one.
  ReleaseInfo? get available => _available;

  Future<void> load() async {
    try {
      _enabled = await _prefs.getBool(enabledKey) ?? true;
      final last = await _prefs.getInt(lastCheckKey);
      _lastCheck = last == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(last);
      _dismissed = await _prefs.getString(dismissedKey);
    } catch (_) {}
    _loaded = true;
    notifyListeners();
  }

  Future<void> setEnabled(bool on) async {
    if (_enabled == on) return;
    _enabled = on;
    notifyListeners();
    try {
      await _prefs.setBool(enabledKey, on);
    } catch (_) {}
  }

  /// The start-up check: only when on, supported and a day has passed.
  /// Returns a release worth announcing (newer, and not dismissed with
  /// "Later"), else null.
  Future<ReleaseInfo?> checkIfDue() async {
    if (!supported) return null;
    if (!_loaded) await load();
    if (!_enabled) return null;
    final last = _lastCheck;
    final now = _now();
    if (last != null && now.difference(last) < interval && now.isAfter(last)) {
      return null;
    }
    await checkNow();
    final r = _available;
    return r != null && r.tag != _dismissed ? r : null;
  }

  /// Asks GitHub now. Concurrent calls share one request.
  Future<UpdateStatus> checkNow() => _running ??= _check().whenComplete(() {
    _running = null;
  });

  Future<UpdateStatus> _check() async {
    _status = UpdateStatus.checking;
    notifyListeners();
    final owned = _http == null;
    final client = _http ?? http.Client();
    UpdateStatus result;
    try {
      final res = await client
          .get(
            kLatestReleaseApi,
            headers: const {
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': 'Tove-update-check',
            },
          )
          .timeout(timeout);
      result = _read(res);
      // Any answer from GitHub counts as today's check; an offline phone
      // tries again at the next start.
      _lastCheck = _now();
      try {
        await _prefs.setInt(lastCheckKey, _lastCheck!.millisecondsSinceEpoch);
      } catch (_) {}
    } on TimeoutException {
      result = UpdateStatus.offline;
    } catch (e) {
      // SocketException, ClientException, HandshakeException…
      debugPrint('Update check: $e');
      result = UpdateStatus.offline;
    } finally {
      if (owned) client.close();
    }
    _status = result;
    notifyListeners();
    return result;
  }

  UpdateStatus _read(http.Response res) {
    final remaining = res.headers['x-ratelimit-remaining'];
    if (res.statusCode == 429 ||
        (res.statusCode == 403 && (remaining == '0' || remaining == null))) {
      return UpdateStatus.rateLimited;
    }
    if (res.statusCode == 404) {
      // No published release yet.
      _available = null;
      return UpdateStatus.upToDate;
    }
    if (res.statusCode != 200) return UpdateStatus.failed;
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      final r = j is Map<String, Object?> ? ReleaseInfo.fromJson(j) : null;
      if (r == null) return UpdateStatus.failed;
      _available = r.version.isNewerThan(installed) ? r : null;
      return _available == null
          ? UpdateStatus.upToDate
          : UpdateStatus.available;
    } catch (_) {
      return UpdateStatus.failed;
    }
  }

  /// "Later": the start-up check stays quiet about this release (About
  /// still shows it).
  Future<void> dismiss(ReleaseInfo r) async {
    _dismissed = r.tag;
    try {
      await _prefs.setString(dismissedKey, r.tag);
    } catch (_) {}
  }
}

/// Makes the [UpdateChecker] reachable from Settings › About.
class UpdateScope extends InheritedNotifier<UpdateChecker> {
  const UpdateScope({
    super.key,
    required UpdateChecker checker,
    required super.child,
  }) : super(notifier: checker);

  static UpdateChecker? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UpdateScope>()?.notifier;
}
