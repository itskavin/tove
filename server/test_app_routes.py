"""App downloads, static-file boundaries, and malformed live API requests."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

SPEC = importlib.util.spec_from_file_location("bridge", Path(__file__).with_name("gpt-live-bridge.py"))
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)


class AppRoutesTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.web_root = root / "web"
        self.web_root.mkdir()
        (self.web_root / "index.html").write_text("<title>Hermes Live</title>")
        (self.web_root / "main.dart.js").write_text("void 0;")
        (self.web_root / "engine.wasm").write_bytes(b"\0asm")
        (self.web_root / ".private").write_text("private")
        (root / "outside").write_text("outside")
        (self.web_root / "escape").symlink_to(root / "outside")
        (root / "app.apk").write_bytes(b"test-apk")
        self.previous = dict(bridge.CFG)
        bridge.CFG.update(app_dir=str(self.web_root), apk_path=str(root / "app.apk"),
                          live_key="fixture-key-for-route-testing-only")
        self.auth = {"Authorization": "Bearer " + bridge.CFG["live_key"]}
        app = web.Application()
        app.add_routes([
            web.get("/app", bridge.live_app_redirect),
            web.get("/app/{path:.*}", bridge.live_app),
            web.get("/downloads/hermes-live.apk", bridge.live_apk),
            web.post("/api/session", bridge.api_session),
            web.post("/api/delegate", bridge.api_delegate),
            web.post("/api/stop", bridge.api_stop),
            web.get("/api/job/{sid}/{jid}", bridge.api_job),
        ])
        self.client = TestClient(TestServer(app))
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        bridge.CFG.clear()
        bridge.CFG.update(self.previous)
        self.temp.cleanup()

    async def test_app_index_and_caching(self):
        response = await self.client.get("/app/")
        self.assertEqual(response.status, 200)
        self.assertIn("Hermes Live", await response.text())
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        self.assertIn("frame-ancestors 'none'", response.headers["Content-Security-Policy"])
        script = await self.client.get("/app/main.dart.js")
        self.assertEqual(script.status, 200)
        self.assertEqual(script.headers["Cache-Control"], "no-store")
        wasm = await self.client.get("/app/engine.wasm")
        self.assertEqual(wasm.status, 200)
        self.assertEqual(wasm.headers["Cache-Control"], "no-cache")
        self.assertEqual(wasm.headers["Content-Type"], "application/wasm")

    async def test_app_redirect_preserves_relative_assets(self):
        response = await self.client.get("/app", allow_redirects=False)
        self.assertEqual(response.status, 302)
        self.assertEqual(response.headers["Location"], "/app/")

    async def test_hidden_missing_and_symlink_paths_are_denied(self):
        for path in (".private", "missing.js", "escape", "%00", "..%2f..%2foutside"):
            with self.subTest(path=path):
                response = await self.client.get("/app/" + path)
                self.assertEqual(response.status, 404)

    async def test_apk_content_and_download_headers(self):
        response = await self.client.get("/downloads/hermes-live.apk")
        self.assertEqual(response.status, 200)
        self.assertEqual(await response.read(), b"test-apk")
        self.assertEqual(response.headers["Content-Type"], "application/vnd.android.package-archive")
        self.assertIn("hermes-live.apk", response.headers["Content-Disposition"])

    async def test_unauthorized_api_calls_remain_rejected(self):
        for endpoint in ("session", "delegate", "stop"):
            response = await self.client.post("/api/" + endpoint, json={})
            self.assertEqual(response.status, 401)

    async def test_key_check_contract(self):
        # The app verifies a pasted key with this probe: 404 means the key is right, 401 means it is not.
        self.assertEqual((await self.client.get("/api/job/check/check", headers=self.auth)).status, 404)
        self.assertEqual((await self.client.get("/api/job/check/check")).status, 401)
        wrong = {"Authorization": "Bearer " + "x" * 40}
        self.assertEqual((await self.client.get("/api/job/check/check", headers=wrong)).status, 401)

    async def test_authenticated_non_object_json_is_bad_request(self):
        for endpoint in ("session", "delegate", "stop"):
            for value in ([], None, "text", 7):
                with self.subTest(endpoint=endpoint, value=value):
                    response = await self.client.post("/api/" + endpoint, data=json.dumps(value),
                                                      headers={**self.auth, "Content-Type": "application/json"})
                    self.assertEqual(response.status, 400)


if __name__ == "__main__":
    unittest.main()
