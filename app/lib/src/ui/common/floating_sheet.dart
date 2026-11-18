import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/physics.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/motion.dart';
import '../theme/render_policy.dart';
import '../feedback.dart';
import '../theme/tokens.dart';
import 'group_card.dart';

/// One page of a floating sheet. A sheet starts with one page and can push
/// more (Settings → Choose a voice, §4.5).
class SheetPage {
  const SheetPage({
    required this.title,
    required this.builder,
    this.heightFraction,
    this.subtitle,
  });

  final String title;

  /// Builds the page body. Fixed-height pages get a bounded height and
  /// should scroll; others size to their content.
  final WidgetBuilder builder;

  /// Fraction of the screen height (the voice page uses 0.75), or null to
  /// size to the content.
  final double? heightFraction;
  final String? subtitle;
}

/// Presents a floating, inset sheet (§3.5, §4.5, §5.8, §6.6).
Future<T?> showFloatingSheet<T>(
  BuildContext context, {
  required SheetPage page,
  bool live = false,
}) {
  FeedbackScope.haptic(context, Haptic.light);
  return Navigator.of(context).push(
    FloatingSheetRoute<T>(
      page: page,
      live: live,
      reduced: Motion.reduced(context),
      scrim: HermesTokens.of(context).scrim,
    ),
  );
}

/// A spring rendered as a curve: the sheet's present motion (stiffness 380,
/// ζ 0.86) normalised over the route duration.
class SpringCurve extends Curve {
  SpringCurve(SpringDescription spring, {this.settle = 0.38})
    : _sim = SpringSimulation(spring, 0, 1, 0);
  final SpringSimulation _sim;
  final double settle;

  @override
  double transformInternal(double t) => t >= 1 ? 1 : _sim.x(t * settle);
}

class FloatingSheetRoute<T> extends PopupRoute<T> {
  FloatingSheetRoute({
    required this.page,
    required this.live,
    required this.reduced,
    required Color scrim,
  }) : _scrim = live ? scrim.withValues(alpha: scrim.a * 0.6) : scrim;

  final SheetPage page;
  final bool live;
  final bool reduced;
  final Color _scrim;

  static final _presentCurve = SpringCurve(Motion.sheet);

  @override
  Color? get barrierColor => _scrim;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Curve get barrierCurve =>
      reduced ? Curves.linear : const Interval(0, 0.66, curve: Motion.standard);

  @override
  Duration get transitionDuration =>
      reduced ? Motion.reducedDuration : const Duration(milliseconds: 380);

  @override
  Duration get reverseTransitionDuration =>
      reduced ? Motion.reducedDuration : const Duration(milliseconds: 220);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => _FloatingSheet(route: this);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: reduced ? Curves.linear : _presentCurve,
      reverseCurve: reduced ? Curves.linear : Motion.exit.flipped,
    );
    return AnimatedBuilder(
      animation: curved,
      child: child,
      builder: (context, child) => FractionalTranslation(
        translation: Offset(0, 1.06 * (1 - curved.value)),
        child: child,
      ),
    );
  }
}

class _FloatingSheet extends StatefulWidget {
  const _FloatingSheet({required this.route});
  final FloatingSheetRoute<Object?> route;

  @override
  State<_FloatingSheet> createState() => _FloatingSheetState();
}

class _FloatingSheetState extends State<_FloatingSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drag = AnimationController.unbounded(
    vsync: this,
  );
  double _height = 1;

  @override
  void dispose() {
    _drag.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    _drag.value = math.max(0, _drag.value + d.delta.dy);
  }

  void _onDragEnd(DragEndDetails d) {
    final v = d.velocity.pixelsPerSecond.dy;
    if (_drag.value > _height * 0.3 || v > 700) {
      FeedbackScope.haptic(context, Haptic.light);
      Navigator.of(context).pop();
      return;
    }
    // Snaps back into place.
    if (_drag.value > 0) FeedbackScope.haptic(context, Haptic.selection);
    _drag.animateWith(SpringSimulation(Motion.sheet, _drag.value, 0, v));
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final mq = MediaQuery.of(context);
    final blur = RenderPolicyScope.of(context).blur;
    final bottom = Sz.sheetInset + mq.viewPadding.bottom + mq.viewInsets.bottom;
    final radius = BorderRadius.circular(Rad.sheet);
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
      child: SheetPager(
        root: widget.route.page,
        maxHeight: mq.size.height - bottom - mq.viewPadding.top - 24,
        screenHeight: mq.size.height,
        onDragUpdate: _onDragUpdate,
        onDragEnd: _onDragEnd,
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
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Sz.sheetInset,
        mq.viewPadding.top + 24,
        Sz.sheetInset,
        bottom,
      ),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Sz.sheetMaxWidth),
          child: AnimatedBuilder(
            animation: _drag,
            builder: (context, child) => Transform.translate(
              offset: Offset(0, _drag.value),
              child: child,
            ),
            child: LayoutBuilder(
              builder: (context, box) {
                _height = box.maxHeight.isFinite ? box.maxHeight : 600;
                return Material(type: MaterialType.transparency, child: panel);
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// The page stack inside a floating sheet: animated height (§6.8, 300 ms
/// emphasizedDecel) and horizontal slides (280 ms standard).
class SheetPager extends StatefulWidget {
  const SheetPager({
    super.key,
    required this.root,
    required this.maxHeight,
    required this.screenHeight,
    this.onDragUpdate,
    this.onDragEnd,
  });

  final SheetPage root;
  final double maxHeight;
  final double screenHeight;
  final GestureDragUpdateCallback? onDragUpdate;
  final GestureDragEndCallback? onDragEnd;

  static SheetPagerState of(BuildContext context) =>
      context.findAncestorStateOfType<SheetPagerState>()!;

  @override
  State<SheetPager> createState() => SheetPagerState();
}

class SheetPagerState extends State<SheetPager>
    with SingleTickerProviderStateMixin {
  late final List<SheetPage> _stack = [widget.root];
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
    value: 1,
  );
  SheetPage? _outgoing;
  bool _forward = true;

  bool get canPop => _stack.length > 1;
  int get depth => _stack.length;

  void push(SheetPage page) {
    setState(() {
      _outgoing = _stack.last;
      _forward = true;
      _stack.add(page);
    });
    _run();
  }

  void pop() {
    if (!canPop) return;
    setState(() {
      _outgoing = _stack.removeLast();
      _forward = false;
    });
    _run();
  }

  void _run() {
    _slide.duration = Motion.of(context, const Duration(milliseconds: 280));
    _slide.forward(from: 0).whenComplete(() {
      if (mounted) setState(() => _outgoing = null);
    });
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  /// The body's pull-down is following the sheet.
  bool _bodyDrag = false;

  bool _onBodyScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    switch (n) {
      case OverscrollNotification(:final dragDetails?) when n.overscroll < 0:
        _bodyDrag = true;
        widget.onDragUpdate?.call(
          DragUpdateDetails(
            globalPosition: dragDetails.globalPosition,
            delta: Offset(0, -n.overscroll),
            primaryDelta: -n.overscroll,
          ),
        );
      case OverscrollNotification(:final dragDetails?) when _bodyDrag:
        widget.onDragUpdate?.call(dragDetails);
      case ScrollUpdateNotification(:final dragDetails?) when _bodyDrag:
        // Back up toward its place while the body scrolls.
        if (dragDetails.delta.dy < 0) widget.onDragUpdate?.call(dragDetails);
      case ScrollEndNotification() when _bodyDrag:
        _bodyDrag = false;
        widget.onDragEnd?.call(
          DragEndDetails(
            velocity: n.dragDetails?.velocity ?? Velocity.zero,
            primaryVelocity: n.dragDetails?.velocity.pixelsPerSecond.dy ?? 0,
          ),
        );
      default:
    }
    return false;
  }

  Widget _page(SheetPage p, {required bool top}) {
    final t = HermesTokens.of(context);
    final isRoot = identical(p, _stack.first) && _stack.length == 1;
    final showBack = !isRoot && (top ? canPop : true);
    final header = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: widget.onDragUpdate,
          onVerticalDragEnd: widget.onDragEnd,
          child: Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: t.textFaint.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              SizedBox(
                height: 56,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 56),
                      child: Semantics(
                        header: true,
                        child: Text(
                          p.title,
                          style: t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    if (showBack)
                      Positioned(
                        left: 6,
                        child: SheetBackButton(onPressed: pop),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (p.subtitle != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Semantics(
              liveRegion: true,
              child: Text(
                p.subtitle!,
                style: t.label,
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );
    // Round 8: a pull down at the top of the body moves the sheet too (it
    // used to follow only the header), and dismisses it past the same
    // threshold. Bodies always scroll, with clamping, so a short body and
    // iOS produce the overscroll that drives it.
    final body = NotificationListener<ScrollNotification>(
      onNotification: _onBodyScroll,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          physics: const AlwaysScrollableScrollPhysics(
            parent: ClampingScrollPhysics(),
          ),
        ),
        child: Builder(builder: p.builder),
      ),
    );
    if (p.heightFraction != null) {
      final h = math.min(
        widget.maxHeight,
        widget.screenHeight * p.heightFraction!,
      );
      return SizedBox(
        height: h,
        child: Column(
          children: [
            header,
            Expanded(child: body),
          ],
        ),
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          header,
          Flexible(child: body),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final top = _stack.last;
    final reduced = Motion.reduced(context);
    final curve = CurvedAnimation(parent: _slide, curve: Motion.standard);
    final incoming = _page(top, top: true);
    Widget content;
    if (_outgoing == null) {
      content = KeyedSubtree(key: ObjectKey(top), child: incoming);
    } else {
      final inFrom = _forward ? 0.24 : -0.12;
      final outTo = _forward ? -0.12 : 0.24;
      content = Stack(
        children: [
          Positioned.fill(
            child: ClipRect(
              child: OverflowBox(
                alignment: Alignment.topCenter,
                maxHeight: double.infinity,
                child: SlideTransition(
                  position: Tween(
                    begin: Offset.zero,
                    end: Offset(outTo, 0),
                  ).animate(curve),
                  child: FadeTransition(
                    opacity: ReverseAnimation(curve),
                    child: KeyedSubtree(
                      key: ObjectKey(_outgoing),
                      child: IgnorePointer(
                        child: _page(_outgoing!, top: false),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SlideTransition(
            position: Tween(
              begin: Offset(inFrom, 0),
              end: Offset.zero,
            ).animate(curve),
            child: FadeTransition(
              opacity: curve,
              child: KeyedSubtree(key: ObjectKey(top), child: incoming),
            ),
          ),
        ],
      );
    }
    return PopScope(
      canPop: !canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) pop();
      },
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: top.title,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Rad.sheet),
          child: AnimatedSize(
            // Not zero under reduced motion: a zero-length AnimatedSize
            // re-dirties itself in layout when the page's size changes.
            duration: reduced
                ? const Duration(microseconds: 1)
                : const Duration(milliseconds: 300),
            curve: Motion.emphasizedDecel,
            alignment: Alignment.bottomCenter,
            child: content,
          ),
        ),
      ),
    );
  }
}
