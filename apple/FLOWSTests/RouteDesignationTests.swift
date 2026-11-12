// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

// The test target compiles the app sources directly; there is no FLOWS module to import.

/// The route chips are decided in Rust behind `SafestRoute`, `FastestRoute`,
/// `CheapestRoute`, `EfficientRoute` and `TruckerDesignation`. The last three
/// have their rules pinned in RoutePlanningRulesTests; these hold "Safest",
/// the time behind the fastest, and that a pick names the right route by id.
final class RouteDesignationTests: XCTestCase {
    private func safe(_ risk: Double, scored: Bool = true) -> SafestRoute.Candidate {
        SafestRoute.Candidate(id: UUID(), risk: risk, scored: scored)
    }

    func testSafestIsTheLowestRiskOnceEveryRouteIsScored() {
        let c = [safe(0.5), safe(0.25), safe(0.75)]
        XCTAssertEqual(SafestRoute.pick(c), c[1].id)
        // The first of equal lowest.
        let tie = [safe(0.25), safe(0.25), safe(0.75)]
        XCTAssertEqual(SafestRoute.pick(tie), tie[0].id)
    }

    func testNoRouteIsSafestWhenTheyAreAllTheSame() {
        // A clear day, every route 0.
        XCTAssertNil(SafestRoute.pick([safe(0), safe(0), safe(0)]))
        XCTAssertNil(SafestRoute.pick([safe(0.4), safe(0.4)]))
    }

    func testSafestWaitsForEveryRouteAndNeedsTwo() {
        XCTAssertNil(SafestRoute.pick([safe(0.5), safe(0.25, scored: false)]))
        XCTAssertNil(SafestRoute.pick([safe(0.5)]))
        XCTAssertNil(SafestRoute.pick([]))
    }

    func testTheFastestETAIsTheShortestOnOffer() {
        XCTAssertEqual(FastestRoute.eta([300, 200, 250]), 200)
        XCTAssertEqual(FastestRoute.eta([42]), 42)
        XCTAssertNil(FastestRoute.eta([]))
    }

    func testOnlyTheFastestRouteSaysFastest() {
        XCTAssertNil(FastestRoute.chipMinutes(eta: 200, fastest: 200))
        // 29 seconds slower is not "Fastest": it is a minute behind.
        XCTAssertEqual(FastestRoute.chipMinutes(eta: 229, fastest: 200), 1)
        XCTAssertEqual(FastestRoute.chipMinutes(eta: 290, fastest: 200), 2)
        XCTAssertEqual(FastestRoute.chipMinutes(eta: 3_800, fastest: 200), 60)
    }

    func testAnETAThatCannotBeCountedNeverCrashesOrSaysFastest() {
        // The Swift this replaced crashed on an endless ETA.
        XCTAssertEqual(FastestRoute.chipMinutes(eta: .infinity, fastest: 200), Int.max)
        XCTAssertEqual(FastestRoute.keyPointMinutes(eta: .infinity, fastest: 200), Int.max)
        XCTAssertNil(FastestRoute.chipMinutes(eta: .nan, fastest: 200))
        XCTAssertNil(FastestRoute.keyPointMinutes(eta: .nan, fastest: 200))
    }

    func testTheKeyPointNeedsMoreThanAMinuteBehind() {
        XCTAssertNil(FastestRoute.keyPointMinutes(eta: 260, fastest: 200))
        XCTAssertEqual(FastestRoute.keyPointMinutes(eta: 261, fastest: 200), 1)
        XCTAssertEqual(FastestRoute.keyPointMinutes(eta: 350, fastest: 200), 2)
    }

    func testEveryPickNamesItsRouteByID() {
        let cheap = [
            CheapestRoute.Candidate(id: UUID(), fuelUSD: 12, hasTolls: false),
            CheapestRoute.Candidate(id: UUID(), fuelUSD: 10, hasTolls: false),
        ]
        XCTAssertEqual(CheapestRoute.pick(cheap), cheap[1].id)
        XCTAssertNil(CheapestRoute.pick([]))
        let short = [
            EfficientRoute.Candidate(id: UUID(), meters: 9_000),
            EfficientRoute.Candidate(id: UUID(), meters: 7_000),
        ]
        XCTAssertEqual(EfficientRoute.pick(short), short[1].id)
        XCTAssertNil(EfficientRoute.pick([]))
        // The better-scoring road cannot clear a known low bridge: the other wears the badge.
        let trucks = [
            TruckerDesignation.Candidate(
                id: UUID(), clearsBridges: false, hasHighways: true, avoidsHighways: false, gradeOK: true,
                windOK: true, eta: 100),
            TruckerDesignation.Candidate(
                id: UUID(), clearsBridges: true, hasHighways: false, avoidsHighways: false, gradeOK: true,
                windOK: true, eta: 200),
        ]
        XCTAssertEqual(TruckerDesignation.pick(trucks), trucks[1].id)
        XCTAssertNil(TruckerDesignation.pick([trucks[0]]))
        XCTAssertNil(TruckerDesignation.pick([]))
        XCTAssertEqual(TruckerDesignation.score(trucks[0]), 6)
        XCTAssertEqual(CheapestRoute.tollAllowanceUSD, 5)
    }
}
