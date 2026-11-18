import 'dart:async';

/// Connection state of the peer link to GPT-Live.
enum TransportLink { connecting, connected, disconnected, failed, closed }

/// Measured audio levels (0..1) from WebRTC stats. A null side means the
/// platform did not report it; callers must not invent a value.
class AudioLevels {
  const AudioLevels({this.input, this.output});
  static const silent = AudioLevels(input: 0, output: 0);
  static const unknown = AudioLevels();

  /// Microphone level being sent.
  final double? input;

  /// Hermes' voice level being received.
  final double? output;

  bool get available => input != null || output != null;
}

class MicrophoneException implements Exception {
  const MicrophoneException(this.message, {this.denied = false});
  final String message;
  final bool denied;
  @override
  String toString() => message;
}

/// The device side of a call: microphone, peer connection and the
/// `oai-events` data channel. Media goes straight to GPT-Live; only the SDP is
/// exchanged through the bridge.
abstract interface class VoiceTransport {
  /// Acquires the microphone; this is where the OS permission prompt appears.
  Future<void> openMicrophone();

  /// Builds the peer connection and data channel, creates the offer and waits
  /// for ICE gathering (at most [iceTimeout]). Returns the offer SDP.
  Future<String> createOffer({required Duration iceTimeout});

  Future<void> applyAnswer(String sdp);

  /// Enables or disables the outgoing microphone track.
  void setMuted(bool muted);

  /// Whether this platform can switch between loudspeaker and earpiece.
  bool get supportsSpeakerRoute;

  /// Loudspeaker on (preferring Bluetooth when connected) or earpiece.
  Future<void> setSpeaker(bool on);

  /// Parsed JSON messages from the data channel.
  Stream<Map<String, dynamic>> get events;

  Stream<TransportLink> get link;

  /// Sends a JSON message; false when the channel is not open.
  bool send(Map<String, dynamic> message);

  Future<AudioLevels> readLevels();

  /// Releases every track, the peer connection and the data channel. Safe to
  /// call at any point, including while another method is still pending.
  Future<void> close();
}

typedef VoiceTransportFactory = VoiceTransport Function();
