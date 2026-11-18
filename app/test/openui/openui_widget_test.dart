import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/chat/models.dart';
import 'package:tove_chat/src/ui/interactive/interactive.dart';
import 'package:tove_chat/src/ui/interactive/ui_slider.dart';
import 'package:tove_chat/src/ui/openui/lang/parser.dart';
import 'package:tove_chat/src/ui/openui/library.dart';
import 'package:tove_chat/src/ui/openui/openui_block.dart';
import 'package:tove_chat/src/ui/openui/plain_text.dart';
import 'package:tove_chat/src/ui/shell/drawer_swipe.dart' show swipeHitInfo;
import 'package:tove_chat/src/ui/thread/messages.dart';

import '../interactive/round3_fixtures.dart';
import '../markdown/golden_harness.dart' show loadReplyFonts;

const compareUi = r'''root = Stack([title, grid, verdict, next])
title = Title("Aster 7 Pro vs Brio 11 Pro")
grid = Grid([a, b])
a = Card([Facts([Fact("Price", "$1,099"), Fact("Battery", "4,400 mAh"), Fact("Chip", "A19")]), ProsCons(["Best video"], ["Costs more"])], "Aster 7 Pro", "https://img.example.com/aster.jpg", "Best for video")
b = Card([Facts([Fact("Price", "$999"), Fact("Battery", "4,970 mAh"), Fact("Chip", "G6")]), ProsCons(["7 years of updates"], ["Slower chip"])], "Brio 11 Pro", "https://img.example.com/brio.jpg", "Best for AI")
verdict = Callout("Brio for value, Aster for video.", "tip", "Verdict")
next = Buttons([Button("Low-light camera?", @ToAssistant("Which has the better low-light camera?")), Button("Brio deals")])''';

const tripUi = r'''root = Stack([title, days])
title = Title("Three days in Munnar")
days = Tabs([d1, d2, d3])
d1 = Tab("Day 1", [Steps([Step("Tea museum", "See how tea is rolled.", "9:00 AM"), Step("Lunch by the lake", null, "12:30 PM"), Step("Dam and boating", "Book ahead.", "3:00 PM")])])
d2 = Tab("Day 2", [Steps([Step("Top Station sunrise", null, "6:00 AM"), Step("Spice garden walk", null, "11:00 AM")])])
d3 = Tab("Day 3", [Text("National park, then the drive back.")])''';

const dashboardUi = r'''root = Stack([status, gauges, services, chart])
status = Status("Homelab", "warn", "1 service degraded", "2 min ago")
gauges = Gauges([Gauge("CPU", 42), Gauge("RAM", 71, 100, "%", "warn"), Gauge("Disk", 58)])
services = Services([Service("Jellyfin", "ok", "38 ms"), Service("Immich", "warn", "820 ms", "Slow thumbnails"), Service("AdGuard", "ok", "4 ms")], "Services")
chart = Chart("line", ["Mon", "Tue", "Wed", "Thu", "Fri"], [Series("CPU %", [30, 45, 38, 52, 42])], "CPU this week", "%")''';

const recipeUi = r'''root = Stack([title, facts, scale, ing, method])
$serves = 2
title = Title("Masala chai")
facts = Facts([Fact("Time", "10 min"), Fact("Serves", "" + $serves)])
scale = Slider($serves, "Cups", 1, 6, 1)
ing = List(["Water: " + $serves * 150 + " ml", "Milk: " + $serves * 100 + " ml", "Tea: " + $serves + " tsp", "Ginger and cardamom"])
method = Steps([Step("Boil water with the spices", null, "3 min"), Step("Add tea and simmer", null, "2 min"), Step("Add milk, bring to a boil, strain")])''';

String fence(String ui, [String before = '']) =>
    '$before\n\n```openui\n$ui\n```\n';

Future<(List<String>, List<String>)> pumpUi(
  WidgetTester tester,
  String ui, {
  Brightness brightness = Brightness.light,
  double height = 2400,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(412, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final sent = <String>[];
  final opened = <String>[];
  await tester.pumpWidget(
    r3Frame(
      HermesUiScope(
        onSend: sent.add,
        onOpenLink: opened.add,
        child: AssistantMessage(
          message: reply(fence(ui, 'Here you go.')),
          onRetry: () {},
          onDelete: () {},
        ),
      ),
      brightness: brightness,
      desktop: false,
      textScale: textScale,
    ),
  );
  await tester.pump(const Duration(milliseconds: 900));
  return (sent, opened);
}

void main() {
  group('library', () {
    test('every reference UI parses with no errors', () {
      for (final ui in [compareUi, tripUi, dashboardUi, recipeUi]) {
        expect(isLegacyProgram(ui), isTrue);
        final r = parseProgram(ui, legacyLibrary);
        expect(r.root, isNotNull);
        expect(r.meta.errors.map((e) => '$e'), isEmpty);
        expect(r.meta.orphaned, isEmpty);
      }
    });

    test('the prompt section is small and lists every taught component', () {
      final p = toveOpenUiPrompt();
      for (final c in toveComponents) {
        expect(p.contains('\n${c.name}('), isTaught(c), reason: c.name);
      }
      // ~4 characters per token: about 3k tokens.
      expect(p.length, lessThan(12000));
      for (final legacy in ['hermes-ui', 'hermes-html', 'hermes-artifact']) {
        expect(p, isNot(contains(legacy)));
      }
    });

    test('server/openui-chat-prompt.md is the registry\'s prompt (regenerate '
        'with dart run tool/openui_prompt.dart)', () {
      expect(
        File('../server/openui-chat-prompt.md').readAsStringSync(),
        toveOpenUiPrompt(),
      );
    });

    test('plain text reads labels and values, never the DSL', () {
      final t = openUiPlainText(recipeUi);
      expect(t, contains('Masala chai'));
      expect(t, contains('Water: 300 ml'));
      expect(t, isNot(contains('Stack(')));
      expect(t, isNot(contains(r'$serves')));
    });

    test('unsafe sends are cleaned and bounded', () {
      expect(cleanSendText('hi\u202Ethere\n\nnow'), 'hi there now');
      expect(cleanSendText('x' * 400).length, OpenUiLimits.maxSendChars);
    });
  });

  group('rendering', () {
    testWidgets('all reference UIs render without exceptions', (tester) async {
      for (final ui in [compareUi, tripUi, dashboardUi, recipeUi]) {
        await pumpUi(tester, ui);
        expect(tester.takeException(), isNull);
      }
      expect(find.text('Three days in Munnar'), findsNothing);
    });

    testWidgets('a reply streams in chunks and renders as it goes',
        (tester) async {
      tester.view.physicalSize = const Size(412, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final full = fence(compareUi, 'Here you go.');
      var sawTitleEarly = false;
      for (var cut = 20; cut <= full.length; cut += 37) {
        final done = cut + 37 > full.length;
        final text = done ? full : full.substring(0, cut);
        await tester.pumpWidget(
          r3Frame(
            HermesUiScope(
              onSend: (_) {},
              child: AssistantMessage(
                message: reply(text).copyWith(
                  status: done ? MessageStatus.done : MessageStatus.streaming,
                ),
                onRetry: () {},
                onDelete: () {},
              ),
            ),
            brightness: Brightness.light,
            desktop: false,
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.takeException(), isNull, reason: 'cut $cut');
        if (!done && find.text('Aster 7 Pro vs Brio 11 Pro').evaluate().isNotEmpty) {
          sawTitleEarly = true;
        }
      }
      expect(sawTitleEarly, isTrue);
    });

    testWidgets('a button sends its visible message once', (tester) async {
      final (sent, _) = await pumpUi(tester, compareUi);
      await tester.ensureVisible(find.text('Low-light camera?'));
      await tester.tap(find.text('Low-light camera?'));
      await tester.pump();
      expect(sent, ['Which has the better low-light camera?']);
      await tester.tap(find.text('Brio deals'));
      await tester.pump();
      expect(sent, hasLength(1), reason: 'the group locks after one send');
    });

    testWidgets('@OpenUrl goes through the confirm hook; bad URLs never do',
        (tester) async {
      final (_, opened) = await pumpUi(
        tester,
        'root = Stack([Buttons([Button("Docs", @OpenUrl("https://example.com/docs")), '
        'Button("Bad", @OpenUrl("javascript:alert(1)"))])])',
      );
      await tester.tap(find.text('Docs'));
      await tester.tap(find.text('Bad'));
      await tester.pump();
      expect(opened, ['https://example.com/docs']);
    });

    testWidgets('a slider updates bound text locally', (tester) async {
      await pumpUi(tester, recipeUi);
      expect(find.textContaining('Water: 300 ml'), findsOneWidget);
      final slider = find.byType(UiSlider);
      await tester.ensureVisible(slider);
      await tester.drag(slider, const Offset(300, 0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Water: 900 ml'), findsOneWidget);
    });

    testWidgets('unknown components degrade to text; garbage falls back',
        (tester) async {
      await pumpUi(
        tester,
        'root = Stack([Text("kept"), Hologram("Visible fallback text")])',
      );
      expect(find.textContaining('kept'), findsOneWidget);
      expect(find.text('Visible fallback text'), findsOneWidget);

      await pumpUi(tester, 'this is not openui at all');
      expect(find.text("Interactive content couldn't be shown"), findsOneWidget);
    });

    testWidgets('a drag on the tab pills never starts the sidebar swipe',
        (tester) async {
      await pumpUi(tester, tripUi);
      final viewId = tester.view.viewId;
      for (final label in ['Day 1', 'Day 2', 'Day 3']) {
        final hit = swipeHitInfo(tester.getCenter(find.text(label)), viewId);
        expect(hit.excluded, isTrue, reason: label);
      }
      // Plain step text is still a normal swipe start.
      expect(
        swipeHitInfo(tester.getCenter(find.text('Tea museum')), viewId).excluded,
        isFalse,
      );
    });

    testWidgets('an empty corner header keeps the columns aligned',
        (tester) async {
      await pumpUi(
        tester,
        'root = Table(["", "Aster", "Brio"], '
        '[["Chip", "Alpha nine", "Gamma six"], ["Display", "Flat panel", "Curved panel"]])',
      );
      expect(tester.takeException(), isNull);
      double x(String t) => tester.getTopLeft(find.text(t)).dx;
      expect(x('Aster'), x('Alpha nine'));
      expect(x('Brio'), x('Gamma six'));
      expect(x('Chip'), lessThan(x('Aster')));
    });

    testWidgets('200% text does not overflow', (tester) async {
      for (final ui in [compareUi, tripUi, dashboardUi, recipeUi]) {
        await pumpUi(tester, ui, height: 6000, textScale: 2);
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('goldens', () {
    setUpAll(loadReplyFonts);
    final cases = {
      'compare': (compareUi, 1250.0),
      'trip': (tripUi, 560.0),
      'dashboard': (dashboardUi, 1150.0),
      'recipe': (recipeUi, 900.0),
    };
    for (final MapEntry(key: name, value: (ui, height)) in cases.entries) {
      for (final b in Brightness.values) {
        testWidgets('golden ${name}_${b.name}', (tester) async {
          await pumpUi(tester, ui, brightness: b, height: height);
          await settleImages(tester);
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byKey(goldenKey),
            matchesGoldenFile('goldens/openui_${name}_${b.name}.png'),
          );
        });
      }
    }
  });
}
