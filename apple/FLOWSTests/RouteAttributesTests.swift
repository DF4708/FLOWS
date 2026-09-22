// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
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
        // Bare ton/tons is US signage — SHORT tons, never metric (a metric
        // read was ~10% too permissive on a safety limit).
        XCTAssertEqual(RouteAttributes.weightLimitLbs(fromOSM: "10 tons")!, 20_000, accuracy: 0.1)
        XCTAssertEqual(RouteAttributes.weightLimitLbs(fromOSM: "3 ton")!, 6_000, accuracy: 0.1)
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

    /// `n` points `step` metres apart heading north (bearing 0) or east (90).
    private func line(from start: CLLocationCoordinate2D, bearing: Double, count: Int,
                      step: Double) -> [CLLocationCoordinate2D] {
        let mLon = 111_320.0 * cos(start.latitude * .pi / 180)
        return (0..<count).map { i in
            let d = Double(i) * step
            return CLLocationCoordinate2D(
                latitude: start.latitude + d * cos(bearing * .pi / 180) / 111_320,
                longitude: start.longitude + d * sin(bearing * .pi / 180) / mLon)
        }
    }

    /// A downtown finish: the route's last kilometre runs north past a
    /// parking garage whose 6'5" bar sits a few metres off the street. Only
    /// the low bridge the route itself drives under restricts it.
    func testOnlyLimitsOnTheRoadTheRouteDrivesCount() {
        let start = CLLocationCoordinate2D(latitude: 43.04, longitude: -87.91)
        let route = line(from: start, bearing: 0, count: 11, step: 100)
        let bridge = PostedLimit(value: 3.9, line: Array(route[3...4]), tags: ["highway": "primary"])
        let garageEntrance = PostedLimit(
            value: 1.96, line: Array(route[7...8]),
            tags: ["highway": "service", "service": "parking_aisle"])
        let garage = PostedLimit(value: 1.96, line: Array(route[5...6]), tags: ["amenity": "parking"])
        let crossing = PostedLimit(
            value: 3.2,
            line: line(from: CLLocationCoordinate2D(latitude: route[2].latitude,
                                                    longitude: start.longitude - 0.002),
                       bearing: 90, count: 3, step: 100),
            tags: ["highway": "residential"])
        XCTAssertEqual(RouteAttributes.onRoute([bridge, garageEntrance, garage, crossing],
                                               route: route),
                       [true, false, false, false])
        // Nothing to judge: no limits, or a route too short to have a line.
        XCTAssertEqual(RouteAttributes.onRoute([], route: route), [])
        XCTAssertEqual(RouteAttributes.onRoute([bridge], route: [start]), [false])
        // A limit whose road came back with no line can't be placed on the route.
        let lineless = PostedLimit(value: 3.9, line: [], tags: ["highway": "primary"])
        XCTAssertEqual(RouteAttributes.onRoute([lineless, bridge], route: route), [false, true])
    }
}
