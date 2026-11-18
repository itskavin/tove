/// Settings › Accessibility › Display › Refresh rate (this device only).
enum RefreshMode {
  auto(
    'Auto',
    'Recommended. 90 Hz while you use the app, the highest rate '
        'while you swipe, scroll or talk live, and the system’s choice when '
        'idle.',
  ),
  hz60('60 Hz', 'Uses the least battery.'),
  hz90('90 Hz', 'Smooth, and lighter on battery and heat than the maximum.'),
  max('Maximum', 'The display’s highest rate all the time.');

  const RefreshMode(this.label, this.detail);
  final String label;
  final String detail;
}

/// Which display rate to ask Android for (round 6, A6).
///
/// Why 90 by default: apps such as ChatGPT and Claude run at 90 Hz. It is
/// most of the smoothness of 120 Hz (an 11 ms frame instead of 8 ms) for
/// noticeably less panel and GPU power, so less battery and heat during long
/// reading and streaming. Many panels also have a native 90 Hz mode.
///
/// Auto, in order:
///  * **Boost** (a finger is moving, the thread scrolls, live mode or another
///    animation holds a reason): the panel's highest rate, so drags and
///    springs track the finger as closely as possible.
///  * **Active** (a touch within the last few seconds): 90 Hz, or the
///    closest mode within 85–100 Hz; a panel without one (60/120 only) gets
///    its highest rate, since 60 would feel worse than the other apps.
///  * **Idle:** 0, the system's own choice. On Android 15+ panels with
///    adaptive refresh (ARR) and on LTPO panels the system then lowers the
///    rate by itself while nothing changes; elsewhere it is the system
///    default. The window keeps no vote, so a static screen costs nothing.
///
/// The fixed choices pin the closest supported mode. Battery saver and the
/// system's peak-rate setting (Smooth display off, Bedtime) still cap every
/// request; `RefreshStatus.systemCap` reports which.
abstract final class RefreshPolicy {
  /// How long after the last touch Auto counts as idle.
  static const idleAfter = Duration(seconds: 3);

  /// How long after the last finger lifts a gesture boost lasts (springs,
  /// flings and the drawer settling).
  static const boostTail = Duration(milliseconds: 700);

  /// The rate to request; 0 hands the choice back to the system.
  static double pick({
    required RefreshMode mode,
    required List<double> supported,
    required bool boosting,
    required bool active,
  }) {
    if (supported.isEmpty) return 0;
    final max = supported.reduce((a, b) => a > b ? a : b);
    double closest(double hz) =>
        supported.reduce((a, b) => (a - hz).abs() <= (b - hz).abs() ? a : b);
    double? ninety() {
      final near = supported.where((r) => r >= 85 && r <= 100).toList();
      return near.isEmpty ? null : near.reduce((a, b) => a > b ? a : b);
    }

    return switch (mode) {
      RefreshMode.hz60 => closest(60),
      RefreshMode.hz90 => ninety() ?? closest(90),
      RefreshMode.max => max,
      RefreshMode.auto when boosting => max,
      RefreshMode.auto when active => ninety() ?? max,
      RefreshMode.auto => 0,
    };
  }
}
