# Frozen Swift oracle: route tags, sensor replies, spoken replies and radio

`../../fixtures/swift_tags_and_replies_oracle.tsv` was produced by compiling
the ORIGINAL `RouteAttributes.swift`, `VehicleLink.swift`, `VoiceReply.swift`,
`BroadcastRadio.swift` and `RadioBrowser.swift` at commit b4b8cd1, the last
before their facade switch, with this harness, and recording its output.
`../../swift_tags_and_replies_oracle.rs` checks the Rust against it: 8,462
records in 26 kinds.

## What it pins

| record | Swift original | Rust twin |
|---|---|---|
| `u-letter` | `Character.isLetter` over every scalar, as ranges | `swift_text::is_letter_scalar` (the table `gen_tables.py` writes from this record) |
| `ra-grade`, `ra-clear`, `ra-weight`, `ra-flood`, `ra-consts` | grades with missing, NaN and infinite samples and odd spacings; `maxheight` and `maxweight` tags in feet and inches, metric and US units, decimal commas, fullwidth digits, marks and odd spaces; FEMA zones after trimming and uppercasing | `tags_and_replies::max_grade_percent`, `clearance_meters`, `weight_limit_lbs`, `is_high_risk_flood_zone` |
| `vl-tpms`, `vl-fuel`, `vl-obd`, `vl-consts` | sensor advertisements at the pressure window's edges with names whose uppercasing changes (`ſ`, `İ`, fullwidth letters) and short data; ELM327 replies with signs, marks and non-ASCII digits; the adapter-name check (a verbatim copy of the discovery callback's expression) | `parse_tpms_advertisement`, `displayed_psi`, `parse_fuel_reply`, `looks_like_obd_adapter` |
| `yn`, `yn-words`, `vp-choose`, `vp-place` | yes and no with curly apostrophes, marks, odd spaces and mixed replies; picks and changes of mind over offered names and cuisines | `interpret_yes_no`, `wants_weather_radio`, `choose`, `place_reply` |
| `br-kinds`, `br-kind`, `br-dial`, `br-ranked` | kind filing over tag soups; dial labels at the FM and AM edges, printf's rounding ties and non-ASCII digits; ranking with missing and NaN positions, repeated coordinates and 70-station lists | `RadioKind`, `kind_for_tags`, `dial_label`, `ranked_stations` |
| `rb-mirror`, `rb-consts`, `rb-genre`, `rb-state`, `rb-merged`, `rb-rows`, `rb-servers`, `rb-ranked` | mirror hosts with non-ASCII letters and digits; genre lists; state codes whose uppercasing changes (`ıd` is Idaho); merges with canonically equal names and URLs; directory rows decoded from real JSON, their fields as `parseStations` casts them; server names; nearest ranking with repeated URLs | `is_allowed_mirror`, `genre_words`, `state_name`, `merged_stations`, `kept_station_rows`, `unique_server_names`, `ranked_nearest` |

## What the harness never touches

`stubs.swift` stands in for the network throttle, the diagnostics journal,
the caches, the Overpass ladder and the trucker radio player. No record
reaches the network, the microphone, Bluetooth or the owner's data.

## Reproduce

Bridge-linked, as `oracle-harness/modes`: `BrandKnowledge.swift` and
`POIRanking.swift` at this commit are facades that call the bridge.

```sh
BASE=b4b8cd1
BR="$REPO/apple/FLOWS/RustBridge"
mkdir -p /tmp/tags-oracle && cd /tmp/tags-oracle
FILES="RouteAttributes VehicleLink VoiceReply RadioBrowser BroadcastRadio BrandKnowledge POIRanking VehicleProfile RefuelLearning TowingLimits VehicleSpecs TripCosts"
for f in $FILES; do git -C "$REPO" show "${BASE}:apple/FLOWS/Sources/Core/${f}.swift" > "${f}.swift"; done
git -C "$REPO" show "${BASE}:apple/FLOWS/RustBridge/flows-bridge/flows-bridge.swift" > bindings.swift
cp "$REPO/rust/flows-bridge/tests/oracle-harness/tags_and_replies/"{main,stubs}.swift .
xcrun --sdk macosx swiftc -O -swift-version 5 -import-objc-header "$BR/BridgingHeader.h" -I "$BR" \
  "$BR/SwiftBridgeCore.swift" bindings.swift \
  $(for f in $FILES; do printf '%s.swift ' "$f"; done) stubs.swift main.swift \
  -L "$REPO/rust/target/xcode/macosx" -lflows_bridge -o oracle
./oracle body.tsv   # the fixture body (three header lines are prepended)
```

Three runs, one with `SWIFT_DETERMINISTIC_HASHING=1`, were byte-identical
(sha1 in the fixture's header line is of the body). Run the loops in bash:
zsh neither splits `$FILES` nor leaves `$BASE:apple` alone.

After regenerating the fixture, rerun
`../places_text/gen_tables.py` so `swift_text/tables.rs` carries the new
letter table, then `rustfmt` that file.
