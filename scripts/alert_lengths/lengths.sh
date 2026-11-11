#!/bin/bash
# usage: lengths.sh events.tsv   prints count, median, 90th percentile hours
# per kind, then the median by how many zones the event named.
q() { # stdin: group<TAB>hours  -> group n p50 p90
  sort -t$'\t' -k1,1 -k2,2n | awk -F'\t' '
    function out() { if (c) printf "%-14s n=%-6d p25=%-7.1f p50=%-7.1f p75=%-7.1f p90=%-7.1f\n", g, c, v[int((c-1)*0.25)+1], v[int((c-1)*0.5)+1], v[int((c-1)*0.75)+1], v[int((c-1)*0.9)+1] }
    $1 != g { out(); g = $1; c = 0 }
    { v[++c] = $2 }
    END { out() }'
}
echo "== by kind"
cut -f1,2 "$1" | q
echo "== by kind and zones (1, 2-3, 4-7, 8-15, 16+)"
awk -F'\t' '{ z = $3; b = z < 2 ? "z01" : z < 4 ? "z02" : z < 8 ? "z04" : z < 16 ? "z08" : "z16"; print $1 ":" b "\t" $2 }' "$1" | q
echo "== floods by severity (N nuisance/none, 1 minor, 2 moderate, 3 major)"
awk -F'\t' '$4 != "-" { print $1 ":" $4 "\t" $2 }' "$1" | q
