import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/ui/thread/messages.dart';
import 'package:tove_chat/src/ui/thread/work_line.dart';

import 'test_harness.dart';

final _t0 = DateTime.fromMillisecondsSinceEpoch(1794730113880);
DateTime _at(int ms) => _t0.add(Duration(milliseconds: ms));

ReplyStep _tool(
  String id, {
  StepPhase state = StepPhase.done,
  int start = 0,
  int? end,
  String name = 'terminal',
  String label = 'echo hi',
  Object? input,
  String? output,
  int? exit,
  String? error,
  bool details = true,
  int offset = -1,
}) => ReplyStep(
  id: id,
  kind: StepKind.tool,
  state: state,
  started: _at(start),
  ended: end == null ? null : _at(end),
  offset: offset,
  tool: StepTool(
    name: name,
    label: label,
    input: input,
    output: output,
    exitStatus: exit,
    error: error,
    details: details,
  ),
);

ReplyStep _thinking(String id, String text, {int start = 0, int? end}) =>
    ReplyStep(
      id: id,
      kind: StepKind.thinking,
      state: end == null ? StepPhase.running : StepPhase.done,
      started: _at(start),
      ended: end == null ? null : _at(end),
      text: text,
    );

ChatMessage _reply({String text = '', bool streaming = false}) => ChatMessage(
  id: 'a1',
  conversationId: 'c',
  role: MessageRole.assistant,
  text: text,
  status: streaming ? MessageStatus.streaming : MessageStatus.done,
  created: _t0,
);

final _doneSteps = [
  _thinking(
    's1',
    'The user wants the output of a shell command. I will run it in the **terminal**.',
    end: 1500,
  ),
  _tool(
    's2',
    start: 1600,
    end: 4600,
    input: {'command': 'echo hi'},
    output: 'hi',
    exit: 0,
  ),
  _tool(
    's3',
    state: StepPhase.failed,
    start: 5000,
    end: 12000,
    label: 'cat /nope',
    input: {'command': 'cat /nope'},
    output: 'cat: /nope: No such file or directory',
    exit: 1,
  ),
];

void main() {
  setUpAll(loadAppFonts);

  Widget reply(
    ChatMessage m,
    List<ReplyStep> steps, {
    Brightness brightness = Brightness.dark,
    bool reduce = false,
    double scale = 1,
  }) => themed(
    Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: AssistantMessage(
              message: m,
              steps: steps,
              onRetry: null,
              onDelete: () {},
              showActions: false,
              now: () => _at(13000),
            ),
          ),
        ),
      ),
    ),
    brightness: brightness,
    reduce: reduce,
  );

  group('words', () {
    test('bridge offsets keep Unicode commentary in the activity and answer intact', () {
      const preamble = 'I’ll check 🔎.\n\n';
      final steps = [_tool('s', offset: preamble.runes.length, end: 4000)];
      final result = replyPresentation('$preamble**Found it.**', steps);
      expect(result.activity, 'I’ll check 🔎.');
      expect(result.answer, '**Found it.**');
      expect(
        replyPresentation('Old reply', [_tool('legacy')]).answer,
        'Old reply',
      );
      expect(
        replyPresentation('Short', [_tool('bad', offset: 999)]).answer,
        'Short',
      );
      // Saved replies open with Hermes' "\n\n" (QA 15 November 2026); a first
      // line's indent is not a blank line and stays.
      const saved = '\n\n```python\ndef deduplicate(items):\n    ';
      expect(
        replyPresentation(saved, const []).answer,
        '```python\ndef deduplicate(items):\n    ',
      );
      expect(
        replyPresentation(saved, [_thinking('t', 'x', end: 1)]).answer,
        startsWith('```python'),
      );
      expect(replyPresentation(' \n\t\n    code', const []).answer, '    code');
    });
    test('tool_call shows the lazily loaded tool it ran', () {
      const call = StepTool(
        name: 'tool_call',
        input: {
          'calls': [
            {
              'name': 'image_search',
              'arguments': {'query': 'red panda'},
            },
          ],
        },
      );
      expect(call.shownName, 'image_search');
      expect(toolName(call.shownName), 'Image search');
      expect(toolActivity(call.shownName), 'Searching images');
      expect(
        const StepTool(
          name: 'tool_call',
          input: '{"calls": [{"name": "web_search"}]}',
        ).shownName,
        'web_search',
      );
      for (final odd in <Object?>[
        null,
        'not json',
        {'calls': 3},
        {},
      ]) {
        expect(StepTool(name: 'tool_call', input: odd).shownName, 'tool_call');
      }
      expect(const StepTool(name: 'terminal').shownName, 'terminal');
      expect(toolName('tool_search'), 'Looking up tools');
      expect(toolName('tool_describe'), 'Looking up tools');
    });
    test('glimpse names what runs now', () {
      expect(workGlimpse(const [], null), 'Thinking');
      expect(
        workGlimpse([_tool('a', state: StepPhase.running)], null),
        'Running terminal',
      );
      expect(
        workGlimpse([
          _tool('a', name: 'web_search', state: StepPhase.running),
        ], null),
        'Searching the web',
      );
      expect(
        workGlimpse([
          _tool('a', name: 'read_file', state: StepPhase.running),
        ], null),
        'Reading file',
      );
      expect(workGlimpse([_thinking('t', '')], null), 'Thinking');
      // A real reasoning summary's title (QA 15 November 2026), as sent.
      expect(
        workGlimpse([_thinking('t', '**Reviewing coding request**\n\n')], null),
        'Reviewing coding request',
      );
      expect(
        workGlimpse([
          _thinking(
            't',
            '**Reviewing coding request**\n\nThe user wants a dedupe.\n\n'
                '**Choosing an approach**',
          ),
        ], null),
        'Choosing an approach',
      );
      expect(
        workGlimpse([
          _thinking('t', 'I will run it in the **terminal**.'),
        ], null),
        'Thinking',
        reason: 'only a whole-line title names the step',
      );
      expect(
        workGlimpse([_thinking('t', '**Reviewing**', end: 200)], null),
        'Thinking',
        reason: 'a finished thinking step is not "running"',
      );
      expect(
        workGlimpse(
          [_tool('a', end: 3)],
          const ChatProgress(
            label: 'Waiting for the provider',
            state: ProgressState.info,
          ),
        ),
        'Waiting for the provider',
      );
      expect(
        workGlimpse([_tool('a', end: 3)], null),
        'Thinking',
        reason: 'a finished tool is not "running"',
      );
    });

    test('summary and duration', () {
      final d = workDuration(_doneSteps, replyStart: _t0);
      expect(d.inSeconds, 12);
      expect(workSummary(_doneSteps, d), 'Worked for 12s');
      expect(
        workSummary([
          _thinking('t', 'x', end: 3000),
        ], const Duration(seconds: 3)),
        'Thought for 3s',
      );
      expect(workSummary(_doneSteps, d, spoken: true), 'Worked for 12 seconds');
      expect(shortDuration(const Duration(seconds: 65)), '1m 05s');
      expect(
        workDuration(
          _doneSteps,
          replyStart: _t0.subtract(const Duration(hours: 1)),
        ).inSeconds,
        12,
        reason: 'an implausible start is ignored',
      );
    });

    test('input formatting', () {
      expect(formatToolInput({'command': 'echo hi'}), 'echo hi');
      expect(formatToolInput('ls -la'), 'ls -la');
      expect(
        formatToolInput({'path': '/a', 'limit': 3}),
        '{\n  "path": "/a",\n  "limit": 3\n}',
      );
    });
  });

  testWidgets(
    'completed activity disclosure contains interim messages and tool details in order',
    (tester) async {
      phoneSize(tester);
      const preamble = 'I will check the storage.\n\n';
      final steps = [
        _tool(
          's',
          offset: preamble.runes.length,
          end: 4000,
          input: {'command': 'df -h'},
          output: '40% used',
        ),
      ];
      await tester.pumpWidget(
        reply(_reply(text: '${preamble}The pool is **40% full**.'), steps),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('I will check', findRichText: true),
        findsNothing,
      );
      expect(
        find.textContaining('40% full', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(find.text('Worked for 4s'));
      await tester.pumpAndSettle();
      final commentary = find.textContaining(
        'I will check',
        findRichText: true,
      );
      expect(commentary, findsOneWidget);
      expect(
        tester.getTopLeft(commentary).dy,
        lessThan(tester.getTopLeft(find.text('Terminal')).dy),
      );
      await tester.tap(find.text('Terminal'));
      await tester.pumpAndSettle();
      expect(find.text('df -h'), findsOneWidget);
      expect(find.text('40% used'), findsOneWidget);
    },
  );

  testWidgets('thinking glimpse: one line, no box, no tool cards', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(reply(_reply(streaming: true), const []));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Thinking'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      find.byIcon(Icons.chevron_right_rounded),
      findsNothing,
      reason: 'nothing to open yet',
    );
    final line = tester.getSemantics(find.byKey(const ValueKey('work-line')));
    expect(line, isSemantics(label: 'Thinking', isLiveRegion: true));
  });

  testWidgets('a reply that opens with blank lines: no gap, title glimpse', (
    tester,
  ) async {
    phoneSize(tester);
    final thinking = _thinking('s1', '**Reviewing coding request**\n\n');
    // Streaming, only the "\n\n" so far: still working, no empty answer box.
    await tester.pumpWidget(
      reply(_reply(text: '\n\n', streaming: true), [thinking]),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Reviewing coding request'), findsOneWidget);
    expect(find.byType(SelectionArea), findsNothing);

    // Reloaded from the bridge (meta.steps): the code block sits where it
    // would without the blank lines, and the thinking text is rendered
    // markdown in the timeline, not raw asterisks.
    final steps = [
      _thinking(
        's1',
        '**Reviewing coding request**\n\n',
        start: 5219,
        end: 5368,
      ),
      _tool('s2', name: 'skill_view', start: 5368, end: 5549, offset: 0),
    ];
    const code =
        '```python\ndef deduplicate(items):\n'
        '    return list(dict.fromkeys(items))\n```';
    Future<double> codeTop(String text) async {
      await tester.pumpWidget(reply(_reply(text: text), steps));
      await tester.pumpAndSettle();
      return tester
          .getTopLeft(find.textContaining('deduplicate', findRichText: true))
          .dy;
    }

    final clean = await codeTop(code);
    expect(await codeTop('\n\n$code'), clean);
    await tester.tap(find.text('Worked for 6s'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Reviewing coding request', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('**', findRichText: true), findsNothing);
  });

  testWidgets('glimpse follows the running tool, then settles', (tester) async {
    phoneSize(tester);
    final running = [
      _tool('s1', state: StepPhase.running, start: 400, input: 'echo hi'),
    ];
    await tester.pumpWidget(reply(_reply(streaming: true), running));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Running terminal'), findsOneWidget);
    expect(find.text('Terminal'), findsNothing, reason: 'collapsed');

    // The reply starts writing while nothing runs: the line settles.
    await tester.pumpWidget(
      reply(_reply(text: 'It printed hi.', streaming: true), [
        _tool('s1', start: 400, end: 3400, output: 'hi'),
      ]),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Worked for 3s'), findsOneWidget);
    expect(find.text('Running terminal'), findsNothing);
  });

  testWidgets('expand: timeline, then a tool opens its input and output', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(
      reply(_reply(text: 'It printed **hi**.'), _doneSteps),
    );
    expect(find.text('Worked for 12s'), findsOneWidget);
    var line = tester.getSemantics(find.byKey(const ValueKey('work-line')));
    expect(
      line,
      matchesSemantics(
        label: 'Worked for 12 seconds',
        isButton: true,
        hasExpandedState: true,
        hasTapAction: true,
        onTapHint: 'expand',
      ),
    );

    await tester.tap(find.text('Worked for 12s'));
    await tester.pumpAndSettle();
    expect(find.text('Terminal'), findsNWidgets(2));
    expect(find.text('echo hi'), findsOneWidget);
    expect(find.text('3s'), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget);
    expect(find.textContaining('The user wants the output'), findsOneWidget);
    expect(find.text('T3'), findsNothing);
    expect(find.textContaining('tool calls'), findsNothing);
    line = tester.getSemantics(find.byKey(const ValueKey('work-line')));
    expect(line, isSemantics(isExpanded: true, onTapHint: 'collapse'));

    // Each tool row is its own focusable node for screen readers.
    expect(
      find.bySemanticsLabel('Terminal, echo hi, done, 3 seconds'),
      findsOneWidget,
    );
    await tester.tap(find.text('echo hi'));
    await tester.pumpAndSettle();
    expect(find.text('INPUT'), findsOneWidget);
    expect(find.text('OUTPUT'), findsOneWidget);
    expect(find.byTooltip('Copy input'), findsOneWidget);
    expect(find.byTooltip('Copy output'), findsOneWidget);

    // The failed tool: exit status and tinted output.
    await tester.tap(find.text('cat /nope'));
    await tester.pumpAndSettle();
    expect(find.text('exit 1'), findsOneWidget);
    final err = tester.widget<SelectableText>(
      find.widgetWithText(
        SelectableText,
        'cat: /nope: No such file or directory',
      ),
    );
    expect(err.style!.color, isNot(equals(err.style!.color!.withAlpha(0))));

    // Copy puts the full text on the clipboard.
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    await tester.tap(find.byTooltip('Copy input').first);
    expect(copied, 'echo hi');
  });

  testWidgets('long output is cut with Show more', (tester) async {
    phoneSize(tester);
    final long = List.generate(40, (i) => 'line $i').join('\n');
    await tester.pumpWidget(
      reply(_reply(text: 'Done.'), [
        _tool('s1', end: 2000, label: 'seq 40', output: long),
      ]),
    );
    await tester.tap(find.text('Worked for 2s'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('seq 40'));
    await tester.pumpAndSettle();
    expect(find.text('Show more'), findsOneWidget);
    expect(find.textContaining('line 39'), findsNothing);
    await tester.tap(find.text('Show more'));
    await tester.pumpAndSettle();
    expect(find.textContaining('line 39'), findsOneWidget);
    expect(find.text('Show less'), findsOneWidget);
  });

  testWidgets('details: false rows show the preview and do not open', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(
      reply(_reply(text: 'ok'), [
        _tool(
          's1',
          end: 1000,
          label: 'weather',
          name: 'web_search',
          details: false,
        ),
        _tool('s2', start: 1000, end: 2000, output: 'hi'),
      ]),
    );
    await tester.tap(find.text('Worked for 2s'));
    await tester.pumpAndSettle();
    expect(find.text('weather'), findsOneWidget);
    // The line's chevron, plus one for the only row with details.
    expect(find.byIcon(Icons.chevron_right_rounded), findsNWidgets(2));
    expect(
      tester.getSemantics(
        find.bySemanticsLabel('Web search, weather, done, 1 second'),
      ),
      isSemantics(isButton: false, hasTapAction: false),
    );
    await tester.tap(find.text('weather'));
    await tester.pumpAndSettle();
    expect(find.text('INPUT'), findsNothing);
    expect(find.text('OUTPUT'), findsNothing);
  });

  testWidgets('a running tool with details opens before its output arrives', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(
      reply(_reply(streaming: true), [
        _tool(
          's1',
          state: StepPhase.running,
          start: 10000,
          input: {'command': 'sleep 5'},
          label: 'sleep 5',
        ),
      ]),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Running terminal'), findsOneWidget);
    // Two pumps: the first starts the height animation, the second ends
    // it (pumpAndSettle would wait on the shimmer forever).
    await tester.tap(find.text('Running terminal'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('sleep 5'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('INPUT'), findsOneWidget);
    expect(find.text('Running…'), findsOneWidget);
  });

  testWidgets('reduced motion: no shimmer or ticking animation', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(
      reply(_reply(streaming: true), const [], reduce: true),
    );
    await tester.pump();
    expect(find.text('Thinking'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(reply(_reply(text: 'x'), _doneSteps, reduce: true));
    await tester.tap(find.text('Worked for 12s'));
    await tester.pump();
    expect(find.text('Terminal'), findsNWidgets(2), reason: 'opens at once');
  });

  testWidgets('200% text: no overflow, open timeline and tool', (tester) async {
    phoneSize(tester, size: const Size(360, 1600));
    await tester.pumpWidget(
      reply(_reply(text: 'It printed hi.'), _doneSteps, scale: 2),
    );
    await tester.tap(find.text('Worked for 12s'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('echo hi'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('OUTPUT'), findsOneWidget);
  });

  for (final b in Brightness.values) {
    testWidgets('golden: timeline with an open tool (${b.name})', (
      tester,
    ) async {
      phoneSize(tester, size: const Size(412, 760));
      await tester.pumpWidget(
        reply(_reply(text: 'It printed **hi**.'), _doneSteps, brightness: b),
      );
      await tester.tap(find.text('Worked for 12s'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('echo hi'));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/work_timeline_${b.name}.png'),
      );
    });

    testWidgets('golden: glimpse and settled line (${b.name})', (tester) async {
      phoneSize(tester, size: const Size(412, 260));
      await tester.pumpWidget(
        themed(
          Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  WorkLine(
                    steps: [_tool('s1', state: StepPhase.running)],
                    working: true,
                    now: () => _at(2000),
                  ),
                  const SizedBox(height: 24),
                  WorkLine(
                    steps: _doneSteps,
                    working: false,
                    replyStart: _t0,
                    now: () => _at(13000),
                  ),
                ],
              ),
            ),
          ),
          brightness: b,
          reduce: true,
        ),
      );
      await tester.pump();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/work_line_${b.name}.png'),
      );
    });
  }
}
