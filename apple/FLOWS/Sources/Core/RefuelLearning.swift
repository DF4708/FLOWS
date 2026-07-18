// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
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
struct RefuelLearning: Codable, Equatable {
    /// |predicted − reported| per answered check-in, most recent last.
    private(set) var errors: [Double] = []

    static let accuracyFloor = 0.8
    static let window = 10

    /// Rolling accuracy over the last `window` answers: 1 − mean(|error|).
    /// No data yet → 0 (the system must earn its confidence).
    var accuracy: Double {
        guard !errors.isEmpty else { return 0 }
        let recent = errors.suffix(Self.window)
        return max(0, 1 - recent.reduce(0, +) / Double(recent.count))
    }

    /// Record one answered gauge: model predicted `predictedFraction` of a
    /// tank remained; driver reported `reportedFraction`.
    mutating func record(predictedFraction: Double, reportedFraction: Double) {
        let p = min(max(predictedFraction, 0), 1)
        let r = min(max(reportedFraction, 0), 1)
        errors.append(abs(p - r))
        if errors.count > 50 { errors.removeFirst(errors.count - 50) }
    }

    /// Ask the gauge? Only when check-ins are enabled AND accuracy is under
    /// the floor (it re-arms automatically if accuracy decays below 80%).
    func shouldPrompt(checkInsEnabled: Bool) -> Bool {
        checkInsEnabled && accuracy < Self.accuracyFloor
    }
}
