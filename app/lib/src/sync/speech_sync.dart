import 'dart:async';

import '../speech/speech_settings.dart';
import 'settings_sync.dart';

/// Syncs the read-aloud and dictation preferences that belong to the person
/// rather than the device:
///
/// - "Read replies aloud" → `read_aloud_auto`
/// - read-aloud speed → `tove.read_aloud_speed`
/// - dictation language → `tove.dictation_language`
///
/// The engines, voices, "on this device only" and the model downloads
/// depend on the device and stay local.
class SpeechSyncSlice implements SyncSlice {
  SpeechSyncSlice(this.settings, this.sync) {
    settings.addListener(_changed);
    _last = settings.value;
  }

  final SpeechSettingsController settings;
  final SettingsSync sync;
  late SpeechSettings _last;
  bool _applying = false;

  /// Adds this slice to [sync] (main, after speech services start).
  static SpeechSyncSlice attach(
    SpeechSettingsController settings,
    SettingsSync sync,
  ) {
    final slice = SpeechSyncSlice(settings, sync);
    sync.register(slice);
    return slice;
  }

  void _changed() {
    if (_applying) return;
    final s = settings.value;
    if (s.autoReadReplies != _last.autoReadReplies) {
      sync.set('read_aloud_auto', s.autoReadReplies);
    }
    if (s.speed != _last.speed) {
      sync.set('tove.read_aloud_speed', s.speed == 1.0 ? null : s.speed);
    }
    if (s.dictationLanguage != _last.dictationLanguage) {
      sync.set('tove.dictation_language', s.dictationLanguage);
    }
    _last = s;
  }

  @override
  Map<String, Object?> syncValues() {
    final s = settings.value;
    return {
      if (s.autoReadReplies) 'read_aloud_auto': true,
      if (s.speed != 1.0) 'tove.read_aloud_speed': s.speed,
      if (s.dictationLanguage != null)
        'tove.dictation_language': s.dictationLanguage,
    };
  }

  @override
  void applySynced(Map<String, Object?> view) {
    final auto = view['read_aloud_auto'] == true;
    final speed = view['tove.read_aloud_speed'];
    final lang = view['tove.dictation_language'];
    final s = settings.value;
    final next = s.copyWith(
      autoReadReplies: auto,
      speed: speed is num ? speed.toDouble() : 1.0,
      dictationLanguage: lang is String ? lang : null,
      clearDictationLanguage: lang is! String,
    );
    if (next == s) return;
    // update() sets the value (and notifies) synchronously, before it
    // saves, so the guard covers the echo.
    _applying = true;
    _last = next;
    try {
      unawaited(settings.update((_) => next));
    } finally {
      _applying = false;
    }
  }

  void dispose() {
    settings.removeListener(_changed);
    sync.unregister(this);
  }
}
