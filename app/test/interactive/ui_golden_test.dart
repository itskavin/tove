import 'package:flutter_test/flutter_test.dart';
import 'package:tove_chat/src/ui/interactive/interactive.dart';
import 'package:tove_chat/src/ui/markdown/hermes_markdown.dart';

import '../markdown/golden_harness.dart';

/// Every hermes-ui type (chat-rendering-v2 §3.5), dark and light, 100 % and
/// 200 % text. Regenerate with `flutter test --update-goldens test/interactive`.
const choices = '''What should I set up first?

```hermes-ui
{"v":1,"type":"options","id":"use-case","prompt":"What are you building?","select":"one",
 "options":[
   {"label":"Voice companion","send":"I'm building a personal voice companion."},
   {"label":"Homelab controller","send":"I want it to control my homelab and apps."},
   {"label":"Both","send":"Both: a companion that can also control my homelab."}],
 "other":true}
```

```hermes-ui
{"v":1,"type":"options","id":"checks","prompt":"Which checks should run?","select":"many",
 "options":[{"label":"Disks"},{"label":"Backups"},{"label":"Certificates"}]}
```

```hermes-ui
{"v":1,"type":"actions","items":[
  {"label":"Run the disk check","style":"primary","action":{"send":"Run the disk check now."}},
  {"label":"Open the pricing page","action":{"link":"https://example.com/pricing"}},
  {"label":"Copy command","action":{"copy":"df -h /mnt/storage"}}]}
```''';

const data = '''## Cost comparison

```hermes-ui
{"v":1,"type":"calc","id":"cost",
 "inputs":[{"id":"minutes","kind":"slider","label":"Session length","min":10,"max":600,"step":10,"value":190,"format":"{} minutes"},
           {"id":"tools","kind":"toggle","label":"Include tools","value":true},
           {"id":"tier","kind":"segmented","label":"Model","value":1,"options":[{"label":"Mini","value":0.4},{"label":"Full","value":1}]},
           {"id":"days","kind":"stepper","label":"Days a week","min":1,"max":7,"value":5}],
 "outputs":[
   {"label":"Base session cost","expr":"minutes * 0.05 * tier","format":"currency:USD","sub":"Excludes backend and tools"},
   {"label":"Weekly (est.)","expr":"minutes * 0.05 * tier * days * (tools ? 1.4 : 1)","format":"currency:USD"}]}
```

```hermes-ui
{"v":1,"type":"cards","items":[
  {"label":"Disk used on NAS-01","value":"71 %","sub":"Up 3 % this week","tone":"warn"},
  {"label":"Backups","value":"OK","sub":"Last run 03:12","tone":"good"},
  {"label":"Failed units","value":"2","tone":"bad"}]}
```''';

const text = '''```hermes-ui
{"v":1,"type":"callout","tone":"warning","title":"Backups paused","body":"NAS-01's nightly job is disabled until **Sunday**."}
```

```hermes-ui
{"v":1,"type":"callout","tone":"tip","body":"Run the check after the update for a clean baseline."}
```

```hermes-ui
{"v":1,"type":"details","title":"Full benchmark method","open":true,"body":"Each model ran **20 prompts**:\\n\\n- 10 short\\n- 10 long"}
```

```hermes-ui
{"v":1,"type":"details","title":"Raw numbers","body":"Hidden until opened."}
```

```hermes-ui
{"v":1,"type":"group","title":"Workbench","children":[
  {"type":"callout","tone":"success","title":"Ethernet is up","body":"Wi-Fi stays as the fallback."},
  {"type":"cards","items":[{"label":"Link speed","value":"1 Gb/s"},{"label":"Latency","value":"0.4 ms"}]}]}
```

<details>
<summary>HTML details</summary>

Body text from an HTML block.
</details>

```hermes-ui
{"v":1,"type":"suggestions","items":["Not shown in place"]}
```''';

const broken = '''This block is invalid:

```hermes-ui
{"v":1,"type":"options","options":[}
```

And this one is from the future:

```hermes-ui
{"v":2,"type":"hologram"}
```''';

void main() {
  goldenMatrix(
    'ui_choices',
    () => HermesUiScope(
      onSend: (_) {},
      child: const HermesMarkdown(text: choices),
    ),
    // Select one chip of the "many" block so the selected style shows.
    before: (tester) async {
      await tester.tap(find.text('Backups'));
      await tester.pump(const Duration(milliseconds: 200));
    },
  );
  goldenMatrix('ui_data', () => const HermesMarkdown(text: data));
  goldenMatrix('ui_text', () => const HermesMarkdown(text: text));
  goldenMatrix('ui_fallback', () => const HermesMarkdown(text: broken));
  goldenMatrix(
    'ui_answered',
    () => HermesUiScope(
      onSend: (_) {},
      nextUserMessage: 'Both: a companion that can also control my homelab.',
      child: HermesMarkdown(
        text: choices.split('```hermes-ui').take(2).join('```hermes-ui'),
      ),
    ),
  );
  goldenMatrix(
    'ui_streaming',
    () => const StreamingMarkdown(
      text: 'Let me build a calculator.\n\n```hermes-ui\n{"v":1,"type":"calc","inputs":[{"id":"m"',
      smoothReveal: false,
    ),
  );
  goldenMatrix(
    'ui_suggestions',
    () => HermesSuggestions(
      items: const [
        'Compare monthly cost at 2 h a day',
        'Which one supports tool calls?',
      ],
      onSend: (_) {},
    ),
  );
}
