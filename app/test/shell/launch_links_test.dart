import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show EditableText;
import 'package:tove_chat/src/app.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/platform/app_links.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/ui/shell/chat_shell.dart';
import 'package:tove_chat/src/ui/theme/render_policy.dart';

import '../fakes.dart';
import '../ui/test_harness.dart';

Map<String, dynamic> _conv(String id, String title) => {
  'id': id,
  'title': title,
  'title_source': 'user',
  'pinned': false,
  'kind': 'text',
  'created': DateTime(2026, 11, 16, 9).millisecondsSinceEpoch,
  'updated': DateTime(2026, 11, 16, 9).millisecondsSinceEpoch,
  'preview': '',
  'message_count': 2,
};

Map<String, dynamic> _msg(String id, String role, String text) => {
  'id': id,
  'conversation_id': 'd1',
  'role': role,
  'text': text,
  'source': 'text',
  'status': 'complete',
  'created': DateTime(2026, 11, 16, 9).millisecondsSinceEpoch,
  'client_id': null,
  'meta': <String, dynamic>{},
};

/// Home-screen widgets and the assistant gesture open the app with
/// `tove://` links (LaunchPlugin.kt → AppLinks → ChatShell.handleLaunch).
void main() {
  group('LaunchAction.parse', () {
    test('the widget and assistant links', () {
      expect(LaunchAction.parse('tove://chat/new'), const NewChatAction());
      expect(
        LaunchAction.parse('tove://chat/new?keyboard=1'),
        const NewChatAction(keyboard: true),
      );
      expect(LaunchAction.parse('tove://live'), const OpenLive());
      expect(
        LaunchAction.parse('tove://chat/c42'),
        const OpenChatAction('c42'),
      );
      expect(
        LaunchAction.parse('tove://chat/a%20b'),
        const OpenChatAction('a b'),
      );
    });

    test('anything else is ignored', () {
      for (final l in [
        null,
        '',
        'https://chat/new',
        'tove://settings',
        'tove://live/now',
        'tove://chat',
        'tove://chat/a/b',
        'tove:chat/new',
      ]) {
        expect(LaunchAction.parse(l), isNull, reason: '$l');
      }
    });
  });

  group('AppLinks channel', () {
    const name = 'test/launch-unit';
    final calls = <MethodCall>[];
    late AppLinks links;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      calls.clear();
      links = AppLinks(channel: const MethodChannel(name), android: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(name), (c) async {
            calls.add(c);
            return switch (c.method) {
              'initialLink' => 'tove://live',
              'assistantStatus' => {'supported': true, 'held': false},
              'openAssistantSettings' => true,
              _ => null,
            };
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(name), null);
      links.dispose();
    });

    test('initial link, assistant status and settings', () async {
      expect(await links.initial(), const OpenLive());
      final s = await links.assistantStatus();
      expect(s?.supported, isTrue);
      expect(s?.held, isFalse);
      expect(await links.openAssistantSettings(), isTrue);
    });

    test('the recent chat is sent once per change', () async {
      await links.setRecentChat('c1', 'Disk check');
      await links.setRecentChat('c1', 'Disk check');
      await links.setRecentChat(null, null);
      final sent = calls.where((c) => c.method == 'setRecentChat').toList();
      expect(sent.map((c) => c.arguments), [
        {'id': 'c1', 'title': 'Disk check'},
        {'id': null, 'title': null},
      ]);
    });

    test('links from the running app arrive as actions', () async {
      final got = <LaunchAction>[];
      final sub = links.actions.listen(got.add);
      const codec = StandardMethodCodec();
      for (final l in ['tove://chat/c9', 'tove://nope']) {
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              name,
              codec.encodeMethodCall(MethodCall('link', l)),
              (_) {},
            );
      }
      await Future<void>.delayed(Duration.zero);
      expect(got, [const OpenChatAction('c9')]);
      await sub.cancel();
    });

    test('off Android every call is a no-op', () async {
      final web = AppLinks(channel: const MethodChannel(name), android: false);
      expect(await web.initial(), isNull);
      expect(await web.assistantStatus(), isNull);
      expect(await web.openAssistantSettings(), isFalse);
      await web.setRecentChat('c1', 'x');
      expect(calls, isEmpty);
    });
  });

  group('the shell follows links', () {
    const name = 'test/launch-shell';
    const codec = StandardMethodCodec();
    late FakeBridge bridge;
    late CallController call;
    late SettingsController settings;
    final sent = <MethodCall>[];
    String? initial;

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
      sent.clear();
      bridge = FakeBridge()..chatEnabled = true;
      bridge.conversations.add(_conv('d1', 'Disk check'));
      bridge.stored['d1'] = [
        _msg('m1', 'user', 'How full are the disks?'),
        _msg('m2', 'assistant', 'NAS-01 is at 40%.'),
      ];
      settings = SettingsController(
        keys: MemoryKeyStore(testKey),
        prefs: MemoryPrefsStore(),
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel(name),
        (c) async {
          sent.add(c);
          if (c.method == 'initialLink') {
            final l = initial;
            initial = null;
            return l;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel(name),
          null,
        ),
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
      final links = AppLinks(channel: const MethodChannel(name), android: true);
      addTearDown(links.dispose);
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
          services: AppServices(links: links),
        ),
      );
      await settings.load();
      await tester.pump();
      await tester.runAsync(() => settle(20));
      await advance(tester);
    }

    Future<void> deliver(WidgetTester tester, String link) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        name,
        codec.encodeMethodCall(MethodCall('link', link)),
        (_) {},
      );
      await tester.runAsync(() => settle(20));
      await advance(tester);
    }

    ChatShellState shell(WidgetTester tester) =>
        tester.state<ChatShellState>(find.byType(ChatShell));

    Finder liveOpen() => find.bySemanticsLabel('End live voice');

    bool composerFocused(WidgetTester tester) => tester
        .widget<EditableText>(find.byType(EditableText).first)
        .focusNode
        .hasFocus;

    testWidgets('a cold start from the assistant gesture opens live', (
      tester,
    ) async {
      initial = 'tove://live';
      await boot(tester);
      expect(liveOpen(), findsWidgets);
      expect(sent.map((c) => c.method), contains('initialLink'));
      await shell(tester).endLive();
      await advance(tester);
    });

    testWidgets('a chat link opens it and feeds the quick widget', (
      tester,
    ) async {
      await boot(tester);
      await deliver(tester, 'tove://chat/d1');
      expect(find.textContaining('NAS-01 is at 40%'), findsOneWidget);
      final recent = sent.where((c) => c.method == 'setRecentChat').last;
      expect(recent.arguments, {'id': 'd1', 'title': 'Disk check'});
    });

    testWidgets('Ask Tove opens a new chat with the keyboard up', (
      tester,
    ) async {
      await boot(tester);
      await deliver(tester, 'tove://chat/d1');
      expect(composerFocused(tester), isFalse);
      await deliver(tester, 'tove://chat/new?keyboard=1');
      expect(find.textContaining('NAS-01 is at 40%'), findsNothing);
      expect(composerFocused(tester), isTrue);
    });

    testWidgets('Live from a chat starts live voice in a fresh chat', (
      tester,
    ) async {
      await boot(tester);
      await deliver(tester, 'tove://chat/d1');
      await deliver(tester, 'tove://live');
      expect(liveOpen(), findsWidgets);
      expect(shell(tester).widget.chat.currentConversationId, isNot('d1'));
      await shell(tester).endLive();
      await advance(tester);
    });
  });
}
