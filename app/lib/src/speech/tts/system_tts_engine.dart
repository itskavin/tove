import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'tts_engine.dart';

/// The subset of flutter_tts the engine uses, so tests can fake it.
abstract class PlatformTts {
  Future<List<Map<String, String>>> voices();
  Future<void> setVoice(Map<String, String> voice);
  Future<void> setRate(double rate);
  Future<void> speak(String text);
  Future<void> stop();
  void setHandlers({
    required VoidCallback onDone,
    required VoidCallback onCancel,
    required void Function(String) onError,
  });
}

class FlutterTtsAdapter implements PlatformTts {
  FlutterTtsAdapter([FlutterTts? tts]) : _tts = tts ?? FlutterTts();
  final FlutterTts _tts;

  @override
  Future<List<Map<String, String>>> voices() async {
    final raw = await _tts.getVoices;
    if (raw is! List) return const [];
    return [
      for (final v in raw)
        if (v is Map)
          {
            for (final e in v.entries)
              if (e.key != null && e.value != null) '${e.key}': '${e.value}',
          },
    ];
  }

  @override
  Future<void> setVoice(Map<String, String> voice) => _tts.setVoice({
    'name': voice['name'] ?? '',
    'locale': voice['locale'] ?? '',
  });

  @override
  Future<void> setRate(double rate) => _tts.setSpeechRate(rate);

  @override
  Future<void> speak(String text) async {
    await _tts.awaitSpeakCompletion(false);
    await _tts.speak(text);
  }

  @override
  Future<void> stop() => _tts.stop();

  @override
  void setHandlers({
    required VoidCallback onDone,
    required VoidCallback onCancel,
    required void Function(String) onError,
  }) {
    _tts.setCompletionHandler(onDone);
    _tts.setCancelHandler(onCancel);
    _tts.setErrorHandler((m) => onError('$m'));
  }
}

/// Read-aloud through the platform's own voices (Android TextToSpeech,
/// AVSpeechSynthesizer, Web Speech, SAPI). Works offline with no download.
///
/// [bestVoice] prefers, in order: the requested language, voices marked
/// neural, "very high"/"high" quality, and network voices when online
/// (Google's network voices are its most natural ones).
class SystemTtsEngine implements TtsEngine {
  SystemTtsEngine({PlatformTts? tts, this.language = 'en-US', this.online})
    : _tts = tts ?? FlutterTtsAdapter();

  final PlatformTts _tts;

  /// Preferred BCP-47 language for [defaultVoice].
  String language;

  /// Whether network voices may be preferred. Null means yes.
  final Future<bool> Function()? online;

  bool _prepared = false;
  List<TtsVoice>? _voices;
  TtsVoice? _applied;
  double? _appliedRate;
  Completer<bool>? _current;
  Future<void> _queue = Future.value();
  int _gen = 0;

  @override
  TtsEngineKind get kind => TtsEngineKind.system;

  /// Platform TTS cannot resume mid-utterance reliably (flutter_tts's
  /// Android pause is a stop), so the sentence is replayed.
  @override
  bool get resumesMidSentence => false;

  @override
  Future<void> prepare() async {
    if (_prepared) return;
    _tts.setHandlers(
      onDone: () => _finish(true),
      onCancel: () => _finish(false),
      onError: (m) {
        final c = _current;
        _current = null;
        if (c != null && !c.isCompleted) c.completeError(TtsException(m));
      },
    );
    _prepared = true;
  }

  void _finish(bool ok) {
    final c = _current;
    _current = null;
    if (c != null && !c.isCompleted) c.complete(ok);
  }

  @override
  Future<List<TtsVoice>> voices() async {
    await prepare();
    return _voices ??= (await _tts.voices()).map(_toVoice).toList();
  }

  static TtsVoice _toVoice(Map<String, String> m) {
    final name = m['name'] ?? '';
    final locale = (m['locale'] ?? '').replaceAll('_', '-');
    final features = (m['features'] ?? '').toLowerCase();
    final network =
        m['network_required'] == '1' ||
        name.toLowerCase().contains('network') ||
        features.contains('networktts');
    return TtsVoice(
      id: name,
      name: _prettyName(name),
      language: locale,
      engine: TtsEngineKind.system,
      gender: m['gender'],
      quality: m['quality'],
      requiresNetwork: network,
      platformVoice: {'name': name, 'locale': m['locale'] ?? locale},
    );
  }

  static String _prettyName(String name) {
    // "en-us-x-tpf-network" → "TPF (network)"
    final g = RegExp(r'-x-([a-z0-9]+)-(network|local)$').firstMatch(name);
    if (g != null) return '${g.group(1)!.toUpperCase()} (${g.group(2)})';
    return name;
  }

  static int _quality(String? q) => switch (q) {
    'very high' => 5,
    'high' => 4,
    'normal' => 3,
    'low' => 2,
    'very low' => 1,
    _ => 3,
  };

  /// Picks the most natural voice for [language], or null when none speaks
  /// it.
  static TtsVoice? bestVoice(
    List<TtsVoice> voices,
    String language, {
    bool online = true,
  }) {
    final want = language.toLowerCase();
    final wantLang = want.split('-').first;
    int score(TtsVoice v) {
      final l = v.language.toLowerCase();
      var s = 0;
      if (l == want) {
        s += 100;
      } else if (l.split('-').first == wantLang) {
        s += 50;
      } else {
        return -1;
      }
      final n = v.id.toLowerCase();
      if (n.contains('neural') ||
          n.contains('wavenet') ||
          n.contains('natural')) {
        s += 15;
      }
      s += _quality(v.quality) * 3;
      if (v.requiresNetwork) s += online ? 6 : -30;
      if (n.contains('premium')) s += 12;
      if (n.contains('enhanced')) s += 8;
      if (n.contains('compact')) s -= 5;
      return s;
    }

    TtsVoice? best;
    var bestScore = -1;
    for (final v in voices) {
      final s = score(v);
      if (s > bestScore) {
        best = v;
        bestScore = s;
      }
    }
    return best;
  }

  @override
  Future<TtsVoice?> defaultVoice() async {
    final all = await voices();
    final isOnline = online == null ? true : await online!();
    return bestVoice(all, language, online: isOnline);
  }

  @override
  Future<TtsUtterance> synthesize(
    String text, {
    TtsVoice? voice,
    required double speed,
  }) async {
    await prepare();
    return TtsUtterance(text: text, payload: (voice: voice, speed: speed));
  }

  /// Platform rate for a speed multiplier. Android's 1.0 is normal speed;
  /// AVSpeech's normal is 0.5.
  static double platformRate(double speed) =>
      !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.iOS ||
              defaultTargetPlatform == TargetPlatform.macOS)
      ? 0.5 * speed
      : speed;

  @override
  Future<bool> play(TtsUtterance u) {
    final gen = _gen;
    final result = Completer<bool>();
    _queue = _queue.then((_) async {
      if (gen != _gen) {
        result.complete(false);
        return;
      }
      try {
        final args = u.payload as ({TtsVoice? voice, double speed})?;
        var voice = args?.voice;
        if (voice == null || voice.engine != TtsEngineKind.system) {
          voice = await defaultVoice();
        }
        if (voice?.platformVoice != null && voice != _applied) {
          await _tts.setVoice(voice!.platformVoice!);
          _applied = voice;
        }
        final rate = platformRate(args?.speed ?? 1.0);
        if (rate != _appliedRate) {
          await _tts.setRate(rate);
          _appliedRate = rate;
        }
        final c = _current = Completer<bool>();
        await _tts.speak(u.text);
        result.complete(await c.future);
      } catch (e) {
        result.completeError(e is TtsException ? e : TtsException('$e'));
      }
    });
    return result.future;
  }

  @override
  Future<void> pause() => stop();

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {
    _gen++;
    _finish(false);
    await _tts.stop();
  }

  @override
  Future<void> release() => stop();
}
