import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/settings/settings.dart';
import 'package:tove_chat/src/ui/settings_screen.dart';

import '../fakes.dart';
import 'test_harness.dart';

void main() {
  late SettingsController settings;
  late MemoryPrefsStore prefs;
  late MemoryKeyStore keys;
  late CallController call;
  late FakeBridge bridge;
  late FakeTransport transport;

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(412, 915),
    double textScale = 1,
    bool effort = true,
  }) async {
    phoneSize(tester, size: size);
    prefs = MemoryPrefsStore();
    keys = MemoryKeyStore(testKey);
    settings = SettingsController(keys: keys, prefs: prefs);
    await settings.load();
    bridge = FakeBridge();
    call = CallController(
      apiFactory: bridge.api,
      transportFactory: () => transport = FakeTransport(),
      platform: FakePlatform(supported: false),
      voice: () => settings.voice,
      timings: fastTimings,
      desktop: true,
    );
    addTearDown(call.dispose);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: themed(
          // A host page, so Settings can pop back to it.
          Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => SettingsScreen(
                settings: settings,
                call: call,
                effortSupported: effort,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool editing() => find
      .byType(EditableText)
      .evaluate()
      .any((e) => (e.widget as EditableText).focusNode.hasFocus);

  group('search', () {
    test('finds labels and synonyms, only for features that exist', () {
      final all = settingsIndex(
        effort: true,
        speech: true,
        notifications: true,
      );
      expect(searchSettings('dark', all).first.id, 'theme');
      expect(searchSettings('vibration', all).single.id, 'haptics');
      expect(searchSettings('log out', all).single.id, 'forgetKey');
      expect(searchSettings('licenses', all).single.id, 'licences');
      expect(searchSettings('read', all).take(2).map((e) => e.id), [
        'readAloud',
        'readReplies',
      ], reason: 'label matches first');
      final bare = settingsIndex(
        effort: false,
        speech: false,
        notifications: false,
      );
      expect(searchSettings('effort', bare), isEmpty);
      expect(searchSettings('dictation', bare), isEmpty);
      expect(searchSettings('notifications', bare), isEmpty);
      expect(searchSettings('   ', all), isEmpty);
    });

    testWidgets('opens without the keyboard; a result opens its page at the '
        'control, and the change is saved', (tester) async {
      await open(tester);
      expect(find.text('Search settings'), findsOneWidget);
      expect(editing(), isFalse, reason: 'no keyboard on open');
      for (final s in ['General', 'Voice', 'Connection', 'About']) {
        expect(find.text(s), findsOneWidget);
      }
      expect(find.text('Storage'), findsNothing, reason: 'no speech services');
      expect(find.text('Notifications'), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('settings-search')),
        'vibration',
      );
      await tester.pump();
      expect(find.text('1 result'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-result-haptics')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-page-general')), findsOne);
      final haptics = find.text('Haptics');
      expect(haptics.hitTestable(), findsOneWidget, reason: 'scrolled to');
      await tester.tap(haptics);
      await tester.pump();
      expect(settings.haptics, isFalse);
      expect(prefs.values['haptics'], 'false', reason: 'persisted');

      await tester.tap(find.bySemanticsLabel('Back').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-page-general')), findsNothing);
      expect(
        find.byKey(const ValueKey('settings-result-haptics')),
        findsOneWidget,
        reason: 'the search is kept when coming back',
      );
      expect(editing(), isFalse);
    });

    testWidgets('no results says so, and Clear brings the categories back', (
      tester,
    ) async {
      await open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('settings-search')),
        'subscription',
      );
      await tester.pump();
      expect(find.text('No settings match “subscription”.'), findsOneWidget);
      expect(find.text('General'), findsNothing);
      await tester.tap(find.text('Clear search'));
      await tester.pump();
      expect(find.text('General'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('settings-search')))
            .controller!
            .text,
        isEmpty,
      );
    });
  });

  group('connection', () {
    testWidgets('never shows the key; forgetting asks first', (tester) async {
      await open(tester);
      await tester.tap(find.text('Connection'));
      await tester.pumpAndSettle();
      expect(find.textContaining(testKey), findsNothing);
      expect(find.text('Saved on this device'), findsOneWidget);

      await tester.tap(find.text('Forget access key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(keys.value, testKey, reason: 'cancel keeps it');

      await tester.tap(find.text('Forget access key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget'));
      await tester.pumpAndSettle();
      expect(keys.value, isNull);
      expect(settings.hasKey, isFalse);
    });

    testWidgets('a live call locks the server and key', (tester) async {
      await open(tester);
      await tester.runAsync(() async {
        await call.start();
        await settle(10);
      });
      transport.emit({'type': 'session.started'});
      await tester.runAsync(() => settle(10));
      expect(call.inCall, isTrue);
      await tester.tap(find.text('Connection'));
      await tester.pumpAndSettle();
      expect(
        find.text('End live voice to change the connection'),
        findsOneWidget,
      );
      await tester.tap(find.text('Change server or access key'));
      await tester.pumpAndSettle();
      expect(
        find.text('Change server or access key'),
        findsOneWidget,
        reason: 'nothing opened',
      );
      await tester.runAsync(() => call.end());
    });
  });

  testWidgets('wide screens show the categories beside the selected one; '
      'search moves the pane', (tester) async {
    await open(tester, size: const Size(1280, 800));
    expect(find.byKey(const ValueKey('settings-nav')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-pane-general')), findsOne);
    expect(find.text('Show suggestions'), findsOneWidget);
    expect(find.text('Reduce motion'), findsNothing, reason: 'Accessibility');
    await tester.tap(find.byKey(const ValueKey('settings-nav-about')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-pane-about')), findsOne);
    expect(find.text('Licences'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('settings-nav-about'))),
      isSemantics(isSelected: true),
    );

    await tester.enterText(
      find.byKey(const ValueKey('settings-search')),
      'effort',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('settings-result-effort')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-pane-general')), findsOne);
    // The pane's row (the search results list it too).
    await tester.tap(find.text('Reply effort').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('High'));
    await tester.pump();
    expect(settings.effort, ReplyEffort.high);
    expect(prefs.values['effort'], 'high');
  }, semanticsEnabled: true);

  testWidgets('200 % text: hub and pages lay out without overflow', (
    tester,
  ) async {
    await open(tester, size: const Size(360, 780), textScale: 2);
    expect(tester.takeException(), isNull);
    for (final s in [
      'General',
      'Voice',
      'Data controls',
      'Connection',
      'Accessibility',
      'About',
    ]) {
      await tester.scrollUntilVisible(
        find.text(s),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('settings-hub')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text(s));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: s);
      await tester.tap(find.bySemanticsLabel('Back').last);
      await tester.pumpAndSettle();
    }
  });
}
