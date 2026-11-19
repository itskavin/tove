"""places: a ``places_search`` tool backed by the Tove bridge's open places service (POST /api/places/search).

Hermes' web search finds pages about places, not the places themselves: no reliable phone numbers, positions or
opening hours. The bridge answers from a local extract of Overture Maps Places (open data, no API key) and adds
OpenStreetMap details (opening hours, wheelchair access, a photo) for the results. Each result carries a stable
``place:`` id; the Tove app turns ``Place("place:…", …)`` into a card with Call, Directions and Website, and
``Map([...])`` into pins. There are no ratings in open data: the model takes them from listing pages it finds with
web search and names their source.

Stdlib only. Environment (Hermes' .env): ``TOVE_BRIDGE_URL`` (the bridge's base URL as Hermes can reach it, e.g.
``http://host.docker.internal:8787``) and ``TOVE_TOOLS_KEY`` (the same value as in the bridge's bridge.env). Without
them the tool is not offered and Hermes keeps using web search.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request

_log = logging.getLogger("hermes.plugins.places")

TIMEOUT_S = 20
MAX_DEFAULT, MAX_LIMIT = 5, 10

SCHEMA = {
    "name": "places_search",
    "description": (
        "Find real local places (clinics, doctors, restaurants, cafes, shops, services) near a location from open map "
        "data: name, category, address, distance, phone, website, opening hours when known, and a stable id. Use it "
        "for any 'find', 'near me', 'best … in <area>' or local recommendation, with the user's approximate location "
        "as near. query = what the place is (a category or name: 'psychiatrist', 'dental clinic', 'biryani'); call it "
        "again with another word when results are thin. No ratings: take ratings, reviews and prices from listing "
        "pages found with web search and name the source."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "What the place is, e.g. 'psychiatrist' or 'biryani restaurant'."},
            "near": {"type": "string", "description": "'lat,lng' (preferred) or an area name, e.g. 'Mylapore, Chennai'."},
            "radius_m": {"type": "integer", "minimum": 500, "maximum": 50000, "description": "Search bias radius in metres (default 5000)."},
            "max": {"type": "integer", "minimum": 1, "maximum": MAX_LIMIT, "description": f"How many results (default {MAX_DEFAULT})."},
        },
        "required": ["query"],
        "additionalProperties": False,
    },
}


def config():
    return os.environ.get("TOVE_BRIDGE_URL", "").strip().rstrip("/"), os.environ.get("TOVE_TOOLS_KEY", "").strip()


def call_bridge(base, key, body, timeout=TIMEOUT_S):
    req = urllib.request.Request(base + "/api/places/search", data=json.dumps(body).encode(), method="POST",
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json",
                                          "User-Agent": "hermes-places"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read(1024 * 1024).decode("utf-8", "replace"))


FALLBACK = "Use web_search instead (search for the places, then open their pages for phone, price and hours)."


def handle_places_search(args, **_kw) -> str:
    args = args if isinstance(args, dict) else {}
    query = str(args.get("query") or "").strip()[:200]
    if not query:
        return json.dumps({"success": False, "error": "query is required"})
    base, key = config()
    if not base or not key:
        return json.dumps({"success": False, "error": "places search is not configured", "note": FALLBACK})
    body = {"query": query}
    for name in ("near", "radius_m", "max"):
        if args.get(name) not in (None, ""):
            body[name] = args[name]
    try:
        data = call_bridge(base, key, body)
    except urllib.error.HTTPError as exc:
        try:
            err = json.loads(exc.read(65536).decode("utf-8", "replace"))
        except (ValueError, OSError):
            err = {}
        code = err.get("code") or "http_%d" % exc.code
        _log.warning("places search: bridge HTTP %s (%s)", exc.code, code)
        return json.dumps({"success": False, "error": err.get("message") or code, "code": code, "note": FALLBACK})
    except (urllib.error.URLError, OSError, ValueError) as exc:
        _log.warning("places search failed: %s", type(exc).__name__)
        return json.dumps({"success": False, "error": "places search is unavailable right now", "note": FALLBACK})
    places = data.get("places") if isinstance(data, dict) else None
    out = {"success": True, "query": query, "near": body.get("near"), "places": places or []}
    if places:
        out["note"] = ('Show 3+ as openui Places([Place("<id>", "<name>", "<subtitle>", "<short fact>", "<rating>", '
                       '"<rating source>")…]) then Map([same refs]); the app loads phone, website, hours and position '
                       "from the id. Copy ids exactly. Find each one's rating and price on a listing page (Practo, "
                       "Justdial, Zomato, its own site) and give it with that source; never invent a rating. Say what "
                       "is unverified.")
    else:
        out["note"] = "No places found. Try a broader query or area, or " + FALLBACK
    return json.dumps(out, ensure_ascii=False)


def check_places_search() -> bool:
    base, key = config()
    return bool(base and key)


def register(ctx) -> None:
    # The "web" toolset, so it is offered exactly where web search is.
    ctx.register_tool(name="places_search", toolset="web", schema=SCHEMA, handler=handle_places_search,
                      check_fn=check_places_search, emoji="📍",
                      description="Local places via the Tove bridge (open map data)")
