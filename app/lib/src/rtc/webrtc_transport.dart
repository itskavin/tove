import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../call/protocol.dart';
import 'voice_transport.dart';

/// [VoiceTransport] on flutter_webrtc: a direct peer connection to GPT-Live,
/// created exactly like hermes-live.html does (no ICE servers, one audio
/// track, `oai-events` data channel).
class WebRtcTransport implements VoiceTransport {
  MediaStream? _mic;
  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  RTCVideoRenderer? _webAudio;
  bool _closed = false;
  bool _muted = false;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _link = StreamController<TransportLink>.broadcast();
  final Map<String, (double, double)> _energy = {};

  static bool get _mobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Stream<TransportLink> get link => _link.stream;

  @override
  bool get supportsSpeakerRoute => _mobile;

  @override
  Future<void> openMicrophone() async {
    final MediaStream stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        // Native builds already enable echo cancellation, noise suppression
        // and gain control by default; browsers need them spelled out.
        'audio': kIsWeb
            ? {
                'echoCancellation': true,
                'noiseSuppression': true,
                'autoGainControl': true,
              }
            : true,
        'video': false,
      });
    } catch (e) {
      final text = e.toString();
      final denied = RegExp(
        r'NotAllowed|Permission|denied|SecurityError',
        caseSensitive: false,
      ).hasMatch(text);
      throw MicrophoneException(
        denied
            ? 'Microphone permission was denied'
            : RegExp(
                r'NotFound|no audio|device',
                caseSensitive: false,
              ).hasMatch(text)
            ? 'No microphone was found'
            : 'The microphone could not be opened',
        denied: denied,
      );
    }
    if (_closed) {
      await _release(stream);
      throw StateError('closed');
    }
    _mic = stream;
    _applyMute();
  }

  /// Quiet time after the newest ICE candidate before the offer is sent.
  static const iceSettle = Duration(milliseconds: 180);

  @override
  Future<String> createOffer({required Duration iceTimeout}) async {
    final mic = _mic;
    if (mic == null || _closed) throw StateError('microphone not open');
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      // Voice-call audio mode: echo cancellation path, call volume stream.
      // Must be set before the session starts.
      try {
        await Helper.setAndroidAudioConfiguration(
          AndroidAudioConfiguration.communication,
        );
      } catch (_) {}
    }
    final pc = await createPeerConnection({'sdpSemantics': 'unified-plan'});
    if (_closed) {
      await pc.close();
      throw StateError('closed');
    }
    _pc = pc;
    final gathered = Completer<void>();
    pc.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !gathered.isCompleted) {
        gathered.complete();
      }
    };
    // Round 8: no ICE servers, so the candidates are the device's own
    // addresses and arrive at once; "complete" can lag them by seconds
    // (more interfaces, TCP candidates). The offer goes out [iceSettle]
    // after the newest candidate instead (one-shot SDP: no trickle here).
    Timer? settle;
    pc.onIceCandidate = (c) {
      if (c.candidate == null || c.candidate!.isEmpty) return;
      settle?.cancel();
      settle = Timer(iceSettle, () {
        if (!gathered.isCompleted) gathered.complete();
      });
    };
    pc.onConnectionState = (s) {
      if (_closed) return;
      _link.add(switch (s) {
        RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
          TransportLink.connected,
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
          TransportLink.disconnected,
        RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
          TransportLink.failed,
        RTCPeerConnectionState.RTCPeerConnectionStateClosed =>
          TransportLink.closed,
        _ => TransportLink.connecting,
      });
    };
    pc.onTrack = (e) {
      // Native builds play remote audio by themselves; the web needs an
      // element, which the renderer provides.
      if (kIsWeb && e.track.kind == 'audio' && e.streams.isNotEmpty) {
        unawaited(_playOnWeb(e.streams.first));
      }
    };
    for (final t in mic.getAudioTracks()) {
      await pc.addTrack(t, mic);
    }
    final dc = await pc.createDataChannel(
      kDataChannelLabel,
      RTCDataChannelInit()..protocol = '',
    );
    _dc = dc;
    dc.onMessage = (m) {
      if (_closed || m.isBinary) return;
      try {
        final decoded = jsonDecode(m.text);
        if (decoded is Map<String, dynamic>) _events.add(decoded);
      } catch (_) {}
    };
    dc.onDataChannelState = (s) {
      if (!_closed && s == RTCDataChannelState.RTCDataChannelClosed) {
        _link.add(TransportLink.closed);
      }
    };
    final offer = await pc.createOffer({});
    await pc.setLocalDescription(offer);
    if (pc.iceGatheringState !=
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      // Like the page: send whatever was gathered after the timeout.
      await gathered.future.timeout(iceTimeout, onTimeout: () {});
    }
    settle?.cancel();
    if (_closed) throw StateError('closed');
    final local = await pc.getLocalDescription();
    final sdp = local?.sdp;
    if (sdp == null || !sdp.startsWith('v=0')) {
      throw StateError('no local offer');
    }
    return sdp;
  }

  Future<void> _playOnWeb(MediaStream stream) async {
    if (_closed) return;
    final r = _webAudio ??= RTCVideoRenderer();
    await r.initialize();
    if (_closed) return;
    r.srcObject = stream;
  }

  @override
  Future<void> applyAnswer(String sdp) async {
    final pc = _pc;
    if (pc == null || _closed) throw StateError('closed');
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
  }

  @override
  void setMuted(bool muted) {
    _muted = muted;
    _applyMute();
  }

  void _applyMute() {
    for (final t in _mic?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = !_muted;
    }
  }

  @override
  Future<void> setSpeaker(bool on) async {
    if (!_mobile) return;
    if (on) {
      await Helper.setSpeakerphoneOnButPreferBluetooth();
    } else {
      await Helper.setSpeakerphoneOn(false);
    }
  }

  @override
  bool send(Map<String, dynamic> message) {
    final dc = _dc;
    if (_closed ||
        dc == null ||
        dc.state != RTCDataChannelState.RTCDataChannelOpen) {
      return false;
    }
    unawaited(
      dc.send(RTCDataChannelMessage(jsonEncode(message))).catchError((_) {}),
    );
    return true;
  }

  @override
  Future<AudioLevels> readLevels() async {
    final pc = _pc;
    if (pc == null || _closed) return AudioLevels.unknown;
    double? input, output;
    for (final r in await pc.getStats()) {
      final v = r.values;
      final kind = v['kind'] ?? v['mediaType'];
      if (kind != 'audio') continue;
      if (r.type == 'media-source') {
        input = _level(r.id, v) ?? input;
      } else if (r.type == 'inbound-rtp') {
        output = _level(r.id, v) ?? output;
      }
    }
    return AudioLevels(input: input, output: output);
  }

  /// `audioLevel` when reported, else RMS from the energy counters.
  double? _level(String id, Map<dynamic, dynamic> v) {
    final level = v['audioLevel'];
    if (level is num) return level.toDouble().clamp(0, 1);
    final e = v['totalAudioEnergy'], d = v['totalSamplesDuration'];
    if (e is! num || d is! num) return null;
    final prev = _energy[id];
    _energy[id] = (e.toDouble(), d.toDouble());
    if (prev == null) return null;
    final dd = d - prev.$2;
    if (dd <= 0) return 0;
    return math.sqrt(math.max(0, (e - prev.$1) / dd)).clamp(0, 1);
  }

  Future<void> _release(MediaStream s) async {
    for (final t in s.getTracks()) {
      try {
        await t.stop();
      } catch (_) {}
    }
    try {
      await s.dispose();
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final dc = _dc, pc = _pc, mic = _mic, web = _webAudio;
    _dc = null;
    _pc = null;
    _mic = null;
    _webAudio = null;
    try {
      await dc?.close();
    } catch (_) {}
    try {
      await pc?.close();
      await pc?.dispose();
    } catch (_) {}
    if (mic != null) await _release(mic);
    try {
      web?.srcObject = null;
      await web?.dispose();
    } catch (_) {}
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        await Helper.clearAndroidCommunicationDevice();
      } catch (_) {}
    }
    await _events.close();
    await _link.close();
  }
}
