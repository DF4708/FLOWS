// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// WHERE THIS DRIVER IS PROBABLY GOING, RIGHT NOW.
///
/// The app has been recording the ingredients for this and reading none of
/// them: `EverydayPlace.contexts` counts every stop the driver picked, keyed
/// by time-of-day bucket, weekday-vs-weekend, and the cell they set out
/// from — and nothing consumed it. `RecentDestinations` counts planned
/// destinations with recency decay but is blind to time and place, so it
/// offers the same list at 7am Tuesday as at 9pm Saturday.
///
/// This joins them. It is not a neural net and does not want to be: with a
/// few hundred observations per driver, a smoothed contextual count model is
/// better behaved than a fitted network — it degrades gracefully to plain
/// frequency when a context is unseen, it cannot hallucinate a destination
/// the driver has never been to, and every score it produces can be
/// explained in one sentence ("you go here most Tuesday mornings").
///
/// All inputs are already on the device and encrypted at rest; nothing here
/// makes a network call.
///
/// The weights, the recency, the ranking and the reason are computed in
/// rust/flows-core (learning.rs) and called through rust/flows-bridge; the
/// reason's words stay here. Pinned bit for bit to the Swift this replaced by
/// rust/flows-bridge/tests/fixtures/swift_learning_oracle.tsv.
enum DestinationPrediction {

    /// One candidate the driver might be heading to.
    struct Candidate: Identifiable, Equatable {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
        /// 0…1 relative likelihood within this prediction (not a probability
        /// of the world — a ranking weight).
        let score: Double
        /// Plain-words reason, shown to the driver so a suggestion is never
        /// unexplained ("Most weekday mornings").
        let reason: String

        static func == (a: Candidate, b: Candidate) -> Bool {
            a.id == b.id && abs(a.score - b.score) < 1e-9
        }
    }

    /// Evidence for one place, flattened from the stores so the ranking
    /// function stays pure and testable without any actor.
    struct Evidence {
        let id: String
        let name: String
        let coordinate: CLLocationCoordinate2D
        /// Taps in the CURRENT context (this hour bucket, this day type,
        /// from near here).
        var contextHits: Int = 0
        /// Taps in this hour bucket regardless of where the driver started —
        /// the back-off tier when the exact context is unseen.
        var timeHits: Int = 0
        /// All taps / plans, ever.
        var totalHits: Int = 0
        /// Epoch seconds of the most recent use.
        var lastUsed: Double = 0
    }

    /// Half-life on recency, in days. Habits change; a place not visited in
    /// months should fall behind one visited last week even at equal counts.
    static let recencyHalfLifeDays = flows_learning_destination_recency_half_life_days()
    /// Weight on an exact context match versus the weaker back-off tiers.
    /// Context is the strongest evidence, so it dominates — but never so
    /// completely that a single tap at 8am outranks a place visited fifty
    /// times.
    static let contextWeight = flows_learning_destination_context_weight()
    static let timeWeight = flows_learning_destination_time_weight()
    static let baseWeight = flows_learning_destination_base_weight()

    /// Rank candidates for the driver's current moment. Pure — inputs in,
    /// ordering out — so the whole prediction is unit-testable.
    static func rank(
        _ evidence: [Evidence], now: Double, limit: Int = 4
    ) -> [Candidate] {
        // Nothing to rank (and an empty buffer never crosses).
        guard !evidence.isEmpty else { return [] }
        let context = evidence.map { Int64($0.contextHits) }
        let time = evidence.map { Int64($0.timeHits) }
        let total = evidence.map { Int64($0.totalHits) }
        let last = evidence.map(\.lastUsed)
        // Flat [index, score, reason code] triples, best first.
        let flat = context.withUnsafeBufferPointer { c in
            time.withUnsafeBufferPointer { t in
                total.withUnsafeBufferPointer { tot in
                    last.withUnsafeBufferPointer { l in
                        flows_learning_destination_rank(c, t, tot, l, now, Int64(limit))
                    }
                }
            }
        }
        var out: [Candidate] = []
        var i = 0
        while i + 2 < flat.len() {
            if let index = Int(exactly: flat[i]), index < evidence.count {
                let e = evidence[index]
                out.append(Candidate(id: e.id, name: e.name, coordinate: e.coordinate,
                                     score: flat[i + 1], reason: reasonWords(UInt8(exactly: flat[i + 2]) ?? 4)))
            }
            i += 3
        }
        return out
    }

    /// Why a candidate is being offered — the driver should never see an
    /// unexplained suggestion about their own movements.
    static func reason(for e: Evidence) -> String {
        reasonWords(flows_learning_destination_reason(Int64(e.contextHits), Int64(e.timeHits), Int64(e.totalHits)))
    }

    /// The plain words for a reason code (the bridge's: 0 usually now, 1 came
    /// at this time, 2 regular at this hour, 3 regular place, 4 recently).
    static func reasonWords(_ code: UInt8) -> String {
        switch code {
        case 0: return "You usually go here about now"
        case 1: return "You've come here at this time"
        case 2: return "A regular stop at this hour"
        case 3: return "One of your regular places"
        default: return "You've been here recently"
        }
    }

    /// Whether a prediction is confident enough to OFFER unprompted (the
    /// CarPlay row, the empty-field suggestion). A weak guess about where
    /// someone is going is worse than silence — it is both useless and a
    /// little unsettling.
    static func isConfident(_ candidates: [Candidate], minimumEvidence: Int) -> Bool {
        let top = candidates.first?.score
        return flows_learning_destination_is_confident(top ?? 0, top != nil, Int64(minimumEvidence))
    }
}
