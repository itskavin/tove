import 'package:material_ui/material_ui.dart';

import 'markdown_style.dart';

/// A source link from a "Sources:" line (chat-rendering-v2 §1.11): neutral
/// `surfaceHigh` stadium,
/// a generic globe glyph (no remote favicons) and the host name. The pill is
/// 24 dp tall at 1× text; tappable pills get a 48 dp hit target.
class SourcePill extends StatelessWidget {
  const SourcePill({
    super.key,
    required this.label,
    required this.onTap,
    this.icon = Icons.language_rounded,
    this.semanticsLabel,
    this.style,
    this.opacity = 1,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData icon;
  final String? semanticsLabel;
  final MarkdownStyle? style;

  /// The streaming fade; applied to the fill and the text.
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final s = style ?? MarkdownStyle.of(context);
    final fg = s.textMuted.withValues(alpha: s.textMuted.a * opacity);
    final pill = DecoratedBox(
      decoration: ShapeDecoration(
        color: s.surfaceHigh.withValues(alpha: s.surfaceHigh.a * opacity),
        shape: const StadiumBorder(),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                style: s.chip.copyWith(color: fg),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
    if (onTap == null) {
      return Semantics(
        label: semanticsLabel ?? label,
        excludeSemantics: true,
        child: pill,
      );
    }
    final box = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Align(widthFactor: 1, heightFactor: 1, child: pill),
    );
    return Semantics(
      link: true,
      label: semanticsLabel ?? label,
      excludeSemantics: true,
      onTap: onTap,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onTap!();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: box,
        ),
      ),
    );
  }
}
