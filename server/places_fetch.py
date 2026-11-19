#!/usr/bin/env python3
"""Extract Overture Maps Places for one area into the bridge's local places database (API.md "Places").

The bridge answers Hermes' places_search tool from this file: no API key, no per-search service, nothing leaves the
server for a search except an optional OpenStreetMap lookup of the few results shown (see the bridge). Run it once at
install (the tove-setup skill does) and again every few months for fresher data.

    pip install duckdb                     # only this script needs it; the bridge reads the result with sqlite3
    python3 places_fetch.py --area "Chennai, India"                  # the area's bounding box from Nominatim
    python3 places_fetch.py --bbox 79.95,12.75,80.35,13.25            # west,south,east,north (degrees)
    python3 places_fetch.py --country IN                              # a whole country (large; slow)
    python3 places_fetch.py --bbox ... --out /path/places.sqlite --release 2026-11-18.0

Data: Overture Maps Foundation, Places theme (https://docs.overturemaps.org/guides/places/). Licences by source:
CDLA-Permissive-2.0 (Meta, Microsoft and others), Apache-2.0 (Foursquare, "Copyright 2024 Foursquare Labs, Inc."),
CC0-1.0 (AllThePlaces). It is read straight from Overture's public S3 bucket (anonymous, no account) with DuckDB's
httpfs extension, using the row groups' bounding-box statistics so only the area's data is downloaded.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import time
import urllib.parse
import urllib.request

BUCKET = "overturemaps-us-west-2"
REGION = "us-west-2"
UA = "ToveBridge/1.0 (self-hosted chat app; places extract)"
ATTRIBUTION = ("Overture Maps Foundation (overturemaps.org): CDLA-Permissive-2.0; includes Foursquare data "
               "(Copyright 2024 Foursquare Labs, Inc., Apache-2.0) and AllThePlaces (CC0-1.0)")
SCHEMA_VERSION = 1


def latest_release():
    """The newest release prefix in the public bucket, e.g. 2026-11-18.0."""
    url = "https://%s.s3.%s.amazonaws.com/?list-type=2&prefix=release/&delimiter=/" % (BUCKET, REGION)
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=30) as r:
        body = r.read().decode()
    releases = sorted(re.findall(r"<Prefix>release/(\d{4}-\d{2}-\d{2}\.\d+)/</Prefix>", body))
    if not releases:
        raise SystemExit("could not list Overture releases")
    return releases[-1]


def area_bbox(query):
    """(west, south, east, north) of a named area from OpenStreetMap Nominatim (one request)."""
    url = "https://nominatim.openstreetmap.org/search?" + urllib.parse.urlencode({"q": query, "format": "jsonv2", "limit": 1})
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=30) as r:
        hits = json.loads(r.read())
    if not hits:
        raise SystemExit("no such area: %s" % query)
    s, n, w, e = (float(x) for x in hits[0]["boundingbox"])
    return w, s, e, n


def parse_bbox(text):
    try:
        w, s, e, n = (float(x) for x in text.split(","))
    except ValueError:
        raise SystemExit("--bbox is west,south,east,north")
    if not (-180 <= w < e <= 180 and -90 <= s < n <= 90):
        raise SystemExit("--bbox is west,south,east,north with west < east and south < north")
    return w, s, e, n


def words(*parts):
    """Search text for the full-text index: category codes become words ("dental_clinic" -> "dental clinic")."""
    out = []
    for p in parts:
        if isinstance(p, (list, tuple)):
            out.extend(str(x) for x in p if x)
        elif p:
            out.append(str(p))
    return " ".join(dict.fromkeys(x.replace("_", " ") for x in out))


def extract(bbox, release, out, country=None, min_confidence=0.3):
    try:
        import duckdb
    except ImportError:
        raise SystemExit("this script needs DuckDB: pip install duckdb")
    w, s, e, n = bbox
    con = duckdb.connect()
    con.execute("INSTALL httpfs; LOAD httpfs; SET s3_region=?;", [REGION])
    where = ["bbox.xmin >= ?", "bbox.xmax <= ?", "bbox.ymin >= ?", "bbox.ymax <= ?", "confidence >= ?",
             "coalesce(operating_status, 'open') = 'open'", "names.primary IS NOT NULL"]
    params = [w, e, s, n, min_confidence]
    if country:
        where.append("addresses[1].country = ?")
        params.append(country.upper())
    sql = """SELECT id, names.primary AS name, taxonomy.primary AS category, basic_category AS basic,
                    taxonomy.hierarchy AS hierarchy, taxonomy.alternates AS alternates, brand.names.primary AS brand,
                    addresses[1].freeform AS address, addresses[1].locality AS locality, addresses[1].region AS region,
                    addresses[1].postcode AS postcode, addresses[1].country AS country,
                    phones, websites, socials, confidence,
                    (bbox.ymin + bbox.ymax) / 2 AS lat, (bbox.xmin + bbox.xmax) / 2 AS lng
             FROM read_parquet('s3://%s/release/%s/theme=places/type=place/*', hive_partitioning = 1)
             WHERE %s""" % (BUCKET, release, " AND ".join(where))
    t0 = time.time()
    rows = con.execute(sql, params).fetchall()
    cols = [d[0] for d in con.description]
    print("read %d places in %.0f s" % (len(rows), time.time() - t0), file=sys.stderr)
    meta = {"release": release, "bbox": [w, s, e, n], "country": country, "min_confidence": min_confidence}
    return write_db((dict(zip(cols, row)) for row in rows), out, meta)


def write_db(rows, out, meta):
    """Writes rows (dicts with the extract's columns) to a new SQLite file at `out`, atomically. Returns the meta."""
    tmp = out + ".tmp"
    if os.path.exists(tmp):
        os.remove(tmp)
    db = sqlite3.connect(tmp)
    db.executescript("""
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE places (id TEXT PRIMARY KEY, name TEXT NOT NULL, category TEXT, basic TEXT, address TEXT,
                             locality TEXT, region TEXT, postcode TEXT, country TEXT, phone TEXT, website TEXT,
                             socials TEXT, brand TEXT, confidence REAL, lat REAL NOT NULL, lng REAL NOT NULL);
        CREATE INDEX places_lat ON places(lat);
        CREATE VIRTUAL TABLE places_fts USING fts5(name, cats, area, content='', tokenize='unicode61 remove_diacritics 2');
    """)
    kept = 0
    for r in rows:
        if r.get("lat") is None or r.get("lng") is None or not r.get("name") or not r.get("id"):
            continue
        cur = db.execute("INSERT OR IGNORE INTO places(id, name, category, basic, address, locality, region, postcode, country, "
                         "phone, website, socials, brand, confidence, lat, lng) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                         (r["id"], r["name"][:200], r.get("category"), r.get("basic"), r.get("address"), r.get("locality"),
                          r.get("region"), r.get("postcode"), r.get("country"), (r.get("phones") or [None])[0],
                          (r.get("websites") or [None])[0], json.dumps(r["socials"][:4]) if r.get("socials") else None,
                          r.get("brand"), r.get("confidence"), round(r["lat"], 6), round(r["lng"], 6)))
        if cur.rowcount:
            db.execute("INSERT INTO places_fts(rowid, name, cats, area) VALUES (?,?,?,?)",
                       (cur.lastrowid, words(r["name"], r.get("brand")),
                        words(r.get("category"), r.get("basic"), r.get("hierarchy"), r.get("alternates")),
                        words(r.get("locality"), r.get("address"))))
            kept += 1
    meta = {"schema": SCHEMA_VERSION, **meta, "count": kept, "created": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "attribution": ATTRIBUTION}
    db.executemany("INSERT INTO meta VALUES (?, ?)", [(k, json.dumps(v)) for k, v in meta.items()])
    db.commit()
    db.execute("VACUUM")
    db.close()
    os.chmod(tmp, 0o600)
    os.replace(tmp, out)
    print("wrote %d places to %s" % (kept, out), file=sys.stderr)
    return meta


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    where = ap.add_mutually_exclusive_group(required=True)
    where.add_argument("--bbox", help="west,south,east,north in degrees")
    where.add_argument("--area", help='a named area, e.g. "Chennai, India" (its bounding box from Nominatim)')
    where.add_argument("--country", help="ISO country code, e.g. IN (the whole country; large)")
    ap.add_argument("--release", default="", help="Overture release, e.g. 2026-11-18.0 (default: the newest)")
    ap.add_argument("--out", default="", help="default: $BRIDGE_DATA_DIR/places.sqlite")
    ap.add_argument("--min-confidence", type=float, default=0.3)
    args = ap.parse_args(argv)
    data = os.environ.get("BRIDGE_DATA_DIR") or os.path.join(os.path.expanduser("~"), ".local", "share", "gpt-live-bridge")
    out = args.out or os.path.join(data, "places.sqlite")
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    if args.bbox:
        bbox, country = parse_bbox(args.bbox), None
    elif args.area:
        bbox, country = area_bbox(args.area), None
    else:
        bbox, country = area_bbox(args.country), args.country
    extract(bbox, args.release or latest_release(), out, country, args.min_confidence)


if __name__ == "__main__":
    main()
