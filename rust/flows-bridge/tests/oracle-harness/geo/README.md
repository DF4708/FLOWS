# Frozen Swift oracle: geo kernel

`../../fixtures/swift_geo_oracle.tsv` was produced by compiling the ORIGINAL
Swift geo code with this harness and recording its output, before any of that
code is replaced by calls into Rust. `../../swift_geo_oracle.rs` checks
`flows_core::geo` against it bit for bit: 5,322 records.

## What it pins

| record | Swift original (base commit) | Rust twin |
|---|---|---|
| `m` | `POIRanking.meters` | `geo::meters` |
| `brg` | `EnforcementCameras.bearingDegrees` and `FuelWarning.bearingDegrees` (both outputs) | `geo::bearing_degrees` |
| `ahead` | `EnforcementCameras.isAhead` | `geo::camera_is_ahead` |
| `reach` | `FuelWarning.isReachable` | `geo::fuel_station_is_reachable` |
| `seg`, `segk` | `HazardFeedScores.distanceToSegmentMeters`, both overloads | `geo::distance_to_segment_meters`, `_scaled` |
| `amtrak` | `AmtrakStations.nearest(to:within:in:)` | `geo::amtrak_nearest` |
| `radio` | `RadioTuning.nearest(to:in:)` | `geo::radio_nearest` |
| `scanner` | `ScannerFeedStore.nearest(to:in:)` | `geo::scanner_feed_nearest` |
| `corr` | `OfflineCorridorStore.nearest(to:)` over `SavedCorridor.coordinates` | `geo::corridor_nearest` |
| `showert`, `shower` | `ShowerAvailability.LocationTable(entries:)`, `.entry(nearLat:lon:)` | `geo::ShowerLocationTable` |
| `rp`, `rpn` | `POIRanking.RoutePath(coords:)` (`cumulative`), `.nearest(to:)` | `geo::RoutePath` |
| `cellkey` | `PlacesShard.cellKey(lat5:lon5:)` | `geo::places_cell_key` |
| `prefix` | `HybridWalk.prefixCoordinates(_:meters:)` | `geo::prefix_coordinates` |

The private grid-cell functions (`RoutePath.cell`, `LocationTable.cell`) are
pinned through the `rp`, `rpn`, `showert` and `shower` records, including the
inputs where they trap.

## Reproduce

The base commit is named in the fixture's first line.

```sh
BASE=a007de042d12e736fdd86398e1ea54ca31aadc1f
FILES="POIRanking HybridWalk FuelWarning EnforcementCameras AmtrakStations RadioTuning ScannerListener OfflineCorridors RatingsAndCost PlacesStore LiveHazardFeeds VehicleProfile FlowsDiag ScannerIncidents SecureBehaviorStore ThrottledNet AdaptiveTuning LaneData PursuitReach SpeedSign RefuelLearning TowingLimits VehicleSpecs ManeuverSymbol"
mkdir -p /tmp/geo-oracle && cd /tmp/geo-oracle
for f in $FILES; do
  git -C "$REPO" show "$BASE:apple/FLOWS/Sources/Core/$f.swift" > "$f.swift"
done
cp "$REPO/rust/flows-bridge/tests/oracle-harness/geo/main.swift" .
xcrun --sdk macosx swiftc -O -swift-version 5 $(for f in $FILES; do printf '%s.swift ' "$f"; done) main.swift -o oracle
./oracle   # the fixture body, byte for byte (the two header lines are prepended)
```

The first eleven files hold the code under test. The other thirteen are the
smallest set that lets them compile; none of their code runs.

`OfflineCorridorStore` is a `@MainActor` class whose initializer reads, and
whose writes persist to, the user's Application Support directory and
keychain. So its `nearest(to:)` body is compiled verbatim over the corridors
it reads, with the real `SavedCorridor` decoding. Check the copy is exact:

```sh
diff <(git -C "$REPO" show "$BASE:apple/FLOWS/Sources/Core/OfflineCorridors.swift" | sed -n '177,184p') \
     <(sed -n '46,53p' "$REPO/rust/flows-bridge/tests/oracle-harness/geo/main.swift")
```

## Rules the harness follows, so the output is a function of the code alone

- A seeded SplitMix64; never a system random source.
- It never iterates a `Dictionary` or `Set` to choose inputs or order
  outputs. The grids inside `RoutePath` and `LocationTable` are dictionaries,
  but they are read by key only, so no answer depends on their order.
- Doubles are recorded as IEEE bit patterns in hex, integers in decimal, nil
  as `-`.
- **Traps are observed, not predicted.** An input that can make the Swift trap
  (`Int(Double)` of a NaN, infinite or out-of-range value; `Int` overflow) runs
  in a child process: this binary with `trap <n>`. Its SIGTRAP/SIGILL handler
  exits with status 86, which the parent records as `trap`. Exiting from the
  handler leaves no crash report. The trap table uses literal inputs only, so
  parent and child build it identically. Boundary inputs that turn out not to
  trap record their real output.
- Four runs are byte-identical: three plain runs and one with
  `SWIFT_DETERMINISTIC_HASHING=1`
  (sha1 `bb6f339419502fb9c21ff396deea8fe81f1bac63` for the body).
