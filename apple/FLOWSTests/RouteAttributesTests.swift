// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
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

    func testFEMAHighRiskZones() {
        XCTAssertTrue(RouteAttributes.isHighRiskFloodZone("AE"))
        XCTAssertTrue(RouteAttributes.isHighRiskFloodZone("A"))
        XCTAssertTrue(RouteAttributes.isHighRiskFloodZone("VE"))
        XCTAssertFalse(RouteAttributes.isHighRiskFloodZone("X"))
        XCTAssertFalse(RouteAttributes.isHighRiskFloodZone("D"))
    }
}
