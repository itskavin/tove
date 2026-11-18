import 'package:material_ui/material_ui.dart';

/// A scroll controller that keeps the view pinned to the end while the user
/// is within [threshold] of it (spec §4.2, §6.3: 160 dp), in the same frame
/// the content grows, so streaming text never lags a frame behind. When the
/// user has scrolled further up, growth does not move what they are reading.
class FollowScrollController extends ScrollController {
  FollowScrollController({this.threshold = 160});

  final double threshold;

  /// Turn following off (for example while the user drags).
  bool enabled = true;

  bool get atEnd {
    if (!hasClients) return true;
    final p = position;
    if (!p.hasContentDimensions) return true;
    return p.maxScrollExtent - p.pixels <= threshold;
  }

  /// Animates to the end (300 ms, standard) or jumps there.
  Future<void> toEnd({Duration? duration, Curve curve = Curves.linear}) async {
    if (!hasClients) return;
    final p = position;
    if (duration == null || duration == Duration.zero) {
      p.jumpTo(p.maxScrollExtent);
    } else {
      await p.animateTo(p.maxScrollExtent, duration: duration, curve: curve);
    }
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _FollowPosition(
    owner: this,
    physics: physics,
    context: context,
    oldPosition: oldPosition,
  );
}

class _FollowPosition extends ScrollPositionWithSingleContext {
  _FollowPosition({
    required this.owner,
    required super.physics,
    required super.context,
    super.oldPosition,
  });

  final FollowScrollController owner;
  bool _wasAtEnd = true;

  bool get _userActive => activity is DragScrollActivity;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final had = hasContentDimensions && hasPixels;
    final follow =
        owner.enabled &&
        had &&
        _wasAtEnd &&
        !_userActive &&
        maxScrollExtent != this.maxScrollExtent &&
        pixels != maxScrollExtent;
    final ok = super.applyContentDimensions(minScrollExtent, maxScrollExtent);
    if (follow) {
      correctPixels(maxScrollExtent);
      _wasAtEnd = true;
      return false;
    }
    if (hasPixels && hasContentDimensions) {
      _wasAtEnd = this.maxScrollExtent - pixels <= owner.threshold;
    }
    return ok;
  }

  @override
  void didUpdateScrollPositionBy(double delta) {
    super.didUpdateScrollPositionBy(delta);
    if (hasContentDimensions) {
      _wasAtEnd = maxScrollExtent - pixels <= owner.threshold;
    }
  }
}
