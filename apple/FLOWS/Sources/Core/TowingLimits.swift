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
            gcwrLbs ?? (gvwrLbs.flatMap { g in towCapacityLbs.map { g + $0 } })
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
        var r: Ratings
        switch heightFeet {
        case ..<5.0:   r = Ratings(gvwrLbs: 4_300, towCapacityLbs: 1_000, gcwrLbs: nil)
        case ..<6.0:   r = Ratings(gvwrLbs: 6_000, towCapacityLbs: 3_500, gcwrLbs: 11_000)
        case ..<7.0:   r = Ratings(gvwrLbs: 7_100, towCapacityLbs: 9_000, gcwrLbs: 15_500)
        case ..<10.0:  r = Ratings(gvwrLbs: 9_500, towCapacityLbs: 5_000, gcwrLbs: 15_000)
        default:       r = Ratings(gvwrLbs: 26_000, towCapacityLbs: 10_000, gcwrLbs: 36_000)
        }
        // EVs carry heavy packs: typical GVWR runs ~1,200 lb above the class.
        if fuelType == .electric, let g = r.gvwrLbs { r.gvwrLbs = g + 1_200 }
        r.estimated = true
        return r
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
        var out: [Violation] = []
        if let gvwr = ratings.gvwrLbs, vehicleWeightLbs > gvwr {
            out.append(.overGVWR(by: vehicleWeightLbs - gvwr))
        }
        if let cap = ratings.towCapacityLbs, towedWeightLbs > cap {
            out.append(.overTowCapacity(by: towedWeightLbs - cap))
        }
        if let gcwr = ratings.effectiveGCWR,
           vehicleWeightLbs + towedWeightLbs > gcwr {
            out.append(.overGCWR(by: vehicleWeightLbs + towedWeightLbs - gcwr))
        }
        return out
    }

    /// Towing burns meaningfully more fuel — a separate multiplier so the
    /// towing pattern never contaminates the vehicle's NORMAL consumption
    /// learning (unique pattern, as specified).
    static let towingEconomyFactor = 0.75
}
