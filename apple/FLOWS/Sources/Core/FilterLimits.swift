// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Driver-tunable filter limits (the right-hand sliders). Pure — the
/// clearance and grade admission rules live here so the canonical scenario
/// (10 ft van that cannot pass a 12 ft post; 14° grade ceiling towing heavy)
/// is pinned by FLOWSTests.
struct FilterLimits {
    var vehicleHeightMeters: Double = 4.115   // 13'6"
    /// Grade limit as PERCENT (what USGS elevation profiles measure). The UI
    /// slider works in DEGREES — a driver towing heavy thinks "14°", which is
    /// tan(14°) ≈ 24.9% — and converts via `degreesToPercent`.
    var maxGradePercent: Double = 6.0
    /// A posted bridge limit must exceed the vehicle height by this margin —
    /// a 10 ft vehicle cannot take a bridge posted 12 ft or smaller (2 ft
    /// of breathing room for load shift and repaving).
    var clearanceMarginMeters: Double = 0.6096   // 2 ft

    static func degreesToPercent(_ degrees: Double) -> Double {
        tan(degrees * .pi / 180) * 100
    }

    /// True when every posted clearance is passable for this vehicle.
    /// "Or smaller" is inclusive: a 10 ft vehicle fails a 12 ft post.
    /// nil (no data yet) never excludes a route.
    func passesClearances(_ clearancesMeters: [Double]?) -> Bool {
        guard let clearancesMeters else { return true }
        let minimumPassable = vehicleHeightMeters + clearanceMarginMeters
        return !clearancesMeters.contains { $0 <= minimumPassable + 1e-9 }
    }

    /// True when the route's steepest measured grade stays under the limit.
    /// nil (no data yet) never excludes a route.
    func passesGrade(_ routeMaxGradePercent: Double?) -> Bool {
        (routeMaxGradePercent ?? 0) < maxGradePercent
    }
}
