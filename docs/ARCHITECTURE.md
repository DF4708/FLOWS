# FLOWS — Architecture

> **Forecasted Live Operational Weather System** — a Shiny R application
> that fuses federal weather / hydrology / air / radiation / seismic /
> roadway feeds into one ZIP-code-precise Wisconsin hazard map with
> hazard-aware routing.

This document is the map. If you need to change the codebase, start
here to figure out which module owns the concept and which downstream
consumers you'll break.

---

## 1. Layers, top-down

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

---

## 2. Directory map

```
FLOWS/
├── global.R                      ← constants, source loader, config
├── server.R                      ← Shiny reactives (938 LOC)
├── ui.R                          ← Shiny UI shell
├── styles.css / gomap.js         ← client assets
├── R/                            ← 38 modules
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
├── scripts/
│   ├── warm_live_startup_snapshot.R      ← foreground warmer
│   ├── warm_external_risk_bundle.R       ← per-horizon warmer
│   ├── runtime_smoke_test.R              ← quickest sanity check
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
│   ├── LEARNINGS.md
│   ├── TESTING_STRATEGY.md
│   ├── CONUS_EXPANSION.md
│   └── MOBILE_PACKAGING.md
├── data/
│   ├── reference/                        ← tracked geometry (gpkg, rds)
│   └── runtime_cache/                    ← gitignored disk snapshots
└── images/                               ← UI banner + docs figures
```

---

## 3. Data flow — a single build pass

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

---

## 4. Routing pipeline

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
  when the package is installed. **A Rust contraction-hierarchy router**
  (`rust/flows-core/src/ch.rs`) is built and cargo-gated (query cost ==
  Dijkstra, ~1.6–4.6× faster than plain Dijkstra) as the CONUS scaling path,
  but is **not yet wired into the R production router** — see
  [`CONUS_EXPANSION.md`](CONUS_EXPANSION.md) and
  [`RUST_SWIFT_MIGRATION.md`](RUST_SWIFT_MIGRATION.md).
- ETA source: `base_speed_mph` per road tier with a −5 mph penalty in
  `adjusted_route_speed_mph` when segment risk exceeds `RISK_RED_MIN`.
  **No real-time traffic input.** 511WI travel-time delays are
  deliberately excluded from both risk and ETA per the
  safety-vs-throughput audit.

---

## 5. Caching, threading, concurrency

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

---

## 7. Test harness

Three tiers (all runnable without external network):

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

The CONUS experiments will layer on top of this
(`tests/conus_experiment_harness.R`, scientific-method runner —
described in [`TESTING_STRATEGY.md`](TESTING_STRATEGY.md)).

---

## 8. Deploy shape (present)

Currently a **single R process** running a Shiny server. The user's
browser hits the Shiny server; server-side reactives build the map
payload, ship JSON to Leaflet on the client. This is the baseline the
mobile packaging paths ([`MOBILE_PACKAGING.md`](MOBILE_PACKAGING.md))
transform into iOS / macOS / iPadOS distribution shapes.
