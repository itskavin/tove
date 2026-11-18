import 'package:flutter/foundation.dart';

enum TtsEngineKind {
  /// On-device Kokoro through sherpa-onnx. Needs a downloaded model.
  kokoro,

  /// The platform's own text-to-speech (Android TextToSpeech, AVSpeech…).
  system,
}

@immutable
class TtsVoice {
  const TtsVoice({
    required this.id,
    required this.name,
    required this.language,
    required this.engine,
    this.gender,
    this.speakerId,
    this.quality,
    this.requiresNetwork = false,
    this.attribution,
    this.platformVoice,
  });

  /// Stable identifier stored in settings (Kokoro: `af_heart`; system: the
  /// platform voice name).
  final String id;

  /// Display name, e.g. "Heart".
  final String name;

  /// BCP-47, e.g. `en-US`.
  final String language;
  final TtsEngineKind engine;

  /// `female` / `male` when known.
  final String? gender;

  /// Kokoro speaker index (`sid`).
  final int? speakerId;

  /// Platform quality label (`very high`, `high`, `normal`…).
  final String? quality;
  final bool requiresNetwork;

  /// Credit required by the voice's licence (some Kokoro voices are CC BY).
  final String? attribution;

  /// The map flutter_tts needs to select this voice.
  final Map<String, String>? platformVoice;

  bool get isEnglish => language.toLowerCase().startsWith('en');

  /// "Heart · American English · female".
  String get label => [
    name,
    languageName(language),
    ?gender,
  ].join(' · ');

  @override
  bool operator ==(Object other) =>
      other is TtsVoice && other.id == id && other.engine == engine;

  @override
  int get hashCode => Object.hash(id, engine);

  @override
  String toString() => 'TtsVoice($engine:$id)';
}

String languageName(String tag) => switch (tag.toLowerCase()) {
  'en-us' => 'American English',
  'en-gb' => 'British English',
  'es' || 'es-es' => 'Spanish',
  'fr' || 'fr-fr' => 'French',
  'hi' || 'hi-in' => 'Hindi',
  'it' || 'it-it' => 'Italian',
  'ja' || 'ja-jp' => 'Japanese',
  'pt-br' => 'Brazilian Portuguese',
  'zh' || 'zh-cn' => 'Mandarin',
  _ => tag,
};

/// One sentence ready to play. Synthesising engines carry audio in
/// [payload]; the system engine carries only the text.
class TtsUtterance {
  TtsUtterance({
    required this.text,
    this.audioDuration,
    this.synthDuration,
    this.payload,
  });

  final String text;
  final Duration? audioDuration;
  final Duration? synthDuration;
  final Object? payload;

  /// Real-time factor: synthesis time ÷ audio length. Below 1 is faster than
  /// real time. Null for engines that do not synthesise ahead.
  double? get rtf {
    final a = audioDuration, s = synthDuration;
    if (a == null || s == null || a == Duration.zero) return null;
    return s.inMicroseconds / a.inMicroseconds;
  }
}

class TtsException implements Exception {
  const TtsException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A text-to-speech backend. [TtsController] calls [synthesize] ahead of
/// playback and [play] in order; [play] queues behind earlier utterances.
abstract class TtsEngine {
  TtsEngineKind get kind;

  /// Loads the engine. Idempotent. Throws [TtsException] when unusable.
  Future<void> prepare();

  Future<List<TtsVoice>> voices();

  /// The voice used when the saved one is missing.
  Future<TtsVoice?> defaultVoice();

  Future<TtsUtterance> synthesize(
    String text, {
    TtsVoice? voice,
    required double speed,
  });

  /// Queues [u]. Completes with true when it has been heard, or false when
  /// [stop] dropped it.
  Future<bool> play(TtsUtterance u);

  Future<void> pause();
  Future<void> resume();

  /// Drops everything queued and playing.
  Future<void> stop();

  /// True when [resume] continues mid-sentence. Otherwise the controller
  /// replays the interrupted sentence.
  bool get resumesMidSentence;

  /// Frees models and native resources. [prepare] may be called again.
  Future<void> release();
}
