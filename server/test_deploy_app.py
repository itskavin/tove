"""deploy-app.py: release swaps, pruning and refusal to publish unsafe builds."""
import importlib.util
import io
import sys
import tempfile
import unittest
import zipfile
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

SPEC = importlib.util.spec_from_file_location("deploy_app", Path(__file__).with_name("deploy-app.py"))
deploy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(deploy)

FIXTURE_KEY = "fixture-live-key-for-deploy-tests"


class DeployAppTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.dest = root / "bridge"
        self.dest.mkdir()
        (self.dest / "bridge.env").write_text("LIVE_PAGE_KEY=%s\nBRIDGE_PORT=3129\n" % FIXTURE_KEY)
        self.build = root / "build"
        self.build.mkdir()
        (self.build / "index.html").write_text('<base href="/app/"><title>Hermes Live</title>')
        (self.build / "main.dart.js").write_text("void 0;")
        (self.build / ".last_build_id").write_text("x")

    def tearDown(self):
        self.temp.cleanup()

    def run_deploy(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "argv", ["deploy-app.py", "--destination", str(self.dest), *argv]), \
                redirect_stdout(out), redirect_stderr(err):
            try:
                deploy.main()
                code = 0
            except SystemExit as exc:
                code = exc.code if isinstance(exc.code, int) else 1
                err.write(str(exc.code))
        return code, out.getvalue() + err.getvalue()

    def releases(self):
        return sorted(p.name for p in (self.dest / "web-releases").iterdir())

    def test_publish_swaps_symlink_and_skips_dotfiles(self):
        code, _ = self.run_deploy("--web-dir", str(self.build))
        self.assertEqual(code, 0)
        web = self.dest / "web"
        self.assertTrue(web.is_symlink())
        self.assertTrue((web / "index.html").is_file())
        self.assertFalse((web / ".last_build_id").exists())
        self.assertFalse((self.dest / "web.new").exists())

    def test_old_releases_pruned_and_stale_link_replaced(self):
        (self.dest / "web-releases").mkdir()
        (self.dest / "web-releases" / "1.partial").mkdir()
        (self.dest / "web.new").symlink_to("nowhere")
        for _ in range(4):
            self.assertEqual(self.run_deploy("--web-dir", str(self.build), "--keep", "2")[0], 0)
        kept = self.releases()
        self.assertEqual(len(kept), 2)
        self.assertEqual((self.dest / "web").resolve().name, kept[-1])

    def test_refuses_build_without_app_base_href(self):
        (self.build / "index.html").write_text('<base href="/">')
        code, output = self.run_deploy("--web-dir", str(self.build))
        self.assertNotEqual(code, 0)
        self.assertIn("--base-href /app/", output)
        self.assertFalse((self.dest / "web").exists())

    def test_refuses_symlinks_in_build(self):
        (self.build / "link").symlink_to(self.dest / "bridge.env")
        code, _ = self.run_deploy("--web-dir", str(self.build))
        self.assertNotEqual(code, 0)
        self.assertFalse((self.dest / "web-releases").exists())

    def test_fallback_fonts_required_when_bootstrap_uses_them(self):
        (self.build / "flutter_bootstrap.js").write_text('config:{fontFallbackBaseUrl:"fonts/fallback/"}')
        code, output = self.run_deploy("--web-dir", str(self.build))
        self.assertNotEqual(code, 0)
        self.assertIn("manifest.json", output)
        fonts = self.build / "fonts" / "fallback" / "noto" / "v1"
        fonts.mkdir(parents=True)
        (fonts / "a.woff2").write_bytes(b"wOF2data")
        manifest = self.build / "fonts" / "fallback" / "manifest.json"
        manifest.write_text('{"files": {"noto/v1/a.woff2": {"bytes": 8}, "noto/v1/b.woff2": {"bytes": 3}}}')
        code, output = self.run_deploy("--web-dir", str(self.build))
        self.assertNotEqual(code, 0)
        self.assertIn("noto/v1/b.woff2", output)
        self.assertFalse((self.dest / "web-releases").exists())
        manifest.write_text('{"files": {"noto/v1/a.woff2": {"bytes": 8}}}')
        self.assertEqual(self.run_deploy("--web-dir", str(self.build))[0], 0)
        self.assertTrue((self.dest / "web" / "fonts" / "fallback" / "noto" / "v1" / "a.woff2").is_file())

    def test_refuses_unmanaged_web_directory(self):
        (self.dest / "web").mkdir()
        code, _ = self.run_deploy("--web-dir", str(self.build))
        self.assertNotEqual(code, 0)
        self.assertFalse((self.dest / "web-releases").exists())

    def test_secret_in_web_build_is_refused_without_echoing_it(self):
        (self.build / "assets").mkdir()
        (self.build / "assets" / "config.json").write_text('{"k":"%s"}' % FIXTURE_KEY)
        code, output = self.run_deploy("--web-dir", str(self.build))
        self.assertNotEqual(code, 0)
        self.assertIn("LIVE_PAGE_KEY", output)
        self.assertNotIn(FIXTURE_KEY, output)
        self.assertFalse((self.dest / "web").exists())

    def test_notify_key_in_web_build_is_refused(self):
        notify_key = "fixture-notify-key-for-deploy-tests"
        with (self.dest / "bridge.env").open("a") as env:
            env.write("TOVE_NOTIFY_KEY=%s\n" % notify_key)
        (self.build / "assets").mkdir()
        (self.build / "assets" / "config.json").write_text('{"n":"%s"}' % notify_key)
        code, output = self.run_deploy("--web-dir", str(self.build))
        self.assertNotEqual(code, 0)
        self.assertIn("TOVE_NOTIFY_KEY", output)
        self.assertNotIn(notify_key, output)
        self.assertFalse((self.dest / "web").exists())

    def test_secret_inside_compressed_apk_entry_is_found(self):
        apk = Path(self.temp.name) / "app.apk"
        with zipfile.ZipFile(apk, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("lib/arm64-v8a/libapp.so", b"\0" * 64 + FIXTURE_KEY.encode())
        hits = list(deploy.leaked(deploy.apk_blobs(apk), deploy.bridge_secrets(self.dest)))
        self.assertEqual(hits, [("lib/arm64-v8a/libapp.so", "LIVE_PAGE_KEY")])

    def test_non_apk_is_refused(self):
        bogus = Path(self.temp.name) / "bogus.apk"
        bogus.write_bytes(b"not a zip")
        code, _ = self.run_deploy("--apk", str(bogus))
        self.assertNotEqual(code, 0)
        self.assertFalse((self.dest / "hermes-live.apk").exists())


if __name__ == "__main__":
    unittest.main()
