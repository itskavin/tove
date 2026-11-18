# gpt-live-bridge HTTP API (version 2)

This is the contract between the Hermes app (`apps/hermes_live`) and the bridge (`gpt-live-bridge.py`). It covers
text chat with Hermes Agent, chat history, live calls linked to a chat, and the start-error codes. It implements §9
of `apps/hermes_live/docs/design/redesign-spec.md`. Where this file and the spec disagree, **this file wins**.

Base URL: wherever the operator serves the bridge, always over HTTPS (see `SELF-HOSTING.md`). The Open WebUI path
(`/v1/realtime`) is unchanged and not covered here.

**What changed on 15 November 2026 (resumable streams).** Additive, so the version stays 2. Check the
`resumable_stream` capability.

- Each `/api/chat` reply now runs in the background. **Closing the connection no longer stops it**: the reply
  finishes and is saved. Stop a reply on purpose with `POST /api/chat/{message_id}/stop`.
- Every stream event carries an SSE `id:` line. `GET /api/chat/{message_id}/stream` with `Last-Event-ID` replays the
  events after that id, then follows the live reply.
- A new terminal event, `stopped`, tells you that a reply was stopped.
- **Older app builds** stop a reply by closing the connection. Against this bridge their Stop button only stops the
  display: Hermes carries on and the full reply appears on the next refresh. An operator who needs the old behaviour
  until the app updates sets `LIVE_STREAM_DISCONNECT=cancel`. Capabilities then report `disconnect_cancels: true`.
  Old clients ignore `id:` lines and unknown events, so nothing else changes for them.
- **Push notifications (UnifiedPush, no Google services):** see "Push notifications" below. Capability `push`.
- **A second GPT-Live backend (`openai`)**: the documented OpenAI Live API with the operator's own API key. See
  "openai backend" below. Capabilities gain `live_backend` and `live_backends`. With the default `codex` backend
  nothing changes for the app, except one new field, `backend: "codex"`, in the `/api/session` response.
- **Client requests, round 2** (`apps/hermes_live/docs/design/bridge-requests.md`): attachments (uploads, images
  to Hermes, documents in Hermes' workspace), tool calls saved on messages (`meta.tools`), progress for running
  live-call tasks, a `web_search` flag, the app-only UI prompt and link previews. Each has its own capability flag
  (see the table below).
- **Delegated live-call tasks now outlive the call.** Ending a call (or starting another) no longer cancels its
  running Hermes tasks. They finish, their results are saved to the linked chat as before, and a push goes out.

**What changed on 16 November 2026 (round 3).** Additive; the version stays 2.

- **One message per spoken turn.** `live-transcript` folds transcript fragments of one call (a piece that the next
  entry repeats and extends, an exact repeat, a reply cut off after a few words) into one message per turn, keeping
  the first entry's `id` and `created`. The response gains `merged`. A client clock that runs ahead no longer
  collapses every turn onto the server time. See "Live calls linked to a chat".
- **Per-message usage** (capability `usage`): `meta.usage` and the `done` event carry model, input/output/cached/
  reasoning tokens, duration, time to first token, tool count and effort. See "Usage".
- **Synced settings** (capability `settings_sync`): `GET`/`PUT /api/settings`. Custom instructions reach Hermes. See
  "Settings".
- **Starter suggestions** (capability `suggestions`): `GET /api/suggestions`. See "Suggestions".
- **Favicons** (capability `favicon`): `GET /api/favicon?host=`. See "Favicons".
- **Titles are rule-based by default** (`titles: "simple"`, no model call): the Hermes title call ran the whole
  agent, about 12,700 prompt tokens per new chat. Operators can turn it back on with `LIVE_TITLES=hermes`.
- **Small talk is not delegated.** A live-call task that is only a greeting, goodbye or thanks ("Okay, I think that's
  enough. Bye") finishes at once without Hermes and is not saved to the chat.
- **The UI prompt gained `entities` and `news` blocks** (the app's round 3 `hermes-ui-prompt.md`, about 234 more
  prompt tokens per model call: 14,152 → 14,386 for a bare `"ui": 1` request). The blocks stay `"v": 1`, so
  `ui_blocks_version` is still `1`; older apps show unknown types as a collapsed fallback. Checked with a real
  web-search news question: Hermes wrote valid `entities` and `news` blocks.
- **`POST /api/entity` (round 3, R3.4) is deferred.** The only model the bridge can reach is the full Hermes agent, so
  each tap on an entity card would cost a whole Hermes run (at least ~14,000 prompt tokens, far more with a web
  search). The capability `entity_details` is therefore absent; the app shows the embedded `about`/`facts` and
  its visible "Follow up" message instead, which costs a turn only when the user asks for it.

**What changed on 16 November 2026 (round 5).** Additive; the version stays 2.

- **Live tasks are chat messages from the start** (capability `task_messages`). A task delegated in a call linked to a
  chat is written into that chat at once as an assistant message with `source: task` and `status: streaming`, and is
  then streamed exactly like a typed reply: `step.*`, `status` and `delta` events, resume with
  `GET /api/chat/{message_id}/stream`, stop with `POST /api/chat/{message_id}/stop`. It keeps running after the call
  ends and survives app restarts (the message is in the chat; a bridge restart marks it `interrupted`). Its final
  text **is Hermes' answer in the chat**: no second Hermes run rephrases it. See "Live tasks in the chat".
- **Ended calls stay readable** (capability `jobs_after_call`): `GET /api/job/{sid}/{jid}` and
  `GET /api/session/{sid}/jobs` keep answering after the call ends (for an hour after its last job), instead of 404.
  Jobs gain `message_id` and `conversation_id` when they are chat messages, and `stopped` when they were stopped.
- **The app's own notification stream** (capability `events`): `GET /api/events` (authenticated SSE with ids,
  heartbeats and resume), `?once=1` for polling, `POST /api/events/test`. No distributor app and no Google service is
  needed. A device whose events stream is open gets no UnifiedPush (it hears the event directly). See "Events".

**What changed on 16 November 2026 (round 6).** Additive; the version stays 2.

- **Sync events** (capability `events.sync`): `/api/events` also carries `conversation.created`, `.updated`, `.title`,
  `.deleted`, `message.created`, `message.deleted` and `reply.started`, so every open client (phone, web on a PC)
  mirrors chat changes at once. Send `X-Device-Id` on every request: its events carry `origin`. See "Events".
- **Image proxy** (capability `image_proxy`): `GET /api/image?url=&w=` returns a reply picture's own bytes (8 MB cap,
  disk cache, host-sized variants such as Wikimedia thumbnails, a descriptive User-Agent that Wikimedia accepts).
  Use it for markdown images, `<img>` in `hermes-html` and `entities`/`news` images. See "Image proxy".
- **Usage limits** (capability `usage_limits`): `GET /api/usage/limits` lists the 5-hour and weekly quota, reset
  times and credits of every account the AI runs on (CLIProxyAPI's Codex/ChatGPT, Claude and Antigravity accounts,
  and the bridge's own ChatGPT login for GPT-Live), with masked account names. See "Usage limits".
- **Titles of 3–4 words** (`titles: "model"`): one small model call instead of a Hermes run. See "Titles".
- **Artifacts in the UI prompt**: big code, scripts, configs, emails and drafts arrive in one ```` ```hermes-artifact ````
  fence (a JSON header line, then the content). The exact format is in the app's `docs/design/hermes-ui-prompt.md`.
  About 100 more prompt tokens per model call.
- **The live voice knows its name**: both backends' session instructions now say who it is (`ASSISTANT_NAME`) and
  that it never calls itself ChatGPT, Codex or GPT. Nothing changes for the app.
- **Steps survive a cold-start resume** (app fix, documented under "Steps"): a reply resumed with a saved
  `Last-Event-ID` only hears the step events after that id; merge them into the stored `meta.steps` by step id.

## Deviations from the spec (read first)

1. **Error bodies have three fields.** Every JSON error is `{"error": …, "code": …, "message": …}`. `code` is the
   stable machine code, so **read `code`**. `error` holds the old human text on the old routes, so older app builds
   keep showing it. On new routes and for the new start errors, `error` equals `code`. The spec's
   `429 {"error":"usage_limit","retry_after_s":N}` is kept as is, with `code` and `message` added. `retry_after_s` is
   `null` when codex gives no hint.
2. **`login_expired` is HTTP 502, as in the spec, not 401.** A 401 always means the app's key is wrong (onboarding
   relies on that). Tell the two apart by `code`.
3. **`POST /api/conversations/{id}/live-transcript` takes an object, not a bare array:**
   `{"session"?, "turns": [...], "tasks"?: [...]}`. Each turn may carry an `id`, so a retried post does not duplicate
   turns.
4. **Extras that are not in the spec:**
   - `retry: true` on `/api/chat`.
   - `DELETE /api/conversations/{id}/messages/{mid}`.
   - `GET /api/conversations/{id}` returns the conversation together with its newest messages.
   - `limit` on every list.
   - A `pinned` filter on the list.
   - A `status` on every message.
   - `title_source`, `preview` and `message_count` on conversations.
   - A `markdown` field on `/api/job`.
5. **The `status` event carries more than `{label}`:** it is `{label, state, tool, id, emoji, kind?}` (see below).
6. **Titles arrive after `done`.** The stream does not wait for the Hermes title call. `done` carries the current
   (rule-based) title and `title_pending`. When `title_pending` is true, re-read the conversation a few seconds later
   (the call has a 20 s budget).
7. **Reply effort sets reasoning and speed.** `effort` goes to Hermes as `model_options.reasoning_effort` and also
   picks the OpenAI service tier:

   | `effort` | Reasoning | Service tier | Hermes request |
   | --- | --- | --- | --- |
   | `instant` | `low` | priority ("fast mode") | default provider (`cliproxy`, adds `service_tier: priority`) |
   | `medium` | `medium` | default | `"provider": "cliproxy-standard"` (`HERMES_STANDARD_PROVIDER`) |
   | `high` | `high` | default | `"provider": "cliproxy-standard"` |
   | omitted | as `medium` (`CHAT_DEFAULT_EFFORT`) | default | as `medium` |

   A chat reply without `effort` (app builds before effort, scripts) runs as Medium: it gives the balanced answer
   older builds got and doesn't spend the larger priority-tier quota on every message. The stored message `meta` and
   `usage.effort` still record only what the client sent. Live-call tasks send no effort and stay on Hermes'
   defaults (fast tier), because a caller is waiting on the voice line. Hermes cron jobs, Telegram and the title and
   side calls are unchanged. `HERMES_STANDARD_PROVIDER=off` keeps every reply in the fast tier. Capabilities report
   `effort: true`.

   How the tier is switched (Hermes code unchanged): Hermes can't drop the tier per request. `model_options.service_tier`
   is ignored for non-first-party hosts, and a per-request `provider` keeps the default provider's `extra_body`.
   So `cliproxy-standard` points at the same CLIProxyAPI under another hostname
   (for example the proxy's container name on the Docker network; Hermes matches `extra_body` by base URL) with its own client key, and a
   CLIProxyAPI `requests.payload.filter` rule strips `service_tier` for that key. Measured 18 November 2026 through
   the deployed bridge (gpt-6.1-terra, one short no-tool reply each, cold chat): time to first token Instant 2.6 s,
   Medium 3.8 s, High 2.8 s. These are single samples. About 1.5 s of each is Hermes before the model call. Round 9
   measured the priority tier alone at 1.0 s against 3.6–4.1 s at the model.
8. **Capabilities live at `GET /api/capabilities` (authenticated).** `/healthz` gains only `api_version`.
9. **Every timestamp is an integer number of Unix milliseconds** (`created`, `updated`).
10. **Search snippets have no highlight markers.** Highlight the query on the client, or use the optional `match`
    offsets (see search below).

## Conventions

- **Auth:** every `/api/*` route needs `Authorization: Bearer <LIVE_PAGE_KEY>`. A missing or wrong key gives
  `401 {"error":"unauthorized","code":"unauthorized","message":"unauthorized"}`. The key check probe is unchanged:
  `GET /api/job/check/check` returns 404 for a good key and 401 for a bad one.
- **Bodies** are JSON objects. A body that is not an object, or not valid JSON, gives `400 bad_request`. Bodies over
  1 MiB give `413 too_large`.
- **IDs** (conversation, message, `client_msg_id`, turn `id`, task `id`) are 1 to 64 characters of
  `A-Z a-z 0-9 _ -`. Treat them as opaque. An unknown or malformed id in a path gives `404 not_found`.
- **Unknown routes** give aiohttp's plain-text 404. An older bridge therefore answers 404 on `/api/capabilities`,
  which means "live only".

**What changed on 18 November 2026 (pairing).** Additive; the version stays 2.

- **Pairing codes** (capability `pairing`): `POST /api/pair` trades a one-time code for the access key, with no
  bearer key. The `tove-setup` Hermes skill (or `tove_pair.py` on the server) makes the code and shows it as a QR code
  holding `tove://pair?u=<address>&c=<code>`. See "Pairing".

## Capabilities

`GET /api/capabilities` → `200`

```json
{
  "version": 2,
  "live_backend": "codex",
  "live_backends": {
    "codex": {"available": true, "active": true, "voices": ["arbor", "…"], "default_voice": "cove", "server_delegation": false},
    "openai": {"available": false, "active": false, "model": "gpt-live-1", "voices": ["beacon", "…"], "default_voice": "marin",
               "server_delegation": true, "max_call_s": 1800, "daily_minutes": 60, "minutes_left_today": 60.0,
               "price_per_minute_usd": 0.05}
  },
  "chat": true, "history": true, "search": true, "pairing": true,
  "effort": true, "efforts": ["instant", "medium", "high"],
  "attachments": true, "vision": true, "language": false,
  "attachment_limits": {"max_items": 4, "image_mb": 10, "file_mb": 25, "conversation_mb": 200, "image_max_edge": 2048,
                        "unused_hours": 24, "mimes": ["image/jpeg", "image/png", "image/webp", "application/pdf", "text/*",
                        "application/json", "application/vnd.oasis.opendocument.presentation", "…"]},
  "web_search": true, "ui_prompt": true, "ui_prompt_header": "X-Hermes-UI", "ui_blocks": true, "ui_blocks_version": 1,
  "link_preview": true, "link_preview_images": true,
  "tool_parts": true, "job_progress": true,
  "steps": true, "step_limits": {"io_chars": 8192, "thinking_chars": 16384, "steps": 128},
  "status_events": true, "live_link": true, "live_transcript": true,
  "usage": true, "settings_sync": true, "settings_limits": {"bytes": 32768, "text_chars": 1500},
  "suggestions": true, "favicon": true,
  "titles": "model", "usage_limits": true,
  "image_proxy": {"max_mb": 8, "widths": [320, 640, 960, 1280, 1920], "types": ["image/gif", "image/jpeg", "image/png", "image/webp"]},
  "error_codes": true, "stream": "sse",
  "voices": ["arbor", "aube", "breeze", "bubbie", "cove", "ember", "juniper", "maple", "sol", "spruce", "vale"],
  "default_voice": "cove",
  "resumable_stream": true, "stop_endpoint": true, "disconnect_cancels": false,
  "push": "unifiedpush", "push_previews": true,
  "events": {"version": 1, "heartbeat_s": 80, "heartbeat_range": [15, 600], "keep": 2000, "poll": true, "test": true,
             "readers_max": 8, "sync": true, "sync_text_chars": 2000,
             "types": ["reply.done", "task.started", "task.done", "notify", "test", "conversation.created", "conversation.updated",
                       "conversation.title", "conversation.deleted", "message.created", "message.deleted", "reply.started"]},
  "task_messages": true, "task_ui": true, "jobs_after_call": true,
  "limits": {"message_chars": 8000, "title_chars": 120, "query_chars": 200, "page_max": 100,
             "messages_page_max": 200, "concurrent_chats": 2, "transcript_turns": 500, "transcript_tasks": 50,
             "task_chars": 32000, "keepalive_s": 15.0, "chat_timeout_s": 900, "live_jobs": 2,
             "stream_keep_s": 300, "stream_buffer_events": 10000,
             "push_devices": 10, "push_per_minute": 20, "push_preview_chars": 120}
}
```

| Flag | Meaning |
|---|---|
| `chat` | `POST /api/chat` works (history is open and the Hermes key is configured) |
| `history` / `search` | The conversation routes work |
| `effort` | `effort` is forwarded to Hermes |
| `attachments` | Uploads work (see "Attachments"). `false` when the operator turned them off or neither vision nor a Hermes workspace is set up |
| `vision` | Images reach Hermes' model as `image_url` parts. With `false`, images are handled like documents |
| `attachment_limits` | Limits the server enforces. `mimes` lists only what this server accepts: without a Hermes workspace, images only. `text/*` is a whole family |
| `web_search` | `web_search: true` on `/api/chat` is honoured (Hermes' API agent has its `web` toolset) |
| `ui_prompt` / `ui_blocks` | The Hermes-app prompt is loaded: `"ui": 1` on `/api/chat` gets replies that may contain `hermes-ui` blocks and that use GFM tables and `-` lists. Both are `false` when no prompt is installed or the operator turned it off |
| `ui_blocks_version` | The `hermes-ui` version the prompt describes (`1`), or `null` |
| `ui_prompt_versions` | The `"ui"` versions with their own prompt installed: `[1]`, or `[1, 2]` when the OpenUI-only prompt is there (see "UI prompt versions") |
| `ui_prompt_header` | The header alternative to `"ui"` (`X-Hermes-UI`), for clients that cannot change the body |
| `link_preview` | `GET /api/link-preview` works |
| `link_preview_images` | `GET /api/link-preview` on a direct image URL returns that image (`"kind": "image"`), for markdown images in replies |
| `tool_parts` | Assistant messages carry `meta.tools`, and `snapshot` events carry `tools` |
| `steps` / `step_limits` | `/api/chat` sends `step.start`/`step.delta`/`step.end` events, and assistant messages carry `meta.steps` (see "Steps") |
| `job_progress` | `/api/job` and the jobs list add `status_event` and `partial` while a task runs |
| `language` | Always `false` for now. Hide the Language row |
| `status_events` | `/api/chat` may send `status` events |
| `live_link` / `live_transcript` | `/api/session` accepts `conversation_id`, and the transcript import route works |
| `titles` | `"simple"` (rule only), `"model"` (a small 3–4 word title call, see "Titles") or `"hermes"` (one extra Hermes call after the first reply) |
| `image_proxy` | `GET /api/image` works (see "Image proxy"): `max_mb`, `widths`, `types` |
| `usage_limits` | `GET /api/usage/limits` works (see "Usage limits") |
| `usage` | Assistant messages carry the richer `meta.usage`, also in `done` (see "Usage") |
| `settings_sync` / `settings_limits` | `GET`/`PUT /api/settings` work (see "Settings"); `bytes` is the largest settings object, `text_chars` the limit of `custom_instructions` and `about_you` |
| `suggestions` | `GET /api/suggestions` works |
| `favicon` | `GET /api/favicon?host=` works (with link previews on) |
| `error_codes` | `/api/session` returns `usage_limit` / `login_expired` codes |
| `resumable_stream` | Stream events have ids, `GET /api/chat/{id}/stream` resumes, and a dropped connection does not stop the reply |
| `stop_endpoint` | `POST /api/chat/{id}/stop` exists. **Call it for the Stop button**: closing the connection is not a stop |
| `disconnect_cancels` | `true` only when the operator turned on the old behaviour (`LIVE_STREAM_DISCONNECT=cancel`) |
| `push` | `"unifiedpush"` when the push routes work, else `false` |
| `push_previews` | `false` when the operator keeps titles and text out of pushes (`PUSH_PREVIEWS=false`) |
| `events` | `GET /api/events` works (see "Events"): `heartbeat_s` is the default heartbeat, `heartbeat_range` what `?heartbeat=` accepts, `keep` how many events stay available for resume and polling. `false` without history |
| `task_messages` | Tasks of a call linked to a chat are `source: task` messages that stream from their start (see "Live tasks in the chat") |
| `task_ui` | Those tasks get the app's UI prompt, so their answer may contain `hermes-ui` blocks |
| `jobs_after_call` | `/api/job` and `/api/session/{sid}/jobs` still answer after the call has ended |
| `report` | `POST /api/report` works (see "Reports"): `reasons` it accepts, `note_chars` the note limit |
| `pairing` | `POST /api/pair` trades one-time pairing codes for the key (see "Pairing"). Needed before a key exists, so clients just try it; a `404` means an older bridge |
| `live_backend` | The backend `/api/session` uses now: `codex` or `openai`. `voices` and `default_voice` at the top level are that backend's |
| `live_backends` | Per backend: `available` (codex: a login exists; openai: a key is set; never the key itself) and `active`, plus the openai limits: `max_call_s`, `daily_minutes` (`null` = no budget) and `minutes_left_today` |

Fallbacks:

- 404 on this route means a version 1 bridge: live only, with generic start errors.
- `resumable_stream` missing means a bridge from before 15 November 2026: no ids, no resume, and closing the
  connection is the only way to stop a reply.
- `chat: false` with `history: true` means history can be read, but sending is off.

## Streaming chat

`POST /api/chat`

```json
{"conversation_id": "optional", "message": {"text": "…", "attachments": ["up_…"]}, "effort": "instant|medium|high (optional)",
 "web_search": false, "client_msg_id": "optional", "retry": false}
```

- `message.attachments` (optional): at most `attachment_limits.max_items` distinct ids from `POST /api/uploads`. See
  "Attachments". **`text` may be empty when there are attachments.** A new chat without text is named after the
  first attachment.
- `web_search: true` (optional): when capabilities say `web_search: true`, the newest user turn tells Hermes to use
  its web search tool and name its sources. It is stored as `meta.web_search` on the user message, and a retry
  repeats it. Hermes' API has no tool-choice hint, so this is an instruction, not a forced tool call. The instruction
  stays on that turn in the history sent with later turns, so the conversation's first user message reads the same
  every time (Hermes derives its session, and its stored system prompt, from it). When the capability is `false`, the
  flag is accepted and ignored.
- `"ui": 1` in the body (optional; the Hermes app only, on a send and on a retry), or the header `X-Hermes-UI: 1`:
  when `ui_blocks` is `true`, the Hermes-app prompt goes to Hermes as a system message ahead of the history. It
  says the app renders Markdown (so Hermes' plain-text hint for API clients does not apply), sets an adaptive reply
  style (a direct lead; lists with bold labels for parallel points; brief headings only for longer answers; plain
  text for greetings and quick facts; a news pattern with `entities` and `news` blocks), describes the `hermes-ui` blocks and requires GFM pipe tables (header and
  separator row) for tabular data and `-`/`1.` lists. It is byte-identical on every turn, with or without
  `web_search`, because Hermes derives its session id from the system prompt plus the first user message; changing
  the file therefore starts a new Hermes session for chats that continue afterwards (their history is still sent). `"ui"` must be a whole number of at least 1 (`true`, `0` or `"1"` do not count). Requests without
  it (Open WebUI, scripts) never get these instructions, so they never see raw `hermes-ui` JSON. The prompt is the
  first file found of `LIVE_UI_PROMPT_FILE`, `<data>/hermes-ui-prompt.md`, and `hermes-ui-prompt.md` shipped beside
  the bridge (`LIVE_UI_PROMPT_FILE=off` turns it off). The app's copy in
  `apps/hermes_live/docs/design/hermes-ui-prompt.md` is kept identical.
- **UI prompt versions** (18 November 2026). `"ui": 2` (Tove from round 10) asks for the OpenUI-only prompt: the
  markdown rules (`markdown-prompt.md`), then OpenUI's chat library as the single rich format
  (`openui-chat-prompt.md`, generated from the app's component registry: `cd app && dart run tool/openui_prompt.dart`).
  It has no `hermes-ui`, `hermes-html` or `hermes-artifact` instructions; emails, artifacts, checklists, entities,
  news and status are OpenUI components. `"ui": 1` (and the `X-Hermes-UI` header) keeps the round-9 prompt
  (`hermes-ui-prompt.md` + `openui-prompt.md`), so installed apps do not get components they cannot draw. Larger
  numbers get the newest prompt. Files: `LIVE_MARKDOWN_PROMPT_FILE` and `LIVE_OPENUI_CHAT_PROMPT_FILE`, else
  `<data>/markdown-prompt.md` and `<data>/openui-chat-prompt.md`, else the copies beside the bridge; hot-reloaded;
  when either is missing or `off`, version 2 gets the version-1 prompt. Capability `ui_prompt_versions` lists what
  is installed (`[1, 2]`). `/api/session` takes the same `"ui"`: tasks of that call get that version's prompt
  (default 1). Measured with a bare request: 18,324 prompt tokens for version 1, 17,437 for version 2.

- Without `conversation_id`, a new conversation is created. Its title is the first 40 characters of the text, cut at
  a word, with `…` added when cut.
- `client_msg_id` is stored on the user message. Sending the same one again in the same conversation gives
  `409 duplicate`.
- `retry: true` (needs `conversation_id`; `message` is ignored) answers the conversation's newest user message
  again. The text replies after that message are deleted first, whatever their status. Task results and voice turns
  are kept.
- Hermes receives the conversation's newest 40 messages (at most about 48,000 characters, newest kept), including the
  new user message. Task results are prefixed with a note saying that they came from a live call.

**Errors before the stream starts** (normal JSON responses):

| Status | `code` | When |
|---|---|---|
| 400 | `empty_message`, `too_long` (> 8000 chars), `bad_effort`, `bad_client_msg_id`, `nothing_to_retry` (retry without a conversation), `bad_request` (also a non-boolean `web_search`) | Invalid input |
| 400 | `bad_attachment` | Not a list of distinct ids, too many, unknown, already sent with another message, or owned by another conversation |
| 507 | `quota_exceeded` | The attachments would take this conversation past `conversation_mb` |
| 401 | `unauthorized` | Wrong or missing key |
| 404 | `not_found` | Unknown conversation |
| 409 | `duplicate` | `client_msg_id` already used in this conversation |
| 409 | `nothing_to_retry` | Retry, but the conversation has no user message |
| 413 | `too_large` | Body over 1 MiB |
| 429 | `busy` | 2 replies are already being written (one key, so the cap is global). Replies still running in the background after a disconnect count too |
| 503 | `history_unavailable`, `hermes_unconfigured` | Server-side setup problem |

**Success:** `200`, with `Content-Type: text/event-stream; charset=utf-8`. Each event is
`id: <n>\nevent: <name>\ndata: <one JSON line>\n\n`. Ids count up from 1 within one reply (`meta` is always 1), with
no gaps. Keep the last id you processed. Lines starting with `:` are comments: a `: keep-alive` is sent after 15 s
without other output. Read the stream with `fetch` or `IOClient` streaming, not `EventSource` (the stream needs the
`Authorization` header).

| Event | Data | Notes |
|---|---|---|
| `meta` | `{"conversation_id", "message_id", "user_message_id", "client_msg_id", "created_conversation", "title", "resumable"}` | Always first (id 1). `message_id` is the **assistant** message being written: keep it for resume and stop. `client_msg_id` is `null` when none was sent. `resumable` is `true` |
| `delta` | `{"text"}` | Append to the reply. Chunks are Hermes' own token chunks, sent on as they arrive. Blank lines before the reply's first visible character are dropped |
| `status` | `{"label", "state", "tool", "id", "emoji", "kind"?}` | Hermes progress. `state` is `running` (tool started; `label` is a short preview such as `df -h`), `completed` (the tool with this `id` finished; `label` may repeat the tool name), `info` (Hermes lifecycle notes such as a provider wait; `kind` is set), or `approval` (Hermes waits for an approval it cannot get here) |
| `done` | `{"conversation_id", "message_id", "finish_reason", "usage", "title", "title_pending"}` | The reply is complete and saved. `usage` is the reply's `meta.usage` (see "Usage"). Its `prompt_tokens`, `completion_tokens` and `total_tokens` are kept for older clients |
| `error` | `{"conversation_id", "message_id", "code", "message"}` | The reply failed. The text received so far is saved with status `error` |
| `stopped` | `{"conversation_id", "message_id", "reason"}` | The reply was stopped. The partial text is saved with status `cancelled`. `reason` is `user` (the stop route), `retry` (a retry replaced it), `deleted` (its chat or message was deleted) or `disconnect` (only with `disconnect_cancels`). **Not an error**: show it as stopped |
| `step.start` / `step.delta` / `step.end` | See "Steps" | The thinking and tool timeline. Ignore them if you do not use steps |
| `snapshot` | `{"conversation_id", "message_id", "text", "status", "last_status", "tools", "steps"}` | On resume (see below), and once just before `done` when the bridge filled in entity pictures (round 9, "Entity pictures"). **Replace** the reply text with `text`. `last_status` is the newest `status` event's data or `null`. `tools` is the reply's tool list so far (the same shape as `meta.tools`), so cards whose events left the buffer can be rebuilt |

`error` codes in the stream:

| `code` | Meaning |
|---|---|
| `hermes_error` | Hermes returned an HTTP error, or reported an error inside the stream |
| `hermes_auth` | Hermes rejected the bridge's key (401/403) |
| `hermes_busy` | Hermes returned 429 |
| `hermes_unreachable` | Network failure |
| `timeout` | The reply took more than 900 s in total |
| `hermes_incomplete` | The stream ended without a finish |
| `bridge_error` | The bridge itself failed while writing the reply |
| `interrupted` | Only on resume: the bridge restarted while it wrote this reply |

After `done`, `error` or `stopped`, the response ends.

**Disconnects.** A closed connection, from a network drop, the app going to the background or a reader that is no
longer needed, ends only that reader. Hermes keeps working, the bridge keeps saving the partial text (at least every
2 s), and the final message is stored as usual. Resume, or refetch the conversation: a reply that is still running
shows `status: streaming`.

### Resume a reply

`GET /api/chat/{message_id}/stream`, with the last id you processed in the `Last-Event-ID` header (or in
`?last_event_id=`; the header wins when both are present). Without either, you get the reply from the start, `meta`
included.

- **The reply is still running, or finished less than 5 minutes ago** (`stream_keep_s`): you get every event after
  that id, then the live events, ending with `done`, `error` or `stopped`. The ids are the same as in the original
  stream. You can open a second reader at any time, for example on another device; each reader gets every event.
- **The buffer dropped some of the events you missed** (a reply over `stream_buffer_events` events): you get one
  `snapshot` first, carrying the whole text so far and the id of the last event it covers, then the events after it.
- **The reply finished longer ago, or the bridge restarted**: the answer comes from the saved message. You get a
  `snapshot` (the saved text) and then the terminal event: `done` for `complete`, `stopped` for `cancelled`, `error`
  for `error`, and `error` with code `interrupted` for a reply that a restart cut off. These two events carry the
  ids of the original stream when the bridge recorded them (`snapshot` = last id − 1, terminal = last id). If you
  have already seen the last id, the stream is empty. Replies from before this change have no recorded ids, so
  those events come without `id:` lines.
- `meta` is sent again only when you resume from id 0.
- Errors (JSON): `400 bad_last_event_id` (not a whole number), `404 not_found` (no such assistant text reply),
  `401`, `503 history_unavailable`.

The client should save `message_id` and the last id while a reply streams. On reconnect, on app resume, or when it
opens a chat whose newest reply has `status: streaming`, it resumes with them.

### Stop a reply

`POST /api/chat/{message_id}/stop` (no body needed) →
`200 {"ok": true, "conversation_id", "message_id", "stopped", "status", "text"}`

- `stopped: true` means this call stopped a running reply. The bridge cancels the Hermes request, which interrupts
  the agent, and waits up to 10 s for the reply to be saved. The partial text is kept with status `cancelled` and
  `meta.stop_reason: "user"`. Every open reader receives `stopped`.
- `stopped: false` means the reply had already ended. `status` is then its final status (`complete`, `error`, …).
  Stopping twice is harmless.
- `404 not_found` for an unknown id, `401` without the key.
- `retry: true` on `/api/chat` and deleting a chat or a message also stop that chat's running reply first.

**Non-streaming fallback:** if Hermes ever answers with plain JSON, the bridge sends the whole reply as one `delta`.
The event sequence does not change. Hermes 2026-11 streams real deltas, and the bridge neither batches nor re-chunks
them. Checked on 15 November 2026: the model provider sends token chunks of 1–14 characters in clumps about 100–200 ms
apart, and a researched answer reached the app as 442 deltas over 6 s. The answer starts only after the turn's last
tool, though, and a few seconds of silence can come between the last step and the first delta (2–6.5 s in that
check) while the model works without sending anything. A short answer can arrive within a few milliseconds when Hermes
or the provider hands it over at once. Show the working line during that wait; do not fake typing.

## Push notifications (UnifiedPush)

The bridge can wake the app when a reply or a live-call task finishes while nobody is watching. It uses
[UnifiedPush](https://unifiedpush.org/): the app gets an endpoint URL from a distributor app on the phone (ntfy, or
another one), registers it here, and the bridge sends a plain HTTP `POST` to that URL. No Google or Firebase service
is involved. `SELF-HOSTING.md` explains how to run ntfy.

`POST /api/push/register`

```json
{"device_id": "stable per-install id", "endpoint": "https://ntfy.example.org/upAbC123?up=1", "app_version": "1.4.0"}
```

- `device_id`: an id string (1–64 characters of `A-Z a-z 0-9 _ -`). Keep it for the life of the install.
- `endpoint`: the URL the distributor gave you: `http` or `https`, at most 2048 characters, a host, no spaces and
  no `user:password@`. Register again whenever the distributor gives you a new endpoint. Registering the same
  `device_id` again replaces its endpoint. An endpoint that another `device_id` held moves to this one.
- `app_version`: optional string, at most 64 characters.
- `200 {"ok": true, "device_id", "previews"}`. `previews` is the `push_previews` setting.
- Errors: `400 bad_device_id`, `bad_endpoint`, `bad_app_version`; `409 too_many_devices` (more than 10 devices;
  unregister one); `503 push_disabled`; `401`.
- The bridge stores endpoints in SQLite and never returns or logs them. Anyone with an endpoint can send to that
  device, so treat it as a secret.

`DELETE /api/push/register/{device_id}` → `200 {"ok": true, "removed": true|false}`. Call it when the user turns
notifications off or signs out. Removing twice is harmless.

`POST /api/push/test` `{"device_id"}` → `200 {"ok": true, "delivered": bool, "status": <distributor HTTP status or null>}`.
Sends one `test` push to that device. `404` for an unknown device, `429 rate_limited`.

**When pushes are sent:**

| Event | Push `type` | When |
|---|---|---|
| A chat reply ends (`done`, `error` or `stopped`) | `chat.reply` | No client is reading its stream at that moment (`POST /api/chat` or `GET …/stream`). Not when it was stopped by a retry, a delete or a disconnect in cancel mode |
| A delegated live-call task ends | `live.task` | The call has ended, or the app has not polled `/api/job` for 15 s |

A device whose `GET /api/events` stream is open (with its `device_id`) gets no push: it hears the event directly.

A client that is reading the stream gets the terminal event itself and handles in-app notification. **When the app
goes to the background, close its stream** (and resume when it comes back), so that the bridge knows to push. A
connection the network dropped silently can count as "reading" until TCP gives up; that reply then gets no push.

**Push body** (`Content-Type: application/json`, about 400 bytes, well under the UnifiedPush 4 KiB limit):

```json
{"type": "chat.reply", "conversation_id": "…", "message_id": "…", "title": "Disk space on storage",
 "preview": "Plain text, at most 120 characters, with … when cut", "status": "done|failed|stopped", "sent": 1794691021626}
```

- `type`: `chat.reply`, `live.task` or `test`.
- `conversation_id` and `message_id`: open that chat and message. For a task of a call that was not linked to a
  chat, both are `null`. For `test`, both are `null`.
- `title`: the conversation's title, `null` when unknown.
- `preview`: the start of the reply or task result as plain text (markdown removed), at most 120 characters.
- **With `PUSH_PREVIEWS=false`, `title` and `preview` are always `null`**: no message content leaves the bridge.
  Show a generic "Reply ready" and fetch the message over the API.
- Pushes go through the distributor's server (for ntfy, the ntfy server). They are not end-to-end encrypted.
- Delivery is best effort. A push that fails is not retried. The bridge also sends `TTL: 86400` and
  `Urgency: normal` headers.
- Rate limit: at most 20 pushes per device per minute (`PUSH_RATE_PER_MIN`); extra pushes are dropped. A
  distributor answering `404` or `410` means the endpoint is gone: the bridge removes that device.

## Pairing

Lets the app connect without anyone copying the access key. On the server, `tove_pair.py` (run by the `tove-setup`
Hermes skill, or by hand: `docker exec tove-bridge python /app/tove_pair.py --url https://<address>`) makes a
one-time code and prints:

- a QR code holding **`tove://pair?u=<bridge address>&c=<code>[&n=<server name>]`** (URL-encoded query values;
  the address is what the phone uses, for example `https://box.tail1234.ts.net:8787`), and
- the same address and code for typing in, for example `ABCDE-FGHJK`.

The long-lived key is never in the QR code, the link or the script's output.

**Codes.** 10 characters from `23456789ABCDEFGHJKLMNPQRSTUVWXYZ` (50 bits; no `0`/`O` or `1`/`I`), shown as
`XXXXX-XXXXX`. Each works **once**, for **10 minutes** (`--ttl`, 60–3600 s). Several may be valid at once (two
phones). Clients ignore case, spaces and dashes; so does the bridge.

**Storage.** `<BRIDGE_DATA_DIR>/pairing.json` (`TOVE_PAIR_FILE`), mode 600, holds only
`sha256("tove-pair:" + code)`, the creation and expiry times (Unix seconds) and `used_at`:

```json
{"version": 1, "codes": [{"sha256": "…", "created_at": 1795000000, "expires_at": 1795000600, "used_at": null}]}
```

The bridge reads the file on each request, so a code made while it runs works at once. At most 8 entries are kept,
and entries more than a day past their expiry are dropped when the next code is made.

`POST /api/pair` (no `Authorization`) with `{"code": "ABCDE-FGHJK"}` →

```json
{"key": "<LIVE_PAGE_KEY>", "name": "Hermes", "version": 2}
```

`name` is `ASSISTANT_NAME`. The response has `Cache-Control: no-store`. The code is marked used before the answer
goes out; if the file cannot be rewritten the bridge answers `500 pairing_failed` instead of handing out the key.

| Status | `code` | Meaning |
|---|---|---|
| 400 | `bad_request` | Not JSON, or `code` missing, under 6 or over 32 characters after normalising |
| 401 | `invalid_code` | No such code (counts as a wrong attempt) |
| 410 | `code_expired` | The code was used already or is past its expiry |
| 429 | `too_many_attempts` | Too many wrong codes: 6 per address or 20 in total per 10 minutes. `retry_after_s` and `Retry-After` say when to try again. While limited, even a right code waits |
| 503 | `pairing_off` | The bridge has no `LIVE_PAGE_KEY` |

The limit counts all clients together as well, because behind `tailscale serve`, a tunnel or a reverse proxy every
request comes from the same address. With 50-bit codes, 20 guesses per 10 minutes cannot find a code in its 10
minutes.

**The app** saves the address and the key it received, then checks the key with an ordinary authenticated request
before showing the chat. A bridge from before pairing answers `404` (no JSON `code`): tell the user to update the
bridge or use the key. `GET /healthz` (no key) answers `200 {"ok": true, …}` when the bridge runs.

**Android.** A `tove://pair` link from outside the app (a camera app, a tapped link) opens the app through a
`BROWSABLE` intent filter for that host only; other `tove://` links are accepted only from the app's own widgets.
If the app is already connected, it asks before switching servers.

## Assistant messages (server jobs)

The assistant can start a message itself: Hermes' scheduled jobs on the bridge's host (for example a
watchdog or a morning briefing) post into one chat of their own, and registered devices get the usual push. The app needs no new
code: it is an ordinary chat whose messages are assistant messages with `"source": "notify"` (shown as text).

`POST /api/notify` with `Authorization: Bearer <TOVE_NOTIFY_KEY>`; not the app's key, and only through a loopback
`Host` (`127.0.0.1`, `localhost`, `[::1]`), so a request through a public route is refused (`403`) even with the key.
Without `TOVE_NOTIFY_KEY` the route answers `404`.

```json
{"text": "⚠️ Tove: homelab needs attention\n- Monitor down: NAS — SMB", "kind": "alert", "dedupe": "brief-20261117"}
```

- `text`: Markdown, 1–8000 characters. `kind`: `alert`, `briefing` or `note` (default), stored as `meta.notify`.
- `dedupe`: optional id (1–64 of `A-Z a-z 0-9 _ -`); a second post with the same id answers
  `200 {"ok": true, "duplicate": true}` and changes nothing.
- The message goes into the newest chat that already holds one (titled with `ASSISTANT_NAME`, `title_source:
  "hermes"`); if the user deleted it, the next message starts a new one. Replying there is a normal `/api/chat` turn
  and Hermes sees the assistant's messages as history.
- `200 {"ok": true, "conversation_id", "message_id", "push_devices"}`; a `chat.reply` push with status `done` goes to
  every registered device. Errors: `400 bad_request`, `401`, `403`, `429 rate_limited` (30 an hour).

## Live tasks in the chat

Capability `task_messages`. For a call started with `conversation_id`, each delegated task (small talk excepted) is:

1. **Created as a message** the moment it is delegated: `role: assistant`, `source: task`, `status: streaming`,
   `client_id: job:<session>:<job>`, `meta: {"task": <request>, "job", "session"}`, `created` = the delegation time
   (so it sits where it was asked in the thread, before the call's voice turns that are posted later). A
   `task.started` event goes out.
2. **Streamed like a reply.** `GET /api/chat/{message_id}/stream` (with `Last-Event-ID`) gives the same events as a
   typed reply. Its `meta` event (id 1) adds `"source": "task"`, `"session"` and `"job"`; `user_message_id` is
   `null`. A reader may attach at any time: during the call, after it, after the app restarts.
3. **Ended like a reply.** `done`, `error` (`hermes_error`, `timeout` after 900 s, …) or `stopped`. The message is
   saved with `status` `complete`, `error` (keeping any text that arrived) or `cancelled`, plus `meta.seconds`,
   `meta.steps`, `meta.tools` and `meta.usage`. A bridge restart leaves it `interrupted`. A `task.done` event goes out,
   and a `live.task` push when nobody reads its stream and the call has ended or stopped polling.

The message text is the task's final answer, and it is the assistant's reply in the chat. Hermes is told (a chat-task
note in place of the voice note) to open with one or two plain sentences that give the result on their own (those
are spoken), then add details for reading only where they help. With `task_ui` the app's UI prompt goes along as the
system message, so the answer may use `hermes-ui` blocks; the voice copy (`answer` on `/api/job`) reads a block's
titles, labels and values instead of its JSON. Cost: one Hermes run per task as before, plus the UI prompt (about
3,700 prompt tokens per model call, mostly prompt-cached); `LIVE_TASK_UI=false` turns that off.

- Ending the call never stops a task. `POST /api/chat/{message_id}/stop` does (its job then reads `failed` with
  `stopped: true`). Deleting the message or the chat stops it too. A `retry` in that chat does not.
- Live tasks have their own limit (`live_jobs`): they never count against `concurrent_chats`, and a running task does
  not block typing in the same chat.
- `GET /api/job/{sid}/{jid}` keeps mirroring it (`status`, `partial`, `status_event`, then `markdown`/`answer`) and
  adds `message_id`/`conversation_id`, so a call screen can hand the task over to the chat.
- Calls **not** linked to a chat run tasks the old way (no message; the app posts them with the transcript).

## Events

Capability `events`. The app's own notification channel: one authenticated, long-lived SSE stream that tells it when
replies and tasks finish and when the assistant posts on its own. It replaces a distributor app: an Android app can
hold this stream in a low-importance foreground service (what ntfy itself does), and fall back to polling
`?once=1`. Events are kept in SQLite (the newest `LIVE_EVENTS_KEEP`, 500 by default, at most 7 days), so a client
can resume across reconnects, app restarts and bridge restarts.

`GET /api/events` (`Authorization: Bearer <LIVE_PAGE_KEY>`)

| Parameter | Meaning |
|---|---|
| `Last-Event-ID` header, or `?after=<id>` | Replay the events after that id, then follow live. The header wins. **Without either the stream starts with new events only** (`?after=0` replays everything kept) |
| `?heartbeat=<s>` | Seconds between heartbeats, 15–600 (default `heartbeat_s`, 80). Keep it under the shortest idle timeout on the way: Cloudflare closes a silent proxied stream after 100 s |
| `?device_id=<id>` | The app's UnifiedPush device id (if any). While this stream is open that device gets no UnifiedPush |
| `?once=1` | No stream: `200 {"events": [{"id", "type", "data"}], "last_id", "reset", "more"}` (at most 200; `more: true` means ask again from `last_id`) |

Stream format: first `event: hello` (no `id:`) with `{"version": 1, "last_id", "heartbeat_s", "time", "reset"}`, then
one `id: <n>\nevent: <type>\ndata: <json>\n\n` per event, oldest first. Ids only grow, also across trims and restarts.
After `heartbeat_s` without output a comment `: hb` (6 bytes) is sent. A client that hears nothing for about twice
the heartbeat should reconnect with its last id.

`reset` (in `hello` and in the poll answer) is `null`, `"gap"` (events after your id were trimmed: re-read your
chats) or `"unknown_id"` (your id is newer than anything this bridge issued, for example a new database: continue
from `last_id`).

| `type` | `data` |
|---|---|
| `reply.done` | `{"conversation_id", "message_id", "status": "done\|failed\|stopped\|interrupted", "title", "preview", "watched"}`. Every typed reply's end, except stops by a retry or a delete. `watched`: a stream reader was attached at the end |
| `task.started` | `{"conversation_id", "message_id", "session", "job", "title", "request"}` (a task of a linked call, see above) |
| `task.done` | `{"conversation_id", "message_id", "session", "job", "status", "seconds", "title", "preview", "watched"}`. For an unlinked call `conversation_id` and `message_id` are `null` |
| `notify` | `{"conversation_id", "message_id", "kind": "alert\|briefing\|note", "title", "preview"}` (`POST /api/notify`) |
| `test` | `{"title", "preview", "conversation_id": null, "message_id": null}` (`POST /api/events/test`) |

Every `data` also has `created` (Unix ms). `title` is the chat's title; `preview` is the start of the reply as plain
text (markdown removed, secrets redacted, at most 120 characters). **Events never carry steps, tool input or tool
output.** Because they travel only to the app's key over the bridge's own HTTPS route, they carry `title` and
`preview` even with `PUSH_PREVIEWS=false` (which is about third-party push servers).

### Sync events (round 6)

Capability `events.sync: true`. The same stream also carries every change to the chat history, wherever it was made
(the phone, the web app on a PC, a live call, Hermes' own jobs), so each open client can mirror it at once instead of
re-reading lists. A client that missed events (`reset: "gap"`, or it was closed) re-reads its chat list and the open
chat, as before.

| `type` | `data` | Sent when |
|---|---|---|
| `conversation.created` | `{"conversation_id", "conversation"}` | A chat is created (`POST /api/conversations`, the first `/api/chat` message, a notify chat) |
| `conversation.title` | `{"conversation_id", "title", "title_source", "conversation"}` | A rename (`PATCH`), or an automatic title (rule-based or Hermes, `title_source` `auto`/`hermes`) |
| `conversation.updated` | `{"conversation_id", "changes": [...], "conversation"}` | `changes` is `["pinned"]` (pin/unpin), `["kind"]` (the chat became `live`) or `["messages"]` (a transcript import added messages: one event for the whole import, not one per turn) |
| `conversation.deleted` | `{"conversation_id"}` | The chat and its messages are gone |
| `message.created` | `{"conversation_id", "message_id", "message", "conversation"}` | Any new message: the user's, an assistant reply's placeholder (`status: streaming`, empty text), a live task (`source: task`), a notify message |
| `message.deleted` | `{"conversation_id", "message_id"}` | `DELETE …/messages/{mid}`, or a retry dropping the old reply |
| `reply.started` | `{"conversation_id", "message_id", "user_message_id"}` | A typed reply starts streaming (live tasks send `task.started`). Follow it with `GET /api/chat/{message_id}/stream` if the chat is open |

The end of streaming is the existing `reply.done` / `task.done`.

- `conversation` is the full conversation object (title, pinned, kind, `updated`, `preview`, `message_count`) after the
  change, so a chat list can update its row and order without a request.
- `message` is the message object **without** `steps`, `tools` or `usage`: its `meta` keeps only `effort`,
  `web_search`, `task`, `job`, `session` and `notify`. `text` is cut to `sync_text_chars` (2000) characters with
  `"truncated": true`; re-read the chat (or `GET /api/conversations/{id}`) for the full text. Attachments are listed.
- `origin`: when the request that caused a change sent an `X-Device-Id` header (the app's per-install id, 1–64 of
  `A-Z a-z 0-9 _ -`), every event it causes carries `"origin": "<that id>"`, including the reply's later events. A
  client may skip events with its own `origin` (it already has the change); events without `origin` came from the
  server itself or a client that sent no id. Send the header on every `/api/*` request.
- Events are hints in id order; apply them idempotently (upsert by id; a `message.created` for a message you
  already have is a no-op). Streaming replies are saved every 2 s but produce no event per save: follow the reply's
  own stream for its text.
- `LIVE_EVENTS_KEEP` now defaults to 2000 (each typed turn adds about five events).

`POST /api/events/test` → `200 {"ok": true, "id", "readers"}`: one `test` event; `readers` is how many streams are
open. At most 6 a minute (`429 rate_limited`).

Errors: `400 bad_request` (a malformed id or heartbeat), `400 bad_device_id`, `401`, `429 too_many_readers` (more than
8 open streams), `503 history_unavailable`.

## Conversations

Conversation object:

```json
{"id": "…", "title": "…", "title_source": "auto|hermes|user", "pinned": false, "kind": "text|live",
 "created": 1794691021626, "updated": 1794691024435, "preview": "last non-empty message, ≤160 chars",
 "message_count": 4}
```

- `kind` becomes `live` once a live call is linked to the chat or a transcript is imported into it. Show the
  waveform glyph for these chats.
- `updated` changes with every new message and live link. It does not change on rename or pin, so the chat keeps
  its place in the list.

Message object:

```json
{"id": "…", "conversation_id": "…", "role": "user|assistant", "text": "markdown or plain",
 "source": "text|voice|task", "status": "complete|streaming|cancelled|error|interrupted",
 "created": 1794691021626, "client_id": "c-1 | turn:<id> | job:<session>:<job> | null", "meta": {}}
```

Message statuses:

| `status` | Meaning |
|---|---|
| `complete` | Normal |
| `streaming` | The reply is being written right now |
| `cancelled` | Stopped (the stop route, a retry, or a disconnect with `disconnect_cancels`). `text` is the partial reply; `meta.stop_reason` says why |
| `error` | The reply failed. `text` is what had arrived. For a task, the task failed |
| `interrupted` | The bridge restarted mid-stream |

Possible `meta` keys:

- `effort`
- `finish_reason`
- `usage`
- `error_code`
- `stop_reason`
- `stream_seq`: the id of the reply's terminal event (used by resume)
- for tasks: `task` (the request text), `job`, `session`, `seconds`
- `web_search` on a user message that asked for it
- `tools` and `tools_truncated` on assistant replies (see "Tool calls on messages")
- `steps` and `steps_truncated` on assistant replies (see "Steps")

Every message also has a top-level `attachments` list, which is `[]` when there are none:
`[{"id", "name", "mime", "size", "kind": "image|file", "width"?, "height"?, "preview_url"?}]`.

## Steps

**Contract summary for the client** (capability `steps: true`):

- Each assistant reply has an ordered list of **steps**: the model's thinking and the tools it ran. It streams as
  SSE events and is saved as `meta.steps`. A resume `snapshot` carries `steps`.
- **Events** (each with an `id:` line, so `Last-Event-ID` replay covers them):
  - `step.start` `{"message_id", "step"}`: a new step, in timeline order.
  - `step.delta` `{"message_id", "id", "text"}`: thinking text to append to step `id`.
  - `step.end` `{"message_id", "step"}`: the step's final form. **Replace** your copy with it (for thinking, its
    `text` is the whole text). A tool's `step.end` can arrive after a later step's `step.start`, or after the reply
    text, because the bridge looks the result up once the tool has finished. Every step gets its `step.end` before
    `done`, `error` or `stopped`.
- **Step object:**
  ```json
  {"id": "s2", "kind": "thinking|tool", "state": "running|done|failed", "started_at": 1794730113880, "ended_at": 1794730116651,
   "offset": 13,
   "text": "thinking text (kind thinking only)", "truncated": false,
   "tool": {"name": "terminal", "label": "echo hi", "emoji": "💻", "call_id": "call_974c…",
            "input": {"command": "echo hi"}, "output": "hi", "exit_status": 0, "error": null,
            "truncated": false, "details": true}}
  ```
  - `id`: `s1`, `s2`, … within the message. `offset`: characters of reply text written when the step started.
    `started_at` and `ended_at` are bridge-clock Unix ms; `ended_at` is `null` while running.
  - `tool.input`: the tool's arguments as JSON (an object) when they parse, else a string. `tool.output`: the result
    text (for results shaped `{"output"|"content"|"result"|"stdout"|"text": …}`, that field; otherwise the raw
    result). `tool.exit_status`: an integer exit code when the tool reports one. `tool.error`: Hermes' error text
    or `null`.
  - `tool.details: false`: the bridge could not read the call from Hermes' session store. `input` is then the
    stream's short preview (`label`), and `output` is `null`.
  - `state: "failed"`: Hermes reported a failure, there is an `error`, `exit_status` is not 0, or the reply ended
    with an error or a stop while the step ran.
- **UI mapping:** the one-line glimpse is the newest running step ("Thinking" for `thinking`, else
  `Running <tool.name>` or the `label`). The expanded timeline is `steps` in order. A tool row opens INPUT
  (`tool.input`) and OUTPUT (`tool.output`).
- **Old clients:** `status` events and `meta.tools` are unchanged and still sent.
- **Resuming after a restart (round 6 B1):** a reader that resumes with `Last-Event-ID` N hears only the step events
  after N, so a reply that ran 10 tools may deliver just the last one or two. Merge those into the message's stored
  `meta.steps` (saved at least every 2 s while it runs, and complete at the end) by step `id`, live copy winning, and
  never let an in-memory list replace the stored one. A reader from id 0 (or a `snapshot`) gets the whole list. The
  bridge keeps every step (up to 128) in `meta.steps`, the resume buffer and the stored snapshot; checked with a
  10-tool reply in `test_steps.py`.

### What Hermes exposes (checked 15 November 2026)

- **Tools:** Hermes' stream names each tool, with a short `label` preview and the call id
  (`hermes.tool.progress` `running`/`completed`). It carries **no arguments and no results**. Both are in Hermes'
  session store as soon as the tool completes: the stored assistant row has `tool_calls[].function.arguments`, and
  the tool row has the result (for `terminal`, `{"output", "exit_code", "error", "cwd"}`). The bridge reads them
  through Hermes' own API (`GET /api/sessions/{id}/messages?order=latest`; the session id is the
  `X-Hermes-Session-Id` response header), with the same key, without changing Hermes. A real request that ran
  `echo hi` came back with input `{"command": "echo hi"}`, output `hi` and exit status 0.
- **Thinking: depends on the model.** Hermes passes structured reasoning on as `reasoning_content` (or `reasoning`)
  deltas when its model returns any, and the bridge turns exactly that text into `thinking` steps. It never writes
  thinking text of its own. Whether a turn has any depends on the model, the provider and the request: a model may
  return none at all, or only for some turns. On 15 November 2026 a model tested through CLIProxyAPI returned
  short reasoning summaries on some turns, titled in markdown, for example `**Reviewing coding request**`, and none on
  a plain chat question. These summaries are what the model chose to show, not its full hidden reasoning. A client
  renders the text as given (it is markdown), may show a running step's newest `**Title**` line as its glimpse, and
  otherwise shows "Thinking" while nothing is running, then "Running <tool>". The reply's own preamble text (for
  example "Let me check.") stays in the reply.

### Safety: truncation and redaction

Applied on the server to every tool input and output, thinking text and tool label, before anything is stored,
streamed or pushed:

- **Size:** each tool input and output is cut to 8,192 characters (`step_limits.io_chars`) and flagged
  `tool.truncated: true`. A JSON input over the limit becomes its cut JSON text. Thinking text is capped at 16,384
  characters per step (`truncated: true`). At most 128 steps per message (`steps_truncated` counts dropped ones).
- **Terminal escapes:** ANSI/VT escape sequences (colours, cursor moves, OSC titles) and other control characters
  except newline and tab are removed.
- **Secrets** are replaced with `[redacted]`:
  - PEM private key blocks (`-----BEGIN … PRIVATE KEY-----` … `-----END …-----`), as `[redacted private key]`
  - `Authorization:` / `Proxy-Authorization:` values (keeping `Bearer`/`Basic`/`Token`), and `Bearer <token>`
  - token formats: `sk-…`/`rk-…`/`pk-…` (including `sk-ant-`, `sk-proj-`), `ghp_`/`gho_`/`ghu_`/`ghs_`/`ghr_`,
    `github_pat_`, `glpat-`, Slack `xox?-`, AWS `AKIA`/`ASIA`, Google `AIza`, Telegram bot tokens and JWTs
  - assignments whose name looks secret: `NAME=value` or `NAME: value`, where the name contains `API_KEY`,
    `SECRET`, `TOKEN`, `PASSWORD`, `PASSWD`, `PASSPHRASE`, `PRIVATE_KEY`, `ACCESS_KEY`, `CLIENT_SECRET`,
    `CREDENTIAL(S)`, `AUTH_KEY`, or ends in `_KEY`, `_PASS` or `_PWD` (any case, quoted values included)
  - JSON `"…password|secret|token|api_key|credential…": "value"`, and in parsed JSON input any string under such
    a key
  - `--password`/`--token`/`--api-key`/`--secret` flag values, and the password in `scheme://user:password@host`
- Redaction is pattern-based, so it can miss secrets in unusual formats. Treat steps as sensitive anyway: they are
  only served to the app's key.
- **Push notifications never contain steps, tool input or tool output.** Their preview comes from the reply text
  only, and it goes through the same redaction.

### Tool calls on messages

`meta.tools` holds the reply's tool calls, oldest first. It is saved while the reply streams (at least every 2 s)
and when it ends, so tool cards survive a reload and a resume.

```json
"meta": {"tools": [{"id": "call_abc", "tool": "terminal", "label": "df -h /mnt/storage", "emoji": "💻",
                    "state": "done", "offset": 42, "started": 1794691021626, "ended": 1794691023810}]}
```

- `id`: Hermes' `toolCallId` (`""` for approval notes). `tool` is at most 80 characters, `label` at most 200 (the
  start event's preview, kept when the call completes), `emoji` at most 8.
- `state`: `running`, `done`, `failed` or `approval`. When a reply ends with calls still running, they become
  `done` if the reply is `complete` and `failed` otherwise.
- `offset`: how many characters of reply text had been written when the call started. Draw the card there.
- `started` and `ended` are bridge-clock Unix ms. `ended` is absent while a call runs.
- At most 64 calls per message; older ones are dropped and counted in `tools_truncated`.
- **Failed calls:** Hermes (2026-11) reports only `running` and `completed`, without a result flag, so today every
  finished call is `done`. If Hermes ever sends `status: "failed"`/`"error"`, `error`, `is_error: true` or
  `ok: false`, the bridge forwards `state: "failed"` in the `status` event and saves it the same way.

| Route | Request | Response |
|---|---|---|
| `GET /api/conversations?limit=30&cursor=&pinned=` | `limit` 1–100 (default 30); `cursor` from the previous page; `pinned` `true`/`false` filter (omit it for all) | `200 {"conversations": [...], "next_cursor": "…" \| null}`, ordered by `updated` (newest first). Errors: `400 bad_limit`, `bad_cursor`, `bad_pinned` |
| `POST /api/conversations` | `{"title"?: "…"}` | `201 {"conversation"}`. Without a title, it is `"New chat"` (`title_source: auto`), and the first message names it |
| `GET /api/conversations/{id}?limit=50` | `limit` 1–200 | `200 {"conversation", "messages": [...oldest first], "has_more"}`: the newest `limit` messages |
| `GET /api/conversations/{id}/messages?before=<message_id>&limit=50` | `before` is optional | `200 {"messages": [...oldest first], "has_more"}`: the `limit` messages just older than `before`. An unknown `before` gives `404` |
| `PATCH /api/conversations/{id}` | `{"title"?: "…", "pinned"?: bool}`, at least one | `200 {"conversation"}`. Whitespace in the title is collapsed. A title sets `title_source: user`, after which no automatic title replaces it. Errors: `400 bad_title`, `title_too_long` (> 120), `bad_pinned`, `nothing_to_change` |
| `DELETE /api/conversations/{id}` | — | `200 {"ok": true}`, or `404`. Its messages are deleted with it |
| `DELETE /api/conversations/{id}/messages/{mid}` | — | `200 {"ok": true}`, or `404` |
| `GET /api/conversations/search?q=…&limit=30` | `q`: 1–200 characters | `200 {"results": [{"conversation", "message_id", "snippet", "match"?}]}`. Title matches come first (`message_id: null`, `snippet` = the title), then message matches (SQLite FTS5, prefix match on each word, best match per conversation). A message `snippet` is plain text (markdown removed: table rows become `cell · cell`, code fences, emphasis, headings and list markers go, links keep their text), at most 160 characters, centred on the first matching word, with `…` where it was cut. Optional `match`: `[start, end]` character offsets of that first matching word inside `snippet`, counted in Unicode code points (these equal Dart `String` indexes unless the snippet has characters outside the BMP, such as emoji), or `null` when no word matched (for example a phrase match across punctuation). Clients that ignore `match` keep working. Errors: `400 empty_query`, `query_too_long`, `bad_limit` |

Messages are ordered by `created`, then by insertion. Message order is stable.

**Titles:**

- Titles always describe the **user's first message**, never the assistant's reply.
- The first user message gives the rule-based title: a leading greeting ("hey", "hi there", "okay", the assistant's
  name) and "can you"/"please"/"I want to" are dropped when at least two words remain, the first letter is
  capitalised, a final `?` goes, and it is cut at a word to 40 characters (with `…`). This is the whole rule with
  `titles: "simple"`, and the title every chat shows until a generated one arrives.
- With `titles: "model"` (round 6; the default whenever `TITLE_API_KEY` is set), the first
  complete reply also starts one small non-streaming call to an OpenAI-compatible endpoint (CLIProxyAPI, model
  `TITLE_MODEL`, 20 s budget) given only the user's first message: a **3–4 word Title Case title** for about 100
  tokens, measured 1.5–2.4 s ("NAS Disk Space Check", "Nightly Photo NAS Backup", "Red Pandas Overview").
- With `titles: "hermes"`, the same call goes to Hermes instead (it runs the whole agent: about 12,700 prompt tokens).
- A generated title must have 2–5 words (3–4 are asked for), else the rule-based one stays. It replaces the title
  only while `title_source` is still `auto`, and sets it to `hermes` ("generated"; both modes). `done` carries
  `title_pending: true` while one is on its way, and a `conversation.title` event announces it (see "Events").
- A live-only chat gets its rule-based title from its first spoken user turn when the transcript is imported, and
  with `model`/`hermes` titles the same call is started from that turn.

## Live calls linked to a chat

`POST /api/session` (existing route), with the new optional `conversation_id`:

```json
{"offer": "v=0…", "voice": "cove", "conversation_id": "optional"}
```

- With `conversation_id`, the chat is checked before codex starts. An unknown chat gives `404 not_found`, a
  malformed id gives `400 bad_conversation_id`, and an unavailable history gives `503 history_unavailable`.
- Delegated Hermes tasks in that call start with the chat's newest 8 messages as context (at most 2000 characters
  each and 6000 in total).
- The chat becomes `kind: live`.
- Success: `200 {"session", "answer", "conversation_id"}`. `conversation_id` is `null` when the call is not linked.
- **Task results are saved by the bridge.** Since round 5 (capability `task_messages`) a delegated job of a linked
  call is a `source: task`, `role: assistant` message from the moment it starts, streamed like a reply; see "Live
  tasks in the chat". Its `client_id` is `job:<session>:<job>`, `meta` holds `task`, `job`, `session` and (at the end)
  `seconds`. A failed job ends with `status: error`, keeping any text that arrived. (Older bridges added the message
  only at the end, with empty text on failure.)
- `GET /api/job/{sid}/{jid}` now also returns `markdown` (Hermes' original reply, for the live canvas) next to
  `answer`, the voice-ready plain text:
  `{"status": "running|done|failed", "answer", "markdown", "seconds", "status_event"?, "partial"?}`.
- **Progress while a task runs** (capability `job_progress`): `status_event` is the newest Hermes tool step, in the
  same shape as the chat `status` event (`{label, state, tool, id, emoji}`; `info` notes are left out). `partial`
  is Hermes' reply text so far (markdown, at most 32,000 characters; it may still change in the final answer). Both
  are present only while `status` is `running`, and only once Hermes has sent something. Delegated tasks now
  stream from Hermes for this; the result is the same as before.
- `GET /api/session/{sid}/jobs` lists a call's jobs in the same shape, plus `id` and `request` (see "openai
  backend"; it works for codex calls too).
- **Small talk is answered without Hermes.** A task of at most 12 words that is only greetings, goodbyes, thanks and
  filler (and contains at least one greeting, goodbye or thanks) is `done` at once with `answer` "Nothing to run for
  this: it is small talk. Reply to the user yourself, briefly." and an empty `markdown`. It is not saved to the chat
  and sends no push. The voice prompt also tells GPT-Live not to delegate these.
- Saved task results carry `meta.usage` (`input_tokens`, `output_tokens`, `total_tokens`, `duration_ms`, `ttft_ms`,
  `tool_count`, `model`) when Hermes reported usage.

**Start errors on `/api/session`.** These are based on the codex app-server's own texts, such as "You've hit your
usage limit…", "Usage limit reached…", `rate_limit_reached`/`usage_limit_reached`, or "Your access token could not be
refreshed… Please log out and sign in again." / "please re-run `codex login`".

| Status | Body | Meaning |
|---|---|---|
| 429 | `{"error": "usage_limit", "code": "usage_limit", "message": "GPT-Live usage limit reached", "retry_after_s": 7200 \| null}` | The ChatGPT plan's GPT-Live limit was reached. A `Retry-After` header is set when the wait is known |
| 502 | `{"error": "login_expired", "code": "login_expired", "message": "…sign in again on the server"}` | The server's ChatGPT login has expired or was revoked. The operator has to log in again |
| 502 | `{"error": "could not start GPT-Live (is the ChatGPT login still valid?)", "code": "start_failed", …}` | Any other start failure (the old response) |
| 400 | `code` `bad_offer`, `bad_request` | Invalid input |

Usage-limit `error` events that arrive on the data channel after `session.started` still come to the client
directly and are classified there.

`POST /api/conversations/{id}/live-transcript`: the client posts the finished voice turns when the call ends (the
bridge never sees voice transcripts).

```json
{"session": "id from /api/session (optional, recommended)",
 "turns": [{"id": "t1", "role": "user|assistant", "text": "…", "created": 1794691021626}],
 "tasks": [{"id": "job id", "request": "…", "answer": "markdown", "status": "done|failed", "seconds": 12, "created": 1794691021626}]}
```

- `turns` are stored as `source: voice` with status `complete`. At most 500 turns per request, each up to 8000
  characters. Empty texts are skipped.
- **One message per spoken turn.** Send the turns in spoken order. Within a run of one speaker (no turn of the other
  speaker in between), the bridge folds:
  - an entry that the next one repeats and extends ("Alright, bye" → "Alright, bye for now."; compared without case
    or punctuation, so a cut inside a word counts too), an exact repeat, and a shorter copy after a longer one;
  - an assistant entry of at most three words without closing punctuation that is followed within 20 s by another
    (a reply GPT-Live cut off and restarted);
  - and joins what is left of entries that start within 20 s of each other with a space.

  The merged message keeps the first entry's `id` (so re-posting still skips it) and `created`. Entries more than
  20 s apart stay separate messages, and the same words said twice with the other speaker in between stay two
  messages. The app does the same before posting (`mergeVoiceTurns`), so the server rule is a safety net for older
  builds.
- `created` is optional. When the newest `created` in the request (turns and tasks) is more than 60 s in the future,
  every `created` is shifted back by the same amount, so the turns keep their order and spacing. After that, a value
  that is missing, more than 7 days in the past or more than 60 s in the future is replaced with the server time.
- A turn `id` makes the post idempotent: a turn whose `id` is already in the chat is skipped.
- `tasks` is optional (at most 50; `answer` up to 32,000 characters). Send tasks only for calls that were **not**
  linked. For linked calls, include `session`; tasks the bridge already saved (same `session` and job `id`) are then
  skipped.
- Response: `200 {"added": n, "skipped": m, "merged": k, "conversation": {...}}`. `merged` counts the entries folded
  into another turn (not added, not skipped).
- Errors:
  - `400` with `code` `bad_transcript`, `bad_turn`, `too_long`, `bad_id`, `bad_task` or `bad_session`
  - `413 too_many_items`
  - `404 not_found`

## openai backend

The operator chooses the backend with `LIVE_BACKEND` (`codex`, `openai`, or `auto`: codex when its login exists,
else openai when `OPENAI_API_KEY` is set). Read `live_backend` from capabilities, or `backend` from the
`/api/session` response. The `openai` backend uses the documented OpenAI Live API with the operator's own project
key. **The key stays on the server**: the app never receives it and never talks to the OpenAI REST API. As with codex,
audio and the `oai-events` data channel go straight between the app and OpenAI over WebRTC. Open WebUI's
`/v1/realtime` always uses codex.

### Flow

1. The app makes its WebRTC offer exactly as today (mic track, `oai-events` data channel created before the offer,
   ICE gathering complete) and calls `POST /api/session` `{offer, voice?, conversation_id?}`.
2. The bridge sends `POST /v1/live/sessions` with
   `{"session": {"model", "instructions", "audio": {"output": {"voice"}}, "delegation": {"type": "client"}, "input"?},
   "transport": {"type": "webrtc", "sdp": <offer>}}`. `input` holds the linked chat's newest 8 messages, so the voice
   model knows the typed thread. OpenAI answers `201 {"session": {"id"}, "transport": {"sdp"}}`.
3. The bridge answers `200`:
   ```json
   {"session": "…", "answer": "v=0…", "conversation_id": "…|null", "backend": "openai", "voice": "marin",
    "server_delegation": true, "server_transcript": true, "max_seconds": 1800}
   ```
   Apply `answer` as the remote description, then **wait for `session.started`** on the data channel. The event
   name is the same as with codex.
4. The bridge attaches a server-side connection to the session (a "sideband" WebSocket) and **runs every delegation
   itself**: on `session.delegation.created` it takes the user's newest spoken turn as the task (with the call
   transcript before it as context), runs it as a Hermes job, and gives the result to the voice model with
   `session.commentary.append`, which the model paraphrases aloud. The task result is saved to a linked chat as
   today (`source: task`, `client_id: job:<session>:<job>`), and the push rules are unchanged.
5. To hang up, call `POST /api/stop {session}` as today. The bridge sends `session.close` and waits up to 5 s for
   `session.closed`, which carries the final usage. Then close the peer connection. The app may also send
   `session.close` on its own data channel; both are safe.

### What the app must do differently (client-visible differences)

| Area | codex backend | openai backend |
|---|---|---|
| `/api/session` response | `{session, answer, conversation_id, backend: "codex"}` | Adds `voice`, `server_delegation: true`, `server_transcript` and `max_seconds` |
| Voices | `cove`, `arbor`, … (`live_backends.codex.voices`) | `marin`, `meridian`, … (`live_backends.openai.voices`). A codex name is mapped to a similar API voice (`cove`→`marin`, `arbor`→`meridian`, `juniper`→`gleam`, `maple`→`willow`, `spruce`→`stone`, `ember`→`cinder`, `vale`→`vesper`, `breeze`→`quartz`, `sol`→`delta`, `aube`→`brise`, `bubbie`→`ripple`); anything else gets the operator's `OPENAI_LIVE_VOICE` |
| Ready event | `session.started` | `session.started` (same) |
| Delegation | The app gets `delegation.created`, calls `/api/delegate`, polls `/api/job`, sends `delegation.context.append` | **The app does nothing.** No `delegation.created` arrives. OpenAI sends `session.delegation.created` instead, which has no task text. **Do not** answer it from the app: the bridge already does, and a second answer would be spoken twice |
| Task cards | From the app's own `/api/delegate` jobs | Poll `GET /api/session/{session}/jobs` (below) |
| Captions | `turn.created`, `input_transcript.added`, `output_transcript.added`, `turn.done` | None of those. OpenAI sends `session.input_transcript.delta` (user) and `session.output_transcript.delta` (assistant), each `{delta, start_ms, end_ms}`, with **no turn boundaries**: start a new caption bubble when the role changes |
| Transcript import | The app posts `/api/conversations/{id}/live-transcript` after the call | With `server_transcript: true` (a linked call), the bridge saves the spoken turns itself when the call ends (`source: voice`, `client_id: turn:<session>-<n>`). **Do not post them again**: the app's turn ids would differ, so they would be saved twice. Unlinked calls are not saved |
| Mute | `input_audio.pause` / `input_audio.resume` | `session.input_audio.mute` / `session.input_audio.unmute` (acknowledged with `…muted` / `…unmuted`). Muting keeps the call, and its billing, running |
| Interruptions and turn taking | Native to GPT-Live | Native to GPT-Live (full duplex). There is no turn-detection setting to send |
| Usage | Not reported | `session.usage.updated` `{usage: {seconds}}` on the data channel (cumulative voice seconds; each event replaces the last) |
| End of call | `thread/realtime/closed` (server side) | `session.closed` `{reason, usage}` on the data channel. `reason` is `close_requested`, `expired` (the duration limit), `content` (a safety filter), `remote_hangup` or `connection_lost` |
| Time limit | `BRIDGE_CALL_SECONDS` | `max_seconds` from the response: the bridge closes the call then (`session.closed` arrives with `close_requested`). It is the smaller of the per-call limit and what is left of the day's budget |
| Data-channel errors | `error` events, classified by the app | `error` `{error: {type, code, message, param, client_event_id}}`. Some moderation errors cut the current speech without ending the call |
| Data-channel client events | `session.update`, `response.create`, … | Do **not** send codex events (`delegation.context.append`, `input_audio.pause`, `response.create`). OpenAI rejects unknown commands with an `error` event |

`GET /api/session/{session}/jobs` → `200 {"session", "backend", "sideband"?, "jobs": [{"id", "status": "running|done|failed",
"request", "answer", "markdown", "seconds"}]}`, oldest first. `request` is the transcribed request, `answer` the
voice-ready text and `markdown` Hermes' original (both empty until `done`). `sideband` (openai only) is `attached`,
`connecting`, `lost` (reattaching) or `failed` (delegations and the time limit are off for this call; show a notice).
It works for codex calls too. Polling it counts as watching the call, so finished tasks are not pushed while the app
polls. `404 not_found` once the call has ended. `GET /api/job/{session}/{job}` also works for these jobs.

### Start errors (openai backend)

| Status | `code` | When |
|---|---|---|
| 429 | `budget_exceeded` | Less than a minute of the operator's daily budget (`OPENAI_DAILY_MINUTES`) is left. `retry_after_s` (and `Retry-After`) = seconds until local midnight. Nothing is sent to OpenAI |
| 429 | `usage_limit`, `reason: "quota"` | OpenAI `insufficient_quota`, `credit_balance_exhausted` or a spend/usage-limit code. `retry_after_s` is `null`: retrying won't help until the operator adds credit |
| 429 | `usage_limit`, `reason: "rate_limit"` | Any other OpenAI 429 (for example too many concurrent sessions). `retry_after_s` from OpenAI's `Retry-After` header, else `null` |
| 502 | `auth_failed` | OpenAI answered 401/403: the server's key is wrong, revoked or lacks GPT-Live access. **Not** `login_expired` (that one means the ChatGPT login of the codex backend). The app's own key is fine (that would be a 401) |
| 502 | `start_failed` (`error`: "could not start GPT-Live with the OpenAI API") | Any other failure: 4xx/5xx, network, timeout, or a reply without an SDP answer. `upstream_status` holds OpenAI's HTTP status when there was one |
| 503 | `openai_unconfigured` | `LIVE_BACKEND=openai` without `OPENAI_API_KEY` |

Every openai start error carries `backend: "openai"`. OpenAI's own error text is never passed on.

### Cost

$0.05 per minute of voice, billed per second. Each session creation bills 15 seconds up front, credited once the
call runs. Delegated work runs on the operator's own Hermes, so it adds no OpenAI cost. Show
`live_backends.openai.minutes_left_today` if you want to warn the user before a call.

### Verified and assumed parts of the OpenAI Live schema

Checked on 15 November 2026 against
[Getting started](https://developers.openai.com/api/docs/guides/live),
[WebRTC (`?api=live`)](https://developers.openai.com/api/docs/guides/voice-webrtc?api=live),
[Delegation and tools](https://developers.openai.com/api/docs/guides/live-delegation),
[Managing sessions](https://developers.openai.com/api/docs/guides/live-conversations),
[Server-side controls (`?api=live`)](https://developers.openai.com/api/docs/guides/voice-server-controls?api=live),
[Cost (`?api=live`)](https://developers.openai.com/api/docs/guides/voice-latency-cost?api=live),
[Error codes](https://developers.openai.com/api/docs/guides/error-codes) and the
[gpt-live-1 model page](https://developers.openai.com/api/docs/models/gpt-live-1).

**Verified (stated in those guides):**

- The request: `POST /v1/live/sessions`, JSON body `{session, transport: {type: "webrtc", sdp}}`, project key as
  `Authorization: Bearer`. The reply: `201 {"session": {"id"}, "transport": {"type": "webrtc", "sdp"}}`.
- Session fields: `model`, `instructions` (up to 16,384 tokens), `audio.output.voice` (default `marin`; the 21
  listed voices), `delegation: {type: "client"}`, `input` (up to 128 messages and 8,192 tokens, one text part each:
  `input_text` for user, `output_text` for assistant), `store` (default `false`, so it is not sent). Leave
  `audio.format` out with WebRTC.
- Data channel label `oai-events`. Wait for `session.started`, and never send `session.start`. `session.close` →
  `session.closed` `{reason, usage}`. `session.usage.updated` `{usage: {seconds}}`. Transcripts:
  `session.input_transcript.delta` / `session.output_transcript.delta` `{delta, start_ms, end_ms}`, with no item ids
  or turn ends. Mute: `session.input_audio.mute` / `unmute`. `error` `{error: {type, code, message, param,
  client_event_id}}`.
- Client delegation: `session.delegation.created` `{offset_ms, delegation: {id, type: "delegation", target:
  "client"}}`, without task text. Results go back as `session.commentary.append` `{event_id, delegation_id,
  content}` (spoken, paraphrased) or `session.thinking.append` (silent), with plain-string content of at most 500
  tokens. The bridge clips results to 1,800 characters.
- Sideband: `wss://api.openai.com/v1/live/sessions/{id}/attach` with the same key. It replays the last 3 s on
  attach (the bridge deduplicates by `event_id`) and carries reflected audio (`session.input_audio.append`,
  `session.output_audio.delta`), which the bridge ignores.
- Pricing $0.05/min billed per second, 15 s initialization charge, concurrency limits per tier (Free unsupported).
  HTTP error codes: 401 invalid key; 429 with `insufficient_quota` type, or `credit_balance_exhausted` /
  `*_spend_limit_exceeded` / `*_usage_limit_exceeded` codes, or a plain rate limit with `Retry-After`.

**Assumed (not stated, or not testable without a key; implemented defensively):**

- The Live API reference pages (`/api/reference/resources/live/...`) were not readable. The schema above comes from
  the guides and their SDK samples.
- **Not run against the real API.** The development setup has no OpenAI key, so the bridge's openai path is tested only
  against a mock that follows the docs.
- The exact body of Live session-creation errors. The bridge reads `error.type` and `error.code` as on the rest of
  the API, falls back to the HTTP status, and never relies on the message text.
- That the sideband can attach right after creation, before the app's WebRTC connection is up. The bridge retries
  the attach 4 times with a growing delay and reports `sideband: "failed"` if all fail.
- How soon the user's transcript arrives relative to `session.delegation.created`. The bridge waits 1 s, then takes
  the newest user turn.
- The automatic spoken acknowledgement of a delegation is left on (no `acknowledgement_delay_ms`), the same as
  codex's `delegationAckFiller`.
- The duration limit OpenAI applies itself (close reason `expired`) is not documented. The bridge's own
  `max_seconds` is the one to rely on.
- The voice mapping from codex names is a choice made from the voice descriptions, not a documented equivalence.

## Attachments

Check `attachments` in capabilities. Upload each file first, then send the ids with `/api/chat`.

### Upload

`POST /api/uploads`, sent as `multipart/form-data` with **one** part named `file` (`filename`, or RFC 5987
`filename*=UTF-8''…`, which wins, plus a `Content-Type`). An optional text part `conversation_id` ties the upload to
an existing chat. The 1 MiB JSON cap does not apply here.

`201`:

```json
{"id": "up_9f2c…", "name": "IMG_2041.jpg", "mime": "image/jpeg", "size": 412233, "sha256": "…", "kind": "image",
 "width": 2048, "height": 1536, "preview_url": "/api/uploads/up_9f2c…/preview", "created": 1794700000000}
```

- `width`, `height` and `preview_url` are given for images only. `kind` is `image` for JPEG, PNG and WebP, and
  `file` for everything else.
- **The type is sniffed from the bytes.** The declared type and the name only choose between formats that share a
  container: the office ZIP formats, `application/json` against `text/plain`, and the `text/*` subtypes.
  - Images must decode (the bridge makes the preview from them) and be at most 8192 px on each edge.
  - Accepted documents (only with a Hermes workspace; see `attachment_limits.mimes`): PDF; UTF-8 text without NUL
    bytes (`text/plain`, `text/markdown`, `text/csv` and other common subtypes, else `text/plain`); JSON that
    parses; DOCX/XLSX/PPTX/ODT/ODS/ODP.
  - **Refused as executable:** ELF, PE (`MZ`), Mach-O, Java class, WebAssembly and DEX binaries, any file starting
    with `#!`, and office files that contain macros (`vbaProject.bin`, ODF `Basic/`) or embedded programs. Stored
    files are never executable (mode 600). In Hermes' workspace, names with a runnable extension (`.sh`, `.exe`,
    `.js`, `.bat`, …) get `.txt` added.
- Names: the path and control characters are removed, leading dots too, and the name is cut to 120 characters.

| Status | `code` | When |
|---|---|---|
| 400 | `bad_upload` | Not multipart, no `file` part, several files, an unknown part, an empty file, or an unreadable body |
| 401 | `unauthorized` | |
| 404 | `not_found` | `conversation_id` is unknown |
| 413 | `too_large` | Over `image_mb` / `file_mb` (checked from `Content-Length` first, then while reading) |
| 415 | `unsupported_type` | Not an accepted type, an image that does not decode, or an executable |
| 507 | `quota_exceeded` | The chat's uploads would pass `conversation_mb`, or all uploads would pass the server's total (`LIVE_UPLOAD_TOTAL_MB`) |
| 503 | `uploads_unavailable` | Turned off, history unavailable, or neither vision nor a Hermes workspace is set up |

### Other upload routes

- `GET /api/uploads/{id}`: the original bytes, `Content-Disposition: inline; filename*=…`,
  `Cache-Control: private, max-age=86400`, and the sha256 as `ETag` (`If-None-Match` → `304`). Text files are
  always served as `text/plain; charset=utf-8`, with `Content-Security-Policy: sandbox`, so an uploaded HTML file
  can never run on the bridge's origin.
- `GET /api/uploads/{id}/preview`: a JPEG of at most 512 px on the long edge (metadata not copied), for images only
  (`404` for files). The same cache headers apply, with ETag `<sha256>-p`.
- `DELETE /api/uploads/{id}` → `204`. `409 in_use` when a message uses it: delete the message instead.
- **Lifetime:** an upload that no message uses is deleted after `unused_hours` (24). Uploads that a message uses
  are deleted with that message or its conversation, together with their copies in Hermes' workspace. Files are
  stored once per sha256.

### What Hermes receives

- **Images, with `vision: true`:** the newest user turn that has images carries them as OpenAI-style content
  parts: `[{"type": "text", …}, {"type": "image_url", "image_url": {"url": "data:image/…;base64,…"}}]`. An
  image-only message gets the text "(The user sent only the attached image.)". Older images in the history window
  become a note: `[image: IMG_2041.jpg, sent earlier in this chat]`. Checked on 15 November 2026: Hermes'
  `/v1/chat/completions` (through `hermes-api-bridge`) takes `image_url` parts and its model read a test image
  correctly.
- **Documents, and images with `vision: false`:** copied to `HERMES_UPLOAD_DIR/<conversation_id>/<name>` (mode
  640) when the message is sent. The text Hermes receives gets the line
  `The user attached report.pdf (1.2 MB, application/pdf) at <HERMES_UPLOAD_PATH>/<conversation_id>/<name>.`.
  Hermes reads the file with its own tools; the bytes never go into the prompt. If the copy failed, the note says
  that the file could not be given to Hermes.
- Live calls linked to a chat see these notes in the seeded history, without images.

## Link previews

`GET /api/link-preview?url=<http(s) URL>` (capability `link_preview`) →
`200 {"url": "<final URL after redirects>", "kind": "page"|"image", "title", "site_name", "image", "favicon", "width",
"height"}`. Every field except `url` and `kind` may be `null`. `image` and `favicon` are `data:` URLs, and only when
their bytes match a JPEG, PNG, GIF, WebP or ICO signature. The bridge never decodes images from websites, and SVG,
AVIF and other types are never returned.

- `"kind": "page"`: an HTML page (or another non-image document). `image` is its `og:image`, at most 300 KB.
- `"kind": "image"` (capability `link_preview_images`): the URL itself is an image, as in a reply's markdown
  `![alt](https://…)`. `image` is that picture, at most 3 MB; `title` and `favicon` are `null` and `site_name` is the
  image's host. A picture that is too large (declared or actual), truncated, of another type or whose bytes do not
  match its type gives `"image": null` (cached 5 minutes), so the app shows its fallback. Attribution comes from the
  markdown (`[![alt](image)](source page)`), never from the image host.
- `width`/`height`: the size of `image` read from its PNG/GIF/WebP/JPEG header (no decoding; EXIF rotation is not
  applied), as a layout hint, or `null`.

- `title`: `og:title`, else `twitter:title`, else `<title>`. `site_name`: `og:site_name`, else the host. `image`:
  `og:image` (or its `secure_url`), else `twitter:image`. `favicon`: the first `<link rel="icon">`, else
  `/favicon.ico`.
- **SSRF protection:** only `http`/`https` on ports 80, 443, 8080 and 8443, with no `user:password@`. Hosts such as
  `localhost`, `*.local`, `*.lan`, `*.internal`, `*.home.arpa` and `*.ts.net` are refused. The host's DNS answers
  must all be public addresses: private, loopback, link-local, CGNAT/tailnet (`100.64.0.0/10`), multicast and
  reserved addresses are refused, and the connection goes to the address that was checked. At most 3 redirects,
  each checked again. At most 512 KB of HTML is read; a body whose
  `Content-Length` is over the limit is not read. 5 s to connect and between reads, 8 s per request and 10 s in total. Proxy settings from the
  environment are ignored.
- Results are cached in memory: 1 hour for a success, 5 minutes for a failure, at most 256 URLs and 48 MB of
  images (oldest dropped first).
- Errors: `400 bad_url` (not a valid public http(s) URL), `400 blocked_url` (a private target, also found after a
  redirect), `502 fetch_failed` (an HTTP error, timeout or network failure), `503 link_preview_disabled`, `401`.
- Since round 6 a direct image is fetched through the same sized-variant rewrite as the image proxy below, and every
  fetch sends a descriptive `User-Agent` (`ToveBridge/1.0 …`): Wikimedia answered the old generic one with 429.

## Image proxy

`GET /api/image?url=<http(s) image URL>&w=<px>` (capability `image_proxy`, round 6) → `200` with **the picture's own
bytes** (`Content-Type` `image/jpeg|png|gif|webp`), for every remote picture in a reply: markdown images,
`<img src>` in `hermes-html`, and the `image` of `entities` and `news` items. Prefer it over `link-preview` for
images: no base64 JSON to parse, an 8 MB cap instead of 3 MB, and a disk cache.

```json
"image_proxy": {"max_mb": 8, "widths": [320, 640, 960, 1280, 1920], "types": ["image/gif", "image/jpeg", "image/png", "image/webp"]}
```

- `w` (optional, default 1280) is rounded up to one of `widths`. It picks the host's own smaller copy where a
  well-known pattern exists: Wikimedia Commons originals (often 4000+ px, several MB) become standard thumbnails
  (SVG files a PNG rendering), Pinterest `originals/` the `736x/` copy, Unsplash and Pexels get a `w=`. When the
  variant fails, the URL itself is tried. Other hosts are fetched as they are. **The bridge never decodes or
  re-encodes web images**: decode at the frame size on the client (Flutter `ResizeImage`).
- Headers: `X-Image-Width` / `X-Image-Height` (from the image header, a layout hint; absent when unreadable),
  `Cache-Control: private, max-age=604800`, `ETag` (`If-None-Match` → `304`), `Content-Security-Policy: sandbox`,
  `X-Content-Type-Options: nosniff`.
- Same SSRF rules as link previews (public addresses only, checked per redirect, ports 80/443/8080/8443, no
  proxies), at most 6 fetches at once and 2 per host. A `429` from the host is retried once after a short wait.
- Cached on disk in `<data>/image-cache` (7 days, 256 MB, oldest dropped first); failures are remembered for 5
  minutes for a wrong type or size, 60 s for a failed fetch and 20 s after a `429`.
- Errors (JSON): `400 bad_url` / `blocked_url` / `bad_width`, `401`, `413 too_large` (over 8 MB), `415
  unsupported_type` (an HTML page, SVG, AVIF, HEIC, or bytes that do not match the declared type), `502 fetch_failed`
  (an HTTP error, a timeout, a site that refuses bots), `503 link_preview_disabled`. Show the frame's fallback and a
  retry; an older bridge answers aiohttp's plain-text 404 (fall back to `link-preview`).
- Measured 16 November 2026 with 40 real `image_search` results for one query: `link-preview` showed 26, `/api/image`
  31. The remaining failures were Facebook/Instagram crawler pages (not images, now dropped by `image_search`), a
  site that resets bot connections, and brief Wikimedia 429s while uncached thumbnails render.

## Usage

Every assistant reply (capability `usage`) stores `meta.usage`, sent as `usage` in `done` and in resumed streams:

```json
"usage": {"model": "gpt-5.5", "input_tokens": 28160, "output_tokens": 412, "total_tokens": 28572,
          "cached_tokens": 27904, "reasoning_tokens": 96, "model_calls": 2,
          "duration_ms": 9120, "ttft_ms": 7310, "tool_count": 1, "effort": "medium",
          "prompt_tokens": 28160, "completion_tokens": 412}
```

- `input_tokens` / `output_tokens` / `total_tokens`: what Hermes reports for the turn, **summed over every model call
  of its tool loop** (each call re-sends Hermes' system prompt, about 12,600 tokens). `prompt_tokens` and
  `completion_tokens` repeat them for older clients.
- `cached_tokens` (prompt tokens served from the provider's cache), `reasoning_tokens` and `model_calls`: this turn's
  share of Hermes' session counters (`GET /api/sessions/{id}` on Hermes). Present only when that share is known
  exactly: the bridge compares it with the streamed prompt tokens and leaves these three out when they disagree by
  more than 5 % (another client used the same Hermes session).
- `model`: the model Hermes' session used (else `HERMES_MODEL`). `duration_ms`: from the request to the end of the
  reply. `ttft_ms`: to the first visible character (absent when the reply had no text). `tool_count`: tool calls
  in the reply. `effort`: the effort sent, absent when none was.
- Any field may be missing (older replies have only the three old keys, or `null`).

## Usage limits

`GET /api/usage/limits` (capability `usage_limits`; `?refresh=1` skips the cache and asks the providers again) →
`200`, the subscription quota of every account the AI runs on, per provider, for a "Usage and limits" page:

```json
{"observed_at": 1794829213514, "cached": false, "max_age_s": 60, "notes": [],
 "providers": [
  {"id": "codex", "name": "ChatGPT · Codex", "accounts": [
    {"id": "68b3d6787e1a", "label": "t•••@g•••.com", "plan": "plus", "source": "proxy", "used_for": ["chat", "live"],
     "status": "ok", "live": true, "observed_at": 1794829212736, "note": null,
     "windows": [{"id": "5h", "label": "5-hour", "used_percent": 3.0, "remaining_percent": 97.0, "resets_at": 1794840563000, "window_s": 18000, "scope": null},
                 {"id": "weekly", "label": "Weekly", "used_percent": 39.0, "remaining_percent": 61.0, "resets_at": 1795328547000, "window_s": 604800, "scope": null}],
     "credits": {"balance": 0.0, "unlimited": false, "has_credits": false, "currency": null}}]},
  {"id": "claude", "name": "Claude", "accounts": [{"…": "windows 5h, weekly, and scoped weekly ones (scope \"Opus\")"}]},
  {"id": "antigravity", "name": "Antigravity", "accounts": [{"…": "windows per model group (scope \"Gemini Models\")"}]}]}
```

- **Providers** in this order when present: `codex` (ChatGPT/Codex plans), `claude`, `antigravity`, then others by
  id. **Accounts** inside one provider: usable first (`ok`, `warning`, `limited`, `unknown`, `unavailable`,
  `error`, `disabled`).
- **The account list is live.** Every uncached fetch enumerates CLIProxyAPI's auth files through its management API
  and reads the bridge's own ChatGPT login (`CODEX_HOME/auth.json`), so an account added to or removed from
  CLIProxyAPI, or a new GPT-Live login, shows up on the next fetch (at most 60 s later, at once with `?refresh=1`)
  without a bridge restart or config change. Disabled and expired accounts stay in the list with their `status`.
- `label`: the account's email **masked** (`t•••@g•••.com`); two alike get ` (2)`, ` (3)`. `id`: an opaque hash of
  the auth file's name (the live login: its ChatGPT account id), stable while that account exists, so the app can
  key rows and animate additions and removals. Tokens, full emails, auth file names and the proxy's own error texts never appear.
- `source`: `proxy` (a CLIProxyAPI account, which Hermes' chat uses) or `live` (the bridge's own ChatGPT login for
  GPT-Live). `used_for`: `["chat"]`, `["live"]`, or both when GPT-Live runs on an account the proxy also has (shown
  once); `[]` for a disabled account.
- `status`: `ok`; `warning` (a window has 20 % or less left); `limited` (a window is used up, or the provider says
  the limit is reached); `unavailable` (the proxy is not routing to it now: a cooldown, or a model its plan lacks);
  `expired` (the provider refused the account's token: sign it in again; windows from its last reply when known);
  `error` (no data; see `note`); `disabled` (turned off in the proxy; windows still shown when known); `unknown`
  (a provider the bridge has no quota reader for yet, e.g. `gemini-cli`: listed, without windows).
- `windows[]`: `id` (`5h`, `weekly`, `30d`, `weekly-opus`, a provider bucket id …), `label` (`5-hour`, `Weekly`,
  `30-day`, `Daily`), `used_percent` and `remaining_percent` (0–100, one decimal), `resets_at` (Unix ms or null),
  `window_s`, and `scope` (null for the account-wide limit, else what it covers: a model group such as `Gemini
  Models` or `Claude and GPT models`, or `Opus`). Show remaining as the bar, like the reference screenshot.
- `credits`: `{"balance", "unlimited", "has_credits", "currency"}` (Codex: the plan's credit balance; Claude: only
  when extra usage is enabled, then also `used` and `monthly_limit`), else null.
- `live: true`: read just now from the provider; `false`: from the rate-limit headers CLIProxyAPI recorded on the
  account's newest reply (`note` says so; `observed_at` is then that reply's time).
- `plan`: the plan type when the provider says (`plus`, `pro`, `free`, …), else null (Claude and Antigravity do not
  report one here).
- `notes`: problems with a whole source, e.g. "CLIProxyAPI could not be read".
- Cached 60 s on the bridge (`cached: true` on a cache hit; `?refresh=1` always fetches, one fetch at a time). One
  fetch asks every account in parallel (15 s at most);
  the providers' quota endpoints cost no tokens.
- Errors: `401`, `503 usage_limits_unavailable` (no CLIProxyAPI management secret and no ChatGPT login),
  `504 timeout` (the first fetch did not finish).
- Where the numbers come from (checked 16 November 2026): CLIProxyAPI's management API (`/v0/management/auth-files`
  and its `requests/api-call` relay, which adds each account's own token on the server), relaying ChatGPT's
  `backend-api/wham/usage` (the codex CLI's `/status` data: 5-hour and weekly windows, plan, credits), Anthropic's
  `api/oauth/usage` (`five_hour`, `seven_day`, scoped weekly limits, extra usage) and Antigravity's
  `retrieveUserQuotaSummary` (per model group 5-hour and weekly fractions). The bridge's own login is read with its
  saved token and never refreshed here.

## Settings

One versioned JSON object per server (one user per bridge), so every device shows the same preferences.

`GET /api/settings` → `200 {"version": 3, "settings": {...}, "updated": 1794771640683}` with `ETag: "s3"`. Before
the first save: `{"version": 0, "settings": {}, "updated": null}`. `If-None-Match: "s3"` gives `304`.

`PUT /api/settings` with `{"version": 3, "settings": {...}}` **replaces the whole object** when `version` (or the
`If-Match` header, `"s3"`) is still the current version (`0` before the first save). Success: `200` with the new
state (`version` + 1) and its `ETag`.

| Status | `code` | When |
|---|---|---|
| 428 | `version_required` | No `version` and no `If-Match` |
| 409 | `version_conflict` | Another device saved first. The body has `current` (`{version, settings, updated}`): merge your change into it and send again with its version |
| 400 | `bad_setting` | A value or key is not allowed; `key` names it (`"personalization.style"`) |
| 413 | `settings_too_large` | Over 32 KiB as compact JSON |

Known keys (all optional; `null` removes one):

| Key | Value |
|---|---|
| `theme` | `system`, `light` or `dark` |
| `voice` | A voice id, at most 40 characters of `A-Z a-z 0-9 _ -` |
| `read_aloud`, `read_aloud_auto`, `web_search_default` | `true`/`false` |
| `effort_default` | `instant`, `medium` or `high` |
| `language` | At most 35 characters of `A-Z a-z 0-9 -` (a BCP 47 tag) |
| `custom_instructions`, `about_you` | Text, at most 1500 characters each |
| `notifications` | `{"replies"?, "tasks"?, "previews"?}`, each `true`/`false` |
| `personalization` | `{"nickname"? (≤ 60), "occupation"? (≤ 100), "style"?: "default"\|"concise"\|"detailed"\|"friendly"\|"professional"}` |

Any other key must be namespaced, `<namespace>.<name>` (`app.sidebar_collapsed`, `tove.font_scale`: a lower-case
namespace of up to 32 characters, a dot, then up to 64 of `A-Z a-z 0-9 _ . -`), and is stored as it is, with any
JSON value. Unknown keys inside `notifications` or `personalization` are refused.

**What reaches Hermes:** on every `/api/chat`, the bridge adds one short system message built from `nickname`,
`occupation`, `about_you`, `style` and `custom_instructions` (nothing when they are all empty). With `"ui": 1` it
follows the app's UI prompt in the same system message. Changing these starts a new Hermes session for chats that
continue (the history is still sent). Other keys never leave the bridge.

## Suggestions

`GET /api/suggestions?n=4&personalize=true` → `200 {"suggestions": [{"id", "title", "prompt", "category"}],
"personalized": bool}`.

- `n` is 1 to 8 (default 4); anything else gives `400 bad_n`.
- Starters come from a curated pool of about 40 (homelab, media, writing, learning, planning, code, food, health,
  ideas, fun, productivity), at most one per category, taken in turn from a shuffled cycle kept on the server, so
  each new chat sees different ones. `title` is the chip text and `prompt` what to send (or put in the composer).
- With `personalize` (the default), one slot may go to a starter that shares a word with the titles of the 10 most
  recent chats; `personalized` says so. Titles are only compared on the server, never returned or sent to a model.
  No model is called.

## Transcription

`POST /api/transcribe` (capability `transcribe`: `{"max_s", "formats", "model", "prompt_chars"}` or `false`), the
app's "Tove server" dictation engine. `multipart/form-data`:

- `file`: 16-bit PCM WAV, mono or stereo, 8 to 48 kHz, at most `max_s` seconds (default 120; `413 too_large`).
  Anything else gives `415 bad_audio`; a missing part `400 bad_audio`.
- `language` (optional): a BCP-47 tag such as `en-IN`; only the language part (`en`) reaches the model.
- `prompt` (optional, last `prompt_chars` characters kept): the words before this clip and names to spell right.

→ `200 {"text", "duration_s", "model"}`. A clip under 0.15 s answers `{"text": ""}` without a model call.
Errors: `401`, `503 transcribe_unavailable` (not configured), `503 busy` (`STT_MAX_CONCURRENT` reached, with
`Retry-After`), `502 transcribe_failed`, `504 transcribe_timeout`.

The bridge resamples to 24 kHz and sends the audio over an OpenAI Realtime-compatible websocket (`STT_REALTIME_URL`,
for example CLIProxyAPI's `/v1/realtime`, where a ChatGPT subscription pays and there is no API key) with
`turn_detection: null`, commits once and returns `conversation.item.input_audio_transcription.completed`. The audio
is never written to disk and is dropped when the request ends; only its length and the time taken are logged.
Measured 16 November 2026 on six synthesised Indian-English phrases: `gpt-4o-transcribe` 1.3% WER (also with
phone-band noise at 10 dB SNR), `gpt-4o-mini-transcribe` 3 to 4%, `whisper-1` 2.6%; about 1.4 s per clip.

## Entity info

`GET /api/entity/info?name=&hint=&wikipedia=&lang=en` (live key; capability `entity_info`; round 8). The Wikipedia
REST summary of one entity for the entity sheet and the cards' pictures. No Hermes run and no model tokens.
`wikipedia` names a page title. Otherwise `name` is tried as a title (redirects followed), then the best search hit
for `name` + `hint` that is not a disambiguation page. Only `https://<lang>.wikipedia.org` is fetched, through the
link fetcher's SSRF checks, with the agent `ToveBridge/1.0 (…)`. Answers are cached for 24 h (failures for 10 min).

```json
{"name": "Jensen Huang", "title": "Jensen Huang", "description": "Taiwanese-American businessman (born 1963)",
 "extract": "Jen-Hsun \"Jensen\" Huang is …", "image": "https://thumb.wikimedia.org/…/330px-….jpg",
 "original_image": "https://upload.wikimedia.org/…/….jpg", "page": "https://en.wikipedia.org/wiki/Jensen_Huang",
 "source": "wikipedia", "lang": "en"}
```

`image` and `original_image` are Wikimedia URLs only, with the tracking query removed; load them through
`/api/image`, which shrinks Wikimedia thumbnails to a standard width. Errors: 400 `bad_request`, 404 `not_found`,
502 `fetch_failed`, 503 `link_preview_disabled`.

## Entity pictures

Round 9. A reply about named things shows their pictures without Hermes searching for images (no extra tool round).
The UI prompt asks Hermes to name each subject with `entity:` plus its English Wikipedia title as the image URL:

- `![Eiffel Tower](entity:Eiffel_Tower)` on its own line (one main subject);
- `<img src="entity:Tata_Nexon" alt="Tata Nexon">` inside a hermes-html card;
- entities block items with a `"wikipedia"` title (or only a name).

The deltas stream as Hermes wrote them; the app does not draw a non-http image. When the reply is complete, the
bridge sends one `snapshot` with the finished text, then `done`, and stores that text:

- each markdown reference becomes `[![alt](picture)](article)`, each `<img>` gets the picture URL;
- entities items without an http(s) `image` get `image` and `page`; `wikipedia` is removed;
- a reference that has no picture or no answer in time is removed (an entities item keeps no `image`, and the app
  looks it up itself);
- a "Who is X?", "What is a X?" or "Tell me about X" question whose reply has no picture at all gets X's picture
  after the first paragraph, when the Wikipedia title matches X and the reply names it.

Pictures are the Wikipedia article's lead image (`original_image`, else the thumbnail), Wikimedia hosts only, loaded
through `/api/image`. Lookups share the `/api/entity/info` cache and start as soon as a reference streams in (and,
for such a question, when the reply starts), so they usually finish while the text streams. The bridge waits at most
1.5 s after the text for any still running, then fetches each picture into the `/api/image` cache at `w=1280` in the
background. The message's `meta.pictures` is `{"count", "ms"}` (pictures shown, wait after the text). With
`LIVE_LINK_PREVIEW=false` nothing is changed.

## Warm start

`POST /api/session/warm` `{}` (live key; capability `live_warm`; round 8). The app sends it when a call is likely: a
finger on the composer or the live button, or a swipe up. On the codex backend the bridge prepares a session ahead
of time: it spawns the app-server, initializes it and starts an ephemeral thread. No realtime session is created,
so this costs no GPT-Live quota. One prepared session is kept for 180 s and the next `POST /api/session` takes it.
Answer: `{"warm": true, "ready": false|true, "ttl_s": 180}`, or `{"warm": false, "reason": "backend"|"in_call"}`.
`POST /api/session` now also returns `timing` (ms): `warm`, `prepare_ms`, `realtime_sdp_ms`, `start_ms`,
`session_ms`, plus `spawn_init_ms` and `thread_ms` from the prepare step. The bridge logs the same values as
`live connect timing: {…}`.

## Favicons

`GET /api/favicon?host=example.com` (capability `favicon`; needs `LIVE_LINK_PREVIEW`) →
`200 {"host", "url", "favicon", "width", "height"}`.

- The host is lower-cased and a leading `www.` dropped. It must be a public domain name: no port, IP address, path or
  private suffix (`400 bad_host` or `400 blocked_url`).
- The bridge tries `https://<host>/favicon.ico`, then the first two `<link rel="icon">` of the home page, with the
  link-preview fetcher and its SSRF rules and limits (icons at most 64 KB). `favicon` is a `data:` URL whose bytes
  match ICO, PNG, GIF, JPEG or WebP, else `null` (no icon found, or the site failed: still `200`). `width`/`height`
  are read from PNG/GIF/WebP/JPEG headers, else `null`.
- Cached per host: 1 hour with an icon, 5 minutes without.

## Reports

Capability `report`. The app's "Report reply" action (long press or More on a reply). Reports stay on this server: the
app sends them only to the bridge it is connected to, and the bridge appends them to a file for the operator. Nothing is
sent anywhere else.

`POST /api/report` (`Authorization: Bearer <LIVE_PAGE_KEY>`)

```json
{"message_id": "m_…", "conversation_id": "c_…", "reason": "harmful", "note": "Told me to mix bleach and ammonia", "hidden": true}
```

- `reason` (required): `offensive`, `harmful`, `wrong` or `other`.
- `note` (optional): at most 1000 characters.
- `conversation_id` (optional), `hidden` (optional): whether the user also hid the reply on their device (the reply
  itself is not changed on the server).
- `200 {"ok": true, "id": "rep_…"}`. Errors: `401 unauthorized`, `400 bad_request` (unknown reason, note too long,
  missing `message_id`), `429 rate_limited` (more than 20 reports a minute), `500 report_failed` (the file could not be
  written).

The bridge appends one JSON object per line to `LIVE_REPORTS_FILE` (default `<BRIDGE_DATA_DIR>/reports.jsonl`, mode
600): `id`, `at` (UTC, ISO 8601), `reason`, `note`, `hidden`, `message_id`, `conversation_id`, `found` (the message
exists in this bridge's history), `role`, `model` (from the message's `meta`, if any) and `text` (the reply as stored,
at most 8000 characters), so the report still makes sense after the chat is deleted. Read it with
`jq . reports.jsonl`. A message the bridge does not know is still logged (`found: false`, empty `text`).

Older bridges answer `404`; the app then still hides the reply locally if the user asked for that, and says the
server did not take the report.

## Other error codes on the old routes

| Route | Code |
|---|---|
| `/api/delegate` | `bad_task` (no session or empty task), `hermes_unconfigured`, `busy` (429: 2 jobs running in this call, or 4 across all calls, counting tasks of calls that have ended) |
| `/api/job/{sid}/{jid}` | `not_found` |
| `/api/session/{sid}/jobs` | `not_found` (no such running call) |

All of these keep their old `error` text.

## Storage (server)

- The SQLite database is `<BRIDGE_DATA_DIR>/chats.sqlite` (mode 600, rollback journal so a raw file copy of the data
  directory is consistent).
- Stream events are kept in memory only, per reply, at most `LIVE_STREAM_BUFFER` events, for `LIVE_STREAM_KEEP_S`
  after the reply ends (and at most 64 finished replies). The reply's text and final status are always in SQLite.
- Tables:
  - `conversations(id, title, title_source, pinned, kind, created, updated)`
  - `messages(seq, id, conversation_id, role, text, source, status, created, client_id, meta_json)`
  - The FTS5 index `messages_fts`.
- Configuration: every variable is documented in `bridge.env.example`. The chat ones:
  - `LIVE_CHAT_DB`: the database path
  - `LIVE_MAX_CHATS`: concurrent replies, default 2
  - `LIVE_STREAM_KEEP_S` (default 300), `LIVE_STREAM_BUFFER` (default 10000), `LIVE_STREAM_DISCONNECT`
    (`continue`, the default, or `cancel`)
  - `LIVE_BACKEND`, `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `OPENAI_LIVE_MODEL`, `OPENAI_LIVE_VOICE`,
    `OPENAI_MAX_CALL_MINUTES` (30), `OPENAI_DAILY_MINUTES` (60; 0 = none), `OPENAI_USAGE_FILE`
    (`<data>/openai-usage.json`)
  - `PUSH_ENABLED` (default true), `PUSH_PREVIEWS` (default true), `PUSH_MAX_DEVICES` (10), `PUSH_RATE_PER_MIN` (20)
  - `LIVE_EVENTS_HEARTBEAT_S` (80), `LIVE_EVENTS_KEEP` (500), `LIVE_TASK_UI` (true)
  - `LIVE_REPORTS_FILE` (`<data>/reports.jsonl`): reported replies (see "Reports")
- Table `push_devices(device_id, endpoint, app_version, created, updated, last_ok, failures)`.
- Table `uploads(id, sha256, name, mime, size, kind, width, height, conversation_id, message_id, created, workspace)`;
  files in `LIVE_UPLOAD_DIR` (`<data>/uploads`: `blobs/<sha256>`, `previews/<sha256>.jpg`, mode 600 in 700
  directories).
- Table `settings(id = 1, version, json, updated)`: the synced settings.
- Table `events(id, created, type, data)`: the events stream (API.md "Events"). The database's `user_version` is 4.
- `meta._hermes` on assistant messages holds Hermes' session counters after that reply (for the next reply's usage
  share). Keys starting with `_` are bridge-private and never returned.
- Attachments: `LIVE_UPLOADS`, `LIVE_UPLOAD_DIR`, `LIVE_UPLOAD_IMAGE_MB` (10), `LIVE_UPLOAD_FILE_MB` (25),
  `LIVE_UPLOAD_CONVERSATION_MB` (200), `LIVE_UPLOAD_TOTAL_MB` (2048), `LIVE_UPLOAD_MAX_ITEMS` (4),
  `LIVE_UPLOAD_UNUSED_HOURS` (24), `LIVE_VISION` (true), `HERMES_UPLOAD_DIR`, `HERMES_UPLOAD_PATH`.
  Also `LIVE_WEB_SEARCH` (`auto`, `true` or `false`), `LIVE_UI_PROMPT_FILE` (`<data>/hermes-ui-prompt.md`) and
  `LIVE_LINK_PREVIEW` (true).
  - `LIVE_TITLES`: `simple` (default) or `hermes`. The Hermes title call costs one full Hermes turn, about
    12,700 prompt tokens because of Hermes' system prompt (measured 16 November 2026).
