import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tove_chat/src/notify/notify.dart';
import 'package:tove_chat/src/ui/settings/notifications_section.dart';

import 'test_harness.dart';

/// Settings › Notifications with Tove's own notifications (round 5): no
/// other app is suggested; the switch, its live status, a test and battery
/// guidance are there.
void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  Future<(InstantNotifications, _Platform)> instantFor(
    Map<Object?, Object?> status,
  ) async {
    final p = _Platform(status);
    final i = InstantNotifications(platform: p, supported: true);
    await i.load();
    await i.configure(
      bridgeOffers: true,
      url: 'https://bridge.test',
      accessKey: 'k' * 30,
      systemEnabled: true,
    );
    return (i, p);
  }

  testWidgets('instant on: connected, test, battery guidance; no ntfy nag', (
    tester,
  ) async {
    final prefs = ReplyNotificationPrefs();
    await prefs.load();
    final (instant, platform) = await instantFor({
      'enabled': true,
      'status': 'connected',
      'batteryExempt': false,
      'notificationsAllowed': true,
    });
    var tests = 0;
    await tester.pumpWidget(
      themed(
        Scaffold(
          body: ListView(
            children: [
              NotificationsSection(
                prefs: prefs,
                instant: instant,
                testEvents: () async {
                  tests++;
                  return 1;
                },
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Instant notifications'), findsOneWidget);
    expect(
      find.textContaining('Keeps a small connection open'),
      findsOneWidget,
    );
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Allow in the background'), findsOneWidget);
    expect(find.text('Battery settings'), findsOneWidget);
    expect(find.textContaining('ntfy'), findsNothing);
    await tester.tap(find.text('Send a test notification'));
    await tester.pump();
    expect(tests, 1);
    expect(find.textContaining('Test sent'), findsOneWidget);
    await tester.tap(find.text('Allow in the background'));
    await tester.pump();
    expect(platform.calls, contains('requestBatteryExemption'));
    await tester.tap(find.text('Battery settings'));
    await tester.pump();
    expect(platform.calls, contains('openBatterySettings'));

    // Off: the slower check is explained and the service is stopped.
    await tester.tap(find.byKey(const ValueKey('settings-instant')));
    await tester.pump();
    expect(instant.enabled, isFalse);
    expect(find.textContaining('about every 15 minutes'), findsOneWidget);
    expect(find.text('Connected'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
    instant.dispose();
  });

  testWidgets('web: says notifications show only while the tab is open', (
    tester,
  ) async {
    final prefs = ReplyNotificationPrefs();
    await prefs.load();
    await tester.pumpWidget(
      themed(
        Scaffold(
          body: ListView(
            children: [
              NotificationsSection(
                prefs: prefs,
                web: true,
                testEvents: () async => 1,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.textContaining('only while this tab is open'), findsOneWidget);
    expect(find.text('Send a test notification'), findsOneWidget);
    expect(find.text('Instant notifications'), findsNothing);
  });
}

class _Platform implements InstantPlatform {
  _Platform(this.status);
  Map<Object?, Object?> status;
  final calls = <String>[];

  @override
  Future<Map<Object?, Object?>?> invoke(String method, [Object? args]) async {
    calls.add(method);
    if (method == 'configure') {
      final on = (args as Map)['enabled'] == true;
      return {
        ...status,
        'enabled': on,
        'status': on ? status['status'] : 'off',
      };
    }
    if (method == 'status') return status;
    return null;
  }

  @override
  void setHandler(Future<Object?> Function(MethodCall call)? handler) {}
}
