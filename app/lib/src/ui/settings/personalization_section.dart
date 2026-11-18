import 'package:material_ui/material_ui.dart';

import '../../brand.dart';
import '../../settings/settings.dart';
import '../common/group_card.dart';
import '../theme/tokens.dart';
import 'settings_widgets.dart';

String _preview(String s) {
  final line = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return line.length <= 80 ? line : '${line.substring(0, 79)}…';
}

/// Settings › Personalization: what Hermes should know and how it should
/// answer. The bridge adds these to every chat (bridge API "What reaches
/// Hermes"), so this category exists only when the server syncs settings.
List<Widget> personalizationSection(
  BuildContext context, {
  required SettingsController settings,
}) {
  final limit = settings.textLimit;
  const name = Brand.assistantName;
  return [
    const SectionHeader('Custom instructions'),
    GroupCard(
      margin: settingsCard,
      children: [
        SettingAnchor(
          id: 'aboutYou',
          child: GroupRow(
            key: const ValueKey('settings-about-you'),
            label: 'What $name should know about you',
            icon: Icons.badge_outlined,
            subtitle: settings.aboutYou.isEmpty
                ? 'Not set'
                : _preview(settings.aboutYou),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => TextSettingPage.open(
              context,
              title: 'About you',
              initial: settings.aboutYou,
              onSave: settings.setAboutYou,
              maxLength: limit,
              fieldKey: const ValueKey('settings-about-you-field'),
              hint:
                  'Where you live, what you work on, your interests, '
                  'the tools you use…',
              help:
                  '$name reads this at the start of every chat. It is kept '
                  'on your server.',
            ),
          ),
        ),
        SettingAnchor(
          id: 'customInstructions',
          child: GroupRow(
            key: const ValueKey('settings-instructions'),
            label: 'How $name should respond',
            icon: Icons.tune_rounded,
            subtitle: settings.customInstructions.isEmpty
                ? 'Not set'
                : _preview(settings.customInstructions),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => TextSettingPage.open(
              context,
              title: 'How to respond',
              initial: settings.customInstructions,
              onSave: settings.setCustomInstructions,
              maxLength: limit,
              fieldKey: const ValueKey('settings-instructions-field'),
              hint:
                  'Formal or casual, how long, whether to ask questions, '
                  'units, languages…',
              help: 'Applies to every new message, in every chat.',
            ),
          ),
        ),
      ],
    ),
    const SectionHeader('About you'),
    GroupCard(
      margin: settingsCard,
      children: [
        SettingAnchor(
          id: 'nickname',
          child: GroupRow(
            key: const ValueKey('settings-nickname'),
            label: 'Nickname',
            icon: Icons.person_outline_rounded,
            value: settings.nickname.isEmpty ? 'Not set' : settings.nickname,
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => TextSettingPage.open(
              context,
              title: 'Nickname',
              initial: settings.nickname,
              onSave: settings.setNickname,
              maxLength: 60,
              multiline: false,
              fieldKey: const ValueKey('settings-nickname-field'),
              hint: 'What should $name call you?',
            ),
          ),
        ),
        SettingAnchor(
          id: 'occupation',
          child: GroupRow(
            key: const ValueKey('settings-occupation'),
            label: 'Occupation',
            icon: Icons.work_outline_rounded,
            value: settings.occupation.isEmpty
                ? 'Not set'
                : settings.occupation,
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => TextSettingPage.open(
              context,
              title: 'Occupation',
              initial: settings.occupation,
              onSave: settings.setOccupation,
              maxLength: 100,
              multiline: false,
              fieldKey: const ValueKey('settings-occupation-field'),
              hint: 'Student, nurse, developer…',
            ),
          ),
        ),
      ],
    ),
    const SectionHeader('Tone'),
    SettingAnchor(
      id: 'style',
      child: GroupCard(
        margin: settingsCard,
        children: [
          for (final s in ReplyStyle.values)
            GroupRow(
              key: ValueKey('settings-style-${s.wire}'),
              label: s.label,
              subtitle: s.description,
              selected: settings.style == s,
              onTap: () => settings.setStyle(s),
            ),
        ],
      ),
    ),
    SyncedNote(
      sync: settings.sync,
      text:
          'Saved on your server. $name gets '
          'them with every message.',
    ),
    const SizedBox(height: 16),
    SettingAnchor(
      id: 'resetPersonalization',
      child: GroupCard(
        margin: settingsCard,
        children: [
          GroupRow(
            label: 'Reset personalization',
            icon: Icons.restart_alt_rounded,
            danger: true,
            onTap: settings.personalized
                ? () => _reset(context, settings)
                : null,
          ),
        ],
      ),
    ),
  ];
}

Future<void> _reset(BuildContext context, SettingsController settings) async {
  final t = HermesTokens.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Reset personalization?'),
      content: const Text(
        'This clears your instructions, nickname, occupation and tone on '
        'every device.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: t.danger),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Reset'),
        ),
      ],
    ),
  );
  if (ok == true) await settings.resetPersonalization();
}
