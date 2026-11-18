import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/call/models.dart';
import 'package:tove_chat/src/chat/chat.dart';

TranscriptEntry entry(int id, Speaker s, String text, [DateTime? at]) =>
    TranscriptEntry(id, s, created: at ?? DateTime(2026, 11, 16, 0, 37))
      ..text = text
      ..live = false;

LiveTurn turn(MessageRole role, String text, [int? ms]) => LiveTurn(
  role: role,
  text: text,
  created: ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms),
);

List<(MessageRole, String)> texts(List<LiveTurn> turns) => [
  for (final t in turns) (t.role, t.text),
];

const user = MessageRole.user, hermes = MessageRole.assistant;

void main() {
  test('the screenshot call: one message per spoken turn', () {
    // What an older build saved after "No, I think it's time to let you go".
    final transcript = [
      entry(242, Speaker.user, 'No'),
      entry(243, Speaker.user, "No, I think it's time to let you go. Bye"),
      entry(244, Speaker.hermes, 'Alright, bye'),
      entry(245, Speaker.hermes, 'Alright, bye for now.'),
      entry(246, Speaker.hermes, 'Goodbye,'),
      entry(247, Speaker.hermes, 'Goodbye, Alex. Take care of yourself.'),
    ];
    final turns = liveTurnsFromTranscript(transcript, key: 'U-BQ');
    expect(texts(turns), [
      (user, "No, I think it's time to let you go. Bye"),
      (hermes, 'Alright, bye for now. Goodbye, Alex. Take care of yourself.'),
    ]);
    expect(turns.map((t) => t.id), ['U-BQ-242', 'U-BQ-244']);
    expect(turns.first.created, transcript.first.created);
    // Posting the same call twice gives the same ids (the bridge skips them).
    expect(liveTurnsFromTranscript(transcript, key: 'U-BQ').map((t) => t.id), [
      'U-BQ-242',
      'U-BQ-244',
    ]);
  });

  test('prefixes, repeats and late copies fold into the full text', () {
    expect(
      texts(mergeVoiceTurns([turn(hermes, 'Uh-h'), turn(hermes, 'Uh-huh.')])),
      [(hermes, 'Uh-huh.')],
    );
    expect(texts(mergeVoiceTurns([turn(user, 'Calm'), turn(user, 'Calm')])), [
      (user, 'Calm'),
    ]);
    expect(
      texts(
        mergeVoiceTurns([
          turn(user, 'Check the disk please'),
          turn(user, 'check the disk'),
        ]),
      ),
      [(user, 'Check the disk please')],
    );
  });

  test('the other speaker in between keeps equal words apart', () {
    final turns = mergeVoiceTurns([
      turn(user, 'Yes'),
      turn(hermes, 'Okay.'),
      turn(user, 'Yes'),
    ]);
    expect(turns.length, 3);
  });

  test('a cut-off reply gives way; a short user pause is joined', () {
    expect(
      texts(
        mergeVoiceTurns([
          turn(hermes, 'Okay, so', 0),
          turn(hermes, "Sure, here's the plan.", 900),
        ]),
      ),
      [(hermes, "Sure, here's the plan.")],
    );
    expect(
      texts(
        mergeVoiceTurns([
          turn(user, 'Thanks', 0),
          turn(user, 'can you also check sonarr', 2000),
        ]),
      ),
      [(user, 'Thanks can you also check sonarr')],
    );
  });

  test('far apart in time: two turns', () {
    final turns = mergeVoiceTurns([
      turn(hermes, 'Sure, checking now.', 0),
      turn(hermes, 'All servers are up.', 30000),
    ]);
    expect(texts(turns), [
      (hermes, 'Sure, checking now.'),
      (hermes, 'All servers are up.'),
    ]);
  });

  test('blank entries are dropped and long joins stay within the limit', () {
    expect(mergeVoiceTurns([turn(user, '   ')]), isEmpty);
    final turns = mergeVoiceTurns([
      turn(user, '${'alpha ' * 800}.', 0),
      turn(user, 'beta ' * 800, 1000),
    ]);
    expect(turns.single.text.length, 8000);
  });

  test('voiceNorm ignores case and punctuation', () {
    expect(voiceNorm('Goodbye,'), 'goodbye');
    expect(voiceNorm('  Goodbye,  Alex. '), 'goodbye alex');
    expect(voiceNorm('Everything’s up'), 'everythings up');
  });
}
