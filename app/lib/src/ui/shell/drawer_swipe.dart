import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

/// Marks a control whose horizontal drags must never open or close the
/// sidebar (chat-rendering-v2 §4.3): hermes-ui sliders, segmented controls.
/// Horizontal scrollables need no marker (see [startsOnHorizontalScroller]).
class DrawerSwipeExclusion extends SingleChildRenderObjectWidget {
  const DrawerSwipeExclusion({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderDrawerSwipeExclusion();
}

class RenderDrawerSwipeExclusion extends RenderProxyBox {}

/// Shares the shell's sidebar-swipe recognizer with widgets deeper in the
/// tree ([DrawerSwipeTarget]).
class DrawerSwipeScope extends InheritedWidget {
  const DrawerSwipeScope({
    super.key,
    required this.factory,
    required super.child,
  });

  final GestureRecognizerFactory<DrawerSwipeRecognizer> factory;

  static DrawerSwipeScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DrawerSwipeScope>();

  @override
  bool updateShouldNotify(DrawerSwipeScope old) => factory != old.factory;
}

/// Adds the sidebar swipe at this depth, for regions where a deeper
/// recognizer would otherwise win a horizontal drag first: the selection
/// area's tap-and-horizontal-drag recognizer under reply text accepts at
/// the same move event, and the deeper recognizer resolves first. Under
/// [DrawerSwipeTarget] the swipe is the deeper one; the shell's own copy
/// then simply loses. Without a [DrawerSwipeScope] it is a no-op.
class DrawerSwipeTarget extends StatelessWidget {
  const DrawerSwipeTarget({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = DrawerSwipeScope.maybeOf(context);
    if (scope == null) return child;
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      excludeFromSemantics: true,
      gestures: {DrawerSwipeRecognizer: scope.factory},
      child: child,
    );
  }
}

/// What lies under a pointer that went down at [position] (global).
///
/// A horizontal scrollable shows up as the [RenderSemanticsGestureHandler]
/// of its gesture detector with only a horizontal drag handler.
({bool excluded, bool horizontalScroller}) swipeHitInfo(
  Offset position,
  int viewId,
) {
  final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(result, position, viewId);
  var excluded = false;
  var scroller = false;
  for (final e in result.path) {
    final t = e.target;
    if (t is RenderDrawerSwipeExclusion) excluded = true;
    if (t is RenderSemanticsGestureHandler &&
        t.onHorizontalDragUpdate != null &&
        t.onVerticalDragUpdate == null) {
      scroller = true;
    }
  }
  return (excluded: excluded, horizontalScroller: scroller);
}

/// The sidebar swipe (chat-rendering-v2 §4.2): a horizontal drag that is
/// accepted only after [slop] (16 dp) of horizontal travel within 32° of
/// horizontal (`|dx| ≥ 1.6·|dy|`), in an allowed direction. Anything else is
/// left to the vertical list, so scrolling never stutters.
///
/// [canStart] decides at pointer-down (system gesture insets, horizontal
/// scrollers, sliders, an active text selection); [direction] is the allowed
/// sign of dx (+1 opening, −1 closing, 0 both).
class DrawerSwipeRecognizer extends HorizontalDragGestureRecognizer {
  DrawerSwipeRecognizer({
    super.debugOwner,
    required this.canStart,
    required this.direction,
    this.slop = 16,
    this.onLost,
  });

  final bool Function(PointerDownEvent event) canStart;
  final int Function() direction;
  final double slop;

  /// Called with the pointer when another recognizer won it, so the owner
  /// can still follow a swipe that a no-op recognizer took (an unfocused
  /// text field's selection drag on Android).
  final void Function(int pointer)? onLost;

  @override
  void rejectGesture(int pointer) {
    onLost?.call(pointer);
    super.rejectGesture(pointer);
  }

  /// tan(32°) ≈ 0.625 ⇒ |dx| ≥ 1.6 · |dy|.
  static const ratio = 1.6;

  final Map<int, Offset> _travel = {};

  @override
  bool isPointerAllowed(PointerEvent event) =>
      super.isPointerAllowed(event) &&
      (event is! PointerDownEvent || canStart(event));

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _travel[event.pointer] = Offset.zero;
    _last = Offset.zero;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent && _travel.containsKey(event.pointer)) {
      _travel[event.pointer] = _travel[event.pointer]! + event.delta;
      _last = _travel[event.pointer]!;
    }
    super.handleEvent(event);
  }

  Offset _last = Offset.zero;

  /// The travel of the pointer being tracked, so the owner can tell which
  /// way an accepted drag went.
  Offset get travel => _last;

  /// Never later than the device's own touch slop (about 8 dp on Android),
  /// where the thread's scroll and the text recognizers accept; with a fixed
  /// 16 dp they won light swipes on a phone (round 6).
  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) => accepts(
    _last,
    direction(),
    slop: math.min(slop, deviceTouchSlop ?? slop),
  );

  /// The acceptance rule, exposed for tests.
  static bool accepts(Offset travel, int direction, {double slop = 16}) {
    final dx = travel.dx, dy = travel.dy;
    if (dx.abs() < slop) return false;
    if (dx.abs() < ratio * dy.abs()) return false;
    if (direction > 0 && dx < 0) return false;
    if (direction < 0 && dx > 0) return false;
    return true;
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    // [travel] stays readable until the next pointer: a drag accepted as
    // the pointer lifts reports its start after this.
    _travel.clear();
    super.didStopTrackingLastPointer(pointer);
  }

  @override
  String get debugDescription => 'drawer swipe';
}

/// The release rule (§4.2): a fling beyond 365 dp/s decides; otherwise a
/// drag that started closed opens from 40 %, and one that started open stays
/// open from 60 % (hysteresis, so a wobble never closes it).
bool drawerShouldOpen({
  required double progress,
  required double velocity,
  required bool startedOpen,
}) {
  if (velocity > 365) return true;
  if (velocity < -365) return false;
  return progress >= (startedOpen ? 0.6 : 0.4);
}

/// Rubber band past fully open (§4.2): 0.15 × the finger, at most 24 dp.
double drawerOvershoot(double rawProgress, double width) {
  if (rawProgress <= 1) return 0;
  final px = ((rawProgress - 1) * width * 0.15).clamp(0.0, 24.0);
  return px / width;
}
