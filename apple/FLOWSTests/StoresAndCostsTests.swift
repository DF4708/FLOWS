// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// Stores ranking (Yelp rating desc → market share → corridor) and the trip
/// cost/CO₂ estimates behind the Cheapest / Efficient banners.
final class StoresAndCostsTests: XCTestCase {

    // Market-share fallback: Walmart is the biggest national brand; Target is
    // recognized but smaller; a local shop sorts after every known brand.
    func testMarketShareOrder() {
        let walmart = POIRanking.storeMarketShareRank(name: "Walmart Supercenter")
        let target = POIRanking.storeMarketShareRank(name: "Target")
        let homeDepot = POIRanking.storeMarketShareRank(name: "The Home Depot")
        let local = POIRanking.storeMarketShareRank(name: "Bob's Bait & Tackle")
        XCTAssertLessThan(walmart, target, "Walmart outranks Target on market share")
        XCTAssertLessThan(homeDepot, target)
        XCTAssertGreaterThan(local, target, "unknown local brands sort after national ones")
        XCTAssertEqual(POIRanking.storeMarketShareRank(name: nil),
                       POIRanking.storeMarketShareOrder.count)
    }

    // Ranking: rated stores first (highest rating first); unrated stores follow
    // by market share; corridor position breaks remaining ties.
    func testRankStoresOrdering() {
        func cand(_ name: String, rating: Double?, ahead: Double)
            -> POIRanking.Candidate<String> {
            POIRanking.Candidate(item: name,
                                 coordinate: CLLocationCoordinate2D(latitude: 43, longitude: -89),
                                 aheadMeters: ahead, detourMeters: 500,
                                 pricePerUnit: nil, rating: rating)
        }
        let ranked = POIRanking.rankStores([
            cand("Bob's Electronics", rating: 4.9, ahead: 9_000),
            cand("Best Buy", rating: 4.0, ahead: 2_000),
            cand("Walmart Supercenter", rating: nil, ahead: 8_000),
            cand("Target", rating: nil, ahead: 1_000),
            cand("Corner Store", rating: nil, ahead: 500),
        ], name: { $0 })
        XCTAssertEqual(ranked.map(\.item),
                       ["Bob's Electronics",       // 4.9★ beats everything
                        "Best Buy",                // 4.0★ next
                        "Walmart Supercenter",     // unrated: biggest brand first…
                        "Target",                  // …then Target,
                        "Corner Store"])           // …then unknown local
    }

    // Store categories all carry a usable query + symbol.
    func testStoreCategoriesComplete() {
        for c in StoreCategory.allCases {
            XCTAssertFalse(c.searchQuery.isEmpty)
            XCTAssertFalse(c.symbol.isEmpty)
        }
        XCTAssertTrue(StoreCategory.allCases.map(\.rawValue).contains("Grocery"))
        XCTAssertTrue(StoreCategory.allCases.map(\.rawValue).contains("Gun"))
    }

    // AAA "Current Avg." row parse: Regular is gas, 4th column is diesel;
    // malformed pages return nil instead of garbage.
    func testAAACurrentAvgParse() {
        let html = """
        <thead><th>Regular</th><th>Mid</th><th>Premium</th><th>Diesel</th></thead>
        <tbody><tr><td>Current Avg.</td>
        <td>$3.6840</td><td>$4.2100</td><td>$4.8310</td><td>$4.5810</td></tr>
        <tr><td>Yesterday Avg.</td><td>$3.5950</td></tr>
        """
        let parsed = AAAFuelPrices.parseCurrentAvg(html)
        XCTAssertEqual(parsed?.gas ?? 0, 3.684, accuracy: 1e-9)
        XCTAssertEqual(parsed?.diesel ?? 0, 4.581, accuracy: 1e-9)
        XCTAssertNil(AAAFuelPrices.parseCurrentAvg("<html>no table here</html>"))
        XCTAssertNil(AAAFuelPrices.parseCurrentAvg("Current Avg. $3.10 only-one-price"))
    }

    // Fuel cost math: 300 mi at 30 mpg × $3.00 = $30; degenerate inputs → nil.
    func testDriveFuelCost() {
        XCTAssertEqual(TripCosts.driveFuelCostUSD(miles: 300, milesPerUnit: 30,
                                                  pricePerUnit: 3.0)!,
                       30, accuracy: 1e-9)
        XCTAssertNil(TripCosts.driveFuelCostUSD(miles: 300, milesPerUnit: 0,
                                                pricePerUnit: 3.0))
        XCTAssertNil(TripCosts.driveFuelCostUSD(miles: .nan, milesPerUnit: 30,
                                                pricePerUnit: 3.0))
    }

    // CO₂: a 25-mpg gas car ≈ 355 g/mi; transit per-passenger-mile beats it.
    func testCO2PerMile() {
        let car = TripCosts.driveGramsCO2PerMile(fuel: .gas, milesPerUnit: 25)!
        XCTAssertEqual(car, 8_887 / 25, accuracy: 1e-9)
        XCTAssertLessThan(TripCosts.transitGramsCO2PerMile(rail: true, longHaul: false), car)
        XCTAssertLessThan(TripCosts.transitGramsCO2PerMile(rail: false, longHaul: true), car)
        // A very efficient EV (4 mi/kWh ≈ 97 g/mi) edges the local-bus average
        // (105 g/mi) — but a mid EV (3.5 → 111 g/mi) does NOT: the model keeps
        // that honest instead of assuming "EV always wins".
        let efficientEV = TripCosts.driveGramsCO2PerMile(fuel: .electric, milesPerUnit: 4.0)!
        let midEV = TripCosts.driveGramsCO2PerMile(fuel: .electric, milesPerUnit: 3.5)!
        XCTAssertLessThan(efficientEV, TripCosts.transitGramsCO2PerMile(rail: false, longHaul: false))
        XCTAssertGreaterThan(midEV, TripCosts.transitGramsCO2PerMile(rail: false, longHaul: false))
    }
}
