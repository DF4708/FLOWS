// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation
import MapKit

/// One corridor sample with its local weather risk (0…1).
struct RiskSample: Sendable {
    let coordinate: CLLocationCoordinate2D
    let risk: Double
    /// Worst active alert event at this sample's cell (drives corridor
    /// hazard symbology even for zone alerts with no polygon geometry).
    var worstEvent: String? = nil
    /// Id of that alert — joins the sample back to its official summary and
    /// source URL for the imminent-alert banner.
    var alertID: String? = nil
}

/// A stretch of route between two adjacent corridor samples, carrying the
/// worse of its endpoints' risks — the unit the map strokes in band colors.
struct RiskSegment: Identifiable {
    let id = UUID()
    let coordinates: [CLLocationCoordinate2D]
    let risk: Double
    let lengthMeters: Double
}

/// Which planning strategy produced a route — the app's analog of the web
/// router's fastest/safest/metro profile triad. "Safest" is not a request
/// kind (Apple can't know weather); it's the risk ranking after hydration.
enum RoutePlanKind {
    case standard        // default MKDirections + alternates
    case avoidHighways   // the "local roads / metro" profile
    case tollFree        // requested with tollPreference = .avoid
}

/// A planned route: Apple's traffic-aware MKRoute plus the FLOWS weather-risk
/// score layered on top.
struct PlannedRoute: Identifiable {
    let id = UUID()
    let route: MKRoute
    let sourceName: String
    let destinationName: String
    var planKind: RoutePlanKind = .standard
    /// 0…1 normalized FLOWS corridor risk (noisy-OR of severity×coverage —
    /// same combination shape as the web app's environmental normalization).
    /// Hydrated asynchronously after the routes are already on screen —
    /// `weatherScored` flips when the corridor score has landed.
    var weatherRisk: Double = 0
    /// Fraction of corridor samples inside any active alert.
    var alertCoverage: Double = 0
    var alertHeadlines: [String] = []
    var alertEvents: [String] = []
    var alertPolygons: [WeatherAlertService.AlertPolygon] = []
    var weatherScored = false
    /// Per-sample corridor risk + map-drawable segments, filled at hydration.
    /// Sample/segment risk is the noisy-OR blend of alert severity AND the
    /// R engine's continuous ZIP environmental field (RiskFieldService), so
    /// the route is colored physically where the risk is — like the web
    /// app's road overlay inheriting ZIP risk.
    var riskSamples: [RiskSample] = []
    var riskSegments: [RiskSegment] = []
    /// R-parity route summary numbers (route_pathfind.R build_route_summary):
    /// peak/avg corridor risk and exposure miles per band.
    var peakRisk: Double = 0
    var avgRisk: Double = 0
    /// Sustained exposure to IDENTIFIED ZIP risk along the corridor (the R
    /// engine's modeled field + the on-device seasonal prior) — the "second
    /// truth" alongside realized alerts. Not the safety band; a ranking input.
    var zipExposure: Double = 0
    /// Ranking score (NOT the display band): balances the realized-risk band
    /// (`weatherRisk`, alert/current-driven) with `zipExposure` (identified/
    /// historical). Two green routes are ordered by the identified risk of the
    /// ZIPs they cross. See FLOWSModel.rankingRisk.
    var rankingRisk: Double = 0
    var milesByBand: [(band: RiskBand, miles: Double)] = []
    /// Hazard summaries of the riskiest ZIPs crossed (risk_type_summary_text
    /// — the "summary_reason" analog under each route).
    var hazardSummaries: [String] = []
    /// Peak per-family field scores along the corridor (wind, qpf_flood, …)
    /// — powers the hazard-specific route filters.
    var familyPeaks: [String: Double] = [:]
    /// Physical attributes from public data (RouteAttributes) — hydrated
    /// async like the weather; nil = unknown (never excludes a route).
    var maxGradePercent: Double?
    /// The route's GRADE TABLE: per-segment grades at mile positions
    /// (coarse pass + fine refinement) — localized steepness, inspectable
    /// on the card and consulted for the steep-hill chip while driving.
    var gradeProfile: [GradeSegment] = []
    /// All posted clearances (meters) found near the corridor below ~5.5 m —
    /// compared against the driver's vehicle-height slider.
    var clearancesMeters: [Double]?
    /// All posted weight limits (pounds) found on the corridor, from the
    /// same Overpass sweep — compared against the driver's vehicle + towing
    /// weight for the Bridge weight filter.
    var weightLimitsLbs: [Double]?
    /// True when EVERY Overpass endpoint failed (clearances and weight
    /// limits ride one query) — the card says "no OSM data" instead of
    /// spinning on "checking…" forever.
    var clearanceDataUnavailable = false
    /// Fraction of sampled corridor points inside FEMA A*/V* flood zones.
    var femaFloodFraction: Double?
    /// ELECTRIC vehicles: mile mark of the first stretch with NO charger in
    /// reach (nil = chargers found along the whole route, or not an EV).
    var evChargingGapMiles: Double?
    /// Flips when the physical-attribute pass (grades / clearances / FEMA /
    /// EV gaps) has run. Attributes hydrate SEPARATELY from the weather
    /// verdict — Overpass/EPQS latency must not hold the GO gate hostage —
    /// so a leg can start weather-scored but attribute-pending.
    var attributesScored = false

    /// Congestion proxy: traffic-aware ETA vs a free-flow baseline for the
    /// road class. > ~1.35 means the corridor commonly crawls. (Real per-road
    /// congestion history needs data Apple doesn't expose; documented approx.)
    var congestionRatio: Double {
        let freeFlowSpeed = hasHighways ? 29.0 : 17.0   // m/s ≈ 65 / 38 mph
        let freeFlow = distanceMeters / freeFlowSpeed
        return freeFlow > 0 ? eta / freeFlow : 1
    }

    /// A LONG-DISTANCE WALKING plan beyond Apple's pedestrian-router range:
    /// geometry follows local roads (avoid-highways) and the ETA is computed
    /// at walking pace — honest routing information instead of "too far".
    var isWalkingEstimate = false
    var etaOverride: TimeInterval?
    var eta: TimeInterval { etaOverride ?? route.expectedTravelTime }   // traffic-aware unless overridden
    var distanceMeters: Double { route.distance }
    var riskBand: RiskBand { FlowsCore.riskBand(score: weatherRisk) }
    /// Apple's route descriptor, e.g. "I-90 E" — the "via …" line on cards.
    var via: String { route.name }
    var hasTolls: Bool { route.hasTolls }
    var hasHighways: Bool { route.hasHighways }

    /// Fraction of corridor samples per band — the card's stacked risk strip.
    /// Samples are uniformly spaced, so count-fractions ≈ distance-fractions.
    var riskFractions: [(band: RiskBand, fraction: Double)] {
        guard !riskSamples.isEmpty else { return [] }
        var counts: [RiskBand: Int] = [:]
        for s in riskSamples { counts[FlowsCore.riskBand(score: s.risk), default: 0] += 1 }
        let n = Double(riskSamples.count)
        return [RiskBand.clear, .green, .yellow, .red].compactMap { band in
            guard let c = counts[band], c > 0 else { return nil }
            return (band, Double(c) / n)
        }
    }
}

/// Route filters for the choices screen.
///   * noTolls additionally triggers a toll-free REPLAN (MKDirections
///     tollPreference = .avoid) so satisfying routes exist instead of the
///     filter collapsing the list to local roads.
///   * bridgeWeight / lowBridges / mountainGrades / noFloodRisk are backed
///     by real public data (OSM maxweight/maxheight, USGS elevations, FEMA
///     flood zones + live field + active alerts); unknown data never
///     excludes a route.
///   ("Low weather risk" used to live here as a relative best-plus-near-ties
///   filter — removed as redundant with the map's and cards' risk colors.)
enum RouteFilter: String, CaseIterable, Identifiable {
    case noTolls = "No tolls"
    case noHighways = "No highways"
    case bridgeWeight = "Bridge weight"
    case noHighWinds = "No high winds"
    case noFloodRisk = "No flood risk"
    case avoidTraffic = "Avoid traffic"
    case lowBridges = "Low bridges"
    case mountainGrades = "Mountain grades"
    case tourist = "Tourist stops"
    // ("Trucker" is NOT a filter — it's a dedicated route designation; see
    // AppModel.truckerRouteID.)

    var id: String { rawValue }

    func passes(_ route: PlannedRoute, limits: FilterLimits = FilterLimits()) -> Bool {
        switch self {
        case .noTolls:
            return !route.hasTolls
        case .noHighways:
            // Trust the actual highway flag, not the planKind PREFERENCE:
            // MKDirections' avoid-highways is a bias, so an .avoidHighways route
            // can still dip onto a freeway connector. A vehicle that legally
            // cannot use highways (oversize/hazmat) needs the real "no highways"
            // guarantee — if this empties the list, the closest-match fallback
            // surfaces the least-violating route rather than a false pass.
            return !route.hasHighways
        case .bridgeWeight:
            // Every posted weight limit on the corridor must take the rig's
            // total weight (vehicle + towed). Unknown data never excludes.
            return limits.passesWeightLimits(route.weightLimitsLbs)
        case .noHighWinds:
            return !route.weatherScored
                || (route.familyPeaks["wind"] ?? 0) < FlowsCore.riskYellowMin
        case .noFloodRisk:
            // Live field + active alerts + FEMA regulatory floodplain.
            guard route.weatherScored else { return true }
            let liveOK = (route.familyPeaks["qpf_flood"] ?? 0) < FlowsCore.riskYellowMin
            let alertOK = !route.alertEvents.contains { $0.localizedCaseInsensitiveContains("flood") }
            let femaOK = (route.femaFloodFraction ?? 0) < 0.15
            return liveOK && alertOK && femaOK
        case .avoidTraffic:
            return route.congestionRatio < 1.35
        case .lowBridges:
            return limits.passesClearances(route.clearancesMeters)
        case .mountainGrades:
            return limits.passesGrade(route.maxGradePercent)
        case .tourist:
            // Enrichment, not exclusion: no route is filtered out — the filter
            // pins attractions along the corridor and surfaces per-route
            // counts so scenic options rank visibly (AppModel side effect).
            return true
        }
    }
}

/// Continent-scale route planning WITHOUT a client-side road graph.
///
/// This is the answer to "users will not want to wait 5 minutes for the map":
/// the web app pays a multi-minute cold build because it loads a whole state
/// road graph up front. The app never does that — MKDirections plans across
/// all of North America server-side in ~a second, Apple streams only the map
/// tiles the camera can see, and FLOWS layers weather risk over just the
/// returned corridors (a few hundred sampled points, not a graph).
@MainActor
final class RouteService: ObservableObject {
    @Published private(set) var isPlanning = false

    private let geocoder = CLGeocoder()

    /// Geocode free text ("ZIP, county, or city" — same contract as the web
    /// planner) into a coordinate.
    func geocode(_ query: String) async throws -> (CLLocationCoordinate2D, String) {
        let placemarks = try await geocoder.geocodeAddressString(query)
        guard let pm = placemarks.first, let loc = pm.location else {
            throw RouteError.notFound(query)
        }
        let name = pm.locality ?? pm.name ?? query
        return (loc.coordinate, name)
    }

    /// Plan DISTINCT route strategies with live traffic and return
    /// IMMEDIATELY, sorted by ETA — the app's version of the web router's
    /// fastest/safest/metro triad:
    ///   * one standard request with alternates (the "fastest" family),
    ///   * one highway-avoiding request (the "local roads / metro" profile —
    ///     MKDirections alternates alone are often three near-identical
    ///     interstate variants, which is useless for an informed choice),
    ///   * "Safest" emerges after weather hydration as the lowest normalized
    ///     corridor risk (labelled in the choices UI).
    /// Weather scoring is deliberately not awaited here: on a 961-mile
    /// 30809→53203 plan the inline sequential scoring blocked route display
    /// for ~55 s; decoupling it puts routes on screen in under 2 s while
    /// `AppModel.hydrateRouteRisk()` fills the badges asynchronously
    /// (measured in apple/tools/route_bench.swift).
    func planRoutes(
        from: CLLocationCoordinate2D, fromName: String,
        to: CLLocationCoordinate2D, toName: String,
        includeTollFree: Bool = false,
        walking: Bool = false
    ) async throws -> [PlannedRoute] {
        isPlanning = true
        defer { isPlanning = false }

        @Sendable func request(kind: RoutePlanKind) -> MKDirections.Request {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
            request.transportType = walking ? .walking : .automobile
            request.departureDate = Date()   // "now" → traffic-aware ETAs
            if walking { return request }    // pedestrian network: one profile
            switch kind {
            case .standard:
                request.requestsAlternateRoutes = true
            case .avoidHighways:
                request.highwayPreference = .avoid
            case .tollFree:
                request.tollPreference = .avoid
                request.requestsAlternateRoutes = true
            }
            return request
        }

        // Walking is ONE pedestrian request (the strategies are identical when
        // transportType is .walking — three concurrent copies wasted requests),
        // and it returns [] instead of throwing so the caller's driving
        // fallback + notice always engage (Apple errors long walking asks).
        if walking {
            guard let resp = try? await MKDirections(request: request(kind: .standard))
                .calculate() else { return [] }
            return resp.routes.map {
                PlannedRoute(route: $0, sourceName: fromName, destinationName: toName,
                             planKind: .standard)
            }
        }

        // Strategies in flight concurrently; local-roads and toll-free are
        // best-effort (a corridor may have no sane answer for them).
        async let standardResp = MKDirections(request: request(kind: .standard)).calculate()
        async let localResp = try? MKDirections(request: request(kind: .avoidHighways)).calculate()
        async let tollFreeResp = includeTollFree
            ? (try? MKDirections(request: request(kind: .tollFree)).calculate()) : nil

        let standard = try await standardResp
        guard !standard.routes.isEmpty else { throw RouteError.noRoute }

        var planned = standard.routes.map {
            PlannedRoute(route: $0, sourceName: fromName, destinationName: toName,
                         planKind: .standard)
        }
        // Merge the other profiles, dropping geometric near-duplicates of a
        // standard alternate (same length and ETA to within a bucket).
        var seen = Set(planned.map { Self.dedupeKey($0.route) })
        for r in (await tollFreeResp)?.routes ?? [] where seen.insert(Self.dedupeKey(r)).inserted {
            planned.append(PlannedRoute(route: r, sourceName: fromName,
                                        destinationName: toName, planKind: .tollFree))
        }
        for r in (await localResp)?.routes ?? [] where seen.insert(Self.dedupeKey(r)).inserted {
            planned.append(PlannedRoute(route: r, sourceName: fromName,
                                        destinationName: toName, planKind: .avoidHighways))
        }

        // Cap at 5, but GUARANTEE profile diversity: the local-roads option
        // (and a toll-free one when requested) must survive the cap — "local
        // roads can be an option for routes".
        var capped = Array(planned.sorted { $0.eta < $1.eta }.prefix(5))
        // Distinct rescue slots from the end — review finding: writing both
        // rescues into the SAME last slot let tollFree clobber avoidHighways.
        var rescueSlot = capped.count - 1
        for kind in [RoutePlanKind.avoidHighways, .tollFree] where rescueSlot >= 0 {
            if !capped.contains(where: { $0.planKind == kind }),
               let candidate = planned.first(where: { $0.planKind == kind }) {
                capped[rescueSlot] = candidate
                rescueSlot -= 1
            }
        }
        return capped.sorted { $0.eta < $1.eta }
    }

    /// Routes within ~400 m and ~45 s of each other are the same road choice.
    nonisolated private static func dedupeKey(_ route: MKRoute) -> String {
        "\(Int(route.distance / 400))|\(Int(route.expectedTravelTime / 45))"
    }

    /// Sample coordinates along a polyline roughly every `everyMeters`.
    nonisolated static func samplePoints(
        of polyline: MKPolyline, everyMeters: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {
        corridorPartition(of: polyline, everyMeters: everyMeters).samples
    }

    /// Partition a polyline at ~`everyMeters` boundaries. `samples` are the
    /// boundary coordinates (identical to the old samplePoints output);
    /// `segments` are the coordinate runs BETWEEN adjacent boundaries, so
    /// `segments.count == samples.count - 1` and segment i spans samples
    /// i → i+1. The map strokes each segment in the risk-band color of the
    /// worse endpoint — that is the on-map "risk you are accepting" overlay.
    nonisolated static func corridorPartition(
        of polyline: MKPolyline, everyMeters: CLLocationDistance
    ) -> (samples: [CLLocationCoordinate2D], segments: [[CLLocationCoordinate2D]]) {
        let n = polyline.pointCount
        guard n > 0 else { return ([], []) }
        var coords = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid, count: n)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
        var samples: [CLLocationCoordinate2D] = [coords[0]]
        var segments: [[CLLocationCoordinate2D]] = []
        var current: [CLLocationCoordinate2D] = [coords[0]]
        var sinceLast: CLLocationDistance = 0
        for i in 1..<n {
            let a = CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
            let b = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
            sinceLast += b.distance(from: a)
            current.append(coords[i])
            if sinceLast >= everyMeters {
                samples.append(coords[i])
                segments.append(current)
                current = [coords[i]]
                sinceLast = 0
            }
        }
        if let last = coords.last {
            samples.append(last)          // preserved duplicate-tail semantics
            current.append(last)
            segments.append(current)
        }
        return (samples, segments)
    }
}

enum RouteError: LocalizedError {
    case notFound(String)
    case noRoute

    var errorDescription: String? {
        switch self {
        case .notFound(let q): return "Couldn't find “\(q)”. Try a ZIP, city, or county."
        case .noRoute: return "No drivable route found between those points."
        }
    }
}
