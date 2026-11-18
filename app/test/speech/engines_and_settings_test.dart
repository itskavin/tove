import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/speech/speech.dart';
import 'package:tove_chat/src/speech/tts/kokoro_engine.dart';
import 'package:tove_chat/src/speech/tts/system_tts_engine.dart';

import 'speech_fakes.dart';

class _FakeSynth implements KokoroSynth {
  final calls = <(String, int, double, bool)>[];
  @override
  int get sampleRate => 24000;
  @override
  Future<KokoroAudio> synth(
    String text, {
    required int sid,
    required double speed,
    required bool british,
  }) async {
    calls.add((text, sid, speed, british));
    return KokoroAudio(
      pcm16: Uint8List(48000), // 1 s
      sampleRate: 24000,
      synthTime: const Duration(milliseconds: 400),
    );
  }

  @override
  Future<void> close() async {}
}

class _MemPrefs implements PrefsStore {
  final map = <String, String>{};
  @override
  Future<String?> get(String name) async => map[name];
  @override
  Future<void> set(String name, String value) async => map[name] = value;
}

class _FakePlatformTts implements PlatformTts {
  final spoken = <String>[];
  final voicesSet = <String>[];
  late void Function() done;
  late void Function() cancel;
  List<Map<String, String>> list = const [];

  @override
  Future<List<Map<String, String>>> voices() async => list;
  @override
  Future<void> setVoice(Map<String, String> voice) async => voicesSet.add(voice['name']!);
  @override
  Future<void> setRate(double rate) async {}
  @override
  Future<void> speak(String text) async => spoken.add(text);
  @override
  Future<void> stop() async => cancel();
  @override
  void setHandlers({
    required void Function() onDone,
    required void Function() onCancel,
    required void Function(String) onError,
  }) {
    done = onDone;
    cancel = onCancel;
  }
}

void main() {
  group('KokoroEngine', () {
    test('missing model is a clear error', () async {
      final e = KokoroEngine(platform: FakeSpeechPlatform(), files: () async => null);
      await expectLater(e.prepare(), throwsA(isA<TtsException>()));
    });

    test('synthesises with the voice sid and plays through the PCM sink', () async {
      final platform = FakeSpeechPlatform();
      final synth = _FakeSynth();
      final e = KokoroEngine(
        platform: platform,
        files: () async => const KokoroModelFiles('/m', KokoroVariant.v1_0Fp32),
        spawn: (_, _) async => synth,
      );
      final voices = await e.voices();
      expect(voices, hasLength(54));
      final emma = voices.firstWhere((v) => v.id == 'bf_emma');
      final u = await e.synthesize('Hello.', voice: emma, speed: 1.2);
      expect(synth.calls.single, ('Hello.', 21, 1.2, true));
      expect(u.rtf, closeTo(0.4, 1e-9));
      expect(u.audioDuration, const Duration(seconds: 1));

      final heard = e.play(u);
      await pump();
      expect(platform.calls, containsAllInOrder(['pcmOpen:24000', 'pcmWrite:1']));
      platform.push(const PcmDoneEvent(1));
      expect(await heard, isTrue);

      final dropped = e.play(u);
      await pump();
      await e.stop();
      expect(await dropped, isFalse);
      expect(platform.calls.last, 'pcmStop');
    });

    test('default voice is af_heart', () async {
      final e = KokoroEngine(platform: FakeSpeechPlatform(), files: () async => null);
      expect((await e.defaultVoice())!.id, 'af_heart');
      expect((await e.defaultVoice())!.speakerId, 3);
    });
  });

  group('Kokoro voices', () {
    test('v1.0 and v1.1 tables', () {
      expect(kokoroVoices(v1_1: false).where((v) => v.isEnglish), hasLength(28));
      final v11 = kokoroVoices(v1_1: true);
      expect(v11, hasLength(103));
      expect(v11.where((v) => v.isEnglish).map((v) => v.id), ['af_maple', 'af_sol', 'bf_vale']);
      expect(v11[58].id, 'zm_009');
      expect(v11[58].name, 'Male 009');
      final siwis = kokoroVoices(v1_1: false).firstWhere((v) => v.id == 'ff_siwis');
      expect(siwis.attribution, contains('CC BY'));
      expect(siwis.label, 'Siwis · French · female');
    });
  });

  group('SystemTtsEngine', () {
    test('picks the most natural voice for the language', () {
      TtsVoice v(String id, String lang, String q, {bool net = false}) => TtsVoice(
        id: id,
        name: id,
        language: lang,
        engine: TtsEngineKind.system,
        quality: q,
        requiresNetwork: net,
      );
      final voices = [
        v('en-us-x-sfg-local', 'en-US', 'normal'),
        v('en-us-x-tpf-network', 'en-US', 'very high', net: true),
        v('en-gb-x-rjs-local', 'en-GB', 'very high'),
        v('de-de-x-nfh-network', 'de-DE', 'very high', net: true),
      ];
      expect(SystemTtsEngine.bestVoice(voices, 'en-US')!.id, 'en-us-x-tpf-network');
      expect(
        SystemTtsEngine.bestVoice(voices, 'en-US', online: false)!.id,
        'en-us-x-sfg-local',
      );
      expect(SystemTtsEngine.bestVoice(voices, 'en-AU')!.language, startsWith('en'));
      expect(SystemTtsEngine.bestVoice(voices, 'fr-FR'), isNull);
    });

    test('speaks queued sentences in order; stop drops the rest', () async {
      final fake = _FakePlatformTts()
        ..list = [
          {'name': 'en-us-x-tpf-network', 'locale': 'en-US', 'quality': 'very high', 'network_required': '1'},
        ];
      final e = SystemTtsEngine(tts: fake);
      await e.prepare();
      final a = e.play(await e.synthesize('One.', speed: 1));
      final b = e.play(await e.synthesize('Two.', speed: 1));
      await pump();
      expect(fake.spoken, ['One.']);
      expect(fake.voicesSet, ['en-us-x-tpf-network']);
      fake.done();
      expect(await a, isTrue);
      await pump();
      expect(fake.spoken, ['One.', 'Two.']);
      await e.stop();
      expect(await b, isFalse);
    });
  });

  group('SpeechSettings', () {
    test('defaults, round trip and clamping', () async {
      const d = SpeechSettings();
      expect(d.ttsEngine, TtsEngineKind.kokoro);
      expect(d.kokoroVariant, KokoroVariant.v1_0Fp32);
      expect(d.kokoroVoice, 'af_heart');
      expect(d.autoReadReplies, isFalse);
      expect(d.downloadOnWifiOnly, isTrue);

      final prefs = _MemPrefs();
      final c = SpeechSettingsController(prefs);
      await c.update(
        (s) => s.copyWith(
          speed: 9,
          dictationEngine: DictationEngineKind.moonshine,
          dictationLanguage: 'en-GB',
          autoReadReplies: true,
        ),
      );
      expect(c.value.speed, SpeechSettings.maxSpeed);

      final again = SpeechSettingsController(prefs);
      await again.load();
      expect(again.value, c.value);
      expect(again.value.dictationEngine, DictationEngineKind.moonshine);
    });

    test('corrupt or unknown values fall back to defaults', () async {
      final prefs = _MemPrefs()
        ..map[SpeechSettingsController.prefsKey] = '{"ttsEngine":"robot","speed":"fast"}';
      final c = SpeechSettingsController(prefs);
      await c.load();
      expect(c.value, const SpeechSettings());
      prefs.map[SpeechSettingsController.prefsKey] = 'not json';
      await c.load();
      expect(c.value, const SpeechSettings());
    });
  });

  test('platform events decode', () {
    expect(
      SpeechPlatformEvent.decode({'type': 'pcm', 'event': 'done', 'id': 3}),
      isA<PcmDoneEvent>().having((e) => e.id, 'id', 3),
    );
    expect(
      SpeechPlatformEvent.decode({'type': 'focus', 'change': 'lossTransient'}),
      isA<AudioFocusEvent>().having((e) => e.change, 'change', AudioFocusChange.lossTransient),
    );
    expect(SpeechPlatformEvent.decode({'type': 'noisy'}), isA<AudioBecomingNoisyEvent>());
    expect(
      SpeechPlatformEvent.decode({'type': 'stt', 'event': 'error', 'code': 7}),
      isA<RecognizerEvent>().having((e) => e.errorCode, 'code', 7),
    );
    expect(SpeechPlatformEvent.decode('junk'), isNull);
  });
}
