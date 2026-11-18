/// Safe HTML for replies (round 4): a ```` ```hermes-html ```` fence, or a
/// hermes-ui `{"type": "html", "html": "…"}` block, drawn natively from a
/// strict allowlist. No WebView, no script, no remote styles.
///
/// How: `package:html` parses the fragment; [sanitizeHtml] keeps only the
/// allowed tags, attributes and CSS properties ([HtmlLimits] bound size and
/// depth) into an [HNode] tree; [HermesHtml] draws it. Layout containers
/// (`div`, `section`, `figure`) become native rows, columns and grids; all
/// text content (paragraphs, headings, lists, tables, links, images,
/// `details`) is turned into markdown and drawn by the reply's own
/// markdown renderer, so it looks exactly like the rest of the reply (same
/// fonts, sizes, colours, spacing; images through the bridge, links through
/// the confirm sheet).
///
/// The user's rule: HTML brings no backgrounds or colours of its own. A
/// text `color` that is red, green, amber or blue-ish becomes the theme's
/// danger, success, warning or accent colour (inherited like CSS); any
/// other colour is the default text colour. Backgrounds are ignored except
/// a tiny status dot (an empty element at most 16 px with a background).
/// A `border` becomes the theme's light 1 px outline.
///
/// Round 7 adds declarative components chosen by `class` (cards, stats,
/// badges, bars, timelines, pros/cons, callouts, tabs, galleries, heroes),
/// `dl` spec sheets, `details` accordions and `<button data-send>` (it only
/// sends that text as the user's message). They are drawn natively in
/// `html_components.dart`; unknown classes are dropped, so the content
/// still shows as plain layout. A fragment of only paragraphs, emphasis,
/// headings and plain lists is drawn exactly like the reply's markdown.
library;

import 'dart:math' as math;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:material_ui/material_ui.dart';

import '../markdown/hermes_markdown.dart';
import '../markdown/md_images.dart' show MdImage, showMdImageViewer;
import '../theme/motion.dart';
import 'scope.dart';
import 'ui_dashboard.dart' show StateDot, dashTone;
import 'ui_entities.dart' show UiRemoteImage;
import 'ui_model.dart' show UiCallout, UiCard, UiTone;
import 'ui_widgets.dart' show UiCalloutView, UiCardsView, UiDetailsView, UiPill;

part 'html_components.dart';

/// Size limits; over them the rest is cut (and [HtmlDoc.truncated] set).
abstract final class HtmlLimits {
  static const int maxBytes = 32 * 1024;
  static const int maxNodes = 600;
  static const int maxDepth = 16;
  static const int maxImages = 8;
  static const double maxSpace = 32;
  static const double maxRadius = 24;
  static const int maxColumns = 4;

  /// A `data-send` message; a tab label.
  static const int maxSend = 300;
  static const int maxTabLabel = 40;
  static const int maxTabs = 8;
}

/// Tags drawn. Others are unwrapped (their text kept), except [droppedTags].
const allowedTags = {
  'div', 'section', 'p', 'h1', 'h2', 'h3', 'h4', 'span', 'strong', 'b', //
  'em', 'i', 'ul', 'ol', 'li', 'table', 'thead', 'tbody', 'tfoot', 'tr',
  'th', 'td', 'img', 'a', 'figure', 'figcaption', 'small', 'br', 'hr',
  'details', 'summary', 'button', 'progress', 'dl', 'dt', 'dd',
};

/// Class names the app understands; every other class is dropped, so an
/// unknown component degrades to its plain content.
const htmlClasses = {
  'cards', 'card', 'grid', 'cols-2', 'cols-3', 'cols-4', 'stats', 'stat', //
  'hero', 'gallery', 'tabs', 'timeline', 'pros', 'cons', 'callout', 'bar',
  'badge', 'button', 'meta', 'muted', 'label', 'value', 'sub', 'time',
  ...htmlToneClasses,
};

/// Tone classes (badges, bars, callouts, timeline dots, stats, text).
const htmlToneClasses = {
  'good', 'warn', 'bad', 'info', 'tip', 'success', 'warning', 'danger', //
  'neutral',
};

/// The tone a set of classes names, or null.
UiTone? htmlTone(Set<String> classes) {
  for (final c in classes) {
    switch (c) {
      case 'good' || 'success':
        return UiTone.good;
      case 'warn' || 'warning':
        return UiTone.warn;
      case 'bad' || 'danger':
        return UiTone.bad;
      case 'tip':
        return UiTone.tip;
      case 'info':
        return UiTone.info;
      case 'neutral':
        return UiTone.neutral;
    }
  }
  return null;
}

/// Tags removed together with everything inside them.
const droppedTags = {
  'script', 'style', 'iframe', 'frame', 'frameset', 'object', 'embed', //
  'applet', 'form', 'input', 'select', 'option', 'textarea',
  'svg', 'math', 'template', 'noscript', 'link', 'meta', 'base', 'head',
  'title', 'canvas', 'video', 'audio', 'source', 'track', 'picture',
  'portal', 'dialog', 'slot',
};

enum HDisplay { block, flex, grid }

/// The allowed part of an element's `style`, already clamped.
@immutable
class HStyle {
  const HStyle({
    this.display = HDisplay.block,
    this.row = true,
    this.wrap = false,
    this.gap = 0,
    this.align,
    this.justify,
    this.columns = 0,
    this.flex = 0,
    this.margin = EdgeInsets.zero,
    this.padding = EdgeInsets.zero,
    this.radius = 0,
    this.border = false,
    this.textAlign,
    this.bold = false,
    this.size = 0,
    this.dot,
    this.hidden = false,
    this.width,
    this.height,
    this.tone,
  });

  final HDisplay display;

  /// flex-direction: row (true) or column.
  final bool row;
  final bool wrap;
  final double gap;

  /// align-items: start, center, end, stretch.
  final String? align;

  /// justify-content: start, center, end, space-between, space-around.
  final String? justify;

  /// grid-template-columns count.
  final int columns;
  final int flex;
  final EdgeInsets margin;
  final EdgeInsets padding;
  final double radius;
  final bool border;

  /// left, center, right.
  final String? textAlign;
  final bool bold;

  /// −1 small, 0 normal, 1 large, 2 larger.
  final int size;

  /// A status dot's tone (an empty element with a background).
  final UiTone? dot;
  final bool hidden;

  /// An image's size in dp (≤ 400), when set.
  final double? width, height;

  /// The text colour as a theme tone (CSS `color`): bad, good, warn or
  /// info (the accent). Other colours: null, the default text colour.
  final UiTone? tone;

  static const none = HStyle();
}

/// A sanitised node: text, or an allowed element.
sealed class HNode {
  const HNode();
}

class HText extends HNode {
  const HText(this.text, {this.tone});
  final String text;

  /// The colour it inherits from its elements' CSS `color`, as a tone.
  final UiTone? tone;
}

class HElement extends HNode {
  const HElement(
    this.tag, {
    this.attrs = const {},
    this.style = HStyle.none,
    this.children = const [],
  });
  final String tag;

  /// Only `href` (a), `src`/`alt` (img), `open` (details), `class` (known
  /// names only), `data-tab` (tab panes), `data-send` (button),
  /// `data-value`/`value` and `data-max`/`max` (bars, progress).
  final Map<String, String> attrs;
  final HStyle style;
  final List<HNode> children;

  /// The known classes on this element.
  Set<String> get classes {
    final c = attrs['class'];
    return c == null || c.isEmpty ? const {} : c.split(' ').toSet();
  }

  bool has(String cls) => classes.contains(cls);

  String get text =>
      children.map((c) => c is HText ? c.text : (c as HElement).text).join();
}

class HtmlDoc {
  const HtmlDoc(this.nodes, {this.truncated = false, this.dropped = 0});
  final List<HNode> nodes;
  final bool truncated;

  /// Elements or attributes removed (for tests and debugging).
  final int dropped;

  /// The readable text (for Read aloud, Share and screen readers).
  String get plainText => nodes
      .map((n) => n is HText ? n.text : (n as HElement).text)
      .join(' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

// ------------------------------------------------------------- sanitise

final Map<String, HtmlDoc> _memo = {};

/// Parses and sanitises [source]. Never throws; memoised.
HtmlDoc sanitizeHtml(String source) {
  final hit = _memo[source];
  if (hit != null) return hit;
  final doc = _Sanitizer().run(source);
  if (_memo.length > 32) _memo.remove(_memo.keys.first);
  return _memo[source] = doc;
}

class _Sanitizer {
  int nodes = 0;
  int images = 0;
  int dropped = 0;
  bool truncated = false;

  HtmlDoc run(String source) {
    var src = source;
    if (src.length > HtmlLimits.maxBytes) {
      src = src.substring(0, HtmlLimits.maxBytes);
      truncated = true;
    }
    final frag = html.parseFragment(src);
    final out = _pairProsCons(_children(frag.nodes, 0, null));
    return HtmlDoc(out, truncated: truncated, dropped: dropped);
  }

  List<HNode> _children(List<dom.Node> list, int depth, UiTone? tone) {
    final out = <HNode>[];
    for (final n in list) {
      if (nodes >= HtmlLimits.maxNodes) {
        truncated = true;
        break;
      }
      out.addAll(_node(n, depth, tone));
    }
    return out;
  }

  List<HNode> _node(dom.Node n, int depth, UiTone? tone) {
    if (n is dom.Text) {
      nodes++;
      return [HText(n.text, tone: tone)];
    }
    if (n is! dom.Element) {
      dropped++; // comments, processing instructions
      return const [];
    }
    final tag = n.localName?.toLowerCase() ?? '';
    if (droppedTags.contains(tag) ||
        n.namespaceUri != null &&
            n.namespaceUri != 'http://www.w3.org/1999/xhtml') {
      dropped++;
      return const [];
    }
    if (depth >= HtmlLimits.maxDepth) {
      truncated = true;
      return const [];
    }
    if (!allowedTags.contains(tag)) {
      // Unknown: keep the text inside, drop the tag.
      dropped++;
      return _children(n.nodes, depth + 1, tone);
    }
    nodes++;
    final attrs = <String, String>{};
    for (final e in n.attributes.entries) {
      final k = '${e.key}'.toLowerCase();
      var v = e.value.trim();
      if (k == 'class') {
        v = cleanClasses(v);
      } else if (k == 'data-send') {
        v = cleanText(v, HtmlLimits.maxSend);
      } else if (k == 'data-tab') {
        v = cleanText(v, HtmlLimits.maxTabLabel);
      }
      final keep = switch (k) {
        'href' => tag == 'a' && safeLink(v) != null && _scheme(v),
        'src' => tag == 'img' && _httpUrl(v),
        'alt' => tag == 'img',
        'width' || 'height' => tag == 'img' && _len(v, max: 400) != null,
        'open' => tag == 'details',
        'class' => v.isNotEmpty,
        'data-send' => tag == 'button' && v.isNotEmpty,
        'data-tab' => (tag == 'section' || tag == 'div') && v.isNotEmpty,
        'value' || 'max' => tag == 'progress' && _number(v) != null,
        'data-value' || 'data-max' => _number(v) != null,
        'style' => false, // parsed below
        _ => false,
      };
      if (keep) {
        attrs[k] = v;
      } else if (k != 'style') {
        dropped++;
      }
    }
    // A button only sends a message; without one it is dropped. A progress
    // bar needs a value.
    if (tag == 'button' && attrs['data-send'] == null ||
        tag == 'progress' && attrs['value'] == null) {
      dropped++;
      return const [];
    }
    if (tag == 'img') {
      if (!attrs.containsKey('src') || images >= HtmlLimits.maxImages) {
        dropped++;
        return const [];
      }
      images++;
    }
    final sizes = [
      for (final k in ['width', 'height'])
        if (attrs[k] != null) '$k:${attrs.remove(k)}px',
    ].join(';');
    final classes = (attrs['class'] ?? '').split(' ').toSet()..remove('');
    final style = parseCss(
      '${_classCss(tag, classes)};$sizes;${n.attributes['style'] ?? ''}',
      empty: !_hasContent(n),
    );
    if (style.hidden) return const [];
    var children = _children(n.nodes, depth + 1, style.tone ?? tone);
    if (tag == 'figure') children = _figure(children);
    if (style.display == HDisplay.block) children = _pairProsCons(children);
    var name = tag == 'b' ? 'strong' : (tag == 'i' ? 'em' : tag);
    // A badge is inline whatever tag carries it.
    if (classes.contains('badge') && const {'div', 'p'}.contains(name)) {
      name = 'span';
    }
    return [HElement(name, attrs: attrs, style: style, children: children)];
  }

  /// The layout and text style a class implies; the element's own `style`
  /// comes after it, so it wins.
  static String _classCss(String tag, Set<String> c) {
    if (c.isEmpty) return '';
    final b = StringBuffer();
    final cols = c.contains('cols-4')
        ? 4
        : c.contains('cols-3')
        ? 3
        : c.contains('cols-2')
        ? 2
        : 0;
    if (c.contains('cards') || c.contains('grid') || cols > 0) {
      b.write(
        'display:grid;grid-template-columns:repeat(${cols == 0 ? 2 : cols},1fr);'
        'gap:12px;',
      );
    }
    if (c.any(const {'meta', 'muted', 'sub', 'label', 'time'}.contains)) {
      b.write('font-size:small;');
    }
    if (c.contains('value')) b.write('font-weight:700;');
    // Tone classes colour plain text; components use them for their state.
    const text = {'span', 'strong', 'b', 'em', 'i', 'small', 'p'};
    final t = htmlTone(c);
    if (t != null && text.contains(tag) && !c.contains('badge')) {
      b.write(switch (t) {
        UiTone.good => 'color:green;',
        UiTone.bad => 'color:red;',
        UiTone.warn || UiTone.tip => 'color:orange;',
        UiTone.info => 'color:blue;',
        UiTone.neutral => '',
      });
    }
    return b.toString();
  }

  /// A `pros` list next to a `cons` list (either order) share a two-column
  /// grid, which falls back to one column when narrow.
  static List<HNode> _pairProsCons(List<HNode> kids) {
    bool side(HNode n) => n is HElement && (n.has('pros') || n.has('cons'));
    final idx = [
      for (final (i, k) in kids.indexed)
        if (k is HElement || (k as HText).text.trim().isNotEmpty) i,
    ];
    var changed = false;
    final out = <HNode>[];
    var skipUntil = -1;
    for (final (j, i) in idx.indexed) {
      if (i <= skipUntil) continue;
      final a = kids[i];
      final next = j + 1 < idx.length ? kids[idx[j + 1]] : null;
      if (side(a) &&
          next != null &&
          side(next) &&
          (a as HElement).has('pros') != (next as HElement).has('pros')) {
        out.add(
          HElement(
            'div',
            attrs: const {'class': 'grid cols-2'},
            style: parseCss(
              'display:grid;grid-template-columns:repeat(2,1fr);gap:16px',
            ),
            children: [a, next],
          ),
        );
        skipUntil = idx[j + 1];
        changed = true;
      } else {
        out.add(a);
      }
    }
    return changed ? out : kids;
  }

  /// A figure's caption becomes its image's caption (the markdown image
  /// shows its alt text under the picture), so it is not said twice.
  static List<HNode> _figure(List<HNode> kids) {
    final img = kids.whereType<HElement>().where((e) => e.tag == 'img');
    final cap = kids.whereType<HElement>().where((e) => e.tag == 'figcaption');
    if (img.length != 1 || cap.length != 1) return kids;
    final text = cap.single.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return kids;
    final i = img.single;
    final merged = HElement(
      'img',
      attrs: {...i.attrs, 'alt': text},
      style: i.style,
    );
    return [
      for (final k in kids)
        if (identical(k, i)) merged else if (!identical(k, cap.single)) k,
    ];
  }

  static bool _hasContent(dom.Element e) =>
      e.text.trim().isNotEmpty || e.querySelector('img') != null;

  static bool _scheme(String v) {
    final u = Uri.tryParse(v);
    return u != null &&
        ((u.scheme == 'http' || u.scheme == 'https') && u.host.isNotEmpty ||
            u.scheme == 'mailto');
  }

  static double? _number(String v) {
    final n = double.tryParse(v.replaceAll('%', '').trim());
    return n == null || !n.isFinite ? null : n;
  }

  static bool _httpUrl(String v) {
    final u = Uri.tryParse(v);
    return u != null &&
        (u.scheme == 'http' || u.scheme == 'https') &&
        u.host.isNotEmpty;
  }
}

/// Keeps the known class names of a `class` attribute, space separated.
String cleanClasses(String v) => v
    .toLowerCase()
    .split(RegExp(r'\s+'))
    .where(htmlClasses.contains)
    .toSet()
    .join(' ');

/// Attribute text the app shows or sends: control and direction-override
/// characters removed, whitespace collapsed, at most [max] characters.
String cleanText(String v, int max) {
  final t = v
      .replaceAll(
        RegExp(
          r'[\u0000-\u001f\u007f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]',
        ),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return t.length <= max ? t : t.substring(0, max).trimRight();
}

// ------------------------------------------------------------------ CSS

final _unsafeCss = RegExp(
  r'url\s*\(|expression\s*\(|@import|javascript:|behavior\s*:|-moz-binding|\\',
  caseSensitive: false,
);

/// Reads the allowed CSS of one `style` attribute. [empty]: the element has
/// no text or image (it may be a status dot).
HStyle parseCss(String css, {bool empty = false}) {
  if (css.trim().isEmpty) return HStyle.none;
  var display = HDisplay.block;
  var row = true, wrap = false, border = false, bold = false, hidden = false;
  double gap = 0, radius = 0;
  String? align, justify, textAlign;
  var columns = 0, flex = 0, size = 0;
  var margin = EdgeInsets.zero, padding = EdgeInsets.zero;
  UiTone? background;
  UiTone? tone;
  double? w, h;
  for (final decl in css.split(';')) {
    final i = decl.indexOf(':');
    if (i < 0) continue;
    final prop = decl.substring(0, i).trim().toLowerCase();
    var value = decl.substring(i + 1).trim().toLowerCase();
    if (value.isEmpty || _unsafeCss.hasMatch(value)) continue;
    value = value.replaceAll('!important', '').trim();
    switch (prop) {
      case 'display':
        if (value == 'flex' || value == 'inline-flex') display = HDisplay.flex;
        if (value == 'grid' || value == 'inline-grid') display = HDisplay.grid;
        if (value == 'none') hidden = true;
      case 'flex-direction':
        row = !value.startsWith('column');
      case 'flex-wrap':
        wrap = value == 'wrap';
      case 'gap' || 'row-gap' || 'column-gap' || 'grid-gap':
        gap = math.max(gap, _len(value.split(' ').first) ?? 0);
      case 'align-items':
        align = _edge(value);
      case 'justify-content':
        justify = value.startsWith('space-') ? value : _edge(value);
      case 'grid-template-columns':
        columns = _columns(value);
      case 'flex' || 'flex-grow':
        final f = double.tryParse(value.split(' ').first);
        if (f != null && f > 0) flex = f.round().clamp(1, 12);
      case 'margin':
        margin = _box(value) ?? margin;
      case 'padding':
        padding = _box(value) ?? padding;
      case 'margin-top' || 'margin-bottom' || 'margin-left' || 'margin-right':
        margin = _side(margin, prop.substring(7), _len(value));
      case 'padding-top' ||
          'padding-bottom' ||
          'padding-left' ||
          'padding-right':
        padding = _side(padding, prop.substring(8), _len(value));
      case 'border-radius':
        radius = (_len(value.split(' ').first) ?? 0).clamp(
          0,
          HtmlLimits.maxRadius,
        );
      case 'border' ||
          'border-top' ||
          'border-bottom' ||
          'border-left' ||
          'border-right' ||
          'border-width' ||
          'border-style':
        border = !value.startsWith('none') && !value.startsWith('0');
      case 'text-align':
        if (const {'left', 'center', 'right', 'start', 'end'}.contains(value)) {
          textAlign = switch (value) {
            'start' => 'left',
            'end' => 'right',
            _ => value,
          };
        }
      case 'font-weight':
        final n = int.tryParse(value);
        bold = value.startsWith('bold') || (n != null && n >= 600);
      case 'font-size':
        size = _fontSize(value);
      case 'color':
        final t = toneOfColor(value);
        tone = t == UiTone.neutral ? null : t;
      case 'background' || 'background-color':
        background = toneOfColor(value);
      case 'width':
        w = _len(value, max: 1000);
      case 'height':
        h = _len(value, max: 1000);
      default:
      // Colours, fonts, positions and everything else: ignored.
    }
  }
  final isDot =
      empty &&
      background != null &&
      (w ?? 99) <= 16 &&
      (h ?? w ?? 99) <= 16 &&
      (w != null || h != null);
  return HStyle(
    display: display,
    row: row,
    wrap: wrap,
    gap: gap,
    align: align,
    justify: justify,
    columns: columns,
    flex: flex,
    margin: margin,
    padding: padding,
    radius: radius,
    border: border,
    textAlign: textAlign,
    bold: bold,
    size: size,
    dot: isDot ? background : null,
    hidden: hidden,
    width: w,
    height: h,
    tone: tone,
  );
}

String? _edge(String v) => switch (v) {
  'center' => 'center',
  'flex-start' || 'start' || 'left' || 'baseline' => 'start',
  'flex-end' || 'end' || 'right' => 'end',
  'stretch' => 'stretch',
  _ => null,
};

/// A length in dp: px, em/rem (× 16), bare numbers; clamped to [max].
double? _len(String v, {double max = HtmlLimits.maxSpace}) {
  final m = RegExp(r'^(-?[\d.]+)(px|em|rem|%)?$').firstMatch(v.trim());
  if (m == null) return v.trim() == 'auto' ? 0 : null;
  var n = double.tryParse(m[1]!) ?? 0;
  if (m[2] == 'em' || m[2] == 'rem') n *= 16;
  if (m[2] == '%') return null;
  return n.clamp(0, max).toDouble();
}

EdgeInsets? _box(String v) {
  final p = [for (final x in v.split(RegExp(r'\s+'))) _len(x) ?? 0];
  return switch (p.length) {
    1 => EdgeInsets.all(p[0]),
    2 => EdgeInsets.symmetric(vertical: p[0], horizontal: p[1]),
    3 => EdgeInsets.fromLTRB(p[1], p[0], p[1], p[2]),
    4 => EdgeInsets.fromLTRB(p[3], p[0], p[1], p[2]),
    _ => null,
  };
}

EdgeInsets _side(EdgeInsets e, String side, double? v) {
  if (v == null) return e;
  return switch (side) {
    'top' => e.copyWith(top: v),
    'bottom' => e.copyWith(bottom: v),
    'left' => e.copyWith(left: v),
    _ => e.copyWith(right: v),
  };
}

int _columns(String v) {
  final rep = RegExp(r'repeat\(\s*(\d+)').firstMatch(v);
  final n = rep != null
      ? int.parse(rep[1]!)
      : v.split(RegExp(r'\s+(?![^(]*\))')).where((x) => x.isNotEmpty).length;
  return n.clamp(1, HtmlLimits.maxColumns);
}

int _fontSize(String v) {
  switch (v) {
    case 'x-small' || 'small' || 'smaller':
      return -1;
    case 'large' || 'larger':
      return 1;
    case 'x-large' || 'xx-large':
      return 2;
  }
  final m = RegExp(r'^([\d.]+)(px|em|rem|%)?$').firstMatch(v);
  if (m == null) return 0;
  var px = double.tryParse(m[1]!) ?? 16;
  if (m[2] == 'em' || m[2] == 'rem') px *= 16;
  if (m[2] == '%') px = px / 100 * 16;
  if (px < 14.5) return -1;
  if (px >= 24) return 2;
  if (px >= 19) return 1;
  return 0;
}

/// The theme tone a CSS colour stands for (dots only): green → good,
/// amber/orange/yellow → warn, red → bad, grey → neutral; other hues → info.
UiTone? toneOfColor(String v) {
  const named = {
    'green': UiTone.good, 'lime': UiTone.good, 'limegreen': UiTone.good,
    'seagreen': UiTone.good, 'forestgreen': UiTone.good, //
    'red': UiTone.bad, 'crimson': UiTone.bad, 'darkred': UiTone.bad,
    'orange': UiTone.warn, 'gold': UiTone.warn, 'yellow': UiTone.warn,
    'amber': UiTone.warn, 'orangered': UiTone.bad,
    'gray': UiTone.neutral, 'grey': UiTone.neutral, 'silver': UiTone.neutral,
    'blue': UiTone.info, 'dodgerblue': UiTone.info,
  };
  final s = v.split(' ').first.trim();
  if (named.containsKey(s)) return named[s];
  Color? c;
  final hex = RegExp(r'^#([0-9a-f]{3}|[0-9a-f]{6})$').firstMatch(s);
  if (hex != null) {
    var h = hex[1]!;
    if (h.length == 3) h = h.split('').map((x) => '$x$x').join();
    c = Color(0xFF000000 | int.parse(h, radix: 16));
  }
  final rgb = RegExp(r'^rgba?\((\d+)[ ,]+(\d+)[ ,]+(\d+)').firstMatch(v);
  if (rgb != null) {
    c = Color.fromARGB(
      255,
      int.parse(rgb[1]!).clamp(0, 255),
      int.parse(rgb[2]!).clamp(0, 255),
      int.parse(rgb[3]!).clamp(0, 255),
    );
  }
  if (c == null) return null;
  final hsl = HSLColor.fromColor(c);
  if (hsl.saturation < 0.2) return UiTone.neutral;
  final hue = hsl.hue;
  if (hue < 18 || hue >= 330) return UiTone.bad;
  if (hue < 65) return UiTone.warn;
  if (hue < 170) return UiTone.good;
  return UiTone.info;
}

// ------------------------------------------------------------- markdown

const _blockTags = {
  'p', 'h1', 'h2', 'h3', 'h4', 'ul', 'ol', 'table', 'hr', 'details', //
  'div', 'section', 'figure', 'figcaption', 'img', 'dl', 'button',
  'progress',
};

/// Markdown-escapes plain text so it can never form markup.
String mdEscape(String s) {
  final t = s.replaceAllMapped(
    RegExp(r'([\\`*_\[\]<>#|~!])'),
    (m) => '\\${m[1]}',
  );
  // A line that would start a list or quote.
  return t.replaceFirstMapped(
    RegExp(r'^(\s*)([-+>]|\d+\.)'),
    (m) =>
        '${m[1]}${m[2]!.replaceAllMapped(RegExp(r'([-+>.])'), (x) => '\\${x[1]}')}',
  );
}

/// The markdown for inline content.
String _inline(List<HNode> nodes) {
  final b = StringBuffer();
  for (final n in nodes) {
    switch (n) {
      case HText(:final text, :final tone):
        b.write(_tone(mdEscape(text.replaceAll(RegExp(r'\s+'), ' ')), tone));
      case HElement(tag: 'br'):
        b.write('<br>');
      case HElement(tag: 'strong', :final children):
        b.write(_wrap('**', _inline(children)));
      case HElement(tag: 'em', :final children):
        b.write(_wrap('*', _inline(children)));
      case HElement(tag: 'small', :final children):
        final t = _inline(children).trim();
        if (t.isNotEmpty) b.write('<small>$t</small>');
      case HElement(tag: 'a', :final attrs, :final children):
        final t = _inline(children).trim();
        final href = attrs['href'];
        b.write(
          href == null || t.isEmpty
              ? t
              : '[$t](${href.replaceAll(')', '%29').replaceAll(' ', '%20')})',
        );
      case HElement(tag: 'img', :final attrs):
        b.write(_image(attrs));
      case HElement(tag: 'button' || 'progress'):
        continue; // drawn as widgets; never inline text
      case final HElement e when e.has('badge'):
        final t = mdEscape(e.text.replaceAll(RegExp(r'\s+'), ' ').trim());
        if (t.isEmpty) continue;
        final tag = badgeTag(htmlTone(e.classes));
        b.write('<$tag>$t</$tag>');
      case HElement(:final children, :final style):
        if (style.dot != null) continue;
        var t = _inline(children);
        if (style.bold) t = _wrap('**', t);
        if (style.size < 0 && t.trim().isNotEmpty) {
          t = '<small>${t.trim()}</small>';
        }
        b.write(t);
    }
  }
  return b.toString();
}

/// The inline tag (`html_subset.dart` [kBadgeTags]) for a badge of [tone].
String badgeTag(UiTone? tone) => switch (tone) {
  UiTone.good => 'badge-good',
  UiTone.warn || UiTone.tip => 'badge-warn',
  UiTone.bad => 'badge-bad',
  UiTone.info => 'badge-info',
  _ => 'badge-neutral',
};

/// Wraps [text] in the inline tag for [tone] (`html_subset.dart`
/// [kToneTags]), keeping outer spaces outside.
String _tone(String text, UiTone? tone) {
  final tag = switch (tone) {
    UiTone.bad => 'tone-bad',
    UiTone.good => 'tone-good',
    UiTone.warn || UiTone.tip => 'tone-warn',
    UiTone.info => 'tone-accent',
    _ => null,
  };
  final t = text.trim();
  if (tag == null || t.isEmpty) return text;
  final lead = text.startsWith(' ') ? ' ' : '';
  final trail = text.endsWith(' ') ? ' ' : '';
  return '$lead<$tag>$t</$tag>$trail';
}

String _wrap(String mark, String inner) {
  final t = inner.trim();
  if (t.isEmpty) return inner;
  final lead = inner.startsWith(' ') ? ' ' : '';
  final trail = inner.endsWith(' ') ? ' ' : '';
  return '$lead$mark$t$mark$trail';
}

String _image(Map<String, String> attrs) {
  final alt = mdEscape(attrs['alt'] ?? 'Image').replaceAll('\n', ' ');
  final src = attrs['src']!.replaceAll(')', '%29').replaceAll(' ', '%20');
  return '![$alt]($src)';
}

/// Markdown for a run of flow nodes (no layout containers at this level).
String flowMarkdown(List<HNode> nodes, {int indent = 0}) {
  final out = <String>[];
  final inline = <HNode>[];
  final pad = ' ' * indent;
  void flush() {
    final t = _inline(inline).trim();
    if (t.isNotEmpty) out.add('$pad$t');
    inline.clear();
  }

  for (final n in nodes) {
    if (n is HText || n is HElement && !_blockTags.contains(n.tag)) {
      inline.add(n);
      continue;
    }
    flush();
    final e = n as HElement;
    final s = e.style;
    switch (e.tag) {
      case 'h1' || 'h2' || 'h3' || 'h4':
        final t = _inline(e.children).trim();
        if (t.isNotEmpty) out.add('$pad${'#' * int.parse(e.tag[1])} $t');
      case 'p' || 'figcaption':
        var t = _inline(e.children).trim();
        if (t.isEmpty) continue;
        if (e.tag == 'figcaption' || s.size < 0) t = '<small>$t</small>';
        if (s.size >= 1) t = '${s.size >= 2 ? '##' : '###'} $t';
        if (s.bold && s.size < 1) t = _wrap('**', t);
        out.add('$pad$t');
      case 'ul' || 'ol':
        out.add(_list(e, indent));
      case 'table':
        final t = _table(e);
        if (t.isNotEmpty) out.add(t);
      case 'hr':
        out.add('$pad---');
      case 'button' || 'progress':
        continue; // widgets, never markdown
      case 'dl':
        // Spec sheets in flowed text (read aloud, nested lists): "**Term:** value".
        final rows = <String>[];
        for (final c in e.children.whereType<HElement>()) {
          final t = _inline(c.children).trim();
          if (t.isEmpty) continue;
          if (c.tag == 'dt') {
            rows.add('$pad- **${t.replaceAll('**', '')}:**');
          } else if (rows.isNotEmpty) {
            rows[rows.length - 1] = '${rows.last} $t';
          } else {
            rows.add('$pad- $t');
          }
        }
        if (rows.isNotEmpty) out.add(rows.join('\n'));
      case 'img':
        out.add('$pad${_image(e.attrs)}');
      case 'details':
        final summary = e.children
            .whereType<HElement>()
            .where((c) => c.tag == 'summary')
            .firstOrNull;
        final body = flowMarkdown([
          for (final c in e.children)
            if (c != summary) c,
        ]);
        final title = summary == null ? 'Details' : _inline(summary.children);
        out.add(
          '<details${e.attrs.containsKey('open') ? ' open' : ''}>'
          '<summary>${title.trim()}</summary>\n\n$body\n\n</details>',
        );
      default: // div/section/figure inside flow content
        final t = flowMarkdown(e.children, indent: indent);
        if (t.trim().isNotEmpty) out.add(t);
    }
  }
  flush();
  return out.join('\n\n');
}

String _list(HElement list, int indent) {
  final ordered = list.tag == 'ol';
  final lines = <String>[];
  var i = 1;
  for (final li in list.children.whereType<HElement>()) {
    if (li.tag != 'li') continue;
    final marker = ordered ? '${i++}. ' : '- ';
    final inner = <HNode>[];
    final nested = <HElement>[];
    for (final c in li.children) {
      if (c is HElement && (c.tag == 'ul' || c.tag == 'ol')) {
        nested.add(c);
      } else {
        inner.add(c);
      }
    }
    final text = flowMarkdown(inner).replaceAll('\n\n', ' ').trim();
    lines.add('${' ' * indent}$marker$text');
    for (final n in nested) {
      lines.add(_list(n, indent + marker.length));
    }
  }
  return lines.join('\n');
}

String _table(HElement table) {
  final rows = <(List<String>, bool)>[];
  void collect(HElement e) {
    for (final c in e.children.whereType<HElement>()) {
      if (c.tag == 'tr') {
        final cells = c.children
            .whereType<HElement>()
            .where((x) => x.tag == 'td' || x.tag == 'th')
            .toList();
        if (cells.isEmpty) continue;
        rows.add((
          [
            for (final x in cells)
              _inline(x.children)
                  .replaceAll('<br>', ' ')
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .trim(),
          ],
          cells.every((x) => x.tag == 'th'),
        ));
      } else if (const {'thead', 'tbody', 'tfoot'}.contains(c.tag)) {
        collect(c);
      }
    }
  }

  collect(table);
  if (rows.isEmpty) return '';
  final n = rows.map((r) => r.$1.length).reduce(math.max);
  List<String> pad(List<String> r) => [
    ...r,
    for (var i = r.length; i < n; i++) '',
  ];
  String line(List<String> r) => '| ${pad(r).join(' | ')} |';
  final head = rows.first;
  final body = rows.skip(1);
  return [
    line(head.$1),
    '|${List.filled(n, ' --- ').join('|')}|',
    for (final r in body) line(r.$1),
  ].join('\n');
}

// --------------------------------------------------------------- widgets

/// Draws sanitised HTML as part of the reply.
class HermesHtml extends StatelessWidget {
  const HermesHtml({super.key, required this.source, this.style});

  final String source;
  final MarkdownStyle? style;

  @override
  Widget build(BuildContext context) {
    final s = style ?? MarkdownStyle.of(context);
    final doc = sanitizeHtml(source);
    // A lazy reply (paragraphs, emphasis, plain lists) reads exactly like
    // markdown: no boxes, padding or extra gaps.
    if (isPlainHtml(doc.nodes)) {
      final md = flowMarkdown(doc.nodes).trim();
      return md.isEmpty
          ? const SizedBox.shrink()
          : NoNestedUiBlocks(
              child: HermesMarkdown(text: md, style: s),
            );
    }
    return NoNestedUiBlocks(
      child: _HtmlBlocks(nodes: doc.nodes, style: s),
    );
  }
}

const _plainTags = {
  'p', 'strong', 'em', 'ul', 'ol', 'li', 'br', 'a', 'small', 'span', 'h1', //
  'h2', 'h3', 'h4', 'hr', 'div', 'section',
};

/// True when [nodes] hold only paragraphs, headings, emphasis, links and
/// plain lists (in unstyled or single-column wrappers): nothing markdown
/// cannot say. Their boxes, borders and padding are then ignored.
bool isPlainHtml(List<HNode> nodes) {
  for (final n in nodes) {
    if (n is! HElement) continue;
    if (!_plainTags.contains(n.tag) ||
        n.classes.isNotEmpty ||
        n.style.dot != null) {
      return false;
    }
    if (n.tag == 'div' || n.tag == 'section') {
      final kids = n.children.whereType<HElement>().length;
      final columns =
          n.style.display == HDisplay.grid && n.style.columns > 1 ||
          n.style.display == HDisplay.flex && n.style.row;
      if (columns && kids > 1) return false;
    }
    if (!isPlainHtml(n.children)) return false;
  }
  return true;
}

const _layoutTags = {'div', 'section', 'figure'};

bool _isLayout(HNode n) =>
    n is HElement && (_layoutTags.contains(n.tag) || isHtmlComponent(n));

bool _isButton(HNode n) =>
    n is HElement &&
    (n.tag == 'button' ||
        n.tag == 'a' && n.has('button') && n.attrs['href'] != null);

/// A run of nodes: flow content as markdown, containers as layout.
class _HtmlBlocks extends StatelessWidget {
  const _HtmlBlocks({required this.nodes, required this.style});
  final List<HNode> nodes;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final parts = <Widget>[];
    final flow = <HNode>[];
    final buttons = <HElement>[];
    void flush() {
      if (buttons.isNotEmpty) {
        parts.add(HtmlButtons(buttons: List.of(buttons), style: style));
        buttons.clear();
      }
      final md = flowMarkdown(flow).trim();
      flow.clear();
      if (md.isNotEmpty) parts.add(HermesMarkdown(text: md, style: style));
    }

    for (final n in nodes) {
      if (_isButton(n)) {
        // Buttons in a row share one wrap; text before them comes first.
        if (flow.isNotEmpty) flush();
        buttons.add(n as HElement);
      } else if (buttons.isNotEmpty && n is HText && n.text.trim().isEmpty) {
        continue;
      } else if (n is HElement &&
          n.tag == 'img' &&
          (n.style.width ?? 999) <= 160) {
        flush();
        parts.add(_smallImage(n, style));
      } else if (_isLayout(n)) {
        flush();
        parts.add(htmlElement(n as HElement, style));
      } else if (n is HElement && n.style.dot != null) {
        flush();
        parts.add(_dot(n, style));
      } else {
        flow.add(n);
      }
    }
    flush();
    if (parts.length == 1) return parts.single;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, p) in parts.indexed) ...[
          if (i > 0) SizedBox(height: style.paragraphGap),
          p,
        ],
      ],
    );
  }
}

/// An icon-sized picture (a logo, an avatar) at its own size, loaded
/// through the bridge like every reply image.
Widget _smallImage(HElement e, MarkdownStyle s) {
  final w = e.style.width!;
  return Semantics(
    image: true,
    label: e.attrs['alt'],
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: 1,
      child: UiRemoteImage(
        url: e.attrs['src'],
        width: w,
        height: e.style.height ?? w,
        radius: e.style.radius,
        style: s,
      ),
    ),
  );
}

Widget _dot(HElement e, MarkdownStyle s) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 4),
  child: StateDot(
    color: dashTone(e.style.dot!, s, neutral: s.textMuted),
    size: 8,
  ),
);

/// A `div`, `section` or `figure`: margin, an optional light outline,
/// padding, then its children as a block, a flex row/column or a grid.
class _HtmlBox extends StatelessWidget {
  const _HtmlBox({required this.element, required this.style});
  final HElement element;
  final MarkdownStyle style;

  /// Children as items with their `flex`. In a flex row or grid every
  /// child is an item; in a block, runs of inline content merge.
  List<(Widget, int)> _items() {
    final out = <(Widget, int)>[];
    final flow = <HNode>[];
    final split = element.style.display != HDisplay.block;
    final cards = element.has('cards');
    final buttons = <HElement>[];
    void flush() {
      if (buttons.isNotEmpty) {
        out.add((HtmlButtons(buttons: List.of(buttons), style: style), 0));
        buttons.clear();
      }
      final has = flow.any(
        (n) => n is HElement || (n as HText).text.trim().isNotEmpty,
      );
      if (has) out.add((_HtmlBlocks(nodes: List.of(flow), style: style), 0));
      flow.clear();
    }

    for (final c in element.children) {
      if (c is HText && c.text.trim().isEmpty) continue;
      if (cards && c is HElement) {
        flush();
        out.add((HtmlCard(element: c, style: style), c.style.flex));
        continue;
      }
      if (!split && _isButton(c)) {
        if (flow.isNotEmpty) flush();
        buttons.add(c as HElement);
        continue;
      }
      final own =
          split ||
          _isLayout(c) ||
          c is HElement && (c.style.dot != null || _blockTags.contains(c.tag));
      if (!own) {
        flow.add(c);
        continue;
      }
      flush();
      // Fixed-size items (dots, small pictures) keep their size: -1.
      final fixed =
          c is HElement &&
          (c.style.dot != null ||
              c.tag == 'img' && (c.style.width ?? 999) <= 160);
      final flex = fixed ? -1 : (c is HElement ? c.style.flex : 0);
      out.add((
        c is HElement && c.style.dot != null
            ? _dot(c, style)
            : _HtmlBlocks(nodes: [c], style: style),
        flex,
      ));
    }
    flush();
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final st = element.style;
    final flexed = _items();
    final items = [for (final x in flexed) x.$1];
    Widget body;
    if (items.isEmpty) {
      body = const SizedBox.shrink();
    } else if (st.display == HDisplay.grid && st.columns > 1) {
      // Component grids (cards, pros/cons) want wider columns; all
      // columns widen with the text size.
      final minColumn =
          (element.classes.isEmpty ? 110.0 : 150.0) *
          MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 3.0);
      body = LayoutBuilder(
        builder: (context, c) {
          final cols = math.max(
            1,
            math.min(st.columns, (c.maxWidth / minColumn).floor()),
          );
          final gap = st.gap == 0 ? 12.0 : st.gap;
          final rows = <Widget>[];
          for (var i = 0; i < items.length; i += cols) {
            if (i > 0) rows.add(SizedBox(height: gap));
            rows.add(
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var j = 0; j < cols; j++) ...[
                    if (j > 0) SizedBox(width: gap),
                    Expanded(
                      child: i + j < items.length
                          ? items[i + j]
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: rows,
          );
        },
      );
    } else if (st.display == HDisplay.flex && st.row) {
      final cross = switch (st.align) {
        'start' => CrossAxisAlignment.start,
        'end' => CrossAxisAlignment.end,
        _ => CrossAxisAlignment.center,
      };
      if (st.wrap) {
        body = LayoutBuilder(
          builder: (context, c) => Wrap(
            spacing: st.gap,
            runSpacing: st.gap,
            crossAxisAlignment: switch (st.align) {
              'start' => WrapCrossAlignment.start,
              'end' => WrapCrossAlignment.end,
              _ => WrapCrossAlignment.center,
            },
            children: [
              for (final w in items)
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: c.maxWidth),
                  child: w,
                ),
            ],
          ),
        );
      } else {
        final main = switch (st.justify) {
          'center' => MainAxisAlignment.center,
          'end' => MainAxisAlignment.end,
          'space-between' => MainAxisAlignment.spaceBetween,
          'space-around' || 'space-evenly' => MainAxisAlignment.spaceAround,
          _ => MainAxisAlignment.start,
        };
        body = Row(
          mainAxisAlignment: main,
          crossAxisAlignment: cross,
          children: [
            for (final (i, (w, flex)) in flexed.indexed) ...[
              if (i > 0 && st.gap > 0) SizedBox(width: st.gap),
              if (flex > 0)
                Expanded(flex: flex, child: w)
              else if (flex < 0)
                w
              else
                Flexible(child: w),
            ],
          ],
        );
      }
    } else {
      final gap = st.display == HDisplay.flex ? st.gap : style.paragraphGap;
      body = Column(
        crossAxisAlignment: st.align == 'center'
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, w) in items.indexed) ...[
            if (i > 0 && gap > 0) SizedBox(height: gap),
            w,
          ],
        ],
      );
    }
    if (st.textAlign == 'center' || st.textAlign == 'right') {
      body = Align(
        alignment: st.textAlign == 'center'
            ? Alignment.topCenter
            : Alignment.topRight,
        widthFactor: 1,
        child: body,
      );
    }
    final pad = st.padding.add(
      st.border && st.padding == EdgeInsets.zero
          ? const EdgeInsets.all(12)
          : EdgeInsets.zero,
    );
    if (pad != EdgeInsets.zero) body = Padding(padding: pad, child: body);
    if (st.border) {
      body = DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: style.outline),
          borderRadius: BorderRadius.circular(
            st.radius == 0 ? style.frameRadius : st.radius,
          ),
        ),
        child: body,
      );
    }
    if (st.margin != EdgeInsets.zero) {
      body = Padding(padding: st.margin, child: body);
    }
    return body;
  }
}
