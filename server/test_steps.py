"""Steps (thinking + tool timeline) on /api/chat, against a fake Hermes stream and a fake Hermes session store, plus
the redaction rules. Nothing real is contacted. Run from this folder with the bridge venv:
  ~/.local/share/gpt-live-bridge/venv/bin/python -m unittest test_steps
"""
import asyncio
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

SPEC = importlib.util.spec_from_file_location("bridge_steps", Path(__file__).with_name("gpt-live-bridge.py"))
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)

KEY = "fixture-key-for-steps-testing"
AUTH = {"Authorization": "Bearer " + KEY}
FAKE_TOKEN = "ghp_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"


class FakeHermes:
    """A Hermes stream (reasoning, two tools, answer) and the session store that holds the tool calls."""

    def __init__(self):
        self.session = "api-0123456789abcdef"
        self.send_session = True
        self.store_rows = []
        self.store_delay = 0.0
        self.lookups = 0
        self.exit_code = 0
        self.long_output = False
        self.many_tools = 0                      # > 0: a reply that runs this many terminal calls (round 6 B1)

    def chunk(self, delta, finish=None):
        return ("data: " + json.dumps({"choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}) + "\n\n").encode()

    def tool_event(self, **p):
        return ("event: hermes.tool.progress\ndata: " + json.dumps(p) + "\n\n").encode()

    async def chat(self, req):
        body = await req.json()
        if not body.get("stream"):
            return web.json_response({"choices": [{"message": {"content": "Title"}, "finish_reason": "stop"}]})
        if self.many_tools:
            return await self.many(req)
        headers = {"Content-Type": "text/event-stream"}
        if self.send_session:
            headers["X-Hermes-Session-Id"] = self.session
        resp = web.StreamResponse(headers=headers)
        await resp.prepare(req)
        await resp.write(self.chunk({"role": "assistant"}))
        await resp.write(self.chunk({"reasoning_content": "The user wants the output of echo. "}))
        await resp.write(self.chunk({"reasoning_content": "I'll run it with the terminal."}))
        await resp.write(self.tool_event(tool="terminal", emoji="x", label="echo hi", toolCallId="call_1", status="running"))
        output = ("\x1b[32mhi\x1b[0m\nexport API_TOKEN=abc123def456\n" + "y" * (9000 if self.long_output else 0))
        self.store_rows = [
            {"role": "user", "content": "run echo hi"},
            {"role": "assistant", "tool_calls": [{"id": "call_1", "type": "function", "function": {
                "name": "terminal", "arguments": json.dumps({"command": "echo hi && curl -H 'Authorization: Bearer %s' x" % FAKE_TOKEN})}}]},
            {"role": "tool", "tool_call_id": "call_1", "tool_name": "terminal",
             "content": json.dumps({"output": output, "exit_code": self.exit_code, "error": None, "cwd": "/home/hermes"})}]
        await resp.write(self.tool_event(tool="terminal", toolCallId="call_1", status="completed"))
        await resp.write(self.tool_event(tool="read_file", emoji="y", label="hostname", toolCallId="call_2", status="running"))
        self.store_rows += [
            {"role": "assistant", "tool_calls": [{"id": "call_2", "function": {"name": "read_file", "arguments": '{"path": "/etc/hostname"}'}}]},
            {"role": "tool", "tool_call_id": "call_2", "content": json.dumps({"content": "1|core", "total_lines": 1})}]
        await resp.write(self.tool_event(tool="read_file", toolCallId="call_2", status="completed"))
        await resp.write(self.chunk({"content": "It printed hi."}))
        await resp.write(self.chunk({}, "stop"))
        await resp.write(b"data: [DONE]\n\n")
        return resp

    async def many(self, req):
        resp = web.StreamResponse(headers={"Content-Type": "text/event-stream", "X-Hermes-Session-Id": self.session})
        await resp.prepare(req)
        await resp.write(self.chunk({"role": "assistant"}))
        self.store_rows = []
        for n in range(1, self.many_tools + 1):
            cid = "call_%d" % n
            await resp.write(self.tool_event(tool="terminal", label="step %d" % n, toolCallId=cid, status="running"))
            self.store_rows += [
                {"role": "assistant", "tool_calls": [{"id": cid, "function": {"name": "terminal",
                                                                              "arguments": json.dumps({"command": "echo %d" % n})}}]},
                {"role": "tool", "tool_call_id": cid, "content": json.dumps({"output": str(n), "exit_code": 0})}]
            await resp.write(self.tool_event(tool="terminal", toolCallId=cid, status="completed"))
        await resp.write(self.chunk({"content": "Ten checks done."}))
        await resp.write(self.chunk({}, "stop"))
        await resp.write(b"data: [DONE]\n\n")
        return resp

    async def messages(self, req):
        self.lookups += 1
        assert req.headers.get("Authorization") == "Bearer fixture-hermes-key"
        assert req.query.get("order") == "latest"
        if req.match_info["sid"] != self.session:
            return web.json_response({"error": {"message": "Session not found"}}, status=404)
        await asyncio.sleep(self.store_delay)
        return web.json_response({"object": "list", "session_id": self.session, "data": self.store_rows})


async def read_sse(response):
    events, event, data, eid = [], None, [], None
    async for raw in response.content:
        line = raw.decode().rstrip("\n")
        if not line:
            if event:
                events.append((eid, event, json.loads("\n".join(data))))
            event, data, eid = None, [], None
        elif line.startswith("id: "):
            eid = int(line[4:])
        elif line.startswith("event: "):
            event = line[7:]
        elif line.startswith("data: "):
            data.append(line[6:])
    return events


class StepsTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        t = self.temp.name
        self.fake = FakeHermes()
        app = web.Application()
        app.router.add_post("/v1/chat/completions", self.fake.chat)
        app.router.add_get("/api/sessions/{sid}/messages", self.fake.messages)
        self.hermes = TestServer(app)
        await self.hermes.start_server()
        self.previous = dict(bridge.CFG)
        bridge.CFG.update(live_key=KEY, hermes_key="fixture-hermes-key", chat_db=os.path.join(t, "chats.sqlite"), titles="simple",
                          hermes_url=str(self.hermes.make_url("/v1")), upload_dir=os.path.join(t, "uploads"), hermes_upload_dir="",
                          ui_prompt_file="off", web_search="false", openai_key="", usage_file=os.path.join(t, "u.json"),
                          codex_home=os.path.join(t, "codex"))
        self.client = TestClient(TestServer(bridge.make_app()))
        await self.client.start_server()
        self.store = bridge.CHAT["store"]

    async def asyncTearDown(self):
        await self.client.close()
        await self.hermes.close()
        bridge.CFG.clear()
        bridge.CFG.update(self.previous)
        bridge.CHAT["active"] = 0
        self.temp.cleanup()

    async def chat(self):
        r = await self.client.post("/api/chat", json={"message": {"text": "run echo hi"}}, headers=AUTH)
        self.assertEqual(r.status, 200)
        return await read_sse(r)

    async def test_steps_stream_and_persist(self):
        events = await self.chat()
        names = [e for _, e, _ in events]
        self.assertEqual(names[0], "meta")
        self.assertEqual(names[-1], "done")
        ids = [i for i, _, _ in events]
        self.assertEqual(ids, list(range(1, len(events) + 1)))                 # every event has the next id
        steps_events = [(e, d) for _, e, d in events if e.startswith("step.")]
        per_step = {}
        for e, d in steps_events:
            per_step.setdefault(d.get("step", d).get("id"), []).append(e)
        self.assertEqual(per_step, {"s1": ["step.start", "step.delta", "step.delta", "step.end"],
                                    "s2": ["step.start", "step.end"], "s3": ["step.start", "step.end"]})
        starts = [d["step"]["id"] for e, d in steps_events if e == "step.start"]
        self.assertEqual(starts, ["s1", "s2", "s3"])             # starts are in timeline order; a tool's end may come later
        ended = {d["step"]["id"]: d["step"] for e, d in steps_events if e == "step.end"}
        thinking = ended["s1"]
        self.assertEqual((thinking["kind"], thinking["state"], thinking["text"]),
                         ("thinking", "done", "The user wants the output of echo. I'll run it with the terminal."))
        term = ended["s2"]
        self.assertEqual((term["kind"], term["state"], term["tool"]["name"], term["tool"]["label"], term["tool"]["call_id"]),
                         ("tool", "done", "terminal", "echo hi", "call_1"))
        self.assertEqual(term["tool"]["input"], {"command": "echo hi && curl -H 'Authorization: Bearer [redacted]' x"})
        self.assertEqual(term["tool"]["output"], "hi\nexport API_TOKEN=[redacted]\n")       # ANSI stripped, secret redacted
        self.assertEqual((term["tool"]["exit_status"], term["tool"]["truncated"], term["tool"]["details"]), (0, False, True))
        self.assertTrue(term["ended_at"] >= term["started_at"])
        read = ended["s3"]
        self.assertEqual((read["tool"]["input"], read["tool"]["output"]), ({"path": "/etc/hostname"}, "1|core"))
        self.assertNotIn(FAKE_TOKEN, json.dumps(events))
        # The old status events still flow, and meta.tools is still kept for older apps.
        self.assertEqual([d["state"] for _, e, d in events if e == "status"], ["running", "completed", "running", "completed"])
        msg = self.store.get_message(events[-1][2]["message_id"])
        self.assertEqual([s["id"] for s in msg["meta"]["steps"]], ["s1", "s2", "s3"])
        self.assertEqual(msg["meta"]["steps"][1], term)
        self.assertEqual([t["tool"] for t in msg["meta"]["tools"]], ["terminal", "read_file"])
        self.assertNotIn("_final", json.dumps(msg["meta"]))
        # Resume: the buffer replays step events with their ids; the stored fallback carries steps in its snapshot.
        r = await self.client.get("/api/chat/%s/stream" % msg["id"], headers={**AUTH, "Last-Event-ID": "3"})
        replay = await read_sse(r)
        self.assertEqual([i for i, _, _ in replay], list(range(4, len(events) + 1)))
        bridge.CHAT["jobs"].clear()
        r = await self.client.get("/api/chat/%s/stream" % msg["id"], headers=AUTH)
        snap = [d for _, e, d in await read_sse(r) if e == "snapshot"][0]
        self.assertEqual(snap["steps"], msg["meta"]["steps"])

    async def test_ten_tools_all_persist_and_resume(self):
        """Round 6 B1: a reply with 10 tools keeps all 10 in meta.steps/meta.tools, in the resume buffer and in the
        stored snapshot (the app's loss was its own merge; this pins the server half)."""
        self.fake.many_tools = 10
        events = await self.chat()
        self.assertEqual(events[-1][1], "done")
        msg = self.store.get_message(events[-1][2]["message_id"])
        steps = msg["meta"]["steps"]
        self.assertEqual([s["id"] for s in steps], ["s%d" % n for n in range(1, 11)])
        self.assertEqual([s["tool"]["output"] for s in steps], [str(n) for n in range(1, 11)])
        self.assertTrue(all(s["state"] == "done" and s["tool"]["details"] for s in steps))
        self.assertEqual(len(msg["meta"]["tools"]), 10)
        # A late reader (another device, or the app after a restart) replays every step from the buffer…
        r = await self.client.get("/api/chat/%s/stream" % msg["id"], headers=AUTH)
        replay = await read_sse(r)
        self.assertEqual(len({d["step"]["id"] for _, e, d in replay if e == "step.end"}), 10)
        # …and from the stored message once the buffer is gone.
        bridge.CHAT["jobs"].clear()
        r = await self.client.get("/api/chat/%s/stream" % msg["id"], headers={**AUTH, "Last-Event-ID": "5"})
        snap = [d for _, e, d in await read_sse(r) if e == "snapshot"][0]
        self.assertEqual(len(snap["steps"]), 10)
        got = await (await self.client.get("/api/conversations/%s" % msg["conversation_id"], headers=AUTH)).json()
        self.assertEqual(len(got["messages"][-1]["meta"]["steps"]), 10)

    async def test_failed_exit_and_truncation(self):
        self.fake.exit_code, self.fake.long_output = 2, True
        events = await self.chat()
        term = [d["step"] for _, e, d in events if e == "step.end" and d["step"]["id"] == "s2"][0]
        self.assertEqual((term["state"], term["tool"]["exit_status"], term["tool"]["truncated"]), ("failed", 2, True))
        self.assertEqual(len(term["tool"]["output"]), bridge.STEP_IO_MAX)

    async def test_without_session_store_steps_use_the_preview(self):
        self.fake.send_session = False
        events = await self.chat()
        term = [d["step"] for _, e, d in events if e == "step.end" and d["step"]["id"] == "s2"][0]
        self.assertEqual((term["state"], term["tool"]["input"], term["tool"]["output"], term["tool"]["details"]), ("done", "echo hi", None, False))
        self.assertEqual(self.fake.lookups, 0)

    async def test_slow_store_still_lands_before_done(self):
        self.fake.store_delay = 0.3
        events = await self.chat()
        names = [e for _, e, _ in events]
        self.assertEqual(names[-1], "done")
        ends = [d["step"] for _, e, d in events if e == "step.end" and d["step"]["kind"] == "tool"]
        self.assertEqual([s["tool"]["details"] for s in ends], [True, True])
        self.assertLess(names.index("step.end", names.index("delta")), len(names))   # details may arrive after the answer text

    async def test_capabilities_and_push_has_no_tool_io(self):
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertIs(caps["steps"], True)
        self.assertEqual(caps["step_limits"], {"io_chars": 8192, "thinking_chars": 16384, "steps": 128})
        payload = bridge.push_payload("chat.reply", "c", "m", "done", "Your key is sk-proj-abcdefghijklmnopqrstuvwx, done.")
        self.assertNotIn("sk-proj-abcdef", json.dumps(payload))
        self.assertEqual(set(payload), {"type", "conversation_id", "message_id", "title", "preview", "status", "sent"})


class RedactionTest(unittest.TestCase):
    def test_rules(self):
        cases = [
            ("Authorization: Bearer abcdefghijklmnop1234", "Authorization: Bearer [redacted]"),
            ("curl -H 'authorization: token ghp_x' ", "curl -H 'authorization: token [redacted]' "),
            ("use bearer eyJhbGciOiJIUzI1NiJ9xxxxxxxx now", "use bearer [redacted] now"),
            ("key sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUV end", "key [redacted] end"),
            ("sk-proj-abcdefghijklmnopqrst", "[redacted]"),
            (FAKE_TOKEN, "[redacted]"),
            ("github_pat_11ABCDEFG0123456789_abcdefghij", "[redacted]"),
            ("gho_abcdefghijklmnopqrstuvwxyz0123", "[redacted]"),
            ("AKIAIOSFODNN7EXAMPLE", "[redacted]"),
            ("HERMES_API_KEY=supersecretvalue", "HERMES_API_KEY=[redacted]"),
            ('export DB_PASSWORD="p@ss word"', "export DB_PASSWORD=[redacted]"),
            ("TELEGRAM_BOT_TOKEN: 123456789:AAabcdefghijklmnopqrstuvwxyz0123456", "TELEGRAM_BOT_TOKEN: [redacted]"),
            ("password: hunter2", "password: [redacted]"),
            ('{"api_key": "abc", "name": "x"}', '{"api_key": "[redacted]", "name": "x"}'),
            ("mysql --password=hunter2 db", "mysql --password=[redacted] db"),
            ("https://admin:s3cret@example.com/x", "https://admin:[redacted]@example.com/x"),
            ("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaA\n-----END OPENSSH PRIVATE KEY-----\nafter",
             "[redacted private key]\nafter"),
            ("PATH=/usr/bin HOME=/root disk 412 GB free", "PATH=/usr/bin HOME=/root disk 412 GB free"),   # ordinary text kept
            ("the token count was high", "the token count was high"),
        ]
        for raw, want in cases:
            with self.subTest(raw=raw[:40]):
                self.assertEqual(bridge.redact_secrets(raw), want)

    def test_ansi_and_json(self):
        self.assertEqual(bridge.strip_ansi("\x1b[1;31mred\x1b[0m \x1b]0;title\x07ok\x08"), "red ok")
        self.assertEqual(bridge.clean_json({"password": "x", "env": ["TOKEN=abc"], "n": 3, "nested": {"client_secret": "y"}}),
                         {"password": "[redacted]", "env": ["TOKEN=[redacted]"], "n": 3, "nested": {"client_secret": "[redacted]"}})
        io = bridge.tool_io("not json", json.dumps({"output": "done", "exit_code": 0, "error": "warn: Bearer abcdefghijklmnopqr"}))
        self.assertEqual((io["input"], io["output"], io["exit_status"], io["error"]), ("not json", "done", 0, "warn: Bearer [redacted]"))
        self.assertEqual(bridge.tool_io(None, "plain result")["output"], "plain result")


if __name__ == "__main__":
    unittest.main()
