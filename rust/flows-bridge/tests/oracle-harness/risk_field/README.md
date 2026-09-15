# Frozen Swift oracle: the risk-field reader

`../../fixtures/swift_risk_field_oracle.tsv` was produced by compiling the
ORIGINAL `RiskFieldService.swift` (with the original `HarmonicClimatology`
it rescored against) with this harness and recording its output, before that
code moved to `flows_core::risk_field`. `../../swift_risk_field_oracle.rs`
checks the Rust against it: 6,335 records in 9 kinds.

## What it pins

| record | Swift original (base commit) | Rust twin |
|---|---|---|
| `rf-parse` | `parseFRB1` over a hand-built shard, its corruptions (flipped payload byte, truncations, wrong magic, version, counts, stamp length, trailing byte, two-point ring, invalid UTF-8, byte-order marks, a duplicated family) and 30 random shards | `RiskField::parse_frb1` |
| `rf-shard`, `rf-families` | a shard written to `$FLOWS_REPO/data/runtime_cache/app_risk_bundle.frb1` and loaded by a fresh service instance (no harmonic table there, so no rescore); its `families` and `generatedUTC` | the parsed field |
| `rf-near` | the loaded service's `scoreRow(at:)` and `summary(at:)` — on centroids, beside them, at the edge of the 0.27° reach, at 65–72°N where the longitude window widens, and at random | `nearest` |
| `rf-zips` | the loaded service's `zips(in:family:limit:)` over regions of every size, unknown families and limits 0…100 000 | `family_index` + `select` |
| `rf-set`, `rf-select` | the static `selectZips` with `buildGrid` over random entry sets (ringed and ring-less, NaN and tied scores, ragged score rows) and the boxes the FLOWSTests used, plus inverted, degenerate, NaN, infinite and planet-sized ones | `RiskField::from_entries` + `select` |
| `rf-table`, `rf-rescore` | `harmonicRescore` against synthetic FLHH tables (one with a duplicated ZIP), weeks 0…104 and −1, family lists with misses and repeats | `family_pairs` + `harmonic_rescore` |

Two rules the fixture checks that a rewrite would be tempted to relax: the
viewport selection sorts with Swift's own algorithm, so tied and NaN scores
land where they did (`flows_core::learning::swift_sort_by`), and the
nearest-centroid search's longitude window is `⌈0.27 / max(cos φ, 0.15) /
0.2⌉` cells clamped to 2…6 — ±2 columns silently missed ZIPs above ~47.5°N,
and the Rust keeps the wider window.

## Reproduce

The base commit is named in the fixture's header. `stubs.swift` stands in for
the perf signposter and `SeasonalRiskModel.week()`, neither of which the
oracle exercises. The harness needs macOS (MapKit's `MKCoordinateRegion`) and
writes its shards under the temporary directory.

```sh
BASE=a007de042d12e736fdd86398e1ea54ca31aadc1f
mkdir -p /tmp/risk-field-oracle && cd /tmp/risk-field-oracle
for f in RiskFieldService HarmonicClimatology; do
  git -C "$REPO" show "$BASE:apple/FLOWS/Sources/Core/$f.swift" > "$f.swift"
done
cp "$REPO/rust/flows-bridge/tests/oracle-harness/risk_field/"{main,stubs}.swift .
xcrun --sdk macosx swiftc -O -swift-version 5 RiskFieldService.swift HarmonicClimatology.swift stubs.swift main.swift -o oracle
./oracle   # the fixture body (three header lines are prepended)
```

Three runs, one with `SWIFT_DETERMINISTIC_HASHING=1`, were byte-identical
(sha1 `3e1176a64bd4aa93c055595a8b21227dc5809545` for the body).
