import 'dart:math' as math;

import 'package:flutter/gestures.dart';

/// Pull up to start live voice (Settings › Voice › "Pull up to start a live
/// call", on by default).
///
/// **Where it arms** (the shell's `canStart`): a touch on the composer, or
/// in the [zone] dp just above it, and only when the thread was already at
/// rest at its newest text when the finger went down (or the chat is
/// empty). A scroll or fling that reaches the end and overscrolls never
/// arms it, and neither does a touch during a scroll or within
/// [settleAfterScroll] of one ending. Never with the keyboard up, in live
/// mode, with a panel open, inside the system's bottom gesture inset
/// (Android's home gesture), or while text is selected above the composer.
///
/// **Acceptance:** [slop] dp of upward travel within about 40° of vertical
/// (`|dy| ≥ 1.2·|dx|`). Downward and sideways drags are left to the thread
/// and the sidebar swipe.
///
/// **Release:** live starts only when the finger lifts at least
/// [thresholdFor] the screen height above where it went down (about 18 % of
/// the screen, 120–160 dp) and has slowed down (under [maxReleaseVelocity]):
/// speed never helps, a flick is not a pull, and dragging back below the
/// threshold before lifting cancels. A hint grows
/// with the pull ("Pull to talk", then "Release to start live" with a
/// haptic tick at the threshold).
///
/// **Lost gestures** (round 8): a finger that rests on the unfocused
/// composer before moving loses the arena to the text field's long press
/// (the "Paste" menu). The shell then follows that pointer itself from raw
/// events ([onLost]); the same rules apply.
/// While dragging the composer follows with a rubber band of at most
/// [maxOffset] dp ([liveSwipeOffset]).
class LiveSwipeRecognizer extends VerticalDragGestureRecognizer {
  LiveSwipeRecognizer({
    super.debugOwner,
    required this.canStart,
    this.slop = 18,
    this.onLost,
  });

  final bool Function(PointerDownEvent event) canStart;
  final double slop;

  /// Called with the pointer when another recognizer won it.
  final void Function(int pointer)? onLost;

  @override
  void rejectGesture(int pointer) {
    onLost?.call(pointer);
    super.rejectGesture(pointer);
  }

  static const double zone = 72;

  /// The pull that starts live: 18 % of the screen height, at least
  /// [minPull] and at most [maxPull] dp.
  static double thresholdFor(double screenHeight) =>
      (screenHeight * 0.18).clamp(minPull, maxPull);
  static const double minPull = 120;
  static const double maxPull = 160;

  /// A release faster than this (dp/s, upward) is a flick, not a pull.
  static const double maxReleaseVelocity = 1000;

  /// After a scroll or fling of the thread ends, the pull stays off this
  /// long, so the next touch of a quick series of flicks is not a pull.
  static const Duration settleAfterScroll = Duration(milliseconds: 600);
  static const double maxOffset = 28;
  static const double ratio = 1.2;

  final Map<int, Offset> _travel = {};
  Offset _last = Offset.zero;

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

  /// Never later than the device's own touch slop (Android reports about
  /// 8 dp): the thread's scroll accepts there, and a fixed 18 dp lost every
  /// upward drag above the composer to it on a phone (round 6).
  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) => accepts(_last, slop: math.min(slop, deviceTouchSlop ?? slop));

  /// The acceptance rule, exposed for tests.
  static bool accepts(Offset travel, {double slop = 18}) {
    final up = -travel.dy;
    if (up < slop) return false;
    return up >= ratio * travel.dx.abs();
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _travel.clear();
    super.didStopTrackingLastPointer(pointer);
  }

  @override
  String get debugDescription => 'live swipe';
}

/// Whether a released pull starts live voice: [travel] (upward-positive dp)
/// reached [threshold] and the finger was not flicking up as it lifted
/// ([velocity], upward-positive dp/s). Speed never makes up for length.
bool liveSwipeShouldOpen({
  required double travel,
  required double threshold,
  double velocity = 0,
}) => travel >= threshold && velocity < LiveSwipeRecognizer.maxReleaseVelocity;

/// The composer's visual lift for [travel] dp of finger travel: it follows
/// with growing resistance and never passes [LiveSwipeRecognizer.maxOffset].
double liveSwipeOffset(double travel) {
  if (travel <= 0) return 0;
  return LiveSwipeRecognizer.maxOffset * (1 - math.exp(-travel / 90));
}
