# Hermes app redesign: chat and live voice

Status: design spec, 15 November 2026. Nothing in this document is implemented yet.

Scope: turn `apps/hermes_live` from a voice-only call screen into a full chat app for Hermes Agent. It gets text
chat with history and streaming replies. Live voice (GPT-Live-1 over the existing WebRTC path) becomes a mode
**inside** a chat thread instead of a separate screen. The look and motion follow the operator's reference
recordings. Those recordings are private and are not stored in the repo (see §0).

Measurements are in logical pixels (dp) for a 412 × 915 dp phone, the size of the reference device, unless a
value is given as a fraction of the screen. Every colour is a design token (§3). Durations are in ms.

---

## 0. References and what they show

The references are photographs of a phone screen taken with a second camera, plus one screen recording. Colours in
the photos are overexposed and warm-shifted by the camera, so this spec does **not** take hex values from them. It
takes layout, proportions, hierarchy and motion from them, and gives neutral tokens that reproduce the intent: a
true-black canvas, neutral grey glass surfaces, and one blue accent.

Working copies (private, outside the repo, mode 700): `~/.local/state/hermes-live-design/refs/`, containing
`shot01–14.png`, `small/`, `frames/` (all 271 video frames), `contact_2fps.jpg`, `contact_10fps.jpg`,
`strip_drop.jpg`, `orb_closeup.jpg` and `orb_metrics.txt` (orb diameter per frame next to the audio RMS).

All 14 photos and the video come from **one product**, a third-party AI chat app in its live voice mode, dark
theme. They are not two sets of "app versus design-site inspiration". The two capture times split them by topic:

| Ref | Time | Shows | What stands out |
|---|---|---|---|
| shot01 | 02:23 | Live mode, docked orb, long rich answer | Text is laid out top to bottom under the app bar: paragraphs, **bold**, inline `code` chips, a bullet list, a source pill (favicon and label), and a link with a dotted underline and ↗. The orb (≈ 0.22 × screen width) sits centred just above the composer and **overlaps** the last lines of text. The live composer row is a pill "+ Ask …" with a gauge glyph, a mute circle and a light close circle. |
| shot02 | 02:24 | Same, with a heading and a table | H2 heading, then a three-column table with hairline row separators. The third column is clipped at the screen edge, so it scrolls horizontally. Rows near the composer **fade out**. |
| shot03 | 02:24 | Same, another table | A "Searched 2 websites" row with stacked favicons under the table. The heading weight is visibly heavier than the body. |
| shot04 | 02:24 | Same as shot03, scrolled | The fade above the composer is visible again. The orb overlaps the table. |
| shot14 | 02:30 | Live mode, **centred orb**, empty canvas | Black canvas. Two round glass buttons at the top (menu at left, sliders at right). An orb about 0.5 × screen width sits about 46 % down the screen. The live composer is pinned to the bottom. |
| shot13 | 02:31 | Live **settings sheet** | A floating bottom sheet, inset from the screen edges, with a large radius and a grab handle. Title "Settings". One outlined group card holds Voice (value and ›), Language (Auto-detect ⌄) and Audio output (Speaker ⌄). The orb stays visible and keeps animating above the sheet. |
| shot12 | 02:31 | **Choose a voice** page inside the sheet | The sheet grows to about 75 % height. A round back button sits at the top left with the title centred. Voices are grouped under language headers ("American English" and so on), each group in an outlined card with rows of about 56 dp. The selected row has a ✓. The orb is pushed up and partly hidden behind the sheet. |
| shot11 | 02:31 | Voice list, scrolled | More groups (Hindi, Argentinian Spanish, Brazilian Portuguese, British English). The header stays fixed. |
| shot10 | 02:31 | **Language dropdown** | A tall popup menu anchored above the Language row: "Auto-detect ✓" followed by an alphabetical list, with a thin scrollbar. The row's chevron flips to ⌃. |
| shot09 | 02:31 | **Audio output dropdown** | A small popup anchored to the right half of the group card, above the row: Speaker ✓ and Phone. |
| shot08 | 02:31 | **"+" menu** with the keyboard open | A popover above the composer's +, left-aligned, with 5 rows: Camera, Photos, Files, "Think harder" ✓ and More ›. Each row has a 32 dp circular icon chip. The keyboard is up because the field has focus. Live mode keeps running (mute and close are still visible). |
| shot07 | 02:31 | **Effort slider**, first stop | The composer row is replaced by a centred label ("Instant effort") above a wide pill track with three stops. The thumb is a white disc with a blue ring at stop 1. |
| shot06 | 02:31 | Effort slider, middle stop | "Medium effort". A blue fill runs from the left end to the thumb, and the thumb is now plain white. |
| shot05 | 02:31 | **Chat drawer** over live mode | A push-style drawer about 0.82 × width. Header with the app name and a round search button. Navigation rows with outline icons, then "Pinned" and "Chats" sections. The current chat is highlighted, and live-voice chats show a waveform glyph. A floating blue "Chat" (new chat) pill and an avatar at the bottom. **The live call's × stays visible**, so the call keeps running while the user browses. |

**Video** (`…6fa02733….mp4`): 11.28 s, 720 × 1280, HEVC, 24 fps nominal (271 frames, average 24.0 fps), AAC
audio.

| Time | What happens |
|---|---|
| 0.0–2.4 s | The assistant speaks. The orb is centred and **pulses with the audio**: diameter 165↔181 px against its 144 px rest size, following the audio RMS with a lag of about 80 ms. Clouds fill about 80 % of the orb, with only a thin blue cap at the top. |
| 2.4–3.3 s | Speech ends. The orb **shrinks smoothly** from 180 to 144 px over about 0.9 s. The blue sky grows back to about 45 % as the cloud bank sinks. |
| 3.3–5.0 s | The orb rests and breathes. The cloud horizon drifts and waves slowly. |
| 5.0–6.8 s | Before the answer, the cloud field **rolls**: the horizon tilts about 35–40° in 0.75 s. This is read as the thinking/working state (see §6.2). |
| 6.83 s | First answer text arrives. The orb **drops from centre to the docked position** above the composer and shrinks to about 0.41 × its size, in **about 250–290 ms** (6–7 frames). The first words appear about 80 ms after the drop starts and stream in at the top, with the last few words of a line fading in. |
| 7.4 s | A status label ("Searching the web") fades in **under the docked orb**. The orb lifts about 8 dp to make room. The label has a light sweep shimmer. |
| 7.4–11.3 s | Text streams paragraph by paragraph while the docked orb idles. |

Trademarks: the references carry the third-party product's name, logos, avatar and placeholder wording. **None of
these is reproduced.** This spec uses "Hermes" and generic icons only. The voice names in §5.11 come from the GPT-Live
API's own voice IDs (`kVoices`), not from the reference UI.

---

## 1. Product model

- **One thread holds both modes.** A conversation is a list of messages. Typed turns and live-voice turns live in
  the same thread. Live mode is an overlay on the current thread, entered from the composer and left with ×. Its
  transcript lands in the thread as messages.
- **Text replies come from Hermes Agent** through a new streaming endpoint on the bridge (§9). **Voice replies come
  from GPT-Live-1.** GPT-Live delegates real work to Hermes as tasks (the existing `/api/delegate` flow).
- **While live, the canvas shows rich content, not captions.** Following the references, live mode shows no running
  caption of the speech. It shows the orb. When Hermes returns a **task result** (markdown), that result renders as
  rich text in the live canvas and the orb docks. Speech transcripts are stored in the thread and shown once the user
  leaves live mode (and in the drawer's live chats).
- The current single-call server rule stays: one live session at a time, and at most 2 tasks.

---

## 2. Screens and navigation

```
App start
 ├─ no key ──► Connect (onboarding) ──► Home
 └─ key ─────► Home = ChatShell
                 ├─ Drawer (push from left): New chat · Search · Pinned · Chats · Settings · Profile
                 ├─ Thread (text mode)  ── composer ── [Live button] ──► Live mode (overlay on the same thread)
                 │      └─ message long-press: Copy · Retry · Read aloud(later) · Delete
                 ├─ Live mode
                 │      ├─ top-left ≡ ─► Drawer (call continues)
                 │      ├─ top-right sliders ─► Live settings sheet ─► Choose a voice (push in sheet)
                 │      │                                      ├─ Language dropdown
                 │      │                                      └─ Audio output dropdown
                 │      ├─ + ─► Plus menu (keyboard opens; typed text goes to the live session or a text turn)
                 │      ├─ gauge ─► Effort slider (replaces the composer row)
                 │      ├─ mic ─► mute toggle
                 │      └─ × ─► end live, back to text mode in the same thread
                 └─ Settings (full screen, from the drawer): Appearance, Voice, Motion, Sounds & haptics,
                    Connection, About
```

### 2.1 Connect (onboarding)

The first launch and "Change server or key" both use it. It keeps the current logic (URL, key, verify, save
anyway) with the new styling: black canvas, a centred orb at 120 dp idling in the listening style, the word
"Hermes" in Display style, a one-line subtitle, two filled text fields (§5.9) and a full-width primary button. While
the key is being checked, the orb uses the connecting style. A wrong key gives a light error shake of the field
(§6.9) and red helper text.

### 2.2 Chat shell, thread (text mode)

- **App bar** (overlaying the content, transparent, 56 dp below the status bar): a glass round button at the left
  (menu glyph: two horizontal bars, the top one longer) opens the drawer. The centre holds the conversation title,
  Title style, single line with ellipsis, fading in once the thread has scrolled under it. A glass round button at
  the right opens the live settings sheet when live and the overflow menu (Rename, Pin, Delete, Share as text) when
  not. Behind the bar, a gradient scrim runs from `bg` at 100 % to 0 over 72 dp so content scrolls underneath
  cleanly.
- **Empty thread:** a centred orb at 96 dp (idle), the greeting "What can I do for you?" in Headline style, and up to
  4 suggestion chips (§5.10) in a wrap above the composer.
- **Messages:** a list, newest at the bottom, with 20 dp side padding and a max content width of 720 dp, centred on
  wide screens.
- **Composer:** pinned to the bottom above the keyboard (§5.5).
- **Wide layout (≥ 900 dp):** the drawer becomes a permanent 300 dp sidebar. Live mode covers only the content
  pane. The thread is centred at a max of 720 dp.

### 2.3 Live mode (overlay on the thread)

- The canvas is pure black (`bg`), and the thread content is hidden (faded, §6.4).
- **Top:** the same two glass buttons. ≡ opens the drawer and the call continues. Sliders opens the live settings
  sheet.
- **Orb:** centred (`orbCentered`) while there is no rich content to show. Once a task result streams in, it docks
  (`orbDocked`).
- **Live canvas text:** shows the latest task result for this live session (markdown), starting 8 dp under the app
  bar. It scrolls. Text under the docked orb fades out (§5.3).
- **Status label:** shown under the orb in either position: "Connecting…", "Muted", "Working on it · 12 s",
  "Reconnecting…".
- **Live composer row:** pill, mute and close (§5.6).

### 2.4 Drawer

A push drawer (§5.7). The live call keeps running while the drawer is open, and the live × stays visible at the
bottom right. Selecting another chat while live first asks "End live voice and open *Title*?" with End and switch
or Cancel, because the live session belongs to the current thread.

### 2.5 Settings (full screen)

The current settings screen, restyled with grouped cards (§5.8):

- **Appearance:** Dark, Light or System. The default changes to **Dark**, matching the references.
- **Voice:** opens the same voice picker as the sheet.
- **Reply effort:** Instant, Medium or High.
- **Motion:** reduce motion.
- **Sounds and haptics:** two switches.
- **Connection:** server, change key, forget key.
- **About.**

---

## 3. Visual tokens

Defined in `lib/src/ui/tokens.dart` as `HermesTokens` (a `ThemeExtension`), replacing today's `HermesColors`. Names in
`code` are the token names.

### 3.1 Colour

| Token | Dark (default) | Light | Use |
|---|---|---|---|
| `bg` | `#000000` | `#FFFFFF` | Canvas: the live canvas and the thread |
| `bgRaised` | `#0B0B0C` | `#FAFAFA` | Drawer background (dark gets a small lift so the push edge reads) |
| `surface` | `#1C1C1E` | `#F1F1F3` | Composer pill, user bubble, cards |
| `surfaceHigh` | `#2A2A2D` | `#E9E9EC` | Pressed/selected rows, inline code bg, menu |
| `glass` | `#FFFFFF` @ 12 % over content | `#000000` @ 6 % | Round app-bar buttons, mute button (with blur, §3.6) |
| `glassStroke` | `#FFFFFF` @ 10 % | `#000000` @ 8 % | 0.5 dp inner stroke on glass |
| `sheet` | `#1C1C1E` @ 94 % | `#FFFFFF` @ 96 % | Bottom sheets and popovers (with blur) |
| `outline` | `#FFFFFF` @ 14 % | `#000000` @ 12 % | Group cards, table rules |
| `hairline` | `#FFFFFF` @ 10 % | `#000000` @ 8 % | Row separators |
| `text` | `#ECECEC` | `#16161A` | Primary text (16.7:1 dark on `bgRaised`, 18.0:1 light) |
| `textMuted` | `#A9A9AE` | `#6B6B72` | Secondary text (7.3:1 on `surface`, 5.3:1 light) |
| `textFaint` | `#8E8E93` | `#8A8A91` | Placeholder, timestamps (5.2:1 on `surface`) |
| `accent` | `#3D63F5` | `#2F57E8` | New-chat pill, effort fill, links, focus ring (white on it: 4.9 / 5.75:1) |
| `accentSoft` | `#20253A` | `#E8EDFF` | Selection, source pills; text on it `#D7DBFF` / `#2F57E8` |
| `onAccent` | `#FFFFFF` | `#FFFFFF` | |
| `closeFill` | `#F2F0EC` | `#16161A` | The light × "end live" button; × glyph in `#0B0B0C` / `#FFFFFF` (17:1) |
| `danger` | `#FF6B6B` | `#C62828` | Errors (7.1:1 / 5.6:1) |
| `success` | `#4ADE80` | `#15803D` | Task done |
| `warning` | `#F5B54A` | `#9A5B00` | Limited background note |
| `scrim` | `#000000` @ 48 % | `#000000` @ 32 % | Behind sheets and the drawer |

**Orb palette** (shared by both themes; the orb is always "daylight sky"):

| Token | Hex | Role |
|---|---|---|
| `orbSkyTop` | `#2F55F0` | Zenith, saturated blue |
| `orbSkyLow` | `#7F9BFF` | Sky near the horizon |
| `orbCloud` | `#F4F1FA` | Cloud body (warm white with a touch of lavender) |
| `orbCloudShade` | `#CFC6E3` | Cloud underside and shadow |
| `orbRim` | `#FFFFFF` @ 35 % | 1 dp inner rim highlight |
| `orbGlow` | `#8FA6FF` @ 18 % (dark only) | Outer halo, radius 1.12 × r. Light theme instead uses a shadow `#000000` @ 10 %, blur 24, y +6 |
| muted variant | Desaturate to 35 %, then multiply by 0.85 | Muted state |
| error variant | Hue-shift the sky to `#8C5A5A` / `#C99393`, clouds unchanged | Error state |

### 3.2 Typography

Families (OFL, bundled locally because the web CSP is `font-src 'self'`):

- **Inter** (variable, OFL 1.1) for all UI and body text. Its neo-grotesque shape is closest to the references.
  Ship `Inter-Variable.ttf`, or static 400/500/600/700 if variable-font weight axes cause trouble on web.
- **JetBrains Mono** (OFL 1.1), 400 and 600, for inline and block code.
- Keep **Roboto** (already bundled, Apache 2.0) as the fallback family. Add licence entries for both new fonts in
  `main.dart` (`LicenseRegistry`).

| Style | Size / line height | Weight | Letter spacing | Use |
|---|---|---|---|---|
| Display | 34 / 40 | 600 | −0.6 | Onboarding title |
| Headline | 24 / 30 | 600 | −0.3 | Empty-thread greeting |
| Title | 17 / 22 | 600 | −0.2 | App-bar title, sheet titles, effort label |
| Body | 17 / 26 | 400 | −0.1 | Assistant markdown and user bubbles (references: about 17 sp with generous leading) |
| BodyStrong | 17 / 26 | 600 | −0.1 | `**bold**` |
| H1 / H2 / H3 (md) | 24/30 / 21/28 / 18/24 | 700 / 700 / 600 | −0.3 | Markdown headings |
| Row | 16 / 22 | 500 | 0 | Drawer rows, sheet rows, menu rows |
| Section | 14 / 18 | 600 | 0 | "Pinned", "Chats", voice group headers (`textMuted`) |
| Table | 14.5 / 20 | 400 (header 600) | 0 | Markdown tables |
| Label | 13 / 16 | 500 | 0 | Status label under the orb, chips, timestamps |
| Code | 14.5 / 22 | 400 | 0 | Code blocks; inline code 15.5 at the body line height |

All sizes are in sp and scale with the system text scale (§8.3).

### 3.3 Spacing scale (dp)

`2, 4, 8, 12, 16, 20, 24, 32, 40, 56`.

- Screen side padding: 20 for content, 16 for controls.
- Paragraph gap: 14. Gap between messages from the same speaker: 8. Gap between speakers: 24.
- Composer bottom: 12 above the safe-area inset (the gesture bar).

### 3.4 Corner radii

| Element | Radius |
|---|---|
| Inline code | 6 |
| Code block | 16 |
| Table container | 0 (rules only) |
| User bubble | 22 (all corners; no tail) |
| Menu and popover | 24 |
| Group card | 20 |
| Floating sheet | 32 |
| Composer pill, chips, buttons | Stadium (fully round) |
| Drawer | 0 (full-height, push) |

### 3.5 Sizes (dp)

| Element | Size |
|---|---|
| Glass app-bar button | 40 (48 hit target) |
| Live composer: pill height, mute, close | 52 each, gap 8 |
| Text composer: min height | 52; grows to 6 lines, then scrolls |
| Composer action button (send / live / stop) | 40 inside the pill |
| `orbCentered` diameter | `clamp(0.50 × width, 168, 280)`, centre at 46 % of the safe-area height |
| `orbDocked` diameter | `0.41 × orbCentered` (≈ 84 on 412 dp); bottom 40 dp above the composer top; the status label sits in that gap |
| Effort track | `min(width − 72, 360)` × 52; thumb 40; stop dots 6 |
| Drawer width | `min(0.82 × width, 340)` |
| Floating sheet | inset 10 from the sides and bottom; max width 520 |

### 3.6 Elevation, blur and glass

There are no Material shadows in dark mode; depth comes from fills and blur.

- **Glass** (app-bar buttons, mute, composer pill while live): `BackdropFilter(sigma 20)` + `glass` fill + a 0.5 dp
  `glassStroke`. Fallback (§7.3): an opaque `surface` fill at 92 %, no blur.
- **Sheets and popovers:** blur sigma 30 + `sheet` fill + a 0.5 dp `outline`. Light theme adds a shadow
  `#000000` @ 12 %, blur 32, y +8.
- **Close button:** solid `closeFill`. This is the only bright control, so "end" is always easy to find. Light
  theme inverts it.

### 3.7 Iconography

Rounded outline icons with a 1.75 dp stroke at 24 dp (Material Symbols Rounded, weight 300–400, or the existing
`Icons.*_rounded`). The references use thin, rounded line icons. Use filled variants only for selected or toggled
states.

| Function | Glyph |
|---|---|
| menu | Two bars, the top one longer (custom `CustomPainter`, 20 × 14) |
| live settings | Two sliders (`tune`) |
| plus | `add` |
| effort gauge | `speed` |
| mute | `mic` / `mic_off` |
| close | `close` |
| send | `arrow_upward` |
| live | Custom 4-bar waveform glyph |
| stop | Rounded square |
| voice | Waveform |
| language | `language` |
| audio output | `volume_up` |
| attach | `photo_camera`, `image`, `attach_file` |
| think harder | `speed` |
| more | `more_horiz` |
| search | `search` |
| new chat | `edit_square` |
| pin | `push_pin` |

---

## 4. Layout details per screen

### 4.1 Live mode, centred (`shot14`)

```
┌──────────────────────────────┐
│ (≡)                      (⫶) │  40 dp glass buttons, 16 dp inset, 8 dp below status bar
│                              │
│                              │
│            ◯◯◯◯              │  orbCentered, centre at 46 % of the safe height
│           ◯ orb ◯            │
│            ◯◯◯◯              │
│        Connecting…           │  status label (only when a state needs it), 16 dp below the orb
│                              │
│ ( +  Ask Hermes      ◔ ) (🎙)(✕)│  live composer row, 16 dp sides, 12 dp above the safe bottom
└──────────────────────────────┘
```

### 4.2 Live mode, docked with content (`shot01–04`, video at 7 s or later)

- The content column starts 8 dp under the app bar and has 20 dp sides. It scrolls, and it follows the stream while
  the user is within 160 dp of the bottom (same rule as today's transcript).
- Bottom fade mask (`ShaderMask`, `dstIn`): opaque down to (docked orb centre − 24 dp), then a linear fade to 0 at the
  composer top. The orb is drawn **over** the text and is not separated from it, as in the references.
- The status label is centred 8 dp under the docked orb.

### 4.3 Thread, text mode

- **User message:** right-aligned bubble, `surface` fill, radius 22, padding 12 × 16, max width 82 % of the content
  width, Body style.
  - Live-voice user turns show a 14 dp waveform glyph in `textFaint` before the text, inside the bubble.
  - Image attachments (later) appear as 120 dp rounded-16 thumbnails above the bubble.
- **Hermes message:** no bubble. Full-width markdown (§5.2), left-aligned, with a 20 dp side gutter.
  - Below the last message of a reply, an action row in 20 dp `textMuted` icons, spaced 16: Copy, Retry, and More
    (… Delete, Copy as markdown). It fades in after the stream ends.
  - Task results that came from a live call carry a small "From live voice · 12 s" Label above them.
- **Hermes task card** (live delegation shown in the thread): an inline card with the `surface` fill, radius 20, a
  mini orb (20 dp) or status icon, "Working on it · 12 s", the task text, and the expandable answer. It is today's
  `TaskCard`, restyled.

### 4.4 Drawer (`shot05`)

Top to bottom:

1. The header row is 56 dp: "Hermes" in Title style at 20 dp from the left, and a 40 dp glass search button at the
   right.
2. Navigation rows (44 dp, 20 dp left pad, 22 dp icon, 12 dp gap, Row style): **Search chats**, **Tasks** (all
   Hermes jobs, later), **Settings**. The references show other product sections here; Hermes only needs these.
3. "Pinned" Section header (top 24, bottom 8), then pinned chats.
4. "Chats" Section header, then chats newest first (44 dp rows, single line, ellipsis).
   - Live-voice chats get a leading 16 dp waveform glyph.
   - The current chat has an `surfaceHigh` fill, radius 12, inset 8 dp horizontally.
   - Long-press opens a menu: Rename, Pin/Unpin, Delete.
   - Lazy paging: "See all" at the bottom after 30 rows.
5. Bottom overlay (floating over the list, with a 64 dp gradient from `bgRaised` to transparent behind it):
   - **New chat** pill at the left: `accent` fill, 44 dp tall, 16 dp horizontal pad, `edit_square` icon plus "New
     chat", Row style in `onAccent`.
   - Avatar circle (40 dp; initials of the configured server host) at the right, which opens Settings.
   - While live, the live × (52 dp `closeFill`) stays visible at the screen's bottom right, outside the drawer, on
     the pushed content.

### 4.5 Live settings sheet (`shot13`, `shot12`, `shot10`, `shot09`)

- A floating sheet: inset 10 dp from the sides and bottom, radius 32, grab handle 36 × 4 (`textFaint` @ 60 %), 8 dp
  from the top.
- The title "Settings" is centred in Title style, 12 dp under the handle.
- Below it, one group card (outline 1 dp `outline`, radius 20, 12 dp side margin, `hairline` separators). Each row
  is 56 dp, with a 22 dp leading icon, Row label, `textMuted` value and a trailing chevron:
  - **Voice** (value: the voice name, ›). Pushes the voice page inside the sheet.
  - **Language** (value "Auto-detect", ⌄). Opens a dropdown popover **above** the row, max height 60 % of the
    screen, 40 dp items, ✓ on the selected item, scrollbar. Hidden until the server supports it (§9.6).
  - **Audio output** (value Speaker/Phone, ⌄). A popover anchored to the right half, two items. Shown only when
    `supportsSpeakerRoute` is true. It maps to `setSpeaker`.
- **Voice page:** the sheet height animates to 75 %. A round back button (36 dp glass) at the top left and the title
  "Choose a voice". Voices are grouped by language under Section headers, each group in an outlined card of 56 dp
  rows, with a ✓ on the selected voice. Tapping a voice selects it and plays a 2 s sample if one is available
  (later); otherwise it just selects. While live it shows "Applies from the next live session" in Label style
  under the title.
- The orb stays visible above the sheet and keeps reacting, as in the references. The sheet scrim is lighter while
  live (`scrim` × 0.6) so the orb remains visible.

### 4.6 Plus menu (`shot08`)

- A popover anchored 8 dp above the + button, left edge aligned with the pill's left edge, width 232, radius 24.
- Rows are 48 dp: a 32 dp circular chip (`surfaceHigh`) with an 18 dp icon, a 12 dp gap, and the label in Row style
  at 15.
- Items: **Camera**, **Photos**, **Files** (attachments, disabled with "Coming soon" until §9.5); **Think harder**
  (toggles effort High ↔ the previous value; ✓ when High); **More** › (opens Settings).
- In the reference, the keyboard opens together with the menu, because the field is focused. Hermes does the same
  when + is tapped while the field already has focus. Otherwise only the menu opens.

### 4.7 Effort slider (`shot07`, `shot06`)

- Tapping the gauge in the composer pill replaces the composer row in place (§6.7).
- The label (Title style, centred) reads "Instant effort", "Medium effort" or "High effort", 16 dp above the track.
- **Track:** `glass` fill, stadium, 52 tall. Three stops at 26 dp from each end and the centre, drawn as 6 dp
  `textMuted` dots.
- **Fill:** `accent`, from the left end to the thumb centre + 20 dp (stadium). It is not drawn at stop 0.
- **Thumb:** 40 dp `closeFill` disc. At stop 0 it has a 2 dp `accent` ring (shot07); at the other stops there is no
  ring (shot06).
- Interaction: drag or tap a stop; the slider snaps to stops.
- Dismissal: 1.8 s after the last interaction, a tap outside, or Back. The selected value persists
  (`settings.effort`).

---

## 5. Components

### 5.1 Orb (`HermesOrb`)

**Shape and look.** A perfect circle (no wobbling outline; the references' edge is crisp) showing a **daytime sky
seen through a round window**:

- The upper part is a vertical gradient from `orbSkyTop` (zenith) to `orbSkyLow` (horizon).
- The lower part is a **cloud bank** in `orbCloud`, shaded with `orbCloudShade` along the bottom and in the folds.
- The horizon between them is soft (feather ≈ 6 % of the diameter) and wavy. Its shape comes from 2D fbm noise, 4
  octaves.
- A 1 dp inner rim (`orbRim`) and an outer halo (`orbGlow`, dark theme only).

**Animated parameters**, all driven per frame by `OrbFrame`:

| Parameter | Meaning |
|---|---|
| `scale` | Diameter multiplier around the rest size |
| `cloudLevel` | Horizon height: 0 = clouds at the bottom, 1 = clouds fill the orb. Rest 0.55 (blue sky ≈ 45 %) |
| `tilt` | Horizon angle in radians |
| `roll` | Continuous rotation of the noise field |
| `drift` | Horizontal scroll of the noise, in diameters per second |
| `turbulence` | Amplitude of the horizon waves |
| `saturation` | 1 normal, 0.35 muted |
| `hue` | Error tint mix |

**Implementation.** A `FragmentProgram` (`shaders/orb.frag`, declared under `flutter: shaders:`) drawn into the orb's
square with a `CustomPainter`. Uniforms: size, time, and the parameters above. The orb gets its own
`RepaintBoundary`. The fallback (§7.3) is today's `OrbPainter`, retuned to this palette.

**Audio mapping.** Input is `AudioLevels` from `readLevels()`, normalised as today:
`e_raw = min(1, sqrt(level × 3.2))`. Smooth it per frame with attack τ = 60 ms and release τ = 350 ms. The video
shows a lag of about 80 ms and a decay from 180 to 144 over about 0.9 s.

### 5.2 Markdown renderer (`HermesMarkdown`)

Parse with `package:markdown` (GitHub-flavoured: tables, strikethrough, autolinks, task lists) and render with our
own widget builder. Do not use `flutter_markdown`, which is discontinued. The custom builder is needed for
per-block streaming, scrollable tables and the source pills. `flutter_markdown_plus` is an acceptable shortcut only
if it can meet §5.3.

| Element | Rendering |
|---|---|
| Paragraph | Body style, 14 dp gap |
| Bold | 600 weight |
| Italic | Real italic. Inter italic is synthetic unless the italic file is shipped; ship `Inter-Italic` variable |
| Heading | H1–H3 styles. 20 dp gap above, 8 dp below |
| Lists | Bullet `•` in `textMuted`, hanging indent 22 dp, item gap 6. Ordered lists use tabular numerals. Task lists use a 16 dp rounded checkbox glyph |
| Inline code | JetBrains Mono at 0.9 × body, `surfaceHigh` fill, radius 6, padding 2 × 5, same line height (`WidgetSpan` with baseline alignment) |
| Code block | `surface` fill, radius 16, 14 dp padding, horizontal scroll, header row (language label in Label style `textMuted`, Copy button at the right). Optional syntax colours from `package:highlight` with a muted 6-colour theme |
| Table | Horizontally scrollable `Table` in a `SingleChildScrollView(axis: horizontal)`. Header row in Table 600. Rows separated by a 1 dp `hairline`. Cells padded 10 × 12, column min width 112 dp, max 280, wrapping text. A right-edge fade of 24 dp shows when content overflows (shot02 clips at the edge) |
| Link | `text` colour with a 1 dp dotted underline in `textMuted`, plus a trailing ↗ glyph at 0.8 size. Opens in the external browser after a confirm sheet showing the host |
| Source pill | Hermes answers can contain links in "Sources:" lines. Render these as pills: `accentSoft` fill, stadium, 24 tall, a 14 dp generic globe glyph (no remote favicons; the web CSP forbids them and they leak requests) and the host name, Label style |
| Blockquote | 3 dp `outline` bar at the left, `textMuted` text |
| Rule | 1 dp `hairline`, 20 dp vertical margin |
| Images | Not loaded remotely (privacy and CSP). Show "[image: alt]" as a pill |

Selection: the whole assistant message sits in a `SelectionArea`.

### 5.3 Streaming text

- Parse incrementally. Split the accumulated text into blocks at blank lines outside code fences. Completed blocks
  are frozen widgets (`ValueKey(blockIndex)`); only the **last** block is re-parsed per chunk.
- **Trailing fade-in:** each newly arrived chunk's characters fade from 0 to 1 over **240 ms, linear**. This
  reproduces the lighter trailing words seen in the video.
  - Implementation: keep `(offset, arrivalTime)` marks for the last block and paint the trailing run as `TextSpan`s
    whose colour alpha comes from `now − arrival`.
  - Only the last ≤ 3 marks are animated. Older text is fully opaque.
  - The ticker runs only while any mark is younger than 240 ms.
- **Rate smoothing:** network chunks arrive in bursts, so reveal them at a capped rate of up to 90 characters per
  second, catching up linearly if the buffer is more than 400 characters behind. When the stream ends, flush within
  300 ms.
- Partial markdown, such as an unclosed `**` or code fence, is rendered as if closed. Never show raw markers
  flickering.

### 5.4 Thinking and working indicators

- **Text mode, before the first token:** a mini orb (20 dp, same shader, `roll` mode, `scale` breathing 0.92 ↔ 1.0,
  1.2 s period, easeInOut) at the start of the Hermes message slot, with the Label "Thinking…" in `textMuted` with
  a shimmer.
- **Hermes tool/task progress** (when the stream sends status events, §9.1): the label changes to the status
  ("Running a command", "Searching") and the elapsed seconds.
- **Shimmer:** a linear gradient band 40 % of the label width, `text` @ 100 % over `textMuted`, sweeping left to right
  in **1.6 s**, linear, repeating, with a 300 ms pause. Applied with `ShaderMask`.

### 5.5 Composer, text mode

- A pill (`surface` fill, stadium, min 52 dp tall), 16 dp from the screen sides, 12 dp above the safe bottom (or 8 dp
  above the keyboard).
- Contents, left to right:
  - **+** (40 dp tap area; 22 dp icon) opens the plus menu.
  - A text field with the placeholder "Ask Hermes" in `textFaint`, Body style. It expands from 1 to 6 lines, then
    scrolls.
  - A **mic** icon (40 dp, dictation via the platform keyboard's voice input; shown only when the field is empty and
    not on web).
  - The **action button** (40 dp circle, `closeFill` with a glyph in `bg` colour) morphs between three glyphs:

| State | Glyph | Action |
|---|---|---|
| Field empty, idle | Waveform | Start live voice |
| Field has text | ↑ arrow | Send |
| Reply streaming | ■ rounded square | Stop generating |

- Enter sends on desktop and web; Shift+Enter adds a newline. On mobile, the return key inserts a newline.
- The text is capped at 8000 characters (the bridge limit), with a counter shown from 7000.

### 5.6 Composer, live mode (`shot14`)

- **Pill:** glass, stadium, 52 tall, flexible width. It holds + (opens the plus menu), the placeholder "Ask Hermes"
  (tapping focuses a field; text typed while live is sent as a text turn to Hermes in the same thread, and its
  answer appears in the live canvas and docks the orb), and a trailing 32 dp gauge chip that opens the effort
  slider.
- **Mute:** a 52 dp glass circle.
  - Unmuted: `mic` glyph in `text`.
  - Muted: the fill becomes `closeFill` and the glyph `mic_off` in `bg`, so muted is unmistakable. The references
    show the muted glyph permanently because they were recorded muted.
- **End:** a 52 dp `closeFill` circle with × in `bg`.

### 5.7 Drawer behaviour

- **Push style:** opening translates the thread/live content to the right by the drawer width and slides the drawer
  in from the left. A `scrim` over the pushed content fades to 32 %. Tapping the content closes the drawer.
- Edge swipe from the left 20 dp opens it, and dragging follows the finger. Releasing past 40 % or with a velocity
  above 365 dp/s completes the move.
- On wide screens it is a permanent sidebar (no push).

### 5.8 Sheets, popovers and group cards

- All bottom sheets are floating (inset), with a radius of 32 and a grab handle.
- Height changes inside a sheet (the Settings → Voice push) animate the height and slide the content horizontally
  (§6.8).
- Group cards: 1 dp `outline`, radius 20, rows separated by `hairline` inset 0 (full width, as in the references).
- Popovers (dropdown, plus menu): radius 24, `sheet` + blur, max height 60 % of the screen, scrollbar 3 dp wide in
  `textFaint`.

### 5.9 Buttons and fields

- **Primary:** `accent` fill, stadium, 52 tall, Row 600, in `onAccent`.
- **Secondary:** `surface` fill, `text`.
- **Destructive:** `danger` text on `surface`.
- **Text fields:** `surface` fill, radius 16, no border. The focus ring is 2 dp `accent`. The helper/error line is
  Label style.

### 5.10 Banners and toasts

- **Toast:** a floating capsule at the top under the app bar, `sheet` + blur, radius 20, 12 × 16 padding. It has a
  leading 18 dp icon in a state colour, Body 15 text, an optional action (accent text button) and an optional ×.
  Auto-dismiss after 4 s unless it has an action. At most one is visible; newer ones replace older ones. It is a
  live region.
- **Inline error in the thread:** under a failed Hermes message, `danger` Label "Couldn't get a reply. Retry"
  (tappable).
- **Persistent notice** (limited background support): a quiet `surface` capsule below the app bar while live, with
  an info icon in `warning`.

### 5.11 Voice list

The bridge accepts these voices (`kVoices`): cove, juniper, sol, ember, vale, maple, spruce, breeze, arbor, aube and
bubbie. The bridge does not provide language or locale metadata.

- Show one group, "Voices", in the card style, with names title-cased.
- If per-locale grouping is wanted later, add `{id, label, group}` metadata in `config.dart` once the locale of each
  voice is confirmed on the server. **Don't guess** the locales.

---

## 6. Motion

Global rules:

- All durations are scaled by 0 when reduce motion is on (§8.2), except where an alternative is given.
- Use `AnimationController`s driven by the ticker. Never use `Timer`-driven animation.
- Springs use `SpringDescription.withDampingRatio(mass: 1, stiffness: k, ratio: ζ)`.
- Named curves:
  - **emphasizedDecel** = `Cubic(0.05, 0.7, 0.1, 1.0)`
  - **standard** = `Cubic(0.2, 0.0, 0.0, 1.0)`
  - **exit** = `Cubic(0.3, 0.0, 0.8, 0.15)`

### 6.1 Orb per state

The rest diameter `D` is `orbCentered`. `scale` multiplies `D`.

| State | scale | cloudLevel | tilt / roll | drift (D/s) | turbulence | Other |
|---|---|---|---|---|---|---|
| **connecting** | 0.86 + breathing ±0.03 (sine, period 1.6 s) | 0.50 | roll slow 15°/s | 0.03 | 0.4 | saturation 0.7 → 1 when live (400 ms) |
| **listening** (idle) | 0.80 (the rest size measured in the video, 144/180) + breathing ±0.012 (period 4.2 s) | 0.55 | tilt drifts ±6° (period 9 s) | 0.035 | 0.5 | |
| **user speaking** (input level, `userSpeaking` or `e_in > 0.08`) | 0.80 + 0.06·e_in | 0.55 + 0.05·e_in | tilt follows e_in up to ±18° (alternating direction per utterance) | 0.035 + 0.06·e_in | 0.5 + 0.8·e_in | |
| **assistant speaking** (output level) | 0.80 + 0.22·e_out (180/144 at peak ≈ 1.0) | 0.55 → 0.82 eased by e_out (clouds rise, about 80 % cover as in the video) | tilt → 0 | 0.05 + 0.08·e_out | 0.6 + 0.6·e_out | brightness +6 %·e_out |
| **thinking / working** (`activeTasks > 0`, or a text turn awaiting its first token while live) | 0.80 | 0.50 | **roll 45°/s** (the video's 35–40° in 0.75 s) | 0.05 | 0.7 | |
| **muted** | 0.76 | 0.55 | frozen tilt | 0.015 | 0.3 | saturation → 0.35 over 250 ms; input reaction off; output reaction still on |
| **ended** | → 0 | | | | | opacity → 0, 220 ms, exit curve; then live mode closes (§6.4) |
| **error** | 0.78 | 0.45 | none | 0.01 | 0.2 | hue → error over 300 ms; a single 2 % "shudder" (scale 0.78 → 0.76 → 0.78 over 240 ms) on entry |

State changes cross-fade parameters with a spring (stiffness 120, ζ = 1.0, ≈ 450 ms). The audio-driven terms use the
attack/release smoothing from §5.1, not the spring.

Level polling goes from 120 ms to **50 ms while live** (`CallTimings.levelPoll`). The painter interpolates between
samples per frame, so movement stays smooth at 60/120 Hz. Without level data (`AudioLevels.unknown`), keep the
breathing only and **never fake speech motion**. This matches today's rule.

### 6.2 Orb centre ↔ dock

- **Dock** is triggered by the first rendered chunk of rich content in the live canvas.
  - Properties: `translateY` (centre to dock position), `scale` (1 → 0.41), the halo shrinking proportionally.
  - Measured: **≈ 260 ms**, nearly linear with a soft landing. Use **260 ms, `Cubic(0.3, 0.0, 0.2, 1.0)`**.
  - The text column starts its first-chunk fade **80 ms** after the dock starts.
  - No overshoot was visible. An optional 2 % settle (spring stiffness 600, ζ = 0.75) can be tried on device.
- **Undock** is triggered when the live canvas is cleared: the user swipes the content away, or a new assistant
  speaking turn begins more than 3 s after the last content and the user has scrolled to the top. It reverses over
  **320 ms**, standard curve, and the text fades out over 160 ms first.
- **Status label under the docked orb:** it fades in with `translateY` +4 → 0 over **200 ms**, emphasizedDecel. At
  the same time the orb lifts by `labelHeight + 4` (≈ 8 dp, measured) over 200 ms, standard. Hiding reverses this
  over 160 ms.

### 6.3 Text streaming and message entry

- **Stream chunk:** 240 ms linear opacity per chunk (§5.3).
- **User bubble on send:**
  - The composer text is cleared instantly.
  - The bubble enters with opacity 0 → 1, `translateY` +12 → 0 and scale 0.97 → 1 (alignment bottom-right), over
    **220 ms**, emphasizedDecel.
  - The list scrolls to the bottom (300 ms, standard) if the user was within 160 dp of it.
- **Hermes reply slot:** the mini orb indicator fades in over 150 ms. On the first token it cross-fades to the text,
  150 ms.
- **Action row:** fades in over 200 ms, 150 ms after the stream ends.
- **Live transcript import on exit:** new messages enter with the user-bubble animation, **staggered 30 ms**, at most
  6 animated; the rest appear without animation.

### 6.4 Entering and leaving live mode

**Enter** (tap the live button):

| Time | What animates |
|---|---|
| 0 ms | Haptic `lightImpact`. The action button's waveform glyph scales 1 → 0.9 → 1 (120 ms). |
| 0–200 ms | Thread content opacity 1 → 0 with scale 1 → 0.98, exit curve. The app-bar title fades out. |
| 0–420 ms | **Orb hero:** it starts at the action button's rect (40 dp, inside the pill) and flies to `orbCentered`, growing to 0.86·D (the connecting state), emphasizedDecel. This is a Hero-like `RectTween` on one overlay layer, not a route `Hero`. |
| 80–320 ms | The composer morphs. The field collapses to the placeholder pill: its width animates from full to `width − 2·52 − 2·8 − 32` and its fill switches from `surface` to `glass`. **Mute** and **End** scale 0.6 → 1 and fade in, staggered 40 ms (mute first), 200 ms each, with an easeOutBack-style `Cubic(0.34, 1.3, 0.64, 1)` overshoot of at most 4 %. |
| 200 ms | The "Connecting…" label fades in under the orb (200 ms). |
| On `session.started` | The orb goes to the listening state (§6.1 spring). Haptic `lightImpact`. Optional "connected" sound (§7.5). |

**Leave** (× or a remote end):

| Time | What animates |
|---|---|
| 0 ms | Haptic `mediumImpact`. The live canvas text fades out over 160 ms. |
| 0–300 ms | The orb flies back into the action button rect while shrinking, exit curve then standard. Over the last 80 ms it cross-fades into the waveform glyph. |
| 60–260 ms | Mute and End scale to 0.6 and fade out (reverse stagger: end first). The pill animates back to the full-width text composer and to the `surface` fill. |
| 120–340 ms | Thread content opacity 0 → 1 with scale 0.98 → 1, emphasizedDecel. Then the transcript import (§6.3). |

Call teardown starts immediately at 0 ms, as today; the animation never delays the hang-up.

### 6.5 Drawer

- **Open:** 300 ms, emphasizedDecel. The drawer `translateX` goes from −W to 0, the content `translateX` from 0 to
  W, and the scrim from 0 to 32 %.
- **Close:** 240 ms, standard.
- **Drag:** follows the finger 1:1. Release fling uses a spring (stiffness 500, ζ = 0.9).

### 6.6 Sheets and popovers

- **Sheet present:** `translateY` from 100 % to 0 with a spring (stiffness 380, ζ = 0.86, ≈ 380 ms). The scrim fades
  in over 250 ms, standard.
- **Sheet dismiss:** 220 ms, exit curve. It can be swiped down with the drag following the finger; dismissal happens
  past 30 % or above 700 dp/s.
- **Popover open:** scale 0.92 → 1 from its anchor corner plus opacity 0 → 1, **180 ms**, emphasizedDecel. The
  chevron rotates 0 → 180° over 180 ms.
- **Popover close:** 120 ms, opacity only.
- **Plus menu:** the same as a popover, anchored bottom-left. Rows stagger 20 ms, translateY +6 → 0.

### 6.7 Effort slider

- **Composer → slider:** the composer row fades out over 120 ms. The track grows from the gauge chip's rect to its
  full rect over **260 ms**, emphasizedDecel. The label fades in over 160 ms, starting 100 ms later.
- **Thumb between stops:** spring (stiffness 500, ζ = 0.8). The fill width is tied to the thumb position. The label
  cross-fades over 150 ms. The ring at stop 0 fades over 120 ms. Haptic `selectionClick` at each stop crossed.
- **Slider → composer:** reverse, 220 ms.

### 6.8 Sheet inner navigation (Settings → Choose a voice)

- The sheet height animates with `AnimatedSize` (300 ms, emphasizedDecel).
- The pages slide horizontally: incoming from +24 % to 0 with opacity 0 → 1, outgoing from 0 to −12 % with opacity
  1 → 0, 280 ms, standard.
- The back button reverses this.

### 6.9 Composer micro-motion

- **Action button glyph morph** (waveform ↔ arrow ↔ stop): cross-fade + scale 0.6 → 1 (incoming) and 1 → 0.6
  (outgoing), **160 ms**, standard. The button's fill does not change.
- **Field height growth:** `AnimatedSize` 120 ms, easeOut. The list keeps its bottom anchored.
- **Mic button hide/show** when text appears: width 40 → 0 + fade, 140 ms.
- **Error shake** (onboarding key field): `translateX` 0, −6, 6, −4, 4, 0 over 320 ms.

### 6.10 Frame-rate targets and costs

- Target 60 fps everywhere, and **120 Hz** where the display allows.
  - iOS: set `CADisableMinimumFrameDurationOnPhone = true` in `ios/Runner/Info.plist`.
  - Android: Flutter follows the display mode. On devices that default to 60 Hz, add a preferred-refresh request
    through a small platform-channel call in `MainActivity`
    (`window.attributes.preferredDisplayModeId` = highest refresh at the current resolution), live mode only, to
    limit the power cost.
- See §7.3 for costly effects.

---

## 7. Feedback, performance and fallbacks

### 7.1 Haptics (mobile only; follows the "Haptics" setting)

| Event | Haptic |
|---|---|
| Live start tap, `session.started` | `lightImpact` |
| End tap | `mediumImpact` |
| Mute toggle | `selectionClick` |
| Effort stop | `selectionClick` |
| Message sent | `lightImpact` |
| Error / usage limit | `heavyImpact` once |
| Long-press menu open | `mediumImpact` |

### 7.2 Sounds (follows the "Sounds" setting, default on, live mode only)

- **Connected:** two soft rising sine tones, 120 ms total, −18 dBFS.
- **Ended:** one falling tone, 140 ms.
- **Muted / unmuted:** no sound (the haptic is enough).

The reference video's audio track is the assistant's voice, so its cue sounds cannot be determined. These cues are
our own and must be short so they never overlap the model's first words. Play them through the same audio session.
On iOS, check that CallKit does not duck them; skip them if `background == native` on iOS when they would interrupt
CallKit's own sounds.

### 7.3 Costly effects and cheaper fallbacks

| Effect | Cost | Fallback (auto when `FrameTiming` shows more than 5 % janky frames over 3 s, on web without the skwasm renderer, or on Android API < 29) |
|---|---|---|
| `BackdropFilter` blur on glass buttons, pill, sheets | High on Android GPUs and web; one save layer per blurred widget | Opaque `surface` at 92 % / `sheet` at 98 %, no blur. Never blur the full screen; blur only inside the control's clip |
| Orb fragment shader | Low to medium (only the orb's pixels, about 600 × 600 px at 3×) | Today's `CustomPainter` orb (gradients plus blurred circles), with `MaskFilter.blur` limited to 3 clouds |
| Live canvas `ShaderMask` fade | Medium (a save layer over the content) | A `bg` gradient overlay (`DecoratedBox`) above the text instead of a mask |
| Per-chunk trailing fade | Low; only the last block repaints | Without animation: appear immediately |
| Shimmer label | Low | A static `textMuted` label |
| Orb halo | Low | Omitted |

The orb, the live canvas text and the composer each sit in their own `RepaintBoundary`. Level changes repaint only
the orb (as today: `ValueListenableBuilder` only around the orb, not the whole screen).

---

## 8. Accessibility

### 8.1 Contrast

Every text token pair in §3.1 meets WCAG AA (4.5:1) at body sizes; the ratios are listed there. The placeholder
(`textFaint` on `surface`) is 5.2:1. Glass controls keep their glyph at `text` over a minimum effective background
of `#1C1C1E`-equivalent: add the fallback fill whenever the content under the glass is bright, for example when the
orb is behind the pill during the dock animation. Focus rings are 2 dp `accent` with a 2 dp offset, visible on both
themes.

### 8.2 Reduced motion

When `MediaQuery.disableAnimations` is true or the app's "Reduce motion" setting is on:

- The orb is a static gradient sphere at rest scale with no drift or roll. Audio reaction becomes an **outer ring**
  (2 dp, `orbSkyLow`) whose opacity follows e_out/e_in. This keeps state feedback without movement.
- The dock is a 120 ms cross-fade between the two positions, with no travel.
- Live mode entry and exit are 150 ms cross-fades.
- The drawer and sheets keep their position animations but at 150 ms with a linear curve. The platform convention
  is that spatial transitions remain, only shortened.
- Streaming text appears without the fade. The shimmer becomes static. Stagger is 0.

### 8.3 Text scaling

- Support a text scale up to 2.0. The composer grows in height. The live composer row wraps: from a scale of 1.6 the
  pill goes full-width on its own line, with mute and end beneath it, right-aligned.
- Drawer rows grow in height and do not truncate below 1.3.
- Table cells wrap.
- The orb does not scale with text. The status label does.

### 8.4 Screen reader labels

| Control | Label |
|---|---|
| ≡ | "Chats" |
| Sliders | "Voice settings" (live), "Chat options" (text) |
| + | "Add" |
| Gauge | "Reply effort: Medium" (with an adjustable action that changes the stop) |
| Mute | "Mute microphone" / "Unmute microphone", toggled |
| End | "End live voice" |
| Action button | "Start live voice", "Send message" or "Stop reply" |

- The orb is excluded from semantics.
- The status label is a live region, announcing state changes only (not every level change).
- Messages are grouped: "You said: …" and "Hermes: …".
- Streaming replies announce once when complete ("Hermes replied"), not per token.
- Task cards: "Task, working, 12 seconds".
- Sheets have a header and a named dismiss action. Popovers trap focus and return focus to their anchor.

Keyboard shortcuts on desktop and web:

| Key | Action |
|---|---|
| M | Mute while live |
| Esc | Close the top popover, sheet or drawer, otherwise end live |
| Ctrl/Cmd+K | Search chats |
| Ctrl/Cmd+Shift+O | New chat |
| Ctrl/Cmd+Shift+L | Toggle live |

- `T` is retired: the transcript is now the thread.
- Every interactive element has a hit target of at least 48 dp.

---

## 9. Server-side needs (bridge `server/gpt-live-bridge.py`)

The bridge is the only thing the app talks to (over HTTPS). Hermes' OpenAI-compatible API (model `hermes-agent`) is
reachable only from the bridge's host, and its key stays in `bridge.env` on the server. **This section is the
original plan; all of it has since been implemented, and `server/API.md` is the current contract.**

1. **`POST /api/chat` (SSE streaming chat proxy).**
   - Request: Bearer `LIVE_PAGE_KEY`; body `{conversation_id?, message: {text}, effort?: "instant"|"medium"|"high",
     client_msg_id}`.
   - The bridge loads the conversation history (item 2), appends the message, and calls
     `HERMES_API_URL/chat/completions` with `stream: true`.
   - Response: `text/event-stream` with these events:
     - `event: meta {conversation_id, message_id}`
     - `event: delta {text}`
     - `event: status {label}`, if Hermes exposes tool progress; otherwise none
     - `event: done {usage?}`
     - `event: error {code, message}`
   - It persists the final assistant message.
   - A client disconnect cancels the upstream request.
   - Limits: at most 2 concurrent chats per key (429 `busy`), 8000 characters per message, 900 s total timeout,
     and a keep-alive comment every 15 s (Tailscale Serve and proxies may close idle streams).
   - **Unverified:** whether Hermes' API server supports `stream: true` with incremental deltas (Open WebUI's use of
     it suggests yes). If not, the bridge must fake the stream by sending the final text as one `delta`, which the
     client's rate smoothing (§5.3) still animates.
2. **Conversation storage.** SQLite at `<BRIDGE_DATA_DIR>/chats.sqlite`, covered by the data directory's
   backups.
   - Tables: `conversations(id, title, pinned, created, updated, kind)` and
     `messages(id, conversation_id, role, text, source{text|voice|task}, created, meta_json)`.
   - Endpoints:
     - `GET /api/conversations?cursor=`
     - `POST /api/conversations`
     - `PATCH /api/conversations/{id}` (title, pinned)
     - `DELETE /api/conversations/{id}`
     - `GET /api/conversations/{id}/messages?before=`
     - `GET /api/conversations/search?q=` (SQLite FTS5)
   - Storage is on the server rather than only on the device because the same key is used on phone, desktop and
     web, and the web build has no durable local database.
3. **Live sessions tied to a conversation.**
   - `POST /api/session` accepts `conversation_id`. The bridge seeds `DirectSession.history` from the thread's last 8
     messages, so delegated Hermes tasks see the typed context.
   - New `POST /api/conversations/{id}/live-transcript` takes `[{role, text, created}]`. The client posts the
     finished turns at the end of the call, because the bridge never sees the voice transcripts. Task results are
     stored by the bridge itself when a job completes.
   - Optionally, the client sends `session.context.append` with a short summary of the typed thread at
     `session.started`. That is one of the client events GPT-Live accepts.
4. **Effort.** Pass `effort` through to Hermes (for example as `reasoning_effort`) only if Hermes' API honours it.
   Otherwise accept and ignore it, and the app hides the slider when `/healthz` capabilities say `effort: false`
   (item 9).
5. **Attachments** (Camera, Photos, Files). This needs an upload endpoint and a check of what Hermes accepts (image
   parts in `messages`, file paths in its workspace). The app ships these items disabled until then.
6. **Live language.** `thread/realtime/start` has no language parameter in the current bridge. Whether GPT-Live-1
   supports a forced language is unknown. Until it is verified, hide the Language row. A fallback is a persona-prompt
   line ("Speak in X"), which would need testing.
7. **Usage-limit errors.** Today every start failure becomes `502 could not start GPT-Live`. The bridge should map
   the Codex/GPT-Live errors that mean usage or rate limits to `429 {"error":"usage_limit","retry_after_s":N}`, and
   a revoked login to `502 {"error":"login_expired"}`. Data-channel `error` events with limit codes keep arriving in
   the client and are classified there (§10, live error states).
8. **Titles.** After the first assistant reply, the bridge asks Hermes for a 2–5 word title (non-streaming, 20 s
   budget) and stores it. Without one the title is the first 40 characters of the user's message.
9. **Capabilities.** Extend `GET /healthz`, or add `GET /api/capabilities` (authenticated), with
   `{chat: bool, history: bool, effort: bool, attachments: bool, language: bool}`. The app shows features based on
   it, so a new app keeps working against an old bridge (chat falls back to "Live only").
10. **Web client streaming.** `package:http`'s `BrowserClient` buffers whole responses, so SSE would not stream on
    web. The app needs `package:fetch_client` (or `package:web` fetch with `ReadableStream`) on web, and `IOClient`
    streaming on native. This is client work, noted here because it affects the endpoint design: plain `fetch`
    streaming with `Authorization`, no `EventSource`, since `EventSource` cannot send headers. The CSP
    `connect-src 'self'` already allows it.

---

## 10. Gap analysis: current app vs this spec

### Per screen

| Area | Today | Spec | Gap |
|---|---|---|---|
| App structure | `HermesApp` → `CallScreen` or `OnboardingScreen`. Voice-only. | `ChatShell` with drawer, thread, composer and live overlay | New shell, routing and controllers |
| **Text chat** | **None.** There is no text input anywhere; the only "conversation" is the live transcript sheet (`conversation.dart`), cleared on every call start | Full text chat with streaming, markdown and history | Entirely new: models, API client, controller, UI. Needs server items 1–2 |
| History / drawer | None. The transcript is in memory and lost at the next call | Server-stored conversations, drawer list, search, pin, rename | New. Needs server item 2 |
| Live mode | A separate call screen: centred orb, title text ("Listening", "Hermes is speaking"), 72 dp labelled round buttons (Mute, Speaker, Transcript, End in danger red), "Start / Try again" pill, live caption line, task chip | An overlay in the thread; centred ↔ docked orb; rich task results in the canvas; glass pill + mute + light ×; status label only for connecting, muted, working and errors | Rebuild the UI. Keep `CallController` logic, add the dock state and the result feed |
| Orb | `CustomPainter` blue sphere with a wobbly edge, blurred cloud circles, specular highlight; modes idle/connecting/listening/speaking/muted/error; level-driven energy (attack 14, release 4 /s) | Shader sky-window orb with a crisp edge, cloud bank/horizon model, explicit per-state parameters, user-speaking and thinking states, docked size, 50 ms level polling | New shader and parameter model. The current painter becomes the fallback. Add `OrbMode.userSpeaking` and `thinking` |
| Call states | connecting (with steps), live, failed (`error` string), muted, notice banner | Adds thinking/working, usage limit, login expired, reconnecting copy | Add an error classification in `CallController._describe` and data-channel `error` handling |
| Transcript / tasks | A bottom sheet with Transcript and Tasks tabs; bubbles with borders; `TaskCard` | Messages in the thread, task cards inline; the live canvas shows results | Replace `ConversationPanel`; reuse the `TaskCard` logic restyled |
| Live settings | Voice chips and theme on a full-screen Settings page | A floating sheet over the live orb: Voice (pushes a picker), Language (hidden until supported), Audio output dropdown | New sheet. Move the speaker toggle there from the call controls |
| Effort / plus menu | None | Plus menu and effort slider | New UI. Effort needs server item 4 |
| Settings page | Material ListView with ChoiceChips, SegmentedButton, switches | Grouped-card restyle, plus Effort, Sounds and Haptics | Restyle and new prefs |
| Onboarding | Functional; "Hermes" header, fields, verify | Restyle with an orb and new tokens; keep the logic | Restyle only |
| Theme | Off-white light default; `HermesColors` with 13 colours; Roboto on web only; M3 defaults | Dark default; `HermesTokens` (§3); Inter + JetBrains Mono everywhere | Replace the theme. Add fonts and licences |
| Markdown | None (plain `Text`) | Full GFM renderer with streaming | New (`package:markdown`) |
| Banners | `_Banners`: bordered boxes under the top bar | Floating toast and inline errors | New toast component |
| Haptics / sounds | None | §7.1–7.2 | New, small |
| Accessibility | Good basics: semantics labels, live regions, shortcuts M/Esc/T, reduce-motion setting | Extended labels, reduced-motion alternatives, text scale 2.0 layout, new shortcuts | Incremental |
| 120 Hz | Not configured | Info.plist key, Android preferred mode | Small native change |

### Implementation plan (ordered, each step testable on its own)

The client steps (C) assume the server endpoints are faked in tests (`test/fakes.dart` already has the patterns). The
server steps (S) can run in parallel. Run `flutter analyze` and `flutter test` after every step.

**C1. Tokens and fonts.**
- Add `lib/src/ui/tokens.dart` (`HermesTokens`, dark and light).
- Rewrite `lib/src/ui/theme.dart` to use it.
- Add Inter and JetBrains Mono to `assets/fonts/` with their OFL texts, update `pubspec.yaml` and register the
  licences in `lib/main.dart`.
- Change the default theme to Dark in `settings.dart`.
- Test: theme golden of a sample card in both themes, and a licence-registry test.

**C2. Common components.**
- Add `lib/src/ui/common/glass_button.dart`, `common/toast.dart`, `common/group_card.dart`,
  `common/floating_sheet.dart` (inset sheet with an inner navigator and `AnimatedSize`) and `common/popover.dart`.
- Add a motion constants file, `lib/src/ui/motion.dart` (curves, durations, springs, `reduceMotion(context)`).
- Test: widget tests for the semantics labels, popover focus return and sheet dismissal.

**C3. Orb v2.**
- Add `shaders/orb.frag` and `lib/src/ui/orb/orb.dart` (`HermesOrb`, `OrbParams`, the state → params table from
  §6.1, a spring cross-fade, and audio smoothing at τ 60/350 ms).
- Move today's painter to `lib/src/ui/orb/orb_fallback.dart`, with automatic fallback selection.
- Add `OrbMode.userSpeaking` and `OrbMode.thinking`.
- Change `CallTimings.levelPoll` to 50 ms while live.
- Test: unit-test the param mapping and smoothing with fake time; a golden per state with fixed time; and a check
  that no speech motion happens when levels are unknown.

**C4. Markdown and streaming text.**
- Add `lib/src/ui/markdown/hermes_markdown.dart`, `markdown/code_block.dart`, `markdown/md_table.dart`,
  `markdown/source_pill.dart` and `markdown/streaming_text.dart` (block freezing, trailing fade, rate smoothing).
- Add `markdown` (and optionally `highlight`) to `pubspec.yaml`.
- Test: golden tests for each element; a stream test that feeds chunks and asserts that only the last block
  rebuilds; and unclosed-marker cases.

**C5. Chat data layer.**
- Add `lib/src/chat/models.dart` (Conversation, ChatMessage with source text/voice/task and a status of
  sending/streaming/done/failed/stopped).
- Add `lib/src/chat/chat_api.dart`: SSE parsing for `/api/chat` and the conversation REST calls, using `IOClient`
  streaming on native and `fetch_client` on web, with a `BridgeException` mapping.
- Add `lib/src/chat/chat_controller.dart` (send, stop via cancel, retry, optimistic user message, error states) and
  `lib/src/chat/conversations_controller.dart` (list, paging, search, pin, rename, delete, current id).
- Extend `bridge_api.dart` with `capabilities()`.
- Test: fake `http.Client` streaming SSE; cancel mid-stream; 401/429/usage_limit mapping; a capabilities fallback to
  "Live only".

**C6. Composer.**
- Add `lib/src/ui/composer/composer.dart` (text mode, the expanding field, the 3-state action button morph),
  `composer/live_composer.dart`, `composer/plus_menu.dart` and `composer/effort_slider.dart`.
- Add `settings.effort`, `settings.sounds` and `settings.haptics` to `settings.dart`.
- Test: action-button state machine; Enter/Shift+Enter; 8000-character cap; effort snapping and semantics
  adjustable actions.

**C7. Thread view.**
- Add `lib/src/ui/thread/thread_view.dart`, `thread/user_bubble.dart`, `thread/assistant_message.dart` (markdown,
  action row), `thread/thinking_indicator.dart` (mini orb and shimmer) and `thread/task_card.dart` (moved from
  `conversation.dart`).
- Add the empty state with suggestion chips.
- Test: follow-scroll rule, entry animation (with reduced motion: none), semantics grouping.

**C8. Shell and drawer.**
- Add `lib/src/ui/shell/chat_shell.dart` (push drawer, app bar, wide-layout sidebar) and
  `lib/src/ui/drawer/chat_drawer.dart`.
- Change `lib/src/app.dart` so the home becomes `ChatShell`.
- Add shortcuts.
- Test: drawer drag thresholds; switching chats while live asks for confirmation; wide layout at 900 dp.

**C9. Live overlay.**
- Add `lib/src/ui/live/live_overlay.dart` (canvas, dock state machine, status label, hero orb enter/exit) and
  `live/live_settings_sheet.dart` (Voice push page, Audio output dropdown, Language hidden by capability).
- Wire everything to the existing `CallController`. Add to it:
  - `liveResults`: a stream of task-result markdown for the canvas;
  - an `onEnded` transcript snapshot for import;
  - error classification (`usageLimit`, `loginExpired`, `network`);
  - a typed-text-while-live path that calls `ChatController` and feeds the canvas.
- Remove `lib/src/ui/call_screen.dart` and `lib/src/ui/conversation.dart` once parity tests pass.
- Test: the existing `call_controller_test.dart` stays green; new widget tests for state → label/orb mode, dock on
  first result, End during connecting returns immediately, and transcript import on exit.

**C10. Settings and onboarding restyle.**
- Restyle `lib/src/ui/settings_screen.dart` (grouped cards, effort, sounds, haptics; voice opens the shared picker)
  and `lib/src/ui/onboarding_screen.dart` (orb header, error shake).
- Test: the existing `widget_test.dart` flows are updated and green.

**C11. Haptics, sounds and 120 Hz.**
- Add `lib/src/ui/feedback.dart` (haptics and tones behind settings) and two short tone assets (generated; no
  third-party sounds).
- Add `CADisableMinimumFrameDurationOnPhone` to `ios/Runner/Info.plist`, and the preferred display mode in
  `android/app/src/main/kotlin/.../MainActivity.kt`, live-only.
- Test: the settings toggles gate the calls (a fake feedback sink).

**C12. Performance pass.**
- Profile-mode run on the Android device: `FrameTiming` capture for live speaking, dock and drawer drag.
- Verify the blur fallback triggers.
- Web build with `--no-web-resources-cdn` and check that the shader works under the CanvasKit/skwasm build.
- Update `tool/device_qa.py` checks and `docs/hermes-live-device-checks.md`.

**Server steps (separate change in `infra/core/gpt-live-bridge/`):**

- **S1.** Capabilities endpoint and usage-limit/login error mapping (§9.7, §9.9), with tests in `test_app_routes.py`.
- **S2.** SQLite storage and the conversation REST endpoints (§9.2), with tests.
- **S3.** `/api/chat` SSE proxy (§9.1). First verify Hermes streaming with a curl run on the bridge host. Include keep-alives,
  cancellation and the concurrency cap.
- **S4.** Live session ↔ conversation link and the transcript import endpoint (§9.3).
- **S5.** Titles (§9.8). Then effort pass-through (§9.4) once Hermes support is known.
- Later: attachments (§9.5) and live language (§9.6), each after its own feasibility check.

The client can ship C1–C4 and C9 against today's bridge (live-only, with the capabilities fallback). Text chat (C5–C8)
needs S1–S3 deployed.

---

## 11. Open points (could not be determined from the references)

- **Exact colours:** the photos are off-screen camera shots, warm-shifted and overexposed, so surface hexes are
  designed, not measured. The orb palette is matched to its *relative* look (saturated blue sky over warm-white
  clouds).
- **User-speaking vs thinking orb:** the 5.0–6.8 s roll happens before an answer, while the audio track shows low
  activity. This spec assigns the roll to thinking and the tilt to user speech. It needs on-device tuning.
- **Dock easing:** the dock lasts only 6–7 frames at 24 fps, so the exact curve (and whether there is a tiny
  overshoot) cannot be resolved. Some frames also show camera motion blur (ghosting) that is not part of the UI.
- **Undock behaviour, sheet/drawer/popover/slider timing, haptics and sounds** are not in the video. The values above
  are designed to fit the measured motion and platform conventions.
- **Error states, including the usage limit,** do not appear in any reference. Their visuals here are designed.
- **Voice locales:** the reference voice picker groups voices by language, but the bridge's voice set has no locale
  metadata, so grouping is deferred.
- **Physical sizes** come from perspective-skewed photos; dp values are within about ±10 %. Validate them on the
  device in C12.
