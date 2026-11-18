import 'package:material_ui/material_ui.dart';

/// Design tokens (redesign spec §3). Every colour, text style, size and radius
/// the UI uses comes from here.
@immutable
class HermesTokens extends ThemeExtension<HermesTokens> {
  const HermesTokens({
    required this.dark,
    required this.bg,
    required this.bgRaised,
    required this.surface,
    required this.surfaceHigh,
    required this.glass,
    required this.glassStroke,
    required this.sheet,
    required this.outline,
    required this.hairline,
    required this.text,
    required this.textMuted,
    required this.textFaint,
    required this.accent,
    required this.accentSoft,
    required this.onAccentSoft,
    required this.onAccent,
    required this.closeFill,
    required this.onClose,
    required this.danger,
    required this.success,
    required this.warning,
    required this.scrim,
    this.typeface = HermesTypeface.phone,
  });

  final bool dark;
  final Color bg;
  final Color bgRaised;
  final Color surface;
  final Color surfaceHigh;
  final Color glass;
  final Color glassStroke;
  final Color sheet;
  final Color outline;
  final Color hairline;
  final Color text;
  final Color textMuted;
  final Color textFaint;
  final Color accent;
  final Color accentSoft;
  final Color onAccentSoft;
  final Color onAccent;
  final Color closeFill;
  final Color onClose;
  final Color danger;
  final Color success;
  final Color warning;
  final Color scrim;

  /// The typeface and reply metrics for this platform ([HermesTypeface]).
  final HermesTypeface typeface;

  static const darkTokens = HermesTokens(
    dark: true,
    bg: Color(0xFF000000),
    bgRaised: Color(0xFF0B0B0C),
    surface: Color(0xFF1C1C1E),
    surfaceHigh: Color(0xFF2A2A2D),
    glass: Color(0x1FFFFFFF),
    glassStroke: Color(0x1AFFFFFF),
    sheet: Color(0xF01C1C1E),
    outline: Color(0x24FFFFFF),
    hairline: Color(0x1AFFFFFF),
    text: Color(0xFFFFFFFF),
    textMuted: Color(0xFFB4B4B8),
    textFaint: Color(0xFF8E8E93),
    accent: Color(0xFF3D63F5),
    accentSoft: Color(0xFF20253A),
    onAccentSoft: Color(0xFFD7DBFF),
    onAccent: Color(0xFFFFFFFF),
    closeFill: Color(0xFFF2F0EC),
    onClose: Color(0xFF0B0B0C),
    danger: Color(0xFFFF6B6B),
    success: Color(0xFF4ADE80),
    warning: Color(0xFFF5B54A),
    scrim: Color(0x7A000000),
  );

  static const lightTokens = HermesTokens(
    dark: false,
    bg: Color(0xFFFFFFFF),
    bgRaised: Color(0xFFFAFAFA),
    surface: Color(0xFFF1F1F3),
    surfaceHigh: Color(0xFFE9E9EC),
    glass: Color(0x0F000000),
    glassStroke: Color(0x14000000),
    sheet: Color(0xF5FFFFFF),
    outline: Color(0x1F000000),
    hairline: Color(0x14000000),
    text: Color(0xFF16161A),
    // #68686F: the nearest grey with AA (4.56:1) on surfaceHigh #E9E9EC
    // (source chips); 5.5:1 on bg.
    textMuted: Color(0xFF68686F),
    textFaint: Color(0xFF8A8A91),
    accent: Color(0xFF2F57E8),
    accentSoft: Color(0xFFE8EDFF),
    onAccentSoft: Color(0xFF2F57E8),
    onAccent: Color(0xFFFFFFFF),
    closeFill: Color(0xFF16161A),
    onClose: Color(0xFFFFFFFF),
    danger: Color(0xFFC62828),
    success: Color(0xFF15803D),
    warning: Color(0xFF9A5B00),
    scrim: Color(0x52000000),
  );

  static HermesTokens of(BuildContext context) =>
      Theme.of(context).extension<HermesTokens>() ?? darkTokens;

  /// The opaque stand-in for [glass] when blur is off (§3.6, §7.3).
  Color get glassFallback => surface.withValues(alpha: 0.92);

  /// The opaque stand-in for [sheet] when blur is off.
  Color get sheetFallback => sheet.withValues(alpha: 0.98);

  // Typography (redesign spec §3.2, chat-rendering-v2 §1.3, typography.md).
  // Sizes are in sp; MediaQuery's text scaler applies. The phone values
  // below are scaled for desktop and web by [HermesTypeface].

  /// The bundled Roboto Flex, subset and variable (`wght`, `opsz`, `slnt`).
  /// [typeface] says whether this platform uses it or the system UI font.
  static const String fontFamily = 'HermesSans';
  static const String monoFamily = 'JetBrainsMono';
  static const List<String> fallback = ['Roboto'];

  /// A style in this platform's typeface: [size]/[line] sp on phones (scaled
  /// on desktop and web), weight [wght] (mapped by [HermesTypeface.weight]),
  /// optical size equal to the font size for the variable font, and even
  /// leading.
  TextStyle v(
    double size,
    double line,
    double wght,
    double tracking, [
    Color? color,
  ]) => typeface.style(size, line, wght, tracking, color ?? text);

  /// A HermesSans (Roboto Flex) style at exactly these values.
  static TextStyle hermesSans(
    double size,
    double line,
    double wght,
    double tracking,
    Color color,
  ) => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fallback,
    fontSize: size,
    height: line / size,
    letterSpacing: tracking,
    color: color,
    fontWeight: weightFor(wght),
    fontVariations: variations(wght, size),
    leadingDistribution: TextLeadingDistribution.even,
  );

  /// The [FontWeight] closest to a variable weight.
  static FontWeight weightFor(double wght) =>
      FontWeight.values[((wght / 100).round() - 1).clamp(0, 8)];

  /// The variation settings for HermesSans at [wght] and [size].
  static List<FontVariation> variations(
    double wght,
    double size, {
    bool oblique = false,
  }) => [
    FontVariation('wght', wght),
    FontVariation('opsz', size.clamp(8, 144).toDouble()),
    if (oblique) const FontVariation('slnt', -10),
  ];

  TextStyle get display => v(34, 40, 650, -0.6);
  TextStyle get headline => v(24, 30, 650, -0.3);
  TextStyle get title => v(17, 22, 650, -0.2);

  /// Reply text: 17/26 400 on phones (tracking 0 meets the §1.3 acceptance
  /// line, orchestrator decision 15 Nov 2026); 16/26 400 on desktop and web,
  /// as measured in the reference web app.
  TextStyle get body => typeface.style(
    typeface.bodySize,
    typeface.bodyLine,
    400,
    0,
    text,
    exact: true,
  );

  /// `**bold**` in replies: 700 on phones (measured stems), semibold 600 on
  /// desktop and web ("Segoe UI Semibold" in the reference).
  TextStyle get bodyStrong => typeface.style(
    typeface.bodySize,
    typeface.bodyLine,
    typeface.strong,
    0,
    text,
    exact: true,
  );

  /// `*emphasis*`: the oblique (`slnt −10`) of [body], or the system italic.
  TextStyle get bodyEm => body.hermesOblique();
  TextStyle get h1 => v(26, 32, 700, -0.4);
  TextStyle get h2 => v(23, 30, 650, -0.3);
  TextStyle get h3 => v(20, 27, 650, -0.2);

  /// H4–H6: a bold paragraph line.
  TextStyle get h4 => typeface.style(
    typeface.bodySize,
    typeface.bodyLine,
    typeface.strong,
    0,
    text,
    exact: true,
  );

  /// `<small>`, footnote lines, captions under tables.
  TextStyle get caption => v(14, 20, 400, 0, textMuted);
  TextStyle get row => v(16, 22, 500, 0);
  TextStyle get section => v(14, 18, 600, 0, textMuted);
  TextStyle get table => v(14.5, 20, 400, 0);
  TextStyle get tableHeader => v(14.5, 20, 700, 0);
  TextStyle get label => v(13, 16, 500, 0, textMuted);

  /// Source and option chips: 13/16 500.
  TextStyle get chip => v(13, 16, 500, 0, textMuted);

  /// hermes-ui control labels and live values.
  TextStyle get widgetLabel => v(17, 24, 700, -0.15);

  /// hermes-ui option chips and buttons: 15/20 500.
  TextStyle get control => v(15, 20, 500, 0);

  /// hermes-ui stat card value: 28/34 700.
  TextStyle get statValue => v(28, 34, 700, -0.4);

  /// hermes-ui stat card label and sub-line.
  TextStyle get statLabel => v(14.5, 20, 400, 0, textMuted);
  TextStyle get toast => v(15, 21, 400, -0.1);
  TextStyle get code => TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: fallback,
    fontSize: typeface.scaled(14.5),
    height: typeface.line(14.5, 22) / typeface.scaled(14.5),
    fontWeight: FontWeight.w400,
    color: text,
  );

  /// These tokens with typeface [type] (the theme picks it per platform).
  HermesTokens withType(HermesTypeface type) => identical(type, typeface)
      ? this
      : HermesTokens(
          dark: dark,
          bg: bg,
          bgRaised: bgRaised,
          surface: surface,
          surfaceHigh: surfaceHigh,
          glass: glass,
          glassStroke: glassStroke,
          sheet: sheet,
          outline: outline,
          hairline: hairline,
          text: text,
          textMuted: textMuted,
          textFaint: textFaint,
          accent: accent,
          accentSoft: accentSoft,
          onAccentSoft: onAccentSoft,
          onAccent: onAccent,
          closeFill: closeFill,
          onClose: onClose,
          danger: danger,
          success: success,
          warning: warning,
          scrim: scrim,
          typeface: type,
        );

  @override
  HermesTokens copyWith() => this;

  @override
  HermesTokens lerp(HermesTokens? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return HermesTokens(
      dark: t < 0.5 ? dark : other.dark,
      bg: l(bg, other.bg),
      bgRaised: l(bgRaised, other.bgRaised),
      surface: l(surface, other.surface),
      surfaceHigh: l(surfaceHigh, other.surfaceHigh),
      glass: l(glass, other.glass),
      glassStroke: l(glassStroke, other.glassStroke),
      sheet: l(sheet, other.sheet),
      outline: l(outline, other.outline),
      hairline: l(hairline, other.hairline),
      text: l(text, other.text),
      textMuted: l(textMuted, other.textMuted),
      textFaint: l(textFaint, other.textFaint),
      accent: l(accent, other.accent),
      accentSoft: l(accentSoft, other.accentSoft),
      onAccentSoft: l(onAccentSoft, other.onAccentSoft),
      onAccent: l(onAccent, other.onAccent),
      closeFill: l(closeFill, other.closeFill),
      onClose: l(onClose, other.onClose),
      danger: l(danger, other.danger),
      success: l(success, other.success),
      warning: l(warning, other.warning),
      scrim: l(scrim, other.scrim),
      typeface: t < 0.5 ? typeface : other.typeface,
    );
  }
}

/// Weight and slant changes that keep HermesSans' variation axes in step
/// with [TextStyle.fontWeight] (a plain `copyWith(fontWeight: …)` would leave
/// the variable font at its old `wght`).
extension HermesTextStyle on TextStyle {
  /// This style at variable weight [wght].
  TextStyle hermesWeight(double wght) => copyWith(
    fontWeight: HermesTokens.weightFor(wght),
    fontVariations: _withAxis('wght', wght),
  );

  /// The oblique (`slnt −10`) of this style; Roboto Flex has no italic.
  TextStyle hermesOblique() => fontFamily == HermesTokens.fontFamily
      ? copyWith(fontVariations: _withAxis('slnt', -10))
      : copyWith(fontStyle: FontStyle.italic);

  /// This style at [size] sp, keeping its line height in sp ([line]) and
  /// moving the optical size with it.
  TextStyle hermesSize(double size, {double? line}) {
    final l = line ?? (fontSize ?? size) * (height ?? 1.2);
    return copyWith(
      fontSize: size,
      height: l / size,
      fontVariations: fontVariations == null
          ? null
          : _withAxis('opsz', size.clamp(8, 144).toDouble()),
    );
  }

  /// The current variable weight (from the `wght` axis or [fontWeight]).
  double get hermesWght {
    for (final f in fontVariations ?? const <FontVariation>[]) {
      if (f.axis == 'wght') return f.value;
    }
    return (fontWeight ?? FontWeight.w400).value.toDouble();
  }

  List<FontVariation>? _withAxis(String axis, double value) {
    if (fontFamily != HermesTokens.fontFamily && fontVariations == null) {
      return null;
    }
    return [
      for (final f in fontVariations ?? const <FontVariation>[])
        if (f.axis != axis) f,
      FontVariation(axis, value),
    ];
  }
}

/// The reply typeface and metrics for one platform (docs/design/typography.md).
///
/// - Android: the bundled Roboto Flex at 17/26, bold 700 (measured against
///   the reference phone app: chat-rendering-v2 §0.2, §1.3).
/// - iOS: the system font (SF Pro via `CupertinoSystemText`), 17/26, bold
///   600, as the reference iOS app uses the platform font.
/// - Web: the bundled Roboto Flex at 16/26, 400/600/700. CanvasKit and
///   skwasm draw only fonts the app supplies, so the browser's system-ui
///   stack (Segoe UI, -apple-system…) cannot be used; the metrics match it.
/// - Windows, macOS, Linux: the platform UI font (Segoe UI, San Francisco,
///   the fontconfig default sans) at 16/26 with semibold 600 for bold, as
///   measured in the reference web app ("Segoe UI" 16/26, "Segoe UI
///   Semibold"). Nothing proprietary is bundled: the OS supplies the font.
@immutable
class HermesTypeface {
  const HermesTypeface({
    required this.name,
    required this.family,
    required this.fallback,
    required this.variable,
    required this.bodySize,
    required this.bodyLine,
    required this.strong,
    required this.heading,
    this.scale = 1,
  });

  final String name;
  final String family;
  final List<String> fallback;

  /// True for the bundled variable Roboto Flex (axes `wght`, `opsz`, `slnt`).
  final bool variable;
  final double bodySize, bodyLine;

  /// Weight of bold prose (`**…**`, H4–H6, table headers, control labels).
  final double strong;

  /// Weight of H2/H3 and titles (650 on the variable font).
  final double heading;

  /// Size factor for every style other than the body.
  final double scale;

  static const phone = HermesTypeface(
    name: 'phone',
    family: HermesTokens.fontFamily,
    fallback: HermesTokens.fallback,
    variable: true,
    bodySize: 17,
    bodyLine: 26,
    strong: 700,
    heading: 650,
  );

  static const ios = HermesTypeface(
    name: 'ios',
    family: 'CupertinoSystemText',
    fallback: [HermesTokens.fontFamily],
    variable: false,
    bodySize: 17,
    bodyLine: 26,
    strong: 600,
    heading: 600,
  );

  static const web = HermesTypeface(
    name: 'web',
    family: HermesTokens.fontFamily,
    fallback: HermesTokens.fallback,
    variable: true,
    bodySize: 16,
    bodyLine: 26,
    strong: 600,
    heading: 600,
    scale: 16 / 17,
  );

  static const windows = HermesTypeface(
    name: 'windows',
    family: 'Segoe UI',
    fallback: ['Segoe UI Emoji', 'Segoe UI Symbol', HermesTokens.fontFamily],
    variable: false,
    bodySize: 16,
    bodyLine: 26,
    strong: 600,
    heading: 600,
    scale: 16 / 17,
  );

  static const macos = HermesTypeface(
    name: 'macos',
    family: '.AppleSystemUIFont',
    fallback: [HermesTokens.fontFamily],
    variable: false,
    bodySize: 16,
    bodyLine: 26,
    strong: 600,
    heading: 600,
    scale: 16 / 17,
  );

  /// fontconfig resolves the generic `sans-serif` to the desktop's UI font.
  static const linux = HermesTypeface(
    name: 'linux',
    family: 'sans-serif',
    fallback: [
      'Ubuntu',
      'Adwaita Sans',
      'Cantarell',
      'DejaVu Sans',
      HermesTokens.fontFamily,
    ],
    variable: false,
    bodySize: 16,
    bodyLine: 26,
    strong: 600,
    heading: 600,
    scale: 16 / 17,
  );

  /// The typeface for [platform] ([web] wins on the web).
  static HermesTypeface forPlatform(
    TargetPlatform platform, {
    bool web = false,
  }) {
    if (web) return HermesTypeface.web;
    return switch (platform) {
      TargetPlatform.iOS => ios,
      TargetPlatform.windows => windows,
      TargetPlatform.macOS => macos,
      TargetPlatform.linux => linux,
      TargetPlatform.android || TargetPlatform.fuchsia => phone,
    };
  }

  /// A phone size on this platform, rounded to 0.5 sp.
  double scaled(double size) =>
      scale == 1 ? size : (size * scale * 2).roundToDouble() / 2;

  /// A phone line height on this platform, rounded to whole dp.
  double line(double size, double line) =>
      scale == 1 ? line : (line * scale).roundToDouble();

  /// The weight a phone weight becomes here: bold prose becomes [strong],
  /// 650 headings become [heading]; 700 display weights stay.
  double weight(double wght) {
    if (wght == 650) return heading;
    if (wght == 700 && strong < 700) return strong;
    return wght;
  }

  /// A text style at phone metrics [size]/[lineHeight], weight [wght] and
  /// tracking, scaled for this platform. With [exact], [size] and
  /// [lineHeight] are used as given.
  TextStyle style(
    double size,
    double lineHeight,
    double wght,
    double tracking,
    Color color, {
    bool exact = false,
  }) {
    final s = exact ? size : scaled(size);
    final l = exact ? lineHeight : line(size, lineHeight);
    final w = exact ? wght : weight(wght);
    if (variable) {
      return HermesTokens.hermesSans(
        s,
        l,
        w,
        tracking,
        color,
      ).copyWith(fontFamily: family, fontFamilyFallback: fallback);
    }
    return TextStyle(
      fontFamily: family,
      fontFamilyFallback: fallback,
      fontSize: s,
      height: l / s,
      // System UI fonts are spaced for their sizes ("normal").
      letterSpacing: 0,
      color: color,
      fontWeight: HermesTokens.weightFor(w),
      leadingDistribution: TextLeadingDistribution.even,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HermesTypeface && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// The orb palette, shared by both themes (§3.1).
abstract final class OrbPalette {
  static const skyTop = Color(0xFF2F55F0);
  static const skyLow = Color(0xFF7F9BFF);
  static const cloud = Color(0xFFF4F1FA);
  static const cloudShade = Color(0xFFCFC6E3);
  static const rim = Color(0x59FFFFFF);
  static const glow = Color(0x2E8FA6FF);
  static const errorSkyTop = Color(0xFF8C5A5A);
  static const errorSkyLow = Color(0xFFC99393);
}

/// Spacing scale (§3.3).
abstract final class Sp {
  static const double xxs = 2, xs = 4, s = 8, m = 12, l = 16, xl = 20;
  static const double xxl = 24, x3 = 32, x4 = 40, x5 = 56;

  /// Screen side padding for content and for controls.
  static const double content = 20, controls = 16;

  /// Thread text gutter (chat-rendering-v2 §2.1; replaces [content] there).
  static const double thread = 16;

  /// Maximum reply text width on tablets and desktops.
  static const double readingMeasure = 680;
  static const double paragraph = 16;
  static const double sameSpeaker = 8, betweenSpeakers = 24;
  static const double composerBottom = 12;
}

/// Corner radii (§3.4).
abstract final class Rad {
  static const double inlineCode = 6, codeBlock = 16, bubble = 22;
  static const double menu = 24, card = 20, sheet = 32, field = 16;
  static const double toast = 20, row = 12;
}

/// Sizes (§3.5).
abstract final class Sz {
  static const double glassButton = 40, hit = 48;
  static const double liveControl = 52, liveGap = 8;
  static const double composerMin = 52, action = 40;
  static const double effortTrackH = 52, effortThumb = 40, effortDot = 6;
  static const double sheetInset = 10, sheetMaxWidth = 520;
  static const double contentMaxWidth = 720;
  static const double wideLayout = 900, sidebar = 300;
  static const double dockRatio = 0.41;

  static double orbCentered(double width) =>
      (0.5 * width).clamp(168.0, 280.0).toDouble();

  /// The left strip (past the system back inset) where a rightward swipe
  /// opens the chat list; elsewhere on the chat it opens Tasks.
  static const double drawerEdge = 24;
  static double drawerWidth(double width) =>
      (0.82 * width).clamp(0.0, 340.0).toDouble();
  static double effortTrack(double width) =>
      (width - 72).clamp(160.0, 360.0).toDouble();
}
