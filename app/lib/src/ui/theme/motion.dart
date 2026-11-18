import 'package:material_ui/material_ui.dart';

/// Motion constants (spec §6) and the reduce-motion policy (§8.2).
abstract final class Motion {
  static const emphasizedDecel = Cubic(0.05, 0.7, 0.1, 1.0);
  static const standard = Cubic(0.2, 0.0, 0.0, 1.0);
  static const exit = Cubic(0.3, 0.0, 0.8, 0.15);

  /// The dock curve measured from the reference video (§6.2).
  static const dock = Cubic(0.3, 0.0, 0.2, 1.0);

  /// easeOutBack-style pop for mute/end, overshoot ≤ 4 % (§6.4).
  static const pop = Cubic(0.34, 1.3, 0.64, 1);

  static const reducedDuration = Duration(milliseconds: 150);

  static SpringDescription spring(double stiffness, double ratio) =>
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: stiffness,
        ratio: ratio,
      );

  /// Orb parameter cross-fade (§6.1).
  static final orbState = spring(120, 1.0);

  /// Sheet present (§6.6).
  static final sheet = spring(380, 0.86);

  /// Drawer release fling (§6.5).
  static final drawer = spring(500, 0.9);

  /// Effort thumb between stops (§6.7).
  static final thumb = spring(500, 0.8);

  static bool reduced(BuildContext context) =>
      MotionScope.reduceOf(context) || MediaQuery.disableAnimationsOf(context);

  /// [full] normally, zero with reduced motion (§6 global rule).
  static Duration of(BuildContext context, Duration full) =>
      reduced(context) ? Duration.zero : full;

  /// Spatial transitions keep moving with reduced motion but shorten to
  /// 150 ms linear (§8.2).
  static Duration spatial(BuildContext context, Duration full) =>
      reduced(context) ? reducedDuration : full;

  static Curve spatialCurve(BuildContext context, Curve full) =>
      reduced(context) ? Curves.linear : full;
}

/// Carries the app's "Reduce motion" setting down the tree.
class MotionScope extends InheritedWidget {
  const MotionScope({super.key, required this.reduce, required super.child});

  final bool reduce;

  static bool reduceOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MotionScope>()?.reduce ??
      false;

  @override
  bool updateShouldNotify(MotionScope old) => old.reduce != reduce;
}
