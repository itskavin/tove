import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'dictation_engine.dart';
import 'server_dictation_engine.dart';

/// [ServerTranscriber] over the Tove bridge: `GET /api/capabilities` for the
/// `transcribe` flag (cached), `POST /api/transcribe` per phrase
/// (server/API.md "Transcription").
class BridgeTranscriber implements ServerTranscriber {
  BridgeTranscriber({
    required this.baseUrl,
    required this.accessKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    this.capabilityTimeout = const Duration(seconds: 4),
    this.availableFor = const Duration(minutes: 10),
    this.unavailableFor = const Duration(minutes: 1),
    DateTime Function()? now,
  }) : _client = client ?? http.Client(),
       _now = now ?? DateTime.now;

  /// The bridge URL from Settings, or null when none is set.
  final Uri? Function() baseUrl;
  final String Function() accessKey;
  final http.Client _client;
  final Duration timeout;
  final Duration capabilityTimeout;

  /// How long a yes (and a no from a reachable server) is believed.
  final Duration availableFor;
  final Duration unavailableFor;
  final DateTime Function() _now;

  String? _cachedFor;
  bool _cached = false;
  DateTime _cachedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  Future<bool>? _pending;

  Uri? _base() {
    final u = baseUrl();
    if (u == null || !u.hasScheme || u.host.isEmpty) return null;
    final path = u.path.endsWith('/')
        ? u.path.substring(0, u.path.length - 1)
        : u.path;
    return u.replace(path: path, query: null, fragment: null);
  }

  Uri _url(Uri base, String path) => base.replace(path: '${base.path}$path');

  Map<String, String> get _auth => {'Authorization': 'Bearer ${accessKey()}'};

  @override
  Future<bool> available() {
    final base = _base();
    final key = accessKey();
    if (base == null || key.isEmpty) return Future.value(false);
    final id = '$base|${key.hashCode}';
    if (id == _cachedFor && _now().isBefore(_cachedUntil)) {
      return Future.value(_cached);
    }
    return _pending ??= _ask(base, id).whenComplete(() => _pending = null);
  }

  Future<bool> _ask(Uri base, String id) async {
    try {
      final r = await _client
          .get(
            _url(base, '/api/capabilities'),
            headers: {..._auth, 'Accept': 'application/json'},
          )
          .timeout(capabilityTimeout);
      final ok =
          r.statusCode == 200 &&
          (jsonDecode(r.body) as Map<String, dynamic>)['transcribe'] is Map;
      _remember(id, ok, ok ? availableFor : unavailableFor);
      return ok;
    } catch (_) {
      // Unreachable: ask again on the next dictation.
      return false;
    }
  }

  void _remember(String id, bool ok, Duration d) {
    _cachedFor = id;
    _cached = ok;
    _cachedUntil = _now().add(d);
  }

  /// Forget the cached answer (the server or key changed).
  void reset() {
    _cachedFor = null;
    _cachedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  }

  static final _rand = math.Random.secure();

  @override
  Future<String> transcribe(
    Uint8List wav, {
    String? language,
    String? prompt,
  }) async {
    final base = _base();
    if (base == null || accessKey().isEmpty) {
      throw const DictationException(
        DictationError(
          DictationErrorKind.unavailable,
          'No Tove server is set up.',
        ),
      );
    }
    final boundary =
        'tove-${List.generate(24, (_) => _rand.nextInt(36).toRadixString(36)).join()}';
    final body = BytesBuilder(copy: false);
    void field(String name, String value) => body.add(
      utf8.encode(
        '--$boundary\r\nContent-Disposition: form-data; name="$name"'
        '\r\n\r\n$value\r\n',
      ),
    );
    if (language != null && language.isNotEmpty) field('language', language);
    if (prompt != null && prompt.isNotEmpty) field('prompt', prompt);
    body
      ..add(
        utf8.encode(
          '--$boundary\r\nContent-Disposition: form-data; name="file"; '
          'filename="dictation.wav"\r\nContent-Type: audio/wav\r\n\r\n',
        ),
      )
      ..add(wav)
      ..add(utf8.encode('\r\n--$boundary--\r\n'));
    final http.Response r;
    try {
      r = await _client
          .post(
            _url(base, '/api/transcribe'),
            headers: {
              ..._auth,
              'Content-Type': 'multipart/form-data; boundary=$boundary',
              'Accept': 'application/json',
            },
            body: body.takeBytes(),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const DictationException(
        DictationError(
          DictationErrorKind.network,
          'Transcription took too long. Check the connection.',
        ),
      );
    } catch (_) {
      throw const DictationException(
        DictationError(
          DictationErrorKind.network,
          'Couldn’t reach the Tove server to transcribe.',
        ),
      );
    }
    if (r.statusCode == 200) {
      try {
        final text = (jsonDecode(r.body) as Map<String, dynamic>)['text'];
        if (text is String) return text;
      } catch (_) {}
      throw const DictationException(
        DictationError(
          DictationErrorKind.server,
          'The Tove server sent an invalid transcription.',
        ),
      );
    }
    if (r.statusCode == 401 || r.statusCode == 404 || r.statusCode == 503) {
      final busy = r.statusCode == 503 && r.body.contains('"busy"');
      if (!busy) reset();
      throw DictationException(
        busy
            ? const DictationError(
                DictationErrorKind.busy,
                'The Tove server is busy. Try again.',
              )
            : const DictationError(
                DictationErrorKind.unavailable,
                'The Tove server can’t transcribe right now.',
              ),
      );
    }
    if (r.statusCode == 413) {
      throw const DictationException(
        DictationError(
          DictationErrorKind.other,
          'That recording is too long to transcribe.',
        ),
      );
    }
    throw DictationException(
      DictationError(
        DictationErrorKind.server,
        'Transcription failed on the Tove server. Try again.',
        code: r.statusCode,
      ),
    );
  }
}
