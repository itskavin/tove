"""GET /api/usage/limits (round 6 C7) against a fake CLIProxyAPI management API and a fake ChatGPT usage endpoint.
Nothing real is contacted. Run from this folder with the bridge venv:
  ~/.local/share/gpt-live-bridge/venv/bin/python -m unittest test_usage_limits
"""
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

SPEC = importlib.util.spec_from_file_location("bridge_limits", Path(__file__).with_name("gpt-live-bridge.py"))
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)

KEY = "fixture-key-for-usage-limits"
AUTH = {"Authorization": "Bearer " + KEY}
MGMT = "fixture-management-secret"
LIVE_TOKEN = "eyJfixture-live-access-token"
EMAILS = ("plus.person@example.com", "claude.person@example.org", "free.person@example.com", "ag.person@example.net")

CODEX_BODY = {"user_id": "user-1", "email": EMAILS[0], "plan_type": "plus",
              "rate_limit": {"limit_reached": False,
                             "primary_window": {"used_percent": 3, "limit_window_seconds": 18000, "reset_at": 1794840563},
                             "secondary_window": {"used_percent": 39, "limit_window_seconds": 604800, "reset_at": 1795328547}},
              "credits": {"has_credits": False, "unlimited": False, "balance": "0"}}
CLAUDE_BODY = {"five_hour": {"utilization": 100.0, "resets_at": "2026-11-16T15:10:00+00:00"},
               "seven_day": {"utilization": 72.0, "resets_at": "2026-11-17T20:00:00+00:00"},
               "seven_day_opus": {"utilization": 10.0, "resets_at": "2026-11-17T20:00:00+00:00"}, "seven_day_sonnet": None,
               "extra_usage": {"is_enabled": False}}
AG_BODY = {"groups": [{"displayName": "Gemini Models", "buckets": [
    {"bucketId": "gemini-5h", "window": "5h", "resetTime": "2026-11-16T15:19:20Z", "remainingFraction": 0.25}]}]}


class FakeProxy:
    def __init__(self):
        self.calls, self.relay_fail, self.extra = [], {}, []

    async def auth_files(self, req):
        assert req.headers["Authorization"] == "Bearer " + MGMT
        self.calls.append("auth-files")
        files = [
            {"auth_index": "i-plus", "provider": "codex", "email": EMAILS[0], "disabled": False},
            {"auth_index": "i-claude", "provider": "claude", "email": EMAILS[1], "disabled": False},
            {"auth_index": "i-free", "provider": "codex", "email": EMAILS[2], "disabled": False, "unavailable": True,
             "model_quotas": {"gpt-x": {"observed_at": "2026-11-16T17:23:37+08:00", "signals": {
                 "X-Codex-Plan-Type": "free", "X-Codex-Primary-Used-Percent": "100", "X-Codex-Primary-Window-Minutes": "43200",
                 "X-Codex-Primary-Reset-At": "1797041224", "X-Codex-Credits-Balance": "0"}}}},
            {"auth_index": "i-ag", "provider": "antigravity", "email": EMAILS[3], "disabled": True, "project_id": "p-1"},
        ] + self.extra
        return web.json_response({"files": files})

    async def relay(self, req):
        assert req.headers["Authorization"] == "Bearer " + MGMT
        body = await req.json()
        self.calls.append(("relay", body["authIndex"], body["url"]))
        assert body["header"]["Authorization"] == "Bearer $TOKEN$"             # the proxy fills in the account's token
        if body["authIndex"] in self.relay_fail:
            return web.json_response({"status_code": self.relay_fail[body["authIndex"]], "header": {}, "body": "{}"})
        answer = {bridge.CODEX_USAGE_URL: CODEX_BODY, bridge.CLAUDE_USAGE_URL: CLAUDE_BODY,
                  bridge.ANTIGRAVITY_QUOTA_URL: AG_BODY}[body["url"]]
        if body["url"] == bridge.ANTIGRAVITY_QUOTA_URL:
            assert json.loads(body["data"]) == {"project": "p-1"}
        return web.json_response({"status_code": 200, "header": {}, "body": json.dumps(answer)})

    async def live_usage(self, req):
        assert req.headers["Authorization"] == "Bearer " + LIVE_TOKEN
        self.calls.append("live")
        return web.json_response(CODEX_BODY)                            # the same ChatGPT account as i-plus


class UsageLimitsTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        t = self.temp.name
        self.fake = FakeProxy()
        app = web.Application()
        app.router.add_get("/v0/management/auth-files", self.fake.auth_files)
        app.router.add_post("/v8/management/requests/api-call", self.fake.relay)          # /v0 gives 404, as on current CLIProxyAPI builds
        app.router.add_get("/backend-api/wham/usage", self.fake.live_usage)
        self.server = TestServer(app)
        await self.server.start_server()
        os.makedirs(t + "/codex")
        with open(t + "/codex/auth.json", "w") as f:
            json.dump({"tokens": {"access_token": LIVE_TOKEN, "account_id": "acct-1"}}, f)
        self.previous = dict(bridge.CFG)
        bridge.CFG.update(live_key=KEY, hermes_key="", chat_db=t + "/c.sqlite", data_dir=t, upload_dir=t + "/u", hermes_upload_dir="",
                          ui_prompt_file="off", codex_home=t + "/codex", cliproxy_url=str(self.server.make_url("")).rstrip("/"),
                          cliproxy_mgmt_key=MGMT, usage_live_login=True)
        bridge.LIMITS_CACHE.update(at=0.0, body=None, lock=None)
        self.patch = mock.patch.object(bridge, "CODEX_USAGE_URL", str(self.server.make_url("/backend-api/wham/usage")))
        self.patch.start()
        self.client = TestClient(TestServer(bridge.make_app()))
        await self.client.start_server()

    async def asyncTearDown(self):
        self.patch.stop()
        await self.client.close()
        await self.server.close()
        bridge.CFG.clear()
        bridge.CFG.update(self.previous)
        bridge.LIMITS_CACHE.update(at=0.0, body=None, lock=None)
        self.temp.cleanup()

    async def limits(self, query=""):
        r = await self.client.get("/api/usage/limits" + query, headers=AUTH)
        self.assertEqual(r.status, 200)
        return await r.json()

    async def test_every_provider_and_account_masked(self):
        data = await self.limits()
        raw = json.dumps(data)
        for secret in EMAILS + (LIVE_TOKEN, MGMT, "i-plus", "acct-1"):
            self.assertNotIn(secret, raw)
        self.assertEqual([p["id"] for p in data["providers"]], ["codex", "claude", "antigravity"])
        codex = data["providers"][0]["accounts"]
        plus = codex[0]
        self.assertEqual((plus["label"], plus["plan"], plus["status"], plus["live"]), ("p•••@e•••.com", "plus", "ok", True))
        self.assertEqual(plus["used_for"], ["chat", "live"], "the live login is the same account: merged, not listed twice")
        self.assertEqual(len(codex), 2)
        self.assertEqual([(w["id"], w["remaining_percent"], w["resets_at"]) for w in plus["windows"]],
                         [("5h", 97.0, 1794840563000), ("weekly", 61.0, 1795328547000)])
        self.assertEqual(plus["credits"], {"balance": 0.0, "unlimited": False, "has_credits": False, "currency": None})
        free = codex[1]                                                  # the live call worked too; unavailable wins
        self.assertEqual((free["status"], free["note"] is not None), ("unavailable", True))
        claude = data["providers"][1]["accounts"][0]
        self.assertEqual(claude["status"], "limited")
        self.assertEqual([(w["id"], w["remaining_percent"], w["scope"]) for w in claude["windows"]],
                         [("5h", 0.0, None), ("weekly", 28.0, None), ("weekly-opus", 90.0, "Opus")])
        ag = data["providers"][2]["accounts"][0]
        self.assertEqual((ag["status"], ag["used_for"], ag["windows"][0]["remaining_percent"], ag["windows"][0]["scope"]),
                         ("disabled", [], 25.0, "Gemini Models"))

    async def test_failed_live_check_falls_back_to_recorded_headers(self):
        self.fake.relay_fail["i-free"] = 500
        data = await self.limits()
        free = [a for a in data["providers"][0]["accounts"] if a["plan"] == "free"][0]
        self.assertFalse(free["live"])
        self.assertEqual([(w["id"], w["label"], w["remaining_percent"]) for w in free["windows"]], [("30d", "30-day", 0.0)])
        self.assertIn("last reply", free["note"])

    async def test_cached_then_refresh_and_auth(self):
        await self.limits()
        n = len(self.fake.calls)
        again = await self.limits()
        self.assertTrue(again["cached"])
        self.assertEqual(len(self.fake.calls), n)
        bridge.LIMITS_CACHE["at"] -= bridge.LIMITS_MIN_REFRESH_S
        fresh = await self.limits("?refresh=1")
        self.assertFalse(fresh["cached"])
        self.assertGreater(len(self.fake.calls), n)
        self.assertEqual((await self.client.get("/api/usage/limits")).status, 401)
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertIs(caps["usage_limits"], True)

    async def test_without_any_source(self):
        bridge.CFG.update(cliproxy_mgmt_key="", codex_home=self.temp.name + "/none")
        r = await self.client.get("/api/usage/limits", headers=AUTH)
        self.assertEqual((r.status, (await r.json())["code"]), (503, "usage_limits_unavailable"))

    async def test_accounts_follow_the_proxy_without_restart(self):
        """Round 6 follow-up: the list is read from CLIProxyAPI on every uncached fetch; ?refresh=1 skips the cache;
        a disabled or expired account stays listed with its state; ids are stable while the auth file exists."""
        first = await self.limits()
        ids = {a["id"] for p in first["providers"] for a in p["accounts"]}
        self.assertEqual(len(ids), 4)
        self.fake.extra = [{"auth_index": "i-new", "name": "new.json", "provider": "claude", "email": "new.person@example.com"},
                           {"auth_index": "i-off", "name": "off.json", "provider": "gemini-cli", "email": "off@example.com", "disabled": True}]
        self.fake.relay_fail["i-new"] = 401                                   # its token is refused: expired
        self.assertEqual({a["id"] for p in (await self.limits())["providers"] for a in p["accounts"]}, ids, "cached")
        added = await self.limits("?refresh=1")
        self.assertFalse(added["cached"])
        accts = {a["id"]: a for p in added["providers"] for a in p["accounts"]}
        self.assertEqual(len(accts), 6)
        self.assertTrue(ids <= set(accts), "existing ids are stable")
        new = [a for i, a in accts.items() if i not in ids]
        self.assertEqual(sorted(a["status"] for a in new), ["disabled", "expired"])
        self.assertIn("gemini-cli", [p["id"] for p in added["providers"]])
        self.assertNotIn("new.person", json.dumps(added))
        self.fake.extra = []
        removed = await self.limits("?refresh=1")
        self.assertEqual({a["id"] for p in removed["providers"] for a in p["accounts"]}, ids)

    def test_masking(self):
        self.assertEqual(bridge.mask_account("someone@gmail.com"), "s•••@g•••.com")
        self.assertEqual(bridge.mask_account("plainname"), "pl•••")
        self.assertIsNone(bridge.mask_account(""))


if __name__ == "__main__":
    unittest.main()
