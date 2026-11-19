import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tove_chat/src/app.dart' show kAppVersion;
import 'package:tove_chat/src/ui/settings/accessibility_about_sections.dart';
import 'package:tove_chat/src/update/update_check.dart';
import 'package:tove_chat/src/update/update_ui.dart';

import '../ui/test_harness.dart';

Map<String, Object?> release({
  String tag = 'v1.2.0+5',
  String body = '- Faster replies\n- Update check',
  List<Map<String, Object?>>? assets,
  bool prerelease = false,
}) => {
  'tag_name': tag,
  'name': 'Tove ${tag.substring(1).split('+').first}',
  'html_url': 'https://github.com/itskavin/tove/releases/tag/$tag',
  'body': body,
  'draft': false,
  'prerelease': prerelease,
  'assets':
      assets ??
      [
        {
          'name': 'tove-${tag.substring(1).split('+').first}.apk',
          'browser_download_url':
              'https://github.com/itskavin/tove/releases/download/$tag/tove-1.2.0.apk',
        },
      ],
};

http.Response json(Object body, {int status = 200, Map<String, String>? h}) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json', ...?h},
    );

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  group('AppVersion', () {
    test('parses tags, pubspec versions and APK names', () {
      expect(AppVersion.tryParse('v1.2.3+7').toString(), '1.2.3+7');
      expect(AppVersion.tryParse('1.2.3').toString(), '1.2.3');
      expect(AppVersion.tryParse('v1.2.3-beta.1+7')?.build, 7);
      expect(AppVersion.tryParse('latest'), isNull);
      expect(AppVersion.tryParse('1.2'), isNull);
      expect(AppVersion.fromApkName('tove-1.4.0.apk').toString(), '1.4.0');
      expect(AppVersion.fromApkName('app-release.apk'), isNull);
    });

    test('compares numerically, by build only when both have one', () {
      AppVersion v(String s) => AppVersion.tryParse(s)!;
      expect(v('1.10.0').isNewerThan(v('1.9.9')), isTrue);
      expect(v('2.0.0').isNewerThan(v('1.99.99+99')), isTrue);
      expect(v('1.0.0+2').isNewerThan(v('1.0.0+1')), isTrue);
      expect(v('1.0.0+1').isNewerThan(v('1.0.0+2')), isFalse);
      expect(v('1.0.0').isNewerThan(v('1.0.0+9')), isFalse);
      expect(v('1.0.0+9').isNewerThan(v('1.0.0')), isFalse);
    });

    test('kAppVersion matches the pubspec version', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final m = RegExp(
        r'^version:\s*(\S+)',
        multiLine: true,
      ).firstMatch(pubspec);
      expect(kAppVersion, m![1], reason: 'bump both (app/README.md)');
      expect(AppVersion.tryParse(kAppVersion)?.build, isNotNull);
    });
  });

  group('ReleaseInfo', () {
    test('prefers the tove-*.apk asset; falls back to the release page', () {
      final r = ReleaseInfo.fromJson(
        release(
          assets: [
            {
              'name': 'other.apk',
              'browser_download_url': 'https://example.test/other.apk',
            },
            {
              'name': 'tove-1.2.0.apk',
              'browser_download_url': 'https://example.test/tove-1.2.0.apk',
            },
            {'name': 'notes.txt', 'browser_download_url': 'https://x.test/n'},
          ],
        ),
      )!;
      expect(r.downloadUrl.toString(), 'https://example.test/tove-1.2.0.apk');
      expect(r.version.toString(), '1.2.0+5');
      final none = ReleaseInfo.fromJson(release(assets: const []))!;
      expect(none.downloadUrl, none.pageUrl);
    });

    test('takes the version from the APK name when the tag has none', () {
      final r = ReleaseInfo.fromJson(
        release(
          tag: 'spring-update',
          assets: [
            {
              'name': 'tove-1.2.0.apk',
              'browser_download_url': 'https://example.test/tove-1.2.0.apk',
            },
          ],
        ),
      )!;
      expect(r.version.toString(), '1.2.0');
      expect(ReleaseInfo.fromJson(release(prerelease: true)), isNull);
      expect(
        ReleaseInfo.fromJson(release(tag: 'spring', assets: const [])),
        isNull,
      );
    });
  });

  group('UpdateChecker', () {
    late DateTime now;
    late int requests;

    UpdateChecker checker(
      http.Response Function(http.Request) answer, {
      String installed = '1.1.0+4',
    }) {
      return UpdateChecker(
        client: MockClient((r) async {
          requests++;
          expect(r.url, kLatestReleaseApi);
          expect(r.headers['Authorization'], isNull);
          return answer(r);
        }),
        installed: installed,
        now: () => now,
        supported: true,
      );
    }

    setUp(() {
      now = DateTime(2026, 11, 19, 9);
      requests = 0;
    });

    test('finds a newer release, at most every 6 hours', () async {
      final c = checker((_) => json(release()));
      final r = await c.checkIfDue();
      expect(r?.version.name, '1.2.0');
      expect(c.status, UpdateStatus.available);
      expect(requests, 1);

      now = now.add(const Duration(hours: 5));
      final again = checker((_) => json(release()));
      expect(await again.checkIfDue(), isNull, reason: 'checked recently');
      expect(requests, 1);

      now = now.add(const Duration(hours: 2));
      expect((await again.checkIfDue())?.tag, 'v1.2.0+5');
      expect(requests, 2);
    });

    test('same or older version: up to date', () async {
      final same = checker((_) => json(release()), installed: '1.2.0+5');
      expect(await same.checkNow(), UpdateStatus.upToDate);
      expect(same.available, isNull);
      final older = checker((_) => json(release()), installed: '1.3.0+6');
      expect(await older.checkNow(), UpdateStatus.upToDate);
      final none = checker((_) => http.Response('{}', 404));
      expect(await none.checkNow(), UpdateStatus.upToDate);
    });

    test('rate limits, errors and no connection stay quiet', () async {
      final limited = checker(
        (_) => json(
          {'message': 'API rate limit exceeded'},
          status: 403,
          h: {'x-ratelimit-remaining': '0'},
        ),
      );
      expect(await limited.checkIfDue(), isNull);
      expect(limited.status, UpdateStatus.rateLimited);
      expect(
        await checker((_) => http.Response('', 429)).checkNow(),
        UpdateStatus.rateLimited,
      );
      expect(
        await checker((_) => http.Response('oops', 500)).checkNow(),
        UpdateStatus.failed,
      );
      expect(
        await checker((_) => http.Response('not json', 200)).checkNow(),
        UpdateStatus.failed,
      );

      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final offline = checker(
        (_) => throw http.ClientException('Failed host lookup'),
      );
      expect(await offline.checkIfDue(), isNull);
      expect(offline.status, UpdateStatus.offline);
      expect(offline.lastCheck, isNull, reason: 'retried at the next start');
      expect(await offline.checkIfDue(), isNull);
      expect(requests, 5, reason: 'no retry within 15 minutes');
      now = now.add(const Duration(minutes: 16));
      await offline.checkIfDue();
      expect(requests, 6, reason: 'retried on the next resume');
    });

    test('a rate limit is not counted as a check', () async {
      var limited = true;
      final c = checker(
        (_) => limited
            ? json(
                {'message': 'x'},
                status: 403,
                h: {'x-ratelimit-remaining': '0'},
              )
            : json(release()),
      );
      expect(await c.checkIfDue(), isNull);
      expect(c.lastCheck, isNull);
      limited = false;
      now = now.add(const Duration(minutes: 20));
      expect((await c.checkIfDue())?.tag, 'v1.2.0+5');
    });

    test('off: no request at start; Check for updates still works', () async {
      final c = checker((_) => json(release()));
      await c.load();
      await c.setEnabled(false);
      final reloaded = checker((_) => json(release()));
      await reloaded.load();
      expect(reloaded.enabled, isFalse, reason: 'remembered');
      expect(await reloaded.checkIfDue(), isNull);
      expect(requests, 0);
      expect(await reloaded.checkNow(), UpdateStatus.available);
      expect(requests, 1);
    });

    test('"Later" silences this release at start, not the next one', () async {
      final c = checker((_) => json(release()));
      final r = (await c.checkIfDue())!;
      await c.dismiss(r);
      now = now.add(const Duration(days: 2));
      final next = checker((_) => json(release()));
      expect(await next.checkIfDue(), isNull);
      expect(next.available?.tag, 'v1.2.0+5', reason: 'About still shows it');
      now = now.add(const Duration(days: 2));
      final newer = checker((_) => json(release(tag: 'v1.3.0+6')));
      expect((await newer.checkIfDue())?.tag, 'v1.3.0+6');
    });

    test('not on this platform: never asks', () async {
      final c = UpdateChecker(
        client: MockClient((_) async {
          requests++;
          return json(release());
        }),
        supported: false,
      );
      expect(await c.checkIfDue(), isNull);
      expect(requests, 0);
    });
  });

  group('UI', () {
    Widget about(UpdateChecker c) => themed(
      UpdateScope(
        checker: c,
        child: Builder(
          builder: (context) =>
              Scaffold(body: ListView(children: aboutSection(context))),
        ),
      ),
    );

    testWidgets('About › Check for updates opens the release with Download', (
      tester,
    ) async {
      phoneSize(tester);
      final opened = <Uri>[];
      final c = UpdateChecker(
        client: MockClient((_) async => json(release())),
        installed: '1.1.0+4',
        supported: true,
      );
      await tester.pumpWidget(
        themed(
          UpdateScope(
            checker: c,
            child: Builder(
              builder: (context) => Scaffold(
                body: ListView(
                  children: updateRows(
                    context,
                    open: (u) async {
                      opened.add(u);
                      return true;
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Check for updates'), findsOneWidget);
      expect(find.text('Installed: 1.1.0'), findsOneWidget);
      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-dialog')), findsOneWidget);
      expect(find.text('Tove 1.2.0 is available'), findsOneWidget);
      expect(find.textContaining('Faster replies'), findsOneWidget);
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(opened.single.path, endsWith('/tove-1.2.0.apk'));
      expect(find.byKey(const ValueKey('update-dialog')), findsNothing);
      expect(find.textContaining('Version 1.2.0 is available'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('about-auto-update-check')));
      await tester.pump();
      expect(c.enabled, isFalse);
    });

    testWidgets('up to date and offline are said in the row', (tester) async {
      phoneSize(tester);
      var online = true;
      final c = UpdateChecker(
        client: MockClient((_) async {
          if (!online) throw http.ClientException('offline');
          return json(release());
        }),
        installed: '1.2.0+5',
        supported: true,
      );
      await tester.pumpWidget(about(c));
      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();
      expect(find.text('You have the latest version (1.2.0).'), findsOneWidget);
      expect(find.byKey(const ValueKey('update-dialog')), findsNothing);
      online = false;
      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Couldn’t reach GitHub'), findsOneWidget);
    });

    testWidgets('no checker (web, desktop, tests): no Updates rows', (
      tester,
    ) async {
      phoneSize(tester);
      await tester.pumpWidget(
        themed(
          Builder(
            builder: (context) =>
                Scaffold(body: ListView(children: aboutSection(context))),
          ),
        ),
      );
      expect(find.text('Check for updates'), findsNothing);
    });

    testWidgets('start-up check shows the dialog; Later dismisses it', (
      tester,
    ) async {
      phoneSize(tester);
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: key, home: const Scaffold()),
      );
      final shown = runStartupUpdateCheck(
        UpdateChecker(
          client: MockClient((_) async => json(release())),
          installed: '1.1.0+4',
          supported: true,
        ),
        () => key.currentContext,
      );
      await tester.pumpAndSettle();
      expect(find.text('Tove 1.2.0 is available'), findsOneWidget);
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      await shown;
      expect(find.byKey(const ValueKey('update-dialog')), findsNothing);
    });
  });
}
