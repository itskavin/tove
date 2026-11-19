import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../bridge/bridge_api.dart';
import '../config.dart';
import '../platform/call_platform.dart';
import '../rtc/voice_transport.dart';
import 'delegations.dart';
import 'farewell.dart';
import 'models.dart';

enum CallPhase { idle, connecting, live, failed }

/// Why a call failed, so the UI can say it plainly (spec §9.7, API.md).
enum CallErrorKind {
  /// GPT-Live's usage limit was reached (start error or data-channel error).
  usageLimit,

  /// The voice service's ChatGPT login expired on the server.
  loginExpired,

  /// The app's access key was rejected.
  unauthorized,
  microphone,

  /// The network or the audio path failed.
  network,
  other,
}

/// What a finished call leaves behind, for importing into the thread.
class CallSummary {
  CallSummary({
    required this.session,
    required this.conversationId,
    required this.linked,
    required this.started,
    required this.ended,
    required this.transcript,
    required this.tasks,
    this.errorKind,
  });

  /// The bridge session id, or null when the call never got one.
  final String? session;

  /// The chat the call belonged to (whether or not the bridge linked it).
  final String? conversationId;

  /// The bridge linked the call to [conversationId] and saves its task
  /// results itself.
  final bool linked;
  final DateTime started;
  final DateTime ended;
  final List<TranscriptEntry> transcript;
  final List<TaskEntry> tasks;
  final CallErrorKind? errorKind;
}

enum ConnectStep { microphone, nativeCall, offer, server, network }

/// What keeps the call running when the app leaves the screen.
enum BackgroundSupport {
  /// Desktop: the window keeps running.
  notNeeded,

  /// Android foreground service or iOS CallKit is active.
  native,

  /// Nothing keeps it alive (web, or the native side failed).
  limited,
}

/// Owns one call at a time: microphone, native call service, peer connection,
/// SDP exchange, transcript, delegated tasks and teardown.
///
/// Order of a call:
///  1. open the microphone (permission prompt),
///  2. `startCall` on the native side (Android foreground service needs the
///     permission first and the app visible; CallKit may take a moment),
///  3. create the offer and gather ICE,
///  4. `POST /api/session`, apply the answer,
///  5. live on `session.started`.
/// Ending at any step releases everything, and a session the server creates
/// after the user already hung up is stopped as soon as its id arrives.
class CallController extends ChangeNotifier {
  CallController({
    required this.apiFactory,
    required this.transportFactory,
    required this.platform,
    required this.voice,
    this.conversationId,
    this.timings = const CallTimings(),
    bool? desktop,
  }) : _desktop =
           desktop ??
           (!kIsWeb &&
               (defaultTargetPlatform == TargetPlatform.linux ||
                   defaultTargetPlatform == TargetPlatform.macOS ||
                   defaultTargetPlatform == TargetPlatform.windows)) {
    platform.setHandlers(onMute: _nativeMute, onEnd: _nativeEnd);
  }

  final BridgeApi Function() apiFactory;
  final VoiceTransportFactory transportFactory;
  final CallPlatform platform;
  final String Function() voice;

  /// The chat to link the call to (API v2 `conversation_id`), or null.
  final String? Function()? conversationId;

  /// The user's approximate location for tasks, when they share it (set by
  /// the app with the chat's location source).
  Map<String, Object?>? Function()? location;
  final CallTimings timings;
  final bool _desktop;

  CallPhase _phase = CallPhase.idle;
  ConnectStep _step = ConnectStep.microphone;
  String? _error;
  CallErrorKind? _errorKind;
  Duration? _retryAfter;
  String? _notice;
  final _ended = StreamController<CallSummary>.broadcast(sync: true);
  bool _muted = false;
  bool _speaker = true;
  BackgroundSupport _background = BackgroundSupport.notNeeded;
  _Call? _call;
  int _ids = 0;
  TranscriptEntry? _userTurn, _hermesTurn;

  /// Every entry of this call that has a GPT-Live turn id, by that id.
  final Map<String, TranscriptEntry> _byTurn = {};

  /// Entries whose own `turn.created` has arrived.
  final Set<TranscriptEntry> _announced = {};
  final List<TranscriptEntry> transcript = [];
  final List<TaskEntry> tasks = [];

  /// Live audio levels from WebRTC stats; [AudioLevels.unknown] when the
  /// platform does not report them.
  final ValueNotifier<AudioLevels> levels = ValueNotifier(AudioLevels.silent);

  CallPhase get phase => _phase;
  ConnectStep get step => _step;
  String? get error => _error;

  /// Set together with [error].
  CallErrorKind? get errorKind => _errorKind;

  /// When GPT-Live says how long its usage limit lasts.
  Duration? get retryAfter => _retryAfter;

  /// One event per call that got past the microphone, when it ends.
  Stream<CallSummary> get ended => _ended.stream;

  /// The bridge session of the current call, once known.
  String? get session => _call?.session;

  /// The chat the current call belongs to (linked or not), or null.
  String? get callConversationId => _call?.conversationId;

  /// Non-fatal problem worth showing (native integration, audio route, voice
  /// model errors).
  String? get notice => _notice;
  bool get muted => _muted;
  bool get speakerOn => _speaker;
  bool get supportsSpeakerRoute =>
      _call?.transport.supportsSpeakerRoute ?? false;
  BackgroundSupport get background => _background;
  String? get backgroundNote => platform.backgroundNote;
  bool get inCall => _phase == CallPhase.connecting || _phase == CallPhase.live;
  bool get userSpeaking => _userTurn != null;
  bool get hermesSpeaking => _hermesTurn != null;
  int get activeTasks => tasks.where((t) => t.active).length;

  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void dismissNotice() {
    _notice = null;
    if (_phase == CallPhase.failed) _phase = CallPhase.idle;
    _error = null;
    _errorKind = null;
    _notify();
  }

  // ---- warm start (round 8) ----------------------------------------------

  BridgeApi? _warmApi;
  DateTime? _warmAt;

  /// How often [prewarm] pings the bridge, and how long its client is reused.
  static const warmEvery = Duration(seconds: 45);
  static const warmKeep = Duration(seconds: 150);

  /// Readies a likely call (the app opened, a finger on the composer or the
  /// live button, a swipe up starting): the bridge prepares a codex session
  /// (`POST /api/session/warm`: free, no realtime session, no quota) and this
  /// client's connection (DNS, TLS) is opened now and reused by [start]. The
  /// microphone is not touched. At most every [warmEvery]; errors (an older
  /// bridge's 404, offline) are ignored.
  void prewarm() {
    if (inCall || _disposed) return;
    final now = DateTime.now();
    final at = _warmAt;
    if (at != null && now.difference(at) < warmEvery) return;
    if (at != null && now.difference(at) > warmKeep) {
      _warmApi?.close();
      _warmApi = null;
    }
    _warmAt = now;
    final api = _warmApi ??= apiFactory();
    unawaited(api.warmSession().catchError((_) => false));
  }

  BridgeApi _takeApi() {
    final api = _warmApi, at = _warmAt;
    _warmApi = null;
    // The call spends the bridge's warm session, so the next touch must warm
    // again rather than wait out [warmEvery] (round 8 ship: back-to-back calls
    // started cold).
    _warmAt = null;
    if (api != null && at != null && DateTime.now().difference(at) < warmKeep) {
      return api;
    }
    api?.close();
    return apiFactory();
  }

  /// Milliseconds from [start] to each connect stage of the newest call
  /// (`microphone`, `native`, `offer`, `session`, `answer`, `live`), also
  /// logged as `ToveLiveConnect {…}` once live (logcat on Android).
  Map<String, int> get connectTiming => Map.unmodifiable(_timing);
  final Map<String, int> _timing = {};
  final Stopwatch _connectClock = Stopwatch();

  void _mark(String stage) =>
      _timing[stage] = _connectClock.elapsedMilliseconds;

  /// The native call starts alongside the offer on Android (its foreground
  /// service needs only the microphone permission, granted by then); iOS's
  /// CallKit must own the audio session before WebRTC audio starts.
  static bool get _parallelNative =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> start() async {
    if (inCall) return;
    _timing.clear();
    _connectClock
      ..reset()
      ..start();
    final c = _Call(_takeApi(), transportFactory());
    _call = c;
    _phase = CallPhase.connecting;
    _step = ConnectStep.microphone;
    _error = null;
    _errorKind = null;
    _retryAfter = null;
    c.conversationId = conversationId?.call();
    _notice = null;
    _muted = false;
    _speaker = true;
    _background = _desktop
        ? BackgroundSupport.notNeeded
        : BackgroundSupport.limited;
    transcript.clear();
    _byTurn.clear();
    _announced.clear();
    tasks.removeWhere((t) => !t.active);
    _userTurn = _hermesTurn = null;
    levels.value = AudioLevels.silent;
    _notify();

    c.subs.add(c.transport.events.listen((m) => _onEvent(c, m)));
    c.subs.add(c.transport.link.listen((l) => _onLink(c, l)));

    try {
      await _runStep(c, ConnectStep.microphone, () {
        return c.transport.openMicrophone().timeout(
          timings.microphone,
          onTimeout: () =>
              throw const MicrophoneException('The microphone did not open'),
        );
      });

      _mark('microphone');

      Future<void>? native;
      if (_parallelNative) {
        native = _startNative(c).whenComplete(() => _mark('native'));
      } else {
        _step = ConnectStep.nativeCall;
        _notify();
        await _startNative(c);
        _mark('native');
        _check(c);
      }

      final offer = await _runStep(
        c,
        ConnectStep.offer,
        () => c.transport.createOffer(iceTimeout: timings.iceGathering),
      );
      _mark('offer');

      _step = ConnectStep.server;
      _notify();
      final pending = c.api.createSession(
        offer: offer,
        voice: voice(),
        conversationId: c.conversationId,
        timeout: timings.session,
      );
      c.pendingSession = pending;
      final answer = await pending;
      _mark('session');
      c.session = answer.session;
      c.linked =
          c.conversationId != null && answer.conversationId == c.conversationId;
      c.pendingSession = null;
      _check(c);

      c.runner = DelegationRunner(
        api: c.api,
        session: answer.session,
        send: c.transport.send,
        tasks: tasks,
        onChanged: _notify,
        conversationId: c.conversationId,
        context: () => transcript,
        location: () => location?.call(),
        timings: timings,
      );

      await _runStep(
        c,
        ConnectStep.network,
        () => c.transport.applyAnswer(answer.answer),
      );
      _mark('answer');
      if (native != null) {
        await native;
        _check(c);
      }
      c.connectTimer = Timer(timings.connect, () {
        if (_call == c && _phase == CallPhase.connecting) {
          unawaited(
            _teardown(
              c,
              error: voiceConnectionFailed,
              kind: CallErrorKind.network,
            ),
          );
        }
      });
    } on _Cancelled {
      return;
    } catch (e) {
      if (c.cancelled) return;
      if (e is BridgeException) _retryAfter = e.retryAfter;
      await _teardown(c, error: _describe(e), kind: classify(e));
    }
  }

  Future<T> _runStep<T>(
    _Call c,
    ConnectStep step,
    Future<T> Function() run,
  ) async {
    _check(c);
    _step = step;
    _notify();
    final r = await run();
    _check(c);
    return r;
  }

  void _check(_Call c) {
    if (c.cancelled) throw const _Cancelled();
  }

  Future<void> _startNative(_Call c) async {
    if (!platform.supported) return;
    c.nativeStarting = true;
    final sentMuted = _muted;
    try {
      final warning = await platform
          .startCall(muted: sentMuted)
          .timeout(
            timings.nativeStart,
            onTimeout: () => throw const CallPlatformException(
              'The phone did not confirm the call in time, so it may stop '
              'when the app leaves the screen.',
            ),
          );
      if (c.cancelled) return;
      c.nativeLive = true;
      _background = BackgroundSupport.native;
      if (warning != null) _notice = warning;
      // A mute toggled while the native call was starting was not applied
      // there (updateCall is a no-op before the call is live).
      if (_muted != sentMuted) _syncNativeMute(c);
    } on CallPlatformException catch (e) {
      if (!c.cancelled) _notice = e.message;
    } catch (e) {
      if (!c.cancelled) _notice = 'Native call error: $e';
    }
  }

  String _describe(Object e) => switch (e) {
    MicrophoneException() => e.message,
    BridgeException(usageLimit: true) => usageLimitMessage(e.retryAfter),
    BridgeException(loginExpired: true) => loginExpiredMessage,
    BridgeException(unauthorized: true) =>
      'The access key was rejected. Check it in Settings.',
    BridgeException(status: 502) =>
      'The voice service could not start. Its ChatGPT login may need renewing.',
    BridgeException() => e.message,
    TimeoutException() => 'Connecting took too long',
    _ => 'Could not connect',
  };

  static CallErrorKind classify(Object e) => switch (e) {
    MicrophoneException() => CallErrorKind.microphone,
    BridgeException(usageLimit: true) => CallErrorKind.usageLimit,
    BridgeException(loginExpired: true) => CallErrorKind.loginExpired,
    BridgeException(unauthorized: true) => CallErrorKind.unauthorized,
    BridgeException(unreachable: true) => CallErrorKind.network,
    TimeoutException() => CallErrorKind.network,
    _ => CallErrorKind.other,
  };

  /// The audio path did not come up. Neutral on purpose: a timeout does not
  /// tell which network, device or service was at fault.
  static const voiceConnectionFailed =
      'Voice connection couldn’t be established. Check your connection and '
      'try again.';

  static const loginExpiredMessage =
      'The voice service’s ChatGPT login has expired. Sign in again on the '
      'server, then try again.';

  static String usageLimitMessage(Duration? retryAfter) {
    const base = 'You have reached your usage limit for live voice.';
    if (retryAfter == null) return '$base Try again later.';
    final m = (retryAfter.inSeconds / 60).ceil();
    final when = m < 60
        ? '$m min'
        : m % 60 == 0 || m >= 180
        ? '${(m / 60).round()} h'
        : '${m ~/ 60} h ${m % 60} min';
    return '$base It resets in about $when.';
  }

  /// Classifies a data-channel `error` event: usage limits and expired
  /// logins end the call with their own message; anything else is a notice.
  static CallErrorKind? classifyVoiceError(Object? err) {
    final code = err is Map ? '${err['code'] ?? ''} ${err['type'] ?? ''}' : '';
    final msg = err is Map ? '${err['message'] ?? ''}' : '$err';
    final all = '$code $msg'.toLowerCase();
    if (RegExp(
      r'usage[ _]limit|rate_limit_reached|insufficient_quota|quota exceeded|'
      r'hit your usage',
    ).hasMatch(all)) {
      return CallErrorKind.usageLimit;
    }
    if (RegExp(
      r'login_expired|token_expired|log out and sign in|sign in again|'
      r'codex login|access token could not be refreshed',
    ).hasMatch(all)) {
      return CallErrorKind.loginExpired;
    }
    return null;
  }

  void _onEvent(_Call c, Map<String, dynamic> m) {
    if (c.cancelled) return;
    switch (m['type']) {
      case 'session.started':
        if (_phase == CallPhase.connecting) {
          _mark('live');
          debugPrint('ToveLiveConnect ${jsonEncode(_timing)}');
          _goLive(c);
        }
      case 'turn.created':
        final turn = m['turn'] is Map ? m['turn'] as Map : const {};
        final who = _speakerOf(turn['role']);
        _turnCreated(who, _turnId(turn['id']));
        // The user spoke again: not a goodbye after all.
        if (who == Speaker.user && _farewell != null) _cancelFarewell();
      case 'input_transcript.added':
        _chunk(Speaker.user, m);
      case 'output_transcript.added':
        _chunk(Speaker.hermes, m);
      case 'turn.done':
        final turn = m['turn'] is Map ? m['turn'] as Map : const {};
        final who = _speakerOf(turn['role']);
        final full = (turn['transcript'] ?? '').toString();
        _turnDone(who, _turnId(turn['id']), full);
        _afterTurn(c, who, full);
      case 'delegation.created':
        if (_farewell != null) _cancelFarewell();
        final item = m['item'];
        if (item is Map<String, dynamic>) c.runner?.handle(item);
      case 'error':
        final err = m['error'];
        final kind = classifyVoiceError(err);
        if (kind == CallErrorKind.usageLimit) {
          unawaited(_teardown(c, error: usageLimitMessage(null), kind: kind));
          return;
        }
        if (kind == CallErrorKind.loginExpired) {
          unawaited(_teardown(c, error: loginExpiredMessage, kind: kind));
          return;
        }
        final msg = err is Map ? err['message'] : null;
        _notice = 'Voice error: ${msg ?? 'unknown'}';
      default:
        return;
    }
    _notify();
  }

  String _itemText(Map<String, dynamic> m) {
    final item = m['item'];
    return item is Map ? (item['text'] ?? '').toString() : '';
  }

  // --- transcript ----------------------------------------------------------
  //
  // One entry per spoken turn. GPT-Live names turns (`turn.created` /
  // `turn.done` carry `turn.id`), but a turn's first transcript chunk can
  // arrive before its `turn.created`. That chunk opens an entry without an
  // id, and the `turn.created` that follows adopts it instead of closing it
  // and opening a second one (which saved "Can" and then the full sentence
  // as two turns). Entries are matched by turn id, never by their text, so
  // two turns that say the same words stay two turns.

  static Speaker _speakerOf(Object? role) =>
      role == 'user' ? Speaker.user : Speaker.hermes;

  static String? _turnId(Object? id) =>
      id is String && id.isNotEmpty ? id : (id is num ? '$id' : null);

  TranscriptEntry? _openOf(Speaker s) =>
      s == Speaker.user ? _userTurn : _hermesTurn;

  void _setOpen(Speaker s, TranscriptEntry? e) {
    if (s == Speaker.user) {
      _userTurn = e;
    } else {
      _hermesTurn = e;
    }
  }

  void _turnCreated(Speaker s, String? id) {
    final open = _openOf(s);
    if (id != null) {
      final known = _byTurn[id];
      // A repeated `turn.created` (a replay) changes nothing.
      if (known != null) {
        _announced.add(known);
        if (known.live) _setOpen(s, known);
        return;
      }
    }
    if (open != null &&
        open.live &&
        !_announced.contains(open) &&
        (open.turnId == null || open.turnId == id)) {
      // Its chunks came before it: this is the same turn.
      _announced.add(open);
      if (id != null) {
        open.turnId = id;
        _byTurn[id] = open;
      }
      return;
    }
    _close(open);
    final e = _open(s, turnId: id);
    _announced.add(e);
    _setOpen(s, e);
  }

  void _chunk(Speaker s, Map<String, dynamic> m) {
    final text = _itemText(m);
    if (text.isEmpty) return;
    final item = m['item'];
    final id = _turnId(m['turn_id'] ?? (item is Map ? item['turn_id'] : null));
    if (id != null) {
      final known = _byTurn[id];
      if (known != null) {
        // A late chunk of a finished turn: its final transcript already won.
        if (known.live) known.text += text;
        return;
      }
    }
    var open = _openOf(s);
    if (open == null || (id != null && open.turnId != null)) {
      _close(open);
      open = _open(s, turnId: id);
      _setOpen(s, open);
    } else if (id != null && open.turnId == null) {
      open.turnId = id;
      _byTurn[id] = open;
    }
    open.text += text;
  }

  void _turnDone(Speaker s, String? id, String full) {
    final open = _openOf(s);
    var e = id == null ? null : _byTurn[id];
    if (e == null && open != null && (id == null || open.turnId == null)) {
      e = open;
      if (id != null) {
        e.turnId = id;
        _byTurn[id] = e;
      }
    }
    if (e == null) {
      // A turn that ended with no `turn.created` or chunk seen: keep what
      // was said.
      if (full.trim().isEmpty) return;
      e = _open(s, turnId: id);
    } else if (full.trim().isNotEmpty && !transcript.contains(e)) {
      // Closed while still wordless (a newer turn of the same speaker began
      // first), so it left the transcript; its words came with turn.done.
      // Back in its place, by entry order.
      final at = transcript.indexWhere((x) => x.id > e!.id);
      transcript.insert(at < 0 ? transcript.length : at, e);
    }
    _close(e, full);
    if (identical(open, e)) _setOpen(s, null);
  }

  TranscriptEntry _open(Speaker s, {String? turnId}) {
    final e = TranscriptEntry(++_ids, s, turnId: turnId);
    transcript.add(e);
    if (turnId != null) _byTurn[turnId] = e;
    return e;
  }

  void _close(TranscriptEntry? e, [String full = '']) {
    if (e == null) return;
    e.live = false;
    if (full.trim().isNotEmpty) e.text = full.trim();
    if (e.text.trim().isEmpty) transcript.remove(e);
  }

  // ---- goodbye ends the call (round 8) -----------------------------------

  /// Set while a farewell is ending the call: the user said goodbye, and the
  /// call ends once Tove's short farewell has played.
  _Farewell? _farewell;

  /// True while the call is ending because the user said goodbye.
  bool get endingByFarewell => _farewell != null;

  void _afterTurn(_Call c, Speaker who, String full) {
    if (_phase != CallPhase.live) return;
    if (who == Speaker.user) {
      final said = full.trim().isNotEmpty
          ? full
          : transcript
                .lastWhere(
                  (e) => e.speaker == Speaker.user,
                  orElse: () => TranscriptEntry(0, Speaker.user),
                )
                .text;
      if (!isFarewell(said)) return;
      _cancelFarewell();
      final f = _farewell = _Farewell(c);
      // No farewell from Tove in time: end anyway.
      f.timer = Timer(timings.farewellReply, () => _finishFarewell(f));
      _notify();
    } else if (who == Speaker.hermes) {
      final f = _farewell;
      if (f == null || f.call != c || f.draining) return;
      f.draining = true;
      f.timer?.cancel();
      _drainFarewell(f, full);
    }
  }

  /// Ends the call once the farewell's audio has played: the received level
  /// stays quiet for a moment, or (no level reading) after an estimate from
  /// its words. Never longer than [CallTimings.farewellMax].
  void _drainFarewell(_Farewell f, String said) {
    final words = said.trim().isEmpty
        ? 4
        : said.trim().split(RegExp(r'\s+')).length;
    final estimate = Duration(milliseconds: 600 + words * 380);
    final started = DateTime.now();
    var quietSince = started;
    f.timer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (_farewell != f || f.call.cancelled) return t.cancel();
      final now = DateTime.now();
      final waited = now.difference(started);
      final out = levels.value.output;
      if (out == null || out > 0.02) quietSince = now;
      final quiet =
          out != null &&
          waited >= timings.farewellMin &&
          now.difference(quietSince) >= timings.farewellQuiet;
      final guessed = out == null && waited >= estimate;
      if (quiet || guessed || waited >= timings.farewellMax) {
        t.cancel();
        _finishFarewell(f);
      }
    });
  }

  void _finishFarewell(_Farewell f) {
    if (_farewell != f) return;
    _farewell = null;
    if (_call == f.call && !f.call.cancelled) unawaited(end());
  }

  void _cancelFarewell() {
    _farewell?.timer?.cancel();
    _farewell = null;
    _notify();
  }

  void _goLive(_Call c) {
    c.connectTimer?.cancel();
    _phase = CallPhase.live;
    _error = null;
    c.levelTimer = Timer.periodic(timings.levelPoll, (_) => _pollLevels(c));
    if (c.transport.supportsSpeakerRoute) {
      unawaited(_route(c, _speaker));
    }
  }

  Future<void> _pollLevels(_Call c) async {
    if (c.cancelled || c.readingLevels) return;
    c.readingLevels = true;
    try {
      final l = await c.transport.readLevels();
      if (c.cancelled) return;
      levels.value = _muted ? AudioLevels(input: 0, output: l.output) : l;
    } catch (_) {
      if (!c.cancelled) levels.value = AudioLevels.unknown;
    } finally {
      c.readingLevels = false;
    }
  }

  void _onLink(_Call c, TransportLink l) {
    if (c.cancelled) return;
    switch (l) {
      case TransportLink.connected:
        c.graceTimer?.cancel();
        c.graceTimer = null;
      case TransportLink.disconnected:
        c.graceTimer ??= Timer(timings.disconnectGrace, () {
          if (!c.cancelled) {
            unawaited(
              _teardown(
                c,
                error: 'Connection lost',
                kind: CallErrorKind.network,
              ),
            );
          }
        });
      case TransportLink.failed || TransportLink.closed:
        unawaited(
          _teardown(
            c,
            error: _phase == CallPhase.live
                ? 'Connection lost'
                : voiceConnectionFailed,
            kind: CallErrorKind.network,
          ),
        );
      case TransportLink.connecting:
        break;
    }
  }

  /// Mute from the notification or CallKit. Returns false when there is no
  /// call to mute, so the native side does not report a mute that nothing
  /// applied.
  bool _nativeMute(bool muted) {
    if (_call == null) return false;
    setMuted(muted, fromNative: true);
    return true;
  }

  /// End from the notification, CallKit or the system. Without a call here,
  /// the native call is stale, so it is told to stop anyway.
  void _nativeEnd() {
    if (_call == null) {
      unawaited(platform.endCall().catchError((Object _) {}));
    }
    unawaited(end());
  }

  void setMuted(bool muted, {bool fromNative = false}) {
    final c = _call;
    if (c == null || muted == _muted) {
      if (fromNative && c != null) _notify();
      return;
    }
    _muted = muted;
    c.transport.setMuted(muted);
    if (muted) {
      levels.value = AudioLevels(input: 0, output: levels.value.output);
    }
    if (!fromNative && c.nativeLive) _syncNativeMute(c);
    _notify();
  }

  void _syncNativeMute(_Call c) {
    unawaited(
      platform.updateCall(muted: _muted).catchError((Object e) {
        if (!c.cancelled) {
          _notice = 'The phone did not get the mute change: $e';
          _notify();
        }
      }),
    );
  }

  void toggleMute() => setMuted(!_muted);

  Future<void> setSpeaker(bool on) async {
    final c = _call;
    _speaker = on;
    _notify();
    if (c != null && _phase == CallPhase.live) await _route(c, on);
  }

  Future<void> _route(_Call c, bool on) async {
    try {
      await c.transport.setSpeaker(on);
    } catch (_) {
      if (!c.cancelled) {
        _notice = 'Could not switch the audio output';
        _notify();
      }
    }
  }

  /// Hangs up. Returns when local cleanup and the stop request are done; the
  /// UI is idle as soon as this is called.
  Future<void> end() async {
    final c = _call;
    if (c == null) {
      if (_phase == CallPhase.failed) {
        _phase = CallPhase.idle;
        _error = null;
        _errorKind = null;
        _notify();
      }
      return;
    }
    await _teardown(c);
  }

  Future<void> _teardown(_Call c, {String? error, CallErrorKind? kind}) async {
    if (c.cancelled) return;
    c.cancelled = true;
    if (_farewell?.call == c) {
      _farewell?.timer?.cancel();
      _farewell = null;
    }
    if (_call == c) _call = null;
    c.connectTimer?.cancel();
    c.levelTimer?.cancel();
    c.graceTimer?.cancel();
    for (final s in c.subs) {
      unawaited(s.cancel());
    }
    c.runner?.stop();
    _close(_userTurn);
    _close(_hermesTurn);
    _userTurn = _hermesTurn = null;
    _phase = error == null ? CallPhase.idle : CallPhase.failed;
    _error = error;
    _errorKind = error == null ? null : (kind ?? CallErrorKind.other);
    _muted = false;
    levels.value = AudioLevels.silent;
    _notify();
    if (!_ended.isClosed) {
      _ended.add(
        CallSummary(
          session: c.session,
          conversationId: c.conversationId,
          linked: c.linked,
          started: c.started,
          ended: DateTime.now(),
          transcript: List.of(transcript),
          tasks: tasks.where((t) => !t.created.isBefore(c.started)).toList(),
          errorKind: _errorKind,
        ),
      );
    }

    final work = <Future<void>>[
      c.transport.close().catchError((_) {}),
      if (c.nativeStarting)
        platform.endCall().catchError((Object e) {
          if (_call == null) {
            _notice = 'The phone may still show the call: $e';
            _notify();
          }
        }),
    ];
    final session = c.session;
    if (session != null) {
      work.add(_stop(c, session));
    } else if (c.pendingSession != null) {
      // The server may still be creating the session for an offer we sent.
      // Stop it once its id arrives, or GPT-Live would keep running.
      work.add(
        c.pendingSession!.then((a) => _stop(c, a.session), onError: (_) {}),
      );
    }
    await Future.wait(work);
    c.api.close();
  }

  Future<void> _stop(_Call c, String session) =>
      c.api.stop(session: session, timeout: timings.stop).catchError((_) {});

  @override
  void dispose() {
    final c = _call;
    if (c != null) unawaited(_teardown(c));
    _warmApi?.close();
    _warmApi = null;
    _disposed = true;
    unawaited(_ended.close());
    levels.dispose();
    super.dispose();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class _Farewell {
  _Farewell(this.call);
  final _Call call;
  Timer? timer;
  bool draining = false;
}

class _Call {
  _Call(this.api, this.transport);
  final BridgeApi api;
  final VoiceTransport transport;
  final List<StreamSubscription<Object?>> subs = [];
  bool cancelled = false;
  bool nativeStarting = false;
  final DateTime started = DateTime.now();
  String? conversationId;
  bool linked = false;

  /// `startCall` succeeded, so `updateCall` reaches a live native call.
  bool nativeLive = false;
  bool readingLevels = false;
  String? session;
  Future<SessionAnswer>? pendingSession;
  DelegationRunner? runner;
  Timer? connectTimer, levelTimer, graceTimer;
}
