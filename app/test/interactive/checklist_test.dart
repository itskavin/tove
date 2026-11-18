import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/settings/prefs_store.dart';
import 'package:tove_chat/src/ui/interactive/interactive.dart';
import 'package:tove_chat/src/ui/interactive/ui_checklist.dart';
import 'package:tove_chat/src/ui/markdown/hermes_markdown.dart';
import 'package:tove_chat/src/ui/thread/messages.dart';

import '../markdown/golden_harness.dart' show loadReplyFonts;
import 'round3_fixtures.dart';

/// A plan reply in the reference's shape: a big title, a muted date line,
/// a lead paragraph, the checklist, then bold "label:" paragraphs.
const planReply = '''# Your Monday game plan

<small>16 November · Starting at 11:30 AM</small>

Your calendar is clear for the rest of today. I'd split the day into three simple phases.

```hermes-ui
{"v":1,"type":"checklist","sections":[
 {"title":"Deep work","time":"11:30 AM – 2:30 PM","icon":"focus","items":["Work on Tove, your AI assistant","Finish one major feature","Have lunch and take a break"]},
 {"title":"Business & career","time":"3:00 PM – 7:00 PM","icon":"work","items":["Review the side project","Send two follow-up emails","Clear the homelab to-do list"]},
 {"title":"Reset & recharge","time":"7:00 PM – 11:00 PM","icon":"rest","items":["Walk for 30 minutes","Review today's progress","Plan tomorrow and sleep by 11 PM"]}]}
```

**Today's rule:** Finish before starting something new. Keep phone unlocks under control and avoid switching between projects.

I've made Tove the main priority based on your recent chats. Everything else is secondary.
''';

String _block(String reply) =>
    RegExp(r'```hermes-ui\n([\s\S]*?)\n```').firstMatch(reply)![1]!;

UiChecklist get _plan =>
    parseHermesUi(_block(planReply)).element! as UiChecklist;

void main() {
  group('parse', () {
    test('sections, times, icons; strings or {label, done} items', () {
      final p = _plan;
      expect(p.sections, hasLength(3));
      expect(p.total, 9);
      expect(p.sections.first.title, 'Deep work');
      expect(p.sections.first.time, '11:30 AM – 2:30 PM');
      expect(p.sections.first.icon, 'focus');
      final flat =
          parseHermesUi(
                jsonEncode({
                  'v': 1,
                  'type': 'plan',
                  'items': [
                    'Buy milk',
                    {'label': 'Call the bank', 'done': true},
                  ],
                }),
              ).element!
              as UiChecklist;
      expect(flat.sections.single.title, isNull);
      expect(flat.sections.single.items.last.done, isTrue);
      expect(flat.plainText, 'To do: Buy milk\nDone: Call the bank');
    });

    test('a model\'s own section numbers are not doubled', () {
      UiChecklist parse(List<String> titles, {bool? numbered}) =>
          parseHermesUi(
                jsonEncode({
                  'v': 1,
                  'type': 'checklist',
                  'numbered': ?numbered,
                  'sections': [
                    for (final t in titles)
                      {
                        'title': t,
                        'items': ['x'],
                      },
                  ],
                }),
              ).element!
              as UiChecklist;
      final p = parse(['1. Finish the workday', '2) Gym', 'Step 3: Lunch']);
      expect(p.sections.map((s) => s.title), [
        'Finish the workday',
        'Gym',
        'Lunch',
      ]);
      expect(p.plainText, startsWith('1. Finish the workday\n'));
      // A title that is only a number, or a year, keeps its text.
      expect(parse(['2.']).sections.single.title, '2.');
      expect(parse(['2026 goals']).sections.single.title, '2026 goals');
      // Unnumbered lists keep the model's own numbers.
      expect(
        parse(['1. Wake up'], numbered: false).sections.single.title,
        '1. Wake up',
      );
    });

    test('limits: 1–8 sections, 1–12 items each, 40 in all', () {
      String block(Object sections) =>
          jsonEncode({'v': 1, 'type': 'checklist', 'sections': sections});
      expect(parseHermesUi(block([])).ok, isFalse);
      expect(
        parseHermesUi(
          block([
            {'items': List.filled(13, 'x')},
          ]),
        ).ok,
        isFalse,
      );
      expect(
        parseHermesUi(
          block([
            for (var i = 0; i < 4; i++) {'items': List.filled(11, 'x')},
          ]),
        ).error,
        contains('40'),
      );
      expect(
        parseHermesUi(
          block([
            {'items': 'x'},
          ]),
        ).ok,
        isFalse,
      );
    });

    test('unknown icon names fall back to the list icon', () {
      expect(UiChecklistView.iconFor('nope'), Icons.checklist_rounded);
      expect(UiChecklistView.iconFor('rest'), Icons.bedtime_outlined);
    });
  });

  group('store', () {
    test('saves locally, keeps the newest 40 lists, merges by time', () async {
      final prefs = MemoryPrefsStore();
      var now = 1000;
      final store = ChecklistStore(
        prefs: prefs,
        clock: () => DateTime.fromMillisecondsSinceEpoch(now++),
      );
      await Future<void>.delayed(Duration.zero);
      store.setDone('m1#0', {'0.1'});
      for (var i = 0; i < 45; i++) {
        store.setDone('x$i#0', {'0.0'});
      }
      await Future<void>.delayed(Duration.zero);
      expect(store.doneFor('m1#0'), isNull, reason: 'oldest dropped');
      expect(store.doneFor('x44#0'), {'0.0'});
      final saved = jsonDecode(prefs.values[ChecklistStore.prefsKey]!) as Map;
      expect(saved, hasLength(ChecklistStore.maxLists));

      // A newer copy from another device wins; an older one does not.
      store.applySynced({
        ChecklistStore.syncKey: {
          'x44#0': {
            'd': ['0.0', '1.2'],
            't': 999999,
          },
          'x43#0': {'d': <String>[], 't': 1},
        },
      });
      expect(store.doneFor('x44#0'), {'0.0', '1.2'});
      expect(store.doneFor('x43#0'), {'0.0'});

      // A new store reads the local copy.
      final again = ChecklistStore(prefs: prefs);
      await Future<void>.delayed(Duration.zero);
      expect(again.doneFor('x44#0'), {'0.0', '1.2'});
    });
  });

  group('widget', () {
    setUpAll(loadReplyFonts);

    Future<ChecklistStore> pump(
      WidgetTester tester, {
      ChecklistStore? store,
      double textScale = 1,
      Brightness brightness = Brightness.dark,
    }) async {
      final s = store ?? ChecklistStore(prefs: MemoryPrefsStore());
      tester.view.physicalSize = const Size(412, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        r3Frame(
          ChecklistScope(
            store: s,
            child: HermesUiScope(
              stateKey: 'm1',
              onSend: (_) {},
              onSelectionHaptic: () {},
              child: HermesMarkdown(text: planReply),
            ),
          ),
          brightness: brightness,
          desktop: false,
          textScale: textScale,
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      return s;
    }

    testWidgets('tapping ticks an item, updates the progress and persists '
        'per message', (tester) async {
      final handle = tester.ensureSemantics();
      final store = await pump(tester);
      expect(find.text('0/9', findRichText: true), findsNothing);
      expect(find.textContaining('0/9', findRichText: true), findsOneWidget);
      final item = find.text('Finish one major feature');
      expect(
        tester.getSemantics(item),
        matchesSemantics(
          label: 'Finish one major feature',
          hasCheckedState: true,
          isChecked: false,
          hasTapAction: true,
        ),
      );
      await tester.tap(item);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('1/9', findRichText: true), findsOneWidget);
      expect(
        tester.getSemantics(item),
        matchesSemantics(
          label: 'Finish one major feature',
          hasCheckedState: true,
          isChecked: true,
          hasTapAction: true,
        ),
      );
      expect(store.doneFor('m1#0'), {'0.1'});
      // Rebuilt from history (a new widget tree): the tick is still there.
      await tester.pumpWidget(const SizedBox());
      await pump(tester, store: store);
      expect(find.textContaining('1/9', findRichText: true), findsOneWidget);
      // Untick.
      await tester.tap(find.text('Finish one major feature'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(store.doneFor('m1#0'), isEmpty);
      handle.dispose();
    });

    testWidgets('all done: the header says so', (tester) async {
      final store = ChecklistStore(prefs: MemoryPrefsStore());
      await tester.pump();
      store.setDone('m1#0', {
        for (var i = 0; i < 3; i++)
          for (var j = 0; j < 3; j++) '$i.$j',
      });
      await pump(tester, store: store);
      expect(find.textContaining('9/9', findRichText: true), findsOneWidget);
      expect(
        find.textContaining('All done', findRichText: true),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    });

    testWidgets('200% text: no overflow, 48 dp rows', (tester) async {
      await pump(tester, textScale: 2);
      expect(tester.takeException(), isNull);
      final row = find.ancestor(
        of: find.text('Walk for 30 minutes'),
        matching: find.byType(InkWell),
      );
      expect(tester.getSize(row.first).height, greaterThanOrEqualTo(48));
    });

    testWidgets('while streaming: a checklist-shaped skeleton', (tester) async {
      tester.view.physicalSize = const Size(412, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final partial = planReply.substring(0, planReply.indexOf('Business'));
      await tester.pumpWidget(
        r3Frame(
          StreamingMarkdown(text: partial, smoothReveal: false),
          brightness: Brightness.dark,
          desktop: false,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('ui-checklist-skeleton')),
        findsOneWidget,
      );
      expect(find.textContaining('"v":1'), findsNothing);
    });
  });

  group('goldens', () {
    setUpAll(loadReplyFonts);
    for (final b in Brightness.values) {
      for (final partly in [false, true]) {
        final tag = '${partly ? 'partly_done' : 'empty'}_${b.name}';
        testWidgets('golden checklist $tag', (tester) async {
          final store = ChecklistStore(prefs: MemoryPrefsStore());
          await tester.pump();
          if (partly) store.setDone('m1#0', {'0.0', '0.1', '0.2', '1.0'});
          tester.view.physicalSize = const Size(412, 1300);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            r3Frame(
              ChecklistScope(
                store: store,
                child: HermesUiScope(
                  stateKey: 'm1',
                  onSend: (_) {},
                  child: AssistantMessage(
                    message: reply(planReply),
                    onRetry: () {},
                    onDelete: () {},
                  ),
                ),
              ),
              brightness: b,
              desktop: false,
            ),
          );
          await tester.pump(const Duration(milliseconds: 600));
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byKey(goldenKey),
            matchesGoldenFile('goldens/checklist_$tag.png'),
          );
        });
      }
    }
  });
}
