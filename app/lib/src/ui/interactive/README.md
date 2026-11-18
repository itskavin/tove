# hermes-ui interactive blocks

Native widgets for the `hermes-ui` fenced blocks in assistant replies
(`docs/design/chat-rendering-v2.md` §3). Import the barrel:

```dart
import 'package:tove_chat/src/ui/interactive/interactive.dart';
```

Nothing here loads HTML, CSS, JavaScript or a WebView. A block is one JSON
object, validated against a fixed schema, drawn with theme widgets only. The
only remote content is the pictures of `entities` and `news` (round 3): they
load through the bridge like markdown images (`MarkdownImageScope`), never
directly, and only http(s) URLs pass the parser.

## How blocks reach the screen

The markdown renderer (`HermesMarkdown`, `StreamingMarkdown`) already draws
every ```` ```hermes-ui ```` fence in place with `HermesUiBlock`:

- while the JSON is still arriving: a 56 dp "Preparing…" placeholder
  (never raw JSON); a half-typed info string (```` ```herm ````) already
  shows it;
- valid JSON: the native element, cross-faded in;
- invalid JSON, unknown type, a broken limit, `v > 1`, a 7th block in one
  message, or a block nested in a `details` body: a collapsed
  "Interactive content couldn't be shown" section with the raw text.

So the thread and live mode get blocks for free. What the app must add:

1. **A `HermesUiScope` above each assistant message**, to wire actions.
2. **The follow-up suggestions** under the latest reply (they are lifted out
   of the message, not drawn in place).

## Callbacks to wire: `HermesUiScope`

```dart
HermesUiScope(
  onSend: (text) => controller.sendUserMessage(text), // visible user message
  onOpenLink: (url) => confirmAndOpen(context, url),  // default if omitted
  onCopy: (text) { Clipboard.setData(ClipboardData(text: text)); toast('Copied'); },
  onFocusComposer: composerFocusNode.requestFocus,    // the "Other…" chip
  onSelectionHaptic: () => feedback.haptic(Haptic.selection), // slider steps
  nextUserMessage: nextUserTextOrNull,                // locks answered blocks
  enabled: !isStreaming && isOnline,                  // send controls on/off
  child: MessageMarkdown(...),
)
```

| Field | Required | Meaning |
|---|---|---|
| `onSend(String)` | yes, for options and `send` buttons | Post the text as a **visible** user message. Without it, send controls render disabled. |
| `onOpenLink(String)` | no | Open a safe http/https/mailto URL **after confirming**. Defaults to `confirmAndOpen` (the host confirm sheet). Unsafe URLs never reach it. |
| `onCopy(String)` | no | Copy and tell the user. Defaults to the clipboard only; the button shows a check for 1.5 s either way. |
| `onFocusComposer()` | no | The "Other…" option chip. Without it the chip is disabled. |
| `onSelectionHaptic()` | no | Slider/stepper step haptic (≤ 1 per 40 ms), so the app's haptics setting applies. Defaults to `HapticFeedback.selectionClick`. |
| `nextUserMessage` | no | The text of the first user message after this reply, or null for the latest reply. Options and `send` buttons lock once it is set and keep the matching answer selected (others drop to 40 %). |
| `enabled` | no (true) | False disables every `send` control. |

Local state (slider positions, chosen chips, open sections) lives in the
widgets and resets when the message is rebuilt from history, as the spec
allows.

## Suggestions

```dart
// Under the action row of the latest finished reply only:
final extras = HermesReplyExtras.maybe(
  message.text,
  streaming: message.streaming,
  onSend: controller.sendUserMessage,
);
if (extras != null) extras,
```

`HermesReplyExtras.maybe` returns null while streaming, without `onSend`, or
when the reply has no `suggestions` block. Hide it once the user sends
anything. Lower level: `extractSuggestions(markdown)` and
`HermesSuggestions(items:, onSend:)`.

### Live mode: `LivePanel.blockBuilder`

Live mode renders answers with the markdown module, so its blocks already
appear in place. Its `blockBuilder` hook should add only the suggestions:

```dart
LivePanel(
  blockBuilder: (context, content) => HermesReplyExtras.maybe(
    content.text,
    streaming: content.streaming,
    onSend: sendFromLive,
  ),
  ...
)
```

Put a `HermesUiScope` (with the same `onSend`) above the `LivePanel` so
options and buttons inside the answer work too.

## Entities and news (round 3)

- `entities` render as a row of square picture cards (two share the width,
  three or more scroll sideways) with the name in bold underline and the
  sub-line muted. Tapping a card opens `showEntitySheet`: picture, sub-line,
  `about` (its citations resolve from the reply's footnotes through
  `UiCitations`), key facts, highlights, links, sources, and **Follow up**,
  which sends `ask` (default "Tell me more about <name>") as a visible
  message.
- `HermesUiScope.onEntityDetails` (optional) fetches more for the sheet
  (bridge `POST /api/entity`, bridge-requests.md R3.4); the sheet shows the
  embedded data at once and merges the answer when it arrives.
- `news` renders rows: rounded thumbnail (`0.26 × width`, 72–104 dp), the
  headline as a dotted-underline link with ↗, and "Publisher · date". The
  headline opens the link confirm, the thumbnail the image viewer.

## Checklists (round 4)

`checklist` renders a progress header ("3/9 Tasks completed", a bar, a
target icon that turns into a check when all are done) and numbered
sections (icon, title, time range, round checkboxes). Ticks animate (the
disc pops, the check draws itself), update the header, and persist per
message: put a `ChecklistScope` (a `ChecklistStore`) above the thread and
give each message's `HermesUiScope` a `stateKey` (its id). The store saves
on the device and, when the bridge has `settings_sync`, under the synced
key `tove.checklists` (newest 40 lists). Without a store or key, ticks
live in the widget. While streaming, the block shows a checklist-shaped
skeleton.

## Dashboard blocks (round 4)

`status`, `metrics`, `gauges`, `services`, `alerts` and `chart`
(`ui_dashboard.dart`) look like part of the reply: no fills or boxes, the
reply's text styles, hairline dividers, colour only for state (dots,
deltas, rings, lines). Service rows and alert buttons only send a visible
follow-up message through `HermesUiScope.onSend`; they are disabled while
sending is off. The chart is a small `CustomPainter` (line with a soft
fill, or grouped bars; three gridlines; first, middle and last labels),
no chart package.

## Safe HTML (round 4)

A ```` ```hermes-html ```` fence (or `{"type":"html","html":…}`) is drawn by
`HermesHtml` (`html_view.dart`), never a WebView. `package:html` (MIT)
parses it; `sanitizeHtml` keeps only allowed tags, `href` (http/https/
mailto), `src` (http/https), `alt`, `open` and a small CSS subset, drops
`script`/`style`/`iframe`/forms/`svg` with their content, unwraps unknown
tags, and limits size (32 KB), nodes (600), depth (16) and images (8).
Layout containers become native rows, columns and grids; all text content
becomes markdown for the reply's own renderer, so it looks exactly like
markdown (images through the bridge, links through the confirm sheet).
Colours and backgrounds are ignored, except tiny status dots mapped to
theme tones; `border` becomes the theme's 1 px outline. A plain ```` ```html ````
fence stays a code block.

### Components (round 7)

Chosen by `class` (unknown classes are dropped, so the content shows as plain
layout); drawn natively in `html_components.dart` with the reply's type and
the blend rule (no fills; 1 px outlines group; colour only for state).

| Markup | Drawn as |
| --- | --- |
| `div.cards` / `div.grid.cols-2\|3\|4` | Grid (2 columns by default; fewer when narrow or at large text). `cards` frames each child as a card: its first `img` as a cover (tap opens the viewer), headings as bold text, `.meta` muted |
| `div.card`, `div.hero` | One card; a hero has a wide cover picture over its content |
| `div.stats` > children with `.value`, `.label`, `.sub` | `UiCardsView` stat tiles (value falls back to the first `strong`/heading, label to `small`); tone class colours the value |
| `span.badge good\|warn\|bad\|info` | Inline outlined pill (`badge-*` inline tags, `md_render.dart`) |
| `div.bar[data-value][data-max]`, `<progress value max>` | Label + value line over a slim track (max 100 → "%") |
| `ol.timeline` / `div.timeline` | Rail with rings; `span.time` is a muted caption; tone class fills the ring |
| `ul.pros`, `ul.cons` (or divs with a heading + list) | Thumb title, check/cross per item; adjacent pros + cons share a 2-column grid |
| `div.callout info\|tip\|warn\|bad` | `UiCalloutView` (first heading is the title) |
| `div.tabs` > `section[data-tab]` | Pill row (wraps) + the selected pane, fading; label falls back to the pane's heading; ≤ 8 tabs |
| `div.gallery` > `img`s | Markdown image paragraph (side by side / strip, tap to zoom) |
| `details` > `summary` | `UiDetailsView` accordion; its body may hold components |
| `dl` > `dt`/`dd` | Spec sheet: muted term left, value right, hairlines |
| `<button data-send="…">`, `<a class="button" href>` | Pills in one wrap. `data-send` (≤ 300 chars, control/bidi characters removed) is only ever sent as the user's message; the group locks after one tap or the user's next message. Link buttons open through the confirm sheet. A button without `data-send` is dropped |

A fragment of only paragraphs, headings, emphasis, links and plain lists
(`isPlainHtml`, ignoring box styling) is drawn as one markdown view, exactly
like the reply's own markdown.

## Text for Read aloud, Share and Copy

- `hermesUiPlainText(markdown)`: replaces each block with its readable text
  (prompt, labels, values; never JSON). Invalid blocks read "Interactive
  content."; suggestions are dropped. Use for Read aloud and Share.
- Copy as markdown keeps the original fences (use the raw message text).
- `hermesUiSources(markdown)`: the bodies of all complete fences.

## Format (for the bridge prompt)

The exact system-prompt snippet is in `docs/design/hermes-ui-prompt.md`.
Envelope: ```` ```hermes-ui ```` + one object `{"v":1,"type":…}`.

| type | fields |
|---|---|
| `options` | `prompt?`, `select: "one"\|"many"`, `options: [{label, send?}]` (2–8; `send` defaults to the label), `other?: bool` |
| `actions` | `items: [{label, style?: "primary", action: {send}\|{link}\|{copy}}]` (1–3, ≤ 1 primary) |
| `cards` | `items: [{label, value, sub?, tone?}]` (1–4) |
| `calc` | `inputs: [{id, kind: slider\|stepper\|toggle\|segmented, label, min, max, step?, value, format?, options?}]` (1–6; segmented `options: [{label, value}]` 2–4), `outputs: [{label, expr, format?, sub?, tone?}]` (1–4) |
| `details` | `title`, `body` (markdown, no nested hermes-ui), `open?` |
| `callout` | `tone: info\|tip\|warning\|danger\|success`, `title?`, `body` (markdown) |
| `suggestions` | `items: [string]` (1–3, ≤ 60 chars) |
| `group` | `title?`, `children: [element without "v"]` (no nested group or suggestions) |
| `entities` | `items: [{name, sub?, image?, page?, about?, facts?: [{label, value}] (≤ 8), links?: [{label, url}] (≤ 4), highlights?: [{name, sub?, image?}] (≤ 8), ask?}]` (1–6). `about` ≤ 1200 chars of markdown and may cite the reply's `[^n]` footnotes |
| `news` | `items: [{title, url, source?, date?, image?}]` (1–8) |
| `checklist` (alias `plan`) | `title?` (header caption, default "Tasks completed"), `numbered?` (default true), `sections: [{title?, time?, icon?, items: [string \| {label, done?}]}]` (1–8 sections, 1–12 items each, ≤ 40 in all; labels ≤ 120) or a flat `items` (1–20). Icons: `focus work rest morning evening home health food learn code travel money social errands homelab calendar call mail idea star list` |
| `status` | `title`, `state?` (ok/up/healthy · warn/degraded · bad/down/offline · info · unknown), `summary?`, `updated?` |
| `metrics` | `items: [{label, value (number or text), unit?, delta?, tone?, trend?: [number] (≤ 48)}]` (1–6) |
| `gauges` | `items: [{label, value, max? (100), unit? (% when max is 100), sub?, tone?}]` (1–6) |
| `services` | `title?`, `items: [{name, state?, latency? (number = ms, or text), sub?, ask?}]` (1–20). A tap sends `ask` (default by state) as a visible message |
| `alerts` | `items: [{tone?, title, body?, time?, actions?: [{label, send}] (≤ 2)}]` (1–8) |
| `chart` | `kind?: line\|bar`, `title?`, `unit?`, `labels?: [string]` (≤ 60), `series: [{name?, values: [number] (1–60), tone?}]` (1–3) |
| `html` | `html` (≤ 12 000 chars), drawn like a `hermes-html` fence (below) |

`id` (optional, `[a-z0-9-]{1,32}`) keys local state. `tone` for cards and
outputs: `neutral`, `good`, `warn`, `bad` (aliases `success`, `warning`,
`danger`). Formats: `"{} unit"`, `number:N`, `percent:N` (a fraction:
0.25 → 25%), `currency:XXX`, `duration:min`.

**Expressions** (`calc` outputs, `Expr`): numbers, input ids, `+ - * / %`,
comparisons (`< <= > >= == !=`), `&&`, `||`, `c ? a : b` (booleans are 1/0), and `min`,
`max`, `round(x, digits)`, `floor`, `ceil`, `abs`, `clamp(x, lo, hi)`.
≤ 200 characters, nesting ≤ 24. Division by zero shows "—".

**Limits** (`UiLimits`): 16 KB per block, 6 blocks per message, 24
elements per block, depth 2, strings 300, labels 60.

## Inline HTML subset

`<small>`, `<kbd>`, `<mark>`, `<sub>`, `<sup>`, `<u>`, `<br>` and block
`<details><summary>…</summary>…</details>` render natively (attributes
ignored, except `open` on `<details>`). Every other tag, and any unclosed
allowed tag, stays visible as literal text. Implemented in
`html_subset.dart` and applied by the markdown parser.

## Files

| File | Contents |
|---|---|
| `interactive.dart` | Public barrel |
| `ui_model.dart` | Schema, limits, `parseHermesUi` (memoised, never throws) |
| `expr.dart` | Expression parser and evaluator |
| `format.dart` | Value formats |
| `html_subset.dart` | Inline HTML subset, `<details>` parsing, streaming repair |
| `scope.dart` | `HermesUiScope`, `NoNestedUiBlocks` |
| `ui_block.dart` | `HermesUiBlock`, placeholder, fallback |
| `ui_widgets.dart` | Element widgets, `UiDetailsView` |
| `ui_entities.dart` | Entity cards, news rows, entity details sheet, `UiRemoteImage` |
| `ui_slider.dart` | The 4 dp track / 20 dp thumb slider |
| `ui_dashboard.dart` | Status, metrics, gauges, services, alerts, chart |
| `html_view.dart` | HTML sanitiser, markdown conversion, `HermesHtml` |
| `ui_checklist.dart` | Checklist block, `CheckCircle`, its skeleton |
| `checklist_store.dart` | `ChecklistStore`, `ChecklistScope`, `UiBlockOrdinal` |
| `suggestions.dart` | Suggestions, `HermesReplyExtras`, plain-text helpers |

Tests: `test/interactive/` (parser, expressions, formats, HTML subset,
widgets, goldens in `test/interactive/goldens/`).
