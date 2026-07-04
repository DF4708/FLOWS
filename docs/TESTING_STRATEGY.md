# FLOWS — testing strategy for the CONUS expansion

> "The hard right over the easy wrong. Use cause and effect. Check
> assumptions between each test. Use the scientific method. Document
> test results every time one is received."

This is the operating manual for the incremental map + route expansion
from Wisconsin to CONUS. Every change to the routing / map pipeline
during that expansion runs through the harness described here.

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
(`tests/experiments.jsonl`) and re-runs the SQA + mutation suite as
part of every post-measurement. A regression on either aborts and
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

Never overwritten. `tests/experiments.jsonl` is append-only. A
regression that's rolled back is still a data point about what doesn't
work; that data survives.

---

## 2. Regression gates (all experiments)

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
| Static analysis | `Rscript tests/static_analysis.R` | only known-safe findings |
| Dead-code scan | `Rscript tests/find_dead_code.R` | Total: 0 |

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
> in `tests/experiments.jsonl`. The continuous runner
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
   `tests/experiments.jsonl`.
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

- **Every commit** — regression gates only (parse + smoke + SQA +
  mutation). Fast (< 5 min).
- **Every intervention** — full experiment record with baseline + post
  measurements. Slow (5–30 min depending on scope).

Baseline measurements are re-captured whenever the WI reference data
version changes; the harness records the reference SHA so a mid-flight
data update doesn't silently confound results.

---

## 8. Reporting

`tests/experiments.jsonl` is the authoritative record. `tests/report.R`
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
