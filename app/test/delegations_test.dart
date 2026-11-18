import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/call/delegations.dart';
import 'package:tove_chat/src/call/models.dart';
import 'package:tove_chat/src/call/protocol.dart';

import 'fakes.dart';

Map<String, dynamic> item(String id, String text) => {
  'id': id,
  'content': [
    {'type': 'input_text', 'text': text},
  ],
};

void main() {
  late FakeBridge bridge;
  late List<Map<String, dynamic>> sent;
  late List<TaskEntry> tasks;
  late DelegationRunner runner;
  var open = true;

  setUp(() {
    bridge = FakeBridge();
    sent = [];
    tasks = [];
    open = true;
    runner = DelegationRunner(
      api: bridge.api(),
      session: 'sid1',
      send: (m) {
        if (!open) return false;
        sent.add(m);
        return true;
      },
      tasks: tasks,
      onChanged: () {},
      timings: fastTimings,
    );
  });

  tearDown(() => runner.stop());

  String sentText(int i) =>
      ((sent[i]['content'] as List).single as Map)['text'] as String;

  test('small talk is answered without a task', () async {
    runner.handle(item('a', 'hey thanks'));
    await settle(5);
    expect(bridge.requests, isEmpty);
    expect(tasks, isEmpty);
    expect(sentText(0), VoiceNotes.chat);
  });

  test('duplicate delegation ids run once', () async {
    runner.handle(item('a', 'Check the backups on storage'));
    runner.handle(item('a', 'Check the backups on storage'));
    await settle(60);
    expect(bridge.to('/api/delegate'), hasLength(1));
    expect(tasks, hasLength(1));
    expect(sent, hasLength(1));
  });

  test('missing or empty ids are ignored', () async {
    runner.handle({'content': []});
    runner.handle({'id': '', 'content': []});
    await settle(5);
    expect(sent, isEmpty);
  });

  test('busy (429) is reported, never claimed as started', () async {
    bridge.delegateStatus = 429;
    runner.handle(item('a', 'Update all the containers on compute'));
    await settle(30);
    expect(tasks.single.status, TaskStatus.busy);
    expect(sentText(0), VoiceNotes.busy);
    expect(bridge.to('/api/job'), isEmpty);
  });

  test('a failed job is reported as failed', () async {
    bridge.jobResult = 'failed';
    runner.handle(item('a', 'Rotate the logs on core'));
    await settle(60);
    expect(tasks.single.status, TaskStatus.failed);
    expect(sentText(0), VoiceNotes.failed);
  });

  test('an empty answer is not dressed up as a result', () async {
    bridge.jobAnswer = '   ';
    runner.handle(item('a', 'What is the uptime of core'));
    await settle(60);
    expect(tasks.single.status, TaskStatus.done);
    expect(sentText(0), VoiceNotes.emptyResult);
  });

  test('results are stripped of markdown and clipped', () async {
    bridge.jobAnswer = '**Bold** `code` ${'x' * 5000}';
    runner.handle(item('a', 'Write me a long report about storage'));
    await settle(60);
    final text = sentText(0);
    expect(text, startsWith('Task result.'));
    expect(text, contains('Bold code'));
    expect(text.length, 3500);
    expect(tasks.single.detail, startsWith('**Bold**'));
  });

  test('a vanished job (404) fails instead of polling forever', () async {
    runner.handle(item('a', 'Check the media library size'));
    await settle(2);
    bridge.runningPolls.clear();
    await settle(60);
    expect(tasks.single.status, TaskStatus.failed);
  });

  test('stop() ends polling and marks active tasks stopped', () async {
    bridge.defaultRunningPolls = 1000;
    runner.handle(item('a', 'Scan the whole NAS for duplicates'));
    await settle(30);
    expect(tasks.single.status, TaskStatus.running);
    runner.stop();
    expect(tasks.single.status, TaskStatus.stopped);
    final n = bridge.requests.length;
    await settle(30);
    expect(bridge.requests.length, n);
    expect(sent, isEmpty);
  });

  test('a result after the channel closed says it was not heard', () async {
    open = false;
    runner.handle(item('a', 'How much RAM is free on compute'));
    await settle(60);
    expect(tasks.single.status, TaskStatus.done);
    expect(tasks.single.detail, contains('no longer connected'));
  });
}
