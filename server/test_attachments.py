"""Attachments, persisted tool calls, live job progress, the web_search flag, the app's UI prompt and link previews,
against a fake Hermes. No real Hermes, OpenAI or outside website is contacted. Run from this folder with the venv:
  ~/.local/share/gpt-live-bridge/venv/bin/python -m unittest test_attachments
"""
import asyncio
import importlib.util
import io
import json
import os
import socket
import stat
import struct
import tempfile
import time
import unittest
import zipfile
import zlib
from pathlib import Path
from unittest import mock

import aiohttp
from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

SPEC = importlib.util.spec_from_file_location("bridge_att", Path(__file__).with_name("gpt-live-bridge.py"))
bridge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bridge)

KEY = "fixture-key-for-attachment-tests"
AUTH = {"Authorization": "Bearer " + KEY}


def png(w=64, h=48, rgb=(200, 30, 30)):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def office_zip(extra=()):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("[Content_Types].xml", "<Types/>")
        z.writestr("word/document.xml", "<w:document/>")
        for name in extra:
            z.writestr(name, "x")
    return buf.getvalue()


class FakeHermes:
    def __init__(self):
        self.requests, self.toolsets_web = [], True
        self.gate = None                                  # an Event: the stream waits for it after its first delta

    def chunk(self, delta, finish=None):
        return ("data: " + json.dumps({"choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}) + "\n\n").encode()

    async def toolsets(self, req):
        return web.json_response({"object": "list", "platform": "api_server", "data": [
            {"name": "web", "enabled": self.toolsets_web, "configured": True, "tools": ["web_extract", "web_search"]}]})

    async def handle(self, req):
        body = await req.json()
        self.requests.append(body)
        if not body.get("stream"):
            return web.json_response({"choices": [{"message": {"content": "Title"}, "finish_reason": "stop"}]})
        resp = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
        await resp.prepare(req)
        await resp.write(self.chunk({"content": "Let me look. "}))
        await resp.write(b'event: hermes.tool.progress\ndata: {"tool": "terminal", "emoji": "\\ud83d\\udcbb", "label": "df -h /mnt", '
                         b'"toolCallId": "call_1", "status": "running"}\n\n')
        if self.gate is not None:
            await self.gate.wait()
        await resp.write(b'event: hermes.tool.progress\ndata: {"tool": "terminal", "toolCallId": "call_1", "status": "completed"}\n\n')
        await resp.write(b'event: hermes.tool.progress\ndata: {"tool": "web_search", "emoji": "x", "label": "weather", '
                         b'"toolCallId": "call_2", "status": "running"}\n\n')
        await resp.write(self.chunk({"content": "Done: 412 GB free."}))
        await resp.write(self.chunk({}, "stop"))
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


class AttachmentTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        t = self.temp.name
        self.fake = FakeHermes()
        app = web.Application()
        app.router.add_post("/v1/chat/completions", self.fake.handle)
        app.router.add_get("/v1/toolsets", self.fake.toolsets)
        self.hermes = TestServer(app)
        await self.hermes.start_server()
        self.previous = dict(bridge.CFG)
        self.workspace = os.path.join(t, "hermes-uploads")
        bridge.CFG.update(live_key=KEY, hermes_key="fixture-hermes-key", chat_db=os.path.join(t, "chats.sqlite"), titles="simple",
                          hermes_url=str(self.hermes.make_url("/v1")), upload_dir=os.path.join(t, "uploads"),
                          hermes_upload_dir=self.workspace, hermes_upload_path="/opt/data/uploads", vision=True, uploads=True,
                          upload_image_mb=10, upload_file_mb=25, upload_conv_mb=200, upload_total_mb=2048, upload_max_items=4,
                          web_search="auto", ui_prompt_file=os.path.join(t, "hermes-ui-prompt.md"), ui_prompt_default="", openai_key="",
                          usage_file=os.path.join(t, "usage.json"), codex_home=os.path.join(t, "codex"), link_preview=True)
        bridge.TOOLSETS.update(web=None, checked=0.0)
        bridge.LINK_CACHE.clear()
        bridge.DIRECT["s"] = None
        self.client = TestClient(TestServer(bridge.make_app()))
        await self.client.start_server()
        self.store = bridge.CHAT["store"]

    async def asyncTearDown(self):
        if bridge.DIRECT["s"] is not None:
            await bridge.DIRECT["s"].close()
        await self.client.close()
        await self.hermes.close()
        bridge.CFG.clear()
        bridge.CFG.update(self.previous)
        bridge.CHAT["active"] = 0
        self.temp.cleanup()

    async def upload(self, data, name="photo.png", ctype="image/png", conversation_id=None, headers=AUTH):
        form = aiohttp.FormData()
        if conversation_id:
            form.add_field("conversation_id", conversation_id)
        form.add_field("file", data, filename=name, content_type=ctype)
        r = await self.client.post("/api/uploads", data=form, headers=headers)
        return r, await r.json() if r.content_type == "application/json" else None

    async def chat(self, headers=AUTH, **body):
        r = await self.client.post("/api/chat", json=body, headers=headers)
        return r, (await read_sse(r) if r.status == 200 else await r.json())

    # ---- uploads
    async def test_image_upload_get_preview_delete(self):
        r, up = await self.upload(png(1200, 800))
        self.assertEqual(r.status, 201, up)
        self.assertTrue(up["id"].startswith("up_") and bridge.valid_id(up["id"]))
        self.assertEqual((up["kind"], up["mime"], up["width"], up["height"], up["name"]), ("image", "image/png", 1200, 800, "photo.png"))
        self.assertEqual(up["preview_url"], "/api/uploads/%s/preview" % up["id"])
        blob = bridge.upload_blob(up["sha256"])
        self.assertEqual(stat.S_IMODE(os.stat(blob).st_mode), 0o600)
        got = await self.client.get("/api/uploads/" + up["id"], headers=AUTH)
        self.assertEqual((got.status, got.headers["Content-Type"], got.headers["ETag"]), (200, "image/png", '"%s"' % up["sha256"]))
        self.assertEqual(await got.read(), png(1200, 800))
        self.assertIn("sandbox", got.headers["Content-Security-Policy"])
        again = await self.client.get("/api/uploads/" + up["id"], headers={**AUTH, "If-None-Match": got.headers["ETag"]})
        self.assertEqual(again.status, 304)
        prev = await self.client.get(up["preview_url"], headers=AUTH)
        data = await prev.read()
        self.assertEqual((prev.status, prev.headers["Content-Type"], data[:3]), (200, "image/jpeg", b"\xff\xd8\xff"))
        self.assertEqual(bridge.image_size(data), (512, 340))
        self.assertEqual((await self.client.get("/api/uploads/" + up["id"])).status, 401)
        self.assertEqual((await self.client.delete("/api/uploads/" + up["id"], headers=AUTH)).status, 204)
        self.assertEqual((await self.client.get("/api/uploads/" + up["id"], headers=AUTH)).status, 404)
        self.assertFalse(os.path.exists(blob))

    async def test_upload_type_and_size_checks(self):
        r, body = await self.upload(b"\x7fELF\x02\x01\x01" + b"\x00" * 100, "tool.png", "image/png")
        self.assertEqual((r.status, body["code"]), (415, "unsupported_type"))
        r, body = await self.upload(b"#!/bin/sh\nrm -rf /\n", "notes.txt", "text/plain")
        self.assertEqual((r.status, body["code"]), (415, "unsupported_type"))
        r, body = await self.upload(b"\x89PNG\r\n\x1a\n" + b"garbage" * 10, "broken.png")
        self.assertEqual((r.status, body["code"]), (415, "unsupported_type"))
        r, body = await self.upload("# Notes\nhéllo".encode(), "notes.md", "text/markdown")
        self.assertEqual((r.status, body["mime"], body["kind"]), (201, "text/markdown", "file"))
        self.assertNotIn("preview_url", body)
        r, body = await self.upload(b'{"a": 1}', "data.json", "application/octet-stream")
        self.assertEqual(body["mime"], "application/json")
        r, body = await self.upload(office_zip(), "report.docx", "application/octet-stream")
        self.assertEqual((r.status, body["mime"]), (201, "application/vnd.openxmlformats-officedocument.wordprocessingml.document"))
        r, body = await self.upload(office_zip(["word/vbaProject.bin"]), "report.docx")
        self.assertEqual(r.status, 415)
        r, body = await self.upload(b"PK\x03\x04junk", "archive.zip", "application/zip")
        self.assertEqual(r.status, 415)
        r, body = await self.upload(io.BytesIO(b"line of text\n" * 240000), "log.txt", "text/plain")   # 3 MB: past the JSON cap
        self.assertEqual((r.status, body["size"]), (201, 13 * 240000))
        bridge.CFG["upload_file_mb"] = 1
        r, body = await self.upload(b"a" * (1024 * 1024 + 10), "big.txt", "text/plain")
        self.assertEqual((r.status, body["code"]), (413, "too_large"))
        bridge.CFG["upload_conv_mb"] = 1
        conv = self.store.create_conversation()
        r, body = await self.upload(b"b" * (700 * 1024), "a.txt", "text/plain", conversation_id=conv["id"])
        self.assertEqual(r.status, 201)
        r, body = await self.upload(b"c" * (700 * 1024), "b.txt", "text/plain", conversation_id=conv["id"])
        self.assertEqual((r.status, body["code"]), (507, "quota_exceeded"))
        r, body = await self.upload(b"x", "a.txt", "text/plain", conversation_id="missing")
        self.assertEqual((r.status, body["code"]), (404, "not_found"))
        r = await self.client.post("/api/uploads", data=b"not multipart", headers={**AUTH, "Content-Type": "text/plain"})
        self.assertEqual((r.status, (await r.json())["code"]), (400, "bad_upload"))
        # Without a Hermes workspace, documents are refused and capabilities list images only.
        bridge.CFG["hermes_upload_dir"] = ""
        r, body = await self.upload(b"plain text", "a.txt", "text/plain")
        self.assertEqual((r.status, body["code"]), (415, "unsupported_type"))
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertEqual(caps["attachment_limits"]["mimes"], ["image/jpeg", "image/png", "image/webp"])
        bridge.CFG["vision"] = False
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertEqual((caps["attachments"], caps["vision"]), (False, False))
        self.assertEqual((await self.upload(png()))[0].status, 503)

    async def test_names_are_sanitised(self):
        self.assertEqual(bridge.safe_name("../../etc/passwd"), "passwd")
        self.assertEqual(bridge.safe_name("..\\x\\.bashrc"), "bashrc")
        self.assertEqual(bridge.safe_name("\x00\x1f"), "file")
        self.assertEqual(bridge.workspace_name("install me.sh"), "install_me.sh.txt")
        self.assertEqual(bridge.workspace_name("Report (final).pdf"), "Report_(final).pdf")

    # ---- sending attachments
    async def test_chat_with_image_sends_content_parts_and_stores_attachments(self):
        r, up = await self.upload(png(), "IMG_1.png")
        r, events = await self.chat(message={"text": "", "attachments": [up["id"]]})
        self.assertEqual(r.status, 200, events)
        meta = events[0][1]
        last = self.fake.requests[-1]["messages"][-1]
        self.assertEqual(last["role"], "user")
        self.assertIsInstance(last["content"], list)
        self.assertEqual(last["content"][0]["type"], "text")
        self.assertIn("only the attached image", last["content"][0]["text"])
        self.assertEqual(last["content"][1]["type"], "image_url")
        self.assertTrue(last["content"][1]["image_url"]["url"].startswith("data:image/png;base64,iVBOR"))
        conv = await (await self.client.get("/api/conversations/" + meta["conversation_id"], headers=AUTH)).json()
        user = conv["messages"][0]
        self.assertEqual(user["attachments"], [{"id": up["id"], "name": "IMG_1.png", "mime": "image/png", "size": len(png()), "kind": "image",
                                                "width": 64, "height": 48, "preview_url": up["preview_url"]}])
        self.assertNotIn("attachments", user["meta"])
        self.assertEqual(conv["conversation"]["title"], "IMG_1.png")
        self.assertEqual((await self.client.delete("/api/uploads/" + up["id"], headers=AUTH)).status, 409)
        # The same upload cannot be sent again; a later turn carries a note instead of the image.
        r, body = await self.chat(conversation_id=meta["conversation_id"], message={"text": "again", "attachments": [up["id"]]})
        self.assertEqual((r.status, body["code"]), (400, "bad_attachment"))
        r, events = await self.chat(conversation_id=meta["conversation_id"], message={"text": "and now?"})
        first = self.fake.requests[-1]["messages"][0]
        self.assertIsInstance(first["content"], list)                     # still the newest user turn with an image
        r, up2 = await self.upload(png(rgb=(0, 0, 255)), "blue.png")
        r, events = await self.chat(conversation_id=meta["conversation_id"], message={"text": "this one", "attachments": [up2["id"]]})
        msgs = self.fake.requests[-1]["messages"]
        self.assertEqual(msgs[0]["content"], "[image: IMG_1.png, sent earlier in this chat]")
        self.assertIsInstance(msgs[-1]["content"], list)
        # Validation
        for bad in ([up2["id"]] * 2, ["nope"], "x", ["a"] * 5):
            with self.subTest(bad=bad):
                r, body = await self.chat(message={"text": "x", "attachments": bad})
                self.assertEqual((r.status, body["code"]), (400, "bad_attachment"))
        r, body = await self.chat(message={"text": "  "})
        self.assertEqual(body["code"], "empty_message")
        other = self.store.create_conversation()
        r, up3 = await self.upload(png(), conversation_id=other["id"])
        r, body = await self.chat(message={"text": "x", "attachments": [up3["id"]]})
        self.assertEqual(body["code"], "bad_attachment")                  # owned by another chat

    async def test_documents_go_to_hermes_workspace_and_leave_with_the_chat(self):
        os.makedirs(self.workspace)
        r, up = await self.upload(b"%PDF-1.7\n...", "Q3 report.pdf", "application/pdf")
        r, events = await self.chat(message={"text": "summarise", "attachments": [up["id"]]})
        cid = events[0][1]["conversation_id"]
        copy = os.path.join(self.workspace, cid, "Q3_report.pdf")
        self.assertEqual(Path(copy).read_bytes(), b"%PDF-1.7\n...")
        self.assertEqual(stat.S_IMODE(os.stat(copy).st_mode), 0o640)
        text = self.fake.requests[-1]["messages"][-1]["content"]
        self.assertEqual(text, "summarise\n\nThe user attached Q3 report.pdf (12 bytes, application/pdf) at /opt/data/uploads/%s/Q3_report.pdf." % cid)
        self.assertNotIn("PDF-1.7", json.dumps(self.fake.requests[-1]))  # bytes never go into the prompt
        blob = bridge.upload_blob(up["sha256"])
        self.assertEqual((await self.client.delete("/api/conversations/" + cid, headers=AUTH)).status, 200)
        self.assertFalse(os.path.exists(copy))
        self.assertFalse(os.path.exists(os.path.join(self.workspace, cid)))
        self.assertFalse(os.path.exists(blob))
        self.assertIsNone(self.store.upload(up["id"]))

    async def test_unused_uploads_expire(self):
        r, up = await self.upload(png())
        self.store.db.execute("UPDATE uploads SET created = ? WHERE id = ?", (bridge.now_ms() - 25 * 3600 * 1000, up["id"]))
        self.assertEqual(bridge.gc_uploads(self.store), 1)
        self.assertIsNone(self.store.upload(up["id"]))
        self.assertFalse(os.path.exists(bridge.upload_blob(up["sha256"])))
        self.assertFalse(os.path.exists(bridge.upload_preview_path(up["sha256"])))

    # ---- persisted tool calls
    async def test_tool_calls_are_saved_on_the_message_and_in_snapshots(self):
        r, events = await self.chat(message={"text": "disk?"})
        done = events[-1][1]
        msg = self.store.get_message(done["message_id"])
        tools = msg["meta"]["tools"]
        self.assertEqual([(t["id"], t["tool"], t["label"], t["state"], t["offset"]) for t in tools],
                         [("call_1", "terminal", "df -h /mnt", "done", len("Let me look. ")),
                          ("call_2", "web_search", "weather", "done", len("Let me look. "))])     # still running at the end: done
        self.assertTrue(all(t["ended"] >= t["started"] for t in tools))
        self.assertEqual(tools[0]["emoji"], "\U0001f4bb")
        # A resume that falls back to SQLite rebuilds the cards from the snapshot.
        bridge.CHAT["jobs"].clear()
        r = await self.client.get("/api/chat/%s/stream" % done["message_id"], headers=AUTH)
        snap = [d for e, d in await read_sse(r) if e == "snapshot"][0]
        self.assertEqual(snap["tools"], tools)

    def test_tool_list_is_capped(self):
        job = bridge.ChatJob.__new__(bridge.ChatJob)
        job.tools, job.tools_truncated, job.tools_dirty, job.parts = [], 0, False, []
        for i in range(70):
            job.track_tool({"state": "running", "id": "c%d" % i, "tool": "t", "label": "l", "emoji": ""})
        job.track_tool({"state": "failed", "id": "c69"})
        job.track_tool({"state": "approval", "label": "Hermes is waiting for an approval"})
        self.assertEqual((len(job.tools), job.tools_truncated), (64, 7))
        self.assertEqual((job.tools[-2]["state"], job.tools[-1]["state"], job.tools[-1]["id"]), ("failed", "approval", ""))

    # ---- live job progress
    async def test_running_live_job_shows_progress(self):
        async def fake_start(ds, offer, voice):
            return "v=0 answer"
        with mock.patch.object(bridge.DirectSession, "start", fake_start):
            sid = (await (await self.client.post("/api/session", json={"offer": "v=0 x"}, headers=AUTH)).json())["session"]
        self.fake.gate = asyncio.Event()
        jid = (await (await self.client.post("/api/delegate", json={"session": sid, "text": "check disk"}, headers=AUTH)).json())["job"]
        ds = bridge.DIRECT["s"]
        end = time.monotonic() + 3
        while time.monotonic() < end and not ds.jobs[jid].get("status_event"):
            await asyncio.sleep(0.02)
        job = await (await self.client.get("/api/job/%s/%s" % (sid, jid), headers=AUTH)).json()
        self.assertEqual(job["status"], "running")
        self.assertEqual((job["status_event"]["label"], job["status_event"]["tool"]), ("df -h /mnt", "terminal"))
        self.assertEqual(job["partial"], "Let me look. ")
        self.fake.gate.set()
        end = time.monotonic() + 3
        while time.monotonic() < end and ds.jobs[jid]["status"] == "running":
            await asyncio.sleep(0.02)
        job = await (await self.client.get("/api/job/%s/%s" % (sid, jid), headers=AUTH)).json()
        self.assertEqual((job["status"], job["markdown"]), ("done", "Let me look. Done: 412 GB free."))
        self.assertNotIn("partial", job)
        listed = await (await self.client.get("/api/session/%s/jobs" % sid, headers=AUTH)).json()
        self.assertEqual((listed["backend"], listed["jobs"][0]["request"]), ("codex", "check disk"))

    # ---- web search flag and the app's UI prompt
    async def test_web_search_flag(self):
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertIs(caps["web_search"], True)
        r, events = await self.chat(message={"text": "weather in Pune?"}, web_search=True)
        cid = events[0][1]["conversation_id"]
        self.assertTrue(self.fake.requests[-1]["messages"][-1]["content"].endswith(bridge.WEB_SEARCH_NOTE))
        user = self.store.messages(cid)[0][0]
        self.assertIs(user["meta"]["web_search"], True)
        r, events = await self.chat(conversation_id=cid, retry=True)
        self.assertTrue(self.fake.requests[-1]["messages"][-1]["content"].endswith(bridge.WEB_SEARCH_NOTE))
        first = self.fake.requests[-1]["messages"][0]
        r, events = await self.chat(conversation_id=cid, message={"text": "thanks"})
        self.assertNotIn(bridge.WEB_SEARCH_NOTE, self.fake.requests[-1]["messages"][-1]["content"])
        # Hermes derives its session id from the first user message: it reads the same on every turn (a changed one
        # opened a new Hermes session with a null stored system prompt at turn 2, QA 15 November 2026).
        self.assertEqual(self.fake.requests[-1]["messages"][0], first)
        r, events = await self.chat(conversation_id=cid, message={"text": "and tomorrow?"}, web_search=True)
        sent = self.fake.requests[-1]["messages"]
        self.assertEqual(sent[0], first)
        self.assertEqual([m["content"].endswith(bridge.WEB_SEARCH_NOTE) for m in sent if m["role"] == "user"],
                         [True, False, True])
        r, body = await self.chat(message={"text": "x"}, web_search="yes")
        self.assertEqual(body["code"], "bad_request")
        # Hermes without its web toolset: the capability is false and the flag adds nothing.
        self.fake.toolsets_web = False
        bridge.TOOLSETS.update(web=None, checked=0.0)
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertIs(caps["web_search"], False)
        r, events = await self.chat(message={"text": "news?"}, web_search=True)
        self.assertNotIn(bridge.WEB_SEARCH_NOTE, self.fake.requests[-1]["messages"][-1]["content"])

    async def test_ui_prompt_only_for_the_app(self):
        bridge.CFG["openui_prompt_file"] = "off"
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertIs(caps["ui_prompt"], False)
        Path(bridge.CFG["ui_prompt_file"]).write_text("You are shown in the Hermes app. Use markdown tables freely.\n")
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertEqual((caps["ui_prompt"], caps["ui_prompt_header"]), (True, "X-Hermes-UI"))
        await self.chat(message={"text": "hi"})
        self.assertNotEqual(self.fake.requests[-1]["messages"][0]["role"], "system")
        await self.chat(headers={**AUTH, "X-Hermes-UI": "1"}, message={"text": "hi"})
        first = self.fake.requests[-1]["messages"][0]
        self.assertEqual(first, {"role": "system", "content": "You are shown in the Hermes app. Use markdown tables freely."})
        self.assertEqual((caps["ui_blocks"], caps["ui_blocks_version"]), (True, 1))
        # The app's own flag: "ui": 1 in the body, on a send and on a retry. A boolean or 0 is not a version.
        r, events = await self.chat(message={"text": "hi"}, ui=1)
        self.assertEqual(self.fake.requests[-1]["messages"][0]["role"], "system")
        await self.chat(conversation_id=events[0][1]["conversation_id"], retry=True, ui=1)
        self.assertEqual(self.fake.requests[-1]["messages"][0]["role"], "system")
        for flag in (True, 0, "1"):
            await self.chat(message={"text": "hi"}, ui=flag)
            self.assertEqual(self.fake.requests[-1]["messages"][0]["role"], "user", flag)

    async def test_shipped_ui_prompt_is_the_default(self):
        bridge.CFG["ui_prompt_file"] = ""                     # unset: <data>/hermes-ui-prompt.md, else the shipped copy
        bridge.CFG["ui_prompt_default"] = os.path.join(self.temp.name, "absent.md")
        shipped = Path(bridge.UI_PROMPT_BUNDLED).read_text().strip()
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertEqual((caps["ui_prompt"], caps["ui_blocks"], caps["ui_blocks_version"]), (True, True, 1))
        await self.chat(message={"text": "hi"}, ui=1)
        # The OpenUI section (generated from the app's registry) follows the hermes-ui snippet.
        self.assertEqual(self.fake.requests[-1]["messages"][0], {"role": "system", "content": shipped + "\n\n" + Path(bridge.OPENUI_PROMPT_BUNDLED).read_text("utf-8").strip()})
        # The formatting rules the phone QA asked for, and a valid example block.
        self.assertIn("GitHub-flavoured pipe table", shipped)
        self.assertIn("| --- | --- |", shipped)
        self.assertIn('lines starting with "- "', shipped)
        self.assertIn("only when tapping or adjusting something helps", shipped)
        # Reply style (QA 15 November 2026: replies came back as plain paragraphs). Hermes' API platform hint says
        # "assume plain text, no markdown", so the app's prompt must say that does not apply here, and ask for
        # structure that adapts to the message instead of forcing headings on short replies.
        self.assertTrue(shipped.startswith("Rendering: this chat app shows GitHub-flavoured Markdown"))
        self.assertIn("does not apply here: format your replies with Markdown", shipped)
        self.assertIn("a list with a short bold label each", shipped)
        self.assertIn("No heading over a short answer", shipped)
        self.assertIn("quick one-fact question gets a sentence or two of plain text", shipped)
        example = shipped.split("```hermes-ui\n", 1)[1].split("\n```", 1)[0]
        block = json.loads(example)
        self.assertEqual((block["v"], block["type"], len(block["options"])), (1, "options", 2))
        self.assertIn("```hermes-artifact fence: the first line is a JSON header", shipped)   # round 6 B6
        # Round 7: HTML only for real layout or interaction; plain lists stay markdown (QA: bullets came back in HTML).
        self.assertIn("never wrap them in HTML", shipped)
        # OpenUI round (18 Nov): comparisons, itineraries, recipes and dashboards moved from hermes-html to openui.
        self.assertIn("use one openui fence", shipped)
        self.assertIn("hermes-html fence only for a layout openui cannot express", shipped)
        self.assertLess(len(shipped.split()), 1700)                    # round 7 html: 1,699; round 6 artifacts: 1,653 words; round 4 (1,455): a bare
        #   ui:1 chat measured 16,278 prompt tokens on 16 Nov, Hermes SOUL included (round 3: 14,386); keep it short
        Path(bridge.CFG["ui_prompt_default"]).write_text("operator copy")
        await self.chat(message={"text": "hi"}, ui=1)
        self.assertEqual(self.fake.requests[-1]["messages"][0]["content"].split("\n\n## Rich layouts: OpenUI")[0],
                         "operator copy")   # the data dir wins
        bridge.CFG["ui_prompt_file"] = "off"
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertEqual((caps["ui_prompt"], caps["ui_blocks"], caps["ui_blocks_version"]), (False, False, None))
        await self.chat(message={"text": "hi"}, ui=1)
        self.assertEqual(self.fake.requests[-1]["messages"][0]["role"], "user")

    async def test_ui_prompt_is_stable_across_turns_and_search(self):
        """Hermes derives its session id from the system prompt plus the first user message, so the app prompt must
        be byte-identical on every turn, with or without web search, on a retry and on a new chat."""
        Path(bridge.CFG["ui_prompt_file"]).write_text(Path(bridge.UI_PROMPT_BUNDLED).read_text())
        r, events = await self.chat(message={"text": "plan a trip"}, ui=1)
        cid = events[0][1]["conversation_id"]
        system = self.fake.requests[-1]["messages"][0]
        self.assertEqual(system["role"], "system")
        for extra in ({"message": {"text": "with sources"}, "web_search": True},
                      {"message": {"text": "and without"}, "web_search": False},
                      {"retry": True}):
            await self.chat(conversation_id=cid, ui=1, **extra)
            sent = self.fake.requests[-1]["messages"]
            self.assertEqual(sent[0], system, extra)
            self.assertEqual(sum(m["role"] == "system" for m in sent), 1, extra)
            self.assertNotIn(bridge.WEB_SEARCH_NOTE, sent[0]["content"])
        await self.chat(message={"text": "another chat"}, ui=1, web_search=True)
        self.assertEqual(self.fake.requests[-1]["messages"][0], system)

    # ---- link previews
    def test_link_url_checks(self):
        for url in ("http://127.0.0.1/", "http://10.0.0.5/", "http://192.168.1.10:8080/", "http://[::1]/", "http://169.254.169.254/latest",
                    "http://100.100.10.20/", "http://localhost/", "https://server.example-tailnet.ts.net/", "http://printer.local/",
                    "https://example.com:22/", "http://[::ffff:127.0.0.1]/", "http://0.0.0.0/"):
            with self.subTest(url=url), self.assertRaises(bridge.LinkBlocked):
                bridge.check_link_url(url)
        for url in ("ftp://example.com/", "javascript:alert(1)", "https://user:pw@example.com/", "https://", "x" * 10):
            with self.subTest(url=url), self.assertRaises(bridge.LinkBlocked):
                bridge.check_link_url(url)
        bridge.check_link_url("https://example.com/a?b=c")
        bridge.check_link_url("http://93.184.215.14:8080/")

    async def test_resolver_refuses_private_answers(self):
        loop = asyncio.get_running_loop()
        resolver = bridge.PublicResolver()

        async def fake_getaddrinfo(host, port, **kw):
            table = {"rebind.example": ["93.184.215.14", "127.0.0.1"], "ok.example": ["93.184.215.14"]}
            return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, port)) for ip in table[host]]
        with mock.patch.object(loop, "getaddrinfo", fake_getaddrinfo):
            with self.assertRaises(OSError):
                await resolver.resolve("rebind.example", 443)
            self.assertEqual([r["host"] for r in await resolver.resolve("ok.example", 443)], ["93.184.215.14"])

    async def test_link_preview_route(self):
        r = await self.client.get("/api/link-preview", params={"url": "http://127.0.0.1:%d/" % self.hermes.port}, headers=AUTH)
        self.assertEqual((r.status, (await r.json())["code"]), (400, "blocked_url"))
        r = await self.client.get("/api/link-preview", params={"url": "file:///etc/passwd"}, headers=AUTH)
        self.assertEqual((r.status, (await r.json())["code"]), (400, "bad_url"))
        self.assertEqual((await self.client.get("/api/link-preview", params={"url": "https://example.com/"})).status, 401)

        async def fake_build(url):
            return {"url": url, "title": "Example", "site_name": "example.com", "image": None, "favicon": None}
        with mock.patch.object(bridge, "build_link_preview", fake_build):
            r = await self.client.get("/api/link-preview", params={"url": "https://example.com/"}, headers=AUTH)
            self.assertEqual((r.status, (await r.json())["title"]), (200, "Example"))
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertEqual((caps["link_preview"], caps["link_preview_images"]), (True, True))
        bridge.CFG["link_preview"] = False
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertEqual((caps["link_preview"], caps["link_preview_images"]), (False, False))
        self.assertEqual((await self.client.get("/api/link-preview", params={"url": "https://example.com/"}, headers=AUTH)).status, 503)

    def test_open_graph_parsing_and_image_checks(self):
        p = bridge.OGParser()
        p.feed('<html><head><title> Fallback  title </title><meta property="og:title" content="Real &amp; title">'
               '<meta property="og:site_name" content="Site"><meta name="twitter:image" content="/t.png">'
               '<link rel="shortcut icon" href="/fav.png"></head></html>')
        self.assertEqual((p.meta["og:title"], p.meta["og:site_name"], p.meta["twitter:image"], p.icons, p.title.strip()),
                         ("Real & title", "Site", "/t.png", ["/fav.png"], "Fallback  title"))
        self.assertTrue(bridge.image_data_url("image/png", png()).startswith("data:image/png;base64,"))
        self.assertIsNone(bridge.image_data_url("image/png", b"<svg onload=alert(1)>"))
        self.assertIsNone(bridge.image_data_url("image/svg+xml", b"<svg/>"))
        self.assertIsNone(bridge.image_data_url("image/webp", b"RIFF1234WAVE"))


if __name__ == "__main__":
    unittest.main()
