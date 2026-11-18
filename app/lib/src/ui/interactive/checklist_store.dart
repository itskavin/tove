import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../settings/prefs_store.dart';
import '../../sync/settings_sync.dart';

/// Which checklist items the user ticked, per message and block, so a plan
/// keeps its ticks when the chat is reopened or opened on another device.
///
/// - Always saved on this device ([PrefsStore], key [prefsKey]).
/// - Also synced through the bridge's settings object when it supports it
///   (`GET`/`PUT /api/settings`, namespaced key [syncKey]). The bridge stores
///   any JSON under a namespaced key; nothing reaches Hermes.
///
/// A list key is `<message id>#<block id or ordinal>`; its value is the set
/// of ticked item keys ("0.2" = section 0, item 2) and when it changed.
/// Only the [maxLists] most recently changed lists are kept, so the synced
/// object stays small (about 60 bytes per list).
class ChecklistStore extends ChangeNotifier implements SyncSlice {
  ChecklistStore({required this.prefs, this.sync, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    sync?.register(this);
    unawaited(_load());
  }

  static const prefsKey = 'checklists.v1';
  static const syncKey = 'tove.checklists';
  static const maxLists = 40;

  final PrefsStore prefs;
  final SettingsSync? sync;
  final DateTime Function() _clock;

  /// key → (ticked items, changed at ms).
  final Map<String, ({Set<String> done, int at})> _lists = {};
  bool _loaded = false;
  bool get loaded => _loaded;

  /// The ticked items of [list], or null when the user never touched it
  /// (the block's own `done` flags apply).
  Set<String>? doneFor(String list) => _lists[list]?.done;

  void setDone(String list, Set<String> done) {
    _lists[list] = (done: Set.of(done), at: _clock().millisecondsSinceEpoch);
    _trim();
    notifyListeners();
    unawaited(_save());
    sync?.set(syncKey, _encode());
  }

  void _trim() {
    if (_lists.length <= maxLists) return;
    final keys = _lists.keys.toList()
      ..sort((a, b) => _lists[b]!.at.compareTo(_lists[a]!.at));
    for (final k in keys.skip(maxLists)) {
      _lists.remove(k);
    }
  }

  Map<String, Object?> _encode() => {
    for (final e in _lists.entries)
      e.key: {'d': e.value.done.toList()..sort(), 't': e.value.at},
  };

  /// Merges [json] (the stored or synced shape): the newer change of each
  /// list wins. Returns whether anything changed.
  bool _merge(Object? json) {
    if (json is! Map) return false;
    var changed = false;
    for (final e in json.entries) {
      final v = e.value;
      if (e.key is! String || v is! Map) continue;
      final d = v['d'], t = v['t'];
      if (d is! List || t is! num) continue;
      final mine = _lists[e.key];
      if (mine != null && mine.at >= t) continue;
      _lists[e.key as String] = (
        done: {
          for (final x in d)
            if (x is String && x.length <= 8) x,
        },
        at: t.toInt(),
      );
      changed = true;
    }
    if (changed) _trim();
    return changed;
  }

  Future<void> _load() async {
    try {
      final raw = await prefs.get(prefsKey);
      if (raw != null) _merge(jsonDecode(raw));
    } catch (_) {
      // A broken local copy only loses ticks.
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      await prefs.set(prefsKey, jsonEncode(_encode()));
    } catch (_) {}
  }

  @override
  Map<String, Object?> syncValues() =>
      _lists.isEmpty ? const {} : {syncKey: _encode()};

  @override
  void applySynced(Map<String, Object?> view) {
    if (_merge(view[syncKey])) {
      notifyListeners();
      unawaited(_save());
    }
  }

  @override
  void dispose() {
    sync?.unregister(this);
    super.dispose();
  }
}

/// Provides a [ChecklistStore] to checklist blocks below it.
class ChecklistScope extends InheritedNotifier<ChecklistStore> {
  const ChecklistScope({
    super.key,
    required ChecklistStore store,
    required super.child,
  }) : super(notifier: store);

  static ChecklistStore? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChecklistScope>()?.notifier;
}

/// The position of a hermes-ui block among its message's blocks, for state
/// keys of blocks without an `id`.
class UiBlockOrdinal extends InheritedWidget {
  const UiBlockOrdinal({
    super.key,
    required this.ordinal,
    required super.child,
  });

  final int ordinal;

  static int of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiBlockOrdinal>()?.ordinal ??
      0;

  @override
  bool updateShouldNotify(UiBlockOrdinal old) => old.ordinal != ordinal;
}
