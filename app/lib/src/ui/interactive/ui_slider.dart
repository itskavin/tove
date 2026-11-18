import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../shell/drawer_swipe.dart';
import '../theme/motion.dart';

/// The hermes-ui slider (chat-rendering-v2 §3.5, measured): 48 dp touch
/// height, a 4 dp track (active [active], inactive [inactive]), a 20 dp thumb
/// filled with [thumbFill] and a 2 dp ring that grows to 24 dp while dragged.
/// Snaps to [step]; arrow keys and accessibility actions move one step.
class UiSlider extends StatefulWidget {
  const UiSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    required this.active,
    required this.inactive,
    required this.thumbFill,
    required this.thumbRing,
    this.semanticLabel,
    this.semanticValue,
  });

  final double value, min, max, step;
  final ValueChanged<double> onChanged;
  final Color active, inactive, thumbFill, thumbRing;
  final String? semanticLabel;

  /// The formatted value for screen readers.
  final String? semanticValue;

  @override
  State<UiSlider> createState() => _UiSliderState();
}

class _UiSliderState extends State<UiSlider> {
  bool _dragging = false;

  double _snap(double v) {
    final w = widget;
    final n = ((v - w.min) / w.step).round();
    return (w.min + n * w.step).clamp(w.min, w.max).toDouble();
  }

  void _setFromDx(double dx, double width) {
    const pad = 12.0;
    final t = ((dx - pad) / (width - 2 * pad)).clamp(0.0, 1.0);
    final v = _snap(widget.min + t * (widget.max - widget.min));
    if (v != widget.value) widget.onChanged(v);
  }

  void _nudge(int dir) {
    final v = _snap(widget.value + dir * widget.step);
    if (v != widget.value) widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final t = w.max > w.min ? (w.value - w.min) / (w.max - w.min) : 0.0;
    final dur = Motion.of(context, const Duration(milliseconds: 90));
    // The sidebar swipe never takes a drag that starts on a slider (§4.3).
    return DrawerSwipeExclusion(
      child: Semantics(
        slider: true,
        label: w.semanticLabel,
        value: w.semanticValue,
        increasedValue: 'more',
        decreasedValue: 'less',
        onIncrease: () => _nudge(1),
        onDecrease: () => _nudge(-1),
        child: FocusableActionDetector(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.arrowRight): _Step(1),
            SingleActivator(LogicalKeyboardKey.arrowUp): _Step(1),
            SingleActivator(LogicalKeyboardKey.arrowLeft): _Step(-1),
            SingleActivator(LogicalKeyboardKey.arrowDown): _Step(-1),
          },
          actions: {
            _Step: CallbackAction<_Step>(onInvoke: (i) => _nudge(i.dir)),
          },
          mouseCursor: SystemMouseCursors.click,
          child: LayoutBuilder(
            builder: (context, c) {
              final width = c.maxWidth;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => _setFromDx(d.localPosition.dx, width),
                onHorizontalDragStart: (d) {
                  setState(() => _dragging = true);
                  _setFromDx(d.localPosition.dx, width);
                },
                onHorizontalDragUpdate: (d) =>
                    _setFromDx(d.localPosition.dx, width),
                onHorizontalDragEnd: (_) => setState(() => _dragging = false),
                onHorizontalDragCancel: () => setState(() => _dragging = false),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: _dragging ? 24 : 20),
                  duration: dur,
                  builder: (context, thumb, _) => CustomPaint(
                    size: Size(width, 48),
                    painter: _SliderPainter(
                      t: t.toDouble(),
                      thumb: thumb,
                      active: w.active,
                      inactive: w.inactive,
                      fill: w.thumbFill,
                      ring: w.thumbRing,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Step extends Intent {
  const _Step(this.dir);
  final int dir;
}

class _SliderPainter extends CustomPainter {
  _SliderPainter({
    required this.t,
    required this.thumb,
    required this.active,
    required this.inactive,
    required this.fill,
    required this.ring,
  });

  final double t, thumb;
  final Color active, inactive, fill, ring;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 12.0;
    final cy = size.height / 2;
    final x = pad + t * (size.width - 2 * pad);
    final track = RRect.fromLTRBR(
      pad - 2,
      cy - 2,
      size.width - pad + 2,
      cy + 2,
      const Radius.circular(2),
    );
    canvas.drawRRect(track, Paint()..color = inactive);
    canvas.drawRRect(
      RRect.fromLTRBR(pad - 2, cy - 2, x, cy + 2, const Radius.circular(2)),
      Paint()..color = active,
    );
    final r = thumb / 2;
    canvas.drawCircle(Offset(x, cy), r, Paint()..color = fill);
    canvas.drawCircle(
      Offset(x, cy),
      r - 1,
      Paint()
        ..color = ring
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_SliderPainter old) =>
      old.t != t ||
      old.thumb != thumb ||
      old.active != active ||
      old.inactive != inactive ||
      old.fill != fill ||
      old.ring != ring;
}
