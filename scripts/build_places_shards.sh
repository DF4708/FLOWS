#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Copyright (c) David B. Foster. All rights reserved.
# -----------------------------------------------------------------------------
# Build the FLOWS offline POI database end to end (FSQ OS Places -> regional
# shards):
#   1. one-time TOOLING conversion (python + duckdb, never a product dep):
#      remote *filtered* scan of the keyless Source Cooperative mirror of the
#      Foursquare OS Places parquet release -> data/reference/fsq_places_us.tsv
#      (files that cannot contain US rows are skipped from parquet footers;
#      only the needed columns are transferred — a few GB, not the full 17 GB)
#   2. pure-std Rust `places-shard` compiles the TSV into per-state binary
#      .fps shards (data/places/<XX>.fps) plus data/places/index.json
#
# The TSV and shards are gitignored (regenerable); data/places/ATTRIBUTION.txt
# (the Apache 2.0 NOTICE carry-through for Foursquare) is tracked and must
# ship with the shards. See docs/DATA_FEEDS.md "FSQ OS Places".
#
# Usage: scripts/build_places_shards.sh [release e.g. 2025-02-06]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TSV="$ROOT/data/reference/fsq_places_us.tsv"
OUT="$ROOT/data/places"

# ---- free-space guard: the TSV + shards + parquet buffering want headroom
FREE_GB=$(df -g "$ROOT" | awk 'NR==2 {print $4}')
if [ "$FREE_GB" -lt 30 ]; then
  echo "only ${FREE_GB} GB free — need >= 30 GB headroom, aborting." >&2
  exit 1
fi

# ---- tooling conversion (skipped when the TSV already exists)
if [ -s "$TSV" ]; then
  echo "reusing existing $TSV (delete it to re-convert)"
else
  python3 -c 'import duckdb' 2>/dev/null || {
    echo "installing duckdb (repo tooling only)"
    pip3 install --user duckdb
  }
  python3 -u "$ROOT/scripts/fsq_places_to_tsv.py" "${1:-}"
fi

# ---- shard build (pure std Rust)
cargo build --release --manifest-path "$ROOT/rust/Cargo.toml" -p flows-train \
  --bin places-shard
"$ROOT/rust/target/release/places-shard" "$TSV" "$OUT"

echo "done: $(ls "$OUT"/*.fps | wc -l | tr -d ' ') shards in $OUT"
