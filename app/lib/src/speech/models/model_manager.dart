import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../speech_platform.dart';
import 'model_catalog.dart';

enum ModelPhase {
  notInstalled,

  /// Wi-Fi only is on and the network is metered.
  waitingForWifi,
  downloading,

  /// Stopped part way; [ModelStatus.receivedBytes] are kept for resuming.
  paused,
  verifying,
  extracting,
  installed,
  failed,
}

@immutable
class ModelStatus {
  const ModelStatus(
    this.phase, {
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.error,
  });

  final ModelPhase phase;
  final int receivedBytes;
  final int totalBytes;

  /// User-facing reason for [ModelPhase.failed] / [ModelPhase.waitingForWifi].
  final String? error;

  double? get progress =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : null;
  bool get isInstalled => phase == ModelPhase.installed;
  bool get isBusy =>
      phase == ModelPhase.downloading ||
      phase == ModelPhase.verifying ||
      phase == ModelPhase.extracting;

  @override
  String toString() =>
      'ModelStatus($phase, $receivedBytes/$totalBytes${error == null ? '' : ', $error'})';
}

class ModelChecksumException implements Exception {
  const ModelChecksumException(this.expected, this.actual);
  final String expected;
  final String actual;
  @override
  String toString() => 'SHA-256 mismatch: expected $expected, got $actual';
}

/// Unpacks a `.tar.bz2` into a directory. Swappable for tests.
typedef ArchiveExtractor = Future<void> Function(String archive, String outDir);

/// SHA-256 of a file as lowercase hex. Swappable for tests.
typedef FileHasher = Future<String> Function(String path);

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Streams the file through SHA-256 off the UI isolate.
Future<String> sha256OfFile(String path) => Isolate.run(() async {
  final out = _DigestSink();
  final input = sha256.startChunkedConversion(out);
  await for (final chunk in File(path).openRead()) {
    input.add(chunk);
  }
  input.close();
  return out.value.toString();
});

Future<void> _extractIsolate(String archive, String outDir) =>
    Isolate.run(() => extractFileToDisk(archive, outDir, verify: true));

/// Downloads, verifies, installs and removes the speech models in
/// [SpeechModels.all] under `<app support>/speech-models/`.
///
/// Layout per model id:
///  * `<id>.tar.bz2.part` + `<id>.part.json`: an interrupted download, resumed
///    with an HTTP Range request;
///  * `<id>/`: the installed files, with `installed.json` written last.
class ModelManager extends ChangeNotifier {
  ModelManager({
    Future<Directory> Function()? baseDir,
    http.Client? client,
    SpeechPlatform? platform,
    ArchiveExtractor? extractor,
    FileHasher? hasher,
    List<SpeechModel> catalog = SpeechModels.all,
    this.progressInterval = const Duration(milliseconds: 250),
  }) : _baseDir = baseDir ?? _defaultBaseDir,
       _client = client ?? http.Client(),
       _platform = platform ?? const UnsupportedSpeechPlatform(),
       _extract = extractor ?? _extractIsolate,
       _hash = hasher ?? sha256OfFile,
       _catalog = {for (final m in catalog) m.id: m};

  static Future<Directory> _defaultBaseDir() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/speech-models');

  final Future<Directory> Function() _baseDir;
  final http.Client _client;
  final SpeechPlatform _platform;
  final ArchiveExtractor _extract;
  final FileHasher _hash;
  final Map<String, SpeechModel> _catalog;
  final Duration progressInterval;

  final Map<String, ModelStatus> _status = {};
  final Map<String, Future<void>> _running = {};
  final Map<String, StreamSubscription<List<int>>> _subs = {};
  final Map<String, Completer<void>> _cancelled = {};
  Directory? _dir;

  Iterable<SpeechModel> get models => _catalog.values;

  ModelStatus status(String id) =>
      _status[id] ?? const ModelStatus(ModelPhase.notInstalled);

  bool isInstalled(String id) => status(id).isInstalled;

  Future<Directory> _root() async {
    final d = _dir ??= await _baseDir();
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// The install directory, or null when not installed.
  Future<Directory?> installedDir(String id) async {
    final d = Directory('${(await _root()).path}/$id');
    return await File('${d.path}/installed.json').exists() ? d : null;
  }

  void _set(String id, ModelStatus s) {
    _status[id] = s;
    notifyListeners();
  }

  /// Reads the state of every model from disk. Call once at start-up.
  Future<void> refresh() async {
    final root = await _root();
    for (final m in _catalog.values) {
      if (_running.containsKey(m.id)) continue;
      if (await installedDir(m.id) != null) {
        _status[m.id] = ModelStatus(
          ModelPhase.installed,
          receivedBytes: m.archiveBytes,
          totalBytes: m.archiveBytes,
        );
        continue;
      }
      final part = File('${root.path}/${m.id}.tar.bz2.part');
      if (await part.exists()) {
        final n = await part.length();
        _status[m.id] = ModelStatus(
          ModelPhase.paused,
          receivedBytes: n,
          totalBytes: m.archiveBytes,
        );
      } else {
        _status[m.id] = const ModelStatus(ModelPhase.notInstalled);
      }
    }
    notifyListeners();
  }

  /// Downloads and installs [id], resuming a partial download. Returns once
  /// installed; status changes go to listeners. With [wifiOnly] and a metered
  /// network, the status becomes [ModelPhase.waitingForWifi] and nothing is
  /// downloaded.
  Future<void> download(String id, {bool wifiOnly = true}) {
    final running = _running[id];
    if (running != null) return running;
    final model = _catalog[id];
    if (model == null) throw ArgumentError.value(id, 'id', 'unknown model');
    final f = _download(model, wifiOnly).whenComplete(() {
      _running.remove(id);
      _subs.remove(id);
      _cancelled.remove(id);
    });
    _running[id] = f;
    return f;
  }

  /// Stops a download and keeps what was received.
  Future<void> cancel(String id) async {
    final c = _cancelled[id];
    if (c != null && !c.isCompleted) c.complete();
    await _subs[id]?.cancel();
    try {
      await _running[id];
    } catch (_) {}
  }

  /// Removes the installed files and any partial download.
  Future<void> delete(String id) async {
    await cancel(id);
    final root = await _root();
    for (final path in [
      '${root.path}/$id',
      '${root.path}/$id.extracting',
    ]) {
      final d = Directory(path);
      if (await d.exists()) await d.delete(recursive: true);
    }
    for (final path in [
      '${root.path}/$id.tar.bz2.part',
      '${root.path}/$id.part.json',
    ]) {
      final f = File(path);
      if (await f.exists()) await f.delete();
    }
    _set(id, const ModelStatus(ModelPhase.notInstalled));
  }

  Future<void> redownload(String id, {bool wifiOnly = true}) async {
    await delete(id);
    await download(id, wifiOnly: wifiOnly);
  }

  Future<void> _download(SpeechModel m, bool wifiOnly) async {
    final root = await _root();
    if (await installedDir(m.id) != null) {
      _set(m.id, ModelStatus(ModelPhase.installed, totalBytes: m.archiveBytes, receivedBytes: m.archiveBytes));
      return;
    }
    final part = File('${root.path}/${m.id}.tar.bz2.part');
    final meta = File('${root.path}/${m.id}.part.json');

    // A partial file from another URL or pin cannot be resumed.
    if (await part.exists()) {
      Map<String, Object?>? info;
      try {
        info = jsonDecode(await meta.readAsString()) as Map<String, Object?>;
      } catch (_) {}
      if (info?['url'] != m.url || info?['sha256'] != m.sha256) {
        await part.delete();
      }
    }
    var have = await part.exists() ? await part.length() : 0;
    if (have > m.archiveBytes) {
      await part.delete();
      have = 0;
    }

    if (have < m.archiveBytes) {
      if (wifiOnly) {
        final net = await _platform.networkInfo();
        if (!net.unmetered) {
          _set(
            m.id,
            ModelStatus(
              ModelPhase.waitingForWifi,
              receivedBytes: have,
              totalBytes: m.archiveBytes,
              error: net.connected
                  ? 'Waiting for Wi-Fi. Turn off "Download on Wi-Fi only" to use mobile data.'
                  : 'No connection.',
            ),
          );
          return;
        }
      }
      final free = await _platform.freeBytes(root.path);
      final need = (m.archiveBytes - have) + m.installedBytes + (20 << 20);
      if (free != null && free < need) {
        _fail(m, have, 'Not enough storage: ${_mb(need)} needed, ${_mb(free)} free.');
        return;
      }
      await meta.writeAsString(jsonEncode({'url': m.url, 'sha256': m.sha256}));
      final ok = await _fetch(m, part, have);
      if (!ok) return;
    }

    _set(m.id, ModelStatus(ModelPhase.verifying, receivedBytes: m.archiveBytes, totalBytes: m.archiveBytes));
    final actual = await _hash(part.path);
    if (actual != m.sha256) {
      await part.delete();
      if (await meta.exists()) await meta.delete();
      _fail(m, 0, 'The download was damaged (checksum mismatch). Try again.');
      throw ModelChecksumException(m.sha256, actual);
    }

    _set(m.id, ModelStatus(ModelPhase.extracting, receivedBytes: m.archiveBytes, totalBytes: m.archiveBytes));
    final staging = Directory('${root.path}/${m.id}.extracting');
    try {
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);
      await _extract(part.path, staging.path);
      var src = Directory('${staging.path}/${m.archiveRoot}');
      if (!await src.exists()) src = staging;
      for (final skip in m.skipDirs) {
        final d = Directory('${src.path}/$skip');
        if (await d.exists()) await d.delete(recursive: true);
      }
      final missing = <String>[
        for (final f in m.requiredFiles)
          if (!await File('${src.path}/$f').exists()) f,
      ];
      if (missing.isNotEmpty) {
        throw FileSystemException('Missing files: ${missing.join(', ')}');
      }
      final target = Directory('${root.path}/${m.id}');
      if (await target.exists()) await target.delete(recursive: true);
      await src.rename(target.path);
      await File('${target.path}/installed.json').writeAsString(
        jsonEncode({
          'id': m.id,
          'sha256': m.sha256,
          'url': m.url,
          'installedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      await part.delete();
      if (await meta.exists()) await meta.delete();
      _set(m.id, ModelStatus(ModelPhase.installed, receivedBytes: m.archiveBytes, totalBytes: m.archiveBytes));
    } catch (e) {
      _fail(m, m.archiveBytes, 'Could not unpack the model: $e');
      rethrow;
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  /// Streams the archive into [part] from byte [have]. Returns false when
  /// cancelled or failed (status already set).
  Future<bool> _fetch(SpeechModel m, File part, int have) async {
    final req = http.Request('GET', Uri.parse(m.url));
    if (have > 0) req.headers['Range'] = 'bytes=$have-';
    final http.StreamedResponse res;
    try {
      res = await _client.send(req);
    } catch (e) {
      _pause(m, have, 'Download interrupted. It will resume where it stopped.');
      return false;
    }

    var offset = have;
    if (res.statusCode == 206) {
      final range = res.headers['content-range'] ?? '';
      final start = int.tryParse(
        RegExp(r'bytes (\d+)-').firstMatch(range)?.group(1) ?? '',
      );
      if (start != have) {
        await res.stream.drain<void>().catchError((_) {});
        await part.delete();
        _fail(m, 0, 'The server sent the wrong part of the file. Try again.');
        return false;
      }
    } else if (res.statusCode == 200) {
      offset = 0; // Server ignored Range: start over.
    } else if (res.statusCode == 416 && have > 0) {
      await res.stream.drain<void>().catchError((_) {});
      return true; // Already complete; the hash decides.
    } else {
      await res.stream.drain<void>().catchError((_) {});
      _fail(m, have, 'Download failed (HTTP ${res.statusCode}).');
      return false;
    }

    final sink = part.openWrite(mode: offset == 0 ? FileMode.write : FileMode.append);
    var received = offset;
    var lastTick = DateTime.now();
    _set(m.id, ModelStatus(ModelPhase.downloading, receivedBytes: received, totalBytes: m.archiveBytes));

    final done = Completer<bool>();
    final cancelled = _cancelled[m.id] = Completer<void>();
    final sub = res.stream.listen(
      (chunk) {
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastTick) >= progressInterval) {
          lastTick = now;
          _set(m.id, ModelStatus(ModelPhase.downloading, receivedBytes: received, totalBytes: m.archiveBytes));
        }
      },
      onError: (Object e) {
        if (!done.isCompleted) done.complete(false);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(true);
      },
      cancelOnError: true,
    );
    _subs[m.id] = sub;
    unawaited(cancelled.future.then((_) {
      if (!done.isCompleted) done.complete(false);
    }));

    final ok = await done.future;
    await sub.cancel();
    await sink.flush();
    await sink.close();

    if (!ok || received < m.archiveBytes) {
      _pause(
        m,
        received,
        cancelled.isCompleted ? null : 'Download interrupted. It will resume where it stopped.',
      );
      return false;
    }
    return true;
  }

  void _pause(SpeechModel m, int have, String? why) => _set(
    m.id,
    ModelStatus(ModelPhase.paused, receivedBytes: have, totalBytes: m.archiveBytes, error: why),
  );

  void _fail(SpeechModel m, int have, String why) => _set(
    m.id,
    ModelStatus(ModelPhase.failed, receivedBytes: have, totalBytes: m.archiveBytes, error: why),
  );

  static String _mb(int bytes) => '${(bytes / (1 << 20)).ceil()} MB';

  @override
  void dispose() {
    for (final s in _subs.values) {
      s.cancel();
    }
    _client.close();
    super.dispose();
  }
}
