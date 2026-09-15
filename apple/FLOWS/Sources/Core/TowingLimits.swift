// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Towing safety checks against the manufacturer's ratings — pure, pinned by
/// FLOWSTests. The towing card's sliders feed these; exceeding a rating
/// flashes red with WHY it matters.
///
/// The class estimates, the effective GCWR and the violation check are
/// computed in rust/flows-core (vehicle_policy.rs) and called through
/// rust/flows-bridge; the titles and consequences are copy and stay here.
/// Pinned bit for bit to the Swift this replaced by
/// rust/flows-bridge/tests/fixtures/swift_vehicle_policy_oracle.tsv.
enum TowingLimits {

    struct Ratings: Equatable {
        /// GVWR: max allowable weight of the VEHICLE itself (curb + people
        /// + cargo + tongue weight).
        var gvwrLbs: Double?
        /// Max weight the vehicle is rated to PULL.
        var towCapacityLbs: Double?
        /// GCWR: max of the whole rig — vehicle + passengers + cargo + the
        /// loaded trailer. Estimated as GVWR + tow capacity when the maker
        /// doesn't publish one.
        var gcwrLbs: Double?

        var effectiveGCWR: Double? {
            // Presence crosses on its own: a present effective GCWR can be NaN.
            guard flows_vehicle_policy_towing_has_effective_gcwr(
                gvwrLbs != nil, towCapacityLbs != nil, gcwrLbs != nil) else { return nil }
            return flows_vehicle_policy_towing_effective_gcwr_lbs(
                gvwrLbs ?? 0, gvwrLbs != nil,
                towCapacityLbs ?? 0, towCapacityLbs != nil,
                gcwrLbs ?? 0, gcwrLbs != nil)
        }

        /// True when these numbers are CLASS-TYPICAL estimates rather than the
        /// manufacturer's published figures — the card labels them as such.
        var estimated: Bool = false
    }

    /// Class-typical ratings estimated from the vehicle's physical shape, for
    /// vehicles with no published figures (EPA-database entries carry economy
    /// but not weights). Best-effort industry-typical numbers per size class —
    /// always labeled "estimated" in the UI, never presented as published.
    static func estimatedRatings(heightFeet: Double, fuelType: FuelType) -> Ratings {
        // [gvwr, tow, gcwr, estimated], NaN for an absent rating.
        let slots = flows_vehicle_policy_towing_estimated_ratings(heightFeet, fuelType.rustCode)
        guard slots.len() == 4 else {
            return Ratings(gvwrLbs: nil, towCapacityLbs: nil, gcwrLbs: nil, estimated: true)
        }
        func rating(_ v: Double) -> Double? { v.isNaN ? nil : v }
        return Ratings(gvwrLbs: rating(slots[0]), towCapacityLbs: rating(slots[1]),
                       gcwrLbs: rating(slots[2]), estimated: slots[3] != 0)
    }

    enum Violation: Equatable {
        case overGVWR(by: Double)
        case overTowCapacity(by: Double)
        case overGCWR(by: Double)

        var title: String {
            switch self {
            case .overGVWR(let by):
                return String(format: "OVER GVWR by %.0f lb", by)
            case .overTowCapacity(let by):
                return String(format: "OVER TOW CAPACITY by %.0f lb", by)
            case .overGCWR(let by):
                return String(format: "OVER GCWR by %.0f lb", by)
            }
        }

        /// What actually goes wrong — the education next to the red flash.
        var consequences: String {
            switch self {
            case .overGVWR:
                return "Overloaded axles and tires can blow out; brakes fade "
                    + "and stopping distances stretch; suspension and frame "
                    + "damage; steering goes light. Insurance can deny claims "
                    + "for an overloaded vehicle."
            case .overTowCapacity:
                return "Transmission and engine overheat on grades; trailer "
                    + "sway can become uncontrollable at speed; hitch or "
                    + "receiver can fail; brakes may not stop the combined "
                    + "load in time."
            case .overGCWR:
                return "The whole rig exceeds what the drivetrain and brakes "
                    + "were engineered for — runaway risk on descents, "
                    + "overheating on climbs, and catastrophic brake fade in "
                    + "emergency stops."
            }
        }
    }

    /// Evaluate the rig. `vehicleWeightLbs` = actual loaded vehicle weight
    /// (what a scale would read without the trailer); `towedWeightLbs` =
    /// actual loaded trailer weight. Unknown ratings are skipped (no data
    /// never fabricates a violation).
    static func check(
        vehicleWeightLbs: Double, towedWeightLbs: Double, ratings: Ratings
    ) -> [Violation] {
        // [over GVWR, over tow capacity, over GCWR], NaN where not exceeded.
        let over = flows_vehicle_policy_towing_check(
            vehicleWeightLbs, towedWeightLbs,
            ratings.gvwrLbs ?? 0, ratings.gvwrLbs != nil,
            ratings.towCapacityLbs ?? 0, ratings.towCapacityLbs != nil,
            ratings.gcwrLbs ?? 0, ratings.gcwrLbs != nil)
        guard over.len() == 3 else { return [] }
        var out: [Violation] = []
        if !over[0].isNaN { out.append(.overGVWR(by: over[0])) }
        if !over[1].isNaN { out.append(.overTowCapacity(by: over[1])) }
        if !over[2].isNaN { out.append(.overGCWR(by: over[2])) }
        return out
    }

    /// Towing burns meaningfully more fuel — a separate multiplier so the
    /// towing pattern never contaminates the vehicle's NORMAL consumption
    /// learning (unique pattern, as specified).
    static let towingEconomyFactor = flows_vehicle_policy_towing_economy_factor()
}
