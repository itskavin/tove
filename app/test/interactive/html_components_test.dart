// Round 7: hermes-html components (cards, stats, badges, bars, timeline,
// pros/cons, callouts, tabs, galleries, spec sheets, accordions, buttons)
// and the plain-content fallback.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/ui/interactive/html_view.dart';
import 'package:tove_chat/src/ui/interactive/interactive.dart';
import 'package:tove_chat/src/ui/interactive/ui_model.dart' show UiTone;
import 'package:tove_chat/src/ui/markdown/hermes_markdown.dart';
import 'package:tove_chat/src/ui/markdown/md_images.dart' show MdImageViewer;
import 'package:tove_chat/src/ui/thread/messages.dart';

import '../markdown/golden_harness.dart' show loadReplyFonts;
import 'round3_fixtures.dart';

/// A rich comparison: hero, image cards with badges, stats, paired
/// pros/cons, bars, a spec sheet, a callout and follow-up buttons. Every
/// address is an example domain; the products are made up.
const compareHtml = '''<div class="hero">
  <h3>Aster 7 Pro vs Brio 11 Pro <span class="badge info">2026</span></h3>
  <p class="meta">Flagship phones · prices at launch</p>
</div>
<div class="cards cols-2">
  <div><img src="https://img.example.com/aster.jpg" alt="Aster 7 Pro"><h4>Aster 7 Pro <span class="badge good">Best video</span></h4><p class="meta">From \$1,099 · A19 chip</p><p>Fastest chip and the best video tools.</p></div>
  <div><img src="https://img.example.com/brio.jpg" alt="Brio 11 Pro"><h4>Brio 11 Pro <span class="badge info">Best AI</span></h4><p class="meta">From \$999 · G6 chip</p><p>Smartest camera software, 7 years of updates.</p></div>
</div>
<div class="stats">
  <div><span class="value">\$100</span><span class="label">Price gap</span></div>
  <div><span class="value good">7 yrs</span><span class="label">Brio updates</span></div>
  <div><span class="value">48 MP</span><span class="label">Main cameras</span></div>
</div>
<ul class="pros"><li><strong>Aster:</strong> pro video, fast transfers</li><li>Better resale value</li></ul>
<ul class="cons"><li>Costs more</li><li>Slower charging</li></ul>
<h4>Battery</h4>
<div class="bar good" data-value="82">Brio endurance</div>
<div class="bar" data-value="74">Aster endurance</div>
<dl><dt>Display</dt><dd>6.3″ OLED, 120 Hz</dd><dt>Weight</dt><dd>199 g / 207 g</dd></dl>
<div class="callout tip"><h4>Pick by ecosystem</h4><p>If your laptop is an Aster, the phone fits better.</p></div>
<button data-send="Which has the better low-light camera?">Low-light camera?</button>
<button data-send="Show me deals on the Brio 11 Pro">Brio deals</button>''';

const compareReply =
    '''The Aster wins on video and ecosystem; the Brio on AI features and price.

```hermes-html
$compareHtml
```
''';

/// A trip plan: tabs per day with timelines, an accordion and a gallery.
const tripHtml = '''<div class="tabs">
  <section data-tab="Day 1">
    <ol class="timeline">
      <li><span class="time">9:00 AM</span><strong>Tea museum</strong><p>See how tea is rolled and dried.</p></li>
      <li class="good"><span class="time">12:30 PM</span><strong>Lunch by the lake</strong></li>
      <li><span class="time">3:00 PM</span><strong>Dam and boating</strong> <span class="badge warn">Book ahead</span></li>
    </ol>
  </section>
  <section data-tab="Day 2"><ol class="timeline"><li><span class="time">6:00 AM</span>Top Station sunrise</li><li><span class="time">11:00 AM</span>Spice garden walk</li></ol></section>
  <section data-tab="Day 3"><p>National park in the morning, then the drive back.</p></section>
</div>
<details><summary>Packing list</summary><ul><li>Light jacket</li><li>Rain cover</li></ul></details>
<div class="gallery"><img src="https://img.example.com/tea.jpg" alt="Tea estates"><img src="https://img.example.com/lake.jpg" alt="The lake"></div>''';

const tripReply =
    '''A relaxed three days in the hills.

```hermes-html
$tripHtml
```
''';

/// A lazy reply: bold and bullets in a styled box.
const plainHtml = '''<div style="border:1px solid #ddd;padding:16px;border-radius:12px;display:flex;flex-direction:column;gap:12px">
  <h3>Summary</h3>
  <p>TCP is <strong>reliable</strong>; UDP is <em>fast</em>.</p>
  <ul><li><strong>TCP:</strong> ordered</li><li><strong>UDP:</strong> no handshake</li></ul>
</div>''';

/// Every element in a sanitised tree, depth first.
Iterable<HElement> _all(List<HNode> nodes) sync* {
  for (final n in nodes) {
    if (n is HElement) {
      yield n;
      yield* _all(n.children);
    }
  }
}

HElement _first(String html, String tag) =>
    _all(sanitizeHtml(html).nodes).firstWhere((e) => e.tag == tag);

void main() {
  group('sanitiser: components', () {
    test('only known class names survive', () {
      final e = _first(
        '<div class="cards evil onclick x-y CARDS cols-3 bg-red-500">x</div>',
        'div',
      );
      expect(e.classes, {'cards', 'cols-3'});
      expect(e.style.display, HDisplay.grid);
      expect(e.style.columns, 3);
      expect(_first('<div class="carousel">x</div>', 'div').attrs, isEmpty);
    });

    test('a malicious data-send is only text; buttons keep nothing else', () {
      final b = _first(
        '<button data-send="javascript:alert(1)" onclick="steal()" '
            'formaction="https://evil.example" type="submit" '
            'href="https://evil.example">Go</button>',
        'button',
      );
      expect(b.attrs, {'data-send': 'javascript:alert(1)'});
      final weird = _first(
        '<button data-send="Yes\u202Eevil\u0007\nnow   please">x</button>',
        'button',
      );
      expect(weird.attrs['data-send'], 'Yes evil now please');
      final long = _first(
        '<button data-send="${'a' * 900}">x</button>',
        'button',
      );
      expect(long.attrs['data-send']!.length, HtmlLimits.maxSend);
      // Only buttons send; a link keeps its href and nothing else.
      final a = _first(
        '<a href="https://example.com" data-send="x">a</a>',
        'a',
      );
      expect(a.attrs, {'href': 'https://example.com'});
      expect(_first('<div data-send="x">d</div>', 'div').attrs, isEmpty);
      // A button with nothing to send is dropped with its text.
      expect(sanitizeHtml('<p>a</p><button>Do it</button>').plainText, 'a');
      expect(sanitizeHtml('<button data-send="  ">Go</button>').plainText, '');
    });

    test('a link button needs a safe href; otherwise it is plain text', () {
      final bad = _first(
        '<a class="button" href="javascript:alert(1)">Open</a>',
        'a',
      );
      expect(bad.attrs['href'], isNull);
      expect(isHtmlComponent(bad), isFalse);
      final ok = _first(
        '<a class="button" href="https://example.com/deal">Deal</a>',
        'a',
      );
      expect(isHtmlComponent(ok), isTrue);
    });

    test('tabs, bars and progress: labels cleaned, numbers required', () {
      final s = _first(
        '<div class="tabs"><section data-tab="  Day\n1 ${'x' * 60}">a</section></div>',
        'section',
      );
      expect(s.attrs['data-tab']!.length, lessThanOrEqualTo(40));
      expect(s.attrs['data-tab'], startsWith('Day 1 x'));
      expect(
        _first('<p data-tab="x">p</p>', 'p').attrs,
        isEmpty,
        reason: 'data-tab only on panes',
      );
      expect(
        _all(sanitizeHtml('<progress max="10"></progress>').nodes),
        isEmpty,
      );
      final p = _first('<progress value="3" max="5"></progress>', 'progress');
      expect(p.attrs, {'value': '3', 'max': '5'});
      final bar = _first('<div class="bar" data-value="abc">x</div>', 'div');
      expect(bar.attrs.containsKey('data-value'), isFalse);
      expect(isHtmlComponent(bar), isFalse, reason: 'no value: plain text');
    });

    test('adjacent pros and cons share a two-column grid', () {
      final doc = sanitizeHtml(
        '<ul class="cons"><li>a</li></ul>\n<ul class="pros"><li>b</li></ul>',
      );
      final grid = doc.nodes.whereType<HElement>().single;
      expect(grid.has('grid'), isTrue);
      expect(grid.style.columns, 2);
      expect(grid.children.map((e) => (e as HElement).classes.first), [
        'cons',
        'pros',
      ]);
    });

    test('every component is recognised', () {
      final doc = sanitizeHtml(compareHtml + tripHtml);
      final found = {
        for (final e in _all(doc.nodes))
          if (isHtmlComponent(e)) e.attrs['class'] ?? e.tag,
      };
      expect(
        found,
        containsAll([
          'hero',
          'cards cols-2',
          'stats',
          'bar good',
          'bar',
          'dl',
          'callout tip',
          'button',
          'tabs',
          'timeline',
          'details',
          'gallery',
          'pros',
          'cons',
        ]),
      );
    });

    test('stats read value, label and tone', () {
      final stats = htmlStats(
        _all(sanitizeHtml(compareHtml).nodes).firstWhere((e) => e.has('stats')),
      );
      expect(stats.map((c) => (c.label, c.value, c.tone)), [
        ('Price gap', r'$100', UiTone.neutral),
        ('Brio updates', '7 yrs', UiTone.good),
        ('Main cameras', '48 MP', UiTone.neutral),
      ]);
    });

    test('badges become inline tags; their text cannot form markup', () {
      String md(String h) => flowMarkdown(sanitizeHtml(h).nodes);
      expect(
        md('<h4>Phone <span class="badge good">Best</span></h4>'),
        '#### Phone <badge-good>Best</badge-good>',
      );
      expect(
        md('<p><span class="badge">**x** [a](javascript:1)</span></p>'),
        r'<badge-neutral>\*\*x\*\* \[a\](javascript:1)</badge-neutral>',
      );
      expect(
        md('<div class="badge bad">Down</div>'),
        '<badge-bad>Down</badge-bad>',
      );
      expect(
        md('<p><span class="meta">Updated 2 min ago</span></p>'),
        '<small>Updated 2 min ago</small>',
      );
    });

    test('read aloud keeps every tab and the spec sheet', () {
      final text = sanitizeHtml(compareHtml + tripHtml).plainText;
      expect(text, contains('Top Station sunrise'));
      expect(text, contains('National park'));
      expect(text, contains('199 g / 207 g'));
    });
  });

  group('plain fallback', () {
    test('paragraphs, emphasis and plain lists are plain; layout is not', () {
      expect(isPlainHtml(sanitizeHtml(plainHtml).nodes), isTrue);
      expect(
        isPlainHtml(sanitizeHtml('<div class="carousel"><p>a</p></div>').nodes),
        isTrue,
        reason: 'unknown classes are dropped',
      );
      for (final h in [
        '<div style="display:grid;grid-template-columns:1fr 1fr"><p>a</p><p>b</p></div>',
        '<div style="display:flex"><p>a</p><p>b</p></div>',
        '<p>a <span class="badge good">b</span></p>',
        '<table><tr><td>a</td></tr></table>',
        '<img src="https://img.example.com/a.png" alt="a">',
        '<details><summary>a</summary>b</details>',
        compareHtml,
      ]) {
        expect(isPlainHtml(sanitizeHtml(h).nodes), isFalse, reason: h);
      }
    });

    testWidgets('a plain block draws exactly like markdown: one markdown '
        'view, no box', (tester) async {
      await tester.pumpWidget(
        r3Frame(
          const HermesHtml(source: plainHtml),
          brightness: Brightness.light,
          desktop: false,
        ),
      );
      final mds = find.descendant(
        of: find.byType(HermesHtml),
        matching: find.byType(HermesMarkdown),
      );
      expect(mds, findsOneWidget);
      expect(
        tester.widget<HermesMarkdown>(mds).text,
        '### Summary\n\nTCP is **reliable**; UDP is *fast*.\n\n'
        '- **TCP:** ordered\n- **UDP:** no handshake',
      );
      final boxes = find.descendant(
        of: find.byType(HermesHtml),
        matching: find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).border != null,
        ),
      );
      expect(boxes, findsNothing);
      // Same height as the same markdown on its own.
      final htmlHeight = tester.getSize(find.byType(HermesHtml)).height;
      await tester.pumpWidget(
        r3Frame(
          HermesMarkdown(text: tester.widget<HermesMarkdown>(mds).text),
          brightness: Brightness.light,
          desktop: false,
        ),
      );
      expect(tester.getSize(find.byType(HermesMarkdown)).height, htmlHeight);
    });
  });

  group('interaction', () {
    Future<(List<String>, List<String>)> pumpReply(
      WidgetTester tester,
      String text, {
      bool enabled = true,
      double textScale = 1,
    }) async {
      final sent = <String>[];
      final opened = <String>[];
      tester.view.physicalSize = const Size(412, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        r3Frame(
          HermesUiScope(
            onSend: sent.add,
            onOpenLink: opened.add,
            enabled: enabled,
            child: AssistantMessage(
              message: reply(text),
              onRetry: () {},
              onDelete: () {},
            ),
          ),
          brightness: Brightness.dark,
          desktop: false,
          textScale: textScale,
        ),
      );
      await tester.pump(const Duration(milliseconds: 900));
      await settleImages(tester);
      expect(tester.takeException(), isNull);
      return (sent, opened);
    }

    testWidgets('a button sends its data-send once, then locks; nothing '
        'opens', (tester) async {
      final (sent, opened) = await pumpReply(tester, compareReply);
      await tester.ensureVisible(find.text('Low-light camera?'));
      await tester.tap(find.text('Low-light camera?'));
      await tester.pump();
      await tester.tap(find.text('Low-light camera?'), warnIfMissed: false);
      await tester.tap(find.text('Brio deals'), warnIfMissed: false);
      expect(sent, ['Which has the better low-light camera?']);
      expect(opened, isEmpty);
    });

    testWidgets('a malicious data-send is sent as text, never opened', (
      tester,
    ) async {
      final (sent, opened) = await pumpReply(
        tester,
        '```hermes-html\n<button data-send="javascript:alert(1)" '
        'onclick="steal()">Tap</button>\n```\n',
      );
      await tester.tap(find.text('Tap'));
      expect(sent, ['javascript:alert(1)']);
      expect(opened, isEmpty);
    });

    testWidgets('while sending is off, buttons do nothing', (tester) async {
      final (sent, _) = await pumpReply(tester, compareReply, enabled: false);
      await tester.ensureVisible(find.text('Brio deals'));
      await tester.tap(find.text('Brio deals'), warnIfMissed: false);
      expect(sent, isEmpty);
    });

    testWidgets('a link button opens through the scope (the confirm sheet)', (
      tester,
    ) async {
      final (sent, opened) = await pumpReply(
        tester,
        '```hermes-html\n<a class="button" href="https://example.com/deal">'
        'See the deal</a>\n```\n',
      );
      await tester.tap(find.text('See the deal'));
      expect(opened, ['https://example.com/deal']);
      expect(sent, isEmpty);
    });

    testWidgets('tabs switch panes; accordions open', (tester) async {
      await pumpReply(tester, tripReply);
      expect(
        find.textContaining('Tea museum', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('Top Station', findRichText: true),
        findsNothing,
      );
      await tester.tap(find.text('Day 2'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Top Station', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('Tea museum', findRichText: true),
        findsNothing,
      );
      expect(
        find.textContaining('Light jacket', findRichText: true),
        findsNothing,
      );
      await tester.tap(find.text('Packing list'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Light jacket', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('a card picture opens the full-screen viewer', (tester) async {
      await pumpReply(tester, compareReply);
      final pic = find.byType(HtmlCover);
      await tester.ensureVisible(pic.first);
      await tester.tap(pic.first);
      await tester.pumpAndSettle();
      expect(find.byType(MdImageViewer), findsOneWidget);
    });

    testWidgets('screen readers hear bars with their values', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpReply(tester, compareReply);
      expect(find.bySemanticsLabel('Brio endurance: 82%'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('200% text: rich replies do not overflow', (tester) async {
      for (final r in [compareReply, tripReply]) {
        tester.view.physicalSize = const Size(412, 6000);
        await pumpReply(tester, r, textScale: 2);
      }
    });
  });

  group('goldens', () {
    setUpAll(loadReplyFonts);
    final cases = {
      'compare': (compareReply, 2350.0),
      'trip': (tripReply, 1050.0),
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
            matchesGoldenFile('goldens/r7_${name}_${b.name}.png'),
          );
        });
      }
    }
  });
}
