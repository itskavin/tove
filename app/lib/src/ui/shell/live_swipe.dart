import 'dart:math' as math;

import 'package:flutter/gestures.dart';

/// Swipe up to start live voice.
///
/// **Where it starts** (the shell's `canStart`): a touch on the composer, or
/// in the [zone] dp just above it while the thread is already at its newest
/// text (or the chat is empty), so a thread that can still scroll keeps
/// normal scrolling. Never with the keyboard up, in live mode, with a panel
/// open, inside the system's bottom gesture inset (Android's home gesture),
/// or while text is selected.
///
/// **Acceptance:** [slop] dp of upward travel within about 40° of vertical
/// (`|dy| ≥ 1.2·|dx|`). Downward and sideways drags are left to the thread
/// and the sidebar swipe.
///
/// **Release:** live opens after [threshold] dp, or a fling of at least
/// [flingVelocity] dp/s after [flingTravel] dp, or a quick swipe that
/// averages that speed ([liveSwipeShouldOpen]).
///
/// **Lost gestures** (round 8): a finger that rests on the unfocused
/// composer before moving loses the arena to the text field's long press
/// (the "Paste" menu). The shell then follows that pointer itself from raw
/// events ([onLost]) and still opens live voice on an upward swipe.
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

  // Round 8: forgiving enough for a medium swipe (a phone's velocity
  // estimate is often low or missing for short, quick swipes).
  static const double zone = 72;
  static const double threshold = 56;
  static const double flingVelocity = 380;
  static const double flingTravel = 24;

  /// A quick swipe (down to up within [quickMs]) of [flingTravel] opens too:
  /// its velocity is measured from the whole gesture.
  static const int quickMs = 280;
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

/// Whether a released swipe opens live voice. [travel] and [velocity] are
/// upward-positive (dp, dp/s); [elapsed] is from pointer down to release,
/// when known (a quick swipe's own average speed counts as a fling).
bool liveSwipeShouldOpen({
  required double travel,
  required double velocity,
  Duration? elapsed,
}) {
  if (travel >= LiveSwipeRecognizer.threshold) return velocity > -300;
  if (travel < LiveSwipeRecognizer.flingTravel) return false;
  if (velocity >= LiveSwipeRecognizer.flingVelocity) return true;
  final ms = elapsed?.inMilliseconds;
  return velocity > -100 &&
      ms != null &&
      ms > 0 &&
      ms <= LiveSwipeRecognizer.quickMs &&
      travel * 1000 / ms >= LiveSwipeRecognizer.flingVelocity;
}

/// The composer's visual lift for [travel] dp of finger travel: it follows
/// with growing resistance and never passes [LiveSwipeRecognizer.maxOffset].
double liveSwipeOffset(double travel) {
  if (travel <= 0) return 0;
  return LiveSwipeRecognizer.maxOffset * (1 - math.exp(-travel / 90));
}
