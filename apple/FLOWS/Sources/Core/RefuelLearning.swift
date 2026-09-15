// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Refuel-prediction learning: every time the driver answers the analog
/// gauge ("where was the needle before you filled?"), the reported fraction
/// is compared to what the odometer model predicted. While accuracy sits
/// below the 80% floor the gauge keeps asking (unless the driver opted
/// out); above it the check-ins go quiet — and resume if accuracy slips.
/// No answer counts as "yes, refueled" and doesn't harm the accuracy stat.
/// Pure; persisted by VehicleStore; pinned by FLOWSTests.
/// The error, the rolling accuracy, the prompt rule and the retained window
/// are computed in rust/flows-core (learning.rs) and called through
/// rust/flows-bridge, pinned bit for bit to the Swift this replaced by
/// rust/flows-bridge/tests/fixtures/swift_learning_oracle.tsv.
struct RefuelLearning: Codable, Equatable {
    /// |predicted − reported| per answered check-in, most recent last.
    private(set) var errors: [Double] = []

    static let accuracyFloor = flows_learning_refuel_accuracy_floor()
    static let window = Int(flows_learning_refuel_window())

    /// Rolling accuracy over the last `window` answers: 1 − mean(|error|).
    /// No data yet → 0 (the system must earn its confidence).
    var accuracy: Double {
        // No answers is no accuracy (and an empty buffer never crosses).
        guard !errors.isEmpty else { return 0 }
        return errors.withUnsafeBufferPointer { flows_learning_refuel_accuracy($0) }
    }

    /// Record one answered gauge: model predicted `predictedFraction` of a
    /// tank remained; driver reported `reportedFraction`.
    mutating func record(predictedFraction: Double, reportedFraction: Double) {
        errors.append(flows_learning_refuel_error(predictedFraction, reportedFraction))
        let retained = Int(flows_learning_refuel_retained())
        if errors.count > retained { errors.removeFirst(errors.count - retained) }
    }

    /// Ask the gauge? Only when check-ins are enabled AND accuracy is under
    /// the floor (it re-arms automatically if accuracy decays below 80%).
    func shouldPrompt(checkInsEnabled: Bool) -> Bool {
        flows_learning_refuel_should_prompt(checkInsEnabled, accuracy)
    }
}

/// The gap after which the fuel reading on screen stops meaning anything.
///
/// FLOWS only knows about fuel it watched you buy. Leave the app alone for a
/// week and the tank has almost certainly been filled without it — so the
/// gauge is a guess, and the honest move is to ask once rather than keep
/// predicting range off a stale number.
enum StaleGauge {
    /// A week away is the threshold: shorter gaps are ordinary weekday use.
    static let gap: TimeInterval = flows_learning_stale_gauge_gap_seconds()

    /// True when the app has been away long enough that the reading can't be
    /// trusted. A first run has nothing to compare against, so it is never
    /// stale — asking a brand-new user whether they just refuelled is
    /// nonsense.
    static func wentStale(lastUsed: Date?, now: Date = Date()) -> Bool {
        flows_learning_gauge_went_stale(
            lastUsed?.timeIntervalSinceReferenceDate ?? 0, lastUsed != nil,
            now.timeIntervalSinceReferenceDate)
    }
}
