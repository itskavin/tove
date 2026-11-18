import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/live/live_content.dart';
import 'package:tove_chat/src/ui/live/live_link_cards.dart';
import 'package:tove_chat/src/ui/live/live_panel.dart';
import 'package:tove_chat/src/ui/thread/follow_scroll.dart';
import 'package:material_ui/material_ui.dart';

import '../ui/test_harness.dart';

String _para(int i) =>
    'Paragraph $i explains one more step of the storage check in detail, '
    'with enough words to wrap over a few lines on a phone.';

String _long(int n) => List.generate(n, _para).join('\n\n');

void main() {
  setUpAll(loadAppFonts);
  late FollowScrollController scroll;
  setUp(() => scroll = FollowScrollController());
  tearDown(() => scroll.dispose());

  Widget panel(
    LiveContent c, {
    VoidCallback? onCollapse,
    ValueChanged<LiveSite>? onOpenSite,
    LiveBlockBuilder? blocks,
  }) => themed(
    Scaffold(
      body: LivePanel(
        content: c,
        scroll: scroll,
        topInset: 72,
        fadeStart: 760,
        fadeEnd: 835,
        bottomPadding: 200,
        onCollapse: onCollapse,
        onOpenSite: onOpenSite,
        blockBuilder: blocks,
      ),
    ),
  );

  LiveContent answer(String text, {bool streaming = true}) => LiveContent(
    id: 'msg-1',
    text: text,
    time: DateTime(2026),
    streaming: streaming,
  );

  testWidgets(
    'sources are readable rows, expand, and open their exact URL at 200% text',
    (tester) async {
      phoneSize(tester);
      final opened = <Uri>[];
      final sites = List.generate(
        5,
        (i) => LiveSite(
          uri: Uri.parse('https://docs.example.org/guide-$i'),
          title: 'Guide $i to storage and reliable backups',
          host: 'docs.example.org',
        ),
      );
      await tester.pumpWidget(
        themed(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: LiveSiteCards(
                    sites: sites,
                    onOpen: (s) => opened.add(s.uri),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(LiveSiteCard), findsNWidgets(3));
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Show all 5 sources'));
      await tester.tap(find.text('Show all 5 sources'));
      await tester.pump();
      expect(find.byType(LiveSiteCard), findsNWidgets(5));
      await tester.ensureVisible(find.byType(LiveSiteCard).last);
      await tester.tap(find.byType(LiveSiteCard).last);
      expect(opened.single, sites.last.uri);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('follows the stream, and stops when the user scrolls up', (
    tester,
  ) async {
    phoneSize(tester);
    // One app; the content changes underneath it, as in live mode.
    final content = ValueNotifier(answer(_para(0)));
    addTearDown(content.dispose);
    await tester.pumpWidget(
      themed(
        Scaffold(
          body: ValueListenableBuilder<LiveContent>(
            valueListenable: content,
            builder: (context, c, _) => LivePanel(
              content: c,
              scroll: scroll,
              topInset: 72,
              fadeStart: 760,
              fadeEnd: 835,
              bottomPadding: 200,
            ),
          ),
        ),
      ),
    );
    for (var n = 2; n <= 24; n += 2) {
      content.value = answer(_long(n));
      await tester.pump(const Duration(milliseconds: 400));
    }
    final p = scroll.position;
    expect(p.maxScrollExtent, greaterThan(800));
    expect(p.maxScrollExtent - p.pixels, lessThanOrEqualTo(160));

    // The reader drags back up: growth no longer moves the text.
    await tester.drag(
      find.byKey(const ValueKey('live-panel-scroll')),
      const Offset(0, 600),
    );
    await tester.pump(const Duration(milliseconds: 500));
    final reading = scroll.position.pixels;
    expect(scroll.position.maxScrollExtent - reading, greaterThan(160));
    content.value = answer(_long(30));
    await tester.pump(const Duration(milliseconds: 400));
    expect(scroll.position.pixels, reading);

    // Done streaming: the full text stays.
    content.value = answer(_long(30), streaming: false);
    await tester.pump(const Duration(seconds: 1));
    await tester.drag(
      find.byKey(const ValueKey('live-panel-scroll')),
      const Offset(0, -6000),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('Paragraph 29', findRichText: true), findsOne);
  });

  testWidgets('link cards open through the callback', (tester) async {
    phoneSize(tester);
    final opened = <Uri>[];
    await tester.pumpWidget(
      panel(
        answer(
          'Two guides: [ZFS tuning](https://openzfs.github.io/tuning) and '
          'https://example.org/disk-usage-guide.html',
          streaming: false,
        ),
        onOpenSite: (s) => opened.add(s.uri),
      ),
    );
    await tester.pump();
    expect(find.text('Sources'), findsOneWidget);
    expect(find.byType(LiveSiteCard), findsNWidgets(2));
    await tester.tap(
      find.bySemanticsLabel('Open ZFS tuning, openzfs.github.io'),
    );
    await tester.tap(
      find.bySemanticsLabel('Open Disk usage guide, example.org'),
    );
    expect(opened.map((u) => u.toString()), [
      'https://openzfs.github.io/tuning',
      'https://example.org/disk-usage-guide.html',
    ]);
  });

  testWidgets('without a callback a card uses the in-app opener', (
    tester,
  ) async {
    phoneSize(tester);
    final opened = <Uri>[];
    final old = liveSiteOpener;
    liveSiteOpener = (u) async {
      opened.add(u);
      return true;
    };
    addTearDown(() => liveSiteOpener = old);
    await tester.pumpWidget(
      themed(
        Scaffold(
          body: Center(
            child: SizedBox(
              width: 216,
              height: 92,
              child: LiveSiteCard(
                site: LiveSite(
                  uri: Uri.parse('https://example.com/a'),
                  title: 'A',
                  host: 'example.com',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(LiveSiteCard));
    expect(opened.single.host, 'example.com');
  });

  testWidgets('a running task shows its request and a working line; hide', (
    tester,
  ) async {
    phoneSize(tester);
    var hidden = 0;
    await tester.pumpWidget(
      panel(
        LiveContent(
          id: 'task-a',
          text: '',
          time: DateTime(2026),
          streaming: true,
          kind: LiveContentKind.task,
          title: 'check the disk on NAS-01',
        ),
        onCollapse: () => hidden++,
        blocks: (context, c) => const Text('interactive hook'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Task running'), findsOneWidget);
    expect(find.text('check the disk on NAS-01'), findsOneWidget);
    expect(find.text('Working on it…'), findsOneWidget);
    expect(find.text('interactive hook'), findsOneWidget);
    await tester.tap(find.byTooltip('Hide'));
    expect(hidden, 1);
  });
}
