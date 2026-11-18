import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/chat/chat.dart';

import 'fake_http.dart';

void main() {
  late FakeHttp http;
  late ConversationsController convs;

  setUp(() {
    http = FakeHttp();
    convs = ConversationsController(api: fakeApi(http), pageSize: 2);
  });

  tearDown(() => convs.dispose());

  test('pages through the history', () async {
    http.on('GET /api/conversations', (r) {
      final second = r.query['cursor'] == 'p2';
      return jsonResponse({
        'conversations': second
            ? [conversationJson('c3', updated: 100)]
            : [
                conversationJson('c1', pinned: true, updated: 300),
                conversationJson('c2', updated: 200),
              ],
        'next_cursor': second ? null : 'p2',
      });
    });
    await convs.refresh();
    expect(convs.loaded, isTrue);
    expect(convs.hasMore, isTrue);
    expect(http.last('GET /api/conversations').query, {'limit': '2'});
    await convs.loadMore();
    expect(convs.conversations.map((c) => c.id), ['c1', 'c2', 'c3']);
    expect(convs.hasMore, isFalse);
    expect(convs.pinned.map((c) => c.id), ['c1']);
    expect(convs.recent.map((c) => c.id), ['c2', 'c3']);
    await convs.loadMore();
    expect(http.count('GET /api/conversations'), 2);

    convs.upsert(Conversation.fromJson(conversationJson('c3', updated: 400)));
    expect(convs.conversations.first.id, 'c3', reason: 'newest updated first');
  });

  test('pin is optimistic and rolls back on failure; rename; delete', () async {
    http.on(
      'GET /api/conversations',
      (_) => jsonResponse({
        'conversations': [conversationJson('c1'), conversationJson('c2')],
        'next_cursor': null,
      }),
    );
    await convs.refresh();

    final gate = Completer<void>();
    http.on('PATCH /api/conversations/c1', (r) async {
      await gate.future;
      return errorResponse(503, 'history_unavailable');
    });
    final pin = convs.togglePin('c1');
    await settle();
    expect(convs.byId('c1')!.pinned, isTrue);
    gate.complete();
    await expectLater(pin, throwsA(isA<ChatException>()));
    expect(convs.byId('c1')!.pinned, isFalse);

    http.on(
      'PATCH /api/conversations/c1',
      (r) => jsonResponse({
        'conversation': {
          ...conversationJson('c1'),
          'title': r.body['title'],
          'title_source': 'user',
        },
      }),
    );
    await convs.rename('c1', '  Trip plans ');
    expect(http.last('PATCH /api/conversations/c1').body, {
      'title': 'Trip plans',
    });
    expect(convs.byId('c1')!.title, 'Trip plans');

    convs.currentId = 'c2';
    http.on('DELETE /api/conversations/c2', (_) => errorResponse(500, 'oops'));
    await expectLater(convs.delete('c2'), throwsA(isA<ChatException>()));
    expect(convs.byId('c2'), isNotNull);
    expect(convs.currentId, 'c2');

    http.on('DELETE /api/conversations/c2', (_) => jsonResponse({'ok': true}));
    await convs.delete('c2');
    expect(convs.byId('c2'), isNull);
    expect(convs.currentId, isNull);
  });

  test('search ignores stale answers and clears', () async {
    final slow = Completer<void>();
    http.on('GET /api/conversations/search', (r) async {
      final q = r.query['q'];
      if (q == 'di') await slow.future;
      return jsonResponse({
        'results': [
          {
            'conversation': conversationJson('c-$q', title: q!),
            'message_id': null,
            'snippet': q,
          },
        ],
      });
    });
    final first = convs.search('di');
    await settle();
    expect(convs.searching, isTrue);
    await convs.search('disk ');
    expect(convs.query, 'disk');
    slow.complete();
    await first;
    expect(convs.results.single.conversation.id, 'c-disk');
    expect(convs.searching, isFalse);

    await convs.search('   ');
    expect(convs.results, isEmpty);
    expect(convs.isSearching, isFalse);
    await convs.search('x' * 300);
    expect(http.last('GET /api/conversations/search').query['q']!.length, 200);
    convs.clearSearch();
    expect(convs.results, isEmpty);
  });

  test('search errors are kept separately', () async {
    http.on(
      'GET /api/conversations/search',
      (_) => errorResponse(400, 'query_too_long'),
    );
    await convs.search('a');
    expect(convs.searchError!.kind, ChatErrorKind.invalid);
    expect(convs.error, isNull);
  });

  test('unavailable history makes the controller inert', () async {
    convs.setAvailable(false);
    await convs.refresh();
    await convs.search('x');
    expect(http.requests, isEmpty);
  });
}
