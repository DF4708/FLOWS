// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// Real lane guidance from OpenStreetMap's `turn:lanes`. Getting a driver
/// into the right lane at an interchange is the whole point, so a lane that
/// doesn't serve the maneuver must never be highlighted.
final class LaneDataTests: XCTestCase {

    func testParsesLanesLeftToRight() {
        let lanes = LaneData.parse(turnLanes: "left|through|through;right")
        XCTAssertEqual(lanes.count, 3)
        XCTAssertEqual(lanes[0].turns, [.left])
        XCTAssertEqual(lanes[1].turns, [.through])
        XCTAssertEqual(lanes[2].turns, [.through, .right])
    }

    func testUnspecifiedLanesAreLanesNotGaps() {
        // "||right" is three lanes, the first two unspecified.
        let lanes = LaneData.parse(turnLanes: "||right")
        XCTAssertEqual(lanes.count, 3)
        XCTAssertEqual(lanes[2].turns, [.right])
    }

    func testParsesEveryOSMMovement() {
        let lanes = LaneData.parse(
            turnLanes: "sharp_left|slight_left|through|merge_to_right|reverse")
        XCTAssertEqual(lanes[0].turns, [.sharpLeft])
        XCTAssertEqual(lanes[1].turns, [.slightLeft])
        XCTAssertEqual(lanes[3].turns, [.mergeToRight])
        XCTAssertEqual(lanes[4].turns, [.reverse])
    }

    func testEmptyTagYieldsNoLanes() {
        XCTAssertTrue(LaneData.parse(turnLanes: "").isEmpty)
        XCTAssertTrue(LaneData.parse(turnLanes: "   ").isEmpty)
    }

    // MARK: which lanes to be in

    func testRightTurnHighlightsOnlyLanesThatTurnRight() {
        let lanes = LaneData.parse(turnLanes: "left|through|through;right|right")
        let lit = LaneData.recommended(lanes: lanes, maneuver: .right)
        XCTAssertEqual(lit, Set([2, 3]))
    }

    func testLeftTurnHighlightsOnlyLanesThatTurnLeft() {
        let lanes = LaneData.parse(turnLanes: "left|left;through|through|right")
        XCTAssertEqual(LaneData.recommended(lanes: lanes, maneuver: .left), Set([0, 1]))
    }

    func testGoingStraightHighlightsTheThroughLanes() {
        let lanes = LaneData.parse(turnLanes: "left|through|through|right")
        XCTAssertEqual(LaneData.recommended(lanes: lanes, maneuver: .none), Set([1, 2]))
    }

    func testNoMatchingLaneHighlightsNothingRatherThanGuessing() {
        // A road whose tagged lanes don't serve this maneuver: better a
        // blank row than a confident green arrow over the wrong lane.
        let lanes = LaneData.parse(turnLanes: "through|through")
        XCTAssertTrue(LaneData.recommended(lanes: lanes, maneuver: .left).isEmpty)
        XCTAssertTrue(LaneData.recommended(lanes: [], maneuver: .right).isEmpty)
    }

    // MARK: how each lane is drawn

    func testLaneArrowsFollowTheirOwnMovement() {
        let lanes = LaneData.parse(turnLanes: "left|through|slight_right")
        XCTAssertEqual(lanes[0].symbol, "arrow.turn.up.left")
        XCTAssertEqual(lanes[1].symbol, "arrow.up")
        XCTAssertEqual(lanes[2].symbol, "arrow.up.right")
    }

    func testASharedLaneDrawsAsItsTurnNotAsThrough() {
        // A through+right lane is worth drawing as a right — that's the
        // movement a driver is deciding about.
        let lanes = LaneData.parse(turnLanes: "through;right")
        XCTAssertEqual(lanes[0].symbol, "arrow.turn.up.right")
    }

    // MARK: the words under the row

    func testSummaryNamesWhereTheLanesAre() {
        let lanes = LaneData.parse(turnLanes: "left|through|through;right|right")
        let lit = LaneData.recommended(lanes: lanes, maneuver: .right)
        XCTAssertEqual(LaneData.summary(lanes: lanes, recommended: lit),
                       "Use the 2 right lanes")
        let leftLanes = LaneData.parse(turnLanes: "left|through|through")
        XCTAssertEqual(
            LaneData.summary(lanes: leftLanes,
                             recommended: LaneData.recommended(lanes: leftLanes,
                                                               maneuver: .left)),
            "Use the 1 left lane")
    }

    func testNoSummaryWhenEveryLaneWorks() {
        // "Use all 3 lanes" is noise — say nothing.
        let lanes = LaneData.parse(turnLanes: "through|through|through")
        let lit = LaneData.recommended(lanes: lanes, maneuver: .none)
        XCTAssertNil(LaneData.summary(lanes: lanes, recommended: lit))
    }
}
