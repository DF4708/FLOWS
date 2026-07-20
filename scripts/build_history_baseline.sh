#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Copyright (c) 2026 David B. Foster. All rights reserved.
# -----------------------------------------------------------------------------
# Build the FLOWS 20-year historical hazard baseline end to end:
#   1. download-if-missing the free, keyless inputs (polite: sequential, 1/s)
#        - NOAA NCEI Storm Events details CSVs 2005-2024
#        - Census ZCTA gazetteer + ZCTA<->county relationship file
#   2. gunzip the yearly CSVs
#   3. run the pure-std `history-baseline` Rust tool (week-of-year passed in;
#      the tool never reads the system clock)
#   4. train the baseline ranking head with `flows-train` in an ISOLATED HOME
#      so the app's real Application Support export/head are never touched,
#      then park the head at data/runtime_cache/history_route_head.json
#
# Usage: scripts/build_history_baseline.sh [week 0-51]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="$ROOT/data/reference"
SE_DIR="$REF/storm_events"
RC="$ROOT/data/runtime_cache"
BASE_URL="https://www.ncei.noaa.gov/pub/data/swdi/stormevents/csvfiles"
YEAR_FROM=2005
YEAR_TO=2024

mkdir -p "$SE_DIR"

# ---- gazetteer (ZIP centroids)
if [ ! -s "$REF/2024_Gaz_zcta_national.txt" ]; then
  echo "downloading ZCTA gazetteer"
  curl -sS --fail -o "$REF/2024_Gaz_zcta_national.zip" \
    "https://www2.census.gov/geo/docs/maps-data/data/gazetteer/2024_Gazetteer/2024_Gaz_zcta_national.zip"
  unzip -o "$REF/2024_Gaz_zcta_national.zip" -d "$REF" >/dev/null
  rm -f "$REF/2024_Gaz_zcta_national.zip"
fi

# ---- ZCTA <-> county relationship file
if [ ! -s "$REF/tab20_zcta520_county20_natl.txt" ]; then
  echo "downloading ZCTA-county relationship file"
  curl -sS --fail -o "$REF/tab20_zcta520_county20_natl.txt" \
    "https://www2.census.gov/geo/docs/maps-data/data/rel2020/zcta520/tab20_zcta520_county20_natl.txt"
fi

# ---- NWS zone<->county correlation file (resolves zone-coded events —
#      winter/heat/cold/wind zone products — to counties). Newest bp*.dbx is
#      listed first on the ZoneCounty page.
if [ ! -s "$REF/nws_zone_county.dbx" ]; then
  echo "downloading NWS zone-county correlation file"
  bp="$(curl -sS --fail "https://www.weather.gov/gis/ZoneCounty" \
      | grep -o 'href="/source/gis/Shapefiles/County/bp[0-9a-z]*\.dbx"' \
      | head -1 | sed 's/^href="//; s/"$//')"
  [ -n "$bp" ] || { echo "error: no bp*.dbx link found" >&2; exit 1; }
  curl -sS --fail -o "$REF/nws_zone_county.dbx" "https://www.weather.gov$bp"
fi

# ---- Storm Events yearly details CSVs (resolve exact c-timestamps from the
#      directory index; sequential + 1s sleep out of politeness)
index="$(curl -sS --fail "$BASE_URL/")"
for y in $(seq "$YEAR_FROM" "$YEAR_TO"); do
  f="$(printf '%s' "$index" \
      | grep -o "StormEvents_details-ftp_v1.0_d${y}_c[0-9]*\.csv\.gz" \
      | sort -u | tail -1)"
  if [ -z "$f" ]; then
    echo "error: no details file for $y in the NCEI index" >&2
    exit 1
  fi
  if [ ! -s "$SE_DIR/$f" ] && [ ! -s "$SE_DIR/${f%.gz}" ]; then
    echo "downloading $f"
    curl -sS --fail -o "$SE_DIR/$f.part" "$BASE_URL/$f"
    mv "$SE_DIR/$f.part" "$SE_DIR/$f"
    sleep 1
  fi
done

# ---- unzip (keep the .gz; gunzip is allowed download tooling)
for g in "$SE_DIR"/*.csv.gz; do
  [ -e "$g" ] || continue
  c="${g%.gz}"
  [ -s "$c" ] || gunzip -kf "$g"
done

# ---- current week-of-year 0..51 (10# guards octal on day-of-year like 008)
week="${1:-$(( (10#$(date +%j) - 1) / 7 ))}"
[ "$week" -gt 51 ] && week=51

# ---- build + run the history tool
( cd "$ROOT/rust" && cargo build --release -p flows-train \
    --bin history-baseline --bin flows-train )
"$ROOT/rust/target/release/history-baseline" "$SE_DIR" "$week"

# ---- train the baseline head from the history rows in an isolated HOME
TRAIN_HOME="$RC/history_train_home"
mkdir -p "$TRAIN_HOME/Library/Application Support"
cp "$RC/history_training_rows.csv" \
   "$TRAIN_HOME/Library/Application Support/flows_training_export.csv"
( cd "$TRAIN_HOME" && HOME="$TRAIN_HOME" "$ROOT/rust/target/release/flows-train" )
cp "$TRAIN_HOME/Library/Application Support/flows_route_head.json" \
   "$RC/history_route_head.json"
echo "baseline head -> $RC/history_route_head.json"
