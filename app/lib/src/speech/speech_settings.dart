import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../settings/settings.dart' show PrefsStore;
import 'dictation/dictation_engine.dart';
import 'models/model_catalog.dart';
import 'tts/kokoro_voices.dart';
import 'tts/tts_engine.dart';

/// Settings › Voice. Immutable; change with [SpeechSettingsController.update].
@immutable
class SpeechSettings {
  const SpeechSettings({
    this.dictationEngine = DictationEngineKind.server,
    this.dictationLanguage,
    this.dictationOnDeviceOnly = false,
    this.ttsEngine = TtsEngineKind.kokoro,
    this.kokoroVariant = KokoroVariant.v1_0Fp32,
    this.kokoroVoice = defaultKokoroVoice,
    this.systemVoice,
    this.speed = 1.0,
    this.autoReadReplies = false,
    this.downloadOnWifiOnly = true,
  });

  /// The Tove server by default; it falls back to the system recogniser
  /// when the server can't transcribe (old bridge, no network).
  final DictationEngineKind dictationEngine;

  /// BCP-47 tag; null means automatic ([resolveDictationLanguage]).
  final String? dictationLanguage;

  /// Never use a recogniser that may send audio off the device.
  final bool dictationOnDeviceOnly;

  final TtsEngineKind ttsEngine;
  final KokoroVariant kokoroVariant;

  /// Kokoro voice id, e.g. `af_heart`.
  final String kokoroVoice;

  /// Platform voice name; null picks the most natural one automatically.
  final String? systemVoice;

  /// Read-aloud speed, 0.8×–1.5× in the UI (spec §5.4).
  final double speed;

  /// "Read replies aloud": read each new reply when it finishes (text mode).
  final bool autoReadReplies;
  final bool downloadOnWifiOnly;

  static const minSpeed = 0.8;
  static const maxSpeed = 1.5;

  /// The model to download for the selected TTS settings.
  SpeechModel get kokoroModel => kokoroVariant.model;

  SpeechSettings copyWith({
    DictationEngineKind? dictationEngine,
    String? dictationLanguage,
    bool clearDictationLanguage = false,
    bool? dictationOnDeviceOnly,
    TtsEngineKind? ttsEngine,
    KokoroVariant? kokoroVariant,
    String? kokoroVoice,
    String? systemVoice,
    bool clearSystemVoice = false,
    double? speed,
    bool? autoReadReplies,
    bool? downloadOnWifiOnly,
  }) => SpeechSettings(
    dictationEngine: dictationEngine ?? this.dictationEngine,
    dictationLanguage: clearDictationLanguage
        ? null
        : (dictationLanguage ?? this.dictationLanguage),
    dictationOnDeviceOnly: dictationOnDeviceOnly ?? this.dictationOnDeviceOnly,
    ttsEngine: ttsEngine ?? this.ttsEngine,
    kokoroVariant: kokoroVariant ?? this.kokoroVariant,
    kokoroVoice: kokoroVoice ?? this.kokoroVoice,
    systemVoice: clearSystemVoice ? null : (systemVoice ?? this.systemVoice),
    speed: (speed ?? this.speed).clamp(minSpeed, maxSpeed).toDouble(),
    autoReadReplies: autoReadReplies ?? this.autoReadReplies,
    downloadOnWifiOnly: downloadOnWifiOnly ?? this.downloadOnWifiOnly,
  );

  /// 2: the server engine exists. Version 1 saved `system` as the only
  /// default, so it is read as "not chosen" and becomes the new default.
  static const schema = 2;

  Map<String, Object?> toJson() => {
    'schema': schema,
    'dictationEngine': dictationEngine.name,
    'dictationLanguage': dictationLanguage,
    'dictationOnDeviceOnly': dictationOnDeviceOnly,
    'ttsEngine': ttsEngine.name,
    'kokoroVariant': kokoroVariant.name,
    'kokoroVoice': kokoroVoice,
    'systemVoice': systemVoice,
    'speed': speed,
    'autoReadReplies': autoReadReplies,
    'downloadOnWifiOnly': downloadOnWifiOnly,
  };

  /// Unknown or missing values fall back to defaults.
  factory SpeechSettings.fromJson(Map<String, Object?> j) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.where((v) => v.name == name).firstOrNull ?? fallback;
    const d = SpeechSettings();
    final old = ((j['schema'] as num?)?.toInt() ?? 1) < 2;
    return SpeechSettings(
      dictationEngine: old && j['dictationEngine'] == 'system'
          ? d.dictationEngine
          : pick(DictationEngineKind.values, j['dictationEngine'], d.dictationEngine),
      dictationLanguage: j['dictationLanguage'] as String?,
      dictationOnDeviceOnly:
          j['dictationOnDeviceOnly'] as bool? ?? d.dictationOnDeviceOnly,
      ttsEngine: pick(TtsEngineKind.values, j['ttsEngine'], d.ttsEngine),
      kokoroVariant: pick(
        KokoroVariant.values,
        j['kokoroVariant'],
        d.kokoroVariant,
      ),
      kokoroVoice: j['kokoroVoice'] as String? ?? d.kokoroVoice,
      systemVoice: j['systemVoice'] as String?,
      speed: ((j['speed'] as num?)?.toDouble() ?? d.speed)
          .clamp(minSpeed, maxSpeed)
          .toDouble(),
      autoReadReplies: j['autoReadReplies'] as bool? ?? d.autoReadReplies,
      downloadOnWifiOnly:
          j['downloadOnWifiOnly'] as bool? ?? d.downloadOnWifiOnly,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SpeechSettings &&
      const MapEquality().equals(other.toJson(), toJson());

  @override
  int get hashCode => Object.hashAll(toJson().values);
}

/// The language dictation asks for: the chosen [tag], else the device's.
///
/// English on a phone set to India's time zone (UTC+5:30) becomes English
/// (India): many Indian phones are set to English (US), and en-US models
/// mishear Indian names, places and accents. Recognisers still understand
/// American English under en-IN.
String resolveDictationLanguage(
  String? tag, {
  required String deviceLanguage,
  String? deviceCountry,
  required Duration utcOffset,
}) {
  if (tag != null && tag.isNotEmpty) return tag;
  final lang = deviceLanguage.toLowerCase();
  final country = deviceCountry?.toUpperCase();
  if (lang == 'en' &&
      (country == 'IN' || utcOffset == const Duration(hours: 5, minutes: 30))) {
    return 'en-IN';
  }
  if (lang.isEmpty) return 'en-US';
  return country == null || country.isEmpty ? lang : '$lang-$country';
}

/// Minimal map equality (avoids a `collection` dependency).
class MapEquality {
  const MapEquality();
  bool equals(Map<String, Object?> a, Map<String, Object?> b) =>
      a.length == b.length && a.keys.every((k) => b.containsKey(k) && a[k] == b[k]);
}

/// Loads and saves [SpeechSettings] under one preferences key.
class SpeechSettingsController extends ValueNotifier<SpeechSettings> {
  SpeechSettingsController(this._prefs) : super(const SpeechSettings());

  static const prefsKey = 'speech.settings.v1';
  final PrefsStore _prefs;

  Future<void> load() async {
    final raw = await _prefs.get(prefsKey);
    if (raw == null) return;
    try {
      value = SpeechSettings.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
    } catch (_) {
      // Corrupt or old format: keep defaults.
    }
  }

  Future<void> update(SpeechSettings Function(SpeechSettings s) change) async {
    final next = change(value);
    if (next == value) return;
    value = next;
    await _prefs.set(prefsKey, jsonEncode(next.toJson()));
  }
}
