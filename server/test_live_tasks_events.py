"""Live-call tasks written into their chat (API.md "Live tasks in the chat") and the app's own notification stream
(API.md "Events"): GET /api/events, ?once=1 polling, POST /api/events/test.

Against the same fakes as test_chat_api (a fake Hermes and a fake UnifiedPush distributor) with a mocked codex start:
no GPT-Live session is opened. Run with the bridge venv:
  ~/.local/share/gpt-live-bridge/venv/bin/python -m unittest test_live_tasks_events
"""
import asyncio
import json
import unittest
from unittest import mock

import test_chat_api as base

bridge = base.bridge
AUTH = base.AUTH


async def fake_start(ds, offer, voice):
    return "v=0 fake answer"


async def read_events(response, n):
    """The first n named events of an SSE response as (id or None, event, data), heartbeat comments counted apart."""
    out, beats, eid, event, data = [], 0, None, None, []
    while len(out) < n:
        raw = await asyncio.wait_for(response.content.readline(), 5)
        if not raw:
            break
        line = raw.decode().rstrip("\n")
        if line.startswith(":"):
            beats += 1
            out.append((None, ":", line))
            continue
        if not line:
            if event:
                out.append((eid, event, json.loads("\n".join(data))))
            eid, event, data = None, None, []
        elif line.startswith("id: "):
            eid = int(line[4:])
        elif line.startswith("event: "):
            event = line[7:]
        elif line.startswith("data: "):
            data.append(line[6:])
    return out


class LiveTasksTest(unittest.IsolatedAsyncioTestCase):
    asyncSetUp = base.ChatApiTest.asyncSetUp
    wait_for = base.ChatApiTest.wait_for
    pushes = base.ChatApiTest.pushes
    endpoint = base.ChatApiTest.endpoint
    register = base.ChatApiTest.register

    def setUp(self):
        bridge.EVENTS.update(wake=None, readers={}, tests=bridge.collections.deque())
        bridge.LIVE_SESSIONS.clear()

    async def asyncTearDown(self):
        await base.ChatApiTest.asyncTearDown(self)
        bridge.EVENTS.update(wake=None, readers={})
        bridge.LIVE_SESSIONS.clear()

    async def call(self, conv_id=None):
        body = {"offer": "v=0 offer", **({"conversation_id": conv_id} if conv_id else {})}
        with mock.patch.object(bridge.DirectSession, "start", fake_start):
            data = await (await self.client.post("/api/session", json=body, headers=AUTH)).json()
        return data["session"]

    async def delegate(self, sid, text="check backups"):
        response = await self.client.post("/api/delegate", json={"session": sid, "text": text}, headers=AUTH)
        self.assertEqual(response.status, 200)
        return (await response.json())["job"]

    def task_message(self, cid):
        return [m for m in self.store.messages(cid)[0] if m["source"] == "task"][-1]

    # ---- part 1: a linked call's task is a chat message from its start and outlives the call
    async def test_task_is_a_streaming_chat_message_that_outlives_the_call(self):
        conv = self.store.create_conversation("Voice chat")
        self.fake.mode = "gated"
        sid = await self.call(conv["id"])
        jid = await self.delegate(sid)
        self.assertTrue(await self.wait_for(lambda: self.fake.requests))
        msg = self.task_message(conv["id"])
        self.assertEqual((msg["role"], msg["status"], msg["client_id"], msg["meta"]["task"], msg["meta"]["job"], msg["meta"]["session"]),
                         ("assistant", "streaming", "job:%s:%s" % (sid, jid), "check backups", jid, sid))
        # The app sees it in the chat at once, links the call's job to it, and can follow it after the call ends.
        listed = await (await self.client.get("/api/conversations/%s" % conv["id"], headers=AUTH)).json()
        self.assertEqual(listed["messages"][-1]["status"], "streaming")
        job = await (await self.client.get("/api/job/%s/%s" % (sid, jid), headers=AUTH)).json()
        self.assertEqual((job["status"], job["message_id"], job["conversation_id"]), ("running", msg["id"], conv["id"]))
        await self.client.post("/api/stop", json={"session": sid}, headers=AUTH)
        self.assertIsNone(bridge.DIRECT["s"])
        jobs = await (await self.client.get("/api/session/%s/jobs" % sid, headers=AUTH)).json()   # ended calls stay readable
        self.assertEqual((jobs["ended"], jobs["conversation_id"], jobs["jobs"][0]["message_id"]), (True, conv["id"], msg["id"]))
        stream = await self.client.get("/api/chat/%s/stream" % msg["id"], headers=AUTH)
        self.assertEqual(stream.status, 200)
        self.assertTrue(await self.wait_for(lambda: self.fake.requests and "partial" in "".join(
            bridge.CHAT["jobs"][msg["id"]].parts)))
        self.fake.release.set()
        events = await base.read_sse_ids(stream)
        names = [e[1] for e in events]
        self.assertEqual(names[0], "meta")
        self.assertEqual((events[0][2]["source"], events[0][2]["job"], events[0][2]["session"]), ("task", jid, sid))
        self.assertIn("delta", names)
        self.assertEqual(names[-1], "done")
        self.assertEqual("".join(e[2]["text"] for e in events if e[1] == "delta"), "partial rest")
        saved = self.store.get_message(msg["id"])
        self.assertEqual((saved["status"], saved["text"], saved["meta"]["job"]), ("complete", "partial rest", jid))
        self.assertIsInstance(saved["meta"]["seconds"], int)
        done = await (await self.client.get("/api/job/%s/%s" % (sid, jid), headers=AUTH)).json()
        self.assertEqual((done["status"], done["markdown"], done["answer"]), ("done", "partial rest", "partial rest"))
        # A reader was following it: no push. Resuming after the end replays from the saved message.
        await asyncio.sleep(0.2)
        self.assertEqual(self.dist.pushes, [])
        again = await base.read_sse_ids(await self.client.get("/api/chat/%s/stream?last_event_id=1" % msg["id"], headers=AUTH))
        self.assertEqual(again[-1][1], "done")

    async def test_task_gets_the_ui_prompt_and_history_and_its_voice_answer_reads_blocks(self):
        prompt = bridge.Path(self.temp.name) / "ui.md"
        prompt.write_text("APP UI PROMPT")
        bridge.CFG["openui_prompt_file"] = "off"
        bridge.CFG.update(ui_prompt_file=str(prompt))
        conv = self.store.create_conversation()
        self.store.add_message(conv["id"], "user", "typed earlier")
        sid = await self.call(conv["id"])
        jid = await self.delegate(sid, "how is the disk")
        self.assertTrue(await self.wait_for(lambda: bridge.DIRECT["s"].jobs[jid]["status"] == "done"))
        sent = self.fake.requests[-1]["body"]["messages"]
        self.assertEqual((sent[0]["role"], sent[0]["content"]), ("system", "APP UI PROMPT"))
        self.assertEqual(sent[1]["content"], "typed earlier")
        self.assertTrue(sent[-1]["content"].startswith(bridge.TASK_CHAT_NOTE))
        bridge.CFG["task_ui"] = False
        jid = await self.delegate(sid, "and the backups")
        self.assertTrue(await self.wait_for(lambda: bridge.DIRECT["s"].jobs[jid]["status"] == "done"))
        self.assertNotEqual(self.fake.requests[-1]["body"]["messages"][0]["role"], "system")
        # The second task sees the first one's result as history, as before.
        self.assertIn({"role": "assistant", "content": "Hello world"}, self.fake.requests[-1]["body"]["messages"])
        block = '```hermes-ui\n{"type": "stats", "v": 1, "items": [{"label": "Free", "value": "412 GB", "tone": "good"}]}\n```'
        voice = bridge.plain_for_voice("**Disk** is fine.\n\n" + block + "\n\n```hermes-html\n<p>Load <b>0.4</b></p>\n```")
        self.assertEqual(voice, "Disk is fine.\n\n Free; 412 GB. \n\n Load 0.4.")
        self.assertNotIn("hermes-ui", voice)

    async def test_task_failure_stop_and_limits(self):
        await self.register()
        conv = self.store.create_conversation("Voice chat")
        sid = await self.call(conv["id"])
        self.fake.mode = "fail"
        jid = await self.delegate(sid)
        self.assertTrue(await self.wait_for(lambda: bridge.DIRECT["s"].jobs[jid]["status"] == "failed"))
        failed = self.task_message(conv["id"])
        self.assertEqual((failed["status"], failed["meta"]["error_code"]), ("error", "hermes_error"))
        # A running task neither counts against the chat reply limit nor is stopped by a retry in that chat.
        self.fake.mode = "gated"
        jid = await self.delegate(sid, "long task")
        self.assertTrue(await self.wait_for(lambda: len(bridge.running_jobs()) == 1))
        bridge.CFG["max_chats"] = 1
        self.store.add_message(conv["id"], "user", "typed question")
        response = await self.client.post("/api/chat", json={"conversation_id": conv["id"], "retry": True}, headers=AUTH)
        self.assertEqual(response.status, 200)
        await asyncio.sleep(0.1)
        task = self.task_message(conv["id"])
        self.assertEqual(task["status"], "streaming")
        self.fake.release.set()
        await base.read_sse(response)
        self.fake.release.clear()
        self.assertTrue(await self.wait_for(lambda: self.store.get_message(task["id"])["status"] == "complete"))
        # The stop route stops a task too; the call's job then reads failed + stopped.
        jid = await self.delegate(sid, "another long task")
        self.assertTrue(await self.wait_for(lambda: bridge.DIRECT["s"].jobs[jid].get("message_id")))
        mid = bridge.DIRECT["s"].jobs[jid]["message_id"]
        stop = await (await self.client.post("/api/chat/%s/stop" % mid, headers=AUTH)).json()
        self.assertEqual((stop["stopped"], stop["status"]), (True, "cancelled"))
        job = await (await self.client.get("/api/job/%s/%s" % (sid, jid), headers=AUTH)).json()
        self.assertEqual((job["status"], job.get("stopped")), ("failed", True))

    async def test_restart_marks_a_running_task_interrupted(self):
        conv = self.store.create_conversation()
        mid = self.store.add_message(conv["id"], "assistant", "half", "task", status="streaming", meta={"job": "j1"})["id"]
        reopened = bridge.ChatStore(self.db_path)
        self.assertEqual(reopened.get_message(mid)["status"], "interrupted")
        reopened.close()
        self.store.update_message(mid, status="interrupted")
        events = await base.read_sse_ids(await self.client.get("/api/chat/%s/stream" % mid, headers=AUTH))
        self.assertEqual([(e[1], e[2].get("code")) for e in events], [("snapshot", None), ("error", "interrupted")])

    async def test_unlinked_call_task_runs_the_old_way(self):
        sid = await self.call()
        jid = await self.delegate(sid, "what time is it")
        self.assertTrue(await self.wait_for(lambda: bridge.DIRECT["s"].jobs[jid]["status"] == "done"))
        self.assertEqual(self.store.list_conversations()[0], [])
        self.assertTrue(self.fake.requests[-1]["body"]["messages"][-1]["content"].startswith(bridge.VOICE_TASK_NOTE))
        once = await (await self.client.get("/api/events?after=0&once=1", headers=AUTH)).json()
        self.assertEqual([(e["type"], e["data"]["conversation_id"], e["data"]["status"]) for e in once["events"]],
                         [("task.done", None, "done")])

    # ---- part 2: the events stream
    async def test_events_stream_carries_replies_tasks_and_notes_without_tool_io(self):
        bridge.CFG.update(notify_key="notify-fixture-key-0123456789abcdef", assistant_name="Tove")
        await self.register()
        stream = await self.client.get("/api/events?device_id=phone-1", headers=AUTH)
        self.assertEqual((stream.status, stream.headers["Content-Type"]), (200, "text/event-stream; charset=utf-8"))
        hello = (await read_events(stream, 1))[0]
        self.assertEqual((hello[0], hello[1], hello[2]["version"], hello[2]["last_id"], hello[2]["reset"]), (None, "hello", 1, 0, None))
        self.assertEqual(bridge.event_devices(), {"phone-1"})
        # A typed reply that ran a tool (`df -h`), nobody reading its stream: the event has ids, status and a preview.
        response = await self.client.post("/api/chat", json={"message": {"text": "disk?"}}, headers=AUTH)
        await base.read_sse(response)
        conv = self.store.list_conversations()[0][0]
        conv_id = conv["id"]
        sid = await self.call(conv_id)
        jid = await self.delegate(sid)
        self.assertTrue(await self.wait_for(lambda: bridge.DIRECT["s"].jobs[jid]["status"] == "done"))
        await self.client.post("/api/notify", json={"text": "Monitor down: NAS", "kind": "alert"},
                               headers={"Authorization": "Bearer notify-fixture-key-0123456789abcdef"})
        seen, got = [], []
        while len(got) < 4:                      # sync events (round 6 D4) arrive in between
            batch = [e for e in await read_events(stream, 1) if e[1] != ":"]
            seen += batch
            got += [e for e in batch if e[1] in ("reply.done", "task.started", "task.done", "notify")]
        self.assertEqual([e[1] for e in got], ["reply.done", "task.started", "task.done", "notify"])
        self.assertEqual([e[0] for e in seen], list(range(1, len(seen) + 1)))
        reply, started, done, note = (e[2] for e in got)
        self.assertEqual((reply["conversation_id"], reply["status"], reply["preview"], reply["title"], reply["watched"]),
                         (conv_id, "done", "Hello world", conv["title"], True))
        self.assertEqual((started["request"], started["conversation_id"]), ("check backups", conv_id))
        self.assertEqual((done["status"], done["message_id"], done["preview"]), ("done", started["message_id"], "Hello world"))
        self.assertEqual((note["kind"], note["title"], note["preview"]), ("alert", "Tove", "Monitor down: NAS"))
        for e in seen:
            self.assertNotIn("df -h", json.dumps(e[2]))                    # never tool input or output
            self.assertNotIn("steps", e[2])
        # The phone hears everything over the stream, so UnifiedPush skips it while the stream is open.
        await asyncio.sleep(0.2)
        self.assertEqual(self.dist.pushes, [])
        stream.close()
        self.assertTrue(await self.wait_for(lambda: not bridge.EVENTS["readers"]))
        await self.client.post("/api/notify", json={"text": "Resolved: NAS"},
                               headers={"Authorization": "Bearer notify-fixture-key-0123456789abcdef"})
        self.assertEqual((await self.pushes(1))[0]["type"], "chat.reply")

    async def test_sync_events_mirror_every_chat_change(self):
        """Round 6 D4: every open client hears chat and message changes, marked with the device that made them."""
        dev = {**AUTH, "X-Device-Id": "pc-web"}
        once = lambda: self.client.get("/api/events?after=0&once=1", headers=AUTH)
        response = await self.client.post("/api/chat", json={"message": {"text": "disk usage on storage please"}}, headers=dev)
        meta = (await base.read_sse(response))[0][1]
        cid, mid = meta["conversation_id"], meta["message_id"]
        events = (await (await once()).json())["events"]
        kinds = [e["type"] for e in events]
        self.assertEqual(kinds[:4], ["conversation.created", "message.created", "message.created", "reply.started"])
        self.assertIn("reply.done", kinds)
        created, user, asst, started = (e["data"] for e in events[:4])
        self.assertEqual((created["conversation"]["id"], created["origin"]), (cid, "pc-web"))
        self.assertEqual((user["message"]["role"], user["message"]["text"], user["conversation"]["message_count"]),
                         ("user", "disk usage on storage please", 1))
        self.assertEqual((asst["message_id"], asst["message"]["status"]), (mid, "streaming"))
        self.assertNotIn("steps", json.dumps(asst))
        self.assertEqual((started["message_id"], started["user_message_id"]), (mid, meta["user_message_id"]))
        last = events[-1]["id"]
        # Rename, pin, retry, delete a message, import a transcript, delete the chat.
        await self.client.patch("/api/conversations/" + cid, json={"title": "Storage disk", "pinned": True}, headers=AUTH)
        await base.read_sse(await self.client.post("/api/chat", json={"conversation_id": cid, "retry": True}, headers=AUTH))
        long = "x" * (bridge.SYNC_TEXT_CHARS + 50)
        await base.read_sse(await self.client.post("/api/chat", json={"conversation_id": cid, "message": {"text": long}}, headers=AUTH))
        user2 = self.store.last_user_message(cid)
        await self.client.delete("/api/conversations/%s/messages/%s" % (cid, user2["id"]), headers=AUTH)
        turns = [{"id": "t%d" % i, "role": "user" if i % 2 == 0 else "assistant", "text": "turn %d words here" % i} for i in range(4)]
        r = await self.client.post("/api/conversations/%s/live-transcript" % cid, json={"turns": turns}, headers=AUTH)
        self.assertEqual((await r.json())["added"], 4)
        await self.client.delete("/api/conversations/" + cid, headers=AUTH)
        later = (await (await self.client.get("/api/events?after=%d&once=1" % last, headers=AUTH)).json())["events"]
        kinds = [e["type"] for e in later]
        self.assertEqual(kinds[:2], ["conversation.title", "conversation.updated"])
        self.assertEqual((later[0]["data"]["title"], later[0]["data"]["title_source"]), ("Storage disk", "user"))
        self.assertEqual(later[1]["data"]["changes"], ["pinned"])
        self.assertEqual(later[2]["type"], "message.deleted")                     # the retry drops the old reply
        self.assertEqual(later[2]["data"]["message_id"], mid)
        long_user = [e["data"] for e in later if e["type"] == "message.created" and e["data"]["message"]["role"] == "user"][0]
        self.assertEqual((len(long_user["message"]["text"]), long_user["message"]["truncated"]), (bridge.SYNC_TEXT_CHARS, True))
        self.assertIn(("message.deleted", user2["id"]), [(e["type"], e["data"].get("message_id")) for e in later])
        imported = [e["data"] for e in later if e["type"] == "conversation.updated" and e["data"]["changes"] == ["messages"]]
        self.assertEqual(len(imported), 1, "one event for the whole transcript")
        self.assertIn(["kind"], [e["data"]["changes"] for e in later if e["type"] == "conversation.updated"])
        self.assertEqual(kinds[-1], "conversation.deleted")
        self.assertNotIn("origin", later[0]["data"])
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertIn("message.created", caps["events"]["types"])
        self.assertIs(caps["events"]["sync"], True)

    async def test_events_resume_poll_reset_heartbeat_and_test(self):
        self.assertEqual((await self.client.get("/api/events")).status, 401)
        for path in ("/api/events?after=x", "/api/events?heartbeat=5", "/api/events?device_id=bad%20id"):
            self.assertEqual((await self.client.get(path, headers=AUTH)).status, 400, path)
        for n in range(3):
            bridge.emit_event("test", n=n)
        # Resume: Last-Event-ID wins over ?after=; replays what came after it, then follows live.
        stream = await self.client.get("/api/events?after=0", headers={**AUTH, "Last-Event-ID": "1"})
        got = await read_events(stream, 3)
        self.assertEqual([(e[0], e[1]) for e in got], [(None, "hello"), (2, "test"), (3, "test")])
        bridge.emit_event("test", n=3)
        self.assertEqual((await read_events(stream, 1))[0][:2], (4, "test"))
        stream.close()
        # Poll (the background check): JSON, and an empty answer keeps the cursor.
        once = await (await self.client.get("/api/events?after=2&once=1", headers=AUTH)).json()
        self.assertEqual(([e["id"] for e in once["events"]], once["last_id"], once["reset"]), ([3, 4], 4, None))
        empty = await (await self.client.get("/api/events?after=4&once=1", headers=AUTH)).json()
        self.assertEqual((empty["events"], empty["last_id"]), ([], 4))
        # Without a cursor a stream starts with new events only.
        fresh = await self.client.get("/api/events", headers=AUTH)
        self.assertEqual((await read_events(fresh, 1))[0][2]["last_id"], 4)
        fresh.close()
        # An id the bridge never issued (a new database) and a trimmed gap both say reset.
        ahead = await (await self.client.get("/api/events?after=99&once=1", headers=AUTH)).json()
        self.assertEqual((ahead["reset"], ahead["last_id"]), ("unknown_id", 4))
        self.store.db.execute("DELETE FROM events WHERE id <= 3")
        gap = await (await self.client.get("/api/events?after=1&once=1", headers=AUTH)).json()
        self.assertEqual((gap["reset"], [e["id"] for e in gap["events"]]), ("gap", [4]))
        # Heartbeats: a comment after `heartbeat_s` of silence (shortened here).
        bridge.CFG["events_heartbeat_s"] = 0.2
        beat = await self.client.get("/api/events", headers=AUTH)
        self.assertEqual([e[1] for e in await read_events(beat, 2)], ["hello", ":"])
        beat.close()
        # The test button, rate limited; readers are capped.
        self.assertEqual((await (await self.client.post("/api/events/test", headers=AUTH)).json())["ok"], True)
        for _ in range(5):
            await self.client.post("/api/events/test", headers=AUTH)
        self.assertEqual((await self.client.post("/api/events/test", headers=AUTH)).status, 429)
        bridge.EVENTS["readers"].update({"r%d" % i: None for i in range(bridge.EVENT_READERS_MAX)})
        self.assertEqual((await self.client.get("/api/events", headers=AUTH)).status, 429)
        bridge.EVENTS["readers"].clear()
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertEqual((caps["events"]["version"], caps["events"]["poll"], caps["task_messages"], caps["jobs_after_call"]),
                         (1, True, True, True))
        self.assertIn("task.done", caps["events"]["types"])

    async def test_event_trim_keeps_ids_growing(self):
        bridge.CFG["events_keep"] = 50
        for n in range(120):
            bridge.emit_event("test", n=n)
        first, last = self.store.events_bounds()
        self.assertEqual(last, 120)
        self.assertGreater(first, 1)
        self.store.db.execute("DELETE FROM events")
        self.assertEqual(self.store.events_bounds(), (None, 120))
        self.assertEqual(bridge.emit_event("test"), 121)


if __name__ == "__main__":
    unittest.main()
