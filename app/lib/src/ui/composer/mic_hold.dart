import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// Where a press on the composer mic is.
enum MicHoldPhase {
  idle,

  /// Down, under [MicHoldMachine.holdDelay]: still a tap if it ends now.
  pressed,

  /// Held: release sends, slide left cancels, slide up locks.
  holding,

  /// Hands-free: recording goes on after the finger lifts.
  locked,
}

/// What a pointer change means for dictation.
enum MicHoldOutcome {
  /// A short press: tap-to-dictate as before (the words go into the field).
  tap,

  /// The press became a hold: keep listening through pauses.
  holdStarted,

  /// Released while holding: stop and send.
  send,

  /// Slid left past [MicHoldMachine.cancelDistance]: throw the words away.
  cancel,

  /// Slid up past [MicHoldMachine.lockDistance]: hands-free.
  lock,
}

/// The press-and-hold gesture on the mic, without widgets or timers so the
/// rules can be tested directly. The composer feeds pointer events and calls
/// [holdElapsed] when [holdDelay] has passed.
class MicHoldMachine {
  /// Shorter presses are taps.
  static const holdDelay = Duration(milliseconds: 300);

  /// Leftward travel that cancels.
  static const cancelDistance = 110.0;

  /// Upward travel that locks.
  static const lockDistance = 80.0;

  MicHoldPhase phase = MicHoldPhase.idle;
  Offset _origin = Offset.zero;

  /// Travel from where the press began, clamped to the two directions that
  /// mean something (left, up).
  Offset offset = Offset.zero;

  /// 0…1 toward cancelling, while holding.
  double get cancelProgress => phase == MicHoldPhase.holding
      ? (-offset.dx / cancelDistance).clamp(0.0, 1.0)
      : 0;

  /// 0…1 toward the lock, while holding.
  double get lockProgress => phase == MicHoldPhase.holding
      ? (-offset.dy / lockDistance).clamp(0.0, 1.0)
      : 0;

  void down(Offset position) {
    phase = MicHoldPhase.pressed;
    _origin = position;
    offset = Offset.zero;
  }

  MicHoldOutcome? holdElapsed() {
    if (phase != MicHoldPhase.pressed) return null;
    phase = MicHoldPhase.holding;
    return _evaluate() ?? MicHoldOutcome.holdStarted;
  }

  /// A cancel or lock that was already reached when the hold began wins
  /// over [MicHoldOutcome.holdStarted]: the caller handles both the same.
  MicHoldOutcome? move(Offset position) {
    if (phase != MicHoldPhase.pressed && phase != MicHoldPhase.holding) {
      return null;
    }
    final d = position - _origin;
    // The dominant direction only: a diagonal slide is not both.
    offset = d.dx.abs() >= d.dy.abs()
        ? Offset(d.dx.clamp(-cancelDistance * 1.2, 0), 0)
        : Offset(0, d.dy.clamp(-lockDistance * 1.2, 0));
    return phase == MicHoldPhase.holding ? _evaluate() : null;
  }

  MicHoldOutcome? _evaluate() {
    if (offset.dx <= -cancelDistance) {
      phase = MicHoldPhase.idle;
      return MicHoldOutcome.cancel;
    }
    if (offset.dy <= -lockDistance) {
      phase = MicHoldPhase.locked;
      offset = Offset.zero;
      return MicHoldOutcome.lock;
    }
    return null;
  }

  MicHoldOutcome? up() {
    final was = phase;
    if (was == MicHoldPhase.locked) {
      offset = Offset.zero;
      return null; // Keeps recording.
    }
    phase = MicHoldPhase.idle;
    offset = Offset.zero;
    return switch (was) {
      MicHoldPhase.pressed => MicHoldOutcome.tap,
      MicHoldPhase.holding => MicHoldOutcome.send,
      _ => null,
    };
  }

  /// The system took the pointer (a permission prompt, the app paused). A
  /// press becomes a tap (dictation into the field goes on); a hold becomes
  /// hands-free, so nothing said is lost or sent by surprise.
  MicHoldOutcome? pointerCancelled() {
    final was = phase;
    offset = Offset.zero;
    switch (was) {
      case MicHoldPhase.pressed:
        phase = MicHoldPhase.idle;
        return MicHoldOutcome.tap;
      case MicHoldPhase.holding:
        phase = MicHoldPhase.locked;
        return MicHoldOutcome.lock;
      case MicHoldPhase.idle || MicHoldPhase.locked:
        return null;
    }
  }

  /// Hands-free ended (sent or cancelled from its buttons).
  void reset() {
    phase = MicHoldPhase.idle;
    offset = Offset.zero;
  }
}

/// Claims every pointer that lands on the mic at once, so the chat's
/// swipe-up-to-live, sidebar swipes and scrolling never take a press that
/// began on it (and a slide left or up stays with the mic).
class MicPressRecognizer extends OneSequenceGestureRecognizer {
  MicPressRecognizer({super.debugOwner, required this.enabled});

  /// Whether the mic takes pointers now (shown, text mode).
  final bool Function() enabled;

  void Function(PointerDownEvent event)? onDown;
  void Function(PointerMoveEvent event)? onMove;
  void Function(PointerUpEvent event)? onUp;
  VoidCallback? onCancel;

  int? _pointer;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      _pointer == null &&
      enabled() &&
      (event.kind != PointerDeviceKind.mouse ||
          event.buttons == kPrimaryMouseButton) &&
      super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _pointer = event.pointer;
    resolve(GestureDisposition.accepted);
    onDown?.call(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    switch (event) {
      case PointerMoveEvent():
        onMove?.call(event);
      case PointerUpEvent():
        _pointer = null;
        stopTrackingPointer(event.pointer);
        onUp?.call(event);
      case PointerCancelEvent():
        _pointer = null;
        stopTrackingPointer(event.pointer);
        onCancel?.call();
      default:
    }
  }

  @override
  void rejectGesture(int pointer) {
    super.rejectGesture(pointer);
    if (pointer == _pointer) {
      _pointer = null;
      onCancel?.call();
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'mic press';
}
