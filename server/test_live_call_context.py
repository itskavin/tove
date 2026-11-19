"""Live calls keep their context (a task carries the call so far, no greeting mid-call) and an empty call leaves the
chat list alone (no kind change, no reorder). Fake Hermes, mocked codex start and a mocked OpenAI Live sideband: no
real voice session is opened. Run with the bridge venv:
  ~/.local/share/gpt-live-bridge/venv/bin/python -m unittest test_live_call_context
"""
import json
import unittest
from unittest import mock

import test_chat_api as base
import test_openai_backend as oai_base

bridge = base.bridge
AUTH = base.AUTH

# The call that went wrong (names and places are fixtures). The voice model asked three questions in a row, then
# handed over only the last answer: Hermes saw "No idea. I'm here. I'm with my home" and greeted the user.
TRIP_CALL = [
    ("user", "We are planning to go at a weekend trip, so give us a plan"),
    ("assistant", "Fun. Tell me a bit more about it. What kind of trip? Mountains, beach, city? What's the vibe?"),
    ("user", "Oh it's more of a city, I think"),
    ("assistant", "Mm. And, uh, when are you leaving?"),
    ("user", "A weekend"),
    ("assistant", "Okay. And, where are you starting from?"),
    ("user", "No idea. I'm here. I'm with my home"),
]
LAST_UTTERANCE = TRIP_CALL[-1][1]
GREETING_REPLY = "Hey, Sam. Here's a weekend city plan from Pune: Saturday in the old town, Sunday by the river."


async def fake_start(ds, offer, voice):
    return "v=0 fake answer"


class CodexCallContextTest(unittest.IsolatedAsyncioTestCase):
    """The codex backend: the app runs delegations and posts /api/delegate with the call's newest turns."""
    asyncSetUp = base.ChatApiTest.asyncSetUp
    asyncTearDown = base.ChatApiTest.asyncTearDown
    wait_for = base.ChatApiTest.wait_for

    async def call(self, conv_id=None):
        body = {"offer": "v=0 offer", **({"conversation_id": conv_id} if conv_id else {})}
        with mock.patch.object(bridge.DirectSession, "start", fake_start):
            response = await self.client.post("/api/session", json=body, headers=AUTH)
        self.assertEqual(response.status, 200)
        return (await response.json())["session"]

    async def delegate(self, sid, text, context=None, status=200, **extra):
        body = {"session": sid, "text": text, **({"context": context} if context is not None else {}), **extra}
        response = await self.client.post("/api/delegate", json=body, headers=AUTH)
        data = await response.json()
        self.assertEqual(response.status, status, data)
        return data.get("job") if status == 200 else data

    def hermes_task(self):
        """The last message the fake Hermes got for the newest streamed task."""
        streamed = [r for r in self.fake.requests if r["body"].get("stream")]
        return streamed[-1]["body"]["messages"][-1]["content"]

    @staticmethod
    def context(turns):
        return [{"role": r, "text": t} for r, t in turns]

    # ---- (a) the call's context reaches Hermes
    async def test_task_carries_the_recent_call_transcript(self):
        conv = self.store.create_conversation()
        sid = await self.call(conv["id"])
        turns = [("user" if i % 2 == 0 else "assistant", "turn number %d" % i) for i in range(14)] + [("user", "check backups")]
        job = await self.delegate(sid, "check backups", self.context(turns))
        ds = bridge.DIRECT["s"]
        self.assertTrue(await self.wait_for(lambda: ds.jobs[job]["status"] == "done"))
        task = self.hermes_task()
        self.assertTrue(task.startswith(bridge.TASK_CHAT_NOTE))
        self.assertIn("Earlier in this call (voice transcript):", task)
        self.assertTrue(task.endswith("The request to handle now: check backups"))
        self.assertNotIn("turn number 3\n", task + "\n")                    # only the newest 10 turns go along
        self.assertIn("Assistant: turn number 13", task)
        self.assertEqual(task.count("check backups"), 1, "the repeated last utterance is not sent twice")
        msg = [m for m in self.store.messages(conv["id"])[0] if m["source"] == "task"][-1]
        self.assertEqual(msg["meta"]["task"], "check backups", "the chat keeps the short request, not the transcript")

    async def test_bad_context_is_refused_and_no_context_is_unchanged(self):
        sid = await self.call()
        for bad in ("x", [{"role": "system", "text": "x"}], [{"role": "user"}], [{"role": "user", "text": "x"}] * 51):
            with self.subTest(bad=str(bad)[:40]):
                data = await self.delegate(sid, "check backups", bad, status=400)
                self.assertEqual(data["code"], "bad_context")
        await self.delegate(sid, "check backups", location="Pune", status=400)
        ds = bridge.DIRECT["s"]
        job = await self.delegate(sid, "check backups")
        self.assertTrue(await self.wait_for(lambda: ds.jobs[job]["status"] == "done"))
        self.assertTrue(self.hermes_task().endswith("\n\ncheck backups"))
        self.assertEqual(ds.jobs[job]["request"], "check backups")

    async def test_shared_location_goes_with_the_task(self):
        sid = await self.call()
        job = await self.delegate(sid, "Plan a weekend city trip", location={"lat": 18.52, "lng": 73.86, "label": "Pune, IN"})
        ds = bridge.DIRECT["s"]
        self.assertTrue(await self.wait_for(lambda: ds.jobs[job]["status"] == "done"))
        self.assertIn("approximate location, shared by the app for this message: Pune, IN", self.hermes_task())

    # ---- the scripted call from the report, both ways the voice model may hand it over
    async def test_scripted_trip_call_keeps_the_goal_and_never_greets_mid_call(self):
        self.fake.mode, self.fake.json_text = "json", GREETING_REPLY
        handovers = {
            # What the new persona asks for: a self-contained task with every detail gathered.
            "self-contained": "Plan a weekend city trip for this Saturday and Sunday, starting from the user's home city; "
                              "they are flexible on the destination.",
            # What happened: only the user's last sentence.
            "last utterance": LAST_UTTERANCE,
        }
        for name, task_text in handovers.items():
            with self.subTest(handover=name):
                conv = self.store.create_conversation()
                sid = await self.call(conv["id"])
                ds = bridge.DIRECT["s"]
                job = await self.delegate(sid, task_text, self.context(TRIP_CALL))
                self.assertTrue(await self.wait_for(lambda: ds.jobs[job]["status"] == "done"))
                task = self.hermes_task()
                for detail in ("weekend trip, so give us a plan", "more of a city", "User: A weekend", task_text):
                    self.assertIn(detail, task)                         # the goal and every detail reach Hermes
                self.assertIn(bridge.MID_CALL_RULES, task)
                self.assertIn("do not greet the user", task)
                result = await (await self.client.get("/api/job/%s/%s" % (sid, job), headers=AUTH)).json()
                self.assertTrue(result["answer"].startswith("Here's a weekend city plan"), result["answer"])
                self.assertNotRegex(result["answer"], r"(?i)^\s*(hey|hi|hello)\b")
                # The reply goes into the same chat as the call's task message; the chat is a voice chat now.
                msgs = self.store.messages(conv["id"])[0]
                self.assertEqual([(m["source"], m["meta"].get("session")) for m in msgs], [("task", sid)])
                self.assertEqual(self.store.get_conversation(conv["id"])["kind"], "live")
                await ds.close()

    async def test_voice_copy_drops_only_a_leading_greeting(self):
        cases = {
            "Hey, Sam. You're home. What's on your mind?": "You're home. What's on your mind?",
            "Hi there! The disk is 40% full.": "The disk is 40% full.",
            "Good evening, Sam — backups ran at 2.": "Backups ran at 2.",
            "Hello": "Hello",                                            # nothing else to say: kept
            "Heyday prices are up 4%.": "Heyday prices are up 4%.",
            "The **hi-fi** shop opens at 10.": "The hi-fi shop opens at 10.",
        }
        for raw, spoken in cases.items():
            with self.subTest(raw=raw):
                self.assertEqual(bridge.task_voice(raw), spoken)

    def test_persona_asks_little_and_hands_over_self_contained_tasks(self):
        text = bridge.live_persona()
        self.assertIn("at most ONE short clarifying question", text)
        self.assertIn("Greet only once, at the very start of the call", text)
        self.assertIn("\"this weekend\" means the coming Saturday and Sunday", text)
        self.assertIn("\"I'm at home\"", text)
        self.assertIn("self-contained description with the user's goal and every detail", text)
        self.assertIn("Give me a moment, I'm planning it", text)
        self.assertIn("never read it twice", text)
        self.assertNotIn("Ask ONE short clarifying question instead of guessing", text)

    # ---- PROBLEM 2: an empty call leaves the chat list alone
    async def test_empty_call_changes_neither_kind_nor_order(self):
        typed = self.store.create_conversation()
        self.store.add_message(typed["id"], "user", "typed question")
        blank = self.store.create_conversation()
        before = {c["id"]: c for c in (self.store.get_conversation(typed["id"]), self.store.get_conversation(blank["id"]))}
        last = (await (await self.client.get("/api/events?after=0&once=1", headers=AUTH)).json())["last_id"]
        for cid in before:
            sid = await self.call(cid)
            self.assertEqual((await self.client.post("/api/stop", json={"session": sid}, headers=AUTH)).status, 200)
            # The app posts nothing for a call without speech; an empty post changes nothing either.
            r = await self.client.post("/api/conversations/%s/live-transcript" % cid, json={"session": sid, "turns": []}, headers=AUTH)
            self.assertEqual((await r.json())["added"], 0)
        for cid, old in before.items():
            now = self.store.get_conversation(cid)
            self.assertEqual((now["kind"], now["updated"]), ("text", old["updated"]))
        later = (await (await self.client.get("/api/events?after=%d&once=1" % last, headers=AUTH)).json())["events"]
        self.assertEqual([e for e in later if e["type"].startswith("conversation.")], [])

    async def test_call_in_a_typed_chat_keeps_it_a_text_chat(self):
        typed = self.store.create_conversation()
        self.store.add_message(typed["id"], "user", "typed question")
        sid = await self.call(typed["id"])
        turns = [{"id": "t1", "role": "user", "text": "and how about tomorrow"}, {"id": "t2", "role": "assistant", "text": "Sunny."}]
        r = await self.client.post("/api/conversations/%s/live-transcript" % typed["id"], json={"session": sid, "turns": turns}, headers=AUTH)
        self.assertEqual((await r.json())["added"], 2)
        job = await self.delegate(sid, "check backups")
        ds = bridge.DIRECT["s"]
        self.assertTrue(await self.wait_for(lambda: ds.jobs[job]["status"] == "done"))
        self.assertEqual(self.store.get_conversation(typed["id"])["kind"], "text")
        voice = [m for m in self.store.messages(typed["id"])[0] if m["source"] == "voice"]
        self.assertEqual(len(voice), 2, "the spoken turns are kept, marked as voice")

    async def test_voice_only_chat_becomes_live_once_the_call_says_something(self):
        conv = self.store.create_conversation()
        sid = await self.call(conv["id"])
        self.assertEqual(self.store.get_conversation(conv["id"])["kind"], "text")
        turns = [{"id": "t1", "role": "user", "text": "what time is it in Tokyo"}]
        r = await self.client.post("/api/conversations/%s/live-transcript" % conv["id"], json={"session": sid, "turns": turns}, headers=AUTH)
        self.assertEqual((await r.json())["conversation"]["kind"], "live")


class OpenAICallContextTest(unittest.IsolatedAsyncioTestCase):
    """The openai backend: the bridge sees the transcript itself and runs the delegation."""
    asyncSetUp = oai_base.OpenAIBackendTest.asyncSetUp
    asyncTearDown = oai_base.OpenAIBackendTest.asyncTearDown
    start = oai_base.OpenAIBackendTest.start
    events = oai_base.OpenAIBackendTest.events
    wait_for = base.ChatApiTest.wait_for

    async def test_scripted_trip_call_reaches_hermes_with_its_goal(self):
        obridge = oai_base.bridge
        self.hermes.answer = GREETING_REPLY
        conv = self.store.create_conversation()
        _, data = await self.start(conversation_id=conv["id"])
        self.assertTrue(await self.wait_for(self.oai.attached.is_set))
        created = json.dumps(self.oai.creates[-1]["body"])
        self.assertIn("at most ONE short clarifying question", created)
        n, t = 0, 100
        for role, text in TRIP_CALL:
            n += 1
            kind = "session.input_transcript.delta" if role == "user" else "session.output_transcript.delta"
            await self.oai.push({"type": kind, "event_id": "e%d" % n, "delta": text, "start_ms": t, "end_ms": t + 1500})
            t += 25000                                                   # each turn its own message
        await self.oai.push({"type": "session.delegation.created", "event_id": "d1",
                             "delegation": {"id": "item_trip", "type": "delegation", "target": "client"}})
        self.assertTrue(await self.wait_for(lambda: self.events("session.commentary.append"), 5), self.oai.client_events)
        task = self.hermes.requests[-1]["messages"][-1]["content"]
        for detail in ("weekend trip, so give us a plan", "more of a city", "User: A weekend",
                       "The request to handle now: " + LAST_UTTERANCE):
            self.assertIn(detail, task)
        self.assertIn(obridge.MID_CALL_RULES, task)
        said = self.events("session.commentary.append")
        self.assertEqual(len(said), 1, "the result is spoken once")
        self.assertNotRegex(said[0]["content"], r"(?i)^\s*(hey|hi|hello)\b")
        task_msgs = [m for m in self.store.messages(conv["id"])[0] if m["source"] == "task"]
        self.assertEqual(len(task_msgs), 1)
        self.assertEqual(task_msgs[0]["meta"]["session"], data["session"])


if __name__ == "__main__":
    unittest.main()
