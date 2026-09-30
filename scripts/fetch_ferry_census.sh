#!/bin/bash
# -----------------------------------------------------------------------------
# Copyright (c) 2026 David B. Foster. All rights reserved.
# Contact: wizeman555@gmail.com
# Unauthorized copying, distribution, modification, or use of this file, in
# whole or in part, is strictly prohibited without the express written
# permission of the copyright holder.
# -----------------------------------------------------------------------------
#
# Download the inputs for flows-train's `ferries-table`: the Bureau of
# Transportation Statistics' 2024 National Census of Ferry Operators —
# terminals, route segments, which operator runs each, and the operators.
#
# SOURCE: https://data.bts.gov (Maritime and Waterways, "2024 NCFO …").
# A work of the United States Government: public domain, free for
# commercial use with nothing owed.
#
# Usage: scripts/fetch_ferry_census.sh <work-dir>
#   writes <work-dir>/{terminals,segments,operator_segments,operators}.csv
#   then: cargo +1.93.0 run --release -p flows-train --bin ferries-table -- \
#           <work-dir> rust/flows-core/src/ferries_table.rs
# Needs: curl. No Python — FLOWS has none.
set -euo pipefail

OUT="${1:?work dir}"
mkdir -p "$OUT"

get() { # get <name> <socrata id>
  curl -sS -L --fail --max-time 120 -o "$OUT/$1.csv" \
    "https://data.bts.gov/api/views/$2/rows.csv?accessType=DOWNLOAD"
  echo "$1: $(($(wc -l < "$OUT/$1.csv") - 1)) rows"
}

get terminals difu-6bgs
get segments 2ygc-ds4z
get operator_segments 7umd-qc2k
get operators qzhh-3xej
