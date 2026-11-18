import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import '../models/model_catalog.dart';
import '../speech_platform.dart';
import 'kokoro_phonemizer.dart';
import 'kokoro_voices.dart';
import 'tts_engine.dart';

/// One synthesised sentence as 16-bit mono PCM.
class KokoroAudio {
  const KokoroAudio({
    required this.pcm16,
    required this.sampleRate,
    required this.synthTime,
  });

  final Uint8List pcm16;
  final int sampleRate;
  final Duration synthTime;

  Duration get duration => Duration(
    microseconds: (pcm16.length ~/ 2) * 1000000 ~/ math.max(1, sampleRate),
  );
}

/// The synthesiser behind [KokoroEngine]. The real one is [KokoroIsolate];
/// tests use a fake.
abstract class KokoroSynth {
  int get sampleRate;
  Future<KokoroAudio> synth(
    String text, {
    required int sid,
    required double speed,
    required bool british,
  });
  Future<void> close();
}

/// Paths to an installed Kokoro model.
class KokoroModelFiles {
  const KokoroModelFiles(this.dir, this.variant);
  final String dir;
  final KokoroVariant variant;

  String get model => '$dir/${variant.modelFile}';
  String get voices => '$dir/voices.bin';
  String get tokens => '$dir/tokens.txt';
  String get lexiconUs => '$dir/lexicon-us-en.txt';
  String get lexiconGb => '$dir/lexicon-gb-en.txt';
  String get lexiconZh => '$dir/lexicon-zh.txt';
}

/// Kokoro read-aloud: sherpa-onnx on a worker isolate, the phonemizer from
/// [KokoroPhonemizer], and PCM played by the native `AudioTrack` in
/// `SpeechChannel.kt`.
class KokoroEngine implements TtsEngine {
  KokoroEngine({
    required this.platform,
    required this.files,
    this.numThreads,
    Future<KokoroSynth> Function(KokoroModelFiles files, int threads)? spawn,
  }) : _spawn = spawn ?? KokoroIsolate.spawn;

  final SpeechPlatform platform;

  /// Resolves the installed model, or null when it is not downloaded.
  final Future<KokoroModelFiles?> Function() files;

  /// sherpa-onnx threads. Defaults to half the cores, 2 to 4.
  final int? numThreads;
  final Future<KokoroSynth> Function(KokoroModelFiles, int) _spawn;

  KokoroSynth? _synth;
  Future<KokoroSynth>? _loading;
  KokoroVariant? _variant;
  StreamSubscription<SpeechPlatformEvent>? _events;
  final Map<int, Completer<bool>> _pending = {};
  bool _open = false;
  int _nextId = 1;

  @override
  TtsEngineKind get kind => TtsEngineKind.kokoro;

  @override
  bool get resumesMidSentence => true;

  int get _threads =>
      numThreads ?? (Platform.numberOfProcessors ~/ 2).clamp(2, 4);

  @override
  Future<void> prepare() async {
    if (_synth != null) return;
    _events ??= platform.events.listen(_onEvent);
    final loading = _loading ??= () async {
      final f = await files();
      if (f == null) {
        throw const TtsException('The natural voice is not downloaded yet.');
      }
      _variant = f.variant;
      return _spawn(f, _threads);
    }();
    try {
      _synth = await loading;
    } catch (e) {
      _loading = null;
      if (e is TtsException) rethrow;
      throw TtsException('The natural voice could not load: $e');
    }
  }

  void _onEvent(SpeechPlatformEvent e) {
    if (e is PcmDoneEvent) {
      _pending.remove(e.id)?.complete(true);
    } else if (e is PcmErrorEvent) {
      for (final c in _pending.values) {
        if (!c.isCompleted) c.completeError(TtsException(e.message));
      }
      _pending.clear();
      _open = false;
    }
  }

  @override
  Future<List<TtsVoice>> voices() async =>
      kokoroVoices(v1_1: _variant?.isV1_1 ?? false);

  @override
  Future<TtsVoice?> defaultVoice() async {
    final all = await voices();
    return all.firstWhere(
      (v) => v.id == defaultKokoroVoice,
      orElse: () => all.first,
    );
  }

  @override
  Future<TtsUtterance> synthesize(
    String text, {
    TtsVoice? voice,
    required double speed,
  }) async {
    await prepare();
    final v = voice != null && voice.engine == TtsEngineKind.kokoro
        ? voice
        : (await defaultVoice())!;
    final all = await voices();
    // A voice saved for the other model maps to that model's default.
    final sid = all.any((x) => x.id == v.id && x.speakerId == v.speakerId)
        ? v.speakerId!
        : (await defaultVoice())!.speakerId!;
    final audio = await _synth!.synth(
      text,
      sid: sid,
      speed: speed,
      british: v.language == 'en-GB',
    );
    return TtsUtterance(
      text: text,
      audioDuration: audio.duration,
      synthDuration: audio.synthTime,
      payload: audio,
    );
  }

  @override
  Future<bool> play(TtsUtterance u) async {
    final audio = u.payload;
    if (audio is! KokoroAudio) throw ArgumentError('not a Kokoro utterance');
    if (audio.pcm16.isEmpty) return true;
    if (!_open) {
      await platform.pcmOpen(sampleRate: audio.sampleRate);
      _open = true;
    }
    final id = _nextId++;
    final c = _pending[id] = Completer<bool>();
    await platform.pcmWrite(id, audio.pcm16);
    return c.future;
  }

  @override
  Future<void> pause() => platform.pcmPause();

  @override
  Future<void> resume() => platform.pcmResume();

  @override
  Future<void> stop() async {
    final pending = _pending.values.toList();
    _pending.clear();
    _open = false;
    await platform.pcmStop();
    for (final c in pending) {
      if (!c.isCompleted) c.complete(false);
    }
  }

  @override
  Future<void> release() async {
    await stop();
    await _events?.cancel();
    _events = null;
    final s = _synth;
    _synth = null;
    _loading = null;
    await s?.close();
  }
}

// ---------------------------------------------------------------------------
// Worker isolate

/// sherpa-onnx Kokoro on its own isolate, so synthesis never blocks the UI.
class KokoroIsolate implements KokoroSynth {
  KokoroIsolate._(this._send, this._receive, this.sampleRate, this._isolate);

  final SendPort _send;
  final ReceivePort _receive;
  final Isolate _isolate;
  @override
  final int sampleRate;
  final Map<int, Completer<KokoroAudio>> _calls = {};
  int _next = 0;

  static Future<KokoroSynth> spawn(KokoroModelFiles files, int threads) async {
    final receive = ReceivePort();
    final isolate = await Isolate.spawn(
      _kokoroMain,
      _KokoroInit(receive.sendPort, files.dir, files.variant.modelFile, threads),
      debugName: 'kokoro-tts',
    );
    final ready = Completer<(SendPort, int)>();
    late final KokoroIsolate self;
    receive.listen((msg) {
      if (msg is _Ready) {
        ready.complete((msg.port, msg.sampleRate));
      } else if (msg is _Failed && !ready.isCompleted) {
        ready.completeError(TtsException(msg.error));
      } else if (ready.isCompleted) {
        self._onReply(msg);
      }
    });
    try {
      final (port, rate) = await ready.future;
      self = KokoroIsolate._(port, receive, rate, isolate);
      return self;
    } catch (_) {
      receive.close();
      isolate.kill();
      rethrow;
    }
  }

  void _onReply(Object? msg) {
    if (msg is _Audio) {
      _calls.remove(msg.id)?.complete(
        KokoroAudio(
          pcm16: msg.pcm.materialize().asUint8List(),
          sampleRate: msg.sampleRate,
          synthTime: Duration(microseconds: msg.synthUs),
        ),
      );
    } else if (msg is _Failed && msg.id != null) {
      _calls.remove(msg.id)?.completeError(TtsException(msg.error));
    }
  }

  @override
  Future<KokoroAudio> synth(
    String text, {
    required int sid,
    required double speed,
    required bool british,
  }) {
    final id = _next++;
    final c = _calls[id] = Completer<KokoroAudio>();
    _send.send(_Synth(id, text, sid, speed, british));
    return c.future;
  }

  @override
  Future<void> close() async {
    _send.send(null);
    for (final c in _calls.values) {
      c.completeError(const TtsException('Stopped.'));
    }
    _calls.clear();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _receive.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

class _KokoroInit {
  const _KokoroInit(this.reply, this.dir, this.modelFile, this.threads);
  final SendPort reply;
  final String dir;
  final String modelFile;
  final int threads;
}

class _Ready {
  const _Ready(this.port, this.sampleRate);
  final SendPort port;
  final int sampleRate;
}

class _Synth {
  const _Synth(this.id, this.text, this.sid, this.speed, this.british);
  final int id;
  final String text;
  final int sid;
  final double speed;
  final bool british;
}

class _Audio {
  const _Audio(this.id, this.pcm, this.sampleRate, this.synthUs);
  final int id;
  final TransferableTypedData pcm;
  final int sampleRate;
  final int synthUs;
}

class _Failed {
  const _Failed(this.id, this.error);
  final int? id;
  final String error;
}

Future<void> _kokoroMain(_KokoroInit init) async {
  final port = ReceivePort();
  final so.OfflineTts tts;
  final Set<int> tokens;
  final KokoroLexicon us;
  KokoroLexicon? gb;
  final dir = init.dir;
  try {
    so.initBindings();
    final zh = File('$dir/lexicon-zh.txt').existsSync();
    tts = so.OfflineTts(
      so.OfflineTtsConfig(
        model: so.OfflineTtsModelConfig(
          kokoro: so.OfflineTtsKokoroModelConfig(
            model: '$dir/${init.modelFile}',
            voices: '$dir/voices.bin',
            tokens: '$dir/tokens.txt',
            // Used only for sentences sherpa-onnx tokenises itself (CJK).
            lexicon: [
              '$dir/lexicon-us-en.txt',
              if (zh) '$dir/lexicon-zh.txt',
            ].join(','),
          ),
          numThreads: init.threads,
        ),
        maxNumSentences: 1,
        ruleFsts: [
          for (final f in ['date-zh.fst', 'number-zh.fst', 'phone-zh.fst'])
            if (File('$dir/$f').existsSync()) '$dir/$f',
        ].join(','),
      ),
    );
    tokens = parseKokoroTokens(File('$dir/tokens.txt').readAsStringSync());
    us = KokoroLexicon.parse(File('$dir/lexicon-us-en.txt').readAsStringSync());
  } catch (e) {
    init.reply.send(_Failed(null, 'The natural voice could not load: $e'));
    port.close();
    return;
  }
  final usPh = KokoroPhonemizer(lexicon: us, tokens: tokens);
  KokoroPhonemizer? gbPh;
  init.reply.send(_Ready(port.sendPort, tts.sampleRate));

  await for (final msg in port) {
    if (msg == null) break;
    if (msg is! _Synth) continue;
    try {
      final t = Stopwatch()..start();
      so.GeneratedAudio audio;
      if (KokoroPhonemizer.hasCjk(msg.text)) {
        audio = tts.generate(text: msg.text, sid: msg.sid, speed: msg.speed);
      } else {
        KokoroPhonemizer ph = usPh;
        if (msg.british) {
          gb ??= KokoroLexicon.parse(
            File('$dir/lexicon-gb-en.txt').readAsStringSync(),
          );
          ph = gbPh ??= KokoroPhonemizer(
            lexicon: gb,
            tokens: tokens,
            british: true,
          );
        }
        final phonemes = ph.phonemize(msg.text);
        audio = phonemes.isEmpty
            ? so.GeneratedAudio(samples: Float32List(0), sampleRate: tts.sampleRate)
            : tts.generateWithConfig(
                text: '',
                config: so.OfflineTtsGenerationConfig(
                  sid: msg.sid,
                  speed: msg.speed,
                  phonemeCodepoints: [phonemes.runes.toList()],
                ),
              );
      }
      final pcm = floatToPcm16(audio.samples);
      init.reply.send(
        _Audio(
          msg.id,
          TransferableTypedData.fromList([pcm]),
          audio.sampleRate == 0 ? tts.sampleRate : audio.sampleRate,
          t.elapsedMicroseconds,
        ),
      );
    } catch (e) {
      init.reply.send(_Failed(msg.id, 'Speech synthesis failed: $e'));
    }
  }
  tts.free();
  port.close();
}

/// [-1, 1] floats → 16-bit little-endian PCM bytes.
Uint8List floatToPcm16(Float32List samples) {
  final out = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    final v = samples[i];
    final clamped = v.isNaN ? 0.0 : (v < -1 ? -1.0 : (v > 1 ? 1.0 : v));
    out.setInt16(i * 2, (clamped * 32767).round(), Endian.little);
  }
  return out.buffer.asUint8List();
}
