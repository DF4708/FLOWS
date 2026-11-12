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

/// The live corridor watch's rules run in Rust behind `CorridorWatchRules`.
/// These hold what the watch must do through the Swift the app calls: look
/// about half an hour ahead, never stop watching when its window cannot be
/// placed, and repaint only the check points a pass really changed.
final class CorridorWatchRulesTests: XCTestCase {
    private func mark(
        _ lat: Double, _ risk: Double, _ event: String? = nil, _ id: String? = nil
    ) -> CorridorWatchRules.Mark {
        CorridorWatchRules.Mark(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: -90), risk: risk,
            worstEvent: event, alertID: id)
    }

    func testTheWindowIsHalfAnHourOfTravelBetween5And150Km() {
        var w = CorridorWatchRules.window(speed: 0)
        XCTAssertEqual(w.lookahead, 5_000)
        XCTAssertEqual(w.cadence, 300)
        w = CorridorWatchRules.window(speed: 3.5)
        XCTAssertEqual(w.lookahead, 6_300)
        XCTAssertEqual(w.cadence, 180)
        w = CorridorWatchRules.window(speed: 30)
        XCTAssertEqual(w.lookahead, 54_000)
        XCTAssertEqual(w.cadence, 120)
        w = CorridorWatchRules.window(speed: 200)
        XCTAssertEqual(w.lookahead, 150_000)
        // A speed the device reports as "unknown" (-1) is the walking window.
        w = CorridorWatchRules.window(speed: -1)
        XCTAssertEqual(w.lookahead, 5_000)
        XCTAssertEqual(w.cadence, 300)
    }

    func testASliceRunsFromTheVehicleToOneCheckPointPastTheLookahead() {
        // 10 check points 40 km apart; the vehicle 100 km in, looking 54 km.
        let s = CorridorWatchRules.slice(
            count: 10, spacing: 40_000, along: 100_000, lookahead: 54_000, secondsPerMeter: 0.04)
        XCTAssertTrue(s.ranged)
        XCTAssertEqual(s.lo, 2)
        XCTAssertEqual(s.hi, 4)
        // The check point behind the vehicle is "now"; the next are 20 km and 60 km ahead.
        XCTAssertEqual(s.offsets, [0, 800, 2_400])
    }

    func testASliceStopsAtTheRouteEnd() {
        let s = CorridorWatchRules.slice(
            count: 3, spacing: 40_000, along: 0, lookahead: .greatestFiniteMagnitude, secondsPerMeter: 1)
        XCTAssertTrue(s.ranged)
        XCTAssertEqual(s.lo, 0)
        XCTAssertEqual(s.hi, 2)
        XCTAssertEqual(s.offsets, [0, 40_000, 80_000])
    }

    func testAWindowThatCannotBePlacedWatchesEveryCheckPoint() {
        // A position that is not a number crashed the Swift this replaced.
        let nan = CorridorWatchRules.slice(
            count: 5, spacing: 40_000, along: .nan, lookahead: 5_000, secondsPerMeter: 1)
        XCTAssertFalse(nan.ranged)
        XCTAssertEqual(nan.offsets, [0, 0, 0, 0, 0])
        // A backwards window.
        let back = CorridorWatchRules.slice(
            count: 5, spacing: 40_000, along: 120_000, lookahead: -100_000, secondsPerMeter: 1)
        XCTAssertFalse(back.ranged)
        XCTAssertEqual(back.offsets.count, 5)
        // No check points at all.
        let none = CorridorWatchRules.slice(
            count: 0, spacing: 40_000, along: 0, lookahead: 5_000, secondsPerMeter: 1)
        XCTAssertFalse(none.ranged)
        XCTAssertTrue(none.offsets.isEmpty)
    }

    func testAReadingIsThePlainMeanAndTheFirstWorst() {
        XCTAssertEqual(
            CorridorWatchRules.reading([]), CorridorWatchRules.Reading(mean: 0, peak: 0, peakIndex: nil))
        let r = CorridorWatchRules.reading([0.25, 0.75, 0.5, 0.75])
        XCTAssertEqual(r.mean, 0.5625)
        XCTAssertEqual(r.peak, 0.75)
        XCTAssertEqual(r.peakIndex, 1)
    }

    func testAPassRepaintsTheCheckPointItSitsOnWhenRiskOrAlertMoved() {
        let route = [mark(43.0, 0.25), mark(43.4, 0.25), mark(43.8, 0.25), mark(44.2, 0.25, "Flood Warning", "a")]
        let window = [
            // Same place, risk up: repaints.
            mark(43.0, 0.5),
            // Same place, risk moved 0.01, same alert: stays.
            mark(43.4, 0.26),
            // Same place, same risk, new alert: repaints.
            mark(43.8, 0.25, "Tornado Warning", "b"),
            // 1.1 km from any check point: belongs to none.
            mark(43.41, 0.9, "Tornado Warning", "b"),
            // Same place, same risk, same event under a new id: repaints.
            mark(44.2, 0.25, "Flood Warning", "c"),
        ]
        XCTAssertEqual(CorridorWatchRules.fold(route: route, window: window), [0, nil, 2, 4])
    }

    func testAnAlertThatIsOnlyNilVersusEmptyStillCountsAsChanged() {
        // nil and "" are different alerts, as they were for the Swift this replaced.
        let route = [mark(43.0, 0.25, nil, nil)]
        XCTAssertEqual(CorridorWatchRules.fold(route: route, window: [mark(43.0, 0.25, "", nil)]), [0])
        XCTAssertEqual(CorridorWatchRules.fold(route: route, window: [mark(43.0, 0.25, nil, nil)]), [nil])
    }

    func testALaterWindowPointReadsWhatAnEarlierOneRepainted() {
        let route = [mark(43.0, 0.25)]
        // The second is within the margin of the FIRST's value, not of the route's: the first is the source.
        XCTAssertEqual(
            CorridorWatchRules.fold(route: route, window: [mark(43.0, 0.5), mark(43.0, 0.51)]), [0])
        // The second moves on again: it is the source.
        XCTAssertEqual(
            CorridorWatchRules.fold(route: route, window: [mark(43.0, 0.5), mark(43.0, 0.75)]), [1])
    }

    func testAnEmptyRouteOrPassRepaintsNothing() {
        XCTAssertEqual(CorridorWatchRules.fold(route: [], window: [mark(43.0, 0.5)]), [])
        XCTAssertEqual(CorridorWatchRules.fold(route: [mark(43.0, 0.25)], window: []), [nil])
    }

    func testPaceAndAverageSpeed() {
        XCTAssertEqual(CorridorWatchRules.secondsPerMeter(eta: 3_600, distanceMeters: 100_000), 0.036)
        XCTAssertEqual(CorridorWatchRules.secondsPerMeter(eta: 3_600, distanceMeters: 0), 3_600)
        XCTAssertEqual(CorridorWatchRules.averageMph(distanceMeters: 1_609.344 * 60, eta: 3_600), 60)
        XCTAssertEqual(CorridorWatchRules.averageMph(distanceMeters: 5_000, eta: 0), 30)
        XCTAssertEqual(CorridorWatchRules.matchMeters, 600)
        XCTAssertEqual(CorridorWatchRules.repaintMargin, 0.02)
    }
}
