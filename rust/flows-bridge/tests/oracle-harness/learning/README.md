# Frozen Swift oracle: the learned models

`../../fixtures/swift_learning_oracle.tsv` was produced by compiling the
ORIGINAL Swift learned-model code with this harness and recording its output,
before that math was replaced by `flows_core::learning`.
`../../swift_learning_oracle.rs` checks the Rust against it bit for bit:
11,283 records in 38 kinds.

## What it pins

| record | Swift original (base commit) | Rust twin |
|---|---|---|
| `const`, `iconst`, `table`, `fidx` | the store statics, `TrafficWeather.allCases`, `EverydayCategory.featureIndex` | the `learning` constants, `TRAFFIC_WEATHER_NAMES`, `everyday_feature_index` |
| `q`, `rad`, `mean`, `sd` | `EverydayStore.quantile`, `.radiusMiles`, `.meanTripMiles`, `.tripMilesSD` | `everyday_quantile`, `everyday_radius_miles`, `everyday_mean_trip_miles`, `everyday_trip_miles_sd` |
| `miles` | `EverydayStore.miles(from:to:)` (the haversine) | `everyday_miles` |
| `tripok`, `twin` | `EverydayStore.recordTrip` (the gate; the 200-trip window) | `everyday_accepts_trip` (+ the window, recomposed) |
| `hb`, `fv` | `EverydayStore.hourBucket`, `EverydayFeatures.vector` | `everyday_hour_bucket`, `everyday_features` |
| `rank`, `evict` | `EverydayStore.ranked`, `remember`'s eviction | `everyday_ranked_order`, `everyday_evict_index` |
| `tw`, `rc` | `TrafficWeather.from(family:)`, `RoadClass.from(averageMph:)` | `traffic_weather_from_family`, `road_class_is_highway` |
| `tmean`, `emean` | `DelayCell.mean`, `RoadEfficiencyStore.Cell.mean` | `DelayCell::mean`, `EfficiencyCell::mean` |
| `tdecay`, `edecay` | `TrafficDelayStore.decay`, `RoadEfficiencyStore.decay` | `decay_plan` + `scale_all` |
| `trec`, `tfac` | `TrafficDelayStore.record`; `.factor`, `.adjustedSeconds`, `.predictedDelayMinutes`, `.isConfident` | `traffic_accepts` + `traffic_add`; `traffic_factor`, `traffic_adjusted_seconds`, `traffic_delay_minutes`, `traffic_is_confident` |
| `erec`, `eeco` | `RoadEfficiencyStore.record`; `.economy`, `.isConfident` | `efficiency_accepts` + `efficiency_add`; `efficiency_economy`, `efficiency_is_confident` |
| `bu`, `bus`, `bw` | `BufferLearning.updated`, `.isUsable`, `.waitSeconds` | `buffer_updated`, `buffer_is_usable`, `buffer_wait_seconds` |
| `ra`, `rsp`, `rerr`, `rcap`, `sg` | `RefuelLearning.accuracy`, `.shouldPrompt`, `.record` (the error; the 50-answer window), `StaleGauge.wentStale` | `refuel_accuracy`, `refuel_should_prompt`, `refuel_error` (+ the window), `gauge_went_stale` |
| `em`, `er` | `DrivingProfile.etaMultiplier`, `.recordArrival` | `eta_multiplier`, `eta_record` |
| `dr`, `dreason`, `dconf` | `DestinationPrediction.rank`, `.reason(for:)`, `.isConfident` | `destination_rank`, `destination_reason`, `destination_is_confident` |

The store methods are pure pieces in Rust; the test recomposes `record`,
`decay`, the eviction and the two windows the way the Swift did, over the
snapshot each record carries. No input makes the original trap; those cases
are pinned in Rust unit tests instead.

Two `rank` records are known divergences, named in the test: Swift's
`String <` is not a consistent order for canonically equivalent names in
different encodings (false in both directions for "öz" against "o\u{308}";
"가 " before the jamo spelling of "가"). The port orders NFC bytes, which is
what Swift does once both names are NFC.

## Reproduce

The base commit is named in the fixture's first line. `EverydayPlaces`
names `SeasonalRiskModel.shared`, so the two seasonal sources compile too;
`stubs.swift` stands in for `SecureBehaviorStore` and `FlowsDiag`, which
nothing under test touches. (The loop is `sh`/`bash` syntax; zsh does not
split `$FILES`.)

```sh
BASE=a007de042d12e736fdd86398e1ea54ca31aadc1f
FILES="EverydayRadius TrafficLearning RoadEfficiencyLearning BufferLearning RefuelLearning DrivingProfile DestinationPrediction SeasonalRiskModel RouteHeadTrainer"
mkdir -p /tmp/learning-oracle && cd /tmp/learning-oracle
for f in $FILES; do
  git -C "$REPO" show "$BASE:apple/FLOWS/Sources/Core/$f.swift" > "$f.swift"
done
cp "$REPO/rust/flows-bridge/tests/oracle-harness/learning/"{main,stubs}.swift .
xcrun --sdk macosx swiftc -O -swift-version 5 $(for f in $FILES; do printf '%s.swift ' "$f"; done) stubs.swift main.swift -o oracle
./oracle   # the fixture body (three header lines are prepended)
```

Four runs are byte-identical: three plain runs and one with
`SWIFT_DETERMINISTIC_HASHING=1` (sha1
`31ae746ad6deb34eef51c4f8fce98ffe2f70949d` for the body).

Two facts about the Release compiler that the fixture carries, both
reproduced in Rust in every build mode:

- `pow(0.5, x)` is compiled as `exp2(-x)` (a power-of-two base), which
  differs from libm `pow` by one ulp for about 0.4 % of arguments; the
  harness's decay-threshold records sit exactly on such an argument. Rust
  writes `(t / -half_life).exp2()`.
- The binary imports `__sincos_stret` (the feature vector takes sin and cos
  of one angle); every `fv` record matched regardless.

The `miles` records were added after the first landing, from their own
seeded generator at the end of the harness, so every earlier record kept its
bytes; the haversine matched bit for bit without a tolerance.
