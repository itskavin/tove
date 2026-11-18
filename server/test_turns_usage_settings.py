"""Voice-turn merging, the cleanup tool, per-message usage, synced settings, suggestions and small-talk delegations.

Against a fake Hermes (chat completions plus its session API); nothing opens a GPT-Live session. Run with the bridge
venv from this folder:
  ~/.local/share/gpt-live-bridge/venv/bin/python -m unittest test_turns_usage_settings
"""
import asyncio
import importlib.util
import json
import os
import random
import sqlite3
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

import test_chat_api as base

bridge = base.bridge
KEY, AUTH = base.KEY, base.AUTH
read_sse = base.read_sse

SPEC = importlib.util.spec_from_file_location("cleanup_tool", Path(__file__).with_name("cleanup-voice-fragments.py"))
cleanup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cleanup)

SCREENSHOT = [("user", "No"), ("user", "No, I think it's time to let you go. Bye"), ("assistant", "Alright, bye"),
              ("assistant", "Alright, bye for now."), ("assistant", "Goodbye,"), ("assistant", "Goodbye, Alex. Take care of yourself.")]


class FakeHermesWithSessions:
    """Streams "Hello world" with a usage chunk and an X-Hermes-Session-Id; GET /api/sessions/{id} returns counters
    that grow the way Hermes' do (cached prompt tokens, reasoning, model calls)."""

    def __init__(self):
        self.requests, self.session, self.prompt = [], "sess-1", 14000
        self.counters, self.extra = {}, 0            # extra: tokens another client added to the same session
        self.model = "gpt-test-5"

    async def chat(self, req):
        body = await req.json()
        self.requests.append(body)
        c = self.counters.setdefault(self.session, {k: 0 for k in bridge.HERMES_COUNTERS})
        c.update(input_tokens=c["input_tokens"] + 150 + self.extra, cache_read_tokens=c["cache_read_tokens"] + self.prompt - 150,
                 output_tokens=c["output_tokens"] + 2, reasoning_tokens=c["reasoning_tokens"] + 7, api_call_count=c["api_call_count"] + 2)
        resp = web.StreamResponse(headers={"Content-Type": "text/event-stream", "X-Hermes-Session-Id": self.session})
        await resp.prepare(req)
        chunk = lambda d, f=None, u=None: ("data: " + json.dumps({"choices": [{"delta": d, "finish_reason": f}], **({"usage": u} if u else {})}) + "\n\n").encode()  # noqa: E731
        await resp.write(b'event: hermes.tool.progress\ndata: {"tool": "terminal", "label": "uptime", "toolCallId": "c1", "status": "running"}\n\n')
        await resp.write(b'event: hermes.tool.progress\ndata: {"tool": "terminal", "label": "uptime", "toolCallId": "c1", "status": "completed"}\n\n')
        await resp.write(chunk({"content": "Hello"}))
        await resp.write(chunk({"content": " world"}))
        await resp.write(chunk({}, "stop", {"prompt_tokens": self.prompt, "completion_tokens": 2, "total_tokens": self.prompt + 2}))
        await resp.write(b"data: [DONE]\n\n")
        return resp

    async def session_get(self, req):
        sid = req.match_info["sid"]
        if sid not in self.counters:
            return web.json_response({"error": "not found"}, status=404)
        return web.json_response({"object": "session", "session": {"id": sid, "model": self.model, **self.counters[sid]}})

    async def messages(self, req):
        return web.json_response({"data": [{"role": "assistant", "tool_calls": [{"id": "c1", "function": {"arguments": json.dumps({"command": "uptime"})}}]},
                                           {"role": "tool", "tool_call_id": "c1", "content": "up 3 days"}]})


class TurnsUsageSettingsTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.temp.name, "chats.sqlite")
        self.fake = FakeHermesWithSessions()
        app = web.Application()
        app.router.add_post("/v1/chat/completions", self.fake.chat)
        app.router.add_get("/api/sessions/{sid}", self.fake.session_get)
        app.router.add_get("/api/sessions/{sid}/messages", self.fake.messages)
        self.hermes = TestServer(app)
        await self.hermes.start_server()
        self.previous = dict(bridge.CFG)
        bridge.CFG.update(live_key=KEY, hermes_key="fixture-hermes-key", chat_db=self.db_path, max_chats=2, titles="simple",
                          hermes_url=str(self.hermes.make_url("/v1")), openai_key="", push_enabled=False,
                          usage_file=os.path.join(self.temp.name, "openai-usage.json"), assistant_name="Tove",
                          upload_dir=os.path.join(self.temp.name, "uploads"), hermes_upload_dir="", web_search="false",
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

    # ---- voice turns
    def test_screenshot_fragments_become_one_message_per_turn(self):
        merged, folded = bridge.merge_voice_turns([{"role": r, "text": t, "id": "t%d" % i} for i, (r, t) in enumerate(SCREENSHOT)])
        self.assertEqual([(m["role"], m["text"], m["id"]) for m in merged], [
            ("user", "No, I think it's time to let you go. Bye", "t0"),
            ("assistant", "Alright, bye for now. Goodbye, Alex. Take care of yourself.", "t2")])
        self.assertEqual(folded, 4)

    def test_merge_rules(self):
        merge = lambda turns: [(m["role"], m["text"]) for m in bridge.merge_voice_turns(turns)[0]]   # noqa: E731
        # a prefix cut inside a word, an exact repeat, and a late shorter copy
        self.assertEqual(merge([{"role": "assistant", "text": "Uh-h"}, {"role": "assistant", "text": "Uh-huh."}]), [("assistant", "Uh-huh.")])
        self.assertEqual(merge([{"role": "user", "text": "Calm"}, {"role": "user", "text": "Calm"}]), [("user", "Calm")])
        self.assertEqual(merge([{"role": "user", "text": "Check the disk please"}, {"role": "user", "text": "check the disk"}]),
                         [("user", "Check the disk please")])
        # the same words in two turns with the other speaker in between stay two turns
        self.assertEqual(len(merge([{"role": "user", "text": "Yes"}, {"role": "assistant", "text": "Okay."}, {"role": "user", "text": "Yes"}])), 3)
        # an assistant fragment that was cut off and restarted gives way; a short user pause is joined
        self.assertEqual(merge([{"role": "assistant", "text": "Okay, so", "created": 0}, {"role": "assistant", "text": "Sure, here's the plan.", "created": 900}]),
                         [("assistant", "Sure, here's the plan.")])
        self.assertEqual(merge([{"role": "user", "text": "Thanks", "created": 0}, {"role": "user", "text": "can you also check sonarr", "created": 2000}]),
                         [("user", "Thanks can you also check sonarr")])
        # far apart in time: two turns (an acknowledgement, then the result 30 s later)
        self.assertEqual(len(merge([{"role": "assistant", "text": "Sure, checking now.", "created": 0},
                                    {"role": "assistant", "text": "All servers are up.", "created": 30000}])), 2)
        self.assertEqual(merge([{"role": "user", "text": "  "}]), [])

    async def test_import_merges_fragments_idempotently(self):
        conv = self.store.create_conversation()
        path = "/api/conversations/%s/live-transcript" % conv["id"]
        t0 = bridge.now_ms() - 60000
        turns = [{"id": "c-%d" % i, "role": r, "text": t, "created": t0 + i * 400} for i, (r, t) in enumerate(SCREENSHOT)]
        first = await (await self.client.post(path, json={"session": "c", "turns": turns}, headers=AUTH)).json()
        self.assertEqual((first["added"], first["skipped"], first["merged"]), (2, 0, 4))
        again = await (await self.client.post(path, json={"session": "c", "turns": turns}, headers=AUTH)).json()
        self.assertEqual((again["added"], again["skipped"]), (0, 2))
        msgs = self.store.messages(conv["id"])[0]
        self.assertEqual([(m["text"], m["client_id"], m["created"]) for m in msgs],
                         [("No, I think it's time to let you go. Bye", "turn:c-0", t0),
                          ("Alright, bye for now. Goodbye, Alex. Take care of yourself.", "turn:c-2", t0 + 800)])
        self.assertEqual(first["conversation"]["title"], "No, I think it's time to let you go")

    async def test_client_clock_ahead_keeps_order_and_spacing(self):
        conv = self.store.create_conversation()
        ahead = bridge.now_ms() + 10 * 60000                       # the phone's clock runs ten minutes fast
        body = {"turns": [{"id": "a", "role": "user", "text": "how is the disk", "created": ahead - 50000},
                          {"id": "b", "role": "assistant", "text": "Checking now.", "created": ahead - 48000}],
                "tasks": [{"id": "j1", "request": "disk", "answer": "Fine.", "status": "done", "created": ahead - 20000}]}
        ok = await (await self.client.post("/api/conversations/%s/live-transcript" % conv["id"], json=body, headers=AUTH)).json()
        self.assertEqual(ok["added"], 3)
        msgs = self.store.messages(conv["id"])[0]
        self.assertEqual([m["text"] for m in msgs], ["how is the disk", "Checking now.", "Fine."])
        self.assertEqual((msgs[1]["created"] - msgs[0]["created"], msgs[2]["created"] - msgs[0]["created"]), (2000, 30000))
        self.assertLessEqual(msgs[2]["created"], bridge.now_ms())

    async def test_openai_transcript_segments_and_save(self):
        conv = self.store.create_conversation()
        ds = bridge.OpenAISession()
        ds.conversation_id, ds.created_at = conv["id"], time.time() - 120
        for role, delta, start, end in [("user", "Bye", 0, 400), ("assistant", "Alright, bye for now.", 600, 1800),
                                        ("assistant", "Goodbye", 3500, 3900), ("assistant", ", take care.", 3900, 4400),
                                        ("assistant", "Still there?", 40000, 41000)]:
            ds._transcript(role, {"delta": delta, "start_ms": start, "end_ms": end})
        self.assertEqual([t["text"] for t in ds.turns], ["Bye", "Alright, bye for now. Goodbye, take care.", "Still there?"])
        self.assertEqual(ds.save_transcript(), 3)
        self.assertEqual([m["text"] for m in self.store.messages(conv["id"])[0]],
                         ["Bye", "Alright, bye for now. Goodbye, take care.", "Still there?"])
        await ds.close()

    def test_cleanup_tool_dry_run_and_apply(self):
        db_path = os.path.join(self.temp.name, "old.sqlite")
        store = bridge.ChatStore(db_path)
        conv = store.create_conversation()
        other = store.create_conversation()
        for i, (role, text) in enumerate(SCREENSHOT):
            store.add_message(conv["id"], role, text, "voice", created=1000, client_id="turn:S-%d" % i, meta={"session": "S"})
        store.add_message(conv["id"], "assistant", "a typed reply", "text", created=2000)
        store.add_message(other["id"], "user", "Hey", "voice", created=1000, client_id="turn:T-1", meta={"session": "T"})
        store.add_message(other["id"], "user", "Hey, hi there", "voice", created=1000, client_id="turn:T-2", meta={"session": "T"})
        store.add_message(other["id"], "user", "Hey, hi there", "voice", created=1000, client_id="turn:U-1", meta={"session": "U"})
        store.close()
        out = []
        with mock.patch("builtins.print", lambda *a: out.append(" ".join(map(str, a)))):
            cleanup.main(["--db", db_path])
        self.assertIn("chats to change: 2; voice messages in affected runs: 8 -> 3 (5 deleted, 3 rewritten)", "\n".join(out))
        check = sqlite3.connect(db_path)
        self.assertEqual(check.execute("SELECT count(*) FROM messages WHERE source = 'voice'").fetchone()[0], 9)  # dry run
        check.close()
        backup_dir = os.path.join(self.temp.name, "bk")
        with mock.patch("builtins.print", lambda *a: None):
            cleanup.main(["--db", db_path, "--apply", "--backup-dir", backup_dir])
        store = bridge.ChatStore(db_path)
        msgs = store.messages(conv["id"])[0]
        self.assertEqual([(m["text"], m["client_id"], m["meta"].get("voice_merged")) for m in msgs],
                         [("No, I think it's time to let you go. Bye", "turn:S-0", 2),
                          ("Alright, bye for now. Goodbye, Alex. Take care of yourself.", "turn:S-2", 4),
                          ("a typed reply", None, None)])
        self.assertEqual([m["text"] for m in store.messages(other["id"])[0]], ["Hey, hi there", "Hey, hi there"])   # two calls
        self.assertEqual([r[0] for r in store.db.execute("SELECT rowid FROM messages_fts WHERE messages_fts MATCH 'Alex'")].__len__(), 1)
        store.close()
        old = sqlite3.connect(os.path.join(backup_dir, "chats.sqlite"))
        self.assertEqual(old.execute("SELECT count(*) FROM messages WHERE source = 'voice'").fetchone()[0], 9)
        old.close()

    # ---- small talk in live calls
    def test_smalltalk_detection(self):
        for text in ("Okay. I think that's enough. Bye", "No, I think it's time to let you go. Bye", "Thanks!", "Hey", "Bye Tove", "good night"):
            self.assertTrue(bridge.is_smalltalk(text), text)
        for text in ("Hey, can you check the disk", "thanks, now restart sonarr", "What time is it", "Not bad", "",
                     "அதுக்கு என்னல்லா options இருக்கு", "bye " * 13):
            self.assertFalse(bridge.is_smalltalk(text), text)

    async def test_smalltalk_delegation_skips_hermes_and_the_chat(self):
        conv = self.store.create_conversation()

        async def fake_start(ds, offer, voice):
            return "v=0 fake answer"
        with mock.patch.object(bridge.DirectSession, "start", fake_start):
            ds_id = (await (await self.client.post("/api/session", json={"offer": "v=0 offer", "conversation_id": conv["id"]}, headers=AUTH)).json())["session"]
        ds = bridge.DIRECT["s"]
        job = (await (await self.client.post("/api/delegate", json={"session": ds_id, "text": "Okay. I think that's enough. Bye"}, headers=AUTH)).json())["job"]
        self.assertTrue(await self.wait_for(lambda: ds.jobs[job]["status"] == "done"))
        result = await (await self.client.get("/api/job/%s/%s" % (ds_id, job), headers=AUTH)).json()
        self.assertEqual(result["answer"], bridge.SMALLTALK_ANSWER)
        self.assertEqual(self.fake.requests, [])
        # a real task still runs on Hermes, is saved, and carries usage
        job = (await (await self.client.post("/api/delegate", json={"session": ds_id, "text": "check the uptime"}, headers=AUTH)).json())["job"]
        self.assertTrue(await self.wait_for(lambda: ds.jobs[job]["status"] == "done"))
        await asyncio.sleep(0.05)
        tasks = [m for m in self.store.messages(conv["id"])[0] if m["source"] == "task"]
        self.assertEqual(len(tasks), 1)
        usage = tasks[0]["meta"]["usage"]
        self.assertEqual((usage["input_tokens"], usage["output_tokens"], usage["tool_count"]), (14000, 2, 1))
        self.assertIn("duration_ms", usage)

    # ---- usage
    async def test_usage_on_done_and_messages(self):
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertIs(caps["usage"], True)
        _, events = await self.chat(message={"text": "uptime please"}, effort="high")
        done = events[-1][1]
        u = done["usage"]
        self.assertEqual((u["input_tokens"], u["output_tokens"], u["total_tokens"], u["cached_tokens"], u["reasoning_tokens"]),
                         (14000, 2, 14002, 13850, 7))
        self.assertEqual((u["model"], u["tool_count"], u["effort"], u["model_calls"]), ("gpt-test-5", 1, "high", 2))
        self.assertEqual((u["prompt_tokens"], u["completion_tokens"]), (14000, 2))            # the old keys stay
        self.assertTrue(isinstance(u["duration_ms"], int) and isinstance(u["ttft_ms"], int) and u["ttft_ms"] <= u["duration_ms"])
        cid = done["conversation_id"]
        # the second reply of the same Hermes session gets only its own share of the session counters
        _, events = await self.chat(conversation_id=cid, message={"text": "and memory?"})
        u2 = events[-1][1]["usage"]
        self.assertEqual((u2["cached_tokens"], u2["reasoning_tokens"], u2["model_calls"]), (13850, 7, 2))
        self.assertNotIn("effort", u2)
        conv = await (await self.client.get("/api/conversations/" + cid, headers=AUTH)).json()
        replies = [m for m in conv["messages"] if m["role"] == "assistant"]
        self.assertEqual(replies[-1]["meta"]["usage"]["cached_tokens"], 13850)
        self.assertNotIn("_hermes", json.dumps(conv))                                        # bridge-private
        resumed = await read_sse(await self.client.get("/api/chat/%s/stream" % replies[0]["id"], headers=AUTH))
        self.assertEqual(resumed[-1][1]["usage"]["cached_tokens"], 13850)

    async def test_usage_without_a_reliable_share_has_no_cache_numbers(self):
        _, events = await self.chat(message={"text": "first"})
        cid = events[-1][1]["conversation_id"]
        self.fake.extra = 5000                                   # someone else used this Hermes session meanwhile
        _, events = await self.chat(conversation_id=cid, message={"text": "second"})
        u = events[-1][1]["usage"]
        self.assertEqual(u["input_tokens"], 14000)
        self.assertNotIn("cached_tokens", u)
        self.assertEqual(u["model"], "gpt-test-5")

    # ---- settings
    async def test_settings_roundtrip_concurrency_and_validation(self):
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertIs(caps["settings_sync"], True)
        self.assertEqual((await self.client.get("/api/settings")).status, 401)
        r = await self.client.get("/api/settings", headers=AUTH)
        self.assertEqual((await r.json(), r.headers["ETag"]), ({"version": 0, "settings": {}, "updated": None}, '"s0"'))
        good = {"theme": "dark", "read_aloud": True, "effort_default": "medium", "notifications": {"replies": True, "tasks": False},
                "personalization": {"nickname": "Kav", "style": "concise"}, "custom_instructions": "Use metric units.",
                "app.sidebar": {"collapsed": True}, "voice": "cove", "language": None}
        r = await self.client.put("/api/settings", json={"settings": good}, headers=AUTH)
        self.assertEqual((r.status, (await r.json())["code"]), (428, "version_required"))
        r = await self.client.put("/api/settings", json={"version": 0, "settings": good}, headers=AUTH)
        saved = await r.json()
        self.assertEqual((r.status, saved["version"], r.headers["ETag"]), (200, 1, '"s1"'))
        self.assertNotIn("language", saved["settings"])                                    # null removes a key
        self.assertEqual(saved["settings"]["app.sidebar"], {"collapsed": True})             # namespaced keys pass through
        r = await self.client.put("/api/settings", json={"version": 0, "settings": {"theme": "light"}}, headers=AUTH)
        body = await r.json()
        self.assertEqual((r.status, body["code"], body["current"]["version"], body["current"]["settings"]["theme"]),
                         (409, "version_conflict", 1, "dark"))
        r = await self.client.put("/api/settings", json={"settings": {**saved["settings"], "theme": "light"}},
                                  headers={**AUTH, "If-Match": '"s1"'})
        self.assertEqual(((await r.json())["version"], (await r.json())["settings"]["theme"]), (2, "light"))
        r = await self.client.get("/api/settings", headers={**AUTH, "If-None-Match": '"s2"'})
        self.assertEqual(r.status, 304)
        bad = [({"theme": "pink"}, "theme"), ({"sidebar": True}, "sidebar"), ({"notifications": {"sms": True}}, "notifications.sms"),
               ({"personalization": {"style": "loud"}}, "personalization.style"), ({"read_aloud": "yes"}, "read_aloud"),
               ({"custom_instructions": "x" * 1501}, "custom_instructions"), ({"voice": "../x"}, "voice")]
        for settings, key in bad:
            with self.subTest(key=key):
                r = await self.client.put("/api/settings", json={"version": 2, "settings": settings}, headers=AUTH)
                body = await r.json()
                self.assertEqual((r.status, body["code"], body["key"]), (400, "bad_setting", key))
        r = await self.client.put("/api/settings", json={"version": 2, "settings": {"app.blob": "x" * 40000}}, headers=AUTH)
        self.assertEqual((r.status, (await r.json())["code"]), (413, "settings_too_large"))
        r = await self.client.put("/api/settings", json={"version": 2, "settings": []}, headers=AUTH)
        self.assertEqual((r.status, (await r.json())["key"]), (400, "settings"))

    async def test_custom_instructions_reach_hermes_as_one_compact_system_message(self):
        _, _ = await self.chat(message={"text": "plain"})
        self.assertEqual(self.fake.requests[-1]["messages"][0]["role"], "user")               # nothing set: no system message
        settings = {"custom_instructions": "Use metric units.\nNo emoji.", "about_you": "I run a homelab.",
                    "personalization": {"nickname": "Kav", "occupation": "engineer", "style": "concise"}}
        await self.client.put("/api/settings", json={"version": 0, "settings": settings}, headers=AUTH)
        await self.chat(message={"text": "hello"})
        system = self.fake.requests[-1]["messages"][0]
        self.assertEqual(system["role"], "system")
        self.assertEqual(system["content"], "The user's own current settings from the app. They are up to date and take precedence over "
                                            "anything remembered about the user; follow them unless a request says otherwise:\n"
                                            "- Call the user Kav.\n- Their occupation: engineer. Fit examples, suggestions and explanations to it.\n"
                                            "- About them: I run a homelab.\n"
                                            "- Keep replies short.\n- How they want replies: Use metric units. No emoji.")
        ui = os.path.join(self.temp.name, "ui.md")
        Path(ui).write_text("UI RULES")
        bridge.CFG["ui_prompt_file"] = ui
        bridge.CFG["openui_prompt_file"] = "off"
        await self.chat(message={"text": "hello again"}, ui=1)
        msgs = self.fake.requests[-1]["messages"]
        self.assertEqual(sum(m["role"] == "system" for m in msgs), 1)
        self.assertTrue(msgs[0]["content"].startswith("UI RULES\n\nThe user's own current settings"))

    async def test_shipped_ui_prompt_has_round3_blocks_and_reaches_hermes(self):
        shipped = Path(bridge.UI_PROMPT_BUNDLED).read_text("utf-8")
        for needle in ("- entities:", "- news:", "News or a person in the news", '"v":1'):
            self.assertIn(needle, shipped)
        self.assertNotIn("````", shipped)                      # the snippet only, not the app doc around it
        bridge.CFG["ui_prompt_file"] = bridge.UI_PROMPT_BUNDLED
        await self.chat(message={"text": "news please"}, ui=1)
        self.assertEqual(self.fake.requests[-1]["messages"][0], {"role": "system", "content": shipped.strip() + "\n\n" + Path(bridge.OPENUI_PROMPT_BUNDLED).read_text("utf-8").strip()})
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertEqual((caps["ui_blocks"], caps["ui_blocks_version"]), (True, 1))
        self.assertNotIn("entity_details", caps)                # POST /api/entity is deferred (API.md)

    # ---- suggestions
    async def test_suggestions_rotate_vary_and_personalise_locally(self):
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertIs(caps["suggestions"], True)
        self.assertEqual((await self.client.get("/api/suggestions")).status, 401)
        for bad in ("0", "9", "x"):
            r = await self.client.get("/api/suggestions?n=" + bad, headers=AUTH)
            self.assertEqual((r.status, (await r.json())["code"]), (400, "bad_n"))
        bridge.SUGGEST.update(order=[], pos=0)
        seen = []
        for _ in range(3):
            data = await (await self.client.get("/api/suggestions", headers=AUTH)).json()
            items = data["suggestions"]
            self.assertEqual(len(items), 4)
            self.assertEqual(len({s["category"] for s in items}), 4)
            self.assertTrue(all(set(s) == {"id", "title", "prompt", "category"} for s in items))
            seen.append({s["id"] for s in items})
            self.assertFalse(data["personalized"])
        self.assertFalse(seen[0] & seen[1])                                   # the next call shows fresh ones
        self.store.update_conversation(self.store.create_conversation()["id"], title="Private Jellyfin movie night")
        data = await (await self.client.get("/api/suggestions?n=2", headers=AUTH)).json()
        self.assertTrue(data["personalized"])
        self.assertEqual(data["suggestions"][0]["category"], "media")
        self.assertNotIn("Private", json.dumps(data))
        data = await (await self.client.get("/api/suggestions?n=8&personalize=false", headers=AUTH)).json()
        self.assertEqual((len(data["suggestions"]), data["personalized"]), (8, False))

    def test_pick_suggestions_is_deterministic_with_a_seeded_rng(self):
        bridge.SUGGEST.update(order=[], pos=0)
        a, _ = bridge.pick_suggestions(4, rng=random.Random(7))
        bridge.SUGGEST.update(order=[], pos=0)
        b, _ = bridge.pick_suggestions(4, rng=random.Random(7))
        self.assertEqual(a, b)

    # ---- titles
    def test_rule_based_titles(self):
        self.assertEqual(bridge.simple_title("Can you check the uptime of every server?"), "Check the uptime of every server")
        self.assertEqual(bridge.simple_title("Hey Tove, how are my servers?"), "How are my servers")
        self.assertEqual(bridge.simple_title("hello there"), "Hello there")
        self.assertEqual(bridge.simple_title("Uh, can you explain more about the failed network wait service"),
                         "Explain more about the failed network…")
        self.assertEqual(bridge.simple_title("   "), "New chat")
        self.assertEqual(bridge.simple_title("What's a good name for a home server? Give me three ideas."),
                         "What's a good name for a home server")
        self.assertEqual(bridge.simple_title("Restart sonarr. Then check the logs"), "Restart sonarr")
        self.assertEqual(bridge.simple_title("Is v1.2 out? e.g. on GitHub"), "Is v1.2 out")

    async def test_default_titles_make_no_model_call(self):
        self.assertEqual(bridge.load_config({})["titles"], "auto")      # auto = simple without TITLE_API_KEY
        self.assertEqual(bridge.title_mode(), "simple") if not bridge.CFG.get("title_api_key") else None
        _, events = await self.chat(message={"text": "could you please summarise my backups"})
        self.assertEqual((events[-1][1]["title"], events[-1][1]["title_pending"]), ("Summarise my backups", False))
        await asyncio.sleep(0.05)
        self.assertEqual(len(self.fake.requests), 1)


if __name__ == "__main__":
    unittest.main()
