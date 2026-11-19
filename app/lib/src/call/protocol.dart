/// GPT-Live data channel (`oai-events`) helpers, matching hermes-live.html.
library;

import '../config.dart';

const String kDataChannelLabel = 'oai-events';

const Set<String> _filler = {
  'hello', 'hi', 'hey', 'ok', 'okay', 'yes', 'yeah', 'no', 'nope', 'thanks', //
  'thank', 'you', 'hmm', 'mm', 'uh', 'um', 'ah', 'right', 'sure', 'well', //
  'so', 'and', 'the', 'a',
};

/// True when a delegated "task" is only small talk (same rule as the page and
/// the bridge's `is_filler`).
bool isFiller(String text) {
  final words = text
      .toLowerCase()
      .replaceAll(RegExp(r"[^\w\s']"), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return true;
  final hits = words.where(_filler.contains).length;
  return text.length <= 60 && hits / words.length >= 0.8;
}

/// Strips markdown so the voice model does not read symbols aloud.
String plainForVoice(String text) {
  var s = text;
  s = s.replaceAll(RegExp(r'```[\s\S]*?```'), ' (code omitted) ');
  s = s.replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => m[1]!);
  s = s.replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (m) => m[1]!);
  s = s.replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '');
  s = s.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m[1]!);
  return s.trim();
}

/// The text of a `delegation.created` item.
String delegationText(Map<String, dynamic> item) {
  final content = item['content'];
  if (content is! List) return '';
  return content
      .whereType<Map>()
      .map((c) => (c['text'] ?? '').toString())
      .join(' ')
      .trim();
}

/// A `delegation.context.append` message.
Map<String, dynamic> contextAppend(String itemId, String text) => {
  'type': 'delegation.context.append',
  'delegation_item_id': itemId,
  'content': [
    {
      'type': 'input_text',
      'text': text.length > kMaxResultChars
          ? text.substring(0, kMaxResultChars)
          : text,
    },
  ],
};

/// Instructions sent back to the voice model. Wording follows the web page.
abstract final class VoiceNotes {
  static const chat =
      'The user was just chatting, not asking for work. Reply briefly and '
      'naturally. Nothing to run.';
  static String result(String answer) =>
      'Task result. Say it once, in your own natural spoken words: headline '
      'first, then only the details that matter. The full answer is already '
      'in the chat, so do not read it all or repeat it. No greeting: the call '
      'is already under way. Result: ${plainForVoice(answer)}';
  static const emptyResult =
      'The task finished but Hermes returned no answer. Tell the user briefly '
      'and offer to retry. Do not invent a result.';
  static const failed =
      'The task failed. Tell the user once, simply, and offer to retry. Do not '
      'claim anything is still running.';
  static const busy =
      'Two tasks are already running. Tell the user you will take this one as '
      'soon as one finishes, and ask them to repeat it then.';
  static const notStarted =
      'The task could not be started. Tell the user briefly.';
}
