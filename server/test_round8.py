"""Round 8: warm live start (POST /api/session/warm), entity info (GET /api/entity/info) and the end-of-call tool.

No network: codex app-server, Wikipedia and Hermes are fakes.
"""
import asyncio
import importlib.util
import json
import os
import tempfile
import time
import unittest
from unittest import mock

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bridge", os.path.join(HERE, "gpt-live-bridge.py"))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

KEY = "k" * 32
AUTH = {"Authorization": "Bearer " + KEY}
OFFER = "v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\n"


class FakeProc:
    """A codex app-server that never writes; rpc() is faked separately."""
    returncode = None
    spawned = 0

    def __init__(self):
        FakeProc.spawned += 1

    class stdin:
        @staticmethod
        def write(_b):
            pass

        @staticmethod
        async def drain():
            pass

    class stdout:
        @staticmethod
        async def readline():
            await asyncio.sleep(3600)

    def kill(self):
        self.returncode = -9


class Base(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.previous = dict(bridge.CFG)
        codex_home = os.path.join(self.temp.name, "codex-home")
        os.makedirs(codex_home)
        with open(os.path.join(codex_home, "auth.json"), "w") as f:
            f.write("{}")
        bridge.CFG.update(live_key=KEY, chat_db=os.path.join(self.temp.name, "chats.sqlite"), live_backend="codex",
                          titles="simple", ui_prompt_file="off", codex_home=codex_home, link_preview=True,
                          data_dir=self.temp.name, workdir=os.path.join(self.temp.name, "work"),
                          upload_dir=os.path.join(self.temp.name, "uploads"))
        bridge.DIRECT["s"] = None
        bridge._drop_warm()
        self.calls = []
        FakeProc.spawned = 0

        async def fake_exec(*a, **kw):
            return FakeProc()

        calls = self.calls

        async def fake_rpc(ds, method, params, timeout=30):
            calls.append(method)
            if method == "initialize":
                await asyncio.sleep(0.05)              # a real spawn + initialize takes ~150 ms
            if method == "thread/realtime/start":
                ds.notifs.put_nowait({"method": "thread/realtime/sdp", "params": {"sdp": "v=0 answer"}})
            return {"thread": {"id": "t-%d" % len(calls)}} if method == "thread/start" else {}

        self.patches = [mock.patch.object(bridge.asyncio, "create_subprocess_exec", fake_exec),
                        mock.patch.object(bridge.DirectSession, "rpc", fake_rpc)]
        for p in self.patches:
            p.start()
        self.client = TestClient(TestServer(bridge.make_app()))
        await self.client.start_server()

    async def asyncTearDown(self):
        if bridge.DIRECT["s"] is not None:
            await bridge.DIRECT["s"].close()
        bridge._drop_warm()
        await asyncio.sleep(0)
        await self.client.close()
        for p in self.patches:
            p.stop()
        bridge.CFG.clear()
        bridge.CFG.update(self.previous)
        self.temp.cleanup()


class WarmStartTest(Base):
    async def test_warm_prepares_without_a_realtime_session(self):
        r = await self.client.post("/api/session/warm", json={}, headers=AUTH)
        self.assertEqual(r.status, 200)
        body = await r.json()
        self.assertTrue(body["warm"])
        self.assertEqual(body["ttl_s"], bridge.LIVE_WARM_S)
        await asyncio.sleep(0.2)
        self.assertEqual(self.calls, ["initialize", "thread/start"])        # no thread/realtime/start: no quota
        self.assertTrue(bridge.LIVE_WARM["s"].prepared)
        # A second ping keeps the same process.
        await self.client.post("/api/session/warm", json={}, headers=AUTH)
        self.assertEqual(FakeProc.spawned, 1)

    async def test_a_call_takes_the_warm_session_and_skips_prepare(self):
        await self.client.post("/api/session/warm", json={}, headers=AUTH)
        await asyncio.sleep(0.2)
        warm = bridge.LIVE_WARM["s"]
        self.calls.clear()
        r = await self.client.post("/api/session", json={"offer": OFFER}, headers=AUTH)
        data = await r.json()
        self.assertEqual(r.status, 200, data)
        self.assertEqual(data["answer"], "v=0 answer")
        self.assertIs(bridge.DIRECT["s"], warm)
        self.assertEqual(self.calls, ["thread/realtime/start"])
        self.assertTrue(data["timing"]["warm"])
        self.assertEqual(data["timing"]["prepare_ms"], 0)
        self.assertIsNone(bridge.LIVE_WARM["s"])
        # While a call runs, warm pings do nothing.
        body = await (await self.client.post("/api/session/warm", json={}, headers=AUTH)).json()
        self.assertEqual(body, {"warm": False, "reason": "in_call"})

    async def test_a_call_waits_for_a_warm_session_still_preparing(self):
        await self.client.post("/api/session/warm", json={}, headers=AUTH)
        r = await self.client.post("/api/session", json={"offer": OFFER}, headers=AUTH)   # at once
        data = await r.json()
        self.assertEqual(r.status, 200, data)
        self.assertEqual(FakeProc.spawned, 1)
        self.assertEqual(self.calls, ["initialize", "thread/start", "thread/realtime/start"])

    async def test_cold_call_still_works_and_reports_timing(self):
        data = await (await self.client.post("/api/session", json={"offer": OFFER}, headers=AUTH)).json()
        self.assertFalse(data["timing"]["warm"])
        self.assertIn("realtime_sdp_ms", data["timing"])
        self.assertIn("session_ms", data["timing"])

    async def test_warm_session_expires(self):
        with mock.patch.object(bridge, "LIVE_WARM_S", 0.1):
            await self.client.post("/api/session/warm", json={}, headers=AUTH)
            await asyncio.sleep(0.3)
        self.assertIsNone(bridge.LIVE_WARM["s"])

    async def test_auth_and_capability(self):
        self.assertEqual((await self.client.post("/api/session/warm", json={})).status, 401)
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertTrue(caps["live_warm"])



SUMMARIES = {
    "Jensen_Huang": {"type": "standard", "title": "Jensen Huang", "description": "Taiwanese-American businessman",
                     "extract": "Jensen Huang is an engineer and businessman.",
                     "thumbnail": {"source": "https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c8/J.jpg/330px-J.jpg?utm_source=x"},
                     "originalimage": {"source": "https://upload.wikimedia.org/wikipedia/commons/c/c8/J.jpg?utm_source=x"},
                     "content_urls": {"desktop": {"page": "https://en.wikipedia.org/wiki/Jensen_Huang"}}},
    "Mercury": {"type": "disambiguation", "title": "Mercury"},
    "Mercury_(planet)": {"type": "standard", "title": "Mercury (planet)", "description": "First planet from the Sun",
                         "extract": "Mercury is the first planet.",
                         "thumbnail": {"source": "http://evil.example/x.jpg"}},
}


class EntityInfoTest(Base):
    async def asyncSetUp(self):
        await super().asyncSetUp()
        bridge.ENTITY_CACHE.clear()
        self.fetched = []

        async def fake_json(s, url):
            self.fetched.append(url)
            if "/page/summary/" in url:
                title = bridge.urllib.parse.unquote(url.rsplit("/", 1)[1])
                if title in SUMMARIES:
                    return SUMMARIES[title]
                raise bridge.LinkBlocked("fetch_failed")
            if "/search/page" in url:
                if "Mercury" not in url:
                    return {"pages": []}
                return {"pages": [{"key": "Mercury"}, {"key": "Mercury_(planet)"}]}
            raise AssertionError(url)

        self.wp = mock.patch.object(bridge, "wiki_json", fake_json)
        self.wp.start()

    async def asyncTearDown(self):
        self.wp.stop()
        await super().asyncTearDown()

    async def get(self, **q):
        r = await self.client.get("/api/entity/info", params=q, headers=AUTH)
        return r.status, await r.json()

    async def test_summary_by_name(self):
        status, body = await self.get(name="Jensen Huang", hint="NVIDIA co-founder")
        self.assertEqual(status, 200)
        self.assertEqual(body["title"], "Jensen Huang")
        self.assertEqual(body["description"], "Taiwanese-American businessman")
        self.assertEqual(body["page"], "https://en.wikipedia.org/wiki/Jensen_Huang")
        # Tracking query dropped; Wikimedia hosts only.
        self.assertEqual(body["image"], "https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c8/J.jpg/330px-J.jpg")
        self.assertEqual(body["original_image"], "https://upload.wikimedia.org/wikipedia/commons/c/c8/J.jpg")
        self.assertTrue(all(u.startswith("https://en.wikipedia.org/") for u in self.fetched))

    async def test_cached(self):
        await self.get(name="Jensen Huang")
        n = len(self.fetched)
        status, _ = await self.get(name="Jensen Huang")
        self.assertEqual((status, len(self.fetched)), (200, n))

    async def test_disambiguation_falls_back_to_search_and_drops_foreign_images(self):
        status, body = await self.get(name="Mercury", hint="planet")
        self.assertEqual((status, body["title"]), (200, "Mercury (planet)"))
        self.assertIsNone(body["image"])
        self.assertTrue(any("/search/page?q=Mercury%20planet" in u for u in self.fetched))

    async def test_not_found_and_bad_requests(self):
        bridge.ENTITY_CACHE.clear()
        status, body = await self.get(name="Nobody At All")
        self.assertEqual(status, 404)
        self.assertEqual(body["code"], "not_found")
        for q in ({}, {"name": "x" * 201}, {"name": "A", "lang": "../x"}, {"wikipedia": "A|B"}):
            self.assertEqual((await self.get(**q))[0], 400, q)
        self.assertEqual((await self.client.get("/api/entity/info", params={"name": "A"})).status, 401)

    async def test_wikipedia_title_wins_and_capability(self):
        status, body = await self.get(name="Jensen", wikipedia="Jensen Huang")
        self.assertEqual(body["title"], "Jensen Huang")
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertTrue(caps["entity_info"])

    def test_no_browser_imitation(self):
        self.assertTrue(bridge.WIKI_UA.startswith("ToveBridge/"))
        self.assertNotIn("Mozilla", bridge.WIKI_UA)


class FarewellPersonaTest(unittest.TestCase):
    def test_persona_asks_for_one_short_farewell(self):
        text = bridge.live_persona()
        self.assertIn("ONE short warm farewell", text)
        self.assertIn("ends the call by itself", text)



class EmailPromptTest(unittest.TestCase):
    def test_profile_name_signs_drafts(self):
        text = bridge.settings_prompt({"app.profile": {"name": " Sam  Lee ", "photo": "x" * 50}})
        self.assertIn("Their name is Sam Lee; sign emails", text)
        self.assertNotIn("xxxx", text)
        self.assertEqual(bridge.settings_prompt({"app.profile": {"name": 5}}), "")

    def test_prompt_asks_for_email_artifacts(self):
        text = open(os.path.join(HERE, "hermes-ui-prompt.md")).read()
        self.assertIn('"kind":"email"', text)
        self.assertIn('"to"', text)
        self.assertIn('never "[Your Name]"', text)
        self.assertLess(len(text.split()), 1700)


if __name__ == "__main__":
    unittest.main()
