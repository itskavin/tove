import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/settings/local_cache.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/sync/chat_archive.dart';
import 'package:tove_chat/src/sync/settings_sync.dart';
import 'package:tove_chat/src/ui/settings_screen.dart';

import '../chat/fake_http.dart';
import '../fakes.dart';
import '../sync/fake_settings_server.dart';
import 'test_harness.dart';

class FakeCache implements LocalCache {
  int bytes = 12 * 1024 * 1024;
  int clears = 0;
  @override
  Future<int?> size() async => bytes;
  @override
  Future<void> clear() async {
    clears++;
    bytes = 0;
  }
}

/// Capabilities of a current bridge (openai backend with a voice budget).
Capabilities bridgeCaps({bool sync = true}) => Capabilities.fromJson({
  'version': 2,
  'chat': true,
  'history': true,
  'search': true,
  'effort': true,
  'attachments': true,
  'web_search': true,
  'usage': true,
  'settings_sync': sync,
  'suggestions': true,
  'push': 'unifiedpush',
  'live_backend': 'openai',
  'live_backends': {
    'openai': {
      'available': true,
      'active': true,
      'max_call_s': 1800,
      'daily_minutes': 60,
      'minutes_left_today': 42.5,
    },
  },
});

/// Settings over a fake bridge: synced settings, chats, cache, links.
class SettingsHarness {
  SettingsHarness({this.syncSupported = true});

  final bool syncSupported;
  late final FakeSettingsServer server = FakeSettingsServer(
    supported: syncSupported,
  );
  final prefs = MemoryPrefsStore()..values['url'] = 'https://bridge.test:9476';
  final keys = MemoryKeyStore(testKey);
  final net = FakeHttp();
  final cache = FakeCache();
  late final SettingsController settings;
  late final CallController call;
  late final ConversationsController conversations;
  final deleted = <String>[];
  final links = <Uri>[];
  String? savedName;
  Uint8List? savedBytes;
  int cleared = 0;
  String? opened;

  Future<void> setUp() async {
    settings = SettingsController(
      keys: keys,
      prefs: prefs,
      syncApi: (_, _) => server.api(),
      // Short, so each pumpAndSettle also sends the change.
      sync: SettingsSync(
        store: prefs,
        debounce: const Duration(milliseconds: 50),
      ),
    );
    // The sync's first exchange finishes in open()'s pumpAndSettle (the
    // fake server answers with microtasks only).
    await settings.load();
    call = CallController(
      apiFactory: FakeBridge().api,
      transportFactory: FakeTransport.new,
      platform: FakePlatform(supported: false),
      voice: () => settings.voice,
      timings: fastTimings,
      desktop: true,
    );
    final chats = [
      for (final (id, title) in const [
        ('c1', 'Disk space on storage'),
        ('c2', 'Weekend plan'),
      ])
        {
          'id': id,
          'title': title,
          'pinned': false,
          'kind': 'text',
          'created': 1794691021626,
          'updated': 1794691024435,
        },
    ];
    net.on('GET /api/conversations', (_) {
      final left = [
        for (final c in chats)
          if (!deleted.contains(c['id'])) c,
      ];
      return jsonResponse({'conversations': left, 'next_cursor': null});
    });
    for (final c in chats) {
      final id = c['id'] as String;
      net.on(
        'GET /api/conversations/$id',
        (_) => jsonResponse({
          'conversation': c,
          'messages': [
            {'id': '$id-m1', 'role': 'user', 'text': 'hello'},
          ],
          'has_more': false,
        }),
      );
      net.on('DELETE /api/conversations/$id', (_) {
        deleted.add(id);
        return jsonResponse({'ok': true});
      });
    }
    net.on(
      'GET /api/conversations/search',
      (r) => jsonResponse({
        'results': [
          for (final c in chats)
            if ((c['title'] as String).toLowerCase().contains(
              r.query['q']!.toLowerCase(),
            ))
              {'conversation': c, 'message_id': null, 'snippet': ''},
        ],
      }),
    );
    conversations = ConversationsController(
      api: ChatApi(baseUrl: chatTestBase, accessKey: chatTestKey, client: net),
    );
  }

  void dispose() {
    call.dispose();
    conversations.dispose();
  }

  SettingsScreen screen({
    bool desktopKeys = true,
    Capabilities? caps,
    bool history = true,
  }) => SettingsScreen(
    settings: settings,
    call: call,
    effortSupported: true,
    showShortcuts: false,
    desktopKeys: desktopKeys,
    capabilities: caps ?? bridgeCaps(sync: syncSupported),
    usageLimits: ({bool refresh = false}) async =>
        const UsageLimits(providers: []),
    openLink: (u) async {
      links.add(u);
      return true;
    },
    data: DataControls(
      conversations: history ? conversations : null,
      archive: history
          ? () => ChatArchive(
              baseUrl: chatTestBase,
              accessKey: chatTestKey,
              client: net,
            )
          : null,
      onOpenChat: (id) => opened = id,
      onChatsCleared: () => cleared++,
      cache: cache,
      save: (name, bytes) async {
        savedName = name;
        savedBytes = bytes;
        return true;
      },
    ),
  );

  /// Pumps Settings in a host navigator, so pages can pop back to it.
  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(412, 915),
    double textScale = 1,
    Brightness brightness = Brightness.dark,
    bool desktopKeys = true,
    Capabilities? caps,
    bool history = true,
  }) async {
    phoneSize(tester, size: size);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: themed(
          brightness: brightness,
          Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => screen(
                desktopKeys: desktopKeys,
                caps: caps,
                history: history,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  SyncState get state => settings.sync.state;
}

/// Opens a hub category on a phone layout.
Future<void> openSection(WidgetTester tester, String title) async {
  await tester.tap(find.text(title).first);
  await tester.pumpAndSettle();
}

/// Scrolls the current settings page until [finder] is on screen.
Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.pumpAndSettle();
}
