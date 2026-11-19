#!/usr/bin/env python3
"""LLM judge for run_eval.py results: scores each case 1-10 on five criteria against its reference rubric.

The judge is any OpenAI-compatible chat endpoint; by default the one the bridge uses for titles (TITLE_API_URL and
TITLE_API_KEY from the env file, e.g. a local CLIProxyAPI), with JUDGE_MODEL or --model.

    python3 judge.py --env /path/to/bridge.env runs/before runs/after      # scores each run, prints a table

Writes <run>/scores.json. Stdlib only.
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
CRITERIA = ("usefulness", "accuracy", "structure", "presentation", "actionability", "speed")

SYSTEM = """You grade answers from a chat assistant called Tove, comparing them with what the best ChatGPT answer would contain.
The app renders Markdown and ```openui fences natively: an openui fence becomes real interactive UI (cards with photos, maps
with pins, tappable buttons that send a message, one-question-at-a-time quizzes, tables, charts, checklists). Judge the fence
by what it would display, not by its syntax. "entity:Title" image URLs become real Wikipedia photos. Footnotes become a
sources list. The user's approximate location may have been known to the assistant.

Score each criterion from 1 (bad) to 10 (better than the reference):
- usefulness: does it actually solve the user's need, with the substance the rubric lists?
- accuracy: are facts, numbers, names, places and sources plausible and verifiable? Penalise invented details, missing
  citations where facts need them, and stale information. Do not reward confident unsourced specifics.
- structure: is the shape right for the intent (cards, maps, tables, quizzes, pictures where they help; plain text for a
  quick fact); no padding.
- presentation: how it would look on a phone: layout, visual hierarchy (lead, headings, bold key facts), visuals,
  scannability; no walls of text, cramped lists or repeated disclaimers.
- actionability: concrete next steps the user can tap or do (call, directions, book, start a test, buttons), rather than
  ending with a bare question that could have been avoided.
- speed: given the time taken and the depth required (quick facts should be under ~5 s; deep research under ~60 s is good).

Answer with JSON only: {"usefulness": n, "accuracy": n, "structure": n, "presentation": n, "actionability": n, "speed": n,
"overall": n, "rationale": "two or three short sentences"}. overall is your holistic score, not necessarily the mean."""


def read_env(path):
    out = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def ask(url, key, model, prompt, tries=3):
    body = {"model": model, "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": prompt}]}
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url.rstrip("/") + "/chat/completions", data=json.dumps(body).encode(),
                                         headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=240) as r:
                text = json.loads(r.read())["choices"][0]["message"]["content"]
            m = re.search(r"\{.*\}", text, re.S)
            data = json.loads(m.group(0))
            if all(isinstance(data.get(c), (int, float)) for c in CRITERIA + ("overall",)):
                return data
        except Exception as exc:                                   # retry on proxy hiccups and malformed JSON
            print("judge retry (%s)" % type(exc).__name__, file=sys.stderr)
            time.sleep(3 * (attempt + 1))
    return None


def case_prompt(case, rubric, location):
    parts = ["Reference rubric (what a top answer contains):\n" + rubric]
    if location:
        parts.append("The app shared the user's approximate location with the assistant: %s." % location.get("label"))
    for i, t in enumerate(case["turns"], 1):
        tools = ", ".join(t.get("tools") or []) or "none"
        parts.append("--- Turn %d. User: %s\n(time %.1f s, tools used: %s%s)\nAssistant reply:\n%s" % (
            i, t["user"], t.get("total_s") or 0, tools, ", ERROR %s" % t["error"] if t.get("error") else "",
            (t.get("text") or "(empty)")[:24000]))
    parts.append("Grade the whole exchange.")
    return "\n\n".join(parts)


def judge_run(run, url, key, model, rubrics, force=False):
    res = json.loads((run / "results.json").read_text())
    path = run / "scores.json"
    scores = json.loads(path.read_text()) if path.exists() and not force else {}
    for case in res["cases"]:
        if case["id"] in scores:
            continue
        s = ask(url, key, model, case_prompt(case, rubrics.get(case["id"], ""), res.get("location")))
        if s is None:
            print("no score for %s" % case["id"], file=sys.stderr)
            continue
        s.update(intent=case["intent"], seconds=round(sum(t.get("total_s") or 0 for t in case["turns"]), 1))
        scores[case["id"]] = s
        path.write_text(json.dumps(scores, indent=1, ensure_ascii=False))
        print("%-20s %s  %s" % (case["id"], s["overall"], s["rationale"][:110]), flush=True)
    return scores


def table(runs):
    """Markdown table: averages per intent for each run, plus the ADHD case."""
    names = [r.name for r, _ in runs]
    intents = sorted({s["intent"] for _, sc in runs for s in sc.values()})
    lines = ["| Intent | " + " | ".join(names) + " |", "|---" * (len(names) + 1) + "|"]

    def avg(sc, pred, field="overall"):
        vals = [s[field] for k, s in sc.items() if pred(k, s)]
        return "%.1f" % statistics.mean(vals) if vals else "–"
    for intent in intents:
        lines.append("| %s | %s |" % (intent, " | ".join(avg(sc, lambda k, s: s["intent"] == intent) for _, sc in runs)))
    lines.append("| **all (overall)** | %s |" % " | ".join(avg(sc, lambda k, s: True) for _, sc in runs))
    for c in CRITERIA:
        lines.append("| all: %s | %s |" % (c, " | ".join(avg(sc, lambda k, s: True, c) for _, sc in runs)))
    lines.append("| ADHD (2 turns) | %s |" % " | ".join(avg(sc, lambda k, s: k == "adhd") for _, sc in runs))
    lines.append("| median seconds | %s |" % " | ".join(
        "%.0f" % statistics.median([s["seconds"] for s in sc.values()]) if sc else "–" for _, sc in runs))
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--env", required=True, help="env file with TITLE_API_URL / TITLE_API_KEY (the model proxy)")
    ap.add_argument("--model", default="")
    ap.add_argument("--questions", default=str(HERE / "questions.json"))
    ap.add_argument("--force", action="store_true", help="re-score cases that already have a score")
    args = ap.parse_args()
    env = read_env(args.env)
    url, key = env.get("TITLE_API_URL", "http://127.0.0.1:8317/v1"), env.get("TITLE_API_KEY", "")
    model = args.model or env.get("JUDGE_MODEL") or "gpt-6.2-sol"
    rubrics = {c["id"]: c["rubric"] for c in json.loads(Path(args.questions).read_text())["cases"]}
    runs = [(Path(r), judge_run(Path(r), url, key, model, rubrics, args.force)) for r in args.runs]
    print("\nJudge: %s\n" % model)
    print(table(runs))


if __name__ == "__main__":
    main()
