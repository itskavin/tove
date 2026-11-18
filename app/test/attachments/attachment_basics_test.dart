import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/attachments/attachments.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

void main() {
  group('limits and capabilities', () {
    test('defaults: 4 items, 10 MB images, 25 MB files, 2048 px', () {
      const l = AttachmentLimits();
      expect(l.maxItems, 4);
      expect(l.imageBytes, 10 * 1024 * 1024);
      expect(l.fileBytes, 25 * 1024 * 1024);
      expect(l.imageMaxEdge, 2048);
      expect(l.jpegQuality, 85);
      expect(l.allows('text/markdown'), isTrue, reason: 'text/*');
      expect(l.allows('application/zip'), isFalse);
    });

    test('capabilities JSON', () {
      final c = AttachmentCapabilities.fromJson({
        'attachments': true,
        'vision': true,
        'web_search': true,
        'attachment_limits': {'max_items': 6, 'image_mb': 5, 'file_mb': 'x'},
      });
      expect(c.attachments, isTrue);
      expect(c.vision, isTrue);
      expect(c.webSearch, isTrue);
      expect(c.limits.maxItems, 6);
      expect(c.limits.imageBytes, 5 * 1024 * 1024);
      expect(c.limits.fileBytes, 25 * 1024 * 1024, reason: 'invalid → default');
      expect(
        AttachmentCapabilities.fromJson({'attachments': false}).attachments,
        isFalse,
      );
    });

    test('formatting helpers', () {
      expect(formatBytes(12), '12 B');
      expect(formatBytes(2048), '2.0 KB');
      expect(formatBytes(880 * 1024), '880 KB');
      expect(formatBytes(4404019), '4.2 MB');
      expect(middleEllipsis('short.pdf'), 'short.pdf');
      final m = middleEllipsis('quarterly-report-final-v2-2026.pdf');
      expect(m.length, 22);
      expect(m, endsWith('2026.pdf'));
      expect(m, contains('…'));
      expect(mimeForName('A.PNG'), 'image/png');
      expect(mimeForName('x.docx'), contains('wordprocessingml'));
      expect(mimeForName('noext'), 'application/octet-stream');
    });
  });

  group('image preparation', () {
    Uint8List jpegWithGps(int w, int h, {int orientation = 1}) {
      final image = img.Image(width: w, height: h);
      img.fill(image, color: img.ColorRgb8(200, 30, 30));
      image.exif.imageIfd.orientation = orientation;
      image.exif.imageIfd['Make'] = img.IfdValueAscii('TestCam');
      image.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(51, 1);
      return img.encodeJpg(image);
    }

    test('downscales to the long edge and strips EXIF and GPS', () {
      final src = jpegWithGps(3000, 1500);
      expect(img.decodeJpgExif(src)!.gpsIfd.isEmpty, isFalse);
      final out = prepareImageSync(src, 2048, 85)!;
      expect(out.mime, 'image/jpeg');
      expect(out.width, 2048);
      expect(out.height, 1024);
      final exif = img.decodeJpgExif(out.bytes);
      expect(exif == null || exif.isEmpty, isTrue, reason: 'no metadata left');
    });

    test('bakes the EXIF orientation into the pixels', () {
      // Orientation 6: stored landscape, shown portrait.
      final out = prepareImageSync(
        jpegWithGps(400, 200, orientation: 6),
        2048,
        85,
      )!;
      expect(out.width, 200);
      expect(out.height, 400);
    });

    test('transparent PNGs stay PNG, opaque ones become JPEG', () {
      final clear = img.Image(width: 10, height: 10, numChannels: 4);
      final opaque = img.Image(width: 10, height: 10, numChannels: 4);
      img.fill(opaque, color: img.ColorRgba8(1, 2, 3, 255));
      expect(
        prepareImageSync(img.encodePng(clear), 2048, 85)!.mime,
        'image/png',
      );
      expect(
        prepareImageSync(img.encodePng(opaque), 2048, 85)!.mime,
        'image/jpeg',
      );
    });

    test('unreadable data gives null (the engine codec is tried next)', () {
      expect(
        prepareImageSync(Uint8List.fromList([1, 2, 3, 4]), 2048, 85),
        isNull,
      );
    });
  });

  group('BridgeUploadClient', () {
    test(
      'posts one multipart file with the key and parses the answer',
      () async {
        late http.BaseRequest seen;
        late String body;
        final client = MockClient((req) async {
          seen = req;
          body = latin1.decode(req.bodyBytes);
          return http.Response(
            jsonEncode({
              'id': 'up_1',
              'name': 'café.txt',
              'mime': 'text/plain',
              'size': 5,
              'kind': 'file',
              'sha256': 'abc',
            }),
            201,
          );
        });
        final progress = <double>[];
        final up = BridgeUploadClient(
          baseUrl: Uri.parse('https://bridge.example/base/'),
          accessKey: 'k',
          client: client,
          chunkSize: 2,
        );
        final r = await up.upload(
          name: 'café.txt',
          mime: 'text/plain',
          bytes: Uint8List.fromList(utf8.encode('hello')),
          conversationId: 'c1',
          onProgress: progress.add,
        );
        expect(seen.url.toString(), 'https://bridge.example/base/api/uploads');
        expect(seen.headers['Authorization'], 'Bearer k');
        expect(
          seen.headers['Content-Type'],
          startsWith('multipart/form-data; boundary='),
        );
        expect(body, contains('name="conversation_id"\r\n\r\nc1\r\n'));
        expect(body, contains('filename="caf_.txt"'));
        expect(body, contains("filename*=UTF-8''caf%C3%A9.txt"));
        expect(body, contains('Content-Type: text/plain\r\n\r\nhello\r\n--'));
        expect(r.id, 'up_1');
        expect(r.kind, AttachmentKind.file);
        expect(progress.first, 0);
        expect(progress.last, 1);
        expect(progress.length, greaterThan(3), reason: 'chunked progress');
      },
    );

    test('maps bridge errors', () async {
      Future<UploadException> fail(int status, [String? code]) async {
        final up = BridgeUploadClient(
          baseUrl: Uri.parse('https://b'),
          accessKey: 'k',
          client: MockClient(
            (_) async => http.Response(
              code == null
                  ? 'Not Found'
                  : jsonEncode({'error': code, 'code': code, 'message': 'm'}),
              status,
            ),
          ),
        );
        try {
          await up.upload(name: 'a', mime: 'text/plain', bytes: Uint8List(1));
        } on UploadException catch (e) {
          return e;
        }
        throw StateError('no error');
      }

      expect((await fail(413, 'too_large')).kind, UploadErrorKind.tooLarge);
      expect(
        (await fail(415, 'unsupported_type')).kind,
        UploadErrorKind.unsupported,
      );
      expect((await fail(507, 'quota_exceeded')).kind, UploadErrorKind.quota);
      expect((await fail(404)).kind, UploadErrorKind.unavailable);
      final server = await fail(500, 'bridge_error');
      expect(server.kind, UploadErrorKind.server);
      expect(server.retryable, isTrue);
      expect((await fail(413, 'too_large')).retryable, isFalse);
    });

    test('a network failure is retryable', () async {
      final up = BridgeUploadClient(
        baseUrl: Uri.parse('https://b'),
        accessKey: 'k',
        client: MockClient((_) async => throw http.ClientException('down')),
      );
      await expectLater(
        up.upload(name: 'a', mime: 'text/plain', bytes: Uint8List(1)),
        throwsA(
          isA<UploadException>()
              .having((e) => e.kind, 'kind', UploadErrorKind.network)
              .having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
    });

    test('resolves preview URLs against the base', () {
      final up = BridgeUploadClient(
        baseUrl: Uri.parse('https://b.example/x/'),
        accessKey: 'k',
      );
      expect(
        up.resolve('/api/uploads/u/preview').toString(),
        'https://b.example/x/api/uploads/u/preview',
      );
      up.close();
    });
  });
}
