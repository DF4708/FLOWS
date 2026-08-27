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

    // MARK: the scale zooms with the driving

    func testScaleTightensAtTownSpeeds() {
        // Crawling a 25 mph street: the bar reads in tens near the driving,
        // not a mostly-empty 120.
        let top = SpeedLaw.dynamicTopMph(speedMph: 28, postedLimitMph: 25,
                                         vehicleTopSpeedMph: nil)
        XCTAssertLessThanOrEqual(top, 60)
        XCTAssertEqual(top.truncatingRemainder(dividingBy: 10), 0)
    }

    func testScaleStepsUpAtHighwaySpeeds() {
        let town = SpeedLaw.dynamicTopMph(speedMph: 28, postedLimitMph: 25,
                                          vehicleTopSpeedMph: nil)
        let highway = SpeedLaw.dynamicTopMph(speedMph: 75, postedLimitMph: 70,
                                             vehicleTopSpeedMph: nil)
        XCTAssertGreaterThan(highway, town)
        XCTAssertEqual(highway.truncatingRemainder(dividingBy: 10), 0)
    }

    func testScaleNeverExceedsTheVehiclesTopSpeed() {
        // Even flat out, and even where the excessive-speed line sits above
        // what the vehicle can do, the bar stops at the vehicle's maximum.
        XCTAssertEqual(SpeedLaw.dynamicTopMph(speedMph: 200, postedLimitMph: 75,
                                              vehicleTopSpeedMph: 85), 85)
        XCTAssertEqual(SpeedLaw.dynamicTopMph(speedMph: 200, postedLimitMph: nil,
                                              vehicleTopSpeedMph: nil),
                       SpeedLaw.defaultTopSpeedMph)
    }

    func testScaleAlwaysKeepsSpeedAndBothLinesInView() {
        // Sweep a whole drive: at every speed, all three must be on the bar.
        for speed in stride(from: 0.0, through: 110.0, by: 5.0) {
            let top = SpeedLaw.dynamicTopMph(speedMph: speed, postedLimitMph: 55,
                                             vehicleTopSpeedMph: nil)
            XCTAssertNotNil(SpeedLaw.barFraction(speed, topMph: top),
                            "current speed \(speed) fell off the bar")
            XCTAssertNotNil(SpeedLaw.barFraction(
                SpeedLaw.stateThresholdMph(postedLimitMph: 55), topMph: top))
            XCTAssertNotNil(SpeedLaw.barFraction(
                SpeedLaw.federalThresholdMph(postedLimitMph: 55), topMph: top))
        }
    }

    func testScaleStaysReadableWhenStopped() {
        XCTAssertEqual(SpeedLaw.dynamicTopMph(speedMph: 0, postedLimitMph: nil,
                                              vehicleTopSpeedMph: nil),
                       SpeedLaw.minTopMph)
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
