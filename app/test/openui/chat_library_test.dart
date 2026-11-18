// The OpenUI chat library (root Card) as Tove's only rich format: parsing
// with the official names and argument order, rendering, forms, card
// actions, follow-ups under the reply, Read aloud text, and round-9
// programs still drawn by the legacy set.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/ui/interactive/interactive.dart';
import 'package:tove_chat/src/ui/openui/lang/parser.dart';
import 'package:tove_chat/src/ui/openui/library.dart';
import 'package:tove_chat/src/ui/openui/plain_text.dart';
import 'package:tove_chat/src/ui/thread/messages.dart';

import '../interactive/round3_fixtures.dart';
import '../markdown/golden_harness.dart' show loadReplyFonts;

const compare = r'''root = Card([head, picks, specs, verdict, more])
head = CardHeader("Pixel 10 Pro vs iPhone 17 Pro", "For photos")
picks = CompositeCardBlock([a, b])
a = CompositeCardItem(null, ImageTextLarge("https://img.example.com/pixel.jpg", "Pixel", "Pixel 10 Pro", "Best zoom"), [TagBlock(["5x zoom", "7 years"])], {price: BoldText("text", "$999"), button: Button("Pick Pixel", @ToAssistant("I'll take the Pixel 10 Pro"))})
b = CompositeCardItem(null, ImageTextLarge("https://img.example.com/iphone.jpg", "iPhone", "iPhone 17 Pro", "Best video"), [TagBlock(["ProRes", "48 MP"])], {price: BoldText("text", "$1,099")})
specs = Table([Col("Spec", ["Main camera", "Zoom"]), Col("Pixel 10 Pro", ["50 MP", "5x"], "string"), Col("iPhone 17 Pro", ["48 MP", "5x"])])
verdict = Callout("success", "Verdict", "Pixel for stills, iPhone for video.")
more = FollowUpBlock([FollowUpItem("Which is better at night?"), FollowUpItem("Show prices in India")])''';

const dashboard = r'''root = Card([status, kpis, gauges, services, cpu, warn])
status = Status("Homelab", "warning", "1 service degraded", "just now")
kpis = OverviewCardBlock([k1, k2])
k1 = OverviewCardItem(null, IconText(Icon("server"), "info", null, "Containers"), MetricIndicatorInline("32", "running", {direction: "up", value: 3}))
k2 = OverviewCardItem(null, IconText(Icon("hard-drive"), "success", null, "Disk free"), MetricIndicatorInline("1.2 TB", "of 4 TB"))
gauges = Gauges([Gauge("CPU", 42), Gauge("RAM", 71, 100, "%", "warning")])
services = Services([Service("Jellyfin", "success", "38 ms"), Service("Immich", "warning", "820 ms", "Slow thumbnails", "Why is Immich slow?")], "Services")
cpu = LineChart(["Mon", "Tue", "Wed", "Thu", "Fri"], [Series("CPU %", [30, 45, 38, 52, 42])])
warn = Callout("warning", "Immich", "Thumbnail jobs are queued.")''';

const form = r'''root = Card([head, f])
head = CardHeader("Book a table")
f = Form("booking", btns, [c1, c2, c3])
c1 = FormControl("Name", Input("name", "Your name", "text", {required: true}))
c2 = FormControl("Guests", Chips("guests", "single", [ChipItem("2", "2"), ChipItem("4", "4")]))
c3 = FormControl("Seating", RadioGroup("seat", [RadioItem("Inside", "Quiet", "in"), RadioItem("Outside", "Garden", "out")]))
btns = Buttons([Button("Book", @ToAssistant("Book this table"), "primary")])''';

const tove = r'''root = Card([mail, plan, people, news])
mail = Email(["landlord@example.com"], "Leaking kitchen tap", "Hi Raj,\n\nThe kitchen tap is leaking. Could you have it fixed this week?\n\nThanks,\nSam")
plan = Checklist([ChecklistSection("Morning", ["Gym", "Breakfast"], "7:00 – 9:00", "health"), ChecklistSection("Deep work", ["Ship the parser"], "10:00 – 1:00", "focus")], "Tomorrow")
people = Entities([Entity("Sundar Pichai", "CEO of Google", "entity:Sundar_Pichai")])
news = News([Article("Google I/O recap", "https://news.example.com/io", "Example News", "May 20")])''';

const trip = r'''root = Card([head, days])
head = CardHeader("3 days in Jaipur")
days = Tabs([d1, d2])
d1 = TabItem("day1", "Day 1", [Steps([StepsItem("Amber Fort", "Go at 8 am to beat the crowds."), StepsItem("Lunch at LMB", "Try the ghewar.")])])
d2 = TabItem("day2", "Day 2", [ListBlock([ListItem("Hawa Mahal", "Morning light"), ListItem("City Palace", "Museum")])])''';

String fence(String ui, [String before = 'Here you go.']) =>
    '$before\n\n```openui\n$ui\n```\n';

Future<(List<String>, List<String>)> pumpUi(
  WidgetTester tester,
  String ui, {
  Brightness brightness = Brightness.light,
  double height = 3000,
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
          message: reply(fence(ui)),
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
  group('parsing', () {
    test('official names and argument order parse with no errors', () {
      for (final ui in [compare, dashboard, form, tove, trip]) {
        expect(isLegacyProgram(ui), isFalse);
        final r = parseProgram(ui, toveLibrary);
        expect(r.root, isNotNull);
        expect(
          r.meta.errors.map((e) => '$e'),
          isEmpty,
          reason: ui.split('\n').first,
        );
        expect(r.meta.orphaned, isEmpty);
      }
    });

    test('round-9 programs are recognised as legacy', () {
      expect(
        isLegacyProgram('root = Stack([Title("Hi"), Facts([Fact("a", "b")])])'),
        isTrue,
      );
      expect(
        isLegacyProgram('root = Card([CardHeader("Hi"), TextContent("x")])'),
        isFalse,
      );
      expect(isLegacyProgram('root = Card([Text("x")])'), isFalse);
    });

    test('Text without its variant still keeps the words', () {
      final r = parseProgram(
        'root = Card([CompositeCardBlock([CompositeCardItem(null, Text("Hello"))])])',
        toveLibrary,
      );
      expect(r.meta.errors, isEmpty);
    });

    test('the prompt matches OpenUI chat-library signatures', () {
      final p = toveOpenUiPrompt();
      for (final sig in [
        'TextContent(text: string, size?:',
        'Callout(variant: "info"|"warning"|"error"|"success"|"neutral", title: string, description: string)',
        'Table(columns: Col[])',
        'Col(label: string, data: (string|number)[], type?:',
        'Form(name: string, buttons: Buttons, fields?: FormControl[])',
        'Button(label: string, action?: Action, variant?: "primary"|"secondary"|"tertiary", type?:',
        'TabItem(value: string, trigger: string, content: Node[])',
        'StepsItem(title: string, details: string)',
        'ListItem(title: string, subtitle?: string, image?: {src, alt}, actionLabel?: string, action?: Action)',
        'CompositeCardItem(id?: string, header?:',
        'VisualCardItem(body: BoldText, id?: string, bgImageSrc?: string, tag?: Tag',
        'PieChart(labels: string[], values: number[], variant?: "pie"|"donut"',
      ]) {
        expect(p, contains(sig));
      }
    });
  });

  group('text', () {
    test('Read aloud uses labels and values', () {
      final t = openUiPlainText(compare);
      expect(t, contains('Pixel 10 Pro vs iPhone 17 Pro'));
      expect(t, contains('Main camera: 50 MP, 48 MP'));
      expect(t, contains('5x zoom, 7 years'));
      expect(t, contains('Verdict: Pixel for stills, iPhone for video.'));
      expect(t, contains(r'$999'));
      expect(t, isNot(contains('success')));
      expect(t, isNot(contains('https://')));
      expect(t, isNot(contains('Which is better at night?')));
    });

    test('ids, settings and pictures are skipped; emails read as emails', () {
      final t = openUiPlainText(trip);
      expect(t, contains('Day 1'));
      expect(t, isNot(contains('day1')));
      final m = openUiPlainText(tove);
      expect(m, contains('Email to landlord@example.com'));
      expect(m, contains('Subject: Leaking kitchen tap'));
      expect(m, isNot(contains('entity:')));
      expect(m, contains('Morning (7:00 – 9:00): Gym, Breakfast'));
    });

    test('charts read their values', () {
      expect(openUiPlainText(dashboard), contains('Line chart: CPU %: Mon 30'));
    });

    test('FollowUpBlock becomes the reply suggestions', () {
      expect(extractSuggestions(fence(compare)), [
        'Which is better at night?',
        'Show prices in India',
      ]);
      expect(openUiFollowUps(dashboard), isEmpty);
    });
  });

  group('rendering', () {
    testWidgets('every sample renders without exceptions, 1× and 200%', (
      tester,
    ) async {
      for (final ui in [compare, dashboard, form, tove, trip]) {
        await pumpUi(tester, ui);
        expect(tester.takeException(), isNull);
        await pumpUi(tester, ui, height: 8000, textScale: 2);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('components show their words; follow-ups are not inline', (
      tester,
    ) async {
      await pumpUi(tester, compare);
      expect(find.text('Pixel 10 Pro vs iPhone 17 Pro'), findsOneWidget);
      expect(find.text('5x zoom'), findsOneWidget);
      expect(find.text('Verdict'), findsOneWidget);
      expect(find.text('Which is better at night?'), findsNothing);
    });

    testWidgets('a form checks required fields, then sends label and values', (
      tester,
    ) async {
      final (sent, _) = await pumpUi(tester, form);
      await tester.tap(find.text('Book'));
      await tester.pump();
      expect(sent, isEmpty);
      expect(find.text('Required'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Asha');
      await tester.tap(find.text('4'));
      await tester.tap(find.text('Outside'));
      await tester.pump();
      await tester.tap(find.text('Book'));
      await tester.pump();
      expect(sent, ['Book this table — Name: Asha; Guests: 4; Seating: out']);
    });

    testWidgets('a card button sends once; Services rows ask', (tester) async {
      final (sent, _) = await pumpUi(tester, compare);
      await tester.ensureVisible(find.text('Pick Pixel'));
      await tester.tap(find.text('Pick Pixel'));
      await tester.pump();
      expect(sent, ["I'll take the Pixel 10 Pro"]);
    });

    testWidgets('Email, Checklist, Entities and News use Tove widgets', (
      tester,
    ) async {
      await pumpUi(tester, tove);
      expect(find.text('Leaking kitchen tap'), findsWidgets);
      expect(find.text('Gym'), findsOneWidget);
      expect(find.text('Sundar Pichai'), findsOneWidget);
      expect(
        find.textContaining('Google I/O recap', findRichText: true),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('tabs switch panes', (tester) async {
      await pumpUi(tester, trip);
      expect(find.text('Amber Fort'), findsOneWidget);
      await tester.tap(find.text('Day 2'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Hawa Mahal'), findsOneWidget);
    });

    testWidgets('a round-9 program still renders with the legacy set', (
      tester,
    ) async {
      await pumpUi(
        tester,
        'root = Stack([Title("Old reply"), Facts([Fact("Price", "\$10")])])',
      );
      expect(find.text('Old reply'), findsOneWidget);
      expect(find.text('Price'), findsOneWidget);
    });
  });

  // Eight real gpt-6.1-terra replies to the OpenUI-only prompt (A/B of 18
  // November 2026; the user's name swapped out). All parse with no errors.
  group('real replies', () {
    setUpAll(loadReplyFonts);
    const names = [
      'compare',
      'trip',
      'recipe',
      'health',
      'person',
      'products',
      'day',
      'email',
    ];
    final fenceRe = RegExp(r'```openui\n([\s\S]*?)\n```');
    test('every fence parses with the chat library and no errors', () {
      for (final n in names) {
        final text = File('test/openui/fixtures/replies/$n.md')
            .readAsStringSync();
        for (final m in fenceRe.allMatches(text)) {
          expect(isLegacyProgram(m[1]!), isFalse, reason: n);
          final r = parseProgram(m[1]!, toveLibrary);
          expect(r.meta.errors.map((e) => '$e'), isEmpty, reason: n);
        }
      }
    });
    for (final n in names) {
      for (final b in Brightness.values) {
        testWidgets('golden reply_${n}_${b.name}', (tester) async {
          tester.view.physicalSize = const Size(412, 9000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final text = File('test/openui/fixtures/replies/$n.md')
              .readAsStringSync();
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
            matchesGoldenFile('goldens/reply_${n}_${b.name}.png'),
          );
        });
      }
    }
  });
}
