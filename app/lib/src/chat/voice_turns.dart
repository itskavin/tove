import 'models.dart';

final _turnClientId = RegExp(r'^turn:(.+)-(\d+)$');

/// Hides voice-turn fragments that older app versions saved.
///
/// Before the transcript fix, a turn whose first transcript chunk arrived
/// before its `turn.created` was saved twice: once as that first chunk
/// ("Can", "I'll", "Not") and once in full. Such a fragment is recognisable
/// without comparing turns in general:
///
///  * both messages are `source: voice`, from the same speaker, and next to
///    each other in the chat;
///  * both were posted by the app for the same call, as consecutive entries
///    (`client_id` `turn:<call>-<n>` and `turn:<call>-<n+1>`; the entry
///    counter is shared by both speakers, so nothing was said in between);
///  * the first is at most four words, and the second starts with exactly
///    that text followed by a word boundary, and is longer.
///
/// Only the fragment is hidden (the stored data is unchanged). Turns that
/// repeat the same words, belong to different calls, are not consecutive or
/// were said by different speakers always stay.
List<ChatMessage> collapseVoiceFragments(List<ChatMessage> messages) {
  List<ChatMessage>? out;
  for (var i = 0; i < messages.length; i++) {
    final m = messages[i];
    final next = i + 1 < messages.length ? messages[i + 1] : null;
    if (next != null && isVoiceFragment(m, next)) {
      out ??= messages.sublist(0, i);
      continue;
    }
    out?.add(m);
  }
  return out ?? messages;
}

/// Whether [m] is a saved fragment of [next] (see [collapseVoiceFragments]).
bool isVoiceFragment(ChatMessage m, ChatMessage next) {
  if (!m.isVoice || !next.isVoice || m.role != next.role) return false;
  final a = _turnClientId.firstMatch(m.clientId ?? '');
  final b = _turnClientId.firstMatch(next.clientId ?? '');
  if (a == null || b == null || a[1] != b[1]) return false;
  final n = int.tryParse(a[2]!), n2 = int.tryParse(b[2]!);
  if (n == null || n2 != n + 1) return false;
  final part = m.text.trim(), full = next.text.trim();
  if (part.isEmpty || full.length <= part.length) return false;
  if (part.split(RegExp(r'\s+')).length > 4) return false;
  if (!full.startsWith(part)) return false;
  final after = full[part.length];
  return RegExp(r"[\s.,;:!?…'’\-]").hasMatch(after);
}
