"""image-search: an ``image_search`` tool backed by your own SearXNG (``categories=images``).

Hermes' built-in ``web_search`` only returns SearXNG's general results, so the agent never saw a real image URL
unless it happened to extract a page. This tool returns what the image engines actually reported: the image URL,
the page it appears on, that page's title and publisher, and the declared resolution. Nothing is invented,
rewritten or fetched here; showing the picture is left to the client (the Tove app fetches it through its bridge,
which validates the bytes). Rows without both a public http(s) image URL and a source page are dropped, so every
image the model can cite has a page to attribute it to.

Stdlib only; reads ``SEARXNG_URL`` from the environment, as the bundled SearXNG web provider does.
"""

from __future__ import annotations

import json
import logging
import os
import re
import urllib.error
import urllib.parse
import urllib.request

_log = logging.getLogger("hermes.plugins.image-search")

LIMIT_DEFAULT, LIMIT_MAX = 6, 10
TIMEOUT_S = 15
URL_MAX = 2048
MIN_SIDE = 160            # declared resolution below this on the short side: an icon or a tracking pixel
LARGE_SIDE = 3000         # declared long side above this: usually several MB, often too big for a phone client
# Stock-photo previews are watermarked and the pages sell licences; they are rarely what a user wants to see.
# Crawler endpoints that engines list as images but that answer with an HTML page (checked 16 November 2026).
PAGE_HOSTS = ("lookaside.fbsbx.com", "lookaside.instagram.com")
# Formats a phone client cannot show (or that are scriptable). Wikimedia SVGs are fine: the Tove bridge asks for
# Wikimedia's PNG rendering of them.
UNSHOWABLE_EXT = (".svg", ".avif", ".heic", ".heif", ".tif", ".tiff")
STOCK_HOSTS = ("istockphoto.com", "gettyimages.com", "shutterstock.com", "alamy.com", "dreamstime.com",
               "depositphotos.com", "123rf.com", "stock.adobe.com", "vectorstock.com", "freepik.com")

SCHEMA = {
    "name": "image_search",
    "description": (
        "Search the web for images (private SearXNG, images category). Returns real image URLs, each with the "
        "page it appears on (source_page), that page's title and publisher, and the declared size. Use it when a "
        "picture would genuinely help the answer (a place, landmark, animal, plant, product, artwork, person in "
        "the news, diagram). Show a result only if its title or source makes it clearly relevant, as "
        "[![short description](image_url)](source_page); never alter or guess an image URL."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "What the images should show, e.g. 'Golden Gate Bridge at dusk'."},
            "limit": {"type": "integer", "minimum": 1, "maximum": LIMIT_MAX,
                      "description": f"How many results to return (default {LIMIT_DEFAULT})."},
        },
        "required": ["query"],
        "additionalProperties": False,
    },
}


def searxng_url() -> str:
    # The container environment, like the bundled SearXNG provider (public plugin surface only, no core imports).
    return os.environ.get("SEARXNG_URL", "").strip().rstrip("/")


def http_url(value):
    """``value`` if it is a plain public-looking http(s) URL (no userinfo, no data:/javascript:), else None.
    Whether the address is actually public is the client's check at fetch time."""
    if not isinstance(value, str):
        return None
    value = value.strip()
    if not value or len(value) > URL_MAX or any(c.isspace() for c in value):
        return None
    if value.startswith("//"):
        value = "https:" + value                       # some engines return protocol-relative URLs
    try:
        u = urllib.parse.urlsplit(value)
        u.port                                          # raises on a malformed port
    except ValueError:
        return None
    if u.scheme not in ("http", "https") or not u.hostname or u.username or u.password:
        return None
    return value


def host_of(url) -> str:
    try:
        host = (urllib.parse.urlsplit(url).hostname or "").lower()
    except ValueError:
        return ""
    return host[4:] if host.startswith("www.") else host


def is_stock(host: str) -> bool:
    return any(host == h or host.endswith("." + h) for h in STOCK_HOSTS)


_SIZE = re.compile(r"(\d{1,5})\s*[x×X*]\s*(\d{1,5})")


def declared_size(resolution):
    m = _SIZE.search(resolution) if isinstance(resolution, str) else None
    if not m:
        return None, None
    w, h = int(m.group(1)), int(m.group(2))
    return (w, h) if w > 0 and h > 0 else (None, None)


def clean(value, limit):
    if not isinstance(value, str):
        return ""
    return re.sub(r"\s+", " ", value).strip()[:limit]


def normalize(raw_results, limit):
    """SearXNG image rows -> at most ``limit`` deduplicated rows that each have an image URL and a source page."""
    rows, seen = [], set()
    for r in raw_results if isinstance(raw_results, list) else []:
        if not isinstance(r, dict):
            continue
        image, page = http_url(r.get("img_src")), http_url(r.get("url"))
        if not image or not page or image in seen:
            continue
        ihost, phost = host_of(image), host_of(page)
        if is_stock(ihost) or is_stock(phost) or ihost in PAGE_HOSTS:
            continue
        path = urllib.parse.urlsplit(image).path.lower()
        if path.endswith(UNSHOWABLE_EXT) and ihost != "upload.wikimedia.org":
            continue
        w, h = declared_size(r.get("resolution"))
        if w and h and min(w, h) < MIN_SIDE:
            continue
        seen.add(image)
        rows.append({
            "title": clean(r.get("title"), 200) or phost,
            "image_url": image,
            "source_page": page,
            "source": clean(r.get("source"), 80) or phost,
            "width": w, "height": h,
            "engine": clean(r.get("engine"), 40),
            "_large": bool(w and h and max(w, h) > LARGE_SIDE),
        })
    # Keep SearXNG's relevance order, but move very large originals after the rest (a phone may not load them).
    rows.sort(key=lambda row: row["_large"])
    out = []
    for i, row in enumerate(rows[:limit], 1):
        row.pop("_large")
        out.append({"position": i, **row})
    return out


def fetch_json(url, timeout=TIMEOUT_S):
    req = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "hermes-image-search"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:   # SearXNG on the private search network
        return json.loads(resp.read(4 * 1024 * 1024).decode("utf-8", "replace"))


def handle_image_search(args, **_kw) -> str:
    args = args if isinstance(args, dict) else {}
    query = clean(args.get("query"), 300)
    if not query:
        return json.dumps({"success": False, "error": "query is required"})
    try:
        limit = max(1, min(LIMIT_MAX, int(args.get("limit") or LIMIT_DEFAULT)))
    except (TypeError, ValueError):
        limit = LIMIT_DEFAULT
    base = searxng_url()
    if not base:
        return json.dumps({"success": False, "error": "SEARXNG_URL is not set"})
    params = urllib.parse.urlencode({"q": query, "format": "json", "categories": "images", "safesearch": 1, "pageno": 1})
    try:
        data = fetch_json(f"{base}/search?{params}")
    except urllib.error.HTTPError as exc:
        _log.warning("image search: SearXNG HTTP %s", exc.code)
        return json.dumps({"success": False, "error": f"SearXNG returned HTTP {exc.code}"})
    except (urllib.error.URLError, OSError, ValueError) as exc:
        _log.warning("image search failed: %s", type(exc).__name__)
        return json.dumps({"success": False, "error": "image search is unavailable right now"})
    results = normalize(data.get("results") if isinstance(data, dict) else None, limit)
    _log.info("image search: %d results", len(results))
    out = {"success": True, "query": query, "results": results}
    if results:
        out["note"] = ("Show only results that clearly match; copy image_url and source_page exactly, as "
                       "[![short description](image_url)](source_page), as <img src=\"image_url\"> in a hermes-html "
                       "layout, or as the image field of an entities/news item. Never shorten, resize or guess a URL.")
    else:
        out["note"] = "No usable images were found; answer without images."
    return json.dumps(out, ensure_ascii=False)


def check_image_search() -> bool:
    return bool(searxng_url())


def register(ctx) -> None:
    # The "web" toolset, so the tool is offered exactly where web search is.
    ctx.register_tool(name="image_search", toolset="web", schema=SCHEMA, handler=handle_image_search,
                      check_fn=check_image_search, emoji="🖼️",
                      description="Image search via the private SearXNG")
