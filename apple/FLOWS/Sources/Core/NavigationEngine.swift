// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Combine
import CoreLocation
import Foundation
import MapKit

/// Turn-by-turn navigation state machine.
///
/// Once a route is selected the map becomes TIME-SENSITIVE: every GPS fix
/// advances the instruction state and re-aims the camera. The camera's zoom
/// follows the DISTANCE BETWEEN INTERSECTIONS (CameraZoom):
///
///   * long highway stretch between off-ramps → high altitude (zoomed out),
///     scaled further out with speed so the driver sees farther ahead;
///   * dense city blocks with turns every few hundred meters → low altitude
///     (zoomed in), regardless of speed;
///   * imminent maneuver (< 250 m) → tight zoom on the intersection;
///   * walking → always the close-in view (walking pace never needs distance).
///
/// The spacing signal is the current step's length — the road between the
/// maneuver behind and the one ahead — cheap per-fix arithmetic on the
/// flattened geometry.
@MainActor
final class NavigationEngine: ObservableObject {
    struct Guidance {
        var instruction: String
        var distanceToManeuver: CLLocationDistance
        var stepIndex: Int
        /// Meters travelled along the route (cumulative at nearest vertex) —
        /// the anchor for the speed-scaled live-monitoring window.
        var alongMeters: CLLocationDistance = 0
        var remainingDistance: CLLocationDistance
        var remainingTime: TimeInterval
        var cameraAltitude: Double
        var isOffRoute: Bool
    }

    @Published private(set) var guidance: Guidance?
    @Published private(set) var route: PlannedRoute?
    @Published private(set) var isRerouting = false
    /// How far the last fix sat from the road corridor being driven — the
    /// "are we even on a road?" signal crash detection corroborates with
    /// (CrashLogic.isCrash). nil before the first matched fix.
    @Published private(set) var metersFromCorridor: CLLocationDistance?

    /// Fired ONCE when the vehicle reaches the route's end (< 120 m) —
    /// AppModel chains multi-leg trips (POI stop → final destination) off it.
    /// Set via start(route:onArrival:) — never assigned post-start.
    private var onArrival: (() -> Void)?
    private var arrivalFired = false
    /// Takes an off-route replan and starts it as a new leg: AppModel
    /// restarts the corridor watch, the stops search and the Watch's line
    /// on the new road and scores it. Answers false when it declines (no
    /// trip being navigated), and then — as with no owner at all — the
    /// engine swaps the route in place, so it is back on the road being
    /// driven instead of asking for the same replan every few fixes.
    var onReroute: ((PlannedRoute) -> Bool)?

    private let location: LocationService
    private var cancellable: AnyCancellable?

    // Route geometry, flattened once at start (not per fix).
    private var points: [CLLocationCoordinate2D] = []
    private var cumulative: [CLLocationDistance] = []   // meters from origin to points[i]
    private var stepEndIndex: [Int] = []                // index into points at each step's end
    private var stepInstructions: [String] = []
    private var currentStep = 0
    private var offRouteFixes = 0

    init(location: LocationService) {
        self.location = location
    }

    /// Late-hydration patch: swap in a metadata-richer copy of the SAME
    /// route (physical attributes land after GO on long corridors). Same id
    /// ⇒ same geometry, so the flattened points/steps stay valid; a
    /// different id is refused rather than desyncing guidance.
    func updateRouteMetadata(_ richer: PlannedRoute) {
        guard let current = route, current.id == richer.id else { return }
        route = richer
    }

    /// True for pedestrian routes (real or estimated) — the camera then pins
    /// to the close-in walking view instead of the intersection-spacing zoom.
    private var isWalkingRoute = false

    /// `onArrival` is a parameter (not assigned after the fact) because
    /// start() produces guidance immediately — review finding: assigning the
    /// callback on the NEXT line meant a <120 m arrival fired into a nil or
    /// stale closure (reentrantly consuming the previous trip's chain).
    func start(route: PlannedRoute, onArrival: (() -> Void)? = nil) {
        lastNearestIndex = 0
        rerouteTask?.cancel()   // a reroute for the OLD leg must not clobber this one
        self.route = route
        self.onArrival = onArrival
        isWalkingRoute = route.isWalkingEstimate
            || route.route.transportType == .walking
        flatten(route: route.route)
        currentStep = firstRealStep()
        offRouteFixes = 0
        arrivalFired = false
        location.beginNavigationUpdates()
        // dropFirst: @Published replays the current fix SYNCHRONOUSLY on
        // subscribe, so without it an instant arrival ran inside start() —
        // inside the caller's leg setup, which then undid the arrival's
        // handling (a replan that lands at the door). The next-tick Task
        // below delivers that fix instead.
        cancellable = location.$latest
            .dropFirst()
            .compactMap { $0 }
            .sink { [weak self] fix in self?.advance(with: fix) }
        // First instruction/camera immediately — but on the NEXT main-actor
        // tick so an instant arrival can never re-enter the caller mid-start.
        if let fix = location.latest {
            Task { @MainActor [weak self] in self?.advance(with: fix) }
        }
    }

    func stop() {
        rerouteTask?.cancel()
        rerouteTask = nil
        cancellable = nil
        guidance = nil
        route = nil
        metersFromCorridor = nil
        location.endNavigationUpdates()
    }

    /// The coordinate `meters` ahead of the current position ALONG the route —
    /// the far end of the local window a walking-estimate refresh routes to.
    /// Uses the cached nearest-index so it's O(window), not a full scan.
    func coordinateAhead(meters: CLLocationDistance) -> CLLocationCoordinate2D? {
        guard !points.isEmpty, lastNearestIndex < cumulative.count else { return nil }
        let target = cumulative[lastNearestIndex] + meters
        for i in lastNearestIndex..<cumulative.count where cumulative[i] >= target {
            return points[i]
        }
        return points.last
    }

    // MARK: per-fix update — the time-sensitive loop

    /// Last matched route index — the next fix searches a LOCAL WINDOW around
    /// it instead of rescanning the whole polyline (a cross-country route has
    /// tens of thousands of points; the old full scan also allocated two
    /// CLLocation objects per point per 1 Hz fix on the main actor).
    private var lastNearestIndex = 0

    private func advance(with fix: CLLocation) {
        guard route != nil, !points.isEmpty else { return }

        // Windowed nearest-point match (allocation-free equirectangular math);
        // full rescan only when the window loses the vehicle (rejoin, jump).
        func scan(_ range: Range<Int>) -> (idx: Int, dist: CLLocationDistance) {
            var bestI = range.lowerBound
            var bestD = CLLocationDistance.greatestFiniteMagnitude
            for i in range {
                let d = POIRanking.meters(points[i], fix.coordinate)
                if d < bestD { bestD = d; bestI = i }
            }
            return (bestI, bestD)
        }
        // Clamp lo so lo <= hi always holds — defense in depth against a
        // stale index outliving a route swap (forming lo..<hi with lo > hi
        // traps). The reroute path resets the index, this guards the rest.
        let hi = min(lastNearestIndex + 80, points.count)
        let lo = min(max(lastNearestIndex - 12, 0), hi)
        var (nearest, nearestDist) = scan(lo..<hi)
        if nearestDist > 250 {   // window lost the vehicle → one full rescan
            (nearest, nearestDist) = scan(0..<points.count)
        }
        lastNearestIndex = nearest
        metersFromCorridor = nearestDist

        // Off-route: 3 consecutive fixes > 60 m from the corridor → reroute.
        if nearestDist > 60 {
            offRouteFixes += 1
            if offRouteFixes >= 3 { requestReroute(from: fix) }
        } else {
            offRouteFixes = 0
        }

        // Advance instruction step when we pass its end point.
        while currentStep < stepEndIndex.count - 1 && nearest >= stepEndIndex[currentStep] {
            currentStep += 1
        }

        let maneuverIdx = stepEndIndex[min(currentStep, stepEndIndex.count - 1)]
        let distToManeuver = max(cumulative[maneuverIdx] - cumulative[nearest], 0)
        let remaining = max(cumulative.last! - cumulative[nearest], 0)
        let fraction = cumulative.last! > 0 ? remaining / cumulative.last! : 0

        guidance = Guidance(
            instruction: stepInstructions[min(currentStep, stepInstructions.count - 1)],
            distanceToManeuver: distToManeuver,
            stepIndex: currentStep,
            alongMeters: cumulative[nearest],
            remainingDistance: remaining,
            remainingTime: (route?.eta ?? 0) * fraction,
            cameraAltitude: cameraAltitude(
                nearestIndex: nearest,
                distToManeuver: distToManeuver,
                speed: location.speed),
            isOffRoute: offRouteFixes >= 3
        )

        if remaining < 120, !arrivalFired {
            // Guard against a spurious nearest-vertex match on a route that
            // doubles back (or a large GPS jump landing on a late vertex): fire
            // arrival only when the fix is ALSO physically near the destination,
            // not merely when the along-route `remaining` (from a possibly-wrong
            // `nearest`) says so — otherwise the multi-leg onArrival chain could
            // fire while the driver is still far out.
            let dest = points.last!
            let destDist = fix.distance(from: CLLocation(
                latitude: dest.latitude, longitude: dest.longitude))
            if destDist < 200 {
                arrivalFired = true
                rerouteTask?.cancel()   // a replan in flight must not re-arm the finished leg
                onArrival?()
            }
        }
    }

    /// Zoom policy: the distance between intersections — this step's length,
    /// from the maneuver behind to the one ahead — mapped by CameraZoom.
    /// City blocks read close, highway stretches read far, walking pins to
    /// the close-in view.
    private func cameraAltitude(
        nearestIndex: Int, distToManeuver: CLLocationDistance, speed: Double
    ) -> Double {
        if isWalkingRoute { return CameraZoom.walkingAltitude }
        let stepIdx = min(currentStep, stepEndIndex.count - 1)
        let stepStart = stepIdx == 0 ? 0 : stepEndIndex[stepIdx - 1]
        let spacing = cumulative[stepEndIndex[stepIdx]] - cumulative[stepStart]
        return CameraZoom.drivingAltitude(
            intersectionSpacingMeters: spacing,
            distanceToManeuverMeters: distToManeuver,
            speedMps: speed)
    }

    // MARK: reroute

    private var rerouteTask: Task<Void, Never>?

    private func requestReroute(from fix: CLLocation) {
        // Not after arrival: circling the lot or GPS drift indoors would
        // start a fresh leg and fire arrival a second time.
        guard !isRerouting, !arrivalFired, let current = route else { return }
        isRerouting = true
        offRouteFixes = 0
        let destination = points.last!
        // Replan the way the leg was planned. This always asked for a
        // driving route, so a walker who strayed was sent down roads for
        // cars — freeways included on a long walk.
        let walking = current.route.transportType == .walking
        let walkingEstimate = current.isWalkingEstimate
        let planKind = current.planKind
        rerouteTask?.cancel()
        rerouteTask = Task { [weak self] in
            defer { self?.isRerouting = false }
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: fix.coordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
            request.transportType = walking ? .walking : .automobile
            request.departureDate = Date()
            if walkingEstimate {
                // Beyond the pedestrian router's range: local roads, and the
                // first answer with no highway at all, as the planner does.
                request.highwayPreference = .avoid
                request.requestsAlternateRoutes = true
            } else if !walking {
                // A driver who chose the local-roads or toll-free route
                // keeps that choice on the way back.
                switch planKind {
                case .standard: break
                case .avoidHighways: request.highwayPreference = .avoid
                case .tollFree: request.tollPreference = .avoid
                }
            }
            guard let response = try? await MKDirections(request: request).calculate(),
                  !Task.isCancelled,   // stop()/new leg superseded this reroute
                  let newRoute = walkingEstimate
                    ? response.routes.first(where: { !$0.hasHighways }) ?? response.routes.first
                    : response.routes.first,
                  let self, !self.arrivalFired else { return }
            var replanned = PlannedRoute(
                route: newRoute,
                sourceName: "Current location",
                destinationName: current.destinationName,
                planKind: planKind)
            if walkingEstimate {
                replanned.isWalkingEstimate = true
                replanned.etaOverride = PlannedRoute.walkingEstimateSeconds(
                    meters: newRoute.distance)
            }
            if let onReroute = self.onReroute, onReroute(replanned) { return }
            replanned.weatherRisk = current.weatherRisk
            replanned.alertHeadlines = current.alertHeadlines
            self.route = replanned
            self.flatten(route: newRoute)
            self.currentStep = self.firstRealStep()
            // The new route is shorter; a stale lastNearestIndex (e.g. ~30k
            // from 60% into the old trip) would form an invalid lo..<hi window
            // on the next fix and TRAP. Reset it, as start() does.
            self.lastNearestIndex = 0
            self.offRouteFixes = 0
        }
    }

    // MARK: geometry prep

    private func flatten(route: MKRoute) {
        points = []
        cumulative = []
        stepEndIndex = []
        stepInstructions = []

        var running: CLLocationDistance = 0
        var prev: CLLocationCoordinate2D?
        for step in route.steps {
            let poly = step.polyline
            let n = poly.pointCount
            guard n > 0 else { continue }
            var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: n)
            poly.getCoordinates(&coords, range: NSRange(location: 0, length: n))
            for c in coords {
                // Allocation-free hop distance — this walks every vertex of
                // the whole route at leg start.
                if let p = prev { running += POIRanking.meters(p, c) }
                points.append(c)
                cumulative.append(running)
                prev = c
            }
            stepEndIndex.append(points.count - 1)
            stepInstructions.append(step.instructions.isEmpty ? "Continue" : step.instructions)
        }
    }

    /// MKRoute's first step is often an empty-instruction "depart" stub.
    private func firstRealStep() -> Int {
        stepInstructions.firstIndex { $0 != "Continue" } ?? 0
    }
}
