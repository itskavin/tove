import 'dart:async';

import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../settings/settings.dart';
import '../common/glass.dart';
import '../feedback.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

/// The reply-effort slider (spec §4.7, §6.7): a glass stadium track with
/// three stops, an accent fill up to the thumb and a white thumb that wears
/// an accent ring at the first stop. It snaps to stops with a spring
/// (500, ζ 0.8), clicks at every stop crossed and asks to close 1.8 s after
/// the last touch.
class EffortSlider extends StatefulWidget {
  const EffortSlider({
    super.key,
    required this.value,
    required this.onChanged,
    required this.onDismiss,
    this.width = 360,
    this.idleTimeout = const Duration(milliseconds: 1800),
  });

  final ReplyEffort value;
  final ValueChanged<ReplyEffort> onChanged;
  final VoidCallback onDismiss;
  final double width;
  final Duration idleTimeout;

  static String labelFor(ReplyEffort e) => '${e.label} effort';

  @override
  State<EffortSlider> createState() => _EffortSliderState();
}

class _EffortSliderState extends State<EffortSlider>
    with SingleTickerProviderStateMixin {
  static const _end = 26.0; // stop inset from each end
  late final AnimationController _pos = AnimationController.unbounded(
    vsync: this,
    value: widget.value.index.toDouble(),
  );
  late ReplyEffort _value = widget.value;
  Timer? _idle;
  int _lastStop = 0;

  @override
  void initState() {
    super.initState();
    _lastStop = widget.value.index;
    _pos.addListener(_crossings);
    _restartIdle();
  }

  @override
  void didUpdateWidget(EffortSlider old) {
    super.didUpdateWidget(old);
    if (widget.value != _value) _snapTo(widget.value.index, notify: false);
  }

  @override
  void dispose() {
    _idle?.cancel();
    _pos.dispose();
    super.dispose();
  }

  void _restartIdle() {
    _idle?.cancel();
    _idle = Timer(widget.idleTimeout, () {
      if (mounted) widget.onDismiss();
    });
  }

  void _crossings() {
    final stop = _pos.value.round().clamp(0, 2);
    if (stop != _lastStop) {
      _lastStop = stop;
      FeedbackScope.haptic(context, Haptic.selection);
    }
  }

  double get _span => widget.width - 2 * _end;
  double _toStops(double x) => ((x - _end) / _span * 2).clamp(0.0, 2.0);

  void _snapTo(int stop, {bool notify = true, double velocity = 0}) {
    final target = stop.clamp(0, 2).toDouble();
    if (Motion.reduced(context)) {
      _pos.value = target;
    } else {
      _pos.animateWith(
        SpringSimulation(Motion.thumb, _pos.value, target, velocity),
      );
    }
    final v = ReplyEffort.values[stop.clamp(0, 2)];
    if (v != _value) {
      setState(() => _value = v);
      if (notify) widget.onChanged(v);
    }
    _restartIdle();
  }

  void _step(int delta) => _snapTo(_value.index + delta);

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final label = EffortSlider.labelFor(_value);
    return Semantics(
      slider: true,
      label: 'Reply effort',
      value: _value.label,
      increasedValue: _value.index < 2
          ? ReplyEffort.values[_value.index + 1].label
          : null,
      decreasedValue: _value.index > 0
          ? ReplyEffort.values[_value.index - 1].label
          : null,
      onIncrease: _value.index < 2 ? () => _step(1) : null,
      onDecrease: _value.index > 0 ? () => _step(-1) : null,
      child: Focus(
        autofocus: true,
        onKeyEvent: (node, e) {
          if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
            _step(1);
          } else if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _step(-1);
          } else if (e.logicalKey == LogicalKeyboardKey.escape ||
              e.logicalKey == LogicalKeyboardKey.enter) {
            widget.onDismiss();
          } else {
            return KeyEventResult.ignored;
          }
          return KeyEventResult.handled;
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: AnimatedSwitcher(
                duration: Motion.of(context, const Duration(milliseconds: 150)),
                child: Text(label, key: ValueKey(label), style: t.title),
              ),
            ),
            const SizedBox(height: 16),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _snapTo(_toStops(d.localPosition.dx).round()),
              onHorizontalDragStart: (_) {
                _pos.stop();
                _restartIdle();
              },
              onHorizontalDragUpdate: (d) {
                _pos.value = (_pos.value + d.delta.dx / _span * 2).clamp(
                  0.0,
                  2.0,
                );
              },
              onHorizontalDragEnd: (d) => _snapTo(
                _pos.value.round(),
                velocity: d.velocity.pixelsPerSecond.dx / _span * 2,
              ),
              child: SizedBox(
                width: widget.width,
                height: Sz.effortTrackH,
                child: AnimatedBuilder(
                  animation: _pos,
                  builder: (context, _) => _Track(
                    position: _pos.value.clamp(0.0, 2.0),
                    width: widget.width,
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

class _Track extends StatelessWidget {
  const _Track({required this.position, required this.width});
  final double position;
  final double width;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    const end = _EffortSliderState._end;
    final span = width - 2 * end;
    final x = end + span * position / 2;
    // Fill and ring fade over the first ~third of a stop (≈ 120 ms of travel).
    final fill = (position / 0.3).clamp(0.0, 1.0);
    final ring = 1 - fill;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Positioned.fill(child: Glass(child: SizedBox.expand())),
        if (fill > 0)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: (x + 20).clamp(0.0, width),
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: t.accent.withValues(alpha: fill),
                shape: const StadiumBorder(),
              ),
            ),
          ),
        for (var i = 0; i < 3; i++)
          Positioned(
            left: end + span * i / 2 - Sz.effortDot / 2,
            top: (Sz.effortTrackH - Sz.effortDot) / 2,
            child: Container(
              width: Sz.effortDot,
              height: Sz.effortDot,
              decoration: BoxDecoration(
                color: t.textMuted,
                shape: BoxShape.circle,
              ),
            ),
          ),
        Positioned(
          left: x - Sz.effortThumb / 2,
          top: (Sz.effortTrackH - Sz.effortThumb) / 2,
          child: Container(
            width: Sz.effortThumb,
            height: Sz.effortThumb,
            decoration: BoxDecoration(
              color: t.closeFill,
              shape: BoxShape.circle,
              border: ring > 0
                  ? Border.all(
                      color: t.accent.withValues(alpha: ring),
                      width: 2,
                    )
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}
