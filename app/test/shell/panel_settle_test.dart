import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/app.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/ui/composer/composer.dart';
import 'package:tove_chat/src/ui/thread/starter_marquee.dart';
import 'package:tove_chat/src/ui/theme/render_policy.dart';

import '../fakes.dart';
import '../ui/test_harness.dart';

/// A side panel that springs shut must read as closed afterwards.
/// `AnimationController.animateWith` always ends "completed", even at 0, so
/// a light sideways drag that sprang back left the chat list "open" at
/// value 0: the starter rows stopped and swipe up to live was refused.
void main() {
  late FakeBridge bridge;
  late CallController call;
  late SettingsController settings;

  setUpAll(() async {
    await loadAppFonts();
  });

  Future<void> advance(WidgetTester tester, [int ms = 800]) async {
    for (var i = 0; i < ms ~/ 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> boot(WidgetTester tester) async {
    phoneSize(tester);
    bridge = FakeBridge()..chatEnabled = true;
    settings = SettingsController(
      keys: MemoryKeyStore(testKey),
      prefs: MemoryPrefsStore(),
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

  Future<void> drag(
    WidgetTester tester,
    Offset from,
    Offset by, {
    int steps = 10,
  }) async {
    var t = const Duration(seconds: 1);
    final g = await tester.createGesture();
    await g.down(from, timeStamp: t);
    for (var i = 0; i < steps; i++) {
      t += const Duration(milliseconds: 40);
      await g.moveBy(by / steps.toDouble(), timeStamp: t);
      await tester.pump(const Duration(milliseconds: 40));
    }
    // Held still before lifting: no fling.
    t += const Duration(milliseconds: 200);
    await tester.pump(const Duration(milliseconds: 200));
    await g.up(timeStamp: t);
    await advance(tester, 1200);
  }

  bool marqueeTicking(WidgetTester tester) =>
      tester.state<StarterMarqueeState>(find.byType(StarterMarquee)).isTicking;

  Rect composer(WidgetTester tester) => tester.getRect(find.byType(Composer));

  Future<void> swipeUpToLive(WidgetTester tester) async {
    // A deliberate pull past the threshold (about 18 % of the screen).
    await drag(tester, composer(tester).center, const Offset(2, -200));
    await tester.runAsync(() => settle(20));
    await advance(tester, 600);
  }

  Finder liveOpen() => find.bySemanticsLabel('End live voice');

  testWidgets('a short sideways drag that springs back leaves the chat list '
      'closed: the starters drift and swipe up opens live', (tester) async {
    await boot(tester);
    expect(marqueeTicking(tester), isTrue);
    // Rightward, well short of the open threshold, released without speed.
    await drag(tester, const Offset(120, 300), const Offset(40, 0));
    expect(find.text('Chats'), findsNothing);
    expect(marqueeTicking(tester), isTrue);
    await swipeUpToLive(tester);
    expect(liveOpen(), findsWidgets);
    await tester.runAsync(() => call.end());
    await advance(tester, 800);
  });

  testWidgets('the chat list swiped open then shut reads as closed', (
    tester,
  ) async {
    await boot(tester);
    await drag(tester, const Offset(40, 300), const Offset(260, 0));
    expect(marqueeTicking(tester), isFalse, reason: 'covered by the list');
    await drag(tester, const Offset(380, 300), const Offset(-300, 0));
    expect(marqueeTicking(tester), isTrue);
    await swipeUpToLive(tester);
    expect(liveOpen(), findsWidgets);
    await tester.runAsync(() => call.end());
    await advance(tester, 800);
  });

  testWidgets('with reduced motion too', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await boot(tester);
    await drag(tester, const Offset(40, 300), const Offset(260, 0));
    await drag(tester, const Offset(380, 300), const Offset(-300, 0));
    await swipeUpToLive(tester);
    expect(liveOpen(), findsWidgets);
    await tester.runAsync(() => call.end());
    await advance(tester, 800);
  });
}
