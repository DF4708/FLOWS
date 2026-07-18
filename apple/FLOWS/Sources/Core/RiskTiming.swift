// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Time-aware risk: a hazard only counts if it will still be there WHEN THE
/// DRIVER ARRIVES. A 10-hour route with an alert at the far end that expires
/// in 1 hour carries no real risk — the storm is long gone by the time the
/// vehicle reaches that stretch. Pure functions, pinned by FLOWSTests.
enum RiskTiming {

    /// Will an alert still be active when the driver reaches its stretch of
    /// road `arrivalOffset` seconds from now? Unknown expiry → assume active
    /// (never silently discount a hazard we can't time).
    static func isActive(expires: Date?, arrivalOffset: TimeInterval, now: Date = Date()) -> Bool {
        guard let expires else { return true }
        return expires > now.addingTimeInterval(max(arrivalOffset, 0))
    }

    /// Seconds from departure to each of `sampleCount` uniformly spaced
    /// corridor samples on a route that takes `totalTravelSeconds` end to end.
    static func arrivalOffsets(sampleCount: Int, totalTravelSeconds: TimeInterval) -> [TimeInterval] {
        guard sampleCount > 0 else { return [] }
        guard sampleCount > 1 else { return [0] }
        let total = max(totalTravelSeconds, 0)
        return (0..<sampleCount).map { total * Double($0) / Double(sampleCount - 1) }
    }
}
