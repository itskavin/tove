"""Chat, history, capabilities, live links and start-error mapping, against a fake Hermes and a mocked codex.

Nothing here opens a GPT-Live session or calls the real Hermes. Run with the bridge venv, from this folder:
  ~/.local/share/gpt-live-bridge/venv/bin/python -m unittest test_app_routes test_deploy_app test_chat_api
"""
import asyncio
import importlib.util
import json
import os
import stat
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

SPEC = importlib.util.spec_from_file_location("bridge_chat", Path(__file__).with_name("gpt-live-bridge.py"))
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)

KEY = "fixture-key-for-chat-testing-only"
AUTH = {"Authorization": "Bearer " + KEY}


class FakeHermes:
    """OpenAI-compatible /v1/chat/completions with a scripted behaviour per test."""

    def __init__(self):
        self.mode = "stream"
        self.requests = []
        self.disconnected = asyncio.Event()
        self.release = asyncio.Event()                  # "gated": the reply finishes only once this is set
        self.fail_delay = 0.0
        self.title = '"Greeting The World."'

    def chunk(self, delta, finish=None, usage=None):
        obj = {"object": "chat.completion.chunk", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
        if usage:
            obj["usage"] = usage
        return ("data: " + json.dumps(obj) + "\n\n").encode()

    async def handle(self, req):
        body = await req.json()
        self.requests.append({"body": body, "auth": req.headers.get("Authorization")})
        if not body.get("stream"):                        # the title call
            return web.json_response({"choices": [{"message": {"content": self.title}, "finish_reason": "stop"}]})
        if self.mode == "fail":
            await asyncio.sleep(self.fail_delay)
            return web.json_response({"error": {"message": "boom"}}, status=500)
        if self.mode == "json":
            return web.json_response({"choices": [{"message": {"content": "Whole reply at once."}, "finish_reason": "stop"}],
                                      "usage": {"prompt_tokens": 3, "completion_tokens": 4, "total_tokens": 7}})
        resp = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
        await resp.prepare(req)
        await resp.write(self.chunk({"role": "assistant"}))
        if self.mode == "gated":
            await resp.write(self.chunk({"content": "partial"}))
            try:
                while not self.release.is_set():
                    try:
                        await asyncio.wait_for(self.release.wait(), 0.05)
                    except asyncio.TimeoutError:
                        await resp.write(b": tick\n\n")    # notices a closed connection
                await resp.write(self.chunk({"content": " rest"}))
                await resp.write(self.chunk({}, "stop"))
                await resp.write(b"data: [DONE]\n\n")
            except (ConnectionResetError, ConnectionError):
                self.disconnected.set()
            except asyncio.CancelledError:
                self.disconnected.set()
                raise
            return resp
        if self.mode == "slow":
            await resp.write(self.chunk({"content": "partial"}))
            try:
                for _ in range(200):
                    await asyncio.sleep(0.05)
                    await resp.write(b": tick\n\n")
            except (ConnectionResetError, ConnectionError):
                self.disconnected.set()
            except asyncio.CancelledError:
                self.disconnected.set()
                raise
            self.finished_slow = True
            return resp
        if self.mode == "leading":                        # the shape of a real reply (QA 15 November 2026)
            await resp.write(self.chunk({"reasoning_content": "**Reviewing coding request**"}))
            await resp.write(self.chunk({"reasoning_content": "\n\n"}))
            for piece in ("\n", "\n", "  ", "    code", "\n\n", "Done"):
                await resp.write(self.chunk({"content": piece}))
            await resp.write(self.chunk({}, "stop"))
            await resp.write(b"data: [DONE]\n\n")
            return resp
        await resp.write(b'event: hermes.tool.progress\ndata: {"tool": "terminal", "emoji": "x", "label": "df -h", '
                         b'"toolCallId": "call_1", "status": "running"}\n\n')
        await resp.write(self.chunk({"content": "Hello"}))
        await resp.write(self.chunk({"content": " world"}))
        if self.mode == "truncated":
            return resp
        await resp.write(self.chunk({}, "stop", {"prompt_tokens": 10, "completion_tokens": 2, "total_tokens": 12}))
        await resp.write(b"data: [DONE]\n\n")
        return resp


async def read_sse(response):
    events, event, data = [], None, []
    async for raw in response.content:
        line = raw.decode().rstrip("\n")
        if not line:
            if event:
                events.append((event, json.loads("\n".join(data))))
            event, data = None, []
        elif line.startswith("event: "):
            event = line[7:]
        elif line.startswith("data: "):
            data.append(line[6:])
    return events


class FakeDistributor:
    """A UnifiedPush endpoint (what ntfy would be): records each push, answers with `status`."""

    def __init__(self):
        self.pushes, self.status, self.arrived = [], 200, asyncio.Event()

    async def handle(self, req):
        self.pushes.append({"device": req.match_info["name"], "type": req.headers.get("Content-Type"), "body": await req.json()})
        self.arrived.set()
        return web.Response(status=self.status)


async def read_sse_ids(response, until=None):
    """[(id or None, event, data)]; stops after the first event for which until(event, data) is true."""
    events, eid, event, data = [], None, None, []
    async for raw in response.content:
        line = raw.decode().rstrip("\n")
        if not line:
            if event:
                events.append((eid, event, json.loads("\n".join(data))))
                if until and until(event, events[-1][2]):
                    break
            eid, event, data = None, None, []
        elif line.startswith("id: "):
            eid = int(line[4:])
        elif line.startswith("event: "):
            event = line[7:]
        elif line.startswith("data: "):
            data.append(line[6:])
    return events


class ChatApiTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.temp.name, "sub", "chats.sqlite")
        self.fake = FakeHermes()
        hermes_app = web.Application()
        hermes_app.router.add_post("/v1/chat/completions", self.fake.handle)
        self.hermes = TestServer(hermes_app)
        await self.hermes.start_server()
        self.dist = FakeDistributor()
        dist_app = web.Application()
        dist_app.router.add_post("/up/{name}", self.dist.handle)
        self.distributor = TestServer(dist_app)
        await self.distributor.start_server()
        bridge.PUSH_SENT.clear()
        self.previous = dict(bridge.CFG)
        bridge.CFG.update(live_key=KEY, hermes_key="fixture-hermes-key", chat_db=self.db_path, max_chats=2, titles="hermes",
                          hermes_url=str(self.hermes.make_url("/v1")), openai_key="",
                          usage_file=os.path.join(self.temp.name, "openai-usage.json"),
                          upload_dir=os.path.join(self.temp.name, "uploads"), hermes_upload_dir="", web_search="auto",
                          ui_prompt_file=os.path.join(self.temp.name, "no-ui-prompt.md"), ui_prompt_default="")
        bridge.DIRECT["s"] = None
        self.client = TestClient(TestServer(bridge.make_app()))
        await self.client.start_server()
        self.store = bridge.CHAT["store"]

    async def asyncTearDown(self):
        if bridge.DIRECT["s"] is not None:
            await bridge.DIRECT["s"].close()
        await self.client.close()
        await self.hermes.close()
        await self.distributor.close()
        bridge.CFG.clear()
        bridge.CFG.update(self.previous)
        bridge.CHAT["active"] = 0
        self.temp.cleanup()

    async def chat(self, **body):
        response = await self.client.post("/api/chat", json=body, headers=AUTH)
        return response, (await read_sse(response) if response.status == 200 else await response.json())

    async def wait_for(self, check, timeout=3.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if check():
                return True
            await asyncio.sleep(0.02)
        return False

    # ---- capabilities and auth
    async def test_capabilities_and_health(self):
        self.assertEqual((await self.client.get("/api/capabilities")).status, 401)
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertEqual(caps["version"], 2)
        for flag in ("chat", "history", "search", "effort", "status_events", "live_link", "live_transcript", "error_codes"):
            self.assertIs(caps[flag], True, flag)
        self.assertIs(caps["attachments"], True)                     # images, with vision (no HERMES_UPLOAD_DIR here)
        self.assertEqual(caps["attachment_limits"]["mimes"], ["image/jpeg", "image/png", "image/webp"])
        self.assertIs(caps["language"], False)
        self.assertEqual(caps["efforts"], ["instant", "medium", "high"])
        self.assertEqual(caps["limits"]["message_chars"], 8000)
        self.assertEqual(caps["stream"], "sse")
        self.assertIs(caps["resumable_stream"], True)
        self.assertIs(caps["stop_endpoint"], True)
        self.assertIs(caps["disconnect_cancels"], False)
        self.assertEqual(caps["limits"]["stream_keep_s"], 300)
        self.assertEqual((caps["push"], caps["push_previews"], caps["limits"]["push_preview_chars"]), ("unifiedpush", True, 120))
        self.assertNotIn("fixture-hermes-key", json.dumps(caps))
        health = await (await self.client.get("/healthz")).json()
        self.assertEqual(health["api_version"], 2)

    async def test_capabilities_without_hermes_key(self):
        bridge.CFG["hermes_key"] = ""
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertFalse(caps["chat"])
        self.assertFalse(caps["effort"])
        self.assertTrue(caps["history"])

    async def test_every_new_route_requires_the_key(self):
        conv = self.store.create_conversation()
        routes = [("GET", "/api/capabilities"), ("POST", "/api/chat"), ("GET", "/api/conversations"), ("POST", "/api/conversations"),
                  ("GET", "/api/conversations/search?q=x"), ("GET", "/api/conversations/" + conv["id"]),
                  ("PATCH", "/api/conversations/" + conv["id"]), ("DELETE", "/api/conversations/" + conv["id"]),
                  ("GET", "/api/conversations/%s/messages" % conv["id"]), ("DELETE", "/api/conversations/%s/messages/x" % conv["id"]),
                  ("POST", "/api/conversations/%s/live-transcript" % conv["id"]),
                  ("GET", "/api/chat/x/stream"), ("POST", "/api/chat/x/stop"), ("POST", "/api/push/register"),
                  ("DELETE", "/api/push/register/x"), ("POST", "/api/push/test")]
        for headers in ({}, {"Authorization": "Bearer " + "y" * 40}):
            for method, path in routes:
                with self.subTest(method=method, path=path, headers=bool(headers)):
                    response = await self.client.request(method, path, json={}, headers=headers)
                    self.assertEqual(response.status, 401)
                    self.assertEqual((await response.json())["code"], "unauthorized")
        self.assertIsNotNone(self.store.get_conversation(conv["id"]))

    # ---- reply effort -> reasoning effort + service tier
    async def test_effort_selects_tier_and_reasoning(self):
        for effort, reasoning, provider in (("instant", "low", None), ("medium", "medium", "cliproxy-standard"),
                                            ("high", "high", "cliproxy-standard")):
            with self.subTest(effort=effort):
                _, events = await self.chat(message={"text": "tier check " + effort}, effort=effort)
                self.assertEqual(events[-1][0], "done")
                body = self.fake.requests[-1]["body"]
                self.assertEqual(body["model_options"], {"reasoning_effort": reasoning})
                self.assertEqual(body.get("provider"), provider)

    async def test_effort_tier_switches(self):
        bridge.CFG["standard_provider"] = ""                 # HERMES_STANDARD_PROVIDER=off: every reply fast
        await self.chat(message={"text": "high but fast"}, effort="high")
        self.assertNotIn("provider", self.fake.requests[-1]["body"])
        bridge.CFG.update(standard_provider="cliproxy-standard", chat_default_effort="none")   # unknown -> Hermes defaults
        await self.chat(message={"text": "no default"})
        self.assertNotIn("model_options", self.fake.requests[-1]["body"])
        self.assertNotIn("provider", self.fake.requests[-1]["body"])

    def test_effort_fields_and_config(self):
        self.assertEqual(bridge.hermes_effort_fields(None), {})   # live-call tasks: Hermes defaults (fast tier)
        cfg = bridge.load_config({})
        self.assertEqual((cfg["standard_provider"], cfg["chat_default_effort"]), ("cliproxy-standard", "medium"))
        self.assertEqual(bridge.load_config({"HERMES_STANDARD_PROVIDER": "off"})["standard_provider"], "")

    # ---- streaming chat
    async def test_chat_streams_and_persists(self):
        response, events = await self.chat(message={"text": "hello there, please greet the whole wide world today"},
                                           effort="instant", client_msg_id="c-1")
        self.assertEqual(response.status, 200)
        self.assertTrue(response.headers["Content-Type"].startswith("text/event-stream"))
        kinds = [k for k, _ in events]
        self.assertEqual([k for k in kinds if not k.startswith("step.")], ["meta", "status", "delta", "delta", "done"])
        self.assertEqual(kinds, ["meta", "status", "step.start", "delta", "delta", "step.end", "done"])   # the tool step (API.md "Steps")
        meta, status, done = events[0][1], events[1][1], events[-1][1]
        self.assertTrue(meta["created_conversation"])
        self.assertEqual(meta["client_msg_id"], "c-1")
        self.assertEqual(status, {"label": "df -h", "state": "running", "tool": "terminal", "id": "call_1", "emoji": "x"})
        self.assertEqual("".join(e["text"] for k, e in events if k == "delta"), "Hello world")
        self.assertEqual(done["message_id"], meta["message_id"])
        self.assertEqual(done["usage"]["total_tokens"], 12)
        self.assertTrue(done["title_pending"])
        self.assertEqual(done["title"], "Greet the whole wide world today")
        sent = self.fake.requests[0]
        self.assertEqual(sent["auth"], "Bearer fixture-hermes-key")
        self.assertTrue(sent["body"]["stream"])
        self.assertEqual(sent["body"]["model_options"], {"reasoning_effort": "low"})
        self.assertNotIn("provider", sent["body"])          # Instant stays on Hermes' default (fast-tier) provider
        self.assertEqual(sent["body"]["messages"][-1]["content"], "hello there, please greet the whole wide world today")
        cid = meta["conversation_id"]
        msgs, _ = self.store.messages(cid)
        self.assertEqual([(m["role"], m["status"], m["text"]) for m in msgs],
                         [("user", "complete", "hello there, please greet the whole wide world today"), ("assistant", "complete", "Hello world")])
        self.assertTrue(await self.wait_for(lambda: self.store.get_conversation(cid)["title"] == "Greeting The World"))
        self.assertEqual(self.store.get_conversation(cid)["title_source"], "hermes")

    async def test_chat_sends_history_and_medium_effort_when_absent(self):
        _, events = await self.chat(message={"text": "first"})
        cid = events[0][1]["conversation_id"]
        _, events = await self.chat(conversation_id=cid, message={"text": "second"})
        self.assertFalse(events[0][1]["created_conversation"])
        body = self.fake.requests[-1]["body"]
        # No effort (older app builds) runs as Medium: default tier + medium reasoning (API.md "Reply effort")
        self.assertEqual((body["model_options"], body["provider"]), ({"reasoning_effort": "medium"}, "cliproxy-standard"))
        self.assertNotIn("effort", self.store.messages(cid)[0][-1]["meta"] or {})   # stored meta keeps what the app sent
        self.assertEqual([(m["role"], m["content"]) for m in body["messages"]],
                         [("user", "first"), ("assistant", "Hello world"), ("user", "second")])
        self.assertFalse(events[-1][1]["title_pending"])     # only the first reply asks for a title

    async def test_leading_blank_lines_are_dropped_and_thinking_stays_open_through_them(self):
        self.fake.mode = "leading"
        _, events = await self.chat(message={"text": "dedupe a list in python"})
        kinds = [k for k, _ in events]
        self.assertEqual(kinds, ["meta", "step.start", "step.delta", "step.delta", "step.end",
                                 "delta", "delta", "delta", "done"])
        thinking = events[4][1]["step"]
        self.assertEqual((thinking["kind"], thinking["text"], thinking["offset"]), ("thinking", "**Reviewing coding request**\n\n", 0))
        text = "".join(d["text"] for k, d in events if k == "delta")
        self.assertEqual(text, "      code\n\nDone")                # blank lines gone, the first line's indent kept
        msg = self.store.get_message(events[0][1]["message_id"])
        self.assertEqual((msg["status"], msg["text"]), ("complete", text))

    async def test_non_streaming_upstream_becomes_one_delta(self):
        self.fake.mode = "json"
        _, events = await self.chat(message={"text": "hi"})
        self.assertEqual([k for k, _ in events], ["meta", "delta", "done"])
        self.assertEqual(events[1][1]["text"], "Whole reply at once.")
        self.assertEqual(events[2][1]["usage"]["total_tokens"], 7)

    async def test_upstream_failure_is_an_error_event_and_retry_replaces_it(self):
        self.fake.mode = "fail"
        _, events = await self.chat(message={"text": "hi"})
        self.assertEqual([k for k, _ in events], ["meta", "error"])
        self.assertEqual(events[1][1]["code"], "hermes_error")
        cid = events[0][1]["conversation_id"]
        self.assertEqual(self.store.get_message(events[0][1]["message_id"])["status"], "error")
        self.fake.mode = "stream"
        _, events = await self.chat(conversation_id=cid, retry=True)
        self.assertEqual(events[-1][0], "done")
        msgs, _ = self.store.messages(cid)
        self.assertEqual([(m["role"], m["status"]) for m in msgs], [("user", "complete"), ("assistant", "complete")])
        self.assertEqual(self.fake.requests[-1]["body"]["messages"], [{"role": "user", "content": "hi"}])

    async def test_truncated_upstream_is_marked_error_with_partial_text(self):
        self.fake.mode = "truncated"
        _, events = await self.chat(message={"text": "hi"})
        self.assertEqual(events[-1][0], "error")
        self.assertEqual(events[-1][1]["code"], "hermes_incomplete")
        msg = self.store.get_message(events[0][1]["message_id"])
        self.assertEqual((msg["status"], msg["text"], msg["meta"]["error_code"]), ("error", "Hello world", "hermes_incomplete"))

    async def test_cancel_mode_disconnect_cancels_upstream_and_keeps_partial(self):
        bridge.CFG["stream_disconnect"] = "cancel"           # LIVE_STREAM_DISCONNECT=cancel: the old behaviour
        self.fake.mode = "slow"
        response = await self.client.post("/api/chat", json={"message": {"text": "long job"}}, headers=AUTH)
        meta = None
        async for raw in response.content:
            line = raw.decode()
            if line.startswith("data: ") and meta is None:
                meta = json.loads(line[6:])
            if '"partial"' in line:
                break
        response.close()
        self.assertTrue(await self.wait_for(lambda: self.store.get_message(meta["message_id"])["status"] == "cancelled", 5))
        msg = self.store.get_message(meta["message_id"])
        self.assertEqual((msg["text"], msg["meta"]["stop_reason"]), ("partial", "disconnect"))
        await asyncio.wait_for(self.fake.disconnected.wait(), 5)
        self.assertEqual(bridge.CHAT["active"], 0)

    # ---- resumable streams
    async def start_gated(self, **body):
        """POST /api/chat in gated mode and read up to the first delta; returns (response, events so far)."""
        self.fake.mode = "gated"
        response = await self.client.post("/api/chat", json={"message": {"text": "long job"}, **body}, headers=AUTH)
        self.assertEqual(response.status, 200)
        events = await read_sse_ids(response, until=lambda e, d: e == "delta")
        return response, events

    async def resume(self, mid, last=None, query=False, until=None):
        headers = dict(AUTH)
        path = "/api/chat/%s/stream" % mid
        if last is not None and query:
            path += "?last_event_id=%d" % last
        elif last is not None:
            headers["Last-Event-ID"] = str(last)
        response = await self.client.get(path, headers=headers)
        return response, (await read_sse_ids(response, until) if response.status == 200 else await response.json())

    async def test_disconnect_does_not_cancel_and_stop_endpoint_keeps_partial(self):
        response, events = await self.start_gated()
        mid = events[0][2]["message_id"]
        self.assertEqual([(i, e) for i, e, _ in events], [(1, "meta"), (2, "delta")])
        self.assertTrue(events[0][2]["resumable"])
        response.close()
        await asyncio.sleep(1.3)                               # longer than the reader's disconnect check
        self.assertFalse(self.fake.disconnected.is_set())
        self.assertEqual(self.store.get_message(mid)["status"], "streaming")
        self.assertEqual(len(bridge.running_jobs()), 1)
        health = await (await self.client.get("/healthz")).json()
        self.assertEqual(health["active_chats"], 1)

        self.assertEqual((await self.client.post("/api/chat/%s/stop" % mid)).status, 401)
        stop = await (await self.client.post("/api/chat/%s/stop" % mid, headers=AUTH)).json()
        self.assertEqual((stop["stopped"], stop["status"], stop["text"]), (True, "cancelled", "partial"))
        msg = self.store.get_message(mid)
        self.assertEqual((msg["status"], msg["text"], msg["meta"]["stop_reason"]), ("cancelled", "partial", "user"))
        await asyncio.wait_for(self.fake.disconnected.wait(), 5)          # Hermes' request was closed
        self.assertEqual((bridge.CHAT["active"], bridge.running_jobs()), (0, []))
        again = await (await self.client.post("/api/chat/%s/stop" % mid, headers=AUTH)).json()
        self.assertEqual((again["stopped"], again["status"]), (False, "cancelled"))
        _, tail = await self.resume(mid, 2)
        self.assertEqual([(i, e, d.get("reason")) for i, e, d in tail], [(3, "stopped", "user")])
        missing = await self.client.post("/api/chat/nope/stop", headers=AUTH)
        self.assertEqual((missing.status, (await missing.json())["code"]), (404, "not_found"))

    async def test_stop_reaches_an_open_post_stream(self):
        response, events = await self.start_gated()
        mid = events[0][2]["message_id"]
        stop = asyncio.ensure_future(self.client.post("/api/chat/%s/stop" % mid, headers=AUTH))
        rest = await read_sse_ids(response)
        self.assertEqual([(i, e) for i, e, _ in rest], [(3, "stopped")])
        self.assertEqual((await (await stop).json())["status"], "cancelled")

    async def test_resume_replays_from_an_id_then_follows_live(self):
        response, events = await self.start_gated()
        mid = events[0][2]["message_id"]
        response.close()
        resumed, replay = await self.resume(mid, 1, until=lambda e, d: e == "delta")
        self.assertTrue(resumed.headers["Content-Type"].startswith("text/event-stream"))
        self.assertEqual([(i, e, d) for i, e, d in replay], [(2, "delta", {"text": "partial"})])
        self.fake.release.set()                                 # Hermes carries on: the same reader gets it live
        live = await read_sse_ids(resumed)
        self.assertEqual([(i, e) for i, e, _ in live], [(3, "delta"), (4, "done")])
        self.assertEqual(live[0][2]["text"], " rest")
        self.assertEqual(live[1][2]["message_id"], mid)
        msg = self.store.get_message(mid)
        self.assertEqual((msg["status"], msg["text"], msg["meta"]["stream_seq"]), ("complete", "partial rest", 4))
        # A second reader, by query parameter, from the middle; and a reader that has seen everything.
        _, part = await self.resume(mid, 3, query=True)
        self.assertEqual([(i, e) for i, e, _ in part], [(4, "done")])
        _, full = await self.resume(mid)
        self.assertEqual([i for i, _, _ in full], [1, 2, 3, 4])
        _, nothing = await self.resume(mid, 4)
        self.assertEqual(nothing, [])

    async def test_two_readers_get_the_same_live_events(self):
        response, events = await self.start_gated()
        mid = events[0][2]["message_id"]
        reader = await self.client.get("/api/chat/%s/stream" % mid, headers={**AUTH, "Last-Event-ID": "2"})
        await asyncio.sleep(0.1)
        self.fake.release.set()
        first, second = await asyncio.gather(read_sse_ids(response), read_sse_ids(reader))
        self.assertEqual(first, second)
        self.assertEqual([e for _, e, _ in first], ["delta", "done"])

    async def test_finished_buffer_expires_and_resume_falls_back_to_sqlite(self):
        bridge.CFG["stream_keep_s"] = 0
        _, events = await self.chat(message={"text": "hi"})
        mid = events[0][1]["message_id"]
        self.assertTrue(await self.wait_for(lambda: mid not in bridge.CHAT["jobs"]))
        _, stored = await self.resume(mid, 2)
        self.assertEqual([(i, e) for i, e, _ in stored], [(6, "snapshot"), (7, "done")])
        self.assertEqual((stored[0][2]["text"], stored[0][2]["status"]), ("Hello world", "complete"))
        self.assertEqual(stored[1][2]["usage"]["total_tokens"], 12)
        _, nothing = await self.resume(mid, 7)
        self.assertEqual(nothing, [])
        # An interrupted reply (bridge restart) resumes as snapshot + error, without ids.
        conv = self.store.create_conversation()
        half = self.store.add_message(conv["id"], "assistant", "half", status="interrupted")
        _, stored = await self.resume(half["id"], 7)
        self.assertEqual([(i, e) for i, e, _ in stored], [(None, "snapshot"), (None, "error")])
        self.assertEqual((stored[0][2]["text"], stored[1][2]["code"]), ("half", "interrupted"))

    async def test_finished_jobs_are_capped(self):
        with mock.patch.object(bridge, "MAX_FINISHED_JOBS", 2):
            mids = []
            for i in range(4):
                _, events = await self.chat(message={"text": "hi %d" % i})
                mids.append(events[0][1]["message_id"])
        self.assertEqual(sorted(bridge.CHAT["jobs"]), sorted(mids[2:]))

    async def test_small_buffer_replays_through_a_snapshot(self):
        bridge.CFG["stream_buffer"] = 2
        _, events = await self.chat(message={"text": "hi"})
        mid = events[0][1]["message_id"]
        _, replay = await self.resume(mid, 1)                    # status (2), step.start (3) and the deltas were dropped
        self.assertEqual([(i, e) for i, e, _ in replay], [(6, "snapshot"), (7, "done")])
        self.assertEqual(replay[0][2]["text"], "Hello world")
        self.assertEqual(replay[0][2]["last_status"]["label"], "df -h")
        _, exact = await self.resume(mid, 5)                      # still held: exact replay, no snapshot
        self.assertEqual([(i, e) for i, e, _ in exact], [(6, "step.end"), (7, "done")])

    async def test_background_replies_count_against_the_limit_and_retry_stops_one(self):
        bridge.CFG["max_chats"] = 1
        response, events = await self.start_gated()
        mid, cid = events[0][2]["message_id"], events[0][2]["conversation_id"]
        response.close()
        busy, data = await self.chat(message={"text": "another"})
        self.assertEqual((busy.status, data["code"]), (429, "busy"))
        self.fake.release.set()
        self.fake.mode = "stream"
        _, events = await self.chat(conversation_id=cid, retry=True)
        self.assertEqual(events[-1][0], "done")
        self.assertIsNone(self.store.get_message(mid))            # the stopped reply was replaced
        msgs, _ = self.store.messages(cid)
        self.assertEqual([(m["role"], m["status"]) for m in msgs], [("user", "complete"), ("assistant", "complete")])

    async def test_deleting_the_chat_stops_its_reply(self):
        response, events = await self.start_gated()
        cid = events[0][2]["conversation_id"]
        response.close()
        self.assertEqual((await self.client.delete("/api/conversations/" + cid, headers=AUTH)).status, 200)
        await asyncio.wait_for(self.fake.disconnected.wait(), 5)
        self.assertEqual(bridge.running_jobs(), [])

    async def test_resume_validation(self):
        _, events = await self.chat(message={"text": "hi"})
        mid = events[0][1]["message_id"]
        for value in ("x", "-1", "1.5", "9" * 12):
            with self.subTest(value=value):
                response = await self.client.get("/api/chat/%s/stream" % mid, headers={**AUTH, "Last-Event-ID": value})
                self.assertEqual((response.status, (await response.json())["code"]), (400, "bad_last_event_id"))
        user_mid = self.store.messages(events[0][1]["conversation_id"])[0][0]["id"]
        for bad in ("missing", user_mid):
            response = await self.client.get("/api/chat/%s/stream" % bad, headers=AUTH)
            self.assertEqual((response.status, (await response.json())["code"]), (404, "not_found"))

    async def test_shutdown_marks_running_reply_interrupted(self):
        response, events = await self.start_gated()
        mid = events[0][2]["message_id"]
        response.close()
        await self.client.close()                                  # app cleanup cancels the job
        reopened = bridge.ChatStore(self.db_path)
        self.assertEqual(reopened.get_message(mid)["status"], "interrupted")
        reopened.close()
        self.client = TestClient(TestServer(bridge.make_app()))
        await self.client.start_server()

    async def test_keepalive_comment_while_hermes_is_quiet(self):
        self.fake.mode = "slow"
        with mock.patch.object(bridge, "KEEPALIVE_S", 0.2):
            response = await self.client.post("/api/chat", json={"message": {"text": "long job"}}, headers=AUTH)
            seen = False
            async for raw in response.content:
                if raw.startswith(b": keep-alive"):
                    seen = True
                    break
            response.close()
        self.assertTrue(seen)

    async def test_chat_validation(self):
        conv = self.store.create_conversation()
        cases = [({}, 400, "empty_message"), ({"message": {"text": "   "}}, 400, "empty_message"),
                 ({"message": {"text": "x" * 8001}}, 400, "too_long"), ({"message": {"text": "hi"}, "effort": "max"}, 400, "bad_effort"),
                 ({"message": {"text": "hi"}, "client_msg_id": "bad id!"}, 400, "bad_client_msg_id"),
                 ({"message": {"text": "hi"}, "conversation_id": "missing"}, 404, "not_found"),
                 ({"retry": True}, 400, "nothing_to_retry"), ({"retry": True, "conversation_id": conv["id"]}, 409, "nothing_to_retry")]
        for body, status, code in cases:
            with self.subTest(body=str(body)[:60]):
                response, data = await self.chat(**body)
                self.assertEqual(response.status, status)
                self.assertEqual(data["code"], code)
        for value in ([], "text", 7):
            response = await self.client.post("/api/chat", data=json.dumps(value), headers={**AUTH, "Content-Type": "application/json"})
            self.assertEqual(response.status, 400)
        self.assertEqual(self.fake.requests, [])

    async def test_duplicate_client_msg_id_and_busy(self):
        _, events = await self.chat(message={"text": "hi"}, client_msg_id="same")
        cid = events[0][1]["conversation_id"]
        response, data = await self.chat(conversation_id=cid, message={"text": "hi"}, client_msg_id="same")
        self.assertEqual((response.status, data["code"]), (409, "duplicate"))
        bridge.CFG["max_chats"] = 0
        response, data = await self.chat(message={"text": "hi"})
        self.assertEqual((response.status, data["code"], data["error"]), (429, "busy", "busy"))

    async def test_simple_titles_make_no_extra_call(self):
        bridge.CFG["titles"] = "simple"
        _, events = await self.chat(message={"text": "short"})
        self.assertFalse(events[-1][1]["title_pending"])
        self.assertEqual(events[-1][1]["title"], "Short")
        self.assertEqual(len(self.fake.requests), 1)

    async def test_hermes_title_describes_the_user_message_not_the_reply(self):
        self.fake.title = "Disk Space On Storage"
        _, events = await self.chat(message={"text": "how much disk space is left on NAS-01?"})
        self.assertTrue(events[-1][1]["title_pending"])
        cid = events[-1][1]["conversation_id"]
        self.assertTrue(await self.wait_for(lambda: self.store.get_conversation(cid)["title_source"] == "hermes"))
        self.assertEqual(self.store.get_conversation(cid)["title"], "Disk Space On Storage")
        prompt = [r for r in self.fake.requests if not r["body"].get("stream")][0]["body"]["messages"][0]["content"]
        self.assertIn("how much disk space is left on NAS-01?", prompt)
        self.assertNotIn("Hello world", prompt)                # the reply is not a title source

    async def test_model_titles_are_three_or_four_words_from_a_small_call(self):
        """Round 6 C6: LIVE_TITLES=model (the default once TITLE_API_KEY is set) asks a small model for a 3–4 word title
        with only the user's first message, instead of a whole Hermes run."""
        bridge.CFG.update(titles="auto", title_api_key="fixture-title-key", title_api_url=bridge.CFG["hermes_url"],
                          title_model="small-model")
        self.assertEqual(bridge.title_mode(), "model")
        self.fake.title = "Storage Disk Space"
        _, events = await self.chat(message={"text": "how much disk space is left on NAS-01?"})
        self.assertTrue(events[-1][1]["title_pending"])
        cid = events[-1][1]["conversation_id"]
        self.assertTrue(await self.wait_for(lambda: self.store.get_conversation(cid)["title_source"] == "hermes"))
        self.assertEqual(self.store.get_conversation(cid)["title"], "Storage Disk Space")
        call = [r for r in self.fake.requests if not r["body"].get("stream")][0]
        self.assertEqual((call["body"]["model"], call["body"]["max_tokens"], call["body"]["reasoning_effort"]), ("small-model", 64, "low"))
        self.assertIn("3 or 4 words", call["body"]["messages"][0]["content"])
        self.assertIn("how much disk space", call["body"]["messages"][1]["content"])
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertEqual(caps["titles"], "model")
        bridge.CFG["title_api_key"] = ""
        self.assertEqual(bridge.title_mode(), "simple")
        self.assertEqual(bridge.usable_title("Disk"), "")
        self.assertEqual(bridge.usable_title("A title that rambles on far too long"), "")

    async def test_rambling_hermes_title_is_discarded(self):
        self.fake.title = "Hi Nova, ready to help with whatever you need today, just ask"
        _, events = await self.chat(message={"text": "check the backups"})
        cid = events[-1][1]["conversation_id"]
        self.assertTrue(await self.wait_for(lambda: len(self.fake.requests) == 2))
        await asyncio.sleep(0.05)
        self.assertEqual((self.store.get_conversation(cid)["title"], self.store.get_conversation(cid)["title_source"]),
                         ("Check the backups", "auto"))

    async def test_simple_title_uses_first_user_message_of_existing_chat(self):
        bridge.CFG["titles"] = "simple"
        conv = self.store.create_conversation()
        _, events = await self.chat(conversation_id=conv["id"], message={"text": "restart jellyfin on compute"})
        self.assertEqual(self.store.get_conversation(conv["id"])["title"], "Restart jellyfin on compute")
        _, events = await self.chat(conversation_id=conv["id"], message={"text": "and now sonarr"})
        self.assertEqual(events[-1][1]["title"], "Restart jellyfin on compute")

    async def test_live_transcript_title_from_first_spoken_user_turn(self):
        self.fake.title = "Storage Weather"
        conv = self.store.create_conversation()
        path = "/api/conversations/%s/live-transcript" % conv["id"]
        ok = await (await self.client.post(path, json={"turns": [
            {"role": "assistant", "text": "Hi Nova, ready to help"},
            {"role": "user", "text": "  "},
            {"role": "user", "text": "is the storage box healthy"},
            {"role": "assistant", "text": "Yes, all disks are fine."}]}, headers=AUTH)).json()
        self.assertEqual(ok["conversation"]["title"], "Is the storage box healthy")
        self.assertTrue(await self.wait_for(lambda: self.store.get_conversation(conv["id"])["title_source"] == "hermes"))
        self.assertEqual(self.store.get_conversation(conv["id"])["title"], "Storage Weather")
        prompt = self.fake.requests[-1]["body"]["messages"][0]["content"]
        self.assertIn("is the storage box healthy", prompt)
        self.assertNotIn("Nova", prompt)

    async def test_search_snippets_are_plain_text_centred_on_the_match(self):
        conv = self.store.create_conversation("Machines")
        md = ("## Overview\n\n" + "Some **filler** words go here. " * 12 + "\n\n| Name | Role |\n| --- | --- |\n"
              "| Pathfinder | core |\n| NAS-01 | storage |\n\n```bash\ndf -h\n```\n\nSee [the docs](https://example.invalid/x) "
              "for _details_. " + "Trailing text keeps going. " * 12)
        self.store.add_message(conv["id"], "assistant", md, touch=False)
        found = await (await self.client.get("/api/conversations/search?q=storage", headers=AUTH)).json()
        r = found["results"][0]
        self.assertEqual(set(r), {"conversation", "message_id", "snippet", "match"})
        snip = r["snippet"]
        self.assertLessEqual(len(snip), bridge.SNIPPET_CHARS)
        self.assertTrue(snip.startswith("…") and snip.endswith("…"))
        self.assertIn("NAS-01 · storage", snip)
        for raw in ("|", "**", "```", "##", "](", "---"):
            self.assertNotIn(raw, snip)
        self.assertEqual(snip[r["match"][0]:r["match"][1]].lower(), "storage")
        centre = (r["match"][0] + r["match"][1]) / 2
        self.assertLess(abs(centre - len(snip) / 2), 25)
        by_title = await (await self.client.get("/api/conversations/search?q=mach", headers=AUTH)).json()
        self.assertEqual((by_title["results"][0]["snippet"], by_title["results"][0]["match"]), ("Machines", [0, 4]))

    # ---- history
    async def test_conversation_crud_paging_and_search(self):
        ids = []
        for i in range(5):
            response = await self.client.post("/api/conversations", json={"title": "Chat %d" % i} if i else {}, headers=AUTH)
            self.assertEqual(response.status, 201)
            ids.append((await response.json())["conversation"]["id"])
            await asyncio.sleep(0.003)
        first = await (await self.client.get("/api/conversations?limit=2", headers=AUTH)).json()
        self.assertEqual([c["id"] for c in first["conversations"]], ids[::-1][:2])
        second = await (await self.client.get("/api/conversations?limit=2&cursor=" + first["next_cursor"], headers=AUTH)).json()
        self.assertEqual([c["id"] for c in second["conversations"]], ids[::-1][2:4])
        third = await (await self.client.get("/api/conversations?limit=2&cursor=" + second["next_cursor"], headers=AUTH)).json()
        self.assertEqual(([c["id"] for c in third["conversations"]], third["next_cursor"]), ([ids[0]], None))
        self.assertEqual((await (await self.client.get("/api/conversations/" + ids[0], headers=AUTH)).json())["conversation"]["title"], "New chat")

        patched = await self.client.patch("/api/conversations/" + ids[1], json={"title": "  Disk   space  ", "pinned": True}, headers=AUTH)
        conv = (await patched.json())["conversation"]
        self.assertEqual((conv["title"], conv["title_source"], conv["pinned"]), ("Disk space", "user", True))
        pinned = await (await self.client.get("/api/conversations?pinned=true", headers=AUTH)).json()
        self.assertEqual([c["id"] for c in pinned["conversations"]], [ids[1]])
        unpinned = await (await self.client.get("/api/conversations?pinned=false", headers=AUTH)).json()
        self.assertNotIn(ids[1], [c["id"] for c in unpinned["conversations"]])

        for path, body, code in (("/api/conversations/" + ids[1], {"title": "x" * 121}, "title_too_long"),
                                 ("/api/conversations/" + ids[1], {"title": ""}, "bad_title"),
                                 ("/api/conversations/" + ids[1], {"pinned": "yes"}, "bad_pinned"),
                                 ("/api/conversations/" + ids[1], {}, "nothing_to_change")):
            response = await self.client.patch(path, json=body, headers=AUTH)
            self.assertEqual(((await response.json())["code"], response.status), (code, 400))
        for query, code in (("limit=0", "bad_limit"), ("limit=101", "bad_limit"), ("cursor=zzz", "bad_cursor"), ("pinned=maybe", "bad_pinned")):
            response = await self.client.get("/api/conversations?" + query, headers=AUTH)
            self.assertEqual(((await response.json())["code"], response.status), (code, 400))

        self.store.add_message(ids[2], "user", "where is the backup of the photo library", touch=False)
        self.store.add_message(ids[3], "assistant", "Photos are on storage", touch=False)
        found = await (await self.client.get("/api/conversations/search?q=photo", headers=AUTH)).json()
        self.assertEqual({r["conversation"]["id"] for r in found["results"]}, {ids[2], ids[3]})
        self.assertTrue(all(r["message_id"] for r in found["results"]))
        by_title = await (await self.client.get("/api/conversations/search?q=disk", headers=AUTH)).json()
        self.assertEqual([(r["conversation"]["id"], r["message_id"]) for r in by_title["results"]], [(ids[1], None)])
        self.assertEqual((await self.client.get("/api/conversations/search?q=", headers=AUTH)).status, 400)
        self.assertEqual((await self.client.get("/api/conversations/search?q=" + "a" * 201, headers=AUTH)).status, 400)
        self.assertEqual((await (await self.client.get('/api/conversations/search?q="%22*', headers=AUTH)).json())["results"], [])

        self.assertEqual((await self.client.delete("/api/conversations/" + ids[2], headers=AUTH)).status, 200)
        self.assertEqual((await self.client.delete("/api/conversations/" + ids[2], headers=AUTH)).status, 404)
        self.assertEqual((await self.client.get("/api/conversations/" + ids[2], headers=AUTH)).status, 404)
        found = await (await self.client.get("/api/conversations/search?q=library", headers=AUTH)).json()
        self.assertEqual(found["results"], [])                   # FTS rows go with the cascade

    async def test_messages_paging_and_delete(self):
        conv = self.store.create_conversation()
        mids = [self.store.add_message(conv["id"], "user" if i % 2 == 0 else "assistant", "m%d" % i)["id"] for i in range(7)]
        page = await (await self.client.get("/api/conversations/%s?limit=3" % conv["id"], headers=AUTH)).json()
        self.assertEqual(([m["text"] for m in page["messages"]], page["has_more"]), (["m4", "m5", "m6"], True))
        self.assertEqual(page["conversation"]["message_count"], 7)
        older = await (await self.client.get("/api/conversations/%s/messages?limit=3&before=%s" % (conv["id"], mids[4]), headers=AUTH)).json()
        self.assertEqual(([m["text"] for m in older["messages"]], older["has_more"]), (["m1", "m2", "m3"], True))
        rest = await (await self.client.get("/api/conversations/%s/messages?before=%s" % (conv["id"], mids[1]), headers=AUTH)).json()
        self.assertEqual(([m["text"] for m in rest["messages"]], rest["has_more"]), (["m0"], False))
        self.assertEqual((await self.client.get("/api/conversations/%s/messages?before=nope" % conv["id"], headers=AUTH)).status, 404)
        self.assertEqual((await self.client.get("/api/conversations/%s/messages?limit=201" % conv["id"], headers=AUTH)).status, 400)
        self.assertEqual((await self.client.delete("/api/conversations/%s/messages/%s" % (conv["id"], mids[3]), headers=AUTH)).status, 200)
        self.assertEqual((await self.client.delete("/api/conversations/%s/messages/%s" % (conv["id"], mids[3]), headers=AUTH)).status, 404)
        self.assertEqual(self.store.get_conversation(conv["id"])["message_count"], 6)

    async def test_database_file_is_private_and_crash_leftovers_are_marked(self):
        self.assertEqual(stat.S_IMODE(os.stat(self.db_path).st_mode), 0o600)
        conv = self.store.create_conversation()
        mid = self.store.add_message(conv["id"], "assistant", "half", status="streaming")["id"]
        reopened = bridge.ChatStore(self.db_path)
        self.assertEqual(reopened.get_message(mid)["status"], "interrupted")
        reopened.close()

    # ---- live calls linked to chats
    async def test_session_links_chat_seeds_history_and_saves_task_results(self):
        conv = self.store.create_conversation()
        for i in range(10):
            self.store.add_message(conv["id"], "user" if i % 2 == 0 else "assistant", "typed %d" % i)

        async def fake_start(ds, offer, voice):
            return "v=0 fake answer"

        with mock.patch.object(bridge.DirectSession, "start", fake_start):
            response = await self.client.post("/api/session", json={"offer": "v=0 offer", "conversation_id": "missing"}, headers=AUTH)
            self.assertEqual((response.status, (await response.json())["code"]), (404, "not_found"))
            self.assertIsNone(bridge.DIRECT["s"])
            response = await self.client.post("/api/session", json={"offer": "v=0 offer", "conversation_id": conv["id"]}, headers=AUTH)
            data = await response.json()
        self.assertEqual(response.status, 200)
        self.assertEqual((data["answer"], data["conversation_id"]), ("v=0 fake answer", conv["id"]))
        ds = bridge.DIRECT["s"]
        self.assertEqual([m["content"] for m in ds.history], ["typed %d" % i for i in range(2, 10)])
        self.assertEqual(self.store.get_conversation(conv["id"])["kind"], "live")
        # A linked call's task is a chat message from the start, written by the fake Hermes ("Hello world").
        job = (await (await self.client.post("/api/delegate", json={"session": ds.id, "text": "check the disk"}, headers=AUTH)).json())["job"]
        self.assertTrue(await self.wait_for(lambda: ds.jobs[job]["status"] == "done"))
        result = await (await self.client.get("/api/job/%s/%s" % (ds.id, job), headers=AUTH)).json()
        self.assertEqual((result["markdown"], result["answer"]), ("Hello world", "Hello world"))
        task = self.store.messages(conv["id"])[0][-1]
        self.assertEqual((task["source"], task["status"], task["text"], task["meta"]["task"], task["meta"]["job"]),
                         ("task", "complete", "Hello world", "check the disk", job))
        self.assertEqual(result["message_id"], task["id"])
        sent = self.fake.requests[-1]["body"]["messages"]
        self.assertTrue(sent[-1]["content"].startswith(bridge.TASK_CHAT_NOTE) and sent[-1]["content"].endswith("check the disk"))

        # The app posts the call transcript afterwards; the task the bridge saved is not duplicated.
        payload = {"session": ds.id, "turns": [{"id": "t1", "role": "user", "text": "how is the disk", "created": bridge.now_ms()},
                                               {"id": "t2", "role": "assistant", "text": "Checking now."},
                                               {"role": "assistant", "text": "   "}],
                   "tasks": [{"id": job, "request": "check the disk", "answer": "dup", "status": "done"}]}
        path = "/api/conversations/%s/live-transcript" % conv["id"]
        first = await (await self.client.post(path, json=payload, headers=AUTH)).json()
        self.assertEqual((first["added"], first["skipped"]), (2, 2))
        again = await (await self.client.post(path, json=payload, headers=AUTH)).json()
        self.assertEqual((again["added"], again["skipped"]), (0, 4))
        voice = [m for m in self.store.messages(conv["id"])[0] if m["source"] == "voice"]
        self.assertEqual([m["text"] for m in voice], ["how is the disk", "Checking now."])

    async def test_session_without_chat_is_unchanged(self):
        async def fake_start(ds, offer, voice):
            return "v=0 fake answer"
        with mock.patch.object(bridge.DirectSession, "start", fake_start):
            data = await (await self.client.post("/api/session", json={"offer": "v=0 offer"}, headers=AUTH)).json()
        self.assertEqual(set(data), {"session", "answer", "conversation_id", "backend", "timing"})   # timing: round 8
        self.assertEqual(data["backend"], "codex")
        self.assertIsNone(data["conversation_id"])
        self.assertEqual(bridge.DIRECT["s"].history, [])

    async def test_live_transcript_titles_and_validation(self):
        conv = self.store.create_conversation()
        path = "/api/conversations/%s/live-transcript" % conv["id"]
        ok = await (await self.client.post(path, json={"turns": [{"role": "user", "text": "what's the weather on the storage box right now"}],
                                                       "tasks": [{"request": "weather", "answer": "", "status": "failed"}]}, headers=AUTH)).json()
        self.assertEqual(ok["added"], 2)
        self.assertEqual(ok["conversation"]["title"], "What's the weather on the storage box…")
        self.assertEqual(ok["conversation"]["kind"], "live")
        bad = [({"turns": "x"}, 400, "bad_transcript"), ({"turns": [{"role": "system", "text": "x"}]}, 400, "bad_turn"),
               ({"turns": [{"role": "user", "text": "x" * 8001}]}, 400, "too_long"),
               ({"turns": [{"role": "user", "text": "x", "id": "bad id"}]}, 400, "bad_id"),
               ({"turns": [{"role": "user", "text": "x"}] * 501}, 413, "too_many_items"),
               ({"tasks": [{"answer": "x", "status": "weird"}]}, 400, "bad_task"), ({"session": "bad id!"}, 400, "bad_session")]
        for body, status, code in bad:
            with self.subTest(code=code):
                response = await self.client.post(path, json=body, headers=AUTH)
                self.assertEqual((response.status, (await response.json())["code"]), (status, code))
        response = await self.client.post("/api/conversations/missing/live-transcript", json={"turns": []}, headers=AUTH)
        self.assertEqual(response.status, 404)

    # ---- start errors
    async def test_start_errors_are_classified(self):
        cases = [
            ("You've hit your usage limit. Upgrade to Plus to continue using Codex (https://chatgpt.com/explore/plus), or try again in 2 hours.",
             429, "usage_limit", 7200),
            ("Usage limit reached. You've reached your usage limit. Increase your limits to continue using codex.", 429, "usage_limit", None),
            ("codex error: rate limited \"usageLimitExceeded\"", 429, "usage_limit", None),
            ("Your access token could not be refreshed because your refresh token has expired. Please log out and sign in again.",
             502, "login_expired", None),
            ("ChatGPT account ID not available, please re-run `codex login`", 502, "login_expired", None),
            ("codex: no SDP answer", 502, "start_failed", None),
        ]
        for text, status, code, after in cases:
            async def failing_start(ds, offer, voice, text=text):
                raise RuntimeError(text)
            with self.subTest(code=code, text=text[:30]), mock.patch.object(bridge.DirectSession, "start", failing_start):
                response = await self.client.post("/api/session", json={"offer": "v=0 offer"}, headers=AUTH)
                data = await response.json()
                self.assertEqual((response.status, data["code"]), (status, code))
                if code == "usage_limit":
                    self.assertEqual(data["error"], "usage_limit")
                    self.assertEqual(data["retry_after_s"], after)
                    self.assertEqual(response.headers.get("Retry-After"), None if after is None else str(after))
                if code == "start_failed":
                    self.assertEqual(data["error"], "could not start GPT-Live (is the ChatGPT login still valid?)")
                self.assertNotIn("chatgpt.com", json.dumps(data))
                self.assertIsNone(bridge.DIRECT["s"])

    def test_config_defaults_are_neutral_and_follow_the_data_dir(self):
        cfg = bridge.load_config({"PATH": ""})
        home_data = os.path.join(os.path.expanduser("~"), ".local", "share", "gpt-live-bridge")
        self.assertEqual((cfg["data_dir"], cfg["host"], cfg["port"]), (home_data, "127.0.0.1", 8787))
        self.assertEqual((cfg["hermes_url"], cfg["hermes_model"], cfg["codex"]), ("http://127.0.0.1:8642/v1", "hermes-agent", "codex"))
        for key, leaf in (("codex_home", "codex-home"), ("workdir", "work"), ("app_dir", "web"), ("apk_path", "hermes-live.apk"),
                          ("chat_db", "chats.sqlite")):
            self.assertEqual(cfg[key], os.path.join(home_data, leaf), key)
        self.assertEqual((cfg["stream_keep_s"], cfg["stream_buffer"], cfg["stream_disconnect"]), (300, 10000, "continue"))
        self.assertEqual((cfg["key"], cfg["live_key"], cfg["hermes_key"]), ("", "", ""))
        self.assertEqual((cfg["max_chats"], cfg["max_jobs"], cfg["max_calls"], cfg["titles"]), (2, 2, 1, "auto"))   # auto = simple until TITLE_API_KEY is set
        self.assertEqual((cfg["push_enabled"], cfg["push_previews"], cfg["push_max_devices"], cfg["push_rate_per_min"]), (True, True, 10, 20))
        self.assertIs(bridge.load_config({"PUSH_PREVIEWS": "false"})["push_previews"], False)
        self.assertIs(bridge.load_config({"PUSH_ENABLED": "0"})["push_enabled"], False)
        self.assertNotIn("/srv", json.dumps(cfg))
        self.assertNotIn("ts.net", json.dumps(cfg))
        moved = bridge.load_config({"BRIDGE_DATA_DIR": "/data", "LIVE_CHAT_DB": "/elsewhere/c.sqlite", "BRIDGE_PORT": " 9000 ",
                                    "CODEX_BIN": "/opt/codex", "XDG_DATA_HOME": "/ignored"})
        self.assertEqual((moved["codex_home"], moved["workdir"], moved["chat_db"], moved["port"], moved["codex"]),
                         ("/data/codex-home", "/data/work", "/elsewhere/c.sqlite", 9000, "/opt/codex"))
        self.assertEqual(bridge.load_config({"XDG_DATA_HOME": "/xdg"})["data_dir"], "/xdg/gpt-live-bridge")
        with tempfile.TemporaryDirectory() as bin_dir:
            fake_codex = os.path.join(bin_dir, "codex")
            Path(fake_codex).write_text("#!/bin/sh\n")
            os.chmod(fake_codex, 0o755)
            self.assertEqual(bridge.load_config({"PATH": bin_dir})["codex"], fake_codex)
        for env in ({"BRIDGE_PORT": "abc"}, {"BRIDGE_PORT": "0"}, {"LIVE_STREAM_BUFFER": "3"}, {"PUSH_PREVIEWS": "maybe"},
                    {"PUSH_RATE_PER_MIN": "0"}):
            with self.subTest(env=env), self.assertRaises(SystemExit):
                bridge.load_config(env)

    # ---- push (UnifiedPush)
    def endpoint(self, name="phone"):
        return str(self.distributor.make_url("/up/" + name))

    async def register(self, device_id="phone-1", name="phone", **extra):
        body = {"device_id": device_id, "endpoint": self.endpoint(name), "app_version": "1.2.3", **extra}
        return await self.client.post("/api/push/register", json=body, headers=AUTH)

    async def pushes(self, n, timeout=5.0):
        self.assertTrue(await self.wait_for(lambda: len(self.dist.pushes) >= n, timeout), "expected %d pushes" % n)
        return [p["body"] for p in self.dist.pushes]

    async def test_push_registration_and_validation(self):
        response = await self.register()
        data = await response.json()
        self.assertEqual((response.status, data), (200, {"ok": True, "device_id": "phone-1", "previews": True}))
        self.assertEqual(self.store.push_device("phone-1")["app_version"], "1.2.3")
        bad = [({"device_id": "bad id!", "endpoint": self.endpoint()}, "bad_device_id"),
               ({"device_id": "d", "endpoint": "ftp://example.invalid/up"}, "bad_endpoint"),
               ({"device_id": "d", "endpoint": "https://user:pw@example.invalid/up"}, "bad_endpoint"),
               ({"device_id": "d", "endpoint": "https:///nohost"}, "bad_endpoint"),
               ({"device_id": "d", "endpoint": "https://example.invalid/a b"}, "bad_endpoint"),
               ({"device_id": "d", "endpoint": "https://example.invalid:99999/"}, "bad_endpoint"),
               ({"device_id": "d", "endpoint": "https://example.invalid/" + "x" * 2048}, "bad_endpoint"),
               ({"device_id": "d", "endpoint": 7}, "bad_endpoint"),
               ({"device_id": "d", "endpoint": "https://example.invalid/up", "app_version": "x" * 65}, "bad_app_version")]
        for body, code in bad:
            with self.subTest(code=code, body=str(body)[:60]):
                response = await self.client.post("/api/push/register", json=body, headers=AUTH)
                self.assertEqual((response.status, (await response.json())["code"]), (400, code))
        # Re-registering a device updates it; an endpoint moves to the newest device id that registers it.
        await self.register(app_version="2.0")
        self.assertEqual(self.store.push_device("phone-1")["app_version"], "2.0")
        await self.register(device_id="phone-2")
        self.assertEqual([d["device_id"] for d in self.store.push_devices()], ["phone-2"])
        bridge.CFG["push_max_devices"] = 2
        await self.register(device_id="tablet", name="tablet")
        response = await self.register(device_id="laptop", name="laptop")
        self.assertEqual((response.status, (await response.json())["code"]), (409, "too_many_devices"))
        self.assertEqual((await self.register(device_id="tablet", name="tablet")).status, 200)    # updating is fine
        gone = await (await self.client.delete("/api/push/register/tablet", headers=AUTH)).json()
        self.assertEqual(gone, {"ok": True, "removed": True})
        again = await (await self.client.delete("/api/push/register/tablet", headers=AUTH)).json()
        self.assertEqual(again["removed"], False)
        self.assertEqual((await self.client.delete("/api/push/register/bad%20id", headers=AUTH)).status, 404)
        self.assertNotIn("/up/", json.dumps(await (await self.client.get("/api/capabilities", headers=AUTH)).json()))
        bridge.CFG["push_enabled"] = False
        self.assertEqual((await self.register()).status, 503)
        self.assertIs((await (await self.client.get("/api/capabilities", headers=AUTH)).json())["push"], False)

    async def test_unwatched_reply_is_pushed_and_watched_reply_is_not(self):
        await self.register()
        _, events = await self.chat(message={"text": "hi"})                # a client read the whole reply
        await asyncio.sleep(0.3)
        self.assertEqual(self.dist.pushes, [])
        response, events = await self.start_gated()
        mid, cid = events[0][2]["message_id"], events[0][2]["conversation_id"]
        response.close()                                                    # the user left the chat
        await asyncio.sleep(1.3)
        self.fake.release.set()
        body = (await self.pushes(1))[0]
        self.assertEqual(self.dist.pushes[0]["type"], "application/json")
        self.assertEqual(set(body), {"type", "conversation_id", "message_id", "title", "preview", "status", "sent"})
        self.assertEqual((body["type"], body["conversation_id"], body["message_id"], body["status"], body["preview"], body["title"]),
                         ("chat.reply", cid, mid, "done", "partial rest", "Long job"))

    async def test_unwatched_stop_pushes_stopped_but_retry_and_delete_do_not(self):
        await self.register()
        response, events = await self.start_gated()
        mid, cid = events[0][2]["message_id"], events[0][2]["conversation_id"]
        response.close()
        await asyncio.sleep(1.3)
        await self.client.post("/api/chat/%s/stop" % mid, headers=AUTH)
        body = (await self.pushes(1))[0]
        self.assertEqual((body["status"], body["preview"], body["message_id"]), ("stopped", "partial", mid))
        response, events = await self.start_gated(conversation_id=cid)
        response.close()
        await asyncio.sleep(1.3)
        await self.client.delete("/api/conversations/" + cid, headers=AUTH)
        await asyncio.sleep(0.3)
        self.assertEqual(len(self.dist.pushes), 1)

    async def test_failed_reply_push_and_previews_off(self):
        bridge.CFG["push_previews"] = False
        await self.register()
        self.fake.mode, self.fake.fail_delay = "fail", 1.6
        response = await self.client.post("/api/chat", json={"message": {"text": "secret plans"}}, headers=AUTH)
        response.close()                                                    # gone (and noticed) before the reply ends
        body = (await self.pushes(1))[0]
        self.assertEqual((body["type"], body["status"], body["title"], body["preview"]), ("chat.reply", "failed", None, None))
        self.assertNotIn("secret", json.dumps(self.dist.pushes))
        self.assertIs((await (await self.client.get("/api/capabilities", headers=AUTH)).json())["push_previews"], False)

    async def test_gone_endpoint_is_removed_and_test_route_reports_delivery(self):
        await self.register()
        ok = await (await self.client.post("/api/push/test", json={"device_id": "phone-1"}, headers=AUTH)).json()
        self.assertEqual(ok, {"ok": True, "delivered": True, "status": 200})
        self.assertEqual(self.dist.pushes[0]["body"]["type"], "test")
        self.assertEqual((await self.client.post("/api/push/test", json={"device_id": "nope"}, headers=AUTH)).status, 404)
        self.dist.status = 410
        gone = await (await self.client.post("/api/push/test", json={"device_id": "phone-1"}, headers=AUTH)).json()
        self.assertEqual((gone["delivered"], gone["status"]), (False, 410))
        self.assertIsNone(self.store.push_device("phone-1"))

    async def test_pushes_are_rate_limited_per_device(self):
        bridge.CFG["push_rate_per_min"] = 2
        await self.register()
        conv = self.store.create_conversation("Chat")
        for i in range(4):
            bridge.notify("chat.reply", conv["id"], "m%d" % i, "complete", "text %d" % i)
        await self.pushes(2)
        await asyncio.sleep(0.3)
        self.assertEqual(len(self.dist.pushes), 2)
        response = await self.client.post("/api/push/test", json={"device_id": "phone-1"}, headers=AUTH)
        self.assertEqual((response.status, (await response.json())["code"]), (429, "rate_limited"))
        self.assertTrue(bridge.push_allowed("other", now=0.0))
        self.assertTrue(bridge.push_allowed("other", now=1.0))
        self.assertFalse(bridge.push_allowed("other", now=2.0))
        self.assertTrue(bridge.push_allowed("other", now=60.5))             # the window slides

    def test_push_preview_is_short_plain_text(self):
        long = "## Disk report\n\n| Name | Free |\n| --- | --- |\n| **storage** | `412 GB` |\n\n" + "More words here. " * 20
        p = bridge.push_preview(long)
        self.assertLessEqual(len(p), 120)
        self.assertTrue(p.startswith("Disk report Name · Free storage · 412 GB") and p.endswith("…"))
        self.assertEqual(bridge.push_preview("**ok**"), "ok")

    async def test_live_task_keeps_running_after_the_call_and_is_pushed(self):
        await self.register()
        conv = self.store.create_conversation("Voice chat")
        self.fake.mode = "gated"

        async def fake_start(ds, offer, voice):
            return "v=0 fake answer"

        with mock.patch.object(bridge.DirectSession, "start", fake_start):
            data = await (await self.client.post("/api/session", json={"offer": "v=0 offer", "conversation_id": conv["id"]}, headers=AUTH)).json()
            sid = data["session"]
            job = (await (await self.client.post("/api/delegate", json={"session": sid, "text": "check backups"}, headers=AUTH)).json())["job"]
            await self.client.post("/api/stop", json={"session": sid}, headers=AUTH)       # the call ends; the task does not
            self.assertIsNone(bridge.DIRECT["s"])
            self.fake.release.set()
            body = (await self.pushes(1))[0]
        task = [m for m in self.store.messages(conv["id"])[0] if m["source"] == "task"][0]
        self.assertEqual((task["text"], task["meta"]["job"]), ("partial rest", job))
        self.assertEqual((body["type"], body["conversation_id"], body["message_id"], body["status"], body["preview"], body["title"]),
                         ("live.task", conv["id"], task["id"], "done", "partial rest", "Voice chat"))

    async def test_live_task_seen_by_a_polling_call_is_not_pushed(self):
        await self.register()

        async def fake_start(ds, offer, voice):
            return "v=0 fake answer"

        async def fake_ask(ds, text, job=None):
            return "done"

        with mock.patch.object(bridge.DirectSession, "start", fake_start), mock.patch.object(bridge.DirectSession, "ask_hermes", fake_ask):
            sid = (await (await self.client.post("/api/session", json={"offer": "v=0 offer"}, headers=AUTH)).json())["session"]
            job = (await (await self.client.post("/api/delegate", json={"session": sid, "text": "x"}, headers=AUTH)).json())["job"]
            self.assertTrue(await self.wait_for(lambda: bridge.DIRECT["s"].jobs[job]["status"] == "done"))
        await asyncio.sleep(0.3)
        self.assertEqual(self.dist.pushes, [])

    def test_retry_after_parsing(self):
        self.assertEqual(bridge.retry_after_seconds("try again in 45 seconds"), 45)
        self.assertEqual(bridge.retry_after_seconds("Try again in 3 minutes"), 180)
        self.assertEqual(bridge.retry_after_seconds('{"retry_after": 30}'), 30)
        self.assertEqual(bridge.retry_after_seconds('"resets_at": 1000000600', now=1000000000), 600)
        self.assertIsNone(bridge.retry_after_seconds("no hint here"))

    def test_titles(self):
        self.assertEqual(bridge.simple_title("  hi   there "), "Hi there")
        self.assertEqual(bridge.simple_title(""), "New chat")
        self.assertEqual(bridge.simple_title("a" * 50), "A" + "a" * 39 + "…")
        self.assertEqual(bridge.clean_title('Title: "Disk Space Check."\nextra'), "Disk Space Check")

    def test_plain_text_and_snippets(self):
        self.assertEqual(bridge.plain_text("# Head\n\n| Name | Role |\n|:--|--:|\n| a | b |"), "Head Name · Role a · b")
        self.assertEqual(bridge.plain_text("**bold** *it* _u_ ~~s~~ `x` [link](http://h/p) ![alt](i.png)"), "bold it u s x link alt")
        self.assertEqual(bridge.plain_text("```python\nprint(1)\n```\n> quoted\n- item\n1. step\n---"), "print(1) quoted item step")
        self.assertEqual(bridge.plain_text("snake_case_name and 2*3*4"), "snake_case_name and 2*3*4")
        self.assertEqual(bridge.make_snippet("short **text** here", ["text"]), ("short text here", [6, 10]))
        self.assertEqual(bridge.make_snippet("nothing", ["zzz"]), ("nothing", None))
        long = "word " * 100 + "needle " + "word " * 100
        snip, (a, b) = bridge.make_snippet(long, ["need"])
        self.assertTrue(len(snip) <= bridge.SNIPPET_CHARS and snip.startswith("…") and snip.endswith("…"))
        self.assertEqual(snip[a:b], "needle")
        snip, (a, b) = bridge.make_snippet("needle " + "word " * 100, ["needle"])
        self.assertEqual((snip[:6], a, snip[-1]), ("needle", 0, "…"))
        snip, (a, b) = bridge.make_snippet("word " * 100 + "needle", ["needle"])
        self.assertEqual((snip[0], snip[a:b], snip.endswith("needle")), ("…", "needle", True))


if __name__ == "__main__":
    unittest.main()
