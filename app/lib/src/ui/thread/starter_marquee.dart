import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import '../shell/drawer_swipe.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'starter_prompts.dart';

/// The empty chat's starter prompts as two endless rows of large chips that
/// drift sideways in opposite directions, fading at both edges, with a
/// "Surprise me" button under them that picks one.
///
/// Performance: one [Ticker] drives both rows. Each frame only moves the
/// already painted chips (a [RepaintBoundary] inside a paint-only render
/// object, [_RenderMarqueeTrack]): no build, no layout. Movement is in dp
/// per second, so it is smooth at 60 and 120 Hz.
///
/// The ticker runs only while it is needed: not while [active] is false (a
/// panel or live mode covers the chat), not while the rows are off screen,
/// not while the app is in the background, and not while [TickerMode] mutes
/// it (another route on top).
///
/// Touch (round 8, the user's rule): a finger on a row holds it; a sideways
/// swipe scrolls that row with the finger and flings on release, and never
/// opens the chat list or Tasks ([DrawerSwipeExclusion]). The drift resumes,
/// easing in, [resumeAfter] after any interaction. A finger is followed
/// through a global pointer route as well, so a lost "up" (the row rebuilt
/// or moved under the finger) can never leave a row held: the rows never
/// stall.
///
/// Reduced motion (the app setting or the system's) and screen readers: the
/// rows are still, ordinary horizontal scrollers.
class StarterMarquee extends StatefulWidget {
  const StarterMarquee({
    super.key,
    required this.prompts,
    required this.onPick,
    this.active = true,
    this.speeds = const [24, 19],
    this.edgeFade = 40,
    this.padding = 16,
  });

  final List<StarterPrompt> prompts;

  /// A chip was tapped, or "Surprise me" chose this prompt.
  final ValueChanged<StarterPrompt> onPick;

  /// False pauses the drift (the chat is covered).
  final bool active;

  /// Drift speed of each row in dp/s; the second row moves the other way.
  final List<double> speeds;

  /// Width of the fade at each edge.
  final double edgeFade;

  /// Start and end padding of the still (reduced motion) rows.
  final double padding;

  // Compact pills (the reference app's size): 38 dp, 15 sp text.
  static const double chipHeight = 38;
  static const double gap = 8;
  static const double rowGap = 10;
  static const Duration resumeAfter = Duration(milliseconds: 1600);

  /// The rows' content: even prompts in the first row, odd in the second
  /// (one row for fewer than four prompts).
  static List<List<StarterPrompt>> split(List<StarterPrompt> prompts) {
    if (prompts.length < 4) return [prompts];
    return [
      [for (var i = 0; i < prompts.length; i += 2) prompts[i]],
      [for (var i = 1; i < prompts.length; i += 2) prompts[i]],
    ];
  }

  @override
  State<StarterMarquee> createState() => StarterMarqueeState();
}

/// One row's motion state.
class _Lane extends ChangeNotifier {
  _Lane(this.direction, this.speed);

  /// +1: content moves left; −1: right.
  final int direction;
  final double speed;

  /// How far the content has moved left, in dp (any value; it wraps).
  double offset = 0;

  /// A finger is on the row.
  bool held = false;

  /// The drift resumes after this time (elapsed ticker time).
  Duration resumeAt = Duration.zero;

  /// Fling velocity, dp/s (positive: content moves left).
  double fling = 0;

  /// 0..1 drift speed factor, eased back in after a pause.
  double ease = 1;

  /// "Surprise me": glide to this offset, then report.
  ({double from, double to, Duration start, Duration length})? glide;

  void move(double dx) {
    if (dx == 0) return;
    offset += dx;
    notifyListeners();
  }

  // Lanes are long-lived listenables; expose the protected notify.
  void changed() => notifyListeners();
}

class StarterMarqueeState extends State<StarterMarquee>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late List<_Lane> _lanes;
  late List<List<StarterPrompt>> _rows;
  late final AppLifecycleListener _lifecycle;
  bool _foreground = true;
  bool _still = false;
  Duration _now = Duration.zero;
  Duration? _last;
  Timer? _visibilityPoll;
  final _trackKeys = <GlobalKey>[];

  /// The chosen prompt while "Surprise me" glides it to the middle.
  final ValueNotifier<StarterPrompt?> _picked = ValueNotifier(null);
  void Function()? _afterGlide;

  /// Whether frames are being produced (tests).
  @visibleForTesting
  bool get isTicking => _ticker.isTicking;

  /// Row offsets (tests).
  @visibleForTesting
  List<double> get offsets => [for (final l in _lanes) l.offset];

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    final s = SchedulerBinding.instance.lifecycleState;
    _foreground = s == null || s == AppLifecycleState.resumed;
    _setRows();
  }

  void _setRows() {
    _rows = StarterMarquee.split(widget.prompts);
    _lanes = [
      for (var i = 0; i < _rows.length; i++)
        _Lane(i.isEven ? 1 : -1, widget.speeds[i % widget.speeds.length])
          ..offset = i.isEven ? 0 : 37,
    ];
    while (_trackKeys.length < _rows.length) {
      _trackKeys.add(GlobalKey());
    }
  }

  void _onLifecycle(AppLifecycleState s) {
    final fg = s == AppLifecycleState.resumed;
    if (fg == _foreground) return;
    _foreground = fg;
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still =
        Motion.reduced(context) || MediaQuery.accessibleNavigationOf(context);
    if (still != _still) _still = still;
    _sync();
  }

  @override
  void didUpdateWidget(StarterMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_samePrompts(oldWidget.prompts, widget.prompts)) {
      _fingers.clear();
      _unroute();
      for (final l in _lanes) {
        l.dispose();
      }
      _picked.value = null;
      _afterGlide = null;
      _setRows();
    }
    _sync();
  }

  static bool _samePrompts(List<StarterPrompt> a, List<StarterPrompt> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _fingers.clear();
    _unroute();
    _visibilityPoll?.cancel();
    _ticker.dispose();
    _lifecycle.dispose();
    _picked.dispose();
    for (final l in _lanes) {
      l.dispose();
    }
    super.dispose();
  }

  bool get _wantsFrames =>
      !_still && widget.active && _foreground && _lanes.isNotEmpty;

  /// Starts or stops the ticker. Off screen it stops and a slow timer
  /// checks when the rows come back.
  void _sync() {
    if (!mounted) return;
    if (!_wantsFrames) {
      _visibilityPoll?.cancel();
      _visibilityPoll = null;
      if (_ticker.isActive) _ticker.stop();
      _last = null;
      return;
    }
    // Off screen: the visibility poll restarts it.
    if (_ticker.isActive || _visibilityPoll != null) return;
    _last = null;
    _ticker.start();
  }

  /// Any part of the rows is inside the window.
  bool _onScreen() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return true;
    final view = View.maybeOf(context);
    if (view == null) return true;
    final screen = Offset.zero & (view.physicalSize / view.devicePixelRatio);
    final r = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
    return r.overlaps(screen);
  }

  void _tick(Duration elapsed) {
    final last = _last;
    _last = elapsed;
    if (last == null) return;
    // Clamp a long gap (a dropped frame, a debugger pause) to one frame.
    final dt = math.min((elapsed - last).inMicroseconds / 1e6, 1 / 30);
    _now += Duration(microseconds: (dt * 1e6).round());
    if (!_onScreen()) {
      _ticker.stop();

      _visibilityPoll ??= Timer.periodic(const Duration(milliseconds: 500), (
        _,
      ) {
        if (!mounted || !_wantsFrames) return;
        if (_onScreen()) {
          _visibilityPoll?.cancel();
          _visibilityPoll = null;
          _sync();
        }
      });
      return;
    }
    for (final l in _lanes) {
      _advance(l, dt);
    }
  }

  void _advance(_Lane l, double dt) {
    final g = l.glide;
    if (g != null) {
      final t = ((_now - g.start).inMicroseconds / g.length.inMicroseconds)
          .clamp(0.0, 1.0);
      l.offset = g.from + (g.to - g.from) * Motion.emphasizedDecel.transform(t);
      l.changed();
      if (t >= 1) {
        l.glide = null;
        final done = _afterGlide;
        _afterGlide = null;
        done?.call();
      }
      return;
    }
    if (l.held) {
      // Held only while a finger is on it: never stall on a lost "up".
      if (_fingers.containsValue(l)) return;
      _release(l);
    }
    if (l.fling.abs() > 4) {
      l.move(l.fling * dt);
      // Friction: about 0.35 s to lose most of the speed.
      l.fling *= math.exp(-dt * 6);
      l.resumeAt = _now + StarterMarquee.resumeAfter;
      l.ease = 0;
      return;
    }
    l.fling = 0;
    if (_now < l.resumeAt) return;
    // Ease the drift back in over about 0.8 s.
    l.ease = math.min(1, l.ease + dt / 0.8);
    final e = Curves.easeInOut.transform(l.ease);
    l.move(l.direction * l.speed * e * dt);
  }

  // --- touch -----------------------------------------------------------

  /// Fingers on the rows, by pointer, and the row each went down on.
  final Map<int, _Lane> _fingers = {};
  bool _routed = false;

  /// Fingers on the rows (tests).
  @visibleForTesting
  int get fingers => _fingers.length;

  void _down(_Lane l, PointerDownEvent e) {
    _fingers[e.pointer] = l;
    if (!_routed) {
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
      _routed = true;
    }
    _hold(l);
  }

  /// Every pointer event of the app: an up or cancel of a finger that went
  /// down on a row releases it, wherever the row is by then.
  void _onGlobalPointer(PointerEvent e) {
    if (e is! PointerUpEvent && e is! PointerCancelEvent) return;
    final l = _fingers.remove(e.pointer);
    if (l != null && !_fingers.containsValue(l)) _release(l);
    _unroute();
  }

  void _unroute() {
    if (!_routed || _fingers.isNotEmpty) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    _routed = false;
  }

  void _hold(_Lane l) {
    l.held = true;
    l.fling = 0;
    l.ease = 0;
  }

  void _release(_Lane l) {
    l.held = false;
    l.resumeAt = _now + StarterMarquee.resumeAfter;
  }

  // A sideways drag scrolls the row with the finger, then flings.
  void _dragUpdate(_Lane l, DragUpdateDetails d) {
    l.held = true;
    l.fling = 0;
    l.move(-d.delta.dx);
  }

  void _dragEnd(_Lane l, DragEndDetails d) {
    l.fling = (-d.velocity.pixelsPerSecond.dx).clamp(-4000.0, 4000.0);
    if (!_fingers.containsValue(l)) _release(l);
    l.held = false;
    l.resumeAt = _now + StarterMarquee.resumeAfter;
    _sync();
  }

  // --- surprise me -----------------------------------------------------

  /// Picks a prompt at random. With motion, its row glides it to the middle
  /// and it lights up for a moment before [StarterMarquee.onPick]; without,
  /// it is picked at once.
  void surprise({math.Random? random}) {
    if (widget.prompts.isEmpty || _picked.value != null) return;
    final rnd = random ?? math.Random();
    final p = widget.prompts[rnd.nextInt(widget.prompts.length)];
    final row = _rows.indexWhere((r) => r.contains(p));
    final track = row < 0
        ? null
        : _trackKeys[row].currentContext?.findRenderObject();
    if (_still || !_wantsFrames || track is! _RenderMarqueeTrack) {
      widget.onPick(p);
      return;
    }
    final target = track.offsetCentring(_rows[row].indexOf(p));
    final l = _lanes[row];
    if (target == null) {
      widget.onPick(p);
      return;
    }
    _picked.value = p;
    l.held = false;
    l.fling = 0;
    // Glide forward (in the row's direction) to the nearest copy.
    final period = track.period;
    var to = target;
    if (l.direction > 0) {
      while (to < l.offset) {
        to += period;
      }
    } else {
      while (to > l.offset) {
        to -= period;
      }
    }
    l.glide = (
      from: l.offset,
      to: to,
      start: _now,
      length: const Duration(milliseconds: 650),
    );
    _afterGlide = () {
      // Let the chosen chip show for a beat, then send.
      Timer(const Duration(milliseconds: 260), () {
        if (!mounted) return;
        _picked.value = null;
        l.resumeAt = _now + StarterMarquee.resumeAfter;
        l.ease = 0;
        widget.onPick(p);
      });
    };
    _sync();
  }

  // --- build -----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _rows.length; i++) ...[
          if (i > 0) const SizedBox(height: StarterMarquee.rowGap),
          _still ? _stillRow(i) : _movingRow(i, t),
        ],
        const SizedBox(height: 14),
        Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: widget.padding),
            child: _SurpriseButton(onTap: surprise),
          ),
        ),
      ],
    );
  }

  List<Widget> _chips(int row, {required bool semantics}) => [
    for (final p in _rows[row])
      Padding(
        padding: const EdgeInsets.only(right: StarterMarquee.gap),
        child: _StarterChip(
          key: semantics ? ValueKey('starter-${p.text}') : null,
          prompt: p,
          picked: _picked,
          onTap: () => widget.onPick(p),
        ),
      ),
  ];

  // Its overscroll stays here: at either end a swipe does nothing more (it
  // never hands off to the chat list).
  Widget _stillRow(int row) => DrawerSwipeExclusion(
    child: NotificationListener<ScrollNotification>(
      onNotification: (_) => true,
      child: SizedBox(
        height: StarterMarquee.chipHeight,
        child: SingleChildScrollView(
          key: ValueKey('starter-row-$row'),
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.only(
            left: widget.padding,
            right: widget.padding - StarterMarquee.gap,
          ),
          child: Row(children: _chips(row, semantics: true)),
        ),
      ),
    ),
  );

  Widget _movingRow(int row, HermesTokens t) {
    final lane = _lanes[row];
    // Enough copies to cover the window's width twice over (a row is never
    // wider than the window); each chip is at least ~110 dp wide. Not a
    // LayoutBuilder: the empty chat measures its content's intrinsic height.
    final n = _rows[row].length;
    final minCopy = n * 110.0;
    final copies = math.max(
      2,
      1 + (MediaQuery.sizeOf(context).width / math.max(minCopy, 1)).ceil(),
    );
    final settings = MediaQuery.maybeGestureSettingsOf(context);
    return Listener(
      onPointerDown: (e) => _down(lane, e),
      child: KeyedSubtree(
        key: ValueKey('starter-row-$row'),
        // The row owns sideways drags: they scroll it and never reach the
        // chat list or Tasks swipe (round 8).
        child: DrawerSwipeExclusion(
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            gestures: {
              HorizontalDragGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    HorizontalDragGestureRecognizer
                  >(
                    () => HorizontalDragGestureRecognizer(debugOwner: this),
                    (r) => r
                      ..gestureSettings = settings
                      ..dragStartBehavior = DragStartBehavior.down
                      ..onUpdate = ((d) => _dragUpdate(lane, d))
                      ..onEnd = ((d) => _dragEnd(lane, d))
                      ..onCancel = (() {
                        lane.held = _fingers.containsValue(lane);
                        if (!lane.held) _release(lane);
                      }),
                  ),
            },
            child: RepaintBoundary(
              child: _MarqueeTrack(
                key: _trackKeys[row],
                lane: lane,
                copies: copies,
                fade: widget.edgeFade,
                fadeColor: t.bg,
                child: RepaintBoundary(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Every copy is in the semantics tree: the clip keeps
                      // only the chips on screen, and a chip is never on
                      // screen twice (a copy is wider than the window).
                      for (var c = 0; c < copies; c++)
                        ..._chips(row, semantics: c == 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row's viewport: lays its child (the copies) out once and paints it
/// shifted by the lane's offset, wrapping every [copies]th of its width.
class _MarqueeTrack extends SingleChildRenderObjectWidget {
  const _MarqueeTrack({
    super.key,
    required this.lane,
    required this.copies,
    required this.fade,
    required this.fadeColor,
    super.child,
  });

  final _Lane lane;
  final int copies;
  final double fade;
  final Color fadeColor;

  @override
  _RenderMarqueeTrack createRenderObject(BuildContext context) =>
      _RenderMarqueeTrack(lane, copies, fade, fadeColor);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMarqueeTrack renderObject,
  ) {
    renderObject
      ..lane = lane
      ..copies = copies
      ..fade = fade
      ..fadeColor = fadeColor;
  }
}

class _RenderMarqueeTrack extends RenderProxyBox {
  _RenderMarqueeTrack(this._lane, this._copies, this._fade, this._fadeColor);

  _Lane _lane;
  set lane(_Lane v) {
    if (identical(v, _lane)) return;
    if (attached) _lane.removeListener(_moved);
    _lane = v;
    if (attached) _lane.addListener(_moved);
    markNeedsPaint();
  }

  int _copies;
  set copies(int v) {
    if (v == _copies) return;
    _copies = v;
    markNeedsPaint();
  }

  double _fade;
  set fade(double v) {
    if (v == _fade) return;
    _fade = v;
    markNeedsPaint();
  }

  Color _fadeColor;
  set fadeColor(Color v) {
    if (v == _fadeColor) return;
    _fadeColor = v;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _lane.addListener(_moved);
  }

  @override
  void detach() {
    _lane.removeListener(_moved);
    super.detach();
  }

  final _sinceSemantics = Stopwatch();

  /// Each frame repaints; while assistive technology listens, the chips'
  /// semantic positions follow at most four times a second.
  void _moved() {
    markNeedsPaint();
    if (owner?.semanticsOwner == null) return;
    if (_sinceSemantics.isRunning &&
        _sinceSemantics.elapsedMilliseconds < 250) {
      return;
    }
    _sinceSemantics
      ..reset()
      ..start();
    markNeedsSemanticsUpdate();
  }

  /// One copy's width (the wrap distance).
  double get period {
    final c = child;
    if (c == null || !c.hasSize || _copies <= 0) return 1;
    return math.max(1, c.size.width / _copies);
  }

  double get _shift => _lane.offset % period;

  @override
  void performLayout() {
    final c = child;
    if (c == null) {
      size = constraints.constrain(Size(constraints.maxWidth, 0));
      return;
    }
    c.layout(
      BoxConstraints(maxHeight: constraints.maxHeight),
      parentUsesSize: true,
    );
    size = constraints.constrain(Size(constraints.maxWidth, c.size.height));
  }

  /// The offset that puts chip [index] of the first copy in the middle.
  double? offsetCentring(int index) {
    final row = child;
    if (row == null || index < 0) return null;
    // child → RepaintBoundary → Row; the first copy's chips are the Row's
    // first children (each a Padding).
    RenderObject? r = row;
    while (r is RenderProxyBox) {
      r = r.child;
    }
    if (r is! RenderFlex) return null;
    var i = 0;
    RenderBox? b = r.firstChild;
    while (b != null && i < index) {
      b = r.childAfter(b);
      i++;
    }
    if (b == null) return null;
    final x = (b.parentData! as FlexParentData).offset.dx;
    final w = b.size.width - StarterMarquee.gap;
    return x + w / 2 - size.width / 2;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final c = child;
    if (c == null) return false;
    return result.addWithPaintOffset(
      offset: Offset(-_shift, 0),
      position: position,
      hitTest: (result, p) => c.hitTest(result, position: p),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(-_shift, 0, 0, 1);
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject child) =>
      Offset(_shift, 0) & size;

  final _clip = LayerHandle<ClipRectLayer>();

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final c = child;
    if (c == null) return;
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (context, o) => context.paintChild(c, o + Offset(-_shift, 0)),
      oldLayer: _clip.layer,
    );
    // The edge fades: the background drawn over the chips, so no layer.
    final f = math.min(_fade, size.width / 4);
    if (f <= 0) return;
    final canvas = context.canvas;
    final solid = _fadeColor;
    final clear = _fadeColor.withValues(alpha: 0);
    final left = offset & Size(f, size.height);
    final right =
        Offset(offset.dx + size.width - f, offset.dy) & Size(f, size.height);
    canvas
      ..drawRect(
        left,
        Paint()
          ..shader = LinearGradient(colors: [solid, clear]).createShader(left),
      )
      ..drawRect(
        right,
        Paint()
          ..shader = LinearGradient(colors: [clear, solid]).createShader(right),
      );
  }
}

/// A compact rounded starter chip: emoji and label, 38 dp tall.
class _StarterChip extends StatelessWidget {
  const _StarterChip({
    super.key,
    required this.prompt,
    required this.picked,
    required this.onTap,
  });

  final StarterPrompt prompt;
  final ValueListenable<StarterPrompt?> picked;
  final VoidCallback onTap;

  /// Emoji fonts tried before the platform's own fallback.
  static const emojiFonts = [
    'Noto Color Emoji',
    'Apple Color Emoji',
    'Segoe UI Emoji',
  ];

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ValueListenableBuilder<StarterPrompt?>(
      valueListenable: picked,
      builder: (context, chosen, child) {
        final on = chosen == prompt;
        return AnimatedScale(
          scale: on ? 1.06 : 1,
          duration: const Duration(milliseconds: 220),
          curve: Motion.pop,
          child: Material(
            color: on ? t.surfaceHigh : t.surface,
            shape: StadiumBorder(
              side: BorderSide(
                color: on ? t.text : (dark ? t.hairline : t.outline),
                width: on ? 1.5 : 1,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: child,
          ),
        );
      },
      child: Semantics(
        button: true,
        label: prompt.text,
        hint: 'Sends this message',
        onTap: onTap,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: StarterMarquee.chipHeight,
              maxWidth: 320,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 14, 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    prompt.emoji,
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.2,
                      fontFamilyFallback: emojiFonts,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      prompt.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.row
                          .copyWith(
                            fontSize: 15,
                            height: 20 / 15,
                            color: t.text,
                          )
                          .hermesWeight(500),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The dark pill under the rows (light pill in the dark theme).
class _SurpriseButton extends StatelessWidget {
  const _SurpriseButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Semantics(
      button: true,
      label: 'Surprise me',
      hint: 'Sends one of these suggestions at random',
      onTap: onTap,
      excludeSemantics: true,
      // A compact 40 dp pill; the tap area around it stays 48 dp.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Material(
            key: const ValueKey('starter-surprise'),
            color: t.text,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 40, minWidth: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.casino_outlined, size: 16, color: t.bg),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Surprise me',
                          style: t.row
                              .copyWith(
                                fontSize: 14.5,
                                height: 20 / 14.5,
                                color: t.bg,
                              )
                              .hermesWeight(600),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
