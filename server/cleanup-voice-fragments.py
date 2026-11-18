#!/usr/bin/env python3
"""One-off cleanup: fold the voice-turn fragments that older app builds saved into one message per spoken turn.

Before 16 November 2026 the app saved the first transcript piece of almost every live-call turn as a message of its
own ("Alright, bye", then "Alright, bye for now."). This tool applies the bridge's own merge_voice_turns() to the
saved chats: consecutive voice messages of one call (same meta.session, nothing else in between) are folded the way
the bridge now folds them on import. The first message of each turn is kept (its id, client_id and time) with the
merged text; the others are deleted.

Dry run by default: it only prints counts (no message text unless --show). --apply first copies the database with
SQLite's backup API to --backup-dir, then changes everything in one transaction.

  python cleanup-voice-fragments.py --db <data>/chats.sqlite
  ... --apply --backup-dir ~/bridge-backup-$(date +%Y%m%d-%H%M%S)
"""
import argparse
import importlib.util
import json
import os
import sqlite3
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load_bridge():
    spec = importlib.util.spec_from_file_location("bridge_cleanup", HERE / "gpt-live-bridge.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _session(meta_json):
    try:
        meta = json.loads(meta_json or "{}")
    except ValueError:
        return None
    return meta.get("session") if isinstance(meta, dict) else None


def plan(db, merge):
    """[(conversation_id, before, after, updates {id: text}, deletes [id])] for every chat that changes."""
    out, conv, run, run_session = [], None, [], None
    changes = {}

    def flush():
        if len(run) < 2:
            return
        merged, folded = merge([{"role": r["role"], "text": r["text"], "created": r["created"], "id": r["id"]} for r in run])
        if not folded:
            return
        keep = {g["id"]: g["text"] for g in merged}
        c = changes.setdefault(run[0]["conversation_id"], {"before": 0, "after": 0, "updates": {}, "deletes": [], "folded": {}})
        c["before"] += len(run)
        c["after"] += len(merged)
        for r in run:
            if r["id"] not in keep:
                c["deletes"].append(r["id"])
            elif keep[r["id"]] != r["text"]:
                c["updates"][r["id"]] = keep[r["id"]]
        ids = [r["id"] for r in run]
        for g in merged:                                  # how many saved messages each kept one stands for
            start = ids.index(g["id"])
            nxt = [ids.index(h["id"]) for h in merged if ids.index(h["id"]) > start]
            c["folded"][g["id"]] = (min(nxt) if nxt else len(ids)) - start

    rows = db.execute("SELECT seq, id, conversation_id, role, text, source, created, meta_json FROM messages "
                      "ORDER BY conversation_id, created, seq").fetchall()
    for r in rows:
        if r["conversation_id"] != conv:
            flush()
            conv, run, run_session = r["conversation_id"], [], None
        session = _session(r["meta_json"]) if r["source"] == "voice" else None
        if r["source"] == "voice" and session and run and session == run_session:
            run.append(r)
            continue
        flush()
        run, run_session = ([r], session) if r["source"] == "voice" and session else ([], None)
    flush()
    for cid, c in changes.items():
        out.append((cid, c["before"], c["after"], c["updates"], c["deletes"], c["folded"]))
    return out


def apply(db, changes):
    db.execute("BEGIN IMMEDIATE")
    try:
        for _cid, _before, _after, updates, deletes, folded in changes:
            for mid, text in updates.items():
                db.execute("UPDATE messages SET text = ? WHERE id = ?", (text, mid))
            for mid, n in folded.items():
                if n > 1:
                    row = db.execute("SELECT meta_json FROM messages WHERE id = ?", (mid,)).fetchone()
                    meta = json.loads(row["meta_json"] or "{}") if row else {}
                    meta["voice_merged"] = n
                    db.execute("UPDATE messages SET meta_json = ? WHERE id = ?", (json.dumps(meta, ensure_ascii=False), mid))
            db.executemany("DELETE FROM messages WHERE id = ?", [(m,) for m in deletes])
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise


def backup(db, folder):
    os.makedirs(folder, mode=0o700, exist_ok=True)
    target = os.path.join(folder, "chats.sqlite")
    dst = sqlite3.connect(target)
    with dst:
        db.backup(dst)
    dst.close()
    os.chmod(target, 0o600)
    return target


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--db", required=True, help="the bridge's chats.sqlite")
    ap.add_argument("--apply", action="store_true", help="change the database (default: dry run)")
    ap.add_argument("--backup-dir", help="where --apply copies the database first (required with --apply)")
    ap.add_argument("--show", action="store_true", help="also print the merged texts (private chat content)")
    args = ap.parse_args(argv)
    if args.apply and not args.backup_dir:
        ap.error("--apply needs --backup-dir")
    bridge = load_bridge()
    db = sqlite3.connect(args.db, isolation_level=None)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA busy_timeout=5000")
    changes = plan(db, bridge.merge_voice_turns)
    voice = db.execute("SELECT count(*) FROM messages WHERE source = 'voice'").fetchone()[0]
    chats = db.execute("SELECT count(DISTINCT conversation_id) FROM messages WHERE source = 'voice'").fetchone()[0]
    before = sum(c[1] for c in changes)
    after = sum(c[2] for c in changes)
    print("%s: %d voice messages in %d chats" % ("APPLY" if args.apply else "DRY RUN", voice, chats))
    print("chats to change: %d; voice messages in affected runs: %d -> %d (%d deleted, %d rewritten)"
          % (len(changes), before, after, sum(len(c[4]) for c in changes), sum(len(c[3]) for c in changes)))
    for cid, b, a, updates, deletes, _folded in changes:
        print("  %s  %d -> %d" % (cid, b, a))
        if args.show:
            for mid, text in updates.items():
                print("      %s: %s" % (mid, text[:160]))
    if args.apply and changes:
        print("backup:", backup(db, os.path.expanduser(args.backup_dir)))
        apply(db, changes)
        print("applied; voice messages now: %d" % db.execute("SELECT count(*) FROM messages WHERE source = 'voice'").fetchone()[0])
    db.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
