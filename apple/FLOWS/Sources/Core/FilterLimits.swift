// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
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

    /// The grade slider's DEFAULT, derived from the vehicle — informally,
    /// "the grade where a parking brake is highly encouraged." The driver can
    /// always slide past it; this only sets where the slider starts.
    ///
    /// The heuristic, in grade PERCENT (converted to degrees at the end):
    ///
    /// 1. Start from the maker's published steep-grade guidance when the
    ///    curated table has one (heavy chassis handbooks: the sustained grade
    ///    above which engine braking is called for). Otherwise start from the
    ///    weight class via GVWR — heavier rigs hold less speed uphill and
    ///    fade brakes sooner downhill:
    ///      under 6,000 lb (cars/crossovers)       18%
    ///      under 10,000 lb (pickups, big SUVs)    15%
    ///      under 14,000 lb (HD pickups, cutaways) 12%
    ///      under 26,000 lb (RVs, box trucks)       9%
    ///      26,000 lb and up (semis, buses)         6%
    ///    No GVWR at all → the same ladder keyed off vehicle height
    ///    (the only physical size signal left).
    /// 2. Towing lowers it — the trailer pushes downhill and doubles brake
    ///    load: any trailer caps the default at 10%; a trailer at 60% of tow
    ///    capacity (or 5,000+ lb when capacity is unknown) caps it at 8%;
    ///    at or over capacity caps it at 6%.
    /// 3. Convert percent → degrees, clamp to the slider's 2°–15° range,
    ///    round to its 0.5° step.
    static func vehicleDefaultMaxGradeDegrees(
        publishedMaxGradePercent: Double?,
        gvwrLbs: Double?,
        towCapacityLbs: Double?,
        heightFeet: Double,
        towing: Bool,
        trailerWeightLbs: Double
    ) -> Double {
        var percent: Double
        if let published = publishedMaxGradePercent {
            percent = published
        } else if let gvwr = gvwrLbs {
            switch gvwr {
            case ..<6_000: percent = 18
            case ..<10_000: percent = 15
            case ..<14_000: percent = 12
            case ..<26_000: percent = 9
            default: percent = 6
            }
        } else {
            switch heightFeet {
            case ..<5.5: percent = 18
            case ..<7.0: percent = 15
            case ..<9.5: percent = 12
            default: percent = 9
            }
        }
        if towing || trailerWeightLbs > 0 {
            percent = min(percent, 10)
            let heavyTrailer: Bool
            if let cap = towCapacityLbs, cap > 0 {
                heavyTrailer = trailerWeightLbs >= cap * 0.6
                if trailerWeightLbs >= cap { percent = min(percent, 6) }
            } else {
                heavyTrailer = trailerWeightLbs >= 5_000
            }
            if heavyTrailer { percent = min(percent, 8) }
        }
        let degrees = atan(percent / 100) * 180 / .pi
        let clamped = min(max(degrees, 2), 15)
        return (clamped * 2).rounded() / 2
    }
}
