// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
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
/// advances the instruction state and re-aims the camera. The camera's zoom is
/// not fixed — it adapts to the concentration of upcoming maneuvers:
///
///   * long highway stretch, no exits to take  → high altitude (zoomed out),
///     scaled further out with speed so the driver sees farther ahead;
///   * dense city blocks with turns every few hundred meters → low altitude
///     (zoomed in), regardless of speed;
///   * imminent maneuver (< 250 m) → tight zoom on the intersection.
///
/// The zoom signal is maneuvers-per-km in a speed-scaled lookahead window —
/// cheap integer/geometry work per fix (the kind of loop that migrates into
/// rust/flows-core if profiling ever shows it hot; at 1 Hz it never has been).
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

    /// Fired ONCE when the vehicle reaches the route's end (< 120 m) —
    /// AppModel chains multi-leg trips (POI stop → final destination) off it.
    /// Set via start(route:onArrival:) — never assigned post-start.
    private var onArrival: (() -> Void)?
    private var arrivalFired = false

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

    /// `onArrival` is a parameter (not assigned after the fact) because
    /// start() produces guidance immediately — review finding: assigning the
    /// callback on the NEXT line meant a <120 m arrival fired into a nil or
    /// stale closure (reentrantly consuming the previous trip's chain).
    func start(route: PlannedRoute, onArrival: (() -> Void)? = nil) {
        lastNearestIndex = 0
        rerouteTask?.cancel()   // a reroute for the OLD leg must not clobber this one
        self.route = route
        self.onArrival = onArrival
        flatten(route: route.route)
        currentStep = firstRealStep()
        offRouteFixes = 0
        arrivalFired = false
        location.beginNavigationUpdates()
        cancellable = location.$latest
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
        let lo = max(lastNearestIndex - 12, 0)
        let hi = min(lastNearestIndex + 80, points.count)
        var (nearest, nearestDist) = scan(lo..<hi)
        if nearestDist > 250 {   // window lost the vehicle → one full rescan
            (nearest, nearestDist) = scan(0..<points.count)
        }
        lastNearestIndex = nearest

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
                onArrival?()
            }
        }
    }

    /// Zoom policy: maneuver density in a speed-scaled lookahead window.
    private func cameraAltitude(
        nearestIndex: Int, distToManeuver: CLLocationDistance, speed: Double
    ) -> Double {
        // Imminent turn: zoom to the intersection.
        if distToManeuver < 250 { return 350 }

        // Lookahead: ~90 s of travel, clamped to 0.8–8 km.
        let lookahead = min(max(speed * 90, 800), 8000)
        let here = cumulative[nearestIndex]
        let horizon = here + lookahead
        let upcoming = stepEndIndex.filter {
            cumulative[$0] > here && cumulative[$0] <= horizon
        }.count
        let turnsPerKm = Double(upcoming) / (lookahead / 1000)

        // Dense urban grid (≥ ~2.5 turns/km) pins to 500 m altitude; an empty
        // highway window relaxes to 2400 m, stretched up to 1.5× with speed so
        // faster travel sees proportionally farther.
        let density = min(max(turnsPerKm / 2.5, 0), 1)
        let base = 2400 - (2400 - 500) * density
        let speedStretch = min(max(speed / 31.0, 1.0), 1.5)   // 31 m/s ≈ 70 mph
        return base * (density < 0.5 ? speedStretch : 1.0)
    }

    // MARK: reroute

    private var rerouteTask: Task<Void, Never>?

    private func requestReroute(from fix: CLLocation) {
        guard !isRerouting, let current = route else { return }
        isRerouting = true
        offRouteFixes = 0
        let destination = points.last!
        rerouteTask?.cancel()
        rerouteTask = Task { [weak self] in
            defer { self?.isRerouting = false }
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: fix.coordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
            request.transportType = .automobile
            request.departureDate = Date()
            guard let response = try? await MKDirections(request: request).calculate(),
                  !Task.isCancelled,   // stop()/new leg superseded this reroute
                  let newRoute = response.routes.first, let self else { return }
            var replanned = PlannedRoute(
                route: newRoute,
                sourceName: "Current location",
                destinationName: current.destinationName)
            replanned.weatherRisk = current.weatherRisk
            replanned.alertHeadlines = current.alertHeadlines
            self.route = replanned
            self.flatten(route: newRoute)
            self.currentStep = self.firstRealStep()
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
                if let p = prev {
                    running += CLLocation(latitude: p.latitude, longitude: p.longitude)
                        .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
                }
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
