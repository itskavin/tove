import '../ui/openui/plain_text.dart' show openUiPlainText;
import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

/// A reply turned into what should be heard (chat-rendering-v2 §5.4):
/// markdown stripped, lists read item by item, tables summarised, code and
/// hermes-ui JSON never read, URLs, hosts and footnote chips skipped.
class SpeakableText {
  SpeakableText._(this.text, this.sentences);

  /// Builds the speakable form of a markdown reply.
  factory SpeakableText.fromMarkdown(String markdown) =>
      SpeakableText.fromPlain(markdownToSpeakable(markdown));

  /// Splits already-plain text into sentences.
  factory SpeakableText.fromPlain(String text) =>
      SpeakableText._(text, splitSentences(text));

  /// The whole speakable text. Sentence offsets point into it.
  final String text;
  final List<SpeakableSentence> sentences;

  bool get isEmpty => sentences.isEmpty;
}

class SpeakableSentence {
  const SpeakableSentence(this.text, this.start, this.end);

  final String text;

  /// Offsets into [SpeakableText.text], end exclusive.
  final int start;
  final int end;

  @override
  String toString() => 'SpeakableSentence($start-$end: $text)';
}

// ---------------------------------------------------------------------------
// Markdown → plain speech text

/// Converts a markdown reply to plain sentences joined by newlines.
String markdownToSpeakable(String markdown) {
  final doc = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  );
  final nodes = doc.parseLines(const LineSplitter().convert(markdown));
  final out = <String>[];
  for (final n in nodes) {
    _block(n, out);
  }
  return out
      .map(_cleanInline)
      .where((s) => s.isNotEmpty)
      .map(_terminate)
      .join('\n');
}

void _block(md.Node node, List<String> out) {
  if (node is md.Text) {
    out.add(node.text);
    return;
  }
  if (node is! md.Element) return;
  final tag = node.tag;
  switch (tag) {
    case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6' || 'p':
      out.add(_inline(node));
    case 'ul' || 'ol':
      for (final li in node.children ?? const <md.Node>[]) {
        _listItem(li, out);
      }
    case 'li':
      _listItem(node, out);
    case 'blockquote':
      for (final c in node.children ?? const <md.Node>[]) {
        _block(c, out);
      }
    case 'pre':
      out.add(_codeBlock(node));
    case 'table':
      out.add(_table(node));
    case 'section':
      // GFM footnote definitions.
      if (node.attributes['class']?.contains('footnotes') == true) return;
      for (final c in node.children ?? const <md.Node>[]) {
        _block(c, out);
      }
    case 'hr':
      return;
    case 'details' || 'div':
      for (final c in node.children ?? const <md.Node>[]) {
        _block(c, out);
      }
    default:
      out.add(_inline(node));
  }
}

void _listItem(md.Node li, List<String> out) {
  if (li is! md.Element) {
    _block(li, out);
    return;
  }
  // Loose items hold <p>; tight items hold inline nodes directly. Nested
  // lists become their own items.
  final inline = <md.Node>[];
  void flush() {
    if (inline.isEmpty) return;
    out.add(inline.map(_inlineNode).join());
    inline.clear();
  }

  for (final c in li.children ?? const <md.Node>[]) {
    if (c is md.Element &&
        const {'p', 'ul', 'ol', 'pre', 'table', 'blockquote'}.contains(c.tag)) {
      flush();
      _block(c, out);
    } else if (c is md.Element && c.tag == 'input') {
      // Task-list checkbox.
      continue;
    } else {
      inline.add(c);
    }
  }
  flush();
}

String _codeBlock(md.Element pre) {
  final code = pre.children?.whereType<md.Element>().firstOrNull;
  final cls = code?.attributes['class'] ?? '';
  if (cls.contains('language-hermes-ui')) {
    return _hermesUi(code?.textContent ?? '');
  }
  if (cls.contains('language-openui')) {
    return openUiPlainText(code?.textContent ?? '');
  }
  return 'Code block skipped.';
}

/// §3.7: read `prompt`, labels and values in order, never the JSON.
String _hermesUi(String json) {
  Object? data;
  try {
    data = jsonDecode(json);
  } catch (_) {
    return 'Interactive content.';
  }
  const keys = {
    'title',
    'prompt',
    'label',
    'value',
    'text',
    'caption',
    'subtitle',
    'description',
  };
  final parts = <String>[];
  void walk(Object? v) {
    if (v is Map) {
      for (final e in v.entries) {
        final val = e.value;
        if (keys.contains(e.key) && (val is String || val is num)) {
          final s = '$val'.trim();
          if (s.isNotEmpty) parts.add(s);
        } else if (val is Map || val is List) {
          walk(val);
        }
      }
    } else if (v is List) {
      v.forEach(walk);
    }
  }

  walk(data);
  if (parts.isEmpty) return 'Interactive content.';
  return parts.map(_terminate).join(' ');
}

String _table(md.Element table) {
  final rows = <md.Element>[];
  md.Element? header;
  for (final section in table.children ?? const <md.Node>[]) {
    if (section is! md.Element) continue;
    for (final tr in section.children ?? const <md.Node>[]) {
      if (tr is! md.Element || tr.tag != 'tr') continue;
      if (section.tag == 'thead') {
        header ??= tr;
      } else {
        rows.add(tr);
      }
    }
  }
  final n = rows.length;
  final buf = StringBuffer('Table with $n ${n == 1 ? 'row' : 'rows'}.');
  if (header != null) {
    final cells = (header.children ?? const <md.Node>[])
        .map(_inlineNode)
        .map(_cleanInline)
        .where((s) => s.isNotEmpty)
        .toList();
    if (cells.isNotEmpty) buf.write(' ${cells.join(', ')}.');
  }
  return buf.toString();
}

String _inline(md.Element e) =>
    (e.children ?? const <md.Node>[]).map(_inlineNode).join();

String _inlineNode(md.Node n) {
  if (n is md.Text) return n.text;
  if (n is! md.Element) return '';
  switch (n.tag) {
    case 'a':
      final text = n.textContent.trim();
      final href = n.attributes['href'] ?? '';
      // Bare URLs and links whose text is the URL are skipped.
      if (text.isEmpty || text == href || _looksLikeUrl(text)) return '';
      return _inline(n);
    case 'img':
      final alt = n.attributes['alt']?.trim() ?? '';
      return alt.isEmpty ? '' : ' $alt ';
    case 'sup':
      // Footnote chips.
      if (n.attributes['class']?.contains('footnote') == true) return '';
      return _inline(n);
    case 'br':
      return ', ';
    case 'code':
      return n.textContent;
    case 'input':
      return '';
    default:
      return _inline(n);
  }
}

final _url = RegExp(r'''(?:https?|ftp|wss?)://[^\s<>()"']+''', caseSensitive: false);
final _www = RegExp(r'''\bwww\.[^\s<>()"']+''', caseSensitive: false);
final _ip = RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b');
final _host = RegExp(
  r'\b(?:[a-z0-9-]+\.)+(?:com|net|org|io|dev|app|ai|co|uk|de|me|sh|xyz|lan|local|home|internal|arpa|ts\.net)\b(?::\d+)?(?:/[^\s]*)?',
  caseSensitive: false,
);
final _email = RegExp(r'\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b');
final _htmlTag = RegExp(r'</?[a-zA-Z][^>]*>');
final _footnoteRef = RegExp(r'\[\^[^\]]+\]');
// Emoji and pictographs: the voices cannot say them.
final _emoji = RegExp(
  r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}\u{20E3}]',
  unicode: true,
);
final _spaces = RegExp(r'[ \t ]+');
final _spaceBeforePunct = RegExp(r'\s+([,.;:!?])');

bool _looksLikeUrl(String s) =>
    _url.hasMatch(s) || _www.hasMatch(s) || _host.hasMatch(s) || _ip.hasMatch(s);

String _cleanInline(String s) {
  var t = s
      .replaceAll(_htmlTag, ' ')
      .replaceAll(_footnoteRef, '')
      .replaceAll(_url, '')
      .replaceAll(_www, '')
      .replaceAll(_email, '')
      .replaceAll(_ip, '')
      .replaceAll(_host, '')
      .replaceAll(_emoji, '')
      .replaceAll('\n', ' ')
      // Leftover markdown markers the parser kept (e.g. in streaming text).
      .replaceAll(RegExp(r'(?<![\w])[*_~`]+|[*_~`]+(?![\w])'), '')
      .replaceAll(_spaces, ' ')
      .replaceAll(_spaceBeforePunct, r'$1')
      .replaceAll(RegExp(r'\(\s*\)'), '')
      .replaceAll(RegExp(r'([,;:])\1+'), r'$1')
      .trim();
  // A stripped URL can leave "see :" or a dangling comma.
  t = t.replaceAll(RegExp(r'^[,;:]\s*'), '').replaceAll(RegExp(r'\s*[,;:]$'), '');
  return t;
}

/// Ends a block with a sentence terminator so list items and headings get a
/// pause and become separate sentences.
String _terminate(String s) {
  if (s.isEmpty) return s;
  final last = s[s.length - 1];
  if ('.!?…:'.contains(last)) return last == ':' ? '${s.substring(0, s.length - 1)}.' : s;
  return '$s.';
}

// ---------------------------------------------------------------------------
// Sentences

const _abbreviations = {
  'mr', 'mrs', 'ms', 'dr', 'prof', 'sr', 'jr', 'st', 'vs', 'etc', 'e.g',
  'i.e', 'eg', 'ie', 'approx', 'fig', 'no', 'vol', 'inc', 'ltd', 'co', 'cf',
  'jan', 'feb', 'mar', 'apr', 'jun', 'jul', 'aug', 'sep', 'sept', 'oct',
  'nov', 'dec', 'min', 'max', 'est',
};

/// Longest sentence sent to the synthesiser in one piece. Longer ones are cut
/// at a clause boundary so the first audio arrives quickly.
const maxSentenceChars = 220;

/// The first sentence is cut shorter so playback starts sooner.
const firstSentenceChars = 120;

/// Splits plain text into sentences with offsets. Newlines always end a
/// sentence.
List<SpeakableSentence> splitSentences(String text) {
  final out = <SpeakableSentence>[];
  var start = 0;

  void emit(int end) {
    var s = start, e = end;
    while (s < e && _isSpace(text.codeUnitAt(s))) {
      s++;
    }
    while (e > s && _isSpace(text.codeUnitAt(e - 1))) {
      e--;
    }
    if (e > s && RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(text.substring(s, e))) {
      _emitBounded(text, s, e, out);
    }
    start = end;
  }

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '\n') {
      emit(i + 1);
      continue;
    }
    if (c != '.' && c != '!' && c != '?' && c != '…') continue;
    // Consume runs like "?!" or "...".
    var j = i;
    while (j + 1 < text.length && '.!?…"\')”’'.contains(text[j + 1])) {
      j++;
    }
    final atEnd = j + 1 >= text.length;
    if (!atEnd && !_isSpace(text.codeUnitAt(j + 1))) {
      i = j;
      continue; // 3.14, v2.0.1, e.g.x
    }
    if (c == '.' && _isAbbreviation(text, i)) {
      i = j;
      continue;
    }
    emit(j + 1);
    i = j;
  }
  emit(text.length);
  return out;
}

bool _isSpace(int c) => c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D || c == 0xA0;

bool _isAbbreviation(String text, int dot) {
  var s = dot;
  while (s > 0 && RegExp(r'[A-Za-z.]').hasMatch(text[s - 1])) {
    s--;
  }
  final word = text.substring(s, dot).toLowerCase();
  if (word.isEmpty) return false;
  if (_abbreviations.contains(word)) return true;
  // Single initials ("J. R. R.") but not the pronoun at a sentence end.
  return word.length == 1 && text[s] != 'I' && text[s].toUpperCase() == text[s];
}

void _emitBounded(String text, int s, int e, List<SpeakableSentence> out) {
  final limit = out.isEmpty ? firstSentenceChars : maxSentenceChars;
  while (e - s > limit) {
    final cut = _clauseCut(text, s, e, limit);
    if (cut == null) break;
    out.add(SpeakableSentence(text.substring(s, cut).trim(), s, cut));
    s = cut;
    while (s < e && _isSpace(text.codeUnitAt(s))) {
      s++;
    }
  }
  if (e > s) out.add(SpeakableSentence(text.substring(s, e), s, e));
}

/// Best cut at or before [limit] chars: after `;`, `:`, `—`, `,`, else a space.
int? _clauseCut(String text, int s, int e, int limit) {
  final windowEnd = s + limit;
  final minCut = s + 30;
  for (final marks in const [';:—–', ',']) {
    for (var i = windowEnd; i > minCut; i--) {
      if (marks.contains(text[i - 1]) && i < e && _isSpace(text.codeUnitAt(i))) {
        return i;
      }
    }
  }
  for (var i = windowEnd; i > minCut; i--) {
    if (_isSpace(text.codeUnitAt(i - 1))) return i;
  }
  return null;
}
