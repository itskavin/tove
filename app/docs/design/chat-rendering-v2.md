# Hermes chat rendering v2: design addendum

Status: design spec, 15 November 2026. This addendum to `redesign-spec.md` covers how assistant replies render
(typography, layout, interactive blocks), the sidebar swipe, the composer's extra options, and speech in and out.
Where it conflicts with `redesign-spec.md` §3.2, §4.3, §4.6, §5.2, §5.4, §5.5 or §5.7, this document wins.

Values marked **measured** come from the new reference recording. Values marked **derived** are not in the
recording. They are chosen to fit the measured system.

---

## 0. Reference and method

### 0.1 The recording

| Property | Value |
|---|---|
| Source | The user's private screen recording of a third-party AI chat app (text replies, dark theme). It stays outside the repo. Frames are in `~/.local/state/hermes-live-design/refs-v2/` (mode 700) |
| Duration | 33.23 s |
| Resolution | 1080 × 2412 portrait |
| Frame rate | Variable: 59.94 fps nominal, 35.1 fps average (1166 frames; static periods have no new frames) |
| Device density | **2.625** (420 dpi). The status bar, cutout and resolution match the QA phone, whose logcat reports `density 420`. 1 dp = 2.625 px |
| Extraction | Every frame at 4 fps (`f4/f_0001…0133.png`), seven 10 × 2 contact sheets (`sheet_01…07.png`), and per-frame timing over the crop of each transition |

Both apps were recorded **on the same phone with the same system font scale**. Pixel comparisons between the
reference and our QA screenshots (`~/.local/state/hermes-live-qa/ui-test-20261115T034119/`) are therefore direct:
the same px means the same sp.

**What the recording shows:** one long reply that contains paragraphs with bold runs, two section headings, a
three-column table that scrolls horizontally, a muted caption with an inline source chip, an **interactive cost
calculator** (slider, live value, two stat cards), a bulleted list with bold lead-ins, the per-message action row,
the source sheet, the message overflow menu, the read-aloud player, the system share sheet, a user bubble, and the
scroll-to-bottom button.

**What it does not show:** the sidebar or any swipe gesture, the composer's + menu, headings H1/H3/H4, ordered or
nested lists, block quotes, code, links in prose, emoji, rules, streaming text, or the thinking state. The spec
derives these and labels them **derived**.

### 0.2 How things were measured

- **Font size** comes from cap height. The reference body cap height is 32 px (12.2 dp). In a Roboto-class face the
  cap height is 0.711 em, which gives 45 px, or **17.1 sp**. The ascender-to-descender ink height (44 px) gives
  17.5 sp. Our app's Inter body (17 sp) has a cap height of 33 px on the same phone. **The sizes are the same.** The
  perceived "bigger, better" text comes from the typeface, weight, colour and spacing (§1.1), not from the size.
- **Weight** comes from stem width at mid-x-height. Reference regular text has 4.4 px stems (0.096 em) and bold text
  has 7 px stems (0.152 em). Our Inter 400 on the phone has 3.6 px stems.
- **Width** comes from rendering the reference's own line "For your own … compare them" (49 characters) in each
  candidate font at 17 sp and comparing it with the reference's 962 px (366.5 dp):

| Font at 17 sp, default instance | Line width | vs reference |
|---|---|---|
| **Reference** | 962 px | 0 |
| Roboto Flex (OFL 1.1, variable) | 977 px | +1.6 % |
| Figtree | 980 px | +1.9 % |
| Roboto (static, already bundled) | 982 px | +2.1 % |
| Public Sans | 988 px | +2.7 % |
| IBM Plex Sans | 1001 px | +4.1 % |
| Instrument Sans | 1002 px | +4.2 % |
| Geist | 1008 px | +4.8 % |
| **Inter (current)** | 1054 px | **+9.6 %** |

- **Spacing** is measured baseline to baseline, then converted into Flutter gaps using the text metrics of the
  recommended font with `TextLeadingDistribution.even` (§1.4).
- **Colours** are pixel samples. The recording is a lossless-looking screen capture, not a camera photo, so the hex
  values are reliable to about ±2.

---

## 1. Typography for replies

### 1.1 What makes the reference text look better (ranked)

1. **A narrower, Roboto-class grotesque.** At the same 17 sp, Inter sets text 9.6 % wider, so each line holds about
   five fewer characters. Wide letters look bigger and looser, and paragraphs run longer. A Roboto-class face looks
   denser and calmer at the same size.
2. **Heavier regular strokes and pure white text.** The reference is #FFFFFF with 0.096 em stems. Our text is
   #ECECEC with thin Inter strokes (3.6 px against 4.4 px). On pure black the reference therefore reads crisper and
   brighter.
3. **Bold is real bold (≈700).** Our `**bold**` is 600, which looks half-bold next to Inter 400.
4. **A narrower gutter (16 dp, not 20) and more air between blocks** (paragraph gap 16, 23 above a heading, list
   items with no extra gap but 32 dp hanging indent).
5. **Tables run to the screen edge**, with flush-left first columns and quiet hairlines. They look like part of the
   text, not like a boxed widget.

### 1.2 Font recommendation

**Roboto Flex** (Google Fonts, **SIL OFL 1.1**, variable), for both reply text and app UI, replacing Inter.

- It is the closest free match in shape and width (+1.6 % before tracking, about 0 % with the tracking in §1.3).
- It has variable axes. Use `wght` (100–1000) for the exact weights below (400 / 650 / 700), `opsz` (8–144) set to
  the font size so headings tighten and small text opens up automatically, and `wdth` (fixed at 100).
- It is the same design family as Android's system font, so Hermes sits naturally on Android while keeping its own
  orb, colours and wording. That is not trade dress: the font is generic and Android-wide.
- **Size budget:** the full font is 1.75 MB. Subset at build time with fontTools: `fonttools varLib.instancer` to pin
  `GRAD=0, XOPQ, XTRA, YOPQ, YTAS, YTDE, YTFI, YTLC, YTUC, slnt=0` to their defaults, keeping `wght`, `wdth` and
  `opsz`. Then `pyftsubset` to Latin, Latin-1 Supplement, Latin Extended-A, General Punctuation, currency, arrows
  and math operators. Expect about 350–450 kB. Removing the five static Inter files saves 2.0 MB, so the APK gets
  smaller.
- **Italic:** Roboto Flex has a `slnt` axis (0 to −10). Use `slnt −10` as the italic. It is an oblique, which suits
  this grotesque style. Ship no separate italic file.
- **Code:** keep **JetBrains Mono** (OFL), 400 and 600.
- **Fallback:** keep the bundled static Roboto (Apache 2.0) as `fontFamilyFallback`. Emoji fall back to the
  platform's colour emoji font (§1.12).
- **Alternatives:**
  - If variable fonts cause trouble on web (`FontVariation` support), use **Figtree** (OFL, +1.9 %, variable
    `wght` only). It is a little rounder and friendlier.
  - The cheapest path is the already bundled static **Roboto**, with `letterSpacing −0.2` and weights 400/500/700.
    Bold would be 700 instead of 650 for headings, and there would be no `opsz`. Use it if the APK size must not
    change at all.
- **Inter** stays a good UI face for dense settings screens, but carrying two text families costs about 2 MB for
  little gain. Drop it.

Flutter setup (`pubspec.yaml`):

```yaml
fonts:
  - family: HermesSans            # Roboto Flex, subset (OFL)
    fonts:
      - asset: assets/fonts/RobotoFlex-Hermes.ttf   # variable: wght, wdth, opsz
  - family: JetBrainsMono
    fonts: [ ... unchanged ... ]
  - family: Roboto                # fallback, unchanged
```

Add `'Roboto Flex': 'assets/fonts/RobotoFlex_LICENSE.txt'` to `kFontLicences` in `lib/src/ui/theme/fonts.dart` and
remove the Inter entry.

### 1.3 Text styles (exact Flutter values)

All sizes are in sp. `height` is the line height divided by the size. Every style sets
`leadingDistribution: TextLeadingDistribution.even` and `fontFamilyFallback: ['Roboto']`. For a variable font,
`fontWeight` must be paired with a matching `FontVariation('wght', …)` so that fallback glyphs and the engine's
weight matching agree. A helper should set both, plus `FontVariation('opsz', size)`.

```dart
TextStyle _v(double size, double line, double wght, double tracking, Color color) => TextStyle(
  fontFamily: 'HermesSans',
  fontFamilyFallback: const ['Roboto'],
  fontSize: size,
  height: line / size,
  letterSpacing: tracking,
  color: color,
  fontWeight: FontWeight.values[((wght / 100).round() - 1).clamp(0, 8)],
  fontVariations: [FontVariation('wght', wght), FontVariation('opsz', size), const FontVariation('wdth', 100)],
  leadingDistribution: TextLeadingDistribution.even,
);
```

| Token | Size / line | wght | Tracking | Colour (dark) | Basis |
|---|---|---|---|---|---|
| `body` | **17 / 26** | **400** | **−0.15** | `text` **#FFFFFF** | Measured: cap 12.2 dp, line pitch 25.9 dp, stems 0.096 em, colour 255/255/255 |
| `bodyStrong` (`**…**`) | 17 / 26 | **700** | −0.15 | `text` | Measured: stems 7 px = 0.152 em, same as Roboto Bold |
| `bodyEm` (`*…*`) | 17 / 26 | 400, `slnt −10` | −0.15 | `text` | Derived |
| `h1` | 26 / 32 | 700 | −0.4 | `text` | Derived (one step above the measured section heading) |
| `h2` | **23 / 30** | **650** | −0.3 | `text` | Measured: cap 16.4 dp ⇒ 23.0 sp. Stems 8 px at 60 px = 0.133 em ⇒ about 650 |
| `h3` | 20 / 27 | 650 | −0.2 | `text` | Derived |
| `h4`–`h6` | 17 / 26 | 700 | −0.15 | `text` | Derived: a bold paragraph line |
| `caption` (`<small>`, footnote lines) | **14 / 20** | 400 | 0 | `textMuted` **#B4B4B8** | Measured: cap 9.9 dp ⇒ 13.9 sp, pitch 20.2 dp, colour ≈ #BBBBBB |
| `table` | **14.5 / 20** | 400 | 0 | `text` | Measured: cap 10.3 dp ⇒ 14.5 sp, pitch 20.2 dp. Already our value |
| `tableHeader` | 14.5 / 20 | **700** | 0 | `text` | Measured: header stems 0.145 em |
| `widgetLabel` (hermes-ui control labels) | 17 / 24 | 700 | −0.15 | `text` | Measured: calculator label |
| `statValue` (hermes-ui cards) | **28 / 34** | 700 | −0.4 | `text` | Measured: cap 20.6 dp ⇒ 28.9 sp |
| `statLabel` / `statSub` | 14.5 / 20 | 400 | 0 | `textMuted` | Measured |
| `chip` (source and option chips) | 13 / 16 | 500 | 0 | `textMuted` / `text` | Measured: source chip text about 13 sp, #B8B8B8 |
| `code` | 14.5 / 22 | 400 | 0 | `text` | Unchanged (JetBrains Mono) |
| `inlineCode` | 15 (0.88 × body) / body line − 4 | 400 | 0 | `text` | Derived. Slightly smaller than today's 0.9 to suit the narrower body |

**Tracking check (acceptance test):** on the 2.625-density phone at font scale 1.0, the reference line "For your own
AI voice assistant, I'd compare them" in `body` must measure **366 dp ± 1 %** from the first glyph's ink to the
last. If Roboto Flex with `opsz 17` is wider, adjust `body` tracking within −0.1 to −0.3. Do not change the size.

**Light theme:** the same sizes and weights. `text` is #16161A and `textMuted` is #6B6B72 (unchanged). Light
regular text renders optically heavier, so keep wght 400 and do not reduce it.

### 1.4 Vertical rhythm (dp)

The renderer places blocks with gaps. The gaps below already include the font's half-leading, so they go straight
into `SizedBox(height: …)` between block widgets.

| Between | Gap | Measured baseline-to-baseline |
|---|---|---|
| Lines in a paragraph | — (line height 26) | 25.9 |
| Paragraph → paragraph | **16** | 41.9 (= 26 + 16) |
| Paragraph → heading | **24** | 53.0 (body descent 7.2 + gap + heading ascent to baseline 22.9). Measured gap 22.9, rounded to the 8-grid |
| Heading → paragraph, list or table | **8** | 32.8 (measured gap 6.9) |
| Paragraph ending in ":" → list | **8** | 34.3 (measured 8.4) |
| Any other block → list | 16 | Derived |
| List → paragraph | **16** | 41.9 |
| List item → list item | **0** | Pitch 25.5–25.9: no extra gap |
| Nested list → its parent's next item | 0 | Derived |
| Paragraph → table | 12 | Derived. The table's header has its own 8 dp top padding |
| Table → paragraph or caption | 16 | Measured about 16 |
| Any block → code block, quote, hermes-ui block | 16 | Derived |
| Rule | 24 above, 24 below | Derived |
| Last block → action row | see §2.4 | |

H1 uses 32 above and 12 below. H3 uses 20 above and 8 below. A heading at the very top of a reply has no gap above.

### 1.5 Lists

**Measured:**

- Bullet: a **filled circle 6 dp in diameter** (6.1 measured), colour `text` (not muted).
- The bullet's left edge is 13.7 dp from the text margin, so its centre is at **16.7 dp**.
- **Hanging indent 32 dp** (32.4 measured). Wrapped lines align with the first line's text.
- Bold lead-ins ("**Label:** text") use `bodyStrong` inline. Nothing special is needed.

**Spec:**

- Draw the bullet as a `CustomPaint` dot, not a "•" glyph, so its size and centre do not depend on the font. Centre
  it vertically on the first line's x-height: `y = baseline − 0.26 × fontSize`, which is 4.4 dp above the
  baseline at 17 sp.
- **Ordered lists** (derived): the number is right-aligned in a 24 dp box, then a 8 dp gap, so the text starts at
  the same 32 dp. Use `body` with `FontFeature.tabularFigures()`, colour `text`. Show "1." with the period, not
  "1)". From 10 items the box widens to fit the widest number + period, and every item's text moves with it.
- **Nested lists** (derived): each level adds 28 dp. Level 2 uses a 6 dp ring with a 1.5 dp stroke. Level 3 uses a
  5 dp filled square, corner radius 1. Levels below 3 repeat level 3. Nested ordered lists use "a." and then "i.".
- **Task lists:** an 18 dp rounded-4 checkbox outline (`textMuted`, 1.5 dp). Checked items fill with `text` and show
  a `bg` tick, and their text stays `text` (not struck through). The text starts at 32.
- **Loose lists** (blank lines between items): 8 dp between items, not 16.

### 1.6 Block quotes (derived)

- A 3 dp bar, `outline` colour (white at 14 %), radius 1.5, running the full height of the quote.
- The text starts 16 dp after the bar, uses `body` in `textMuted`, and keeps the same paragraph rhythm inside.
- No background, no italics. A quote that is a single line starting with "Note:", "Tip:" or "Warning:" does **not**
  become a callout. Callouts use the explicit block in §3.6.

### 1.7 Inline code and code blocks (derived; the reference shows none)

- **Inline code:** `inlineCode` style, fill `surfaceHigh` (#2A2A2D), radius 6, padding 1.5 × 5, baseline aligned.
  Line height = body line − 3, so a chip never grows a line.
- **Code block:** keep today's block (`surface` #1C1C1E, radius 16, horizontal scroll, header with the language and
  Copy). Three changes:
  1. Padding becomes 16 (header 12 top, 16 left, 8 right).
  2. The language label uses `caption` (14/20, `textMuted`), lower case as written.
  3. Copy becomes an icon-only 40 dp button with a tooltip. It shows a check for 1.5 s after copying, and its
     semantics label is "Copy code".
- The code block keeps the 16 dp gutter (it does **not** bleed like tables), because code has its own fill.

### 1.8 Tables (measured)

| Property | Value |
|---|---|
| Header | `tableHeader` (14.5/20, 700). No fill |
| Body cells | `table` (14.5/20, 400), top-aligned, wrapping |
| Cell padding | **8 top, 8 bottom** (single-line row: rule to rule 36.6 dp = 20 + 2 × 8.3). Left **0**, right **24** (gutter to the next column) |
| Column widths | Content width + 24, with each column between 112 and 300 dp. Measured: columns start at 0, 129 and 268 dp |
| Rules | 1 dp, `hairline` (white at 10 %, renders as #1A1A1A on black; measured #191919). Under the header and between rows. **No** rule above the header, no vertical rules, no outer frame |
| Horizontal extent | The scroll view **bleeds to the right screen edge**: its right margin is −16 so content is clipped by the physical edge. The rules also run to the edge. **No fade.** The clipped column at the edge is the scroll cue, as in the reference |
| Left edge | Content starts at the 16 dp text margin. Use `SingleChildScrollView(padding: EdgeInsets.only(left: 16, right: 16))` placed with a −16 margin on both sides, so scrolled content slides under the left screen edge as well |
| Header alignment | GFM `:---:` and `---:` alignments apply to the header and the cells |
| Numbers | Columns where every body cell parses as a number or currency get `tabularFigures` and right alignment (derived) |
| Long press on a cell | Copies the cell text. "Copy table" (as TSV) is in the message overflow menu (derived) |

### 1.9 Horizontal rules (derived)

A 1 dp `hairline` that spans the text column (not the bleed), with 24 above and 24 below.

### 1.10 Links (derived; only source chips appear in the reference)

- Links in prose: `text` colour, a **solid** 1 dp underline in `text` at 35 % alpha, with offset 2 (use
  `decorationThickness` 1 and draw it as a `TextDecoration.underline`). Remove the trailing ↗ glyph: the underline is
  enough, and the glyph shifts the line rhythm.
- Pressed state: the underline goes to 100 % for 100 ms.
- Tapping a link opens the existing confirm sheet with the host. Long press offers Copy link and Open.
- Bare URLs (autolinks) show the host and path shortened to 40 characters with "…" in the middle.

### 1.11 Source citations (measured)

**Reference behaviour:**

- A small stadium chip sits **inline at the end of the paragraph** it supports, after a space.
- The body variant is 24 dp tall and the caption variant 18 dp. The fill is white at about 25 % over black (#414141).
- The text uses `chip` style in about #B8B8B8. It holds a publisher name, plus "+N" when several sources back the
  same sentence.
- Tapping the chip opens a bottom sheet listing each source: title in 17/24 700, page name in `body`, publisher in
  `textMuted`, with a hairline between rows.

**Hermes version:**

- **Syntax:** GFM footnotes. Hermes writes `…respectively.[^1][^2]` and puts definitions at the end:
  `[^1]: [Pricing](https://example.com/pricing) — Example Docs`. Consecutive footnote references at the end of a
  paragraph render as **one** chip, "example.com +1". The existing "Sources:" list detection stays as a fallback.
- **Chip look:**
  - Fill `surfaceHigh` (#2A2A2D), no stroke, height 24 (18 in captions), padding 4 × 10.
  - A 14 dp **globe glyph** (no remote favicons: privacy and the CSP), then the host without `www.`, in `chip`
    style `textMuted`.
  - "+N" uses the same style at 70 % alpha.
  - The chip sits 6 dp after the last word and is baseline-aligned, so it never changes the line height.
  - This replaces today's `accentSoft` (blue-tinted) pill. The neutral fill blends in better and keeps colour for
    actions.
- **Sheet:** the standard Hermes floating sheet (`redesign-spec.md` §5.8), titled "Sources". Each row is 72 dp: a
  globe glyph, the title (`title` style), and the host + footnote text (`caption`). Tapping a row opens the link
  confirm.
- The renderer parses per block, so a footnote definition and its reference may be in different blocks. Pre-scan the
  whole message for `^\[\^[^\]]+\]:` definition lines first, pass the map into every block, and hide the
  definitions block itself. While streaming, a reference whose definition has not arrived yet renders as a pending
  chip with the label "Source" (no host).

### 1.12 Emoji (derived)

Platform colour emoji through the fallback chain, at the surrounding text's size and line height. Never use bitmap
emoji larger than the text. A message made of 1–3 emoji only renders them at 34 sp, line 40.

---

## 2. Message layout

### 2.1 Columns and widths

| Property | Value |
|---|---|
| Text gutter | **16 dp** left and right (measured 16.4 dp). Replaces `Sp.content = 20` for the thread |
| Measure | Phone: full width − 32. **Tablet and desktop: max 680 dp** of text (about 75 characters at 17 sp), centred, with tables still allowed to bleed to the column's container edge |
| User bubble | Right-aligned, **max width 78 %** of the text column (measured 296 dp of 380), `surface` fill (#1C1C1E; see trade dress §7), radius **22**, padding **16 horizontal, 11 vertical** (so a one-line bubble is 48 dp tall), `body` style. Right edge on the 16 dp gutter |
| Assistant reply | No bubble, full text-column width, left-aligned |
| Between turns | User bubble → assistant reply: 24 dp. Assistant action row → next user bubble: 20 dp |

### 2.2 Floating chrome (measured)

- **Top:** two glass buttons, 44 dp (measured 43), 12 dp from the screen edges, vertically centred 34 dp below the
  status bar. Content scrolls under them.
- **Top scrim:** content under the status bar and buttons, the top 110 dp, is dimmed by black at **70 %**, with a
  6 dp soft edge at the bottom. A full-height gradient is not used. This keeps the buttons legible without a solid
  bar. Today's top fade is close: keep it, but match the 70 % and 6 dp edge.
- **Bottom:** the composer floats over the content. The content has a bottom padding equal to the composer height +
  28 dp, so the last action row clears it. Content behind the composer is dimmed by a 48 dp black gradient from 0 %
  to 85 %.

### 2.3 Scroll-to-bottom button (measured; new)

| Property | Value |
|---|---|
| Size | 44 dp circle |
| Fill | #212121 (`surface` on dark is close enough: use `surface`), 1 dp `hairline` stroke |
| Glyph | ↓ arrow, 22 dp, `text` |
| Position | Horizontally centred, its bottom **24 dp above the composer's top** |
| Shows when | The list is more than 1 screen height from the bottom, or the user has scrolled up while a reply streams |
| Motion | Fade + scale 0.9 → 1 over 150 ms in, 120 ms out |
| Tap | Animates to the bottom: 300 ms, `standard`, or a jump when the distance is more than 3 screens |
| While streaming | It also carries a 6 dp `accent` dot at the top right when new text has arrived below the viewport |
| Semantics | "Scroll to latest" |

### 2.4 Action row under assistant messages

**Measured in the reference:**

- Four glyphs of about 18 dp at a 36 dp pitch, left-aligned with the text.
- The last text baseline to the row's centre line is **48 dp**. The row's centre to the next message's first line
  is 53 dp.
- The row appears under **every** completed assistant message, not only the last.

**Hermes spec:**

- **Glyphs** are 20 dp, `textMuted`, with **48 dp hit targets** (keep the 48 pitch). The reference's 36 dp pitch
  fails the Play accessibility scanner's 48 × 48 rule.
- **Items, in order:** **Copy**, **Read aloud** (§5.4), **Retry** (last reply only), **More** (⋯).
- **More** opens a popover (`surfaceHigh`, radius 20, 232 wide, rows 48):
  - A header line with the message time ("Today · 04:00", `caption`).
  - **Share** (Android share sheet with the plain text), **Copy as markdown**, **Copy table** (only when the
    message has a table), **Delete**.
  - The popover opens with opacity and scale 0.96 → 1 from its anchor over **120 ms** (measured 120 ms), easeOut.
- **Position:** the row's top is 8 dp below the last block. The row is 48 dp tall. 20 dp follow it before the next
  turn.
- **Motion:** it fades in over 200 ms, 150 ms after the stream ends (unchanged).
- **No timestamps** inline. Time appears only in the More popover header (the reference does the same, and it keeps
  the thread calm).

### 2.5 Streaming and thinking

- **Streaming** (unchanged from `redesign-spec.md` §5.3): per-chunk fade 240 ms, linear, at a capped reveal rate.
  The reference recording shows no visible caret. Keep **no caret**: the fading tail shows where writing happens.
- **Thinking:** unchanged (mini orb + shimmering "Thinking…").
  - Tool status lines ("Searching the web", "Running a command") replace the label.
  - When the reply's first text arrives, the label collapses (height 26 → 0, 180 ms) instead of being swapped out
    instantly.
- **Preamble lines:** Hermes often writes a short preamble ("Let me check that") before a tool call. Render it as a
  normal paragraph. The thinking indicator continues **below** it until the next text arrives.

---

## 3. Interactive blocks ("hermes-ui")

### 3.1 What the reference shows

The user's "html for interactive options" is a set of native components inside the reply. They use the same
fonts, the same black canvas and only greys plus white. Nothing in them looks like a web page:

1. **A calculator:**
   - A bold label with a right-aligned live value ("190 minutes").
   - A slider: 4 dp track, white active part, #1E1E1E inactive part, 20 dp thumb.
   - Below it, two stat cards (1 dp hairline frame, radius 12, padding 12; a muted label, a 28 sp bold value, a muted
     sub-line).
   - The values recompute as the slider moves. Measured: 60 → $3.00, 190 → $9.50, 470 → $23.50.
2. **A data table** (GFM, §1.8).
3. **Inline source chips** that open a sheet (§1.11).
4. **A caption** under the table (`caption` style).

Common chat UIs also use **option chips** (pick one or several answers), **action buttons**, **follow-up
suggestions**, **collapsible sections** and **callouts**. The user asked for interactive options, so all of these are
specified below.

### 3.2 Safety model

- Hermes emits a **fenced code block with the info string `hermes-ui`** whose body is **one JSON object**. The app
  parses it with `jsonDecode`, validates it against the schema below, and renders **native Flutter widgets**.
- **No HTML, CSS, JavaScript, WebView or remote content** is ever loaded. There are no images or iframes. Colours,
  fonts and sizes come only from the app theme. The JSON can choose a semantic `tone`, never a colour.
- **Actions are limited to three kinds:**
  - `send`: posts a **visible** user message whose text is shown on the control or in the confirmation, so no
    hidden prompts are possible.
  - `link`: goes through `safeLink` and the host confirm sheet. Only `https:`, `http:` and `mailto:` are allowed.
  - `copy`: copies a string, with a toast.
- **Expressions** (§3.4) are a tiny arithmetic language evaluated by our own parser. It has no loops, no strings and
  no function calls outside a fixed list, with a 200-character limit.
- **Limits:**
  - At most 16 KB of JSON per block and 6 blocks per message.
  - At most 24 elements per block, nesting depth 2 (a `group` holding elements).
  - Strings are capped at 300 characters, labels at 60.
  - Anything over a limit, unknown types or invalid JSON renders as a fallback (§3.9).
- **Gating:**
  - The bridge adds the format instructions to Hermes' system prompt **only** for requests from this app that
    send `"ui": 1` in `POST /api/chat`.
  - `GET /api/capabilities` reports `"ui_blocks": 1`.
  - Other clients (for example Open WebUI) never get these instructions, so they never see raw `hermes-ui` JSON.

**Restricted inline HTML subset** (for small formatting Hermes may produce anyway):

- Allowed: `<small>` (renders as `caption`), `<kbd>` (inline-code chip with a 1 dp outline instead of a fill),
  `<mark>` (`accentSoft` background, radius 3), `<sub>`, `<sup>`, `<u>`, `<br>`, and
  `<details><summary>…</summary>…</details>` (rendered as the `details` element in §3.6).
- Every attribute is ignored.
- Every other tag is shown **as literal text**, escaped. It is never stripped silently, so nothing is hidden from the
  user.

### 3.3 Envelope

````text
```hermes-ui
{"v": 1, "type": "<element type>", "id": "<optional, [a-z0-9-]{1,32}>", ...element fields}
```
````

- `v` is required. Version 1 is this document. A higher major version renders the fallback.
- `id` keys local state (slider positions, open sections, chosen options) within the message.

### 3.4 Expression language (for `calc`)

```
expr    := ternary
ternary := or ( "?" expr ":" expr )?
or      := and ( "||" and )*
and     := cmp ( "&&" cmp )*
cmp     := sum ( ("<"|"<="|">"|">="|"=="|"!=") sum )?
sum     := prod ( ("+"|"-") prod )*
prod    := unary ( ("*"|"/"|"%") unary )*
unary   := "-" unary | atom
atom    := NUMBER | IDENT | IDENT "(" expr ("," expr)* ")" | "(" expr ")"
```

- `IDENT` is an input `id`.
- The functions are `min`, `max`, `round(x, digits)`, `floor`, `ceil`, `abs` and `clamp(x, lo, hi)`.
- Booleans are 1/0. Division by zero gives `null`, which displays "—".

### 3.5 Element catalogue

Each element is listed with its exact syntax and rendering. Unless an element says otherwise:

- It takes the full text-column width.
- It has 16 dp of space above and below.
- It inherits `body` typography.

#### `options`: answer chips (sends a reply)

```hermes-ui
{"v":1,"type":"options","id":"use-case","prompt":"What are you building?","select":"one",
 "options":[
   {"label":"Voice companion","send":"I'm building a personal voice companion."},
   {"label":"Homelab controller","send":"I want it to control my homelab and apps."},
   {"label":"Both","send":"Both: a companion that can also control my homelab."}],
 "other":true}
```

**Fields:**

- `select` is `one` (tap sends at once) or `many` (chips toggle, then a **Send** button sends the chosen labels
  joined by ", ", or the `send` texts joined by newlines).
- `other: true` adds an "Other…" chip that focuses the composer.
- There are 2–8 options.

**Rendering:**

- The `prompt` (optional) uses `bodyStrong`, 8 dp above the chips.
- Chips wrap with 8 dp spacing in both directions. Each chip is **40 dp tall** with a **48 dp hit target**, padding
  0 × 16, stadium shape.
- Chip colours: fill `surface` (#1C1C1E), 1 dp `outline` stroke (white at 14 %), label in 15/20 500 `text`.
- Pressed: fill `surfaceHigh` and scale 0.97 over 90 ms.
- Selected (`many`): fill `text` (#FFFFFF), label in `bg`, with a 16 dp check glyph before the label.
- The Send button is a 40 dp `closeFill` pill with the label "Send", disabled until at least one chip is selected.

**After answering:**

- The block locks once any later user message exists.
- The chosen chip (matched by its `send` text against the next user message) keeps the selected style. The others
  drop to 40 % opacity and stop reacting.
- No server state is needed.

**Semantics:** a radio group or a checkbox group, labelled with the prompt.

#### `actions`: buttons

```hermes-ui
{"v":1,"type":"actions","items":[
  {"label":"Run the disk check","style":"primary","action":{"send":"Run the disk check now."}},
  {"label":"Open the pricing page","action":{"link":"https://example.com/pricing"}},
  {"label":"Copy command","action":{"copy":"df -h /mnt/storage"}}]}
```

- There are 1–3 items, laid out in a row that wraps. Each button is 44 dp tall with a 48 dp hit target, padding
  0 × 18, stadium shape.
- `primary` (at most one): fill `closeFill` (white), label in 15/20 600 `onClose`.
- The default style is the chip look from `options`.
- A trailing glyph shows the action kind: ↗ for `link`, a copy glyph for `copy`, none for `send`.
- A `send` action is single-use. It locks like `options` once sent.

#### `cards`: stat cards (measured)

```hermes-ui
{"v":1,"type":"cards","items":[
  {"label":"Base session cost","value":"$3.00","sub":"Excludes backend and tools"},
  {"label":"Alternative","value":"Variable","sub":"Depends on input and output"}]}
```

- There are 1–4 items, in a grid of 2 columns under 600 dp and up to 4 columns above it. The gap between cards is
  12 dp.
- Each card has a 1 dp `hairline` frame, **radius 12**, **padding 12**, no fill (measured: #191919 frame on black).
- Contents, in order:
  - `label` in `statLabel`.
  - 4 dp, then `value` in `statValue`.
  - 4 dp, then `sub` in `statSub`.
- Cards in a row share the height of the tallest card. Long values shrink to fit down to 20 sp.
- Optional `tone` (`neutral`, `good`, `warn`, `bad`) colours only the value: `text`, `success`, `warning`,
  `danger`.

#### `calc`: inputs with computed outputs (the measured calculator)

```hermes-ui
{"v":1,"type":"calc","id":"cost",
 "inputs":[{"id":"minutes","kind":"slider","label":"Session length","min":10,"max":600,"step":10,
            "value":60,"format":"{} minutes"}],
 "outputs":[
   {"label":"Base session cost","expr":"minutes * 0.05","format":"currency:USD","sub":"Excludes backend and tools"},
   {"label":"With tools (est.)","expr":"minutes * 0.05 * 1.4","format":"currency:USD"}]}
```

**Input kinds:**

- `slider`: `min`, `max`, `step`, `value`.
- `stepper`: − and + buttons of 40 dp around a value.
- `toggle`: a switch, value 0 or 1.
- `segmented`: 2–4 labelled values.

**Formats:**

- `"{} unit"` (the value inserted).
- `number:N` (N decimals).
- `percent:N`.
- `currency:XXX` (ISO 4217, formatted with the device locale).
- `duration:min` (renders "3 h 10 min").

**Rendering (measured):**

- Each input row starts with a header line: the `label` in `widgetLabel` at the left, and the formatted value in
  `widgetLabel` with `tabularFigures` at the right.
- The slider sits 12 dp below the header line:
  - It is 48 dp tall (touch), with a **4 dp track**, radius 2.
  - Active part: `text` (white). Inactive part: white at 12 % (#1E1E1E on black).
  - The **thumb is 20 dp**, `bg` fill with a 2 dp white at 30 % ring. When dragged it grows to 24 dp over 90 ms.
- Haptic `selectionClick` on each step. Light thumps are limited to 1 per 40 ms.
- Outputs render as a `cards` grid 16 dp below the last input. Values update every frame while the slider is
  dragged, with no animation (the reference updates instantly).

Local state only. The block resets to `value` when the message is reloaded.

#### `details`: collapsible section

```hermes-ui
{"v":1,"type":"details","title":"Full benchmark method","open":false,
 "body":"Markdown text. **Bold**, lists and tables are allowed; nested hermes-ui is not."}
```

**Rendering:**

- A 48 dp header row with the `title` in `bodyStrong` and a 20 dp chevron at the right, which rotates 0 → 180°
  over 200 ms.
- A hairline above and below the whole element.
- The body is rendered with the same markdown renderer, 8 dp below the header. It expands with a size transition
  over 220 ms, emphasizedDecel.
- `<details><summary>` in the inline-HTML subset renders the same way.

#### `callout`

```hermes-ui
{"v":1,"type":"callout","tone":"warning","title":"Backups paused","body":"NAS-01's nightly job is disabled until **Sunday**."}
```

- A 1 dp `hairline` frame, radius 12, padding 12 × 14, no fill.
- An 18 dp tone glyph at the left (info ⓘ, tip 💡-style bulb outline, warning △, danger ⊘, success ✓), coloured
  with the tone. Only the glyph and the title use the tone colour. The body stays `text`, so it blends with the
  reply.
- The title in `bodyStrong`, the body in `body`, 4 dp apart.

#### `suggestions`: follow-up prompts

```hermes-ui
{"v":1,"type":"suggestions","items":["Compare monthly cost at 2 h a day","Which one supports tool calls?"]}
```

- There are 1–3 items, at most 60 characters each. This element is **not rendered in place**. The app lifts it out
  of the message and shows it **under the action row of the latest reply only**, after the stream ends.
- Layout: vertical list. Each row is a stadium, 40 dp tall, `surface` fill, padding 0 × 14, label in 15/20 400
  `text`, with a 16 dp "↳"-style return glyph in `textMuted` at the left. The gap between rows is 8 dp.
- Motion: rows fade and rise 6 dp, staggered 40 ms, over 180 ms.
- Tapping sends the text as a user message.
- The suggestions disappear when the user sends anything.

#### `group`: layout container

```hermes-ui
{"v":1,"type":"group","title":"Cost comparison","children":[{ "type":"calc", ... }, { "type":"callout", ... }]}
```

- `title` renders as `h2`, using the heading gaps.
- The children stack with 16 dp gaps. Children carry no `v` field.

### 3.6 Streaming behaviour

- While a `hermes-ui` fence is open, show a placeholder:
  - `surface` fill, radius 12, **56 dp tall**.
  - A shimmering `caption` label: "Preparing options…" for options, actions and suggestions; "Preparing
    calculator…" for calc; "Preparing…" for anything else.
  - The placeholder fades in after 150 ms (short blocks never flash it).
- When the closing fence arrives, cross-fade to the rendered element over 180 ms. The height animates from 56 to
  the real height (220 ms, emphasizedDecel), so the text below moves once and smoothly.
- `md_blocks.dart`'s `repairPartial` already closes open fences. The renderer must recognise the `hermes-ui` info
  string on an **unclosed** fence and show the placeholder instead of rendering the JSON as code.

### 3.7 Fallback

- **Invalid JSON, unknown `type`, a limit exceeded or `v > 1`:** render a collapsed `details` titled "Interactive
  content couldn't be shown", with the raw JSON as a code block inside.
- **Copy as markdown** keeps the original fence.
- **Read aloud and Share** read `prompt`, labels and values in order, and never the JSON.

### 3.8 Theme blending rules (apply to every element)

- **Surfaces:** only `bg`, `surface`, `surfaceHigh`, `hairline` and `outline`. The only accent is `closeFill`
  (white) for one primary action. Tone colours apply to glyphs and stat values only. Do not use the blue `accent`
  inside replies: in the reference only white and greys appear, which is why the widgets blend.
- **Shapes:** radius 12 for frames and cards, stadium for chips and buttons. The text column's left edge is shared,
  so nothing is indented.
- **Type:** only the tokens in §1.3.
- **Light theme:** the same structure. Frames use `hairline`, and selected chips are `text` (#16161A) with `bg`
  labels.

### 3.9 Hermes prompt addendum (the bridge adds it when `ui: 1`)

> You can add interactive blocks to replies in the Hermes app. Write a fenced block with the info string
> `hermes-ui` that contains one JSON object `{"v":1,"type":…}`. Types: `options` (answer chips), `actions` (up to
> 3 buttons), `cards` (stat cards), `calc` (sliders, steppers or toggles with computed outputs using + − × ÷, min,
> max and round), `details`, `callout`, `suggestions` (at most 3 follow-ups, at the end of the reply) and `group`.
> Use them only when they help the user act or compare. Keep prose as markdown. Never put HTML, scripts or
> styling in them. A `send` text must say exactly what the user would say. Use GFM footnotes `[^1]` for sources.

The full schema with the field lists in §3.5 lives in the bridge next to the prompt, as
`infra/core/gpt-live-bridge/hermes-ui-schema.json`. The app and the bridge tests share it.

---

## 4. Sidebar swipe

### 4.1 Direction

> **Superseded (November 2026).** A rightward swipe that starts on the chat now opens that chat's **Tasks**, and
> the panel comes in from the left. The sidebar opens with the menu button, or with a rightward swipe that starts
> in the 24 dp strip just past the system back inset (`Sz.drawerEdge`). In live mode a rightward swipe still opens
> the sidebar. The angle lock, slop, exclusions, scroller hand-off and release rules below are unchanged. They now
> apply to both panels.

The recording does not show the sidebar or any swipe. The direction follows the convention of the reference
product and of Hermes today:

- The sidebar is on the **left**.
- A **horizontal swipe toward the right** (finger moving left → right) that starts **anywhere on the thread** opens
  it, and the sidebar follows the finger.
- A swipe toward the **left** anywhere closes it.

"Swipe left from chat" most likely means "swipe from the left side of the chat". If the user means the finger
moving right → left, the same spec applies mirrored. That is an open point (§8).

**The current defect:** `chat_shell.dart:655` only accepts drags that start within **20 dp** of the left edge. With
Android gesture navigation (the QA phone uses it), that strip lies inside the system back-gesture inset (24–32 dp),
so the system takes the touch and the sidebar effectively cannot be swiped open. The fix is the full-surface
gesture below.

### 4.2 Gesture spec

| Parameter | Value |
|---|---|
| Start region | The whole thread pane, **except**: the system gesture insets (`MediaQuery.systemGestureInsetsOf(context)`, left and right), the composer while its field has focus, active text-selection handles, and hermes-ui sliders |
| Direction lock | Accept only after **16 dp** of horizontal travel with `|dx| ≥ 1.6 · |dy|` (within 32° of horizontal). Otherwise reject so the vertical list scrolls. Implement as a custom `HorizontalDragGestureRecognizer` subclass that checks the angle in `hasSufficientGlobalDistanceToAccept` |
| Follow | 1:1. `progress += dx / drawerWidth`, clamped 0–1. The drawer translates from −W to 0 and the content pushes to +W (unchanged push model) |
| Rubber band | Past fully open: content and drawer move at 0.15 × the finger, up to 24 dp |
| Release | With `v = velocity.dx` in dp/s: `v > +365` opens, `v < −365` closes, otherwise open if `progress ≥ 0.4` when opening, or stay open if `progress ≥ 0.6` when closing (hysteresis, so a small wobble never closes it) |
| Settle | Spring, **stiffness 500, damping ratio 0.9, mass 1**, initial velocity `v / W` (unchanged `Motion.drawer`). About 280 ms for a full open |
| Scrim | Black over the pushed content, alpha **0.32 × progress** (dark) or 0.24 × progress (light), linear |
| Haptic | `selectionClick` once when a drag crosses the 0.4 threshold while opening, and none when closing |
| Close by tap | Tapping the pushed content closes the sidebar (unchanged) |
| Reduced motion | No spring: 150 ms linear to the end state. The drag still follows the finger |
| RTL | Mirrored: the sidebar is on the right and the swipe goes toward the left |
| Wide layout (≥ 900 dp) | No gesture. The sidebar is permanent |

### 4.3 Coexistence with horizontal scrollers

Tables, code blocks and hermes-ui segmented controls scroll horizontally.

- **When the scroller can still scroll toward the finger,** it wins. A right-moving drag on a table that is scrolled
  away from its start scrolls the table back.
- **When the scroller is at its start and the drag moves right,** it hands off. The scroller's
  `OverscrollNotification` (with `dragDetails`) is caught by the shell and converted into sidebar progress. From
  then on the sidebar follows the finger, and the release rules apply with the notification's velocity. This is
  how the user can open the sidebar from a table that is at rest.
- **Left-moving drags on a scroller never close a closed sidebar,** since there is nothing to close. They scroll
  normally.
- **Sliders** (hermes-ui `calc`) never hand off.
- **Text selection:** while a `SelectionArea` drag is active (selection handles shown), the sidebar gesture is off.

### 4.4 Android back

- The system back gesture (from either edge) is never intercepted for opening.
- With the sidebar open, back closes it, using **predictive back** (API 33+):
  - During the back preview, `progress = 1 − 0.25 × backProgress`, so the sidebar moves up to 25 % toward closed
    and the scrim follows.
  - On commit it closes with the spring.
  - On cancel it springs back to open.
- With the sidebar closed, back follows the existing order in `chat_shell.dart` (popover, then live, then exit).

---

## 5. Composer: more options, attachments, speech

### 5.1 Layout of the + tray

The recording does not open the + menu. The layout below is our own design, chosen to **avoid** the reference
family's popover with the same five rows (see §7, item 5).

- Tapping **+** opens a **tray** that grows out of the composer upward, attached to it, like a drawer above the
  field.
- Size: full composer width, radius 24 on the top corners only, joined to the pill. Fill `surface`, 1 dp `hairline`
  stroke.
- **Row 1: three tiles**, each 76 dp tall and an equal share of the width with 8 dp gaps, radius 16, fill
  `surfaceHigh`. Each tile shows a 24 dp icon above a 13/16 500 label:
  - **Camera**
  - **Photos** (the Android Photo Picker)
  - **Files** (the system document picker)
- **Rows below** are 52 dp, 16 dp side padding, `row` style, with a trailing switch or chevron:
  - **Think harder**: switch (effort High ↔ previous).
  - **Search the web**: switch, shown only when capabilities report `web_search: true`. It tells Hermes to prefer
    its search tools for this message.
  - **Read replies aloud**: switch (auto TTS for new replies in text mode, §5.4).
  - **Voice and speech settings**: chevron, opens Settings › Voice.
- The tray closes on: tapping +, which has rotated to ×; tapping outside; Back; or picking an item.
- **Motion:**
  - Open: + rotates 45° over 180 ms. The tray clips in from the composer's top edge (height 0 → H) with opacity
    0 → 1 over **220 ms, emphasizedDecel**. The tiles fade in staggered 30 ms.
  - Close: 160 ms, exit curve.
  - Reduced motion: opacity only, 120 ms.
- If the keyboard is open, the tray sits above the keyboard (the composer stays docked to the keyboard).

### 5.2 Attachments in the composer

**Staged items** appear in a strip **inside** the pill, above the text field:

- Images are 56 dp thumbnails with radius 12 and a 20 dp × button at the top right.
- Files are 44 dp-tall chips: a type glyph, the name (middle-ellipsised to 22 characters) and the size in
  `caption`.
- The strip scrolls horizontally when needed.

**Upload progress:**

- Each item shows a 2 dp progress ring (images) or bar (files) in `text`.
- Send stays disabled until every upload finishes. A failed upload shows a `danger` ⟳ retry badge.

**Limits** (from capabilities, below):

- At most 4 items.
- Images are downscaled on the device to 2048 px on the long edge and re-encoded as JPEG quality 85. HEIC is
  converted.
- **EXIF metadata, including GPS, is stripped on the device** before upload.

**In the thread:**

- The user bubble shows images as a row of 120 dp radius-16 thumbnails above the text (as `redesign-spec.md` §4.3
  planned) and files as chips.
- Tapping an image opens a full-screen viewer (pinch to zoom, swipe down to dismiss with a 200 ms fade).

**Play Store requirements:**

- **Photos:** use the **Android Photo Picker** (`ACTION_PICK_IMAGES`, through `image_picker`, which uses it on API
  33+). Do **not** declare `READ_MEDIA_IMAGES` or `READ_MEDIA_VIDEO`. Play's photo and video permissions policy
  rejects broad media access for one-off picking.
- **Camera:** use the camera intent (`ACTION_IMAGE_CAPTURE`). If the manifest declares `CAMERA` (for example
  through a plugin), the app must request it at runtime. Otherwise the intent fails.
- **Files:** use the Storage Access Framework (`ACTION_OPEN_DOCUMENT`). No storage permission is needed.
- **Data safety form:** declare photos, files and audio as user-provided content sent to the user's own server,
  encrypted in transit.

**Server needs (bridge):**

1. `POST /api/uploads` (authenticated), multipart, one file per request.
   - Returns `{"upload_id", "name", "mime", "size", "sha256", "kind": "image|file"}`.
   - Caps: images 10 MB after client compression, files 25 MB, at most 200 MB per conversation.
   - Allowed MIME types: `image/jpeg`, `image/png`, `image/webp`, `application/pdf`, `text/*`, `application/json`,
     and common office types.
   - Files are stored under the bridge's data directory, keyed by sha256, and deleted with the conversation.
2. `POST /api/chat` accepts `"message": {"text", "attachments": ["upload_id", …]}`.
   - Images are passed to Hermes as chat-completions `image_url` content parts (data URLs), **if Hermes' model accepts
     images**. This needs checking against `hermes-api-bridge`.
   - Other files are copied into a per-conversation folder in Hermes' workspace and referenced in the text ("The
     user attached report.pdf at /…/uploads/…").
3. `GET /api/uploads/{id}` streams the file back for thumbnails and the viewer (authenticated, `Cache-Control:
   private`).
4. Capabilities: `"attachments": true, "attachment_limits": {"max_items": 4, "image_mb": 10, "file_mb": 25,
   "mimes": [...]}, "vision": true|false`. With `vision: false`, Camera and Photos stay visible but images are sent
   as files.

### 5.3 Speech-to-text (dictation)

- The composer's **mic** (40 dp, shown when the field is empty) starts **in-app dictation**. Today the app relies on
  the keyboard's voice key.
- **Engine:** Android `SpeechRecognizer` through `speech_to_text`.
  - Prefer on-device recognition (`EXTRA_PREFER_OFFLINE`) when the language pack is installed.
  - Language: the app's language setting, or the device default.
  - Permission: `RECORD_AUDIO`, which is already granted for live voice.
- **While listening:**
  - The mic glyph becomes a 40 dp circle in `text` with a `bg` mic.
  - A ring pulses with the input level (scale 1 → 1.18 at full level; attack 60 ms, release 180 ms).
  - Partial text streams into the field in `textMuted`, then turns `text` when final.
  - The placeholder reads "Listening…".
  - The action button shows ↑ as soon as there is text.
- **Stop:** tap the mic again, after 2.0 s of silence (the engine default), or by sending.
- **Haptics:** `lightImpact` at start and `selectionClick` at stop.
- **Errors:**
  - "Couldn't hear that" appears as a toast for no-match.
  - A missing recogniser falls back to focusing the field and showing the keyboard (whose own voice key still
    works).
- **Server engine (done 16 Nov 2026, the default):** `POST /api/transcribe` (WAV, at most 2 min) → `{"text"}` with
  gpt-4o-transcribe through CLIProxyAPI. See voice-models.md §4b for the accuracy findings and engines.
- **Press and hold (16 Nov 2026, `composer/mic_hold.dart`, `dictation_hold.dart`):**
  - Listening starts on the press (light haptic), so no first word is lost. A press under 300 ms is a **tap**:
    everything above is unchanged.
  - Held past 300 ms (medium haptic): the mic grows into an accent bubble that pulses with the voice. A panel above
    the composer shows the words as they arrive (fading in; the unstable part muted), a scrolling level waveform,
    a timer with a breathing red dot, and "Release to send · ‹ Slide left to cancel".
  - **Release** stops, waits for the last phrase and **sends**. With nothing heard, "Didn't catch that. Nothing was
    sent." Sending never closes or opens the keyboard.
  - **Slide left** 110 dp cancels (the panel and bubble turn red on the way; medium haptic) and restores the field.
  - **Slide up** 80 dp **locks** hands-free (selection haptic): a lock hint fills on the way. The panel then has
    Cancel and Send, and a tap on the mic also sends.
  - The mic claims its pointer at once, so swipe up to live, the sidebar swipes and scrolling never take a press
    that began on it. A system pointer cancel turns a press into a tap and a hold into hands-free.
  - **Screen readers:** the mic's hint is "Hold to talk and send". Its long-press action starts hands-free with
    Cancel recording / Send recording buttons, and the panel is a live region.
  - **Reduced motion:** no growth, travel, pulse or waveform scroll (a still level meter); changes cross-fade.
  - Errors close the panel and explain: no permission, nothing heard, the server unreachable ("Couldn't reach the
    Tove server to transcribe."), busy.

### 5.4 Text-to-speech (Read aloud)

**Triggers:**

- **Read aloud** in the action row (§2.4).
- The **Read replies aloud** switch in the + tray, which reads each new reply when its stream ends. It is off by
  default.
- It never runs during live voice.

**Engine:** Android `TextToSpeech` through `flutter_tts`. It works offline and costs nothing. The voice and speed
come from Settings › Voice: speed 0.8×–1.5×, default 1.0×.

**Speakable text:**

- Strip markdown.
- Read lists item by item with pauses.
- Read tables as "Table with N rows" followed by the header row only.
- Code blocks become "Code block skipped".
- Read hermes-ui as described in §3.7.
- Hosts and URLs are skipped. Footnote chips are skipped.

**Player:** our own design. The reference uses a full-width bar under the top buttons, so ours is a **capsule
docked above the composer**, near the thumb:

- Height 48 dp, width up to 320 dp, centred, 8 dp above the composer. Fill `surfaceHigh`, stadium shape, 1 dp
  `hairline`.
- Left: a 36 dp `text` circle with ❚❚ or ▶ in `bg`.
- Middle: the message's first words (`caption`, one line), with a 2 dp progress line along the capsule's bottom
  inner edge (`text` on white at 12 %).
- Right: a speed toggle ("1×", `chip` style) and a 36 dp ×.
- The message being read gets a 3 dp `accent` bar in the left gutter, 8 dp outside the text, so the user can find
  it.
- **Motion:** it rises 8 dp and fades in over 140 ms (measured reference bar: about 130 ms). It goes out over
  120 ms.
- **Audio focus:** it ducks for notifications and pauses when another app takes focus or the headphones unplug.

**Server option (later):** `POST /api/tts {"text", "voice"}` → `audio/ogg` stream, using the same voice as live
mode for continuity. Capabilities: `"tts": true`.

---

## 6. Gap list: current app vs this spec

Ordered by visual impact. Paths are relative to `apps/hermes_live/lib/src/ui/`. Line numbers are from the tree on
15 November 2026, while another delegate is editing the app, so re-check them before changing anything.

| # | Gap | Current | Target | Files |
|---|---|---|---|---|
| 1 | Typeface | Inter (9.6 % wider than the reference) | Roboto Flex variable, subset, `opsz` = size (§1.2) | `theme/tokens.dart:119` (`fontFamily`), new `_v` style helper; `theme/fonts.dart` (licences); `pubspec.yaml` fonts; `assets/fonts/` |
| 2 | Text colour and stroke | `text` #ECECEC, Inter 400 renders thin | `text` #FFFFFF; `textMuted` #B4B4B8 | `theme/tokens.dart:68-69` |
| 3 | Bold weight | 600 | 700 (inline), 650 (H2, H3) | `markdown/markdown_style.dart` (`bodyStrong` getter), `markdown/md_render.dart:694` (hard-coded `w600` for `strong`), `theme/tokens.dart:144-147` |
| 4 | Gutter | 20 dp | 16 dp; reading measure max 680 dp | `theme/tokens.dart:216` (`Sp.content`, or a new `Sp.thread = 16`), `thread/thread_view.dart:203-205, 278` |
| 5 | Block rhythm | Paragraph 14, heading 20 above / 8 below, rule 20 | 16; 24 / 8 (H1 32 / 12); rule 24; para-with-colon → list 8; table gaps 12 / 16 | `markdown/markdown_style.dart` (defaults), `markdown/md_render.dart:105` (`gapBetween` needs list, table and colon cases) |
| 6 | Lists | `•` glyph in `textMuted`, indent 22, item gap 6 | Painted 6 dp dot in `text`, indent 32, item gap 0, nested ring/square, ordered numbers in a 24 dp right-aligned box | `markdown/md_render.dart:341-368` (`_list`), `markdown/markdown_style.dart` (`listIndent`, `listItemGap`) |
| 7 | Headings | H1 24/30 700, H2 21/28 700, H3 18/24 600; H4–H6 use `bodyStrong` | 26/32 700, 23/30 650, 20/27 650, H4 17/26 700 | `theme/tokens.dart:145-147`; `markdown/markdown_style.dart` (add `h4`); `markdown/md_render.dart` heading switch |
| 8 | Tables | 10 × 12 cell padding (first column indented 12), header 600, 24 dp fade, ends 25 dp from the right edge | 8 vertical, 0 left, 24 right; header 700; bleeds to the screen edge, no fade; numeric columns right-aligned | `markdown/md_table.dart:76, 103-106, 137`; `markdown/markdown_style.dart` (`tableEdgeFade` → 0, `tableMaxColumnWidth` → 300) |
| 9 | User bubble | 82 % width, padding 12 × 16 | 78 %, padding 11 × 16, 48 dp one-line height | `thread/messages.dart:115` |
| 10 | Source citations | "Sources:" list → blue `accentSoft` pills | Footnote chips inline at paragraph end, neutral `surfaceHigh`, "+N", Sources sheet; footnote pre-scan across blocks | `markdown/source_pill.dart`, `markdown/md_render.dart:603` (`_sourcesList`), `markdown/hermes_markdown.dart` and `markdown/streaming_text.dart` (definition pre-scan) |
| 11 | hermes-ui blocks | Not supported (shown as code) | §3: new `markdown/ui_blocks/` (parser, validator, expression evaluator, widgets); `pre` dispatch by info string | `markdown/md_render.dart:308` (`case 'pre'`), `markdown/md_blocks.dart` (`repairPartial`: placeholder for an open `hermes-ui` fence), new files |
| 12 | Inline HTML subset | Tags appear as raw text | `<small>`, `<kbd>`, `<mark>`, `<sub>`, `<sup>`, `<u>`, `<br>`, `<details>` rendered; others literal | `markdown/md_render.dart` (inline switch near `:692`), an inline syntax for `package:markdown` |
| 13 | Scroll-to-bottom button | None | §2.3 | `thread/thread_view.dart`, `thread/follow_scroll.dart` |
| 14 | Sidebar swipe | 20 dp edge only, inside the system back inset, so effectively unusable | Full-surface swipe with an angle lock, scroller hand-off and predictive back (§4) | `shell/chat_shell.dart:654-675`; new recognizer in `shell/` |
| 15 | Action row | Copy, Retry, More; no Read aloud or Share | Copy, Read aloud, Retry (last only), More (Share, Copy as markdown, Copy table, Delete, time header) | `thread/messages.dart:434-460` |
| 16 | Links | Dotted underline + ↗ glyph | Solid 35 % underline, no glyph | `markdown/md_render.dart:820-836` (`_link`) |
| 17 | Code blocks | Padding 14, text "Copy" button | Padding 16, icon-only copy, caption-style label | `markdown/code_block.dart:69-125` |
| 18 | Inline code | 0.9 × body, padding 2 × 5 | 0.88 × body, padding 1.5 × 5, line − 3 | `markdown/markdown_style.dart` (`inlineCode` getter), `markdown/md_render.dart` (`_inlineCode` padding) |
| 19 | + tray | Popover with Camera, Photos, Files (Coming soon), Think harder, More | Tray (§5.1); attachments once the bridge supports them | `composer/plus_menu.dart`, `composer/composer.dart` |
| 20 | Dictation and TTS | Keyboard voice key only; no TTS | §5.3 and §5.4 | `composer/composer.dart:631`, new `speech/` services, `thread/messages.dart` |

The renderer's block cache keys on `MarkdownStyle` equality. Changing token values through `fromTokens` keeps that
working. New fields (`h4`, `caption`, etc.) must be added to `_props` in `markdown_style.dart`.

---

## 7. Trade dress: where we must stay different

The app goes to the Play Store under the **Hermes** name with **our orb**. The following elements of the reference
family are distinctive enough that copying them would make Hermes look like the other product. This spec avoids
each of them.

1. **Composer action button.** The reference uses a **saturated blue filled circle with a white waveform** at the
   composer's right end. Keep ours: a `closeFill` (off-white) circle with a dark glyph. Never turn it blue.
2. **Placeholder wording.** The reference puts the product name after a verb in the field. Keep "Ask Hermes".
3. **Top-right grouped pill** (a glass capsule holding a "compose" pen-in-square and a kebab). Keep our single round
   ⋯ button, and put New chat in the sidebar.
4. **User bubble colour.** The reference's bubble is a **deep navy gradient**. Keep our neutral `surface` bubble.
   Do not add gradients.
5. **The + menu.** `redesign-spec.md` §4.6 copied the reference's popover almost row for row (Camera, Photos, Files,
   "Think harder" ✓, More ›, 32 dp circular icon chips). This addendum replaces it with the tray in §5.1 (tiles plus
   switches). Rename any item whose wording matches the reference: use "Think harder" only if it is not the
   reference's own label. Otherwise call it **"Deep think"**. The tray's "Search the web" and "Read replies aloud"
   are generic descriptions.
6. **Overflow menu wording.** The reference's menu offers a branch action under its own phrase. Hermes does not
   copy it. If branching is added later, call it **"Continue in new chat"**.
7. **Read-aloud player.** The reference shows a full-width bar under the top buttons. Ours is a centred capsule above
   the composer with a gutter marker on the message (§5.4).
8. **Action row.** Four bare icons in a row are a generic convention. Our order (Copy, Read aloud, Retry, ⋯) and our
   Material Rounded glyphs differ from the reference's set and order (which has Share as a top-level icon and uses
   its own speaker glyph).
9. **Source chips.** The reference shows publisher favicons. Ours show a globe glyph and the host. That is also
   required for privacy.
10. **Typography.** Roboto Flex is a generic OFL face and Android's system design. The reference's proprietary face
    is not used, and the metrics in §1.3 are matched only for readability. Hermes headings and the orb keep the
    brand distinct.
11. **Icons, names, the logo and the reference's sample content** (brand names in its reply) appear nowhere in this
    spec or in the app. The design notes describe them only generically.

---

## 8. Could not be measured, and open points

- **Swipe direction.** The recording has no sidebar. Section 4 assumes the drawer is on the left and opens when the
  finger moves right. **Confirm with the user** whether "swipe left" means that, or a right-to-left swipe.
- **The + menu, attachments, dictation UI and thinking state** are not in the recording. §5 and §2.5 are our design.
- **H1, H3, H4, ordered and nested lists, quotes, code, prose links, rules and emoji** are not in the recording.
  §1.5–§1.12 are derived from the measured system.
- **Streaming.** The recording shows only completed text, so the existing 240 ms chunk fade stays.
- **System font scale on the phone** is unknown. Both apps were recorded on the same phone, so relative values hold.
  Absolute sp assumes scale 1.0. A setting of 1.1 would make the reference body 15.5–16 sp. Check with
  `adb shell settings get system font_scale`.
- **The reference's exact typeface** is proprietary and not identified. Roboto Flex is the closest free match by
  width (+1.6 %) and stem weight.
- **Source-sheet and popover timings.** The variable frame rate drops frames during some transitions. Only the
  overflow popover (about 120 ms fade) and the player (about 130 ms) were timed reliably. The share sheet is the
  system's own.
- **Server:**
  - Whether Hermes' model accepts images (`vision`), and whether a homelab speech-to-text or TTS model exists.
  - Whether `hermes-api-bridge` passes multi-part content through.
  - These need checking before §5.2–§5.4's server items are built.
