/// GFM footnote citations as inline source chips (chat-rendering-v2 §1.11).
///
/// Hermes writes `…respectively.[^1][^2]` and puts the definitions at the end
/// (`[^1]: [Pricing](https://example.com/pricing) — Example Docs`). The
/// renderer parses per block, so the whole message is pre-scanned for
/// definitions ([scanFootnotes]); definition lines are hidden; consecutive
/// references render as one chip ("example.com +1") that opens a Sources
/// sheet. A reference whose definition has not arrived yet shows "Source".
library;

import 'package:markdown/markdown.dart' as md;
import 'package:material_ui/material_ui.dart';

import '../common/floating_sheet.dart';
import 'favicons.dart';
import 'links.dart';
import 'markdown_style.dart';

/// One footnote definition.
@immutable
class Footnote {
  const Footnote({
    required this.label,
    required this.title,
    this.url,
    this.note = '',
  });

  final String label;

  /// The link text, or the definition text without its URL.
  final String title;

  /// The first http(s) or mailto URL in the definition.
  final String? url;

  /// The rest of the definition (often the publisher).
  final String note;

  /// The host without `www.`, or null when there is no safe URL.
  String? get host {
    final u = url == null ? null : safeLink(url!);
    return u == null ? null : linkHost(u);
  }

  @override
  bool operator ==(Object other) =>
      other is Footnote &&
      other.label == label &&
      other.title == title &&
      other.url == url &&
      other.note == note;

  @override
  int get hashCode => Object.hash(label, title, url, note);
}

/// A definition line: `[^label]: text`.
final footnoteDefLine = RegExp(r'^ {0,3}\[\^([^\]\s]{1,40})\]:[ \t]*(.*)$');
final _mdLink = RegExp(r'\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)');
final _bareUrl = RegExp(r'(https?://[^\s<>()]+|mailto:[^\s<>()]+)');

/// All footnote definitions in [text], by label. Lines inside code fences
/// are ignored.
Map<String, Footnote> scanFootnotes(String text) {
  if (!text.contains('[^')) return const {};
  final out = <String, Footnote>{};
  var inFence = false;
  for (final line in text.split('\n')) {
    final t = line.trimLeft();
    if (t.startsWith('```') || t.startsWith('~~~')) inFence = !inFence;
    if (inFence) continue;
    final m = footnoteDefLine.firstMatch(line);
    if (m == null) continue;
    out[m[1]!] = parseFootnote(m[1]!, m[2]!);
  }
  return out;
}

/// Parses the text of one definition.
Footnote parseFootnote(String label, String raw) {
  var text = raw.trim();
  String? url;
  var title = '';
  final link = _mdLink.firstMatch(text);
  if (link != null) {
    url = link[2];
    title = link[1]!.trim();
    text = (text.substring(0, link.start) + text.substring(link.end)).trim();
  } else {
    final bare = _bareUrl.firstMatch(text);
    if (bare != null) {
      url = bare[0]!.replaceFirst(RegExp(r'[.,;:]+$'), '');
      text = (text.substring(0, bare.start) + text.substring(bare.end)).trim();
    }
  }
  final note = text
      .replaceFirst(RegExp(r'^[\s—–\-:|,·]+'), '')
      .replaceFirst(RegExp(r'[\s—–\-:|,·]+$'), '')
      .replaceAll(RegExp(r'[*_`]'), '')
      .trim();
  if (title.isEmpty) title = note;
  final f = Footnote(
    label: label,
    title: title,
    url: url,
    note: identical(title, note) || title == note ? '' : note,
  );
  if (f.title.isEmpty) {
    return Footnote(label: label, title: f.host ?? 'Source $label', url: url);
  }
  return f;
}

/// Removes footnote definition lines (and their indented continuation
/// lines) from a block outside code fences.
String stripFootnoteDefs(String block) {
  if (!block.contains('[^')) return block;
  final out = <String>[];
  var inFence = false;
  var inDef = false;
  for (final line in block.split('\n')) {
    final t = line.trimLeft();
    if (t.startsWith('```') || t.startsWith('~~~')) inFence = !inFence;
    if (!inFence && footnoteDefLine.hasMatch(line)) {
      inDef = true;
      continue;
    }
    if (inDef && line.isNotEmpty && line.startsWith('    ')) continue;
    inDef = false;
    out.add(line);
  }
  return out.join('\n');
}

/// The footnote labels referenced in [text].
Set<String> footnoteRefsIn(String text) => {
  for (final m in RegExp(r'\[\^([^\]\s]{1,40})\](?!:)').allMatches(text)) m[1]!,
};

/// `[^label]` → an `fnref` element with a `label` attribute and no text.
class FootnoteRefSyntax extends md.InlineSyntax {
  FootnoteRefSyntax()
    : super(r'\[\^([^\]\s]{1,40})\]', startCharacter: 0x5B /* [ */);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final e = md.Element.empty('fnref');
    e.attributes['label'] = match[1]!;
    parser.addNode(e);
    return true;
  }
}

/// A source chip (round 3, as in the reference): `surfaceHigh` stadium, the
/// first source's favicon (through the bridge, else its letter tile), its
/// publisher (the definition's note, else the host) cut at 96 dp, and "+N"
/// for the others. 24 dp tall in body text, 18 dp in captions; tappable
/// chips get a 48 dp hit target in height through their semantics only, so
/// the line never grows.
class SourceChip extends StatelessWidget {
  const SourceChip({
    super.key,
    required this.sources,
    required this.onLinkTap,
    this.style,
    this.small = false,
    this.opacity = 1,
  });

  /// One entry per reference; null where the definition has not arrived.
  final List<Footnote?> sources;
  final void Function(String href) onLinkTap;
  final MarkdownStyle? style;

  /// The caption variant (18 dp).
  final bool small;

  /// The streaming fade.
  final double opacity;

  String get _label => chipLabel(sources.firstOrNull);

  /// The chip text for [f]: a short publisher name, else the host.
  static String chipLabel(Footnote? f) {
    if (f == null) return 'Source';
    final note = f.note.trim();
    if (note.isNotEmpty && note.length <= 40 && !note.contains('http')) {
      return note;
    }
    return f.host ?? f.title;
  }

  @override
  Widget build(BuildContext context) {
    final s = style ?? MarkdownStyle.of(context);
    Color fade(Color c, [double k = 1]) =>
        c.withValues(alpha: c.a * opacity * k);
    final scaler = MediaQuery.textScalerOf(context);
    final h = scaler.scale(small ? 18 : 24);
    final ts = s.chip.copyWith(
      color: fade(s.textMuted),
      fontSize: small ? 11.5 : s.chip.fontSize,
      height: 1,
    );
    final more = sources.length - 1;
    final chip = Container(
      height: h,
      padding: EdgeInsets.symmetric(horizontal: small ? 7 : 10),
      decoration: ShapeDecoration(
        color: fade(s.surfaceHigh),
        shape: const StadiumBorder(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (sources.firstOrNull?.host case final host?)
            Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: SiteFavicon(
                host: host,
                size: scaler.scale(small ? 11 : 14),
              ),
            )
          else
            Icon(
              Icons.language_rounded,
              size: scaler.scale(small ? 11 : 14),
              color: fade(s.textMuted),
            ),
          SizedBox(width: small ? 3 : 5),
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: scaler.scale(96)),
              child: Text(
                _label,
                style: ts,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (more > 0)
            Text(' +$more', style: ts.copyWith(color: fade(s.textMuted, 0.7))),
        ],
      ),
    );
    final names = [
      for (final f in sources) f?.host ?? f?.title ?? 'pending source',
    ];
    // Its own node, flagged as a link: an inline citation is a link in
    // running text (exempt from the 48 dp target like other inline links),
    // and its tap never merges into the paragraph's node.
    return Semantics(
      container: true,
      link: true,
      label: 'Sources: ${names.join(', ')}',
      excludeSemantics: true,
      onTap: () => showSourcesSheet(context, sources, onLinkTap, style: s),
      child: SelectionContainer.disabled(
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                showSourcesSheet(context, sources, onLinkTap, style: s),
            child: chip,
          ),
        ),
      ),
    );
  }
}

/// The Sources sheet: one 72 dp row per source (favicon, title, host and
/// note). Tapping a row opens the link confirm.
Future<void> showSourcesSheet(
  BuildContext context,
  List<Footnote?> sources,
  void Function(String href) onLinkTap, {
  MarkdownStyle? style,
}) {
  final known = sources.whereType<Footnote>().toSet().toList();
  return showFloatingSheet<void>(
    context,
    page: SheetPage(
      title: 'Sources',
      builder: (context) {
        final s = style ?? MarkdownStyle.of(context);
        if (known.isEmpty) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Text(
              'The source details are still arriving.',
              style: s.caption,
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < known.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: s.hairline,
                    indent: 56,
                  ),
                _SourceRow(
                  source: known[i],
                  style: s,
                  onTap: known[i].host == null
                      ? null
                      : () {
                          Navigator.of(context).pop();
                          onLinkTap(known[i].url!);
                        },
                ),
              ],
            ],
          ),
        );
      },
    ),
  );
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.source, required this.style, this.onTap});
  final Footnote source;
  final MarkdownStyle style;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = style;
    final sub = [
      if (source.host != null) source.host!,
      if (source.note.isNotEmpty) source.note,
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 72),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            children: [
              if (source.host case final host?)
                SiteFavicon(host: host, size: 24)
              else
                Icon(Icons.language_rounded, size: 24, color: s.textMuted),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.title,
                      style: s.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (sub.isNotEmpty)
                      Text(
                        sub,
                        style: s.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
