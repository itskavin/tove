/// `GET /api/usage/limits` (capability `usage_limits`): the subscription
/// quota of every account the AI runs on, per provider (API.md "Usage
/// limits"). Every field is optional on the wire; parsing never throws.
class UsageLimits {
  const UsageLimits({
    required this.providers,
    this.observedAt,
    this.cached = false,
    this.notes = const [],
  });

  final List<UsageProvider> providers;
  final DateTime? observedAt;
  final bool cached;

  /// Problems with a whole source ("CLIProxyAPI could not be read").
  final List<String> notes;

  factory UsageLimits.fromJson(Map<String, dynamic> j) => UsageLimits(
    providers: [
      for (final p in _maps(j['providers'])) UsageProvider.fromJson(p),
    ],
    observedAt: _time(j['observed_at']),
    cached: j['cached'] == true,
    notes: [
      for (final n in (j['notes'] is List ? j['notes'] as List : const []))
        if (n is String && n.isNotEmpty) n,
    ],
  );
}

class UsageProvider {
  const UsageProvider({
    required this.id,
    required this.name,
    required this.accounts,
  });

  final String id;
  final String name;
  final List<UsageAccount> accounts;

  factory UsageProvider.fromJson(Map<String, dynamic> j) => UsageProvider(
    id: _str(j['id']) ?? '',
    name: _str(j['name']) ?? _str(j['id']) ?? 'Provider',
    accounts: [for (final a in _maps(j['accounts'])) UsageAccount.fromJson(a)],
  );
}

enum UsageStatus {
  ok,
  warning,
  limited,
  unavailable,
  expired,
  error,
  disabled,
  unknown;

  static UsageStatus parse(Object? v) =>
      values.asNameMap()[v is String ? v : ''] ?? unknown;
}

class UsageAccount {
  const UsageAccount({
    required this.id,
    required this.label,
    this.plan,
    this.status = UsageStatus.unknown,
    this.usedFor = const [],
    this.live = false,
    this.observedAt,
    this.note,
    this.windows = const [],
    this.credits,
  });

  final String id;

  /// The masked email (`t•••@g•••.com`).
  final String label;
  final String? plan;
  final UsageStatus status;
  final List<String> usedFor;
  final bool live;
  final DateTime? observedAt;
  final String? note;
  final List<UsageWindow> windows;
  final UsageCredits? credits;

  factory UsageAccount.fromJson(Map<String, dynamic> j) => UsageAccount(
    id: _str(j['id']) ?? _str(j['label']) ?? '',
    label: _str(j['label']) ?? 'Account',
    plan: _str(j['plan']),
    status: UsageStatus.parse(j['status']),
    usedFor: [
      for (final u in (j['used_for'] is List ? j['used_for'] as List : []))
        if (u is String) u,
    ],
    live: j['live'] == true,
    observedAt: _time(j['observed_at']),
    note: _str(j['note']),
    windows: [for (final w in _maps(j['windows'])) UsageWindow.fromJson(w)],
    credits: j['credits'] is Map<String, dynamic>
        ? UsageCredits.fromJson(j['credits'] as Map<String, dynamic>)
        : null,
  );
}

class UsageWindow {
  const UsageWindow({
    required this.id,
    required this.label,
    required this.remainingPercent,
    this.resetsAt,
    this.scope,
  });

  final String id;

  /// `5-hour`, `Weekly`, `30-day`, `Daily`.
  final String label;

  /// 0–100.
  final double remainingPercent;
  final DateTime? resetsAt;

  /// Null for the account-wide limit, else what it covers (`Opus`).
  final String? scope;

  factory UsageWindow.fromJson(Map<String, dynamic> j) {
    final remaining = _num(j['remaining_percent']);
    final used = _num(j['used_percent']);
    return UsageWindow(
      id: _str(j['id']) ?? '',
      label: _str(j['label']) ?? _str(j['id']) ?? 'Limit',
      remainingPercent: (remaining ?? (used == null ? 0 : 100 - used))
          .clamp(0, 100)
          .toDouble(),
      resetsAt: _time(j['resets_at']),
      scope: _str(j['scope']),
    );
  }

  /// "5-hour limit", "Weekly limit · Opus".
  String get title {
    final base = label.toLowerCase().endsWith('limit') ? label : '$label limit';
    return scope == null ? base : '$base · $scope';
  }
}

class UsageCredits {
  const UsageCredits({
    this.balance,
    this.unlimited = false,
    this.hasCredits = false,
    this.currency,
    this.used,
    this.monthlyLimit,
  });

  final double? balance;
  final bool unlimited;
  final bool hasCredits;
  final String? currency;
  final double? used;
  final double? monthlyLimit;

  factory UsageCredits.fromJson(Map<String, dynamic> j) => UsageCredits(
    balance: _num(j['balance']),
    unlimited: j['unlimited'] == true,
    hasCredits: j['has_credits'] == true,
    currency: _str(j['currency']),
    used: _num(j['used']),
    monthlyLimit: _num(j['monthly_limit']),
  );
}

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;
double? _num(Object? v) => v is num ? v.toDouble() : null;
DateTime? _time(Object? v) =>
    v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
Iterable<Map<String, dynamic>> _maps(Object? v) =>
    (v is List ? v : const []).whereType<Map<String, dynamic>>();

/// "Resets in 3 h 12 min", "Resets in 2 days", "Resets soon".
String resetsIn(DateTime at, DateTime now) {
  final d = at.difference(now);
  if (d.inMinutes < 1) return 'Resets soon';
  if (d.inHours < 1) return 'Resets in ${d.inMinutes} min';
  if (d.inHours < 24) {
    final m = d.inMinutes % 60;
    return 'Resets in ${d.inHours} h${m == 0 ? '' : ' $m min'}';
  }
  final days = d.inHours ~/ 24;
  final h = d.inHours % 24;
  return 'Resets in $days ${days == 1 ? 'day' : 'days'}'
      '${h == 0 ? '' : ' $h h'}';
}

/// "Updated just now", "Updated 4 min ago".
String updatedAgo(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inMinutes < 1) return 'Updated just now';
  if (d.inHours < 1) return 'Updated ${d.inMinutes} min ago';
  if (d.inHours < 24) return 'Updated ${d.inHours} h ago';
  return 'Updated ${d.inDays} ${d.inDays == 1 ? 'day' : 'days'} ago';
}
