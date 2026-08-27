// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// The speed bar's two warning lines and the efficiency icon that leads it.
final class SpeedBarTests: XCTestCase {

    // MARK: where the lines sit

    func testYellowLineIsTheStateViolation() {
        // Posted 55: the yellow line sits just past it, allowing for the
        // slack every speedometer and every trooper allows.
        XCTAssertEqual(SpeedLaw.stateThresholdMph(postedLimitMph: 55), 60)
        XCTAssertEqual(SpeedLaw.standing(speedMph: 57, postedLimitMph: 55), .legal)
        XCTAssertEqual(SpeedLaw.standing(speedMph: 62, postedLimitMph: 55), .stateViolation)
    }

    func testRedLineIsGrossExcessNotOnePastTheLimit() {
        // 20 over is where a citation becomes reckless/excessive speed.
        XCTAssertEqual(SpeedLaw.federalThresholdMph(postedLimitMph: 55), 75)
        XCTAssertEqual(SpeedLaw.standing(speedMph: 74, postedLimitMph: 55), .stateViolation)
        XCTAssertEqual(SpeedLaw.standing(speedMph: 76, postedLimitMph: 55), .federalViolation)
    }

    func testRedLineHasAnAbsoluteCeiling() {
        // On a 75 mph interstate, 20 over would be 95 — the absolute
        // excessive-speed floor catches it first.
        XCTAssertEqual(SpeedLaw.federalThresholdMph(postedLimitMph: 75),
                       SpeedLaw.excessAbsoluteMph)
    }

    func testNothingPostedMeansNothingViolated() {
        // The app must never accuse a driver on the strength of missing data.
        XCTAssertNil(SpeedLaw.stateThresholdMph(postedLimitMph: nil))
        XCTAssertNil(SpeedLaw.federalThresholdMph(postedLimitMph: nil))
        XCTAssertEqual(SpeedLaw.standing(speedMph: 100, postedLimitMph: nil), .legal)
    }

    // MARK: the bar itself

    func testBarTopUsesTheVehicleThenFallsBack() {
        XCTAssertEqual(SpeedLaw.barTopMph(vehicleTopSpeedMph: 95), 95)
        XCTAssertEqual(SpeedLaw.barTopMph(vehicleTopSpeedMph: nil),
                       SpeedLaw.defaultTopSpeedMph)
        // A nonsense figure falls back rather than drawing a 5 mph bar.
        XCTAssertEqual(SpeedLaw.barTopMph(vehicleTopSpeedMph: 3),
                       SpeedLaw.defaultTopSpeedMph)
    }

    func testThresholdsPlaceAlongTheBarAndDropOffTheEnd() {
        XCTAssertEqual(SpeedLaw.barFraction(60, topMph: 120)!, 0.5, accuracy: 0.001)
        // A line past the vehicle's top speed simply isn't drawn.
        XCTAssertNil(SpeedLaw.barFraction(150, topMph: 120))
        XCTAssertNil(SpeedLaw.barFraction(nil, topMph: 120))
    }

    // MARK: the scale follows the driving

    func testScaleShrinksSoTheBarIsNotMostlyEmpty() {
        // Crawling a 25 mph street: a 120 mph scale would leave the fill a
        // sliver. The bar tightens to its own floor instead.
        let top = SpeedLaw.dynamicTopMph(speedMph: 22, postedLimitMph: 25,
                                         vehicleTopSpeedMph: 120)
        XCTAssertLessThanOrEqual(top, 60)
        XCTAssertGreaterThanOrEqual(top, SpeedLaw.minTopMph)
    }

    func testScaleGrowsToKeepSpeedAndBothLinesInView() {
        // 80 mph on a 65 road: current speed, the yellow line (70) and the
        // red line (85) must all still be on the bar.
        let top = SpeedLaw.dynamicTopMph(speedMph: 80, postedLimitMph: 65,
                                         vehicleTopSpeedMph: 120)
        XCTAssertNotNil(SpeedLaw.barFraction(80, topMph: top))
        XCTAssertNotNil(SpeedLaw.barFraction(
            SpeedLaw.stateThresholdMph(postedLimitMph: 65), topMph: top))
        XCTAssertNotNil(SpeedLaw.barFraction(
            SpeedLaw.federalThresholdMph(postedLimitMph: 65), topMph: top))
    }

    func testScaleNeverExceedsTheVehiclesOwnMaximum() {
        let top = SpeedLaw.dynamicTopMph(speedMph: 100, postedLimitMph: 75,
                                         vehicleTopSpeedMph: 85)
        XCTAssertEqual(top, 85)
    }

    func testScaleRoundsToACleanTenSoTheNumberStopsFlickering() {
        for speed in stride(from: 40.0, through: 48.0, by: 1.0) {
            let top = SpeedLaw.dynamicTopMph(speedMph: speed, postedLimitMph: nil,
                                             vehicleTopSpeedMph: 120)
            XCTAssertEqual(top.truncatingRemainder(dividingBy: 10), 0)
        }
    }

    func testStoppedVehicleStillGetsAUsableScale() {
        let top = SpeedLaw.dynamicTopMph(speedMph: 0, postedLimitMph: nil,
                                         vehicleTopSpeedMph: 120)
        XCTAssertEqual(top, SpeedLaw.minTopMph)
    }

    // MARK: the compass reading

    func testCardinalNames() {
        XCTAssertEqual(CompassReading.cardinal(0), "N")
        XCTAssertEqual(CompassReading.cardinal(90), "E")
        XCTAssertEqual(CompassReading.cardinal(180), "S")
        XCTAssertEqual(CompassReading.cardinal(270), "W")
        XCTAssertEqual(CompassReading.cardinal(315), "NW")
        // Wraps cleanly rather than falling off the end of the table.
        XCTAssertEqual(CompassReading.cardinal(359), "N")
    }

    func testHeadingsAreNormalizedIncludingTheNoCourseSentinel() {
        XCTAssertEqual(CompassReading.normalized(-1), 359)
        XCTAssertEqual(CompassReading.normalized(370), 10)
        XCTAssertEqual(CompassReading.label(90), "90° E")
    }

    // MARK: the leading efficiency icon

    func testSteadyLegalCruiseEarnsTheLeaf() {
        XCTAssertEqual(DriveEfficiency.verdict(speedMph: 55, accelMphPerSec: 0,
                                               gradePercent: 0), .efficient)
    }

    func testHardThrottleIsWasteful() {
        XCTAssertEqual(DriveEfficiency.verdict(speedMph: 40, accelMphPerSec: 4,
                                               gradePercent: 0), .wasteful)
    }

    func testHighSpeedDragIsWasteful() {
        // Drag rises with the square of speed — 95 on the flat is not thrifty.
        XCTAssertEqual(DriveEfficiency.verdict(speedMph: 95, accelMphPerSec: 0,
                                               gradePercent: 0), .wasteful)
    }

    func testClimbingIsJudgedDifferentlyFromTheFlat() {
        // The same 65 mph is not the same act: holding it on the flat is
        // fine, dragging the vehicle up a 6% grade at that speed is not.
        XCTAssertNotEqual(DriveEfficiency.verdict(speedMph: 65, accelMphPerSec: 0,
                                                  gradePercent: 0), .wasteful)
        XCTAssertEqual(DriveEfficiency.verdict(speedMph: 65, accelMphPerSec: 0,
                                               gradePercent: 6), .wasteful)
        XCTAssertLessThan(
            DriveEfficiency.score(speedMph: 65, accelMphPerSec: 0, gradePercent: 0),
            DriveEfficiency.score(speedMph: 65, accelMphPerSec: 0, gradePercent: 6))
    }

    func testGentleDescentAndCoastingEarnCredit() {
        XCTAssertLessThan(DriveEfficiency.gradePenalty(gradePercent: -4), 0)
        XCTAssertLessThan(DriveEfficiency.throttlePenalty(accelMphPerSec: -2), 0)
        // …but the credit is capped: coasting downhill is not free range.
        XCTAssertGreaterThan(DriveEfficiency.gradePenalty(gradePercent: -50), -0.5)
    }

    func testIdlingIsAlwaysWasteful() {
        XCTAssertEqual(DriveEfficiency.verdict(speedMph: 0, accelMphPerSec: 0,
                                               gradePercent: 0), .wasteful)
        // …but pulling away from the light is not.
        XCTAssertNotEqual(DriveEfficiency.verdict(speedMph: 1, accelMphPerSec: 1.5,
                                                  gradePercent: 0), .wasteful)
    }
}
