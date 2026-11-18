"""Tests for the image-search Hermes plugin. Run: python3 -m unittest test_image_search (from this directory)."""

import importlib.util
import json
import os
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

_spec = importlib.util.spec_from_file_location("image_search_plugin", Path(__file__).with_name("__init__.py"))
plugin = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(plugin)


def row(img, page, **kw):
    return {"img_src": img, "url": page, "title": kw.pop("title", "A title"), **kw}


class NormalizeTests(unittest.TestCase):
    def test_keeps_real_urls_and_attribution(self):
        out = plugin.normalize([row("https://upload.wikimedia.org/a.jpg", "https://commons.wikimedia.org/wiki/File:A.jpg",
                                    title="  Golden\n Gate ", resolution="2048 x 1536", engine="wikicommons.images")], 5)
        self.assertEqual(out, [{"position": 1, "title": "Golden Gate", "image_url": "https://upload.wikimedia.org/a.jpg",
                                "source_page": "https://commons.wikimedia.org/wiki/File:A.jpg",
                                "source": "commons.wikimedia.org", "width": 2048, "height": 1536,
                                "engine": "wikicommons.images"}])

    def test_drops_rows_without_image_or_page_and_bad_schemes(self):
        out = plugin.normalize([
            row("", "https://a.example/p"),
            row("https://a.example/i.jpg", ""),
            row("data:image/png;base64,AAAA", "https://a.example/p"),
            row("javascript:alert(1)", "https://a.example/p"),
            row("https://user:pw@a.example/i.jpg", "https://a.example/p"),
            row("https://a.example/i.jpg", "ftp://a.example/p"),
            row("https://a.example/has space.jpg", "https://a.example/p"),
            row("https://a.example/" + "x" * 3000, "https://a.example/p"),
            row(None, "https://a.example/p"),
            "not a dict",
        ], 10)
        self.assertEqual(out, [])

    def test_protocol_relative_image_becomes_https(self):
        out = plugin.normalize([row("//cdn.example/i.png", "https://example.org/page")], 5)
        self.assertEqual(out[0]["image_url"], "https://cdn.example/i.png")

    def test_dedupes_and_limits(self):
        rows = [row("https://a.example/1.jpg", "https://a.example/p1"), row("https://a.example/1.jpg", "https://b.example/p"),
                row("https://a.example/2.jpg", "https://a.example/p2"), row("https://a.example/3.jpg", "https://a.example/p3")]
        out = plugin.normalize(rows, 2)
        self.assertEqual([r["image_url"] for r in out], ["https://a.example/1.jpg", "https://a.example/2.jpg"])
        self.assertEqual([r["position"] for r in out], [1, 2])

    def test_skips_stock_and_tiny_and_orders_large_last(self):
        out = plugin.normalize([
            row("https://media.istockphoto.com/x.jpg", "https://www.istockphoto.com/photos/x"),
            row("https://a.example/i.jpg", "https://www.shutterstock.com/x"),
            row("https://a.example/tiny.png", "https://a.example/p", resolution="64x64"),
            row("https://a.example/huge.jpg", "https://a.example/huge", resolution="5388x3368"),
            row("https://a.example/ok.jpg", "https://a.example/ok", resolution="1600×1168", source="Britannica"),
        ], 5)
        self.assertEqual([r["image_url"] for r in out], ["https://a.example/ok.jpg", "https://a.example/huge.jpg"])
        self.assertEqual(out[0]["source"], "Britannica")
        self.assertEqual((out[0]["width"], out[0]["height"]), (1600, 1168))

    def test_drops_crawler_pages_and_unshowable_formats(self):
        out = plugin.normalize([
            row("https://lookaside.fbsbx.com/lookaside/crawler/media/?media_id=1", "https://www.facebook.com/x"),
            row("https://lookaside.instagram.com/seo/google_widget/crawler/?media_id=2", "https://www.instagram.com/p/x"),
            row("https://a.example/logo.svg", "https://a.example/"),
            row("https://a.example/photo.AVIF", "https://a.example/p"),
            row("https://upload.wikimedia.org/wikipedia/commons/4/4a/Logo.svg", "https://commons.wikimedia.org/wiki/File:Logo.svg"),
            row("https://a.example/ok.jpg", "https://a.example/ok"),
        ], 6)
        self.assertEqual([r["image_url"] for r in out], ["https://upload.wikimedia.org/wikipedia/commons/4/4a/Logo.svg",
                                                          "https://a.example/ok.jpg"])

    def test_unknown_size_is_null(self):
        out = plugin.normalize([row("https://a.example/i.jpg", "https://www.a.example/p", resolution="")], 5)
        self.assertEqual((out[0]["width"], out[0]["height"], out[0]["source"]), (None, None, "a.example"))


class HandlerTests(unittest.TestCase):
    def call(self, args, data=None, exc=None):
        fetch = mock.Mock(side_effect=exc) if exc else mock.Mock(return_value=data)
        with mock.patch.dict(os.environ, {"SEARXNG_URL": "http://searxng:8080/"}), \
                mock.patch.object(plugin, "fetch_json", fetch):
            return json.loads(plugin.handle_image_search(args)), fetch

    def test_queries_images_category_with_safesearch(self):
        out, fetch = self.call({"query": "golden gate", "limit": 3},
                               {"results": [row("https://a.example/i.jpg", "https://a.example/p")]})
        url = fetch.call_args.args[0]
        self.assertTrue(url.startswith("http://searxng:8080/search?"))
        self.assertIn("categories=images", url)
        self.assertIn("safesearch=1", url)
        self.assertIn("format=json", url)
        self.assertTrue(out["success"])
        self.assertEqual(out["results"][0]["source_page"], "https://a.example/p")

    def test_requires_query(self):
        out, fetch = self.call({"query": "  "})
        self.assertFalse(out["success"])
        fetch.assert_not_called()

    def test_limit_is_clamped(self):
        rows = [row(f"https://a.example/{i}.jpg", f"https://a.example/{i}") for i in range(20)]
        out, _ = self.call({"query": "x", "limit": 99}, {"results": rows})
        self.assertEqual(len(out["results"]), plugin.LIMIT_MAX)
        out, _ = self.call({"query": "x", "limit": "bad"}, {"results": rows})
        self.assertEqual(len(out["results"]), plugin.LIMIT_DEFAULT)

    def test_failures_are_reported_without_results(self):
        out, _ = self.call({"query": "x"}, exc=urllib.error.URLError("down"))
        self.assertEqual(out, {"success": False, "error": "image search is unavailable right now"})
        out, _ = self.call({"query": "x"}, exc=urllib.error.HTTPError("u", 503, "x", {}, None))
        self.assertFalse(out["success"])
        out, _ = self.call({"query": "x"}, data=["not", "a", "dict"])
        self.assertEqual(out["results"], [])
        self.assertIn("without images", out["note"])

    def test_missing_searxng_url(self):
        with mock.patch.dict(os.environ, {"SEARXNG_URL": ""}), mock.patch.object(plugin, "fetch_json") as fetch:
            out = json.loads(plugin.handle_image_search({"query": "x"}))
        self.assertFalse(out["success"])
        fetch.assert_not_called()
        self.assertFalse(plugin.check_image_search())

    def test_register_uses_web_toolset(self):
        ctx = mock.Mock()
        plugin.register(ctx)
        kw = ctx.register_tool.call_args.kwargs
        self.assertEqual((kw["name"], kw["toolset"]), ("image_search", "web"))
        self.assertEqual(kw["schema"]["name"], "image_search")


if __name__ == "__main__":
    unittest.main()
