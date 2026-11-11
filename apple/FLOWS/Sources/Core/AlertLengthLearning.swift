// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// One official event that said both when it began and when it ends: a
/// free, labeled example of how long that kind of event runs here.
struct AlertLengthSample: Equatable {
    /// The event itself, the same across its updates (its VTEC office,
    /// kind and number; the message id when it has none).
    let eventKey: String
    /// The kind it is learned under (`flows_alerts_usual_kind`).
    let kind: String
    /// From its start to its stated end.
    let hours: Double
    let ends: Date
    /// Whether this message knows the true start. An update of an event
    /// already under way gives its own send time as the start, so it can
    /// only move the end of an event whose start was seen before.
    let opens: Bool
}

/// Learns how long each kind of alert really runs where this device goes
/// (owner, 2026-11-11: adjust in proportion as the device sees more alerts).
///
/// An alert with no end time is taken to run as long as its kind usually
/// does. "Usually" starts as the national record (the measured table in
/// rust/flows-core, alerts.rs). Every alert that DOES state its end is an
/// example: a winter storm in the lake belt runs longer than the national
/// middle, a monsoon flood shorter. The rule is a weighted average, not a
/// neural model: the table counts as twenty events already seen, so one
/// event moves the answer a little, twenty move it half way, and the table
/// always keeps a say. With a few events of each kind a year that is the
/// right estimator, and it can be explained when a driver asks.
///
/// The math, its limits (never under half the measured length, never over
/// three times it) and which lengths count are in rust/flows-core
/// (`learned_usual_hours`); this file reads the alerts and keeps the sums.
enum AlertLengthLearning {
    /// The examples in one api.weather.gov alert list. Cancelled messages
    /// and events with no stated end teach nothing.
    static func samples(from features: [[String: Any]],
                        parse: (String) -> Date?) -> [AlertLengthSample] {
        features.compactMap { feature -> AlertLengthSample? in
            guard let props = feature["properties"] as? [String: Any],
                  let id = props["id"] as? String ?? feature["id"] as? String,
                  let event = (props["event"] as? String) ?? (props["headline"] as? String),
                  !event.isEmpty,
                  (props["messageType"] as? String)?.lowercased() != "cancel",
                  let ends = (props["ends"] as? String).flatMap(parse),
                  let onset = ["onset", "effective", "sent"]
                      .compactMap({ props[$0] as? String }).compactMap(parse).first
            else { return nil }
            let hours = ends.timeIntervalSince(onset) / 3600
            guard flows_alerts_length_usable(hours) else { return nil }
            return AlertLengthSample(eventKey: eventKey(props: props, id: id),
                                     kind: flows_alerts_usual_kind(event).toString(),
                                     hours: hours, ends: ends, opens: opens(props: props))
        }
    }

    /// Whether a message carries the event's true start: a VTEC line that
    /// is NEW or still names a start time (it reads 000000T0000Z once the
    /// event is under way); with no VTEC line, the first message only.
    static func opens(props: [String: Any]) -> Bool {
        let vtec = ((props["parameters"] as? [String: Any])?["VTEC"] as? [String])?.first ?? ""
        let parts = vtec.split(separator: ".")
        if parts.count >= 7 {
            return parts[1] == "NEW" || !parts[6].hasPrefix("000000T0000Z")
        }
        return (props["messageType"] as? String)?.lowercased() == "alert"
    }

    /// Office, kind and event number out of the VTEC line
    /// ("/O.CON.KBUF.WS.W.0004.261201T0000Z-261202T1200Z/"), which stays
    /// the same while the action word and the times change with each
    /// update; the message id for a product with no VTEC line.
    static func eventKey(props: [String: Any], id: String) -> String {
        let vtec = ((props["parameters"] as? [String: Any])?["VTEC"] as? [String])?.first ?? ""
        let parts = vtec.split(separator: ".")
        guard parts.count >= 7 else { return id }
        return parts[2...5].joined(separator: ".")
    }
}

/// What the device has learned about alert lengths: for each kind, how many
/// events it saw and the sum of the logarithms of their lengths.
///
/// Which alerts a device saw says where it has been, so this is a behaviour
/// store: sealed by `SecureBehaviorStore`, and erased by "Erase everything
/// FLOWS has learned" (AppModel.eraseEverythingLearned).
final class AlertLengthMemory: @unchecked Sendable {
    static let shared = AlertLengthMemory()

    private struct Stat: Codable, Equatable {
        var count: Int
        var sumLn: Double
    }
    /// An event already counted, kept until a week past its end so an
    /// update corrects its length instead of counting it twice.
    private struct Seen: Codable, Equatable {
        var kind: String
        var ln: Double
        var ends: Date
    }
    private struct Stored: Codable, Equatable {
        var stats: [String: Stat] = [:]
        var seen: [String: Seen] = [:]
    }

    /// The most events remembered as already counted; the oldest ends go
    /// first. A state-wide list on a bad day is a few hundred.
    static let maxSeen = 2_000
    static let keepSeen: TimeInterval = 7 * 86_400

    private let lock = NSLock()
    private var stored = Stored()
    private let url: URL

    init(directory: URL? = nil) {
        let dir = directory
            ?? (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = dir.appendingPathComponent("flows_alert_lengths.json")
        if let loaded = SecureBehaviorStore.load(Stored.self, from: url) { stored = loaded }
    }

    /// Events of this kind seen, and the mean logarithm of their lengths.
    func learned(event: String) -> (count: Int, meanLn: Double) {
        let kind = flows_alerts_usual_kind(event.isEmpty ? "Alert" : event).toString()
        lock.lock(); defer { lock.unlock() }
        guard let stat = stored.stats[kind], stat.count > 0 else { return (0, 0) }
        return (stat.count, stat.sumLn / Double(stat.count))
    }

    /// The usual length of this kind now, in hours: the measured table,
    /// moved by what was seen.
    func usualHours(event: String) -> Double {
        let known = learned(event: event)
        return flows_alerts_learned_usual_hours(
            event.isEmpty ? "Alert" : event, Int64(known.count), known.meanLn)
    }

    /// How many events have been learned from, over every kind.
    var eventCount: Int {
        lock.lock(); defer { lock.unlock() }
        return stored.stats.values.reduce(0) { $0 + $1.count }
    }

    /// Learn from a list of examples. An event is counted once: an update
    /// that moves its end replaces the length it was counted with.
    func record(_ samples: [AlertLengthSample], now: Date = Date()) {
        guard !samples.isEmpty else { return }
        lock.lock()
        let before = stored
        for sample in samples where flows_alerts_length_usable(sample.hours) {
            let old = stored.seen[sample.eventKey]
            // The start comes only from a message that knows it; the end is
            // the latest any part of the event states (the longer side).
            let sampleStart = sample.ends.addingTimeInterval(-sample.hours * 3600)
            let oldStart = old.map { $0.ends.addingTimeInterval(-exp($0.ln) * 3600) }
            let start: Date
            switch (oldStart, sample.opens) {
            case let (was?, true): start = min(was, sampleStart)
            case let (was?, false): start = was
            case (nil, true): start = sampleStart
            case (nil, false): continue
            }
            let ends = max(old?.ends ?? sample.ends, sample.ends)
            let hours = ends.timeIntervalSince(start) / 3600
            guard flows_alerts_length_usable(hours) else { continue }
            let ln = log(hours)
            if let old {
                guard abs(old.ln - ln) > 1e-9 || old.kind != sample.kind else { continue }
                stored.stats[old.kind]?.sumLn -= old.ln
                stored.stats[old.kind]?.count -= 1
            }
            var stat = stored.stats[sample.kind] ?? Stat(count: 0, sumLn: 0)
            stat.count += 1
            stat.sumLn += ln
            stored.stats[sample.kind] = stat
            stored.seen[sample.eventKey] = Seen(kind: sample.kind, ln: ln, ends: ends)
        }
        stored.stats = stored.stats.filter { $0.value.count > 0 }
        // Forget which events were counted once they are well over; their
        // lengths stay in the sums.
        stored.seen = stored.seen.filter { now.timeIntervalSince($0.value.ends) < Self.keepSeen }
        if stored.seen.count > Self.maxSeen {
            let keep = stored.seen.sorted { $0.value.ends > $1.value.ends }.prefix(Self.maxSeen)
            stored.seen = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        let snapshot = stored
        lock.unlock()
        guard snapshot != before else { return }
        let url = self.url
        SecureBehaviorStore.persistQueue.async { SecureBehaviorStore.save(snapshot, to: url) }
    }

    /// "Erase everything FLOWS has learned".
    func erase() {
        lock.lock()
        stored = Stored()
        lock.unlock()
        // On the save queue, so a save already waiting cannot put the file
        // back after the erase.
        let url = self.url
        SecureBehaviorStore.persistQueue.sync { SecureBehaviorStore.shred(url) }
    }
}
