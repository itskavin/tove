import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/chat/chat.dart';

import 'fake_http.dart';

void main() {
  late FakeHttp http;
  late ChatApi api;

  setUp(() {
    http = FakeHttp();
    api = fakeApi(http);
  });

  group('capabilities', () {
    test('parses and caches the v2 answer', () async {
      http.on('GET /api/capabilities', (_) => jsonResponse(fullCapabilities));
      final c = await api.capabilities();
      expect(c.known, isTrue);
      expect(c.chat && c.history && c.search && c.effort, isTrue);
      expect(c.efforts, ChatEffort.values);
      expect(c.liveLink && c.liveTranscript, isTrue);
      expect(c.attachments || c.language, isFalse);
      expect(c.limits.messageChars, 8000);
      expect(c.limits.keepalive, const Duration(seconds: 15));
      expect(c.defaultVoice, 'cove');
      await api.capabilities();
      expect(http.count('GET /api/capabilities'), 1);
      expect(
        http.last('GET /api/capabilities').headers['Authorization'],
        'Bearer $chatTestKey',
      );
      expect(
        http.last('GET /api/capabilities').url.toString(),
        'https://bridge.test:9476/api/capabilities',
      );
      await api.capabilities(refresh: true);
      expect(http.count('GET /api/capabilities'), 2);
    });

    test('a missing route (old bridge) means live only, known', () async {
      final c = await api.capabilities();
      expect(c.known, isTrue);
      expect(c.liveOnly, isTrue);
      expect(c.chat, isFalse);
      await api.capabilities();
      expect(http.count('GET /api/capabilities'), 1, reason: 'cached');
    });

    test('a network failure means live only, unknown, not cached', () async {
      http.failWith = const SocketException('down');
      final c = await api.capabilities();
      expect(c.known, isFalse);
      expect(c.liveOnly, isTrue);
      http.failWith = null;
      http.on('GET /api/capabilities', (_) => jsonResponse(fullCapabilities));
      expect((await api.capabilities()).chat, isTrue);
    });

    test('401 throws unauthorized', () async {
      http.on(
        'GET /api/capabilities',
        (_) => errorResponse(401, 'unauthorized'),
      );
      await expectLater(
        api.capabilities(),
        throwsA(
          isA<ChatException>()
              .having((e) => e.kind, 'kind', ChatErrorKind.unauthorized)
              .having((e) => e.unauthorized, 'unauthorized', isTrue),
        ),
      );
    });
  });

  group('history', () {
    test('list, create, get, older, rename, pin, delete, search', () async {
      http.on(
        'GET /api/conversations',
        (r) => jsonResponse({
          'conversations': [
            conversationJson('c1', pinned: true),
            conversationJson('c2'),
          ],
          'next_cursor': 'cur2',
        }),
      );
      final page = await api.listConversations(
        limit: 2,
        cursor: 'cur1',
        pinned: true,
      );
      expect(page.conversations.map((c) => c.id), ['c1', 'c2']);
      expect(page.conversations.first.pinned, isTrue);
      expect(
        page.conversations.first.updated.millisecondsSinceEpoch,
        1794691024435,
      );
      expect(page.nextCursor, 'cur2');
      expect(http.last('GET /api/conversations').query, {
        'limit': '2',
        'cursor': 'cur1',
        'pinned': 'true',
      });

      http.on(
        'POST /api/conversations',
        (r) => jsonResponse({
          'conversation': conversationJson('c3', title: 'New chat'),
        }, status: 201),
      );
      expect((await api.createConversation()).id, 'c3');
      expect(http.last('POST /api/conversations').body, isEmpty);
      await api.createConversation(title: 'Plans');
      expect(http.last('POST /api/conversations').body, {'title': 'Plans'});

      http.on(
        'GET /api/conversations/c1',
        (r) => jsonResponse({
          'conversation': conversationJson('c1', kind: 'live'),
          'messages': [
            messageJson('m1', conv: 'c1'),
            messageJson(
              'm2',
              conv: 'c1',
              role: 'assistant',
              status: 'cancelled',
              text: 'part',
            ),
            messageJson(
              'm3',
              conv: 'c1',
              role: 'assistant',
              source: 'task',
              status: 'error',
              meta: {
                'task': 'check disks',
                'seconds': 12,
                'error_code': 'hermes_error',
              },
            ),
          ],
          'has_more': true,
        }),
      );
      final d = await api.getConversation('c1', limit: 3);
      expect(d.conversation.isLive, isTrue);
      expect(d.hasMore, isTrue);
      expect(d.messages[1].status, MessageStatus.stopped);
      expect(d.messages[1].isPartial, isTrue);
      expect(d.messages[2].isTask, isTrue);
      expect(d.messages[2].taskRequest, 'check disks');
      expect(d.messages[2].taskSeconds, 12);
      expect(d.messages[2].errorKind, ChatErrorKind.hermes);
      expect(http.last('GET /api/conversations/c1').query, {'limit': '3'});

      http.on(
        'GET /api/conversations/c1/messages',
        (r) => jsonResponse({
          'messages': [messageJson('m0', conv: 'c1')],
          'has_more': false,
        }),
      );
      final older = await api.messages('c1', before: 'm1', limit: 10);
      expect(older.messages.single.id, 'm0');
      expect(older.hasMore, isFalse);
      expect(http.last('GET /api/conversations/c1/messages').query, {
        'before': 'm1',
        'limit': '10',
      });

      http.on('PATCH /api/conversations/c1', (r) {
        final b = r.body;
        return jsonResponse({
          'conversation': {
            ...conversationJson('c1'),
            if (b.containsKey('title')) ...{
              'title': b['title'],
              'title_source': 'user',
            },
            if (b.containsKey('pinned')) 'pinned': b['pinned'],
          },
        });
      });
      final renamed = await api.renameConversation('c1', 'Disk check');
      expect(renamed.title, 'Disk check');
      expect(renamed.titleSource, TitleSource.user);
      expect(http.last('PATCH /api/conversations/c1').body, {
        'title': 'Disk check',
      });
      expect((await api.setPinned('c1', true)).pinned, isTrue);
      expect(http.last('PATCH /api/conversations/c1').body, {'pinned': true});

      http.on(
        'DELETE /api/conversations/c1',
        (_) => jsonResponse({'ok': true}),
      );
      await api.deleteConversation('c1');
      expect(http.count('DELETE /api/conversations/c1'), 1);
      http.on(
        'DELETE /api/conversations/c1/messages/m2',
        (_) => jsonResponse({'ok': true}),
      );
      await api.deleteMessage('c1', 'm2');

      http.on(
        'GET /api/conversations/search',
        (r) => jsonResponse({
          'results': [
            {
              'conversation': conversationJson('c2', title: 'Disks'),
              'message_id': null,
              'snippet': 'Disks',
            },
            {
              'conversation': conversationJson('c4'),
              'message_id': 'm9',
              'snippet': 'the disk is full',
            },
          ],
        }),
      );
      final results = await api.search('disk', limit: 5);
      expect(results.first.titleMatch, isTrue);
      expect(results.last.messageId, 'm9');
      expect(results.last.snippet, 'the disk is full');
      expect(http.last('GET /api/conversations/search').query, {
        'q': 'disk',
        'limit': '5',
      });
    });

    test('unknown chat maps to notFound', () async {
      http.on(
        'GET /api/conversations/zz',
        (_) => errorResponse(404, 'not_found'),
      );
      await expectLater(
        api.getConversation('zz'),
        throwsA(
          isA<ChatException>().having(
            (e) => e.kind,
            'kind',
            ChatErrorKind.notFound,
          ),
        ),
      );
    });

    test('live transcript posts an object and batches by the limits', () async {
      http.on(
        'GET /api/capabilities',
        (_) => jsonResponse({
          ...fullCapabilities,
          'limits': {
            ...(fullCapabilities['limits'] as Map),
            'transcript_turns': 2,
          },
        }),
      );
      await api.capabilities();
      http.on('POST /api/conversations/c1/live-transcript', (r) {
        final n =
            (r.body['turns'] as List).length +
            ((r.body['tasks'] as List?)?.length ?? 0);
        return jsonResponse({
          'added': n,
          'skipped': 0,
          'conversation': conversationJson('c1', kind: 'live'),
        });
      });
      final turns = [
        for (var i = 0; i < 5; i++)
          LiveTurn(
            id: 't$i',
            role: i.isEven ? MessageRole.user : MessageRole.assistant,
            text: 'turn $i',
          ),
      ];
      final r = await api.saveLiveTranscript(
        'c1',
        session: 's1',
        turns: turns,
        tasks: const [
          LiveTask(
            id: 'j1',
            request: 'df',
            answer: '**ok**',
            done: true,
            seconds: 3,
          ),
        ],
      );
      expect(http.count('POST /api/conversations/c1/live-transcript'), 3);
      expect(r.added, 6);
      expect(r.conversation!.isLive, isTrue);
      final first = http.requests
          .firstWhere((q) => q.path.endsWith('live-transcript'))
          .body;
      expect(first['session'], 's1');
      expect(first['turns'], [
        {'id': 't0', 'role': 'user', 'text': 'turn 0'},
        {'id': 't1', 'role': 'assistant', 'text': 'turn 1'},
      ]);
      expect(first['tasks'], [
        {
          'id': 'j1',
          'request': 'df',
          'answer': '**ok**',
          'status': 'done',
          'seconds': 3,
        },
      ]);
    });
  });

  group('streaming', () {
    test('send body, split chunks, status and the done marker', () async {
      final body = SseBody();
      http.on('POST /api/chat', (_) => body.response());
      final s = api.send(
        conversationId: 'conv1',
        text: 'Hello',
        effort: ChatEffort.high,
        clientMsgId: 'c-1',
      );
      final events = <ChatEvent>[];
      final finished = Completer<void>();
      s.events.listen(events.add, onDone: finished.complete);
      await settle();
      final req = http.last('POST /api/chat');
      expect(req.body, {
        'conversation_id': 'conv1',
        'message': {'text': 'Hello'},
        'effort': 'high',
        'client_msg_id': 'c-1',
        'ui': 2,
      });
      expect(req.headers['Accept'], 'text/event-stream');
      body.meta(client: 'c-1');
      // A delta split mid-line and mid-character.
      final bytes = utf8.encode('event: delta\ndata: {"text":"Hé"}\n\n');
      body.bytes(bytes.sublist(0, 10));
      await settle();
      body.bytes(bytes.sublist(10, 27));
      body.bytes(bytes.sublist(27));
      body.raw(': keep-alive\n\n');
      body.event('status', {
        'label': 'df -h',
        'state': 'running',
        'tool': 'terminal',
        'id': 't1',
        'emoji': '💻',
      });
      body.delta('llo');
      body.done(titlePending: true);
      await finished.future;
      expect(events.map((e) => e.runtimeType), [
        ChatMetaEvent,
        ChatDeltaEvent,
        ChatProgressEvent,
        ChatDeltaEvent,
        ChatDoneEvent,
      ]);
      expect(
        events.whereType<ChatDeltaEvent>().map((e) => e.text).join(),
        'Héllo',
      );
      final done = events.last as ChatDoneEvent;
      expect(done.titlePending, isTrue);
      expect(done.usage!.totalTokens, 3);
      expect(s.closed, isTrue);
      expect(
        body.cancelled,
        isTrue,
        reason: 'body subscription released after done',
      );
    });

    test('retry sends retry:true without a message', () async {
      final body = SseBody();
      http.on('POST /api/chat', (_) => body.response());
      api.retry(conversationId: 'conv1').events.listen((_) {});
      await settle();
      expect(http.last('POST /api/chat').body, {
        'conversation_id': 'conv1',
        'retry': true,
        'ui': 2,
      });
    });

    test('cancel aborts the request and closes the connection', () async {
      final body = SseBody();
      http.on('POST /api/chat', (_) => body.response());
      final s = api.send(text: 'Hi');
      final events = <ChatEvent>[];
      final errors = <Object>[];
      final finished = Completer<void>();
      s.events.listen(
        events.add,
        onError: errors.add,
        onDone: finished.complete,
      );
      await settle();
      body.meta();
      body.delta('Par');
      await settle();
      s.cancel();
      await finished.future;
      body.delta('tial');
      await settle();
      expect(s.cancelled, isTrue);
      expect(http.last('POST /api/chat').aborted, isTrue);
      expect(body.cancelled, isTrue);
      expect(events.whereType<ChatDeltaEvent>().length, 1);
      expect(errors, isEmpty);
    });

    test('a stream error event ends the stream', () async {
      final body = SseBody();
      http.on('POST /api/chat', (_) => body.response());
      final s = api.send(text: 'Hi');
      final events = <ChatEvent>[];
      final finished = Completer<void>();
      s.events.listen(events.add, onDone: finished.complete);
      await settle();
      body.meta();
      body.event('error', {
        'conversation_id': 'conv1',
        'message_id': 'a1',
        'code': 'timeout',
        'message': 'took too long',
      });
      await finished.future;
      final f = events.last as ChatFailedEvent;
      expect(f.error.kind, ChatErrorKind.hermes);
      expect(f.error.code, 'timeout');
      expect(f.error.message, 'took too long');
    });

    test('a stream that ends without done is reported as cut off', () async {
      final body = SseBody();
      http.on('POST /api/chat', (_) => body.response());
      final s = api.send(text: 'Hi');
      final errors = <Object>[];
      final finished = Completer<void>();
      s.events.listen((_) {}, onError: errors.add, onDone: finished.complete);
      await settle();
      body.meta();
      body.delta('x');
      await body.close();
      await finished.future;
      expect(
        errors.single,
        isA<ChatException>().having(
          (e) => e.kind,
          'kind',
          ChatErrorKind.network,
        ),
      );
    });

    test('a silent stream times out', () async {
      api = fakeApi(http, idleTimeout: const Duration(milliseconds: 50));
      final body = SseBody();
      http.on('POST /api/chat', (_) => body.response());
      final errors = <Object>[];
      final finished = Completer<void>();
      final s = api.send(text: 'Hi');
      s.events.listen((_) {}, onError: errors.add, onDone: finished.complete);
      await finished.future;
      expect(
        errors.single,
        isA<ChatException>().having((e) => e.code, 'code', 'client_timeout'),
      );
      expect(http.last('POST /api/chat').aborted, isTrue);
    });
  });

  group('error mapping', () {
    Future<ChatException> sendError(FakeHandler h) async {
      http.on('POST /api/chat', h);
      final c = Completer<ChatException>();
      api
          .send(text: 'Hi')
          .events
          .listen(
            (_) {},
            onError: (Object e) => c.complete(e as ChatException),
          );
      return c.future;
    }

    test('429 usage_limit with retry_after_s', () async {
      final e = await sendError(
        (_) => errorResponse(
          429,
          'usage_limit',
          message: 'GPT-Live usage limit reached',
          extra: {'retry_after_s': 7200},
        ),
      );
      expect(e.kind, ChatErrorKind.usageLimit);
      expect(e.usageLimit, isTrue);
      expect(e.busy, isFalse);
      expect(e.retryAfter, const Duration(hours: 2));
      expect(e.status, 429);
    });

    test('429 usage_limit falls back to the Retry-After header', () async {
      final e = await sendError(
        (_) => errorResponse(
          429,
          'usage_limit',
          extra: {'retry_after_s': null},
          headers: {'retry-after': '60'},
        ),
      );
      expect(e.kind, ChatErrorKind.usageLimit);
      expect(e.retryAfter, const Duration(seconds: 60));
    });

    test('502 login_expired is distinct from 401', () async {
      final e = await sendError(
        (_) => errorResponse(
          502,
          'login_expired',
          message: 'sign in again on the server',
        ),
      );
      expect(e.kind, ChatErrorKind.loginExpired);
      expect(e.loginExpired, isTrue);
      expect(e.unauthorized, isFalse);
      final u = await sendError((_) => errorResponse(401, 'unauthorized'));
      expect(u.kind, ChatErrorKind.unauthorized);
    });

    test('busy, invalid, unavailable, server and network', () async {
      expect(
        (await sendError((_) => errorResponse(429, 'busy'))).kind,
        ChatErrorKind.busy,
      );
      expect(
        (await sendError(
          (_) => errorResponse(400, 'too_long', message: 'too long'),
        )).kind,
        ChatErrorKind.invalid,
      );
      expect(
        (await sendError((_) => errorResponse(409, 'duplicate'))).kind,
        ChatErrorKind.invalid,
      );
      expect(
        (await sendError((_) => errorResponse(503, 'hermes_unconfigured')))
            .kind,
        ChatErrorKind.unavailable,
      );
      expect(
        (await sendError((_) => jsonResponse('oops', status: 500))).kind,
        ChatErrorKind.server,
      );
      http.failWith = const SocketException('down');
      final n = await sendError((_) => jsonResponse({}));
      expect(n.kind, ChatErrorKind.network);
      expect(n.unreachable, isTrue);
    });

    test('non-SSE success is a server error', () async {
      final e = await sendError((_) => jsonResponse({'reply': 'x'}));
      expect(e.kind, ChatErrorKind.server);
    });

    test('REST errors use the same mapping', () async {
      http.on(
        'GET /api/conversations',
        (_) => errorResponse(401, 'unauthorized'),
      );
      await expectLater(
        api.listConversations(),
        throwsA(
          isA<ChatException>().having(
            (e) => e.kind,
            'kind',
            ChatErrorKind.unauthorized,
          ),
        ),
      );
      expect(
        ChatException.fromHttp(
          400,
          jsonEncode({
            'error': 'bad_title',
            'code': 'bad_title',
            'message': 'title is empty',
          }),
        ).message,
        'title is empty',
      );
    });
  });
}
