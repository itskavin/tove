import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tove_chat/src/speech/speech.dart';

import 'speech_fakes.dart';

Float32List _tone(int ms, double amp) => Float32List.fromList(
  List.generate(16 * ms, (i) => amp * math.sin(2 * math.pi * 220 * i / 16000)),
);

Uint8List _pcm(Float32List f) {
  final b = ByteData(f.length * 2);
  for (var i = 0; i < f.length; i++) {
    b.setInt16(i * 2, (f[i] * 32767).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

/// Records each phrase; answers from [replies] (or throws [error]).
class _FakeServer implements ServerTranscriber {
  bool ok = true;
  final calls = <({int bytes, String? language, String? prompt})>[];
  final replies = <String>['Remind me to call Ramesh.', 'At six thirty.'];
  final errors = <DictationError>[];

  @override
  Future<bool> available() async => ok;

  @override
  Future<String> transcribe(
    Uint8List wav, {
    String? language,
    String? prompt,
  }) async {
    calls.add((bytes: wav.length, language: language, prompt: prompt));
    if (errors.isNotEmpty) throw DictationException(errors.removeAt(0));
    return replies.isEmpty ? '' : replies.removeAt(0);
  }
}

void main() {
  group('dictation language', () {
    String r(
      String? tag,
      String lang,
      String? country, {
      Duration offset = Duration.zero,
    }) => resolveDictationLanguage(
      tag,
      deviceLanguage: lang,
      deviceCountry: country,
      utcOffset: offset,
    );
    const ist = Duration(hours: 5, minutes: 30);

    test('a chosen language wins', () {
      expect(r('en-GB', 'en', 'US', offset: ist), 'en-GB');
      expect(r('hi-IN', 'en', 'IN'), 'hi-IN');
    });

    test('English in India becomes English (India)', () {
      expect(r(null, 'en', 'US', offset: ist), 'en-IN', reason: 'IST phone');
      expect(r(null, 'en', 'IN'), 'en-IN');
      expect(r(null, 'en', null, offset: ist), 'en-IN');
    });

    test('elsewhere the device locale is used', () {
      expect(r(null, 'en', 'US', offset: const Duration(hours: -5)), 'en-US');
      expect(r(null, 'en', 'GB'), 'en-GB');
      expect(r(null, 'hi', 'IN', offset: ist), 'hi-IN');
      expect(r(null, 'de', null), 'de');
      expect(r(null, '', null), 'en-US');
    });
  });

  group('speech settings', () {
    test('the server engine is the default; old saves move to it', () {
      expect(
        const SpeechSettings().dictationEngine,
        DictationEngineKind.server,
      );
      // Schema 1 saved `system` as the only default.
      expect(
        SpeechSettings.fromJson({'dictationEngine': 'system'}).dictationEngine,
        DictationEngineKind.server,
      );
      expect(
        SpeechSettings.fromJson({'dictationEngine': 'moonshine'})
            .dictationEngine,
        DictationEngineKind.moonshine,
      );
      // A choice made now is kept.
      final chosen = const SpeechSettings().copyWith(
        dictationEngine: DictationEngineKind.system,
      );
      expect(
        SpeechSettings.fromJson(chosen.toJson()).dictationEngine,
        DictationEngineKind.system,
      );
    });
  });

  group('DictationController continuous', () {
    late FakeSpeechPlatform platform;
    late FakeDictationEngine engine;
    late DictationController c;

    setUp(() {
      platform = FakeSpeechPlatform();
      engine = FakeDictationEngine(onDevice: false);
      c = DictationController(platform: platform, engines: () => [engine]);
    });
    tearDown(() => c.dispose());

    test('an engine that ends at a pause is started again', () async {
      await c.start(continuous: true);
      expect(engine.continuous, isTrue);
      engine.emit(const DictationPartial('remind me'));
      await Future<void>.delayed(const Duration(milliseconds: 650));
      engine.emit(const DictationEnded());
      await pump();
      expect(engine.log, ['start:continuous', 'start:continuous']);
      expect(c.value.status, DictationStatus.listening);
      expect(c.value.committed, 'remind me', reason: 'the partial is kept');
      // "No match" at a pause is not an error while held.
      engine.emit(DictationFailed(DictationError.fromAndroid(7)));
      expect(c.value.status, DictationStatus.listening);
      engine.emit(const DictationPartial('to call Ramesh'));
      await c.stop();
      engine.emit(const DictationEnded());
      await pump();
      expect(c.value.status, DictationStatus.idle);
      expect(c.value.committed, 'remind me to call Ramesh');
    });

    test('a tap that becomes a hold switches to continuous', () async {
      await c.start();
      expect(engine.log, ['start']);
      c.continuous = true;
      expect(engine.continuous, isTrue);
      engine.emit(const DictationEnded());
      await pump();
      expect(engine.log.last, 'start:continuous');
    });

    test('quick ends in a row stop restarting', () async {
      await c.start(continuous: true);
      for (var i = 0; i < DictationController.maxQuickRestarts + 1; i++) {
        engine.emit(const DictationEnded());
        await pump();
      }
      expect(c.value.status, DictationStatus.idle);
      expect(
        engine.log.length,
        DictationController.maxQuickRestarts + 1,
        reason: 'the first start and three restarts',
      );
    });

    test('without continuous, a pause ends dictation as before', () async {
      await c.start();
      engine.emit(const DictationPartial('hello'));
      engine.emit(const DictationEnded());
      await pump();
      expect(c.value.status, DictationStatus.idle);
      expect(engine.log, ['start']);
    });

    test('stop while starting stops once the engine runs', () async {
      final slow = Completer<void>();
      platform.permission = MicPermission.denied;
      platform.afterRequest = MicPermission.granted;
      c.dispose();
      c = DictationController(
        platform: platform,
        engines: () => [engine],
        beforeListening: () => slow.future,
      );
      final started = c.start();
      await pump();
      expect(c.value.status, DictationStatus.starting);
      await c.stop();
      slow.complete();
      await started;
      await pump();
      expect(engine.log, ['start', 'stop']);
    });
  });

  group('ServerDictationEngine', () {
    late FakeSpeechPlatform platform;
    late _FakeServer server;
    late ServerDictationEngine engine;
    late List<DictationEvent> events;

    setUp(() {
      platform = FakeSpeechPlatform();
      server = _FakeServer();
      engine = ServerDictationEngine(
        platform: platform,
        transcriber: () => server,
        retryDelay: Duration.zero,
      );
      events = [];
      engine.events.listen(events.add);
    });
    tearDown(() => engine.dispose());

    void say(int ms, double amp) {
      final t = _tone(ms, amp);
      for (var i = 0; i < t.length; i += 1600) {
        platform.push(
          MicChunkEvent(
            _pcm(Float32List.sublistView(t, i, math.min(i + 1600, t.length))),
          ),
        );
      }
    }

    test(
      'each phrase goes to the server as it ends; stop sends the rest',
      () async {
        final info = await engine.start(language: 'en-IN', continuous: true);
        expect(info.mayUseNetwork, isTrue);
        expect(platform.calls.first, 'micStart');
        say(400, 0.001); // the room
        say(1200, 0.3);
        say(900, 0.001); // a pause ends the phrase
        await pump();
        expect(server.calls, hasLength(1));
        expect(server.calls.first.language, 'en-IN');
        expect(server.calls.first.prompt, isNull);
        // 300 ms of pre-roll + 1.2 s of speech + the pause, 16-bit, + header.
        expect(server.calls.first.bytes, greaterThan(44 + 2 * 16 * 1500));
        expect(
          events.whereType<DictationFinal>().single.text,
          'Remind me to call Ramesh.',
        );

        say(800, 0.3);
        await engine.stop();
        await pump();
        expect(server.calls, hasLength(2));
        expect(
          server.calls.last.prompt,
          'Remind me to call Ramesh.',
          reason: 'earlier words are the context',
        );
        expect(events.whereType<DictationFinal>().last.text, 'At six thirty.');
        expect(events.last, isA<DictationEnded>());
        expect(platform.calls, contains('micStop'));
        expect(events.whereType<DictationLevel>(), isNotEmpty);
      },
    );

    test('continuous ignores long silence; tap mode ends on it', () async {
      await engine.start(continuous: true);
      say(800, 0.3);
      say(4000, 0.001);
      await pump();
      expect(events.whereType<DictationEnded>(), isEmpty);
      engine.continuous = false;
      say(2400, 0.001);
      await pump();
      expect(events.whereType<DictationEnded>(), hasLength(1));
    });

    test('a server that cannot transcribe falls back (unavailable)', () async {
      server.ok = false;
      await expectLater(
        engine.start(),
        throwsA(
          isA<DictationException>().having(
            (e) => e.error.kind,
            'kind',
            DictationErrorKind.unavailable,
          ),
        ),
      );
      expect(platform.calls, ['micStart', 'micStop']);
      await expectLater(
        engine.start(onDeviceOnly: true),
        throwsA(isA<DictationException>()),
      );
      platform.network = const NetworkInfo(connected: false, unmetered: false);
      server.ok = true;
      await expectLater(engine.start(), throwsA(isA<DictationException>()));
    });

    test('one network failure is retried; a second is reported', () async {
      server.errors.add(
        const DictationError(DictationErrorKind.network, 'offline'),
      );
      await engine.start(continuous: true);
      say(800, 0.3);
      say(900, 0.001);
      await pump();
      expect(server.calls, hasLength(2));
      expect(events.whereType<DictationFinal>(), hasLength(1));

      server.errors
        ..add(const DictationError(DictationErrorKind.network, 'offline'))
        ..add(
          const DictationError(DictationErrorKind.network, 'still offline'),
        );
      say(800, 0.3);
      say(900, 0.001);
      await pump(20);
      final failed = events.whereType<DictationFailed>().single;
      expect(failed.error.kind, DictationErrorKind.network);
      expect(events.last, isA<DictationEnded>());
    });

    test('nothing said in tap mode: "Didn\'t hear anything"', () async {
      final quick = ServerDictationEngine(
        platform: platform,
        transcriber: () => server,
        endpointer: () => EnergyEndpointer(
          noSpeechTimeout: const Duration(milliseconds: 500),
        ),
      );
      final seen = <DictationEvent>[];
      quick.events.listen(seen.add);
      await quick.start();
      say(700, 0.001);
      await pump();
      expect(
        seen.whereType<DictationFailed>().single.error.kind,
        DictationErrorKind.speechTimeout,
      );
      expect(server.calls, isEmpty);
      await quick.dispose();
    });

    test('cancel drops phrases still on their way', () async {
      final gate = Completer<void>();
      final slow = _GatedServer(gate.future);
      final e = ServerDictationEngine(
        platform: platform,
        transcriber: () => slow,
      );
      final seen = <DictationEvent>[];
      e.events.listen(seen.add);
      await e.start(continuous: true);
      say(800, 0.3);
      say(900, 0.001);
      await pump();
      await e.cancel();
      gate.complete();
      await pump();
      expect(seen.whereType<DictationFinal>(), isEmpty);
      await e.dispose();
    });
  });

  test('pcm16Wav writes a 16 kHz mono header', () {
    final wav = pcm16Wav(Float32List.fromList([0, 0.5, -1]), 16000);
    final b = ByteData.sublistView(wav);
    expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
    expect(ascii.decode(wav.sublist(8, 12)), 'WAVE');
    expect(b.getUint16(22, Endian.little), 1);
    expect(b.getUint32(24, Endian.little), 16000);
    expect(b.getUint32(40, Endian.little), 6);
    expect(b.getInt16(46, Endian.little), 16384);
    expect(b.getInt16(48, Endian.little), -32768);
  });

  group('BridgeTranscriber', () {
    var now = DateTime(2026, 11, 16, 12);
    late List<http.BaseRequest> seen;
    late List<String> bodies;

    BridgeTranscriber make(
      Future<http.Response> Function(http.Request r) handler, {
      String? key,
    }) {
      seen = [];
      bodies = [];
      return BridgeTranscriber(
        baseUrl: () => Uri.parse('https://chat.example.org/'),
        accessKey: () => key ?? 'k' * 24,
        now: () => now,
        client: MockClient((r) {
          seen.add(r);
          bodies.add(latin1.decode(r.bodyBytes));
          return handler(r);
        }),
      );
    }

    test('reads the capability once and caches it', () async {
      final t = make(
        (r) async => http.Response(
          jsonEncode({
            'transcribe': {'max_s': 120},
          }),
          200,
        ),
      );
      expect(await t.available(), isTrue);
      expect(await t.available(), isTrue);
      expect(seen, hasLength(1));
      expect(seen.single.url.path, '/api/capabilities');
      expect(seen.single.headers['Authorization'], 'Bearer ${'k' * 24}');
      now = now.add(const Duration(minutes: 11));
      expect(await t.available(), isTrue);
      expect(seen, hasLength(2), reason: 'asked again after 10 minutes');
    });

    test('an old bridge or no key: unavailable', () async {
      final old = make((r) async => http.Response('{"chat": true}', 200));
      expect(await old.available(), isFalse);
      final none = make((r) async => http.Response('{}', 200), key: '');
      expect(await none.available(), isFalse);
      expect(seen, isEmpty);
    });

    test('posts the phrase with language and context', () async {
      final t = make(
        (r) async => http.Response(
          jsonEncode({'text': 'Hello there.', 'duration_s': 1.2}),
          200,
        ),
      );
      final text = await t.transcribe(
        pcm16Wav(Float32List(160), 16000),
        language: 'en-IN',
        prompt: 'Earlier words',
      );
      expect(text, 'Hello there.');
      final r = seen.single;
      expect(r.method, 'POST');
      expect(r.url.toString(), 'https://chat.example.org/api/transcribe');
      expect(r.headers['Content-Type'], startsWith('multipart/form-data'));
      expect(bodies.single, contains('name="language"\r\n\r\nen-IN'));
      expect(bodies.single, contains('name="prompt"\r\n\r\nEarlier words'));
      expect(bodies.single, contains('filename="dictation.wav"'));
      expect(bodies.single, contains('RIFF'));
    });

    test('errors map to clear kinds', () async {
      Future<DictationErrorKind> kindFor(http.Response resp) async {
        final t = make((r) async => resp);
        try {
          await t.transcribe(Uint8List(44));
        } on DictationException catch (e) {
          return e.error.kind;
        }
        fail('no error');
      }

      expect(
        await kindFor(http.Response('{"code": "busy"}', 503)),
        DictationErrorKind.busy,
      );
      expect(
        await kindFor(http.Response('{"code": "transcribe_unavailable"}', 503)),
        DictationErrorKind.unavailable,
      );
      expect(
        await kindFor(http.Response('{"code": "transcribe_failed"}', 502)),
        DictationErrorKind.server,
      );
      final down = make((r) async => throw http.ClientException('no route'));
      await expectLater(
        down.transcribe(Uint8List(44)),
        throwsA(
          isA<DictationException>().having(
            (e) => e.error.kind,
            'kind',
            DictationErrorKind.network,
          ),
        ),
      );
    });
  });
}

class _GatedServer implements ServerTranscriber {
  _GatedServer(this.gate);
  final Future<void> gate;
  @override
  Future<bool> available() async => true;
  @override
  Future<String> transcribe(
    Uint8List wav, {
    String? language,
    String? prompt,
  }) async {
    await gate;
    return 'late words';
  }
}
