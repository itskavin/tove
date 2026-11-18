import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

/// Parts of the day a starter prompt suits (local time).
enum DayPart { morning, afternoon, evening, night }

DayPart dayPartOf(DateTime t) => switch (t.hour) {
  >= 5 && < 12 => DayPart.morning,
  >= 12 && < 17 => DayPart.afternoon,
  >= 17 && < 22 => DayPart.evening,
  _ => DayPart.night,
};

/// One suggestion on the empty new chat: the text it sends, and the icon the
/// wide layout's suggestion rows show in front of it.
@immutable
class StarterPrompt {
  const StarterPrompt(
    this.text, {
    this.icon = Icons.chat_bubble_outline_rounded,
    this.emoji = '✨',
    this.parts = const {},
    this.send,
  });

  /// What the chip or row shows.
  final String text;
  final IconData icon;

  /// The emoji in front of the label on the starter chips.
  final String emoji;

  /// What a tap sends: the bridge's `prompt` when it differs from its
  /// `title`, otherwise [text].
  String get prompt => send ?? text;
  final String? send;

  /// Empty: any time of day.
  final Set<DayPart> parts;

  @override
  bool operator ==(Object other) =>
      other is StarterPrompt && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'StarterPrompt($text)';
}

const _m = {DayPart.morning};
const _e = {DayPart.evening, DayPart.night};
const _day = {DayPart.morning, DayPart.afternoon};

/// The local pool: server checks, everyday questions and a few open ones,
/// some tied to a part of the day.
const starterPool = <StarterPrompt>[
  // Server health.
  StarterPrompt(
    'How full are the disks?',
    emoji: '💽',
    icon: Icons.storage_rounded,
  ),
  StarterPrompt(
    'Are all my servers healthy?',
    emoji: '🩺',
    icon: Icons.monitor_heart_outlined,
  ),
  StarterPrompt(
    'What did last night’s backups do?',
    emoji: '🗄️',
    icon: Icons.backup_outlined,
    parts: _m,
  ),
  StarterPrompt(
    'Summarise today’s alerts',
    emoji: '🔔',
    icon: Icons.notifications_none_rounded,
    parts: {DayPart.afternoon, DayPart.evening},
  ),
  StarterPrompt(
    'Which containers restarted recently?',
    emoji: '🔁',
    icon: Icons.restart_alt_rounded,
  ),
  StarterPrompt(
    'How busy is my main server right now?',
    emoji: '⚙️',
    icon: Icons.memory_rounded,
  ),
  StarterPrompt(
    'Check the health of my drives',
    emoji: '🧰',
    icon: Icons.health_and_safety_outlined,
  ),
  StarterPrompt(
    'Are any updates waiting on the servers?',
    emoji: '⬆️',
    icon: Icons.system_update_alt_rounded,
  ),
  StarterPrompt(
    'What changed on my servers this week?',
    emoji: '🗓️',
    icon: Icons.history_rounded,
  ),
  StarterPrompt(
    'Is the internet connection stable today?',
    emoji: '📶',
    icon: Icons.wifi_rounded,
    parts: _day,
  ),
  StarterPrompt(
    'Anything unusual in the logs overnight?',
    emoji: '🔎',
    icon: Icons.manage_search_rounded,
    parts: _m,
  ),
  StarterPrompt(
    'Run a quick check before I go to bed',
    emoji: '🌙',
    icon: Icons.bedtime_outlined,
    parts: _e,
  ),
  // Media and home.
  StarterPrompt(
    'What’s new in the media library?',
    emoji: '🎬',
    icon: Icons.movie_outlined,
    parts: _e,
  ),
  StarterPrompt(
    'Suggest a film for tonight',
    emoji: '🍿',
    icon: Icons.local_movies_outlined,
    parts: _e,
  ),
  StarterPrompt(
    'What’s downloading at the moment?',
    emoji: '📥',
    icon: Icons.downloading_rounded,
  ),
  // Everyday.
  StarterPrompt(
    'Plan my day in three steps',
    emoji: '📝',
    icon: Icons.checklist_rounded,
    parts: _m,
  ),
  StarterPrompt(
    'What’s the weather like today?',
    emoji: '🌤️',
    icon: Icons.wb_sunny_outlined,
    parts: _m,
  ),
  StarterPrompt(
    'Give me a quick dinner idea',
    emoji: '🍝',
    icon: Icons.restaurant_outlined,
    parts: {DayPart.afternoon, DayPart.evening},
  ),
  StarterPrompt(
    'Help me write a short message',
    emoji: '✍️',
    icon: Icons.edit_note_rounded,
  ),
  StarterPrompt(
    'Explain something I should know about',
    emoji: '💡',
    icon: Icons.lightbulb_outline_rounded,
  ),
  StarterPrompt(
    'Summarise a web page for me',
    emoji: '📰',
    icon: Icons.article_outlined,
  ),
  StarterPrompt(
    'Find the latest news on a topic',
    emoji: '🌍',
    icon: Icons.public_rounded,
    parts: _day,
  ),
  StarterPrompt(
    'Help me wind down with a short story',
    emoji: '📖',
    icon: Icons.auto_stories_outlined,
    parts: {DayPart.night},
  ),
  StarterPrompt(
    'Quiz me on something new',
    emoji: '🧠',
    icon: Icons.quiz_outlined,
  ),
  StarterPrompt(
    'Draft a shell script for a chore',
    emoji: '💻',
    icon: Icons.terminal_rounded,
  ),
  StarterPrompt(
    'Set me a reminder for later',
    emoji: '⏰',
    icon: Icons.alarm_rounded,
  ),
];

/// Picks the empty chat's suggestions: a fresh set for every new chat, from
/// the bridge's suggestions when it has some and the local [pool] otherwise.
///
/// No prompt from the previous set comes back straight away (while the pool
/// is big enough), and prompts that suit the part of the day are three times
/// as likely as general ones; ones for another part of the day are rare.
class StarterPrompts {
  StarterPrompts({
    Random? random,
    this.pool = starterPool,
    this.count = marqueeCount,
  }) : _random = random ?? (debugSeed == null ? Random() : Random(debugSeed));

  /// Tests: a fixed seed and clock, so goldens and finders see the same set
  /// (test/flutter_test_config.dart sets both).
  @visibleForTesting
  static int? debugSeed;
  @visibleForTesting
  static DateTime Function()? debugClock;

  final Random _random;
  final List<StarterPrompt> pool;
  final int count;

  /// Prompts per new chat: two drifting rows of six.
  static const marqueeCount = 12;

  /// Prompts the bridge offered (`GET /api/suggestions`), newest first.
  List<StarterPrompt> remote = const [];

  List<StarterPrompt> _last = const [];
  List<StarterPrompt> get last => _last;

  static double _weight(StarterPrompt p, DayPart now, {bool remote = false}) {
    if (remote) return 4;
    if (p.parts.isEmpty) return 1;
    return p.parts.contains(now) ? 3 : 0.15;
  }

  /// A new set of [count] prompts, different from the last one.
  List<StarterPrompt> next({DateTime? now}) {
    final part = dayPartOf(now ?? debugClock?.call() ?? DateTime.now());
    final seen = <String>{};
    final candidates = <(StarterPrompt, double)>[
      for (final p in remote)
        if (seen.add(p.text)) (p, _weight(p, part, remote: true)),
      for (final p in pool)
        if (seen.add(p.text)) (p, _weight(p, part)),
    ];
    final fresh = [
      for (final c in candidates)
        if (!_last.contains(c.$1)) c,
    ];
    // Fall back to repeats only when the pool is too small.
    final from = fresh.length >= count ? fresh : candidates;
    final picked = <StarterPrompt>[];
    final bag = [...from];
    while (picked.length < count && bag.isNotEmpty) {
      final total = bag.fold<double>(0, (s, c) => s + c.$2);
      var r = _random.nextDouble() * total;
      var i = 0;
      for (; i < bag.length - 1; i++) {
        r -= bag[i].$2;
        if (r <= 0) break;
      }
      picked.add(bag.removeAt(i).$1);
    }
    return _last = picked;
  }

  /// Parses `GET /api/suggestions`: `{"suggestions": [...]}` or a bare list,
  /// with strings or `{"text": ...}` objects. Unknown shapes give nothing.
  ///
  /// The bridge (API.md "Suggestions") sends `{"id", "title", "prompt",
  /// "category"}`: `title` is shown, `prompt` is sent, `category` picks the
  /// icon.
  static List<StarterPrompt> parse(Object? json) {
    final list = json is Map ? json['suggestions'] ?? json['items'] : json;
    if (list is! List) return const [];
    String? str(Object? v) {
      final t = v is String ? v.trim() : '';
      return t.isEmpty ? null : t;
    }

    final out = <StarterPrompt>[];
    for (final e in list) {
      final (
        String? title,
        String? prompt,
        String? category,
        String? emoji,
      ) = switch (e) {
        String s => (str(s), null, null, null),
        Map m => (
          str(m['title']) ?? str(m['text']) ?? str(m['prompt']),
          str(m['prompt']),
          str(m['category']),
          str(m['emoji']),
        ),
        _ => (null, null, null, null),
      };
      if (title == null || title.length > 120) continue;
      out.add(
        StarterPrompt(
          title,
          send: prompt != null && prompt != title && prompt.length <= 2000
              ? prompt
              : null,
          icon: categoryIcons[category] ?? Icons.auto_awesome_outlined,
          emoji: emoji != null && emoji.runes.length <= 8
              ? emoji
              : categoryEmoji[category] ??
                    fallbackEmoji[out.length % fallbackEmoji.length],
        ),
      );
    }
    return out;
  }

  /// Emoji for the bridge's starter categories, used when a suggestion
  /// brings none of its own (`emoji`).
  static const categoryEmoji = <String, String>{
    'homelab': '🖥️',
    'media': '🎬',
    'writing': '✍️',
    'learning': '📚',
    'planning': '🗓️',
    'code': '💻',
    'food': '🍳',
    'health': '🌿',
    'ideas': '💡',
    'fun': '🎲',
    'productivity': '✅',
  };

  /// For suggestions with neither an emoji nor a known category.
  static const fallbackEmoji = ['✨', '💬', '🧭', '🪄', '🌟', '🔮'];

  /// Icons for the bridge's starter categories.
  static const categoryIcons = <String, IconData>{
    'homelab': Icons.dns_outlined,
    'media': Icons.movie_outlined,
    'writing': Icons.edit_note_rounded,
    'learning': Icons.school_outlined,
    'planning': Icons.event_note_outlined,
    'code': Icons.terminal_rounded,
    'food': Icons.restaurant_outlined,
    'health': Icons.favorite_outline_rounded,
    'ideas': Icons.lightbulb_outline_rounded,
    'fun': Icons.casino_outlined,
    'productivity': Icons.checklist_rounded,
  };
}

/// Fetches the bridge's starter suggestions without ever blocking the empty
/// chat: a short timeout, and after a 404 (an older bridge) it stops asking.
class RemoteSuggestions {
  RemoteSuggestions({
    required this.baseUrl,
    required this.accessKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 4),
  }) : _client = client ?? http.Client(),
       _owns = client == null;

  final Uri baseUrl;
  final String accessKey;
  final Duration timeout;
  final http.Client _client;
  final bool _owns;
  bool _unsupported = false;

  bool get unsupported => _unsupported;

  Future<List<StarterPrompt>> fetch() async {
    if (_unsupported) return const [];
    final path = baseUrl.path.endsWith('/')
        ? baseUrl.path.substring(0, baseUrl.path.length - 1)
        : baseUrl.path;
    final url = baseUrl.replace(
      path: '$path/api/suggestions',
      // The bridge's maximum; the local pool fills the rest of the rows.
      queryParameters: const {'n': '8'},
    );
    try {
      final r = await _client
          .get(url, headers: {'Authorization': 'Bearer $accessKey'})
          .timeout(timeout);
      if (r.statusCode == 404 || r.statusCode == 405) {
        _unsupported = true;
        return const [];
      }
      if (r.statusCode < 200 || r.statusCode >= 300) return const [];
      return StarterPrompts.parse(jsonDecode(r.body));
    } catch (_) {
      return const [];
    }
  }

  void close() {
    if (_owns) _client.close();
  }
}
