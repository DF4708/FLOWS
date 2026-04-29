# Satellite Flooding / Wisconsin Hazard Map

This project is a Wisconsin-focused NOAA/NWS Shiny application that renders ZIP-level environmental risk, forecast windows, an optional driving-risk highway overlay, and a risk-aware route planner. The current code path combines NWS alerts, NWS forecasts, NWPS gauges, WPC QPF and winter guidance, SPC fire and convective outlooks, live GOES GLM lightning nowcasts, HeatRisk, AirNow live observations plus reporting-area forecast horizons, EPA UV, EPA RadNet near-real-time monitor signals, NRC daily event reports, USGS seismic feeds, NOAA experimental Flood Hazard Outlook guidance, and optional official 511WI roadway feeds including winter roads, travel times, events, alerts, and dynamic message signs.

The app now starts in a lean "fast paint" mode. Default map filters are limited to alerts plus forecast temperature, wind, and precipitation so the first visible statewide ZIP map can render before slower specialty feeds are requested. Heavier families such as QPF/flood, winter, fire, convective, heat, air, radiation, seismic, and transport overlays are only fetched when the selected view actually needs them.

## Run expectations

- `global.R`, `ui.R`, and `server.R` define the application.
- The app still uses live government feeds at runtime.
- `data/wi_latitude_band_profiles.csv` drives latitude-normalized temperature scoring.
- If `data/reference/wisconsin_reference.gpkg` exists, the app loads bundled Wisconsin-only counties, ZIPs, places, and roads before attempting any live Census download.
- `scripts/build_wisconsin_reference_assets.py` builds that GeoPackage and its manifest deterministically for release packaging.
- `scripts/validate_wisconsin_reference_assets.py` verifies that the bundled GeoPackage and manifest contain the required Wisconsin-only layers before a local-only release build is shipped.

- `scripts/runtime_smoke_test.R` sources `global.R`, `ui.R`, and `server.R` in a real R environment and fails fast when core app objects do not load.
- `scripts/release_preflight.py` orchestrates the bundled-reference validator and runtime smoke test so release packaging can report exactly whether the remaining literal gaps are "missing assets", "missing R runtime", or an actual app-load failure.

## Optional configuration

The app now supports optional environment variables:

- `NOAA_USER_AGENT` — overrides the default Weather.gov user agent string.
- `WI511_API_KEY` — enables 511WI winter-road, travel-time, event, and alert enrichment.
- `USE_LOCAL_REFERENCE_ONLY` — when set to `true`, the app fails fast if the bundled reference GeoPackage is missing instead of silently falling back to live Census downloads.

Optional R packages:

- `cppRouting` — when installed, the route planner runs its A* search via the C++ bidirectional Dijkstra implementation (sub-second routing). Falls back to the in-process heap-based A* when not installed.
- `ncdf4` — required for live GOES GLM lightning ingestion; the convective layer falls back to SPC-only when not installed.

If `WI511_API_KEY` is set, the highway hazard overlay adds official 511WI winter road condition segments, travel-time delay segments, and incident/closure event segments on top of the modeled ZIP-derived road overlay. Those official roadway feeds now propagate into ZIP-level transportation and driving risk through both direct intersection and nearby-corridor distance decay. The app also ingests 511WI alert notifications and message-sign text as ZIP-level transportation signals. Alert-to-location matching now goes beyond raw ZIP/county/place hits by also using roadway-name extraction and a coarse Wisconsin region alias map before falling back to high-importance statewide conditions. Future horizons treat 511WI roadway feeds, alerts, and message signs as live-only inputs and decay them over time rather than pretending they are true forecasts.

The flood family now also samples NOAA gridded Flash Flood Guidance at Wisconsin ZIP centroids and uses it as a live flash-flood-sensitivity term. That sensitivity is strongest in the live view and decays into later horizons instead of being treated as a literal forecast product. NWPS river guidance is now scored from explicit observed, forecast, and National Water Model-style stageflow paths when available instead of collapsing everything into one generic numeric signal, and nearby river-corridor spillover now influences ZIP flood risk instead of relying only on the single nearest gauge. Flood popups now expose both key contributors and a numeric flood breakdown rather than a single opaque reason string, and flood/convective reason text is source-aware so route and ZIP explanations can distinguish rain/QPF-driven flooding from point-gauge flooding, off-gauge hydrologic guidance, nearby river-corridor/NWM-style guidance, and SPC guidance from live lightning-driven convective escalation.

Radiation risk now has two live-only sources in addition to EPA UV: EPA RadNet Wisconsin monitor anomalies and NRC daily event reports that mention Wisconsin locations or facilities. Those live-only ionizing signals decay across 24h/48h/72h views instead of being copied forward as literal forecasts.

Air quality now uses two different AirNow paths: live views use recent hourly observation files, while 24h/48h/72h views use the reporting-area forecast file plus the ZIP-to-reporting-area lookup file when those forecast records exist. If no valid forecast record is available for a later horizon, the app falls back to a decayed live-air proxy instead of returning a blank signal.


## Route planner

The UI includes a Wisconsin-only route planner. It accepts start and destination inputs as ZIP, county, or city and returns three profile-specific routes:

- **Fastest** — strict time minimum (uniform tier weighting, no risk penalty).
- **Safest** — avoids any non-zero forecast risk where time-feasible (alpha = 25), with a piecewise time cap (3x at one hour, decaying to 1.1x at twenty-four hours) that prevents pathological detours on long trips.
- **Metro / Rail** — stays on highway corridors through cities and accepts green-band risk freely (alpha = 10 with a green-min risk floor); fights yellow / red as aggressively as Safest.

The road graph is built from OpenStreetMap (Geofabrik Wisconsin extract, ~97k drivable ways covering motorway / trunk / primary / secondary / tertiary plus link variants) and cached at `data/reference/wi_osm_roads.rds`. Edge cost is `(length / speed) * tier_bonus * (1 + alpha * effective_risk + closure_scale * closure_penalty)`. `effective_risk` is `seg_risk * exp(-boundary_distance_m / 2500)` so a road skirting the perimeter of a low-risk neighbour ZIP is genuinely less penalized than a road in the core of the same risky polygon.

When the optional `cppRouting` package is installed, the search runs as bidirectional Dijkstra in C++ over the cached graph and resolves each query in roughly fifty milliseconds; the legacy in-process heap A* path is kept as a fallback. Route summaries and road popups also classify official transport causes such as closures, winter conditions, delays, alerts, incidents, and message-sign-driven disruptions.

Live GLM lightning nowcasts are fetched from NOAA Open Data GOES buckets when the optional `ncdf4` R package is installed. The app scans recent GLM flash files from the first available GOES bucket, assigns recent flashes to nearby Wisconsin ZIP centroids, and uses that live-only signal in the `live` convective view while keeping SPC guidance authoritative for projected horizons.


## Release preflight

- Build the bundled Wisconsin reference assets on a machine with internet access:
  - `python scripts/build_wisconsin_reference_assets.py`
  - or provide pre-downloaded archives explicitly with `--county-archive`, `--zcta-archive`, `--place-archive`, and `--roads-archive`
- Validate the built bundle:
  - `python scripts/validate_wisconsin_reference_assets.py`
- Run the release preflight:
  - `python scripts/release_preflight.py --project-dir . --require-assets --require-r`

The preflight will validate the GeoPackage when present and then run the R smoke test when `Rscript` is available.
