#!/usr/bin/env python3
"""Tove device QA harness (Android, adb over wireless debugging).

Scoped to the Tove package only ($TOVE_PACKAGE): it never installs another package, never
reads or captures the screen while another app is in front, never unlocks the
phone or types a passcode, and never prints the live key. Output that could hold
a bridge secret is redacted before it is shown or saved. Evidence (screenshots,
redacted logcat) goes to ~/.local/state/hermes-live-qa/, outside the repo.

  device_qa.py preflight            device, lock state, reverse tunnel, bridge reachability
  device_qa.py install APK [--fresh] verify package name/signature, then install it (no -g)
  device_qa.py launch | stop | home | wake | sleep
  device_qa.py reset                clear Tove app data (re-runs onboarding)
  device_qa.py mic grant|revoke|reprompt
  device_qa.py ui [--tap LABEL] [--wait LABEL] [--timeout S]
  device_qa.py enter-key            type the shared live key into the focused Tove field
  device_qa.py screenshot NAME
  device_qa.py status               foreground, service, notification, mic and playback for Tove
  device_qa.py notification [--shade]
  device_qa.py logcat start|stop
  device_qa.py bridge [--since 10min]
  device_qa.py cleanup [--uninstall]
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET


def setting(*names, default):
    """First non-empty environment variable among names (new name first, legacy after), else default."""
    for name in names:
        value = os.environ.get(name, "").strip()
        if value:
            return value
    return default


PACKAGE = setting("TOVE_PACKAGE", default="io.github.tovechat.tove")
DIALOG_PACKAGES = {"com.google.android.permissioncontroller", "com.android.permissioncontroller"}
TOOLS = Path(setting("TOVE_BUILD_TOOLS", "HERMES_BUILD_TOOLS", default="~/.local/share/hermes-build-tools")).expanduser()
ADB = setting("ADB", default=str(TOOLS / "android-sdk/platform-tools/adb"))
SERIAL = setting("TOVE_QA_SERIAL", "HERMES_QA_SERIAL", default="")   # empty: the only device adb sees
BRIDGE_ENV = Path(setting("TOVE_BRIDGE_ENV", "BRIDGE_ENV", default="~/.local/share/gpt-live-bridge/bridge.env")).expanduser()
BRIDGE_PORT = int(setting("TOVE_BRIDGE_PORT", default="8787"))
TARGET = ["-s", SERIAL] if SERIAL else []
STATE = Path(setting("TOVE_QA_STATE", "HERMES_QA_STATE", default="~/.local/state/hermes-live-qa")).expanduser()
SECRET_NAMES = ("LIVE_PAGE_KEY", "BRIDGE_API_KEY", "HERMES_API_KEY", "TOVE_NOTIFY_KEY")


# ---------------------------------------------------------------- secrets / output
def secrets():
    found = {}
    try:
        lines = BRIDGE_ENV.read_text().splitlines()
    except OSError:
        return found
    for line in lines:
        name, _, value = line.partition("=")
        value = value.strip().strip("'\"")
        if name.strip() in SECRET_NAMES and len(value) >= 12:
            found[name.strip()] = value
    return found


SECRETS = secrets()


def redact(text):
    for name, value in SECRETS.items():
        text = text.replace(value, "<%s redacted>" % name)
    return text


def say(text=""):
    print(redact(str(text)))


def die(text):
    say("FAIL: " + text)
    sys.exit(1)


# ---------------------------------------------------------------- adb
def adb(*args, check=True, binary=False, stdin=None, timeout=60):
    proc = subprocess.run([ADB, *TARGET, *args], capture_output=True, input=stdin, timeout=timeout)
    if check and proc.returncode != 0:
        die("adb %s failed: %s" % (args[0], redact(proc.stderr.decode(errors="replace")).strip()[:300]))
    return proc.stdout if binary else proc.stdout.decode(errors="replace")


def sh(command, **kw):
    return adb("shell", command, **kw)


def connected():
    out = subprocess.run([ADB, "devices"], capture_output=True, text=True).stdout
    states = [line.split("\t")[:2] for line in out.splitlines()[1:] if "\t" in line]
    if not SERIAL:
        return [s for _, s in states] == ["device"]
    return [SERIAL, "device"] in states


def keyguard_showing():
    return "isKeyguardShowing=true" in sh("dumpsys window | grep -m1 isKeyguardShowing", check=False)


def foreground():
    out = sh("dumpsys activity activities | grep -m1 topResumedActivity", check=False)
    match = re.search(r"u\d+ ([\w.]+)/", out)
    return match.group(1) if match else ""


def require_hermes_front(allow_dialog=True):
    front = foreground()
    allowed = {PACKAGE} | (DIALOG_PACKAGES if allow_dialog else set())
    if front not in allowed:
        die("Tove is not in the foreground; refusing to read the screen")   # never name another app
    return front


def uid():
    out = sh("pm list packages -U " + PACKAGE, check=False)
    match = re.search(r"package:%s uid:(\d+)" % re.escape(PACKAGE), out)
    return match.group(1) if match else None


def pid():
    return sh("pidof " + PACKAGE, check=False).strip()


# ---------------------------------------------------------------- UI hierarchy
def dump_ui():
    require_hermes_front()
    sh("uiautomator dump /data/local/tmp/hermes-qa-ui.xml >/dev/null", check=False)
    xml = sh("cat /data/local/tmp/hermes-qa-ui.xml", check=False)
    sh("rm -f /data/local/tmp/hermes-qa-ui.xml", check=False)
    try:
        root = ET.fromstring(xml[xml.find("<"):])
    except ET.ParseError:
        die("could not read the UI hierarchy")
    nodes = []
    for node in root.iter("node"):
        if node.get("package") not in {PACKAGE} | DIALOG_PACKAGES:
            continue
        label = node.get("text") or node.get("content-desc") or ""
        nodes.append({"label": label, "class": node.get("class", ""), "bounds": node.get("bounds", ""),
                      "clickable": node.get("clickable") == "true", "focused": node.get("focused") == "true",
                      "password": node.get("password") == "true", "enabled": node.get("enabled") == "true"})
    return nodes, xml


def center(bounds):
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", bounds))
    return (x1 + x2) // 2, (y1 + y2) // 2


def find(nodes, label):
    want = label.lower()
    exact = [n for n in nodes if n["label"].lower() == want]
    loose = [n for n in nodes if want in n["label"].lower()]
    return (exact or loose or [None])[0]


def cmd_ui(args):
    deadline = time.time() + args.timeout
    while True:
        nodes, _ = dump_ui()
        target = args.wait or args.tap
        node = find(nodes, target) if target else None
        if not target or node or time.time() > deadline:
            break
        time.sleep(1)
    if target and not node:
        for n in nodes:
            if n["label"]:
                say("  %-40s %s" % (n["label"][:40], n["bounds"]))
        die("no element labelled %r" % target)
    if args.tap:
        x, y = center(node["bounds"])
        sh("input tap %d %d" % (x, y))
        say("tapped %r" % node["label"])
    elif args.wait:
        say("found %r" % node["label"])
    else:
        for n in nodes:
            if n["label"] or n["clickable"]:
                flags = "".join(f for f, on in (("C", n["clickable"]), ("F", n["focused"]), ("P", n["password"]),
                                                 ("-", not n["enabled"])) if on)
                say("  %-4s %-48s %s" % (flags, (n["label"] or "<" + n["class"].rsplit(".", 1)[-1] + ">")[:48], n["bounds"]))


def cmd_enter_key(_args):
    key = SECRETS.get("LIVE_PAGE_KEY")
    if not key:
        die("LIVE_PAGE_KEY is not readable from %s" % BRIDGE_ENV)
    if not re.fullmatch(r"[A-Za-z0-9_\-.~]+", key):
        die("the live key has characters adb input cannot type safely; enter it by hand")
    if foreground() != PACKAGE:
        die("Tove is not in the foreground")
    nodes, _ = dump_ui()
    if not any(n["focused"] and "EditText" in n["class"] for n in nodes):
        die("no focused Tove text field; tap the key field first (ui --tap LABEL)")
    # The value goes through adb's stdin, so it never appears in a host command line or in this output.
    adb("shell", stdin=("input text '%s'\nexit\n" % key).encode())
    say("live key entered (%d characters)" % len(key))


# ---------------------------------------------------------------- commands
def cmd_preflight(_args):
    if not connected():
        die("device %s is not connected over adb" % (SERIAL or "(set TOVE_QA_SERIAL when several are attached)"))
    props = sh("getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.version.sdk").split()
    say("device: %s Android %s (API %s)" % tuple(props[:3]))
    say("screen: " + sh("wm size").strip().split(":")[-1].strip())
    if sh("getprop service.adb.tcp.port", check=False).strip() not in ("", "-1", "0"):
        say("WARN: legacy tcp adb port is set; this harness does not use or enable it")
    say("lock screen showing: %s" % keyguard_showing())
    reverse = adb("reverse", "--list")
    if "tcp:%d tcp:%d" % (BRIDGE_PORT, BRIDGE_PORT) not in reverse:
        adb("reverse", "tcp:%d" % BRIDGE_PORT, "tcp:%d" % BRIDGE_PORT)
        say("reverse tunnel tcp:%d added" % BRIDGE_PORT)
    else:
        say("reverse tunnel tcp:%d present" % BRIDGE_PORT)
    code = sh("curl -s -o /dev/null -w '%%{http_code}' http://127.0.0.1:%d/healthz" % BRIDGE_PORT, check=False).strip()
    say("phone -> bridge healthz: " + (code or "no answer"))
    say("Tove installed: %s" % (uid() is not None))
    say("live key available locally: %s" % ("LIVE_PAGE_KEY" in SECRETS))


def build_tool(name):
    tools = sorted((TOOLS / "android-sdk/build-tools").glob("*/" + name))
    return str(tools[-1]) if tools else None


def cmd_install(args):
    apk = Path(args.apk)
    aapt2 = build_tool("aapt2")
    if not apk.is_file() or not aapt2:
        die("APK or aapt2 missing")
    badging = subprocess.run([aapt2, "dump", "badging", str(apk)], capture_output=True, text=True).stdout
    match = re.search(r"package: name='([^']+)'", badging)
    if not match or match.group(1) != PACKAGE:
        die("APK package is %s, not %s; refusing to install" % (match.group(1) if match else "unknown", PACKAGE))
    if keyguard_showing():
        die("phone is locked; ask the operator to unlock it")
    adb("install", "-r", str(apk), timeout=300)              # no -g: runtime permissions stay user-granted
    say("installed %s (%s)" % (PACKAGE, re.search(r"versionName='([^']*)'", badging).group(1)
                                if "versionName" in badging else "unknown version"))
    if args.fresh:
        sh("pm clear " + PACKAGE)
        say("app data cleared for a fresh onboarding run")


def cmd_mic(args):
    perm = "android.permission.RECORD_AUDIO"
    if args.action == "grant":
        sh("pm grant %s %s" % (PACKAGE, perm))
    elif args.action == "revoke":
        sh("pm revoke %s %s" % (PACKAGE, perm))
    else:                                                   # forget the user's choice so the system prompt returns
        sh("pm revoke %s %s; pm clear-permission-flags %s %s user-set user-fixed" % (PACKAGE, perm, PACKAGE, perm))
    say("microphone: " + mic_state())


def mic_state():
    out = sh("dumpsys package %s | grep -m1 'android.permission.RECORD_AUDIO: granted'" % PACKAGE, check=False)
    return "granted" if "granted=true" in out else "not granted"


def notification_lines():
    out = sh("dumpsys notification --noredact", check=False)
    blocks, current = [], None
    for line in out.splitlines():
        if re.match(r"\s+NotificationRecord\(", line):
            current = [line] if "pkg=" + PACKAGE in line else None
            if current is not None:
                blocks.append(current)
        elif current is not None:
            current.append(line)
    return blocks


def cmd_notification(args):
    if args.shade:
        sh("cmd statusbar expand-notifications")
        say("notification shade opened; collapse with: adb shell cmd statusbar collapse")
    blocks = notification_lines()
    say("Tove notifications: %d" % len(blocks))
    for block in blocks:
        for line in block:
            if re.search(r"(channel=|category=|flags=|visibility|actions=|\s\[\d+\] \"|android\.title=|ongoing|FOREGROUND)", line):
                say("  " + line.strip()[:160])


def cmd_status(_args):
    front = foreground()
    say("foreground: %s" % (front if front in {PACKAGE} | DIALOG_PACKAGES else "another app"))
    say("lock screen showing: %s" % keyguard_showing())
    app_uid = uid()
    if not app_uid:
        say("Tove is not installed")
        return
    say("process: %s" % (pid() or "not running"))
    say("microphone permission: " + mic_state())
    services = sh("dumpsys activity services " + PACKAGE, check=False)
    say("foreground service: %s" % ("isForeground=true" in services))
    say("notifications: %d" % len(notification_lines()))
    audio = sh("dumpsys audio", check=False)
    playing = [l.strip() for l in audio.splitlines() if "AudioPlaybackConfiguration" in l and "u/pid:%s/" % app_uid in l]
    say("playback players: %d (%d started)" % (len(playing), sum("state:started" in l for l in playing)))
    for line in playing:
        say("  " + re.sub(r"deviceIds:\S+ |bundle=\S+ |FormatInfo\{.*", "", line)[:160])
    ops = sh("cmd appops get %s RECORD_AUDIO" % PACKAGE, check=False).strip()
    say("RECORD_AUDIO appop: " + (ops.replace("\n", " | ")[:200] or "none"))
    recording = sh("dumpsys media.audio_policy | grep -iE 'uid:? ?%s' | head -5" % app_uid, check=False).strip()
    say("audio policy records for Tove: %d line(s)" % len(recording.splitlines()) if recording else "audio policy records for Tove: none")
    code = sh("curl -s http://127.0.0.1:%d/healthz" % BRIDGE_PORT, check=False).strip()
    say("bridge: " + (code or "no answer"))


def cmd_screenshot(args):
    require_hermes_front()
    nodes, xml = dump_ui()
    if any(value in xml for value in SECRETS.values()):
        die("a bridge secret is visible on screen; refusing to capture it")
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    name = re.sub(r"[^\w.-]", "_", args.name) + ".png"
    png = adb("exec-out", "screencap -p", binary=True)
    path = STATE / (time.strftime("%Y%m%d-%H%M%S-") + name)
    path.write_bytes(png)
    path.chmod(0o600)
    say("saved " + str(path))


def cmd_logcat(args):
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    pidfile = STATE / "logcat.pid"
    if args.action == "start":
        app_pid = pid()
        if not app_pid:
            die("Tove is not running; launch it first")
        sh("logcat -c", check=False)
        out = STATE / time.strftime("logcat-%Y%m%d-%H%M%S.txt")
        # Redact before anything touches disk.
        reader = subprocess.Popen([ADB, *TARGET, "logcat", "--pid", app_pid, "-v", "time"], stdout=subprocess.PIPE)
        writer = subprocess.Popen([sys.executable, "-I", __file__, "_redact", str(out)], stdin=reader.stdout)
        reader.stdout.close()
        pidfile.write_text("%d %d %s" % (reader.pid, writer.pid, out))
        say("capturing Tove logcat to " + str(out))
    else:
        if not pidfile.exists():
            die("no capture running")
        reader, writer, out = pidfile.read_text().split(" ", 2)
        for p in (reader, writer):
            try:
                os.kill(int(p), 15)
            except ProcessLookupError:
                pass
        pidfile.unlink()
        say("capture stopped: " + out)


def redact_stream(out):
    with open(out, "w", buffering=1) as fh:
        os.chmod(out, 0o600)
        for line in sys.stdin.buffer:
            fh.write(redact(line.decode(errors="replace")))


def cmd_bridge(args):
    out = subprocess.run(["journalctl", "--user", "-u", "gpt-live-bridge", "--since", "-" + args.since, "--no-pager", "-o", "cat"],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        if re.search(r"live session|live start|hermes task|error|warning", line, re.I):
            say(line)


def cmd_cleanup(args):
    sh("cmd statusbar collapse", check=False)
    if uid():
        sh("am force-stop " + PACKAGE)
        time.sleep(1)
        say("process after force-stop: %s" % (pid() or "none"))
        say("notifications left: %d" % len(notification_lines()))
        say("foreground service left: %s" % ("isForeground=true" in sh("dumpsys activity services " + PACKAGE, check=False)))
        if args.uninstall:
            adb("uninstall", PACKAGE)
            say("uninstalled " + PACKAGE)
    time.sleep(1)
    say("bridge: " + sh("curl -s http://127.0.0.1:%d/healthz" % BRIDGE_PORT, check=False).strip())


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "_redact":
        return redact_stream(sys.argv[2])
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("preflight")
    p = sub.add_parser("install"); p.add_argument("apk"); p.add_argument("--fresh", action="store_true")
    for name in ("launch", "stop", "home", "wake", "sleep", "reset", "enter-key", "status"):
        sub.add_parser(name)
    p = sub.add_parser("mic"); p.add_argument("action", choices=("grant", "revoke", "reprompt"))
    p = sub.add_parser("ui"); p.add_argument("--tap"); p.add_argument("--wait"); p.add_argument("--timeout", type=float, default=15)
    p = sub.add_parser("screenshot"); p.add_argument("name")
    p = sub.add_parser("notification"); p.add_argument("--shade", action="store_true")
    p = sub.add_parser("logcat"); p.add_argument("action", choices=("start", "stop"))
    p = sub.add_parser("bridge"); p.add_argument("--since", default="10min")
    p = sub.add_parser("cleanup"); p.add_argument("--uninstall", action="store_true")
    args = parser.parse_args()
    if args.command != "bridge" and not connected():
        die("device %s is not connected over adb" % (SERIAL or "(set TOVE_QA_SERIAL when several are attached)"))
    simple = {
        "launch": lambda: sh("monkey -p %s -c android.intent.category.LAUNCHER 1 >/dev/null" % PACKAGE),
        "stop": lambda: sh("am force-stop " + PACKAGE),
        "home": lambda: sh("input keyevent KEYCODE_HOME"),
        "wake": lambda: sh("input keyevent KEYCODE_WAKEUP"),          # shows the lock screen; never unlocks
        "sleep": lambda: sh("input keyevent KEYCODE_SLEEP"),
        "reset": lambda: sh("pm clear " + PACKAGE),
    }
    if args.command in simple:
        if args.command == "launch" and keyguard_showing():
            die("phone is locked; ask the operator to unlock it")
        simple[args.command]()
        say(args.command + ": done")
        return
    {"preflight": cmd_preflight, "install": cmd_install, "mic": cmd_mic, "ui": cmd_ui, "enter-key": cmd_enter_key,
     "screenshot": cmd_screenshot, "status": cmd_status, "notification": cmd_notification, "logcat": cmd_logcat,
     "bridge": cmd_bridge, "cleanup": cmd_cleanup}[args.command](args)


if __name__ == "__main__":
    main()
