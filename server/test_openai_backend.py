"""The "openai" GPT-Live backend against a mocked OpenAI Live API (session creation + sideband WebSocket) and a fake
Hermes. No real OpenAI call is made and no key is needed. Run from this folder with the bridge venv:
  ~/.local/share/gpt-live-bridge/venv/bin/python -m unittest test_openai_backend
"""
import asyncio
import importlib.util
import json
import os
import tempfile
import time
import unittest
from unittest import mock
from pathlib import Path

from aiohttp import WSMsgType, web
from aiohttp.test_utils import TestClient, TestServer

SPEC = importlib.util.spec_from_file_location("bridge_openai", Path(__file__).with_name("gpt-live-bridge.py"))
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)

KEY = "fixture-key-for-openai-testing"
AUTH = {"Authorization": "Bearer " + KEY}
OPENAI_KEY = "sk-fixture-not-a-real-openai-key-000"
OFFER = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\n"


class FakeOpenAI:
    """POST /v1/live/sessions and the /attach sideband, as the Live docs describe them."""

    def __init__(self):
        self.mode = "ok"
        self.creates, self.client_events, self.sockets = [], [], []
        self.attached = asyncio.Event()
        self.got_event = asyncio.Event()
        self.attach_auth = None
        self.reply_to_close = True

    async def create(self, req):
        body = await req.json()
        self.creates.append({"body": body, "auth": req.headers.get("Authorization"), "type": req.headers.get("Content-Type", "")})
        if self.mode == "401":
            return web.json_response({"error": {"message": "Incorrect API key provided: sk-fi***", "type": "invalid_request_error",
                                                "code": "invalid_api_key"}}, status=401)
        if self.mode == "quota":
            return web.json_response({"error": {"message": "You exceeded your current quota", "type": "insufficient_quota",
                                                "code": "insufficient_quota"}}, status=429)
        if self.mode == "rate":
            return web.json_response({"error": {"message": "Rate limit reached for concurrent sessions", "type": "rate_limit_error",
                                                "code": "rate_limit_exceeded"}}, status=429, headers={"Retry-After": "30"})
        if self.mode == "500":
            return web.json_response({"error": {"message": "internal", "type": "server_error"}}, status=500)
        if self.mode == "nosdp":
            return web.json_response({"session": {"id": "live_x"}}, status=201)
        return web.json_response({"session": {"id": "live_123"}, "transport": {"type": "webrtc", "sdp": "v=0 answer"}}, status=201)

    async def attach(self, req):
        self.attach_auth = req.headers.get("Authorization")
        self.attach_id = req.match_info["sid"]
        ws = web.WebSocketResponse()
        await ws.prepare(req)
        self.sockets.append(ws)
        self.attached.set()
        async for msg in ws:
            if msg.type != WSMsgType.TEXT:
                continue
            event = json.loads(msg.data)
            self.client_events.append(event)
            self.got_event.set()
            if event.get("type") == "session.close" and self.reply_to_close:
                await ws.send_json({"type": "session.closed", "event_id": "event_closed", "reason": "close_requested",
                                    "usage": {"seconds": 42}})
        return ws

    async def push(self, event):
        await self.sockets[-1].send_json(event)


class FakeHermes:
    def __init__(self):
        self.requests = []
        self.answer = "**Disk** is fine: `412 GB` free"

    async def handle(self, req):
        body = await req.json()
        self.requests.append(body)
        return web.json_response({"choices": [{"message": {"content": self.answer}, "finish_reason": "stop"}]})


class OpenAIBackendTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.oai, self.hermes = FakeOpenAI(), FakeHermes()
        app = web.Application()
        app.router.add_post("/v1/live/sessions", self.oai.create)
        app.router.add_get("/v1/live/sessions/{sid}/attach", self.oai.attach)
        app.router.add_post("/v1/chat/completions", self.hermes.handle)
        self.upstream = TestServer(app)
        await self.upstream.start_server()
        self.previous = dict(bridge.CFG)
        bridge.CFG.update(live_key=KEY, hermes_key="fixture-hermes-key", chat_db=os.path.join(self.temp.name, "chats.sqlite"),
                          hermes_url=str(self.upstream.make_url("/v1")), openai_url=str(self.upstream.make_url("/v1")),
                          openai_key=OPENAI_KEY, live_backend="openai", titles="simple", ui_prompt_file="off",
                          codex_home=os.path.join(self.temp.name, "codex-home"),
                          usage_file=os.path.join(self.temp.name, "openai-usage.json"), upload_dir=os.path.join(self.temp.name, "uploads"),
                          openai_daily_min=60, openai_call_min=30, call_seconds=3300)
        bridge.DIRECT["s"] = None
        bridge.USAGE["ledger"] = None
        self.client = TestClient(TestServer(bridge.make_app()))
        await self.client.start_server()
        self.store = bridge.CHAT["store"]

    async def asyncTearDown(self):
        if bridge.DIRECT["s"] is not None:
            await bridge.DIRECT["s"].close()
        await self.client.close()
        await self.upstream.close()
        bridge.CFG.clear()
        bridge.CFG.update(self.previous)
        bridge.USAGE["ledger"] = None
        self.temp.cleanup()

    async def wait_for(self, check, timeout=4.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if check():
                return True
            await asyncio.sleep(0.02)
        return False

    async def start(self, **body):
        response = await self.client.post("/api/session", json={"offer": OFFER, **body}, headers=AUTH)
        return response, await response.json()

    def events(self, kind):
        return [e for e in self.oai.client_events if e.get("type") == kind]

    # ---- session creation: the documented request and response
    async def test_sdp_exchange_and_session_config(self):
        conv = self.store.create_conversation()
        self.store.add_message(conv["id"], "user", "earlier typed question")
        self.store.add_message(conv["id"], "assistant", "earlier answer")
        response, data = await self.start(voice="cove", conversation_id=conv["id"])
        self.assertEqual(response.status, 200, data)
        self.assertEqual((data["answer"], data["backend"], data["voice"], data["conversation_id"]), ("v=0 answer", "openai", "marin", conv["id"]))
        self.assertIs(data["server_delegation"], True)
        self.assertIs(data["server_transcript"], True)
        self.assertEqual(data["max_seconds"], 1800)
        sent = self.oai.creates[-1]
        self.assertEqual(sent["auth"], "Bearer " + OPENAI_KEY)
        self.assertTrue(sent["type"].startswith("application/json"))
        body = sent["body"]
        self.assertEqual(body["transport"], {"type": "webrtc", "sdp": OFFER})
        session = body["session"]
        self.assertEqual(session["model"], "gpt-live-1")
        self.assertEqual(session["audio"], {"output": {"voice": "marin"}})
        self.assertEqual(session["delegation"], {"type": "client"})
        self.assertNotIn("format", session["audio"])                         # WebRTC negotiates the format
        self.assertIn("by voice", session["instructions"])
        self.assertEqual(session["input"], [
            {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "earlier typed question"}]},
            {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "earlier answer"}]}])
        self.assertNotIn(OPENAI_KEY, json.dumps(data))
        self.assertTrue(await self.wait_for(self.oai.attached.is_set))
        self.assertEqual((self.oai.attach_auth, self.oai.attach_id), ("Bearer " + OPENAI_KEY, "live_123"))

    async def test_both_backends_tell_the_voice_its_name(self):
        """Round 6 D3: asked its name, GPT-Live said "ChatGPT". Both backends now send the configured name with explicit
        identity rules: openai as `instructions`, codex as the `prompt` of thread/realtime/start."""
        bridge.CFG["assistant_name"] = "Tove"
        response, data = await self.start(voice="cove")
        self.assertEqual(response.status, 200, data)
        sent = self.oai.creates[-1]["body"]["session"]["instructions"]
        for text in (sent, bridge.live_persona()):
            self.assertTrue(text.startswith("You are Tove,"))
            self.assertIn("Your name is Tove.", text)
            self.assertIn("say you are Tove", text)
            self.assertIn("Never call yourself ChatGPT, Codex, GPT or an OpenAI assistant", text)
            self.assertNotIn("Hermes.", text.split("HOW TO SOUND HUMAN")[0].split("WHO YOU ARE")[1])
        # codex: run the real start() against a fake app-server and capture what it sends.
        calls = []

        class FakeProc:
            class stdin:
                @staticmethod
                def write(_b): pass

                @staticmethod
                async def drain(): pass

            class stdout:
                @staticmethod
                async def readline():
                    await asyncio.sleep(3600)

        async def fake_exec(*a, **kw):
            return FakeProc()

        ds = bridge.DirectSession()

        async def fake_rpc(method, params, timeout=30):
            calls.append((method, params))
            if method == "thread/realtime/start":
                ds.notifs.put_nowait({"method": "thread/realtime/sdp", "params": {"sdp": "v=0 codex"}})
            return {"thread": {"id": "t1"}} if method == "thread/start" else {}

        with mock.patch.object(bridge.asyncio, "create_subprocess_exec", fake_exec), mock.patch.object(ds, "rpc", fake_rpc):
            self.assertEqual(await ds.start(OFFER, "cove"), "v=0 codex")
        for t in ds.tasks:
            t.cancel()
        prompt = [p for m, p in calls if m == "thread/realtime/start"][0]["prompt"]
        self.assertEqual(prompt, bridge.live_persona())
        self.assertIn("Your name is Tove.", prompt)

    async def test_voice_choice(self):
        for requested, expected in (("vesper", "vesper"), ("arbor", "meridian"), ("nonsense", "marin"), (None, "marin")):
            with self.subTest(requested=requested):
                _, data = await self.start(**({"voice": requested} if requested else {}))
                self.assertEqual(self.oai.creates[-1]["body"]["session"]["audio"]["output"]["voice"], expected)
                self.assertEqual(data["voice"], expected)
        bridge.CFG["openai_voice"] = "gleam"
        await self.start()
        self.assertEqual(self.oai.creates[-1]["body"]["session"]["audio"]["output"]["voice"], "gleam")

    # ---- the sideband: delegation, results, transcript, usage
    async def test_delegation_runs_hermes_and_speaks_the_result(self):
        conv = self.store.create_conversation()
        _, data = await self.start(conversation_id=conv["id"])
        self.assertTrue(await self.wait_for(self.oai.attached.is_set))
        await self.oai.push({"type": "session.started", "event_id": "e0", "session": {"id": "live_123"}})
        await self.oai.push({"type": "session.input_transcript.delta", "event_id": "e1", "delta": "Hi there.", "start_ms": 100, "end_ms": 600})
        await self.oai.push({"type": "session.output_transcript.delta", "event_id": "e2", "delta": "Hey! What can I do?", "start_ms": 700})
        await self.oai.push({"type": "session.input_transcript.delta", "event_id": "e3", "delta": "How much space is left", "start_ms": 2000})
        await self.oai.push({"type": "session.input_transcript.delta", "event_id": "e4", "delta": " on the storage box?", "start_ms": 2600})
        created = {"type": "session.delegation.created", "event_id": "e5", "offset_ms": 3000,
                   "delegation": {"id": "item_abc", "type": "delegation", "target": "client"}}
        await self.oai.push(created)
        await self.oai.push(created)                                          # replayed after a re-attach: run once
        self.assertTrue(await self.wait_for(lambda: self.events("session.commentary.append")), self.oai.client_events)
        said = self.events("session.commentary.append")
        self.assertEqual(len(said), 1)
        self.assertEqual(said[0]["delegation_id"], "item_abc")
        self.assertEqual(said[0]["content"], "Disk is fine: 412 GB free")
        self.assertTrue(said[0]["event_id"].startswith("evt_"))
        self.assertEqual(len(self.hermes.requests), 1)
        task = self.hermes.requests[0]["messages"][-1]["content"]
        self.assertIn("How much space is left on the storage box?", task)
        self.assertIn("User: Hi there.", task)                                # earlier call context
        self.assertTrue(task.startswith(bridge.TASK_CHAT_NOTE))                 # a linked call: the result goes into the chat
        jobs = await (await self.client.get("/api/session/%s/jobs" % data["session"], headers=AUTH)).json()
        self.assertEqual((jobs["backend"], jobs["sideband"], len(jobs["jobs"])), ("openai", "attached", 1))
        self.assertEqual((jobs["jobs"][0]["status"], jobs["jobs"][0]["request"]), ("done", "How much space is left on the storage box?"))
        self.assertEqual(jobs["jobs"][0]["markdown"], "**Disk** is fine: `412 GB` free")
        self.assertEqual((await self.client.get("/api/session/nope/jobs", headers=AUTH)).status, 404)
        self.assertEqual((await self.client.get("/api/session/%s/jobs" % data["session"])).status, 401)

        await self.oai.push({"type": "session.usage.updated", "event_id": "e6", "usage": {"seconds": 12}})
        self.assertTrue(await self.wait_for(lambda: bridge.DIRECT["s"] is not None and bridge.DIRECT["s"].usage_s == 12))
        stop = await self.client.post("/api/stop", json={"session": data["session"]}, headers=AUTH)
        self.assertEqual(stop.status, 200)
        self.assertEqual(len(self.events("session.close")), 1)
        self.assertIsNone(bridge.DIRECT["s"])
        ledger = json.loads(Path(bridge.CFG["usage_file"]).read_text())
        self.assertEqual(ledger["seconds"], 42)                             # the final usage from session.closed
        self.assertEqual(os.stat(bridge.CFG["usage_file"]).st_mode & 0o777, 0o600)
        msgs = self.store.messages(conv["id"])[0]
        voice = [(m["role"], m["text"]) for m in msgs if m["source"] == "voice"]
        self.assertEqual(voice, [("user", "Hi there."), ("assistant", "Hey! What can I do?"),
                                 ("user", "How much space is left on the storage box?")])
        tasks = [m for m in msgs if m["source"] == "task"]
        self.assertEqual((len(tasks), tasks[0]["meta"]["task"]), (1, "How much space is left on the storage box?"))
        self.assertEqual(self.store.get_conversation(conv["id"])["title"], "Hi there")

    async def test_failed_task_and_missing_transcript_are_spoken(self):
        _, data = await self.start()
        self.assertTrue(await self.wait_for(self.oai.attached.is_set))
        await self.oai.push({"type": "session.delegation.created", "event_id": "d1", "delegation": {"id": "item_1", "target": "client"}})
        self.assertTrue(await self.wait_for(lambda: self.events("session.commentary.append")))
        self.assertIn("didn't catch", self.events("session.commentary.append")[0]["content"])
        self.hermes.answer = None
        bridge.CFG["hermes_url"] = "http://127.0.0.1:9/v1"                   # unreachable: the job fails
        await self.oai.push({"type": "session.input_transcript.delta", "event_id": "t1", "delta": "restart the box"})
        await self.oai.push({"type": "session.delegation.created", "event_id": "d2", "delegation": {"id": "item_2", "target": "client"}})
        self.assertTrue(await self.wait_for(lambda: len(self.events("session.commentary.append")) == 2, 6))
        last = self.events("session.commentary.append")[1]
        self.assertEqual(last["delegation_id"], "item_2")
        self.assertIn("failed", last["content"])

    async def test_long_results_are_clipped_for_the_voice(self):
        text = "First sentence is here. " * 200
        clipped = bridge.clip_for_voice(text)
        self.assertLessEqual(len(clipped), bridge.COMMENTARY_CHARS + 40)
        self.assertTrue(clipped.endswith("(The full answer is in the chat.)"))
        self.assertEqual(bridge.clip_for_voice("short  \n text"), "short text")

    async def test_remote_close_books_usage_and_frees_the_slot(self):
        _, data = await self.start()
        self.assertTrue(await self.wait_for(self.oai.attached.is_set))
        await self.oai.push({"type": "session.closed", "event_id": "c1", "reason": "expired", "usage": {"seconds": 90}})
        self.assertTrue(await self.wait_for(lambda: bridge.DIRECT["s"] is None))
        self.assertEqual(self.events("session.close"), [])                  # already closed by OpenAI
        self.assertEqual(bridge.usage_ledger().used(), 90)

    async def test_call_time_limit_closes_the_session(self):
        bridge.CFG["call_seconds"] = 0.3
        _, data = await self.start()
        self.assertEqual(data["max_seconds"], 0)
        self.assertTrue(await self.wait_for(lambda: self.events("session.close"), 4))
        self.assertTrue(await self.wait_for(lambda: bridge.DIRECT["s"] is None))

    # ---- cost control
    async def test_daily_budget(self):
        bridge.usage_ledger().add(59.5 * 60)
        response, data = await self.start()
        self.assertEqual((response.status, data["code"], data["error"]), (429, "budget_exceeded", "budget_exceeded"))
        self.assertEqual(response.headers["Retry-After"], str(data["retry_after_s"]))
        self.assertGreater(data["retry_after_s"], 0)
        self.assertEqual(self.oai.creates, [])                               # nothing was billed
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertEqual(caps["live_backends"]["openai"]["minutes_left_today"], 0.5)
        # 10 minutes left: the call is capped at what is left, not at OPENAI_MAX_CALL_MINUTES.
        bridge.USAGE["ledger"] = None
        Path(bridge.CFG["usage_file"]).write_text(json.dumps({"day": bridge.UsageLedger.today(), "seconds": 50 * 60}))
        response, data = await self.start()
        self.assertEqual(response.status, 200, data)
        self.assertTrue(585 <= data["max_seconds"] <= 600, data["max_seconds"])
        # Yesterday's usage does not count today; 0 turns the budget off.
        Path(bridge.CFG["usage_file"]).write_text(json.dumps({"day": "2000-01-01", "seconds": 999999}))
        self.assertEqual(bridge.UsageLedger(bridge.CFG["usage_file"]).used(), 0)
        bridge.CFG["openai_daily_min"] = 0
        self.assertIsNone(bridge.openai_seconds_left())

    # ---- errors
    async def test_openai_errors_map_to_bridge_codes(self):
        cases = [("401", 502, "auth_failed", None, None), ("quota", 429, "usage_limit", None, "quota"),
                 ("rate", 429, "usage_limit", 30, "rate_limit"), ("500", 502, "start_failed", None, None),
                 ("nosdp", 502, "start_failed", None, None)]
        for mode, status, code, after, reason in cases:
            with self.subTest(mode=mode):
                self.oai.mode = mode
                response, data = await self.start()
                self.assertEqual((response.status, data["code"]), (status, code))
                self.assertEqual(data.get("backend"), "openai")
                if code == "usage_limit":
                    self.assertEqual((data["retry_after_s"], data["reason"]), (after, reason))
                    self.assertEqual(response.headers.get("Retry-After"), None if after is None else str(after))
                dumped = json.dumps(data)
                self.assertNotIn("sk-fi", dumped)                            # OpenAI's text is never echoed
                self.assertIsNone(bridge.DIRECT["s"])
        self.assertEqual(bridge.usage_ledger().used(), 0)                    # failed creations bill nothing here
        bridge.CFG["openai_key"] = ""
        response, data = await self.start()
        self.assertEqual((response.status, data["code"]), (503, "openai_unconfigured"))

    # ---- backend selection and capabilities
    async def test_auto_selection_and_capabilities(self):
        auth = os.path.join(bridge.CFG["codex_home"], "auth.json")
        bridge.CFG["live_backend"] = "auto"
        self.assertEqual(bridge.live_backends()["active"], "openai")         # no codex login, key set
        os.makedirs(bridge.CFG["codex_home"])
        Path(auth).write_text("{}")
        self.assertEqual(bridge.live_backends()["active"], "codex")          # codex login wins
        bridge.CFG["openai_key"] = ""
        os.remove(auth)
        self.assertEqual(bridge.live_backends()["active"], "codex")          # nothing set up: codex explains the login
        bridge.CFG["live_backend"] = "codex"
        bridge.CFG["openai_key"] = OPENAI_KEY
        self.assertEqual(bridge.live_backends()["active"], "codex")

        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertEqual(caps["live_backend"], "codex")
        self.assertEqual((caps["live_backends"]["codex"]["active"], caps["live_backends"]["openai"]["available"]), (True, True))
        self.assertIn("cove", caps["voices"])
        bridge.CFG["live_backend"] = "openai"
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertEqual((caps["live_backend"], caps["default_voice"]), ("openai", "marin"))
        self.assertIn("meridian", caps["voices"])
        oai = caps["live_backends"]["openai"]
        self.assertEqual((oai["model"], oai["max_call_s"], oai["daily_minutes"], oai["server_delegation"]), ("gpt-live-1", 1800, 60, True))
        self.assertNotIn(OPENAI_KEY, json.dumps(caps))
        self.assertNotIn("sk-", json.dumps(caps))
        health = await (await self.client.get("/healthz")).json()
        self.assertEqual(health["live_backend"], "openai")

    def test_config(self):
        cfg = bridge.load_config({"PATH": ""})
        self.assertEqual((cfg["live_backend"], cfg["openai_model"], cfg["openai_voice"], cfg["openai_call_min"], cfg["openai_daily_min"]),
                         ("auto", "gpt-live-1", "marin", 30, 60))
        self.assertEqual(cfg["openai_url"], "https://api.openai.com/v1")
        self.assertEqual(cfg["openai_key"], "")
        moved = bridge.load_config({"BRIDGE_DATA_DIR": "/data", "LIVE_BACKEND": "OpenAI", "OPENAI_DAILY_MINUTES": "0"})
        self.assertEqual((moved["usage_file"], moved["live_backend"], moved["openai_daily_min"]), ("/data/openai-usage.json", "openai", 0))
        with self.assertRaises(SystemExit):
            bridge.load_config({"OPENAI_MAX_CALL_MINUTES": "0"})


if __name__ == "__main__":
    unittest.main()
