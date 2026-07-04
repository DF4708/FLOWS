// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation
import MapKit

/// A planned route: Apple's traffic-aware MKRoute plus the FLOWS weather-risk
/// score layered on top.
struct PlannedRoute: Identifiable {
    let id = UUID()
    let route: MKRoute
    let sourceName: String
    let destinationName: String
    /// 0…1 FLOWS environmental risk along the corridor (max of sampled points).
    var weatherRisk: Double = 0
    var alertHeadlines: [String] = []

    var eta: TimeInterval { route.expectedTravelTime }   // includes live traffic
    var distanceMeters: Double { route.distance }
    var riskBand: RiskBand { FlowsCore.riskBand(score: weatherRisk) }
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
    @Published private(set) var lastError: String?

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

    /// Plan alternates with live traffic. Returns routes scored for weather.
    func planRoutes(
        from: CLLocationCoordinate2D, fromName: String,
        to: CLLocationCoordinate2D, toName: String,
        alerts: WeatherAlertService
    ) async throws -> [PlannedRoute] {
        isPlanning = true
        defer { isPlanning = false }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        request.departureDate = Date()   // "now" → traffic-aware ETAs

        let response = try await MKDirections(request: request).calculate()
        guard !response.routes.isEmpty else { throw RouteError.noRoute }

        var planned = response.routes.map {
            PlannedRoute(route: $0, sourceName: fromName, destinationName: toName)
        }

        // Weather-risk scoring per corridor: sample the polyline, ask NWS for
        // active alerts at the samples, fold severity into a 0…1 score. This
        // is FLOWS's value-add over stock Apple routing.
        for i in planned.indices {
            let samples = Self.samplePoints(of: planned[i].route.polyline, everyMeters: 40_000)
            let scored = await alerts.corridorRisk(at: samples)
            planned[i].weatherRisk = scored.risk
            planned[i].alertHeadlines = scored.headlines
        }
        // Same ranking philosophy as the web app: fastest first, but a red
        // corridor never outranks a clear one at similar ETA.
        planned.sort {
            if abs($0.eta - $1.eta) < 300 { return $0.weatherRisk < $1.weatherRisk }
            return $0.eta < $1.eta
        }
        return planned
    }

    /// Sample coordinates along a polyline roughly every `everyMeters`.
    nonisolated static func samplePoints(
        of polyline: MKPolyline, everyMeters: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {
        let n = polyline.pointCount
        guard n > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid, count: n)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
        var out: [CLLocationCoordinate2D] = [coords[0]]
        var sinceLast: CLLocationDistance = 0
        for i in 1..<n {
            let a = CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
            let b = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
            sinceLast += b.distance(from: a)
            if sinceLast >= everyMeters {
                out.append(coords[i])
                sinceLast = 0
            }
        }
        if let last = coords.last { out.append(last) }
        return out
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
