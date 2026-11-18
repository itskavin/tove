import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../call/call_controller.dart';
import '../../chat/chat.dart';
import '../common/shimmer.dart';
import '../common/size_reporter.dart';
import '../orb/orb.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../thread/follow_scroll.dart';
import 'live_content.dart';
import 'live_link_cards.dart';
import 'live_panel.dart';
import 'live_transcript.dart';
import 'live_work.dart';

export 'live_content.dart' show LiveContent, liveContentFor;
export 'live_panel.dart' show LiveBlockBuilder;

/// Maps the call to the orb state (spec §6.1).
OrbState liveOrbState(CallController call, {required bool awaitingReply}) {
  switch (call.phase) {
    case CallPhase.idle:
      return OrbState.ended;
    case CallPhase.connecting:
      return OrbState.connecting;
    case CallPhase.failed:
      return OrbState.error;
    case CallPhase.live:
      final l = call.levels.value;
      final out = l.output;
      final hermes = out != null
          ? out > 0.02 || call.hermesSpeaking
          : call.hermesSpeaking;
      if (hermes) return OrbState.assistantSpeaking;
      if (call.muted) return OrbState.muted;
      final input = l.input;
      if (call.userSpeaking || (input != null && input > 0.08)) {
        return OrbState.userSpeaking;
      }
      if (call.activeTasks > 0 || awaitingReply) return OrbState.thinking;
      return OrbState.listening;
  }
}

/// The status label under the orb (spec §2.3): only for the call's own
/// states. Hermes' work shows in the [LiveWorkStrip] above the composer, not
/// here. Null when nothing should show.
String? liveStatus(CallController call) {
  switch (call.phase) {
    case CallPhase.connecting:
      return 'Connecting…';
    case CallPhase.failed:
      return call.error ?? 'Live voice stopped';
    case CallPhase.idle:
      return null;
    case CallPhase.live:
      return call.muted ? 'Muted' : null;
  }
}

/// Live mode on top of the thread: the entry widget the shell places over
/// the thread (see README.md here). Spec §2.3, §4.1, §4.2, §6.2, §6.4.
///
/// [enter] runs 0 → 1 when live mode opens and back when it closes; the orb
/// flies between [heroRect] (the composer's action button) and its place.
/// The orb glides between a large centred pose and a small docked pose over
/// the [LivePanel] (rich content), nudges towards whoever speaks and
/// flinches when the user interrupts ([OrbChoreographer]). Touch follows the
/// finger; a downward pull reveals the live conversation. Running work
/// (delegated tasks, a typed reply's thinking and tools) shows compactly in
/// the [LiveWorkStrip] under the orb, above the composer, and never moves
/// the orb into its docked pose; only a finished result does.
class LiveOverlay extends StatefulWidget {
  const LiveOverlay({
    super.key,
    required this.call,
    required this.chat,
    required this.enter,
    required this.since,
    required this.topInset,
    required this.composerTop,
    required this.onRetry,
    this.heroRect,
    this.onOpenSite,
    this.blockBuilder,
  });

  final CallController call;
  final ChatController chat;
  final Animation<double> enter;

  /// The live session's start; older content and tasks are not shown.
  final DateTime since;
  final double topInset;

  /// The composer's top edge in this widget's coordinates.
  final double composerTop;
  final VoidCallback onRetry;
  final Rect? heroRect;

  /// Opens a link card. Defaults to [liveSiteOpener] (in-app browser view).
  final ValueChanged<LiveSite>? onOpenSite;

  /// Extra blocks under an answer (the hermes-ui hook).
  final LiveBlockBuilder? blockBuilder;

  @override
  State<LiveOverlay> createState() => LiveOverlayState();
}

class LiveOverlayState extends State<LiveOverlay>
    with TickerProviderStateMixin {
  /// The panel's text: in 320 ms with the first 80 ms held, so it starts
  /// its fade 80 ms after the dock starts (§6.2); out 160 ms.
  late final AnimationController _text = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    reverseDuration: const Duration(milliseconds: 160),
  );
  late final _textCurve = CurvedAnimation(
    parent: _text,
    curve: const Interval(0.25, 1, curve: Curves.linear),
  );
  late CurvedAnimation _enterCurve = _curveEnter();
  final _scroll = FollowScrollController();
  final _engine = OrbEngine();
  final _choreo = OrbChoreographer();

  /// When each finished piece of work was first seen (it lingers a while).
  final Map<String, DateTime> _endedAt = {};
  List<LiveWork> _work = const [];
  double _stripH = 0;
  Timer? _expiry;

  /// A newer result that arrived while the reader was scrolled into the
  /// one on screen.
  LiveContent? _newer;
  static const double _readingOffset = 48;

  /// The result waiting behind the pill, for tests.
  LiveContent? get newer => _newer;

  /// Shows the result waiting behind the "New result" pill.
  void showNewer() {
    final n = _newer;
    if (n == null) return;
    _scroll.enabled = false;
    setState(() {
      _newer = null;
      _shown = n;
      _selected = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _scroll.enabled = true;
    });
  }

  LiveContent? _shown;
  DateTime? _clearedAt;
  String? _selected;
  DateTime? _selectedAt;
  bool _wasHermes = false;
  bool _placed = false;
  bool _conversationOpen = false;
  Offset? _touchStart;
  Offset _touchDelta = Offset.zero;

  /// True while rich content is shown and the orb is (going) docked.
  bool get docked => _shown != null || _conversationOpen;

  bool get conversationOpen => _conversationOpen;

  /// The orb's motion, for tests and diagnostics.
  OrbChoreographer get choreographer => _choreo;

  /// The work in the strip now.
  List<LiveWork> get work => _work;

  /// The content in the panel, or null.
  LiveContent? get shown => _shown;

  @override
  void initState() {
    super.initState();
    _engine.choreographer = _choreo;
    widget.call.addListener(_sync);
    widget.chat.addListener(_sync);
    widget.call.levels.addListener(_react);
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  CurvedAnimation _curveEnter() => CurvedAnimation(
    parent: widget.enter,
    curve: Motion.emphasizedDecel,
    reverseCurve: Curves.easeInOutCubic,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _choreo.reduced = _reduced;
  }

  @override
  void didUpdateWidget(LiveOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enter != widget.enter) {
      _enterCurve.dispose();
      _enterCurve = _curveEnter();
    }
    if (oldWidget.call != widget.call) {
      oldWidget.call.removeListener(_sync);
      oldWidget.call.levels.removeListener(_react);
      widget.call.addListener(_sync);
      widget.call.levels.addListener(_react);
    }
    if (oldWidget.chat != widget.chat) {
      oldWidget.chat.removeListener(_sync);
      widget.chat.addListener(_sync);
    }
    if (oldWidget.since != widget.since) {
      _clearedAt = null;
      _shown = null;
      _conversationOpen = false;
      _choreo.releaseTouch();
      _selected = null;
      _endedAt.clear();
      _work = const [];
      _newer = null;
      _text.value = 0;
    }
  }

  @override
  void dispose() {
    widget.call.removeListener(_sync);
    widget.chat.removeListener(_sync);
    widget.call.levels.removeListener(_react);
    _expiry?.cancel();
    _enterCurve.dispose();
    _textCurve.dispose();
    _text.dispose();
    _scroll.dispose();
    _engine.dispose();
    _choreo.dispose();
    super.dispose();
  }

  bool get _reduced => Motion.reduced(context);

  void _react() {
    final call = widget.call;
    final l = call.levels.value;
    final out = OrbEngine.normalise(l.output);
    _choreo.react(
      userLevel: OrbEngine.normalise(l.input),
      hermesLevel: out,
      userSpeaking: call.userSpeaking,
      hermesSpeaking: call.hermesSpeaking || out > 0.1,
    );
  }

  LiveContent? _resolve() {
    final call = widget.call, chat = widget.chat;
    final latest = liveContentFor(
      call: call,
      chat: chat,
      since: widget.since,
      clearedAt: _clearedAt,
    );
    final sel = _selected;
    if (sel != null) {
      final picked = liveContentById(sel, call: call, chat: chat);
      final newer =
          latest != null &&
          latest.id != sel &&
          latest.time.isAfter(_selectedAt ?? widget.since);
      if (picked != null && !newer) return picked;
      _selected = null;
    }
    return latest;
  }

  void _sync() {
    if (!mounted) return;
    final call = widget.call;
    final now = liveNow();
    _work = liveWorkFrom(
      call: call,
      chat: widget.chat,
      since: widget.since,
      now: now,
      endedAt: _endedAt,
    );
    _scheduleExpiry(now);
    _react();
    final content = _resolve();
    // A new spoken answer long after the last content, with the panel at
    // the top, clears it (§6.2 undock).
    final hermes = call.hermesSpeaking;
    if (!_conversationOpen &&
        hermes &&
        !_wasHermes &&
        _shown != null &&
        content != null) {
      final old = DateTime.now().difference(content.time).inSeconds > 3;
      final top = !_scroll.hasClients || _scroll.offset <= 0;
      if (old && top && !content.streaming && _selected == null) {
        _wasHermes = hermes;
        unawaited(clear());
        return;
      }
    }
    _wasHermes = hermes;
    if (content != null) {
      final first = !docked;
      final swapped = _shown != null && _shown!.id != content.id;
      // The reader is part-way into a result: a newer one waits behind a
      // "New result" pill instead of replacing the text under their eyes.
      if (swapped &&
          !_conversationOpen &&
          _scroll.hasClients &&
          _scroll.offset > _readingOffset) {
        final current = liveContentById(
          _shown!.id,
          call: call,
          chat: widget.chat,
        );
        setState(() {
          if (current != null) _shown = current;
          _newer = content;
        });
        return;
      }
      _newer = null;
      final firstResult =
          _shown?.id == content.id &&
          _shown!.text.trim().isEmpty &&
          content.text.trim().isNotEmpty &&
          !content.streaming;
      final resetScroll = !_conversationOpen && (swapped || firstResult);
      if (resetScroll) _scroll.enabled = false;
      setState(() => _shown = content);
      if (first) _textIn();
      if (resetScroll) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (!_conversationOpen && _scroll.hasClients) _scroll.jumpTo(0);
          _scroll.enabled = true;
        });
      }
    } else {
      setState(() {});
    }
  }

  void _scheduleExpiry(DateTime now) {
    _expiry?.cancel();
    final at = liveWorkExpiry(_work, _endedAt);
    if (at == null) return;
    final wait = at.difference(now) + const Duration(milliseconds: 20);
    _expiry = Timer(wait.isNegative ? Duration.zero : wait, _sync);
  }

  void _textIn() {
    if (_reduced) {
      // §8.2: a 120 ms cross-fade and no travel.
      _text.duration = const Duration(milliseconds: 120);
      _textCurve.curve = Curves.linear;
    } else {
      _text.duration = const Duration(milliseconds: 320);
      _textCurve.curve = const Interval(0.25, 1);
    }
    _text.forward();
  }

  /// Clears the panel: the text fades out (160 ms), then the orb glides
  /// back to the centre.
  Future<void> clear() async {
    _clearedAt = DateTime.now();
    _selected = null;
    _newer = null;
    await _text.reverse();
    if (!mounted) return;
    setState(() {
      _shown = null;
      _conversationOpen = false;
    });
  }

  /// Pulling the orb down reveals the actual conversation while voice stays on.
  void showConversation() {
    final first = !docked;
    setState(() => _conversationOpen = true);
    if (first || _text.value < 1) _textIn();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.toEnd();
    });
  }

  void _touchDown(Offset position) {
    _touchStart = position;
    _touchDelta = Offset.zero;
    _choreo.touch(Offset.zero);
  }

  void _touchMove(Offset position) {
    _touchStart ??= position;
    _touchDelta = position - _touchStart!;
    _choreo.touch(_touchDelta);
  }

  void _touchEnd([Offset velocity = Offset.zero]) {
    final delta = _touchDelta;
    _touchStart = null;
    _touchDelta = Offset.zero;
    _choreo.releaseTouch(velocity);
    if (delta.dy > 64 || (delta.dy > 20 && velocity.dy > 600)) {
      showConversation();
    } else if (docked && delta.dy < -64) {
      unawaited(clear());
    }
  }

  void _cancelTouch() {
    _touchStart = null;
    _touchDelta = Offset.zero;
    _choreo.releaseTouch();
  }

  /// Shows [contentId] in the panel (a tapped task card).
  void expand(String contentId) {
    final c = liveContentById(contentId, call: widget.call, chat: widget.chat);
    if (c == null) return;
    final first = _shown == null;
    setState(() {
      _selected = contentId;
      _conversationOpen = false;
      _selectedAt = DateTime.now();
      _shown = c;
    });
    if (first) {
      _textIn();
    } else if (_text.status == AnimationStatus.reverse || _text.value < 1) {
      _text.forward();
    }
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _openSite(LiveSite s) {
    final cb = widget.onOpenSite;
    if (cb != null) {
      cb(s);
    } else {
      unawaited(liveSiteOpener(s.uri));
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        return ListenableBuilder(
          listenable: Listenable.merge([widget.call, widget.chat]),
          builder: (context, _) {
            final status = _status();
            final strip = !_conversationOpen && _work.isNotEmpty;
            // The orb keeps its size; it only rises when the strip would
            // reach it (short or landscape screens, large text).
            final workTop = strip
                ? widget.composerTop - _stripH - _stripGap
                : widget.composerTop;
            final layout = OrbStageLayout(
              size: size,
              padding: mq.padding,
              topInset: widget.topInset,
              composerTop: workTop,
              cardsExtent: 0,
              labelShown: status != null,
            );
            final stage = docked ? OrbStage.docked : OrbStage.centred;
            final target = OrbChoreography.pose(stage, layout);
            _choreo.moveTo(target, diameter: layout.diameter, animate: _placed);
            _placed = true;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                if (!docked)
                  Positioned(
                    top: widget.topInset,
                    left: 0,
                    right: 0,
                    bottom: math.max(0, size.height - widget.composerTop),
                    child: GestureDetector(
                      key: const ValueKey('live-pull-surface'),
                      behavior: HitTestBehavior.translucent,
                      onVerticalDragStart: (d) => _touchDown(d.globalPosition),
                      onVerticalDragUpdate: (d) => _touchMove(d.globalPosition),
                      onVerticalDragEnd: (d) =>
                          _touchEnd(d.velocity.pixelsPerSecond),
                      onVerticalDragCancel: _cancelTouch,
                    ),
                  ),
                if (docked) _panel(context, layout, target),
                Positioned.fill(
                  child: Flow(
                    delegate: _LiveFlow(
                      choreo: _choreo,
                      enter: _enterCurve,
                      rawEnter: widget.enter,
                      hero: widget.heroRect,
                      diameter: layout.diameter,
                      reduced: _reduced,
                      sideInset: Sp.content,
                    ),
                    children: [
                      _orb(context, layout.diameter, status),
                      _label(context, status),
                      // No task cards near the orb: the status label
                      // ("Working on it · 12 s") is the only progress.
                      const SizedBox.shrink(),
                    ],
                  ),
                ),
                if (strip)
                  Positioned(
                    left: Sp.controls,
                    right: Sp.controls,
                    bottom: math.max(
                      0,
                      size.height - widget.composerTop + _stripGap,
                    ),
                    child: FadeTransition(
                      opacity: widget.enter,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: Sz.sheetMaxWidth,
                          ),
                          child: SizeReporter(
                            onSize: _onStripSize,
                            child: LiveWorkStrip(items: _work),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (widget.call.inCall &&
                    widget.call.background == BackgroundSupport.limited &&
                    widget.call.backgroundNote != null)
                  Positioned(
                    top: widget.topInset + 8,
                    left: Sp.controls,
                    right: Sp.controls,
                    child: _Notice(text: widget.call.backgroundNote!),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  static const double _stripGap = 8;

  void _onStripSize(Size s) {
    if (s.height == _stripH || !mounted) return;
    setState(() => _stripH = s.height);
  }

  /// A typed turn's reply is on its way with nothing written yet.
  bool _awaitingReply() {
    for (final m in widget.chat.messages.reversed) {
      if (!m.isAssistant || m.created.isBefore(widget.since)) continue;
      return m.isStreaming && m.text.isEmpty;
    }
    return false;
  }

  String? _status() => liveStatus(widget.call);

  Widget _orb(BuildContext context, double d, String? status) {
    final orb = HermesOrb(
      state: liveOrbState(widget.call, awaitingReply: _awaitingReply()),
      size: d,
      levels: widget.call.levels,
      engine: _engine,
      active: widget.enter.value > 0,
    );
    // The hit area follows the painted orb through Flow's transform.
    final label = docked ? 'Hide the answer' : 'Show live conversation';
    return Stack(
      alignment: Alignment.center,
      children: [
        IgnorePointer(child: orb),
        Semantics(
          button: true,
          label: label,
          hint: 'Drag down to show the live conversation',
          onTap: docked ? () => unawaited(clear()) : showConversation,
          child: GestureDetector(
            key: const ValueKey('live-orb-touch'),
            behavior: HitTestBehavior.opaque,
            onPanDown: (d) => _touchDown(d.globalPosition),
            onTapUp: (_) => _touchEnd(),
            onTapCancel: () => _choreo.releaseTouch(),
            onTap: docked ? () => unawaited(clear()) : showConversation,
            onPanStart: (d) => _touchMove(d.globalPosition),
            onPanUpdate: (d) => _touchMove(d.globalPosition),
            onPanEnd: (d) => _touchEnd(d.velocity.pixelsPerSecond),
            onPanCancel: _cancelTouch,
            child: SizedBox.square(
              dimension: math.max(Sz.hit, d * (docked ? Sz.dockRatio : 0.95)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _label(BuildContext context, String? status) {
    final t = HermesTokens.of(context);
    final failed = widget.call.phase == CallPhase.failed;
    final shimmer =
        status != null &&
        (status.startsWith('Working') ||
            status == 'Thinking…' ||
            status == 'Connecting…');
    final label = status == null
        ? Semantics(
            key: const ValueKey('none'),
            label: widget.call.phase == CallPhase.live
                ? 'Live voice is on'
                : null,
            child: const SizedBox(width: 160, height: 16),
          )
        : Column(
            key: ValueKey(failed ? 'failed' : status),
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: failed
                    ? Text(
                        status,
                        textAlign: TextAlign.center,
                        style: t.row.copyWith(fontWeight: FontWeight.w400),
                      )
                    : shimmer
                    ? ShimmerText(status)
                    : Text(status, style: t.label, textAlign: TextAlign.center),
              ),
              if (failed) ...[
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: widget.onRetry,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(140, 44),
                  ),
                  child: const Text('Try again'),
                ),
              ],
            ],
          );
    return Semantics(
      liveRegion: true,
      child: AnimatedSwitcher(
        duration: Motion.of(context, const Duration(milliseconds: 200)),
        reverseDuration: Motion.of(context, const Duration(milliseconds: 160)),
        switchInCurve: Motion.emphasizedDecel,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          children: [...previous, ?current],
        ),
        transitionBuilder: (child, a) => FadeTransition(
          opacity: a,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.25),
              end: Offset.zero,
            ).animate(a),
            child: child,
          ),
        ),
        child: label,
      ),
    );
  }

  Widget _panel(BuildContext context, OrbStageLayout layout, OrbPose docked) {
    final content = _shown;
    final fadeStart = docked.centre.dy - 24;
    final clearFrom = fadeStart;
    if (_conversationOpen) {
      return Positioned.fill(
        child: FadeTransition(
          opacity: _textCurve,
          child: LiveTranscriptPanel(
            call: widget.call,
            chat: widget.chat,
            since: widget.since,
            scroll: _scroll,
            topInset: widget.topInset,
            fadeStart: fadeStart,
            fadeEnd: widget.composerTop,
            bottomPadding: math.max(0, layout.size.height - clearFrom) + Sp.l,
            onCollapse: () => unawaited(clear()),
            onOpenSite: _openSite,
          ),
        ),
      );
    }
    final newer = _newer;
    return Positioned.fill(
      child: FadeTransition(
        opacity: _textCurve,
        child: Stack(
          children: [
            Positioned.fill(
              child: Dismissible(
                key: ValueKey('panel-${content!.id}'),
                direction: DismissDirection.horizontal,
                resizeDuration: null,
                onDismissed: (_) => unawaited(clear()),
                child: LivePanel(
                  content: content,
                  scroll: _scroll,
                  topInset: widget.topInset,
                  fadeStart: fadeStart,
                  fadeEnd: widget.composerTop,
                  bottomPadding:
                      math.max(0, layout.size.height - clearFrom) + Sp.l,
                  onCollapse: () => unawaited(clear()),
                  onOpenSite: _openSite,
                  blockBuilder: widget.blockBuilder,
                ),
              ),
            ),
            if (newer != null)
              Positioned(
                top: widget.topInset + 8,
                left: 0,
                right: 0,
                child: Center(
                  child: Semantics(
                    liveRegion: true,
                    child: FilledButton.tonalIcon(
                      key: const ValueKey('live-new-result'),
                      onPressed: showNewer,
                      icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                      label: const Text('New result'),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Positions the orb, its label and the task cards from the choreographer
/// at paint time: moving them repaints this layer only, with no rebuild or
/// relayout. Children: orb (D × D), label, cards.
class _LiveFlow extends FlowDelegate {
  _LiveFlow({
    required this.choreo,
    required this.enter,
    required this.rawEnter,
    required this.hero,
    required this.diameter,
    required this.reduced,
    required this.sideInset,
  }) : super(repaint: Listenable.merge([choreo, enter]));

  final OrbChoreographer choreo;
  final Animation<double> enter, rawEnter;
  final Rect? hero;
  final double diameter;
  final bool reduced;
  final double sideInset;

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) {
    if (i == 0) return BoxConstraints.tight(Size.square(diameter));
    final w = math.max(0.0, constraints.maxWidth - 2 * sideInset);
    return BoxConstraints(maxWidth: w, maxHeight: constraints.maxHeight);
  }

  @override
  void paintChildren(FlowPaintingContext context) {
    final d = diameter;
    final w = context.size.width;
    final dk = choreo.dock;
    final base = choreo.pose.centre;
    var c = choreo.centre;
    var scale = choreo.pulse;
    var opacity = 1.0;
    final e = enter.value;
    final h = hero;
    if (reduced) {
      opacity = rawEnter.value;
    } else if (h != null && e < 1) {
      final s0 = h.width / (0.86 * d);
      c = Offset.lerp(h.center, c, e)!;
      scale *= s0 + (1 - s0) * e;
      if (rawEnter.status == AnimationStatus.reverse) {
        // The last 80 ms cross-fade into the waveform glyph.
        opacity = (rawEnter.value / (80 / 340)).clamp(0.0, 1.0);
      }
    } else if (h == null) {
      opacity = rawEnter.value;
    }
    context.paintChild(
      0,
      transform: Matrix4.translationValues(c.dx, c.dy, 0)
        ..rotateZ(choreo.touchTilt * 0.15)
        ..scaleByDouble(
          scale *
              (1 + choreo.touchPressure * 0.035 - choreo.touchStretch * 0.45),
          scale * (1 + choreo.touchPressure * 0.035 + choreo.touchStretch),
          1,
          1,
        )
        ..translateByDouble(-d / 2, -d / 2, 0, 1),
      opacity: opacity.clamp(0.0, 1.0),
    );

    final fade = rawEnter.value.clamp(0.0, 1.0);
    // Label: under the orb, 16 dp centred → 8 dp docked (§4.1, §4.2).
    final r = d / 2 * (0.86 + (Sz.dockRatio * 0.8 - 0.86) * dk);
    final top = base.dy + r + (16 + (8 - 16) * dk);
    final ls = context.getChildSize(1)!;
    context.paintChild(
      1,
      transform: Matrix4.translationValues(w / 2 - ls.width / 2, top, 0),
      opacity: fade,
    );
    // Cards: stacked above the orb.
    final cs = context.getChildSize(2)!;
    if (cs.height > 0) {
      final bottom =
          base.dy - OrbChoreography.radius(d, dk) - OrbChoreography.cardsGap;
      context.paintChild(
        2,
        transform: Matrix4.translationValues(
          w / 2 - cs.width / 2,
          bottom - cs.height,
          0,
        ),
        opacity: fade,
      );
    }
  }

  @override
  bool shouldRelayout(_LiveFlow old) =>
      old.diameter != diameter || old.sideInset != sideInset;

  @override
  bool shouldRepaint(_LiveFlow old) =>
      old.choreo != choreo ||
      old.enter != enter ||
      old.hero != hero ||
      old.diameter != diameter ||
      old.reduced != reduced;
}

/// The quiet "limited background" note under the app bar (spec §5.10).
class _Notice extends StatelessWidget {
  const _Notice({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(Rad.toast),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.info_outline_rounded, size: 18, color: t.warning),
            const SizedBox(width: 10),
            Flexible(
              child: Text(text, style: t.label.copyWith(color: t.text)),
            ),
          ],
        ),
      ),
    );
  }
}
