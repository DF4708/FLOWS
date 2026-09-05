// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// The decision behind "conditions are worsening — reroute?".
///
/// Pure, so the deferred baseline, the two triggers and the dismissal rules
/// are pinned by FLOWSTests. They used to live inline in the corridor sink
/// of AppModel, where they were changed twice in one month — the acute cut
/// and the identity-aware dismissal — with no test able to see either.
enum EscalationPolicy {
    /// What the driver has accepted so far on this leg.
    struct State: Equatable {
        /// The corridor risk the driver implicitly accepted at GO. A route
        /// selected before scoring finished has nothing to accept yet:
        /// `deferred` (-1) means "the first COMPLETE score is the baseline".
        var baseline: Double
        /// The risk of the last prompt the driver waved through.
        var dismissedRisk: Double = 0
        /// The hazards the driver has waved through, by identity. Severity
        /// alone cannot tell two Extreme alerts apart: both score 0.95.
        var dismissedAlertIDs: Set<String> = []

        static let deferred = -1.0
        static func fresh(baseline: Double?) -> State {
            State(baseline: baseline ?? deferred)
        }
    }

    /// One corridor score, reduced to what the decision needs.
    struct Reading: Equatable {
        /// False when a cell fetch failed: the zeroed samples make the mean
        /// meaningless, and "no data" must never read as "all clear".
        let complete: Bool
        /// Mean realized risk across the look-ahead window.
        let mean: Double
        /// Worst single sample in the window.
        let peak: Double
        /// The alert behind that worst sample, when one named it.
        let peakAlertID: String?
    }

    enum Trigger: Equatable {
        /// The whole window got worse: mean up into yellow by `sustainedRise`.
        case sustained(mean: Double)
        /// A realized Red somewhere in the window — a tornado warning on one
        /// stretch escalates even when the rest of the window is quiet.
        case acute(peak: Double, alertID: String?)

        var risk: Double {
            switch self {
            case .sustained(let m): return m
            case .acute(let p, _): return p
            }
        }
        var alertID: String? {
            if case .acute(_, let id) = self { return id }
            return nil
        }
    }

    /// How far the mean must rise above the accepted baseline.
    static let sustainedRise = 0.12
    /// How much worse a new prompt must be than the last one dismissed.
    static let dismissMargin = 0.05

    /// Evaluate one reading. Returns the state to keep and the prompt to
    /// raise, if any. Acute wins over sustained when both hold: the prompt
    /// then carries the peak, which is the number the driver needs.
    static func evaluate(_ r: Reading, state: State) -> (state: State, trigger: Trigger?) {
        var s = state
        if s.baseline < 0 {
            if r.complete { s.baseline = r.mean }
            return (s, nil)
        }
        guard r.complete else { return (s, nil) }
        let unseen = r.peakAlertID.map { !s.dismissedAlertIDs.contains($0) } ?? false
        let acute = FlowsCore.riskBand(score: r.peak) == .red
            && (r.peak > s.dismissedRisk + dismissMargin || unseen)
        if acute { return (s, .acute(peak: r.peak, alertID: r.peakAlertID)) }
        let sustained = r.mean >= FlowsCore.riskYellowMin
            && r.mean > s.baseline + sustainedRise
            && r.mean > s.dismissedRisk + dismissMargin
        if sustained { return (s, .sustained(mean: r.mean)) }
        return (s, nil)
    }

    /// The driver pressed Continue on `trigger`.
    static func dismissed(_ trigger: Trigger, state: State) -> State {
        var s = state
        s.dismissedRisk = trigger.risk
        if let id = trigger.alertID { s.dismissedAlertIDs.insert(id) }
        return s
    }
}
