import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';
import 'tove_mark_path.dart';

/// Tove's mark (the three-lobed triangle of the app icon) as a flat
/// silhouette in the theme's text colour, [size] dp wide. Decorative: the
/// name beside it, or a [Semantics] label around it, says what it is.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 26, this.color});

  final double size;

  /// Defaults to the theme's text colour.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _MarkPainter(color ?? t.text)),
      ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / toveMarkBox;
    canvas
      ..save()
      ..translate(
        (size.width - toveMarkBox * s) / 2,
        size.height / 2 - toveMarkCentreY * s,
      )
      ..scale(s)
      ..drawPath(
        toveMarkPath,
        Paint()
          ..color = color
          ..isAntiAlias = true,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.color != color;
}
