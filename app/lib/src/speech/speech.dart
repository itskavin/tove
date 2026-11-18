/// Dictation (speech-to-text) and read-aloud (text-to-speech).
///
/// Start with [SpeechServices.create]. See docs/design/voice-models.md for
/// models, hashes and licences.
library;

export 'dictation/bridge_transcriber.dart';
export 'dictation/dictation_engine.dart';
export 'dictation/moonshine_dictation_engine.dart'
    show MoonshineDictationEngine, EnergyEndpointer, EndpointEvent;
export 'dictation/server_dictation_engine.dart';
export 'dictation/system_dictation_engine.dart';
export 'dictation_controller.dart';
export 'licenses.dart';
export 'models/model_catalog.dart';
export 'models/model_manager.dart';
export 'speakable_text.dart';
export 'speech_platform.dart';
export 'speech_services.dart';
export 'speech_settings.dart' hide MapEquality;
export 'tts/kokoro_engine.dart' show KokoroEngine, KokoroModelFiles;
export 'tts/kokoro_voices.dart';
export 'tts/system_tts_engine.dart' show SystemTtsEngine;
export 'tts/tts_engine.dart';
export 'tts_controller.dart';
