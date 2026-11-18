"""OpenUI: the prompt section is appended to the UI prompt (hot reload), `entity:` pictures inside ```openui fences are
filled in, and finished replies get a structural check for the log. No network.
  ~/.local/share/gpt-live-bridge/venv/bin/python -m unittest test_openui
"""
import os
import tempfile
import time
import unittest

import test_round9 as r9
from test_round9 import UP, bridge

HERE = os.path.dirname(os.path.abspath(__file__))


class PromptTest(unittest.TestCase):
    def setUp(self):
        self.previous = dict(bridge.CFG)
        self.temp = tempfile.TemporaryDirectory()
        self.ui = os.path.join(self.temp.name, "ui.md")
        self.oui = os.path.join(self.temp.name, "openui.md")
        with open(self.ui, "w") as f:
            f.write("UI rules.")
        bridge.CFG.update(ui_prompt_file=self.ui, openui_prompt_file=self.oui)
        bridge.UI_PROMPT.update(key=None, text="")
        bridge.OPENUI_PROMPT.update(key=None, text="")

    def tearDown(self):
        bridge.CFG.clear()
        bridge.CFG.update(self.previous)
        self.temp.cleanup()

    def test_appended_and_hot_reloaded(self):
        self.assertEqual(bridge.ui_prompt(), "UI rules.")              # no OpenUI file yet
        with open(self.oui, "w") as f:
            f.write("## Rich layouts: OpenUI\nStack(children: Node[]) – root\n")
        self.assertEqual(bridge.ui_prompt(), "UI rules.\n\n## Rich layouts: OpenUI\nStack(children: Node[]) – root")
        time.sleep(0.01)
        with open(self.oui, "w") as f:
            f.write("Card(children: Node[])\n")
        os.utime(self.oui, (time.time() + 5, time.time() + 5))
        self.assertTrue(bridge.ui_prompt().endswith("Card(children: Node[])"))
        bridge.CFG["openui_prompt_file"] = "off"
        self.assertEqual(bridge.ui_prompt(), "UI rules.")

    def test_shipped_prompt_is_small_and_beside_the_script(self):
        with open(os.path.join(HERE, "openui-prompt.md"), encoding="utf-8") as f:
            text = f.read()
        self.assertLess(len(text), 10000)                             # ~2.3k tokens; the TS demo prompt is ~35k chars
        self.assertIn("```openui", text)
        self.assertIn("Stack(", text)

    def test_issues(self):
        bridge.CFG["openui_prompt_file"] = os.path.join(HERE, "openui-prompt.md")
        good = '```openui\nroot = Stack([t, c])\nt = Title("Hi")\nc = Card([Text("x")], "Box")\n```'
        self.assertEqual(bridge.openui_issues("Intro.\n\n" + good), [])
        bad = ('```openui\nmain = Stack([Hologram("x"), t]\nt = Title("Q(uoted) [text")\nlost = Text("y")\n'
               'q = Query("tickets", {}, {})\n```')
        issues = bridge.openui_issues(bad)
        self.assertTrue(any("no root" in i for i in issues), issues)
        self.assertTrue(any("Hologram" in i for i in issues), issues)
        self.assertTrue(any("Query/Mutation" in i for i in issues), issues)
        self.assertTrue(any("unbalanced" in i for i in issues), issues)
        self.assertTrue(any("lost" in i for i in issues), issues)
        self.assertTrue(any("not closed" in i for i in bridge.openui_issues("```openui\nroot = Stack([])")))


class OpenUiPicturesTest(r9.Base):
    async def test_entity_strings_in_openui_become_pictures(self):
        text = ('Two towers.\n\n```openui\nroot = Stack([Grid([a, b])])\n'
                'a = Card([Text("Paris")], "Eiffel Tower", "entity:Eiffel_Tower")\n'
                'b = Card([Text("?")], "Nowhere", "entity:Lost_Media_Thing")\n```\n')
        pics = bridge.ReplyPictures("")
        pics.scan(text)
        out, shown = await pics.finish(text)
        self.assertIn('"Eiffel Tower", "%sa/a1/Eiffel.jpg")' % UP, out)
        self.assertIn('"Nowhere", null)', out)                       # unknown: no picture, the card still renders
        self.assertIn(UP + "a/a1/Eiffel.jpg", shown)
        self.assertTrue(out.startswith("Two towers.\n\n```openui\n") and out.rstrip().endswith("```"))

    async def test_entity_text_outside_openui_untouched(self):
        text = 'Say "entity:Eiffel_Tower" literally.'
        pics = bridge.ReplyPictures("")
        pics.scan(text)
        out, _ = await pics.finish(text)
        self.assertEqual(out, text)


if __name__ == "__main__":
    unittest.main()
