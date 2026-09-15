# Frozen Swift oracle: places

`../../fixtures/swift_places_oracle.tsv` was produced by compiling the
ORIGINAL `POIRanking.swift`, `PlacesStore.swift`, `POIService.swift` and
`EverydayRadius.swift` at commit 0f8894b — the last before their facade
switch — with this harness and recording its output.
`../../swift_places_oracle.rs` checks the Rust against it: 11,204 records in
27 kinds.

## What it pins

| record | Swift original | Rust twin |
|---|---|---|
| `rp-route`, `rp-near` | `RoutePath(coords:)`'s cumulative meters and `nearest(to:)` over random walks, doubled and back-tracking routes, polar and antimeridian routes, sparse routes, one-point and empty routes, with queries on vertices, on cell edges and past the sixteenth ring | `RoutePath::new`, `RoutePath::nearest` |
| `rk-annot`, `rk-food`, `rk-fuel`, `rk-hotels`, `rk-parking`, `rk-stores` | `annotate` and the five rankers over up to 150 candidates with NaN, infinite and signed-zero metrics, prices and ratings, exact ties, and tiers at `Int` extremes | `annotate`, `rank_food` … `rank_stores` |
| `pk-tier`, `ms-rank`, `ms-order`, `rk-consts`, `fuel` | the name tables over odd spellings, marks and case mappings; the constants; `FuelType`'s fill and average price | `parking_cost_tier`, `store_market_share_rank`, `STORE_MARKET_SHARE_ORDER`, `fuel_costs` |
| `ps-shard`, `ps-parse`, `ps-near`, `ps-key` | `PlacesShard(data:)` over valid shards and seventeen corruptions (hash, magic, version, truncation, offsets, counts, string lengths, grid ranges, swapped and repeated keys, padding); `places(near:)` with ill-formed UTF-8 in every text field; `cellKey` | `PlacesIndex::parse`, `places_near`, `place`, `cell_key` |
| `ps-real` | `places(near:)` on the tool-built Wisconsin shard (checked only where that exact file is present, by size and stored hash) | the same |
| `st-states`, `store-q` | `PlacesStore.states(containing:)` and the store's cross-shard query and merge over five generated state shards served from a temporary `$FLOWS_REPO` | `hazard_feeds::states_containing`, `places_near` + `rank_by_distance` |
| `svc-groups`, `svc-rank`, `svc-merged`, `svc-rowkey`, `svc-corridor`, `ev-attr` | `POIService.shardGroups`, `rank` (every kind, fuel, trucker mode, with and without a route or position, uneven price and rating lists), `merged`, `rowKey`, `corridorAhead`; `EverydayPlace.attributeID` | `shard_groups`, `rank_along` / `rank_by_distance`, `merge_everyday_first`, `attribute_id`, `first_nearest` |
| `u-prefix` | `String.hasPrefix` as the runtime answers it, the rule the shower brand pick reads | `swift_text::has_prefix` |

What stayed out of the records: `search` runs MapKit searches, so the
per-kind sets it tests, its centre spread, its dedup keys, its habit pins
and its shower brand pick are unit-tested pure helpers (`kind_policy`,
`center_picks`, `dedup_rows`, `pinned_rows`, `shower_brand`) that the facade
calls, the way the third landing handled `corridorRisk`. The brand pick
keeps one answer the Swift comment disowns: "Vista Travel" contains
"ta travel", so it reads as TA.

## Reproduce

Bridge-linked, as `oracle-harness/hazard_feeds`. `POIService`'s `rank`,
`merged`, `rowKey`, `corridorAhead` and `corridor` are private; the recipe
makes them visible with an access-only `sed`, nothing else changes.
`stubs.swift` stands in for the network, the diagnostics log, the tuning
knobs, the planned-route types, the seasonal model's learned home and the
trip-needs enum.

```sh
BASE=0f8894b
BR="$REPO/apple/FLOWS/RustBridge"
mkdir -p /tmp/places-oracle && cd /tmp/places-oracle
FILES="POIRanking PlacesStore POIService EverydayRadius DestinationPrediction RatingsAndCost BrandKnowledge ChoiceLog SecureBehaviorStore ShelterPolicy LiveHazardFeeds LiveHazardScoring WeatherAlertService PrimarySources RiskTiming LaneData EnforcementCameras SpeedSign FlowsCore RiskEquations WMOAlerts PursuitReach"
for f in $FILES; do git -C "$REPO" show "$BASE:apple/FLOWS/Sources/Core/$f.swift" > "$f.swift"; done
sed -i '' -e 's/private nonisolated static func rank(/nonisolated static func rank(/' \
  -e 's/private static func merged(/static func merged(/' -e 's/private static func rowKey(/static func rowKey(/' \
  -e 's/private func corridorAhead(/func corridorAhead(/' \
  -e 's/private var corridor: \[CLLocationCoordinate2D\]/var corridor: [CLLocationCoordinate2D]/' POIService.swift
cp "$REPO/rust/flows-bridge/tests/oracle-harness/places/"{main,stubs}.swift .
xcrun --sdk macosx swiftc -O -swift-version 5 -import-objc-header "$BR/BridgingHeader.h" -I "$BR" \
  "$BR/SwiftBridgeCore.swift" "$BR/flows-bridge/flows-bridge.swift" \
  $(for f in $FILES; do printf '%s.swift ' "$f"; done) stubs.swift main.swift \
  -L "$REPO/rust/target/xcode/macosx" -lflows_bridge -o oracle
./oracle body.tsv   # the fixture body (three header lines are prepended)
```

The harness writes its records to the path it is given: MapKit prints its
own complaints about out-of-range coordinates to standard output. Three
runs, one with `SWIFT_DETERMINISTIC_HASHING=1`, were byte-identical (sha1
in the fixture's header line is of the body).
