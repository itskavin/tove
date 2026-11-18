import 'package:flutter/foundation.dart';

/// Default bridge address: none. Each person runs their own bridge, so the
/// connect screen starts empty (on the web it proposes the page's origin).
const String kDefaultBridgeUrl = '';

/// An example address, shown in hints only.
const String kExampleBridgeUrl = 'https://tove.example.com';

/// Voices the GPT-Live v3 app-server accepts (mirrors `V3_VOICES` in gpt-live-bridge.py).
const List<String> kVoices = [
  'cove',
  'juniper',
  'sol',
  'ember',
  'vale',
  'maple',
  'spruce',
  'breeze',
  'arbor',
  'aube',
  'bubbie',
];
const String kDefaultVoice = 'cove';

/// The bridge refuses keys shorter than this (`live_authorized`).
const int kMinKeyLength = 20;

/// The bridge rejects longer tasks with 400 (`api_delegate`).
const int kMaxTaskChars = 8000;

/// `delegation.context.append` payloads are clipped to this, like the web page.
const int kMaxResultChars = 3500;

/// Server-side job limit (`LIVE_MAX_JOBS`, default 2). Informational only: the
/// server's 429 is the source of truth.
const int kServerTaskCap = 2;

/// The address the app proposes on first launch. On the web the bridge has no
/// CORS headers, so the app can only talk to the origin that served it.
String defaultBridgeUrl() {
  if (kIsWeb) {
    final base = Uri.base;
    if (base.scheme == 'https' || base.scheme == 'http') return base.origin;
  }
  return kDefaultBridgeUrl;
}

/// Timings of the call lifecycle. Tests shrink these.
class CallTimings {
  const CallTimings({
    this.microphone = const Duration(seconds: 60),
    this.nativeStart = const Duration(seconds: 20),
    this.iceGathering = const Duration(milliseconds: 2500),
    this.session = const Duration(seconds: 50),
    this.connect = const Duration(seconds: 20),
    this.disconnectGrace = const Duration(seconds: 6),
    this.stop = const Duration(seconds: 8),
    this.request = const Duration(seconds: 15),
    this.jobPoll = const Duration(milliseconds: 1200),
    this.levelPoll = const Duration(milliseconds: 50),
    this.maxPollFailures = 4,
    this.farewellReply = const Duration(seconds: 7),
    this.farewellMin = const Duration(milliseconds: 400),
    this.farewellQuiet = const Duration(milliseconds: 700),
    this.farewellMax = const Duration(seconds: 9),
  });

  /// After the user says goodbye: how long Tove has to start its farewell
  /// before the call ends anyway.
  final Duration farewellReply;

  /// After Tove's farewell turn: the shortest wait, the quiet that means its
  /// audio has played, and the longest wait before the call ends.
  final Duration farewellMin, farewellQuiet, farewellMax;

  /// Waiting for the microphone, including the permission prompt.
  final Duration microphone;

  /// Waiting for the native call service / CallKit to report the call started.
  final Duration nativeStart;

  /// ICE gathering before the offer is sent (the page uses 2.5 s).
  final Duration iceGathering;

  /// `/api/session`; the server gives Codex 45 s.
  final Duration session;

  /// From the SDP answer to `session.started`.
  final Duration connect;

  /// How long a `disconnected` peer may stay so before the call is ended.
  final Duration disconnectGrace;

  /// `/api/stop`.
  final Duration stop;

  /// Any other bridge request.
  final Duration request;

  /// Interval between `/api/job` polls (the page uses 1.2 s).
  final Duration jobPoll;

  /// Interval between WebRTC stats reads for the audio levels (50 ms while
  /// live, spec §6.1; the orb interpolates between samples per frame).
  final Duration levelPoll;

  /// Consecutive failed polls before a task is reported as failed.
  final int maxPollFailures;
}
