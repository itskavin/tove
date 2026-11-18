import '../chat/models.dart' show ChatProgress;
import '../chat/tool_calls.dart' show ToolCallLog;

enum Speaker { user, hermes }

class TranscriptEntry {
  TranscriptEntry(this.id, this.speaker, {DateTime? created, this.turnId})
    : created = created ?? DateTime.now();
  final int id;
  final Speaker speaker;
  final DateTime created;
  String text = '';

  /// GPT-Live's turn id (`turn.created` / `turn.done`), once known. Null for
  /// an entry opened by a transcript chunk that arrived before its
  /// `turn.created`; that event then adopts it (see `CallController`).
  String? turnId;

  /// Still being spoken / transcribed.
  bool live = true;
}

enum TaskStatus {
  /// Waiting for the bridge to accept the task.
  starting,
  running,
  done,
  failed,

  /// The bridge refused it: two tasks are already running.
  busy,

  /// The call ended before the result arrived.
  stopped,
}

class TaskEntry {
  TaskEntry(this.itemId, this.text, {this.conversationId, this.session});

  /// The GPT-Live `delegation.created` item id.
  final String itemId;
  final String text;
  TaskStatus status = TaskStatus.starting;
  int seconds = 0;

  /// Hermes' answer (done) or the reason it failed.
  String? detail;

  /// Hermes' original markdown for a done task, when the bridge sends it.
  String? markdown;

  /// The bridge's job id, once the task was accepted.
  String? job;

  /// The chat the call was linked to, if any (tasks belong to that chat).
  final String? conversationId;

  /// The bridge session that ran the task.
  final String? session;

  /// Hermes' newest tool step while the task runs (`status_event` on
  /// `GET /api/job`, capability `job_progress`), and every distinct step
  /// seen while polling, oldest first. Real progress only: nothing is
  /// invented when the bridge sends none.
  ChatProgress? progress;
  final ToolCallLog tools = ToolCallLog();
  final DateTime created = DateTime.now();
  DateTime? finished;

  bool get active =>
      status == TaskStatus.starting || status == TaskStatus.running;
}
