import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'speakable_text.dart';
import 'speech_platform.dart';
import 'tts/tts_engine.dart';

enum TtsStatus { idle, loading, playing, paused, error }

enum TtsPauseReason {
  user,

  /// A call, alarm or another app took audio focus.
  audioFocus,

  /// Headphones unplugged.
  noisy,

  /// Live voice started. Resume is blocked until it ends; reading does not
  /// restart by itself afterwards.
  liveMode,
}

/// What the read-aloud mini player shows.
@immutable
class TtsPlaybackState {
  const TtsPlaybackState({
    this.status = TtsStatus.idle,
    this.messageId,
    this.text = '',
    this.sentences = const [],
    this.sentenceIndex = 0,
    this.speed = 1.0,
    this.engine,
    this.voice,
    this.pauseReason,
    this.error,
    this.fallbackReason,
    this.lastRtf,
    this.meanRtf,
    this.firstAudioLatency,
  });

  final TtsStatus status;

  /// The message being read, for the gutter marker.
  final String? messageId;

  /// The speakable text; sentence offsets point into it.
  final String text;
  final List<SpeakableSentence> sentences;

  /// The sentence being heard.
  final int sentenceIndex;
  final double speed;
  final TtsEngineKind? engine;
  final TtsVoice? voice;
  final TtsPauseReason? pauseReason;
  final String? error;

  /// Set when the system voice stands in for Kokoro (e.g. not downloaded).
  final String? fallbackReason;

  /// Real-time factor of the last synthesised sentence, and the mean for this
  /// reply (Kokoro only).
  final double? lastRtf;
  final double? meanRtf;

  /// From the request to the first audio being queued.
  final Duration? firstAudioLatency;

  bool get isActive =>
      status == TtsStatus.loading ||
      status == TtsStatus.playing ||
      status == TtsStatus.paused;

  SpeakableSentence? get currentSentence =>
      sentenceIndex < sentences.length ? sentences[sentenceIndex] : null;

  /// Position in the text, 0–1, by characters already heard.
  double get progress {
    if (text.isEmpty || sentences.isEmpty) return 0;
    if (sentenceIndex >= sentences.length) return 1;
    return (sentences[sentenceIndex].start / text.length).clamp(0.0, 1.0);
  }

  /// The first words, for the capsule's caption.
  String get caption {
    final t = text.trim();
    return t.length <= 60 ? t : '${t.substring(0, 57).trimRight()}…';
  }

  TtsPlaybackState copyWith({
    TtsStatus? status,
    String? messageId,
    String? text,
    List<SpeakableSentence>? sentences,
    int? sentenceIndex,
    double? speed,
    TtsEngineKind? engine,
    TtsVoice? voice,
    TtsPauseReason? pauseReason,
    bool clearPauseReason = false,
    String? error,
    bool clearError = false,
    String? fallbackReason,
    double? lastRtf,
    double? meanRtf,
    Duration? firstAudioLatency,
  }) => TtsPlaybackState(
    status: status ?? this.status,
    messageId: messageId ?? this.messageId,
    text: text ?? this.text,
    sentences: sentences ?? this.sentences,
    sentenceIndex: sentenceIndex ?? this.sentenceIndex,
    speed: speed ?? this.speed,
    engine: engine ?? this.engine,
    voice: voice ?? this.voice,
    pauseReason: clearPauseReason ? null : (pauseReason ?? this.pauseReason),
    error: clearError ? null : (error ?? this.error),
    fallbackReason: fallbackReason ?? this.fallbackReason,
    lastRtf: lastRtf ?? this.lastRtf,
    meanRtf: meanRtf ?? this.meanRtf,
    firstAudioLatency: firstAudioLatency ?? this.firstAudioLatency,
  );
}

/// The engine and voice to use for the next reply.
class TtsSelection {
  const TtsSelection(this.engine, {this.voice, this.fallback, this.fallbackReason});

  final TtsEngine engine;
  final TtsVoice? voice;

  /// Used when [engine] fails to prepare (e.g. Kokoro cannot load).
  final TtsEngine? fallback;

  /// Shown when [engine] is already a stand-in for the chosen one.
  final String? fallbackReason;
}

/// Read-aloud: turns a reply into sentences, synthesises ahead of playback,
/// and plays them in order with pause, resume, stop, speed and audio focus.
///
/// Never speaks while [liveModeActive] (chat-rendering-v2 §5.4).
class TtsController extends ChangeNotifier
    implements ValueListenable<TtsPlaybackState> {
  TtsController({
    required this._platform,
    required this._select,
    double speed = 1.0,
    this.lookahead = 2,
    this.autoReadReplies = false,
    this.idleRelease = const Duration(minutes: 3),
  }) : _state = TtsPlaybackState(speed: speed) {
    _events = _platform.events.listen(_onPlatformEvent);
  }

  final SpeechPlatform _platform;
  final Future<TtsSelection> Function() _select;

  /// Sentences synthesised ahead of the one being heard.
  final int lookahead;

  /// Reads each finished reply when true (the "Read replies aloud" switch).
  bool autoReadReplies;

  /// Kokoro's model is released after this long idle, to free ~800 MB.
  final Duration idleRelease;

  late final StreamSubscription<SpeechPlatformEvent> _events;
  TtsPlaybackState _state;
  TtsEngine? _engine;
  TtsVoice? _voice;
  int _gen = 0;
  int _heard = 0; // sentences fully heard
  bool _restartOnResume = false;
  bool _liveMode = false;
  bool _focusHeld = false;
  Completer<void>? _advanced;
  Timer? _idleTimer;
  final List<double> _rtfs = [];
  final Set<TtsEngine> _used = {};

  final StreamController<TtsPlaybackState> _stream =
      StreamController.broadcast();

  @override
  TtsPlaybackState get value => _state;

  /// Every state change, for listeners that prefer a stream.
  Stream<TtsPlaybackState> get states => _stream.stream;

  void _emit(TtsPlaybackState s) {
    _state = s;
    notifyListeners();
    if (!_stream.isClosed) _stream.add(s);
  }

  // ---- live mode -----------------------------------------------------------

  bool get liveModeActive => _liveMode;

  /// Wire to the live call state. Starting live voice pauses read-aloud and
  /// blocks new reads; the player stays paused when live voice ends.
  set liveModeActive(bool on) {
    if (_liveMode == on) return;
    _liveMode = on;
    if (on) unawaited(_pauseForLive());
  }

  Future<void> _pauseForLive() async {
    if (_state.status == TtsStatus.paused) {
      _emit(_state.copyWith(pauseReason: TtsPauseReason.liveMode));
    } else {
      await pause(reason: TtsPauseReason.liveMode);
    }
    // Live voice owns audio focus now.
    await _abandonFocus();
  }

  // ---- public API ----------------------------------------------------------

  /// Reads a markdown reply. Returns false when nothing was started (live
  /// mode, or nothing speakable).
  Future<bool> speak(String markdown, {String? messageId}) =>
      _start(SpeakableText.fromMarkdown(markdown), messageId);

  /// Reads plain text.
  Future<bool> speakPlain(String text, {String? messageId}) =>
      _start(SpeakableText.fromPlain(text), messageId);

  /// Call when a reply finishes streaming in text mode.
  Future<void> onReplyFinished(String messageId, String markdown) async {
    if (!autoReadReplies || _liveMode) return;
    await speak(markdown, messageId: messageId);
  }

  /// Read aloud, or stop when that message is already being read.
  Future<void> toggle(String markdown, {required String messageId}) async {
    if (_state.isActive && _state.messageId == messageId) {
      await stop();
    } else {
      await speak(markdown, messageId: messageId);
    }
  }

  Future<void> pause({TtsPauseReason reason = TtsPauseReason.user}) async {
    if (_state.status != TtsStatus.playing && _state.status != TtsStatus.loading) {
      return;
    }
    final engine = _engine;
    if (engine == null) return;
    if (engine.resumesMidSentence && _state.status == TtsStatus.playing) {
      await engine.pause();
    } else {
      // Replay the interrupted sentence on resume.
      _gen++;
      _restartOnResume = true;
      await engine.stop();
    }
    _emit(_state.copyWith(status: TtsStatus.paused, pauseReason: reason));
  }

  Future<void> resume() async {
    if (_state.status != TtsStatus.paused || _liveMode) return;
    final engine = _engine;
    if (engine == null) return;
    if (!await _requestFocus()) {
      _emit(_state.copyWith(error: _focusRefused));
      return;
    }
    _emit(_state.copyWith(status: TtsStatus.playing, clearPauseReason: true, clearError: true));
    if (_restartOnResume) {
      _restartOnResume = false;
      _gen++;
      await engine.stop();
      unawaited(_pipeline(_gen, _heard, DateTime.now()));
    } else {
      await engine.resume();
    }
  }

  Future<void> togglePause() =>
      _state.status == TtsStatus.paused ? resume() : pause();

  Future<void> stop() async {
    _gen++;
    _restartOnResume = false;
    _advanced?.complete();
    _advanced = null;
    final engine = _engine;
    if (engine != null) await engine.stop();
    await _abandonFocus();
    if (_state.status != TtsStatus.idle || _state.messageId != null) {
      _emit(TtsPlaybackState(speed: _state.speed));
    }
    _armIdleRelease();
  }

  /// Changes speed. While reading, the current sentence restarts at the new
  /// speed (already-synthesised audio cannot be re-timed).
  Future<void> setSpeed(double speed) async {
    final s = speed.clamp(0.5, 2.0).toDouble();
    if (s == _state.speed) return;
    _emit(_state.copyWith(speed: s));
    final engine = _engine;
    if (engine == null) return;
    if (_state.status == TtsStatus.playing) {
      _gen++;
      await engine.stop();
      unawaited(_pipeline(_gen, _heard, DateTime.now()));
    } else if (_state.status == TtsStatus.paused) {
      _restartOnResume = true;
    }
  }

  /// The capsule's speed chip: 1× → 1.25× → 1.5× → 0.8× → 1×.
  Future<void> cycleSpeed() {
    const steps = [1.0, 1.25, 1.5, 0.8];
    final i = steps.indexWhere((s) => (s - _state.speed).abs() < 0.01);
    return setSpeed(steps[(i + 1) % steps.length]);
  }

  /// Frees loaded models now (e.g. when the app goes to the background).
  Future<void> releaseEngines() async {
    if (_state.isActive) return;
    for (final e in _used) {
      await e.release();
    }
    _used.clear();
  }

  // ---- pipeline ------------------------------------------------------------

  Future<bool> _start(SpeakableText speakable, String? messageId) async {
    if (_liveMode) return false;
    await stop();
    if (speakable.isEmpty) return false;
    _idleTimer?.cancel();
    final gen = _gen;
    final started = DateTime.now();
    _heard = 0;
    _rtfs.clear();
    _emit(
      TtsPlaybackState(
        status: TtsStatus.loading,
        messageId: messageId,
        text: speakable.text,
        sentences: speakable.sentences,
        speed: _state.speed,
      ),
    );

    TtsSelection sel;
    try {
      sel = await _select();
    } catch (e) {
      _fail(gen, 'Read aloud is not available: $e');
      return false;
    }
    var engine = sel.engine;
    var voice = sel.voice;
    var fallbackReason = sel.fallbackReason;
    try {
      await engine.prepare();
    } catch (e) {
      final fb = sel.fallback;
      if (fb == null) {
        _fail(gen, e is TtsException ? e.message : 'Read aloud failed: $e');
        return false;
      }
      engine = fb;
      voice = null;
      fallbackReason = e is TtsException ? e.message : '$e';
      try {
        await engine.prepare();
      } catch (e2) {
        _fail(gen, 'Read aloud failed: $e2');
        return false;
      }
    }
    if (gen != _gen) return false;
    voice ??= await engine.defaultVoice();
    _engine = engine;
    _voice = voice;
    _used.add(engine);

    if (!await _requestFocus()) {
      _fail(gen, _focusRefused);
      return false;
    }
    if (gen != _gen) return false;
    _emit(
      _state.copyWith(
        engine: engine.kind,
        voice: voice,
        fallbackReason: fallbackReason,
      ),
    );
    unawaited(_pipeline(gen, 0, started));
    return true;
  }

  Future<void> _pipeline(int gen, int from, DateTime started) async {
    final engine = _engine!;
    final sentences = _state.sentences;
    var firstQueued = false;
    for (var i = from; i < sentences.length; i++) {
      // Back-pressure: stay at most [lookahead] sentences ahead.
      while (gen == _gen && i - _heard > lookahead) {
        final c = _advanced ??= Completer<void>();
        await c.future;
      }
      if (gen != _gen) return;
      final TtsUtterance u;
      try {
        u = await engine.synthesize(
          sentences[i].text,
          voice: _voice,
          speed: _state.speed,
        );
      } catch (e) {
        _fail(gen, e is TtsException ? e.message : 'Speech synthesis failed: $e');
        return;
      }
      if (gen != _gen) return;
      final rtf = u.rtf;
      if (rtf != null) _rtfs.add(rtf);
      if (!firstQueued) {
        firstQueued = true;
        _emit(
          _state.copyWith(
            status: _state.status == TtsStatus.paused ? null : TtsStatus.playing,
            sentenceIndex: from,
            lastRtf: rtf,
            meanRtf: _mean(),
            firstAudioLatency: from == 0 ? DateTime.now().difference(started) : null,
          ),
        );
      } else if (rtf != null) {
        _emit(_state.copyWith(lastRtf: rtf, meanRtf: _mean()));
      }
      final index = i;
      engine.play(u).then(
        (ok) {
          if (gen != _gen || !ok) return;
          _onHeard(gen, index);
        },
        onError: (Object e) =>
            _fail(gen, e is TtsException ? e.message : 'Playback failed: $e'),
      );
    }
  }

  double? _mean() => _rtfs.isEmpty
      ? null
      : _rtfs.reduce((a, b) => a + b) / _rtfs.length;

  void _onHeard(int gen, int index) {
    _heard = math.max(_heard, index + 1);
    final c = _advanced;
    _advanced = null;
    c?.complete();
    if (_heard >= _state.sentences.length) {
      _gen++;
      unawaited(_abandonFocus());
      _emit(TtsPlaybackState(speed: _state.speed, lastRtf: _state.lastRtf, meanRtf: _state.meanRtf));
      _armIdleRelease();
      return;
    }
    _emit(_state.copyWith(sentenceIndex: _heard));
  }

  void _fail(int gen, String message) {
    if (gen != _gen) return;
    _gen++;
    unawaited(_engine?.stop());
    unawaited(_abandonFocus());
    _emit(_state.copyWith(status: TtsStatus.error, error: message));
    _armIdleRelease();
  }

  void _armIdleRelease() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleRelease, () => unawaited(releaseEngines()));
  }

  // ---- audio focus ---------------------------------------------------------

  static const _focusRefused =
      "Can't read aloud during a call or while another app holds the audio.";

  Future<bool> _requestFocus() async {
    if (_focusHeld) return true;
    try {
      _focusHeld = await _platform.requestAudioFocus(mayDuck: false);
    } catch (_) {
      _focusHeld = true; // No native focus API: do not block reading.
    }
    return _focusHeld;
  }

  Future<void> _abandonFocus() async {
    if (!_focusHeld) return;
    _focusHeld = false;
    try {
      await _platform.abandonAudioFocus();
    } catch (_) {}
  }

  void _onPlatformEvent(SpeechPlatformEvent e) {
    switch (e) {
      case AudioFocusEvent(change: AudioFocusChange.lossTransient):
        unawaited(pause(reason: TtsPauseReason.audioFocus));
      case AudioFocusEvent(change: AudioFocusChange.loss):
        // Another app took over: stay paused until the user resumes.
        _focusHeld = false;
        unawaited(pause(reason: TtsPauseReason.user));
      case AudioFocusEvent(change: AudioFocusChange.gain):
        if (_state.status == TtsStatus.paused &&
            _state.pauseReason == TtsPauseReason.audioFocus) {
          unawaited(resume());
        }
      case AudioFocusEvent(change: AudioFocusChange.duck):
        break; // The native player lowers its own volume.
      case AudioBecomingNoisyEvent():
        unawaited(pause(reason: TtsPauseReason.noisy));
      default:
        break;
    }
  }

  @override
  void dispose() {
    _gen++;
    _idleTimer?.cancel();
    _events.cancel();
    for (final e in _used) {
      unawaited(e.release());
    }
    unawaited(_abandonFocus());
    _stream.close();
    super.dispose();
  }
}
