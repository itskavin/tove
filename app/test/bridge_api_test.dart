import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/bridge/bridge_api.dart';
import 'package:tove_chat/src/call/protocol.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

void main() {
  BridgeApi api(MockClientHandler h, {String base = 'https://b.test:9476/'}) =>
      BridgeApi(
        baseUrl: Uri.parse(base),
        accessKey: testKey,
        client: MockClient(h),
        requestTimeout: const Duration(milliseconds: 200),
      );

  test('verifyKey: 404 means the key is right', () async {
    late Uri seen;
    await api((r) async {
      seen = r.url;
      expect(r.headers['Authorization'], 'Bearer $testKey');
      return http.Response('{"error":"no such job"}', 404);
    }).verifyKey();
    expect(seen.toString(), 'https://b.test:9476/api/job/check/check');
  });

  test('verifyKey: 401 is an auth error', () async {
    final f = api((_) async => http.Response('', 401)).verifyKey();
    await expectLater(
      f,
      throwsA(
        isA<BridgeException>().having((e) => e.unauthorized, 'auth', true),
      ),
    );
  });

  test('network failure and timeouts are unreachable errors', () async {
    await expectLater(
      api((_) async => throw Exception('dns')).verifyKey(),
      throwsA(isA<BridgeException>().having((e) => e.unreachable, 'u', true)),
    );
    await expectLater(
      api((_) => Completer<http.Response>().future).verifyKey(),
      throwsA(isA<BridgeException>().having((e) => e.unreachable, 'u', true)),
    );
  });

  test('server errors carry the server message and status', () async {
    final f = api((_) async => http.Response('{"error":"busy"}', 429))
        .delegate(session: 's', text: 't');
    await expectLater(
      f,
      throwsA(
        isA<BridgeException>()
            .having((e) => e.busy, 'busy', true)
            .having((e) => e.message, 'msg', 'busy'),
      ),
    );
  });

  test('base paths are kept', () async {
    late Uri seen;
    await api((r) async {
      seen = r.url;
      return http.Response('{"ok":true}', 200);
    }, base: 'https://b.test/live/').stop(session: 'sid');
    expect(seen.path, '/live/api/stop');
  });

  test('parseUrl', () {
    expect(
      BridgeApi.parseUrl('core.example:9476').toString(),
      'https://core.example:9476',
    );
    expect(BridgeApi.parseUrl(''), isNull);
    expect(BridgeApi.parseUrl('ftp://x'), isNull);
  });

  test('protocol helpers match the web page', () {
    expect(isFiller('ok thanks'), isTrue);
    expect(isFiller(''), isTrue);
    expect(isFiller('check the disk'), isFalse);
    expect(
      plainForVoice('# Title\n**a** [link](http://x) `c`'),
      'Title\na link c',
    );
    expect(
      delegationText({
        'content': [
          {'text': 'a'},
          {'text': 'b'},
        ],
      }),
      'a b',
    );
    final m = contextAppend('id', 'x' * 4000);
    expect(m['delegation_item_id'], 'id');
    expect(((m['content'] as List).single as Map)['text'], hasLength(3500));
  });
}
