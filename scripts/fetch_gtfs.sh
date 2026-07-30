#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Copyright (c) 2026 David B. Foster. All rights reserved.
# -----------------------------------------------------------------------------

# fetch_gtfs.sh — politely download and unzip a GTFS feed into data/transit/<name>/.
#
# Usage: scripts/fetch_gtfs.sh <agency-url> <name>
#   e.g. scripts/fetch_gtfs.sh http://transitdata.cityofmadison.com/GTFS/mmt_gtfs.zip madison
#
# Only DATA is ever downloaded — never a tool or library (zero-crate rule).
# curl/unzip are tooling, not product dependencies. Feeds land in data/transit/
# which is gitignored (large, per-feed redistribution licenses vary).
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <agency-url> <name>" >&2
  exit 2
fi
url=$1
name=$2
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$root/data/transit/$name"
zip="$dir/gtfs.zip"
mkdir -p "$dir"

# Polite fetch: identify ourselves, follow redirects, retry transient failures,
# and use a conditional GET when a previous copy exists (don't re-pull unchanged
# feeds off an agency's server).
curl_args=(
  -L --fail --retry 3 --retry-delay 2 --connect-timeout 30
  -A "FLOWS/1.0 GTFS fetch (wizeman555@gmail.com)"
  -o "$zip"
)
if [ -f "$zip" ]; then
  curl_args+=( -z "$zip" )
fi
curl "${curl_args[@]}" "$url"

rm -rf "$dir/gtfs"
mkdir -p "$dir/gtfs"
unzip -o -q "$zip" -d "$dir/gtfs"

# Some agencies nest the files one folder deep inside the zip; flatten so the
# converter always finds stops.txt at $dir/gtfs/stops.txt.
if [ ! -f "$dir/gtfs/stops.txt" ]; then
  inner=$(find "$dir/gtfs" -mindepth 2 -maxdepth 2 -name stops.txt | head -n1 || true)
  if [ -n "$inner" ]; then
    mv "$(dirname "$inner")"/* "$dir/gtfs/"
  fi
fi

echo "fetched $url -> $dir/gtfs"
ls -l "$dir/gtfs"
