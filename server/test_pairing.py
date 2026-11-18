"""POST /api/pair and tove_pair.py: one-time codes that the app trades for the access key (API.md "Pairing").

Against the same fakes as test_chat_api. Run with the bridge venv:
  venv/bin/python -m unittest test_pairing
"""
import io, json, os, stat, struct, time, unittest, zlib
from contextlib import redirect_stdout
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import test_chat_api as base
import tove_pair

bridge = base.bridge


class PairCodesTest(unittest.TestCase):
    """tove_pair.py on its own: codes, the file, the link and the QR output."""

    def setUp(self):
        import tempfile
        self.temp = tempfile.TemporaryDirectory()
        self.dir = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_codes_are_unambiguous_and_normalized(self):
        codes = {tove_pair.new_code() for _ in range(200)}
        self.assertEqual(len(codes), 200)
        for c in codes:
            self.assertEqual(len(c), 10)
            self.assertFalse(set(c) & set("01IO"))
        self.assertEqual(tove_pair.normalize(" abcde-fghjk "), "ABCDEFGHJK")
        self.assertEqual(tove_pair.pretty("abcdefghjk"), "ABCDE-FGHJK")
        self.assertEqual(tove_pair.code_hash("abcde fghjk"), tove_pair.code_hash("ABCDE-FGHJK"))
        # The bridge hashes exactly like the script: the file is the only thing they share.
        self.assertEqual(bridge.pair_hash("abcde-fghjk")[1], tove_pair.code_hash("ABCDEFGHJK"))

    def test_file_holds_hashes_only_with_mode_600(self):
        made = tove_pair.create(self.dir, now=1000)
        path = self.dir / "pairing.json"
        text = path.read_text()
        self.assertNotIn(made["code"], text)
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        entry = json.loads(text)["codes"][0]
        self.assertEqual((entry["expires_at"], entry["used_at"]), (1600, None))
        for _ in range(12):
            tove_pair.create(self.dir, now=1000)
        self.assertEqual(len(tove_pair.read_entries(path)), tove_pair.KEEP)
        tove_pair.create(self.dir, now=1000 + 2 * 86400)                    # day-old entries are dropped
        self.assertEqual(len(tove_pair.read_entries(path)), 1)

    def test_link_carries_url_and_code_but_never_a_key(self):
        link = tove_pair.pair_link("https://box.tail1234.ts.net:8787", "abcdefghjk", "Home server")
        u = urlparse(link)
        q = parse_qs(u.query)
        self.assertEqual((u.scheme, u.netloc), ("tove", "pair"))
        self.assertEqual(q, {"u": ["https://box.tail1234.ts.net:8787"], "c": ["ABCDE-FGHJK"], "n": ["Home server"]})

    def test_cli_json_png_and_terminal(self):
        out = io.StringIO()
        with redirect_stdout(out):
            tove_pair.main(["--url", "https://tove.example.com/", "--data-dir", str(self.dir), "--json",
                            "--png", str(self.dir / "qr.png")])
        r = json.loads(out.getvalue())
        self.assertEqual(r["url"], "https://tove.example.com")
        self.assertTrue(r["link"].startswith("tove://pair?u=https%3A%2F%2Ftove.example.com&c="))
        self.assertEqual(tove_pair.code_hash(r["code"]), tove_pair.read_entries(self.dir / "pairing.json")[0]["sha256"])
        if r["qr"]:                                   # segno or qrcode installed (segno is in requirements.txt)
            png = Path(r["png"]).read_bytes()
            self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n"))
            w, h = struct.unpack(">II", png[16:24])
            self.assertEqual(w, h)
            self.assertIn("█", r["terminal_qr"])
        with self.assertRaises(SystemExit):
            with redirect_stdout(io.StringIO()), unittest.mock.patch("sys.stderr", io.StringIO()):
                tove_pair.main(["--url", "tove.example.com", "--data-dir", str(self.dir)])

    def test_png_writer_without_libraries(self):
        matrix = [[(x + y) % 2 == 0 for x in range(5)] for y in range(5)]
        tove_pair.qr_png(matrix, self.dir / "m.png", scale=2)
        png = (self.dir / "m.png").read_bytes()
        self.assertEqual(struct.unpack(">II", png[16:24]), (10, 10))
        idat = png[png.index(b"IDAT") + 4:png.index(b"IEND") - 8]
        raw = zlib.decompress(idat)
        self.assertEqual(len(raw), 10 * (1 + 10))
        self.assertEqual(raw[1:3], b"\x00\x00")       # top-left module is dark
        self.assertEqual(tove_pair.qr_terminal([[True, False], [False, True]]), "▄▀")


class PairEndpointTest(unittest.IsolatedAsyncioTestCase):
    asyncSetUp = base.ChatApiTest.asyncSetUp
    asyncTearDown = base.ChatApiTest.asyncTearDown

    def setUp(self):
        bridge.PAIR_FAILS.clear()

    def tearDown(self):
        bridge.PAIR_FAILS.clear()

    def code(self, **kw):
        bridge.CFG["pair_file"] = os.path.join(self.temp.name, "pairing.json")
        return tove_pair.create(Path(self.temp.name), **kw)["code"]

    async def pair(self, code, headers=None):
        r = await self.client.post("/api/pair", json={"code": code}, headers=headers or {})
        return r.status, await r.json()

    async def test_code_gives_the_key_once(self):
        bridge.CFG["assistant_name"] = "Tove"
        code = self.code()
        status, body = await self.pair(tove_pair.pretty(code).lower())          # typed in lower case with the dash
        self.assertEqual((status, body["key"], body["name"]), (200, base.KEY, "Tove"))
        self.assertEqual(body["version"], bridge.API_VERSION)
        status, body = await self.pair(code)
        self.assertEqual((status, body["code"]), (410, "code_expired"))
        # The key it returned works, and capabilities advertise pairing.
        r = await self.client.get("/api/capabilities", headers={"Authorization": "Bearer " + base.KEY})
        self.assertTrue((await r.json())["pairing"])
        used = tove_pair.read_entries(Path(self.temp.name) / "pairing.json")[0]["used_at"]
        self.assertIsInstance(used, int)

    async def test_expired_wrong_and_malformed(self):
        old = self.code(now=time.time() - 601)
        self.assertEqual((await self.pair(old))[1]["code"], "code_expired")
        self.assertEqual((await self.pair("ZZZZZ-ZZZZZ"))[0], 401)
        for bad in ("", "abc", "x" * 40):
            self.assertEqual((await self.pair(bad))[0], 400)
        r = await self.client.post("/api/pair", data="not json")
        self.assertEqual(r.status, 400)
        r = await self.client.post("/api/pair", json={"code": 12345678})
        self.assertEqual(r.status, 400)

    async def test_no_file_and_no_key(self):
        bridge.CFG["pair_file"] = os.path.join(self.temp.name, "missing", "pairing.json")
        self.assertEqual((await self.pair("ABCDE-FGHJK"))[1]["code"], "invalid_code")
        bridge.CFG["live_key"] = ""
        self.assertEqual((await self.pair("ABCDE-FGHJK"))[1]["code"], "pairing_off")

    async def test_wrong_codes_are_rate_limited(self):
        good = self.code()
        for _ in range(bridge.PAIR_MAX_FAILS_CLIENT):
            self.assertEqual((await self.pair("WRONG-CODE2"))[0], 401)
        status, body = await self.pair(good)                                   # even the right code waits
        self.assertEqual((status, body["code"]), (429, "too_many_attempts"))
        self.assertGreater(body["retry_after_s"], 0)
        # The window passes: the right code works again (it has not been used).
        bridge.PAIR_FAILS.clear()
        bridge.PAIR_FAILS.extend((time.monotonic() - bridge.PAIR_WINDOW_S - 1, "x") for _ in range(50))
        self.assertEqual((await self.pair(good))[0], 200)

    async def test_global_limit_counts_every_client(self):
        self.code()
        now = time.monotonic()
        bridge.PAIR_FAILS.extend((now, "10.0.0.%d" % i) for i in range(bridge.PAIR_MAX_FAILS))
        self.assertEqual((await self.pair("ABCDE-FGHJK"))[0], 429)


import unittest.mock  # noqa: E402  (used above inside a test)

if __name__ == "__main__":
    unittest.main()
