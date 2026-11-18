#!/usr/bin/env python3
"""Self-host the Flutter web engine's fallback fonts beside a web build.

The CanvasKit renderer downloads a Noto font (emoji, CJK, Arabic, Devanagari,
symbols, ...) the first time it has to draw a glyph that the bundled Roboto does
not cover. By default it fetches them from https://fonts.gstatic.com/s/, which
the /app/ CSP blocks (connect-src 'self'), so emoji and non-Latin transcripts
rendered as boxes. `web/flutter_bootstrap.js` points `fontFallbackBaseUrl` at
`fonts/fallback/` instead, and this script fills that directory.

The font list is read from the compiled `main.dart.js`, so the copy always
matches exactly what this build can request (728 files for Flutter 3.50). The
browser only downloads the files it needs for the text on screen.

Files are cached outside the repo in ~/.cache/hermes-live/web-fallback-fonts/.
Paths on the font CDN are versioned and never change content, so a cached file
is reused as is. The cache is filled from the CDN once (`--fetch`); building
offline from a filled cache needs no network. No user data is sent: requests
carry only the public font path and a generic user agent.

  python3 -I tool/web_fallback_fonts.py --web-dir build/web --fetch
  python3 -I tool/web_fallback_fonts.py --web-dir build/web --check

Exit status is non-zero if any font is missing, invalid or does not match the
build, so a release never ships with a partial set.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import urllib.request

CDN = "https://fonts.gstatic.com/s/"
DEST = Path("fonts") / "fallback"
CACHE = Path(os.environ.get("XDG_CACHE_HOME", "~/.cache")).expanduser() / "hermes-live" / "web-fallback-fonts"
# Strict shape of an engine fallback path, e.g.
# notocoloremoji/v39/Yq6P-KqIXTD0t4D9z1ESnKM3-HpFabsE4tq3luCC7p-aXxcn.0.woff2
PATH_RE = re.compile(r'"([a-z0-9]+/v[0-9]+/[A-Za-z0-9_-]+(?:\.[0-9]+)?\.(?:woff2|ttf|otf))"')
MAGIC = (b"wOF2", b"\x00\x01\x00\x00", b"OTTO", b"true")
MAX_BYTES = 16 * 1024 * 1024
LICENSE = """\
Fonts in this directory are unmodified copies of the fallback fonts that the
Flutter web engine (CanvasKit) loads for characters the bundled Roboto font does
not cover: Noto Sans/Serif families, Noto Color Emoji, and Roboto itself. They
are mirrored from https://fonts.gstatic.com/s/ at the same relative paths so the
app does not need a third-party font CDN.

Noto fonts and Noto Color Emoji: Copyright Google LLC and the Noto Project
Authors, licensed under the SIL Open Font License, Version 1.1
(https://openfontlicense.org/). Roboto: Copyright Google LLC, licensed under the
SIL Open Font License, Version 1.1 (see assets/fonts/Roboto_LICENSE.txt).
"""


def build_paths(web_dir):
    main_js = web_dir / "main.dart.js"
    if not main_js.is_file():
        raise SystemExit("%s has no main.dart.js; build the web app first" % web_dir)
    paths = sorted(set(PATH_RE.findall(main_js.read_text(errors="replace"))))
    if not paths:
        raise SystemExit("main.dart.js lists no fallback fonts; the engine may have changed")
    for p in paths:
        if ".." in p.split("/"):
            raise SystemExit("unexpected font path " + p)
    return paths


def valid(data):
    return 0 < len(data) <= MAX_BYTES and data[:4] in MAGIC


def fetch(path, cache):
    target = cache / path
    if target.is_file() and valid(target.read_bytes()):
        return path, "cached"
    req = urllib.request.Request(CDN + path, headers={"User-Agent": "font-mirror/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = resp.read(MAX_BYTES + 1)
    if not valid(data):
        raise ValueError("%s is not a font file" % path)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(target.name + ".part")
    tmp.write_bytes(data)
    os.replace(tmp, target)
    return path, "downloaded"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--web-dir", type=Path, required=True, help="completed `flutter build web` output")
    ap.add_argument("--cache", type=Path, default=CACHE)
    ap.add_argument("--fetch", action="store_true", help="download fonts missing from the cache")
    ap.add_argument("--check", action="store_true", help="only verify the copy in --web-dir")
    args = ap.parse_args()
    web_dir = args.web_dir.resolve()
    paths = build_paths(web_dir)
    out = web_dir / DEST

    if args.check:
        manifest = out / "manifest.json"
        if not manifest.is_file():
            raise SystemExit("no %s; run without --check first" % manifest.relative_to(web_dir))
        listed = json.loads(manifest.read_text())["files"]
        problems = [p for p in paths if p not in listed]
        for p, entry in listed.items():
            f = out / p
            if not f.is_file() or hashlib.sha256(f.read_bytes()).hexdigest() != entry["sha256"]:
                problems.append(p)
        if problems:
            raise SystemExit("%d fallback fonts missing or changed, e.g. %s" % (len(problems), problems[0]))
        total = sum(e["bytes"] for e in listed.values())
        print("ok: %d fallback fonts, %.1f MB, match main.dart.js" % (len(listed), total / 1e6))
        return

    missing = [p for p in paths if not (args.cache / p).is_file()]
    if missing and not args.fetch:
        raise SystemExit("%d of %d fonts are not cached in %s; rerun with --fetch"
                         % (len(missing), len(paths), args.cache))
    counts = {"cached": 0, "downloaded": 0}
    failures = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for fut in concurrent.futures.as_completed([pool.submit(fetch, p, args.cache) for p in paths]):
            try:
                counts[fut.result()[1]] += 1
            except Exception as e:  # report every failure, then stop
                failures.append(str(e)[:200])
    if failures:
        raise SystemExit("%d fonts failed, e.g. %s" % (len(failures), failures[0]))

    if out.exists():
        shutil.rmtree(out)
    files = {}
    for p in paths:
        data = (args.cache / p).read_bytes()
        if not valid(data):
            raise SystemExit("cached %s is not a font file; delete it and rerun with --fetch" % p)
        dest = out / p
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        files[p] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    (out / "LICENSE.txt").write_text(LICENSE)
    (out / "manifest.json").write_text(json.dumps({"source": CDN, "files": files}, indent=1, sort_keys=True))
    total = sum(e["bytes"] for e in files.values())
    print("fallback fonts: %d files (%d from cache, %d downloaded), %.1f MB in %s"
          % (len(files), counts["cached"], counts["downloaded"], total / 1e6, out.relative_to(web_dir)))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
