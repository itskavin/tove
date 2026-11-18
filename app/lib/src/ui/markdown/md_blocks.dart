/// Block splitting and partial-markdown repair for streaming (spec §5.3).
///
/// A reply is cut into blocks at blank lines outside code fences. Blocks that
/// are followed by more text are complete and never change again, so the
/// renderer parses them once. Only the trailing block is re-parsed while the
/// reply streams, after [repairPartial] has made it safe to render.
library;

import '../interactive/html_subset.dart';

final _fenceOpen = RegExp(r'^(\s*)(`{3,}|~{3,})(.*)$');
final _heading = RegExp(r'^\s{0,3}#{1,6}(\s|$)');
final _listItem = RegExp(r'^\s{0,3}([-*+]|\d{1,9}[.)])(\s|$)');
final _orderedItem = RegExp(r'^\s*\d{1,9}[.)]\s');

/// One block of a markdown text: `text.substring(start, end)`.
typedef BlockRange = ({int start, int end});

/// Splits [text] into block ranges, scanning from [from] (which must be the
/// start of a line outside any code fence, such as a previous block start).
///
/// Blocks end at blank lines outside code fences. One exception keeps lists
/// whole: after a blank line, an indented line that follows a list block
/// continues that list (a nested list or a second paragraph of an item).
List<BlockRange> splitBlockRanges(String text, {int from = 0}) {
  final out = <BlockRange>[];
  var blockStart = -1;
  var blockEnd = -1;
  var blockIsList = false;
  var sawBlank = false;
  String? fenceChar;
  var fenceLen = 0;
  var inDetails = false;

  var lineStart = from;
  while (lineStart <= text.length) {
    var nl = text.indexOf('\n', lineStart);
    if (nl < 0) nl = text.length;
    final line = text.substring(lineStart, nl);

    if (fenceChar != null) {
      // Inside a fence every line, blank or not, belongs to the block.
      final t = line.trim();
      if (t.length >= fenceLen && t.split('').every((c) => c == fenceChar)) {
        fenceChar = null;
      }
      blockEnd = nl;
    } else if (inDetails) {
      // A <details> section stays one block, blank lines included.
      if (closesDetails(line)) inDetails = false;
      blockEnd = nl;
    } else if (line.trim().isEmpty) {
      if (blockStart >= 0) sawBlank = true;
    } else {
      final continuesList =
          sawBlank &&
          blockIsList &&
          (line.startsWith(' ') || line.startsWith('\t'));
      if (blockStart >= 0 && sawBlank && !continuesList) {
        out.add((start: blockStart, end: blockEnd));
        blockStart = -1;
      }
      if (blockStart < 0) {
        blockStart = lineStart;
        blockIsList = _listItem.hasMatch(line);
      }
      sawBlank = false;
      blockEnd = nl;
      if (opensDetails(line) && !closesDetails(line)) inDetails = true;
      final m = _fenceOpen.firstMatch(line);
      if (m != null && !(m[2]![0] == '`' && m[3]!.contains('`'))) {
        fenceChar = m[2]![0];
        fenceLen = m[2]!.length;
      }
    }
    if (nl >= text.length) break;
    lineStart = nl + 1;
  }
  if (blockStart >= 0) out.add((start: blockStart, end: blockEnd));
  return out;
}

final _glyphBullet = RegExp(r'^(\s*)[•◦▪‣]\s+');

/// Lines that start with a bullet glyph (`•`, `◦`, `▪`, `‣`) become GFM list
/// items (`- `), keeping their indent. Hermes often writes such lines with
/// single newlines between them, which markdown would otherwise join into one
/// paragraph (round-2 device QA). Lines inside code fences are left alone.
String normalizeBulletGlyphs(String src) {
  if (!src.contains(RegExp('[•◦▪‣]'))) return src;
  final lines = src.split('\n');
  String? fence;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final f = _fenceOpen.firstMatch(line);
    if (fence != null) {
      if (line.trim().startsWith(fence)) fence = null;
      continue;
    }
    if (f != null) {
      fence = f[2]!;
      continue;
    }
    final m = _glyphBullet.firstMatch(line);
    if (m != null) lines[i] = '${m[1]}- ${line.substring(m.end)}';
  }
  return lines.join('\n');
}

/// Splits [text] into block strings (see [splitBlockRanges]).
List<String> splitBlocks(String text) => [
  for (final r in splitBlockRanges(text)) text.substring(r.start, r.end),
];

bool startsWithHeading(String block) => _heading.hasMatch(block);

bool endsWithHeading(String block) => _heading.hasMatch(block.split('\n').last);

/// Makes a partly received block render as if it were complete, so raw
/// markers never flicker (§5.3):
///
/// - an open code fence is closed (a half-typed closing fence or info string
///   is hidden);
/// - an unfinished link shows only its text, an unfinished image (or linked
///   image) nothing;
/// - a trailing line that is only a marker (`#`, `-`, `1.`, `>`, `|`, …) is
///   held back;
/// - a table is held back until its separator row covers every column;
/// - open `` ` ``, `**`, `*`, `_` and `~~` runs are closed, and a trailing
///   opener with nothing after it yet is held back.
String repairPartial(String block) {
  // A <details> section renders collapsed while it streams.
  if (opensDetails(block)) return block;
  var lines = block.split('\n');

  // Code fences.
  String? fChar;
  var fLen = 0;
  var fLine = -1;
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (fChar == null) {
      final m = _fenceOpen.firstMatch(l);
      if (m != null && !(m[2]![0] == '`' && m[3]!.contains('`'))) {
        fChar = m[2]![0];
        fLen = m[2]!.length;
        fLine = i;
      }
    } else {
      final t = l.trim();
      if (t.length >= fLen && t.split('').every((c) => c == fChar)) {
        fChar = null;
      }
    }
  }
  if (fChar != null) {
    final m = _fenceOpen.firstMatch(lines[fLine])!;
    if (fLine == lines.length - 1) {
      // The info string may still be arriving: wait for its newline. A
      // prefix of "hermes-ui" already shows the interactive placeholder.
      final info = m[3]!.trim();
      lines[fLine] = info.length >= 2 && 'hermes-ui'.startsWith(info)
          ? '${m[1]}${m[2]}hermes-ui'
          : info.length >= 2 && 'openui'.startsWith(info)
          ? '${m[1]}${m[2]}openui'
          : '${m[1]}${m[2]}';
    } else {
      final t = lines.last.trim();
      if (t.isNotEmpty && t.split('').every((c) => c == fChar)) {
        lines = lines.sublist(0, lines.length - 1);
      }
    }
    return '${lines.join('\n')}\n${m[1]}${m[2]}';
  }

  // Unfinished links and images on the last line. A half-typed footnote
  // reference or definition is held back.
  var last = lines.last;
  if (RegExp(r'^ {0,3}\[\^[^\]]*(\]:?)?\s*$').hasMatch(last)) last = '';
  // A linked image (`[![alt](src)](page)`) is held back whole until its
  // page link closes, so the card never shows stray brackets.
  last = last
      .replaceFirst(RegExp(r'\[!\[[^\]\n]*\]\([^)\n]*\)(\]\(?[^)\n]*)?$'), '')
      .replaceFirst(RegExp(r'\[\^[^\]\s]*$'), '')
      .replaceFirst(RegExp(r'!\[[^\]\n]*\]\([^)\n]*$'), '')
      .replaceFirst(RegExp(r'!\[[^\]\n]*\]?$'), '')
      .replaceFirstMapped(RegExp(r'\[([^\]\n]*)\]\([^)\n]*$'), (m) => m[1]!)
      .replaceFirstMapped(RegExp(r'\[(?!\^)([^\]\n]*)\]$'), (m) => m[1]!)
      .replaceFirstMapped(RegExp(r'\[(?!\^)([^\]\n]*)$'), (m) => m[1]!);
  lines[lines.length - 1] = last;

  // A trailing line holding only a marker.
  final t = lines.last.trim();
  final markerOnly = RegExp(
    r'^(#{1,6}|[-*+_]{1,2}|\d{1,9}[.)]|>+|\|[\s|:-]*|`{1,2}|~{1,2})$',
  ).hasMatch(t);
  final numberAfterItem =
      RegExp(r'^\d{1,9}$').hasMatch(t) &&
      lines.length > 1 &&
      _orderedItem.hasMatch(lines[lines.length - 2]);
  if (markerOnly || numberAfterItem || t.isEmpty) {
    lines = lines.sublist(0, lines.length - 1);
    if (lines.isEmpty) return '';
  }

  // A table without a complete separator row yet: hold the table back.
  final tableStart = lines.indexWhere((l) => l.trimLeft().startsWith('|'));
  if (tableStart >= 0) {
    final rest = lines.sublist(tableStart);
    var ok = false;
    if (rest.length > 1 &&
        RegExp(r'^\s*\|?\s*:?-+:?\s*(\|\s*:?-*:?\s*)*\|?\s*$')
            .hasMatch(rest[1])) {
      ok =
          _cells(rest[1]).every((c) => RegExp(r'^:?-+:?$').hasMatch(c)) &&
          _cells(rest[1]).length >= _cells(rest[0]).length;
    }
    if (!ok) lines = lines.sublist(0, tableStart);
  }
  if (lines.isEmpty) return '';

  return repairInlineHtml(_repairInline(lines.join('\n')));
}

List<String> _cells(String row) {
  var r = row.trim();
  if (r.startsWith('|')) r = r.substring(1);
  if (r.endsWith('|') && !r.endsWith(r'\|')) r = r.substring(0, r.length - 1);
  return r.split('|').map((c) => c.trim()).toList();
}

String _repairInline(String text) {
  // Inline code: an odd number of backticks means a span is still open.
  final ticks = '`'.allMatches(text).length;
  if (ticks.isOdd) {
    if (text.endsWith('`')) {
      return _repairInline(text.substring(0, text.length - 1));
    }
    text = '$text`';
  }

  // Mask code spans, URLs and link destinations with same-length filler so
  // offsets keep matching while their markers are ignored.
  final masked = text.replaceAllMapped(
    RegExp(r'`[^`]*`|https?://\S+|\]\([^)\n]*\)'),
    (m) => 'x' * m[0]!.length,
  );

  final stack = <String>[];
  var lastStart = -1, lastEnd = -1;
  var lastUsed = true;
  var i = 0;
  bool ws(int j) => j < 0 || j >= masked.length || masked[j].trim().isEmpty;
  bool word(int j) =>
      j >= 0 &&
      j < masked.length &&
      RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(masked[j]);
  while (i < masked.length) {
    final c = masked[i];
    if (c == r'\') {
      i += 2;
      continue;
    }
    String? tok;
    if (masked.startsWith('**', i)) {
      tok = '**';
    } else if (masked.startsWith('~~', i)) {
      tok = '~~';
    } else if (c == '*') {
      tok = '*';
    } else if (c == '_' && !(word(i - 1) && word(i + 1))) {
      tok = '_';
    }
    if (tok == null) {
      i++;
      continue;
    }
    final end = i + tok.length;
    final canOpen = end < masked.length && !ws(end);
    final canClose = !ws(i - 1);
    var used = false;
    if (canClose && stack.isNotEmpty && stack.last == tok) {
      stack.removeLast();
      used = true;
    } else if (canOpen && (tok != '_' || !word(i - 1))) {
      stack.add(tok);
      used = true;
    }
    lastStart = i;
    lastEnd = end;
    lastUsed = used;
    i = end;
  }
  // A marker at the very end that neither opens nor closes anything yet
  // (`foo **`, or the first `*` of a closing `**`): hold it back.
  if (!lastUsed && lastEnd == text.length && lastStart >= 0) {
    return _repairInline(text.substring(0, lastStart));
  }
  // A closer cannot follow whitespace ("**bold **" stays literal).
  if (stack.isNotEmpty) text = text.trimRight();
  for (final tok in stack.reversed) {
    text = '$text$tok';
  }
  return text;
}
