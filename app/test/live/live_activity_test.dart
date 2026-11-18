import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/live/live_activity.dart';

final _t0 = DateTime(2026, 11, 15, 12);

LiveActivity _a(
  String id, {
  LiveActivityState state = LiveActivityState.running,
  int at = 0,
  DateTime? finished,
  LiveActivityKind kind = LiveActivityKind.task,
}) => LiveActivity(
  id: id,
  label: id,
  kind: kind,
  state: state,
  started: _t0.add(Duration(seconds: at)),
  finished: finished,
  contentId: id,
);

DateTime _s(num seconds) =>
    _t0.add(Duration(milliseconds: (seconds * 1000).round()));

void main() {
  test('lifecycle: running → done lingers 6 s → gone', () {
    final t = LiveActivityTracker();
    t.update([_a('task-1')], _s(0));
    expect(t.visible(_s(1)).single.running, isTrue);
    expect(t.nextExpiry(_s(1)), isNull);

    t.update([
      _a('task-1', state: LiveActivityState.done, finished: _s(5)),
    ], _s(5));
    final done = t.visible(_s(5)).single;
    expect(done.state, LiveActivityState.done);
    expect(done.elapsed(_s(30)), 5, reason: 'stops counting once finished');
    expect(t.nextExpiry(_s(5)), _s(11));
    expect(t.visible(_s(10.9)), hasLength(1));
    expect(t.visible(_s(11)), isEmpty);
    expect(t.nextExpiry(_s(11)), isNull);
  });

  test('failed cards stay 10 s', () {
    final t = LiveActivityTracker();
    t.update([
      _a('task-1', state: LiveActivityState.failed, finished: _s(2)),
    ], _s(2));
    expect(t.visible(_s(11.9)), hasLength(1));
    expect(t.visible(_s(12)), isEmpty);
  });

  test(
    'a tool step that leaves the stream is done; tools time from first sight',
    () {
      final t = LiveActivityTracker();
      t.update([_a('tool-m1-a', kind: LiveActivityKind.tool, at: -60)], _s(3));
      expect(t.visible(_s(4)).single.elapsed(_s(4)), 1);
      t.update([_a('tool-m1-b', kind: LiveActivityKind.t3)], _s(6));
      final v = t.visible(_s(6));
      expect(v.map((e) => e.id), ['tool-m1-a', 'tool-m1-b']);
      expect(v.first.state, LiveActivityState.done);
      expect(v.first.finished, _s(6));
      expect(v.last.kind, LiveActivityKind.t3);
      t.update(const [], _s(8));
      expect(t.visible(_s(8)).last.state, LiveActivityState.done);
    },
  );

  test('at most 3 cards, running ones first, oldest on top', () {
    final t = LiveActivityTracker();
    t.update([
      _a('task-1', state: LiveActivityState.done, finished: _s(1)),
      _a('task-2', state: LiveActivityState.done, finished: _s(2)),
      _a('task-3', at: 1),
      _a('task-4', at: 2),
      _a('task-5', state: LiveActivityState.failed, finished: _s(3)),
    ], _s(3));
    final v = t.visible(_s(3));
    expect(v.map((e) => e.id), ['task-3', 'task-4', 'task-5']);
    t.clear();
    expect(t.visible(_s(3)), isEmpty);
  });

  test('a bridge count larger than the local one wins', () {
    final a = LiveActivity(
      id: 'task-1',
      label: 'x',
      kind: LiveActivityKind.task,
      state: LiveActivityState.running,
      started: _s(0),
      seconds: 9,
    );
    expect(a.elapsed(_s(2)), 9);
    expect(a.elapsed(_s(12)), 12);
    expect(a.elapsed(_s(-5)), 9, reason: 'never negative');
  });
}
