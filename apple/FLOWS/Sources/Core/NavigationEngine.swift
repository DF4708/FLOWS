// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
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
        var remainingDistance: CLLocationDistance
        var remainingTime: TimeInterval
        var cameraAltitude: Double
        var isOffRoute: Bool
    }

    @Published private(set) var guidance: Guidance?
    @Published private(set) var route: PlannedRoute?
    @Published private(set) var isRerouting = false

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

    func start(route: PlannedRoute) {
        self.route = route
        flatten(route: route.route)
        currentStep = firstRealStep()
        offRouteFixes = 0
        location.beginNavigationUpdates()
        cancellable = location.$latest
            .compactMap { $0 }
            .sink { [weak self] fix in self?.advance(with: fix) }
    }

    func stop() {
        cancellable = nil
        guidance = nil
        route = nil
        location.endNavigationUpdates()
    }

    // MARK: per-fix update — the time-sensitive loop

    private func advance(with fix: CLLocation) {
        guard route != nil, !points.isEmpty else { return }

        // Nearest route point (bounded scan around the previous match would be
        // the optimization; a full scan at 1 Hz over one route is already sub-ms).
        var nearest = 0
        var nearestDist = CLLocationDistance.greatestFiniteMagnitude
        for (i, pt) in points.enumerated() {
            let d = fix.distance(from: CLLocation(latitude: pt.latitude, longitude: pt.longitude))
            if d < nearestDist { nearestDist = d; nearest = i }
        }

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
            remainingDistance: remaining,
            remainingTime: (route?.eta ?? 0) * fraction,
            cameraAltitude: cameraAltitude(
                nearestIndex: nearest,
                distToManeuver: distToManeuver,
                speed: location.speed),
            isOffRoute: offRouteFixes >= 3
        )
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

    private func requestReroute(from fix: CLLocation) {
        guard !isRerouting, let current = route else { return }
        isRerouting = true
        offRouteFixes = 0
        let destination = points.last!
        Task { [weak self] in
            defer { self?.isRerouting = false }
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: fix.coordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
            request.transportType = .automobile
            request.departureDate = Date()
            guard let response = try? await MKDirections(request: request).calculate(),
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
