import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../markdown/hermes_markdown.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'checklist_store.dart';
import 'scope.dart';
import 'ui_model.dart';

/// A `checklist` (or `plan`) block: a progress header, then numbered
/// sections with an icon, a time range and checkbox items.
///
/// It reads as part of the reply: no fill, the reply's own text styles, one
/// very light outline around the whole list, thin dividers between
/// sections; the theme accent only on progress and ticked boxes.
///
/// Ticks persist per message through [ChecklistScope] (this device, plus
/// the bridge's synced settings when available) when the message has a
/// [HermesUiScope.stateKey]; otherwise they live in the widget.
class UiChecklistView extends StatefulWidget {
  const UiChecklistView({
    super.key,
    required this.element,
    required this.style,
  });

  final UiChecklist element;
  final MarkdownStyle style;

  /// Icons for the section names a block may use.
  static IconData iconFor(String? name) => switch (name) {
    'focus' => Icons.psychology_outlined,
    'work' => Icons.work_outline_rounded,
    'rest' || 'evening' => Icons.bedtime_outlined,
    'morning' => Icons.wb_sunny_outlined,
    'home' => Icons.home_outlined,
    'health' => Icons.fitness_center_rounded,
    'food' => Icons.restaurant_outlined,
    'learn' => Icons.school_outlined,
    'code' => Icons.code_rounded,
    'travel' => Icons.flight_takeoff_rounded,
    'money' => Icons.payments_outlined,
    'social' => Icons.groups_outlined,
    'errands' => Icons.shopping_bag_outlined,
    'homelab' => Icons.dns_outlined,
    'calendar' => Icons.event_outlined,
    'call' => Icons.call_outlined,
    'mail' => Icons.mail_outline_rounded,
    'idea' => Icons.lightbulb_outline_rounded,
    'star' => Icons.star_outline_rounded,
    _ => Icons.checklist_rounded,
  };

  @override
  State<UiChecklistView> createState() => _UiChecklistViewState();
}

class _UiChecklistViewState extends State<UiChecklistView> {
  Set<String>? _local;
  ChecklistStore? _store;
  String? _key;

  UiChecklist get e => widget.element;

  Set<String> get _defaults => {
    for (final (i, s) in e.sections.indexed)
      for (final (j, it) in s.items.indexed)
        if (it.done) UiChecklist.itemKey(i, j),
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store = ChecklistScope.maybeOf(context);
    final msg = HermesUiScope.maybeOf(context)?.stateKey;
    _key = msg == null ? null : '$msg#${e.id ?? UiBlockOrdinal.of(context)}';
  }

  Set<String> get _done {
    final key = _key;
    if (key != null && _store != null) {
      return _store!.doneFor(key) ?? _local ?? _defaults;
    }
    return _local ?? _defaults;
  }

  void _toggle(String item) {
    final next = Set.of(_done);
    if (!next.remove(item)) next.add(item);
    UiActionHandler.of(context).selectionHaptic();
    setState(() => _local = next);
    final key = _key;
    if (key != null) _store?.setDone(key, next);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.style;
    final t = HermesTokens.of(context);
    final done = _done;
    final total = e.total;
    final count = done.length.clamp(0, total);
    final all = total > 0 && count == total;
    final caption = e.title ?? 'Tasks completed';
    final children = <Widget>[
      Semantics(
        liveRegion: true,
        label: '$count of $total ${caption.toLowerCase()}',
        excludeSemantics: true,
        child: _Header(
          count: count,
          total: total,
          caption: all && e.title == null ? 'All done' : caption,
          complete: all,
          style: s,
          accent: t.accent,
        ),
      ),
    ];
    for (final (i, sec) in e.sections.indexed) {
      children.add(Divider(height: 1, thickness: 1, color: s.hairline));
      children.add(
        _Section(
          index: i,
          section: sec,
          numbered: e.numbered,
          done: done,
          onToggle: _toggle,
          style: s,
          accent: t.accent,
          onAccent: t.onAccent,
        ),
      );
    }
    return Container(
      key: const ValueKey('ui-checklist'),
      decoration: BoxDecoration(
        border: Border.all(color: s.outline),
        borderRadius: BorderRadius.circular(s.frameRadius + 4),
      ),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.count,
    required this.total,
    required this.caption,
    required this.complete,
    required this.style,
    required this.accent,
  });

  final int count, total;
  final String caption;
  final bool complete;
  final MarkdownStyle style;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final dur = Motion.of(context, const Duration(milliseconds: 420));
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '$count/$total',
                        style: s.h3.copyWith(color: s.text),
                      ),
                      const TextSpan(text: '  '),
                      TextSpan(text: caption, style: s.caption),
                    ],
                  ),
                ),
              ),
              AnimatedSwitcher(
                duration: dur,
                transitionBuilder: (child, a) => ScaleTransition(
                  scale: CurvedAnimation(parent: a, curve: Motion.pop),
                  child: FadeTransition(opacity: a, child: child),
                ),
                child: Icon(
                  complete
                      ? Icons.check_circle_rounded
                      : Icons.track_changes_rounded,
                  key: ValueKey(complete),
                  size: 24,
                  color: complete ? accent : s.text,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TweenAnimationBuilder<double>(
            tween: Tween(end: total == 0 ? 0 : count / total),
            duration: dur,
            curve: Motion.emphasizedDecel,
            builder: (context, v, _) => ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 6,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(color: s.hairline),
                    FractionallySizedBox(
                      alignment: AlignmentDirectional.centerStart,
                      widthFactor: v.clamp(0.0, 1.0),
                      child: ColoredBox(color: accent),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.index,
    required this.section,
    required this.numbered,
    required this.done,
    required this.onToggle,
    required this.style,
    required this.accent,
    required this.onAccent,
  });

  final int index;
  final UiCheckSection section;
  final bool numbered;
  final Set<String> done;
  final ValueChanged<String> onToggle;
  final MarkdownStyle style;
  final Color accent, onAccent;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final title = section.title;
    final hasHead = title != null || section.time != null;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasHead)
            Semantics(
              header: true,
              child: Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(
                        UiChecklistView.iconFor(section.icon),
                        size: 22,
                        color: s.text,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (title != null)
                            Text(
                              numbered ? '${index + 1}. $title' : title,
                              style: s.bodyStrong,
                            ),
                          if (section.time != null)
                            Text(section.time!, style: s.caption),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          for (final (j, it) in section.items.indexed)
            _ItemRow(
              key: ValueKey('check-$index.$j'),
              label: it.label,
              done: done.contains(UiChecklist.itemKey(index, j)),
              onTap: () => onToggle(UiChecklist.itemKey(index, j)),
              style: s,
              accent: accent,
              onAccent: onAccent,
            ),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    super.key,
    required this.label,
    required this.done,
    required this.onTap,
    required this.style,
    required this.accent,
    required this.onAccent,
  });

  final String label;
  final bool done;
  final VoidCallback onTap;
  final MarkdownStyle style;
  final Color accent, onAccent;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final dur = Motion.of(context, const Duration(milliseconds: 240));
    return MergeSemantics(
      child: Semantics(
        checked: done,
        label: label,
        onTap: onTap,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  CheckCircle(
                    checked: done,
                    accent: accent,
                    onAccent: onAccent,
                    outline: s.textMuted,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: AnimatedDefaultTextStyle(
                      duration: dur,
                      style: s.body.copyWith(
                        color: done ? s.textMuted : s.text,
                        decoration: done
                            ? TextDecoration.lineThrough
                            : TextDecoration.none,
                        decorationColor: s.textMuted,
                      ),
                      child: Text(label),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A 24 dp round checkbox: an outline ring, then on ticking a filled accent
/// disc that pops (overshoot) while the check mark draws itself.
class CheckCircle extends StatefulWidget {
  const CheckCircle({
    super.key,
    required this.checked,
    required this.accent,
    required this.onAccent,
    required this.outline,
    this.size = 24,
  });

  final bool checked;
  final Color accent, onAccent, outline;
  final double size;

  @override
  State<CheckCircle> createState() => _CheckCircleState();
}

class _CheckCircleState extends State<CheckCircle>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    value: widget.checked ? 1 : 0,
  );

  @override
  void didUpdateWidget(CheckCircle old) {
    super.didUpdateWidget(old);
    if (old.checked == widget.checked) return;
    if (Motion.reduced(context)) {
      _c.value = widget.checked ? 1 : 0;
    } else if (widget.checked) {
      _c.forward(from: 0);
    } else {
      _c.reverse();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      size: Size.square(widget.size),
      painter: _CheckPainter(
        _c,
        accent: widget.accent,
        onAccent: widget.onAccent,
        outline: widget.outline,
      ),
    ),
  );
}

class _CheckPainter extends CustomPainter {
  _CheckPainter(
    this.t, {
    required this.accent,
    required this.onAccent,
    required this.outline,
  }) : super(repaint: t);

  final Animation<double> t;
  final Color accent, onAccent, outline;

  @override
  void paint(Canvas canvas, Size size) {
    final v = t.value;
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    // The ring fades as the disc grows.
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = outline.withValues(alpha: outline.a * (1 - v).clamp(0.4, 1));
    canvas.drawCircle(c, r - 0.75, ring);
    if (v <= 0) return;
    // Disc: 0 → 1.12 → 1 over the first 60 %.
    final grow = (v / 0.6).clamp(0.0, 1.0);
    final scale = Motion.pop.transform(grow);
    canvas.drawCircle(c, r * math.min(scale, 1.12), Paint()..color = accent);
    // Check: drawn over the last 55 %.
    final draw = ((v - 0.45) / 0.55).clamp(0.0, 1.0);
    if (draw <= 0) return;
    final a = Offset(size.width * 0.28, size.height * 0.53);
    final b = Offset(size.width * 0.44, size.height * 0.68);
    final d = Offset(size.width * 0.73, size.height * 0.36);
    final l1 = (b - a).distance, l2 = (d - b).distance;
    final len = (l1 + l2) * Curves.easeOut.transform(draw);
    final path = Path()..moveTo(a.dx, a.dy);
    if (len <= l1) {
      final p = Offset.lerp(a, b, len / l1)!;
      path.lineTo(p.dx, p.dy);
    } else {
      final p = Offset.lerp(b, d, (len - l1) / l2)!;
      path
        ..lineTo(b.dx, b.dy)
        ..lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = onAccent,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) =>
      old.accent != accent ||
      old.onAccent != onAccent ||
      old.outline != outline;
}

/// The streaming placeholder for a checklist: the header, the bar and three
/// rows in the block's shape, so the reply does not jump when it arrives.
class UiChecklistSkeleton extends StatelessWidget {
  const UiChecklistSkeleton({super.key, required this.style});
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final s = style;
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: s.hairline,
        borderRadius: BorderRadius.circular(h / 2),
      ),
    );
    return Container(
      key: const ValueKey('ui-checklist-skeleton'),
      decoration: BoxDecoration(
        border: Border.all(color: s.outline),
        borderRadius: BorderRadius.circular(s.frameRadius + 4),
      ),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [bar(44, 18), const SizedBox(width: 10), bar(110, 12)]),
          const SizedBox(height: 16),
          bar(double.infinity, 6),
          const SizedBox(height: 20),
          for (final w in [0.62, 0.48, 0.55]) ...[
            Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: s.hairline, width: 1.5),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: FractionallySizedBox(
                    alignment: AlignmentDirectional.centerStart,
                    widthFactor: w,
                    child: bar(double.infinity, 12),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }
}
