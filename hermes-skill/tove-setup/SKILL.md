---
name: tove-setup
description: "Connect the Tove phone app to this Hermes Agent."
version: 1.0.0
author: itskavin (https://github.com/itskavin), Hermes Agent
license: GPL-3.0-or-later
platforms: [linux]
metadata:
  hermes:
    tags: [tove, mobile, app, pairing, qr, bridge, voice]
    category: productivity
    homepage: https://github.com/itskavin/tove
---

# Tove Setup Skill

Installs the Tove bridge next to this Hermes Agent, gives it a private address the user's phone can reach, and shows
a QR code that the Tove app scans to connect. Tove is a chat and voice app for Hermes; the bridge is its small server.
This skill does not install Hermes, and it never restarts Hermes without asking.

## When to Use

- The user says "set up Tove", "connect my phone", "pair the Tove app", "install the Tove bridge".
- The user asks to pair another phone or says the app lost its connection ("pair Tove again"): skip to step 5.
- The user asks whether Tove is running: `status` only.

## Prerequisites

- Linux, with either Docker or Python 3.11+ and systemd user services, on the machine where `terminal` runs.
- Hermes' API server. If it is off, the script says so and step 3 turns it on (with the user's consent).
- For a private address: Tailscale on this machine and the phone. Otherwise a Cloudflare quick tunnel (temporary).

## How to Run

All steps use one helper, run with `terminal`: `python3 SKILL_DIR/scripts/tove_setup.py <command>` (SKILL_DIR is
this skill's directory; use its absolute path). Every command prints JSON. `--dry-run` shows the plan and changes
nothing.

## Quick Reference

| Command | Does |
|---|---|
| `detect` | What is here (Hermes, Docker, Python, Tailscale). Changes nothing |
| `install [--mode docker\|venv] [--enable-hermes-api]` | Installs and starts the bridge with a new access key |
| `expose --via tailscale` / `--via cloudflare --download` / `--via url --url https://...` | Gives the phone an address |
| `pair --png <file>` | One-time pairing code and QR code (one use, 10 minutes) |
| `status`, `uninstall [--keep-data]` | Check, or remove everything this skill made |

## Procedure

1. **Look.** Run `detect`. If it reports `blocker`, explain it in plain words and stop (the README's "Install by
   hand" section is the way out). If `state` shows Tove is already installed, offer to pair again (step 5).
2. **Explain the choice of address** before installing, in plain words, and let the user pick:
   - **Tailscale (recommended)**: private; only the user's own devices can reach Tove, from anywhere. Needs the free
     Tailscale app on the phone, signed in to the same account. Offer it when `tailscale.running` is true; if
     `tailscale.https` is false, they must first turn on HTTPS in the Tailscale admin console (DNS page).
   - **Their own HTTPS address** (a domain with a reverse proxy, or a named Cloudflare Tunnel): if they have one.
   - **Cloudflare quick tunnel**: works anywhere with no account, but only for trying Tove: the address changes when
     this machine restarts, replies may arrive all at once (no streaming), and notifications may not work.
   - Same Wi-Fi only is not offered: the app needs HTTPS, and a plain home-network address has none.
3. **Hermes' API server.** If `hermes.api_key_set` is false (or `api_host_needs_change` is true), tell the user Tove
   talks to Hermes through Hermes' API server, which must be switched on and needs Hermes to restart once. Only after
   they agree, add `--enable-hermes-api` in step 4.
4. **Install.** `install` (add `--mode` only if the user prefers Docker or not). It generates the access key
   itself; never print or repeat that key. Report `ok`, and keep `hermes_restart_command` for step 6.
5. **Address and pairing.** `expose --via <choice>` (cloudflare needs `--download` if `cloudflared` is missing; ask
   first, it downloads Cloudflare's official build). Pass on its `warnings`. Then
   `pair --png ~/tove-pair.png`, and show the user:
   - the QR code: on a messaging platform send the PNG as `MEDIA:<png path>`; in a terminal, run
     `pair --human` instead so the QR code prints there;
   - the server address and the short code (for typing it in), and that the code works once, for 10 minutes.
   Tell them: download the latest Tove APK from the GitHub Releases page
   (https://github.com/itskavin/tove/releases) and install it, open it, tap **Scan QR code** (or **Enter code or
   address**).
6. **Restart Hermes last**, only if step 4 returned `hermes_restart_command` and the user agreed: say you will be
   gone for a few seconds, then run it. Do this after the QR code is sent, because the restart ends this turn.

## Pitfalls

- Never show, log or send the access key (`LIVE_PAGE_KEY`) or Hermes' `API_SERVER_KEY`. The QR code holds only a
  one-time code; the app fetches the key itself.
- If `terminal` runs on another machine than the gateway (SSH backend), a `MEDIA:` path is not visible to the
  gateway: send the address and code as text, or copy the PNG first.
- `tailscale serve` can fail with "access denied": the user must run `sudo tailscale set --operator=$USER` once.
- A Docker Hermes on its own network listens only inside its container; `--enable-hermes-api` also sets
  `API_SERVER_HOST=0.0.0.0` there (still key-protected and not published to the host's network).
- A code that expired or was used gives "expired" in the app: run `pair` again. Wrong codes are rate-limited.
- Voice calls need a ChatGPT login or an OpenAI key on the bridge; chat works without. See the Tove README.

## Verification

- `status` shows `healthy: true` and the chosen `public_url`.
- After the user scans the code, the app opens the chat. A message there reaches Hermes.
