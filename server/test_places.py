"""Places (open data: an Overture extract, Photon geocoding, OSM details through Overpass) and the approximate location
on chat turns.

The extract is built from fixtures/places-open.json with places_fetch.write_db; Overpass and Photon are fakes on
loopback answering with the recorded shapes. No network, no keys. Run with the bridge venv:
  python -m unittest test_places
"""
import asyncio
import datetime
import time
import importlib.util
import json
import os
import unittest
import unittest.mock
from pathlib import Path

from aiohttp import web
from aiohttp.test_utils import TestServer

import test_chat_api as base

bridge = base.bridge
AUTH = base.AUTH
TOOLS_KEY = "tools-fixture-key-0123456789abcdef"
TAUTH = {"Authorization": "Bearer " + TOOLS_KEY}
HERE = Path(__file__).resolve().parent
FIXTURE = json.loads((HERE / "fixtures" / "places-open.json").read_text())
_spec = importlib.util.spec_from_file_location("places_fetch", HERE / "places_fetch.py")
places_fetch = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(places_fetch)
NEAR = "13.03,80.27"
CLINIC = "place:11111111-aaaa-4bbb-8ccc-000000000001"


class FakeOsm:
    def __init__(self):
        self.overpass, self.photon = [], []

    async def interpreter(self, req):
        form = await req.post()
        self.overpass.append((form.get("data"), req.headers.get("User-Agent")))
        return web.json_response(FIXTURE["overpass"])

    async def api(self, req):
        self.photon.append(dict(req.query))
        if req.query.get("q") == "Nowhere at all":
            return web.json_response({"type": "FeatureCollection", "features": []})
        return web.json_response(FIXTURE["photon"])


class PlacesTest(unittest.IsolatedAsyncioTestCase):
    wait_for = base.ChatApiTest.wait_for
    chat = base.ChatApiTest.chat

    async def asyncSetUp(self):
        await base.ChatApiTest.asyncSetUp(self)
        self.osm = FakeOsm()
        app = web.Application()
        app.router.add_post("/api/interpreter", self.osm.interpreter)
        app.router.add_get("/api/", self.osm.api)
        self.server = TestServer(app)
        await self.server.start_server()
        self.db = os.path.join(self.temp.name, "places.sqlite")
        places_fetch.write_db(iter(FIXTURE["overture"]), self.db, {"release": "2026-11-18.0", "bbox": [80, 12.5, 80.5, 13.5]})
        bridge.CFG.update(places_db=self.db, tools_key=TOOLS_KEY, data_dir=self.temp.name, geocoder_url="off",
                          places_geocoder_url=str(self.server.make_url("/api/")),
                          overpass_url=str(self.server.make_url("/api/interpreter")), overpass_daily=500, places_cache_h=24)
        for k in ("search", "osm", "geo"):
            bridge.PLACES[k].clear()
        bridge.PLACES_THROTTLE.clear()
        bridge.OSM_STATE["down_until"] = 0.0
        bridge.GEO_CACHE.clear()

    async def asyncTearDown(self):
        await self.server.close()
        await base.ChatApiTest.asyncTearDown(self)

    async def search(self, body, headers=TAUTH):
        r = await self.client.post("/api/places/search", json=body, headers=headers)
        return r.status, await r.json()

    async def test_search_ranks_nearby_matches_and_enriches_from_osm(self):
        status, out = await self.search({"query": "psychiatrist near me", "near": NEAR, "max": 3})
        self.assertEqual(status, 200)
        ids = [p["id"] for p in out["places"]]
        self.assertEqual(ids[:2], [CLINIC, "place:11111111-aaaa-4bbb-8ccc-000000000002"])
        self.assertNotIn("place:11111111-aaaa-4bbb-8ccc-000000000004", ids)          # 25 km away
        self.assertNotIn("place:11111111-aaaa-4bbb-8ccc-000000000005", ids)          # a restaurant
        first = out["places"][0]
        self.assertEqual({k: first[k] for k in ("name", "category", "subtitle", "phone", "website", "hours", "wheelchair",
                                                 "photo", "sources")},
                         {"name": "Sample Mind Clinic", "category": "Psychiatry", "subtitle": "Psychiatry · 12 Example Street",
                          "phone": "+910000000001", "website": "https://clinic.example/adhd",
                          "hours": "Mo-Sa 09:00-20:00; Su off", "wheelchair": "yes",
                          "photo": "https://images.example/clinic.jpg", "sources": "Overture Maps + OpenStreetMap"})
        self.assertLess(first["distance_km"], 1)
        self.assertNotIn("rating", first)                                            # no open ratings: never invented
        self.assertNotIn("hours", out["places"][1])                                  # its OSM namesake is 8 km away
        self.assertIn("Overture", out["attribution"])
        query, ua = self.osm.overpass[0]
        self.assertIn('nwr(around:150,13.033900,80.268600)["name"~"sample mind",i];', query)
        self.assertTrue(ua.startswith("ToveBridge/"))
        # Cached: the same search makes no new Overpass request.
        status, again = await self.search({"query": "psychiatrist near me", "near": NEAR, "max": 3})
        self.assertEqual((status, again["cached"], len(self.osm.overpass)), (200, True, 1))
        # Another search with the same places reuses their OSM details.
        await self.search({"query": "psychiatrist", "near": NEAR, "max": 2})
        self.assertEqual(len(self.osm.overpass), 1)

    async def test_synonyms_and_wikimedia_photo(self):
        status, out = await self.search({"query": "dentist open now", "near": NEAR, "max": 2})
        self.assertEqual(status, 200)
        dental = out["places"][0]
        self.assertEqual(dental["name"], "Placeholder Dental Care")
        self.assertEqual((dental["hours"], dental["open_now"]), ("24/7", True))
        self.assertEqual(dental["photo"], "https://commons.wikimedia.org/wiki/Special:FilePath/Sample_dental_building.jpg")

    async def test_area_names_are_geocoded_and_cached(self):
        status, out = await self.search({"query": "biryani", "near": "Mylapore, Chennai"})
        self.assertEqual((status, out["located"], out["places"][0]["name"]), (200, True, "Demo Biryani House"))
        self.assertEqual(self.osm.photon[0], {"q": "Mylapore, Chennai", "limit": "1"})
        await self.search({"query": "biryani restaurant", "near": "mylapore, chennai"})
        self.assertEqual(len(self.osm.photon), 1)
        status, out = await self.search({"query": "biryani", "near": "Nowhere at all"})
        self.assertEqual((status, out["located"]), (200, False))
        self.assertIn("could not find", out["warning"])

    async def test_auth_validation_and_unavailable(self):
        self.assertEqual((await self.search({"query": "x"}, headers={}))[0], 401)
        self.assertEqual((await self.search({"query": "clinic"}, headers=AUTH))[0], 200)   # the app's key works too
        self.assertEqual((await self.search({"query": ""}))[1]["code"], "bad_request")
        self.assertEqual((await self.search({"query": "the near me"}))[1]["code"], "bad_request")   # only stop words
        self.assertEqual((await self.search({"query": "x", "max": "lots"}))[0], 400)
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertEqual((caps["places"]["search"], caps["places"]["count"], caps["location"]), (True, 5, True))
        self.assertEqual(caps["places"]["map_tiles"], bridge.CFG["map_tiles"])
        bridge.CFG["places_db"] = os.path.join(self.temp.name, "missing.sqlite")
        status, out = await self.search({"query": "dentist"})
        self.assertEqual((status, out["code"]), (503, "unavailable"))

    async def test_overpass_off_and_daily_cap(self):
        bridge.CFG["overpass_daily"] = 0
        status, out = await self.search({"query": "psychiatrist", "near": NEAR})
        self.assertEqual(status, 200)
        self.assertEqual((self.osm.overpass, out["places"][0]["sources"]), ([], "Overture Maps"))
        bridge.CFG.update(overpass_daily=5, overpass_url="off")
        bridge.PLACES["search"].clear()
        await self.search({"query": "psychiatrist", "near": NEAR})
        self.assertEqual(self.osm.overpass, [])

    async def test_info_for_the_app(self):
        await self.search({"query": "psychiatrist", "near": NEAR})
        r = await self.client.get("/api/places/info", params={"id": CLINIC}, headers=AUTH)
        body = await r.json()
        self.assertEqual((r.status, body["name"], body["hours"], body["lat"]), (200, "Sample Mind Clinic", "Mo-Sa 09:00-20:00; Su off", 13.0339))
        self.assertEqual((await self.client.get("/api/places/info", params={"id": CLINIC})).status, 401)
        self.assertEqual((await self.client.get("/api/places/info", params={"id": CLINIC}, headers=TAUTH)).status, 401)
        r = await self.client.get("/api/places/info", params={"id": "place:11111111-aaaa-4bbb-8ccc-00000000ffff"}, headers=AUTH)
        self.assertEqual(r.status, 404)
        for bad in ("11111111-aaaa-4bbb-8ccc-000000000001", "place:../../etc", "place:a b"):
            r = await self.client.get("/api/places/info", params={"id": bad}, headers=AUTH)
            self.assertEqual(r.status, 400, bad)

    async def test_slow_overpass_does_not_hold_the_answer(self):
        release = asyncio.Event()
        orig = self.osm.interpreter

        async def slow(req):
            await release.wait()
            return await orig(req)
        app = web.Application()
        app.router.add_post("/api/interpreter", slow)
        server = TestServer(app)
        await server.start_server()
        try:
            bridge.CFG["overpass_url"] = str(server.make_url("/api/interpreter"))
            with unittest.mock.patch.object(bridge, "OSM_WAIT_S", 0.2):
                t0 = time.monotonic()
                status, out = await self.search({"query": "psychiatrist", "near": NEAR, "max": 2})
            self.assertEqual(status, 200)
            self.assertLess(time.monotonic() - t0, 2)
            self.assertNotIn("hours", out["places"][0])
            release.set()                                           # the request finishes in the background
            self.assertTrue(await self.wait_for(lambda: bridge.PLACES["osm"].get(CLINIC[6:]) is not None))
            r = await self.client.get("/api/places/info", params={"id": CLINIC}, headers=AUTH)
            self.assertEqual((await r.json())["hours"], "Mo-Sa 09:00-20:00; Su off")
        finally:
            release.set()
            await server.close()

    async def test_failed_overpass_backs_off(self):
        bridge.CFG["overpass_url"] = "http://127.0.0.1:9/api/interpreter"      # nothing listens there
        await self.search({"query": "psychiatrist", "near": NEAR, "max": 2})
        self.assertGreater(bridge.OSM_STATE["down_until"], time.monotonic())

    def test_opening_hours_parser(self):
        tue_10 = datetime.datetime(2026, 11, 17, 10, 0)          # a Tuesday
        sun_10 = datetime.datetime(2026, 11, 22, 10, 0)
        late = datetime.datetime(2026, 11, 17, 23, 30)
        oh = bridge.opening_hours_open
        self.assertIs(oh("24/7", tue_10), True)
        self.assertIs(oh("Mo-Sa 09:00-20:00; Su off", tue_10), True)
        self.assertIs(oh("Mo-Sa 09:00-20:00; Su off", sun_10), False)
        self.assertIs(oh("Mo-Fr 09:00-13:00,16:00-21:00", late), False)
        self.assertIs(oh("Mo-Su 18:00-02:00", late), True)                  # past midnight
        self.assertIs(oh("Sa-Mo 10:00-12:00", sun_10), True)                # wraps the week
        self.assertIsNone(oh("Mo-Fr 09:00-18:00; PH off", tue_10))
        self.assertIsNone(oh("sunrise-sunset", tue_10))

    # ---- approximate location on chat turns
    async def test_location_note_reaches_hermes_and_stays_stable(self):
        loc = {"lat": 13.033912, "lng": 80.268601, "label": "Mylapore, Chennai, IN"}
        response, events = await self.chat(message={"text": "dentist near me"}, location=loc)
        self.assertEqual(response.status, 200)
        sent = self.fake.requests[-1]["body"]["messages"]
        user = [m for m in sent if m["role"] == "user"][-1]["content"]
        self.assertIn("User's approximate location, shared by the app for this message: Mylapore, Chennai, IN; about 13.03, 80.27.", user)
        self.assertNotIn("13.0339", user)
        cid = events[0][1]["conversation_id"]
        msgs = await (await self.client.get("/api/conversations/%s/messages" % cid, headers=AUTH)).json()
        self.assertNotIn("Mylapore", json.dumps(msgs))                       # never in the API or history views
        await self.chat(conversation_id=cid, message={"text": "thanks"})
        sent2 = self.fake.requests[-1]["body"]["messages"]
        self.assertEqual([m for m in sent2 if m["role"] == "user"][0]["content"], user)   # Hermes' session stays stable
        self.assertNotIn("approximate location", [m for m in sent2 if m["role"] == "user"][-1]["content"])

    async def test_location_validation_and_reverse_geocode(self):
        response, body = await self.chat(message={"text": "hi"}, location="Chennai")
        self.assertEqual((response.status, body["code"]), (400, "bad_request"))
        self.assertIsNone(bridge.coarse_location({"lat": 91, "lng": 0}))
        self.assertIsNone(bridge.coarse_location({"lat": True, "lng": 0}))
        self.assertEqual(bridge.coarse_location({"label": "Old <b>Town</b> [x]"}), (None, None, "Old bTown/b x"))
        geo = web.Application()
        seen = []

        async def reverse(req):
            seen.append((dict(req.query), req.headers.get("User-Agent")))
            return web.json_response({"address": {"suburb": "Sampleville", "city": "Example City", "country_code": "in"}})
        geo.router.add_get("/reverse", reverse)
        server = TestServer(geo)
        await server.start_server()
        try:
            bridge.CFG["geocoder_url"] = str(server.make_url("/reverse"))
            note = await bridge.location_note({"lat": 12.98765, "lng": 80.123})
            self.assertIn("Sampleville, Example City, IN; about 12.99, 80.12", note)
            self.assertEqual((seen[0][0]["lat"], seen[0][0]["lon"], seen[0][0]["zoom"]), ("12.99", "80.12", "14"))
            self.assertTrue(seen[0][1].startswith("ToveBridge/"))
            await bridge.location_note({"lat": 12.9871, "lng": 80.1201})          # same 1 km cell: cached
            self.assertEqual(len(seen), 1)
        finally:
            await server.close()
        self.assertEqual(await bridge.location_note(None), "")


class FetchTest(unittest.TestCase):
    def test_write_db_and_words(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "p.sqlite")
            meta = places_fetch.write_db(iter(FIXTURE["overture"]), out, {"release": "r", "bbox": [0, 0, 1, 1]})
            self.assertEqual(meta["count"], 5)
            self.assertIn("Foursquare", meta["attribution"])
            self.assertEqual(oct(os.stat(out).st_mode & 0o777), "0o600")
        self.assertEqual(places_fetch.words("dental_clinic", ["health_care", "dental_clinic"]), "dental clinic health care")
        self.assertEqual(places_fetch.parse_bbox("79.9,12.7,80.3,13.2"), (79.9, 12.7, 80.3, 13.2))
        with self.assertRaises(SystemExit):
            places_fetch.parse_bbox("80,13,79,12")


class PluginTest(unittest.TestCase):
    """The hermes-places plugin against a stub of the bridge call."""

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("places_plugin", HERE / "hermes-places" / "__init__.py")
        cls.plugin = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.plugin)

    def test_not_configured(self):
        with unittest.mock.patch.dict(os.environ, {"TOVE_BRIDGE_URL": "", "TOVE_TOOLS_KEY": ""}):
            self.assertFalse(self.plugin.check_places_search())
            out = json.loads(self.plugin.handle_places_search({"query": "dentist"}))
            self.assertFalse(out["success"])
            self.assertIn("web_search", out["note"])

    def test_passes_arguments_and_adds_note(self):
        got = {}

        def fake(base_url, key, body, timeout=20):
            got.update(base=base_url, key=key, body=body)
            return {"places": [{"id": CLINIC, "name": "Sample Mind Clinic"}]}
        with unittest.mock.patch.dict(os.environ, {"TOVE_BRIDGE_URL": "http://bridge.example:8787/", "TOVE_TOOLS_KEY": "k" * 30}), \
                unittest.mock.patch.object(self.plugin, "call_bridge", fake):
            self.assertTrue(self.plugin.check_places_search())
            out = json.loads(self.plugin.handle_places_search({"query": "psychiatrist", "near": NEAR, "max": 3}))
        self.assertEqual(got["base"], "http://bridge.example:8787")
        self.assertEqual(got["body"], {"query": "psychiatrist", "near": NEAR, "max": 3})
        self.assertTrue(out["success"])
        self.assertIn("Places(", out["note"])
        self.assertIn("rating", out["note"])
        self.assertEqual(self.plugin.SCHEMA["name"], "places_search")
        self.assertNotIn("open_now", self.plugin.SCHEMA["parameters"]["properties"])


if __name__ == "__main__":
    unittest.main()
