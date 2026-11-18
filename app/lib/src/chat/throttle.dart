import 'dart:async';

/// Leading + trailing throttle: the first [call] runs [action] at once, later
/// calls within [interval] are folded into one run at the end of it. Timer
/// based only, so fake time in tests drives it.
class Throttle {
  Throttle(this.interval, this.action);

  final Duration interval;
  final void Function() action;
  Timer? _timer;
  bool _dirty = false;

  void call() {
    if (_timer != null) {
      _dirty = true;
      return;
    }
    action();
    _timer = Timer(interval, _tick);
  }

  void _tick() {
    _timer = null;
    if (_dirty) {
      _dirty = false;
      call();
    }
  }

  /// Runs [action] now and starts a new window (drops a pending trailing run).
  void flush() {
    reset();
    action();
    _timer = Timer(interval, _tick);
  }

  /// Drops a pending trailing run.
  void reset() {
    _timer?.cancel();
    _timer = null;
    _dirty = false;
  }

  void dispose() => reset();
}
