import 'dart:async';
import 'dart:typed_data';

import '../speech_platform.dart';
import 'dictation_engine.dart';
import 'moonshine_dictation_engine.dart'
    show EndpointEvent, EnergyEndpointer, OfflineTranscriber, pcm16ToFloat;

/// Speech to text on the user's Tove server (`POST /api/transcribe`).
abstract interface class ServerTranscriber {
  /// The server offers transcription (capability `transcribe`) and answers.
  /// Cached by the implementation; cheap to call again.
  Future<bool> available();

  /// 16-bit mono WAV → text. Throws [DictationException].
  Future<String> transcribe(Uint8List wav, {String? language, String? prompt});
}

/// Dictation through the Tove server: the microphone is read here, cut into
/// phrases at short pauses ([EnergyEndpointer]), and each phrase is sent to
/// the server while the user keeps talking, so text appears phrase by phrase
/// and only the last phrase is left when they stop.
///
/// Measured on Indian-English test phrases (voice-models.md "Dictation
/// accuracy"): about 1 % word errors against 6 to 22 % for Moonshine tiny.
/// When [preview] has a local model (Moonshine, if downloaded), the phrase
/// being spoken is also shown as unstable text until the server's arrives.
class ServerDictationEngine implements DictationEngine {
  ServerDictationEngine({
    required this._platform,
    required this.transcriber,
    this.preview,
    EnergyEndpointer Function()? endpointer,
    this.partialInterval = const Duration(milliseconds: 700),
    this.availabilityTimeout = const Duration(seconds: 4),
    this.retryDelay = const Duration(milliseconds: 400),
  }) : _newEndpointer = endpointer ?? _defaultEndpointer;

  static EnergyEndpointer _defaultEndpointer() => EnergyEndpointer(
    segmentSilence: const Duration(milliseconds: 800),
    endSilence: const Duration(milliseconds: 2200),
    noSpeechTimeout: const Duration(seconds: 8),
    maxSegment: const Duration(seconds: 25),
  );

  final SpeechPlatform _platform;

  /// Null while no server is set up.
  final ServerTranscriber? Function() transcriber;

  /// A local model for unstable previews, or null.
  final Future<OfflineTranscriber?> Function()? preview;
  final EnergyEndpointer Function() _newEndpointer;
  final Duration partialInterval;
  final Duration availabilityTimeout;
  final Duration retryDelay;

  static const sampleRate = 16000;

  /// Audio kept from before speech is detected, so soft first sounds are
  /// not clipped.
  static const preRollSamples = sampleRate * 3 ~/ 10;

  /// The words before a phrase, as the model's context.
  static const promptChars = 400;

  final _events = StreamController<DictationEvent>.broadcast();
  StreamSubscription<SpeechPlatformEvent>? _sub;
  EnergyEndpointer? _ep;
  OfflineTranscriber? _preview;
  ServerTranscriber? _server;
  String? _language;
  bool _listening = false;
  int _generation = 0;

  final List<Float32List> _segment = [];
  int _segmentLen = 0;
  final List<Float32List> _preRoll = [];
  int _preRollLen = 0;
  int _sinceDecode = 0;
  bool _decoding = false;
  Future<void> _finals = Future.value();
  String _context = '';
  bool _failed = false;

  @override
  DictationEngineKind get kind => DictationEngineKind.server;

  @override
  Stream<DictationEvent> get events => _events.stream;

  @override
  Future<DictationAvailability> availability({
    bool onDeviceOnly = false,
  }) async {
    if (onDeviceOnly) {
      return const DictationAvailability(
        available: false,
        reason: '“On this device only” is on.',
      );
    }
    if (!_platform.isSupported) {
      return const DictationAvailability(
        available: false,
        reason: 'Server dictation needs the Android app for now.',
      );
    }
    final t = transcriber();
    if (t == null || !await _available(t)) {
      return const DictationAvailability(
        available: false,
        reason: 'The Tove server does not offer transcription.',
      );
    }
    return const DictationAvailability(available: true);
  }

  Future<bool> _available(ServerTranscriber t) =>
      t.available().timeout(availabilityTimeout, onTimeout: () => false);

  static const _unavailable = DictationException(
    DictationError(
      DictationErrorKind.unavailable,
      'Server dictation is not available right now. Using the phone’s '
      'recogniser.',
    ),
  );

  @override
  set continuous(bool on) => _ep?.continuous = on;

  @override
  Future<DictationStart> start({
    String? language,
    bool onDeviceOnly = false,
    bool continuous = false,
  }) async {
    final t = transcriber();
    if (onDeviceOnly || !_platform.isSupported || t == null) {
      throw _unavailable;
    }
    final gen = ++_generation;
    _language = language;
    _context = '';
    _failed = false;
    _finals = Future.value();
    _ep = _newEndpointer()..continuous = continuous;
    _segment.clear();
    _segmentLen = 0;
    _preRoll.clear();
    _preRollLen = 0;
    _sinceDecode = 0;
    _sub ??= _platform.events.listen(_onPlatform);
    // The microphone opens first, so nothing said while the server answers
    // is lost; it is dropped again if the server cannot transcribe.
    try {
      await _platform.startMic(sampleRate: sampleRate);
    } catch (_) {
      throw const DictationException(
        DictationError(
          DictationErrorKind.audio,
          'The microphone could not be opened.',
        ),
      );
    }
    _server = t;
    _listening = true;
    final net = await _platform.networkInfo();
    final ok = net.connected && await _available(t);
    if (gen != _generation) return const DictationStart(onDevice: false);
    if (!ok) {
      _listening = false;
      await _platform.stopMic();
      throw _unavailable;
    }
    final p = preview;
    if (p != null && _preview == null) {
      unawaited(p().then((v) => _preview ??= v, onError: (Object _) => null));
    }
    _events.add(const DictationReady());
    return const DictationStart(onDevice: false);
  }

  void _onPlatform(SpeechPlatformEvent e) {
    if (!_listening) return;
    if (e is MicErrorEvent) {
      _fail(
        const DictationError(
          DictationErrorKind.audio,
          'The microphone could not be read.',
        ),
      );
      return;
    }
    if (e is MicChunkEvent) feed(pcm16ToFloat(e.pcm16));
  }

  /// Feeds captured audio. Public for tests.
  void feed(Float32List chunk) {
    final ep = _ep;
    if (ep == null || !_listening) return;
    final wasIn = ep.inSegment;
    final events = ep.add(chunk);
    _events.add(DictationLevel(ep.level));
    if (!wasIn && ep.inSegment) {
      // Speech began: the phrase starts with the pre-roll.
      _segment.addAll(_preRoll);
      _segmentLen += _preRollLen;
      _preRoll.clear();
      _preRollLen = 0;
    }
    if (ep.inSegment || events.contains(EndpointEvent.segmentEnded)) {
      _segment.add(chunk);
      _segmentLen += chunk.length;
      _sinceDecode += chunk.length;
    } else {
      _preRoll.add(chunk);
      _preRollLen += chunk.length;
      while (_preRoll.length > 1 &&
          _preRollLen - _preRoll.first.length >= preRollSamples) {
        _preRollLen -= _preRoll.removeAt(0).length;
      }
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
          _fail(DictationError.fromAndroid(6));
      }
    }
    _maybePreview(ep);
  }

  void _maybePreview(EnergyEndpointer ep) {
    final asr = _preview;
    final every = partialInterval.inMicroseconds * sampleRate ~/ 1000000;
    if (asr == null || !ep.inSegment || _decoding || _sinceDecode < every) {
      return;
    }
    _sinceDecode = 0;
    _decoding = true;
    final gen = _generation;
    asr
        .transcribe(_joined())
        .then(
          (text) {
            _decoding = false;
            if (gen == _generation &&
                _listening &&
                _ep?.inSegment == true &&
                text.trim().isNotEmpty) {
              _events.add(DictationPartial(text.trim()));
            }
          },
          onError: (Object _) {
            _decoding = false;
          },
        );
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
    final wav = pcm16Wav(_joined(), sampleRate);
    _segment.clear();
    _segmentLen = 0;
    _sinceDecode = 0;
    final server = _server;
    if (server == null) return;
    final gen = _generation;
    _finals = _finals.then((_) async {
      if (gen != _generation || _failed) return;
      final text = await _transcribe(server, wav, gen);
      if (text == null || gen != _generation) return;
      final t = text.trim();
      if (t.isEmpty) return;
      _context = '$_context $t';
      if (_context.length > promptChars) {
        _context = _context.substring(_context.length - promptChars);
      }
      _events.add(DictationFinal(t));
    });
  }

  /// One retry: phones drop a request now and then on a moving network.
  Future<String?> _transcribe(
    ServerTranscriber server,
    Uint8List wav,
    int gen,
  ) async {
    final prompt = _context.trim().isEmpty ? null : _context.trim();
    for (var attempt = 0; ; attempt++) {
      try {
        return await server.transcribe(
          wav,
          language: _language,
          prompt: prompt,
        );
      } on DictationException catch (e) {
        final retry =
            attempt == 0 &&
            (e.error.kind == DictationErrorKind.network ||
                e.error.kind == DictationErrorKind.server ||
                e.error.kind == DictationErrorKind.busy);
        if (!retry) {
          if (gen == _generation) _fail(e.error);
          return null;
        }
        await Future<void>.delayed(retryDelay);
        if (gen != _generation) return null;
      }
    }
  }

  void _fail(DictationError error) {
    if (_failed) return;
    _failed = true;
    _events.add(DictationFailed(error));
    unawaited(cancel());
  }

  @override
  Future<void> stop() async {
    if (!_listening) return;
    _listening = false;
    final gen = _generation;
    await _platform.stopMic();
    _commitSegment();
    await _finals;
    if (gen == _generation) _events.add(const DictationEnded());
  }

  @override
  Future<void> cancel() async {
    final was = _listening;
    _listening = false;
    _generation++;
    _segment.clear();
    _segmentLen = 0;
    _preRoll.clear();
    _preRollLen = 0;
    await _platform.stopMic();
    if (was) _events.add(const DictationEnded());
  }

  /// Frees the preview model.
  Future<void> release() async {
    await _preview?.close();
    _preview = null;
  }

  @override
  Future<void> dispose() async {
    await cancel();
    await release();
    await _sub?.cancel();
    await _events.close();
  }
}

/// 16-bit little-endian mono WAV.
Uint8List pcm16Wav(Float32List samples, int sampleRate) {
  final n = samples.length;
  final out = ByteData(44 + n * 2);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      out.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  out.setUint32(4, 36 + n * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little); // PCM
  out.setUint16(22, 1, Endian.little); // mono
  out.setUint32(24, sampleRate, Endian.little);
  out.setUint32(28, sampleRate * 2, Endian.little);
  out.setUint16(32, 2, Endian.little);
  out.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  out.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    final v = (samples[i] * 32768).round().clamp(-32768, 32767);
    out.setInt16(44 + i * 2, v, Endian.little);
  }
  return out.buffer.asUint8List();
}
