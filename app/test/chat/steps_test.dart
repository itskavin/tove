import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/ui/tasks/conversation_tasks.dart';

import 'fake_http.dart';

const _t0 = 1794730113880;

Map<String, dynamic> toolStep(
  String id, {
  String state = 'running',
  int start = _t0,
  int? end,
  String name = 'terminal',
  String label = 'echo hi',
  Object? input,
  String? output,
  int? exit,
  bool details = false,
}) => {
  'id': id,
  'kind': 'tool',
  'state': state,
  'started_at': start,
  'ended_at': end,
  'offset': 0,
  'tool': {
    'name': name,
    'label': label,
    'emoji': '💻',
    'call_id': 'call_$id',
    'input': input ?? label,
    'output': output,
    'exit_status': exit,
    'error': null,
    'truncated': false,
    'details': details,
  },
};

void main() {
  group('step model', () {
    test('parses the contract example', () {
      final s = ReplyStep.fromJson(
        toolStep(
          's2',
          state: 'done',
          end: _t0 + 2771,
          input: {'command': 'echo hi'},
          output: 'hi',
          exit: 0,
          details: true,
        ),
      )!;
      expect(s.id, 's2');
      expect(s.kind, StepKind.tool);
      expect(s.state, StepPhase.done);
      expect(s.elapsed(DateTime.now()).inMilliseconds, 2771);
      expect(s.tool!.name, 'terminal');
      expect(s.tool!.input, {'command': 'echo hi'});
      expect(s.tool!.output, 'hi');
      expect(s.tool!.exitStatus, 0);
      expect(s.tool!.details, isTrue);
      final back = ReplyStep.fromJson(s.toJson())!;
      expect(back.tool!.output, 'hi');
      expect(back.ended, s.ended);
    });

    test('start, delta and an out-of-order end', () {
      final log = StepLog()
        ..start(
          ReplyStep.fromJson({
            'id': 's1',
            'kind': 'thinking',
            'state': 'running',
            'started_at': _t0,
          })!,
        )
        ..delta('s1', 'Let me ')
        ..delta('s1', 'look.')
        ..start(ReplyStep.fromJson(toolStep('s2'))!)
        ..start(
          ReplyStep.fromJson({
            'id': 's3',
            'kind': 'thinking',
            'state': 'running',
            'started_at': _t0 + 10,
          })!,
        );
      expect(log.steps.first.text, 'Let me look.');
      // s2's end arrives after s3 started: it replaces s2 in place.
      log.end(
        ReplyStep.fromJson(
          toolStep('s2', state: 'done', end: _t0 + 5, output: 'hi'),
        )!,
      );
      expect(log.steps.map((s) => s.id), ['s1', 's2', 's3']);
      expect(log.steps[1].tool!.output, 'hi');
      log.finish(DateTime.fromMillisecondsSinceEpoch(_t0 + 99), failed: true);
      expect(log.steps[0].state, StepPhase.failed);
      expect(log.steps[2].state, StepPhase.failed);
      expect(log.steps[1].state, StepPhase.done, reason: 'already ended');
    });

    test('SSE step events parse', () {
      final start = ChatApi.parseChatEvent(
        SseEvent(
          'step.start',
          '{"message_id":"a1","step":{"id":"s1","kind":"tool",'
              '"state":"running","started_at":$_t0,"tool":{"name":"terminal"}}}',
        ),
      );
      expect(start, isA<ChatStepEvent>());
      expect((start! as ChatStepEvent).end, isFalse);
      final delta = ChatApi.parseChatEvent(
        SseEvent('step.delta', '{"message_id":"a1","id":"s1","text":"hm"}'),
      );
      expect((delta! as ChatStepDeltaEvent).text, 'hm');
      final end = ChatApi.parseChatEvent(
        SseEvent(
          'step.end',
          '{"message_id":"a1","step":{"id":"s1","kind":"tool",'
              '"state":"failed","started_at":$_t0,"ended_at":${_t0 + 1}}}',
        ),
      );
      expect((end! as ChatStepEvent).step.state, StepPhase.failed);
      expect(
        ChatApi.parseChatEvent(SseEvent('step.start', '{"step":{"id":"x"}}')),
        isNull,
        reason: 'no started_at',
      );
    });

    test('the fallback adapter turns tool calls into steps', () {
      final t = DateTime.fromMillisecondsSinceEpoch(_t0);
      final steps = stepsFromToolCalls([
        ToolCall(
          id: 'c1',
          tool: 'web_search',
          label: 'flutter news',
          started: t,
          ended: t.add(const Duration(seconds: 2)),
          state: ToolCallState.done,
          offset: 4,
        ),
        ToolCall(id: '', tool: 'terminal', label: 'ls', started: t, offset: 9),
      ]);
      expect(steps.map((s) => s.id), ['c1', 'tool-1']);
      expect(steps.first.state, StepPhase.done);
      expect(steps.first.tool!.label, 'flutter news');
      expect(steps.first.tool!.details, isFalse);
      expect(steps.last.running, isTrue);
    });
  });

  group('controller', () {
    late FakeHttp http;
    late ChatController chat;

    setUp(() {
      http = FakeHttp();
      chat = ChatController(api: fakeApi(http), newClientId: () => 'c-1');
    });
    tearDown(() => chat.dispose());

    Future<void> init() async {
      http.on(
        'GET /api/capabilities',
        (_) => jsonResponse({...fullCapabilities, 'steps': true}),
      );
      http.on(
        'GET /api/conversations',
        (_) => jsonResponse({'conversations': [], 'next_cursor': null}),
      );
      await chat.init();
    }

    test('a streaming reply is a task only once it calls a tool', () async {
      await init();
      final body = SseBody();
      http.on('POST /api/chat', (_) => body.response());
      final sent = chat.send('Hello');
      await settle();
      body.meta(conv: 'c9', msg: 'a1', user: 'u1', created: true);
      body.event('step.start', {
        'message_id': 'a1',
        'step': {
          'id': 't1',
          'kind': 'thinking',
          'state': 'running',
          'started_at': _t0,
          'text': '**Greeting**',
        },
      });
      body.delta('Hi there');
      await settle();
      expect(chat.streaming, isTrue);
      expect(conversationTasks(chat: chat), isEmpty, reason: 'thinking only');
      expect(toolWorkRunning(chat: chat), isFalse);

      body.event('step.start', {'message_id': 'a1', 'step': toolStep('s1')});
      await settle();
      final tasks = conversationTasks(chat: chat);
      expect(tasks.single.state, ConversationTaskState.running);
      expect(toolWorkRunning(chat: chat), isTrue);

      http.on(
        'GET /api/conversations/c9',
        (_) => jsonResponse({
          'conversation': conversationJson('c9'),
          'messages': [],
          'has_more': false,
        }),
      );
      body.done(conv: 'c9', msg: 'a1');
      await sent;
      expect(toolWorkRunning(chat: chat), isFalse);
    });

    test('live steps, then the stored copy after a reload', () async {
      await init();
      final body = SseBody();
      http.on('POST /api/chat', (_) => body.response());
      final sent = chat.send('Run echo hi');
      await settle();
      body.meta(conv: 'c9', msg: 'a1', user: 'u1', created: true);
      body.event('step.start', {'message_id': 'a1', 'step': toolStep('s1')});
      // The old status event still arrives; steps win over it.
      body.event('status', {
        'label': 'echo hi',
        'state': 'running',
        'tool': 'terminal',
        'id': 'call_s1',
      });
      await settle();
      var m = chat.streamingMessage!;
      expect(chat.stepsFor(m).map((s) => s.id), ['s1']);
      expect(chat.stepsFor(m).single.running, isTrue);

      body.event('step.end', {
        'message_id': 'a1',
        'step': toolStep(
          's1',
          state: 'done',
          end: _t0 + 3000,
          input: {'command': 'echo hi'},
          output: 'hi',
          exit: 0,
          details: true,
        ),
      });
      body.delta('It printed hi.');
      http.on(
        'GET /api/conversations/c9',
        (_) => jsonResponse({
          'conversation': conversationJson('c9'),
          'messages': [],
          'has_more': false,
        }),
      );
      body.done(conv: 'c9', msg: 'a1');
      await sent;
      m = chat.messages.last;
      expect(chat.stepsFor(m).single.tool!.output, 'hi');

      // A fresh controller (app restart) reads meta.steps.
      final again = ChatController(api: fakeApi(http));
      addTearDown(again.dispose);
      http.on(
        'GET /api/conversations/c9',
        (_) => jsonResponse({
          'conversation': conversationJson('c9'),
          'messages': [
            messageJson('u1', conv: 'c9', text: 'Run echo hi'),
            messageJson(
              'a1',
              conv: 'c9',
              role: 'assistant',
              text: 'It printed hi.',
              meta: {
                'steps': [
                  toolStep(
                    's1',
                    state: 'done',
                    end: _t0 + 3000,
                    output: 'hi',
                    details: true,
                  ),
                ],
                'tools': [
                  {'id': 'x', 'tool': 'terminal', 'started': _t0},
                ],
              },
            ),
          ],
          'has_more': false,
        }),
      );
      await again.init();
      await again.load('c9');
      final stored = again.stepsFor(again.messages.last);
      expect(stored.map((s) => s.id), ['s1'], reason: 'steps win over tools');
      expect(stored.single.tool!.output, 'hi');
    });

    test('without steps, meta.tools still fills the timeline', () async {
      await init();
      http.on(
        'GET /api/conversations/old',
        (_) => jsonResponse({
          'conversation': conversationJson('old'),
          'messages': [
            messageJson(
              'a1',
              conv: 'old',
              role: 'assistant',
              text: 'ok',
              meta: {
                'tools': [
                  {
                    'id': 't1',
                    'tool': 'web_search',
                    'label': 'weather',
                    'state': 'completed',
                    'started': _t0,
                    'ended': _t0 + 2000,
                  },
                ],
              },
            ),
          ],
          'has_more': false,
        }),
      );
      await chat.load('old');
      final steps = chat.stepsFor(chat.messages.single);
      expect(steps.single.tool!.name, 'web_search');
      expect(steps.single.tool!.output, isNull);
    });
  });
}
