import 'package:material_ui/material_ui.dart';

import '../common/glass.dart';
import '../theme/motion.dart';

/// One button inside a [HeaderPill]. [onPressed] gets the segment's context,
/// so a menu can open under it.
class HeaderPillAction {
  const HeaderPillAction({
    this.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final Key? key;
  final String label;
  final String? tooltip;
  final Widget icon;
  final void Function(BuildContext anchor) onPressed;
}

/// The header's joined glass capsule (New chat and More on phones): one
/// [height] dp stadium holding [segment] dp wide buttons, icons centred, so
/// two buttons make a 96 × 44 pill whose icons sit 48 dp apart. One action
/// makes a circle, the size of the menu button on the other side. Each
/// button has its own semantics node, tooltip, focus ring and a 48 dp tall
/// hit target; the width eases when an action comes or goes.
class HeaderPill extends StatelessWidget {
  const HeaderPill({
    super.key,
    required this.actions,
    this.height = 44,
    this.segment = 48,
  });

  final List<HeaderPillAction> actions;
  final double height;
  final double segment;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) return const SizedBox.shrink();
    final single = actions.length == 1;
    final w = single ? height : segment * actions.length;
    return SizedBox(
      height: height < 48 ? 48 : height,
      child: Center(
        child: AnimatedContainer(
          duration: Motion.of(context, const Duration(milliseconds: 180)),
          curve: Motion.standard,
          width: w,
          height: height,
          child: Glass(
            shape: const StadiumBorder(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final a in actions)
                  Flexible(
                    child: _Segment(
                      key: a.key,
                      action: a,
                      width: single ? height : segment,
                      height: height,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    super.key,
    required this.action,
    required this.width,
    required this.height,
  });

  final HeaderPillAction action;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    void tap() => action.onPressed(context);
    Widget button = Semantics(
      container: true,
      button: true,
      label: action.label,
      excludeSemantics: true,
      onTap: tap,
      child: FocusRing(
        shape: const CircleBorder(),
        onActivate: tap,
        child: Material(
          type: MaterialType.transparency,
          child: InkResponse(
            onTap: tap,
            radius: height / 2,
            containedInkWell: false,
            highlightShape: BoxShape.circle,
            child: SizedBox(
              width: width,
              height: height,
              child: Center(child: PressScale(child: action.icon)),
            ),
          ),
        ),
      ),
    );
    final tip = action.tooltip;
    if (tip != null) {
      button = Tooltip(message: tip, excludeFromSemantics: true, child: button);
    }
    return button;
  }
}

/// The compose glyph (New chat): a rounded square open at its top right,
/// with a pencil leaving through the gap. Strokes scale with [size].
class ComposeGlyph extends StatelessWidget {
  const ComposeGlyph({super.key, this.color, this.size = 22});
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _ComposePainter(
        color ?? IconTheme.of(context).color ?? const Color(0xFF000000),
      ),
    ),
  );
}

class _ComposePainter extends CustomPainter {
  _ComposePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.scale(s);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // The square, 4..20 with 3.5 corners, open from the top edge's middle
    // round to the right edge's middle.
    final box = Path()
      ..moveTo(12, 4)
      ..lineTo(7.5, 4)
      ..arcToPoint(
        const Offset(4, 7.5),
        radius: const Radius.circular(3.5),
        clockwise: false,
      )
      ..lineTo(4, 16.5)
      ..arcToPoint(
        const Offset(7.5, 20),
        radius: const Radius.circular(3.5),
        clockwise: false,
      )
      ..lineTo(16.5, 20)
      ..arcToPoint(
        const Offset(20, 16.5),
        radius: const Radius.circular(3.5),
        clockwise: false,
      )
      ..lineTo(20, 12);
    canvas.drawPath(box, paint);
    // The pencil: a slim body from the tip at (9.5, 14.5) up to the right,
    // with a rounded cap.
    final pencil = Path()
      ..moveTo(9.5, 14.5)
      ..lineTo(10.2, 11.6)
      ..lineTo(17.7, 4.1)
      ..arcToPoint(const Offset(19.9, 6.3), radius: const Radius.circular(1.6))
      ..lineTo(12.4, 13.8)
      ..close();
    canvas.drawPath(pencil, paint);
  }

  @override
  bool shouldRepaint(_ComposePainter old) => old.color != color;
}
