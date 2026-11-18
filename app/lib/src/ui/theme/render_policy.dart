import 'dart:ui' show FramePhase, FrameTiming, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

/// Which costly effects are on (spec §7.3).
///
/// Blur, the live-canvas mask and the shader orb start on where the platform
/// handles them well. If [FrameTiming] shows more than 5 % janky frames over
/// a 3 s window, one effect is switched off per bad window, cheapest win
/// first: blur, then the mask, then the shader orb. Nothing switches back on
/// during the session, so the UI never flaps between the two looks.
class RenderPolicy extends ChangeNotifier {
  RenderPolicy({
    bool? blur,
    bool? shaderOrb,
    bool? liveMask,
    this.monitor = true,
  }) : _blur = blur ?? _blurByDefault,
       _shader = shaderOrb ?? !kIsWeb,
       _mask = liveMask ?? true;

  /// Web without the skwasm renderer blurs slowly (§7.3). `dart2wasm` builds
  /// use skwasm.
  static bool get _blurByDefault =>
      !kIsWeb || const bool.fromEnvironment('dart.tool.dart2wasm');

  final bool monitor;
  bool _blur, _shader, _mask;
  bool _listening = false;
  final List<FrameTiming> _window = [];
  Duration _windowStart = Duration.zero;

  bool get blur => _blur;
  bool get shaderOrb => _shader;
  bool get liveMask => _mask;

  /// Android below API 29 runs Skia over OpenGL: start with the fallbacks.
  void applyAndroidSdk(int sdk) {
    if (sdk >= 29) return;
    final changed = _blur || _shader;
    _blur = false;
    _shader = false;
    if (changed) notifyListeners();
  }

  /// Marks the shader orb as unavailable (it failed to compile or load).
  void shaderFailed() {
    if (!_shader) return;
    _shader = false;
    notifyListeners();
  }

  void start() {
    if (!monitor || _listening) return;
    _listening = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    if (!_blur && !_mask && !_shader) return;
    final rate = PlatformDispatcher.instance.displays.isEmpty
        ? 60.0
        : PlatformDispatcher.instance.displays.first.refreshRate;
    final budget = Duration(
      microseconds: (1e6 / (rate <= 0 ? 60 : rate)).round(),
    );
    for (final t in timings) {
      final start = Duration(
        microseconds: t.timestampInMicroseconds(FramePhase.buildStart),
      );
      if (_window.isEmpty) _windowStart = start;
      _window.add(t);
      if (start - _windowStart >= const Duration(seconds: 3)) {
        _evaluate(budget);
        _window.clear();
      }
    }
  }

  @visibleForTesting
  static bool janky(FrameTiming t, Duration budget) =>
      t.buildDuration > budget || t.rasterDuration > budget;

  void _evaluate(Duration budget) {
    // Idle screens produce few frames; judge only animated windows.
    if (_window.length < 60) return;
    final bad = _window.where((t) => janky(t, budget)).length;
    if (bad / _window.length <= 0.05) return;
    if (_blur) {
      _blur = false;
    } else if (_mask) {
      _mask = false;
    } else if (_shader) {
      _shader = false;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    if (_listening) SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }
}

class RenderPolicyScope extends InheritedNotifier<RenderPolicy> {
  const RenderPolicyScope({
    super.key,
    required RenderPolicy policy,
    required super.child,
  }) : super(notifier: policy);

  static final _fallback = RenderPolicy(monitor: false);

  static RenderPolicy of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<RenderPolicyScope>()
          ?.notifier ??
      _fallback;
}
