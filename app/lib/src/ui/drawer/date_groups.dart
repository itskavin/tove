import '../../chat/chat.dart';

/// Chats grouped by their last update for the drawer: Today, Yesterday,
/// Previous 7 days, Previous 30 days, then one group per month ("October",
/// or "October 2025" outside the current year). Order inside a group follows
/// [chats] (the list arrives newest first). Pinned chats are listed apart and
/// are not passed here.
List<(String, List<Conversation>)> groupChatsByDate(
  List<Conversation> chats, {
  DateTime? now,
}) {
  final n = (now ?? DateTime.now()).toLocal();
  final today = DateTime(n.year, n.month, n.day);
  final groups = <String, List<Conversation>>{};
  for (final c in chats) {
    final u = c.updated.toLocal();
    final day = DateTime(u.year, u.month, u.day);
    // Calendar days, safe across DST changes.
    final days = DateTime.utc(
      today.year,
      today.month,
      today.day,
    ).difference(DateTime.utc(day.year, day.month, day.day)).inDays;
    final label = switch (days) {
      <= 0 => 'Today',
      1 => 'Yesterday',
      <= 7 => 'Previous 7 days',
      <= 30 => 'Previous 30 days',
      _ =>
        u.year == n.year
            ? _months[u.month - 1]
            : '${_months[u.month - 1]} ${u.year}',
    };
    (groups[label] ??= []).add(c);
  }
  return [for (final e in groups.entries) (e.key, e.value)];
}

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
