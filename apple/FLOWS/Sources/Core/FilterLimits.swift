// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Driver-tunable filter limits (the right-hand sliders). Pure — the
/// clearance, grade, and bridge-weight admission rules live here so the
/// canonical scenario (10 ft van that cannot pass a 12 ft post; 14° grade
/// ceiling towing heavy) is pinned by FLOWSTests.
///
/// The rules and the slider default are computed in rust/flows-core
/// (vehicle_policy.rs) and called through rust/flows-bridge; the defaults are
/// read from Rust. Swift still owns the `flows.maxGradeDegrees` preference the
/// app model writes when the driver moves the slider. Pinned bit for bit to
/// the Swift this replaced by
/// rust/flows-bridge/tests/fixtures/swift_vehicle_policy_oracle.tsv.
struct FilterLimits {
    var vehicleHeightMeters: Double = FilterLimits.defaultVehicleHeightMeters   // 13'6"
    /// Grade limit as PERCENT (what USGS elevation profiles measure). The UI
    /// slider works in DEGREES — a driver towing heavy thinks "14°", which is
    /// tan(14°) ≈ 24.9% — and converts via `degreesToPercent`.
    var maxGradePercent: Double = FilterLimits.defaultMaxGradePercent
    /// A posted bridge limit must exceed the vehicle height by this margin —
    /// a 10 ft vehicle cannot take a bridge posted 12 ft or smaller (2 ft
    /// of breathing room for load shift and repaving).
    var clearanceMarginMeters: Double = FilterLimits.defaultClearanceMarginMeters   // 2 ft
    /// The rig's total weight (vehicle + what it tows, pounds) for the
    /// bridge-weight check; nil = no weights entered → never excludes.
    var rigWeightLbs: Double? = nil

    static let defaultVehicleHeightMeters = flows_vehicle_policy_filter_default_vehicle_height_meters()
    static let defaultMaxGradePercent = flows_vehicle_policy_filter_default_max_grade_percent()
    static let defaultClearanceMarginMeters = flows_vehicle_policy_filter_default_clearance_margin_meters()

    static func degreesToPercent(_ degrees: Double) -> Double {
        flows_vehicle_policy_degrees_to_percent(degrees)
    }

    /// True when every posted clearance is passable for this vehicle.
    /// "Or smaller" is inclusive: a 10 ft vehicle fails a 12 ft post.
    /// nil (no data yet) never excludes a route.
    func passesClearances(_ clearancesMeters: [Double]?) -> Bool {
        // No data and no postings both pass; nothing to send across.
        guard let clearancesMeters, !clearancesMeters.isEmpty else { return true }
        return clearancesMeters.withUnsafeBufferPointer {
            flows_vehicle_policy_passes_clearances(vehicleHeightMeters, clearanceMarginMeters, $0)
        }
    }

    /// True when the route's steepest measured grade stays under the limit.
    /// nil (no data yet) never excludes a route.
    func passesGrade(_ routeMaxGradePercent: Double?) -> Bool {
        flows_vehicle_policy_passes_grade(
            maxGradePercent, routeMaxGradePercent ?? 0, routeMaxGradePercent != nil)
    }

    /// True when every posted weight limit can take the rig's total weight.
    /// A posted limit is the legal maximum the bridge or road carries — AT
    /// the limit is allowed, one pound over is not. nil data (no fetch yet)
    /// or no entered weight never excludes a route.
    func passesWeightLimits(_ limitsLbs: [Double]?) -> Bool {
        // No data and no postings both pass; nothing to send across.
        guard let limitsLbs, !limitsLbs.isEmpty else { return true }
        return limitsLbs.withUnsafeBufferPointer {
            flows_vehicle_policy_passes_weight_limits(rigWeightLbs ?? 0, rigWeightLbs != nil, $0)
        }
    }

    /// The vehicle's share of the rig weight: the weight the driver entered,
    /// else — once a trailer weight is entered — the vehicle's max rating
    /// (GVWR). A trailer alone is not the rig, and the max is the safe side.
    /// Nothing entered stays 0, so no road is excluded on a guess.
    static func rigVehicleLbs(entered: Double, towedLbs: Double,
                              ratedMaxLbs: @autoclosure () -> Double?) -> Double {
        if entered > 0 { return entered }
        return towedLbs > 0 ? ratedMaxLbs() ?? 0 : 0
    }

    /// A height the way a clearance sign reads it: whole inches first, then
    /// feet and inches. Truncating feet and then inches showed a posted
    /// 13'6" (4.1148 m, 13.4999… ft) as 13'5", and rounding the inches alone
    /// showed 14'0" as 13'12".
    static func feetAndInches(meters: Double) -> String {
        let inches = (meters / 0.0254).rounded()
        guard inches.isFinite, abs(inches) < 1_000_000 else { return "—" }
        let whole = Int(inches)
        return "\(whole / 12)'\(whole % 12)\""
    }

    static func feetAndInches(feet: Double) -> String {
        feetAndInches(meters: feet * 0.3048)
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
        flows_vehicle_policy_default_max_grade_degrees(
            publishedMaxGradePercent ?? 0, publishedMaxGradePercent != nil,
            gvwrLbs ?? 0, gvwrLbs != nil,
            towCapacityLbs ?? 0, towCapacityLbs != nil,
            heightFeet, towing, trailerWeightLbs)
    }
}
