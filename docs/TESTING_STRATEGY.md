<!--
  Copyright (c) 2026 David B. Foster. All rights reserved.
  Contact: wizeman555@gmail.com
  Unauthorized copying, distribution, modification, or use of this file, in
  whole or in part, is strictly prohibited without the express written
  permission of the copyright holder.
-->

# FLOWS — testing strategy for the CONUS expansion

> "The hard right over the easy wrong. Use cause and effect. Check
> assumptions between each test. Use the scientific method. Document
> test results every time one is received."

This is the operating manual for the incremental map + route expansion
from Wisconsin to CONUS. Every change to the routing / map pipeline
during that expansion runs through the harness described here.

> **Scope update (2026-07).** The product is now the native app
> (Rust + Swift only — the AArch64 asm tier was retired 2026-07-19 when
> a measured bake-off showed rustc faster; Python is allowed as repo
> tooling/verification, never in the product). The R/Shiny engine
> described in §§2–9 was **RETIRED** (commit `c8a903e`, 2026-07-11; the
> `R/` directory is gone and `global.R`/`server.R`/`ui.R` were deleted
> 2026-07-19). It no longer runs and no longer gates anything — there is
> no `source global.R` step, no `Rscript`, no R harness. But before it
> was removed, the risk/scoring paths it defined were captured as
> **frozen reference fixtures**, and those fixtures are the oracle now
> (not a live R process). Where §§2–9 speak of the R engine and its
> gates in the present tense, read them as the historical harness that
> produced those fixtures. The current test inventory and the
> byte-identity doctrine live in §0; everything below it is that
> original CONUS harness, preserved for the record.

---

## 0. Native test inventory and byte-identity doctrine (2026-07)

### 0.1 Inventory (counted from source, not asserted)

| Suite | Where | Count | Run with |
|---|---|---|---|
| Swift XCTest | `apple/FLOWSTests/` (18 files) | **180** `func test…` | `xcodebuild test -scheme FLOWSTests` |
| Rust `flows-core` | `rust/flows-core/src/*.rs` + `src/transit/` | **55** `#[test]` | `cargo test --release -p flows-core` |
| Rust `flows-train` | `src/main.rs` + `src/bin/*.rs` (history-baseline, national-bundle, places-shard, bundle-frb) | **35** `#[test]` | `cargo test --release -p flows-train` |

That is **180 Swift + 101 Rust** tests, zero compiler warnings, and
`cargo clippy -D warnings` clean.

Swift coverage concentrates where the money is: `SafetyAndGradeTests`
(52 tests), `RiskRealizationTests` (18 — the two-tier realized-risk
design, see below), `HybridVanScenarioTests` (14), `SeasonalModelTests`
(13), `DriverFeaturesTests` (12), plus climate, POI-ranking,
badge-clustering, latitude-band, route-attribute, store/cost and
international-weather parsing suites.

A pure-std benchmark, `rust/flows-core/src/bin/bench.rs`, times the
polyline and CH hot paths over fixed seeded corpora (LCG-seeded inputs,
medians over repeated runs, zero dependencies). It is **reported, never
asserted** — a thermometer, not a gate — and fills the measurement gap
the R harness left when it retired. (Its polyline bake-off is what
retired the hand-asm kernel: the raw-pointer portable kernel out-timed
it, 2.59 vs 3.20 ns/byte.)

### 0.2 Byte-identity doctrine

Where the native code **ports** behavior from the retired R engine,
equality to the **frozen fixtures** captured from it is the acceptance
criterion — not "close enough". The fixtures are the oracle now; there
is no live R process to diff against:

- **Risk equations.** `apple/FLOWSTests/RiskEquationVectors.swift` is a
  **frozen fixture**: its expected values were computed by the original
  `R/scoring.R` equations before the engine was retired, and are now
  pinned as the oracle. `RiskEquationsTests` asserts the Swift port is
  byte-identical to them. Never hand-edited — and no longer regenerable,
  because R is gone.
- **Polyline decoder.** Two live implementations, one frozen truth: the
  Google-spec reference vector is the golden oracle. The Rust FFI decoder
  (`flows_polyline_decode` in `rust/flows-core/src/ffi.rs`) has its own
  null/short-buffer contract tests (plus the kernel tests in
  `polyline.rs`), and `CoreTests.swift` asserts the Rust-FFI path is
  byte-for-byte identical to the pure-Swift fallback and to the spec
  vector. The in-house R decoder was the retired third twin.
- **Rust ↔ reference equivalence.** The old `rust_equiv` job that diffed
  the Rust core against the live R engine retired with R. The same
  "diff against an independent oracle" discipline now lives entirely
  Rust-internal — CH vs Dijkstra and RAPTOR vs time-dependent Dijkstra
  (§0.3).
- **National ZIP bundle → FRB1.** `scripts/generate_national_bundle.sh`
  fills every uncovered CONUS ZCTA with a seasonal-climatology entry from
  `rust/flows-train/src/bin/national-bundle.rs` and copies every
  already-present entry through **byte-for-byte**, so
  `data/runtime_cache/app_risk_bundle.json` covers all 33,300 ZIPs as one
  unified 20-yr NOAA Storm Events field (no special-cased Wisconsin /
  R-engine entries, no polygon rings); that JSON is the dev/regeneration
  source. The script then serializes it to
  the binary **FRB1** sibling (`bundle-frb.rs`, bit-exact doubles) and
  copies it to `apple/FLOWS/Resources/app_risk_bundle.frb1` — the app
  loads THAT with **zero JSON parse** on the launch path
  (`RiskFieldService.parseFRB1`). The old shipped
  `Resources/app_risk_bundle.json` was removed when FRB1 replaced it.
  Byte-identity is gated at both ends: `bundle-frb.rs` has round-trip +
  corruption tests, and
  `HarmonicClimatologyTests.testFRB1ParseRoundTripAndCorruptionRefusal`
  round-trips a hand-assembled shard and rejects corrupted / truncated /
  bad-magic input.

Where native code implements a **new design** with no R counterpart,
tests assert design properties instead. `RiskRealizationTests` says so
explicitly in its header: it verifies the two-tier realized-risk model
(`RiskEquations.realizedRisk` — primary hazard families can reach Red
alone; secondary predictors only amplify a realized primary and are
capped below Red; `RiskEquations.alertFamily` splits warnings =
realized from watches/forecasts = predictors), not byte-identity to a
prior version.

### 0.3 Algorithm gates: independent oracles

New routing algorithms are accepted only against an independent
reference implementation (the §4.1 "quality parity" principle, applied
natively):

- **RAPTOR vs Dijkstra.** The transit engine's correctness gate
  (`rust/flows-core/src/transit/raptor.rs`,
  `correctness_gate_matches_reference_dijkstra`) checks RAPTOR earliest
  arrivals over seeded random timetables against a label-setting
  time-dependent Dijkstra written independently over the same
  timetable. Same discipline as the ch.rs-vs-Dijkstra gate.
- **Shipped self-test.** `flows_transit_selftest()` in `ffi.rs` runs a
  1500-case check and is force-linked into every app binary
  (`-Wl,-u,_flows_transit_selftest` in `apple/project.yml`), so the
  gate travels with the product.

### 0.4 Continuous runner (live smoke workflow)

`scripts/autonomous_test_runner.sh` is the always-on measurement loop.
The R gates it once rotated are gone; each pass now runs the native
suites under a **memory governor** and mtime gate: `swift_suite`
(`xcodebuild … FLOWSTests test`, run only when a file under `apple/` is
newer than the last pass) and `rust_r0_gate` (`cargo test --release
-j 1`, run only when memory < 82 % and a `.rs` file is newer than the
last-pass marker). The pinned byte-identity oracles ride inside those
suites, so the equivalence guarantees survive the R runtime's removal.
Results append to `data/results/continuous_results.jsonl` (8 MiB
rotated); over many passes these are distributions (p50/p95), not
point estimates. Stop with `touch tests/.stop_runner`. App-level live
smoke is `xcodebuild -scheme FLOWS-macOS build` (or `FLOWS-iOS`) plus
a launch against live NWS/WZDx feeds.

### 0.5 CI (`.github/workflows/ci.yml`)

The only CI workflow. It replaced `.github/workflows/r.yml` on
2026-07-19 — that one `rcmdcheck`'d the retired R engine (no
`DESCRIPTION`, no `R/`), so it could never pass and misled the repo
status. Two jobs run on `macos-latest` (arm64 — the same ISA family the
product ships on):

- **rust** — `cargo clippy --workspace --all-targets -- -D warnings`
  (clean) then `cargo test --release --workspace` (includes the
  CH/RAPTOR oracle gates).
- **swift** — `brew install xcodegen`, `xcodegen generate`, then
  `xcodebuild … -scheme FLOWSTests … test`.

---

## 1. Principles

### The hard right over the easy wrong

If a change is fast to implement but would silently regress route
quality, safety popup accuracy, or fresh-data invariants (see
[LEARNINGS.md](LEARNINGS.md)), it does not ship. Rollback is always
cheaper than propagation.

### Scientific method

Each experiment is a self-contained record of:

```
{
  id, timestamp, hypothesis, assumptions,
  baseline_protocol, baseline_measurement,
  intervention,
  post_protocol, post_measurement,
  effect (post − baseline),
  significance (does the effect exceed the noise floor?),
  conclusion (SUPPORTED / REFUTED / INCONCLUSIVE),
  next_action (LAND / ROLL_BACK / REDESIGN)
}
```

The harness appends each experiment to a versioned log
(`data/results/experiments.jsonl` — the authored scientific record,
crash-safe on the project volume) and re-runs the SQA + mutation suite
as part of every post-measurement. A regression on either aborts and
records `next_action = ROLL_BACK`.

### Assumptions are stated up front and checked between each test

Every experiment declares its assumptions as a named list. Before
running the intervention, the harness re-runs each assumption's
verification predicate. If any assumption is falsified, the experiment
does not run — you get `next_action = REDESIGN` with the falsified
assumption highlighted.

Example assumption list for a routing experiment:

```r
assumptions <- list(
  wi_road_graph_intact       = function() nrow(load_wi_roads()) > 80000,
  no_regression_from_last    = function() Rscript_ok("tests/sqa_runner.R"),
  free_disk_gb               = function() disk_free_gb() > 5,
  network_reachable          = function() ping("api.weather.gov"),
  ci_load_below_2            = function() cpu_load1() < 2.0
)
```

### Cause and effect

The only variable allowed to change between baseline and post is the
intervention. If the intervention is "increase mc.cores from 12 to
24", the harness records BOTH runs on the same machine, same TTL, same
external cache state. If a shared cache would confound the measurement,
the harness clears it first (documented per-experiment).

### Document every result

Never overwritten. `data/results/experiments.jsonl` is append-only. A
regression that's rolled back is still a data point about what doesn't
work; that data survives.

---

## 2. Regression gates (all experiments)

> **Status (2026-07):** the **R reference engine** these gates ran
> against was **retired** — the gates below no longer execute (there is
> no `R/`, no `Rscript`, no `tests/` harness). They are preserved here
> as the historical record of how that engine was gated, and as the
> definition of the behavior later frozen into the §0 fixtures. Landing
> today means passing the §0 suites (180 Swift + 101 Rust tests) and CI,
> not these.

Every experiment's post-measurement must pass these gates before the
intervention is considered LAND-eligible:

| Gate | Command | Acceptance |
|---|---|---|
| Parse all files | `Rscript -e 'for (f in list.files("R", "\\\\.R$", full.names=TRUE)) parse(f)'` | zero errors |
| Source-load global | `Rscript -e 'source("global.R", chdir=TRUE)'` | exit 0 |
| Runtime smoke | `Rscript scripts/runtime_smoke_test.R` | exit 0 |
| SQA suite | `Rscript tests/sqa_runner.R` | "All 8 SQA suites PASSED" |
| Mutation harness | `Rscript tests/mutation_test.R` | "Mutations killed: 13 / 13" |
| Modeled-road equivalence | `Rscript tests/test_modeled_road_risk.R` | speedup ≥ 20×, all columns match |
| Polyline decoder | `Rscript tests/test_polyline_decoder.R` | "PASS: polyline decoder gate" (byte-identical to retired reference) |
| Static analysis | `Rscript tests/static_analysis.R` | only known-safe findings |

A single gate failure aborts the experiment and records
`next_action = ROLL_BACK`.

---

## 3. Latency budgets

Every experiment measures against these budgets. Regressions on any
row abort the experiment.

| Metric | Wisconsin baseline (measured) | CONUS Phase 1 target | CONUS Phase 4 target |
|---|---|---|---|
| Cold `build_risk_polygons` | 22 s | ≤ 45 s | ≤ 90 s |
| Warm `build_risk_polygons` | 3 s | ≤ 5 s | ≤ 10 s |
| Warm `build_driving_roads_overlay` | 3 s | ≤ 5 s | ≤ 10 s |
| Route graph build (cold) | **17 s** (measured) | ≤ 20 s | ≤ 20 s |
| Route plan latency, WI corpus | **p50 2.7 s / p95 3.7 s** (measured) | ≤ p95 3.7 s | ≤ p95 3.7 s |
| Interstate route (500 mi) | infeasible now | ≤ 8 s | ≤ 4 s |
| Cross-country route (2 500 mi) | infeasible now | infeasible | ≤ 4 s |
| Peak resident memory during build | ~ 1 GB | ≤ 2 GB | ≤ 6 GB |
| Persisted snapshot on disk | ~ 130 MB (measured) | ≤ 250 MB | ≤ 1 GB |
| First-paint TTI | ~ 2 s | ≤ 3 s | ≤ 5 s |

> **Assumption correction (2026-07-01).** An earlier draft of this table
> asserted "Intrastate route (100 mi) < 1 s". Direct measurement via
> `tests/jobs/route_bench.R` over an 8-pair Wisconsin corpus (Milwaukee↔
> Madison through Kenosha↔Superior ~380 mi) **refutes** that: route
> planning is **p50 2.7 s, p95 3.7 s, max 4.2 s** with a **17 s cold
> graph build**. The sub-second claim was an unverified assumption. The
> real numbers are now the baseline the CONUS targets are set against —
> the whole point of "cross-country loads as fast as local" is to hold
> the p95 flat as the graph grows, and the honest local baseline is
> ~3.7 s p95, not < 1 s. Recorded as experiment `route-latency-baseline`
> in `data/results/experiments.jsonl`. The continuous runner
> (`scripts/autonomous_test_runner.sh`) re-samples this distribution on
> every pass so the baseline is a distribution, not a point estimate.

Baselines are captured by `tests/conus_experiment_harness.R baseline`
and continuously re-sampled by `scripts/autonomous_test_runner.sh`.

---

## 4. Correctness gates

Beyond regression gates, CONUS experiments introduce new correctness
questions. Each has an oracle in the harness:

### 4.1 Route quality parity

For a fixed corpus of 100 seed OD pairs (defined in
`tests/route_corpus_wi.json`), the route returned before the
intervention and the route returned after must satisfy:

- Same start / end nodes.
- Total mileage within ±5 % of baseline (or better).
- Total ETA within ±10 % of baseline.
- Ranking of {fastest, safest, metro/metrorail} preserved.
- No new segment crosses a red-risk polygon that wasn't crossed by the
  baseline route.

If the intervention introduces a hierarchical routing algorithm
(contraction hierarchies, ALT), correctness parity is the acceptance
gate — otherwise the algorithm "wins" the latency budget by producing
worse routes.

### 4.2 Popup content stability

For the 861 WI ZIPs (Phase 1) or the expanded population (Phases 2+),
every ZIP's popup text is compared to a golden fixture:

- Same `risk_reason_text`.
- Same `risk_component_summary_text`.
- Same `risk_type_summary_text` (with the "NA family → No material
  contributors" invariant preserved).
- Same `driving_reason_text` (with the safety-vs-throughput discipline
  preserved).

### 4.3 Coverage completeness

- Zero ZIPs with `NA` forecast temperature in the persisted snapshot.
  The degraded-snapshot guard remains in force.
- Zero visible roads whose `road_source` is `"511WI travel times"` or
  matches `is_operational_only_511_text`.
- Zero popup text matching `is_travel_delay_reason`.

### 4.4 Fork safety (repeat gate)

- No zombie R processes after a warmer run.
- `mclapply` return list has no NULL / `try-error` entries — soft
  failures caught and retried per the `forecast_baseline` pattern.

---

## 5. Experiment templates

Three archetypes cover most CONUS work. See
`tests/conus_experiment_harness.R` for the executable definitions.

### 5.1 Data-scale experiment

Widen an input source (add a state; add a gauge network). Measure the
effect on build time, memory, and disk snapshot size.

```r
experiment_data_scale(
  id = "phase-2a-add-minnesota-zctas",
  hypothesis = paste(
    "Adding MN ZCTAs to zip_static will increase cold",
    "build_risk_polygons by < 30 % while keeping WI popups identical."
  ),
  assumptions = list(
    mn_gpkg_exists       = function() file.exists("data/reference/mn.gpkg"),
    wi_popups_unchanged  = function() Rscript_ok("tests/sqa_runner.R")
  ),
  intervention = function() { include_state("MN"); rebuild_reference() },
  measurements = c("cold_polygons", "peak_mem", "snapshot_mb"),
  budgets      = c(cold_polygons = 45, peak_mem = 2e9, snapshot_mb = 250)
)
```

### 5.2 Algorithm-scale experiment

Change an algorithm. Baseline and post measure the same corpus; the
harness diffs quality metrics.

```r
experiment_algorithm(
  id = "phase-3-contraction-hierarchies",
  hypothesis = paste(
    "Building contraction hierarchies during offline",
    "prep + querying via CH will keep interstate route",
    "latency < 4 s AND preserve quality parity on the 100-route corpus."
  ),
  assumptions = list(
    ch_lib_installed     = function() requireNamespace("cchelpers"),
    corpus_stable        = function() file.mtime("tests/route_corpus_wi.json") < Sys.time()
  ),
  baseline_impl  = "R/checkpoints/route_pathfind.R.wisconsin-baseline",
  intervention   = function() install_ch_pathfinder(),
  measurements   = c("route_latency_p50","route_latency_p95","route_quality_diff"),
  budgets        = c(route_latency_p95 = 4, route_quality_diff = 0.05)
)
```

### 5.3 Infrastructure-scale experiment

Change concurrency / caching. Not visible to product; measured only
on wall-clock and resource usage.

```r
experiment_infrastructure(
  id = "phase-1-nwps-24cores",
  hypothesis = "NWPS at 24 cores × 4 s timeout reduces cold Flood guidance step from 67s to < 30s p50.",
  assumptions = list(
    cpu_cores_available = function() parallel::detectCores() >= 24
  ),
  intervention = function() set_nwps_concurrency(cores = 24, timeout = 4),
  measurements = c("flood_step_p50","flood_step_p95"),
  budgets      = c(flood_step_p50 = 30, flood_step_p95 = 60)
)
```

---

## 6. Rollback protocol

If any post-measurement fails a regression gate OR a budget:

1. Harness writes `next_action = ROLL_BACK` in
   `data/results/experiments.jsonl`.
2. Working-tree changes attributed to the intervention are reverted:
   - If the intervention was a checkpoint swap (`R/checkpoints/*` file
     copied over `R/`), the previous checkpoint is restored.
   - If the intervention was a config change (constants in `global.R`),
     the change is undone via the harness's tracked-change stack.
3. A follow-up post-rollback measurement runs the same gates — if
   THAT fails, the harness stops and screams for a human.
4. The failed hypothesis is preserved in the log for later analysis.
   Never mark an experiment `SUCCESS` after a rollback.

---

## 7. Cadence

Two-tier:

- **Every commit** — the §0 native suites and CI
  (`.github/workflows/ci.yml`): `xcodebuild test -scheme FLOWSTests`,
  `cargo test --release --workspace`, and `cargo clippy -D warnings`.
  Fast (< 5 min). The R regression gates (parse + smoke + SQA +
  mutation) that once ran here retired with the engine.
- **Every intervention** — full experiment record with baseline + post
  measurements. Slow (5–30 min depending on scope).
- **Continuously** — `scripts/autonomous_test_runner.sh` (§0.4) refills
  the gate rotation forever; cargo runs are mtime- and memory-gated so
  the loop stays a steady ~1-core load.

Baseline measurements are re-captured whenever the WI reference data
version changes; the harness records the reference SHA so a mid-flight
data update doesn't silently confound results.

---

## 8. Reporting

`data/results/experiments.jsonl` is the authoritative record. `tests/report.R`
prints a human-readable summary:

```
=== FLOWS experiment log ===

  ID                                    Effect       Result       Action
  ------------------------------------- ------------ ------------ ---------
  phase-1-nwps-24cores                  -47 s (p50)  SUPPORTED    LAND
  phase-1-message-sign-bulk-matrix      -74 s        SUPPORTED    LAND
  phase-2a-add-minnesota-zctas          +38 % cold   PARTIAL      REDESIGN
  ...
```

The report is committed to git after every merge so the historical
record is versioned alongside the code that produced it.

---

## 9. What "done" looks like

CONUS Phase 4 is done when, for the corpus:

- All regression gates pass.
- Cold-cache warmer completes in ≤ 90 s wall-clock.
- Cross-country route (Portland OR → Portland ME, 2 500 mi) completes
  in ≤ 4 s p95, with quality parity ≥ 95 % of the intrastate baseline.
- Peak resident memory ≤ 6 GB.
- Zero popup text matches the operational / travel-delay sanitisers.
- Every experiment in `experiments.jsonl` between the baseline and
  Phase 4 either has `conclusion = SUPPORTED` or a documented
  `next_action = ROLL_BACK` that restored the previous good state.

Anything less is not shipped.
