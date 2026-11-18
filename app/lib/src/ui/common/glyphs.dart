import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Custom glyphs from spec §3.7, drawn with 1.75 dp rounded strokes.

/// Menu: two bars, the top one longer (20 × 14).
class MenuGlyph extends StatelessWidget {
  const MenuGlyph({super.key, this.color, this.size = 24});
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _MenuPainter(color ?? IconTheme.of(context).color!),
    ),
  );
}

class _MenuPainter extends CustomPainter {
  _MenuPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.9 * s
      ..strokeCap = StrokeCap.round;
    // 20 × 14 box centred: bars at y = 9 and 15.
    canvas.drawLine(Offset(4 * s, 9 * s), Offset(20 * s, 9 * s), p);
    canvas.drawLine(Offset(4 * s, 15 * s), Offset(14 * s, 15 * s), p);
  }

  @override
  bool shouldRepaint(_MenuPainter old) => old.color != color;
}

/// The live-voice glyph: four rounded bars.
class WaveGlyph extends StatelessWidget {
  const WaveGlyph({super.key, this.color, this.size = 24});
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _WavePainter(color ?? IconTheme.of(context).color!),
    ),
  );
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.color);
  final Color color;
  static const _heights = [0.34, 0.72, 0.5, 0.26];

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final p = Paint()
      ..color = color
      ..strokeWidth = math.max(1.5, w * 0.095)
      ..strokeCap = StrokeCap.round;
    final gap = w * 0.19;
    final x0 = w / 2 - gap * 1.5;
    for (var i = 0; i < 4; i++) {
      final h = size.height * _heights[i];
      final x = x0 + gap * i;
      canvas.drawLine(
        Offset(x, size.height / 2 - h / 2),
        Offset(x, size.height / 2 + h / 2),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.color != color;
}

/// Stop generating: a rounded square.
class StopGlyph extends StatelessWidget {
  const StopGlyph({super.key, this.color, this.size = 24});
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = color ?? IconTheme.of(context).color!;
    final side = size * 0.46;
    return SizedBox.square(
      dimension: size,
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: c,
            borderRadius: BorderRadius.circular(side * 0.22),
          ),
          child: SizedBox.square(dimension: side),
        ),
      ),
    );
  }
}
