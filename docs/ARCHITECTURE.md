<!--
  Copyright (c) David B. Foster. All rights reserved.
  Contact: d.foster@marquette.edu
  Unauthorized copying, distribution, modification, or use of this file, in
  whole or in part, is strictly prohibited without the express written
  permission of the copyright holder.
-->

# FLOWS — Architecture

> **Forecasted Live Operational Weather System** — hazard-aware travel.
> Two deploy shapes share one risk model: (1) the original **Shiny R
> application** that fuses federal weather / hydrology / air / radiation /
> seismic / roadway feeds into a ZIP-code-precise Wisconsin hazard map —
> now the reference engine and offline data producer — and (2) the
> **native Apple app** (Swift UI + `rust/flows-core` compute) that ships
> the same physics as a national driving / walking / transit navigator.

This document is the map. If you need to change the codebase, start
here to figure out which module owns the concept and which downstream
consumers you'll break. Sections 1–8 describe the R engine (still live,
still the training-data and bundle producer); section 9 describes the
native app architecture that now carries the product.

---

## 1. Layers, top-down

### 1a. R engine (reference / producer)

```
                     ┌────────────────────────────────────┐
User's browser  ───▶ │  Shiny UI (ui.R + gomap.js +       │
                     │  styles.css + Leaflet map)         │
                     └──────────────┬─────────────────────┘
                                    │
                     ┌──────────────▼─────────────────────┐
                     │  server.R — reactive orchestration │
                     │  input events → payload builds     │
                     │  → leafletProxy draws              │
                     └──────────────┬─────────────────────┘
                                    │
                     ┌──────────────▼─────────────────────┐
                     │  Build pipeline (R/build_view.R)   │
                     │  build_risk_polygons → finalize_   │
                     │  zip_view → build_driving_roads_   │
                     │  overlay                           │
                     └──────────────┬─────────────────────┘
                                    │
    ┌─────────┬──────────┬──────────┼──────────┬──────────┬──────────┐
    │         │          │          │          │          │          │
┌───▼──┐ ┌───▼──┐ ┌──────▼──┐ ┌─────▼──┐ ┌─────▼──┐ ┌─────▼──┐ ┌─────▼──┐
│Family│ │Forec.│ │External │ │511     │ │Routing │ │Alerts  │ │Reference│
│layer │ │baseln│ │bundle   │ │pipeline│ │(route.R│ │(NWS)   │ │loaders  │
│      │ │      │ │(11 feeds│ │(9 files)│ │+ pathfd│ │        │ │(gpkg,   │
│      │ │      │ │per horiz│ │        │ │+ chkpt)│ │        │ │osm rds) │
└──────┘ └──────┘ └─────────┘ └────────┘ └────────┘ └────────┘ └─────────┘
    │         │          │          │          │          │          │
    └─────────┴──────────┴──────────┴──────────┴──────────┴──────────┘
                                    │
                     ┌──────────────▼─────────────────────┐
                     │  Cache tiers                       │
                     │  1. in-process live_cache env      │
                     │  2. disk snapshots                 │
                     │     (data/runtime_cache/*.rds)     │
                     │  3. reference data                 │
                     │     (data/reference/*.gpkg,*.rds)  │
                     └──────────────┬─────────────────────┘
                                    │
                     ┌──────────────▼─────────────────────┐
                     │  16 external feeds (all HTTP JSON  │
                     │  or shapefile)                     │
                     └────────────────────────────────────┘
```

### 1b. Native Apple app (product)

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
             │ app_risk_bundle.json (national ZIP field),  │
             │ nwr_stations.json, shower CityTables        │
             └─────────────────────────────────────────────┘
```

The R engine exports `data/runtime_cache/app_risk_bundle.json`
(`scripts/export_app_risk_bundle.R` + `scripts/generate_national_bundle.sh`)
which is copied into the app bundle; `rust/flows-train` trains the
learned route head the app loads. Nothing in the app calls R at runtime.

---

## 2. Directory map

```
FLOWS/
├── global.R                      ← constants, source loader, config
├── server.R                      ← Shiny reactives
├── ui.R                          ← Shiny UI shell
├── styles.css / gomap.js         ← client assets
├── R/                            ← 43 modules
│   ├── util.R  scoring.R  cache.R  timing.R
│   ├── build_view.R              ← top-level orchestration
│   ├── families.R                ← environmental noisy-OR family scoring
│   ├── forecast.R                ← NWS forecast baseline
│   ├── external_bundle.R         ← 11-family external risk bundle
│   ├── alerts.R  zone_alerts.R   ← NWS alert ingest + zone→zip
│   ├── driving.R                 ← driving risk composition
│   ├── route.R  route_pathfind.R ← native A* router
│   ├── popups.R                  ← per-ZIP HTML popup builder
│   ├── snapshots.R               ← disk snapshot orchestration
│   ├── nwps.R  wpc.R  ffg.R      ← flood signals (NWPS gauges, WPC)
│   ├── airnow.R  radnet_nrc.R  uv_seismic.R   ← non-flood externals
│   ├── glm.R  spc_convective.R                ← convective / lightning
│   ├── wi_loaders.R              ← reference geometry loaders
│   ├── geo.R  geom_utils.R  polyline.R        ← spatial helpers
│   ├── http.R                    ← http_json + safely + extract_named_*
│   ├── wi511_*.R (9 files)       ← WI511 transport pipeline (thematic split)
│   └── checkpoints/              ← immutable routing backups
├── apple/                        ← native Apple app (see §9)
│   ├── FLOWS/Sources/Core/       ← ~45 Swift service/model files
│   ├── FLOWS/Sources/UI/         ← ContentView, PlannerPanel, HUD, …
│   ├── FLOWS/Resources/          ← app_risk_bundle.json, nwr_stations.json,
│   │                               per-brand shower city tables
│   ├── FLOWSTests/               ← 153 Swift tests
│   ├── FLOWSWatch/               ← watchOS companion
│   └── project.yml               ← xcodegen project spec
├── rust/
│   ├── flows-core/               ← scoring, risk, distance, polyline,
│   │   └── src/transit/          ← CH router, owned RAPTOR transit engine
│   └── flows-train/              ← learned-head trainer (pure std, zero
│       └── src/bin/national-bundle.rs   crates) + national bundle builder
├── ml/route-gnn/                 ← run_worker.sh weekly training worker
│                                   (launchd template, logs, models)
├── scripts/
│   ├── warm_live_startup_snapshot.R      ← foreground warmer
│   ├── warm_external_risk_bundle.R       ← per-horizon warmer
│   ├── export_app_risk_bundle.R          ← R snapshot → app JSON bundle
│   ├── generate_national_bundle.sh       ← WI-preserving national bundle
│   ├── runtime_smoke_test.R              ← quickest sanity check
│   ├── autonomous_test_runner.sh         ← cron-driven build+test loop
│   ├── build_wisconsin_reference_assets.py
│   └── validate_wisconsin_reference_assets.py
├── tests/
│   ├── sqa_runner.R                      ← 8-suite SQA gate
│   ├── mutation_test.R                   ← 13 mutant kill tests
│   ├── test_modeled_road_risk.R          ← vectorised equivalence
│   ├── static_analysis.R                 ← lint-style scanner
│   ├── score_matrix.R                    ← scorer cross-check
│   └── conus_experiment_harness.R        ← scientific-method runner
├── docs/
│   ├── ARCHITECTURE.md                   ← this file
│   ├── APPLE_APP.md / FLOW_APP.md        ← native-app feature docs
│   ├── RUST_SWIFT_MIGRATION.md           ← stack rule + FFI surface
│   ├── TRANSIT_ROUTING.md                ← owned RAPTOR engine
│   ├── LEARNINGS.md / TESTING_STRATEGY.md
│   ├── CONUS_EXPANSION.md
│   └── MOBILE_PACKAGING.md
├── data/
│   ├── reference/                        ← tracked geometry (gpkg, rds)
│   └── runtime_cache/                    ← gitignored disk snapshots +
│                                           app_risk_bundle.json (33,300 zips)
└── images/                               ← UI banner + docs figures
```

---

## 3. Data flow — a single build pass (R engine)

The map user sees a ZIP polygon is the output of this pipeline. Each
call is memoised in `live_cache` for the horizon-scoped TTL and, when
appropriate, persisted to `data/runtime_cache/*.rds` so the next process
starts warm.

```
prefetch_live_startup_payload  (R/build_view.R)
│
├── fetch_wisconsin_alerts               (R/alerts.R)
│     └── NWS Alerts API (per-state active)
│
├── build_fast_live_baseline             (R/forecast.R)
│     └── one NWS points/hourly probe + broadcasts to all zips
│
├── ★ mcparallel fork ★  511 road prefetch
│     ├── build_511_roads_overlay        (R/wi511_transport.R)
│     │   ├── fetch_511_winter_roads_live       (winter feed)
│     │   ├── fetch_511_events_live             (crashes/hazmat)
│     │   └── snap_511_overlay_to_osm_roads     (laser-detection)
│     ├── compute_511_message_sign_road_signal
│     └── compute_511_road_proximity_signal
│
├── build_risk_polygons                  (R/build_view.R)
│     ├── build_forecast_baseline        (R/forecast.R)
│     │     └── parallel NWS forecast per forecast_region (18)
│     │         + degraded-snapshot guard
│     ├── enrich_external_risks          (R/external_bundle.R)
│     │     ├── flood: get_wpc_qpf_sf,
│     │     │           get_wpc_flood_outlook_sf,
│     │     │           get_owp_fho_sf,
│     │     │           fetch_nwps_gauge_context (455 gauges, 24-core parallel)
│     │     │           compute_nwps_corridor_signal,
│     │     │           fetch_ffg_zip_sensitivity
│     │     ├── winter, fire, convective, lightning, heat, UV, radiation,
│     │     │   NRC, seismic, air-quality guidance (one step each)
│     │     └── transport: compute_511_zip_transport_risk
│     ├── apply_alert_coverage_to_zips  (R/alerts.R)
│     ├── apply_family_risk_totals      (R/families.R)
│     ├── combine_environmental_risk_score
│     ├── apply_proximity_boost
│     └── finalize_zip_view              (R/build_view.R)
│           ├── compute_driving_risk    (R/driving.R)
│           ├── compute_primary_fill_score
│           ├── risk_label_from_score (vectorised)
│           ├── risk_rgba (vectorised)
│           ├── compose_risk_reason_vec       (family reason line)
│           ├── compose_risk_component_summary_vec
│           ├── compose_risk_type_summary_vec
│           └── build_popup_vectorized
│
└── build_driving_roads_overlay         (R/driving.R)
      ├── build_511_roads_overlay       (cache hit from prefetch)
      ├── compute_511_road_proximity_signal   (cache hit)
      ├── build_modeled_road_risk_index (R/wi_loaders.R, vectorised)
      ├── 511 boost merge
      ├── style (risk_rgb_hex vectorised)
      └── manual sf-concat (drop_geometry + rbind + c(sfc)+st_sf)
```

Cache scopes:
- **In-process (`live_cache`)**: TTL-bounded, evicted on TTL expiry
  or LRU cap. `cache_get / cache_put / cache_peek` in
  [R/cache.R](../R/cache.R).
- **Disk snapshots**: `save_runtime_snapshot / load_runtime_snapshot`
  around `data/runtime_cache/*.rds`. Used by `startup_live_environmental.rds`
  (whole map payload) and by every per-family
  `derived_external-bundle-<horizon>-<hash>.rds`.
- **Reference data**: `data/reference/wisconsin_reference.gpkg` (14 MB
  Wisconsin geometry — ZCTAs, counties, places, zones) and
  `data/reference/wi_osm_roads.rds` (7.6 MB OSM road network for
  routing). Built offline by `scripts/build_wisconsin_reference_assets.py`.

**Bundle export**: `scripts/export_app_risk_bundle.R` dumps the warmed
snapshot's per-ZIP families to `data/runtime_cache/app_risk_bundle.json`;
`scripts/generate_national_bundle.sh` +
`rust/flows-train/src/bin/national-bundle.rs` extend it to 33,300 ZIPs
nationally — the 861 R-engine Wisconsin entries are preserved
byte-for-byte, and the ~32.4k non-WI ZCTAs get seasonal-climatology
entries recomputed for the current week. The app carries this bundle;
there are **no polygon rings in it** — `ZCTAFetcher`
(`apple/FLOWS/Sources/Core/ZipBordersAndTransit.swift`) fetches ZCTA
borders on demand.

---

## 4. Routing pipeline (R engine)

Cold-cache route request:

```
plan_route_options(start_point, end_point, horizon_key, ...)
│                                              R/route.R
├── build_route_segments(zips, horizon_key)   [cached per zips+horizon]
│     ├── load_wi_roads()                     [reference gpkg]
│     ├── build_modeled_road_risk_index()     [driving risk join]
│     └── produce ~90k-edge table with
│         segment_risk, closure_penalty,
│         route_tier, from/to node IDs
│
└── native_plan_routes(start_point, end_point,
                        full_segments,
                        progress, horizon_key)      R/route_pathfind.R
      ├── For each profile in {fastest, safest, metrorail}:
      │     ├── build_route_graph(segments, profile)
      │     │     [edge weights = length / adjusted_speed
      │     │      × (1 + 4·risk + closure)]
      │     ├── find_polygon_or_point_nodes()
      │     ├── pq_new / pq_push / pq_pop / pq_empty  (binary heap)
      │     ├── A* with landmark-free heuristic
      │     └── route_edges → route summary + popup HTML
      └── ranking + dedup: the three profiles (fastest/safest/metro) yield
          distinct paths; clone_route_profile() (route_pathfind.R) substitutes
          when one collapses onto another
```

Key algorithmic properties (Wisconsin baseline):
- Graph size: ~97k nodes, ~90k edges (WI OSM extract).
- Complexity: O((V+E)·log V) per profile (three profiles). Route-plan latency
  in practice is ~5 s p50 under the worker's memory pressure — the "sub-second
  intrastate" target was refuted (see TESTING_STRATEGY.md).
- Production heuristic: the R A* uses a landmark-free (admissible euclidean)
  heuristic; an optional `cppRouting` bidirectional-Dijkstra backend is used
  when the package is installed. The Rust contraction-hierarchy router
  (`rust/flows-core/src/ch.rs`) remains built and tested (query cost ==
  Dijkstra, faster in practice) and is still not wired into the R router —
  the CONUS scaling need it targeted is instead met by the native app's
  MapKit-directions + corridor-scoring path (§9.4) and the owned transit
  engine (`rust/flows-core/src/transit/`, RAPTOR over `.ftt` timetables —
  see [`TRANSIT_ROUTING.md`](TRANSIT_ROUTING.md)).
- ETA source: `base_speed_mph` per road tier with a −5 mph penalty in
  `adjusted_route_speed_mph` when segment risk exceeds `RISK_RED_MIN`.
  **No real-time traffic input.** 511WI travel-time delays are
  deliberately excluded from both risk and ETA per the
  safety-vs-throughput audit.

---

## 5. Caching, threading, concurrency (R engine)

### Cache namespaces (`R/cache.R`)

- `"reference"` — long-lived, TTL up to 24h (public forecast zones,
  county polygons).
- `"derived"` — computed outputs, TTL by horizon:
  `ALERT_TTL_SECONDS` (90 s) for live alerts, `FORECAST_TTL_SECONDS`
  (900 s / 15 min) for forecast layers.
- `live_cache` is a plain env; `prune_cache_namespace` runs on
  every put with a per-namespace size cap.

### Disk snapshots (`R/snapshots.R`)

- `STARTUP_MAP_SNAPSHOT_PATH` — whole map payload, loaded on server
  start to give an instant paint.
- `derived_external-bundle-<horizon>-<hash>.rds` — per-horizon /
  per-feature bundle, used to sidestep a cold external fetch.
- All snapshots are gitignored (regenerable).

### Fork model

- `parallel::mclapply` for the per-region NWS forecast fan-out
  (8-worker cap) and for NWPS gauge fetches (24-worker cap).
- `parallel::mcparallel` for the 511 road prefetch fork in
  `prefetch_live_startup_payload` so the 511 pipeline runs while
  the parent works on the polygon stack.
- **Fork-safety rule**: `curl`, `httr2`, `sf` must be loaded in the
  parent *before* the first fork. Warmer scripts eager-load them at
  the top; documented in [LEARNINGS.md](LEARNINGS.md#fork-safety).

### Progress reporting

`notify_progress(progress, value, detail)` in `R/forecast.R` is the
uniform channel — the Shiny progress bar reads from it; band-render
observers gate `reset_progress()` on `!isTRUE(payload$is_snapshot)`
so "Map ready" only fires after a fresh (non-snapshot) build paints.

---

## 6. External feeds inventory

### R engine feeds

| Feed | Layer | Endpoint | Refresh |
|---|---|---|---|
| NWS alerts | alerts | `api.weather.gov/alerts/active?area=WI` | 90 s |
| NWS forecast (per region) | forecast baseline | `api.weather.gov/gridpoints/...` | 15 min |
| WPC QPF | flood | `weather.gov/source/gis/Shapefiles/...` | 15 min |
| WPC winter | winter | `ftp.wpc.ncep.noaa.gov/shapefiles/winter/...` | 30 min |
| WPC flood outlook | flood | `ftp.wpc.ncep.noaa.gov/shapefiles/fop/...` | 60 min |
| OWP flood hazard outlook | flood | `mapservices.weather.noaa.gov/experimental/rest/services/owp_fho` | 60 min |
| NWPS gauges | flood (gauge) | `api.water.noaa.gov/nwps/v1/gauges` | 15 min |
| FFG (flash-flood guidance) | flood | `mapservices.weather.noaa.gov/raster/rest/services/precip/rfc_gridded_ffg` | 60 min |
| SPC convective outlook | storm | `mapservices.weather.noaa.gov/vector/rest/services/outlooks/SPC_wx_outlks` | 60 min |
| SPC fire outlook | fire | `mapservices.weather.noaa.gov/vector/rest/services/fire_weather/SPC_firewx` | 60 min |
| GOES GLM lightning | storm | AWS S3 `noaa-goes*` | 15 min |
| NWS HeatRisk | heat | official CSV | 60 min |
| EPA AirNow | air | `files.airnowtech.org/airnow/today` | 60 min |
| EPA UV daily | radiation | `data.epa.gov/dmapservice/getEnvirofactsUVDAILY` | 24 h |
| RadNet radiation | radiation | scraped (4 stations) | 15 min |
| NRC event RSS | radiation | `nrc.gov/public-involve/rss?feed=event` | 15 min |
| USGS seismic | seismic | `earthquake.usgs.gov/fdsnws/event/1/query` | 15 min |
| WI511 winter roads | transport | `511wi.gov/api/v3/get/winterroads` | 60 s |
| WI511 events | transport | `511wi.gov/api/v2/get/event` | 60 s |
| WI511 message signs | transport | `511wi.gov/api/v2/get/messagesigns` | 60 s |
| WI511 alerts (prose) | transport | `511wi.gov/api/v2/get/alerts` | 60 s |
| Census TIGER | reference | `www2.census.gov/geo/tiger/...` | build-time (annual) |
| OSM Geofabrik | reference | `download.geofabrik.de/north-america/us/wisconsin-latest.osm.pbf` | build-time (weekly) |

**No paid API key required** for any weather / flood / air / radiation /
seismic feed. WI511 requires a free WisDOT key set via
`WI511_API_KEY` env var; the pipeline degrades gracefully to
`empty_road_overlay_sf()` when absent.

### Native-app feeds (all keyless)

| Feed | Owner | Purpose |
|---|---|---|
| NWS Active Alerts (viewport bbox) | `Core/WeatherAlertService.swift` | live alert polygons on the map + per-sweep `corridorRisk` over route grid points |
| NWS gridpoint forecast (QPF, temp, wind) | `Core/NWSForecastService.swift` | `ForecastConditions.qpfInches` etc. for corridor scoring |
| WZDx open-feed registry (data.transportation.gov) | `Core/LiveHazardFeeds.swift` (`ensureWZDxRegistry`, `roadClosures`) | DOT-reported road closures → `closure` primary, per-state cache, registry refreshed daily |
| USGS / tsunami / volcanic / fire live hazards | `Core/LiveHazardFeeds.swift` | remaining primary families |
| International weather (WMO-coded) | `Core/InternationalWeather.swift`, `Core/WMOAlerts.swift` | coverage beyond NWS (Canada/Mexico corridors) |
| Census ZCTA borders | `Core/ZipBordersAndTransit.swift` (`ZCTAFetcher`) | on-demand ZIP polygons (bundle ships no rings) |
| NOAA Weather Radio station list | `Resources/nwr_stations.json` (static) | trucker radio GPS-nearest streams |

All app network access funnels through `Core/ThrottledNet.swift`.

---

## 7. Test harness

R tiers (all runnable without external network):

1. **Runtime smoke** (`scripts/runtime_smoke_test.R`) — verifies
   `global.R + ui.R + server.R` all source clean. Fastest check.
2. **SQA suite** (`tests/sqa_runner.R`) — 8 property tests: function
   presence / dead-code absence / operational-vs-safety sign scoring /
   sanitiser correctness / boundary threshold /
   parse_iso_time / etc.
3. **Mutation harness** (`tests/mutation_test.R`) — 13 semantic
   mutations injected into safety-critical functions; oracle suite must
   detect each. 100 % kill rate is the acceptance gate.

Additional pieces:
- **Modeled-road equivalence** (`tests/test_modeled_road_risk.R`) —
  vectorised `build_modeled_road_risk_index` vs a copy of the pre-fix
  scalar implementation must match column-for-column on ~1500 rows.
- **Static analysis** (`tests/static_analysis.R`) — custom scanner for
  14 R footguns (`==NA`, untyped `NA`, `1:n` zero-bug, etc.).

Native tiers:

- **Swift**: 153 tests in `apple/FLOWSTests/` (risk equations,
  climate profiles, badge clustering, towing limits, transit
  itineraries, seasonal model, crash logic, …), run by
  `scripts/autonomous_test_runner.sh` on the cron loop.
- **Rust**: 48 `#[test]`s — 37 in `flows-core` (scoring/risk R-parity,
  distance, polyline, CH, transit RAPTOR) and 11 in `flows-train`
  (trainer + `national-bundle.rs` builder).

The CONUS experiments layer on top of this
(`tests/conus_experiment_harness.R`, scientific-method runner —
described in [`TESTING_STRATEGY.md`](TESTING_STRATEGY.md)).

---

## 8. Deploy shape (present)

Two shapes:

1. **R engine** — a single R process running a Shiny server; browser
   hits it, server-side reactives build the map payload, ship JSON to
   Leaflet. This is now the reference implementation, the source of
   R-parity oracles for the Rust port, and the producer of the app's
   risk bundle. *(The earlier framing of this as the sole product,
   with mobile delivered by packaging the R app per
   [`MOBILE_PACKAGING.md`](MOBILE_PACKAGING.md), is superseded.)*
2. **Native Apple app** — the product. Swift/SwiftUI app
   (iOS / macOS / iPadOS via one `apple/project.yml` xcodegen spec,
   plus a watchOS companion in `apple/FLOWSWatch/`) statically linking
   `rust/flows-core` over a C FFI (`rust/flows-core/src/ffi.rs`). It
   is fully self-contained at runtime: bundled national risk field +
   keyless live feeds; no server component. See §9 and
   [`APPLE_APP.md`](APPLE_APP.md).

**Stack rule** (see [`RUST_SWIFT_MIGRATION.md`](RUST_SWIFT_MIGRATION.md)
and [`CODING_STANDARDS.md`](CODING_STANDARDS.md)): the product is
**Rust + AArch64 assembly + Swift only** — no Python ships in or powers
the product; Python remains acceptable as repo tooling/verification
(reference-asset builders, preflight checks). Dead code is removed, not
kept "just in case": the `risk_band` variant experiments, the NEON /
autovectorised distance kernels (scalar reference retained in
`rust/flows-core/src/distance.rs`), and `hazardFieldShapes` were all
deleted after losing their benchmarks or callers.

---

## 9. Native app architecture

Everything below lives under `apple/FLOWS/Sources/` unless noted.
This section is the Swift/Rust counterpart of §3–§6.

### 9.1 Risk model — two-tier realized risk

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
  `Core/LatitudeBands.swift` is retained only as an R-parity scoring
  input; the 1-D latitude bands are superseded for temperature
  normalization.

### 9.2 Ingestion & the national ZIP field

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
  `app_risk_bundle.json` (33,300 ZIPs: 861 byte-preserved R-engine WI
  entries + seasonal-climatology entries for the rest, built per §3)
  and selects visible ZIPs through a spatial grid (`selectZips`).
  Borders come from `ZCTAFetcher` on demand.

### 9.3 Map presentation

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

### 9.4 Routing & trip planning

`Core/RouteService.swift`, `UI/RouteChoicesView.swift`,
`Core/NavigationEngine.swift`:

- **Two-truths ranking** — `RiskEquations.rankingRisk` (route ordering
  only, never the display band) noisy-ORs the realized band with
  0.6-discounted identified ZIP exposure; as the on-device seasonal
  prior accrues confidence it takes over from the static field.
- **GO gating** — the GO affordance is gated per-route on
  `weatherScored`: a route can't be started before its corridor score
  has landed.
- **Walking** — a single pedestrian MapKit request with a driving
  fallback; the substitution is disclosed via the `plannerNotice`
  banner (`RouteChoicesView`).
- **Cost banners** — Cheapest / Most-efficient badges from
  `Core/TripCosts.swift` (fuel cost via `Core/FuelPrices.swift` +
  per-fuel gCO₂ and per-passenger-mile transit constants).
- **Tourist route filter** — pins attractions along candidates and
  shows per-card attraction counts.
- **Transit** — rail + bus multi-select cards, each with its own
  itinerary (`Core/TransitItinerary.swift`) and **exact ticket links**
  (`TransitTickets`: Amtrak/Greyhound booking pages, the station's own
  URL for local agencies — no Apple Maps handoff). When no local rail
  exists, the planner recommends the nearest Amtrak station. The
  MapKit transit stopgap is being replaced by the owned Rust RAPTOR
  engine over `.ftt` timetables (`rust/flows-core/src/transit/`,
  binary-searched `earliest_trip`) — see
  [`TRANSIT_ROUTING.md`](TRANSIT_ROUTING.md).

### 9.5 Learned route prediction

`Core/SeasonalRiskModel.swift` + `rust/flows-train`:

- **Seasonal prior** — week-of-year buckets with a 52-week half-life
  decay, frequency gating (local routes need ≥6 observations,
  cross-country ≥2), a hub/edge trip graph, and `learnedHome` /
  `homeAnchor` inference.
- **Learned head** — `LearnedHead`, a small MLP over the
  `RouteFeatures` 6-vector, trained off-device by `rust/flows-train`
  (pure std, zero crates) via `ml/route-gnn/run_worker.sh` (weekly
  launchd template `com.flows.routegnn.plist.template`); the app loads
  the JSON weights when present, nil until the worker produces one.
- **Phase 2b (future, documented not built)** — a GNN over the trip
  graph, Rust-trained, executed in Swift via MLTensor/BNNS on the ANE
  (see [`RUST_SWIFT_MIGRATION.md`](RUST_SWIFT_MIGRATION.md)).

### 9.6 POI layer

`Core/POIService.swift`, `Core/POIRanking.swift`,
`Core/RatingsAndCost.swift`, `Core/TruckerRadio.swift`:

- **Stores** kind: 8 categories, ranked Yelp-rating-desc then
  market-share, brand-augmented search queries, no MapKit category
  filter. **Tourist** kind for attractions.
- **Showers** — verified per-city tables for Pilot / Flying J plus
  Love's (576) and TA/Petro (324), each brand its own `CityTable`
  (`RatingsAndCost.swift`); shipped as
  `Resources/{pilot_city,loves_city,ta_petro_city,truckstop}_showers.json`.
- **Trucker radio** — GPS-nearest NOAA Weather Radio stream with
  auto-switch under 20 % hysteresis (coordinates in
  `Resources/nwr_stations.json`), plus cab-radio rows shown as an
  honest disabled state: there are no licensed CB/HAR streams to play.

### 9.7 Vehicle & towing

`Core/VehicleSpecs.swift`, `Core/TowingLimits.swift`,
`Core/EPAVehicleDatabase.swift`:

- Every curated vehicle spec carries published GVWR / tow / GCWR;
  `TowingLimits.estimatedRatings` provides a class-typical fallback
  explicitly labeled as an estimate.
- Towing compliance is re-checked on every GPS tick with a one-shot
  violation banner.

### 9.8 Performance notes

- `earliest_trip` binary search in the RAPTOR inner loop
  (`rust/flows-core/src/transit/`).
- Spatial grids everywhere a nearest-neighbor scan appeared in a
  profile: `RoutePath.nearest`, the shower city tables, SMN station
  lookup (`InternationalWeather`), and `RiskFieldService.selectZips`.
- Per-sweep overlay caches keep map redraws off the network.
