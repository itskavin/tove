import 'dart:ui' show SemanticsAction;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/ui/composer/composer.dart';
import 'package:tove_chat/src/ui/composer/effort_slider.dart';
import 'package:tove_chat/src/ui/feedback.dart';
import 'package:material_ui/material_ui.dart';

import 'test_harness.dart';

class _Sink implements FeedbackSink {
  final haptics = <Haptic>[];
  final cues = <Cue>[];
  @override
  void haptic(Haptic h) => haptics.add(h);
  @override
  void cue(Cue c) => cues.add(c);
}

void main() {
  late TextEditingController text;
  late FocusNode focus;
  late List<String> events;
  late ReplyEffort effort;

  setUp(() {
    text = TextEditingController();
    focus = FocusNode();
    events = [];
    effort = ReplyEffort.medium;
  });
  tearDown(() {
    text.dispose();
    focus.dispose();
  });

  Widget composer({
    bool live = false,
    bool streaming = false,
    bool chat = true,
    bool effortOn = true,
    bool muted = false,
    bool desktopKeys = true,
    AppFeedback? feedback,
  }) => themed(
    FeedbackScope(
      feedback: feedback,
      child: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => Align(
            alignment: Alignment.bottomCenter,
            child: Composer(
              controller: text,
              focusNode: focus,
              live: live,
              streaming: streaming,
              chatEnabled: chat,
              effortEnabled: effortOn,
              effort: effort,
              onEffort: (e) => setState(() {
                effort = e;
                events.add('effort:${e.name}');
              }),
              onSend: (t) => events.add('send:$t'),
              onStop: () => events.add('stop'),
              onStartLive: () => events.add('live'),
              muted: muted,
              onMute: () => events.add('mute'),
              onEnd: () => events.add('end'),
              onMore: () => events.add('more'),
              desktopKeys: desktopKeys,
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('action button: live when empty, send with text, stop while '
      'streaming', (tester) async {
    phoneSize(tester);
    final h = tester.ensureSemantics();
    await tester.pumpWidget(composer());
    expect(find.bySemanticsLabel('Start live voice'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Start live voice'));
    expect(events, ['live']);

    await tester.enterText(find.byType(TextField), '  hello  ');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Send message'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Send message'));
    await tester.pump();
    expect(events.last, 'send:hello');
    expect(text.text, isEmpty, reason: 'cleared instantly on send');

    await tester.pumpWidget(composer(streaming: true));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Stop reply'));
    expect(events.last, 'stop');
    h.dispose();
  });

  testWidgets('the field is named "Ask Hermes" for screen readers', (
    tester,
  ) async {
    phoneSize(tester);
    final h = tester.ensureSemantics();
    for (final desktop in [false, true]) {
      await tester.pumpWidget(composer(desktopKeys: desktop));
      expect(
        tester.getSemantics(find.byType(EditableText)),
        isSemantics(label: 'Ask Hermes', isTextField: true),
        reason: 'desktopKeys: $desktop',
      );
    }
    h.dispose();
  });

  testWidgets('Enter sends on desktop; Shift+Enter adds a line', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(composer());
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'line one');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(events, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(events.single, startsWith('send:line one'));
  });

  testWidgets('text is capped at 8000 characters, counter from 7000', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(composer());
    await tester.enterText(find.byType(TextField), 'a' * 6999);
    await tester.pump();
    expect(find.textContaining('/ 8000'), findsNothing);
    await tester.enterText(find.byType(TextField), 'a' * 9000);
    await tester.pump();
    expect(text.text.length, 8000);
    expect(find.text('8000 / 8000'), findsOneWidget);
  });

  testWidgets('live morph: pill shrinks, mute and end appear', (tester) async {
    phoneSize(tester);
    final h = tester.ensureSemantics();
    await tester.pumpWidget(composer());
    final full = tester.getSize(find.byType(Composer)).width;
    expect(find.bySemanticsLabel('End live voice'), findsNothing);

    await tester.pumpWidget(composer(live: true));
    await tester.pump(const Duration(milliseconds: 170));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Mute microphone'), findsOneWidget);
    expect(find.bySemanticsLabel('End live voice'), findsOneWidget);
    expect(find.bySemanticsLabel('Reply effort: Medium'), findsOneWidget);
    // Pill = width − 2·52 − 2·8 − 32 (spec §6.4); the composer has 16 dp sides.
    final pill = tester
        .getSize(
          find
              .descendant(
                of: find.byType(Composer),
                matching: find.byType(SizedBox),
              )
              .at(1),
        )
        .width;
    expect(pill, closeTo(full - 32 - 2 * 52 - 2 * 8, 0.5));

    await tester.tap(find.bySemanticsLabel('End live voice'));
    await tester.tap(find.bySemanticsLabel('Mute microphone'));
    expect(events, ['end', 'mute']);

    await tester.pumpWidget(composer(live: true, muted: true));
    await tester.pump();
    expect(find.bySemanticsLabel('Unmute microphone'), findsOneWidget);
    h.dispose();
  });

  testWidgets('large text puts the live pill on its own line', (tester) async {
    phoneSize(tester);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(412, 915),
          textScaler: TextScaler.linear(2),
        ),
        child: composer(live: true),
      ),
    );
    await tester.pumpAndSettle();
    final end = tester.getCenter(find.byIcon(Icons.close_rounded));
    final add = tester.getCenter(find.byIcon(Icons.add_rounded));
    expect(end.dy, greaterThan(add.dy + 40));
  });

  testWidgets('effort slider snaps to stops, clicks, and closes when idle', (
    tester,
  ) async {
    phoneSize(tester);
    final sink = _Sink();
    final settings = SettingsController(
      keys: MemoryKeyStore(),
      prefs: MemoryPrefsStore(),
    );
    await tester.pumpWidget(
      composer(
        live: true,
        feedback: AppFeedback(settings: settings, sink: sink, mobile: true),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.speed_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Medium effort'), findsOneWidget);

    final slider = find.byType(EffortSlider);
    final box = tester.getRect(slider);
    await tester.tapAt(Offset(box.left + 30, box.bottom - 26));
    await tester.pumpAndSettle();
    expect(effort, ReplyEffort.instant);
    expect(find.text('Instant effort'), findsOneWidget);
    expect(sink.haptics, contains(Haptic.selection));

    // Drag to the far end: snaps to High.
    await tester.drag(slider, const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(effort, ReplyEffort.high);

    await tester.pump(const Duration(milliseconds: 1900));
    await tester.pumpAndSettle();
    expect(find.byType(EffortSlider), findsNothing);
  });

  testWidgets('effort slider is adjustable by screen readers', (tester) async {
    final h = tester.ensureSemantics();
    var v = ReplyEffort.medium;
    await tester.pumpWidget(
      themed(
        Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) => EffortSlider(
                value: v,
                onChanged: (e) => setState(() => v = e),
                onDismiss: () {},
                width: 300,
              ),
            ),
          ),
        ),
      ),
    );
    final node = tester.getSemantics(find.byType(EffortSlider));
    expect(node.value, 'Medium');
    expect(node.increasedValue, 'High');
    tester.semantics.performAction(
      find.semantics.byLabel('Reply effort'),
      SemanticsAction.increase,
    );
    await tester.pumpAndSettle();
    expect(v, ReplyEffort.high);
    h.dispose();
  });

  testWidgets('without chat the composer offers only live voice', (
    tester,
  ) async {
    phoneSize(tester);
    await tester.pumpWidget(composer(chat: false, effortOn: false));
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Talk to Hermes'), findsOneWidget);
    await tester.tap(find.text('Talk to Hermes'));
    expect(events, ['live']);
  });

  test('haptics follow the setting and stay off on desktop', () async {
    final sink = _Sink();
    final settings = SettingsController(
      keys: MemoryKeyStore(),
      prefs: MemoryPrefsStore(),
    );
    await settings.load();
    final f = AppFeedback(settings: settings, sink: sink, mobile: true);
    f.haptic(Haptic.light);
    f.cue(Cue.connected);
    await settings.setHaptics(false);
    await settings.setSounds(false);
    f.haptic(Haptic.light);
    f.cue(Cue.ended);
    expect(sink.haptics, [Haptic.light]);
    expect(sink.cues, [Cue.connected]);
    AppFeedback(
      settings: settings..setHaptics(true),
      sink: sink,
      mobile: false,
    ).haptic(Haptic.heavy);
    expect(sink.haptics, [Haptic.light]);
  });
}
