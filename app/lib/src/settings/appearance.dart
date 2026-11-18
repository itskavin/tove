import 'package:material_ui/material_ui.dart';

import '../ui/theme/tokens.dart';

/// Accent colours (Settings › General › Accent colour). Synced as
/// `tove.accent`.
enum AccentColour {
  blue('Blue', Color(0xFF3D63F5), Color(0xFF2F57E8)),
  green('Green', Color(0xFF22A06B), Color(0xFF13795B)),
  purple('Purple', Color(0xFF8B5CF6), Color(0xFF6D3FD8)),
  pink('Pink', Color(0xFFE5508C), Color(0xFFC2306F)),
  orange('Orange', Color(0xFFF08A24), Color(0xFFB55A06)),
  teal('Teal', Color(0xFF14A3B8), Color(0xFF0B7A8C));

  const AccentColour(this.label, this.dark, this.light);
  final String label;

  /// The accent on the dark theme (white text on it) and on the light one.
  final Color dark, light;

  Color forBrightness(Brightness b) => b == Brightness.dark ? dark : light;
}

/// Text sizes (Settings › Accessibility › Text size), as a factor on the
/// system text size. Per device.
enum TextSize {
  small('Small', 0.9),
  standard('Default', 1.0),
  large('Large', 1.15),
  larger('Larger', 1.3),
  largest('Largest', 1.5);

  const TextSize(this.label, this.factor);
  final String label;
  final double factor;
}

/// [base] with the accent and contrast preferences applied.
///
/// The blue accent at normal contrast returns [base] unchanged.
ThemeData applyAppearance(
  ThemeData base, {
  required AccentColour accent,
  required bool highContrast,
}) {
  if (accent == AccentColour.blue && !highContrast) return base;
  final t = base.extension<HermesTokens>();
  if (t == null) return base;
  final dark = base.brightness == Brightness.dark;
  final a = accent == AccentColour.blue
      ? t.accent
      : accent.forBrightness(base.brightness);
  final soft = accent == AccentColour.blue
      ? t.accentSoft
      : Color.alphaBlend(a.withValues(alpha: dark ? 0.22 : 0.12), t.bg);
  final onSoft = accent == AccentColour.blue
      ? t.onAccentSoft
      : (dark ? Color.lerp(a, Colors.white, 0.65)! : a);
  final next = recolourTokens(
    t,
    accent: a,
    accentSoft: soft,
    onAccentSoft: onSoft,
    textMuted: highContrast
        ? (dark ? const Color(0xFFE4E4E7) : const Color(0xFF3A3A40))
        : null,
    textFaint: highContrast
        ? (dark ? const Color(0xFFC4C4C8) : const Color(0xFF55555C))
        : null,
    hairline: highContrast
        ? (dark ? const Color(0x66FFFFFF) : const Color(0x52000000))
        : null,
    outline: highContrast
        ? (dark ? const Color(0x8CFFFFFF) : const Color(0x73000000))
        : null,
    glassStroke: highContrast
        ? (dark ? const Color(0x66FFFFFF) : const Color(0x52000000))
        : null,
  );
  final scheme = base.colorScheme.copyWith(
    primary: next.accent,
    secondary: next.accent,
    onSurfaceVariant: next.textMuted,
    outline: next.outline,
    outlineVariant: next.hairline,
  );
  WidgetStateProperty<Color?> track() => WidgetStateProperty.resolveWith(
    (s) => s.contains(WidgetState.selected) ? next.accent : next.surfaceHigh,
  );
  return base.copyWith(
    extensions: [
      next,
      ...base.extensions.values.where((e) => e is! HermesTokens),
    ],
    colorScheme: scheme,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: next.accent,
      selectionColor: next.accent.withValues(alpha: 0.35),
      selectionHandleColor: next.accent,
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      focusedBorder: _recolourBorder(
        base.inputDecorationTheme.focusedBorder,
        next.accent,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.copyWith(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? next.accent.withValues(alpha: 0.4)
              : next.accent,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: base.textButtonTheme.style?.copyWith(
        foregroundColor: WidgetStatePropertyAll(next.accent),
      ),
    ),
    switchTheme: base.switchTheme.copyWith(trackColor: track()),
    progressIndicatorTheme: base.progressIndicatorTheme.copyWith(
      color: next.accent,
    ),
    dividerTheme: base.dividerTheme.copyWith(color: next.hairline),
  );
}

InputBorder? _recolourBorder(InputBorder? b, Color c) => b is OutlineInputBorder
    ? b.copyWith(borderSide: b.borderSide.copyWith(color: c))
    : b;

/// [t] with some colours replaced, keeping every other field (including any
/// non-colour fields the theme adds) as it is.
///
/// [HermesTokens] has no colour `copyWith`, so this builds the recoloured
/// set and carries [t]'s other fields over with two lerps: `x.lerp(t, 0.5)`
/// takes [t]'s discrete fields (they switch at 0.5) and the midpoint
/// colours, and `t.lerp(mid, 2)` extrapolates the colours back to `x`'s.
/// Unchanged colours are equal in both, so they come out exactly as in [t].
/// Integration note: replace with a `HermesTokens.withColours` once the
/// theme module has one.
HermesTokens recolourTokens(
  HermesTokens t, {
  Color? accent,
  Color? accentSoft,
  Color? onAccentSoft,
  Color? textMuted,
  Color? textFaint,
  Color? hairline,
  Color? outline,
  Color? glassStroke,
}) {
  final x = HermesTokens(
    dark: t.dark,
    bg: t.bg,
    bgRaised: t.bgRaised,
    surface: t.surface,
    surfaceHigh: t.surfaceHigh,
    glass: t.glass,
    glassStroke: glassStroke ?? t.glassStroke,
    sheet: t.sheet,
    outline: outline ?? t.outline,
    hairline: hairline ?? t.hairline,
    text: t.text,
    textMuted: textMuted ?? t.textMuted,
    textFaint: textFaint ?? t.textFaint,
    accent: accent ?? t.accent,
    accentSoft: accentSoft ?? t.accentSoft,
    onAccentSoft: onAccentSoft ?? t.onAccentSoft,
    onAccent: t.onAccent,
    closeFill: t.closeFill,
    onClose: t.onClose,
    danger: t.danger,
    success: t.success,
    warning: t.warning,
    scrim: t.scrim,
  );
  final mid = x.lerp(t, 0.5);
  return t.lerp(mid, 2);
}

/// Multiplies the system text size by [factor] below it.
class AppTextScale extends StatelessWidget {
  const AppTextScale({super.key, required this.factor, required this.child});

  final double factor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (factor == 1.0) return child;
    final mq = MediaQuery.of(context);
    final system = mq.textScaler.scale(16) / 16;
    return MediaQuery(
      data: mq.copyWith(textScaler: TextScaler.linear(system * factor)),
      child: child,
    );
  }
}
