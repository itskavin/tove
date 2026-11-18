import 'package:material_ui/material_ui.dart';

import '../../brand.dart';

/// The Settings categories. Each is one page on phones and one detail pane
/// on wide screens; only categories with something real to show appear.
enum SettingsSection {
  general('General', Icons.tune_rounded),
  personalization('Personalization', Icons.person_outline_rounded),
  voice('Voice', Icons.graphic_eq_rounded),
  notifications('Notifications', Icons.notifications_outlined),
  data('Data controls', Icons.folder_outlined),
  usage('Usage and limits', Icons.speed_rounded),
  connection('Connection', Icons.dns_outlined),
  accessibility('Accessibility', Icons.accessibility_new_rounded),
  about('About', Icons.info_outline_rounded);

  const SettingsSection(this.title, this.icon);
  final String title;
  final IconData icon;
}

/// One searchable setting: its visible label, where it lives, and other
/// words people use for it.
@immutable
class SettingsEntry {
  const SettingsEntry(
    this.id,
    this.label,
    this.section, [
    this.keywords = const [],
  ]);

  /// The anchor the result scrolls to ([SettingAnchor.id]).
  final String id;
  final String label;
  final SettingsSection section;
  final List<String> keywords;
}

/// Every searchable setting that exists with these features.
List<SettingsEntry> settingsIndex({
  required bool effort,
  required bool speech,
  required bool notifications,
  bool personalization = false,
  bool history = false,
  bool sendWithEnter = false,
  bool liveBackend = false,
  bool usageLimits = false,
  bool assistant = false,
  bool updates = false,
}) => [
  // General
  const SettingsEntry('theme', 'Appearance', SettingsSection.general, [
    'theme', 'dark', 'light', 'system', 'mode', 'night', //
  ]),
  const SettingsEntry('accent', 'Accent colour', SettingsSection.general, [
    'accent color', 'colour', 'color', 'tint', 'highlight', 'blue', //
    'green', 'purple', 'pink', 'orange', 'teal',
  ]),
  const SettingsEntry('textSize', 'Text size', SettingsSection.general, [
    'font size', 'bigger', 'smaller', 'zoom', 'scale', 'larger text', //
  ]),
  if (effort)
    const SettingsEntry('effort', 'Reply effort', SettingsSection.general, [
      'instant', 'medium', 'high', 'thinking', 'speed', 'reasoning', //
      'default effort',
    ]),
  const SettingsEntry(
    'suggestions',
    'Show suggestions',
    SettingsSection.general,
    ['starter prompts', 'follow-up', 'ideas', 'new chat', 'chips'],
  ),
  if (sendWithEnter)
    const SettingsEntry(
      'sendWithEnter',
      'Send with Enter',
      SettingsSection.general,
      ['keyboard', 'return key', 'shift enter', 'new line', 'submit'],
    ),
  const SettingsEntry('sounds', 'Sounds', SettingsSection.general, [
    'tones', 'audio', 'beep', //
  ]),
  const SettingsEntry('haptics', 'Haptics', SettingsSection.general, [
    'vibration', 'vibrate', 'feedback', //
  ]),
  // Personalization
  if (personalization) ...[
    const SettingsEntry(
      'aboutYou',
      'What Hermes should know about you',
      SettingsSection.personalization,
      ['custom instructions', 'about me', 'profile', 'context', 'bio'],
    ),
    const SettingsEntry(
      'customInstructions',
      'How Hermes should respond',
      SettingsSection.personalization,
      [
        'custom instructions',
        'system prompt',
        'rules',
        'behaviour',
        'behavior',
      ],
    ),
    const SettingsEntry(
      'nickname',
      'Nickname',
      SettingsSection.personalization,
      [
        'name', 'call me', 'what to call you', //
      ],
    ),
    const SettingsEntry(
      'occupation',
      'Occupation',
      SettingsSection.personalization,
      ['job', 'work', 'profession', 'role'],
    ),
    const SettingsEntry('style', 'Tone', SettingsSection.personalization, [
      'personality', 'traits', 'style', 'concise', 'detailed', 'friendly', //
      'professional', 'preset',
    ]),
    const SettingsEntry(
      'resetPersonalization',
      'Reset personalization',
      SettingsSection.personalization,
      ['clear', 'remove', 'forget me'],
    ),
  ],
  // Voice
  const SettingsEntry('voice', 'Live voice', SettingsSection.voice, [
    'voice', 'speaker', 'persona', 'gpt-live', 'call', //
  ]),
  if (liveBackend)
    const SettingsEntry('liveBackend', 'Voice service', SettingsSection.voice, [
      'backend', 'codex', 'openai', 'minutes', 'live api', 'budget', //
    ]),
  if (assistant)
    const SettingsEntry(
      'defaultAssistant',
      'Default assistant app',
      SettingsSection.voice,
      [
        'assistant', 'digital assistant', 'home button', 'power button', //
        'long press', 'gemini', 'google assistant', 'default app',
      ],
    ),
  const SettingsEntry(
    'background',
    'Live voice in the background',
    SettingsSection.voice,
    ['background', 'screen off', 'other apps', 'notification', 'tab'],
  ),
  if (speech) ...[
    const SettingsEntry('readAloud', 'Read aloud', SettingsSection.voice, [
      'text to speech', 'tts', 'kokoro', 'natural voice', 'system voice', //
    ]),
    const SettingsEntry(
      'readReplies',
      'Read replies aloud',
      SettingsSection.voice,
      ['automatic', 'auto read', 'speak replies'],
    ),
    const SettingsEntry('speed', 'Speaking speed', SettingsSection.voice, [
      'rate', 'faster', 'slower', //
    ]),
    const SettingsEntry('dictation', 'Dictation', SettingsSection.voice, [
      'speech to text',
      'microphone',
      'recogniser',
      'recognizer',
      'moonshine',
      'engine',
    ]),
    const SettingsEntry(
      'dictationLanguage',
      'Dictation language',
      SettingsSection.voice,
      ['language', 'locale', 'english', 'speech language'],
    ),
    const SettingsEntry(
      'onDevice',
      'On this device only',
      SettingsSection.voice,
      ['privacy', 'offline', 'local'],
    ),
    const SettingsEntry('downloads', 'Voice downloads', SettingsSection.voice, [
      'models',
      'space',
      'delete',
      'kokoro',
      'moonshine',
      'storage',
    ]),
    const SettingsEntry(
      'wifiOnly',
      'Download on Wi-Fi only',
      SettingsSection.voice,
      ['mobile data', 'cellular', 'wifi'],
    ),
  ],
  // Notifications
  if (notifications) ...[
    const SettingsEntry(
      'replyNotifications',
      'Reply notifications',
      SettingsSection.notifications,
      ['alerts', 'push', 'ntfy', 'unifiedpush'],
    ),
    const SettingsEntry(
      'instantNotifications',
      'Instant notifications',
      SettingsSection.notifications,
      ['connection', 'background', 'battery', 'realtime', 'push', 'delay'],
    ),
    const SettingsEntry(
      'testNotification',
      'Send a test notification',
      SettingsSection.notifications,
      ['test', 'check notifications', 'not working', 'connection status'],
    ),
    const SettingsEntry(
      'testPush',
      'UnifiedPush test',
      SettingsSection.notifications,
      ['test push', 'ntfy', 'unifiedpush', 'push status', 'distributor'],
    ),
  ],
  // Data controls
  if (history) ...[
    const SettingsEntry('history', 'Chat history', SettingsSection.data, [
      'chats', 'conversations', 'search chats', 'past chats', 'list', //
    ]),
    const SettingsEntry('export', 'Export all chats', SettingsSection.data, [
      'download', 'backup', 'json', 'save', 'data export', 'takeout', //
    ]),
    const SettingsEntry('deleteAll', 'Delete all chats', SettingsSection.data, [
      'clear history', 'erase', 'remove chats', 'wipe', //
    ]),
  ],
  const SettingsEntry('cache', 'Images and attachments', SettingsSection.data, [
    'cache', 'clear cache', 'storage', 'space', 'files', 'temporary', //
  ]),
  // Connection
  const SettingsEntry('server', 'Server', SettingsSection.connection, [
    'url', 'address', 'bridge', 'host', //
  ]),
  const SettingsEntry(
    'status',
    'Connection status',
    SettingsSection.connection,
    [
      'online', 'offline', 'reachable', 'connected', //
    ],
  ),
  const SettingsEntry(
    'bridge',
    'Server version and features',
    SettingsSection.connection,
    ['capabilities', 'api', 'bridge version', 'features'],
  ),
  const SettingsEntry('sync', 'Settings sync', SettingsSection.connection, [
    'sync', 'devices', 'synced', 'other devices', 'cloud', //
  ]),
  const SettingsEntry('usage', 'Usage', SettingsSection.connection, [
    'tokens', 'cost', 'minutes', 'quota', 'limits', //
  ]),
  const SettingsEntry('key', 'Access key', SettingsSection.connection, [
    'key', 'token', 'password', 'change server', 'account', //
  ]),
  const SettingsEntry(
    'forgetKey',
    'Forget access key',
    SettingsSection.connection,
    ['sign out', 'log out', 'logout', 'remove key', 'reset'],
  ),
  const SettingsEntry(
    'selfHost',
    'Set up ${Brand.appName} for someone else',
    SettingsSection.connection,
    [
      'self-hosting',
      'self host',
      'friend',
      'family',
      'install',
      'guide',
      'share',
    ],
  ),
  if (usageLimits)
    const SettingsEntry(
      'usageLimits',
      'Usage and limits',
      SettingsSection.usage,
      [
        'quota', 'limits', 'rate limit', 'credits', 'codex', 'claude', //
        'antigravity', '5-hour', 'weekly', 'subscription', 'plan',
      ],
    ),
  // Accessibility
  const SettingsEntry(
    'motion',
    'Reduce motion',
    SettingsSection.accessibility,
    ['animation', 'orb', 'movement', 'still'],
  ),
  const SettingsEntry(
    'largerText',
    'Larger text',
    SettingsSection.accessibility,
    ['text size', 'font', 'bigger', 'zoom', 'vision'],
  ),
  const SettingsEntry(
    'contrast',
    'Increase contrast',
    SettingsSection.accessibility,
    ['high contrast', 'contrast', 'readability', 'vision', 'darker text'],
  ),
  const SettingsEntry(
    'refreshRate',
    'Refresh rate',
    SettingsSection.accessibility,
    ['hz', '90', '120', '60', 'smooth', 'display', 'frame rate', 'battery'],
  ),
  // About
  const SettingsEntry(
    'about',
    'About ${Brand.appName}',
    SettingsSection.about,
    ['version', 'how it works', 'hermes'],
  ),
  const SettingsEntry(
    'shortcuts',
    'Keyboard shortcuts',
    SettingsSection.about,
    ['keys', 'hotkeys', 'ctrl'],
  ),
  if (updates)
    const SettingsEntry('updates', 'Check for updates', SettingsSection.about, [
      'update', 'new version', 'upgrade', 'release', 'download', 'apk', //
    ]),
  const SettingsEntry('privacy', 'Privacy', SettingsSection.about, [
    'data', 'tracking', 'analytics', 'where my data goes', //
  ]),
  const SettingsEntry('licences', 'Licences', SettingsSection.about, [
    'licenses', 'open source', 'legal', 'credits', //
  ]),
];

/// The entries matching [query]: every word must start a word of the label,
/// the section name or a keyword. Label matches come first.
List<SettingsEntry> searchSettings(String query, List<SettingsEntry> index) {
  // Query and labels split the same way, so "wi-fi" finds "Wi-Fi".
  List<String> tokens(String s) => s
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9+]+'))
      .where((w) => w.isNotEmpty)
      .toList();
  final words = tokens(query);
  if (words.isEmpty) return const [];
  bool hits(List<String> pool) =>
      words.every((w) => pool.any((p) => p.startsWith(w)));
  final strong = <SettingsEntry>[], weak = <SettingsEntry>[];
  for (final e in index) {
    final label = tokens(e.label);
    if (hits(label)) {
      strong.add(e);
    } else if (hits([
      ...label,
      ...tokens(e.section.title),
      for (final k in e.keywords) ...tokens(k),
    ])) {
      weak.add(e);
    }
  }
  return [...strong, ...weak];
}
