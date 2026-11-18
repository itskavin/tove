import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/background/background.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/ui/tasks/conversation_tasks.dart';

import '../chat/fake_http.dart';

/// The reported bug (16 Nov 2026): "When I start a task in live and close
/// live after the task has started, the task no longer shows in the UI."
/// Root cause: live tasks lived only in the call controller, which marked
/// them "Continues in the chat" when the call ended; the chat got the result
/// only when the job finished, and only after a timed re-read.
///
/// Now the bridge writes the task into the chat when it starts (a
/// `source: task` message with `status: streaming`) and the app follows it
/// like a reply.
void main() {
  late FakeHttp http;
  late ChatApi api;
  late ChatController chat;
  late TaskStreams tasks;
  late SseBody body;
  late List<Map<String, dynamic>> messages;

  Map<String, dynamic> taskJson(String status, {String text = ''}) =>
      messageJson(
        't1',
        conv: 'c1',
        role: 'assistant',
        text: text,
        source: 'task',
        status: status,
        meta: {'task': 'check the disk', 'job': 'j1', 'session': 's1'},
      );

  setUp(() async {
    http = FakeHttp();
    api = fakeApi(http);
    body = SseBody();
    messages = [
      messageJson('v1', conv: 'c1', text: 'check the disk', source: 'voice'),
      taskJson('streaming'),
    ];
    http.on(
      'GET /api/capabilities',
      (_) => jsonResponse({
        ...resumableCapabilities,
        'task_messages': true,
        'events': {'version': 1, 'heartbeat_s': 80},
      }),
    );
    http.on(
      'GET /api/conversations',
      (_) => jsonResponse({
        'conversations': [conversationJson('c1', kind: 'live')],
        'next_cursor': null,
      }),
    );
    http.on(
      'GET /api/conversations/c1',
      (_) => jsonResponse({
        'conversation': conversationJson('c1', kind: 'live'),
        'messages': messages,
        'has_more': false,
      }),
    );
    http.on('GET /api/chat/t1/stream', (_) => body.response());
    tasks = TaskStreams(
      api: api,
      backoff: (_) => const Duration(milliseconds: 20),
    );
    chat = ChatController(
      api: api,
      conversations: ConversationsController(api: api),
      tasks: tasks,
    );
    await chat.init();
  });

  tearDown(() {
    chat.dispose();
    tasks.dispose();
  });

  test('a running live task shows in the thread and the Tasks panel, with steps, after the call', () async {
    await chat.load('c1');
    await settle();
    expect(http.count('GET /api/chat/t1/stream'), 1);
    body.idEvent(1, 'meta', {
      'conversation_id': 'c1',
      'message_id': 't1',
      'user_message_id': null,
      'source': 'task',
      'session': 's1',
      'job': 'j1',
      'title': 'Disk',
    });
    body.idEvent(2, 'step.start', {
      'message_id': 't1',
      'step': {
        'id': 's1',
        'kind': 'tool',
        'state': 'running',
        'started_at': 1794691022000,
        'tool': {'name': 'terminal', 'label': 'df -h'},
      },
    });
    body.idEvent(3, 'status', {
      'label': 'df -h',
      'state': 'running',
      'tool': 'terminal',
      'id': 'call_1',
    });
    await settle();
    final shown = chat.messages.last;
    expect((shown.id, shown.isTask, shown.isStreaming), ('t1', true, true));
    expect(chat.stepsFor(shown).single.running, isTrue);
    final panel = conversationTasks(chat: chat);
    expect(panel.single.state, ConversationTaskState.running);
    expect(panel.single.title, 'check the disk');
    expect(panel.single.steps.single.tool?.label, contains('df -h'));
    expect(panel.single.canStop, isTrue);
    // A running task never blocks typing in the same chat.
    expect(chat.canSend, isTrue);

    body.idEvent(4, 'delta', {'text': 'Disk is fine: '});
    body.idEvent(5, 'delta', {'text': '412 GB free.'});
    await settle();
    expect(chat.messages.last.text, 'Disk is fine: 412 GB free.');

    // It ends: the chat is re-read, and the saved answer is Hermes' reply.
    messages[1] = taskJson('complete', text: 'Disk is fine: 412 GB free.')
      ..['meta'] = {'task': 'check the disk', 'job': 'j1', 'seconds': 12};
    body.idEvent(6, 'done', {
      'conversation_id': 'c1',
      'message_id': 't1',
      'finish_reason': 'stop',
      'title': 'Disk',
    });
    await settle(10);
    final done = chat.messages.last;
    expect(
      (done.status, done.text, done.taskSeconds),
      (MessageStatus.done, 'Disk is fine: 412 GB free.', 12),
    );
    expect(
      conversationTasks(chat: chat).single.state,
      ConversationTaskState.done,
    );
    expect(tasks.active, isEmpty);
  });

  test('background closes the reader (so the bridge notifies); return resumes after the last id', () async {
    await chat.load('c1');
    await settle();
    body.idEvent(1, 'meta', {'conversation_id': 'c1', 'message_id': 't1'});
    body.idEvent(2, 'delta', {'text': 'Checking'});
    await settle();
    tasks.setForeground(false);
    await settle();
    expect(body.cancelled, isTrue);
    expect(
      chat.messages.last.isStreaming,
      isTrue,
      reason: 'still running on the bridge',
    );
    final again = SseBody();
    http.on('GET /api/chat/t1/stream', (_) => again.response());
    tasks.setForeground(true);
    await settle();
    expect(http.last('GET /api/chat/t1/stream').headers['Last-Event-ID'], '2');
    again.idEvent(3, 'delta', {'text': ' now'});
    await settle();
    expect(chat.messages.last.text, 'Checking now');
  });

  test(
    'a dropped stream reconnects; failure and timeout read clearly',
    () async {
      await chat.load('c1');
      await settle();
      body.idEvent(1, 'meta', {'conversation_id': 'c1', 'message_id': 't1'});
      await settle();
      final again = SseBody();
      http.on('GET /api/chat/t1/stream', (_) => again.response());
      await body.close();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await settle();
      expect(http.count('GET /api/chat/t1/stream'), 2);
      messages[1] = taskJson('error', text: '')
        ..['meta'] = {'task': 'check the disk', 'error_code': 'timeout'};
      again.idEvent(2, 'error', {
        'conversation_id': 'c1',
        'message_id': 't1',
        'code': 'timeout',
        'message': 'slow',
      });
      await settle(10);
      final t = conversationTasks(chat: chat).single;
      expect(t.state, ConversationTaskState.failed);
      expect(t.detail, contains('15 minutes'));
    },
  );

  test('switching chats lets go of the other chat’s tasks; stop uses the stop route', () async {
    await chat.load('c1');
    await settle();
    expect(tasks.active, hasLength(1));
    http.on(
      'POST /api/chat/t1/stop',
      (_) => jsonResponse({
        'ok': true,
        'conversation_id': 'c1',
        'message_id': 't1',
        'stopped': true,
        'status': 'cancelled',
        'text': 'half',
      }),
    );
    messages[1] = taskJson('cancelled', text: 'half');
    await chat.stopTask('t1');
    await settle();
    expect(http.count('POST /api/chat/t1/stop'), 1);
    expect(tasks.active, isEmpty);
    http.on(
      'GET /api/conversations/c2',
      (_) => jsonResponse({
        'conversation': conversationJson('c2'),
        'messages': [],
        'has_more': false,
      }),
    );
    messages[1] = taskJson('streaming');
    body = SseBody();
    await chat.load('c1');
    await settle();
    expect(tasks.active, hasLength(1));
    await chat.load('c2');
    await settle();
    expect(tasks.active, isEmpty);
  });

  test(
    'a bridge without task messages: saved results only, nothing followed',
    () async {
      http.on(
        'GET /api/capabilities',
        (_) => jsonResponse(resumableCapabilities),
      );
      await chat.refreshCapabilities();
      await chat.load('c1');
      await settle();
      expect(http.count('GET /api/chat/t1/stream'), 0);
    },
  );
}
