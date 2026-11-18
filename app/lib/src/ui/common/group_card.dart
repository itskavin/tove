import 'package:material_ui/material_ui.dart';

import '../feedback.dart';
import '../theme/tokens.dart';
import 'glass.dart';

/// An outlined group of rows with full-width hairline separators (§5.8).
class GroupCard extends StatelessWidget {
  const GroupCard({super.key, required this.children, this.margin});

  final List<Widget> children;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: t.outline),
          borderRadius: BorderRadius.circular(Rad.card),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Rad.card),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(height: 1, thickness: 1, color: t.hairline),
                  children[i],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A 56 dp row: leading icon, label, muted value and a trailing glyph.
class GroupRow extends StatelessWidget {
  const GroupRow({
    super.key,
    required this.label,
    this.icon,
    this.value,
    this.trailing,
    this.onTap,
    this.selected = false,
    this.danger = false,
    this.semanticsHint,
    this.subtitle,
  });

  final String label;
  final IconData? icon;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool selected;
  final bool danger;
  final String? semanticsHint;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final color = danger ? t.danger : t.text;
    return Semantics(
      // Its own node: never merged with a neighbouring text block.
      container: true,
      button: onTap != null,
      selected: selected,
      hint: semanticsHint,
      child: InkWell(
        onTap: onTap,
        highlightColor: t.surfaceHigh,
        splashColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 22, color: color),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label, style: t.row.copyWith(color: color)),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!, style: t.label.hermesWeight(400)),
                      ],
                    ],
                  ),
                ),
                if (value != null) ...[
                  const SizedBox(width: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(
                      value!,
                      style: t.row
                          .copyWith(color: t.textMuted)
                          .hermesWeight(400),
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
                if (trailing != null) ...[
                  const SizedBox(width: 6),
                  IconTheme.merge(
                    data: IconThemeData(color: t.textMuted, size: 20),
                    child: trailing!,
                  ),
                ] else if (selected) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.check_rounded, size: 20, color: t.text),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A "Section" header (§3.2) used above group cards and drawer lists.
class SectionHeader extends StatelessWidget {
  const SectionHeader(
    this.text, {
    super.key,
    this.padding = const EdgeInsets.fromLTRB(20, 24, 20, 8),
  });
  final String text;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Semantics(
      header: true,
      child: Text(text, style: HermesTokens.of(context).section),
    ),
  );
}

/// A switch row inside a group card.
class SwitchRow extends StatelessWidget {
  const SwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.icon,
    this.subtitle,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final IconData? icon;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    // Every toggle clicks (round 6).
    void change(bool on) {
      FeedbackScope.haptic(context, Haptic.selection);
      onChanged(on);
    }

    return MergeSemantics(
      child: GroupRow(
        label: label,
        icon: icon,
        subtitle: subtitle,
        onTap: () => change(!value),
        trailing: Switch(value: value, onChanged: change),
      ),
    );
  }
}

/// The 36 dp round back button used at the top of sheet pages.
class SheetBackButton extends StatelessWidget {
  const SheetBackButton({super.key, required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => GlassButton(
    label: 'Back',
    size: 36,
    onPressed: onPressed,
    child: Icon(
      Icons.arrow_back_rounded,
      size: 20,
      color: HermesTokens.of(context).text,
    ),
  );
}
