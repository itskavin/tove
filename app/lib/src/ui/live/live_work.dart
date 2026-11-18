import 'package:material_ui/material_ui.dart';

import '../../call/call_controller.dart';
import '../../call/models.dart';
import '../../chat/chat.dart';
import '../common/shimmer.dart';
import '../theme/tokens.dart';
import '../thread/work_line.dart'
    show replyPresentation, toolActivity, toolIcon, workGlimpse;

/// Where a piece of live work is.
enum LiveWorkState { running, failed, continuesInChat }

/// Hermes work in progress during a live session, shown compactly under the
/// orb: a delegated task, or the thinking and tools of a typed turn's reply.
/// Finished results are not work: they open in the result panel instead.
class LiveWork {
  const LiveWork({
    required this.id,
    required this.title,
    required this.state,
    required this.started,
    this.glimpse,
    this.steps = const [],
    this.seconds,
    this.detail,
    this.replyText = '',
  });

  /// `task-<item id>` or `msg-<message id>`.
  final String id;

  /// What was asked.
  final String title;
  final LiveWorkState state;
  final DateTime started;

  /// What runs now: the newest step's summary or tool, as Hermes sent it.
  final String? glimpse;

  /// Thinking summaries and tools, oldest first (real steps only).
  final List<ReplyStep> steps;

  /// The bridge's own count for a task.
  final int? seconds;

  /// Why it failed, or where the result goes.
  final String? detail;

  /// The reply's text so far (for the commentary between steps).
  final String replyText;

  bool get running => state == LiveWorkState.running;

  Duration elapsed(DateTime now) {
    final local = now.difference(started);
    final bridge = Duration(seconds: seconds ?? 0);
    final d = bridge > local ? bridge : local;
    return d.isNegative ? Duration.zero : d;
  }
}

String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// The live work since [since]: running and failed delegated tasks (a task
/// that returned no answer counts as failed), the call's tasks that continue
/// after it, and typed replies that are still thinking or running a tool.
/// [endedAt] holds when each finished item was first seen; finished items
/// show for [linger] after that.
List<LiveWork> liveWorkFrom({
  required CallController call,
  required ChatController chat,
  required DateTime since,
  required DateTime now,
  required Map<String, DateTime> endedAt,
  Duration linger = const Duration(seconds: 12),
}) {
  final out = <LiveWork>[];
  bool lingers(String id) =>
      now.difference(endedAt.putIfAbsent(id, () => now)) < linger;

  for (final t in call.tasks) {
    if (t.created.isBefore(since)) continue;
    final id = 'task-${t.itemId}';
    final title = _oneLine(t.text).isEmpty ? 'Task' : _oneLine(t.text);
    final steps = stepsFromToolCalls(t.tools.calls);
    switch (t.status) {
      case TaskStatus.starting || TaskStatus.running:
        // Worded like the chat's thinking line: what kind of step runs,
        // not its raw command.
        final p = t.progress;
        final tool = p?.tool?.trim() ?? '';
        final label = p?.label.trim() ?? '';
        out.add(
          LiveWork(
            id: id,
            title: title,
            state: LiveWorkState.running,
            started: t.created,
            glimpse: tool.isNotEmpty && p!.state != ProgressState.info
                ? toolActivity(tool)
                : label.isNotEmpty
                ? label
                : (t.status == TaskStatus.starting ? 'Starting' : null),
            steps: steps,
            seconds: t.seconds,
          ),
        );
      case TaskStatus.done:
        // No answer: say so, never show it as a result.
        if (t.markdown != null || !lingers(id)) continue;
        out.add(
          LiveWork(
            id: id,
            title: title,
            state: LiveWorkState.failed,
            started: t.created,
            steps: steps,
            seconds: t.seconds,
            detail: t.detail ?? 'Hermes returned no answer',
          ),
        );
      case TaskStatus.failed || TaskStatus.busy:
        if (!lingers(id)) continue;
        out.add(
          LiveWork(
            id: id,
            title: title,
            state: LiveWorkState.failed,
            started: t.created,
            steps: steps,
            seconds: t.seconds,
            detail: t.detail ?? 'Hermes could not finish this',
          ),
        );
      case TaskStatus.stopped:
        if (!lingers(id)) continue;
        out.add(
          LiveWork(
            id: id,
            title: title,
            state: LiveWorkState.continuesInChat,
            started: t.created,
            steps: steps,
            seconds: t.seconds,
            detail: 'Continues in the chat',
          ),
        );
    }
  }

  String lastUser = '';
  for (final m in chat.messages) {
    if (m.isUser) {
      lastUser = m.text;
      continue;
    }
    if (m.source != MessageSource.text || m.created.isBefore(since)) continue;
    final id = 'msg-${m.id}';
    final steps = chat.stepsFor(m);
    final title = _oneLine(lastUser).isEmpty
        ? 'Your message'
        : _oneLine(lastUser);
    if (m.isStreaming) {
      final answer = replyPresentation(m.text, steps).answer;
      final p = m.progress;
      final working =
          answer.trim().isEmpty ||
          steps.any((s) => s.running) ||
          p?.state == ProgressState.info ||
          p?.state == ProgressState.approval;
      if (!working) continue;
      out.add(
        LiveWork(
          id: id,
          title: title,
          state: LiveWorkState.running,
          started: m.created,
          glimpse: workGlimpse(steps, p),
          steps: steps,
          replyText: m.text,
        ),
      );
    } else if (m.status == MessageStatus.failed && lingers(id)) {
      out.add(
        LiveWork(
          id: id,
          title: title,
          state: LiveWorkState.failed,
          started: m.created,
          steps: steps,
          detail: m.error?.message ?? 'The reply failed',
          replyText: m.text,
        ),
      );
    }
  }
  return out;
}

/// When the visible set next changes by itself (a finished item expires).
DateTime? liveWorkExpiry(
  List<LiveWork> items,
  Map<String, DateTime> endedAt, {
  Duration linger = const Duration(seconds: 12),
}) {
  DateTime? next;
  for (final w in items) {
    if (w.running) continue;
    final at = endedAt[w.id]?.add(linger);
    if (at != null && (next == null || at.isBefore(next))) next = at;
  }
  return next;
}

/// Hermes' work under the orb, just above the composer: one quiet line,
/// like the chat's thinking line. It says what runs now ("Thinking",
/// "Running terminal") with a shimmer, or that something could not finish,
/// and nothing more: no box, no timeline. The steps are in the chat's Tasks
/// panel and the live conversation.
class LiveWorkStrip extends StatelessWidget {
  const LiveWorkStrip({super.key, required this.items});

  final List<LiveWork> items;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    if (items.isEmpty) return const SizedBox.shrink();
    final running = items.where((w) => w.running).toList();
    // The newest running work speaks; otherwise the newest ended one.
    final w = running.isNotEmpty ? running.last : items.last;
    final others = running.length - (w.running ? 1 : 0);
    final status = switch (w.state) {
      LiveWorkState.running => w.glimpse ?? 'Working on it',
      LiveWorkState.failed => 'Couldn’t finish',
      LiveWorkState.continuesInChat => 'Continues in the chat',
    };
    final style = t.label.hermesSize(15, line: 22);
    final tool = w.steps.where((s) => s.isTool && s.running).lastOrNull;
    final more = others > 0 ? ' · ${others + 1} tasks' : '';
    return Semantics(
      key: const ValueKey('live-work-strip'),
      container: true,
      liveRegion: !w.running,
      label: '$status$more',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 32),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (w.running && tool != null) ...[
              Icon(
                toolIcon(tool.tool?.shownName ?? ''),
                size: 16,
                color: t.textMuted,
              ),
              const SizedBox(width: 7),
            ] else if (w.state == LiveWorkState.failed) ...[
              Icon(Icons.error_outline_rounded, size: 16, color: t.danger),
              const SizedBox(width: 7),
            ],
            Flexible(
              child: w.running
                  ? ShimmerText(status, style: style)
                  : Text(
                      status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style.copyWith(
                        color: w.state == LiveWorkState.failed
                            ? t.danger
                            : t.textMuted,
                      ),
                    ),
            ),
            if (more.isNotEmpty)
              Text(more, style: style.copyWith(color: t.textFaint)),
          ],
        ),
      ),
    );
  }
}
