// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

// The test target compiles the app sources directly; there is no FLOWS module to import.

/// The numbers behind the distance and time readouts are computed in Rust
/// behind `TripReadouts`; the words are Swift. These hold the texts the
/// driver reads and hears, and that a number that cannot be counted no
/// longer crashes.
final class TripReadoutsTests: XCTestCase {
    private let mile = 1609.344

    func testACloseTurnReadsInFeetAndNeverZero() {
        XCTAssertEqual(TripReadouts.turnDistanceText(0), "50 ft")
        XCTAssertEqual(TripReadouts.turnDistanceText(137.16), "450 ft")
        XCTAssertEqual(TripReadouts.turnDistanceText(0.18 * mile), "950 ft")
        XCTAssertEqual(TripReadouts.turnDistanceText(0.25 * mile), "0.2 mi")
        XCTAssertEqual(TripReadouts.turnDistanceText(2.44 * mile), "2.4 mi")
        XCTAssertEqual(TripReadouts.turnDistanceText(12.3 * mile), "12 mi")
    }

    func testMilesKeepATenthBelowTen() {
        XCTAssertEqual(TripReadouts.milesText(0.5 * mile), "0.5 mi")
        // 9.96 miles is "10 mi" on a card, not "10.0 mi".
        XCTAssertEqual(TripReadouts.milesText(9.96 * mile), "10 mi")
        XCTAssertEqual(TripReadouts.plannerMilesText(9.96 * mile), "10.0 mi")
        XCTAssertEqual(TripReadouts.plannerMilesText(10.4 * mile), "10 mi")
    }

    func testATimeReadsInMinutesHoursOrDays() {
        XCTAssertEqual(TripReadouts.clockText(seconds: 45 * 60, days: false), "45 min")
        XCTAssertEqual(TripReadouts.clockText(seconds: 89 * 60, days: true), "89 min")
        XCTAssertEqual(TripReadouts.clockText(seconds: 90 * 60, days: true), "1 h 30 min")
        XCTAssertEqual(TripReadouts.clockText(seconds: 125 * 60, days: false), "2 h 05 min")
        // A multi-day walk reads in days on a card; the driving screen keeps hours.
        XCTAssertEqual(TripReadouts.clockText(seconds: 10.8 * 86_400, days: true), "10.8 days")
        XCTAssertEqual(TripReadouts.clockText(seconds: 2 * 86_400, days: false), "48 h 00 min")
        XCTAssertEqual(TripReadouts.clock(seconds: 2 * 86_400, days: true), .days(2))
    }

    func testSiriSaysOneMileWholeMilesOrTenths() {
        XCTAssertEqual(TripReadouts.spokenMiles(meters: mile), .one)
        XCTAssertEqual(TripReadouts.spokenMiles(meters: 5 * mile), .whole(5))
        XCTAssertEqual(TripReadouts.spokenMiles(meters: 640), .tenths(0.4))
        XCTAssertEqual(TripReadouts.spokenMiles(meters: 212.4 * mile), .whole(212))
    }

    func testANumberThatCannotBeCountedNeverCrashes() {
        // The Swift this replaced crashed on every one of these.
        XCTAssertEqual(TripReadouts.clockText(seconds: .nan, days: true), "0 min")
        XCTAssertEqual(TripReadouts.clock(seconds: .infinity, days: true), .days(.infinity))
        XCTAssertEqual(TripReadouts.minutes(.infinity), Int.max)
        XCTAssertEqual(TripReadouts.turnDistanceText(-.infinity), "50 ft")
        XCTAssertEqual(TripReadouts.spokenMiles(meters: .nan), .whole(0))
        XCTAssertEqual(SiriSummaries.spokenTime(seconds: .nan), "under a minute")
        XCTAssertEqual(TripReadouts.minutesSaved(from: .nan, to: 600), 1)
        XCTAssertEqual(TripReadouts.exposurePercent(coverage: .nan), 0)
        XCTAssertEqual(TripReadouts.exposureMiles(meters: .infinity, coverage: 1), Int.max)
    }

    func testMinutesSavedAndAlertShareRound() {
        XCTAssertEqual(TripReadouts.minutesSaved(from: 1_000, to: 700), 5)
        // A faster road always saves at least a minute.
        XCTAssertEqual(TripReadouts.minutesSaved(from: 1_000, to: 990), 1)
        XCTAssertEqual(TripReadouts.exposurePercent(coverage: 0.345), 35)
        XCTAssertEqual(TripReadouts.exposureMiles(meters: 100 * mile, coverage: 0.345), 35)
    }

    func testTheGradeIsTheFirstStretchThatHoldsTheMile() {
        let profile = [
            GradeSegment(startMile: 0, endMile: 1, gradePercent: 2),
            GradeSegment(startMile: 1, endMile: 2, gradePercent: -3),
            GradeSegment(startMile: 4, endMile: 5, gradePercent: 6),
        ]
        XCTAssertEqual(TripReadouts.grade(atMile: 0.5, in: profile), 2)
        // On the join, the first stretch wins.
        XCTAssertEqual(TripReadouts.grade(atMile: 1, in: profile), 2)
        XCTAssertEqual(TripReadouts.grade(atMile: 1.5, in: profile), -3)
        // Between measured stretches, and with no table, the road is level.
        XCTAssertEqual(TripReadouts.grade(atMile: 3, in: profile), 0)
        XCTAssertEqual(TripReadouts.grade(atMile: 1, in: []), 0)
    }
}
