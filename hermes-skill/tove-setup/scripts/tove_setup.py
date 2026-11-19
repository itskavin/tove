#!/usr/bin/env python3
"""Set up the Tove bridge next to Hermes Agent and pair the Tove app (the tove-setup skill's helper).

    tove_setup.py detect                                  what is here: Hermes, Docker, Python, Tailscale, cloudflared
    tove_setup.py install [--mode docker|venv] [--enable-hermes-api] [--dry-run]
    tove_setup.py expose --via tailscale|cloudflare|url [--url https://...] [--dry-run]
    tove_setup.py pair [--png FILE]                       QR code + short code (one use, 10 minutes)
    tove_setup.py places --area "City, Country" | --bbox W,S,E,N | --country CC [--dry-run]
                                                          local places for "near me" answers (open data, no key)
    tove_setup.py status | uninstall [--keep-data]

Every command prints one JSON object on stdout (`--human` for the pairing QR on a terminal). Nothing is changed by
`detect`, `status` or `--dry-run`. Hermes' own files are changed only with `--enable-hermes-api`, and Hermes is never
restarted by this script: it prints the command, so the agent can ask first.

Standard library only (Python 3.9+). State lives in $TOVE_HOME (default ~/.local/share/tove):
setup.json, bridge.env (mode 600, holds the keys), data/ (the bridge's data), src/ (the bridge's code), venv/.
"""
import argparse, io, json, os, platform, re, secrets, shlex, shutil, socket, subprocess, sys, tarfile, time
import urllib.error, urllib.parse, urllib.request
from pathlib import Path

REPO = "itskavin/tove"
TARBALL = "https://codeload.github.com/%s/tar.gz/refs/heads/main" % REPO
HERMES_DOCS = "https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server"
CLOUDFLARED_URL = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-%s"
DEFAULT_PORT = 8787
HERMES_PORT = 8642
NAME = "tove-bridge"
TUNNEL_UNIT = "tove-tunnel"


# ---------------------------------------------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------------------------------------------
class Plan:
    """Runs commands, or with dry_run only records them (the JSON output lists every step either way)."""

    def __init__(self, dry_run=False):
        self.dry_run, self.steps = dry_run, []

    def run(self, cmd, check=True, capture=True, input=None, timeout=900, quiet=False):
        if not quiet:
            self.steps.append(" ".join(shlex.quote(str(c)) for c in cmd))
        if self.dry_run:
            return subprocess.CompletedProcess(cmd, 0, "", "")
        r = subprocess.run([str(c) for c in cmd], capture_output=capture, text=True, input=input, timeout=timeout)
        if check and r.returncode != 0:
            raise SetupError("command failed: %s\n%s" % (cmd[0], (r.stderr or r.stdout or "").strip()[-1500:]))
        return r

    def write(self, path, text, mode=0o644):
        self.steps.append("write %s (mode %o)" % (path, mode))
        if self.dry_run:
            return
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name("." + path.name + ".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)


class SetupError(Exception):
    pass


def sh(cmd, timeout=20):
    """Quiet probe: (returncode, stdout). Never raises."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return 127, ""


def home() -> Path:
    return Path(os.path.expanduser(os.environ.get("TOVE_HOME") or "~/.local/share/tove"))


def load_state() -> dict:
    try:
        return json.loads((home() / "setup.json").read_text())
    except (OSError, ValueError):
        return {}


def save_state(plan, state):
    plan.write(home() / "setup.json", json.dumps(state, indent=2) + "\n", 0o600)


def read_env_file(text: str) -> dict:
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        if k.startswith("export "):
            k = k[7:].strip()
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        out[k] = v
    return out


def http_status(url, key=None, timeout=4):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + key} if key else {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except (OSError, ValueError):
        return None


def lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.0.2.1", 9))           # TEST-NET: nothing is sent; picks the outward interface
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()


def port_free(port):
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", port)) != 0


# ---------------------------------------------------------------------------------------------------------------
# detect
# ---------------------------------------------------------------------------------------------------------------
def docker_ok():
    if not shutil.which("docker"):
        return False
    return sh(["docker", "info", "--format", "{{.ServerVersion}}"])[0] == 0


def find_hermes_container():
    code, out = sh(["docker", "ps", "--format", "{{.Names}}\t{{.Image}}"])
    if code != 0:
        return None
    for line in out.splitlines():
        name, _, image = line.partition("\t")
        if "hermes-agent" in image or name == "hermes":
            return name
    return None


def container_info(name):
    code, out = sh(["docker", "inspect", name])
    if code != 0:
        return {}
    c = json.loads(out)[0]
    nets = c.get("NetworkSettings", {}).get("Networks", {}) or {}
    env = dict(e.split("=", 1) for e in c.get("Config", {}).get("Env", []) if "=" in e)
    mounts = {m.get("Destination"): m.get("Source") for m in c.get("Mounts", [])}
    hermes_home = env.get("HERMES_HOME", "/opt/data")
    return {"network_mode": c.get("HostConfig", {}).get("NetworkMode", ""), "networks": list(nets),
            "ips": [n.get("IPAddress") for n in nets.values() if n.get("IPAddress")],
            "hermes_home": hermes_home, "home_on_host": mounts.get(hermes_home)}


def hermes_env_native():
    hh = Path(os.path.expanduser(os.environ.get("HERMES_HOME") or "~/.hermes"))
    try:
        return hh, read_env_file((hh / ".env").read_text())
    except OSError:
        return hh, {}


def hermes_env_container(name, hermes_home):
    code, out = sh(["docker", "exec", name, "sh", "-c", 'cat "%s/.env" 2>/dev/null; echo; env' % hermes_home])
    return read_env_file(out) if code == 0 else {}


def detect() -> dict:
    """What is installed and how the pieces could reach each other. Changes nothing."""
    in_container = Path("/.dockerenv").exists() or os.environ.get("container") is not None
    have_docker = docker_ok()
    r = {"os": platform.system().lower(), "arch": platform.machine(), "in_container": in_container,
         "docker": have_docker, "systemd_user": sh(["systemctl", "--user", "is-system-running"])[1] in ("running", "degraded"),
         "python": None, "uv": bool(shutil.which("uv")), "lan_ip": lan_ip(), "state": load_state() or None}
    for py in ("python3.12", "python3.13", "python3.14", "python3"):
        exe = shutil.which(py)
        if exe and sh([exe, "-c", "import sys; sys.exit(sys.version_info < (3, 11))"])[0] == 0:
            r["python"] = exe
            break
    hermes = {"found": False}
    container = find_hermes_container() if have_docker else None
    if container:
        info = container_info(container)
        env = hermes_env_container(container, info.get("hermes_home", "/opt/data"))
        host_net = info.get("network_mode") == "host"
        hermes.update(found=True, mode="docker", container=container, **info)
        api_host = env.get("API_SERVER_HOST", "127.0.0.1")
        port = int(env.get("API_SERVER_PORT") or HERMES_PORT)
        if host_net:
            hermes["api_url_for_host"] = "http://127.0.0.1:%d/v1" % port
            hermes["api_url_for_bridge"] = hermes["api_url_for_host"]
            hermes["bridge_network"] = "host"
        else:
            ip = (info.get("ips") or [None])[0]
            hermes["api_url_for_host"] = "http://%s:%d/v1" % (ip, port) if ip else None
            hermes["api_url_for_bridge"] = "http://%s:%d/v1" % (container, port)
            hermes["bridge_network"] = (info.get("networks") or [None])[0]
            # Inside its own network namespace, 127.0.0.1 is not reachable from another container.
            hermes["api_host_needs_change"] = api_host in ("127.0.0.1", "localhost")
    else:
        hh, env = hermes_env_native()
        if shutil.which("hermes") or (hh / "config.yaml").exists() or env:
            port = int(env.get("API_SERVER_PORT") or HERMES_PORT)
            hermes.update(found=True, mode="native", hermes_home=str(hh), api_url_for_host="http://127.0.0.1:%d/v1" % port,
                          api_url_for_bridge="http://127.0.0.1:%d/v1" % port, bridge_network="host")
    if hermes["found"]:
        key = env.get("API_SERVER_KEY", "")
        hermes["api_key_set"] = len(key) >= 16
        hermes["_key"] = key
        url = hermes.get("api_url_for_host")
        status = http_status(url + "/models", key) if url and key else None
        hermes["api_reachable"] = status == 200
        hermes["api_status"] = status
    r["hermes"] = hermes
    ts = {"installed": bool(shutil.which("tailscale"))}
    if ts["installed"]:
        code, out = sh(["tailscale", "status", "--json"])
        if code == 0 and out:
            st = json.loads(out)
            me = st.get("Self") or {}
            ts.update(running=st.get("BackendState") == "Running", dns_name=(me.get("DNSName") or "").rstrip("."),
                      https=bool(st.get("CertDomains")))
    r["tailscale"] = ts
    r["cloudflared"] = bool(shutil.which("cloudflared") or (home() / "bin" / "cloudflared").exists())
    r["recommended_mode"] = "docker" if (have_docker and hermes.get("mode") == "docker") or (have_docker and not r["python"]) else \
        ("venv" if r["python"] and r["systemd_user"] else ("docker" if have_docker else None))
    if in_container and not have_docker:
        r["blocker"] = ("This terminal runs inside a container (probably Hermes' own), which cannot start programs on the "
                        "host. Run the bridge on the host by hand (README: 'Install by hand'), or give Hermes a host terminal.")
    elif not r["recommended_mode"]:
        r["blocker"] = "Neither Docker nor Python 3.11+ with systemd user services is available here."
    return r


def public(r):
    """detect() without secrets."""
    out = json.loads(json.dumps(r))
    out.get("hermes", {}).pop("_key", None)
    return out


# ---------------------------------------------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------------------------------------------
def fetch_source(plan, source) -> Path:
    """The bridge's code: a local checkout (--source DIR, its server/ is used), or the main branch from GitHub."""
    if source and not source.startswith(("http://", "https://")):
        src = Path(source).expanduser().resolve()
        server = src / "server" if (src / "server" / "gpt-live-bridge.py").exists() else src
        if not (server / "gpt-live-bridge.py").exists():
            raise SetupError("%s has no gpt-live-bridge.py" % source)
        return server
    dest = home() / "src"
    plan.steps.append("download %s → %s" % (source or TARBALL, dest))
    if plan.dry_run:
        return dest / "server"
    try:
        with urllib.request.urlopen(source or TARBALL, timeout=120) as r:
            data = r.read()
    except urllib.error.HTTPError as e:
        raise SetupError("could not download the bridge (%s). If the repository is private, clone it and pass --source." % e.code)
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        members = []
        for m in tar.getmembers():
            parts = m.name.split("/", 1)
            if len(parts) < 2 or not parts[1].startswith("server/") or not (m.isfile() or m.isdir()):
                continue
            m.name = parts[1]
            if m.name.startswith("/") or ".." in Path(m.name).parts:
                continue
            members.append(m)
        kw = {"filter": "data"} if sys.version_info >= (3, 12) else {}
        tar.extractall(dest, members=members, **kw)
    return dest / "server"


def enable_hermes_api(plan, det) -> dict:
    """Adds API_SERVER_KEY (and, for a container on its own network, API_SERVER_HOST=0.0.0.0) to Hermes' .env.
    Hermes reads .env at start, so it needs a restart afterwards; the command is returned, not run."""
    h = det["hermes"]
    key = h.get("_key") if h.get("api_key_set") else secrets.token_urlsafe(32)
    lines = []
    if not h.get("api_key_set"):
        lines += ["API_SERVER_ENABLED=true", "API_SERVER_KEY=" + key]
    if h.get("api_host_needs_change"):
        lines.append("API_SERVER_HOST=0.0.0.0")
    if not lines:
        return {"changed": False, "key": key}
    block = "\n# Added by tove-setup: Hermes' API server for the Tove bridge\n" + "\n".join(lines) + "\n"
    if h["mode"] == "native":
        env_path = Path(h["hermes_home"]) / ".env"
        plan.steps.append("append %s to %s" % ([l.split("=")[0] for l in lines], env_path))
        if not plan.dry_run:
            env_path.parent.mkdir(parents=True, exist_ok=True)
            with open(env_path, "a") as f:
                f.write(block)
            os.chmod(env_path, 0o600)
        restart = "hermes gateway restart"
    else:
        target = "%s/.env" % h["hermes_home"]
        plan.steps.append("append %s to %s in container %s" % ([l.split("=")[0] for l in lines], target, h["container"]))
        plan.run(["docker", "exec", "-i", h["container"], "sh", "-c", 'cat >> "%s"' % target], input=block, quiet=True)
        restart = "docker restart %s" % h["container"]
    return {"changed": True, "key": key, "restart_command": restart,
            "note": "Hermes reads this at start: restart it to turn its API server on."}


def write_bridge_env(plan, path, values):
    lines = ["# Written by tove-setup. Keep private (mode 600). Settings: bridge.env.example in the Tove repo."]
    lines += ["%s=%s" % (k, v) for k, v in values.items()]
    plan.write(path, "\n".join(lines) + "\n", 0o600)


def install(a) -> dict:
    plan = Plan(a.dry_run)
    det = detect()
    if det.get("blocker") and not a.mode:
        raise SetupError(det["blocker"])
    h = det["hermes"]
    if not h.get("found") and not a.hermes_url:
        raise SetupError("Hermes Agent was not found here. Install it first (%s), or pass --hermes-url." % HERMES_DOCS)
    mode = a.mode or det["recommended_mode"]
    if mode == "docker" and not det["docker"]:
        raise SetupError("Docker is not available to this user.")
    if mode == "venv" and not det["python"]:
        raise SetupError("Python 3.11 or newer was not found.")
    state = load_state()
    name = a.name or state.get("name") or NAME
    port = a.port or state.get("port") or DEFAULT_PORT
    if not a.dry_run and state.get("port") != port and not port_free(port):
        raise SetupError("port %d is in use; pass --port" % port)
    api = {"changed": False, "key": h.get("_key", "")}
    if not h.get("api_key_set") or h.get("api_host_needs_change"):
        if not a.enable_hermes_api and not a.hermes_key:
            raise SetupError("Hermes' API server is off (no API_SERVER_KEY)%s. Ask the user, then run again with "
                             "--enable-hermes-api." % (" or only listens inside its container" if h.get("api_host_needs_change") else ""))
        if a.enable_hermes_api:
            api = enable_hermes_api(plan, det)
    hermes_key = a.hermes_key or api["key"]
    hermes_url = a.hermes_url or h.get("api_url_for_bridge")
    root = home()
    data = Path(a.data_dir).expanduser() if a.data_dir else root / "data"
    env_file = root / "bridge.env"
    old_env = read_env_file(env_file.read_text()) if env_file.exists() else {}
    live_key = old_env.get("LIVE_PAGE_KEY") if len(old_env.get("LIVE_PAGE_KEY", "")) >= 24 else secrets.token_urlsafe(32)
    server = fetch_source(plan, a.source)
    values = {"LIVE_PAGE_KEY": live_key, "HERMES_API_URL": hermes_url, "HERMES_API_KEY": hermes_key,
              "ASSISTANT_NAME": a.assistant_name or old_env.get("ASSISTANT_NAME") or "Hermes"}
    plan.steps.append("generate a new access key" if live_key != old_env.get("LIVE_PAGE_KEY") else "keep the existing access key")
    if not plan.dry_run:
        data.mkdir(parents=True, exist_ok=True)
        os.chmod(data, 0o700)
    if mode == "docker":
        network = h.get("bridge_network") or "host"
        values.update(BRIDGE_DATA_DIR="/data", CODEX_HOME="/data/codex-home")
        if network == "host":
            values.update(BRIDGE_HOST="127.0.0.1", BRIDGE_PORT=str(port))
        else:
            values.update(BRIDGE_HOST="0.0.0.0", BRIDGE_PORT="8787")
        write_bridge_env(plan, env_file, values)
        image = "tove-bridge:local"
        build = ["docker", "build", "-t", image]
        if a.no_codex:
            build += ["--build-arg", "CODEX_VERSION="]
        plan.run(build + [str(server)], timeout=1800)
        plan.run(["docker", "rm", "-f", name], check=False)
        run = ["docker", "run", "-d", "--name", name, "--restart", "unless-stopped", "--env-file", str(env_file),
               "-v", "%s:/data" % data, "--user", "%d:%d" % (os.getuid(), os.getgid()), "--read-only", "--tmpfs", "/tmp",
               "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true", "--memory", "1g"]
        run += ["--network", "host"] if network == "host" else ["--network", network, "-p", "127.0.0.1:%d:8787" % port]
        plan.run(run + [image])
    else:
        values.update(BRIDGE_DATA_DIR=str(data), BRIDGE_HOST="127.0.0.1", BRIDGE_PORT=str(port))
        write_bridge_env(plan, env_file, values)
        venv = root / "venv"
        py = det["python"]
        if not (venv / "bin" / "python").exists() or a.dry_run:
            made = plan.run([py, "-m", "venv", str(venv)], check=False)
            if made.returncode != 0:
                if not det["uv"]:
                    raise SetupError("python -m venv failed (on Debian/Ubuntu: sudo apt install python3-venv)")
                if venv.exists():
                    shutil.rmtree(venv)
                plan.run(["uv", "venv", "-q", "-p", py, str(venv)])
        if (venv / "bin" / "pip").exists() or plan.dry_run:
            plan.run([venv / "bin" / "pip", "install", "-q", "--only-binary=:all:", "-r", server / "requirements.txt"], timeout=1800)
        else:
            plan.run(["uv", "pip", "install", "-q", "--python", venv / "bin" / "python", "-r", server / "requirements.txt"], timeout=1800)
        unit = """[Unit]
Description=Tove bridge (the Tove app's server, next to Hermes Agent)
After=network-online.target

[Service]
ExecStart=%s %s
EnvironmentFile=%s
Restart=always
RestartSec=5
MemoryMax=900M
NoNewPrivileges=true

[Install]
WantedBy=default.target
""" % (venv / "bin" / "python", server / "gpt-live-bridge.py", env_file)
        unit_path = Path(os.path.expanduser("~/.config/systemd/user")) / (name + ".service")
        plan.write(unit_path, unit)
        plan.run(["systemctl", "--user", "daemon-reload"])
        plan.run(["systemctl", "--user", "enable", "--now", name])
        plan.run(["systemctl", "--user", "restart", name])
    local = "http://127.0.0.1:%d" % port
    healthy = plan.dry_run or wait_healthy(local)
    state.update(name=name, mode=mode, port=port, data_dir=str(data), env_file=str(env_file), server=str(server),
                 local_url=local, installed_at=int(time.time()))
    save_state(plan, state)
    out = {"ok": bool(healthy), "dry_run": a.dry_run, "mode": mode, "name": name, "local_url": local,
           "hermes_api_url": hermes_url, "hermes_api_changed": api.get("changed", False), "steps": plan.steps}
    if api.get("restart_command"):
        out["hermes_restart_command"] = api["restart_command"]
    if not healthy:
        out["error"] = "the bridge did not answer on %s/healthz; see %s" % (local, "docker logs " + name if mode == "docker"
                                                                              else "journalctl --user -u " + name)
    if mode == "venv":
        out["note"] = "To keep it running after you log out: loginctl enable-linger $USER"
    return out


def wait_healthy(url, seconds=45):
    end = time.time() + seconds
    while time.time() < end:
        if http_status(url + "/healthz") == 200:
            return True
        time.sleep(1)
    return False


# ---------------------------------------------------------------------------------------------------------------
# expose: how the phone reaches the bridge
# ---------------------------------------------------------------------------------------------------------------
def expose(a) -> dict:
    plan = Plan(a.dry_run)
    state = load_state()
    if not state and not a.dry_run:
        raise SetupError("run install first")
    port = state.get("port") or DEFAULT_PORT
    local = "http://127.0.0.1:%d" % port
    if a.via == "url":
        if not a.url or not a.url.startswith("https://") and not a.allow_http:
            raise SetupError("--url must be an https:// address that reaches this bridge (a reverse proxy or named tunnel)")
        url = a.url.rstrip("/")
        warnings = []
    elif a.via == "tailscale":
        code, out = sh(["tailscale", "status", "--json"])
        if code != 0:
            raise SetupError("Tailscale is not running here (tailscale up)")
        st = json.loads(out)
        dns = ((st.get("Self") or {}).get("DNSName") or "").rstrip(".")
        if not st.get("CertDomains"):
            raise SetupError("HTTPS certificates are off in this tailnet: turn on MagicDNS and HTTPS in the Tailscale admin "
                             "console (DNS page), then run this again")
        r = plan.run(["tailscale", "serve", "--bg", "--https=%d" % port, local], check=False)
        if r.returncode != 0:
            err = (r.stderr or r.stdout or "").strip()
            hint = " Run once: sudo tailscale set --operator=$USER" if "denied" in err.lower() or "operator" in err.lower() else ""
            raise SetupError("tailscale serve failed: %s%s" % (err[-400:], hint))
        url = "https://%s%s" % (dns, "" if port == 443 else ":%d" % port)
        warnings = ["Only devices signed in to the same tailnet can reach it: install Tailscale on the phone and sign in "
                    "with the same account."]
    else:
        exe = shutil.which("cloudflared") or str(home() / "bin" / "cloudflared")
        if not Path(exe).exists():
            if not a.download:
                raise SetupError("cloudflared is not installed; run again with --download to fetch Cloudflare's official build")
            arch = {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine(), "amd64")
            plan.steps.append("download %s → %s" % (CLOUDFLARED_URL % arch, exe))
            if not a.dry_run:
                Path(exe).parent.mkdir(parents=True, exist_ok=True)
                urllib.request.urlretrieve(CLOUDFLARED_URL % arch, exe)
                os.chmod(exe, 0o755)
        unit = """[Unit]
Description=Tove bridge quick tunnel (Cloudflare; temporary address)
After=network-online.target

[Service]
ExecStart=%s tunnel --no-autoupdate --url %s
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
""" % (exe, local)
        plan.write(Path(os.path.expanduser("~/.config/systemd/user")) / (TUNNEL_UNIT + ".service"), unit)
        plan.run(["systemctl", "--user", "daemon-reload"])
        plan.run(["systemctl", "--user", "enable", "--now", TUNNEL_UNIT])
        url = "https://<random>.trycloudflare.com" if a.dry_run else tunnel_url()
        warnings = ["Quick tunnels are for trying Tove out: Cloudflare gives no uptime guarantee and they do not support "
                    "streaming (Server-Sent Events), so replies may arrive all at once and instant notifications may not "
                    "work.", "The address changes whenever the tunnel restarts (a reboot, for example); then ask Hermes "
                    "to pair Tove again. For daily use, choose Tailscale or your own domain."]
    status = http_status(url + "/healthz") if not a.dry_run and a.via != "tailscale" else None
    state.update(public_url=url, via=a.via)
    save_state(plan, state)
    return {"ok": True, "dry_run": a.dry_run, "url": url, "via": a.via, "reachable_from_here": status == 200 if status else None,
            "warnings": warnings, "steps": plan.steps}


def tunnel_url(seconds=40):
    end = time.time() + seconds
    while time.time() < end:
        _, out = sh(["journalctl", "--user", "-u", TUNNEL_UNIT, "-n", "80", "--no-pager", "-o", "cat"])
        found = re.findall(r"https://[a-z0-9-]+\.trycloudflare\.com", out)
        if found:
            return found[-1]
        time.sleep(2)
    raise SetupError("the quick tunnel did not report its address (journalctl --user -u %s)" % TUNNEL_UNIT)


# ---------------------------------------------------------------------------------------------------------------
# pair
# ---------------------------------------------------------------------------------------------------------------
def pair(a) -> dict:
    state = load_state()
    url = (a.url or state.get("public_url") or "").rstrip("/")
    if not url:
        raise SetupError("no address for the phone yet: run expose first, or pass --url")
    png = Path(a.png).expanduser().resolve() if a.png else home() / "pair-qr.png"
    args = ["--url", url, "--json", "--name", a.name or socket.gethostname()]
    if state.get("mode") == "docker":
        cmd = ["docker", "exec", state.get("name", NAME), "python", "/app/tove_pair.py"] + args + ["--png", "/data/pair-qr.png"]
    elif state.get("mode") == "venv":
        py = home() / "venv" / "bin" / "python"
        cmd = [str(py), str(Path(state["server"]) / "tove_pair.py"), "--data-dir", state["data_dir"]] + args + ["--png", str(png)]
    else:
        raise SetupError("run install first")
    code, out = sh(cmd, timeout=30)
    if code != 0:
        raise SetupError("could not make a pairing code: " + out[-400:])
    r = json.loads(out.splitlines()[-1])
    if state.get("mode") == "docker" and r.get("png"):
        src = Path(state["data_dir"]) / "pair-qr.png"
        if src != png and src.exists():
            shutil.copyfile(src, png)
        r["png"] = str(png) if png.exists() else str(src)
    if a.human:
        print(r.pop("terminal_qr") or "")
        print("\nIn the Tove app tap Scan QR code, or Enter code and type:\n  Server address: %s\n  Pairing code:   %s\n"
              "The code works once, for 10 minutes." % (r["url"], r["code"]))
        if r.get("png"):
            print("QR image: " + r["png"])
        return None
    return r


# ---------------------------------------------------------------------------------------------------------------
# status / uninstall
# ---------------------------------------------------------------------------------------------------------------
def places(a) -> dict:
    """Extracts Overture Maps Places for an area into the bridge's data dir (places_fetch.py, DuckDB in its own
    venv), and gives the bridge a tools key for Hermes' places_search plugin. The bridge picks the database up at
    once. Installing the plugin into Hermes changes Hermes' plugins and .env, so the steps are returned, not run."""
    plan = Plan(a.dry_run)
    state = load_state()
    if not state:
        raise SetupError("Tove is not installed here yet: run install first.")
    det = detect()
    server, data = Path(state["server"]), Path(state["data_dir"])
    venv = home() / "places-venv"
    py = det["python"] or sys.executable
    if not (venv / "bin" / "python").exists() or a.dry_run:
        made = plan.run([py, "-m", "venv", str(venv)], check=False)
        if made.returncode != 0:
            if not det["uv"]:
                raise SetupError("python -m venv failed (on Debian/Ubuntu: sudo apt install python3-venv)")
            if venv.exists():
                shutil.rmtree(venv)
            plan.run(["uv", "venv", "-q", "-p", py, str(venv)])
    if (venv / "bin" / "pip").exists() or plan.dry_run:
        plan.run([venv / "bin" / "pip", "install", "-q", "--only-binary=:all:", "duckdb"], timeout=1800)
    else:
        plan.run(["uv", "pip", "install", "-q", "--python", venv / "bin" / "python", "duckdb"], timeout=1800)
    where = (["--area", a.area] if a.area else ["--bbox", a.bbox] if a.bbox else ["--country", a.country])
    plan.run([venv / "bin" / "python", server / "places_fetch.py", *where, "--out", data / "places.sqlite"], timeout=7200)
    env_file = Path(state["env_file"])
    env = read_env_file(env_file.read_text()) if env_file.exists() else {}
    tools_key = env.get("TOVE_TOOLS_KEY") if len(env.get("TOVE_TOOLS_KEY", "")) >= 24 else secrets.token_urlsafe(32)
    if env.get("TOVE_TOOLS_KEY") != tools_key:
        if not plan.dry_run:
            text = env_file.read_text().rstrip("\n") + "\nTOVE_TOOLS_KEY=%s\n" % tools_key
            plan.write(env_file, text, 0o600)
        else:
            plan.steps.append("add TOVE_TOOLS_KEY to %s" % env_file)
        name = state.get("name", NAME)
        if state.get("mode") == "docker":
            plan.steps.append("recreate the container to load TOVE_TOOLS_KEY (run install again)")
        else:
            plan.run(["systemctl", "--user", "restart", name])
    bridge_url = state.get("public_url") or state.get("local_url")
    return {"ok": True, "dry_run": a.dry_run, "database": str(data / "places.sqlite"), "steps": plan.steps,
            "hermes_plugin": {
                "copy": "%s → Hermes' plugins directory as places/ (container: /opt/data/plugins/places)" % (server / "hermes-places"),
                "hermes_env": {"TOVE_BRIDGE_URL": bridge_url, "TOVE_TOOLS_KEY": "<the value in %s>" % env_file},
                "enable": "hermes plugins enable places (as Hermes' user; new sessions get the tool)",
                "note": "Hermes reads .env at start: adding the two lines needs a Hermes restart. Ask first."}}


def status(_a) -> dict:
    state = load_state()
    if not state:
        return {"installed": False}
    local = state.get("local_url")
    pub = state.get("public_url")
    return {"installed": True, **{k: state.get(k) for k in ("mode", "name", "port", "via", "public_url", "data_dir")},
            "healthy": http_status(local + "/healthz") == 200 if local else False,
            "public_reachable_from_here": (http_status(pub + "/healthz") == 200) if pub and "<" not in pub else None}


def uninstall(a) -> dict:
    plan = Plan(a.dry_run)
    state = load_state()
    name = state.get("name", NAME)
    if state.get("mode") == "docker":
        plan.run(["docker", "rm", "-f", name], check=False)
    elif state.get("mode") == "venv":
        plan.run(["systemctl", "--user", "disable", "--now", name], check=False)
        unit = Path(os.path.expanduser("~/.config/systemd/user")) / (name + ".service")
        plan.steps.append("remove " + str(unit))
        if not a.dry_run and unit.exists():
            unit.unlink()
    if state.get("via") == "cloudflare":
        plan.run(["systemctl", "--user", "disable", "--now", TUNNEL_UNIT], check=False)
    if state.get("via") == "tailscale":
        plan.run(["tailscale", "serve", "--https=%d" % state.get("port", DEFAULT_PORT), "off"], check=False)
    if state.get("mode") == "venv" or state.get("via") == "cloudflare":
        plan.run(["systemctl", "--user", "daemon-reload"], check=False)
    root = home()
    keep = {"data"} if a.keep_data else set()
    plan.steps.append("remove %s%s" % (root, " (keeping data/)" if keep else ""))
    if not a.dry_run and root.exists():
        for child in root.iterdir():
            if child.name in keep:
                continue
            shutil.rmtree(child) if child.is_dir() and not child.is_symlink() else child.unlink()
        if not keep:
            root.rmdir()
    return {"ok": True, "dry_run": a.dry_run, "steps": plan.steps}


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("detect")
    i = sub.add_parser("install")
    i.add_argument("--mode", choices=("docker", "venv"))
    i.add_argument("--source", help="a local Tove checkout (default: download the main branch from GitHub)")
    i.add_argument("--port", type=int)
    i.add_argument("--name", help="container or systemd unit name (default tove-bridge)")
    i.add_argument("--data-dir")
    i.add_argument("--hermes-url", help="Hermes' API as the bridge reaches it (default: detected)")
    i.add_argument("--hermes-key", help="Hermes' API_SERVER_KEY (default: read from Hermes' .env)")
    i.add_argument("--assistant-name")
    i.add_argument("--enable-hermes-api", action="store_true", help="turn Hermes' API server on (asks nothing; confirm first)")
    i.add_argument("--no-codex", action="store_true", help="Docker: build without the Codex CLI (no ChatGPT-login voice)")
    i.add_argument("--dry-run", action="store_true")
    e = sub.add_parser("expose")
    e.add_argument("--via", choices=("tailscale", "cloudflare", "url"), required=True)
    e.add_argument("--url")
    e.add_argument("--allow-http", action="store_true", help=argparse.SUPPRESS)
    e.add_argument("--download", action="store_true", help="cloudflare: download cloudflared if it is missing")
    e.add_argument("--dry-run", action="store_true")
    q = sub.add_parser("pair")
    q.add_argument("--url", help="the address the phone uses (default: from expose)")
    q.add_argument("--png")
    q.add_argument("--name", help="server name shown in the app (default: this host's name)")
    q.add_argument("--human", action="store_true", help="print the QR code for a terminal")
    pl = sub.add_parser("places")
    where = pl.add_mutually_exclusive_group(required=True)
    where.add_argument("--area", help='a named area, e.g. "Chennai, India"')
    where.add_argument("--bbox", help="west,south,east,north in degrees")
    where.add_argument("--country", help="ISO country code (large; slow)")
    pl.add_argument("--dry-run", action="store_true")
    sub.add_parser("status")
    u = sub.add_parser("uninstall")
    u.add_argument("--keep-data", action="store_true")
    u.add_argument("--dry-run", action="store_true")
    a = p.parse_args(argv)
    try:
        out = {"detect": lambda _: public(detect()), "install": install, "expose": expose, "pair": pair,
               "status": status, "uninstall": uninstall, "places": places}[a.cmd](a)
    except SetupError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}))
        return 1
    if out is not None:
        print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
