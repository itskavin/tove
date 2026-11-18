import '../call/models.dart';
import 'models.dart';

final _badIdChars = RegExp(r'[^A-Za-z0-9_-]');

/// Makes [raw] a valid bridge id (1–64 chars of `A-Za-z0-9_-`).
String bridgeId(String raw) {
  var s = raw.replaceAll(_badIdChars, '_');
  if (s.isEmpty) s = 'x';
  return s.length > 64 ? s.substring(s.length - 64) : s;
}

/// A key that tells one call's turns apart from another's. Pass the call's
/// session id when there is one.
String callKey([String? session]) => session != null && session.isNotEmpty
    ? session
    : 'call${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';

/// Converts `CallController.transcript` to [LiveTurn]s, one per spoken turn
/// (see [mergeVoiceTurns]). Turn ids are `<key>-<entry id>` of a turn's first
/// entry, so posting the same call twice adds nothing.
List<LiveTurn> liveTurnsFromTranscript(
  Iterable<TranscriptEntry> entries, {
  required String key,
}) => mergeVoiceTurns([
  for (final e in entries)
    if (e.text.trim().isNotEmpty)
      LiveTurn(
        id: bridgeId('$key-${e.id}'),
        role: e.speaker == Speaker.user
            ? MessageRole.user
            : MessageRole.assistant,
        text: e.text.trim(),
        // When it was spoken, so typed turns and task results saved during
        // the call sort around it correctly.
        created: e.created,
      ),
]);

/// Same-speaker entries that start closer together than this are one turn.
const voiceJoinGap = Duration(seconds: 20);

/// An assistant entry this short, without closing punctuation, was cut off.
const voiceFragmentWords = 3;

final _voiceNoise = RegExp(r'[^\p{L}\p{N}\s]', unicode: true);
final _space = RegExp(r'\s+');
final _sentenceEnd = RegExp(r'''[.!?…。！？]["'”’)\]]*$''');

/// Lower case, no punctuation, single spaces: "Goodbye," and
/// "Goodbye, Alex." then compare as prefix and text.
String voiceNorm(String text) => text
    .toLowerCase()
    .replaceAll(_voiceNoise, '')
    .trim()
    .split(_space)
    .join(' ');

/// Folds a call's transcript entries into one [LiveTurn] per spoken turn,
/// the same way the bridge does (`merge_voice_turns`). A turn's transcript
/// arrives in pieces, and GPT-Live can cut a reply off and start again, so
/// the transcript may hold "Alright, bye" and then "Alright, bye for now.".
/// Within a run of one speaker:
///
///  * an entry that the next one repeats and extends (compared without case
///    or punctuation), or repeats exactly, gives way to the longer one; a
///    shorter copy after it is dropped;
///  * an assistant entry of at most [voiceFragmentWords] words without
///    closing punctuation, followed within [voiceJoinGap], was cut off and
///    gives way to the next;
///  * what is left of entries that start within [voiceJoinGap] of each other
///    is joined with a space.
///
/// Each result keeps its first entry's id and time. Turns of the other
/// speaker in between always keep two turns apart, even with the same words.
List<LiveTurn> mergeVoiceTurns(List<LiveTurn> turns) {
  final out = <_Run>[];
  for (final t in turns) {
    final text = t.text.trim().split(_space).join(' ');
    if (text.isEmpty) continue;
    final g = out.isNotEmpty && out.last.first.role == t.role ? out.last : null;
    if (g != null) {
      final last = g.segments.last;
      final a = voiceNorm(last), b = voiceNorm(text);
      final near =
          t.created == null ||
          g.lastCreated == null ||
          t.created!.difference(g.lastCreated!) <= voiceJoinGap;
      if (b.startsWith(a) || a.startsWith(b) || near) {
        if (b.startsWith(a)) {
          g.segments.last = text;
        } else if (a.startsWith(b)) {
          // A late, shorter copy of what is already there.
        } else if (t.role == MessageRole.assistant &&
            last.split(' ').length <= voiceFragmentWords &&
            !_sentenceEnd.hasMatch(last)) {
          g.segments.last = text;
        } else {
          g.segments.add(text);
        }
        if (t.created != null) g.lastCreated = t.created;
        continue;
      }
    }
    out.add(_Run(t, text));
  }
  return [
    for (final g in out)
      LiveTurn(
        id: g.first.id,
        role: g.first.role,
        text: _cap(g.segments.join(' ')),
        created: g.first.created,
      ),
  ];
}

/// The bridge refuses turns over 8000 characters (`limits.message_chars`).
const _maxTurnChars = 8000;

String _cap(String s) =>
    s.length <= _maxTurnChars ? s : s.substring(0, _maxTurnChars);

class _Run {
  _Run(this.first, String text)
    : segments = [text],
      lastCreated = first.created;
  final LiveTurn first;
  final List<String> segments;
  DateTime? lastCreated;
}

/// Converts finished `CallController.tasks` to [LiveTask]s. Only needed for
/// calls that were not linked to a chat (the bridge saves linked ones).
///
/// The task id is the bridge job id when known (the bridge dedups on session +
/// job id), else `<key>-<item id>`. The answer is Hermes' markdown, falling
/// back to the voice-ready text.
List<LiveTask> liveTasksFromEntries(
  Iterable<TaskEntry> tasks, {
  required String key,
}) => [
  for (final t in tasks)
    if (t.status == TaskStatus.done || t.status == TaskStatus.failed)
      LiveTask(
        id: bridgeId(
          t.job != null && t.job!.isNotEmpty ? t.job! : '$key-${t.itemId}',
        ),
        request: t.text,
        answer: t.status == TaskStatus.done
            ? (t.markdown ?? t.detail ?? '')
            : '',
        done: t.status == TaskStatus.done,
        seconds: t.seconds,
        created: t.created,
      ),
];
