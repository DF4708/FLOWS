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
#   GeoNames cities1000 + admin1 codes (CC BY 4.0, credited in the app), for
#   each city's position: https://download.geonames.org/export/dump/
#   FLOWS's own airports table (rust/flows-core/src/airports_table.rs).
#
# Usage: scripts/fetch_rental_places.sh <geonames-dir> <work-dir>
#   <geonames-dir> holds cities1000.txt and admin1CodesASCII.txt
#   writes <work-dir>/rental_cities.tsv and <work-dir>/rental_airports.tsv
# Needs: curl, jq (both ship with macOS), awk. No Python — FLOWS has none.
set -euo pipefail

GEO="${1:?geonames dir}"; OUT="${2:?work dir}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENDPOINT="https://www.discovercars.com/en/search/search-box-dropdowns"
mkdir -p "$OUT/regions" "$OUT/locations"

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

# 3. A position for each city from GeoNames, matched by name (or any
#    alternate name) within its state; a neighbourhood only wins when no
#    town has the name. Unmatched cities (counties, bases) are left out —
#    a traveller near one gets the nearest matched city or the state page.
awk -F'\t' '
FILENAME ~ /admin1/ { a1[$1]=$2; next }
FILENAME ~ /cities1000/ {
  if (!($9=="US"||$9=="CA"||$9=="MX") || $8 !~ /^PPL/ || $8 ~ /^PPL(H|Q|W)$/) next
  st = ($9=="US") ? a1[$9"."$11] : ""
  pop = $15+0; if ($8=="PPLX") pop = pop/100
  # Its own name and ASCII name are PRIMARY; alternate names count only when
  # no place has the name as its own — GeoNames lists "Manhattan" as an
  # alternate name of New York City, which put the separate DiscoverCars
  # city Manhattan exactly on top of New York, and it won the tie.
  n = split(tolower($2)","tolower($3)","tolower($4), names, ",")
  for (i=1; i<=n; i++) { k = $9"|"st"|"names[i]; if (names[i]=="") continue
    rank = (i <= 2) ? 1 : 0
    if (!(k in bp) || rank > brank[k] || (rank == brank[k] && pop > bp[k])) {
      bp[k]=pop; brank[k]=rank; blat[k]=$5; blon[k]=$6; bpop[k]=$15+0 } }
  next
}
{ st=""
  if ($1=="US") { st=$2; sub(/^USA - /, "", st); if (st=="Washington DC") st="District of Columbia" }
  k = $1"|"st"|"tolower($3)
  if (!(k in bp)) next
  region = tolower($2); gsub(/ - /, "-", region); gsub(/ /, "-", region)
  print $1"\t"region"\t"$3"\t"$4"\t"blat[k]"\t"blon[k]"\t"bpop[k]"\t"$5"\t"brank[k]
}' "$GEO/admin1CodesASCII.txt" "$GEO/cities1000.txt" "$OUT/dc_cities.tsv" > "$OUT/rental_cities_matched.tsv"
# 3b. Only cities whose page DiscoverCars actually serves.
while IFS=$'\t' read -r c region name slug lat lon pop id rank; do
  if live "$region/$slug"; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$c" "$region" "$name" "$slug" "$lat" "$lon" "$pop" "$id" "$rank"
  fi
done < "$OUT/rental_cities_matched.tsv" > "$OUT/rental_cities_live.tsv"

# 3c. Two live cities on the same spot in one region: keep the one that
# matched by its own name. (Checking first matters: of Washington, DC's two
# entries the own-name one is the 404.)
awk -F'\t' 'NR==FNR { if ($9==1) own[$2"|"$5"|"$6]=1; next }
                 $9==1 || !(($2"|"$5"|"$6) in own)' \
  "$OUT/rental_cities_live.tsv" "$OUT/rental_cities_live.tsv" | cut -f1-8 > "$OUT/rental_cities_full.tsv"
cut -f1-7 "$OUT/rental_cities_full.tsv" > "$OUT/rental_cities.tsv"

# 4. FLOWS's airports: code, city, country, region, lat, lon.
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

# 5. Up to three DiscoverCars cities per airport where it may be listed: the
#    airport's own city by name (ORD is filed under Chicago, not Rosemont),
#    the nearest city, and the biggest city within 50 km (DFW is under
#    Dallas; its own name "Dallas-Fort Worth" and its nearest city Grapevine
#    both miss).
awk -F'\t' '
function rad(d){ return d*3.14159265358979/180 }
function km(a,b,c,d,  x){ x=sin(rad(c-a)/2)^2 + cos(rad(a))*cos(rad(c))*sin(rad(d-b)/2)^2; return 12742*atan2(sqrt(x),sqrt(1-x)) }
FILENAME ~ /admin1/ { a1[$1]=$2; next }
FILENAME ~ /rental_cities_full/ { n++; cc[n]=$1; rg[n]=$2; nm[n]=tolower($3); la[n]=$5; lo[n]=$6; pp[n]=$7; id[n]=$8
  byname[$1"|"$2"|"tolower($3)]=n; next }
{ region = ($3=="US") ? "usa-" tolower(a1["US." substr($4,4)]) : tolower($3=="CA" ? "canada" : "mexico")
  gsub(/ /, "-", region); if (region=="usa-district-of-columbia") region="usa-washington-dc"
  c1 = byname[$3"|"region"|"tolower($2)]
  near=-1; nd=1e9; big=-1; bpop=-1
  for (i=1;i<=n;i++) { if (cc[i]!=$3) continue; d=km($5,$6,la[i],lo[i])
    if (d<nd) { nd=d; near=i }
    if (d<=50 && pp[i]>bpop) { bpop=pp[i]; big=i } }
  printf "%s\t%s\t%s\t%s\n", $1, (c1 ? id[c1] : "-"), (near>0 ? id[near] : "-"), (big>0 ? id[big] : "-")
}' "$GEO/admin1CodesASCII.txt" "$OUT/rental_cities_full.tsv" "$OUT/flows_airports.tsv" > "$OUT/airport_candidates.tsv"

# 6. Ask each candidate city for its pick-up locations (cached).
cut -f2-4 "$OUT/airport_candidates.tsv" | tr '\t' '\n' | grep -v '^-$' | sort -u | while read -r CID; do
  ask 2 "$CID" "$OUT/locations/$CID.json"
done

# 7. An airport resolves to the first candidate city that lists it.
: > "$OUT/rental_airports.tsv"
while IFS=$'\t' read -r IATA C1 C2 C3; do
  for CID in "$C1" "$C2" "$C3"; do
    [ "$CID" = "-" ] && continue
    F="$OUT/locations/$CID.json"; [ -s "$F" ] || continue
    if jq -e --arg code "$IATA" '.data[]? | select(.iata == $code)' "$F" > /dev/null 2>&1; then
      ROW=$(awk -F'\t' -v cid="$CID" '$8==cid { print $2"\t"$4; exit }' "$OUT/rental_cities_full.tsv")
      [ -n "$ROW" ] || continue
      REGION=${ROW%%$'\t'*}; SLUG=${ROW#*$'\t'}
      CODE=$(printf '%s' "$IATA" | tr 'A-Z' 'a-z')
      live "$REGION/$SLUG/$CODE" || continue
      printf '%s\t%s\t%s\n' "$IATA" "$REGION" "$SLUG" >> "$OUT/rental_airports.tsv"
      break
    fi
  done
done < "$OUT/airport_candidates.tsv"

echo "rental cities: $(wc -l < "$OUT/rental_cities.tsv" | tr -d ' ') of $(wc -l < "$OUT/dc_cities.tsv" | tr -d ' ') placed"
echo "airports listed by DiscoverCars: $(wc -l < "$OUT/rental_airports.tsv" | tr -d ' ') of $(wc -l < "$OUT/flows_airports.tsv" | tr -d ' ')"
