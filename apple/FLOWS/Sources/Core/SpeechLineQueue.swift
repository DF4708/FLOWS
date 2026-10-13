// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// The lines a FLOWS voice has still to say. AVSpeechSynthesizer keeps its own
/// queue with no way to take one line out of it: stopping it silences
/// everything, turn directions included. So each voice hands the synthesizer
/// ONE line at a time and keeps the rest here, every line tagged with the
/// message it belongs to, and closing a message takes out only that
/// message's lines. Speech platform glue: it stays in Swift.
struct SpeechLineQueue<Line> {
    struct Entry {
        let serial: Int
        let line: Line
        /// The message this line reads out (see SpeechTopic); nil for lines
        /// no close can take back, such as a turn direction.
        let topic: String?
        /// When the line was queued: a turn direction that waited out a long
        /// warning is stale (see `turnLineLifetime`).
        var queuedAt = Date()
    }

    /// A turn direction older than this when its turn comes to be said is
    /// dropped: it describes a turn the car has gone by (15 s is a quarter
    /// mile at 60 mph, past the maneuver it announced).
    static var turnLineLifetime: TimeInterval { 15 }

    /// The line the synthesizer is saying.
    private(set) var current: Entry?
    private var waiting: [Entry] = []
    private var lastSerial = 0
    /// The playing line already queued again (requeueCurrentBehindWarnings).
    private var requeued: Int?

    /// A line is playing or waiting to.
    var isBusy: Bool { current != nil }

    /// Queue a line. Answers the entry to start now when nothing is playing.
    mutating func enqueue(_ line: Line, topic: String?) -> Entry? {
        lastSerial += 1
        let entry = Entry(serial: lastSerial, line: line, topic: topic)
        guard current == nil else {
            waiting.append(entry)
            return nil
        }
        current = entry
        return entry
    }

    /// Queue a line ahead of every waiting one — a warning, which must not
    /// wait behind a music reply and two turn directions. Answers the entry
    /// to start now when nothing is playing.
    mutating func enqueueFirst(_ line: Line, topic: String?) -> Entry? {
        lastSerial += 1
        let entry = Entry(serial: lastSerial, line: line, topic: topic)
        guard current == nil else {
            // Behind any warning already waiting, ahead of everything else.
            let at = waiting.firstIndex { !SpeechTopic.isUrgent($0.topic) } ?? waiting.endIndex
            waiting.insert(entry, at: at)
            return nil
        }
        current = entry
        return entry
    }

    /// A warning is about to cut the playing line: queue it again, after the
    /// warnings waiting and ahead of everything else, so it is said once the
    /// warning is. Its callers had marked it said — a cut fuel last-chance
    /// line, camera line or traffic offer never came back. Not a turn
    /// direction: said after a warning it came after the turn, and the next
    /// one replaces it.
    mutating func requeueCurrentBehindWarnings() {
        // Once per line: a second warning before the cut's report would
        // queue it twice.
        guard let playing = current, !SpeechTopic.isUrgent(playing.topic),
              playing.topic != SpeechTopic.turn, requeued != playing.serial else { return }
        requeued = playing.serial
        lastSerial += 1
        let again = Entry(serial: lastSerial, line: playing.line, topic: playing.topic)
        let at = waiting.firstIndex { !SpeechTopic.isUrgent($0.topic) } ?? waiting.endIndex
        waiting.insert(again, at: at)
    }

    /// The playing line finished or was stopped. Answers the next line to
    /// start. A late or repeated report (another serial) changes nothing, so
    /// the queue never skips a line.
    mutating func finished(serial: Int, now: Date = Date()) -> Entry? {
        guard current?.serial == serial else { return nil }
        waiting.removeAll {
            $0.topic == SpeechTopic.turn
                && now.timeIntervalSince($0.queuedAt) > Self.turnLineLifetime
        }
        current = waiting.isEmpty ? nil : waiting.removeFirst()
        return current
    }

    /// Take a message's lines out: the waiting ones go now. Answers whether
    /// the playing line is that message's — the caller stops it, and its
    /// finish report moves the queue on (it stays current until then, so the
    /// queue can never move on twice).
    mutating func cancel(topic: String) -> (stopCurrent: Bool, removed: Int) {
        let before = waiting.count
        waiting.removeAll { $0.topic == topic }
        return (current?.topic == topic, before - waiting.count)
    }

    /// The playing line's finish report never came: drop it and answer the
    /// next line, so one lost report can't silence every later line.
    mutating func abandonCurrent() -> Entry? {
        guard let playing = current else { return nil }
        return finished(serial: playing.serial)
    }

    /// Drop everything, the playing line included.
    mutating func cancelAll() {
        waiting.removeAll()
        current = nil
    }
}

/// The messages whose spoken lines a close takes back. Every spoken line with
/// a banner, chip or card passes its topic, and every way that message
/// closes cancels the topic.
enum SpeechTopic {
    static func imminent(_ alertID: String) -> String { "imminent." + alertID }
    static let trafficOffer = "traffic-offer"
    static let escalation = "escalation"
    static let fuelLastChance = "fuel-last-chance"
    /// A turn direction: a newer one makes any still waiting stale — said
    /// after a long warning, "in a quarter mile, turn left" came after the
    /// turn.
    static let turn = "turn"

    /// A warning: spoken before anything waiting, and over a music reply or
    /// a turn line already playing.
    static func isUrgent(_ topic: String?) -> Bool {
        guard let topic else { return false }
        return topic.hasPrefix("imminent.") || topic == escalation
    }
}
