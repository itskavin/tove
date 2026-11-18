import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tove_chat/src/sync/chat_archive.dart';
import 'package:tove_chat/src/sync/settings_api.dart';

import '../chat/fake_http.dart';

http.StreamedResponse json(Object body, [int status = 200]) =>
    http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), status);

void main() {
  late FakeHttp net;
  setUp(() => net = FakeHttp());

  group('HttpSettingsApi', () {
    HttpSettingsApi api() => HttpSettingsApi(
      baseUrl: chatTestBase,
      accessKey: chatTestKey,
      client: net,
    );

    test('capabilities: settings_sync and its limits; 404 is none', () async {
      net.on(
        'GET /api/capabilities',
        (_) => json({
          'settings_sync': true,
          'settings_limits': {'bytes': 4096, 'text_chars': 900},
        }),
      );
      final s = await api().support();
      expect(s.supported, isTrue);
      expect(s.maxBytes, 4096);
      expect(s.textChars, 900);
      expect(
        net.last('GET /api/capabilities').headers['Authorization'],
        'Bearer $chatTestKey',
      );

      net.routes.clear();
      expect((await api().support()).supported, isFalse, reason: '404');
      net.on('GET /api/capabilities', (_) => json({'settings_sync': false}));
      expect((await api().support()).supported, isFalse);
    });

    test('GET sends If-None-Match and reads 304 as unchanged', () async {
      net.on('GET /api/settings', (r) {
        if (r.headers['If-None-Match'] == '"s3"') {
          return http.StreamedResponse(const Stream.empty(), 304);
        }
        return json({
          'version': 3,
          'settings': {'theme': 'light'},
          'updated': 5,
        });
      });
      final got = await api().fetch();
      expect(got!.version, 3);
      expect(got.settings['theme'], 'light');
      expect(await api().fetch(etag: '"s3"'), isNull);
    });

    test('PUT carries the version; 409 hands back the current state', () async {
      net.on('PUT /api/settings', (r) {
        if (r.body['version'] != 3) {
          return json({
            'error': 'version_conflict',
            'code': 'version_conflict',
            'current': {
              'version': 3,
              'settings': {'theme': 'dark'},
              'updated': 9,
            },
          }, 409);
        }
        return json({
          'version': 4,
          'settings': r.body['settings'],
          'updated': 10,
        });
      });
      final saved = await api().put(3, {'theme': 'light'});
      expect(saved.version, 4);
      expect(net.last('PUT /api/settings').body, {
        'version': 3,
        'settings': {'theme': 'light'},
      });
      await expectLater(
        api().put(2, {'theme': 'light'}),
        throwsA(
          isA<SettingsApiException>()
              .having((e) => e.kind, 'kind', SettingsErrorKind.conflict)
              .having((e) => e.current?.version, 'current', 3),
        ),
      );
    });

    test('400 names the key; 413, 401 and network failures map', () async {
      net.on(
        'PUT /api/settings',
        (_) =>
            json({'code': 'bad_setting', 'key': 'personalization.style'}, 400),
      );
      await expectLater(
        api().put(0, {}),
        throwsA(
          isA<SettingsApiException>()
              .having((e) => e.kind, 'kind', SettingsErrorKind.rejected)
              .having((e) => e.key, 'key', 'personalization.style'),
        ),
      );
      net.on(
        'PUT /api/settings',
        (_) => json({'code': 'settings_too_large'}, 413),
      );
      await expectLater(
        api().put(0, {}),
        throwsA(
          isA<SettingsApiException>().having(
            (e) => e.kind,
            'kind',
            SettingsErrorKind.tooLarge,
          ),
        ),
      );
      net.on('GET /api/settings', (_) => json({'code': 'unauthorized'}, 401));
      await expectLater(
        api().fetch(),
        throwsA(
          isA<SettingsApiException>().having(
            (e) => e.kind,
            'kind',
            SettingsErrorKind.unauthorized,
          ),
        ),
      );
      net.failWith = Exception('down');
      await expectLater(
        api().fetch(),
        throwsA(
          isA<SettingsApiException>().having(
            (e) => e.kind,
            'kind',
            SettingsErrorKind.offline,
          ),
        ),
      );
    });
  });

  group('ChatArchive', () {
    ChatArchive archive() => ChatArchive(
      baseUrl: chatTestBase,
      accessKey: chatTestKey,
      client: net,
      pageSize: 2,
      messagesPage: 2,
    );

    void serve() {
      net.on('GET /api/conversations', (r) {
        final page = r.query['cursor'] == null
            ? [
                {'id': 'c1', 'title': 'One'},
                {'id': 'c2', 'title': 'Two'},
              ]
            : [
                {'id': 'c3', 'title': 'Three'},
              ];
        return json({
          'conversations': page,
          'next_cursor': r.query['cursor'] == null ? 'p2' : null,
        });
      });
      for (final id in ['c1', 'c2', 'c3']) {
        net.on(
          'GET /api/conversations/$id',
          (_) => json({
            'conversation': {'id': id, 'title': id},
            'messages': [
              {'id': '$id-m3', 'text': 'three'},
              {'id': '$id-m4', 'text': 'four'},
            ],
            'has_more': id == 'c1',
          }),
        );
      }
      net.on(
        'GET /api/conversations/c1/messages',
        (r) => json({
          'messages': [
            {'id': 'c1-m1', 'text': 'one'},
            {'id': 'c1-m2', 'text': 'two'},
          ],
          'has_more': false,
        }),
      );
    }

    test('exports every page and every message, oldest first', () async {
      serve();
      final progress = <(int, int)>[];
      final out = await archive().export(
        onProgress: (d, t) => progress.add((d, t)),
        now: DateTime(2026, 11, 16),
      );
      expect(out['format'], 'tove-chats');
      final chats = out['conversations'] as List;
      expect(chats.map((c) => c['id']), ['c1', 'c2', 'c3']);
      expect(((chats.first as Map)['messages'] as List).map((m) => m['id']), [
        'c1-m1',
        'c1-m2',
        'c1-m3',
        'c1-m4',
      ]);
      expect(
        net.last('GET /api/conversations/c1/messages').query['before'],
        'c1-m3',
      );
      expect(progress.last, (3, 3));
      final text = utf8.decode(ChatArchive.encode(out));
      expect(text, isNot(contains(chatTestKey)), reason: 'never the key');
      expect(
        ChatArchive.fileName(DateTime(2026, 1, 5)),
        'tove-chats-2026-01-05.json',
      );
    });

    test('deleteAll goes through the given delete for every chat', () async {
      serve();
      final deleted = <String>[];
      final n = await archive().deleteAll((id) async => deleted.add(id));
      expect(n, 3);
      expect(deleted, ['c1', 'c2', 'c3']);
    });

    test('a failure is reported', () async {
      net.failWith = Exception('down');
      await expectLater(
        archive().export(),
        throwsA(isA<ChatArchiveException>()),
      );
    });
  });
}
