#!/usr/bin/env python3
"""gpt-live-bridge: an OpenAI-Realtime-compatible websocket in front of Codex's GPT-Live-1 (ChatGPT login).

Open WebUI's Realtime Call speaks the OpenAI Realtime websocket protocol and is the orchestrator: it waits for a
transcript, asks for a response, and runs delegated work through its own chat model (Hermes). GPT-Live-1 is only
reachable through `codex app-server` over WebRTC with a ChatGPT login, drives its own turn taking and delegates
with `delegation.created`. This bridge is a WebRTC peer toward Codex (aiortc) and translates both directions:

  Open WebUI  <-- OpenAI Realtime events (PCM16 24 kHz base64) -->  bridge  <-- WebRTC + oai-events -->  Codex GPT-Live-1

It also serves the Hermes app's HTTP API (API.md): live calls through either GPT-Live backend ("codex" with the
ChatGPT login, or "openai" with the operator's OpenAI API key, which never leaves this server), text chat with
Hermes, history, attachments, push and link previews.

Everything the bridge says about itself is metadata only: transcripts and audio are never logged.
"""
import asyncio, base64, collections, contextlib, contextvars, datetime, fractions, hashlib, hmac, html, html.parser, ipaddress, json, logging, math, os, re, secrets, shutil, signal, \
    socket, sqlite3, time, urllib.parse, zipfile
from pathlib import Path

import aiohttp
import yarl
import av
import numpy as np
from aiohttp import WSMsgType, web
from aiohttp.abc import AbstractResolver
from aiortc import MediaStreamTrack, RTCPeerConnection, RTCSessionDescription
from av import AudioFrame

log = logging.getLogger("gpt-live-bridge")


def load_config(env=None) -> dict:
    """Every setting comes from the environment; bridge.env.example documents each variable. Paths default to
    BRIDGE_DATA_DIR (default ~/.local/share/gpt-live-bridge), so one variable moves all state."""
    env = os.environ if env is None else env

    def num(name, default, lo=0):
        raw = str(env.get(name) or "").strip()
        if not raw:
            return default
        try:
            value = int(raw)
        except ValueError:
            raise SystemExit("%s must be a whole number" % name)
        if value < lo:
            raise SystemExit("%s must be at least %d" % (name, lo))
        return value

    def text(name, default=""):
        return str(env.get(name) or "").strip() or default

    def flag(name, default):
        raw = str(env.get(name) or "").strip().lower()
        if not raw:
            return default
        if raw in ("1", "true", "yes", "on"):
            return True
        if raw in ("0", "false", "no", "off"):
            return False
        raise SystemExit("%s must be true or false" % name)

    xdg = text("XDG_DATA_HOME", os.path.join(os.path.expanduser("~"), ".local", "share"))
    data = os.path.expanduser(text("BRIDGE_DATA_DIR", os.path.join(xdg, "gpt-live-bridge")))
    return {
        "data_dir": data,
        "host": text("BRIDGE_HOST", "127.0.0.1"),
        "port": num("BRIDGE_PORT", 8787, 1),
        "key": text("BRIDGE_API_KEY"),                                       # Open WebUI Realtime route (/v1/realtime)
        "codex": text("CODEX_BIN", shutil.which("codex", path=env.get("PATH")) or "codex"),
        "codex_home": os.path.expanduser(text("CODEX_HOME", os.path.join(data, "codex-home"))),
        # GET /api/usage/limits (API.md "Usage limits"): CLIProxyAPI's management API (its panel password, which stays
        # on the server) and whether the bridge's own ChatGPT login is shown too.
        "cliproxy_url": text("CLIPROXY_URL", "http://127.0.0.1:8317"),
        "cliproxy_mgmt_key": text("CLIPROXY_MANAGEMENT_KEY"),
        "usage_live_login": flag("USAGE_LIVE_LOGIN", True),
        "workdir": os.path.expanduser(text("BRIDGE_WORKDIR", os.path.join(data, "work"))),
        "voice": text("GPT_LIVE_VOICE", "cove"),
        "assistant_name": text("ASSISTANT_NAME", "Hermes"),                # the name the voice uses for itself
        "max_calls": num("BRIDGE_MAX_CALLS", 1),
        "call_seconds": num("BRIDGE_CALL_SECONDS", 55 * 60, 60),
        "live_key": text("LIVE_PAGE_KEY"),                                   # the app's key for every /api/* route
        "notify_key": text("TOVE_NOTIFY_KEY"),                               # POST /api/notify (Hermes jobs on this host)
        "pair_file": os.path.expanduser(text("TOVE_PAIR_FILE", os.path.join(data, "pairing.json"))),   # POST /api/pair codes
        "hermes_key": text("HERMES_API_KEY"),
        "hermes_url": text("HERMES_API_URL", "http://127.0.0.1:8642/v1"),    # Hermes Agent's API server default
        "hermes_model": text("HERMES_MODEL", "hermes-agent"),
        "max_jobs": num("LIVE_MAX_JOBS", 2),
        "app_dir": os.path.expanduser(text("LIVE_APP_DIR", os.path.join(data, "web"))),
        "apk_path": os.path.expanduser(text("LIVE_APK_PATH", os.path.join(data, "hermes-live.apk"))),
        "chat_db": os.path.expanduser(text("LIVE_CHAT_DB", os.path.join(data, "chats.sqlite"))),   # chat history (mode 600)
        "max_chats": num("LIVE_MAX_CHATS", 2),                               # concurrent /api/chat replies
        # "auto" (default): "model" when TITLE_API_KEY is set, else "simple". "simple": rule-based titles, no model
        # call. "model": one small call to an OpenAI-compatible endpoint (for example a local CLIProxyAPI) for a 3–4 word
        # title, about 150 tokens. "hermes": one extra Hermes call per new chat, which runs the whole agent (about
        # 12,700 prompt tokens with Hermes' system prompt, measured 16 November 2026).
        "titles": text("LIVE_TITLES", "auto"),
        "title_api_url": text("TITLE_API_URL", "http://127.0.0.1:8317/v1"),
        "title_api_key": text("TITLE_API_KEY"),
        "title_model": text("TITLE_MODEL", "gpt-6-luna"),
        # OpenAI's priority ("fast") tier for the title call; CLIProxyAPI passes it to the ChatGPT backend, where it
        # roughly halves the time (measured 18 November 2026) and uses more of the plan's quota. "" or "off" sends none.
        "title_service_tier": "" if text("TITLE_SERVICE_TIER", "priority").lower() in ("off", "none", "default") else text("TITLE_SERVICE_TIER", "priority"),
        # Reply effort picks the OpenAI service tier too. Hermes' default provider runs every call in the priority
        # ("fast") tier; Medium and High replies name this Hermes provider per request, which runs the default tier.
        # "" or "off" keeps every reply on Hermes' default provider. See API.md "Reply effort".
        "standard_provider": "" if text("HERMES_STANDARD_PROVIDER", "cliproxy-standard").lower() in ("off", "none") else text("HERMES_STANDARD_PROVIDER", "cliproxy-standard"),
        # Effort for a chat reply sent without one (app builds before effort, scripts). Live-call tasks never use it:
        # they send no effort and stay in the fast tier.
        "chat_default_effort": text("CHAT_DEFAULT_EFFORT", "medium").lower(),
        "stream_keep_s": num("LIVE_STREAM_KEEP_S", 300),                     # finished replies stay resumable this long
        "stream_buffer": num("LIVE_STREAM_BUFFER", 10000, 16),               # events kept per reply for exact replay
        "stream_disconnect": text("LIVE_STREAM_DISCONNECT", "continue"),     # "continue" (default) or "cancel" (old behaviour)
        "push_enabled": flag("PUSH_ENABLED", True),                          # UnifiedPush notifications
        "push_previews": flag("PUSH_PREVIEWS", True),                        # false: no titles or text in pushes
        "push_max_devices": num("PUSH_MAX_DEVICES", 10),
        "push_rate_per_min": num("PUSH_RATE_PER_MIN", 20, 1),                # per device; extra pushes are dropped
        # GPT-Live backend for /api/session: "codex" (ChatGPT login), "openai" (the operator's OpenAI API key, billed per
        # minute) or "auto" (codex when its login exists, else openai when OPENAI_API_KEY is set). /v1/realtime is codex only.
        "live_backend": text("LIVE_BACKEND", "auto").lower(),
        "openai_key": text("OPENAI_API_KEY"),                                # never logged, never returned
        "openai_url": text("OPENAI_BASE_URL", "https://api.openai.com/v1").rstrip("/"),
        "openai_model": text("OPENAI_LIVE_MODEL", "gpt-live-1"),
        "openai_voice": text("OPENAI_LIVE_VOICE", "marin"),
        "openai_call_min": num("OPENAI_MAX_CALL_MINUTES", 30, 1),            # one call, then the bridge closes it
        "openai_daily_min": num("OPENAI_DAILY_MINUTES", 60),                 # all calls per local day; 0 = no budget
        "usage_file": os.path.expanduser(text("OPENAI_USAGE_FILE", os.path.join(data, "openai-usage.json"))),
        # POST /api/report (API.md "Reports"): reported replies, one JSON object per line, readable only by the bridge.
        "reports_file": os.path.expanduser(text("LIVE_REPORTS_FILE", os.path.join(data, "reports.jsonl"))),
        # Attachments (API.md "Attachments"): uploads live in LIVE_UPLOAD_DIR; documents are copied for Hermes into
        # HERMES_UPLOAD_DIR (a directory Hermes' tools can read), named in the prompt as HERMES_UPLOAD_PATH/...
        "uploads": flag("LIVE_UPLOADS", True),
        "upload_dir": os.path.expanduser(text("LIVE_UPLOAD_DIR", os.path.join(data, "uploads"))),
        "upload_image_mb": num("LIVE_UPLOAD_IMAGE_MB", 10, 1),
        "upload_file_mb": num("LIVE_UPLOAD_FILE_MB", 25, 1),
        "upload_conv_mb": num("LIVE_UPLOAD_CONVERSATION_MB", 200, 1),
        "upload_total_mb": num("LIVE_UPLOAD_TOTAL_MB", 2048, 1),
        "upload_max_items": num("LIVE_UPLOAD_MAX_ITEMS", 4, 1),
        "upload_unused_h": num("LIVE_UPLOAD_UNUSED_HOURS", 24, 1),
        "vision": flag("LIVE_VISION", True),                                 # Hermes' model takes image_url parts
        "hermes_upload_dir": os.path.expanduser(text("HERMES_UPLOAD_DIR")),
        "hermes_upload_path": text("HERMES_UPLOAD_PATH"),                     # default: HERMES_UPLOAD_DIR
        "web_search": text("LIVE_WEB_SEARCH", "auto").lower(),               # auto (ask Hermes' /v1/toolsets), true, false
        # Unset: <data>/hermes-ui-prompt.md if present, else the copy shipped beside this script. "off" sends none.
        "ui_prompt_file": os.path.expanduser(text("LIVE_UI_PROMPT_FILE")),
        "ui_prompt_default": os.path.join(data, "hermes-ui-prompt.md"),
        # OpenUI section appended to the UI prompt: <data>/openui-prompt.md, else the copy beside this script; "off" = none.
        "openui_prompt_file": os.path.expanduser(text("LIVE_OPENUI_PROMPT_FILE")),
        "openui_prompt_default": os.path.join(data, "openui-prompt.md"),
        # Clients that send "ui": 2 (Tove with the OpenUI chat library) get these two instead: markdown rules, then the
        # OpenUI section generated from the app's registry. Same lookup: <data>/<name>, else beside this script; "off".
        "markdown_prompt_file": os.path.expanduser(text("LIVE_MARKDOWN_PROMPT_FILE")),
        "markdown_prompt_default": os.path.join(data, "markdown-prompt.md"),
        "openui_chat_prompt_file": os.path.expanduser(text("LIVE_OPENUI_CHAT_PROMPT_FILE")),
        "openui_chat_prompt_default": os.path.join(data, "openui-chat-prompt.md"),
        "link_preview": flag("LIVE_LINK_PREVIEW", True),
        # Live-call tasks of a call linked to a chat are written into that chat like a reply (API.md "Live tasks in the
        # chat"). With LIVE_TASK_UI on (default) they get the app's UI prompt, so the result can use hermes-ui blocks.
        "task_ui": flag("LIVE_TASK_UI", True),
        # GET /api/events (API.md "Events"): the app's own notification stream. Seconds between heartbeats by default;
        # keep it under the slowest idle timeout on the way (Cloudflare closes a silent proxied stream after 100 s).
        "events_heartbeat_s": num("LIVE_EVENTS_HEARTBEAT_S", 80, 15),
        "events_keep": num("LIVE_EVENTS_KEEP", 2000, 50),                    # events kept for resume and polling (sync events too)
        # POST /api/transcribe (API.md "Transcription"): dictation audio -> text through an OpenAI Realtime-compatible
        # websocket (e.g. CLIProxyAPI's /v1/realtime, so a ChatGPT subscription pays and no API key is needed). Unset
        # STT_REALTIME_URL turns the route off. Audio is held in memory only and dropped after each request.
        "stt_url": text("STT_REALTIME_URL"),
        "stt_key": text("STT_API_KEY"),                                      # never logged, never returned
        "stt_model": text("STT_MODEL", "gpt-4o-transcribe"),
        "stt_session_model": text("STT_SESSION_MODEL", "gpt-realtime-2.1-mini"),   # the realtime session that hosts it
        "stt_max_s": num("STT_MAX_SECONDS", 120, 5),                         # longest clip per request
        "stt_concurrent": num("STT_MAX_CONCURRENT", 3, 1),
        "stt_timeout_s": num("STT_TIMEOUT_SECONDS", 45, 5),
        # Places (API.md "Places"): open data, no keys. PLACES_DB is the Overture extract places_fetch.py writes
        # (default <data>/places.sqlite; without it places_search reports "unavailable" and Hermes uses web search).
        # "near <area>" goes to a Photon (default) or Nominatim /search endpoint; result details come from OSM through
        # Overpass (OVERPASS_DAILY requests a day at most). "off" turns either service off.
        "places_db": os.path.expanduser(text("PLACES_DB", os.path.join(data, "places.sqlite"))),
        "places_geocoder_url": text("PLACES_GEOCODER_URL", "https://photon.komoot.io/api/"),
        "overpass_url": text("OVERPASS_URL", "https://overpass-api.de/api/interpreter"),
        "overpass_daily": num("OVERPASS_DAILY", 500, 0),
        "places_cache_h": num("PLACES_CACHE_HOURS", 24, 1),
        "tools_key": text("TOVE_TOOLS_KEY"),                                 # Hermes plugins -> /api/places/search
        # Map tiles for the app's Map component; "" hides the map. Use your own tile server for heavy use: the
        # OpenStreetMap Foundation's tiles are for light use only (operations.osmfoundation.org/policies/tiles/).
        "map_tiles": "" if text("MAP_TILE_URL", "https://tile.openstreetmap.org/{z}/{x}/{y}.png").lower() == "off"
                     else text("MAP_TILE_URL", "https://tile.openstreetmap.org/{z}/{x}/{y}.png"),
        "map_attribution": text("MAP_TILE_ATTRIBUTION"),
        # Reverse geocoding of the app's approximate location (a label when the app sends only coordinates); "off".
        "geocoder_url": text("LOCATION_GEOCODER_URL", "https://nominatim.openstreetmap.org/reverse"),
    }


CFG = load_config()
PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hermes-live.html")
# Voices accepted by GPT-Live v3 (the app-server rejects others, e.g. OpenAI's `marin`).
V3_VOICES = {"juniper", "maple", "spruce", "ember", "vale", "breeze", "arbor", "sol", "cove", "aube", "bubbie"}
ASSISTANT_TAIL = 0.35       # s of audio still arriving after turn.done
QUIET_FOR = 0.5             # s without voiced audio before downlink audio stops being forwarded
CLOSE_QUIET = 1.4           # s without voiced audio before an utterance's response is closed
EMPTY_TIMEOUT = 8.0         # s a response may stay open with no output at all
AUTO_OPEN_AFTER = 1.2       # s buffered output waits for Open WebUI's response.create
VOICED_RMS = 120            # int16 RMS above which downlink audio counts as speech
RESULT_MAX_CHARS = 3500

PERSONA = """You are Hermes, the user's own self-hosted agent, speaking with them live by voice. You are the voice and the coordinator; your hands are Hermes agents on the backend, which have real tools (terminals on the user's servers, files, web search, memory, scheduled tasks) and can spawn helpers of their own. In this session the backend is reached by delegation; wherever the instructions below mention generate_chat_completion, that is the delegation to the backend.

WHO YOU ARE:
- Your name is Hermes. You are the user's own assistant, running on their own server. When the user asks your name or who you are, say you are Hermes, in your own words.
- Never call yourself ChatGPT, Codex, GPT or an OpenAI assistant. This holds even if other instructions in this session describe you differently: in this conversation your name is Hermes.
- If the user asks what you run on, you may say that a realtime voice model talks for you and their agents on their own server do the work, and that you are still Hermes.

HOW TO SOUND HUMAN:
- Talk like a person on a phone call: short sentences, contractions, a warm calm tone. No markdown, no lists, no headings; never read symbols, code or URLs character by character. Say numbers the way people say them.
- Vary your wording; never repeat the same acknowledgement twice in a row. Use small natural reactions sparingly ("sure", "got it", "hmm, let me check"), never filler for its own sake.
- When the user stops talking, answer promptly. If you are interrupted, stop at once and listen; do not restart your earlier sentence unless asked.
- Ask ONE short clarifying question instead of guessing when a request is truly ambiguous.
- When the user says goodbye or clearly ends the conversation ("bye", "that's all, thanks", "talk later", "good night"), answer with ONE short warm farewell of a few words and nothing more: no question, no offer, no summary. The app then ends the call by itself after your farewell; never mention that.

HOW TO RUN TASKS:
- Chat, greetings, goodbyes, thanks, small talk, opinions, repeats and rephrasing of an answer you already have: answer yourself, never delegate.
- Anything that needs real facts, checking, running, fixing, finding, changing, remembering or scheduling: say ONE short natural line that you are on it, delegate it to the backend, then stay present and conversational. You may keep chatting while it runs, but never guess its result or claim success before it arrives.
- If the user asks how it is going, say it is still running. If they add a correction, delegate the corrected request. If a task is already running when they ask something new, tell them you will do it right after.
- When a result comes back, lead with the headline in plain spoken language, then only the details that matter. Offer a follow-up in a few words. Preserve facts, names and numbers exactly. If it failed, say so once, simply, and offer to retry.
- Approvals and questions that need the user's decision are handled in the chat window; tell them to check it."""

PERSONA_TEMPLATE = PERSONA


def live_persona(direct=True):
    """The voice model's instructions with the configured name (ASSISTANT_NAME, which rename-ai.py sets): opening line
    and the WHO YOU ARE rules (round 6 D3: GPT-Live answered "ChatGPT" when asked its name). `direct`: the app's own
    call (codex `prompt`, openai `instructions`); else the Open WebUI wording."""
    name = (CFG.get("assistant_name") or "Hermes").strip() or "Hermes"
    text = PERSONA_TEMPLATE.replace("You are Hermes,", "You are %s," % name, 1)
    text = text.replace("Your name is Hermes.", "Your name is %s." % name, 1).replace("say you are Hermes,", "say you are %s," % name, 1)
    text = text.replace("your name is Hermes.", "your name is %s." % name, 1).replace("you are still Hermes.", "you are still %s." % name, 1)
    if direct:
        text = text.replace(
            " In this session the backend is reached by delegation; wherever the instructions below mention generate_chat_completion, that is the delegation to the backend.",
            " The backend is reached by delegation. Several tasks can run at the same time; keep track of them out loud in a natural way.")
    return text


PERSONA = live_persona(False)                  # import-time copies, kept for scripts; the call paths use live_persona()
PERSONA_DIRECT = live_persona(True)

# Prepended to every spoken task sent to Hermes: its answer is read aloud by the voice model.
VOICE_TASK_NOTE = ("[Note: this message is a delegation from a live spoken conversation. The text is a voice transcript and may contain "
                   "mis-hearings; use the latest intent. Your reply will be spoken aloud by a voice model that paraphrases it: answer in plain "
                   "conversational sentences, keep it short (a few sentences unless detail was asked for), no markdown, no lists, no code blocks, "
                   "no URLs read out. Do the work with your tools as usual; only the final facts need to be spoken. Do not claim an action "
                   "succeeded before it actually did.]")

# Prepended instead for a call linked to a chat: the result is saved in that chat as the assistant's reply (rendered
# with Markdown and, with LIVE_TASK_UI, hermes-ui blocks) and a plain-text copy is spoken by the voice model.
TASK_CHAT_NOTE = ("[Note: this message is a delegation from a live spoken conversation. The text is a voice transcript and may contain "
                  "mis-hearings; use the latest intent. Your final reply is saved in the user's chat with you, as your answer, and a "
                  "plain-text copy is read aloud by a voice model. Open with one or two plain sentences that give the result on their "
                  "own (that is what gets spoken). Then add details formatted for reading, a short list, a table or a block, only "
                  "when they help. Do the work with your tools as usual. Do not claim an action succeeded before it actually did.]")

NO_CLIENT_HANDOFF ="The client executes delegations. If you receive a <realtime_delegation> message, do not use tools or read files: reply only with the word: skip"

FILLER = set("hello hi hey ok okay yes yeah no nope thanks thank you hmm mm uh um ah right sure well so and the a".split())


# A delegated "task" made only of these words (and at least one greeting, goodbye or thanks) is small talk: it would
# cost a full Hermes run (about 13,000 prompt tokens) to say goodbye, so the bridge answers it at once instead.
SMALLTALK_WORDS = FILLER | set("bye goodbye byebye bye-bye good night morning evening afternoon see later talk soon take care thanks "
                               "thank cheers i i'm im think it's its time to let go that's thats enough for now all cool great nice "
                               "awesome perfect much very alright have day got it fine you that was is".split())
SMALLTALK_TRIGGERS = set("bye goodbye byebye bye-bye thanks thank cheers hello hi hey night".split())
SMALLTALK_ANSWER = "Nothing to run for this: it is small talk. Reply to the user yourself, briefly."


def is_smalltalk(text: str) -> bool:
    words = re.findall(r"[\w'-]+", str(text or "").lower().replace("’", "'"))
    names = set(CFG["assistant_name"].lower().split())
    return 0 < len(words) <= 12 and all(w in SMALLTALK_WORDS or w in names for w in words) and any(w in SMALLTALK_TRIGGERS for w in words)


VOICE_SKIP_KEYS = {"type", "v", "id", "icon", "emoji", "tone", "url", "href", "image", "src", "favicon", "color", "style", "kind",
                   "format", "unit_style", "action", "actions"}
UI_FENCE_RE = re.compile(r"```hermes-(ui|html)[^\n]*\n([\s\S]*?)```")


def blocks_for_voice(kind, body, limit=600):
    """The readable words of a hermes-ui block (titles, labels, values) or a hermes-html block, for the voice model."""
    if kind == "html":
        words = html_to_words(body)
    else:
        try:
            data = json.loads(body)
        except ValueError:
            return ""
        out = []

        def walk(v, key=None):
            if key in VOICE_SKIP_KEYS or len(out) > 80:
                return
            if isinstance(v, dict):
                for k, x in v.items():
                    walk(x, k)
            elif isinstance(v, list):
                for x in v:
                    walk(x, key)
            elif isinstance(v, bool) or v is None:
                return
            elif isinstance(v, (int, float)):
                out.append(str(v))
            elif isinstance(v, str) and v.strip() and not v.startswith(("http://", "https://", "data:")):
                out.append(v.strip())
        walk(data)
        words = "; ".join(out)
    words = " ".join(words.split())
    return words if len(words) <= limit else words[:limit - 1].rstrip() + "…"


OPENUI_VOICE_SKIP = {"text", "number", "row", "column", "grid", "carousel", "card", "sunk", "clear", "default", "small",
                     "large", "sm", "md", "lg", "xs", "neutral", "info", "success", "warning", "danger", "error", "primary",
                     "secondary", "tertiary", "normal", "destructive", "grouped", "stacked", "linear", "natural", "step",
                     "pie", "donut", "single", "multiple", "range", "horizontal", "vertical", "metric", "up", "down",
                     "code", "script", "config", "draft", "document", "continuous", "discrete", "image", "small-heavy",
                     "large-heavy", "circular", "semiCircular"}


def openui_for_voice(body, limit=600):
    """The readable words of an openui fence: its quoted strings, minus URLs, picture references, ids and settings."""
    out = []
    for m in re.finditer(r'"((?:\\.|[^"\\])*)"', body):
        t = m.group(1).replace('\\"', '"').replace("\\n", " ").strip()
        if not t or t in OPENUI_VOICE_SKIP or t.startswith(("http://", "https://", "entity:", "mailto:")):
            continue
        if re.fullmatch(r"[a-z][a-z0-9_-]{0,24}", t) and re.search(r"[\d_]", t):
            continue                                   # ids like "day1", "q_3"
        out.append(t)
        if len(out) > 80:
            break
    words = " ".join("; ".join(out).split())
    return words if len(words) <= limit else words[:limit - 1].rstrip() + "…"


def html_to_words(body):
    return re.sub(r"<[^>]*>", " ", html.unescape(re.sub(r"(?is)<(script|style)\b.*?</\1>", " ", body)))


def plain_for_voice(t: str) -> str:
    s = str(t or "")
    s = UI_FENCE_RE.sub(lambda m: (lambda w: " " + w + ". " if w else " ")(blocks_for_voice(m.group(1), m.group(2))), s)
    s = re.sub(r"```openui[^\n]*\n([\s\S]*?)(?:```|\Z)", lambda m: (lambda w: " " + w + ". " if w else " ")(openui_for_voice(m.group(1))), s)
    s = re.sub(r"```[\s\S]*?```", " (code block omitted) ", s)
    s = re.sub(r"`([^`]*)`", r"\1", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"\1", s)
    s = re.sub(r"__([^_]+)__", r"\1", s)
    s = re.sub(r"^#{1,6}\s+", "", s, flags=re.M)
    s = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", s)
    return re.sub(r"\n{3,}", "\n\n", s).strip()


def is_filler(t: str) -> bool:
    toks = [w for w in re.sub(r"[^\w\s']", " ", t.lower()).split() if w]
    return (not toks) or (len(t) <= 60 and sum(w in FILLER for w in toks) / len(toks) >= 0.8)


def ev(kind: str, **kw) -> dict:
    return {"type": kind, "event_id": "event_" + secrets.token_hex(8), **kw}


# ----------------------------------------------------------------------------------------------------------------
# Codex: app-server (JSON-RPC over stdio) + WebRTC peer
# ----------------------------------------------------------------------------------------------------------------
class MicTrack(MediaStreamTrack):
    """Outgoing audio: 48 kHz mono PCM16 fed by push(); silence when empty. 20 ms frames paced in real time."""
    kind = "audio"

    def __init__(self):
        super().__init__()
        self._t = 0
        self._start = None
        self._buf = bytearray()

    def push(self, pcm48: bytes):
        self._buf += pcm48
        cap = 48000 * 2 * 4
        if len(self._buf) > cap:           # more than 4 s behind: drop the oldest audio
            del self._buf[: len(self._buf) - cap]

    async def recv(self):
        if self._start is None:
            self._start = time.time()
        wait = self._start + self._t / 48000 - time.time()
        if wait > 0:
            await asyncio.sleep(wait)
        if len(self._buf) >= 1920:
            chunk = bytes(self._buf[:1920]); del self._buf[:1920]
            arr = np.frombuffer(chunk, dtype=np.int16).reshape(1, 960)
        else:
            arr = np.zeros((1, 960), dtype=np.int16)
        f = AudioFrame.from_ndarray(arr, format="s16", layout="mono")
        f.sample_rate = 48000; f.pts = self._t; f.time_base = fractions.Fraction(1, 48000)
        self._t += 960
        return f


class CodexLive:
    def __init__(self, on_event, on_audio, on_closed):
        self.on_event, self.on_audio, self.on_closed = on_event, on_audio, on_closed
        self.proc = None; self.pc = None; self.dc = None; self.mic = MicTrack()
        self.seq = 0; self.pending = {}; self.thread_id = None; self.closed = False
        self.up = av.AudioResampler(format="s16", layout="mono", rate=48000)
        self.down = av.AudioResampler(format="s16", layout="mono", rate=24000)
        self.in_pts = 0
        self.ready = asyncio.Event(); self.notifs = asyncio.Queue(); self.tasks = []

    # --- JSON-RPC
    async def _read(self):
        try:
            while True:
                line = await self.proc.stdout.readline()
                if not line:
                    break
                try:
                    m = json.loads(line)
                except Exception:
                    continue
                if "id" in m and ("result" in m or "error" in m) and m["id"] in self.pending:
                    self.pending.pop(m["id"]).set_result(m)
                else:
                    self.notifs.put_nowait(m)
        finally:
            await self.close("app-server exited")

    async def rpc(self, method, params, timeout=30):
        self.seq += 1
        fut = asyncio.get_running_loop().create_future()
        self.pending[self.seq] = fut
        self.proc.stdin.write((json.dumps({"jsonrpc": "2.0", "id": self.seq, "method": method, "params": params}) + "\n").encode())
        await self.proc.stdin.drain()
        m = await asyncio.wait_for(fut, timeout)
        if "error" in m:
            raise RuntimeError(str(m["error"].get("message") or m["error"])[:300])
        return m.get("result")

    async def start(self, prompt: str, voice: str):
        env = dict(os.environ, CODEX_HOME=CFG["codex_home"])
        env.pop("OPENAI_API_KEY", None); env.pop("CODEX_API_KEY", None)   # the voice lane must use the ChatGPT login
        os.makedirs(CFG["workdir"], exist_ok=True)
        self.proc = await asyncio.create_subprocess_exec(
            CFG["codex"], "app-server", "--listen", "stdio://", "--enable", "realtime_conversation",
            "-c", "model_provider=openai", "-c", "suppress_unstable_features_warning=true",
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, env=env, limit=8 * 1024 * 1024)
        self.tasks.append(asyncio.create_task(self._read()))
        await self.rpc("initialize", {"clientInfo": {"name": "gpt-live-bridge", "version": "1"}, "capabilities": {"experimentalApi": True}})
        th = await self.rpc("thread/start", {"cwd": CFG["workdir"], "modelProvider": "openai", "approvalPolicy": "never",
                                             "sandbox": "read-only", "ephemeral": True})
        self.thread_id = th["thread"]["id"]
        self.pc = RTCPeerConnection()
        self.pc.addTrack(self.mic)
        self.dc = self.pc.createDataChannel("oai-events")

        @self.dc.on("open")
        def _open():
            pass

        @self.dc.on("message")
        def _msg(raw):
            try:
                m = json.loads(raw)
            except Exception:
                return
            if m.get("type") == "session.started":
                self.ready.set()
            self.on_event(m)

        @self.pc.on("track")
        def _track(tr):
            self.tasks.append(asyncio.create_task(self._drain(tr)))

        await self.pc.setLocalDescription(await self.pc.createOffer())
        await self.rpc("thread/realtime/start", {
            "threadId": self.thread_id, "transport": {"type": "webrtc", "sdp": self.pc.localDescription.sdp},
            "outputModality": "audio", "version": "v3", "voice": voice, "prompt": prompt,
            "realtimeStartInstructions": NO_CLIENT_HANDOFF, "clientManagedHandoffs": True, "delegationAckFiller": True}, timeout=30)
        answer = None
        end = time.time() + 30
        while time.time() < end and not answer:
            try:
                n = await asyncio.wait_for(self.notifs.get(), 1)
            except asyncio.TimeoutError:
                continue
            meth = n.get("method", "")
            if meth == "thread/realtime/sdp":
                answer = n["params"]["sdp"]
            elif meth == "thread/realtime/error":
                raise RuntimeError("codex: " + str(n["params"].get("message"))[:200])
        if not answer:
            raise TimeoutError("codex: no SDP answer")
        await self.pc.setRemoteDescription(RTCSessionDescription(sdp=answer, type="answer"))
        self.tasks.append(asyncio.create_task(self._watch()))
        await asyncio.wait_for(self.ready.wait(), 20)

    async def _watch(self):
        while not self.closed:
            n = await self.notifs.get()
            if n.get("method") in ("thread/realtime/closed", "thread/realtime/error"):
                await self.close(str(n.get("params", {}).get("reason") or n.get("params", {}).get("message") or "closed")[:120])
                return

    async def _drain(self, track):
        while not self.closed:
            try:
                frame = await track.recv()
            except Exception:
                return
            try:
                for f in self.down.resample(frame):
                    self.on_audio(f.to_ndarray().tobytes())
            except Exception:
                log.exception("downlink resample failed")

    # --- audio in (24 kHz mono PCM16 from Open WebUI)
    def push_mic(self, pcm24: bytes):
        n = len(pcm24) // 2
        if n == 0:
            return
        f = AudioFrame.from_ndarray(np.frombuffer(pcm24[: n * 2], dtype=np.int16).reshape(1, n), format="s16", layout="mono")
        f.sample_rate = 24000; f.pts = self.in_pts; f.time_base = fractions.Fraction(1, 24000)
        self.in_pts += n
        for out in self.up.resample(f):
            self.mic.push(out.to_ndarray().tobytes())

    def send_dc(self, obj: dict):
        if self.dc is not None and self.dc.readyState == "open":
            self.dc.send(json.dumps(obj))

    async def close(self, reason="closed"):
        if self.closed:
            return
        self.closed = True
        try:
            if self.proc and self.proc.returncode is None and self.thread_id:
                await asyncio.wait_for(self.rpc("thread/realtime/stop", {"threadId": self.thread_id}, timeout=5), 5)
        except Exception:
            pass
        try:
            if self.pc:
                await self.pc.close()
        except Exception:
            pass
        try:
            if self.proc and self.proc.returncode is None:
                self.proc.kill()
        except Exception:
            pass
        for t in self.tasks:
            if t is not asyncio.current_task():
                t.cancel()
        self.on_closed(reason)


# ----------------------------------------------------------------------------------------------------------------
# One call: Open WebUI websocket <-> Codex, as a single serial state machine
# ----------------------------------------------------------------------------------------------------------------
class Resp:
    def __init__(self, meta):
        self.id = "resp_" + secrets.token_hex(8)
        self.item_id = "item_" + secrets.token_hex(8)
        self.meta = meta or {}
        self.text = ""
        self.opened = time.monotonic()
        self.last_activity = self.opened
        self.spoke = False
        self.abytes = 0
        self.func_at = None


class Call:
    def __init__(self, ws):
        self.ws = ws
        self.inbox = asyncio.Queue()
        self.codex = CodexLive(lambda m: self.inbox.put_nowait(("dc", m)), self._on_audio, self._on_codex_closed)
        self.resp = None
        self.wants = []
        self.pre = []               # buffered ("a", bytes) / ("t", str) while no response is open
        self.pre_since = 0.0
        self.ring = []              # short pre-roll of downlink audio kept while idle
        self.turn_open = False
        self.tail_until = 0.0
        self.last_voice = 0.0
        self.user_open = False          # the user is mid-turn (speech_started sent, transcript not yet)
        self.user_id = None
        self.user_pieces = []
        self.user_emitted = False
        self.last_user_voice = 0.0      # last time the browser microphone carried speech-level energy
        self.await_create_until = 0.0   # after a transcript: give Open WebUI time to send response.create
        self.calls = {}           # call_id -> delegation item id (outstanding function calls)
        self.queued = None          # one queued delegation while busy
        self.deferred = None        # delegation waiting for the user's transcript to be handed to Open WebUI
        self.hold_for = None        # call_id whose result response must finish before the queue is released
        self.hold_until = 0.0
        self.last_context = ""
        self.alive = True
        self.reason = ""

    # ---- helpers
    def _on_audio(self, pcm: bytes):
        self.inbox.put_nowait(("audio", pcm))

    def _on_codex_closed(self, reason: str):
        self.reason = reason
        self.alive = False
        self.inbox.put_nowait(("closed", reason))

    async def send(self, obj):
        if self.ws.closed:
            self.alive = False
            return
        await self.ws.send_json(obj)

    def assistant_active(self, now):
        return self.turn_open or now < self.tail_until

    # ---- response lifecycle
    async def open_response(self, meta):
        r = Resp(meta)
        self.resp = r
        await self.send(ev("response.created", response={"id": r.id, "object": "realtime.response", "status": "in_progress", "metadata": r.meta, "output": []}))
        pre, self.pre = self.pre, []
        if any(k == "a" for k, _ in pre):
            self.last_voice = time.monotonic()      # buffered audio is fresh to the listener, whatever its age
        for kind, val in pre:
            await self._emit(kind, val)

    async def _emit(self, kind, val):
        r = self.resp
        if r is None:
            return
        r.last_activity = time.monotonic()
        if kind == "a":
            r.spoke = True
            r.abytes += len(val)
            await self.send(ev("response.output_audio.delta", response_id=r.id, item_id=r.item_id, output_index=0, content_index=0, delta=base64.b64encode(val).decode()))
        else:
            r.text += val
            await self.send(ev("response.output_audio_transcript.delta", response_id=r.id, item_id=r.item_id, output_index=0, content_index=0, delta=val))

    async def close_response(self, status="completed", why=""):
        r = self.resp
        if r is None:
            return
        log.info("response closed: %s status=%s audio=%.1fs func=%s chars=%d age=%.1fs call=%s silent=%.1fs turn_open=%s", why or "-", status,
                 r.abytes / 48000, bool(r.func_at), len(r.text), time.monotonic() - r.opened, r.meta.get("call_id", "-"),
                 time.monotonic() - self.last_voice, self.turn_open)
        self.resp = None
        if r.text:
            await self.send(ev("response.output_audio_transcript.done", response_id=r.id, item_id=r.item_id, output_index=0, content_index=0, transcript=r.text))
        await self.send(ev("response.done", response={"id": r.id, "object": "realtime.response", "status": status, "metadata": r.meta, "output": []}))
        if self.hold_for and r.meta.get("call_id") == self.hold_for:
            self.hold_for = None
        if self.wants:
            await self.open_response(self.wants.pop(0))

    async def route(self, kind, val):
        if self.resp is not None:
            await self._emit(kind, val)
        else:
            if not self.pre:
                self.pre_since = time.monotonic()
            self.pre.append((kind, val))
            if len(self.pre) > 4000:
                del self.pre[:1000]

    # ---- Codex -> Open WebUI
    async def on_audio(self, pcm: bytes):
        now = time.monotonic()
        a = np.frombuffer(pcm, dtype=np.int16)
        rms = float(np.sqrt(np.mean(a.astype(np.float32) ** 2))) if a.size else 0.0
        if rms > VOICED_RMS:
            self.last_voice = now
        forwarding = self.assistant_active(now) or (now - self.last_voice) < QUIET_FOR
        if forwarding:
            if self.ring and self.resp is None and not self.pre:      # include a little pre-roll when speech starts
                for chunk in self.ring:
                    await self.route("a", chunk)
            self.ring = []
            await self.route("a", pcm)
        else:
            self.ring.append(pcm)
            if len(self.ring) > 8:
                self.ring.pop(0)

    async def on_dc(self, m: dict):
        t = m.get("type")
        now = time.monotonic()
        if t == "turn.created":
            turn = m.get("turn", {})
            if turn.get("role") == "user":
                if self.resp is not None and (self.resp.spoke or self.assistant_active(now)):
                    await self.close_response("cancelled", "barge-in")
                self.pre = []; self.turn_open = False; self.tail_until = 0.0; self.user_open = True
                self.user_id, self.user_pieces, self.user_emitted = turn.get("id"), [], False
                await self.send(ev("input_audio_buffer.speech_started", item_id=turn.get("id"), audio_start_ms=turn.get("start_ms", 0)))
            else:
                self.turn_open = True
                await self.finish_user_early(now)          # GPT-Live is answering, so the user's turn is over
        elif t == "input_transcript.added":
            if self.user_open and not self.user_emitted:
                self.user_pieces.append(str((m.get("item") or {}).get("text") or ""))
        elif t == "turn.done":
            turn = m.get("turn", {})
            if turn.get("role") == "user":
                if self.user_id is None:
                    self.user_id = turn.get("id")
                await self.finish_user(str(turn.get("transcript") or "").strip(), turn.get("end_ms", 0), now)
            else:
                self.turn_open = False
                self.tail_until = now + ASSISTANT_TAIL
                if self.resp is not None and not self.resp.text and turn.get("transcript"):
                    await self._emit("t", str(turn["transcript"]))
        elif t == "output_transcript.added":
            txt = (m.get("item") or {}).get("text")
            if txt:
                await self.route("t", txt)
        elif t == "delegation.created":
            await self.on_delegation(m.get("item") or {})
        elif t == "error":
            code = (m.get("error") or {}).get("code") or "error"
            log.warning("codex data-channel error: %s", code)
            await self.send(ev("error", error={"type": "server_error", "code": str(code), "message": "voice backend error"}))

    async def finish_user(self, text, end_ms, now):
        """Hand the user's finished turn to Open WebUI exactly once (by the early path or by Codex's turn.done)."""
        if self.user_emitted or self.user_id is None:
            return
        self.user_emitted = True
        self.user_open = False
        self.await_create_until = now + 2.0 if text else 0.0
        await self.send(ev("input_audio_buffer.speech_stopped", item_id=self.user_id, audio_end_ms=end_ms))
        if text:
            await self.send(ev("conversation.item.input_audio_transcription.completed", item_id=self.user_id, content_index=0, transcript=text))
        else:
            await self.send(ev("conversation.item.input_audio_transcription.failed", item_id=self.user_id, content_index=0, error={"type": "transcription_error", "message": "empty transcript"}))

    async def finish_user_early(self, now):
        """Codex finalizes the transcript about a second after it starts answering; Open WebUI waits for it before
        asking for a response. If the microphone has gone quiet, release the words heard so far instead."""
        text = "".join(self.user_pieces).strip()
        if self.user_open and not self.user_emitted and text and now - self.last_user_voice > 0.4:
            await self.finish_user(text, 0, now)

    def note_uplink(self, pcm: bytes):
        n = len(pcm) // 2
        if n:
            a = np.frombuffer(pcm[: n * 2], dtype=np.int16).astype(np.float32)
            if float(np.sqrt(np.mean(a * a))) > 400:
                self.last_user_voice = time.monotonic()

    async def on_delegation(self, item: dict):
        req = " ".join(str(c.get("text", "")) for c in (item.get("content") or []) if isinstance(c, dict)).strip()
        did = str(item.get("id") or "")
        call_id = str(item.get("handoff_id") or did)
        await self.finish_user_early(time.monotonic())
        if is_filler(req):
            return self.append_result(did, "The user was just chatting, not asking for work. Reply briefly and naturally. Nothing to run.")
        if self.calls or self.deferred:
            self.queued = {"req": req, "did": did, "call_id": call_id}
            return self.append_result(did, "A task is already in progress. Tell the user you are still on it and will do this next, right after. If what they said is a correction, it will be reflected in the result.")
        # GPT-Live often delegates before the spoken request is fully transcribed: hand the user's transcript to
        # Open WebUI first, then the function call, so the call belongs to the response that answers that turn.
        self.deferred = {"req": req, "did": did, "call_id": call_id}

    async def emit_call(self, req, did, call_id):
        if self.resp is None:
            await self.open_response(self.wants.pop(0) if self.wants else {})
        r = self.resp
        self.calls[call_id] = did
        r.func_at = time.monotonic(); r.last_activity = r.func_at
        await self.send(ev("response.output_item.done", response_id=r.id, output_index=1, item={
            "id": "fc_" + secrets.token_hex(6), "type": "function_call", "status": "completed", "name": "generate_chat_completion",
            "call_id": call_id, "arguments": json.dumps({"request": req[:32000]})}))

    def append_result(self, did, text):
        self.codex.send_dc({"type": "delegation.context.append", "delegation_item_id": did,
                            "content": [{"type": "input_text", "text": text[:RESULT_MAX_CHARS]}]})

    # ---- Open WebUI -> Codex
    async def on_client(self, e: dict):
        t = e.get("type")
        if t == "response.create":
            r = e.get("response") or {}
            meta = {k: v for k, v in (r.get("metadata") or {}).items() if k in ("input_item_id", "call_id", "status")}
            self.await_create_until = 0.0
            if r.get("conversation") == "none":                     # status line request: nothing for GPT-Live to say
                if self.resp is None:
                    await self.open_response(meta); await self.close_response(why="status")
                return
            if self.resp is not None and not self.resp.spoke and not self.resp.func_at and not self.resp.meta and not self.resp.text:
                await self.close_response(why="replaced by requested")  # empty auto-opened response
            if self.resp is None:
                await self.open_response(meta)
            else:
                self.wants.append(meta)
        elif t == "response.cancel":
            if self.resp is not None and self.resp.id == e.get("response_id"):
                self.pre = []
                await self.close_response("cancelled", "client cancel")
        elif t == "conversation.item.create":
            item = e.get("item") or {}
            if item.get("type") == "function_call_output":
                await self.on_result(item)
            elif item.get("type") == "message":
                text = " ".join(str(c.get("text", "")) for c in item.get("content") or [] if isinstance(c, dict)).strip()
                if text and text != self.last_context:
                    self.last_context = text
                    self.codex.send_dc({"type": "session.context.append", "content": [{"type": "input_text", "text": text[-12000:]}]})

    async def on_result(self, item):
        call_id = str(item.get("call_id"))
        did = self.calls.pop(call_id, None)
        if did is None:
            return
        try:
            out = json.loads(item.get("output") or "{}")
        except Exception:
            out = {"status": "completed", "answer": str(item.get("output"))}
        status, answer = out.get("status", "completed"), plain_for_voice(out.get("answer", ""))
        if status == "completed" and answer:
            text = "Task result. Answer the user with this in your own natural spoken words: headline first, then only the details that matter. Result: " + answer
        elif status == "deferred":
            text = "The task needs the user to finish something in the chat window first (an approval or a question). Tell them briefly to check the chat."
        elif status == "cancelled":
            text = "The task was cancelled. Say so briefly."
        else:
            text = "The task failed: " + (answer or "no details") + ". Tell the user once, simply, and offer to retry. Do not claim anything is still running."
        self.append_result(did, text)
        self.hold_for, self.hold_until = call_id, time.monotonic() + 25

    # ---- periodic housekeeping
    async def tick(self):
        now = time.monotonic()
        silent = now - self.last_voice
        quiet = (not self.assistant_active(now)) and silent > QUIET_FOR
        gated = self.user_open or now < self.await_create_until     # the user's turn is still being handed to Open WebUI
        r = self.resp
        if r is None:
            if self.wants:
                await self.open_response(self.wants.pop(0))
            elif self.pre and not gated:
                meaningful = any(k == "t" for k, _ in self.pre) or sum(len(v) for k, v in self.pre if k == "a") >= 16800
                if meaningful and now - self.pre_since > AUTO_OPEN_AFTER:
                    await self.open_response({})
                elif not meaningful and now - self.pre_since > 3.0:
                    self.pre = []                                   # a stray blip with no words: drop it
        else:
            # GPT-Live keeps ONE assistant turn open across a delegation wait, so close on silence, not on turn end.
            # idle = time since this response last carried anything: audio heard OR text emitted. GPT-Live sends words as
            # text about a second before their audio, so measuring from voiced audio alone would close it too early.
            idle = now - max(self.last_voice, r.last_activity)
            if r.func_at:
                # the same assistant turn can stay open for the whole delegation wait: ignore turn state here
                if idle > CLOSE_QUIET and now - r.func_at > 0.8:
                    await self.close_response(why="function call, silent")
            elif r.spoke or r.text:
                # GPT-Live pauses ~1 s mid-sentence while it reads a delegation result: keep one utterance in one response
                if (not self.turn_open and idle > CLOSE_QUIET) or idle > 4.0:
                    await self.close_response(why="speech ended")
            elif not self.user_open and idle > EMPTY_TIMEOUT:
                await self.close_response(why="empty timeout")
        if self.deferred and not self.user_open and (self.resp is not None or self.wants or now >= self.await_create_until):
            d, self.deferred = self.deferred, None
            await self.emit_call(d["req"], d["did"], d["call_id"])
        if self.hold_for and now > self.hold_until:
            self.hold_for = None
        if self.queued and not self.calls and not self.hold_for and self.resp is None and quiet:
            q, self.queued = self.queued, None
            await self.emit_call(q["req"], q["did"], q["call_id"])

    async def pump(self):
        while self.alive:
            try:
                kind, val = await asyncio.wait_for(self.inbox.get(), 0.1)
            except asyncio.TimeoutError:
                kind, val = "tick", None
            if kind == "dc":
                await self.on_dc(val)
            elif kind == "audio":
                await self.on_audio(val)
            elif kind == "client":
                await self.on_client(val)
            elif kind == "closed":
                break
            await self.tick()


# ----------------------------------------------------------------------------------------------------------------
# HTTP / websocket server
# ----------------------------------------------------------------------------------------------------------------
ACTIVE = set()


def authorized(req: web.Request) -> bool:
    given = req.headers.get("Authorization", "")
    given = given[7:] if given.lower().startswith("bearer ") else req.headers.get("api-key", "")
    return bool(CFG["key"]) and hmac.compare_digest(given.encode(), CFG["key"].encode())


async def realtime(req: web.Request):
    if not authorized(req):
        return web.Response(status=401, text="unauthorized")
    if len(ACTIVE) >= CFG["max_calls"]:
        return web.Response(status=503, text="a call is already active")
    ws = web.WebSocketResponse(heartbeat=20, max_msg_size=1024 * 1024)
    await ws.prepare(req)
    call = Call(ws)
    ACTIVE.add(call)
    t0 = time.monotonic()
    log.info("call started (%d active)", len(ACTIVE))
    pump = None
    try:
        await ws.send_json(ev("session.created", session={"id": "sess_" + secrets.token_hex(8), "object": "realtime.session", "type": "realtime", "model": "gpt-live-1"}))
        started = False
        async for msg in ws:
            if msg.type != WSMsgType.TEXT:
                break
            if time.monotonic() - t0 > CFG["call_seconds"]:
                break
            try:
                e = json.loads(msg.data)
            except Exception:
                continue
            t = e.get("type")
            if t == "session.update" and not started:
                s = e.get("session") or {}
                voice = (((s.get("audio") or {}).get("output") or {}).get("voice") or "")
                voice = voice if voice in V3_VOICES else CFG["voice"]
                prompt = live_persona(False) + "\n\n---\nCALL INSTRUCTIONS FROM THE CHAT APP (follow them, adapting tool names as explained above):\n" + str(s.get("instructions") or "")
                try:
                    await asyncio.wait_for(call.codex.start(prompt, voice), 45)
                except Exception as exc:
                    log.error("codex start failed: %s", type(exc).__name__)
                    await ws.send_json(ev("error", error={"type": "server_error", "code": "codex_start_failed", "message": "could not start GPT-Live"}))
                    break
                started = True
                pump = asyncio.create_task(call.pump())
                await ws.send_json(ev("session.updated", session={"type": "realtime", "model": "gpt-live-1"}))
            elif not started:
                continue
            elif t == "input_audio_buffer.append":
                try:
                    pcm = base64.b64decode(e.get("audio", ""), validate=True)
                    call.codex.push_mic(pcm)
                    call.note_uplink(pcm)
                except Exception:
                    pass
            elif t == "session.update":
                await ws.send_json(ev("session.updated", session={"type": "realtime", "model": "gpt-live-1"}))
            else:
                call.inbox.put_nowait(("client", e))
            if not call.alive:
                break
    except Exception:
        log.exception("call error")
    finally:
        call.alive = False
        if pump:
            pump.cancel()
        await call.codex.close("call ended")
        ACTIVE.discard(call)
        log.info("call ended after %ds (%s)", int(time.monotonic() - t0), call.reason or "client closed")
        if not ws.closed:
            await ws.close()
    return ws


async def health(_req):
    return web.json_response({"ok": True, "active_calls": len(ACTIVE), "live_session": DIRECT["s"] is not None, "api_version": API_VERSION,
                              "active_chats": len(running_jobs()), "live_backend": live_backends()["active"]})


# ----------------------------------------------------------------------------------------------------------------
# Hermes Live: the browser talks WebRTC straight to GPT-Live. This server only brokers the SDP exchange with the Codex
# app-server and runs the delegated Hermes tasks, so there is no audio relay (no extra hops, native turn taking).
# ----------------------------------------------------------------------------------------------------------------
DIRECT = {"s": None}
LIVE_TASKS = set()                              # delegated Hermes tasks, including those of calls that have ended
LIVE_SESSIONS = collections.OrderedDict()       # session id -> session, kept after the call so its jobs stay readable
LIVE_SESSIONS_MAX = 16
LIVE_SESSION_KEEP_S = 3600                      # an ended call's jobs stay readable this long after its last job ends


def remember_session(ds):
    LIVE_SESSIONS[ds.id] = ds
    now = time.monotonic()
    for sid, old in list(LIVE_SESSIONS.items()):
        if old is ds or any(j["status"] == "running" for j in old.jobs.values()) or not old.closed:
            continue
        ended = max([old.closed_at or 0] + [j.get("t_end", 0) for j in old.jobs.values()])
        if now - ended > LIVE_SESSION_KEEP_S or len(LIVE_SESSIONS) > LIVE_SESSIONS_MAX:
            del LIVE_SESSIONS[sid]


class DirectSession:
    """The "codex" backend: codex app-server brokers the SDP and the app runs delegations over the data channel."""
    backend = "codex"

    def __init__(self):
        self.id = secrets.token_urlsafe(9)
        self.proc = None; self.seq = 0; self.pending = {}; self.notifs = asyncio.Queue()
        self.thread_id = None; self.closed = False; self.tasks = []
        self.jobs = {}; self.history = []
        self.last_poll = time.monotonic()       # last /api/job poll: a client that polls sees results itself
        self.conversation_id = None             # chat the call belongs to: task results are saved there
        self.closed_at = None
        self.prepared = False                   # app-server spawned, initialized, its thread started (prepare())
        self.started = False                    # a realtime session was asked for (only then is it "a call")
        self.timing = {}                        # connect stages in ms, for the log and API.md "Connect timing"
        self.ui = 1                             # UI prompt version for task results ("ui" on /api/session)

    async def _read(self):
        try:
            while True:
                line = await self.proc.stdout.readline()
                if not line:
                    break
                try:
                    m = json.loads(line)
                except Exception:
                    continue
                if "id" in m and ("result" in m or "error" in m) and m["id"] in self.pending:
                    self.pending.pop(m["id"]).set_result(m)
                else:
                    self.notifs.put_nowait(m)
        finally:
            await self.close()

    async def rpc(self, method, params, timeout=30):
        self.seq += 1
        fut = asyncio.get_running_loop().create_future()
        self.pending[self.seq] = fut
        self.proc.stdin.write((json.dumps({"jsonrpc": "2.0", "id": self.seq, "method": method, "params": params}) + "\n").encode())
        await self.proc.stdin.drain()
        m = await asyncio.wait_for(fut, timeout)
        if "error" in m:
            raise RuntimeError(str(m["error"].get("message") or m["error"])[:300])
        return m.get("result")

    async def prepare(self):
        """Everything before the realtime session: spawn app-server, initialize, start an ephemeral thread. Costs no
        GPT-Live quota, so the bridge may do it ahead of a call (POST /api/session/warm, LIVE_WARM)."""
        if self.prepared:
            return
        t0 = time.monotonic()
        env = dict(os.environ, CODEX_HOME=CFG["codex_home"])
        env.pop("OPENAI_API_KEY", None); env.pop("CODEX_API_KEY", None)
        os.makedirs(CFG["workdir"], exist_ok=True)
        self.proc = await asyncio.create_subprocess_exec(
            CFG["codex"], "app-server", "--listen", "stdio://", "--enable", "realtime_conversation",
            "-c", "model_provider=openai", "-c", "suppress_unstable_features_warning=true",
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, env=env, limit=8 * 1024 * 1024)
        self.tasks.append(asyncio.create_task(self._read()))
        await self.rpc("initialize", {"clientInfo": {"name": "hermes-live", "version": "1"}, "capabilities": {"experimentalApi": True}})
        t1 = time.monotonic()
        th = await self.rpc("thread/start", {"cwd": CFG["workdir"], "modelProvider": "openai", "approvalPolicy": "never", "sandbox": "read-only", "ephemeral": True})
        self.thread_id = th["thread"]["id"]
        self.timing.update(spawn_init_ms=round((t1 - t0) * 1000), thread_ms=round((time.monotonic() - t1) * 1000))
        self.prepared = True

    async def start(self, offer: str, voice: str) -> str:
        t0 = time.monotonic()
        warm = self.prepared
        await self.prepare()
        t1 = time.monotonic()
        self.started = True
        await self.rpc("thread/realtime/start", {
            "threadId": self.thread_id, "transport": {"type": "webrtc", "sdp": offer}, "outputModality": "audio", "version": "v3",
            "voice": voice, "prompt": live_persona(), "realtimeStartInstructions": NO_CLIENT_HANDOFF,
            "clientManagedHandoffs": True, "delegationAckFiller": True})
        answer, last_error = None, ""
        end = time.time() + 30
        while time.time() < end and not answer:
            try:
                n = await asyncio.wait_for(self.notifs.get(), 1)
            except asyncio.TimeoutError:
                continue
            meth, params = n.get("method"), n.get("params") or {}
            if meth == "thread/realtime/sdp":
                answer = params["sdp"]
            elif meth == "thread/realtime/error":
                raise RuntimeError("codex: " + str(params.get("message"))[:300])
            elif meth == "thread/realtime/closed":
                raise RuntimeError("codex closed: " + str(params.get("reason") or params.get("message") or "")[:300])
            elif meth == "error" and not params.get("willRetry"):
                # app-server's generic error notification (usage limits, auth refresh failures) carries the text in
                # error.message and a machine hint in error.codexErrorInfo. Fail fast only on the ones we recognise.
                err = params.get("error") if isinstance(params.get("error"), dict) else params
                last_error = (str(err.get("message") or "") + " " + json.dumps(err.get("codexErrorInfo") or ""))[:400]
                if classify_start_error(last_error) != "start_failed":
                    raise RuntimeError("codex error: " + last_error)
        if not answer:
            raise TimeoutError("codex: no SDP answer " + last_error)
        t2 = time.monotonic()
        self.timing.update(warm=warm, prepare_ms=round((t1 - t0) * 1000), realtime_sdp_ms=round((t2 - t1) * 1000),
                           start_ms=round((t2 - t0) * 1000))
        self.tasks.append(asyncio.create_task(self._watch()))
        self.tasks.append(asyncio.create_task(self._expire()))
        return answer

    async def _watch(self):
        while not self.closed:
            n = await self.notifs.get()
            if n.get("method") in ("thread/realtime/closed", "thread/realtime/error"):
                await self.close()
                return

    async def _expire(self):
        await asyncio.sleep(CFG["call_seconds"])
        await self.close()

    async def ask_hermes(self, text: str, job=None) -> str:
        """Run one task on Hermes, streamed, so a running job shows its newest tool step and the text so far."""
        msgs = self.history[-8:] + [{"role": "user", "content": VOICE_TASK_NOTE + "\n\n" + text}]
        q, parts = asyncio.Queue(), []
        upstream = asyncio.create_task(hermes_stream(msgs, None, q))
        t0, ttft, tools, usage = time.monotonic(), None, 0, None
        try:
            while True:
                kind, val = await q.get()
                if kind == "delta":
                    parts.append(val)
                    ttft = ttft if ttft is not None else time.monotonic() - t0
                    if job is not None:
                        job["partial"] = "".join(parts)[-MAX_TASK_CHARS:]
                elif kind == "finish":
                    usage = val.get("usage") or usage
                elif kind == "status" and job is not None and val.get("state") != "info":
                    tools += val.get("state") == "running"
                    job["status_event"] = val
                elif kind == "error":
                    raise RuntimeError("hermes " + str(val.get("code")))
                elif kind == "eof":
                    break
        finally:
            if not upstream.done():
                upstream.cancel()
        answer = "".join(parts).strip()
        if job is not None:
            job["usage"] = build_usage(usage, None, duration_ms=round((time.monotonic() - t0) * 1000),
                                       ttft_ms=None if ttft is None else round(ttft * 1000), tool_count=tools, effort=None)
        self.history += [{"role": "user", "content": text}, {"role": "assistant", "content": answer[:2000]}]
        return answer

    def start_job(self, text: str, on_done=None, request=None) -> str:
        """Run one Hermes task. `on_done(job)` runs when it ends (the openai backend speaks the result with it);
        `request` is what is saved as the task text when `text` carries extra call context. Small talk ("bye",
        "thanks") is answered at once without Hermes, and not saved to the chat."""
        jid = secrets.token_hex(4)
        self.jobs[jid] = {"status": "running", "answer": "", "markdown": "", "t0": time.monotonic(), "request": (request or text)[:2000]}
        smalltalk = is_smalltalk(request or text)
        if not smalltalk and self.start_task_message(jid, text, request or text, on_done):
            return jid

        async def run():
            job = self.jobs[jid]
            if smalltalk:
                job.update(status="done", answer=SMALLTALK_ANSWER, markdown="", smalltalk=True)
                log.info("live task skipped: small talk")
            else:
                try:
                    raw = await self.ask_hermes(text, job)
                    job["markdown"], job["answer"] = raw, plain_for_voice(raw)
                    job["status"] = "done"
                except Exception as exc:
                    log.warning("hermes task failed: %s", type(exc).__name__)
                    job["status"] = "failed"
            if on_done is not None:
                try:
                    await on_done(job)
                except Exception as exc:
                    log.warning("task result not delivered to the call: %s", type(exc).__name__)
            if smalltalk:
                return
            msg = save_task_result(self, jid, request or text, job)
            job["t_end"] = time.monotonic()
            if self.closed or time.monotonic() - self.last_poll > PUSH_POLL_GRACE_S:
                notify("live.task", self.conversation_id, msg["id"] if msg else None, job["status"], job.get("markdown", ""))
            emit_event("task.done", conversation_id=self.conversation_id, message_id=msg["id"] if msg else None, session=self.id,
                       job=jid, status=PUSH_STATUS.get(job["status"], job["status"]), seconds=round(time.monotonic() - job["t0"]),
                       **event_text(self.conversation_id, job.get("markdown", "")))
        # Not in self.tasks: a task keeps running when the call ends, so its result still reaches the chat and a push.
        task = asyncio.create_task(run())
        LIVE_TASKS.add(task)
        task.add_done_callback(LIVE_TASKS.discard)
        return jid

    def task_context(self, text):
        """What a task of a linked call sends to Hermes: the app's UI prompt and the user's custom instructions (as
        for a typed turn), the chat's newest messages, then the spoken request with the chat-task note."""
        store = CHAT["store"]
        system = "\n\n".join(p for p in (ui_prompt(self.ui) if CFG["task_ui"] else "",
                                           settings_prompt(store.get_settings()["settings"]) if store is not None else "") if p)
        msgs = ([{"role": "system", "content": system}] if system else []) + self.history[-8:]
        return msgs + [{"role": "user", "content": TASK_CHAT_NOTE + "\n\n" + text}]

    def start_task_message(self, jid, text, request, on_done):
        """A call linked to a chat: the task is written into that chat as an assistant message (`source: task`) from
        the start, streamed like a reply (resume with GET /api/chat/{message_id}/stream), and it keeps running after
        the call ends. False when there is no chat (the job then runs the old way)."""
        store, cid = CHAT["store"], self.conversation_id
        if store is None or not cid or not CFG["hermes_key"]:
            return False
        try:
            asst = store.add_message(cid, "assistant", "", "task", status="streaming", client_id="job:%s:%s" % (self.id, jid),
                                     meta={"task": request[:2000], "job": jid, "session": self.id})
        except sqlite3.Error as exc:
            log.info("task message not created: %s", type(exc).__name__)     # the chat was deleted meanwhile
            return False
        conv = store.get_conversation(cid)
        job = TaskJob(store, conv, asst, self.task_context(text), self, jid, request, on_done).start()
        LIVE_TASKS.add(job.task)
        job.task.add_done_callback(LIVE_TASKS.discard)
        emit_event("task.started", conversation_id=cid, message_id=asst["id"], session=self.id, job=jid,
                   title=(conv or {}).get("title"), request=push_preview(request))
        return True

    async def close(self):
        if self.closed:
            return
        self.closed, self.closed_at = True, time.monotonic()
        if DIRECT["s"] is self:
            DIRECT["s"] = None
        try:
            if self.proc and self.proc.returncode is None and self.thread_id:
                await asyncio.wait_for(self.rpc("thread/realtime/stop", {"threadId": self.thread_id}, timeout=5), 5)
        except Exception:
            pass
        try:
            if self.proc and self.proc.returncode is None:
                self.proc.kill()
        except Exception:
            pass
        for t in self.tasks:
            if t is not asyncio.current_task():
                t.cancel()
        if self.started:
            log.info("live session ended")


# ---- warm start (round 8): a call's slow first part, app-server spawn + initialize + thread/start (~0.2-0.5 s, more
# under load), happens ahead of the call when the app shows intent (opening the app, starting the swipe up, pressing
# the live button): POST /api/session/warm. No realtime session is created, so a warm session costs no GPT-Live quota;
# it is one idle app-server process (~90 MB), killed after LIVE_WARM_S unless a call takes it.
LIVE_WARM = {"s": None, "task": None, "timer": None}
LIVE_WARM_S = 180


def _drop_warm():
    ds, timer = LIVE_WARM["s"], LIVE_WARM["timer"]
    LIVE_WARM.update(s=None, task=None, timer=None)
    if timer is not None:
        timer.cancel()
    if ds is not None and not ds.started:
        asyncio.ensure_future(ds.close())


def ensure_warm():
    """Starts (or keeps alive) one prepared codex session. Returns True when one is ready or being prepared."""
    ds = LIVE_WARM["s"]
    if ds is not None and (ds.closed or (ds.proc is not None and ds.proc.returncode is not None)):
        _drop_warm()
        ds = None
    if ds is None:
        ds = DirectSession()
        task = asyncio.ensure_future(ds.prepare())

        def done(t, ds=ds):
            if t.cancelled() or t.exception() is not None:
                if LIVE_WARM["s"] is ds:
                    _drop_warm()
                log.info("live warm start failed: %s", "cancelled" if t.cancelled() else type(t.exception()).__name__)
        task.add_done_callback(done)
        LIVE_WARM.update(s=ds, task=task)
    if LIVE_WARM["timer"] is not None:
        LIVE_WARM["timer"].cancel()
    LIVE_WARM["timer"] = asyncio.get_running_loop().call_later(LIVE_WARM_S, _drop_warm)
    return True


async def take_warm(wait_s=3.0):
    """The warm session for a call (waiting briefly while it is still preparing), or None."""
    ds, task = LIVE_WARM["s"], LIVE_WARM["task"]
    if ds is None:
        return None
    if task is not None and not task.done():
        try:
            await asyncio.wait_for(asyncio.shield(task), wait_s)
        except Exception:
            pass
    if LIVE_WARM["s"] is not ds:
        return None
    if LIVE_WARM["timer"] is not None:
        LIVE_WARM["timer"].cancel()
    LIVE_WARM.update(s=None, task=None, timer=None)
    if not ds.prepared or ds.closed or ds.proc is None or ds.proc.returncode is not None:
        await ds.close()
        return None
    return ds


async def api_session_warm(req):
    """POST /api/session/warm: prepare a codex session ahead of a likely call (API.md "Warm start"). Free: no quota."""
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    if live_backends()["active"] != "codex":
        return web.json_response({"warm": False, "reason": "backend"})
    cur = DIRECT["s"]
    if cur is not None and not cur.closed:
        return web.json_response({"warm": False, "reason": "in_call"})
    ensure_warm()
    ds = LIVE_WARM["s"]
    return web.json_response({"warm": True, "ready": bool(ds and ds.prepared), "ttl_s": LIVE_WARM_S})


# ----------------------------------------------------------------------------------------------------------------
# The "openai" backend: the documented OpenAI Live API with the operator's own API key. The app's offer goes to
# POST /v1/live/sessions (client delegation) and the answer comes back, so audio still flows straight between the
# app and OpenAI. The key never leaves this server. The bridge attaches a sideband WebSocket to the session and runs
# delegations itself: session.delegation.created -> Hermes job -> session.commentary.append. It also enforces the
# per-call and daily limits and saves the call's transcript to a linked chat.
# Docs: developers.openai.com/api/docs/guides/{live, voice-webrtc?api=live, live-delegation, live-conversations,
# voice-server-controls?api=live}; checked 15 November 2026. API.md "openai backend" lists verified vs assumed parts.
# ----------------------------------------------------------------------------------------------------------------
OPENAI_VOICES = {"marin", "quartz", "ripple", "vesper", "willow", "stone", "gleam", "meridian", "bossa", "tempo", "beacon",
                 "delta", "cinder", "nuri", "juni", "flitz", "brise", "sillage", "nira", "harema", "shida", "noeul"}
# Codex v3 names an older app may send -> a documented API voice. Approximate (chosen by description, not by ear).
V3_TO_OPENAI = {"cove": "marin", "arbor": "meridian", "juniper": "gleam", "maple": "willow", "spruce": "stone", "ember": "cinder",
                "vale": "vesper", "breeze": "quartz", "sol": "delta", "aube": "brise", "bubbie": "ripple"}
COMMENTARY_CHARS = 1800        # session.*.append content is limited to 500 tokens
OPENAI_INIT_SECONDS = 15       # a WebRTC session bills 15 s while it initializes (credited once it runs)
TRANSCRIPT_SETTLE_S = 1.0      # after session.delegation.created, wait for the request's trailing transcript deltas
CALL_TURNS_MAX = 400           # transcript turns kept per call
CALL_CONTEXT_CHARS = 3000      # earlier call transcript sent with a delegated task
OPENAI_SEGMENT_GAP_MS = 1200   # a pause this long between same-speaker transcript deltas separates two sentences
REFLECTED_AUDIO = ('"session.input_audio.append"', '"session.output_audio.delta"')   # sideband audio copies: ignored


def openai_voice(requested):
    if isinstance(requested, str):
        if requested in OPENAI_VOICES:
            return requested
        if requested in V3_TO_OPENAI:
            return V3_TO_OPENAI[requested]
    return CFG["openai_voice"]


def codex_logged_in() -> bool:
    try:
        return os.path.getsize(os.path.join(CFG["codex_home"], "auth.json")) > 0
    except OSError:
        return False


def live_backends() -> dict:
    """Which GPT-Live backends could work and which one /api/session uses. Never includes a key."""
    codex, openai = codex_logged_in(), bool(CFG["openai_key"])
    choice = CFG["live_backend"]
    if choice == "auto":
        active = "codex" if codex else ("openai" if openai else "codex")    # nothing set up: codex explains the login
    else:
        active = choice
    return {"codex": codex, "openai": openai, "active": active, "choice": choice}


class UsageLedger:
    """OpenAI voice seconds per local day, in a small JSON file so a restart keeps the day's budget."""

    def __init__(self, path):
        self.path, self.day, self.seconds = path, None, 0.0
        try:
            data = json.loads(Path(path).read_text())
            self.day, self.seconds = str(data["day"]), max(0.0, float(data["seconds"]))
        except (OSError, ValueError, TypeError, KeyError):
            pass

    @staticmethod
    def today(now=None):
        return time.strftime("%Y-%m-%d", time.localtime(now))

    def used(self, now=None):
        return self.seconds if self.day == self.today(now) else 0.0

    def add(self, seconds, now=None):
        day = self.today(now)
        if self.day != day:
            self.day, self.seconds = day, 0.0
        self.seconds += max(0.0, float(seconds))
        try:
            os.makedirs(os.path.dirname(self.path) or ".", mode=0o700, exist_ok=True)
            tmp = self.path + ".tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump({"day": self.day, "seconds": round(self.seconds, 1)}, f)
            os.replace(tmp, self.path)
        except OSError as exc:
            log.warning("openai usage not saved: %s", type(exc).__name__)


USAGE = {"ledger": None}


def usage_ledger() -> UsageLedger:
    if USAGE["ledger"] is None or USAGE["ledger"].path != CFG["usage_file"]:
        USAGE["ledger"] = UsageLedger(CFG["usage_file"])
    return USAGE["ledger"]


def openai_seconds_left(now=None):
    """Seconds of today's budget left, counting a running openai call; None when there is no budget."""
    if not CFG["openai_daily_min"]:
        return None
    ds = DIRECT["s"]
    running = ds.billed_seconds(now) if isinstance(ds, OpenAISession) and not ds.booked else 0.0
    return max(0.0, CFG["openai_daily_min"] * 60 - usage_ledger().used(now) - running)


def seconds_to_midnight(now=None):
    t = time.localtime(now)
    return max(1, 86400 - (t.tm_hour * 3600 + t.tm_min * 60 + t.tm_sec))


def clip_for_voice(text, limit=COMMENTARY_CHARS):
    text = re.sub(r"\s+", " ", str(text or "")).strip()
    if len(text) <= limit:
        return text
    cut = text[:limit]
    end = max(cut.rfind(". "), cut.rfind("! "), cut.rfind("? "))
    return (cut[: end + 1] if end > limit // 2 else cut.rstrip() + "…") + " (The full answer is in the chat.)"


class OpenAIStartError(Exception):
    """POST /v1/live/sessions failed: HTTP status, OpenAI's error object and the Retry-After header."""

    def __init__(self, status, error=None, retry_after=None, code=None):
        self.status, self.error, self.retry_after, self.code = status, error if isinstance(error, dict) else {}, retry_after, code
        super().__init__("openai http %s %s" % (status, self.error.get("code") or self.error.get("type") or ""))


class OpenAISession(DirectSession):
    backend = "openai"

    def __init__(self):
        super().__init__()
        self.oai_id = None; self.created_at = None; self.ended_at = None
        self.usage_s = None; self.final_usage = None; self.close_reason = None; self.booked = False
        self.http = None; self.ws = None; self.sideband = "connecting"     # connecting | attached | lost | failed
        self.turns = []                          # [{"role", "text", "start_ms"}] from the transcript deltas
        self.cutoff = 0                          # turns before this index were already sent with a delegation
        self.delegations = {}                    # delegation id -> job id (None while the request settles)
        self.seen = collections.deque(maxlen=1024); self.seen_ids = set()
        self.closed_event = asyncio.Event()
        self.limit_s = None

    def _auth(self):
        return {"Authorization": "Bearer " + CFG["openai_key"]}

    def session_body(self, offer, voice):
        session = {"model": CFG["openai_model"], "instructions": live_persona(),
                   "audio": {"output": {"voice": voice}}, "delegation": {"type": "client"}}
        seed = [m for m in self.history if m.get("content")][-LIVE_SEED_MESSAGES:]
        if seed:                                 # a linked chat: the voice model starts with its newest messages
            session["input"] = [{"type": "message", "role": m["role"], "content": [
                {"type": "input_text" if m["role"] == "user" else "output_text", "text": m["content"][:2000]}]} for m in seed]
        return {"session": session, "transport": {"type": "webrtc", "sdp": offer}}

    def billed_seconds(self, now=None):
        if self.created_at is None:
            return 0.0
        if self.final_usage is not None:
            return float(self.final_usage)
        wall = (self.ended_at or (now if now is not None else time.time())) - self.created_at
        return max(float(self.usage_s or 0), wall, float(OPENAI_INIT_SECONDS))

    async def start(self, offer: str, voice: str) -> str:
        if not CFG["openai_key"]:
            raise OpenAIStartError(503, code="openai_unconfigured")
        self.http = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=None, sock_connect=15))
        try:
            async with self.http.post(CFG["openai_url"] + "/live/sessions", json=self.session_body(offer, voice), headers=self._auth(),
                                      timeout=aiohttp.ClientTimeout(total=30)) as r:
                try:
                    data = await r.json(content_type=None)
                except ValueError:
                    data = None
                if r.status not in (200, 201):
                    raise OpenAIStartError(r.status, (data or {}).get("error") if isinstance(data, dict) else None,
                                           r.headers.get("Retry-After"))
        except aiohttp.ClientError as exc:
            raise RuntimeError("openai unreachable: " + type(exc).__name__)
        data = data if isinstance(data, dict) else {}
        sid = (data.get("session") or {}).get("id") if isinstance(data.get("session"), dict) else None
        answer = (data.get("transport") or {}).get("sdp") if isinstance(data.get("transport"), dict) else None
        if not isinstance(sid, str) or not sid or not isinstance(answer, str) or not answer.startswith("v=0"):
            raise RuntimeError("openai: no SDP answer")
        self.oai_id, self.created_at = sid, time.time()
        left = openai_seconds_left()                      # this session counts already: it is DIRECT["s"]
        self.limit_s = min(CFG["call_seconds"], CFG["openai_call_min"] * 60,
                           *([max(left + OPENAI_INIT_SECONDS, OPENAI_INIT_SECONDS)] if left is not None else []))
        self.tasks.append(asyncio.create_task(self._sideband()))
        self.tasks.append(asyncio.create_task(self._expire()))
        return answer

    async def _expire(self):
        await asyncio.sleep(self.limit_s)
        log.info("openai live call reached its time limit")
        await self.close()

    def _spawn(self, coro):
        t = asyncio.create_task(coro)
        self.tasks.append(t)
        return t

    async def _sideband(self):
        url = re.sub(r"^http", "ws", CFG["openai_url"]) + "/live/sessions/%s/attach" % urllib.parse.quote(self.oai_id, safe="")
        failures = 0
        while not self.closed and not self.closed_event.is_set() and failures < 4:
            try:
                self.ws = await self.http.ws_connect(url, headers=self._auth(), heartbeat=20, max_msg_size=8 * 1024 * 1024,
                                                     timeout=aiohttp.ClientWSTimeout(ws_close=5))
            except (aiohttp.ClientError, asyncio.TimeoutError, OSError) as exc:
                failures += 1
                log.warning("openai sideband attach failed (%s, try %d)", type(exc).__name__, failures)
                await asyncio.sleep(failures)
                continue
            self.sideband, failures = "attached", 0
            try:
                async for msg in self.ws:
                    if msg.type != WSMsgType.TEXT:
                        if msg.type in (WSMsgType.CLOSED, WSMsgType.CLOSING, WSMsgType.ERROR):
                            break
                        continue
                    head = msg.data[:160]
                    if any(name in head for name in REFLECTED_AUDIO):
                        continue
                    try:
                        m = json.loads(msg.data)
                    except ValueError:
                        continue
                    if isinstance(m, dict):
                        await self._on_event(m)
            except Exception as exc:
                log.warning("openai sideband dropped: %s", type(exc).__name__)
            if not self.closed and not self.closed_event.is_set():
                self.sideband = "lost"
                failures += 1                    # re-attach: the 3 s replay window is deduplicated by event_id
                await asyncio.sleep(0.5)
        if not self.closed and not self.closed_event.is_set():
            self.sideband = "failed"
            log.warning("openai sideband unavailable: delegations and time limits are off for this call")

    def _new(self, m) -> bool:
        eid = m.get("event_id")
        if not isinstance(eid, str):
            return True
        if eid in self.seen_ids:
            return False
        if len(self.seen) == self.seen.maxlen:
            self.seen_ids.discard(self.seen[0])
        self.seen.append(eid); self.seen_ids.add(eid)
        return True

    async def _on_event(self, m):
        if not self._new(m):
            return
        kind = m.get("type")
        if kind == "session.input_transcript.delta":
            self._transcript("user", m)
        elif kind == "session.output_transcript.delta":
            self._transcript("assistant", m)
        elif kind == "session.delegation.created":
            d = m.get("delegation") if isinstance(m.get("delegation"), dict) else {}
            did = d.get("id")
            if isinstance(did, str) and did and d.get("target", "client") == "client" and did not in self.delegations:
                self.delegations[did] = None
                self._spawn(self._delegate(did))
        elif kind == "session.usage.updated":
            secs = (m.get("usage") or {}).get("seconds") if isinstance(m.get("usage"), dict) else None
            if isinstance(secs, (int, float)) and not isinstance(secs, bool):
                self.usage_s = secs
        elif kind == "session.closed":
            secs = (m.get("usage") or {}).get("seconds") if isinstance(m.get("usage"), dict) else None
            if isinstance(secs, (int, float)) and not isinstance(secs, bool):
                self.final_usage = secs
            self.close_reason = str(m.get("reason") or "")[:40]
            self.closed_event.set()
            asyncio.create_task(self.close())
        elif kind == "error":
            err = m.get("error") if isinstance(m.get("error"), dict) else {}
            log.info("openai live error event: %s", str(err.get("code") or err.get("type") or "unknown")[:60])

    def _transcript(self, role, m):
        """Transcript deltas carry only start_ms/end_ms (no turn ids). Same-speaker deltas extend the open turn; a
        pause starts a new segment (joined with a space, so two replies do not run together as "now.Goodbye"), and a
        long pause (VOICE_JOIN_GAP_MS) a new turn."""
        delta = m.get("delta")
        if not isinstance(delta, str) or not delta:
            return
        start, end = _ms(m.get("start_ms")), _ms(m.get("end_ms"))
        last = self.turns[-1] if self.turns and self.turns[-1]["role"] == role else None
        gap = start - last["end_ms"] if last is not None and start is not None and last.get("end_ms") is not None else None
        if last is not None and (gap is None or gap <= VOICE_JOIN_GAP_MS):
            if len(last["text"]) < MAX_MESSAGE_CHARS:
                if gap is not None and gap > OPENAI_SEGMENT_GAP_MS and last["text"][-1:].strip() and delta[:1].strip():
                    delta = " " + delta
                last["text"] += delta
            last["end_ms"] = end if end is not None else (start if start is not None else last.get("end_ms"))
            return
        self.turns.append({"role": role, "text": delta, "start_ms": start, "end_ms": end if end is not None else start})
        if len(self.turns) > CALL_TURNS_MAX:
            drop = len(self.turns) - CALL_TURNS_MAX
            del self.turns[:drop]
            self.cutoff = max(0, self.cutoff - drop)

    def task_text(self):
        """(request, text for Hermes): the user's newest turn (preferably one not delegated yet; the assistant's
        acknowledgement may already have started), plus the call transcript before it as context."""
        users = [i for i, t in enumerate(self.turns) if t["role"] == "user" and t["text"].strip()]
        fresh = [i for i in users if i >= self.cutoff]
        at = (fresh or users or [None])[-1]
        if at is None:
            return "", ""
        request = self.turns[at]["text"].strip()[:MAX_MESSAGE_CHARS]
        earlier, total = [], 0
        for t in reversed(self.turns[:at]):
            line = ("User: " if t["role"] == "user" else "Assistant: ") + t["text"].strip()
            if total + len(line) > CALL_CONTEXT_CHARS:
                break
            earlier.append(line); total += len(line)
        self.cutoff = at + 1
        if not earlier:
            return request, request
        return request, ("Earlier in this call (voice transcript):\n" + "\n".join(reversed(earlier)) +
                         "\n\nThe request to handle now: " + request)

    async def send(self, obj):
        if self.ws is None or self.ws.closed:
            return False
        await self.ws.send_str(json.dumps({"event_id": "evt_" + secrets.token_hex(8), **obj}))
        return True

    async def say(self, did, content):
        return await self.send({"type": "session.commentary.append", "delegation_id": did, "content": clip_for_voice(content)})

    async def _delegate(self, did):
        await asyncio.sleep(TRANSCRIPT_SETTLE_S)
        if self.closed:
            return
        request, text = self.task_text()
        if not request:
            await self.say(did, "I didn't catch the request. Ask the user to say it again.")
            return
        if not CFG["hermes_key"]:
            await self.say(did, "The backend is not configured on this server, so the task can't run.")
            return
        if sum(1 for j in self.jobs.values() if j["status"] == "running") >= CFG["max_jobs"] or len(LIVE_TASKS) >= 2 * CFG["max_jobs"]:
            await self.say(did, "Too many tasks are already running. Tell the user you will do this one once they finish.")
            return

        async def deliver(job):
            if job["status"] == "done":
                await self.say(did, job["answer"] or "The task finished without anything to report.")
            else:
                await self.say(did, "The task failed: the backend could not finish it.")
        self.delegations[did] = self.start_job(text, on_done=deliver, request=request)

    def _book(self):
        if self.booked or self.created_at is None:
            return
        self.booked = True
        usage_ledger().add(self.billed_seconds())

    def save_transcript(self):
        """A linked chat keeps the call's spoken turns (the app gets no turn events from this backend)."""
        store, cid = CHAT["store"], self.conversation_id
        if store is None or not cid or not self.turns:
            return 0
        base, added, first_user = int((self.created_at or time.time()) * 1000), 0, None
        merged, _ = merge_voice_turns([{"role": t["role"], "text": t["text"], "created": base + (t["start_ms"] or i), "id": "%s-%d" % (self.id, i)}
                                       for i, t in enumerate(self.turns)])
        with store.quiet(cid):
            for t in merged:
                text = t["text"]
                try:
                    store.add_message(cid, t["role"], text, "voice", created=t["created"], client_id="turn:" + t["id"],
                                      meta={"session": self.id}, touch=False)
                    added += 1
                    first_user = first_user or (text if t["role"] == "user" else None)
                except sqlite3.Error:
                    pass                              # already saved, or the chat was deleted meanwhile
        if added:
            store.touch(cid, kind="live")
            conv = store.get_conversation(cid)
            if conv and first_user and conv["title_source"] == "auto" and conv["title"] == NEW_CHAT_TITLE:
                store.set_auto_title(cid, simple_title(store.first_user_text(cid) or first_user), "auto")
                if title_mode() != "simple":
                    _background(generate_title(cid, first_user))
        return added

    async def close(self):
        if self.closed:
            return
        self.closed, self.closed_at = True, time.monotonic()
        if DIRECT["s"] is self:
            DIRECT["s"] = None
        try:
            if not self.closed_event.is_set() and await self.send({"type": "session.close"}):
                await asyncio.wait_for(self.closed_event.wait(), 5)       # final usage arrives with session.closed
        except Exception:
            pass
        self.ended_at = time.time()
        self._book()
        try:
            self.save_transcript()
        except Exception as exc:
            log.warning("call transcript not saved: %s", type(exc).__name__)
        for t in self.tasks:
            if t is not asyncio.current_task():
                t.cancel()
        for closer in (self.ws, self.http):
            try:
                if closer is not None:
                    await closer.close()
            except Exception:
                pass
        log.info("live session ended (openai, %d s billed%s)", round(self.billed_seconds()),
                 "" if self.final_usage is not None else ", unconfirmed")


def live_authorized(req: web.Request) -> bool:
    given = req.headers.get("Authorization", "")
    given = given[7:] if given.lower().startswith("bearer ") else ""
    return bool(CFG["live_key"]) and len(CFG["live_key"]) >= 20 and hmac.compare_digest(given.encode(), CFG["live_key"].encode())


def jerr(status, msg, code=None, message=None, headers=None, **extra):
    """JSON error. `error` keeps the text older clients show; `code` is the stable machine code (API.md)."""
    body = {"error": msg, "code": code or re.sub(r"\W+", "_", msg).strip("_"), "message": message or msg, **extra}
    return web.json_response(body, status=status, headers=headers)


async def read_json(req):
    """(body, None) for a JSON object, else (None, error response)."""
    try:
        body = await req.json()
    except web.HTTPRequestEntityTooLarge:
        return None, jerr(413, "too_large", message="request body too large")
    except Exception:
        return None, jerr(400, "bad request", "bad_request")
    if not isinstance(body, dict):
        return None, jerr(400, "bad request", "bad_request")
    return body, None


# Codex app-server start failures, matched on the text it really sends (codex 0.167 strings): "You've hit your usage
# limit. ...", "Usage limit reached. You've reached your usage limit.", rate_limit_reached / usage_limit_reached codes,
# "Your access token could not be refreshed because your refresh token has expired. Please log out and sign in again."
USAGE_LIMIT_RE = re.compile(r"usage.?limit|rate.?limit|quota.?exceeded|out of credits|credits.?depleted|spend cap|too many requests|\b429\b", re.I)
LOGIN_EXPIRED_RE = re.compile(r"sign in again|log ?in again|log out and sign in|refresh.?token|not logged in|login is required|"
                              r"codex login|unauthori[sz]ed|\b401\b|token.?expired|auth_recovery|reauthori[sz]ation|"
                              r"chatgpt auth (?:is )?(?:not available|missing)", re.I)
_UNIT_S = {"s": 1, "m": 60, "h": 3600, "d": 86400}


def classify_start_error(text: str) -> str:
    text = str(text or "")
    if USAGE_LIMIT_RE.search(text):
        return "usage_limit"
    if LOGIN_EXPIRED_RE.search(text):
        return "login_expired"
    return "start_failed"


def retry_after_seconds(text: str, now: float = None):
    text = str(text or "")
    m = re.search(r"(?:try again|retry|resets?)\s+(?:in|after)\s+(?:about\s+)?(\d+(?:\.\d+)?)\s*(s|sec|m|min|h|hr|hour|d|day)[a-z]*\b", text, re.I)
    if m:
        return max(0, round(float(m.group(1)) * _UNIT_S[m.group(2)[0].lower()]))
    m = re.search(r"retry[-_ ]?after[\"'=: ]+(\d+)", text, re.I)
    if m:
        return int(m.group(1))
    m = re.search(r"resets?_?at[\"'=: ]+(\d{9,13})\b", text, re.I)
    if m:
        at = int(m.group(1))
        at = at / 1000 if at > 10 ** 11 else at
        return max(0, round(at - (now if now is not None else time.time())))
    return None


OPENAI_QUOTA_CODES = {"insufficient_quota", "credit_balance_exhausted", "billing_hard_limit_reached",
                      "organization_spend_limit_exceeded", "project_spend_limit_exceeded",
                      "organization_usage_limit_exceeded", "project_usage_limit_exceeded"}


def openai_error_response(exc: "OpenAIStartError"):
    """Map an OpenAI Live session-creation failure to the bridge's codes. Never echoes OpenAI's text (it can name the
    project or organization)."""
    err, status = exc.error, exc.status
    kind, code = str(err.get("type") or ""), str(err.get("code") or "")
    if exc.code == "openai_unconfigured":
        return "openai_unconfigured", jerr(503, "openai_unconfigured", message="LIVE_BACKEND=openai but OPENAI_API_KEY is not set on the server")
    if status in (401, 403) or code in ("invalid_api_key", "invalid_authentication") or kind == "authentication_error":
        return "auth_failed", jerr(502, "auth_failed", message="the server's OpenAI API key was rejected (wrong key, revoked, or no GPT-Live access)",
                                   backend="openai")
    if status == 429 or kind == "insufficient_quota" or code in OPENAI_QUOTA_CODES:
        quota = kind == "insufficient_quota" or code in OPENAI_QUOTA_CODES
        after = None
        if not quota:
            raw = str(exc.retry_after or "").strip()
            after = int(float(raw)) if re.fullmatch(r"\d+(\.\d+)?", raw) else retry_after_seconds(str(err.get("message") or ""))
        return "usage_limit", jerr(429, "usage_limit", message="OpenAI quota or spend limit reached" if quota else "OpenAI rate limit reached",
                                   retry_after_s=after, reason="quota" if quota else "rate_limit", backend="openai",
                                   headers={"Retry-After": str(after)} if after is not None else None)
    return "start_failed", jerr(502, "could not start GPT-Live with the OpenAI API", "start_failed", backend="openai",
                                upstream_status=status if isinstance(status, int) else None)


def start_error_response(exc: BaseException, backend="codex"):
    if isinstance(exc, OpenAIStartError):
        return openai_error_response(exc)
    if backend == "openai":                       # network failure, timeout, or a response without an SDP answer
        return "start_failed", jerr(502, "could not start GPT-Live with the OpenAI API", "start_failed", backend="openai")
    text = str(exc)
    code = classify_start_error(text)
    if code == "usage_limit":
        after = retry_after_seconds(text)
        return code, jerr(429, "usage_limit", message="GPT-Live usage limit reached", retry_after_s=after,
                          headers={"Retry-After": str(after)} if after is not None else None)
    if code == "login_expired":
        return code, jerr(502, "login_expired", message="the ChatGPT login used for GPT-Live has expired; sign in again on the server")
    return code, jerr(502, "could not start GPT-Live (is the ChatGPT login still valid?)", "start_failed")


async def live_page(_req):
    try:
        html = open(PAGE, encoding="utf-8").read()
    except OSError:
        return web.Response(status=404, text="page missing")
    return web.Response(text=html, content_type="text/html", headers={
        "Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; media-src 'self' blob: mediastream:; img-src data:; base-uri 'none'; form-action 'none'"})


async def live_app(req):
    """Serve the Flutter client beside the API; never serve files outside its build."""
    root = Path(CFG["app_dir"]).resolve()
    relative = req.match_info.get("path", "") or "index.html"
    if "\x00" in relative or any(part.startswith(".") for part in Path(relative).parts):
        raise web.HTTPNotFound()
    try:
        target = (root / relative).resolve()
        if not target.is_relative_to(root) or not target.is_file():
            raise web.HTTPNotFound()
    except (OSError, ValueError):
        raise web.HTTPNotFound()
    # Release asset names are not content-hashed, so every file revalidates after a deploy (304s stay cheap).
    return web.FileResponse(target, headers={
        "Cache-Control": "no-store" if target.suffix in (".html", ".js", ".json") else "no-cache",
        "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": "default-src 'self'; script-src 'self' 'wasm-unsafe-eval' 'unsafe-eval' blob:; "
            "style-src 'self' 'unsafe-inline'; connect-src 'self' blob:; img-src 'self' data: blob:; "
            "font-src 'self' data:; media-src 'self' blob: mediastream:; worker-src 'self' blob:; "
            "object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'",
    })


async def live_app_redirect(_req):
    raise web.HTTPFound("/app/")


async def live_apk(_req):
    path = Path(CFG["apk_path"])
    if not path.is_file():
        raise web.HTTPNotFound()
    return web.FileResponse(path, headers={
        "Content-Type": "application/vnd.android.package-archive",
        "Content-Disposition": 'attachment; filename="hermes-live.apk"',
        "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
    })


async def api_session(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    body, bad = await read_json(req)
    if bad:
        return bad
    offer = body.get("offer")
    requested_voice = body.get("voice")
    backend = live_backends()["active"]
    if backend == "openai":
        voice = openai_voice(requested_voice)
    else:
        voice = requested_voice if isinstance(requested_voice, str) and requested_voice in V3_VOICES else CFG["voice"]
    if not isinstance(offer, str) or not offer.startswith("v=0") or len(offer) > 30000:
        return jerr(400, "bad offer", "bad_offer")
    conv_id, seed = body.get("conversation_id"), []
    if conv_id is not None:
        if not valid_id(conv_id):
            return jerr(400, "bad_conversation_id", message="conversation_id must be an id string")
        store = CHAT["store"]
        if store is None:
            return jerr(503, "history_unavailable", message="chat history is not available")
        if store.get_conversation(conv_id) is None:
            return jerr(404, "not_found", message="no such conversation")
        seed = store.live_seed(conv_id)
    if backend == "openai" and not CFG["openai_key"]:
        return jerr(503, "openai_unconfigured", message="LIVE_BACKEND=openai but OPENAI_API_KEY is not set on the server")
    old = DIRECT["s"]
    if old is not None:
        await old.close()                                   # a new device takes over: one live session at a time
    if backend == "openai":
        left = openai_seconds_left()
        if left is not None and left < 60:                  # less than a minute of today's budget: refuse
            after = seconds_to_midnight()
            return jerr(429, "budget_exceeded", message="today's GPT-Live minutes on this server are used up (OPENAI_DAILY_MINUTES)",
                        retry_after_s=after, backend="openai", headers={"Retry-After": str(after)})
    t_req = time.monotonic()
    if backend == "openai":
        ds = OpenAISession()
    else:
        ds = await take_warm() or DirectSession()
    ds.history, ds.conversation_id = seed, conv_id          # delegated tasks see the typed thread
    ds.ui = ui_version(req, body) or 1                      # task results render in the app that started the call
    DIRECT["s"] = ds
    remember_session(ds)
    try:
        answer = await asyncio.wait_for(ds.start(offer, voice), 45)
    except Exception as exc:
        code, response = start_error_response(exc, backend)
        log.error("live start failed: %s (%s, %s)", type(exc).__name__, code, backend)
        await ds.close()
        return response
    if conv_id and CHAT["store"] is not None:
        CHAT["store"].touch(conv_id, kind="live")
    log.info("live session started (%s)%s", backend, " (linked to a chat)" if conv_id else "")
    timing = dict(getattr(ds, "timing", {}) or {}, session_ms=round((time.monotonic() - t_req) * 1000))
    log.info("live connect timing: %s", json.dumps(timing, sort_keys=True))
    out = {"session": ds.id, "answer": answer, "conversation_id": conv_id, "backend": backend, "timing": timing}
    if backend == "openai":
        # The bridge runs delegations and saves the transcript itself; the app must not do either for this call.
        out.update(voice=voice, server_delegation=True, server_transcript=bool(conv_id), max_seconds=round(ds.limit_s))
    return web.json_response(out)


def _session(req, sid, ended_ok=False):
    """The live call `sid`. With `ended_ok`, also a call that has ended (its jobs keep running and stay readable)."""
    ds = DIRECT["s"]
    if ds is not None and not ds.closed and hmac.compare_digest(ds.id.encode(), str(sid or "").encode()):
        return ds
    if not ended_ok:
        return None
    return next((x for x in LIVE_SESSIONS.values() if hmac.compare_digest(x.id.encode(), str(sid or "").encode())), None)


async def api_delegate(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    body, bad = await read_json(req)
    if bad:
        return bad
    ds = _session(req, body.get("session"))
    text = str(body.get("text") or "").strip()
    if ds is None or not text or len(text) > 8000:
        return jerr(400, "no such session or empty task", "bad_task")
    if not CFG["hermes_key"]:
        return jerr(503, "hermes not configured", "hermes_unconfigured")
    if sum(1 for j in ds.jobs.values() if j["status"] == "running") >= CFG["max_jobs"] or len(LIVE_TASKS) >= 2 * CFG["max_jobs"]:
        return jerr(429, "busy")
    return web.json_response({"job": ds.start_job(text)})


async def api_job(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    ds = _session(req, req.match_info["sid"], ended_ok=True)
    if ds is not None:
        ds.last_poll = time.monotonic()
    j = ds.jobs.get(req.match_info["jid"]) if ds else None
    if j is None:
        return jerr(404, "no such job", "not_found")
    # `answer` is the voice-ready plain text; `markdown` is Hermes' original reply for the live canvas.
    return web.json_response(job_public(j))


def job_public(j):
    """A delegated job as /api/job and the jobs list show it. While it runs: the newest Hermes tool step and the reply
    text so far (`status_event`, `partial`; both optional, API.md)."""
    done = j["status"] == "done"
    out = {"status": j["status"], "answer": j["answer"] if done else "", "markdown": j.get("markdown", "") if done else "",
           "seconds": round((j.get("t_end") or time.monotonic()) - j["t0"])}
    for key in ("message_id", "conversation_id"):          # a task of a linked call is this chat message (API.md)
        if j.get(key):
            out[key] = j[key]
    if j.get("stopped"):
        out["stopped"] = True
    if j["status"] == "running":
        if j.get("status_event"):
            out["status_event"] = j["status_event"]
        if j.get("partial"):
            out["partial"] = j["partial"]
    return out


async def api_session_jobs(req):
    """Every job of a live call, newest last. With the openai backend the bridge starts the jobs itself, so this is
    how the app learns about them (job ids are new to it). Also works for codex calls."""
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    ds = _session(req, req.match_info["sid"], ended_ok=True)
    if ds is None:
        return jerr(404, "no such session", "not_found")
    ds.last_poll = time.monotonic()
    jobs = [{"id": jid, "request": j.get("request", ""), **job_public(j)} for jid, j in ds.jobs.items()]
    out = {"session": ds.id, "backend": ds.backend, "jobs": jobs, "ended": ds.closed, "conversation_id": ds.conversation_id}
    if isinstance(ds, OpenAISession):
        out["sideband"] = ds.sideband
    return web.json_response(out)


async def api_stop(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    try:
        body = await req.json()
    except Exception:
        body = {}
    if not isinstance(body, dict):
        return jerr(400, "bad request", "bad_request")
    ds = _session(req, body.get("session"))
    if ds is not None:
        await ds.close()
    return web.json_response({"ok": True})


# ----------------------------------------------------------------------------------------------------------------
# Hermes chat: streaming text chat with Hermes Agent, chat history in SQLite, live calls linked to a chat.
# The wire contract for the app is API.md beside this file; keep the two in step.
# ----------------------------------------------------------------------------------------------------------------
API_VERSION = 2
EFFORTS = {"instant": "low", "medium": "medium", "high": "high"}   # app effort -> Hermes model_options.reasoning_effort
FAST_EFFORTS = {"instant"}   # efforts that keep Hermes' default (priority-tier) provider; others use CFG["standard_provider"]
MAX_MESSAGE_CHARS = 8000
MAX_TITLE_CHARS = 120
MAX_TASK_CHARS = 32000
MAX_QUERY_CHARS = 200
PAGE_DEFAULT, PAGE_MAX = 30, 100            # conversations per page
MSG_PAGE_DEFAULT, MSG_PAGE_MAX = 50, 200    # messages per page
MAX_TURNS, MAX_TASKS = 500, 50              # per live-transcript request
CONTEXT_MESSAGES, CONTEXT_CHARS = 40, 48000     # history sent to Hermes with each chat turn
LIVE_SEED_MESSAGES, LIVE_SEED_CHARS = 8, 6000   # history a linked live call's tasks start with
KEEPALIVE_S = 15.0
CHAT_TIMEOUT_S = 900
TITLE_TIMEOUT_S = 20
NEW_CHAT_TITLE = "New chat"
ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
CHAT = {"store": None, "active": 0, "bg": set(), "jobs": {}}   # jobs: message_id -> ChatJob (running or recently finished)


def now_ms() -> int:
    return int(time.time() * 1000)


def new_id() -> str:
    return secrets.token_urlsafe(12)


def valid_id(v) -> bool:
    return isinstance(v, str) and bool(ID_RE.match(v))


TITLE_LEAD_RE = re.compile(r"^(?:(?:(?:hey|hi|hello)(?: there)?|yo|ok(?:ay)?|so|um+|uh+|well|oh)\b[\s,.!-]*)+", re.I)
TITLE_ASK_RE = re.compile(r"^(?:(?:can|could|would|will) you(?: please)?|please|i (?:want|need|would like) (?:you )?to|"
                          r"help me(?: to)?|tell me)\b[\s,]*", re.I)


def simple_title(text: str) -> str:
    """The rule-based title (no model call): the user's first message without a leading greeting or "can you", with a
    capital first letter and no final question mark, cut at a word to 40 characters. A message that is only a
    greeting ("hi there") keeps its words."""
    t = " ".join(str(text or "").split())
    core = TITLE_ASK_RE.sub("", TITLE_LEAD_RE.sub("", t), count=1)
    name = CFG["assistant_name"].strip()
    if name and core.lower().startswith(name.lower()) and core[len(name):len(name) + 1] in (",", "!", ".", ""):
        core = core[len(name):].lstrip(" ,!.")
    if len(core.split()) >= 2:
        t = core
    first = re.match(r"(.{6,}?[.?!])(?:\s|$)", t)          # several sentences: the first one names the chat
    if first and len(first.group(1).split()) >= 2:
        t = first.group(1)
    t = t.rstrip(" ?.!")
    t = t[:1].upper() + t[1:]
    if len(t) <= 40:
        return t or NEW_CHAT_TITLE
    cut = t[:40]
    space = cut.rfind(" ")
    if t[40] != " " and space >= 20:          # do not end on half a word
        cut = cut[:space]
    return cut.rstrip(" ,.;:-") + "…"


SNIPPET_CHARS = 160                     # plain-text search snippets, ellipses included (API.md)


def plain_text(md: str) -> str:
    """Markdown to one line of plain text for search snippets: tables become "cell · cell", fences, emphasis,
    headings, quotes and list markers go, links and images keep their text."""
    lines = []
    for ln in str(md or "").splitlines():
        s = ln.strip()
        if re.match(r"^(```|~~~)", s):
            s = s[3:].strip()
            s = "" if re.fullmatch(r"[\w+#.-]*", s) else s.rstrip("`~").strip()   # drop "```python", keep inline content
        if re.fullmatch(r"\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?", s) or re.fullmatch(r"(?:[-*_]\s*){3,}", s):
            continue                                       # table separator row, horizontal rule
        if s.count("|") >= 2 or (s.startswith("|") and s.endswith("|")):
            s = " · ".join(c.strip() for c in s.strip("|").split("|") if c.strip())
        s = re.sub(r"^#{1,6}\s+", "", s)
        s = re.sub(r"^(?:>\s*)+", "", s)
        s = re.sub(r"^(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?", "", s)
        lines.append(s)
    t = " ".join(x for x in lines if x)
    t = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", t)        # [text](url), ![alt](src)
    t = re.sub(r"<(https?://[^>\s]+)>", r"\1", t)
    t = re.sub(r"`+([^`]*)`+", r"\1", t)
    t = re.sub(r"(\*\*|__)(?=\S)(.+?)(?<=\S)\1", r"\2", t)
    t = re.sub(r"(?<![\w*])\*(?=\S)([^*]+?)(?<=\S)\*(?!\w)", r"\1", t)
    t = re.sub(r"(?<![\w_])_(?=\S)([^_]+?)(?<=\S)_(?![\w_])", r"\1", t)
    t = re.sub(r"~~(?=\S)(.+?)(?<=\S)~~", r"\1", t)
    t = re.sub(r"`+", "", t)
    return " ".join(t.split())


def make_snippet(text: str, tokens, limit=SNIPPET_CHARS):
    """(snippet, [start, end] of the first match inside it or None): plain text centred on the first word that
    starts with one of the query tokens, with "…" where it was cut, at most `limit` characters."""
    t = plain_text(text)
    m = None
    if tokens:
        pat = r"(?<!\w)(?:%s)\w*" % "|".join(re.escape(x) for x in sorted(tokens, key=len, reverse=True))
        m = re.search(pat, t, re.I | re.UNICODE)
    if len(t) <= limit:
        return t, ([m.start(), m.end()] if m else None)
    ms, me = (m.start(), min(m.end(), m.start() + limit - 2)) if m else (0, 0)
    room = limit - 2 - (me - ms)                            # two ellipses at most
    start = max(0, ms - room // 2)
    end = min(len(t), start + (limit - 2))
    start = max(0, end - (limit - 2))
    if start > 0:                                           # do not start or end on half a word
        sp = t.find(" ", start, ms)
        if sp != -1 and sp - start < 20:
            start = sp + 1
    if end < len(t):
        sp = t.rfind(" ", me, end)
        if sp != -1 and end - sp < 20:
            end = sp
    out = t[start:end].strip()
    lead = start > 0
    shift = (1 if lead else 0) - start - (len(t[start:end]) - len(t[start:end].lstrip()))
    snippet = ("…" if lead else "") + out + ("…" if end < len(t) else "")
    return snippet, ([ms + shift, me + shift] if m else None)


def clean_title(text: str) -> str:
    line = next((ln for ln in str(text or "").splitlines() if ln.strip()), "")
    line = re.sub(r"^(?:title\s*:\s*)", "", line.strip(), flags=re.I)
    line = " ".join(line.strip(" \t\"'`*#_“”‘’").split()).rstrip(".!:;,")
    return line[:60].strip()


SCHEMA = """
CREATE TABLE IF NOT EXISTS conversations(
  id TEXT PRIMARY KEY, title TEXT NOT NULL, title_source TEXT NOT NULL DEFAULT 'auto',
  pinned INTEGER NOT NULL DEFAULT 0, kind TEXT NOT NULL DEFAULT 'text',
  created INTEGER NOT NULL, updated INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS conversations_updated ON conversations(updated DESC, id DESC);
CREATE TABLE IF NOT EXISTS messages(
  seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  role TEXT NOT NULL, text TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT 'text',
  status TEXT NOT NULL DEFAULT 'complete', created INTEGER NOT NULL, client_id TEXT,
  meta_json TEXT NOT NULL DEFAULT '{}');
CREATE INDEX IF NOT EXISTS messages_conv ON messages(conversation_id, created, seq);
CREATE UNIQUE INDEX IF NOT EXISTS messages_client ON messages(conversation_id, client_id) WHERE client_id IS NOT NULL;
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(text, content='messages', content_rowid='seq',
  tokenize='unicode61 remove_diacritics 2');
CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
  INSERT INTO messages_fts(rowid, text) VALUES (new.seq, new.text); END;
CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
  INSERT INTO messages_fts(messages_fts, rowid, text) VALUES ('delete', old.seq, old.text); END;
CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE OF text ON messages BEGIN
  INSERT INTO messages_fts(messages_fts, rowid, text) VALUES ('delete', old.seq, old.text);
  INSERT INTO messages_fts(rowid, text) VALUES (new.seq, new.text); END;
CREATE TABLE IF NOT EXISTS push_devices(
  device_id TEXT PRIMARY KEY, endpoint TEXT NOT NULL UNIQUE, app_version TEXT NOT NULL DEFAULT '',
  created INTEGER NOT NULL, updated INTEGER NOT NULL, last_ok INTEGER, failures INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS uploads(
  id TEXT PRIMARY KEY, sha256 TEXT NOT NULL, name TEXT NOT NULL, mime TEXT NOT NULL, size INTEGER NOT NULL,
  kind TEXT NOT NULL, width INTEGER, height INTEGER,
  conversation_id TEXT REFERENCES conversations(id) ON DELETE CASCADE,
  message_id TEXT REFERENCES messages(id) ON DELETE CASCADE,
  created INTEGER NOT NULL, workspace TEXT);
CREATE INDEX IF NOT EXISTS uploads_conv ON uploads(conversation_id);
CREATE INDEX IF NOT EXISTS uploads_sha ON uploads(sha256);
CREATE INDEX IF NOT EXISTS uploads_msg ON uploads(message_id);
CREATE TABLE IF NOT EXISTS settings(
  id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL, json TEXT NOT NULL, updated INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS events(
  id INTEGER PRIMARY KEY AUTOINCREMENT, created INTEGER NOT NULL, type TEXT NOT NULL, data TEXT NOT NULL);
PRAGMA user_version = 4;
"""
CONV_COLS = ("SELECT c.id, c.title, c.title_source, c.pinned, c.kind, c.created, c.updated, "
             "(SELECT substr(m.text, 1, 160) FROM messages m WHERE m.conversation_id = c.id AND m.text <> '' "
             "ORDER BY m.created DESC, m.seq DESC LIMIT 1) AS preview, "
             "(SELECT count(*) FROM messages m WHERE m.conversation_id = c.id) AS message_count FROM conversations c")


SYNC_META_KEYS = ("effort", "web_search", "task", "job", "session", "notify")   # meta that message.created carries


class ChatStore:
    """Chat history. One connection on the event loop thread; every call is a short local query. Each change to a chat
    or a message also goes on the events stream through `emit` (API.md "Events", sync), so open clients mirror it."""
    emit = None                                  # emit_event, set at startup; None in scripts and some tests

    def __init__(self, path: str):
        self._quiet = 0
        if path != ":memory:":
            os.makedirs(os.path.dirname(path) or ".", mode=0o700, exist_ok=True)
            os.close(os.open(path, os.O_RDWR | os.O_CREAT, 0o600))
            os.chmod(path, 0o600)
        self.db = sqlite3.connect(path, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        # Rollback journal, not WAL: a raw file-level backup of the data directory then copies one consistent file.
        for pragma in ("foreign_keys=ON", "journal_mode=DELETE", "synchronous=FULL", "busy_timeout=3000"):
            self.db.execute("PRAGMA " + pragma)
        self.db.executescript(SCHEMA)
        self.db.execute("UPDATE messages SET status = 'interrupted' WHERE status = 'streaming'")   # left by a crash

    def close(self):
        self.db.close()

    # --- sync events (round 6 D4)
    def _changed(self, etype, **data):
        if self.emit is None or self._quiet:
            return
        try:
            self.emit(etype, **data)
        except Exception as exc:                 # an event must never break the change itself
            log.info("sync event not sent: %s", type(exc).__name__)

    @contextlib.contextmanager
    def quiet(self, cid):
        """Bulk changes (a transcript import): one `conversation.updated` (changes ["messages"]) at the end instead of
        one event per message, and none when nothing was added."""
        before = (self.get_conversation(cid) or {}).get("message_count")
        self._quiet += 1
        try:
            yield
        finally:
            self._quiet -= 1
        conv = self.get_conversation(cid)
        if conv is not None and conv["message_count"] != before:
            self._changed("conversation.updated", conversation_id=cid, changes=["messages"], conversation=conv)

    def _sync_message(self, msg):
        text = msg["text"] or ""
        out = {k: v for k, v in msg.items() if k != "meta"}
        out["meta"] = {k: msg["meta"][k] for k in SYNC_META_KEYS if k in msg["meta"]}
        if len(text) > SYNC_TEXT_CHARS:
            out.update(text=text[:SYNC_TEXT_CHARS], truncated=True)
        return out

    # --- conversations
    @staticmethod
    def _conv(row):
        return None if row is None else {
            "id": row["id"], "title": row["title"], "title_source": row["title_source"], "pinned": bool(row["pinned"]),
            "kind": row["kind"], "created": row["created"], "updated": row["updated"],
            "preview": row["preview"] or "", "message_count": row["message_count"]}

    def get_conversation(self, cid):
        return self._conv(self.db.execute(CONV_COLS + " WHERE c.id = ?", (cid,)).fetchone())

    def create_conversation(self, title=None, title_source=None, kind="text"):
        cid, t = new_id(), now_ms()
        self.db.execute("INSERT INTO conversations(id, title, title_source, pinned, kind, created, updated) VALUES (?,?,?,0,?,?,?)",
                        (cid, title or NEW_CHAT_TITLE, title_source or ("user" if title else "auto"), kind, t, t))
        conv = self.get_conversation(cid)
        self._changed("conversation.created", conversation_id=cid, conversation=conv)
        return conv

    def list_conversations(self, limit=PAGE_DEFAULT, cursor=None, pinned=None):
        where, args = [], []
        if pinned is not None:
            where.append("c.pinned = ?"); args.append(1 if pinned else 0)
        if cursor:
            updated, cid = cursor
            where.append("(c.updated < ? OR (c.updated = ? AND c.id < ?))"); args += [updated, updated, cid]
        sql = CONV_COLS + (" WHERE " + " AND ".join(where) if where else "") + " ORDER BY c.updated DESC, c.id DESC LIMIT ?"
        rows = [self._conv(r) for r in self.db.execute(sql, args + [limit + 1])]
        more = len(rows) > limit
        rows = rows[:limit]
        return rows, ("%d:%s" % (rows[-1]["updated"], rows[-1]["id"]) if more and rows else None)

    def update_conversation(self, cid, title=None, pinned=None, title_source="user"):
        # Renaming or pinning does not bump `updated`, so the chat keeps its place in the list.
        if title is not None:
            self.db.execute("UPDATE conversations SET title = ?, title_source = ? WHERE id = ?", (title, title_source, cid))
        if pinned is not None:
            self.db.execute("UPDATE conversations SET pinned = ? WHERE id = ?", (1 if pinned else 0, cid))
        conv = self.get_conversation(cid)
        if conv is not None and title is not None:
            self._changed("conversation.title", conversation_id=cid, title=conv["title"], title_source=conv["title_source"],
                          conversation=conv)
        if conv is not None and pinned is not None:
            self._changed("conversation.updated", conversation_id=cid, changes=["pinned"], conversation=conv)
        return conv

    def set_auto_title(self, cid, title, source):
        """Set a generated title unless the user has named the chat (or Hermes already did)."""
        cur = self.db.execute("UPDATE conversations SET title = ?, title_source = ? WHERE id = ? AND title_source = 'auto'",
                              (title, source, cid))
        if cur.rowcount > 0:
            conv = self.get_conversation(cid)
            self._changed("conversation.title", conversation_id=cid, title=title, title_source=source, conversation=conv)
        return cur.rowcount > 0

    def delete_conversation(self, cid):
        gone = self.db.execute("DELETE FROM conversations WHERE id = ?", (cid,)).rowcount > 0
        if gone:
            self._changed("conversation.deleted", conversation_id=cid)
        return gone

    def notify_conversation(self, title):
        """The chat that holds the assistant's own messages (alerts, briefings): the newest chat with a notify
        message, else a new one. Deleting it is fine; the next message starts a fresh one."""
        row = self.db.execute("SELECT conversation_id FROM messages WHERE source = 'notify' "
                              "ORDER BY created DESC, seq DESC LIMIT 1").fetchone()
        conv = self.get_conversation(row[0]) if row else None
        return conv or self.create_conversation(title, "hermes")

    def touch(self, cid, kind=None):
        if kind:
            cur = self.db.execute("UPDATE conversations SET updated = ?, kind = ? WHERE id = ? AND kind <> ?", (now_ms(), kind, cid, kind))
            if cur.rowcount:
                self._changed("conversation.updated", conversation_id=cid, changes=["kind"], conversation=self.get_conversation(cid))
            else:
                self.db.execute("UPDATE conversations SET updated = ? WHERE id = ?", (now_ms(), cid))
        else:
            self.db.execute("UPDATE conversations SET updated = ? WHERE id = ?", (now_ms(), cid))

    # --- messages
    @staticmethod
    def _msg(row):
        if row is None:
            return None
        try:
            meta = json.loads(row["meta_json"] or "{}")
        except ValueError:
            meta = {}
        meta = {k: v for k, v in meta.items() if not k.startswith("_")} if isinstance(meta, dict) else {}   # bridge-private
        attachments = meta.pop("attachments", None)
        return {"id": row["id"], "conversation_id": row["conversation_id"], "role": row["role"], "text": row["text"],
                "source": row["source"], "status": row["status"], "created": row["created"],
                "client_id": row["client_id"], "meta": meta, "attachments": attachments if isinstance(attachments, list) else []}

    def add_message(self, cid, role, text, source="text", status="complete", created=None, client_id=None, meta=None, touch=True):
        """Raises sqlite3.IntegrityError for a client_id already in this chat or a chat that no longer exists."""
        mid = new_id()
        self.db.execute("INSERT INTO messages(id, conversation_id, role, text, source, status, created, client_id, meta_json) "
                        "VALUES (?,?,?,?,?,?,?,?,?)", (mid, cid, role, text, source, status, created or now_ms(), client_id,
                                                       json.dumps(meta or {}, ensure_ascii=False)))
        if touch:
            self.touch(cid)
        msg = self.get_message(mid)
        if self.emit is not None and not self._quiet:
            self._changed("message.created", conversation_id=cid, message_id=mid, message=self._sync_message(msg),
                          conversation=self.get_conversation(cid))
        return msg

    def get_message(self, mid):
        return self._msg(self.db.execute("SELECT * FROM messages WHERE id = ?", (mid,)).fetchone())

    def update_message(self, mid, text=None, status=None, meta=None):
        if text is not None:
            self.db.execute("UPDATE messages SET text = ? WHERE id = ?", (text, mid))
        if status is not None:
            self.db.execute("UPDATE messages SET status = ? WHERE id = ?", (status, mid))
        if meta:
            row = self.db.execute("SELECT meta_json FROM messages WHERE id = ?", (mid,)).fetchone()
            if row is not None:
                try:
                    cur = json.loads(row[0] or "{}")
                except ValueError:
                    cur = {}
                merged = {**(cur if isinstance(cur, dict) else {}), **meta}
                self.db.execute("UPDATE messages SET meta_json = ? WHERE id = ?", (json.dumps(merged, ensure_ascii=False), mid))

    def hermes_snapshot(self, session_id, exclude_mid=None):
        """Hermes' session counters saved with the newest reply of that Hermes session (meta._hermes, never sent out)."""
        row = self.db.execute("SELECT meta_json FROM messages WHERE role = 'assistant' AND id <> ? AND "
                              "json_extract(meta_json, '$._hermes.session') = ? ORDER BY created DESC, seq DESC LIMIT 1",
                              (exclude_mid or "", session_id)).fetchone()
        try:
            snap = json.loads(row[0]).get("_hermes") if row else None
        except (ValueError, AttributeError):
            snap = None
        return snap if isinstance(snap, dict) else None

    def delete_message(self, cid, mid):
        gone = self.db.execute("DELETE FROM messages WHERE id = ? AND conversation_id = ?", (mid, cid)).rowcount > 0
        if gone:
            self._changed("message.deleted", conversation_id=cid, message_id=mid)
        return gone

    def messages(self, cid, limit=MSG_PAGE_DEFAULT, before=None):
        """The newest `limit` messages (older than `before`), oldest first, and whether older ones exist."""
        args = [cid]
        where = "conversation_id = ?"
        if before is not None:
            b = self.db.execute("SELECT created, seq FROM messages WHERE id = ? AND conversation_id = ?", (before, cid)).fetchone()
            if b is None:
                return None, False
            where += " AND (created < ? OR (created = ? AND seq < ?))"; args += [b["created"], b["created"], b["seq"]]
        rows = self.db.execute("SELECT * FROM messages WHERE " + where + " ORDER BY created DESC, seq DESC LIMIT ?", args + [limit + 1]).fetchall()
        more = len(rows) > limit
        return [self._msg(r) for r in reversed(rows[:limit])], more

    def first_user_text(self, cid):
        """The conversation's first non-empty user message (typed or spoken): what automatic titles describe."""
        row = self.db.execute("SELECT text FROM messages WHERE conversation_id = ? AND role = 'user' AND text <> '' "
                              "ORDER BY created, seq LIMIT 1", (cid,)).fetchone()
        return row[0] if row else None

    def last_user_message(self, cid):
        return self._msg(self.db.execute("SELECT * FROM messages WHERE conversation_id = ? AND role = 'user' "
                                         "ORDER BY created DESC, seq DESC LIMIT 1", (cid,)).fetchone())

    def delete_replies_after(self, cid, msg):
        """Retry: drop the assistant messages that answered `msg` (the newest user message)."""
        where = ("conversation_id = ? AND role = 'assistant' AND source = 'text' AND "
                 "(created > ? OR (created = ? AND seq > (SELECT seq FROM messages WHERE id = ?)))")
        args = (cid, msg["created"], msg["created"], msg["id"])
        gone = [r[0] for r in self.db.execute("SELECT id FROM messages WHERE " + where, args)]
        self.db.execute("DELETE FROM messages WHERE " + where, args)
        for mid in gone:
            self._changed("message.deleted", conversation_id=cid, message_id=mid)

    def count_replies(self, cid):
        return self.db.execute("SELECT count(*) FROM messages WHERE conversation_id = ? AND role = 'assistant' AND status = 'complete' "
                               "AND text <> ''", (cid,)).fetchone()[0]

    def _recent(self, cid, n, chars, per_message, exclude=()):
        rows = self.db.execute("SELECT * FROM messages WHERE conversation_id = ? AND (text <> '' OR meta_json LIKE '%\"attachments\": [{%') "
                               "AND status <> 'streaming' ORDER BY created DESC, seq DESC LIMIT ?", (cid, n + len(exclude))).fetchall()
        out, total = [], 0
        for r in rows:
            if r["id"] in exclude:
                continue
            msg = self._msg(r)
            text = r["text"][:per_message]
            try:
                loc = json.loads(r["meta_json"] or "{}").get("_location")      # bridge-private: never in the API
            except (ValueError, AttributeError):
                loc = None
            if r["source"] == "task":
                text = "[Result of a task Hermes ran during a live voice call]\n" + text
            if total + len(text) > chars and out:
                break
            out.append({"role": "user" if r["role"] == "user" else "assistant", "content": text, "_msg": msg,
                        "_location": loc if isinstance(loc, str) else None})
            total += len(text)
            if len(out) >= n:
                break
        return list(reversed(out))

    def context(self, cid, exclude=(), web_note="", web_last=None):
        """Hermes' history for a chat turn. The newest user turn with images carries them as image_url parts (vision);
        other attachments become a one-line note each (documents: where Hermes can read them).
        `web_note` goes on every user turn sent with web search (the newest follows `web_last` when given), the same
        way on every later turn: Hermes keys its session on the first user message, so that one must not change."""
        out = self._recent(cid, CONTEXT_MESSAGES, CONTEXT_CHARS, MAX_TASK_CHARS, exclude)
        inline = None
        if CFG["vision"]:
            inline = next((m["_msg"]["id"] for m in reversed(out) if m["role"] == "user"
                           and any(a.get("kind") == "image" for a in m["_msg"]["attachments"])), None)
        last_user = next((m["_msg"]["id"] for m in reversed(out) if m["role"] == "user"), None)
        result = []
        for m in out:
            msg = self._with_attachments(m, inline_images=m["_msg"]["id"] == inline)
            web = m["_msg"]["meta"].get("web_search") is True
            if m["_msg"]["id"] == last_user and web_last is not None:
                web = web_last
            if web_note and web and m["role"] == "user":
                add_note(msg, web_note)
            if m["role"] == "user" and m.get("_location"):
                add_note(msg, m["_location"])
            result.append(msg)
        return result

    def used_web_search(self, cid):
        return self.db.execute("SELECT 1 FROM messages WHERE conversation_id = ? AND role = 'user' "
                               "AND meta_json LIKE '%\"web_search\": true%' LIMIT 1", (cid,)).fetchone() is not None

    def live_seed(self, cid):
        return [self._with_attachments(m, inline_images=False) for m in self._recent(cid, LIVE_SEED_MESSAGES, LIVE_SEED_CHARS, 2000)]

    def _with_attachments(self, m, inline_images):
        atts, text = m["_msg"]["attachments"], m["content"]
        if not atts:
            return {"role": m["role"], "content": text}
        notes, images = [], []
        for a in atts:
            row = self.upload(a.get("id")) if isinstance(a, dict) else None
            if row is None:
                notes.append("[The user attached %s, which has since been deleted.]" % (a.get("name") if isinstance(a, dict) else "a file"))
            elif row["kind"] == "image" and inline_images:
                images.append(row)
            elif row["kind"] == "image" and CFG["vision"]:
                notes.append("[image: %s, sent earlier in this chat]" % row["name"])
            elif row["workspace"]:
                notes.append("The user attached %s (%s, %s) at %s." % (row["name"], human_size(row["size"]), row["mime"],
                                                                       hermes_side_path(row["workspace"])))
            else:
                notes.append("[The user attached %s (%s), but it could not be given to you.]" % (row["name"], row["mime"]))
        text = "\n\n".join(p for p in (text, "\n".join(notes)) if p)
        if not images:
            return {"role": m["role"], "content": text}
        parts = [{"type": "text", "text": text or "(The user sent only the attached image%s.)" % ("s" if len(images) > 1 else "")}]
        for row in images:
            try:
                data = Path(upload_blob(row["sha256"])).read_bytes()
            except OSError:
                parts[0]["text"] += "\n[image %s is missing on the server]" % row["name"]
                continue
            parts.append({"type": "image_url", "image_url": {"url": "data:%s;base64,%s" % (row["mime"], base64.b64encode(data).decode())}})
        return {"role": m["role"], "content": parts}

    # --- uploads (attachments)
    def upload(self, uid):
        if not isinstance(uid, str):
            return None
        r = self.db.execute("SELECT * FROM uploads WHERE id = ?", (uid,)).fetchone()
        return dict(r) if r else None

    def add_upload(self, row):
        cols = ("id", "sha256", "name", "mime", "size", "kind", "width", "height", "conversation_id", "created")
        self.db.execute("INSERT INTO uploads(%s) VALUES (%s)" % (", ".join(cols), ", ".join("?" * len(cols))), [row.get(c) for c in cols])

    def upload_bytes(self, cid=None):
        if cid is None:
            return self.db.execute("SELECT coalesce(sum(size), 0) FROM uploads").fetchone()[0]
        return self.db.execute("SELECT coalesce(sum(size), 0) FROM uploads WHERE conversation_id = ?", (cid,)).fetchone()[0]

    def claim_uploads(self, ids, cid, mid):
        self.db.executemany("UPDATE uploads SET conversation_id = ?, message_id = ? WHERE id = ?", [(cid, mid, i) for i in ids])

    def set_workspace(self, uid, path):
        self.db.execute("UPDATE uploads SET workspace = ? WHERE id = ?", (path, uid))

    def delete_upload(self, uid):
        return self.db.execute("DELETE FROM uploads WHERE id = ?", (uid,)).rowcount > 0

    def expire_uploads(self, before_ms):
        return self.db.execute("DELETE FROM uploads WHERE message_id IS NULL AND created < ?", (before_ms,)).rowcount

    def live_shas(self):
        return {r[0] for r in self.db.execute("SELECT DISTINCT sha256 FROM uploads")}

    def live_workspaces(self):
        return {r[0] for r in self.db.execute("SELECT workspace FROM uploads WHERE workspace IS NOT NULL")}

    # --- synced account settings (one versioned JSON object, API.md "Settings")
    def get_settings(self):
        row = self.db.execute("SELECT version, json, updated FROM settings WHERE id = 1").fetchone()
        if row is None:
            return {"version": 0, "settings": {}, "updated": None}
        try:
            data = json.loads(row["json"])
        except ValueError:
            data = {}
        return {"version": row["version"], "settings": data if isinstance(data, dict) else {}, "updated": row["updated"]}

    def put_settings(self, data, expect_version):
        """Replace the settings if their version is still `expect_version`: (True, new state) or (False, current state)."""
        self.db.execute("BEGIN IMMEDIATE")
        try:
            row = self.db.execute("SELECT version FROM settings WHERE id = 1").fetchone()
            current = row["version"] if row else 0
            if current != expect_version:
                self.db.execute("ROLLBACK")
                return False, self.get_settings()
            self.db.execute("INSERT INTO settings(id, version, json, updated) VALUES (1, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET "
                            "version = excluded.version, json = excluded.json, updated = excluded.updated",
                            (current + 1, json.dumps(data, ensure_ascii=False, separators=(",", ":")), now_ms()))
            self.db.execute("COMMIT")
        except Exception:
            self.db.execute("ROLLBACK")
            raise
        return True, self.get_settings()

    # --- events (API.md "Events"): ids only grow (AUTOINCREMENT), so a client's Last-Event-ID stays meaningful
    def add_event(self, kind, data, keep):
        cur = self.db.execute("INSERT INTO events(created, type, data) VALUES (?,?,?)",
                              (now_ms(), kind, json.dumps(data, ensure_ascii=False, separators=(",", ":"))))
        eid = cur.lastrowid
        if eid % 50 == 0:
            self.db.execute("DELETE FROM events WHERE id <= ? OR created < ?", (eid - keep, now_ms() - 7 * 86400 * 1000))
        return eid

    def events_after(self, after, limit=100):
        return [{"id": r["id"], "type": r["type"], "created": r["created"], "data": json.loads(r["data"])}
                for r in self.db.execute("SELECT * FROM events WHERE id > ? ORDER BY id LIMIT ?", (after, limit))]

    def events_bounds(self):
        """(oldest kept id or None, newest id ever issued). The newest survives trimming (sqlite_sequence)."""
        first = self.db.execute("SELECT min(id) FROM events").fetchone()[0]
        row = self.db.execute("SELECT seq FROM sqlite_sequence WHERE name = 'events'").fetchone()
        return first, (row[0] if row else 0)

    # --- push devices (endpoints are capability URLs: never log or return them)
    def push_devices(self):
        return [dict(r) for r in self.db.execute("SELECT device_id, endpoint, app_version FROM push_devices ORDER BY updated DESC")]

    def push_device(self, device_id):
        r = self.db.execute("SELECT device_id, endpoint, app_version FROM push_devices WHERE device_id = ?", (device_id,)).fetchone()
        return dict(r) if r else None

    def push_count_others(self, device_id, endpoint):
        return self.db.execute("SELECT count(*) FROM push_devices WHERE device_id <> ? AND endpoint <> ?", (device_id, endpoint)).fetchone()[0]

    def push_register(self, device_id, endpoint, app_version):
        t = now_ms()
        self.db.execute("BEGIN")
        try:
            self.db.execute("DELETE FROM push_devices WHERE endpoint = ? AND device_id <> ?", (endpoint, device_id))
            self.db.execute("INSERT INTO push_devices(device_id, endpoint, app_version, created, updated) VALUES (?,?,?,?,?) "
                            "ON CONFLICT(device_id) DO UPDATE SET endpoint = excluded.endpoint, app_version = excluded.app_version, "
                            "updated = excluded.updated, failures = 0", (device_id, endpoint, app_version, t, t))
            self.db.execute("COMMIT")
        except Exception:
            self.db.execute("ROLLBACK")
            raise

    def push_unregister(self, device_id):
        return self.db.execute("DELETE FROM push_devices WHERE device_id = ?", (device_id,)).rowcount > 0

    def push_result(self, device_id, ok):
        if ok:
            self.db.execute("UPDATE push_devices SET last_ok = ?, failures = 0 WHERE device_id = ?", (now_ms(), device_id))
        else:
            self.db.execute("UPDATE push_devices SET failures = failures + 1 WHERE device_id = ?", (device_id,))

    # --- search
    def search(self, q, limit=30):
        out, seen = [], set()
        like = "%" + q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
        tokens = re.findall(r"\w+", q, re.UNICODE)[:8]
        for r in self.db.execute(CONV_COLS + " WHERE c.title LIKE ? ESCAPE '\\' ORDER BY c.updated DESC LIMIT ?", (like, limit)):
            seen.add(r["id"])
            title = r["title"]
            i = title.lower().find(q.lower())
            match = [i, i + len(q)] if i >= 0 else make_snippet(title, tokens, len(title) + 1)[1]
            out.append({"conversation": self._conv(r), "message_id": None, "snippet": title, "match": match})
        if tokens and len(out) < limit:
            fts_query = " ".join('"%s"*' % t for t in tokens)
            rows = self.db.execute("SELECT m.conversation_id AS cid, m.id AS mid, m.text AS text "
                                   "FROM messages_fts JOIN messages m ON m.seq = messages_fts.rowid WHERE messages_fts MATCH ? "
                                   "ORDER BY bm25(messages_fts) LIMIT 300", (fts_query,)).fetchall()
            for r in rows:
                if r["cid"] in seen:
                    continue
                seen.add(r["cid"])
                snippet, match = make_snippet(r["text"], tokens)
                out.append({"conversation": self.get_conversation(r["cid"]), "message_id": r["mid"], "snippet": snippet,
                            "match": match})
                if len(out) >= limit:
                    break
        return out


def save_task_result(ds, jid, request, job):
    """A delegated task finished during a call linked to a chat: keep its result in that chat."""
    store, cid = CHAT["store"], getattr(ds, "conversation_id", None)
    if store is None or not cid:
        return None
    try:
        return store.add_message(cid, "assistant", job.get("markdown", "") if job["status"] == "done" else "", "task",
                          status="complete" if job["status"] == "done" else "error", client_id="job:%s:%s" % (ds.id, jid),
                          meta={k: v for k, v in (("task", request[:2000]), ("job", jid), ("session", ds.id),
                                                  ("seconds", round(time.monotonic() - job["t0"])), ("usage", job.get("usage"))) if v is not None})
    except sqlite3.Error as exc:
        log.info("task result not saved: %s", type(exc).__name__)     # the chat was deleted meanwhile
        return None


# ----------------------------------------------------------------------------------------------------------------
# Steps (API.md "Steps"): the reply's thinking and tool timeline. Hermes' stream names each tool and gives a short
# preview; the full arguments and result are read from Hermes' own session API (GET /api/sessions/{id}/messages, the
# session id comes in the X-Hermes-Session-Id response header) as soon as the tool completes. Everything is
# redacted and cut before it is stored or sent.
# ----------------------------------------------------------------------------------------------------------------
STEP_IO_MAX = 8192            # characters per tool input and per tool output
STEP_TEXT_MAX = 16384         # characters of thinking text per step
STEPS_MAX = 128               # steps kept per message (older ones dropped, counted in steps_truncated)
STEP_DETAIL_WAIT_S = 6.0      # how long the end of a reply waits for outstanding tool details
ANSI_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b[@-Z\\-_]|[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
REDACTED = "[redacted]"
SECRET_RULES = [
    # PEM private key blocks (RSA, EC, OPENSSH, PGP, encrypted, …)
    (re.compile(r"-----BEGIN ([A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?)-----[\s\S]*?(?:-----END \1-----|$)"), "[redacted private key]"),
    # Authorization headers and bearer/basic credentials
    (re.compile(r"(?i)\b(authorization|proxy-authorization)(\s*[:=]\s*)(?:(bearer|basic|token|digest)\s+)?[^\s\"',;]+"),
     lambda m: m.group(1) + m.group(2) + ((m.group(3) + " ") if m.group(3) else "") + REDACTED),
    (re.compile(r"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]{12,}"), r"\1 " + REDACTED),
    # Well-known token formats
    (re.compile(r"\b(?:sk|rk|pk)-(?:ant-|proj-|live-|test-|or-v1-)?[A-Za-z0-9_-]{16,}"), REDACTED),
    (re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,})"), REDACTED),
    (re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}"), REDACTED),
    (re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"), REDACTED),
    (re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"), REDACTED),
    (re.compile(r"\b[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}"), REDACTED),                       # Telegram bot tokens
    (re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"), REDACTED),   # JWTs
    # NAME=value / NAME: value where NAME looks like a secret (env files, exports, YAML, CLI flags)
    (re.compile(r"(?i)\b([A-Z0-9_.-]*(?:API[_-]?KEY|SECRET|TOKEN|PASSWORD|PASSWD|PASSPHRASE|PRIVATE[_-]?KEY|ACCESS[_-]?KEY|"
                r"CLIENT[_-]?SECRET|CREDENTIALS?|AUTH[_-]?KEY|_KEY|_PASS|_PWD)[A-Z0-9_]*)(\s*[=:]\s*)(\"[^\"\n]*\"|'[^'\n]*'|[^\s\"',;]+)"),
     lambda m: m.group(1) + m.group(2) + REDACTED),
    # JSON-style "password": "…"
    (re.compile(r"(?i)(\"(?:[a-z0-9_]*(?:api_?key|secret|token|password|passwd|passphrase|credential)[a-z0-9_]*)\"\s*:\s*)\"[^\"\n]*\""),
     lambda m: m.group(1) + "\"" + REDACTED + "\""),
    # --password xyz / -p=xyz style flags
    (re.compile(r"(?i)(--?(?:password|passwd|token|api-key|secret)(?:=|\s+))(\S+)"), lambda m: m.group(1) + REDACTED),
    # user:password@ in URLs
    (re.compile(r"(?i)\b([a-z][a-z0-9+.-]*://[^/\s:@]+:)[^@\s/]+@"), r"\1" + REDACTED + "@"),
]


def strip_ansi(text):
    return ANSI_RE.sub("", str(text or ""))


def redact_secrets(text):
    text = str(text or "")
    for rule, repl in SECRET_RULES:
        text = rule.sub(repl, text)
    return text


def clean_io(text, limit=STEP_IO_MAX):
    """(text, truncated) for a tool input or output: no terminal escapes, secrets redacted, at most `limit` chars."""
    text = redact_secrets(strip_ansi(text))
    if len(text) <= limit:
        return text, False
    return text[:limit], True


def clean_json(value):
    """Redact every string inside a JSON value (keys whose names look secret lose their value)."""
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            secret = isinstance(v, str) and re.search(r"(?i)(api_?key|secret|token|password|passwd|passphrase|credential)", str(k))
            out[str(k)] = REDACTED if secret and v else clean_json(v)
        return out
    if isinstance(value, list):
        return [clean_json(v) for v in value]
    if isinstance(value, str):
        return redact_secrets(strip_ansi(value))
    return value


def tool_io(arguments, content):
    """The tool part of a finished step from Hermes' stored call and result."""
    out = {"input": None, "output": None, "exit_status": None, "error": None, "truncated": False}
    if isinstance(arguments, str) and arguments:
        try:
            parsed = json.loads(arguments)
        except ValueError:
            parsed = None
        if isinstance(parsed, (dict, list)):
            cleaned = clean_json(parsed)
            if len(json.dumps(cleaned, ensure_ascii=False)) > STEP_IO_MAX:
                out["input"], out["truncated"] = clean_io(json.dumps(cleaned, ensure_ascii=False))
            else:
                out["input"] = cleaned
        else:
            out["input"], cut = clean_io(arguments)
            out["truncated"] |= cut
    if isinstance(content, str):
        text, result = content, None
        try:
            result = json.loads(content)
        except ValueError:
            pass
        if isinstance(result, dict):
            for field in ("output", "content", "result", "stdout", "text"):
                if isinstance(result.get(field), str):
                    text = result[field]
                    break
            code = next((result[k] for k in ("exit_code", "returncode", "exit_status") if isinstance(result.get(k), int)
                         and not isinstance(result.get(k), bool)), None)
            out["exit_status"] = code
            if isinstance(result.get("error"), str) and result["error"]:
                out["error"] = clean_io(result["error"], 1000)[0]
        out["output"], cut = clean_io(text)
        out["truncated"] |= cut
    return out


def hermes_api_root():
    url = CFG["hermes_url"].rstrip("/")
    return url[:-3] if url.endswith("/v1") else url


async def hermes_tool_detail(session_id, call_id, tries=3):
    """(arguments, content) of one tool call from Hermes' session store, or None. Hermes writes each call and its
    result while the turn runs, so they are there when the tool reports `completed` (checked 15 November 2026)."""
    url = "%s/api/sessions/%s/messages?limit=80&order=latest" % (hermes_api_root(), urllib.parse.quote(session_id, safe=""))
    for attempt in range(tries):
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=5)) as s:
                async with s.get(url, headers={"Authorization": "Bearer " + CFG["hermes_key"]}) as r:
                    data = await r.json(content_type=None) if r.status == 200 else None
        except (aiohttp.ClientError, asyncio.TimeoutError, ValueError) as exc:
            log.info("tool detail lookup failed: %s", type(exc).__name__)
            data = None
        rows = data.get("data") if isinstance(data, dict) else None
        if isinstance(rows, list):
            arguments = content = None
            for m in rows:
                if not isinstance(m, dict):
                    continue
                if m.get("role") == "tool" and m.get("tool_call_id") == call_id:
                    content = m.get("content") if isinstance(m.get("content"), str) else json.dumps(m.get("content"))
                for tc in m.get("tool_calls") or []:
                    if isinstance(tc, dict) and call_id in (tc.get("id"), tc.get("call_id")):
                        arguments = (tc.get("function") or {}).get("arguments")
            if content is not None or arguments is not None:
                return arguments, content
        if attempt + 1 < tries:
            await asyncio.sleep(0.5 * (attempt + 1))
    return None


# ----------------------------------------------------------------------------------------------------------------
# Push (UnifiedPush): the app registers an endpoint URL from its distributor (ntfy or another). When a reply or a
# live-call task finishes and no client is watching it, the bridge POSTs a small JSON message to every endpoint.
# No Google or Firebase services are involved. The wire contract is in API.md ("Push notifications").
# ----------------------------------------------------------------------------------------------------------------
PUSH_PREVIEW_CHARS = 120
PUSH_TIMEOUT_S = 10
PUSH_POLL_GRACE_S = 15.0                 # a live call that polled /api/job this recently shows task results itself
PUSH_STATUS = {"complete": "done", "done": "done", "error": "failed", "failed": "failed", "cancelled": "stopped"}
PUSH_SENT = collections.defaultdict(collections.deque)      # device_id -> monotonic times of recent pushes


def push_endpoint_error(url):
    """None for an acceptable UnifiedPush endpoint, else the reason."""
    if not isinstance(url, str) or not url or len(url) > 2048:
        return "endpoint must be a URL of at most 2048 characters"
    if any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in url):
        return "endpoint must not contain spaces or control characters"
    try:
        parts = urllib.parse.urlsplit(url)
        parts.port
    except ValueError:
        return "endpoint is not a valid URL"
    if parts.scheme not in ("http", "https"):
        return "endpoint must be an http or https URL"
    if not parts.hostname:
        return "endpoint needs a host"
    if parts.username is not None or parts.password is not None:
        return "endpoint must not contain credentials"
    return None


def push_preview(text):
    t = redact_secrets(plain_text(text))
    return t if len(t) <= PUSH_PREVIEW_CHARS else t[:PUSH_PREVIEW_CHARS - 1].rstrip() + "…"


def push_payload(kind, cid, mid, status, text):
    title = None
    if CFG["push_previews"] and cid and CHAT["store"] is not None:
        title = (CHAT["store"].get_conversation(cid) or {}).get("title")
    return {"type": kind, "conversation_id": cid, "message_id": mid,
            "title": title if CFG["push_previews"] else None,
            "preview": push_preview(text) if CFG["push_previews"] else None,
            "status": PUSH_STATUS.get(status, status), "sent": now_ms()}


def push_allowed(device_id, now=None):
    """Sliding one-minute window per device. Records the push when it is allowed."""
    now = time.monotonic() if now is None else now
    sent = PUSH_SENT[device_id]
    while sent and now - sent[0] >= 60:
        sent.popleft()
    if len(sent) >= CFG["push_rate_per_min"]:
        return False
    sent.append(now)
    return True


def notify(kind, cid, mid, status, text):
    """Queue a push to every registered device. Never raises; the push goes out in the background."""
    store = CHAT["store"]
    if not CFG["push_enabled"] or store is None:
        return
    try:
        live = event_devices()
        devices = [d for d in store.push_devices() if d["device_id"] not in live]
        if devices:
            _background(send_push(devices, push_payload(kind, cid, mid, status, text)))
    except Exception as exc:
        log.info("push skipped: %s", type(exc).__name__)


async def send_push(devices, payload):
    """POST payload to each device; returns {device_id: http status, or None when not delivered}."""
    body = json.dumps(payload, ensure_ascii=False).encode()
    results = {}
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=PUSH_TIMEOUT_S, sock_connect=5)) as s:
        async def one(dev):
            did = dev["device_id"]
            if not push_allowed(did):
                log.info("push dropped: rate limit")
                results[did] = None
                return
            try:
                async with s.post(dev["endpoint"], data=body, allow_redirects=False,
                                  headers={"Content-Type": "application/json", "TTL": "86400", "Urgency": "normal"}) as r:
                    results[did] = r.status
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                log.info("push failed: %s", type(exc).__name__)
                results[did] = None
            store, code = CHAT["store"], results[did]
            if store is None:
                return
            if code in (404, 410):                       # UnifiedPush: the endpoint is gone; forget the device
                store.push_unregister(did)
                log.info("push endpoint gone; device removed")
            else:
                store.push_result(did, code is not None and 200 <= code < 300)
        await asyncio.gather(*(one(d) for d in devices))
    return results


# --- the app's own notification stream (API.md "Events"): GET /api/events, authenticated SSE. Each event has an id
# for resume and carries only what a notification needs (ids, status, the chat title and a short redacted preview of
# the reply text). Never steps, tool input or tool output.
EVENT_TYPES = ("reply.done", "task.started", "task.done", "notify", "test",
               # Sync (round 6 D4): every open client mirrors chat changes made anywhere (API.md "Events").
               "conversation.created", "conversation.updated", "conversation.title", "conversation.deleted",
               "message.created", "message.deleted", "reply.started")
SYNC_TEXT_CHARS = 2000                  # message.created carries at most this much text (`truncated` when cut)
# The device that caused a change (`X-Device-Id` on the request), so it can skip its own echoes. Background work
# started by a request inherits it (asyncio copies the context into tasks).
ORIGIN_DEVICE = contextvars.ContextVar("origin_device", default=None)
EVENT_READERS_MAX = 8
EVENT_REPLAY_MAX = 200
EVENTS = {"wake": None, "readers": {}, "tests": collections.deque()}     # readers: reader id -> device_id or None


def _events_wake():
    wake = EVENTS["wake"]
    if wake is None:
        wake = EVENTS["wake"] = asyncio.Event()
    return wake


def event_text(cid, text):
    """`title` (the chat's) and `preview` (plain, redacted, at most PUSH_PREVIEW_CHARS) for an event. Events go only
    to the app's own key over the bridge's HTTPS route, so they carry previews even when PUSH_PREVIEWS is off."""
    title = (CHAT["store"].get_conversation(cid) or {}).get("title") if cid and CHAT["store"] is not None else None
    return {"title": title, "preview": push_preview(text) if text else ""}


def emit_event(etype, **data):
    """Store one event and wake every /api/events reader. Never raises."""
    store = CHAT["store"]
    if store is None:
        return None
    origin = ORIGIN_DEVICE.get()
    if origin and "origin" not in data:
        data["origin"] = origin                  # the device whose request caused it (it may skip its own echo)
    try:
        eid = store.add_event(etype, data, CFG["events_keep"])
    except Exception as exc:
        log.info("event not stored: %s", type(exc).__name__)
        return None
    wake, EVENTS["wake"] = _events_wake(), asyncio.Event()
    wake.set()
    return eid


def event_devices():
    """Device ids whose /api/events stream is open now: they hear every event directly, so no UnifiedPush for them."""
    return {d for d in EVENTS["readers"].values() if d}


def event_sse(e):
    return sse_bytes(e["id"], e["type"], {**e["data"], "created": e["created"]})


async def api_events(req):
    """GET /api/events: the app's notification stream (SSE). Resume with Last-Event-ID (or ?after=); without either it
    starts with new events only. ?once=1 answers JSON instead (the background poll). ?heartbeat= seconds between
    heartbeats, ?device_id= the app's push device id (that device then gets no UnifiedPush while connected)."""
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    raw = (req.headers.get("Last-Event-ID") or req.query.get("after") or "").strip()
    try:
        if raw and not re.fullmatch(r"\d{1,12}", raw):
            raise ValueError("after")
        after = int(raw) if raw else None
        hb = _int_param(req, "heartbeat", CFG["events_heartbeat_s"], 15, 600)
    except ValueError:
        return jerr(400, "bad_request", message="Last-Event-ID/after must be an event id; heartbeat 15-600 seconds")
    device = req.query.get("device_id")
    if device is not None and not valid_id(device):
        return jerr(400, "bad_device_id", message="device_id must be 1-64 characters of A-Z a-z 0-9 _ -")
    first, last = store.events_bounds()
    reset = None
    if after is not None and after > last:
        reset, after = "unknown_id", last            # the history was reset (a new database): start from now
    elif after is not None and after > 0 and first is not None and after < first - 1:
        reset = "gap"                                # some events were trimmed: the app should re-read its chats
    cursor = last if after is None else after
    if req.query.get("once") in ("1", "true"):
        items = store.events_after(cursor, EVENT_REPLAY_MAX)
        return web.json_response({"events": [{"id": e["id"], "type": e["type"], "data": {**e["data"], "created": e["created"]}}
                                             for e in items],
                                  "last_id": items[-1]["id"] if items else max(cursor, 0), "reset": reset,
                                  "more": len(items) >= EVENT_REPLAY_MAX})
    if len(EVENTS["readers"]) >= EVENT_READERS_MAX:
        return jerr(429, "too_many_readers", message="at most %d event streams at a time" % EVENT_READERS_MAX)
    rid = secrets.token_hex(6)
    EVENTS["readers"][rid] = device
    resp = _sse_response()
    try:
        await resp.prepare(req)
        hello = {"version": 1, "last_id": last, "heartbeat_s": hb, "time": now_ms(), "reset": reset}
        await resp.write(sse_bytes(None, "hello", hello))
        last_write = time.monotonic()
        while True:
            wake = _events_wake()
            items = store.events_after(cursor, EVENT_REPLAY_MAX)
            for e in items:
                await resp.write(event_sse(e))
                cursor = e["id"]
            if items:
                last_write = time.monotonic()
                if len(items) >= EVENT_REPLAY_MAX:
                    continue
            try:
                await asyncio.wait_for(wake.wait(), min(5.0, hb))
            except asyncio.TimeoutError:
                if req.transport is None or req.transport.is_closing():
                    break
                if time.monotonic() - last_write >= hb:
                    await resp.write(b": hb\n\n")                  # 6 bytes: keeps proxies and NATs from closing it
                    last_write = time.monotonic()
    except (ConnectionResetError, ConnectionError):
        pass
    finally:
        EVENTS["readers"].pop(rid, None)
    return resp


async def api_events_test(req):
    """POST /api/events/test: one `test` event to every open stream (the app's "Send a test" button)."""
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    now, sent = time.monotonic(), EVENTS["tests"]
    while sent and now - sent[0] >= 60:
        sent.popleft()
    if len(sent) >= 6:
        return jerr(429, "rate_limited", message="at most 6 test events a minute")
    sent.append(now)
    eid = emit_event("test", conversation_id=None, message_id=None, title="Test notification",
                     preview="Notifications from your bridge work.")
    return web.json_response({"ok": True, "id": eid, "readers": len(EVENTS["readers"])})


# --- reported replies (API.md "Reports"): the app's "Report reply" action, kept on this server only
REPORT_REASONS = ("offensive", "harmful", "wrong", "other")
REPORT_NOTE_CHARS = 1000
REPORT_TEXT_CHARS = 8000
REPORT_RATE_PER_MIN = 20
REPORTS_SENT = collections.deque()


def _append_report(path, entry):
    """Appends one JSON line; the file is created mode 600 (it can hold reply text)."""
    os.makedirs(os.path.dirname(path) or ".", mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


async def api_report(req):
    """POST /api/report {message_id, conversation_id?, reason, note?, hidden?}: logs a reported reply to
    LIVE_REPORTS_FILE with a copy of the reply as stored, so the owner can review what the model said."""
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    body, bad = await read_json(req)
    if bad:
        return bad
    reason, note = body.get("reason"), body.get("note") or ""
    mid, cid = body.get("message_id"), body.get("conversation_id")
    if reason not in REPORT_REASONS:
        return jerr(400, "bad reason", "bad_request", message="reason must be one of " + ", ".join(REPORT_REASONS))
    if not isinstance(note, str) or len(note) > REPORT_NOTE_CHARS:
        return jerr(400, "bad note", "bad_request", message="note must be text of at most %d characters" % REPORT_NOTE_CHARS)
    if not isinstance(mid, str) or not mid or len(mid) > 200 or (cid is not None and (not isinstance(cid, str) or len(cid) > 200)):
        return jerr(400, "bad message_id", "bad_request")
    now, sent = time.monotonic(), REPORTS_SENT
    while sent and now - sent[0] >= 60:
        sent.popleft()
    if len(sent) >= REPORT_RATE_PER_MIN:
        return jerr(429, "rate_limited", message="at most %d reports a minute" % REPORT_RATE_PER_MIN)
    sent.append(now)
    msg, store = None, CHAT["store"]
    if store is not None:
        try:
            msg = store.get_message(mid)
        except Exception:                                          # a report never fails on a lookup
            msg = None
    if msg is not None and cid and msg.get("conversation_id") not in (None, cid):
        msg = None
    meta = (msg or {}).get("meta") or {}
    rid = "rep_" + secrets.token_hex(8)
    entry = {"id": rid, "at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
             "reason": reason, "note": note.strip(), "hidden": body.get("hidden") is True,
             "message_id": mid, "conversation_id": cid or (msg or {}).get("conversation_id"),
             "found": msg is not None, "role": (msg or {}).get("role"),
             "model": meta.get("model") if isinstance(meta, dict) else None,
             "text": ((msg or {}).get("text") or "")[:REPORT_TEXT_CHARS]}
    try:
        await asyncio.to_thread(_append_report, CFG["reports_file"], entry)
    except OSError as exc:
        log.warning("cannot write report: %s", type(exc).__name__)
        return jerr(500, "report_failed", message="the report could not be saved")
    log.info("reply reported: %s (%s)", rid, reason)
    return web.json_response({"ok": True, "id": rid})


# --- messages from the assistant itself (API.md "Assistant messages")
NOTIFY_KINDS = ("alert", "briefing", "note")
NOTIFY_RATE_PER_HOUR = 30
NOTIFY_SENT = collections.deque()
NOTIFY_LOOPBACK_HOSTS = ("127.0.0.1", "localhost", "[::1]")


def notify_authorized(req):
    given = req.headers.get("Authorization", "")
    given = given[7:] if given.lower().startswith("bearer ") else ""
    key = CFG.get("notify_key") or ""
    return len(key) >= 24 and hmac.compare_digest(given.encode(), key.encode())


# ----------------------------------------------------------------------------------------------------------------
# Pairing (API.md "Pairing"): tove_pair.py (or the tove-setup Hermes skill) writes a one-time code's SHA-256 into
# <data>/pairing.json; the app trades the code for the access key here, once, within 10 minutes. The format is
# tove_pair.py's; this side only reads the file and marks entries used, so the bridge still runs as a single file.
# ----------------------------------------------------------------------------------------------------------------
PAIR_FAILS = collections.deque()                 # (monotonic time, client) of wrong codes, for the attempt limit
PAIR_WINDOW_S = 600
PAIR_MAX_FAILS = 20                              # wrong codes per window from everyone (proxies hide client addresses)
PAIR_MAX_FAILS_CLIENT = 6                        # wrong codes per window from one address


def pair_file():
    return CFG.get("pair_file") or os.path.join(CFG["data_dir"], "pairing.json")


def pair_hash(code):
    canon = "".join(ch for ch in str(code or "").upper() if ch.isalnum())
    return canon, hashlib.sha256(("tove-pair:" + canon).encode()).hexdigest()


def pair_retry_after(client, now):
    """Seconds until another attempt is allowed, or 0."""
    while PAIR_FAILS and now - PAIR_FAILS[0][0] >= PAIR_WINDOW_S:
        PAIR_FAILS.popleft()
    mine = [t for t, c in PAIR_FAILS if c == client]
    if len(PAIR_FAILS) >= PAIR_MAX_FAILS:
        return int(PAIR_FAILS[0][0] + PAIR_WINDOW_S - now) + 1
    if len(mine) >= PAIR_MAX_FAILS_CLIENT:
        return int(mine[0] + PAIR_WINDOW_S - now) + 1
    return 0


async def api_pair(req):
    """POST /api/pair {"code"}: no bearer key (the code is the credential). 200 {"key", "name", "version"} once per
    code; 401 invalid_code, 410 code_expired (used or past its 10 minutes), 429 too_many_attempts."""
    if not CFG["live_key"]:
        return jerr(503, "pairing_off", message="the bridge has no app key (LIVE_PAGE_KEY)")
    client = req.remote or "?"
    now = time.monotonic()
    wait = pair_retry_after(client, now)
    if wait:
        return jerr(429, "too_many_attempts", message="too many wrong codes; try again later", retry_after_s=wait,
                    headers={"Retry-After": str(wait)})
    body, bad = await read_json(req)
    if bad:
        return bad
    canon, digest = pair_hash(body.get("code") if isinstance(body.get("code"), str) else "")
    if not 6 <= len(canon) <= 32:
        return jerr(400, "bad_request", message="code must be the pairing code the setup showed")
    # No await between reading and rewriting the file, so two requests cannot both take one code.
    path = pair_file()
    try:
        with open(path) as f:
            data = json.load(f)
        entries = data.get("codes") if isinstance(data, dict) else None
        entries = entries if isinstance(entries, list) else []
    except (OSError, ValueError):
        entries, data = [], None
    entry = next((e for e in entries if isinstance(e, dict) and isinstance(e.get("sha256"), str)
                  and hmac.compare_digest(e["sha256"], digest)), None)
    if entry is None:
        PAIR_FAILS.append((now, client))
        log.info("pairing: wrong code")
        return jerr(401, "invalid_code", message="that pairing code is not right")
    if entry.get("used_at") or float(entry.get("expires_at") or 0) <= time.time():
        log.info("pairing: expired or used code")
        return jerr(410, "code_expired", message="that pairing code has expired or was already used")
    entry["used_at"] = int(time.time())
    try:
        tmp = path + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({**data, "codes": entries}, f)
        os.replace(tmp, path)
    except OSError as exc:
        # Without marking it used the code could be traded twice: refuse rather than hand the key out.
        log.error("pairing: cannot update %s: %s", path, type(exc).__name__)
        return jerr(500, "pairing_failed", message="the bridge could not record the pairing")
    log.info("pairing: a device paired")
    return web.json_response({"key": CFG["live_key"], "name": CFG["assistant_name"], "version": API_VERSION},
                             headers={"Cache-Control": "no-store"})


async def api_notify(req):
    """POST /api/notify {"text", "kind"?, "dedupe"?}: Hermes' scheduled jobs (on this host) post a message from the
    assistant into its own chat, and registered devices get the usual chat.reply push. Own key (TOVE_NOTIFY_KEY), and
    only through a loopback Host, so a request through a public route is refused even with the key."""
    if not CFG.get("notify_key"):
        return jerr(404, "not_found")
    host = (req.host or "").lower()
    if not any(host == h or host.startswith(h + ":") for h in NOTIFY_LOOPBACK_HOSTS):
        return jerr(403, "forbidden", message="this route is for jobs on the bridge's own host")
    if not notify_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    body, bad = await read_json(req)
    if bad:
        return bad
    text, kind, dedupe = body.get("text"), body.get("kind", "note"), body.get("dedupe")
    if not isinstance(text, str) or not text.strip() or len(text) > MAX_MESSAGE_CHARS:
        return jerr(400, "bad_request", message="text must be 1-%d characters" % MAX_MESSAGE_CHARS)
    if kind not in NOTIFY_KINDS:
        return jerr(400, "bad_request", message="kind must be one of " + ", ".join(NOTIFY_KINDS))
    if dedupe is not None and not valid_id(dedupe):
        return jerr(400, "bad_request", message="dedupe must be 1-64 characters of A-Z a-z 0-9 _ -")
    client_id = "notify-" + dedupe if dedupe else None
    if client_id and store.db.execute("SELECT 1 FROM messages WHERE client_id = ? AND source = 'notify'", (client_id,)).fetchone():
        return web.json_response({"ok": True, "duplicate": True})
    now = time.monotonic()
    while NOTIFY_SENT and now - NOTIFY_SENT[0] >= 3600:
        NOTIFY_SENT.popleft()
    if len(NOTIFY_SENT) >= NOTIFY_RATE_PER_HOUR:
        return jerr(429, "rate_limited", message="at most %d assistant messages an hour" % NOTIFY_RATE_PER_HOUR)
    NOTIFY_SENT.append(now)
    conv = store.notify_conversation(CFG["assistant_name"])
    msg = store.add_message(conv["id"], "assistant", text.strip(), source="notify", client_id=client_id, meta={"notify": kind})
    devices = len(store.push_devices()) if CFG["push_enabled"] else 0
    notify("chat.reply", conv["id"], msg["id"], "done", msg["text"])
    emit_event("notify", conversation_id=conv["id"], message_id=msg["id"], kind=kind, **event_text(conv["id"], msg["text"]))
    log.info("assistant message posted (%s, %d device(s) to push)", kind, devices)
    return web.json_response({"ok": True, "conversation_id": conv["id"], "message_id": msg["id"], "push_devices": devices})


async def api_push_register(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    if not CFG["push_enabled"]:
        return jerr(503, "push_disabled", message="push notifications are turned off on this bridge")
    body, bad = await read_json(req)
    if bad:
        return bad
    device_id, endpoint, app_version = body.get("device_id"), body.get("endpoint"), body.get("app_version", "")
    if not valid_id(device_id):
        return jerr(400, "bad_device_id", message="device_id must be 1-64 characters of A-Z a-z 0-9 _ -")
    why = push_endpoint_error(endpoint)
    if why:
        return jerr(400, "bad_endpoint", message=why)
    if app_version is None:
        app_version = ""
    if not isinstance(app_version, str) or len(app_version) > 64:
        return jerr(400, "bad_app_version", message="app_version must be a string of at most 64 characters")
    if store.push_device(device_id) is None and store.push_count_others(device_id, endpoint) >= CFG["push_max_devices"]:
        return jerr(409, "too_many_devices", message="at most %d devices can register; unregister one first" % CFG["push_max_devices"])
    store.push_register(device_id, endpoint, app_version.strip())
    return web.json_response({"ok": True, "device_id": device_id, "previews": CFG["push_previews"]})


async def api_push_unregister(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    device_id = req.match_info["device_id"]
    if not valid_id(device_id):
        return jerr(404, "not_found", message="no such device")
    return web.json_response({"ok": True, "removed": store.push_unregister(device_id)})


async def api_push_test(req):
    """POST /api/push/test {device_id}: send one test push to that device and report the distributor's answer."""
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    if not CFG["push_enabled"]:
        return jerr(503, "push_disabled", message="push notifications are turned off on this bridge")
    body, bad = await read_json(req)
    if bad:
        return bad
    dev = store.push_device(body.get("device_id")) if valid_id(body.get("device_id")) else None
    if dev is None:
        return jerr(404, "not_found", message="no such device")
    sent = PUSH_SENT[dev["device_id"]]
    if len([t for t in sent if time.monotonic() - t < 60]) >= CFG["push_rate_per_min"]:
        return jerr(429, "rate_limited", message="too many pushes to this device in the last minute")
    payload = {"type": "test", "conversation_id": None, "message_id": None, "title": "Test notification",
               "preview": "Push notifications from the bridge work.", "status": "done", "sent": now_ms()}
    code = (await send_push([dev], payload)).get(dev["device_id"])
    return web.json_response({"ok": True, "delivered": code is not None and 200 <= code < 300, "status": code})


def _store_or_error():
    store = CHAT["store"]
    return store, (None if store is not None else jerr(503, "history_unavailable", message="chat history is not available"))


def _conv_or_404(store, cid):
    conv = store.get_conversation(cid) if valid_id(cid) else None
    return conv, (None if conv is not None else jerr(404, "not_found", message="no such conversation"))


def _int_param(req, name, default, lo, hi):
    raw = req.query.get(name)
    if raw is None or raw == "":
        return default
    if not re.fullmatch(r"\d{1,6}", raw) or not lo <= int(raw) <= hi:
        raise ValueError(name)
    return int(raw)


async def api_capabilities(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store_ok, hermes_ok = CHAT["store"] is not None, bool(CFG["hermes_key"])
    lb = live_backends()
    openai_active = lb["active"] == "openai"
    left = openai_seconds_left()
    backends = {
        "codex": {"available": lb["codex"], "active": lb["active"] == "codex", "voices": sorted(V3_VOICES), "default_voice": CFG["voice"],
                  "server_delegation": False, "warm_start": True},
        "openai": {"available": lb["openai"], "active": openai_active, "model": CFG["openai_model"],
                   "voices": sorted(OPENAI_VOICES), "default_voice": openai_voice(None), "server_delegation": True,
                   "max_call_s": min(CFG["call_seconds"], CFG["openai_call_min"] * 60), "daily_minutes": CFG["openai_daily_min"] or None,
                   "minutes_left_today": None if left is None else round(left / 60, 1), "price_per_minute_usd": 0.05},
    }
    return web.json_response({
        "live_backend": lb["active"], "live_backends": backends,
        "version": API_VERSION, "chat": store_ok and hermes_ok, "history": store_ok, "search": store_ok,
        "effort": hermes_ok, "efforts": list(EFFORTS), "language": False,
        "attachments": uploads_enabled(), "vision": uploads_enabled() and CFG["vision"],
        "attachment_limits": {"max_items": CFG["upload_max_items"], "image_mb": CFG["upload_image_mb"], "file_mb": CFG["upload_file_mb"],
                              "conversation_mb": CFG["upload_conv_mb"], "image_max_edge": 2048, "mimes": upload_mimes(),
                              "unused_hours": CFG["upload_unused_h"]},
        "web_search": hermes_ok and await hermes_has_web_search(), "ui_prompt": bool(ui_prompt()), "ui_prompt_header": UI_HEADER,
        "ui_blocks": bool(ui_prompt()), "ui_blocks_version": UI_BLOCKS_VERSION if ui_prompt() else None,
        "ui_prompt_versions": [v for v in (1, 2) if ui_prompt(v) and (v == 1 or ui_prompt(v) != ui_prompt(1))],
        "link_preview": CFG["link_preview"], "link_preview_images": CFG["link_preview"], "favicon": CFG["link_preview"],
        "entity_info": CFG["link_preview"],
        "places": places_capability(), "location": True,
        "image_proxy": {"max_mb": IMAGE_PROXY_MAX // MIB, "widths": list(IMAGE_PROXY_WIDTHS),
                        "types": sorted(LINK_IMAGE_TYPES)} if CFG["link_preview"] else False,
        "tool_parts": True, "job_progress": True, "live_warm": lb["active"] == "codex",
        "steps": True, "step_limits": {"io_chars": STEP_IO_MAX, "thinking_chars": STEP_TEXT_MAX, "steps": STEPS_MAX},
        "status_events": True, "live_link": store_ok, "live_transcript": store_ok,
        "usage": True, "settings_sync": store_ok, "suggestions": True,
        "settings_limits": {"bytes": SETTINGS_MAX_BYTES, "text_chars": SETTINGS_TEXT_CHARS},
        "titles": title_mode(),
        "usage_limits": usage_limits_enabled(),
        "error_codes": True, "stream": "sse",
        "voices": backends[lb["active"]]["voices"], "default_voice": backends[lb["active"]]["default_voice"],
        # resumable_stream: replies run in the background; a dropped connection resumes with GET /api/chat/{id}/stream,
        # and only POST /api/chat/{id}/stop stops a reply (unless disconnect_cancels says otherwise).
        "resumable_stream": True, "stop_endpoint": True, "pairing": True, "disconnect_cancels": CFG["stream_disconnect"] == "cancel",
        "push": "unifiedpush" if store_ok and CFG["push_enabled"] else False, "push_previews": CFG["push_previews"],
        # The app's own notification stream (API.md "Events") and live tasks written into their chat ("Live tasks").
        "events": {"version": 1, "heartbeat_s": CFG["events_heartbeat_s"], "heartbeat_range": [15, 600], "keep": CFG["events_keep"],
                   "types": list(EVENT_TYPES), "poll": True, "test": True, "readers_max": EVENT_READERS_MAX,
                   "sync": True, "sync_text_chars": SYNC_TEXT_CHARS} if store_ok else False,
        "task_messages": store_ok and bool(CFG["hermes_key"]), "task_ui": bool(CFG["task_ui"] and ui_prompt()),
        # Dictation on the server (API.md "Transcription").
        "transcribe": {"max_s": CFG["stt_max_s"], "formats": ["audio/wav"], "model": CFG["stt_model"],
                       "prompt_chars": STT_PROMPT_CHARS} if transcribe_enabled() else False,
        "jobs_after_call": True,
        "report": {"reasons": list(REPORT_REASONS), "note_chars": REPORT_NOTE_CHARS},
        "limits": {"message_chars": MAX_MESSAGE_CHARS, "title_chars": MAX_TITLE_CHARS, "query_chars": MAX_QUERY_CHARS,
                   "page_max": PAGE_MAX, "messages_page_max": MSG_PAGE_MAX, "concurrent_chats": CFG["max_chats"],
                   "transcript_turns": MAX_TURNS, "transcript_tasks": MAX_TASKS, "task_chars": MAX_TASK_CHARS,
                   "keepalive_s": KEEPALIVE_S, "chat_timeout_s": CHAT_TIMEOUT_S, "live_jobs": CFG["max_jobs"],
                   "stream_keep_s": CFG["stream_keep_s"], "stream_buffer_events": CFG["stream_buffer"],
                   "push_devices": CFG["push_max_devices"], "push_per_minute": CFG["push_rate_per_min"],
                   "push_preview_chars": PUSH_PREVIEW_CHARS}})


# ----------------------------------------------------------------------------------------------------------------
# Attachments (API.md "Attachments"). Files are stored once per sha256 under LIVE_UPLOAD_DIR (mode 600, never
# executable); the uploads table holds names, owners and sizes. Images go to Hermes as image_url parts (Hermes'
# /v1/chat/completions accepts them; checked 15 November 2026). Documents are copied into HERMES_UPLOAD_DIR and named
# in the prompt; their bytes never go into the prompt.
# ----------------------------------------------------------------------------------------------------------------
MIB = 1024 * 1024
IMAGE_MIMES = {"image/jpeg", "image/png", "image/webp"}
OFFICE_MIMES = {
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": ".docx",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": ".xlsx",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation": ".pptx",
    "application/vnd.oasis.opendocument.text": ".odt",
    "application/vnd.oasis.opendocument.spreadsheet": ".ods",
    "application/vnd.oasis.opendocument.presentation": ".odp"}
OFFICE_BY_EXT = {ext: mime for mime, ext in OFFICE_MIMES.items()}
TEXT_SUBTYPES = {"plain", "markdown", "csv", "tab-separated-values", "x-log", "x-python", "x-yaml", "yaml", "x-toml", "xml",
                 "html", "css", "javascript", "x-c", "x-java", "x-rust", "x-go", "x-sh", "x-shellscript", "rtf", "calendar", "vcard"}
EXECUTABLE_MAGIC = (b"\x7fELF", b"MZ", b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe",
                    b"\xca\xfe\xba\xbe", b"\x00asm", b"dex\n")
# Extensions that get ".txt" added in Hermes' workspace, so nothing there looks runnable by name.
RUNNABLE_EXT = {"sh", "bash", "zsh", "fish", "ps1", "psm1", "bat", "cmd", "com", "exe", "msi", "scr", "apk", "jar", "bin", "run",
                "appimage", "dmg", "deb", "rpm", "so", "dll", "dylib", "elf", "out", "vbs", "js", "mjs", "cjs", "pl", "rb", "php"}
PREVIEW_EDGE, MAX_IMAGE_EDGE = 512, 8192
UPLOAD_GC_EVERY_S = 3600


def human_size(n):
    for unit, size in (("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10)):
        if n >= size:
            return "%.1f %s" % (n / size, unit)
    return "%d bytes" % n


def upload_blob(sha):
    return os.path.join(CFG["upload_dir"], "blobs", sha)


def upload_preview_path(sha):
    return os.path.join(CFG["upload_dir"], "previews", sha + ".jpg")


def hermes_side_path(rel):
    base = CFG["hermes_upload_path"] or CFG["hermes_upload_dir"]
    return base.rstrip("/") + "/" + rel


def uploads_enabled():
    return CFG["uploads"] and CHAT["store"] is not None and (CFG["vision"] or bool(CFG["hermes_upload_dir"]))


def upload_mimes():
    mimes = sorted(IMAGE_MIMES) if (CFG["vision"] or CFG["hermes_upload_dir"]) else []
    if CFG["hermes_upload_dir"]:
        mimes += ["application/pdf", "text/*", "application/json"] + sorted(OFFICE_MIMES)
    return mimes


def safe_name(name):
    name = str(name or "").replace("\\", "/").rsplit("/", 1)[-1]
    name = re.sub(r"[\x00-\x1f\x7f]", "", name)
    name = re.sub(r"\s+", " ", name).strip().lstrip(".").strip()
    if len(name) > 120:
        stem, dot, ext = name.rpartition(".")
        name = (stem[: 110 - len(ext)] + "." + ext) if dot and len(ext) <= 10 else name[:120]
    return name or "file"


def workspace_name(name):
    name = re.sub(r"[^\w.\- ()+,@]", "_", safe_name(name)).replace(" ", "_")
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    return name + ".txt" if ext in RUNNABLE_EXT else name


def image_size(head):
    """(width, height) from a JPEG, PNG or WebP header, else None. No decoder involved."""
    try:
        if head.startswith(b"\x89PNG\r\n\x1a\n") and head[12:16] == b"IHDR":
            return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")
        if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
            chunk = head[12:16]
            if chunk == b"VP8X":
                return 1 + int.from_bytes(head[24:27], "little"), 1 + int.from_bytes(head[27:30], "little")
            if chunk == b"VP8 ":
                return int.from_bytes(head[26:28], "little") & 0x3FFF, int.from_bytes(head[28:30], "little") & 0x3FFF
            if chunk == b"VP8L":
                b = int.from_bytes(head[21:25], "little")
                return (b & 0x3FFF) + 1, ((b >> 14) & 0x3FFF) + 1
        if head[:3] == b"\xff\xd8\xff":
            i = 2
            while i + 9 < len(head):
                if head[i] != 0xFF:
                    i += 1
                    continue
                marker = head[i + 1]
                if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7 or marker == 0xFF:
                    i += 1 if marker == 0xFF else 2
                    continue
                length = int.from_bytes(head[i + 2:i + 4], "big")
                if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                    return int.from_bytes(head[i + 7:i + 9], "big"), int.from_bytes(head[i + 5:i + 7], "big")
                i += 2 + length
    except (IndexError, ValueError):
        return None
    return None


def sniff_upload(path, head, declared, name):
    """(mime, kind) from the file's own bytes, or None when the type is not accepted. The declared type and the name
    only choose between formats that share a container (office ZIPs, text subtypes)."""
    declared = str(declared or "").split(";")[0].strip().lower()
    ext = ("." + name.rsplit(".", 1)[-1].lower()) if "." in name else ""
    if head.startswith(EXECUTABLE_MAGIC) or head.startswith(b"#!"):
        return None
    if head[:3] == b"\xff\xd8\xff":
        return "image/jpeg", "image"
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png", "image"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp", "image"
    if head.startswith(b"%PDF-"):
        return "application/pdf", "file"
    if head.startswith(b"PK\x03\x04"):
        mime = declared if declared in OFFICE_MIMES else OFFICE_BY_EXT.get(ext)
        if not mime:
            return None
        try:
            with zipfile.ZipFile(path) as z:
                names = z.namelist()
        except Exception:
            return None
        lowered = [n.lower() for n in names]
        if any(n.endswith(("vbaproject.bin", ".exe", ".dll", ".js", ".vbs")) or "/macros/" in n or n.startswith("basic/") for n in lowered):
            return None                                   # macros or embedded programs
        is_ooxml, is_odf = "[content_types].xml" in lowered, "mimetype" in lowered
        return (mime, "file") if (is_odf if OFFICE_MIMES[mime].startswith(".od") else is_ooxml) else None
    if b"\x00" in head:
        return None
    try:
        sample = head.decode("utf-8")
    except UnicodeDecodeError as exc:
        if exc.start < len(head) - 4:                     # only a multibyte character cut at the sample's end is fine
            return None
        sample = head[:exc.start].decode("utf-8")
    stripped = sample.lstrip()
    if (declared == "application/json" or ext == ".json") and stripped[:1] in ("{", "["):
        try:
            if os.path.getsize(path) <= 4 * MIB:
                json.loads(Path(path).read_text("utf-8"))
            return "application/json", "file"
        except (ValueError, OSError):
            pass
    sub = declared.split("/", 1)[1] if declared.startswith("text/") else ""
    return ("text/" + sub if sub in TEXT_SUBTYPES else "text/plain"), "file"


def make_preview(src, dst, edge=PREVIEW_EDGE):
    """Decode an image (PyAV/ffmpeg, already a dependency) and write a JPEG of at most `edge` px. Returns (w, h) of the
    decoded original. Raises on anything that does not decode. Metadata is not copied."""
    with av.open(src) as c:
        frame = next(c.decode(video=0))
    w, h = frame.width, frame.height
    scale = min(1.0, edge / max(w, h))
    nw, nh = max(2, int(w * scale) // 2 * 2), max(2, int(h * scale) // 2 * 2)
    img = frame.reformat(width=nw, height=nh, format="yuvj420p")
    enc = av.CodecContext.create("mjpeg", "w")
    enc.width, enc.height, enc.pix_fmt, enc.time_base = nw, nh, "yuvj420p", fractions.Fraction(1, 25)
    enc.options = {"qmin": "2", "qmax": "6"}
    data = b"".join(bytes(p) for p in enc.encode(img)) + b"".join(bytes(p) for p in enc.encode(None))
    os.makedirs(os.path.dirname(dst), mode=0o700, exist_ok=True)
    tmp = dst + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.replace(tmp, dst)
    return w, h


def copy_to_workspace(row, cid):
    """Copy an upload where Hermes' tools can read it: HERMES_UPLOAD_DIR/<conversation>/<name> (mode 640, so a setgid
    directory with Hermes' group gives Hermes read access). Returns the path relative to that directory."""
    folder = os.path.join(CFG["hermes_upload_dir"], cid)
    os.makedirs(folder, mode=0o750, exist_ok=True)
    name = workspace_name(row["name"])
    target = os.path.join(folder, name)
    if os.path.exists(target):
        name = row["id"][-8:] + "-" + name
        target = os.path.join(folder, name)
    tmp = target + ".part"
    shutil.copyfile(upload_blob(row["sha256"]), tmp)
    os.chmod(tmp, 0o640)
    os.replace(tmp, target)
    return cid + "/" + name


def gc_uploads(store):
    """Delete blobs, previews and workspace copies that no upload row references, and unused uploads past their time."""
    removed = store.expire_uploads(now_ms() - CFG["upload_unused_h"] * 3600 * 1000)
    shas = store.live_shas()
    for sub, strip in (("blobs", ""), ("previews", ".jpg")):
        folder = os.path.join(CFG["upload_dir"], sub)
        try:
            names = os.listdir(folder)
        except OSError:
            continue
        for n in names:
            sha = n[: -len(strip)] if strip and n.endswith(strip) else n
            if sha not in shas:
                try:
                    os.remove(os.path.join(folder, n))
                except OSError:
                    pass
    root = CFG["hermes_upload_dir"]
    if root and os.path.isdir(root):
        keep = store.live_workspaces()
        for cid in os.listdir(root):
            folder = os.path.join(root, cid)
            if not valid_id(cid) or not os.path.isdir(folder):
                continue
            for n in os.listdir(folder):
                if cid + "/" + n not in keep:
                    try:
                        os.remove(os.path.join(folder, n))
                    except OSError:
                        pass
            try:
                os.rmdir(folder)                         # only when empty
            except OSError:
                pass
    return removed


async def upload_housekeeping():
    while True:
        await asyncio.sleep(UPLOAD_GC_EVERY_S)
        if CHAT["store"] is not None:
            try:
                gc_uploads(CHAT["store"])
            except Exception as exc:
                log.warning("upload cleanup failed: %s", type(exc).__name__)


def upload_public(row):
    out = {"id": row["id"], "name": row["name"], "mime": row["mime"], "size": row["size"], "kind": row["kind"]}
    if row["kind"] == "image":
        out.update(width=row["width"], height=row["height"], preview_url="/api/uploads/%s/preview" % row["id"])
    return out


async def api_upload_create(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    if not uploads_enabled():
        return jerr(503, "uploads_unavailable", message="uploads are not configured on this server")
    store = CHAT["store"]
    cap = max(CFG["upload_image_mb"], CFG["upload_file_mb"]) * MIB
    if req.content_length is not None and req.content_length > cap + 64 * 1024:
        return jerr(413, "too_large", message="the file is larger than this server accepts")
    try:
        reader = await req.multipart()
    except Exception:
        return jerr(400, "bad_upload", message="send multipart/form-data with one part named file")
    tmpdir = os.path.join(CFG["upload_dir"], "tmp")
    os.makedirs(tmpdir, mode=0o700, exist_ok=True)
    tmp = os.path.join(tmpdir, secrets.token_hex(8))
    conv_id, got, size, head, digest = None, None, 0, b"", None
    try:
        try:
            while True:
                part = await reader.next()
                if part is None:
                    break
                if part.name == "conversation_id" and part.filename is None:
                    raw = await part.read_chunk(256)
                    if await part.read_chunk(1):
                        return jerr(400, "bad_upload", message="conversation_id is too long")
                    conv_id = raw.decode("utf-8", "replace").strip() or None
                elif part.name == "file" and got is None:
                    digest = hashlib.sha256()
                    name = part.filename or ""            # aiohttp prefers RFC 5987 filename*= when present
                    if re.search(r"%[0-9A-Fa-f]{2}", name):
                        name = urllib.parse.unquote(name)  # some clients percent-encode the plain filename=
                    got = {"name": safe_name(name), "declared": part.headers.get("Content-Type", "")}
                    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                    with os.fdopen(fd, "wb") as f:
                        while True:
                            chunk = await part.read_chunk(256 * 1024)
                            if not chunk:
                                break
                            size += len(chunk)
                            if size > cap:
                                return jerr(413, "too_large", message="the file is larger than this server accepts")
                            if len(head) < 65536:
                                head += chunk[: 65536 - len(head)]
                            digest.update(chunk)
                            f.write(chunk)
                else:
                    return jerr(400, "bad_upload", message="one part named file (and optionally conversation_id) only")
        except (ValueError, aiohttp.ClientError, asyncio.IncompleteReadError, OSError) as exc:
            if isinstance(exc, OSError) and not isinstance(exc, (ConnectionError,)):
                log.warning("upload not stored: %s", type(exc).__name__)
            return jerr(400, "bad_upload", message="the multipart body could not be read")
        if got is None or size == 0:
            return jerr(400, "bad_upload", message="no file, or an empty file")
        if conv_id is not None and (not valid_id(conv_id) or store.get_conversation(conv_id) is None):
            return jerr(404, "not_found", message="no such conversation")
        sniffed = sniff_upload(tmp, head, got["declared"], got["name"])
        if sniffed is None or (sniffed[1] == "file" and not CFG["hermes_upload_dir"]):
            return jerr(415, "unsupported_type", message="this file type is not accepted")
        mime, kind = sniffed
        limit = (CFG["upload_image_mb"] if kind == "image" else CFG["upload_file_mb"]) * MIB
        if size > limit:
            return jerr(413, "too_large", message="the file is larger than %d MB" % (limit // MIB))
        if store.upload_bytes() + size > CFG["upload_total_mb"] * MIB or \
                (conv_id and store.upload_bytes(conv_id) + size > CFG["upload_conv_mb"] * MIB):
            return jerr(507, "quota_exceeded", message="the server's upload storage for this chat is full")
        sha = digest.hexdigest()
        width = height = None
        if kind == "image":
            dims = image_size(head)
            if not dims or not all(0 < d <= MAX_IMAGE_EDGE for d in dims):
                return jerr(415, "unsupported_type", message="the image could not be read or is too large in pixels")
            try:
                width, height = await asyncio.get_running_loop().run_in_executor(None, make_preview, tmp, upload_preview_path(sha))
            except Exception as exc:
                log.info("image upload rejected: %s", type(exc).__name__)
                return jerr(415, "unsupported_type", message="the image could not be decoded")
        blob = upload_blob(sha)
        os.makedirs(os.path.dirname(blob), mode=0o700, exist_ok=True)
        if os.path.exists(blob):
            os.remove(tmp)
        else:
            os.chmod(tmp, 0o600)
            os.replace(tmp, blob)
        row = {"id": "up_" + secrets.token_urlsafe(12).replace("-", "x"), "sha256": sha, "name": got["name"], "mime": mime, "size": size,
               "kind": kind, "width": width, "height": height, "conversation_id": conv_id, "created": now_ms()}
        store.add_upload(row)
        log.info("upload stored: %s, %s", kind, human_size(size))
        return web.json_response({**upload_public(row), "sha256": sha, "created": row["created"]}, status=201)
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass


def _upload_or_404(req):
    row = CHAT["store"].upload(req.match_info["uid"]) if CHAT["store"] is not None and valid_id(req.match_info["uid"]) else None
    return row, (None if row is not None else jerr(404, "not_found", message="no such upload"))


async def _file_response(req, path, mime, etag, name=None):
    """The stored bytes with the sha256 as ETag (aiohttp's FileResponse would replace it with mtime-size)."""
    if req.headers.get("If-None-Match", "").strip('" W/') == etag:
        return web.Response(status=304, headers={"ETag": '"%s"' % etag, "Cache-Control": "private, max-age=86400"})
    headers = {"Content-Type": "text/plain; charset=utf-8" if mime.startswith("text/") else mime, "ETag": '"%s"' % etag,
               "Cache-Control": "private, max-age=86400", "X-Content-Type-Options": "nosniff",
               "Content-Security-Policy": "sandbox; default-src 'none'", "Referrer-Policy": "no-referrer"}
    if name:
        headers["Content-Disposition"] = "inline; filename*=UTF-8''" + urllib.parse.quote(name, safe="")
    body = await asyncio.get_running_loop().run_in_executor(None, Path(path).read_bytes)
    return web.Response(body=body, headers=headers)


async def api_upload_get(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    row, bad = _upload_or_404(req)
    if bad:
        return bad
    path = upload_blob(row["sha256"])
    if not os.path.isfile(path):
        return jerr(404, "not_found", message="the file is missing on the server")
    return await _file_response(req, path, row["mime"], row["sha256"], row["name"])


async def api_upload_preview(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    row, bad = _upload_or_404(req)
    if bad:
        return bad
    if row["kind"] != "image":
        return jerr(404, "not_found", message="previews exist for images only")
    path = upload_preview_path(row["sha256"])
    if not os.path.isfile(path):
        try:
            await asyncio.get_running_loop().run_in_executor(None, make_preview, upload_blob(row["sha256"]), path)
        except Exception:
            return jerr(404, "not_found", message="no preview")
    return await _file_response(req, path, "image/jpeg", row["sha256"] + "-p")


async def api_upload_delete(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    row, bad = _upload_or_404(req)
    if bad:
        return bad
    if row["message_id"]:
        return jerr(409, "in_use", message="a message uses this upload; delete the message instead")
    CHAT["store"].delete_upload(row["id"])
    gc_uploads(CHAT["store"])
    return web.Response(status=204)


def workspace_copies(conv_id, rows):
    """Copy documents (and images Hermes cannot see) into Hermes' workspace; runs in a thread, so no database access.
    Returns [(upload id, relative path)]. A failed copy leaves a "could not be given to you" note in the prompt."""
    done = []
    for row in rows:
        if row["workspace"] or not CFG["hermes_upload_dir"] or (row["kind"] == "image" and CFG["vision"]):
            continue
        try:
            done.append((row["id"], copy_to_workspace(row, conv_id)))
        except OSError as exc:
            log.warning("attachment not copied to Hermes' workspace: %s", type(exc).__name__)
    return done


# ---- link previews (Open Graph), fetched by the bridge so the app contacts no linked site itself
LINK_CACHE = collections.OrderedDict()               # url -> (expires, (status, body), bytes)
LINK_CACHE_MAX, LINK_CACHE_S, LINK_FAIL_CACHE_S = 256, 3600, 300
LINK_HTML_MAX, LINK_IMAGE_MAX, LINK_ICON_MAX = 512 * 1024, 300 * 1024, 64 * 1024
# A markdown image in a reply (![alt](url)) is previewed by fetching the image URL itself: the picture IS the content,
# so it gets a larger cap than a page's og:image. Cached previews are kept under a byte budget.
LINK_DIRECT_IMAGE_MAX, LINK_CACHE_BYTES = 3 * 1024 * 1024, 48 * 1024 * 1024
LINK_TIMEOUT_S, LINK_TOTAL_S, LINK_REDIRECTS = 5, 10, 3
LINK_REQUEST_S = 8                                    # one request incl. body; LINK_TOTAL_S bounds the whole preview
LINK_PORTS = {80, 443, 8080, 8443}
LINK_IMAGE_TYPES = {"image/jpeg", "image/png", "image/webp", "image/gif"}
# A descriptive agent, as Wikimedia's User-Agent policy asks: it answers 429 to generic ones such as the old
# "Mozilla/5.0 (compatible; link-preview)" (checked 16 November 2026). No browser imitation: a site that refuses bots
# (a WAF or a Cloudflare challenge) stays refused.
LINK_UA = "ToveBridge/1.0 (self-hosted chat app; link and image previews)"
LINK_ICON_TYPES = LINK_IMAGE_TYPES | {"image/x-icon", "image/vnd.microsoft.icon"}


class LinkBlocked(Exception):
    pass


class LinkRateLimited(LinkBlocked):
    """The site answered 429 (code fetch_failed, as before); the image proxy waits briefly and tries once more."""

    def __init__(self, retry_after=None):
        super().__init__("fetch_failed")
        self.retry_after = retry_after


def wire_url(url):
    """The URL exactly as written when it is plain ASCII: aiohttp would re-quote the path otherwise (%2C becomes ","),
    and some hosts (Wikimedia's thumbnails) then serve a different or missing file."""
    if url.isascii() and not any(c.isspace() for c in url):
        try:
            return yarl.URL(url, encoded=True)
        except ValueError:
            pass
    return url


def public_ip(addr) -> bool:
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    # is_global excludes private, loopback, link-local, CGNAT/tailnet (100.64/10), reserved and documentation ranges
    return ip.is_global and not ip.is_multicast


def check_link_url(url):
    try:
        u = urllib.parse.urlsplit(url)
        port = u.port
    except ValueError:
        raise LinkBlocked("bad_url")
    if u.scheme not in ("http", "https") or not u.hostname or u.username or u.password or len(url) > 2048:
        raise LinkBlocked("bad_url")
    if (port or (443 if u.scheme == "https" else 80)) not in LINK_PORTS:
        raise LinkBlocked("blocked_url")
    host = u.hostname.rstrip(".").lower()
    if host == "localhost" or host.endswith((".localhost", ".local", ".internal", ".lan", ".home.arpa", ".ts.net")):
        raise LinkBlocked("blocked_url")
    try:
        ipaddress.ip_address(host)
        if not public_ip(host):
            raise LinkBlocked("blocked_url")
    except ValueError:
        pass
    return u


class PublicResolver(AbstractResolver):
    """Resolves like the system resolver but only returns public addresses, so the connection goes to the address that
    was checked (no DNS-rebinding window)."""

    async def resolve(self, host, port=0, family=socket.AF_INET):
        infos = await asyncio.get_running_loop().getaddrinfo(host, port, type=socket.SOCK_STREAM, family=family)
        out = [{"hostname": host, "host": info[4][0], "port": port, "family": info[0], "proto": 0, "flags": socket.AI_NUMERICHOST}
               for info in infos if public_ip(info[4][0])]
        if not out or len(out) != len(infos):
            raise OSError("non-public address")       # any private answer: refuse the host as a whole
        return out

    async def close(self):
        pass


async def link_fetch(session, url, accept, limit, image_limit=None, ua=None):
    """GET with manual redirects (each target re-checked); returns (final url, content type, body ≤ limit, cut).
    ``image_limit`` replaces ``limit`` when the response turns out to be a supported image. A body whose declared
    Content-Length is over the limit is not read at all (returned empty, cut=True)."""
    for _ in range(LINK_REDIRECTS + 1):
        check_link_url(url)
        async with session.get(wire_url(url), allow_redirects=False, headers={"Accept": accept, "User-Agent": ua or LINK_UA}) as r:
            if r.status in (301, 302, 303, 307, 308) and r.headers.get("Location"):
                url = urllib.parse.urljoin(url, r.headers["Location"])
                continue
            if r.status == 429:
                ra = r.headers.get("Retry-After", "")
                raise LinkRateLimited(int(ra) if ra.isdigit() else None)
            if r.status != 200:
                raise LinkBlocked("fetch_failed")
            ctype = r.headers.get("Content-Type", "").split(";")[0].strip().lower()
            if image_limit is not None and ctype in LINK_IMAGE_TYPES:
                limit = image_limit
            if r.content_length is not None and r.content_length > limit:
                return url, ctype, b"", True
            body = bytearray()
            async for chunk in r.content.iter_chunked(65536):
                body += chunk
                if len(body) > limit:
                    break
            return url, ctype, bytes(body[:limit]), len(body) > limit
    raise LinkBlocked("fetch_failed")


class OGParser(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.meta, self.title, self.icons, self._in_title = {}, "", [], False

    def handle_starttag(self, tag, attrs):
        a = {k.lower(): (v or "") for k, v in attrs}
        if tag == "meta":
            key = (a.get("property") or a.get("name") or "").lower()
            if key in ("og:title", "og:site_name", "og:image", "og:image:secure_url", "twitter:image", "twitter:title",
                       "application-name") and key not in self.meta:
                self.meta[key] = a.get("content", "").strip()
        elif tag == "link" and "icon" in a.get("rel", "").lower().split() and a.get("href"):
            self.icons.append(a["href"])
        elif tag == "title":
            self._in_title = True

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False

    def handle_data(self, data):
        if self._in_title and len(self.title) < 300:
            self.title += data


IMAGE_MAGIC = {"image/jpeg": (b"\xff\xd8\xff",), "image/png": (b"\x89PNG\r\n\x1a\n",), "image/gif": (b"GIF87a", b"GIF89a"),
               "image/webp": (b"RIFF",), "image/x-icon": (b"\x00\x00\x01\x00",), "image/vnd.microsoft.icon": (b"\x00\x00\x01\x00",)}


def image_data_url(ctype, data):
    """A data URL for a small fetched image whose bytes match its declared type. The bridge never decodes images
    from linked sites (no decoder runs on untrusted web content); the app's image widget does that."""
    if not data or not data.startswith(IMAGE_MAGIC.get(ctype, (b"\x00never",))) or (ctype == "image/webp" and data[8:12] != b"WEBP"):
        return None
    return "data:%s;base64,%s" % (ctype, base64.b64encode(data).decode())


def link_image_size(data):
    """(width, height) of fetched image bytes from their header (image_size, plus GIF), or (None, None). A layout
    hint for the app; the decoded picture wins (EXIF rotation, for one, is not applied here)."""
    riff = 25 if data[12:16] == b"VP8L" else 30
    if len(data) < (riff if data[:4] == b"RIFF" else 24 if data[:4] == b"\x89PNG" else 10):
        return None, None                              # header cut short: image_size would read zero-filled fields
    dims = image_size(data)
    if dims is None and data[:6] in (b"GIF87a", b"GIF89a") and len(data) >= 10:
        dims = int.from_bytes(data[6:8], "little"), int.from_bytes(data[8:10], "little")
    w, h = dims or (None, None)
    return (w, h) if w and h and w <= 65535 and h <= 65535 else (None, None)


def link_image(ctype, data, cut):
    """(data URL, width, height) for fetched image bytes, or (None, None, None)."""
    url = image_data_url(ctype, data) if ctype in LINK_IMAGE_TYPES and not cut else None
    return (url, *link_image_size(data)) if url else (None, None, None)


async def build_link_preview(url):
    """Open Graph preview of a page ("kind": "page"), or, when the URL itself is an image, that image ("kind": "image").
    "width"/"height" describe "image" when they could be read from its header."""
    connector = aiohttp.TCPConnector(resolver=PublicResolver(), use_dns_cache=False, limit=4)
    timeout = aiohttp.ClientTimeout(total=LINK_REQUEST_S, sock_connect=LINK_TIMEOUT_S, sock_read=LINK_TIMEOUT_S)
    async with aiohttp.ClientSession(connector=connector, timeout=timeout, trust_env=False, max_field_size=16384) as s:
        final, ctype, body, cut = await link_fetch(s, url, "text/html,application/xhtml+xml,image/webp,image/jpeg,image/png,image/gif,image/*;q=0.5",
                                                   LINK_HTML_MAX, image_limit=LINK_DIRECT_IMAGE_MAX)
        host = urllib.parse.urlsplit(final).hostname or ""
        result = {"url": final, "title": None, "site_name": None, "image": None, "favicon": None, "kind": "page",
                  "width": None, "height": None}
        if ctype.startswith("image/"):
            # Only the four bitmap types whose bytes match their declared type; SVG (scriptable), AVIF/HEIC (no
            # check here), oversized or truncated bodies all come back with "image": null.
            result.update(kind="image", site_name=host)
            result["image"], result["width"], result["height"] = link_image(ctype, body, cut)
            return result
        if ctype not in ("text/html", "application/xhtml+xml"):
            result["site_name"] = host
            return result
        p = OGParser()
        try:
            p.feed(body.decode("utf-8", "replace"))
        except Exception:
            pass
        clean = lambda v, n: (re.sub(r"\s+", " ", v).strip()[:n] or None) if v else None
        result["title"] = clean(p.meta.get("og:title") or p.meta.get("twitter:title") or p.title, 200)
        result["site_name"] = clean(p.meta.get("og:site_name") or p.meta.get("application-name"), 80) or host
        image = p.meta.get("og:image:secure_url") or p.meta.get("og:image") or p.meta.get("twitter:image")
        if image:
            try:
                _, itype, data, cut = await link_fetch(s, urllib.parse.urljoin(final, image), "image/*", LINK_IMAGE_MAX)
                result["image"], result["width"], result["height"] = link_image(itype, data, cut)
            except (LinkBlocked, aiohttp.ClientError, asyncio.TimeoutError, OSError):
                pass
        for icon in (p.icons[:2] or ["/favicon.ico"]):
            try:
                _, itype, data, cut = await link_fetch(s, urllib.parse.urljoin(final, icon), "image/*", LINK_ICON_MAX)
                if itype in LINK_ICON_TYPES and not cut and image_data_url(itype, data):
                    result["favicon"] = image_data_url(itype, data)
                    break
            except (LinkBlocked, aiohttp.ClientError, asyncio.TimeoutError, OSError):
                continue
        return result


async def api_link_preview(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    if not CFG["link_preview"]:
        return jerr(503, "link_preview_disabled", message="link previews are turned off on this server")
    url = (req.query.get("url") or "").strip()
    try:
        check_link_url(url)
    except LinkBlocked as exc:
        return jerr(400, str(exc), message="only public http(s) links can be previewed")
    now = time.monotonic()
    hit = LINK_CACHE.get(url)
    if hit and hit[0] > now:
        LINK_CACHE.move_to_end(url)
        status, body = hit[1]
        return web.json_response(body, status=status, headers={"Cache-Control": "private, max-age=%d" % max(1, hit[0] - now)})
    try:
        body, status, keep = await asyncio.wait_for(build_link_preview(image_variant_url(url, 1280) or url), LINK_TOTAL_S), 200, LINK_CACHE_S
    except LinkBlocked as exc:
        code = str(exc)
        body, status, keep = {"error": code, "code": code, "message": "the link could not be previewed"}, 400 if code == "blocked_url" else 502, LINK_FAIL_CACHE_S
    except (aiohttp.ClientError, asyncio.TimeoutError, OSError, UnicodeError, ValueError):
        body, status, keep = {"error": "fetch_failed", "code": "fetch_failed", "message": "the link could not be fetched"}, 502, LINK_FAIL_CACHE_S
    if status == 200 and body.get("kind") == "image" and not body.get("image"):
        keep = LINK_FAIL_CACHE_S                       # unusable image (too large, wrong type): retry sooner
    link_cache_put(url, now + keep, status, body)
    return web.json_response(body, status=status, headers={"Cache-Control": "private, max-age=%d" % keep})


# ---- image proxy (round 6 B5): GET /api/image?url=&w= returns the picture's own bytes, for <img> in hermes-html,
# entity/news cards and markdown images. Same SSRF rules as link previews. The bridge still never decodes web images:
# "sensible sizes" come from each host's own sized variants (below), a byte cap, and the app decoding at frame size.
IMAGE_PROXY_MAX = 8 * MIB                             # bytes of one picture
IMAGE_PROXY_WIDTHS = (320, 640, 960, 1280, 1920)      # `w` is rounded up to one of these (default 1280)
IMAGE_CACHE_BYTES = 256 * MIB                         # on disk, <data>/image-cache, oldest dropped first
IMAGE_CACHE_S, IMAGE_FAIL_S = 7 * 86400, 300
IMAGE_FAILS = collections.OrderedDict()               # cache key -> (expires, status, code)
IMAGE_INFLIGHT = {}                                   # cache key -> Future, so one picture is fetched once at a time
IMAGE_SEM = None
IMAGE_HOST_SEMS = {}                                  # host -> Semaphore(2): Wikimedia answers bursts with 429
WIKIMEDIA_STEPS = (330, 500, 960, 1280, 1920)         # thumbnail widths upload.wikimedia.org serves without rendering
WIKIMEDIA_RE = re.compile(r"^/wikipedia/([a-z0-9.-]+)/([0-9a-f])/([0-9a-f]{2})/([^/]+)$")
WIKIMEDIA_THUMB_RE = re.compile(r"^/wikipedia/([a-z0-9.-]+)/thumb/([0-9a-f])/([0-9a-f]{2})/([^/]+)/(\d+)px-([^/]+)$")


def image_variant_url(url, width):
    """A smaller copy of `url` that its host already publishes, or None: Wikimedia Commons originals (often 4000+ px
    and several MB) become standard thumbnails (SVG ones a PNG rendering), Pinterest originals the 736x copy,
    Unsplash and Pexels get a width. Only well-known URL patterns; anything else is fetched as it is."""
    try:
        u = urllib.parse.urlsplit(url)
    except ValueError:
        return None
    host, path = (u.hostname or "").lower(), u.path
    t = WIKIMEDIA_THUMB_RE.match(path) if host in ("upload.wikimedia.org", "thumb.wikimedia.org") else None
    if t:                                            # already a thumbnail: a smaller standard step when it is larger
        step = next((w for w in WIKIMEDIA_STEPS if w >= width), WIKIMEDIA_STEPS[-1])
        if int(t.group(5)) <= step:
            return None
        return urllib.parse.urlunsplit((u.scheme, u.netloc, "/wikipedia/%s/thumb/%s/%s/%s/%dpx-%s" % (
            t.group(1), t.group(2), t.group(3), t.group(4), step, t.group(6)), "", ""))
    if host == "upload.wikimedia.org":
        m = WIKIMEDIA_RE.match(path)
        name = m.group(4) if m else ""
        ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
        if not m or ext not in ("jpg", "jpeg", "png", "gif", "webp", "svg"):
            return None
        step = next((w for w in WIKIMEDIA_STEPS if w >= width), WIKIMEDIA_STEPS[-1])
        thumb = "%dpx-%s%s" % (step, name, ".png" if ext == "svg" else "")
        return urllib.parse.urlunsplit((u.scheme, u.netloc, "/wikipedia/%s/thumb/%s/%s/%s/%s" % (m.group(1), m.group(2), m.group(3), name, thumb), "", ""))
    if host == "i.pinimg.com" and path.startswith("/originals/"):
        return urllib.parse.urlunsplit((u.scheme, u.netloc, "/736x/" + path[len("/originals/"):], u.query, ""))
    if host in ("images.unsplash.com", "images.pexels.com"):
        q = [(k, v) for k, v in urllib.parse.parse_qsl(u.query, keep_blank_values=True) if k not in ("w", "h", "fit", "dpr")]
        q += [("w", str(width)), ("fit", "max")] if host == "images.unsplash.com" else [("auto", "compress"), ("w", str(width))]
        q = list(dict(q).items())                    # Pexels' own auto= stays once
        return urllib.parse.urlunsplit((u.scheme, u.netloc, path, urllib.parse.urlencode(q), ""))
    return None


def image_cache_dir():
    return os.path.join(CFG["data_dir"], "image-cache")


def image_cache_get(key):
    path = os.path.join(image_cache_dir(), key)
    try:
        with open(path, "rb") as f:
            head = json.loads(f.readline())
            data = f.read()
        if head.get("expires", 0) < time.time() or len(data) != head.get("size"):
            raise ValueError("stale")
        os.utime(path)                               # LRU by modification time
        return head, data
    except (OSError, ValueError):
        return None


def image_cache_put(key, head, data):
    folder = image_cache_dir()
    os.makedirs(folder, mode=0o700, exist_ok=True)
    tmp = os.path.join(folder, key + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(json.dumps({**head, "size": len(data), "expires": time.time() + IMAGE_CACHE_S}).encode() + b"\n" + data)
    os.replace(tmp, os.path.join(folder, key))
    entries = []
    for name in os.listdir(folder):
        try:
            st = os.stat(os.path.join(folder, name))
            entries.append((st.st_mtime, st.st_size, name))
        except OSError:
            continue
    total = sum(e[1] for e in entries)
    for _, size, name in sorted(entries):
        if total <= IMAGE_CACHE_BYTES:
            break
        try:
            os.remove(os.path.join(folder, name))
            total -= size
        except OSError:
            pass


async def fetch_proxy_image(url, width):
    """(head, bytes) of one picture: its sized variant first (falling back to the URL itself), then a check that the
    bytes are a JPEG, PNG, GIF or WebP matching the declared type. Raises LinkBlocked with an error code."""
    global IMAGE_SEM
    IMAGE_SEM = IMAGE_SEM or asyncio.Semaphore(6)
    connector = aiohttp.TCPConnector(resolver=PublicResolver(), use_dns_cache=False, limit=4)
    timeout = aiohttp.ClientTimeout(total=LINK_REQUEST_S + 4, sock_connect=LINK_TIMEOUT_S, sock_read=LINK_TIMEOUT_S)
    accept = "image/webp,image/jpeg,image/png,image/gif;q=0.9,image/*;q=0.1"
    variant = image_variant_url(url, width)
    last = LinkBlocked("fetch_failed")
    host = (urllib.parse.urlsplit(url).hostname or "").lower()
    per_host = IMAGE_HOST_SEMS.setdefault(host, asyncio.Semaphore(2))
    if len(IMAGE_HOST_SEMS) > 256:
        IMAGE_HOST_SEMS.clear()
        IMAGE_HOST_SEMS[host] = per_host
    async with IMAGE_SEM, per_host:
        async with aiohttp.ClientSession(connector=connector, timeout=timeout, trust_env=False, max_field_size=16384) as s:
            for candidate in ([variant] if variant else []) + [url]:
                try:
                    try:
                        final, ctype, data, cut = await link_fetch(s, candidate, accept, 64 * 1024, image_limit=IMAGE_PROXY_MAX)
                    except LinkRateLimited as exc:     # one more try after a short, bounded wait
                        await asyncio.sleep(min(3.0, exc.retry_after or 1.5))
                        final, ctype, data, cut = await link_fetch(s, candidate, accept, 64 * 1024, image_limit=IMAGE_PROXY_MAX)
                except LinkBlocked as exc:
                    last = exc if isinstance(exc, LinkRateLimited) or not isinstance(last, LinkRateLimited) else last
                    if str(exc) == "blocked_url":
                        raise
                    continue
                except (aiohttp.ClientError, asyncio.TimeoutError, OSError, UnicodeError, ValueError):
                    last = LinkBlocked("fetch_failed")
                    continue
                if ctype not in LINK_IMAGE_TYPES:
                    last = LinkBlocked("unsupported_type")        # a page, SVG, AVIF, HEIC: the app shows its fallback
                    continue
                if cut:
                    last = LinkBlocked("too_large")
                    continue
                if not image_data_url(ctype, data[:32]):
                    last = LinkBlocked("unsupported_type")        # bytes that do not match the declared type
                    continue
                w, h = link_image_size(data)
                return {"type": ctype, "width": w, "height": h, "url": final}, data
    raise last


async def api_image(req):
    """GET /api/image?url=<http(s) image URL>&w=<px>: the picture's bytes, through the bridge (API.md "Image proxy")."""
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    if not CFG["link_preview"]:
        return jerr(503, "link_preview_disabled", message="link previews and images are turned off on this server")
    url = (req.query.get("url") or "").strip()
    try:
        check_link_url(url)
    except LinkBlocked as exc:
        return jerr(400, str(exc), message="only public http(s) images can be loaded")
    raw_w = req.query.get("w", "")
    if raw_w and not re.fullmatch(r"\d{1,5}", raw_w):
        return jerr(400, "bad_width", message="w must be a whole number of pixels")
    want = int(raw_w) if raw_w else 1280
    width = next((w for w in IMAGE_PROXY_WIDTHS if w >= want), IMAGE_PROXY_WIDTHS[-1])
    key = hashlib.sha256(("%s\n%d" % (url, width)).encode()).hexdigest()
    etag = '"%s"' % key[:32]
    if req.headers.get("If-None-Match") == etag and os.path.exists(os.path.join(image_cache_dir(), key)):
        return web.Response(status=304, headers={"ETag": etag, "Cache-Control": "private, max-age=%d" % IMAGE_CACHE_S})
    fail = IMAGE_FAILS.get(key)
    if fail and fail[0] > time.monotonic():
        return jerr(fail[1], fail[2], message="the image could not be loaded")
    hit = await asyncio.get_running_loop().run_in_executor(None, image_cache_get, key)
    if hit is None:
        fut = IMAGE_INFLIGHT.get(key)
        if fut is None:
            fut = IMAGE_INFLIGHT[key] = asyncio.ensure_future(asyncio.wait_for(fetch_proxy_image(url, width), LINK_TOTAL_S + 8))
            fut.add_done_callback(lambda _f: IMAGE_INFLIGHT.pop(key, None))
        try:
            head, data = await asyncio.shield(fut)
        except (LinkBlocked, asyncio.TimeoutError) as exc:
            code = str(exc) if isinstance(exc, LinkBlocked) and str(exc) else "fetch_failed"
            status = {"blocked_url": 400, "unsupported_type": 415, "too_large": 413}.get(code, 502)
            # A 429 passes quickly and a network failure may too; a wrong type or size stays wrong.
            ttl = 20 if isinstance(exc, LinkRateLimited) else 60 if code == "fetch_failed" else IMAGE_FAIL_S
            IMAGE_FAILS[key] = (time.monotonic() + ttl, status, code)
            while len(IMAGE_FAILS) > 512:
                IMAGE_FAILS.popitem(last=False)
            return jerr(status, code, message="the image could not be loaded")
        try:
            await asyncio.get_running_loop().run_in_executor(None, image_cache_put, key, head, data)
        except OSError as exc:
            log.info("image not cached: %s", type(exc).__name__)
    else:
        head, data = hit
    headers = {"Cache-Control": "private, max-age=%d" % IMAGE_CACHE_S, "ETag": etag, "X-Content-Type-Options": "nosniff",
               "Content-Security-Policy": "sandbox"}
    if head.get("width") and head.get("height"):
        headers.update({"X-Image-Width": str(head["width"]), "X-Image-Height": str(head["height"])})
    return web.Response(body=data, content_type=head["type"], headers=headers)


# ---- entity info (round 8): GET /api/entity/info?name=&hint=&wikipedia=&lang= -> a Wikipedia REST summary (title,
# description, extract, picture, page) for the entity sheet and the cards' pictures. No Hermes run, no model tokens.
# Fixed Wikipedia hosts only (never a URL from the request), the link fetcher's SSRF checks and redirect re-checks, a
# descriptive User-Agent as Wikimedia's policy asks (no browser imitation, no personal contact data), cached.
ENTITY_CACHE = collections.OrderedDict()             # key -> (expires, status, body)
ENTITY_CACHE_MAX, ENTITY_CACHE_S, ENTITY_FAIL_S = 512, 86400, 600
ENTITY_INFLIGHT = {}
WIKI_UA = "ToveBridge/1.0 (self-hosted chat app; entity summaries from the Wikipedia REST API)"
WIKI_LANG_RE = re.compile(r"^[a-z]{2,3}$")
ENTITY_EXTRACT_MAX = 1200


WIKI_IMAGE_HOSTS = {"upload.wikimedia.org", "thumb.wikimedia.org"}


def wiki_image(url):
    """A picture URL from a summary, kept only when it is an https Wikimedia upload or thumbnail; its tracking query
    (utm_*, added by the REST API since 2026) is dropped, so one picture has one cache key."""
    try:
        u = urllib.parse.urlsplit(url or "")
    except ValueError:
        return None
    if u.scheme != "https" or (u.hostname or "") not in WIKI_IMAGE_HOSTS or len(url) >= 2048:
        return None
    return urllib.parse.urlunsplit((u.scheme, u.netloc, u.path, "", ""))


async def wiki_json(s, url):
    try:
        _, ctype, body, cut = await link_fetch(s, url, "application/json", 512 * 1024, ua=WIKI_UA)
    except (aiohttp.ClientError, asyncio.TimeoutError, OSError, UnicodeError, ValueError):
        raise LinkBlocked("fetch_failed")
    if cut or "json" not in ctype:
        raise LinkBlocked("fetch_failed")
    try:
        return json.loads(body)
    except ValueError:
        raise LinkBlocked("fetch_failed")


async def wiki_summary(s, lang, title):
    """The REST summary of `title` (redirects followed), or None when there is no such page."""
    url = "https://%s.wikipedia.org/api/rest_v1/page/summary/%s" % (lang, urllib.parse.quote(title.strip().replace(" ", "_"), safe=""))
    try:
        data = await wiki_json(s, url)
    except LinkRateLimited:
        raise
    except LinkBlocked:
        return None
    return data if isinstance(data, dict) and data.get("title") else None


async def build_entity_info(name, hint, wikipedia, lang):
    """(status, body) for one entity: the page `wikipedia` names, else `name` as a title, else the best search hit for
    `name` + `hint` that is not a disambiguation page."""
    connector = aiohttp.TCPConnector(resolver=PublicResolver(), use_dns_cache=False, limit=4)
    timeout = aiohttp.ClientTimeout(total=LINK_TOTAL_S, sock_connect=LINK_TIMEOUT_S, sock_read=LINK_TIMEOUT_S)

    def usable(d):
        return d is not None and d.get("type") != "disambiguation"

    async with aiohttp.ClientSession(connector=connector, timeout=timeout, trust_env=False, max_field_size=16384) as s:
        data = await wiki_summary(s, lang, wikipedia) if wikipedia else None
        if not usable(data) and name:
            data = await wiki_summary(s, lang, name)
        if not usable(data) and name:
            q = (name + " " + hint).strip() if hint else name
            found = await wiki_json(s, "https://%s.wikipedia.org/w/rest.php/v1/search/page?q=%s&limit=3"
                                    % (lang, urllib.parse.quote(q[:200], safe="")))
            for page in (found.get("pages") or [])[:3] if isinstance(found, dict) else []:
                key = page.get("key") if isinstance(page, dict) else None
                if isinstance(key, str) and key:
                    data = await wiki_summary(s, lang, key)
                    if usable(data):
                        break
    if not usable(data):
        return 404, {"error": "not found", "code": "not_found", "message": "no Wikipedia page for this name"}
    extract = str(data.get("extract") or "").strip()
    if len(extract) > ENTITY_EXTRACT_MAX:
        cut = extract[:ENTITY_EXTRACT_MAX]
        extract = cut[:cut.rfind(". ") + 1] if ". " in cut else cut.rstrip() + "…"
    page = ((data.get("content_urls") or {}).get("desktop") or {}).get("page")
    if not (isinstance(page, str) and page.startswith("https://%s.wikipedia.org/" % lang)):
        page = "https://%s.wikipedia.org/wiki/%s" % (lang, urllib.parse.quote(str(data["title"]).replace(" ", "_")))
    image = wiki_image((data.get("thumbnail") or {}).get("source"))
    original = wiki_image((data.get("originalimage") or {}).get("source"))
    if not_a_photo(original or image) and not ORG_RE.search(str(data.get("description") or "")):
        photo = None                  # a landmark's summary picture can be its logo (Eiffel Tower, 18 Nov 2026)
        try:
            async with aiohttp.ClientSession(connector=aiohttp.TCPConnector(resolver=PublicResolver(), use_dns_cache=False, limit=4),
                                             timeout=timeout, trust_env=False, max_field_size=16384) as s:
                photo = article_photo(await wiki_json(s, "https://%s.wikipedia.org/api/rest_v1/page/media-list/%s" % (
                    lang, urllib.parse.quote(str(data["title"]).replace(" ", "_"), safe=""))))
        except (LinkBlocked, aiohttp.ClientError, asyncio.TimeoutError, OSError):
            pass
        if photo:
            image = original = photo
    return 200, {
        "name": name or data["title"], "title": data["title"], "description": data.get("description") or None,
        "extract": extract or None, "image": image, "original_image": original,
        "page": page, "source": "wikipedia", "lang": lang,
    }


ORG_RE = re.compile(r"\b(?:company|corporation|conglomerate|brand|organi[sz]ation|manufacturer|software|website|app|service|bank|"
                    r"airline|retailer|party|club|team|band|agency|university|logo|font|symbol|flag)\b", re.I)
NOT_PHOTO_RE = re.compile(r"(?:logo|icon|flag|map|locator|seal|coat_of_arms|signature|wordmark|diagram)", re.I)


def not_a_photo(url):
    """True for an SVG rendering or a logo-like file name: fine for a company, wrong for a place, person or animal."""
    name = urllib.parse.unquote((url or "").rsplit("/", 1)[-1])
    return bool(url) and (".svg" in name.lower() or bool(NOT_PHOTO_RE.search(name)))


def article_photo(media):
    """The article's own lead photo from a REST media-list (the infobox picture), else its first gallery photo."""
    items = [m for m in (media or {}).get("items") or [] if isinstance(m, dict) and m.get("type") == "image"]
    def url(m):
        srcs = [x for x in m.get("srcset") or [] if isinstance(x, dict) and isinstance(x.get("src"), str)]
        src = srcs[-1]["src"] if srcs else ""
        return wiki_image("https:" + src if src.startswith("//") else src)
    for m in sorted(items, key=lambda m: not m.get("leadImage")):
        u = url(m)
        if u and m.get("showInGallery", True) and not not_a_photo(u) and not NOT_PHOTO_RE.search(str(m.get("title") or "")):
            return u
    return None


async def api_entity_info(req):
    """GET /api/entity/info?name=&hint=&wikipedia=&lang=en (API.md "Entity info")."""
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    if not CFG["link_preview"]:
        return jerr(503, "link_preview_disabled", message="link previews and images are turned off on this server")
    q = req.query
    name, hint, wikipedia = (q.get("name") or "").strip(), (q.get("hint") or "").strip(), (q.get("wikipedia") or "").strip()
    lang = (q.get("lang") or "en").strip().lower()
    if not (name or wikipedia) or len(name) > 200 or len(hint) > 200 or len(wikipedia) > 300 or not WIKI_LANG_RE.match(lang) \
            or any(c in wikipedia for c in "#<>[]{}|"):
        return jerr(400, "bad_request", message="give name (and optional hint) or a wikipedia title")
    try:
        status, body = await entity_info_cached(name, hint, wikipedia, lang)
    except LinkRateLimited:
        return jerr(502, "fetch_failed", message="Wikipedia is busy; try again shortly")
    return web.json_response(body, status=status, headers={"Cache-Control": "private, max-age=3600"})


def _entity_key(name, hint, wikipedia, lang):
    return json.dumps([lang, wikipedia.lower(), name.lower(), hint.lower()])


def entity_cache_put(key, status, body):
    ENTITY_CACHE[key] = (time.monotonic() + (ENTITY_CACHE_S if status == 200 else ENTITY_FAIL_S), status, body)
    ENTITY_CACHE.move_to_end(key)
    while len(ENTITY_CACHE) > ENTITY_CACHE_MAX:
        ENTITY_CACHE.popitem(last=False)


async def entity_info_cached(name, hint="", wikipedia="", lang="en"):
    """(status, body) of GET /api/entity/info, from the cache or one shared lookup. Raises LinkRateLimited (not cached)."""
    key = _entity_key(name, hint, wikipedia, lang)
    hit = ENTITY_CACHE.get(key)
    if hit and hit[0] > time.monotonic():
        ENTITY_CACHE.move_to_end(key)
        return hit[1], hit[2]
    async def lookup():                      # caches its own answer, even when every waiter has gone
        try:
            status, body = await asyncio.wait_for(build_entity_info(name, hint, wikipedia, lang), LINK_TOTAL_S + 4)
        except (LinkBlocked, asyncio.TimeoutError, aiohttp.ClientError, OSError) as exc:
            if isinstance(exc, LinkRateLimited):
                raise
            status, body = 502, {"error": "fetch failed", "code": "fetch_failed", "message": "Wikipedia could not be reached"}
        entity_cache_put(key, status, body)
        return status, body

    fut = ENTITY_INFLIGHT.get(key)
    if fut is None:
        fut = ENTITY_INFLIGHT[key] = asyncio.ensure_future(lookup())
        fut.add_done_callback(lambda f: (ENTITY_INFLIGHT.pop(key, None), f.cancelled() or f.exception()))
    return await asyncio.shield(fut)


# ---- pictures for named things in replies (round 9; API.md "Entity pictures"). Hermes never searches for them: it
# names the subject as an image URL `entity:<English Wikipedia title>` (markdown image or hermes-html <img>) or lists it
# in an entities block, and the bridge fills in the article's lead picture once the text has streamed: one `snapshot`
# event with the finished text, before `done`. The lookups start the moment a reference streams in (and, for a "Who
# is X" / "Tell me about X" question, when the reply starts), so by the end they are usually cached. A reference that
# cannot be resolved in time is dropped (markdown and HTML) or left without a picture (entities: the app looks it up).
ENTITY_REF_MD_RE = re.compile(r"(\[)?!\[([^\]\n]{0,200})\]\(entity:((?:[^()\s]|\([^()\s]*\))+)\)(?(1)\]\((?:[^()\s]|\([^()\s]*\))*\))")
ENTITY_REF_HTML_RE = re.compile(r"""<img\b[^<>]*?\bsrc\s*=\s*(["'])entity:([^"'<>]+)\1[^<>]*>""", re.I)
UI_BLOCK_FENCE_RE = re.compile(r"(^|\n)([ \t]*)(`{3,})hermes-ui[ \t]*\n(.*?)\n[ \t]*\3[ \t]*(?=\n|$)", re.S)
OPENUI_FENCE_RE = re.compile(r"(^|\n)([ \t]*)(`{3,})openui[ \t]*\n(.*?)(?:\n[ \t]*\3[ \t]*(?=\n|$)|\Z)", re.S)
OPENUI_ENTITY_RE = re.compile(r'"entity:([^"\\\n]{1,200})"')
ENTITY_WAIT_S = 1.5                     # longest wait after the text for lookups still running
ENTITY_REFS_MAX = 12                    # lookups per reply
SUBJECT_RE = re.compile(r"^\s*(?:(?:can you |please )?tell me (?:a bit |more |all )?about|who (?:is|was)|what (?:is|was|are) (?:an? |the )?"
                        r"|describe|explain what (?:is )?(?:an? |the )?)\s*(?:the |an? )?(?P<s>[^?!.\n]{2,60}?)\s*[?!.]*\s*$", re.I)
SUBJECT_STOP = re.compile(r"\b(?:i|me|my|mine|you|your|yours|we|our|it|its|this|that|these|those|today|tomorrow|now|time|date|weather|news|"
                          r"latest|price|prices|difference|best|happening|going on|up|wrong|meaning of life|plan|plans)\b|\d", re.I)


OPENUI_STRING_RE = re.compile(r'"(?:\\.|[^"\\])*"?|\'(?:\\.|[^\'\\])*\'?')
OPENUI_STMT_RE = re.compile(r"^\s*(\$?[A-Za-z_]\w*)\s*=(?!=)", re.M)
OPENUI_CALL_RE = re.compile(r"(?<![@\w.$])([A-Z]\w*)\s*\(")
OPENUI_REF_RE = re.compile(r"(?<![@\w.$])([a-z_]\w*)\b(?!\s*=(?!=))")


# Components the app draws but the generated prompt leaves out to save tokens (app/lib/src/ui/openui/library.dart
# `_untaught` and the hidden base-library Stack): never "unknown" in the log.
OPENUI_UNTAUGHT = {"TextCallout", "Separator", "RadarChart", "RadialChart", "ScatterChart", "ScatterSeries", "Point", "Label",
                   "CheckBoxGroup", "CheckBoxItem", "SwitchGroup", "SwitchItem", "IconButton", "SnippetCardBlock",
                   "SnippetCardItem", "ContextCardBlock", "ContextCardItem", "MetricIndicatorWithStrikethrough", "Stack",
                   "Slice"}


def openui_components():
    """Component names the app draws: every `Name(` at a line start of both installed OpenUI prompts, plus the
    components the chat-library prompt leaves out."""
    found = set(re.findall(r"(?m)^([A-Z]\w*)\(", openui_prompt() + "\n" + openui_chat_prompt()))
    return found | OPENUI_UNTAUGHT if openui_chat_prompt() else found


def openui_issues(text):
    """Structural problems in each ```openui fence of a finished reply (the app recovers; this is for the log)."""
    known = openui_components() | {"Action"}
    issues = []
    for i, m in enumerate(OPENUI_FENCE_RE.finditer(text or "")):
        src, tag = m.group(4), "openui#%d" % (i + 1)
        if not re.search(r"\n[ \t]*%s[ \t]*(?:\n|$)" % re.escape(m.group(3)), m.group(0)):
            issues.append("%s: fence not closed" % tag)
        code = "\n".join(l for l in src.split("\n") if not re.match(r"\s*(//|#)", l))
        bare = OPENUI_STRING_RE.sub('""', code)
        defined = OPENUI_STMT_RE.findall(code)
        if "root" not in defined:
            issues.append("%s: no root statement" % tag)
        unknown = sorted({c for c in OPENUI_CALL_RE.findall(bare) if c not in known} - {"Query", "Mutation"})
        if unknown and known != {"Action"}:
            issues.append("%s: unknown components %s" % (tag, ", ".join(unknown[:8])))
        if re.search(r"(?<![\w@])(Query|Mutation)\s*\(", bare):
            issues.append("%s: Query/Mutation (no tools in the app)" % tag)
        depth = sum(bare.count(c) for c in "([{") - sum(bare.count(c) for c in ")]}")
        if depth:
            issues.append("%s: unbalanced brackets (%+d)" % (tag, depth))
        rhs = OPENUI_STMT_RE.sub("", bare)
        used = set(OPENUI_REF_RE.findall(rhs))
        orphans = [d for d in defined if d != "root" and not d.startswith("$") and d not in used]
        if orphans:
            issues.append("%s: unused statements %s" % (tag, ", ".join(orphans[:8])))
    return issues


def entity_title(ref):
    """`Eiffel_Tower` -> ("Eiffel Tower", "Eiffel_Tower"); percent escapes are decoded."""
    title = urllib.parse.unquote(ref).strip().strip("_")[:200]
    return title.replace("_", " ").strip(), title.replace(" ", "_")


def _norm_name(s):
    return re.sub(r"[^a-z0-9]+", " ", re.sub(r"\s*\([^)]*\)", "", s.lower())).strip()


def entity_picture(body):
    """The picture URL to show for an entity summary, or None."""
    if not isinstance(body, dict):
        return None
    return body.get("original_image") or body.get("image")


def question_subject(text):
    """The one named subject of a "Who is X?" / "Tell me about X" / "What is a X?" question, or None."""
    m = SUBJECT_RE.match((text or "").strip())
    s = m.group("s").strip(" '\"") if m else ""
    if not s or SUBJECT_STOP.search(s) or len(s.split()) > 6:
        return None
    return s


class ReplyPictures:
    """Entity pictures of one reply: lookups started while it streams, then one rewrite of the finished text."""

    def __init__(self, user_text=""):
        self.tasks = {}                       # key -> Task -> (status, body)
        self.subject = question_subject(user_text) if CFG["link_preview"] else None
        if self.subject:
            self._start(("q", self.subject), self.subject, "", "")

    def _start(self, key, name, hint, wikipedia):
        if key in self.tasks or len(self.tasks) >= ENTITY_REFS_MAX or not (name or wikipedia):
            return
        async def run():
            try:
                return await entity_info_cached(name[:200], hint[:200], wikipedia[:300])
            except LinkRateLimited:
                return 502, None
        self.tasks[key] = asyncio.ensure_future(run())

    def scan(self, text):
        """Start a lookup for every reference in `text` (the reply so far) not seen yet."""
        if not CFG["link_preview"] or ("entity:" not in text and "hermes-ui" not in text):
            return
        for m in ENTITY_REF_MD_RE.finditer(text):
            name, wiki = entity_title(m.group(3))
            self._start(("w", wiki.lower()), name, "", wiki)
        for m in ENTITY_REF_HTML_RE.finditer(text):
            name, wiki = entity_title(m.group(2))
            self._start(("w", wiki.lower()), name, "", wiki)
        for item in self._entity_items(text):
            name, hint, wiki = self._item_ref(item)
            self._start(("e", name.lower(), hint.lower(), wiki.lower()), name, hint, wiki)
        for m in OPENUI_FENCE_RE.finditer(text):
            for r in OPENUI_ENTITY_RE.finditer(m.group(4)):
                name, wiki = entity_title(r.group(1))
                self._start(("w", wiki.lower()), name, "", wiki)

    @staticmethod
    def _item_ref(item):
        name = str(item.get("name") or "").strip()
        wiki = item.get("wikipedia")
        wiki = entity_title(wiki)[1] if isinstance(wiki, str) and wiki.strip() else ""
        img = item.get("image")
        if not wiki and isinstance(img, str) and img.startswith("entity:"):
            wiki = entity_title(img[7:])[1]
        return name, str(item.get("sub") or "").strip(), wiki

    @staticmethod
    def _blocks(text):
        for m in UI_BLOCK_FENCE_RE.finditer(text):
            try:
                obj = json.loads(m.group(4))
            except ValueError:
                continue
            if isinstance(obj, dict):
                yield m, obj

    @classmethod
    def _entities_of(cls, obj):
        if obj.get("type") == "entities":
            yield obj
        for child in obj.get("children") or [] if obj.get("type") == "group" else []:
            if isinstance(child, dict) and child.get("type") == "entities":
                yield child

    @classmethod
    def _entity_items(cls, text):
        for _m, obj in cls._blocks(text):
            for ent in cls._entities_of(obj):
                for item in ent.get("items") or []:
                    if isinstance(item, dict) and not (isinstance(item.get("image"), str) and item["image"].startswith(("https://", "http://"))):
                        yield item

    def _result(self, key):
        t = self.tasks.get(key)
        if t is None or not t.done() or t.cancelled() or t.exception():
            return None
        status, body = t.result()
        return body if status == 200 and entity_picture(body) else None

    async def finish(self, text):
        """The finished text with pictures filled in (it may be unchanged), and the picture URLs it now shows."""
        self.scan(text)
        pending = [t for t in self.tasks.values() if not t.done()]
        if pending:
            await asyncio.wait(pending, timeout=ENTITY_WAIT_S)
        shown = []

        def md(m):
            name, wiki = entity_title(m.group(3))
            body = self._result(("w", wiki.lower()))
            if body is None:
                return ""
            shown.append(entity_picture(body))
            alt = (m.group(2) or body["title"]).replace("]", "")
            return "[![%s](%s)](%s)" % (alt, entity_picture(body), body["page"])

        def tag(m):
            name, wiki = entity_title(m.group(2))
            body = self._result(("w", wiki.lower()))
            if body is None:
                return ""
            shown.append(entity_picture(body))
            q = m.group(1)
            return m.group(0).replace("%sentity:%s%s" % (q, m.group(2), q), '"%s"' % html.escape(entity_picture(body), quote=True), 1)

        out = ENTITY_REF_HTML_RE.sub(tag, ENTITY_REF_MD_RE.sub(md, text))
        out = self._fill_blocks(out, shown)
        out = self._fill_openui(out, shown)
        out = self._subject_picture(out, shown)
        out = re.sub(r"\n{3,}", "\n\n", out) if out != text else out
        return out, shown

    def _fill_blocks(self, text, shown):
        parts, last = [], 0
        for m, obj in list(self._blocks(text)):
            changed = False
            for ent in self._entities_of(obj):
                for item in ent.get("items") or []:
                    if not isinstance(item, dict):
                        continue
                    img = item.get("image")
                    if isinstance(img, str) and img.startswith(("https://", "http://")):
                        continue
                    name, hint, wiki = self._item_ref(item)
                    item.pop("wikipedia", None)
                    if "image" in item:
                        item.pop("image")
                        changed = True
                    body = self._result(("e", name.lower(), hint.lower(), wiki.lower()))
                    if body is None:
                        changed = changed or bool(wiki)
                        continue
                    item["image"] = entity_picture(body)
                    item.setdefault("page", body["page"])
                    shown.append(item["image"])
                    changed = True
                    # The app's details sheet asks by name and sub: give it the same page.
                    entity_cache_put(_entity_key(name, hint, "", "en"), 200, {**body, "name": name})
            if changed:
                parts += [text[last:m.start(4)], json.dumps(obj, ensure_ascii=False, separators=(",", ":"))]
                last = m.end(4)
        return "".join(parts) + text[last:] if parts else text

    def _fill_openui(self, text, shown):
        """`"entity:Title"` strings in ```openui fences become the picture URL, or null when it is not known."""
        def body(m):
            def one(r):
                found = self._result(("w", entity_title(r.group(1))[1].lower()))
                if found is None:
                    return "null"
                shown.append(entity_picture(found))
                return json.dumps(entity_picture(found))
            return m.group(0)[:m.start(4) - m.start(0)] + OPENUI_ENTITY_RE.sub(one, m.group(4)) + m.group(0)[m.end(4) - m.start(0):]
        return OPENUI_FENCE_RE.sub(body, text) if "openui" in text and "entity:" in text else text

    def _subject_picture(self, text, shown):
        """A "Who is X?" answer with no picture at all gets X's: after its first paragraph, like a hero image."""
        if not self.subject or shown or "](http" in text and "![" in text or "<img" in text or "hermes-artifact" in text \
                or "```openui" in text and re.search(r"\b(?:Email|Artifact)\(", text):
            return text
        if any(o.get("type") == "entities" for _m, obj in self._blocks(text) for o in self._entities_of(obj)):
            return text
        body = self._result(("q", self.subject))
        if body is None:
            return text
        want, got = _norm_name(self.subject), _norm_name(body.get("title") or "")
        if not want or not (want == got or want in got.split(" ") or got.startswith(want) or want.startswith(got)):
            return text
        if want not in _norm_name(text):
            return text                      # the reply is not about it (a refusal, a question back)
        cut = text.find("\n\n")
        if cut < 0 or text[:cut].lstrip().startswith(("#", "```", "|", "- ", "1. ")):
            return text
        shown.append(entity_picture(body))
        return "%s\n\n[![%s](%s)](%s)%s" % (text[:cut], body["title"].replace("]", ""), entity_picture(body), body["page"], text[cut:])


async def warm_image(url, width=1280):
    """Fetch one picture into the /api/image cache at the width the app asks for, so its first load is a cache hit."""
    try:
        check_link_url(url)
        key = hashlib.sha256(("%s\n%d" % (url, width)).encode()).hexdigest()
        if os.path.exists(os.path.join(image_cache_dir(), key)) or key in IMAGE_INFLIGHT:
            return
        fut = IMAGE_INFLIGHT[key] = asyncio.ensure_future(asyncio.wait_for(fetch_proxy_image(url, width), LINK_TOTAL_S + 8))
        fut.add_done_callback(lambda _f: IMAGE_INFLIGHT.pop(key, None))
        head, data = await asyncio.shield(fut)
        await asyncio.get_running_loop().run_in_executor(None, image_cache_put, key, head, data)
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        log.info("picture not prefetched: %s", type(exc).__name__)


FAVICON_HOST_RE = re.compile(r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,62}$")


async def build_favicon(host, origin=None):
    """A site's icon for source chips (API.md "Favicons"): /favicon.ico, else the first two <link rel="icon"> of its
    home page. Same fetcher, limits and SSRF checks as link previews; never an og:image. `origin` is for tests."""
    origin = origin or "https://" + host
    connector = aiohttp.TCPConnector(resolver=PublicResolver(), use_dns_cache=False, limit=4)
    timeout = aiohttp.ClientTimeout(total=LINK_REQUEST_S, sock_connect=LINK_TIMEOUT_S, sock_read=LINK_TIMEOUT_S)
    result = {"host": host, "url": None, "favicon": None, "width": None, "height": None}

    async def take(s, url):
        try:
            final, itype, data, cut = await link_fetch(s, url, "image/*", LINK_ICON_MAX)
        except (LinkBlocked, aiohttp.ClientError, asyncio.TimeoutError, OSError):
            return False
        icon = image_data_url(itype, data) if itype in LINK_ICON_TYPES and not cut else None
        if icon:
            w, h = link_image_size(data) if itype in LINK_IMAGE_TYPES else (None, None)
            result.update(url=final, favicon=icon, width=w, height=h)
        return bool(icon)

    async with aiohttp.ClientSession(connector=connector, timeout=timeout, trust_env=False, max_field_size=16384) as s:
        if await take(s, origin + "/favicon.ico"):
            return result
        try:
            final, ctype, body, _ = await link_fetch(s, origin + "/", "text/html,application/xhtml+xml", LINK_HTML_MAX)
        except (LinkBlocked, aiohttp.ClientError, asyncio.TimeoutError, OSError):
            return result
        if ctype in ("text/html", "application/xhtml+xml"):
            p = OGParser()
            try:
                p.feed(body.decode("utf-8", "replace"))
            except Exception:
                pass
            for icon in p.icons[:2]:
                if await take(s, urllib.parse.urljoin(final, icon)):
                    break
    return result


async def api_favicon(req):
    """GET /api/favicon?host=example.com → {host, url, favicon (data: URL or null), width, height}; cached per host."""
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    if not CFG["link_preview"]:
        return jerr(503, "link_preview_disabled", message="link previews are turned off on this server")
    host = (req.query.get("host") or "").strip().rstrip(".").lower()
    host = host[4:] if host.startswith("www.") else host
    try:
        if not FAVICON_HOST_RE.match(host):
            raise LinkBlocked("bad_host")
        check_link_url("https://%s/" % host)
    except LinkBlocked as exc:
        code = "bad_host" if str(exc) == "bad_url" else str(exc)
        return jerr(400, code, message="host must be a public domain name such as example.com")
    key, now = "favicon:" + host, time.monotonic()
    hit = LINK_CACHE.get(key)
    if hit and hit[0] > now:
        LINK_CACHE.move_to_end(key)
        return web.json_response(hit[1][1], headers={"Cache-Control": "private, max-age=%d" % max(1, hit[0] - now)})
    try:
        body = await asyncio.wait_for(build_favicon(host), LINK_TOTAL_S)
    except (asyncio.TimeoutError, aiohttp.ClientError, OSError, UnicodeError, ValueError):
        body = {"host": host, "url": None, "favicon": None, "width": None, "height": None}
    keep = LINK_CACHE_S if body["favicon"] else LINK_FAIL_CACHE_S
    link_cache_put(key, now + keep, 200, body)
    return web.json_response(body, headers={"Cache-Control": "private, max-age=%d" % keep})


def link_cache_put(url, expires, status, body):
    """Store a preview; the oldest entries go once there are too many or their images take too much memory."""
    size = sum(len(v) for v in body.values() if isinstance(v, str))
    LINK_CACHE.pop(url, None)
    LINK_CACHE[url] = (expires, (status, body), size)
    total = sum(entry[2] for entry in LINK_CACHE.values())
    while LINK_CACHE and (len(LINK_CACHE) > LINK_CACHE_MAX or total > LINK_CACHE_BYTES):
        _, old = LINK_CACHE.popitem(last=False)
        total -= old[2]


# ---- web search, UI prompt
WEB_SEARCH_NOTE = ("[The user switched on web search for this message. Use your web search tool to look this up "
                   "(do not answer from memory alone), and name your sources.]")
TOOLSETS = {"web": None, "checked": 0.0}


async def hermes_has_web_search():
    """Whether Hermes' API agent has its web toolset enabled (GET /v1/toolsets), cached for 10 minutes."""
    if CFG["web_search"] in ("true", "1", "yes", "on"):
        return True
    if CFG["web_search"] not in ("auto",) or not CFG["hermes_key"]:
        return False
    if time.monotonic() - TOOLSETS["checked"] < 600 and TOOLSETS["web"] is not None:
        return TOOLSETS["web"]
    found = False
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=5)) as s:
            async with s.get(CFG["hermes_url"].rstrip("/") + "/toolsets", headers={"Authorization": "Bearer " + CFG["hermes_key"]}) as r:
                data = await r.json(content_type=None) if r.status == 200 else {}
        items = data.get("data") if isinstance(data, dict) else None
        found = any(isinstance(t, dict) and t.get("enabled") and t.get("configured", True)
                    and "web_search" in (t.get("tools") or []) for t in items or [])
    except Exception as exc:
        log.info("toolset check failed: %s", type(exc).__name__)
        if TOOLSETS["web"] is not None:
            return TOOLSETS["web"]                         # keep the last answer through a short Hermes outage
    TOOLSETS.update(web=found, checked=time.monotonic())
    return found


UI_PROMPT = {"key": None, "text": ""}
OPENUI_PROMPT = {"key": None, "text": ""}
UI_HEADER = "X-Hermes-UI"
UI_BLOCKS_VERSION = 1                     # the hermes-ui version the shipped prompt describes
UI_PROMPT_VERSION_MAX = 2                 # 2 = markdown + OpenUI chat library only (API.md "UI prompt versions")
UI_PROMPT_BUNDLED = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hermes-ui-prompt.md")
OPENUI_PROMPT_BUNDLED = os.path.join(os.path.dirname(os.path.abspath(__file__)), "openui-prompt.md")


def _prompt_path(chosen, default, bundled):
    if chosen.lower() in ("off", "none", "false", "0"):
        return None
    if chosen:
        return chosen
    return next((p for p in (default, bundled) if os.path.isfile(p)), None)


def ui_prompt_path():
    return _prompt_path(CFG["ui_prompt_file"], CFG["ui_prompt_default"], UI_PROMPT_BUNDLED)


def _read_prompt(cache, path, limit):
    """The file's text, re-read when its mtime or size changes (hot reload); "" when missing."""
    try:
        st = os.stat(path) if path else None
    except OSError:
        st = None
    if st is None:
        return ""
    key = (path, st.st_mtime, st.st_size)
    if cache["key"] != key:
        try:
            cache.update(key=key, text=Path(path).read_text("utf-8").strip()[:limit])
        except (OSError, UnicodeDecodeError):
            return ""
    return cache["text"]


def openui_prompt():
    """The OpenUI section (generated from the app's component registry), or ""."""
    path = _prompt_path(CFG["openui_prompt_file"], CFG["openui_prompt_default"], OPENUI_PROMPT_BUNDLED)
    return _read_prompt(OPENUI_PROMPT, path, 16000)


MARKDOWN_PROMPT = {"key": None, "text": ""}
OPENUI_CHAT_PROMPT = {"key": None, "text": ""}
MARKDOWN_PROMPT_BUNDLED = os.path.join(os.path.dirname(os.path.abspath(__file__)), "markdown-prompt.md")
OPENUI_CHAT_PROMPT_BUNDLED = os.path.join(os.path.dirname(os.path.abspath(__file__)), "openui-chat-prompt.md")


def openui_chat_prompt():
    """The OpenUI chat-library section for "ui": 2 clients (generated from the app's registry), or ""."""
    path = _prompt_path(CFG["openui_chat_prompt_file"], CFG["openui_chat_prompt_default"], OPENUI_CHAT_PROMPT_BUNDLED)
    return _read_prompt(OPENUI_CHAT_PROMPT, path, 16000)


def ui_prompt(version=1):
    """The Hermes-app system prompt snippet, or "" when none is installed. Version 1 (Tove up to round 9, and any
    client that sends "ui": 1): hermes-ui blocks and markdown rules, then the first OpenUI section. Version 2 and
    up: markdown rules, then OpenUI's chat library as the only rich format; falls back to version 1 when its files
    are missing."""
    if version >= 2:
        path = _prompt_path(CFG["markdown_prompt_file"], CFG["markdown_prompt_default"], MARKDOWN_PROMPT_BUNDLED)
        base, extra = _read_prompt(MARKDOWN_PROMPT, path, 16000), openui_chat_prompt()
        if base and extra:
            return base + "\n\n" + extra
    base = _read_prompt(UI_PROMPT, ui_prompt_path(), 16000)
    if not base:
        return ""
    extra = openui_prompt()
    return base + "\n\n" + extra if extra else base


def ui_version(req, body):
    """The UI version a client renders: "ui": <n> in the body, else 1 for the X-Hermes-UI header, else 0."""
    v = body.get("ui") if isinstance(body, dict) else None
    if isinstance(v, int) and not isinstance(v, bool) and v >= 1:
        return min(v, UI_PROMPT_VERSION_MAX)
    return 1 if req.headers.get(UI_HEADER) else 0


def wants_ui(req, body):
    """The Hermes app asks for its prompt with "ui": <version> in the /api/chat body (or the X-Hermes-UI header)."""
    return ui_version(req, body) >= 1


def add_note(m, note):
    if isinstance(m["content"], list):
        m["content"][0]["text"] = (m["content"][0]["text"] + "\n\n" + note).strip()
    else:
        m["content"] = (m["content"] + "\n\n" + note).strip()


# --- synced account settings (API.md "Settings")
SETTINGS_MAX_BYTES = 32 * 1024
SETTINGS_TEXT_CHARS = 1500                  # custom_instructions and about_you, like ChatGPT's custom instructions
SETTINGS_STYLES = ("default", "concise", "detailed", "friendly", "professional")
SETTINGS_KEY_RE = re.compile(r"^[a-z][a-z0-9_]{0,31}\.[A-Za-z0-9_.-]{1,64}$")     # pass-through keys: "<namespace>.<name>"


def _s_enum(*values):
    return lambda v: v in values, "one of " + ", ".join(values)


def _s_str(limit, pattern=None):
    rx = re.compile(pattern) if pattern else None
    return (lambda v: isinstance(v, str) and len(v) <= limit and (rx is None or bool(rx.fullmatch(v))),
            "a string of at most %d characters" % limit)


_S_BOOL = (lambda v: isinstance(v, bool), "true or false")
SETTINGS_SCHEMA = {
    "theme": _s_enum("system", "light", "dark"),
    "voice": _s_str(40, r"[A-Za-z0-9_-]*"),
    "read_aloud": _S_BOOL,
    "read_aloud_auto": _S_BOOL,
    "effort_default": _s_enum(*EFFORTS),
    "web_search_default": _S_BOOL,
    "language": _s_str(35, r"[A-Za-z0-9-]*"),
    "custom_instructions": _s_str(SETTINGS_TEXT_CHARS),
    "about_you": _s_str(SETTINGS_TEXT_CHARS),
    "notifications": {"replies": _S_BOOL, "tasks": _S_BOOL, "previews": _S_BOOL},
    "personalization": {"nickname": _s_str(60), "occupation": _s_str(100), "style": _s_enum(*SETTINGS_STYLES)},
}


def validate_settings(data):
    """(clean settings, None) or (None, (key, what it must be)). Known keys are checked (null removes a key); unknown
    keys must be namespaced ("app.sidebar") and are kept as they are; anything else is refused."""
    if not isinstance(data, dict):
        return None, ("settings", "an object")
    out = {}
    for key, value in data.items():
        rule = SETTINGS_SCHEMA.get(key)
        if value is None:
            continue
        if rule is None:
            if not SETTINGS_KEY_RE.match(str(key)):
                return None, (key, "a known setting or a namespaced key like \"app.%s\"" % re.sub(r"\W", "_", str(key))[:20])
            out[key] = value
        elif isinstance(rule, dict):
            if not isinstance(value, dict):
                return None, (key, "an object")
            inner = {}
            for k, v in value.items():
                if v is None:
                    continue
                if k not in rule:
                    return None, ("%s.%s" % (key, k), "one of " + ", ".join(rule))
                if not rule[k][0](v):
                    return None, ("%s.%s" % (key, k), rule[k][1])
                inner[k] = v
            if inner:
                out[key] = inner
        elif not rule[0](value):
            return None, (key, rule[1])
        else:
            out[key] = value
    return out, None


def settings_prompt(settings):
    """The user's custom instructions as a short addition to Hermes' system prompt on /api/chat, or ""."""
    s = settings if isinstance(settings, dict) else {}
    p = s.get("personalization") if isinstance(s.get("personalization"), dict) else {}
    one = lambda v: " ".join(str(v).split())                    # noqa: E731 (keeps the prompt to one line per item)
    lines = []
    if p.get("nickname"):
        lines.append("Call the user %s." % one(p["nickname"]))
    prof = s.get("app.profile") if isinstance(s.get("app.profile"), dict) else {}
    name = one(prof.get("name") or "")[:60] if isinstance(prof.get("name"), str) else ""
    if name:                                                    # round 8: drafts are signed, never "[Your Name]"
        lines.append("Their name is %s; sign emails, letters and messages you draft for them with it." % name)
    if p.get("occupation"):
        lines.append("Their occupation: %s. Fit examples, suggestions and explanations to it." % one(p["occupation"]).rstrip("."))
    if s.get("about_you", "").strip():
        lines.append("About them: " + one(s["about_you"]))
    style = {"concise": "Keep replies short.", "detailed": "Give thorough, detailed replies.", "friendly": "Use a warm, friendly tone.",
             "professional": "Use a neutral, professional tone."}.get(p.get("style"))
    if style:
        lines.append(style)
    if s.get("custom_instructions", "").strip():
        lines.append("How they want replies: " + one(s["custom_instructions"]))
    if not lines:
        return ""
    # Round 6 C1: an occupation set here lost to older notes in Hermes' memory, so these are marked as current.
    return ("The user's own current settings from the app. They are up to date and take precedence over anything "
            "remembered about the user; follow them unless a request says otherwise:\n") + \
        "\n".join("- " + x for x in lines)


def _settings_etag(version):
    return '"s%d"' % version


def _settings_body(state):
    return web.json_response(state, headers={"ETag": _settings_etag(state["version"]), "Cache-Control": "no-store"})


async def api_settings_get(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    state = store.get_settings()
    if req.headers.get("If-None-Match", "").strip() == _settings_etag(state["version"]):
        return web.Response(status=304, headers={"ETag": _settings_etag(state["version"])})
    return _settings_body(state)


async def api_settings_put(req):
    """PUT /api/settings {"version": n, "settings": {...}}: replaces the whole object when n (or If-Match) is the
    current version (0 before the first save). A stale version gives 409 with the current settings to merge with."""
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    body, bad = await read_json(req)
    if bad:
        return bad
    version = body.get("version")
    match = re.fullmatch(r'(?:W/)?"?s?(\d{1,9})"?', req.headers.get("If-Match", "").strip())
    if version is None and match:
        version = int(match.group(1))
    if not isinstance(version, int) or isinstance(version, bool) or version < 0:
        return jerr(428, "version_required", message='send the version you last read ("version" or If-Match); 0 for the first save')
    clean, problem = validate_settings(body.get("settings"))
    if problem:
        return jerr(400, "bad_setting", message="%s must be %s" % problem, key=problem[0])
    if len(json.dumps(clean, ensure_ascii=False, separators=(",", ":")).encode()) > SETTINGS_MAX_BYTES:
        return jerr(413, "settings_too_large", message="settings are larger than %d bytes" % SETTINGS_MAX_BYTES)
    ok, state = store.put_settings(clean, version)
    if not ok:
        return jerr(409, "version_conflict", message="the settings changed on another device; merge and send again", current=state,
                    headers={"ETag": _settings_etag(state["version"])})
    return _settings_body(state)


# --- starter suggestions (API.md "Suggestions"): a curated pool, rotated on the server, no model call
SUGGESTIONS = [
    # (category, title, prompt, tags)
    ("homelab", "Check on my servers", "How are my servers doing right now? Flag anything that needs my attention.", "server servers health status uptime"),
    ("homelab", "Disk space report", "How much disk space is left on each of my servers, and is anything filling up fast?", "disk storage space drive"),
    ("homelab", "Review my backups", "Did my backups run as planned recently? Tell me if anything failed or looks stale.", "backup backups restore"),
    ("homelab", "What's using memory?", "Which services use the most memory and CPU on my servers right now?", "memory cpu docker container service"),
    ("homelab", "Explain a log error", "I'll paste an error from my logs. Explain what it means and how to fix it.", "log logs error failed service"),
    ("homelab", "Plan a homelab upgrade", "Suggest a sensible next upgrade for my homelab and what it would improve.", "homelab upgrade hardware server"),
    ("homelab", "Harden SSH access", "Walk me through hardening SSH on a Linux server, step by step.", "ssh security linux server"),
    ("homelab", "Update my containers", "Which of my Docker containers have updates waiting, and is any of them risky to update?", "docker container update image"),
    ("media", "Movie for tonight", "Suggest a movie for tonight from my media library, with a one-line reason for each pick.", "movie movies jellyfin film watch"),
    ("media", "Series to start", "Recommend three TV series I might like, with why each one is worth starting.", "series show tv watch"),
    ("writing", "Draft a follow-up email", "Help me write a short, polite follow-up email to someone who hasn't replied.", "email mail write reply"),
    ("writing", "Tighten my writing", "I'll paste a paragraph. Make it clearer and shorter without losing the meaning.", "write writing edit text"),
    ("writing", "Write a short bio", "Help me write a short, friendly bio I can use on my profiles.", "bio profile about"),
    ("writing", "Reply to a tricky message", "Help me reply to a message diplomatically. I'll paste it next.", "message reply chat"),
    ("learning", "Explain a concept simply", "Explain how DNS works as if I'm new to it, with one everyday analogy.", "dns network learn explain"),
    ("learning", "Teach me a Linux command", "Teach me one useful Linux command I probably don't know, with a practical example.", "linux command shell terminal bash"),
    ("learning", "Quiz me", "Quiz me with five quick questions on networking basics, one at a time.", "quiz network learn"),
    ("learning", "Summarise a topic", "Give me a five-minute overview of how solar panels work and what affects their output.", "solar energy power learn"),
    ("planning", "Plan my week", "Help me plan this week: ask me what's on my plate, then lay out a realistic schedule.", "plan week schedule calendar"),
    ("planning", "Break down a big goal", "Help me break a big goal into small steps I can start today.", "goal plan steps habit"),
    ("planning", "Weekend trip checklist", "Make a packing checklist for a two-day trip.", "trip travel packing"),
    ("planning", "Make a decision", "Help me decide between two options. Ask me about them, then weigh the trade-offs.", "decide decision choice option"),
    ("code", "Write a script", "Write a Bash script that backs up a folder to another disk and keeps the last seven copies.", "script bash backup code"),
    ("code", "Review my code", "I'll paste a function. Review it for bugs, readability and edge cases.", "code review python bug"),
    ("code", "Build a regex", "Help me write a regular expression. I'll describe what it should match.", "regex code pattern"),
    ("code", "Explain this error", "I'll paste a stack trace. Explain what went wrong and how to fix it.", "error code python stack trace bug"),
    ("food", "Dinner from my fridge", "Suggest three quick dinners from what's in my fridge. Ask me what I have first.", "dinner food recipe cook"),
    ("food", "Meal prep for the week", "Plan a simple, healthy meal prep for five weekday lunches, with a shopping list.", "meal food lunch prep shopping"),
    ("health", "Quick home workout", "Give me a 20-minute workout I can do at home with no equipment.", "workout exercise fitness health"),
    ("health", "Better sleep", "Give me five practical, evidence-based tips to sleep better.", "sleep health rest"),
    ("ideas", "Side project ideas", "Suggest five side projects I could build and host on my own servers.", "project idea homelab build"),
    ("ideas", "Small business ideas", "Brainstorm small business ideas that I could start with little money, with the first step for each.", "business idea money startup"),
    ("ideas", "Gift ideas", "Help me find a thoughtful gift. Ask me a few questions about the person first.", "gift present birthday"),
    ("fun", "Tell me something surprising", "Tell me three surprising facts I probably haven't heard, each in one sentence.", "fact fun trivia"),
    ("fun", "Play 20 questions", "Let's play 20 questions. You think of something and I'll guess.", "game play fun"),
    ("fun", "Write a short poem", "Write a short, light-hearted poem about servers humming at night.", "poem poetry fun server"),
    ("productivity", "Turn notes into tasks", "I'll paste some messy notes. Turn them into a clear to-do list.", "notes todo tasks list"),
    ("productivity", "Summarise an article", "I'll share a link. Summarise the article in five bullet points.", "article summary read link"),
]
SUGGEST = {"order": [], "pos": 0}
SUGGEST_MAX = 8
_SUGGEST_STOP = set("the a an and or to of for in on my me i is it how what new chat with your you can".split())


def pick_suggestions(n, recent_titles=(), rng=None):
    """n starters with distinct categories, taken in turn from a shuffled cycle of the pool (each call moves on, so a
    new chat sees fresh ones). One slot may go to a starter that shares a word with a recent chat title; titles never
    leave this function."""
    rng = rng or secrets.SystemRandom()
    words = {w for t in recent_titles for w in re.findall(r"[a-z]+", str(t).lower()) if w not in _SUGGEST_STOP and len(w) > 2}
    picked, cats = [], set()
    related = [i for i, s in enumerate(SUGGESTIONS) if words & set(s[3].split())]
    if related:
        i = rng.choice(related)
        picked.append(i); cats.add(SUGGESTIONS[i][0])
    tries = 0
    while len(picked) < n and tries < 3 * len(SUGGESTIONS):
        if SUGGEST["pos"] >= len(SUGGEST["order"]):
            SUGGEST["order"] = list(range(len(SUGGESTIONS)))
            rng.shuffle(SUGGEST["order"])
            SUGGEST["pos"] = 0
        i = SUGGEST["order"][SUGGEST["pos"]]
        SUGGEST["pos"] += 1
        tries += 1
        if i not in picked and (SUGGESTIONS[i][0] not in cats or tries > 2 * len(SUGGESTIONS)):
            picked.append(i); cats.add(SUGGESTIONS[i][0])
    out = [{"id": "s%d" % i, "title": SUGGESTIONS[i][1], "prompt": SUGGESTIONS[i][2], "category": SUGGESTIONS[i][0]} for i in picked]
    return out, bool(related)


# ---- usage limits (round 6 C7): GET /api/usage/limits. The subscription quota of every account the
# assistant runs on: CLIProxyAPI's accounts (Codex/ChatGPT, Claude, Antigravity; asked live through its management API, which
# adds each account's own token on the server side) and the bridge's own ChatGPT login (GPT-Live). Tokens never leave
# the bridge and account names are masked.
LIMITS_CACHE = {"at": 0.0, "body": None, "lock": None}
LIMITS_CACHE_S, LIMITS_MIN_REFRESH_S, LIMITS_TIMEOUT_S = 60, 15, 15
CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
ANTIGRAVITY_QUOTA_URL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
CODEX_UA = "codex-tui/0.149.1"
PROVIDER_NAMES = {"codex": "ChatGPT · Codex", "claude": "Claude", "antigravity": "Antigravity", "gemini-cli": "Gemini CLI"}
CLAUDE_SCOPED = {"seven_day_opus": "Opus", "seven_day_sonnet": "Sonnet", "seven_day_oauth_apps": "OAuth apps",
                 "seven_day_cowork": "Cowork"}


def mask_account(text):
    """"t•••@g•••.com" for an email, "ab•••" for anything else; never the whole name."""
    text = str(text or "").strip()
    if not text:
        return None
    if "@" in text:
        user, _, domain = text.partition("@")
        head, dot, tld = domain.rpartition(".")
        return "%s•••@%s•••%s" % (user[:1], (head or domain)[:1], (dot + tld) if head else "")
    return text[:2] + "•••"


def account_id(*parts):
    return hashlib.sha256("\n".join(str(p) for p in parts).encode()).hexdigest()[:12]


def limit_window(wid, label, used=None, remaining=None, resets_at=None, window_s=None, scope=None):
    """One quota window. Percentages are 0–100 (rounded to 0.1); `resets_at` is Unix ms or null."""
    if used is None and remaining is None:
        return None
    used = max(0.0, min(100.0, float(used if used is not None else 100 - remaining)))
    return {"id": wid, "label": label, "used_percent": round(used, 1), "remaining_percent": round(100 - used, 1),
            "resets_at": resets_at, "window_s": window_s, "scope": scope}


def window_id(label):
    """"5h", "weekly", "30d", …: a stable id from a window label."""
    return {"5-hour": "5h", "Weekly": "weekly", "Daily": "daily"}.get(label) or label.lower().replace("-hour", "h").replace("-day", "d")


def window_label(seconds):
    if not seconds:
        return "Limit"
    if abs(seconds - 18000) < 600:
        return "5-hour"
    if abs(seconds - 604800) < 3600:
        return "Weekly"
    hours = seconds / 3600
    return "%d-hour" % round(hours) if hours < 48 else "%d-day" % round(hours / 24)


def _epoch_ms(v):
    """Unix seconds or ms (number or digit string), or an ISO 8601 time, as Unix ms."""
    if v is None or v == "":
        return None
    try:
        n = float(v)
        return int(n * 1000) if n < 1e11 else int(n)
    except (TypeError, ValueError):
        pass
    try:
        return int(datetime.datetime.fromisoformat(str(v).replace("Z", "+00:00")).timestamp() * 1000)
    except ValueError:
        return None


def _num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def codex_limits(body):
    """wham/usage → (plan, windows, credits, limit_reached)."""
    rl = body.get("rate_limit") if isinstance(body.get("rate_limit"), dict) else {}
    windows = []
    for key, wid in (("primary_window", None), ("secondary_window", None)):
        w = rl.get(key)
        if isinstance(w, dict):
            secs = w.get("limit_window_seconds")
            label = window_label(secs)
            windows.append(limit_window(window_id(label), label, used=_num(w.get("used_percent")),
                                        resets_at=_epoch_ms(w.get("reset_at")), window_s=secs))
    for extra in body.get("additional_rate_limits") or []:          # per-feature limits, when the plan has any
        if isinstance(extra, dict) and isinstance(extra.get("rate_limit"), dict):
            name = str(extra.get("limit_name") or extra.get("metered_feature") or "Extra")[:40]
            for key in ("primary_window", "secondary_window"):
                w = extra["rate_limit"].get(key)
                if isinstance(w, dict):
                    secs = w.get("limit_window_seconds")
                    windows.append(limit_window("%s-%s" % (name, key), window_label(secs), used=_num(w.get("used_percent")),
                                                resets_at=_epoch_ms(w.get("reset_at")), window_s=secs, scope=name))
    c = body.get("credits") if isinstance(body.get("credits"), dict) else None
    credits = {"balance": _num(c.get("balance")), "unlimited": bool(c.get("unlimited")), "has_credits": bool(c.get("has_credits")),
               "currency": None} if c else None
    return body.get("plan_type"), [w for w in windows if w], credits, bool(rl.get("limit_reached"))


def claude_limits(body):
    windows = []
    for key, wid, label, scope in [("five_hour", "5h", "5-hour", None), ("seven_day", "weekly", "Weekly", None)] + \
            [(k, "weekly-" + k[len("seven_day_"):], "Weekly", v) for k, v in CLAUDE_SCOPED.items()]:
        w = body.get(key)
        if isinstance(w, dict) and _num(w.get("utilization")) is not None:
            windows.append(limit_window(wid, label, used=_num(w["utilization"]), resets_at=_epoch_ms(w.get("resets_at")),
                                        window_s=18000 if wid == "5h" else 604800, scope=scope))
    extra = body.get("extra_usage") if isinstance(body.get("extra_usage"), dict) else {}
    credits = None
    if extra.get("is_enabled"):
        credits = {"balance": None, "unlimited": False, "has_credits": True, "currency": extra.get("currency"),
                   "used": _num(extra.get("used_credits")), "monthly_limit": _num(extra.get("monthly_limit"))}
    return None, [w for w in windows if w], credits, any(w and w["remaining_percent"] <= 0 for w in windows)


def antigravity_limits(body):
    windows = []
    for g in body.get("groups") or []:
        if not isinstance(g, dict):
            continue
        scope = str(g.get("displayName") or "")[:60] or None
        for b in g.get("buckets") or []:
            if isinstance(b, dict) and _num(b.get("remainingFraction")) is not None:
                kind = str(b.get("window") or "")
                label = {"5h": "5-hour", "weekly": "Weekly", "daily": "Daily"}.get(kind, kind or "Limit")
                windows.append(limit_window(str(b.get("bucketId") or kind)[:40], label, remaining=_num(b["remainingFraction"]) * 100,
                                            resets_at=_epoch_ms(b.get("resetTime")),
                                            window_s={"5h": 18000, "weekly": 604800, "daily": 86400}.get(kind), scope=scope))
    return None, [w for w in windows if w], None, any(w and w["remaining_percent"] <= 0 for w in windows)


def signal_limits(provider, model_quotas):
    """Fallback: the rate-limit headers CLIProxyAPI recorded on the account's newest reply (`model_quotas`)."""
    newest = None
    for q in (model_quotas or {}).values():
        if isinstance(q, dict) and isinstance(q.get("signals"), dict) and (newest is None or str(q.get("observed_at")) > str(newest.get("observed_at"))):
            newest = q
    if newest is None:
        return None
    sig, windows, plan, credits = {k.lower(): v for k, v in newest["signals"].items()}, [], None, None
    if provider == "codex":
        for part, wid in (("primary", "5h"), ("secondary", "weekly")):
            mins = _num(sig.get("x-codex-%s-window-minutes" % part))
            secs = int(mins * 60) if mins else None
            windows.append(limit_window(window_id(window_label(secs)), window_label(secs),
                                        used=_num(sig.get("x-codex-%s-used-percent" % part)),
                                        resets_at=_epoch_ms(sig.get("x-codex-%s-reset-at" % part)), window_s=secs))
        plan = sig.get("x-codex-plan-type")
        if "x-codex-credits-balance" in sig:
            credits = {"balance": _num(sig.get("x-codex-credits-balance")), "currency": None,
                       "unlimited": str(sig.get("x-codex-credits-unlimited")).lower() == "true",
                       "has_credits": str(sig.get("x-codex-credits-has-credits")).lower() == "true"}
    elif provider == "claude":
        for part, wid, label, secs in (("5h", "5h", "5-hour", 18000), ("7d", "weekly", "Weekly", 604800)):
            u = _num(sig.get("anthropic-ratelimit-unified-%s-utilization" % part))
            windows.append(limit_window(wid, label, used=u * 100 if u is not None else None,
                                        resets_at=_epoch_ms(sig.get("anthropic-ratelimit-unified-%s-reset" % part)), window_s=secs))
    windows = [w for w in windows if w]
    if not windows:
        return None
    return plan, windows, credits, any(w["remaining_percent"] <= 0 for w in windows), _epoch_ms(newest.get("observed_at"))


def limits_status(windows, limit_reached, disabled):
    if disabled:
        return "disabled"
    if limit_reached or any(w["remaining_percent"] <= 0 for w in windows):
        return "limited"
    if any(w["remaining_percent"] <= 20 for w in windows):
        return "warning"
    return "ok" if windows else "unknown"


async def cliproxy_call(session, path, method="GET", body=None):
    """CLIProxyAPI's management API (the key stays here). Tries /v0 then /v8 (the relay lives under /v8 on this build)."""
    last = None
    for prefix in ("/v0/management", "/v8/management"):
        async with session.request(method, CFG["cliproxy_url"].rstrip("/") + prefix + path, json=body,
                                   headers={"Authorization": "Bearer " + CFG["cliproxy_mgmt_key"]}) as r:
            if r.status == 404:
                last = 404
                continue
            if r.status != 200:
                raise RuntimeError("management API HTTP %d" % r.status)
            return await r.json(content_type=None)
    raise RuntimeError("management API HTTP %s" % last)


async def proxy_relay(session, auth_index, method, url, header, data=None):
    """One request to a provider made by CLIProxyAPI with that account's token ($TOKEN$). Returns the parsed body."""
    body = {"authIndex": auth_index, "auth_index": auth_index, "method": method, "url": url, "header": header}
    if data is not None:
        body["data"] = json.dumps(data)
    res = await cliproxy_call(session, "/requests/api-call", "POST", body)
    status = res.get("status_code") if isinstance(res, dict) else None
    raw = res.get("body") if isinstance(res, dict) else None
    if status != 200:
        raise RuntimeError("provider HTTP %s" % status)
    return json.loads(raw) if isinstance(raw, str) else raw


async def proxy_account_limits(session, f):
    provider = str(f.get("provider") or f.get("type") or "").lower()
    idx = str(f.get("auth_index") or "")
    disabled = bool(f.get("disabled")) or f.get("status") == "disabled"
    # The id hashes the auth file's own name (stable while the file exists, whatever CLIProxyAPI's index does), so the
    # app can animate an account appearing or going away; it reveals nothing about the account.
    acct = {"id": account_id("proxy", provider, f.get("name") or f.get("id") or idx), "label": mask_account(f.get("email") or f.get("label") or f.get("account")),
            "plan": None, "source": "proxy", "used_for": ["chat"], "status": "unknown", "windows": [], "credits": None,
            "live": False, "observed_at": None, "note": None}
    parsed, err = None, None
    try:
        if provider == "codex":
            body = await proxy_relay(session, idx, "GET", CODEX_USAGE_URL,
                                     {"Authorization": "Bearer $TOKEN$", "Content-Type": "application/json", "User-Agent": CODEX_UA})
            parsed = codex_limits(body)
            acct["_who"] = account_id("codex-user", body.get("user_id") or body.get("email") or idx)
        elif provider == "claude":
            body = await proxy_relay(session, idx, "GET", CLAUDE_USAGE_URL,
                                     {"Authorization": "Bearer $TOKEN$", "Content-Type": "application/json", "Accept": "application/json",
                                      "anthropic-beta": "oauth-2025-04-20", "User-Agent": "claude-cli/2.1.280 (external, cli)"})
            parsed = claude_limits(body)
        elif provider == "antigravity" and f.get("project_id"):
            body = await proxy_relay(session, idx, "POST", ANTIGRAVITY_QUOTA_URL,
                                     {"Authorization": "Bearer $TOKEN$", "Content-Type": "application/json",
                                      "User-Agent": "antigravity/hub/2.23.0 darwin/arm64"}, {"project": f["project_id"]})
            parsed = antigravity_limits(body)
    except Exception as exc:
        err = type(exc).__name__ if not isinstance(exc, RuntimeError) else str(exc)
    expired = bool(err) and any(code in err for code in ("HTTP 401", "HTTP 403"))
    if parsed:
        acct.update(plan=parsed[0], windows=parsed[1], credits=parsed[2], live=True, observed_at=now_ms())
        reached = parsed[3]
    else:
        fb = signal_limits(provider, f.get("model_quotas"))
        reached = False
        if fb:
            acct.update(plan=fb[0], windows=fb[1], credits=fb[2], observed_at=fb[4],
                        note="From the account's last reply" + (" (live check failed)" if err else ""))
            reached = fb[3]
        elif err:
            acct["note"] = "Live check failed"
    acct["status"] = limits_status(acct["windows"], reached, disabled)
    if expired and not disabled:                     # the provider refused the account's token: sign in again
        acct.update(status="expired", note="Sign-in expired: log this account in again in CLIProxyAPI"
                    + (" (limits from its last reply)" if acct["windows"] else ""))
    if disabled:
        acct["used_for"] = []
    elif f.get("unavailable") and acct["status"] in ("ok", "warning", "unknown"):
        # The proxy is not routing to it now (a cooldown, or a model this plan does not include). Its own error text
        # stays on the server: it can name the account.
        acct.update(status="unavailable", note="Not in use right now: the provider refused its last request")
    return provider, acct


async def live_login_limits(session):
    """The bridge's own ChatGPT login (GPT-Live), read with its saved access token; never refreshed here (codex does that)."""
    try:
        with open(os.path.join(CFG["codex_home"], "auth.json")) as fh:
            tokens = (json.load(fh) or {}).get("tokens") or {}
    except (OSError, ValueError):
        return None
    token = tokens.get("access_token")
    if not token:
        return None
    acct = {"id": account_id("live", tokens.get("account_id") or ""), "label": None, "plan": None, "source": "live",
            "used_for": ["live"], "status": "unknown", "windows": [], "credits": None, "live": False, "observed_at": None, "note": None}
    headers = {"Authorization": "Bearer " + token, "User-Agent": CODEX_UA, "Accept": "application/json"}
    if tokens.get("account_id"):
        headers["Chatgpt-Account-Id"] = tokens["account_id"]
    try:
        async with session.get(CODEX_USAGE_URL, headers=headers) as r:
            if r.status in (401, 403):
                acct.update(status="expired", note="The server's ChatGPT login needs a refresh (it renews on the next call)")
                return acct
            if r.status != 200:
                acct.update(status="error", note="Live check failed")
                return acct
            body = await r.json(content_type=None)
    except (aiohttp.ClientError, asyncio.TimeoutError, ValueError):
        acct.update(status="error", note="Live check failed")
        return acct
    plan, windows, credits, reached = codex_limits(body)
    acct.update(label=mask_account(body.get("email")), plan=plan, windows=windows, credits=credits, live=True, observed_at=now_ms(),
                _who=account_id("codex-user", body.get("user_id") or body.get("email") or ""))
    acct["status"] = limits_status(windows, reached, False)
    return acct


async def build_usage_limits():
    providers, notes = {}, []
    timeout = aiohttp.ClientTimeout(total=LIMITS_TIMEOUT_S - 2, sock_connect=5)
    async with aiohttp.ClientSession(timeout=timeout) as s:
        jobs = []
        if CFG["cliproxy_mgmt_key"]:
            try:
                files = (await cliproxy_call(s, "/auth-files")).get("files") or []
            except Exception as exc:
                files = []
                notes.append("CLIProxyAPI could not be read (%s)" % (str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__))
            jobs += [proxy_account_limits(s, f) for f in files if isinstance(f, dict)]
        live = live_login_limits(s) if CFG.get("usage_live_login", True) else None
        results = await asyncio.gather(*jobs, *( [live] if live else []), return_exceptions=True)
    live_acct = results[-1] if live and not isinstance(results[-1], BaseException) else None
    for r in results[:len(jobs)]:
        if isinstance(r, BaseException):
            continue
        provider, acct = r
        providers.setdefault(provider, []).append(acct)
    if live_acct:
        same = next((a for a in providers.get("codex", []) if a.get("_who") and a.get("_who") == live_acct.get("_who")), None)
        if same is not None:
            same["used_for"] = ["chat", "live"]                # GPT-Live runs on an account the proxy also uses
        else:
            providers.setdefault("codex", []).append(live_acct)
    order = {"ok": 0, "warning": 1, "limited": 2, "unknown": 3, "unavailable": 4, "expired": 5, "error": 6, "disabled": 7}
    # (status order inside a provider: usable accounts first)
    out = []
    for pid in sorted(providers, key=lambda p: list(PROVIDER_NAMES).index(p) if p in PROVIDER_NAMES else 99):
        accts = sorted(providers[pid], key=lambda a: order.get(a["status"], 9))
        seen = collections.Counter()
        for a in accts:
            a.pop("_who", None)
            seen[a["label"]] += 1
            if a["label"] and seen[a["label"]] > 1:          # two masked labels alike: number them, reveal nothing more
                a["label"] = "%s (%d)" % (a["label"], seen[a["label"]])
        out.append({"id": pid, "name": PROVIDER_NAMES.get(pid, pid.title()), "accounts": accts})
    return {"observed_at": now_ms(), "cached": False, "max_age_s": LIMITS_CACHE_S, "providers": out, "notes": notes}


async def api_usage_limits(req):
    """GET /api/usage/limits[?refresh=1] (API.md "Usage limits")."""
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    if not usage_limits_enabled():
        return jerr(503, "usage_limits_unavailable", message="no quota source is configured on this server")
    LIMITS_CACHE["lock"] = LIMITS_CACHE["lock"] or asyncio.Lock()
    async with LIMITS_CACHE["lock"]:
        age = time.monotonic() - LIMITS_CACHE["at"]
        fresh = req.query.get("refresh") in ("1", "true")      # bypasses the cache; the lock still runs one fetch at a time
        if LIMITS_CACHE["body"] is None or age >= LIMITS_CACHE_S or fresh:
            try:
                LIMITS_CACHE["body"] = await asyncio.wait_for(build_usage_limits(), LIMITS_TIMEOUT_S)
                LIMITS_CACHE["at"] = time.monotonic()
            except asyncio.TimeoutError:
                if LIMITS_CACHE["body"] is None:
                    return jerr(504, "timeout", message="the providers did not answer in time")
            body = dict(LIMITS_CACHE["body"])
        else:
            body = {**LIMITS_CACHE["body"], "cached": True}
    return web.json_response(body, headers={"Cache-Control": "private, max-age=%d" % LIMITS_CACHE_S})


def usage_limits_enabled():
    return bool(CFG.get("cliproxy_mgmt_key")) or os.path.exists(os.path.join(CFG["codex_home"], "auth.json"))


async def api_suggestions(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    try:
        n = _int_param(req, "n", 4, 1, SUGGEST_MAX)
    except ValueError:
        return jerr(400, "bad_n", message="n must be 1 to %d" % SUGGEST_MAX)
    titles = []
    if CHAT["store"] is not None and req.query.get("personalize", "true") not in ("false", "0"):
        rows, _ = CHAT["store"].list_conversations(10)
        titles = [r["title"] for r in rows if r["title"] != NEW_CHAT_TITLE]
    items, personal = pick_suggestions(n, titles)
    return web.json_response({"suggestions": items, "personalized": personal}, headers={"Cache-Control": "no-store"})


# --- conversations REST
async def api_conversations_list(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    try:
        limit = _int_param(req, "limit", PAGE_DEFAULT, 1, PAGE_MAX)
    except ValueError:
        return jerr(400, "bad_limit", message="limit must be 1 to %d" % PAGE_MAX)
    cursor, raw = None, req.query.get("cursor") or ""
    if raw:
        m = re.fullmatch(r"(\d{1,15}):([A-Za-z0-9_-]{1,64})", raw)
        if not m:
            return jerr(400, "bad_cursor", message="cursor is not one this server returned")
        cursor = (int(m.group(1)), m.group(2))
    pinned = {"true": True, "1": True, "false": False, "0": False, None: None, "": None}.get(req.query.get("pinned"), "bad")
    if pinned == "bad":
        return jerr(400, "bad_pinned", message="pinned must be true or false")
    rows, nxt = store.list_conversations(limit, cursor, pinned)
    return web.json_response({"conversations": rows, "next_cursor": nxt})


def _title_param(body):
    title = body.get("title")
    if title is None:
        return None, None
    if not isinstance(title, str) or not title.strip():
        return None, jerr(400, "bad_title", message="title must be a non-empty string")
    title = " ".join(title.split())
    if len(title) > MAX_TITLE_CHARS:
        return None, jerr(400, "title_too_long", message="title is longer than %d characters" % MAX_TITLE_CHARS)
    return title, None


async def api_conversations_create(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    body, bad = await read_json(req)
    if bad:
        return bad
    title, bad = _title_param(body)
    if bad:
        return bad
    return web.json_response({"conversation": store.create_conversation(title)}, status=201)


async def api_conversation_get(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    conv, bad = _conv_or_404(store, req.match_info["cid"])
    if bad:
        return bad
    try:
        limit = _int_param(req, "limit", MSG_PAGE_DEFAULT, 1, MSG_PAGE_MAX)
    except ValueError:
        return jerr(400, "bad_limit", message="limit must be 1 to %d" % MSG_PAGE_MAX)
    msgs, more = store.messages(conv["id"], limit)
    return web.json_response({"conversation": conv, "messages": msgs, "has_more": more})


async def api_conversation_messages(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    conv, bad = _conv_or_404(store, req.match_info["cid"])
    if bad:
        return bad
    try:
        limit = _int_param(req, "limit", MSG_PAGE_DEFAULT, 1, MSG_PAGE_MAX)
    except ValueError:
        return jerr(400, "bad_limit", message="limit must be 1 to %d" % MSG_PAGE_MAX)
    before = req.query.get("before") or None
    if before is not None and not valid_id(before):
        return jerr(400, "bad_before", message="before must be a message id")
    msgs, more = store.messages(conv["id"], limit, before)
    if msgs is None:
        return jerr(404, "not_found", message="no such message in this conversation")
    return web.json_response({"messages": msgs, "has_more": more})


async def api_conversation_patch(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    conv, bad = _conv_or_404(store, req.match_info["cid"])
    if bad:
        return bad
    body, bad = await read_json(req)
    if bad:
        return bad
    title, bad = _title_param(body)
    if bad:
        return bad
    pinned = body.get("pinned")
    if pinned is not None and not isinstance(pinned, bool):
        return jerr(400, "bad_pinned", message="pinned must be true or false")
    if title is None and pinned is None:
        return jerr(400, "nothing_to_change", message="send title and/or pinned")
    return web.json_response({"conversation": store.update_conversation(conv["id"], title, pinned)})


async def api_conversation_delete(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    cid = req.match_info["cid"]
    if not valid_id(cid) or store.get_conversation(cid) is None:
        return jerr(404, "not_found", message="no such conversation")
    await stop_jobs(cid, "deleted")                         # do not leave Hermes working for a chat that is gone
    if not store.delete_conversation(cid):
        return jerr(404, "not_found", message="no such conversation")
    gc_uploads(store)                                       # its attachments go with it
    return web.json_response({"ok": True})


async def api_message_delete(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    cid, mid = req.match_info["cid"], req.match_info["mid"]
    if valid_id(cid) and valid_id(mid):
        await stop_jobs(cid, "deleted", mid=mid)
    if not valid_id(cid) or not valid_id(mid) or not store.delete_message(cid, mid):
        return jerr(404, "not_found", message="no such message in this conversation")
    gc_uploads(store)
    return web.json_response({"ok": True})


async def api_conversations_search(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    q = " ".join((req.query.get("q") or "").split())
    if not q:
        return jerr(400, "empty_query", message="q is required")
    if len(q) > MAX_QUERY_CHARS:
        return jerr(400, "query_too_long", message="q is longer than %d characters" % MAX_QUERY_CHARS)
    try:
        limit = _int_param(req, "limit", PAGE_DEFAULT, 1, PAGE_MAX)
    except ValueError:
        return jerr(400, "bad_limit", message="limit must be 1 to %d" % PAGE_MAX)
    return web.json_response({"results": store.search(q, limit)})


# --- live transcript import
def _client_time(v, now):
    return v if isinstance(v, int) and not isinstance(v, bool) and now - 7 * 86400000 <= v <= now + 60000 else now


def _ms(v):
    return v if isinstance(v, int) and not isinstance(v, bool) else None


def client_clock_shift(values, now):
    """Milliseconds to add to a client's times when its clock runs ahead: the newest time then lands on `now`, so the
    turns keep their order and spacing instead of all becoming `now` (which put every turn after the call's tasks)."""
    times = [v for v in map(_ms, values) if v is not None]
    return now - max(times) if times and max(times) > now + 60000 else 0


# One message per spoken turn. Transcripts arrive in pieces, and app builds before 16 November 2026 saved the first
# piece of almost every turn as a turn of its own ("Alright, bye" then "Alright, bye for now."); a turn that GPT-Live
# cut off and restarted also left a few words behind. merge_voice_turns() folds such entries into one.
VOICE_JOIN_GAP_MS = 20000      # same-speaker entries that start closer together than this are one spoken turn
VOICE_FRAGMENT_WORDS = 3       # an assistant entry this short with no closing punctuation was cut off
_VOICE_NORM_RE = re.compile(r"[^\w\s]|_", re.UNICODE)
_SENTENCE_END_RE = re.compile(r"[.!?…。！？][\"'”’)\]]*$")


def voice_norm(text):
    """Lower case, punctuation removed, single spaces: "Goodbye," and "Goodbye, Alex." compare as prefix and text."""
    return " ".join(_VOICE_NORM_RE.sub("", str(text or "").lower()).split())


def merge_voice_turns(turns, gap_ms=VOICE_JOIN_GAP_MS):
    """Voice entries of one call, in spoken order (dicts with role, text, optional created ms and id) -> one entry per
    spoken turn, and how many entries were folded away. Within a run of one speaker:
      - an entry that the next one repeats and extends (a transcript prefix, compared without punctuation or case),
        or that repeats it exactly, gives way to the longer one; a shorter repeat after it is dropped;
      - an assistant entry of at most three words without closing punctuation, followed within `gap_ms` by another,
        was interrupted and gives way to it;
      - what is left of entries that start within `gap_ms` of each other is joined with a space.
    The result keeps the first entry's id and created time. Empty texts are dropped (not counted)."""
    out, folded = [], 0
    for t in turns:
        text = " ".join(str(t.get("text") or "").split())
        if not text:
            continue
        created = _ms(t.get("created"))
        g = out[-1] if out and out[-1]["role"] == t["role"] else None
        if g is not None:
            last = g["_segs"][-1]
            a, b = voice_norm(last), voice_norm(text)
            near = created is None or g["_last"] is None or created - g["_last"] <= gap_ms
            if b.startswith(a) or a.startswith(b) or near:
                if b.startswith(a):
                    g["_segs"][-1] = text                    # the earlier entry was a piece of this one
                elif a.startswith(b):
                    pass                                     # a late, shorter copy of what is already there
                elif t["role"] == "assistant" and len(last.split()) <= VOICE_FRAGMENT_WORDS and not _SENTENCE_END_RE.search(last):
                    g["_segs"][-1] = text                    # cut off, then said again differently
                else:
                    g["_segs"].append(text)
                if created is not None:
                    g["_last"] = created
                folded += 1
                continue
        out.append({**t, "text": text, "_segs": [text], "_last": created})
    for g in out:
        g["text"] = " ".join(g.pop("_segs"))[:MAX_MESSAGE_CHARS]
        g.pop("_last")
    return out, folded


async def api_live_transcript(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    conv, bad = _conv_or_404(store, req.match_info["cid"])
    if bad:
        return bad
    body, bad = await read_json(req)
    if bad:
        return bad
    turns, tasks, session = body.get("turns", []), body.get("tasks", []), body.get("session")
    if not isinstance(turns, list) or not isinstance(tasks, list):
        return jerr(400, "bad_transcript", message="turns and tasks must be lists")
    if len(turns) > MAX_TURNS or len(tasks) > MAX_TASKS:
        return jerr(413, "too_many_items", message="at most %d turns and %d tasks per request" % (MAX_TURNS, MAX_TASKS))
    if session is not None and not valid_id(session):
        return jerr(400, "bad_session", message="session must be the id /api/session returned")
    now, rows, spoken, empty = now_ms(), [], [], 0
    for t in turns:
        if not isinstance(t, dict) or t.get("role") not in ("user", "assistant") or not isinstance(t.get("text"), str):
            return jerr(400, "bad_turn", message="each turn needs role user|assistant and text")
        if len(t["text"]) > MAX_MESSAGE_CHARS:
            return jerr(400, "too_long", message="a turn is longer than %d characters" % MAX_MESSAGE_CHARS)
        if t.get("id") is not None and not valid_id(t["id"]):
            return jerr(400, "bad_id", message="turn id must be an id string")
        if t["text"].strip():
            spoken.append({"role": t["role"], "text": t["text"], "created": _ms(t.get("created")), "id": t.get("id")})
        else:
            empty += 1
    shift = client_clock_shift([t.get("created") for t in turns + tasks if isinstance(t, dict)], now)
    merged, folded = merge_voice_turns(spoken)
    for t in merged:
        created = t["created"] + shift if t["created"] is not None else None
        rows.append((t["role"], t["text"], "voice", "complete", _client_time(created, now),
                     "turn:" + t["id"] if t.get("id") else None, {"session": session} if session else {}))
    for t in tasks:
        if not isinstance(t, dict) or t.get("status", "done") not in ("done", "failed") or not isinstance(t.get("answer", ""), str) \
                or not isinstance(t.get("request", ""), str):
            return jerr(400, "bad_task", message="each task needs answer (string) and status done|failed")
        if len(t.get("answer", "")) > MAX_TASK_CHARS or len(t.get("request", "")) > MAX_MESSAGE_CHARS:
            return jerr(400, "too_long", message="a task answer or request is too long")
        if t.get("id") is not None and not valid_id(t["id"]):
            return jerr(400, "bad_id", message="task id must be an id string")
        seconds = t.get("seconds") if isinstance(t.get("seconds"), int) and not isinstance(t.get("seconds"), bool) else None
        client_id = ("job:%s:%s" % (session, t["id"]) if session else "job::" + t["id"]) if t.get("id") else None
        created = _ms(t.get("created"))
        rows.append(("assistant", t.get("answer", "").strip(), "task", "complete" if t.get("status", "done") == "done" else "error",
                     _client_time(created + shift if created is not None else None, now), client_id,
                     {k: v for k, v in (("task", t.get("request", "")[:2000]), ("job", t.get("id")), ("session", session), ("seconds", seconds)) if v}))
    added, skipped = 0, empty
    first_user = None
    with store.quiet(conv["id"]):
        store.db.execute("BEGIN")
        try:
            for role, text, source, status, created, client_id, meta in rows:
                if not text and status == "complete":
                    skipped += 1
                    continue
                try:
                    store.add_message(conv["id"], role, text, source, status, created, client_id, meta, touch=False)
                    added += 1
                    if role == "user" and first_user is None:
                        first_user = text
                except sqlite3.IntegrityError:
                    skipped += 1                   # already imported (same turn id, or a task the bridge saved itself)
            store.db.execute("COMMIT")
        except Exception:
            store.db.execute("ROLLBACK")
            raise
    if added:
        store.touch(conv["id"], kind="live")
        if first_user and conv["title_source"] == "auto" and conv["title"] == NEW_CHAT_TITLE:
            first_user = store.first_user_text(conv["id"]) or first_user     # the earliest spoken turn names the chat
            store.set_auto_title(conv["id"], simple_title(first_user), "auto")
            if title_mode() != "simple":
                _background(generate_title(conv["id"], first_user))
    return web.json_response({"added": added, "skipped": skipped, "merged": folded, "conversation": store.get_conversation(conv["id"])})


# --- streaming chat
async def iter_sse(content):
    """(event, data) pairs from an SSE byte stream (aiohttp StreamReader iterates lines)."""
    event, data = "", []
    async for raw in content:
        line = raw.decode("utf-8", "replace").rstrip("\r\n")
        if not line:
            if data:
                yield event or "message", "\n".join(data)
            event, data = "", []
        elif line.startswith(":"):
            continue
        else:
            field, _, value = line.partition(":")
            value = value[1:] if value.startswith(" ") else value
            if field == "event":
                event = value
            elif field == "data":
                data.append(value)
    if data:
        yield event or "message", "\n".join(data)


def _usage(u):
    return {k: u[k] for k in ("prompt_tokens", "completion_tokens", "total_tokens") if isinstance(u, dict) and isinstance(u.get(k), int)} or None


HERMES_COUNTERS = ("input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "reasoning_tokens", "api_call_count")


def build_usage(stream, session, *, duration_ms, ttft_ms, tool_count, effort, model=None):
    """meta.usage for one reply (API.md "Usage"). `stream` is Hermes' own usage ({prompt,completion,total}_tokens,
    summed over the turn's tool loop); `session` is this turn's share of Hermes' session counters (or None). The
    old keys stay for older clients."""
    u = dict(stream or {})
    if stream:
        u.update(input_tokens=stream.get("prompt_tokens"), output_tokens=stream.get("completion_tokens"))
    s = (session or {}).get("delta")
    if s:
        if "input_tokens" not in u:
            u.update(input_tokens=s["input_tokens"] + s["cache_read_tokens"], output_tokens=s["output_tokens"],
                     total_tokens=s["input_tokens"] + s["cache_read_tokens"] + s["output_tokens"])
        u.update(cached_tokens=s["cache_read_tokens"], reasoning_tokens=s["reasoning_tokens"], model_calls=s["api_call_count"])
    u.update(model=(session or {}).get("model") or model or CFG["hermes_model"], duration_ms=duration_ms, ttft_ms=ttft_ms,
             tool_count=tool_count, effort=effort)
    return {k: v for k, v in u.items() if v is not None}


async def hermes_session_usage(store, session_id, prompt_tokens, exclude_mid, tries=3):
    """This turn's share of Hermes' session counters (GET /api/sessions/{id}: input, cache-read, reasoning tokens,
    model calls; checked 16 November 2026), as {"model", "snapshot", "delta"}. The counters add up over the whole
    session (a chat keeps one), so the turn's share is the difference to the snapshot saved with the previous reply
    of that session. A new session is its own share. `delta` is None when it cannot be known exactly: the share
    must agree with the prompt tokens Hermes streamed (within 5 %), else another client shares the session."""
    url = "%s/api/sessions/%s" % (hermes_api_root(), urllib.parse.quote(session_id, safe=""))
    prev = store.hermes_snapshot(session_id, exclude_mid) if store is not None else None
    for attempt in range(tries):
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=3)) as s:
                async with s.get(url, headers={"Authorization": "Bearer " + CFG["hermes_key"]}) as r:
                    data = await r.json(content_type=None) if r.status == 200 else None
        except (aiohttp.ClientError, asyncio.TimeoutError, ValueError) as exc:
            log.info("hermes session usage lookup failed: %s", type(exc).__name__)
            return None
        sess = data.get("session") if isinstance(data, dict) else None
        if not isinstance(sess, dict):
            return None
        snap = {k: sess.get(k) if isinstance(sess.get(k), int) and not isinstance(sess.get(k), bool) else 0 for k in HERMES_COUNTERS}
        delta = {k: snap[k] - prev.get(k, 0) for k in HERMES_COUNTERS} if prev else dict(snap)
        model = str(sess.get("model") or "")[:80] or None
        if delta["api_call_count"] > 0 and min(delta.values()) >= 0:
            seen = delta["input_tokens"] + delta["cache_read_tokens"]
            ok = prompt_tokens is None or abs(seen - prompt_tokens) <= max(64, prompt_tokens * 0.05)
            return {"model": model, "snapshot": {"session": session_id, **snap}, "delta": delta if ok else None}
        if attempt + 1 < tries:
            await asyncio.sleep(0.3 * (attempt + 1))         # the counters may land just after the stream ends
    return {"model": model, "snapshot": {"session": session_id, **snap}, "delta": None}


def _upstream_error(status):
    if status in (401, 403):
        return {"code": "hermes_auth", "message": "Hermes rejected the bridge's API key"}
    if status == 429:
        return {"code": "hermes_busy", "message": "Hermes is busy; try again shortly"}
    return {"code": "hermes_error", "message": "Hermes returned HTTP %d" % status}


def hermes_effort_fields(effort):
    """Body fields for one reply effort: Instant = fast tier + low reasoning; Medium/High = default tier (the
    standard Hermes provider) + that reasoning. No effort (live-call tasks) = Hermes' defaults, i.e. the fast tier."""
    if not effort:
        return {}
    fields = {"model_options": {"reasoning_effort": EFFORTS[effort]}}
    if effort not in FAST_EFFORTS and CFG.get("standard_provider"):
        fields["provider"] = CFG["standard_provider"]
    return fields


async def hermes_stream(messages, effort, q):
    """Run one Hermes chat completion and put ("delta"|"status"|"finish"|"error"|"eof", value) on q."""
    body = {"model": CFG["hermes_model"], "messages": messages, "stream": True, **hermes_effort_fields(effort)}
    finished = False
    try:
        timeout = aiohttp.ClientTimeout(total=CHAT_TIMEOUT_S, sock_connect=10)
        async with aiohttp.ClientSession(timeout=timeout) as s:
            async with s.post(CFG["hermes_url"].rstrip("/") + "/chat/completions", json=body,
                              headers={"Authorization": "Bearer " + CFG["hermes_key"], "Accept": "text/event-stream"}) as r:
                if r.status != 200:
                    q.put_nowait(("error", _upstream_error(r.status)))
                    return
                sid = r.headers.get("X-Hermes-Session-Id", "").strip()
                if sid and len(sid) <= 200 and not re.search(r"[\x00-\x1f/]", sid):
                    q.put_nowait(("session", sid))                # where Hermes stores this turn's tool calls
                if r.content_type != "text/event-stream":       # a server that ignores stream: one chunk
                    data = await r.json(content_type=None)
                    choice = (data.get("choices") or [{}])[0]
                    text = str((choice.get("message") or {}).get("content") or "")
                    if text:
                        q.put_nowait(("delta", text))
                    q.put_nowait(("finish", {"finish_reason": choice.get("finish_reason") or "stop", "usage": _usage(data.get("usage"))}))
                    q.put_nowait(("eof", None))
                    return
                async for event, data in iter_sse(r.content):
                    if event == "message":
                        if data.strip() == "[DONE]":
                            finished = True
                            break
                        try:
                            obj = json.loads(data)
                        except ValueError:
                            continue
                        if isinstance(obj.get("error"), (dict, str)):
                            q.put_nowait(("error", {"code": "hermes_error", "message": "Hermes reported an error"}))
                            return
                        choice = (obj.get("choices") or [{}])[0]
                        delta = choice.get("delta") or {}
                        thought = delta.get("reasoning_content") or delta.get("reasoning")
                        if isinstance(thought, str) and thought:
                            q.put_nowait(("reasoning", thought))  # structured reasoning, when the model exposes it
                        piece = delta.get("content")
                        if piece:
                            q.put_nowait(("delta", str(piece)))
                        if choice.get("finish_reason") or obj.get("usage"):
                            q.put_nowait(("finish", {"finish_reason": choice.get("finish_reason"), "usage": _usage(obj.get("usage"))}))
                            finished = finished or bool(choice.get("finish_reason"))
                    elif event == "hermes.tool.progress":
                        try:
                            p = json.loads(data)
                        except ValueError:
                            continue
                        state = str(p.get("status") or "running").lower()
                        if state == "error" or p.get("error") or p.get("is_error") is True or p.get("ok") is False:
                            state = "failed"                  # Hermes 2026-11 only sends running/completed
                        q.put_nowait(("status", {"label": redact_secrets(strip_ansi(str(p.get("label") or p.get("tool") or "")))[:200], "state": state,
                                                 "tool": str(p.get("tool") or "")[:80], "id": str(p.get("toolCallId") or "")[:80],
                                                 "emoji": str(p.get("emoji") or "")[:8]}))
                    elif event == "hermes.status":
                        try:
                            p = json.loads(data)
                        except ValueError:
                            continue
                        q.put_nowait(("status", {"label": str(p.get("text") or "")[:200], "state": "info", "tool": "", "id": "",
                                                 "emoji": "", "kind": str(p.get("kind") or "")[:40]}))
                    elif event == "approval.request":
                        q.put_nowait(("status", {"label": "Hermes is waiting for an approval", "state": "approval", "tool": "", "id": "", "emoji": ""}))
        q.put_nowait(("eof", None) if finished else ("error", {"code": "hermes_incomplete", "message": "Hermes ended the reply early"}))
    except asyncio.CancelledError:
        raise
    except asyncio.TimeoutError:
        q.put_nowait(("error", {"code": "timeout", "message": "Hermes took longer than %d s" % CHAT_TIMEOUT_S}))
    except Exception as exc:
        log.warning("hermes chat failed: %s", type(exc).__name__)
        q.put_nowait(("error", {"code": "hermes_unreachable", "message": "could not reach Hermes"}))


def title_mode():
    """"simple", "model" or "hermes" (API.md "Titles"); "auto" picks "model" when a title endpoint key is set."""
    mode = CFG.get("titles", "auto")
    if mode == "auto":
        mode = "model" if CFG.get("title_api_key") else "simple"
    if (mode == "model" and not CFG.get("title_api_key")) or (mode == "hermes" and not CFG.get("hermes_key")) \
            or mode not in ("simple", "model", "hermes"):
        return "simple"
    return mode


TITLE_SYSTEM = ("You name chats. Reply with a title of 3 or 4 words (never more than 4) in Title Case that names the topic of the user's "
                "first message. Describe what the user asks or says; never answer it, greet, or address anyone. "
                "No quotes, no emoji, no final punctuation. Reply with the title only.")


def usable_title(raw):
    """A cleaned model title of 2 to 5 words (asked for 3–4; one word either way is tolerated), else ""."""
    title = clean_title(raw)
    return title if 2 <= len(title.split()) <= 5 else ""


def generate_title(cid, user_text):
    return model_title(cid, user_text) if title_mode() == "model" else hermes_title(cid, user_text)


async def model_title(cid, user_text):
    """One small non-streaming call to TITLE_API_URL (for example CLIProxyAPI's OpenAI-compatible API) with only
    the user's first message: a 3–4 word title for about 150 tokens instead of a whole Hermes run."""
    # max_tokens leaves room for a reasoning model's own tokens: with 24, a third of the titles came back empty.
    body = {"model": CFG["title_model"], "stream": False, "max_tokens": 64, "temperature": 0.2, "reasoning_effort": "low",
            **({"service_tier": CFG["title_service_tier"]} if CFG["title_service_tier"] else {}),
            "messages": [{"role": "system", "content": TITLE_SYSTEM},
                         {"role": "user", "content": "<message>\n%s\n</message>" % user_text[:1000]}]}
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=TITLE_TIMEOUT_S)) as s:
            async with s.post(CFG["title_api_url"].rstrip("/") + "/chat/completions", json=body,
                              headers={"Authorization": "Bearer " + CFG["title_api_key"]}) as r:
                if r.status != 200:
                    log.info("title model answered HTTP %d", r.status)
                    return
                data = await r.json(content_type=None)
        title = usable_title((data.get("choices") or [{}])[0].get("message", {}).get("content"))
        if title and CHAT["store"] is not None:
            CHAT["store"].set_auto_title(cid, title, "hermes")      # "hermes" = generated (the app knows it)
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        log.info("title generation skipped: %s", type(exc).__name__)


async def hermes_title(cid, user_text):
    """One short non-streaming Hermes call after the first reply (spec §9.8); the 40-character title stays otherwise.
    Only the user's first message goes in: the title names what they asked, never how Hermes answered."""
    prompt = ("Write a title of 3 or 4 words that names the topic of the message below, which a user sent to start a chat. "
              "Describe what the user is asking or saying; do not answer it, greet anyone or address the user. "
              "Reply with the title only: no quotes, no final punctuation, no tools.\n\n<message>\n%s\n</message>"
              % user_text[:1000])
    body = {"model": CFG["hermes_model"], "stream": False, "messages": [{"role": "user", "content": prompt}],
            "model_options": {"reasoning_effort": "low"}}
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=TITLE_TIMEOUT_S)) as s:
            async with s.post(CFG["hermes_url"].rstrip("/") + "/chat/completions", json=body,
                              headers={"Authorization": "Bearer " + CFG["hermes_key"]}) as r:
                if r.status != 200:
                    return
                data = await r.json(content_type=None)
        title = usable_title((data.get("choices") or [{}])[0].get("message", {}).get("content"))
        if title and CHAT["store"] is not None:
            CHAT["store"].set_auto_title(cid, title, "hermes")
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        log.info("title generation skipped: %s", type(exc).__name__)


def _background(coro):
    t = asyncio.create_task(coro)
    CHAT["bg"].add(t)
    t.add_done_callback(CHAT["bg"].discard)


TERMINAL_EVENTS = ("done", "error", "stopped")
LEADING_BLANK_LINES = re.compile(r"\A(?:[ \t]*\r?\n)+")   # Hermes opens a reply with "\n\n" (QA 15 November 2026)
TOOLS_MAX = 64                          # tool calls kept per message (older ones dropped, counted in tools_truncated)
MAX_FINISHED_JOBS = 64                  # finished replies kept for resume, on top of the time limit


def running_jobs(cid=None):
    return [j for j in CHAT["jobs"].values() if not j.done and (cid is None or j.cid == cid)]


def sse_bytes(seq, event, data) -> bytes:
    head = "id: %d\n" % seq if seq is not None else ""
    return (head + "event: %s\ndata: %s\n\n" % (event, json.dumps(data, ensure_ascii=False))).encode()


class ChatJob:
    """One Hermes reply, run as a background task that no HTTP request owns. Every event gets the next id (1, 2, 3…,
    `meta` is always 1) and goes into a bounded buffer; any number of readers replay from an id and then follow live.
    Closing a reader never stops the reply: only stop() does (POST /api/chat/{message_id}/stop)."""
    kind = "text"                                # "task": a live-call task written into its chat (TaskJob)

    def __init__(self, store, conv, user_msg, asst, context, effort, created, user_text):
        self.store, self.id, self.cid = store, asst["id"], conv["id"]
        self.context, self.effort, self.created, self.user_text = context, effort, created, user_text
        self.seq = 0
        self.meta = None                         # (1, "meta", data): kept outside the buffer, never dropped
        self.events = collections.deque()
        self.parts, self.last_status = [], None
        self.lead = ""                           # whitespace before the reply's first visible character, held back
        self.tools, self.tools_truncated, self.tools_dirty = [], 0, False   # persisted as meta.tools (API.md)
        self.steps, self.steps_truncated, self.step_seq = [], 0, 0             # persisted as meta.steps (API.md "Steps")
        self.hermes_session, self.details = None, set()
        self.status, self.stop_reason = "streaming", None
        self.done, self.finished_at = False, None
        self.finished = asyncio.Event()
        self._wake = asyncio.Event()
        self.q = asyncio.Queue()
        self.task = self.upstream = None
        self.readers = 0                         # open GET/POST streams following this reply
        self.t0, self.ttft_ms, self.hermes_usage = time.monotonic(), None, None
        self.pics, self.pictures = ReplyPictures(user_text), None        # entity pictures (API.md "Entity pictures")
        self.publish("meta", {"conversation_id": conv["id"], "message_id": asst["id"], "user_message_id": user_msg["id"],
                              "client_msg_id": user_msg.get("client_id"), "created_conversation": created,
                              "title": conv["title"], "resumable": True})

    # ---- event buffer
    def publish(self, event, data):
        self.seq += 1
        item = (self.seq, event, data)
        if event == "meta":
            self.meta = item
        else:
            self.events.append(item)
            while len(self.events) > CFG["stream_buffer"]:
                self.events.popleft()
        wake, self._wake = self._wake, asyncio.Event()
        wake.set()

    def since(self, after):
        """Events with an id above `after`. When the buffer no longer holds all of them, a `snapshot` event (the whole
        reply so far, with the id of the last event it covers) stands in for the ones that were dropped."""
        out = []
        if after < 1:
            out.append(self.meta)
            after = 1
        if self.events and self.events[0][0] > after + 1:
            upto = self.seq - 1 if self.done else self.seq     # the terminal event is always still in the buffer
            out.append((upto, "snapshot", {"conversation_id": self.cid, "message_id": self.id, "text": "".join(self.parts),
                                           "status": "streaming", "last_status": self.last_status, "tools": self.tools_meta(),
                                           "steps": self.steps_meta()}))
            after = upto
        out.extend(e for e in self.events if e[0] > after)
        return out

    # ---- lifecycle
    def start(self):
        CHAT["jobs"][self.id] = self
        CHAT["active"] += 1
        if self.kind == "text":                  # a live task announces itself as task.started
            emit_event("reply.started", conversation_id=self.cid, message_id=self.id, user_message_id=self.meta[2]["user_message_id"])
        self.task = asyncio.create_task(self.run())
        return self

    def stop(self, reason="user"):
        """Ask the reply to stop; the partial text is kept with status `cancelled`. Harmless once it has finished."""
        if self.done or self.stop_reason:
            return False
        self.stop_reason = reason
        self.q.put_nowait(("stop", reason))
        if self.upstream is not None and not self.upstream.done():
            self.upstream.cancel()                            # closes the Hermes request, which interrupts the agent
        return True

    async def run(self):
        store, st, status = self.store, {"finish": None, "usage": None, "error": None}, "streaming"
        try:
            if self.stop_reason is None:
                effort = self.effort or (CFG["chat_default_effort"] if CFG["chat_default_effort"] in EFFORTS else None)
                self.upstream = asyncio.create_task(hermes_stream(self.context, effort, self.q))
            last_save = time.monotonic()
            while True:
                kind, val = await self.q.get()
                if kind == "delta":
                    if not self.parts:
                        # Blank lines before the first visible character are dropped (stored, streamed and pushed
                        # alike); a first line's indent is kept. Whitespace alone is not the answer starting yet.
                        self.lead += val
                        if not self.lead.strip():
                            continue
                        val, self.lead = LEADING_BLANK_LINES.sub("", self.lead), ""
                        self.ttft_ms = round((time.monotonic() - self.t0) * 1000)
                    self.close_thinking()
                    self.parts.append(val)
                    self.publish("delta", {"text": val})
                    if any(c in val for c in ")>`"):            # where an entity reference or a block can end
                        self.pics.scan("".join(self.parts))
                elif kind == "reasoning":
                    self.add_thinking(val)
                elif kind == "session":
                    self.hermes_session = val
                    continue
                elif kind == "step_io":
                    self.end_tool_step(*val)
                elif kind == "status":
                    self.last_status = val
                    self.track_tool(val)
                    self.publish("status", val)
                    self.tool_step(val)
                elif kind == "finish":
                    st["finish"] = val.get("finish_reason") or st["finish"]
                    st["usage"] = val.get("usage") or st["usage"]
                    continue
                elif kind == "error":
                    status, st["error"] = "error", val
                    await self.finish_steps(wait=True)
                    break
                elif kind == "eof":
                    status = "complete"
                    await self.finish_steps(wait=True)
                    break
                elif kind == "stop":
                    status = "cancelled"
                    break
                if time.monotonic() - last_save > 2.0:      # keep a partial reply if the bridge dies mid-stream
                    store.update_message(self.id, text="".join(self.parts), meta=self.tools_save() if self.tools_dirty else None)
                    last_save = time.monotonic()
            if status == "complete" and self.parts:
                await self.fill_pictures()
            if status == "complete" and self.hermes_session:
                try:                                        # at most a few seconds before `done`; usage is extra
                    self.hermes_usage = await asyncio.wait_for(hermes_session_usage(
                        store, self.hermes_session, (st["usage"] or {}).get("prompt_tokens"), self.id), 4)
                except asyncio.TimeoutError:
                    log.info("hermes session usage lookup timed out")
        except asyncio.CancelledError:
            status = "interrupted"                            # the bridge is shutting down
            raise
        except Exception:
            log.exception("chat reply failed inside the bridge")
            status, st["error"] = "error", {"code": "bridge_error", "message": "the bridge failed while writing this reply"}
        finally:
            if self.upstream is not None and not self.upstream.done():
                self.upstream.cancel()
            if status == "streaming":
                status = "interrupted"
            self.status = status
            self.close_tools("done" if status == "complete" else "failed")
            self.close_steps("done" if status == "complete" else "failed")
            st["usage"] = build_usage(st["usage"], self.hermes_usage, duration_ms=round((time.monotonic() - self.t0) * 1000),
                                      ttft_ms=self.ttft_ms, tool_count=len(self.tools) + self.tools_truncated, effort=self.effort)
            meta = {k: v for k, v in (("finish_reason", st["finish"]), ("usage", st["usage"]),
                                      ("_hermes", (self.hermes_usage or {}).get("snapshot")),
                                      ("tools", self.tools_meta() or None), ("tools_truncated", self.tools_truncated or None),
                                      ("steps", self.steps_meta() or None), ("steps_truncated", self.steps_truncated or None),
                                      ("error_code", (st["error"] or {}).get("code")),
                                      ("stop_reason", self.stop_reason if status == "cancelled" else None),
                                      ("pictures", self.pictures if (self.pictures or {}).get("count") else None),
                                      ("stream_seq", self.seq + 1)) if v}
            meta.update(self.end_meta())
            try:
                store.update_message(self.id, text="".join(self.parts), status=status, meta=meta)
            except sqlite3.Error as exc:
                log.info("chat reply not saved: %s", type(exc).__name__)
            log.info("chat reply %s: %d chars", status, sum(map(len, self.parts)))
            if status == "interrupted":
                self._finish()
        try:
            if status == "complete":
                self.publish("done", self._done_data(st))
            elif status == "error":
                self.publish("error", {"conversation_id": self.cid, "message_id": self.id, **st["error"]})
            else:
                self.publish("stopped", {"conversation_id": self.cid, "message_id": self.id, "reason": self.stop_reason or "user"})
            self.after_end(status)
        finally:
            self._finish()

    async def fill_pictures(self):
        """Entity pictures, once the text has streamed: a `snapshot` with the finished text when it changed. Never
        fails the reply; at most ENTITY_WAIT_S of lookups still running (they usually ended while the text streamed)."""
        t, text = time.monotonic(), "".join(self.parts)
        if "```openui" in text:
            try:
                problems = openui_issues(text)
                if problems:
                    log.warning("openui reply %s: %s", self.id, "; ".join(problems))
                else:
                    log.info("openui reply %s: valid", self.id)
            except Exception:
                log.exception("openui check skipped")
        try:
            new, shown = await self.pics.finish(text)
        except Exception:
            log.exception("entity pictures skipped")
            return
        finally:
            for task in self.pics.tasks.values():
                if not task.done():
                    task.cancel()                    # the shared lookup goes on and lands in the cache
        self.pictures = {"count": len(shown), "ms": round((time.monotonic() - t) * 1000)}
        if new != text:
            self.parts = [new]
            self.publish("snapshot", {"conversation_id": self.cid, "message_id": self.id, "text": new, "status": "streaming",
                                      "last_status": self.last_status, "tools": self.tools_meta(), "steps": self.steps_meta()})
        for url in dict.fromkeys(shown):
            _background(warm_image(url))
        if shown or new != text:
            log.info("entity pictures: %d shown, %d ms after the text", len(shown), self.pictures["ms"])

    def end_meta(self):
        return {}

    def after_end(self, status):
        """The reply has ended and its terminal event is out. Nobody is watching (the app left the chat or is
        closed): tell the devices. A stop because of a retry, a delete or a dropped connection in cancel mode needs no
        notification. Every other end goes on the events stream (API.md "Events"), which the app dedupes."""
        if status == "cancelled" and self.stop_reason in ("retry", "deleted", "disconnect"):
            return
        text = "".join(self.parts)
        if self.readers == 0:
            notify("chat.reply", self.cid, self.id, status, text)
        emit_event("reply.done", conversation_id=self.cid, message_id=self.id, status=PUSH_STATUS.get(status, status),
                   watched=self.readers > 0, **event_text(self.cid, text))

    # ---- tool calls, kept on the message as meta.tools
    def track_tool(self, val):
        state, now = val.get("state"), now_ms()
        if state == "info":
            return
        offset = sum(map(len, self.parts))
        if state in ("completed", "done", "failed"):
            final = "failed" if state == "failed" else "done"
            for t in reversed(self.tools):
                if t["id"] == val.get("id") and t["state"] == "running":
                    t["state"], t["ended"] = final, now
                    break
            else:
                self.tools.append({"id": val.get("id", ""), "tool": val.get("tool", ""), "label": val.get("label", ""),
                                   "emoji": val.get("emoji", ""), "state": final, "offset": offset, "started": now, "ended": now})
        else:
            self.tools.append({"id": val.get("id", "") if state == "running" else "", "tool": val.get("tool", ""),
                               "label": val.get("label", ""), "emoji": val.get("emoji", ""),
                               "state": "approval" if state == "approval" else "running", "offset": offset, "started": now})
        if len(self.tools) > TOOLS_MAX:
            drop = len(self.tools) - TOOLS_MAX
            del self.tools[:drop]
            self.tools_truncated += drop
        self.tools_dirty = True

    def close_tools(self, final):
        now = now_ms()
        for t in self.tools:
            if t["state"] == "running":
                t["state"], t["ended"] = final, now

    def tools_meta(self):
        return [dict(t) for t in self.tools]

    def tools_save(self):
        self.tools_dirty = False
        return {"tools": self.tools_meta(), **({"tools_truncated": self.tools_truncated} if self.tools_truncated else {}),
                "steps": self.steps_meta(), **({"steps_truncated": self.steps_truncated} if self.steps_truncated else {})}

    # ---- steps: thinking and tool timeline (API.md "Steps")
    def new_step(self, kind, **fields):
        self.step_seq += 1
        step = {"id": "s%d" % self.step_seq, "kind": kind, "state": "running", "started_at": now_ms(), "ended_at": None,
                "offset": sum(map(len, self.parts)), **fields}
        self.steps.append(step)
        if len(self.steps) > STEPS_MAX:
            for old in self.steps[: len(self.steps) - STEPS_MAX]:
                if old["state"] == "running":
                    old["state"] = "done"
            del self.steps[: len(self.steps) - STEPS_MAX]
            self.steps_truncated += 1
        self.tools_dirty = True
        return step

    @staticmethod
    def public_step(step):
        return {k: (dict(v) if isinstance(v, dict) else v) for k, v in step.items() if not k.startswith("_")}

    def steps_meta(self):
        return [self.public_step(st) for st in self.steps]

    def add_thinking(self, text):
        st = self.steps[-1] if self.steps and self.steps[-1]["kind"] == "thinking" and self.steps[-1]["state"] == "running" else None
        if st is None:
            st = self.new_step("thinking", text="", truncated=False)
            self.publish("step.start", {"message_id": self.id, "step": self.public_step(st)})
        room = STEP_TEXT_MAX - len(st["text"])
        piece = strip_ansi(text)[:max(0, room)]
        if len(text) > room:
            st["truncated"] = True
        if piece:
            st["text"] += piece
            self.publish("step.delta", {"message_id": self.id, "id": st["id"], "text": redact_secrets(piece)})
            self.tools_dirty = True

    def close_thinking(self):
        st = self.steps[-1] if self.steps and self.steps[-1]["kind"] == "thinking" and self.steps[-1]["state"] == "running" else None
        if st is not None:
            st.update(state="done", ended_at=now_ms(), text=redact_secrets(st["text"]))
            self.publish("step.end", {"message_id": self.id, "step": self.public_step(st)})
            self.tools_dirty = True

    def tool_step(self, val):
        state = val.get("state")
        if state == "running":
            self.close_thinking()
            st = self.new_step("tool", tool={"name": val.get("tool", ""), "label": val.get("label", ""), "emoji": val.get("emoji", ""),
                                             "call_id": val.get("id", ""), "input": None, "output": None, "exit_status": None,
                                             "error": None, "truncated": False, "details": False})
            self.publish("step.start", {"message_id": self.id, "step": self.public_step(st)})
        elif state in ("completed", "done", "failed"):
            st = next((x for x in reversed(self.steps) if x["kind"] == "tool" and x["state"] == "running" and not x.get("_ending")
                       and x["tool"]["call_id"] == val.get("id")), None)
            if st is None:
                return
            st["_ending"], st["_final"], st["ended_at"] = True, "failed" if state == "failed" else "done", now_ms()
            if self.hermes_session and st["tool"]["call_id"]:
                task = asyncio.create_task(hermes_tool_detail(self.hermes_session, st["tool"]["call_id"]))
                self.details.add(task)

                def done(t, step_id=st["id"]):
                    self.details.discard(t)
                    if not t.cancelled() and not self.done:
                        self.q.put_nowait(("step_io", (step_id, t.exception() is None and t.result() or None)))
                task.add_done_callback(done)
            else:
                self.end_tool_step(st["id"], None)

    def end_tool_step(self, step_id, detail):
        st = next((x for x in self.steps if x["id"] == step_id), None)
        if st is None or st["state"] != "running":
            return
        if detail:
            st["tool"].update(tool_io(*detail), details=True)
        else:
            st["tool"]["input"] = st["tool"]["input"] or st["tool"]["label"] or None   # the stream's preview only
        failed = st.get("_final") == "failed" or bool(st["tool"]["error"]) or st["tool"]["exit_status"] not in (None, 0)
        st.update(state="failed" if failed else "done", ended_at=st["ended_at"] or now_ms())
        self.publish("step.end", {"message_id": self.id, "step": self.public_step(st)})
        self.tools_dirty = True

    async def finish_steps(self, wait):
        """Before the terminal event: let outstanding tool lookups land (briefly), then end every open step."""
        self.close_thinking()
        if wait and self.details:
            await asyncio.wait(set(self.details), timeout=STEP_DETAIL_WAIT_S)
            await asyncio.sleep(0)
            while not self.q.empty():
                kind, val = self.q.get_nowait()
                if kind == "step_io":
                    self.end_tool_step(*val)
        for st in self.steps:
            if st["kind"] == "tool" and st["state"] == "running" and st.get("_ending"):
                self.end_tool_step(st["id"], None)

    def close_steps(self, final):
        """The reply ended: every step still open ends `final` (done for a complete reply, else failed)."""
        for t in list(self.details):
            t.cancel()
        now = now_ms()
        for st in self.steps:
            if st["state"] == "running":
                if st["kind"] == "thinking":
                    st["text"] = redact_secrets(st["text"])
                st.update(state=final if not st.get("_final") else st["_final"], ended_at=st["ended_at"] or now)
                self.publish("step.end", {"message_id": self.id, "step": self.public_step(st)})

    def _done_data(self, st):
        store, title_pending = self.store, False
        fresh = store.get_conversation(self.cid)
        if (self.kind == "text" and fresh and fresh["title_source"] == "auto" and title_mode() != "simple" and self.parts
                and store.count_replies(self.cid) == 1):                 # a live chat is named from its spoken turns
            _background(generate_title(self.cid, store.first_user_text(self.cid) or self.user_text))
            title_pending = True
        return {"conversation_id": self.cid, "message_id": self.id, "finish_reason": st["finish"] or "stop", "usage": st["usage"],
                "title": (fresh or {}).get("title", ""), "title_pending": title_pending}

    def _finish(self):
        if self.done:
            return
        self.done, self.finished_at = True, time.monotonic()
        CHAT["active"] -= 1
        self.finished.set()
        wake, self._wake = self._wake, asyncio.Event()
        wake.set()
        try:
            asyncio.get_running_loop().call_later(CFG["stream_keep_s"], self._expire)
        except RuntimeError:
            pass
        finished = sorted((j for j in CHAT["jobs"].values() if j.done), key=lambda j: j.finished_at)
        for old in finished[:max(0, len(finished) - MAX_FINISHED_JOBS)]:
            old._expire()

    def _expire(self):
        if CHAT["jobs"].get(self.id) is self:
            del CHAT["jobs"][self.id]


class TaskJob(ChatJob):
    """A delegated task of a live call linked to a chat, run exactly like a chat reply: its assistant message
    (`source: task`) streams with steps and status events, resumes with GET /api/chat/{message_id}/stream, stops with
    POST …/stop, and outlives the call. The call's job record (/api/job) mirrors its progress and result."""
    kind = "task"

    def __init__(self, store, conv, asst, context, ds, jid, request, on_done=None):
        self.live = None
        super().__init__(store, conv, {"id": None, "client_id": None}, asst, context, None, False, request)
        self.meta[2].update(source="task", session=ds.id, job=jid)
        self.ds, self.jid, self.request, self.on_done = ds, jid, request, on_done
        self.live = ds.jobs[jid]
        self.live.update(message_id=asst["id"], conversation_id=conv["id"])

    def publish(self, event, data):
        super().publish(event, data)
        if self.live is None:
            return
        if event == "delta":
            self.live["partial"] = "".join(self.parts)[-MAX_TASK_CHARS:]
        elif event == "status" and data.get("state") != "info":
            self.live["status_event"] = data

    def end_meta(self):
        return {"seconds": round(time.monotonic() - self.live["t0"])}

    def after_end(self, status):
        raw, live = "".join(self.parts).strip(), self.live
        done = status == "complete"
        live.update(status="done" if done else "failed", markdown=raw if done else "", answer=plain_for_voice(raw) if done else "",
                    usage=None, t_end=time.monotonic(), stopped=status == "cancelled")
        live.pop("partial", None)
        live.pop("status_event", None)
        if done:
            self.ds.history += [{"role": "user", "content": self.request}, {"role": "assistant", "content": raw[:2000]}]
        if self.on_done is not None:
            async def deliver():
                try:
                    await self.on_done(live)
                except Exception as exc:
                    log.warning("task result not delivered to the call: %s", type(exc).__name__)
            _background(deliver())
        if status == "cancelled" and self.stop_reason in ("retry", "deleted"):
            return
        # The same rule as before for the push: nobody follows the message and the call is over or stopped polling.
        if self.readers == 0 and (self.ds.closed or time.monotonic() - self.ds.last_poll > PUSH_POLL_GRACE_S):
            notify("live.task", self.cid, self.id, live["status"] if status != "cancelled" else status, raw)
        emit_event("task.done", conversation_id=self.cid, message_id=self.id, session=self.ds.id, job=self.jid,
                   status=PUSH_STATUS.get(status, status), seconds=round(live["t_end"] - live["t0"]),
                   watched=self.readers > 0, **event_text(self.cid, raw))


def stored_reply_events(msg, after):
    """Resume a reply whose buffer has expired (or that a restart interrupted), from what SQLite holds: a `snapshot`
    with the saved text, then the terminal event. Ids follow the original stream when it recorded them."""
    meta, final = msg["meta"], msg["meta"].get("stream_seq")
    final = final if isinstance(final, int) and final > 1 else None
    if final is not None and after >= final:
        return []
    base = {"conversation_id": msg["conversation_id"], "message_id": msg["id"]}
    status = msg["status"]
    if status == "complete":
        conv = CHAT["store"].get_conversation(msg["conversation_id"]) or {}
        last = ("done", {**base, "finish_reason": meta.get("finish_reason") or "stop", "usage": meta.get("usage"),
                         "title": conv.get("title", ""), "title_pending": False})
    elif status == "cancelled":
        last = ("stopped", {**base, "reason": meta.get("stop_reason") or "user"})
    elif status == "error":
        code = meta.get("error_code") or "hermes_error"
        last = ("error", {**base, "code": code, "message": "the reply failed (%s)" % code})
    else:                                                    # interrupted, or streaming with no job left
        last = ("error", {**base, "code": "interrupted", "message": "the bridge restarted while writing this reply"})
    tools = meta.get("tools") if isinstance(meta.get("tools"), list) else []
    steps = meta.get("steps") if isinstance(meta.get("steps"), list) else []
    return [(final - 1 if final else None, "snapshot", {**base, "text": msg["text"], "status": status, "last_status": None, "tools": tools,
                                                        "steps": steps}),
            (final, last[0], last[1])]


def _sse_response():
    return web.StreamResponse(status=200, headers={
        "Content-Type": "text/event-stream; charset=utf-8", "Cache-Control": "no-store", "X-Accel-Buffering": "no",
        "X-Content-Type-Options": "nosniff"})


async def follow_job(req, job, after, on_disconnect=None):
    """Write a job's events after id `after` to this request, then follow it live until its terminal event. Sends a
    `: keep-alive` comment after KEEPALIVE_S without output. Leaving early only affects this reader."""
    resp, gone = _sse_response(), False
    job.readers += 1
    try:
        await resp.prepare(req)
        cursor, last_write = after, time.monotonic()
        while True:
            wake = job._wake
            items = job.since(cursor)
            for seq, event, data in items:
                await resp.write(sse_bytes(seq, event, data))
                cursor = max(cursor, seq)
                last_write = time.monotonic()
            if (items and items[-1][1] in TERMINAL_EVENTS) or (job.done and cursor >= job.seq):
                break
            try:
                await asyncio.wait_for(wake.wait(), min(1.0, KEEPALIVE_S))
            except asyncio.TimeoutError:
                if req.transport is None or req.transport.is_closing():
                    gone = True
                    break
                if time.monotonic() - last_write >= KEEPALIVE_S:
                    await resp.write(b": keep-alive\n\n")
                    last_write = time.monotonic()
        await resp.write_eof()
    except (ConnectionResetError, ConnectionError):
        gone = True
    except asyncio.CancelledError:
        job.readers -= 1
        if on_disconnect:
            on_disconnect()
        raise
    job.readers -= 1
    if gone and on_disconnect:
        on_disconnect()
    return resp


async def api_chat(req):
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    if not CFG["hermes_key"]:
        return jerr(503, "hermes_unconfigured", message="Hermes is not configured on the bridge")
    body, bad = await read_json(req)
    if bad:
        return bad
    retry = body.get("retry") is True
    message = body.get("message")
    text = message.get("text") if isinstance(message, dict) else None
    att_ids = message.get("attachments") if isinstance(message, dict) else None
    if not retry:
        if att_ids is not None and (not isinstance(att_ids, list) or len(att_ids) > CFG["upload_max_items"]
                                    or not all(valid_id(a) for a in att_ids) or len(set(att_ids)) != len(att_ids)):
            return jerr(400, "bad_attachment", message="attachments must be at most %d distinct upload ids" % CFG["upload_max_items"])
        att_ids = att_ids or []
        if text is None and att_ids:
            text = ""
        if not isinstance(text, str) or (not text.strip() and not att_ids):
            return jerr(400, "empty_message", message="message.text is required (it may be empty when attachments are sent)")
        if len(text) > MAX_MESSAGE_CHARS:
            return jerr(400, "too_long", message="message is longer than %d characters" % MAX_MESSAGE_CHARS)
    web_search = body.get("web_search")
    if web_search is not None and not isinstance(web_search, bool):
        return jerr(400, "bad_request", message="web_search must be true or false")
    effort = body.get("effort")
    if effort is not None and effort not in EFFORTS:
        return jerr(400, "bad_effort", message="effort must be instant, medium or high")
    if body.get("location") is not None and not isinstance(body.get("location"), dict):
        return jerr(400, "bad_request", message="location must be an object")
    client_msg_id = body.get("client_msg_id")
    if client_msg_id is not None and not valid_id(client_msg_id):
        return jerr(400, "bad_client_msg_id", message="client_msg_id must be 1-64 characters of A-Z a-z 0-9 _ -")
    cid = body.get("conversation_id")
    if cid is not None and not valid_id(cid):
        return jerr(404, "not_found", message="no such conversation")
    # A retry first stops the reply it replaces, so that one does not count against the limit.
    busy = [j for j in running_jobs() if j.kind == "text" and not (retry and j.cid == cid)]   # live tasks have their own limit
    if len(busy) >= CFG["max_chats"]:
        return jerr(429, "busy", message="%d replies are already streaming" % CFG["max_chats"])
    created, att_rows = False, []
    if not retry and att_ids:
        if not uploads_enabled():
            return jerr(400, "bad_attachment", message="this server does not accept attachments")
        att_rows = [store.upload(a) for a in att_ids]
        if any(r is None or (r["conversation_id"] is not None and r["conversation_id"] != cid) or r["message_id"] for r in att_rows):
            return jerr(400, "bad_attachment", message="an attachment is unknown, already sent, or belongs to another chat")
        new_bytes = sum(r["size"] for r in att_rows if r["conversation_id"] is None)
        if cid is not None and new_bytes and store.upload_bytes(cid) + new_bytes > CFG["upload_conv_mb"] * MIB:
            return jerr(507, "quota_exceeded", message="the server's upload storage for this chat is full")
    if cid is None:
        if retry:
            return jerr(400, "nothing_to_retry", message="retry needs a conversation_id")
        first_name = att_rows[0]["name"] if att_rows else ""
        conv, created = store.create_conversation(simple_title(text) if text.strip() else simple_title(first_name), "auto"), True
    else:
        conv, bad = _conv_or_404(store, cid)
        if bad:
            return bad
    if retry:
        user_msg = store.last_user_message(conv["id"])
        if user_msg is None:
            return jerr(409, "nothing_to_retry", message="this conversation has no user message to answer")
        await stop_jobs(conv["id"], "retry", kind="text")          # a running live-call task is not a reply to retry
        store.delete_replies_after(conv["id"], user_msg)
        text = user_msg["text"]
        web_search = user_msg["meta"].get("web_search") is True if web_search is None else web_search
    else:
        meta = {k: v for k, v in (("effort", effort), ("web_search", True if web_search else None),
                                  ("attachments", [upload_public(r) for r in att_rows] or None),
                                  ("_location", await location_note(body.get("location")))) if v}
        try:
            user_msg = store.add_message(conv["id"], "user", text, "text", client_id=client_msg_id, meta=meta or None)
        except sqlite3.IntegrityError:
            return jerr(409, "duplicate", message="a message with this client_msg_id is already in the conversation")
        if att_rows:
            store.claim_uploads([r["id"] for r in att_rows], conv["id"], user_msg["id"])
            copies = await asyncio.get_running_loop().run_in_executor(None, workspace_copies, conv["id"],
                                                                      [store.upload(r["id"]) for r in att_rows])
            for uid, rel in copies:
                store.set_workspace(uid, rel)
        if not created and conv["title_source"] == "auto" and conv["title"] == NEW_CHAT_TITLE and text.strip():
            store.set_auto_title(conv["id"], simple_title(store.first_user_text(conv["id"]) or text), "auto")
    web = (web_search or store.used_web_search(conv["id"])) and await hermes_has_web_search()
    context = store.context(conv["id"], web_note=WEB_SEARCH_NOTE if web else "", web_last=bool(web_search))
    # One system message: the app's UI prompt, then the user's custom instructions (both byte-stable between turns,
    # because Hermes keys its session on the system prompt plus the first user message).
    v = ui_version(req, body)
    system = "\n\n".join(p for p in (ui_prompt(v) if v else "", settings_prompt(store.get_settings()["settings"])) if p)
    if system:
        context.insert(0, {"role": "system", "content": system})
    asst = store.add_message(conv["id"], "assistant", "", "text", status="streaming", meta={"effort": effort} if effort else None)
    job = ChatJob(store, store.get_conversation(conv["id"]), user_msg, asst, context, effort, created, text).start()
    on_gone = (lambda: job.stop("disconnect")) if CFG["stream_disconnect"] == "cancel" else None
    return await follow_job(req, job, 0, on_gone)


async def stop_jobs(cid, reason, mid=None, timeout=5.0, kind=None):
    jobs = [j for j in running_jobs(cid) if (mid is None or j.id == mid) and (kind is None or j.kind == kind)]
    for j in jobs:
        j.stop(reason)
    if jobs:
        await asyncio.wait([asyncio.ensure_future(j.finished.wait()) for j in jobs], timeout=timeout)


def _last_event_id(req):
    raw = req.headers.get("Last-Event-ID")
    raw = raw if raw not in (None, "") else req.query.get("last_event_id", "")
    raw = raw.strip()
    if raw == "":
        return 0
    if not re.fullmatch(r"\d{1,9}", raw):
        raise ValueError(raw)
    return int(raw)


def _assistant_or_404(store, mid):
    msg = store.get_message(mid) if valid_id(mid) else None
    if msg is None or msg["role"] != "assistant" or msg["source"] not in ("text", "task"):
        return None, jerr(404, "not_found", message="no such reply")
    return msg, None


async def api_chat_stream(req):
    """GET /api/chat/{message_id}/stream: resume a reply after `Last-Event-ID` (header or ?last_event_id=)."""
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    try:
        after = _last_event_id(req)
    except ValueError:
        return jerr(400, "bad_last_event_id", message="Last-Event-ID must be an event id this server sent")
    mid = req.match_info["mid"]
    job = CHAT["jobs"].get(mid) if valid_id(mid) else None
    if job is not None:
        return await follow_job(req, job, after)
    msg, bad = _assistant_or_404(store, mid)
    if bad:
        return bad
    resp = _sse_response()
    try:
        await resp.prepare(req)
        for seq, event, data in stored_reply_events(msg, after):
            await resp.write(sse_bytes(seq, event, data))
        await resp.write_eof()
    except (ConnectionResetError, ConnectionError):
        pass
    return resp


async def api_chat_stop(req):
    """POST /api/chat/{message_id}/stop: stop a reply on purpose. The partial text stays, with status `cancelled`."""
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    store, bad = _store_or_error()
    if bad:
        return bad
    mid = req.match_info["mid"]
    job = CHAT["jobs"].get(mid) if valid_id(mid) else None
    stopped = False
    if job is not None and not job.done:
        stopped = job.stop("user")
        try:
            await asyncio.wait_for(job.finished.wait(), 10)
        except asyncio.TimeoutError:
            pass
    msg, bad = _assistant_or_404(store, mid)
    if bad:
        return bad
    return web.json_response({"ok": True, "conversation_id": msg["conversation_id"], "message_id": mid,
                              "stopped": stopped and msg["status"] == "cancelled", "status": msg["status"],
                              "text": msg["text"]})


async def _open_store(_app):
    try:
        CHAT["store"] = ChatStore(CFG["chat_db"])
        CHAT["store"].emit = emit_event              # chat changes go on the events stream (sync, round 6 D4)
    except Exception as exc:
        CHAT["store"] = None
        log.error("chat history unavailable: %s", type(exc).__name__)
    if CHAT["store"] is not None and CFG["uploads"]:
        try:
            gc_uploads(CHAT["store"])
        except Exception as exc:
            log.warning("upload cleanup failed: %s", type(exc).__name__)
        _background(upload_housekeeping())


async def _close_store(_app):
    if isinstance(DIRECT["s"], OpenAISession):
        await DIRECT["s"].close()                   # books its minutes and saves its transcript before the store closes
    for t in list(CHAT["bg"]):
        t.cancel()
    tasks = [j.task for j in CHAT["jobs"].values() if j.task is not None and not j.task.done()] + list(LIVE_TASKS)
    for t in tasks:
        t.cancel()                                           # saved as `interrupted`
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)
    CHAT["jobs"].clear()
    CHAT["active"] = 0
    if CHAT["store"] is not None:
        CHAT["store"].close()
        CHAT["store"] = None


# ----------------------------------------------------------------------------------------------------------------
# Transcription (dictation): POST /api/transcribe
# ----------------------------------------------------------------------------------------------------------------
STT_PROMPT_CHARS = 600
STT_RATE = 24000                                   # the Realtime API's PCM input rate
STT_SLOTS = {"busy": 0}


def transcribe_enabled() -> bool:
    return bool(CFG["stt_url"]) and bool(CFG["live_key"])


def wav_to_pcm24k(data: bytes):
    """16-bit PCM WAV (mono or stereo, 8-48 kHz) -> (24 kHz mono PCM16 bytes, seconds). Raises ValueError."""
    import io, wave
    try:
        with wave.open(io.BytesIO(data)) as w:
            ch, width, rate, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
            frames = w.readframes(n)
    except (wave.Error, EOFError) as exc:
        raise ValueError("not a WAV file (%s)" % exc)
    if width != 2 or ch not in (1, 2) or not 8000 <= rate <= 48000:
        raise ValueError("send 16-bit PCM WAV, mono or stereo, 8-48 kHz")
    a = np.frombuffer(frames[: len(frames) // (2 * ch) * 2 * ch], dtype="<i2").astype(np.float32)
    if ch == 2:
        a = a.reshape(-1, 2).mean(axis=1)
    seconds = a.size / rate
    if rate != STT_RATE and a.size:
        x = np.arange(0, a.size, rate / STT_RATE)
        a = np.interp(x, np.arange(a.size), a)
    return np.clip(a, -32768, 32767).astype("<i2").tobytes(), seconds


def stt_language(tag: str):
    """BCP-47 (en-IN) -> ISO 639-1 (en) for the transcription model; None when unusable."""
    base = (tag or "").strip().replace("_", "-").split("-")[0].lower()
    return base if re.fullmatch(r"[a-z]{2}", base) else None


async def stt_upstream(pcm: bytes, language, prompt) -> str:
    """One transcription over the Realtime websocket: append, commit, wait for the transcript."""
    url = CFG["stt_url"] + ("&" if "?" in CFG["stt_url"] else "?") + urllib.parse.urlencode({"model": CFG["stt_session_model"]})
    headers = {"Authorization": "Bearer " + CFG["stt_key"]} if CFG["stt_key"] else {}
    transcription = {"model": CFG["stt_model"]}
    if language:
        transcription["language"] = language
    if prompt:
        transcription["prompt"] = prompt
    timeout = aiohttp.ClientTimeout(total=CFG["stt_timeout_s"])
    async with aiohttp.ClientSession(timeout=timeout) as s:
        async with s.ws_connect(url, headers=headers, heartbeat=20, max_msg_size=4 * MIB) as ws:
            async def next_event():
                msg = await ws.receive(timeout=CFG["stt_timeout_s"])
                if msg.type != WSMsgType.TEXT:
                    raise ConnectionError("transcription service closed the connection")
                return json.loads(msg.data)
            first = await next_event()
            if first.get("type") == "error":
                raise ConnectionError((first.get("error") or {}).get("code") or "upstream_error")
            await ws.send_json({"type": "session.update", "session": {"type": "realtime", "output_modalities": ["text"],
                "audio": {"input": {"format": {"type": "audio/pcm", "rate": STT_RATE}, "turn_detection": None,
                                    "transcription": transcription}}}})
            step = STT_RATE * 2 // 2                       # half a second per append
            for i in range(0, len(pcm), step):
                await ws.send_json({"type": "input_audio_buffer.append", "audio": base64.b64encode(pcm[i:i + step]).decode()})
            await ws.send_json({"type": "input_audio_buffer.commit"})
            while True:
                e = await next_event()
                t = e.get("type")
                if t == "conversation.item.input_audio_transcription.completed":
                    return (e.get("transcript") or "").strip()
                if t in ("error", "conversation.item.input_audio_transcription.failed"):
                    err = e.get("error") or {}
                    raise ConnectionError(err.get("code") or err.get("type") or "upstream_error")


async def api_transcribe(req):
    """multipart/form-data: `file` (16-bit PCM WAV), optional `language` (BCP-47) and `prompt` (earlier words, names).
    -> {"text", "duration_s", "model"}. The audio stays in memory and is dropped when the request ends."""
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    if not transcribe_enabled():
        return jerr(503, "transcribe_unavailable", message="transcription is not configured on this server")
    cap = CFG["stt_max_s"] * 48000 * 2 * 2 + 64 * 1024       # the longest clip at 48 kHz stereo
    if req.content_length is not None and req.content_length > cap:
        return jerr(413, "too_large", message="the recording is longer than this server accepts")
    audio, language, prompt = None, None, None
    try:
        reader = await req.multipart()
        while True:
            part = await reader.next()
            if part is None:
                break
            if part.name == "file" and audio is None:
                buf = bytearray()
                while True:
                    chunk = await part.read_chunk(256 * 1024)
                    if not chunk:
                        break
                    buf += chunk
                    if len(buf) > cap:
                        return jerr(413, "too_large", message="the recording is longer than this server accepts")
                audio = bytes(buf)
            elif part.name == "language" and part.filename is None:
                language = stt_language((await part.read_chunk(64)).decode("utf-8", "replace"))
            elif part.name == "prompt" and part.filename is None:
                raw = await part.read_chunk(STT_PROMPT_CHARS * 4)
                prompt = raw.decode("utf-8", "ignore").strip()[-STT_PROMPT_CHARS:] or None
    except (ValueError, aiohttp.ClientError, AssertionError):
        return jerr(400, "bad_audio", message="send multipart/form-data with a WAV part named file")
    if not audio:
        return jerr(400, "bad_audio", message="send multipart/form-data with a WAV part named file")
    try:
        pcm, seconds = wav_to_pcm24k(audio)
    except ValueError as exc:
        return jerr(415, "bad_audio", message=str(exc))
    finally:
        del audio
    if seconds > CFG["stt_max_s"] + 0.5:
        return jerr(413, "too_large", message="the recording is longer than %d seconds" % CFG["stt_max_s"])
    if seconds < 0.15:
        return web.json_response({"text": "", "duration_s": round(seconds, 2), "model": CFG["stt_model"]})
    if STT_SLOTS["busy"] >= CFG["stt_concurrent"]:
        return jerr(503, "busy", message="too many transcriptions at once; try again", headers={"Retry-After": "2"})
    STT_SLOTS["busy"] += 1
    started = time.monotonic()
    try:
        text = await stt_upstream(pcm, language, prompt)
    except (asyncio.TimeoutError, TimeoutError):
        log.warning("transcribe: upstream timed out after %.1fs", time.monotonic() - started)
        return jerr(504, "transcribe_timeout", message="transcription took too long; try again")
    except (aiohttp.ClientError, ConnectionError, OSError, json.JSONDecodeError) as exc:
        log.warning("transcribe: upstream failed (%s)", type(exc).__name__ if not isinstance(exc, ConnectionError) else exc)
        return jerr(502, "transcribe_failed", message="the transcription service did not answer; try again")
    finally:
        STT_SLOTS["busy"] -= 1
        del pcm
    log.info("transcribe: %.1fs of audio in %.2fs", seconds, time.monotonic() - started)
    return web.json_response({"text": text, "duration_s": round(seconds, 2), "model": CFG["stt_model"]})


# ----------------------------------------------------------------------------------------------------------------
# Places (API.md "Places"): open data, no API keys. Hermes' places_search tool (hermes-places/ plugin) is answered
# from a local SQLite extract of Overture Maps Places (places_fetch.py: names, categories, addresses, phones,
# websites, socials, confidence, position). "near <area>" is geocoded with Photon (komoot) or any Photon/Nominatim
# compatible endpoint, cached. The few results shown are enriched from OpenStreetMap through the Overpass API
# (opening hours, phone, website, wheelchair access, a photo tag), politely: one request at a time, at least a second
# apart, a daily cap, results cached for a week. There are no ratings: the model takes ratings from listing pages it
# finds on the web and names their source.
# ----------------------------------------------------------------------------------------------------------------
PLACE_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
PLACES_MAX_DEFAULT, PLACES_MAX = 5, 10
PLACES_RADIUS_DEFAULT, PLACES_RADIUS_MAX = 5000, 50000
PLACES = {"search": collections.OrderedDict(), "osm": collections.OrderedDict(), "geo": collections.OrderedDict()}
PLACES_CACHE_MAX = 2000
PLACES_UA = "ToveBridge/1.0 (self-hosted chat app; places)"
OSM_TILES = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
OSM_ATTRIBUTION = "© OpenStreetMap contributors"
PLACES_ATTRIBUTION = "Places: Overture Maps Foundation · OpenStreetMap contributors"
OSM_CACHE_S = 7 * 86400
PLACES_THROTTLE = {}                                  # service -> {"lock", "last"}
PLACES_STOP = {"a", "an", "the", "near", "me", "my", "in", "at", "for", "of", "and", "or", "to", "best", "good", "top",
               "nearby", "around", "here", "open", "now", "find", "cheap", "great", "nice", "place", "places", "some",
               "with", "where", "can", "i", "get", "really", "tonight", "today", "quiet", "suggest", "recommend"}
# Words people use -> the words Overture's names and categories use (prefix terms, OR-ed with the word itself).
PLACES_SYNONYMS = {
    "dentist": ["dental"], "physio": ["physical", "physiotherap"], "physiotherapist": ["physical", "physiotherap"],
    "psychiatrist": ["psychiatr", "mental"], "psychologist": ["psycholog", "mental"], "adhd": ["psychiatr", "psycholog", "mental"],
    "therapist": ["psycholog", "counsel"], "counsellor": ["counsel"], "doctor": ["clinic", "doctor"],
    "eye": ["ophthalm", "optic", "eye"], "kids": ["pediatr", "child"], "paediatrician": ["pediatr"],
    "vet": ["veterinar"], "gym": ["gym", "fitness"], "cafe": ["cafe", "coffee"], "coffee": ["cafe", "coffee"],
    "hotel": ["hotel", "lodg"], "veg": ["vegetarian"], "atm": ["atm", "bank"], "chemist": ["pharmac"],
    "pharmacy": ["pharmac"], "hospital": ["hospital"], "salon": ["salon", "beauty", "hair"],
}


class PlacesError(Exception):
    """A places failure with a stable code: unavailable, bad_request, not_found, upstream."""


def places_db_path():
    return CFG.get("places_db") or os.path.join(CFG["data_dir"], "places.sqlite")


def places_enabled():
    return os.path.isfile(places_db_path())


def _place_text(v, limit=200):
    return re.sub(r"\s+", " ", v).strip()[:limit] if isinstance(v, str) else ""


def _http_url(v):
    v = _place_text(v, 500)
    try:
        u = urllib.parse.urlsplit(v)
    except ValueError:
        return None
    return v if u.scheme in ("http", "https") and u.hostname and not u.username else None


def places_meta():
    """The extract's meta table (release, bbox, count, attribution), or {}."""
    try:
        db = sqlite3.connect("file:%s?mode=ro" % urllib.parse.quote(places_db_path()), uri=True)
        try:
            return {k: json.loads(v) for k, v in db.execute("SELECT key, value FROM meta")}
        finally:
            db.close()
    except (sqlite3.Error, ValueError):
        return {}


def places_terms(query):
    """FTS5 query over names and categories: each meaningful word as a prefix term, plus its synonyms."""
    words = [w for w in re.findall(r"[^\W_]+", query.lower()) if w not in PLACES_STOP and len(w) > 1][:6]
    terms = []
    for w in words:
        for t in [w] + PLACES_SYNONYMS.get(w, []):
            stem = t[:-3] if len(t) >= 8 else t[:-1] if len(t) >= 6 else t      # dentist -> dent*, clinics -> clinic*
            if stem not in terms:
                terms.append(stem)
    return "{name cats} : (%s)" % " OR ".join('"%s"*' % t.replace('"', "") for t in terms) if terms else ""


def haversine_km(lat1, lng1, lat2, lng2):
    p = math.pi / 180
    a = 0.5 - math.cos((lat2 - lat1) * p) / 2 + math.cos(lat1 * p) * math.cos(lat2 * p) * (1 - math.cos((lng2 - lng1) * p)) / 2
    return 12742 * math.asin(math.sqrt(max(0.0, a)))


def places_query_db(path, query, point, radius_m, n):
    """Ranked rows from the extract: text relevance, then confidence and distance. Widens the radius (up to 4x) when
    fewer than n match nearby."""
    match = places_terms(query)
    if not match:
        raise PlacesError("bad_request")
    db = sqlite3.connect("file:%s?mode=ro" % urllib.parse.quote(path), uri=True)
    db.row_factory = sqlite3.Row
    try:
        for factor in (1, 2, 4):
            sql = ("SELECT p.*, bm25(places_fts, 4.0, 6.0, 0.5) AS rank FROM places_fts JOIN places p ON p.rowid = places_fts.rowid "
                   "WHERE places_fts MATCH ?")
            args = [match]
            if point:
                r = radius_m * factor
                dlat = r / 111320.0
                dlng = r / (111320.0 * max(0.2, math.cos(math.radians(point[0]))))
                sql += " AND p.lat BETWEEN ? AND ? AND p.lng BETWEEN ? AND ?"
                args += [point[0] - dlat, point[0] + dlat, point[1] - dlng, point[1] + dlng]
            rows = db.execute(sql + " ORDER BY rank LIMIT 400", args).fetchall()
            if len(rows) >= n or not point:
                break
    except sqlite3.OperationalError as exc:
        log.warning("places: query failed (%s)", exc)
        raise PlacesError("unavailable")
    finally:
        db.close()
    if not rows:
        return []
    best = min(r["rank"] for r in rows) or -1.0
    scored, seen = [], set()
    for r in rows:
        dist = haversine_km(point[0], point[1], r["lat"], r["lng"]) if point else None
        rel = r["rank"] / best if best else 0.0                                 # 1.0 = the best text match
        near = 1.0 - min(1.0, (dist or 0) * 1000 / (radius_m * 4)) if point else 0.5
        score = 0.55 * rel + 0.25 * (r["confidence"] or 0) + 0.2 * near
        key = (r["name"].lower(), round(r["lat"], 3), round(r["lng"], 3))
        if key in seen:
            continue
        seen.add(key)
        scored.append((score, dist, dict(r)))
    scored.sort(key=lambda x: -x[0])
    return [(dist, row) for _, dist, row in scored[:n]]


def place_compact(row, dist=None, osm=None):
    """One extract row (+ its OSM tags) -> the compact shape the model and the app see."""
    osm = osm or {}
    category = _place_text((row.get("category") or row.get("basic") or "").replace("_", " "), 60).capitalize()
    socials = []
    try:
        socials = [s for s in json.loads(row.get("socials") or "[]") if _http_url(s)][:2]
    except ValueError:
        pass
    hours = _place_text(osm.get("opening_hours"), 120) or None
    photo = _http_url(osm.get("image"))
    commons = _place_text(osm.get("wikimedia_commons"), 200)
    if not photo and commons.startswith("File:"):
        photo = "https://commons.wikimedia.org/wiki/Special:FilePath/" + urllib.parse.quote(commons[5:].replace(" ", "_"))
    out = {
        "id": "place:" + row["id"], "name": _place_text(row["name"], 120),
        "category": category or None,
        "subtitle": " · ".join(x for x in (category, _place_area(row)) if x),
        "address": ", ".join(x for x in (_place_text(row.get("address"), 160), _place_text(row.get("locality"), 60)) if x) or None,
        "lat": row["lat"], "lng": row["lng"],
        "distance_km": round(dist, 1) if dist is not None else None,
        "phone": _place_text(osm.get("phone") or osm.get("contact:phone") or row.get("phone"), 40).split(";")[0].strip() or None,
        "website": _http_url(row.get("website")) or _http_url(osm.get("website") or osm.get("contact:website")),
        "socials": socials or None,
        "hours": hours, "open_now": opening_hours_open(hours) if hours else None,
        "wheelchair": osm.get("wheelchair") if osm.get("wheelchair") in ("yes", "no", "limited") else None,
        "photo": photo,
        "confidence": round(row.get("confidence") or 0, 2),
        "sources": "Overture Maps" + (" + OpenStreetMap" if osm else ""),
    }
    return {k: v for k, v in out.items() if v is not None}


def _place_area(row):
    """A short "where": the street part of the address (Overture's locality is usually just the city)."""
    parts = [p.strip() for p in (row.get("address") or "").split(",") if p.strip() and not re.fullmatch(r"[\d\s/-]+", p.strip())]
    street = next((p for p in parts if not re.match(r"^(no\.?|#|door|flat|plot)\b", p, re.I)), parts[0] if parts else "")
    return _place_text(street, 40) or _place_text(row.get("locality"), 40)


_OH_DAYS = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]


def opening_hours_open(spec, now=None):
    """True/False for common OSM opening_hours ("24/7", "Mo-Fr 09:00-18:00; Sa 10:00-14:00; Su off"), at the bridge's
    local time; None for anything this small parser does not understand (holidays, months, sunrise…)."""
    now = now or datetime.datetime.now()
    spec = spec.strip()
    if spec == "24/7":
        return True
    today, minute = _OH_DAYS[now.weekday()], now.hour * 60 + now.minute
    state = None
    for rule in [r.strip() for r in spec.split(";") if r.strip()]:
        m = re.fullmatch(r"((?:(?:Mo|Tu|We|Th|Fr|Sa|Su)(?:-(?:Mo|Tu|We|Th|Fr|Sa|Su))?,?)+)?\s*(.+)", rule)
        if not m:
            return None
        days, times = m.group(1), m.group(2).strip()
        if days:
            covered = set()
            for part in days.strip(",").split(","):
                a, _, b = part.partition("-")
                i, j = _OH_DAYS.index(a), _OH_DAYS.index(b or a)
                covered.update(_OH_DAYS[k % 7] for k in range(i, j + 1 if j >= i else j + 8))
            if today not in covered:
                continue
        if times in ("off", "closed"):
            state = False
            continue
        spans = re.findall(r"(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})", times)
        if not spans or re.sub(r"[\d:,\s+-]", "", times):
            return None
        state = False
        for h1, m1, h2, m2 in spans:
            a, b = int(h1) * 60 + int(m1), int(h2) * 60 + int(m2)
            if (a <= minute < b) if b > a else (minute >= a or minute < b):
                state = True
    return state


async def places_throttled(service, spacing=1.0):
    """One request at a time per service, at least `spacing` seconds apart (Nominatim's and Overpass's policies)."""
    t = PLACES_THROTTLE.setdefault(service, {"lock": asyncio.Lock(), "last": 0.0})
    await t["lock"].acquire()
    wait = spacing - (time.monotonic() - t["last"])
    if wait > 0:
        await asyncio.sleep(wait)
    return t


def places_release(t):
    t["last"] = time.monotonic()
    t["lock"].release()


async def places_http_json(service, url, params=None, data=None, timeout=8):
    t = await places_throttled(service)
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=timeout), trust_env=False) as s:
            req = s.post(url, data=data, headers={"User-Agent": PLACES_UA}) if data is not None else \
                s.get(url, params=params, headers={"User-Agent": PLACES_UA, "Accept-Language": "en"})
            async with req as r:
                if r.status != 200:
                    raise PlacesError("upstream")
                return await r.json(content_type=None)
    except (aiohttp.ClientError, asyncio.TimeoutError, OSError, ValueError) as exc:
        log.info("places: %s failed (%s)", service, type(exc).__name__)
        raise PlacesError("upstream")
    finally:
        places_release(t)


def _cache_get(cache, key, ttl):
    hit = cache.get(key)
    if hit and hit[0] + ttl > time.time():
        cache.move_to_end(key)
        return hit[1]
    return None


def _cache_put(cache, key, value):
    cache[key] = (time.time(), value)
    cache.move_to_end(key)
    while len(cache) > PLACES_CACHE_MAX:
        cache.popitem(last=False)


def parse_near(near):
    """`near` as ((lat, lng), "") when it is "lat,lng", else (None, text)."""
    near = _place_text(near, 160)
    m = re.fullmatch(r"\s*(-?\d{1,2}(?:\.\d+)?)\s*,\s*(-?\d{1,3}(?:\.\d+)?)\s*", near or "")
    if m:
        lat, lng = float(m.group(1)), float(m.group(2))
        if -90 <= lat <= 90 and -180 <= lng <= 180:
            return (lat, lng), ""
    return None, near


async def geocode_area(text):
    """(lat, lng) of an area name through the configured geocoder (Photon by default; a Nominatim /search URL works
    too), cached for 30 days; None when off, unknown or failing."""
    url = CFG["places_geocoder_url"]
    key = text.lower()
    if not url or url.lower() == "off" or not key:
        return None
    hit = _cache_get(PLACES["geo"], key, 30 * 86400)
    if hit is not None:
        return tuple(hit) if hit else None
    nominatim = "nominatim" in url or url.rstrip("/").endswith("/search")
    params = {"q": text, "format": "jsonv2", "limit": "1"} if nominatim else {"q": text, "limit": "1"}
    try:
        data = await places_http_json("geocoder", url, params=params, timeout=6)
    except PlacesError:
        return None
    point = None
    try:
        if nominatim and isinstance(data, list) and data:
            point = (float(data[0]["lat"]), float(data[0]["lon"]))
        elif isinstance(data, dict) and data.get("features"):
            lng, lat = data["features"][0]["geometry"]["coordinates"][:2]
            point = (float(lat), float(lng))
    except (KeyError, TypeError, ValueError, IndexError):
        point = None
    _cache_put(PLACES["geo"], key, list(point) if point else [])
    return point


def _place_norm(s):
    return " ".join(re.findall(r"[^\W_]+", (s or "").lower()))


def _overpass_regex(name):
    first = _place_norm(name).split(" ")[:2]
    return "".join("\\\\" + c if c in ".^$*+?()[]{}|\\" else c for c in " ".join(first))[:40]


def osm_match(row, elements):
    """The OSM element within about 150 m whose name best matches the row's, or None."""
    want = set(_place_norm(row["name"]).split())
    best, best_score = None, 0.0
    for el in elements:
        tags = el.get("tags") or {}
        lat = el.get("lat") or (el.get("center") or {}).get("lat")
        lng = el.get("lon") or (el.get("center") or {}).get("lon")
        if lat is None or lng is None or haversine_km(row["lat"], row["lng"], lat, lng) > 0.15:
            continue
        have = set(_place_norm(tags.get("name")).split())
        score = len(want & have) / max(1, len(want | have))
        if score > best_score:
            best, best_score = tags, score
    return best if best_score >= 0.5 else None


OSM_STATE = {"down_until": 0.0, "tasks": set()}
OSM_WAIT_S = 2.5                 # how long a search waits for OSM details before answering without them
OSM_BACKOFF_S = 300              # after a failed Overpass request, none for this long (busy public servers)


async def osm_enrich(rows, wait=None):
    """{place id: OSM tags} for the rows: cached details, plus one Overpass request for the rest that may run for at most
    `wait` seconds here; a slower request finishes in the background and fills the cache (for /api/places/info and
    later searches). Best effort: Overpass's public servers are often at capacity."""
    out = {}
    for _, row in rows:
        hit = _cache_get(PLACES["osm"], row["id"], OSM_CACHE_S)
        if hit:
            out[row["id"]] = hit
    task = asyncio.ensure_future(osm_fetch(rows))
    OSM_STATE["tasks"].add(task)
    task.add_done_callback(OSM_STATE["tasks"].discard)
    try:
        fresh = await asyncio.wait_for(asyncio.shield(task), OSM_WAIT_S if wait is None else wait)
    except asyncio.TimeoutError:
        return out
    return {**out, **fresh}


async def osm_fetch(rows):
    """One Overpass request for the rows without cached details; {place id: tags} of the matches."""
    out = {}
    todo = [row for _, row in rows if _cache_get(PLACES["osm"], row["id"], OSM_CACHE_S) is None]
    url = CFG["overpass_url"]
    if (not todo or not url or url.lower() == "off" or places_daily_left("overpass") <= 0
            or time.monotonic() < OSM_STATE["down_until"]):
        return out
    parts = ['nwr(around:150,%.6f,%.6f)["name"~"%s",i];' % (r["lat"], r["lng"], _overpass_regex(r["name"]))
             for r in todo if _overpass_regex(r["name"])]
    if not parts:
        return out
    query = "[out:json][timeout:8];(%s);out tags center 200;" % "".join(parts)
    places_daily_take("overpass")
    try:
        data = await places_http_json("overpass", url, data={"data": query}, timeout=12)
    except PlacesError:
        OSM_STATE["down_until"] = time.monotonic() + OSM_BACKOFF_S
        return out                                     # not cached: a later search may try again
    elements = data.get("elements") if isinstance(data, dict) else None
    keep = ("opening_hours", "phone", "contact:phone", "website", "contact:website", "wheelchair", "image", "wikimedia_commons")
    for row in todo:
        tags = osm_match(row, elements or [])
        tags = {k: v for k, v in (tags or {}).items() if k in keep and isinstance(v, str)}
        _cache_put(PLACES["osm"], row["id"], tags)
        if tags:
            out[row["id"]] = tags
    return out


def places_usage_file():
    return os.path.join(CFG["data_dir"], "places-usage.json")


def places_daily_left(kind):
    try:
        usage = json.loads(Path(places_usage_file()).read_text())
    except (OSError, ValueError):
        usage = {}
    return max(0, CFG["overpass_daily"] - usage.get(time.strftime("%Y-%m-%d"), {}).get(kind, 0))


def places_daily_take(kind):
    path, today = places_usage_file(), time.strftime("%Y-%m-%d")
    try:
        usage = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        usage = {}
    day = usage.get(today, {})
    usage = {today: {**day, kind: day.get(kind, 0) + 1}}
    os.makedirs(CFG["data_dir"], mode=0o700, exist_ok=True)
    fd = os.open(path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(usage, f)
    os.replace(path + ".tmp", path)


async def places_search(query, near=None, radius_m=None, max_results=None):
    """{"query", "near", "places": [compact…]} from the local extract, enriched from OSM; cached by its arguments."""
    if not places_enabled():
        raise PlacesError("unavailable")
    query = _place_text(query, 200)
    if not query:
        raise PlacesError("bad_request")
    try:
        n = max(1, min(PLACES_MAX, int(max_results or PLACES_MAX_DEFAULT)))
        radius = max(500, min(PLACES_RADIUS_MAX, int(radius_m or PLACES_RADIUS_DEFAULT)))
    except (TypeError, ValueError):
        raise PlacesError("bad_request")
    point, near_text = parse_near(near)
    if near_text:
        point = await geocode_area(near_text)
    key = json.dumps([query.lower(), [round(x, 3) for x in point] if point else near_text, radius, n])
    hit = _cache_get(PLACES["search"], key, CFG["places_cache_h"] * 3600)
    if hit is not None:
        return {**hit, "cached": True}
    rows = await asyncio.get_running_loop().run_in_executor(None, places_query_db, places_db_path(), query, point, radius, n)
    osm = await osm_enrich(rows)
    places = [place_compact(row, dist, osm.get(row["id"])) for dist, row in rows]
    out = {"query": query, "near": near or None, "located": bool(point), "places": places, "attribution": PLACES_ATTRIBUTION}
    if near_text and not point:
        out["warning"] = "could not find %r on the map; results are not limited to that area" % near_text
    _cache_put(PLACES["search"], key, out)
    log.info("places: search returned %d (%d with OSM details)", len(places), len(osm))
    return {**out, "cached": False}


def place_row(pid):
    """One extract row by its "place:<id>", or None."""
    if not valid_place_ref(pid) or not places_enabled():
        return None
    db = sqlite3.connect("file:%s?mode=ro" % urllib.parse.quote(places_db_path()), uri=True)
    db.row_factory = sqlite3.Row
    try:
        r = db.execute("SELECT * FROM places WHERE id = ?", (pid[6:],)).fetchone()
        return dict(r) if r else None
    except sqlite3.Error:
        return None
    finally:
        db.close()


def valid_place_ref(pid):
    return isinstance(pid, str) and pid.startswith("place:") and bool(PLACE_ID_RE.match(pid[6:]))


def places_error(exc):
    code = str(exc) or "upstream"
    status = {"unavailable": 503, "bad_request": 400, "not_found": 404}.get(code, 502)
    message = {"unavailable": "this server has no places database (run places_fetch.py)",
               "bad_request": "invalid places request", "not_found": "no such place"}.get(code, "places search failed")
    return jerr(status, code, message=message)


def tools_authorized(req):
    """Hermes' tools (the places_search plugin) use TOVE_TOOLS_KEY; the app's key works too."""
    given = req.headers.get("Authorization", "")
    given = given[7:] if given.lower().startswith("bearer ") else ""
    key = CFG.get("tools_key") or ""
    return (len(key) >= 24 and hmac.compare_digest(given.encode(), key.encode())) or live_authorized(req)


async def api_places_search(req):
    """POST /api/places/search {query, near?, radius_m?, max?} -> compact places (API.md "Places")."""
    if not tools_authorized(req):
        return jerr(401, "unauthorized")
    body, bad = await read_json(req)
    if bad:
        return bad
    try:
        out = await places_search(body.get("query"), body.get("near"), body.get("radius_m"), body.get("max"))
    except PlacesError as exc:
        return places_error(exc)
    return web.json_response(out)


async def api_places_info(req):
    """GET /api/places/info?id=place:… -> one place (the app's cards and map pins), with OSM details when cached."""
    if not live_authorized(req):
        return jerr(401, "unauthorized")
    pid = req.query.get("id", "")
    if not valid_place_ref(pid):
        return places_error(PlacesError("bad_request"))
    row = await asyncio.get_running_loop().run_in_executor(None, place_row, pid)
    if row is None:
        return places_error(PlacesError("not_found" if places_enabled() else "unavailable"))
    osm = _cache_get(PLACES["osm"], row["id"], OSM_CACHE_S) or None
    return web.json_response(place_compact(row, None, osm), headers={"Cache-Control": "private, max-age=3600"})


def places_capability():
    tiles = CFG["map_tiles"]
    meta = places_meta() if places_enabled() else {}
    return {"search": bool(meta), "attribution": PLACES_ATTRIBUTION if meta else None,
            "release": meta.get("release"), "count": meta.get("count"), "bbox": meta.get("bbox"),
            "map_tiles": tiles or None,
            "map_attribution": CFG["map_attribution"] or (OSM_ATTRIBUTION if tiles == OSM_TILES else None)}


# ---- approximate location (API.md "Location"): the app may send {"location": {"lat", "lng", "label"?}} with a chat
# turn. Coordinates are rounded to 2 decimals (about 1 km) before anything else sees them; a missing label comes from
# a reverse geocoder (OpenStreetMap Nominatim by default, cached, at most one request a second as its policy asks).
# Only the resulting one-line note is kept, on that user message (bridge-private meta), so later turns send the same
# history and Hermes' session stays stable.
GEO_CACHE = collections.OrderedDict()
GEO_LOCK = {"lock": None, "last": 0.0}
GEO_UA = "ToveBridge/1.0 (self-hosted chat app; coarse reverse geocoding)"
LOCATION_LABEL_MAX = 80


def coarse_location(value):
    """(lat, lng, label) rounded to about 1 km, or None for anything malformed."""
    if not isinstance(value, dict):
        return None
    lat, lng = value.get("lat"), value.get("lng")
    label = _place_text(value.get("label"), LOCATION_LABEL_MAX) if isinstance(value.get("label"), str) else ""
    label = re.sub(r"[\[\]{}<>`]", "", label)
    if isinstance(lat, bool) or isinstance(lng, bool) or not isinstance(lat, (int, float)) or not isinstance(lng, (int, float)):
        return (None, None, label) if label else None
    if not (-90 <= lat <= 90 and -180 <= lng <= 180):
        return None
    return round(float(lat), 2), round(float(lng), 2), label


async def reverse_geocode(lat, lng):
    """"Neighbourhood, City, CC" for rounded coordinates, or "" (geocoder off or failing)."""
    url = CFG["geocoder_url"]
    if not url or url.lower() == "off":
        return ""
    key = "%.2f,%.2f" % (lat, lng)
    if key in GEO_CACHE:
        GEO_CACHE.move_to_end(key)
        return GEO_CACHE[key]
    GEO_LOCK["lock"] = GEO_LOCK["lock"] or asyncio.Lock()
    label = ""
    async with GEO_LOCK["lock"]:
        if key in GEO_CACHE:
            return GEO_CACHE[key]
        wait = 1.0 - (time.monotonic() - GEO_LOCK["last"])
        if wait > 0:
            await asyncio.sleep(wait)
        GEO_LOCK["last"] = time.monotonic()
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=4), trust_env=False) as s:
                async with s.get(url, params={"format": "jsonv2", "lat": key.split(",")[0], "lon": key.split(",")[1],
                                              "zoom": "14", "addressdetails": "1"},
                                 headers={"User-Agent": GEO_UA, "Accept-Language": "en"}) as r:
                    data = await r.json(content_type=None) if r.status == 200 else {}
            a = data.get("address") if isinstance(data, dict) and isinstance(data.get("address"), dict) else {}
            parts = [a.get(k) for k in ("suburb", "neighbourhood", "city_district", "village", "town")]
            place = next((p for p in parts if isinstance(p, str) and p), "")
            city = next((a.get(k) for k in ("city", "town", "county", "state_district", "state") if isinstance(a.get(k), str) and a.get(k)), "")
            cc = a.get("country_code", "").upper() if isinstance(a.get("country_code"), str) else ""
            label = ", ".join(dict.fromkeys(x for x in (place, city, cc) if x))[:LOCATION_LABEL_MAX]
        except (aiohttp.ClientError, asyncio.TimeoutError, OSError, ValueError) as exc:
            log.info("reverse geocode failed: %s", type(exc).__name__)
            return ""
        GEO_CACHE[key] = label
        while len(GEO_CACHE) > 1024:
            GEO_CACHE.popitem(last=False)
    return label


async def location_note(value):
    """The context line for one chat turn, or "" when there is no usable location."""
    loc = coarse_location(value)
    if not loc:
        return ""
    lat, lng, label = loc
    if not label and lat is not None:
        label = await reverse_geocode(lat, lng)
    where = "; ".join(x for x in (label, "about %.2f, %.2f" % (lat, lng) if lat is not None else "") if x)
    return "[User's approximate location, shared by the app for this message: %s. Use it for anything local instead of asking.]" % where


@web.middleware
async def origin_middleware(req, handler):
    """`X-Device-Id` (the app's per-install id) marks the events this request causes with `origin` (API.md "Events")."""
    dev = req.headers.get("X-Device-Id")
    token = ORIGIN_DEVICE.set(dev if valid_id(dev) else None)
    try:
        return await handler(req)
    finally:
        ORIGIN_DEVICE.reset(token)


def make_app():
    app = web.Application(middlewares=[origin_middleware])
    app.on_startup.append(_open_store)
    app.on_cleanup.append(_close_store)

    async def _close_warm(_app):
        _drop_warm()
    app.on_shutdown.append(_close_warm)
    app.add_routes([web.get("/v1/realtime", realtime), web.get("/healthz", health), web.get("/", live_page),
                    web.get("/app", live_app_redirect), web.get("/app/{path:.*}", live_app),
                    web.get("/downloads/hermes-live.apk", live_apk),
                    web.post("/api/session", api_session), web.post("/api/session/warm", api_session_warm),
                    web.post("/api/delegate", api_delegate),
                    web.get("/api/job/{sid}/{jid}", api_job), web.post("/api/stop", api_stop),
                    web.get("/api/session/{sid}/jobs", api_session_jobs),
                    web.get("/api/capabilities", api_capabilities), web.post("/api/chat", api_chat),
                    web.get("/api/chat/{mid}/stream", api_chat_stream), web.post("/api/chat/{mid}/stop", api_chat_stop),
                    web.post("/api/uploads", api_upload_create), web.get("/api/uploads/{uid}", api_upload_get),
                    web.get("/api/uploads/{uid}/preview", api_upload_preview), web.delete("/api/uploads/{uid}", api_upload_delete),
                    web.get("/api/link-preview", api_link_preview), web.get("/api/favicon", api_favicon),
                    web.get("/api/image", api_image), web.get("/api/entity/info", api_entity_info),
                    web.post("/api/places/search", api_places_search), web.get("/api/places/info", api_places_info),
                    web.get("/api/settings", api_settings_get), web.put("/api/settings", api_settings_put),
                    web.get("/api/suggestions", api_suggestions), web.get("/api/usage/limits", api_usage_limits), web.post("/api/transcribe", api_transcribe),
                    web.post("/api/push/register", api_push_register), web.post("/api/notify", api_notify),
                    web.post("/api/report", api_report), web.post("/api/pair", api_pair),
                    web.get("/api/events", api_events), web.post("/api/events/test", api_events_test),
                    web.delete("/api/push/register/{device_id}", api_push_unregister), web.post("/api/push/test", api_push_test),
                    # search before {cid}: routes match in registration order
                    web.get("/api/conversations/search", api_conversations_search),
                    web.get("/api/conversations", api_conversations_list), web.post("/api/conversations", api_conversations_create),
                    web.get("/api/conversations/{cid}", api_conversation_get),
                    web.patch("/api/conversations/{cid}", api_conversation_patch),
                    web.delete("/api/conversations/{cid}", api_conversation_delete),
                    web.get("/api/conversations/{cid}/messages", api_conversation_messages),
                    web.delete("/api/conversations/{cid}/messages/{mid}", api_message_delete),
                    web.post("/api/conversations/{cid}/live-transcript", api_live_transcript)])
    return app


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    for name, value in (("BRIDGE_API_KEY", CFG["key"]), ("LIVE_PAGE_KEY", CFG["live_key"]), ("TOVE_NOTIFY_KEY", CFG["notify_key"]),
                        ("TOVE_TOOLS_KEY", CFG["tools_key"])):
        if value and len(value) < 24:
            raise SystemExit("%s must be at least 24 characters (or unset)" % name)
    if not CFG["key"] and not CFG["live_key"]:
        raise SystemExit("set LIVE_PAGE_KEY (the app's key) and/or BRIDGE_API_KEY (Open WebUI Realtime); see bridge.env.example")
    if CFG["stream_disconnect"] not in ("continue", "cancel"):
        raise SystemExit("LIVE_STREAM_DISCONNECT must be continue or cancel")
    if CFG["live_backend"] not in ("codex", "openai", "auto"):
        raise SystemExit("LIVE_BACKEND must be codex, openai or auto")
    if CFG["openai_key"] and len(CFG["openai_key"]) < 20:
        raise SystemExit("OPENAI_API_KEY looks truncated")
    lb = live_backends()
    log.info("GPT-Live backend: %s (setting %s; codex login %s, OpenAI key %s)", lb["active"], lb["choice"],
             "found" if lb["codex"] else "missing", "set" if lb["openai"] else "not set")
    for path in (CFG["codex_home"], CFG["workdir"]):          # codex warns about a missing CODEX_HOME
        try:
            os.makedirs(path, mode=0o700, exist_ok=True)
        except OSError as exc:
            log.warning("cannot create %s: %s", path, type(exc).__name__)
    app = make_app()
    log.info("gpt-live-bridge listening on %s:%s (data in %s)", CFG["host"], CFG["port"], CFG["data_dir"])
    # shutdown_timeout: open /api/events streams (and other long requests) would otherwise hold a stop until systemd
    # kills the process after 90 s; running replies are saved as `interrupted` either way.
    web.run_app(app, host=CFG["host"], port=CFG["port"], access_log=None, print=None, handle_signals=True, shutdown_timeout=5)


if __name__ == "__main__":
    main()
