import 'dart:async';
import 'dart:typed_data';

import 'package:tove_chat/src/speech/speech.dart';

/// In-memory [SpeechPlatform]: records calls, lets tests push native events.
class FakeSpeechPlatform implements SpeechPlatform {
  final _events = StreamController<SpeechPlatformEvent>.broadcast(sync: true);
  final calls = <String>[];
  final writes = <(int, Uint8List)>[];

  MicPermission permission = MicPermission.granted;
  MicPermission afterRequest = MicPermission.granted;
  bool focusGranted = true;
  NetworkInfo network = const NetworkInfo(connected: true, unmetered: true, wifi: true);
  int? free;
  RecognizerAvailability recognizer = const RecognizerAvailability(
    available: true,
    onDeviceAvailable: true,
    sdk: 34,
  );
  bool startOnDevice = true;

  void push(SpeechPlatformEvent e) => _events.add(e);

  @override
  bool get isSupported => true;
  @override
  Stream<SpeechPlatformEvent> get events => _events.stream;

  @override
  Future<RecognizerAvailability> recognizerAvailability() async => recognizer;
  @override
  Future<RecognizerStartInfo> startRecognizer({
    String? language,
    required bool preferOnDevice,
    required bool allowNetwork,
  }) async {
    calls.add('sttStart:$language:$preferOnDevice:$allowNetwork');
    return RecognizerStartInfo(onDevice: startOnDevice);
  }

  @override
  Future<void> stopRecognizer() async => calls.add('sttStop');
  @override
  Future<void> cancelRecognizer() async => calls.add('sttCancel');
  @override
  Future<RecognizerLanguages?> recognizerLanguages(String? language) async => null;
  @override
  Future<bool> downloadRecognizerLanguage(String language) async => false;

  @override
  Future<MicPermission> micPermission() async => permission;
  @override
  Future<MicPermission> requestMicPermission() async {
    calls.add('requestMic');
    permission = afterRequest;
    return permission;
  }

  @override
  Future<void> startMic({int sampleRate = 16000}) async => calls.add('micStart');
  @override
  Future<void> stopMic() async => calls.add('micStop');

  @override
  Future<void> pcmOpen({required int sampleRate}) async =>
      calls.add('pcmOpen:$sampleRate');
  @override
  Future<void> pcmWrite(int id, Uint8List pcm16) async {
    calls.add('pcmWrite:$id');
    writes.add((id, pcm16));
  }

  @override
  Future<void> pcmPause() async => calls.add('pcmPause');
  @override
  Future<void> pcmResume() async => calls.add('pcmResume');
  @override
  Future<void> pcmStop() async => calls.add('pcmStop');

  @override
  Future<bool> requestAudioFocus({bool mayDuck = false}) async {
    calls.add('focus');
    return focusGranted;
  }

  @override
  Future<void> abandonAudioFocus() async => calls.add('abandonFocus');
  @override
  Future<NetworkInfo> networkInfo() async => network;
  @override
  Future<int?> freeBytes(String path) async => free;
}

/// A [TtsEngine] whose playback the test finishes by hand.
class FakeTtsEngine implements TtsEngine {
  FakeTtsEngine({
    this.kind = TtsEngineKind.kokoro,
    this.resumesMidSentence = true,
    this.failPrepare = false,
    this.rtf = 0.5,
  });

  @override
  final TtsEngineKind kind;
  @override
  final bool resumesMidSentence;
  final bool failPrepare;
  final double rtf;

  final synthesized = <String>[];
  final speeds = <double>[];
  final playing = <(String, Completer<bool>)>[];
  final log = <String>[];
  int prepared = 0;
  int released = 0;

  /// Completes synthesis immediately unless set.
  Completer<void>? synthGate;

  @override
  Future<void> prepare() async {
    prepared++;
    if (failPrepare) throw const TtsException('model missing');
  }

  @override
  Future<List<TtsVoice>> voices() async => const [
    TtsVoice(id: 'v1', name: 'One', language: 'en-US', engine: TtsEngineKind.kokoro),
  ];

  @override
  Future<TtsVoice?> defaultVoice() async => (await voices()).first;

  @override
  Future<TtsUtterance> synthesize(
    String text, {
    TtsVoice? voice,
    required double speed,
  }) async {
    final gate = synthGate;
    if (gate != null) await gate.future;
    synthesized.add(text);
    speeds.add(speed);
    return TtsUtterance(
      text: text,
      audioDuration: const Duration(seconds: 2),
      synthDuration: Duration(milliseconds: (2000 * rtf).round()),
    );
  }

  @override
  Future<bool> play(TtsUtterance u) {
    final c = Completer<bool>();
    playing.add((u.text, c));
    log.add('play:${u.text}');
    return c.future;
  }

  /// Finishes the oldest unfinished utterance.
  void finishNext() {
    final p = playing.firstWhere((p) => !p.$2.isCompleted);
    p.$2.complete(true);
  }

  int get queued => playing.where((p) => !p.$2.isCompleted).length;

  @override
  Future<void> pause() async => log.add('pause');
  @override
  Future<void> resume() async => log.add('resume');

  @override
  Future<void> stop() async {
    log.add('stop');
    for (final p in playing) {
      if (!p.$2.isCompleted) p.$2.complete(false);
    }
  }

  @override
  Future<void> release() async => released++;
}

/// A [DictationEngine] driven by the test.
class FakeDictationEngine implements DictationEngine {
  FakeDictationEngine({
    this.kind = DictationEngineKind.system,
    this.onDevice = true,
    this.startError,
  });

  @override
  final DictationEngineKind kind;
  final bool onDevice;
  DictationError? startError;
  final _events = StreamController<DictationEvent>.broadcast(sync: true);
  final log = <String>[];
  String? language;

  void emit(DictationEvent e) => _events.add(e);

  @override
  Stream<DictationEvent> get events => _events.stream;

  @override
  Future<DictationAvailability> availability({bool onDeviceOnly = false}) async =>
      DictationAvailability(available: startError == null, onDevice: onDevice);

  bool continuous = false;

  @override
  Future<DictationStart> start({
    String? language,
    bool onDeviceOnly = false,
    bool continuous = false,
  }) async {
    log.add(continuous ? 'start:continuous' : 'start');
    this.language = language;
    this.continuous = continuous;
    final e = startError;
    if (e != null) throw DictationException(e);
    return DictationStart(onDevice: onDevice);
  }

  @override
  Future<void> stop() async => log.add('stop');
  @override
  Future<void> cancel() async => log.add('cancel');
  @override
  Future<void> dispose() async {}
}

/// Lets microtasks and zero-delay timers run.
Future<void> pump([int times = 10]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
