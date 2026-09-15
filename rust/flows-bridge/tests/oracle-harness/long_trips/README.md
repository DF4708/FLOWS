# Frozen Swift oracle: the long-drive rules

`../../fixtures/swift_long_trips_oracle.tsv` was produced by compiling the
ORIGINAL `FuelWarning.swift`, `TripShare.swift` and `OfflineCorridors.swift`
at commit d1197b5, the last before their facade switch, with this harness,
and recording its output. `../../swift_long_trips_oracle.rs` checks the Rust
against it: 6,815 records in 20 kinds.

## What it pins

| record | Swift original | Rust twin |
|---|---|---|
| `fw-band`, `fw-consts` | the gauge's severity and band around both band edges, NaN and out-of-range fractions; the cone, the warning count and the reserve | `long_trips::fuel_severity`, `fuel_band` |
| `fw-level` | the reachable list, the level and the cheapest station over repeated distances and prices, missing and NaN prices, prices a tenth of a cent apart, the default and odd reserves, and 70-station lists that take the sort's merge path | `reachable_stations`, `fuel_level`, `cheapest_station` |
| `fw-isreach` | reachability with and without a route and with the default corridor; 200 records sit on the cone's edge | `geo::fuel_station_is_reachable` |
| `ts-consts`, `ts-offer` | the long-trip line at its edge and at NaN | `should_offer_share` |
| `ts-daily` | the day odometer across days, NaN days, negative and NaN readings | `daily_drive_add` |
| `ts-rank` | suggestion order with tied and NaN, infinite and future dates, and 70-recipient lists | `ranked_recipients` |
| `ts-norm` | phone digits across scripts, keycaps, fractions, numerals and combining marks | `normalized_phone` |
| `ts-store`, `ts-suggest` | forty real `ShareHistoryStore`s fed shares one by one (the same number typed several ways, empty names, canonically equivalent digits, the date and recipient caps), with the stored list after every fifth share and the suggestions | `record_share`, `ranked_recipients` |
| `oc-consts`, `oc-worth` | the retention constants and the trip-length rule | `worth_saving` |
| `oc-keep`, `oc-prune`, `oc-super` | keeping, pruning and superseding over malformed, NaN and empty point lists, stale and future save times, and 70-corridor lists | `keep_corridor`, `prune_corridors`, `supersedes` |
| `oc-decimate` | thinning with repeated and NaN points, odd steps, and limits that sample (one 1,600-point road at the default limit) | `decimate` |
| `oc-store-record`, `oc-store-prune`, `oc-store-nearest` | forty real `OfflineCorridorStore`s recording, pruning and answering the nearest corridor | `decimate`, `record_corridor`, `prune_corridors`, `geo::corridor_nearest` |

## What the harness never touches

`ShareHistoryStore` reads the keychain when handed the standard defaults and
a plist otherwise. The harness hands it `VolatileDefaults`, a `UserDefaults`
subclass that answers nothing and stores nothing, and `stubs.swift` replaces
the keychain store. `OfflineCorridorStore` reads and writes an encrypted file
in Application Support through `SecureBehaviorStore`, which `stubs.swift`
also replaces. No record is read from or written to the owner's data.

## Reproduce

Bridge-linked, as `oracle-harness/modes`: `VehicleProfile.swift` at this
commit reads its reserve from the bridge.

```sh
BASE=d1197b5
BR="$REPO/apple/FLOWS/RustBridge"
mkdir -p /tmp/long-trips-oracle && cd /tmp/long-trips-oracle
FILES="FuelWarning TripShare OfflineCorridors POIRanking VehicleProfile RefuelLearning TowingLimits VehicleSpecs TripCosts"
for f in $FILES; do git -C "$REPO" show "${BASE}:apple/FLOWS/Sources/Core/${f}.swift" > "${f}.swift"; done
git -C "$REPO" show "${BASE}:apple/FLOWS/RustBridge/flows-bridge/flows-bridge.swift" > bindings.swift
cp "$REPO/rust/flows-bridge/tests/oracle-harness/long_trips/"{main,stubs}.swift .
xcrun --sdk macosx swiftc -O -swift-version 5 -import-objc-header "$BR/BridgingHeader.h" -I "$BR" \
  "$BR/SwiftBridgeCore.swift" bindings.swift \
  $(for f in $FILES; do printf '%s.swift ' "$f"; done) stubs.swift main.swift \
  -L "$REPO/rust/target/xcode/macosx" -lflows_bridge -o oracle
./oracle body.tsv   # the fixture body (three header lines are prepended)
```

Three runs, one with `SWIFT_DETERMINISTIC_HASHING=1`, were byte-identical
(sha1 in the fixture's header line is of the body). In zsh, write
`${BASE}:apple`, not `$BASE:apple`: `:a` is a path modifier there.
