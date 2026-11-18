import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

import '../theme/motion.dart';
import '../theme/render_policy.dart';
import '../feedback.dart';
import '../theme/tokens.dart';

enum PopoverAlign { start, end }

/// Shows an anchored popover menu (§5.8, §6.6): above [anchor] by default,
/// radius 24, frosted, at most 60 % of the screen tall. It opens with a
/// scale from the anchor corner and closes with a fade. Focus is trapped in
/// the popover and returns to the anchor afterwards.
Future<T?> showPopover<T>({
  required BuildContext anchor,
  required WidgetBuilder builder,
  double width = 232,
  PopoverAlign align = PopoverAlign.start,
  double gap = 8,
  bool above = true,
  Rect? anchorRect,
  String label = 'Menu',

  /// False keeps focus (and the keyboard) where it is, for the plus menu
  /// opened from a focused field (§4.6).
  bool takeFocus = true,
}) async {
  final nav = Navigator.of(anchor);
  // Every menu opens with a light tap (round 6).
  FeedbackScope.haptic(anchor, Haptic.light);
  final overlay = nav.overlay!.context.findRenderObject()! as RenderBox;
  Rect rect;
  if (anchorRect != null) {
    rect = anchorRect;
  } else {
    final box = anchor.findRenderObject()! as RenderBox;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    rect = topLeft & box.size;
  }
  final focus = FocusManager.instance.primaryFocus;
  final result = await nav.push<T>(
    _PopoverRoute<T>(
      anchor: rect,
      width: width,
      align: align,
      gap: gap,
      above: above,
      builder: builder,
      reduced: Motion.reduced(anchor),
      label: label,
      takeFocus: takeFocus,
    ),
  );
  if (focus != null && focus.context != null && focus.canRequestFocus) {
    focus.requestFocus();
  }
  return result;
}

class _PopoverRoute<T> extends PopupRoute<T> {
  _PopoverRoute({
    required this.anchor,
    required this.width,
    required this.align,
    required this.gap,
    required this.above,
    required this.builder,
    required this.reduced,
    required this.label,
    required this.takeFocus,
  }) : super(requestFocus: takeFocus);

  final bool takeFocus;
  final Rect anchor;
  final double width;
  final PopoverAlign align;
  final double gap;
  final bool above;
  final WidgetBuilder builder;
  final bool reduced;
  final String label;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Close $label';

  @override
  Duration get transitionDuration =>
      reduced ? Duration.zero : const Duration(milliseconds: 180);

  @override
  Duration get reverseTransitionDuration =>
      reduced ? Duration.zero : const Duration(milliseconds: 120);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return CustomSingleChildLayout(
      delegate: _PopoverLayout(
        anchor: anchor,
        width: width,
        align: align,
        gap: gap,
        above: above,
        padding: MediaQuery.paddingOf(context),
      ),
      child: _PopoverPanel(
        animation: animation,
        above: above,
        align: align,
        label: label,
        autofocus: takeFocus,
        child: Builder(builder: builder),
      ),
    );
  }
}

class _PopoverLayout extends SingleChildLayoutDelegate {
  _PopoverLayout({
    required this.anchor,
    required this.width,
    required this.align,
    required this.gap,
    required this.above,
    required this.padding,
  });

  final Rect anchor;
  final double width;
  final PopoverAlign align;
  final double gap;
  final bool above;
  final EdgeInsets padding;
  static const _margin = 8.0;

  bool _fitsAbove(Size size, double h) =>
      anchor.top - gap - h >= padding.top + _margin;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) {
    final room = above
        ? anchor.top - gap - padding.top - _margin
        : c.maxHeight - anchor.bottom - gap - padding.bottom - _margin;
    final maxH = math.min(c.maxHeight * 0.6, math.max(room, c.maxHeight * 0.3));
    return BoxConstraints(
      minWidth: math.min(width, c.maxWidth - 2 * _margin),
      maxWidth: math.min(width, c.maxWidth - 2 * _margin),
      maxHeight: maxH,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size child) {
    var x = align == PopoverAlign.start
        ? anchor.left
        : anchor.right - child.width;
    x = x.clamp(_margin, size.width - child.width - _margin).toDouble();
    double y;
    if (above && _fitsAbove(size, child.height)) {
      y = anchor.top - gap - child.height;
    } else if (above) {
      y = math.max(padding.top + _margin, anchor.top - gap - child.height);
    } else {
      y = anchor.bottom + gap;
    }
    y = y
        .clamp(
          padding.top + _margin,
          math.max(padding.top + _margin, size.height - child.height - _margin),
        )
        .toDouble();
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_PopoverLayout old) =>
      old.anchor != anchor || old.width != width || old.padding != padding;
}

class _PopoverPanel extends StatelessWidget {
  const _PopoverPanel({
    required this.animation,
    required this.above,
    required this.align,
    required this.label,
    required this.child,
    this.autofocus = true,
  });

  final bool autofocus;
  final Animation<double> animation;
  final bool above;
  final PopoverAlign align;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final blur = RenderPolicyScope.of(context).blur;
    final radius = BorderRadius.circular(Rad.menu);
    Widget panel = DecoratedBox(
      decoration: BoxDecoration(
        color: blur ? t.sheet : t.sheetFallback,
        borderRadius: radius,
        border: Border.all(color: t.outline, width: 0.5),
        boxShadow: t.dark
            ? null
            : const [
                BoxShadow(
                  color: Color(0x1F000000),
                  blurRadius: 32,
                  offset: Offset(0, 8),
                ),
              ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ClipRRect(
          borderRadius: radius,
          child: _ScrollablePanel(child: child),
        ),
      ),
    );
    if (blur) {
      panel = ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: panel,
        ),
      );
    }
    final origin = Alignment(
      align == PopoverAlign.start ? -1 : 1,
      above ? 1 : -1,
    );
    final opening = CurvedAnimation(
      parent: animation,
      curve: Motion.emphasizedDecel,
      reverseCurve: Curves.linear,
    );
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: label,
      child: FocusScope(
        autofocus: autofocus,
        child: AnimatedBuilder(
          animation: opening,
          child: panel,
          builder: (context, child) {
            // Close: opacity only (§6.6).
            final closing = animation.status == AnimationStatus.reverse;
            return FadeTransition(
              opacity: opening,
              child: closing
                  ? child
                  : Transform.scale(
                      scale: 0.92 + 0.08 * opening.value,
                      alignment: origin,
                      child: child,
                    ),
            );
          },
        ),
      ),
    );
  }
}

class _ScrollablePanel extends StatefulWidget {
  const _ScrollablePanel({required this.child});
  final Widget child;

  @override
  State<_ScrollablePanel> createState() => _ScrollablePanelState();
}

class _ScrollablePanelState extends State<_ScrollablePanel> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
    controller: _scroll,
    child: SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: widget.child,
    ),
  );
}

/// A row in a popover. [height] is 40 for dropdowns and 48 for the plus menu.
class PopoverItem extends StatelessWidget {
  const PopoverItem({
    super.key,
    required this.label,
    this.icon,
    this.checked = false,
    this.onTap,
    this.trailing,
    this.height = 40,
    this.subtitle,
    this.index = 0,
    this.stagger = false,
    this.chip = false,
    this.destructive = false,
  });

  final String label;
  final IconData? icon;
  final bool checked;

  /// Drawn in the error colour (Delete, last in its menu).
  final bool destructive;
  final VoidCallback? onTap;
  final Widget? trailing;
  final double height;
  final String? subtitle;

  /// Position for the row stagger (plus menu: 20 ms per row, +6 → 0 dp).
  final int index;
  final bool stagger;

  /// Draws the icon inside a 32 dp circular chip.
  final bool chip;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final enabled = onTap != null;
    final fg = !enabled
        ? t.textFaint
        : destructive
        ? t.danger
        : t.text;
    Widget? lead;
    if (icon != null) {
      lead = chip
          ? Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: t.surfaceHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 18, color: fg),
            )
          : Icon(icon, size: 20, color: fg);
    }
    Widget row = Semantics(
      button: true,
      enabled: enabled,
      selected: checked,
      child: InkWell(
        onTap: onTap,
        highlightColor: t.surfaceHigh,
        splashColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: math.max(height, 40)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Row(
              children: [
                if (lead != null) ...[lead, const SizedBox(width: 12)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: t.row.copyWith(
                          color: fg,
                          fontSize: chip ? 15 : 16,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: t.label
                              .copyWith(color: t.textFaint)
                              .hermesWeight(400),
                        ),
                    ],
                  ),
                ),
                if (trailing != null)
                  IconTheme.merge(
                    data: IconThemeData(color: t.textMuted, size: 20),
                    child: trailing!,
                  )
                else if (checked)
                  Icon(Icons.check_rounded, size: 20, color: t.text),
              ],
            ),
          ),
        ),
      ),
    );
    if (!stagger) return row;
    final route = ModalRoute.of(context);
    final a = route?.animation;
    if (a == null || Motion.reduced(context)) return row;
    final start = math.min(0.6, index * 20 / 180);
    final c = CurvedAnimation(
      parent: a,
      curve: Interval(start, 1, curve: Motion.emphasizedDecel),
    );
    return AnimatedBuilder(
      animation: c,
      child: row,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, 6 * (1 - c.value)),
        child: child,
      ),
    );
  }
}
