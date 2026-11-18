import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/call/models.dart';
import 'package:tove_chat/src/chat/chat.dart';

ChatMessage voice(
  String id,
  MessageRole role,
  String text, {
  String? clientId,
  MessageSource source = MessageSource.voice,
}) => ChatMessage(
  id: id,
  conversationId: 'c1',
  role: role,
  text: text,
  source: source,
  created: DateTime.fromMillisecondsSinceEpoch(1000),
  clientId: clientId,
);

const u = MessageRole.user, a = MessageRole.assistant;

void main() {
  group('collapseVoiceFragments', () {
    test('hides the fragments the screenshot shows, keeps every real turn', () {
      // As saved by the old app: entry ids 1..6 of call sess1.
      final saved = [
        voice('m1', u, 'Can', clientId: 'turn:sess1-1'),
        voice(
          'm2',
          u,
          'Can you download and can you download the entire internet',
          clientId: 'turn:sess1-2',
        ),
        voice('m3', a, "I'll", clientId: 'turn:sess1-3'),
        voice('m4', a, "I'll check that quickly.", clientId: 'turn:sess1-4'),
        voice('m5', a, 'Not', clientId: 'turn:sess1-5'),
        voice(
          'm6',
          a,
          'Not realistically. It is enormous.',
          clientId: 'turn:sess1-6',
        ),
      ];
      expect(collapseVoiceFragments(saved).map((m) => m.id), [
        'm2',
        'm4',
        'm6',
      ]);
    });

    test('genuinely separate turns stay', () {
      final cases = <List<ChatMessage>>[
        // The same words twice.
        [
          voice('a', u, 'Can', clientId: 'turn:s-1'),
          voice('b', u, 'Can', clientId: 'turn:s-2'),
        ],
        // Something was said in between (entry 2 is not shown here).
        [
          voice('a', u, 'Can', clientId: 'turn:s-1'),
          voice('b', u, 'Can you hear me', clientId: 'turn:s-3'),
        ],
        // Different calls.
        [
          voice('a', u, 'Can', clientId: 'turn:s-1'),
          voice('b', u, 'Can you hear me', clientId: 'turn:t-2'),
        ],
        // Different speakers.
        [
          voice('a', u, 'Can', clientId: 'turn:s-1'),
          voice('b', a, 'Can you hear me', clientId: 'turn:s-2'),
        ],
        // Not a word boundary.
        [
          voice('a', u, 'Can', clientId: 'turn:s-1'),
          voice('b', u, 'Cannot do it', clientId: 'turn:s-2'),
        ],
        // Longer than a first chunk.
        [
          voice('a', u, 'Please check the disk now', clientId: 'turn:s-1'),
          voice(
            'b',
            u,
            'Please check the disk now and tell me',
            clientId: 'turn:s-2',
          ),
        ],
        // Typed messages are never touched.
        [
          voice('a', u, 'Can', source: MessageSource.text),
          voice('b', u, 'Can you hear me', source: MessageSource.text),
        ],
        // No client ids (unknown origin).
        [voice('a', u, 'Can'), voice('b', u, 'Can you hear me')],
      ];
      for (final c in cases) {
        expect(collapseVoiceFragments(c).length, 2, reason: '$c');
      }
    });
  });

  test('imported turns carry the time they were spoken', () {
    final spoken = DateTime.fromMillisecondsSinceEpoch(1794691021626);
    final turns = liveTurnsFromTranscript([
      TranscriptEntry(1, Speaker.user, created: spoken)..text = 'Hi',
    ], key: 'sess');
    expect(turns.single.created, spoken);
    expect(turns.single.toJson()['created'], 1794691021626);
    expect(turns.single.id, 'sess-1');
  });
}
