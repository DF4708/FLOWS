// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import MapKit
import SwiftUI

/// Root view — one Apple Maps surface, mode-dependent chrome floated over it.
/// The same adaptive rules as the web app's responsive CSS, expressed in
/// size classes: compact width (iPhone) stacks panels top/bottom; regular
/// width (iPad, macOS) floats them in the corners like the desktop web UI.
extension BadgeClustering.Item where Kind == HazardKind {
    /// Stable identity for MapKit diffing: location + hazard kind.
    var stableID: String {
        "\(coordinate.latitude),\(coordinate.longitude),\(kind.name)"
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    // Cold start frames CONUS instead of a blank void; the first GPS fix
    // narrows to the user's area (see onReceive below).
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
        span: MKCoordinateSpan(latitudeDelta: 42, longitudeDelta: 60)))
    @State private var visibleRegion: MKCoordinateRegion?
    /// Navigation camera mode: follows GPS until the user pans; a re-center
    /// button restores following (Apple/Google Maps behavior).
    @State private var cameraFollows = true
    /// The forward-facing chase view waits for the vehicle to actually MOVE:
    /// at GO the map holds a flat street-scale overview, and the first real
    /// motion (speed + course) pitches it into the heading-up chase — which
    /// then STAYS engaged through red lights (momentary stops must not flip
    /// the view back).
    @State private var chaseEngaged = false
    /// Stable identity for the reach-circle tick: built inline, the publisher
    /// was recreated (and its 30 s countdown restarted) on every re-render —
    /// at ~1 Hz GPS ticks it never fired at all.
    @State private var redAlertTimer = Timer.publish(
        every: 30, tolerance: 5, on: .main, in: .common).autoconnect()
    /// Last settled camera heading (deg). A pan during navigation KEEPS the
    /// camera's heading-up rotation — the marker must rotate relative to the
    /// world's rotation, not assume a panned camera is north-up.
    @State private var cameraHeading: Double = 0
    /// Where the vehicle marker is DRAWN. Slid toward each new fix rather
    /// than snapped to it — see VehicleTrack.
    @State private var drawnFix: CLLocationCoordinate2D?
    @State private var drawnHeading: Double?
    @State private var lastFixAt: Date?
    /// Pitch the chase camera last used, for picking the marker's aspect.
    @State private var cameraPitch: Double = 0
    /// What the CHASE just asked the camera for.
    ///
    /// `onMapCameraChange` only reports a settle, which is too late and too
    /// coarse to dress the vehicle marker: at GO the camera pitches forward
    /// immediately while the settle callback still says pitch 0, so the
    /// marker showed the roof view from behind the car. The chase knows the
    /// angle it just requested, so it records it and the marker uses that;
    /// a free pan falls back to the settled values.
    @State private var chaseAngle: (heading: Double, pitch: Double)?
    /// Set while THIS view moves the camera, so onMapCameraChange can tell
    /// our animations from the user's gestures.
    @State private var programmaticCameraMove = Date.distantPast
    @State private var didAutoCenterOnFix = false
    /// NA-wide planning-mode hazards from live NWS grid points (banded R
    /// equations). Refetched when the camera settles on a new area.
    @State private var viewportHazards: [ViewportHazard] = []
    @State private var viewportHazardKey = ""
    @State private var lastViewportRefresh = Date.distantPast
    /// Trailing-edge debounce task for the viewport sweep (so a settle that
    /// arrives early isn't dropped and lost until the next camera move).
    @State private var viewportSweepTask: Task<Void, Never>?
    /// Cached clustered badges — recomputed only when `viewportHazards` changes,
    /// not on every view-body render (the clustering is O(n²)).
    @State private var clusteredBadgesCache: [BadgeClustering.Item<HazardKind>] = []

    /// A precomputed risk-area polygon (a ZCTA ring or a hull blob) with its
    /// worst-band score — built once per sweep so the map body doesn't re-run the
    /// O(U²) `RiskBlob.clusters` + per-blob membership scans on every render.
    struct RiskAreaOverlay: Identifiable {
        let id: String
        let ring: [CLLocationCoordinate2D]
        let score: Double
        /// The area's dominant hazard kind — colors the TYPE stripes.
        let kind: HazardKind
        /// Alternating diagonal stripes clipped to the ring, drawn as
        /// MapPolyline segments (MapKit ignores pattern-image fills). The fill
        /// itself stays transparent: risk-level stripes and hazard-type stripes
        /// interleave — e.g. green/blue alternating = low risk / flood.
        let riskStripes: [[CLLocationCoordinate2D]]
        let typeStripes: [[CLLocationCoordinate2D]]
    }

    /// Scan-line hatch: diagonal (lat+lon = k) segments clipped to a polygon.
    /// Even–odd pairing of the edge intersections handles concave rings.
    /// Returns TWO interleaved stripe sets (alternate hatch lines), so the risk
    /// color and the hazard color can alternate across the same area.
    private static func hatchLines(_ ring: [CLLocationCoordinate2D],
                                   spacingDeg: Double)
        -> (even: [[CLLocationCoordinate2D]], odd: [[CLLocationCoordinate2D]]) {
        guard ring.count >= 3 else { return ([], []) }
        let ks = ring.map { $0.latitude + $0.longitude }
        guard let lo = ks.min(), let hi = ks.max(), hi > lo else { return ([], []) }
        var even: [[CLLocationCoordinate2D]] = []
        var odd: [[CLLocationCoordinate2D]] = []
        var k = lo + spacingDeg
        var line = 0
        while k < hi {
            var hits: [CLLocationCoordinate2D] = []
            for i in 0..<ring.count {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                let ka = a.latitude + a.longitude, kb = b.latitude + b.longitude
                // Half-open (<= vs >), not a strict sign test: a vertex lying
                // EXACTLY on the scan line must count as one crossing, not
                // zero from both incident edges — an odd hit count shifts the
                // even-odd pairing and paints stripes outside a concave ring.
                if (ka <= k) != (kb <= k) {
                    let t = (k - ka) / (kb - ka)
                    hits.append(CLLocationCoordinate2D(
                        latitude: a.latitude + t * (b.latitude - a.latitude),
                        longitude: a.longitude + t * (b.longitude - a.longitude)))
                }
            }
            hits.sort { $0.longitude < $1.longitude }
            var j = 0
            while j + 1 < hits.count {
                if line % 2 == 0 { even.append([hits[j], hits[j + 1]]) }
                else { odd.append([hits[j], hits[j + 1]]) }
                j += 2
            }
            k += spacingDeg
            line += 1
        }
        return (even, odd)
    }
    @State private var zctaOverlays: [RiskAreaOverlay] = []
    @State private var blobOverlays: [RiskAreaOverlay] = []

    /// Recompute the ZCTA + blob risk-area overlays from the current
    /// `viewportHazards` and `zctaRings`. Called once per sweep (and once when the
    /// ZCTA rings resolve), NOT per render — this holds the O(U²) clustering and
    /// the O(K·E) worst-scans off the hot map-render path.
    private func rebuildRiskOverlays() {
        let elevated = viewportHazards.filter {
            $0.realized >= model.riskDisplayFloor
        }
        let worstAll = elevated.map { $0.realized }.max() ?? 0.25
        let fallbackKind = elevated.max(by: { $0.realized < $1.realized })?.kind
            ?? HazardStyle.kind(forFamily: "environmental")
        // Each ZIP ring takes ITS OWN worst hazard (nearest its centroid) — that
        // drives both the risk-level stripe (score) and the hazard-type stripe.
        zctaOverlays = zctaRings.keys.sorted().compactMap { code in
            guard let ring = zctaRings[code] else { return nil }
            let c = Self.centroid(of: ring)
            // The ring's WORST hazard, which is what the stripes claim to
            // show — the code used to take the merely NEAREST one, so a mild
            // reading beside the centroid could name a ZIP that had something
            // far worse inside it. Points inside the ring are the ring's own;
            // if none fell inside, fall back to the nearest.
            let inside = elevated.filter {
                HazardFeedScores.pointInPolygon($0.coordinate, ring)
            }
            let near = inside.max(by: { $0.realized < $1.realized })
                ?? elevated.map { ($0, POIRanking.meters($0.coordinate, c)) }
                    .min(by: { $0.1 < $1.1 })?.0
            let hatch = Self.hatchLines(ring, spacingDeg: 0.012)
            return RiskAreaOverlay(id: code, ring: ring,
                                   score: near?.realized ?? worstAll,
                                   kind: near?.kind ?? fallbackKind,
                                   riskStripes: hatch.even, typeStripes: hatch.odd)
        }
        // Hull blobs are the FALLBACK area, never an overlapping duplicate:
        // a point inside a resolved ZCTA ring is covered by that ring; a US
        // point merely NEAR a ring (within a sample radius) is part of the same
        // risk area — drawing a hull on top of the ZIP boundary painted the
        // "multiple overlapping risks" the map must not show. Blobs remain for
        // Canada/Mexico and for US points whose ZIP truly hasn't resolved.
        let ringCentroids = zctaRings.values.map { Self.centroid(of: $0) }
        let unresolved = elevated.filter { pt in
            if zctaRings.values.contains(where: {
                HazardFeedScores.pointInPolygon(pt.coordinate, $0)
            }) { return false }
            let inCONUS = pt.coordinate.latitude > 24 && pt.coordinate.latitude < 50
                && pt.coordinate.longitude > -125 && pt.coordinate.longitude < -66
            if inCONUS, ringCentroids.contains(where: {
                POIRanking.meters($0, pt.coordinate) < viewportHazardRadius * 2
            }) { return false }   // same risk area as an already-drawn ZIP
            // Inside the US a hull blob is a PLACEHOLDER for a ZIP boundary
            // that hasn't resolved yet. Drawing it means a big rough box
            // appears and then visibly snaps into the real outline a moment
            // later — the "large risk boxes before they settle" flicker.
            // Wait for the boundary instead; outside CONUS the blob is the
            // permanent answer, so it still draws immediately.
            if inCONUS, !model.riskField.loaded { return false }
            return true
        }
        let blobs = RiskBlob.clusters(unresolved.map(\.coordinate),
                                      adjacencyMeters: viewportHazardRadius * 3)
        blobOverlays = blobs.enumerated().map { bi, blob in
            let members = elevated.filter { pt in blob.contains(where: {
                $0.latitude == pt.coordinate.latitude
                    && $0.longitude == pt.coordinate.longitude }) }
            let worstMember = members.max(by: { $0.realized < $1.realized })
            let ring = RiskBlob.hull(blob, padMeters: viewportHazardRadius)
            let hatch = Self.hatchLines(ring, spacingDeg: 0.02)
            return RiskAreaOverlay(id: "blob-\(bi)", ring: ring,
                                   score: worstMember?.realized ?? 0.25,
                                   kind: worstMember?.kind ?? fallbackKind,
                                   riskStripes: hatch.even, typeStripes: hatch.odd)
        }
    }
    struct ViewportHazard: Identifiable {
        /// Stable id from the grid coordinate, so MapKit diffs overlays by
        /// LOCATION across refreshes instead of by array index — an index key
        /// remapped every non-deterministic sweep, smearing/ghosting circles.
        var id: String { "\(coordinate.latitude),\(coordinate.longitude)" }
        let coordinate: CLLocationCoordinate2D
        let kind: HazardKind
        let score: Double
        /// Live per-family scores at this grid point (banded R equations) —
        /// what makes the Map Filter families work ACROSS North America,
        /// not just where the WI export has ZIPs. Merges rain PROBABILITY into
        /// the Flood/Storm filters (a predictive overlay), so it is NOT what the
        /// band keys off — `bandInput` is.
        var familyScores: [String: Double] = [:]
        /// The driving-safety realized/predictor split the risk BAND keys off:
        /// realized primaries (impassable road / direct traversal danger) vs.
        /// predictors (precip probability, forecast winter, wind, heat…). Built
        /// per point in the viewport sweep from live gauges/outlooks/perimeters.
        var bandInput: [String: Double] = [:]
        /// The point's REALIZED risk under the primary/secondary model
        /// (`RiskEquations.realizedRisk`): primary hazards can reach Red;
        /// secondary predictors amplify a realized primary but are capped below
        /// Red on their own. Keys off `bandInput`, so precip PROBABILITY and a
        /// forecast of snow can no longer read as a life-threatening primary.
        var realized: Double { RiskEquations.realizedRisk(bandInput) }
    }
    private var viewportHazardRadius: CLLocationDistance {
        guard let span = visibleRegion?.span.latitudeDelta else { return 20_000 }
        return max(min(span * 111_000 / 9, 60_000), 8_000)
    }
    /// Tapped risk symbol → summary card state.
    struct HazardTapInfo: Identifiable {
        let id = UUID()
        let kind: HazardKind
        let coordinate: CLLocationCoordinate2D
        let score: Double?
        var sourceURL: URL? = nil
    }
    @State private var hazardInfo: HazardTapInfo?
    @State private var redAlertTick = 0
    /// Demo/gallery hooks (FLOWS_DEMO env: "gallery" | "redalert").
    @State private var showDemoGalleryRoot = false
    /// Real ZIP (ZCTA) rings for elevated US risk points — Census TIGERweb.
    @State private var zctaRings: [String: [CLLocationCoordinate2D]] = [:]

    /// Cached (see `clusteredBadgesCache`) so the O(n²) clustering runs once per
    /// sweep, not on every view-body evaluation (camera ticks, timers, gestures).
    private var clusteredViewportBadges: [BadgeClustering.Item<HazardKind>] {
        clusteredBadgesCache
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isCompact: Bool { sizeClass == .compact }
    private var isShort: Bool { verticalSizeClass == .compact }
    #else
    private let isCompact = false
    private let isShort = false
    #endif

    /// Golden-ratio metrics from the live window (see GoldenScale) — set by
    /// the GeometryReader below and pushed into the environment for every
    /// child, so all chrome sizes as a proportion of THIS window.
    @State private var golden = GoldenScale()

    /// The legend belongs to the MAP: it only shows while most of the
    /// window IS map — hidden when the choices panel covers a phone, when
    /// a short (sideways) window is mostly planner, and behind the
    /// first-launch vehicle card. Tucking those menus away (collapse)
    /// brings the legend back.
    private var legendHasRoom: Bool {
        guard model.mode != .navigating else { return false }
        guard !model.collapsedPanels.contains("legend") else { return false }
        // Wide layouts used to return true unconditionally, so on an
        // 11-inch iPad in portrait the key ran under the centred planner.
        guard isCompact else { return golden.legendFits }
        if model.needsVehicleOnboarding { return false }
        if model.mode == .choosing {
            return model.collapsedPanels.contains("routes")
        }
        return !isShort || model.collapsedPanels.contains("planner")
    }

    var body: some View {
        GeometryReader { geo in
            mainStack
                .environment(\.golden, GoldenScale(size: geo.size))
                .onChange(of: geo.size, initial: true) { _, size in
                    golden = GoldenScale(size: size)
                }
        }
    }

    /// How much room the bottom chrome actually needs.
    ///
    /// Driving shows the drive bar (two rows plus the stop strip); planning
    /// shows the planner. One value, derived once, instead of a different
    /// guess at each call site.
    private var bottomSlotClearance: CGFloat {
        model.mode == .navigating ? golden.bottomClear * 2.6 : golden.bottomClear
    }

    /// Every card that floats above the bottom bar, stacked in one column
    /// so two of them can never cover each other. Most urgent last, so it
    /// sits nearest the driver's eye above the bar.
    @ViewBuilder
    private var bottomCardSlot: some View {
        VStack(spacing: 8) {
            Spacer()
            if let stop = model.poi.touristDetail {
                TouristStopCard(stop: stop) { model.poi.touristDetail = nil }
                    .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
            }
            if let info = hazardInfo {
                hazardCard(info)
            }
            if model.showTowingCard {
                TowingCard()
            }
            if model.crash.state != .idle {
                CrashCheckInCard()
            }
        }
        .padding(.horizontal, golden.padCard)
        .padding(.bottom, bottomSlotClearance)
    }

    private var mainStack: some View {
        ZStack {
            mapLayer
            // Legend first: it is BACKGROUND — every input and information
            // box (planner, cards, banners) draws over it, never under it.
            if legendHasRoom {
                LegendCard(isCompact: isCompact)
            }
            chromeLayer
            // Menus tucked away by their grab bars wait here as small round
            // icons; a tap brings the menu back.
            CollapsedPanelTray()
            // (Re-center now lives in the middle of the bottom bar.)
            // A red alert matters while PLANNING too — same banner as the HUD.
            if model.mode != .navigating, let warning = model.imminentWarning {
                VStack {
                    ImminentBannerView(
                        warning: warning, isCompact: isCompact,
                        onDismiss: { model.dismissImminentWarning() },
                        onShelterDelay: nil, onFindRest: nil)
                        .padding(.top, golden.topClear)
                    Spacer()
                }
                .padding(.horizontal, golden.padCard)
            }
            // ONE bottom slot for every floating card.
            //
            // These used to be four independent ZStack siblings, each with
            // its own Spacer and its own hand-tuned bottom padding —
            // bottomClear here, bottomClear × 2.6 there. Any two showing at
            // once landed on top of each other, and none of the guesses
            // matched the real bar height, which changes with mode and
            // device. Stacking them in one slot with ONE clearance is what
            // makes that impossible rather than merely unlikely.
            bottomCardSlot
            #if os(macOS)
            // Settings floats as a panel instead of a modal sheet, so a
            // click on the map (or Done) closes it — click-off behavior.
            if model.showSettings {
                settingsPanel
            }
            #endif
        }
        .sheet(isPresented: $model.showVehicleEditor) {
            VehicleEditorSheet()
                .environmentObject(model)
        }
        // A sheet is presented into its own environment root and does
        // NOT inherit the presenter's appearance — say it again here or
        // settings opens bright white in a dark cab.
        .presentationColorScheme(model.resolvedColorScheme)
        // Light by day, dark by night, on the sun at the driver's own
        // position — see DaylightClock. Settings can pin either one.
        .preferredColorScheme(model.resolvedColorScheme)
        .onAppear {
            model.refreshDaylight()
            // A week away means fuel stops happened that the app never saw.
            model.checkStaleFuelGauge()
        }
        .onReceive(model.navigation.$guidance) { guidance in
            // Navigation camera: chase the GPS fix at the engine's altitude —
            // but never fight the user; a manual pan pauses following until
            // re-center is tapped. The forward-facing pitch waits for the
            // vehicle to START MOVING: parked at GO the map holds a flat
            // overview, and the first motion with a real course engages the
            // heading-up chase, which then survives red lights.
            guard model.mode == .navigating, cameraFollows, let g = guidance,
                  let coord = model.location.coordinate else { return }
            if !chaseEngaged, model.location.speed > 1.2,
               model.location.course >= 0 {
                chaseEngaged = true
            }
            let heading = chaseEngaged && model.location.course >= 0
                ? model.location.course : 0
            let distance = model.cameraAltitude(
                auto: chaseEngaged ? g.cameraAltitude : g.cameraAltitude * 1.4)
            // Keep the vehicle in the middle of the map the driver can SEE,
            // not the middle of the map behind the chrome. The offset moves
            // the aim point only — the zoom is untouched, so a banner opening
            // or closing never changes it.
            let pitch: Double = chaseEngaged ? (model.show3DMap ? 66 : 55) : 0
            chaseAngle = (heading, pitch)
            moveCamera(.camera(MapCamera(
                centerCoordinate: CameraZoom.chaseCenter(
                    vehicle: coord, headingDegrees: heading,
                    distanceMeters: distance,
                    topCover: chromeTopFraction, bottomCover: chromeBottomFraction),
                distance: distance,
                heading: heading,
                pitch: pitch)))
        }
        // FLIGHT camera: with the plane option chosen, the map follows the
        // traveler by phase — airport-close like walking (before takeoff and
        // on approach), continent-wide at cruise (CameraZoom.flightAltitude).
        // It engages only while actually MOVING, so browsing the choices
        // never fights the camera; a pan pauses it, and picking the plane
        // card again resumes.
        .onReceive(model.location.$latest.compactMap { $0 }) { fix in
            guard model.mode != .navigating, cameraFollows else { return }
            // Flying: the phase camera owns the view.
            if fix.speed > 0.7, let camera = flightCamera(for: fix) {
                moveCamera(.camera(camera))
                return
            }
            // Otherwise: once the device is actually MOVING, turn the map to
            // face the direction of travel, the same as during a guided
            // drive. Parked, it stays north-up — a heading from a standing
            // GPS fix is noise, and a map that spins at the curb is worse
            // than one that doesn't move.
            guard fix.speed > 2.2, fix.course >= 0,
                  let region = visibleRegion else { return }
            let distance = max(region.span.latitudeDelta * 111_000 * 1.4, 1_200)
            moveCamera(.camera(MapCamera(centerCoordinate: fix.coordinate,
                                         distance: distance,
                                         heading: fix.course,
                                         pitch: 0)))
        }
        .onChange(of: model.transitItinerary?.mode) { _, mode in
            if mode == "Plane" { cameraFollows = true }
        }
        .onReceive(model.location.$latest.compactMap { $0 }) { fix in
            // First fix in planning mode: settle from CONUS onto the user.
            guard !didAutoCenterOnFix, model.mode == .planning else { return }
            didAutoCenterOnFix = true
            moveCamera(.region(MKCoordinateRegion(
                center: fix.coordinate,
                latitudinalMeters: 120_000, longitudinalMeters: 120_000)))
        }
        .onChange(of: model.poi.selected?.id) { _, _ in
            // POI quick action: zoom OUT to show both the vehicle and the
            // selected hit so the driver sees where it is relative to them.
            guard let selected = model.poi.selected else { return }
            var rect = MKMapRect(
                origin: MKMapPoint(selected.item.placemark.coordinate),
                size: MKMapSize(width: 1, height: 1))
            if let me = model.location.coordinate {
                rect = rect.union(MKMapRect(
                    origin: MKMapPoint(me), size: MKMapSize(width: 1, height: 1)))
            }
            // While DRIVING with follow on, nothing but the driver or the
            // guidance chase moves the camera. A stop appearing in a list —
            // which is what opening or closing an alert does — must not
            // yank the map out from under the vehicle or change its zoom.
            guard !(model.mode == .navigating && cameraFollows) else { return }
            cameraFollows = false   // let the driver inspect; re-center restores
            moveCamera(.rect(rect.insetBy(dx: -rect.width * 0.4 - 3000,
                                          dy: -rect.height * 0.4 - 3000)))
        }
        #if os(iOS)
        // iOS keeps the system sheet (it owns swipe-down dismissal); the
        // macOS panel presentation lives in the ZStack above.
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet()
                .environmentObject(model)
        }
        // A sheet is presented into its own environment root and does
        // NOT inherit the presenter's appearance — say it again here or
        // settings opens bright white in a dark cab.
        .presentationColorScheme(model.resolvedColorScheme)
        #endif
        .onChange(of: model.mode) { previous, mode in
            switch mode {
            case .navigating:
                // Selection flips the map from corridor-scale to street-scale
                // IMMEDIATELY (Apple/Google Maps behavior): zoom to the GPS
                // fix — or the route start when there is no fix yet. The view
                // stays a flat overview until the vehicle starts moving; the
                // guidance chase pitches it forward-facing then.
                cameraFollows = true
                chaseEngaged = false
                let target = model.location.coordinate
                    ?? model.navigation.route.flatMap { firstCoordinate(of: $0) }
                guard let target else { return }
                moveCamera(.camera(MapCamera(
                    centerCoordinate: target,
                    distance: 1_260,
                    heading: 0,
                    pitch: 0)))
            case .planning where previous == .navigating:
                // Ending a trip: zoom back out to the corridor (or the user)
                // instead of stranding the camera at street level.
                if let rect = model.lastRouteRect.flatMap(CameraZoom.usableRect) {
                    moveCamera(.rect(rect.insetBy(dx: -rect.width * 0.2,
                                                  dy: -rect.height * 0.2)))
                } else if let me = model.location.coordinate {
                    moveCamera(.region(MKCoordinateRegion(
                        center: me, latitudinalMeters: 120_000, longitudinalMeters: 120_000)))
                }
            default:
                break
            }
        }
        .onChange(of: model.routeFilters) { _, _ in
            model.ensureHighlightValid()
        }
        .onChange(of: model.recenterRequested) { _, requested in
            guard requested else { return }
            model.recenterRequested = false
            cameraFollows = true
            if let coord = model.location.coordinate {
                // Same rule as the chase: pitched heading-up only once the
                // vehicle has moved; re-centering while parked stays flat.
                moveCamera(.camera(MapCamera(
                    centerCoordinate: coord,
                    distance: model.cameraAltitude(
                        auto: model.navigation.guidance?.cameraAltitude ?? 900),
                    heading: chaseEngaged && model.location.course >= 0
                        ? model.location.course : 0,
                    pitch: chaseEngaged ? (model.show3DMap ? 66 : 55) : 0)))
            }
        }
        .sheet(isPresented: $showDemoGalleryRoot) {
            DemoAlertsView()
                .environmentObject(model)
        }
        // A sheet is presented into its own environment root and does
        // NOT inherit the presenter's appearance — say it again here or
        // settings opens bright white in a dark cab.
        .presentationColorScheme(model.resolvedColorScheme)
        .onAppear {
            switch ProcessInfo.processInfo.environment["FLOWS_DEMO"] {
            case "gallery":
                showDemoGalleryRoot = true
            case "redalert":
                let madison = CLLocationCoordinate2D(latitude: 43.0731, longitude: -89.4012)
                moveCamera(.region(MKCoordinateRegion(
                    center: madison, latitudinalMeters: 120_000, longitudinalMeters: 120_000)))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    model.demoRedAlert(near: madison)
                }
            default:
                break
            }
        }
    }

    /// Live NWS conditions on a 4×4 grid over the visible region, scored by
    /// the banded equations — hazard shapes anywhere in North America the
    /// NWS covers. Skipped while navigating (corridor buffer rule), at
    /// continent zoom (too coarse to mean anything), and when the camera
    /// hasn't really moved (debounce key).
    private func refreshViewportHazards(_ region: MKCoordinateRegion) {
        guard model.mode != .navigating, model.showWeatherLayer,
              region.span.latitudeDelta < 44 else { return }
        let key = "\(Int(region.center.latitude * 8))|\(Int(region.center.longitude * 8))|\(Int(region.span.latitudeDelta * 4))"
        guard key != viewportHazardKey else { return }
        // Commit the key now so the same viewport won't re-trigger, then run the
        // sweep on the TRAILING edge of the debounce window. The old code DROPPED
        // a settle that arrived early — and since onMapCameraChange(.onEnd) won't
        // fire again until the map moves, a panned-to region could show stale/no
        // hazards indefinitely. Now the last settle always gets its sweep. The
        // interval widens on weak/hot/low-power devices.
        viewportHazardKey = key
        let debounceWait = max(0, AdaptiveTuning.shared.debounceSeconds
                                  - Date().timeIntervalSince(lastViewportRefresh))
        viewportSweepTask?.cancel()
        viewportSweepTask = Task { @MainActor in
            if debounceWait > 0 { try? await Task.sleep(for: .seconds(debounceWait)) }
            guard !Task.isCancelled, viewportHazardKey == key else { return }
            lastViewportRefresh = Date()
            // Live NA-wide feeds for the families weather points can't cover:
            // satellite fire hotspots + recent quakes (viewport-wide), AQI +
            // UV per grid cell (fetched inside the loop below).
            let minLat = region.center.latitude - region.span.latitudeDelta / 2
            let maxLat = region.center.latitude + region.span.latitudeDelta / 2
            let minLon = region.center.longitude - region.span.longitudeDelta / 2
            let maxLon = region.center.longitude + region.span.longitudeDelta / 2
            async let hotspotsTask = LiveHazardFeedFetcher.shared.hotspots()
            async let quakesTask = LiveHazardFeedFetcher.shared.recentQuakes()
            // New primary feeds (all keyless, probed live): interagency active
            // fire perimeters, NWS river-gauge flood categories, NOAA space
            // weather. Each blends into an existing family below.
            async let perimTask = LiveHazardFeedFetcher.shared.firePerimeters(
                minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
            async let floodTask = LiveHazardFeedFetcher.shared.floodGauges(
                minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
            async let spaceTask = LiveHazardFeedFetcher.shared.spaceWeather()
            // New acute families (national feeds, probed live): volcanoes,
            // avalanche zones, tropical storms, tsunami alerts.
            async let volcanoTask = LiveHazardFeedFetcher.shared.elevatedVolcanoes()
            async let avalancheTask = LiveHazardFeedFetcher.shared.avalanche()
            async let stormTask = LiveHazardFeedFetcher.shared.tropicalStorms()
            async let tsunamiTask = LiveHazardFeedFetcher.shared.tsunamiEvents()
            async let spcTask = LiveHazardFeedFetcher.shared.convectiveOutlook()
            // DOT road closures (WZDx open feeds) — realized blocked-road proof.
            async let closureTask = LiveHazardFeedFetcher.shared.roadClosures(
                minLat: region.center.latitude - region.span.latitudeDelta / 2,
                minLon: region.center.longitude - region.span.longitudeDelta / 2,
                maxLat: region.center.latitude + region.span.latitudeDelta / 2,
                maxLon: region.center.longitude + region.span.longitudeDelta / 2)
            let hotspots = await hotspotsTask
            let quakes = await quakesTask
            let perimeters = await perimTask
            let floodGauges = await floodTask
            let space = await spaceTask
            let volcanoes = await volcanoTask
            let avalancheZones = await avalancheTask
            let storms = await stormTask
            let tsunamis = await tsunamiTask
            let spcZones = await spcTask
            let closures = await closureTask
            var found: [ViewportHazard] = []
            // N×N grid (5×5 on capable devices, 4×4 / 3×3 on weaker, hot, or
            // Low-Power ones) — fewer sample points is fewer requests AND less
            // CPU per sweep. Floor is BELOW the green cut so the driver SEES
            // weather across North America, not only what already scores.
            // Deep zoom (span < 1° ≈ city scale) earns one extra grid step —
            // local conditions resolve finer exactly where the driver is
            // looking, without raising the wide-view request budget.
            let base = AdaptiveTuning.shared.viewportGridSpan
            let n = region.span.latitudeDelta < 1.0 ? min(base + 1, 6) : base
            let half = Double(n - 1) / 2
            // Divide by (n-1), not n, so the N×N grid spans edge-to-edge (±0.5
            // of the visible span). Dividing by n left a ~10% unsampled margin
            // on every side, so a hazard in the outer tenth produced no badge.
            let denom = Double(max(n - 1, 1))
            var gridPts: [CLLocationCoordinate2D] = []
            for gy in 0..<n {
                for gx in 0..<n {
                    gridPts.append(CLLocationCoordinate2D(
                        latitude: region.center.latitude
                            + region.span.latitudeDelta * (Double(gy) - half) / denom,
                        longitude: region.center.longitude
                            + region.span.longitudeDelta * (Double(gx) - half) / denom))
                }
            }
            // REALIZED NWS alerts across the viewport (one sweep, zero arrival
            // offsets = active right now): a grid point inside a Tornado /
            // Flash-Flood / Tsunami WARNING carries that realized primary into
            // its band input — the map can band Red on proof, not just routes.
            let alertSweep = await model.alerts.corridorRisk(
                at: gridPts,
                arrivalOffsets: RiskTiming.arrivalOffsets(
                    sampleCount: gridPts.count, totalTravelSeconds: 0))
            await withTaskGroup(of: ViewportHazard?.self) { group in
                for (idx, gridPt) in gridPts.enumerated() {
                    let alertEvent = idx < alertSweep.samples.count
                        ? alertSweep.samples[idx].worstEvent : nil
                    let alertSeverity = idx < alertSweep.samples.count
                        ? alertSweep.samples[idx].risk : 0
                    do {
                        let lat = gridPt.latitude
                        let lon = gridPt.longitude
                        group.addTask {
                            let pt = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                            guard let c = await NWSForecastFetcher.shared.conditions(at: pt)
                            else { return nil }
                            let score = c.forecastScore(latitude: lat, longitude: lon, elevationMeters: nil)
                            var families = Self.familyScores(c, latitude: lat, longitude: lon)
                            // Live safety feeds: fire / air / UV / seismic.
                            // Fire = worse of satellite hotspots and being
                            // inside/near a mapped active perimeter.
                            families["fire"] = max(
                                HazardFeedScores.fireScore(hotspots: hotspots, at: pt),
                                HazardFeedScores.firePerimeterScore(
                                    perimeters: perimeters, at: pt))
                            families["seismic"] = HazardFeedScores.seismicScore(
                                quakes: quakes, at: pt)
                            // Flood: the DISPLAY family (map filter) is the worse
                            // of precip probability and a live river gauge; the
                            // BAND uses only `floodRealized` (gauge over the
                            // road), keeping rain PROBABILITY out of the realized
                            // primary.
                            let floodRealized = HazardFeedScores.floodGaugeScore(
                                gauges: floodGauges, at: pt)
                            families["qpf_flood"] = max(families["qpf_flood"] ?? 0, floodRealized)
                            let (aqi, uv) = await LiveHazardFeedFetcher.shared.airAndUV(at: pt)
                            if let aqi { families["air"] = HazardFeedScores.airScore(usAQI: aqi) }
                            // Radiation = worse of UV and NOAA space weather
                            // (solar radiation storm / geomagnetic by latitude).
                            let spaceRad = HazardFeedScores.radiationSpaceWeatherScore(
                                sScale: space.s, gScale: space.g, latitude: lat)
                            let uvRad = uv.map { HazardFeedScores.uvScore(index: $0) } ?? 0
                            let radiation = max(spaceRad, uvRad)
                            if radiation > 0 { families["radiation"] = radiation }
                            // Acute live-feed families (only register when real).
                            let volcanic = HazardFeedScores.volcanicScore(
                                volcanoes: volcanoes, at: pt)
                            if volcanic > 0 { families["volcanic"] = volcanic }
                            let avalanche = HazardFeedScores.avalancheScore(
                                zones: avalancheZones, at: pt)
                            if avalanche > 0 { families["avalanche"] = avalanche }
                            let tropical = HazardFeedScores.tropicalScore(
                                storms: storms, at: pt)
                            if tropical > 0 { families["tropical"] = tropical }
                            let tsunami = HazardFeedScores.tsunamiScore(
                                events: tsunamis, at: pt)
                            if tsunami > 0 { families["tsunami"] = tsunami }
                            // Convective = worse of the forecast signal and the
                            // official SPC severe-weather outlook at this point.
                            let spc = HazardFeedScores.outlookScore(zones: spcZones, at: pt)
                            if spc > 0 {
                                families["convective"] = max(families["convective"] ?? 0, spc)
                            }
                            // Keep the point if ANY family registers — the
                            // family overlay needs it even when the blended
                            // environmental score is quiet.
                            guard score >= 0.25 || families.values.contains(where: { $0 >= 0.25 })
                            else { return nil }
                            // Label the tappable symbol: a specific ACUTE hazard
                            // (fire, tsunami, volcanic…) takes the icon at yellow+
                            // over the blended forecast, since it's the distinct
                            // danger a driver most needs named. Otherwise use the
                            // forecast-dominant kind.
                            // The WORST hazard here names the area, comparing
                            // every family on the same footing — see
                            // HazardStyle.dominantFamily. Storms and flooding
                            // used to be excluded from naming entirely, so a
                            // middling fire reading labelled a ZIP surrounded
                            // by severe storms FIRE.
                            var kind: HazardKind
                            if let top = HazardStyle.dominantFamily(families) {
                                kind = HazardStyle.kind(forFamily: top)
                                // The qpf_flood family carries BOTH the gauge
                                // reading and plain rain probability. With no
                                // gauge near flood stage the score is only
                                // "it may rain", and calling that Flood puts a
                                // blue water badge over a dry ZIP.
                                if top == "qpf_flood", floodRealized < 0.45 {
                                    kind = HazardStyle.rain
                                }
                            } else {
                                kind = Self.dominantKind(c, latitude: lat, longitude: lon)
                            }
                            // A realized in-progress-danger WARNING here (Tornado,
                            // Flash Flood…) names the icon — it's the danger.
                            if let ev = alertEvent, alertSeverity >= 0.6,
                               let fam = RiskEquations.alertFamily(ev),
                               RiskEquations.primaryFamilies.contains(fam) {
                                kind = HazardStyle.kind(forEvent: ev)
                            }
                            // The BAND's driving-safety realized/predictor split,
                            // separate from `families` (which merges rain
                            // PROBABILITY into the Flood/Storm map filters):
                            //   • realized primaries = the road is impassable or
                            //     the driver is in direct danger (fire perimeter,
                            //     gauge flood over the road, SPC severe storm,
                            //     quake, tsunami…);
                            //   • predictors = precip probability, FORECAST winter
                            //     (snow prediction, not a blocked road), wind,
                            //     heat, cold, haze, UV — amplify a realized
                            //     primary, capped advisory alone.
                            var bandInput: [String: Double] = [
                                "fire": families["fire"] ?? 0,
                                "qpf_flood": floodRealized,
                                "convective": spc,
                                "seismic": families["seismic"] ?? 0,
                                "tropical": families["tropical"] ?? 0,
                                "tsunami": families["tsunami"] ?? 0,
                                "volcanic": families["volcanic"] ?? 0,
                                "avalanche": families["avalanche"] ?? 0,
                                "wind": families["wind"] ?? 0,
                                "heat": families["heat"] ?? 0,
                                "cold": families["cold"] ?? 0,
                                "air": families["air"] ?? 0,
                                "radiation": families["radiation"] ?? 0,
                                "precip": c.popPercent.map(RiskEquations.popRisk(pct:)) ?? 0,
                                "winter": families["winter"] ?? 0,
                            ]
                            // Realized NWS alert at this point: an in-progress-
                            // danger WARNING is a realized primary (Red-capable);
                            // a watch/advisory classifies to a predictor.
                            if let ev = alertEvent, let fam = RiskEquations.alertFamily(ev) {
                                bandInput[fam] = max(bandInput[fam] ?? 0, alertSeverity)
                            }
                            // DOT-reported closure = PROOF the road is blocked.
                            let closed = HazardFeedScores.closureScore(closures: closures, at: pt)
                            if closed > 0 {
                                bandInput["closure"] = closed
                                families["closure"] = closed
                                if closed >= 0.8 { kind = HazardStyle.closure }
                            }
                            return ViewportHazard(coordinate: pt,
                                                  kind: kind,
                                                  score: score,
                                                  familyScores: families,
                                                  bandInput: bandInput)
                        }
                    }
                }
                for await hz in group { if let hz { found.append(hz) } }
            }
            if Task.isCancelled { return }   // superseded sweep: stop before committing
            // An empty result usually means the fetches failed (offline, NWS
            // outage) — un-pin the debounce key so the next camera settle
            // retries instead of showing stale/empty hazards forever.
            if found.isEmpty { viewportHazardKey = ""; return }
            // Ring fetching below walks this — found PLUS the kept carryover
            // points, so a rain point surviving from the last sweep keeps its
            // ZIP ring (and its centered badge) instead of aging out.
            var merged = found
            if viewportHazardKey == key {
                // Merge, don't replace: the new sweep's box is offset from
                // the old one, and wholesale replacement blinked away icons
                // (rain) that were still inside the visible region.
                let newKeys = Set(found.map { "\(Int($0.coordinate.latitude * 50))|\(Int($0.coordinate.longitude * 50))" })
                let kept = viewportHazards.filter { hz in
                    let key = "\(Int(hz.coordinate.latitude * 50))|\(Int(hz.coordinate.longitude * 50))"
                    guard !newKeys.contains(key) else { return false }
                    let r = region
                    return abs(hz.coordinate.latitude - r.center.latitude) < r.span.latitudeDelta / 2
                        && abs(hz.coordinate.longitude - r.center.longitude) < r.span.longitudeDelta / 2
                }
                viewportHazards = found + kept
                merged = viewportHazards
                // Cluster once here, not on every render (O(n²) in the body).
                // Badge score is the point's REALIZED risk (primary hazards can
                // reach Red; secondary predictors amplify a realized primary but
                // are capped below Red on their own), so the number matches the
                // icon and a lone secondary — or a pile of small ones — never
                // reads as life-threatening. Only genuinely-elevated points get
                // a symbol.
                let sp = flowsSignposter.beginInterval("badge-sweep")
                clusteredBadgesCache = BadgeClustering.cluster(
                    viewportHazards.compactMap { hz in
                        hz.realized >= model.riskDisplayFloor
                            ? BadgeClustering.Item(coordinate: hz.coordinate,
                                                   kind: hz.kind, score: hz.realized)
                            : nil
                    },
                    minSeparationMeters: viewportHazardRadius * 2.5)
                rebuildRiskOverlays()   // once per sweep, not per render
                flowsSignposter.endInterval("badge-sweep", sp)
            }
            // Real ZIP borders for elevated US points (Census TIGERweb) —
            // the overlay outlines the actual affected ZCTA, sized by the
            // risk's true footprint, not a synthetic shape.
            // MERGE rather than replace: ZCTA rings stay pinned to their
            // ZIPs across grid refreshes instead of shifting with resampling
            // (the "cold areas keep moving" complaint). Rings whose ZIP no
            // longer has any elevated point age out.
            var rings = zctaRings
            var liveCodes = Set<String>()
            // Every elevated point gets a real ZIP boundary (ZCTAFetcher caches
            // by cell, so repeat sweeps are nearly free) — risk areas draw as
            // actual ZIP shapes, with hull blobs only as a genuine fallback.
            // Same floor as the badges: striped AREAS are the map's loudest
            // element and must not paint for clear-band scores.
            for hz in merged.prefix(40)
            where hz.realized >= model.riskDisplayFloor {
                if Task.isCancelled { return }   // superseded: skip remaining fetches
                if let z = await ZCTAFetcher.shared.zcta(containing: hz.coordinate) {
                    rings[z.code] = z.ring
                    liveCodes.insert(z.code)
                }
            }
            rings = rings.filter { liveCodes.contains($0.key) }
            if viewportHazardKey == key {
                zctaRings = rings
                // Center each badge on its contiguous ZIP: a badge whose
                // cluster-centroid falls inside a resolved ZCTA ring snaps to
                // that ring's shoelace centroid — the symbol sits at the middle
                // of the actual ZIP shape, not at the grid-sample average.
                // A cluster averaging points from NEIGHBORING ZIPs can land in
                // the gap between rings ("rain icon isn't on the striped
                // area") — those snap to the nearest ring center within a
                // couple of sample radii. Two badges of one kind landing on
                // the same center collapse to one (duplicate identities).
                let centers = rings.values.map { (ring: $0, center: Self.centroid(of: $0)) }
                var seen = Set<String>()
                clusteredBadgesCache = clusteredBadgesCache.compactMap { badge in
                    var snapped = badge
                    if let hit = centers.first(where: {
                        HazardFeedScores.pointInPolygon(badge.coordinate, $0.ring)
                    }) {
                        snapped = BadgeClustering.Item(coordinate: hit.center,
                                                       kind: badge.kind, score: badge.score)
                    } else if let near = centers.min(by: {
                        POIRanking.meters($0.center, badge.coordinate)
                            < POIRanking.meters($1.center, badge.coordinate)
                    }), POIRanking.meters(near.center, badge.coordinate)
                            < viewportHazardRadius * 2.5 {
                        snapped = BadgeClustering.Item(coordinate: near.center,
                                                       kind: badge.kind, score: badge.score)
                    }
                    return seen.insert(snapped.stableID).inserted ? snapped : nil
                }
                rebuildRiskOverlays()   // ZCTA rings resolved — refresh overlays
            }
        }
    }

    /// Live family scores from the ported equations — the NA-wide backing
    /// for the Map Filter families. Fire/air/radiation/seismic have no live
    /// point proxy (those stay export-only and say so in Settings).
    nonisolated private static func familyScores(
        _ c: ForecastConditions, latitude: Double, longitude: Double
    ) -> [String: Double] {
        // Display families for the Map Filters (shared decomposition with the
        // route scorer): the forecast predictors, with precip probability shown
        // as the Flood family (a predictive overlay) plus the blended
        // environmental composite. The BAND keys off `bandInput` instead.
        var out = c.predictorFamilies(latitude: latitude, longitude: longitude, elevationMeters: nil)
        out["qpf_flood"] = out.removeValue(forKey: "precip") ?? 0
        out["environmental"] = c.forecastScore(latitude: latitude, longitude: longitude, elevationMeters: nil)
        // SEASONAL-NORMAL gate for MAP PRESENTATION, applied across the board:
        // between the regional+seasonal average min and max (±σ) is "normal"
        // conditions — nothing draws. Temperature AND wind only present when
        // they exceed that window (ordinary wind was dominating the map once
        // temperature was gated). Route scoring is untouched (it reads
        // predictorFamilies directly).
        let norms = ClimateProfiles.seasonalNorms(
            week: SeasonalRiskModel.week(), latitude: latitude, longitude: longitude)
        let tempBeyond = c.temperatureF.map {
            ClimateProfiles.temperatureBeyondNormal(tempF: $0, norms: norms)
        } ?? false
        if !tempBeyond { out["heat"] = 0; out["cold"] = 0 }
        let windBeyond = c.windMph.map {
            ClimateProfiles.windBeyondNormal(windMph: $0, norms: norms)
        } ?? false
        if !windBeyond { out["wind"] = 0 }
        return out
    }

    /// Which hazard drives these conditions — heat/cold vs wind vs rain.
    nonisolated private static func dominantKind(
        _ c: ForecastConditions, latitude: Double, longitude: Double) -> HazardKind {
        let band = ClimateProfiles.profile(latitude: latitude, longitude: longitude)
        let t = c.temperatureF.map {
            RiskEquations.temperatureRisk(tempF: $0, comfortLowF: band.comfortLowF,
                                          comfortHighF: band.comfortHighF,
                                          recordLowF: band.recordLowF,
                                          recordHighF: band.recordHighF)
        } ?? 0
        let w = c.windMph.map(RiskEquations.windRisk(mph:)) ?? 0
        let p = c.popPercent.map(RiskEquations.popRisk(pct:)) ?? 0
        // Every icon honors the seasonal-normal gate: heat/cold and WIND only
        // claim the symbol when beyond the regional+seasonal window; an
        // ordinary breezy or warm day falls through to precipitation.
        let norms = ClimateProfiles.seasonalNorms(
            week: SeasonalRiskModel.week(), latitude: latitude, longitude: longitude)
        let tempBeyond = c.temperatureF.map {
            ClimateProfiles.temperatureBeyondNormal(tempF: $0, norms: norms)
        } ?? false
        let windBeyond = c.windMph.map {
            ClimateProfiles.windBeyondNormal(windMph: $0, norms: norms)
        } ?? false
        if t >= w && t >= p && tempBeyond {
            let hot = (c.temperatureF ?? 70) > band.comfortHighF
            return hot ? HazardStyle.heat : HazardStyle.cold
        }
        if w >= p && windBeyond { return HazardStyle.wind }
        // Precipitation PROBABILITY is the fall-through — label it rain
        // chance, not flood: PoP is a predictor; "Flood" is reserved for
        // realized water (gauges, flood warnings, the qpf_flood family).
        return HazardStyle.rain
    }

    /// The traveler's map marker: mode-appropriate icon in a colored puck.
    /// On a transit itinerary the icon FOLLOWS THE LEG the traveler is on —
    /// walker on the station walk, train/bus once aboard (nearest-leg by GPS),
    /// so arriving at the station naturally transitions the icon.
    private var travelerMarker: some View {
        let (symbol, color): (String, Color) = {
            if let itin = model.transitItinerary {
                let rail = itin.mode.lowercased().contains("rail")
                    || itin.mode.lowercased().contains("amtrak")
                let rideSymbol = itin.mode == "Plane" ? "airplane"
                    : rail ? "tram.fill" : "bus.fill"
                guard let here = model.location.coordinate,
                      let leg = Self.nearestLeg(of: itin, to: here) else {
                    return (rideSymbol, .purple)
                }
                return switch leg.kind {
                case .walk: ("figure.walk", .green)
                case .drive: ("car.fill", .blue)   // park-and-ride access or hailed ride
                case .ride: (rideSymbol, .purple)
                }
            }
            if model.walkingMode { return ("figure.walk", .green) }
            // The driver's own vehicle, drawn from the angle the camera is
            // actually looking from: the roof flat on the map, the back when
            // following behind, the front when the camera faces it. Flat art
            // swapped per aspect, not a 3D model — which is all a marker
            // this size needs to read as having a direction.
            // The angle the CHASE just set, when it owns the camera —
            // otherwise the last settled one from a free pan.
            let camHeading = chaseAngle?.heading ?? cameraHeading
            let camPitch = chaseAngle?.pitch ?? cameraPitch
            let aspect = VehicleAspect.forCamera(
                pitchDegrees: camPitch,
                relativeBearing: camHeading - (drawnHeading ?? camHeading))
            return (model.vehicleShape.symbol(aspect),
                    Self.markerColor(model.vehicleColorName))
        }()
        // Heading-up camera already rotates the WORLD to the course — rotating
        // the marker again pointed it wrong by 2×course. On a free camera,
        // rotate by heading MINUS the retained camera heading: a pan mid-drive
        // keeps the heading-up world, so assuming north-up re-created the
        // double-rotation this comment warns about.
        //
        // The heading used is the marker's OWN smoothed one, the same value
        // that picked the drawing above — a raw course reading here would
        // let the icon's rotation and its front/back/side view disagree, and
        // would jitter on GPS course noise the smoothing exists to absorb.
        let markerHeading = drawnHeading
        let rotate = model.mode == .navigating && markerHeading != nil
            && !cameraFollows
        return Image(systemName: symbol)
            .scaledFont(size: 15, weight: .bold)
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(color.gradient)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .shadow(radius: 3)
            .rotationEffect(.degrees(
                rotate ? (markerHeading ?? 0) - cameraHeading : 0))
    }

    /// Which itinerary leg the traveler is currently ON: nearest leg polyline
    /// to the GPS fix (sampled every ~10th vertex — 3 legs, render-cheap).
    nonisolated private static func nearestLeg(
        of itin: TransitItinerary, to here: CLLocationCoordinate2D) -> TransitLeg? {
        var best: (TransitLeg, Double)?
        for leg in itin.legs {
            guard let poly = leg.polyline else { continue }
            let n = poly.pointCount
            guard n > 0 else { continue }
            var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid,
                                                  count: n)
            poly.getCoordinates(&coords, range: NSRange(location: 0, length: n))
            var d = Double.greatestFiniteMagnitude
            var i = 0
            while i < n {
                d = min(d, POIRanking.meters(coords[i], here))
                i += max(n / 24, 1)
            }
            if best == nil || d < best!.1 { best = (leg, d) }
        }
        return best?.0
    }

    /// Camera moves WE initiate, stamped so gesture detection can ignore them.
    private func moveCamera(_ position: MapCameraPosition) {
        programmaticCameraMove = Date()
        withAnimation(.easeInOut(duration: 0.8)) { camera = position }
    }

    /// The flight-phase camera for an active plane itinerary: altitude from
    /// the distance to the NEAREST airport (the flight arc's endpoints) —
    /// walking-close on the ground and on approach, continent-wide at cruise.
    private func flightCamera(for fix: CLLocation) -> MapCamera? {
        guard model.transitItinerary?.mode == "Plane",
              let poly = model.transitItinerary?.legs
                  .first(where: { $0.kind == .ride })?.polyline,
              poly.pointCount >= 2 else { return nil }
        var board = CLLocationCoordinate2D()
        var alight = CLLocationCoordinate2D()
        poly.getCoordinates(&board, range: NSRange(location: 0, length: 1))
        poly.getCoordinates(&alight, range: NSRange(location: poly.pointCount - 1,
                                                    length: 1))
        let nearest = min(POIRanking.meters(board, fix.coordinate),
                          POIRanking.meters(alight, fix.coordinate))
        return MapCamera(
            centerCoordinate: fix.coordinate,
            distance: CameraZoom.flightAltitude(metersToNearestAirport: nearest),
            heading: fix.course >= 0 ? fix.course : 0,
            pitch: 0)
    }

    private var mapLayer: some View {
        mapContent
            // The red-alert reach-circle tick only exists while a red alert
            // with a coordinate is actually showing — the old unconditional
            // publisher woke the main thread every 30 s for the app's whole
            // lifetime to serve a state that is almost never active. The
            // timer rides a clear overlay so the Map's identity is stable;
            // 5 s tolerance lets firings coalesce with other wakeups.
            .overlay {
                if model.imminentWarning?.incidentCoordinate != nil {
                    Color.clear
                        .allowsHitTesting(false)
                        .onReceive(redAlertTimer) { _ in
                            redAlertTick += 1   // grow the reach circle
                        }
                }
            }
    }

    @Namespace private var mapScope

    private var mapContent: some View {
        // interactionModes is an INITIALIZER parameter on SwiftUI's Map, not
        // a modifier. Stated explicitly rather than left to the default so
        // pinch-to-zoom, two-finger rotate, two-finger pitch and drag-to-pan
        // can't be narrowed by accident later.
        Map(position: $camera, interactionModes: .all, scope: mapScope) {
            // OFFLINE LIFELINE: the recorded breadcrumb trail — the way you
            // came, drawable with zero network. Orange dashes, newest at the
            // vehicle; follow it backward to walk out the way you came in.
            if model.breadcrumbs.showTrail, model.breadcrumbs.points.count >= 2 {
                MapPolyline(coordinates: model.breadcrumbs.points)
                    .stroke(Color.orange.opacity(0.95),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [8, 6]))
            }
            // OFFLINE LIFELINE, the other half: the ROAD AHEAD, saved to disk
            // for trips between towns. With no signal Apple can't route, but
            // this line already knows the way — so it draws whenever the
            // network is gone and nothing live is on the map.
            if model.breadcrumbs.isOffline, model.navigation.route == nil,
               let here = model.location.coordinate,
               let saved = model.corridors.nearest(to: here),
               saved.coordinates.count >= 2 {
                MapPolyline(coordinates: saved.coordinates)
                    .stroke(Color.purple.opacity(0.9),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [14, 8]))
                if let end = saved.destination {
                    Annotation(saved.destinationName, coordinate: end) {
                        Image(systemName: "flag.checkered")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.purple)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .shadow(radius: 3)
                    }
                }
            }
            // Mode-aware "you are here": a simplified vehicle icon at the
            // precise GPS position — car when driving, walker in walking mode,
            // tram/bus when a transit itinerary is active. Rotates with the
            // course while navigating so the car points down the road.
            if let here = model.location.coordinate {
                Annotation("", coordinate: drawnFix ?? here) {
                    travelerMarker
                }
                // Fuel-reach ring: ONLY once the tank is 75%+ empty — the
                // blue circle is how far the remaining fuel can take you,
                // shrinking toward the car as the tank approaches empty.
                if model.mode == .navigating, !model.walkingMode,
                   let frac = model.vehicle.predictedFuelFraction, frac <= 0.25,
                   let rangeMiles = model.vehicle.expectedRangeMiles, rangeMiles > 0 {
                    MapCircle(center: here, radius: rangeMiles * 1609.344)
                        .foregroundStyle(Color.blue.opacity(0.06))
                        .stroke(Color.blue.opacity(0.55), lineWidth: 2)
                }
            } else {
                UserAnnotation()
            }

            // RED ALERT incident: symbol at the described location, ringed by
            // how far a vehicle could have driven since the incident at the
            // speeds nearby roads allow — the circle GROWS with time.
            // The reach circle is about a thing that MOVES — a fleeing
            // vehicle as much as a spreading hazard — so a lookout alert
            // draws it too.
            if let warning = model.imminentWarning,
               warning.action == .shelter || warning.action == .lookout,
               let incident = warning.incidentCoordinate {
                let _ = redAlertTick   // re-evaluate as time passes
                let elapsed = Date().timeIntervalSince(warning.onset ?? Date())
                let radius = PursuitReach.radiusMeters(
                    elapsedSeconds: elapsed, speedMph: warning.reachSpeedMph)
                MapCircle(center: incident, radius: radius)
                    .foregroundStyle(Theme.riskRed.opacity(0.12))
                    .stroke(Theme.riskRed.opacity(0.7), lineWidth: 2)
                Annotation("", coordinate: incident) {
                    ZStack {
                        Circle().fill(Theme.riskRed).frame(width: 34, height: 34)
                        Image(systemName: warning.vehicleEntity?.kind.symbol
                              ?? "exclamationmark.octagon.fill")
                            .scaledFont(size: 16, weight: .bold)
                            .foregroundStyle(.white)
                    }
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .shadow(radius: 3)
                }
            }

            // Dispatch calls heard on the local feed and transcribed on this
            // device — small pins, the size of the vehicle marker, that fade
            // out on their own. Colour by kind: blue police, red medical,
            // orange fire.
            ForEach(model.visibleScannerIncidents) { incident in
                Annotation("", coordinate: incident.coordinate) {
                    ScannerIncidentPin(incident: incident)
                }
            }

            // Fixed automated enforcement: speed and red-light cameras, from
            // OpenStreetMap. Permanent, publicly signed installations — the
            // only enforcement FLOWS can lawfully carry (see
            // EnforcementCameras for why a parked patrol car is not here).
            ForEach(model.enforcementCameras) { camera in
                Annotation("", coordinate: camera.coordinate) {
                    ZStack {
                        Circle().fill(Color.black.opacity(0.85))
                            .frame(width: 26, height: 26)
                        Image(systemName: camera.kind.symbol)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.onDark)
                    }
                    .overlay(Circle().stroke(Theme.riskYellow, lineWidth: 2))
                    .shadow(radius: 2)
                    .help(camera.kind.title)
                }
            }

            // The web app's ZIP risk choropleth, family-filtered by the Map
            // Filter — drawn first, under everything. Brightened (0.35) with
            // a visible floor at 0.2 so the filterable overlay actually shows.
            if model.showRiskField, model.riskField.loaded, model.mode != .navigating,
               let region = visibleRegion,
               // Family index hoisted above the ForEach — it was re-resolved
               // once per rendered ZIP (up to 220 per frame).
               let fi = model.riskField.familyIndex(model.overlayFamily) {
                ForEach(model.riskField.zips(in: region, family: model.overlayFamily, limit: 220)) { entry in
                    if let ring = entry.ring,
                       fi < entry.scores.count, entry.scores[fi] >= 0.2 {
                        MapPolygon(coordinates: ring)
                            .foregroundStyle(FlowsCore.riskBand(score: entry.scores[fi]).color
                                .opacity(0.15 + 0.25 * entry.scores[fi]))
                    }
                }
            }

            // ONE normalized layer (per request): everything folds into the
            // NORMALIZED ENVIRONMENTAL score — live NWS/ECCC/SMN conditions,
            // fire, air, UV, seismic — as band-tinted circles + one tappable
            // symbol per area. No family picker, no striped sublayers.
            if model.showRiskField, model.mode != .navigating {
                // Contiguous OUTLINES of affected areas (adjacent elevated
                // grid points cluster → hull polygon), not circles.
                // Continuous field everywhere (like WI's choropleth): every
                // grid point tints faintly by band; ZCTA rings + badges key
                // off genuinely elevated scores.
                // Risk-area overlays — real ZCTA ZIP rings (US) + hull blobs
                // (Canada/Mexico + still-loading) — are precomputed once per sweep
                // in rebuildRiskOverlays(); the map body only DRAWS them, so the
                // O(U²) clustering + O(K·E) worst-scans no longer run per render.
                // Two-color risk areas: a solid RISK-LEVEL base (green/yellow/red)
                // with the dominant HAZARD-TYPE as diagonal stripes on top — e.g.
                // a green area striped blue = low risk, flood. Border = risk color.
                // TRANSPARENT fill; the area reads through two alternating
                // stripe sets — risk-level color (green/yellow/red) and hazard-
                // type color (blue flood, orange fire, …). Border = risk color.
                ForEach(zctaOverlays) { ov in
                    let risk = HazardStyle.riskLevelColor(FlowsCore.riskBand(score: ov.score))
                    MapPolygon(coordinates: ov.ring)
                        .foregroundStyle(risk.opacity(0.05))
                        .stroke(risk.opacity(0.9), lineWidth: 2)
                    ForEach(Array(ov.riskStripes.enumerated()), id: \.offset) { _, seg in
                        MapPolyline(coordinates: seg)
                            .stroke(risk.opacity(0.85), lineWidth: 3)
                    }
                    ForEach(Array(ov.typeStripes.enumerated()), id: \.offset) { _, seg in
                        MapPolyline(coordinates: seg)
                            .stroke(ov.kind.color.opacity(0.85), lineWidth: 3)
                    }
                }
                ForEach(blobOverlays) { ov in
                    let risk = HazardStyle.riskLevelColor(FlowsCore.riskBand(score: ov.score))
                    MapPolygon(coordinates: ov.ring)
                        .foregroundStyle(risk.opacity(0.05))
                        .stroke(risk.opacity(0.85), lineWidth: 2)
                    ForEach(Array(ov.riskStripes.enumerated()), id: \.offset) { _, seg in
                        MapPolyline(coordinates: seg)
                            .stroke(risk.opacity(0.8), lineWidth: 3)
                    }
                    ForEach(Array(ov.typeStripes.enumerated()), id: \.offset) { _, seg in
                        MapPolyline(coordinates: seg)
                            .stroke(ov.kind.color.opacity(0.8), lineWidth: 3)
                    }
                }
                // Stable LOCATION+kind identity — positional ids remapped every
                // non-deterministic sweep and ghosted badges (same bug class as
                // ViewportHazard.id).
                ForEach(clusteredViewportBadges, id: \.stableID) { hz in
                    Annotation("", coordinate: hz.coordinate) {
                        hazardBadge(hz.kind, at: hz.coordinate, score: hz.score)
                    }
                }
            }

            if model.mode == .choosing {
                // Risk field first (under everything): the actual NWS alert
                // polygons along the highlighted corridor, severity-tinted —
                // the corridor-scoped analog of the web app's ZIP choropleth.
                if let hl = model.routeChoices.first(where: { $0.id == model.highlightedRouteID }) {
                    alertPolygonOverlay(hl)
                    corridorHazardShapes(hl)
                }
                // ALL alternates side by side: gray underlays, then the
                // highlighted route on top in per-segment risk-band colors so
                // the risk being accepted is visible on the map itself.
                ForEach(model.routeChoices.filter { $0.id != model.highlightedRouteID }) { alt in
                    MapPolyline(alt.route.polyline)
                        .stroke(Color.gray.opacity(0.55), lineWidth: 5)
                }
                if let hl = model.routeChoices.first(where: { $0.id == model.highlightedRouteID }) {
                    if model.show3DMap { gradeRibbon(hl) }   // elevation casing UNDER the route
                    riskStrokedRoute(hl)
                    if model.show3DMap { steepGradeMarkers(hl) }
                }
                // Public-transit itinerary drawn IN FLOWS: walk legs (real
                // MapKit geometry) solid green; a park-and-ride access leg
                // solid blue (it's a drive); the ride leg follows the road
                // corridor (MKDirections .automobile, straight connector only if
                // unroutable) dashed purple. Final green leg is the no-car last mile.
                if let itin = model.transitItinerary {
                    ForEach(itin.legs) { leg in
                        if let poly = leg.polyline {
                            let color: Color = switch leg.kind {
                            case .walk: .green
                            case .drive: .blue
                            case .ride: .purple
                            }
                            MapPolyline(poly)
                                .stroke(color,
                                        style: StrokeStyle(
                                            lineWidth: leg.kind == .ride ? 4 : 5,
                                            lineCap: .round,
                                            dash: leg.kind == .ride ? [10, 8] : []))
                        }
                    }
                }
            } else if model.mode == .navigating, let route = model.navigation.route {
                alertPolygonOverlay(route)
                corridorHazardShapes(route)
                // Appended-stop continuation: the rest of the trip after the
                // stop, dashed, under the leg being driven.
                if let next = model.upcomingLeg {
                    MapPolyline(next.route.polyline)
                        .stroke(Color.blue.opacity(0.5),
                                style: StrokeStyle(lineWidth: 5, dash: [8, 6]))
                }
                if model.show3DMap { gradeRibbon(route) }   // elevation casing UNDER the route
                riskStrokedRoute(route)
                if model.show3DMap { steepGradeMarkers(route) }
                // Long walking estimate: the accurate Apple pedestrian path for
                // the stretch right ahead, drawn (bright green, solid) over the
                // big-picture road route — real sidewalks locally, road-based
                // direction overall.
                if route.isWalkingEstimate, model.walkingRefinedPath.count >= 2 {
                    MapPolyline(coordinates: model.walkingRefinedPath)
                        .stroke(Color.green,
                                style: StrokeStyle(lineWidth: 6, lineCap: .round))
                }
            }

            ForEach(model.poi.results) { ranked in
                if model.poi.activeKind == .gas, let price = ranked.pricePerUnit {
                    // The price IS the pin for gas stops.
                    Annotation(ranked.item.name ?? "Stop",
                               coordinate: ranked.item.placemark.coordinate) {
                        Text(String(format: "$%.2f", price))
                            .scaledFont(size: 12, weight: .heavy).monospacedDigit()
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(ranked.id == model.poi.selected?.id
                                        ? Theme.cta : Theme.cardBackground)
                            .foregroundStyle(ranked.id == model.poi.selected?.id
                                             ? Theme.onCTA : Color.primary)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Theme.cta, lineWidth: 1))
                            .shadow(radius: 2)
                            .onTapGesture { model.poi.choose(ranked) }
                    }
                } else {
                    // Annotation, not Marker: Marker swallows taps, which left
                    // tourist stars (and every other stop pin) dead to clicks.
                    Annotation(ranked.item.name ?? "Stop",
                               coordinate: ranked.item.placemark.coordinate) {
                        poiPin(ranked)
                    }
                }
            }
        }
        // Apple's traffic layer is exactly the "live conditions" underlay the
        // web app approximates with 511 feeds — free, continent-wide.
        .mapStyle(.standard(elevation: model.show3DMap ? .realistic : .flat,
                            showsTraffic: true))
        // Terrain relief only READS at an angle: toggling 3D on pitches the
        // camera over the current view (flat country still looks flat — the
        // Rockies don't). Toggling off levels it back.
        // Corridor ZIP areas follow the active route (highlight in choosing,
        // the driven route in navigation) and refresh when hydration lands.
        .task(id: "\(model.highlightedRouteID?.uuidString ?? "")|\(model.navigation.route?.id.uuidString ?? "")|\(model.routeChoices.filter(\.weatherScored).count)") {
            let active = model.mode == .navigating
                ? model.navigation.route
                : model.routeChoices.first(where: { $0.id == model.highlightedRouteID })
            if let active, active.weatherScored {
                await rebuildCorridorAreas(for: active)
            }
        }
        .onChange(of: model.show3DMap) { _, on in
            guard let region = visibleRegion else { return }
            let distance = max(region.span.latitudeDelta * 111_000 * 1.4, 1_200)
            moveCamera(.camera(MapCamera(centerCoordinate: region.center,
                                         distance: distance, heading: 0,
                                         pitch: on ? 55 : 0)))
        }
        // MapKit's own compass lives top-right, where the phone's status
        // icons cover it — the built-ins stay off. While driving the
        // directions banner carries a compass instead (NavigationHUD);
        // a north-up planning map has nothing to report.
        .mapControls { }
        // No network: routing can't help, but the breadcrumb trail can. The
        // banner names the situation and offers the way back — the recorded
        // trail draws entirely offline (MapKit shows recently-cached tiles).
        .overlay(alignment: .top) {
            if model.breadcrumbs.isOffline {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                    Text("Offline — live routing unavailable.")
                        .font(.footnote.weight(.semibold))
                    if model.breadcrumbs.points.count >= 2 {
                        Button(model.breadcrumbs.showTrail
                               ? "Hide my trail"
                               : String(format: "Find my way back (%.1f mi trail)",
                                        model.breadcrumbs.wayBack().meters / 1609.344)) {
                            model.breadcrumbs.showTrail.toggle()
                        }
                        .font(.footnote.weight(.bold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.top, golden.pad)
            }
        }
        .mapScope(mapScope)
        // A drag is DEFINITIVE user intent: stop chasing GPS immediately.
        // (The old stamp-window heuristic never fired at 1 Hz guidance —
        // every settle looked programmatic and the map fought every pan.)
        // Applies to the flight-phase follow too — panning while a plane
        // itinerary is chosen pauses it; picking the plane card resumes.
        .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in
            releaseCameraToUser()
        })
        // Pinch and two-finger rotate are user intent too, and neither one
        // is a drag. Without these the automatic zoom kept overriding a
        // pinch: the settle-window backstop can't tell them apart, because
        // guidance moves the camera about once a second, so every gesture
        // landed inside the "we just moved it ourselves" window.
        .simultaneousGesture(MagnifyGesture().onChanged { _ in
            releaseCameraToUser()
        })
        .simultaneousGesture(RotateGesture().onChanged { _ in
            releaseCameraToUser()
        })
        // Click-off dismiss: a click/tap on the MAP closes any open floating
        // panel or menu (settings, fuel/food/store menus, stop list, slider
        // card, towing card). Annotation buttons (risk symbols, gas-price
        // pins) and the chrome cards sit deeper in the hierarchy, so their
        // own taps win and this never fires for them — selections still work.
        .onTapGesture {
            hazardInfo = nil
            model.dismissFloatingPanels()
        }
        // `.onEnd` is LOAD-BEARING for the ZIP overlay: RiskFieldService's
        // zips(in:) memo holds only ~8 region keys, so a stable region during
        // a pan keeps it hitting. `.continuous` would make every frame a memo
        // miss running a full grid select (at continental zoom, a sort of all
        // ~33k entries per frame).
        .onReceive(model.location.$latest.compactMap { $0 }) { fix in
            // Slide to the new fix instead of teleporting. A large step is
            // the GPS correcting itself (leaving a tunnel), and animating
            // across that would draw the car through buildings — so that
            // one snaps.
            let now = Date()
            let gap = lastFixAt.map { now.timeIntervalSince($0) } ?? 1
            lastFixAt = now
            // Ease toward the new course rather than snapping to it. GPS
            // course steps in whole degrees and jumps at a turn, so a marker
            // pinned straight to it flicks round; easing the short way makes
            // the turn read as a turn. (Crossing north eases 10°, not 350° —
            // VehicleTrack.easedHeading.)
            let reported = VehicleTrack.heading(courseDegrees: fix.course,
                                                speedMps: max(fix.speed, 0),
                                                previous: drawnHeading)
            if let reported, let current = drawnHeading {
                drawnHeading = VehicleTrack.easedHeading(from: current,
                                                         to: reported,
                                                         fraction: 0.45)
            } else {
                drawnHeading = reported
            }
            guard let previous = drawnFix else {
                drawnFix = fix.coordinate
                return
            }
            if VehicleTrack.shouldAnimate(from: previous, to: fix.coordinate) {
                withAnimation(.linear(duration: VehicleTrack.slideSeconds(gap: gap))) {
                    drawnFix = fix.coordinate
                }
            } else {
                drawnFix = fix.coordinate
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
            cameraHeading = context.camera.heading
            cameraPitch = context.camera.pitch
            refreshViewportHazards(context.region)

            // A camera settle we didn't initiate while navigating = the user
            // panned/zoomed. Stop chasing GPS until they re-center. The
            // window is generous: the GO jump (state-wide choices view down
            // to street level) can take MapKit well past the animation's
            // nominal 0.8 s, and a settle just outside a tight window read
            // as a user pan — killing the chase before the trip even moved.
            // Real pans are caught by the drag gesture above; this backstop
            // only needs to catch stationary pinches.
            if model.mode == .navigating, cameraFollows,
               Date().timeIntervalSince(programmaticCameraMove) > 4.0 {
                cameraFollows = false
            }
        }
        .ignoresSafeArea()
    }

    /// The driver's chosen marker colour, by name so the setting survives
    /// as a word rather than a packed number.
    static func markerColor(_ name: String) -> Color {
        switch name {
        case "red": return .red
        case "green": return .green
        case "orange": return .orange
        case "purple": return .purple
        case "yellow": return .yellow
        case "gray": return .gray
        case "black": return .black
        default: return .blue
        }
    }

    /// Share of the window the top chrome covers while driving: the
    /// directions banner, plus the instrument cluster when it's up.
    private var chromeTopFraction: Double {
        var f = 0.16                                   // directions banner
        if model.vehicle.profile != nil,
           !model.collapsedPanels.contains("fuel") { f += 0.10 }
        if model.imminentWarning != nil { f += 0.12 }
        return f
    }

    /// …and the drive bar at the bottom.
    private var chromeBottomFraction: Double { 0.22 }

    /// Hand the camera to the driver: any deliberate gesture — drag, pinch,
    /// rotate — stops the automatic zoom and heading-up chase until the
    /// re-center button gives it back. A map that fights your fingers is
    /// worse than one that never moved on its own.
    private func releaseCameraToUser() {
        guard cameraFollows else { return }
        chaseAngle = nil        // the driver owns the angle now
        // No mode guard. The follow camera also runs while PLANNING (a
        // passenger scouting the route in a moving car), and gating the
        // release on .navigating meant those drags did nothing at all: the
        // next GPS fix snapped the map straight back, once a second, and the
        // map could not be read while the car was moving.
        cameraFollows = false
    }

    /// One tappable stop pin. Tapping mirrors tapping the stop's list row —
    /// it becomes the selection (row highlights + scrolls into view, map
    /// zooms), and a tourist star also opens its detail card.
    private func poiPin(_ ranked: POIService.RankedPOI) -> some View {
        let isSelected = ranked.id == model.poi.selected?.id
        return Button {
            model.poi.choose(ranked)
            if model.poi.activeKind == .tourist {
                model.poi.touristDetail = ranked
                hazardInfo = nil   // shares the bottom-center slot
            }
        } label: {
            Image(systemName: model.poi.activeKind?.symbol ?? "mappin")
                .scaledFont(size: 13, weight: .bold)
                .foregroundStyle(isSelected ? Theme.onCTA : Color.white)
                .frame(width: 28, height: 28)
                .background(isSelected ? Theme.cta : Color.gray)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                .shadow(radius: 2)
        }
        .buttonStyle(.plain)
    }

    /// NWS alert polygons intersecting a route's corridor — striped in the
    /// hazard's color with its symbol at the centroid ("tornado symbol in
    /// the center of the shape"), drawn under the route lines.
    @MapContentBuilder
    private func alertPolygonOverlay(_ route: PlannedRoute) -> some MapContent {
        ForEach(route.alertPolygons) { poly in
            let kind = HazardStyle.kind(forEvent: poly.event)
            // Solid tint + stroke (MapKit ignores ImagePaint pattern fills).
            MapPolygon(coordinates: poly.coordinates)
                .foregroundStyle(kind.color.opacity(0.22))
                .stroke(kind.color.opacity(0.85), lineWidth: 2)
            let center = Self.centroid(of: poly.coordinates)
            Annotation("", coordinate: center) {
                hazardBadge(kind, at: center, score: poly.severity)
            }
        }
    }

    /// Hazard shapes along the WHOLE corridor: many NWS alerts are
    /// zone-referenced with no polygon geometry, and the ZIP field only
    /// covers states the R engine scores — so every risky corridor sample
    /// also gets a striped circle in its hazard's pattern. Overlaps stack.
    @MapContentBuilder
    private func corridorHazardShapes(_ route: PlannedRoute) -> some MapContent {
        // Display floor sits BELOW the green band cut: the driver asked to
        // SEE all weather along the route, not only what already scores.
        let risky = route.riskSamples.filter { $0.risk >= model.riskDisplayFloor }
        // REAL ZIP boundaries for the affected areas (fetched per route);
        // a circle only remains for samples whose ZCTA hasn't resolved.
        if corridorAreaRouteID == route.id {
            ForEach(corridorAreas) { area in
                MapPolygon(coordinates: area.ring)
                    .foregroundStyle(area.kind.color.opacity(0.20))
                    .stroke(area.kind.color.opacity(0.75), lineWidth: 2)
            }
        }
        // ONE symbol at the center of each contiguous risk area — clustered
        // once per route change (rebuildCorridorAreas), never per frame; falls
        // back to a live cluster only until that first rebuild lands.
        let badges = corridorAreaRouteID == route.id
            ? corridorBadges
            : BadgeClustering.cluster(
                risky.map { BadgeClustering.Item(coordinate: $0.coordinate,
                                                 kind: corridorKind($0), score: $0.risk) },
                minSeparationMeters: 80_000)
        ForEach(badges, id: \.stableID) { badge in
            Annotation("", coordinate: badge.coordinate) {
                hazardBadge(badge.kind, at: badge.coordinate, score: badge.score)
            }
        }
    }

    private func corridorKind(_ sample: RiskSample) -> HazardKind {
        sample.worstEvent.map(HazardStyle.kind(forEvent:))
            ?? HazardStyle.kind(forFamily: "environmental")
    }

    /// Symbol size follows the zoom: closing in on a storm grows its badge,
    /// zooming out to the continent shrinks it — so a single symbol reads as
    /// anchored to the risk area's central weight at any camera height.
    private var badgeSize: CGFloat {
        let span = visibleRegion?.span.latitudeDelta ?? 6
        return CGFloat(min(44, max(16, 26 * pow(5.0 / max(span, 0.05), 0.28))))
    }

    /// Tapping a risk symbol opens its summary card ("what is this flood
    /// icon telling me here?"). Badges without a coordinate are decorative.
    private func hazardBadge(
        _ kind: HazardKind, at coordinate: CLLocationCoordinate2D? = nil, score: Double? = nil
    ) -> some View {
        let size = badgeSize
        return Button {
            if let coordinate {
                hazardInfo = HazardTapInfo(kind: kind, coordinate: coordinate, score: score)
                model.poi.touristDetail = nil   // shares the bottom-center slot
            }
        } label: {
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(kind.color.opacity(0.9))
                .clipShape(Circle())
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                .shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(coordinate != nil)
    }

    /// The tapped symbol's story: hazard type, band, the R engine's hazard
    /// summary for that ZIP (or the active alert event), where it is.
    /// The tapped-hazard card. Anchoring belongs to `bottomCardSlot` — this
    /// only says what the card IS.
    private func hazardCard(_ info: HazardTapInfo) -> some View {
        let fieldSummary = model.riskField.summary(at: info.coordinate)
        let band = info.score.map { FlowsCore.riskBand(score: $0) }
        return Group {
            HStack(spacing: 10) {
                Image(systemName: info.kind.symbol)
                    .scaledFont(size: 22, weight: .bold)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(info.kind.color)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("\(info.kind.name) risk")
                            .scaledFont(size: 15, weight: .bold)
                        if let band {
                            Text(band.rawValue)
                                .font(.caption.weight(.heavy))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background((band == .clear ? Color.secondary : band.color).opacity(0.15))
                                .foregroundStyle(band == .clear ? Color.secondary : band.color)
                                .clipShape(Capsule())
                        }
                    }
                    Text(fieldSummary
                         ?? "Elevated \(info.kind.name.lowercased()) conditions in this area — "
                         + "drive to conditions and watch for official alerts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    if let score = info.score {
                        Text(String(format: "Local risk score %.0f%%", score * 100))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    // Expert actions, SCALED to the band — mild elevation
                    // gets proportionate advice (NWS/CDC/FEMA guidance).
                    ForEach(RiskAdvice.actions(kindName: info.kind.name,
                                               band: band ?? .green), id: \.self) { line in
                        Label(line, systemImage: "checkmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                    // The issuing agency's page for THIS location — a
                    // specific alert link when one is active, else the
                    // official point-forecast/hazards page.
                    if let url = info.sourceURL
                        ?? model.imminentWarning?.sourceURL
                        ?? RiskAdvice.officialURL(latitude: info.coordinate.latitude,
                                                  longitude: info.coordinate.longitude) {
                        Link("Official warning page →", destination: url)
                            .font(.caption.weight(.bold))
                    }
                }
                Spacer()
                Button { hazardInfo = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 18)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .floatingCard()
            .frame(maxWidth: isCompact ? .infinity : golden.cardMax)
        }
    }

    #if os(macOS)
    /// Settings as a floating top-right panel (under the gear). The map's
    /// click-off tap closes it; panel clicks land on the panel itself.
    private var settingsPanel: some View {
        VStack {
            HStack {
                Spacer()
                SettingsSheet()
                    .frame(width: golden.sidePanel)
                    .frame(maxHeight: golden.size.height / Theme.phi)
                    .background(Theme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius,
                                                style: .continuous))
                    .shadow(color: Theme.cardShadow, radius: 18, y: 6)
            }
            Spacer()
        }
        // One pad below the gear, same trailing inset — the top-right column.
        .padding(.top, golden.pad * 2 + golden.iconCircle)
        .padding(.trailing, golden.pad)
    }
    #endif

    /// Corridor hazard areas as REAL ZIP boundaries: risky corridor samples
    /// resolve to their containing ZCTA rings (fetched once per highlighted
    /// route, cached by the fetcher) — the map shows the actual affected ZIP,
    /// not an 18 km circle. Samples whose ZIP hasn't resolved keep the circle
    /// as a fallback.
    struct CorridorHazardArea: Identifiable {
        let id: String
        let ring: [CLLocationCoordinate2D]
        let kind: HazardKind
    }
    @State private var corridorAreas: [CorridorHazardArea] = []
    @State private var corridorAreaRouteID: UUID?
    @State private var corridorBadges: [BadgeClustering.Item<HazardKind>] = []

    private func rebuildCorridorAreas(for route: PlannedRoute) async {
        // Index space = the FILTERED list, matching the renderer's enumeration.
        let risky = route.riskSamples.filter { $0.risk >= model.riskDisplayFloor }
        var areas: [CorridorHazardArea] = []
        var seenCodes: Set<String> = []
        for sample in risky.prefix(20) {
            guard let z = await ZCTAFetcher.shared.zcta(containing: sample.coordinate)
            else { continue }
            guard seenCodes.insert(z.code).inserted else { continue }
            areas.append(CorridorHazardArea(
                id: z.code, ring: z.ring, kind: corridorKind(sample)))
        }
        corridorAreas = areas
        // Badge clustering moved OFF the render path: computed once per route
        // change here instead of inside mapContent on every frame.
        corridorBadges = BadgeClustering.cluster(
            risky.map { BadgeClustering.Item(coordinate: $0.coordinate,
                                             kind: corridorKind($0), score: $0.risk) },
            minSeparationMeters: 80_000)
        corridorAreaRouteID = route.id
    }

    /// Shoelace (area-weighted) polygon centroid — the true center of the SHAPE,
    /// not the vertex mean. Census ZCTA rings put dense vertex runs on wiggly
    /// borders (rivers), which dragged the vertex-mean toward them and left
    /// badges visibly off-center of their contiguous ZIP. Falls back to the
    /// vertex mean for degenerate (near-zero-area) rings.
    private static func centroid(of ring: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        guard !ring.isEmpty else { return CLLocationCoordinate2D() }
        var area = 0.0, cx = 0.0, cy = 0.0
        for i in 0..<ring.count {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let cross = a.longitude * b.latitude - b.longitude * a.latitude
            area += cross
            cx += (a.longitude + b.longitude) * cross
            cy += (a.latitude + b.latitude) * cross
        }
        if abs(area) > 1e-12 {
            return CLLocationCoordinate2D(latitude: cy / (3 * area),
                                          longitude: cx / (3 * area))
        }
        let lat = ring.map(\.latitude).reduce(0, +) / Double(ring.count)
        let lon = ring.map(\.longitude).reduce(0, +) / Double(ring.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// GRADE-tinted elevation ribbon: a casing under the route colored by our
    /// EPQS grade table — flat = green, moderate = yellow, steep = orange,
    /// severe = red. MapKit's base mesh is NOT app-deformable (it comes from
    /// Apple's own DEM), so instead of "bending the map" this DRAPES our own
    /// elevation-change data onto it — the honest way to show relief we know in
    /// detail. Shown with the steep-grade % markers when 3D terrain is on.
    @MapContentBuilder
    private func gradeRibbon(_ route: PlannedRoute) -> some MapContent {
        // Slices are precomputed at grade hydration
        // (RouteService.gradeDisplayGeometry) — slicing the full polyline per
        // segment HERE ran ~100 whole-polyline walks per frame.
        ForEach(Array(route.gradeRibbonSlices.enumerated()), id: \.offset) { _, s in
            MapPolyline(coordinates: s.coords)
                .stroke(Self.gradeColor(s.gradePercent),
                        style: StrokeStyle(lineWidth: 11, lineCap: .round))
        }
    }

    /// Hypsometric-style ramp for road STEEPNESS (|grade|): the flatter the
    /// greener, the steeper the redder.
    nonisolated private static func gradeColor(_ percent: Double) -> Color {
        switch abs(percent) {
        case ..<2: return Color.green.opacity(0.5)
        case ..<4: return Color(red: 0.6, green: 0.8, blue: 0.2).opacity(0.55)
        case ..<6: return Color.yellow.opacity(0.6)
        case ..<9: return Color.orange.opacity(0.7)
        default: return Color.red.opacity(0.8)
        }
    }

    /// STEEP-GRADE markers along the active route when 3D terrain is on: our
    /// EPQS grade table knows exact road steepness that MapKit's terrain mesh
    /// only hints at — ≥6% stretches get an angled badge with the real number
    /// at the stretch's midpoint. (MapKit's mesh itself isn't deformable.)
    /// Midpoints are precomputed at grade hydration — resolving each against
    /// the full polyline here re-walked it per marker per frame.
    @MapContentBuilder
    private func steepGradeMarkers(_ route: PlannedRoute) -> some MapContent {
        ForEach(Array(route.steepMarkers.enumerated()), id: \.offset) { _, m in
            Annotation("", coordinate: m.coordinate) {
                Label(String(format: "%.0f%%", abs(m.gradePercent)),
                      systemImage: m.gradePercent > 0
                        ? "arrow.up.right" : "arrow.down.right")
                    .scaledFont(size: 10, weight: .heavy)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(abs(m.gradePercent) >= 9
                                ? Theme.riskRed : Color.orange)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .shadow(radius: 2)
            }
        }
    }

    /// A route drawn as risk-band-colored corridor segments once its weather
    /// has hydrated; a single band-colored stroke before that.
    @MapContentBuilder
    private func riskStrokedRoute(_ route: PlannedRoute) -> some MapContent {
        // No full-length white casing underlay: MapKit does not guarantee
        // stable z-order between sibling polylines across content updates,
        // and the casing intermittently re-stacked ON TOP of the colored
        // segments — the "route flashes to white" bug. Round line caps give
        // the segments enough contrast on their own.
        if route.weatherScored && !route.riskSegments.isEmpty {
            // Continuous full-geometry understroke: at far zoom the separate
            // segment polylines could expose straight-line seams — the
            // same-color base line beneath them hides any artifact.
            MapPolyline(route.route.polyline)
                .stroke(route.riskBand.color.opacity(0.9), lineWidth: 5)
            ForEach(route.riskSegments) { seg in
                MapPolyline(coordinates: seg.coordinates)
                    .stroke(FlowsCore.riskBand(score: seg.risk).color,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round))
            }
        } else {
            MapPolyline(route.route.polyline)
                .stroke(route.riskBand.color, lineWidth: 7)
        }
    }

    private func firstCoordinate(of route: PlannedRoute) -> CLLocationCoordinate2D? {
        let poly = route.route.polyline
        guard poly.pointCount > 0 else { return nil }
        var c = CLLocationCoordinate2D()
        poly.getCoordinates(&c, range: NSRange(location: 0, length: 1))
        return c
    }

    @ViewBuilder
    private var chromeLayer: some View {
        switch model.mode {
        case .planning, .choosing:
            PlanningChrome(isCompact: isCompact, camera: $camera)
        case .navigating:
            NavigationHUD(isCompact: isCompact)
        }
    }

}

/// Planning-mode chrome: planner card + route choices, placed per platform.
/// While choosing, the planner collapses to a compact trip pill so the map
/// and the route list get the space.

/// First-launch vehicle prompt: range tracking needs to know the truck.
///
/// A standalone view because it is stacked directly above the planner in
/// BOTH layouts — a nag card has no business covering the road ahead, and
/// letting the planner's own stack place it beats guessing a bottom padding
/// that lands mid-map on a tablet.
private struct VehicleOnboardingCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.golden) private var golden

    private var blurb: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Add your vehicle")
                .scaledFont(size: 14, weight: .bold)
            Text("Track range from mpg + tank size + how you drive, and "
                 + "get fuel stops before you need them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var addButton: some View {
        Button("Add vehicle") { model.showVehicleEditor = true }
            .scaledFont(size: 13, weight: .heavy)
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(Theme.cta)
            .foregroundStyle(Theme.onCTA)
            .clipShape(Capsule())
    }

    private var dismiss: some View {
        Button { model.vehicleOnboardingDismissed = true } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss the vehicle prompt")
    }

    var body: some View {
        // One row where there is room, two where there isn't. Sharing the
        // planner's column on a tablet is narrower than the full width this
        // card used to get at the top, and four things abreast in that
        // column wrapped "Add your / vehicle" down the middle.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Image(systemName: "car.fill").scaledFont(size: 20)
                blurb
                addButton
                dismiss
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "car.fill").scaledFont(size: 20)
                    blurb
                    Spacer(minLength: 0)
                    dismiss
                }
                addButton.frame(maxWidth: .infinity)
            }
        }
        .floatingCard()
    }
}

private struct PlanningChrome: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.golden) private var golden
    let isCompact: Bool
    @Binding var camera: MapCameraPosition

    var body: some View {
        if isCompact {
            VStack {
                HStack { Spacer(); SettingsGear() }   // gear top-right
                // EVERYTHING ELSE HANGS FROM THE BOTTOM. The top of a phone
                // screen is the most valuable map there is — it is the road
                // ahead — so no card is allowed to sit up there and the
                // whole choosing stack drops to the thumb end, the same way
                // the planner always has.
                Spacer()
                if model.mode == .choosing {
                    TripSummaryPill()
                    FilterSlidersCard()
                    // Enough for a whole route card, and no more: the map
                    // above still has to show the route being chosen.
                    RouteChoicesView(camera: $camera)
                        .frame(maxHeight: golden.choicesPanelHeight)
                } else {
                    if model.needsVehicleOnboarding { VehicleOnboardingCard() }
                    PlannerPanel(camera: $camera)     // planner bottom-center
                }
            }
            .padding(golden.pad)
        } else {
            ZStack {
                // Gear pinned top-right.
                VStack {
                    HStack { Spacer(); SettingsGear() }
                    Spacer()
                }
                if model.mode == .choosing {
                    HStack(alignment: .top) {
                        RouteChoicesView(camera: $camera)
                            .frame(width: golden.sidePanel)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 10) {
                            TripSummaryPill()
                            FilterSlidersCard()
                        }
                        .frame(width: golden.sideColumn)
                        .padding(.top, golden.topClear)   // clear of the gear
                    }
                } else {
                    // Planner bottom-center, with the vehicle nag stacked
                    // directly above it rather than floating on a
                    // phone-tuned padding that lands mid-map on a tablet.
                    VStack {
                        Spacer()
                        if model.needsVehicleOnboarding {
                            VehicleOnboardingCard()
                                .frame(width: golden.sidePanel)
                        }
                        PlannerPanel(camera: $camera)
                            .frame(width: golden.sidePanel)
                    }
                }
            }
            .padding(golden.pad)
        }
    }
}

/// Right-hand sliders that appear with the Low bridges / Mountain grades /
/// Bridge weight filters: set YOUR vehicle's height, comfortable max grade,
/// and the weights the bridge-weight check compares against.
struct FilterSlidersCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.golden) private var golden
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private let isCompact = false
    #endif

    var body: some View {
        // A map click hides the card (click-off dismiss); touching any
        // filter brings it back.
        if !model.filterCardsHidden,
           model.routeFilters.contains(.lowBridges) || model.routeFilters.contains(.mountainGrades)
            || model.routeFilters.contains(.bridgeWeight) {
            // Compact layouts span the window width (240 pt reads as a side
            // panel only next to a desktop map) and scroll when all three
            // filter sections are open — stacked above the route list they
            // pushed it off a phone screen.
            ScrollWhenTight {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Vehicle limits")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    // X = minimize into the round limits icon at the top right.
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            _ = model.collapsedPanels.insert("sliders")
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Tuck the limits card away")
                }
                if model.routeFilters.contains(.lowBridges) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Vehicle height: %d'%d\"",
                                    Int(model.vehicleHeightFeet),
                                    Int((model.vehicleHeightFeet - Double(Int(model.vehicleHeightFeet))) * 12)))
                            .font(.caption.weight(.semibold))
                        Slider(value: $model.vehicleHeightFeet,
                               in: VehicleSpecs.minimumHeightFeet...16, step: 0.25)
                        // Spell out the effect: height + 2 ft margin.
                        Text(String(format: "Avoiding posted clearances of %.0f'%.0f\" "
                                    + "or lower (your height + 2 ft margin).",
                                    (model.vehicleHeightFeet + 2).rounded(.down),
                                    ((model.vehicleHeightFeet + 2)
                                     - (model.vehicleHeightFeet + 2).rounded(.down)) * 12))
                            .scaledFont(size: 9)
                            .foregroundStyle(.secondary)
                    }
                }
                if model.routeFilters.contains(.mountainGrades) {
                    VStack(alignment: .leading, spacing: 2) {
                        // Degrees, the unit a driver towing heavy thinks in —
                        // 14° ≈ a 25% grade. Percent shown for the data-minded.
                        Text(String(format: "Max grade: %.1f° (%.0f%%)", model.maxGradeDegrees,
                                    FilterLimits.degreesToPercent(model.maxGradeDegrees)))
                            .font(.caption.weight(.semibold))
                        Slider(value: $model.maxGradeDegrees, in: 2...15, step: 0.5)
                        Text("USGS elevation profile must stay under this incline.")
                            .scaledFont(size: 9)
                            .foregroundStyle(.secondary)
                    }
                }
                if model.routeFilters.contains(.bridgeWeight) {
                    VStack(alignment: .leading, spacing: 2) {
                        // The SAME weights the towing card uses — change
                        // either place and both follow.
                        HStack {
                            Text(model.towVehicleWeightLbs > 0
                                 ? String(format: "Vehicle weight: %.0f lb", model.towVehicleWeightLbs)
                                 : "Vehicle weight: not set (no roads excluded)")
                                .font(.caption.weight(.semibold))
                            if model.towVehicleWeightLbs > 0 {
                                Button("Clear") { model.towVehicleWeightLbs = 0 }
                                    .font(.caption2)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.blue)
                            }
                        }
                        Slider(value: $model.towVehicleWeightLbs, in: 2000...40000, step: 100)
                        Text(String(format: "Towing weight: %.0f lb", model.towTrailerWeightLbs))
                            .font(.caption.weight(.semibold))
                        Slider(value: $model.towTrailerWeightLbs, in: 0...45000, step: 100)
                        // Spell out the effect: the whole rig vs posted limits.
                        if let rig = model.filterLimits.rigWeightLbs {
                            Text(String(format: "Avoiding roads and bridges with "
                                        + "weight signs under %.0f lb "
                                        + "(your vehicle + what you tow).", rig))
                                .scaledFont(size: 9)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Set your weights so routes can be checked "
                                 + "against posted weight signs.")
                                .scaledFont(size: 9)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                // Per-route verdicts against YOUR limits — moving a slider
                // shows its effect here immediately, and excluded routes
                // drop from the list.
                Divider()
                ForEach(model.routeChoices.prefix(4)) { r in
                    routeVerdictRow(r)
                }
            }
            .padding(golden.padCard)
            }
            .collapsibleMenu("sliders")
            .frame(maxWidth: isCompact ? .infinity : golden.sideColumn)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Theme.cardShadow, radius: 8, y: 3)
        }
    }
}

extension FilterSlidersCard {
    /// "I-90 E · 2.1° ✓ · 16'4" ✓" — measured attributes vs current limits.
    @ViewBuilder
    fileprivate func routeVerdictRow(_ r: PlannedRoute) -> some View {
        let limits = model.filterLimits
        HStack(spacing: 4) {
            Text(r.via.isEmpty ? "Route" : r.via)
                .scaledFont(size: 9, weight: .semibold)
                .lineLimit(1)
            Spacer()
            if model.routeFilters.contains(.mountainGrades) {
                if let g = r.maxGradePercent {
                    let deg = atan(g / 100) * 180 / .pi
                    Label(String(format: "%.1f°", deg),
                          systemImage: limits.passesGrade(g)
                              ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .scaledFont(size: 9, weight: .bold)
                        .foregroundStyle(limits.passesGrade(g) ? Theme.riskGreen : Theme.riskRed)
                } else {
                    Text("grade…").scaledFont(size: 9).foregroundStyle(.secondary)
                }
            }
            if model.routeFilters.contains(.lowBridges) {
                if let cl = r.clearancesMeters {
                    let worst = cl.min()
                    let passes = limits.passesClearances(cl)
                    Label(worst.map { w -> String in
                        let ft = w / 0.3048
                        return String(format: "%d'%d\"", Int(ft), Int((ft - Double(Int(ft))) * 12))
                    } ?? "no low posts",
                          systemImage: passes ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .scaledFont(size: 9, weight: .bold)
                        .foregroundStyle(passes ? Theme.riskGreen : Theme.riskRed)
                } else {
                    Text("bridges…").scaledFont(size: 9).foregroundStyle(.secondary)
                }
            }
            if model.routeFilters.contains(.bridgeWeight) {
                if limits.rigWeightLbs == nil {
                    // No entered weight → nothing honest to check against.
                    Text("set weight").scaledFont(size: 9).foregroundStyle(.secondary)
                } else if let wl = r.weightLimitsLbs {
                    let passes = limits.passesWeightLimits(wl)
                    Label(wl.min().map { String(format: "%.0f lb", $0) } ?? "no weight signs",
                          systemImage: passes ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .scaledFont(size: 9, weight: .bold)
                        .foregroundStyle(passes ? Theme.riskGreen : Theme.riskRed)
                } else {
                    Text("weight…").scaledFont(size: 9).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The settings gear — fuel type preference and future app settings.
struct SettingsGear: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.golden) private var golden

    var body: some View {
        Button {
            model.showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                // Both sides improved this: golden sizing AND Dynamic Type.
                // scaledFont takes a size, so they compose — a hardcoded 36pt
                // circle becomes golden, and the glyph still grows with the
                // driver's text-size setting.
                .scaledFont(size: golden.iconCircle * 0.4, weight: .semibold)
                .frame(width: golden.iconCircle, height: golden.iconCircle)
                .background(Theme.cardBackground)
                .clipShape(Circle())
                .shadow(color: Theme.cardShadow, radius: 8, y: 3)
        }
        .accessibilityLabel("Settings")
        .buttonStyle(.plain)
        .help("Settings")
    }
}

/// The tucked-menu tray: a small round icon per menu the driver collapsed
/// with its grab bar, pinned top-right under the gear and compass. Tapping
/// an icon brings that menu back.
struct CollapsedPanelTray: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.golden) private var golden

    struct PanelBadge: Identifiable {
        let id: String
        let symbol: String
        let name: String
    }

    /// Every menu that tucks into the tray: id → symbol + plain name.
    /// (Cards that already have their own bar button — radio, music,
    /// towing — minimize back into that button instead.)
    static let panels: [PanelBadge] = [
        PanelBadge(id: "planner", symbol: "magnifyingglass", name: "Trip planner"),
        PanelBadge(id: "routes", symbol: "arrow.triangle.turn.up.right.circle",
                   name: "Route choices"),
        PanelBadge(id: "sliders", symbol: "slider.horizontal.3", name: "Vehicle limits"),
        PanelBadge(id: "legend", symbol: "list.bullet.rectangle", name: "Map key"),
        PanelBadge(id: "fuel", symbol: "gauge.with.dots.needle.bottom.50percent",
                   name: "Driving instruments"),
    ]

    var body: some View {
        let tucked = Self.panels.filter { model.collapsedPanels.contains($0.id) }
        VStack(spacing: 8) {
            ForEach(tucked) { panel in
                badgeButton(panel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        // Stacked right under the gear, one pad apart, in the same
        // top-right column — no dead gap. While navigating the gear lives
        // in the bottom bar, so the tray takes the corner itself.
        // Clear of whatever owns the top-right: the instruction banner
        // while driving, the settings gear while planning.
        .padding(.top, model.mode == .navigating
                 ? golden.topClear * 3
                 : golden.pad * 2 + golden.iconCircle)
        .padding(.trailing, golden.pad)
    }

    private func badgeButton(_ panel: PanelBadge) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                _ = model.collapsedPanels.remove(panel.id)
            }
        } label: {
            Image(systemName: panel.symbol)
                .font(.system(size: golden.iconCircle * 0.4, weight: .semibold))
                .frame(width: golden.iconCircle, height: golden.iconCircle)
                .background(Theme.cardBackground)
                .clipShape(Circle())
                .shadow(color: Theme.cardShadow, radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .help("Show \(panel.name)")
    }
}

/// Fuel preference + app settings. The fuel type chosen here (or at the
/// first Gas press) is remembered and used for every future Gas request.
/// First launch: ONE plain-words message covering every permission —
/// what's asked now (location, the only one basic use needs) and what
/// waits until its feature is first used. iOS never allows a single
/// combined system dialog, so this card is the single explanation and
/// the later prompts arrive one at a time, each already expected.
struct WelcomeCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Label("Welcome to FLOWS", systemImage: "cloud.sun.fill")
                    .scaledFont(size: 18, weight: .bold)
                Text("One permission runs the whole app: your location. It "
                     + "powers navigation, the weather-risk map around you, "
                     + "and stops ahead. The phone asks right after this.")
                    .font(.callout)
                Text("Nothing else is asked up front — each of these asks "
                     + "only the first time you use it:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                permissionRow("dot.radiowaves.right",
                              "Bluetooth — when you turn on the tire-sensor "
                              + "link in Settings")
                permissionRow("music.note",
                              "Music library — the first time you press play")
                permissionRow("mic.fill",
                              "Microphone and speech — the first time you "
                              + "answer FLOWS by voice")
                Button {
                    model.completeOnboarding()
                } label: {
                    Text("Get started")
                        .scaledFont(size: 15, weight: .bold)
                        .frame(maxWidth: .infinity, minHeight: Theme.tapMinimum)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.cta)
            }
            .padding(20)
            .frame(maxWidth: 440)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Theme.cardShadow, radius: 18, y: 6)
            .padding(24)
        }
    }

    private func permissionRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .scaledFont(size: 12, weight: .semibold)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(text).font(.caption)
        }
    }
}

struct SettingsSheet: View {
    /// Body shape for the map marker — "Match my vehicle" reads it from the
    /// make, model and weight already on file.
    private var vehicleShapePicker: some View {
        Picker("Shape", selection: Binding(
            get: { model.vehicleShapeOverride },
            set: { model.vehicleShapeOverride = $0 })) {
            Text("Match my vehicle").tag(VehicleShape?.none)
            ForEach(VehicleShape.allCases) { shape in
                Text(shape.title).tag(VehicleShape?.some(shape))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private var vehicleColorRow: some View {
        HStack(spacing: 8) {
            ForEach(AppModel.vehicleColorChoices, id: \.self) { name in
                let chosen = model.vehicleColorName == name
                Button { model.vehicleColorName = name } label: {
                    Circle()
                        .fill(ContentView.markerColor(name))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(chosen ? Color.primary : Color.clear,
                                                 lineWidth: 2.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(name) vehicle marker")
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @State private var showDemoGallery = false
    @State private var showContactPicker = false
    /// Seeds the text-size slider at the phone's current setting until the
    /// driver moves it (already clamped by the root modifier).
    @Environment(\.dynamicTypeSize) private var systemTypeSize
    /// Recent diagnostic-journal lines for the health log section.
    @State private var healthLines: [String] = []
    /// Shown after the driver erases what the app has learned.
    @State private var erasedConfirmation = false

    /// One "label … value" line in the learned-about-you section.
    private func learnedRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
    }

    /// Camera height in the units a driver thinks in.
    private func zoomLabel(_ meters: Double) -> String {
        let feet = meters / 0.3048
        return feet < 2_000
            ? String(format: "%.0f ft up", feet)
            : String(format: "%.1f mi up", meters / 1609.344)
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Settings")
                    .scaledFont(size: 17, weight: .bold)
                Spacer()
                Button("Done") { model.showSettings = false }
                    .buttonStyle(PillCTAStyle())
                    .frame(width: 90)
            }
            Text("Fuel type")
                .scaledFont(size: 14, weight: .semibold)
            Picker("Fuel type", selection: Binding(
                get: { model.poi.fuelType },
                set: { model.poi.fuelType = $0 })) {
                Text("Not set").tag(FuelType?.none)
                ForEach(FuelType.allCases) { fuel in
                    Label(fuel.rawValue, systemImage: fuel.symbol).tag(FuelType?.some(fuel))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Text("Used to pick which stations Gas searches for and how they're "
                 + "ranked (fill cost + detour time). Station-level prices need a "
                 + "licensed feed — until then stations rank by detour time.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Text("Music")
                .scaledFont(size: 14, weight: .semibold)
            Picker("Music app", selection: $model.musicProvider) {
                ForEach(MusicProvider.allCases) { provider in
                    Label(provider.displayName, systemImage: provider.symbol)
                        .tag(provider)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(Theme.riskGreen)
            Text("The little player in the drive bar uses this app. Play, "
                 + "pause, and skip work right in FLOWS with Apple Music — "
                 + "and with Spotify when a Spotify token is set under Data "
                 + "sources. No other music service lets outside apps "
                 + "control it, so the rest open in their own app. The same "
                 + "rule drives the Siri and CarPlay buttons.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Text("Emergency radio on the map")
                .font(.system(size: 14, weight: .semibold))
            if model.scanner.available {
                Toggle("Show calls heard nearby", isOn: Binding(
                    get: { model.scanner.enabled },
                    set: { model.scanner.enabled = $0 }))
                    .font(.caption)
                Text("Local dispatch is transcribed ON THIS PHONE — the audio "
                     + "is never uploaded, saved, or played. Calls show as "
                     + "small pins near you and along your route, and fade "
                     + "out on their own. Heard on a radio, so treat them as "
                     + "a heads-up, not a fact.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let status = model.scanner.status {
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("No feed list is set up on this device, so there is "
                     + "nothing to listen to. Feeds come from whoever holds "
                     + "the listening agreement — drop a scanner_feeds.json "
                     + "into the app's Application Support folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Text("Your vehicle on the map")
                .font(.system(size: 14, weight: .semibold))
            vehicleShapePicker
            vehicleColorRow
            Text("The marker is drawn from the angle the camera is looking "
                 + "from — the roof flat on the map, the back when following "
                 + "behind. Shape starts from the vehicle you entered.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Text("Screen light")
                .font(.system(size: 14, weight: .semibold))
            Picker("Screen light", selection: Binding(
                get: { model.appearanceOverride },
                set: { model.appearanceOverride = $0 })) {
                Text("Follow the sun").tag(Bool?.none)
                Text("Always light").tag(Bool?.some(false))
                Text("Always dark").tag(Bool?.some(true))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.appearanceOverride == nil
                 ? "Bright by day and dark by night, on the sunset and sunrise "
                   + "where you are — not on a set hour. Dusk in Miami in June "
                   + "and dusk in Fairbanks in December are hours apart."
                 : "Pinned. Pick \"Follow the sun\" to have it change on its own "
                   + "at dusk and dawn.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Text("Vehicle limits")
                .scaledFont(size: 14, weight: .semibold)
            HStack {
                Text(String(format: "Height %.0f'%.0f\"", model.vehicleHeightFeet.rounded(.down),
                            (model.vehicleHeightFeet - model.vehicleHeightFeet.rounded(.down)) * 12))
                    .font(.caption)
                    .frame(width: 90, alignment: .leading)
                Slider(value: $model.vehicleHeightFeet,
                       in: VehicleSpecs.minimumHeightFeet...16, step: 0.25)
            }
            HStack {
                Text(String(format: "Max grade %.1f°", model.maxGradeDegrees))
                    .font(.caption)
                    .frame(width: 90, alignment: .leading)
                Slider(value: $model.maxGradeDegrees, in: 2...15, step: 0.5)
            }
            HStack(spacing: 8) {
                Text("Preset from your vehicle — the slope where you'd really "
                     + "want the parking brake. Towing or a heavy rig lowers it. "
                     + "Move the slider to pick your own.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Use my vehicle's number") {
                    model.applyVehicleMaxGradeDefault(force: true)
                }
                .buttonStyle(.plain)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.blue)
                .fixedSize()
            }

            Divider()
            Text("Notifications")
                .scaledFont(size: 14, weight: .semibold)
            Toggle(isOn: $model.notifyImminent) {
                Text("Imminent weather + emergency broadcasts").font(.caption)
            }
            Toggle(isOn: $model.notifyEscalation) {
                Text("Rising-risk reroute prompts").font(.caption)
            }
            Toggle(isOn: $model.notifyTraffic) {
                Text("Traffic delay chips").font(.caption)
            }
            Toggle(isOn: $model.voiceAlerts) {
                Text("Speak alerts and faster-route offers out loud "
                     + "(answer with a plain yes or no)").font(.caption)
            }
            Toggle(isOn: $model.speakTurns) {
                Text("Turn-by-turn voice directions").font(.caption)
            }
            Toggle(isOn: $model.notifyFuel) {
                Text("Fuel range reminders + refuel check-ins").font(.caption)
            }
            Toggle(isOn: $model.crashDetectionEnabled) {
                Text("Crash detection (iPhone: impact → voice check-in)").font(.caption)
            }
            Toggle(isOn: $model.radioAutoSwitch) {
                Text("Trucker radio auto-retunes to the nearest station").font(.caption)
            }
            Toggle(isOn: $model.refuelCheckInsEnabled) {
                Text("Refuel gauge check-ins (train range prediction to 80%+)").font(.caption)
            }

            Divider()
            Text("Text size")
                .scaledFont(size: 14, weight: .semibold)
            HStack(spacing: 10) {
                Text("A").scaledFont(size: 12, weight: .semibold)
                Slider(
                    value: Binding(
                        get: {
                            Double(model.textSizeIndex >= 0
                                ? min(model.textSizeIndex, model.textSizeMaxIndex)
                                : min(TextScale.index(of: systemTypeSize),
                                      model.textSizeMaxIndex))
                        },
                        set: { model.textSizeIndex = Int($0.rounded()) }),
                    in: 0...Double(max(model.textSizeMaxIndex, 1)),
                    step: 1)
                    .accessibilityLabel("Text size")
                Text("A").scaledFont(size: 22, weight: .semibold)
            }
            if model.textSizeIndex >= 0 {
                Button("Match the phone's text size") { model.textSizeIndex = -1 }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .font(.caption.weight(.bold))
            }
            Text("Bigger or smaller words, your pick. The top end is capped "
                 + "to this screen's size, so words never warp or fall off "
                 + "the edge. Until you move the slider, FLOWS follows the "
                 + "phone's own text-size setting.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()
            Text("Accessibility")
                .scaledFont(size: 14, weight: .semibold)
            Toggle(isOn: $model.wordFindingHelp) {
                Text("Word-finding help (on-device)").font(.caption)
            }
            Text("When FLOWS can't make out an answer, the phone's own "
                 + "on-device helper matches your words to the choices — "
                 + "\"the one with the tacos\" finds Taco Bell. Nothing you "
                 + "say leaves the phone. Needs a phone with Apple "
                 + "Intelligence; off or unsupported, FLOWS just asks again.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Toggle(isOn: $model.personalVoiceAnnouncements) {
                Text("Speak with your Personal Voice").font(.caption)
            }
            Text("If you've made a Personal Voice (phone Settings → "
                 + "Accessibility → Personal Voice), FLOWS can speak its "
                 + "alerts and directions with it. The phone asks once for "
                 + "permission.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Toggle(isOn: $model.hapticAlerts) {
                Text("Vibration tap with every spoken alert").font(.caption)
            }
            Text("A felt tap lands with each alert and faster-route offer — "
                 + "for drivers who can't hear the voice, the tap IS the "
                 + "announcement, and the banner carries the words.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("More help from the phone itself: Vocal Shortcuts (phone "
                 + "Settings → Accessibility) can trigger any FLOWS Siri "
                 + "command with any sound you can make — built for speech "
                 + "impediments. Type to Siri types those same commands. "
                 + "Live Speech can speak a typed reply out loud when FLOWS "
                 + "asks a question.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button {
                showDemoGallery = true
            } label: {
                Label("Preview alerts & notifications", systemImage: "eye")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)

            Divider()
            Text("Emergency")
                .scaledFont(size: 14, weight: .semibold)
            HStack(spacing: 8) {
                TextField("Contact name", text: $model.emergencyContactName)
                    .textFieldStyle(.roundedBorder)
                TextField("Contact phone", text: $model.emergencyContactPhone)
                    .textFieldStyle(.roundedBorder)
                #if os(iOS)
                // iOS never exposes Medical ID contacts to apps — the
                // Contacts picker is the sanctioned import path.
                Button { showContactPicker = true } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                #endif
            }
            TextField("Medical notes for responders (allergies, conditions)",
                      text: $model.medicalNotes)
                .textFieldStyle(.roundedBorder)
            Text("After a detected crash FLOWS asks aloud if you need help and "
                 + "keeps asking until you answer or dismiss. On yes: one-tap "
                 + "911 (iOS never lets apps dial silently), a prefilled report "
                 + "text to your contact (GPS, address, time, vehicle, notes), "
                 + "then a call to them. Apple Health Medical ID is not "
                 + "readable by apps — notes here ride the report instead.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Toggle(isOn: $model.truckerUI) {
                Label("Trucker mode", systemImage: "truck.box.fill")
                    .scaledFont(size: 14, weight: .semibold)
            }
            Text("Trucker route designation on the choices screen, plus showers, "
                 + "legal truck parking, truck-friendly motels, and "
                 + "diesel-by-cost. The drive-bar radio works for everyone — "
                 + "this just renames it trucker radio.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Text("Vehicle")
                .scaledFont(size: 14, weight: .semibold)
            HStack(spacing: 8) {
                if let v = model.vehicle.profile {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(v.displayName.isEmpty ? "My vehicle" : v.displayName)
                            .font(.caption.weight(.semibold))
                        Text(String(format: "%.0f %@ tank · %.0f mi/%@ · range ~%.0f mi",
                                    v.tankCapacityUnits,
                                    v.fuelType == .electric ? "kWh" : "gal",
                                    v.ratedMilesPerUnit,
                                    v.fuelType == .electric ? "kWh" : "gal",
                                    model.vehicle.expectedRangeMiles ?? v.ratedRangeMiles))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No vehicle on file — add one for range tracking + fuel timing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.vehicle.profile == nil ? "Add vehicle" : "Edit") {
                    model.showSettings = false
                    model.showVehicleEditor = true
                }
                .font(.caption.weight(.bold))
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }

            Divider()
            Text("Map zoom while driving")
                .font(.system(size: 14, weight: .semibold))
            Picker("Map zoom", selection: $model.cameraZoomMode) {
                ForEach(AppModel.CameraZoomMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            if model.cameraZoomMode == .manual {
                HStack {
                    Text(zoomLabel(model.manualZoomMeters))
                        .font(.caption)
                        .frame(width: 90, alignment: .leading)
                    // Log scale: the useful range spans street level to
                    // continent, and a linear slider spends most of its
                    // travel in the far end nobody drives at.
                    Slider(value: Binding(
                        get: { log10(model.manualZoomMeters) },
                        set: { model.manualZoomMeters = pow(10, $0) }),
                        in: log10(150)...log10(200_000))
                }
            }
            Text("Automatic follows the road: close together in town where "
                 + "turns come fast, farther out on a highway between exits, "
                 + "and tight on the turn itself. Walking always stays close. "
                 + "Flying stays far until the airport. Pick another option to "
                 + "hold one view — handy for seeing the walking and flying "
                 + "views without walking or flying.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Toggle(isOn: $model.show3DMap) {
                Label("3D terrain", systemImage: "mountain.2.fill")
                    .scaledFont(size: 14, weight: .semibold)
            }
            Text("Drapes a grade-colored elevation ribbon on the route (from our EPQS road-elevation data) and pitches the camera deeper. Apple's base terrain isn't app-editable, so relief is shown through the ribbon + grade markers, not by bending the map.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()
            Text("Trip needs")
                .scaledFont(size: 14, weight: .semibold)
            Toggle(isOn: $model.tripNeedsEnabled) {
                Text("Schedule recurring stops")
                    .font(.caption)
            }
            if model.tripNeedsEnabled {
                HStack {
                    Text(String(format: "Rest every %.0f min", model.tripRestMinutes))
                        .font(.caption)
                        .frame(width: 130, alignment: .leading)
                    Slider(value: $model.tripRestMinutes, in: 60...240, step: 15)
                }
                HStack {
                    Text(String(format: "Food every %.0f h", model.tripFoodMinutes / 60))
                        .font(.caption)
                        .frame(width: 130, alignment: .leading)
                    Slider(value: $model.tripFoodMinutes, in: 90...360, step: 30)
                }
                HStack {
                    Text(model.derivedFuelIntervalMiles.map {
                        String(format: "Fuel every ~%.0f mi", $0)
                    } ?? "Fuel: add a vehicle")
                        .font(.caption)
                        .frame(width: 130, alignment: .leading)
                    if model.vehicle.profile != nil {
                        Slider(value: Binding(
                            get: { model.tripFuelMilesOverride
                                ?? model.derivedFuelIntervalMiles ?? 300 },
                            set: { model.tripFuelMilesOverride = $0 }),
                            in: 50...1200, step: 25)
                    }
                }
            }
            Text("Defaults from published guidance: NHTSA/AAA — break every "
                 + "~2 h or 100 mi (drowsy-driving prevention); FMCSA "
                 + "hours-of-service — 30-min break by hour 8 (meal cadence "
                 + "3.5 h keeps you ahead of it). Fuel derives from YOUR "
                 + "vehicle: 75% of habit-adjusted range. All editable here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Text("Favorites")
                .scaledFont(size: 14, weight: .semibold)
            if model.favorites.favorites.isEmpty {
                Text("Star a destination in the planner to save it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.favorites.favorites) { fav in
                HStack(spacing: 8) {
                    Image(systemName: fav.symbol.systemImage)
                        .foregroundStyle(.secondary)
                    Text(fav.name).font(.caption)
                    Spacer()
                    Button {
                        model.favorites.remove(fav)
                    } label: {
                        Image(systemName: "trash").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }

            Divider()
            Text("Data sources")
                .scaledFont(size: 14, weight: .semibold)
            TextField("Google Places API key (free monthly quota: console.cloud.google.com) — stars + $",
                      text: $model.googlePlacesAPIKey)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            HStack(spacing: 6) {
                TextField("Yelp Places API key (30-day free trial, then paid) — stars + $",
                          text: $model.yelpAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Menu {
                    Text("How to get a Yelp key:")
                    Text("1. Open business.yelp.com/data/products/places-api")
                    Text("2. Start the free 30-day trial (5,000 calls)")
                    Text("3. Create an app to get your API key")
                    Text("4. Paste the key here")
                    Divider()
                    Link("Open the Yelp API page",
                         destination: URL(string: "https://business.yelp.com/data/products/places-api/")!)
                } label: {
                    Text("Get one")
                        .font(.caption.weight(.semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            TextField("TomTom API key (free tier: developer.tomtom.com) — live gas prices",
                      text: $model.tomtomAPIKey)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            Text("With a key, hotels/food show review stars (yellow→gold) and "
                 + "$ tiers (income-anchored: $ = minimum-wage affordable, "
                 + "$$$$$ = top 1–3%). Without one, stars/$ stay hidden.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("Spotify token (optional) — play/pause/skip Spotify in FLOWS",
                          text: $model.spotifyWebToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Menu {
                    Text("How to get a Spotify token:")
                    Text("1. Open developer.spotify.com (free account)")
                    Text("2. Create an app in the developer dashboard")
                    Text("3. Make an access token with the playback-state permissions")
                    Text("4. Paste the token here")
                    Divider()
                    Link("Open the Spotify developer page",
                         destination: URL(string: "https://developer.spotify.com/documentation/web-api")!)
                } label: {
                    Text("Get one")
                        .font(.caption.weight(.semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Text("With a token, Spotify play, pause, and skip work right in "
                 + "FLOWS (needs Spotify Premium; a token expires after about "
                 + "an hour). It is kept in the device's locked Keychain. "
                 + "Without one, FLOWS opens the Spotify app instead.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()
            Text("Connected vehicle (cloud — Smartcar)")
                .scaledFont(size: 14, weight: .semibold)
            HStack(spacing: 8) {
                TextField("Client ID", text: Binding(
                    get: { model.smartcar.clientID },
                    set: { model.smartcar.clientID = $0 }))
                    .textFieldStyle(.roundedBorder)
                TextField("Client Secret", text: Binding(
                    get: { model.smartcar.clientSecret },
                    set: { model.smartcar.clientSecret = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                if model.smartcar.connected {
                    Button("Refresh data") { Task { await model.smartcar.refreshData() } }
                        .buttonStyle(.plain).foregroundStyle(.blue).font(.caption.weight(.bold))
                    Button("Disconnect") { model.smartcar.disconnect() }
                        .buttonStyle(.plain).foregroundStyle(.red).font(.caption.weight(.bold))
                } else if let url = model.smartcar.connectURL {
                    Link("Connect vehicle →", destination: url)
                        .font(.caption.weight(.bold))
                }
                Spacer()
                Text(model.smartcar.status).font(.caption2).foregroundStyle(.secondary)
            }
            Text("dashboard.smartcar.com → create app → redirect URI "
                 + "flows://smartcar → paste ID + Secret → Connect. Real fuel "
                 + "level and tire pressure then override the odometer model.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()
            Text("Vehicle link (Bluetooth)")
                .scaledFont(size: 14, weight: .semibold)
            Toggle(isOn: Binding(
                get: { model.vehicleLink.scanning },
                set: {
                    model.vehicleLink.scanning = $0
                    // Persisted: scanning resumes on later launches only if
                    // the driver chose it (first turn-on shows the system's
                    // one-time Bluetooth permission ask).
                    UserDefaults.standard.set($0, forKey: "flows.vehicleLinkScanning")
                })) {
                Text("Listen for TPMS caps + OBD-II adapters").font(.caption)
            }
            Text(model.vehicleLink.status).font(.caption2).foregroundStyle(.secondary)
            if !model.vehicleLink.tirePressuresPsi.isEmpty {
                Text(model.vehicleLink.tirePressuresPsi
                    .sorted { $0.key < $1.key }
                    .map { String(format: "%@ %.0f psi", $0.key, $0.value) }
                    .joined(separator: " · "))
                    .font(.caption.monospacedDigit())
            }
            Text("BLE valve-cap TPMS kits broadcast pressures directly; ELM327 "
                 + "OBD adapters (OBDLink/Veepeak) supply real fuel level "
                 + "(SAE PID 2F).")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()
            Text("Data sources & refresh")
                .scaledFont(size: 14, weight: .semibold)
            Text("Weather alerts: NWS api.weather.gov — live, re-checked every "
                 + "4 min while driving. Risk field: FLOWS 20-year NOAA Storm "
                 + "Events climatology baseline. "
                 + "Elevation/grades: USGS EPQS, fetched per plan, cached. Low "
                 + "bridges: OpenStreetMap maxheight via Overpass, per plan. "
                 + "Floodplain: FEMA NFHL zones, per plan. "
                 + "Unknown data never excludes a route.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // The risk map's vintage. The text above used to point at a
            // "generated time in Map Filter" that nothing ever displayed —
            // the value was published and never read. A stale climatology is
            // worth knowing about, so it says so here.
            if let generated = model.riskField.generatedUTC {
                Text("Risk field generated \(generated).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Text("Your everyday area")
                .scaledFont(size: 14, weight: .semibold)
            Text(String(format: "Stops you use often within ~%.0f miles of "
                 + "home are remembered on this device for instant results. "
                 + "The area is learned from your trips and "
                 + "never leaves your phone.",
                 EverydayPlaces.shared.radiusMiles))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Text("Attribution & licenses")
                .scaledFont(size: 14, weight: .semibold)
            Text("Maps, routing, search and traffic: Apple Maps — "
                 + "© Apple Inc. and its data providers. The Apple logo and "
                 + "Legal link on the map are required by Apple's terms and "
                 + "cannot be removed by an app; tapping Legal there opens "
                 + "Apple's full notices.\n"
                 + "Places (fuel, food, lodging, medical, transit): Foursquare "
                 + "Open Source Places, © Foursquare Labs, Inc., licensed under "
                 + "Apache License 2.0.\n"
                 + "Low-bridge clearances, weight limits, posted speed limits "
                 + "and lane guidance: © OpenStreetMap contributors, available "
                 + "under the Open Database License (ODbL) — "
                 + "openstreetmap.org/copyright.\n"
                 + "Government feeds (NWS, USGS, FEMA, SPC, NOAA, Census TIGER, "
                 + "EPA, DOT WZDx, ECCC, SMN) are public-domain or open government "
                 + "data. FLOWS is not affiliated with any of these agencies.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Divider()

            // WHAT FLOWS HAS LEARNED — the driver can see everything the app
            // has inferred about them, and erase it in one press. Learning
            // about someone without showing them what you learned, or
            // letting them take it back, isn't a feature.
            DisclosureGroup("What FLOWS has learned about you") {
                let summary = SeasonalRiskModel.shared.learningSummary
                VStack(alignment: .leading, spacing: 4) {
                    Text("All of this is stored on this device only, encrypted "
                         + "with a key that never leaves it. None of it is sent anywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    learnedRow("Trips remembered", "\(summary.trips)")
                    learnedRow("Routes recognized", "\(summary.routes)")
                    learnedRow("Everyday area",
                               String(format: "%.0f mi", EverydayPlaces.shared.radiusMiles))
                    learnedRow("Places remembered", "\(EverydayPlaces.shared.allPlaces.count)")
                    learnedRow("Destinations kept", "\(model.recents.entries.count)")
                    learnedRow("Choices recorded", "\(ChoiceLogStore.shared.eventCount)")
                    learnedRow("Your pace", DrivingProfileStore.shared.profile.etaDescription)
                    if let cal = summary.calibration {
                        learnedRow("Risk prediction error",
                                   String(format: "%.3f typical", cal))
                    }
                    if summary.tuned {
                        Text("The risk model has been fine-tuned on your own trips.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        SeasonalRiskModel.shared.eraseLearnedHistory()
                        EverydayPlaces.shared.erase()
                        model.recents.erase()
                        ChoiceLogStore.shared.erase()
                        DrivingProfileStore.shared.erase()
                        // Where the driver has actually BEEN. These four were
                        // missing: the breadcrumb trail, the saved offline
                        // corridors, and the two learned models are all
                        // location history, and none of them was reached by
                        // this button — nor helped by destroying the key,
                        // since all four were written as plaintext.
                        model.breadcrumbs.erase()
                        model.corridors.erase()
                        model.trafficModel.erase()
                        model.roadEfficiency.erase()
                        // Last: drop the key. Each store shreds its own
                        // plaintext above, but until the key goes with it an
                        // escaped ciphertext is still readable — and this
                        // button promises the app is "back to knowing
                        // nothing".
                        SecureBehaviorStore.destroyKey()
                        erasedConfirmation = true
                    } label: {
                        Label("Erase everything FLOWS has learned",
                              systemImage: "trash")
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.top, 4)
                    if erasedConfirmation {
                        Text("Erased. The app is back to knowing nothing about your travel.")
                            .font(.caption)
                            .foregroundStyle(Theme.riskGreen)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scaledFont(size: 13, weight: .semibold)

            Divider()

            // App health log: the rotating diagnostic journal's recent
            // lines — which backup source kicked in, which feed was down —
            // so a field report can carry the app's own account.
            DisclosureGroup("App health log") {
                ScrollView {
                    Text(healthLines.isEmpty
                         ? "No problems recorded — every weather and road source is answering."
                         : healthLines.joined(separator: "\n"))
                        .scaledFont(size: 9, design: .monospaced)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 150)
                HStack(spacing: 12) {
                    Button("Copy log") {
                        let text = healthLines.joined(separator: "\n")
                        #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        #else
                        UIPasteboard.general.string = text
                        #endif
                    }
                    .font(.caption)
                    // The visible tail is a preview; a trip review wants
                    // the WHOLE journal, so the files themselves ship out.
                    ShareLink(items: FlowsDiag.shared.fileURLs) {
                        Text("Send full log").font(.caption)
                    }
                }
                Text("After a drive, send the full log to have the music "
                     + "handoffs, learned buffer times, and any feed "
                     + "problems reviewed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .scaledFont(size: 13, weight: .semibold)
            .task { healthLines = await FlowsDiag.shared.recent(120) }
        }
        .padding(20)
        }
        // Panel-sizing floors are for the macOS floating panel — on an
        // iPhone sheet a 480 pt floor pushed the scroll area past a
        // landscape window's edge.
        #if os(macOS)
        .frame(minWidth: 340, minHeight: 480)
        #endif
        .sheet(isPresented: $showDemoGallery) {
            DemoAlertsView()
                .environmentObject(model)
        }
        // A sheet is presented into its own environment root and does
        // NOT inherit the presenter's appearance — say it again here or
        // settings opens bright white in a dark cab.
        .presentationColorScheme(model.resolvedColorScheme)
        #if os(iOS)
        .sheet(isPresented: $showContactPicker) {
            ContactPicker { name, phone in
                model.emergencyContactName = name
                model.emergencyContactPhone = phone
            }
        }
        // A sheet is presented into its own environment root and does
        // NOT inherit the presenter's appearance — say it again here or
        // settings opens bright white in a dark cab.
        .presentationColorScheme(model.resolvedColorScheme)
        #endif
    }
}

/// "30809 → 53203 · Edit" — what the planner becomes once routes are shown.
private struct TripSummaryPill: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                .foregroundStyle(Theme.cta)
            Text(tripText)
                .scaledFont(size: 13, weight: .semibold)
                .lineLimit(1)
            Button("Edit") {
                model.routeChoices = []
                model.highlightedRouteID = nil
                // Walking is a per-choice mode, not a persistent setting:
                // leaving it set made the NEXT plan silently request a
                // pedestrian route (which can fail at driving distances),
                // leaving the planner stuck "on walking" with no routes.
                model.walkingMode = false
                model.mode = .planning
            }
            .scaledFont(size: 13, weight: .bold)
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .background(Theme.cardBackground)
        .clipShape(Capsule())
        .shadow(color: Theme.cardShadow, radius: 8, y: 3)
    }

    private var tripText: String {
        let src = model.routeChoices.first?.sourceName ?? model.plannerSource
        let dst = model.routeChoices.first?.destinationName ?? model.plannerDestination
        return "\(src) → \(dst)"
    }
}

/// The web app's legend-shell, compact: what the route/band colors and
/// weather blotches mean. Hidden while navigating (driver knows by then),
/// and shown ONLY while the map owns most of the window (see
/// ContentView.legendHasRoom). All sizes are golden fractions of the window.
private struct LegendCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.golden) private var golden
    /// Phones pin the legend TOP-LEFT — the planner and choices panels own
    /// the bottom, and the legend must never sit under them. Regular
    /// layouts keep it bottom-left like the web app.
    var isCompact = false

    /// Which free corner the legend snaps to. Regular layouts keep the web
    /// app's bottom-left. Compact planning: the planner owns the bottom, so
    /// top-left. Compact choosing (legend shows only once the routes panel
    /// is tucked): the trip pill owns the top center, so bottom-left.
    private var anchorsBottom: Bool {
        !isCompact || model.mode == .choosing
    }

    var body: some View {
        // Corner-snapped: the SAME inset from both edges of its corner —
        // corner elements never float an uneven distance from the two edges.
        VStack {
            if anchorsBottom { Spacer() }
            HStack {
                legendBox
                Spacer()
            }
            .padding(.leading, golden.pad)
            .padding(anchorsBottom ? .bottom : .top, golden.pad)
            if !anchorsBottom { Spacer() }
        }
    }

    /// The key itself: everything but the X is BACKGROUND (map taps pass
    /// straight through), so the button is overlaid rather than nested —
    /// hit testing disabled on a parent can't be re-enabled by a child.
    private var legendBox: some View {
        legendContent
            .allowsHitTesting(false)
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        _ = model.collapsedPanels.insert("legend")
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        // A fingertip target around the small glyph.
                        .frame(width: Theme.tapMinimum, height: Theme.tapMinimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Tuck the key away")
            }
    }

    private var legendContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Risk")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            // Continuous gradient — risk is a 0…1 scale, not four
            // discrete buckets.
            VStack(alignment: .leading, spacing: 2) {
                LinearGradient(
                    stops: [
                        .init(color: .blue, location: 0),
                        .init(color: Theme.riskGreen.opacity(0.15), location: 0.0),
                        .init(color: Theme.riskGreen, location: 0.40),
                        .init(color: Theme.riskYellow, location: 0.70),
                        .init(color: Theme.riskRed, location: 0.92),
                    ],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(width: golden.legendDrawWidth, height: 8)
                    .clipShape(Capsule())
                HStack {
                    Text("Clear").scaledFont(size: 8)
                    Spacer()
                    Text("Severe").scaledFont(size: 8)
                }
                .frame(width: golden.legendDrawWidth)
                .foregroundStyle(.secondary)
            }
            // A colour ramp says nothing to a screen reader, and nothing to
            // a driver who can't separate the hues — so the scale is stated
            // in words too. (Carried across the merge: the extracted,
            // minimizable legend structure came from one branch and this
            // accessibility from the other; dropping either would be a
            // regression.)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Risk scale")
            .accessibilityValue("Runs from clear, through green for "
                                + "normal and yellow for elevated, to "
                                + "red for severe.")
            if model.showWeatherLayer && model.riskField.loaded {
                Text("Hazards")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 4)],
                          alignment: .leading, spacing: 3) {
                    ForEach(HazardStyle.legendKinds, id: \.self) { kind in
                        HStack(spacing: 3) {
                            Image(systemName: kind.symbol)
                                .scaledFont(size: 9, weight: .bold)
                                .foregroundStyle(kind.color)
                                .frame(width: 12)
                            Text(kind.name).scaledFont(size: 9)
                        }
                        // Icon + name are one idea; read them as one.
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(width: golden.legendDrawWidth)
            }
        }
        // The key hugs its own content — without a width the header's
        // spacer would stretch the whole card across the window.
        .frame(width: golden.legendDrawWidth)
        .padding(golden.padCard)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 8, y: 3)
    }
}

struct VehicleEditorSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private static let customMake = "Custom"

    @State private var make = VehicleEditorSheet.customMake
    @State private var specModel = ""
    @State private var fuelType: FuelType = .gas
    @State private var tankUnits: Double = 15
    @State private var milesPerUnit: Double = 28
    @State private var heightFeet: Double = 5.0
    // EPA everything-path state.
    @State private var vehicleYear = ""
    @State private var useEPADatabase = true   // all makes/models by default
    @State private var epaYears: [String] = []
    @State private var epaYear = "2025"
    @State private var epaMakes: [String] = []
    @State private var epaMake = ""
    @State private var epaModels: [String] = []
    @State private var epaModel = ""
    /// Auto-filled values collapse behind this until asked for.
    @State private var fineTune = false
    /// City/highway split carried through to the saved profile.
    @State private var citySplit: (city: Double, highway: Double)?
    /// EPA class-typical ratings staged for save.
    @State private var pendingEPARatings: (gvwr: Double?, towCap: Double?)?

    var body: some View {
        // iOS sheets can be shorter than the form (landscape), so the form
        // always rides a ScrollView there — a fits/scrolls swap mid-edit
        // would rebuild the form and reset its fields. macOS keeps the
        // fixed panel (its sheet sizes to the content).
        #if os(iOS)
        ScrollView { editorForm }
        #else
        editorForm
            .frame(minWidth: 420)
        #endif
    }

    private var editorForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.vehicle.profile == nil ? "Add vehicle" : "Edit vehicle")
                    .scaledFont(size: 17, weight: .bold)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
            }
            // Year → make → model IS the whole ask: those three answers
            // fill everything else (economy, fuel, tank, height, tow
            // ratings) from the EPA database + class-typical specs. The
            // sliders live under Fine-tune for trim differences; hand
            // entry is the no-internet/can't-find-it fallback.
            Text(useEPADatabase
                 ? "Pick the year, make, and model — FLOWS fills in the rest."
                 : "Enter your vehicle by hand.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if useEPADatabase {
                epaPickers
            } else {
            // Make → model, filtered from the curated table.
            HStack(spacing: 8) {
                Picker("Make", selection: $make) {
                    ForEach(VehicleSpecs.makes, id: \.self) { Text($0).tag($0) }
                    Text(Self.customMake).tag(Self.customMake)
                }
                .labelsHidden()
                .onChange(of: make) { _, newMake in
                    if let first = VehicleSpecs.models(make: newMake).first {
                        specModel = first.model
                        apply(first)
                    } else {
                        specModel = ""
                    }
                }
                if make == Self.customMake {
                    TextField("Year (e.g. 2022)", text: $vehicleYear)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
                if make != Self.customMake {
                    Picker("Model", selection: $specModel) {
                        ForEach(VehicleSpecs.models(make: make)) { spec in
                            Text(spec.model).tag(spec.model)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: specModel) { _, newModel in
                        if let spec = VehicleSpecs.spec(make: make, model: newModel) {
                            apply(spec)
                        }
                    }
                }
            }
            if make != Self.customMake, VehicleSpecs.spec(make: make, model: specModel) != nil {
                Text("Filled from the vehicle table (manufacturer-typical specs — "
                     + "adjust below if your trim differs).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            }

            Button(useEPADatabase
                   ? "No internet, or can't find it? Enter it by hand"
                   : "Pick from every US vehicle since 1984 instead") {
                useEPADatabase.toggle()
                if !useEPADatabase { fineTune = true }
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.blue)

            // Auto-filled values stay out of the way until asked for —
            // the pop-up is three pickers, not a wall of sliders.
            DisclosureGroup(isExpanded: $fineTune) {
                VStack(alignment: .leading, spacing: 12) {
            Picker("Fuel", selection: $fuelType) {
                ForEach(FuelType.allCases) { fuel in
                    Label(fuel.rawValue, systemImage: fuel.symbol).tag(fuel)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Text(String(format: "Tank: %.0f %@", tankUnits,
                            fuelType == .electric ? "kWh" : "gal"))
                    .font(.caption)
                    .frame(width: 120, alignment: .leading)
                Slider(value: $tankUnits, in: fuelType == .electric ? 20...250 : 5...300, step: 1)
            }
            HStack {
                Text(String(format: "Economy: %.1f mi/%@", milesPerUnit,
                            fuelType == .electric ? "kWh" : "gal"))
                    .font(.caption)
                    .frame(width: 120, alignment: .leading)
                Slider(value: $milesPerUnit, in: fuelType == .electric ? 1...6 : 4...60,
                       step: fuelType == .electric ? 0.1 : 0.5)
            }
            HStack {
                Text(String(format: "Height: %.1f ft", heightFeet))
                    .font(.caption)
                    .frame(width: 120, alignment: .leading)
                Slider(value: $heightFeet, in: VehicleSpecs.minimumHeightFeet...14, step: 0.1)
            }
                }
                .padding(.top, 6)
            } label: {
                Text("Fine-tune for your exact trim")
                    .font(.caption.weight(.semibold))
            }
            .onAppear {
                // Editing an existing vehicle (or entering by hand): the
                // numbers ARE the point — show them.
                if model.vehicle.profile != nil || !useEPADatabase {
                    fineTune = true
                }
            }
            Text(String(format: "Rated range ~%.0f mi. Height feeds the low-bridge "
                        + "filter automatically; on the road FLOWS adjusts range for "
                        + "how you drive and recommends fuel stops early.",
                        tankUnits * milesPerUnit))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if model.vehicle.profile != nil {
                    Button("Mark tank full") { model.vehicle.filledUp() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                        .font(.caption.weight(.bold))
                }
                Spacer()
                Button("Save vehicle") {
                    let isSpec = make != Self.customMake
                    var profile = VehicleProfile(
                        make: isSpec ? make : "Custom",
                        model: isSpec ? specModel : "vehicle",
                        year: vehicleYear.isEmpty ? nil : vehicleYear,
                        fuelType: fuelType,
                        tankCapacityUnits: tankUnits, ratedMilesPerUnit: milesPerUnit)
                    // Keep the city/highway split (speed-aware predictions);
                    // manual slider tweaks scale both figures proportionally.
                    if let split = citySplit {
                        let combined = 1 / (0.55 / split.city + 0.45 / split.highway)
                        let f = combined > 0 ? milesPerUnit / combined : 1
                        profile.cityMilesPerUnit = (split.city * f * 10).rounded() / 10
                        profile.highwayMilesPerUnit = (split.highway * f * 10).rounded() / 10
                    }
                    // Ratings ride the profile: curated spec first, EPA
                    // class-typical otherwise — GVWR/tow alerts always work.
                    if let spec = VehicleSpecs.spec(make: make, model: specModel) {
                        profile.gvwrLbs = spec.gvwrLbs
                        profile.towCapacityLbs = spec.towCapacityLbs
                        profile.gcwrLbs = spec.gcwrLbs
                    } else if let ratings = pendingEPARatings {
                        profile.gvwrLbs = ratings.gvwr
                        profile.towCapacityLbs = ratings.towCap
                    }
                    model.vehicle.profile = profile
                    // The vehicle's height IS the route-planning height.
                    model.vehicleHeightFeet = (heightFeet * 4).rounded() / 4
                    // Big rigs get the trucker UI automatically: RVs, box
                    // trucks, semis, buses, cutaways — anything ≥ 9 ft tall.
                    let bigWords = ["semi", "box truck", "motorhome", "bus",
                                    "cutaway", "rv"]
                    if heightFeet >= 9
                        || bigWords.contains(where: { specModel.lowercased().contains($0) }) {
                        model.truckerUI = true
                    }
                    model.poi.fuelType = fuelType   // gas searches follow the vehicle
                    dismiss()
                }
                .buttonStyle(PillCTAStyle())
                .frame(width: 160)
            }
        }
        .padding(20)
        .onAppear {
            if let v = model.vehicle.profile {
                vehicleYear = v.year ?? ""
                if VehicleSpecs.spec(make: v.make, model: v.model) != nil {
                    make = v.make
                    specModel = v.model
                } else {
                    make = Self.customMake
                }
                fuelType = v.fuelType
                tankUnits = v.tankCapacityUnits
                milesPerUnit = v.ratedMilesPerUnit
                heightFeet = model.vehicleHeightFeet
            } else if let first = VehicleSpecs.makes.first,
                      let spec = VehicleSpecs.models(make: first).first {
                make = first
                specModel = spec.model
                apply(spec)
            }
        }
    }

    private func apply(_ spec: VehicleSpec) {
        fuelType = spec.fuelType
        tankUnits = spec.tankUnits
        milesPerUnit = (spec.combinedMPU * 10).rounded() / 10
        heightFeet = spec.heightFeet
        citySplit = (spec.cityMPU, spec.highwayMPU)
    }

    // MARK: EPA everything-path (live year/make/model menus)

    @ViewBuilder
    private var epaPickers: some View {
        HStack(spacing: 8) {
            Picker("Year", selection: $epaYear) {
                ForEach(epaYears, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .onChange(of: epaYear) { _, y in
                vehicleYear = y
                Task {
                    let makes = await EPAVehicleDatabase.shared.makes(year: y)
                    // Commit only if this fetch still matches the picker (two
                    // quick changes race; the slower stale one must lose).
                    guard y == epaYear else { return }
                    epaMakes = makes
                    let make = makes.contains(epaMake) ? epaMake : (makes.first ?? "")
                    // Refetch models even when the make NAME is unchanged —
                    // onChange won't fire for an equal value, and make lists
                    // are near-identical across years, so 2024's models would
                    // silently stand in for 2025's (applyEPA then keeps the
                    // previous vehicle's specs behind a new label).
                    if make == epaMake {
                        let models = await EPAVehicleDatabase.shared.models(year: y, make: make)
                        guard y == epaYear, make == epaMake else { return }
                        epaModels = models
                        epaModel = models.first ?? ""
                    } else {
                        epaMake = make
                    }
                }
            }
            Picker("Make", selection: $epaMake) {
                ForEach(epaMakes, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .onChange(of: epaMake) { _, m in
                Task {
                    let models = await EPAVehicleDatabase.shared.models(year: epaYear, make: m)
                    guard m == epaMake else { return }   // superseded by a newer tap
                    epaModels = models
                    epaModel = models.first ?? ""
                }
            }
            Picker("Model", selection: $epaModel) {
                ForEach(epaModels, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .onChange(of: epaModel) { _, mo in
                Task { await applyEPA(model: mo) }
            }
        }
        .task {
            if epaYears.isEmpty {
                epaYears = await EPAVehicleDatabase.shared.years()
                epaYear = epaYears.first ?? "2025"
                epaMakes = await EPAVehicleDatabase.shared.makes(year: epaYear)
                epaMake = epaMakes.first ?? ""
            }
        }
        if !epaModel.isEmpty {
            // The proof the three answers were enough: everything that got
            // filled in, on one line.
            Text(String(format: "Filled in: %@ · %.0f %@ tank · %.1f mi/%@ "
                        + "· %.1f ft tall%@",
                        fuelType.rawValue, tankUnits,
                        fuelType == .electric ? "kWh" : "gal",
                        milesPerUnit, fuelType == .electric ? "kWh" : "gal",
                        heightFeet,
                        pendingEPARatings?.gvwr != nil ? " · tow ratings" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func applyEPA(model modelName: String) async {
        guard let details = await EPAVehicleDatabase.shared.details(
            year: epaYear, make: epaMake, model: modelName) else { return }
        let physical = EPAClassSpecs.physical(forVClass: details.vClass)
        pendingEPARatings = (physical.gvwr, physical.towCap)
        citySplit = (details.cityMPU, details.highwayMPU)
        fuelType = details.fuelType
        let combined = 1 / (0.55 / details.cityMPU + 0.45 / details.highwayMPU)
        // Keep the validatedTank clamp — a small car must not inherit a van-size
        // tank implying >650 mi of range. The prior code immediately overwrote it
        // with the raw physical.tank, making the clamp dead code (and letting the
        // absurd EPA-EV range through, since MPGe is stored here as mi/unit).
        tankUnits = EPAClassSpecs.validatedTank(physical.tank, combinedMPU: combined)
        milesPerUnit = (combined * 10).rounded() / 10
        heightFeet = physical.height
        make = epaMake
        specModel = modelName
    }
}

/// The crash check-in / assisted-emergency card. Persistent: it re-asks by
/// voice until answered and only a PHYSICAL press dismisses it.
struct CrashCheckInCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.golden) private var golden

    var body: some View {
        // Anchoring belongs to the shared bottom slot — this only says what
        // the card IS.
        VStack(alignment: .leading, spacing: 10) {
            Group {
                Label("Possible crash detected", systemImage: "car.side.rear.and.collision.and.car.side.front")
                    .scaledFont(size: 17, weight: .heavy)
                if case .checkingIn(let attempt) = model.crash.state {
                    Text("Do you need assistance? Say “yes” or “I'm okay” — "
                         + "or use the buttons. FLOWS keeps asking (attempt \(attempt)) "
                         + "until you respond.")
                        .font(.footnote)
                    HStack(spacing: 10) {
                        Button("I'm OK") { model.crash.standDown() }
                            .scaledFont(size: 15, weight: .bold)
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, minHeight: Theme.tapMinimum)
                            .background(Color.white.opacity(0.25))
                            .clipShape(Capsule())
                        Button("Get help") { model.crash.requestAssistance() }
                            .scaledFont(size: 15, weight: .heavy)
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, minHeight: Theme.tapMinimum)
                            .background(Color.white)
                            .foregroundStyle(Theme.riskRed)
                            .clipShape(Capsule())
                    }
                } else {
                    #if os(iOS)
                    Text("Step 1 — call 911 (one tap; the report below is read "
                         + "aloud so you can relay it). Step 2 — send the report "
                         + "to \(model.emergencyContactName.isEmpty ? "your contact" : model.emergencyContactName). "
                         + "Step 3 — call them.")
                        .font(.footnote)
                    HStack(spacing: 8) {
                        Button("Call 911") { model.crash.call911() }
                            .scaledFont(size: 15, weight: .heavy)
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, minHeight: Theme.tapMinimum)
                            .background(Color.white)
                            .foregroundStyle(Theme.riskRed)
                            .clipShape(Capsule())
                        if !model.emergencyContactPhone.isEmpty {
                            Button("Text report") {
                                model.crash.messageContact(number: model.emergencyContactPhone)
                            }
                            .scaledFont(size: 15, weight: .bold)
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, minHeight: Theme.tapMinimum)
                            .background(Color.white.opacity(0.25))
                            .clipShape(Capsule())
                            Button("Call contact") {
                                model.crash.callContact(number: model.emergencyContactPhone)
                            }
                            .scaledFont(size: 15, weight: .bold)
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, minHeight: Theme.tapMinimum)
                            .background(Color.white.opacity(0.25))
                            .clipShape(Capsule())
                        }
                    }
                    ScrollView {
                        Text(model.crash.emergencyReport())
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                    #endif
                    Button("Done — dismiss") { model.crash.standDown() }
                        .scaledFont(size: 14, weight: .bold)
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(Color.white.opacity(0.25))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(golden.padCard)
        .frame(maxWidth: golden.cardMax)
        .background(Theme.riskRed.opacity(0.97))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 18, y: 6)
    }
}
