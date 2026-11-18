import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/speech/speech_settings.dart';
import 'package:tove_chat/src/sync/settings_sync.dart';
import 'package:tove_chat/src/sync/speech_sync.dart';

import 'fake_settings_server.dart';

const _server = 'https://bridge.test:9476';
const _key = 'test-key-not-a-real-secret-0000';

/// Waits for timers and microtasks of a few debounce periods.
Future<void> idle([int ms = 120]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late FakeSettingsServer server;
  late MemoryPrefsStore prefs;

  setUp(() {
    server = FakeSettingsServer();
    prefs = MemoryPrefsStore()..values['url'] = _server;
  });

  SettingsController controller({
    FakeSettingsServer? on,
    MemoryPrefsStore? store,
    List<Duration> retry = const [Duration(milliseconds: 30)],
  }) {
    final s = store ?? prefs;
    final api = (on ?? server).api();
    final c = SettingsController(
      keys: MemoryKeyStore(_key),
      prefs: s,
      syncApi: (_, _) => api,
      sync: SettingsSync(
        store: s,
        debounce: const Duration(milliseconds: 20),
        retryDelays: retry,
      ),
    );
    addTearDown(c.dispose);
    return c;
  }

  test('initial load adopts the server copy and caches it', () async {
    server.saveElsewhere({
      'theme': 'light',
      'voice': 'marin',
      'effort_default': 'high',
      'tove.accent': 'green',
      'custom_instructions': 'Answer in British English.',
      'personalization': {'nickname': 'Kay', 'style': 'concise'},
    });
    final s = controller();
    await s.load();
    await idle();
    expect(s.sync.state, SyncState.synced);
    expect(s.theme, AppTheme.light);
    expect(s.voice, 'marin', reason: 'any bridge voice id is kept');
    expect(s.effort, ReplyEffort.high);
    expect(s.accent, AccentColour.green);
    expect(s.customInstructions, 'Answer in British English.');
    expect(s.nickname, 'Kay');
    expect(s.style, ReplyStyle.concise);
    expect(server.puts, 0, reason: 'nothing to send');
    expect(prefs.values['theme'], 'light', reason: 'local copy kept');
    final cache = jsonDecode(prefs.values[SettingsSync.cacheKey]!) as Map;
    expect((cache['base'] as Map)['version'], 1);
  });

  test('starts instantly from the cache while the server is away', () async {
    server.saveElsewhere({'theme': 'light', 'tove.accent': 'pink'});
    final first = controller();
    await first.load();
    await idle();
    expect(first.accent, AccentColour.pink);

    // Restart without a network: the cached copy applies at once.
    server.offline = true;
    final store = MemoryPrefsStore()..values.addAll(prefs.values);
    store.values.remove('accent'); // even without the per-key copy
    final again = controller(store: store);
    await again.load();
    await idle(20);
    expect(again.accent, AccentColour.pink);
    expect(again.sync.state, SyncState.offline);
    expect(again.sync.enabled, isTrue, reason: 'Personalization stays');
  });

  test('an empty server receives this device’s settings', () async {
    prefs.values
      ..['theme'] = 'system'
      ..['accent'] = 'teal'
      ..['nickname'] = 'Kay';
    final s = controller();
    await s.load();
    await idle();
    expect(server.version, 1);
    expect(server.settings['theme'], 'system');
    expect(server.settings['tove.accent'], 'teal');
    expect(server.settings['personalization'], {'nickname': 'Kay'});
    expect(s.sync.state, SyncState.synced);
  });

  test('changes are debounced into one PUT', () async {
    server.saveElsewhere({'theme': 'dark'});
    final s = controller();
    await s.load();
    await idle();
    final before = server.puts;
    await s.setTheme(AppTheme.light);
    await s.setAccent(AccentColour.purple);
    await s.setNickname('  Kay  ');
    await s.setStyle(ReplyStyle.friendly);
    expect(s.sync.state, SyncState.saving);
    expect(server.puts, before, reason: 'still inside the debounce');
    await idle();
    expect(server.puts, before + 1);
    expect(server.settings, {
      'theme': 'light',
      'tove.accent': 'purple',
      'personalization': {'nickname': 'Kay', 'style': 'friendly'},
    });
    expect(s.sync.state, SyncState.synced);
    expect(s.sync.pendingPaths, isEmpty);

    // Clearing a field removes it; no nulls are sent.
    await s.setNickname('');
    await s.setStyle(ReplyStyle.standard);
    await idle();
    expect(server.settings.containsKey('personalization'), isFalse);
    expect(jsonEncode(server.putBodies.last), isNot(contains('null')));
  });

  test(
    '409: the other device’s changes are kept, ours win for our keys',
    () async {
      server.saveElsewhere({
        'theme': 'dark',
        'personalization': {'nickname': 'Kay'},
      });
      final s = controller();
      await s.load();
      await idle();
      server.beforePut = () => server.saveElsewhere({
        'theme': 'dark',
        'tove.accent': 'orange',
        'personalization': {'nickname': 'Sam', 'occupation': 'Nurse'},
      });
      await s.setTheme(AppTheme.light);
      await s.setOccupation('Teacher');
      await idle();
      expect(server.puts, greaterThanOrEqualTo(2), reason: 'sent again');
      expect(server.settings, {
        'theme': 'light',
        'tove.accent': 'orange',
        'personalization': {'nickname': 'Sam', 'occupation': 'Teacher'},
      });
      expect(s.accent, AccentColour.orange, reason: 'adopted from the server');
      expect(s.nickname, 'Sam');
      expect(s.occupation, 'Teacher');
      expect(s.theme, AppTheme.light);
      expect(s.sync.state, SyncState.synced);
    },
  );

  test('offline: changes are queued, survive a restart and are sent', () async {
    server.saveElsewhere({'theme': 'dark'});
    final s = controller(retry: const [Duration(seconds: 30)]);
    await s.load();
    await idle();
    server.offline = true;
    await s.setTheme(AppTheme.light);
    await s.setCustomInstructions('Be brief.');
    await idle();
    expect(s.sync.state, SyncState.offline);
    expect(s.sync.pendingPaths, {'theme', 'custom_instructions'});
    final cache = jsonDecode(prefs.values[SettingsSync.cacheKey]!) as Map;
    expect((cache['pending'] as Map).keys, contains('custom_instructions'));

    // The app restarts once the server is back.
    server.offline = false;
    final store = MemoryPrefsStore()..values.addAll(prefs.values);
    final again = controller(store: store);
    await again.load();
    await idle();
    expect(server.settings, {
      'theme': 'light',
      'custom_instructions': 'Be brief.',
    });
    expect(again.sync.state, SyncState.synced);
    expect(again.customInstructions, 'Be brief.');
  });

  test('offline: the retry sends the queue when the server returns', () async {
    server.saveElsewhere({'theme': 'dark'});
    final s = controller();
    await s.load();
    await idle();
    server.offline = true;
    await s.setAccent(AccentColour.green);
    await idle(40);
    expect(s.sync.state, SyncState.offline);
    server.offline = false;
    await idle(150);
    expect(server.settings['tove.accent'], 'green');
    expect(s.sync.state, SyncState.synced);
  });

  test(
    'another device’s change arrives on refresh (304 when unchanged)',
    () async {
      server.saveElsewhere({'theme': 'dark'});
      final s = controller();
      await s.load();
      await idle();
      final gets = server.gets;
      await s.sync.refresh();
      expect(server.gets, gets + 1);
      expect(s.theme, AppTheme.dark);
      server.saveElsewhere({'theme': 'light', 'tove.send_with_enter': false});
      await s.sync.refresh();
      expect(s.theme, AppTheme.light);
      expect(s.sendWithEnter, isFalse);
    },
  );

  test('a refused key is dropped, the rest still syncs', () async {
    server.saveElsewhere({'theme': 'dark'});
    server.refuse.add('personalization.style');
    final s = controller();
    await s.load();
    await idle();
    await s.setStyle(ReplyStyle.professional);
    await s.setTheme(AppTheme.light);
    await idle();
    expect(server.settings['theme'], 'light');
    expect(server.settings.containsKey('personalization'), isFalse);
    expect(s.sync.state, SyncState.synced);
  });

  test('old bridges: local only, nothing is sent', () async {
    server.supported = false;
    final s = controller();
    await s.load();
    await idle();
    expect(s.sync.state, SyncState.localOnly);
    expect(s.sync.enabled, isFalse);
    await s.setTheme(AppTheme.light);
    await idle();
    expect(server.puts, 0);
    expect(prefs.values['theme'], 'light', reason: 'still saved locally');
  });

  test('device-only preferences never leave the device', () async {
    final s = controller();
    await s.load();
    await idle();
    await s.setHaptics(false);
    await s.setSounds(false);
    await s.setReduceMotion(true);
    await s.setTextSize(TextSize.larger);
    await s.setHighContrast(true);
    await s.setSidebarCollapsed(true);
    await idle();
    final all = jsonEncode(server.settings);
    for (final word in [
      'haptic',
      'sound',
      'motion',
      'text',
      'contrast',
      'sidebar',
    ]) {
      expect(all.toLowerCase(), isNot(contains(word)), reason: word);
    }
    expect(prefs.values['textSize'], 'larger');
  });

  test('another server drops the old server’s cache', () async {
    server.saveElsewhere({'tove.accent': 'pink'});
    final s = controller();
    await s.load();
    await idle();
    expect(s.accent, AccentColour.pink);
    final other = FakeSettingsServer()..saveElsewhere({'theme': 'light'});
    await s.sync.connect(other.api(), server: 'https://other.test');
    await idle();
    expect(s.accent, AccentColour.blue, reason: 'the other server has none');
    expect(s.theme, AppTheme.light);
  });

  test('settings over the size limit are not sent', () async {
    server.maxBytes = 200;
    server.saveElsewhere({'theme': 'dark'});
    final s = controller();
    await s.load();
    await idle();
    await s.setCustomInstructions('x' * 400);
    await idle();
    expect(s.sync.state, SyncState.error);
    expect(s.sync.problem, contains('larger'));
  });

  test('signing out stops syncing', () async {
    final s = controller();
    await s.load();
    await idle();
    await s.forgetKey();
    await idle();
    expect(s.sync.state, SyncState.localOnly);
  });

  group('speech slice', () {
    test(
      'auto read, speed and dictation language sync; engines do not',
      () async {
        server.saveElsewhere({
          'read_aloud_auto': true,
          'tove.read_aloud_speed': 1.25,
          'tove.dictation_language': 'de-DE',
        });
        final speech = SpeechSettingsController(prefs);
        final s = controller();
        final slice = SpeechSyncSlice.attach(speech, s.sync);
        addTearDown(slice.dispose);
        await s.load();
        await idle();
        expect(speech.value.autoReadReplies, isTrue);
        expect(speech.value.speed, 1.25);
        expect(speech.value.dictationLanguage, 'de-DE');
        expect(server.puts, 0, reason: 'applying is not an edit');

        await speech.update(
          (v) => v.copyWith(autoReadReplies: false, speed: 1.0),
        );
        await speech.update((v) => v.copyWith(clearDictationLanguage: true));
        await speech.update((v) => v.copyWith(dictationOnDeviceOnly: true));
        await idle();
        expect(server.settings, {'read_aloud_auto': false});
      },
    );
  });
}
