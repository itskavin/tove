"""Tests for the tove-setup skill's helper. Standard library only; nothing is installed and no network is used.

    python3 -m unittest discover -s hermes-skill -p 'test_*.py'
"""
import importlib.util, io, json, os, stat, sys, tempfile, unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("tove_setup", HERE / "tove-setup" / "scripts" / "tove_setup.py")
ts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ts)
SERVER = HERE.parent / "server"


def run(*argv):
    out = io.StringIO()
    with redirect_stdout(out):
        code = ts.main(list(argv))
    return code, json.loads(out.getvalue())


class SetupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.env = mock.patch.dict(os.environ, {"TOVE_HOME": str(self.root / "tove"), "HERMES_HOME": str(self.root / "hermes")})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def native(self, key=""):
        """detect() for a native Hermes with (or without) its API key; no Docker, Python and systemd present."""
        hermes = {"found": True, "mode": "native", "hermes_home": str(self.root / "hermes"), "bridge_network": "host",
                  "api_url_for_bridge": "http://127.0.0.1:8642/v1", "api_url_for_host": "http://127.0.0.1:8642/v1",
                  "api_key_set": len(key) >= 16, "_key": key}
        return {"docker": False, "python": sys.executable, "uv": False, "systemd_user": True, "hermes": hermes,
                "recommended_mode": "venv", "in_container": False}

    def test_env_file_parsing(self):
        env = ts.read_env_file('# c\nexport API_SERVER_KEY="abc def"\nX=1\n\nBAD LINE\nY=\'q\'\nZ= spaced \n')
        self.assertEqual(env, {"API_SERVER_KEY": "abc def", "X": "1", "Y": "q", "Z": "spaced"})

    def test_install_needs_consent_before_touching_hermes(self):
        with mock.patch.object(ts, "detect", return_value=self.native()):
            code, out = run("install", "--dry-run", "--source", str(SERVER))
        self.assertEqual(code, 1)
        self.assertIn("--enable-hermes-api", out["error"])
        self.assertFalse((self.root / "hermes").exists())

    def test_dry_run_plans_but_writes_nothing(self):
        with mock.patch.object(ts, "detect", return_value=self.native()):
            code, out = run("install", "--dry-run", "--enable-hermes-api", "--source", str(SERVER))
        self.assertEqual(code, 0)
        self.assertEqual((out["mode"], out["hermes_api_changed"], out["hermes_restart_command"]),
                         ("venv", True, "hermes gateway restart"))
        steps = "\n".join(out["steps"])
        for want in ("API_SERVER_KEY", "bridge.env (mode 600)", "-m venv", "tove-bridge.service", "enable --now tove-bridge"):
            self.assertIn(want, steps)
        self.assertFalse((self.root / "tove").exists())
        self.assertFalse((self.root / "hermes").exists())

    def test_enable_hermes_api_appends_a_strong_key(self):
        (self.root / "hermes").mkdir()
        (self.root / "hermes" / ".env").write_text("OPENROUTER_API_KEY=x\n")
        r = ts.enable_hermes_api(ts.Plan(), self.native())
        env = ts.read_env_file((self.root / "hermes" / ".env").read_text())
        self.assertEqual(env["OPENROUTER_API_KEY"], "x")                        # kept
        self.assertEqual(env["API_SERVER_KEY"], r["key"])
        self.assertGreaterEqual(len(r["key"]), 40)
        self.assertEqual(stat.S_IMODE(os.stat(self.root / "hermes" / ".env").st_mode), 0o600)
        # A key that is already there is reused, and nothing is written.
        again = ts.enable_hermes_api(ts.Plan(), self.native(key="k" * 20))
        self.assertEqual((again["changed"], again["key"]), (False, "k" * 20))

    def test_docker_hermes_on_its_own_network(self):
        det = self.native(key="k" * 32)
        det["hermes"].update(mode="docker", container="hermes", hermes_home="/opt/data", api_host_needs_change=True,
                             bridge_network="hermes_net", api_url_for_bridge="http://hermes:8642/v1")
        det.update(docker=True, recommended_mode="docker")
        with mock.patch.object(ts, "detect", return_value=det):
            code, out = run("install", "--dry-run", "--enable-hermes-api", "--source", str(SERVER))
        self.assertEqual(code, 0)
        steps = "\n".join(out["steps"])
        self.assertIn("API_SERVER_HOST", steps)                                 # listen beyond the container's loopback
        self.assertNotIn("'API_SERVER_KEY'", steps)                              # the existing key stays
        self.assertIn("--network hermes_net -p 127.0.0.1:8787:8787", steps)
        self.assertEqual(out["hermes_restart_command"], "docker restart hermes")

    def test_pair_uses_the_bridge_helper_and_keeps_the_key_out(self):
        home = self.root / "tove"
        (home / "venv" / "bin").mkdir(parents=True)
        os.symlink(sys.executable, home / "venv" / "bin" / "python")
        (home / "bridge.env").write_text("LIVE_PAGE_KEY=secret-key-that-must-not-appear-000\n")
        state = {"mode": "venv", "server": str(SERVER), "data_dir": str(home / "data"), "public_url": "https://box.example.ts.net:8787"}
        (home / "setup.json").write_text(json.dumps(state))
        code, out = run("pair", "--png", str(self.root / "qr.png"), "--name", "box")
        self.assertEqual(code, 0)
        self.assertEqual(out["url"], "https://box.example.ts.net:8787")
        self.assertRegex(out["code"], r"^[2-9A-Z]{5}-[2-9A-Z]{5}$")
        self.assertTrue(out["link"].startswith("tove://pair?u=https%3A%2F%2Fbox.example.ts.net%3A8787&c="))
        self.assertNotIn("secret-key", json.dumps(out))
        self.assertTrue((home / "data" / "pairing.json").exists())

    def test_expose_url_must_be_https(self):
        (self.root / "tove").mkdir()
        (self.root / "tove" / "setup.json").write_text(json.dumps({"port": 8787, "mode": "venv"}))
        code, out = run("expose", "--via", "url", "--url", "http://192.168.1.5:8787")
        self.assertEqual(code, 1)
        self.assertIn("https://", out["error"])

    def test_detect_never_prints_keys(self):
        det = self.native(key="hermes-secret-key-0123456789")
        printed = json.dumps(ts.public(det))
        self.assertNotIn("hermes-secret-key", printed)


if __name__ == "__main__":
    unittest.main()
