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
    /// Every alert the live watch found in its window of road ahead at its
    /// last full pass — all of them, not only each check point's worst (a
    /// Flood Warning inside a Severe Thunderstorm stretch is never the worst
    /// anywhere, so the check points alone never name it). Empty until the
    /// watch has run on this leg.
    var watchedAlertEvents: [String] = []
    var alertPolygons: [WeatherAlertService.AlertPolygon] = []
    var weatherScored = false
    /// 0…1 fraction of this route's corridor alert cells already resolved —
    /// fills the card's "Checking weather" progress while scoring runs.
    var scoringProgress: Double = 0
    /// Mid-scoring per-sample view: realized risk where the cell has landed,
    /// nil where the fetch is still in flight (or failed — unknown is never
    /// shown as clear). Display-only: the card colors what is known so a slow
    /// cellular link shows risk as it lands; GO stays locked until the full
    /// verdict flips `weatherScored`.
    var provisionalSamples: [RiskSample?] = []
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
    /// Draw geometry for the 3D-terrain grade overlay, resolved ONCE when
    /// the grade profile hydrates (RouteService.gradeDisplayGeometry) —
    /// the map body just strokes these.
    var gradeRibbonSlices: [(coords: [CLLocationCoordinate2D], gradePercent: Double)] = []
    var steepMarkers: [(coordinate: CLLocationCoordinate2D, gradePercent: Double)] = []
    /// All posted clearances (meters) found near the corridor below ~5.5 m —
    /// compared against the driver's vehicle-height slider.
    var clearancesMeters: [Double]?
    /// All posted weight limits (pounds) found on the corridor, from the
    /// same Overpass sweep — compared against the driver's vehicle + towing
    /// weight for the Bridge weight filter.
    var weightLimitsLbs: [Double]?
    /// True when EVERY Overpass endpoint failed (clearances and weight
    /// limits ride one query) — the card says "no map data" instead of
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
    /// road class. Only meaningful next to other routes on the same kind of
    /// road (RouteFilter.avoidsTraffic). (Real per-road congestion history
    /// needs data Apple doesn't expose; documented approx.)
    var congestionRatio: Double {
        let freeFlowSpeed = hasHighways ? 29.0 : 17.0   // m/s ≈ 65 / 38 mph
        let freeFlow = distanceMeters / freeFlowSpeed
        return freeFlow > 0 ? eta / freeFlow : 1
    }

    /// A LONG-DISTANCE WALKING plan beyond Apple's pedestrian-router range:
    /// geometry follows local roads (avoid-highways) and the ETA is computed
    /// at walking pace — honest routing information instead of "too far".
    var isWalkingEstimate = false
    /// A walk: Apple's pedestrian route or the long-walk estimate. Walks
    /// neither take the learned driving pace nor teach it.
    var isWalk: Bool { route.transportType == .walking || isWalkingEstimate }
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

    /// Worst realized risk among the corridor cells resolved SO FAR — the
    /// provisional "so far" band while scoring. nil until anything lands.
    var provisionalWorstRisk: Double? {
        provisionalSamples.compactMap { $0?.risk }.max()
    }

    /// Mid-scoring strip fractions: resolved samples by band, plus a trailing
    /// nil-band share for cells still being checked (drawn as pending, so an
    /// unfetched stretch never reads as clear).
    var provisionalFractions: [(band: RiskBand?, fraction: Double)] {
        guard !provisionalSamples.isEmpty else { return [] }
        var counts: [RiskBand: Int] = [:]
        var unknown = 0
        for s in provisionalSamples {
            if let s { counts[FlowsCore.riskBand(score: s.risk), default: 0] += 1 } else { unknown += 1 }
        }
        let n = Double(provisionalSamples.count)
        var out: [(band: RiskBand?, fraction: Double)] = [RiskBand.clear, .green, .yellow, .red]
            .compactMap { band in
                guard let c = counts[band], c > 0 else { return nil }
                return (band, Double(c) / n)
            }
        if unknown > 0 { out.append((nil, Double(unknown) / n)) }
        return out
    }

    /// A long-walk estimate's time: 3.1 mph sustained pace plus 10% rest.
    nonisolated static func walkingEstimateSeconds(meters: Double) -> TimeInterval {
        meters / 1.39 * 1.10
    }

    /// Fold in the weather pass's answer (`AppModel.scored`) from `scored`, a
    /// scoring of this same road, and leave every other field alone. A leg
    /// that starts before it is scored (the off-route replan) gets its
    /// scoring and its physical attributes in either order, and the live
    /// corridor keeps patching it in between: whole-route writes let the
    /// later pass wipe the earlier one's fields.
    mutating func takeScore(from scored: PlannedRoute) {
        weatherRisk = scored.weatherRisk
        alertCoverage = scored.alertCoverage
        alertHeadlines = scored.alertHeadlines
        alertEvents = scored.alertEvents
        alertPolygons = scored.alertPolygons
        weatherScored = scored.weatherScored
        riskSamples = scored.riskSamples
        riskSegments = scored.riskSegments
        peakRisk = scored.peakRisk
        avgRisk = scored.avgRisk
        zipExposure = scored.zipExposure
        rankingRisk = scored.rankingRisk
        milesByBand = scored.milesByBand
        hazardSummaries = scored.hazardSummaries
        familyPeaks = scored.familyPeaks
    }

    /// Fold in the physical-attribute pass (`AppModel.attributeScored`) from
    /// `hydrated`, a pass over this same road, and leave every other field
    /// alone — see `takeScore(from:)`.
    mutating func takeAttributes(from hydrated: PlannedRoute) {
        maxGradePercent = hydrated.maxGradePercent
        gradeProfile = hydrated.gradeProfile
        gradeRibbonSlices = hydrated.gradeRibbonSlices
        steepMarkers = hydrated.steepMarkers
        clearancesMeters = hydrated.clearancesMeters
        weightLimitsLbs = hydrated.weightLimitsLbs
        clearanceDataUnavailable = hydrated.clearanceDataUnavailable
        femaFloodFraction = hydrated.femaFloodFraction
        evChargingGapMiles = hydrated.evChargingGapMiles
        attributesScored = hydrated.attributesScored
    }

    /// The alerts on the road still ahead, each once: every alert the live
    /// watch saw in its window (worst first), then every check point's worst
    /// alert from the one the vehicle last passed (it is inside that
    /// stretch) to the end, `alongMeters` into the route. The live watch
    /// repaints the check points it covers, so an alert issued mid-drive is
    /// named and one that has ended is not; `alertEvents` is fixed at plan
    /// time. A route with no check points yet has only that.
    func alertEventsAhead(alongMeters: Double) -> [String] {
        guard !riskSamples.isEmpty else { return alertEvents }
        var start = 0
        var along = 0.0
        for i in 1..<riskSamples.count where i - 1 < riskSegments.count {
            along += riskSegments[i - 1].lengthMeters
            if along > alongMeters { break }
            start = i
        }
        let ahead = riskSamples[start...].enumerated()
            .filter { $0.element.worstEvent != nil }
            .sorted {
                $0.element.risk != $1.element.risk
                    ? $0.element.risk > $1.element.risk : $0.offset < $1.offset
            }
        var events: [String] = []
        for event in watchedAlertEvents where !events.contains(event) { events.append(event) }
        for s in ahead {
            if let event = s.element.worstEvent, !events.contains(event) { events.append(event) }
        }
        return events
    }

    /// This weather pass's result (`AppModel.scored`) as it lands on `card`,
    /// the same road's choice card now. The card keeps its physical
    /// attributes: a Try again scores while the first pass's bridge and hill
    /// checks land, and the copy it scored predates them. An INCOMPLETE
    /// score keeps the card's provisional picture instead of blanking back
    /// to a bare spinner.
    func landing(on card: PlannedRoute) -> PlannedRoute {
        var out = self
        if !weatherScored {
            out.scoringProgress = card.scoringProgress
            out.provisionalSamples = card.provisionalSamples
        }
        out.takeAttributes(from: card)
        return out
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
///   The raw values are the chip labels, named for what the chip keeps
///   away ("No steep hills"), like "No tolls" beside them: a chip named
///   for the hazard ("Mountain grades") read, when lit, as "show me them".
enum RouteFilter: String, CaseIterable, Identifiable {
    case noTolls = "No tolls"
    case noHighways = "No highways"
    case bridgeWeight = "No weak bridges"
    case noHighWinds = "No high winds"
    case noFloodRisk = "No flood risk"
    case avoidTraffic = "Avoid traffic"
    case lowBridges = "No low bridges"
    case mountainGrades = "No steep hills"
    case tourist = "Tourist stops"
    // ("Trucker" is NOT a filter — it's a dedicated route designation; see
    // AppModel.truckerRouteID.)

    var id: String { rawValue }

    /// `routes` are what Avoid traffic compares a route with (see
    /// `avoidsTraffic`); no others means nothing to avoid.
    func passes(_ route: PlannedRoute, limits: FilterLimits = FilterLimits(),
                among routes: [PlannedRoute] = []) -> Bool {
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
            return Self.avoidsTraffic(
                ratio: route.congestionRatio, highways: route.hasHighways,
                among: routes.map { (ratio: $0.congestionRatio, highways: $0.hasHighways) })
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
extension RouteFilter {
    /// The filters towing forces on: a rig under tow must not be sent over a
    /// mountain grade, under a low bridge, across a weight-limited one, or
    /// into a crosswind. Lives here so the launch path and the towing toggle
    /// read the SAME set — they used to hold separate copies, and the launch
    /// path simply never applied its one.
    static let towingSafety: Set<RouteFilter> =
        [.mountainGrades, .lowBridges, .bridgeWeight, .noHighWinds]

    /// The route the choices list shows when no route passes every filter:
    /// the fewest broken filters, then the lowest weather risk, then the
    /// sooner arrival (the list's "Closest match" card).
    static func closestMatch(in routes: [PlannedRoute], filters: Set<RouteFilter>,
                             limits: FilterLimits) -> PlannedRoute? {
        func broken(_ r: PlannedRoute) -> Int { filters.filter { !$0.passes(r, limits: limits) }.count }
        return routes.min { a, b in
            let (va, vb) = (broken(a), broken(b))
            if va != vb { return va < vb }
            if a.weatherRisk != b.weatherRisk { return a.weatherRisk < b.weatherRisk }
            return a.eta < b.eta
        }
    }

    /// The towing card's line about the towing filters, built from the ones
    /// actually on — the driver can switch any of them off on the choices
    /// screen, and the card used to go on claiming all four.
    static func towingSummary(active: Set<RouteFilter>) -> String {
        let phrases: [(RouteFilter, String)] = [
            (.mountainGrades, "steep grades"),
            (.lowBridges, "low bridges"),
            (.noHighWinds, "high winds"),
            (.bridgeWeight, "roads with weight signs under your vehicle + towing weight"),
        ]
        let on = phrases.filter { active.contains($0.0) }.map(\.1)
        switch on.count {
        case 0: return "Towing route filters are off."
        case 1: return "Route filters set: avoiding \(on[0])."
        case 2: return "Route filters set: avoiding \(on[0]) and \(on[1])."
        default:
            return "Route filters set: avoiding \(on.dropLast().joined(separator: ", ")), "
                + "and \(on[on.count - 1])."
        }
    }

    /// The filters that judge a route. On foot only No highways does: the
    /// chips are hidden while walking, and a driving filter left on (Avoid
    /// traffic is on by default and times a walk against car speeds) threw
    /// out every walk with nothing on screen to turn it off.
    static func judging(_ filters: Set<RouteFilter>, walking: Bool) -> Set<RouteFilter> {
        walking ? filters.intersection([.noHighways]) : filters
    }

    /// A mode that forces filters on (walking, towing) adds only the ones
    /// the driver hadn't picked, and `added` is all it may take away again:
    /// a No highways or No low bridges the driver chose stays theirs.
    static func forcing(_ forced: Set<RouteFilter>, onto filters: Set<RouteFilter>)
        -> (filters: Set<RouteFilter>, added: Set<RouteFilter>) {
        (filters.union(forced), forced.subtracting(filters))
    }

    /// How far a route's congestion ratio may sit above the calmest route
    /// on the same kind of road and still pass Avoid traffic.
    static let trafficAllowance = 0.3

    /// Avoid traffic, judged against the other routes on offer. The ratio
    /// sets the live-traffic time against a free-flow guess for the road
    /// class, which can't tell a slow street from a jammed one: as a fixed
    /// 1.35 cutoff it threw out every in-town route at 2 am, Local roads
    /// with them, and could empty the list. So a route fails only when it
    /// crawls clearly worse than the calmest route on the same kind of road
    /// (highways or not); the calmest of each kind always passes. Pure,
    /// pinned by tests.
    static func avoidsTraffic(ratio: Double, highways: Bool,
                              among others: [(ratio: Double, highways: Bool)]) -> Bool {
        let calmest = others.filter { $0.highways == highways }.map(\.ratio).min() ?? ratio
        return ratio <= min(calmest, ratio) + trafficAllowance
    }
}

/// Which towing filters towing itself switched on. Turning towing off takes
/// back only those: it used to subtract all four, so a driver who had chosen
/// Low bridges for a tall rig lost it on unhitching.
struct TowingFilterHold: Equatable {
    private(set) var added: Set<RouteFilter> = []

    mutating func towingOn(_ filters: inout Set<RouteFilter>) {
        added.formUnion(RouteFilter.towingSafety.subtracting(filters))
        filters.formUnion(RouteFilter.towingSafety)
    }

    mutating func towingOff(_ filters: inout Set<RouteFilter>) {
        filters.subtract(added)
        added = []
    }

    /// The driver switched this filter by hand: it is theirs now, and
    /// towing no longer takes it back.
    mutating func driverChose(_ filter: RouteFilter) {
        added.remove(filter)
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
    ///   * Raw coordinates ("43.0731, -89.4012") plan directly — no
    ///     geocoder, no network.
    ///   * Ambiguous names resolve NEAREST-FIRST when the driver's position
    ///     is known: "Springfield" should mean the one down the road, not
    ///     whichever of the dozen Apple lists first.
    ///   * REDUNDANT: CLGeocoder is rate-limited and throttles bursts; when
    ///     it fails, MKLocalSearch answers the same query through a
    ///     different Apple service, so planning survives a geocoder throttle
    ///     instead of dead-ending the destination field.
    func geocode(
        _ query: String, near: CLLocationCoordinate2D? = nil
    ) async throws -> (CLLocationCoordinate2D, String) {
        if let point = CoordinateInput.parse(query) {
            return (point, CoordinateInput.displayName(point))
        }
        do {
            let placemarks = try await geocoder.geocodeAddressString(query)
                .filter { $0.location != nil }
            let pm: CLPlacemark?
            if let near {
                pm = placemarks.min {
                    POIRanking.meters($0.location!.coordinate, near)
                        < POIRanking.meters($1.location!.coordinate, near)
                }
            } else {
                pm = placemarks.first
            }
            guard let pm, let loc = pm.location else {
                throw RouteError.notFound(query)
            }
            let name = pm.locality ?? pm.name ?? query
            return (loc.coordinate, name)
        } catch {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            if let near {
                request.region = MKCoordinateRegion(
                    center: near, latitudinalMeters: 200_000, longitudinalMeters: 200_000)
            }
            guard let item = (try? await MKLocalSearch(request: request).start())?
                .mapItems.first else { throw error }   // surface the ORIGINAL failure
            FlowsDiag.logThrottled(
                key: "geocode.fallback", .info, "geocode",
                "CLGeocoder failed — MKLocalSearch answered the plan query")
            let pm = item.placemark
            return (pm.coordinate, pm.locality ?? item.name ?? query)
        }
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

    /// How much slower a route may be and still win the top card on lower
    /// risk — PROPORTIONAL to the trip, not a flat number.
    ///
    /// Review finding: this was a fixed 300 s, which is a 25% swing on a
    /// 20-minute errand and 0.8% on a ten-hour haul. That made safety
    /// essentially unable to win a short trip and almost unable to lose a
    /// long one — an inversion nobody chose. 8% of the shorter ETA matches
    /// how people actually talk about detours ("ten minutes out of my way"
    /// means something different on a cross-country run), with a 2-minute
    /// floor so short trips still have a real tolerance, and a 15-minute
    /// ceiling so a marginally-calmer corridor can't cost three quarters of
    /// an hour on a long haul.
    nonisolated static func etaTieTolerance(shorterETA: TimeInterval) -> TimeInterval {
        let proportional = max(shorterETA, 0) * 0.08
        return min(max(proportional, 120), 900)
    }

    /// Scale routing ETAs by the driver's learned pace (DrivingProfile). A
    /// multiplier of 1 — not yet earned, or a driver who matches the router
    /// — returns the routes untouched, and a route that already carries an
    /// `etaOverride` (the long-walk estimate) keeps its own number. A walk
    /// keeps the pedestrian router's time: the pace is how this person
    /// DRIVES.
    nonisolated static func applyPersonalPace(
        _ routes: [PlannedRoute], multiplier: Double
    ) -> [PlannedRoute] {
        guard multiplier != 1, multiplier.isFinite, multiplier > 0 else { return routes }
        return routes.map { r in
            guard r.etaOverride == nil, !r.isWalk else { return r }
            var out = r
            out.etaOverride = r.route.expectedTravelTime * multiplier
            return out
        }
    }

    /// Precomputed draw geometry for the 3D-terrain grade overlay: the
    /// ribbon's per-segment polyline slices and the steep-marker (≥6%, first
    /// 12) midpoints. One pass extracts the coordinates and their cumulative
    /// meters; each segment then resolves by binary search. The map body
    /// used to re-extract and re-walk the WHOLE polyline for every segment
    /// on every frame — ~100 segments × thousands of vertices at GPS-fix
    /// cadence whenever 3D terrain was on.
    nonisolated static func gradeDisplayGeometry(
        of polyline: MKPolyline, profile: [GradeSegment]
    ) -> (slices: [(coords: [CLLocationCoordinate2D], gradePercent: Double)],
          markers: [(coordinate: CLLocationCoordinate2D, gradePercent: Double)]) {
        let n = polyline.pointCount
        guard n > 1, !profile.isEmpty else { return ([], []) }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: n)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
        var prefix = [Double](repeating: 0, count: n)
        for i in 1..<n { prefix[i] = prefix[i - 1] + POIRanking.meters(coords[i - 1], coords[i]) }

        // First vertex index whose cumulative distance reaches `target`.
        func firstIndex(atOrAbove target: Double) -> Int {
            var lo = 0, hi = n
            while lo < hi {
                let mid = (lo + hi) / 2
                if prefix[mid] >= target { hi = mid } else { lo = mid + 1 }
            }
            return lo
        }

        var slices: [(coords: [CLLocationCoordinate2D], gradePercent: Double)] = []
        slices.reserveCapacity(profile.count)
        for seg in profile {
            let a = seg.startMile * 1609.344, b = seg.endMile * 1609.344
            var i = firstIndex(atOrAbove: a)
            var pts: [CLLocationCoordinate2D] = []
            while i < n, prefix[i] <= b {
                pts.append(coords[i])
                i += 1
            }
            if pts.count >= 2 { slices.append((pts, seg.gradePercent)) }
        }
        var markers: [(coordinate: CLLocationCoordinate2D, gradePercent: Double)] = []
        for seg in profile where abs(seg.gradePercent) >= 6 {
            if markers.count >= 12 { break }
            let target = (seg.startMile + seg.endMile) / 2 * 1609.344
            let i = min(max(firstIndex(atOrAbove: target), 1), n - 1)
            markers.append((coords[i], seg.gradePercent))
        }
        return (slices, markers)
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
            // POIRanking.meters, not CLLocation.distance: this loop walks
            // every vertex of the polyline (~30k on a long route) and is run
            // several times per route — the CLLocation pair here was two heap
            // objects per vertex. The equirectangular error (<0.1% at vertex
            // hop lengths) only shifts a sample boundary against the 40 km
            // threshold by at most one vertex.
            sinceLast += POIRanking.meters(coords[i - 1], coords[i])
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
    /// No fix, no typed start and nothing known to start from.
    case noStart

    var errorDescription: String? {
        switch self {
        case .notFound(let q): return "Couldn't find “\(q)”. Try a ZIP, city, or county."
        case .noRoute: return "No drivable route found between those points."
        case .noStart: return "No starting point yet. Type where you're starting from."
        }
    }

    /// Plain words for any planning failure — never a raw framework error
    /// ("kCLErrorDomain error 8"), and "try again" only where trying again
    /// can help: a route that doesn't exist won't appear on a retry.
    static func plainMessage(for error: Error) -> String {
        if let routeError = error as? RouteError, let text = routeError.errorDescription {
            return text
        }
        if (error as? MKError)?.code == .directionsNotFound {
            return "No drivable route found between those places."
        }
        let ns = error as NSError
        if ns.domain == kCLErrorDomain {
            switch ns.code {
            case 8: return "Couldn't find that place. Check the spelling or add a city or state."
            case 2: return "No internet right now — try again when you're back in coverage."
            default: return "Couldn't look that up right now. Try again in a moment."
            }
        }
        if (error as? URLError) != nil {
            return "No internet right now — try again when you're back in coverage."
        }
        return "Couldn't plan that route. Try again in a moment."
    }
}

/// Which route earns the "Cheapest" chip. Fuel is the only cost FLOWS can
/// price, and every route burns it at one price and one mileage, so on fuel
/// alone "Cheapest" always went to the shortest road — tolls and all, the
/// same card as "Efficient". A toll is money the estimate can't see, so a
/// tolled route gives the chip up to a toll-free one that costs no more
/// than `tollAllowanceUSD` extra in fuel. Pure, pinned by tests.
enum CheapestRoute {
    struct Candidate: Equatable {
        let id: UUID
        let fuelUSD: Double
        let hasTolls: Bool
    }

    static let tollAllowanceUSD = 5.0

    /// Lowest fuel, ties to toll-free; nil for no candidates.
    static func pick(_ candidates: [Candidate]) -> UUID? {
        func cheaper(_ a: Candidate, _ b: Candidate) -> Bool {
            if abs(a.fuelUSD - b.fuelUSD) > 0.01 { return a.fuelUSD < b.fuelUSD }
            return !a.hasTolls && b.hasTolls
        }
        guard let lowest = candidates.min(by: cheaper) else { return nil }
        guard lowest.hasTolls,
              let tollFree = candidates.filter({ !$0.hasTolls }).min(by: cheaper),
              tollFree.fuelUSD - lowest.fuelUSD <= tollAllowanceUSD
        else { return lowest.id }
        return tollFree.id
    }
}

/// Which route earns the trucker badge.
///
/// A KNOWN low bridge DISQUALIFIES a route — it is not a 3-point penalty
/// to be outweighed by highways and gentle grades. A route failing a 13'6"
/// clearance check once scored 6 and could tie or beat a clearance-passing
/// route, i.e. the badge could point a semi at a bridge it cannot clear.
/// Unknown clearance data still passes (the app-wide "unknown never
/// excludes" rule). If nothing clears, no route earns the badge: silence
/// is honest, badging an impassable route is not. Pure, pinned by tests.
enum TruckerDesignation {
    struct Candidate: Equatable {
        let id: UUID
        /// Passes every known clearance on the route (unknown = passes).
        let clearsBridges: Bool
        let hasHighways: Bool
        let avoidsHighways: Bool
        let gradeOK: Bool
        let windOK: Bool
        let eta: TimeInterval
    }

    static func score(_ c: Candidate) -> Double {
        var s = 0.0
        if c.hasHighways && !c.avoidsHighways { s += 3 }
        if c.gradeOK { s += 2 }
        if c.windOK { s += 1 }
        return s
    }

    /// Best score, then shortest ETA; nil when no candidate clears.
    static func pick(_ candidates: [Candidate]) -> UUID? {
        candidates
            .filter(\.clearsBridges)
            .map { (id: $0.id, score: score($0), eta: $0.eta) }
            .min { $0.score != $1.score ? $0.score > $1.score : $0.eta < $1.eta }?
            .id
    }
}

