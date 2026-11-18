/// The restricted inline-HTML subset (chat-rendering-v2 §3.2).
///
/// Allowed: `<small>`, `<kbd>`, `<mark>`, `<sub>`, `<sup>`, `<u>`, `<br>` and
/// block-level `<details><summary>…</summary>…</details>`. Attributes are
/// ignored. Every other tag, and an allowed tag that is never closed, stays
/// visible as literal text. Nothing is executed, loaded or hidden.
library;

import 'package:markdown/markdown.dart' as md;

/// Inline tags that become formatting.
const Set<String> kInlineHtmlTags = {
  'small', 'kbd', 'mark', 'sub', 'sup', 'u', //
  ...kToneTags,
  ...kBadgeTags,
};

/// Small outlined pills in a state colour: emitted by the safe-HTML
/// converter for `class="badge good|warn|bad|info"` (neutral otherwise).
const Set<String> kBadgeTags = {
  'badge-good',
  'badge-warn',
  'badge-bad',
  'badge-info',
  'badge-neutral',
};

/// Theme colours for text: emitted by the safe-HTML converter for CSS
/// `color` (red, green, amber, blue-ish) and drawn with the theme's danger,
/// success, warning and accent tokens. Nothing else can be coloured.
const Set<String> kToneTags = {
  'tone-bad',
  'tone-good',
  'tone-warn',
  'tone-accent',
};

final _tagRe = RegExp(r'<(/?)([A-Za-z][A-Za-z0-9-]*)(?:\s[^<>]*)?\s*(/?)>');

/// Replaces allowed inline tags in [nodes] (as produced by `package:markdown`
/// with `encodeHtml: false`, where raw tags are text) with elements named
/// after the tag. `<br>` becomes a `br` element. Returns [nodes] itself when
/// there is nothing to change, and never mutates its input.
List<md.Node> applyInlineHtml(List<md.Node> nodes) {
  if (!_mayHaveTags(nodes)) return nodes;
  final root = _Frame(null, null);
  final stack = <_Frame>[root];

  void addText(String t) {
    if (t.isEmpty) return;
    final kids = stack.last.children;
    if (kids.isNotEmpty && kids.last is md.Text) {
      kids[kids.length - 1] = md.Text((kids.last as md.Text).text + t);
    } else {
      kids.add(md.Text(t));
    }
  }

  for (final n in nodes) {
    if (n is md.Element) {
      final kids = n.children;
      if (kids == null || n.tag == 'code' || n.tag == 'pre') {
        stack.last.children.add(n);
      } else {
        final mapped = applyInlineHtml(kids);
        stack.last.children.add(identical(mapped, kids) ? n : _copy(n, mapped));
      }
      continue;
    }
    if (n is! md.Text) {
      stack.last.children.add(n);
      continue;
    }
    final text = n.text;
    var at = 0;
    for (final m in _tagRe.allMatches(text)) {
      addText(text.substring(at, m.start));
      at = m.end;
      final closing = m[1] == '/';
      final name = m[2]!.toLowerCase();
      if (name == 'br' && !closing) {
        stack.last.children.add(md.Element.empty('br'));
        continue;
      }
      if (!kInlineHtmlTags.contains(name) || m[3] == '/') {
        addText(m[0]!);
        continue;
      }
      if (!closing) {
        stack.add(_Frame(name, m[0]!));
        continue;
      }
      final idx = stack.lastIndexWhere((f) => f.tag == name);
      if (idx <= 0) {
        addText(m[0]!);
        continue;
      }
      // Close every frame above the match as literal (badly nested tags).
      while (stack.length - 1 > idx) {
        _unwrap(stack);
      }
      final f = stack.removeLast();
      stack.last.children.add(md.Element(f.tag!, f.children));
    }
    addText(text.substring(at));
  }
  while (stack.length > 1) {
    _unwrap(stack);
  }
  return root.children;
}

class _Frame {
  _Frame(this.tag, this.open);
  final String? tag;
  final String? open;
  final List<md.Node> children = [];
}

/// Pops an unclosed frame, putting its opening tag back as literal text.
void _unwrap(List<_Frame> stack) {
  final f = stack.removeLast();
  final parent = stack.last.children;
  parent.add(md.Text(f.open!));
  parent.addAll(f.children);
  // Merge adjacent texts so the result stays tidy.
  for (var i = parent.length - 1; i > 0; i--) {
    if (parent[i] is md.Text && parent[i - 1] is md.Text) {
      parent[i - 1] = md.Text(
        (parent[i - 1] as md.Text).text + (parent[i] as md.Text).text,
      );
      parent.removeAt(i);
    }
  }
}

md.Element _copy(md.Element e, List<md.Node> children) {
  final c = md.Element(e.tag, children);
  c.attributes.addAll(e.attributes);
  return c;
}

bool _mayHaveTags(List<md.Node> nodes) {
  for (final n in nodes) {
    if (n is md.Text && n.text.contains('<')) return true;
    if (n is md.Element &&
        n.tag != 'code' &&
        n.children != null &&
        _mayHaveTags(n.children!)) {
      return true;
    }
  }
  return false;
}

/// A `<details>` block: its summary, its markdown body and whether it starts
/// open (the `open` attribute is the one attribute honoured).
typedef DetailsHtml = ({String summary, String body, bool open, bool closed});

final _detailsOpen = RegExp(
  r'^\s{0,3}<details(\s[^>]*)?>',
  caseSensitive: false,
);
final _detailsClose = RegExp(r'</details>\s*$', caseSensitive: false);
final _summary = RegExp(
  r'^\s*<summary(?:\s[^>]*)?>([\s\S]*?)</summary>',
  caseSensitive: false,
);

/// True if [line] opens a `<details>` block.
bool opensDetails(String line) => _detailsOpen.hasMatch(line);

/// True if [line] closes a `<details>` block.
bool closesDetails(String line) => _detailsClose.hasMatch(line);

/// Parses a block that starts with `<details>`. Returns null when [block] is
/// not one. A block still streaming (no `</details>` yet) parses with
/// `closed: false`.
DetailsHtml? parseDetailsHtml(String block) {
  final open = _detailsOpen.firstMatch(block);
  if (open == null) return null;
  var rest = block.substring(open.end);
  final closeAt = rest.toLowerCase().lastIndexOf('</details>');
  final closed = closeAt >= 0 && rest.substring(closeAt + 10).trim().isEmpty;
  if (closed) rest = rest.substring(0, closeAt);
  var summary = 'Details';
  final s = _summary.firstMatch(rest);
  if (s != null) {
    final t = s[1]!.replaceAll(RegExp(r'<[^>]*>'), '').trim();
    if (t.isNotEmpty) summary = t;
    rest = rest.substring(s.end);
  } else if (RegExp(r'^\s*<summary', caseSensitive: false).hasMatch(rest)) {
    // The summary is still arriving.
    rest = '';
  }
  final attrs = open[1] ?? '';
  return (
    summary: summary,
    body: rest.trim(),
    open: RegExp(r'\bopen\b', caseSensitive: false).hasMatch(attrs),
    closed: closed,
  );
}

/// For streaming: closes allowed inline tags left open in [text], and holds
/// back a half-typed tag at its end (`<sm`, `</kb`), so raw tags never
/// flicker.
String repairInlineHtml(String text) {
  final partial = RegExp(r'</?[A-Za-z]{0,6}$').firstMatch(text);
  final inCode = '`'.allMatches(text).length.isOdd;
  if (partial != null && !inCode) {
    final name = partial[0]!.replaceAll(RegExp(r'[</]'), '').toLowerCase();
    final candidates = {...kInlineHtmlTags, 'br', 'details', 'summary'};
    if (name.isEmpty || candidates.any((t) => t.startsWith(name))) {
      text = text.substring(0, partial.start);
    }
  }
  final open = <String>[];
  // Tags inside code spans are code, not markup.
  final masked = text.replaceAllMapped(
    RegExp(r'`[^`]*`'),
    (m) => 'x' * m[0]!.length,
  );
  for (final m in _tagRe.allMatches(masked)) {
    final name = m[2]!.toLowerCase();
    if (!kInlineHtmlTags.contains(name) || m[3] == '/') continue;
    if (m[1] == '/') {
      final i = open.lastIndexOf(name);
      if (i >= 0) open.removeRange(i, open.length);
    } else {
      open.add(name);
    }
  }
  for (final t in open.reversed) {
    text = '$text</$t>';
  }
  return text;
}
