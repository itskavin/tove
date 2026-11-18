import 'models.dart';

/// How a Hermes tool call ended (or that it has not yet).
enum ToolCallState { running, done, failed, approval }

/// One Hermes tool call, built from the bridge's `status` events
/// (`{label, state, tool, id, emoji}`, API.md) while a reply streams.
///
/// The bridge does not persist these yet, so the app keeps them in memory for
/// the session ([ToolCallLog]); `docs/design/bridge-requests.md` lists the
/// fields a persisted copy needs (`meta.tools`, read by [ToolCall.fromJson]).
class ToolCall {
  ToolCall({
    required this.id,
    required this.tool,
    required this.label,
    required this.started,
    required this.offset,
    this.emoji = '',
    this.state = ToolCallState.running,
    this.ended,
  });

  /// From a persisted `meta.tools` entry (see bridge-requests.md).
  static ToolCall? fromJson(Object? j) {
    if (j is! Map) return null;
    final started = j['started'];
    if (started is! num) return null;
    final ended = j['ended'];
    return ToolCall(
      id: '${j['id'] ?? ''}',
      tool: '${j['tool'] ?? ''}',
      label: '${j['label'] ?? ''}',
      emoji: '${j['emoji'] ?? ''}',
      offset: j['offset'] is num ? (j['offset'] as num).toInt() : -1,
      started: DateTime.fromMillisecondsSinceEpoch(started.toInt()),
      ended: ended is num
          ? DateTime.fromMillisecondsSinceEpoch(ended.toInt())
          : null,
      state: switch (j['state']) {
        'running' => ToolCallState.running,
        'failed' || 'error' => ToolCallState.failed,
        'approval' => ToolCallState.approval,
        _ => ToolCallState.done,
      },
    );
  }

  /// Hermes' `toolCallId` (may be empty for approval notes).
  final String id;

  /// Hermes' tool name, such as `terminal` or `web_search`.
  final String tool;

  /// The short preview Hermes sends with the start (`df -h`, a query, a URL).
  String label;
  String emoji;
  ToolCallState state;
  final DateTime started;
  DateTime? ended;

  /// Characters of reply text written before the call started; the thread
  /// shows the call there, so a preamble ("Let me check") reads before it.
  /// −1 means unknown (show it at the end).
  final int offset;

  bool get running => state == ToolCallState.running;

  Duration elapsed(DateTime now) => (ended ?? now).difference(started);

  /// A call to T3 Code: Hermes reaches it through its `terminal` tool
  /// (`t3 thread start …`, the label is the command preview) or through a tool
  /// whose name contains a `t3` token (an MCP server named `t3`).
  bool get isT3 => _t3Token.hasMatch(tool) || _t3Label.hasMatch(label.trim());

  static final _t3Token = RegExp(
    r'(^|[^a-z0-9])t3([^a-z0-9]|$)',
    caseSensitive: false,
  );
  static final _t3Label = RegExp(r'(^|[\s/"`(])t3(\s|$)|\bT3( Code)?\b');

  Map<String, Object?> toJson() => {
    'id': id,
    'tool': tool,
    'label': label,
    'emoji': emoji,
    'state': state.name,
    'offset': offset,
    'started': started.millisecondsSinceEpoch,
    'ended': ?ended?.millisecondsSinceEpoch,
  };
}

/// Folds one reply's `status` events into [ToolCall]s.
class ToolCallLog {
  final List<ToolCall> calls = [];

  bool get isEmpty => calls.isEmpty;

  /// Records [p] at [offset] characters into the reply. `info` events are
  /// lifecycle notes (they only change the thinking label) and are skipped.
  void record(ChatProgress p, int offset, DateTime now) {
    switch (p.state) {
      case ProgressState.info:
        return;
      case ProgressState.approval:
        calls.add(
          ToolCall(
            id: 'approval-${calls.length}',
            tool: 'approval',
            label: p.label,
            offset: offset,
            started: now,
            state: ToolCallState.approval,
          ),
        );
      case ProgressState.completed:
        final c = _find(p);
        if (c == null) {
          // A completion whose start we missed (resume): show it as done.
          calls.add(
            ToolCall(
              id: p.id ?? '',
              tool: p.tool ?? '',
              label: p.label,
              emoji: p.emoji ?? '',
              offset: offset,
              started: now,
              ended: now,
              state: ToolCallState.done,
            ),
          );
        } else {
          c
            ..state = ToolCallState.done
            ..ended = now;
          if ((p.emoji ?? '').isNotEmpty) c.emoji = p.emoji!;
        }
      case ProgressState.failed:
        final c = _find(p);
        if (c != null) {
          c
            ..state = ToolCallState.failed
            ..ended = now;
        }
      case ProgressState.running || ProgressState.unknown:
        final c = _find(p);
        if (c != null && c.running) {
          // Same call, new preview.
          if (p.label.trim().isNotEmpty) c.label = p.label;
          return;
        }
        calls.add(
          ToolCall(
            id: p.id ?? '',
            tool: p.tool ?? '',
            label: p.label,
            emoji: p.emoji ?? '',
            offset: offset,
            started: now,
          ),
        );
    }
  }

  ToolCall? _find(ChatProgress p) {
    final id = p.id ?? '';
    for (final c in calls.reversed) {
      if (id.isNotEmpty ? c.id == id : c.running && c.tool == (p.tool ?? '')) {
        return c;
      }
    }
    return null;
  }

  /// The reply ended: calls still running ended with it ([failed] for an
  /// error or a stop, done otherwise, since Hermes finished its answer).
  void finish(DateTime now, {required bool failed}) {
    for (final c in calls) {
      if (c.running || c.state == ToolCallState.approval) {
        c
          ..state = failed ? ToolCallState.failed : ToolCallState.done
          ..ended = now;
      }
    }
  }
}
