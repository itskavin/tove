"""POST /api/transcribe: WAV upload -> text through a Realtime-compatible websocket (a fake one here)."""
import base64
import importlib.util
import io
import json
import unittest
import wave
from pathlib import Path

import aiohttp
from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

SPEC = importlib.util.spec_from_file_location("bridge", Path(__file__).with_name("gpt-live-bridge.py"))
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)

KEY = "fixture-key-for-transcribe-tests-only"


def wav(seconds=1.0, rate=16000, channels=1, width=2):
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(width)
        w.setframerate(rate)
        w.writeframes(b"\x10\x00" * int(seconds * rate) * channels)
    return out.getvalue()


def form(audio, **fields):
    data = aiohttp.FormData()
    if audio is not None:
        data.add_field("file", audio, filename="clip.wav", content_type="audio/wav")
    for k, v in fields.items():
        data.add_field(k, v)
    return data


class FakeRealtime:
    """Records what the bridge sends; answers like CLIProxyAPI's /v1/realtime."""

    def __init__(self):
        self.mode = "ok"
        self.sessions = []
        self.audio_bytes = 0
        self.query = None
        self.auth = None

    async def handler(self, req):
        ws = web.WebSocketResponse()
        await ws.prepare(req)
        self.query, self.auth = dict(req.query), req.headers.get("Authorization")
        if self.mode == "reject":
            await ws.send_json({"type": "error", "error": {"code": "model_not_found"}})
            await ws.close()
            return ws
        await ws.send_json({"type": "session.created"})
        async for msg in ws:
            e = json.loads(msg.data)
            if e["type"] == "session.update":
                self.sessions.append(e["session"])
            elif e["type"] == "input_audio_buffer.append":
                self.audio_bytes += len(base64.b64decode(e["audio"]))
            elif e["type"] == "input_audio_buffer.commit":
                if self.mode == "fail":
                    await ws.send_json({"type": "conversation.item.input_audio_transcription.failed",
                                        "error": {"code": "audio_unintelligible"}})
                elif self.mode == "hang":
                    continue
                else:
                    await ws.send_json({"type": "conversation.item.input_audio_transcription.completed",
                                        "transcript": " Remind me to call Ramesh at 6:30. "})
        return ws


class TranscribeTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.fake = FakeRealtime()
        up = web.Application()
        up.add_routes([web.get("/v1/realtime", self.fake.handler)])
        self.upstream = TestServer(up)
        await self.upstream.start_server()
        self.previous = dict(bridge.CFG)
        bridge.CFG.update(live_key=KEY, stt_url=str(self.upstream.make_url("/v1/realtime")), stt_key="proxy-key",
                          stt_max_s=10, stt_timeout_s=5, stt_concurrent=1)
        app = web.Application()
        app.add_routes([web.post("/api/transcribe", bridge.api_transcribe)])
        self.client = TestClient(TestServer(app))
        await self.client.start_server()
        self.auth = {"Authorization": "Bearer " + KEY}

    async def asyncTearDown(self):
        await self.client.close()
        await self.upstream.close()
        bridge.CFG.clear()
        bridge.CFG.update(self.previous)
        bridge.STT_SLOTS["busy"] = 0

    async def post(self, data, headers=None):
        return await self.client.post("/api/transcribe", data=data, headers=self.auth if headers is None else headers)

    async def test_transcribes_with_language_and_prompt(self):
        r = await self.post(form(wav(1.0), language="en-IN", prompt="Names: Koramangala"))
        self.assertEqual(r.status, 200)
        body = await r.json()
        self.assertEqual(body["text"], "Remind me to call Ramesh at 6:30.")
        self.assertEqual(body["duration_s"], 1.0)
        tr = self.fake.sessions[0]["audio"]["input"]["transcription"]
        self.assertEqual(tr, {"model": "gpt-4o-transcribe", "language": "en", "prompt": "Names: Koramangala"})
        self.assertIsNone(self.fake.sessions[0]["audio"]["input"]["turn_detection"])
        self.assertEqual(self.fake.audio_bytes, 24000 * 2)           # resampled to 24 kHz mono
        self.assertEqual(self.fake.query["model"], "gpt-realtime-2.1-mini")
        self.assertEqual(self.fake.auth, "Bearer proxy-key")

    async def test_stereo_48k_is_downmixed(self):
        r = await self.post(form(wav(0.5, rate=48000, channels=2)))
        self.assertEqual(r.status, 200)
        self.assertEqual(self.fake.audio_bytes, 12000 * 2)

    async def test_auth_and_unconfigured(self):
        r = await self.post(form(wav()), headers={})
        self.assertEqual(r.status, 401)
        bridge.CFG["stt_url"] = ""
        r = await self.post(form(wav()))
        self.assertEqual(r.status, 503)
        self.assertEqual((await r.json())["code"], "transcribe_unavailable")

    async def test_bad_input(self):
        for data, status in ((form(None, language="en"), 400), (form(b"not a wav"), 415),
                             (form(wav(width=1)), 415), (form(wav(11.0)), 413)):
            with self.subTest(status=status):
                r = await self.post(data)
                self.assertEqual(r.status, status)
                self.assertIn((await r.json())["code"], ("bad_audio", "too_large"))
        r = await self.client.post("/api/transcribe", data=b"raw", headers={**self.auth, "Content-Type": "audio/wav"})
        self.assertEqual(r.status, 400)
        self.assertEqual(self.fake.audio_bytes, 0)

    async def test_tiny_clip_skips_upstream(self):
        r = await self.post(form(wav(0.05)))
        self.assertEqual(r.status, 200)
        self.assertEqual((await r.json())["text"], "")
        self.assertEqual(self.fake.sessions, [])

    async def test_upstream_errors(self):
        for mode, status, code in (("reject", 502, "transcribe_failed"), ("fail", 502, "transcribe_failed"),
                                   ("hang", 504, "transcribe_timeout")):
            with self.subTest(mode=mode):
                self.fake.mode = mode
                if mode == "hang":
                    bridge.CFG["stt_timeout_s"] = 1
                r = await self.post(form(wav(0.5)))
                self.assertEqual(r.status, status)
                self.assertEqual((await r.json())["code"], code)
                self.assertEqual(bridge.STT_SLOTS["busy"], 0)

    async def test_busy(self):
        bridge.STT_SLOTS["busy"] = 1
        r = await self.post(form(wav(0.5)))
        self.assertEqual(r.status, 503)
        self.assertEqual((await r.json())["code"], "busy")

    def test_language_tags(self):
        self.assertEqual(bridge.stt_language("en-IN"), "en")
        self.assertEqual(bridge.stt_language("hi_IN"), "hi")
        self.assertIsNone(bridge.stt_language(""))
        self.assertIsNone(bridge.stt_language("x"))


if __name__ == "__main__":
    unittest.main()
