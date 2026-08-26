// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// What the driver CHOSE, alongside what they DIDN'T — the missing half of
/// every preference signal in the app.
///
/// The app already recorded taps: which POI row, which destination. What it
/// never recorded was the *alternatives* — the rows that were on screen and
/// lost. That distinction is not academic. Ranking weights (how much detour
/// a cheaper fill is worth, how far off-corridor a food stop may sit, how
/// many minutes of ETA a calmer corridor earns) are only identifiable from
/// (shown set, chosen item) pairs. A log of winners with no comparison set
/// cannot recover an exchange rate: if every recorded stop is 2 km off the
/// route, that is equally consistent with "this driver hates detours" and
/// "nothing further away was ever offered."
///
/// So this records both sides, capped and encrypted, and is deliberately
/// PASSIVE: nothing reads it to steer the app yet. It accrues the evidence a
/// weight fit needs, and until that fit exists and is validated, the
/// hand-set constants keep running. Collecting first and fitting later is
/// the honest order — the alternative is shipping a learned ranker trained
/// on nothing.
struct ChoiceLog: Codable {

    /// One option as it was PRESENTED, with the features a ranker uses.
    struct Option: Codable, Equatable {
        var aheadMiles: Double = 0
        var detourMiles: Double = 0
        var price: Double?
        var rating: Double?
        var costTier: Int?
        /// Position in the list as shown — presentation bias is real and a
        /// fit has to control for it.
        var shownRank: Int = 0
        var chosen: Bool = false
    }

    /// One decision: the whole option set, one of them marked chosen.
    struct Event: Codable {
        var kind: String            // "gas", "food", "hotel", "route", …
        var t: Double               // epoch seconds
        var hourBucket: Int         // 0…5 (4-hour bins) — choices are time-shaped
        var weekend: Bool
        var options: [Option]
    }

    var events: [Event] = []

    /// Bounded history — a fit needs hundreds of events, not thousands, and
    /// this file must never grow without limit.
    static let cap = 400
    /// Options kept per event: the head of the list is where the decision
    /// actually happens.
    static let optionsPerEvent = 8

    mutating func record(_ event: Event) {
        var e = event
        e.options = Array(e.options.prefix(Self.optionsPerEvent))
        guard e.options.contains(where: \.chosen) else { return }   // no label, no value
        events.append(e)
        if events.count > Self.cap { events.removeFirst(events.count - Self.cap) }
    }

    /// Events for one decision kind, newest last.
    func events(kind: String) -> [Event] { events.filter { $0.kind == kind } }
}

/// Encrypted, capped store for choice events.
@MainActor
final class ChoiceLogStore: ObservableObject {
    static let shared = ChoiceLogStore()

    private(set) var log = ChoiceLog()
    private let url: URL
    private let persistQueue = DispatchQueue(label: "com.flows.choices.persist", qos: .utility)

    init(directory: URL? = nil) {
        let dir = directory
            ?? (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = dir.appendingPathComponent("flows_choices.json")
        if let loaded = SecureBehaviorStore.read(url).flatMap({
            try? JSONDecoder().decode(ChoiceLog.self, from: $0)
        }) {
            log = loaded
        }
    }

    func record(kind: String, options: [ChoiceLog.Option], now: Date = Date()) {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let weekday = cal.component(.weekday, from: now)
        log.record(ChoiceLog.Event(
            kind: kind, t: now.timeIntervalSince1970,
            hourBucket: min(hour / 4, 5),
            weekend: weekday == 1 || weekday == 7,
            options: options))
        let snapshot = log
        let url = self.url
        persistQueue.async { SecureBehaviorStore.save(snapshot, to: url) }
    }

    /// How much evidence has accrued — surfaced in Settings so the driver can
    /// see what the app has kept about them.
    var eventCount: Int { log.events.count }

    func erase() {
        log = ChoiceLog()
        SecureBehaviorStore.shred(url)
    }
}
