import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/chat/chat.dart';

Future<List<SseEvent>> decode(List<List<int>> chunks) =>
    Stream.fromIterable(chunks).transform(const SseDecoder()).toList();

List<int> b(String s) => utf8.encode(s);

void main() {
  test('parses events split at arbitrary byte boundaries', () async {
    const text =
        'event: meta\ndata: {"conversation_id":"c","message_id":"m"}\n\n'
        ': keep-alive\n\n'
        'event: delta\ndata: {"text":"Grüße 🌍"}\n\n'
        'event: done\ndata: {"conversation_id":"c","message_id":"m"}\n\n';
    final bytes = b(text);
    // Every possible single split point, including inside multi-byte chars.
    for (var cut = 1; cut < bytes.length; cut += 3) {
      final events = await decode([bytes.sublist(0, cut), bytes.sublist(cut)]);
      expect(events.map((e) => e.event), [
        'meta',
        'delta',
        'done',
      ], reason: 'cut $cut');
      expect(jsonDecode(events[1].data)['text'], 'Grüße 🌍');
    }
    // One byte at a time.
    final events = await decode([
      for (final x in bytes) [x],
    ]);
    expect(events.length, 3);
  });

  test(
    'handles CRLF, multi-line data, comments and default event name',
    () async {
      final events = await decode([
        b('data: one\r\ndata: two\r\n\r\n'),
        b(':comment\r\n\r\n'),
        b('event:x\ndata:no-space\n\n'),
      ]);
      expect(events.length, 2);
      expect(events[0].event, 'message');
      expect(events[0].data, 'one\ntwo');
      expect(events[1].event, 'x');
      expect(events[1].data, 'no-space');
    },
  );

  test('drops an unterminated last event', () async {
    final events = await decode([
      b('event: delta\ndata: {"text":"a"}\n\nevent: delta\ndata: {"te'),
    ]);
    expect(events.length, 1);
  });

  test('parseChatEvent maps contract events and ignores junk', () {
    expect(
      ChatApi.parseChatEvent(const SseEvent('delta', '{"text":"hi"}')),
      isA<ChatDeltaEvent>().having((e) => e.text, 'text', 'hi'),
    );
    final s = ChatApi.parseChatEvent(
      const SseEvent(
        'status',
        '{"label":"df -h","state":"running","tool":"terminal","id":"t1","emoji":"💻"}',
      ),
    );
    expect(
      s,
      isA<ChatProgressEvent>()
          .having((e) => e.progress.state, 'state', ProgressState.running)
          .having((e) => e.progress.label, 'label', 'df -h'),
    );
    final err = ChatApi.parseChatEvent(
      const SseEvent(
        'error',
        '{"conversation_id":"c","message_id":"m","code":"hermes_busy","message":"x"}',
      ),
    );
    expect(
      err,
      isA<ChatFailedEvent>().having(
        (e) => e.error.kind,
        'kind',
        ChatErrorKind.busy,
      ),
    );
    expect(ChatApi.parseChatEvent(const SseEvent('delta', 'not json')), isNull);
    expect(ChatApi.parseChatEvent(const SseEvent('future', '{}')), isNull);
  });
}
