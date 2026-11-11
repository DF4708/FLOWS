#!/bin/bash
# -----------------------------------------------------------------------------
# Copyright (c) 2026 David B. Foster. All rights reserved.
# Contact: wizeman555@gmail.com
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------
#
# Stamp a data table in scripts/tables/TABLES.tsv: the day its source was
# fetched, and the checksum of the bytes that day produced. The age test
# (rust/flows-bridge/tests/table_ages.rs) fails on a table that changed
# without a new stamp, so a date can never describe other bytes.
#
# Usage: scripts/tables/stamp.sh <path> [YYYY-MM-DD]
#          a table already listed; the day defaults to today
#        scripts/tables/stamp.sh <path> <YYYY-MM-DD> <max_days> <refresh> <source>
#          a new table
# Only stamp a day on which the source really was fetched again.
# Needs: cksum, awk, date. No Python: FLOWS has none.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIST="$REPO/scripts/tables/TABLES.tsv"
P="${1:?path of the table, from the repository root}"
DAY="${2:-$(date +%Y-%m-%d)}"
[ -f "$REPO/$P" ] || { echo "stamp: no such file: $P" >&2; exit 1; }
case "$DAY" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) echo "stamp: the day must be YYYY-MM-DD" >&2; exit 1 ;;
esac
read -r SUM BYTES < <(cksum < "$REPO/$P")

if awk -F'\t' -v p="$P" '$1 == p { hit = 1 } END { exit !hit }' "$LIST"; then
  [ $# -le 2 ] || { echo "stamp: $P is listed; give the path and the day only" >&2; exit 1; }
  awk -F'\t' -v OFS='\t' -v p="$P" -v d="$DAY" -v s="$SUM" -v b="$BYTES" '
    $1 == p { $2 = d; if ($4 != "-") { $4 = s; $5 = b } }
    { print }' "$LIST" > "$LIST.new"
  mv "$LIST.new" "$LIST"
else
  [ $# -eq 5 ] || { echo "stamp: $P is new; give day, max_days, refresh and source" >&2; exit 1; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$P" "$DAY" "$3" "$SUM" "$BYTES" "$4" "$5" >> "$LIST"
fi
awk -F'\t' -v p="$P" '$1 == p { print "stamped " $1 ": built " $2 ", limit " $3 " days" }' "$LIST"
