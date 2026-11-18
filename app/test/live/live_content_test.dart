import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/call/call_controller.dart';
import 'package:tove_chat/src/call/models.dart';
import 'package:tove_chat/src/chat/chat.dart';
import 'package:tove_chat/src/ui/live/live_activity.dart';
import 'package:tove_chat/src/ui/live/live_content.dart';

import '../fakes.dart';

void main() {
  group('extractSites', () {
    test('an existing source index is not repeated, and code is ignored', () {
      expect(
        hasSourceIndex('Answer\n\n**Sources:** [Docs](https://example.org)'),
        isTrue,
      );
      expect(
        hasSourceIndex('## Sources\n\n- [Docs](https://example.org)'),
        isTrue,
      );
      expect(hasSourceIndex('```text\nSources: example\n```'), isFalse);
      expect(hasSourceIndex('The sources are listed in the guide.'), isFalse);
      expect(
        LiveContent(
          id: 'a',
          text: 'Sources: [Docs](https://example.org)',
          time: DateTime(2026),
        ).sites,
        isEmpty,
      );
    });
    test('markdown links keep their text as the title', () {
      final s = extractSites(
        'See [the Proxmox docs](https://www.proxmox.com/en/docs) and '
        '[ZFS **tuning**](https://openzfs.github.io/openzfs-docs/Performance/).',
      );
      expect(s, hasLength(2));
      expect(s[0].title, 'the Proxmox docs');
      expect(s[0].host, 'proxmox.com');
      expect(s[1].title, 'ZFS tuning');
      expect(s[1].uri.toString(), startsWith('https://openzfs.github.io/'));
    });

    test('bare addresses get a title from the path, else the host', () {
      final s = extractSites(
        'Read https://example.org/guides/disk-usage-guide.html, then '
        'https://status.example.net/.',
      );
      expect(s.map((e) => e.title), ['Disk usage guide', 'status.example.net']);
    });

    test('duplicates, images, code and unsafe schemes are skipped', () {
      final s = extractSites('''
![chart](https://img.example.com/a.png)
[A](https://a.example.com/x) and again https://a.example.com/x
`https://code.example.com/inline`
```
https://code.example.com/fenced
```
[mail](mailto:me@example.com) [js](javascript:alert(1))
''');
      expect(s.map((e) => e.host), ['a.example.com']);
    });

    test('a link still streaming in is not a card yet', () {
      expect(extractSites('Look at [the docs](https://exa'), hasLength(1));
      expect(extractSites('Look at [the docs](https://exa').single.host, 'exa');
      expect(extractSites('Look at [the docs]('), isEmpty);
    });

    test('a linked image cites its page, never the image or its alt', () {
      // Real reply F1 (Hermes, 15 Nov 2026), trimmed: two linked images,
      // a photo credit and two footnote citations.
      const reply =
          'Red pandas are tree-dwelling mammals.[^1][^2]\n'
          '\n'
          '[![Red panda resting on a snowy branch](https://assets.worldwildlife.org/www-prd/images/wwfcmsprodimagesSleeping_red_pand.width-800.format-webp.webp)](https://www.worldwildlife.org/species/red-panda/)\n'
          '[![Red panda eating bamboo leaves](https://www.wwf.org.uk/sites/default/files/styles/ar_16x9_1024px/public/2022-04/_WW256800.jpg?h=82f92a78&itok=4uZKGzsO)](https://www.wwf.org.uk/learn/fascinating-facts/red-panda)\n'
          '\n'
          'Photo credits: Juan Carlos Munoz / naturepl.com / WWF-Canon; Ola Jennersten / WWF-Sweden.\n'
          '\n'
          '[^1]: [Red Panda](https://www.worldwildlife.org/species/red-panda/) — World Wildlife Fund.\n'
          '[^2]: [Top 5 facts about Red Pandas](https://www.wwf.org.uk/learn/fascinating-facts/red-panda) — WWF-UK.\n';
      final s = extractSites(reply);
      expect(s.map((e) => e.uri.toString()), [
        'https://www.worldwildlife.org/species/red-panda/',
        'https://www.wwf.org.uk/learn/fascinating-facts/red-panda',
      ]);
      expect(s.map((e) => e.title), [
        'Red Panda',
        'Top 5 facts about Red Pandas',
      ]);
      expect(s.every((e) => !e.title.contains('![')), isTrue);
    });

    test('a page behind only an image is titled from its address', () {
      final s = extractSites(
        '[![A red panda](https://img.example.com/p.jpg)](https://zoo.example.org/animals/red-panda)',
      );
      expect(s.single.uri.host, 'zoo.example.org');
      expect(s.single.title, 'Red panda');
    });

    test('escaped brackets, titles, parentheses and code spans', () {
      final s = extractSites(r'''
\[not a link\](https://plain.example.com/a) then
[Spec \[draft\]](https://spec.example.com/v2 "The spec") and
[Wiki](https://en.example.org/wiki/Panda_(disambiguation)).
`[code](https://code.example.com/x)` and ``![img](https://code.example.com/y)``
''');
      expect(s.map((e) => e.host), [
        'plain.example.com',
        'spec.example.com',
        'en.example.org',
      ]);
      expect(s[1].title, 'Spec [draft]');
      expect(s[2].uri.path, '/wiki/Panda_(disambiguation)');
    });

    test('at most max cards', () {
      final md = List.generate(12, (i) => 'https://s$i.example.com/').join(' ');
      expect(extractSites(md, max: 8), hasLength(8));
    });
  });

  group('content and activities from the call', () {
    late CallController call;
    final since = DateTime.now().subtract(const Duration(seconds: 1));

    setUp(() {
      final bridge = FakeBridge();
      call = CallController(
        apiFactory: bridge.api,
        transportFactory: FakeTransport.new,
        platform: FakePlatform(supported: false),
        voice: () => 'cove',
        timings: fastTimings,
        desktop: true,
      );
    });
    tearDown(() => call.dispose());

    test('tasks map to cards; T3 requests are marked', () {
      call.tasks
        ..add(TaskEntry('a', 'check the disk on NAS-01'))
        ..add(
          TaskEntry('b', 'ask T3 to fix the failing build')
            ..status = TaskStatus.running
            ..seconds = 4,
        )
        ..add(
          TaskEntry('c', 'restart Seerr')
            ..status = TaskStatus.busy
            ..detail = 'Two tasks were already running'
            ..finished = DateTime.now(),
        );
      final a = liveActivitiesFrom(call: call, chat: _noChat(), since: since);
      expect(a.map((e) => e.state), [
        LiveActivityState.running,
        LiveActivityState.running,
        LiveActivityState.failed,
      ]);
      expect(a.map((e) => e.kind), [
        LiveActivityKind.task,
        LiveActivityKind.t3,
        LiveActivityKind.task,
      ]);
      expect(a[1].elapsed(DateTime.now()), greaterThanOrEqualTo(4));
      expect(a[2].detail, 'Two tasks were already running');
    });

    test('a running task is no result; its finished markdown is', () {
      final t = TaskEntry('a', 'check the disk')..status = TaskStatus.running;
      call.tasks.add(t);
      final chat = _noChat();
      final running = liveContentById('task-a', call: call, chat: chat)!;
      expect(running.streaming, isTrue);
      expect(running.text, isEmpty);
      expect(running.title, 'check the disk');
      expect(
        liveContentFor(call: call, chat: chat, since: since),
        isNull,
        reason: 'running work stays under the orb; only results open',
      );
      t
        ..status = TaskStatus.done
        ..markdown = '## Disk\n40% full'
        ..seconds = 7
        ..finished = DateTime.now();
      final done = liveContentFor(call: call, chat: chat, since: since)!;
      expect(done.id, 'task-a');
      expect(done.kind, LiveContentKind.task);
      expect(done.text, '## Disk\n40% full');
      expect(done.seconds, 7);
    });

    test('a task the call ended on continues in the chat, not failed', () {
      call.tasks.add(
        TaskEntry('s', 'summarise the backups')
          ..status = TaskStatus.stopped
          ..detail = 'The call ended before Hermes finished'
          ..finished = DateTime.now(),
      );
      final a = liveActivitiesFrom(call: call, chat: _noChat(), since: since);
      expect(a.single.state, LiveActivityState.continuesInChat);
      expect(a.single.detail, continuesInChatNote);
      final c = liveContentById('task-s', call: call, chat: _noChat())!;
      expect(c.failed, isFalse);
      expect(c.continuesInChat, isTrue);
      expect(c.text, continuesInChatNote);
    });

    test('mentionsT3 matches the word, not parts of words', () {
      expect(mentionsT3('t3_code.run'), isTrue);
      expect(mentionsT3('Ask T3 to look'), isTrue);
      expect(mentionsT3('st3am'), isFalse);
      expect(mentionsT3(null), isFalse);
    });
  });
}

/// A chat with no messages.
ChatController _noChat() => ChatController(
  api: ChatApi(
    baseUrl: Uri.parse('https://bridge.test:9476'),
    accessKey: testKey,
    client: FakeBridge().client,
  ),
);
