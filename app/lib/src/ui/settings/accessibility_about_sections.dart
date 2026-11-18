import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../app.dart' show kAppVersion;
import '../../brand.dart';
import '../../platform/device.dart';
import '../../settings/settings.dart';
import '../common/brand_mark.dart';
import '../common/group_card.dart';
import '../markdown/hermes_markdown.dart';
import '../theme/tokens.dart';
import '../../update/update_ui.dart';
import 'general_section.dart' show TextSizeRow;
import 'settings_widgets.dart';

/// Settings › Accessibility: all per device, since needs differ between a
/// phone and a desktop.
List<Widget> accessibilitySection(
  BuildContext context, {
  required SettingsController settings,
}) => [
  const SectionHeader('Motion'),
  SettingAnchor(
    id: 'motion',
    child: GroupCard(
      margin: settingsCard,
      children: [
        SwitchRow(
          label: 'Reduce motion',
          icon: Icons.animation_rounded,
          subtitle: 'Keep the orb still. Also follows the system.',
          value: settings.reduceMotion,
          onChanged: settings.setReduceMotion,
        ),
      ],
    ),
  ),
  const SectionHeader('Display'),
  SettingAnchor(
    id: 'refreshRate',
    child: GroupCard(
      margin: settingsCard,
      children: [
        GroupRow(
          label: 'Refresh rate',
          icon: Icons.speed_rounded,
          value: settings.refreshRate.label,
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => ChoicePage.open<RefreshMode>(
            context,
            title: 'Refresh rate',
            listenable: settings,
            options: [
              for (final m in RefreshMode.values) (m, m.label, m.detail),
            ],
            selected: () => settings.refreshRate,
            onSelected: settings.setRefreshRate,
            note: const DeviceOnlyNote(
              text:
                  'On this device only. Battery saver and the system’s '
                  'own refresh setting can lower it.',
            ),
          ),
        ),
      ],
    ),
  ),
  const SectionHeader('Vision'),
  GroupCard(
    margin: settingsCard,
    children: [
      SettingAnchor(
        id: 'largerText',
        child: TextSizeRow(settings: settings),
      ),
      SettingAnchor(
        id: 'contrast',
        child: SwitchRow(
          label: 'Increase contrast',
          icon: Icons.contrast_rounded,
          subtitle: 'Darker secondary text and stronger dividers.',
          value: settings.highContrast,
          onChanged: settings.setHighContrast,
        ),
      ),
    ],
  ),
  const DeviceOnlyNote(),
];

/// Settings › About.
/// "1.0.0+7" → ("1.0.0", "7"); no build part gives null.
(String, String?) appVersionParts(String v) {
  final parts = v.split('+');
  return (
    parts.first,
    parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null,
  );
}

/// The one-line mission under the name.
const aboutMission = 'A private AI assistant that lives on your own server.';

List<Widget> aboutSection(
  BuildContext context, {
  DeviceServices? device,
  bool? showShortcuts,
}) {
  final (version, build) = appVersionParts(kAppVersion);
  return [
    const SizedBox(height: 24),
    _AboutHero(version: version, buildNumber: build),
    const SizedBox(height: 24),
    GroupCard(
      margin: settingsCard,
      children: [
        SettingAnchor(
          id: 'shortcuts',
          child: SettingAnchor(
            id: 'about',
            child: _AboutText(device: device, showShortcuts: showShortcuts),
          ),
        ),
      ],
    ),
    ...updateRows(context),
    const SectionHeader('Made by'),
    const GroupCard(margin: settingsCard, children: [_MadeBy()]),
    const SectionHeader('Legal'),
    GroupCard(
      margin: settingsCard,
      children: [
        SettingAnchor(
          id: 'licences',
          child: GroupRow(
            label: 'Licences',
            icon: Icons.description_outlined,
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => showLicensePage(
              context: context,
              applicationName: Brand.appName,
              applicationVersion: build == null
                  ? version
                  : '$version (build $build)',
              applicationLegalese: aboutMission,
              applicationIcon: const Padding(
                padding: EdgeInsets.all(12),
                child: _AppIcon(size: 64),
              ),
            ),
          ),
        ),
        GroupRow(
          key: const ValueKey('about-privacy-policy'),
          label: 'Privacy policy',
          icon: Icons.privacy_tip_outlined,
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const PrivacyPolicyPage()),
          ),
        ),
      ],
    ),
    const SectionHeader('Privacy'),
    const SettingAnchor(
      id: 'privacy',
      child: GroupCard(margin: settingsCard, children: [_PrivacyText()]),
    ),
  ];
}

/// The app icon (the brand PNG), rounded like a launcher icon.
class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.23),
      child: Image.asset(
        'assets/brand/tove-icon-256.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => BrandMark(size: size),
      ),
    ),
  );
}

/// Icon, name, version and build, and the mission line.
class _AboutHero extends StatelessWidget {
  const _AboutHero({required this.version, this.buildNumber});
  final String version;
  final String? buildNumber;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final b = buildNumber;
    return Semantics(
      container: true,
      label:
          '${Brand.appName}, version $version'
          '${b == null ? '' : ', build $b'}. $aboutMission',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          children: [
            const _AppIcon(size: 88),
            const SizedBox(height: 16),
            Text(Brand.appName, style: t.display),
            const SizedBox(height: 4),
            Text(
              b == null ? 'Version $version' : 'Version $version · Build $b',
              key: const ValueKey('about-version'),
              style: t.label,
            ),
            const SizedBox(height: 14),
            Text(
              aboutMission,
              key: const ValueKey('about-mission'),
              textAlign: TextAlign.center,
              style: t.row.copyWith(height: 1.4).hermesWeight(400),
            ),
          ],
        ),
      ),
    );
  }
}

/// Who builds the app: an independent open-source project.
class _MadeBy extends StatelessWidget {
  const _MadeBy();

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Semantics(
      container: true,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ExcludeSemantics(
                  child: CircleAvatar(
                    radius: 22,
                    backgroundColor: t.accentSoft,
                    child: Text(
                      Brand.appName[0],
                      style: t.row.copyWith(color: t.onAccentSoft),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${Brand.appName} contributors', style: t.row),
                      Text('Independent project', style: t.label),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '${Brand.appName} is a personal AI assistant app for your own '
              'self-hosted Hermes Agent. It is built and maintained as an '
              'independent project, with privacy and self-hosting first.',
              key: const ValueKey('about-made-by'),
              style: t.row
                  .copyWith(color: t.textMuted, height: 1.45)
                  .hermesWeight(400),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shortcuts shown in About on desktop and with a keyboard.
const settingsShortcutsText =
    'Shortcuts: M mutes, Esc closes or ends live voice, Ctrl+K searches '
    'chats, Ctrl+Shift+O starts a new chat, Ctrl+Shift+L toggles live voice.';

class _PrivacyText extends StatelessWidget {
  const _PrivacyText();

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Semantics(
      container: true,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Your chats, settings, uploads and reports are stored on the '
          '${Brand.serverName} you connect to, not by ${Brand.appName}\u2019s '
          'developer, who collects nothing. The app has no ads, no analytics '
          'and no tracking. Your server may send your requests to the AI services it '
          'uses. Live voice audio goes from this device to the voice service '
          'your server sets up. Notifications come from your server, or '
          'through a push app you choose (such as ntfy).',
          style: t.row
              .copyWith(color: t.textMuted, height: 1.45)
              .hermesWeight(400),
        ),
      ),
    );
  }
}

/// The About text, in its own semantics node (not merged with Licences).
/// The keyboard shortcuts are listed in desktop apps, on the web from the
/// wide layout, and on phones and tablets only with a physical keyboard.
class _AboutText extends StatefulWidget {
  const _AboutText({this.device, this.showShortcuts});

  final DeviceServices? device;
  final bool? showShortcuts;

  @override
  State<_AboutText> createState() => _AboutTextState();
}

class _AboutTextState extends State<_AboutText> {
  bool _keyboard = false;

  @override
  void initState() {
    super.initState();
    final device = widget.device;
    if (widget.showShortcuts == null && device != null) {
      device.hardwareKeyboard().then((k) {
        if (mounted && k == true) setState(() => _keyboard = true);
      });
    }
  }

  bool _shown(BuildContext context) {
    final forced = widget.showShortcuts;
    if (forced != null) return forced;
    if (kIsWeb) return MediaQuery.sizeOf(context).width >= Sz.wideLayout;
    return switch (defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      _ => _keyboard,
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final shortcuts = _shown(context);
    return Semantics(
      container: true,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Text replies come from Hermes Agent through the ${Brand.serverName}. '
          'Live voice runs GPT-Live directly between this device and the '
          'voice service over WebRTC; the server only exchanges connection '
          'details and runs the tasks you ask for, up to two at a time. One '
          'live session at a time.'
          '${shortcuts ? '\n\n$settingsShortcutsText' : ''}',
          style: t.row
              .copyWith(color: t.textMuted, height: 1.45)
              .hermesWeight(400),
        ),
      ),
    );
  }
}

/// The privacy policy, bundled with the app (assets/legal/privacy-policy.md).
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key, this.load});

  static const asset = 'assets/legal/privacy-policy.md';

  /// For tests; defaults to the bundled asset.
  final Future<String> Function()? load;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy policy')),
      body: FutureBuilder<String>(
        future:
            (load ?? () => DefaultAssetBundle.of(context).loadString(asset))(),
        builder: (context, snap) {
          final text = snap.data;
          if (text == null) {
            return snap.hasError
                ? Center(
                    child: Text(
                      'The privacy policy couldn\u2019t be loaded.',
                      style: t.row,
                    ),
                  )
                : const SizedBox.shrink();
          }
          return SafeArea(
            top: false,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [HermesMarkdown(text: text, selectable: true)],
            ),
          );
        },
      ),
    );
  }
}
