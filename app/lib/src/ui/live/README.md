# Live mode

The live voice overlay drawn on top of the thread (redesign spec §2.3, §4.1, §4.2, §6.2, §6.4). The shell owns
entering and leaving live mode, the composer row and the app bar. Everything between them lives here.

## Entry point

```dart
import '../live/live_overlay.dart';

LiveOverlay(
  key: overlayKey,               // GlobalKey<LiveOverlayState> (optional)
  call: call,                    // CallController
  chat: chat,                    // ChatController (typed turns during the call)
  enter: liveAnimation,          // 0 → 1 enter (420 ms), 1 → 0 leave (340 ms)
  since: liveSince,              // session start; older tasks/messages are ignored
  topInset: appBarBottom,        // panel text starts 8 dp under this
  composerTop: composerTop,      // in the overlay's coordinates
  heroRect: actionButtonRect,    // orb flies from/to here; null = fade
  onRetry: () { call.end(); call.start(); },
  onOpenSite: null,              // optional; defaults to liveSiteOpener (in-app browser)
  blockBuilder: null,            // optional hook for hermes-ui blocks (see below)
)
```

Place it in a `Positioned.fill` above the thread and below the app bar and composer. This is what
`chat_shell.dart` does today, unchanged from before the move. `LiveOverlayState` exposes `docked`, `shown`,
`work` (what the status line shows), `newer` (a result waiting behind the "New result" pill), `choreographer`,
`conversationOpen`, `showConversation()`, `showNewer()`, `clear()` (hide the panel) and `expand(contentId)`.

`live_settings_sheet.dart` (`showLiveSettings`) moved here too, with the same API.

## Files

| File | What |
|---|---|
| `live_overlay.dart` | `LiveOverlay`, plus `liveOrbState` / `liveStatus` (call → orb state, status label) |
| `live_content.dart` | `LiveContent` (what the panel shows), `liveContentFor` / `liveContentById`, `extractSites`, `liveNow` (test clock) |
| `live_transcript.dart` | Live conversation: spoken transcript, typed turns and tasks in time order |
| `live_panel.dart` | `LivePanel`: header, markdown (`StreamingMarkdown` / `HermesMarkdown`), source cards, bottom fade, follow-scroll |
| `live_link_cards.dart` | `LiveSiteCards` / `LiveSiteCard` (live), `LiveSourcesPill` + `showLiveSourcesSheet` (chat replies), `openSiteInApp`, `liveSiteOpener` |
| `live_work.dart` | `liveWorkFrom` (running/failed work since the session start) and `LiveWorkStrip`, the one-line status |
| `live_activity.dart` | Older `LiveActivity` card tracker, kept for its tests; not rendered |

## Behaviour

- **Orb choreography** (`../orb/orb_choreography.dart`): two poses. *Centred* is `orbCentered` with its centre at
  46 % of the safe height, pushed down only if the task cards would reach the app bar. *Docked* is 0.41 ×, 40 dp
  above the composer, and lifts 8 dp while a status label shows. The poses are joined by critically damped springs
  (dock k = 500, ≈ 260 ms; undock k = 330, ≈ 320 ms; other moves k = 260), which keep their velocity when
  retargeted. On top of that come nudges: the user speaking pulls the orb towards the mic by 5 % of D and 2.5 % of D
  to the side (alternating per utterance), and Hermes speaking lifts it by 3 %. Talking over Hermes makes it flinch
  (a downward kick plus a ≈ 3 % squash). The orb's own ticker steps the choreographer (`OrbEngine.choreographer`).
  A `Flow` places the orb, label and cards at paint time, so movement repaints only and never rebuilds or relayouts.
  With reduced motion poses snap, with no nudges or flinch, and the panel cross-fades in 120 ms.
- **Touch:** the orb follows a finger immediately with bounded resistance, a slight stretch and cloud tilt.
  Releasing it returns to rest with a damped spring. Pulling down by 64 dp (or a short downward fling) reveals
  the live conversation; pulling up on the docked orb hides it. Tapping the centred orb also reveals the transcript.
  Reduced motion keeps the gesture and transcript, with no deformation or travel.
- **Conversation:** uses the existing call transcript, including partial transcription, plus typed messages
  and delegated tasks from the current session. It follows new text until the reader scrolls up. Voice keeps
  running while it is open.
- **Panel:** opens only for a result: a delegated task's answer, or a typed reply once its answer text starts. A
  running, failed or handed-off task never opens it or docks the orb. A newer result that arrives while the reader
  is scrolled into the current one waits behind a "New result" pill. It follows the stream while
  the reader is within 160 dp of the end, and scrolling up stops that. The bottom fade runs from the docked orb to
  the composer. Hide it with the ⌄ button, a horizontal swipe, or a tap on the docked orb: the text fades out in
  160 ms and the orb glides back. A new spoken turn more than 3 s after the content clears it if the reader is at
  the top (§6.2).
- **Links:** markdown links and bare http(s) addresses become readable source rows (monogram, title, host).
  The first three show initially; an expansion reveals the rest (eight at most). Chat replies use the same rows.
  Titles and URLs come from returned content; preview images and publisher metadata are not invented. Images and code are
  skipped. A tap opens `LaunchMode.inAppBrowserView` (Custom Tabs / SFSafariViewController), falling back to the
  external browser. Pages never run inside our widget tree. Inline links in the text keep the markdown module's
  confirm sheet.
- **Work status (`live_work.dart`):** one quiet line between the orb and the composer, like the chat's thinking
  line: the newest running work's status ("Thinking", "Running terminal", from the reply's steps or the job's
  `status_event`) with a shimmer and a task count, or "Couldn't finish" / "Continues in the chat" for 12 s. No box,
  no timeline, no request text, no label under the orb. The orb keeps its size and only rises if the line would
  reach it. Steps are in the chat's Tasks panel (`../tasks/`) and the live conversation. `live_activity.dart`
  (the older card tracker) is no longer rendered.

## Chat activity

`../thread/work_line.dart` presents a quiet activity line and an inline disclosure. Step offsets count Unicode
code points on the bridge. Interim assistant messages before tool calls are placed in the timeline in order;
the final answer remains below it. Old bridges without offsets retain the full answer. Each tool with details
opens its input and output. Model reasoning is shown only if the bridge supplies it. Completed blocks retain
cached markdown rendering and streamed text uses the existing smooth reveal.

## Hooks for the integrator

- **hermes-ui blocks:** `lib/src/ui/interactive/` did not exist when this was written. If the markdown renderer
  does not draw `hermes-ui` fences itself, pass
  `blockBuilder: (context, content) => InteractiveBlocks(markdown: content.text)` (or whatever its public widget
  is). It renders under the answer in the panel.
- **Goldens in `test/ui/goldens/screen_live_*.png`** come from the full shell and will differ (cards, panel
  header). Regenerate them with the shell build.
