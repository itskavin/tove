import 'models.dart';

/// The first message of a chat forked at a reply (round 6 B3). The bridge
/// has no fork route yet (bridge-requests.md R6.1), so the conversation up
/// to the reply travels as context in that message. Oldest turns are dropped
/// first to fit [limit] characters; `hermes-ui` and `hermes-html` blocks are
/// left out (the model wrote them, and they are bulky JSON).
String forkSeed(
  List<ChatMessage> messages, {
  String? title,
  required int limit,
}) {
  final head = title == null || title.trim().isEmpty
      ? 'Continuing from an earlier chat. The conversation so far:'
      : 'Continuing from an earlier chat (“${title.trim()}”). '
            'The conversation so far:';
  const tail =
      'Carry on from here: reply with one short line and wait for my next '
      'message.';
  final turns = <String>[
    for (final m in messages)
      if (m.text.trim().isNotEmpty && (m.isUser || m.isAssistant))
        '${m.isUser ? 'Me' : 'You'}: ${_withoutBlocks(m.text).trim()}',
  ];
  final budget = limit - head.length - tail.length - 8;
  final kept = <String>[];
  var used = 0;
  for (final turn in turns.reversed) {
    final room = budget - used;
    if (room <= 40) break;
    if (turn.length + 2 <= room) {
      kept.insert(0, turn);
      used += turn.length + 2;
    } else {
      // The newest turn that does not fit keeps its end.
      kept.insert(0, '…${turn.substring(turn.length - room + 3)}');
      break;
    }
  }
  return [head, ...kept, tail].join('\n\n');
}

final _block = RegExp(
  r'^ {0,3}(`{3,}|~{3,})\s*hermes-(?:ui|html)\b[\s\S]*?^ {0,3}\1\s*$',
  multiLine: true,
);

String _withoutBlocks(String md) =>
    md.replaceAll(_block, '').replaceAll(RegExp(r'\n{3,}'), '\n\n');
