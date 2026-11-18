import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

import '../speech_platform.dart';
import 'dictation_engine.dart';

enum EndpointEvent { speechStarted, segmentEnded, utteranceEnded, noSpeech }

/// Energy-based end-of-speech detection for the offline engine.
///
/// sherpa-onnx's Moonshine is an offline recogniser, so "streaming" means
/// re-decoding the current segment for partials and cutting segments at
/// short pauses. The threshold follows the room's noise floor.
class EnergyEndpointer {
  EnergyEndpointer({
    this.sampleRate = 16000,
    this.segmentSilence = const Duration(milliseconds: 700),
    this.endSilence = const Duration(milliseconds: 2000),
    this.noSpeechTimeout = const Duration(seconds: 6),
    this.maxSegment = const Duration(seconds: 20),
    this.minThreshold = 0.012,
  });

  final int sampleRate;

  /// A pause this long ends a segment (its text becomes final).
  final Duration segmentSilence;

  /// A pause this long after speech ends dictation (the Android default).
  final Duration endSilence;

  /// No speech at all for this long ends dictation with "Didn't hear".
  final Duration noSpeechTimeout;

  /// Segments are cut here even without a pause.
  final Duration maxSegment;
  final double minThreshold;

  /// Press and hold / hands-free: pauses only end segments; dictation ends
  /// when the user says so (no [EndpointEvent.utteranceEnded] or
  /// [EndpointEvent.noSpeech]). Can change while listening.
  bool continuous = false;

  double _floor = 0.005;
  int _samples = 0;
  int _silentSamples = 0;
  int _segmentSamples = 0;
  bool _heardSpeech = false;
  bool _inSegment = false;
  bool _ended = false;

  /// Input level 0–1.
  double level = 0;

  int _n(Duration d) => d.inMicroseconds * sampleRate ~/ 1000000;

  bool get inSegment => _inSegment;

  List<EndpointEvent> add(Float32List chunk) {
    if (chunk.isEmpty || _ended) return const [];
    var sum = 0.0;
    for (final v in chunk) {
      sum += v * v;
    }
    final rms = math.sqrt(sum / chunk.length);
    final threshold = math.max(minThreshold, _floor * 3);
    final speech = rms > threshold;
    if (!speech) _floor = _floor * 0.95 + rms * 0.05;
    level = (rms / (threshold * 4)).clamp(0.0, 1.0);
    _samples += chunk.length;

    final out = <EndpointEvent>[];
    if (speech) {
      _silentSamples = 0;
      if (!_inSegment) {
        _inSegment = true;
        _segmentSamples = 0;
        if (!_heardSpeech) out.add(EndpointEvent.speechStarted);
        _heardSpeech = true;
      }
    } else {
      _silentSamples += chunk.length;
    }
    if (_inSegment) {
      _segmentSamples += chunk.length;
      if (_silentSamples >= _n(segmentSilence) ||
          _segmentSamples >= _n(maxSegment)) {
        _inSegment = false;
        out.add(EndpointEvent.segmentEnded);
      }
    }
    if (continuous) {
      // Only segments.
    } else if (_heardSpeech && !_inSegment && _silentSamples >= _n(endSilence)) {
      _ended = true;
      out.add(EndpointEvent.utteranceEnded);
    } else if (!_heardSpeech && _samples >= _n(noSpeechTimeout)) {
      _ended = true;
      out.add(EndpointEvent.noSpeech);
    }
    return out;
  }
}

/// Decodes 16 kHz mono audio to text. Real one: [MoonshineIsolate].
abstract class OfflineTranscriber {
  Future<String> transcribe(Float32List samples);
  Future<void> close();
}

/// Offline dictation: microphone PCM from `SpeechChannel.kt` and Moonshine
/// tiny (English) through sherpa-onnx on a worker isolate.
class MoonshineDictationEngine implements DictationEngine {
  MoonshineDictationEngine({
    required this._platform,
    required this.modelDir,
    Future<OfflineTranscriber> Function(String dir)? spawn,
    EnergyEndpointer Function()? endpointer,
    this.partialInterval = const Duration(milliseconds: 700),
  }) : _spawn = spawn ?? MoonshineIsolate.spawn,
       _newEndpointer = endpointer ?? EnergyEndpointer.new;

  final SpeechPlatform _platform;

  /// The installed model directory, or null when not downloaded.
  final Future<String?> Function() modelDir;
  final Future<OfflineTranscriber> Function(String) _spawn;
  final EnergyEndpointer Function() _newEndpointer;

  /// How much new audio triggers a partial re-decode.
  final Duration partialInterval;

  static const sampleRate = 16000;

  final _events = StreamController<DictationEvent>.broadcast();
  StreamSubscription<SpeechPlatformEvent>? _sub;
  OfflineTranscriber? _asr;
  EnergyEndpointer? _ep;
  final List<Float32List> _segment = [];
  int _segmentLen = 0;
  int _sinceDecode = 0;
  bool _decoding = false;
  bool _listening = false;
  Future<void> _finals = Future.value();

  @override
  DictationEngineKind get kind => DictationEngineKind.moonshine;

  @override
  Stream<DictationEvent> get events => _events.stream;

  @override
  Future<DictationAvailability> availability({bool onDeviceOnly = false}) async {
    if (!_platform.isSupported) {
      return const DictationAvailability(
        available: false,
        reason: 'Offline dictation needs the Android app for now.',
      );
    }
    if (await modelDir() == null) {
      return const DictationAvailability(
        available: false,
        onDevice: true,
        reason: 'Download offline dictation in Voice settings first.',
      );
    }
    return const DictationAvailability(available: true, onDevice: true);
  }

  bool _continuous = false;

  @override
  set continuous(bool on) {
    _continuous = on;
    _ep?.continuous = on;
  }

  @override
  Future<DictationStart> start({
    String? language,
    bool onDeviceOnly = false,
    bool continuous = false,
  }) async {
    _continuous = continuous;
    if (language != null && !language.toLowerCase().startsWith('en')) {
      throw const DictationException(
        DictationError(
          DictationErrorKind.languageNotSupported,
          'Offline dictation understands English only.',
        ),
      );
    }
    final dir = await modelDir();
    if (dir == null) {
      throw const DictationException(
        DictationError(
          DictationErrorKind.modelMissing,
          'Download offline dictation in Voice settings first.',
        ),
      );
    }
    try {
      _asr ??= await _spawn(dir);
    } catch (e) {
      throw DictationException(
        DictationError(
          DictationErrorKind.other,
          'Offline dictation could not load: $e',
        ),
      );
    }
    _ep = _newEndpointer()..continuous = _continuous;
    _segment.clear();
    _segmentLen = 0;
    _sinceDecode = 0;
    _sub ??= _platform.events.listen(_onPlatform);
    try {
      await _platform.startMic(sampleRate: sampleRate);
    } catch (e) {
      throw const DictationException(
        DictationError(
          DictationErrorKind.audio,
          'The microphone could not be opened.',
        ),
      );
    }
    _listening = true;
    _events.add(const DictationReady());
    return const DictationStart(onDevice: true);
  }

  void _onPlatform(SpeechPlatformEvent e) {
    if (!_listening) return;
    if (e is MicErrorEvent) {
      _events.add(
        const DictationFailed(
          DictationError(
            DictationErrorKind.audio,
            'The microphone could not be read.',
          ),
        ),
      );
      unawaited(cancel());
      return;
    }
    if (e is MicChunkEvent) feed(pcm16ToFloat(e.pcm16));
  }

  /// Feeds captured audio. Public for tests.
  void feed(Float32List chunk) {
    final ep = _ep;
    if (ep == null || !_listening) return;
    final events = ep.add(chunk);
    _events.add(DictationLevel(ep.level));
    if (ep.inSegment || events.contains(EndpointEvent.segmentEnded)) {
      _segment.add(chunk);
      _segmentLen += chunk.length;
      _sinceDecode += chunk.length;
    }
    for (final ev in events) {
      switch (ev) {
        case EndpointEvent.speechStarted:
          _events.add(const DictationSpeechStarted());
        case EndpointEvent.segmentEnded:
          _commitSegment();
        case EndpointEvent.utteranceEnded:
          unawaited(stop());
        case EndpointEvent.noSpeech:
          _events.add(DictationFailed(DictationError.fromAndroid(6)));
          unawaited(cancel());
      }
    }
    final every = partialInterval.inMicroseconds * sampleRate ~/ 1000000;
    if (_listening && ep.inSegment && !_decoding && _sinceDecode >= every) {
      _sinceDecode = 0;
      _decoding = true;
      _asr!.transcribe(_joined()).then(
        (text) {
          _decoding = false;
          if (_listening && _ep?.inSegment == true && text.trim().isNotEmpty) {
            _events.add(DictationPartial(text.trim()));
          }
        },
        onError: (Object _) {
          _decoding = false;
        },
      );
    }
  }

  Float32List _joined() {
    final out = Float32List(_segmentLen);
    var o = 0;
    for (final c in _segment) {
      out.setAll(o, c);
      o += c.length;
    }
    return out;
  }

  void _commitSegment() {
    if (_segmentLen == 0) return;
    final audio = _joined();
    _segment.clear();
    _segmentLen = 0;
    _sinceDecode = 0;
    final asr = _asr!;
    _finals = _finals.then((_) async {
      try {
        final text = (await asr.transcribe(audio)).trim();
        if (text.isNotEmpty) _events.add(DictationFinal(text));
      } catch (_) {}
    });
  }

  @override
  Future<void> stop() async {
    if (!_listening) return;
    _listening = false;
    await _platform.stopMic();
    _commitSegment();
    await _finals;
    _events.add(const DictationEnded());
  }

  @override
  Future<void> cancel() async {
    final was = _listening;
    _listening = false;
    _segment.clear();
    _segmentLen = 0;
    await _platform.stopMic();
    if (was) _events.add(const DictationEnded());
  }

  /// Frees the model; the next [start] reloads it.
  Future<void> release() async {
    await cancel();
    await _asr?.close();
    _asr = null;
  }

  @override
  Future<void> dispose() async {
    await release();
    await _sub?.cancel();
    await _events.close();
  }
}

Float32List pcm16ToFloat(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final n = bytes.length ~/ 2;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Worker isolate

class MoonshineIsolate implements OfflineTranscriber {
  MoonshineIsolate._(this._send, this._receive, this._isolate);

  final SendPort _send;
  final ReceivePort _receive;
  final Isolate _isolate;
  final Map<int, Completer<String>> _calls = {};
  int _next = 0;

  static Future<OfflineTranscriber> spawn(String dir) async {
    final receive = ReceivePort();
    final isolate = await Isolate.spawn(
      _moonshineMain,
      (receive.sendPort, dir),
      debugName: 'moonshine-asr',
    );
    final ready = Completer<SendPort>();
    MoonshineIsolate? self;
    receive.listen((msg) {
      if (msg is SendPort) {
        ready.complete(msg);
      } else if (msg is String && !ready.isCompleted) {
        ready.completeError(Exception(msg));
      } else if (msg is (int, String?, String?)) {
        final c = self?._calls.remove(msg.$1);
        if (msg.$3 != null) {
          c?.completeError(Exception(msg.$3));
        } else {
          c?.complete(msg.$2 ?? '');
        }
      }
    });
    try {
      self = MoonshineIsolate._(await ready.future, receive, isolate);
      return self;
    } catch (_) {
      receive.close();
      isolate.kill();
      rethrow;
    }
  }

  @override
  Future<String> transcribe(Float32List samples) {
    final id = _next++;
    final c = _calls[id] = Completer<String>();
    _send.send((id, TransferableTypedData.fromList([samples])));
    return c.future;
  }

  @override
  Future<void> close() async {
    _send.send(null);
    for (final c in _calls.values) {
      c.completeError(Exception('closed'));
    }
    _calls.clear();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _receive.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

Future<void> _moonshineMain((SendPort, String) init) async {
  final (reply, dir) = init;
  final port = ReceivePort();
  final so.OfflineRecognizer recognizer;
  try {
    so.initBindings();
    recognizer = so.OfflineRecognizer(
      so.OfflineRecognizerConfig(
        model: so.OfflineModelConfig(
          moonshine: so.OfflineMoonshineModelConfig(
            encoder: '$dir/encoder_model.ort',
            mergedDecoder: '$dir/decoder_model_merged.ort',
          ),
          tokens: '$dir/tokens.txt',
          numThreads: 2,
          debug: false,
        ),
      ),
    );
  } catch (e) {
    reply.send('Offline dictation could not load: $e');
    port.close();
    return;
  }
  reply.send(port.sendPort);
  await for (final msg in port) {
    if (msg == null) break;
    if (msg is! (int, TransferableTypedData)) continue;
    final (id, data) = msg;
    try {
      final samples = data.materialize().asFloat32List();
      final stream = recognizer.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      recognizer.decode(stream);
      final text = recognizer.getResult(stream).text;
      stream.free();
      reply.send((id, text, null));
    } catch (e) {
      reply.send((id, null, '$e'));
    }
  }
  recognizer.free();
  port.close();
}
