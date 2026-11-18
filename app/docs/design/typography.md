# Reply typography per platform (round 3)

Status: implemented 16 November 2026 (`lib/src/ui/theme/tokens.dart`, `HermesTypeface`). Supersedes the
single-font decision in `chat-rendering-v2.md` §1.2 for desktop and web; phones are unchanged.

## Measurements

| Reference | Font | Body | Bold |
|---|---|---|---|
| Web app on the user's Windows PC (devtools "Fonts" panel) | "Segoe UI" from the page's system stack `ui-sans-serif, -apple-system, system-ui, "Segoe UI", Helvetica, …` | 16 px / 26 px, 400, normal spacing | "Segoe UI Semibold" (600) |
| Android app on the QA phone (chat-rendering-v2 §0.2) | Roboto-class | 17 sp / 26 | ≈ 700 (stem width) |

## Decision

| Platform | Family | Body | Bold (`**…**`, H4–H6, table header) | Headings (H2/H3) | Why |
|---|---|---|---|---|---|
| Android | bundled **Roboto Flex** (`HermesSans`, variable) | 17/26 | 700 | 650 | Closest measured width to the reference phone app (+1.6 % vs static Roboto +2.1 %); has `opsz` and exact 650 headings |
| iOS | system **SF Pro** (`CupertinoSystemText`) | 17/26 | 600 | 600 | The reference iOS app uses the platform font; nothing to bundle. Not yet checked on a device |
| Web | bundled **Roboto Flex** | **16/26** | **600** | 600 | CanvasKit and skwasm only draw fonts the app supplies (see below), so the browser's system-ui stack cannot be used; metrics and weights match the reference |
| Windows | system **Segoe UI** (+ Segoe UI Emoji/Symbol, then Roboto Flex) | **16/26** | **600** (Segoe UI Semibold) | 600 | Exactly the reference |
| macOS | system **San Francisco** (`.AppleSystemUIFont`) | 16/26 | 600 | 600 | What `-apple-system` resolves to in the reference stack |
| Linux | fontconfig **`sans-serif`** (then Ubuntu, Adwaita Sans, Cantarell, DejaVu Sans, Roboto Flex) | 16/26 | 600 | 600 | What `system-ui` resolves to on Linux desktops |

Every other style (captions, tables, chips, headings, stat values) keeps its phone value × 16/17 on desktop and web,
rounded to 0.5 sp, line heights rounded to whole dp. System fonts get tracking 0 ("normal"); the variable font keeps
the tuned tracking. 700 display weights become the platform's bold weight (600) on desktop and web.

## Why not system fonts on Flutter web

Flutter web's CanvasKit and skwasm renderers shape and draw text with Skia inside WebAssembly. Skia can only use
font bytes that were loaded into it (the app's assets and the engine's fallback fonts); it cannot reach the
operating system's installed fonts by name, so `system-ui` or "Segoe UI" in a `TextStyle` silently falls back.
The HTML renderer that used the browser's own text stack was removed in Flutter 3.29. The engine shipped with
Flutter 3.50 contains an experimental `WebParagraph` path (`preferWebParagraph`, built on Chrome's Canvas text
clusters API), which would draw with browser fonts, but it is marked experimental and only works where that API
exists, so it is not used. Loading the user's Segoe UI through the Local Font Access API would need a permission
prompt and would still ship Microsoft's font into the Skia heap; it is not done.

## Licences

- Roboto Flex: SIL Open Font License 1.1 (`assets/fonts/RobotoFlex_LICENSE.txt`), bundled.
- JetBrains Mono: SIL OFL 1.1, bundled (code).
- Roboto: Apache 2.0, bundled (fallback).
- Segoe UI (Microsoft), San Francisco (Apple), and the Linux desktop fonts are proprietary or system-supplied and
  are **not bundled**: the app names them and the operating system provides them at run time.

## Tests

`test/interactive/round3_test.dart` ("typography per platform") checks the mapping and the 16/26 and 600 values;
`test/theme/typography_test.dart` keeps the phone values. Goldens in `test/interactive/goldens/r3_*_desktop.png`
use the web typeface (Roboto Flex 16/26), the one desktop-width face the test host can render.
