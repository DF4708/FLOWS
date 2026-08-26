// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// The gauge's exponential color curve and the last-chance refuel warning:
/// the driver must be told while stations selling THEIR fuel are still
/// reachable — never after the last one is behind them.
final class FuelWarningTests: XCTestCase {

    private func station(_ name: String, _ miles: Double, _ price: Double? = nil)
        -> FuelWarning.Station {
        FuelWarning.Station(name: name, milesAhead: miles, pricePerUnit: price)
    }

    // MARK: gauge color

    func testGaugeStaysGreenThroughTheMiddleOfTheTank() {
        XCTAssertEqual(FuelWarning.band(fraction: 1.0), .green)
        XCTAssertEqual(FuelWarning.band(fraction: 0.75), .green)
        XCTAssertEqual(FuelWarning.band(fraction: 0.5), .green)
        XCTAssertEqual(FuelWarning.band(fraction: 0.35), .green)
    }

    func testGaugeWarnsOnlyNearEmpty() {
        XCTAssertEqual(FuelWarning.band(fraction: 0.25), .yellow)
        XCTAssertEqual(FuelWarning.band(fraction: 0.18), .yellow)
        XCTAssertEqual(FuelWarning.band(fraction: 0.10), .red)
        XCTAssertEqual(FuelWarning.band(fraction: 0.0), .red)
    }

    func testSeverityGrowsExponentiallyTowardEmpty() {
        // Losing the first quarter tank barely moves it; the last quarter
        // moves it far more — that's the whole point of the curve.
        let firstQuarter = FuelWarning.severity(fraction: 0.75)
            - FuelWarning.severity(fraction: 1.0)
        let lastQuarter = FuelWarning.severity(fraction: 0.0)
            - FuelWarning.severity(fraction: 0.25)
        XCTAssertGreaterThan(lastQuarter, firstQuarter * 4)
    }

    // MARK: reachable-station warning

    func testQuietWhilePlentyOfStationsAreReachable() {
        let stations = (1...8).map { station("Stop \($0)", Double($0) * 10) }
        // 200 mi of range, 40 mi reserve → 160 usable, 8 stations reachable.
        XCTAssertEqual(FuelWarning.level(stationsAhead: stations, rangeMiles: 200),
                       .none)
    }

    func testWarnsWhileTheLastFewAreStillInRange() {
        // The owner's case: a diesel truck with 50 miles left. Reserve is
        // 40, so only stations inside 10 mi are truly reachable.
        let stations = [station("Pilot", 4), station("Loves", 8),
                        station("TA", 40), station("Petro", 120)]
        XCTAssertEqual(FuelWarning.level(stationsAhead: stations, rangeMiles: 50),
                       .lastChances(remaining: 2))
    }

    func testWarnsBeforeTheLastStationGoesOutOfRange() {
        // Sweep the tank down: the warning must appear while at least one
        // station is still reachable, never first appearing as .unreachable.
        let stations = [station("A", 20), station("B", 45), station("C", 70)]
        var sawLastChance = false
        for range in stride(from: 140.0, through: 45.0, by: -5.0) {
            switch FuelWarning.level(stationsAhead: stations, rangeMiles: range) {
            case .lastChances: sawLastChance = true
            case .unreachable:
                XCTAssertTrue(sawLastChance,
                              "went unreachable at \(range) mi with no prior warning")
            case .none: break
            }
        }
        XCTAssertTrue(sawLastChance)
    }

    func testUnreachableWhenNothingSellsThisFuelInRange() {
        let stations = [station("Far", 300)]
        XCTAssertEqual(FuelWarning.level(stationsAhead: stations, rangeMiles: 60),
                       .unreachable)
        XCTAssertEqual(FuelWarning.level(stationsAhead: [], rangeMiles: 60),
                       .unreachable)
    }

    func testReserveIsNeverSpent() {
        // A station exactly at the range limit is NOT reachable — arriving on
        // fumes is not a plan.
        let stations = [station("Edge", 100)]
        XCTAssertEqual(FuelWarning.level(stationsAhead: stations, rangeMiles: 100),
                       .unreachable)
    }

    // MARK: which station gets recommended

    func testCheapestReachableWins() {
        let stations = [station("Near pricey", 5, 4.59),
                        station("Cheap", 8, 3.19),
                        station("Cheapest but too far", 400, 2.99)]
        let pick = FuelWarning.cheapest(stationsAhead: stations, rangeMiles: 60)
        XCTAssertEqual(pick?.name, "Cheap")
    }

    func testUnpricedStationsRankBehindPricedOnes() {
        let stations = [station("Unknown price", 3), station("Known", 9, 3.99)]
        XCTAssertEqual(FuelWarning.cheapest(stationsAhead: stations, rangeMiles: 60)?.name,
                       "Known")
    }

    func testFallsBackToNearestWhenNoPricesAreKnown() {
        let stations = [station("Farther", 9), station("Nearest", 3)]
        XCTAssertEqual(FuelWarning.cheapest(stationsAhead: stations, rangeMiles: 60)?.name,
                       "Nearest")
    }

    // MARK: what the driver hears

    func testSpokenAdviceNamesFuelPlaceAndDistance() {
        let pick = station("Loves Travel Stop", 8, 3.49)
        let spoken = FuelWarning.spokenAdvice(
            fuel: .diesel, level: .lastChances(remaining: 2),
            station: pick, rangeMiles: 50)
        XCTAssertNotNil(spoken)
        XCTAssertTrue(spoken!.contains("diesel"))
        XCTAssertTrue(spoken!.contains("Loves Travel Stop"))
        XCTAssertTrue(spoken!.contains("8 miles"))
        XCTAssertTrue(spoken!.contains("3.49"))
    }

    func testElectricSpeaksCharging() {
        let spoken = FuelWarning.spokenAdvice(
            fuel: .electric, level: .lastChances(remaining: 1),
            station: station("Supercharger", 12), rangeMiles: 60)
        XCTAssertTrue(spoken?.contains("charging") == true)
        XCTAssertFalse(spoken?.contains("gallon") == true)
    }

    func testNothingIsSaidWhenAllIsWell() {
        XCTAssertNil(FuelWarning.spokenAdvice(fuel: .gas, level: .none,
                                              station: nil, rangeMiles: 300))
        XCTAssertNil(FuelWarning.bannerText(fuel: .gas, level: .none, station: nil))
    }
}
