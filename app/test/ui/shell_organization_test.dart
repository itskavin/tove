import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/app.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/ui/feedback.dart';
import 'package:tove_chat/src/ui/theme/render_policy.dart';
import 'package:tove_chat/src/ui/thread/messages.dart';

import '../fakes.dart';
import 'test_harness.dart';

class _NoFeedback implements FeedbackSink {
  @override
  void haptic(Haptic h) {}
  @override
  void cue(Cue c) {}
}

Map<String, dynamic> _conv(String id, String title) => {
  'id': id,
  'title': title,
  'title_source': 'user',
  'pinned': false,
  'kind': 'text',
  'created': 1794691021626,
  'updated': 1794691021626,
  'preview': '',
  'message_count': 0,
};

/// The shell after this round: the Tasks panel from the right, the folding
/// desktop sidebar, and Send closing the on-screen keyboard.
void main() {
  late FakeBridge bridge;
  late FakeTransport transport;
  late CallController call;
  late SettingsController settings;

  Future<void> advance(WidgetTester tester, [int ms = 800]) async {
    for (var i = 0; i < ms ~/ 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> boot(
    WidgetTester tester, {
    Size size = const Size(412, 915),
    MemoryPrefsStore? prefs,
    void Function(FakeBridge)? setup,
  }) async {
    phoneSize(tester, size: size);
    bridge = FakeBridge()..chatEnabled = true;
    setup?.call(bridge);
    settings = SettingsController(
      keys: MemoryKeyStore(testKey),
      prefs: prefs ?? MemoryPrefsStore(),
    );
    final link = LiveLink();
    call = CallController(
      apiFactory: bridge.api,
      transportFactory: () => transport = FakeTransport(),
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
        feedbackSink: _NoFeedback(),
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

  /// A text field has the focus (so a phone shows its keyboard).
  bool composerFocused(WidgetTester tester) => find
      .byType(EditableText)
      .evaluate()
      .any((e) => (e.widget as EditableText).focusNode.hasFocus);

  void focusLabelled(WidgetTester tester, String label) => tester
      .widget<Focus>(
        find.byWidgetPredicate(
          (w) => w is Focus && w.focusNode?.debugLabel == label,
        ),
      )
      .focusNode!
      .requestFocus();

  final tasksPanel = find.byKey(const ValueKey('tasks-panel'));

  // The swipe rule (user decision, 16 Nov 2026): rightward opens the chat
  // list from the left, leftward this chat's Tasks from the right edge.
  group('Tasks by a leftward swipe, chats by a rightward one', () {
    testWidgets('a leftward swipe on the chat opens this chat’s tasks; a '
        'rightward one opens the chat list; Back and Escape close', (
      tester,
    ) async {
      await boot(
        tester,
        setup: (b) {
          b.conversations.add(_conv('c1', 'Disk check'));
          b.stored['c1'] = [];
        },
      );
      await tester.timedDragFrom(
        const Offset(330, 200),
        const Offset(-220, 0),
        const Duration(milliseconds: 500),
      );
      await advance(tester);
      expect(tasksPanel, findsOneWidget);
      expect(find.text('Nothing running in this chat'), findsOneWidget);
      expect(find.byKey(const ValueKey('drawer-avatar')), findsNothing);

      await tester.binding.handlePopRoute();
      await advance(tester);
      expect(tasksPanel, findsNothing, reason: 'Back closes it, app stays');

      await tester.timedDragFrom(
        const Offset(120, 200),
        const Offset(220, 0),
        const Duration(milliseconds: 500),
      );
      await advance(tester);
      expect(find.byKey(const ValueKey('drawer-avatar')), findsOneWidget);
      expect(tasksPanel, findsNothing);
      // The sidebar: the app's name and one search icon; no Search or
      // Settings rows (Settings is in the avatar's menu).
      expect(find.text('Tove'), findsOneWidget);
      expect(find.byTooltip('Search chats'), findsOneWidget);
      expect(find.text('Search chats'), findsNothing);
      expect(find.text('Settings'), findsNothing);
      await tester.tap(find.byTooltip('Search chats'));
      await advance(tester, 300);
      expect(find.byKey(const ValueKey('drawer-search-field')), findsOneWidget);
      expect(composerFocused(tester), isTrue, reason: 'the field takes focus');
      await tester.tap(find.byTooltip('Close search'));
      await advance(tester, 300);
      expect(find.text('Tove'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await advance(tester);

      // Chat options opens it too (screen readers, no swipe needed).
      await tester.tap(find.bySemanticsLabel('Chats'));
      await tester.runAsync(() => settle(20));
      await advance(tester, 600);
      await tester.tap(find.text('Disk check'));
      await tester.runAsync(() => settle(20));
      await advance(tester, 600);
      await tester.tap(find.bySemanticsLabel('Chat options'));
      await advance(tester, 400);
      await tester.tap(find.text('Tasks'));
      await advance(tester);
      expect(tasksPanel, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await advance(tester);
      expect(tasksPanel, findsNothing);
    });

    testWidgets('the system back-gesture edge is left to the system', (
      tester,
    ) async {
      await boot(tester);
      tester.view.systemGestureInsets = const FakeViewPadding(left: 30);
      addTearDown(tester.view.resetSystemGestureInsets);
      await tester.timedDragFrom(
        const Offset(12, 450),
        const Offset(220, 0),
        const Duration(milliseconds: 500),
      );
      await advance(tester);
      expect(tasksPanel, findsNothing);
      expect(find.byKey(const ValueKey('drawer-avatar')), findsNothing);
    });

    testWidgets('an active text selection or a slider keeps the swipe off', (
      tester,
    ) async {
      await boot(tester);
      ThreadSelection.set('m1', true);
      addTearDown(() => ThreadSelection.set('m1', false));
      await tester.timedDragFrom(
        const Offset(120, 450),
        const Offset(220, 0),
        const Duration(milliseconds: 500),
      );
      await advance(tester);
      expect(tasksPanel, findsNothing);
      expect(find.byKey(const ValueKey('drawer-avatar')), findsNothing);
    });

    testWidgets('in live mode a rightward swipe opens the chat list and a '
        'leftward one nothing (live work shows under the orb)', (tester) async {
      await boot(tester);
      await tester.tap(find.bySemanticsLabel('Start live voice'));
      await tester.pump();
      await tester.runAsync(() => settle(20));
      transport.emit({'type': 'session.started'});
      await advance(tester, 900);
      expect(call.phase, CallPhase.live);
      await tester.timedDragFrom(
        const Offset(330, 300),
        const Offset(-220, 0),
        const Duration(milliseconds: 500),
      );
      await advance(tester);
      expect(tasksPanel, findsNothing);
      expect(find.byKey(const ValueKey('drawer-avatar')), findsNothing);
      await tester.timedDragFrom(
        const Offset(120, 300),
        const Offset(220, 0),
        const Duration(milliseconds: 500),
      );
      await advance(tester);
      expect(tasksPanel, findsNothing);
      expect(find.byKey(const ValueKey('drawer-avatar')), findsOneWidget);
      await tester.runAsync(() => call.end());
      await advance(tester, 800);
    });
  });

  group('desktop sidebar', () {
    testWidgets('folds into a rail and back, keeps the chat and remembers it; '
        'phones keep the drawer', (tester) async {
      final prefs = MemoryPrefsStore();
      void chats(FakeBridge b) {
        b.conversations.add(_conv('c1', 'Disk check'));
        b.stored['c1'] = [];
      }

      await boot(
        tester,
        size: const Size(1280, 800),
        prefs: prefs,
        setup: chats,
      );
      // An empty new chat centres the composer (greeting above it).
      expect(tester.getCenter(find.byType(TextField)).dy, closeTo(368, 40));
      await tester.tap(find.text('Disk check'));
      await tester.runAsync(() => settle(20));
      await advance(tester, 600);
      // An opened chat: the pane fills the height, the composer at the
      // bottom.
      expect(
        tester.getRect(find.byType(TextField)).bottom,
        greaterThan(800 - 12 - 8),
      );

      await tester.tap(find.byTooltip('Collapse sidebar'));
      await advance(tester, 600);
      expect(prefs.values['sidebarCollapsed'], 'true');
      // The chat list is folded away (the header still shows the title).
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('sidebar')),
          matching: find.text('Disk check'),
        ),
        findsNothing,
      );
      for (final tip in [
        'Open sidebar',
        'New chat',
        'Search chats',
        'Tasks',
        'Menu',
      ]) {
        expect(find.byTooltip(tip), findsWidgets, reason: tip);
      }
      expect(tester.getSize(find.byKey(const ValueKey('sidebar'))).width, 52);
      // One Tasks button: the rail's (the header leaves it out).
      expect(find.byKey(const ValueKey('tasks-button')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('rail-tasks')));
      await advance(tester);
      expect(tasksPanel, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await advance(tester);

      await tester.tap(find.byKey(const ValueKey('sidebar-expand')));
      await advance(tester, 600);
      expect(prefs.values['sidebarCollapsed'], 'false');
      expect(
        tester.getSemantics(
          find.descendant(
            of: find.byKey(const ValueKey('sidebar')),
            matching: find.text('Disk check'),
          ),
        ),
        isSemantics(isSelected: true),
        reason: 'the open chat is still selected',
      );

      // Search from the rail opens the list with its field focused.
      await tester.tap(find.byTooltip('Collapse sidebar'));
      await advance(tester, 600);
      await tester.tap(find.byKey(const ValueKey('rail-search')));
      await advance(tester, 600);
      expect(find.byKey(const ValueKey('drawer-search-field')), findsOneWidget);
      expect(composerFocused(tester), isTrue, reason: 'search field focused');
      await tester.tap(find.byTooltip('Close search'));
      await tester.tap(find.byTooltip('Collapse sidebar'));
      await advance(tester, 600);

      // A restart keeps it folded.
      await tester.pumpWidget(const SizedBox());
      await boot(
        tester,
        size: const Size(1280, 800),
        prefs: prefs,
        setup: chats,
      );
      expect(find.byKey(const ValueKey('sidebar-expand')), findsOneWidget);

      // Narrow: the drawer as always, no rail, no fold button.
      tester.view.physicalSize = const Size(412, 915);
      await advance(tester, 400);
      expect(find.byKey(const ValueKey('sidebar-expand')), findsNothing);
      await tester.tap(find.bySemanticsLabel('Chats'));
      await advance(tester, 600);
      expect(find.byKey(const ValueKey('drawer-avatar')), findsOneWidget);
      expect(find.byTooltip('Collapse sidebar'), findsNothing);
      await tester.binding.handlePopRoute();
      await advance(tester, 600);
      expect(find.byKey(const ValueKey('drawer-avatar')), findsNothing);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('keyboard users land on the toggle that replaces the one '
        'they pressed', (tester) async {
      await boot(tester, size: const Size(1280, 800));
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      focusLabelled(tester, 'collapse sidebar');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await advance(tester, 600);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'expand sidebar');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await advance(tester, 600);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'collapse sidebar',
      );
    });
  });

  group('Send closes the on-screen keyboard', () {
    testWidgets('a Send tap on a phone: the message goes, the keyboard '
        'closes, the prompt stays where it settled', (tester) async {
      await boot(tester);
      await tester.tap(find.byType(TextField));
      tester.view.viewInsets = const FakeViewPadding(bottom: 420);
      await tester.pump();
      expect(composerFocused(tester), isTrue);
      await tester.enterText(find.byType(TextField), 'How full is /srv?');
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Send message'));
      await tester.pump();
      expect(composerFocused(tester), isFalse, reason: 'keyboard closes');
      expect(bridge.to('/api/chat'), hasLength(1));
      await tester.runAsync(() => settle(40));
      await advance(tester, 1200);
      final before = tester.getRect(find.text('How full is /srv?').last).top;
      tester.view.resetViewInsets();
      await advance(tester, 600);
      expect(
        tester.getRect(find.text('How full is /srv?').last).top,
        closeTo(before, 1),
      );
      expect(
        composerFocused(tester),
        isFalse,
        reason: 'the finished reply does not take the focus back',
      );
    });

    testWidgets('a hardware keyboard keeps the field: Enter sends and the '
        'Send click keeps focus', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await boot(tester, size: const Size(1280, 800));
        await tester.tap(find.byType(TextField));
        await tester.enterText(find.byType(TextField), 'First');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(bridge.to('/api/chat'), hasLength(1));
        expect(composerFocused(tester), isTrue);
        await tester.runAsync(() => settle(40));
        await advance(tester, 1200);
        await tester.enterText(find.byType(TextField), 'Second');
        await tester.pump();
        // ignore: avoid_print
        await tester.tap(
          find.bySemanticsLabel('Send message'),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        expect(bridge.to('/api/chat'), hasLength(2));
        expect(composerFocused(tester), isTrue, reason: 'no soft keyboard');
        await tester.runAsync(() => settle(40));
        await advance(tester, 1200);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('typing in live mode shows Send; tapping it sends and closes '
        'the keyboard, and the call goes on', (tester) async {
      await boot(tester);
      await tester.tap(find.bySemanticsLabel('Start live voice'));
      await tester.pump();
      await tester.runAsync(() => settle(20));
      transport.emit({'type': 'session.started'});
      await advance(tester, 900);
      expect(call.phase, CallPhase.live);
      expect(find.byKey(const ValueKey('live-send')), findsNothing);
      await tester.tap(find.byType(TextField));
      tester.view.viewInsets = const FakeViewPadding(bottom: 420);
      await tester.enterText(find.byType(TextField), 'Also the backups');
      await tester.pump();
      final send = find.byKey(const ValueKey('live-send'));
      expect(send, findsOneWidget);
      await tester.tap(send);
      await tester.pump();
      expect(bridge.to('/api/chat'), hasLength(1));
      expect(composerFocused(tester), isFalse);
      expect(call.phase, CallPhase.live);
      tester.view.resetViewInsets();
      await tester.runAsync(() => settle(40));
      await advance(tester, 1200);
      await tester.runAsync(() => call.end());
      await advance(tester, 800);
    });
  });
}
