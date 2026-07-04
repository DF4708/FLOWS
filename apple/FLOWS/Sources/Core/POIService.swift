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

/// Gas / food along the selected corridor, from Apple Maps (MKLocalSearch).
/// Searches are scoped to regions around the corridor AHEAD of the driver —
/// never continent-wide — which keeps them fast and relevant.
@MainActor
final class POIService: ObservableObject {
    enum Kind: String, CaseIterable, Identifiable {
        case gas = "Gas"
        case food = "Food"
        var id: String { rawValue }

        var query: String {
            switch self {
            case .gas: return "gas station"
            case .food: return "food"
            }
        }

        var poiFilter: MKPointOfInterestFilter {
            switch self {
            case .gas: return MKPointOfInterestFilter(including: [.gasStation, .evCharger])
            case .food: return MKPointOfInterestFilter(including: [.restaurant, .cafe, .foodMarket])
            }
        }

        var symbol: String {
            switch self {
            case .gas: return "fuelpump.fill"
            case .food: return "fork.knife"
            }
        }
    }

    @Published private(set) var results: [MKMapItem] = []
    @Published var activeKind: Kind?

    private var corridor: [CLLocationCoordinate2D] = []

    func beginCorridorSearch(along route: PlannedRoute) {
        corridor = RouteService.samplePoints(of: route.route.polyline, everyMeters: 30_000)
    }

    func reset() {
        corridor = []
        results = []
        activeKind = nil
    }

    /// Search for a POI kind near the corridor ahead of `progressIndex`
    /// (how far along the sampled corridor the vehicle currently is).
    func search(_ kind: Kind, aheadOf position: CLLocationCoordinate2D?) async {
        activeKind = kind
        var found: [MKMapItem] = []
        // Take up to 3 corridor windows ahead of the vehicle (~30–90 km out).
        let ahead = corridorAhead(of: position).prefix(3)
        for center in ahead {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = kind.query
            request.pointOfInterestFilter = kind.poiFilter
            request.resultTypes = .pointOfInterest
            request.region = MKCoordinateRegion(
                center: center,
                latitudinalMeters: 20_000, longitudinalMeters: 20_000)
            if let response = try? await MKLocalSearch(request: request).start() {
                found.append(contentsOf: response.mapItems)
            }
        }
        // Dedup by name+proximity, cap the pin count so the nav map stays clean.
        var seen = Set<String>()
        results = found.filter { item in
            let key = "\(item.name ?? "?")|\(Int(item.placemark.coordinate.latitude * 500))|\(Int(item.placemark.coordinate.longitude * 500))"
            return seen.insert(key).inserted
        }.prefix(12).map { $0 }
    }

    func clearResults() {
        results = []
        activeKind = nil
    }

    private func corridorAhead(of position: CLLocationCoordinate2D?) -> [CLLocationCoordinate2D] {
        guard let position else { return corridor }
        guard let nearestIdx = corridor.indices.min(by: { i, j in
            distance(corridor[i], position) < distance(corridor[j], position)
        }) else { return corridor }
        return Array(corridor[nearestIdx...])
    }

    private func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
