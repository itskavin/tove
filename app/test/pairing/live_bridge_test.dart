import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tove_chat/src/pairing/pair_link.dart';
import 'package:tove_chat/src/pairing/pairing.dart';

void main() {
  // End to end against a real bridge, when one is given (the tove-setup
  // verification runs a scratch bridge and makes a code for this):
  //   TOVE_PAIR_URL=http://127.0.0.1:8797 TOVE_PAIR_CODE=ABCDE-FGHJK \
  //     flutter test test/pairing/pair_link_test.dart
  final liveUrl = Platform.environment['TOVE_PAIR_URL'];
  final liveCode = Platform.environment['TOVE_PAIR_CODE'];
  test(
    'live bridge: the code gives a working key, once',
    () async {
      final server = PairLink.parseServer(liveUrl)!;
      final code = PairLink.normalizeCode(liveCode)!;
      // flutter_test answers every real request with 400 once a test binding
      // exists; this test talks to a real server.
      HttpOverrides.global = null;
      final client = http.Client();
      addTearDown(client.close);
      final r = await pairWithBridge(server, code, client: client);
      expect(r.key.length, greaterThanOrEqualTo(24));
      final caps = await client.get(
        server.replace(path: '${server.path}/api/capabilities'),
        headers: {'Authorization': 'Bearer ${r.key}'},
      );
      expect(caps.statusCode, 200);
      expect(jsonDecode(caps.body)['pairing'], isTrue);
      try {
        await pairWithBridge(server, code, client: client);
        fail('a code works once');
      } on PairingException catch (e) {
        expect(e.problem, PairingProblem.expired);
      }
    },
    skip: liveUrl == null || liveCode == null
        ? 'set TOVE_PAIR_URL and TOVE_PAIR_CODE to run against a bridge'
        : false,
  );
}
