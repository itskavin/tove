import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../call/call_controller.dart';
import '../../platform/app_links.dart';
import '../../settings/settings.dart';
import '../../speech/speech.dart';
import '../common/group_card.dart';
import '../live/live_settings_sheet.dart';
import 'default_assistant_row.dart';
import 'settings_widgets.dart';
import 'speech_settings_page.dart';

/// What the bridge says about its GPT-Live backend (capabilities
/// `live_backend` / `live_backends`), for the read-only "Voice service" row.
class LiveBackendInfo {
  const LiveBackendInfo({
    required this.id,
    this.minutesLeftToday,
    this.dailyMinutes,
    this.maxCallMinutes,
  });

  /// From the capabilities object; null when the bridge does not say.
  static LiveBackendInfo? fromCapabilities(Map<String, dynamic> raw) {
    final id = raw['live_backend'];
    if (id is! String || id.isEmpty) return null;
    final all = raw['live_backends'];
    final mine = all is Map ? all[id] : null;
    num? n(String k) => mine is Map && mine[k] is num ? mine[k] as num : null;
    final maxS = n('max_call_s');
    return LiveBackendInfo(
      id: id,
      minutesLeftToday: n('minutes_left_today')?.toDouble(),
      dailyMinutes: n('daily_minutes')?.toInt(),
      maxCallMinutes: maxS == null ? null : (maxS / 60).round(),
    );
  }

  final String id;
  final double? minutesLeftToday;
  final int? dailyMinutes;
  final int? maxCallMinutes;

  String get title => switch (id) {
    'codex' => 'GPT-Live with the server’s ChatGPT login',
    'openai' => 'OpenAI Live API (the server’s API key)',
    _ => id,
  };

  /// "42 of 60 minutes left today", for budgeted backends.
  String? get budget {
    final left = minutesLeftToday, daily = dailyMinutes;
    if (left == null || daily == null) return null;
    return '${left.floor()} of $daily minutes left today';
  }
}

/// The 17 dictation languages offered besides the device language. The
/// system recogniser decides which it supports; Moonshine is English only.
const dictationLanguages = <(String, String)>[
  ('en-US', 'English (US)'),
  ('en-GB', 'English (UK)'),
  ('en-IN', 'English (India)'),
  ('es-ES', 'Español'),
  ('fr-FR', 'Français'),
  ('de-DE', 'Deutsch'),
  ('it-IT', 'Italiano'),
  ('pt-BR', 'Português (Brasil)'),
  ('nl-NL', 'Nederlands'),
  ('sv-SE', 'Svenska'),
  ('hi-IN', 'हिन्दी'),
  ('ta-IN', 'தமிழ்'),
  ('ja-JP', '日本語'),
  ('ko-KR', '한국어'),
  ('zh-CN', '中文 (简体)'),
  ('ar-SA', 'العربية'),
  ('ru-RU', 'Русский'),
];

String dictationLanguageLabel(String? tag) => tag == null
    ? 'Automatic'
    : dictationLanguages.where((l) => l.$1 == tag).firstOrNull?.$2 ?? tag;

/// What keeps live voice going when the app leaves the screen.
String _backgroundText(CallController call) {
  final note = call.backgroundNote;
  if (note != null) return note;
  if (kIsWeb) return 'Keep this tab open while live voice is on.';
  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS =>
      'Live voice keeps going when you switch apps or the screen turns '
          'off. The call notification can mute or end it.',
    _ => 'Live voice keeps going while this window is open.',
  };
}

/// Settings › Voice: the live voice and its service, read aloud, dictation
/// and their downloads.
List<Widget> voiceSection(
  BuildContext context, {
  required SettingsController settings,
  required CallController call,
  required List<String> voices,
  LiveBackendInfo? backend,
  SpeechServices? speech,
  AppLinks? links,
}) => [
  const SectionHeader('Live voice'),
  GroupCard(
    margin: settingsCard,
    children: [
      SettingAnchor(
        id: 'voice',
        child: GroupRow(
          label: 'Voice',
          icon: Icons.graphic_eq_rounded,
          value: voiceTitle(settings.voice),
          subtitle: call.inCall ? 'Applies from the next live session' : null,
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => VoicePickerPage(
                settings: settings,
                voices: voices,
                live: call.inCall,
              ),
            ),
          ),
        ),
      ),
      if (backend != null)
        SettingAnchor(
          id: 'liveBackend',
          child: GroupRow(
            key: const ValueKey('settings-live-backend'),
            label: 'Voice service',
            icon: Icons.cloud_outlined,
            subtitle: [
              backend.title,
              ?backend.budget,
              if (backend.maxCallMinutes != null)
                'Calls up to ${backend.maxCallMinutes} minutes',
            ].join(' · '),
          ),
        ),
    ],
  ),
  const SettingsNote('The server operator picks the voice service.'),
  if (links != null && links.android) ...[
    SettingAnchor(
      id: 'defaultAssistant',
      child: GroupCard(
        margin: settingsCard,
        children: [DefaultAssistantRow(links: links)],
      ),
    ),
    const SizedBox(height: 12),
  ],
  SettingAnchor(id: 'background', child: SettingsNote(_backgroundText(call))),
  if (speech != null) ...[
    SpeechSettingsGroups(
      speech: speech,
      downloads: false,
      anchor: (id, child) => SettingAnchor(id: id, child: child),
    ),
    const SizedBox(height: 12),
    SettingAnchor(
      id: 'dictationLanguage',
      child: GroupCard(
        margin: settingsCard,
        children: [_DictationLanguageRow(speech: speech)],
      ),
    ),
    SpeechSettingsGroups(
      speech: speech,
      readAloud: false,
      dictation: false,
      anchor: (id, child) => SettingAnchor(id: id, child: child),
    ),
  ],
];

class _DictationLanguageRow extends StatelessWidget {
  const _DictationLanguageRow({required this.speech});
  final SpeechServices speech;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: speech.settings,
    builder: (context, _) {
      final s = speech.settings.value;
      return GroupRow(
        key: const ValueKey('settings-dictation-language'),
        label: 'Dictation language',
        icon: Icons.translate_rounded,
        value: dictationLanguageLabel(s.dictationLanguage),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => ChoicePage.open<String?>(
          context,
          title: 'Dictation language',
          listenable: speech.settings,
          options: [
            (
              null,
              'Automatic',
              'This device’s language; English in India’s time zone uses '
                  'English (India)',
            ),
            for (final (tag, label) in dictationLanguages) (tag, label, null),
          ],
          selected: () => speech.settings.value.dictationLanguage,
          onSelected: (tag) => unawaited(
            speech.settings.update(
              (s) => tag == null
                  ? s.copyWith(clearDictationLanguage: true)
                  : s.copyWith(dictationLanguage: tag),
            ),
          ),
          note: const SettingsNote(
            'For the Tove server and the phone recogniser. The offline '
            'Moonshine model understands English only.',
          ),
        ),
      );
    },
  );
}
