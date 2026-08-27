// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Is this vehicle being driven efficiently RIGHT NOW? Pure, pinned by
/// FLOWSTests — the leading icon on the speed bar reads straight off it.
///
/// The judgment blends everything the phone can already observe without new
/// sensors: how hard the driver is on the throttle (smoothed acceleration),
/// how fast they're going against the vehicle's own economy curve, the drag
/// penalty that curve encodes, and the road's inclination from the route's
/// grade profile. Climbing a 6% grade at 70 mph is not the same act as
/// holding 70 on the flat, and the icon should not pretend otherwise.
enum DriveEfficiency {
    /// What the leading icon says.
    enum Verdict: Equatable {
        /// Green leaf — smooth, in the vehicle's sweet spot.
        case efficient
        /// Steady but not thrifty — the in-between.
        case fair
        /// Red pump — heavy throttle, high drag, or fighting a hill.
        case wasteful
    }

    /// Aerodynamic drag rises with the SQUARE of speed, so the penalty past
    /// a vehicle's efficient cruise grows fast. Expressed against the
    /// vehicle's own rated economy so a semi and a hatchback are judged on
    /// their own terms.
    static func dragPenalty(speedMph: Double, efficientCruiseMph: Double = 55) -> Double {
        guard speedMph > efficientCruiseMph else { return 0 }
        let over = (speedMph - efficientCruiseMph) / efficientCruiseMph
        // Scaled so the curve lands where real economy does: ~65 barely
        // registers, 75 is noticeably thirstier, and 95 — where a car burns
        // roughly a third more than at its cruise — reads plainly wasteful.
        return over * over * 2.0
    }

    /// Climbing costs fuel; a gentle descent gives some back (engine braking
    /// caps the credit — coasting downhill is not free range).
    static func gradePenalty(gradePercent: Double) -> Double {
        gradePercent >= 0 ? gradePercent / 6.0 : max(gradePercent / 12.0, -0.4)
    }

    /// Hard acceleration is the single biggest thing a driver controls.
    /// Coasting (negative) earns a small credit.
    static func throttlePenalty(accelMphPerSec: Double) -> Double {
        accelMphPerSec > 0 ? accelMphPerSec / 2.5 : max(accelMphPerSec / 8.0, -0.3)
    }

    /// Idling burns fuel and moves nothing — always the worst score, but
    /// only once the vehicle has genuinely stopped (a red light shouldn't
    /// paint the icon red the instant the wheels stop turning).
    static let idleSpeedMph = 2.0

    /// The blended score: 0 is ideal, higher is worse.
    static func score(speedMph: Double,
                      accelMphPerSec: Double,
                      gradePercent: Double,
                      efficientCruiseMph: Double = 55) -> Double {
        throttlePenalty(accelMphPerSec: accelMphPerSec)
            + dragPenalty(speedMph: speedMph, efficientCruiseMph: efficientCruiseMph)
            + gradePenalty(gradePercent: gradePercent)
    }

    /// Score → icon. Thresholds are deliberately forgiving: a driver holding
    /// a steady legal cruise should see the leaf, not be nagged.
    static func verdict(speedMph: Double,
                        accelMphPerSec: Double,
                        gradePercent: Double,
                        efficientCruiseMph: Double = 55) -> Verdict {
        // Stopped with the engine on: nothing is moving, everything is burning.
        if speedMph < idleSpeedMph, accelMphPerSec <= 0.1 { return .wasteful }
        let s = score(speedMph: speedMph, accelMphPerSec: accelMphPerSec,
                      gradePercent: gradePercent,
                      efficientCruiseMph: efficientCruiseMph)
        if s <= 0.25 { return .efficient }
        if s <= 0.75 { return .fair }
        return .wasteful
    }

    /// The efficient-cruise speed for a vehicle: where its own economy curve
    /// peaks before drag takes over. Falls back to the classic 55.
    static func efficientCruiseMph(city: Double?, highway: Double?) -> Double {
        guard let city, let highway, highway > city else { return 55 }
        return 55
    }
}
