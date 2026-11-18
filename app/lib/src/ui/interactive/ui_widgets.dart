/// Native widgets for hermes-ui elements (chat-rendering-v2 §3.5, §3.8).
/// Only theme surfaces, greys, white and tone colours on glyphs and values.
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../markdown/hermes_markdown.dart';
import '../shell/drawer_swipe.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'format.dart';
import 'scope.dart';
import 'html_view.dart';
import 'ui_checklist.dart';
import 'ui_dashboard.dart';
import 'ui_model.dart';
import 'ui_entities.dart';
import 'ui_slider.dart';

/// Renders a validated element.
class UiElementView extends StatelessWidget {
  const UiElementView({super.key, required this.element, this.style});

  final UiElement element;
  final MarkdownStyle? style;

  @override
  Widget build(BuildContext context) {
    final s = style ?? MarkdownStyle.of(context);
    return switch (element) {
      final UiOptions e => UiOptionsView(element: e, style: s),
      final UiActions e => UiActionsView(element: e, style: s),
      final UiCards e => UiCardsView(cards: e.items, style: s),
      final UiCalc e => UiCalcView(element: e, style: s),
      final UiDetails e => UiDetailsView(
        title: e.title,
        initiallyOpen: e.open,
        style: s,
        body: NoNestedUiBlocks(
          child: HermesMarkdown(text: e.body, style: s),
        ),
      ),
      final UiCallout e => UiCalloutView(element: e, style: s),
      // Lifted out of the message and shown under its action row.
      UiSuggestions() => const SizedBox.shrink(),
      final UiGroup e => _Group(element: e, style: s),
      final UiEntities e => UiEntitiesView(element: e, style: s),
      final UiNews e => UiNewsView(element: e, style: s),
      final UiChecklist e => UiChecklistView(element: e, style: s),
      final UiStatus e => UiStatusView(element: e, style: s),
      final UiMetrics e => UiMetricsView(element: e, style: s),
      final UiGauges e => UiGaugesView(element: e, style: s),
      final UiServices e => UiServicesView(element: e, style: s),
      final UiAlerts e => UiAlertsView(element: e, style: s),
      final UiChart e => UiChartView(element: e, style: s),
      final UiHtml e => HermesHtml(source: e.html, style: s),
    };
  }
}

Color toneColor(UiTone t, MarkdownStyle s) => switch (t) {
  UiTone.good => s.success,
  UiTone.warn => s.warning,
  UiTone.bad => s.danger,
  UiTone.tip => s.warning,
  UiTone.neutral || UiTone.info => s.text,
};

// ------------------------------------------------------------------ pills

/// The stadium chip/button shared by options, actions and segments.
class UiPill extends StatefulWidget {
  const UiPill({
    super.key,
    required this.label,
    required this.style,
    this.onTap,
    this.selected = false,
    this.primary = false,
    this.dimmed = false,
    this.leading,
    this.trailing,
    this.height = 40,
    this.horizontalPadding = 16,
    this.semanticsSelected,
    this.semanticsHint,
    this.quiet = false,
  });

  /// No fill when unselected (the chat background and the outline only),
  /// for controls inside blocks that blend with the reply.
  final bool quiet;

  final String label;
  final MarkdownStyle style;
  final VoidCallback? onTap;
  final bool selected, primary, dimmed;
  final IconData? leading, trailing;
  final double height, horizontalPadding;

  /// For radio/checkbox semantics; null for a plain button.
  final bool? semanticsSelected;
  final String? semanticsHint;

  @override
  State<UiPill> createState() => _UiPillState();
}

class _UiPillState extends State<UiPill> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final s = w.style;
    final filled = w.selected || w.primary;
    final fill = w.primary
        ? s.closeFill
        : w.selected
        ? s.text
        : _down
        ? s.surfaceHigh
        : w.quiet
        ? Colors.transparent
        : s.surface;
    final fg = w.primary
        ? s.onClose
        : w.selected
        ? s.background
        : s.text;
    final ts = (w.primary ? s.control.hermesWeight(600) : s.control).copyWith(
      color: fg,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final icon = scaler.scale(16);
    final dur = Motion.of(context, const Duration(milliseconds: 90));
    Widget pill = AnimatedContainer(
      duration: dur,
      constraints: BoxConstraints(minHeight: w.height),
      padding: EdgeInsets.symmetric(
        horizontal: w.horizontalPadding,
        vertical: 6,
      ),
      decoration: ShapeDecoration(
        color: fill,
        shape: StadiumBorder(
          side: filled
              ? BorderSide.none
              : BorderSide(color: s.outline, width: 1),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (w.leading != null) ...[
            Icon(w.leading, size: icon, color: fg),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(w.label, style: ts, textAlign: TextAlign.center),
          ),
          if (w.trailing != null) ...[
            const SizedBox(width: 6),
            Icon(w.trailing, size: icon, color: fg.withValues(alpha: 0.8)),
          ],
        ],
      ),
    );
    pill = AnimatedScale(scale: _down ? 0.97 : 1, duration: dur, child: pill);
    pill = AnimatedOpacity(
      opacity: w.dimmed ? 0.4 : (w.onTap == null && !w.selected ? 0.6 : 1),
      duration: dur,
      child: pill,
    );
    final enabled = w.onTap != null;
    return Semantics(
      button: w.semanticsSelected == null,
      inMutuallyExclusiveGroup: false,
      checked: w.semanticsSelected,
      enabled: enabled,
      hint: w.semanticsHint,
      label: w.label,
      excludeSemantics: true,
      onTap: w.onTap,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              w.onTap?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => setState(() => _down = true) : null,
          onTapUp: enabled ? (_) => setState(() => _down = false) : null,
          onTapCancel: enabled ? () => setState(() => _down = false) : null,
          onTap: w.onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Align(widthFactor: 1, heightFactor: 1, child: pill),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- options

class UiOptionsView extends StatefulWidget {
  const UiOptionsView({super.key, required this.element, required this.style});
  final UiOptions element;
  final MarkdownStyle style;

  @override
  State<UiOptionsView> createState() => _UiOptionsViewState();
}

class _UiOptionsViewState extends State<UiOptionsView> {
  final _picked = <int>{};
  String? _sent;

  bool _matches(UiOption o, String msg) {
    final m = msg.trim();
    if (o.send.trim() == m || o.label.trim() == m) return true;
    if (!widget.element.many) return false;
    final parts = m
        .split(RegExp(r'\n|, '))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty);
    return parts.any((p) => p == o.send.trim() || p == o.label.trim());
  }

  String _joined() {
    final chosen = [
      for (final i in _picked.toList()..sort()) widget.element.options[i],
    ];
    if (chosen.every((o) => o.send == o.label)) {
      return chosen.map((o) => o.label).join(', ');
    }
    return chosen.map((o) => o.send).join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.element;
    final s = widget.style;
    final actions = UiActionHandler.of(context);
    final answer = actions.nextUserMessage ?? _sent;
    final locked = answer != null;
    final chosen = <int>{
      if (answer != null)
        for (var i = 0; i < e.options.length; i++)
          if (_matches(e.options[i], answer)) i,
    };

    void send(String text) {
      if (_sent != null) return; // a second tap inside the same frame
      setState(() => _sent = text);
      actions.send(text);
    }

    final chips = <Widget>[
      for (var i = 0; i < e.options.length; i++)
        UiPill(
          label: e.options[i].label,
          style: s,
          selected: locked ? chosen.contains(i) : _picked.contains(i),
          leading: (locked ? chosen.contains(i) : _picked.contains(i))
              ? Icons.check_rounded
              : null,
          dimmed: locked && !chosen.contains(i),
          semanticsSelected: locked
              ? chosen.contains(i)
              : (e.many ? _picked.contains(i) : false),
          onTap: locked || !actions.canSend
              ? null
              : () {
                  if (e.many) {
                    setState(
                      () => _picked.contains(i)
                          ? _picked.remove(i)
                          : _picked.add(i),
                    );
                  } else {
                    send(e.options[i].send);
                  }
                },
        ),
      if (e.other && !locked)
        UiPill(
          label: 'Other…',
          style: s,
          semanticsHint: 'Type your own answer',
          onTap: actions.canFocusComposer ? actions.focusComposer : null,
        ),
    ];
    return Semantics(
      container: true,
      label: e.prompt,
      explicitChildNodes: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (e.prompt != null) ...[
            Text(e.prompt!, style: s.bodyStrong),
            const SizedBox(height: 8),
          ],
          Wrap(spacing: 8, runSpacing: 0, children: chips),
          if (e.many && !locked) ...[
            const SizedBox(height: 4),
            UiPill(
              label: 'Send',
              style: s,
              primary: true,
              onTap: _picked.isEmpty || !actions.canSend
                  ? null
                  : () => send(_joined()),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- actions

class UiActionsView extends StatefulWidget {
  const UiActionsView({super.key, required this.element, required this.style});
  final UiActions element;
  final MarkdownStyle style;

  @override
  State<UiActionsView> createState() => _UiActionsViewState();
}

class _UiActionsViewState extends State<UiActionsView> {
  final _sent = <int>{};
  int? _copied;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.style;
    final actions = UiActionHandler.of(context);
    final items = widget.element.items;
    return Wrap(
      spacing: 8,
      children: [
        for (var i = 0; i < items.length; i++)
          () {
            final b = items[i];
            final a = b.action;
            final sentLater =
                a.send != null &&
                actions.nextUserMessage?.trim() == a.send!.trim();
            final lockedSend =
                a.send != null &&
                (_sent.contains(i) || actions.nextUserMessage != null);
            VoidCallback? onTap;
            if (a.send != null) {
              onTap = lockedSend || !actions.canSend
                  ? null
                  : () {
                      // Two taps inside one frame must not send twice.
                      if (_sent.contains(i)) return;
                      setState(() => _sent.add(i));
                      actions.send(a.send!);
                    };
            } else if (a.link != null) {
              onTap = () => actions.openLink(a.link!);
            } else {
              onTap = () {
                actions.copy(a.copy!);
                setState(() => _copied = i);
                _reset?.cancel();
                _reset = Timer(const Duration(milliseconds: 1500), () {
                  if (mounted) setState(() => _copied = null);
                });
              };
            }
            return UiPill(
              label: b.label,
              style: s,
              primary: b.primary && !lockedSend,
              selected: lockedSend && (_sent.contains(i) || sentLater),
              dimmed: lockedSend && !(_sent.contains(i) || sentLater),
              height: 44,
              horizontalPadding: 18,
              trailing: a.link != null
                  ? Icons.north_east_rounded
                  : a.copy != null
                  ? (_copied == i ? Icons.check_rounded : Icons.copy_rounded)
                  : null,
              semanticsHint: a.link != null
                  ? 'Opens a link'
                  : a.copy != null
                  ? 'Copies text'
                  : 'Sends "${a.send}"',
              onTap: onTap,
            );
          }(),
      ],
    );
  }
}

// ------------------------------------------------------------------ cards

class UiCardsView extends StatelessWidget {
  const UiCardsView({super.key, required this.cards, required this.style});
  final List<UiCard> cards;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final perRow = c.maxWidth < 600
            ? (cards.length < 2 ? cards.length : 2)
            : cards.length.clamp(1, 4);
        // Blend rule: no boxes; a hairline above each row groups the stats
        // like a table.
        final rule = Divider(height: 1, thickness: 1, color: style.hairline);
        final rows = <Widget>[];
        for (var i = 0; i < cards.length; i += perRow) {
          rows.add(rule);
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var j = 0; j < perRow; j++) ...[
                    if (j > 0) const SizedBox(width: 12),
                    Expanded(
                      child: i + j < cards.length
                          ? _Card(card: cards[i + j], style: style)
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.card, required this.style});
  final UiCard card;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final s = style;
    return Semantics(
      container: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(card.label, style: s.statLabel),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                card.value,
                maxLines: 1,
                style: s.statValue.copyWith(
                  color: toneColor(card.tone, s),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            if (card.sub != null) ...[
              const SizedBox(height: 4),
              Text(card.sub!, style: s.statLabel),
            ],
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------- calc

class UiCalcView extends StatefulWidget {
  const UiCalcView({super.key, required this.element, required this.style});
  final UiCalc element;
  final MarkdownStyle style;

  @override
  State<UiCalcView> createState() => _UiCalcViewState();
}

class _UiCalcViewState extends State<UiCalcView> {
  late Map<String, double> _values = {
    for (final i in widget.element.inputs) i.id: i.value,
  };
  Duration? _lastHaptic;
  final _clock = Stopwatch()..start();

  @override
  void didUpdateWidget(UiCalcView old) {
    super.didUpdateWidget(old);
    if (!identical(old.element, widget.element)) {
      _values = {
        for (final i in widget.element.inputs) i.id: _values[i.id] ?? i.value,
      };
    }
  }

  void _set(String id, double v, {bool haptic = false}) {
    if (_values[id] == v) return;
    setState(() => _values[id] = v);
    if (haptic) {
      final now = _clock.elapsed;
      if (_lastHaptic == null ||
          now - _lastHaptic! >= const Duration(milliseconds: 40)) {
        _lastHaptic = now;
        UiActionHandler.of(context).selectionHaptic();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.element;
    final s = widget.style;
    final children = <Widget>[];
    for (final input in e.inputs) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 12));
      children.add(_input(input, s));
    }
    children.add(const SizedBox(height: 16));
    children.add(
      UiCardsView(
        style: s,
        cards: [
          for (final o in e.outputs)
            UiCard(
              label: o.label,
              value: formatUiValue(o.expr.eval(_values), o.format),
              sub: o.sub,
              tone: o.tone,
            ),
        ],
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _input(UiInput i, MarkdownStyle s) {
    final v = _values[i.id] ?? i.value;
    final shown = i.kind == UiInputKind.segmented
        ? (i.format == null
              ? i.segments
                    .firstWhere(
                      (g) => g.value == v,
                      orElse: () => i.segments.first,
                    )
                    .label
              : formatUiValue(v, i.format))
        : i.kind == UiInputKind.toggle
        ? (i.format == null
              ? (v != 0 ? 'On' : 'Off')
              : formatUiValue(v, i.format))
        : formatUiValue(v, i.format);
    final Widget header;
    if (i.kind == UiInputKind.toggle) {
      header = Row(
        children: [
          Expanded(child: Text(i.label, style: s.widgetLabel)),
          const SizedBox(width: 12),
          Switch(
            value: v != 0,
            onChanged: (on) => _set(i.id, on ? 1 : 0),
            activeTrackColor: s.text,
            activeThumbColor: s.background,
            inactiveTrackColor: s.surfaceHigh,
            inactiveThumbColor: s.textMuted,
            trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
          ),
        ],
      );
    } else {
      // Label left, live value right; the value drops under the label when
      // both do not fit (large text).
      header = SizedBox(
        width: double.infinity,
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          children: [
            Text(i.label, style: s.widgetLabel),
            ExcludeSemantics(
              child: Text(
                shown,
                style: s.widgetLabel.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      );
    }
    switch (i.kind) {
      case UiInputKind.toggle:
        return Semantics(toggled: v != 0, label: i.label, child: header);
      case UiInputKind.slider:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            UiSlider(
              value: v,
              min: i.min,
              max: i.max,
              step: i.step,
              active: s.text,
              inactive: s.text.withValues(alpha: 0.12),
              thumbFill: s.background,
              thumbRing: s.text.withValues(alpha: 0.3),
              semanticLabel: i.label,
              semanticValue: shown,
              onChanged: (nv) => _set(i.id, nv, haptic: true),
            ),
          ],
        );
      case UiInputKind.stepper:
        Widget btn(IconData icon, String label, double next) {
          final ok = next >= i.min && next <= i.max;
          return Semantics(
            button: true,
            label: label,
            enabled: ok,
            excludeSemantics: true,
            child: SizedBox(
              width: 48,
              height: 48,
              child: Center(
                child: Material(
                  type: MaterialType.transparency,
                  shape: CircleBorder(side: BorderSide(color: s.outline)),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: ok ? () => _set(i.id, next, haptic: true) : null,
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: Icon(
                        icon,
                        size: 20,
                        color: ok ? s.text : s.textMuted.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        final down = ((v - i.step) * 1e9).round() / 1e9;
        final up = ((v + i.step) * 1e9).round() / 1e9;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            const SizedBox(height: 4),
            Row(
              children: [
                btn(Icons.remove_rounded, 'Decrease ${i.label}', down),
                const SizedBox(width: 8),
                btn(Icons.add_rounded, 'Increase ${i.label}', up),
              ],
            ),
          ],
        );
      case UiInputKind.segmented:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            const SizedBox(height: 8),
            // Segmented choices never hand a drag to the sidebar swipe.
            DrawerSwipeExclusion(
              child: Wrap(
                spacing: 8,
                children: [
                  for (final g in i.segments)
                    UiPill(
                      label: g.label,
                      style: s,
                      quiet: true,
                      selected: g.value == v,
                      semanticsSelected: g.value == v,
                      onTap: () => _set(i.id, g.value, haptic: true),
                    ),
                ],
              ),
            ),
          ],
        );
    }
  }
}

// ---------------------------------------------------------------- details

/// A collapsible section: a 48 dp header (title in bodyStrong, a chevron
/// that turns 180° over 200 ms) between hairlines; the body expands over
/// 220 ms. Used by hermes-ui `details`, HTML `<details>` and the fallback.
class UiDetailsView extends StatefulWidget {
  const UiDetailsView({
    super.key,
    required this.title,
    required this.body,
    required this.style,
    this.initiallyOpen = false,
    this.titleStyle,
  });

  final String title;
  final Widget body;
  final MarkdownStyle style;
  final bool initiallyOpen;
  final TextStyle? titleStyle;

  @override
  State<UiDetailsView> createState() => _UiDetailsViewState();
}

class _UiDetailsViewState extends State<UiDetailsView> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final s = widget.style;
    final rot = Motion.of(context, const Duration(milliseconds: 200));
    final size = Motion.spatial(context, const Duration(milliseconds: 220));
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: s.hairline),
          bottom: BorderSide(color: s.hairline),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _open,
            child: InkWell(
              onTap: () => setState(() => _open = !_open),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          widget.title,
                          style: widget.titleStyle ?? s.bodyStrong,
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: rot,
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 20,
                        color: s.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: size,
            curve: Motion.spatialCurve(context, Motion.emphasizedDecel),
            alignment: Alignment.topCenter,
            child: _open
                ? Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 12),
                    child: widget.body,
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- callout

class UiCalloutView extends StatelessWidget {
  const UiCalloutView({super.key, required this.element, required this.style});
  final UiCallout element;
  final MarkdownStyle style;

  static IconData glyph(UiTone t) => switch (t) {
    UiTone.tip => Icons.lightbulb_outline_rounded,
    UiTone.warn => Icons.warning_amber_rounded,
    UiTone.bad => Icons.block_rounded,
    UiTone.good => Icons.check_circle_outline_rounded,
    UiTone.info || UiTone.neutral => Icons.info_outline_rounded,
  };

  static String toneName(UiTone t) => switch (t) {
    UiTone.tip => 'Tip',
    UiTone.warn => 'Warning',
    UiTone.bad => 'Important',
    UiTone.good => 'Success',
    UiTone.info || UiTone.neutral => 'Note',
  };

  @override
  Widget build(BuildContext context) {
    final s = style;
    final e = element;
    final c = toneColor(e.tone, s);
    final scaler = MediaQuery.textScalerOf(context);
    final line = scaler.scale(s.body.fontSize ?? 17) * (s.body.height ?? 1.5);
    final g = scaler.scale(18);
    return Semantics(
      container: true,
      label: toneName(e.tone),
      // Blend rule: no box; the tone shows in the glyph and the title.
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(top: ((line - g) / 2).clamp(0, 20)),
              child: Icon(glyph(e.tone), size: g, color: c),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (e.title != null) ...[
                    Text(e.title!, style: s.bodyStrong.copyWith(color: c)),
                    const SizedBox(height: 4),
                  ],
                  NoNestedUiBlocks(
                    child: HermesMarkdown(text: e.body, style: s),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ group

class _Group extends StatelessWidget {
  const _Group({required this.element, required this.style});
  final UiGroup element;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final kids = element.children.where((c) => c is! UiSuggestions).toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (element.title != null) ...[
          Semantics(header: true, child: Text(element.title!, style: style.h2)),
          SizedBox(height: style.headingGapBelow),
        ],
        for (var i = 0; i < kids.length; i++) ...[
          if (i > 0) const SizedBox(height: 16),
          UiElementView(element: kids[i], style: style),
        ],
      ],
    );
  }
}
