// Places, Map, Quiz and LocationButton (Tove OpenUI components for local,
// health and practice answers): rendering, actions, selection sync, saved
// quiz answers, Read aloud text, and goldens of a local answer and a quiz
// at question 3 of 6 (light and dark).

import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/settings/prefs_store.dart';
import 'package:tove_chat/src/ui/interactive/interactive.dart';
import 'package:tove_chat/src/ui/markdown/links.dart';
import 'package:tove_chat/src/ui/openui/lang/parser.dart';
import 'package:tove_chat/src/ui/openui/library.dart';
import 'package:tove_chat/src/ui/openui/plain_text.dart';
import 'package:tove_chat/src/ui/openui/places_view.dart';
import 'package:tove_chat/src/ui/openui/quiz_view.dart';
import 'package:tove_chat/src/ui/thread/messages.dart';

import '../interactive/round3_fixtures.dart';
import '../markdown/golden_harness.dart' show loadReplyFonts;

String fixture(String name) =>
    File('test/openui/fixtures/replies/$name.md').readAsStringSync();

final _fence = RegExp(r'```openui\n([\s\S]*?)\n```');

Future<(List<String>, List<String>)> pumpReply(
  WidgetTester tester,
  String text, {
  Brightness brightness = Brightness.light,
  ChecklistStore? store,
  String id = 'msg_r3',
  double height = 3000,
}) async {
  tester.view.physicalSize = Size(412, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final sent = <String>[];
  final opened = <String>[];
  Widget child = HermesUiScope(
    onSend: sent.add,
    onOpenLink: opened.add,
    stateKey: id,
    child: AssistantMessage(
      message: reply(text, id: id),
      onRetry: () {},
      onDelete: () {},
    ),
  );
  if (store != null) child = ChecklistScope(store: store, child: child);
  await tester.pumpWidget(
    r3Frame(child, brightness: brightness, desktop: false),
  );
  await tester.pump(const Duration(milliseconds: 900));
  return (sent, opened);
}

Future<void> answer(WidgetTester tester, String option) async {
  await tester.tap(find.bySemanticsLabel(RegExp('^$option, option ')).first);
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('parsing', () {
    test('the fixtures parse with no errors', () {
      for (final n in ['local', 'quiz']) {
        for (final m in _fence.allMatches(fixture(n))) {
          final r = parseProgram(m[1]!, toveLibrary);
          expect(r.meta.errors.map((e) => '$e'), isEmpty, reason: n);
        }
      }
    });

    test('the prompt teaches Places, Map, Quiz and LocationButton', () {
      final p = toveOpenUiPrompt();
      for (final name in [
        'Places(',
        'Place(id: string, name: string',
        'Map(items: (Place|Pin)[]',
        'Quiz(title: string, questions: Question[]',
        'Question(text: string, options: string[], answer?: number',
        'LocationButton(',
      ]) {
        expect(p, contains(name));
      }
      expect(p, isNot(contains('scores?')));
    });

    test('quiz message lists every answer compactly', () {
      const qs = [
        OuiQuestion(text: 'A?', options: ['No', 'Yes']),
        OuiQuestion(text: 'B?', options: ['No', 'Yes']),
      ];
      expect(
        quizMessage('Check', qs, {0: 1, 1: 0}),
        'Check answers: 1 Yes; 2 No',
      );
      const practice = [
        OuiQuestion(text: 'Hola?', options: ['Hello', 'Bye'], answer: 0),
        OuiQuestion(text: 'Adiós?', options: ['Hello', 'Bye'], answer: 1),
      ];
      expect(
        quizMessage('Spanish', practice, {0: 0, 1: 0}),
        'Spanish: 1 of 2 correct. Missed: Q2 (I said Hello; answer Bye)',
      );
    });

    test('tel: and geo: links are allowed and checked', () {
      expect(safeLink('tel:+910000000001'), isNotNull);
      expect(safeLink('tel:call-me-maybe'), isNull);
      expect(safeLink('geo:13.03,80.27?q=13.03,80.27(Clinic)'), isNotNull);
      expect(safeLink('geo:somewhere'), isNull);
      expect(safeLink('javascript:alert(1)'), isNull);
      expect(
        linkHost(Uri.parse('geo:13.03,80.27?q=13.03,80.27(Sample%20Clinic)')),
        'Sample Clinic',
      );
    });
  });

  group('text', () {
    test('Read aloud describes places, the map and the quiz', () {
      final local = openUiPlainText(_fence.firstMatch(fixture('local'))![1]!);
      expect(
        local,
        contains(
          '1. Sample Mind Clinic, Adult ADHD assessment · ₹3,500 (clinic '
          'site), rated 4.8 · 120 reviews on Practo',
        ),
      );
      expect(
        local,
        contains(
          'Map of 3 places: Sample Mind Clinic, Example Neuro Centre, '
          'Placeholder Health Hospital',
        ),
      );
      expect(local, isNot(contains('place:')));
      final quiz = openUiPlainText(_fence.firstMatch(fixture('quiz'))![1]!);
      expect(quiz, contains('Quiz: Sleep habits check, 6 questions.'));
      expect(
        quiz,
        contains(
          '1. How often do you have trouble falling asleep? (Never, Rarely, '
          'Sometimes, Often, Very often)',
        ),
      );
      expect(quiz, contains('Screening, not a diagnosis.'));
      expect(quiz, contains('Source: Sample Sleep Scale (example)'));
    });
  });

  group('places', () {
    testWidgets('cards show bridge details, sourced ratings and actions', (
      tester,
    ) async {
      final (sent, opened) = await pumpReply(tester, fixture('local'));
      expect(tester.takeException(), isNull);
      expect(find.text('Sample Mind Clinic'), findsOneWidget);
      expect(find.text('Psychiatry · Example Street · 0.4 km'), findsOneWidget);
      expect(find.text('4.8 · 120 reviews on Practo'), findsOneWidget);
      expect(find.textContaining('Open now'), findsOneWidget);
      expect(find.textContaining('Closed now'), findsOneWidget);
      // The third place has no sourced rating: none is shown.
      expect(find.textContaining('on Practo'), findsOneWidget);
      expect(find.text('Call'), findsNWidgets(3));
      expect(find.text('Website'), findsNWidgets(2));
      await tester.tap(find.text('Call').first);
      await tester.tap(find.text('Website').first);
      await tester.tap(find.text('Directions').first);
      expect(opened[0], 'tel:+910000000001');
      expect(opened[1], 'https://clinic.example/adhd');
      // Android: the user's maps app.
      expect(
        opened[2],
        'geo:13.0339,80.2686?q=13.0339,80.2686(Sample%20Mind%20Clinic)',
      );
      expect(sent, isEmpty);
    });

    testWidgets('a pin tap selects its card and a card tap its pin', (
      tester,
    ) async {
      await pumpReply(tester, fixture('local'));
      expect(
        find.bySemanticsLabel('Pin 2, Example Neuro Centre'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'^Map of 3 places')),
        findsOneWidget,
      );
      await tester.tap(find.bySemanticsLabel('Pin 2, Example Neuro Centre'));
      await tester.pump(const Duration(milliseconds: 400));
      bool selected(String label) =>
          tester
              .getSemantics(
                find.bySemanticsLabel(RegExp('^${RegExp.escape(label)}')),
              )
              .flagsCollection
              .isSelected ==
          Tristate.isTrue;
      expect(selected('Place 2 of the list: Example Neuro Centre'), isTrue);
      expect(selected('Place 1 of the list: Sample Mind Clinic'), isFalse);
      await tester.tap(find.text('Placeholder Health Hospital'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(selected('Pin 3, Placeholder Health Hospital'), isTrue);
      expect(selected('Pin 1, Sample Mind Clinic'), isFalse);
    });

    testWidgets('a web-found place without an id still gets its links', (
      tester,
    ) async {
      final (_, opened) = await pumpReply(
        tester,
        '```openui\nroot = Card([Places([Place("", "Web Clinic", "Sample '
        'Road", "Found on the web", "4.2", null, "+91 00000 00009", '
        '"https://web-clinic.example/")])])\n```',
      );
      expect(find.text('Web Clinic'), findsOneWidget);
      expect(find.textContaining('4.2'), findsNothing); // no source, no rating
      await tester.tap(find.text('Call'));
      await tester.tap(find.text('Directions'));
      expect(opened[0], 'tel:+910000000009');
      expect(
        opened[1],
        contains('openstreetmap.org/search?query=Web%20Clinic'),
      );
    });
  });

  group('quiz', () {
    testWidgets('one question at a time, Back, then one message', (
      tester,
    ) async {
      final (sent, _) = await pumpReply(tester, fixture('quiz'));
      expect(find.text('Question 1 of 6'), findsOneWidget);
      expect(find.text('0% complete'), findsOneWidget);
      expect(
        find.text('How often do you have trouble falling asleep?'),
        findsOneWidget,
      );
      await answer(tester, 'Often');
      expect(find.text('Question 2 of 6'), findsOneWidget);
      expect(find.text('17% complete'), findsOneWidget);
      await tester.tap(find.text('Back'));
      await tester.pump();
      expect(find.text('Question 1 of 6'), findsOneWidget);
      await answer(tester, 'Sometimes'); // changes the answer, moves on
      for (final o in ['Rarely', 'Often', 'Very often', 'Never', 'Sometimes']) {
        await answer(tester, o);
      }
      expect(find.text('All 6 answered'), findsOneWidget);
      expect(sent, isEmpty); // nothing sent per question
      await tester.tap(find.text('Send my answers'));
      await tester.pump();
      expect(sent, [
        'Sleep habits check answers: 1 Sometimes; 2 Rarely; 3 Often; '
            '4 Very often; 5 Never; 6 Sometimes',
      ]);
      expect(find.text('Answers sent'), findsOneWidget);
      expect(find.text('Source: Sample Sleep Scale (example)'), findsOneWidget);
    });

    testWidgets('answers survive leaving and returning', (tester) async {
      final store = ChecklistStore(prefs: MemoryPrefsStore());
      await pumpReply(tester, fixture('quiz'), store: store);
      await answer(tester, 'Often');
      await answer(tester, 'Rarely');
      await tester.pumpWidget(const SizedBox());
      await pumpReply(tester, fixture('quiz'), store: store);
      expect(find.text('Question 3 of 6'), findsOneWidget);
      expect(find.text('33% complete'), findsOneWidget);
    });

    testWidgets('practice questions show right or wrong and a score', (
      tester,
    ) async {
      final (sent, _) = await pumpReply(
        tester,
        '```openui\nroot = Card([q])\nq = Quiz("Spanish greetings", '
        '[Question("Hola means…", ["Hello", "Goodbye"], 0, "Hola is hello."), '
        'Question("Adiós means…", ["Hello", "Goodbye"], 1)])\n```',
      );
      await answer(tester, 'Goodbye');
      expect(find.text('Hola is hello.'), findsOneWidget);
      expect(find.text('Question 1 of 2'), findsOneWidget); // waits for Next
      await tester.tap(find.text('Next'));
      await tester.pump();
      await answer(tester, 'Goodbye');
      await tester.tap(find.text('Review'));
      await tester.pump();
      expect(find.text('1 of 2 correct'), findsOneWidget);
      await tester.tap(find.text('Send my results'));
      await tester.pump();
      expect(
        sent.single,
        startsWith('Spanish greetings: 1 of 2 correct. Missed: Q1'),
      );
    });

    testWidgets('options are big, labelled buttons', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpReply(tester, fixture('quiz'));
      final option = find.bySemanticsLabel('Often, option 4 of 5');
      expect(option, findsOneWidget);
      expect(tester.getSize(option).height, greaterThanOrEqualTo(48));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      handle.dispose();
    });
  });

  testWidgets('LocationButton is hidden without a location service', (
    tester,
  ) async {
    await pumpReply(
      tester,
      '```openui\nroot = Card([TextContent("Where are you?"), LocationButton()])\n```',
    );
    expect(find.byType(OuiLocationButton), findsOneWidget);
    expect(find.text('Use my location'), findsNothing);
  });

  group('goldens', () {
    setUpAll(loadReplyFonts);
    for (final b in Brightness.values) {
      testWidgets('golden reply_local_${b.name}', (tester) async {
        await pumpReply(tester, fixture('local'), brightness: b, height: 2400);
        await settleImages(tester);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/reply_local_${b.name}.png'),
        );
      });
      testWidgets('golden reply_quiz_q3_${b.name}', (tester) async {
        await pumpReply(tester, fixture('quiz'), brightness: b, height: 1400);
        await answer(tester, 'Often');
        await answer(tester, 'Sometimes');
        expect(find.text('Question 3 of 6'), findsOneWidget);
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/reply_quiz_q3_${b.name}.png'),
        );
      });
    }
  });
}
