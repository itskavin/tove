import 'dart:math' as math;

import '../../call/call_controller.dart';
import '../../call/models.dart';
import '../../chat/chat.dart';

/// What a live activity card stands for.
enum LiveActivityKind {
  /// A Hermes task delegated by the voice model (`/api/delegate`).
  task,

  /// A tool Hermes runs while answering a typed turn (`status` events).
  tool,

  /// A task or tool that calls T3 Code.
  t3,
}

enum LiveActivityState {
  running,
  done,
  failed,

  /// The call ended while the task ran. The bridge keeps it running and
  /// saves the result to the linked chat (API.md: tasks outlive the call).
  continuesInChat,
}

/// The note shown for [LiveActivityState.continuesInChat].
const continuesInChatNote =
    'Hermes is still working on this. The result will appear in the chat.';

/// One card in the live task stack (spec: "Hermes task cards").
class LiveActivity {
  const LiveActivity({
    required this.id,
    required this.label,
    required this.kind,
    required this.state,
    required this.started,
    this.finished,
    this.seconds,
    this.contentId,
    this.detail,
  });

  /// `task-<item id>` or `tool-<message id>-<tool call id>`.
  final String id;
  final String label;
  final LiveActivityKind kind;
  final LiveActivityState state;

  /// When the card first appeared.
  final DateTime started;
  final DateTime? finished;

  /// Seconds reported by the bridge (jobs), when known.
  final int? seconds;

  /// The live content to expand into the panel (see `liveContentById`).
  final String? contentId;

  /// A failure reason.
  final String? detail;

  bool get running => state == LiveActivityState.running;

  /// Seconds shown on the card: the bridge's count, or the local time since
  /// it started (until it finished), whichever is larger.
  int elapsed(DateTime now) {
    final local = (finished ?? now).difference(started).inSeconds;
    return math.max(seconds ?? 0, math.max(0, local));
  }

  LiveActivity copyWith({
    LiveActivityState? state,
    DateTime? started,
    DateTime? finished,
    String? label,
    int? seconds,
  }) => LiveActivity(
    id: id,
    label: label ?? this.label,
    kind: kind,
    state: state ?? this.state,
    started: started ?? this.started,
    finished: finished ?? this.finished,
    seconds: seconds ?? this.seconds,
    contentId: contentId,
    detail: detail,
  );
}

final _t3 = RegExp(r'(^|[^a-z0-9])t3([^a-z0-9]|$)', caseSensitive: false);

/// Whether [text] (a tool name, a label or a task request) refers to T3.
bool mentionsT3(String? text) => text != null && _t3.hasMatch(text);

String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// The activities visible in the call and chat right now, since [since]:
/// every delegated task, and the running tool of each streaming typed reply.
List<LiveActivity> liveActivitiesFrom({
  required CallController call,
  required ChatController chat,
  required DateTime since,
}) {
  final out = <LiveActivity>[];
  for (final t in call.tasks) {
    if (t.created.isBefore(since)) continue;
    final label = _oneLine(t.text);
    out.add(
      LiveActivity(
        id: 'task-${t.itemId}',
        label: label.isEmpty ? 'Hermes task' : label,
        kind: mentionsT3(t.text) ? LiveActivityKind.t3 : LiveActivityKind.task,
        state: switch (t.status) {
          TaskStatus.starting ||
          TaskStatus.running => LiveActivityState.running,
          TaskStatus.done => LiveActivityState.done,
          TaskStatus.stopped => LiveActivityState.continuesInChat,
          TaskStatus.failed || TaskStatus.busy => LiveActivityState.failed,
        },
        started: t.created,
        finished: t.finished,
        seconds: t.seconds > 0 ? t.seconds : null,
        contentId: 'task-${t.itemId}',
        detail: t.status == TaskStatus.stopped
            ? continuesInChatNote
            : (t.active ? null : t.detail),
      ),
    );
  }
  for (final m in chat.messages) {
    if (!m.isAssistant || m.created.isBefore(since) || !m.isStreaming) {
      continue;
    }
    final p = m.progress;
    if (p == null) continue;
    final state = switch (p.state) {
      ProgressState.running ||
      ProgressState.approval => LiveActivityState.running,
      ProgressState.completed => LiveActivityState.done,
      ProgressState.failed => LiveActivityState.failed,
      ProgressState.info || ProgressState.unknown => null,
    };
    if (state == null) continue; // Lifecycle notes are not tools.
    final tool = p.tool?.trim();
    var label = _oneLine(p.label);
    if (label.isEmpty) label = tool ?? 'Working';
    if (p.state == ProgressState.approval) {
      label = 'Waiting for approval · $label';
    }
    out.add(
      LiveActivity(
        id: 'tool-${m.id}-${p.id ?? tool ?? 'step'}',
        label: label,
        kind: mentionsT3(tool) || mentionsT3(p.label)
            ? LiveActivityKind.t3
            : LiveActivityKind.tool,
        state: state,
        started: m.created,
        contentId: 'msg-${m.id}',
      ),
    );
  }
  return out;
}

/// Keeps the card stack: when each card was first seen, when a tool step
/// that vanished from the stream finished, and how long finished cards stay.
class LiveActivityTracker {
  /// Finished cards stay this long (failed and handed-off ones longer).
  static const doneLinger = Duration(seconds: 6);
  static const failedLinger = Duration(seconds: 10);

  /// At most this many cards show.
  static const maxVisible = 3;

  final Map<String, LiveActivity> _items = {};

  /// Every card seen this session, oldest first.
  Iterable<LiveActivity> get all => _items.values;

  /// Merges a snapshot taken at [now]. Running tool steps missing from it
  /// (the stream moved on to another tool, or the reply ended) are done.
  void update(List<LiveActivity> snapshot, DateTime now) {
    final ids = <String>{};
    for (final a in snapshot) {
      ids.add(a.id);
      final old = _items[a.id];
      // Tool steps have no start time of their own: use first sight.
      final started = a.id.startsWith('tool-')
          ? (old?.started ?? now)
          : a.started;
      DateTime? finished = a.finished;
      if (!a.running) finished ??= old?.finished ?? now;
      _items[a.id] = LiveActivity(
        id: a.id,
        label: a.label,
        kind: a.kind,
        state: a.state,
        started: started,
        finished: a.running ? null : finished,
        seconds: a.seconds,
        contentId: a.contentId,
        detail: a.detail,
      );
    }
    for (final e in _items.entries.toList()) {
      if (!ids.contains(e.key) && e.value.running) {
        _items[e.key] = e.value.copyWith(
          state: LiveActivityState.done,
          finished: now,
        );
      }
    }
  }

  Duration _linger(LiveActivity a) =>
      a.state == LiveActivityState.done ? doneLinger : failedLinger;

  bool _shows(LiveActivity a, DateTime now) =>
      a.running || now.difference(a.finished ?? now) < _linger(a);

  /// The cards to show at [now], oldest first (the newest sits nearest the
  /// orb). Running cards win over finished ones.
  List<LiveActivity> visible(DateTime now, {int max = maxVisible}) {
    final shown = _items.values.where((a) => _shows(a, now)).toList();
    if (shown.length <= max) return shown;
    final running = shown.where((a) => a.running).toList();
    final done = shown.where((a) => !a.running).toList();
    final keep = <LiveActivity>{
      ...running.skip(math.max(0, running.length - max)),
    };
    for (final a in done.reversed) {
      if (keep.length >= max) break;
      keep.add(a);
    }
    return shown.where(keep.contains).toList();
  }

  /// When the visible set next changes by itself (a finished card expires).
  DateTime? nextExpiry(DateTime now) {
    DateTime? next;
    for (final a in _items.values) {
      if (a.running || !_shows(a, now)) continue;
      final at = a.finished!.add(_linger(a));
      if (next == null || at.isBefore(next)) next = at;
    }
    return next;
  }

  void clear() => _items.clear();
}
