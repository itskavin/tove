import 'dart:async';

import '../bridge/bridge_api.dart';
import '../chat/models.dart' show ChatProgress, ProgressState;
import '../config.dart';
import '../chat/tool_calls.dart' show ToolCallState;
import 'models.dart';
import 'protocol.dart';
import '../brand.dart';

/// Runs GPT-Live delegations as Hermes jobs for one call:
/// `delegation.created` -> `POST /api/delegate` -> poll `GET /api/job` ->
/// `delegation.context.append`. Each item id is handled once.
class DelegationRunner {
  DelegationRunner({
    required this.api,
    required this.session,
    required this.send,
    required this.tasks,
    required this.onChanged,
    this.conversationId,
    this.timings = const CallTimings(),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final BridgeApi api;
  final String session;

  /// Sends a data-channel message; false when the channel is gone.
  final bool Function(Map<String, dynamic>) send;

  /// Shared, newest last. Owned by the call controller.
  final List<TaskEntry> tasks;
  final void Function() onChanged;

  /// The chat the call is linked to; stamped on every task.
  final String? conversationId;
  final CallTimings timings;
  final DateTime Function() _now;

  final Set<String> _seen = {};
  final Set<Completer<void>> _sleeps = {};
  bool _stopped = false;

  /// Handles a `delegation.created` item.
  void handle(Map<String, dynamic> item) {
    if (_stopped) return;
    final id = item['id'];
    if (id is! String || id.isEmpty || !_seen.add(id)) return;
    final text = delegationText(item);
    if (isFiller(text)) {
      send(contextAppend(id, VoiceNotes.chat));
      return;
    }
    final task = TaskEntry(
      id,
      text,
      conversationId: conversationId,
      session: session,
    );
    tasks.add(task);
    onChanged();
    unawaited(_run(task));
  }

  Future<void> _run(TaskEntry task) async {
    final String job;
    try {
      job = await api.delegate(
        session: session,
        text: task.text.length > kMaxTaskChars
            ? task.text.substring(0, kMaxTaskChars)
            : task.text,
      );
    } on BridgeException catch (e) {
      if (_stopped) return;
      if (e.busy) {
        _finish(
          task,
          TaskStatus.busy,
          'Two tasks were already running',
          VoiceNotes.busy,
        );
      } else {
        _finish(task, TaskStatus.failed, e.message, VoiceNotes.notStarted);
      }
      return;
    }
    if (_stopped) return;
    task.job = job;
    task.status = TaskStatus.running;
    onChanged();

    var failures = 0;
    while (true) {
      await _sleep(timings.jobPoll);
      if (_stopped) return;
      final JobStatus j;
      try {
        j = await api.job(session: session, job: job);
      } on BridgeException catch (e) {
        if (_stopped) return;
        if (e.status == 404 ||
            e.unauthorized ||
            ++failures >= timings.maxPollFailures) {
          _finish(task, TaskStatus.failed, e.message, VoiceNotes.failed);
          return;
        }
        continue;
      }
      if (_stopped) return;
      failures = 0;
      task.seconds = j.seconds;
      switch (j.state) {
        case JobState.running:
          _progress(task, j.statusEvent);
          onChanged();
        case JobState.done:
          final answer = j.answer.trim();
          if (answer.isEmpty) {
            _finish(
              task,
              TaskStatus.done,
              '${Brand.assistantName} returned no answer',
              VoiceNotes.emptyResult,
            );
          } else {
            task.markdown = j.markdown?.trim() ?? answer;
            _finish(task, TaskStatus.done, answer, VoiceNotes.result(answer));
          }
          return;
        case JobState.failed:
          _finish(
            task,
            TaskStatus.failed,
            '${Brand.assistantName} failed',
            VoiceNotes.failed,
          );
          return;
      }
    }
  }

  /// Records the job's newest tool step. Polling sees only the newest one,
  /// so a step that is replaced by a different one has ended by then.
  void _progress(TaskEntry task, Map<String, dynamic>? event) {
    if (event == null) return;
    final p = ChatProgress.fromJson(event);
    if (p.label.trim().isEmpty && (p.tool ?? '').trim().isEmpty) return;
    final now = _now();
    task.progress = p;
    if (p.state == ProgressState.running || p.state == ProgressState.unknown) {
      for (final c in task.tools.calls) {
        final same = (p.id ?? '').isNotEmpty
            ? c.id == p.id
            : c.tool == (p.tool ?? '');
        if (c.running && !same) {
          c
            ..state = ToolCallState.done
            ..ended = now;
        }
      }
    }
    task.tools.record(p, -1, now);
  }

  void _finish(TaskEntry t, TaskStatus status, String detail, String note) {
    t.status = status;
    t.finished = _now();
    t.progress = null;
    t.tools.finish(t.finished!, failed: status != TaskStatus.done);
    t.detail = detail;
    if (!send(contextAppend(t.itemId, note)) && status == TaskStatus.done) {
      t.detail = '$detail\n(The call was no longer connected to hear it.)';
    }
    onChanged();
  }

  Future<void> _sleep(Duration d) {
    final c = Completer<void>();
    _sleeps.add(c);
    final timer = Timer(d, () {
      if (!c.isCompleted) c.complete();
    });
    return c.future.whenComplete(() {
      timer.cancel();
      _sleeps.remove(c);
    });
  }

  /// Ends polling. Active tasks are reported as stopped here, but the bridge
  /// now lets them finish after the call and saves the result to the linked
  /// chat (and pushes `live.task`), so they read "Continues in the chat".
  void stop() {
    if (_stopped) return;
    _stopped = true;
    for (final c in _sleeps.toList()) {
      if (!c.isCompleted) c.complete();
    }
    var changed = false;
    for (final t in tasks) {
      if (t.active) {
        // The job keeps running on the bridge: its steps are not over.
        t.status = TaskStatus.stopped;
        t.detail = 'Continues in the chat';
        changed = true;
      }
    }
    if (changed) onChanged();
  }
}
