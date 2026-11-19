import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/app.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/ui/composer/composer.dart';
import 'package:tove_chat/src/ui/feedback.dart';
import 'package:tove_chat/src/ui/shell/live_swipe.dart';
import 'package:tove_chat/src/ui/theme/render_policy.dart';
import 'package:tove_chat/src/ui/thread/starter_marquee.dart';
import 'package:tove_chat/src/ui/thread/starter_prompts.dart';

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

/// Navigation chrome (round 3): the header pill, the gap above the
/// composer, swipe up to live, fresh starter prompts, pull to refresh in the
/// chat list, and the desktop rail and sidebar.
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

  /// Saves a synthetic render for the orchestrator when
  /// TOVE_QA_RENDER_DIR is set (never a device capture).
  Future<void> render(WidgetTester tester, String name, String note) async {
    final dir = Platform.environment['TOVE_QA_RENDER_DIR'];
    if (dir == null || dir.isEmpty) return;
    final view = tester.binding.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    final size = view.size;
    await tester.runAsync(() async {
      final shot = await layer.toImage(Offset.zero & size, pixelRatio: 1);
      const band = 44.0;
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawImage(shot, Offset.zero, Paint());
      c.drawRect(
        Rect.fromLTWH(0, size.height, size.width, band),
        Paint()..color = const Color(0xFFFFD54F),
      );
      final pb =
          ui.ParagraphBuilder(
              ui.ParagraphStyle(fontSize: 11, fontFamily: 'Roboto'),
            )
            ..pushStyle(ui.TextStyle(color: const Color(0xFF000000)))
            ..addText(
              'SYNTHETIC FLUTTER TEST RENDER (not a device capture) '
              '2026-11-16 · $name\n$note',
            );
      final para = pb.build()
        ..layout(ui.ParagraphConstraints(width: size.width - 12));
      c.drawParagraph(para, Offset(6, size.height + 4));
      final img = await rec.endRecording().toImage(
        size.width.round(),
        (size.height + band).round(),
      );
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      File('$dir/$name.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  Future<void> golden(WidgetTester tester, String name) => expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/chrome_$name.png'),
  );

  Rect composerRect(WidgetTester tester) =>
      tester.getRect(find.byType(Composer));

  group('header pill (phones)', () {
    testWidgets('New chat and More share one 96 × 44 pill; the menu is its '
        'own circle', (tester) async {
      await boot(tester, setup: seed);
      await openChat(tester, 'Disk check');
      final pill = tester.getRect(find.byKey(const ValueKey('header-pill')));
      final newChat = tester.getRect(find.byKey(const ValueKey('new-chat')));
      final more = tester.getRect(find.byKey(const ValueKey('more-button')));
      expect(pill.width, 96);
      expect(newChat.height, 44);
      expect(newChat.width, 48);
      expect(more.width, 48);
      expect(more.center.dx - newChat.center.dx, 48);
      expect(newChat.center.dy, more.center.dy);
      expect(pill.right, closeTo(412 - 12, 0.5), reason: '12 dp edge');
      final menu = tester.getRect(find.bySemanticsLabel('Chats'));
      expect(menu.center.dy, closeTo(more.center.dy, 0.5));
      await golden(tester, 'header_pill');
      await render(
        tester,
        'phone-header-pill',
        'Phone 412×915: menu circle left; New chat + More in one glass pill.',
      );

      // More opens the chat's options.
      await tester.tap(find.bySemanticsLabel('Chat options'));
      await advance(tester, 400);
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Tasks'), findsOneWidget);
    });

    testWidgets('an empty chat shows only More, with live voice and '
        'Settings', (tester) async {
      await boot(tester);
      expect(find.byKey(const ValueKey('new-chat')), findsNothing);
      final more = tester.getRect(find.byKey(const ValueKey('more-button')));
      expect(more.width, 44, reason: 'one action: a circle');
      await tester.tap(find.bySemanticsLabel('More'));
      await advance(tester, 400);
      expect(find.text('Start live voice'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    });
  });

  group('gap above the composer', () {
    testWidgets('the last action row clears the composer by the reply gap, '
        'keyboard closed or open', (tester) async {
      await boot(
        tester,
        setup: (b) => seed(
          b,
          reply: List.generate(40, (i) => 'Paragraph ${i + 1}.').join('\n\n'),
        ),
      );
      await openChat(tester, 'Disk check');
      double gap() =>
          composerRect(tester).top -
          tester.getRect(find.byTooltip('Copy').last).bottom;
      // The action row's 48 dp targets carry a few dp of their own.
      expect(gap(), greaterThanOrEqualTo(60));
      expect(gap(), lessThanOrEqualTo(80));
      await render(
        tester,
        'phone-reply-gap',
        'Phone: the newest reply scrolled to its end; ~72 dp between its '
            'action row and the composer.',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      addTearDown(tester.view.resetViewInsets);
      await advance(tester, 400);
      // At the end again (the inset grew), the same gap above the raised
      // composer.
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -3000),
      );
      await advance(tester, 600);
      expect(gap(), greaterThanOrEqualTo(60));
      expect(gap(), lessThanOrEqualTo(80));
    });
  });

  group('swipe up to live', () {
    test('the acceptance and release rules', () {
      expect(LiveSwipeRecognizer.accepts(const Offset(0, -20)), isTrue);
      expect(LiveSwipeRecognizer.accepts(const Offset(0, -10)), isFalse);
      expect(LiveSwipeRecognizer.accepts(const Offset(0, 40)), isFalse);
      expect(LiveSwipeRecognizer.accepts(const Offset(30, -20)), isFalse);
      // Only the pull's length counts at release, never its speed.
      expect(liveSwipeShouldOpen(travel: 160, threshold: 160), isTrue);
      expect(liveSwipeShouldOpen(travel: 159, threshold: 160), isFalse);
      expect(liveSwipeShouldOpen(travel: 60, threshold: 120), isFalse);
      // About 18 % of the screen, 120–160 dp.
      expect(LiveSwipeRecognizer.thresholdFor(915), 160);
      expect(LiveSwipeRecognizer.thresholdFor(780), closeTo(140.4, 0.01));
      expect(LiveSwipeRecognizer.thresholdFor(500), 120);
      expect(liveSwipeOffset(0), 0);
      expect(liveSwipeOffset(1000), lessThanOrEqualTo(28));
      expect(liveSwipeOffset(40), lessThan(40));
    });

    Finder liveOpen() => find.bySemanticsLabel('End live voice');

    testWidgets('an upward drag on the composer opens live voice, with a '
        'haptic as it passes the threshold', (tester) async {
      await boot(tester);
      final start = composerRect(tester).center;
      final g = await tester.startGesture(start);
      for (var i = 0; i < 8; i++) {
        await g.moveBy(const Offset(0, -10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      // The rubber band lifts the composer and the hint grows.
      expect(composerRect(tester).center.dy, lessThan(start.dy - 10));
      expect(find.text('Pull to talk'), findsOneWidget);
      expect(feedback.haptics, isNot(contains(Haptic.selection)));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(0, -10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.text('Release to start live'), findsOneWidget);
      expect(feedback.haptics, contains(Haptic.selection));
      await g.up();
      await tester.pump();
      await tester.runAsync(() => settle(20));
      await advance(tester, 600);
      expect(liveOpen(), findsWidgets);
      await tester.runAsync(() => call.end());
      await advance(tester, 800);
    });

    testWidgets('a short slow drag springs back; the thread keeps its '
        'scrolling; the keyboard and the gesture inset keep it off', (
      tester,
    ) async {
      await boot(
        tester,
        setup: (b) => seed(
          b,
          reply: List.generate(40, (i) => 'Paragraph ${i + 1}.').join('\n\n'),
        ),
      );
      await openChat(tester, 'Disk check');
      final rest = composerRect(tester);
      await tester.timedDragFrom(
        rest.center,
        const Offset(0, -40),
        const Duration(milliseconds: 600),
      );
      await advance(tester, 600);
      expect(liveOpen(), findsNothing);
      expect(composerRect(tester), rest, reason: 'sprung back');

      // In the middle of the thread an upward drag scrolls (here: nothing
      // more to show, so it stays a scroll gesture and live stays shut).
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, 400),
      );
      await advance(tester, 400);
      await tester.dragFrom(const Offset(200, 500), const Offset(0, -200));
      await advance(tester, 600);
      expect(liveOpen(), findsNothing);
      // Just above the composer, with the thread scrolled up: a scroll too.
      await tester.dragFrom(Offset(200, rest.top - 30), const Offset(0, -150));
      await advance(tester, 600);
      expect(liveOpen(), findsNothing);

      // Android's home gesture area.
      tester.view.systemGestureInsets = const FakeViewPadding(bottom: 40);
      addTearDown(tester.view.resetSystemGestureInsets);
      await tester.pump();
      await tester.dragFrom(const Offset(200, 905), const Offset(0, -200));
      await advance(tester, 600);
      expect(liveOpen(), findsNothing);

      // The keyboard is up: the field keeps its drags.
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      addTearDown(tester.view.resetViewInsets);
      await advance(tester, 300);
      await tester.dragFrom(composerRect(tester).center, const Offset(0, -200));
      await advance(tester, 600);
      expect(liveOpen(), findsNothing);
    });

    testWidgets('sideways drags on the composer area still open the panels', (
      tester,
    ) async {
      await boot(tester, setup: seed);
      await openChat(tester, 'Disk check');
      await tester.dragFrom(
        Offset(120, composerRect(tester).top - 20),
        const Offset(220, -10),
      );
      await advance(tester, 600);
      expect(find.byKey(const ValueKey('drawer-avatar')), findsOneWidget);
      expect(liveOpen(), findsNothing);
    });
  });

  group('starter prompts', () {
    test(
      'each set is new: no prompt from the last set comes straight back',
      () {
        final p = StarterPrompts(random: Random(1), count: 4);
        var last = p.next(now: DateTime(2026, 11, 16, 9));
        for (var i = 0; i < 50; i++) {
          final next = p.next(now: DateTime(2026, 11, 16, 9));
          expect(next, hasLength(4));
          expect(next.toSet(), hasLength(4));
          expect(next.toSet().intersection(last.toSet()), isEmpty);
          last = next;
        }
      },
    );

    test('prompts for this part of the day come up more often', () {
      final p = StarterPrompts(random: Random(2), count: 4);
      var morning = 0, night = 0;
      for (var i = 0; i < 400; i++) {
        for (final s in p.next(now: DateTime(2026, 11, 16, 8))) {
          if (s.parts.contains(DayPart.morning)) morning++;
          if (s.parts.length == 1 && s.parts.contains(DayPart.night)) night++;
        }
      }
      expect(morning, greaterThan(night * 5));
    });

    test('the bridge shape: strings or {text}, junk skipped', () {
      expect(
        StarterPrompts.parse({
          'suggestions': [
            'Check the UPS',
            {'text': 'What is Seerr doing?'},
            42,
            '',
          ],
        }).map((p) => p.text),
        ['Check the UPS', 'What is Seerr doing?'],
      );
      expect(StarterPrompts.parse('nope'), isEmpty);
      // The bridge's shape (API.md "Suggestions"): title shown, prompt sent.
      final bridge = StarterPrompts.parse({
        'suggestions': [
          {
            'id': 'hl-3',
            'title': 'Check the backups',
            'prompt': 'Did last night’s backups on NAS-01 finish cleanly?',
            'category': 'homelab',
          },
        ],
        'personalized': false,
      }).single;
      expect(bridge.text, 'Check the backups');
      expect(
        bridge.prompt,
        'Did last night’s backups on NAS-01 finish cleanly?',
      );
      expect(bridge.icon, Icons.dns_outlined);
      final p = StarterPrompts(random: Random(3))
        ..remote = StarterPrompts.parse(['A', 'B', 'C', 'D', 'E']);
      final first = p.next();
      expect(first.where((s) => s.text.length == 1).length, greaterThan(1));
    });

    test('the fetch stops after a 404 and never throws', () async {
      var calls = 0;
      final missing = RemoteSuggestions(
        baseUrl: Uri.parse('https://bridge.test:9476/'),
        accessKey: 'k',
        client: MockClient((r) async {
          calls++;
          expect(r.url.path, '/api/suggestions');
          expect(r.url.queryParameters['n'], '8');
          expect(r.headers['Authorization'], 'Bearer k');
          return http.Response('404: Not Found', 404);
        }),
      );
      expect(await missing.fetch(), isEmpty);
      expect(await missing.fetch(), isEmpty);
      expect(calls, 1);
      final ok = RemoteSuggestions(
        baseUrl: Uri.parse('https://bridge.test:9476'),
        accessKey: 'k',
        client: MockClient(
          (r) async => http.Response(
            jsonEncode({
              'suggestions': ['Check the UPS'],
            }),
            200,
          ),
        ),
      );
      expect((await ok.fetch()).single.text, 'Check the UPS');
      final broken = RemoteSuggestions(
        baseUrl: Uri.parse('https://bridge.test:9476'),
        accessKey: 'k',
        client: MockClient((r) async => throw const SocketException('down')),
      );
      expect(await broken.fetch(), isEmpty);
    });

    List<String> chips(WidgetTester tester) => [
      for (final p
          in tester
              .widget<StarterMarquee>(
                find.byKey(const ValueKey('starter-chips')),
              )
              .prompts)
        p.text,
    ];

    testWidgets('every new chat shows a fresh set', (tester) async {
      await boot(tester, setup: seed);
      final first = chips(tester);
      expect(first, hasLength(12));
      await openChat(tester, 'Disk check');
      await tester.tap(find.bySemanticsLabel('New chat'));
      await tester.runAsync(() => settle(20));
      await advance(tester, 800);
      final second = chips(tester);
      expect(second, hasLength(12));
      expect(second.toSet().intersection(first.toSet()), isEmpty);
      // The menu's New chat on an already empty chat refreshes too.
      await tester.tap(find.bySemanticsLabel('Chats'));
      await advance(tester, 600);
      await tester.tap(find.bySemanticsLabel('New chat').last);
      await advance(tester, 800);
      final third = chips(tester);
      expect(third.toSet().intersection(second.toSet()), isEmpty);
    });
  });

  group('chat list pull to refresh (phones)', () {
    testWidgets('pulling the list down reloads chats from the bridge', (
      tester,
    ) async {
      await boot(tester, setup: seed);
      await tester.tap(find.bySemanticsLabel('Chats'));
      await advance(tester, 600);
      expect(find.text('Fresh from the server'), findsNothing);
      int gets() => bridge.requests
          .where((r) => r.method == 'GET' && r.path == '/api/conversations')
          .length;
      final before = gets();
      bridge.conversations.insert(0, _conv('c9', 'Fresh from the server'));
      await tester.fling(
        find.byKey(const ValueKey('drawer-list')),
        const Offset(0, 300),
        1200,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);
      await tester.runAsync(() => settle(30));
      await advance(tester, 1200);
      expect(gets(), greaterThan(before));
      expect(find.text('Fresh from the server'), findsOneWidget);
      expect(feedback.haptics, contains(Haptic.light));
    });
  });

  group('desktop', () {
    testWidgets('the open sidebar: name, search and collapse, New chat and '
        'Tasks rows, Pinned, Chats and the account row; the empty chat '
        'centres its greeting and composer', (tester) async {
      await boot(tester, size: const Size(1280, 800), setup: seed);
      expect(tester.getSize(find.byKey(const ValueKey('sidebar'))).width, 260);
      for (final k in [
        'drawer-search',
        'sidebar-collapse',
        'sidebar-new-chat',
        'sidebar-tasks',
        'drawer-avatar',
      ]) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('Chats'), findsOneWidget);
      expect(find.text('Backup plan'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('sidebar-new-chat'))).height,
        38,
      );
      // Greeting above the centred composer, suggestion rows under it.
      final composer = composerRect(tester);
      final greeting = tester.getRect(
        find.byKey(const ValueKey('empty-greeting')),
      );
      final rows = tester.getRect(find.byKey(const ValueKey('starter-rows')));
      expect(composer.center.dy, closeTo(800 * 0.46, 30));
      expect(greeting.bottom, lessThan(composer.top));
      expect(rows.top, greaterThan(composer.bottom - 14));
      expect(greeting.center.dx, closeTo(composer.center.dx, 1));
      await golden(tester, 'desktop_open');
      await render(
        tester,
        'desktop-sidebar-open',
        'Desktop 1280×800: open sidebar and the centred empty chat.',
      );

      // A chat: the title with a chevron opens its options; the composer
      // moves to the bottom.
      await tester.tap(find.text('Disk check'));
      await tester.runAsync(() => settle(20));
      await advance(tester, 800);
      expect(find.byKey(const ValueKey('title-button')), findsOneWidget);
      expect(composerRect(tester).bottom, greaterThan(800 - 20));
      await tester.tap(find.byKey(const ValueKey('title-button')));
      await advance(tester, 400);
      expect(find.text('Rename'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await advance(tester, 400);
    });

    testWidgets('the folded rail: brand mark, New chat, Search, Pinned, '
        'Chats, Tasks and the avatar; Pinned lists pinned chats', (
      tester,
    ) async {
      final prefs = MemoryPrefsStore()..values['sidebarCollapsed'] = 'true';
      await boot(
        tester,
        size: const Size(1280, 800),
        setup: seed,
        prefs: prefs,
      );
      // Chats lists the recent chats beside the rail.
      await tester.tap(find.byKey(const ValueKey('rail-chats')));
      await advance(tester, 400);
      await tester.tap(find.text('Disk check'));
      await tester.runAsync(() => settle(20));
      await advance(tester, 800);
      expect(tester.getSize(find.byKey(const ValueKey('sidebar'))).width, 52);
      final keys = [
        'sidebar-expand',
        'rail-new-chat',
        'rail-search',
        'rail-pinned',
        'rail-chats',
        'rail-tasks',
        'rail-avatar',
      ];
      double? lastY;
      for (final k in keys) {
        final r = tester.getRect(find.byKey(ValueKey(k)));
        expect(r.center.dx, closeTo(26, 1), reason: k);
        if (lastY != null) expect(r.center.dy, greaterThan(lastY), reason: k);
        lastY = r.center.dy;
      }
      await golden(tester, 'desktop_rail');
      await render(
        tester,
        'desktop-rail',
        'Desktop 1280×800: folded icon rail, chat title with a chevron.',
      );
      await tester.tap(find.byKey(const ValueKey('rail-pinned')));
      await advance(tester, 400);
      expect(find.text('Backup plan'), findsOneWidget);
      await tester.tap(find.text('Backup plan'));
      await tester.runAsync(() => settle(20));
      await advance(tester, 800);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('title-button')),
          matching: find.text('Backup plan'),
        ),
        findsOneWidget,
      );
      // Hover turns the brand mark into the sidebar icon.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('sidebar-expand'))),
      );
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('sidebar-expand')),
          matching: find.byIcon(Icons.view_sidebar_outlined),
        ),
        findsOneWidget,
      );
    });
  });
}
