import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/ui/tasks/tasks_panel.dart';
import 'package:tove_chat/src/ui/thread/work_line.dart';

import '../chat/fake_http.dart';
import '../fakes.dart';
import 'test_harness.dart';

// The user's report (16 Nov 2026): Notion connector steps in the Tasks panel
// read "Connectors notion SEARCH NOTION PAGE" and overflowed the row by 62 and
// 81 px. These are the steps of that reply, as the bridge stored them.

const _t0 = 1794691021626;

Map<String, Object?> _tool(
  String id,
  int from,
  int to,
  String name,
  String label, {
  Object? input,
}) => {
  'id': id,
  'kind': 'tool',
  'state': 'done',
  'started_at': _t0 + from * 1000,
  'ended_at': _t0 + to * 1000,
  'tool': {
    'name': name,
    'label': label,
    'input': ?input,
    'output': 'ok',
    'details': true,
  },
};

Map<String, Object?> _call(String inner) => {
  'calls': [
    {
      'name': inner,
      'arguments': {'query': ''},
    },
  ],
};

final reportedSteps = [
  {
    'id': 's0',
    'kind': 'thinking',
    'state': 'done',
    'started_at': _t0 + 1000,
    'ended_at': _t0 + 2000,
    'text': '**Searching personal context**',
  },
  _tool('s1', 2, 5, 'skill_view', 'notion', input: {'name': 'notion'}),
  _tool(
    's2',
    5,
    8,
    'tool_describe',
    'Reading tool details · 1 tool',
    input: {
      'names': ['session_search'],
    },
  ),
  _tool(
    's3',
    8,
    9,
    'tool_call',
    'Notion · search notion page',
    input: _call('connectors__notion__SEARCH_NOTION_PAGE'),
  ),
  _tool('s4', 9, 11, 'session_search', 'recall: "family"'),
  _tool('s5', 11, 13, 'session_search', 'recall: "personal"'),
  for (final i in [6, 7, 8])
    _tool(
      's$i',
      13,
      14,
      'tool_call',
      'Notion · fetch block contents',
      input: _call('connectors__notion__FETCH_BLOCK_CONTENTS'),
    ),
];

void main() {
  group('tool names read naturally', () {
    test('connectors: service · action, no shouting, no "Connectors"', () {
      expect(
        toolName('connectors__notion__SEARCH_NOTION_PAGE'),
        'Notion · Search pages',
      );
      expect(
        toolName('connectors__notion__FETCH_BLOCK_CONTENTS'),
        'Notion · Read page',
      );
      expect(
        toolName('connectors__notion__FETCH_ALL_BLOCK_CONTENTS'),
        'Notion · Read page',
      );
      expect(
        toolName('connectors__notion__CREATE_NOTION_PAGE'),
        'Notion · Create page',
      );
      expect(toolName('mcp_github_create_issue'), 'GitHub · Create issue');
      expect(
        toolName('connectors__google_calendar__LIST_EVENTS'),
        'Google Calendar · List events',
      );
      expect(
        toolActivity('connectors__notion__SEARCH_NOTION_PAGE'),
        'Using Notion',
      );
    });

    test('Hermes tools have friendly names', () {
      expect(toolName('skill_view'), 'Read skill');
      expect(toolName('tool_describe'), 'Looking up tools');
      expect(toolName('tool_search'), 'Looking up tools');
      expect(toolName('session_search'), 'Searching past chats');
      expect(toolName('terminal'), 'Terminal');
      expect(toolName('read_file'), 'Read file');
      expect(toolName('web_search'), 'Web search');
      expect(toolActivity('session_search'), 'Searching past chats');
    });

    test('unknown tools: sentence case, acronyms kept', () {
      expect(toolName('FETCH_URL_AS_JSON'), 'Fetch URL as JSON');
      expect(toolName('check-dns.records'), 'Check DNS records');
      expect(toolName('restartContainer'), 'RestartContainer');
      expect(toolName(''), 'Tool');
    });
  });

  group('step rows never overflow', () {
    setUpAll(loadAppFonts);
    late FakeHttp http;
    late ChatController chat;
    late CallController call;

    setUp(() async {
      http = FakeHttp();
      chat = ChatController(api: fakeApi(http));
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
            messageJson('u1', text: 'Tell me something about my notes')
              ..['created'] = _t0,
            messageJson(
              'a1',
              role: 'assistant',
              text: 'Here is what I found.',
              meta: {'steps': reportedSteps},
            )..['created'] = _t0 + 500,
          ],
          'has_more': false,
        }),
      );
      await chat.init();
      await chat.load('conv1');
      call = CallController(
        apiFactory: FakeBridge().api,
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

    /// Every row's duration and chevron sit inside [within].
    void expectDurationsVisible(WidgetTester tester, Finder within) {
      final right = tester.getRect(within).right;
      for (final d in ['3s', '1s', '2s']) {
        for (final e in find.text(d).evaluate()) {
          expect(
            tester.getRect(find.byWidget(e.widget)).right,
            lessThan(right),
          );
        }
      }
      for (final e in find.byIcon(Icons.chevron_right_rounded).evaluate()) {
        expect(
          tester.getRect(find.byWidget(e.widget)).right,
          lessThanOrEqualTo(right),
        );
      }
    }

    for (final scale in [1.0, 2.0]) {
      testWidgets('Tasks panel at phone width, text ×$scale', (tester) async {
        phoneSize(tester, size: const Size(340, 1400));
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
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
        await tester.tap(find.textContaining('Show steps'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Notion · Search pages'), findsOneWidget);
        expect(find.text('Notion · Read page'), findsNWidgets(3));
        expect(find.text('Looking up tools'), findsOneWidget);
        expect(find.text('Searching past chats'), findsNWidgets(2));
        expect(find.textContaining('Connectors'), findsNothing);
        expect(find.textContaining('NOTION'), findsNothing);
        // The bridge's own label only repeated the name; it is not shown.
        expect(find.text('Notion · search notion page'), findsNothing);
        expect(find.text('1 tool'), findsOneWidget);
        expectDurationsVisible(tester, find.byType(ConversationTasksPanel));
        await expectLater(
          find.byType(ConversationTasksPanel),
          matchesGoldenFile(
            'goldens/tasks_panel_long_tools_x${scale.toInt()}.png',
          ),
        );
      });
    }

    testWidgets('chat work-line timeline, very long labels, text ×2', (
      tester,
    ) async {
      phoneSize(tester, size: const Size(320, 900));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final steps = [
        for (final s in reportedSteps) ReplyStep.fromJson(s)!,
        ReplyStep.fromJson(
          _tool(
            'x1',
            14,
            80,
            'connectors__an_unusually_long_service__'
                'DO_SOMETHING_WITH_A_VERY_LONG_NAME_THAT_KEEPS_GOING',
            'with a descriptor that is also far too long to fit anywhere',
          ),
        )!,
        ReplyStep.fromJson({
          ..._tool('x2', 80, 95, 'terminal', 'uptime && df -h / /srv'),
          'state': 'failed',
        })!,
      ];
      await tester.pumpWidget(
        themed(
          Material(
            color: Colors.black,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SingleChildScrollView(
                // The viewport is the capture's repaint boundary: paint the
                // page colour inside it.
                child: ColoredBox(
                  color: Colors.black,
                  child: StepTimeline(
                    steps: steps,
                    now: DateTime.fromMillisecondsSinceEpoch(_t0 + 99000),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expectDurationsVisible(tester, find.byType(StepTimeline));
      expect(find.text('1m 06s'), findsOneWidget);
      expect(find.text('15s'), findsOneWidget);
      expect(find.text('Notion · Read page'), findsNWidgets(3));
      await expectLater(
        find.byType(StepTimeline),
        matchesGoldenFile('goldens/work_timeline_long_tools_x2.png'),
      );
    });
  });
}
