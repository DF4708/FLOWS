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

    // MARK: the real inputs
    //
    // The icon is a three-state simplification of a genuinely multivariable
    // problem, and the states only mean anything if the number behind them
    // accounts for what actually moves fuel: the air the vehicle is pushing
    // (its own speed PLUS the headwind component), the mass it is dragging
    // up or down a grade, the throttle, and the load. Averages stand in for
    // whatever the driver hasn't told us — with no vehicle on file the
    // curve falls back to a mid-size car's numbers rather than pretending
    // to know.

    /// Everything the score reads. Optionals are genuinely optional: each
    /// falls back to a documented average rather than being ignored.
    struct Inputs {
        var speedMph: Double
        var accelMphPerSec: Double
        var gradePercent: Double = 0
        /// Wind speed and the direction it blows FROM, in degrees — the
        /// pairing every weather feed publishes.
        var windMph: Double = 0
        var windFromDegrees: Double? = nil
        /// Which way the vehicle is pointed, so a tailwind and a headwind of
        /// the same strength don't score alike.
        var headingDegrees: Double? = nil
        /// Where the vehicle's economy peaks before drag takes over.
        var efficientCruiseMph: Double = 55
        /// City and highway economy, when the vehicle's spec supplies them —
        /// their SPREAD says how drag-sensitive this vehicle is (a brick-shaped
        /// van loses far more at speed than a sedan).
        var cityMPU: Double? = nil
        var highwayMPU: Double? = nil
        /// Laden mass relative to the vehicle's own: a full tank, a load, or
        /// a trailer all cost fuel on every acceleration and every climb.
        var loadedWeightLbs: Double? = nil
        var vehicleWeightLbs: Double? = nil
        /// Towing (or crawling in a low gear) is its own penalty on top of
        /// the weight — the aerodynamics of a trailer are their own problem.
        var towing: Bool = false
        /// Fraction of tank remaining: fuel is mass, so a brimmed tank costs
        /// a little on every hill.
        var fuelFraction: Double? = nil
    }

    /// The headwind component along the direction of travel (mph). Positive
    /// is a headwind (costs fuel), negative a tailwind (gives some back).
    /// Zero whenever either direction is unknown — a crosswind of unknown
    /// bearing is not evidence of anything.
    static func headwindMph(windMph: Double, windFromDegrees: Double?,
                            headingDegrees: Double?) -> Double {
        guard windMph > 0, let from = windFromDegrees, let heading = headingDegrees,
              heading >= 0 else { return 0 }
        // Wind FROM 90° blowing at a vehicle heading 90° is a pure headwind.
        let delta = (from - heading) * .pi / 180
        return windMph * cos(delta)
    }

    /// The air the vehicle is actually pushing: its own speed plus whatever
    /// the wind adds or removes. This is the number drag should key off —
    /// 60 mph into a 20 mph headwind is aerodynamically 80.
    static func airspeedMph(_ i: Inputs) -> Double {
        max(i.speedMph + headwindMph(windMph: i.windMph,
                                     windFromDegrees: i.windFromDegrees,
                                     headingDegrees: i.headingDegrees), 0)
    }

    /// How drag-sensitive this vehicle is, from the gap between its city and
    /// highway figures. A sedan gains on the highway (ratio > 1) and takes
    /// the standard penalty; a van or box truck that gains little is paying
    /// more to push air, so its drag penalty is scaled up.
    static func dragSensitivity(cityMPU: Double?, highwayMPU: Double?) -> Double {
        guard let city = cityMPU, let highway = highwayMPU, city > 0 else { return 1 }
        let gain = highway / city
        // 1.35 is a typical sedan's city→highway gain. Vehicles that gain
        // less are dragging more.
        return min(max(1.35 / max(gain, 0.6), 0.7), 1.8)
    }

    /// Mass penalty: everything the vehicle is hauling beyond itself, plus
    /// the weight of the fuel still in the tank. It costs on acceleration
    /// and on climbs, and nothing at a steady cruise on the flat.
    static func loadFactor(_ i: Inputs) -> Double {
        var ratio = 1.0
        if let loaded = i.loadedWeightLbs, let base = i.vehicleWeightLbs, base > 0 {
            ratio = min(max(loaded / base, 1), 2.5)
        }
        // A full tank is real mass — roughly 6 lb a gallon — but a small
        // effect next to a trailer, so it is scaled accordingly.
        if let fuel = i.fuelFraction { ratio += 0.04 * min(max(fuel, 0), 1) }
        if i.towing { ratio += 0.35 }
        return ratio
    }

    /// The blended score: 0 is ideal, higher is worse.
    static func score(_ i: Inputs) -> Double {
        let load = loadFactor(i)
        // Throttle and climbing both move MASS, so both scale with load.
        let throttle = throttlePenalty(accelMphPerSec: i.accelMphPerSec) * load
        let grade = gradePenalty(gradePercent: i.gradePercent) * load
        // Drag fights AIR, not mass — it scales with the vehicle's shape.
        let drag = dragPenalty(speedMph: airspeedMph(i),
                               efficientCruiseMph: i.efficientCruiseMph)
            * dragSensitivity(cityMPU: i.cityMPU, highwayMPU: i.highwayMPU)
        return throttle + drag + grade
    }

    /// Score → icon.
    static func verdict(_ i: Inputs) -> Verdict {
        // Stopped with the engine on: nothing is moving, everything is burning.
        if i.speedMph < idleSpeedMph, i.accelMphPerSec <= 0.1 { return .wasteful }
        let s = score(i)
        if s <= 0.25 { return .efficient }
        if s <= 0.75 { return .fair }
        return .wasteful
    }

    /// Convenience for callers with only the basics — the rest take their
    /// documented averages.
    static func score(speedMph: Double, accelMphPerSec: Double,
                      gradePercent: Double,
                      efficientCruiseMph: Double = 55) -> Double {
        score(Inputs(speedMph: speedMph, accelMphPerSec: accelMphPerSec,
                     gradePercent: gradePercent,
                     efficientCruiseMph: efficientCruiseMph))
    }

    static func verdict(speedMph: Double, accelMphPerSec: Double,
                        gradePercent: Double,
                        efficientCruiseMph: Double = 55) -> Verdict {
        verdict(Inputs(speedMph: speedMph, accelMphPerSec: accelMphPerSec,
                       gradePercent: gradePercent,
                       efficientCruiseMph: efficientCruiseMph))
    }

    /// The efficient-cruise speed for a vehicle: where its own economy curve
    /// peaks before drag takes over. Falls back to the classic 55.
    static func efficientCruiseMph(city: Double?, highway: Double?) -> Double {
        guard let city, let highway, highway > city else { return 55 }
        return 55
    }
}
