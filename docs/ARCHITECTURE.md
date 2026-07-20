<!--
  Copyright (c) 2026 David B. Foster. All rights reserved.
  Contact: wizeman555@gmail.com
  Unauthorized copying, distribution, modification, or use of this file, in
  whole or in part, is strictly prohibited without the express written
  permission of the copyright holder.
-->

# FLOWS — Architecture

> **Forecasted Live Operational Weather System** — hazard-aware travel.
> FLOWS is now a **single system**: the **native Apple app** (SwiftUI UI +
> `rust/flows-core` compute over a C FFI) that fuses federal weather /
> hydrology / air / radiation / seismic / roadway feeds into a
> ZIP-code-precise national driving / walking / transit navigator.
>
> The product ships in exactly **two languages**: **Rust** (core
> algorithms, data pipelines, on-device training) and **Swift** (the app).
> The original R / Shiny "Wisconsin" engine that started the project was
> **retired** in commit `5ed9cc0` (2026-07-11); the `R/` directory and the
> root Shiny files were deleted. Its scoring survives only as pinned test
> fixtures. See §9 for that history.

This document is the map. If you need to change the codebase, start
here to figure out which module owns the concept and which downstream
consumers you'll break. Sections 1–8 describe the live native app and
its offline data pipelines; section 9 is the clearly-labeled historical
record of the retired R engine — past tense, kept because it is
legitimately part of the project's origin and because its scores are
still the parity oracles for the Rust port.

---

## 1. Layers, top-down

```
                     ┌────────────────────────────────────┐
SwiftUI / MapKit ──▶ │  UI layer (apple/FLOWS/Sources/UI) │
                     │  ContentView (map, hatch overlays, │
                     │  badges) · PlannerPanel · Route-   │
                     │  ChoicesView · NavigationHUD ·     │
                     │  AlertBanners · HazardStyle        │
                     └──────────────┬─────────────────────┘
                                    │
                     ┌──────────────▼─────────────────────┐
                     │  Core services (Sources/Core)      │
                     │  FlowsCore model · RiskEquations · │
                     │  RiskFieldService · WeatherAlert-  │
                     │  Service · LiveHazardFeeds ·       │
                     │  RouteService · NavigationEngine · │
                     │  SeasonalRiskModel · POIService …  │
                     └──────┬───────────────┬─────────────┘
                            │               │
             ┌──────────────▼───┐   ┌───────▼──────────────────┐
             │ rust/flows-core  │   │ Live feeds (keyless)     │
             │ via C FFI:       │   │ NWS alerts+forecast,     │
             │ scoring, risk,   │   │ WZDx DOT closures, USGS, │
             │ distance, poly-  │   │ Open-Meteo/intl (WMO),   │
             │ line decode, CH, │   │ Census ZCTA on demand    │
             │ transit RAPTOR   │   └──────────────────────────┘
             └──────────────────┘
                            │
             ┌──────────────▼──────────────────────────────┐
             │ Bundled data (apple/FLOWS/Resources):       │
             │ app_risk_bundle.frb1 (national ZIP field,   │
             │ FRB1 binary), nwr_stations.json, shower     │
             │ CityTables, baseline_route_head.json        │
             └─────────────────────────────────────────────┘
```

The app is **fully self-contained at runtime**: it ships the national
risk field as a binary FRB1 file and reaches keyless live feeds
directly; there is no server component and nothing calls R. The offline
data pipelines that produce the bundle (`rust/flows-train`) and train the
learned route head are Rust; the app statically links `rust/flows-core`
over the C FFI (`rust/flows-core/src/ffi.rs`).

---

## 2. Directory map

The source tree is **`rust/` + `apple/`**. R is gone.

```
FLOWS/
├── apple/                          ← native Apple app (see §7)
│   ├── FLOWS/
│   │   ├── Sources/
│   │   │   ├── Core/               ← ~51 Swift service/model files
│   │   │   ├── UI/                 ← ContentView, PlannerPanel, HUD, …
│   │   │   ├── CarPlay/            ← CarPlay scene
│   │   │   ├── FLOWSApp.swift  FLOWSIntents.swift  Theme.swift
│   │   ├── Resources/              ← app_risk_bundle.frb1 (national ZIP
│   │   │                             field), nwr_stations.json,
│   │   │                             baseline_route_head.json,
│   │   │                             per-brand shower city tables
│   │   └── Generated/              ← xcodegen output
│   ├── FLOWSTests/                 ← 162 Swift tests
│   ├── FLOWSWatch/                 ← watchOS companion
│   ├── tools/                      ← app-side build tooling
│   └── project.yml                 ← xcodegen project spec
├── rust/
│   ├── flows-core/                 ← scoring, risk, distance, polyline,
│   │   ├── src/transit/            ← CH router, owned RAPTOR transit engine
│   │   └── src/bin/                ← bench.rs (kernel bake-off), gtfs-ftt.rs
│   └── flows-train/                ← learned-head trainer (pure std, zero
│       └── src/bin/                   crates) + data builders:
│                                      national-bundle.rs, history-baseline.rs,
│                                      bundle-frb.rs, places-shard.rs
├── ml/route-gnn/                   ← run_worker.sh weekly training worker
│                                     (launchd template, logs, models)
├── scripts/
│   ├── generate_national_bundle.sh ← national-bundle → bundle-frb → FRB1
│   ├── build_history_baseline.sh   ← 20-yr NOAA Storm Events baseline
│   ├── build_ftt.sh  fetch_gtfs.sh ← transit timetable build
│   ├── build_places_shards.sh  fsq_places_to_tsv.py   ← POI shards
│   ├── autonomous_test_runner.sh   ← cron-driven build+test loop
│   ├── worker.sh  sync_to_shared.sh
├── .github/workflows/ci.yml        ← Rust + Swift CI (replaced dead r.yml)
├── docs/
│   ├── ARCHITECTURE.md             ← this file
│   ├── APPLE_APP.md / FLOW_APP.md  ← native-app feature docs
│   ├── LANGUAGE_ARCHITECTURE.md    ← the two-language rule
│   ├── RUST_SWIFT_MIGRATION.md     ← stack rule + FFI surface
│   ├── TRANSIT_ROUTING.md          ← owned RAPTOR engine
│   ├── DATA_FEEDS.md  CRASH_SURVIVAL.md
│   ├── LEARNINGS.md / TESTING_STRATEGY.md
│   ├── CONUS_EXPANSION.md
│   └── MOBILE_PACKAGING.md         ← historical (packaging the R app)
├── data/
│   ├── reference/                  ← pipeline inputs: ZCTA gazetteer,
│   │                                 ZCTA↔county, NOAA storm_events/,
│   │                                 places TSV, zone↔county
│   ├── places/  transit/  results/ ← POI shards, .ftt timetables, outputs
│   └── runtime_cache/              ← dev/regeneration sources +
│                                     app_risk_bundle.json (33,300 zips) +
│                                     gitignored leftovers
└── images/                         ← UI banner + docs figures
```

---

## 3. Data flow — the national risk field

The app never builds the choropleth live; it **ships** it. The national
ZIP risk field is produced offline by Rust tools, converted to a binary
shard, and parsed on the launch path with zero JSON cost.

```
scripts/build_history_baseline.sh
│   downloads keyless inputs (NOAA NCEI Storm Events details CSVs
│   2005–2024, Census ZCTA gazetteer + ZCTA↔county + NWS zone↔county)
│
├── history-baseline.rs   (rust/flows-train/src/bin)
│     per ZCTA × week-of-year × hazard family:
│     20-year event frequencies from NOAA Storm Events; point events
│     snap to the nearest ZCTA centroid, county/zone-coded events spread
│     over their ZCTAs with weight 1/n; log-linear score normalized to a
│     per-family p95, hard-capped at 0.6 (< the 0.699 yellow cut — a
│     historical PRIOR may never manufacture a realized hazard)
│
scripts/generate_national_bundle.sh
│
├── national-bundle.rs    seasonal-climatology floor for every CONUS ZCTA
│     (week-of-year sinusoid; blended max(history, climatology))
│
└── bundle-frb.rs         JSON → FRB1 binary (bit-exact f64 doubles)
      writes app_risk_bundle.frb1 and copies it into
      apple/FLOWS/Resources/
```

The result is **one unified national field of 33,300 ZCTAs**, every one
scored from the 20-year NOAA Storm Events history baseline (with the
seasonal climatology as a conservative floor). There are **no
special-cased or byte-preserved Wisconsin / R-engine entries** — every
ZCTA carries the same `z` (ZIP) / `c` (centroid `[lon, lat]`) / `s`
(scores aligned to the bundle's `families` array) / `t` (optional summary)
shape — and there are **no polygon rings in the bundle**:
`ZCTAFetcher` (`apple/FLOWS/Sources/Core/ZipBordersAndTransit.swift`)
fetches ZCTA borders on demand.

**On-device load** — `Core/RiskFieldService.swift` parses
`app_risk_bundle.frb1` via `parseFRB1` (magic `FRB1`, little-endian
fixed-width records, FNV-1a integrity check) with no JSONDecoder on the
cold-start path, and selects visible ZIPs through a spatial grid
(`selectZips`). The 2.85 MB JSON copy was removed from `Resources`;
`data/runtime_cache/app_risk_bundle.json` remains only as the
dev/regeneration source and an on-disk fallback.

The app's *live* map layer is a thin dynamic overlay on top of this
static field: `Core/WeatherAlertService.swift` pulls NWS active alerts
for the viewport and `Core/LiveHazardFeeds.swift` serves DOT closures and
the other live primary hazards (§7.2).

---

## 4. Routing & transit

There is no server-side router. Trip planning is on-device
(`Core/RouteService.swift`, `Core/NavigationEngine.swift`,
`UI/RouteChoicesView.swift`):

- **Corridor scoring** — the app requests candidate routes from MapKit
  Directions and scores each corridor with `RiskEquations` over sampled
  grid points, fusing the static ZIP field with live NWS alerts
  (`corridorRisk`) and WZDx closures. This MapKit-directions +
  corridor-scoring path is what carries the national (CONUS) scale that a
  single Wisconsin OSM graph could not.
- **Two-truths ranking** — `RiskEquations.rankingRisk` (route ordering
  only, never the display band) noisy-ORs the realized band with
  0.6-discounted identified ZIP exposure; as the on-device seasonal prior
  accrues confidence it takes over from the static field.
- **GO gating** — the GO affordance is gated per-route on `weatherScored`:
  a route can't be started before its corridor score has landed.
- **Transit** — the MapKit transit stopgap is being replaced by the
  **owned Rust RAPTOR engine** over `.ftt` timetables
  (`rust/flows-core/src/transit/`, binary-searched `earliest_trip`) — see
  [`TRANSIT_ROUTING.md`](TRANSIT_ROUTING.md). Rail + bus multi-select
  cards each carry their own itinerary (`Core/TransitItinerary.swift`) and
  exact ticket links (`TransitTickets`).
- **CH router status** — the Rust contraction-hierarchy router
  (`rust/flows-core/src/ch.rs`) is built and tested (query cost ==
  Dijkstra, faster in practice) but not yet wired into the app's routing
  UI; it is retained for the transit/graph work.

ETA has **no real-time traffic input**; road-tier base speeds carry a
risk penalty. See §7.4 for the full trip-planning surface (cost banners,
walking fallback, tourist filter).

---

## 5. External feeds inventory (all keyless)

| Feed | Owner | Purpose |
|---|---|---|
| NWS Active Alerts (viewport bbox) | `Core/WeatherAlertService.swift` | live alert polygons on the map + per-sweep `corridorRisk` over route grid points |
| NWS gridpoint forecast (QPF, temp, wind) | `Core/NWSForecastService.swift` | `ForecastConditions.qpfInches` etc. for corridor scoring |
| WZDx open-feed registry (data.transportation.gov) | `Core/LiveHazardFeeds.swift` (`ensureWZDxRegistry`, `roadClosures`) | DOT-reported road closures → `closure` primary, per-state cache, registry refreshed daily |
| USGS / tsunami / volcanic / fire live hazards | `Core/LiveHazardFeeds.swift` | remaining primary families |
| International weather (WMO-coded) | `Core/InternationalWeather.swift`, `Core/WMOAlerts.swift` | coverage beyond NWS (Canada/Mexico corridors) |
| Census ZCTA borders | `Core/ZipBordersAndTransit.swift` (`ZCTAFetcher`) | on-demand ZIP polygons (bundle ships no rings) |
| NOAA Weather Radio station list | `Resources/nwr_stations.json` (static) | trucker radio GPS-nearest streams |

**No paid API key** is required for any feed. All app network access
funnels through `Core/ThrottledNet.swift`. The offline pipelines (§3)
pull NOAA NCEI Storm Events and Census reference files, also keyless.

For the full endpoint-by-endpoint list see
[`DATA_FEEDS.md`](DATA_FEEDS.md).

---

## 6. Test harness & CI

- **Swift**: **162 tests** in `apple/FLOWSTests/` (risk equations and
  realization, climate profiles, harmonic climatology, badge clustering,
  towing/vehicle limits, transit/route attributes, seasonal model, places
  store, latitude-band parity, driver features, crash logic, …).
- **Rust**: **90 `#[test]`s** across `flows-core` (scoring / risk R-parity
  oracles, distance, polyline equivalence, CH, transit RAPTOR) and
  `flows-train` (trainer, `national-bundle`, `history-baseline`,
  `bundle-frb`). The polyline suite pins the shipped kernel and the safe
  oracle byte-identical (§8).

The whole tree is **zero-warnings** and `cargo clippy --all-targets -D
warnings` clean. CI is [`.github/workflows/ci.yml`](../.github/workflows/ci.yml):
a Rust job (`cargo clippy -D warnings` + `cargo test --release`) and a
Swift job (`xcodegen generate` + `xcodebuild … test`). It replaced the
dead `r.yml`, which `rcmdcheck`'d the R engine retired in `5ed9cc0` and
could never pass. The autonomous build+test loop runs
`scripts/autonomous_test_runner.sh`.

The R engine's scoring survives only as **pinned fixtures**: the Rust
scorer's R-parity oracles reproduce the retired engine's numbers exactly,
so the physics is preserved even though the R code is gone. The CONUS
experiments layer on top (see [`TESTING_STRATEGY.md`](TESTING_STRATEGY.md)
and [`CONUS_EXPANSION.md`](CONUS_EXPANSION.md)).

---

## 7. Native app architecture

Everything below lives under `apple/FLOWS/Sources/` unless noted.

### 7.1 Risk model — two-tier realized risk

`Core/RiskEquations.swift` is the single scoring authority (shared by
the map, the route scorer, and the live corridor monitor):

- **Primary families** — `fire`, `qpf_flood`/`flood`, `storm`
  (warning-level convective), `closure` (DOT-reported road closure),
  `seismic`, `tsunami`, `tropical`, `volcanic` — proof of in-progress
  danger; they combine by unweighted noisy-OR and can reach Red alone
  (`RiskEquations.primaryFamilies`).
- **Secondary / predictor families** — `wind`, `heat`, `cold`, `air`,
  `radiation`, `precip`, `winter` (forecast), `convective` (SPC
  outlook), `avalanche` (danger rating) — they **amplify** a realized
  primary (scaled by how realized it is: no primary ⇒ no
  amplification) and alone are capped at `secondaryCeiling = 0.80`,
  structurally below `RISK_RED_MIN`. Overlapping predictors can never
  sum to a lethal band (`RiskEquations.realizedRisk`).
- **Proof-not-prediction rule** — `RiskEquations.alertFamily(_:)` maps
  NWS event names: warnings of in-progress danger (Tornado Warning,
  Flood Warning, Tsunami Warning, …) land in a primary family;
  watches, advisories, and condition warnings (Winter Storm, High
  Wind, Red Flag, Flood Watch) land in a predictor family.
- **Flood physics** — QPF inches (`ForecastConditions.qpfInches`,
  `Core/NWSForecastService.swift`) × **relative** corridor elevation:
  `RiskEquations.floodElevationMultiplier` scores where a sample sits
  within its own corridor's min/max elevation, so a mountain-town
  valley floor floods at 8,000 ft absolute. It multiplies the precip
  *predictor* only — never manufactures proof.
- **Seasonal-normal presentation gates** —
  `Core/ClimateProfiles.swift` defines 12 Köppen-style climate types
  computed from lat/lon/elevation; `seasonalNorms(week:…)` blends
  winter/summer norms sinusoidally by week-of-year, and
  `temperatureBeyondNormal` / `windBeyondNormal` gate display:
  weather that is normal for *here, this season* never draws.
  `Core/LatitudeBands.swift` is retained only as a parity-scoring input
  (matching the retired R engine's latitude bands); the 1-D latitude
  bands are superseded for temperature normalization.

### 7.2 Ingestion & the national ZIP field

- `Core/WeatherAlertService.swift` pulls NWS active alerts for the map
  viewport and computes per-sweep `corridorRisk` over route grid
  points.
- `Core/LiveHazardFeeds.swift` (`LiveHazardFeedFetcher`) maintains the
  WZDx open-feed registry (fetched from data.transportation.gov,
  refreshed daily) and serves `roadClosures(minLat:…)` from keyless
  state-DOT feeds with a per-state cache — feeding the `closure`
  primary on both the map and route corridors, plus the other live
  primary-hazard feeds.
- `Core/RiskFieldService.swift` loads the national
  `app_risk_bundle.frb1` (33,300 ZIPs scored from the 20-yr NOAA Storm
  Events history baseline, built per §3; no special-cased Wisconsin
  entries, no polygon rings) via `parseFRB1` and selects visible ZIPs
  through a spatial grid (`selectZips`). Borders come from `ZCTAFetcher`
  on demand.

### 7.3 Map presentation

`UI/ContentView.swift` + `UI/HazardStyle.swift`:

- Risk areas render as transparent fills with alternating
  risk-color / hazard-type **hatch stripes**. MapKit's `MapPolygon`
  ignores `ImagePaint` pattern fills, so stripes are drawn as clipped
  `MapPolyline` hatch segments (`ContentView.hatchLines`).
- Hazard badges snap to ZCTA shoelace centroids
  (`Core/BadgeClustering.swift`); circular "blobs" survive only as a
  non-overlapping fallback when no polygon is available.
- Mode-aware traveler marker (car / walk / tram / bus; leg-aware on
  transit), 3D terrain toggle (`.realistic` map style + pitched
  camera), and a finer risk grid at deep zoom.
- Offline: `Core/BreadcrumbTrail.swift` records the traveled path;
  an `NWPathMonitor` banner plus a "Find my way back" affordance
  retrace it with no connectivity.

### 7.4 Routing & trip planning

`Core/RouteService.swift`, `UI/RouteChoicesView.swift`,
`Core/NavigationEngine.swift` (routing engine overview in §4):

- **Walking** — a single pedestrian MapKit request with a driving
  fallback; the substitution is disclosed via the `plannerNotice`
  banner (`RouteChoicesView`).
- **Cost banners** — Cheapest / Most-efficient badges from
  `Core/TripCosts.swift` (fuel cost via `Core/FuelPrices.swift` +
  per-fuel gCO₂ and per-passenger-mile transit constants).
- **Tourist route filter** — pins attractions along candidates and
  shows per-card attraction counts.
- **Transit tickets** — `TransitTickets` gives exact booking links
  (Amtrak/Greyhound pages, the station's own URL for local agencies —
  no Apple Maps handoff). When no local rail exists, the planner
  recommends the nearest Amtrak station.

### 7.5 Learned route prediction

`Core/SeasonalRiskModel.swift` + `rust/flows-train`:

- **Seasonal prior** — week-of-year buckets with a 52-week half-life
  decay, frequency gating (local routes need ≥6 observations,
  cross-country ≥2), a hub/edge trip graph, and `learnedHome` /
  `homeAnchor` inference.
- **Learned head** — `LearnedHead`, a small MLP over the
  `RouteFeatures` 6-vector, trained off-device by `rust/flows-train`
  (pure std, zero crates) via `ml/route-gnn/run_worker.sh` (weekly
  launchd template `com.flows.routegnn.plist.template`); the app loads
  the JSON weights when present (`Resources/baseline_route_head.json`
  seeds it), nil until the worker produces one.
- **Phase 2b (future, documented not built)** — a GNN over the trip
  graph, Rust-trained, executed in Swift via MLTensor/BNNS on the ANE
  (see [`RUST_SWIFT_MIGRATION.md`](RUST_SWIFT_MIGRATION.md)).

### 7.6 POI layer

`Core/POIService.swift`, `Core/POIRanking.swift`,
`Core/RatingsAndCost.swift`, `Core/TruckerRadio.swift`:

- **Stores** kind: 8 categories, ranked Yelp-rating-desc then
  market-share, brand-augmented search queries, no MapKit category
  filter. **Tourist** kind for attractions.
- **Showers** — verified per-city tables for Pilot / Flying J plus
  Love's and TA/Petro, each brand its own `CityTable`
  (`RatingsAndCost.swift`); shipped as
  `Resources/{pilot_city,loves_city,ta_petro_city,truckstop}_showers.json`.
- **Trucker radio** — GPS-nearest NOAA Weather Radio stream with
  auto-switch under 20 % hysteresis (coordinates in
  `Resources/nwr_stations.json`), plus cab-radio rows shown as an
  honest disabled state: there are no licensed CB/HAR streams to play.

### 7.7 Vehicle & towing

`Core/VehicleSpecs.swift`, `Core/TowingLimits.swift`,
`Core/EPAVehicleDatabase.swift`:

- Every curated vehicle spec carries published GVWR / tow / GCWR;
  `TowingLimits.estimatedRatings` provides a class-typical fallback
  explicitly labeled as an estimate.
- Towing compliance is re-checked on every GPS tick with a one-shot
  violation banner.

### 7.8 Performance notes

- `earliest_trip` binary search in the RAPTOR inner loop
  (`rust/flows-core/src/transit/`).
- Spatial grids everywhere a nearest-neighbor scan appeared in a
  profile: `RoutePath.nearest`, the shower city tables, SMN station
  lookup (`InternationalWeather`), and `RiskFieldService.selectZips`.
- Per-sweep overlay caches keep map redraws off the network.
- The launch path decodes the risk field from the FRB1 binary shard,
  not JSON (§3).

---

## 8. Deploy shape & stack rule

**One shape.** The product is the Swift/SwiftUI app
(iOS / macOS / iPadOS via one `apple/project.yml` xcodegen spec, plus a
watchOS companion in `apple/FLOWSWatch/` and a CarPlay scene) statically
linking `rust/flows-core` over a C FFI (`rust/flows-core/src/ffi.rs`). It
is fully self-contained at runtime: bundled national risk field (FRB1) +
keyless live feeds; **no server component**. See §7 and
[`APPLE_APP.md`](APPLE_APP.md).

**Stack rule** (see [`LANGUAGE_ARCHITECTURE.md`](LANGUAGE_ARCHITECTURE.md),
[`RUST_SWIFT_MIGRATION.md`](RUST_SWIFT_MIGRATION.md) and
[`CODING_STANDARDS.md`](CODING_STANDARDS.md)): the product is **Rust +
Swift only** — no Python and no hand-written assembly ship in or power the
product; Python remains acceptable as repo tooling/verification
(reference-asset builders, preflight checks).

**Dead code is removed, not kept "just in case."** The clearest recent
case: the hand-written **AArch64 assembly polyline kernel was retired on
2026-07-19**. A three-way bake-off in
[`rust/flows-core/src/bin/bench.rs`](../rust/flows-core/src/bin/bench.rs)
measured rustc's portable raw-pointer code *faster* than the hand kernel
(asm 3.20 ns/byte vs 2.59 ns/byte on M-series; `Vec::push` 2.83).
`polyline::decode_deltas()` now uses the portable raw-pointer body on all
targets (writing through `reserve` + a raw pointer — the asm wrapper's one
real trick, kept); `decode_deltas_rust` is the fully-safe oracle, and the
equivalence tests still pin the two byte-identical. Assembly must *earn*
its keep against the compiler or it goes. Earlier removals in the same
spirit: the `risk_band` variant experiments, the NEON / autovectorised
distance kernels (scalar reference retained in
`rust/flows-core/src/distance.rs`), and `hazardFieldShapes`.

---

## 9. Historical: the retired R / Shiny "Wisconsin" engine

> **Retired 2026-07-11 (commit `5ed9cc0`).** The `R/` directory and the
> root Shiny files (`global.R`, `server.R`, `ui.R`, `gomap.js`,
> `styles.css`) were deleted from the repo; the R export scripts and the
> `tests/*.R` harness are gone. **Nothing below is live.** This section is
> kept as design history — the engine is where the risk physics was born,
> and its scores remain the parity oracles the Rust port is tested
> against (§6). The rest of this document (§1–§8) is the current system.

**What it was.** FLOWS began as a single R process running a **Shiny**
server. A browser hit it; server-side reactives (`server.R`) built a
map payload and shipped JSON to a Leaflet map (`ui.R` + `gomap.js` +
`styles.css`). It covered **Wisconsin only**, at ZIP-code precision.

**Build pipeline.** `R/build_view.R` orchestrated a single build pass:
`prefetch_live_startup_payload` fetched alerts (`R/alerts.R`) and a fast
forecast baseline (`R/forecast.R`), forked the 511WI road prefetch with
`parallel::mcparallel`, then `build_risk_polygons` fused ~11 external
hazard families (`R/external_bundle.R` — flood via NWPS gauges / WPC /
FFG, plus winter, fire, convective, lightning, heat, UV, radiation, NRC,
seismic, air) with the forecast baseline and alert coverage, applied
noisy-OR family scoring (`R/families.R`), and finalized per-ZIP fills,
labels, and popups (`finalize_zip_view`). A native A\* router
(`R/route.R` + `R/route_pathfind.R`) planned fastest/safest/metro
profiles over a ~97k-node / ~90k-edge Wisconsin OSM graph.

**Caching & concurrency.** A three-tier cache — in-process `live_cache`
env, disk `.rds` snapshots under `data/runtime_cache/`, and reference
geometry under `data/reference/` — plus `parallel::mclapply` fan-out for
per-region NWS forecasts and NWPS gauge fetches, under a strict
fork-safety rule (load `curl` / `httr2` / `sf` before the first fork).

**Feeds.** ~22 keyless federal feeds (NWS alerts + forecast, WPC/OWP
flood, NWPS gauges, FFG, SPC convective/fire, GOES GLM lightning, NWS
HeatRisk, EPA AirNow / UV, RadNet, NRC, USGS seismic) plus the 511WI
transport pipeline (free WisDOT key, degrades gracefully when absent).

**Tests.** An R-only harness lived under `tests/`: a runtime smoke test,
an 8-suite SQA gate (`sqa_runner.R`), a 13-mutant mutation harness
(`mutation_test.R`), modeled-road equivalence, and a static-analysis
scanner for R footguns. These validated the scoring that the Rust
`flows-core` R-parity oracles now reproduce.

**Why it's gone.** The native app carries the product at national scale
with no server; the R engine's Wisconsin-only, single-process, Leaflet
shape could not. Rather than keep two systems in sync, the R engine was
retired and its physics frozen into the Rust port's test fixtures. The
earlier plan to deliver mobile by packaging the R app
([`MOBILE_PACKAGING.md`](MOBILE_PACKAGING.md)) is likewise historical.
