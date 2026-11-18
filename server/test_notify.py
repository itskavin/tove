"""POST /api/notify: messages from the assistant itself (watchdog alerts, briefings) into its own chat, with a push.

Against the same fakes as test_chat_api (a fake Hermes and a fake UnifiedPush distributor). Run with the bridge venv:
  ~/.local/share/gpt-live-bridge/venv/bin/python -m unittest test_notify
"""
import unittest

import test_chat_api as base

bridge = base.bridge
AUTH = base.AUTH
NOTIFY_KEY = "notify-fixture-key-0123456789abcdef"
NAUTH = {"Authorization": "Bearer " + NOTIFY_KEY}


class NotifyTest(unittest.IsolatedAsyncioTestCase):
    asyncSetUp = base.ChatApiTest.asyncSetUp
    asyncTearDown = base.ChatApiTest.asyncTearDown
    wait_for = base.ChatApiTest.wait_for

    async def asyncTearDown(self):                                   # noqa: F811 (extends the shared teardown)
        bridge.NOTIFY_SENT.clear()
        await base.ChatApiTest.asyncTearDown(self)

    async def post(self, body, headers=NAUTH):
        return await self.client.post("/api/notify", json=body, headers=headers)

    async def register(self):
        body = {"device_id": "phone-1", "endpoint": str(self.distributor.make_url("/up/phone"))}
        self.assertEqual((await self.client.post("/api/push/register", json=body, headers=AUTH)).status, 200)

    def setUp(self):
        bridge.NOTIFY_SENT.clear()

    async def test_disabled_without_key_and_auth_rules(self):
        bridge.CFG.update(notify_key="", assistant_name="Tove")
        self.assertEqual((await self.post({"text": "hi"})).status, 404)
        bridge.CFG["notify_key"] = NOTIFY_KEY
        for headers in ({}, AUTH, {"Authorization": "Bearer " + "x" * 40}):    # the app's key is not the notify key
            with self.subTest(headers=bool(headers)):
                response = await self.post({"text": "hi"}, headers)
                self.assertEqual((response.status, (await response.json())["code"]), (401, "unauthorized"))
        # A request that came through a public hostname is refused even with the right key.
        response = await self.post({"text": "hi"}, {**NAUTH, "Host": "chat.example.com"})
        self.assertEqual(response.status, 403)
        self.assertEqual(self.store.list_conversations()[0], [])

    async def test_posts_into_one_assistant_chat_and_pushes(self):
        bridge.CFG.update(notify_key=NOTIFY_KEY, assistant_name="Tove", push_enabled=True, push_previews=True)
        await self.register()
        r1 = await (await self.post({"text": "⚠️ Tove: homelab needs attention\n- Monitor down: NAS", "kind": "alert"})).json()
        self.assertTrue(r1["ok"])
        self.assertEqual(r1["push_devices"], 1)
        self.assertTrue(await self.wait_for(lambda: len(self.dist.pushes) == 1))
        push = self.dist.pushes[0]["body"]
        self.assertEqual((push["type"], push["status"], push["conversation_id"], push["message_id"], push["title"]),
                         ("chat.reply", "done", r1["conversation_id"], r1["message_id"], "Tove"))
        self.assertIn("Monitor down", push["preview"])
        r2 = await (await self.post({"text": "Good morning, Alex.", "kind": "briefing", "dedupe": "brief-2026-11-17"})).json()
        self.assertEqual(r2["conversation_id"], r1["conversation_id"])          # same chat
        conv = self.store.get_conversation(r1["conversation_id"])
        self.assertEqual((conv["title"], conv["title_source"], conv["message_count"]), ("Tove", "hermes", 2))
        msgs = await (await self.client.get("/api/conversations/%s/messages" % r1["conversation_id"], headers=AUTH)).json()
        last = msgs["messages"][-1]
        self.assertEqual((last["role"], last["source"], last["status"], last["meta"]), ("assistant", "notify", "complete",
                                                                                        {"notify": "briefing"}))
        # The same dedupe key is accepted once; the user deleting the chat makes the next message start a new one.
        again = await (await self.post({"text": "Good morning, Alex.", "kind": "briefing", "dedupe": "brief-2026-11-17"})).json()
        self.assertEqual(again, {"ok": True, "duplicate": True})
        await self.client.delete("/api/conversations/" + r1["conversation_id"], headers=AUTH)
        r3 = await (await self.post({"text": "Resolved: NAS"})).json()
        self.assertNotEqual(r3["conversation_id"], r1["conversation_id"])

    async def test_validation_and_rate_limit(self):
        bridge.CFG.update(notify_key=NOTIFY_KEY, assistant_name="Tove")
        for body in ({}, {"text": "  "}, {"text": "x" * (bridge.MAX_MESSAGE_CHARS + 1)}, {"text": "hi", "kind": "spam"},
                     {"text": "hi", "dedupe": "bad id!"}, {"text": 7}):
            with self.subTest(body=str(body)[:40]):
                self.assertEqual((await self.post(body)).status, 400)
        for _ in range(bridge.NOTIFY_RATE_PER_HOUR):
            self.assertEqual((await self.post({"text": "x"})).status, 200)
        self.assertEqual((await self.post({"text": "x"})).status, 429)

    async def test_user_can_reply_in_the_assistant_chat(self):
        bridge.CFG.update(notify_key=NOTIFY_KEY, assistant_name="Tove")
        cid = (await (await self.post({"text": "Monitor down: NAS", "kind": "alert"})).json())["conversation_id"]
        response = await self.client.post("/api/chat", json={"conversation_id": cid, "message": {"text": "Investigate it"}},
                                          headers=AUTH)
        events = await base.read_sse(response)
        self.assertEqual(events[-1][0], "done")
        sent = self.fake.requests[-1]["body"]["messages"]
        self.assertEqual([(m["role"], m["content"] if isinstance(m["content"], str) else "") for m in sent][-2:],
                         [("assistant", "Monitor down: NAS"), ("user", "Investigate it")])


if __name__ == "__main__":
    unittest.main()
