# OpenUI in Tove: library choice and port

Date: 2026-11-18. Follows `openui-evaluation.md` (research). The user asked
for OpenUI natively, fast. This records which Dart implementation we use and
why.

## Candidates (checked 2026-11-18, Flutter 3.50.0)

| | titanseason/openui-flutter (`openui_lang`) | mtwichel/openui_flutter | Our port (`lib/src/ui/openui/lang`) |
|---|---|---|---|
| Licence | Apache-2.0 (GPL-3.0 compatible, one way) | MIT (Very Good Ventures) | MIT-derived port of `@openuidev/lang-core`, notice kept |
| Maturity | 73 commits, 0.18.2 on pub.dev, last commit 2026-11-05 | 63 commits, 0.0.1-dev.2, last commit 2026-05-26 | New |
| Lang version | Claims 1.1 | Pre-1.0 dialect: `@Query(...)` builtin replaces the spec's `Query(...)` statement | 1.0/1.1, ported from the reference TS |
| Official spec fixtures (level 1) | 17/53 under a quick adapter. Several failures are adapter-shape noise (action/binding summary), but real grammar failures remain: operator precedence and object keys, `-` lexing, `m.0` member digits, multi-line strings with `//`, multi-line ternary root (all `parse-failed`, nothing renders); no `no-root` reporting; no enum checks; numeric-string sort wrong | Not run (dialect differs from the spec) | **54/54 runnable cases pass** (5 editing cases skipped: edit merge not ported) |
| Streaming | Line-based: complete lines parsed, last line auto-closed | Yes (`StreamParser`) | Spec §4 statement-completion scanner with implicit closing; char-by-char streaming equals batch parse for every fixture (test) |
| Components | 82 (react-ui GenUI library) | ~14 | Tove library, built on our existing widgets |
| Builds on Flutter 3.50 | Yes; 352 own tests pass; 36 analyzer infos (deprecations) | Core: yes, 536 own tests pass | Yes |
| Security | No WebView, no code execution. `Image.network` direct (bypasses `/api/image`) | No WebView. `OpenUrl` → `url_launcher` directly (no confirm sheet); `Image.network` | No WebView, nothing executes; actions map to send / confirm-sheet link / copy / local state only; pictures through the bridge |
| Theming | Own `OpenUIThemeData` (separate from Material theme); hard-coded `Colors.grey.shade200` and Chinese fallback strings ("图片加载失败") | Own tokens file | Our `MarkdownStyle` tokens and the blend rule |
| Extra deps | `flutter_markdown_plus` (a second markdown renderer) | `fl_chart`, `url_launcher`, `dart_mappable`, `json_schema_builder` | None |

## Decision

Keep our own port of the language core and render with Tove's existing
widgets. Neither library is first-party (openui.com lists both as
"Community"), neither passes the spec grammar, and adopting either would
bring a second design system, a second markdown renderer and direct network
images that bypass the bridge. From titanseason we take only the vocabulary
idea: our component names follow the react-ui GenUI library where they
overlap, so models see familiar names.

## What openui.com/docs/integrations recommends

Read from `thesysdev/openui` `docs/content/docs/integrations` and
`docs/lib/examples-catalog.ts` (the page renders that catalogue).

- No official Flutter or Dart integration. Non-React clients are community
  ports of lang-core (SwiftUI, Rust, HarmonyOS, two Flutter ones). The
  official route for a native client is the one we took: port the parser,
  streaming parser, evaluator and prompt generator, and draw native widgets.
- Prompt: generate it from the component library (`generateSystemPrompt`,
  or `openui generate` for a static prompt). The flags that match Tove are
  `inlineMode` (text plus fenced code, so simple answers stay prose) and
  `bindings` (`$variables`, `@Set`, `@Reset`); `toolCalls` (Query/Mutation)
  stays off because the app runs no tools.
- Models: any OpenAI-compatible Chat Completions endpoint, streamed.
- Validation/repair: the docs recommend Gateway or the Autofix API. Both
  need a Thesys key and send the conversation to Thesys, so we do not use
  them. We follow the spec's own recovery instead (drop the smallest unit,
  render the rest) on the client, and the bridge checks the finished reply
  and logs errors (see the bridge section of `hermes-ui-prompt.md`).

## OpenUI as the only format (18 Nov 2026, round 10)

The user asked to use OpenUI's components for everything instead of our own
hermes-ui blocks. Checked first with an A/B through a scratch bridge (the
repo script on another port, fresh data dir, real Hermes on gpt-6.1-terra,
default effort): the same 8 prompts with `"ui": 1` (round-9 prompt:
hermes-ui + hermes-html + artifacts + Tove-named OpenUI) and `"ui": 2`
(markdown rules + the official chat library only). Evidence:
`~/.local/state/hermes-live-qa/openui-only-20261118/` (ab.py, ab.jsonl,
summary.json, validity.json, renders/).

| Prompt | v1 format | v2 format | Valid v1 / v2 | First component after first delta, v1 / v2 | Output tokens v1 / v2 |
|---|---|---|---|---|---|
| Phone comparison | openui (Grid, ProsCons, Table) | openui Entities + markdown table | ✓ / ✓ | 1.4 / 1.4 s | 928 / 782 |
| Jaipur trip | openui Tabs + Steps | openui Tabs + Steps | ✓ / ✓ | 1.8 / 1.6 s | 1266 / 1475 |
| Recipe | openui Facts, List, Steps | openui EntityList, Steps, Callout | ✓ / ✓ | 1.4 / 1.3 s | 442 / 538 |
| Homelab health | openui Status, Services, Gauges, Alerts | openui Status, Services, Gauges, Callouts | ✓ / ✓ | 1.2 / 1.0 s | 658 / 728 |
| A person | markdown + picture | markdown + picture | – | – | 119 / 125 |
| Cars with pictures | openui Grid of Cards + Facts | openui CompositeCardBlock | ✓ / ✓ | 1.4 / 1.5 s | 1273 / 805 |
| Plan my day | hermes-ui checklist | openui Checklist | ✓ / ✓ | 5.0 / 1.2 s | 534 / 393 |
| Email draft | hermes-artifact | openui Email | ✓ / ✓ | 0.7 / 1.0 s | 76 / 64 |

Prompt size: 17,005 → 14,553 characters; a request without tool rounds
measured 18,324 → 17,437 prompt tokens (−887 per model call). Wall times
are dominated by Hermes' web-search rounds and vary run to run.

Verdict: not worse; adopted. All 14 rich replies parsed with zero errors
in both variants. v2 is at least as rich everywhere except the phone
comparison, where the model chose Entities plus a markdown table instead of
v1's card grid with pros and cons. The checklist arrives about 4 s earlier
because OpenUI streams while a hermes-ui block waits for its closing fence.

What changed: the registry follows `openuiChatLibrary` (names, argument
order, enum values); Tove-only components are documented OpenUI custom
components; installed apps (`"ui": 1`) keep the round-9 prompt until they
update.
