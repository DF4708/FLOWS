#!/bin/bash
# The kinds the first pass did not hold: wildfires (national incident
# records), statements drawn as an area, and ashfall, tsunami and air quality
# year by year (the archive refuses a request of a year or more).
# usage: fetch_rare.sh OUTDIR
out="$1"; mkdir -p "$out/fires" "$out/sps" "$out/vtec"
W="https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/WFIGS_Incident_Locations/FeatureServer/0/query"
off=0
while :; do
  f="$out/fires/p$off.json"
  [ -s "$f" ] || curl -sS -m 300 -A curl -G "$W" \
    --data-urlencode "where=IncidentTypeCategory='WF' AND IncidentSize>=10 AND ContainmentDateTime IS NOT NULL AND FireDiscoveryDateTime IS NOT NULL" \
    --data-urlencode "outFields=FireDiscoveryDateTime,ContainmentDateTime,FireOutDateTime,IncidentSize,POOState" \
    --data-urlencode "orderByFields=OBJECTID" --data-urlencode "returnGeometry=false" \
    --data-urlencode "resultOffset=$off" --data-urlencode "resultRecordCount=2000" \
    --data-urlencode "f=json" -o "$f"
  n=$(jq '.features | length' "$f")
  echo "fires offset $off: $n"
  [ "$n" -gt 0 ] 2>/dev/null || break
  off=$((off + n)); sleep 1
done
for m in 2024-01 2024-04 2024-07 2024-10; do
  f="$out/sps/$m.zip"; y=${m%-*}; mo=${m#*-}
  [ -s "$f" ] || curl -sS -m 600 -A curl \
    "https://mesonet.agron.iastate.edu/cgi-bin/request/gis/sps.py?sts=$m-01T00:00Z&ets=$m-15T00:00Z" -o "$f"
  echo "sps $m $(wc -c < "$f")"; sleep 2
done
base="https://mesonet.agron.iastate.edu/cgi-bin/request/gis/watchwarn.py"
get() { # phen sig year
  f="$out/vtec/$1.$2.$3.csv"
  [ -s "$f" ] && return
  curl -sS -m 600 -A "curl" \
    "$base?accept=csv&sts=$3-01-01T00:00Z&ets=$(($3 + 1))-01-01T00:00Z&limitps=1&phenomena=$1&significance=$2" \
    -o "$f" || echo "FAILED $1.$2.$3"
  echo "$1.$2.$3 $(wc -l < "$f")"
  sleep 1
}
for y in 2008 2009 2010 2011 2012 2013 2014 2015 2016 2017 2018 2019 2020 2021 2022 2023 2024; do
  for ps in TS.W TS.A TS.Y AF.Y AF.W AQ.Y; do
    get "${ps%.*}" "${ps#*.}" "$y"
  done
done
echo FETCH DONE
