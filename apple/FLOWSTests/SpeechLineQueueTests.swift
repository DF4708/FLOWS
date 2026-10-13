// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// Closing a message takes its voice with it, and nothing else: the owner
/// reported that dismissing a message did not stop FLOWS reading it out.
final class SpeechLineQueueTests: XCTestCase {
    func testLinesPlayOneAtATimeInOrder() {
        var q = SpeechLineQueue<String>()
        XCTAssertEqual(q.enqueue("turn", topic: nil)?.line, "turn")
        XCTAssertNil(q.enqueue("alert", topic: "imminent.A"))
        XCTAssertNil(q.enqueue("turn 2", topic: nil))
        XCTAssertTrue(q.isBusy)
        let first = q.current!.serial
        XCTAssertEqual(q.finished(serial: first)?.line, "alert")
        XCTAssertEqual(q.finished(serial: q.current!.serial)?.line, "turn 2")
        XCTAssertNil(q.finished(serial: q.current!.serial))
        XCTAssertFalse(q.isBusy)
    }

    func testClosingTheMessageBeingReadStopsOnlyIt() {
        var q = SpeechLineQueue<String>()
        _ = q.enqueue("alert", topic: "imminent.A")
        _ = q.enqueue("turn", topic: nil)
        let result = q.cancel(topic: "imminent.A")
        XCTAssertTrue(result.stopCurrent)
        XCTAssertEqual(result.removed, 0)
        // The stopped line's report moves the queue on to the turn.
        XCTAssertEqual(q.finished(serial: q.current!.serial)?.line, "turn")
    }

    func testClosingAWaitingMessageDropsItsLinesAndKeepsTheRest() {
        var q = SpeechLineQueue<String>()
        _ = q.enqueue("turn", topic: nil)
        _ = q.enqueue("alert", topic: "imminent.A")
        _ = q.enqueue("alert again", topic: "imminent.A")
        _ = q.enqueue("other alert", topic: "imminent.B")
        let result = q.cancel(topic: "imminent.A")
        XCTAssertFalse(result.stopCurrent)
        XCTAssertEqual(result.removed, 2)
        XCTAssertEqual(q.finished(serial: q.current!.serial)?.line, "other alert")
    }

    func testLinesWithoutATopicSurviveAnyClose() {
        var q = SpeechLineQueue<String>()
        _ = q.enqueue("turn", topic: nil)
        _ = q.enqueue("turn 2", topic: nil)
        XCTAssertEqual(q.cancel(topic: "imminent.A").removed, 0)
        XCTAssertFalse(q.cancel(topic: "imminent.A").stopCurrent)
        XCTAssertEqual(q.current?.line, "turn")
    }

    func testALateOrRepeatedReportNeverSkipsALine() {
        var q = SpeechLineQueue<String>()
        _ = q.enqueue("one", topic: nil)
        _ = q.enqueue("two", topic: nil)
        let one = q.current!.serial
        XCTAssertEqual(q.finished(serial: one)?.line, "two")
        XCTAssertNil(q.finished(serial: one), "a repeated report")
        XCTAssertNil(q.finished(serial: 999), "an unknown report")
        XCTAssertEqual(q.current?.line, "two")
    }

    func testALostReportCanBeRecoveredFrom() {
        var q = SpeechLineQueue<String>()
        _ = q.enqueue("one", topic: nil)
        _ = q.enqueue("two", topic: nil)
        let one = q.current!.serial
        XCTAssertEqual(q.abandonCurrent()?.line, "two")
        // The lost report arriving after all changes nothing.
        XCTAssertNil(q.finished(serial: one))
        XCTAssertEqual(q.current?.line, "two")
    }

    func testCancelAllEmptiesTheQueue() {
        var q = SpeechLineQueue<String>()
        _ = q.enqueue("one", topic: nil)
        _ = q.enqueue("two", topic: "x")
        q.cancelAll()
        XCTAssertFalse(q.isBusy)
        XCTAssertNil(q.abandonCurrent())
    }

    func testALineCutByAWarningIsSaidAfterIt() {
        var q = SpeechLineQueue<String>()
        _ = q.enqueue("last fuel", topic: SpeechTopic.fuelLastChance)
        let cut = q.current!.serial
        _ = q.enqueue("music", topic: nil)
        _ = q.enqueueFirst("tornado", topic: SpeechTopic.imminent("A"))
        q.requeueCurrentBehindWarnings()
        XCTAssertEqual(q.finished(serial: cut)?.line, "tornado")
        XCTAssertEqual(q.finished(serial: q.current!.serial)?.line, "last fuel")
        XCTAssertEqual(q.finished(serial: q.current!.serial)?.line, "music")
        // A cut turn direction is not said late.
        var t = SpeechLineQueue<String>()
        _ = t.enqueue("turn left", topic: SpeechTopic.turn)
        let turn = t.current!.serial
        _ = t.enqueueFirst("tornado", topic: SpeechTopic.imminent("A"))
        t.requeueCurrentBehindWarnings()
        XCTAssertEqual(t.finished(serial: turn)?.line, "tornado")
        XCTAssertNil(t.finished(serial: t.current!.serial))
    }

    /// A turn direction that waited out a long warning describes a turn the
    /// car has gone by: dropped when its turn comes. Other lines are kept
    /// however long they waited.
    func testATurnLineThatWaitedTooLongIsNotSaid() {
        var q = SpeechLineQueue<String>()
        _ = q.enqueue("tornado", topic: SpeechTopic.imminent("A"))
        let warning = q.current!.serial
        _ = q.enqueue("in a quarter mile, turn left", topic: SpeechTopic.turn)
        _ = q.enqueue("music reply", topic: nil)
        let late = Date().addingTimeInterval(SpeechLineQueue<String>.turnLineLifetime + 5)
        XCTAssertEqual(q.finished(serial: warning, now: late)?.line, "music reply")
        // Within its lifetime it is still said.
        var fresh = SpeechLineQueue<String>()
        _ = fresh.enqueue("tornado", topic: SpeechTopic.imminent("A"))
        let first = fresh.current!.serial
        _ = fresh.enqueue("turn left", topic: SpeechTopic.turn)
        XCTAssertEqual(fresh.finished(serial: first, now: Date().addingTimeInterval(5))?.line,
                       "turn left")
    }

    func testTopicsNameTheirMessage() {
        XCTAssertEqual(SpeechTopic.imminent("abc"), "imminent.abc")
        XCTAssertNotEqual(SpeechTopic.trafficOffer, SpeechTopic.escalation)
    }
}
