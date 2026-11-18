import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../settings/prefs_store.dart';
import 'settings_api.dart';

export 'settings_api.dart';

/// Where the synced settings stand, for the subtle status in Settings.
enum SyncState {
  /// No server sync: an old bridge, no connection set up, or signed out.
  /// Every preference is kept on this device only.
  localOnly,

  /// Asking the server for the first time since the app started.
  connecting,

  /// This device matches the server.
  synced,

  /// A change is waiting for the debounce or is being saved.
  saving,

  /// The server could not be reached; changes are kept and sent later.
  offline,

  /// The server refused the settings (too large, wrong key).
  error,
}

/// A part of the app whose preferences are synced (the settings controller,
/// read-aloud preferences).
///
/// Values are JSON. A path is a top-level settings key (`theme`,
/// `tove.accent`) or, one level down, `parent/child`
/// (`personalization/nickname`).
abstract interface class SyncSlice {
  /// The local values, for the first upload to an empty server. Leave out
  /// values that are at their defaults.
  Map<String, Object?> syncValues();

  /// The merged view (server state plus this device's unsent changes) has
  /// changed: adopt it. A missing key means "default". Must not call
  /// [SettingsSync.set].
  void applySynced(Map<String, Object?> view);
}

/// Syncs preferences through `GET`/`PUT /api/settings` (bridge API
/// "Settings").
///
/// - **Instant start:** the last server copy and the unsent changes are
///   cached in [PrefsStore], and slices keep their own local copies, so the
///   app starts with the last known settings before the server answers.
/// - **Debounced writes:** [set] records a change and saves after
///   [debounce]; a burst of changes is one `PUT`.
/// - **Optimistic concurrency:** each `PUT` carries the version it was based
///   on. On `409` the server's current state replaces the base, this
///   device's unsent changes are laid over it (they win for the keys they
///   touch; everything else comes from the other device), and the `PUT` is
///   sent again.
/// - **Offline queue:** unsent changes survive restarts and are sent, with
///   backoff, once the server answers again.
/// - **Old bridges:** without `settings_sync` nothing is sent; the slices
///   keep working on local preferences ([SyncState.localOnly]).
class SettingsSync extends ChangeNotifier {
  SettingsSync({
    required this.store,
    this.debounce = const Duration(milliseconds: 800),
    this.retryDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 30),
      Duration(seconds: 60),
    ],
    this.watchLifecycle = false,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const cacheKey = 'sync.settings.v1';

  /// Where the server copy and unsent changes are cached.
  final PrefsStore store;
  final Duration debounce;
  final List<Duration> retryDelays;

  /// Re-reads the server copy whenever the app comes back to the
  /// foreground (production only).
  final bool watchLifecycle;
  final DateTime Function() _clock;

  final _slices = <SyncSlice>[];
  SettingsApi? _api;
  String? _server;
  int _generation = 0;

  RemoteSettings _base = RemoteSettings.empty;
  final Map<String, Object?> _pending = {};
  bool _cacheLoaded = false;
  bool _cachedSupport = false;

  SettingsSupport _support = SettingsSupport.none;
  SyncState _state = SyncState.localOnly;
  DateTime? _lastSynced;
  String? _problem;

  Timer? _debounceTimer;
  Timer? _retryTimer;
  int _retries = 0;
  Future<void>? _inflight;
  bool _again = false;
  bool _applying = false;
  AppLifecycleListener? _lifecycle;

  SyncState get state => _state;

  /// The server takes synced settings (or did the last time it answered).
  bool get enabled => _support.supported || (_api != null && _cachedSupport);
  SettingsSupport get support => _support;
  DateTime? get lastSynced => _lastSynced;
  String? get problem => _problem;

  /// The server's version of the settings this device last saw.
  int get version => _base.version;

  /// Paths changed on this device and not saved yet.
  Set<String> get pendingPaths => Set.unmodifiable(_pending.keys);

  /// The server state with this device's unsent changes on top.
  Map<String, Object?> get view => _compose(_base.settings, _pending);

  /// Adds a slice and gives it the current view when one is known.
  void register(SyncSlice slice) {
    if (_slices.contains(slice)) return;
    _slices.add(slice);
    if (_api != null && (_base.version > 0 || _pending.isNotEmpty)) {
      _applyTo([slice]);
    }
  }

  void unregister(SyncSlice slice) => _slices.remove(slice);

  /// Starts syncing with [api] for the bridge at [server]; null stops
  /// syncing (signed out, or local only). Changing [server] drops the old
  /// server's cache.
  Future<void> connect(SettingsApi? api, {String? server}) async {
    final gen = ++_generation;
    _debounceTimer?.cancel();
    _retryTimer?.cancel();
    _api?.close();
    _api = api;
    _retries = 0;
    await _loadCache();
    if (gen != _generation) return;
    if (api == null) {
      _server = server;
      _support = SettingsSupport.none;
      _setState(SyncState.localOnly);
      return;
    }
    if (server != _server) {
      if (_server != null) {
        _base = RemoteSettings.empty;
        _pending.clear();
        _cachedSupport = false;
      }
      _server = server;
      await _saveCache();
    }
    if (watchLifecycle) {
      _lifecycle ??= AppLifecycleListener(onResume: () => unawaited(refresh()));
    }
    // The cached copy first, so the app starts with the last known values.
    if (_cachedSupport && (_base.version > 0 || _pending.isNotEmpty)) {
      _applyTo(_slices);
    }
    _setState(SyncState.connecting);
    await _start(gen);
  }

  Future<void> _start(int gen) async {
    final api = _api;
    if (api == null) return;
    try {
      _support = await api.support();
    } on SettingsApiException catch (e) {
      if (gen != _generation) return;
      _fail(e);
      return;
    }
    if (gen != _generation) return;
    _cachedSupport = _support.supported;
    if (!_support.supported) {
      _pending.clear();
      await _saveCache();
      _setState(SyncState.localOnly);
      return;
    }
    await _pull(gen, seed: true);
  }

  /// Reads the server copy again (app resumed, Settings opened).
  Future<void> refresh() async {
    final api = _api;
    if (api == null) return;
    if (!_support.supported) {
      // Not reached yet, or an old bridge that may have been updated.
      if (_state == SyncState.offline || _state == SyncState.connecting) {
        await _start(_generation);
      }
      return;
    }
    if (_inflight != null) return;
    await _pull(_generation, seed: false);
  }

  Future<void> _pull(int gen, {required bool seed}) async {
    final api = _api;
    if (api == null) return;
    RemoteSettings? got;
    try {
      got = await api.fetch(
        etag: !seed && _base.version > 0 ? '"s${_base.version}"' : null,
      );
    } on SettingsApiException catch (e) {
      if (gen != _generation) return;
      _fail(e);
      return;
    }
    if (gen != _generation) return;
    if (got != null) {
      if (seed && got.version == 0) {
        // An empty server: this device's settings become everyone's.
        for (final slice in _slices) {
          for (final e in _flatten(slice.syncValues()).entries) {
            _pending.putIfAbsent(e.key, () => e.value);
          }
        }
      }
      _base = got;
      await _saveCache();
      _applyTo(_slices);
    }
    _retries = 0;
    _problem = null;
    _lastSynced = _clock();
    if (_pending.isEmpty) {
      _setState(SyncState.synced);
    } else {
      await flush();
    }
  }

  /// Records a change made on this device and saves it after [debounce].
  /// [value] null removes the key.
  void set(String path, Object? value) {
    if (_applying) return;
    final current = _lookup(view, path);
    if (_jsonEquals(current, value) && !_pending.containsKey(path)) return;
    _pending[path] = value;
    unawaited(_saveCache());
    if (_api == null || !enabled) return;
    if (_state != SyncState.offline) _setState(SyncState.saving);
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => unawaited(flush()));
  }

  /// Sends the unsent changes now.
  Future<void> flush() async {
    _debounceTimer?.cancel();
    if (_api == null || !_support.supported || _pending.isEmpty) return;
    if (_inflight != null) {
      _again = true;
      return _inflight;
    }
    final run = _push(_generation);
    _inflight = run;
    try {
      await run;
    } finally {
      _inflight = null;
    }
    if (_again) {
      _again = false;
      if (_pending.isNotEmpty && _state != SyncState.offline) await flush();
    }
  }

  Future<void> _push(int gen) async {
    var conflicts = 0;
    while (true) {
      final api = _api;
      if (api == null || gen != _generation || _pending.isEmpty) return;
      final sent = Map<String, Object?>.of(_pending);
      final body = _compose(_base.settings, sent);
      if (utf8.encode(jsonEncode(body)).length > _support.maxBytes) {
        _problem = 'Your settings are larger than the server allows.';
        _setState(SyncState.error);
        return;
      }
      _setState(SyncState.saving);
      try {
        final saved = await api.put(_base.version, body);
        if (gen != _generation) return;
        _base = saved;
        for (final e in sent.entries) {
          if (_pending.containsKey(e.key) &&
              _jsonEquals(_pending[e.key], e.value)) {
            _pending.remove(e.key);
          }
        }
        await _saveCache();
        _retries = 0;
        _problem = null;
        _lastSynced = _clock();
        _applyTo(_slices);
        if (_pending.isEmpty) {
          _setState(SyncState.synced);
          return;
        }
        // Changed again while saving: loop and send that too.
      } on SettingsApiException catch (e) {
        if (gen != _generation) return;
        switch (e.kind) {
          case SettingsErrorKind.conflict:
            // Another device saved first: take its state, keep ours on top.
            var current = e.current;
            if (current == null) {
              try {
                current = await api.fetch();
              } on SettingsApiException catch (e2) {
                _fail(e2);
                return;
              }
            }
            if (gen != _generation) return;
            _base = current ?? _base;
            await _saveCache();
            _applyTo(_slices);
            if (++conflicts > 3) {
              _problem = 'Settings keep changing on another device.';
              _scheduleRetry();
              _setState(SyncState.offline);
              return;
            }
          case SettingsErrorKind.rejected:
            // Drop what the server refused (an older server or a bad value)
            // so the rest still syncs.
            final key = e.key;
            final before = _pending.length;
            if (key != null) {
              final path = key.replaceFirst('.', '/');
              _pending.removeWhere(
                (p, _) =>
                    p == key ||
                    p == path ||
                    p.startsWith('$key/') ||
                    (!key.contains('.') && p.split('/').first == key),
              );
            }
            if (_pending.length == before) {
              _pending.clear();
            }
            await _saveCache();
            _applyTo(_slices);
          default:
            _fail(e);
            return;
        }
      }
    }
  }

  void _fail(SettingsApiException e) {
    switch (e.kind) {
      case SettingsErrorKind.offline:
      case SettingsErrorKind.other:
        _problem = null;
        _setState(SyncState.offline);
        _scheduleRetry();
      case SettingsErrorKind.unsupported:
        _support = SettingsSupport.none;
        _cachedSupport = false;
        _setState(SyncState.localOnly);
      case SettingsErrorKind.unauthorized:
        _problem = 'The server did not accept the access key.';
        _setState(SyncState.error);
      case SettingsErrorKind.tooLarge:
        _problem = 'Your settings are larger than the server allows.';
        _setState(SyncState.error);
      case SettingsErrorKind.conflict:
      case SettingsErrorKind.rejected:
        _setState(SyncState.error);
    }
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    if (_api == null || retryDelays.isEmpty) return;
    final delay = retryDelays[_retries.clamp(0, retryDelays.length - 1)];
    _retries++;
    final gen = _generation;
    _retryTimer = Timer(delay, () {
      if (gen != _generation) return;
      if (!_support.supported) {
        unawaited(_start(gen));
      } else if (_pending.isNotEmpty) {
        unawaited(flush());
      } else {
        unawaited(_pull(gen, seed: false));
      }
    });
  }

  void _applyTo(List<SyncSlice> slices) {
    final v = view;
    _applying = true;
    try {
      for (final s in slices) {
        s.applySynced(v);
      }
    } finally {
      _applying = false;
    }
  }

  void _setState(SyncState s) {
    if (s == _state) {
      notifyListeners();
      return;
    }
    _state = s;
    notifyListeners();
  }

  // --- cache ---------------------------------------------------------------

  Future<void> _loadCache() async {
    if (_cacheLoaded) return;
    _cacheLoaded = true;
    try {
      final raw = await store.get(cacheKey);
      if (raw == null) return;
      final j = jsonDecode(raw);
      if (j is! Map<String, dynamic>) return;
      _server = j['server'] as String?;
      _cachedSupport = j['supported'] == true;
      if (j['base'] is Map<String, dynamic>) {
        _base = RemoteSettings.fromJson(j['base'] as Map<String, dynamic>);
      }
      if (j['pending'] is Map<String, dynamic>) {
        _pending.addAll(j['pending'] as Map<String, dynamic>);
      }
    } catch (_) {
      // A damaged cache only costs the instant start.
    }
  }

  Future<void> _saveCache() async {
    try {
      await store.set(
        cacheKey,
        jsonEncode({
          'server': _server,
          'supported': _cachedSupport,
          'base': _base.toJson(),
          'pending': _pending,
        }),
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _generation++;
    _debounceTimer?.cancel();
    _retryTimer?.cancel();
    _lifecycle?.dispose();
    _api?.close();
    super.dispose();
  }

  // --- JSON helpers --------------------------------------------------------

  /// [base] with [changes] laid over it. Nulls remove a key, and an object
  /// left empty is removed, so the body never carries nulls.
  static Map<String, Object?> _compose(
    Map<String, Object?> base,
    Map<String, Object?> changes,
  ) {
    final out = <String, Object?>{
      for (final e in base.entries)
        e.key: e.value is Map
            ? Map<String, Object?>.from(e.value as Map)
            : e.value,
    };
    for (final e in changes.entries) {
      final parts = e.key.split('/');
      if (parts.length == 1) {
        if (e.value == null) {
          out.remove(e.key);
        } else {
          out[e.key] = e.value;
        }
        continue;
      }
      final parent = out[parts[0]];
      final child = parent is Map
          ? Map<String, Object?>.from(parent)
          : <String, Object?>{};
      if (e.value == null) {
        child.remove(parts[1]);
      } else {
        child[parts[1]] = e.value;
      }
      if (child.isEmpty) {
        out.remove(parts[0]);
      } else {
        out[parts[0]] = child;
      }
    }
    return out;
  }

  static Map<String, Object?> _flatten(Map<String, Object?> values) {
    final out = <String, Object?>{};
    for (final e in values.entries) {
      final v = e.value;
      if (v is Map) {
        for (final c in v.entries) {
          if (c.value != null) out['${e.key}/${c.key}'] = c.value;
        }
      } else if (v != null) {
        out[e.key] = v;
      }
    }
    return out;
  }

  static Object? _lookup(Map<String, Object?> m, String path) {
    final parts = path.split('/');
    if (parts.length == 1) return m[path];
    final parent = m[parts[0]];
    return parent is Map ? parent[parts[1]] : null;
  }

  static bool _jsonEquals(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every((k) => b.containsKey(k) && _jsonEquals(a[k], b[k]));
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_jsonEquals(a[i], b[i])) return false;
      }
      return true;
    }
    if (a is num && b is num) return a == b;
    return a == b;
  }
}

/// Reads one value of a synced view (`parent/child` paths reach one level
/// into an object).
Object? syncedValue(Map<String, Object?> view, String path) =>
    SettingsSync._lookup(view, path);
