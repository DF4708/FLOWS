# FLOWS Apple app — SwiftUI + MapKit + Rust core

The native FLOWS client for **macOS, iOS, and iPadOS**, living in `apple/`.
One SwiftUI codebase, two xcodegen targets (`FLOWS-iOS`, `FLOWS-macOS`), the
same design language as the web app (pill controls, #111 CTA, floating white
cards, FLOWS risk palette — see `Theme.swift` ↔ `styles.css`).

```
apple/
  project.yml                 # xcodegen source of truth (xcodeproj is generated)
  FLOWS/Sources/
    FLOWSApp.swift            # AppModel + mode machine: planning → choosing → navigating
    Theme.swift               # shared design tokens (mirrors styles.css)
    Core/
      FlowsCore.swift         # Rust FFI bridge (dlopen dev / static-link ship) + Swift fallbacks
      LocationService.swift   # GPS + speed; coarse in planning, every-fix in navigation
      RouteService.swift      # MKDirections alternates + FLOWS weather-risk scoring
      NavigationEngine.swift  # turn-by-turn state machine + dynamic zoom policy
      POIService.swift        # gas/food along the corridor ahead (MKLocalSearch)
      WeatherAlertService.swift # NWS corridor alerts, driving-cadence refresh
    UI/                       # ContentView (adaptive root), PlannerPanel,
                              # RouteChoicesView, NavigationHUD
    CarPlay/                  # CPMapTemplate scene + Apple Music controls
    Resources/Assets.xcassets # FLOWS icon (from images/FLOWS_icon_transparent_enhanced_v2.png)
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
| Continent-scale routing + traffic ETAs | `MKDirections` (alternates, `departureDate = now`) |
| Gas / food along route | `MKLocalSearch` + `MKPointOfInterestFilter`, corridor-scoped |
| Weather warnings + corridor risk | NWS `api.weather.gov` sampled along the polyline, folded into the FLOWS 0…1 risk scale (same band cuts as `R/risk_constants.R`) |
| Hot loops (polyline decode, future scoring/CH) | `rust/flows-core` — AArch64 assembly + Rust |

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

**Rust + assembly backend.** `FlowsCore.swift` mirrors `R/rust_core.R`:
dlopen `libflows_core.dylib` in dev (with the same owner/non-writable
security guard), static-link `libflows_core.a` for device builds, pure-Swift
fallback that is value-identical when neither is present. The polyline
decoder's varint/zigzag hot loop is hand-written AArch64 assembly
(`rust/flows-core/src/polyline.rs`), equivalence-tested against the portable
Rust kernel on every `cargo test`. Static-link recipe:

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
4. Corridor weather: upgrade from active-alerts-only to the full FLOWS
   family scoring (QPF/winter/convective…) via a lightweight scoring service
   or on-device Rust port.
5. CarPlay entitlement application; then real CPManeuver turn cards on the
   CPMapTemplate.
