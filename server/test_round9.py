"""Round 9: pictures for named things in replies (`entity:` references, entities blocks, "Who is X?" subjects) and
the priority tier on the title call. No network: Wikipedia, Hermes and the image fetches are fakes.
  ~/.local/share/gpt-live-bridge/venv/bin/python -m unittest test_round9
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
spec = importlib.util.spec_from_file_location("bridge_r9", os.path.join(HERE, "gpt-live-bridge.py"))
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

KEY = "k" * 32
AUTH = {"Authorization": "Bearer " + KEY}
UP = "https://upload.wikimedia.org/wikipedia/commons/"


def summary(title, image=None, kind="standard"):
    d = {"type": kind, "title": title, "description": "d", "extract": "x.",
         "content_urls": {"desktop": {"page": "https://en.wikipedia.org/wiki/" + title.replace(" ", "_")}}}
    if image:
        d["originalimage"] = {"source": UP + image}
        d["thumbnail"] = {"source": UP + "thumb/" + image + "/330px-x.jpg?utm_source=x"}
    return d


SUMMARIES = {s["title"]: s for s in (
    summary("Eiffel Tower", "a/a1/Eiffel.jpg"), summary("Tata Nexon", "b/b2/Nexon.jpg"), summary("Red panda", "c/c3/Panda.jpg"),
    summary("Sundar Pichai", "d/d4/Pichai.jpg"), summary("iPhone 17 Pro", "e/e5/iPhone.jpg"), summary("No Picture"),
    dict(summary("Big Tower", "f/f6/Big_Tower_logo.svg"), description="Landmark in Paris"),
    dict(summary("Acme", "a/a7/Acme_logo.svg"), description="American technology company"),
    dict(summary("Lost Media", "b/b8/Lost_wordmark.svg"), description="Landmark"))}
MEDIA = {"Big_Tower": {"items": [
    {"type": "image", "title": "File:Big_Tower_logo.svg", "showInGallery": True,
     "srcset": [{"src": "//thumb.wikimedia.org/wikipedia/en/thumb/f/f6/Big_Tower_logo.svg/250px-Big_Tower_logo.svg.png", "scale": "1x"}]},
    {"type": "image", "title": "File:Big_Tower_map.png", "showInGallery": True,
     "srcset": [{"src": "//upload.wikimedia.org/wikipedia/commons/1/11/Big_Tower_map.png", "scale": "1x"}]},
    {"type": "image", "title": "File:Big_Tower_photo.jpg", "leadImage": True, "showInGallery": True,
     "srcset": [{"src": "//thumb.wikimedia.org/wikipedia/commons/thumb/9/99/Big_Tower_photo.jpg/640px-Big_Tower_photo.jpg?utm_source=x",
                 "scale": "1x"},
                {"src": "//thumb.wikimedia.org/wikipedia/commons/thumb/9/99/Big_Tower_photo.jpg/1280px-Big_Tower_photo.jpg?utm_source=x",
                 "scale": "2x"}]}]}}


def wiki_lookup(title):
    """Wikipedia's own normalisation: underscores are spaces and the first letter is case-insensitive."""
    t = title.replace("_", " ").strip()
    return next((v for k, v in SUMMARIES.items() if k[:1].lower() + k[1:] == t[:1].lower() + t[1:]), None)


class Base(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        bridge.ENTITY_CACHE.clear()
        bridge.ENTITY_INFLIGHT.clear()
        self.previous = dict(bridge.CFG)
        bridge.CFG.update(link_preview=True)
        self.fetched = []

        async def fake_json(s, url):
            self.fetched.append(url)
            await asyncio.sleep(0.01)
            if "/page/summary/" in url:
                title = bridge.urllib.parse.unquote(url.rsplit("/", 1)[1])
                if wiki_lookup(title):
                    return wiki_lookup(title)
                raise bridge.LinkBlocked("fetch_failed")
            if "/search/page" in url:
                return {"pages": []}
            if "/page/media-list/" in url:
                key = bridge.urllib.parse.unquote(url.rsplit("/", 1)[1])
                if key in MEDIA:
                    return MEDIA[key]
                raise bridge.LinkBlocked("fetch_failed")
            raise AssertionError(url)

        self.warmed = []

        async def fake_warm(url, width=1280):
            self.warmed.append(url)

        self.patches = [mock.patch.object(bridge, "wiki_json", fake_json), mock.patch.object(bridge, "warm_image", fake_warm)]
        for p in self.patches:
            p.start()

    async def asyncTearDown(self):
        for p in self.patches:
            p.stop()
        bridge.CFG.clear()
        bridge.CFG.update(self.previous)


class SubjectTest(unittest.TestCase):
    def test_subjects(self):
        q = bridge.question_subject
        self.assertEqual(q("Tell me about the Eiffel Tower"), "Eiffel Tower")
        self.assertEqual(q("Who is Sundar Pichai"), "Sundar Pichai")
        self.assertEqual(q("What is a red panda?"), "red panda")
        for text in ("What is the weather today?", "Who are you?", "What is my name?", "Best cars under 10 lakh in India",
                     "Compare the iPhone 17 Pro and the Pixel 11 Pro", "What is 2+2?", "hi", "Plan my day", ""):
            self.assertIsNone(q(text), text)


class PicturesTest(Base):
    async def fill(self, text, question=""):
        pics = bridge.ReplyPictures(question)
        pics.scan(text)
        return await pics.finish(text)

    async def test_markdown_reference_becomes_a_linked_picture(self):
        out, shown = await self.fill("The tower is tall.\n\n![Eiffel Tower](entity:Eiffel_Tower)\n\nMore.")
        self.assertIn("[![Eiffel Tower](%sa/a1/Eiffel.jpg)](https://en.wikipedia.org/wiki/Eiffel_Tower)" % UP, out)
        self.assertEqual(shown, [UP + "a/a1/Eiffel.jpg"])
        self.assertNotIn("entity:", out)

    async def test_wrapped_reference_and_unknown_one(self):
        out, shown = await self.fill("A\n\n[![T](entity:Eiffel_Tower)](https://example.com/p)\n\n![X](entity:Nothing_Here)\n\nB")
        self.assertIn("[![T](%sa/a1/Eiffel.jpg)](https://en.wikipedia.org/wiki/Eiffel_Tower)" % UP, out)
        self.assertNotIn("example.com", out)
        self.assertNotIn("Nothing_Here", out)                  # dropped, and no triple blank line left behind
        self.assertNotIn("\n\n\n", out)

    async def test_html_img_is_filled_or_removed(self):
        html = '```hermes-html\n<div class="cards cols-2"><div><img src="entity:Tata_Nexon" alt="Tata Nexon"><h4>Nexon</h4></div>' \
               '<div><img alt="Gone" src=\'entity:No_Picture\'><h4>Gone</h4></div></div>\n```'
        out, shown = await self.fill(html)
        self.assertIn('<img src="%sb/b2/Nexon.jpg" alt="Tata Nexon">' % UP, out)
        self.assertNotIn("No_Picture", out)
        self.assertIn("<h4>Gone</h4>", out)
        self.assertEqual(shown, [UP + "b/b2/Nexon.jpg"])

    async def test_entities_block_items_get_pictures(self):
        block = {"v": 1, "type": "entities", "items": [
            {"name": "iPhone 17 Pro", "sub": "Apple phone", "wikipedia": "iPhone 17 Pro"},
            {"name": "Tata Nexon", "image": "entity:Tata_Nexon"},
            {"name": "Unknown Thing", "image": "not a url"},
            {"name": "Kept", "image": "https://example.com/k.jpg"}]}
        text = "Lead.\n\n```hermes-ui\n%s\n```\n" % json.dumps(block)
        out, shown = await self.fill(text)
        got = json.loads(out.split("```hermes-ui\n", 1)[1].split("\n```", 1)[0])
        items = got["items"]
        self.assertEqual(items[0]["image"], UP + "e/e5/iPhone.jpg")
        self.assertEqual(items[0]["page"], "https://en.wikipedia.org/wiki/iPhone_17_Pro")
        self.assertNotIn("wikipedia", items[0])
        self.assertEqual(items[1]["image"], UP + "b/b2/Nexon.jpg")
        self.assertNotIn("image", items[2])                       # the app looks it up itself
        self.assertEqual(items[3]["image"], "https://example.com/k.jpg")
        # The app's details sheet asks by name + sub: answered from the cache.
        self.assertEqual(bridge.ENTITY_CACHE[bridge._entity_key("iPhone 17 Pro", "Apple phone", "", "en")][1], 200)

    async def test_group_with_entities(self):
        block = {"v": 1, "type": "group", "children": [{"type": "entities", "items": [{"name": "Eiffel Tower"}]}]}
        out, _ = await self.fill("```hermes-ui\n%s\n```" % json.dumps(block))
        self.assertIn(UP + "a/a1/Eiffel.jpg", out)

    async def test_question_subject_gets_a_hero_picture(self):
        reply = "Sundar Pichai is the CEO of Alphabet and Google.\n\n- **Born:** 1972\n- **Role:** CEO"
        out, shown = await self.fill(reply, "Who is Sundar Pichai?")
        self.assertTrue(out.startswith("Sundar Pichai is the CEO of Alphabet and Google.\n\n[![Sundar Pichai](%sd/d4/Pichai.jpg)]"
                                       "(https://en.wikipedia.org/wiki/Sundar_Pichai)\n\n- **Born:**" % UP), out)
        # Not when the reply already has pictures, an entities block, or is not about the subject.
        for other in ("Sundar Pichai leads Google.\n\n![x](https://a.org/x.jpg)\n\nMore.",
                      "Sundar Pichai leads Google.\n\n```hermes-ui\n{\"v\":1,\"type\":\"entities\",\"items\":[{\"name\":\"Sundar Pichai\"}]}\n```",
                      "I can't help with that.\n\nSorry."):
            out2, _ = await self.fill(other, "Who is Sundar Pichai?")
            self.assertNotIn("[![Sundar Pichai]", out2, other)          # no hero picture added

    async def test_lowercase_subject_and_unchanged_text(self):
        out, _ = await self.fill("A red panda is a small mammal.\n\nIt lives in the Himalayas.", "What is a red panda?")
        self.assertIn("[![Red panda](%sc/c3/Panda.jpg)]" % UP, out)
        plain = "Hello there."
        out, shown = await self.fill(plain, "hi")
        self.assertEqual((out, shown), (plain, []))

    async def test_slow_lookup_is_dropped_not_waited_on(self):
        async def slow(s, url):
            await asyncio.sleep(5)
        with mock.patch.object(bridge, "wiki_json", slow), mock.patch.object(bridge, "ENTITY_WAIT_S", 0.2):
            t = time.monotonic()
            out, shown = await self.fill("A\n\n![E](entity:Eiffel_Tower)\n\nB")
            self.assertLess(time.monotonic() - t, 1.0)
        self.assertEqual((out, shown), ("A\n\nB", []))

    async def test_link_preview_off_changes_nothing(self):
        bridge.CFG["link_preview"] = False
        text = "A\n\n![E](entity:Eiffel_Tower)"
        pics = bridge.ReplyPictures("Who is Sundar Pichai?")
        pics.scan(text)
        self.assertEqual(pics.tasks, {})


class LeadPhotoTest(Base):
    async def test_a_landmark_logo_becomes_its_lead_photo(self):
        status, body = await bridge.entity_info_cached("Big Tower")
        photo = "https://thumb.wikimedia.org/wikipedia/commons/thumb/9/99/Big_Tower_photo.jpg/1280px-Big_Tower_photo.jpg"
        self.assertEqual((status, body["image"], body["original_image"]), (200, photo, photo))

    async def test_a_company_keeps_its_logo_and_a_failed_media_list_keeps_the_summary_picture(self):
        status, body = await bridge.entity_info_cached("Acme")
        self.assertTrue(body["original_image"].endswith("Acme_logo.svg"))
        self.assertFalse(any("media-list" in u for u in self.fetched))
        status, body = await bridge.entity_info_cached("Lost Media")
        self.assertEqual(status, 200)
        self.assertTrue(body["original_image"].endswith("Lost_wordmark.svg"))
        self.assertTrue(any("media-list" in u for u in self.fetched))

    def test_not_a_photo(self):
        self.assertTrue(bridge.not_a_photo(UP + "x/Thing_logo.svg"))
        self.assertTrue(bridge.not_a_photo(UP + "x/Coat_of_arms.png"))
        self.assertFalse(bridge.not_a_photo(UP + "x/Tour_Eiffel.jpg"))
        self.assertFalse(bridge.not_a_photo(None))


class FakeHermes:
    def __init__(self, pieces):
        self.pieces, self.bodies = pieces, []

    async def handle(self, req):
        body = await req.json()
        self.bodies.append(body)
        if not body.get("stream"):
            return web.json_response({"choices": [{"message": {"content": "Eiffel Tower Facts"}}]})
        resp = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
        await resp.prepare(req)
        for p in self.pieces:
            await resp.write(("data: " + json.dumps({"choices": [{"index": 0, "delta": {"content": p}}]}) + "\n\n").encode())
            await asyncio.sleep(0.01)
        await resp.write(("data: " + json.dumps({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}) + "\n\n").encode())
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


class ChatPicturesTest(Base):
    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.temp = tempfile.TemporaryDirectory()
        self.fake = FakeHermes(["The Eiffel Tower is in Paris.", "\n\n![Eiffel Tower](entity:Eiffel_Tower)", "\n\nIt is 330 m tall."])
        app = web.Application()
        app.router.add_post("/v1/chat/completions", self.fake.handle)
        self.hermes = TestServer(app)
        await self.hermes.start_server()
        bridge.CFG.update(live_key=KEY, hermes_key="h", chat_db=os.path.join(self.temp.name, "chats.sqlite"), titles="simple",
                          hermes_url=str(self.hermes.make_url("/v1")), web_search="false", data_dir=self.temp.name,
                          ui_prompt_file="off", upload_dir=os.path.join(self.temp.name, "uploads"), hermes_upload_dir="")
        self.client = TestClient(TestServer(bridge.make_app()))
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        await self.hermes.close()
        bridge.CHAT["active"] = 0
        await super().asyncTearDown()
        self.temp.cleanup()

    async def test_snapshot_with_pictures_before_done_and_stored(self):
        r = await self.client.post("/api/chat", json={"message": {"text": "Tell me about the Eiffel Tower"}, "ui": 1}, headers=AUTH)
        events = await read_sse(r)
        kinds = [e for e, _ in events]
        self.assertEqual(kinds[-2:], ["snapshot", "done"])
        snap = events[-2][1]
        self.assertIn("[![Eiffel Tower](%sa/a1/Eiffel.jpg)](https://en.wikipedia.org/wiki/Eiffel_Tower)" % UP, snap["text"])
        self.assertTrue(snap["text"].startswith("The Eiffel Tower is in Paris."))
        # The deltas themselves streamed untouched.
        self.assertIn("entity:Eiffel_Tower", "".join(d["text"] for e, d in events if e == "delta"))
        mid = events[-1][1]["message_id"]
        msg = bridge.CHAT["store"].db.execute("SELECT text, meta_json FROM messages WHERE id = ?", (mid,)).fetchone()
        self.assertEqual(msg[0], snap["text"])
        self.assertEqual(json.loads(msg[1])["pictures"]["count"], 1)
        await asyncio.sleep(0.05)
        self.assertEqual(self.warmed, [UP + "a/a1/Eiffel.jpg"])

    async def test_reply_without_references_has_no_snapshot(self):
        self.fake.pieces = ["Hello", " there."]
        r = await self.client.post("/api/chat", json={"message": {"text": "hi"}}, headers=AUTH)
        kinds = [e for e, _ in await read_sse(r)]
        self.assertNotIn("snapshot", kinds)
        self.assertEqual(kinds[-1], "done")


class TitleTierTest(unittest.IsolatedAsyncioTestCase):
    async def test_title_call_asks_for_priority_and_can_be_off(self):
        self.assertEqual(bridge.load_config({})["title_service_tier"], "priority")
        self.assertEqual(bridge.load_config({"TITLE_SERVICE_TIER": "off"})["title_service_tier"], "")
        seen = []

        async def handle(req):
            seen.append(await req.json())
            return web.json_response({"choices": [{"message": {"content": "Paris Tower Facts"}}]})
        app = web.Application()
        app.router.add_post("/v1/chat/completions", handle)
        server = TestServer(app)
        await server.start_server()
        previous = dict(bridge.CFG)
        try:
            bridge.CFG.update(title_api_url=str(server.make_url("/v1")), title_api_key="t", title_service_tier="priority")
            await bridge.model_title("c1", "Tell me about Paris")
            bridge.CFG["title_service_tier"] = ""
            await bridge.model_title("c1", "Tell me about Paris")
        finally:
            bridge.CFG.clear()
            bridge.CFG.update(previous)
            await server.close()
        self.assertEqual(seen[0]["service_tier"], "priority")
        self.assertNotIn("service_tier", seen[1])


if __name__ == "__main__":
    unittest.main()
