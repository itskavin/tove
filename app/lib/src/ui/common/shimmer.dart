import 'package:material_ui/material_ui.dart';

import '../theme/motion.dart';
import '../theme/tokens.dart';

/// The status shimmer (spec §5.4): a band 40 % of the label wide, `text`
/// over `textMuted`, sweeping left to right in 1.6 s, then a 300 ms pause.
/// Static under reduced motion.
class ShimmerText extends StatefulWidget {
  const ShimmerText(this.text, {super.key, this.style, this.enabled = true});

  final String text;
  final TextStyle? style;
  final bool enabled;

  @override
  State<ShimmerText> createState() => _ShimmerTextState();
}

class _ShimmerTextState extends State<ShimmerText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ShimmerText old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final run =
        widget.enabled &&
        !Motion.reduced(context) &&
        TickerMode.valuesOf(context).enabled;
    if (run && !_c.isAnimating) {
      _c.repeat();
    } else if (!run && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final style = (widget.style ?? t.label).copyWith(color: t.textMuted);
    final text = Text(widget.text, style: style);
    if (!widget.enabled ||
        Motion.reduced(context) ||
        !TickerMode.valuesOf(context).enabled) {
      return text;
    }
    return AnimatedBuilder(
      animation: _c,
      child: text,
      builder: (context, child) {
        // 1.6 s sweep, then a 0.3 s pause.
        final p = (_c.value * 1900 / 1600).clamp(0.0, 1.0);
        final x = -0.4 + 1.8 * p;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (r) => LinearGradient(
            colors: [t.textMuted, t.text, t.textMuted],
            stops: [
              (x - 0.2).clamp(0.0, 1.0),
              x.clamp(0.0, 1.0),
              (x + 0.2).clamp(0.0, 1.0),
            ],
          ).createShader(r),
          child: child,
        );
      },
    );
  }
}
