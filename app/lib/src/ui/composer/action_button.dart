import 'package:material_ui/material_ui.dart';

import '../common/glass.dart';
import '../common/glyphs.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

/// What the composer's round action button does (spec §5.5).
enum ComposerAction {
  /// Field empty, idle: start live voice.
  live,

  /// Field has text: send.
  send,

  /// A reply is streaming: stop it.
  stop,
}

ComposerAction composerActionFor({
  required bool hasText,
  required bool streaming,
}) => streaming
    ? ComposerAction.stop
    : hasText
    ? ComposerAction.send
    : ComposerAction.live;

/// A 40 dp `closeFill` circle whose glyph morphs between waveform, arrow and
/// stop: cross-fade plus scale 0.6 ↔ 1 over 160 ms, standard (§6.9).
class ComposerActionButton extends StatefulWidget {
  const ComposerActionButton({
    super.key,
    required this.action,
    required this.onPressed,
    this.enabled = true,
  });

  final ComposerAction action;
  final VoidCallback onPressed;
  final bool enabled;

  static String labelFor(ComposerAction a) => switch (a) {
    ComposerAction.live => 'Start live voice',
    ComposerAction.send => 'Send message',
    ComposerAction.stop => 'Stop reply',
  };

  @override
  State<ComposerActionButton> createState() => _ComposerActionButtonState();
}

class _ComposerActionButtonState extends State<ComposerActionButton>
    with SingleTickerProviderStateMixin {
  // The live tap pulse: 1 → 0.9 → 1 over 120 ms (§6.4).
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
  );

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _tap() {
    if (widget.action == ComposerAction.live && !Motion.reduced(context)) {
      _pulse.forward(from: 0);
    }
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final glyph = switch (widget.action) {
      ComposerAction.live => WaveGlyph(color: t.bg, size: 22),
      ComposerAction.send => Icon(
        Icons.arrow_upward_rounded,
        color: t.bg,
        size: 22,
      ),
      ComposerAction.stop => StopGlyph(color: t.bg, size: 24),
    };
    return SolidRoundButton(
      label: ComposerActionButton.labelFor(widget.action),
      onPressed: widget.enabled ? _tap : null,
      color: t.closeFill,
      size: Sz.action,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) => Transform.scale(
          scale: 1 - 0.1 * (1 - (2 * _pulse.value - 1).abs()),
          child: child,
        ),
        child: AnimatedSwitcher(
          duration: Motion.of(context, const Duration(milliseconds: 160)),
          switchInCurve: Motion.standard,
          switchOutCurve: Motion.standard,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: ScaleTransition(
              scale: Tween(begin: 0.6, end: 1.0).animate(a),
              child: child,
            ),
          ),
          child: KeyedSubtree(key: ValueKey(widget.action), child: glyph),
        ),
      ),
    );
  }
}
