#!/bin/bash
# -----------------------------------------------------------------------------
# Copyright (c) 2026 David B. Foster. All rights reserved.
# Contact: wizeman555@gmail.com
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------
#
# Build the inputs for flows-train's `rental-places-table`: every DiscoverCars
# rental city in the US, Canada and Mexico with a map position, and the
# airports DiscoverCars lists as their own pick-up locations.
#
# WHY: FLOWS's rental links were built from map names ("Mexico City",
# "Quebec City") and DiscoverCars names places its own way ("mexico",
# "quebec"), so some links landed on a 404. Links built from DiscoverCars'
# OWN list of places resolve by construction.
#
# SOURCES
#   DiscoverCars' landing-page generator data (the owner's affiliate tool,
#   https://www.discovercars.com/landing-page-generator), fetched politely —
#   one request a second, cached, only what the table needs.
#   Positions from public-domain sources only (owner's rule 2026-09-30: where
#   public domain can do the job, FLOWS uses it — these replaced GeoNames,
#   CC BY 4.0). `rental-positions` says how each is used:
#     Census Bureau gazetteers (places and county subdivisions, 2025; places
#       with their 2010 count) and its 2024 city and town estimates
#     USGS GNIS domestic names (populated places)
#     Natural Earth populated places (public domain)
#     NGA GEOnet Names Server, Canada and Mexico ("no licensing requirements
#       or restrictions")
#   FLOWS's own airports table (rust/flows-core/src/airports_table.rs,
#   OurAirports, public domain).
#
# Usage: scripts/fetch_rental_places.sh <work-dir>
#   downloads the public sources into <work-dir>/pd (about 200 MB, kept),
#   writes <work-dir>/rental_cities.tsv and <work-dir>/rental_airports.tsv
# Needs: curl, jq, unzip (all ship with macOS), awk, cargo. No Python —
# FLOWS has none.
set -euo pipefail

OUT="${1:?work dir}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENDPOINT="https://www.discovercars.com/en/search/search-box-dropdowns"
PD="$OUT/pd"
mkdir -p "$OUT/regions" "$OUT/locations" "$PD"

ask() { # ask <type> <id> <file>: one generator query, cached
  [ -s "$3" ] && return 0
  curl -s --max-time 25 -A "Mozilla/5.0 (Macintosh)" -X POST \
    -H "X-Requested-With: XMLHttpRequest" \
    -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
    -H "Referer: https://www.discovercars.com/landing-page-generator" \
    --data "type=$1&id=$2" "$ENDPOINT" > "$3"
  sleep 1
}

# live <path>: does DiscoverCars actually serve this landing page? Their own
# list is not enough — "usa-washington-dc/washington" is in it and is a 404,
# while their misspelt "usa-maryland/baltimor/bwi" is real and the corrected
# "baltimore/bwi" is the 404. So every link is checked. A HEAD request answers
# exactly as a GET does without downloading a megabyte of page. Cached in
# status.tsv, so a rerun asks only about paths it has never seen.
STATUS="$OUT/status.tsv"; touch "$STATUS"
live() {
  local code
  code=$(awk -F'\t' -v p="$1" '$1==p { print $2; exit }' "$STATUS")
  if [ -z "$code" ]; then
    code=$(curl -s -I -o /dev/null -A "Mozilla/5.0 (Macintosh)" --max-time 25 \
      -w '%{http_code}' "https://www.discovercars.com/$1?a_aid=FAWN" || echo 000)
    printf '%s\t%s\n' "$1" "$code" >> "$STATUS"
    sleep 0.5
  fi
  [ "$code" = "200" ]
}

# fetch <url> <file>: one public download, kept.
fetch() { [ -s "$2" ] || curl -sS -L --fail --max-time 600 -o "$2" "$1"; }

# 0. The public-domain sources.
GAZ=https://www2.census.gov/geo/docs/maps-data/data/gazetteer
fetch "$GAZ/2025_Gazetteer/2025_Gaz_place_national.zip" "$PD/gaz_places.zip"
fetch "$GAZ/2025_Gazetteer/2025_Gaz_cousubs_national.zip" "$PD/gaz_cousubs.zip"
fetch "$GAZ/Gaz_places_national.zip" "$PD/gaz_places_2010.zip"
fetch https://www2.census.gov/programs-surveys/popest/datasets/2020-2024/cities/totals/sub-est2024.csv "$PD/sub-est2024.csv"
fetch https://prd-tnm.s3.amazonaws.com/StagedProducts/GeographicNames/DomesticNames/DomesticNames_National_Text.zip "$PD/gnis.zip"
fetch https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_populated_places_simple.geojson "$PD/ne_places.geojson"
fetch https://geonames.nga.mil/geonames/GNSData/Canada.zip "$PD/gns_canada.zip"
fetch https://geonames.nga.mil/geonames/GNSData/Mexico.zip "$PD/gns_mexico.zip"
[ -s "$PD/2025_Gaz_place_national.txt" ] || unzip -o -q "$PD/gaz_places.zip" -d "$PD"
[ -s "$PD/2025_Gaz_cousubs_national.txt" ] || unzip -o -q "$PD/gaz_cousubs.zip" -d "$PD"
[ -s "$PD/Gaz_places_national.txt" ] || unzip -o -q "$PD/gaz_places_2010.zip" -d "$PD"
[ -s "$PD/Text/DomesticNames_National.txt" ] || unzip -o -q "$PD/gnis.zip" "Text/DomesticNames_National.txt" -d "$PD"
[ -s "$PD/gns_ca.txt" ] || unzip -p "$PD/gns_canada.zip" fc_files/Populated_Places.txt > "$PD/gns_ca.txt"
[ -s "$PD/gns_mx.txt" ] || unzip -p "$PD/gns_mexico.zip" fc_files/Populated_Places.txt > "$PD/gns_mx.txt"
jq -r '.features[].properties | select(.iso_a2=="CA" or .iso_a2=="MX")
       | [.iso_a2, .name, .adm1name, .latitude, .longitude, .pop_max] | @tsv' \
  "$PD/ne_places.geojson" > "$PD/ne_camx.tsv"

# 1. Every region the generator offers here: each US state (and DC) is its
#    own entry, Canada and Mexico are one each. Ids from the generator's
#    country list: Mexico 64, Canada 5406, DC 6385, Arkansas 6408, the other
#    states 4992-5040.
for ID in 64 5406 6385 6408 $(seq 4992 5040); do ask 1 "$ID" "$OUT/regions/$ID.json"; done

# 2. Cities: country, region label, name (hidden direction marks removed —
#    "Redwood City" carries one), slug, id. Slugs are lowercased: DiscoverCars
#    writes many Canadian and Mexican ones capitalised ("Brandon",
#    "San-Miguel-De-Allende"), its pages answer either way, and one spelling
#    keeps links comparable and the redirect page's allow-list simple.
for f in "$OUT"/regions/*.json; do
  jq -r '.data[] | select(.type_id==2) | [.countryCode, .p1name, .name, (.url | ascii_downcase), (.id|tostring)] | @tsv' "$f"
done | LC_ALL=C sed -e $'s/\xe2\x80\x8e//g; s/\xe2\x80\x8f//g; s/\xe2\x80\x8b//g' > "$OUT/dc_cities.tsv"

# 3. FLOWS's airports: code, city, country, region, lat, lon.
awk '
/Airport \{/ { inb=1; iata=city=country=region=lat=lon=""; next }
inb && /iata:/    { match($0, /"[^"]*"/); iata=substr($0, RSTART+1, RLENGTH-2) }
inb && /city:/    { match($0, /"[^"]*"/); city=substr($0, RSTART+1, RLENGTH-2) }
inb && /country:/ { match($0, /"[^"]*"/); country=substr($0, RSTART+1, RLENGTH-2) }
inb && /region:/  { match($0, /"[^"]*"/); region=substr($0, RSTART+1, RLENGTH-2) }
inb && /lat:/     { v=$0; sub(/.*lat: */, "", v); sub(/,.*/, "", v); lat=v }
inb && /lon:/     { v=$0; sub(/.*lon: */, "", v); sub(/,.*/, "", v); lon=v }
inb && /^ *\},?$/ { if (iata!="") print iata"\t"city"\t"country"\t"region"\t"lat"\t"lon; inb=0 }
' "$REPO/rust/flows-core/src/airports_table.rs" > "$OUT/flows_airports.tsv"

# 4. The airports the current table files under each city (IATA, region,
#    city slug) — DiscoverCars' own filings, checked when that table was
#    built. They anchor the first pass of positions (below) and are asked
#    about first in step 7, so a rebuild keeps what the last one found: a
#    position needs the airports (Lincoln is the New Brunswick town
#    Fredericton's airport stands in, not Lincoln, Ontario) and finding the
#    airports needs positions.
awk '
/RentalAirport \{/ { inb=1; iata=region=city=""; next }
inb && /iata:/   { match($0, /"[^"]*"/); iata=substr($0, RSTART+1, RLENGTH-2) }
inb && /region:/ { match($0, /"[^"]*"/); region=substr($0, RSTART+1, RLENGTH-2) }
inb && /city:/   { match($0, /"[^"]*"/); city=substr($0, RSTART+1, RLENGTH-2) }
inb && /\}/      { if (iata!="") print iata"\t"region"\t"city; inb=0 }
' "$REPO/rust/flows-core/src/rental_places_table.rs" > "$OUT/table_airports.tsv"

# 5. A position for each city (`rental-positions`): country, region slug,
#    name, slug, then the id passed through. Towns DiscoverCars files under
#    the wrong state are placed by hand there (`REFILED`, `LEFT_OUT`),
#    checked against the nearest-cities list on its own pages.
awk -F'\t' '{ region = tolower($2); gsub(/ - /, "-", region); gsub(/ /, "-", region)
              print $1"\t"region"\t"$3"\t"$4"\t"$5 }' "$OUT/dc_cities.tsv" > "$OUT/dc_cities_keyed.tsv"
positions() { # positions <cities> <rental_airports> <out>
  (cd "$REPO/rust" && cargo +1.93.0 run -q --release -p flows-train --bin rental-positions -- \
    "$1" "$PD/2025_Gaz_place_national.txt" "$PD/2025_Gaz_cousubs_national.txt" \
    "$PD/Gaz_places_national.txt" "$PD/sub-est2024.csv" "$PD/Text/DomesticNames_National.txt" \
    "$PD/ne_camx.tsv" "$PD/gns_ca.txt" "$PD/gns_mx.txt" "$OUT/flows_airports.tsv" "$2" "$3")
}
positions "$OUT/dc_cities_keyed.tsv" "$OUT/table_airports.tsv" "$OUT/rental_cities_matched.tsv" \
  > "$OUT/positions_first.log"
head -1 "$OUT/positions_first.log"

# 6. Only cities whose page DiscoverCars actually serves:
#    country, region, name, slug, lat, lon, people, id.
while IFS=$'\t' read -r c region name slug lat lon people id; do
  if live "$region/$slug"; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$c" "$region" "$name" "$slug" "$lat" "$lon" "$people" "$id"
  fi
done < "$OUT/rental_cities_matched.tsv" > "$OUT/rental_cities_live.tsv"

# 7. Up to four DiscoverCars cities per airport where it may be listed: the
#    city the current table files it under, the airport's own city by name
#    (ORD is filed under Chicago, not Rosemont), the nearest city, and the
#    biggest city within 50 km (DFW is under Dallas; its own name "Dallas-
#    Fort Worth" and its nearest city Grapevine both miss).
awk -F'\t' '
function rad(d){ return d*3.14159265358979/180 }
function km(a,b,c,d,  x){ x=sin(rad(c-a)/2)^2 + cos(rad(a))*cos(rad(c))*sin(rad(d-b)/2)^2; return 12742*atan2(sqrt(x),sqrt(1-x)) }
BEGIN {
  n = split("AL:Alabama AK:Alaska AZ:Arizona AR:Arkansas CA:California CO:Colorado " \
    "CT:Connecticut DE:Delaware DC:Washington_DC FL:Florida GA:Georgia HI:Hawaii " \
    "ID:Idaho IL:Illinois IN:Indiana IA:Iowa KS:Kansas KY:Kentucky LA:Louisiana " \
    "ME:Maine MD:Maryland MA:Massachusetts MI:Michigan MN:Minnesota MS:Mississippi " \
    "MO:Missouri MT:Montana NE:Nebraska NV:Nevada NH:New_Hampshire NJ:New_Jersey " \
    "NM:New_Mexico NY:New_York NC:North_Carolina ND:North_Dakota OH:Ohio " \
    "OK:Oklahoma OR:Oregon PA:Pennsylvania RI:Rhode_Island SC:South_Carolina " \
    "SD:South_Dakota TN:Tennessee TX:Texas UT:Utah VT:Vermont VA:Virginia " \
    "WA:Washington WV:West_Virginia WI:Wisconsin WY:Wyoming", pairs, " ")
  for (i = 1; i <= n; i++) { split(pairs[i], kv, ":"); s = tolower(kv[2]); gsub(/_/, "-", s); state[kv[1]] = "usa-" s }
}
FILENAME ~ /table_airports/ { was[$1] = $2"|"$3; next }
FILENAME ~ /rental_cities_live/ { n2++; cc[n2]=$1; rg[n2]=$2; la[n2]=$5; lo[n2]=$6; pp[n2]=$7; id[n2]=$8
  byname[$1"|"$2"|"tolower($3)]=n2; byslug[$2"|"$4]=n2; next }
{ region = ($3=="US") ? state[substr($4,4)] : ($3=="CA" ? "canada" : "mexico")
  c0 = ($1 in was) ? byslug[was[$1]] : 0
  c1 = byname[$3"|"region"|"tolower($2)]
  near=-1; nd=1e9; big=-1; bpop=-1
  for (i=1;i<=n2;i++) { if (cc[i]!=$3) continue; d=km($5,$6,la[i],lo[i])
    if (d<nd) { nd=d; near=i }
    if (d<=50 && pp[i]>bpop) { bpop=pp[i]; big=i } }
  printf "%s\t%s\t%s\t%s\t%s\n", $1, (c0 ? id[c0] : "-"), (c1 ? id[c1] : "-"), (near>0 ? id[near] : "-"), (big>0 ? id[big] : "-")
}' "$OUT/table_airports.tsv" "$OUT/rental_cities_live.tsv" "$OUT/flows_airports.tsv" > "$OUT/airport_candidates.tsv"

# 8. Ask each candidate city for its pick-up locations (cached).
cut -f2-5 "$OUT/airport_candidates.tsv" | tr '\t' '\n' | grep -v '^-$' | sort -u | while read -r CID; do
  ask 2 "$CID" "$OUT/locations/$CID.json"
done

# 9. An airport resolves to the first candidate city that lists it.
: > "$OUT/rental_airports.tsv"
while IFS=$'\t' read -r IATA C0 C1 C2 C3; do
  for CID in "$C0" "$C1" "$C2" "$C3"; do
    [ "$CID" = "-" ] && continue
    F="$OUT/locations/$CID.json"; [ -s "$F" ] || continue
    if jq -e --arg code "$IATA" '.data[]? | select(.iata == $code)' "$F" > /dev/null 2>&1; then
      ROW=$(awk -F'\t' -v cid="$CID" '$8==cid { print $2"\t"$4; exit }' "$OUT/rental_cities_live.tsv")
      [ -n "$ROW" ] || continue
      REGION=${ROW%%$'\t'*}; SLUG=${ROW#*$'\t'}
      CODE=$(printf '%s' "$IATA" | tr 'A-Z' 'a-z')
      live "$REGION/$SLUG/$CODE" || continue
      printf '%s\t%s\t%s\n' "$IATA" "$REGION" "$SLUG" >> "$OUT/rental_airports.tsv"
      break
    fi
  done
done < "$OUT/airport_candidates.tsv"

# 10. Positions again, anchored by the airports this run found filed under
#     each city.
cut -f1-4,8 "$OUT/rental_cities_live.tsv" > "$OUT/rental_cities_live_keyed.tsv"
positions "$OUT/rental_cities_live_keyed.tsv" "$OUT/rental_airports.tsv" "$OUT/rental_cities_final.tsv" \
  > "$OUT/positions.log"
cat "$OUT/positions.log"
cut -f1-7 "$OUT/rental_cities_final.tsv" > "$OUT/rental_cities.tsv"

echo "rental cities: $(wc -l < "$OUT/rental_cities.tsv" | tr -d ' ') of $(wc -l < "$OUT/dc_cities.tsv" | tr -d ' ') placed and served"
echo "airports listed by DiscoverCars: $(wc -l < "$OUT/rental_airports.tsv" | tr -d ' ') of $(wc -l < "$OUT/flows_airports.tsv" | tr -d ' ')"
