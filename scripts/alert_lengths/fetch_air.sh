#!/bin/bash
# Air quality alerts are not in the warnings archive (they carry no event
# code), so they are read from the archive of the messages themselves: each
# message's send time, and the time its area line says it stops.
# usage: fetch_air.sh OUTDIR     prints one line per message: office, hours
out="$1"; mkdir -p "$out/air"
for o in PHI LWX OKX PBZ LOT SGX LOX HNX STO SLC BOU FWD HGX FFC IND DTX MPX SEW PDT MSO BOI GRR CLE ALY BOX; do
  for y in 2023 2024; do
    f="$out/air/$o.$y.txt"
    [ -s "$f" ] || { curl -sS -m 300 -A curl \
      "https://mesonet.agron.iastate.edu/cgi-bin/afos/retrieve.py?pil=AQA$o&sdate=$y-01-01&edate=$((y + 1))-01-01&limit=9999&fmt=text" \
      -o "$f" || echo "FAILED $o $y" >&2; sleep 1; }
  done
done
awk '
  BEGIN { split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ")
          split("31 28 31 30 31 30 31 31 30 31 30 31", len, " ")
          for (i = 1; i <= 12; i++) days[m[i]] = len[i] }
  /^AEUS[0-9]+ [A-Z]+ [0-9]+/ && length($3) == 6 { sent = $3; stop = ""; month = ""; next }
  sent != "" && month == "" && / (AM|PM) [A-Z]+ [A-Z][a-z][a-z] [A-Z][a-z][a-z] [0-9]+ [0-9]+$/ { month = $(NF - 2) }
  sent != "" && stop == "" && /-[0-9][0-9][0-9][0-9][0-9][0-9]-$/ {
    stop = substr($0, length($0) - 6, 6); held = 1; next }
  held && month != "" {
    d1 = substr(sent, 1, 2) + 0; d2 = substr(stop, 1, 2) + 0
    a = d1 * 1440 + substr(sent, 3, 2) * 60 + substr(sent, 5, 2)
    b = d2 * 1440 + substr(stop, 3, 2) * 60 + substr(stop, 5, 2)
    if (b < a) b += days[month] * 1440
    h = (b - a) / 60
    if (h > 0 && h < 240) { o = FILENAME; sub(/.*\//, "", o); sub(/\..*/, "", o); printf "%s\t%.2f\n", o, h }
    held = 0; sent = ""
  }' "$out"/air/*.txt
