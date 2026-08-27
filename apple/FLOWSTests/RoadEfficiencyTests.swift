// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// What the vehicle really gets on the roads this driver really drives —
/// measured per neighbourhood, pooled for highways, and only trusted once
/// enough miles back it.
final class RoadEfficiencyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSince1970

    private var home: TrafficArea {
        TrafficArea(CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40))
    }
    private var away: TrafficArea {
        TrafficArea(CLLocationCoordinate2D(latitude: 39.74, longitude: -104.99))
    }

    func testRatedFigureStandsUntilEnoughRoadIsMeasured() {
        var s = RoadEfficiencyStore()
        // Two miles of evidence is not enough to overrule the vehicle.
        s.record(milesDriven: 2, unitsBurned: 0.2, area: home,
                 roadClass: .local, now: t0)
        XCTAssertFalse(s.isConfident(area: home, roadClass: .local))
        XCTAssertEqual(s.economy(ratedMilesPerUnit: 30, area: home, roadClass: .local),
                       30, accuracy: 0.001)
    }

    func testLearnsThatATownIsThirstierThanTheSticker() {
        var s = RoadEfficiencyStore()
        // 60 miles of stop-and-go at a real 20 mpg on a 30 mpg car.
        for i in 0..<6 {
            s.record(milesDriven: 10, unitsBurned: 0.5, area: home,
                     roadClass: .local, now: t0 + Double(i) * 86_400)
        }
        XCTAssertTrue(s.isConfident(area: home, roadClass: .local))
        XCTAssertEqual(s.economy(ratedMilesPerUnit: 30, area: home, roadClass: .local),
                       20, accuracy: 0.5)
    }

    func testLongerStretchesCarryMoreWeightThanShortOnes() {
        var s = RoadEfficiencyStore()
        // One brief bad stretch, then a long representative one.
        s.record(milesDriven: 2, unitsBurned: 0.4, area: home,     // 5 mpg
                 roadClass: .local, now: t0)
        s.record(milesDriven: 60, unitsBurned: 2.0, area: home,    // 30 mpg
                 roadClass: .local, now: t0 + 3_600)
        let learned = s.economy(ratedMilesPerUnit: 30, area: home, roadClass: .local)
        XCTAssertGreaterThan(learned, 25, "the long stretch should dominate")
    }

    func testOneStrangeStretchCannotRewriteTheVehicle() {
        var s = RoadEfficiencyStore()
        // 40 miles of implausibly good economy (a long downhill coast).
        for i in 0..<4 {
            s.record(milesDriven: 10, unitsBurned: 0.05, area: home,   // 200 mpg
                     roadClass: .local, now: t0 + Double(i) * 3_600)
        }
        let learned = s.economy(ratedMilesPerUnit: 30, area: home, roadClass: .local)
        XCTAssertLessThanOrEqual(learned, 30 * RoadEfficiencyStore.maxRatio)
    }

    func testLocalMeasurementStaysInItsOwnNeighbourhood() {
        var s = RoadEfficiencyStore()
        for i in 0..<6 {
            s.record(milesDriven: 10, unitsBurned: 0.5, area: home,
                     roadClass: .local, now: t0 + Double(i) * 86_400)
        }
        // A town never driven in keeps the rated figure.
        XCTAssertEqual(s.economy(ratedMilesPerUnit: 30, area: away, roadClass: .local),
                       30, accuracy: 0.001)
    }

    func testHighwayMeasurementPoolsAndTransfers() {
        var s = RoadEfficiencyStore()
        for i in 0..<6 {
            s.record(milesDriven: 20, unitsBurned: 0.5, area: home,   // 40 mpg
                     roadClass: .highway, now: t0 + Double(i) * 86_400)
        }
        // A highway 800 miles away benefits from the same measurement.
        XCTAssertEqual(s.economy(ratedMilesPerUnit: 30, area: away, roadClass: .highway),
                       s.economy(ratedMilesPerUnit: 30, area: home, roadClass: .highway),
                       accuracy: 0.001)
        XCTAssertGreaterThan(
            s.economy(ratedMilesPerUnit: 30, area: away, roadClass: .highway), 30)
    }

    func testGarbageMeasurementsAreIgnored() {
        var s = RoadEfficiencyStore()
        s.record(milesDriven: 0, unitsBurned: 1, area: home, roadClass: .local, now: t0)
        s.record(milesDriven: 5, unitsBurned: 0, area: home, roadClass: .local, now: t0)
        XCTAssertTrue(s.cells.isEmpty)
    }

    func testOldMeasurementsFade() {
        var s = RoadEfficiencyStore()
        for i in 0..<6 {
            s.record(milesDriven: 10, unitsBurned: 0.5, area: home,
                     roadClass: .local, now: t0 + Double(i) * 3_600)
        }
        let before = s.cells[RoadEfficiencyStore.key(area: home, roadClass: .local)]!.weight
        s.decay(to: t0 + 720 * 24 * 3_600)   // two years on
        let after = s.cells[RoadEfficiencyStore.key(area: home, roadClass: .local)]!.weight
        XCTAssertLessThan(after, before / 8)
    }
}
