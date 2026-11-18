#!/usr/bin/env python3
"""Publish a built Flutter web client/APK beside the existing private voice API.

Example: deploy-app.py --web-dir ../app/build/web --apk ../app/build/app/outputs/flutter-apk/app-release.apk
Run as the existing bridge user. Nothing is published if a bridge secret from
bridge.env appears in any build file; only the variable name and file are reported.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import zipfile

SECRET_NAMES = ("LIVE_PAGE_KEY", "BRIDGE_API_KEY", "HERMES_API_KEY", "TOVE_NOTIFY_KEY")
TOOLS = Path(os.environ.get("HERMES_BUILD_TOOLS", "~/.local/share/hermes-build-tools")).expanduser()


def bridge_secrets(destination):
    found = {}
    env = destination / "bridge.env"
    if env.is_file():
        for line in env.read_text().splitlines():
            name, _, value = line.partition("=")
            value = value.strip().strip("'\"")
            if name.strip() in SECRET_NAMES and len(value) >= 12:
                found[name.strip()] = value.encode()
    return found


def leaked(blobs, secrets):
    """Yield (label, secret name) for each blob that contains a secret value."""
    for label, data in blobs:
        for name, value in secrets.items():
            if value in data:
                yield label, name


def web_blobs(root):
    for path in sorted(root.rglob("*")):
        if path.is_file():
            yield str(path.relative_to(root)), path.read_bytes()


def apk_blobs(apk):
    with zipfile.ZipFile(apk) as archive:
        for info in archive.infolist():
            if not info.is_dir():
                yield info.filename, archive.read(info)


def check_web(web_dir):
    index = web_dir / "index.html"
    if not index.is_file():
        return "--web-dir must contain the completed web build's index.html"
    if not re.search(r'<base\s+href="/app/"', index.read_text(errors="replace")):
        return 'the web build must be compiled with --base-href /app/'
    links = [p for p in web_dir.rglob("*") if p.is_symlink()]
    if links:
        return "the web build contains symlinks (%s); refusing to follow them" % links[0].relative_to(web_dir)
    return check_fallback_fonts(web_dir)


def check_fallback_fonts(web_dir):
    """A build whose bootstrap points the engine at fonts/fallback/ must ship the complete set.

    Otherwise emoji and non-Latin text would silently render as boxes (the CSP blocks the font CDN).
    """
    boot = web_dir / "flutter_bootstrap.js"
    if not boot.is_file() or "fonts/fallback/" not in boot.read_text(errors="replace"):
        return None
    fonts = web_dir / "fonts" / "fallback"
    try:
        listed = json.loads((fonts / "manifest.json").read_text())["files"]
    except (OSError, ValueError, KeyError, TypeError):
        return "the web build has no fonts/fallback/manifest.json; run apps/hermes_live/tool/web_fallback_fonts.py"
    bad = [name for name, entry in sorted(listed.items())
           if not (fonts / name).is_file() or (fonts / name).stat().st_size != entry.get("bytes")]
    if not listed or bad:
        return "the web build's fallback fonts are incomplete (%s); rerun web_fallback_fonts.py" % (
            bad[0] if bad else "empty manifest")
    return None


def build_tool(name):
    tools = sorted((TOOLS / "android-sdk" / "build-tools").glob("*/" + name))
    return tools[-1] if tools else None


def check_apk(apk, allow_debug):
    if not zipfile.is_zipfile(apk):
        return "--apk is not an Android package"
    with zipfile.ZipFile(apk) as archive:
        names = set(archive.namelist())
    if not {"AndroidManifest.xml", "classes.dex"} <= names:
        return "--apk is missing AndroidManifest.xml or classes.dex"
    aapt2, apksigner = build_tool("aapt2"), build_tool("apksigner")
    if not aapt2 or not apksigner:
        return "aapt2/apksigner not found under %s; cannot verify the package" % TOOLS
    env = dict(os.environ)
    jdk = TOOLS / "sysroot/usr/lib/jvm/java-17-openjdk-amd64"
    if "JAVA_HOME" not in env and jdk.is_dir():
        env["JAVA_HOME"] = str(jdk)
        env["PATH"] = str(jdk / "bin") + os.pathsep + env.get("PATH", "")
    signed = subprocess.run([str(apksigner), "verify", str(apk)], env=env, capture_output=True, text=True)
    if signed.returncode != 0:
        return "apksigner rejected the package: " + (signed.stderr or signed.stdout).strip()[:300]
    manifest = subprocess.run([str(aapt2), "dump", "xmltree", "--file", "AndroidManifest.xml", str(apk)],
                              capture_output=True, text=True)
    if manifest.returncode != 0:
        return "aapt2 could not read the manifest"
    debuggable = re.search(r":debuggable\(0x0101000f\)=(?:\(type [^)]*\))?(\S+)", manifest.stdout)
    if debuggable and debuggable.group(1).lower() not in ("false", "0x0", "0") and not allow_debug:
        return "the package is debuggable; publish a release build or pass --allow-debug"
    return None


def prune(releases, keep, current):
    for partial in releases.glob("*.partial"):
        shutil.rmtree(partial)                          # interrupted copies were never published
    olds = sorted((p for p in releases.iterdir() if p.is_dir() and p.name.isdigit()), key=lambda p: int(p.name))
    for old in olds[:-keep]:
        if old.resolve() != current:
            shutil.rmtree(old)


def publish_file(source, destination):
    staged = destination.with_name(destination.name + ".new")
    shutil.copy2(source, staged)
    staged.chmod(0o644)
    os.replace(staged, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--web-dir", type=Path)
    parser.add_argument("--apk", type=Path)
    parser.add_argument("--destination", type=Path,
                        default=Path(os.environ.get("BRIDGE_DATA_DIR", "~/.local/share/gpt-live-bridge")).expanduser(),
                        help="the bridge data directory (default $BRIDGE_DATA_DIR or ~/.local/share/gpt-live-bridge)")
    parser.add_argument("--keep", type=int, default=3, help="web releases to keep (default 3)")
    parser.add_argument("--allow-debug", action="store_true", help="permit publishing a debuggable APK")
    args = parser.parse_args()
    if not args.web_dir and not args.apk:
        parser.error("provide --web-dir and/or --apk")
    if args.keep < 1:
        parser.error("--keep must be at least 1")
    if not args.destination.is_dir():
        parser.error("--destination must be the existing bridge data directory")
    current = args.destination / "web"
    if args.web_dir:
        if current.exists() and not current.is_symlink():
            parser.error("existing web directory is not a managed release symlink; preserve it before deploying")
        problem = check_web(args.web_dir)
        if problem:
            parser.error(problem)
    if args.apk:
        if not args.apk.is_file():
            parser.error("--apk must point to a built Android package")
        problem = check_apk(args.apk, args.allow_debug)
        if problem:
            parser.error(problem)

    secrets = bridge_secrets(args.destination)
    blobs = []
    if args.web_dir:
        blobs.append(web_blobs(args.web_dir))
    if args.apk:
        blobs.append(apk_blobs(args.apk))
    for source in blobs:
        for label, name in leaked(source, secrets):
            raise SystemExit("refusing to publish: %s contains the value of %s" % (label, name))

    if args.web_dir:
        # Complete a versioned directory before swapping the public symlink.
        # In-flight asset requests can still finish against the prior release.
        releases = args.destination / "web-releases"
        releases.mkdir(exist_ok=True)
        name = str(time.time_ns())
        staging = releases / (name + ".partial")
        shutil.copytree(args.web_dir, staging, ignore=shutil.ignore_patterns(".*"))
        release = releases / name
        staging.rename(release)
        link = args.destination / "web.new"
        if link.is_symlink():
            link.unlink()                               # left over from an interrupted deploy
        link.symlink_to(release.relative_to(args.destination), target_is_directory=True)
        os.replace(link, current)
        prune(releases, args.keep, release.resolve())
        print("Flutter web build published as release " + name)
    if args.apk:
        publish_file(args.apk, args.destination / "hermes-live.apk")
        print("Android package published")


if __name__ == "__main__":
    main()
