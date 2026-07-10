#!/usr/bin/env bash
# build_ftt.sh — convert a fetched GTFS feed into a .ftt timetable shard.
#
# Usage: scripts/build_ftt.sh <name> [YYYYMMDD]
#   e.g. scripts/build_ftt.sh madison            # today's service day
#        scripts/build_ftt.sh madison 20260713   # an explicit service day
#
# The Rust converter never reads the system clock (determinism rule); THIS
# wrapper computes "today" and passes it in. If the feed's calendar doesn't
# cover the requested date, the converter errors with the covered range —
# rerun with an in-range date.
set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "usage: $0 <name> [YYYYMMDD]" >&2
  exit 2
fi
name=$1
date_arg=${2:-$(date +%Y%m%d)}
root="$(cd "$(dirname "$0")/.." && pwd)"
gtfs="$root/data/transit/$name/gtfs"
out="$root/data/transit/$name.ftt"

if [ ! -d "$gtfs" ]; then
  echo "no feed at $gtfs — run scripts/fetch_gtfs.sh <url> $name first" >&2
  exit 1
fi

export PATH="$HOME/.cargo/bin:$PATH"
cargo run --release --quiet \
  --manifest-path "$root/rust/Cargo.toml" \
  -p flows-core --bin gtfs-ftt -- \
  "$gtfs" "$out" "$date_arg" --verify
