/// `hermes-artifact` fences (round 6 B6, hermes-ui-prompt.md "Round 6"): a
/// program, script, config file, email or long draft as one card with its
/// title, a kind or language chip, the first lines fading out, Copy, Share
/// and Expand (full screen, highlighted, with a wrap toggle). Email and
/// draft kinds read as text, not code.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../thread/message_actions.dart';
import 'email_card.dart';
import 'markdown_style.dart';

/// The fence's info string.
const hermesArtifactInfo = 'hermes-artifact';

enum ArtifactKind {
  code('Code', Icons.code_rounded),
  script('Script', Icons.terminal_rounded),
  config('Config', Icons.settings_suggest_outlined),
  email('Email', Icons.mail_outline_rounded),
  draft('Draft', Icons.edit_note_rounded),
  document('Document', Icons.description_outlined);

  const ArtifactKind(this.label, this.icon);
  final String label;
  final IconData icon;

  /// Prose kinds read as text, not code.
  bool get prose => this == email || this == draft || this == document;

  static ArtifactKind parse(Object? v) => values.firstWhere(
    (k) => k.name == v,
    orElse: () => ArtifactKind.document,
  );
}

/// One parsed artifact: line 1 is a JSON header, the rest is the content.
@immutable
class Artifact {
  const Artifact({
    required this.title,
    required this.kind,
    required this.lang,
    required this.content,
    this.file,
    this.subject,
    this.to = const [],
  });

  final String title;
  final ArtifactKind kind;

  /// A highlighter language, or `text` / `markdown` for prose.
  final String lang;
  final String content;

  /// A sanitised file name for Share, or null.
  final String? file;

  /// An email's subject: the header's `subject`, else a `Subject:` line
  /// taken out of [content].
  final String? subject;

  /// An email's recipients (header `to` or `recipients`: names or
  /// addresses, a list or one string).
  final List<String> to;

  /// Reads like text: a prose kind, or a `text`/`markdown` language.
  bool get prose => kind.prose || lang == 'text' || lang == 'markdown';

  /// What Read aloud says instead of the content.
  String get speakable => '$title (${kind.label.toLowerCase()})';

  /// Null when line 1 is not a JSON object with a string `title`; the
  /// caller then shows the body as an ordinary code block.
  static Artifact? parse(String body) {
    final nl = body.indexOf('\n');
    final head = nl < 0 ? body : body.substring(0, nl);
    var content = nl < 0 ? '' : body.substring(nl + 1);
    final Object? j;
    try {
      j = jsonDecode(head.trim());
    } on FormatException {
      return null;
    }
    if (j is! Map || j['title'] is! String) return null;
    final title = (j['title'] as String).trim();
    if (title.isEmpty) return null;
    final kind = ArtifactKind.parse(j['kind']);
    final lang = j['lang'] is String && (j['lang'] as String).trim().isNotEmpty
        ? (j['lang'] as String).trim().toLowerCase()
        : 'text';
    String? subject;
    var to = const <String>[];
    if (kind == ArtifactKind.email) {
      final head = j['subject'];
      if (head is String && head.trim().isNotEmpty) {
        subject = head.trim();
      }
      final m = RegExp(r'^Subject:[ \t]*(.*)\r?\n(?:\r?\n)?')
          .firstMatch(content);
      if (m != null) {
        subject ??= m[1]!.trim();
        content = content.substring(m.end);
      }
      final r = j['to'] ?? j['recipients'];
      to = [
        for (final v in r is List ? r : [r])
          if (v is String && v.trim().isNotEmpty)
            v.trim().length > 120 ? v.trim().substring(0, 120) : v.trim(),
      ].take(20).toList();
    }
    return Artifact(
      title: title.length > 80 ? '${title.substring(0, 79)}…' : title,
      kind: kind,
      lang: lang,
      content: content,
      file: sanitiseFileName(j['file']),
      subject: subject,
      to: to,
    );
  }
}

/// A safe file name: no path, no control or reserved characters, at most
/// 80 characters; null when nothing is left.
String? sanitiseFileName(Object? v) {
  if (v is! String) return null;
  var name = v.split(RegExp(r'[\\/]')).last;
  name = name.replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '').trim();
  name = name.replaceFirst(RegExp(r'^\.+'), '');
  if (name.isEmpty) return null;
  return name.length > 80 ? name.substring(name.length - 80) : name;
}

/// The artifact card in a reply. While [complete] is false (the fence is
/// still streaming) it shows a skeleton under whatever header has arrived.
class ArtifactCard extends StatelessWidget {
  const ArtifactCard({
    super.key,
    required this.body,
    required this.complete,
    required this.style,
  });

  final String body;
  final bool complete;
  final MarkdownStyle style;

  /// Lines shown before the fade.
  static const previewLines = 8;

  @override
  Widget build(BuildContext context) {
    final a = Artifact.parse(body);
    final s = style;
    if (!complete) return _Skeleton(artifact: a, style: s);
    // Round 8: an email reads as an email (the reference's card).
    if (a!.kind == ArtifactKind.email) return EmailCard(artifact: a, style: s);
    final shown = a.content.split('\n').take(previewLines).join('\n');
    final more = a.content.split('\n').length > previewLines;
    return Semantics(
      container: true,
      label: '${a.kind.label}, ${a.title}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: s.surface,
          borderRadius: BorderRadius.circular(s.codeBlockRadius),
          border: Border.all(color: s.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _Header(artifact: a, style: s),
            InkWell(
              onTap: () => openArtifact(context, a, s),
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (r) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black,
                    more ? Colors.transparent : Colors.black,
                  ],
                  stops: const [0.55, 1],
                ).createShader(r),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    s.codeBlockPadding,
                    4,
                    s.codeBlockPadding,
                    12,
                  ),
                  child: ExcludeSemantics(
                    child: Text.rich(
                      a.prose
                          ? TextSpan(text: shown)
                          : highlight(shown, a.lang, s),
                      style: a.prose ? s.body : s.code,
                      maxLines: previewLines,
                      overflow: TextOverflow.clip,
                      softWrap: a.prose,
                    ),
                  ),
                ),
              ),
            ),
            _Actions(artifact: a, style: s),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.artifact, required this.style});
  final Artifact artifact;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final a = artifact;
    final s = style;
    final chip = a.prose ? a.kind.label : a.lang;
    return Padding(
      padding: EdgeInsets.fromLTRB(s.codeBlockPadding, 12, 12, 4),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: s.surfaceHigh,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(a.kind.icon, size: 18, color: s.textMuted),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  a.title,
                  style: s.widgetLabel,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (a.subject != null || a.file != null)
                  Text(
                    a.subject ?? a.file!,
                    style: s.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: s.surfaceHigh,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(chip, style: s.caption),
          ),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.artifact, required this.style});
  final Artifact artifact;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final s = style;
    Widget button(String label, IconData icon, VoidCallback onTap) =>
        TextButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 16, color: s.textMuted),
          label: Text(label, style: s.label),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
        );
    return SelectionContainer.disabled(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
        child: Row(
          children: [
            button(
              'Copy',
              Icons.copy_rounded,
              () => copyArtifact(context, artifact),
            ),
            button(
              'Share',
              Icons.ios_share_rounded,
              () => shareArtifact(context, artifact),
            ),
            const Spacer(),
            button(
              'Expand',
              Icons.open_in_full_rounded,
              () => openArtifact(context, artifact, s),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> copyArtifact(BuildContext context, Artifact a) async {
  final actions = MessageActions.of(context);
  await Clipboard.setData(ClipboardData(text: a.content));
  actions?.notify('Copied');
}

/// Shares the content as text (the shell's share sheet; a copy without
/// one). Sharing as the named file needs a file-share adapter in
/// [MessageActions]; until then the file name heads the shared text.
Future<void> shareArtifact(BuildContext context, Artifact a) async {
  final actions = MessageActions.of(context);
  if (actions == null) {
    await Clipboard.setData(ClipboardData(text: a.content));
    return;
  }
  await actions.share(a.content);
}

/// Opens [a] full screen.
Future<void> openArtifact(BuildContext context, Artifact a, MarkdownStyle s) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ArtifactPage(artifact: a, style: s),
      ),
    );

/// The artifact full screen: highlighted, wrap toggle, Copy and Share.
class ArtifactPage extends StatefulWidget {
  const ArtifactPage({super.key, required this.artifact, required this.style});
  final Artifact artifact;
  final MarkdownStyle style;

  @override
  State<ArtifactPage> createState() => _ArtifactPageState();
}

class _ArtifactPageState extends State<ArtifactPage> {
  late bool _wrap = widget.artifact.prose;

  @override
  Widget build(BuildContext context) {
    final a = widget.artifact;
    final s = widget.style;
    final text = Text.rich(
      a.prose ? TextSpan(text: a.content) : highlight(a.content, a.lang, s),
      style: a.prose ? s.body : s.code,
      softWrap: _wrap,
    );
    return Scaffold(
      backgroundColor: s.background,
      appBar: AppBar(
        backgroundColor: s.background,
        title: Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: _wrap ? 'Don’t wrap lines' : 'Wrap lines',
            isSelected: _wrap,
            icon: const Icon(Icons.wrap_text_rounded),
            onPressed: () => setState(() => _wrap = !_wrap),
          ),
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy_rounded),
            onPressed: () => copyArtifact(context, a),
          ),
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: () => shareArtifact(context, a),
          ),
        ],
      ),
      body: SafeArea(
        child: SelectionArea(
          child: Scrollbar(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: _wrap
                  ? text
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: text,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton({required this.artifact, required this.style});
  final Artifact? artifact;
  final MarkdownStyle style;

  @override
  Widget build(BuildContext context) {
    final s = style;
    Widget bar(double f) => FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: f,
      child: Container(
        height: 10,
        margin: const EdgeInsets.only(top: 10),
        decoration: BoxDecoration(
          color: s.surfaceHigh,
          borderRadius: BorderRadius.circular(5),
        ),
      ),
    );
    return Semantics(
      container: true,
      label: 'Writing ${artifact?.title ?? 'an artifact'}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: s.surface,
          borderRadius: BorderRadius.circular(s.codeBlockRadius),
          border: Border.all(color: s.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (artifact != null)
              _Header(artifact: artifact!, style: s)
            else
              Padding(
                padding: EdgeInsets.fromLTRB(s.codeBlockPadding, 14, 12, 0),
                child: bar(0.4),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                s.codeBlockPadding,
                0,
                s.codeBlockPadding,
                16,
              ),
              child: Column(children: [bar(0.9), bar(0.75), bar(0.6)]),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ highlighting

const _keywords = {
  'abstract',
  'as',
  'async',
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'def',
  'default',
  'do',
  'done',
  'elif',
  'else',
  'enum',
  'esac',
  'except',
  'export',
  'extends',
  'false',
  'fi',
  'final',
  'finally',
  'fn',
  'for',
  'from',
  'func',
  'function',
  'if',
  'import',
  'in',
  'interface',
  'is',
  'lambda',
  'let',
  'local',
  'match',
  'mut',
  'new',
  'nil',
  'None',
  'not',
  'null',
  'of',
  'or',
  'and',
  'package',
  'pass',
  'private',
  'protected',
  'pub',
  'public',
  'raise',
  'return',
  'self',
  'static',
  'struct',
  'super',
  'switch',
  'then',
  'this',
  'throw',
  'true',
  'True',
  'False',
  'try',
  'type',
  'use',
  'val',
  'var',
  'void',
  'while',
  'with',
  'yield',
  'echo',
  'select',
  'where',
  'SELECT',
  'FROM',
  'WHERE',
};

/// A small built-in highlighter (no dependency): comments, strings,
/// numbers and common keywords, in the theme's own colours. Good enough to
/// read; it does not parse.
TextSpan highlight(String code, String lang, MarkdownStyle s) {
  final hash = const {
    'bash',
    'sh',
    'shell',
    'zsh',
    'python',
    'py',
    'yaml',
    'yml',
    'toml',
    'ruby',
    'rb',
    'perl',
    'r',
    'dockerfile',
    'make',
    'makefile',
    'ini',
    'conf',
    'nginx',
    'powershell',
    'ps1',
  }.contains(lang);
  final comment = hash ? r'#[^\n]*' : r'//[^\n]*|/\*[\s\S]*?\*/';
  final re = RegExp(
    '(?<c>$comment)'
    r'|(?<s>"(?:\\.|[^"\\\n])*"|'
    "'(?:\\\\.|[^'\\\\\\n])*')"
    r'|(?<n>\b\d+(?:\.\d+)?\b)'
    r'|(?<w>\b[A-Za-z_]\w*\b)',
  );
  final kw = s.code.copyWith(fontWeight: FontWeight.w700);
  final str = s.code.copyWith(color: s.success);
  final num = s.code.copyWith(color: s.warning);
  final com = s.code.copyWith(color: s.textMuted, fontStyle: FontStyle.italic);
  final out = <InlineSpan>[];
  var at = 0;
  for (final m in re.allMatches(code)) {
    if (m.start > at) out.add(TextSpan(text: code.substring(at, m.start)));
    final text = m[0]!;
    final TextStyle? style = m.namedGroup('c') != null
        ? com
        : m.namedGroup('s') != null
        ? str
        : m.namedGroup('n') != null
        ? num
        : _keywords.contains(text)
        ? kw
        : null;
    out.add(TextSpan(text: text, style: style));
    at = m.end;
  }
  if (at < code.length) out.add(TextSpan(text: code.substring(at)));
  return TextSpan(children: out);
}
