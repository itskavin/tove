# Tove bridge

The bridge is the small Python server between the Tove app and your own Hermes Agent. It keeps the chat history,
forwards chats to Hermes' API server, stores attachments, serves the web app, and brokers GPT-Live voice sessions.
The app talks only to the bridge; every credential stays here.

- **Let Hermes set it up:** the `tove-setup` skill in [../hermes-skill/](../hermes-skill/) installs the bridge,
  gives it an address and shows a pairing QR code.
- **Set it up by hand:** [SELF-HOSTING.md](SELF-HOSTING.md) (Docker or a Python 3.12 virtual environment, TLS, voice
  backends, attachments, notifications, upgrades, backups, troubleshooting).
- **Configure it:** [bridge.env.example](bridge.env.example) lists every setting with its default.
- **Build a client:** [API.md](API.md) is the wire contract between the app and the bridge.

## Files

| File | What it is |
| --- | --- |
| `gpt-live-bridge.py` | The bridge: one aiohttp server, no framework. Settings come from the environment (`bridge.env`). |
| `requirements.txt` | Pinned Python dependencies (aiohttp, aiortc, av, numpy). |
| `Dockerfile`, `compose.example.yaml` | Container image (optionally with the Codex CLI) and an example Compose file. |
| `bridge.env.example` | Every setting, documented. Copy to `bridge.env` (gitignored, mode 600). |
| `*-prompt.md` | System-prompt sections the bridge sends to Hermes for app requests (rich replies). A copy in the data directory overrides the shipped one. |
| `hermes-live.html` | A minimal browser page for live voice, served at `/`. |
| `tove_pair.py` | Makes a one-time pairing code and its QR code for the app (API.md "Pairing"). Standard library plus `segno` for the QR code. |
| `deploy-app.py` | Copies a built web app and/or APK into the data directory, where the bridge serves them at `/app/` and `/downloads/hermes-live.apk`. |
| `cleanup-voice-fragments.py` | One-off migration for voice chats saved by app builds from before 16 November 2026 (SELF-HOSTING.md §6). |
| `hermes-image-search/` | Optional Hermes plugin: an `image_search` tool backed by your own SearXNG. |
| `hermes-places/` | Optional Hermes plugin: a `places_search` tool answered by the bridge from open map data (SELF-HOSTING.md "Local places"). |
| `places_fetch.py` | Extracts Overture Maps Places for an area into `<data>/places.sqlite` (needs DuckDB, this script only). |
| `eval/` | Answer-quality eval: realistic questions sent through a scratch bridge to a real Hermes, scored by an LLM judge. See `eval/README.md`. |
| `fixtures/` | Recorded response shapes (neutral sample data) for the tests. |
| `test_*.py` | Unit tests, against a fake Hermes and a mocked Codex. Nothing calls a real service. |

## Run the tests

```sh
python3.12 -m venv venv
venv/bin/pip install -r requirements.txt
venv/bin/python -m unittest discover -p 'test_*.py'
```

This also runs the image-search plugin's tests. The places tests build a small extract from `fixtures/` and fake
Overpass and Photon on loopback.
