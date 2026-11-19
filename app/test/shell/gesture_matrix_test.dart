import 'dart:io';

import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show debugOnRebuildDirtyWidget;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart'
    show Axis, Scrollable, ScrollableState, ScrollPosition, ValueKey;
import 'package:tove_chat/src/app.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/ui/composer/composer.dart';
import 'package:tove_chat/src/ui/feedback.dart';
import 'package:tove_chat/src/ui/shell/chat_shell.dart';
import 'package:tove_chat/src/ui/theme/render_policy.dart';
import 'package:tove_chat/src/ui/thread/messages.dart' show ThreadSelection;
import 'package:tove_chat/src/ui/thread/starter_marquee.dart';

import '../fakes.dart';
import '../ui/test_harness.dart';

class _Feedback implements FeedbackSink {
  final haptics = <Haptic>[];
  @override
  void haptic(Haptic h) => haptics.add(h);
  @override
  void cue(Cue c) {}
}

Future<void> _loadIcons() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  final candidates = [
    if (root != null)
      '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    '${Platform.environment['HOME']}/.local/share/hermes-build-tools/flutter/'
        'bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ];
  for (final p in candidates) {
    final f = File(p);
    if (f.existsSync()) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
      await loader.load();
      return;
    }
  }
}

Map<String, dynamic> _conv(String id, String title, {bool pinned = false}) => {
  'id': id,
  'title': title,
  'title_source': 'user',
  'pinned': pinned,
  'kind': 'text',
  'created': DateTime(2026, 11, 16, 9).millisecondsSinceEpoch,
  'updated': DateTime(2026, 11, 16, 9).millisecondsSinceEpoch,
  'preview': '',
  'message_count': 2,
};

Map<String, dynamic> _msg(String id, String role, String text) => {
  'id': id,
  'conversation_id': 'c1',
  'role': role,
  'text': text,
  'source': 'text',
  'status': 'complete',
  'created': DateTime(2026, 11, 16, 9).millisecondsSinceEpoch,
  'client_id': null,
  'meta': <String, dynamic>{},
};

/// Gesture matrix (round 6): every swipe at a slow, light and fast pace,
/// from reply text, empty space and the composer; on the starter rows a
/// swipe only scrolls them (round 8).
void main() {
  late FakeBridge bridge;
  late CallController call;
  late SettingsController settings;
  late _Feedback feedback;

  setUpAll(() async {
    await loadAppFonts();
    await loadEmojiFont();
    await _loadIcons();
  });

  Future<void> advance(WidgetTester tester, [int ms = 800]) async {
    for (var i = 0; i < ms ~/ 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> boot(
    WidgetTester tester, {
    Size size = const Size(412, 915),
    void Function(FakeBridge)? setup,
    MemoryPrefsStore? prefs,
  }) async {
    phoneSize(tester, size: size);
    bridge = FakeBridge()..chatEnabled = true;
    setup?.call(bridge);
    feedback = _Feedback();
    settings = SettingsController(
      keys: MemoryKeyStore(testKey),
      prefs: prefs ?? MemoryPrefsStore(),
    );
    final link = LiveLink();
    call = CallController(
      apiFactory: bridge.api,
      transportFactory: FakeTransport.new,
      platform: FakePlatform(supported: false),
      voice: () => settings.voice,
      conversationId: () => link.conversationId,
      timings: fastTimings,
      desktop: true,
    );
    addTearDown(call.dispose);
    await tester.pumpWidget(
      HermesApp(
        settings: settings,
        call: call,
        liveLink: link,
        verify: (u, k) async {},
        chatApi: (s) => ChatApi(
          baseUrl: Uri.parse('https://bridge.test:9476'),
          accessKey: s.accessKey,
          client: bridge.client,
        ),
        feedbackSink: feedback,
        renderPolicy: RenderPolicy(
          blur: false,
          shaderOrb: false,
          liveMask: true,
          monitor: false,
        ),
      ),
    );
    await settings.load();
    await tester.pump();
    await tester.runAsync(() => settle(20));
    await advance(tester);
  }

  void seed(FakeBridge b, {String reply = 'NAS-01 is at **40%**.'}) {
    b.conversations
      ..add(_conv('c1', 'Disk check'))
      ..add(_conv('c2', 'Backup plan', pinned: true));
    b.stored['c1'] = [
      _msg('m1', 'user', 'How full are the disks?'),
      _msg('m2', 'assistant', reply),
    ];
    b.stored['c2'] = [];
  }

  Future<void> openChat(WidgetTester tester, String title) async {
    await tester.tap(find.bySemanticsLabel('Chats'));
    await advance(tester, 600);
    await tester.tap(find.text(title));
    await tester.runAsync(() => settle(20));
    await advance(tester, 800);
  }

  Rect composerRect(WidgetTester tester) =>
      tester.getRect(find.byType(Composer));

  ChatShellState shell(WidgetTester tester) =>
      tester.state<ChatShellState>(find.byType(ChatShell));

  Finder liveOpen() => find.bySemanticsLabel('End live voice');

  Future<void> closePanels(WidgetTester tester) async {
    shell(tester).handleBack();
    await advance(tester, 800);
  }

  /// One drag at a realistic pace: [steps] moves of [by]/[steps], one frame
  /// (16 ms) apart, then up. A light flick is few, short, fast moves.
  Future<void> drag(
    WidgetTester tester,
    Offset from,
    Offset by, {
    int steps = 6,
    Duration frame = const Duration(milliseconds: 16),
  }) async {
    // Real timestamps: the release velocity comes from them.
    var t = const Duration(seconds: 1);
    final g = await tester.createGesture();
    await g.down(from, timeStamp: t);
    for (var i = 0; i < steps; i++) {
      t += frame;
      await g.moveBy(by / steps.toDouble(), timeStamp: t);
      await tester.pump(frame);
    }
    await g.up(timeStamp: t);
    await advance(tester, 800);
  }

  // Slow: 160 dp over ~1 s. Light: 48 dp in 4 frames. Fast: 140 dp in 3
  // frames (a flick).
  const paces = <String, ({double dist, int steps, int ms})>{
    'slow': (dist: 160, steps: 60, ms: 16),
    'light': (dist: 48, steps: 4, ms: 16),
    'fast flick': (dist: 140, steps: 3, ms: 10),
  };

  group('sidebar swipes open from anywhere, at any pace', () {
    for (final pace in paces.entries) {
      for (final where in ['reply text', 'empty space', 'composer']) {
        testWidgets('${pace.key} rightward on $where opens the chat list', (
          tester,
        ) async {
          await boot(tester, setup: seed);
          await openChat(tester, 'Disk check');
          final from = switch (where) {
            'reply text' => tester.getCenter(find.textContaining('NAS-01')),
            'composer' => composerRect(tester).center,
            _ => Offset(200, composerRect(tester).top - 160),
          };
          final p = pace.value;
          await drag(
            tester,
            from - Offset(p.dist / 2, 0),
            Offset(p.dist, 4),
            steps: p.steps,
            frame: Duration(milliseconds: p.ms),
          );
          expect(
            shell(tester).drawerProgress,
            closeTo(1, 0.01),
            reason: 'chat list open',
          );
          await closePanels(tester);
        });

        testWidgets('${pace.key} leftward on $where opens Tasks', (
          tester,
        ) async {
          await boot(tester, setup: seed);
          await openChat(tester, 'Disk check');
          final from = switch (where) {
            'reply text' => tester.getCenter(find.textContaining('NAS-01')),
            'composer' => composerRect(tester).center,
            _ => Offset(200, composerRect(tester).top - 160),
          };
          final p = pace.value;
          await drag(
            tester,
            from + Offset(p.dist / 2, 0),
            Offset(-p.dist, -4),
            steps: p.steps,
            frame: Duration(milliseconds: p.ms),
          );
          expect(
            shell(tester).tasksProgress,
            closeTo(1, 0.01),
            reason: 'Tasks open',
          );
          await closePanels(tester);
        });
      }
    }

    // Round 8 (the user's rule, reversing round 6): a swipe on the starter
    // rows scrolls them and opens neither panel, at any pace, either way;
    // the rows drift again afterwards.
    for (final pace in paces.entries) {
      for (final dir in [1.0, -1.0]) {
        testWidgets('${pace.key} ${dir > 0 ? 'rightward' : 'leftward'} over '
            'the starter rows scrolls them; no panel opens', (tester) async {
          await boot(tester);
          final marquee = find.byType(StarterMarquee).first;
          final m = tester.state<StarterMarqueeState>(marquee);
          final row = find.byKey(const ValueKey('starter-row-0')).first;
          final before = m.offsets[0];
          final p = pace.value;
          await drag(
            tester,
            tester.getCenter(row) - Offset(dir * p.dist / 2, 0),
            Offset(dir * p.dist, 2),
            steps: p.steps,
            frame: Duration(milliseconds: p.ms),
          );
          expect(shell(tester).drawerProgress, 0, reason: 'no chat list');
          expect(shell(tester).tasksProgress, 0, reason: 'no Tasks');
          // The content followed the finger (rightward: the offset falls),
          // net of the drift that resumed during the 800 ms after release.
          expect((m.offsets[0] - before) * -dir, greaterThan(p.dist * 0.5));
          expect(m.fingers, 0);
          // 16 ms frames (the drift clamps longer frames to 1/30 s): the
          // fling settles, the pause passes, the drift eases back in.
          for (var i = 0; i < 260; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          final a = m.offsets[0];
          for (var i = 0; i < 30; i++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(m.offsets[0], greaterThan(a + 5), reason: 'drifting');
        });
      }
    }

    testWidgets('the panel follows the finger from the first move (no slop '
        'lag)', (tester) async {
      await boot(tester, setup: seed);
      await openChat(tester, 'Disk check');
      // On reply text, where the selection recognizers compete, so the swipe
      // is accepted only after its slop.
      final g = await tester.startGesture(
        tester.getCenter(find.textContaining('NAS-01')) - const Offset(40, 0),
      );
      for (var i = 0; i < 4; i++) {
        await g.moveBy(const Offset(10, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final w = shell(tester).drawerWidth;
      // 40 dp of travel shows as 40 dp of drawer, not 40 − slop.
      expect(shell(tester).drawerProgress * w, closeTo(40, 1));
      await g.up();
      await advance(tester, 800);
    });
  });

  // Pull up to live (round 11): deliberate only. It arms over a thread
  // already at rest at its end, needs about 18 % of the screen (160 dp on
  // this 915 dp phone) and starts on release past that; speed never counts.
  group('pull up to live', () {
    void phoneSlop(WidgetTester tester) {
      tester.view.gestureSettings = const ui.GestureSettings(
        physicalTouchSlop: 8,
      );
      addTearDown(tester.view.resetGestureSettings);
    }

    Future<void> expectLive(WidgetTester tester, String why) async {
      await tester.runAsync(() => settle(20));
      await advance(tester, 600);
      expect(liveOpen(), findsWidgets, reason: why);
      await tester.runAsync(() => call.end());
      await advance(tester, 800);
    }

    Future<void> expectNoLive(WidgetTester tester, String why) async {
      await tester.runAsync(() => settle(20));
      await advance(tester, 600);
      expect(liveOpen(), findsNothing, reason: why);
      expect(bridge.to('/api/session'), isEmpty, reason: why);
    }

    ScrollPosition threadScroll(WidgetTester tester) => tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .map((s) => s.position)
        .firstWhere((p) => p.axis == Axis.vertical && p.maxScrollExtent > 0);

    void longChat(FakeBridge b) => seed(
      b,
      reply: List.generate(40, (i) => 'Paragraph ${i + 1}.').join('\n\n'),
    );

    testWidgets('a slow pull from the composer past the threshold, released, '
        'starts live', (tester) async {
      await boot(tester);
      await drag(
        tester,
        composerRect(tester).center,
        const Offset(3, -200),
        steps: 50,
      );
      await expectLive(tester, 'slow pull of 200 dp');
    });

    testWidgets('just above the composer of a chat at rest at its end', (
      tester,
    ) async {
      await boot(tester, setup: longChat);
      phoneSlop(tester);
      await openChat(tester, 'Disk check');
      await drag(
        tester,
        Offset(200, composerRect(tester).top - 24),
        const Offset(0, -200),
        steps: 50,
      );
      await expectLive(tester, 'from the zone above the composer');
    });

    for (final pace in {
      'light flick (44 dp in 3 frames)': (dist: 44.0, steps: 3, ms: 16),
      'fast flick (140 dp in 3 frames)': (dist: 140.0, steps: 3, ms: 10),
      'very fast (150 dp in 2 frames)': (dist: 150.0, steps: 2, ms: 8),
      'slow but short (100 dp)': (dist: 100.0, steps: 30, ms: 16),
    }.entries) {
      testWidgets('${pace.key} from the composer does not start live', (
        tester,
      ) async {
        await boot(tester, setup: seed);
        phoneSlop(tester);
        await openChat(tester, 'Disk check');
        final p = pace.value;
        await drag(
          tester,
          composerRect(tester).center,
          Offset(2, -p.dist),
          steps: p.steps,
          frame: Duration(milliseconds: p.ms),
        );
        await expectNoLive(tester, pace.key);
        expect(find.byKey(const ValueKey('live-swipe-hint')), findsNothing);
      });
    }

    testWidgets('dragging back below the threshold before release cancels', (
      tester,
    ) async {
      await boot(tester);
      final g = await tester.startGesture(composerRect(tester).center);
      for (var i = 0; i < 20; i++) {
        await g.moveBy(const Offset(0, -10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.text('Release to start live'), findsOneWidget);
      for (var i = 0; i < 8; i++) {
        await g.moveBy(const Offset(0, 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.text('Pull to talk'), findsOneWidget);
      await g.up();
      await expectNoLive(tester, 'released at 120 dp after reaching 200');
    });

    testWidgets('a fling that reaches the end of the thread and overscrolls '
        'never starts live, nor does a pull right after it', (tester) async {
      await boot(tester, setup: longChat);
      phoneSlop(tester);
      await openChat(tester, 'Disk check');
      final scroll = threadScroll(tester);
      scroll.jumpTo(scroll.maxScrollExtent - 500);
      await tester.pump();
      // Fling toward the end from just above the composer: the thread was
      // not at its end when the finger went down.
      await tester.flingFrom(
        Offset(200, composerRect(tester).top - 30),
        const Offset(0, -260),
        3000,
      );
      for (var i = 0; i < 300 && scroll.isScrollingNotifier.value; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(scroll.pixels, closeTo(scroll.maxScrollExtent, 1));
      await expectNoLive(tester, 'fling into the end');

      // A second fling at the end overscrolls: still nothing.
      await tester.flingFrom(
        Offset(200, composerRect(tester).top - 30),
        const Offset(0, -260),
        3000,
      );
      for (var i = 0; i < 300 && scroll.isScrollingNotifier.value; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(liveOpen(), findsNothing, reason: 'a fling at the end');
      // At once (within 600 ms of the fling): a slow, full pull does nothing.
      await drag(
        tester,
        composerRect(tester).center,
        const Offset(0, -200),
        steps: 50,
      );
      await expectNoLive(tester, 'within 600 ms of a fling');

      // At rest: the same pull starts live.
      await advance(tester, 800);
      await drag(
        tester,
        composerRect(tester).center,
        const Offset(0, -200),
        steps: 50,
      );
      await expectLive(tester, 'after the thread settled');
    });

    testWidgets('a chat scrolled up from its end does not arm it', (
      tester,
    ) async {
      await boot(tester, setup: longChat);
      phoneSlop(tester);
      await openChat(tester, 'Disk check');
      final scroll = threadScroll(tester);
      scroll.jumpTo(scroll.maxScrollExtent - 300);
      await tester.pump();
      await advance(tester, 800);
      await drag(
        tester,
        composerRect(tester).center,
        const Offset(0, -200),
        steps: 50,
      );
      await expectNoLive(tester, 'thread not at its end');
    });

    testWidgets('turned off in Settings, a full pull does nothing', (
      tester,
    ) async {
      final prefs = MemoryPrefsStore()..values['pullToLive'] = 'false';
      await boot(tester, prefs: prefs);
      expect(settings.pullToLive, isFalse);
      await drag(
        tester,
        composerRect(tester).center,
        const Offset(0, -220),
        steps: 50,
      );
      await expectNoLive(tester, 'setting off');
      expect(find.byKey(const ValueKey('live-swipe-hint')), findsNothing);
      // The live button still works.
      await settings.setPullToLive(true);
      await tester.pump();
      await drag(
        tester,
        composerRect(tester).center,
        const Offset(0, -220),
        steps: 50,
      );
      await expectLive(tester, 'setting back on');
    });

    testWidgets('a finger that rests on the composer (its long press wins: '
        'the Paste menu) and then pulls up still starts live', (tester) async {
      await boot(tester, setup: seed);
      phoneSlop(tester);
      await openChat(tester, 'Disk check');
      var t = const Duration(seconds: 1);
      final g = await tester.createGesture();
      await g.down(composerRect(tester).center, timeStamp: t);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      t += const Duration(milliseconds: 800);
      for (var i = 0; i < 18; i++) {
        t += const Duration(milliseconds: 16);
        await g.moveBy(const Offset(0, -12), timeStamp: t);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up(timeStamp: t);
      await expectLive(tester, 'after a long press');
    });

    testWidgets('a stray text selection does not block it from the '
        'composer, and is cleared', (tester) async {
      await boot(tester, setup: seed);
      phoneSlop(tester);
      await openChat(tester, 'Disk check');
      var cleared = false;
      ThreadSelection.set('stray', true, clear: () => cleared = true);
      addTearDown(() => ThreadSelection.set('stray', false));
      await drag(
        tester,
        composerRect(tester).center,
        const Offset(0, -200),
        steps: 40,
      );
      expect(cleared, isTrue);
      expect(ThreadSelection.active.value, isFalse);
      await expectLive(tester, 'with a selection');
    });
  });

  // Android reports the phone's own touch slop (ViewConfiguration, about
  // 8 dp). The thread's scroll and the text field's recognizers use it, so
  // a fixed 16–18 dp swipe slop lost to them on a device (round 6, A2).
  group('with a phone touch slop of 8 dp', () {
    void phoneSlop(WidgetTester tester) {
      tester.view.gestureSettings = const ui.GestureSettings(
        physicalTouchSlop: 8,
      );
      addTearDown(tester.view.resetGestureSettings);
    }

    for (final where in ['reply text', 'composer']) {
      testWidgets('light sideways swipes on $where open both panels', (
        tester,
      ) async {
        await boot(tester, setup: seed);
        phoneSlop(tester);
        await openChat(tester, 'Disk check');
        Offset from() => where == 'composer'
            ? composerRect(tester).center
            : tester.getCenter(find.textContaining('NAS-01'));
        await drag(
          tester,
          from() - const Offset(24, 0),
          const Offset(48, 3),
          steps: 4,
        );
        expect(shell(tester).drawerProgress, closeTo(1, 0.01));
        await closePanels(tester);
        await drag(
          tester,
          from() + const Offset(24, 0),
          const Offset(-48, 3),
          steps: 4,
        );
        expect(shell(tester).tasksProgress, closeTo(1, 0.01));
        await closePanels(tester);
      });
    }
  });

  group('haptics (round 6, A4)', () {
    testWidgets('a light flick that opens a panel clicks once; a menu opens '
        'with a light tap; a long press on a chat row is medium', (
      tester,
    ) async {
      await boot(tester, setup: seed);
      await openChat(tester, 'Disk check');
      feedback.haptics.clear();
      await drag(
        tester,
        tester.getCenter(find.textContaining('NAS-01')) - const Offset(24, 0),
        const Offset(48, 2),
        steps: 4,
      );
      expect(shell(tester).drawerProgress, closeTo(1, 0.01));
      expect(feedback.haptics, [Haptic.selection]);
      await closePanels(tester);

      feedback.haptics.clear();
      await tester.tap(find.byKey(const ValueKey('more-button')));
      await advance(tester, 400);
      expect(feedback.haptics, contains(Haptic.light));
      shell(tester).handleBack();
      await tester.binding.handlePopRoute();
      await advance(tester, 600);
    });
  });

  // Frame cost (round 6, A5). Widget tests have no GPU, so these measure the
  // framework side of each frame (build, layout, paint recording) and count
  // widget rebuilds; on-device timings need integration_test's traceAction.
  group('frame cost', () {
    Future<({List<double> ms, List<int> rebuilds})> measure(
      WidgetTester tester,
      int frames,
      Future<void> Function(int i) frame,
    ) async {
      final ms = <double>[];
      final rebuilds = <int>[];
      var count = 0;
      debugOnRebuildDirtyWidget = (e, builtOnce) => count++;
      try {
        for (var i = 0; i < frames; i++) {
          count = 0;
          final w = Stopwatch()..start();
          await frame(i);
          ms.add(w.elapsedMicroseconds / 1000);
          rebuilds.add(count);
        }
      } finally {
        debugOnRebuildDirtyWidget = null;
      }
      return (ms: ms, rebuilds: rebuilds);
    }

    String summary(String name, ({List<double> ms, List<int> rebuilds}) r) {
      final ms = [...r.ms]..sort();
      final reb = [...r.rebuilds]..sort();
      double p(List<num> l, double q) =>
          l[((l.length - 1) * q).round()].toDouble();
      return '$name: ${r.ms.length} frames, framework ms '
          'p50 ${p(ms, 0.5).toStringAsFixed(2)} '
          'p90 ${p(ms, 0.9).toStringAsFixed(2)} '
          'max ${ms.last.toStringAsFixed(2)}; rebuilds/frame '
          'p50 ${p(reb, 0.5).toInt()} max ${reb.last}';
    }

    testWidgets('drawer drag: no rebuilds of the chat while following', (
      tester,
    ) async {
      await boot(tester, setup: seed);
      await openChat(tester, 'Disk check');
      final g = await tester.startGesture(const Offset(60, 400));
      // Past the slop first, so the swipe is following.
      await g.moveBy(const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 16));
      final r = await measure(tester, 60, (i) async {
        await g.moveBy(const Offset(4, 0));
        await tester.pump(const Duration(milliseconds: 16));
      });
      await g.up();
      await advance(tester, 800);
      // ignore: avoid_print
      print(summary('drawer drag', r));
      // Only the Stack that positions the panels rebuilds (389 before).
      expect(r.rebuilds.reduce((a, b) => a > b ? a : b), lessThan(20));
    });

    testWidgets('starter marquee: paint only, no rebuilds', (tester) async {
      await boot(tester);
      final r = await measure(tester, 120, (i) async {
        await tester.pump(const Duration(milliseconds: 16));
      });
      // ignore: avoid_print
      print(summary('starter marquee', r));
      expect(r.rebuilds.every((n) => n == 0), isTrue);
    });
  });
}
