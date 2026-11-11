#!/bin/bash
# -----------------------------------------------------------------------------
# Copyright (c) 2026 David B. Foster. All rights reserved.
# Contact: wizeman555@gmail.com
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------
#
# Fetch a data table's source again, rebuild the table and stamp it.
#
# Usage: scripts/tables/refresh.sh <airports|feeds|ferries|rental> [--check]
#   --check  build into the work folder only and say whether the table
#            would change; the repository is left alone.
# Work folder: $FLOWS_TABLE_WORK, or a new temporary folder.
#
# The other tables in scripts/tables/TABLES.tsv have no fetch script. Their
# refresh column names the script that rebuilds them, or says "by hand".
# After a refresh: read the diff, run the tests, then land it. A refresh is
# never landed unread: a source can publish a broken file.
# Needs: curl, cargo, and what the fetch scripts need. No Python.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WHAT="${1:?airports, feeds, ferries or rental}"
CHECK="${2:-}"
[ -z "$CHECK" ] || [ "$CHECK" = "--check" ] || { echo "refresh: unknown option $CHECK" >&2; exit 1; }
TOOLCHAIN="${FLOWS_RUST_TOOLCHAIN:-1.93.0}"
WORK="${FLOWS_TABLE_WORK:-$(mktemp -d)}"
mkdir -p "$WORK"

bin() { # bin <name> <args…>: run one flows-train generator
  local name="$1"; shift
  (cd "$REPO/rust" && cargo "+$TOOLCHAIN" run -q --release -p flows-train --bin "$name" -- "$@")
}
get() { # get <url> <file>: a plain download that fails loudly
  curl -sS -L --fail --max-time 300 -A curl -o "$2" "$1"
  [ -s "$2" ] || { echo "refresh: empty download: $1" >&2; exit 1; }
}

case "$WHAT" in
  airports)
    TABLE=rust/flows-core/src/airports_table.rs
    get https://davidmegginson.github.io/ourairports-data/airports.csv "$WORK/airports.csv"
    bin airports-table "$WORK/airports.csv" "$WORK/out.rs" ;;
  feeds)
    TABLE=rust/flows-core/src/transit/feeds_table.rs
    # The current export. The older one (bit.ly/catalogs-csv) leaves out a
    # third of the feeds.
    get https://files.mobilitydatabase.org/feeds_v2.csv "$WORK/catalog.csv"
    bin feeds-table "$WORK/catalog.csv" "$WORK/out.rs" ;;
  ferries)
    TABLE=rust/flows-core/src/ferries_table.rs
    bash "$REPO/scripts/fetch_ferry_census.sh" "$WORK/ferries"
    bin ferries-table "$WORK/ferries" "$WORK/out.rs" ;;
  rental)
    TABLE=rust/flows-core/src/rental_places_table.rs
    bash "$REPO/scripts/fetch_rental_places.sh" "$WORK/rental"
    bin rental-places-table "$WORK/rental/rental_cities.tsv" "$WORK/rental/rental_airports.tsv" "$WORK/out.rs" ;;
  *) echo "refresh: unknown table $WHAT (airports, feeds, ferries, rental)" >&2; exit 1 ;;
esac

# Compare, measure and install in rustfmt's layout, the one the repository
# keeps.
(cd "$REPO/rust" && rustup run "$TOOLCHAIN" rustfmt --edition 2021 "$WORK/out.rs")
# A table that shrank by a tenth or more is far more likely a broken
# download than a real change: stop, and leave the old table in place.
OLD=$(wc -l < "$REPO/$TABLE"); NEW=$(wc -l < "$WORK/out.rs")
if [ $((NEW * 10)) -lt $((OLD * 9)) ]; then
  echo "refresh: $WHAT would shrink from $OLD to $NEW lines; not applied (see $WORK/out.rs)" >&2
  exit 1
fi
if cmp -s "$WORK/out.rs" "$REPO/$TABLE"; then
  echo "$WHAT: the source gives the same table ($OLD lines)"
  SAME=1
else
  echo "$WHAT: the table changes ($OLD lines to $NEW)"
  SAME=0
fi
if [ "$CHECK" = "--check" ]; then
  echo "checked only; the new table is $WORK/out.rs"
  exit 0
fi
[ "$SAME" = 1 ] || cp "$WORK/out.rs" "$REPO/$TABLE"
bash "$REPO/scripts/tables/stamp.sh" "$TABLE"
