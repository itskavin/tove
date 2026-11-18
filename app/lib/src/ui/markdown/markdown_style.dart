import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';

/// Colours, text styles and spacing for the markdown renderer
/// (chat-rendering-v2 §1, §3.8).
///
/// [MarkdownStyle.of] derives it from the app's [HermesTokens]; pass a custom
/// one to [HermesMarkdown] or [StreamingMarkdown] to override it. Two styles
/// with equal fields compare equal, so building a new one per frame does not
/// invalidate the renderer's block cache.
@immutable
class MarkdownStyle {
  const MarkdownStyle({
    required this.body,
    required this.h1,
    required this.h2,
    required this.h3,
    required this.code,
    required this.table,
    required this.tableHeader,
    required this.label,
    required this.text,
    required this.textMuted,
    required this.surface,
    required this.surfaceHigh,
    required this.outline,
    required this.hairline,
    required this.accentSoft,
    required this.onAccentSoft,
    required this.background,
    TextStyle? h4,
    TextStyle? caption,
    TextStyle? chip,
    TextStyle? title,
    TextStyle? widgetLabel,
    TextStyle? control,
    TextStyle? statValue,
    TextStyle? statLabel,
    Color? closeFill,
    Color? onClose,
    Color? success,
    Color? warning,
    Color? danger,
    this.paragraphGap = 16,
    this.headingGapAbove = 24,
    this.headingGapBelow = 8,
    this.h1GapAbove = 32,
    this.h1GapBelow = 12,
    this.h3GapAbove = 20,
    this.leadInListGap = 8,
    this.tableGapAbove = 12,
    this.ruleGap = 24,
    this.listIndent = 32,
    this.nestedListIndent = 28,
    this.listItemGap = 0,
    this.looseListItemGap = 8,
    this.bulletSize = 6,
    this.codeBlockRadius = 16,
    this.codeBlockPadding = 16,
    this.inlineCodeRadius = 6,
    this.tableMinColumnWidth = 112,
    this.tableMaxColumnWidth = 300,
    this.tableColumnGap = 24,
    this.tableCellPadding = 8,
    this.tableBleed = 16,
    this.tableEdgeFade = 28,
    this.frameRadius = 12,
    this.strongWeight = 700,
  }) : h4 = h4 ?? body,
       caption = caption ?? label,
       chip = chip ?? label,
       title = title ?? body,
       widgetLabel = widgetLabel ?? body,
       control = control ?? body,
       statValue = statValue ?? h1,
       statLabel = statLabel ?? label,
       closeFill = closeFill ?? text,
       onClose = onClose ?? background,
       success = success ?? text,
       warning = warning ?? text,
       danger = danger ?? text;

  /// The spec's mapping from design tokens.
  factory MarkdownStyle.fromTokens(HermesTokens t) => MarkdownStyle(
    body: t.body,
    h1: t.h1,
    h2: t.h2,
    h3: t.h3,
    h4: t.h4,
    code: t.code,
    table: t.table,
    tableHeader: t.tableHeader,
    label: t.label,
    caption: t.caption,
    chip: t.chip,
    title: t.title,
    widgetLabel: t.widgetLabel,
    control: t.control,
    statValue: t.statValue,
    statLabel: t.statLabel,
    text: t.text,
    textMuted: t.textMuted,
    surface: t.surface,
    surfaceHigh: t.surfaceHigh,
    outline: t.outline,
    hairline: t.hairline,
    accentSoft: t.accentSoft,
    onAccentSoft: t.onAccentSoft,
    background: t.bg,
    closeFill: t.closeFill,
    onClose: t.onClose,
    success: t.success,
    warning: t.warning,
    danger: t.danger,
    strongWeight: t.typeface.strong,
  );

  static HermesTokens? _memoTokens;
  static MarkdownStyle? _memo;

  /// The style for the current theme's [HermesTokens].
  static MarkdownStyle of(BuildContext context) {
    final t = HermesTokens.of(context);
    if (!identical(t, _memoTokens)) {
      _memoTokens = t;
      _memo = MarkdownStyle.fromTokens(t);
    }
    return _memo!;
  }

  /// Paragraph text (17/26, 400). Bold is 700 ([bodyStrong]).
  final TextStyle body;
  final TextStyle h1, h2, h3, h4;

  /// Block code (JetBrains Mono 14.5/22). Inline code uses this family at
  /// 0.88 × [body].
  final TextStyle code;
  final TextStyle table, tableHeader;

  /// Small UI labels (image placeholders, "Sources:").
  final TextStyle label;

  /// `<small>`, code-block language, captions (14/20, muted).
  final TextStyle caption;

  /// Source and option chip text (13/16 500, muted).
  final TextStyle chip;

  /// Sheet row titles (17/22 650).
  final TextStyle title;

  /// hermes-ui: control labels (17/24 700), chip and button labels (15/20
  /// 500), stat values (28/34 700) and stat labels (14.5/20, muted).
  final TextStyle widgetLabel, control, statValue, statLabel;

  final Color text, textMuted, surface, surfaceHigh, outline, hairline;
  final Color accentSoft, onAccentSoft;

  /// The canvas behind the message.
  final Color background;

  /// The one primary action fill and its label colour.
  final Color closeFill, onClose;

  /// Tone colours (hermes-ui glyphs and stat values only).
  final Color success, warning, danger;

  final double paragraphGap, headingGapAbove, headingGapBelow;
  final double h1GapAbove, h1GapBelow, h3GapAbove;

  /// A paragraph ending in ":" followed by a list.
  final double leadInListGap;

  /// A paragraph followed by a table.
  final double tableGapAbove;
  final double ruleGap;

  /// Hanging indent of a top-level list, and of each nested level.
  final double listIndent, nestedListIndent;

  /// Between items of a tight list, and of a loose one.
  final double listItemGap, looseListItemGap;

  /// Bullet dot diameter at 1× text.
  final double bulletSize;
  final double codeBlockRadius, codeBlockPadding, inlineCodeRadius;
  final double tableMinColumnWidth, tableMaxColumnWidth;

  /// Space after each table column's text, and above and below each cell.
  final double tableColumnGap, tableCellPadding;

  /// How far top-level tables extend past the text column on each side
  /// (the thread's gutter), so they scroll to the screen edges.
  final double tableBleed;

  /// Width of the fade on a table edge with more columns past it, shown
  /// only when the table is wider than the screen (0: none).
  final double tableEdgeFade;

  /// Radius of hermes-ui frames and cards.
  final double frameRadius;

  /// The weight of `**bold**`: 700 on phones, semibold 600 on desktop and
  /// web ([HermesTypeface.strong]).
  final double strongWeight;

  TextStyle get bodyStrong => body.hermesWeight(strongWeight);

  TextStyle get bodyEm => body.hermesOblique();

  /// Inline code: mono at 0.88 × body. Its line height is the body line
  /// height less the chip's 2 × 1.5 dp padding, so a chip never grows a line.
  TextStyle get inlineCode {
    final size = (body.fontSize ?? 17) * 0.88;
    final line = (body.fontSize ?? 17) * (body.height ?? 26 / 17) - 3;
    return code.copyWith(fontSize: size, height: line / size);
  }

  List<Object?> get _props => [
    body,
    h1,
    h2,
    h3,
    h4,
    code,
    table,
    tableHeader,
    label,
    caption,
    chip,
    title,
    widgetLabel,
    control,
    statValue,
    statLabel,
    text,
    textMuted,
    surface,
    surfaceHigh,
    outline,
    hairline,
    accentSoft,
    onAccentSoft,
    background,
    closeFill,
    onClose,
    success,
    warning,
    danger,
    paragraphGap,
    headingGapAbove,
    headingGapBelow,
    h1GapAbove,
    h1GapBelow,
    h3GapAbove,
    leadInListGap,
    tableGapAbove,
    ruleGap,
    listIndent,
    nestedListIndent,
    listItemGap,
    looseListItemGap,
    bulletSize,
    codeBlockRadius,
    codeBlockPadding,
    inlineCodeRadius,
    tableMinColumnWidth,
    tableMaxColumnWidth,
    tableColumnGap,
    tableCellPadding,
    tableBleed,
    tableEdgeFade,
    frameRadius,
    strongWeight,
  ];

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MarkdownStyle) return false;
    final a = _props, b = other._props;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_props);
}
