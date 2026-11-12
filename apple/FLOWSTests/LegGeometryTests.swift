// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

// The test target compiles the app sources directly; there is no FLOWS module to import.

/// The road of one leg is read in Rust behind `LegGeometry`. These hold the
/// rules a driver feels: which point a fix is at, how far the turn is, when
/// the next step begins, and where a path is cut.
final class LegGeometryTests: XCTestCase {
    private func p(_ lat: Double, _ lon: Double = -90) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Points going north, a hundredth of a degree (about 1.1 km) apart.
    private func north(_ count: Int) -> [CLLocationCoordinate2D] {
        (0..<count).map { p(40 + Double($0) * 0.01) }
    }

    func testALegAddsUpItsMetersAndLeavesOutEmptySteps() {
        let road = north(5)
        let leg = LegGeometry(steps: [Array(road[0...1]), [], Array(road[2...4])])
        XCTAssertEqual(leg.points.count, 5)
        XCTAssertEqual(leg.stepEnd, [1, 4])
        XCTAssertEqual(leg.cumulative.count, 5)
        XCTAssertEqual(leg.cumulative[0], 0)
        for i in 1..<5 {
            XCTAssertEqual(
                leg.cumulative[i], leg.cumulative[i - 1] + POIRanking.meters(road[i - 1], road[i]))
        }
        XCTAssertEqual(leg.cumulative[4], 4_448, accuracy: 10)
    }

    func testALegWithNoPointsAnswersNothing() {
        for leg in [LegGeometry(steps: []), LegGeometry(steps: [[], []])] {
            XCTAssertTrue(leg.points.isEmpty)
            XCTAssertTrue(leg.cumulative.isEmpty)
            XCTAssertTrue(leg.stepEnd.isEmpty)
            XCTAssertNil(leg.match(last: 0, fix: p(40)))
            XCTAssertNil(leg.progress(nearest: 0, step: 0))
            XCTAssertNil(leg.ahead(from: 0, meters: 10))
        }
    }

    func testAFixIsMatchedInTheWindowAndOverTheWholeLegWhenLost() {
        let leg = LegGeometry(steps: [north(200)])
        // Beside point 20, with the last match at 15: inside the window.
        let near = leg.match(last: 15, fix: p(40.2001))
        XCTAssertEqual(near?.index, 20)
        XCTAssertEqual(near?.meters ?? 99, 11, accuracy: 1)
        // The vehicle rejoined far ahead: the window (up to point 94) is
        // more than 250 m off, so the whole leg is read.
        XCTAssertEqual(leg.match(last: 15, fix: p(41.5))?.index, 150)
        // Under 250 m off the window's best, the window's answer stands
        // even though a later point is nearer.
        let turned = LegGeometry(steps: [north(100) + [p(40.001)]])
        XCTAssertEqual(turned.match(last: 0, fix: p(40.0011))?.index, 0)
        // A stale index past the end reads nothing in the window and so
        // the whole leg.
        XCTAssertEqual(leg.match(last: 5_000, fix: p(40.03))?.index, 3)
        XCTAssertEqual(leg.match(last: -7, fix: p(40.03))?.index, 3)
    }

    func testProgressMovesToTheNextStepAtItsEnd() throws {
        let road = north(7)
        let leg = LegGeometry(steps: [Array(road[0...2]), Array(road[3...4]), Array(road[5...6])])
        XCTAssertEqual(leg.stepEnd, [2, 4, 6])
        let total = try XCTUnwrap(leg.cumulative.last)

        let start = try XCTUnwrap(leg.progress(nearest: 1, step: 0))
        XCTAssertEqual(start.step, 0)
        XCTAssertEqual(start.toManeuver, leg.cumulative[2] - leg.cumulative[1])
        XCTAssertEqual(start.along, leg.cumulative[1])
        XCTAssertEqual(start.remaining, total - leg.cumulative[1])
        XCTAssertEqual(start.fractionLeft, start.remaining / total)
        XCTAssertEqual(start.stepSpacing, leg.cumulative[2])

        // At the first step's last point the second step begins.
        let turn = try XCTUnwrap(leg.progress(nearest: 2, step: 0))
        XCTAssertEqual(turn.step, 1)
        XCTAssertEqual(turn.toManeuver, leg.cumulative[4] - leg.cumulative[2])
        XCTAssertEqual(turn.stepSpacing, leg.cumulative[4] - leg.cumulative[2])

        // A jump ahead moves over every step passed, never past the last.
        XCTAssertEqual(leg.progress(nearest: 6, step: 0)?.step, 2)
        XCTAssertEqual(leg.progress(nearest: 6, step: 0)?.remaining, 0)
        XCTAssertEqual(leg.progress(nearest: 6, step: 0)?.toManeuver, 0)
        // The step never moves back, and behind the turn the meters to it
        // stay at zero rather than going below.
        let behind = try XCTUnwrap(leg.progress(nearest: 3, step: 2))
        XCTAssertEqual(behind.step, 2)
        XCTAssertGreaterThan(behind.toManeuver, 0)
        XCTAssertEqual(leg.progress(nearest: 5, step: -3)?.step, 2)

        XCTAssertNil(leg.progress(nearest: 7, step: 0))
        XCTAssertNil(leg.progress(nearest: -1, step: 0))
    }

    func testALegStandingStillHasNoShareLeft() {
        let leg = LegGeometry(steps: [[p(40), p(40), p(40)]])
        XCTAssertEqual(leg.progress(nearest: 1, step: 0)?.fractionLeft, 0)
        XCTAssertEqual(leg.progress(nearest: 1, step: 0)?.remaining, 0)
    }

    func testThePointAheadIsTheFirstFarEnough() {
        let leg = LegGeometry(steps: [north(6)])
        XCTAssertEqual(leg.ahead(from: 1, meters: 0), 1)
        XCTAssertEqual(leg.ahead(from: 1, meters: 1), 2)
        XCTAssertEqual(leg.ahead(from: 1, meters: leg.cumulative[3] - leg.cumulative[1]), 3)
        XCTAssertEqual(leg.ahead(from: 1, meters: 2_500), 4)
        // The leg ends sooner: its last point.
        XCTAssertEqual(leg.ahead(from: 1, meters: 1e7), 5)
        XCTAssertNil(leg.ahead(from: 6, meters: 10))
        XCTAssertNil(leg.ahead(from: -1, meters: 10))
    }

    func testTheWaitForANewRoadDoublesToTwoMinutes() {
        XCTAssertEqual(LegGeometry.rerouteWait(failures: 1), 15)
        XCTAssertEqual(LegGeometry.rerouteWait(failures: 2), 30)
        XCTAssertEqual(LegGeometry.rerouteWait(failures: 3), 60)
        XCTAssertEqual(LegGeometry.rerouteWait(failures: 4), 120)
        XCTAssertEqual(LegGeometry.rerouteWait(failures: 9), 120)
        XCTAssertEqual(LegGeometry.rerouteWait(failures: 5_000), 120)
    }

    func testSteepSignsStandAtTheMiddleOfStretchesOfSixPercent() throws {
        let road = north(11)
        let miles = try XCTUnwrap(LegGeometry(steps: [road]).cumulative.last) / 1609.344
        func stretch(_ from: Double, _ to: Double, _ grade: Double) -> GradeSegment {
            GradeSegment(startMile: miles * from, endMile: miles * to, gradePercent: grade)
        }
        let marks = LegGeometry.steepMarkerIndices(
            road,
            profile: [
                stretch(0, 0.2, 5.9), stretch(0.2, 0.45, 6), stretch(0.45, 0.6, -8), stretch(0.6, 1, 2),
            ])
        // Middles at 3.25 and 5.25 hops, off any point: the sign stands on the next one.
        XCTAssertEqual(marks.map(\.index), [4, 6])
        XCTAssertEqual(marks.map(\.gradePercent), [6, -8])
        // A stretch at the very start still stands past the first point.
        XCTAssertEqual(
            LegGeometry.steepMarkerIndices(road, profile: [stretch(0, 0, 9)]).map(\.index), [1])
        // Twelve signs at most.
        let many = (0..<20).map { stretch(Double($0) / 20, Double($0 + 1) / 20, 7) }
        XCTAssertEqual(LegGeometry.steepMarkerIndices(road, profile: many).count, 12)
        XCTAssertTrue(LegGeometry.steepMarkerIndices(road, profile: []).isEmpty)
        XCTAssertTrue(LegGeometry.steepMarkerIndices([road[0]], profile: many).isEmpty)
    }

    func testAPathIsCutAtHalfItsLength() {
        // One long hop: the cut is inside it, at its middle.
        guard case .between(let before, let lat, let lon) = LegGeometry.cut([p(40), p(40.02)]) else {
            return XCTFail("a path with length is cut between two points")
        }
        XCTAssertEqual(before, 1)
        XCTAssertEqual(lat, 40.01, accuracy: 1e-9)
        XCTAssertEqual(lon, -90)
        // A short hop and then a long one: the half falls in the second.
        guard case .between(let second, let mid, _) = LegGeometry.cut([p(40), p(40.01), p(40.05)])
        else { return XCTFail("a path with length is cut between two points") }
        XCTAssertEqual(second, 2)
        XCTAssertEqual(mid, 40.025, accuracy: 1e-6)
        // A path standing still is cut at its first hop, on the spot.
        XCTAssertEqual(
            LegGeometry.cut([p(40), p(40), p(40), p(40)]),
            .between(before: 1, midLatitude: 40, midLongitude: -90))
        // A path whose meters are not numbers is halved by its points.
        XCTAssertEqual(LegGeometry.cut(Array(repeating: p(.nan), count: 4)), .at(2))
        XCTAssertEqual(LegGeometry.cut([p(40)]), .whole)
        XCTAssertEqual(LegGeometry.cut([]), .whole)
    }

    func testCheckPointsStandWhereTheMetersSinceTheLastReachTheSpacing() {
        let road = north(10)  // hops of about 1,112 m
        XCTAssertEqual(LegGeometry.checkPointIndices(road, everyMeters: 2_000), [2, 4, 6, 8])
        XCTAssertEqual(LegGeometry.checkPointIndices(road, everyMeters: 1_000), Array(1...9))
        // A spacing longer than the road: no cuts (the ends are check
        // points already), not the plain even cut.
        XCTAssertEqual(LegGeometry.checkPointIndices(road, everyMeters: 1e7), [])
        XCTAssertEqual(LegGeometry.checkPointIndices([road[0]], everyMeters: 10), [])
        XCTAssertEqual(LegGeometry.checkPointIndices([], everyMeters: 10), [])
    }
}
