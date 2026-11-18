import 'dart:async';

import 'package:flutter/foundation.dart';

import 'dictation/dictation_engine.dart';
import 'speech_platform.dart';

enum DictationStatus {
  idle,

  /// Permission prompt or engine start-up.
  starting,
  listening,

  /// Stopped; waiting for the final text.
  finishing,
  error,
}

/// What the composer shows while dictating (chat-rendering-v2 §5.3).
@immutable
class DictationState {
  const DictationState({
    this.status = DictationStatus.idle,
    this.committed = '',
    this.partial = '',
    this.level = 0,
    this.speechDetected = false,
    this.mayUseNetwork = false,
    this.engine,
    this.error,
    this.notice,
  });

  final DictationStatus status;

  /// Final text so far in this session.
  final String committed;

  /// Unstable text after [committed]; draw it in `textMuted`.
  final String partial;

  /// Input level 0–1 for the pulsing ring.
  final double level;
  final bool speechDetected;

  /// The system default recogniser is in use and may send audio to a server.
  /// Show a small "may use network" hint.
  final bool mayUseNetwork;
  final DictationEngineKind? engine;
  final DictationError? error;

  /// Non-error information, e.g. why another engine was used.
  final String? notice;

  bool get isActive =>
      status == DictationStatus.starting ||
      status == DictationStatus.listening ||
      status == DictationStatus.finishing;

  /// [committed] and [partial] joined: the text to show in the field.
  String get text => [committed, partial].where((s) => s.isNotEmpty).join(' ');

  DictationState copyWith({
    DictationStatus? status,
    String? committed,
    String? partial,
    double? level,
    bool? speechDetected,
    bool? mayUseNetwork,
    DictationEngineKind? engine,
    DictationError? error,
    bool clearError = false,
    String? notice,
  }) => DictationState(
    status: status ?? this.status,
    committed: committed ?? this.committed,
    partial: partial ?? this.partial,
    level: level ?? this.level,
    speechDetected: speechDetected ?? this.speechDetected,
    mayUseNetwork: mayUseNetwork ?? this.mayUseNetwork,
    engine: engine ?? this.engine,
    error: clearError ? null : (error ?? this.error),
    notice: notice ?? this.notice,
  );
}

/// Dictation into the composer.
///
/// The composer calls [toggle] from the mic button, listens to the state and
/// writes `state.text` after the text that was in the field when dictation
/// started. [onFinished] delivers the final text once.
class DictationController extends ChangeNotifier
    implements ValueListenable<DictationState> {
  DictationController({
    required this._platform,
    required this._engines,
    String? Function()? language,
    bool Function()? onDeviceOnly,
    this.beforeListening,
    this.finishTimeout = const Duration(seconds: 12),
  }) : _language = language ?? (() => null),
       _onDeviceOnly = onDeviceOnly ?? (() => false);

  final SpeechPlatform _platform;

  /// Engines in preference order: the chosen one first, then fallbacks.
  final List<DictationEngine> Function() _engines;
  final String? Function() _language;
  final bool Function() _onDeviceOnly;

  /// Runs before the mic opens (e.g. stop read-aloud).
  final Future<void> Function()? beforeListening;

  /// [stop] gives up waiting for the final result after this. Server
  /// engines wait for the last phrase's transcription, so it is generous.
  final Duration finishTimeout;

  /// Restarts of an engine that keeps ending at pauses while [continuous]
  /// (Android's recogniser); a few quick ends in a row stop the session.
  static const maxQuickRestarts = 3;
  static const quickEnd = Duration(milliseconds: 600);

  DictationState _state = const DictationState();
  DictationEngine? _engine;
  StreamSubscription<DictationEvent>? _sub;
  Timer? _finishTimer;
  bool _liveMode = false;
  int _session = 0;
  bool _continuous = false;
  bool _stopWhenStarted = false;
  int _quickRestarts = 0;
  DateTime _engineStarted = DateTime.fromMillisecondsSinceEpoch(0);
  final _finished = StreamController<String>.broadcast();

  @override
  DictationState get value => _state;

  /// Final text of each session that produced some. Broadcast.
  Stream<String> get onFinished => _finished.stream;

  void _emit(DictationState s) {
    _state = s;
    notifyListeners();
  }

  set liveModeActive(bool on) {
    _liveMode = on;
    if (on && _state.isActive) unawaited(cancel());
  }

  /// Engines usable now (for settings).
  Future<DictationAvailability> availability() async {
    for (final e in _engines()) {
      final a = await e.availability(onDeviceOnly: _onDeviceOnly());
      if (a.available) return a;
    }
    final first = _engines().firstOrNull;
    return first == null
        ? const DictationAvailability(available: false, reason: 'No dictation engine.')
        : await first.availability(onDeviceOnly: _onDeviceOnly());
  }

  Future<void> toggle() => _state.isActive ? stop() : start();

  /// Lets the first engine look itself up (the server's capability) before
  /// the mic is pressed. Never throws.
  Future<void> warmUp() async {
    try {
      await _engines().firstOrNull?.availability(onDeviceOnly: _onDeviceOnly());
    } catch (_) {}
  }

  /// Keep listening through pauses until [stop] (press and hold,
  /// hands-free). Can change while listening: a tap that became a hold.
  bool get continuous => _continuous;
  set continuous(bool on) {
    _continuous = on;
    _engine?.continuous = on;
  }

  /// Starts listening. Errors end up in `state.error`, never thrown.
  Future<void> start({bool continuous = false}) async {
    if (_state.isActive || _liveMode) return;
    final session = ++_session;
    _continuous = continuous;
    _stopWhenStarted = false;
    _quickRestarts = 0;
    _emit(const DictationState(status: DictationStatus.starting));

    // Permission (RECORD_AUDIO is already declared for live voice).
    var perm = await _platform.micPermission();
    if (perm == MicPermission.denied) {
      perm = await _platform.requestMicPermission();
    }
    if (session != _session) return;
    if (perm == MicPermission.permanentlyDenied) {
      return _fail(
        const DictationError(
          DictationErrorKind.permissionPermanentlyDenied,
          'Microphone access is off. Allow it in Settings to dictate.',
        ),
      );
    }
    if (perm == MicPermission.denied) {
      return _fail(
        const DictationError(
          DictationErrorKind.permissionDenied,
          'Dictation needs the microphone.',
        ),
      );
    }

    await beforeListening?.call();
    if (session != _session) return;

    DictationError? firstError;
    String? notice;
    final candidates = _engines();
    for (var i = 0; i < candidates.length; i++) {
      final engine = candidates[i];
      await _sub?.cancel();
      _sub = engine.events.listen((e) => _onEvent(session, e));
      try {
        final info = await engine.start(
          language: _language(),
          onDeviceOnly: _onDeviceOnly(),
          continuous: _continuous,
        );
        if (session != _session) {
          await engine.cancel();
          return;
        }
        _engine = engine;
        _engineStarted = DateTime.now();
        _emit(
          _state.copyWith(
            status: DictationStatus.listening,
            engine: engine.kind,
            mayUseNetwork: info.mayUseNetwork,
            notice: notice,
          ),
        );
        if (_stopWhenStarted) unawaited(stop());
        return;
      } on DictationException catch (e) {
        firstError ??= e.error;
        // Try the next engine only for "this engine can't run" errors.
        final recoverable =
            e.error.kind == DictationErrorKind.modelMissing ||
            e.error.kind == DictationErrorKind.unavailable ||
            e.error.kind == DictationErrorKind.languageNotSupported;
        if (!recoverable) break;
        if (i + 1 < candidates.length) notice = e.error.message;
      }
    }
    await _sub?.cancel();
    _sub = null;
    if (session == _session) {
      _fail(firstError ?? DictationError.fromAndroid(-1));
    }
  }

  /// Stops listening; the final text follows. While still starting, it
  /// stops as soon as the engine runs, so words already captured are kept.
  Future<void> stop() async {
    if (_state.status == DictationStatus.starting) {
      _stopWhenStarted = true;
      return;
    }
    final engine = _engine;
    if (engine == null || !_state.isActive) return;
    _emit(_state.copyWith(status: DictationStatus.finishing, level: 0));
    final session = _session;
    _finishTimer?.cancel();
    _finishTimer = Timer(finishTimeout, () {
      if (session == _session && _state.status == DictationStatus.finishing) {
        _end(session);
      }
    });
    await engine.stop();
  }

  /// Stops and drops the text.
  Future<void> cancel() async {
    final engine = _engine;
    _session++;
    _finishTimer?.cancel();
    _engine = null;
    await _sub?.cancel();
    _sub = null;
    await engine?.cancel();
    _emit(const DictationState());
  }

  /// Clears an error so the mic shows idle again.
  void dismissError() {
    if (_state.status == DictationStatus.error) _emit(const DictationState());
  }

  void _onEvent(int session, DictationEvent e) {
    if (session != _session) return;
    switch (e) {
      case DictationReady():
        break;
      case DictationSpeechStarted():
        _emit(_state.copyWith(speechDetected: true));
      case DictationLevel(:final level):
        if (_state.status == DictationStatus.listening) {
          _emit(_state.copyWith(level: level));
        }
      case DictationPartial(:final text):
        _emit(_state.copyWith(partial: text, speechDetected: true));
      case DictationFinal(:final text):
        final committed = [
          _state.committed,
          text,
        ].where((s) => s.isNotEmpty).join(' ');
        _emit(_state.copyWith(committed: committed, partial: ''));
      case DictationFailed(:final error):
        // Errors while stopping (ERROR_CLIENT after stop) are noise when we
        // already have text.
        if (_state.status == DictationStatus.finishing &&
            (_state.committed.isNotEmpty || _state.partial.isNotEmpty)) {
          return;
        }
        // A pause in a held session: the recogniser starts again.
        if (_restartable && _quietError(error)) return;
        _fail(error);
      case DictationEnded():
        if (_restartable) {
          unawaited(_restart(session));
        } else if (_state.status != DictationStatus.error) {
          _end(session);
        }
    }
  }

  bool get _restartable =>
      _continuous &&
      _state.status == DictationStatus.listening &&
      _engine != null &&
      _quickRestarts < maxQuickRestarts;

  static bool _quietError(DictationError e) =>
      e.kind == DictationErrorKind.noMatch ||
      e.kind == DictationErrorKind.speechTimeout;

  /// The engine ended at a pause while continuous: keep what it heard and
  /// start it again.
  Future<void> _restart(int session) async {
    final engine = _engine;
    if (engine == null) return;
    final quick = DateTime.now().difference(_engineStarted) < quickEnd;
    _quickRestarts = quick ? _quickRestarts + 1 : 0;
    // A partial that never became final is what the user saw: keep it.
    if (_state.partial.isNotEmpty) {
      _emit(
        _state.copyWith(
          committed: _state.text,
          partial: '',
        ),
      );
    }
    try {
      await engine.start(
        language: _language(),
        onDeviceOnly: _onDeviceOnly(),
        continuous: true,
      );
      _engineStarted = DateTime.now();
      if (session != _session) await engine.cancel();
    } on DictationException {
      if (session == _session) _end(session);
    }
  }

  void _end(int session) {
    _finishTimer?.cancel();
    // A partial that never became final is kept: it is what the user saw.
    final text = _state.text.trim();
    _engine = null;
    _emit(DictationState(committed: text, engine: _state.engine));
    if (text.isNotEmpty) _finished.add(text);
  }

  void _fail(DictationError error) {
    _finishTimer?.cancel();
    final engine = _engine;
    _engine = null;
    _session++;
    unawaited(_sub?.cancel());
    _sub = null;
    unawaited(engine?.cancel());
    _emit(DictationState(status: DictationStatus.error, error: error, engine: _state.engine));
  }

  @override
  void dispose() {
    _session++;
    _finishTimer?.cancel();
    _sub?.cancel();
    unawaited(_engine?.cancel());
    _finished.close();
    super.dispose();
  }
}
