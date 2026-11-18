#!/usr/bin/env python3
"""Reproducible Tove builds with an evidence report that holds no secrets.

  build_release.py web          [--checks]  flutter build web + self-hosted fallback fonts
  build_release.py apk-debug    [--checks]  debuggable APK for adb-reverse device QA (never published)
  build_release.py apk-release  [--checks]  signed, non-debuggable APK for GitHub Releases

`--checks` runs `flutter analyze` and `flutter test` first and stops on failure.

Every build uses the shared toolchain in ~/.local/share/hermes-build-tools
($TOVE_BUILD_TOOLS) and its Gradle home, whose gradle.properties caps the daemon at 1536 MB and two
workers (it overrides the project's larger default on this 7 GB host). APK builds run Gradle on JDK 21
or newer, which AGP's release lint needs: $TOVE_JDK if set, else the newest such JDK under the
toolchain's sysroot*/usr/lib/jvm/. Flutter gets a private copy of the user's settings with jdk-dir
set to that JDK (a global jdk-dir outranks JAVA_HOME), and the JDK Flutter resolves is checked before
the build starts.

The evidence report goes to ~/.local/state/hermes-live-qa/builds/ ($TOVE_QA_STATE;
mode 0600, outside the repo): toolchain versions, git revision and whether the app tree
was dirty, output sizes and SHA-256 digests, and for APKs the package, version,
SDK levels, debuggable flag and the signer's public certificate digest. Each
output is scanned for the values of the bridge secrets; the report names only
the variable when one is found, never the value, and the build then fails.

Signing material is read by Gradle (android/app/build.gradle.kts) from outside
the repo. This script only locates key.properties ($TOVE_KEY_PROPERTIES, then the
legacy $HERMES_LIVE_KEY_PROPERTIES, android/key.properties, then a per-user fallback
outside the repo, DEFAULT_KEY_PROPERTIES below), hands that path to Gradle and
records which source was used; it never reads or prints the contents. A release APK signed with the
Android debug certificate, or still debuggable, is refused.

apk-release also prepares a GitHub release (app/README.md "Releasing"): it copies the APK to
build/release/tove-X.Y.Z.apk (the name the in-app update check prefers), writes a release-notes stub
build/release/notes-vX.Y.Z+N.md (kept if it already exists, so edits survive a rebuild) and prints
the `gh release create` command for the tag vX.Y.Z+N. It never runs gh. The build is refused when
kAppVersion in lib/src/app.dart differs from the pubspec version.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import zipfile

APP = Path(__file__).resolve().parent.parent


def setting(*names, default):
    """First non-empty environment variable among names (new name first, legacy after), else default."""
    for name in names:
        value = os.environ.get(name, "").strip()
        if value:
            return value
    return default


TOOLS = Path(setting("TOVE_BUILD_TOOLS", "HERMES_BUILD_TOOLS", default="~/.local/share/hermes-build-tools")).expanduser()
SDK = TOOLS / "android-sdk"
JDK_MAJOR = 21   # AGP 9's lint (lintVitalAnalyzeRelease) calls Java 21 APIs; JDK 17 crashes it
FLUTTER = Path(setting("TOVE_FLUTTER", default=str(TOOLS / "flutter/bin/flutter"))).expanduser()
BRIDGE_ENV = Path(setting("TOVE_BRIDGE_ENV", "BRIDGE_ENV", default="~/.local/share/gpt-live-bridge/bridge.env")).expanduser()
SECRET_NAMES = ("LIVE_PAGE_KEY", "BRIDGE_API_KEY", "HERMES_API_KEY", "TOVE_NOTIFY_KEY")
STATE = Path(setting("TOVE_QA_STATE", "HERMES_QA_STATE", default="~/.local/state/hermes-live-qa")).expanduser() / "builds"
PACKAGE = setting("TOVE_PACKAGE", default="io.github.tovechat.tove")
RELEASE_REPO = "itskavin/tove"   # GitHub Releases; keep equal to kReleaseRepo in lib/src/update/update_check.dart
RELEASE_DIR = APP / "build/release"
DEFAULT_KEY_PROPERTIES = Path("~/.config/tove/key.properties").expanduser()


def jdk_major(home):
    """Major version from a JDK's release file (JAVA_VERSION="21.0.13" -> 21), else its Debian directory
    name (java-21-openjdk-amd64), else None."""
    try:
        m = re.search(r'^JAVA_VERSION="(\d+)', (home / "release").read_text(), re.M)
    except OSError:
        m = None
    m = m or re.match(r"java-(\d+)-", home.name)
    return int(m.group(1)) if m else None


def find_jdk():
    """$TOVE_JDK if set, else the newest JDK >= JDK_MAJOR in the toolchain's sysroots (sysroot*/usr/lib/jvm/*)."""
    chosen = setting("TOVE_JDK", default="")
    if chosen:
        return Path(chosen).expanduser()
    homes = [java.parent.parent for java in TOOLS.glob("sysroot*/usr/lib/jvm/*/bin/java")]
    found = sorted((jdk_major(h), h) for h in homes if (jdk_major(h) or 0) >= JDK_MAJOR)
    return found[-1][1] if found else None


JDK = find_jdk()
FLUTTER_CONFIG = None   # private Flutter settings dir, set by scope_flutter_config() for APK builds


def require_jdk():
    """Stop before Gradle starts when the JDK cannot run AGP's lint, instead of failing minutes into the build."""
    major = jdk_major(JDK) if JDK else None
    if major and major >= JDK_MAJOR and (JDK / "bin/java").is_file():
        return {"java_home": str(JDK), "java_major": major}
    where = ("$TOVE_JDK=%s" % JDK) if setting("TOVE_JDK", default="") else ("%s/sysroot*/usr/lib/jvm/" % TOOLS)
    raise SystemExit("Android builds need JDK %d or newer (found %s at %s). Install one into the toolchain, e.g. "
                     "%s/sysroot-jdk21/usr/lib/jvm/java-21-openjdk-amd64, or point TOVE_JDK at a JDK %d home."
                     % (JDK_MAJOR, "JDK %d" % major if major else "none", where, TOOLS, JDK_MAJOR))


def user_flutter_settings():
    """The settings file Flutter reads on Linux: legacy ~/.flutter_settings, else $XDG_CONFIG_HOME/settings,
    else ~/.config/flutter/settings (flutter_tools base/config.dart)."""
    legacy = Path("~/.flutter_settings").expanduser()
    if legacy.is_file():
        return legacy
    xdg = os.environ.get("XDG_CONFIG_HOME")
    return Path(xdg) / "settings" if xdg else Path("~/.config/flutter/settings").expanduser()


def scope_flutter_config():
    """Give this build's Flutter a private copy of the user's settings with jdk-dir set to JDK.

    Flutter's jdk-dir setting outranks JAVA_HOME when it picks the JDK it hands to Gradle, so a global
    `flutter config --jdk-dir` pointing at JDK 17 would otherwise win. The user's file is left untouched."""
    global FLUTTER_CONFIG
    try:
        values = json.loads(user_flutter_settings().read_text() or "{}")
    except (OSError, ValueError):
        values = {}
    values["jdk-dir"] = str(JDK)
    FLUTTER_CONFIG = STATE.parent / "flutter-config"
    FLUTTER_CONFIG.mkdir(parents=True, exist_ok=True, mode=0o700)
    (FLUTTER_CONFIG / "settings").write_text(json.dumps(values, indent=2) + "\n")
    machine = run([FLUTTER, "config", "--machine"], capture=True)
    used = json.loads(machine[machine.find("{"):]).get("jdk-dir")
    if not used or Path(used).resolve() != JDK.resolve():
        raise SystemExit("Flutter would build with the JDK at %s, not %s. Remove jdk-dir from %s (or set TOVE_JDK "
                         "to that JDK if it is %d or newer)." % (used, JDK, user_flutter_settings(), JDK_MAJOR))
    for props in (TOOLS / "gradle/gradle.properties", APP / "android/gradle.properties"):
        pinned = re.search(r"^\s*org\.gradle\.java\.home\s*=\s*(.+?)\s*$",
                           props.read_text() if props.is_file() else "", re.M)
        if pinned and Path(pinned.group(1)).expanduser().resolve() != JDK.resolve():
            raise SystemExit("%s sets org.gradle.java.home=%s, which overrides %s for the Gradle daemon."
                             % (props, pinned.group(1), JDK))
    return used


def key_properties():
    """(source, path) of the release key.properties in Gradle's order, or (None, None). Never opens the file."""
    for name in ("TOVE_KEY_PROPERTIES", "HERMES_LIVE_KEY_PROPERTIES"):
        value = os.environ.get(name, "").strip()
        if value and Path(value).expanduser().is_file():
            return "$" + name, Path(value).expanduser()
    for source, path in (("android/key.properties", APP / "android/key.properties"),
                         ("default location", DEFAULT_KEY_PROPERTIES)):
        if path.is_file():
            return source, path
    return None, None

def env():
    e = dict(os.environ)
    e["PATH"] = os.pathsep.join(([str(JDK / "bin")] if JDK else []) + [
        str(TOOLS / "flutter/bin"), str(TOOLS / "sysroot/usr/bin"), str(SDK / "platform-tools"), e.get("PATH", "")])
    if JDK:
        e["JAVA_HOME"] = str(JDK)
    if FLUTTER_CONFIG:
        e["XDG_CONFIG_HOME"] = str(FLUTTER_CONFIG)   # Flutter reads $XDG_CONFIG_HOME/settings
    e.update(ANDROID_HOME=str(SDK), ANDROID_SDK_ROOT=str(SDK), GRADLE_USER_HOME=str(TOOLS / "gradle"))
    _, props = key_properties()
    if props:
        e["TOVE_KEY_PROPERTIES"] = str(props)   # the same file Gradle would pick; passed as a path only
    return e


def run(cmd, capture=False):
    print("+ " + " ".join(str(c) for c in cmd), flush=True)
    r = subprocess.run([str(c) for c in cmd], cwd=APP, env=env(), text=True,
                       capture_output=capture)
    if r.returncode != 0:
        if capture:
            sys.stderr.write((r.stdout + r.stderr)[-3000:])
        raise SystemExit("failed (%d): %s" % (r.returncode, cmd[0] if len(cmd) < 2 else " ".join(map(str, cmd[:3]))))
    return r.stdout if capture else ""


def build_tool(name):
    found = sorted((SDK / "build-tools").glob("*/" + name))
    if not found:
        raise SystemExit("%s not found under %s" % (name, SDK / "build-tools"))
    return found[-1]


def secret_values():
    values = {}
    try:
        lines = BRIDGE_ENV.read_text().splitlines()
    except OSError:
        print("note: %s is not readable, so outputs are not scanned for bridge secrets "
              "(set TOVE_BRIDGE_ENV)" % BRIDGE_ENV, file=sys.stderr)
        return values
    for line in lines:
        name, _, value = line.partition("=")
        value = value.strip().strip("'\"")
        if name.strip() in SECRET_NAMES and len(value) >= 12:
            values[name.strip()] = value.encode()
    return values


def scan(blobs):
    """Return [(file, variable)] for every blob holding a secret value. Values never leave this function."""
    values = secret_values()
    return [(label, name) for label, data in blobs for name, v in values.items() if v in data], sorted(values)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git_state():
    def git(*a):
        r = subprocess.run(["git", *a], cwd=APP, capture_output=True, text=True)
        return r.stdout.strip() if r.returncode == 0 else None
    status = git("status", "--porcelain", "--", ".")
    return {"head": git("rev-parse", "HEAD"),
            "app_tree": "clean" if status == "" else "dirty or untracked (%d paths)" % len((status or "").splitlines())}


def toolchain():
    version = json.loads(run([FLUTTER, "--version", "--machine"], capture=True) or "{}")
    return {"flutter": version.get("frameworkVersion"), "dart": version.get("dartSdkVersion"),
            "engine": version.get("engineRevision"),
            "android_build_tools": build_tool("aapt2").parent.name if (SDK / "build-tools").is_dir() else None}


def checks():
    run([FLUTTER, "pub", "get"])
    run([FLUTTER, "analyze"])
    run([FLUTTER, "test"])
    return {"analyze": "no issues", "test": "all passed"}


def build_web():
    # --no-wasm-dry-run: the dry run only reports wasm compatibility (output is
    # unchanged) but needs ~2 GB and many minutes on this host.
    run([FLUTTER, "build", "web", "--release", "--base-href", "/app/", "--no-web-resources-cdn",
         "--no-wasm-dry-run"])
    web = APP / "build/web"
    fonts = [sys.executable, "-I", APP / "tool/web_fallback_fonts.py", "--web-dir", web]
    run(fonts + ["--fetch"])
    font_check = run(fonts + ["--check"], capture=True).strip()
    files = [p for p in sorted(web.rglob("*")) if p.is_file()]
    leaks, scanned = scan((str(p.relative_to(web)), p.read_bytes()) for p in files)
    base = re.search(r'<base\s+href="([^"]*)"', (web / "index.html").read_text())
    return {"output": str(web), "files": len(files), "bytes": sum(p.stat().st_size for p in files),
            "base_href": base.group(1) if base else None, "main.dart.js_sha256": sha256(web / "main.dart.js"),
            "fallback_fonts": font_check, "secret_scan": {"variables_checked": scanned,
                                                          "found_in": [f"{n} in {f}" for f, n in leaks]}}


def apk_facts(apk):
    badging = run([build_tool("aapt2"), "dump", "badging", apk], capture=True)
    pkg = re.search(r"package: name='([^']+)' versionCode='([^']*)' versionName='([^']*)'", badging)
    sdk = re.search(r"sdkVersion:'(\d+)'", badging)
    target = re.search(r"targetSdkVersion:'(\d+)'", badging)
    tree = run([build_tool("aapt2"), "dump", "xmltree", "--file", "AndroidManifest.xml", apk], capture=True)
    dbg = re.search(r":debuggable\(0x0101000f\)=(?:\(type [^)]*\))?(\S+)", tree)
    debuggable = bool(dbg) and dbg.group(1).lower() not in ("false", "0x0", "0")
    certs = run([build_tool("apksigner"), "verify", "--verbose", "--print-certs", apk], capture=True)
    schemes = sorted(set(re.findall(r"Verified using (v[\d.]+) scheme[^:]*: true", certs)))
    signer = re.search(r"Signer #1 certificate SHA-256 digest: (\S+)", certs)
    dn = re.search(r"Signer #1 certificate DN: (.+)", certs)
    perms = sorted(set(re.findall(r"uses-permission: name='([^']+)'", badging)))
    with zipfile.ZipFile(apk) as z:
        leaks, scanned = scan((i.filename, z.read(i)) for i in z.infolist() if not i.is_dir())
    return {"output": str(apk), "bytes": apk.stat().st_size, "sha256": sha256(apk),
            "package": pkg.group(1) if pkg else None, "versionCode": pkg.group(2) if pkg else None,
            "versionName": pkg.group(3) if pkg else None, "minSdk": sdk.group(1) if sdk else None,
            "targetSdk": target.group(1) if target else None, "debuggable": debuggable,
            "apksigner": "verified (%s)" % ", ".join(schemes), "signer_sha256": signer.group(1) if signer else None,
            "signer_is_android_debug": bool(dn and "CN=Android Debug" in dn.group(1)), "permissions": perms,
            "secret_scan": {"variables_checked": scanned, "found_in": [f"{n} in {f}" for f, n in leaks]}}


def build_apk(release):
    mode = "--release" if release else "--debug"
    run([FLUTTER, "build", "apk", mode])
    apk = APP / "build/app/outputs/flutter-apk" / ("app-release.apk" if release else "app-debug.apk")
    facts = apk_facts(apk)
    if release:
        facts["signing_source"] = key_properties()[0] or "none"
    problems = []
    if facts["package"] != PACKAGE:
        problems.append("package is %s, expected %s" % (facts["package"], PACKAGE))
    if release and facts["debuggable"]:
        problems.append("release APK is debuggable")
    if release and facts["signer_is_android_debug"]:
        problems.append("release APK is signed with the Android debug certificate")
    if not release and not facts["debuggable"]:
        problems.append("debug APK is not debuggable (unexpected build type)")
    facts["problems"] = problems
    return facts


def pubspec_version():
    """version: 1.2.3+N from pubspec.yaml, and kAppVersion from lib/src/app.dart (they must match)."""
    pub = re.search(r"^version:\s*(\S+)", (APP / "pubspec.yaml").read_text(), re.M)
    const = re.search(r"^const kAppVersion = '([^']+)';", (APP / "lib/src/app.dart").read_text(), re.M)
    return (pub.group(1) if pub else None), (const.group(1) if const else None)


def release_tag(version_name, version_code):
    return "v%s+%s" % (version_name, version_code)


def notes_stub(apk_name, digest):
    """The release body; the app shows it in its update dialog, so plain Markdown only (no HTML comments)."""
    return """## What's new

- TODO: one line per change people will notice.

## Install or update

Download `{apk}` below and open it. If Android asks, allow your browser to install apps. Updating keeps
your chats and settings. Tove also checks for new releases once a day (Settings › About › Updates).

SHA-256 of `{apk}`: `{digest}`
""".format(apk=apk_name, digest=digest)


def prepare_release(facts):
    """Copy the APK to build/release/tove-X.Y.Z.apk, write the notes stub, return the gh command."""
    name, code = facts["versionName"], facts["versionCode"]
    tag = release_tag(name, code)
    RELEASE_DIR.mkdir(parents=True, exist_ok=True)
    apk = RELEASE_DIR / ("tove-%s.apk" % name)
    shutil.copyfile(facts["output"], apk)
    notes = RELEASE_DIR / ("notes-%s.md" % tag)
    kept = notes.is_file()
    if not kept:
        notes.write_text(notes_stub(apk.name, facts["sha256"]))
    cmd = ["gh", "release", "create", tag, str(apk), "--repo", RELEASE_REPO, "--verify-tag",
           "--title", "Tove %s" % name, "--notes-file", str(notes)]
    return {"tag": tag, "apk": str(apk), "notes": str(notes), "notes_kept": kept,
            "tag_commands": ["git tag -a %s -m %s" % (tag, shlex.quote("Tove %s" % name)),
                             "git push origin %s" % tag],
            "gh_command": " ".join(shlex.quote(c) for c in cmd)}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target", choices=["web", "apk-debug", "apk-release"])
    ap.add_argument("--checks", action="store_true", help="run flutter analyze and flutter test first")
    args = ap.parse_args()
    if args.target == "apk-release":
        pub, const = pubspec_version()
        if not pub or pub != const:
            raise SystemExit("pubspec version %s and kAppVersion %s in lib/src/app.dart differ; set both to the "
                             "release version (app/README.md \"Releasing\")" % (pub, const))
    jdk = require_jdk() if args.target != "web" else None
    started = datetime.datetime.now().astimezone()
    report = {"target": args.target, "started": started.isoformat(timespec="seconds"),
              "git": git_state(), "toolchain": toolchain()}
    if jdk:
        jdk["flutter_jdk_dir"] = scope_flutter_config()
        report["toolchain"]["jdk"] = jdk
    if args.checks:
        report["checks"] = checks()
    if args.target == "web":
        report["web"] = build_web()
        leaks = report["web"]["secret_scan"]["found_in"]
        problems = ["secret value found: " + leaks[0]] if leaks else []
    else:
        report["apk"] = build_apk(args.target == "apk-release")
        problems = report["apk"]["problems"]
        if report["apk"]["secret_scan"]["found_in"]:
            problems.append("secret value found: " + report["apk"]["secret_scan"]["found_in"][0])
        if args.target == "apk-release" and not problems:
            report["release"] = prepare_release(report["apk"])
    report["result"] = "refused: " + "; ".join(problems) if problems else "ok"

    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    out = STATE / ("%s-%s.json" % (started.strftime("%Y%m%dT%H%M%S"), args.target))
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(report, f, indent=1)
    print(json.dumps(report, indent=1))
    print("evidence: " + str(out))
    if problems:
        raise SystemExit("build refused: " + "; ".join(problems))
    rel = report.get("release")
    if rel:
        print("\nRelease %s (not published; run these after editing %s):" % (rel["tag"], rel["notes"]))
        for line in rel["tag_commands"] + [rel["gh_command"]]:
            print("  " + line)


if __name__ == "__main__":
    main()
