import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/app.dart';
import 'package:tove_chat/src/brand.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/ui/drawer/date_groups.dart';
import 'package:tove_chat/src/ui/feedback.dart';
import 'package:tove_chat/src/ui/shell/drawer_swipe.dart';
import 'package:tove_chat/src/ui/theme/render_policy.dart';
import 'package:tove_chat/src/ui/thread/messages.dart';
import 'package:material_ui/material_ui.dart';

import '../fakes.dart';
import 'test_harness.dart';

class _NoFeedback implements FeedbackSink {
  @override
  void haptic(Haptic h) {}
  @override
  void cue(Cue c) {}
}

final _t0 = DateTime(2026, 11, 15, 10);

Finder _tip(String message) =>
    find.byWidgetPredicate((w) => w is Tooltip && w.message == message);

Conversation _c(String id, DateTime updated, {bool pinned = false}) =>
    Conversation(
      id: id,
      title: id,
      created: updated,
      updated: updated,
      pinned: pinned,
    );

ChatProgress _p(
  String state, {
  String id = '',
  String tool = '',
  String label = '',
}) => ChatProgress.fromJson({
  'state': state,
  'id': id,
  'tool': tool,
  'label': label,
  'emoji': '',
});

void main() {
  group('brand', () {
    test('app name is Tove, the agent stays Hermes', () {
      expect(Brand.appName, 'Tove');
      expect(Brand.assistantName, 'Hermes');
      expect(Brand.serverName, 'Hermes server');
    });
  });

  group('sidebar swipe rules (chat-rendering-v2 §4.2)', () {
    test('needs 16 dp of travel within 32° of horizontal', () {
      expect(DrawerSwipeRecognizer.accepts(const Offset(15, 0), 1), isFalse);
      expect(DrawerSwipeRecognizer.accepts(const Offset(16, 0), 1), isTrue);
      expect(DrawerSwipeRecognizer.accepts(const Offset(32, 20), 1), isTrue);
      expect(DrawerSwipeRecognizer.accepts(const Offset(30, 20), 1), isFalse);
      expect(DrawerSwipeRecognizer.accepts(const Offset(20, -40), 1), isFalse);
    });

    test('closed: rightward only; open: both ways', () {
      expect(DrawerSwipeRecognizer.accepts(const Offset(-40, 0), 1), isFalse);
      expect(DrawerSwipeRecognizer.accepts(const Offset(-40, 0), 0), isTrue);
      expect(DrawerSwipeRecognizer.accepts(const Offset(40, 0), 0), isTrue);
    });

    test('release: fling 365 dp/s, else 40 % opening / 60 % staying open', () {
      bool open(double p, double v, bool wasOpen) =>
          drawerShouldOpen(progress: p, velocity: v, startedOpen: wasOpen);
      expect(open(0.1, 400, false), isTrue);
      expect(open(0.9, -400, true), isFalse);
      expect(open(0.39, 0, false), isFalse);
      expect(open(0.4, 0, false), isTrue);
      expect(open(0.59, 0, true), isFalse);
      expect(open(0.6, 0, true), isTrue);
      expect(open(0.5, 300, true), isFalse);
    });

    test('rubber band: 0.15 × the finger, at most 24 dp', () {
      expect(drawerOvershoot(1, 300), 0);
      expect(drawerOvershoot(1.2, 300) * 300, closeTo(9, 0.01));
      expect(drawerOvershoot(2, 300) * 300, 24);
    });
  });

  group('drawer date groups', () {
    test('Today, Yesterday, 7 and 30 days, then months', () {
      final groups = groupChatsByDate([
        _c('a', _t0.subtract(const Duration(hours: 2))),
        _c('b', _t0.subtract(const Duration(days: 1))),
        _c('c', _t0.subtract(const Duration(days: 5))),
        _c('d', _t0.subtract(const Duration(days: 20))),
        _c('e', DateTime(2026, 3, 2)),
        _c('f', DateTime(2025, 12, 30)),
      ], now: _t0);
      expect(groups.map((g) => g.$1), [
        'Today',
        'Yesterday',
        'Previous 7 days',
        'Previous 30 days',
        'March',
        'December 2025',
      ]);
      expect(groups.first.$2.single.id, 'a');
    });
  });

  group('tool calls', () {
    test('running → completed by id; info skipped; end fails the rest', () {
      final log = ToolCallLog();
      log.record(
        _p('running', id: 't1', tool: 'terminal', label: 'df -h'),
        12,
        _t0,
      );
      log.record(_p('info', label: 'Waiting for the provider'), 12, _t0);
      log.record(
        _p('completed', id: 't1', tool: 'terminal', label: 'terminal'),
        12,
        _t0.add(const Duration(seconds: 3)),
      );
      log.record(
        _p('running', id: 't2', tool: 'web_search', label: 'q'),
        30,
        _t0,
      );
      log.finish(_t0.add(const Duration(seconds: 9)), failed: true);
      expect(log.calls, hasLength(2));
      expect(log.calls[0].state, ToolCallState.done);
      expect(log.calls[0].label, 'df -h', reason: 'keeps the start preview');
      expect(log.calls[0].elapsed(_t0).inSeconds, 3);
      expect(log.calls[1].state, ToolCallState.failed);
    });
  });

  group('message text helpers', () {
    test('plain text drops marks, footnotes and hermes-ui', () {
      const md =
          '## Disks\n\n**NAS-01** is at 40%.[^1]\n\n'
          '```hermes-ui\n{"v":1}\n```\n\n'
          '| Disk | Use |\n|---|---|\n| sda | 40% |\n\n'
          '[^1]: [Status](https://x.test) — Status';
      expect(
        plainText(md),
        'Disks\n\nNAS-01 is at 40%.\n\nInteractive content.\n\nDisk  Use\nsda  40%',
      );
    });

    test('tables copy as TSV', () {
      expect(markdownTables('| A | **B** |\n|:--|--:|\n| 1 | 2 |\n'), [
        'A\tB\n1\t2',
      ]);
      expect(markdownTables('```\n| a | b |\n|---|---|\n```'), isEmpty);
    });

    test('message time header', () {
      expect(messageTime(_t0, now: _t0), 'Today · 10:00');
      expect(
        messageTime(_t0.subtract(const Duration(days: 1)), now: _t0),
        'Yesterday · 10:00',
      );
      expect(
        messageTime(DateTime(2026, 11, 3, 9, 2), now: _t0),
        '3 Nov · 09:02',
      );
    });
  });

  group('shell', () {
    late FakeBridge bridge;
    late CallController call;
    late SettingsController settings;

    Future<void> boot(
      WidgetTester tester, {
      void Function(FakeBridge)? setup,
    }) async {
      phoneSize(tester);
      bridge = FakeBridge()..chatEnabled = true;
      setup?.call(bridge);
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

    Future<void> advance(WidgetTester tester, [int ms = 800]) async {
      for (var i = 0; i < ms ~/ 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Map<String, dynamic> conv(String id, String title) => {
      'id': id,
      'title': title,
      'title_source': 'user',
      'pinned': false,
      'kind': 'text',
      'created': DateTime.now().millisecondsSinceEpoch,
      'updated': DateTime.now().millisecondsSinceEpoch,
      'preview': '',
      'message_count': 2,
    };

    Map<String, dynamic> msg(String id, String role, String text) => {
      'id': id,
      'conversation_id': 'c1',
      'role': role,
      'text': text,
      'source': 'text',
      'status': 'complete',
      'created': DateTime.now().millisecondsSinceEpoch,
      'client_id': null,
      'meta': <String, dynamic>{},
    };

    Future<void> openChat(WidgetTester tester, String reply) async {
      await boot(
        tester,
        setup: (b) {
          b.conversations.add(conv('c1', 'Disk check'));
          b.stored['c1'] = [
            msg('m1', 'user', 'How full are the disks?'),
            msg('m2', 'assistant', reply),
          ];
        },
      );
      await tester.tap(find.bySemanticsLabel('Chats'));
      await advance(tester, 600);
      await tester.tap(find.text('Disk check'));
      await tester.runAsync(() => settle(20));
      await advance(tester, 800);
    }

    bool drawerOpen(WidgetTester tester) => find
        .byKey(const ValueKey('drawer-avatar'))
        .hitTestable()
        .evaluate()
        .isNotEmpty;

    bool tasksOpen(WidgetTester tester) => find
        .byKey(const ValueKey('tasks-panel'))
        .hitTestable()
        .evaluate()
        .isNotEmpty;

    // The swipe rule (user decision, 16 Nov 2026): rightward opens the chat
    // list from the left, leftward this chat's Tasks from the right; each
    // closes with the opposite swipe.
    testWidgets('a rightward swipe anywhere on the chat opens the chat list; '
        'a leftward one closes it', (tester) async {
      await openChat(tester, 'NAS-01 is at **40%**.');
      expect(drawerOpen(tester), isFalse);
      // From the middle of a reply, far from the edge.
      await tester.dragFrom(const Offset(200, 300), const Offset(220, 6));
      await advance(tester, 600);
      expect(drawerOpen(tester), isTrue);
      expect(tasksOpen(tester), isFalse);
      await tester.dragFrom(const Offset(380, 500), const Offset(-220, 0));
      await advance(tester, 600);
      expect(drawerOpen(tester), isFalse);
      expect(tasksOpen(tester), isFalse);
    });

    testWidgets('a leftward swipe opens this chat\'s Tasks from the right '
        'edge; a rightward one closes them', (tester) async {
      await openChat(tester, 'NAS-01 is at **40%**.');
      await tester.dragFrom(const Offset(320, 300), const Offset(-240, 4));
      await advance(tester, 600);
      expect(tasksOpen(tester), isTrue);
      expect(drawerOpen(tester), isFalse);
      // The panel came in from the right edge.
      expect(
        tester.getTopRight(find.byKey(const ValueKey('tasks-panel'))).dx,
        412,
      );
      await tester.dragFrom(const Offset(60, 500), const Offset(240, 0));
      await advance(tester, 600);
      expect(tasksOpen(tester), isFalse);
      expect(drawerOpen(tester), isFalse);
    });

    testWidgets('Back closes either panel', (tester) async {
      await openChat(tester, 'NAS-01 is at **40%**.');
      await tester.dragFrom(const Offset(320, 300), const Offset(-240, 4));
      await advance(tester, 600);
      expect(tasksOpen(tester), isTrue);
      await tester.binding.handlePopRoute();
      await advance(tester, 600);
      expect(tasksOpen(tester), isFalse);
      await tester.dragFrom(const Offset(100, 300), const Offset(240, 4));
      await advance(tester, 600);
      expect(drawerOpen(tester), isTrue);
      await tester.binding.handlePopRoute();
      await advance(tester, 600);
      expect(drawerOpen(tester), isFalse);
    });

    testWidgets('swipes never start in the system back-gesture strips', (
      tester,
    ) async {
      tester.view.systemGestureInsets = const FakeViewPadding(
        left: 30,
        right: 30,
      );
      addTearDown(tester.view.resetSystemGestureInsets);
      await openChat(tester, 'NAS-01 is at **40%**.');
      // Inside the 30 dp insets: the system's Back.
      await tester.dragFrom(const Offset(10, 300), const Offset(240, 6));
      await advance(tester, 600);
      expect(drawerOpen(tester), isFalse);
      await tester.dragFrom(const Offset(402, 300), const Offset(-240, 6));
      await advance(tester, 600);
      expect(tasksOpen(tester), isFalse);
      // Just past them: the chat list.
      await tester.dragFrom(const Offset(40, 300), const Offset(240, 6));
      await advance(tester, 600);
      expect(drawerOpen(tester), isTrue);
    });

    testWidgets('a swipe that starts on reply text opens the chat list with '
        'the phone\'s 8 dp touch slop (text selection must not take it)', (
      tester,
    ) async {
      // Android reports an 8 dp touch slop; the selection area's drag
      // recognizer would accept at that slop, before the swipe's 16 dp.
      tester.view.gestureSettings = const ui.GestureSettings(
        physicalTouchSlop: 8,
      );
      addTearDown(tester.view.resetGestureSettings);
      await openChat(tester, 'NAS-01 is at **40%** of its capacity today.');
      final text = find.textContaining('of its capacity', findRichText: true);
      expect(text, findsWidgets);
      await tester.dragFrom(
        tester.getTopLeft(text.first) + const Offset(20, 10),
        const Offset(240, 6),
      );
      await advance(tester, 600);
      expect(drawerOpen(tester), isTrue);
    });

    testWidgets('scroll-to-latest shows more than a screen up and returns', (
      tester,
    ) async {
      await openChat(
        tester,
        List.generate(120, (i) => 'Paragraph ${i + 1}.').join('\n\n'),
      );
      // Hit-testable: a hidden button ignores pointers.
      Finder jump() => find.bySemanticsLabel('Scroll to latest').hitTestable();
      expect(jump(), findsNothing, reason: 'opens at the end');
      for (var i = 0; i < 4; i++) {
        await tester.dragFrom(const Offset(200, 300), const Offset(0, 500));
        await advance(tester, 300);
      }
      expect(jump(), findsOneWidget);
      await tester.tap(jump());
      await advance(tester, 800);
      expect(find.text('Paragraph 120.'), findsOneWidget);
      expect(jump(), findsNothing);
    });

    testWidgets('a mostly vertical drag scrolls and never opens it', (
      tester,
    ) async {
      await openChat(tester, 'Line\n\n' * 40);
      await tester.dragFrom(const Offset(200, 500), const Offset(60, -200));
      await advance(tester, 600);
      expect(drawerOpen(tester), isFalse);
      expect(tasksOpen(tester), isFalse);
    });

    testWidgets('short flings open the panels', (tester) async {
      await openChat(tester, 'Short reply.');
      await tester.flingFrom(const Offset(150, 400), const Offset(80, 0), 900);
      await advance(tester, 800);
      expect(drawerOpen(tester), isTrue);
      expect(tasksOpen(tester), isFalse);
      await tester.binding.handlePopRoute();
      await advance(tester, 600);
      await tester.flingFrom(const Offset(260, 400), const Offset(-80, 0), 900);
      await advance(tester, 800);
      expect(tasksOpen(tester), isTrue);
      expect(drawerOpen(tester), isFalse);
    });

    testWidgets('the empty state swipes open too', (tester) async {
      await boot(tester);
      // Above the starter rows (they scroll sideways themselves).
      await tester.dragFrom(const Offset(200, 200), const Offset(220, 0));
      await advance(tester, 600);
      expect(drawerOpen(tester), isTrue);
    });

    testWidgets('a wide table scrolls first, then hands off at its start', (
      tester,
    ) async {
      final table = [
        '| ${List.generate(8, (i) => 'Column $i').join(' | ')} |',
        '|${List.filled(8, '---').join('|')}|',
        '| ${List.generate(8, (i) => 'value number $i').join(' | ')} |',
      ].join('\n');
      await openChat(tester, 'Here:\n\n$table');
      final cell = find.text('value number 0');
      expect(cell, findsOneWidget);
      final at = tester.getCenter(cell);
      // Scroll the table left (finger moves left): no panel at its end.
      await tester.dragFrom(at, const Offset(-200, 0));
      await advance(tester, 400);
      expect(drawerOpen(tester), isFalse);
      expect(tasksOpen(tester), isFalse);
      // Back to its start, then on: the chat swipe (the chat list) takes
      // over.
      await tester.dragFrom(
        tester.getCenter(find.text('value number 1')),
        const Offset(500, 0),
      );
      await advance(tester, 800);
      expect(drawerOpen(tester), isTrue);
      expect(tasksOpen(tester), isFalse);
    });

    testWidgets('New chat: hidden on an empty chat, starts one from a chat', (
      tester,
    ) async {
      await boot(tester);
      // Only the drawer's own "New chat" pill exists (off screen).
      expect(_tip('New chat'), findsNothing);
    });

    testWidgets('New chat in the header leaves the chat for an empty one', (
      tester,
    ) async {
      await openChat(tester, 'NAS-01 is at 40%.');
      final button = _tip('New chat');
      expect(button, findsOneWidget);
      expect(tester.getSize(button).width, greaterThanOrEqualTo(48));
      await tester.tap(button);
      await advance(tester, 600);
      expect(find.text('NAS-01 is at 40%.'), findsNothing);
      expect(find.text('What can I do for you?'), findsOneWidget);
    });

    testWidgets('the action row: Copy and Share, Retry in the More menu', (
      tester,
    ) async {
      await openChat(tester, 'NAS-01 is at **40%**.');
      expect(_tip('Copy'), findsOneWidget);
      expect(_tip('Share'), findsOneWidget);
      expect(_tip('Retry'), findsNothing, reason: 'Retry moved into More');
      expect(
        _tip('Read aloud'),
        findsNothing,
        reason: 'hidden until the speech module is wired',
      );
      await tester.tap(_tip('More'));
      await advance(tester, 400);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Fork to new chat'), findsOneWidget);
      expect(find.text('Share'), findsNothing, reason: 'on the row already');
      expect(find.text('Copy as markdown'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(find.textContaining('·'), findsWidgets, reason: 'time header');
    });

    testWidgets('an assistant message from /api/notify offers no Retry', (
      tester,
    ) async {
      await boot(
        tester,
        setup: (b) {
          b.conversations.add(conv('c1', 'Disk check'));
          b.stored['c1'] = [
            msg('m1', 'user', 'How full are the disks?'),
            msg('m2', 'assistant', 'NAS-01 is at 40%.'),
            {
              ...msg('m3', 'assistant', 'Homelab needs attention.'),
              'source': 'notify',
              'meta': <String, dynamic>{'notify': 'alert'},
            },
          ];
        },
      );
      await tester.tap(find.bySemanticsLabel('Chats'));
      await advance(tester, 600);
      await tester.tap(find.text('Disk check'));
      await tester.runAsync(() => settle(20));
      await advance(tester, 800);
      expect(find.text('Homelab needs attention.'), findsOneWidget);
      expect(_tip('Copy'), findsWidgets);
      // The bridge would answer the last user message again and delete the
      // alert; the older reply is no longer the newest either.
      await tester.tap(_tip('More').last);
      await advance(tester, 400);
      expect(find.text('Retry'), findsNothing);
    });
  });
}
