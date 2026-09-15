# Frozen Swift oracle: trip and vehicle

`../../fixtures/swift_trip_vehicle_oracle.tsv` (8,704 records) was produced by
compiling the ORIGINAL Swift trip and vehicle code with this harness and
recording its output, before that code was replaced by
`flows_core::trip_vehicle` and its bridge. `../../swift_trip_vehicle_oracle.rs`
calls every function through `flows_bridge::trip_vehicle`, exactly as its
Swift facade will, and compares bit for bit.

Under test: `TripCosts`, `TripNeeds`, `CrashLogic`, `VehicleSpecs`,
`VehicleProfile`, `EPAVehicleDatabase`. Compiled with them so they type-check:
`POIRanking`, `TowingLimits`, `RefuelLearning`. The harness carries two
stand-ins of its own — `ThrottledNet` (nothing fetches) and an in-memory
`UserDefaults`, so the oracle never reads the user's preferences.

Doubles are IEEE-754 bit patterns in hex; `UInt64` values plain hex; strings
`s:` + UTF-8 hex; nil `-`; lists `L<n>:` + comma-separated items. Inputs that
trap the Swift (integer overflow, `Int(Double)` out of range) run in a child
process and are recorded as `trap`.

## Reproduce

The loop is `sh`/`bash` syntax; zsh does not split `$FILES`.

```sh
BASE=a007de042d12e736fdd86398e1ea54ca31aadc1f
FILES="TripCosts TripNeeds CrashLogic VehicleSpecs VehicleProfile EPAVehicleDatabase POIRanking TowingLimits RefuelLearning"
mkdir -p /tmp/trip-vehicle-oracle && cd /tmp/trip-vehicle-oracle
for f in $FILES; do
  git -C "$REPO" show "$BASE:apple/FLOWS/Sources/Core/$f.swift" > "$f.swift"
done
cp "$REPO/rust/flows-bridge/tests/oracle-harness/trip_vehicle/main.swift" .
xcrun --sdk macosx swiftc -O -swift-version 5 $(for f in $FILES; do printf '%s.swift ' "$f"; done) main.swift -o oracle
./oracle   # the fixture body (two header lines are prepended)
```
