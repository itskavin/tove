import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tove_chat/src/ui/markdown/md_images.dart';

// Plain tests only: the widget test binding stalls MockClient requests, so
// these stay apart from images_test.dart.

/// A 1×1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

String _previewBody({
  String? image,
  String kind = 'image',
  int? width,
  int? height,
}) => jsonEncode({
  'url': 'https://i.example/final.png',
  'title': null,
  'site_name': 'i.example',
  'image': image,
  'favicon': null,
  'kind': kind,
  'width': width,
  'height': height,
});

String _dataUrl(List<int> bytes, [String type = 'image/png']) =>
    'data:$type;base64,${base64Encode(bytes)}';

/// A bridge from before `/api/image`: aiohttp's plain-text 404 there.
MockClient _old(Future<http.Response> Function(http.Request) handler) =>
    MockClient(
      (r) async => r.url.path.endsWith('/api/image')
          ? http.Response(
              '404: Not Found',
              404,
              headers: {'content-type': 'text/plain; charset=utf-8'},
            )
          : handler(r),
    );

void main() {
  group('parseLinkPreviewImage', () {
    Uint8List body(String s) => Uint8List.fromList(utf8.encode(s));

    test('reads a direct image with its size', () {
      final img = parseLinkPreviewImage(
        body(_previewBody(image: _dataUrl(_png), width: 640, height: 480)),
      )!;
      expect(img.bytes, _png);
      expect(img.url, 'https://i.example/final.png');
      expect(img.aspect, closeTo(4 / 3, 1e-9));
    });

    test('a page with an og:image works too', () {
      final img = parseLinkPreviewImage(
        body(_previewBody(image: _dataUrl(_png, 'image/jpeg'), kind: 'page')),
      )!;
      expect(img.width, isNull);
      expect(img.aspect, isNull);
    });

    test('no image, other types and bad data give nothing', () {
      for (final b in [
        _previewBody(),
        _previewBody(image: _dataUrl(_png, 'image/svg+xml')),
        _previewBody(image: 'https://i.example/a.png'),
        _previewBody(image: 'data:image/png;base64,@@@'),
        _previewBody(image: 'data:image/png;base64,'),
        '[1, 2]',
        'not json',
      ]) {
        expect(parseLinkPreviewImage(body(b)), isNull, reason: b);
      }
    });

    test('nonsense sizes are dropped', () {
      final img = parseLinkPreviewImage(
        body(_previewBody(image: _dataUrl(_png), width: 0, height: -3)),
      )!;
      expect(img.width, isNull);
      expect(img.height, isNull);
    });
  });

  group('BridgeImageLoader', () {
    test('asks the bridge with the key, never the image host', () async {
      final seen = <http.Request>[];
      final loader = BridgeImageLoader(
        baseUrl: Uri.parse('https://bridge.example/hermes/'),
        accessKey: 'k',
        client: _old((r) async {
          seen.add(r);
          return http.Response(_previewBody(image: _dataUrl(_png)), 200);
        }),
      );
      final r = await loader.load('https://i.example/a.png?x=1&y=2');
      expect(r.image!.bytes, _png);
      expect(seen, hasLength(1));
      final u = seen.single.url;
      expect(u.host, 'bridge.example');
      expect(u.path, '/hermes/api/link-preview');
      expect(u.queryParameters['url'], 'https://i.example/a.png?x=1&y=2');
      expect(seen.single.headers['Authorization'], 'Bearer k');
    });

    test('shares one request and answers again from memory', () async {
      var n = 0;
      final loader = BridgeImageLoader(
        baseUrl: Uri.parse('https://bridge.example'),
        accessKey: 'k',
        client: _old((r) async {
          n++;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return http.Response(_previewBody(image: _dataUrl(_png)), 200);
        }),
      );
      const url = 'https://i.example/a.png';
      expect(loader.peek(url), isNull);
      final both = await Future.wait([loader.load(url), loader.load(url)]);
      expect(n, 1);
      expect(both[0].image, isNotNull);
      expect(loader.peek(url)!.image!.bytes, _png);
      await loader.load(url);
      expect(n, 1);
    });

    test('remembers a refusal; retry asks again', () async {
      var n = 0;
      final loader = BridgeImageLoader(
        baseUrl: Uri.parse('https://bridge.example'),
        accessKey: 'k',
        client: _old((r) async {
          n++;
          return http.Response('{"error":"blocked_url"}', 400);
        }),
      );
      const url = 'https://10.0.0.1/a.png';
      expect((await loader.load(url)).image, isNull);
      expect(loader.peek(url), isNotNull);
      await loader.load(url);
      expect(n, 1);
      await loader.load(url, retry: true);
      expect(n, 2);
    });

    test('a network failure is not remembered', () async {
      var fail = true;
      final loader = BridgeImageLoader(
        baseUrl: Uri.parse('https://bridge.example'),
        accessKey: 'k',
        client: _old((r) async {
          if (fail) throw http.ClientException('offline');
          return http.Response(_previewBody(image: _dataUrl(_png)), 200);
        }),
      );
      const url = 'https://i.example/a.png';
      expect((await loader.load(url)).image, isNull);
      expect(loader.peek(url), isNull);
      fail = false;
      expect((await loader.load(url)).image, isNotNull);
    });

    test('drops the least recently used images past the byte budget', () async {
      final loader = BridgeImageLoader(
        baseUrl: Uri.parse('https://bridge.example'),
        accessKey: 'k',
        maxBytes: _png.length * 2,
        client: _old(
          (r) async => http.Response(_previewBody(image: _dataUrl(_png)), 200),
        ),
      );
      await loader.load('https://i.example/1.png');
      await loader.load('https://i.example/2.png');
      loader.peek('https://i.example/1.png'); // now most recent
      await loader.load('https://i.example/3.png');
      expect(loader.peek('https://i.example/1.png'), isNotNull);
      expect(loader.peek('https://i.example/2.png'), isNull);
      expect(loader.peek('https://i.example/3.png'), isNotNull);
    });
  });

  group('BridgeImageLoader with /api/image (round 6 B5)', () {
    test('takes the raw bytes and the size headers', () async {
      final seen = <http.Request>[];
      final loader = BridgeImageLoader(
        baseUrl: Uri.parse('https://bridge.example/hermes/'),
        accessKey: 'k',
        client: MockClient((r) async {
          seen.add(r);
          return http.Response.bytes(
            _png,
            200,
            headers: {
              'content-type': 'image/png',
              'x-image-width': '960',
              'x-image-height': '640',
            },
          );
        }),
      );
      const url = 'https://upload.wikimedia.org/wikipedia/commons/a/ab/X.jpg';
      final r = await loader.load(url);
      expect(r.image!.bytes, _png);
      expect(r.image!.aspect, closeTo(1.5, 1e-9));
      final u = seen.single.url;
      expect(u.path, '/hermes/api/image');
      expect(u.queryParameters, {'url': url, 'w': '1280'});
      expect(seen.single.headers['Authorization'], 'Bearer k');
      expect(loader.imageRoute, isTrue);
      expect(loader.peek(url)!.image, isNotNull);
    });

    test(
      'a refusal is remembered, a 502 is not, an old bridge falls back',
      () async {
        var status = 415;
        var n = 0;
        final loader = BridgeImageLoader(
          baseUrl: Uri.parse('https://bridge.example'),
          accessKey: 'k',
          client: MockClient((r) async {
            n++;
            return http.Response(
              '{"error":"x","code":"x"}',
              status,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        expect((await loader.load('https://i.example/a.svg')).image, isNull);
        expect(loader.peek('https://i.example/a.svg'), isNotNull);
        status = 502;
        expect((await loader.load('https://i.example/b.png')).image, isNull);
        expect(loader.peek('https://i.example/b.png'), isNull, reason: 'retry');
        expect(n, 2);

        final old = BridgeImageLoader(
          baseUrl: Uri.parse('https://bridge.example'),
          accessKey: 'k',
          client: _old(
            (r) async =>
                http.Response(_previewBody(image: _dataUrl(_png)), 200),
          ),
        );
        expect((await old.load('https://i.example/a.png')).image, isNotNull);
        expect(old.imageRoute, isFalse);
      },
    );
  });

  group('BridgeImageLoader: entity info and page pictures', () {
    test('GET /api/entity/info with name and hint; cached; parsed', () async {
      final asked = <Uri>[];
      final client = MockClient((r) async {
        asked.add(r.url);
        expect(r.headers['authorization'], 'Bearer k');
        return http.Response(
          jsonEncode({
            'title': 'Jensen Huang',
            'description': 'Businessman',
            'extract': 'An engineer.',
            'image': 'https://thumb.wikimedia.org/a.jpg',
            'original_image': 'https://upload.wikimedia.org/a.jpg',
            'page': 'https://en.wikipedia.org/wiki/Jensen_Huang',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final loader = BridgeImageLoader(
        baseUrl: Uri.parse('https://bridge.test/'),
        accessKey: 'k',
        client: client,
      );
      final i = await loader.entityInfo('Jensen Huang', hint: 'CEO');
      expect(i!.title, 'Jensen Huang');
      expect(i.originalImage, 'https://upload.wikimedia.org/a.jpg');
      expect(asked.single.path, '/api/entity/info');
      expect(asked.single.queryParameters, {
        'name': 'Jensen Huang',
        'hint': 'CEO',
      });
      await loader.entityInfo('jensen huang', hint: 'ceo');
      expect(asked, hasLength(1), reason: 'cached');
      expect(loader.peekEntityInfo('Jensen Huang', hint: 'CEO'), isNotNull);
    });

    test('an older bridge (plain-text 404) is remembered; 502 is not '
        'cached', () async {
      var status = 502;
      var calls = 0;
      final loader = BridgeImageLoader(
        baseUrl: Uri.parse('https://bridge.test'),
        accessKey: 'k',
        client: MockClient((r) async {
          calls++;
          return status == 404
              ? http.Response('404: Not Found', 404)
              : http.Response('{"code":"fetch_failed"}', status);
        }),
      );
      expect(await loader.entityInfo('A'), isNull);
      expect(await loader.entityInfo('A'), isNull);
      expect(calls, 2, reason: '502: asked again');
      status = 404;
      expect(await loader.entityInfo('B'), isNull);
      expect(loader.entityRoute, isFalse);
      await loader.entityInfo('C');
      expect(calls, 3);
    });

    test('a page picture comes from the link preview', () async {
      final png = base64Encode(List.filled(8, 1));
      final loader = BridgeImageLoader(
        baseUrl: Uri.parse('https://bridge.test'),
        accessKey: 'k',
        client: MockClient((r) async {
          expect(r.url.path, '/api/link-preview');
          return http.Response(
            jsonEncode({
              'url': 'https://n.example/a',
              'image': 'data:image/png;base64,$png',
            }),
            200,
          );
        }),
      );
      final r = await loader.loadPageImage('https://n.example/a');
      expect(r.image, isNotNull);
      expect(loader.peekPageImage('https://n.example/a'), isNotNull);
    });
  });
}
