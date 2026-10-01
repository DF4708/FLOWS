// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// The banner arrow must agree with the banner words. An icon pointing right
/// while the text says "turn left" is worse than no icon at all.
final class ManeuverSymbolTests: XCTestCase {

    func testTurnsPointTheWayTheySay() {
        XCTAssertEqual(ManeuverSymbol.symbol(for: "Turn left onto W Johnson St"),
                       "arrow.turn.up.left")
        XCTAssertEqual(ManeuverSymbol.symbol(for: "Turn right onto Park St"),
                       "arrow.turn.up.right")
    }

    func testAStreetNamedLeftDoesNotSteerTheArrow() {
        // The destination clause is stripped before matching, so a road
        // called "Left Fork" can't turn a right-hand maneuver around.
        XCTAssertEqual(ManeuverSymbol.side(of: "Turn right onto Left Fork Rd"), .right)
        XCTAssertEqual(ManeuverSymbol.symbol(for: "Turn right onto Left Fork Rd"),
                       "arrow.turn.up.right")
        XCTAssertEqual(ManeuverSymbol.side(of: "Turn left toward Right Bank Ave"), .left)
    }

    func testGentleAndSharpTurnsAreDistinct() {
        XCTAssertEqual(ManeuverSymbol.symbol(for: "Slight left onto the ramp"),
                       "arrow.up.left")
        XCTAssertEqual(ManeuverSymbol.symbol(for: "Keep right at the fork"),
                       "arrow.up.right")
        XCTAssertEqual(ManeuverSymbol.symbol(for: "Sharp left onto Oak"),
                       "arrow.turn.up.left")
    }

    func testSpecialManeuvers() {
        XCTAssertEqual(ManeuverSymbol.symbol(for: "Make a U-turn"), "arrow.uturn.down")
        XCTAssertEqual(ManeuverSymbol.symbol(for: "At the roundabout, take the 2nd exit"),
                       "arrow.triangle.turn.up.right.circle")
        XCTAssertEqual(ManeuverSymbol.symbol(for: "You have arrived"),
                       "mappin.circle.fill")
        XCTAssertEqual(ManeuverSymbol.symbol(for: "Continue on I-94 E"), "arrow.up")
    }

    func testUnknownInstructionsGetANeutralArrowNotAGuess() {
        XCTAssertEqual(ManeuverSymbol.symbol(for: ""), "arrow.up")
        XCTAssertEqual(ManeuverSymbol.symbol(for: "Proceed to the route"), "arrow.up")
    }

    // MARK: lane guidance

    func testReadsLaneCountAndSideWhenStated() {
        let a = LaneGuidance.advice(for: "Use the 2 right lanes to turn right onto I-285")
        XCTAssertEqual(a?.laneCount, 2)
        XCTAssertEqual(a?.side, .right)
        XCTAssertTrue(a?.text.contains("right") == true)
    }

    func testReadsSpelledOutLaneCounts() {
        XCTAssertEqual(LaneGuidance.advice(for: "Use the three left lanes")?.laneCount, 3)
    }

    func testKeepLeftImpliesASideWithoutNamingLanes() {
        let a = LaneGuidance.advice(for: "Keep left at the fork")
        XCTAssertEqual(a?.side, .left)
        XCTAssertEqual(a?.laneCount, 1)
    }

    func testNoLaneAdviceIsInventedWhenTheWordsDoNotSayIt() {
        // MapKit gives no structured lane data — a fabricated diagram at an
        // interchange is exactly the wrongness that puts a driver in the
        // wrong lane at speed.
        XCTAssertNil(LaneGuidance.advice(for: "Turn left onto Main St"))
        XCTAssertNil(LaneGuidance.advice(for: "Continue on I-94 E"))
    }

    func testHighlightedLanesSitOnTheStatedSide() {
        let right = LaneGuidance.Advice(laneCount: 2, side: .right, text: "")
        XCTAssertEqual(LaneGuidance.highlighted(advice: right, total: 5), Set([3, 4]))
        let left = LaneGuidance.Advice(laneCount: 2, side: .left, text: "")
        XCTAssertEqual(LaneGuidance.highlighted(advice: left, total: 5), Set([0, 1]))
    }

    func testHighlightNeverRunsPastTheLanesThatExist() {
        let a = LaneGuidance.Advice(laneCount: 9, side: .right, text: "")
        XCTAssertEqual(LaneGuidance.highlighted(advice: a, total: 3), Set([0, 1, 2]))
        XCTAssertTrue(LaneGuidance.highlighted(advice: a, total: 0).isEmpty)
    }

    // MARK: the exit sign and the lane box

    func testTheExitSignReadsTheNumberedExit() {
        XCTAssertEqual(ManeuverSymbol.exitNumber(in: "Take exit 142A toward I-94 E"), "142A")
        XCTAssertEqual(ManeuverSymbol.exitNumber(in: "Take Exit 5 onto US-51 S"), "5")
        XCTAssertNil(ManeuverSymbol.exitNumber(in: "Take the exit toward Madison"))
        XCTAssertNil(ManeuverSymbol.exitNumber(in: "At the roundabout, take the 2nd exit"))
        XCTAssertNil(ManeuverSymbol.exitNumber(in: "Continue on I-94 W"))
    }

    func testTheLaneBoxDrawsEveryTaggedLaneAsItsOwnMovement() {
        // A U-turn lane, two through lanes and a right-turn lane; turning right.
        let lanes = LaneData.parse(turnLanes: "reverse|through|through|right")
        let arrows = LaneBox.arrows(lanes: lanes, recommended: [3],
                                    instruction: "Turn right onto Main St")
        XCTAssertEqual(arrows.map(\.turn), [.reverse, .through, .through, .right])
        XCTAssertEqual(arrows.map(\.lit), [false, false, false, true])
        XCTAssertTrue(arrows[0].uTurnLeft, "a U-turn lane on the left curls left")
    }

    func testWithNoLanesTheBoxIsOneArrowForTheTurn() {
        let u = LaneBox.arrows(lanes: [], recommended: [], instruction: "Make a U-turn")
        XCTAssertEqual(u, [LaneBox.Arrow(turn: .reverse, lit: true, uTurnLeft: true)])
        let left = LaneBox.arrows(lanes: [], recommended: [], instruction: "Turn left onto Oak St")
        XCTAssertEqual(left.map(\.turn), [.left])
        // Stated lanes: the lit ones show the turn, the rest go straight.
        let stated = LaneBox.arrows(lanes: [], recommended: [],
                                    instruction: "Use the right 2 lanes to take exit 142A")
        XCTAssertEqual(stated.count, 4)
        XCTAssertEqual(stated.filter(\.lit).map(\.turn), [.right, .right])
        XCTAssertEqual(stated.filter { !$0.lit }.map(\.turn), [.through, .through])
    }
}
