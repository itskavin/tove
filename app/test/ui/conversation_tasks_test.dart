import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/call/models.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/ui/tasks/tasks_panel.dart';
import 'package:tove_chat/src/ui/thread/follow_scroll.dart';
import 'package:tove_chat/src/ui/thread/thread_view.dart';
import 'package:tove_chat/src/ui/thread/work_line.dart';

import '../chat/fake_http.dart';
import '../fakes.dart';
import 'test_harness.dart';

const _t0 = 1794691021626;

Map<String, dynamic> _msg(
  String id,
  int at, {
  String role = 'user',
  String text = 'hi',
  String source = 'text',
  String status = 'complete',
  String? clientId,
  Map<String, dynamic> meta = const {},
}) =>
    messageJson(
        id,
        role: role,
        text: text,
        source: source,
        status: status,
        meta: meta,
      )
      ..['created'] = _t0 + at * 1000
      ..['client_id'] = clientId;

/// Steps as the bridge stores them (`meta.steps`, API.md "Steps").
final _steps = [
  {
    'id': 's1',
    'kind': 'thinking',
    'state': 'done',
    'started_at': _t0 + 1000,
    'ended_at': _t0 + 2000,
    'text': '**Checking disk usage**',
  },
  {
    'id': 's2',
    'kind': 'tool',
    'state': 'done',
    'started_at': _t0 + 2000,
    'ended_at': _t0 + 5000,
    'tool': {'name': 'terminal', 'label': 'df -h /srv'},
  },
];

/// Text as shown, ignoring the voice glyph placed inside the bubble.
Finder _shown(String text) => find.byWidgetPredicate(
  (w) =>
      w is RichText &&
      w.text.toPlainText(includePlaceholders: false).trim() == text,
);

void main() {
  setUpAll(loadAppFonts);
  late FakeHttp http;
  late ChatController chat;
  late CallController call;

  setUp(() async {
    http = FakeHttp();
    final api = fakeApi(http);
    chat = ChatController(api: api);
    http.on('GET /api/capabilities', (_) => jsonResponse(fullCapabilities));
    http.on(
      'GET /api/conversations',
      (_) => jsonResponse({'conversations': [], 'next_cursor': null}),
    );
    http.on(
      'GET /api/conversations/conv1',
      (_) => jsonResponse({
        'conversation': conversationJson('conv1'),
        'messages': [
          _msg('u1', 0, text: 'How full is /srv?'),
          _msg(
            'a1',
            1,
            role: 'assistant',
            text: '/srv is 60% full.',
            meta: {'steps': _steps},
          ),
          _msg('u2', 10, text: 'Thanks'),
          _msg('a2', 11, role: 'assistant', text: 'Any time.'),
          _msg(
            't1',
            20,
            role: 'assistant',
            source: 'task',
            text: 'Backups are current.',
            clientId: 'job:sess:job7',
            meta: {'task': 'check the backups', 'job': 'job7', 'seconds': 12},
          ),
          _msg('u3', 30, text: 'Restart the media box'),
          _msg('a3', 31, role: 'assistant', text: '', status: 'error'),
        ],
        'has_more': false,
      }),
    );
    await chat.init();
    await chat.load('conv1');
    final bridge = FakeBridge();
    call = CallController(
      apiFactory: bridge.api,
      transportFactory: FakeTransport.new,
      platform: FakePlatform(supported: false),
      voice: () => 'cove',
      timings: fastTimings,
      desktop: true,
    );
  });

  tearDown(() {
    call.dispose();
    chat.dispose();
  });

  void addLiveTasks() {
    final d1Progress = const ChatProgress(
      label: 'grep -i error /var/log/syslog',
      state: ProgressState.running,
      tool: 'terminal',
      id: 'c1',
    );
    call.tasks.addAll([
      // Saved to the chat already: the message stands for it.
      TaskEntry('d0', 'check the backups', conversationId: 'conv1')
        ..job = 'job7'
        ..status = TaskStatus.stopped,
      TaskEntry('d1', 'summarise the error logs', conversationId: 'conv1')
        ..job = 'job8'
        ..status = TaskStatus.running
        ..progress = d1Progress
        ..tools.record(
          d1Progress,
          -1,
          DateTime.fromMillisecondsSinceEpoch(_t0 + 40000),
        )
        ..seconds = 4,
      // Another chat's task never shows here.
      TaskEntry('d2', 'plan the trip', conversationId: 'conv2')
        ..status = TaskStatus.running,
    ]);
  }

  test('only this chat’s work, newest first, from real data', () {
    addLiveTasks();
    final tasks = conversationTasks(chat: chat, call: call);
    expect(
      tasks.map((x) => (x.id, x.state)),
      [
        ('job-job8', ConversationTaskState.running),
        ('msg-t1', ConversationTaskState.done),
        ('reply-a1', ConversationTaskState.done),
      ],
      reason:
          'only tool work: a plain answer (a2) and a failed reply that '
          'called no tool (a3) are no tasks; d0 is saved as t1; d2 is '
          'another chat’s',
    );
    final live = tasks.first;
    expect(live.glimpse, 'Running terminal', reason: 'worded like the chat');
    expect(live.title, 'summarise the error logs');
    expect(live.canStop, isFalse, reason: 'no stop route for live jobs');
    final reply = tasks.last;
    expect(reply.steps.map((s) => s.kind), [StepKind.thinking, StepKind.tool]);
    expect(
      reply.elapsed,
      const Duration(seconds: 4),
      reason: 'reply start to last step end',
    );
    expect(tasks[1].elapsed, const Duration(seconds: 12));
  });

  test('a new chat has none; the call’s tasks follow the chat they belong '
      'to', () {
    addLiveTasks();
    chat.newChat();
    expect(conversationTasks(chat: chat, call: call), isEmpty);
  });

  testWidgets('the panel: running first, steps on demand, honest empty state', (
    tester,
  ) async {
    phoneSize(tester, size: const Size(360, 780));
    addLiveTasks();
    var closed = 0;
    await tester.pumpWidget(
      themed(
        ConversationTasksPanel(
          chat: chat,
          call: call,
          onClose: () => closed++,
          now: () => DateTime.fromMillisecondsSinceEpoch(_t0 + 60000),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Running now'), findsOneWidget);
    expect(find.text('Earlier in this chat'), findsOneWidget);
    expect(find.text('plan the trip'), findsNothing);
    expect(
      tester.getTopLeft(find.text('summarise the error logs')).dy,
      lessThan(tester.getTopLeft(find.text('How full is /srv?')).dy),
    );
    expect(find.text('Retry'), findsNothing, reason: 'a3 is no task');
    expect(find.text('Restart the media box'), findsNothing);
    // Finished work keeps its steps folded until asked.
    expect(find.byType(StepTimeline), findsOneWidget, reason: 'running only');
    await tester.tap(find.textContaining('Show steps · 1 tool and thinking'));
    await tester.pump();
    expect(find.byType(StepTimeline), findsNWidgets(2));
    expect(find.text('df -h /srv'), findsOneWidget);
    await tester.tap(find.byTooltip('Close tasks'));
    expect(closed, 1);

    chat.newChat();
    call.tasks.clear();
    await tester.pump();
    expect(find.text('Nothing running in this chat'), findsOneWidget);
    // Let the close button's tooltip timers run out.
    await tester.pump(const Duration(seconds: 2));
  });

  for (final tools in [true, false]) {
    testWidgets('golden: the Tasks panel ${tools ? 'with' : 'without'} tool '
        'calls', (tester) async {
      phoneSize(tester, size: const Size(412, 780));
      if (tools) {
        addLiveTasks();
      } else {
        http.on(
          'GET /api/conversations/conv2',
          (_) => jsonResponse({
            'conversation': conversationJson('conv2'),
            'messages': [
              _msg('u1', 0, text: 'Hi'),
              _msg('a1', 1, role: 'assistant', text: 'Hello!'),
              _msg('u2', 2, text: 'Restart the media box'),
              _msg('a2', 3, role: 'assistant', text: '', status: 'error'),
            ],
            'has_more': false,
          }),
        );
        await tester.runAsync(() => chat.load('conv2'));
      }
      await tester.pumpWidget(
        themed(
          ConversationTasksPanel(
            chat: chat,
            call: call,
            onClose: () {},
            now: () => DateTime.fromMillisecondsSinceEpoch(_t0 + 60000),
          ),
        ),
      );
      await tester.pump();
      if (!tools) {
        expect(find.text('Nothing running in this chat'), findsOneWidget);
      }
      await expectLater(
        find.byType(ConversationTasksPanel),
        matchesGoldenFile(
          'goldens/tasks_panel_${tools ? 'tool_calls' : 'plain_replies'}.png',
        ),
      );
    });
  }

  testWidgets('spoken turns: one action row per reply, and fragments saved by '
      'older versions are hidden', (tester) async {
    http.on(
      'GET /api/conversations/conv9',
      (_) => jsonResponse({
        'conversation': conversationJson('conv9', kind: 'live'),
        'messages': [
          // The screenshot, as the old app saved it.
          _msg('v1', 0, source: 'voice', text: 'Can', clientId: 'turn:s-1'),
          _msg(
            'v2',
            1,
            source: 'voice',
            text: 'Can you download the entire internet',
            clientId: 'turn:s-2',
          ),
          _msg(
            'v3',
            2,
            role: 'assistant',
            source: 'voice',
            text: "I'll",
            clientId: 'turn:s-3',
          ),
          _msg(
            'v4',
            3,
            role: 'assistant',
            source: 'voice',
            text: "I'll check that quickly.",
            clientId: 'turn:s-4',
          ),
          _msg(
            'v5',
            4,
            role: 'assistant',
            source: 'voice',
            text: 'Not',
            clientId: 'turn:s-5',
          ),
          _msg(
            'v6',
            5,
            role: 'assistant',
            source: 'voice',
            text: 'Not realistically.',
            clientId: 'turn:s-6',
          ),
        ],
        'has_more': false,
      }),
    );
    await chat.load('conv9');
    phoneSize(tester);
    final scroll = FollowScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      themed(
        Scaffold(
          body: ThreadView(
            chat: chat,
            scroll: scroll,
            topInset: 80,
            bottomInset: 100,
            onSuggestion: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    for (final gone in ['Can', "I'll", 'Not']) {
      expect(_shown(gone), findsNothing, reason: gone);
    }
    expect(_shown('Can you download the entire internet'), findsOneWidget);
    expect(_shown("I'll check that quickly."), findsOneWidget);
    expect(_shown('Not realistically.'), findsOneWidget);
    expect(
      find.byTooltip('Copy'),
      findsOneWidget,
      reason: 'the acknowledgement and the answer are one spoken reply',
    );
  });
}
