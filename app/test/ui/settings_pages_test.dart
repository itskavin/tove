import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/settings/appearance.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/sync/settings_sync.dart';
import 'package:tove_chat/src/ui/settings/connection_section.dart'
    show bridgeFeatures;
import 'package:tove_chat/src/ui/settings_screen.dart';
import 'package:tove_chat/src/ui/theme/theme.dart';

import 'settings_harness.dart';

void main() {
  late SettingsHarness h;

  Future<SettingsHarness> make({bool sync = true}) async {
    h = SettingsHarness(syncSupported: sync);
    await h.setUp();
    addTearDown(h.dispose);
    return h;
  }

  group('search', () {
    List<SettingsEntry> all({bool personal = true, bool desktop = true}) =>
        settingsIndex(
          effort: true,
          speech: true,
          notifications: true,
          personalization: personal,
          history: true,
          sendWithEnter: desktop,
          liveBackend: true,
        );

    String? first(String q, [List<SettingsEntry>? index]) =>
        searchSettings(q, index ?? all()).firstOrNull?.id;

    test('every new option is findable by label and synonyms', () {
      final cases = {
        'accent': 'accent',
        'color': 'accent',
        'font size': 'textSize',
        'starter prompts': 'suggestions',
        'enter': 'sendWithEnter',
        'custom instructions': 'aboutYou',
        'system prompt': 'customInstructions',
        'nickname': 'nickname',
        'job': 'occupation',
        'personality': 'style',
        'concise': 'style',
        'backend': 'liveBackend',
        'dictation language': 'dictationLanguage',
        'test push': 'testPush',
        'chat history': 'history',
        'backup': 'export',
        'json': 'export',
        'wipe': 'deleteAll',
        'clear cache': 'cache',
        'capabilities': 'bridge',
        'tokens': 'usage',
        'sync': 'sync',
        'someone else': 'selfHost',
        'self host': 'selfHost',
        'high contrast': 'contrast',
        'larger text': 'largerText',
        'privacy': 'privacy',
        'reduce motion': 'motion',
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        expect(first(key), value, reason: key);
      }
      // Every entry is found by its own label.
      for (final e in all()) {
        expect(
          searchSettings(e.label, all()).map((x) => x.id),
          contains(e.id),
          reason: e.label,
        );
      }
    });

    test('options the app or server can’t honour are not indexed', () {
      final bare = all(personal: false, desktop: false);
      expect(searchSettings('nickname', bare), isEmpty);
      expect(searchSettings('enter', bare), isEmpty);
      expect(
        searchSettings(
          'export',
          settingsIndex(effort: false, speech: false, notifications: false),
        ),
        isEmpty,
        reason: 'no chat history',
      );
      expect(searchSettings('memory', all()), isEmpty, reason: 'hidden');
      expect(searchSettings('language of the app', all()), isEmpty);
    });

    testWidgets('a result opens the right page at the control', (tester) async {
      await make();
      await h.open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('settings-search')),
        'occupation',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('settings-result-occupation')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings-page-personalization')),
        findsOne,
      );
      expect(
        find.byKey(const ValueKey('settings-occupation')).hitTestable(),
        findsOneWidget,
      );
    });
  });

  group('hub', () {
    testWidgets('grouped categories and a subtle sync line', (tester) async {
      await make();
      await h.open(tester);
      for (final s in [
        'General',
        'Personalization',
        'Voice',
        'Data controls',
        'Connection',
        'Accessibility',
        'About',
      ]) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
      expect(h.state, SyncState.synced);
      expect(find.textContaining('synced across'), findsNothing);
    });

    testWidgets('old bridge: no Personalization, local-only note', (
      tester,
    ) async {
      await make(sync: false);
      await h.open(tester);
      expect(find.text('Personalization'), findsNothing);
      expect(find.textContaining('kept on this device'), findsOneWidget);
    });
  });

  group('general', () {
    testWidgets('accent, text size, suggestions and Send with Enter', (
      tester,
    ) async {
      await make();
      await h.open(tester);
      await openSection(tester, 'General');
      await tester.tap(find.bySemanticsLabel('Green accent'));
      await tester.pump();
      expect(h.settings.accent, AccentColour.green);

      await tester.tap(find.text('Text size'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Larger'));
      await tester.pump();
      expect(h.settings.textSize, TextSize.larger);
      await tester.tap(find.bySemanticsLabel('Back').last);
      await tester.pumpAndSettle();
      expect(find.text('Larger'), findsOneWidget, reason: 'value shown');

      await reveal(tester, find.text('Send with Enter'));
      await tester.tap(find.text('Show suggestions'));
      await tester.tap(find.text('Send with Enter'));
      await tester.pump();
      expect(h.settings.showSuggestions, isFalse);
      expect(h.settings.sendWithEnter, isFalse);
      expect(find.text('Enter adds a line; use the Send button.'), findsOne);

      await tester.pump(const Duration(seconds: 1)); // debounce
      await tester.pump();
      expect(h.server.settings['tove.accent'], 'green');
      expect(h.server.settings['tove.suggestions'], false);
      expect(h.server.settings['tove.send_with_enter'], false);
      expect(
        jsonEncode(h.server.settings),
        isNot(contains('larger')),
        reason: 'text size is per device',
      );
    });

    testWidgets('phones have no Send with Enter row', (tester) async {
      await make();
      await h.open(tester, desktopKeys: false);
      await openSection(tester, 'General');
      expect(find.text('Send with Enter'), findsNothing);
    });

    testWidgets('reply effort opens its choices', (tester) async {
      await make();
      await h.open(tester);
      await openSection(tester, 'General');
      await reveal(tester, find.text('Reply effort'));
      await tester.tap(find.text('Reply effort'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('High'));
      await tester.pumpAndSettle();
      expect(h.settings.effort, ReplyEffort.high);
      expect(h.server.settings['effort_default'], 'high');
    });

    test('accent and contrast recolour the tokens and keep the rest', () {
      final base = buildTheme(Brightness.dark);
      final t = base.extension<HermesTokens>()!;
      final same = applyAppearance(
        base,
        accent: AccentColour.blue,
        highContrast: false,
      );
      expect(identical(same, base), isTrue);
      final next = applyAppearance(
        base,
        accent: AccentColour.green,
        highContrast: true,
      );
      final n = next.extension<HermesTokens>()!;
      expect(n.accent.toARGB32(), AccentColour.green.dark.toARGB32());
      expect(next.colorScheme.primary.toARGB32(), n.accent.toARGB32());
      expect(n.bg.toARGB32(), t.bg.toARGB32());
      expect(n.text.toARGB32(), t.text.toARGB32());
      expect(n.danger.toARGB32(), t.danger.toARGB32());
      expect(n.textMuted.toARGB32(), isNot(t.textMuted.toARGB32()));
      expect(n.dark, t.dark);
      expect(n.body.fontFamily, t.body.fontFamily, reason: 'typeface kept');
    });

    testWidgets('text size scales the system size', (tester) async {
      late double scale;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.2)),
          child: AppTextScale(
            factor: 1.5,
            child: Builder(
              builder: (c) {
                scale = MediaQuery.textScalerOf(c).scale(10) / 10;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(scale, closeTo(1.8, 1e-9));
    });
  });

  group('personalization', () {
    testWidgets('edits reach the server; reset asks first', (tester) async {
      await make();
      await h.open(tester);
      await openSection(tester, 'Personalization');
      await tester.tap(find.byKey(const ValueKey('settings-nickname')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('settings-nickname-field')),
        'Kay',
      );
      await tester.tap(find.byKey(const ValueKey('settings-text-done')));
      await tester.pumpAndSettle();
      expect(h.settings.nickname, 'Kay');
      expect(find.text('Kay'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('settings-instructions')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('settings-instructions-field')),
        'Use metric units.',
      );
      // Back keeps what was typed.
      await tester.tap(find.bySemanticsLabel('Back').last);
      await tester.pumpAndSettle();
      expect(h.settings.customInstructions, 'Use metric units.');
      expect(find.text('Use metric units.'), findsOneWidget);

      await reveal(
        tester,
        find.byKey(const ValueKey('settings-style-concise')),
      );
      await tester.tap(find.byKey(const ValueKey('settings-style-concise')));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(h.server.settings['custom_instructions'], 'Use metric units.');
      expect(h.server.settings['personalization'], {
        'nickname': 'Kay',
        'style': 'concise',
      });

      await reveal(tester, find.text('Reset personalization'));
      await tester.tap(find.text('Reset personalization'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(h.settings.nickname, 'Kay');
      await tester.tap(find.text('Reset personalization'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      expect(h.settings.personalized, isFalse);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(h.server.settings.containsKey('personalization'), isFalse);
      expect(h.server.settings.containsKey('custom_instructions'), isFalse);
    });

    testWidgets('the text limit comes from the server', (tester) async {
      await make();
      await h.open(tester);
      await openSection(tester, 'Personalization');
      await tester.tap(find.byKey(const ValueKey('settings-about-you')));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('settings-about-you-field')),
      );
      expect(field.maxLength, h.settings.textLimit);
    });
  });

  group('voice', () {
    testWidgets('the voice service is shown read-only', (tester) async {
      await make();
      await h.open(tester);
      await openSection(tester, 'Voice');
      final row = find.byKey(const ValueKey('settings-live-backend'));
      expect(row, findsOneWidget);
      expect(
        find.textContaining('42 of 60 minutes left today'),
        findsOneWidget,
      );
      expect(find.textContaining('Calls up to 30 minutes'), findsOneWidget);
    });
  });

  group('data controls', () {
    testWidgets('export saves one JSON file with every chat', (tester) async {
      await make();
      await h.open(tester);
      await openSection(tester, 'Data controls');
      await tester.tap(find.byKey(const ValueKey('settings-export')));
      await tester.pumpAndSettle();
      expect(
        h.savedName,
        matches(RegExp(r'^tove-chats-\d{4}-\d\d-\d\d\.json$')),
      );
      final out = jsonDecode(utf8.decode(h.savedBytes!)) as Map;
      expect((out['conversations'] as List).length, 2);
      expect(find.text('Exported 2 chats.'), findsOneWidget);
    });

    testWidgets('delete all needs the typed word', (tester) async {
      await make();
      await h.open(tester);
      await openSection(tester, 'Data controls');
      await tester.tap(find.byKey(const ValueKey('settings-delete-all')));
      await tester.pumpAndSettle();
      TextButton go() => tester.widget<TextButton>(
        find.byKey(const ValueKey('delete-all-go')),
      );
      expect(go().onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('delete-all-confirm')),
        'delete',
      );
      await tester.pump();
      expect(go().onPressed, isNull, reason: 'exact word');
      await tester.enterText(
        find.byKey(const ValueKey('delete-all-confirm')),
        'DELETE',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('delete-all-go')));
      await tester.pumpAndSettle();
      expect(h.deleted, ['c1', 'c2']);
      expect(h.cleared, 1);
      expect(find.text('Deleted 2 chats.'), findsOneWidget);
    });

    testWidgets('history lists, searches and opens chats', (tester) async {
      await make();
      await h.open(tester);
      await openSection(tester, 'Data controls');
      await tester.tap(find.byKey(const ValueKey('settings-history')));
      await tester.pumpAndSettle();
      expect(find.text('Disk space on storage'), findsOneWidget);
      expect(find.text('Weekend plan'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('history-search')),
        'week',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('Disk space on storage'), findsNothing);
      await tester.tap(find.text('Weekend plan'));
      await tester.pumpAndSettle();
      expect(h.opened, 'c2');
    });

    testWidgets('cache size and clear', (tester) async {
      await make();
      await h.open(tester, history: false);
      await openSection(tester, 'Data controls');
      expect(find.text('Chat history'), findsNothing, reason: 'no history');
      expect(find.text('12 MB'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-cache-clear')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear').last);
      await tester.pumpAndSettle();
      expect(h.cache.clears, 1);
      expect(find.text('0 B'), findsOneWidget);
    });
  });

  group('connection', () {
    testWidgets('status, features, sync, usage and the guide', (tester) async {
      await make();
      await h.open(tester);
      await openSection(tester, 'Connection');
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('API 2'), findsOneWidget);
      expect(find.text('Synced'), findsOneWidget);
      expect(find.text('42 of 60 minutes left today'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-bridge')));
      await tester.pumpAndSettle();
      expect(find.text('Synced settings'), findsOneWidget);
      expect(find.text('Images to Hermes'), findsOneWidget);
      final features = bridgeFeatures(bridgeCaps());
      expect(features, contains(('Synced settings', true)));
      expect(features, contains(('Images to Hermes', false)));
      await tester.tap(find.bySemanticsLabel('Back').last);
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(const ValueKey('settings-self-host')));
      await tester.tap(find.byKey(const ValueKey('settings-self-host')));
      await tester.pump();
      expect(h.links, isEmpty, reason: 'no link to a guide users cannot open');
    }, semanticsEnabled: true);

    testWidgets('an unreachable server says so', (tester) async {
      await make();
      await h.open(tester, caps: const Capabilities.liveOnly(known: false));
      await openSection(tester, 'Connection');
      expect(find.text('Can’t reach the server'), findsOneWidget);
      expect(find.text('Server version and features'), findsNothing);
    });
  });

  group('accessibility and about', () {
    testWidgets('reduce motion, larger text and contrast stay local', (
      tester,
    ) async {
      await make();
      await h.open(tester);
      await openSection(tester, 'Accessibility');
      await tester.tap(find.text('Reduce motion'));
      await tester.tap(find.text('Increase contrast'));
      await tester.pump();
      expect(h.settings.reduceMotion, isTrue);
      expect(h.settings.highContrast, isTrue);
      expect(find.text('On this device only.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(jsonEncode(h.server.settings), isNot(contains('contrast')));
    });

    testWidgets('About has a privacy note', (tester) async {
      await make();
      await h.open(tester);
      await openSection(tester, 'About');
      await reveal(tester, find.textContaining('no analytics'));
      expect(find.textContaining('no analytics'), findsOneWidget);
    });
  });

  testWidgets('every page lays out at 200 % text on a small phone', (
    tester,
  ) async {
    await make();
    await h.open(tester, size: const Size(360, 780), textScale: 2);
    for (final s in [
      'General',
      'Personalization',
      'Voice',
      'Data controls',
      'Connection',
      'Accessibility',
      'About',
    ]) {
      await reveal(tester, find.text(s));
      await openSection(tester, s);
      expect(tester.takeException(), isNull, reason: s);
      await tester.tap(find.bySemanticsLabel('Back').last);
      await tester.pumpAndSettle();
    }
  });

  testWidgets('wide layout shows every category beside its pane', (
    tester,
  ) async {
    await make();
    await h.open(tester, size: const Size(1280, 800));
    for (final s in SettingsSection.values) {
      if (s == SettingsSection.notifications) continue;
      await tester.tap(find.byKey(ValueKey('settings-nav-${s.name}')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('settings-pane-${s.name}')), findsOne);
      expect(tester.takeException(), isNull, reason: s.name);
    }
  });
}
