import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/app.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/platform/device.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/ui/drawer/snippet.dart';
import 'package:tove_chat/src/ui/feedback.dart';
import 'package:tove_chat/src/ui/settings_screen.dart';
import 'package:tove_chat/src/ui/theme/render_policy.dart';
import 'package:material_ui/material_ui.dart';

import '../fakes.dart';
import 'test_harness.dart';

class _NoFeedback implements FeedbackSink {
  @override
  void haptic(Haptic h) {}
  @override
  void cue(Cue c) {}
}

Map<String, dynamic> _conv(String id, String title, {bool pinned = false}) => {
  'id': id,
  'title': title,
  'title_source': 'user',
  'pinned': pinned,
  'kind': 'text',
  'created': 1794691021626,
  'updated': 1794691021626,
  'preview': '',
  'message_count': 2,
};

Map<String, dynamic> _stored(String id, String role, String text) => {
  'id': id,
  'conversation_id': 'c1',
  'role': role,
  'text': text,
  'source': 'text',
  'status': 'complete',
  'created': 1794691021626,
  'client_id': null,
  'meta': <String, dynamic>{},
};

/// Fixes from the on-device QA pass of 15 November 2026.
void main() {
  late FakeBridge bridge;
  late CallController call;
  late SettingsController settings;
  late List<bool> handlesBack;

  Future<void> boot(
    WidgetTester tester, {
    bool chat = true,
    void Function(FakeBridge)? setup,
    MemoryPrefsStore? prefs,
  }) async {
    phoneSize(tester);
    handlesBack = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (c) async {
        if (c.method == 'SystemNavigator.setFrameworkHandlesBack') {
          handlesBack.add(c.arguments as bool);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    bridge = FakeBridge()..chatEnabled = chat;
    setup?.call(bridge);
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
    // The framework reports back handling only once the app is resumed.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.runAsync(() => settle(20));
    await tester.pump();
  }

  Future<void> advance(WidgetTester tester, [int ms = 800]) async {
    for (var i = 0; i < ms ~/ 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.bySemanticsLabel('Chats'));
    await advance(tester, 600);
  }

  group('system Back (defect 1)', () {
    testWidgets('closes the drawer instead of leaving the app', (tester) async {
      await boot(tester);
      await openDrawer(tester);
      expect(find.byKey(const ValueKey('drawer-new-chat')), findsOneWidget);
      // While the drawer is open the framework takes Back (predictive back
      // registers Flutter's callback only then).
      expect(handlesBack.last, isTrue);

      final handled = await tester.binding.handlePopRoute();
      await advance(tester, 600);
      expect(handled, isTrue, reason: 'Back stays in the app');
      expect(find.byKey(const ValueKey('drawer-new-chat')), findsNothing);
      // Closed: Android Back at the root stays with the shell, which
      // minimises the app (round 6) rather than letting the system finish it.
      expect(handlesBack.last, isTrue);
    });

    testWidgets('leaves live mode after the drawer, then the app', (
      tester,
    ) async {
      await boot(tester);
      bridge
        ..sessionStatus = 429
        ..sessionError = {'error': 'usage_limit', 'code': 'usage_limit'};
      await tester.tap(find.bySemanticsLabel('Start live voice'));
      await tester.pump();
      await tester.runAsync(() => settle(30));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Try again'), findsOneWidget);

      await openDrawer(tester);
      await tester.binding.handlePopRoute();
      await advance(tester, 600);
      expect(find.text('Search chats'), findsNothing, reason: 'drawer first');
      expect(find.text('Try again'), findsOneWidget, reason: 'still live');

      await tester.binding.handlePopRoute();
      await tester.runAsync(() => settle(10));
      await advance(tester, 800);
      expect(find.text('Try again'), findsNothing, reason: 'live mode left');
      expect(find.text('What can I do for you?'), findsOneWidget);
      // At the root the shell keeps Back and minimises the app (round 6).
      expect(handlesBack.last, isTrue);
    });

    testWidgets('pops a pushed screen (Settings) before anything else', (
      tester,
    ) async {
      await boot(tester);
      await openDrawer(tester);
      await tester.tap(find.byKey(const ValueKey('drawer-avatar')));
      await advance(tester, 400);
      await tester.tap(find.text('Settings').first);
      await advance(tester, 800);
      expect(find.text('Search settings'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await advance(tester, 800);
      expect(find.text('Search settings'), findsNothing);
    });
  });

  testWidgets('a failed call hides mute and the pill, keeps End (defect 3)', (
    tester,
  ) async {
    final h = tester.ensureSemantics();
    await boot(tester);
    bridge
      ..sessionStatus = 429
      ..sessionError = {'error': 'usage_limit', 'code': 'usage_limit'};
    await tester.tap(find.bySemanticsLabel('Start live voice'));
    await tester.pump();
    await tester.runAsync(() => settle(30));
    await advance(tester, 600);
    expect(call.phase, CallPhase.failed);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.bySemanticsLabel('Mute microphone'), findsNothing);
    expect(find.bySemanticsLabel('Ask Hermes'), findsNothing);
    expect(find.bySemanticsLabel(RegExp('^Reply effort')), findsNothing);
    expect(find.bySemanticsLabel('End live voice'), findsOneWidget);
    // The faded controls ignore taps.
    final ignoring = tester
        .widgetList<IgnorePointer>(
          find.ancestor(
            of: find.byIcon(Icons.mic_none_rounded),
            matching: find.byType(IgnorePointer),
          ),
        )
        .any((w) => w.ignoring);
    expect(ignoring, isTrue);
    await tester.tap(find.bySemanticsLabel('End live voice'));
    await tester.runAsync(() => settle(10));
    await advance(tester);
    h.dispose();
  });

  group('drawer search snippet (defect 4)', () {
    const reply =
        'Hi Nova, ready to help.\n\n'
        '| Name | Role | LAN IP | OS |\n'
        '|---|---|---|---|\n'
        '| **Workbench** | Compute | 192.168.1.12 | Ubuntu |\n'
        '| NAS-01 | Storage: Navidrome, *arr apps | 192.168.1.11 | Ubuntu |\n'
        '| Pathfinder | Core: Coolify, `Vaultwarden` | 192.168.1.10 | '
        'Ubuntu |\n\n'
        '```bash\nssh core\n```';

    test('strips markdown', () {
      final s = stripMarkdown(reply);
      expect(s, isNot(contains('|')));
      expect(s, isNot(contains('---')));
      expect(s, isNot(contains('**')));
      expect(s, isNot(contains('`')));
      expect(s, contains('Name · Role · LAN IP · OS'));
      expect(s, contains('Workbench · Compute'));
      expect(
        stripMarkdown('# Title\n- **bold** and _em_ [link](https://x.y)'),
        'Title bold and em link',
      );
    });

    test('centres the first match, case-insensitively, with ellipses', () {
      final s = searchSnippet(reply, 'pathfinder');
      expect(s, startsWith('…'));
      final i = s.toLowerCase().indexOf('pathfinder');
      expect(i, inInclusiveRange(1, 32), reason: s);
      expect(s, isNot(contains('|')));
      // Short text that already shows the match is left whole.
      expect(searchSnippet('Disk is **full**', 'disk'), 'Disk is full');
      // No match: the start of the plain text.
      expect(searchSnippet(reply, 'zzz'), startsWith('Hi Nova'));
    });

    testWidgets('the drawer row shows the plain, centred snippet', (
      tester,
    ) async {
      await boot(
        tester,
        setup: (b) => b.conversations.add(_conv('c1', 'Hi Nova')),
      );
      bridge.searchHits = [
        {
          'conversation': _conv('c1', 'Hi Nova'),
          'message_id': 'm9',
          'snippet': reply,
        },
      ];
      await openDrawer(tester);
      await tester.tap(find.byTooltip('Search chats'));
      await advance(tester, 300);
      await tester.enterText(
        find.byKey(const ValueKey('drawer-search-field')),
        'Pathfinder',
      );
      await advance(tester, 300);
      await tester.runAsync(() => settle(20));
      await advance(tester, 300);
      final rich = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((r) => r.text.toPlainText())
          .firstWhere((t) => t.contains('Pathfinder'));
      expect(rich, isNot(contains('|')));
      expect(rich.indexOf('Pathfinder'), lessThan(33));
    });
  });

  group('drawer empty state (defect 6)', () {
    testWidgets('a pinned chat hides "No chats yet" and the empty Chats', (
      tester,
    ) async {
      await boot(
        tester,
        setup: (b) =>
            b.conversations.add(_conv('p1', 'Pinned one', pinned: true)),
      );
      await openDrawer(tester);
      expect(find.text('Pinned'), findsOneWidget);
      expect(find.text('Pinned one'), findsOneWidget);
      expect(find.text('No chats yet'), findsNothing);
      expect(find.text('Chats'), findsNothing);
    });

    testWidgets('no chats at all shows the empty state', (tester) async {
      await boot(tester);
      await openDrawer(tester);
      expect(find.text('Chats'), findsOneWidget);
      expect(find.text('No chats yet'), findsOneWidget);
    });

    testWidgets('pinned and recent show both sections', (tester) async {
      await boot(
        tester,
        setup: (b) => b.conversations
          ..add(_conv('p1', 'Pinned one', pinned: true))
          ..add(_conv('r1', 'Recent one')),
      );
      await openDrawer(tester);
      expect(find.text('Pinned'), findsOneWidget);
      // One list without date groups (round 6): Pinned, then Chats.
      expect(find.text('Chats'), findsOneWidget);
      expect(find.text('Today'), findsNothing);
      expect(find.text('Recent one'), findsOneWidget);
      expect(find.text('No chats yet'), findsNothing);
    });
  });

  testWidgets('keyboard open: suggestions never sit under the composer '
      '(defect 7)', (tester) async {
    await boot(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 420);
    await tester.pump();
    await tester.enterText(
      find.byType(TextField),
      'Hi Hermes, reply in one short sentence, and make it a fairly long '
      'draft so the field wraps onto a second line.',
    );
    await advance(tester, 400);
    expect(tester.takeException(), isNull);
    final composerTop = tester.getRect(find.bySemanticsLabel('Ask Hermes')).top;
    final viewport = tester.getRect(find.byType(CustomScrollView).first);
    expect(
      viewport.bottom,
      lessThanOrEqualTo(composerTop),
      reason: 'the empty state is clipped above the composer',
    );
    // The Surprise me button under the rows can be scrolled into view,
    // above the composer.
    final surprise = find.byKey(const ValueKey('starter-surprise'));
    await tester.dragUntilVisible(
      surprise,
      find.byType(CustomScrollView).first,
      const Offset(0, -80),
    );
    await tester.pump();
    expect(tester.getRect(surprise).bottom, lessThanOrEqualTo(composerTop));
  });

  group('settings (defect 8)', () {
    test('fresh installs default to Dark; a stored choice is kept', () async {
      final fresh = SettingsController(
        keys: MemoryKeyStore(),
        prefs: MemoryPrefsStore(),
      );
      await fresh.load();
      expect(fresh.theme, AppTheme.dark);

      final prefs = MemoryPrefsStore()..values['theme'] = 'system';
      final chosen = SettingsController(keys: MemoryKeyStore(), prefs: prefs);
      await chosen.load();
      expect(chosen.theme, AppTheme.system);
    });

    Future<void> openSettings(
      WidgetTester tester, {
      bool? showShortcuts,
    }) async {
      phoneSize(tester);
      final s = SettingsController(
        keys: MemoryKeyStore(testKey),
        prefs: MemoryPrefsStore(),
      );
      await s.load();
      final c = CallController(
        apiFactory: FakeBridge().api,
        transportFactory: FakeTransport.new,
        platform: FakePlatform(supported: false),
        voice: () => s.voice,
        timings: fastTimings,
        desktop: true,
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        themed(
          SettingsScreen(settings: s, call: c, showShortcuts: showShortcuts),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
    }

    testWidgets('phones hide the desktop shortcuts; About and Licences are '
        'separate nodes', (tester) async {
      final h = tester.ensureSemantics();
      await openSettings(tester);
      expect(find.textContaining('Ctrl+K'), findsNothing);
      // An exact label match: the row is not merged with the About text.
      expect(find.bySemanticsLabel('Licences'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp(r'^Text replies come from Hermes')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp(r'Licences$')),
        findsOneWidget,
        reason: 'Licences is not appended to the About text',
      );
      h.dispose();
    });

    testWidgets('desktop (or a hardware keyboard) lists the shortcuts', (
      tester,
    ) async {
      await openSettings(tester, showShortcuts: true);
      expect(find.textContaining('Ctrl+K'), findsOneWidget);
    });
  });

  testWidgets('an opened chat has no title in the header; a sent prompt '
      'sits under it with the reply below, keyboard open or closed', (
    tester,
  ) async {
    await boot(
      tester,
      setup: (b) {
        b.conversations.add(
          _conv('c1', 'A very long conversation title that never fits'),
        );
        // Long enough to open scrolled, where the old title showed.
        b.stored['c1'] = [
          for (var i = 0; i < 10; i++) ...[
            _stored('u$i', 'user', 'Question $i'),
            _stored('a$i', 'assistant', 'Answer $i.\n\nSecond paragraph.'),
          ],
        ];
      },
    );
    await openDrawer(tester);
    await tester.tap(
      find.text('A very long conversation title that never fits'),
    );
    await tester.runAsync(() => settle(20));
    await advance(tester, 600);
    final options = tester.getRect(find.bySemanticsLabel('Chat options'));
    final header = Rect.fromLTRB(0, 0, 412, options.bottom + 8);
    // Text drawn in the header bar itself; thread text scrolls under it.
    Iterable<String> headerTexts() => find
        .byType(Text)
        .hitTestable()
        .evaluate()
        .where(
          (e) =>
              e.findAncestorWidgetOfExactType<Scrollable>() == null &&
              header.overlaps(
                tester.getRect(find.byElementPredicate((x) => x == e)),
              ),
        )
        .map((e) => (e.widget as Text).data ?? '');
    expect(headerTexts(), isEmpty, reason: 'no title text in the header');
    // The stored title stays in the chat list.
    await openDrawer(tester);
    expect(
      find.text('A very long conversation title that never fits'),
      findsOneWidget,
    );
    await tester.binding.handlePopRoute();
    await advance(tester, 600);

    tester.view.viewInsets = const FakeViewPadding(bottom: 420);
    await tester.pump();
    bridge.reply = List.generate(4, (i) => '${i + 1}. A fact.').join('\n');
    await tester.enterText(find.byType(TextField), 'List facts');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Send message'));
    await tester.pump();
    await tester.runAsync(() => settle(40));
    await advance(tester, 1200);
    Rect prompt() => tester.getRect(find.text('List facts').last);
    // Under the header buttons, not at the bottom above the composer.
    expect(prompt().top, greaterThan(options.bottom));
    expect(prompt().top, lessThan(options.bottom + 60));
    final reply = tester.getRect(find.textContaining('A fact').first);
    expect(reply.top, greaterThan(prompt().bottom));
    expect(headerTexts(), isEmpty, reason: 'still no title after the reply');
    final before = prompt().top;
    tester.view.resetViewInsets();
    await advance(tester, 600);
    expect(prompt().top, closeTo(before, 1), reason: 'keyboard hidden');
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat options and the title follow pin and rename', (
    tester,
  ) async {
    await boot(
      tester,
      setup: (b) {
        b.conversations.add(_conv('c1', 'Disk check'));
        b.stored['c1'] = [];
      },
    );
    await openDrawer(tester);
    await tester.tap(find.text('Disk check'));
    await tester.runAsync(() => settle(20));
    await advance(tester, 600);
    Future<void> choose(String item) async {
      await tester.tap(find.bySemanticsLabel('Chat options'));
      await advance(tester, 400);
      await tester.tap(find.text(item));
      await tester.runAsync(() => settle(20));
      await advance(tester, 400);
    }

    await choose('Pin');
    await tester.tap(find.bySemanticsLabel('Chat options'));
    await advance(tester, 400);
    expect(find.text('Unpin'), findsOneWidget);
    expect(find.text('Pin'), findsNothing);
  });

  group('refresh-rate requests (defect 2)', () {
    late List<Object?> calls;
    late DeviceServices device;

    setUp(() {
      calls = [];
      const channel = MethodChannel(DeviceServices.channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (c) async {
            if (c.method == 'info') {
              return {
                'sdk': 35,
                'refreshRates': [120.0, 90.0, 60.0],
              };
            }
            calls.add(c.arguments);
            final hz = (c.arguments as Map?)?['hz'] as double?;
            return {
              'supportedHz': [120.0, 90.0, 60.0],
              'currentHz': 60.0,
              'requestedHz': hz == null || hz == 0 ? null : hz,
              'peakSettingHz': 60.0,
              'powerSave': false,
            };
          });
      device = DeviceServices(channel: channel, android: true);
    });

    test('live and scrolling share one request', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await device.requestHighRefresh('live', true);
      await device.requestHighRefresh('scroll', true);
      await device.requestHighRefresh('scroll', false);
      expect(calls, [
        {'hz': 120.0},
      ], reason: 'still live: no release');
      await device.requestHighRefresh('live', false);
      // Auto with no recent touch: back to the system's choice.
      expect(calls.last, {'hz': 0.0});
      expect(device.lastRefreshStatus?.requestedHz, isNull);
    });

    test('reports a system cap', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await device.requestHighRefresh('live', true);
      final s = device.lastRefreshStatus!;
      expect(s.requestedHz, 120);
      expect(s.systemCap, 'system peak refresh setting 60 Hz');
      expect(
        RefreshStatus.fromMap(const {
          'supportedHz': [120.0, 60.0],
          'peakSettingHz': 120.0,
          'powerSave': true,
        }).systemCap,
        'battery saver',
      );
      expect(
        RefreshStatus.fromMap(const {
          'supportedHz': [120.0, 60.0],
          'peakSettingHz': 120.0,
        }).systemCap,
        isNull,
      );
    });
  });

  group('refresh policy (round 6, A6)', () {
    const both = [120.0, 90.0, 60.0];
    double pick(
      RefreshMode m, {
      List<double> rates = both,
      bool boosting = false,
      bool active = false,
    }) => RefreshPolicy.pick(
      mode: m,
      supported: rates,
      boosting: boosting,
      active: active,
    );

    test('Auto: the maximum while boosting, 90 while active, the system '
        'when idle', () {
      expect(pick(RefreshMode.auto, boosting: true, active: true), 120);
      expect(pick(RefreshMode.auto, active: true), 90);
      expect(pick(RefreshMode.auto), 0);
      // A 60/120 panel has no 90: active use gets its maximum.
      expect(pick(RefreshMode.auto, rates: [120, 60], active: true), 120);
      // A 60 Hz panel never asks for anything else.
      expect(pick(RefreshMode.auto, rates: [60], boosting: true), 60);
      expect(pick(RefreshMode.auto, rates: const [], active: true), 0);
    });

    test('fixed choices pin the closest mode at all times', () {
      for (final b in [false, true]) {
        expect(pick(RefreshMode.hz60, boosting: b), 60);
        expect(pick(RefreshMode.hz90, boosting: b), 90);
        expect(pick(RefreshMode.max, boosting: b), 120);
      }
      expect(pick(RefreshMode.hz90, rates: [144, 60]), 60);
      expect(pick(RefreshMode.hz90, rates: [96, 60]), 96);
    });

    test('the setting is applied at once and saved', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final calls = <Object?>[];
      const channel = MethodChannel(DeviceServices.channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (c) async {
            if (c.method == 'info') return {'refreshRates': both};
            calls.add(c.arguments);
            return <String, Object?>{};
          });
      final device = DeviceServices(channel: channel, android: true);
      device.refreshMode = RefreshMode.hz90;
      await pumpEventQueue();
      expect(calls.last, {'hz': 90.0});
      device.refreshMode = RefreshMode.max;
      await pumpEventQueue();
      expect(calls.last, {'hz': 120.0});

      final prefs = MemoryPrefsStore();
      final settings = SettingsController(
        keys: MemoryKeyStore(testKey),
        prefs: prefs,
      );
      await settings.load();
      expect(settings.refreshRate, RefreshMode.auto);
      await settings.setRefreshRate(RefreshMode.hz60);
      final again = SettingsController(
        keys: MemoryKeyStore(testKey),
        prefs: prefs,
      );
      await again.load();
      expect(again.refreshRate, RefreshMode.hz60);
    });
  });
}
