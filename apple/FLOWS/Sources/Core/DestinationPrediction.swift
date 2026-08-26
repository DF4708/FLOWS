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
    static let recencyHalfLifeDays = 21.0
    /// Weight on an exact context match versus the weaker back-off tiers.
    /// Context is the strongest evidence, so it dominates — but never so
    /// completely that a single tap at 8am outranks a place visited fifty
    /// times.
    static let contextWeight = 3.0
    static let timeWeight = 1.5
    static let baseWeight = 1.0

    /// Rank candidates for the driver's current moment. Pure — inputs in,
    /// ordering out — so the whole prediction is unit-testable.
    static func rank(
        _ evidence: [Evidence], now: Double, limit: Int = 4
    ) -> [Candidate] {
        let scored: [(Evidence, Double, String)] = evidence.compactMap { e in
            let counts = Double(e.contextHits) * contextWeight
                + Double(e.timeHits) * timeWeight
                + Double(e.totalHits) * baseWeight
            guard counts > 0 else { return nil }
            let ageDays = max(now - e.lastUsed, 0) / 86_400
            let recency = e.lastUsed > 0 ? pow(0.5, ageDays / recencyHalfLifeDays) : 0.35
            let score = counts * recency
            return (e, score, reason(for: e))
        }
        guard let best = scored.map(\.1).max(), best > 0 else { return [] }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { e, s, why in
                Candidate(id: e.id, name: e.name, coordinate: e.coordinate,
                          score: s / best, reason: why)
            }
    }

    /// Why a candidate is being offered — the driver should never see an
    /// unexplained suggestion about their own movements.
    static func reason(for e: Evidence) -> String {
        if e.contextHits >= 3 { return "You usually go here about now" }
        if e.contextHits > 0 { return "You've come here at this time" }
        if e.timeHits >= 3 { return "A regular stop at this hour" }
        if e.totalHits >= 5 { return "One of your regular places" }
        return "You've been here recently"
    }

    /// Whether a prediction is confident enough to OFFER unprompted (the
    /// CarPlay row, the empty-field suggestion). A weak guess about where
    /// someone is going is worse than silence — it is both useless and a
    /// little unsettling.
    static func isConfident(_ candidates: [Candidate], minimumEvidence: Int) -> Bool {
        guard let top = candidates.first else { return false }
        return top.score >= 0.5 && minimumEvidence >= 3
    }
}
