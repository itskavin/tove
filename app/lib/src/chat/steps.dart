import 'dart:convert';

import 'tool_calls.dart';

/// What a reply step is: the model's thinking, or one tool it ran.
enum StepKind { thinking, tool }

/// Where a step is.
enum StepPhase { running, done, failed }

/// One tool call inside a [ReplyStep] (API.md "Steps", `step.tool`).
class StepTool {
  const StepTool({
    required this.name,
    this.label = '',
    this.emoji = '',
    this.callId,
    this.input,
    this.output,
    this.exitStatus,
    this.error,
    this.truncated = false,
    this.details = false,
  });

  static StepTool fromJson(Object? j) {
    if (j is! Map) return const StepTool(name: '');
    final exit = j['exit_status'];
    final error = j['error'];
    final output = j['output'];
    return StepTool(
      name: '${j['name'] ?? ''}',
      label: '${j['label'] ?? ''}',
      emoji: '${j['emoji'] ?? ''}',
      callId: j['call_id'] is String ? j['call_id'] as String : null,
      input: j['input'],
      output: output == null ? null : (output is String ? output : '$output'),
      exitStatus: exit is num ? exit.toInt() : null,
      error: error is String && error.isNotEmpty ? error : null,
      truncated: j['truncated'] == true,
      details: j['details'] == true,
    );
  }

  /// Hermes' tool name (`terminal`, `web_search`, …).
  final String name;

  /// The short preview Hermes streams (`echo hi`, a query, a URL).
  final String label;
  final String emoji;
  final String? callId;

  /// The tool the step really ran. Hermes loads some tools lazily and runs
  /// them through `tool_call` (`{"calls": [{"name": "image_search", …}]}`);
  /// that shows as the inner tool's name. Otherwise [name].
  String get shownName {
    if (name.trim() != 'tool_call') return name;
    var args = input;
    if (args is String) {
      try {
        args = jsonDecode(args);
      } on FormatException {
        return name;
      }
    }
    final calls = args is Map ? args['calls'] : null;
    if (calls is! List) return name;
    for (final c in calls) {
      final inner = c is Map ? c['name'] : null;
      if (inner is String && inner.trim().isNotEmpty) return inner.trim();
    }
    return name;
  }

  /// The arguments: a JSON object when they parsed, else a string, or null.
  final Object? input;

  /// The result text, or null when the bridge could not read it.
  final String? output;
  final int? exitStatus;
  final String? error;

  /// Input or output was cut by the bridge (8,192 characters each).
  final bool truncated;

  /// False when input and output come from the stream preview only.
  final bool details;

  Map<String, Object?> toJson() => {
    'name': name,
    'label': label,
    'emoji': emoji,
    'call_id': ?callId,
    'input': input,
    'output': output,
    'exit_status': exitStatus,
    'error': error,
    'truncated': truncated,
    'details': details,
  };
}

/// One entry of a reply's timeline: thinking text or a tool call.
///
/// Built from the bridge's `step.*` events and `meta.steps` (API.md "Steps"),
/// or, for bridges without steps, from the `status` events and `meta.tools`
/// through [stepsFromToolCalls] (no input or output then).
class ReplyStep {
  ReplyStep({
    required this.id,
    required this.kind,
    required this.started,
    this.state = StepPhase.running,
    this.ended,
    this.offset = -1,
    this.text = '',
    this.truncated = false,
    this.tool,
  });

  static ReplyStep? fromJson(Object? j) {
    if (j is! Map) return null;
    final started = j['started_at'];
    if (started is! num) return null;
    final ended = j['ended_at'];
    final kind = j['kind'] == 'thinking' ? StepKind.thinking : StepKind.tool;
    return ReplyStep(
      id: '${j['id'] ?? ''}',
      kind: kind,
      state: switch (j['state']) {
        'running' => StepPhase.running,
        'failed' || 'error' => StepPhase.failed,
        _ => StepPhase.done,
      },
      started: DateTime.fromMillisecondsSinceEpoch(started.toInt()),
      ended: ended is num
          ? DateTime.fromMillisecondsSinceEpoch(ended.toInt())
          : null,
      offset: j['offset'] is num ? (j['offset'] as num).toInt() : -1,
      text: j['text'] is String ? j['text'] as String : '',
      truncated: j['truncated'] == true,
      tool: kind == StepKind.tool ? StepTool.fromJson(j['tool']) : null,
    );
  }

  final String id;
  final StepKind kind;
  StepPhase state;

  /// Bridge-clock start and end (the end is null while running).
  final DateTime started;
  DateTime? ended;

  /// Characters of reply text written when the step started (−1 unknown).
  final int offset;

  /// Thinking text (markdown); empty for tools.
  String text;
  bool truncated;
  final StepTool? tool;

  bool get running => state == StepPhase.running;
  bool get isTool => kind == StepKind.tool;

  Duration elapsed(DateTime now) {
    final d = (ended ?? now).difference(started);
    return d.isNegative ? Duration.zero : d;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'state': state.name,
    'started_at': started.millisecondsSinceEpoch,
    'ended_at': ended?.millisecondsSinceEpoch,
    'offset': offset,
    if (kind == StepKind.thinking) 'text': text,
    if (kind == StepKind.thinking) 'truncated': truncated,
    if (tool != null) 'tool': tool!.toJson(),
  };
}

/// Folds one reply's `step.start` / `step.delta` / `step.end` events.
class StepLog {
  final List<ReplyStep> steps = [];

  bool get isEmpty => steps.isEmpty;

  void start(ReplyStep s) {
    final i = steps.indexWhere((e) => e.id == s.id);
    if (i >= 0) {
      steps[i] = s;
    } else {
      steps.add(s);
    }
  }

  void delta(String id, String text) {
    for (final s in steps.reversed) {
      if (s.id == id) {
        s.text += text;
        return;
      }
    }
  }

  /// The step's final form replaces the running copy.
  void end(ReplyStep s) => start(s);

  /// A resume `snapshot`: the bridge's list so far.
  void replaceAll(Iterable<ReplyStep> list) {
    steps
      ..clear()
      ..addAll(list);
  }

  /// The reply ended: steps still running ended with it (failed for an
  /// error or a stop). The bridge sends every `step.end` before the end, so
  /// this only matters when the stream was cut.
  void finish(DateTime now, {required bool failed}) {
    for (final s in steps) {
      if (s.running) {
        s
          ..state = failed ? StepPhase.failed : StepPhase.done
          ..ended = now;
      }
    }
  }
}

/// The adapter for bridges without `steps`: tool calls rebuilt from the
/// `status` events (live) or `meta.tools` (stored). They carry a name, the
/// preview label, a state and times, but no input or output.
List<ReplyStep> stepsFromToolCalls(List<ToolCall> calls) => [
  for (final (i, c) in calls.indexed)
    ReplyStep(
      id: c.id.isEmpty ? 'tool-$i' : c.id,
      kind: StepKind.tool,
      started: c.started,
      ended: c.ended,
      offset: c.offset,
      state: switch (c.state) {
        ToolCallState.running || ToolCallState.approval => StepPhase.running,
        ToolCallState.done => StepPhase.done,
        ToolCallState.failed => StepPhase.failed,
      },
      tool: StepTool(
        name: c.state == ToolCallState.approval ? 'approval' : c.tool,
        label: c.label,
        emoji: c.emoji,
        callId: c.id.isEmpty ? null : c.id,
      ),
    ),
];

/// Parses a stored `meta.steps` list.
List<ReplyStep> stepsFromJson(Object? list) =>
    list is List ? [for (final j in list) ?ReplyStep.fromJson(j)] : const [];

/// One reply's timeline from two partial copies, joined by step id: the
/// [stored] `meta.steps` (the bridge saves the whole list every 2 s and at
/// the end) and the [live] steps this device folded from `step.*` events.
///
/// A reply resumed after an app restart with a saved `Last-Event-ID` only
/// hears the events after that id, so its live list can hold just the last
/// step or two; the stored copy fills in the rest. For an id in both, the
/// live copy wins unless it is still running and the stored one has ended.
/// Order: the stored order, then live-only steps in their order.
List<ReplyStep> mergeSteps(List<ReplyStep> stored, List<ReplyStep> live) {
  if (stored.isEmpty) return live;
  if (live.isEmpty) return stored;
  final byId = {for (final s in live) s.id: s};
  final out = <ReplyStep>[];
  final seen = <String>{};
  for (final s in stored) {
    final l = byId[s.id];
    out.add(l == null || (l.running && !s.running) ? s : l);
    seen.add(s.id);
  }
  for (final s in live) {
    if (seen.add(s.id)) out.add(s);
  }
  return out;
}
