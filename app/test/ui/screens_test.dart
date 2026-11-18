import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/settings/profile_page.dart';
import 'package:tove_chat/src/app.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/ui/feedback.dart';
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

/// Goldens of the key screens and states (412 × 915, the reference size),
/// plus layout checks at a 2.0 text scale.
void main() {
  late FakeBridge bridge;
  late FakeTransport transport;
  late CallController call;
  late SettingsController settings;

  setUpAll(() async {
    await loadAppFonts();
    await loadEmojiFont();
    await _loadIcons();
  });

  Future<void> boot(
    WidgetTester tester, {
    bool chat = true,
    String? key = testKey,
    double textScale = 1,
    Brightness brightness = Brightness.dark,
  }) async {
    phoneSize(tester);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    bridge = FakeBridge()..chatEnabled = chat;
    final prefs = MemoryPrefsStore();
    if (brightness == Brightness.light) prefs.values['theme'] = 'light';
    settings = SettingsController(keys: MemoryKeyStore(key), prefs: prefs);
    final link = LiveLink();
    call = CallController(
      apiFactory: bridge.api,
      transportFactory: () => transport = FakeTransport()..speakerRoute = true,
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
    await advance(tester);
  }

  Future<void> live(WidgetTester tester, {bool started = true}) async {
    await tester.tap(find.bySemanticsLabel('Start live voice'));
    await tester.pump();
    await tester.runAsync(() => settle(20));
    await tester.pump(const Duration(milliseconds: 50));
    if (started) transport.emit({'type': 'session.started'});
    await advance(tester, started ? 900 : 300);
  }

  Future<void> golden(WidgetTester tester, String name) => expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/screen_$name.png'),
  );

  Future<void> end(WidgetTester tester) async {
    if (call.inCall) {
      await call.end();
      await advance(tester);
    }
  }

  testWidgets('empty thread', (tester) async {
    await boot(tester);
    await golden(tester, 'empty_dark');
  });

  testWidgets('empty thread, light', (tester) async {
    await boot(tester, brightness: Brightness.light);
    await golden(tester, 'empty_light');
  });

  testWidgets('thread with a reply', (tester) async {
    bridge = FakeBridge();
    await boot(tester);
    bridge.reply =
        '## Disk usage\n\nThe **storage box** (NAS-01) is at `40%`.\n\n'
        '- `/srv` 1.2 TB free\n- `/backups` 300 GB free\n\n'
        '| Volume | Used | Free |\n|---|---|---|\n| /srv | 60% | 1.2 TB |\n'
        '| /backups | 70% | 300 GB |\n\nSources: [docs](https://example.org/a)';
    await tester.enterText(find.byType(TextField), 'How full are the disks?');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Send message'));
    await tester.pump();
    await tester.runAsync(() => settle(60));
    await advance(tester, 3000);
    await golden(tester, 'thread_dark');
  });

  testWidgets('live, connecting', (tester) async {
    await boot(tester);
    await live(tester, started: false);
    await golden(tester, 'live_connecting');
    await end(tester);
  });

  testWidgets('live, centred and muted', (tester) async {
    await boot(tester);
    await live(tester);
    await tester.tap(find.bySemanticsLabel('Mute microphone'));
    await advance(tester, 600);
    await golden(tester, 'live_muted');
    await end(tester);
  });

  testWidgets('live, docked with a task result', (tester) async {
    await boot(tester);
    bridge.jobAnswer =
        'The **storage box** is healthy.\n\n- Disks: 4 of 4 online\n'
        '- Pool: `tank` at 40%\n- Last scrub: 2 days ago, no errors';
    await live(tester);
    transport.emit({
      'type': 'delegation.created',
      'item': {
        'id': 'd1',
        'content': [
          {'text': 'check the storage box health'},
        ],
      },
    });
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => settle(10));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await advance(tester, 2500);
    await golden(tester, 'live_docked');
    await end(tester);
  });

  testWidgets('live settings sheet', (tester) async {
    await boot(tester);
    await live(tester);
    await tester.tap(find.bySemanticsLabel('Voice settings'));
    await advance(tester, 600);
    await golden(tester, 'live_settings');
    await tester.tap(find.text('Voice'));
    await advance(tester, 600);
    await golden(tester, 'live_voices');
    await end(tester);
  });

  testWidgets('drawer over live mode keeps the end button', (tester) async {
    await boot(tester);
    await live(tester);
    await tester.tap(find.bySemanticsLabel('Chats'));
    await advance(tester, 600);
    expect(find.bySemanticsLabel('End live voice'), findsWidgets);
    await golden(tester, 'drawer_live');
    await end(tester);
  });

  testWidgets('effort slider', (tester) async {
    await boot(tester);
    await live(tester);
    await tester.tap(find.bySemanticsLabel('Reply effort: Medium'));
    await advance(tester, 500);
    await golden(tester, 'effort');
    await end(tester);
  });

  testWidgets('settings', (tester) async {
    await boot(tester);
    await tester.tap(find.bySemanticsLabel('Chats'));
    await advance(tester, 500);
    // Round 8: the avatar opens Settings; Profile is its first row.
    await tester.tap(find.byKey(const ValueKey('drawer-avatar')));
    await advance(tester, 800);
    expect(find.byKey(const ValueKey('settings-profile')), findsOneWidget);
    await golden(tester, 'settings');
    await tester.tap(find.byKey(const ValueKey('settings-profile')));
    await advance(tester, 800);
    expect(find.byType(ProfilePage), findsOneWidget);
  });

  testWidgets('connect', (tester) async {
    await boot(tester, key: null);
    await golden(tester, 'connect');
  });

  testWidgets('text scale 2.0: thread and live lay out without overflow', (
    tester,
  ) async {
    await boot(tester, textScale: 2);
    expect(tester.takeException(), isNull);
    await live(tester);
    expect(tester.takeException(), isNull);
    // The live pill takes its own line; mute and end sit under it.
    final add = tester.getCenter(find.byIcon(Icons.add_rounded));
    final end_ = tester.getCenter(find.byIcon(Icons.close_rounded).last);
    expect(end_.dy, greaterThan(add.dy));
    await golden(tester, 'live_scale2');
    await end(tester);
  });
}

Future<void> advance(WidgetTester tester, [int ms = 800]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
