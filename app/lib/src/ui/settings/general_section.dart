import 'package:material_ui/material_ui.dart';

import '../../settings/settings.dart';
import '../common/group_card.dart';
import '../theme/tokens.dart';
import 'settings_widgets.dart';

/// Settings › General: appearance, chat behaviour, sounds and haptics.
List<Widget> generalSection(
  BuildContext context, {
  required SettingsController settings,
  required bool effortSupported,
  required bool sendWithEnter,
}) => [
  const SectionHeader('Appearance'),
  SettingAnchor(
    id: 'theme',
    child: GroupCard(
      margin: settingsCard,
      children: [
        for (final (v, label, icon) in const [
          (AppTheme.dark, 'Dark', Icons.dark_mode_outlined),
          (AppTheme.light, 'Light', Icons.light_mode_outlined),
          (AppTheme.system, 'System', Icons.brightness_auto_outlined),
        ])
          GroupRow(
            label: label,
            icon: icon,
            selected: settings.theme == v,
            onTap: () => settings.setTheme(v),
          ),
      ],
    ),
  ),
  const SizedBox(height: 12),
  GroupCard(
    margin: settingsCard,
    children: [
      SettingAnchor(
        id: 'accent',
        child: AccentRow(value: settings.accent, onChanged: settings.setAccent),
      ),
      SettingAnchor(
        id: 'textSize',
        child: TextSizeRow(settings: settings),
      ),
    ],
  ),
  const SectionHeader('Chats'),
  GroupCard(
    margin: settingsCard,
    children: [
      if (effortSupported)
        SettingAnchor(
          id: 'effort',
          child: GroupRow(
            label: 'Reply effort',
            icon: Icons.speed_rounded,
            value: settings.effort.label,
            subtitle: 'How long Hermes thinks before a typed reply.',
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => ChoicePage.open<ReplyEffort>(
              context,
              title: 'Reply effort',
              listenable: settings,
              options: const [
                (ReplyEffort.instant, 'Instant', 'Answers at once.'),
                (ReplyEffort.medium, 'Medium', 'Thinks briefly first.'),
                (ReplyEffort.high, 'High', 'Takes longer on hard questions.'),
              ],
              selected: () => settings.effort,
              onSelected: settings.setEffort,
              note: const SettingsNote(
                'The default for new messages. The slider in the composer '
                'changes it too.',
              ),
            ),
          ),
        ),
      SettingAnchor(
        id: 'suggestions',
        child: SwitchRow(
          label: 'Show suggestions',
          icon: Icons.lightbulb_outline_rounded,
          subtitle: 'Starter ideas on a new chat.',
          value: settings.showSuggestions,
          onChanged: settings.setShowSuggestions,
        ),
      ),
      if (sendWithEnter)
        SettingAnchor(
          id: 'sendWithEnter',
          child: SwitchRow(
            label: 'Send with Enter',
            icon: Icons.keyboard_return_rounded,
            subtitle: settings.sendWithEnter
                ? 'Shift+Enter adds a line.'
                : 'Enter adds a line; use the Send button.',
            value: settings.sendWithEnter,
            onChanged: settings.setSendWithEnter,
          ),
        ),
    ],
  ),
  if (settings.locationSupported) ...[
    const SectionHeader('Local answers'),
    GroupCard(
      margin: settingsCard,
      children: [
        SettingAnchor(
          id: 'location',
          child: SwitchRow(
            label: 'Use my approximate location',
            icon: Icons.near_me_outlined,
            subtitle:
                'For "near me" answers, each message carries your area, '
                'rounded to about 1 km. Off by default.',
            value: settings.locationAnswers,
            onChanged: (on) async {
              final ok = await settings.requestLocationAnswers(on);
              if (!ok && context.mounted) {
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Location is off or not allowed for Tove. Turn it on in '
                      'Android settings, then try again.',
                    ),
                  ),
                );
              }
            },
          ),
        ),
      ],
    ),
  ],
  const SectionHeader('Sounds and haptics'),
  GroupCard(
    margin: settingsCard,
    children: [
      SettingAnchor(
        id: 'sounds',
        child: SwitchRow(
          label: 'Sounds',
          icon: Icons.volume_up_outlined,
          subtitle: 'Short tones when live voice connects and ends.',
          value: settings.sounds,
          onChanged: settings.setSounds,
        ),
      ),
      SettingAnchor(
        id: 'haptics',
        child: SwitchRow(
          label: 'Haptics',
          icon: Icons.vibration_rounded,
          subtitle: 'Gentle vibrations for taps, sends and live voice.',
          value: settings.haptics,
          onChanged: settings.setHaptics,
        ),
      ),
    ],
  ),
  const DeviceOnlyNote(),
];

/// The accent colour swatches.
class AccentRow extends StatelessWidget {
  const AccentRow({super.key, required this.value, required this.onChanged});

  final AccentColour value;
  final ValueChanged<AccentColour> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final brightness = Theme.of(context).brightness;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.palette_outlined, size: 22, color: t.text),
              const SizedBox(width: 14),
              Expanded(child: Text('Accent colour', style: t.row)),
              Text(value.label, style: t.row.copyWith(color: t.textMuted)),
            ],
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(left: 36),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final a in AccentColour.values)
                  Semantics(
                    button: true,
                    selected: a == value,
                    label: '${a.label} accent',
                    excludeSemantics: true,
                    child: InkResponse(
                      key: ValueKey('accent-${a.name}'),
                      radius: 24,
                      onTap: () => onChanged(a),
                      child: SizedBox.square(
                        dimension: 44,
                        child: Center(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: a.forBrightness(brightness),
                              border: Border.all(
                                color: a == value ? t.text : Colors.transparent,
                                width: 2.5,
                                strokeAlign: BorderSide.strokeAlignOutside,
                              ),
                            ),
                            child: a == value
                                ? const Icon(
                                    Icons.check_rounded,
                                    size: 18,
                                    color: Colors.white,
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Text size" with its value; opens the choices.
class TextSizeRow extends StatelessWidget {
  const TextSizeRow({super.key, required this.settings, this.label});

  final SettingsController settings;
  final String? label;

  @override
  Widget build(BuildContext context) => GroupRow(
    label: label ?? 'Text size',
    icon: Icons.format_size_rounded,
    value: settings.textSize.label,
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: () => ChoicePage.open<TextSize>(
      context,
      title: label ?? 'Text size',
      listenable: settings,
      options: [
        for (final s in TextSize.values)
          (
            s,
            s.label,
            s == TextSize.standard ? 'Follows the system size' : null,
          ),
      ],
      selected: () => settings.textSize,
      onSelected: settings.setTextSize,
      note: const DeviceOnlyNote(
        text: 'On this device only, on top of the system text size.',
      ),
    ),
  );
}
