// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// Gates for the physical route-attribute math backing the trucker filters.
final class RouteAttributesTests: XCTestCase {

    func testMaxGradeFlatRouteIsZero() {
        XCTAssertEqual(RouteAttributes.maxGradePercent(
            elevations: [200, 200, 200], spacingMeters: 1000), 0)
    }

    func testMaxGradeDetectsClimb() {
        // 100 m rise over 1 km = 10% grade.
        let g = RouteAttributes.maxGradePercent(
            elevations: [100, 200, 250], spacingMeters: 1000)
        XCTAssertEqual(g!, 10.0, accuracy: 0.001)
    }

    func testMaxGradeSkipsMissingSamples() {
        // Pairs touching a nil sample are skipped; only 100→120 (2%) counts.
        let g = RouteAttributes.maxGradePercent(
            elevations: [100, 120, nil, 130], spacingMeters: 1000)
        XCTAssertEqual(g!, 2.0, accuracy: 0.001)
        // All-missing → unknown, not zero.
        XCTAssertNil(RouteAttributes.maxGradePercent(
            elevations: [nil, nil], spacingMeters: 1000))
    }

    func testOSMClearanceParsing() {
        XCTAssertEqual(RouteAttributes.clearanceMeters(fromOSM: "4.1")!, 4.1, accuracy: 0.001)
        XCTAssertEqual(RouteAttributes.clearanceMeters(fromOSM: "4.1 m")!, 4.1, accuracy: 0.001)
        XCTAssertEqual(RouteAttributes.clearanceMeters(fromOSM: "13'6\"")!, 4.1148, accuracy: 0.001)
        XCTAssertEqual(RouteAttributes.clearanceMeters(fromOSM: "12 ft")!, 3.6576, accuracy: 0.001)
        XCTAssertNil(RouteAttributes.clearanceMeters(fromOSM: "default"))
        XCTAssertNil(RouteAttributes.clearanceMeters(fromOSM: "tall"))
        // 11'8" — the famous can-opener bridge — must read as LOW.
        let canOpener = RouteAttributes.clearanceMeters(fromOSM: "11'8\"")!
        XCTAssertLessThan(canOpener, RouteAttributes.lowClearanceThresholdMeters)
    }

    func testOSMWeightLimitParsing() {
        // Bare numbers are metric tonnes (the OSM default); decimal commas
        // appear in the global dataset just like they do for maxheight.
        XCTAssertEqual(RouteAttributes.weightLimitLbs(fromOSM: "7.5")!, 16_534.65, accuracy: 0.1)
        XCTAssertEqual(RouteAttributes.weightLimitLbs(fromOSM: "3,5")!, 7_716.17, accuracy: 0.1)
        // Explicit units: tonnes, pounds, short tons, kilograms.
        XCTAssertEqual(RouteAttributes.weightLimitLbs(fromOSM: "7.5 t")!, 16_534.65, accuracy: 0.1)
        XCTAssertEqual(RouteAttributes.weightLimitLbs(fromOSM: "2 tonnes")!, 4_409.24, accuracy: 0.1)
        XCTAssertEqual(RouteAttributes.weightLimitLbs(fromOSM: "10000 lbs")!, 10_000, accuracy: 1e-9)
        XCTAssertEqual(RouteAttributes.weightLimitLbs(fromOSM: "5 st")!, 10_000, accuracy: 1e-9)
        XCTAssertEqual(RouteAttributes.weightLimitLbs(fromOSM: "3500 kg")!, 7_716.17, accuracy: 0.1)
        // Non-numeric signage → unknown, never a fabricated limit.
        XCTAssertNil(RouteAttributes.weightLimitLbs(fromOSM: "default"))
        XCTAssertNil(RouteAttributes.weightLimitLbs(fromOSM: "none"))
        XCTAssertNil(RouteAttributes.weightLimitLbs(fromOSM: "heavy"))
        // The relevance cap sits above the US federal interstate max — an
        // 80,000 lb posting still counts as a real restriction.
        XCTAssertLessThan(80_000, RouteAttributes.weightLimitCapLbs)
    }

    func testFEMAHighRiskZones() {
        XCTAssertTrue(RouteAttributes.isHighRiskFloodZone("AE"))
        XCTAssertTrue(RouteAttributes.isHighRiskFloodZone("A"))
        XCTAssertTrue(RouteAttributes.isHighRiskFloodZone("VE"))
        XCTAssertFalse(RouteAttributes.isHighRiskFloodZone("X"))
        XCTAssertFalse(RouteAttributes.isHighRiskFloodZone("D"))
    }
}
