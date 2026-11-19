import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/app.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/ui/feedback.dart';
import 'package:tove_chat/src/ui/live/live_overlay.dart';
import 'package:tove_chat/src/ui/theme/render_policy.dart';
import 'package:tove_chat/src/ui/thread/messages.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';

class _Sink implements FeedbackSink {
  final haptics = <Haptic>[];
  final cues = <Cue>[];
  @override
  void haptic(Haptic h) => haptics.add(h);
  @override
  void cue(Cue c) => cues.add(c);
}

/// App-level flows on the new shell. The old call-screen tests (Start
/// button, transcript sheet, wide transcript panel) are replaced by their
/// equivalents: the live button, the drawer and the wide sidebar.
void main() {
  late FakeBridge bridge;
  late FakeTransport transport;
  late FakePlatform platform;
  late MemoryKeyStore keys;
  late SettingsController settings;
  late CallController call;
  late _Sink sink;
  final verified = <(Uri, String)>[];

  Future<void> boot(
    WidgetTester tester, {
    String? key,
    bool reduce = false,
    bool native = false,
    bool chat = false,
    void Function(FakeBridge)? setup,
  }) async {
    bridge = FakeBridge()..chatEnabled = chat;
    setup?.call(bridge);
    keys = MemoryKeyStore(key);
    sink = _Sink();
    final prefs = MemoryPrefsStore();
    if (reduce) prefs.values['reduceMotion'] = 'true';
    settings = SettingsController(keys: keys, prefs: prefs);
    platform = FakePlatform(supported: native);
    final link = LiveLink();
    call = CallController(
      apiFactory: bridge.api,
      transportFactory: () => transport = FakeTransport(),
      platform: platform,
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
        verify: (u, k) async => verified.add((u, k)),
        chatApi: (s) => ChatApi(
          baseUrl: Uri.parse('https://bridge.test:9476'),
          accessKey: s.accessKey,
          client: bridge.client,
        ),
        feedbackSink: sink,
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
    await tester.pump();
  }

  Future<void> goLive(WidgetTester tester) async {
    await tester.tap(find.bySemanticsLabel('Start live voice'));
    await tester.pump();
    await tester.runAsync(() => settle(20));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Connecting…'), findsOneWidget);
    transport.emit({'type': 'session.started'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(call.phase, CallPhase.live);
  }

  /// The idle orb breathes forever, so tests advance fixed time instead of
  /// waiting for the tree to settle.
  Future<void> advance(WidgetTester tester, [int ms = 800]) async {
    for (var i = 0; i < ms ~/ 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  setUp(verified.clear);

  testWidgets('onboarding validates and stores the key securely', (
    tester,
  ) async {
    await boot(tester);
    // First run: the welcome screen; an access key is the manual path's
    // fallback (pairing codes are tested in test/pairing/).
    expect(find.text('How do I get Hermes?'), findsOneWidget);
    await tester.ensureVisible(find.text('Enter code or address'));
    await tester.tap(find.text('Enter code or address'));
    await advance(tester);
    await tester.ensureVisible(find.text('I have an access key instead'));
    await tester.tap(find.text('I have an access key instead'));
    await advance(tester);
    expect(find.text('Check and save'), findsOneWidget);
    expect(find.text('https://tove.example.com'), findsOneWidget); // hint only
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Server address'),
      'https://tove.example.com',
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Access key'),
      'short',
    );
    await tester.tap(find.text('Check and save'));
    await tester.pump();
    expect(find.text('That is too short to be the access key'), findsOneWidget);
    expect(keys.value, isNull);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Access key'),
      testKey,
    );
    await tester.tap(find.text('Check and save'));
    await tester.pump();
    await tester.pump();
    expect(verified.single.$2, testKey);
    expect(keys.value, testKey);
    await tester.runAsync(() => settle(20));
    await advance(tester); // the key and code pages close
    await tester.runAsync(() => settle(20));
    await tester.pump();
    expect(find.bySemanticsLabel('Start live voice'), findsOneWidget);
  });

  testWidgets('an old bridge (no /api/capabilities) is live only', (
    tester,
  ) async {
    await boot(tester, key: testKey);
    expect(find.text('Talk to Hermes'), findsWidgets);
    expect(find.byType(TextField), findsNothing);
    expect(bridge.to('/api/capabilities'), hasLength(1));
  });

  testWidgets('live flow: start, connecting, live, mute, end', (tester) async {
    await boot(tester, key: testKey);
    final semantics = tester.ensureSemantics();
    await goLive(tester);
    expect(bridge.to('/api/session'), hasLength(1));
    expect(sink.cues, [Cue.connected]);
    expect(find.text('Connecting…'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Mute microphone'));
    await tester.pump();
    expect(transport.muted, isTrue);
    expect(find.text('Muted'), findsOneWidget);
    expect(find.bySemanticsLabel('Unmute microphone'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('End live voice'));
    await tester.pump();
    await tester.runAsync(() => settle(10));
    await advance(tester);
    expect(call.inCall, isFalse);
    expect(find.byType(LiveOverlay), findsNothing);
    expect(find.bySemanticsLabel('Start live voice'), findsOneWidget);
    expect(transport.closed, isTrue);
    expect(bridge.to('/api/stop'), hasLength(1));
    semantics.dispose();
  });

  testWidgets('End during connecting returns at once', (tester) async {
    await boot(tester, key: testKey);
    await tester.tap(find.bySemanticsLabel('Start live voice'));
    await tester.pump();
    await tester.runAsync(() => settle(20));
    await tester.pump(const Duration(milliseconds: 250));
    expect(call.phase, CallPhase.connecting);
    await tester.tap(find.bySemanticsLabel('End live voice'));
    await tester.pump();
    expect(call.inCall, isFalse);
    await tester.runAsync(() => settle(10));
    await advance(tester);
    expect(find.byType(LiveOverlay), findsNothing);
  });

  testWidgets('the usage limit is shown plainly, not as a lost connection', (
    tester,
  ) async {
    await boot(tester, key: testKey);
    bridge
      ..sessionStatus = 429
      ..sessionError = {
        'error': 'usage_limit',
        'code': 'usage_limit',
        'message': 'GPT-Live usage limit reached',
        'retry_after_s': 3600,
      };
    await tester.tap(find.bySemanticsLabel('Start live voice'));
    await tester.pump();
    await tester.runAsync(() => settle(30));
    await tester.pump(const Duration(milliseconds: 500));
    expect(call.errorKind, CallErrorKind.usageLimit);
    expect(
      find.textContaining('You have reached your usage limit'),
      findsOneWidget,
    );
    expect(find.textContaining('Connection lost'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);
    // Reported through the haptic too, once.
    expect(sink.haptics.where((h) => h == Haptic.heavy), hasLength(1));
  });

  testWidgets('notifications-off warning shows as a toast; call stays live', (
    tester,
  ) async {
    const warning = 'Notifications are off for Tove.';
    await boot(tester, key: testKey, native: true);
    platform.startWarning = warning;
    await goLive(tester);
    expect(find.text(warning), findsOneWidget);
    expect(call.phase, CallPhase.live);
    expect(platform.calls, ['start:false']);

    await tester.tap(find.bySemanticsLabel('End live voice'));
    await tester.pump();
    await tester.runAsync(() => settle(10));
    expect(platform.calls.last, 'end');
    await advance(tester);
  });

  testWidgets('keyboard: M mutes, Escape ends', (tester) async {
    await boot(tester, key: testKey);
    await goLive(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(call.muted, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(call.inCall, isFalse);
    await tester.runAsync(() => settle(10));
    await advance(tester);
  });

  testWidgets('a task result docks the orb and shows rich text', (
    tester,
  ) async {
    await boot(tester, key: testKey);
    await goLive(tester);
    final overlay = tester.state<LiveOverlayState>(find.byType(LiveOverlay));
    expect(overlay.docked, isFalse);
    transport.emit({
      'type': 'delegation.created',
      'item': {
        'id': 'd1',
        'content': [
          {'text': 'check the disk usage on the storage box'},
        ],
      },
    });
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => settle(10));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await advance(tester, 500);
    expect(overlay.docked, isTrue);
    expect(find.textContaining('40% full'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('End live voice'));
    await tester.pump();
    await tester.runAsync(() => settle(10));
    await advance(tester);
  });

  testWidgets('phones open the drawer from the Chats button', (tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await boot(tester, key: testKey);
    expect(find.byKey(const ValueKey('drawer-avatar')), findsNothing);
    await tester.tap(find.bySemanticsLabel('Chats'));
    await advance(tester);
    expect(find.byKey(const ValueKey('drawer-avatar')), findsOneWidget);
    expect(find.byKey(const ValueKey('drawer-new-chat')), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    // Tapping the pushed content closes it.
    await tester.tapAt(const Offset(390, 400));
    await advance(tester);
    expect(find.byKey(const ValueKey('drawer-avatar')), findsNothing);
  });

  testWidgets('drawer drag: past 40 % opens, short drags spring back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await boot(tester, key: testKey);
    // 0.82 × 400 = 328 dp drawer; 25 % does not open it.
    await tester.timedDragFrom(
      const Offset(5, 400),
      const Offset(82, 0),
      const Duration(milliseconds: 600),
    );
    await advance(tester);
    expect(find.byKey(const ValueKey('drawer-avatar')), findsNothing);
    await tester.timedDragFrom(
      const Offset(5, 400),
      const Offset(180, 0),
      const Duration(milliseconds: 900),
    );
    await advance(tester);
    expect(find.byKey(const ValueKey('drawer-avatar')), findsOneWidget);
  });

  testWidgets('wide screens keep the chat list as a sidebar', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await boot(tester, key: testKey);
    expect(find.byKey(const ValueKey('drawer-avatar')), findsOneWidget);
    expect(find.bySemanticsLabel('Chats'), findsNothing);
  });

  testWidgets('text chat: send streams a reply into the thread', (
    tester,
  ) async {
    await boot(tester, key: testKey, chat: true);
    expect(find.text('What can I do for you?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'How full is the disk?');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Send message'));
    await tester.pump();
    await tester.runAsync(() => settle(50));
    await tester.pump(const Duration(milliseconds: 100));
    await advance(tester);
    expect(
      find.descendant(
        of: find.byType(UserBubble),
        matching: find.textContaining('How full is the disk?'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('40% full'), findsOneWidget);
    expect(bridge.to('/api/chat').single.body['effort'], 'medium');
    expect(sink.haptics, contains(Haptic.light));
  });

  testWidgets('a call links to the chat and imports its transcript', (
    tester,
  ) async {
    await boot(tester, key: testKey, chat: true);
    await goLive(tester);
    final session = bridge.to('/api/session').single;
    expect(session.body['conversation_id'], isNotNull);
    transport
      ..emit({
        'type': 'turn.created',
        'turn': {'role': 'user'},
      })
      ..emit({
        'type': 'turn.done',
        'turn': {'role': 'user', 'transcript': 'Is NAS-01 healthy?'},
      });
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('End live voice'));
    await tester.pump();
    await tester.runAsync(() => settle(60));
    await advance(tester);
    final post = bridge
        .to('/api/conversations/')
        .where((r) => r.path.endsWith('/live-transcript'));
    expect(post.single.body['session'], 'sid1');
    expect(find.textContaining('Is NAS-01 healthy?'), findsOneWidget);
  });

  testWidgets('a call that ends without a word leaves no chat behind', (
    tester,
  ) async {
    await boot(tester, key: testKey, chat: true);
    await goLive(tester);
    final id = bridge.to('/api/session').single.body['conversation_id'];
    expect(id, isNotNull);
    await tester.tap(find.bySemanticsLabel('End live voice'));
    await tester.pump();
    await tester.runAsync(() => settle(60));
    await advance(tester);
    expect(
      bridge
          .to('/api/conversations/')
          .where((r) => r.path.endsWith('/live-transcript')),
      isEmpty,
    );
    expect(
      bridge.requests.where(
        (r) => r.method == 'DELETE' && r.path == '/api/conversations/$id',
      ),
      hasLength(1),
    );
    expect(bridge.conversations, isEmpty);
  });

  testWidgets('switching chats while live asks first', (tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await boot(
      tester,
      key: testKey,
      chat: true,
      setup: (b) {
        b.conversations.add({
          'id': 'old1',
          'title': 'Backup report',
          'title_source': 'auto',
          'pinned': false,
          'kind': 'text',
          'created': 1794691021626,
          'updated': 1794691021626,
          'preview': 'Backups ran at 2.',
          'message_count': 1,
        });
        b.stored['old1'] = [
          {
            'id': 'om1',
            'conversation_id': 'old1',
            'role': 'assistant',
            'text': 'Backups ran at 2.',
            'source': 'text',
            'status': 'complete',
            'created': 1794691021626,
            'client_id': null,
            'meta': <String, dynamic>{},
          },
        ];
      },
    );
    await goLive(tester);
    await tester.tap(find.bySemanticsLabel('Chats'));
    await advance(tester, 600);
    await tester.tap(find.bySemanticsLabel('Backup report'));
    await advance(tester, 400);
    expect(
      find.text('End live voice and open “Backup report”?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await advance(tester, 400);
    expect(call.inCall, isTrue);

    await tester.tap(find.bySemanticsLabel('Backup report'));
    await advance(tester, 400);
    await tester.tap(find.text('End and switch'));
    await tester.pump();
    await tester.runAsync(() => settle(30));
    await advance(tester);
    expect(call.inCall, isFalse);
  });

  testWidgets('reduced motion keeps the idle orb still', (tester) async {
    await boot(tester, key: testKey, reduce: true);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('the idle orb breathes when motion is allowed', (tester) async {
    await boot(tester, key: testKey);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isTrue);
  });
}
