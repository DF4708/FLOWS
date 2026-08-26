// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// The HUD's live speed pair: reading OSM's posted limits, judging how far
/// over the driver is, and staying off screen for anyone who isn't driving.
final class SpeedSignTests: XCTestCase {

    func testParsesUSMilesPerHour() {
        XCTAssertEqual(SpeedSign.parseMaxspeed("55 mph"), 55)
        XCTAssertEqual(SpeedSign.parseMaxspeed("25mph"), 25)
        XCTAssertEqual(SpeedSign.parseMaxspeed("70 MPH"), 70)
    }

    func testBareNumberIsKilometersPerHour() {
        // OSM specifies a bare maxspeed number as km/h.
        XCTAssertEqual(SpeedSign.parseMaxspeed("80")!, 49.7, accuracy: 0.2)
        XCTAssertEqual(SpeedSign.parseMaxspeed("50")!, 31.1, accuracy: 0.2)
    }

    func testUnreadableValuesPostNoNumber() {
        // Better a blank plate than a wrong limit.
        XCTAssertNil(SpeedSign.parseMaxspeed("none"))       // derestricted autobahn
        XCTAssertNil(SpeedSign.parseMaxspeed("signals"))
        XCTAssertNil(SpeedSign.parseMaxspeed("variable"))
        XCTAssertNil(SpeedSign.parseMaxspeed(""))
        XCTAssertNil(SpeedSign.parseMaxspeed("fast"))
        XCTAssertNil(SpeedSign.parseMaxspeed("0"))
    }

    func testWalkingZone() {
        XCTAssertEqual(SpeedSign.parseMaxspeed("walk"), 5)
    }

    func testJudgmentToleratesNormalDriving() {
        XCTAssertEqual(SpeedSign.judge(speedMph: 55, limitMph: 55), .under)
        XCTAssertEqual(SpeedSign.judge(speedMph: 58, limitMph: 55), .under)
        XCTAssertEqual(SpeedSign.judge(speedMph: 61, limitMph: 55), .slightlyOver)
        XCTAssertEqual(SpeedSign.judge(speedMph: 70, limitMph: 55), .over)
    }

    func testNoLimitMeansNoAccusation() {
        // Nothing posted (or nothing found) must never paint the driver red.
        XCTAssertEqual(SpeedSign.judge(speedMph: 95, limitMph: nil), .under)
        XCTAssertEqual(SpeedSign.judge(speedMph: 95, limitMph: 0), .under)
    }

    func testVisibleOnlyWhileDriving() {
        XCTAssertTrue(SpeedSign.shouldShow(isNavigating: true, isWalking: false,
                                           isPassengerTransit: false))
        // A walker has no posted limit to keep.
        XCTAssertFalse(SpeedSign.shouldShow(isNavigating: true, isWalking: true,
                                            isPassengerTransit: false))
        // A passenger on a plane, bus, or train isn't the one driving.
        XCTAssertFalse(SpeedSign.shouldShow(isNavigating: true, isWalking: false,
                                            isPassengerTransit: true))
        // And it's a driving instrument, so not while planning.
        XCTAssertFalse(SpeedSign.shouldShow(isNavigating: false, isWalking: false,
                                            isPassengerTransit: false))
    }
}
