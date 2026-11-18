import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/app.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/pairing/pairing.dart';
import 'package:tove_chat/src/platform/app_links.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/ui/pairing/scan_page.dart';
import 'package:tove_chat/src/ui/pairing/welcome_screen.dart';
import 'package:tove_chat/src/ui/theme/render_policy.dart';

import '../fakes.dart';
import '../ui/test_harness.dart';

const _link =
    'tove://pair?u=https%3A%2F%2Fbox.tail1234.ts.net%3A8787'
    '&c=ABCDE-FGHJK&n=Home%20server';
const _pairedKey = 'paired-key-from-the-bridge-0000000000';

/// First run: the welcome screen, scanning, typing a code, and pairing links
/// (server/API.md "Pairing").
void main() {
  const channel = 'test/welcome-links';
  const codec = StandardMethodCodec();
  late SettingsController settings;
  late MemoryKeyStore keys;
  late FakeBridge bridge;
  final pairCalls = <(Uri, String)>[];
  final verified = <(Uri, String)>[];
  final opened = <Uri>[];
  PairingException? pairError;
  String? scanned;
  String? initial;

  setUpAll(loadAppFonts);

  setUp(() {
    pairCalls.clear();
    verified.clear();
    opened.clear();
    pairError = null;
    scanned = null;
    initial = null;
  });

  Future<PairResult> fakePair(Uri server, String code) async {
    pairCalls.add((server, code));
    if (pairError != null) throw pairError!;
    return const PairResult(key: _pairedKey, name: 'Hermes');
  }

  Future<void> advance(WidgetTester tester, [int ms = 800]) async {
    for (var i = 0; i < ms ~/ 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> boot(
    WidgetTester tester, {
    String? key,
    bool canScan = true,
    bool links = false,
  }) async {
    phoneSize(tester);
    keys = MemoryKeyStore(key);
    settings = SettingsController(keys: keys, prefs: MemoryPrefsStore());
    bridge = FakeBridge()..chatEnabled = true;
    AppLinks? appLinks;
    if (links) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel(channel),
        (c) async => c.method == 'initialLink' ? initial : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel(channel),
          null,
        ),
      );
      appLinks = AppLinks(channel: const MethodChannel(channel), android: true);
      addTearDown(appLinks.dispose);
    }
    final call = CallController(
      apiFactory: bridge.api,
      transportFactory: FakeTransport.new,
      platform: FakePlatform(supported: false),
      voice: () => settings.voice,
      conversationId: () => null,
      timings: fastTimings,
      desktop: true,
    );
    addTearDown(call.dispose);
    await tester.pumpWidget(
      HermesApp(
        settings: settings,
        call: call,
        verify: (u, k) async => verified.add((u, k)),
        pair: fakePair,
        scan: (_) async => scanned,
        canScan: canScan,
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
        services: AppServices(links: appLinks),
      ),
    );
    await settings.load();
    await tester.pump();
    await tester.runAsync(() => settle(20));
    await advance(tester);
  }

  /// Signed in: the chat screen is showing.
  Future<void> expectChat(WidgetTester tester) async {
    await tester.runAsync(() => settle(20));
    await advance(tester);
    expect(find.text('How do I get Hermes?'), findsNothing);
    expect(find.bySemanticsLabel('Start live voice'), findsOneWidget);
  }

  testWidgets('first run explains Hermes and offers both ways in', (
    tester,
  ) async {
    await boot(tester);
    expect(find.text('Tove'), findsOneWidget);
    expect(find.textContaining('open-source AI assistant'), findsOneWidget);
    expect(find.text('Scan QR code'), findsOneWidget);
    expect(find.text('Enter code or address'), findsOneWidget);
    expect(find.textContaining('“set up Tove”'), findsOneWidget);
  });

  testWidgets('"How do I get Hermes?" opens the official docs', (tester) async {
    phoneSize(tester);
    await tester.pumpWidget(
      themed(
        WelcomeScreen(
          settings: SettingsController(
            keys: MemoryKeyStore(),
            prefs: MemoryPrefsStore(),
          ),
          openUrl: (u) async {
            opened.add(u);
            return true;
          },
          canScan: false,
        ),
      ),
    );
    await advance(tester, 300);
    // No camera here (web, desktop): typing is the only way.
    expect(find.text('Scan QR code'), findsNothing);
    await tester.tap(find.text('How do I get Hermes?'));
    await tester.pump();
    expect(opened.single.host, 'hermes-agent.nousresearch.com');
    expect(opened.single.path, startsWith('/docs/'));
  });

  testWidgets('scan → pair → check → chat', (tester) async {
    await boot(tester);
    scanned = _link;
    await tester.tap(find.text('Scan QR code'));
    await tester.pump();
    await tester.runAsync(() => settle(20));
    await advance(tester);
    expect(pairCalls.single.$1, Uri.parse('https://box.tail1234.ts.net:8787'));
    expect(pairCalls.single.$2, 'ABCDEFGHJK');
    expect(verified.single.$2, _pairedKey);
    expect(keys.value, _pairedKey);
    expect(settings.url, 'https://box.tail1234.ts.net:8787');
    await expectChat(tester);
  });

  testWidgets('an expired code explains what to do; nothing is saved', (
    tester,
  ) async {
    await boot(tester);
    pairError = const PairingException(PairingProblem.expired);
    scanned = _link;
    await tester.tap(find.text('Scan QR code'));
    await tester.pump();
    await tester.runAsync(() => settle(20));
    await advance(tester);
    expect(find.text('Couldn’t connect to Home server'), findsOneWidget);
    expect(find.textContaining('pair Tove again'), findsOneWidget);
    expect(find.text('Try again'), findsNothing); // a new code is needed
    expect(keys.value, isNull);
    await tester.tap(find.text('Back'));
    await advance(tester);
    expect(find.text('Scan QR code'), findsOneWidget);
  });

  testWidgets('unreachable can be retried', (tester) async {
    await boot(tester);
    pairError = const PairingException(PairingProblem.unreachable);
    scanned = _link;
    await tester.tap(find.text('Scan QR code'));
    await tester.pump();
    await tester.runAsync(() => settle(20));
    await advance(tester);
    expect(find.textContaining('turn Tailscale on'), findsOneWidget);
    pairError = null;
    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.runAsync(() => settle(20));
    await advance(tester);
    expect(pairCalls, hasLength(2));
    await expectChat(tester);
  });

  testWidgets('a QR code that is not a pairing code says so', (tester) async {
    await boot(tester);
    scanned = 'https://example.com/menu';
    await tester.tap(find.text('Scan QR code'));
    await tester.pump();
    await advance(tester, 300);
    expect(find.textContaining('isn’t a Tove pairing code'), findsOneWidget);
    expect(pairCalls, isEmpty);
  });

  testWidgets('"enter the code instead" from the camera opens typing', (
    tester,
  ) async {
    await boot(tester);
    scanned = ScanPage.enterByHand;
    await tester.tap(find.text('Scan QR code'));
    await tester.pump();
    await advance(tester);
    expect(find.widgetWithText(TextFormField, 'Pairing code'), findsOneWidget);
  });

  testWidgets('typing the address and code', (tester) async {
    await boot(tester);
    await tester.tap(find.text('Enter code or address'));
    await advance(tester);
    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(find.textContaining('Enter an address'), findsOneWidget);
    expect(find.textContaining('Enter the code'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Server address'),
      'box.tail1234.ts.net:8787',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Pairing code'),
      'abcde-fghjk',
    );
    pairError = const PairingException(PairingProblem.wrongCode);
    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.runAsync(() => settle(20));
    await advance(tester, 300);
    expect(
      find.text('That code isn’t right. Check it and try again.'),
      findsOne,
    );
    expect(keys.value, isNull);

    pairError = null;
    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.runAsync(() => settle(20));
    await advance(tester);
    expect(pairCalls.last.$1.toString(), 'https://box.tail1234.ts.net:8787');
    expect(pairCalls.last.$2, 'ABCDEFGHJK');
    expect(keys.value, _pairedKey);
    await expectChat(tester);
  });

  testWidgets('a pairing link that started the app pairs at once', (
    tester,
  ) async {
    initial = _link;
    await boot(tester, links: true);
    await tester.runAsync(() => settle(20));
    await advance(tester);
    expect(pairCalls.single.$2, 'ABCDEFGHJK');
    expect(keys.value, _pairedKey);
    await expectChat(tester);
  });

  testWidgets('signed in, a pairing link asks before switching', (
    tester,
  ) async {
    await boot(tester, key: testKey, links: true);
    await tester.runAsync(() => settle(20));
    await advance(tester);
    Future<void> deliver() async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        channel,
        codec.encodeMethodCall(const MethodCall('link', _link)),
        (_) {},
      );
      await tester.pump();
      await advance(tester, 500);
    }

    await deliver();
    expect(find.text('Connect to Home server?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await advance(tester, 500);
    expect(pairCalls, isEmpty);
    expect(keys.value, testKey);

    await deliver();
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pump();
    await tester.runAsync(() => settle(20));
    await advance(tester);
    expect(pairCalls, hasLength(1));
    expect(keys.value, _pairedKey);
    await expectChat(tester);
  });
}
