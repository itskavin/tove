# OpenUI (generative UI) in replies

A ```` ```openui ```` fence in an assistant reply is an OpenUI Lang program
([thesysdev/openui](https://github.com/thesysdev/openui), spec 1.0/1.1). It
renders natively while it streams, with Tove's own widgets. No WebView, no
code execution. Why our own port and not a community Flutter library:
`docs/design/openui-port.md`.

Since 18 November 2026 OpenUI is Tove's **only** rich format for new
replies: the prompt (`"ui": 2`) teaches OpenUI's official chat library and
nothing else. Older `hermes-ui`, `hermes-html` and `hermes-artifact` fences
in saved chats still render (`../interactive/`), and so do OpenUI replies
written with the first Tove names (root `Stack`, `Title`, `Facts`…).

## Files

| File | Contents |
|---|---|
| `lang/ast.dart` | AST, element tree, action steps, errors, parse result |
| `lang/syntax.dart` | Lexer, statement splitter, Pratt expression parser |
| `lang/parser.dart` | Fences/comments, materialize + schema validation, entry, `parseProgram`, `StreamParser` |
| `lang/builtins.dart` | `@Count` … `@Each`, JS value semantics (ToNumber, loose equality, locale sort) |
| `lang/evaluator.dart` | Expressions, actions, `evaluateRoot` (with a work budget) |
| `lang/rules.dart` | Input validation rules (§5.4) |
| `library.dart` | The component registry (OpenUI chat library + Tove components): parser schema, generated prompt, legacy detection |
| `library_legacy.dart` | The round-9 Tove set, for replies written with it |
| `openui_block.dart` | `OpenUiBlock`: streaming parse, local `$state`, form values, safe actions, the shared renderer base and the legacy renderer |
| `chat_renderer.dart` | The chat-library renderer (part of `openui_block.dart`) |
| `charts.dart` | Native Bar/Line/Area/HorizontalBar/Radar/Pie/Radial/SingleStackedBar/Scatter charts |
| `plain_text.dart` | Readable text for Read aloud, Share and Copy; `FollowUpBlock` items for the reply suggestions |
| `places_view.dart` | `Places`/`Place` cards, the `Map` and `LocationButton` |
| `quiz_view.dart` | The `Quiz` component |

`lang/` is a port of `@openuidev/lang-core` (MIT, Thesys Inc.); it imports
no Flutter. Not ported: Query/Mutation execution (no tools in the app),
incremental edit merge, serialization.

## Components

Names, argument order and enum values follow `openuiChatLibrary` in
`@openuidev/react-ui` 0.18.9 (the built-in library openui.com uses for chat
answers; root `Card`), so a model's OpenUI knowledge transfers:

- Content: `Card` (root), `CardHeader`, `InlineHeader`, `TextContent`,
  `MarkDownRenderer`, `Callout`, `TextCallout`, `Image`, `ImageBlock`,
  `ImageGallery`, `CodeBlock`, `Separator`.
- Tables and charts: `Table` + `Col` (column-oriented), `BarChart`,
  `LineChart`, `AreaChart`, `HorizontalBarChart`, `RadarChart`, `Series`,
  `PieChart`, `RadialChart`, `SingleStackedBarChart`, `ScatterChart`.
- Forms: `Form`, `FormControl`, `Label`, `Input`, `TextArea`, `Select`,
  `DatePicker`, `Slider`, `CheckBoxGroup`, `RadioGroup`, `SwitchGroup`,
  `Chips`, `OptionCards` and their items.
- Buttons and lists: `Button`, `Buttons`, `Icon` (lucide names mapped to
  Material icons), `IconButton`, `ListBlock`, `ListItem`, `FollowUpBlock`.
- Layout: `SectionBlock`, `Tabs`, `Accordion`, `Steps`, `Carousel`.
- Data and cards: `TagBlock`, `Tag`, `EntityList`, the five card blocks
  (`Snippet`, `Overview`, `Context`, `Composite`, `Visual`) and their
  building blocks (`Text`, `BoldText`, `IconText`, `ImageText`,
  `ImageTextLarge`, `MetricIndicator*`).

Tove custom components, where OpenUI has no equivalent (group "Tove" in the
prompt): `Email(to, subject, body, cc?)` (the email card with Copy and the
Send menu), `Artifact(title, content, kind?, language?, file?)`,
`Checklist(sections, title?)` + `ChecklistSection(title, items, time?, icon?)`
(ticks saved and synced), `Entities` + `Entity(name, subtitle?, image?,
about?)` (Wikipedia picture, tap = details sheet), `News` + `Article`, and
the status family `Status`, `Services` + `Service` (tap sends `ask`),
`Gauges` + `Gauge`; `Places` + `Place(id, name, subtitle?, facts?, rating?, ratingSource?, phone?, url?)`
(cards with Call, Directions and Website; details by the `place:` id from the bridge's open places service;
a rating shows only with its source) and `Map(items, zoom?)` + `Pin(label, lat, lng)` (flutter_map with the
bridge's tile URL and attribution, numbered pins, selection shared with the cards; `places_view.dart`);
`Quiz(title, questions, source?, note?)` + `Question(text, options, answer?, explain?)` (one question at a
time with progress and Back, answers kept like checklist ticks, one message at the end; `quiz_view.dart`);
`LocationButton(label?)` (turns on the approximate-location setting and asks again). Their variants use OpenUI's
`"neutral"|"info"|"success"|"warning"|"danger"`.

Not supported: `EditableTable` (no save path). Tolerated, not taught: the
base library's `Stack`.

Behaviour differences from react-ui, on purpose:

- The root `Card` draws no box (the blend rule: a reply is not a card).
- `FollowUpBlock` is not drawn inline; its items become the reply's
  suggestions under the action row (`extractSuggestions`).
- A Button inside a `Form` sends one **visible** message: its
  `@ToAssistant` text (or label), then "Field: value" pairs. Required fields
  are checked first.
- Card-block actions send the action's text plus the tapped item's title.
- `Callout`'s auto-dismiss (`visible`) is honoured only when false; chat
  content does not disappear by itself.

## Safety

- Actions map only to: `@ToAssistant(text)` → a **visible** user message
  (cleaned, ≤ 300 chars, once per block, disabled once answered);
  `@OpenUrl` → the confirm sheet (http/https/mailto only); `@Copy`;
  `@Set` / `@Reset` → this block's local state. `@Run`, `Query`, `Mutation`
  do nothing.
- Pictures load through the bridge (`UiRemoteImage`, markdown images);
  `entity:Title` references resolve through the bridge's entity info.
- Limits: 24 000 source chars, 400 rendered elements, 50 000 evaluation
  steps, 200 `@Each` items, expression depth 64. A component whose build
  throws renders nothing; the rest stays.
- Recovery follows the spec: the smallest broken unit is dropped. Unknown
  components show their string arguments as text. A program that yields
  nothing shows the collapsed "couldn't be shown" section.

## Prompt

`toveOpenUiPrompt()` generates the bridge's OpenUI section for `"ui": 2`
clients from `toveComponents` (rarer components and trailing props stay
untaught to save tokens; see `_untaught` and `_untaughtProps`). After
changing the registry:

    dart run tool/openui_prompt.dart > ../server/openui-chat-prompt.md

then install it on the bridge (beside the script and in the data dir;
hot-reloaded) together with `server/markdown-prompt.md`.
`test/openui/openui_widget_test.dart` fails on drift, and the bridge test
`test_openui_chat.py` checks that the bridge knows every untaught name.
`server/hermes-ui-prompt.md` + `server/openui-prompt.md` are the frozen
round-9 prompt for `"ui": 1` apps.

## Tests

- `test/openui/conformance_test.dart`: the spec's 1.0 fixtures (vendored,
  MIT) — 54 runnable cases pass; 5 editing cases skipped.
- `test/openui/streaming_test.dart`: char-by-char streaming equals a batch
  parse; fuzzed input never throws; deep nesting and sharing stay bounded.
- `test/openui/openui_widget_test.dart`: the round-9 set — rendering,
  streaming, actions, bindings, fallbacks, 200 % text, goldens (4 UIs ×
  dark/light).
- `test/openui/chat_library_test.dart`: the chat library — signatures,
  forms, card actions, follow-ups, Read aloud text, legacy detection, and
  goldens of eight real replies (dark/light, `fixtures/replies/`).
