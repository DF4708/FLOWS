// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// The crash help card's steps and the red alerts' standing: what the
/// alerts, voice and haptics check found.
final class AlertsAndVoiceTests: XCTestCase {

    // MARK: the crash help card

    func testNoContactNumberMeansNoStepsWithoutButtons() {
        // The card has no Text report or Call contact button without a
        // saved number, so it must not tell the driver to use them.
        let steps = CrashLogic.assistSteps(contactName: "Ana", hasContactPhone: false)
        XCTAssertTrue(steps.contains("911"))
        XCTAssertFalse(steps.contains("Step 2"))
        XCTAssertFalse(steps.contains("Step 3"))
        XCTAssertFalse(steps.contains("Ana"))
    }

    func testASavedNumberListsTheContactSteps() {
        let named = CrashLogic.assistSteps(contactName: "Ana", hasContactPhone: true)
        XCTAssertTrue(named.contains("Step 1 — call 911"))
        XCTAssertTrue(named.contains("Step 2 — send the report to Ana."))
        XCTAssertTrue(named.contains("Step 3 — call them."))
        // A number with no name still gets the steps, addressed plainly.
        let unnamed = CrashLogic.assistSteps(contactName: "", hasContactPhone: true)
        XCTAssertTrue(unnamed.contains("send the report to your contact."))
    }

    // MARK: red alerts

    func testOnlyTheRedPairIsRed() {
        // Red cards stay until pressed — a Settings switch turned off
        // mid-trip clears the others, never these.
        XCTAssertTrue(ImminentAlerts.Action.shelter.isRed)
        XCTAssertTrue(ImminentAlerts.Action.lookout.isRed)
        XCTAssertFalse(ImminentAlerts.Action.restArea.isRed)
        XCTAssertFalse(ImminentAlerts.Action.monitor.isRed)
    }
}
