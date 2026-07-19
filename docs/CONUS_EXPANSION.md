<!--
  Copyright (c) David B. Foster. All rights reserved.
  Contact: wizeman555@gmail.com
  Unauthorized copying, distribution, modification, or use of this file, in
  whole or in part, is strictly prohibited without the express written
  permission of the copyright holder.
-->

# Wisconsin → CONUS expansion

> **HISTORICAL (2026-07-19).** This was the plan for widening the original
> R engine from Wisconsin to CONUS. It has since been overtaken: the R
> engine is retired, and the shipping native app already covers the whole
> US uniformly — a 33,300-ZCTA on-device risk field scored from 20 years of
> NOAA Storm Events history (no Wisconsin special-casing), plus Rust
> Contraction-Hierarchies routing. `global.R` and the other R sources
> referenced below no longer exist. Kept as the historical expansion record.

Migration plan for widening FLOWS from Wisconsin-only to the whole
continental United States (CONUS), with cross-country routing as fast
as intrastate routing.

The plan runs on the testing strategy in
[TESTING_STRATEGY.md](TESTING_STRATEGY.md). No CONUS work lands
without a `SUPPORTED` experiment record.

---

## 1. What's Wisconsin-specific today

Every one of these must generalise. Enumerated by category:

### 1.1 Config / constants (global.R)

| Constant | Current | Post-CONUS |
|---|---|---|
| `TARGET_STATE` | `"WI"` | list of states (`"CONUS"` sentinel) |
| `TARGET_STATE_FIPS` | `"55"` | vector of FIPS codes |
| `BORDER_STATE_FIPS` | 5 codes | ~50 codes |
| `FORECAST_REGION_COUNT` | 18 | ~4 000 (all NWS gridpoints) or 200 (WFO offices) |
| `NWS_ALERTS_URL` | `?area=WI` | multiplex per-state or `?area=US` |
| `RADNET_WI_MONITOR_SPECS` | 4 WI stations | RadNet's ~140 CONUS stations |
| `WI511_*_URL` (4 endpoints) | Wisconsin 511 API | 50 different state 511 APIs — most states have their own; some have none |
| `WI_MAGNETIC_DECLINATION_DEG` | −2.5° | latitude/longitude dependent — call NOAA WMM API |
| `REFERENCE_GPKG_PATH` | `wisconsin_reference.gpkg` | `conus_reference.gpkg` OR per-state shards |

### 1.2 Reference data (`data/reference/wisconsin_reference.gpkg`)

Currently one 14 MB GeoPackage with five layers:

| Layer | Wisconsin | Estimated CONUS |
|---|---|---|
| counties | 72 | ~3 100 |
| zctas | 861 | ~33 000 |
| places | 808 | ~30 000 |
| roads (primary/secondary) | 6 328 | ~150 000 |
| border_states | 5 | ~50 |

The single-file model won't scale — a monolithic 500 MB+ gpkg fights
memory. Design change:
- Split by state (`data/reference/states/<FIPS>.gpkg`).
- On demand, load only states within the current view / route
  corridor.
- Keep a lightweight index (`data/reference/state_index.rds`) mapping
  each ZCTA / county / place to its state file.

### 1.3 OSM road graph (`data/reference/wi_osm_roads.rds`)

Currently 7.6 MB with ~90 k edges (Wisconsin OSM extract).

CONUS: the North America OSM PBF is ~11 GB; the drivable extract is
~30 million edges. The current flat-table + Dijkstra approach is
approximately three orders of magnitude too slow for cross-country
queries.

**Structural change required**: precomputed hierarchical routing —
either

- **Contraction hierarchies (CH)** — the OSRM / Valhalla approach.
  Build once (hours). Queries are milliseconds even coast-to-coast.
- **A\* with Landmarks + Triangle inequality (ALT)** — the Delling &
  Wagner approach. Middle ground; build in minutes.
- **Hub Labels** — asymptotically fastest, largest memory.

For FLOWS, CH is the pragmatic choice: mature R interop via
`{cchelpers}` or direct FFI to OSRM's C++ preprocessor, sub-4-s query
latency at CONUS scale.

### 1.4 511 state transport feeds

Non-uniform coverage. Rough breakdown of what states publish:

- **JSON API (like Wisconsin)**: CA (511.org), CT, FL, GA, IA, IL, IN,
  KY, MA, MD, MI, MN, MO, NC, NH, NJ, NY, OH, PA, TN, TX (per
  metro-area feeds), VA, WA.
- **Feed-only (RSS/no structured API)**: AL, AR, KS, MS, NE, NM, OK,
  SC, WV.
- **No public feed**: AK, DE, HI, ID, LA, ME, MT, ND, NV, OR, RI, SD,
  UT, VT, WY, plus some others.

Design: an adapter layer. Each state gets its own
`R/state511/<state>.R` implementing a small interface
(`fetch_winter`, `fetch_events`, `fetch_message_signs`). The current
`R/wi511_*.R` becomes `R/state511/wi.R`. States without an API contribute
zeros.

### 1.5 NWPS gauges

Currently: 455 Wisconsin bbox gauges, 24-core parallel fetch, ~15 s
warm / ~65 s cold. CONUS: ~13 000 gauges. Linear scaling on cores
alone: ~7 min cold. Requires either:

- Regional shards fetched on demand (only the states covering the
  current view / route corridor).
- Or bulk endpoint aggregation if NOAA publishes one.

The gauge dataset is the largest external fetch by far and the biggest
single risk to the cold-cache latency budget.

### 1.6 Forecast baseline

Currently: 18 hand-picked WI forecast regions, per-region NWS
`/gridpoints/.../forecast/hourly` fetch, ~1 s cold with fork-parallel.

CONUS-scale approaches:

- **Per-WFO** (~150 offices) — one NWS office serves each county-tier
  region. Fetch the office's forecast product; broadcast to every ZIP
  in that office's coverage.
- **Per-grid** (~4 000 unique gridpoints) — one fetch per ZIP-cluster.
  Much larger fan-out; ideal only with heavy caching.

Per-WFO is the pragmatic starting point.

---

## 2. Phased rollout

Each phase is a distinct set of experiments in
`tests/experiments.jsonl`. A phase does not begin until the previous
phase's acceptance gate is met.

### Phase 0 — Baselines & guardrails (this session)

- Checkpoint current routing (**done**: `R/checkpoints/`).
- Document architecture, learnings, testing strategy (**done**: this
  directory).
- Build the experiment harness (**next**:
  `tests/conus_experiment_harness.R`).
- Capture Wisconsin baselines for every metric the CONUS work will be
  compared against.

**Acceptance**: baseline row present in `tests/experiments.jsonl`;
all gates green.

### Phase 1 — Midwest (WI + 5 border states)

MN, IA, IL, MI, IN. Rough 4× data volume vs WI.

- Introduce per-state adapter layer for reference geometry
  (`data/reference/states/<FIPS>.gpkg`, index file).
- Introduce per-state 511 adapter (`R/state511/`).
- Extend `apply_alert_coverage_to_zips` to accept multi-state alerts.
- Bump NWPS bbox and confirm still parallelisable (~1 800 gauges).
- **No routing algorithm change yet** — Phase 1 is data-scale only.

**Acceptance**: cold `build_risk_polygons` ≤ 45 s; warm ≤ 5 s; peak
memory ≤ 2 GB; all correctness gates preserved on the WI corpus.

### Phase 2 — Region packs (Northeast, Southeast, West, Central)

Each region added as an independent shard, loaded on demand based on
the current view / route corridor.

- Refactor `zip_static` from a global to a lazy loader
  (`load_zip_static(region)`).
- Refactor `wi_zctas` / `wi_bounds` naming — they become
  `active_zctas` / `active_bounds` reflecting the current view.
- Refactor snapshot naming — instead of one whole-CONUS snapshot,
  per-region snapshots merged on load.

**Acceptance**: cold `build_risk_polygons` still ≤ 45 s with any
single-region view active; region switch (user pans coast-to-coast) is
≤ 3 s.

### Phase 3 — Cross-region routing (hierarchical routing lands here)

Introduce contraction hierarchies (or ALT). This is the single largest
technical change in the CONUS expansion.

- Add `scripts/build_ch.R` — offline preprocessing that emits
  `data/reference/ch/<region>.rds`.
- Rewrite `native_plan_routes` to detect single-region vs
  cross-region queries; cross-region delegates to CH.
- Preserve `route_edge_keys`, `route_overlap_ratio`, popup building,
  and profile ranking unchanged so the front end doesn't know.
- Correctness parity gate on the 100-route corpus.

**Acceptance**: interstate route (500 mi) p95 ≤ 4 s; cross-country
route (2 500 mi) p95 ≤ 4 s; quality parity ≥ 95 % vs the flat-A\*
baseline on within-region OD pairs.

### Phase 4 — CONUS complete

All 50 states + DC + PR (as available). Full 511 adapter matrix.
Full CH index for CONUS.

**Acceptance**: every budget row in [TESTING_STRATEGY.md §3](TESTING_STRATEGY.md#3-latency-budgets)
met at the "Phase 4 target" column.

---

## 3. Cross-country routing algorithm — detailed plan

The single hardest piece. Reproduced here in enough detail to guide
implementation.

### 3.1 Why the current router won't scale

`route_pathfind.R` builds a graph from the flat edge table and runs a
binary-heap-backed A\*. On WI's ~90 k-edge graph, Dijkstra visits
tens of thousands of nodes for a state-crossing query. On CONUS'
~30 M-edge graph, a coast-to-coast query would need to touch a similar
*fraction* of the graph — tens of millions of nodes — because the A\*
heuristic (crow-fly distance) doesn't discriminate well over
intercontinental distances. Cold queries would take minutes; warm
queries would still take seconds.

### 3.2 Contraction hierarchies — the intended solution

Idea: offline, precompute a topological ordering where every node
gets a **level**. During preprocessing, iteratively remove nodes in
low-to-high level order; when a node is removed, add "shortcut" edges
between its neighbours that preserve shortest-path distances.

At query time, A\* only considers edges leading to a strictly higher
level. The search space collapses dramatically — for CONUS,
milliseconds to tens of milliseconds per query.

### 3.3 R-side integration

Two viable paths:

1. **`{cchelpers}` R package** — R-native, works out-of-the-box.
   Slower preprocessing but no C++ dependency.
2. **Direct FFI to OSRM's C++ preprocessor** — build OSRM's
   preprocessor offline (produces `.osrm.hsgr` file); load via
   `{Rcpp}` at query time. Faster preprocessing, faster queries,
   external C++ dep.

Path 1 for the first landing; Path 2 as an optimisation experiment if
warranted.

### 3.4 Safety-risk integration with CH

CH edges get baseline weights during preprocessing. But FLOWS re-weights
edges by live segment risk (`1 + 4·risk + closure_pen`). Options:

- **Option A**: rebuild CH indices whenever segment risks change
  (cheap for a single road; expensive for whole-CONUS state changes).
- **Option B**: keep two CH indices — baseline and "avoid red" — and
  query both, blending results by profile weight.
- **Option C**: at query time, override CH shortcuts that include a
  red-risk segment; fall back to unpacked A\* on those.

Option C matches the "safety over throughput" principle:
short-circuit the CH win when a shortcut goes through a hazard, at
the cost of some query latency in exactly those cases. That's the
right trade.

### 3.5 What lands during Phase 3

- `scripts/build_ch.R` — offline preprocessing (assumes Path 1).
- `data/reference/ch/<region>.rds` — one file per region, ~50-500 MB.
- `route_pathfind.R` — split into `route_pathfind_astar.R` (kept
  verbatim, used for intra-region queries) and `route_pathfind_ch.R`
  (new, used for cross-region).
- `native_plan_routes` — detects same-region vs cross-region via
  index lookup; delegates.
- New scientific-method experiments:
  - `phase-3-ch-baseline-parity` (does CH preserve route quality?)
  - `phase-3-ch-cross-country-latency` (does CH hit the 4 s p95 target?)
  - `phase-3-ch-red-shortcut-detour` (does Option C correctly avoid a
    red segment even when the CH shortcut would use it?)

---

## 4. Migration strategy — order of operations

1. **Land Phase 0** (this session): checkpoints + docs + harness +
   baselines. **Does not change** any product behaviour. Fully
   reversible.
2. **Land Phase 1** (data scale + adapters + shards). Product behaviour
   changes: more states covered. Reversible via git.
3. **Land Phase 2** (lazy loading). Big architectural refactor.
   High-risk. Every experiment must show the WI ZIP popups remain
   pixel-perfect against the Phase 1 golden fixture.
4. **Land Phase 3** (CH routing). The largest single change. Must land
   behind a feature flag (`CH_ROUTING_ENABLED`) so a regression can be
   turned off in one line of config.
5. **Land Phase 4** (fill in remaining states + polish).

Every phase ends with an updated `R/checkpoints/*.<phase>-baseline`
snapshot so the next phase has an anchor.

---

## 5. Known risks

| Risk | Mitigation |
|---|---|
| NWS API rate limits at CONUS scale | Aggressive TTL + per-WFO caching + jittered request timing |
| 511 state APIs go down individually | Adapter layer — one state's outage doesn't crash the map |
| CH preprocessing times out on CI | Preprocess offline on a beefier build machine; commit the emitted `.rds` |
| Popup HTML size explodes at 33k ZIPs | Lazy popups (already implemented via `LAZY_ZIP_POPUPS_ENABLED`) |
| Cross-region cache invalidation | Region-scoped TTLs; one region's stale data doesn't force a global rebuild |
| Storage budget (~1 GB snapshots) | Keep only the most recent per-region snapshot; older ones age out |
| RadNet /NRC national scale | Their JSON is already national; the WI-only filter is a downstream slice, cheaply generalised |
| Golden fixtures drift with real-world data | Golden fixtures reference the *shape* of the popup, not the exact numeric values; equivalence tests target specific known-hazard rows manually curated |

---

## 6. What survives the expansion

- The safety-vs-throughput discipline in the 511 scorers.
- The sanitiser boundary rule (every snapshot read runs current
  sanitisers).
- The three-tier cache model.
- The vectorised compose helpers.
- The mutation harness.
- The SQA suite.
- Every learning captured in [LEARNINGS.md](LEARNINGS.md).

None of them are WI-specific. The scale changes; the discipline
doesn't.
