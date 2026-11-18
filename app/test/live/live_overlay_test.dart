import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/config.dart';
import 'package:tove_chat/src/rtc/voice_transport.dart';
import 'package:tove_chat/src/ui/live/live_work.dart';
import 'package:tove_chat/src/ui/live/live_content.dart';
import 'package:tove_chat/src/ui/live/live_link_cards.dart';
import 'package:tove_chat/src/ui/live/live_overlay.dart';
import 'package:tove_chat/src/ui/orb/orb.dart';
import 'package:tove_chat/src/ui/theme/tokens.dart';
import 'package:material_ui/material_ui.dart';

import '../fakes.dart';
import '../ui/test_harness.dart';
import 'live_fonts.dart';

const _answer = '''
## Storage on NAS-01

The pool is **40 % full** after last night's backups. Three things stand out:

1. Media grew by 180 GB this week.
2. Snapshots older than 30 days take 64 GB.
3. The backup dataset is compressed 1.6 ×.

| Dataset | Used | Change |
|---|---|---|
| media | 2.1 TB | +180 GB |
| backups | 410 GB | +12 GB |

Pruning old snapshots is safe; see [the OpenZFS snapshot guide](https://openzfs.github.io/openzfs-docs/snapshots) and https://www.truenas.com/docs/scale/data-protection/snapshot-retention.html for retention ideas.
''';

/// [fastTimings] with room for a loaded machine: the connect and session
/// timers run in real time inside `runAsync`.
const _timings = CallTimings(
  microphone: Duration(seconds: 5),
  nativeStart: Duration(milliseconds: 300),
  iceGathering: Duration(milliseconds: 10),
  session: Duration(seconds: 10),
  connect: Duration(seconds: 20),
  disconnectGrace: Duration(milliseconds: 100),
  stop: Duration(milliseconds: 300),
  request: Duration(seconds: 5),
  jobPoll: Duration(milliseconds: 5),
  levelPoll: Duration(milliseconds: 20),
  maxPollFailures: 3,
);

const _composerTop = 915.0 - 12 - 52;

void main() {
  late FakeBridge bridge;
  late FakeTransport transport;
  late CallController call;
  late ChatController chat;
  late DateTime since;
  late ValueNotifier<bool> tickers;
  final opened = <Uri>[];

  setUpAll(() async {
    await loadLiveTestFonts();
  });

  setUp(() {
    opened.clear();
    tickers = ValueNotifier(true);
    // Elapsed times come from the bridge only: goldens stay stable.
    liveNow = () => DateTime(2000);
  });
  tearDown(() {
    liveNow = DateTime.now;
    tickers.dispose();
  });

  GlobalKey<LiveOverlayState> overlayKey = GlobalKey();

  Future<void> advance(WidgetTester tester, [int ms = 800]) async {
    for (var i = 0; i < ms ~/ 50; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> snapshot(WidgetTester tester, String name) async {
    // Motion assertions run above each snapshot. Freeze the visual baseline
    // at the orb's resting parameters so async job timing cannot shift clouds.
    tickers.value = false;
    await tester.pump();
    tester.widget<HermesOrb>(find.byType(HermesOrb)).engine!.settle();
    await tester.pump();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/$name.png'),
    );
    tickers.value = true;
    await tester.pump();
  }

  Future<void> mount(WidgetTester tester, {bool reduce = false}) async {
    phoneSize(tester);
    bridge = FakeBridge()..chatEnabled = true;
    call = CallController(
      apiFactory: bridge.api,
      transportFactory: () =>
          transport = FakeTransport()..levels = AudioLevels.silent,
      platform: FakePlatform(supported: false),
      voice: () => 'cove',
      timings: _timings,
      desktop: true,
    );
    addTearDown(call.dispose);
    chat = ChatController(
      api: ChatApi(
        baseUrl: Uri.parse('https://bridge.test:9476'),
        accessKey: testKey,
        client: bridge.client,
      ),
    );
    addTearDown(chat.dispose);
    since = DateTime.now().subtract(const Duration(seconds: 1));
    overlayKey = GlobalKey();
    await tester.pumpWidget(
      ValueListenableBuilder<bool>(
        valueListenable: tickers,
        builder: (context, ticking, _) => TickerMode(
          enabled: ticking,
          child: themed(
            Builder(
              builder: (context) {
                final t = HermesTokens.of(context);
                return Scaffold(
                  backgroundColor: t.bg,
                  body: Stack(
                    children: [
                      // A stand-in for the live composer row.
                      Positioned(
                        left: 16,
                        right: 16,
                        top: _composerTop,
                        height: 52,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: t.surface,
                            borderRadius: BorderRadius.circular(26),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: LiveOverlay(
                          key: overlayKey,
                          call: call,
                          chat: chat,
                          enter: const AlwaysStoppedAnimation(1.0),
                          since: since,
                          topInset: 56,
                          composerTop: _composerTop,
                          onRetry: () {},
                          onOpenSite: (s) => opened.add(s.uri),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            reduce: reduce,
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await call.start();
      await settle(10);
    });
    transport.emit({'type': 'session.started'});
    await tester.runAsync(() => settle(10));
    call.levels.value = AudioLevels.silent;
    await advance(tester, 600);
    expect(call.phase, CallPhase.live);
  }

  Future<void> delegate(WidgetTester tester, String id, String text) async {
    transport.emit({
      'type': 'delegation.created',
      'item': {
        'id': id,
        'content': [
          {'text': text},
        ],
      },
    });
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => settle(10));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> end(WidgetTester tester) async {
    await tester.runAsync(() async {
      await call.end();
      await settle(10);
    });
    await advance(tester, 400);
  }

  LiveOverlayState overlay() => overlayKey.currentState!;
  OrbStageLayout layout(int cards) => OrbStageLayout(
    size: const Size(412, 915),
    padding: EdgeInsets.zero,
    topInset: 56,
    composerTop: _composerTop,
    cardsExtent: 0, // no task cards near the orb any more
  );

  testWidgets('idle: the orb is large and centred', (tester) async {
    await mount(tester);
    final c = overlay().choreographer;
    expect(overlay().docked, isFalse);
    expect(c.pose, OrbChoreography.pose(OrbStage.centred, layout(0)));
    expect(c.dock, 0);
    await snapshot(tester, 'live_idle');
    await end(tester);
  });

  testWidgets(
    'orb follows touch, springs back, and a pull reveals a live transcript',
    (tester) async {
      await mount(tester);
      final c = overlay().choreographer;
      final rest = c.centre;
      final drag = await tester.startGesture(rest);
      await drag.moveBy(const Offset(32, 30));
      await advance(tester, 100);
      expect(c.touchOffset.distance, greaterThan(10));
      expect(c.centre.dx, greaterThan(rest.dx));
      expect(c.touchStretch, greaterThan(0));
      await drag.up();
      await advance(tester, 1500);
      expect(c.touchOffset.distance, lessThan(0.1));
      expect(overlay().conversationOpen, isFalse);

      transport.emit({
        'type': 'turn.created',
        'turn': {'role': 'user'},
      });
      transport.emit({
        'type': 'input_transcript.added',
        'item': {'text': 'Check the storage'},
      });
      await tester.runAsync(() => settle(10));
      await tester.dragFrom(c.centre, const Offset(0, 140));
      await advance(tester, 1000);
      expect(overlay().conversationOpen, isTrue);
      expect(c.dock, 1);
      expect(find.text('Check the storage'), findsOneWidget);
      expect(call.phase, CallPhase.live);

      transport.emit({
        'type': 'input_transcript.added',
        'item': {'text': ' on NAS-01'},
      });
      await tester.runAsync(() => settle(10));
      await advance(tester, 100);
      expect(find.text('Check the storage on NAS-01'), findsOneWidget);
      expect(find.text('Check the storage'), findsNothing);
      await snapshot(tester, 'live_transcript');
      // A task arriving while only the transcript is open must update the
      // conversation without replacing it or dereferencing an absent answer.
      bridge.defaultRunningPolls = 100000;
      await delegate(tester, 'during-transcript', 'Check backup status');
      await advance(tester, 200);
      expect(overlay().conversationOpen, isTrue);
      expect(find.text('Check backup status'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Hide conversation'));
      await advance(tester, 1000);
      expect(overlay().conversationOpen, isFalse);
      expect(c.dock, 0);
      await end(tester);
    },
  );

  testWidgets(
    'reduced motion preserves transcript gesture without deforming the orb',
    (tester) async {
      await mount(tester, reduce: true);
      final c = overlay().choreographer;
      await tester.dragFrom(c.centre, const Offset(0, 130));
      await advance(tester, 300);
      expect(overlay().conversationOpen, isTrue);
      expect(c.touchOffset, Offset.zero);
      expect(c.touchPressure, 0);
      expect(
        find.textContaining('Your live conversation will appear'),
        findsOneWidget,
      );
      await end(tester);
    },
  );

  testWidgets('a long result docks the orb under a scrolling panel; '
      'links open; hiding brings the orb back', (tester) async {
    await mount(tester);
    bridge
      ..jobAnswer = _answer
      ..defaultRunningPolls = 0;
    await delegate(tester, 'd1', 'check the storage on NAS-01');
    await advance(tester, 200);
    // Mid-glide: between the two poses.
    final c = overlay().choreographer;
    final centred = OrbChoreography.pose(OrbStage.centred, layout(1));
    final docked = OrbChoreography.pose(OrbStage.docked, layout(1));
    expect(overlay().docked, isTrue);
    expect(c.target, docked);
    await advance(tester, 800);
    expect((c.centre - docked.centre).distance, lessThan(0.5));
    expect(c.dock, 1);
    expect(find.text('Storage on NAS-01', findRichText: true), findsWidgets);
    expect(find.byType(LiveSiteCard), findsNWidgets(2));
    expect(overlay().work, isEmpty, reason: 'a finished result is not work');
    final panelScroll = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('live-panel-scroll')),
    );
    expect(
      panelScroll.controller!.offset,
      0,
      reason: 'a completed task opens at the start of its answer',
    );
    await snapshot(tester, 'live_docked_panel');

    await tester.scrollUntilVisible(
      find.byType(LiveSiteCard).first,
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('live-panel-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.byType(LiveSiteCard).first);
    expect(opened.single.host, 'openzfs.github.io');

    // Tap the docked orb: the panel fades, the orb glides back.
    await tester.tap(find.bySemanticsLabel('Hide the answer'));
    await advance(tester, 100);
    expect(c.target!.dock, 1, reason: 'the text fades out first');
    await advance(tester, 900);
    expect(overlay().docked, isFalse);
    expect((c.pose.centre - centred.centre).distance, lessThan(0.5));
    expect(find.byType(LiveSiteCard), findsNothing);
    await end(tester);
  });

  testWidgets('running tasks stay compact under the orb; only a result '
      'docks it; failures never pose as results', (tester) async {
    await mount(tester);
    bridge.defaultRunningPolls = 100000;
    // Synthetic job progress in the bridge's `status_event` shape.
    bridge.jobStatusEvents['job1'] = {
      'label': 'df -h /srv',
      'state': 'running',
      'tool': 'terminal',
      'id': 'call-1',
    };
    await delegate(tester, 'd1', 'check the storage on NAS-01');
    await delegate(tester, 'd2', 'ask T3 to fix the failing app build');
    await advance(tester, 400);
    final c = overlay().choreographer;
    expect(overlay().docked, isFalse, reason: 'running work is not a result');
    expect(overlay().shown, isNull);
    expect(c.dock, 0, reason: 'the orb keeps its hero size');
    expect(overlay().work.map((w) => (w.id, w.running)), [
      ('task-d1', true),
      ('task-d2', true),
    ]);
    // No progress label or paragraph under the orb; the strip has it.
    expect(find.textContaining('Working on it ·'), findsNothing);
    final strip = find.byKey(const ValueKey('live-work-strip'));
    expect(strip, findsOneWidget);
    expect(
      tester.getBottomLeft(strip).dy,
      lessThanOrEqualTo(_composerTop - 8 + 0.5),
      reason: 'just above the composer',
    );
    expect(
      tester.getTopLeft(strip).dy,
      greaterThan(c.pose.centre.dy),
      reason: 'below the orb',
    );
    // One quiet status line, like the chat's thinking line: the newest
    // task's status and a count, no request text, box or timeline.
    expect(find.text('Working on it'), findsOneWidget);
    expect(find.text(' · 2 tasks'), findsOneWidget);
    expect(find.textContaining('ask T3 to fix'), findsNothing);
    expect(find.text('df -h /srv'), findsNothing, reason: 'no raw commands');
    expect(
      find.descendant(of: strip, matching: find.byType(DecoratedBox)),
      findsNothing,
    );
    await snapshot(tester, 'live_working');

    // The second job finishes: its result docks the orb.
    bridge.runningPolls.updateAll((k, v) => k == 'job2' ? 0 : v);
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => settle(10));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await advance(tester, 800);
    expect(overlay().docked, isTrue);
    expect(overlay().shown!.id, 'task-d2');
    expect(find.textContaining('Task result'), findsOneWidget);
    expect(c.dock, closeTo(1, 0.01));
    expect(overlay().work.map((w) => w.id), ['task-d1']);
    // The remaining task's real step, worded like the chat.
    expect(find.text('Running terminal'), findsOneWidget);

    // The first fails: it shows as a failure in the strip, and the result
    // on screen stays.
    bridge.jobResult = 'failed';
    bridge.runningPolls.updateAll((k, v) => k == 'job1' ? 0 : v);
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => settle(10));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await advance(tester, 200);
    expect(overlay().shown!.id, 'task-d2');
    expect(overlay().work.single.state, LiveWorkState.failed);
    expect(find.textContaining('Couldn’t finish'), findsOneWidget);

    // Failures linger 12 s, then leave.
    liveNow = () => DateTime(2000).add(const Duration(seconds: 13));
    // (The expiry timer runs on real time here; any call event re-reads.)
    call
      ..toggleMute()
      ..toggleMute();
    await advance(tester, 200);
    expect(overlay().work, isEmpty);
    expect(find.byKey(const ValueKey('live-work-strip')), findsNothing);
    await end(tester);
  });

  testWidgets('a new result waits behind a pill while the reader is '
      'scrolled into the current one', (tester) async {
    await mount(tester);
    bridge
      ..jobAnswer = _answer * 3
      ..defaultRunningPolls = 0;
    await delegate(tester, 'd1', 'check the storage on NAS-01');
    await advance(tester, 800);
    expect(overlay().shown!.id, 'task-d1');
    final scrollable = find
        .descendant(
          of: find.byKey(const ValueKey('live-panel-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.drag(scrollable, const Offset(0, -300));
    await advance(tester, 400);
    final controller = tester
        .widget<SingleChildScrollView>(
          find.byKey(const ValueKey('live-panel-scroll')),
        )
        .controller!;
    final reading = controller.offset;
    expect(reading, greaterThan(100));

    bridge.jobAnswer = 'A short **second** result.';
    await delegate(tester, 'd2', 'and the backups?');
    await advance(tester, 400);
    expect(overlay().shown!.id, 'task-d1', reason: 'the text stays put');
    expect(overlay().newer?.id, 'task-d2');
    expect(controller.offset, reading);
    expect(find.byKey(const ValueKey('live-new-result')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('live-new-result')));
    await advance(tester, 400);
    expect(overlay().shown!.id, 'task-d2');
    expect(overlay().newer, isNull);
    expect(controller.offset, 0);
    await end(tester);
  });

  testWidgets('reduced motion: the orb docks with no travel', (tester) async {
    await mount(tester, reduce: true);
    bridge.defaultRunningPolls = 0;
    await delegate(tester, 'd1', 'check the storage on NAS-01');
    await tester.pump();
    final c = overlay().choreographer;
    expect(c.reduced, isTrue);
    expect(overlay().docked, isTrue);
    expect(c.centre, c.target!.centre, reason: 'snapped, not gliding');
    expect(c.dock, 1);
    expect(c.settled, isTrue);
    await end(tester);
  });

  testWidgets('login expired keeps its message and retry', (tester) async {
    phoneSize(tester);
    bridge = FakeBridge()
      ..sessionStatus = 502
      ..sessionError = {'error': 'login_expired', 'code': 'login_expired'};
    call = CallController(
      apiFactory: bridge.api,
      transportFactory: () => transport = FakeTransport(),
      platform: FakePlatform(supported: false),
      voice: () => 'cove',
      timings: _timings,
      desktop: true,
    );
    addTearDown(call.dispose);
    chat = ChatController(
      api: ChatApi(
        baseUrl: Uri.parse('https://bridge.test:9476'),
        accessKey: testKey,
        client: bridge.client,
      ),
    );
    addTearDown(chat.dispose);
    var retried = 0;
    await tester.pumpWidget(
      themed(
        Scaffold(
          body: LiveOverlay(
            call: call,
            chat: chat,
            enter: const AlwaysStoppedAnimation(1.0),
            since: DateTime.now(),
            topInset: 56,
            composerTop: _composerTop,
            onRetry: () => retried++,
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await call.start();
      await settle(10);
    });
    await advance(tester, 400);
    expect(find.text(CallController.loginExpiredMessage), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, 1);
  });
}
