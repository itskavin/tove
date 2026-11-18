import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import '../common/glass.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'dictation.dart';

/// What the hold panel shows.
enum HoldPanelMode {
  /// Finger down: release sends, slide left cancels, slide up locks.
  holding,

  /// Hands-free: Cancel and Send buttons.
  locked,

  /// Released: the last words are being transcribed, then it sends.
  sending,
}

/// The press-and-hold dictation panel above the composer: the words heard so
/// far (fading in), a live waveform, the elapsed time and what to do next.
///
/// With reduced motion the waveform is a still level meter and nothing
/// slides or pulses; changes cross-fade.
class DictationHoldPanel extends StatefulWidget {
  const DictationHoldPanel({
    super.key,
    required this.dictation,
    required this.mode,
    this.cancelProgress = 0,
    this.lockProgress = 0,
    required this.onCancel,
    required this.onSend,
  });

  final ComposerDictation dictation;
  final HoldPanelMode mode;
  final double cancelProgress;
  final double lockProgress;
  final VoidCallback onCancel;
  final VoidCallback onSend;

  @override
  State<DictationHoldPanel> createState() => _DictationHoldPanelState();
}

class _DictationHoldPanelState extends State<DictationHoldPanel>
    with SingleTickerProviderStateMixin {
  // The panel appears when the hold begins, so its age is the recording
  // time. Frame time, not wall time: steady in tests and goldens.
  late final Ticker _clock = createTicker(_tick)..start();
  int _seconds = 0;

  void _tick(Duration elapsed) {
    final s = elapsed.inSeconds;
    if (s != _seconds) setState(() => _seconds = s);
  }

  @override
  void initState() {
    super.initState();
    widget.dictation.addListener(_changed);
  }

  @override
  void didUpdateWidget(DictationHoldPanel old) {
    super.didUpdateWidget(old);
    if (old.dictation != widget.dictation) {
      old.dictation.removeListener(_changed);
      widget.dictation.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    widget.dictation.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String get _elapsed {
    final s = _seconds.clamp(0, 5999);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final reduced = Motion.reduced(context);
    final d = widget.dictation;
    final words = d.partial.trim();
    final cancel = widget.mode == HoldPanelMode.holding
        ? widget.cancelProgress
        : 0.0;
    final status = switch (widget.mode) {
      HoldPanelMode.holding =>
        'Recording. Release to send, slide left to '
            'cancel, slide up for hands-free.',
      HoldPanelMode.locked => 'Recording hands-free.',
      HoldPanelMode.sending => 'Transcribing, then sending.',
    };
    final fade = Motion.of(context, const Duration(milliseconds: 220));

    final transcript = AnimatedSwitcher(
      duration: fade,
      switchInCurve: Motion.standard,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.bottomLeft,
        children: [...previous, ?current],
      ),
      child: words.isEmpty
          ? Text(
              widget.mode == HoldPanelMode.sending
                  ? 'Transcribing…'
                  : 'Listening…',
              key: const ValueKey('placeholder'),
              style: t.body.copyWith(color: t.textFaint),
            )
          : _Transcript(
              key: const ValueKey('words'),
              words: words,
              stable: d.stablePrefix.trim(),
              style: t.body,
              muted: t.textMuted,
              reduced: reduced,
            ),
    );

    final panel = Container(
      padding: const EdgeInsets.fromLTRB(Sp.l, Sp.m, Sp.l, Sp.m),
      decoration: ShapeDecoration(
        // Reddens toward a cancel; stays opaque.
        color: Color.alphaBlend(
          t.danger.withValues(alpha: 0.16 * cancel * cancel),
          t.surface,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Rad.card),
          side: BorderSide(color: t.hairline),
        ),
        shadows: const [
          BoxShadow(
            color: Color(0x29000000),
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 26, maxHeight: 104),
            child: Align(
              alignment: Alignment.bottomLeft,
              heightFactor: 1,
              child: transcript,
            ),
          ),
          const SizedBox(height: Sp.s),
          SizedBox(
            height: 44,
            child: LevelWaveform(
              dictation: d,
              color: Color.lerp(t.accent, t.danger, cancel)!,
              active: widget.mode != HoldPanelMode.sending,
            ),
          ),
          const SizedBox(height: Sp.s),
          _footer(context, t, reduced, cancel),
        ],
      ),
    );

    return Semantics(
      container: true,
      liveRegion: true,
      label: status,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          panel,
          if (widget.mode == HoldPanelMode.holding)
            Positioned(
              right: Sp.s,
              top: -60,
              child: ExcludeSemantics(
                child: _LockHint(
                  progress: widget.lockProgress,
                  reduced: reduced,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _footer(
    BuildContext context,
    HermesTokens t,
    bool reduced,
    double cancel,
  ) {
    final clock = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RecDot(
          color: t.danger,
          pulse: !reduced && widget.mode != HoldPanelMode.sending,
        ),
        const SizedBox(width: Sp.s),
        Text(
          _elapsed,
          style: t.control.copyWith(
            color: t.text,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
    final Widget trailing = switch (widget.mode) {
      HoldPanelMode.holding => Expanded(
        child: Opacity(
          opacity: 1 - 0.6 * cancel,
          child: Transform.translate(
            offset: Offset(reduced ? 0 : -16 * cancel, 0),
            child: Text(
              cancel >= 0.5
                  ? 'Let go to keep · keep sliding to cancel'
                  : 'Release to send · ‹ Slide left to cancel',
              key: const ValueKey('hold-hint'),
              textAlign: TextAlign.end,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.label.copyWith(
                color: Color.lerp(t.textMuted, t.danger, cancel),
              ),
            ),
          ),
        ),
      ),
      HoldPanelMode.locked => Expanded(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Flexible(
              child: Text(
                'Hands-free',
                overflow: TextOverflow.ellipsis,
                style: t.label,
              ),
            ),
            const SizedBox(width: Sp.s),
            _RoundAction(
              label: 'Cancel recording',
              icon: Icons.close_rounded,
              fill: t.surfaceHigh,
              color: t.text,
              onTap: widget.onCancel,
            ),
            const SizedBox(width: Sp.s),
            _RoundAction(
              label: 'Send recording',
              icon: Icons.arrow_upward_rounded,
              fill: t.text,
              color: t.bg,
              onTap: widget.onSend,
            ),
          ],
        ),
      ),
      HoldPanelMode.sending => Expanded(
        child: Text(
          'Sending when the words are in',
          textAlign: TextAlign.end,
          overflow: TextOverflow.ellipsis,
          style: t.label,
        ),
      ),
    };
    return SizedBox(
      height: Sz.hit,
      child: Row(
        children: [
          clock,
          const SizedBox(width: Sp.m),
          trailing,
        ],
      ),
    );
  }
}

/// The transcript, newest words in view; the part the engine has not made
/// final is muted. New text fades in.
class _Transcript extends StatelessWidget {
  const _Transcript({
    super.key,
    required this.words,
    required this.stable,
    required this.style,
    required this.muted,
    required this.reduced,
  });

  final String words;
  final String stable;
  final TextStyle style;
  final Color muted;
  final bool reduced;

  @override
  Widget build(BuildContext context) {
    final split = stable.isNotEmpty && words.startsWith(stable)
        ? stable.length
        : 0;
    final text = Text.rich(
      TextSpan(
        children: [
          TextSpan(text: words.substring(0, split)),
          TextSpan(
            text: words.substring(split),
            style: TextStyle(color: split == 0 ? null : muted),
          ),
        ],
      ),
      style: style,
    );
    // Long dictation: the start scrolls away, the newest words stay.
    final scroll = SingleChildScrollView(
      reverse: true,
      physics: const NeverScrollableScrollPhysics(),
      child: text,
    );
    if (reduced) return scroll;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Motion.standard,
      builder: (context, v, child) => Opacity(
        opacity: v,
        alwaysIncludeSemantics: true,
        child: Transform.translate(
          offset: Offset(0, 6 * (1 - v)),
          child: child,
        ),
      ),
      child: scroll,
    );
  }
}

/// A live waveform from the input level: bars scroll right to left, each a
/// level sample. Reduced motion: still bars at the current level.
class LevelWaveform extends StatefulWidget {
  const LevelWaveform({
    super.key,
    required this.dictation,
    required this.color,
    this.active = true,
    this.bars = 32,
  });

  final ComposerDictation dictation;
  final Color color;
  final bool active;
  final int bars;

  @override
  State<LevelWaveform> createState() => _LevelWaveformState();
}

class _LevelWaveformState extends State<LevelWaveform>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late List<double> _samples = List.filled(widget.bars, 0);
  final _repaint = ValueNotifier<int>(0);
  Duration _lastSample = Duration.zero;
  double _smoothed = 0;
  bool _reduced = false;

  static const _every = Duration(milliseconds: 70);

  @override
  void initState() {
    super.initState();
    widget.dictation.addListener(_onLevel);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = Motion.reduced(context);
    _sync();
  }

  @override
  void didUpdateWidget(LevelWaveform old) {
    super.didUpdateWidget(old);
    if (old.dictation != widget.dictation) {
      old.dictation.removeListener(_onLevel);
      widget.dictation.addListener(_onLevel);
    }
    if (old.bars != widget.bars) _samples = List.filled(widget.bars, 0);
    _sync();
  }

  void _sync() {
    final run = widget.active && !_reduced;
    if (run && !_ticker.isActive) {
      _lastSample = Duration.zero;
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  double get _level =>
      widget.active ? widget.dictation.level.clamp(0.0, 1.0) : 0.0;

  void _onLevel() {
    if (_reduced) _repaint.value++;
  }

  void _tick(Duration now) {
    if (now - _lastSample < _every && _lastSample != Duration.zero) return;
    _lastSample = now;
    // Quick rise, slower fall, like the mic ring.
    final target = _level;
    _smoothed += (target - _smoothed) * (target > _smoothed ? 0.7 : 0.35);
    _samples = [..._samples.skip(1), _smoothed];
    _repaint.value++;
  }

  @override
  void dispose() {
    widget.dictation.removeListener(_onLevel);
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _WavePainter(
          repaint: _repaint,
          samples: () => _reduced ? List.filled(widget.bars, _level) : _samples,
          color: widget.color,
        ),
      ),
    ),
  );
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required Listenable repaint,
    required this.samples,
    required this.color,
  }) : super(repaint: repaint);

  final List<double> Function() samples;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = samples();
    if (s.isEmpty || size.isEmpty) return;
    final slot = size.width / s.length;
    final w = math.min(4.0, slot * 0.55);
    final mid = size.height / 2;
    final paint = Paint()..color = color;
    for (var i = 0; i < s.length; i++) {
      // Older samples fade toward the left edge.
      final age = i / (s.length - 1);
      final h = math.max(w, size.height * (0.08 + 0.92 * s[i]));
      paint.color = color.withValues(alpha: 0.35 + 0.65 * age);
      final x = i * slot + (slot - w) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, mid - h / 2, w, h),
          Radius.circular(w / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.color != color;
}

/// The red recording dot; it breathes unless motion is reduced.
class _RecDot extends StatefulWidget {
  const _RecDot({required this.color, required this.pulse});
  final Color color;
  final bool pulse;

  @override
  State<_RecDot> createState() => _RecDotState();
}

class _RecDotState extends State<_RecDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulse) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_RecDot old) {
    super.didUpdateWidget(old);
    if (widget.pulse && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.pulse && _c.isAnimating) {
      _c
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween<double>(begin: 0.35, end: 1).animate(_c),
    child: Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    ),
  );
}

/// Above the held mic: a lock that fills as the finger slides up.
class _LockHint extends StatelessWidget {
  const _LockHint({required this.progress, required this.reduced});
  final double progress;
  final bool reduced;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final p = progress.clamp(0.0, 1.0);
    return Transform.translate(
      offset: Offset(0, reduced ? 0 : -10 * p),
      child: Container(
        width: 40,
        height: 56,
        decoration: ShapeDecoration(
          color: Color.lerp(t.surface, t.accentSoft, p),
          shape: StadiumBorder(side: BorderSide(color: t.hairline)),
          shadows: const [
            BoxShadow(
              color: Color(0x1F000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              p >= 1 ? Icons.lock_rounded : Icons.lock_open_rounded,
              size: 18,
              color: Color.lerp(t.textMuted, t.onAccentSoft, p),
            ),
            Icon(Icons.keyboard_arrow_up_rounded, size: 18, color: t.textFaint),
          ],
        ),
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.label,
    required this.icon,
    required this.fill,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color fill;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    onTap: onTap,
    child: Tooltip(
      message: label,
      child: FocusRing(
        shape: const CircleBorder(),
        onActivate: onTap,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox.square(
            dimension: Sz.hit,
            child: Center(
              child: Container(
                width: Sz.action,
                height: Sz.action,
                decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
                child: Icon(icon, size: 22, color: color),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The mic while held: it grows into an accent bubble that follows the
/// finger a little (left toward cancel, up toward the lock) and pulses with
/// the voice. Reduced motion: no growth, travel or pulse.
class HeldMic extends StatelessWidget {
  const HeldMic({
    super.key,
    required this.dictation,
    required this.offset,
    required this.cancelProgress,
    required this.mode,
  });

  final ComposerDictation dictation;
  final Offset offset;
  final double cancelProgress;
  final HoldPanelMode mode;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final reduced = Motion.reduced(context);
    final color = Color.lerp(t.accent, t.danger, cancelProgress)!;
    final icon = switch (mode) {
      HoldPanelMode.locked => Icons.lock_rounded,
      HoldPanelMode.sending => Icons.arrow_upward_rounded,
      HoldPanelMode.holding =>
        cancelProgress >= 1 ? Icons.delete_outline_rounded : Icons.mic_rounded,
    };
    final bubble = ListenableBuilder(
      listenable: dictation,
      builder: (context, child) {
        final level = reduced || mode == HoldPanelMode.sending
            ? 0.0
            : dictation.level.clamp(0.0, 1.0);
        return CustomPaint(
          painter: _PulsePainter(
            color: color.withValues(alpha: 0.28),
            scale: 1.15 + 0.35 * level,
          ),
          child: child,
        );
      },
      child: Container(
        width: Sz.action,
        height: Sz.action,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(icon, size: 22, color: t.onAccent),
      ),
    );
    if (reduced) return ExcludeSemantics(child: bubble);
    return ExcludeSemantics(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 1, end: mode == HoldPanelMode.holding ? 1.3 : 1.1),
        duration: const Duration(milliseconds: 260),
        curve: Motion.pop,
        builder: (context, scale, child) => Transform.translate(
          offset: offset * 0.6,
          child: Transform.scale(scale: scale, child: child),
        ),
        child: bubble,
      ),
    );
  }
}

class _PulsePainter extends CustomPainter {
  _PulsePainter({required this.color, required this.scale});
  final Color color;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(
      size.center(Offset.zero),
      size.shortestSide / 2 * scale,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_PulsePainter old) =>
      old.color != color || old.scale != scale;
}
