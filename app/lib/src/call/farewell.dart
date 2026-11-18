/// Ending a live call by saying goodbye (round 8).
///
/// The whole of the user's final turn must be a farewell: "bye", "okay bye
/// Tove", "thanks, that's all, goodbye", "talk to you later", "good night".
/// A farewell word inside a request ("how do I say bye in French", "say
/// goodbye to the old server", "bye-bye birdie lyrics") never counts, nor
/// does a long turn. Works the same on both voice backends: it reads the
/// transcript the app already receives.
library;

/// Leading fillers that may come before the farewell itself.
const _lead =
    r"(?:(?:ok(?:ay)?|alright|all right|right|cool|great|perfect|awesome|"
    r"nice|good|fine|yeah|yep|yes|no|nope|well|so|and|then|"
    r"thanks?(?: (?:a lot|so much|again))?|thank you(?: (?:so much|again))?|"
    r"cheers|that'?s (?:all|it|everything)(?: for (?:now|today|tonight))?|"
    r"(?:i'?m|we'?re) (?:done|good|all set)(?: for (?:now|today|tonight))?|"
    r"nothing else|that will be all|that'?ll be all|"
    r"(?:i'?ve )?got (?:it|to go)|(?:i )?(?:have|need) to go|gotta go)"
    r"[\s,.!-]+)*";

/// The farewell itself.
const _bye =
    r"(?:bye(?:[\s-]?bye)?|good[\s-]?bye|goodnight|good night|night night|"
    r"see (?:you|ya)(?: (?:later|soon|tomorrow|around))?|"
    r"talk (?:to you )?(?:later|soon|tomorrow)|catch you later|later|"
    r"take care|ciao|farewell|"
    r"(?:you can )?(?:end|stop|hang up)(?: the| this)? (?:call|conversation|chat)|"
    r"hang up|that'?s all(?: for (?:now|today|tonight))?|i'?m done)";

/// What may follow it: a name, "then", "for now", "thanks", another bye.
const _tail =
    r"(?:[\s,.!-]+(?:tove|hermes|then|for now|for today|for tonight|now|"
    r"thanks|thank you|again|buddy|mate|bye|goodbye|take care|"
    r"have a (?:good|nice|great) (?:one|day|night|evening)))*";

final _farewell = RegExp(
  '^$_lead$_bye$_tail[\\s,.!?-]*\$',
  caseSensitive: false,
);

/// Whether [text], the user's whole final turn, ends the conversation.
bool isFarewell(String text) {
  final t = text
      .toLowerCase()
      .replaceAll(RegExp(r"[’‘]"), "'")
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty || t.length > 80) return false;
  // "That's all" alone is a farewell; "that's all I needed to know about X"
  // is not (the anchored pattern decides).
  if (t.split(' ').length > 12) return false;
  return _farewell.hasMatch(t);
}
