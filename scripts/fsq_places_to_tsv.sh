#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Copyright (c) 2026 David B. Foster. All rights reserved.
# -----------------------------------------------------------------------------
# REPO TOOLING ONLY (never a product dependency): one-time conversion of the
# Foursquare OS Places dataset (Apache 2.0) into the flat TSV that the pure-std
# Rust `places-shard` tool compiles into per-state .fps shards. It needs curl
# and the DuckDB command-line tool (`brew install duckdb`); FLOWS has no
# Python.
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
# Nothing close to the full 17 GB dataset is downloaded. Files are converted
# in the mirror's numeric order, so the TSV's row order is the same on every
# run.
#
# Output: data/reference/fsq_places_us.tsv (gitignored), no header, columns:
#   group  lat  lon  name  street  city  region  postcode  website  tel  category_label
#
# Usage: scripts/fsq_places_to_tsv.sh [release e.g. 2025-02-06]
#        (default: latest release present on the mirror)
set -euo pipefail

command -v duckdb >/dev/null || {
  echo "needs the DuckDB command-line tool: brew install duckdb" >&2
  exit 1
}
# Every duckdb call below passes `-init /dev/null`: this script parses what the
# CLI prints, and a ~/.duckdbrc with `.timer on` or `.echo on` would print
# lines into it.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_TSV="$ROOT/data/reference/fsq_places_us.tsv"
LIST_URL="https://s3.us-west-2.amazonaws.com/us-west-2.opendata.source.coop?list-type=2&prefix=fused/fsq-os-places/"
DATA_BASE="https://data.source.coop/fused/fsq-os-places/"
GROUP_NAMES=(fuel food stores hotel medical tourist transit rest/truckstop)
# The TSV's delimiter, a real tab character inside the SQL string (the regex
# below spells it `\t`, which the regex engine reads).
TAB=$'\t'

# One S3 list-type=2 page, as the values of one XML element, one per line.
s3_list() { # url element
  curl -fsS --max-time 120 "$1" | grep -o "<$2>[^<]*</$2>" | sed "s#<$2>\\(.*\\)</$2>#\\1#"
}

# ---- releases on the mirror, oldest first
releases=$(s3_list "${LIST_URL}&delimiter=/" Prefix \
  | grep -E '/[0-9]{4}-[0-9]{2}-[0-9]{2}/$' | sed -E 's#/$##; s#.*/##' | LC_ALL=C sort || true)
[ -n "$releases" ] || { echo "no releases found on the mirror" >&2; exit 1; }
release=${1:-$(printf '%s\n' "$releases" | tail -n 1)}
printf '%s\n' "$releases" | grep -qx "$release" || {
  echo "release $release not on mirror; available: $(printf '%s ' $releases)" >&2
  exit 1
}

# ---- that release's parquet files, in numeric order
files=$(s3_list "${LIST_URL}${release}/places/" Key \
  | grep '\.parquet$' | sed 's#.*/##' | grep '^[0-9]' | sort -t. -k1,1n || true)
[ -n "$files" ] || { echo "no parquet files for $release" >&2; exit 1; }
echo "release $release: $(printf '%s\n' "$files" | wc -l | tr -d ' ') parquet files on mirror"

# A SQL list literal of the files' URLs, in order.
url_list="[$(printf '%s\n' "$files" | sed "s#.*#'${DATA_BASE}${release}/places/&'#" | paste -sd, -)]"

# ---- footer-only pass: which files can contain US rows at all, and how many
# bytes of the needed columns they hold (the transfer's upper bound).
t0=$SECONDS
footer=$(duckdb -init /dev/null -csv -noheader <<SQL
INSTALL httpfs; LOAD httpfs; SET threads=8;
WITH meta AS (
  SELECT file_name,
         min(stats_min_value) FILTER (path_in_schema = 'country') AS cmin,
         max(stats_max_value) FILTER (path_in_schema = 'country') AS cmax,
         sum(total_compressed_size) FILTER (list_contains(
           ['name', 'latitude', 'longitude', 'address', 'locality', 'region',
            'postcode', 'country', 'website', 'tel', 'fsq_category_labels',
            'date_closed'], path_in_schema)) AS need_bytes
  FROM parquet_metadata($url_list) GROUP BY file_name
)
SELECT file_name, coalesce(need_bytes, 0) FROM meta
WHERE cmin IS NOT NULL AND cmin <= 'US' AND 'US' <= cmax
ORDER BY list_position($url_list, file_name);
SQL
)
us_urls=$(printf '%s\n' "$footer" | cut -d, -f1 | sed '/^$/d')
est=$(printf '%s\n' "$footer" | awk -F, '{ s += $2 } END { printf "%.2f", s / 1e9 }')
echo "footer scan $((SECONDS - t0))s: $(printf '%s\n' "$us_urls" | sed '/^$/d' | wc -l | tr -d ' ')/$(printf '%s\n' "$files" | wc -l | tr -d ' ') files can hold US rows; <= $est GB of needed columns to transfer"

# ---- the per-file conversion
select_sql() { # url
  cat <<SQL
WITH src AS (
  SELECT name, latitude, longitude, address, locality, region,
         postcode, website, tel, fsq_category_labels,
         lower(coalesce(array_to_string(fsq_category_labels, ' | '), ''))
           AS labels
  FROM read_parquet('$1')
  WHERE country = 'US' AND date_closed IS NULL
    AND latitude IS NOT NULL AND longitude IS NOT NULL
    AND latitude BETWEEN -90 AND 90 AND longitude BETWEEN -180 AND 180
    AND name IS NOT NULL AND trim(name) <> ''
)
SELECT
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
             '> (International Airport|Private Airport|Airport|Airport Terminal)\$'))) > 0
        THEN 6
      WHEN labels LIKE '%dining and drinking%' THEN 1
      WHEN labels LIKE '%retail%' THEN 2
      WHEN (labels LIKE '%arts and entertainment%'
        OR labels LIKE '%landmarks and outdoors%')
        AND labels NOT LIKE '%states and municipalities%' THEN 5
      ELSE NULL
    END AS grp, latitude, longitude,
       trim(regexp_replace(coalesce(name, ''), '[\t\n\r]+', ' ', 'g')) AS name,
       trim(regexp_replace(coalesce(address, ''), '[\t\n\r]+', ' ', 'g')) AS street,
       trim(regexp_replace(coalesce(locality, ''), '[\t\n\r]+', ' ', 'g')) AS city,
       CASE WHEN upper(trim(coalesce(region,''))) IN ('AK', 'AL', 'AR', 'AS', 'AZ', 'CA', 'CO', 'CT', 'DC', 'DE', 'FL', 'GA', 'GU', 'HI', 'IA', 'ID', 'IL', 'IN', 'KS', 'KY', 'LA', 'MA', 'MD', 'ME', 'MI', 'MN', 'MO', 'MP', 'MS', 'MT', 'NC', 'ND', 'NE', 'NH', 'NJ', 'NM', 'NV', 'NY', 'OH', 'OK', 'OR', 'PA', 'PR', 'RI', 'SC', 'SD', 'TN', 'TX', 'UT', 'VA', 'VI', 'VT', 'WA', 'WI', 'WV', 'WY') THEN upper(trim(region)) ELSE CASE upper(trim(coalesce(region,''))) WHEN 'ALABAMA' THEN 'AL' WHEN 'ALASKA' THEN 'AK' WHEN 'ARIZONA' THEN 'AZ' WHEN 'ARKANSAS' THEN 'AR' WHEN 'CALIFORNIA' THEN 'CA' WHEN 'COLORADO' THEN 'CO' WHEN 'CONNECTICUT' THEN 'CT' WHEN 'DELAWARE' THEN 'DE' WHEN 'FLORIDA' THEN 'FL' WHEN 'GEORGIA' THEN 'GA' WHEN 'HAWAII' THEN 'HI' WHEN 'IDAHO' THEN 'ID' WHEN 'ILLINOIS' THEN 'IL' WHEN 'INDIANA' THEN 'IN' WHEN 'IOWA' THEN 'IA' WHEN 'KANSAS' THEN 'KS' WHEN 'KENTUCKY' THEN 'KY' WHEN 'LOUISIANA' THEN 'LA' WHEN 'MAINE' THEN 'ME' WHEN 'MARYLAND' THEN 'MD' WHEN 'MASSACHUSETTS' THEN 'MA' WHEN 'MICHIGAN' THEN 'MI' WHEN 'MINNESOTA' THEN 'MN' WHEN 'MISSISSIPPI' THEN 'MS' WHEN 'MISSOURI' THEN 'MO' WHEN 'MONTANA' THEN 'MT' WHEN 'NEBRASKA' THEN 'NE' WHEN 'NEVADA' THEN 'NV' WHEN 'NEW HAMPSHIRE' THEN 'NH' WHEN 'NEW JERSEY' THEN 'NJ' WHEN 'NEW MEXICO' THEN 'NM' WHEN 'NEW YORK' THEN 'NY' WHEN 'NORTH CAROLINA' THEN 'NC' WHEN 'NORTH DAKOTA' THEN 'ND' WHEN 'OHIO' THEN 'OH' WHEN 'OKLAHOMA' THEN 'OK' WHEN 'OREGON' THEN 'OR' WHEN 'PENNSYLVANIA' THEN 'PA' WHEN 'RHODE ISLAND' THEN 'RI' WHEN 'SOUTH CAROLINA' THEN 'SC' WHEN 'SOUTH DAKOTA' THEN 'SD' WHEN 'TENNESSEE' THEN 'TN' WHEN 'TEXAS' THEN 'TX' WHEN 'UTAH' THEN 'UT' WHEN 'VERMONT' THEN 'VT' WHEN 'VIRGINIA' THEN 'VA' WHEN 'WASHINGTON' THEN 'WA' WHEN 'WEST VIRGINIA' THEN 'WV' WHEN 'WISCONSIN' THEN 'WI' WHEN 'WYOMING' THEN 'WY' WHEN 'DISTRICT OF COLUMBIA' THEN 'DC' WHEN 'WASHINGTON DC' THEN 'DC' WHEN 'WASHINGTON D.C.' THEN 'DC' WHEN 'PUERTO RICO' THEN 'PR' WHEN 'GUAM' THEN 'GU' WHEN 'U.S. VIRGIN ISLANDS' THEN 'VI' WHEN 'US VIRGIN ISLANDS' THEN 'VI' WHEN 'VIRGIN ISLANDS' THEN 'VI' WHEN 'AMERICAN SAMOA' THEN 'AS' WHEN 'NORTHERN MARIANA ISLANDS' THEN 'MP' ELSE NULL END END AS st,
       trim(regexp_replace(coalesce(postcode, ''), '[\t\n\r]+', ' ', 'g')) AS postcode,
       trim(regexp_replace(coalesce(website, ''), '[\t\n\r]+', ' ', 'g')) AS website,
       trim(regexp_replace(coalesce(tel, ''), '[\t\n\r]+', ' ', 'g')) AS tel,
       trim(regexp_replace(coalesce(fsq_category_labels[1], ''), '[\t\n\r]+', ' ', 'g')) AS category_label
FROM src
WHERE grp IS NOT NULL AND st IS NOT NULL
SQL
}

mkdir -p "$(dirname "$OUT_TSV")"
# The rows gather in a temporary file that becomes the TSV only when every
# file has converted: a failed or interrupted run must never leave a partial
# TSV, which build_places_shards.sh would reuse without a word.
tmp="$OUT_TSV.tmp"
part="$OUT_TSV.part"
trap 'rm -f "$tmp" "$part"' EXIT
: > "$tmp"
total=0 i=0
count=$(printf '%s\n' "$us_urls" | sed '/^$/d' | wc -l | tr -d ' ')
t0=$SECONDS
while IFS= read -r url; do
  [ -n "$url" ] || continue
  i=$((i + 1))
  for attempt in 0 1 2; do
    if { echo "INSTALL httpfs; LOAD httpfs; SET threads=8;"
         echo "COPY ($(select_sql "$url")) TO '$part' (FORMAT CSV, DELIMITER '$TAB', HEADER false, QUOTE '');"
       } | duckdb -init /dev/null; then
      break
    fi
    [ "$attempt" -lt 2 ] || exit 1
    echo "  retry ${url##*/}"
    sleep $((5 * (attempt + 1)))
  done
  n=$(wc -l < "$part" | tr -d ' ')
  cat "$part" >> "$tmp"
  rm -f "$part"
  total=$((total + n))
  echo "  [$i/$count] ${url##*/}: $n rows ($total so far, $((SECONDS - t0))s)"
done <<< "$us_urls"
mv -f "$tmp" "$OUT_TSV"

echo
echo "wrote $total rows -> $OUT_TSV in $((SECONDS - t0))s"
duckdb -init /dev/null -csv -noheader -c "SELECT grp, count(*) FROM read_csv('$OUT_TSV', delim='$TAB', header=false, quote='', all_varchar=true, names=['grp']) GROUP BY 1 ORDER BY 1" \
  | while IFS=, read -r g n; do echo "  group $g (${GROUP_NAMES[$g]}): $n"; done
