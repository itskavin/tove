// Offline visual QA, 15 November 2026: contrast of the sources toggle, the
// reply's long-press label and the wide-table scroll cue.
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/brand.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/ui/live/live_content.dart';
import 'package:tove_chat/src/ui/live/live_link_cards.dart';
import 'package:tove_chat/src/ui/markdown/favicons.dart';
import 'package:tove_chat/src/ui/markdown/hermes_markdown.dart';
import 'package:tove_chat/src/ui/thread/messages.dart';

import 'test_harness.dart';

const _wideTable =
    '| Option | Access | Setup | Notes |\n|---|---|---|---|\n'
    '| Windows OpenSSH | Native SSH, SFTP | Optional feature | Handles keys |\n'
    '| Tailscale SSH | Tailnet only | One toggle | Not on Windows hosts |';

const _narrowTable = '| A | B |\n|---|---|\n| 1 | 2 |';

ChatMessage _reply(
  String text, {
  String id = 'a1',
  MessageStatus status = MessageStatus.done,
}) => ChatMessage(
  id: id,
  conversationId: 'c',
  role: MessageRole.assistant,
  text: text,
  status: status,
  created: DateTime(2026, 11, 15),
);

// A cited reply ending in an uncited credit line, as REAL F1 does.
const _cited =
    'Red pandas live in temperate forests.[^1]\n'
    '\n'
    'Photo credits: Juan Carlos Munoz / naturepl.com.\n'
    '\n'
    '[^1]: [Red Panda](https://www.worldwildlife.org/species/red-panda/) — WWF.\n';

Widget _scaled(Widget child, double scale) => Builder(
  builder: (context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    ),
  ),
);

void main() {
  setUpAll(loadAppFonts);

  group('sources toggle', () {
    final sites = [
      for (var i = 0; i < 4; i++)
        LiveSite(
          uri: Uri.parse('https://s$i.example.org/page'),
          title: 'Source $i',
          host: 's$i.example.org',
        ),
    ];

    for (final b in Brightness.values) {
      testWidgets('meets WCAG AA text contrast (${b.name})', (tester) async {
        final handle = tester.ensureSemantics();
        phoneSize(tester);
        await tester.pumpWidget(
          themed(_scaled(LiveSiteCards(sites: sites), 1), brightness: b),
        );
        expect(find.text('Show all 4 sources'), findsOneWidget);
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        handle.dispose();
      });
    }

    testWidgets('200 % text: toggle reads whole and expands', (tester) async {
      phoneSize(tester);
      await tester.pumpWidget(themed(_scaled(LiveSiteCards(sites: sites), 2)));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Show all 4 sources'));
      await tester.pumpAndSettle();
      expect(find.text('Source 3'), findsOneWidget);
      expect(find.text('Show fewer sources'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('reply long-press', () {
    Future<void> pumpReply(WidgetTester tester, ValueChanged<int> onMenu) {
      var opened = 0;
      return tester.pumpWidget(
        themed(
          _scaled(
            AssistantMessage(
              message: _reply(
                'Use **OpenSSH**. See [the docs](https://learn.example.com/ssh).',
              ),
              onRetry: () {},
              onDelete: () {},
              onLongPress: (_) => onMenu(++opened),
            ),
            1,
          ),
        ),
      );
    }

    testWidgets('is a labelled action that keeps the reply readable', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      phoneSize(tester);
      var opened = 0;
      await pumpReply(tester, (n) => opened = n);
      await tester.pumpAndSettle();

      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

      final node = tester.getSemantics(find.byType(AssistantMessage));
      final data = node.getSemanticsData();
      expect(data.hasAction(SemanticsAction.longPress), isTrue);
      expect(data.label, startsWith(Brand.assistantName));
      expect(node.hintOverrides?.onLongPressHint, 'Message options');

      // The selectable answer, the source and the action buttons stay
      // their own nodes, not merged into the action.
      expect(find.semantics.byLabel(RegExp('OpenSSH')), findsOne);
      expect(
        find.semantics.byPredicate(
          (n) =>
              n.tooltip == 'Copy' &&
              n.getSemanticsData().hasAction(SemanticsAction.tap),
        ),
        findsOne,
      );
      expect(find.semantics.byLabel('the docs'), findsOne);

      tester.semantics.longPress(find.semantics.byLabel(RegExp('^Hermes')));
      await tester.pump();
      expect(opened, 1);
      handle.dispose();
    });

    testWidgets('a long press outside the text still opens the menu', (
      tester,
    ) async {
      phoneSize(tester);
      var opened = 0;
      await pumpReply(tester, (n) => opened = n);
      await tester.pumpAndSettle();
      // Text itself keeps the selection's long press.
      await tester.longPress(find.text('Sources'));
      expect(opened, 1);
    });

    testWidgets('no long-press action while streaming', (tester) async {
      final handle = tester.ensureSemantics();
      phoneSize(tester);
      await tester.pumpWidget(
        themed(
          _scaled(
            AssistantMessage(
              message: _reply('Working'),
              onRetry: null,
              onDelete: () {},
            ),
            1,
          ),
        ),
      );
      final data = tester
          .getSemantics(find.byType(AssistantMessage))
          .getSemanticsData();
      expect(data.hasAction(SemanticsAction.longPress), isFalse);
      handle.dispose();
    });
  });

  group('reply semantics with sources', () {
    final variants = [
      ('dark', Brightness.dark, 1.0),
      ('light', Brightness.light, 1.0),
      ('dark200', Brightness.dark, 2.0),
    ];
    for (final (name, b, scale) in variants) {
      testWidgets('long-press node holds only the assistant name ($name)', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        phoneSize(tester);
        var opened = 0;
        await tester.pumpWidget(
          themed(
            _scaled(
              AssistantMessage(
                message: _reply(_cited),
                onRetry: () {},
                onDelete: () {},
                onLongPress: (_) => opened++,
              ),
              scale,
            ),
            brightness: b,
          ),
        );
        await tester.pumpAndSettle();

        final node = tester.getSemantics(find.byType(AssistantMessage));
        final data = node.getSemanticsData();
        expect(data.label, Brand.assistantName);
        expect(data.flagsCollection.isHeader, isFalse);
        expect(data.hasAction(SemanticsAction.longPress), isTrue);

        // The credit line and the sources pill are their own nodes, in
        // reading order: answer, credit, sources.
        final credit = find.semantics
            .byLabel(RegExp('^Photo credits'))
            .evaluate()
            .single;
        expect(credit.id, isNot(node.id));
        expect(credit.getSemanticsData().flagsCollection.isHeader, isFalse);
        final order = <String>[];
        bool visit(SemanticsNode n) {
          final l = n.getSemanticsData().label;
          if (l.isNotEmpty) order.add(l);
          n.visitChildren(visit);
          return true;
        }

        node.visitChildren(visit);
        int at(String p) => order.indexWhere((l) => l.startsWith(p));
        expect(at('Red pandas'), greaterThanOrEqualTo(0));
        expect(at('Red pandas'), lessThan(at('Photo credits')));
        expect(at('Photo credits'), lessThan(at('Sources, 1 page')));
        expect(
          find.semantics.byPredicate(
            (n) =>
                n.tooltip == 'Copy' &&
                n.getSemanticsData().hasAction(SemanticsAction.tap),
          ),
          findsOne,
        );

        tester.semantics.longPress(find.semantics.byLabel(Brand.assistantName));
        await tester.pump();
        expect(opened, 1);
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        handle.dispose();
      });
    }

    testWidgets('a long press on the answer selects text, no menu', (
      tester,
    ) async {
      phoneSize(tester);
      addTearDown(() => ThreadSelection.set('a1', false));
      var opened = 0;
      await tester.pumpWidget(
        themed(
          _scaled(
            AssistantMessage(
              message: _reply(_cited),
              onRetry: () {},
              onDelete: () {},
              onLongPress: (_) => opened++,
            ),
            1,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final r = tester.getRect(find.textContaining('Photo credits'));
      await tester.longPressAt(r.topLeft + const Offset(24, 10));
      await tester.pumpAndSettle();
      expect(opened, 0);
      expect(find.byType(AdaptiveTextSelectionToolbar), findsOne);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('sources pill: screen reader opens details, then the page', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      phoneSize(tester);
      final opened = <Uri>[];
      final previous = liveSiteOpener;
      liveSiteOpener = (uri) async {
        opened.add(uri);
        return true;
      };
      addTearDown(() => liveSiteOpener = previous);
      await tester.pumpWidget(
        themed(
          _scaled(
            AssistantMessage(
              message: _reply(_cited),
              onRetry: () {},
              onDelete: () {},
            ),
            1,
          ),
        ),
      );
      await tester.pumpAndSettle();
      // No full rows under the answer: one compact pill.
      expect(find.byType(LiveSiteCard), findsNothing);
      final pill = find.semantics.byLabel('Sources, 1 page: worldwildlife.org');
      final pd = pill.evaluate().single.getSemanticsData();
      expect(pd.flagsCollection.isButton, isTrue);
      expect(pd.hasAction(SemanticsAction.tap), isTrue);

      tester.semantics.tap(pill);
      await tester.pumpAndSettle();
      expect(find.text('Red Panda'), findsOneWidget);
      expect(find.text('worldwildlife.org/species/red-panda'), findsOneWidget);
      final row = find.semantics.byLabel('Open Red Panda, worldwildlife.org');
      final data = row.evaluate().single.getSemanticsData();
      expect(data.flagsCollection.isLink, isTrue);
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      tester.semantics.tap(row);
      await tester.pumpAndSettle();
      final page = Uri.parse(
        'https://www.worldwildlife.org/species/red-panda/',
      );
      expect(opened, [page]);
      expect(find.text('Red Panda'), findsNothing); // the sheet closed

      // Physical taps open the sheet and the page exactly once too.
      await tester.tap(find.text('Sources'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Red Panda'));
      await tester.pumpAndSettle();
      expect(opened, [page, page]);
      handle.dispose();
    });
  });

  group('sources pill', () {
    LiveSite site(String url, [String? title]) {
      final uri = Uri.parse(url);
      return LiveSite(
        uri: uri,
        title: title ?? siteTitleFromUri(uri),
        host: linkHost(uri),
      );
    }

    final many = [
      site('https://learn.microsoft.com/windows/wsl/install', 'Install WSL'),
      site('https://tailscale.com/kb/1193/tailscale-ssh', 'Tailscale SSH'),
      site('https://code.visualstudio.com/docs/remote/ssh', 'Remote SSH'),
      site('https://github.com/PowerShell/Win32-OpenSSH/wiki', 'Wiki'),
      site(
        'https://a-very-long-subdomain.documentation.example-organisation.co.uk/'
        'guides/2026/secure-shell-configuration-for-windows-hosts',
      ),
    ];

    testWidgets('none shows nothing', (tester) async {
      await tester.pumpWidget(
        themed(_scaled(const LiveSourcesPill(sites: []), 1)),
      );
      expect(find.text('Sources'), findsNothing);
    });

    for (final (name, b, scale) in [
      ('dark', Brightness.dark, 1.0),
      ('light', Brightness.light, 1.0),
      ('dark200', Brightness.dark, 2.0),
    ]) {
      testWidgets('compact, readable and complete in details ($name)', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        phoneSize(tester);
        await tester.pumpWidget(
          themed(_scaled(LiveSourcesPill(sites: many), scale), brightness: b),
        );
        expect(tester.takeException(), isNull);
        final box = tester.getRect(find.byType(LiveSourcesPill));
        final label = tester.getRect(find.text('Sources'));
        final cluster = tester
            .getRect(find.byType(SiteFavicon).first)
            .expandToInclude(label);
        // The reference cluster: three round favicons (letter tiles without
        // a loader) and "Sources", no fill, on a full 48 dp target.
        expect(box.height, greaterThanOrEqualTo(48));
        expect(cluster.height, lessThan(scale == 1 ? 32 : 48));
        expect(cluster.width, lessThan(scale == 1 ? 140 : 220));
        expect(find.byType(SiteFavicon), findsNWidgets(3));
        expect(find.byType(SiteLetterTile), findsNWidgets(3));
        final icons = [
          for (final e in find.byType(SiteFavicon).evaluate())
            tester.getRect(find.byWidget(e.widget)),
        ]..sort((a, b) => a.left.compareTo(b.left));
        // 20 dp faces (+ 1.5 dp ring) stepping 18 dp: they overlap.
        expect(icons.first.width, scale == 1 ? 23 : greaterThan(23));
        expect(icons[1].left - icons[0].left, lessThan(icons[0].width));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        expect(
          find.semantics.byLabel(
            'Sources, 5 pages: learn.microsoft.com, tailscale.com, '
            'code.visualstudio.com, github.com, '
            'a-very-long-subdomain.documentation.example-organisation.co.uk',
          ),
          findsOne,
        );

        await tester.tap(find.text('Sources'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(LiveSiteCard), findsNWidgets(5));
        // A missing title reads from the address; long addresses ellipsize.
        expect(
          find.text('Secure shell configuration for windows hosts'),
          findsOne,
        );
        for (final s in many) {
          expect(
            find.semantics.byLabel('Open ${s.title}, ${s.host}'),
            findsOne,
          );
        }
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        handle.dispose();
      });
    }

    test('details list the cited pages, deduped, never images', () {
      final sites = extractSites(
        '[![Red panda](https://img.example.org/a.jpg)](https://wwf.org/panda/)\n'
        '\n'
        'See [Red panda](https://wwf.org/panda) and https://wwf.org/panda/#diet.',
      );
      expect(sites.map((s) => s.uri.toString()), ['https://wwf.org/panda/']);
      expect(sites.single.title, 'Red panda');
      expect(siteAddress(sites.single.uri), 'wwf.org/panda');
    });
  });

  group('reply sources cache', () {
    late List<String> parsed;
    late List<LiveSite> Function(String) previous;
    setUp(() {
      parsed = [];
      previous = replySitesExtractor;
      replySitesExtractor = (text) {
        parsed.add(text);
        return extractSites(text);
      };
    });
    tearDown(() => replySitesExtractor = previous);

    Widget reply(
      ChatMessage m, {
      Brightness b = Brightness.dark,
      double scale = 1,
    }) => themed(
      _scaled(
        AssistantMessage(message: m, onRetry: () {}, onDelete: () {}),
        scale,
      ),
      brightness: b,
    );

    List<String> shown(WidgetTester tester) {
      final f = find.byType(LiveSourcesPill);
      if (f.evaluate().isEmpty) return const [];
      return [for (final s in tester.widget<LiveSourcesPill>(f).sites) s.title];
    }

    testWidgets('settled rebuilds parse once; theme and text size rebuild', (
      tester,
    ) async {
      phoneSize(tester);
      final m = _reply(_cited);
      await tester.pumpWidget(reply(m));
      final rect = tester.getRect(find.text('Sources'));
      Color colour() => tester
          .widget<RichText>(
            find
                .descendant(
                  of: find.byType(LiveSourcesPill),
                  matching: find.byType(RichText),
                )
                .last,
          )
          .text
          .style!
          .color!;
      final dark = colour();
      // As while another reply streams: the same settled message rebuilds,
      // also as an equal copy from a history reload.
      for (var i = 0; i < 5; i++) {
        await tester.pumpWidget(reply(_reply(_cited)));
      }
      await tester.pumpWidget(reply(m, b: Brightness.light));
      await tester.pumpAndSettle();
      expect(colour(), isNot(dark));
      await tester.pumpWidget(reply(m, scale: 2));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.text('Sources')).height,
        greaterThan(rect.height),
      );
      await tester.pumpWidget(reply(m));
      await tester.pumpAndSettle();
      expect(parsed, hasLength(1));
      expect(tester.getRect(find.text('Sources')), rect);
      expect(shown(tester), ['Red Panda']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('never parses while streaming', (tester) async {
      phoneSize(tester);
      var text = '';
      for (final chunk in _cited.split(' ')) {
        text += '$chunk ';
        await tester.pumpWidget(
          reply(_reply(text, status: MessageStatus.streaming)),
        );
      }
      expect(parsed, isEmpty);
      expect(find.byType(LiveSourcesPill), findsNothing);
      await tester.pumpWidget(reply(_reply(_cited)));
      await tester.pump(const Duration(seconds: 1));
      expect(parsed, hasLength(1));
      expect(shown(tester), ['Red Panda']);
    });

    testWidgets('an edit or retry of the same message replaces its sources', (
      tester,
    ) async {
      phoneSize(tester);
      await tester.pumpWidget(reply(_reply(_cited)));
      expect(shown(tester), ['Red Panda']);

      const edited =
          'Now see [Red panda facts](https://www.wwf.org.uk/red-panda).';
      await tester.pumpWidget(reply(_reply(edited)));
      expect(parsed, hasLength(2));
      expect(shown(tester), ['Red panda facts']);

      // A retry streams again, then settles with no links: no stale pill.
      await tester.pumpWidget(
        reply(_reply('Re', status: MessageStatus.streaming)),
      );
      expect(find.byType(LiveSourcesPill), findsNothing);
      await tester.pumpWidget(reply(_reply('Plain answer.')));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(LiveSourcesPill), findsNothing);
      expect(parsed, hasLength(3));
    });

    testWidgets('another message in the same slot reads its own text', (
      tester,
    ) async {
      phoneSize(tester);
      await tester.pumpWidget(reply(_reply(_cited)));
      await tester.pumpWidget(
        reply(
          _reply(
            'See [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh).',
            id: 'a2',
          ),
        ),
      );
      expect(parsed, hasLength(2));
      expect(shown(tester), ['Tailscale SSH']);
    });
  });

  group('wide table scroll cue', () {
    Finder scrollable() => find.descendant(
      of: find.byType(MdTable),
      matching: find.byType(Scrollable),
    );
    Finder fades() => find.descendant(
      of: find.byType(MdTable),
      matching: find.byWidgetPredicate((w) => w is Positioned),
    );

    testWidgets('a table that fits shows no cue and takes no focus', (
      tester,
    ) async {
      phoneSize(tester);
      await tester.pumpWidget(
        themed(_scaled(const HermesMarkdown(text: _narrowTable), 1)),
      );
      await tester.pump();
      expect(fades(), findsNothing);
      final focus = tester.widget<Focus>(
        find
            .descendant(of: find.byType(MdTable), matching: find.byType(Focus))
            .first,
      );
      expect(focus.canRequestFocus, isFalse);
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('keyboard reaches the last column at ${scale}x', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        phoneSize(tester);
        await tester.pumpWidget(
          themed(_scaled(const HermesMarkdown(text: _wideTable), scale)),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(fades(), findsOneWidget);

        // Screen readers hear that it scrolls and get scroll actions.
        final data = tester
            .getSemantics(find.byType(MdTable))
            .getSemanticsData();
        expect(data.hint, contains('scrolls sideways'));

        final screen = tester.getRect(find.byType(Scaffold));
        final last = find.textContaining('Not on Windows hosts');
        expect(tester.getRect(last).right, greaterThan(screen.right));

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.end);
        await tester.pumpAndSettle();
        final pos = tester.state<ScrollableState>(scrollable()).position;
        expect(pos.pixels, pos.maxScrollExtent);
        expect(tester.getRect(last).right, lessThanOrEqualTo(screen.right));
        // At the end only the leading edge fades.
        expect(tester.widgetList<Positioned>(fades()).map((p) => p.left), [
          -16,
        ]);

        await tester.sendKeyEvent(LogicalKeyboardKey.home);
        await tester.pumpAndSettle();
        expect(pos.pixels, 0);
        expect(tester.takeException(), isNull);
        handle.dispose();
      });
    }
  });
}
