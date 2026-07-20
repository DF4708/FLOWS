#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# Copyright (c) 2026 David B. Foster. All rights reserved.
# -----------------------------------------------------------------------------
# REPO TOOLING ONLY (never a product dependency): one-time conversion of the
# Foursquare OS Places dataset (Apache 2.0) into the flat TSV that the pure-std
# Rust `places-shard` tool compiles into per-state .fps shards.
#
# Source: the keyless, ungated Source Cooperative mirror of FSQ OS Places
#   https://data.source.coop/fused/fsq-os-places/<release>/places/*.parquet
# (Foursquare's own S3 bucket now holds only LICENSE/NOTICE; current releases
# moved to a GATED Hugging Face dataset that requires an account + agreement,
# so the last ungated Apache-2.0 mirror is what we build from. See
# docs/DATA_FEEDS.md "FSQ OS Places".)
#
# Strategy: remote *filtered* scan with DuckDB httpfs — parquet footers are
# read first so files whose country column can never contain 'US' are skipped
# entirely, and only the needed columns of the remaining files are transferred.
# Nothing close to the full 17 GB dataset is downloaded.
#
# Output: data/reference/fsq_places_us.tsv (gitignored), no header, columns:
#   group  lat  lon  name  street  city  region  postcode  website  tel  category_label
#
# Usage: python3 scripts/fsq_places_to_tsv.py [release e.g. 2025-02-06]
#        (default: latest release present on the mirror)

import json
import os
import re
import sys
import time
import urllib.request

try:
    import duckdb
except ImportError:
    sys.exit("duckdb missing — install repo tooling with: pip3 install --user duckdb")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_TSV = os.path.join(ROOT, "data", "reference", "fsq_places_us.tsv")
LIST_URL = ("https://s3.us-west-2.amazonaws.com/us-west-2.opendata.source.coop"
            "?list-type=2&prefix=fused/fsq-os-places/")
DATA_BASE = "https://data.source.coop/fused/fsq-os-places/"

GROUP_NAMES = ["fuel", "food", "stores", "hotel", "medical", "tourist",
               "transit", "rest/truckstop"]

# Keyword -> group table (first match wins; matched against the lowercased
# ' | '-joined fsq_category_labels). Grounded in the actual 2025-02-06 label
# inventory — FSQ says "Fuel Station" (not "Gas Station"), pharmacies live
# under "Retail > Pharmacy", and the naive substrings collide with Food Truck,
# Hotel Bar, Fire/Police/Radio/TV Station, Gastropub, Stationery Store — hence
# the precedence order and the explicit exclusions below.
GROUP_CASE = """
    CASE
      WHEN labels LIKE '%truck stop%' OR labels LIKE '%rest area%' THEN 7
      WHEN labels LIKE '%fuel station%' OR labels LIKE '%gas station%'
        OR labels LIKE '%filling station%'
        OR labels LIKE '%electric vehicle charging%'
        OR labels LIKE '%charging station%' THEN 0
      WHEN (labels LIKE '%hospital%' OR labels LIKE '%urgent care%'
        OR labels LIKE '%emergency room%' OR labels LIKE '%pharmacy%'
        OR labels LIKE '%drugstore%')
        AND labels NOT LIKE '%veterinar%'
        AND labels NOT LIKE '%animal hospital%' THEN 4
      WHEN labels LIKE '%> lodging%'
        OR ((labels LIKE '%hotel%' OR labels LIKE '%motel%')
            AND labels NOT LIKE '%hotel bar%') THEN 3
      WHEN labels LIKE '%rail station%' OR labels LIKE '%train station%'
        OR labels LIKE '%metro station%' OR labels LIKE '%tram station%'
        OR labels LIKE '%bus station%' OR labels LIKE '%marine terminal%'
        OR len(list_filter(fsq_category_labels, x -> regexp_matches(x,
             '> (International Airport|Private Airport|Airport|Airport Terminal)$'))) > 0
        THEN 6
      WHEN labels LIKE '%dining and drinking%' THEN 1
      WHEN labels LIKE '%retail%' THEN 2
      WHEN (labels LIKE '%arts and entertainment%'
        OR labels LIKE '%landmarks and outdoors%')
        AND labels NOT LIKE '%states and municipalities%' THEN 5
      ELSE NULL
    END
"""

STATES = {
    "ALABAMA": "AL", "ALASKA": "AK", "ARIZONA": "AZ", "ARKANSAS": "AR",
    "CALIFORNIA": "CA", "COLORADO": "CO", "CONNECTICUT": "CT",
    "DELAWARE": "DE", "FLORIDA": "FL", "GEORGIA": "GA", "HAWAII": "HI",
    "IDAHO": "ID", "ILLINOIS": "IL", "INDIANA": "IN", "IOWA": "IA",
    "KANSAS": "KS", "KENTUCKY": "KY", "LOUISIANA": "LA", "MAINE": "ME",
    "MARYLAND": "MD", "MASSACHUSETTS": "MA", "MICHIGAN": "MI",
    "MINNESOTA": "MN", "MISSISSIPPI": "MS", "MISSOURI": "MO", "MONTANA": "MT",
    "NEBRASKA": "NE", "NEVADA": "NV", "NEW HAMPSHIRE": "NH",
    "NEW JERSEY": "NJ", "NEW MEXICO": "NM", "NEW YORK": "NY",
    "NORTH CAROLINA": "NC", "NORTH DAKOTA": "ND", "OHIO": "OH",
    "OKLAHOMA": "OK", "OREGON": "OR", "PENNSYLVANIA": "PA",
    "RHODE ISLAND": "RI", "SOUTH CAROLINA": "SC", "SOUTH DAKOTA": "SD",
    "TENNESSEE": "TN", "TEXAS": "TX", "UTAH": "UT", "VERMONT": "VT",
    "VIRGINIA": "VA", "WASHINGTON": "WA", "WEST VIRGINIA": "WV",
    "WISCONSIN": "WI", "WYOMING": "WY",
    "DISTRICT OF COLUMBIA": "DC", "WASHINGTON DC": "DC", "WASHINGTON D.C.": "DC",
    "PUERTO RICO": "PR", "GUAM": "GU", "U.S. VIRGIN ISLANDS": "VI",
    "US VIRGIN ISLANDS": "VI", "VIRGIN ISLANDS": "VI",
    "AMERICAN SAMOA": "AS", "NORTHERN MARIANA ISLANDS": "MP",
}
VALID_CODES = sorted(set(STATES.values()))


def s3_list(url):
    """Return (keys, prefixes) of one S3 list-type=2 page (stdlib only)."""
    body = urllib.request.urlopen(url, timeout=120).read().decode()
    return (re.findall(r"<Key>([^<]*)</Key>", body),
            re.findall(r"<Prefix>([^<]*)</Prefix>", body))


def discover(release_arg):
    _, prefixes = s3_list(LIST_URL + "&delimiter=/")
    releases = sorted(p.rstrip("/").rsplit("/", 1)[-1] for p in prefixes
                      if re.search(r"/\d{4}-\d{2}-\d{2}/$", p))
    if not releases:
        sys.exit("no releases found on the mirror")
    release = release_arg or releases[-1]
    if release not in releases:
        sys.exit(f"release {release} not on mirror; available: {releases}")
    keys, _ = s3_list(LIST_URL + f"{release}/places/")
    files = sorted((k.rsplit("/", 1)[-1] for k in keys
                    if k.endswith(".parquet") and k.rsplit("/", 1)[-1][0].isdigit()),
                   key=lambda n: int(n.split(".")[0]))
    return release, files


def region_case():
    full = " ".join(f"WHEN '{k}' THEN '{v}'" for k, v in STATES.items())
    codes = ", ".join(f"'{c}'" for c in VALID_CODES)
    return (f"CASE WHEN upper(trim(coalesce(region,''))) IN ({codes}) "
            f"THEN upper(trim(region)) ELSE "
            f"CASE upper(trim(coalesce(region,''))) {full} ELSE NULL END END")


CLEAN = "trim(regexp_replace(coalesce({0}, ''), '[\\t\\n\\r]+', ' ', 'g'))"


def main():
    release, files = discover(sys.argv[1] if len(sys.argv) > 1 else None)
    urls = [f"{DATA_BASE}{release}/places/{f}" for f in files]
    print(f"release {release}: {len(files)} parquet files on mirror")

    con = duckdb.connect()
    con.execute("INSTALL httpfs; LOAD httpfs; SET threads=8;")

    # Footer-only pass: which files can contain US rows at all, and how many
    # bytes of the needed columns they hold (= transfer upper bound).
    need_cols = ("name", "latitude", "longitude", "address", "locality",
                 "region", "postcode", "country", "website", "tel",
                 "fsq_category_labels", "date_closed")
    t0 = time.time()
    meta = con.execute("""
        SELECT file_name,
               min(stats_min_value) FILTER (path_in_schema = 'country') AS cmin,
               max(stats_max_value) FILTER (path_in_schema = 'country') AS cmax,
               sum(total_compressed_size)
                 FILTER (list_contains($cols, path_in_schema)) AS need_bytes
        FROM parquet_metadata($urls) GROUP BY file_name
    """, {"urls": urls, "cols": list(need_cols)}).fetchall()
    us_urls = [fn for fn, cmin, cmax, _ in meta
               if cmin is not None and cmin <= "US" <= cmax]
    est = sum(nb for fn, _, _, nb in meta if fn in set(us_urls)) / 1e9
    print(f"footer scan {time.time()-t0:.0f}s: {len(us_urls)}/{len(files)} files "
          f"can hold US rows; <= {est:.2f} GB of needed columns to transfer")

    sel = f"""
        WITH src AS (
          SELECT name, latitude, longitude, address, locality, region,
                 postcode, website, tel, fsq_category_labels,
                 lower(coalesce(array_to_string(fsq_category_labels, ' | '), ''))
                   AS labels
          FROM read_parquet($url)
          WHERE country = 'US' AND date_closed IS NULL
            AND latitude IS NOT NULL AND longitude IS NOT NULL
            AND latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180
            AND name IS NOT NULL AND trim(name) <> ''
        )
        SELECT {GROUP_CASE} AS grp, latitude, longitude,
               {CLEAN.format('name')} AS name,
               {CLEAN.format('address')} AS street,
               {CLEAN.format('locality')} AS city,
               {region_case()} AS st,
               {CLEAN.format('postcode')} AS postcode,
               {CLEAN.format('website')} AS website,
               {CLEAN.format('tel')} AS tel,
               {CLEAN.format('fsq_category_labels[1]')} AS category_label
        FROM src
        WHERE grp IS NOT NULL AND st IS NOT NULL
    """

    os.makedirs(os.path.dirname(OUT_TSV), exist_ok=True)
    total = 0
    t0 = time.time()
    with open(OUT_TSV, "w", encoding="utf-8") as out:
        for i, url in enumerate(us_urls):
            part = OUT_TSV + ".part"
            for attempt in range(3):
                try:
                    con.execute(
                        f"COPY ({sel}) TO '{part}' "
                        "(FORMAT CSV, DELIMITER '\t', HEADER false, QUOTE '')",
                        {"url": url})
                    break
                except duckdb.Error as e:
                    if attempt == 2:
                        raise
                    print(f"  retry {url.rsplit('/',1)[-1]}: {e}")
                    time.sleep(5 * (attempt + 1))
            n = 0
            with open(part, encoding="utf-8") as p:
                for line in p:
                    out.write(line)
                    n += 1
            os.remove(part)
            total += n
            print(f"  [{i+1}/{len(us_urls)}] {url.rsplit('/',1)[-1]}: "
                  f"{n} rows ({total} so far, {time.time()-t0:.0f}s)")

    print(f"\nwrote {total} rows -> {OUT_TSV} in {time.time()-t0:.0f}s")
    counts = con.execute("""
        SELECT column0 AS grp, count(*) FROM read_csv($f, delim='\t',
            header=false, quote='', all_varchar=true) GROUP BY 1 ORDER BY 1
    """, {"f": OUT_TSV}).fetchall()
    for g, n in counts:
        print(f"  group {g} ({GROUP_NAMES[int(g)]}): {n}")


if __name__ == "__main__":
    main()
