#!/usr/bin/env python3
"""Make a one-time pairing code for the Tove app (API.md "Pairing").

    python tove_pair.py --url https://bridge.example.ts.net:8787            # prints a QR code, the link and the code
    python tove_pair.py --url https://... --png pair.png --json             # for scripts (the tove-setup skill)
    docker exec tove-bridge python /app/tove_pair.py --url https://...      # the bridge in Docker

The app scans the QR code (or the user types the address and the short code); it then calls POST /api/pair with the
code and receives the bridge's access key. A code works once and for 10 minutes. The long-lived key never appears in
the QR code, the link or this script's output.

Codes are kept in <BRIDGE_DATA_DIR>/pairing.json (mode 600) as SHA-256 hashes only, so the running bridge and this
script share nothing but that file. Standard library only; the QR code needs `segno` (in requirements.txt), or
`qrcode` as a fallback. Without either, the link and code are still printed.
"""
import argparse, hashlib, json, os, secrets, sys, tempfile, time, urllib.parse
from pathlib import Path

ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"   # 32 symbols: no 0/O, 1/I, so codes survive being read out loud
CODE_LEN = 10                                     # 50 bits; with the bridge's attempt limit, guessing is hopeless
TTL_S = 600
KEEP = 8                                          # entries kept in the file (used and expired ones answer "expired")
PAIR_FILE = "pairing.json"


def data_dir(env=None) -> Path:
    env = os.environ if env is None else env
    xdg = env.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return Path(os.path.expanduser(env.get("BRIDGE_DATA_DIR") or os.path.join(xdg, "gpt-live-bridge")))


def normalize(code: str) -> str:
    """What the user typed → the canonical code: upper case, separators and spaces dropped."""
    return "".join(ch for ch in str(code or "").upper() if ch.isalnum())


def code_hash(code: str) -> str:
    return hashlib.sha256(("tove-pair:" + normalize(code)).encode()).hexdigest()


def new_code() -> str:
    return "".join(secrets.choice(ALPHABET) for _ in range(CODE_LEN))


def pretty(code: str) -> str:
    c = normalize(code)
    return c[:5] + "-" + c[5:] if len(c) == CODE_LEN else c


def read_entries(path: Path) -> list:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return []
    entries = data.get("codes") if isinstance(data, dict) else None
    return [e for e in entries if isinstance(e, dict) and isinstance(e.get("sha256"), str)] if isinstance(entries, list) else []


def write_entries(path: Path, entries: list) -> None:
    """Atomic, mode 600 (the file only holds hashes, but nobody else needs to read it)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".pairing-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as f:
            json.dump({"version": 1, "codes": entries[-KEEP:]}, f)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def create(directory: Path, ttl_s: int = TTL_S, now: float = None) -> dict:
    now = time.time() if now is None else now
    code = new_code()
    path = Path(directory) / PAIR_FILE
    entries = [e for e in read_entries(path) if float(e.get("expires_at") or 0) > now - 86400]
    entries.append({"sha256": code_hash(code), "created_at": int(now), "expires_at": int(now + ttl_s), "used_at": None})
    write_entries(path, entries)
    return {"code": code, "expires_at": int(now + ttl_s)}


def pair_link(url: str, code: str, name: str = "") -> str:
    query = {"u": url, "c": pretty(code)}
    if name:
        query["n"] = name
    return "tove://pair?" + urllib.parse.urlencode(query, quote_via=urllib.parse.quote)


def qr_matrix(text: str):
    """Rows of booleans (True = dark), quiet zone included; None when no QR library is installed."""
    try:
        import segno
        qr = segno.make(text, error="m", micro=False)
        return [[bool(v) for v in row] for row in qr.matrix_iter(scale=1, border=2)]
    except ImportError:
        pass
    try:
        import qrcode
        qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, border=2)
        qr.add_data(text)
        qr.make(fit=True)
        return [[bool(v) for v in row] for row in qr.get_matrix()]
    except ImportError:
        return None


def qr_terminal(matrix) -> str:
    """Two rows per line with half blocks. Light modules are drawn, dark ones are the terminal's background (like
    `qrencode -t UTF8`), so it is a normal QR code on a dark terminal; on a light one, use the PNG."""
    lines = []
    for y in range(0, len(matrix), 2):
        top, bottom = matrix[y], matrix[y + 1] if y + 1 < len(matrix) else [False] * len(matrix[y])
        lines.append("".join(" " if t and b else "▄" if t else "▀" if b else "█" for t, b in zip(top, bottom)))
    return "\n".join(lines)


def qr_png(matrix, path: Path, scale: int = 10) -> None:
    """A black-on-white PNG, written with zlib only (no Pillow)."""
    import struct, zlib
    size = len(matrix) * scale
    raw = bytearray()
    for row in matrix:
        line = bytearray([0])                       # filter: none
        for dark in row:
            line += (b"\x00" if dark else b"\xff") * scale
        raw += bytes(line) * scale

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 0, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def main(argv=None):
    p = argparse.ArgumentParser(description="Make a one-time pairing code for the Tove app.")
    p.add_argument("--url", required=True, help="the bridge's address as the phone reaches it (https://...)")
    p.add_argument("--name", default="", help="a name for this server, shown in the app")
    p.add_argument("--data-dir", help="the bridge's data directory (default: BRIDGE_DATA_DIR)")
    p.add_argument("--png", help="also write the QR code to this PNG file")
    p.add_argument("--ttl", type=int, default=TTL_S, help="seconds the code works (default 600)")
    p.add_argument("--json", action="store_true", help="print JSON instead of the QR code")
    a = p.parse_args(argv)
    parsed = urllib.parse.urlparse(a.url)
    if parsed.scheme not in ("https", "http") or not parsed.hostname:
        p.error("--url must be the bridge's full address, such as https://tove.example.com")
    if not 60 <= a.ttl <= 3600:
        p.error("--ttl must be between 60 and 3600 seconds")
    made = create(Path(a.data_dir) if a.data_dir else data_dir(), a.ttl)
    link = pair_link(a.url.rstrip("/"), made["code"], a.name)
    matrix = qr_matrix(link)
    png = None
    if a.png and matrix:
        png = str(Path(a.png).resolve())
        qr_png(matrix, Path(png))
    out = {"code": pretty(made["code"]), "link": link, "url": a.url.rstrip("/"), "expires_at": made["expires_at"],
           "expires_in_s": a.ttl, "png": png, "qr": bool(matrix)}
    if a.json:
        out["terminal_qr"] = qr_terminal(matrix) if matrix else None
        print(json.dumps(out))
        return 0
    if matrix:
        print(qr_terminal(matrix))
    else:
        print("(install segno for a QR code: pip install segno)")
    print("\nScan this with the Tove app, or enter:\n  Server address: %s\n  Pairing code:   %s\n" % (out["url"], out["code"]))
    print("The code works once, for %d minutes." % (a.ttl // 60))
    if png:
        print("QR code image: " + png)
    return 0


if __name__ == "__main__":
    sys.exit(main())
