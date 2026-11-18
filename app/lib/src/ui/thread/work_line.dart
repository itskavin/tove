import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../chat/chat.dart';
import '../common/shimmer.dart';
import '../markdown/hermes_markdown.dart';
import 'message_markdown.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';

// ---------------------------------------------------------------------------
// Words

/// A connector or MCP tool, split into its service and action:
/// `connectors__notion__SEARCH_NOTION_PAGE` → (notion, SEARCH_NOTION_PAGE),
/// `mcp_github_create_issue` → (github, create_issue). Null for Hermes' own
/// tools.
({String service, String action})? connectorTool(String tool) {
  final id = tool.trim();
  if (id.contains('__')) {
    final parts = id.split('__').where((p) => p.isNotEmpty).toList();
    if (parts.isNotEmpty &&
        const {
          'connectors',
          'connector',
          'mcp',
        }.contains(parts.first.toLowerCase())) {
      parts.removeAt(0);
    }
    if (parts.length >= 2) {
      return (service: parts.first, action: parts.skip(1).join('_'));
    }
    return null;
  }
  if (id.startsWith('mcp_')) {
    final rest = id.substring(4);
    final cut = rest.indexOf('_');
    if (cut > 0 && cut < rest.length - 1) {
      return (service: rest.substring(0, cut), action: rest.substring(cut + 1));
    }
  }
  return null;
}

const _serviceNames = {
  'notion': 'Notion',
  'github': 'GitHub',
  'gitlab': 'GitLab',
  'gmail': 'Gmail',
  'googlecalendar': 'Google Calendar',
  'googledrive': 'Google Drive',
  'googledocs': 'Google Docs',
  'googlesheets': 'Google Sheets',
  'slack': 'Slack',
  'linear': 'Linear',
  'todoist': 'Todoist',
  'spotify': 'Spotify',
  'youtube': 'YouTube',
  'homeassistant': 'Home Assistant',
};

/// "Notion", "Google Calendar", "Home Assistant".
String serviceName(String service) {
  final key = service.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return _serviceNames[key] ?? _titleWords(service);
}

// Actions whose plain words read badly ("Fetch block contents").
const _actionNames = {
  'search page': 'Search pages',
  'search pages': 'Search pages',
  'search': 'Search',
  'fetch block contents': 'Read page',
  'fetch all block contents': 'Read page',
  'fetch block content': 'Read page',
  'get block children': 'Read page',
  'fetch page': 'Read page',
  'get page': 'Read page',
  'retrieve page': 'Read page',
  'fetch data': 'Read data',
  'append block children': 'Add to page',
  'add page content': 'Add to page',
  'create page': 'Create page',
  'update page': 'Update page',
  'query database': 'Query database',
  'fetch database': 'Read database',
};

/// "Search pages" for SEARCH_NOTION_PAGE (the service's own name is dropped).
String actionName(String action, {String? service}) {
  final svc = service?.toLowerCase();
  final words = action
      .split(RegExp(r'[\s_\-.]+'))
      .map((w) => w.toLowerCase())
      .where((w) => w.isNotEmpty && w != svc)
      .toList();
  if (words.isEmpty) return 'Action';
  return _actionNames[words.join(' ')] ?? _sentence(words);
}

/// Plain names for Hermes' tools; connectors read "Notion · Search pages";
/// unknown ones read from their id, without shouting capitals.
String toolName(String tool) {
  final id = tool.trim();
  final known = switch (id) {
    'terminal' || 'shell' || 'bash' => 'Terminal',
    'process' => 'Process',
    'execute_code' || 'python' => 'Run code',
    'web_search' || 'search' => 'Web search',
    'image_search' => 'Image search',
    'tool_search' || 'tool_describe' => 'Looking up tools',
    'session_search' => 'Searching past chats',
    'skill_view' => 'Read skill',
    'skills_list' => 'List skills',
    'skill_manage' => 'Update skill',
    'web_extract' || 'web_fetch' || 'fetch' => 'Read page',
    'read_file' => 'Read file',
    'write_file' => 'Write file',
    'patch' || 'edit_file' => 'Edit file',
    'search_files' => 'Search files',
    'delegate_task' => 'Delegate',
    'memory' => 'Memory',
    'todo' => 'To-do list',
    'clarify' => 'Question',
    'vision_analyze' => 'Look at image',
    'image_generate' => 'Make image',
    'send_message' => 'Send message',
    'cronjob' => 'Schedule',
    'approval' => 'Approval',
    'tool_call' => 'Tool',
    _ => null,
  };
  if (known != null) return known;
  final c = connectorTool(id);
  if (c != null) {
    return '${serviceName(c.service)} · '
        '${actionName(c.action, service: c.service)}';
  }
  if (id.startsWith('browser')) return 'Browser';
  if (id.startsWith('skill')) return 'Skill';
  if (id.isEmpty) return 'Tool';
  return _sentence(_split(id));
}

/// What a running tool is doing, for the one-line glimpse.
String toolActivity(String tool) {
  final id = tool.trim();
  final known = switch (id) {
    'terminal' || 'shell' || 'bash' => 'Running terminal',
    'process' => 'Checking a process',
    'execute_code' || 'python' => 'Running code',
    'web_search' || 'search' => 'Searching the web',
    'image_search' => 'Searching images',
    'tool_search' || 'tool_describe' => 'Looking up tools',
    'session_search' => 'Searching past chats',
    'skill_view' || 'skills_list' => 'Reading a skill',
    'web_extract' || 'web_fetch' || 'fetch' => 'Reading a page',
    'read_file' => 'Reading file',
    'write_file' => 'Writing file',
    'patch' || 'edit_file' => 'Editing file',
    'search_files' => 'Searching files',
    'delegate_task' => 'Delegating',
    'memory' => 'Checking memory',
    'todo' => 'Updating the to-do list',
    'clarify' => 'Asking a question',
    'vision_analyze' => 'Looking at the image',
    'image_generate' => 'Making an image',
    'send_message' => 'Sending a message',
    'cronjob' => 'Scheduling',
    'approval' => 'Waiting for approval',
    _ => null,
  };
  if (known != null) return known;
  final c = connectorTool(id);
  if (c != null) return 'Using ${serviceName(c.service)}';
  if (id.startsWith('browser')) return 'Using the browser';
  if (id.startsWith('skill')) return 'Using a skill';
  return 'Running ${toolName(id).toLowerCase()}';
}

IconData toolIcon(String tool) {
  final id = tool.trim();
  return switch (id) {
    'terminal' || 'shell' || 'bash' || 'process' => Icons.terminal_rounded,
    'execute_code' || 'python' => Icons.code_rounded,
    'web_search' || 'search' => Icons.travel_explore_rounded,
    'image_search' => Icons.image_search_rounded,
    'tool_search' || 'tool_describe' => Icons.manage_search_rounded,
    'session_search' => Icons.history_rounded,
    'web_extract' || 'web_fetch' || 'fetch' => Icons.public_rounded,
    'read_file' || 'search_files' => Icons.description_outlined,
    'write_file' || 'patch' || 'edit_file' => Icons.edit_outlined,
    'delegate_task' => Icons.call_split_rounded,
    'memory' => Icons.bookmark_border_rounded,
    'todo' => Icons.checklist_rounded,
    'clarify' => Icons.help_outline_rounded,
    'vision_analyze' || 'image_generate' => Icons.image_outlined,
    'send_message' => Icons.send_outlined,
    'cronjob' => Icons.schedule_rounded,
    'approval' => Icons.pan_tool_outlined,
    _ when id.startsWith('skill') => Icons.menu_book_outlined,
    _ when id.startsWith('browser') => Icons.public_rounded,
    _ when connectorTool(id) != null => Icons.extension_outlined,
    _ => Icons.build_outlined,
  };
}

List<String> _split(String id) =>
    id.split(RegExp(r'[\s_\-.]+')).where((w) => w.isNotEmpty).toList();

// Kept in capitals when they appear in a tool name.
const _acronyms = {
  'api', 'url', 'id', 'pdf', 'sql', 'dns', 'ssh', 'http', 'https', 'json', //
  'csv', 'html', 'ip', 'ai', 'ui', 'cpu', 'gpu', 'ram', 'smb', 'nas', 'vm',
};

/// "Fetch block contents": the first word capitalised, capitals that only
/// shout lowered, acronyms kept.
String _sentence(List<String> words) {
  if (words.isEmpty) return 'Tool';
  final out = <String>[];
  for (final (i, w) in words.indexed) {
    final lower = w.toLowerCase();
    if (_acronyms.contains(lower)) {
      out.add(lower.toUpperCase());
    } else {
      // A word in capitals is shouting; mixed case (iPhone, GitHub) stays.
      final plain = w == w.toUpperCase() ? lower : w;
      out.add(i == 0 ? plain[0].toUpperCase() + plain.substring(1) : plain);
    }
  }
  return out.join(' ');
}

String _titleWords(String id) {
  final words = _split(id);
  if (words.isEmpty) return 'Tool';
  return words
      .map((w) {
        final lower = w.toLowerCase();
        if (_acronyms.contains(lower)) return lower.toUpperCase();
        return lower[0].toUpperCase() + lower.substring(1);
      })
      .join(' ');
}

/// "12s", "1m 05s".
String shortDuration(Duration d) {
  final s = d.inMilliseconds < 1000 ? 1 : (d.inMilliseconds / 1000).round();
  if (s < 60) return '${s}s';
  return '${s ~/ 60}m ${(s % 60).toString().padLeft(2, '0')}s';
}

/// "12 seconds", "1 minute 5 seconds", for screen readers.
String spokenDuration(Duration d) {
  final s = d.inMilliseconds < 1000 ? 1 : (d.inMilliseconds / 1000).round();
  String unit(int n, String w) => '$n $w${n == 1 ? '' : 's'}';
  if (s < 60) return unit(s, 'second');
  final r = s % 60;
  return r == 0
      ? unit(s ~/ 60, 'minute')
      : '${unit(s ~/ 60, 'minute')} ${unit(r, 'second')}';
}

final _summaryTitle = RegExp(
  r'^\s*\*\*([^*\n]{1,80})\*\*\s*$',
  multiLine: true,
);

/// The newest `**Title**` line of a thinking step's text: reasoning summaries
/// come titled that way ("**Reviewing coding request**"). Null when the text
/// has none; other thinking text is never shortened into a title.
String? thinkingTitle(String text) {
  final titles = _summaryTitle.allMatches(text);
  if (titles.isEmpty) return null;
  final t = titles.last[1]!.trim();
  return t.isEmpty ? null : t;
}

/// The glimpse while the reply works: the newest running step (a thinking
/// step by its summary title, as sent), Hermes' lifecycle notes (a provider
/// wait, an approval) as sent, else "Thinking".
String workGlimpse(List<ReplyStep> steps, ChatProgress? progress) {
  for (final s in steps.reversed) {
    if (!s.running) continue;
    if (s.kind == StepKind.thinking) return thinkingTitle(s.text) ?? 'Thinking';
    return toolActivity(s.tool?.shownName ?? '');
  }
  final label = progress?.label.trim() ?? '';
  if (label.isNotEmpty &&
      (progress!.state == ProgressState.info ||
          progress.state == ProgressState.approval)) {
    return label;
  }
  return 'Thinking';
}

/// How long the reply worked: from its start (when known and plausible) or
/// its first step to the end of its last step.
Duration workDuration(List<ReplyStep> steps, {DateTime? replyStart}) {
  if (steps.isEmpty) return Duration.zero;
  var first = steps.first.started;
  var last = steps.first.ended ?? steps.first.started;
  for (final s in steps) {
    if (s.started.isBefore(first)) first = s.started;
    final e = s.ended ?? s.started;
    if (e.isAfter(last)) last = e;
  }
  if (replyStart != null &&
      replyStart.isBefore(first) &&
      first.difference(replyStart) < const Duration(minutes: 10)) {
    first = replyStart;
  }
  final d = last.difference(first);
  return d.isNegative ? Duration.zero : d;
}

/// "Worked for 12s" when tools ran, "Thought for 12s" otherwise.
String workSummary(List<ReplyStep> steps, Duration d, {bool spoken = false}) {
  final verb = steps.any((s) => s.isTool) ? 'Worked' : 'Thought';
  return '$verb for ${spoken ? spokenDuration(d) : shortDuration(d)}';
}

final _leadingBlankLines = RegExp(r'^(?:[ \t]*\r?\n)+');

/// Bridge offsets count Unicode code points, while Dart strings use UTF-16.
/// Only text preceding a tool belongs to the activity disclosure. Everything
/// after the final tool stays in the answer, including on older bridges.
/// Blank lines that open a reply (Hermes writes "\n\n" first; replies saved
/// before the bridge dropped them still have it) are not part of the answer.
({String activity, String answer}) replyPresentation(
  String text,
  List<ReplyStep> steps,
) {
  var offset = 0;
  final length = text.runes.length;
  for (final step in steps) {
    if (step.offset > offset && step.offset <= length) offset = step.offset;
  }
  if (offset == 0) {
    return (activity: '', answer: text.replaceFirst(_leadingBlankLines, ''));
  }
  final runes = text.runes.toList();
  final activity = String.fromCharCodes(runes.take(offset)).trim();
  final answer = String.fromCharCodes(runes.skip(offset)).trimLeft();
  // A stopped/failed turn can have only a preamble: retain it in the timeline.
  return (activity: activity, answer: answer);
}

// ---------------------------------------------------------------------------
// The line

/// One quiet line above a reply (ChatGPT-style): a shimmering glimpse of what
/// is running while the reply works ("Thinking", "Running terminal"), then
/// "Worked for 12s". Tapping it opens the timeline of thinking and tool
/// steps in place. No box, no border.
class WorkLine extends StatefulWidget {
  const WorkLine({
    super.key,
    required this.steps,
    required this.working,
    this.progress,
    this.replyStart,
    this.now,
    this.initiallyExpanded = false,
    this.replyText = '',
  });

  final List<ReplyStep> steps;

  /// The reply is still working (nothing written yet, a step running, or a
  /// lifecycle note showing): the glimpse shows instead of the summary.
  final bool working;
  final ChatProgress? progress;

  /// When the reply started, for the summary's duration.
  final DateTime? replyStart;

  /// For tests: a fixed clock.
  final DateTime Function()? now;
  final bool initiallyExpanded;
  final String replyText;

  @override
  State<WorkLine> createState() => _WorkLineState();
}

class _WorkLineState extends State<WorkLine> {
  late bool _open = widget.initiallyExpanded;
  Timer? _tick;

  bool get _ticking =>
      _open && widget.now == null && widget.steps.any((s) => s.running);

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(WorkLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  /// Durations of running steps tick once a second, only while open.
  void _sync() {
    if (_ticking) {
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _toggle() {
    setState(() => _open = !_open);
    _sync();
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final now = (widget.now ?? DateTime.now)();
    final steps = widget.steps;
    final working = widget.working;
    final canOpen = steps.isNotEmpty;
    final d = workDuration(steps, replyStart: widget.replyStart);
    final text = working
        ? workGlimpse(steps, widget.progress)
        : workSummary(steps, d);
    final spoken = working ? text : workSummary(steps, d, spoken: true);
    final style = t.label.hermesSize(15, line: 22);
    final line = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (working && steps.any((s) => s.isTool && s.running)) ...[
          Icon(
            toolIcon(
              steps.lastWhere((s) => s.isTool && s.running).tool?.shownName ??
                  '',
            ),
            size: 16,
            color: t.textMuted,
          ),
          const SizedBox(width: 7),
        ],
        Flexible(
          child: working
              ? ShimmerText(text, style: style)
              : Text(text, style: style.copyWith(color: t.textMuted)),
        ),
        if (canOpen) ...[
          const SizedBox(width: 2),
          AnimatedRotation(
            turns: _open ? 0.25 : 0,
            duration: Motion.of(context, const Duration(milliseconds: 200)),
            curve: Motion.standard,
            child: Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: t.textFaint,
            ),
          ),
        ],
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Semantics(
            key: const ValueKey('work-line'),
            container: true,
            button: canOpen,
            expanded: canOpen ? _open : null,
            liveRegion: working,
            label: spoken,
            onTapHint: canOpen ? (_open ? 'collapse' : 'expand') : null,
            onTap: canOpen ? _toggle : null,
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: canOpen ? _toggle : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Align(
                  alignment: Alignment.centerLeft,
                  widthFactor: 1,
                  child: line,
                ),
              ),
            ),
          ),
        ),
        _Reveal(
          duration: const Duration(milliseconds: 240),
          child: _open && canOpen
              ? Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: StepTimeline(
                    steps: steps,
                    now: now,
                    replyText: widget.replyText,
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
        if (!_open && working && widget.replyText.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 12),
            child: MessageMarkdown(
              text: replyPresentation(widget.replyText, steps).activity,
              streaming: true,
            ),
          ),
      ],
    );
  }
}

/// Opens and closes its child with a smooth height animation; with reduced
/// motion it changes at once (no zero-length AnimatedSize, which re-dirties
/// itself during layout).
class _Reveal extends StatelessWidget {
  const _Reveal({required this.duration, required this.child});
  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (Motion.reduced(context)) return child;
    return ClipRect(
      child: AnimatedSize(
        duration: duration,
        curve: Motion.emphasizedDecel,
        alignment: Alignment.topLeft,
        child: child,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The timeline

/// The reply's steps in order: thinking text in muted type, and one row per
/// tool (icon, name, short descriptor, duration) that opens its input and
/// output. A faint rail joins the entries.
class StepTimeline extends StatelessWidget {
  const StepTimeline({
    super.key,
    required this.steps,
    required this.now,
    this.replyText = '',
  });

  final List<ReplyStep> steps;
  final DateTime now;
  final String replyText;

  static const double lead = 22;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final entries = <Widget>[];
    final runes = replyText.runes.toList();
    var cursor = 0;
    for (final s in steps) {
      if (s.offset > cursor && s.offset <= runes.length) {
        final commentary = String.fromCharCodes(runes.sublist(cursor, s.offset))
            .trim();
        cursor = s.offset;
        if (commentary.isNotEmpty) {
          entries.add(
            Padding(
              key: ValueKey('commentary-${s.id}'),
              padding: const EdgeInsets.only(
                top: 8,
                bottom: 12,
                left: lead + 8,
              ),
              child: HermesMarkdown(text: commentary),
            ),
          );
        }
      }
      entries.add(
        s.kind == StepKind.thinking
            ? _ThinkingEntry(key: ValueKey('step-${s.id}'), step: s)
            : _ToolEntry(key: ValueKey('step-${s.id}'), step: s, now: now),
      );
    }
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: entries,
    );
    if (steps.length < 2) return column;
    return Stack(
      children: [
        Positioned(
          left: lead / 2 - 0.5,
          top: 14,
          bottom: 14,
          width: 1,
          child: ColoredBox(color: t.hairline),
        ),
        column,
      ],
    );
  }
}

class _Lead extends StatelessWidget {
  const _Lead({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    // The page colour behind the glyph hides the rail under it.
    return SizedBox(
      width: StepTimeline.lead,
      child: Center(
        child: ColoredBox(
          color: t.bg,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _ThinkingEntry extends StatelessWidget {
  const _ThinkingEntry({super.key, required this.step});
  final ReplyStep step;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final text = step.text.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: _Lead(
              child: SizedBox.square(
                dimension: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: t.textFaint,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: text.isEmpty
                ? ShimmerText(
                    step.running ? 'Thinking' : 'Thought',
                    style: t.label.hermesSize(14, line: 20),
                  )
                : Semantics(
                    container: true,
                    label: 'Thinking: ',
                    child: HermesMarkdown(
                      text: text,
                      style: thinkingMarkdownStyle(t),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ToolEntry extends StatefulWidget {
  const _ToolEntry({super.key, required this.step, required this.now});
  final ReplyStep step;
  final DateTime now;

  @override
  State<_ToolEntry> createState() => _ToolEntryState();
}

class _ToolEntryState extends State<_ToolEntry> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final s = widget.step;
    final tool = s.tool ?? const StepTool(name: '');
    final name = toolName(tool.shownName);
    final descriptor = _descriptor(tool);
    final failed = s.state == StepPhase.failed;
    final time = shortDuration(s.elapsed(widget.now));
    // `details: false`: the bridge only has the stream's short preview (the
    // descriptor already shows it) and no output, so the row does not open.
    final openable = tool.details;
    final stateWord = s.running ? 'running' : (failed ? 'failed' : 'done');
    final nameText = Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      style: t.label.hermesSize(14, line: 20).copyWith(color: t.text),
    );
    // Name and descriptor share what the duration leaves; the name keeps up
    // to 65% of it when a descriptor follows, and both end in an ellipsis,
    // so no label length or text size can push the row past its edge.
    final labels = descriptor.isEmpty
        ? nameText
        : LayoutBuilder(
            builder: (context, c) => Row(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: c.maxWidth * 0.65),
                  child: nameText,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    descriptor,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: t.code.copyWith(
                      fontSize: 13,
                      height: 20 / 13,
                      color: t.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          );
    final row = Row(
      children: [
        _Lead(
          child: Icon(
            toolIcon(tool.shownName),
            size: 16,
            color: failed ? t.danger.withValues(alpha: 0.8) : t.textMuted,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: labels),
        const SizedBox(width: 8),
        if (failed) ...[
          Flexible(
            flex: 0,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 80),
              child: Text(
                'Failed',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: t.label.copyWith(color: t.danger.withValues(alpha: 0.8)),
              ),
            ),
          ),
          Text(' · ', style: t.label.copyWith(color: t.textFaint)),
        ],
        s.running
            ? ShimmerText(time, style: t.label)
            : Text(
                time,
                maxLines: 1,
                softWrap: false,
                style: t.label.copyWith(
                  color: t.textFaint,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
        // Same width either way, so durations line up.
        SizedBox(
          width: 20,
          child: openable
              ? AnimatedRotation(
                  turns: _open ? 0.25 : 0,
                  duration: Motion.of(
                    context,
                    const Duration(milliseconds: 200),
                  ),
                  curve: Motion.standard,
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: t.textFaint,
                  ),
                )
              : null,
        ),
      ],
    );
    void toggle() => setState(() => _open = !_open);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          // Its own node, so a screen reader can focus each tool row.
          container: true,
          button: openable,
          expanded: openable ? _open : null,
          label:
              '$name${descriptor.isEmpty ? '' : ', $descriptor'}, '
              '$stateWord, ${spokenDuration(s.elapsed(widget.now))}',
          onTapHint: openable
              ? (_open ? 'hide input and output' : 'show input and output')
              : null,
          onTap: openable ? toggle : null,
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: openable ? toggle : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 40),
              child: row,
            ),
          ),
        ),
        _Reveal(
          duration: const Duration(milliseconds: 200),
          child: _open && openable
              ? Padding(
                  padding: const EdgeInsets.only(
                    left: StepTimeline.lead + 8,
                    bottom: 10,
                  ),
                  child: ToolIo(step: s),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  static String _descriptor(StepTool tool) {
    var label = tool.label.trim().replaceAll(RegExp(r'\s+'), ' ');
    final id = tool.shownName.trim();
    if (label.isEmpty || label == tool.name || label == id) return '';
    final name = toolName(id).toLowerCase();
    final connector = connectorTool(id);
    // Hermes' previews often open with the tool's own words
    // ("Reading tool details · 1 tool", "Notion · search notion page"):
    // keep only what they add.
    final cut = label.indexOf(' · ');
    if (cut > 0) {
      final head = label.substring(0, cut).toLowerCase();
      final tail = label.substring(cut + 3).trim();
      if (connector != null &&
          head == serviceName(connector.service).toLowerCase()) {
        return '';
      }
      if (head == name ||
          head == toolActivity(id).toLowerCase() ||
          const {'searching tools', 'reading tool details'}.contains(head)) {
        label = tail;
      }
    }
    return label.toLowerCase() == name ? '' : label;
  }
}

/// A muted, slightly smaller markdown style for thinking text.
MarkdownStyle thinkingMarkdownStyle(HermesTokens t) {
  if (identical(t, _thinkingTokens)) return _thinkingStyle!;
  final base = MarkdownStyle.fromTokens(t);
  TextStyle m(TextStyle s, double size, double line) =>
      s.copyWith(color: t.textMuted, fontSize: size, height: line / size);
  _thinkingTokens = t;
  return _thinkingStyle = MarkdownStyle(
    body: m(base.body, 15, 22),
    h1: m(base.h1, 16, 22),
    h2: m(base.h2, 15.5, 22),
    h3: m(base.h3, 15, 22),
    h4: m(base.h4, 15, 22),
    code: base.code.copyWith(fontSize: 13, height: 19 / 13),
    table: m(base.table, 14, 20),
    tableHeader: m(base.tableHeader, 14, 20),
    label: base.label,
    text: t.textMuted,
    textMuted: t.textFaint,
    surface: base.surface,
    surfaceHigh: base.surfaceHigh,
    outline: base.outline,
    hairline: base.hairline,
    accentSoft: base.accentSoft,
    onAccentSoft: base.onAccentSoft,
    background: base.background,
    paragraphGap: 10,
    headingGapAbove: 12,
    h1GapAbove: 14,
    h3GapAbove: 12,
  );
}

HermesTokens? _thinkingTokens;
MarkdownStyle? _thinkingStyle;

// ---------------------------------------------------------------------------
// Input and output

/// A tool's INPUT and OUTPUT as two monospace blocks, each with a copy
/// button; long text is cut with "Show more". Error output is tinted.
class ToolIo extends StatelessWidget {
  const ToolIo({super.key, required this.step});
  final ReplyStep step;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final tool = step.tool ?? const StepTool(name: '');
    final input = formatToolInput(tool.input ?? tool.label);
    final output = tool.output ?? '';
    final error = tool.error ?? '';
    final failed =
        step.state == StepPhase.failed ||
        error.isNotEmpty ||
        (tool.exitStatus != null && tool.exitStatus != 0);
    final outputText = output.isNotEmpty
        ? (error.isNotEmpty && !output.contains(error)
              ? '$output\n$error'
              : output)
        : error;
    final note = !tool.details
        ? (step.running ? 'Output appears when the tool finishes.' : null)
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (input.trim().isNotEmpty)
          _IoBlock(title: 'Input', text: input, truncated: tool.truncated),
        const SizedBox(height: 10),
        if (outputText.isNotEmpty)
          _IoBlock(
            title: 'Output',
            text: outputText,
            error: failed,
            extra: tool.exitStatus != null && tool.exitStatus != 0
                ? 'exit ${tool.exitStatus}'
                : null,
            truncated: tool.truncated,
          )
        else
          Text(
            note ??
                (step.running
                    ? 'Running…'
                    : tool.details
                    ? 'No output.'
                    : 'Output isn’t available for this step.'),
            style: t.label.copyWith(color: t.textFaint),
          ),
      ],
    );
  }
}

/// `{"command": "echo hi"}` reads as `echo hi`; other objects as indented
/// JSON; strings as they are.
String formatToolInput(Object? input) {
  if (input == null) return '';
  if (input is String) return input;
  if (input is Map && input.length == 1) {
    final v = input.values.single;
    if (v is String &&
        const {
          'command',
          'code',
          'query',
          'url',
          'path',
        }.contains(input.keys.single)) {
      return v;
    }
  }
  try {
    return const JsonEncoder.withIndent('  ').convert(input);
  } catch (_) {
    return '$input';
  }
}

class _IoBlock extends StatefulWidget {
  const _IoBlock({
    required this.title,
    required this.text,
    this.error = false,
    this.extra,
    this.truncated = false,
  });

  final String title;
  final String text;
  final bool error;
  final String? extra;
  final bool truncated;

  static const int previewLines = 12;
  static const int previewChars = 1200;

  @override
  State<_IoBlock> createState() => _IoBlockState();
}

class _IoBlockState extends State<_IoBlock> {
  bool _all = false;

  String get _preview {
    final text = widget.text;
    var cut = text.length;
    var lines = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 10 && ++lines >= _IoBlock.previewLines) {
        cut = i;
        break;
      }
    }
    if (cut > _IoBlock.previewChars) cut = _IoBlock.previewChars;
    return text.substring(0, cut);
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final long = _preview.length < widget.text.length;
    final shown = _all || !long ? widget.text : '${_preview.trimRight()}\n…';
    final fg = widget.error ? t.danger : t.text;
    final bg = widget.error
        ? t.danger.withValues(alpha: 0.08)
        : t.surface.withValues(alpha: 0.7);
    final title = widget.title.toUpperCase();
    final mono = t.code.copyWith(fontSize: 13, height: 19 / 13, color: fg);
    Widget body = Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: SelectableText(shown, style: mono),
    );
    if (_all && long) {
      body = ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: Scrollbar(child: SingleChildScrollView(child: body)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              title,
              style: t.label
                  .hermesSize(11, line: 16)
                  .copyWith(letterSpacing: 0.8, color: t.textFaint),
            ),
            if (widget.extra != null) ...[
              const SizedBox(width: 8),
              Text(
                widget.extra!,
                style: t.label
                    .hermesSize(11, line: 16)
                    .copyWith(color: t.danger.withValues(alpha: 0.8)),
              ),
            ],
            if (widget.truncated) ...[
              const SizedBox(width: 8),
              Text(
                'cut by the server',
                style: t.label
                    .hermesSize(11, line: 16)
                    .copyWith(color: t.textFaint),
              ),
            ],
            const Spacer(),
            IconButton(
              tooltip: 'Copy ${widget.title.toLowerCase()}',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              color: t.textMuted,
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: widget.text)),
              icon: const Icon(Icons.copy_rounded),
            ),
          ],
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: body,
        ),
        if (long)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(
                foregroundColor: t.textMuted,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () => setState(() => _all = !_all),
              child: Text(_all ? 'Show less' : 'Show more'),
            ),
          ),
      ],
    );
  }
}
