import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/ui/interactive/html_view.dart';
import 'package:tove_chat/src/ui/interactive/interactive.dart';
import 'package:tove_chat/src/ui/interactive/ui_model.dart'
    show UiElement, UiTone;
import 'package:tove_chat/src/ui/markdown/hermes_markdown.dart';
import 'package:tove_chat/src/ui/thread/messages.dart';

import '../markdown/golden_harness.dart' show loadReplyFonts;
import 'dashboard_html_fixtures.dart';
import 'round3_fixtures.dart';

List<String> _blocks(String reply) => [
  for (final m in RegExp(r'```hermes-ui\n([\s\S]*?)\n```').allMatches(reply))
    m[1]!,
];

UiElement _parse(Map<String, Object?> m) {
  final r = parseHermesUi(jsonEncode({'v': 1, ...m}));
  expect(r.ok, isTrue, reason: r.error);
  return r.element!;
}

String? _error(Map<String, Object?> m) =>
    parseHermesUi(jsonEncode({'v': 1, ...m})).error;

/// Every element in a sanitised tree, depth first.
Iterable<HElement> _all(List<HNode> nodes) sync* {
  for (final n in nodes) {
    if (n is HElement) {
      yield n;
      yield* _all(n.children);
    }
  }
}

void main() {
  group('dashboard parse', () {
    test('every block of the health reply parses', () {
      for (final b in _blocks(healthReply)) {
        expect(parseHermesUi(b).ok, isTrue, reason: parseHermesUi(b).error);
      }
    });

    test('states and their aliases; numbers become short text', () {
      final s = _parse({
        'type': 'services',
        'items': [
          {'name': 'A', 'state': 'up', 'latency': 38},
          {'name': 'B', 'state': 'degraded', 'latency': 12.5},
          {'name': 'C', 'state': 'offline'},
          {'name': 'D'},
        ],
      }) as UiServices;
      expect(s.items.map((x) => x.state), [
        UiTone.good,
        UiTone.warn,
        UiTone.bad,
        UiTone.neutral,
      ]);
      expect(s.items[0].latency, '38 ms');
      expect(s.items[1].latency, '12.5 ms');
      expect(s.items[2].followUp, 'Why is C down?');
      expect(s.items[1].followUp, 'What is wrong with B?');
      expect(
        _error({
          'type': 'services',
          'items': [
            {'name': 'A', 'state': 'sideways'},
          ],
        }),
        contains('unknown state'),
      );
    });

    test('gauges: max must be positive; % by default', () {
      final g = _parse({
        'type': 'gauges',
        'items': [
          {'label': 'CPU', 'value': 23},
          {'label': 'Fans', 'value': 3, 'max': 4, 'unit': ''},
        ],
      }) as UiGauges;
      expect(g.items.first.unit, '%');
      expect(g.items.last.fraction, 0.75);
      expect(
        _error({
          'type': 'gauges',
          'items': [
            {'label': 'X', 'value': 1, 'max': 0},
          ],
        }),
        contains('positive'),
      );
    });

    test('chart: kinds, 1–3 series, numbers only, at most 60 points', () {
      final c = _parse({
        'type': 'chart',
        'kind': 'bar',
        'series': [
          {
            'name': 'a',
            'values': [1, 2, 3],
          },
        ],
      }) as UiChart;
      expect(c.kind, UiChartKind.bar);
      expect(c.plainText, contains('from 1 to 3'));
      expect(
        _error({
          'type': 'chart',
          'kind': 'pie',
          'series': [
            {
              'values': [1],
            },
          ],
        }),
        contains('kind'),
      );
      expect(
        _error({
          'type': 'chart',
          'series': [
            {
              'values': ['1'],
            },
          ],
        }),
        contains('numbers'),
      );
      expect(
        _error({
          'type': 'chart',
          'series': [
            {'values': List.filled(61, 1)},
          ],
        }),
        isNotNull,
      );
    });

    test('alerts: only send actions, at most two', () {
      final a = _parse({
        'type': 'alerts',
        'items': [
          {
            'tone': 'warn',
            'title': 'Slow',
            'actions': [
              {'label': 'Restart?', 'send': 'Restart it.'},
            ],
          },
        ],
      }) as UiAlerts;
      expect(a.items.single.actions.single.action.send, 'Restart it.');
      expect(
        _error({
          'type': 'alerts',
          'items': [
            {
              'title': 'x',
              'actions': [
                {'label': 'Go', 'link': 'https://example.com'},
              ],
            },
          ],
        }),
        isNotNull,
      );
    });
  });

  group('sanitiser', () {
    test('drops script, style, iframe, forms, svg with their content', () {
      final doc = sanitizeHtml(
        '<p>Hi</p><script>alert(1)</script><style>p{color:red}</style>'
        '<iframe src="https://evil.example"></iframe>'
        '<form action="/x"><input name="p"><button>Go</button></form>'
        '<svg onload="x()"><text>svg</text></svg><object data="x"></object>',
      );
      expect(doc.plainText, 'Hi');
      final tags = _all(doc.nodes).map((e) => e.tag).toSet();
      expect(tags, {'p'});
    });

    test('drops event handlers and every other attribute', () {
      final doc = sanitizeHtml(
        '<div onclick="steal()" onmouseover="x()" class="c" id="i" '
        'data-x="1"><a href="https://example.com" onclick="steal()" '
        'target="_blank">ok</a><img src="https://img.example.com/a.png" '
        'onerror="x()" alt="A"></div>',
      );
      for (final e in _all(doc.nodes)) {
        expect(
          e.attrs.keys.every((k) => const {'href', 'src', 'alt'}.contains(k)),
          isTrue,
          reason: '${e.tag}: ${e.attrs}',
        );
      }
      expect(doc.dropped, greaterThanOrEqualTo(7));
    });

    test('javascript:, data: and other schemes never survive', () {
      final doc = sanitizeHtml(
        '<a href="javascript:alert(1)">a</a>'
        '<a href=" JaVaScRiPt:alert(1)">b</a>'
        '<a href="data:text/html,<script>1</script>">c</a>'
        '<a href="vbscript:x">d</a><a href="/relative">e</a>'
        '<a href="mailto:me@example.com">f</a>'
        '<img src="javascript:x()"><img src="data:image/png;base64,AAAA">'
        '<img src="//cdn.example.com/x.png">',
      );
      final links = _all(doc.nodes).where((e) => e.tag == 'a').toList();
      expect(links.map((e) => e.attrs['href']), [
        null,
        null,
        null,
        null,
        null,
        'mailto:me@example.com',
      ]);
      expect(_all(doc.nodes).where((e) => e.tag == 'img'), isEmpty);
      final md = flowMarkdown(doc.nodes);
      expect(md, isNot(contains('javascript')));
      expect(md, isNot(contains('data:')));
    });

    test('CSS: url(), expression() and imports are ignored; colours and '
        'backgrounds are not kept', () {
      final s = parseCss(
        'background:url(https://evil.example/x.png);'
        'width:expression(alert(1));color:#ff0000;'
        'background-color:#00ff00;font-family:Comic Sans;'
        'position:fixed;padding:8px;gap:500px',
      );
      expect(s.dot, isNull, reason: 'not an empty dot element');
      expect(s.padding, const EdgeInsets.all(8));
      expect(s.gap, HtmlLimits.maxSpace, reason: 'clamped');
      expect(parseCss('margin:1px\\ 2px').margin, EdgeInsets.zero);
    });

    test('status dots: a tiny empty element with a background', () {
      final doc = sanitizeHtml(
        '<span style="display:inline-block;width:8px;height:8px;'
        'border-radius:50%;background:#22c55e"></span>'
        '<span style="background:#ef4444;width:200px;height:8px"></span>',
      );
      final spans = _all(doc.nodes).toList();
      expect(spans.first.style.dot, UiTone.good);
      expect(spans.last.style.dot, isNull, reason: 'too large for a dot');
    });

    test('unknown tags are unwrapped; text is markdown-escaped', () {
      final doc = sanitizeHtml(
        '<p><blink>**not bold** [x](javascript:y) <u>#1</u></blink></p>',
      );
      final md = flowMarkdown(doc.nodes);
      expect(md, r'\*\*not bold\*\* \[x\](javascript:y) \#1');
    });

    test('limits: depth, node count, images and size', () {
      final deep = '${'<div>' * 40}deep${'</div>' * 40}';
      expect(sanitizeHtml(deep).truncated, isTrue);
      final many = List.filled(800, '<p>x</p>').join();
      final doc = sanitizeHtml(many);
      expect(doc.truncated, isTrue);
      expect(_all(doc.nodes).length, lessThanOrEqualTo(HtmlLimits.maxNodes));
      final imgs = List.filled(
        12,
        '<img src="https://img.example.com/a.png">',
      ).join();
      expect(_all(sanitizeHtml(imgs).nodes).length, HtmlLimits.maxImages);
      expect(sanitizeHtml('<p>${'a' * 40000}</p>').truncated, isTrue);
    });

    test('flow content becomes the reply’s own markdown', () {
      final md = flowMarkdown(
        sanitizeHtml(
          '<h2>Title</h2><p>One <strong>two</strong> <em>three</em></p>'
          '<ul><li>a<ul><li>b</li></ul></li></ul><ol><li>c</li></ol>'
          '<table><tr><th>K</th><th>V</th></tr><tr><td>x|y</td><td>1</td></tr>'
          '</table><hr><p><a href="https://example.com/a b">link</a></p>'
          '<details><summary>More</summary><p>Body</p></details>',
        ).nodes,
      );
      expect(
        md,
        '## Title\n\n'
        'One **two** *three*\n\n'
        '- a\n  - b\n\n'
        '1. c\n\n'
        '| K | V |\n| --- | --- |\n| x\\|y | 1 |\n\n'
        '---\n\n'
        '[link](https://example.com/a%20b)\n\n'
        '<details><summary>More</summary>\n\nBody\n\n</details>',
      );
    });

    test('the company example keeps its link but loses onclick, the '
        'script and the green background', () {
      final doc = sanitizeHtml(companyHtml);
      expect(doc.plainText, isNot(contains('alert')));
      final a = _all(doc.nodes).firstWhere((e) => e.tag == 'a');
      expect(a.attrs, {'href': 'https://example.com/investors'});
      expect(_all(doc.nodes).where((e) => e.tag == 'img'), hasLength(3));
    });

    test('text colours map to theme tones, inherited like CSS; grey, '
        'white and backgrounds do not colour text', () {
      String md(String h) => flowMarkdown(sanitizeHtml(h).nodes);
      expect(
        md('<p style="color:#dc2626">Down</p>'),
        '<tone-bad>Down</tone-bad>',
      );
      expect(
        md('<div style="color:green"><p>Up <strong>now</strong></p></div>'),
        '<tone-good>Up</tone-good> **<tone-good>now</tone-good>**',
      );
      expect(
        md('<p style="color:#f59e0b">Slow</p>'),
        '<tone-warn>Slow</tone-warn>',
      );
      expect(
        md('<p style="color:rgb(37,99,235)">Info</p>'),
        '<tone-accent>Info</tone-accent>',
      );
      expect(md('<p style="color:#888">Grey</p>'), 'Grey');
      expect(md('<p style="color:#fff;background:#dc2626">White</p>'), 'White');
      expect(
        md('<p style="color:red"><span style="color:#999">x</span> y</p>'),
        '<tone-bad>x</tone-bad> <tone-bad>y</tone-bad>',
        reason: 'grey maps to no tone, so the parent colour stays',
      );
      // Text can never forge a tone tag.
      expect(
        md('<p>&lt;tone-bad&gt;x&lt;/tone-bad&gt;</p>'),
        r'\<tone-bad\>x\</tone-bad\>',
      );
    });

    test('read aloud: hermes-html fences read as their text', () {
      final text = hermesUiPlainText(companyReply);
      expect(text, contains('NVIDIA Corporation'));
      expect(text, isNot(contains('<')));
    });
  });

  group('widgets', () {
    setUpAll(loadReplyFonts);

    Future<List<String>> pumpReply(
      WidgetTester tester,
      String text, {
      bool enabled = true,
    }) async {
      final sent = <String>[];
      tester.view.physicalSize = const Size(412, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        r3Frame(
          HermesUiScope(
            onSend: sent.add,
            enabled: enabled,
            child: AssistantMessage(
              message: reply(text),
              onRetry: () {},
              onDelete: () {},
            ),
          ),
          brightness: Brightness.dark,
          desktop: false,
        ),
      );
      await tester.pump(const Duration(milliseconds: 900));
      await settleImages(tester);
      expect(tester.takeException(), isNull);
      return sent;
    }

    testWidgets('a service row sends its follow-up; an alert button sends '
        'its text; nothing runs by itself', (tester) async {
      final sent = await pumpReply(tester, healthReply);
      await tester.tap(find.text('Seerr'));
      await tester.tap(find.text('Backups'));
      await tester.tap(find.text('Find big files'));
      expect(sent, [
        'Restart Seerr?',
        'Why is Backups down?',
        'Which folders on /srv are the biggest?',
      ]);
    });

    testWidgets('while sending is off, rows and buttons do nothing', (
      tester,
    ) async {
      final sent = await pumpReply(tester, healthReply, enabled: false);
      await tester.tap(find.text('Seerr'), warnIfMissed: false);
      await tester.tap(find.text('Find big files'), warnIfMissed: false);
      expect(sent, isEmpty);
    });

    testWidgets('screen readers hear states, values and the chart summary', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpReply(tester, healthReply);
      expect(
        find.bySemanticsLabel(RegExp(r'^Seerr, degraded, 910 ms')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel(RegExp(r'^Disk /srv: 91%')), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp(r'^Line chart\. CPU, last 12 hours')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('html: links open through the confirm sheet, never directly', (
      tester,
    ) async {
      await pumpReply(tester, companyReply);
      expect(find.text('alert(1)'), findsNothing);
      await tester.tap(
        find.textContaining('investor site', findRichText: true),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining('example.com'), findsWidgets);
    });

    testWidgets('coloured html text uses the theme’s success, warning and '
        'danger colours', (tester) async {
      await pumpReply(tester, mixedReply);
      final context = tester.element(find.byType(AssistantMessage));
      final s = MarkdownStyle.of(context);
      Set<Color?> colorsOf(String word) {
        final found = <Color?>{};
        for (final e in find.byType(RichText).evaluate()) {
          (e.widget as RichText).text.visitChildren((span) {
            if (span is TextSpan && span.text == word) {
              found.add(span.style?.color);
            }
            return true;
          });
        }
        return found;
      }

      expect(colorsOf('healthy'), contains(s.success));
      expect(colorsOf('78% full'), contains(s.warning));
      expect(colorsOf('none today'), contains(s.danger));
      expect(colorsOf('healthy'), isNot(contains(s.text)));
    });

    testWidgets('200% text: dashboard and html replies do not overflow', (
      tester,
    ) async {
      for (final r in [healthReply, companyReply, mixedReply]) {
        tester.view.physicalSize = const Size(412, 4000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          r3Frame(
            HermesUiScope(
              onSend: (_) {},
              child: AssistantMessage(
                message: reply(r),
                onRetry: () {},
                onDelete: () {},
              ),
            ),
            brightness: Brightness.light,
            desktop: false,
            textScale: 2,
          ),
        );
        await tester.pump(const Duration(milliseconds: 900));
        await settleImages(tester);
        expect(tester.takeException(), isNull, reason: r.substring(0, 30));
      }
    });
  });

  group('goldens', () {
    setUpAll(loadReplyFonts);
    final cases = {
      'health': (healthReply, 1900.0),
      'html_company': (companyReply, 1350.0),
      'mixed': (mixedReply, 1300.0),
    };
    for (final MapEntry(key: name, value: (text, height)) in cases.entries) {
      for (final b in Brightness.values) {
        testWidgets('golden ${name}_${b.name}', (tester) async {
          tester.view.physicalSize = Size(412, height);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            r3Frame(
              HermesUiScope(
                onSend: (_) {},
                child: AssistantMessage(
                  message: reply(text),
                  onRetry: () {},
                  onDelete: () {},
                ),
              ),
              brightness: b,
              desktop: false,
            ),
          );
          await tester.pump(const Duration(milliseconds: 900));
          await settleImages(tester);
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byKey(goldenKey),
            matchesGoldenFile('goldens/r4_${name}_${b.name}.png'),
          );
        });
      }
    }
  });
}
