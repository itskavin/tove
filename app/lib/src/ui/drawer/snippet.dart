/// Search snippets for the drawer (API.md: snippets are plain excerpts with
/// no match markers, but message text is markdown, so it may carry table
/// pipes, fences and emphasis).
library;

final _fence = RegExp(r'^\s*(```|~~~).*$', multiLine: true);
final _tableRule = RegExp(
  r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$',
  multiLine: true,
);
final _heading = RegExp(r'^\s{0,3}#{1,6}\s+', multiLine: true);
final _quote = RegExp(r'^\s{0,3}>\s?', multiLine: true);
final _bullet = RegExp(r'^\s*(?:[-*+]|\d{1,3}[.)])\s+', multiLine: true);
final _rule = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$', multiLine: true);
final _image = RegExp(r'!\[([^\]]*)\]\([^)]*\)');
final _link = RegExp(r'\[([^\]]+)\]\([^)]*\)');
final _html = RegExp(r'</?[A-Za-z][^>]*>');
final _strong = RegExp(r'(\*\*|__)(.+?)\1');
final _em = RegExp(r'(?<![\w*])([*_])(?!\s)(.+?)(?<!\s)\1(?![\w*])');
final _strike = RegExp(r'~~(.+?)~~');
final _code = RegExp(r'`+([^`]*)`+');
final _space = RegExp(r'\s+');

/// Plain text from markdown: no fences, table rules, headings, quotes, list
/// markers, emphasis, inline-code ticks, link targets or HTML tags. Table
/// cells are joined with " · ", lines with spaces.
String stripMarkdown(String md) {
  var s = md
      .replaceAll(_fence, '')
      .replaceAll(_tableRule, '')
      .replaceAll(_rule, '')
      .replaceAll(_heading, '')
      .replaceAll(_quote, '')
      .replaceAll(_bullet, '');
  s = s
      .split('\n')
      .map((line) {
        final l = line.trim();
        if (!l.contains('|')) return l;
        final cells = l
            .replaceAll(RegExp(r'^\||\|$'), '')
            .split('|')
            .map((c) => c.trim())
            .where((c) => c.isNotEmpty);
        return cells.join(' · ');
      })
      .join(' ');
  s = s
      .replaceAllMapped(_image, (m) => m[1]!)
      .replaceAllMapped(_link, (m) => m[1]!)
      .replaceAll(_html, '')
      .replaceAllMapped(_strong, (m) => m[2]!)
      .replaceAllMapped(_strike, (m) => m[1]!)
      .replaceAllMapped(_em, (m) => m[2]!)
      .replaceAllMapped(_code, (m) => m[1]!);
  return s.replaceAll(_space, ' ').trim();
}

/// The first case-insensitive match of [query] in [text]: the whole query
/// first, then its longest word (of two or more characters).
(int, int)? findMatch(String text, String query) {
  final q = query.trim();
  if (q.isEmpty) return null;
  final lower = text.toLowerCase();
  final whole = lower.indexOf(q.toLowerCase());
  if (whole >= 0) return (whole, whole + q.length);
  final words = q.split(_space).where((w) => w.length > 1).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final w in words) {
    final i = lower.indexOf(w.toLowerCase());
    if (i >= 0) return (i, i + w.length);
  }
  return null;
}

/// A short plain-text excerpt of [text] with the first match of [query]
/// near its start, so a two-line row shows it: up to [before] characters of
/// lead-in (cut at a word boundary) and an ellipsis on each cut side.
String searchSnippet(
  String text,
  String query, {
  int before = 28,
  int maxLength = 140,
}) {
  final plain = stripMarkdown(text);
  final m = findMatch(plain, query);
  var start = 0;
  if (m != null && m.$1 > before) {
    start = m.$1 - before;
    // Start on a word: skip the partial word the cut landed in.
    final space = plain.indexOf(' ', start);
    if (space >= 0 && space < m.$1) start = space + 1;
  }
  var end = plain.length;
  if (end - start > maxLength) {
    end = start + maxLength;
    if (m != null && end < m.$2) end = m.$2;
    final space = plain.lastIndexOf(' ', end);
    if (space > (m?.$2 ?? start)) end = space;
  }
  final body = plain.substring(start, end).trim();
  return '${start > 0 ? '…' : ''}$body${end < plain.length ? '…' : ''}';
}
