// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// Imminent-hazard policy: weather the driver will ENCOUNTER SOON (within the
/// lookahead window at current speed) is surfaced loudly, with the official
/// alert summary and a link to the issuing source, and the app reacts:
///   * RED alerts (active tornado / hurricane / fire / radiological / other
///     life-safety warnings) → automatically open a shelter list relevant to
///     that specific warning;
///   * TRANSIENT upper-yellow risk (expires within ~2 h) → recommend waiting
///     it out at a rest area instead of driving into it;
///   * everything else → keep monitoring.
/// Pure functions — pinned by FLOWSTests against the Mexico→Canada scenario.
enum ImminentAlerts {

    /// How far ahead "imminent" reaches: 10 minutes at current speed.
    static let lookaheadSeconds: Double = 600
    /// Floor so a vehicle stopped at a light still sees hazards just ahead
    /// (≈ 18 km at the floor speed over the 10-minute window).
    static let minimumSpeedMps: Double = 5.0
    /// "Transient" = the alert expires within this horizon (the 1–2 h rule).
    static let transientHorizonSeconds: Double = 2 * 3600
    /// Upper-yellow floor: risks below this aren't worth a stop.
    static let upperYellowMin: Double = 0.60

    enum Action: Equatable {
        /// Life-safety warning ahead — open shelters for THIS hazard now.
        case shelter
        /// An AMBER-family or law-enforcement alert: a described vehicle or
        /// person to WATCH FOR. Just as urgent as a shelter warning, and
        /// carried with the same red weight — but you do not take cover from
        /// a child abduction, so it offers no shelter and no "get inside"
        /// advice. It shows the description and the official link.
        case lookout
        /// Short-lived elevated risk — recommend a rest-area wait.
        case restArea
        /// Elevated but not actionable — banner only.
        case monitor

        /// The red pair. A red card stays until the driver presses it, is
        /// never cut short on screen, and sits above every convenience card.
        var isRed: Bool { self == .shelter || self == .lookout }
    }

    /// Is this a life-safety event by name — the vocabulary above?
    static func isLifeSafetyEvent(_ event: String) -> Bool {
        flows_alerts_is_life_safety(event)
    }

    /// Is this a look-out-for alert (a person or vehicle), not a hazard?
    static func isLookoutEvent(_ event: String) -> Bool {
        flows_alerts_is_lookout(event)
    }

    /// Classify one alert the vehicle is about to enter.
    static func classify(
        event: String, severityScore: Double, expires: Date?, now: Date = Date()
    ) -> Action {
        let secs = expires.map { $0.timeIntervalSince(now) }
        switch flows_alerts_action(event, severityScore, secs != nil, secs ?? 0) {
        case 1: return .restArea
        case 2: return .shelter
        case 3: return .lookout
        default: return .monitor   // 0, and the containment fallback
        }
    }

    /// How this alert ranks against every other one the driver could be
    /// shown — the owner's rule that the most immediate risk to life takes
    /// precedence. 3 life-safety, 2 realized primary or Red severity,
    /// 1 predictor, 0 lookout or unclassified. See rust/flows-core alerts.rs.
    static func threatRank(event: String, severityScore: Double) -> Int {
        Int(flows_alerts_threat_rank(event, severityScore))
    }

    /// Seconds until the vehicle reaches a point `distanceMeters` ahead at
    /// `speedMps` (floored so "stopped" still evaluates the road just ahead).
    static func secondsToReach(distanceMeters: Double, speedMps: Double) -> Double {
        max(distanceMeters, 0) / max(speedMps, minimumSpeedMps)
    }

    /// Is a hazard at `distanceMeters` ahead inside the 10-minute window?
    static func isImminent(distanceMeters: Double, speedMps: Double) -> Bool {
        secondsToReach(distanceMeters: distanceMeters, speedMps: speedMps) <= lookaheadSeconds
    }

    /// One risky corridor point, positioned by straight-line distance from
    /// the vehicle (corridor samples are dense enough that straight-line ≈
    /// along-route at the 10-minute scale).
    struct Candidate: Equatable {
        let alertID: String
        let distanceMeters: Double
        let severityScore: Double
        /// `threatRank(event:severityScore:)` of the alert; callers that have
        /// no event (tests of the distance rule) get the predictor rank.
        var threatRank: Int = 1
    }

    /// The alert the driver should be warned about NOW: the worst-severity
    /// alert whose nearest risky sample is inside the lookahead window.
    static func firstImminent(
        _ candidates: [Candidate], speedMps: Double
    ) -> Candidate? {
        candidates
            .filter { isImminent(distanceMeters: $0.distanceMeters, speedMps: speedMps) }
            .sorted {
                // Most immediate risk to life first; then CAP severity; then
                // whichever is reached first. A lookout can only win an
                // otherwise empty field.
                if $0.threatRank != $1.threatRank { return $0.threatRank > $1.threatRank }
                if $0.severityScore != $1.severityScore { return $0.severityScore > $1.severityScore }
                return $0.distanceMeters < $1.distanceMeters
            }
            .first
    }

    /// The shelter search relevant to a specific warning — a tornado warning
    /// should list tornado shelters, a fire evacuation lists evacuation
    /// centers, a flood lists shelters on high ground.
    static func shelterQuery(forEvent event: String) -> String {
        let lower = event.lowercased()
        if lower.contains("tornado") || lower.contains("severe thunderstorm") {
            return "tornado shelter storm shelter"
        }
        if lower.contains("hurricane") || lower.contains("typhoon") || lower.contains("tropical") {
            return "hurricane shelter evacuation center"
        }
        if lower.contains("fire") || lower.contains("red flag") || lower.contains("evacuation") {
            return "evacuation center emergency shelter"
        }
        if lower.contains("flood") || lower.contains("tsunami") {
            return "emergency shelter evacuation center"
        }
        if lower.contains("radiological") || lower.contains("nuclear") {
            return "fallout shelter emergency shelter"
        }
        return "emergency shelter"
    }
}
