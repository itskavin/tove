"""Direct-image link previews (markdown images in replies) and their failure boundaries, against a fake website on
loopback. Loopback is only reachable because the tests allow 127.0.0.1 explicitly; everything else private stays
refused. Run from this folder with the venv:
  ~/.local/share/gpt-live-bridge/venv/bin/python -m unittest test_link_images
"""
import base64
import importlib.util
import struct
import time
import unittest
import zlib
from pathlib import Path
from unittest import mock

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

SPEC = importlib.util.spec_from_file_location("bridge_img", Path(__file__).with_name("gpt-live-bridge.py"))
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)

REAL_PUBLIC_IP = bridge.public_ip


def png(w=64, h=48):
    raw = b"".join(b"\x00" + b"\xc8\x1e\x1e" * w for _ in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def jpeg(w=640, h=427):
    app0 = b"\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    sof0 = b"\xff\xc0" + struct.pack(">HBHHB", 17, 8, h, w, 3) + b"\x01\x22\x00\x02\x11\x01\x03\x11\x01"
    return b"\xff\xd8" + app0 + b"\xff\xff" + sof0 + b"\xff\xd9"   # \xff\xff: a fill byte before the marker


def gif(w=320, h=200):
    return b"GIF89a" + struct.pack("<HH", w, h) + b"\x00\x00\x00;"


def webp(kind, w, h):
    if kind == b"VP8X":
        payload = b"\x00\x00\x00\x00" + (w - 1).to_bytes(3, "little") + (h - 1).to_bytes(3, "little")
    elif kind == b"VP8L":
        payload = b"\x2f" + ((w - 1) | ((h - 1) << 14)).to_bytes(4, "little")
    else:
        payload = b"\x00\x00\x00\x9d\x01\x2a" + struct.pack("<HH", w, h)
    body = b"WEBP" + kind + struct.pack("<I", len(payload)) + payload
    return b"RIFF" + struct.pack("<I", len(body)) + body


class Site:
    """A fake public website. Paths decide what it answers."""

    def __init__(self):
        self.hits = []

    async def handle(self, req):
        path = req.path
        self.hits.append((path, req.headers.get("Accept", "")))
        if path == "/photo.png":
            return web.Response(body=png(), content_type="image/png")
        if path == "/photo.jpg":
            return web.Response(body=jpeg(), headers={"Content-Type": "image/jpeg; charset=binary"})
        if path == "/anim.gif":
            return web.Response(body=gif(), content_type="image/gif")
        if path == "/pic.webp":
            return web.Response(body=webp(b"VP8X", 1200, 800), content_type="image/webp")
        if path == "/vector.svg":
            return web.Response(text="<svg xmlns='http://www.w3.org/2000/svg' onload='alert(1)'/>", content_type="image/svg+xml")
        if path == "/fake.png":                                   # declared PNG, actually HTML
            return web.Response(body=b"<html><script>alert(1)</script></html>", content_type="image/png")
        if path == "/photo.avif":
            return web.Response(body=b"\x00\x00\x00\x1cftypavif" + b"\x00" * 64, content_type="image/avif")
        if path == "/chunked.png":                                # no Content-Length, body larger than the cap
            resp = web.StreamResponse(headers={"Content-Type": "image/png"})
            resp.enable_chunked_encoding()
            await resp.prepare(req)
            await resp.write(png())
            await resp.write(b"\x00" * 4096)
            await resp.write_eof()
            return resp
        if path == "/moved.jpg":
            raise web.HTTPFound("/photo.jpg")
        if path == "/to-private.png":
            raise web.HTTPFound("http://10.0.0.7/photo.png")
        if path == "/to-localhost.png":
            raise web.HTTPFound("http://localhost/photo.png")
        if path == "/article":
            return web.Response(text='<html><head><title>Article</title><meta property="og:image" content="/photo.jpg">'
                                     '<link rel="icon" href="/anim.gif"></head></html>', content_type="text/html")
        if path == "/gone.png":
            return web.Response(status=404)
        if path == "/busy.png":                                   # 429 once, then the picture (Wikimedia under a burst)
            self.busy = getattr(self, "busy", 0) + 1
            if self.busy == 1:
                return web.Response(status=429, headers={"Retry-After": "0"})
            return web.Response(body=png(), content_type="image/png")
        if req.raw_path == "/a%2Cb.png":                          # the path must arrive exactly as written
            return web.Response(body=png(8, 8), content_type="image/png")
        return web.Response(status=404)


class LinkImageTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.site = Site()
        app = web.Application()
        app.router.add_get("/{tail:.*}", self.site.handle)
        self.server = TestServer(app, host="127.0.0.1")
        await self.server.start_server()
        self.base = "http://127.0.0.1:%d" % self.server.port
        # Only this fake site's loopback address counts as public; every other private address is still refused.
        self.patches = [mock.patch.object(bridge, "public_ip", lambda a: a == "127.0.0.1" or REAL_PUBLIC_IP(a)),
                        mock.patch.object(bridge, "LINK_PORTS", bridge.LINK_PORTS | {self.server.port})]
        for p in self.patches:
            p.start()
        self.previous = dict(bridge.CFG)
        bridge.CFG.update(live_key="fixture-key-for-link-image-tests", link_preview=True)
        bridge.LINK_CACHE.clear()

    async def asyncTearDown(self):
        for p in self.patches:
            p.stop()
        await self.server.close()
        bridge.CFG.clear()
        bridge.CFG.update(self.previous)
        bridge.LINK_CACHE.clear()

    async def preview(self, path):
        return await bridge.build_link_preview(self.base + path)

    def decoded(self, data_url, ctype):
        prefix = "data:%s;base64," % ctype
        self.assertTrue(data_url.startswith(prefix))
        return base64.b64decode(data_url[len(prefix):])

    async def test_direct_png_returns_the_image_and_its_size(self):
        r = await self.preview("/photo.png")
        self.assertEqual((r["kind"], r["width"], r["height"], r["title"], r["favicon"]), ("image", 64, 48, None, None))
        self.assertEqual(r["site_name"], "127.0.0.1")
        self.assertEqual(self.decoded(r["image"], "image/png"), png())
        self.assertIn("image/", self.site.hits[0][1])                 # the first request accepts images

    async def test_direct_jpeg_gif_webp(self):
        r = await self.preview("/photo.jpg")
        self.assertEqual((r["kind"], r["width"], r["height"]), ("image", 640, 427))
        self.assertEqual(self.decoded(r["image"], "image/jpeg"), jpeg())
        r = await self.preview("/anim.gif")
        self.assertEqual((r["width"], r["height"]), (320, 200))
        r = await self.preview("/pic.webp")
        self.assertEqual((r["kind"], r["width"], r["height"]), ("image", 1200, 800))

    async def test_redirect_to_an_image_reports_the_final_url(self):
        r = await self.preview("/moved.jpg")
        self.assertEqual((r["url"], r["kind"], r["width"]), (self.base + "/photo.jpg", "image", 640))

    async def test_unsafe_or_unchecked_image_types_give_no_image(self):
        for path in ("/vector.svg", "/fake.png", "/photo.avif"):
            r = await self.preview(path)
            self.assertEqual((r["kind"], r["image"], r["width"], r["height"]), ("image", None, None, None), path)

    async def test_oversized_images_are_refused(self):
        with mock.patch.object(bridge, "LINK_DIRECT_IMAGE_MAX", 100):
            r = await self.preview("/photo.png")                       # Content-Length over the cap: body never read
            self.assertEqual((r["kind"], r["image"]), ("image", None))
            r = await self.preview("/chunked.png")                     # no Content-Length: cut while reading
            self.assertEqual((r["kind"], r["image"]), ("image", None))
        r = await self.preview("/chunked.png")                         # under the real cap it is fine
        self.assertIsNotNone(r["image"])

    async def test_direct_cap_does_not_raise_the_page_image_cap(self):
        with mock.patch.object(bridge, "LINK_IMAGE_MAX", 20):
            r = await self.preview("/article")
        self.assertEqual((r["kind"], r["title"], r["image"]), ("page", "Article", None))
        self.assertIsNotNone(r["favicon"])

    async def test_page_og_image_has_size(self):
        r = await self.preview("/article")
        self.assertEqual((r["kind"], r["title"], r["width"], r["height"]), ("page", "Article", 640, 427))
        self.assertEqual(self.decoded(r["image"], "image/jpeg"), jpeg())

    async def test_redirects_to_private_targets_are_blocked(self):
        for path in ("/to-private.png", "/to-localhost.png"):
            with self.assertRaises(bridge.LinkBlocked) as ctx:
                await self.preview(path)
            self.assertEqual(str(ctx.exception), "blocked_url", path)

    async def test_http_errors_fail(self):
        with self.assertRaises(bridge.LinkBlocked) as ctx:
            await self.preview("/gone.png")
        self.assertEqual(str(ctx.exception), "fetch_failed")

    async def test_route_caches_failed_images_briefly_and_keeps_auth(self):
        client = TestClient(TestServer(bridge.make_app()))
        await client.start_server()
        try:
            auth = {"Authorization": "Bearer fixture-key-for-link-image-tests"}
            self.assertEqual((await client.get("/api/link-preview", params={"url": self.base + "/photo.png"})).status, 401)
            r = await client.get("/api/link-preview", params={"url": self.base + "/photo.png"}, headers=auth)
            body = await r.json()
            self.assertEqual(r.status, 200, body)
            self.assertEqual((r.status, body["kind"], body["width"]), (200, "image", 64))
            self.assertIn("max-age=%d" % bridge.LINK_CACHE_S, r.headers["Cache-Control"])
            r = await client.get("/api/link-preview", params={"url": self.base + "/vector.svg"}, headers=auth)
            self.assertEqual(((await r.json())["image"], r.headers["Cache-Control"]),
                             (None, "private, max-age=%d" % bridge.LINK_FAIL_CACHE_S))
            expires = bridge.LINK_CACHE[self.base + "/vector.svg"][0]
            self.assertLessEqual(expires - time.monotonic(), bridge.LINK_FAIL_CACHE_S)
            hits = len(self.site.hits)
            r = await client.get("/api/link-preview", params={"url": self.base + "/photo.png"}, headers=auth)
            self.assertEqual(((await r.json())["width"], len(self.site.hits)), (64, hits))   # served from the cache
            r = await client.get("/api/link-preview", params={"url": self.base + "/to-private.png"}, headers=auth)
            self.assertEqual((r.status, (await r.json())["code"]), (400, "blocked_url"))
            r = await client.get("/api/link-preview", params={"url": "http://10.0.0.7/photo.png"}, headers=auth)
            self.assertEqual((r.status, (await r.json())["code"]), (400, "blocked_url"))
        finally:
            await client.close()


class HeaderSizeTests(unittest.TestCase):
    def test_sizes(self):
        self.assertEqual(bridge.link_image_size(png(7, 9)), (7, 9))
        self.assertEqual(bridge.link_image_size(jpeg(1, 65535)), (1, 65535))
        self.assertEqual(bridge.link_image_size(gif(5, 6)), (5, 6))
        for kind in (b"VP8 ", b"VP8L", b"VP8X"):
            self.assertEqual(bridge.link_image_size(webp(kind, 300, 150)), (300, 150), kind)

    def test_garbage_and_truncated_headers(self):
        self.assertEqual(bridge.link_image_size(b"\x89PNG\r\n\x1a\n"), (None, None))
        self.assertEqual(bridge.link_image_size(png(0, 9)), (None, None))
        self.assertEqual(bridge.link_image_size(b"\xff\xd8\xff"), (None, None))
        self.assertEqual(bridge.link_image_size(jpeg()[:20]), (None, None))
        self.assertEqual(bridge.link_image_size(b"\xff\xd8" + b"\xff\xe0\x00\x00" * 50), (None, None))  # seg < 2
        self.assertEqual(bridge.link_image_size(b"\xff\xd8" + b"\xff\xd0" * 2000), (None, None))         # bounded
        self.assertEqual(bridge.link_image_size(b"RIFF\x00\x00\x00\x00WEBPVP8X"), (None, None))
        self.assertEqual(bridge.link_image_size(b"\x00\x00\x01\x00"), (None, None))

    def test_link_image_requires_matching_bytes_and_no_cut(self):
        self.assertEqual(bridge.link_image("image/png", png(3, 4), False)[1:], (3, 4))
        self.assertEqual(bridge.link_image("image/png", png(3, 4), True), (None, None, None))
        self.assertEqual(bridge.link_image("image/svg+xml", b"<svg/>", False), (None, None, None))
        self.assertEqual(bridge.link_image("image/jpeg", png(), False), (None, None, None))


class CacheBudgetTests(unittest.TestCase):
    def setUp(self):
        bridge.LINK_CACHE.clear()

    def tearDown(self):
        bridge.LINK_CACHE.clear()

    def test_oldest_previews_go_when_images_exceed_the_budget(self):
        with mock.patch.object(bridge, "LINK_CACHE_BYTES", 2500):
            for i in range(4):
                bridge.link_cache_put("u%d" % i, time.monotonic() + 60, 200, {"url": "u", "image": "x" * 1000})
            self.assertEqual(list(bridge.LINK_CACHE), ["u2", "u3"])
            bridge.link_cache_put("u2", time.monotonic() + 60, 200, {"url": "u", "image": None})   # replace, not add
            self.assertEqual(list(bridge.LINK_CACHE), ["u3", "u2"])

    def test_entry_count_limit_still_applies(self):
        with mock.patch.object(bridge, "LINK_CACHE_MAX", 3):
            for i in range(5):
                bridge.link_cache_put("u%d" % i, time.monotonic() + 60, 200, {"url": "u"})
        self.assertEqual(list(bridge.LINK_CACHE), ["u2", "u3", "u4"])



ICO = b"\x00\x00\x01\x00\x01\x00\x10\x10" + b"\x00" * 30


class FaviconTests(unittest.IsolatedAsyncioTestCase):
    """GET /api/favicon (round 3): /favicon.ico first, else the home page's <link rel="icon">, cached per host."""

    async def asyncSetUp(self):
        self.mode, self.hits = "ico", []
        app = web.Application()
        app.router.add_get("/{tail:.*}", self.handle)
        self.server = TestServer(app, host="127.0.0.1")
        await self.server.start_server()
        self.origin = "http://127.0.0.1:%d" % self.server.port
        self.patches = [mock.patch.object(bridge, "public_ip", lambda a: a == "127.0.0.1" or REAL_PUBLIC_IP(a)),
                        mock.patch.object(bridge, "LINK_PORTS", bridge.LINK_PORTS | {self.server.port})]
        for p in self.patches:
            p.start()
        self.previous = dict(bridge.CFG)
        bridge.CFG.update(live_key="fixture-key-for-link-image-tests", link_preview=True)
        bridge.LINK_CACHE.clear()

    async def asyncTearDown(self):
        for p in self.patches:
            p.stop()
        await self.server.close()
        bridge.CFG.clear()
        bridge.CFG.update(self.previous)
        bridge.LINK_CACHE.clear()

    async def handle(self, req):
        self.hits.append(req.path)
        if req.path == "/favicon.ico" and self.mode == "ico":
            return web.Response(body=ICO, content_type="image/x-icon")
        if req.path == "/" and self.mode == "html":
            return web.Response(text='<html><head><link rel="icon" href="/fake.png"><link rel="icon" href="/icon.png"></head></html>',
                                content_type="text/html")
        if req.path == "/fake.png":
            return web.Response(body=b"<html></html>", content_type="image/png")
        if req.path == "/icon.png":
            return web.Response(body=png(32, 32), content_type="image/png")
        return web.Response(status=404)

    async def test_favicon_ico_then_declared_icons_then_nothing(self):
        r = await bridge.build_favicon("site.test", self.origin)
        self.assertEqual((r["host"], r["url"], r["width"]), ("site.test", self.origin + "/favicon.ico", None))
        self.assertEqual(base64.b64decode(r["favicon"].split(",", 1)[1]), ICO)
        self.assertTrue(r["favicon"].startswith("data:image/x-icon;base64,"))
        self.mode = "html"
        r = await bridge.build_favicon("site.test", self.origin)
        self.assertEqual((r["url"], r["width"], r["height"]), (self.origin + "/icon.png", 32, 32))   # the fake PNG is skipped
        self.mode = "none"
        r = await bridge.build_favicon("site.test", self.origin)
        self.assertEqual((r["favicon"], r["url"]), (None, None))

    async def test_route_validates_hosts_and_caches(self):
        client = TestClient(TestServer(bridge.make_app()))
        await client.start_server()
        auth = {"Authorization": "Bearer fixture-key-for-link-image-tests"}
        try:
            self.assertEqual((await client.get("/api/favicon?host=example.com")).status, 401)
            for host in ("", "localhost", "10.0.0.1", "nodots", "a/b.com", "box.local", "x.ts.net", "-a.com", "example.com:8443"):
                with self.subTest(host=host):
                    r = await client.get("/api/favicon", params={"host": host}, headers=auth)
                    self.assertEqual((r.status, (await r.json())["code"]), (400, "blocked_url" if host in ("box.local", "x.ts.net") else "bad_host"))
            calls = []

            async def fake(host, origin=None):
                calls.append(host)
                return {"host": host, "url": "https://example.com/favicon.ico", "favicon": "data:image/x-icon;base64,AAABAA==",
                        "width": None, "height": None}
            with mock.patch.object(bridge, "build_favicon", fake):
                a = await (await client.get("/api/favicon?host=WWW.Example.com", headers=auth)).json()
                b = await (await client.get("/api/favicon?host=example.com", headers=auth)).json()
            self.assertEqual((a, calls), (b, ["example.com"]))
            caps = await (await client.get("/api/capabilities", headers=auth)).json()
            self.assertIs(caps["favicon"], True)
        finally:
            await client.close()


class ImageProxyTests(unittest.IsolatedAsyncioTestCase):
    """GET /api/image (round 6 B5): raw bytes through the same SSRF rules, cached on disk, sized host variants."""

    async def asyncSetUp(self):
        await LinkImageTests.asyncSetUp(self)
        import tempfile
        self.temp = tempfile.TemporaryDirectory()
        bridge.CFG.update(data_dir=self.temp.name, chat_db=self.temp.name + "/c.sqlite", upload_dir=self.temp.name + "/u",
                          hermes_upload_dir="", ui_prompt_file="off", hermes_key="")
        bridge.IMAGE_FAILS.clear()
        self.client = TestClient(TestServer(bridge.make_app()))
        await self.client.start_server()
        self.auth = {"Authorization": "Bearer fixture-key-for-link-image-tests"}

    async def asyncTearDown(self):
        await self.client.close()
        self.temp.cleanup()
        bridge.IMAGE_FAILS.clear()
        await LinkImageTests.asyncTearDown(self)

    async def get(self, path, w=None, headers=None):
        q = {"url": self.base + path, **({"w": w} if w is not None else {})}
        return await self.client.get("/api/image", params=q, headers={**self.auth, **(headers or {})})

    async def test_bytes_headers_cache_and_etag(self):
        r = await self.get("/photo.jpg", w="600")
        self.assertEqual((r.status, r.content_type), (200, "image/jpeg"))
        self.assertEqual(await r.read(), jpeg())
        self.assertEqual((r.headers["X-Image-Width"], r.headers["X-Image-Height"]), ("640", "427"))
        self.assertIn("max-age=604800", r.headers["Cache-Control"])
        self.assertEqual(r.headers["Content-Security-Policy"], "sandbox")
        self.assertTrue(self.site.hits)
        etag, hits = r.headers["ETag"], len(self.site.hits)
        again = await self.get("/photo.jpg", w="600")
        self.assertEqual((again.status, await again.read()), (200, jpeg()))
        self.assertEqual(len(self.site.hits), hits, "served from the disk cache")
        self.assertEqual((await self.get("/photo.jpg", w="600", headers={"If-None-Match": etag})).status, 304)

    async def test_refusals(self):
        self.assertEqual((await self.client.get("/api/image", params={"url": self.base + "/photo.png"})).status, 401)
        for path, status, code in (("/vector.svg", 415, "unsupported_type"), ("/fake.png", 415, "unsupported_type"),
                                   ("/photo.avif", 415, "unsupported_type"), ("/article", 415, "unsupported_type"),
                                   ("/to-private.png", 400, "blocked_url"), ("/gone.png", 502, "fetch_failed")):
            r = await self.get(path)
            self.assertEqual((r.status, (await r.json())["code"]), (status, code), path)
        r = await self.client.get("/api/image", params={"url": "http://10.0.0.7/x.png"}, headers=self.auth)
        self.assertEqual(r.status, 400)
        self.assertEqual((await self.get("/photo.png", w="big")).status, 400)
        with mock.patch.object(bridge, "IMAGE_PROXY_MAX", 100):
            self.assertEqual((await self.get("/chunked.png", w="320")).status, 413)

    async def test_a_429_is_retried_once_and_paths_keep_their_encoding(self):
        r = await self.get("/busy.png")
        self.assertEqual((r.status, await r.read()), (200, png()))
        r = await self.get("/a%2Cb.png")
        self.assertEqual(r.status, 200)

    async def test_capability_and_agent(self):
        caps = await (await self.client.get("/api/capabilities", headers=self.auth)).json()
        self.assertEqual(caps["image_proxy"]["max_mb"], 8)
        self.assertNotIn("Mozilla", bridge.LINK_UA)                  # descriptive, not a browser imitation

    def test_sized_variants(self):
        v = bridge.image_variant_url
        self.assertEqual(v("https://upload.wikimedia.org/wikipedia/commons/6/6d/Red_Panda_(1).jpg", 640),
                         "https://upload.wikimedia.org/wikipedia/commons/thumb/6/6d/Red_Panda_(1).jpg/960px-Red_Panda_(1).jpg")
        self.assertEqual(v("https://upload.wikimedia.org/wikipedia/en/4/4a/Logo.svg", 300),
                         "https://upload.wikimedia.org/wikipedia/en/thumb/4/4a/Logo.svg/330px-Logo.svg.png")
        self.assertIsNone(v("https://upload.wikimedia.org/wikipedia/commons/thumb/a/a7/x.jpg/500px-x.jpg", 640))
        self.assertEqual(v("https://i.pinimg.com/originals/bd/16/x.png", 640), "https://i.pinimg.com/736x/bd/16/x.png")
        self.assertEqual(v("https://images.unsplash.com/photo-1?fm=jpg&w=3000", 1280),
                         "https://images.unsplash.com/photo-1?fm=jpg&w=1280&fit=max")
        self.assertIsNone(v("https://example.com/a.jpg", 640))


if __name__ == "__main__":
    unittest.main()
