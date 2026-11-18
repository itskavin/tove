import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// How the orb is drawn.
enum OrbRenderer {
  /// Shader where it works, the painter otherwise (see [OrbRenderer.resolve]).
  auto,

  /// The fragment shader; still falls back if it cannot load.
  shader,

  /// The gradient [CustomPainter] (low-end devices, reduced motion, web).
  fallback;

  /// Which renderer to use (spec §7.3, §8.2).
  ///
  /// The painter is used when it is asked for, when motion is reduced (a
  /// still gradient sphere), on the web for [auto] (web Impeller has no
  /// runtime effects and CanvasKit support is unconfirmed), when the render
  /// policy has turned the shader off (Android < 29, sustained jank), and
  /// whenever the program has not loaded (still loading or failed).
  static OrbRenderer resolve({
    required OrbRenderer requested,
    required bool reduceMotion,
    required bool isWeb,
    required bool policyAllowsShader,
    required OrbShaderStatus status,
  }) {
    if (requested == OrbRenderer.fallback || reduceMotion) return fallback;
    if (requested == OrbRenderer.auto && (isWeb || !policyAllowsShader)) {
      return fallback;
    }
    return status == OrbShaderStatus.ready ? shader : fallback;
  }
}

enum OrbShaderStatus { notLoaded, loading, ready, failed }

/// Loads `shaders/orb.frag` once per process.
///
/// Call [precache] early (for example from `main`) so the first live frame
/// does not wait for compilation. [status] says whether it is usable.
abstract final class OrbShader {
  static const String asset = 'shaders/orb.frag';

  /// Number of float uniforms `orb.frag` declares.
  static const int uniformCount = 14;

  static ui.FragmentProgram? _program;
  static Future<ui.FragmentProgram?>? _loading;
  static OrbShaderStatus _status = OrbShaderStatus.notLoaded;
  static Future<ui.FragmentProgram> Function() _loader = _defaultLoader;

  static Future<ui.FragmentProgram> _defaultLoader() =>
      ui.FragmentProgram.fromAsset(asset);

  static ui.FragmentProgram? get program => _program;
  static OrbShaderStatus get status => _status;
  static bool get ready => _status == OrbShaderStatus.ready;
  static bool get failed => _status == OrbShaderStatus.failed;

  /// Starts loading (and compiling) the program. Never throws: a failure
  /// sets [status] to [OrbShaderStatus.failed] and completes with null.
  static Future<ui.FragmentProgram?> precache() {
    return _loading ??= () async {
      _status = OrbShaderStatus.loading;
      try {
        _program = await _loader();
        _status = OrbShaderStatus.ready;
      } catch (e) {
        _program = null;
        _status = OrbShaderStatus.failed;
        debugPrint('Hermes orb: shader unavailable, using the painter ($e)');
      }
      return _program;
    }();
  }

  /// Resets the cache and optionally replaces the loader (tests only).
  @visibleForTesting
  static void debugReset({Future<ui.FragmentProgram> Function()? loader}) {
    _program = null;
    _loading = null;
    _status = OrbShaderStatus.notLoaded;
    _loader = loader ?? _defaultLoader;
  }
}
