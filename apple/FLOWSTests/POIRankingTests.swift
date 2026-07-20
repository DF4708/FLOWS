// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// Gates for the route-aware POI ranking: never backwards, capped detour,
/// food ordered soonest-reachable, fuel ordered by fill-cost + detour-time.
final class POIRankingTests: XCTestCase {

    /// A straight west→east route along latitude 43, ~111 km long.
    private func straightRoute() -> POIRanking.RoutePath {
        let coords = stride(from: -90.0, through: -88.6, by: 0.01).map {
            CLLocationCoordinate2D(latitude: 43.0, longitude: $0)
        }
        return POIRanking.RoutePath(coords: coords)
    }

    private func candidate(
        _ name: String, lon: Double, latOffset: Double = 0, price: Double? = nil,
        route: POIRanking.RoutePath, vehicleAlong: CLLocationDistance
    ) -> POIRanking.Candidate<String>? {
        POIRanking.annotate(
            item: name,
            at: CLLocationCoordinate2D(latitude: 43.0 + latOffset, longitude: lon),
            route: route, vehicleAlong: vehicleAlong, pricePerUnit: price)
    }

    func testBehindTheVehicleIsExcluded() {
        let route = straightRoute()
        // Vehicle mid-route (~ -89.3).
        let vehicleAlong = route.cumulative[route.coords.count * 5 / 10]
        let behind = candidate("behind", lon: -89.8, route: route, vehicleAlong: vehicleAlong)!
        let ahead = candidate("ahead", lon: -89.0, route: route, vehicleAlong: vehicleAlong)!
        let ranked = POIRanking.rankFood([behind, ahead])
        XCTAssertEqual(ranked.map(\.item), ["ahead"], "backwards stops must be filtered")
    }

    func testExcessiveDetourIsExcluded() {
        let route = straightRoute()
        // ~0.5° of latitude ≈ 55 km off-corridor — way past the 12 km cap.
        let farOff = candidate("far", lon: -89.0, latOffset: 0.5, route: route, vehicleAlong: 0)!
        let onRoute = candidate("close", lon: -89.0, route: route, vehicleAlong: 0)!
        XCTAssertEqual(POIRanking.rankFood([farOff, onRoute]).map(\.item), ["close"])
    }

    func testFoodOrdersBySoonestReachable() {
        let route = straightRoute()
        let near = candidate("near", lon: -89.7, route: route, vehicleAlong: 0)!
        let far = candidate("far", lon: -88.8, route: route, vehicleAlong: 0)!
        XCTAssertEqual(POIRanking.rankFood([far, near]).map(\.item), ["near", "far"])
    }

    func testCheaperFuelJustifiesLongerDetour() {
        let route = straightRoute()
        // Near but expensive vs farther-up-route but much cheaper: with a
        // 15-unit fill, $0.60/unit savings ($9) outweighs the extra ~8 min
        // detour (~$4 at $30/hr).
        let nearExpensive = candidate("pricey", lon: -89.9, price: 3.80,
                                      route: route, vehicleAlong: 0)!
        let farCheap = candidate("cheap", lon: -89.0, latOffset: 0.02, price: 3.20,
                                 route: route, vehicleAlong: 0)!
        let ranked = POIRanking.rankFuel([nearExpensive, farCheap],
                                         fillUnits: 15, averagePricePerUnit: 3.50)
        XCTAssertEqual(ranked.first?.item, "cheap",
                       "significantly cheaper fuel should win despite the longer range")
    }

    func testEqualPricesFallBackToShortestDetour() {
        let route = straightRoute()
        let near = candidate("near", lon: -89.8, route: route, vehicleAlong: 0)!
        let off = candidate("off", lon: -89.8, latOffset: 0.05, route: route, vehicleAlong: 0)!
        let ranked = POIRanking.rankFuel([off, near], fillUnits: 15, averagePricePerUnit: 3.50)
        XCTAssertEqual(ranked.first?.item, "near",
                       "with no price signal, least detour time wins")
    }
}
