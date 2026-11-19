"""OpenUI chat library as the only rich format (UI prompt version 2): "ui": 2 clients get markdown rules plus the
generated OpenUI section, "ui": 1 clients keep the round-9 prompt, live-call tasks follow the app that started the
call, the voice reader speaks openui fences, and the structural check knows the chat library. No network.
  ~/.local/share/gpt-live-bridge/venv/bin/python -m unittest test_openui_chat
"""
import os
import re
import unittest
from pathlib import Path

import test_attachments as ta
from test_attachments import AUTH

bridge = ta.bridge
HERE = Path(__file__).parent

LEGACY_FORMATS = ("hermes-ui", "hermes-html", "hermes-artifact")


def shipped(name):
    return (HERE / name).read_text("utf-8").strip()


class ShippedPromptTest(unittest.TestCase):
    def test_v2_teaches_only_openui(self):
        md, oui = shipped("markdown-prompt.md"), shipped("openui-chat-prompt.md")
        for fmt in LEGACY_FORMATS:
            self.assertNotIn(fmt, md + oui, fmt)
        self.assertIn("root = Card([", oui)
        for name in ("CardHeader", "TextContent", "Callout", "Table", "Col", "BarChart", "Form", "FormControl",
                     "Buttons", "ListBlock", "FollowUpBlock", "Tabs", "TabItem", "Steps", "StepsItem", "TagBlock",
                     "EntityList", "CompositeCardBlock", "VisualCardBlock", "OverviewCardBlock", "Email", "Artifact",
                     "Checklist", "Entities", "News", "Status", "Services", "Gauges"):
            self.assertRegex(oui, r"(?m)^%s\(" % name)
        # Still the markdown rules the phone QA asked for.
        self.assertTrue(md.startswith("Rendering: this chat app shows GitHub-flavoured Markdown"))
        self.assertIn("| --- | --- |", md)
        self.assertIn("entity:", md)

    def test_v2_stays_within_budget(self):
        # 18 Nov: 14,553 characters. 19 Nov: answer playbooks and the Places/Map/Quiz components, budgeted at about
        # +1,500 tokens (~6,000 characters); keep the whole v2 prompt under 21,000 characters.
        v2 = len(shipped("markdown-prompt.md")) + len(shipped("openui-chat-prompt.md"))
        self.assertLess(v2, 21000, v2)
        self.assertLess(len(shipped("openui-chat-prompt.md")), 14000)

    def test_example_is_valid(self):
        bridge.CFG.update(openui_chat_prompt_file=str(HERE / "openui-chat-prompt.md"))
        bridge.OPENUI_CHAT_PROMPT.update(key=None, text="")
        oui = shipped("openui-chat-prompt.md")
        example = oui.split("```openui\n", 1)[1].split("\n```", 1)[0]
        self.assertEqual(bridge.openui_issues("```openui\n" + example + "\n```"), [])


class VersionTest(unittest.IsolatedAsyncioTestCase):
    chat = ta.AttachmentTest.chat
    asyncTearDown = ta.AttachmentTest.asyncTearDown

    async def asyncSetUp(self):
        await ta.AttachmentTest.asyncSetUp(self)
        t = self.temp.name
        for name, text in (("hermes-ui-prompt.md", "V1 rules."), ("openui1.md", "## Rich layouts: OpenUI\nStack(children)"),
                           ("md.md", "Markdown rules."), ("oui.md", "## Rich answers: OpenUI\nCard(children: Node[])")):
            Path(t, name).write_text(text)
        bridge.CFG.update(openui_prompt_file=os.path.join(t, "openui1.md"), markdown_prompt_file=os.path.join(t, "md.md"),
                          openui_chat_prompt_file=os.path.join(t, "oui.md"))
        for cache in (bridge.UI_PROMPT, bridge.OPENUI_PROMPT, bridge.MARKDOWN_PROMPT, bridge.OPENUI_CHAT_PROMPT):
            cache.update(key=None, text="")

    def system(self):
        m = self.fake.requests[-1]["messages"][0]
        return m["content"] if m["role"] == "system" else None

    async def test_version_picks_the_prompt(self):
        await self.chat(message={"text": "hi"}, ui=1)
        self.assertEqual(self.system(), "V1 rules.\n\n## Rich layouts: OpenUI\nStack(children)")
        await self.chat(message={"text": "hi"}, ui=2)
        self.assertEqual(self.system(), "Markdown rules.\n\n## Rich answers: OpenUI\nCard(children: Node[])")
        await self.chat(message={"text": "hi"}, ui=7)                 # newer apps get the newest prompt
        self.assertTrue(self.system().startswith("Markdown rules."))
        await self.chat(message={"text": "hi"}, headers={**AUTH, bridge.UI_HEADER: "1"})
        self.assertTrue(self.system().startswith("V1 rules."))
        await self.chat(message={"text": "hi"})
        self.assertIsNone(self.system())
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertEqual(caps["ui_prompt_versions"], [1, 2])

    async def test_v2_falls_back_without_its_files(self):
        bridge.CFG["openui_chat_prompt_file"] = "off"
        await self.chat(message={"text": "hi"}, ui=2)
        self.assertTrue(self.system().startswith("V1 rules."))
        caps = await (await self.client.get("/api/capabilities", headers=AUTH)).json()
        self.assertEqual(caps["ui_prompt_versions"], [1])

    async def test_task_follows_the_calling_app(self):
        ds = bridge.DirectSession()
        self.assertTrue(ds.task_context("x")[0]["content"].startswith("V1 rules."))
        ds.ui = 2
        self.assertTrue(ds.task_context("x")[0]["content"].startswith("Markdown rules."))

    async def test_session_records_the_version(self):
        class Req:
            headers = {}
        self.assertEqual(bridge.ui_version(Req, {"ui": 2}), 2)
        self.assertEqual(bridge.ui_version(Req, {"ui": True}), 0)
        self.assertEqual(bridge.ui_version(Req, {}), 0)


class VoiceAndCheckTest(unittest.TestCase):
    PROGRAM = (
        'Here is the plan.\n\n```openui\nroot = Card([head, tabs, more])\n'
        'head = CardHeader("Goa in 3 days", "Beaches and food")\n'
        'tabs = Tabs([TabItem("day1", "Day 1", [Steps([StepsItem("Baga Beach", "Swim at 10 am")])])])\n'
        'pic = ImageTextLarge("entity:Baga_Beach", "Baga", "Baga Beach")\n'
        'more = FollowUpBlock([FollowUpItem("Add a budget")])\n```\n'
    )

    def setUp(self):
        self.previous = dict(bridge.CFG)
        bridge.CFG.update(openui_chat_prompt_file=str(HERE / "openui-chat-prompt.md"),
                          openui_prompt_file=str(HERE / "openui-prompt.md"))
        bridge.OPENUI_CHAT_PROMPT.update(key=None, text="")
        bridge.OPENUI_PROMPT.update(key=None, text="")

    def tearDown(self):
        bridge.CFG.clear()
        bridge.CFG.update(self.previous)

    def test_voice_reads_labels_not_settings(self):
        said = bridge.plain_for_voice(self.PROGRAM)
        for words in ("Goa in 3 days", "Day 1", "Baga Beach", "Swim at 10 am"):
            self.assertIn(words, said)
        for noise in ("day1", "entity:", "openui", "root", "Card(", "code block omitted"):
            self.assertNotIn(noise, said)

    def test_check_knows_the_chat_library(self):
        issues = bridge.openui_issues(self.PROGRAM)
        self.assertEqual(issues, ["openui#1: unused statements pic"])
        untaught = '```openui\nroot = Card([RadarChart(["a", "b", "c"], [Series("x", [1, 2, 3])])])\n```'
        self.assertEqual(bridge.openui_issues(untaught), [])
        self.assertTrue(any("Hologram" in i for i in bridge.openui_issues('```openui\nroot = Card([Hologram("x")])\n```')))
        # Round-9 programs (Tove's first names) still pass while old chats exist.
        self.assertEqual(bridge.openui_issues('```openui\nroot = Stack([Title("Hi")])\n```'), [])

    def test_untaught_list_matches_the_app(self):
        lib = (HERE.parent / "app/lib/src/ui/openui/library.dart").read_text("utf-8")
        block = lib.split("const Set<String> _untaught = {", 1)[1].split("};", 1)[0]
        app = set(re.findall(r"'(\w+)'", block))
        self.assertLessEqual(app, bridge.OPENUI_UNTAUGHT)


if __name__ == "__main__":
    unittest.main()
