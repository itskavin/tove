import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import '../settings/settings.dart' show PrefsStore;
import 'dictation/dictation_engine.dart';
import 'dictation/moonshine_dictation_engine.dart';
import 'dictation/server_dictation_engine.dart';
import 'dictation/system_dictation_engine.dart';
import 'dictation_controller.dart';
import 'licenses.dart';
import 'models/model_catalog.dart';
import 'models/model_manager.dart';
import 'speech_platform.dart';
import 'speech_settings.dart';
import 'tts/kokoro_engine.dart';
import 'tts/kokoro_voices.dart';
import 'tts/system_tts_engine.dart';
import 'tts/tts_engine.dart';
import 'tts_controller.dart';

/// Everything speech, wired together. Create once at start-up:
///
/// ```dart
/// final speech = await SpeechServices.create(prefs: SharedPrefsStore());
/// // composer:   speech.dictation (mic button)
/// // thread:     speech.tts.toggle(markdown, messageId: id)
/// // player:     ValueListenableBuilder(valueListenable: speech.tts, …)
/// // settings:   speech.settings, speech.models, speech.voices()
/// // live call:  speech.liveModeActive = callIsLive;
/// ```
class SpeechServices {
  SpeechServices._({
    required this.platform,
    required this.settings,
    required this.models,
    required this.tts,
    required this.dictation,
    required this.kokoro,
    required this.systemTts,
    required this.systemDictation,
    required this.moonshine,
    required this.serverDictation,
    required this.transcriber,
  });

  final SpeechPlatform platform;
  final SpeechSettingsController settings;
  final ModelManager models;
  final TtsController tts;
  final DictationController dictation;
  final KokoroEngine kokoro;
  final SystemTtsEngine systemTts;
  final SystemDictationEngine systemDictation;
  final MoonshineDictationEngine moonshine;
  final ServerDictationEngine serverDictation;

  /// The Tove server's transcription, or null when the app has none.
  final ServerTranscriber? transcriber;

  /// [transcriber]: dictation on the Tove server (`BridgeTranscriber`).
  /// [deviceLocale]/[utcOffset] are for tests.
  static Future<SpeechServices> create({
    required PrefsStore prefs,
    SpeechPlatform? platform,
    ModelManager? models,
    ServerTranscriber? transcriber,
    (String, String?) Function()? deviceLocale,
    Duration Function()? utcOffset,
  }) async {
    registerSpeechLicenses();
    final p = platform ?? defaultSpeechPlatform();
    final settings = SpeechSettingsController(prefs);
    await settings.load();
    final m = models ?? ModelManager(platform: p);
    await m.refresh();

    final kokoro = KokoroEngine(
      platform: p,
      files: () async {
        final variant = settings.value.kokoroVariant;
        final dir = await m.installedDir(variant.modelId);
        return dir == null ? null : KokoroModelFiles(dir.path, variant);
      },
    );
    final systemTts = SystemTtsEngine(
      online: () async => (await p.networkInfo()).connected,
    );

    Future<TtsSelection> select() async {
      final s = settings.value;
      TtsVoice? systemVoice;
      if (s.systemVoice != null) {
        List<TtsVoice> all;
        try {
          all = await systemTts.voices();
        } catch (_) {
          all = const [];
        }
        systemVoice = all.where((v) => v.id == s.systemVoice).firstOrNull;
      }
      if (s.ttsEngine == TtsEngineKind.kokoro && p.isSupported) {
        if (m.isInstalled(s.kokoroVariant.modelId)) {
          final voices = kokoroVoices(v1_1: s.kokoroVariant.isV1_1);
          return TtsSelection(
            kokoro,
            voice: voices.where((v) => v.id == s.kokoroVoice).firstOrNull,
            fallback: systemTts,
          );
        }
        return TtsSelection(
          systemTts,
          voice: systemVoice,
          fallbackReason:
              'Natural voices are not downloaded. Using the system voice.',
        );
      }
      return TtsSelection(systemTts, voice: systemVoice);
    }

    final tts = TtsController(
      platform: p,
      select: select,
      speed: settings.value.speed,
      autoReadReplies: settings.value.autoReadReplies,
    );

    final systemDictation = SystemDictationEngine(p);
    final moonshine = MoonshineDictationEngine(
      platform: p,
      modelDir: () async =>
          (await m.installedDir(SpeechModels.moonshineTinyEn.id))?.path,
    );
    final serverDictation = ServerDictationEngine(
      platform: p,
      transcriber: () => transcriber,
      // Unstable text while a phrase is spoken, when Moonshine is here.
      preview: () async {
        final dir = await m.installedDir(SpeechModels.moonshineTinyEn.id);
        return dir == null ? null : MoonshineIsolate.spawn(dir.path);
      },
    );
    final locale =
        deviceLocale ??
        () {
          final l = PlatformDispatcher.instance.locale;
          return (l.languageCode, l.countryCode);
        };
    final offset = utcOffset ?? () => DateTime.now().timeZoneOffset;
    final dictation = DictationController(
      platform: p,
      engines: () => switch (settings.value.dictationEngine) {
        DictationEngineKind.server => [
          serverDictation,
          systemDictation,
          moonshine,
        ],
        DictationEngineKind.moonshine => [moonshine, systemDictation],
        DictationEngineKind.system => [systemDictation, moonshine],
      },
      language: () {
        final (lang, country) = locale();
        return resolveDictationLanguage(
          settings.value.dictationLanguage,
          deviceLanguage: lang,
          deviceCountry: country,
          utcOffset: offset(),
        );
      },
      onDeviceOnly: () => settings.value.dictationOnDeviceOnly,
      beforeListening: tts.stop,
    );

    // Keep the controllers in step with settings.
    settings.addListener(() {
      final s = settings.value;
      tts.autoReadReplies = s.autoReadReplies;
      if ((tts.value.speed - s.speed).abs() > 0.001) {
        unawaited(tts.setSpeed(s.speed));
      }
    });

    return SpeechServices._(
      platform: p,
      settings: settings,
      models: m,
      tts: tts,
      dictation: dictation,
      kokoro: kokoro,
      systemTts: systemTts,
      systemDictation: systemDictation,
      moonshine: moonshine,
      serverDictation: serverDictation,
      transcriber: transcriber,
    );
  }

  /// Asks the server once whether it transcribes, so the first press of the
  /// mic does not wait for it.
  void warmUp() => unawaited(dictation.warmUp());

  /// Wire to the live voice call. Live mode stops and blocks read-aloud and
  /// dictation, which would fight it for the microphone and speaker.
  set liveModeActive(bool on) {
    tts.liveModeActive = on;
    dictation.liveModeActive = on;
  }

  /// Voices for the settings picker. Kokoro lists English voices first.
  Future<List<TtsVoice>> voices({TtsEngineKind? engine}) async {
    final s = settings.value;
    switch (engine ?? s.ttsEngine) {
      case TtsEngineKind.kokoro:
        final all = kokoroVoices(v1_1: s.kokoroVariant.isV1_1);
        return [
          ...all.where((v) => v.isEnglish),
          ...all.where((v) => !v.isEnglish),
        ];
      case TtsEngineKind.system:
        try {
          return await systemTts.voices();
        } catch (_) {
          return const [];
        }
    }
  }

  /// Downloads the Kokoro model the current settings use.
  Future<void> downloadKokoro() => models.download(
    settings.value.kokoroVariant.modelId,
    wifiOnly: settings.value.downloadOnWifiOnly,
  );

  Future<void> downloadMoonshine() => models.download(
    SpeechModels.moonshineTinyEn.id,
    wifiOnly: settings.value.downloadOnWifiOnly,
  );

  /// Frees loaded models, e.g. when the app goes to the background.
  Future<void> trimMemory() async {
    await tts.releaseEngines();
    if (!dictation.value.isActive) {
      await moonshine.release();
      await serverDictation.release();
    }
  }

  Future<void> dispose() async {
    tts.dispose();
    dictation.dispose();
    await kokoro.release();
    await systemDictation.dispose();
    await moonshine.dispose();
    await serverDictation.dispose();
    models.dispose();
    settings.dispose();
  }
}
