import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tove_chat/src/pairing/pair_link.dart';
import 'package:tove_chat/src/pairing/pairing.dart';
import 'package:tove_chat/src/platform/app_links.dart';

/// `tove://pair?u=…&c=…` links and `POST /api/pair` (server/API.md "Pairing").
void main() {
  group('PairLink.parse', () {
    test('the link tove_pair.py makes', () {
      final l = PairLink.parse(
        'tove://pair?u=https%3A%2F%2Fbox.tail1234.ts.net%3A8787&c=ABCDE-FGHJK'
        '&n=Home%20server',
      );
      expect(l, isNotNull);
      expect(l!.server, Uri.parse('https://box.tail1234.ts.net:8787'));
      expect(l.code, 'ABCDEFGHJK');
      expect(l.name, 'Home server');
      expect(PairLink.pretty(l.code), 'ABCDE-FGHJK');
    });

    test('tolerant of case, spaces and a trailing slash', () {
      final l = PairLink.parse(
        ' tove://pair?c=abcde%20fghjk&u=https://tove.example.com/ ',
      )!;
      expect(l.server.toString(), 'https://tove.example.com');
      expect(l.code, 'ABCDEFGHJK');
      expect(l.name, isNull);
      // A sub-path (a reverse proxy at /tove) is kept.
      expect(
        PairLink.parse('tove://pair?u=https://example.org/tove/&c=ABCDEFGHJK')!
            .server
            .toString(),
        'https://example.org/tove',
      );
    });

    test('anything else is not a pairing link', () {
      for (final bad in [
        null,
        '',
        'https://tove.example.com',
        'tove://live',
        'tove://chat/new',
        'tove://pair',
        'tove://pair?u=https://x.example',
        'tove://pair?c=ABCDEFGHJK',
        'tove://pair/extra?u=https://x.example&c=ABCDEFGHJK',
        'tove://pair?u=ftp://x.example&c=ABCDEFGHJK',
        'tove://pair?u=https://user:pw@x.example&c=ABCDEFGHJK',
        'tove://pair?u=https://x.example&c=ABC',
        'tove://pair?u=https://x.example&c=AB%24DEFGHJ',
        'tove://pair?u=https://x.example&c=${'A' * 40}',
        'other://pair?u=https://x.example&c=ABCDEFGHJK',
      ]) {
        expect(PairLink.parse(bad), isNull, reason: '$bad');
      }
    });

    test('codes and addresses typed by hand', () {
      expect(PairLink.normalizeCode('abcde-fghjk'), 'ABCDEFGHJK');
      expect(PairLink.normalizeCode(' ab cd e-fg hjk '), 'ABCDEFGHJK');
      expect(PairLink.normalizeCode('ABC'), isNull);
      expect(PairLink.normalizeCode('ABCDE/FGHJK'), isNull);
      expect(
        PairLink.parseServer('box.tail1234.ts.net:8787').toString(),
        'https://box.tail1234.ts.net:8787',
      );
      expect(PairLink.parseServer('http://127.0.0.1:8787')!.scheme, 'http');
      expect(PairLink.parseServer('  '), isNull);
    });

    test('a long name is clipped', () {
      final l = PairLink.parse(
        'tove://pair?u=https://x.example&c=ABCDEFGHJK&n=${'n' * 100}',
      )!;
      expect(l.name!.length, 60);
    });
  });

  group('pairWithBridge', () {
    final server = Uri.parse('https://tove.example.com');

    Future<PairResult> pairWith(int status, Object? body) => pairWithBridge(
      server,
      'ABCDEFGHJK',
      client: MockClient((req) async {
        expect(req.method, 'POST');
        expect(req.url.toString(), 'https://tove.example.com/api/pair');
        expect(jsonDecode(req.body), {'code': 'ABCDEFGHJK'});
        expect(req.headers['authorization'], isNull);
        return http.Response(
          body is String ? body : jsonEncode(body),
          status,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    Future<PairingProblem> problem(int status, Object? body) async {
      try {
        await pairWith(status, body);
      } on PairingException catch (e) {
        expect(e.message, isNotEmpty);
        return e.problem;
      }
      fail('no exception');
    }

    test('a good code gives the key and name', () async {
      final r = await pairWith(200, {
        'key': 'k' * 43,
        'name': 'Hermes',
        'version': 2,
      });
      expect(r.key, 'k' * 43);
      expect(r.name, 'Hermes');
    });

    test('each answer maps to a plain problem', () async {
      expect(
        await problem(410, {'code': 'code_expired'}),
        PairingProblem.expired,
      );
      expect(
        await problem(401, {'code': 'invalid_code'}),
        PairingProblem.wrongCode,
      );
      expect(
        await problem(400, {'code': 'bad_request'}),
        PairingProblem.wrongCode,
      );
      expect(await problem(404, '404: Not Found'), PairingProblem.unsupported);
      expect(
        await problem(503, {'code': 'pairing_off'}),
        PairingProblem.server,
      );
      expect(await problem(200, {'key': 'short'}), PairingProblem.server);
      expect(await problem(502, '<html>'), PairingProblem.server);
    });

    test('too many tries says how long to wait', () async {
      try {
        await pairWith(429, {
          'code': 'too_many_attempts',
          'retry_after_s': 290,
        });
        fail('no exception');
      } on PairingException catch (e) {
        expect(e.problem, PairingProblem.tooManyTries);
        expect(e.message, contains('5 minutes'));
      }
    });

    test('no answer is "unreachable"', () async {
      try {
        await pairWithBridge(
          server,
          'ABCDEFGHJK',
          client: MockClient((_) => throw const SocketException('down')),
        );
        fail('no exception');
      } on PairingException catch (e) {
        expect(e.problem, PairingProblem.unreachable);
        expect(e.message, contains('Tailscale'));
      }
    });

    test('plain http to another machine is refused before sending', () async {
      var sent = false;
      try {
        await pairWithBridge(
          Uri.parse('http://192.168.1.20:8787'),
          'ABCDEFGHJK',
          client: MockClient((_) async {
            sent = true;
            return http.Response('{}', 200);
          }),
        );
        fail('no exception');
      } on PairingException catch (e) {
        expect(e.problem, PairingProblem.insecure);
      }
      expect(sent, isFalse);
      expect(insecureAddress(Uri.parse('http://127.0.0.1:8787')), isFalse);
      expect(insecureAddress(Uri.parse('https://192.168.1.20')), isFalse);
    });
  });

  group('AppLinks', () {
    const name = 'test/pair-links';
    const codec = StandardMethodCodec();
    const pairLink = 'tove://pair?u=https%3A%2F%2Fx.example&c=ABCDE-FGHJK';
    late AppLinks links;
    String? initial;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      links = AppLinks(channel: const MethodChannel(name), android: true);
      var asked = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(name), (c) async {
            if (c.method == 'initialLink') {
              asked++;
              expect(asked, 1, reason: 'the native side hands it out once');
              return initial;
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(name), null);
      links.dispose();
    });

    test('a pairing link that started the app goes to initialPair', () async {
      initial = pairLink;
      expect(await links.initial(), isNull);
      expect((await links.initialPair())!.code, 'ABCDEFGHJK');
    });

    test('a widget link still goes to initial', () async {
      initial = 'tove://live';
      expect(await links.initialPair(), isNull);
      expect(await links.initial(), const OpenLive());
    });

    test('running: pairing links on their own stream', () async {
      final pairs = <PairLink>[];
      final actions = <LaunchAction>[];
      final s1 = links.pairs.listen(pairs.add);
      final s2 = links.actions.listen(actions.add);
      for (final l in [pairLink, 'tove://chat/new', 'tove://pair?u=x']) {
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              name,
              codec.encodeMethodCall(MethodCall('link', l)),
              (_) {},
            );
      }
      await Future<void>.delayed(Duration.zero);
      expect(pairs.map((p) => p.code), ['ABCDEFGHJK']);
      expect(actions, [const NewChatAction()]);
      expect(LaunchAction.parse(pairLink), isNull);
      await s1.cancel();
      await s2.cancel();
    });
  });
}
