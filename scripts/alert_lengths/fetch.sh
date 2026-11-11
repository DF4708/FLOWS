#!/bin/bash
# How the table in rust/flows-core/src/alerts.rs (USUAL_EVENT_HOURS) was
# measured: bash fetch.sh DIR; awk -F, -f events.awk DIR/*.csv > events.tsv;
# bash lengths.sh events.tsv. Public-domain records, no key needed.
# Fetch past NWS watch/warning records (public archive, CSV), one request
# per phenomenon/significance pair per year, one at a time.
# usage: fetch.sh OUTDIR
out="$1"; mkdir -p "$out"
base="https://mesonet.agron.iastate.edu/cgi-bin/request/gis/watchwarn.py"
get() { # phen sig year
  f="$out/$1.$2.$3.csv"
  [ -s "$f" ] && return
  curl -sS -m 600 -A "curl" \
    "$base?accept=csv&sts=$3-01-01T00:00Z&ets=$(($3 + 1))-01-01T00:00Z&limitps=1&phenomena=$1&significance=$2" \
    -o "$f" || echo "FAILED $1.$2.$3"
  echo "$1.$2.$3 $(wc -l < "$f")"
  sleep 2
}
for y in 2020 2021 2022 2023 2024; do
  for ps in HU.W HU.A TR.W TR.A SS.W SS.A TY.W SQ.W DS.W EW.W TS.W FW.W FW.A; do
    get "${ps%.*}" "${ps#*.}" "$y"
  done
done
for y in 2022 2023 2024; do
  for ps in FF.W FL.W FA.W FA.A FL.A CF.W LS.W TO.W SV.W MA.W TO.A SV.A \
            BZ.W WS.W IS.W LE.W WS.A WW.Y FA.Y FL.Y FF.A FR.Y SU.Y HZ.W EH.W XH.W HT.Y EC.W WC.W CW.Y FZ.W \
            HW.W WI.Y FG.Y AS.Y AQ.Y AV.W; do
    get "${ps%.*}" "${ps#*.}" "$y"
  done
done
echo FETCH DONE
