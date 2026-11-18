import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../background/background.dart';
import '../../brand.dart';
import '../../notify/notify.dart';
import '../common/group_card.dart';
import '../theme/tokens.dart';

/// Settings › Notifications: the "Reply notifications" switch, Tove's own
/// instant notifications (Android: a small connection held by the app, so no
/// other app is needed), a test, and UnifiedPush for people who already use a
/// distributor. The in-app banner always shows.
class NotificationsSection extends StatelessWidget {
  const NotificationsSection({
    super.key,
    required this.prefs,
    this.sink,
    this.push,
    this.instant,
    this.testEvents,
    this.web = false,
    this.showHeader = true,
    this.anchor,
  });

  /// Android's instant notifications; null elsewhere.
  final InstantNotifications? instant;

  /// `POST /api/events/test` (bridges with `events`); returns how many
  /// streams heard it. Null hides the test row.
  final Future<int> Function()? testEvents;

  /// The web app: notifications show only while the tab is open.
  final bool web;

  /// Wraps rows a settings search can point at (`testPush`).
  final Widget Function(String id, Widget child)? anchor;

  final ReplyNotificationPrefs prefs;
  final NotificationSink? sink;
  final PushRegistrar? push;

  /// False inside the Notifications page, whose title already says it.
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    const card = EdgeInsets.symmetric(horizontal: 16);
    final push = this.push;
    final instant = this.instant;
    return ListenableBuilder(
      listenable: Listenable.merge([prefs, ?push, ?instant]),
      builder: (context, _) {
        final rows = <Widget>[
          SwitchRow(
            label: 'Reply notifications',
            icon: Icons.notifications_outlined,
            subtitle:
                'Tell me when a reply finishes while I’m elsewhere. '
                'The banner inside the app always shows.',
            value: prefs.enabled,
            onChanged: (on) async {
              await prefs.setEnabled(on);
              if (on) await sink?.requestPermission();
            },
          ),
        ];
        final own =
            instant != null && instant.supported && instant.bridgeOffers;
        if (own && prefs.enabled) rows.addAll(_instant(context, instant, t));
        if (web && prefs.enabled) {
          rows.add(
            _note(
              t,
              'In the browser, notifications show only while this tab is '
              'open. Install the Android app for notifications when it is '
              'closed.',
            ),
          );
        }
        if (prefs.enabled && testEvents != null && (own || web)) {
          rows.add(
            (anchor ?? (_, c) => c)(
              'testNotification',
              GroupRow(
                key: const ValueKey('settings-test-events'),
                label: 'Send a test notification',
                icon: Icons.send_outlined,
                onTap: () => unawaited(_testEvents(context)),
              ),
            ),
          );
        }
        // UnifiedPush: still there for people with a distributor (ntfy); no
        // longer suggested when Tove's own notifications work here.
        final showPush =
            push != null &&
            !(own &&
                (push.state == PushState.needsDistributor ||
                    push.state == PushState.off ||
                    push.state == PushState.unsupported));
        if (showPush) rows.add(_status(push, t));
        if (showPush && prefs.enabled) rows.addAll(_push(context, push, t));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHeader)
              const SectionHeader('Notifications')
            else
              const SizedBox(height: 8),
            GroupCard(margin: card, children: rows),
          ],
        );
      },
    );
  }

  static Widget _note(HermesTokens t, String text, {Color? color}) => Semantics(
    container: true,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Text(
        text,
        style: t.label.copyWith(color: color ?? t.textMuted, height: 1.4),
      ),
    ),
  );

  List<Widget> _instant(
    BuildContext context,
    InstantNotifications instant,
    HermesTokens t,
  ) {
    final s = instant.status;
    return [
      SwitchRow(
        key: const ValueKey('settings-instant'),
        label: 'Instant notifications',
        icon: Icons.bolt_rounded,
        subtitle:
            'Keeps a small connection open, so notifications arrive in '
            'seconds with only ${Brand.appName} installed. Uses very little '
            'data (about 6 KB an hour).',
        value: instant.enabled,
        onChanged: (on) => unawaited(instant.setEnabled(on)),
      ),
      if (instant.enabled) _InstantStatusRow(instant: instant),
      if (!instant.enabled)
        _note(
          t,
          'Off: ${Brand.appName} checks your server about every 15 minutes '
          'instead, which Android can stretch while the phone sleeps.',
        ),
      if (instant.enabled && !s.notificationsAllowed) ...[
        _note(
          t,
          'Android is blocking ${Brand.appName}’s notifications.',
          color: t.warning,
        ),
        GroupRow(
          label: 'Allow notifications',
          icon: Icons.notifications_active_outlined,
          onTap: () async {
            final ok = await sink?.requestPermission() ?? false;
            if (!ok) await instant.openNotificationSettings();
            await instant.refreshStatus();
          },
        ),
      ],
      if (instant.enabled && s.running && !s.batteryExempt) ...[
        _note(
          t,
          'Battery optimisation can delay reconnecting while the phone '
          'sleeps. Letting ${Brand.appName} run in the background makes '
          'notifications reliable; the connection itself stays idle.',
        ),
        GroupRow(
          key: const ValueKey('settings-battery'),
          label: 'Allow in the background',
          icon: Icons.battery_saver_outlined,
          onTap: () => unawaited(instant.requestBatteryExemption()),
        ),
        GroupRow(
          key: const ValueKey('settings-battery-list'),
          label: 'Battery settings',
          icon: Icons.tune_rounded,
          onTap: () => unawaited(instant.openBatterySettings()),
        ),
      ],
    ];
  }

  Future<void> _testEvents(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    String text;
    try {
      final readers = await testEvents!();
      text = readers > 0
          ? 'Test sent. It should appear in a second.'
          : 'Sent, but no connection is open yet. Try again in a moment.';
    } catch (_) {
      text = 'The test couldn’t be sent.';
    }
    messenger?.showSnackBar(SnackBar(content: Text(text)));
  }

  /// How notifications reach this device when the app is closed.
  Widget _status(PushRegistrar push, HermesTokens t) {
    final (value, color) = switch (push.state) {
      PushState.unsupported => ('Not on this device', null),
      PushState.off => (
        prefs.enabled ? 'Not offered by the server' : 'Off',
        null,
      ),
      PushState.needsDistributor => ('Needs ntfy', t.warning),
      PushState.choosing => ('Choose an app', t.warning),
      PushState.registering => ('Connecting…', null),
      PushState.active => ('On (UnifiedPush)', t.success),
      PushState.failed => ('Not working', t.danger),
    };
    return GroupRow(
      key: const ValueKey('settings-push-status'),
      label: 'UnifiedPush',
      icon: Icons.cell_tower_rounded,
      value: value,
      trailing: color == null
          ? null
          : Icon(Icons.circle, size: 10, color: color),
    );
  }

  Future<void> _test(BuildContext context, PushRegistrar push) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    bool ok;
    try {
      ok = await push.sendTest();
    } catch (_) {
      ok = false;
    }
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Test notification sent.'
              : 'The test notification couldn’t be delivered.',
        ),
      ),
    );
  }

  List<Widget> _push(BuildContext context, PushRegistrar push, HermesTokens t) {
    Widget note(String text, {Color? color}) => Semantics(
      container: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Text(
          text,
          style: t.label.copyWith(color: color ?? t.textMuted, height: 1.4),
        ),
      ),
    );
    final previews = push.previews
        ? null
        : note(
            'The server keeps message text out of notifications, so they '
            'show only that a reply is ready.',
          );
    switch (push.state) {
      case PushState.unsupported:
      case PushState.off:
        return [?previews];
      case PushState.needsDistributor:
        return [
          note(
            'Optional: a UnifiedPush app such as ntfy can deliver '
            'notifications too. Without one the app checks every 15 '
            'minutes, which is much slower.',
          ),
          GroupRow(
            label: 'Get ntfy from F-Droid',
            icon: Icons.open_in_new_rounded,
            onTap: () => _open(PushRegistrar.ntfyFdroid),
          ),
          GroupRow(
            label: 'Get ntfy from Google Play',
            icon: Icons.open_in_new_rounded,
            onTap: () => _open(PushRegistrar.ntfyPlay),
          ),
          ?previews,
        ];
      case PushState.choosing:
        return [
          note('Choose the app that delivers notifications:'),
          for (final d in push.distributors)
            GroupRow(
              label: d,
              icon: Icons.inbox_outlined,
              onTap: () => unawaited(push.chooseDistributor(d)),
            ),
        ];
      case PushState.registering:
        return [note('Connecting notifications…')];
      case PushState.active:
        return [
          (anchor ?? (_, c) => c)(
            'testPush',
            GroupRow(
              key: const ValueKey('settings-test-push'),
              label: 'Send a test notification',
              icon: Icons.send_outlined,
              onTap: () => unawaited(_test(context, push)),
            ),
          ),
          ?previews,
        ];
      case PushState.failed:
        return [
          note(
            push.problem ?? 'Notifications could not be set up.',
            color: t.danger,
          ),
        ];
    }
  }

  static Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }
}

/// The connection's state, re-read every few seconds while shown.
class _InstantStatusRow extends StatefulWidget {
  const _InstantStatusRow({required this.instant});
  final InstantNotifications instant;

  @override
  State<_InstantStatusRow> createState() => _InstantStatusRowState();
}

class _InstantStatusRowState extends State<_InstantStatusRow> {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(widget.instant.refreshStatus());
    _poll = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(widget.instant.refreshStatus()),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final s = widget.instant.status;
    final (value, color) = switch (s.state) {
      InstantState.connected => ('Connected', t.success),
      InstantState.connecting => ('Connecting…', null),
      InstantState.reconnecting => ('Reconnecting…', t.warning),
      InstantState.waitingNetwork => ('Waiting for a network', t.warning),
      InstantState.unauthorized => ('The server refused the key', t.danger),
      InstantState.blocked => ('Starts when you open the app', t.warning),
      InstantState.unsupported => ('Not offered by the server', null),
      InstantState.off => ('Off', null),
    };
    return GroupRow(
      key: const ValueKey('settings-instant-status'),
      label: 'Connection',
      icon: Icons.cell_tower_rounded,
      value: value,
      trailing: color == null
          ? null
          : Icon(Icons.circle, size: 10, color: color),
    );
  }
}
