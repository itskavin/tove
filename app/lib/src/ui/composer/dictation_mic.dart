import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import '../common/glass.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import 'dictation.dart';

/// The mic while dictating (spec §5.3): a 40 dp `text` circle with a `bg`
/// mic, and a ring that follows the input level (scale 1 → 1.18 at full
/// level; attack 60 ms, release 180 ms). Tap to stop.
class DictationMicButton extends StatefulWidget {
  const DictationMicButton({
    super.key,
    required this.dictation,
    required this.onTap,
  });

  final ComposerDictation dictation;
  final VoidCallback onTap;

  @override
  State<DictationMicButton> createState() => _DictationMicButtonState();
}

class _DictationMicButtonState extends State<DictationMicButton>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _level = ValueNotifier<double>(0);
  Duration _last = Duration.zero;

  static const _attack = 60.0, _release = 180.0;

  bool _animate = true;

  @override
  void initState() {
    super.initState();
    widget.dictation.addListener(_onLevel);
  }

  @override
  void didUpdateWidget(DictationMicButton old) {
    super.didUpdateWidget(old);
    if (old.dictation != widget.dictation) {
      old.dictation.removeListener(_onLevel);
      widget.dictation.addListener(_onLevel);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _animate = !Motion.reduced(context);
    if (!_animate) {
      _ticker.stop();
      _level.value = 0;
    }
  }

  double get _target =>
      widget.dictation.phase == ComposerDictationPhase.listening
      ? widget.dictation.level.clamp(0.0, 1.0)
      : 0.0;

  /// Runs the ticker only while the ring is moving.
  void _onLevel() {
    if (!_animate || _ticker.isActive) return;
    if ((_target - _level.value).abs() < 0.002) return;
    _last = Duration.zero;
    _ticker.start();
  }

  void _tick(Duration now) {
    final dt = _last == Duration.zero
        ? 16.0
        : (now - _last).inMicroseconds / 1000.0;
    _last = now;
    final target = _target;
    final v = _level.value;
    final tau = target > v ? _attack : _release;
    var next = v + (target - v) * (1 - math.exp(-dt / tau));
    if ((target - next).abs() < 0.002) {
      next = target;
      _ticker.stop();
    }
    _level.value = next;
  }

  @override
  void dispose() {
    widget.dictation.removeListener(_onLevel);
    _ticker.dispose();
    _level.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final listening =
        widget.dictation.phase == ComposerDictationPhase.listening;
    return Semantics(
      button: true,
      label: 'Stop dictation',
      value: listening ? 'Listening' : 'Starting',
      liveRegion: true,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: Tooltip(
        message: 'Stop dictation',
        child: FocusRing(
          shape: const CircleBorder(),
          onActivate: widget.onTap,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: SizedBox.square(
              dimension: Sz.hit,
              child: Center(
                child: ValueListenableBuilder<double>(
                  valueListenable: _level,
                  builder: (context, level, child) => CustomPaint(
                    painter: _RingPainter(
                      color: t.text.withValues(alpha: listening ? 0.35 : 0.18),
                      scale: 1 + 0.18 * level,
                    ),
                    child: child,
                  ),
                  child: Container(
                    width: Sz.action,
                    height: Sz.action,
                    decoration: BoxDecoration(
                      color: t.text,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.mic_rounded, size: 22, color: t.bg),
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

class _RingPainter extends CustomPainter {
  _RingPainter({required this.color, required this.scale});
  final Color color;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2 * scale;
    canvas.drawCircle(
      size.center(Offset.zero),
      r,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.color != color || old.scale != scale;
}
