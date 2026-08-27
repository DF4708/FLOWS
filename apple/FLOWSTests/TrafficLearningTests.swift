// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// The on-device traffic-delay model: learns how much longer drives really
/// take by time of day and weather, and only speaks once it has earned it.
final class TrafficLearningTests: XCTestCase {

    private let noon = Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSince1970

    /// Weekday 8am rush, clear weather.
    private func rushKeyParts() -> (Int, Int) { (3, 8) }   // Tuesday, 08:00

    func testSaysNothingUntilItHasSeenEnoughTrips() {
        var s = TrafficDelayStore()
        let (wd, hr) = rushKeyParts()
        // Three bad trips is an anecdote.
        for i in 0..<3 {
            s.record(predictedSeconds: 1_800, actualSeconds: 2_700,
                     weekday: wd, hour: hr, weather: .clear,
                     now: noon + Double(i) * 86_400)
        }
        XCTAssertFalse(s.isConfident(weekday: wd, hour: hr, weather: .clear))
        XCTAssertEqual(s.factor(weekday: wd, hour: hr, weather: .clear), 1.0,
                       "an unproven cell must not move the ETA")
    }

    func testLearnsARushHourPattern() {
        var s = TrafficDelayStore()
        let (wd, hr) = rushKeyParts()
        // Six weeks of the same 50%-over commute.
        for i in 0..<6 {
            s.record(predictedSeconds: 1_800, actualSeconds: 2_700,
                     weekday: wd, hour: hr, weather: .clear,
                     now: noon + Double(i) * 7 * 86_400)
        }
        XCTAssertTrue(s.isConfident(weekday: wd, hour: hr, weather: .clear))
        XCTAssertEqual(s.factor(weekday: wd, hour: hr, weather: .clear), 1.5, accuracy: 0.05)
        // 30 predicted minutes → ~15 minutes of learned delay.
        XCTAssertEqual(s.predictedDelayMinutes(routerSeconds: 1_800, weekday: wd,
                                               hour: hr, weather: .clear), 15)
    }

    func testWeatherIsLearnedSeparatelyFromTheClock() {
        var s = TrafficDelayStore()
        let (wd, hr) = rushKeyParts()
        for i in 0..<6 {
            // Same hour, snowing: much worse.
            s.record(predictedSeconds: 1_800, actualSeconds: 3_600,
                     weekday: wd, hour: hr, weather: .snow,
                     now: noon + Double(i) * 7 * 86_400)
            // Same hour, clear: on time.
            s.record(predictedSeconds: 1_800, actualSeconds: 1_800,
                     weekday: wd, hour: hr, weather: .clear,
                     now: noon + Double(i) * 7 * 86_400)
        }
        XCTAssertGreaterThan(s.factor(weekday: wd, hour: hr, weather: .snow),
                             s.factor(weekday: wd, hour: hr, weather: .clear))
        XCTAssertEqual(s.factor(weekday: wd, hour: hr, weather: .clear), 1.0, accuracy: 0.05)
    }

    func testWeekendIsNotWeekday() {
        XCTAssertNotEqual(TrafficDelayStore.bucket(weekday: 3, hour: 8),
                          TrafficDelayStore.bucket(weekday: 1, hour: 8))
        // …and hours inside the same block share a cell.
        XCTAssertEqual(TrafficDelayStore.bucket(weekday: 3, hour: 8),
                       TrafficDelayStore.bucket(weekday: 3, hour: 9))
    }

    func testOldObservationsFadeAway() {
        var s = TrafficDelayStore()
        let (wd, hr) = rushKeyParts()
        for i in 0..<6 {
            s.record(predictedSeconds: 1_800, actualSeconds: 2_700,
                     weekday: wd, hour: hr, weather: .clear,
                     now: noon + Double(i) * 86_400)
        }
        let fresh = s.factor(weekday: wd, hour: hr, weather: .clear)
        let weightBefore = s.cells[TrafficDelayStore.key(weekday: wd, hour: hr,
                                                         weather: .clear)]!.weight
        // A year later the evidence is much lighter…
        s.decay(to: noon + 365 * 86_400)
        let weightAfter = s.cells[TrafficDelayStore.key(weekday: wd, hour: hr,
                                                        weather: .clear)]!.weight
        XCTAssertLessThan(weightAfter, weightBefore / 4)
        // …though the ratio it learned is unchanged; decay lowers influence,
        // it does not rewrite what was observed.
        XCTAssertEqual(s.factor(weekday: wd, hour: hr, weather: .clear), fresh,
                       accuracy: 0.01)
    }

    func testWildTripsCannotRunAwayWithTheEstimate() {
        var s = TrafficDelayStore()
        let (wd, hr) = rushKeyParts()
        for i in 0..<8 {
            // A closed highway: 10× the estimate.
            s.record(predictedSeconds: 600, actualSeconds: 6_000,
                     weekday: wd, hour: hr, weather: .clear,
                     now: noon + Double(i) * 86_400)
        }
        XCTAssertLessThanOrEqual(s.factor(weekday: wd, hour: hr, weather: .clear),
                                 TrafficDelayStore.maxFactor)
    }

    func testGarbageObservationsAreIgnored() {
        var s = TrafficDelayStore()
        let (wd, hr) = rushKeyParts()
        s.record(predictedSeconds: 0, actualSeconds: 900, weekday: wd, hour: hr,
                 weather: .clear, now: noon)
        s.record(predictedSeconds: 900, actualSeconds: -5, weekday: wd, hour: hr,
                 weather: .clear, now: noon)
        XCTAssertTrue(s.cells.isEmpty)
    }

    func testHazardFamiliesMapToTrafficWeather() {
        XCTAssertEqual(TrafficWeather.from(family: "winter"), .snow)
        XCTAssertEqual(TrafficWeather.from(family: "qpf_flood"), .rain)
        XCTAssertEqual(TrafficWeather.from(family: nil), .clear)
        XCTAssertEqual(TrafficWeather.from(family: "heat"), .clear)
    }
}
