import 'package:material_ui/material_ui.dart';

import '../common/size_reporter.dart';
import '../theme/tokens.dart';

/// One point of an edge feather's opacity profile: [alpha] of the theme's
/// background at [at] dp from the top of the feather.
typedef FeatherStop = ({double at, double alpha});

/// The fades that let the thread scroll under the floating header and
/// composer (the reference shows text passing behind both and dimming toward
/// the outer edges, never an opaque band).
///
/// A feather is a vertical gradient of the theme's `bg` whose opacity follows
/// [stops]; between two stops it eases (smoothstep), so there is no visible
/// edge where a fade starts or a slope changes. It ignores pointers: what is
/// under it still scrolls, and the controls drawn above it stay tappable.
///
/// One style everywhere (round 6): the chat screen, the chat list and Tasks
/// use these stops and levels; only [color] follows the surface underneath.
class EdgeFeather extends StatelessWidget {
  const EdgeFeather({super.key, required this.stops, this.color});

  /// Opacity profile, top to bottom; `at` values increase.
  final List<FeatherStop> stops;

  /// The surface faded to; the theme's `bg` when null.
  final Color? color;

  /// Space between a panel header and its first row that the top feather
  /// eases out over.
  static const underHeader = 16.0;

  /// Samples taken between two stops to approximate the ease.
  static const _samples = 6;

  /// Strongest dimming at the very top (behind the status bar). Text there is
  /// still faintly visible, as in the reference, but the status bar icons stay
  /// legible.
  static const topEdge = 0.9;

  /// Behind the status bar's lower edge.
  static const underStatusBar = 0.66;

  /// Fade above the composer's top edge, and its opacity at that edge.
  static const aboveComposer = 56.0;
  static const atComposer = 0.5;

  /// At the bottom edge of the screen (gesture bar or keyboard top).
  static const bottomEdge = 0.92;

  /// The header feather, [statusBar] + [bar] + [underBar] dp tall: dimmest
  /// at the top edge, easing out to nothing where the first message rests.
  static List<FeatherStop> topStops({
    required double statusBar,
    required double bar,
    required double underBar,
  }) => [
    (at: 0, alpha: topEdge),
    if (statusBar > 0) (at: statusBar, alpha: underStatusBar),
    (at: statusBar + bar + underBar, alpha: 0),
  ];

  /// The composer feather for a pane [height] dp tall whose composer (with
  /// everything below it, keyboard included) takes [composerExtent] dp: clear
  /// [aboveComposer] dp above the composer, [atComposer] at its top edge and
  /// [bottomEdge] at the bottom of the pane. Its `at` values are offsets
  /// from the feather's top, which is [aboveComposer] dp above the composer.
  static List<FeatherStop> bottomStops({required double composerExtent}) => [
    (at: 0, alpha: 0),
    (at: aboveComposer, alpha: atComposer),
    (at: aboveComposer + composerExtent, alpha: bottomEdge),
  ];

  /// The feather's height: the last stop's offset.
  double get extent => stops.last.at;

  /// The opacity at [y] dp from the top, eased between stops.
  static double alphaAt(List<FeatherStop> stops, double y) {
    if (y <= stops.first.at) return stops.first.alpha;
    for (var i = 1; i < stops.length; i++) {
      final a = stops[i - 1], b = stops[i];
      if (y <= b.at) {
        final span = b.at - a.at;
        final t = span <= 0 ? 1.0 : (y - a.at) / span;
        final s = t * t * (3 - 2 * t);
        return a.alpha + (b.alpha - a.alpha) * s;
      }
    }
    return stops.last.alpha;
  }

  /// The gradient drawn for [stops] over [color].
  static LinearGradient gradient(List<FeatherStop> stops, Color color) {
    final h = stops.last.at;
    final offsets = <double>[];
    for (var i = 0; i < stops.length; i++) {
      if (i == 0) {
        offsets.add(stops[0].at);
        continue;
      }
      final a = stops[i - 1].at, b = stops[i].at;
      for (var k = 1; k <= _samples; k++) {
        offsets.add(a + (b - a) * k / _samples);
      }
    }
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        for (final y in offsets) color.withValues(alpha: alphaAt(stops, y)),
      ],
      stops: [for (final y in offsets) h <= 0 ? 0.0 : (y / h).clamp(0.0, 1.0)],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return IgnorePointer(
      child: SizedBox(
        height: extent,
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(gradient: gradient(stops, color ?? t.bg)),
        ),
      ),
    );
  }
}

/// A side panel's header, pinned at the top over the same feather as the chat
/// screen's header, with [body] scrolling underneath. [body] gets the inset
/// its first row should start at (status bar plus the measured header).
class FeatheredHeader extends StatefulWidget {
  const FeatheredHeader({
    super.key,
    required this.header,
    required this.body,
    this.color,
    this.estimate = 64,
  });

  final Widget header;
  final Widget Function(double topInset) body;

  /// The surface faded to (see [EdgeFeather.color]).
  final Color? color;

  /// The header's height before its first layout.
  final double estimate;

  @override
  State<FeatheredHeader> createState() => _FeatheredHeaderState();
}

class _FeatheredHeaderState extends State<FeatheredHeader> {
  late double _height = widget.estimate;

  void _onSize(Size s) {
    if (mounted && s.height != _height) setState(() => _height = s.height);
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Stack(
      children: [
        Positioned.fill(child: widget.body(top + _height)),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: EdgeFeather(
            color: widget.color,
            stops: EdgeFeather.topStops(
              statusBar: top,
              bar: _height,
              underBar: EdgeFeather.underHeader,
            ),
          ),
        ),
        Positioned(
          top: top,
          left: 0,
          right: 0,
          child: SizeReporter(onSize: _onSize, child: widget.header),
        ),
      ],
    );
  }
}
