#!/usr/bin/env python3
"""Answer-quality eval runner: sends each case in questions.json through a SCRATCH bridge to a real Hermes and saves
the replies.

The scratch bridge is started here, from the bridge script you name, on its own port and in its own temporary data
directory, so a production bridge (its chats, prompts, caches) is never touched. Hermes' address and key (and the
title/judge proxy settings) are read from an env file you name; nothing else
is copied from it. Places come from a places_fetch.py extract (--places-db); the places_search tool itself is a
Hermes plugin, so Hermes only uses it when hermes-places is installed there.

    python3 run_eval.py --bridge ../gpt-live-bridge.py --env /path/to/bridge.env --out runs/after
    python3 run_eval.py ... --only adhd,dentist --location "Mylapore, Chennai, IN@13.03,80.27"
    python3 run_eval.py ... --no-location

Stdlib only. Each case is one chat; its turns are sent in order. Output: <out>/results.json (text, timings, tools,
usage per turn) plus one markdown file per case.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import urllib.parse
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
# Only these are taken from the env file: Hermes and the model proxy (titles and the judge).
PASS_KEYS = ("HERMES_API_URL", "HERMES_API_KEY", "HERMES_MODEL", "HERMES_STANDARD_PROVIDER",
             "TITLE_API_URL", "TITLE_API_KEY", "TITLE_MODEL", "ASSISTANT_NAME")


def read_env(path):
    out = {}
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start_bridge(script, env_file, port, data_dir, places, places_db=""):
    src = read_env(env_file)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("BRIDGE_", "LIVE_", "HERMES_", "PLACES_", "TOVE_"))}
    env.update({k: src[k] for k in PASS_KEYS if src.get(k)})
    if places and places_db:
        env["PLACES_DB"] = places_db
    key = secrets.token_urlsafe(32)
    env.update({"BRIDGE_HOST": "127.0.0.1", "BRIDGE_PORT": str(port), "BRIDGE_DATA_DIR": data_dir, "LIVE_PAGE_KEY": key,
                "LIVE_TITLES": "simple", "PUSH_ENABLED": "false", "LIVE_UPLOADS": "false", "LIVE_MAX_CHATS": "2",
                "LIVE_BACKEND": "openai", "CODEX_HOME": os.path.join(data_dir, "codex-home")})
    log = open(os.path.join(data_dir, "bridge.log"), "w")
    script = os.path.abspath(script)
    proc = subprocess.Popen([sys.executable, script], env=env, stdout=log, stderr=subprocess.STDOUT,
                            cwd=os.path.dirname(os.path.abspath(script)))
    base = "http://127.0.0.1:%d" % port
    for _ in range(100):
        try:
            caps = get_json(base + "/api/capabilities", key)
            return proc, base, key, caps
        except (urllib.error.URLError, ConnectionError, OSError):
            if proc.poll() is not None:
                raise SystemExit("scratch bridge exited; see %s/bridge.log" % data_dir)
            time.sleep(0.2)
    proc.terminate()
    raise SystemExit("scratch bridge did not start")


def get_json(url, key):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + key})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())


def chat(base, key, body, timeout=900):
    """One /api/chat turn: (events summary). Reads the SSE stream to the end."""
    req = urllib.request.Request(base + "/api/chat", data=json.dumps(body).encode(), method="POST",
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    t0 = time.monotonic()
    first = None
    text, tools, meta, done, error = "", [], {}, None, None
    with urllib.request.urlopen(req, timeout=timeout) as r:
        event = None
        for raw in r:
            line = raw.decode("utf-8", "replace").rstrip("\n")
            if line.startswith("event: "):
                event = line[7:]
            elif line.startswith("data: "):
                data = json.loads(line[6:])
                if event == "meta":
                    meta = data
                elif event == "delta":
                    first = first or time.monotonic() - t0
                    text += data.get("text", "")
                elif event == "snapshot":
                    text = data.get("text", text)
                elif event == "status" and data.get("state") == "running":
                    tools.append(data.get("tool") or data.get("label"))
                elif event == "done":
                    done = data
                elif event in ("error", "stopped"):
                    error = data
    return {"text": text, "first_token_s": round(first or 0, 2), "total_s": round(time.monotonic() - t0, 2),
            "tools": [t for t in tools if t], "usage": (done or {}).get("usage"), "error": error,
            "conversation_id": meta.get("conversation_id")}


def place_infos(base, key, text):
    """/api/places/info for each place: id in a reply (for the renders); {} when none or unavailable."""
    out = {}
    for pid in dict.fromkeys(re.findall(r'"(place:[A-Za-z0-9_-]{8,64})"', text)):
        try:
            out[pid] = get_json(base + "/api/places/info?id=" + urllib.parse.quote(pid), key)
        except (urllib.error.URLError, OSError, ValueError):
            pass
    return out


def parse_location(value):
    label, _, coords = value.partition("@")
    lat, _, lng = coords.partition(",")
    return {"label": label.strip(), "lat": float(lat), "lng": float(lng)} if coords else {"label": label.strip()}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--bridge", required=True, help="the gpt-live-bridge.py to run (its prompts are used)")
    ap.add_argument("--env", required=True, help="env file with HERMES_API_URL and HERMES_API_KEY")
    ap.add_argument("--out", required=True)
    ap.add_argument("--questions", default=str(HERE / "questions.json"))
    ap.add_argument("--only", default="", help="comma-separated case ids")
    ap.add_argument("--ui", type=int, default=2)
    ap.add_argument("--effort", default="medium")
    ap.add_argument("--location", default="", help='"Label@lat,lng"; default: the questions file\'s sample location')
    ap.add_argument("--no-location", action="store_true", help="send no location (as a bridge without it)")
    ap.add_argument("--no-places", action="store_true", help="no places database for the scratch bridge")
    ap.add_argument("--places-db", default="", help="a places_fetch.py extract for the scratch bridge (PLACES_DB)")
    ap.add_argument("--pause", type=float, default=8.0, help="seconds between cases (spares the search engines)")
    ap.add_argument("--keep-data", action="store_true")
    args = ap.parse_args()

    qs = json.loads(Path(args.questions).read_text())
    cases = qs["cases"]
    if args.only:
        wanted = set(args.only.split(","))
        cases = [c for c in cases if c["id"] in wanted]
    location = None if args.no_location else (parse_location(args.location) if args.location else qs.get("default_location"))
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    data_dir = tempfile.mkdtemp(prefix="tove-eval-bridge-")
    os.chmod(data_dir, 0o700)
    port = free_port()
    proc, base, key, caps = start_bridge(args.bridge, args.env, port, data_dir, not args.no_places, args.places_db)
    print("scratch bridge on %s (data %s); places: %s" % (base, data_dir, caps.get("places")), flush=True)
    results = {"started": time.strftime("%Y-%m-%d %H:%M:%S"), "bridge": str(args.bridge), "ui": args.ui,
               "effort": args.effort, "location": location, "places": caps.get("places"),
               "location_capability": caps.get("location"), "cases": []}
    try:
        for n, case in enumerate(cases):
            if n:
                time.sleep(args.pause)
            turns, cid = [], None
            for text in case["turns"]:
                body = {"message": {"text": text}, "ui": args.ui, "effort": args.effort}
                if cid:
                    body["conversation_id"] = cid
                if location:
                    body["location"] = location
                try:
                    r = chat(base, key, body)
                except Exception as exc:                       # keep going; the judge scores a failure as such
                    r = {"text": "", "error": {"code": type(exc).__name__}, "total_s": 0, "first_token_s": 0, "tools": []}
                cid = r.get("conversation_id") or cid
                r["places"] = place_infos(base, key, r.get("text") or "")
                turns.append({"user": text, **r})
                print("%-20s %6.1fs tools=%d chars=%d%s" % (case["id"], r["total_s"], len(r["tools"]), len(r["text"]),
                                                            " ERROR %s" % r["error"] if r.get("error") else ""), flush=True)
            results["cases"].append({"id": case["id"], "intent": case["intent"], "turns": turns})
            md = ["# %s (%s)\n" % (case["id"], case["intent"])]
            for t in turns:
                md.append("## User\n\n%s\n\n## Tove (%.1f s, tools: %s)\n\n%s\n" % (t["user"], t["total_s"], ", ".join(t["tools"]) or "none", t["text"]))
            (out / ("%s.md" % case["id"])).write_text("\n".join(md))
            (out / "results.json").write_text(json.dumps(results, indent=1, ensure_ascii=False))
    finally:
        proc.terminate()
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()
        shutil.copy(os.path.join(data_dir, "bridge.log"), out / "bridge.log")
        if not args.keep_data:
            shutil.rmtree(data_dir, ignore_errors=True)
    print("saved %s" % (out / "results.json"))


if __name__ == "__main__":
    main()
