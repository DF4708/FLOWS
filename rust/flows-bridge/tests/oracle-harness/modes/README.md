# Frozen Swift oracle: devices, playback and other ways to travel

`../../fixtures/swift_modes_oracle.tsv` was produced by compiling the
ORIGINAL `SignalQuality.swift`, `AdaptiveTuning.swift`,
`PlaybackFallback.swift`, `PlaybackGrace.swift`, `RadioTuning.swift`,
`AmtrakStations.swift`, `BreadcrumbTrail.swift`, `AirTravel.swift`,
`Mobility.swift` and `HybridWalk.swift` at commit bea472d, the last before
their facade switch, with this harness, and recording its output.
`../../swift_modes_oracle.rs` checks the Rust against it: 7,161 records in
34 kinds.

## What it pins

| record | Swift original | Rust twin |
|---|---|---|
| `sq-tier`, `sq-prestage`, `sq-drain` | the link tier over real and odd radio-technology names, the pre-staging triggers, the draining test with NaN and infinite readings | `media_policy::signal_tier`, `should_pre_stage`, `is_draining` |
| `at-base`, `at-settings` | the device tier at core and memory edges; every tier × thermal state (including an unknown raw value) × Low Power Mode | `device_tier`, `tuning_settings` |
| `pf-lost`, `pf-restore`, `pf-consts`, `pg-grace`, `pg-consts` | the fallback ladder with whitespace-only and marked genres, the restore rule, the buffer grace for every player and buffer edge | `on_connection_lost`, `should_restore`, `grace_seconds` |
| `rt-nearest`, `rt-retarget`, `rt-consts` | the nearest transmitter with ties, repeated stations, repeated ids and NaN coordinates; the retarget rule | `nearest_station`, `retarget` |
| `am-nearest` | the nearest Amtrak station within a radius, including NaN and infinite radii | `travel_modes::nearest_within` |
| `bc-should`, `bc-trail`, `bc-consts` | the recording rule near (0, 0) and at the 25 m step; trails driven through a real `BreadcrumbTrail` (one past the 6,000-point cap) and their way-back meters | `should_record`, `way_back_meters` |
| `air-miles`, `air-score`, `air-pick`, `air-consts` | flight timing and fare at distance edges, the airport name score, the airport pick | `flight_seconds`, `door_seconds`, `fare_estimate`, `airport_score`, `pick_airport` |
| `tc-peak`, `tc-local`, `tc-consts` | the rush windows at every edge, local minutes across the epoch and the antimeridian | `is_peak`, `local_minutes`, `traffic_interval_seconds` |
| `blob-clusters`, `blob-hull` | risk-area clustering with repeated and NaN points, hulls of 0 to 30 points with NaN and negative padding | `risk_clusters`, `risk_hull` |
| `fares`, `fares-flat`, `hw-cost`, `hw-consts`, `hw-bar`, `hw-eval`, `hw-prefix` | the fare formulas, the ride cost, the significance bar, the offer, the drop-off prefix with repeated and NaN vertices | `amtrak_fare`, `ride_cost`, `meets_bar`, `evaluate_ride`, `prefix_coordinates` |

`BreadcrumbTrail`'s initializer reads the saved trail through the
keychain-sealed store, so `stubs.swift` replaces that store: the harness
never touches the owner's data. The stubs also stand in for the transit
wording and the route sampler, which the records never use.

## Reproduce

Bridge-linked, as `oracle-harness/places`: `POIRanking.swift` at this commit
is a facade that calls the bridge, and its distance primitive is the one
these files use.

```sh
BASE=bea472d
BR="$REPO/apple/FLOWS/RustBridge"
mkdir -p /tmp/modes-oracle && cd /tmp/modes-oracle
FILES="SignalQuality AdaptiveTuning PlaybackFallback PlaybackGrace RadioTuning AmtrakStations BreadcrumbTrail AirTravel Mobility HybridWalk POIRanking TripCosts"
for f in $FILES; do git -C "$REPO" show "$BASE:apple/FLOWS/Sources/Core/$f.swift" > "$f.swift"; done
cp "$REPO/rust/flows-bridge/tests/oracle-harness/modes/"{main,stubs}.swift .
xcrun --sdk macosx swiftc -O -swift-version 5 -import-objc-header "$BR/BridgingHeader.h" -I "$BR" \
  "$BR/SwiftBridgeCore.swift" "$BR/flows-bridge/flows-bridge.swift" \
  $(for f in $FILES; do printf '%s.swift ' "$f"; done) stubs.swift main.swift \
  -L "$REPO/rust/target/xcode/macosx" -lflows_bridge -o oracle
./oracle body.tsv   # the fixture body (three header lines are prepended)
```

Three runs, one with `SWIFT_DETERMINISTIC_HASHING=1`, were byte-identical
(sha1 in the fixture's header line is of the body).
