import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/interactive/interactive.dart';
import 'package:tove_chat/src/ui/markdown/hermes_markdown.dart';
import 'package:material_ui/material_ui.dart';

import '../markdown/helpers.dart';

String ui(String json) => '```hermes-ui\n$json\n```';

const oneOf =
    '{"v":1,"type":"options","prompt":"Pick one","options":['
    '{"label":"Alpha","send":"I pick alpha."},{"label":"Beta","send":"I pick beta."}],"other":true}';

void main() {
  final sent = <String>[];
  final opened = <String>[];
  final copied = <String>[];
  var focused = 0;

  setUp(() {
    sent.clear();
    opened.clear();
    copied.clear();
    focused = 0;
  });

  Widget scoped(Widget child, {String? next}) => HermesUiScope(
    onSend: sent.add,
    onOpenLink: opened.add,
    onCopy: copied.add,
    onFocusComposer: () => focused++,
    nextUserMessage: next,
    child: child,
  );

  Future<void> show(WidgetTester tester, String md, {String? next}) async {
    setSurface(tester, 412, 1400);
    await tester.pumpWidget(
      host(scoped(HermesMarkdown(text: md), next: next), reduceSetting: true),
    );
    await tester.pump();
  }

  double opacityOf(WidgetTester tester, String label) => tester
      .widget<AnimatedOpacity>(
        find
            .ancestor(
              of: find.text(label),
              matching: find.byType(AnimatedOpacity),
            )
            .first,
      )
      .opacity;

  testWidgets('options: one tap sends the visible text, then locks', (
    tester,
  ) async {
    await show(tester, ui(oneOf));
    expect(find.text('Pick one'), findsOneWidget);
    expect(find.textContaining('"type"'), findsNothing);
    await tester.tap(find.text('Beta'));
    await tester.pump();
    expect(sent, ['I pick beta.']);
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    expect(sent, ['I pick beta.'], reason: 'locked after answering');
    expect(opacityOf(tester, 'Alpha'), 0.4);
    expect(opacityOf(tester, 'Beta'), 1);
    expect(find.text('Other…'), findsNothing);
  });

  testWidgets('options: a later user message locks and marks the choice', (
    tester,
  ) async {
    await show(tester, ui(oneOf), next: 'I pick alpha.');
    await tester.tap(find.text('Beta'));
    expect(sent, isEmpty);
    expect(opacityOf(tester, 'Beta'), 0.4);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });

  testWidgets('options: Other… focuses the composer', (tester) async {
    await show(tester, ui(oneOf));
    await tester.tap(find.text('Other…'));
    expect(focused, 1);
  });

  testWidgets('options: many toggles, then Send joins the labels', (
    tester,
  ) async {
    await show(
      tester,
      ui(
        '{"v":1,"type":"options","select":"many","options":'
        '[{"label":"Disks"},{"label":"Backups"},{"label":"Certs"}]}',
      ),
    );
    await tester.tap(find.text('Send'));
    expect(sent, isEmpty, reason: 'disabled until something is chosen');
    await tester.tap(find.text('Certs'));
    await tester.tap(find.text('Disks'));
    // The chip row re-wraps; the block settles on the next frame.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(sent, ['Disks, Certs']);
  });

  testWidgets('without onSend, send controls are disabled', (tester) async {
    setSurface(tester, 412);
    await tester.pumpWidget(host(HermesMarkdown(text: ui(oneOf))));
    await tester.pump();
    await tester.tap(find.text('Alpha'));
    expect(sent, isEmpty);
  });

  testWidgets('actions: send once, link through the callback, copy', (
    tester,
  ) async {
    await show(
      tester,
      ui(
        '{"v":1,"type":"actions","items":['
        '{"label":"Run","style":"primary","action":{"send":"Run it now."}},'
        '{"label":"Docs","action":{"link":"https://example.com/docs"}},'
        '{"label":"Copy cmd","action":{"copy":"df -h"}}]}',
      ),
    );
    expect(find.byIcon(Icons.north_east_rounded), findsOneWidget);
    await tester.tap(find.text('Run'));
    await tester.tap(find.text('Run'));
    await tester.tap(find.text('Docs'));
    await tester.tap(find.text('Copy cmd'));
    await tester.pump();
    expect(sent, ['Run it now.']);
    expect(opened, ['https://example.com/docs']);
    expect(copied, ['df -h']);
    expect(find.byIcon(Icons.check_rounded), findsWidgets);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('default copy goes to the clipboard; default link confirms', (
    tester,
  ) async {
    final clip = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clip.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    setSurface(tester, 412);
    await tester.pumpWidget(
      host(
        HermesMarkdown(
          text: ui(
            '{"v":1,"type":"actions","items":['
            '{"label":"Copy","action":{"copy":"abc"}},'
            '{"label":"Site","action":{"link":"https://www.example.org/x"}}]}',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(clip, ['abc']);
    await tester.tap(find.text('Site'));
    await tester.pumpAndSettle();
    expect(find.text('Open link?'), findsOneWidget);
    expect(find.text('example.org'), findsOneWidget);
  });

  testWidgets('calc: dragging the slider recomputes the cards at once', (
    tester,
  ) async {
    await show(
      tester,
      ui(
        '{"v":1,"type":"calc","inputs":[{"id":"minutes","label":"Session length",'
        '"min":10,"max":600,"step":10,"value":60,"format":"{} minutes"}],'
        '"outputs":[{"label":"Base","expr":"minutes * 0.05","format":"currency:USD"},'
        '{"label":"Ratio","expr":"1 / (minutes - minutes)"}]}',
      ),
    );
    expect(find.text('60 minutes'), findsOneWidget);
    expect(find.text(r'$3.00'), findsOneWidget);
    expect(find.text('—'), findsOneWidget, reason: 'division by zero');
    final slider = find.byType(CustomPaint).last;
    final box = tester.getRect(
      find.ancestor(of: slider, matching: find.byType(GestureDetector)).first,
    );
    // 12 dp inset on each side; 190 is (190 - 10) / 590 of the way.
    final x = box.left + 12 + (box.width - 24) * (180 / 590);
    await tester.tapAt(Offset(x, box.center.dy));
    await tester.pump();
    expect(find.text('190 minutes'), findsOneWidget);
    expect(find.text(r'$9.50'), findsOneWidget);
    await tester.dragFrom(
      Offset(x, box.center.dy),
      Offset((box.width - 24) * (280 / 590), 0),
    );
    await tester.pump();
    expect(find.text('470 minutes'), findsOneWidget);
    expect(find.text(r'$23.50'), findsOneWidget);
  });

  testWidgets('calc: the slider is an accessible slider', (tester) async {
    final sem = tester.ensureSemantics();
    await show(
      tester,
      ui(
        '{"v":1,"type":"calc","inputs":[{"id":"n","label":"Count","min":0,"max":10,"value":5}],'
        '"outputs":[{"label":"Double","expr":"n * 2"}]}',
      ),
    );
    final node = tester.getSemantics(find.bySemanticsLabel('Count').last);
    expect(node.value, '5');
    expect(node.getSemanticsData().hasAction(SemanticsAction.increase), isTrue);
    tester
        .widget<Semantics>(
          find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.slider == true,
          ),
        )
        .properties
        .onIncrease!();
    await tester.pump();
    expect(find.text('12'), findsOneWidget);
    sem.dispose();
  });

  testWidgets('details expand; callouts and cards render', (tester) async {
    await show(
      tester,
      '${ui('{"v":1,"type":"details","title":"Method","body":"Hidden **body**."}')}\n\n'
      '${ui('{"v":1,"type":"callout","tone":"warning","title":"Careful","body":"Text."}')}\n\n'
      '${ui('{"v":1,"type":"cards","items":[{"label":"Disk","value":"71 %"}]}')}',
    );
    expect(find.textContaining('Hidden'), findsNothing);
    await tester.tap(find.text('Method'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Hidden'), findsOneWidget);
    expect(find.text('Careful'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.text('71 %'), findsOneWidget);
  });

  testWidgets('invalid, future and nested blocks fall back, raw text inside', (
    tester,
  ) async {
    await show(
      tester,
      '${ui('{"v":1,"type":"options","options":[}')}\n\n'
      '${ui('{"v":2,"type":"cards"}')}\n\n'
      '${ui('{"v":1,"type":"details","title":"Outer","open":true,"body":"```hermes-ui\\n{\\"v\\":1,\\"type\\":\\"callout\\",\\"body\\":\\"x\\"}\\n```"}')}',
    );
    expect(
      find.text("Interactive content couldn't be shown"),
      findsNWidgets(3),
    );
    // The raw text is inside, collapsed.
    expect(find.textContaining('"options":[}'), findsNothing);
    await tester.tap(find.text("Interactive content couldn't be shown").first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('"options":[}'), findsOneWidget);
  });

  testWidgets('more than six blocks in a message fall back', (tester) async {
    final block = ui(
      '{"v":1,"type":"cards","items":[{"label":"L","value":"V"}]}',
    );
    await show(tester, List.filled(7, block).join('\n\n'));
    expect(find.text('V'), findsNWidgets(6));
    expect(find.text("Interactive content couldn't be shown"), findsOneWidget);
  });

  testWidgets('suggestions are not rendered in place', (tester) async {
    await show(
      tester,
      'Done.\n\n${ui('{"v":1,"type":"suggestions","items":["Next step"]}')}',
    );
    expect(find.text('Next step'), findsNothing);
    final extras = HermesReplyExtras.maybe(
      'Done.\n\n${ui('{"v":1,"type":"suggestions","items":["Next step"]}')}',
      streaming: false,
      onSend: sent.add,
    );
    expect(extras, isNotNull);
    expect(
      HermesReplyExtras.maybe('x', streaming: false, onSend: sent.add),
      isNull,
    );
    await tester.pumpWidget(host(extras!, reduceSetting: true));
    await tester.tap(find.text('Next step'));
    expect(sent, ['Next step']);
  });

  testWidgets('a streaming block shows a placeholder, never raw JSON', (
    tester,
  ) async {
    setSurface(tester, 412);
    final source = ValueNotifier(
      'Here:\n\n```hermes-ui\n{"v":1,"type":"calc","inputs":[{"id":"m"',
    );
    await tester.pumpWidget(
      host(
        scoped(
          StreamingMarkdown.listenable(source: source, smoothReveal: false),
        ),
        reduceSetting: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Preparing calculator…'), findsOneWidget);
    expect(find.textContaining('"inputs"'), findsNothing);
    // Half-typed info string: already the placeholder, not a code block.
    source.value = 'Here:\n\n```herm';
    await tester.pump(const Duration(milliseconds: 300));
    source.value = 'Here:\n\n```hermes-ui\n{"v":1,"type":"cards","items":[{"label":"L","value":"V"}]}\n```\n\nAfter.';
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('V'), findsOneWidget);
    expect(find.textContaining('Preparing'), findsNothing);
  });

  testWidgets('a broken block shows the fallback once the stream ends', (
    tester,
  ) async {
    setSurface(tester, 412);
    Widget w(bool streaming) => host(
      StreamingMarkdown(
        text: '```hermes-ui\n{"v":1,"type":"cards","items":[',
        isStreaming: streaming,
        smoothReveal: false,
      ),
      reduceSetting: true,
    );
    await tester.pumpWidget(w(true));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Preparing…'), findsOneWidget);
    await tester.pumpWidget(w(false));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text("Interactive content couldn't be shown"), findsOneWidget);
  });

  group('citations', () {
    const reply =
        'Prices are \$32 and \$64.[^1][^2] Mini is cheaper.[^3]\n\n'
        '[^1]: [Pricing](https://www.example.com/pricing) — Example Docs\n'
        '[^2]: [Guide](https://platform.example.org/g)\n'
        '[^3]: https://news.example.net/x Launch notes';

    testWidgets('consecutive references become one chip; defs are hidden', (
      tester,
    ) async {
      await show(tester, reply);
      // The chip names the publisher when the definition gives one (round
      // 3, as in the reference), else the host.
      expect(find.text('Example Docs'), findsOneWidget);
      expect(find.text(' +1'), findsOneWidget);
      expect(find.text('news.example.net'), findsOneWidget);
      expect(visibleText(tester), isNot(contains('[^')));
      expect(visibleText(tester), isNot(contains('Pricing')));
    });

    testWidgets('a chip opens the Sources sheet; a row opens the link', (
      tester,
    ) async {
      final taps = <String>[];
      setSurface(tester, 412);
      await tester.pumpWidget(
        host(HermesMarkdown(text: reply, onLinkTap: taps.add)),
      );
      await tester.pump();
      await tester.tap(find.text('Example Docs'));
      await tester.pumpAndSettle();
      expect(find.text('Sources'), findsOneWidget);
      expect(find.text('Pricing'), findsOneWidget);
      expect(find.text('example.com · Example Docs'), findsOneWidget);
      expect(find.text('Guide'), findsOneWidget);
      await tester.tap(find.text('Guide'));
      await tester.pumpAndSettle();
      expect(taps, ['https://platform.example.org/g']);
    });

    testWidgets('while streaming, a chip waits for its definition', (
      tester,
    ) async {
      setSurface(tester, 412);
      final source = ValueNotifier('Fact one.[^1]\n\nMore text.');
      await tester.pumpWidget(
        host(StreamingMarkdown.listenable(source: source, smoothReveal: false)),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Source'), findsOneWidget);
      // The first block is final now; the definition still updates it.
      source.value =
          '${source.value}\n\n[^1]: [Doc](https://docs.example.dev/a)';
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Source'), findsNothing);
      expect(find.text('docs.example.dev'), findsOneWidget);
    });
  });

  testWidgets('<details> HTML renders collapsed; other tags show as text', (
    tester,
  ) async {
    await show(
      tester,
      '<details>\n<summary>Why</summary>\n\nBecause **reasons**.\n\nTwo paras.\n</details>\n\n'
      'Then <script>alert(1)</script> and <small>fine print</small>.',
    );
    expect(find.text('Why'), findsOneWidget);
    expect(find.textContaining('Because'), findsNothing);
    expect(visibleText(tester), contains('<script>alert(1)</script>'));
    expect(visibleText(tester), isNot(contains('<small>')));
    await tester.tap(find.text('Why'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Because'), findsOneWidget);
    expect(find.textContaining('Two paras.'), findsOneWidget);
  });

  testWidgets('200 % text: every element lays out without overflow', (
    tester,
  ) async {
    setSurface(tester, 360, 3000);
    await tester.pumpWidget(
      host(
        scoped(
          HermesMarkdown(
            text: [
              ui(oneOf),
              ui(
                '{"v":1,"type":"actions","items":[{"label":"Open the very long pricing page","action":{"link":"https://e.com"}}]}',
              ),
              ui(
                '{"v":1,"type":"cards","items":[{"label":"A long label for a card","value":"\$1,234,567.89","sub":"sub"},{"label":"B","value":"Variable"}]}',
              ),
              ui(
                '{"v":1,"type":"calc","inputs":[{"id":"m","label":"Session length in minutes","min":0,"max":600,"value":190,"format":"{} minutes"},{"id":"s","kind":"segmented","label":"Mode","value":1,"options":[{"label":"Economy","value":1},{"label":"Premium","value":2}]}],"outputs":[{"label":"Cost","expr":"m * s","format":"currency:USD"}]}',
              ),
              ui(
                '{"v":1,"type":"callout","tone":"tip","title":"A tip","body":"Some body text that wraps."}',
              ),
            ].join('\n\n'),
          ),
        ),
        textScale: 2,
        reduceSetting: true,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });
}
