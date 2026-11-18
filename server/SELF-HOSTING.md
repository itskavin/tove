# Self-hosting the bridge

The bridge is a small Python server that sits between the app and two things you run yourself:

- **Hermes Agent**, for text chat, chat history and the tasks a voice call delegates.
- **GPT-Live**, through one of two backends (see "Choose a GPT-Live backend" below): the official Codex CLI
  (`codex app-server`) with **your own ChatGPT login**, or the OpenAI Live API with **your own OpenAI API key**. Both
  keep the credential on your server. The bridge never sees audio in the app's live mode: the phone or browser talks
  WebRTC straight to OpenAI, and the bridge only brokers the session setup and runs the delegated Hermes tasks.

The app never holds an OpenAI key. OpenAI's own guidance is to keep the project key on a trusted server, so the API
key goes into the bridge's `bridge.env`, not into the app.

What you need:

- A Linux server (x86_64 or arm64) with Docker, or Python 3.12.
- Hermes Agent with its API server on (`API_SERVER_KEY` set). Hermes listens on port 8642 by default.
- For voice: a ChatGPT plan that includes GPT-Live, **or** an OpenAI API project with GPT-Live access (paid tier;
  the Free tier is not supported).
- A way to give the bridge HTTPS: a reverse proxy with a certificate, or Tailscale (see below).

The wire contract for app developers is [API.md](API.md). Every setting is in
[bridge.env.example](bridge.env.example).

## 1. Configure

```sh
cp bridge.env.example bridge.env
chmod 600 bridge.env
python3 -c "import secrets; print(secrets.token_urlsafe(32))"    # use the output as LIVE_PAGE_KEY
```

Set at least:

- `LIVE_PAGE_KEY`: the key you paste into the app.
- `HERMES_API_URL` and `HERMES_API_KEY`: where Hermes' API server is, and its `API_SERVER_KEY`.

`BRIDGE_API_KEY` is only for Open WebUI's Realtime Call (`/v1/realtime`). Leave it empty if you don't use that.

### Choose a GPT-Live backend

| | `codex` (ChatGPT login) | `openai` (your OpenAI API key) |
|---|---|---|
| Credential | A ChatGPT login kept in `CODEX_HOME` (device login, see section 2) | `OPENAI_API_KEY`, a project key in `bridge.env` |
| Cost | Included in the ChatGPT plan, up to its GPT-Live limit | **$0.05 per minute of voice**, billed per second, plus nothing else (the backend is your own Hermes) |
| Status | Uses Codex's experimental realtime API, which is not documented by OpenAI | The documented OpenAI Live API (`POST /v1/live/sessions`) |
| Delegation to Hermes | The app runs it over the call's data channel | The bridge runs it on the server through a sideband connection |
| Open WebUI Realtime (`/v1/realtime`) | Yes | No, that route always uses codex |

Set `LIVE_BACKEND`:

- `auto` (the default): `codex` when the Codex login exists (`CODEX_HOME/auth.json`), otherwise `openai` when
  `OPENAI_API_KEY` is set. With neither, calls fail with codex's `login_expired`, which tells you to log in.
- `codex` or `openai`: always that one. `openai` without a key answers `503 openai_unconfigured`.

`GET /api/capabilities` shows which backends are available and which one is active (`live_backend`,
`live_backends`). It never shows a key. The log prints the choice at startup.

**Cost control (openai backend).** A forgotten call costs money, so the bridge enforces two limits:

- `OPENAI_MAX_CALL_MINUTES` (default 30): the bridge ends each call after this long.
- `OPENAI_DAILY_MINUTES` (default 60, so at most about $3 a day; `0` turns the budget off): voice minutes for all
  calls per local calendar day. When less than a minute is left, `/api/session` answers `429 budget_exceeded` with
  `retry_after_s` until midnight, and a running call is ended when the budget runs out. Usage is kept in
  `<BRIDGE_DATA_DIR>/openai-usage.json` (mode 600), so a restart keeps it.

The budget counts the voice duration that OpenAI reports when the call ends. If that report is missing, it counts
the wall-clock time from creation, which is at least as long. Every session creation bills 15 seconds up front
(credited once the call runs). Also set a **monthly spend limit on the OpenAI project**: it is the backstop if the
bridge itself is down or misconfigured.

**Key safety (openai backend).**

- Create a dedicated **project** for the bridge in the OpenAI dashboard, with its own key and spend limit, so the
  key cannot spend on anything else and revoking it affects nothing else.
- Put the key only in `bridge.env` (mode 600). The bridge sends it only to `OPENAI_BASE_URL`, never returns it in
  an API response, and never logs it or OpenAI's error texts.
- Anyone with `LIVE_PAGE_KEY` can start paid calls, up to the daily budget. Treat the app key accordingly.
- The bridge removes `OPENAI_API_KEY` from the environment of the Codex processes it starts, so the codex backend
  keeps using the ChatGPT login.

### Attachments: give Hermes a folder for documents

Photos work with no setup when Hermes' model accepts images (`LIVE_VISION=true`, the default). PDFs, text and
office files are copied into a folder that **Hermes' tools can read**, and Hermes is told the path. Without that
folder the bridge accepts images only, and capabilities say so.

- Hermes on the same host, with its tools running as user `hermes`:
  `sudo install -d -o <bridge user> -g hermes -m 2750 /srv/hermes-uploads`, then `HERMES_UPLOAD_DIR=/srv/hermes-uploads`.
  Files are written with mode 640, and the setgid bit gives them Hermes' group, so Hermes can read them but not
  change them.
- Hermes in a container: mount one host folder into both (for example `/srv/hermes-uploads` → `/data/uploads` in
  Hermes), set `HERMES_UPLOAD_DIR` to the bridge's path and `HERMES_UPLOAD_PATH` to Hermes' path.

The copies are deleted with their message or chat. Uploads nobody sent are deleted after 24 hours. Executable
files are refused, and nothing is stored with execute permission.

### The Hermes app's prompt

The bridge ships `hermes-ui-prompt.md`. It is sent to Hermes only for requests from the Hermes app (`"ui": 1`), and
lets Hermes add tap-to-answer options, buttons and calculators, and keeps tables and lists in proper markdown. Nothing
to set up. To change the wording, copy it to `<BRIDGE_DATA_DIR>/hermes-ui-prompt.md` and edit that copy (it wins and is
re-read when it changes). `LIVE_UI_PROMPT_FILE=off` turns it off.

### Pictures in replies (optional)

The prompt lets Hermes show real images as `[![description](image URL)](source page)`; the app loads each picture
through `GET /api/link-preview` (the bridge fetches it with the same public-address checks, at most 3 MB, JPEG, PNG,
GIF or WebP only). Hermes only shows images a tool gave it. Its `web_search` returns no image URLs, so for pictures
beyond those found in extracted pages, install the bundled `hermes-image-search` plugin, which adds an
`image_search` tool backed by your own SearXNG (`categories=images`, `SEARXNG_URL` must be set for Hermes):

```sh
docker cp hermes-image-search <hermes container>:/opt/data/plugins/image-search   # then chown it to Hermes' user
docker exec -u hermes <hermes container> hermes plugins enable image-search         # applies to new sessions
```

It needs no key or paid service and fetches no image bytes itself; it only returns the URLs and source pages that
SearXNG's image engines reported (watermarked stock-photo sites and tiny images are dropped).

## 2a. Install with Docker

```sh
cp compose.example.yaml compose.yaml
docker compose build
```

The image installs the Codex CLI release named by the `CODEX_VERSION` build argument. To use a Codex binary you
already have, build with `--build-arg CODEX_VERSION=` and uncomment the codex mount in `compose.yaml`.

All state lives in the `bridge-data` volume, mounted at `/data`:

| Path | Contents |
|---|---|
| `/data/chats.sqlite` | Chat history |
| `/data/codex-home` | The bridge's Codex login (secret) |
| `/data/work` | Codex's working directory |
| `/data/web`, `/data/hermes-live.apk` | Optional web app and APK the bridge serves |

**First run: log Codex in inside the container.** Do this once, before you start the service:

```sh
docker compose run --rm bridge codex login --device-auth
```

Codex prints a URL and a one-time code. Open the URL on any device, sign in to ChatGPT, and enter the code. The
login is saved in `/data/codex-home`. Check it with:

```sh
docker compose run --rm bridge codex login status
```

Then start the bridge and check it:

```sh
docker compose up -d
curl -s http://127.0.0.1:8787/healthz
```

If Hermes runs on the same host outside Docker, set `HERMES_API_URL=http://host.docker.internal:8642/v1`. The
compose example maps that name to the host. Hermes must then listen on an address the container can reach, not
only on 127.0.0.1.

## 2b. Install with a Python virtual environment

```sh
python3.12 -m venv ~/.local/share/gpt-live-bridge-venv
~/.local/share/gpt-live-bridge-venv/bin/pip install -r requirements.txt
```

Install the Codex CLI the official way (the npm package or a GitHub release), then log the bridge in with its own
Codex home:

```sh
export CODEX_HOME=~/.local/share/gpt-live-bridge/codex-home
mkdir -p "$CODEX_HOME" && chmod 700 "$CODEX_HOME"
codex login --device-auth
```

Keep this Codex home separate from the one you use by hand (`~/.codex`). Refresh tokens are single-use, so two
programs sharing one login keep logging each other out.

Run the bridge as a systemd user service. Adjust the paths:

```ini
# ~/.config/systemd/user/gpt-live-bridge.service
[Unit]
Description=The bridge (app API, Hermes chat, GPT-Live through Codex)
After=network-online.target

[Service]
ExecStart=%h/.local/share/gpt-live-bridge-venv/bin/python /path/to/gpt-live-bridge.py
EnvironmentFile=/path/to/bridge.env
Restart=always
RestartSec=5
MemoryMax=900M
NoNewPrivileges=true

[Install]
WantedBy=default.target
```

```sh
systemctl --user daemon-reload
systemctl --user enable --now gpt-live-bridge
loginctl enable-linger "$USER"      # keep it running when you are logged out
curl -s http://127.0.0.1:8787/healthz
```

## 3. TLS: reverse proxy or Tailscale

The bridge speaks plain HTTP and listens on 127.0.0.1 by default. **Never expose it without TLS.** The app sends the
key as a bearer token on every request, so anyone who can read the traffic can use your Hermes agent.

**Tailscale (private, simplest).** On the bridge host:

```sh
tailscale serve --bg --https=8787 http://127.0.0.1:8787
```

The app then uses `https://<machine>.<tailnet>.ts.net:8787`. Only devices on your tailnet can reach it.

**Reverse proxy (public or LAN).** Proxy one HTTPS host to `http://127.0.0.1:8787`. Chat replies stream as
server-sent events, so turn response buffering off and allow long reads. For nginx:

```nginx
location / {
    proxy_pass http://127.0.0.1:8787;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_read_timeout 1h;
    client_max_body_size 1m;
}
# Open WebUI Realtime only (websocket):
location /v1/realtime {
    proxy_pass http://127.0.0.1:8787;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 1h;
}
```

Caddy streams by default: `reverse_proxy 127.0.0.1:8787` is enough.

The bridge sends a `: keep-alive` comment every 15 seconds while Hermes works, so proxies don't drop quiet streams.

## 3a. Pair the app

Instead of typing the key into the app, make a one-time pairing code on the server:

```sh
docker compose exec bridge python /app/tove_pair.py --url https://<the address the phone uses>   # Docker
venv/bin/python tove_pair.py --url https://<the address the phone uses>                          # virtual environment
```

It prints a QR code, the address and a short code such as `ABCDE-FGHJK`. In the app, tap **Scan QR code**, or
**Enter code or address**. The code works once, for 10 minutes; the app receives the key from the bridge over HTTPS
(`POST /api/pair`, API.md "Pairing"). `--png FILE` also saves the QR code as an image. Wrong codes are rate-limited.

The `tove-setup` Hermes skill ([../hermes-skill/](../hermes-skill/)) does all of this, and the install, for you.

## 4. Security notes

- **Keys.** Use a random key of at least 24 characters (the bridge refuses shorter ones). Anyone with
  `LIVE_PAGE_KEY` can chat with your Hermes agent, read your chat history and start GPT-Live calls on your ChatGPT
  plan. Rotate it by changing `bridge.env` and restarting, then paste the new key into the app.
- **Rate limits.** The bridge caps work, not requests: `LIVE_MAX_CHATS` replies at once, `LIVE_MAX_JOBS` tasks per
  call, one live session at a time (a new one replaces the old), and `BRIDGE_MAX_CALLS` Open WebUI calls. It does not
  throttle failed key attempts. If you expose it beyond a private network, add rate limiting in the proxy (for
  example nginx `limit_req` on `/api/`) or put it behind an identity-aware proxy.
- **Hermes has real tools.** Hermes can run commands on your machines. Treat the bridge key like an SSH key.
- **Secrets on disk.** `bridge.env` (with `OPENAI_API_KEY` if you use the openai backend) and the Codex home hold
  secrets. Keep them mode 600 / 700 and out of version
  control and screenshots. The chat database is created with mode 600.
- **Link previews.** `GET /api/link-preview` makes the bridge fetch public web pages. It refuses private,
  loopback, link-local and tailnet addresses (also after redirects and DNS answers), caps size and time, and never
  decodes the images it returns. Set `LIVE_LINK_PREVIEW=false` if the bridge must not make outbound web requests.
- **Logs.** The bridge logs metadata only (sizes, durations, status). It never logs messages, transcripts or audio.
- **Push endpoints.** The bridge sends pushes only to `http(s)` URLs that the app registered with the key, and
  never follows redirects. If you don't use push, set `PUSH_ENABLED=false`.
- **Stopping a reply.** Replies keep running when the app disconnects (so a flaky network does not lose them). The
  app's Stop button calls `POST /api/chat/{id}/stop`, which also interrupts Hermes. Old app builds that only close
  the connection need `LIVE_STREAM_DISCONNECT=cancel`.

## 5. Notifications

**Nothing to set up.** The app's "Instant notifications" (Settings → Notifications, on by default) keep one small
connection open to the bridge's `GET /api/events` stream (a heartbeat every 80 s, `LIVE_EVENTS_HEARTBEAT_S`), shown as
a quiet ongoing notification; with it off, the app checks `/api/events?once=1` about every 15 minutes. Only the Tove
app is needed on the phone. The web app shows notifications
only while its tab is open. UnifiedPush through ntfy (below) still works for people who already use a distributor.

## 5a. Push notifications with ntfy (optional)

The app can notify you when a reply or a voice-call task finishes while the app is in the background or closed.
This uses [UnifiedPush](https://unifiedpush.org/), not Google's push service: a distributor app on the phone keeps
one connection to a push server, the app registers that server's endpoint with the bridge, and the bridge POSTs to
it. [ntfy](https://ntfy.sh/) is the usual distributor and server. Its Android app is on F-Droid and Google Play.

**Option A: the public ntfy.sh server.** Nothing to install. Install the ntfy app on the phone and pick it as the
app's push distributor. Pushes then pass through ntfy.sh in plain text, so set `PUSH_PREVIEWS=false` in `bridge.env`
to keep chat titles and reply text out of them.

**Option B: your own ntfy server (recommended).**

```yaml
# ntfy/compose.yaml
services:
  ntfy:
    image: binwiederhier/ntfy
    command: serve
    restart: unless-stopped
    environment:
      NTFY_BASE_URL: https://ntfy.example.org     # the URL your phone uses
      NTFY_CACHE_FILE: /var/cache/ntfy/cache.db
      NTFY_AUTH_FILE: /var/lib/ntfy/auth.db
      NTFY_AUTH_DEFAULT_ACCESS: deny-all
      NTFY_BEHIND_PROXY: "true"
    volumes:
      - ./cache:/var/cache/ntfy
      - ./lib:/var/lib/ntfy
    ports:
      - "127.0.0.1:2586:80"
```

```sh
docker compose up -d
# UnifiedPush topics start with "up"; anyone may publish to them (the topic name is the secret), nobody else reads
docker compose exec ntfy ntfy access '*' 'up*' write-only
```

Serve it over HTTPS (reverse proxy or `tailscale serve`, as for the bridge; ntfy needs long-lived connections, so
turn proxy buffering off). In the ntfy app on the phone, set the default server to your URL. The bridge must be able
to reach that URL too, because it sends the pushes. With Docker, check that the bridge container resolves the host.

Then, in the app, turn notifications on. It registers its endpoint (`POST /api/push/register`), and its "send test
notification" button calls `POST /api/push/test`. To check from the server, look at the bridge log: it logs
`push failed` or `push endpoint gone` (never the URL). An endpoint that answers 404 or 410 is removed automatically.

Notes:

- Pushes are sent only when no app is watching the reply. An app in the foreground shows the result itself.
- With `PUSH_PREVIEWS=false` a push carries only ids and a status. The app shows a generic notification and fetches
  the text over the API.
- At most `PUSH_MAX_DEVICES` (10) devices, and `PUSH_RATE_PER_MIN` (20) pushes per device per minute.
- Endpoints are stored in `chats.sqlite`. Anyone holding an endpoint URL can send notifications to that phone.

## 6. Upgrade

Docker:

```sh
git pull
docker compose build --pull
docker compose up -d
```

To move to a newer Codex CLI, change `CODEX_VERSION` in the Dockerfile (or pass `--build-arg`), then rebuild.

Virtual environment: replace `gpt-live-bridge.py` (and `hermes-live.html`), run
`pip install -r requirements.txt` again, and restart the service.

Before you restart, check that no live call is running: `curl -s http://127.0.0.1:8787/healthz` shows
`"live_session": false` and `"active_chats": 0`. A restart ends live calls. Replies being written at that moment are
saved as `interrupted`.

The database schema upgrades itself on start. Clients find new features through `GET /api/capabilities`.

**Voice chats saved by app builds from before 16 November 2026** may show each spoken turn twice or more ("Alright,
bye" above "Alright, bye for now."). New imports are merged, and `cleanup-voice-fragments.py` merges the old ones the
same way. It is a dry run unless you pass `--apply`, and `--apply` copies the database to `--backup-dir` first:

```sh
python cleanup-voice-fragments.py --db <data>/chats.sqlite                       # counts only
python cleanup-voice-fragments.py --db <data>/chats.sqlite --apply --backup-dir ~/bridge-backup-$(date +%F)
```

## 7. Backup and restore

Back up the data directory (`/data` in Docker, `BRIDGE_DATA_DIR` otherwise), together with `bridge.env`:

- `chats.sqlite` uses a rollback journal, not WAL. A file copy while the bridge is idle is consistent. For a
  guaranteed-consistent copy while it runs, use `sqlite3 chats.sqlite ".backup chats-backup.sqlite"`.
- `codex-home` holds the ChatGPT login. Restoring an old copy may hold a refresh token that was already used. If
  voice then fails with `login_expired`, run the device login again.
- `uploads/` holds the attachments (`blobs/` is what matters; `previews/` and `tmp/` can be rebuilt or skipped).
  `HERMES_UPLOAD_DIR` holds only copies.
- `openai-usage.json` holds only today's voice seconds for the daily budget. Losing it resets the day's count.
- `web`, `web-releases` and the APK can be rebuilt. `work` can be skipped.

Docker example (the volume name starts with your compose project's name; `docker volume ls` shows it):

```sh
docker run --rm -v gpt-live-bridge_bridge-data:/data -v "$PWD":/backup python:3.12-slim \
    tar -czf /backup/bridge-data-$(date +%F).tgz -C /data chats.sqlite codex-home
```

To restore, stop the bridge, put the files back into the data directory (owned by the bridge user, uid 10001 in the
image), and start it again.

## 8. Setting Tove up for someone else

The bridge serves one person: one key, one chat history, one set of settings, one Hermes. It has no user accounts.
To give a friend Tove, run **a second bridge and a second Hermes Agent for them**, never a shared one. Anyone with a
bridge's key reads all of its chats and drives its Hermes, and Hermes' memory, files and tools are that person's.

**What they get, per person:**

| Piece | Theirs alone |
|---|---|
| Hermes Agent | Its own instance and data folder (memory, sessions, skills), its own `API_SERVER_KEY`, and its own model credentials. Its tools (terminal, files) must not reach your machines: give it its own host, VM or container, and no SSH key of yours |
| Bridge | Its own data folder (`BRIDGE_DATA_DIR`, or its own Docker volume), port and `bridge.env`. `HERMES_API_URL`/`HERMES_API_KEY` point at **their** Hermes |
| Voice | Either their own ChatGPT login in their bridge's `CODEX_HOME` (`codex login --device-auth`, signed in with their account), or an OpenAI project key of theirs (`LIVE_BACKEND=openai`), or no voice at all |
| URL | Their own HTTPS host name (another `server` block or Caddy site), or a `tailscale serve` port shared with their tailnet account |

**Steps (Docker):**

1. Copy the bridge folder to a new directory (say `tove-sam/`), so its compose project, volume and container names
   differ. In `compose.yaml`, publish a free port, for example `127.0.0.1:8788:8787`.
2. Make their access key and put it in their `bridge.env` as `LIVE_PAGE_KEY`, with their Hermes' URL and key:

   ```sh
   python3 -c "import secrets; print(secrets.token_urlsafe(32))"
   ```

3. Voice: `docker compose run --rm bridge codex login --device-auth`, and have **them** open the link and sign in
   with their ChatGPT account. Or set their `OPENAI_API_KEY` with `OPENAI_DAILY_MINUTES` and a project spend limit.
4. Start it, check `curl -s http://127.0.0.1:8788/healthz`, and put HTTPS in front of it (section 3).
5. Make a pairing code for them (section 3a) and send the QR image, or the address and the code. A code works once,
   for 10 minutes, so it is useless to anyone who sees it later. (Sending the key itself also works, under the app's
   "I have an access key instead"; send a key only over a private channel.) If the key leaks, change
   `LIVE_PAGE_KEY`, restart, and pair again.

**Never share:** your `LIVE_PAGE_KEY`, `BRIDGE_API_KEY`, `HERMES_API_KEY`/`API_SERVER_KEY`, `OPENAI_API_KEY`,
`bridge.env`, your bridge's `codex-home` (the ChatGPT login: a copy logs both of you out, because refresh tokens are
single-use, and it would put their calls on your plan), your `chats.sqlite`, your Hermes data folder, or SSH keys
your Hermes uses. Their push notifications use their own ntfy topics, so nothing to share there either.

**Cost and quota:**

- Every text reply is at least one full Hermes run: Hermes' own system prompt and tools are about 12,600 prompt
  tokens before the chat starts, and each tool call in a reply sends it again (a reply with several tool calls often
  totals 50,000–150,000 prompt tokens). Most of it is usually served from the provider's prompt cache, which costs
  far less. Each message's `meta.usage` (or the app's message details) shows the real numbers.
- Their Hermes bills their model provider, so they should bring their own API key or subscription login. If you pay
  for it, put a spend limit on that key.
- Voice on the codex backend uses their ChatGPT plan's GPT-Live limit. On the openai backend it is $0.05 a minute,
  capped by `OPENAI_DAILY_MINUTES` (default 60 minutes, about $3 a day).
- Each bridge is small: a typical one uses about 40 MB idle and peaked near 500 MB (calls and uploads), under
  the 1 GB `mem_limit` in the compose example. Each Hermes needs what Hermes needs.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `/api/session` returns `502 login_expired` | The Codex login expired or was used elsewhere. Run the device login again |
| `/api/session` returns `429 usage_limit` | The ChatGPT plan's GPT-Live limit was reached; `retry_after_s` says when to retry |
| `/api/session` returns `502 auth_failed` | The openai backend's `OPENAI_API_KEY` was rejected: wrong, revoked, or the project has no GPT-Live access |
| `/api/session` returns `429 usage_limit` with `reason: "quota"` | The OpenAI project is out of credit or hit its spend limit. Retrying does not help until you add credit or raise the limit |
| `/api/session` returns `429 budget_exceeded` | `OPENAI_DAILY_MINUTES` is used up for today |
| openai calls talk but tasks never run | The bridge could not attach its sideband; the log says `openai sideband unavailable`. Check outbound WebSocket access to `api.openai.com` |
| `/api/capabilities` shows `"chat": false` | `HERMES_API_KEY` is not set, or the chat database could not be opened |
| Chat errors `hermes_unreachable` | `HERMES_API_URL` is wrong, or Hermes is not reachable from the bridge (Docker: see `host.docker.internal`) |
| Replies arrive all at once | A proxy buffers the stream; turn buffering off |
| No notifications | `/api/push/test` returns `delivered: false`: the bridge cannot reach the ntfy URL, or ntfy refuses the topic (run the `ntfy access` command above) |
