<!--
  Copyright (c) 2026 David B. Foster. All rights reserved.
  Contact: wizeman555@gmail.com
  Unauthorized copying, distribution, modification, or use of this file, in
  whole or in part, is strictly prohibited without the express written
  permission of the copyright holder.
-->

# FLOWS Apple app — SwiftUI + MapKit + Rust core

The native FLOWS client for **macOS, iOS, and iPadOS**, living in `apple/`.
One SwiftUI codebase, two xcodegen targets (`FLOWS-iOS`, `FLOWS-macOS`), the
same design language as the web app (pill controls, #111 CTA, floating white
cards, FLOWS risk palette — now defined solely in `Theme.swift`, the sole
source of design tokens since `styles.css` was retired).

```
apple/
  project.yml                 # xcodegen source of truth (xcodeproj is generated)
  FLOWS/Sources/
    FLOWSApp.swift            # AppModel + mode machine: planning → choosing → navigating
    Theme.swift               # design tokens (sole source; styles.css retired)
    Core/
      FlowsCore.swift         # Rust FFI bridge (dlopen dev / static-link ship) + Swift fallbacks
      LocationService.swift   # GPS + speed; coarse in planning, every-fix in navigation
      RouteService.swift      # MKDirections alternates + FLOWS weather-risk scoring
      NavigationEngine.swift  # turn-by-turn state machine + dynamic zoom policy
      POIService.swift        # gas/food along the corridor ahead (MKLocalSearch)
      WeatherAlertService.swift # NWS corridor alerts, driving-cadence refresh
      RiskEquations.swift     # ported R equations + two-tier realized risk
      ClimateProfiles.swift   # 12 Köppen-style climates, seasonal norms
      SeasonalRiskModel.swift # learned seasonal prior + LearnedHead MLP
      LiveHazardFeeds.swift   # fire/air/UV/seismic + WZDx DOT closures
      TransitItinerary.swift  # transit cards + TransitTickets links
      …                       # ~45 Core modules total — see batch notes below
    UI/                       # ContentView (adaptive root), PlannerPanel,
                              # RouteChoicesView, NavigationHUD, AlertBanners,
                              # HazardStyle
    CarPlay/                  # CPMapTemplate scene + Apple Music controls
    Resources/                # Assets.xcassets (FLOWS icon), app_risk_bundle.frb1
                              # (binary national risk bundle, 33,300 ZCTAs), nwr_stations.json,
                              # per-brand shower CityTables (pilot/loves/ta_petro)
```

## Build & run

```sh
cd apple
xcodegen generate                       # project.yml → FLOWS.xcodeproj
xcodebuild -scheme FLOWS-macOS build    # macOS app
xcodebuild -scheme FLOWS-iOS -destination 'generic/platform=iOS' build
open DerivedData/Build/Products/Debug/FLOWS-macOS.app
```

Verified 2026-07-04: macOS target **builds and runs** (ad-hoc signed,
sandboxed, location+network entitlements only); iOS sources type-check clean
against the iOS 17 SDK. Known environmental issue: after an Xcode update,
`actool` fails with "No simulator runtime version … available" until the Mac
reboots (CoreSimulator service version mismatch) — code is unaffected.

## Architecture decisions

**Apple Maps data, FLOWS judgment.** The web app builds its own risk-scored
road graph; the app instead uses Apple's stack for what Apple does best and
keeps FLOWS's value-add on top:

| Concern | Source |
| --- | --- |
| Base map, live traffic overlay | MapKit (`showsTraffic: true`) |
| Continent-scale routing + traffic ETAs | `MKDirections`: standard + alternates AND a `highwayPreference = .avoid` request, deduped — the fastest/safest(local) profile triad from the web router; "Safest" is labelled post-hydration as lowest normalized risk |
| Gas / food along route | `MKLocalSearch` + `MKPointOfInterestFilter`, corridor-scoped |
| Weather warnings + corridor risk | NWS `api.weather.gov` sampled along the polyline; **normalized via the web app's noisy-OR shape** (`1 − Π(1 − severityᵢ·coverageᵢ)`, mirror of `R/families.R::noisy_or_combine`) so the FLOWS band cuts apply unchanged; then passed through the **two-tier realized-risk model** (`RiskEquations.realizedRisk`, see below). Alert **polygons** render hazard-hatched under the route; cards show exposure %, miles, and event names. ZIP family scores now cover **all 33,300 CONUS ZCTAs** via the national bundle (superseding the earlier "web-engine-only, WI-export" limitation) |
| Hot loops (polyline decode, future scoring/CH) | `rust/flows-core` — Rust (a raw-pointer kernel, formerly hand-asm, retired 2026-07-19 when the compiler beat it) |

**No 5-minute cold start — relevance-ordered loading.** The web app's cold
start pays a whole-state graph build before first paint. The app never loads a
road graph or a continent of tiles:

1. *First frame*: map tiles for the visible viewport only (Apple streams them;
   zoom defaults to the user's region, not North America).
2. *Planning*: `MKDirections` computes NA-wide routes server-side in ~1 s;
   FLOWS then scores **only the returned corridors** (a few dozen sampled
   points per route, fetched concurrently) — not a state, not a continent.
3. *Weather view*: alert queries are corridor- and viewport-scoped, so the
   data fetched is always proportional to what's on screen, and zoomed to
   where planning decisions actually happen.
4. *Navigating*: prefetch narrows further — POI and weather refresh only for
   the corridor ahead at a driving cadence (
   `WeatherAlertService.beginCorridorWatch`, 240 s).

**Route selection flips the map from spatial to temporal.** Planning shows the
whole corridor at continent scale; the moment a route is selected
(`AppModel.select`), `LocationService` switches to
`kCLLocationAccuracyBestForNavigation` with no distance filter, and every GPS
fix re-aims the camera. Turn-by-turn is time-sensitive and locally relevant,
so update frequency goes up while spatial scope goes down.

**Dynamic zoom = maneuver density.** `NavigationEngine.cameraAltitude`:

- maneuver < 250 m away → 350 m altitude (tight on the intersection);
- otherwise count upcoming maneuvers in a speed-scaled lookahead window
  (~90 s of travel, clamped 0.8–8 km) → maneuvers/km;
- dense urban grid (≥ 2.5 turns/km) pins to 500 m; an empty highway window
  relaxes to 2400 m and stretches up to 1.5× with speed, so a long interstate
  stretch reads zoomed-out while city blocks read zoomed-in.

**Rust backend.** `FlowsCore.swift` is the FFI bridge to the Rust staticlib:
dlopen `libflows_core.dylib` in dev (with the same owner/non-writable
security guard), static-link `libflows_core.a` for device builds, pure-Swift
fallback that is value-identical when neither is present. The polyline
decoder's varint/zigzag hot loop is a Rust raw-pointer kernel
(`rust/flows-core/src/polyline.rs`, `decode_deltas` — formerly hand-written
AArch64 assembly, retired 2026-07-19 when a bench bake-off showed rustc's
portable code faster, 3.20 vs 2.59 ns/byte), equivalence-tested against the
safe `decode_deltas_rust` oracle on every `cargo test`. Static-link recipe:

```sh
cd rust/flows-core
cargo build --release --target aarch64-apple-ios      # device
cargo build --release --target aarch64-apple-ios-sim  # simulator
# then add the .a to the FLOWS-iOS target's OTHER_LDFLAGS / library search path
```

## CarPlay + Apple Music

`CarPlaySceneDelegate` (iOS target only, `#if canImport(CarPlay)`) presents a
`CPMapTemplate` with Apple Music transport controls
(`MPMusicPlayerController.systemMusicPlayer` — whatever the driver was
playing keeps playing; FLOWS surfaces play/pause/next in the nav bar).

CarPlay navigation apps require the **`com.apple.developer.carplay-maps`**
entitlement, granted per-app by Apple: apply at
<https://developer.apple.com/contact/carplay/> with the app's bundle ID and
use-case description, then add the entitlement + provisioning profile in
`project.yml`. Until granted, the scene simply never connects — phone and
iPad builds are unaffected.

## Risk equations — what is ported vs exported vs approximated

The transfer ledger (each Swift port cites its R source; FLOWSTests locks
them to vectors COMPUTED BY the R functions, equality to 1e-12):

| Piece | Status |
| --- | --- |
| Band cuts (0.3980 / 0.6990 / 0.8751) | **Exact port**, tested |
| `piecewise_score` (R/scoring.R:244) | **Exact port**, R-vector-tested |
| `temperature_risk` (R/scoring.R:279) | **Exact port**, R-vector-tested |
| Wind 15/28/45, PoP 25/50/75, composite 0.45/0.30/0.25 (R/forecast.R:226) | **Exact port**, R-vector-tested |
| `environmental_family_weights` + noisy-OR (R/families.R:471/497) | **Exact port**, tested |
| Per-ZIP family scores (all 11 families) | **National coverage** (2026-07): 33,300 ZCTAs, all scored from 20-year NOAA Storm Events history — one unified system, no preserved R/WI entries — generated by `rust/flows-train/src/bin/national-bundle.rs` via `scripts/generate_national_bundle.sh` and shipped as the binary `Resources/app_risk_bundle.frb1` (converted by `rust/flows-train/src/bin/bundle-frb.rs`, parsed by `RiskFieldService.parseFRB1` at zero JSON cost). No polygon rings ship in the bundle — `ZCTAFetcher` (`Core/ZipBordersAndTransit.swift`) fetches ZCTA borders on demand |
| Winter (WPC snow-probability grids), convective (SPC), fire, air, radiation, seismic feeds | **Not computable on-device yet** — WI export or alert-driven; winter_base_signal ported partially (grid term = 0, documented) |
| Alert severity map (Extreme .95 / Severe .88 / Moderate .72 / Minor .45) | **App approximation** (the retired R engine weighted alerts per-family via its feeds) |

On-device coverage: `NWSForecastService` fetches NWS gridpoint hourly
forecasts along any US corridor (~11 km cache cells, 30-min TTL, ≤15
fetches/route) and runs the ported equations — so corridor risk coloring,
wind filtering, and the environmental blend work CONUS-wide, with the national
risk bundle taking precedence where scored (max of the two).
Canada/Mexico corridors would need Environment Canada / SMN feeds.

### Two-tier realized risk (2026-07, `Core/RiskEquations.swift`)

Family scores no longer feed the band cuts symmetrically. `realizedRisk`
splits the families into two tiers:

- **PRIMARY** hazards — fire, qpf_flood/flood, storm (NWS *warning-level*
  convective), closure (a DOT-reported road closure), seismic, tsunami,
  tropical, volcanic — can reach Red on their own.
- **SECONDARY** predictors — wind, heat, cold, air, radiation, precip,
  winter *forecasts*, convective *outlooks*, avalanche ratings — only
  amplify an already-realized primary and are capped (~0.80) alone, so
  overlapping predictors can never sum to a lethal band by themselves.

The dividing line is **proof, not prediction** (`RiskEquations.alertFamily`
classifies NWS event names): a warning describing in-progress danger is
realized; a watch/forecast/outlook is a predictor. Flood risk is physical:
forecast QPF inches (`ForecastConditions.qpfInches`) scaled by
`floodElevationMultiplier` — relative corridor elevation, with the
mountain-town-in-a-valley case handled explicitly (low point in high
terrain amplifies; ridge tops shed).

**Presentation gate — normal never draws.** `ClimateProfiles.swift` defines
12 Köppen-style climate types computed from lat/lon/elevation, each with
per-week seasonal norms (`seasonalNorms`, sinusoidal blend across the
year); `temperatureBeyondNormal` / `windBeyondNormal` gate the map symbols
so weather that is normal-for-here-and-this-season never renders as a
hazard. A Phoenix July 105°F draws nothing; the same reading in Seattle
does. Pinned by `ClimateProfilesTests` + `RiskRealizationTests`.

### Continental latitude bands (`LatitudeBands.swift`)

> **Partially superseded (2026-07):** temperature/wind *normalization* now
> uses `ClimateProfiles` (12 climate types beat a 1-D latitude gradient in
> the mountain West and marine coasts). LatitudeBands is retained as the
> R-parity scoring input — the ported equations still take a band profile —
> so everything below remains true of that layer.

The WI 10-band profile system generalized North-America-wide:
- WI's exact anchors (ZCTA bbox 42.312985–47.080621, pitch = span/10) and
  its exactly-linear −1°F/band temperature gradient extend at the SAME pitch
  north through Canada and south through Mexico — one Wisconsin-height north
  is bands 11–20; the 14°N…70°N span holds ~119 bands.
- A location's effective band can shift by AT MOST ±1 (the contiguous rule)
  on elevation (~85.5 m per band step at the standard lapse rate, referenced
  to WI's ~300 m mean) — the Rockies normalize one band poleward, never
  jumping bands; the clamp is the upper/lower limit the rule demands.
- Inside WI the profiles equal the R server's CSV rows exactly
  (R-anchored vectors in LatitudeBandsTests — which caught a real
  right-closed-boundary bug on first run); the long extrapolation is clamped
  to physical extremes.
- Forecast scoring (`ForecastConditions.forecastScore(latitude:elevation:)`)
  normalizes against the local band, so the same 95°F reads differently in a
  Manitoba band than a Sonora band — regional norms, as specified.

## Validated North-America coverage (2026-07-04)

`apple/tools/na_coverage_check.swift` exercises every data path against all
50 states + DC + Puerto Rico and 5 Canadian / 5 Mexican cities (rerun any
time: compile with swiftc, ~3 min):

| Data path | US (52 pts) | Canada | Mexico |
| --- | --- | --- | --- |
| Latitude-band profiles (pure math) | ✅ | ✅ | ✅ (unit-tested 14–70°N) |
| Forecast conditions → banded scoring | ✅ NWS 52/52 | ✅ **ECCC GeoMet SWOB** 5/5 (obs: temp+wind; PoP n/a) | ✅ **SMN/CONAGUA** 5/5 (municipal: temp+wind+PoP) |
| Active alerts | ✅ NWS 52/52 | ✅ **ECCC CAP alerts** (chained after NWS; polygons included) | ⚠️ bulletins only — SMN severity flows via conditions |
| USGS EPQS elevation (band shift, grades) | ✅ | ⚠️ partial — Vancouver 31 m, Winnipeg 227 m returned | ⚠️ partial — Mexico City 2251 m, Monterrey 540 m returned (accurate!) |
| FEMA flood zones | ✅ | ❌ | ❌ |
| OSM Overpass clearances | ✅ | ✅ (global OSM) | ✅ |
| MKDirections routing + traffic | ✅ | ✅ Seattle→Vancouver 142 mi, Detroit→Toronto 231 mi | ✅ San Diego→Tijuana, Monterrey→Houston 491 mi |
| Apple Maps POI (gas/food/rest/medical/shelter) | ✅ | ✅ | ✅ |

Sanity anchors from the live run: Anchorage 58°F, Phoenix 103°F, Honolulu
85°F/21 mph trades, San Juan 83°F — all plausible; Mexico City's returned
elevation (2251 m) matches reality within ~10 m.

The provider chain (NWSForecastService): **NWS → Apple WeatherKit (hook,
activates with a paid team + com.apple.developer.weatherkit entitlement —
ad-hoc signing can't carry it) → ECCC GeoMet SWOB (Canada) → SMN/CONAGUA
municipios (Mexico)**. Live chain validation 2026-07-04
(apple/tools + intl chain harness): Toronto 69°F, Vancouver 60°F, Calgary
59°F via ECCC; Mexico City 66°F/90% PoP, Guadalajara 74°F/90% PoP via SMN —
banded scores computed by the same ported R equations everywhere. SMN
method=1 is a daily municipal forecast (temp = day midpoint, documented);
ECCC SWOB is observations (no PoP). Refresh: ECCC per plan/watch-cycle
cached 30 min; SMN full dataset (~9,850 municipios, 340 KB gzip) cached 3 h.
Remaining known gap: Mexican point-queryable alerts (SMN publishes
bulletins) — severity reaches scoring through the SMN conditions instead.

## Long-haul driving features (hybrid-van scenario, 2026-07-04)

Built for — and pinned by — the canonical trip test
(`apple/FLOWSTests/HybridVanScenarioTests.swift`): a 10-foot hybrid van
towing heavy, Mexico → Canada north of New York.

- **Imminent alerts** (`Core/ImminentAlerts.swift` + `AppModel`): weather the
  driver will encounter within **10 minutes at current speed** raises a loud
  banner with the official summary (NWS/ECCC headline + description excerpt)
  and a link that opens the issuing source's alert record. Reactions are
  automatic: **red** life-safety warnings (tornado / hurricane / fire /
  radiological / shelter-in-place…) auto-open the shelter list matched to
  that hazard (tornado → tornado shelters, fire → evacuation centers,
  radiological → fallout shelters); **transient upper-yellow** risk (alert
  expires ≤ 2 h) recommends waiting it out at a rest area.
- **Sheltering delay**: "Sheltering here (+1 h)" folds unplanned stopped time
  into every displayed ETA (`TripNeeds.adjustedRemainingSeconds`), with a
  visible chip so the arrival time is honest.
- **Trip needs** (`Core/TripNeeds.swift`, Settings → Trip needs): recurring
  stops at fixed cadences — hybrid preset diesel 350 mi / charge 500 mi /
  food 100 mi (seeded-random cuisine per stop) / rest 200 mi. The HUD shows
  the next need with a mileage countdown; tapping runs its POI search.
- **Vehicle limits in the driver's units** (`Core/FilterLimits.swift`): the
  grade slider works in **degrees** (up to 15°; 14° ≈ 25 % grade), and the
  clearance rule is inclusive with a 2 ft margin — a 10 ft vehicle fails a
  bridge posted 12 ft or smaller.
- **Favorites** (`Core/Favorites.swift`): the star by the destination field
  saves an address under a role symbol (home/office/school/gym/star); a chip
  row atop the planner plans a route to one from the current GPS fix in one
  press.
- **Music + Siri** (`Core/MusicController.swift`, `FLOWSIntents.swift`):
  play/pause/skip/shuffle in the HUD (iOS system Music player; hidden on
  macOS), and App Intents for the music buttons and POI quick actions —
  "skip track in FLOWS", "find diesel in FLOWS" — for hands-free driving.
- **Weighted hazard badges** (`Core/BadgeClustering.swift`): each risk area
  shows ONE symbol at the **score-weighted centroid** of its affected ZIPs,
  and the badge grows/shrinks with map zoom. *(Superseded 2026-07: badges
  now snap to ZCTA shoelace centroids; the weighted-blob placement remains
  only as the non-overlapping fallback — see the 07-06→09 batch.)*
- **Turn banner**: top-center, glanceable — the distance countdown is the
  biggest element on screen (monospaced digits), maneuver text underneath.

## Driver batch 2 (2026-07-04, evening)

- **Time-aware route risk** (`Core/RiskTiming.swift`): an alert only counts
  where the driver will ARRIVE while it's still active — a 10 h route with a
  1 h-remaining storm at the far end scores clear there. Applied in
  `corridorRisk` (per-sample arrival offsets prorated from the route ETA)
  and in the live corridor watch (offsets from the route's own pace).
- **Trucker is a dedicated route, not a filter**: the `.trucker` RouteFilter
  is gone; `AppModel.truckerRouteID` designates the fastest highway route
  clearing the vehicle's height/grade limits, labeled "Trucker" on its card.
- **Trucker mode** (top-left toggle, persisted): trucker button set —
  diesel-by-cost, Showers (Love's/Pilot/TA), legal Truck parking, state
  rest areas, truck-friendly Motels — plus the radio card
  (`Core/TruckerRadio.swift`): internet-relay player (user-configurable
  `trucker_radio.json`, fail-soft) + CB/NOAA frequency guide for the cab
  radio.
- **Vehicle profile + range** (`Core/VehicleProfile.swift`): Add-vehicle
  onboarding on first launch, editor under ⚙ Settings; range = tank × mpg ×
  habit factor (−1.2%/mph over 55, idling is pure loss), tank odometer from
  navigation GPS deltas, fill-up reset on arriving at an added gas stop, and
  a "fuel soon" HUD chip with a 40 mi reserve.
- **Hotels button**: lodging along the corridor ranked by review/cost
  balance (`POIRanking.rankHotels` — neutral until a licensed ratings feed
  is wired via `poi.hotelInfoProvider`); trucker mode biases to
  truck-friendly motels near the highway.
- **Visible limits**: route cards show max grade in degrees AND percent and
  the lowest clearance, each marked ✓/✗ against YOUR sliders when the
  matching filter is on; the sliders card lists per-route verdicts live.
- **Weather visibility**: alert-polygon cap 12 → 40, corridor hazard shapes
  draw from risk ≥ 0.25 (below the green cut), and every risk symbol is now
  TAPPABLE → a summary card (hazard type, band, the seasonal-climatology ZIP
  hazard summary, local score).
- **POI fixes**: pressing any POI button dismisses another kind's pending
  submenu; Rest searches "rest area" + "welcome center" + "service plaza"
  (state/county areas included); gas/hotel prices render large
  (19 pt rounded) — not fine print.
- **macOS music**: Music.app via Apple Events (sandbox temporary exception +
  usage string; consent asked once) — so the same Siri App Intents work on
  macOS, iOS, iPadOS, and CarPlay.
- **iOS verified in Simulator**: built, installed, launched on iPhone 17 Pro
  (screenshots in session log); compact layout fixed (trucker toggle
  icon-only below the filter bar, onboarding card offset).

## Driver batch 3 (2026-07-05)

- **Vehicle spec table** (`Core/VehicleSpecs.swift`, ~50 vehicles): pick make
  → model and economy (EPA 55/45 blend), tank size, AND factory height fill
  themselves; the height seeds the low-bridge filter automatically. Height
  slider floor is now a real sedan height (~4.6 ft), not 10 ft.
- **NA-wide viewport weather**: the live-conditions sweep runs at any zoom
  under 44° span on a 5×5 grid with a 0.25 display floor — hazard symbols
  appear at continent scale wherever NWS grid conditions are elevated. (At
  the time of this batch the choropleth was still a WI-only R-engine export;
  it has since been superseded by the unified 33,300-ZCTA national field —
  the R engine is retired. Live weather is no longer Wisconsin-bounded on
  screen.) Verified in the iOS Simulator.
- **Real mountain grades**: two-pass elevation profile — 10 km coarse pass,
  then the 3 steepest segments re-sampled at ~1.2 km (EPQS), so Appalachian
  6-9% climbs actually register instead of averaging to ~0 over 15 km.
- **Trucker toggle moved to ⚙ Settings** (it floated over the map).
- **Trip needs, sourced + editable** (Settings → Trip needs): rest default
  every 120 min (NHTSA/AAA drowsy-driving guidance: break every ~2 h or
  100 mi), food every 3.5 h (stays ahead of the FMCSA 30-min-by-hour-8
  rule), fuel derived from YOUR vehicle (75% of habit-adjusted range, gas/
  diesel/electric labeled correctly) — all sliders, all persisted.
- **Parking button**: closest-and-cheapest first (`POIRanking.rankParking`
  — free lots / park & ride rank above unknown, garages/valet last, detour
  breaks ties; a live rate feed can replace the name-based tier).
- **Bottom bar rebuilt**: two rows — trip stats + range + music + radio +
  gear + End on top, LABELED stop buttons in a horizontal scroll strip
  below (no more icon soup squeezing text out).
- **Prices populate**: `Core/FuelPrices.swift` state-average estimates
  (EIA/AAA-style baselines with state factors, labeled "est. avg") fill the
  big price slot via each result's own state; the same `priceProvider` hook
  takes a licensed station feed later.
- **Radio streams for real**: 67 NOAA Weather Radio internet relays
  (weatherusa.net) scraped into `Resources/nwr_stations.json` — verified
  `audio/mpeg` at build time — station picker + play in the radio card;
  user list still overrides via trucker_radio.json.

## Safety + trucker batch (2026-07-05)

- **Red alerts / emergency broadcasts**: AMBER / Blue / Silver / civil
  emergencies (they ride the same NWS/ECCC CAP feeds) classify RED, and red
  cards STAY until physically pressed. `Core/AlertEntityParser.swift` pulls
  vehicle (color/type/brand) and person (adult/child + clothing color)
  descriptions out of the official text → the card renders a colored
  vehicle silhouette + brand text badge + colored adult/child silhouette
  (generic shapes — no photo library needed; brand as TEXT, since shipping
  trademarked logo art isn't on).
- **Crash detection** (`Core/CrashLogic.swift` + `CrashDetectionService`,
  iPhone): 4 g impact → spoken "do you need assistance?" with live speech
  recognition for "yes"/"I'm okay", re-asking every 20 s FOREVER until
  answered or physically dismissed (an injured driver may surface late).
  On yes: one-tap 911 (iOS's hard rule — apps can never dial silently), the
  templated report (GPS, street address, time, vehicle, medical notes)
  spoken aloud for relaying to the operator + prefilled as a text to the
  emergency contact, then a one-tap call to them. Medical ID isn't
  app-readable — medical notes live in Settings → Emergency. Complements
  (never replaces) Apple's hardware Crash Detection.
- **Notification toggles** (Settings): imminent/emergency, escalation,
  traffic, fuel, crash detection — each individually switchable.
- **Speed-aware fuel predictions**: city/highway MPG from the spec table,
  interpolated by current speed (city ≤30 mph → ramp → highway 55–65 →
  drag past 65). Refuel detected from a 4-min GPS dwell → one-tap "tank's
  full" check-in (CarPlay does NOT expose real fuel level to third-party
  apps; the hook is ready if Apple opens it).
- **Grade TABLE** (`Core/GradeProfile.swift`): per-segment grades at mile
  positions — coarse pass + ~1.2 km refinement spliced in; route cards list
  the steepest three with mile markers; while driving a chip warns
  "7.2% (4.1°) grade in 1.4 mi" from the same table.
- **Family risk layers NA-wide**: the Map Filter families (wind, flood,
  winter, convective, heat, cold, environmental) now render across North
  America from live NWS/ECCC/SMN grid conditions through the ported
  equations wherever the WI ZIP export has no polygons.
  Fire/air/radiation/seismic still need the R export (no live point proxy).
- **Truckers**: Weigh station button (trucker bar) + FMCSA §395.3
  hours-of-service chip (break warning at 7:30, break due at 8 h, 11 h
  stop). Candidate next features: chain-law alerts by pass, dock-hours on
  hotel/receiver cards, IFTA fuel-tax mileage log export, PrePass/bypass
  integration, wind-gust warnings tuned to trailer profile.

## Live-safety batch (2026-07-05, later)

- **Live feeds for the last four families** (`Core/LiveHazardFeeds.swift`,
  all keyless, all probed live): fire = NOAA HMS satellite hotspots
  (GOES, US+CA+MX); air = Open-Meteo US AQI; radiation = Open-Meteo UV
  (radiological EMERGENCIES ride the CAP alert pipeline); seismic = USGS
  M3+ 24 h feed. Score mappings pinned by tests. Every Map Filter family
  now renders across North America.
- **Radar loop**: trailing hour of RainViewer precipitation radar animated
  over the map, FIFO frames, polled every 5 min (the radar product itself
  updates every 10); web-mercator tile math in `Core/RadarLoop.swift`
  (tested), stitched viewport images positioned via MapReader.
- **Red-alert incident symbol + reach circle**: alert onset + geometry give
  the incident anchor; the circle radius = elapsed time × the max posted
  speed near the incident (OSM Overpass probe, 45 mph blended default,
  3 h cap) and GROWS in real time. `Core/PursuitReach.swift`.
- **Demo hooks**: Settings → "Preview alerts & notifications" gallery +
  "Demo red alert on the map"; FLOWS_DEMO=gallery|redalert env for
  screenshot automation.
- **Towing** (`Core/TowingLimits.swift`): card with vehicle/trailer weight
  scales checked live against GVWR / tow capacity / GCWR from the spec
  table — violations flash red with the actual consequences; towing mode
  auto-applies grade/bridge/wind filters and a SEPARATE fuel pattern
  (0.75× economy) so normal-pattern learning stays clean.
- **Analog refuel gauge** (`Core/RefuelLearning.swift`): draggable needle
  ("where was it before you filled?") trains prediction accuracy to the
  80% floor, goes quiet above it, re-arms if accuracy decays; opt-out in
  Settings; dismissing assumes a full refuel harmlessly.
- **Speed-split economy everywhere**: every spec-table entry carries
  city/highway figures (property-tested across the whole table); Generic
  type fallbacks (Sedan/SUV/Pickup/Cargo van/Box truck/Bus/Motorhome) for
  unlisted vehicles; Nissan Versa + Ford E-450 added.
- **Crash vocabulary broadened** (word-boundary matched): yeah/yep/help/
  hurt/bleeding/ambulance/mayday… vs nope/false alarm/all good/stop
  asking… — "know" ≠ "no", "yesterday" ≠ "yes".
- **Vehicle telemetry hook**: `VehicleStore.telemetry` supplies real fuel
  fraction + tire pressures when a source exists (OEM cloud APIs like
  Tesla Fleet/FordPass, Smartcar-style aggregators, BLE OBD-II readers) —
  overrides the odometer model and silences refuel prompts. CarPlay/USB do
  not expose these to third-party apps.

## Risk realization + national coverage batch (2026-07-06→09)

The risk model itself changed shape this batch — see "Two-tier realized
risk" above. Everything else that landed with it:

- **Viewport alert ingestion**: NWS Active Alerts are pulled for the map
  viewport and scored per-sweep via `corridorRisk` over the grid points
  (`FLOWSApp.swift`) — the same realized-risk path the route corridors use,
  so map symbols and route bands can never disagree.
- **DOT road closures** (`LiveHazardFeedFetcher.roadClosures`,
  `Core/LiveHazardFeeds.swift`): the WZDx open-feed registry
  (data.transportation.gov Socrata JSON, refreshed daily, keyless feeds
  only, per-state cache) feeds a **closure primary** — a state-reported
  closure on the corridor is proof, and can go Red alone.
- **Map presentation rebuilt**: risk areas are transparent with alternating
  risk-color / hazard-type **hatch stripes** — MapKit's `MapPolygon`
  ignores `ImagePaint` pattern fills, so the stripes are clipped
  `MapPolyline` hatch lines (`ContentView.hatchLines`). Hazard badges snap
  to ZCTA shoelace centroids (blobs remain only as a non-overlapping
  fallback). The traveler marker is **mode-aware** — car / figure.walk /
  tram / bus, leg-aware on transit itineraries. 3D terrain toggle
  (`.realistic` map style + pitched camera), finer risk grid at deep zoom,
  and an offline `BreadcrumbTrail` ("Find my way back", `NWPathMonitor`
  banner) for when the network drops mid-route.
- **Two-truths route ranking** (`RouteService.rankingRisk` +
  `FLOWSModel.rankingRisk`): a route is ranked by its realized corridor
  band ⊕ 0.6× the identified ZIP exposure it crosses — what is happening
  now plus what is known about where it goes; the learned seasonal prior
  (below) takes over as its confidence earns it. **GO is gated per-route on
  `weatherScored`** — navigation cannot start on an unscored corridor.
- **Walking mode**: a single pedestrian `MKDirections` request (the driving
  strategies are identical on foot); if Apple's walking router has no path,
  a driving fallback fires with a `plannerNotice` banner saying so.
- **Cheapest / Efficient banners** (`RouteChoicesView` + `Core/TripCosts.swift`):
  cross-mode cost and CO₂ comparison — fuel cost from the vehicle profile,
  published per-passenger-mile CO₂ constants (FTA/UIC) for transit.
- **Tourist is a ROUTE FILTER**: pins attractions along each corridor and
  puts per-route attraction counts on the cards.
- **Transit cards + tickets** (`Core/TransitItinerary.swift`,
  `TransitTickets`): rail and bus are **multi-select** cards, each with its
  own itinerary and an exact ticket link — Amtrak/Greyhound booking pages,
  the station's own URL for local systems. **No Maps handoff.** When no
  local rail exists, the card recommends the nearest Amtrak station.
- **Learned prediction** (`Core/SeasonalRiskModel.swift`): week-of-year
  buckets with a 52-week half-life decay, frequency gating (local ≥ 6
  trips, cross-country ≥ 2), a hub/edge trip graph, and `learnedHome` /
  `homeAnchor` — plus a `LearnedHead` MLP over a 6-feature `RouteFeatures`
  vector, trained by `rust/flows-train` (pure std, zero crates) via
  `ml/route-gnn/run_worker.sh` (weekly launchd template ships alongside).
  Phase 2b — a Rust-trained GNN run on-device via Swift MLTensor/BNNS on
  the ANE — is documented as future work, not shipped.
- **POI**: **Stores** kind (8 categories, ranked Yelp-rating-desc then
  market-share, brand-augmented queries, no `MKPointOfInterestFilter`);
  Tourist kind; showers are now **verified per-city** — Pilot/Flying J,
  Love's (576 cities), TA/Petro (324) each with their own bundled
  `CityTable` (`pilot_city_showers.json` etc., `Core/POIService.swift`).
- **Trucker radio, live-tuned**: GPS-nearest NOAA station with
  **auto-switch while driving** (20% distance hysteresis so borders don't
  flap; coordinates in `nwr_stations.json`, `TruckerRadio.nearestChannel`);
  cab-radio rows (CB / HAR) render an honest disabled state — no licensed
  internet streams exist for them, and the card says so rather than faking.
- **Vehicle + towing**: every curated spec now carries published
  GVWR / tow capacity / GCWR; `TowingLimits.estimatedRatings` provides a
  class-typical fallback that is **labeled as an estimate**; towing limits
  re-check on every GPS tick with a one-shot violation banner.
- **Stack rule**: the product is **Rust + Swift only** (the AArch64 assembly
  polyline kernel was retired 2026-07-19 after the compiler beat it) —
  no Python in the product (python remains allowed as repo tooling /
  verification). Dead code removed accordingly: unused `risk_band`
  variants, the distance NEON/autovec kernels (scalar reference retained),
  `hazardFieldShapes`.
- **Perf**: `earliest_trip` binary search in the transit core
  (`rust/flows-core/src/transit/`); spatial grids for `RoutePath.nearest`,
  the shower tables, SMN municipios, and `RiskFieldService.selectZips`;
  per-sweep overlay caches on the map.
- **Tests**: 162 Swift test functions (`apple/FLOWSTests/`) + 90 Rust
  (flows-core 55, flows-train 35), zero warnings, `cargo clippy -D warnings`
  clean in CI.

## North America routing status

- Today: `MKDirections` covers all of North America with live traffic.
- FLOWS-native CH routing (`rust/flows-core/src/ch.rs`, cost-equal to
  Dijkstra, built + gated) is the path to *weather-aware* routing offline /
  off-Apple: per-region CSR graphs contracted ahead of time, downloaded like
  map packs. That work continues under `docs/CONUS_EXPANSION.md`.

## Roadmap

1. Reboot → verify `FLOWS-iOS` end-to-end in the iOS Simulator.
2. Static-link flows-core into the iOS target (recipe above).
3. UniFFI (or cbindgen header) to replace the hand-rolled dlsym bridge.
4. Corridor weather: **done via the national risk bundle** —
   `rust/flows-train` (`national-bundle` + `bundle-frb`) scores all 33,300
   ZCTAs from 20-year NOAA Storm Events history (11 families + hazard
   summaries) and emits the binary `app_risk_bundle.frb1`, driven by
   `scripts/generate_national_bundle.sh`
   (`data/runtime_cache/app_risk_bundle.json` is a dev/regen source only;
   `apple/FLOWS/Resources/app_risk_bundle.frb1` ships);
   `RiskFieldService.swift` serves it to the Map Filter layer, the route
   coloring, and the per-route hazard descriptions, with `ZCTAFetcher`
   pulling polygon borders on demand (no rings in the bundle). Remaining:
   automate regeneration on the next data refresh (the `.frb1` now ships in
   the app bundle on both platforms).
5. CarPlay entitlement application; then real CPManeuver turn cards on the
   CPMapTemplate.
