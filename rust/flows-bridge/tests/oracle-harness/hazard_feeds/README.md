# Frozen Swift oracle: the live hazard feeds and the alert service

`../../fixtures/swift_hazard_feeds_oracle.tsv` was produced by compiling the
ORIGINAL `HazardFeedScores` and `LiveHazardSnapshot`
(`LiveHazardFeeds.swift`, `LiveHazardScoring.swift`), the `WeatherAlertService`
statics, `BackupWarningsCache.severity` and `MexicoFuelParsing`
(`PrimarySources.swift`) at commit f36ee9e — the last before their facade
switch — with this harness and recording its output.
`../../swift_hazard_feeds_oracle.rs` checks the Rust against it: 6,670 records
in 35 kinds.

## What it pins

| record | Swift original | Rust twin |
|---|---|---|
| `hf-air`, `hf-uv`, `hf-tropint`, `hf-space`, `hf-avrating`, `hf-spc`, `hf-rad` | the scalar bands and the radiation weighting | `air_score` … `radiation_space_weather_score` |
| `hf-floodcat`, `hf-volcanolvl`, `hf-tsulevel`, `wa-sev`, `wa-backup` | the word tables, over odd spellings, cases and marks | `flood_category_score`, `volcano_alert_score`, `tsunami_level_score`, `severity_score`, `backup_severity` |
| `hf-pip`, `hf-fire`, `hf-seis`, `hf-perim`, `hf-gauge`, `hf-water`, `hf-volc`, `hf-aval`, `hf-trop`, `hf-tsu`, `hf-outlook`, `hf-closure` | every feed score at random points near seven centres, with NaN and infinite coordinates, one-point and two-point rings, and ratings and codes at `Int` extremes | the same names |
| `hf-live`, `hf-clip` | `HazardFeedScores.live` (the eight scores and the families that registered) and `LiveHazardSnapshot.clipped` over random snapshots | `live`, `Snapshot::clipped` |
| `wa-cell`, `wa-states`, `wa-marine` | `cellKey`, `statesContaining` (written sorted: the Swift read a dictionary in hash order), `marineRegionsContaining` | `cell_key`, `states_containing`, `marine_regions_containing` |
| `wa-cover`, `wa-prov`, `wa-rings` | `alertsCovering`, `provisionalSamples` (with expiry, arrival offsets and a NaN severity), `allRings` decimation over 1…2000-point rings and short coordinates | `alerts_covering`, `provisional_samples`, `all_rings` |
| `mx-prices`, `mx-places` | the CRE tag scans over broken tags, repeated ids, odd numbers and whitespace | `parse_fuel_prices`, `parse_fuel_places` |
| `u-wsnl` | `CharacterSet.whitespacesAndNewlines` over every scalar (the place scan trims with it) | `swift_text::is_whitespace_or_newline` |

Three things the fixture taught:

- `Double(Substring)` and `Double(String)` differ at an embedded NUL: the
  `String` path ends the text there (a C string), the generic `StringProtocol`
  path copies the bytes and requires all of them consumed, so it fails. The
  price scan reads a `Substring`, the place scan a trimmed `String`;
  `swift_text::swift_double_substring` carries the difference.
- The harness wrote the CRE maps in Swift's `sorted()` order, which compares
  canonically (a Kelvin sign sorts as K); the port's maps order by bytes, so
  the test puts both sides in byte order before comparing. A harness should
  sort by UTF-8 bytes to begin with.
- `statesContaining` came out of a dictionary in per-launch hash order; the
  harness sorted it, the port answers code order, and every caller used the
  answer as a set.

The corridor's noisy-OR, coverage and worst-first sort are inline in
`corridorRisk`, which fetches; they are unit-tested pure helpers
(`corridor_noisy_or`, `corridor_coverage`, `worst_first`) that the facade
calls, not oracle records.

## Reproduce

Bridge-linked, as `oracle-harness/forecast`: the originals call `RiskTiming`
and the facades of earlier landings. `stubs.swift` stands in for the network,
its caches and gates, the diagnostics log, the tuning knobs, the route sample
type and the alert and maneuver helpers other facades own.

```sh
BASE=f36ee9e
BR="$REPO/apple/FLOWS/RustBridge"
mkdir -p /tmp/hazard-oracle && cd /tmp/hazard-oracle
FILES="LiveHazardFeeds LiveHazardScoring WeatherAlertService PrimarySources POIRanking RiskTiming LaneData EnforcementCameras SpeedSign FlowsCore RiskEquations WMOAlerts PursuitReach"
for f in $FILES; do git -C "$REPO" show "$BASE:apple/FLOWS/Sources/Core/$f.swift" > "$f.swift"; done
cp "$REPO/rust/flows-bridge/tests/oracle-harness/hazard_feeds/"{main,stubs}.swift .
xcrun --sdk macosx swiftc -O -swift-version 5 -import-objc-header "$BR/BridgingHeader.h" -I "$BR" \
  "$BR/SwiftBridgeCore.swift" "$BR/flows-bridge/flows-bridge.swift" \
  $(for f in $FILES; do printf '%s.swift ' "$f"; done) stubs.swift main.swift \
  -L "$REPO/rust/target/xcode/macosx" -lflows_bridge -o oracle
./oracle   # the fixture body (three header lines are prepended)
```

Three runs, one with `SWIFT_DETERMINISTIC_HASHING=1`, were byte-identical
(sha1 in the fixture's header line is of the body).
