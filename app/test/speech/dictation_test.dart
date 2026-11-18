import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/speech/speech.dart';
import 'package:tove_chat/src/speech/dictation/moonshine_dictation_engine.dart'
    show OfflineTranscriber;

import 'speech_fakes.dart';

void main() {
  group('DictationController', () {
    late FakeSpeechPlatform platform;
    late FakeDictationEngine engine;
    late DictationController dictation;
    var stoppedTts = 0;

    setUp(() {
      platform = FakeSpeechPlatform();
      engine = FakeDictationEngine();
      stoppedTts = 0;
      dictation = DictationController(
        platform: platform,
        engines: () => [engine],
        language: () => 'en-GB',
        beforeListening: () async => stoppedTts++,
      );
    });

    tearDown(() => dictation.dispose());

    test('partial then final flow', () async {
      final finished = <String>[];
      dictation.onFinished.listen(finished.add);
      await dictation.start();
      expect(dictation.value.status, DictationStatus.listening);
      expect(engine.language, 'en-GB');
      expect(stoppedTts, 1, reason: 'read-aloud stops before the mic opens');
      expect(dictation.value.mayUseNetwork, isFalse);

      engine.emit(const DictationSpeechStarted());
      engine.emit(const DictationLevel(0.6));
      expect(dictation.value.level, 0.6);
      engine.emit(const DictationPartial('turn on'));
      expect(dictation.value.partial, 'turn on');
      expect(dictation.value.text, 'turn on');
      engine.emit(const DictationPartial('turn on the lights'));
      expect(dictation.value.text, 'turn on the lights');

      await dictation.stop();
      expect(dictation.value.status, DictationStatus.finishing);
      expect(engine.log, contains('stop'));
      engine.emit(const DictationFinal('Turn on the lights.'));
      expect(dictation.value.committed, 'Turn on the lights.');
      expect(dictation.value.partial, '');
      engine.emit(const DictationEnded());
      await pump();
      expect(dictation.value.status, DictationStatus.idle);
      expect(dictation.value.committed, 'Turn on the lights.');
      expect(finished, ['Turn on the lights.']);
    });

    test('segmented finals are appended', () async {
      await dictation.start();
      engine.emit(const DictationFinal('First part.'));
      engine.emit(const DictationPartial('second'));
      expect(dictation.value.text, 'First part. second');
      engine.emit(const DictationFinal('Second part.'));
      engine.emit(const DictationEnded());
      expect(dictation.value.committed, 'First part. Second part.');
    });

    test('end of speech without stop delivers the text', () async {
      final finished = <String>[];
      dictation.onFinished.listen(finished.add);
      await dictation.start();
      engine.emit(const DictationPartial('hello there'));
      engine.emit(const DictationEnded());
      await pump();
      expect(dictation.value.status, DictationStatus.idle);
      expect(finished, ['hello there']);
    });

    test('network recogniser is flagged', () async {
      engine = FakeDictationEngine(onDevice: false);
      await dictation.start();
      expect(dictation.value.mayUseNetwork, isTrue);
    });

    test('asks for permission and maps a refusal', () async {
      platform.permission = MicPermission.denied;
      platform.afterRequest = MicPermission.denied;
      await dictation.start();
      expect(platform.calls, contains('requestMic'));
      expect(dictation.value.status, DictationStatus.error);
      expect(dictation.value.error!.kind, DictationErrorKind.permissionDenied);
      expect(engine.log, isEmpty);
    });

    test('permanent refusal points to Settings', () async {
      platform.permission = MicPermission.permanentlyDenied;
      await dictation.start();
      expect(dictation.value.error!.needsSettings, isTrue);
      expect(platform.calls, isNot(contains('requestMic')));
    });

    test('granting at the prompt starts listening', () async {
      platform.permission = MicPermission.denied;
      platform.afterRequest = MicPermission.granted;
      await dictation.start();
      expect(dictation.value.status, DictationStatus.listening);
    });

    test('engine errors become clear messages', () async {
      await dictation.start();
      engine.emit(DictationFailed(DictationError.fromAndroid(7)));
      expect(dictation.value.status, DictationStatus.error);
      expect(dictation.value.error!.message, "Couldn't hear that.");
      dictation.dismissError();
      expect(dictation.value.status, DictationStatus.idle);
    });

    test('an error while finishing with text is ignored', () async {
      await dictation.start();
      engine.emit(const DictationPartial('almost done'));
      await dictation.stop();
      engine.emit(DictationFailed(DictationError.fromAndroid(5)));
      engine.emit(const DictationEnded());
      expect(dictation.value.status, DictationStatus.idle);
      expect(dictation.value.committed, 'almost done');
    });

    test('falls back to the next engine when the first cannot run', () async {
      final offline = FakeDictationEngine(
        kind: DictationEngineKind.moonshine,
        startError: const DictationError(DictationErrorKind.modelMissing, 'Download first.'),
      );
      final system = FakeDictationEngine(onDevice: false);
      dictation.dispose();
      dictation = DictationController(platform: platform, engines: () => [offline, system]);
      await dictation.start();
      expect(dictation.value.engine, DictationEngineKind.system);
      expect(dictation.value.notice, 'Download first.');
      expect(dictation.value.mayUseNetwork, isTrue);
    });

    test('no engine at all says to use the keyboard', () async {
      engine.startError = DictationError.fromAndroid(-1);
      await dictation.start();
      expect(dictation.value.error!.fallBackToKeyboard, isTrue);
    });

    test('cancel drops the text; live mode cancels and blocks', () async {
      await dictation.start();
      engine.emit(const DictationPartial('secret'));
      await dictation.cancel();
      expect(dictation.value.text, '');
      expect(engine.log, contains('cancel'));

      await dictation.start();
      dictation.liveModeActive = true;
      await pump();
      expect(dictation.value.isActive, isFalse);
      await dictation.start();
      expect(dictation.value.isActive, isFalse);
    });

    test('stop gives up waiting after the timeout', () async {
      dictation.dispose();
      dictation = DictationController(
        platform: platform,
        engines: () => [engine],
        finishTimeout: const Duration(milliseconds: 20),
      );
      await dictation.start();
      engine.emit(const DictationPartial('half'));
      await dictation.stop();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(dictation.value.status, DictationStatus.idle);
      expect(dictation.value.committed, 'half');
    });
  });

  group('SystemDictationEngine', () {
    test('maps recogniser events', () async {
      final platform = FakeSpeechPlatform()..startOnDevice = false;
      final engine = SystemDictationEngine(platform);
      final events = <DictationEvent>[];
      engine.events.listen(events.add);
      final info = await engine.start(language: 'en-US');
      expect(info.mayUseNetwork, isTrue);
      expect(platform.calls.single, 'sttStart:en-US:false:true', reason: 'online first');
      platform.push(const RecognizerEvent(event: 'ready'));
      platform.push(const RecognizerEvent(event: 'rms', rmsDb: 10));
      platform.push(const RecognizerEvent(event: 'partial', text: 'hi'));
      platform.push(const RecognizerEvent(event: 'final', text: 'Hi.'));
      await pump();
      expect(events[0], isA<DictationReady>());
      expect((events[1] as DictationLevel).level, 1.0);
      expect((events[2] as DictationPartial).text, 'hi');
      expect((events[3] as DictationFinal).text, 'Hi.');
      expect(events[4], isA<DictationEnded>());
      await engine.dispose();
    });

    test('on-device only is passed through', () async {
      final platform = FakeSpeechPlatform();
      final engine = SystemDictationEngine(platform);
      await engine.start(onDeviceOnly: true);
      expect(platform.calls.single, 'sttStart:null:true:false');
      await engine.dispose();
    });
  });

  group('Moonshine offline engine', () {
    Float32List tone(int ms, double amp) {
      final n = 16 * ms;
      return Float32List.fromList(
        List.generate(n, (i) => amp * math.sin(2 * math.pi * 220 * i / 16000)),
      );
    }

    test('endpointer: speech, segment pause, end of speech', () {
      final ep = EnergyEndpointer();
      final seen = <EndpointEvent>[];
      void feed(Float32List c) {
        for (var i = 0; i < c.length; i += 1600) {
          seen.addAll(ep.add(Float32List.sublistView(c, i, math.min(i + 1600, c.length))));
        }
      }

      feed(tone(500, 0.001)); // quiet room
      expect(seen, isEmpty);
      feed(tone(800, 0.3));
      expect(seen, [EndpointEvent.speechStarted]);
      feed(tone(800, 0.001));
      expect(seen.last, EndpointEvent.segmentEnded);
      feed(tone(1500, 0.001));
      expect(seen.last, EndpointEvent.utteranceEnded);
    });

    test('endpointer: no speech times out', () {
      final ep = EnergyEndpointer(noSpeechTimeout: const Duration(seconds: 1));
      final seen = <EndpointEvent>[];
      for (var i = 0; i < 12; i++) {
        seen.addAll(ep.add(tone(100, 0.001)));
      }
      expect(seen, [EndpointEvent.noSpeech]);
    });

    test('partials while speaking, final per segment, then ended', () async {
      final platform = FakeSpeechPlatform();
      final asr = _FakeTranscriber();
      final engine = MoonshineDictationEngine(
        platform: platform,
        modelDir: () async => '/models/moonshine',
        spawn: (_) async => asr,
        partialInterval: const Duration(milliseconds: 300),
      );
      final events = <DictationEvent>[];
      engine.events.listen(events.add);
      await engine.start(language: 'en-US');
      expect(platform.calls, contains('micStart'));
      for (var i = 0; i < 8; i++) {
        platform.push(MicChunkEvent(_pcm(tone(100, 0.3))));
      }
      await pump();
      expect(events.whereType<DictationPartial>(), isNotEmpty);
      for (var i = 0; i < 8; i++) {
        platform.push(MicChunkEvent(_pcm(tone(100, 0.0005))));
      }
      await pump();
      expect(events.whereType<DictationFinal>().single.text, 'heard 1');
      await engine.stop();
      await pump();
      expect(events.last, isA<DictationEnded>());
      expect(platform.calls, contains('micStop'));
      await engine.dispose();
    });

    test('missing model and non-English are refused clearly', () async {
      final engine = MoonshineDictationEngine(
        platform: FakeSpeechPlatform(),
        modelDir: () async => null,
      );
      expect((await engine.availability()).available, isFalse);
      await expectLater(
        engine.start(),
        throwsA(
          isA<DictationException>().having(
            (e) => e.error.kind,
            'kind',
            DictationErrorKind.modelMissing,
          ),
        ),
      );
      await expectLater(
        engine.start(language: 'de-DE'),
        throwsA(
          isA<DictationException>().having(
            (e) => e.error.kind,
            'kind',
            DictationErrorKind.languageNotSupported,
          ),
        ),
      );
    });
  });

  test('Android error codes map to messages', () {
    expect(DictationError.fromAndroid(2).kind, DictationErrorKind.network);
    expect(DictationError.fromAndroid(6).message, "Didn't hear anything.");
    expect(DictationError.fromAndroid(9).kind, DictationErrorKind.permissionDenied);
    expect(DictationError.fromAndroid(13).kind, DictationErrorKind.languageUnavailable);
    expect(DictationError.fromAndroid(99).kind, DictationErrorKind.other);
  });
}

Uint8List _pcm(Float32List f) {
  final b = ByteData(f.length * 2);
  for (var i = 0; i < f.length; i++) {
    b.setInt16(i * 2, (f[i] * 32767).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

class _FakeTranscriber implements OfflineTranscriber {
  int calls = 0;
  @override
  Future<String> transcribe(Float32List samples) async {
    calls++;
    return 'heard 1';
  }

  @override
  Future<void> close() async {}
}
