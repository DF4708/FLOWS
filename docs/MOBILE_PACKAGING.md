# Mobile packaging — iOS / macOS / iPadOS

Three viable paths. Each preserves different amounts of the current
Shiny R app. Each has different Apple approval requirements and different
timelines. Pick after the CONUS expansion has advanced enough to warrant
mobile investment.

---

## Reality check

The user's ask includes:

- iOS + macOS + iPadOS app.
- Turn-by-turn GPS navigation.
- Life-threatening alerts pushed even when the app is backgrounded.
- Behaviour "just like Apple's maps".

Apple gates several of those:

- **Critical Alerts entitlement** — required for alerts that override
  Focus / Do Not Disturb / silent mode. Apple grants this
  case-by-case; typical approvals are limited to first-responder /
  public-safety orgs. Application: `developer.apple.com/contact/request/critical-alerts-entitlement`.
- **Background location (`always`)** — required for turn-by-turn.
  Standard entitlement, but requires clear user disclosure and
  App Store review scrutiny.
- **Voice guidance (AVSpeechSynthesizer)** — no entitlement, but
  best practices reviewed for driver safety.

None of these are things I can grant on the user's behalf. They
require an Apple Developer Program membership ($99/yr for individuals,
$299/yr for organisations) and human review.

---

## Path 1 — WKWebView wrapper (fastest, smallest change)

A thin native shell that loads the running Shiny server URL in a
WKWebView. Deployable in days after the Apple accounts are set up.

### Architecture

```
┌────────────────────────────────────────────────────────┐
│  iOS / iPadOS / macOS app (Swift, ~500 LOC)            │
│  ├── WKWebView pointed at https://flows.example.com   │
│  ├── CLLocationManager → JavaScript bridge (GPS)      │
│  ├── UNUserNotificationCenter → push channel          │
│  └── AVSpeechSynthesizer → TTS for turn-by-turn       │
└────────────────────────┬───────────────────────────────┘
                         │  HTTPS
                         ▼
┌────────────────────────────────────────────────────────┐
│  R/Shiny server (unchanged)                            │
│  Serves the map + emits push tokens per user          │
└────────────────────────────────────────────────────────┘
```

### What ships to Apple

- **Info.plist** with `NSLocationAlwaysAndWhenInUseUsageDescription`,
  `UIBackgroundModes = [location, remote-notification]`.
- **Entitlements**: `aps-environment` (push), `com.apple.developer.usernotifications.critical-alerts`
  (when granted).
- **ATS**: `NSAppTransportSecurity` — server must be TLS 1.2+.

### What must be added server-side

- APNs push provider — when NWS Critical Alerts fire for a user's
  current ZIP, server pushes to Apple's APNs which relays to the
  device.
- Turn-by-turn instructions — server produces a `native_step_instructions`
  vector (already present in `route_pathfind.R`); the shell reads them
  from the injected JS and hands them to AVSpeechSynthesizer.
- Session auth so pushes route to the right device.

### Pros / cons

- **Pro**: minimal code duplication; the R pipeline is the truth.
- **Pro**: fastest path to shippable.
- **Pro**: cross-platform (iOS + iPadOS + macOS share ~90% of the shell).
- **Con**: requires the R/Shiny server to be internet-accessible with
  high uptime.
- **Con**: WKWebView UX is second-tier — no true native map gestures,
  no MapKit integration.
- **Con**: offline usage is impossible — the map is server-rendered.
- **Con**: Apple review sometimes rejects "just a webview" apps
  (guideline 4.2). Mitigation: the shell must add real native
  features (GPS, CoreLocation, push, TTS) so it's not a bare browser.

### Timeline

Once Apple Developer accounts + push cert are set up:

- Shell scaffolding (SwiftUI + WKWebView): 2 days.
- CLLocationManager + JS bridge: 2 days.
- APNs push (server + client): 3 days.
- AVSpeechSynthesizer + turn-by-turn wiring: 2 days.
- Critical Alerts application + review: 4–12 weeks *external wait*.
- App Store review: 1–3 weeks *external wait*.

Wall-clock: ~2 weeks of development + 2–4 months of Apple wait.

---

## Path 2 — Capacitor / Tauri hybrid (compromise)

Native shell around a pre-rendered offline map + a small live-data
bridge. Uses Capacitor (JS + WebKit) or Tauri (Rust + WebKit).

### Architecture

```
┌────────────────────────────────────────────────────────┐
│  Capacitor / Tauri app                                 │
│  ├── Pre-rendered map tiles (MBTiles / PMTiles)        │
│  ├── Local SQLite of ZIP polygons + reference data     │
│  ├── CLLocationManager (native)                        │
│  ├── Push notifications (native)                       │
│  └── Live-data client polls Shiny for hazard updates   │
└────────────────────────┬───────────────────────────────┘
                         │  HTTPS (only for live updates)
                         ▼
┌────────────────────────────────────────────────────────┐
│  R/Shiny server (as data API)                          │
└────────────────────────────────────────────────────────┘
```

### Pros / cons

- **Pro**: works offline for the base map + ZIP overlay.
- **Pro**: better UX than Path 1 (native map gestures).
- **Pro**: still cross-platform.
- **Con**: significantly more work — need to port popup rendering to JS.
- **Con**: two truth sources (JS renderer + R renderer) must stay in sync.
- **Con**: pre-rendered tile pipeline needed for CONUS scale.

### Timeline

~2 months of development + Apple wait times.

---

## Path 3 — Native Swift rewrite (best UX, longest timeline)

Full native app on MapKit. Server-side R pipeline continues to run
as a data-only backend.

### Architecture

```
┌────────────────────────────────────────────────────────┐
│  iOS / iPadOS / macOS app (Swift, ~30 000 LOC)         │
│  ├── MapKit (native map rendering)                     │
│  ├── MapKit MKDirections (native turn-by-turn)         │
│  ├── CoreLocation                                      │
│  ├── UserNotifications + Critical Alerts               │
│  ├── AVSpeechSynthesizer                               │
│  ├── Local Core Data / SwiftData for offline hazards   │
│  └── Data client → FLOWS JSON API                      │
└────────────────────────┬───────────────────────────────┘
                         │  JSON over HTTPS
                         ▼
┌────────────────────────────────────────────────────────┐
│  R backend (headless — no Shiny UI)                    │
│  Exposes /alerts /polys /roads /routes as JSON         │
└────────────────────────────────────────────────────────┘
```

### What must be added

- **R side**: strip Shiny; expose the existing build pipeline via
  `{plumber}` HTTP endpoints emitting the same JSON currently
  streamed to Leaflet.
- **Swift side**:
  - MapKit annotations for ZIP polygons (translate colour bands).
  - `MKDirections` for routing OR call the R side's routing endpoint
    and render the resulting polyline.
  - `CLLocationManager` in `.authorizedAlways` for background
    turn-by-turn.
  - `UNNotificationCategory` with Critical Alerts entitlement.
  - Local persistence so recent hazards survive offline.

### Pros / cons

- **Pro**: native performance, true MapKit UX.
- **Pro**: best possible driver safety (proven MapKit + CoreLocation
  stack).
- **Pro**: works fully offline once initial data is downloaded.
- **Pro**: passes Apple review easily (no webview objections).
- **Con**: months of development.
- **Con**: two codebases (R backend + Swift front) — every feature
  lands twice.

### Timeline

~4–6 months of engineering + Apple wait times.

---

## Life-threatening alerts — Critical Alerts specifically

Regardless of path, delivering *life-threatening* alerts specifically
means:

1. Applying for the Critical Alerts entitlement with a first-responder /
   public-safety justification. FLOWS' NWS integration is a strong case;
   Apple's rubric is not published but severe-weather / hazardous
   conditions apps have been approved before.
2. Tagging each pushed alert as `interruptionLevel = .critical` and
   attaching a sound the user cannot silence. Critical Alerts bypass
   Focus and Silent Mode.
3. Enforcing a policy that the alert MUST be actionable and
   life-threatening. A false-positive Critical Alert damages the app's
   reputation and can trigger entitlement revocation.

Practical mapping:

- **Convert to Critical**: NWS Tornado Warning, NWS Flash Flood
  Emergency, NWS Extreme Wind Warning, NWS Tsunami Warning,
  NWS Hurricane Warning, NWS Boil Water Advisory (per-CDC-guidance),
  chemical/nuclear release alerts from RadNet + NRC.
- **Convert to Time-Sensitive (not Critical)**: Winter Storm Warning,
  Flood Warning (non-flash), Heat Advisory, Air Quality Alert.
- **Convert to standard priority**: everything else — Watches, minor
  advisories, informational bulletins.

The mapping already exists in principle inside `alerts.R` /
`zone_alerts.R` (each alert has a family + severity tier). The mobile
push adapter just reads those and picks the priority.

---

## GPS turn-by-turn — driver-safety non-negotiables

MapKit's `MKDirections` handles most of this cleanly, but a native or
hybrid path has to enforce:

- **Speech synthesis with anti-fatigue**: instructions are
  announced once at the "prepare" distance and once at the "act"
  distance. Repeating them beyond that is worse than silence.
- **Speed-relative distance thresholds**: 1 mi warning above 55 mph,
  0.3 mi warning under 25 mph. MapKit's default cadence is a good
  starting point.
- **Hazard-aware re-routing**: when a red-risk hazard appears on the
  chosen route in real time (NWS Flash Flood Warning polygon
  intersects the remaining route), the app must offer a re-route
  automatically. This is the value FLOWS adds over Apple Maps.
- **Background lock**: while turn-by-turn is active,
  `CLLocationManager.pausesLocationUpdatesAutomatically = false`.
  `allowsBackgroundLocationUpdates = true`. Show the "app is using
  your location" banner honestly.

---

## Recommended path

Given the CONUS expansion is not complete and the user hasn't yet
committed the Apple Developer resources:

1. **Complete CONUS Phase 1** (Wisconsin + border states) first —
   proves the horizontal-scaling story before adding a vertical
   deployment target.
2. **Prototype Path 1 (WKWebView wrapper)** in parallel, on a staging
   Shiny server. Get a shell app running on a test device with GPS,
   push, and TTS. Zero App Store commitment yet.
3. **Apply for Critical Alerts entitlement** once Path 1 has proven
   viable. This is the longest external dependency; start it early.
4. **Decide Path 2 vs Path 3** based on user feedback from the Path 1
   prototype:
   - If users are content with the WKWebView UX and cross-platform is
     valuable, stay on Path 1.
   - If UX is the blocker and users demand native-map polish, commit
     to Path 3.
5. **Ship** — App Store submission, iterate on rejection feedback,
   monitor crash rates + Critical Alert accuracy.

## Timeline reality

Best case (Path 1 wrapper + Critical Alerts approved fast):
**~3 months** from CONUS Phase 1 completion to App Store launch.

Realistic case (Path 3 native rewrite, standard Apple review): **~9
months** from CONUS Phase 1 completion.

Anyone who tells you they can build a native, Critical-Alert-enabled,
turn-by-turn-navigating iOS + macOS + iPadOS app in less than that
either has the code half-written already or is going to cut a corner
that harms driver safety. FLOWS' entire value proposition depends on
not cutting that corner.
