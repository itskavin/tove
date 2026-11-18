import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/background/background_replies.dart';
import 'package:tove_chat/src/background/reply_store.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/ui/thread/reply_details.dart';

import 'fake_http.dart';

/// The reported bug: "when I press the home button or go to a new chat, the
/// previous chat's task shows an error". Root cause: the reply's stream was
/// owned by the controller and any silence or drop (the process frozen in
/// the background, the socket torn down) turned it into a failed message
/// plus a global error toast, shown in whichever chat was open.
void main() {
  late FakeHttp http;
  late ChatApi api;
  late ConversationsController convs;
  late BackgroundReplies replies;
  late MemoryReplyStore store;
  late ChatController chat;
  var ids = 0;

  String? header(FakeRequest r, String name) {
    for (final e in r.headers.entries) {
      if (e.key.toLowerCase() == name.toLowerCase()) return e.value;
    }
    return null;
  }

  ChatController makeChat() => ChatController(
    api: api,
    conversations: convs,
    replies: replies,
    newClientId: () => 'c-${++ids}',
    titleRefreshDelay: const Duration(milliseconds: 20),
  );

  Future<void> setUpChat({Map<String, dynamic> caps = resumableCapabilities}) async {
    http.on('GET /api/capabilities', (_) => jsonResponse(caps));
    http.on(
      'GET /api/conversations',
      (_) => jsonResponse({
        'conversations': [conversationJson('old'), conversationJson('other')],
        'next_cursor': null,
      }),
    );
    http.on(
      'GET /api/conversations/other',
      (_) => jsonResponse({
        'conversation': conversationJson('other', title: 'Other chat'),
        'messages': [messageJson('o1', conv: 'other')],
        'has_more': false,
      }),
    );
    await chat.init();
  }

  void conversationWith(String id, List<Map<String, dynamic>> messages) =>
      http.on(
        'GET /api/conversations/$id',
        (_) => jsonResponse({
          'conversation': conversationJson(id, title: 'Chat $id'),
          'messages': messages,
          'has_more': false,
        }),
      );

  setUp(() {
    ids = 0;
    http = FakeHttp();
    api = fakeApi(http);
    convs = ConversationsController(api: api);
    store = MemoryReplyStore();
    replies = BackgroundReplies(
      store: store,
      backoff: (_) => const Duration(milliseconds: 5),
      persistDelay: const Duration(milliseconds: 5),
    );
    chat = makeChat();
  });

  tearDown(() {
    chat.dispose();
    convs.dispose();
    replies.dispose();
  });

  /// Sends "More?" in chat `old` and lets meta and two deltas (ids 1–3) in.
  Future<(SseBody, Future<void>)> startInOld() async {
    conversationWith('old', [messageJson('m1', conv: 'old')]);
    await chat.load('old');
    final body = SseBody();
    http.on('POST /api/chat', (_) => body.response());
    final done = chat.send('More?');
    await settle();
    body.idEvent(1, 'meta', {
      'conversation_id': 'old',
      'message_id': 'a9',
      'user_message_id': 'u9',
      'title': 'Chat old',
      'resumable': true,
    });
    body.idEvent(2, 'delta', {'text': 'Sure'});
    body.idEvent(3, 'delta', {'text': ' thing'});
    await settle();
    return (body, done);
  }

  test('switching to a new chat and another chat mid-stream keeps streaming',
      () async {
    await setUpChat();
    final (body, done) = await startInOld();

    chat.newChat();
    expect(chat.streaming, isFalse);
    expect(chat.streamingElsewhere, isTrue);
    expect(chat.streamingConversations, {'old'});
    await chat.load('other');
    body.idEvent(4, 'delta', {'text': ', here'});
    await settle();
    expect(body.cancelled, isFalse, reason: 'navigation never closes the stream');
    expect(http.last('POST /api/chat').aborted, isFalse);
    expect(chat.error, isNull);

    conversationWith('old', [
      messageJson('u9', conv: 'old', text: 'More?'),
      messageJson('a9', conv: 'old', role: 'assistant', text: 'Su', status: 'streaming'),
    ]);
    await chat.load('old');
    expect(chat.streaming, isTrue);
    expect(chat.messages.last.text, 'Sure thing, here');
    expect(http.count('GET /api/chat/a9/stream'), 0,
        reason: 'the live task is reused, not resumed again');
    body.idEvent(5, 'done', {
      'conversation_id': 'old',
      'message_id': 'a9',
      'finish_reason': 'stop',
      'title': 'Chat old',
    });
    await done;
    expect(chat.messages.last.status, MessageStatus.done);
    expect(chat.messages.last.text, 'Sure thing, here');
  });

  test('a just-finished reply keeps the whole done.usage for Details',
      () async {
    await setUpChat();
    final (body, done) = await startInOld();
    const usage = {
      'model': 'gpt-5.5',
      'input_tokens': 28160,
      'output_tokens': 412,
      'total_tokens': 28572,
      'cached_tokens': 27904,
      'reasoning_tokens': 96,
      'model_calls': 2,
      'duration_ms': 9120,
      'ttft_ms': 7310,
      'tool_count': 1,
      'effort': 'medium',
      'prompt_tokens': 28160,
      'completion_tokens': 412,
    };
    body.idEvent(4, 'done', {
      'conversation_id': 'old',
      'message_id': 'a9',
      'finish_reason': 'stop',
      'usage': usage,
    });
    await done;
    final m = chat.messages.last;
    expect(m.status, MessageStatus.done);
    expect(m.meta['usage'], usage,
        reason: 'the Details sheet reads the same fields as after a reload');
    final details = ReplyDetails.of(m);
    expect(details.model, 'gpt-5.5');
    expect(details.cachedTokens, 27904);
    expect(details.firstToken, const Duration(milliseconds: 7310));
  });

  test('an older bridge\'s three-count usage still fills meta.usage', () async {
    await setUpChat();
    final (body, done) = await startInOld();
    body.idEvent(4, 'done', {
      'conversation_id': 'old',
      'message_id': 'a9',
      'usage': {'prompt_tokens': 1, 'completion_tokens': 2, 'total_tokens': 3},
    });
    await done;
    expect(chat.messages.last.meta['usage'],
        {'prompt_tokens': 1, 'completion_tokens': 2, 'total_tokens': 3});
  });

  test('a reply that fails in a chat not on screen raises no error toast',
      () async {
    await setUpChat(caps: fullCapabilities); // Old bridge: a drop is final.
    final (body, done) = await startInOld();
    await chat.load('other');
    body.idEvent(4, 'error', {
      'conversation_id': 'old',
      'message_id': 'a9',
      'code': 'hermes_error',
      'message': 'boom',
    });
    await done;
    expect(chat.error, isNull);
    expect(chat.messages.single.id, 'o1');
  });

  test('pause with push: the reader closes, resume reconnects with Last-Event-ID',
      () async {
    await setUpChat();
    replies.pushActive = true;
    final (body, done) = await startInOld();
    expect(replies.needsKeepAlive, isFalse);

    replies.setForeground(false);
    await settle();
    expect(body.cancelled, isTrue, reason: 'closed so the bridge pushes');
    expect(chat.messages.last.status, MessageStatus.streaming);
    expect(chat.reconnecting, isTrue);
    expect(chat.error, isNull);
    expect(http.count('GET /api/chat/a9/stream'), 0);
    // The pair (id 3, "Sure thing") is persisted for a cold start.
    await replies.flush();
    expect(store.items.single.lastEventId, 3);
    expect(store.items.single.text, 'Sure thing');

    final again = SseBody();
    http.on('GET /api/chat/a9/stream', (_) => again.response());
    replies.setForeground(true);
    await settle();
    expect(header(http.last('GET /api/chat/a9/stream'), 'Last-Event-ID'), '3');
    again.idEvent(3, 'delta', {'text': ' thing'}); // Duplicate: ignored.
    again.idEvent(4, 'delta', {'text': '!'});
    again.idEvent(5, 'done', {
      'conversation_id': 'old',
      'message_id': 'a9',
      'title': 'Chat old',
    });
    await done;
    expect(chat.messages.last.text, 'Sure thing!');
    expect(chat.messages.last.status, MessageStatus.done);
    expect(replies.byMessage('a9')!.reconnects, 1);
    await replies.flush();
    expect(store.items, isEmpty);
  });

  test('pause without push keeps the stream; a drop reconnects, never fails',
      () async {
    await setUpChat();
    final (body, done) = await startInOld();
    expect(replies.needsKeepAlive, isTrue);
    replies.setForeground(false);
    expect(body.cancelled, isFalse, reason: 'the foreground service keeps it');

    final again = SseBody();
    http.on('GET /api/chat/a9/stream', (_) => again.response());
    await body.close(); // The OS tore the socket down.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(chat.messages.last.status, MessageStatus.streaming);
    expect(header(http.last('GET /api/chat/a9/stream'), 'Last-Event-ID'), '3');
    again.idEvent(4, 'done', {'conversation_id': 'old', 'message_id': 'a9'});
    await done;
    expect(chat.messages.last.status, MessageStatus.done);
    expect(chat.error, isNull);
  });

  test('old bridge: a drop in the background is reconciled, not failed',
      () async {
    await setUpChat(caps: fullCapabilities);
    final (body, done) = await startInOld();
    replies.setForeground(false);
    conversationWith('old', [
      messageJson('u9', conv: 'old', text: 'More?'),
      messageJson('a9', conv: 'old', role: 'assistant', text: 'Sure thing',
          status: 'cancelled', meta: {'stop_reason': 'disconnect'}),
    ]);
    await body.close();
    await done;
    expect(chat.messages.last.status, MessageStatus.stopped);
    expect(chat.messages.last.text, 'Sure thing');
    expect(chat.error, isNull);
    expect(http.count('GET /api/chat/a9/stream'), 0, reason: 'no resume route');
  });

  test('old bridge in the foreground: a drop still fails as network', () async {
    await setUpChat(caps: fullCapabilities);
    final (body, done) = await startInOld();
    await body.close();
    await done;
    expect(chat.messages.last.status, MessageStatus.failed);
    expect(chat.error?.kind, ChatErrorKind.network);
  });

  test('Stop calls the stop route and keeps the partial text', () async {
    await setUpChat();
    final (body, done) = await startInOld();
    http.on('POST /api/chat/a9/stop', (_) => jsonResponse({
          'ok': true,
          'conversation_id': 'old',
          'message_id': 'a9',
          'stopped': true,
          'status': 'cancelled',
          'text': 'Sure thing, and',
        }));
    chat.stop();
    await done;
    expect(chat.messages.last.status, MessageStatus.stopped);
    expect(chat.streaming, isFalse);
    expect(chat.canSend, isTrue);
    await settle();
    expect(http.count('POST /api/chat/a9/stop'), 1);
    expect(chat.messages.last.text, 'Sure thing, and', reason: 'saved text');
    body.idEvent(4, 'stopped', {'conversation_id': 'old', 'message_id': 'a9'});
    await settle();
    expect(chat.messages.last.status, MessageStatus.stopped);
  });

  test('Stop racing the end of the reply shows the finished reply', () async {
    await setUpChat();
    final (_, done) = await startInOld();
    http.on('POST /api/chat/a9/stop', (_) => jsonResponse({
          'ok': true,
          'conversation_id': 'old',
          'message_id': 'a9',
          'stopped': false,
          'status': 'complete',
          'text': 'Sure thing, all done.',
        }));
    chat.stop();
    await done;
    await settle();
    expect(chat.messages.last.status, MessageStatus.done);
    expect(chat.messages.last.text, 'Sure thing, all done.');
  });

  test('Stop before meta stops the reply on the bridge once its id arrives',
      () async {
    await setUpChat();
    final body = SseBody();
    http.on('POST /api/chat', (_) => body.response());
    http.on('POST /api/chat/a1/stop', (_) => jsonResponse({
          'ok': true, 'stopped': true, 'status': 'cancelled', 'text': '',
        }));
    final done = chat.send('Hi');
    await settle();
    chat.stop();
    await done;
    expect(chat.messages.single.status, MessageStatus.stopped);
    expect(chat.canSend, isTrue);
    body.idEvent(1, 'meta', {'conversation_id': 'n1', 'message_id': 'a1'});
    await settle();
    expect(http.count('POST /api/chat/a1/stop'), 1);
    expect(body.cancelled, isTrue);
  });

  test('cold start resumes a persisted reply after its last event id', () async {
    store = MemoryReplyStore([
      InFlightReply(
        server: api.baseUrl.toString(),
        messageId: 'a5',
        conversationId: 'old',
        started: DateTime.now(),
        lastEventId: 4,
        text: 'Hello wor',
        title: 'Chat old',
      ),
    ]);
    replies.dispose();
    replies = BackgroundReplies(store: store);
    chat.dispose();
    chat = makeChat();
    final finished = replies.finished.first;
    final body = SseBody();
    http.on('GET /api/chat/a5/stream', (_) => body.response());
    await setUpChat();
    await settle();
    expect(header(http.last('GET /api/chat/a5/stream'), 'Last-Event-ID'), '4');
    expect(chat.streamingElsewhere, isTrue);

    conversationWith('old', [
      messageJson('u5', conv: 'old'),
      messageJson('a5', conv: 'old', role: 'assistant', text: 'Hello w', status: 'streaming'),
    ]);
    await chat.load('old');
    expect(chat.streaming, isTrue);
    expect(chat.messages.last.text, 'Hello wor');
    body.idEvent(5, 'delta', {'text': 'ld'});
    body.idEvent(6, 'done', {'conversation_id': 'old', 'message_id': 'a5'});
    final t = await finished;
    expect(t.text, 'Hello world');
    expect(t.resumed, isTrue);
    await settle();
    expect(chat.messages.last.text, 'Hello world');
    expect(chat.messages.last.status, MessageStatus.done);
  });

  // Round 6 B1: "a task used 10 tools; after reopening the app only the last
  // one shows". A cold-start resume after a saved Last-Event-ID hears only
  // the newest step events; the stored meta.steps must fill in the rest, both
  // while it streams and after it ends (when the session keeps its own copy).
  test('a cold-start resume keeps every stored step, not just the last', () async {
    Map<String, dynamic> step(int n, {bool running = false}) => {
      'id': 's$n',
      'kind': 'tool',
      'state': running ? 'running' : 'done',
      'started_at': 1794730113880 + n * 1000,
      'ended_at': running ? null : 1794730113880 + n * 1000 + 500,
      'offset': 0,
      'tool': {'name': 'terminal', 'label': 'step $n', 'call_id': 'call_$n'},
    };
    store = MemoryReplyStore([
      InFlightReply(
        server: api.baseUrl.toString(),
        messageId: 'a6',
        conversationId: 'old',
        started: DateTime.now(),
        lastEventId: 40,
        text: 'Checking',
        title: 'Chat old',
      ),
    ]);
    replies.dispose();
    replies = BackgroundReplies(store: store);
    chat.dispose();
    chat = makeChat();
    final finished = replies.finished.first;
    final body = SseBody();
    http.on('GET /api/chat/a6/stream', (_) => body.response());
    await setUpChat();
    await settle();
    expect(header(http.last('GET /api/chat/a6/stream'), 'Last-Event-ID'), '40');
    conversationWith('old', [
      messageJson('u6', conv: 'old'),
      messageJson('a6', conv: 'old', role: 'assistant', text: 'Checking',
          status: 'streaming',
          meta: {'steps': [for (var n = 1; n <= 9; n++) step(n), step(10, running: true)]}),
    ]);
    await chat.load('old');
    expect(chat.streaming, isTrue);
    body.idEvent(41, 'step.end', {'message_id': 'a6', 'step': step(10)});
    await settle();
    var steps = chat.stepsFor(chat.messages.last);
    expect(steps.map((s) => s.id), [for (var n = 1; n <= 10; n++) 's$n']);
    expect(steps.last.running, isFalse, reason: 'the live end wins');
    body.idEvent(42, 'delta', {'text': ' done'});
    body.idEvent(43, 'done', {'conversation_id': 'old', 'message_id': 'a6'});
    await finished;
    await settle();
    steps = chat.stepsFor(chat.messages.last);
    expect(steps, hasLength(10), reason: 'the kept copy does not hide stored steps');
  });

  test('opening a chat whose reply is still streaming replays it from the start',
      () async {
    await setUpChat();
    final body = SseBody();
    http.on('GET /api/chat/a7/stream', (_) => body.response());
    conversationWith('old', [
      messageJson('u7', conv: 'old'),
      messageJson('a7', conv: 'old', role: 'assistant', text: 'Partial te', status: 'streaming'),
    ]);
    await chat.load('old');
    await settle();
    final req = http.last('GET /api/chat/a7/stream');
    expect(header(req, 'Last-Event-ID'), isNull);
    expect(chat.messages.last.text, 'Partial te', reason: 'saved copy meanwhile');
    body.idEvent(1, 'meta', {'conversation_id': 'old', 'message_id': 'a7'});
    body.idEvent(2, 'delta', {'text': 'Partial '});
    await settle();
    expect(chat.messages.last.text, 'Partial te');
    body.idEvent(3, 'delta', {'text': 'text, done'});
    body.idEvent(4, 'done', {'conversation_id': 'old', 'message_id': 'a7'});
    await settle();
    expect(chat.messages.last.text, 'Partial text, done');
    expect(chat.messages.last.status, MessageStatus.done);
  });

  test('a rejected Last-Event-ID resumes from the start', () async {
    await setUpChat();
    replies.pushActive = true;
    final (_, done) = await startInOld();
    replies.setForeground(false);
    var calls = 0;
    final again = SseBody();
    http.on('GET /api/chat/a9/stream', (req) {
      calls++;
      if (calls == 1) return errorResponse(400, 'bad_last_event_id');
      return again.response();
    });
    replies.setForeground(true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(calls, 2);
    expect(header(http.last('GET /api/chat/a9/stream'), 'Last-Event-ID'), isNull);
    again.idEvent(1, 'meta', {'conversation_id': 'old', 'message_id': 'a9'});
    again.idEvent(2, 'snapshot', {
      'conversation_id': 'old', 'message_id': 'a9', 'text': 'Sure thing',
      'status': 'streaming',
    });
    again.idEvent(9, 'done', {'conversation_id': 'old', 'message_id': 'a9'});
    await done;
    expect(chat.messages.last.text, 'Sure thing');
  });

  test('two chats can stream at once up to concurrent_chats', () async {
    await setUpChat();
    final (body, _) = await startInOld();
    await chat.load('other');
    expect(chat.canSend, isTrue);
    final second = SseBody();
    http.on('POST /api/chat', (_) => second.response());
    final done2 = chat.send('Also this');
    await settle();
    expect(replies.active.length, 2);
    chat.newChat();
    expect(chat.canSend, isFalse, reason: 'the bridge allows 2 at once');
    await chat.send('Third');
    expect(chat.error?.code, 'busy');
    second.idEvent(1, 'meta', {'conversation_id': 'other', 'message_id': 'b1'});
    second.idEvent(2, 'done', {'conversation_id': 'other', 'message_id': 'b1'});
    await done2;
    expect(chat.canSend, isTrue);
    expect(body.cancelled, isFalse);
  });

  test('a reconnect that never succeeds fails after giveUpAfter', () async {
    replies.dispose();
    replies = BackgroundReplies(
      backoff: (_) => const Duration(milliseconds: 5),
      giveUpAfter: const Duration(milliseconds: 40),
    );
    chat.dispose();
    chat = makeChat();
    await setUpChat();
    final (body, done) = await startInOld();
    http.on('GET /api/chat/a9/stream', (_) => errorResponse(503, 'history_unavailable'));
    await body.close();
    await done;
    expect(chat.messages.last.status, MessageStatus.failed);
    expect(chat.messages.last.text, 'Sure thing');
    expect(http.count('GET /api/chat/a9/stream'), greaterThan(1));
  });
}
