import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/speech/speech.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'speech_fakes.dart';

/// A real `.tar.bz2` with the layout of a sherpa-onnx model archive.
Uint8List _archive() {
  final a = Archive()
    ..add(ArchiveFile.bytes('tiny-model/model.onnx', utf8.encode('weights')))
    ..add(ArchiveFile.bytes('tiny-model/tokens.txt', utf8.encode('a 1\n')))
    ..add(ArchiveFile.bytes('tiny-model/espeak-ng-data/en_dict', utf8.encode('gpl data')))
    ..add(ArchiveFile.bytes('tiny-model/LICENSE', utf8.encode('Apache-2.0')));
  return BZip2Encoder().encodeBytes(TarEncoder().encodeBytes(a));
}

SpeechModel _model(Uint8List bytes, {String? hash}) => SpeechModel(
  id: 'tiny-model',
  kind: SpeechModelKind.tts,
  title: 'Tiny',
  description: 'test',
  url: 'https://example.test/tiny-model.tar.bz2',
  sha256: hash ?? sha256.convert(bytes).toString(),
  archiveBytes: bytes.length,
  installedBytes: 100,
  archiveRoot: 'tiny-model',
  requiredFiles: const ['model.onnx', 'tokens.txt'],
  skipDirs: const ['espeak-ng-data'],
  licence: 'test',
);

/// Serves [bytes] with Range support. [cutAt] ends the first response early
/// with an error, like a dropped connection.
class _Server {
  _Server(this.bytes, {this.cutAt, this.honourRange = true, this.hold});

  final Uint8List bytes;
  int? cutAt;

  /// When set, the body stalls after its first chunk until it completes.
  final Completer<void>? hold;
  final firstChunk = Completer<void>();
  final bool honourRange;
  final ranges = <String?>[];

  http.Client client() => MockClient.streaming((req, _) async {
    final range = req.headers['Range'];
    ranges.add(range);
    var start = 0;
    if (range != null && honourRange) {
      start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
    }
    final body = bytes.sublist(start);
    final cut = cutAt;
    cutAt = null;
    final controller = StreamController<List<int>>();
    () async {
      const step = 7;
      for (var i = 0; i < body.length; i += step) {
        if (cut != null && start + i >= cut) {
          controller.addError(const SocketException('connection reset'));
          break;
        }
        controller.add(body.sublist(i, i + step > body.length ? body.length : i + step));
        if (!firstChunk.isCompleted) {
          firstChunk.complete();
          if (hold != null) await hold!.future;
        }
        await Future<void>.delayed(Duration.zero);
      }
      await controller.close();
    }();
    return http.StreamedResponse(
      controller.stream,
      range != null && honourRange ? 206 : 200,
      headers: {
        if (range != null && honourRange)
          'content-range': 'bytes $start-${bytes.length - 1}/${bytes.length}',
      },
    );
  });
}

void main() {
  late Directory tmp;
  late FakeSpeechPlatform platform;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('speech-models-');
    platform = FakeSpeechPlatform();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  ModelManager manager(SpeechModel m, _Server s) => ModelManager(
    baseDir: () async => tmp,
    client: s.client(),
    platform: platform,
    catalog: [m],
    progressInterval: Duration.zero,
  );

  test('downloads, verifies, extracts and drops espeak-ng-data', () async {
    final bytes = _archive();
    final m = _model(bytes);
    final mm = manager(m, _Server(bytes));
    final phases = <ModelPhase>[];
    mm.addListener(() => phases.add(mm.status(m.id).phase));

    await mm.download(m.id);

    expect(mm.status(m.id).phase, ModelPhase.installed);
    expect(phases, containsAllInOrder([
      ModelPhase.downloading,
      ModelPhase.verifying,
      ModelPhase.extracting,
      ModelPhase.installed,
    ]));
    final dir = (await mm.installedDir(m.id))!;
    expect(await File('${dir.path}/model.onnx').readAsString(), 'weights');
    expect(await File('${dir.path}/installed.json').exists(), isTrue);
    expect(await Directory('${dir.path}/espeak-ng-data').exists(), isFalse);
    expect(await File('${tmp.path}/${m.id}.tar.bz2.part').exists(), isFalse);
  });

  test('checksum mismatch deletes the download and installs nothing', () async {
    final bytes = _archive();
    final m = _model(bytes, hash: '0' * 64);
    final mm = manager(m, _Server(bytes));
    await expectLater(mm.download(m.id), throwsA(isA<ModelChecksumException>()));
    expect(mm.status(m.id).phase, ModelPhase.failed);
    expect(mm.status(m.id).error, contains('checksum'));
    expect(await mm.installedDir(m.id), isNull);
    expect(await File('${tmp.path}/${m.id}.tar.bz2.part').exists(), isFalse);
  });

  test('an interrupted download resumes with a Range request', () async {
    final bytes = _archive();
    final m = _model(bytes);
    final server = _Server(bytes, cutAt: bytes.length ~/ 2);
    final mm = manager(m, server);

    await mm.download(m.id);
    final paused = mm.status(m.id);
    expect(paused.phase, ModelPhase.paused);
    expect(paused.receivedBytes, greaterThan(0));
    expect(paused.receivedBytes, lessThan(bytes.length));
    final part = File('${tmp.path}/${m.id}.tar.bz2.part');
    expect(await part.length(), paused.receivedBytes);

    // A fresh manager (app restart) sees the partial file.
    final again = manager(m, server);
    await again.refresh();
    expect(again.status(m.id).phase, ModelPhase.paused);
    await again.download(m.id);
    expect(server.ranges.last, 'bytes=${paused.receivedBytes}-');
    expect(again.status(m.id).phase, ModelPhase.installed);
  });

  test('a server that ignores Range restarts from zero', () async {
    final bytes = _archive();
    final m = _model(bytes);
    final cut = _Server(bytes, cutAt: bytes.length ~/ 2);
    await manager(m, cut).download(m.id);
    final mm = manager(m, _Server(bytes, honourRange: false));
    await mm.download(m.id);
    expect(mm.status(m.id).phase, ModelPhase.installed);
  });

  test('a partial file for another pin is discarded', () async {
    final bytes = _archive();
    final m = _model(bytes);
    await File('${tmp.path}/${m.id}.tar.bz2.part').writeAsBytes([1, 2, 3]);
    await File('${tmp.path}/${m.id}.part.json').writeAsString(
      jsonEncode({'url': m.url, 'sha256': 'old'}),
    );
    final server = _Server(bytes);
    final mm = manager(m, server);
    await mm.download(m.id);
    expect(server.ranges.single, isNull);
    expect(mm.status(m.id).phase, ModelPhase.installed);
  });

  test('Wi-Fi only waits on a metered network', () async {
    final bytes = _archive();
    final m = _model(bytes);
    platform.network = const NetworkInfo(connected: true, unmetered: false);
    final server = _Server(bytes);
    final mm = manager(m, server);
    await mm.download(m.id);
    expect(mm.status(m.id).phase, ModelPhase.waitingForWifi);
    expect(server.ranges, isEmpty);
    await mm.download(m.id, wifiOnly: false);
    expect(mm.status(m.id).phase, ModelPhase.installed);
  });

  test('not enough storage fails before downloading', () async {
    final bytes = _archive();
    final m = _model(bytes);
    platform.free = 1000;
    final server = _Server(bytes);
    final mm = manager(m, server);
    await mm.download(m.id);
    expect(mm.status(m.id).phase, ModelPhase.failed);
    expect(mm.status(m.id).error, contains('Not enough storage'));
    expect(server.ranges, isEmpty);
  });

  test('delete removes the install; redownload restores it', () async {
    final bytes = _archive();
    final m = _model(bytes);
    final mm = manager(m, _Server(bytes));
    await mm.download(m.id);
    await mm.delete(m.id);
    expect(mm.status(m.id).phase, ModelPhase.notInstalled);
    expect(await mm.installedDir(m.id), isNull);
    await mm.redownload(m.id);
    expect(mm.isInstalled(m.id), isTrue);
  });

  test('cancel keeps the partial download', () async {
    final bytes = _archive();
    final m = _model(bytes);
    final hold = Completer<void>();
    final server = _Server(bytes, hold: hold);
    final mm = manager(m, server);
    final f = mm.download(m.id);
    await server.firstChunk.future;
    await pump();
    expect(mm.status(m.id).phase, ModelPhase.downloading);
    await mm.cancel(m.id);
    await f;
    hold.complete();
    expect(mm.status(m.id).phase, ModelPhase.paused);
    expect(mm.status(m.id).error, isNull);
    expect(mm.status(m.id).receivedBytes, greaterThan(0));
    expect(await File('${tmp.path}/${m.id}.tar.bz2.part').exists(), isTrue);
  });

  test('catalog pins are well formed', () {
    for (final m in SpeechModels.all) {
      expect(m.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: m.id);
      expect(
        m.url,
        startsWith('https://github.com/k2-fsa/sherpa-onnx/releases/download/'),
      );
      expect(m.url, endsWith('/${m.id}.tar.bz2'));
      expect(m.archiveBytes, greaterThan(0));
    }
    expect(KokoroVariant.v1_0Fp32.model, SpeechModels.kokoroV1_0);
  });
}
