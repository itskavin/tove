/// Turns `package:markdown` nodes into widgets (spec §5.2). Internal to the
/// markdown module; use [HermesMarkdown] or [StreamingMarkdown].
library;

import 'package:flutter/gestures.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:material_ui/material_ui.dart';

import '../interactive/html_subset.dart';
import '../interactive/scope.dart';
import '../interactive/ui_block.dart';
import '../interactive/html_view.dart' show HermesHtml;
import '../interactive/ui_model.dart' show hermesHtmlInfo, hermesUiInfo;
import '../openui/openui_block.dart' show OpenUiBlock, openUiInfo;
import 'artifact.dart';
import '../interactive/ui_widgets.dart' show UiDetailsView;
import '../theme/tokens.dart';
import 'code_block.dart';
import 'md_blocks.dart' show normalizeBulletGlyphs;
import 'footnotes.dart';
import 'plain_math.dart';
import 'links.dart';
import 'markdown_style.dart';
import 'md_images.dart';
import 'md_table.dart';
import 'source_pill.dart';

/// Called with a link's destination when it is tapped.
typedef MarkdownLinkTap = void Function(String href);

/// Test hooks. Not part of the public API.
abstract final class MarkdownDebug {
  /// Incremented on every block parse.
  static int parseCount = 0;

  /// Called whenever a block widget builds, with its index and whether it is
  /// still live (being written or fading in). A block that built once with
  /// `live == false` is final.
  static void Function(int index, bool live)? onBlockBuild;
}

/// GitHub-flavoured markdown without its footnote definitions (they are
/// pre-scanned across the whole message instead) and with `[^label]`
/// references as `fnref` elements.
final _extensions = md.ExtensionSet(
  const [
    md.FencedCodeBlockSyntax(),
    md.TableSyntax(),
    md.UnorderedListWithCheckboxSyntax(),
    md.OrderedListWithCheckboxSyntax(),
  ],
  [
    FootnoteRefSyntax(),
    md.InlineHtmlSyntax(),
    md.StrikethroughSyntax(),
    md.AutolinkExtensionSyntax(),
  ],
);

/// Parses one block with GitHub-flavoured markdown, the inline HTML subset
/// and footnote references. Footnote definition lines are dropped; a
/// `<details>` block becomes an `x-details` element.
List<md.Node> parseMarkdownBlock(String source) {
  MarkdownDebug.parseCount++;
  final details = parseDetailsHtml(source);
  if (details != null) {
    final e = md.Element(
      'x-details',
      details.body.isEmpty ? <md.Node>[] : _parse(details.body),
    );
    e.attributes['summary'] = details.summary;
    if (details.open) e.attributes['open'] = 'open';
    return [e];
  }
  final src = stripFootnoteDefs(source);
  if (src.trim().isEmpty) return const [];
  return _parse(src);
}

List<md.Node> _parse(String src) {
  final doc = md.Document(extensionSet: _extensions, encodeHtml: false);
  return applyInlineHtml(
    doc.parseLines(plainMath(normalizeBulletGlyphs(src)).split('\n')),
  );
}

/// The number of fade offsets a node list spans: the length of its text in
/// document order, which is how the renderer counts as it walks.
int textLength(List<md.Node> nodes) {
  var n = 0;
  for (final node in nodes) {
    n += node.textContent.length;
  }
  return n;
}

/// Opacity per text offset: run `i` covers `[starts[i], starts[i + 1])`.
/// Text before the first run is opaque.
@immutable
class FadeRuns {
  const FadeRuns(this.starts, this.alphas);

  final List<int> starts;
  final List<double> alphas;

  double alphaAt(int offset) {
    for (var i = starts.length - 1; i >= 0; i--) {
      if (starts[i] <= offset) return alphas[i];
    }
    return 1;
  }

  /// The next run start after [offset], or null.
  int? nextBoundary(int offset) {
    for (final s in starts) {
      if (s > offset) return s;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is FadeRuns &&
      _listEq(other.starts, starts) &&
      _listEq(other.alphas, alphas);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(starts), Object.hashAll(alphas));
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// What a block starts and ends with, for the gaps between blocks.
enum BlockEdge {
  h1,

  /// H2.
  heading,

  /// H3–H6.
  h3,
  paragraph,

  /// A paragraph ending in ":" (a lead-in to a list).
  leadIn,
  list,
  table,
  rule,
  other,
  none,
}

BlockEdge edgeOf(md.Node? n) {
  if (n == null) return BlockEdge.none;
  if (n is! md.Element) return BlockEdge.paragraph;
  return switch (n.tag) {
    'h1' => BlockEdge.h1,
    'h2' => BlockEdge.heading,
    'h3' || 'h4' || 'h5' || 'h6' => BlockEdge.h3,
    'hr' => BlockEdge.rule,
    'ul' || 'ol' => BlockEdge.list,
    'table' => BlockEdge.table,
    'p' =>
      n.textContent.trimRight().endsWith(':')
          ? BlockEdge.leadIn
          : BlockEdge.paragraph,
    _ => BlockEdge.other,
  };
}

/// Vertical gap between two top-level elements (chat-rendering-v2 §1.4):
/// 16 between blocks; 24 above a heading (H1 32, H3–H6 20) and 8 below one
/// (H1 12); 8 from a paragraph ending in ":" to its list; 12 from a
/// paragraph to a table; 24 around a rule.
double gapBetween(BlockEdge above, BlockEdge below, MarkdownStyle s) {
  if (above == BlockEdge.none || below == BlockEdge.none) return 0;
  if (above == BlockEdge.rule || below == BlockEdge.rule) return s.ruleGap;
  switch (below) {
    case BlockEdge.h1:
      return s.h1GapAbove;
    case BlockEdge.heading:
      return s.headingGapAbove;
    case BlockEdge.h3:
      return s.h3GapAbove;
    default:
  }
  if (above == BlockEdge.h1) return s.h1GapBelow;
  if (above == BlockEdge.heading || above == BlockEdge.h3) {
    return s.headingGapBelow;
  }
  if (below == BlockEdge.list && above == BlockEdge.leadIn) {
    return s.leadInListGap;
  }
  if (below == BlockEdge.table &&
      (above == BlockEdge.paragraph || above == BlockEdge.leadIn)) {
    return s.tableGapAbove;
  }
  return s.paragraphGap;
}

final _sourcesLabel = RegExp(
  r'^\s*(sources?|references?)\s*:?\s*$',
  caseSensitive: false,
);
final _sourcesPrefix = RegExp(
  r'^\s*(sources?|references?)\s*:',
  caseSensitive: false,
);
final _punctOnly = RegExp(r'^[\s,;·•|/\-–—.]*$');

/// True if [n] is a paragraph whose whole text is a "Sources:" label.
bool isSourcesLabel(md.Node? n) =>
    n is md.Element && n.tag == 'p' && _sourcesLabel.hasMatch(n.textContent);

/// One block of rendered markdown. Holds the tap recognizers its links use.
class MdBlockView extends StatefulWidget {
  const MdBlockView({
    super.key,
    required this.index,
    required this.nodes,
    required this.style,
    required this.onLinkTap,
    this.fade,
    this.complete = true,
    this.afterSourcesLabel = false,
    this.footnotes = const {},
    this.uiOrdinal = 0,
  });

  final int index;
  final List<md.Node> nodes;
  final MarkdownStyle style;
  final MarkdownLinkTap onLinkTap;
  final FadeRuns? fade;

  /// False while more text may still arrive in this block.
  final bool complete;

  /// The previous block was a bare "Sources:" line, so a list of links at
  /// the start of this block renders as source pills.
  final bool afterSourcesLabel;

  /// The message's footnote definitions, by label.
  final Map<String, Footnote> footnotes;

  /// The number of hermes-ui blocks in the message before this block.
  final int uiOrdinal;

  @override
  State<MdBlockView> createState() => _MdBlockViewState();
}

class _MdBlockViewState extends State<MdBlockView> {
  final _recognizers = <GestureRecognizer>[];

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    MarkdownDebug.onBlockBuild?.call(
      widget.index,
      widget.fade != null || !widget.complete,
    );
    _disposeRecognizers();
    final r = _Renderer(
      context: context,
      style: widget.style,
      onLinkTap: widget.onLinkTap,
      fade: widget.fade,
      recognizers: _recognizers,
      complete: widget.complete,
      footnotes: widget.footnotes,
      uiOrdinal: widget.uiOrdinal,
    );
    return r.blocks(
      widget.nodes,
      widget.style.body,
      afterSourcesLabel: widget.afterSourcesLabel,
    );
  }
}

const _blockTags = {
  'p',
  'ul',
  'ol',
  'pre',
  'blockquote',
  'table',
  'hr',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'x-details',
};

class _Renderer {
  _Renderer({
    required this.context,
    required this.style,
    required this.onLinkTap,
    required this.fade,
    required this.recognizers,
    required this.complete,
    required this.footnotes,
    required this.uiOrdinal,
  });

  final BuildContext context;
  final MarkdownStyle style;
  final MarkdownLinkTap onLinkTap;
  final FadeRuns? fade;
  final List<GestureRecognizer> recognizers;
  final bool complete;
  final Map<String, Footnote> footnotes;
  final int uiOrdinal;

  /// Text offset in document order, for the fade.
  int _offset = 0;

  /// hermes-ui blocks rendered so far in this block.
  int _uiCount = 0;

  /// > 0 inside lists, quotes and details (tables do not bleed there).
  int _nest = 0;

  late final TextScaler _scaler = MediaQuery.textScalerOf(context);

  Color _fadeColor(Color c, double a) =>
      a >= 1 ? c : c.withValues(alpha: c.a * a);

  TextStyle _faded(TextStyle s, double a) => a >= 1
      ? s
      : s.copyWith(
          color: _fadeColor(s.color ?? style.text, a),
          decorationColor: s.decorationColor == null
              ? null
              : _fadeColor(s.decorationColor!, a),
          backgroundColor: s.backgroundColor == null
              ? null
              : _fadeColor(s.backgroundColor!, a),
        );

  double _alphaHere() => fade?.alphaAt(_offset) ?? 1;

  void _skip(md.Node n) => _offset += n.textContent.length;

  // ---------------------------------------------------------------- blocks

  Widget blocks(
    List<md.Node> nodes,
    TextStyle base, {
    bool afterSourcesLabel = false,
    double? gap,
  }) {
    final children = <Widget>[];
    md.Node? prev;
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      if (n is md.Text && n.text.trim().isEmpty) {
        _skip(n);
        continue;
      }
      if (prev != null) {
        children.add(
          SizedBox(height: gap ?? gapBetween(edgeOf(prev), edgeOf(n), style)),
        );
      }
      final pillsAfter = (i == 0 && afterSourcesLabel) || isSourcesLabel(prev);
      children.add(_block(n, base, sourcesList: pillsAfter));
      prev = n;
    }
    if (children.isEmpty) return const SizedBox.shrink();
    if (children.length == 1) return children.single;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _nested(Widget Function() build) {
    _nest++;
    try {
      return build();
    } finally {
      _nest--;
    }
  }

  Widget _block(md.Node n, TextStyle base, {bool sourcesList = false}) {
    if (n is md.Text) return _paragraph([n], base);
    final e = n as md.Element;
    switch (e.tag) {
      case 'p':
        final gallery = _imageParagraph(e, base);
        if (gallery != null) return gallery;
        final pills = _sourcesParagraph(e);
        if (pills != null) return pills;
        if (isSourcesLabel(e)) {
          return _paragraph(
            e.children ?? const [],
            style.label.hermesWeight(600),
          );
        }
        return _paragraph(e.children ?? const [], base);
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final hs = switch (e.tag) {
          'h1' => style.h1,
          'h2' => style.h2,
          'h3' => style.h3,
          _ => style.h4,
        };
        return Semantics(
          header: true,
          container: true,
          child: _paragraph(e.children ?? const [], hs),
        );
      case 'ul' || 'ol':
        if (sourcesList) {
          final pills = _sourcesList(e);
          if (pills != null) return pills;
        }
        return _nested(() => _list(e, base, 0));
      case 'blockquote':
        return _nested(() => _quote(e, base));
      case 'pre':
        return _codeBlock(e);
      case 'hr':
        return ExcludeSemantics(
          child: Container(height: 1, color: style.hairline),
        );
      case 'table':
        return _table(e);
      case 'x-details':
        return _nested(() => _details(e, base));
      case 'section' || 'div':
        return blocks(e.children ?? const [], base);
      default:
        return _paragraph([e], base);
    }
  }

  Widget _paragraph(List<md.Node> nodes, TextStyle style) {
    final spans = <InlineSpan>[];
    _inlineAll(nodes, style, spans);
    return Text.rich(TextSpan(children: spans), style: style);
  }

  Widget _quote(md.Element e, TextStyle base) {
    return Stack(
      children: [
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 3,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: style.outline,
              borderRadius: BorderRadius.circular(1.5),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 19),
          child: blocks(
            e.children ?? const [],
            base.copyWith(color: style.textMuted),
          ),
        ),
      ],
    );
  }

  Widget _details(md.Element e, TextStyle base) {
    final summary = e.attributes['summary'] ?? 'Details';
    final body = blocks(e.children ?? const [], base);
    return UiDetailsView(
      title: summary,
      initiallyOpen: e.attributes['open'] != null,
      style: style,
      body: NoNestedUiBlocks(child: body),
    );
  }

  // ----------------------------------------------------------------- lists

  static const _letters = 'abcdefghijklmnopqrstuvwxyz';

  static String _roman(int n) {
    const v = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
    const r = [
      'm',
      'cm',
      'd',
      'cd',
      'c',
      'xc',
      'l',
      'xl',
      'x',
      'ix',
      'v',
      'iv',
      'i',
    ];
    final b = StringBuffer();
    for (var i = 0; i < v.length; i++) {
      while (n >= v[i]) {
        b.write(r[i]);
        n -= v[i];
      }
    }
    return b.toString();
  }

  static String _ordinal(int n, int depth) {
    if (n < 1) return '$n.';
    switch (depth) {
      case 0:
        return '$n.';
      case 1:
        var s = '';
        var k = n;
        while (k > 0) {
          k--;
          s = _letters[k % 26] + s;
          k ~/= 26;
        }
        return '$s.';
      default:
        return '${_roman(n)}.';
    }
  }

  Widget _list(md.Element list, TextStyle base, int depth) {
    final ordered = list.tag == 'ol';
    final start = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    final items = (list.children ?? const [])
        .whereType<md.Element>()
        .where((e) => e.tag == 'li')
        .toList();
    final loose = items.any(
      (li) =>
          (li.children ?? const []).any((c) => c is md.Element && c.tag == 'p'),
    );
    final itemGap = loose ? style.looseListItemGap : style.listItemGap;
    final markerStyle = base.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    // First-line metrics, so painted markers sit on the text.
    final size = base.fontSize ?? 17;
    final scaled = _scaler.scale(size);
    final line = scaled * (base.height ?? 1.5);
    final probe = TextPainter(
      text: TextSpan(text: 'x', style: base),
      textDirection: TextDirection.ltr,
      textScaler: _scaler,
    )..layout();
    final baseline = probe.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    probe.dispose();
    final grow = (scaled / size).clamp(1.0, 1.6);

    var indent = depth == 0 ? style.listIndent : style.nestedListIndent;
    final labels = [
      for (var i = 0; i < items.length; i++)
        ordered ? _ordinal(start + i, depth) : '',
    ];
    if (ordered) {
      var widest = 0.0;
      for (final l in labels) {
        final tp = TextPainter(
          text: TextSpan(text: l, style: markerStyle),
          textDirection: TextDirection.ltr,
          textScaler: _scaler,
        )..layout();
        if (tp.width > widest) widest = tp.width;
        tp.dispose();
      }
      final box = widest > indent - 8 ? widest : indent - 8;
      indent = box + 8;
    } else if (grow > 1) {
      indent = indent * (1 + (grow - 1) * 0.5);
    }
    final markerCx = indent - 15.3 * (indent / 32).clamp(0.8, 1.6);

    final rows = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0 && itemGap > 0) rows.add(SizedBox(height: itemGap));
      final li = items[i];
      final children = List<md.Node>.of(li.children ?? const []);
      // Task list: the parser puts an <input type=checkbox> first, either in
      // the item or in its first paragraph.
      // Cached nodes are re-rendered on fade frames, so never mutate them.
      bool? checked;
      bool isBox(md.Node n) => n is md.Element && n.tag == 'input';
      if (children.isNotEmpty && isBox(children.first)) {
        checked =
            (children.first as md.Element).attributes['checked'] == 'true';
        children.removeAt(0);
      } else if (children.isNotEmpty &&
          children.first is md.Element &&
          (children.first as md.Element).tag == 'p') {
        final p = children.first as md.Element;
        final pc = p.children ?? const <md.Node>[];
        if (pc.isNotEmpty && isBox(pc.first)) {
          checked = (pc.first as md.Element).attributes['checked'] == 'true';
          children[0] = md.Element('p', pc.sublist(1));
        }
      }

      final a = _alphaHere();
      final Widget marker;
      if (checked != null) {
        marker = Semantics(
          checked: checked,
          label: checked ? 'Done' : 'Not done',
          child: CustomPaint(
            size: Size(indent, line),
            painter: _CheckboxPainter(
              cx: markerCx,
              size: 18 * grow,
              checked: checked,
              outline: _fadeColor(style.textMuted, a),
              fill: _fadeColor(style.text, a),
              tick: _fadeColor(style.background, a),
            ),
          ),
        );
      } else if (ordered) {
        marker = SelectionContainer.disabled(
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              labels[i],
              textAlign: TextAlign.right,
              maxLines: 1,
              softWrap: false,
              style: _faded(markerStyle, a),
            ),
          ),
        );
      } else {
        marker = ExcludeSemantics(
          child: CustomPaint(
            size: Size(indent, line),
            painter: _BulletPainter(
              cx: markerCx,
              cy: baseline - 0.26 * scaled,
              diameter: style.bulletSize * grow,
              kind: depth.clamp(0, 2),
              color: _fadeColor(style.text, a),
            ),
          ),
        );
      }
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: indent, child: marker),
            Expanded(child: _itemBody(children, base, depth, itemGap)),
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  Widget _itemBody(List<md.Node> nodes, TextStyle base, int depth, double gap) {
    final parts = <Widget>[];
    final inline = <md.Node>[];
    void flush() {
      if (inline.isEmpty) return;
      parts.add(_paragraph(List.of(inline), base));
      inline.clear();
    }

    for (final n in nodes) {
      final isBlock = n is md.Element && _blockTags.contains(n.tag);
      if (!isBlock) {
        inline.add(n);
        continue;
      }
      flush();
      if (n.tag == 'ul' || n.tag == 'ol') {
        parts.add(_list(n, base, depth + 1));
      } else {
        parts.add(_block(n, base));
      }
    }
    flush();
    if (parts.isEmpty) return const SizedBox.shrink();
    if (parts.length == 1) return parts.single;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < parts.length; i++) ...[
          if (i > 0 && gap > 0) SizedBox(height: gap),
          parts[i],
        ],
      ],
    );
  }

  // -------------------------------------------------------------- code

  Widget _codeBlock(md.Element pre) {
    final codeEl = (pre.children ?? const [])
        .whereType<md.Element>()
        .where((e) => e.tag == 'code')
        .firstOrNull;
    var lang = codeEl?.attributes['class'] ?? '';
    if (lang.startsWith('language-')) lang = lang.substring(9);
    var code = (codeEl ?? pre).textContent;
    final start = _offset;
    _offset += code.length;
    // The parser keeps the newline before the closing fence.
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    if (lang == hermesHtmlInfo) {
      // Safe HTML, drawn natively once the fence is complete.
      return complete
          ? HermesHtml(source: code, style: style)
          : UiPlaceholder(type: 'html', style: style);
    }
    if (lang == hermesArtifactInfo &&
        (!complete || Artifact.parse(code) != null)) {
      return ArtifactCard(body: code, complete: complete, style: style);
    }
    if (lang == openUiInfo) {
      // OpenUI Lang: rendered natively while it streams.
      return OpenUiBlock(source: code, complete: complete, style: style);
    }
    if (lang == hermesUiInfo) {
      return HermesUiBlock(
        source: code,
        complete: complete,
        ordinal: uiOrdinal + _uiCount++,
        style: style,
        footnotes: footnotes,
      );
    }
    InlineSpan? span;
    if (fade != null) {
      span = TextSpan(children: _fadedRuns(code, start, style.code));
    }
    return CodeBlock(code: code, language: lang, style: style, span: span);
  }

  // -------------------------------------------------------------- tables

  static final _numeric = RegExp(
    r'^[\s(]*[-−+]?[$€£¥₹]?\s?[-−+]?\d[\d,. ]*(%|[kKmMbB]|\s?[A-Z]{3})?\)?\s*$',
  );

  Widget _table(md.Element table) {
    final header = <InlineSpan>[];
    final rows = <List<InlineSpan>>[];
    final align = <String?>[];
    final bodyText = <List<String>>[];
    for (final section
        in (table.children ?? const []).whereType<md.Element>()) {
      for (final tr in (section.children ?? const []).whereType<md.Element>()) {
        final cells = <InlineSpan>[];
        final texts = <String>[];
        for (final c in (tr.children ?? const []).whereType<md.Element>()) {
          final isHead = c.tag == 'th';
          if (isHead) {
            final a = c.attributes['align'];
            align.add(a == null || a == 'null' ? null : a);
          }
          final spans = <InlineSpan>[];
          _inlineAll(
            c.children ?? const <md.Node>[],
            isHead ? style.tableHeader : style.table,
            spans,
          );
          cells.add(TextSpan(children: spans));
          texts.add(c.textContent.trim());
        }
        if (section.tag == 'thead') {
          header.addAll(cells);
        } else {
          rows.add(cells);
          bodyText.add(texts);
        }
      }
    }
    // Columns where every non-empty body cell is a number or an amount.
    final cols = align.length;
    final numeric = [
      for (var c = 0; c < cols; c++)
        () {
          var any = false;
          for (final r in bodyText) {
            if (c >= r.length || r[c].isEmpty || r[c] == '—' || r[c] == '-') {
              continue;
            }
            if (!_numeric.hasMatch(r[c])) return false;
            any = true;
          }
          return any;
        }(),
    ];
    return MdTable(
      header: header,
      rows: rows,
      alignments: align,
      numeric: numeric,
      style: style,
      bleed: _nest == 0 ? style.tableBleed : 0,
    );
  }

  // -------------------------------------------------------------- images

  /// A paragraph of only images (each optionally linked to its source page,
  /// with footnote citations allowed) as an image card or gallery, loaded
  /// through the bridge. Null without a loader, or when the paragraph has
  /// other text: those images stay pills.
  Widget? _imageParagraph(md.Element p, TextStyle base) {
    final loader = MarkdownImageScope.of(context);
    if (loader == null) return null;
    final images = <MdImage>[];
    final refs = <md.Node>[];
    for (final k in p.children ?? const <md.Node>[]) {
      if (k is md.Text) {
        if (k.text.trim().isEmpty) continue;
        return null;
      }
      final e = k as md.Element;
      if (e.tag == 'br') continue;
      if (e.tag == 'fnref') {
        refs.add(e);
        continue;
      }
      final image = _imageOf(e);
      if (image == null) return null;
      if (!images.any((i) => i.src == image.src)) images.add(image);
    }
    if (images.isEmpty) return null;
    final start = _offset;
    final a = _alphaHere();
    final gallery = MdImageGallery(
      images: images,
      loader: loader,
      style: style,
      onLinkTap: onLinkTap,
      opacity: a,
    );
    Widget out = gallery;
    if (refs.isNotEmpty) {
      out = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [gallery, _paragraph(refs, base)],
      );
    }
    _offset = start + p.textContent.length;
    return out;
  }

  MdImage? _imageOf(md.Element e) {
    if (e.tag == 'img') return _mdImage(e, null);
    if (e.tag != 'a') return null;
    final kids = (e.children ?? const <md.Node>[])
        .where((n) => !(n is md.Text && n.text.trim().isEmpty))
        .toList();
    if (kids.length != 1) return null;
    final only = kids.single;
    if (only is! md.Element || only.tag != 'img') return null;
    return _mdImage(only, e.attributes['href']);
  }

  static bool _isWeb(String? href) {
    final u = href == null ? null : safeLink(href);
    return u != null && (u.scheme == 'https' || u.scheme == 'http');
  }

  MdImage? _mdImage(md.Element img, String? source) {
    final src = img.attributes['src'] ?? '';
    if (!_isWeb(src)) return null;
    return MdImage(
      src: src,
      alt: img.attributes['alt'] ?? '',
      title: img.attributes['title'],
      source: _isWeb(source) && source != src ? source : null,
    );
  }

  // ------------------------------------------------------------- sources

  /// "Sources: [a](u), [b](u)" as a label and a wrap of pills.
  Widget? _sourcesParagraph(md.Element p) {
    final kids = p.children ?? const [];
    if (kids.isEmpty || !_sourcesPrefix.hasMatch(p.textContent)) return null;
    final links = <md.Element>[];
    var labelDone = false;
    for (final k in kids) {
      if (k is md.Element && k.tag == 'a') {
        if (!labelDone) return null;
        links.add(k);
      } else {
        var t = k.textContent;
        if (!labelDone) {
          final m = _sourcesPrefix.firstMatch(t);
          if (m == null) {
            // The label may be wrapped in ** **.
            if (k is md.Element && _sourcesPrefix.hasMatch(t)) {
              labelDone = true;
              t = t.replaceFirst(_sourcesPrefix, '');
            } else {
              return null;
            }
          } else {
            labelDone = true;
            t = t.substring(m.end);
          }
        }
        if (!_punctOnly.hasMatch(t)) return null;
      }
    }
    if (links.isEmpty ||
        links.any((l) => safeLink(l.attributes['href'] ?? '') == null)) {
      return null;
    }
    final a = _alphaHere();
    final label = _sourcesPrefix.firstMatch(p.textContent)![1]!;
    _skip(p);
    return _pillWrap(links, label: '$label:', alpha: a);
  }

  /// A list whose every item is just a link, following a "Sources:" line.
  Widget? _sourcesList(md.Element list) {
    final links = <md.Element>[];
    for (final li in (list.children ?? const []).whereType<md.Element>()) {
      final flat = <md.Node>[];
      for (final c in li.children ?? const <md.Node>[]) {
        if (c is md.Element && c.tag == 'p') {
          flat.addAll(c.children ?? const []);
        } else {
          flat.add(c);
        }
      }
      final ls = flat
          .whereType<md.Element>()
          .where((e) => e.tag == 'a')
          .toList();
      if (ls.length != 1 ||
          safeLink(ls.single.attributes['href'] ?? '') == null) {
        return null;
      }
      for (final n in flat) {
        if (n == ls.single) continue;
        if (n is md.Element && n.tag != 'a') return null;
        if (!_punctOnly.hasMatch(n.textContent)) return null;
      }
      links.add(ls.single);
    }
    if (links.isEmpty) return null;
    final a = _alphaHere();
    _skip(list);
    return _pillWrap(links, alpha: a);
  }

  Widget _pillWrap(List<md.Element> links, {String? label, double alpha = 1}) {
    return Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (label != null)
          Text(label, style: _faded(style.label.hermesWeight(600), alpha)),
        for (final l in links)
          Builder(
            builder: (context) {
              final href = l.attributes['href']!;
              final uri = safeLink(href)!;
              final host = linkHost(uri);
              return SourcePill(
                label: host,
                semanticsLabel: 'Source: $host',
                style: style,
                opacity: alpha,
                onTap: () => onLinkTap(href),
              );
            },
          ),
      ],
    );
  }

  // -------------------------------------------------------------- inline

  /// Renders [nodes] in order, merging runs of footnote references into one
  /// source chip.
  void _inlineAll(
    List<md.Node> nodes,
    TextStyle s,
    List<InlineSpan> out, {
    GestureRecognizer? link,
  }) {
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      if (n is md.Element && n.tag == 'fnref') {
        final labels = <String>[n.attributes['label']!];
        while (i + 1 < nodes.length) {
          final next = nodes[i + 1];
          if (next is md.Element && next.tag == 'fnref') {
            labels.add(next.attributes['label']!);
            i++;
          } else {
            break;
          }
        }
        out.add(_sourceChip(labels, s, nodes, i - labels.length));
        continue;
      }
      _inline(n, s, out, link: link);
    }
  }

  InlineSpan _sourceChip(
    List<String> labels,
    TextStyle s,
    List<md.Node> siblings,
    int before,
  ) {
    final seen = <String>{};
    final sources = [
      for (final l in labels)
        if (seen.add(l)) footnotes[l],
    ];
    final prevText = before >= 0 ? siblings[before].textContent : '';
    final space = prevText.isEmpty || prevText.endsWith(' ') ? 0.0 : 6.0;
    final small = (s.fontSize ?? 17) < 16;
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: EdgeInsets.only(left: space),
        // WidgetSpan children are scaled with the text already.
        child: MediaQuery.withNoTextScaling(
          child: SourceChip(
            sources: sources,
            onLinkTap: onLinkTap,
            style: style,
            small: small,
            opacity: _alphaHere(),
          ),
        ),
      ),
    );
  }

  void _inline(
    md.Node n,
    TextStyle s,
    List<InlineSpan> out, {
    GestureRecognizer? link,
  }) {
    if (n is md.Text) {
      // Soft line breaks render as spaces (same length, so offsets hold).
      _emit(n.text.replaceAll('\n', ' '), s, out, link);
      return;
    }
    final e = n as md.Element;
    final kids = e.children ?? const <md.Node>[];
    void all(TextStyle st) => _inlineAll(kids, st, out, link: link);
    switch (e.tag) {
      case 'strong':
        final w = s.hermesWght;
        final strong = style.strongWeight;
        all(s.hermesWeight(w > strong ? w : strong));
      case 'em':
        all(s.hermesOblique());
      case 'del':
        all(
          s.copyWith(
            decoration: TextDecoration.combine([
              if (s.decoration != null) s.decoration!,
              TextDecoration.lineThrough,
            ]),
          ),
        );
      case 'u':
        all(
          s.copyWith(
            decoration: TextDecoration.combine([
              if (s.decoration != null) s.decoration!,
              TextDecoration.underline,
            ]),
            decorationColor: s.color,
          ),
        );
      case 'small':
        all(
          s
              .hermesSize(
                style.caption.fontSize ?? 14,
                line:
                    (style.caption.fontSize ?? 14) *
                    (style.caption.height ?? 20 / 14),
              )
              .copyWith(color: style.textMuted),
        );
      case 'mark':
        all(s.copyWith(backgroundColor: style.accentSoft));
      case 'tone-bad':
        all(s.copyWith(color: style.danger, decorationColor: style.danger));
      case 'tone-good':
        all(s.copyWith(color: style.success, decorationColor: style.success));
      case 'tone-warn':
        all(s.copyWith(color: style.warning, decorationColor: style.warning));
      case 'tone-accent':
        final accent = HermesTokens.of(context).accent;
        all(s.copyWith(color: accent, decorationColor: accent));
      case 'badge-good' ||
          'badge-warn' ||
          'badge-bad' ||
          'badge-info' ||
          'badge-neutral':
        out.add(_badge(e.textContent.replaceAll('\n', ' '), e.tag));
      case 'sup' || 'sub':
        final size = (s.fontSize ?? 17) * 0.75;
        all(s.hermesSize(size, line: size * 1.2));
      case 'code':
        out.add(_inlineCode(e.textContent.replaceAll('\n', ' '), s));
      case 'kbd':
        out.add(_inlineCode(e.textContent.replaceAll('\n', ' '), s, kbd: true));
      case 'br':
        out.add(const TextSpan(text: '\n'));
      case 'a':
        _link(e, s, out);
      case 'img':
        out.add(_imagePill(e));
      case 'input' || 'fnref':
        break;
      default:
        all(s);
    }
  }

  /// Emits [text] with the fade applied per run.
  void _emit(
    String text,
    TextStyle s,
    List<InlineSpan> out,
    GestureRecognizer? link,
  ) {
    if (text.isEmpty) return;
    final start = _offset;
    _offset += text.length;
    if (fade == null) {
      out.add(TextSpan(text: text, style: s, recognizer: link));
      return;
    }
    out.addAll(_fadedRuns(text, start, s, link));
  }

  List<InlineSpan> _fadedRuns(
    String text,
    int start,
    TextStyle s, [
    GestureRecognizer? link,
  ]) {
    final f = fade!;
    final out = <InlineSpan>[];
    var i = 0;
    while (i < text.length) {
      final at = start + i;
      final a = f.alphaAt(at);
      final next = f.nextBoundary(at);
      var end = next == null
          ? text.length
          : (next - start).clamp(i + 1, text.length);
      // Never split a surrogate pair.
      if (end < text.length && (text.codeUnitAt(end) & 0xFC00) == 0xDC00) {
        end++;
      }
      out.add(
        TextSpan(
          text: text.substring(i, end),
          style: _faded(s, a),
          recognizer: link,
        ),
      );
      i = end;
    }
    return out;
  }

  /// Inline code (`surfaceHigh` chip) or a `<kbd>` key (1 dp outline).
  InlineSpan _inlineCode(String code, TextStyle around, {bool kbd = false}) {
    final a = _alphaHere();
    _offset += code.length;
    final cs = style.inlineCode.copyWith(
      color: _fadeColor(around.color ?? style.text, a),
    );
    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 1.5, horizontal: 5),
        decoration: BoxDecoration(
          color: kbd ? null : _fadeColor(style.surfaceHigh, a),
          border: kbd ? Border.all(color: _fadeColor(style.outline, a)) : null,
          borderRadius: BorderRadius.circular(style.inlineCodeRadius),
        ),
        // WidgetSpan children are already scaled with the text.
        child: Text(code, style: cs, textScaler: TextScaler.noScaling),
      ),
    );
  }

  /// A hermes-html badge: a small outlined pill in its state colour.
  InlineSpan _badge(String text, String tag) {
    final a = _alphaHere();
    _offset += text.length;
    final c = switch (tag) {
      'badge-good' => style.success,
      'badge-warn' => style.warning,
      'badge-bad' => style.danger,
      'badge-info' => HermesTokens.of(context).accent,
      _ => style.textMuted,
    };
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        decoration: ShapeDecoration(
          shape: StadiumBorder(
            side: BorderSide(color: _fadeColor(c.withValues(alpha: 0.55), a)),
          ),
        ),
        // WidgetSpan children are already scaled with the text.
        child: Text(
          text,
          style: style.caption
              .hermesWeight(600)
              .copyWith(color: _fadeColor(c, a)),
          textScaler: TextScaler.noScaling,
        ),
      ),
    );
  }

  /// "host/path" shortened to [max] characters with "…" in the middle.
  static String shortUrl(String href, {int max = 40}) {
    final u = Uri.tryParse(href);
    var t = href;
    if (u != null && u.host.isNotEmpty) {
      final host = u.host.startsWith('www.') ? u.host.substring(4) : u.host;
      final path = u.path == '/' ? '' : u.path;
      t = '$host$path${u.hasQuery ? '?${u.query}' : ''}';
    } else if (u != null && u.scheme == 'mailto') {
      t = u.path;
    }
    if (t.length <= max) return t;
    final head = (max - 1) * 2 ~/ 3;
    final tail = max - 1 - head;
    return '${t.substring(0, head)}…${t.substring(t.length - tail)}';
  }

  void _link(md.Element e, TextStyle s, List<InlineSpan> out) {
    final href = e.attributes['href'] ?? '';
    final safe = safeLink(href) != null;
    GestureRecognizer? rec;
    if (safe) {
      rec = TapGestureRecognizer()..onTap = () => onLinkTap(href);
      recognizers.add(rec);
    }
    final color = s.color ?? style.text;
    final ls = s.copyWith(
      color: color,
      decoration: TextDecoration.underline,
      decorationStyle: TextDecorationStyle.solid,
      decorationColor: color.withValues(alpha: color.a * 0.35),
      decorationThickness: 1,
    );
    final kids = e.children ?? const <md.Node>[];
    final text = e.textContent;
    final auto =
        safe &&
        kids.length == 1 &&
        kids.single is md.Text &&
        (text == href || 'mailto:$text' == href || 'http://$text' == href);
    if (auto) {
      // Bare URLs show the host and path, shortened.
      final a = _alphaHere();
      _offset += text.length;
      out.add(
        TextSpan(
          text: shortUrl(href),
          style: _faded(ls, a),
          recognizer: rec,
          semanticsLabel: text,
        ),
      );
      return;
    }
    _inlineAll(kids, safe ? ls : s, out, link: rec);
  }

  InlineSpan _imagePill(md.Element e) {
    final alt = (e.attributes['alt'] ?? '').trim();
    final a = _alphaHere();
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: MediaQuery.withNoTextScaling(
        child: SourcePill(
          label: alt.isEmpty ? '[image]' : '[image: $alt]',
          semanticsLabel: alt.isEmpty ? 'Image' : 'Image: $alt',
          icon: Icons.image_outlined,
          style: style,
          opacity: a,
          onTap: null,
        ),
      ),
    );
  }
}

/// A list bullet: level 1 a filled dot, level 2 a ring (1.5 dp stroke),
/// level 3+ a small rounded square; centred at ([cx], [cy]).
class _BulletPainter extends CustomPainter {
  _BulletPainter({
    required this.cx,
    required this.cy,
    required this.diameter,
    required this.kind,
    required this.color,
  });

  final double cx, cy, diameter;
  final int kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(cx, cy);
    final p = Paint()
      ..color = color
      ..isAntiAlias = true;
    switch (kind) {
      case 0:
        canvas.drawCircle(c, diameter / 2, p);
      case 1:
        canvas.drawCircle(
          c,
          diameter / 2 - 0.75,
          p
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      default:
        final d = diameter * 5 / 6;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: c, width: d, height: d),
            const Radius.circular(1),
          ),
          p,
        );
    }
  }

  @override
  bool shouldRepaint(_BulletPainter old) =>
      old.cx != cx ||
      old.cy != cy ||
      old.diameter != diameter ||
      old.kind != kind ||
      old.color != color;
}

/// A task-list box: an 18 dp rounded outline, or filled with a tick.
class _CheckboxPainter extends CustomPainter {
  _CheckboxPainter({
    required this.cx,
    required this.size,
    required this.checked,
    required this.outline,
    required this.fill,
    required this.tick,
  });

  final double cx, size;
  final bool checked;
  final Color outline, fill, tick;

  @override
  void paint(Canvas canvas, Size s) {
    final r = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx, s.height / 2),
        width: size,
        height: size,
      ),
      Radius.circular(4 * size / 18),
    );
    if (!checked) {
      canvas.drawRRect(
        r.deflate(0.75),
        Paint()
          ..color = outline
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      return;
    }
    canvas.drawRRect(r, Paint()..color = fill);
    final k = size / 18;
    final o = r.outerRect.topLeft;
    final path = Path()
      ..moveTo(o.dx + 4.5 * k, o.dy + 9.5 * k)
      ..lineTo(o.dx + 7.5 * k, o.dy + 12.5 * k)
      ..lineTo(o.dx + 13.5 * k, o.dy + 5.5 * k);
    canvas.drawPath(
      path,
      Paint()
        ..color = tick
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * k
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CheckboxPainter old) =>
      old.cx != cx ||
      old.size != size ||
      old.checked != checked ||
      old.outline != outline ||
      old.fill != fill ||
      old.tick != tick;
}
