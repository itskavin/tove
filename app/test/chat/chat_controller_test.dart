import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/call/models.dart';
import 'package:tove_chat/src/chat/chat.dart';

import 'fake_http.dart';

void main() {
  late FakeHttp http;
  late ChatApi api;
  late ConversationsController convs;
  late ChatController chat;
  var ids = 0;

  Future<void> setUpChat({Map<String, dynamic>? caps}) async {
    http.on(
      'GET /api/capabilities',
      (_) => jsonResponse(caps ?? fullCapabilities),
    );
    http.on(
      'GET /api/conversations',
      (_) => jsonResponse({
        'conversations': [conversationJson('old')],
        'next_cursor': null,
      }),
    );
    await chat.init();
  }

  setUp(() {
    ids = 0;
    http = FakeHttp();
    api = fakeApi(http);
    convs = ConversationsController(api: api);
    chat = ChatController(
      api: api,
      conversations: convs,
      defaultEffort: () => ChatEffort.medium,
      newClientId: () => 'c-${++ids}',
      titleRefreshDelay: const Duration(milliseconds: 20),
    );
  });

  tearDown(() {
    chat.dispose();
    convs.dispose();
  });

  test('a cold start from a notification tap opens its chat even before '
      'init() has read the capabilities', () async {
    // Seen on the phone: tapping an instant notification with the app closed
    // opened an empty new chat; load() returned early (no history yet).
    final capsReply = Completer<void>();
    var capsReads = 0;
    http.on('GET /api/capabilities', (_) async {
      capsReads++;
      await capsReply.future;
      return jsonResponse(fullCapabilities);
    });
    http.on(
      'GET /api/conversations',
      (_) => jsonResponse({
        'conversations': [conversationJson('tove')],
        'next_cursor': null,
      }),
    );
    http.on(
      'GET /api/conversations/tove',
      (_) => jsonResponse({
        'conversation': conversationJson('tove'),
        'messages': [
          messageJson('n1', role: 'assistant', text: 'QA round 5 test'),
        ],
        'has_more': false,
      }),
    );
    final starting = chat.init(); // the app's start, still waiting
    final opening = chat.load('tove'); // the tap, at once
    capsReply.complete();
    await Future.wait([starting, opening]);
    expect(chat.currentConversationId, 'tove');
    expect(chat.messages.map((m) => m.text), ['QA round 5 test']);
    expect(capsReads, 1, reason: 'the in-flight read is shared');
  });

  test(
    'capabilities missing: live only, send refused, transcript kept locally',
    () async {
      await chat.init();
      expect(chat.capabilities.known, isTrue);
      expect(chat.textChatAvailable, isFalse);
      expect(chat.localOnly, isTrue);
      expect(convs.available, isFalse);
      expect(http.count('GET /api/conversations'), 0);

      await chat.send('hello');
      expect(chat.error?.kind, ChatErrorKind.unavailable);
      expect(chat.messages, isEmpty);
      expect(http.count('POST /api/chat'), 0);

      final transcript = [
        TranscriptEntry(1, Speaker.user)..text = 'what time is it',
        TranscriptEntry(2, Speaker.hermes)..text = 'Ten past three',
        TranscriptEntry(3, Speaker.user)..text = '  ',
      ];
      final r = await chat.importLiveTranscript(
        liveTurnsFromTranscript(transcript, key: 'sess'),
      );
      expect(r, isNull);
      expect(chat.messages.map((m) => (m.role, m.source, m.text)), [
        (MessageRole.user, MessageSource.voice, 'what time is it'),
        (MessageRole.assistant, MessageSource.voice, 'Ten past three'),
      ]);
      expect(chat.messages.first.clientId, 'turn:sess-1');
    },
  );

  test('send: optimistic message, streaming reply, new chat, done', () async {
    await setUpChat();
    expect(convs.conversations.map((c) => c.id), ['old']);
    final body = SseBody();
    http.on('POST /api/chat', (_) => body.response());

    final done = chat.send('  Hello there  ');
    expect(chat.messages.length, 2, reason: 'user message + reply placeholder');
    expect(chat.messages.first.text, 'Hello there');
    expect(chat.messages.first.status, MessageStatus.sending);
    expect(chat.messages.last.isStreaming, isTrue);
    await settle();
    expect(http.last('POST /api/chat').body, {
      'message': {'text': 'Hello there'},
      'effort': 'medium',
      'client_msg_id': 'c-1',
      'ui': 2,
    });
    expect(chat.streaming, isTrue);
    expect(chat.canSend, isFalse);
    expect(chat.streamingMessage!.text, '');

    body.meta(
      conv: 'new1',
      msg: 'a1',
      user: 'u1',
      created: true,
      title: 'Hello there',
    );
    await settle();
    expect(chat.currentConversationId, 'new1');
    expect(chat.title, 'Hello there');
    expect(convs.currentId, 'new1');
    expect(convs.conversations.first.id, 'new1');
    expect(chat.messages.first.id, 'u1');
    expect(chat.messages.first.status, MessageStatus.done);

    body.delta('Hi');
    body.event('status', {
      'label': 'Searching',
      'state': 'running',
      'tool': 'web',
      'id': 't1',
      'emoji': null,
    });
    body.delta(', friend');
    await settle();
    final s = chat.streamingMessage!;
    expect(s.id, 'a1');
    expect(s.text, 'Hi, friend');
    expect(s.isStreaming, isTrue);
    expect(s.statusLabel, 'Searching');

    http.on(
      'GET /api/conversations/new1',
      (_) => jsonResponse({
        'conversation': {
          ...conversationJson('new1', title: 'Friendly hello'),
          'title_source': 'hermes',
        },
        'messages': [],
        'has_more': false,
      }),
    );
    body.done(
      conv: 'new1',
      msg: 'a1',
      title: 'Hello there',
      titlePending: true,
    );
    await done;
    expect(chat.streaming, isFalse);
    expect(chat.canSend, isTrue);
    final reply = chat.messages.last;
    expect(reply.status, MessageStatus.done);
    expect(reply.text, 'Hi, friend');
    expect(reply.progress, isNull);
    expect(reply.meta['finish_reason'], 'stop');
    expect(chat.messages.length, 2);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(
      chat.title,
      'Friendly hello',
      reason: 'title re-read after title_pending',
    );
    expect(convs.byId('new1')!.title, 'Friendly hello');
  });

  test(
    'stop mid-stream marks the reply partial and closes the connection',
    () async {
      await setUpChat();
      final body = SseBody();
      http.on('POST /api/chat', (_) => body.response());
      final done = chat.send('Write a long story');
      await settle();
      body.meta(conv: 'new1', created: true);
      body.delta('Once upon');
      await settle();
      chat.stop();
      await done;
      expect(body.cancelled, isTrue);
      expect(http.last('POST /api/chat').aborted, isTrue);
      final reply = chat.messages.last;
      expect(reply.status, MessageStatus.stopped);
      expect(reply.isPartial, isTrue);
      expect(reply.text, 'Once upon');
      expect(chat.streaming, isFalse);
      // Late bytes are ignored.
      body.delta(' a time');
      await settle();
      expect(chat.messages.last.text, 'Once upon');
    },
  );

  test('retry after a stopped reply asks the server to answer again', () async {
    await setUpChat();
    var body = SseBody();
    http.on('POST /api/chat', (_) => body.response());
    final first = chat.send('Hi', effort: ChatEffort.high);
    await settle();
    body.meta(conv: 'new1', created: true);
    body.delta('Par');
    await settle();
    chat.stop();
    await first;

    body = SseBody();
    final again = chat.retry(chat.messages.last);
    await settle();
    expect(http.last('POST /api/chat').body, {
      'conversation_id': 'new1',
      'effort': 'high',
      'retry': true,
      'ui': 2,
    });
    expect(
      chat.messages.length,
      2,
      reason: 'stopped reply replaced by the streaming one',
    );
    body.meta(conv: 'new1', msg: 'a2');
    body.delta('Full answer');
    body.done(conv: 'new1', msg: 'a2');
    await again;
    expect(chat.messages.map((m) => m.text), ['Hi', 'Full answer']);
    expect(chat.messages.last.status, MessageStatus.done);
  });

  test(
    '429 usage limit before the stream: user message fails, retry resends',
    () async {
      await setUpChat();
      http.on(
        'POST /api/chat',
        (_) => errorResponse(429, 'usage_limit', extra: {'retry_after_s': 30}),
      );
      await chat.send('Hi');
      expect(chat.error?.kind, ChatErrorKind.usageLimit);
      expect(chat.error?.retryAfter, const Duration(seconds: 30));
      final user = chat.messages.single;
      expect(user.status, MessageStatus.failed);
      expect(user.errorKind, ChatErrorKind.usageLimit);
      expect(chat.canSend, isTrue);

      final body = SseBody();
      http.on('POST /api/chat', (_) => body.response());
      final again = chat.retry(user);
      await settle();
      expect(http.last('POST /api/chat').body['message'], {'text': 'Hi'});
      expect(http.last('POST /api/chat').body.containsKey('retry'), isFalse);
      expect(chat.messages.where((m) => m.isUser).length, 1);
      body.meta(conv: 'n', created: true);
      body.delta('ok');
      body.done(conv: 'n');
      await again;
      expect(chat.messages.map((m) => m.status), [
        MessageStatus.done,
        MessageStatus.done,
      ]);
      expect(chat.error, isNull);
    },
  );

  test(
    'login expired and Hermes errors inside the stream keep the partial text',
    () async {
      await setUpChat();
      final body = SseBody();
      http.on('POST /api/chat', (_) => body.response());
      final done = chat.send('Hi');
      await settle();
      body.meta(conv: 'n', created: true);
      body.delta('Half');
      body.event('error', {
        'conversation_id': 'n',
        'message_id': 'a1',
        'code': 'login_expired',
        'message': 'sign in',
      });
      await done;
      final reply = chat.messages.last;
      expect(reply.status, MessageStatus.failed);
      expect(reply.text, 'Half');
      expect(reply.errorKind, ChatErrorKind.loginExpired);
      expect(chat.error!.loginExpired, isTrue);
      expect(chat.messages.first.status, MessageStatus.done);
    },
  );

  test('401 is reported as unauthorized', () async {
    await setUpChat();
    http.on('POST /api/chat', (_) => errorResponse(401, 'unauthorized'));
    await chat.send('Hi');
    expect(chat.error!.kind, ChatErrorKind.unauthorized);
  });

  test('a dropped connection mid-stream fails the reply as network', () async {
    await setUpChat();
    final body = SseBody();
    http.on('POST /api/chat', (_) => body.response());
    final done = chat.send('Hi');
    await settle();
    body.meta(conv: 'n', created: true);
    body.delta('Some');
    await body.close();
    await done;
    expect(chat.messages.last.status, MessageStatus.failed);
    expect(chat.messages.last.errorKind, ChatErrorKind.network);
    expect(chat.messages.last.text, 'Some');
  });

  test('too-long messages are refused locally', () async {
    await setUpChat();
    await chat.send('x' * 8001);
    expect(chat.error!.code, 'too_long');
    expect(chat.messages, isEmpty);
  });

  test(
    'load, older messages, new chat and switching away while streaming',
    () async {
      await setUpChat();
      http.on(
        'GET /api/conversations/old',
        (_) => jsonResponse({
          'conversation': conversationJson('old', title: 'Old chat'),
          'messages': [
            messageJson('m2', conv: 'old'),
            messageJson('m3', conv: 'old', role: 'assistant', text: 'yo'),
          ],
          'has_more': true,
        }),
      );
      http.on(
        'GET /api/conversations/old/messages',
        (_) => jsonResponse({
          'messages': [messageJson('m1', conv: 'old', text: 'first')],
          'has_more': false,
        }),
      );
      await chat.load('old');
      expect(chat.title, 'Old chat');
      expect(convs.currentId, 'old');
      expect(chat.hasOlder, isTrue);
      await chat.loadOlder();
      expect(
        http.last('GET /api/conversations/old/messages').query['before'],
        'm2',
      );
      expect(chat.messages.map((m) => m.id), ['m1', 'm2', 'm3']);
      expect(chat.hasOlder, isFalse);

      final body = SseBody();
      http.on('POST /api/chat', (_) => body.response());
      final done = chat.send('More?');
      await settle();
      body.meta(conv: 'old', msg: 'a9', user: 'u9');
      body.delta('Sure');
      await settle();
      expect(http.last('POST /api/chat').body['conversation_id'], 'old');

      chat.newChat();
      expect(chat.messages, isEmpty);
      expect(chat.streaming, isFalse);
      expect(chat.streamingElsewhere, isTrue);
      expect(convs.currentId, isNull);

      // Back to the chat: the server copy (status streaming) is replaced by the live one.
      http.on(
        'GET /api/conversations/old',
        (_) => jsonResponse({
          'conversation': conversationJson('old', title: 'Old chat'),
          'messages': [
            messageJson('u9', conv: 'old', text: 'More?'),
            messageJson(
              'a9',
              conv: 'old',
              role: 'assistant',
              text: 'Su',
              status: 'streaming',
            ),
          ],
          'has_more': false,
        }),
      );
      await chat.load('old');
      body.delta(' thing');
      await settle();
      expect(chat.messages.length, 2);
      expect(chat.messages.last.text, 'Sure thing');
      expect(chat.streaming, isTrue);
      body.done(conv: 'old', msg: 'a9');
      await done;
      expect(chat.messages.last.status, MessageStatus.done);
      expect(chat.messages.length, 2);
    },
  );

  test('live: conversation id hook creates the chat, transcript is posted and reloaded', () async {
    await setUpChat();
    http.on(
      'POST /api/conversations',
      (_) => jsonResponse({
        'conversation': conversationJson('live1', title: 'New chat'),
      }, status: 201),
    );
    final id = await chat.conversationIdForLive();
    expect(id, 'live1');
    expect(chat.currentConversationId, 'live1');
    expect(await chat.conversationIdForLive(), 'live1');
    expect(http.count('POST /api/conversations'), 1);

    http.on(
      'POST /api/conversations/live1/live-transcript',
      (r) => jsonResponse({
        'added': 2,
        'skipped': 0,
        'conversation': conversationJson(
          'live1',
          kind: 'live',
          title: 'What time',
        ),
      }),
    );
    http.on(
      'GET /api/conversations/live1',
      (_) => jsonResponse({
        'conversation': conversationJson(
          'live1',
          kind: 'live',
          title: 'What time',
        ),
        'messages': [
          messageJson('v1', conv: 'live1', source: 'voice', text: 'what time'),
          messageJson(
            'v2',
            conv: 'live1',
            role: 'assistant',
            source: 'voice',
            text: 'three',
          ),
          messageJson(
            'k1',
            conv: 'live1',
            role: 'assistant',
            source: 'task',
            text: '**disk ok**',
            meta: {'task': 'check disk'},
          ),
        ],
        'has_more': false,
      }),
    );
    final r = await chat.importLiveTranscript(const [
      LiveTurn(id: 's-1', role: MessageRole.user, text: 'what time'),
      LiveTurn(id: 's-2', role: MessageRole.assistant, text: 'three'),
    ], session: 's');
    expect(r!.added, 2);
    expect(
      http
          .last('POST /api/conversations/live1/live-transcript')
          .body['session'],
      's',
    );
    expect(chat.conversation!.isLive, isTrue);
    expect(chat.messages.map((m) => m.source), [
      MessageSource.voice,
      MessageSource.voice,
      MessageSource.task,
    ]);
    expect(convs.byId('live1')!.title, 'What time');
  });

  test('live: a failed transcript post still shows the turns', () async {
    await setUpChat();
    http.on(
      'POST /api/conversations',
      (_) => jsonResponse({
        'conversation': conversationJson('live1'),
      }, status: 201),
    );
    await chat.conversationIdForLive();
    http.on(
      'POST /api/conversations/live1/live-transcript',
      (_) => errorResponse(503, 'history_unavailable'),
    );
    final tasks = [
      TaskEntry('item:1', 'check disk')
        ..status = TaskStatus.done
        ..detail = 'ok'
        ..seconds = 4,
    ];
    await chat.importLiveTranscript(const [
      LiveTurn(role: MessageRole.user, text: 'check the disk'),
    ], tasks: liveTasksFromEntries(tasks, key: 'k'));
    expect(chat.error!.kind, ChatErrorKind.unavailable);
    expect(chat.messages.map((m) => m.source), [
      MessageSource.voice,
      MessageSource.task,
    ]);
    expect(chat.messages.last.taskRequest, 'check disk');
    expect(liveTasksFromEntries(tasks, key: 'k').single.id, 'k-item_1');
    final rich = TaskEntry('item:2', 'df')
      ..status = TaskStatus.done
      ..detail = 'plain'
      ..markdown = '**rich**'
      ..job = 'job_A1';
    final converted = liveTasksFromEntries([rich], key: 'k').single;
    expect(converted.answer, '**rich**');
    expect(converted.id, 'job_A1');
    expect(converted.created, rich.created);
  });

  testWidgets('streaming notifications are throttled to ~30 per second', (
    tester,
  ) async {
    final http = FakeHttp();
    final api = fakeApi(http, idleTimeout: const Duration(minutes: 5));
    final chat = ChatController(api: api, newClientId: () => 'c-1');
    http.on('GET /api/capabilities', (_) => jsonResponse(fullCapabilities));
    await chat.refreshCapabilities();
    final body = SseBody();
    http.on('POST /api/chat', (_) => body.response());
    chat.send('Hi').ignore();
    await tester.pump();
    body.meta(conv: 'n', created: true);
    await tester.pump(const Duration(milliseconds: 100));

    var notifications = 0;
    chat.addListener(() => notifications++);
    // 1000 deltas over one second (one per millisecond).
    for (var i = 0; i < 1000; i++) {
      body.delta('x');
      await tester.pump(const Duration(milliseconds: 1));
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(chat.streamingMessage!.text.length, 1000);
    expect(notifications, inInclusiveRange(25, 33));

    // A burst within one frame yields a leading and one trailing notification.
    notifications = 0;
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 50; i++) {
      body.delta('y');
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(notifications, lessThanOrEqualTo(2));
    expect(chat.streamingMessage!.text.length, 1050);

    chat.stop();
    chat.dispose();
  });
}
