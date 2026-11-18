import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../call/call_controller.dart';
import '../../chat/chat.dart';
import '../common/glyphs.dart';
import '../common/shimmer.dart';
import '../shell/edge_feather.dart';
import '../theme/tokens.dart';
import '../thread/work_line.dart'
    show StepTimeline, shortDuration, spokenDuration;
import 'conversation_tasks.dart';

export 'conversation_tasks.dart';

/// The chat's Hermes work, opened by swiping the chat towards the right
/// (on phones the panel comes in from the left; wide layouts show it over
/// the pane's right side) or with the Tasks button: what
/// runs now and what ran earlier in this chat, with the real thinking and
/// tool steps. Stop and retry use the chat's existing routes.
class ConversationTasksPanel extends StatefulWidget {
  const ConversationTasksPanel({
    super.key,
    required this.chat,
    required this.onClose,
    this.call,
    this.closeFocus,
    this.now,
  });

  final ChatController chat;
  final CallController? call;
  final VoidCallback onClose;

  /// Focus for the close button, so keyboard users land in the panel.
  final FocusNode? closeFocus;

  /// For tests: a fixed clock.
  final DateTime Function()? now;

  @override
  State<ConversationTasksPanel> createState() => _ConversationTasksPanelState();
}

class _ConversationTasksPanelState extends State<ConversationTasksPanel> {
  /// Cards the user opened or closed; others follow their default (running
  /// work open, finished work closed).
  final Map<String, bool> _open = {};
  Timer? _tick;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// Elapsed times tick once a second while something runs.
  void _syncTick(bool running) {
    if (running && widget.now == null) {
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Material(
      color: t.bg,
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: 'Tasks in this chat',
        child: ListenableBuilder(
          listenable: Listenable.merge([widget.chat, ?widget.call]),
          builder: (context, _) {
            final tasks = conversationTasks(
              chat: widget.chat,
              call: widget.call,
              now: _now,
            );
            final running = tasks.where((x) => x.active).toList();
            final earlier = tasks.where((x) => !x.active).toList();
            _syncTick(running.isNotEmpty);
            // The header stays put over the chat screen's top feather and the
            // list scrolls under it (round 6).
            return FeatheredHeader(
              header: Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 8, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text('Tasks', style: t.title),
                      ),
                    ),
                    IconButton(
                      focusNode: widget.closeFocus,
                      tooltip: 'Close tasks',
                      onPressed: widget.onClose,
                      icon: Icon(Icons.close_rounded, color: t.text),
                    ),
                  ],
                ),
              ),
              body: (inset) => tasks.isEmpty
                  ? Padding(
                      padding: EdgeInsets.only(top: inset),
                      child: _Empty(bottom: bottom),
                    )
                  : ListView(
                      key: const ValueKey('tasks-list'),
                      padding: EdgeInsets.only(top: inset, bottom: 24 + bottom),
                      children: [
                        if (running.isNotEmpty) ...[
                          _section(t, 'Running now'),
                          for (final x in running) _card(x),
                        ],
                        if (earlier.isNotEmpty) ...[
                          _section(t, 'Earlier in this chat'),
                          for (final x in earlier) _card(x),
                        ],
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }

  Widget _section(HermesTokens t, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
    child: Semantics(header: true, child: Text(text, style: t.section)),
  );

  Widget _card(ConversationTask x) => _TaskCard(
    key: ValueKey(x.id),
    task: x,
    now: _now(),
    open: _open[x.id] ?? x.active,
    onToggle: () => setState(() => _open[x.id] = !(_open[x.id] ?? x.active)),
    onStop: !x.canStop
        ? null
        : x.origin == ConversationTaskOrigin.liveTask && x.message != null
        ? () => unawaited(widget.chat.stopTask(x.message!.id))
        : widget.chat.stop,
    onRetry: x.canRetry ? () => unawaited(widget.chat.retry(x.message)) : null,
  );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.bottom});
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 24, 20, 24 + bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.checklist_rounded, size: 28, color: t.textFaint),
          const SizedBox(height: 12),
          Text('Nothing running in this chat', style: t.row),
          const SizedBox(height: 6),
          Text(
            'When Hermes uses tools or runs a task from live voice in this '
            'chat, its steps show here.',
            style: t.caption,
          ),
        ],
      ),
    );
  }
}

/// One task: what was asked, where it is, its steps (open on demand) and
/// the actions that exist for it.
class _TaskCard extends StatelessWidget {
  const _TaskCard({
    super.key,
    required this.task,
    required this.now,
    required this.open,
    required this.onToggle,
    this.onStop,
    this.onRetry,
  });

  final ConversationTask task;
  final DateTime now;
  final bool open;
  final VoidCallback onToggle;
  final VoidCallback? onStop;
  final VoidCallback? onRetry;

  /// "Running · 12s", "Done · 8s", "Failed", …; null parts are left out.
  (String text, String spoken) _status() {
    final x = task;
    final d = x.elapsed;
    String withTime(String s) =>
        d == null || d == Duration.zero ? s : '$s · ${shortDuration(d)}';
    String spokenTime(String s) =>
        d == null || d == Duration.zero ? s : '$s, ${spokenDuration(d)}';
    final base = switch (x.state) {
      ConversationTaskState.starting => 'Starting',
      ConversationTaskState.running => x.glimpse ?? 'Working',
      ConversationTaskState.done => 'Done',
      ConversationTaskState.failed => 'Failed',
      ConversationTaskState.stopped => 'Stopped',
      ConversationTaskState.interrupted => 'Cut off',
      ConversationTaskState.continuesAfterCall => 'Continues after the call',
    };
    return (withTime(base), spokenTime(base));
  }

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    final x = task;
    final (status, spoken) = _status();
    final failed = x.state == ConversationTaskState.failed;
    final statusStyle = t.label.copyWith(
      color: failed ? t.danger : t.textMuted,
    );
    final hasSteps = x.steps.isNotEmpty;
    final tools = x.steps.where((s) => s.isTool).length;
    final stepsLabel = tools > 0
        ? '$tools ${tools == 1 ? 'tool' : 'tools'}'
              '${x.steps.length > tools ? ' and thinking' : ''}'
        : 'Thinking';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: x.active ? t.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(Rad.card),
          border: x.active ? null : Border.all(color: t.hairline),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                container: true,
                label: [
                  x.title,
                  if (x.origin == ConversationTaskOrigin.liveTask)
                    'from live voice',
                  spoken,
                ].join('. '),
                excludeSemantics: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2, right: 10),
                      child: _StateIcon(state: x.state),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            x.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: t.row,
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (x.origin == ConversationTaskOrigin.liveTask)
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    WaveGlyph(color: t.textFaint, size: 12),
                                    const SizedBox(width: 4),
                                    Text('Live voice', style: t.label),
                                  ],
                                ),
                              if (x.state == ConversationTaskState.running)
                                ShimmerText(status, style: statusStyle)
                              else
                                Text(status, style: statusStyle),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (x.detail != null) ...[
                const SizedBox(height: 8),
                Text(
                  x.detail!,
                  style: t.caption.copyWith(
                    color: failed ? t.danger : t.textMuted,
                  ),
                ),
              ],
              if (hasSteps) ...[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: onToggle,
                    style: TextButton.styleFrom(
                      foregroundColor: t.textMuted,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(48, 40),
                    ),
                    icon: Icon(
                      open
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                    ),
                    label: Text(
                      open ? 'Hide steps' : 'Show steps · $stepsLabel',
                      style: t.label,
                    ),
                  ),
                ),
                if (open)
                  ColoredBox(
                    // The timeline paints its glyphs on the page colour.
                    color: t.bg,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: StepTimeline(
                        steps: x.steps,
                        now: now,
                        replyText: x.message?.text ?? '',
                      ),
                    ),
                  ),
              ],
              if (onStop != null || onRetry != null) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    if (onStop != null)
                      OutlinedButton.icon(
                        onPressed: onStop,
                        icon: const Icon(Icons.stop_rounded, size: 18),
                        label: const Text('Stop'),
                      ),
                    if (onRetry != null)
                      OutlinedButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Retry'),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StateIcon extends StatelessWidget {
  const _StateIcon({required this.state});
  final ConversationTaskState state;

  @override
  Widget build(BuildContext context) {
    final t = HermesTokens.of(context);
    return SizedBox.square(
      dimension: 18,
      child: switch (state) {
        ConversationTaskState.running ||
        ConversationTaskState.starting => Padding(
          padding: const EdgeInsets.all(2),
          child: CircularProgressIndicator(strokeWidth: 1.8, color: t.text),
        ),
        ConversationTaskState.done => Icon(
          Icons.check_circle_outline_rounded,
          size: 18,
          color: t.textMuted,
        ),
        ConversationTaskState.failed => Icon(
          Icons.error_outline_rounded,
          size: 18,
          color: t.danger,
        ),
        ConversationTaskState.stopped => Icon(
          Icons.stop_circle_outlined,
          size: 18,
          color: t.textMuted,
        ),
        ConversationTaskState.interrupted => Icon(
          Icons.content_cut_rounded,
          size: 18,
          color: t.textMuted,
        ),
        ConversationTaskState.continuesAfterCall => Icon(
          Icons.schedule_rounded,
          size: 18,
          color: t.textMuted,
        ),
      },
    );
  }
}
