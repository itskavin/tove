"""POST /api/report: the app's "Report reply" action, logged to a file in the bridge's data directory.

Against the same fakes as test_chat_api. Run with the bridge venv:
  venv/bin/python -m unittest test_report
"""
import json
import os
import stat
import unittest

import test_chat_api as base

bridge = base.bridge
AUTH = base.AUTH


class ReportTest(unittest.IsolatedAsyncioTestCase):
    asyncSetUp = base.ChatApiTest.asyncSetUp
    wait_for = base.ChatApiTest.wait_for

    async def asyncSetUp(self):                                     # noqa: F811 (extends the shared setup)
        bridge.REPORTS_SENT.clear()
        await base.ChatApiTest.asyncSetUp(self)
        self.path = os.path.join(self.temp.name, "data", "reports.jsonl")
        bridge.CFG["reports_file"] = self.path

    async def asyncTearDown(self):
        bridge.REPORTS_SENT.clear()
        await base.ChatApiTest.asyncTearDown(self)

    async def post(self, body, headers=AUTH):
        return await self.client.post("/api/report", json=body, headers=headers)

    def lines(self):
        with open(self.path, encoding="utf-8") as f:
            return [json.loads(line) for line in f]

    async def test_capability(self):
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertEqual(caps["report"], {"reasons": ["offensive", "harmful", "wrong", "other"], "note_chars": 1000})

    async def test_logs_a_stored_reply_with_its_text(self):
        cid = self.store.create_conversation("Chat")["id"]
        mid = self.store.add_message(cid, "assistant", "Some bad advice", meta={"model": "hermes-x"})["id"]
        response = await self.post({"message_id": mid, "conversation_id": cid, "reason": "harmful",
                                    "note": "  dangerous  ", "hidden": True})
        self.assertEqual(response.status, 200)
        body = await response.json()
        self.assertTrue(body["ok"])
        self.assertTrue(body["id"].startswith("rep_"))
        [entry] = self.lines()
        self.assertEqual(
            {k: entry[k] for k in ("id", "reason", "note", "hidden", "message_id", "conversation_id", "found", "role",
                                   "model", "text")},
            {"id": body["id"], "reason": "harmful", "note": "dangerous", "hidden": True, "message_id": mid,
             "conversation_id": cid, "found": True, "role": "assistant", "model": "hermes-x", "text": "Some bad advice"})
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)
        # The reply itself is untouched on the server.
        self.assertEqual(self.store.get_message(mid)["text"], "Some bad advice")

    async def test_unknown_message_is_still_logged(self):
        response = await self.post({"message_id": "m_missing", "reason": "wrong"})
        self.assertEqual(response.status, 200)
        [entry] = self.lines()
        self.assertEqual((entry["found"], entry["text"], entry["hidden"], entry["note"]), (False, "", False, ""))

    async def test_validation_and_auth(self):
        for body in ({"message_id": "m", "reason": "rude"}, {"message_id": "m"}, {"reason": "other"},
                     {"message_id": "m", "reason": "other", "note": "x" * 1001},
                     {"message_id": "m", "reason": "other", "note": 5}):
            with self.subTest(body=body):
                response = await self.post(body)
                self.assertEqual((response.status, (await response.json())["code"]), (400, "bad_request"))
        self.assertEqual((await self.post({"message_id": "m", "reason": "other"}, headers={})).status, 401)
        self.assertFalse(os.path.exists(self.path))

    async def test_rate_limited(self):
        for _ in range(bridge.REPORT_RATE_PER_MIN):
            self.assertEqual((await self.post({"message_id": "m", "reason": "other"})).status, 200)
        response = await self.post({"message_id": "m", "reason": "other"})
        self.assertEqual((response.status, (await response.json())["code"]), (429, "rate_limited"))
        self.assertEqual(len(self.lines()), bridge.REPORT_RATE_PER_MIN)


if __name__ == "__main__":
    unittest.main()
