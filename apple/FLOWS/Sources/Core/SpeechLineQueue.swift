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
    }

    /// The line the synthesizer is saying.
    private(set) var current: Entry?
    private var waiting: [Entry] = []
    private var lastSerial = 0

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

    /// The playing line finished or was stopped. Answers the next line to
    /// start. A late or repeated report (another serial) changes nothing, so
    /// the queue never skips a line.
    mutating func finished(serial: Int) -> Entry? {
        guard current?.serial == serial else { return nil }
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
}
