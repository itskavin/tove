# Bridge requests from the app (round 2)

For the bridge delegate. Source of truth for the current wire format: `infra/core/gpt-live-bridge/API.md`.

## Status (bridge, 15 November 2026)

| § | Request | Status | Where / notes |
|---|---|---|---|
| 1 | Tool calls as `meta.tools` (+ `tools` in `snapshot`) | **Done** | API.md "Tool calls on messages". Fields as requested; capped at 64 with `tools_truncated`. Capability `tool_parts` |
| 2 | `state: "failed"` for failed tools | **Partly done (deferred upstream)** | The bridge forwards and saves `failed` whenever Hermes says so, but Hermes' API (2026-11) sends only `running`/`completed` with no result flag (checked in `gateway/platforms/api_server.py`). Needs a Hermes change; until then every finished call is `done` |
| 3 | T3 detection | No bridge change needed | `tool` and `label` pass through unchanged |
| 4 | Attachments: uploads, previews, 24 h expiry, `message.attachments`, empty text | **Done** | API.md "Attachments". `vision: true` was verified: Hermes' `/v1/chat/completions` through `hermes-api-bridge` took an `image_url` part and its model read a test image. Documents go to `HERMES_UPLOAD_DIR/<conversation>/<name>` with a note. Also a `507 quota_exceeded` on `/api/chat` when claiming unowned uploads would pass `conversation_mb` |
| 5 | `web_search` flag | **Done** | Hermes' API has no tool-choice hint, so it is an instruction on the newest user turn. `web_search: true` is advertised only while Hermes' `/v1/toolsets` shows its `web` toolset (web_search) enabled. Stored as `meta.web_search`, repeated on retry |
| 6.1 | Live job `status_event` + `partial` | **Done** | `/api/job/{sid}/{jid}` and the new `GET /api/session/{sid}/jobs`. Capability `job_progress` |
| 6.2 | Link previews | **Done** | `GET /api/link-preview?url=`, capability `link_preview`. Images and favicons come back as small `data:` URLs, never decoded on the server; SSRF rules in API.md |
| 6.3 | Tasks of unlinked calls | Not changed | Nothing was asked of the bridge |
| — | hermes-ui system-prompt snippet | **Mechanism done; snippet deferred** | `docs/design/hermes-ui-prompt.md` does not exist yet. The bridge sends the contents of `LIVE_UI_PROMPT_FILE` (default `<data>/hermes-ui-prompt.md`) as a system message, only on `/api/chat` requests with the header `X-Hermes-UI: 1`. Capability `ui_prompt` turns true once the operator installs the file. **App:** send that header |
| — | Second GPT-Live backend (`openai`, operator's API key) | **Done** | API.md "openai backend". With it, the bridge runs delegations and saves linked transcripts itself; the app must not (see the differences table) |

## 1. Persist tool calls on assistant messages

**Today:** `status` events (`hermes.tool.progress` → `{label, state, tool, id, emoji}`) are only streamed; the
bridge keeps `last_status` for resume and drops the rest. Reopening a chat therefore loses the tool cards the
app showed while the reply streamed. The app keeps them in memory for the session only
(`ChatController.toolCallsFor`).

**Request:** store a compact list per assistant message and return it as `meta.tools` on every message read
(`GET /api/conversations/{id}`, messages pages, resume `snapshot`):

```json
"meta": {"tools": [
  {"id": "call_abc", "tool": "terminal", "label": "df -h /mnt/storage", "emoji": "💻",
   "state": "done", "offset": 42, "started": 1794691021626, "ended": 1794691023810}
]}
```

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Hermes `toolCallId` (`""` for approval notes) |
| `tool` | string ≤ 80 | Tool name as Hermes sends it |
| `label` | string ≤ 200 | The start event's preview (keep the start label; a later `completed` label often just repeats the tool name) |
| `emoji` | string ≤ 8 | As sent |
| `state` | `running \| done \| failed \| approval` | `completed` → `done`. When the reply ends with calls still running: `done` on `complete`, `failed` on `error`/`cancelled`/`interrupted` |
| `offset` | int | Characters of reply text already written when the call started; the app draws the card there (so a preamble reads before it). `-1` if unknown |
| `started`, `ended` | Unix ms | Bridge clock; `ended` absent while running |

Limits: keep at most 64 calls per message (drop the oldest beyond that, and add `"tools_truncated": n`).
`info` events (`hermes.status`) are lifecycle notes and need no persistence.

**Also useful:** include the same list in `snapshot` as `tools`, so a resumed stream can rebuild cards whose
events fell out of the buffer.

## 2. Distinguish failed tool calls

If Hermes reports a failed tool (non-zero exit, exception), forward it as `state: "failed"` (the app already
maps `failed`/`error`). Today every finished call arrives as `completed`.

## 3. T3 detection

The app marks a call as T3 when `tool` contains a `t3` token (for example an MCP server named `t3`) or the
label is a `t3 …` command preview (Hermes runs `t3 thread start …` through `terminal`). If Hermes gains a
dedicated T3 tool, keep its name containing `t3`.

## 4. Attachments: uploads (from the composer delegate)

The app side is built (`lib/src/attachments/`) against this contract, and it switches on only when capabilities
say `attachments: true`. Until then the tray's Camera, Photos and Files tiles read "Needs a newer server". This
replaces the sketch in `chat-rendering-v2.md` §5.2 ("Server needs") wherever the two differ.

### 4.1 Capabilities

```json
"attachments": true,
"attachment_limits": {"max_items": 4, "image_mb": 10, "file_mb": 25, "conversation_mb": 200,
                      "image_max_edge": 2048, "mimes": ["image/jpeg", "image/png", "image/webp",
                      "application/pdf", "text/*", "application/json", "…office types…"]},
"vision": true,
"web_search": false
```

- `attachment_limits` is optional. The app's defaults are the values above (`AttachmentLimits`), and it never
  goes past what the server reports. `text/*` matches a whole family.
- `vision`: whether Hermes' model accepts image content parts. With `false` the app still uploads images (and
  shows thumbnails), and the bridge handles them as files (4.4).

### 4.2 `POST /api/uploads`

- Authenticated like every `/api/*` route.
- `multipart/form-data` with **one** part named `file`. It carries `filename` (ASCII-safe) plus RFC 5987
  `filename*=UTF-8''…` (prefer that one when present) and the part's `Content-Type`.
- An optional text part `conversation_id` ties the upload to an existing conversation. Without it the upload is
  unowned until a message references it.
- The 1 MiB JSON body cap does **not** apply here. Cap the request at `file_mb` + 64 KiB and answer
  `413 too_large` past that, before reading the whole body.
- The app has already downscaled images to 2048 px on the long edge, re-encoded them (JPEG q85, or PNG when there
  is transparency, HEIC converted) and **stripped EXIF/GPS/XMP**. The bridge should still re-check the size and
  sniff the type (magic bytes, not just the declared MIME).

`201`:

```json
{"id": "up_9f2c…", "name": "IMG_2041.jpg", "mime": "image/jpeg", "size": 412233,
 "sha256": "…", "kind": "image", "width": 2048, "height": 1536,
 "preview_url": "/api/uploads/up_9f2c…/preview", "created": 1794700000000}
```

- `id` follows the usual id rules (1 to 64 characters of `A-Z a-z 0-9 _ -`).
- `kind` is `image` for `image/*` and `file` otherwise.
- `width`, `height` and `preview_url` are given for images only.
- The app also accepts `upload_id` in place of `id`.

Errors use the usual three-field body:

| Status | `code` | When |
|---|---|---|
| 400 | `bad_upload` | No `file` part, several files, an empty file, or a malformed multipart body |
| 401 | `unauthorized` | |
| 404 | `not_found` | `conversation_id` is unknown |
| 413 | `too_large` | Over `image_mb` / `file_mb` (the app shows "Too large for the server", not retryable) |
| 415 | `unsupported_type` | The sniffed type is not in `mimes` (not retryable) |
| 507 | `quota_exceeded` | The conversation's uploads would exceed `conversation_mb` |
| 503 | `uploads_unavailable` | Storage not configured |

An older bridge's plain 404 on the route counts as "no uploads".

### 4.3 Other routes

- `GET /api/uploads/{id}` streams the original back with its `Content-Type`, `Content-Disposition: inline`,
  `Cache-Control: private, max-age=86400` and an `ETag` (the sha256). It is used by the full-screen viewer and
  for opening documents.
- `GET /api/uploads/{id}/preview` returns a JPEG of at most 512 px on the long edge, for images only (404 for
  files). It is used for the 120 dp thumbnails in the thread. Same cache headers.
- `DELETE /api/uploads/{id}` → `204`. The app calls it when the user removes a staged item that has already
  uploaded. Deleting an upload a message references gives `409 in_use`. The app ignores failures here.
- Housekeeping: delete unreferenced uploads after 24 h. Delete referenced ones with their conversation (or
  message). Store them under the bridge data directory, keyed by sha256, with a per-conversation reference list.

### 4.4 Sending: `POST /api/chat`

```json
{"conversation_id": "…", "message": {"text": "What is this?", "attachments": ["up_9f2c…", "up_77ab…"]},
 "effort": "high", "web_search": true, "client_msg_id": "…"}
```

- `message.attachments` holds at most `max_items` ids, each from `POST /api/uploads`. An unknown id gives
  `400 bad_attachment`. An upload owned by another conversation also gives `400 bad_attachment`. An unowned upload
  becomes owned by this conversation.
- **`text` may be empty when `attachments` is non-empty.** Today an empty text gives `empty_message`, so relax that
  rule.
- The stored user message gains
  `attachments: [{id, name, mime, size, kind, width?, height?, preview_url?}]`. It is returned on every message
  read, so the thread can draw thumbnails and file chips.
- **Images with `vision: true`:** pass each one to Hermes as an OpenAI-style content part on that user turn:
  `{"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,…"}}`, after a text part. **This needs
  checking:** confirm that Hermes' `/v1/chat/completions` (and `hermes-api-bridge`) accept array `content`. Today
  the bridge builds `content` as a plain string (`gpt-live-bridge.py` around line 1440). In the history window
  (newest 40 messages), send images only on the newest user turn that has them. Replace older ones with a text
  note ("[image: IMG_2041.jpg]") to keep the request small.
- **Documents, and images with `vision: false`:** copy the file into Hermes' workspace at
  `uploads/<conversation_id>/<sanitised name>`. Append a note to the text Hermes receives:
  `The user attached report.pdf (1.2 MB, application/pdf) at <path>.` Hermes reads it with its own tools.
  Never inline document bytes into the prompt.

## 5. Web search flag

`POST /api/chat` accepts `"web_search": true` (optional, default false). The app sends it only when capabilities
report `web_search: true`, for one message at a time (the switch resets after sending). The bridge passes it to
Hermes as a short system or user note ("Prefer your web search tools for this request") or as a tool-choice hint,
if Hermes' API has one. Report `web_search: true` in capabilities once this is honoured. Store it on the user
message as `meta.web_search`, so a retry repeats it.

## 6. Live mode (from the live-mode delegate)

The live overlay (`lib/src/ui/live/`) shows Hermes task cards above the orb and a scrolling result panel with link
cards. It works with today's API; these would make it richer.

### 6.1 Progress for delegated jobs

**Today:** `GET /api/job/{sid}/{jid}` returns `{status, answer, markdown, seconds}`. A live task card can only say
"running · 12 s"; it cannot show which tool Hermes is in, or that it is calling T3.

**Request:** add the newest tool step (same shape as the chat `status` event) and an optional streamed partial:

```json
{"status": "running", "seconds": 12, "answer": "", "markdown": "",
 "status_event": {"label": "t3 thread start …", "state": "running", "tool": "terminal", "id": "call_1", "emoji": "💻"},
 "partial": "First findings so far…"}
```

The app would show `status_event.label` on the card (T3 detection as in §3) and stream `partial` into the live
panel while the job runs. Both fields optional; old apps ignore them.

### 6.2 Link previews (Open Graph)

**Today:** link cards show a monogram tile, the host and the link text (or a title made from the path). The app
fetches nothing from the linked sites, so no favicon or preview image.

**Request (optional):** `GET /api/link-preview?url=…` → `{"title", "site_name", "image", "favicon"}`, fetched and
cached by the bridge (timeouts, size caps, http/https only, no private addresses), images proxied or returned as
small data URLs. Capability flag `link_preview: true`. The app keeps its current cards when the flag is absent.

### 6.3 Results of tasks that outlive the call

The bridge now keeps live tasks running after the call ends and saves them to the linked chat. The app's
`DelegationRunner.stop()` (owned by `lib/src/call/`, not changed here) still marks them `stopped` with
"The call ended before Hermes finished". The live overlay now shows `stopped` as "continues in the chat" rather
than a failure. **For the call owner:** reword that detail, and refresh the linked chat when the push for a
finished task arrives. **For the bridge:** nothing more needed, unless unlinked calls should also keep tasks (then
`/api/live/transcript` could accept late task results).

---

# Round 3 (reply rendering delegate, 16 November 2026)

For the server delegate. The app builds against all of these now and falls back gracefully while they are
missing; nothing here is required for old bridges to keep working. App side: `lib/src/ui/thread/reply_details.dart`
(R3.1), `lib/src/ui/markdown/favicons.dart` + `BridgeImageLoader` (R3.2), `lib/src/ui/interactive/ui_entities.dart`
(R3.3, R3.4), prompt in `docs/design/hermes-ui-prompt.md` (R3.5).

| § | Request | Priority | App fallback today |
|---|---|---|---|
| R3.1 | Per-message model, timing and full usage in `meta` (+ `done`) | **Done by the bridge (cd27040, `meta.usage`)**; app reads it. Open: `reasoning_tokens` is often absent (see below) | "Not available" rows in the Details sheet |
| R3.2 | `GET /api/favicon?host=` | **Done by the bridge (cd27040)**; app uses it | `GET /api/link-preview?url=https://<host>/`, then a letter tile |
| R3.3 | Images in `hermes-ui` `entities`/`news` blocks | None (already works) | — |
| R3.4 | `POST /api/entity` side request for an entity's details sheet | Optional. **Deferred by the bridge (16 Nov)**: see R3.4 | Embedded `about`/`facts` + a visible "Follow up" message |
| R3.5 | Install the updated `hermes-ui-prompt.md` | **Installed by the bridge (16 Nov)**; real news reply had valid `entities` + `news` | Hermes never emits the new block types |

## R3.1 Details: model, timing and full usage per reply

**Status:** the bridge shipped this in cd27040 with a flatter shape inside `meta.usage` (`model`, `input_tokens`,
`output_tokens`, `cached_tokens`, `reasoning_tokens`, `model_calls`, `duration_ms`, `ttft_ms`, `tool_count`,
`effort`; API.md "Usage"). The app's Details sheet reads that shape (and the one below as a fallback). Remaining
asks: (1) a `completed_at` is not needed (the app uses `created + duration_ms`); (2) when the session-share check
drops `cached_tokens`/`reasoning_tokens`/`model_calls`, consider taking them from the streamed `usage` chunk's
`*_details` if Hermes forwards them. **App follow-up (chat/background owner, not this delegate):** `ReplyTask.build`
copies only the three old keys from `done.usage` into `meta`, so a reply that just finished shows the rich fields
only after a reload; copy the whole `done.usage` map.

The original request, kept for reference:

The reply's ⋮ menu now has **Details** (tokens, timing, model, tools). Today only `meta.usage`
(`prompt_tokens`, `completion_tokens`, `total_tokens`), `meta.effort`, `meta.finish_reason` and `meta.steps` exist.

**Request:** on every assistant message (stored `meta`, message reads, resume `snapshot`) and in the `done` event:

```json
"meta": {
  "model": "gpt-5.5",
  "usage": {"prompt_tokens": 18342, "completion_tokens": 1206, "total_tokens": 19548,
            "completion_tokens_details": {"reasoning_tokens": 512},
            "prompt_tokens_details": {"cached_tokens": 16000}},
  "timing": {"first_token_ms": 1840, "total_ms": 14250},
  "completed_at": 1794730127000
}
```

| Field | Meaning |
|---|---|
| `model` | The model Hermes answered with (from the upstream response's `model`), ≤ 80 chars. Not the bridge's own config name if they differ |
| `usage.*_details` | Pass through what Hermes/the provider reports (OpenAI shape). Summed over the tool loop like `usage` already is. The app also accepts flat `reasoning_tokens` / `cached_tokens` and the Responses API names (`input_tokens`, `output_tokens`, `output_tokens_details`) |
| `timing.first_token_ms` | Bridge clock: request accepted → first visible `delta` (not a step or status) |
| `timing.total_ms` | Request accepted → terminal event |
| `completed_at` | Unix ms of the terminal event |

No capability flag needed: the app shows each row when its field is present. Also add these fields to `done`
(`model`, `timing`, `completed_at`) so a just-finished reply shows them without a reload; the app copies `done.usage`
into `meta` today and will copy these the same way (`lib/src/background/reply_task.dart`, owner: chat/background).

## R3.2 Favicons: `GET /api/favicon?host=<host>`

**Status:** shipped in cd27040 (`200 {"host", "url", "favicon", "width", "height"}`, capability `favicon`); the app
calls it and falls back as described below on older bridges. Original request:

The reply's sources now show the reference's cluster of round site favicons, and inline source chips and both
sources sheets show the favicon of each page. The app gets them only through the bridge (never from the site).

**Request:** `GET /api/favicon?host=example.com` (capability `favicons: true`) →
`200 {"host": "example.com", "favicon": "data:image/png;base64,…" | null, "width": 64, "height": 64}`

- Same SSRF rules, timeouts and signature checks as `/api/link-preview`. PNG, ICO, GIF, JPEG, WebP; never SVG.
- Pick the best icon ≤ 256 px: `apple-touch-icon` (180), then `<link rel="icon" sizes>` closest to 64, then
  `/favicon.ico`. Do not decode or resize; at most 100 KB.
- Strip `www.`; one fetch per host; cache 24 h for a success and 1 h for a miss (`"favicon": null`, still 200).
- Errors like link-preview (`400 bad_url`, `400 blocked_url`). A host with no icon is `200` with `null`, not an error.

**App fallback (implemented):** until the route exists the bridge answers aiohttp's plain-text 404; the app then
remembers that and asks `/api/link-preview?url=https://<host>/` and uses its `favicon` field (one homepage fetch
per host). JSON errors from a present route are not treated as "missing route". Results are cached per host in
memory (256 hosts).

## R3.3 Images in the new `hermes-ui` blocks (no change needed)

`entities` cards (`image`, `highlights[].image`) and `news` thumbnails (`image`) load through
`/api/link-preview` exactly like markdown images (capability `link_preview_images`). If the bridge validates
`hermes-ui` blocks in tests, add the two new types (schema in `lib/src/ui/interactive/README.md`).

## R3.4 Optional: entity details side request `POST /api/entity`

**Status: deferred (bridge, 16 November 2026).** The bridge's only model is the full Hermes agent: no small direct
model call exists on this server (no OpenAI API key by design, and the ChatGPT login is for GPT-Live only). One
details request would therefore cost a whole Hermes run, at least ~14,000 prompt tokens and far more with a web
search, on every tap. That is the cost the "Follow up" fallback already has, but only when the user asks. The
capability `entity_details` stays absent. Revisit if Hermes gains a cheap no-agent completion route.

Tapping an entity card opens a details sheet (reference: a person's page with picture, summary, highlights,
sections, sources). The sheet shows what the block embedded at once. To keep replies cheap, the prompt asks Hermes
to embed only a short `about` and a few `facts`. For the full page the app can ask once per tap:

`POST /api/entity` (capability `entity_details: true`)

```json
{"conversation_id": "…", "message_id": "…", "name": "Ada Lind", "hint": "Co-founder and former CEO"}
```

→ `200 {"entity": {"name", "sub", "image", "page", "about", "facts", "links", "highlights"}}` (exactly the
`entities` item schema; `about` ≤ 1200 chars may cite `[^n]` footnotes of that message) or `{"entity": null}`.

- One short Hermes call with the message's text as context and the instruction to answer only with that JSON
  object (no tools unless it must look something up; then `web_search`). Not stored in the conversation history.
- Cache by `(message_id, name)` for the life of the message. Rate-limit like `/api/chat` (`429 busy`).
- The app wires this through `HermesUiScope.onEntityDetails` (the shell owner adds the call when the capability is
  true). Without it, the sheet's **Follow up** button sends "Tell me more about <name>" as a visible message.

## R3.5 Install the updated prompt

**Status: installed 16 November 2026** (the snippet only, byte-identical in the bridge's shipped
`hermes-ui-prompt.md` and the data-dir copy; +234 prompt tokens per model call, measured). A real web-search news
question gave valid `entities` and `news` blocks, the date line and footnotes; length was in line with earlier
tool replies, so the wording was kept. Hermes once added an empty `"children": []` to `entities`, which the parser
ignores. R3.1 note: Hermes' streamed `usage` has only `prompt_tokens`/`completion_tokens`/`total_tokens` (no
`*_details`), so `cached_tokens`/`reasoning_tokens` come only from its session counters.

`docs/design/hermes-ui-prompt.md` gained the `entities` and `news` types, inline `<small>` date lines and a short
"news and people" pattern. Copy the snippet to the bridge's prompt file (`LIVE_UI_PROMPT_FILE` /
`hermes-ui-prompt.md` beside the bridge) and keep the two identical. It changes the system prompt, so chats that
continue afterwards start a new Hermes session (as documented).

# Round 3 (settings delegate, 16 November 2026)

Settings › Data controls and Connection work today with the existing routes. These would make them faster and more
complete. All optional; the app checks a capability flag for each and keeps its fallback.

## R3.6 Export all chats: `GET /api/export` (capability `export`)

Today the app pages `GET /api/conversations` and, per chat, `GET /api/conversations/{id}` plus
`…/messages?before=` (one request per 200 messages), then saves one JSON file. A server route would be one request:

- `GET /api/export` → `200`, `Content-Type: application/json`, `Content-Disposition: attachment;
  filename="tove-chats-YYYY-MM-DD.json"`, streamed: `{"format": "tove-chats", "version": 1, "exported": ms,
  "conversations": [{...conversation, "messages": [...message objects, oldest first]}]}` (the app's current
  format, so both are interchangeable). Never include the key, push endpoints or `_`-private meta.
- Optional `?include=settings` adds the synced settings object; attachments stay out (ids and names only).

## R3.7 Delete all chats: `DELETE /api/conversations` (capability `delete_all`)

Today the app deletes chats one by one through `DELETE /api/conversations/{id}`. Asked for: `DELETE
/api/conversations` with body `{"confirm": "all"}` → `200 {"deleted": n}`; it stops running replies, removes the
chats' uploads like the per-chat delete, and keeps settings. `400 confirm_required` without the body.

## R3.8 Usage summary: `GET /api/usage?days=30` (capability `usage_summary`)

For Settings › Connection › Usage: `{"days": 30, "totals": {"input_tokens", "output_tokens", "cached_tokens",
"replies", "model_calls"}, "by_day": [{"date": "2026-11-16", ...same keys}], "by_model": {"gpt-5.5": {...}},
"voice_minutes": {"today", "days"}}`, summed from `meta.usage`. The app shows nothing until it exists.

## R3.9 Memory (capability `memory`)

Hidden for now. If Hermes Agent exposes its memory, `GET /api/memory` (list), `DELETE /api/memory/{id}` and a
synced `memory_enabled` setting the bridge honours would let Personalization show "Memory" like the reference app.

# Round 4 (app delegate, 16 November 2026)

## R4.1 Starter suggestions: an `emoji` per item (optional)

The new chat shows two drifting rows of twelve starter chips, each with an emoji. The app asks for
`GET /api/suggestions?n=8` (the documented maximum) and fills the rest from its local pool.

- Please add `"emoji"` (one emoji, at most 8 code points) to each suggestion. Without it the app uses an emoji for
  the `category` (`StarterPrompts.categoryEmoji` in `lib/src/ui/thread/starter_prompts.dart`), then a fallback set.
- Optional: allow `n` up to 12, so a whole set can come from the server.

## R4.2 Tasks: thinking-only replies are not tasks (app-side fix, no change needed)

The bridge sends a `thinking` step for nearly every reply. The app used to count any step, so every prompt showed
in the chat's Tasks panel and lit the Tasks button's "work running" dot. The app now counts only `kind: "tool"`
steps (and live-call Hermes jobs). No bridge change is needed. Please keep `kind` accurate: a tool call must be
`"tool"` and model reasoning `"thinking"`.

## R4.3 Checklist ticks (no change needed)

The new `checklist` block keeps the user's ticks per message on the device and in the synced settings object under
the namespaced key `tove.checklists` (`{"<message id>#<block>": {"d": ["0.1", …], "t": ms}}`, newest 40 lists,
about 60 bytes each), which the bridge already stores as is. Optional later: a `PATCH` for message `meta` would let
ticks live with the message itself; until then nothing else is needed.

# Round 6 (app delegate, 16 November 2026)

## R6.1 Fork a chat at a reply (capability `fork`)

The reply's More menu has "Fork to new chat". With no fork route, the app creates the chat by sending one message
that carries the conversation up to that reply as context (`forkSeed` in `lib/src/chat/fork.dart`: oldest turns
dropped to fit `message_chars`, `hermes-ui`/`hermes-html` blocks left out), then renames it "<title> (fork)". That
costs a model call, shows the seed as the first user message and loses attachments, steps and usage.

Asked for: `POST /api/conversations/{id}/fork` with `{"message_id": "…"}` → `201 {"conversation": {…}}`: a new chat
(title "<title> (fork)") holding copies of the messages up to and including `message_id` (meta, steps, usage and
attachment references kept; no model call). `404` for an unknown message. Report `"fork": true` in capabilities; the
app then uses the route and keeps the client-side seed for older bridges.
