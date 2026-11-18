import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/markdown/hermes_markdown.dart';
import 'package:tove_chat/src/ui/markdown/links.dart' as links;
import 'package:tove_chat/src/ui/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

void main() {
  const t = HermesTokens.darkTokens;

  Future<void> show(
    WidgetTester tester,
    String md, {
    MarkdownLinkTap? onLinkTap,
    double width = 412,
  }) async {
    setSurface(tester, width);
    await tester.pumpWidget(
      host(HermesMarkdown(text: md, onLinkTap: onLinkTap)),
    );
    await tester.pump();
  }

  testWidgets('headings use H1–H3 styles and are semantic headers', (
    tester,
  ) async {
    final sem = tester.ensureSemantics();
    await show(tester, '# Big\n\n## Mid\n\n### Small\n\nBody text.');
    expect(styleOf(tester, 'Big')!.fontSize, 26);
    expect(styleOf(tester, 'Mid')!.fontSize, 23);
    expect(styleOf(tester, 'Small')!.fontSize, 20);
    expect(
      styleOf(tester, 'Mid')!.fontVariations,
      contains(const FontVariation('wght', 650)),
    );
    expect(styleOf(tester, 'Body text.')!.fontSize, 17);
    expect(styleOf(tester, 'Big')!.fontWeight, FontWeight.w700);
    for (final h in ['Big', 'Mid', 'Small']) {
      expect(
        tester.getSemantics(find.text(h)),
        isSemantics(isHeader: true, label: h),
      );
    }
    sem.dispose();
  });

  testWidgets('paragraph gap is 16, heading gaps 24 above and 8 below', (
    tester,
  ) async {
    await show(tester, 'One.\n\nTwo.\n\n## Head\nThree.');
    double top(String s) => tester.getTopLeft(find.text(s)).dy;
    double bottom(String s) => tester.getBottomLeft(find.text(s)).dy;
    expect(top('Two.') - bottom('One.'), closeTo(16, 0.01));
    expect(top('Head') - bottom('Two.'), closeTo(24, 0.01));
    expect(top('Three.') - bottom('Head'), closeTo(8, 0.01));
  });

  testWidgets('bold, italic, strikethrough and soft breaks', (tester) async {
    await show(tester, 'A **strong** and *slanted* and ~~gone~~\nnext line.');
    final strong = spanWithText(tester, 'strong')!.style!;
    expect(strong.fontWeight, FontWeight.w700);
    expect(strong.fontVariations, contains(const FontVariation('wght', 700)));
    // Roboto Flex has no italic: emphasis is its oblique (slnt −10).
    expect(
      spanWithText(tester, 'slanted')!.style!.fontVariations,
      contains(const FontVariation('slnt', -10)),
    );
    expect(
      spanWithText(tester, 'gone')!.style!.decoration,
      TextDecoration.lineThrough,
    );
    // A soft break is a space, not a new line.
    expect(visibleText(tester), contains('gone next line.'));
  });

  testWidgets('HTML entities and inline <br> render as text', (tester) async {
    await show(tester, 'Fish &amp; chips<br>on toast');
    final text = visibleText(tester);
    expect(text, contains('Fish & chips'));
    expect(text, contains('\non toast'));
  });

  testWidgets('inline code is a mono chip on the body line', (tester) async {
    await show(tester, 'Call `fetch()` now.');
    final code = tester.widget<Text>(find.text('fetch()'));
    expect(code.style!.fontFamily, HermesTokens.monoFamily);
    expect(code.style!.fontSize, closeTo(17 * 0.88, 0.001));
    final chip = find.ancestor(
      of: find.text('fetch()'),
      matching: find.byType(Container),
    );
    final box =
        tester.widget<Container>(chip.first).decoration as BoxDecoration;
    expect(box.color, t.surfaceHigh);
    // The chip is no taller than a body line (26 dp).
    expect(tester.getSize(chip.first).height, lessThanOrEqualTo(26.01));
  });

  testWidgets('code block: language label, horizontal scroll, copy feedback', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
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
    final long = 'x' * 300;
    await show(tester, '```dart\nfinal a = 1;\nfinal b = "$long";\n```');
    expect(find.byType(CodeBlock), findsOneWidget);
    expect(find.text('dart'), findsOneWidget);
    final codeText = find.textContaining('final a = 1;');
    expect(
      tester.widget<Text>(codeText).style!.fontFamily,
      HermesTokens.monoFamily,
    );
    expect(tester.widget<Text>(codeText).softWrap, isFalse);
    final scroll = find.ancestor(
      of: codeText,
      matching: find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      ),
    );
    expect(scroll, findsOneWidget);
    expect(tester.takeException(), isNull);

    // Icon-only copy (40 dp) with a check for 1.5 s.
    expect(tester.getSize(find.byType(InkResponse).first), const Size(40, 40));
    await tester.tap(find.byIcon(Icons.copy_rounded));
    await tester.pump();
    expect(copied, ['final a = 1;\nfinal b = "$long";']);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1600));
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
  });

  testWidgets('code block semantics name the language', (tester) async {
    final sem = tester.ensureSemantics();
    await show(tester, '```py\nprint(1)\n```');
    expect(find.bySemanticsLabel(RegExp(r'^Code, py')), findsOneWidget);
    expect(find.bySemanticsLabel('Copy code'), findsOneWidget);
    sem.dispose();
  });

  testWidgets('bullet, ordered and task lists', (tester) async {
    final sem = tester.ensureSemantics();
    await show(
      tester,
      '- one\n- two\n  - nested\n\n3. third\n4. fourth\n\n- [x] done\n- [ ] todo',
    );
    // Bullets are painted dots, not glyphs.
    expect(find.text('•'), findsNothing);
    expect(find.text('3.'), findsOneWidget);
    expect(find.text('4.'), findsOneWidget);
    expect(find.bySemanticsLabel('Done'), findsOneWidget);
    expect(find.bySemanticsLabel('Not done'), findsOneWidget);
    // 32 dp hanging indent from the 16 dp gutter; nested levels add 28.
    expect(tester.getTopLeft(find.text('one')).dx, closeTo(16 + 32, 0.01));
    expect(tester.getTopLeft(find.text('nested')).dx, closeTo(16 + 60, 0.01));
    // Numbers are right-aligned 8 dp before the text, in a box of at least
    // 24 dp (wider when the number needs it, as with the test font here).
    final third = tester.getTopLeft(find.text('third')).dx;
    expect(third, greaterThanOrEqualTo(16 + 32 - 0.01));
    expect(third - tester.getTopRight(find.text('3.')).dx, closeTo(8, 0.01));
    // Tight items have no extra gap: one line pitch (26) apart.
    expect(
      tester.getTopLeft(find.text('two')).dy -
          tester.getTopLeft(find.text('one')).dy,
      closeTo(26, 0.01),
    );
    sem.dispose();
  });

  testWidgets('a lead-in ending in ":" sits 8 dp above its list', (
    tester,
  ) async {
    await show(tester, 'Test these:\n\n- one\n\nAfter.');
    double top(String s) => tester.getTopLeft(find.text(s)).dy;
    double bottom(String s) => tester.getBottomLeft(find.text(s)).dy;
    expect(top('one') - bottom('Test these:'), closeTo(8, 0.01));
    expect(top('After.') - bottom('one'), closeTo(16, 0.01));
  });

  testWidgets('a table scrolls horizontally with a styled header', (
    tester,
  ) async {
    await show(
      tester,
      '| Name | Role | Notes |\n|---|:---:|---:|\n'
      '| Pathfinder | core | ${'long text ' * 20}|\n'
      '| NAS-01 | storage | short |',
      width: 360,
    );
    expect(find.byType(MdTable), findsOneWidget);
    expect(styleOf(tester, 'Name')!.fontWeight, FontWeight.w700);
    expect(styleOf(tester, 'Pathfinder')!.fontWeight, FontWeight.w400);
    expect(styleOf(tester, 'Pathfinder')!.fontSize, 14.5);
    expect(tester.takeException(), isNull);

    // It overflows, so only the right edge fades; the scroller bleeds 16 dp
    // past the gutter to both screen edges and the first column is flush
    // with the text.
    await tester.pump();
    expect(find.byWidgetPredicate((w) => w is Positioned), findsOneWidget);
    final viewport = find.descendant(
      of: find.byType(MdTable),
      matching: find.byType(Scrollable),
    );
    expect(tester.getTopLeft(viewport).dx, closeTo(0, 0.01));
    expect(tester.getTopRight(viewport).dx, closeTo(360, 0.01));
    expect(tester.getTopLeft(find.text('Name')).dx, closeTo(16, 0.01));
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(MdTable),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    await tester.drag(find.byType(MdTable), const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, greaterThan(0));
    // At the end only the left edge fades.
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    final fades = tester.widgetList<Positioned>(
      find.byWidgetPredicate((w) => w is Positioned),
    );
    expect(fades.map((p) => p.left), [-16]);
    // Columns are clamped to 112–300 dp, so the long cell wraps.
    final notes = find.textContaining('long text');
    expect(tester.getSize(notes).width, lessThanOrEqualTo(300 - 24 + 0.01));
  });

  testWidgets('links: solid 35 % underline, no glyph, tap, semantics', (
    tester,
  ) async {
    final sem = tester.ensureSemantics();
    final taps = <String>[];
    await show(
      tester,
      'Read [the docs](https://docs.example.dev/x) or [bad](javascript:alert(1)).',
      onLinkTap: taps.add,
    );
    final s = spanWithText(tester, 'the docs')!;
    expect(s.style!.decoration, TextDecoration.underline);
    expect(s.style!.decorationStyle, TextDecorationStyle.solid);
    expect(s.style!.decorationColor, t.text.withValues(alpha: 0.35));
    expect(s.recognizer, isNotNull);
    expect(find.text(' ↗'), findsNothing);
    expect(spanWithText(tester, 'bad')!.recognizer, isNull);

    await tester.tapOnText(find.textRange.ofSubstring('the docs'));
    expect(taps, ['https://docs.example.dev/x']);

    final node = find.semantics.byLabel('the docs').evaluate().single;
    expect(node, isSemantics(isLink: true));
    sem.dispose();
  });

  testWidgets('default link tap asks before opening, showing the host', (
    tester,
  ) async {
    final opened = <Uri>[];
    final prev = links.linkOpener;
    links.linkOpener = (u) async {
      opened.add(u);
      return true;
    };
    addTearDown(() => links.linkOpener = prev);
    await show(tester, '[site](https://www.example.org/page)');
    await tester.tapOnText(find.textRange.ofSubstring('site'));
    await tester.pumpAndSettle();
    expect(find.text('Open link?'), findsOneWidget);
    expect(find.text('example.org'), findsOneWidget);
    await tester.tap(find.text('Open in browser'));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse('https://www.example.org/page')]);
  });

  testWidgets('a Sources line renders host pills', (tester) async {
    final taps = <String>[];
    await show(
      tester,
      'Answer.\n\n**Sources:** [A](https://www.example.com/a), [B](https://news.site.org/b)',
      onLinkTap: taps.add,
    );
    expect(find.byType(SourcePill), findsNWidgets(2));
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('news.site.org'), findsOneWidget);
    expect(find.byIcon(Icons.language_rounded), findsNWidgets(2));
    await tester.tap(find.text('news.site.org'));
    expect(taps, ['https://news.site.org/b']);
    expect(
      tester.getSize(find.byType(SourcePill).first).height,
      greaterThanOrEqualTo(48),
    );
  });

  testWidgets('a Sources label followed by a list of links renders pills', (
    tester,
  ) async {
    await show(
      tester,
      'Sources:\n\n- [One](https://one.dev)\n- [Two](https://two.dev/x)',
    );
    expect(find.byType(SourcePill), findsNWidgets(2));
    expect(find.text('two.dev'), findsOneWidget);
    // A list of links without the label stays a list.
    await show(tester, 'Links:\n\n- [One](https://one.dev)');
    expect(find.byType(SourcePill), findsNothing);
  });

  testWidgets('block quote, rule and image placeholder', (tester) async {
    await show(
      tester,
      '> quoted words\n\n---\n\n![a cat](https://x.dev/cat.png)',
    );
    expect(styleOf(tester, 'quoted words')!.color, t.textMuted);
    final bar = find.byWidgetPredicate((w) => w is Positioned && w.width == 3);
    expect(bar, findsOneWidget);
    // The text starts 16 dp after the 3 dp bar.
    expect(
      tester.getTopLeft(find.text('quoted words')).dx -
          tester.getTopLeft(bar).dx,
      closeTo(19, 0.01),
    );
    expect(
      find.byWidgetPredicate((w) => w is Container && w.color == t.hairline),
      findsOneWidget,
    );
    expect(find.text('[image: a cat]'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('everything renders at 200 % text without overflow', (
    tester,
  ) async {
    setSurface(tester, 360);
    const md =
        '# A heading that is rather long for a phone\n\n'
        'Body with `a_very_long_inline_code_identifier_value` and a '
        '[link](https://example.dev/some/long/path) and **bold**.\n\n'
        '1. one\n2. two\n3. three\n4. four\n5. five\n6. six\n7. seven\n'
        '8. eight\n9. nine\n10. ten\n\n'
        '- [x] task\n  - nested bullet with words\n\n'
        '> A quote that wraps across lines at large sizes.\n\n'
        '```bash\ncurl -fsSL https://example.dev/install.sh | sh -s -- --yes\n```\n\n'
        '| Column one | Column two | Column three |\n|---|---|---|\n'
        '| a value | another value | a third value |\n\n'
        'Sources: [A](https://a.example.com), [B](https://b.example.com)\n\n'
        '![diagram](https://x.dev/d.png)';
    await tester.pumpWidget(host(const HermesMarkdown(text: md), textScale: 2));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // Ordered markers widen the hanging indent instead of overflowing.
    expect(
      tester.getTopRight(find.text('10.')).dx,
      lessThanOrEqualTo(tester.getTopLeft(find.text('ten')).dx),
    );
  });
}
