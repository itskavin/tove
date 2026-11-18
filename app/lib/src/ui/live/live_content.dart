import 'package:markdown/markdown.dart' as md;

import '../../call/call_controller.dart';
import '../../call/models.dart';
import '../../chat/chat.dart';
import '../markdown/hermes_markdown.dart' show linkHost, safeLink;
import '../thread/work_line.dart' show replyPresentation;
import 'live_activity.dart' show continuesInChatNote;

/// The clock live mode reads (elapsed times, card lingering). Replaced in
/// tests so goldens do not depend on wall time.
DateTime Function() liveNow = DateTime.now;

/// What a [LiveContent] came from.
enum LiveContentKind {
  /// A typed turn's reply during this live session.
  answer,

  /// A Hermes task delegated by the voice model.
  task,
}

/// Rich content shown in the live panel: a task result or a typed turn's
/// reply from this live session (spec §1, §2.3).
class LiveContent {
  const LiveContent({
    required this.id,
    required this.text,
    required this.time,
    this.streaming = false,
    this.kind = LiveContentKind.answer,
    this.title,
    this.failed = false,
    this.continuesInChat = false,
    this.seconds,
  });

  /// `task-<item id>` or `msg-<message id>`.
  final String id;

  /// Markdown. Empty while a task is still running.
  final String text;
  final DateTime time;

  /// More text may arrive (a reply streaming, a task running).
  final bool streaming;
  final LiveContentKind kind;

  /// A task's request, shown above its result.
  final String? title;

  /// The task failed; [text] is the reason.
  final bool failed;

  /// The call ended before the task finished; the result goes to the chat.
  final bool continuesInChat;

  /// How long a finished task took, when known.
  final int? seconds;

  /// Links in [text], as cards (see [extractSites]).
  List<LiveSite> get sites =>
      hasSourceIndex(text) ? const [] : extractSites(text);
}

LiveContent? _taskContent(TaskEntry t, {required bool includeRunning}) {
  final request = t.text.trim();
  switch (t.status) {
    case TaskStatus.done:
      // No markdown means Hermes returned no answer: that is not a result
      // (the work strip says so).
      final text = (t.markdown ?? '').trim();
      if (text.isEmpty) return null;
      return LiveContent(
        id: 'task-${t.itemId}',
        text: text,
        time: t.finished ?? t.created,
        kind: LiveContentKind.task,
        title: request.isEmpty ? null : request,
        seconds: t.seconds > 0 ? t.seconds : null,
      );
    case TaskStatus.starting:
    case TaskStatus.running:
      if (!includeRunning) return null;
      return LiveContent(
        id: 'task-${t.itemId}',
        text: '',
        time: t.created,
        streaming: true,
        kind: LiveContentKind.task,
        title: request.isEmpty ? null : request,
      );
    case TaskStatus.stopped:
      // The call ended first; the bridge finishes it and saves the result
      // to the linked chat, so this is not a failure.
      if (!includeRunning) return null;
      return LiveContent(
        id: 'task-${t.itemId}',
        text: continuesInChatNote,
        time: t.finished ?? t.created,
        kind: LiveContentKind.task,
        title: request.isEmpty ? null : request,
        continuesInChat: true,
      );
    case TaskStatus.failed:
    case TaskStatus.busy:
      if (!includeRunning) return null;
      return LiveContent(
        id: 'task-${t.itemId}',
        text: (t.detail ?? 'Hermes could not finish this').trim(),
        time: t.finished ?? t.created,
        kind: LiveContentKind.task,
        title: request.isEmpty ? null : request,
        failed: true,
      );
  }
}

/// A typed turn's reply as live content: its answer only. Text Hermes wrote
/// between tool steps belongs to the work, shown under the orb.
LiveContent _messageContent(ChatMessage m, ChatController chat) => LiveContent(
  id: 'msg-${m.id}',
  text: replyPresentation(m.text, chat.stepsFor(m)).answer,
  time: m.created,
  streaming: m.isStreaming,
);

/// The newest finished rich content since [since] (or [clearedAt], when the
/// user cleared the panel), or null: a delegated task's result, or the
/// answer of a typed turn's reply once its text starts. Running, failed and
/// handed-off tasks are work, not results; they stay under the orb.
LiveContent? liveContentFor({
  required CallController call,
  required ChatController chat,
  required DateTime since,
  DateTime? clearedAt,
}) {
  final after = clearedAt ?? since;
  LiveContent? best;
  void consider(LiveContent c) {
    if (c.time.isBefore(after)) return;
    if (best == null || !c.time.isBefore(best!.time)) best = c;
  }

  for (final t in call.tasks) {
    if (t.created.isBefore(since)) continue;
    final c = _taskContent(t, includeRunning: false);
    if (c != null) consider(c);
  }
  for (final m in chat.messages) {
    if (!m.isAssistant || m.source != MessageSource.text) continue;
    if (m.created.isBefore(since) || m.text.trim().isEmpty) continue;
    final c = _messageContent(m, chat);
    if (c.text.trim().isEmpty) continue;
    consider(c);
  }
  return best;
}

/// The content with [id] (a task in any state, or a typed reply), or null.
/// Used when the user expands a task card.
LiveContent? liveContentById(
  String id, {
  required CallController call,
  required ChatController chat,
}) {
  if (id.startsWith('task-')) {
    final item = id.substring(5);
    for (final t in call.tasks) {
      if (t.itemId == item) return _taskContent(t, includeRunning: true);
    }
  } else if (id.startsWith('msg-')) {
    final mid = id.substring(4);
    for (final m in chat.messages) {
      if (m.id == mid) return _messageContent(m, chat);
    }
  }
  return null;
}

// --- sites -----------------------------------------------------------------

/// A link in live content, shown as a tappable card.
class LiveSite {
  const LiveSite({required this.uri, required this.title, required this.host});

  final Uri uri;

  /// The link text, or a title made from the address.
  final String title;

  /// The host without `www.`.
  final String host;

  @override
  bool operator ==(Object other) =>
      other is LiveSite && other.uri == uri && other.title == title;

  @override
  int get hashCode => Object.hash(uri, title);

  @override
  String toString() => 'LiveSite($title, $uri)';
}

/// [markdown] without fenced code blocks (an open fence runs to the end).
String _withoutFences(String markdown) {
  final out = StringBuffer();
  String? fence;
  for (final line in markdown.split('\n')) {
    final t = line.trimLeft();
    if (fence == null) {
      if (t.startsWith('```') || t.startsWith('~~~')) {
        fence = t.substring(0, 3);
        continue;
      }
      out.writeln(line);
    } else if (t.startsWith(fence)) {
      fence = null;
    }
  }
  return out.toString();
}

final _bareUrl = RegExp(r'https?://[^\s<>()\[\]`"]+');

/// Links, images and code as markdown parses them, so nested forms such as a
/// linked image `[![alt](img)](page)` and escaped brackets come out right.
/// Footnote definitions are read as plain paragraphs: their links are the
/// reply's citations.
final _siteExtensions = md.ExtensionSet(
  const [md.FencedCodeBlockSyntax(), md.TableSyntax()],
  [md.StrikethroughSyntax(), md.AutolinkExtensionSyntax()],
);
final _footnoteDef = RegExp(r'^ {0,3}\[\^[^\]\n]+\]:[ \t]?', multiLine: true);

/// An explicit Sources/References section is already rendered by markdown.
/// Keep its links in place instead of repeating a second resource list.
bool hasSourceIndex(String markdown) => RegExp(
  r'^ {0,3}(?:#{1,6}\s+)?(?:\*\*)?(?:sources|references)(?:\*\*)?\s*(?::|$)',
  caseSensitive: false,
  multiLine: true,
).hasMatch(_withoutFences(markdown));

/// Links (http and https, not images) in [markdown], in order, without
/// duplicates, at most [max]. Code is skipped. A link's text is its title;
/// a bare address, or a link around only an image, gets a title made from
/// its path, else its host, until a later link to the same page names it.
List<LiveSite> extractSites(String markdown, {int max = 8}) {
  if (!markdown.contains('http')) return const [];
  final out = <LiveSite>[];
  final index = <String, int>{};
  final named = <String>{};

  void add(String href, String? label) {
    final uri = safeLink(href);
    if (uri == null || uri.scheme == 'mailto') return;
    // removeFragment, not replace(fragment: ''), which keeps a trailing '#'
    // and so never matched a page cited with and without its final slash.
    final key = uri.removeFragment().toString().replaceAll(RegExp(r'/$'), '');
    final host = linkHost(uri);
    var title = (label ?? '').replaceAll(RegExp(r'[*_`]'), '').trim();
    final hasName =
        title.isNotEmpty && safeLink(title) == null && title != host;
    if (!hasName) title = siteTitleFromUri(uri);
    final at = index[key];
    if (at != null) {
      // A page first seen behind an image takes its cited name.
      if (hasName && named.add(key)) {
        final s = out[at];
        out[at] = LiveSite(uri: s.uri, title: title, host: s.host);
      }
      return;
    }
    if (out.length >= max) return;
    index[key] = out.length;
    if (hasName) named.add(key);
    out.add(LiveSite(uri: uri, title: title, host: host));
  }

  void walk(List<md.Node> nodes) {
    for (final n in nodes) {
      if (n is md.Text) {
        for (final m in _bareUrl.allMatches(n.text)) {
          final href = m
              .group(0)!
              .replaceAll(RegExp(r'''[.,;:!?'"*_>]+$'''), '');
          add(href, null);
        }
      } else if (n is md.Element) {
        switch (n.tag) {
          case 'img' || 'code' || 'pre':
            continue; // An image is never a card; code is not a citation.
          case 'a':
            final href = n.attributes['href'];
            if (href != null) add(href, n.textContent);
          default:
            walk(n.children ?? const []);
        }
      }
    }
  }

  final source = markdown.replaceAll(_footnoteDef, '');
  final doc = md.Document(extensionSet: _siteExtensions, encodeHtml: false);
  walk(doc.parseLines(source.split('\n')));
  return out;
}

/// A readable title for a bare address: the last path segment
/// ("disk-usage-guide.html" → "Disk usage guide"), else the host.
String siteTitleFromUri(Uri uri) {
  final segs = uri.pathSegments.where((s) => s.trim().isNotEmpty).toList();
  if (segs.isNotEmpty) {
    var s = segs.last;
    try {
      s = Uri.decodeComponent(s);
    } catch (_) {}
    s = s.replaceAll(RegExp(r'\.(html?|php|aspx?)$', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'[-_+]+'), ' ').trim();
    final words = s.split(RegExp(r'\s+'));
    final looksLikeId =
        s.length < 3 ||
        RegExp(r'^[0-9a-f]{8,}$', caseSensitive: false).hasMatch(s);
    if (!looksLikeId && words.length <= 14 && s.length <= 90) {
      return s[0].toUpperCase() + s.substring(1);
    }
  }
  return linkHost(uri);
}
