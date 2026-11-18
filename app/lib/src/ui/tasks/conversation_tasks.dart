import '../../call/call_controller.dart';
import '../../call/models.dart';
import '../../chat/chat.dart';
import '../thread/work_line.dart' show toolActivity, workDuration, workGlimpse;

/// Where a conversation task is.
enum ConversationTaskState {
  /// Waiting for the bridge to accept a live-voice task.
  starting,
  running,
  done,
  failed,

  /// Stopped by the user; any partial answer is kept.
  stopped,

  /// Cut off (the bridge restarted mid-reply, or an old bridge).
  interrupted,

  /// The live call ended while the task ran. The bridge finishes it and
  /// saves the result to this chat.
  continuesAfterCall,
}

/// Where the work came from.
enum ConversationTaskOrigin {
  /// Hermes answering a typed message (its thinking and tool steps).
  reply,

  /// A Hermes task delegated from live voice.
  liveTask,
}

/// One unit of Hermes work in a chat, read from what the app already has:
/// a typed reply's steps (`ChatController.stepsFor`), a live-voice task
/// (`CallController.tasks`, with the tool steps its job reported) or a task
/// result saved to the chat (`source: task`). Nothing here is estimated.
class ConversationTask {
  const ConversationTask({
    required this.id,
    required this.origin,
    required this.title,
    required this.state,
    required this.started,
    this.elapsed,
    this.steps = const [],
    this.glimpse,
    this.detail,
    this.message,
    this.canStop = false,
    this.canRetry = false,
  });

  /// `reply-<message id>`, `job-<job id>` or `live-<delegation item id>`.
  final String id;
  final ConversationTaskOrigin origin;

  /// What was asked: the user's message, or the delegated request.
  final String title;
  final ConversationTaskState state;
  final DateTime started;

  /// How long it ran (finished work) or has run so far, when known.
  final Duration? elapsed;

  /// Thinking and tool steps, oldest first.
  final List<ReplyStep> steps;

  /// What is running now (the newest step, or Hermes' own note).
  final String? glimpse;

  /// Why it failed, or another short note.
  final String? detail;

  /// The chat message holding the reply or result, when there is one.
  final ChatMessage? message;

  /// The existing stop route applies (the reply streaming in this chat).
  final bool canStop;

  /// The existing retry applies (the newest reply, ended early).
  final bool canRetry;

  bool get active =>
      state == ConversationTaskState.running ||
      state == ConversationTaskState.starting;
}

String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// A step that ran a tool (not Hermes thinking).
bool isToolStep(ReplyStep s) => s.kind == StepKind.tool;

/// The Hermes work in the chat on screen, newest first: replies that called
/// at least one tool, live-voice tasks (Hermes jobs) of calls linked to this
/// chat, and task results saved in it. Plain replies, streaming or not, are
/// never tasks. Work from other chats never shows.
List<ConversationTask> conversationTasks({
  required ChatController chat,
  CallController? call,
  DateTime Function() now = DateTime.now,
}) {
  final at = now();
  final messages = chat.messages;
  final out = <ConversationTask>[];
  final savedJobs = <String>{};
  final lastReply = messages.lastIndexWhere((m) => m.isAssistant && !m.isTask);
  String lastUser = '';
  for (var i = 0; i < messages.length; i++) {
    final m = messages[i];
    if (m.isUser) {
      lastUser = m.text;
      continue;
    }
    if (m.isTask) {
      // A live-call task is a chat message from its start (bridges with
      // `task_messages`): running while it streams, with its steps.
      final job = m.meta['job'];
      if (job is String && job.isNotEmpty) savedJobs.add(job);
      final state = _state(m.status);
      final running = state == ConversationTaskState.running;
      final steps = chat.stepsFor(m);
      final secs = m.taskSeconds;
      final worked = workDuration(steps, replyStart: m.created);
      out.add(
        ConversationTask(
          id: 'msg-${m.id}',
          origin: ConversationTaskOrigin.liveTask,
          title: _oneLine(m.taskRequest ?? 'Task from live voice'),
          state: state,
          started: m.created,
          elapsed: running
              ? at.difference(m.created)
              : secs != null
              ? Duration(seconds: secs)
              : (steps.isEmpty || worked.isNegative ? null : worked),
          steps: steps,
          glimpse: running ? workGlimpse(steps, m.progress) : null,
          detail: state == ConversationTaskState.failed
              ? taskFailureText(m)
              : null,
          message: m,
          canStop: running && !m.isLocal,
        ),
      );
      continue;
    }
    if (m.isVoice) continue;
    final steps = chat.stepsFor(m);
    final state = _state(m.status);
    // Only tool calls are tasks (user rule, 16 Nov 2026): a reply that only
    // thought, or is still thinking, is a reply, whatever its status. The
    // bridge sends a `thinking` step for nearly every reply, so counting
    // any step would list every prompt here as running work.
    if (!steps.any(isToolStep)) continue;
    final running = state == ConversationTaskState.running;
    final d = running
        ? at.difference(m.created)
        : workDuration(steps, replyStart: m.created);
    out.add(
      ConversationTask(
        id: 'reply-${m.id}',
        origin: ConversationTaskOrigin.reply,
        title: _oneLine(lastUser).isEmpty ? 'Reply' : _oneLine(lastUser),
        state: state,
        started: m.created,
        elapsed: d.isNegative ? null : d,
        steps: steps,
        glimpse: running ? workGlimpse(steps, m.progress) : null,
        detail: state == ConversationTaskState.failed
            ? (m.error?.message ?? 'The reply failed.')
            : null,
        message: m,
        canStop: running && chat.streamingMessage?.id == m.id,
        canRetry:
            i == lastReply &&
            chat.canSend &&
            (state == ConversationTaskState.failed ||
                state == ConversationTaskState.stopped ||
                state == ConversationTaskState.interrupted),
      ),
    );
  }

  final conv = chat.currentConversationId;
  for (final t in call?.tasks ?? const <TaskEntry>[]) {
    if (t.conversationId != conv) continue;
    final job = t.job;
    // Saved to the chat: the message above stands for it.
    if (job != null && savedJobs.contains(job)) continue;
    final state = switch (t.status) {
      TaskStatus.starting => ConversationTaskState.starting,
      TaskStatus.running => ConversationTaskState.running,
      TaskStatus.done => ConversationTaskState.done,
      TaskStatus.failed || TaskStatus.busy => ConversationTaskState.failed,
      TaskStatus.stopped => ConversationTaskState.continuesAfterCall,
    };
    final local = (t.finished ?? at).difference(t.created);
    final secs = Duration(seconds: t.seconds);
    final p = t.progress;
    out.add(
      ConversationTask(
        id: job != null ? 'job-$job' : 'live-${t.itemId}',
        origin: ConversationTaskOrigin.liveTask,
        title: _oneLine(t.text).isEmpty
            ? 'Task from live voice'
            : _oneLine(t.text),
        state: state,
        started: t.created,
        elapsed: secs > local ? secs : local,
        steps: stepsFromToolCalls(t.tools.calls),
        // Worded like the chat's thinking line; the command itself is in
        // the step row.
        glimpse: !t.active
            ? null
            : (p?.tool ?? '').trim().isNotEmpty &&
                  p!.state != ProgressState.info
            ? toolActivity(p.tool!)
            : (p != null && p.label.trim().isNotEmpty)
            ? p.label.trim()
            : (t.status == TaskStatus.starting ? 'Starting' : null),
        detail: switch (t.status) {
          TaskStatus.failed || TaskStatus.busy => t.detail,
          TaskStatus.stopped =>
            'The call ended while Hermes was working. The result will be '
                'saved to this chat.',
          _ => null,
        },
      ),
    );
  }
  // Newest first; for equal times the later one in the chat comes first.
  final order = {for (final (i, x) in out.indexed) x.id: i};
  out.sort((a, b) {
    final c = b.started.compareTo(a.started);
    return c != 0 ? c : order[b.id]!.compareTo(order[a.id]!);
  });
  return out;
}

ConversationTaskState _state(MessageStatus s) => switch (s) {
  MessageStatus.streaming ||
  MessageStatus.sending => ConversationTaskState.running,
  MessageStatus.done => ConversationTaskState.done,
  MessageStatus.failed => ConversationTaskState.failed,
  MessageStatus.stopped => ConversationTaskState.stopped,
  MessageStatus.interrupted => ConversationTaskState.interrupted,
};

/// Why a live-call task failed, in one line (the bridge's `error_code`).
String taskFailureText(ChatMessage m) {
  final code = m.meta['error_code'] as String? ?? m.error?.code;
  final partial = m.text.trim().isNotEmpty;
  final why = switch (code) {
    'timeout' => 'Timed out after 15 minutes.',
    'hermes_unreachable' => 'Hermes could not be reached.',
    'hermes_busy' => 'Hermes was busy.',
    'hermes_auth' => 'The server could not sign in to Hermes.',
    _ => 'Hermes could not finish this task.',
  };
  return partial ? '$why What it found so far is in the chat.' : why;
}

/// Tool work runs in this chat now: the streaming reply has called a tool,
/// or a live-voice job linked to this chat is active. A reply that is only
/// thinking or writing is not "work running" (the Tasks glyph's dot).
bool toolWorkRunning({required ChatController chat, CallController? call}) {
  final m = chat.streamingMessage;
  if (m != null && chat.stepsFor(m).any(isToolStep)) return true;
  if (chat.taskRunning) return true;
  final conv = chat.currentConversationId;
  return call?.tasks.any((t) => t.active && t.conversationId == conv) ?? false;
}
