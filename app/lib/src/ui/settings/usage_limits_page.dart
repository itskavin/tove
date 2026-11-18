import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../chat/chat_errors.dart';
import '../../chat/usage_limits.dart';
import '../common/group_card.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'settings_widgets.dart';

/// How often the page re-reads the limits while visible.
const usageLimitsPollEvery = Duration(minutes: 1);

/// Loads the limits; `refresh` asks the providers again (`?refresh=1`).
typedef LoadUsageLimits = Future<UsageLimits> Function({bool refresh});

/// Settings › Usage and limits (API.md "Usage limits"): every account the
/// bridge reports, grouped by provider in the bridge's order (nothing is
/// hard-coded), each limit as a "remaining" bar with when it resets, then
/// credits. Accounts added to or removed from CLIProxyAPI animate in and
/// out by their stable id. It asks the providers again on open and on pull
/// (`?refresh=1`), and quietly re-reads every minute while visible.
class UsageLimitsPage extends StatelessWidget {
  const UsageLimitsPage({super.key, required this.load, this.clock});

  /// Null: the bridge has no `usage_limits` (an older bridge).
  final LoadUsageLimits? load;
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: settingsBar(context, 'Usage and limits'),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: UsageLimitsView(load: load, clock: clock, scrolls: true),
      ),
    ),
  );
}

/// The page's content. [scrolls]: its own pull-to-refresh list (a page);
/// otherwise a column with a refresh button (the wide Settings pane).
class UsageLimitsView extends StatefulWidget {
  const UsageLimitsView({
    super.key,
    required this.load,
    this.clock,
    this.scrolls = false,
  });

  final LoadUsageLimits? load;
  final DateTime Function()? clock;
  final bool scrolls;

  @override
  State<UsageLimitsView> createState() => _UsageLimitsViewState();
}

/// An account on screen: its provider, and whether it is leaving (gone
/// from the last answer, animating out).
typedef _Shown = ({UsageProvider provider, UsageAccount account, bool gone});

class _UsageLimitsViewState extends State<UsageLimitsView>
    with WidgetsBindingObserver {
  UsageLimits? _data;
  Object? _error;
  bool _loading = false;
  Timer? _poll;

  /// Accounts dropped by the last answer, keyed like [_key], until their
  /// exit animation ends.
  final _gone =
      <String, ({UsageProvider provider, UsageAccount account, int index})>{};

  DateTime get _now => (widget.clock ?? DateTime.now)();

  static String _key(UsageProvider p, UsageAccount a) => '${p.id}/${a.id}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Opening the page asks the providers again.
    if (widget.load != null) unawaited(_fetch(refresh: true));
    // Quiet re-reads (the bridge caches 60 s), only while visible; this
    // also keeps "Resets in" and "Updated … ago" current.
    _poll = Timer.periodic(usageLimitsPollEvery, (_) {
      if (!mounted || !_visible) return;
      unawaited(_fetch(quiet: true));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back in the foreground after a while: catch up at once.
    if (state == AppLifecycleState.resumed && mounted && _visible) {
      unawaited(_fetch(quiet: true));
    }
  }

  /// In the foreground, on the top route and not in a hidden pane.
  bool get _visible {
    final life = WidgetsBinding.instance.lifecycleState;
    if (life != null && life != AppLifecycleState.resumed) return false;
    if (!TickerMode.valuesOf(context).enabled) return false;
    return ModalRoute.of(context)?.isCurrent ?? true;
  }

  /// [quiet]: no spinner, and a failure keeps the last answer silently.
  Future<void> _fetch({bool refresh = false, bool quiet = false}) async {
    final load = widget.load;
    if (load == null || (_loading && quiet)) return;
    if (!quiet) setState(() => _loading = true);
    try {
      final d = await load(refresh: refresh);
      if (!mounted) return;
      setState(() {
        _noteGone(_data, d);
        _data = d;
        _error = null;
      });
    } catch (e) {
      if (mounted && (!quiet || _data == null)) setState(() => _error = e);
    } finally {
      if (mounted && !quiet) setState(() => _loading = false);
    }
  }

  /// Keeps accounts that disappeared, at their old place, to animate out.
  void _noteGone(UsageLimits? before, UsageLimits after) {
    if (before == null) return;
    final now = {
      for (final p in after.providers)
        for (final a in p.accounts) _key(p, a),
    };
    for (final p in before.providers) {
      for (final (i, a) in p.accounts.indexed) {
        final k = _key(p, a);
        if (!now.contains(k)) _gone[k] = (provider: p, account: a, index: i);
      }
    }
    // An account that came back is no longer leaving.
    _gone.removeWhere((k, _) => now.contains(k));
  }

  /// Providers in the bridge's order with their accounts, plus the leaving
  /// ones at their old places (providers that left go last).
  List<(UsageProvider, List<_Shown>)> _groups(UsageLimits data) {
    final out = <(UsageProvider, List<_Shown>)>[];
    final seen = <String>{};
    void add(UsageProvider p, List<UsageAccount> current) {
      final rows = <_Shown>[
        for (final a in current) (provider: p, account: a, gone: false),
      ];
      final leaving = _gone.values.where((g) => g.provider.id == p.id).toList()
        ..sort((a, b) => a.index.compareTo(b.index));
      for (final g in leaving) {
        rows.insert(g.index.clamp(0, rows.length), (
          provider: p,
          account: g.account,
          gone: true,
        ));
      }
      if (rows.isNotEmpty) out.add((p, rows));
    }

    for (final p in data.providers) {
      seen.add(p.id);
      add(p, p.accounts);
    }
    final left = {
      for (final g in _gone.values)
        if (!seen.contains(g.provider.id)) g.provider.id: g.provider,
    };
    for (final p in left.values) {
      add(p, const []);
    }
    return out;
  }

  String _problem(Object e) {
    if (e is ChatException) {
      if (e.status == 404) return _oldBridge;
      if (e.code == 'usage_limits_unavailable') {
        return 'The server can’t read any account’s limits yet.';
      }
      if (e.code == 'timeout') {
        return 'The providers took too long to answer. Pull to try again.';
      }
    }
    return 'Couldn’t load the limits. Pull to try again.';
  }

  static const _oldBridge =
      'This server doesn’t report usage limits yet. Update the bridge to '
      'see them.';

  List<Widget> _children(HermesTokens t) {
    final data = _data;
    if (widget.load == null) {
      return [_message(t, _oldBridge, key: 'usage-unsupported')];
    }
    if (data == null) {
      if (_error != null) {
        return [
          _message(t, _problem(_error!), key: 'usage-error', error: true),
          if (!widget.scrolls) _retry(),
        ];
      }
      return [
        const Padding(
          padding: EdgeInsets.all(48),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    final now = _now;
    final groups = _groups(data);
    return [
      if (data.observedAt != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  updatedAgo(data.observedAt!, now),
                  key: const ValueKey('usage-updated'),
                  style: t.label,
                ),
              ),
              if (!widget.scrolls) _refreshButton(),
            ],
          ),
        ),
      if (_error != null)
        _message(t, _problem(_error!), key: 'usage-error', error: true),
      for (final n in data.notes) SettingsNote(n, icon: Icons.info_outline),
      if (groups.isEmpty)
        _message(t, 'No accounts to show.', key: 'usage-empty'),
      for (final (p, rows) in groups)
        _Presence(
          key: ValueKey('usage-provider-${p.id}'),
          visible: rows.any((r) => !r.gone),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
                child: Semantics(
                  header: true,
                  child: Text(p.name, style: t.title),
                ),
              ),
              for (final r in rows)
                _Presence(
                  // The bridge's stable opaque id (the label is masked).
                  key: ValueKey('usage-account-${_key(p, r.account)}'),
                  visible: !r.gone,
                  onGone: () =>
                      setState(() => _gone.remove(_key(p, r.account))),
                  child: _account(t, r.account, now),
                ),
            ],
          ),
        ),
    ];
  }

  Widget _account(HermesTokens t, UsageAccount a, DateTime now) {
    final plan = a.plan == null
        ? null
        : '${a.plan![0].toUpperCase()}${a.plan!.substring(1)}';
    final credits = a.credits;
    final state = accountState(a);
    // Disabled or expired accounts stay listed, dimmed under their badge.
    final dim = state?.dim ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  [a.label, ?plan].join(' · '),
                  style: t.label.copyWith(color: t.text),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (state != null) _StatusChip(state: state),
            ],
          ),
        ),
        Opacity(
          opacity: dim ? 0.55 : 1,
          child: GroupCard(
            margin: settingsCard,
            children: [
              if (a.windows.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    a.note ?? 'No limits reported for this account.',
                    style: t.label.hermesWeight(400),
                  ),
                ),
              for (final w in a.windows) _LimitRow(window: w, now: now),
              if (credits != null) _creditsRow(t, credits),
            ],
          ),
        ),
        if (a.note != null && a.windows.isNotEmpty) SettingsNote(a.note!),
      ],
    );
  }

  Widget _creditsRow(HermesTokens t, UsageCredits c) {
    String money(double v) => c.currency == null
        ? v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2)
        : '${v.toStringAsFixed(2)} ${c.currency}';
    final value = c.unlimited
        ? 'Unlimited'
        : c.used != null && c.monthlyLimit != null
        ? '${money(c.used!)} of ${money(c.monthlyLimit!)} used'
        : c.balance != null
        ? money(c.balance!)
        : c.hasCredits
        ? 'Available'
        : 'None';
    return GroupRow(
      key: const ValueKey('usage-credits'),
      label: 'Credits',
      icon: Icons.toll_outlined,
      value: value,
    );
  }

  Widget _message(
    HermesTokens t,
    String text, {
    required String key,
    bool error = false,
  }) => Padding(
    key: ValueKey(key),
    padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
    child: Column(
      children: [
        Icon(
          error ? Icons.cloud_off_outlined : Icons.speed_rounded,
          size: 32,
          color: t.textMuted,
        ),
        const SizedBox(height: 12),
        Text(
          text,
          textAlign: TextAlign.center,
          style: t.row.copyWith(color: t.textMuted).hermesWeight(400),
        ),
      ],
    ),
  );

  Widget _refreshButton() => IconButton(
    key: const ValueKey('usage-refresh'),
    tooltip: 'Refresh',
    onPressed: _loading ? null : () => unawaited(_fetch(refresh: true)),
    icon: const Icon(Icons.refresh_rounded, size: 20),
  );

  Widget _retry() => Center(
    child: TextButton(
      onPressed: _loading ? null : () => unawaited(_fetch(refresh: true)),
      child: const Text('Try again'),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final children = _children(t);
    if (!widget.scrolls) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }
    final list = ListView(
      key: const ValueKey('usage-list'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(
        bottom: 32 + MediaQuery.paddingOf(context).bottom,
      ),
      children: children,
    );
    return widget.load == null
        ? list
        : RefreshIndicator.adaptive(
            onRefresh: () => _fetch(refresh: true),
            child: list,
          );
  }
}

/// One limit: label, "% remaining", the bar and when it resets.
class _LimitRow extends StatelessWidget {
  const _LimitRow({required this.window, required this.now});
  final UsageWindow window;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final left = window.remainingPercent;
    final pct = left == left.roundToDouble()
        ? left.toStringAsFixed(0)
        : left.toStringAsFixed(1);
    final colour = left <= 0
        ? t.danger
        : left <= 20
        ? t.warning
        : t.accent;
    final reset = window.resetsAt == null
        ? null
        : resetsIn(window.resetsAt!, now);
    return Semantics(
      container: true,
      label: [window.title, '$pct % remaining', ?reset].join(', '),
      excludeSemantics: true,
      child: Padding(
        key: ValueKey('usage-window-${window.id}'),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    window.title,
                    style: t.row,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text('$pct% remaining', style: t.label.copyWith(color: t.text)),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: left / 100,
                minHeight: 8,
                color: colour,
                backgroundColor: t.surfaceHigh,
              ),
            ),
            if (reset != null) ...[
              const SizedBox(height: 8),
              Text(reset, style: t.label.hermesWeight(400)),
            ],
          ],
        ),
      ),
    );
  }
}

enum _Tone { warn, bad, muted }

/// What an account's badge says, or null for a healthy one (no badge).
/// `dim` greys its limits out: the account is not in use.
({String text, bool dim, _Tone tone})? accountState(UsageAccount a) {
  final expired = RegExp(
    r'expired|sign in again|log ?in again|reauth',
    caseSensitive: false,
  ).hasMatch(a.note ?? '');
  // `expired` from bridges after 16 Nov 2026; older ones say so in `note`.
  if (expired || a.status == UsageStatus.expired) {
    return (text: 'Expired', dim: true, tone: _Tone.bad);
  }
  return switch (a.status) {
    UsageStatus.ok || UsageStatus.unknown => null,
    UsageStatus.warning => (text: 'Running low', dim: false, tone: _Tone.warn),
    UsageStatus.limited => (text: 'Limit reached', dim: false, tone: _Tone.bad),
    UsageStatus.unavailable => (
      text: 'Unavailable',
      dim: true,
      tone: _Tone.muted,
    ),
    UsageStatus.error => (text: 'No data', dim: true, tone: _Tone.muted),
    UsageStatus.disabled => (text: 'Disabled', dim: true, tone: _Tone.muted),
    UsageStatus.expired => (text: 'Expired', dim: true, tone: _Tone.bad),
  };
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.state});
  final ({String text, bool dim, _Tone tone}) state;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final colour = switch (state.tone) {
      _Tone.warn => t.warning,
      _Tone.bad => t.danger,
      _Tone.muted => t.textMuted,
    };
    return Container(
      key: ValueKey('usage-status-${state.text}'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(state.text, style: t.label.copyWith(color: colour)),
    );
  }
}

/// Grows and fades in when first built; shrinks and fades out when
/// [visible] turns false, then calls [onGone]. Instant with reduced motion.
class _Presence extends StatefulWidget {
  const _Presence({
    super.key,
    required this.visible,
    required this.child,
    this.onGone,
  });

  final bool visible;
  final Widget child;
  final VoidCallback? onGone;

  @override
  State<_Presence> createState() => _PresenceState();
}

class _PresenceState extends State<_Presence>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  late final _curve = CurvedAnimation(parent: _c, curve: Motion.standard);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _c.duration = Motion.of(context, const Duration(milliseconds: 280));
    if (widget.visible && _c.status == AnimationStatus.dismissed) {
      unawaited(_c.forward());
    }
  }

  @override
  void didUpdateWidget(_Presence old) {
    super.didUpdateWidget(old);
    if (widget.visible == old.visible) return;
    if (widget.visible) {
      unawaited(_c.forward());
    } else {
      unawaited(
        _c.reverse().whenComplete(() {
          if (mounted && !widget.visible) widget.onGone?.call();
        }),
      );
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    excluding: !widget.visible,
    child: SizeTransition(
      sizeFactor: _curve,
      alignment: Alignment.topCenter,
      child: FadeTransition(opacity: _curve, child: widget.child),
    ),
  );
}
