# tove-setup: a Hermes skill that sets up Tove

`tove-setup/` is a [Hermes Agent skill](https://hermes-agent.nousresearch.com/docs/user-guide/features/skills). It
installs the Tove bridge next to Hermes, gives it an address the phone can reach, and shows a QR code that the Tove
app scans to connect. The user never edits a config file or copies a key.

```sh
hermes skills install itskavin/tove/hermes-skill/tove-setup
```

Then ask Hermes "set up Tove". Hermes follows `tove-setup/SKILL.md` and runs `tove-setup/scripts/tove_setup.py`
(Python standard library only) with its `terminal` tool.

## What it does

| Step | Command | What happens |
|---|---|---|
| Look | `detect` | Finds Hermes (native in `~/.hermes`, or a `hermes-agent` container), its API server and key, Docker, Python, systemd, Tailscale and cloudflared. Changes nothing and never prints keys |
| Install | `install [--mode docker\|venv] [--enable-hermes-api]` | Downloads the bridge (`server/` of this repo), writes `~/.local/share/tove/bridge.env` (mode 600) with a new 43-character access key, and starts the bridge on `127.0.0.1:8787`: a hardened container (`--read-only`, no capabilities, your uid) when Hermes runs in Docker, else a virtual environment and a systemd user service `tove-bridge` |
| Hermes' API | (part of install) | Only with `--enable-hermes-api`, which the skill adds after the user agrees: appends `API_SERVER_KEY` (and, for a container on its own network, `API_SERVER_HOST=0.0.0.0`) to Hermes' `.env`. Hermes is not restarted by the script; the agent restarts it last, after asking |
| Address | `expose --via tailscale\|cloudflare\|url` | `tailscale serve --bg --https=8787` (private to the tailnet), a Cloudflare quick tunnel as a systemd user service `tove-tunnel`, or an HTTPS address the user already has |
| Pair | `pair [--png FILE] [--human]` | Runs the bridge's `tove_pair.py`: a one-time code (10 minutes, one use), a QR code of `tove://pair?u=<address>&c=<code>` for the terminal and as a PNG that Hermes sends with `MEDIA:` on Telegram and its other chats |
| Check, remove | `status`, `uninstall [--keep-data]` | Health of the bridge and the address; removes what the skill made |

Every command prints JSON, and `install`, `expose` and `uninstall` take `--dry-run` to show the plan without changing
anything.

## How the phone reaches the bridge

| Option | Good | Limits |
|---|---|---|
| **Tailscale** (recommended) | Private: only the user's own devices; works from anywhere, behind CGNAT too; real HTTPS certificate | The phone needs the Tailscale app, signed in to the same tailnet. HTTPS must be on in the tailnet's DNS settings. `tailscale serve` may need `sudo tailscale set --operator=$USER` once |
| **Own HTTPS address** (reverse proxy, named Cloudflare Tunnel) | Works on any network, stable | The user needs a domain and a proxy; the bridge is then reachable from the internet (key-protected, pairing rate-limited) |
| **Cloudflare quick tunnel** | No account, no domain, works behind CGNAT | For trying Tove only. Cloudflare says quick tunnels have no uptime guarantee and **do not support Server-Sent Events**, which Tove uses for streaming replies and notifications. The `trycloudflare.com` address changes on every restart, so the phone must pair again |
| Same Wi-Fi only | | **Not offered.** Release builds of the app refuse plain `http://`, and a LAN address has no trusted certificate. Supporting it would need a self-signed certificate pinned through the QR code, in every HTTP client of the app, the native Android notification service included |

## Limits

- Linux only (systemd user services or Docker).
- The script runs where Hermes' `terminal` runs. If that is inside Hermes' own container with no Docker access,
  `detect` reports a `blocker` and the user installs the bridge by hand (README, "Install by hand").
- `install` downloads the main branch from GitHub, so the repository must be public (or the user passes
  `--source` with a local checkout). There is no published container image yet; Docker mode builds one locally,
  which takes a few minutes and includes the Codex CLI for ChatGPT-login voice (`--no-codex` skips it).
- Voice needs a ChatGPT login (`docker exec -it tove-bridge codex login --device-auth`) or an OpenAI key; chat works
  without either.

## Tests

```sh
python3 -m unittest discover -s hermes-skill -p 'test_*.py'
```

No network, nothing installed: `detect` is mocked and `install` runs as `--dry-run`. The bridge side of pairing is
tested in `server/test_pairing.py`.

## Publishing to the Skills Hub (not done yet)

Hermes installs skills from GitHub paths, so once this repository is public the install command above works with no
extra step. To list the skill in registries as well:

1. Check it with Hermes' scanner: `hermes skills inspect itskavin/tove/hermes-skill/tove-setup`, then install it on
   a test machine and run `hermes skills audit`.
2. Keep the frontmatter within the hub's rules: `description` at most 60 characters ending with a period, the human
   author first, `platforms` matching what the scripts use (Linux).
3. Publish with `hermes skills publish hermes-skill/tove-setup --to github --repo <registry repo>` (a pull request to
   a skills registry), or `--to clawhub` for ClawHub. Both need the maintainer's account.
4. For Hermes Desktop users, an install link can be shared:
   `hermes://skill/install?identifier=itskavin%2Ftove%2Fhermes-skill%2Ftove-setup`.

Bump `version` in `SKILL.md` for each change; `hermes skills update` uses it.
