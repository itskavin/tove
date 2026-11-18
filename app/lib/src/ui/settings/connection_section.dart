import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../brand.dart';
import '../../call/call_controller.dart';
import '../../chat/chat.dart';
import '../../settings/settings.dart';
import '../../sync/settings_sync.dart';
import '../common/group_card.dart';
import '../onboarding_screen.dart';
import '../theme/tokens.dart';
import 'settings_widgets.dart';
import 'voice_section.dart' show LiveBackendInfo;

/// Opens a link outside the app; false when nothing could open it.
typedef OpenLink = Future<bool> Function(Uri url);

Future<bool> openExternal(Uri url) async {
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// The features a bridge reports, in plain words, for "Server version and
/// features".
List<(String, bool)> bridgeFeatures(Capabilities c) {
  bool f(String k) => c.raw[k] == true;
  return [
    ('Text chat', c.chat),
    ('Chat history and search', c.history && c.search),
    ('Reply effort', c.effort),
    ('Attachments', c.attachments),
    ('Images to Hermes', c.vision),
    ('Web search', c.webSearch),
    ('Rich replies (cards, tables)', f('ui_blocks')),
    ('Link previews', f('link_preview')),
    ('Resumable replies', c.resumableStream),
    ('Live voice linked to chats', c.liveLink),
    ('Push notifications', c.unifiedPush),
    ('Synced settings', f('settings_sync')),
    ('Token usage per reply', f('usage')),
    ('Starter suggestions', f('suggestions')),
  ];
}

/// Settings › Connection: the server, its state and features, sync, usage,
/// the access key, and setting Tove up for someone else.
List<Widget> connectionSection(
  BuildContext context, {
  required SettingsController settings,
  required CallController call,
  Capabilities? capabilities,
  OpenLink openLink = openExternal,
}) {
  final caps = capabilities;
  final backend = caps == null
      ? null
      : LiveBackendInfo.fromCapabilities(caps.raw);
  final (status, statusColor) = switch (caps) {
    null => ('Not checked yet', null),
    Capabilities(known: false) => (
      'Can’t reach the server',
      HermesTokens.of(context).danger,
    ),
    Capabilities(version: 1) => (
      'Connected (live voice only)',
      HermesTokens.of(context).warning,
    ),
    Capabilities(chat: false) => (
      'Connected (sending is off)',
      HermesTokens.of(context).warning,
    ),
    _ => ('Connected', HermesTokens.of(context).success),
  };
  final usage = caps?.raw['usage'] == true;
  final budget = backend?.budget;
  return [
    const SectionHeader('Server'),
    GroupCard(
      margin: settingsCard,
      children: [
        SettingAnchor(
          id: 'server',
          child: GroupRow(
            label: 'Server',
            icon: Icons.dns_outlined,
            subtitle: settings.url,
          ),
        ),
        SettingAnchor(
          id: 'status',
          child: GroupRow(
            key: const ValueKey('settings-connection-status'),
            label: 'Status',
            icon: Icons.wifi_tethering_rounded,
            value: status,
            trailing: statusColor == null
                ? null
                : Icon(Icons.circle, size: 10, color: statusColor),
          ),
        ),
        if (caps != null && caps.known)
          SettingAnchor(
            id: 'bridge',
            child: GroupRow(
              key: const ValueKey('settings-bridge'),
              label: 'Server version and features',
              icon: Icons.memory_rounded,
              value: 'API ${caps.version}',
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _FeaturesPage(capabilities: caps),
                ),
              ),
            ),
          ),
        SettingAnchor(
          id: 'sync',
          child: ListenableBuilder(
            listenable: settings.sync,
            builder: (context, _) => GroupRow(
              key: const ValueKey('settings-sync-row'),
              label: 'Settings sync',
              icon: Icons.sync_rounded,
              value: syncStatusShort(settings.sync),
              subtitle:
                  settings.sync.state == SyncState.synced &&
                      settings.sync.lastSynced != null
                  ? null
                  : syncStatusText(settings.sync),
              onTap: settings.sync.state == SyncState.localOnly
                  ? null
                  : () => unawaited(settings.sync.refresh()),
            ),
          ),
        ),
      ],
    ),
    if (usage || budget != null) ...[
      const SectionHeader('Usage'),
      SettingAnchor(
        id: 'usage',
        child: GroupCard(
          margin: settingsCard,
          children: [
            if (budget != null)
              GroupRow(
                key: const ValueKey('settings-usage-voice'),
                label: 'Live voice today',
                icon: Icons.timer_outlined,
                value: budget,
              ),
            if (usage)
              const GroupRow(
                key: ValueKey('settings-usage-replies'),
                label: 'Tokens per reply',
                icon: Icons.data_usage_rounded,
                subtitle:
                    'Open a reply’s ⋮ menu and choose Details to see its '
                    'model, tokens and time.',
              ),
          ],
        ),
      ),
    ],
    const SectionHeader('Access key'),
    GroupCard(
      margin: settingsCard,
      children: [
        // The key itself is never shown, only whether one is saved.
        SettingAnchor(
          id: 'key',
          child: GroupRow(
            label: 'Access key',
            icon: Icons.key_outlined,
            value: settings.hasKey ? 'Saved on this device' : 'Not set',
          ),
        ),
        GroupRow(
          label: 'Change server or access key',
          icon: Icons.edit_outlined,
          subtitle: call.inCall
              ? 'End live voice to change the connection'
              : null,
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: call.inCall
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        OnboardingScreen(settings: settings, editing: true),
                  ),
                ),
        ),
      ],
    ),
    const SettingsNote(
      'The key stays in this device’s secure storage. It is never shown or '
      'sent anywhere except to your server.',
    ),
    const SizedBox(height: 16),
    SettingAnchor(
      id: 'forgetKey',
      child: GroupCard(
        margin: settingsCard,
        children: [
          GroupRow(
            label: 'Forget access key',
            icon: Icons.logout_rounded,
            danger: true,
            onTap: () => _forget(context, settings, call),
          ),
        ],
      ),
    ),
    const SectionHeader('Share'),
    SettingAnchor(
      id: 'selfHost',
      child: GroupCard(
        margin: settingsCard,
        children: [
          GroupRow(
            key: const ValueKey('settings-self-host'),
            label: 'Set up ${Brand.appName} for someone else',
            icon: Icons.group_add_outlined,
            subtitle:
                'Each person needs their own ${Brand.serverName} and Hermes '
                'Agent, set up the same way as yours. Then they install '
                '${Brand.appName} and connect to it.',
          ),
        ],
      ),
    ),
  ];
}

Future<void> _forget(
  BuildContext context,
  SettingsController settings,
  CallController call,
) async {
  final t = HermesTokens.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Forget the access key?'),
      content: Text(
        'This device will need the key again before it can reach '
        '${Brand.assistantName}.'
        '${call.inCall ? ' Live voice will end.' : ''}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: t.danger),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Forget'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  await call.end();
  await settings.forgetKey();
  if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
}

class _FeaturesPage extends StatelessWidget {
  const _FeaturesPage({required this.capabilities});
  final Capabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final backend = LiveBackendInfo.fromCapabilities(capabilities.raw);
    return SettingsSubPage(
      title: 'Server features',
      children: [
        GroupCard(
          margin: settingsCard,
          children: [
            GroupRow(
              label: 'API version',
              icon: Icons.tag_rounded,
              value: '${capabilities.version}',
            ),
            if (backend != null)
              GroupRow(
                label: 'Voice service',
                icon: Icons.cloud_outlined,
                subtitle: backend.title,
              ),
          ],
        ),
        const SectionHeader('Features'),
        GroupCard(
          margin: settingsCard,
          children: [
            for (final (label, on) in bridgeFeatures(capabilities))
              Semantics(
                label: '$label: ${on ? 'available' : 'not available'}',
                excludeSemantics: true,
                child: GroupRow(
                  label: label,
                  trailing: Icon(
                    on
                        ? Icons.check_circle_rounded
                        : Icons.remove_circle_outline,
                    size: 20,
                    color: on ? t.success : t.textFaint,
                  ),
                ),
              ),
          ],
        ),
        const SettingsNote(
          'Features the server doesn’t offer are hidden in the app. Updating '
          'the server turns them on.',
        ),
      ],
    );
  }
}
