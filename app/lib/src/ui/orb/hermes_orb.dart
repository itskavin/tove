import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../rtc/voice_transport.dart';
import '../theme/motion.dart';
import '../theme/render_policy.dart';
import '../theme/tokens.dart';
import 'orb_engine.dart';
import 'orb_fallback.dart';
import 'orb_shader.dart';

/// The Hermes live voice orb (spec §5.1, §6.1, §6.2): a daytime sky over a
/// rolling cloud bank, seen through a crisp round window.
///
/// * [state] picks the per-state parameters; changes cross-fade with a
///   spring (≈ 450 ms), never jump.
/// * Audio: pass either [level] (one 0..1 energy, interpreted per state; see
///   [OrbEngine.setLevel]) or [levels] (raw WebRTC [AudioLevels], normalised
///   and split into user/Hermes here). Smoothing (attack 60 ms, release
///   350 ms) happens in Dart. Without levels the orb only breathes.
/// * [size] is the rest diameter `D` and the size of the layout box. The
///   orb paints a little outside it (speech peaks, halo), never clipped.
/// * [docked] shrinks the circle to 0.41 × around the box centre over
///   260 ms (320 ms back). Moving the box is the parent's job: use
///   [OrbEngine.dockDuration] / [OrbEngine.dockCurve], or drive both from
///   one controller and pass the 0..1 [dock] factor instead.
/// * [engine]: pass one to keep motion continuous when the orb moves in the
///   tree (centred ↔ docked layouts). Otherwise the widget owns one.
///
/// Rendering: the fragment shader where available, else the gradient
/// painter (see [OrbRenderer.resolve]). One [Ticker] runs only while
/// [active], not muted by [TickerMode], motion is not reduced, and the
/// ended fade is not finished. Each tick repaints only the orb's
/// [RepaintBoundary]; no widget rebuilds per frame, no save layers.
///
/// Reduced motion ([reduceMotion], or [Motion.reduced]): a still gradient
/// sphere; state changes step instantly (colour, scale) and audio shows as a
/// 2 dp outer ring. No frames are scheduled while nothing changes.
class HermesOrb extends StatefulWidget {
  const HermesOrb({
    super.key,
    required this.state,
    required this.size,
    this.level,
    this.levels,
    this.docked = false,
    this.dock,
    this.engine,
    this.renderer = OrbRenderer.auto,
    this.reduceMotion,
    this.active = true,
    this.halo = true,
  }) : assert(
         level == null || levels == null,
         'Pass either level or levels, not both.',
       );

  final OrbState state;

  /// Rest diameter `D` (spec §3.5 `orbCentered`) and the layout box size.
  final double size;

  /// One 0..1 energy (already normalised), read per state.
  final ValueListenable<double>? level;

  /// Raw call levels; input drives user reactions, output Hermes' reactions.
  final ValueListenable<AudioLevels>? levels;

  /// Animated dock (0.41 × size). Ignored when [dock] is given.
  final bool docked;

  /// Caller-driven dock factor, 0 centred … 1 docked.
  final double? dock;

  final OrbEngine? engine;
  final OrbRenderer renderer;

  /// Overrides [Motion.reduced] when not null.
  final bool? reduceMotion;

  /// False stops the ticker (orb hidden or offscreen). The last frame stays.
  final bool active;

  /// Dark theme: `orbGlow` halo at 1.12 r. Light theme: a soft shadow.
  final bool halo;

  /// How far outside [size] the orb may paint, as a multiple of [size].
  static const double paintExtent = 1.32;

  @override
  State<HermesOrb> createState() => HermesOrbState();
}

/// Public so tests and the integrator's debug tools can inspect it.
class HermesOrbState extends State<HermesOrb>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late OrbEngine _engine;
  bool _ownsEngine = true;
  Duration? _last;
  bool _reduced = false;
  RenderPolicy? _policy;
  ui.FragmentShader? _shader;
  OrbRenderer? _built;

  OrbEngine get engine => _engine;

  /// Whether the ticker is running (frames are being produced).
  bool get isTicking => _ticker.isTicking;

  /// The renderer chosen for the current frame.
  OrbRenderer get renderer => _resolve();

  bool get usesShader => renderer == OrbRenderer.shader;

  @override
  void initState() {
    super.initState();
    _ownsEngine = widget.engine == null;
    _engine =
        widget.engine ?? OrbEngine(state: widget.state, docked: widget.docked);
    _applyWidget(animateDock: false);
    _subscribe(widget);
    _readLevels();
    final pending =
        OrbShader.status == OrbShaderStatus.notLoaded ||
        OrbShader.status == OrbShaderStatus.loading;
    if (widget.renderer != OrbRenderer.fallback && !kIsWeb && pending) {
      unawaited(OrbShader.precache().then((_) => _onShaderSettled()));
    }
  }

  bool _computeReduced() => widget.reduceMotion ?? Motion.reduced(context);

  void _onShaderSettled() {
    if (!mounted) return;
    if (OrbShader.failed) _policy?.shaderFailed();
    // Rebuild only when the renderer changes, so a settled load schedules
    // no frame (reduced motion must stay frame-free).
    if (_resolve() != _built) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _policy = RenderPolicyScope.of(context);
    final reduced = _computeReduced();
    if (reduced != _reduced) {
      _reduced = reduced;
      if (_reduced) _engine.settle();
    }
    _syncTicker();
  }

  @override
  void didUpdateWidget(HermesOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.engine != oldWidget.engine) {
      final next =
          widget.engine ??
          OrbEngine(state: widget.state, docked: widget.docked);
      if (_ownsEngine) _engine.dispose();
      _engine = next;
      _ownsEngine = widget.engine == null;
    }
    if (oldWidget.level != widget.level || oldWidget.levels != widget.levels) {
      _unsubscribe(oldWidget);
      _subscribe(widget);
      _readLevels();
    }
    _reduced = _computeReduced();
    _applyWidget(animateDock: true);
    if (_reduced) _engine.settle();
    _syncTicker();
  }

  void _applyWidget({required bool animateDock}) {
    _engine
      ..state = widget.state
      ..dockOverride = widget.dock;
    _engine.setDocked(widget.docked, animate: animateDock);
  }

  void _subscribe(HermesOrb w) {
    w.level?.addListener(_onLevel);
    w.levels?.addListener(_onLevel);
  }

  void _unsubscribe(HermesOrb w) {
    w.level?.removeListener(_onLevel);
    w.levels?.removeListener(_onLevel);
  }

  void _readLevels() {
    final levels = widget.levels;
    if (levels != null) {
      _engine.setLevels(levels.value);
    } else {
      _engine.setLevel(widget.level?.value ?? 0);
    }
  }

  void _onLevel() {
    _readLevels();
    // Reduced motion: no ticker; repaint the ring directly.
    if (_reduced) _engine.settle();
  }

  void _syncTicker() {
    final run = widget.active && !_reduced && _engine.needsFrames;
    if (run && !_ticker.isActive) {
      _last = null;
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _tick(Duration now) {
    final last = _last;
    _last = now;
    _engine.step(last == null ? 0 : (now - last).inMicroseconds / 1e6);
    if (!_engine.needsFrames) _ticker.stop();
  }

  OrbRenderer _resolve() => OrbRenderer.resolve(
    requested: widget.renderer,
    reduceMotion: _reduced,
    isWeb: kIsWeb,
    policyAllowsShader: _policy?.shaderOrb ?? true,
    status: OrbShader.status,
  );

  @override
  void dispose() {
    _unsubscribe(widget);
    _ticker.dispose();
    _shader?.dispose();
    if (_ownsEngine) _engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ui.FragmentShader? shader;
    _built = _resolve();
    if (_built == OrbRenderer.shader) {
      shader = _shader ??= OrbShader.program!.fragmentShader();
    }
    final extent = widget.size * HermesOrb.paintExtent;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: widget.size,
        child: OverflowBox(
          minWidth: extent,
          maxWidth: extent,
          minHeight: extent,
          maxHeight: extent,
          child: RepaintBoundary(
            child: CustomPaint(
              size: Size.square(extent),
              isComplex: true,
              willChange: !_reduced,
              painter: OrbPainter(
                engine: _engine,
                restDiameter: widget.size,
                shader: shader,
                dark: HermesTokens.of(context).dark,
                halo: widget.halo,
                reduced: _reduced,
                devicePixelRatio:
                    MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints one orb frame. Repaints when [engine] notifies (each tick), with
/// no widget rebuild.
class OrbPainter extends CustomPainter {
  OrbPainter({
    required this.engine,
    required this.restDiameter,
    required this.shader,
    required this.dark,
    required this.halo,
    required this.reduced,
    required this.devicePixelRatio,
  }) : super(repaint: engine);

  final OrbEngine engine;
  final double restDiameter;
  final ui.FragmentShader? shader;
  final bool dark;
  final bool halo;
  final bool reduced;
  final double devicePixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    final f = engine.frame;
    final r = restDiameter / 2 * f.diameter.clamp(0.0, 1.25);
    if (r <= 0.5 || f.opacity <= 0.001) return;
    final c = size.center(Offset.zero);

    if (halo) _paintHalo(canvas, c, r, f.opacity);

    final s = shader;
    if (s != null) {
      final half = size.shortestSide / 2;
      s
        ..setFloat(0, size.width)
        ..setFloat(1, size.height)
        ..setFloat(2, f.time)
        ..setFloat(3, r / half)
        ..setFloat(4, f.cloudLevel)
        ..setFloat(5, f.tilt)
        ..setFloat(6, f.roll)
        ..setFloat(7, f.drift)
        ..setFloat(8, f.turbulence)
        ..setFloat(9, f.saturation)
        ..setFloat(10, f.errorMix)
        ..setFloat(11, f.brightness)
        ..setFloat(12, f.opacity)
        ..setFloat(13, devicePixelRatio);
      canvas.drawRect(
        Rect.fromCircle(center: c, radius: r + 1),
        Paint()..shader = s,
      );
    } else {
      paintFallbackOrb(canvas, c, r, f);
    }

    if (reduced && f.ring > 0.01) {
      canvas.drawCircle(
        c,
        r + 5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = OrbPalette.skyLow.withValues(
            alpha: f.ring.clamp(0.0, 1.0) * f.opacity,
          ),
      );
    }
  }

  void _paintHalo(Canvas canvas, Offset c, double r, double opacity) {
    if (dark) {
      final gr = r * 1.12;
      canvas.drawCircle(
        c,
        gr,
        Paint()
          ..shader = ui.Gradient.radial(
            c,
            gr,
            [
              OrbPalette.glow.withValues(alpha: OrbPalette.glow.a * opacity),
              OrbPalette.glow.withValues(alpha: 0),
            ],
            [r / gr * 0.97, 1],
          ),
      );
    } else {
      canvas.drawCircle(
        c.translate(0, 6),
        r,
        Paint()
          ..color = Color.fromRGBO(0, 0, 0, 0.10 * opacity)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      );
    }
  }

  @override
  bool shouldRepaint(OrbPainter old) =>
      old.engine != engine ||
      old.restDiameter != restDiameter ||
      old.shader != shader ||
      old.dark != dark ||
      old.halo != halo ||
      old.reduced != reduced ||
      old.devicePixelRatio != devicePixelRatio;
}
