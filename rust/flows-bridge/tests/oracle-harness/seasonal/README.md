# Frozen Swift oracle: the seasonal model and the route-head trainer

`../../fixtures/swift_seasonal_oracle.tsv` was produced by compiling the
ORIGINAL Swift (`SeasonalRiskModel.swift`, `RouteHeadTrainer.swift`) with this
harness and recording its output, before that math was replaced by
`flows_core::seasonal`. `../../swift_seasonal_oracle.rs` checks the Rust
against it bit for bit: 3,163 records in 29 kinds.

## What it pins

| record | Swift original (base commit) | Rust twin |
|---|---|---|
| `const` | the `SeasonalStore` statics, `RouteFeatures.count` | the `seasonal` constants |
| `wd`, `wa`, `wm` | `WeekStat.decay`, `.add`, `.mean` | `WeekStat::decayed`, `::added`, `mean_observed` |
| `im` | `SeasonalStore.isModeled` | `is_modeled` |
| `rk`, `ek`, `es`, `ok` | `RouteKey.init`, `EdgeKey.init`, the edge and origin key strings | `route_cell`, `edge_key`, `edge_key_string`, `origin_key` |
| `sp` | `SeasonalStore.seasonalPrior` | `prior_week_keys` + `seasonal_prior` |
| `ac` | `SeasonalStore.accuracy` | `accuracy` |
| `ou`, `oe` | `SeasonalStore.recordOrigin` (the update; the 200-cell eviction) | `origin_after_trip`, `origin_evictions` |
| `re`, `ee` | `SeasonalStore.recordEdges` (keys, adds; the 4,000-edge eviction) | `path_edge_keys`, `WeekStat::added`, `edge_freshness`, `edge_evictions` |
| `rc` | `SeasonalStore.record` end to end | `next_count`, `is_cross_country`, `added`, `origin_after_trip` |
| `lh`, `lg` | `SeasonalStore.learnedHome` (from origins; legacy routes) | `learned_home`, `legacy_home` (+ `parse_origin_key`) |
| `tr` | `SeasonalStore.trainingRows` | `training_rows` |
| `rf` | `RouteFeatures.vector` | `route_features` |
| `hp` | `LearnedHead.predict` | `head_predict` |
| `ft`, `me` | `RouteHeadTrainer.fineTune`, `.meanSquaredError` (defaults and explicit; the shipped baseline on realistic rows) | `fine_tune`, `mean_squared_error`, `tuned_rows` |
| `wk` | `SeasonalRiskModel.week` over a leap year | `week_of_year` |
| `copied-*` | expressions inside the `@MainActor` class, copied verbatim with line numbers | `blend_prior`, `choose_head`, `tune_due`, `accept_tune`, `mean_in_order` |

The store methods fold over Dictionaries; Rust exposes their pure pieces and
the test recomposes them the way the Swift did, over the snapshot each record
carries. Every input the harness gives those methods has an answer that does
not depend on iteration order (no weight ties at a cut, distinct per-cell
totals, evicted groups tied only among themselves). Where the original's
answer *would* depend on it — a `(0, 0)` tie for home, a NaN weight at the
top — the harness leaves the case out and says so in a comment.

## Reproduce

The base commit is named in the fixture's first line. The harness needs the
shipped baseline head as its one argument. (The loop below is `sh`/`bash`
syntax; zsh does not split `$FILES`.)

```sh
BASE=a007de042d12e736fdd86398e1ea54ca31aadc1f
mkdir -p /tmp/seasonal-oracle && cd /tmp/seasonal-oracle
for f in SeasonalRiskModel RouteHeadTrainer; do
  git -C "$REPO" show "$BASE:apple/FLOWS/Sources/Core/$f.swift" > "$f.swift"
done
cp "$REPO/rust/flows-bridge/tests/oracle-harness/seasonal/"{main,stubs}.swift .
xcrun --sdk macosx swiftc -O -swift-version 5 SeasonalRiskModel.swift RouteHeadTrainer.swift stubs.swift main.swift -o oracle
./oracle "$REPO/apple/FLOWS/Resources/baseline_route_head.json"   # the fixture body (three header lines are prepended)
```

`stubs.swift` stands in for `SecureBehaviorStore` and `FlowsDiag`, the two
app types the originals name; nothing under test touches them (persistence
is not under test, and the harness never instantiates the class).

Four runs are byte-identical: three plain runs and one with
`SWIFT_DETERMINISTIC_HASHING=1` (sha1
`c011270d8c366201ded5ca6a44e34f32a96f8925` for the body).

The binary imports `__sincos_stret`: the route feature vector takes the sine
and cosine of one angle and the optimiser fused them. Every record still
matched the Rust bit for bit, in debug and release — the fused sine differs
from the standalone one only for some arguments (see the geo README and
`docs/LEARNINGS.md`, "Two calls the optimiser turns into one").
