// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// The driver's vehicle: make/model, fuel economy, and tank size — the
/// inputs for range tracking and timely "fuel soon" recommendations.
/// The efficiency model folds in CURRENT DRIVING HABITS (average speed and
/// idling fraction): sustained speed above ~55 mph costs ~1.2%/mph to
/// aerodynamic drag, and idling burns fuel with zero miles. Pure math,
/// pinned by FLOWSTests.
struct VehicleProfile: Codable, Equatable {
    var make: String
    var model: String
    var year: String? = nil
    var fuelType: FuelType
    /// Tank/battery size in fuel units (gal, or kWh for electric).
    var tankCapacityUnits: Double
    /// Rated combined economy in miles per unit (mpg, or mi/kWh).
    var ratedMilesPerUnit: Double
    /// City/highway split from the spec table (nil for hand-entered
    /// vehicles) — lets predictions interpolate economy BY CURRENT SPEED
    /// instead of one flat number.
    var cityMilesPerUnit: Double? = nil
    var highwayMilesPerUnit: Double? = nil
    /// Towing ratings persisted WITH the vehicle (curated table or EPA
    /// class-typical) — resolving them by name lookup left EPA-path
    /// vehicles with no GVWR and no violation alerts.
    var gvwrLbs: Double? = nil
    var towCapacityLbs: Double? = nil
    var gcwrLbs: Double? = nil

    var displayName: String {
        [year ?? "", make, model].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Full-tank range at rated economy, before habit adjustments.
    var ratedRangeMiles: Double { tankCapacityUnits * ratedMilesPerUnit }

    /// Habit multiplier on economy: 1.0 at or below 55 mph with no idling;
    /// −1.2% per mph above 55 (drag), and idling time is pure loss (an hour
    /// stopped with the engine running moves nothing). Clamped to [0.5, 1].
    static func efficiencyFactor(averageSpeedMph: Double, idleFraction: Double) -> Double {
        let speedPenalty = max(averageSpeedMph - 55, 0) * 0.012
        let idlePenalty = min(max(idleFraction, 0), 1) * 0.5
        return min(max(1 - speedPenalty - idlePenalty, 0.5), 1)
    }

    /// Speed-aware economy when the spec table supplied a city/highway
    /// split: city figure through 30 mph, linear city→highway ramp from
    /// 30–55, highway at 55–65, then the −1.2%/mph drag penalty past 65.
    /// Falls back to the flat rated number for hand-entered vehicles.
    func milesPerUnit(atSpeedMph mph: Double) -> Double {
        guard let city = cityMilesPerUnit, let highway = highwayMilesPerUnit else {
            return ratedMilesPerUnit
        }
        switch mph {
        case ..<30:
            return city
        case ..<55:
            return city + (highway - city) * (mph - 30) / 25
        case ..<65:
            return highway
        default:
            return max(highway * (1 - (mph - 65) * 0.012), highway * 0.6)
        }
    }

    /// The tank's effective range at the given habits: the city/highway
    /// interpolation (when known) handles the speed dependence; the habit
    /// factor then only charges what the split doesn't (idling; drag past
    /// 55 for flat-rated vehicles).
    func effectiveRangeMiles(averageSpeedMph: Double, idleFraction: Double) -> Double {
        if cityMilesPerUnit != nil {
            let idleFactor = min(max(1 - min(max(idleFraction, 0), 1) * 0.5, 0.5), 1)
            return tankCapacityUnits * milesPerUnit(atSpeedMph: averageSpeedMph) * idleFactor
        }
        return ratedRangeMiles
            * Self.efficiencyFactor(averageSpeedMph: averageSpeedMph, idleFraction: idleFraction)
    }

    /// Fraction of a tank left after `milesSinceFill` at the given habits.
    func fuelFractionAfter(
        milesSinceFill: Double, averageSpeedMph: Double, idleFraction: Double
    ) -> Double {
        let range = effectiveRangeMiles(averageSpeedMph: averageSpeedMph,
                                        idleFraction: idleFraction)
        guard range > 0 else { return 0 }
        return min(max(1 - milesSinceFill / range, 0), 1)
    }

    /// Miles of driving left in the tank at the given habits.
    func expectedRangeMiles(
        milesSinceFill: Double, averageSpeedMph: Double, idleFraction: Double
    ) -> Double {
        max(effectiveRangeMiles(averageSpeedMph: averageSpeedMph,
                                idleFraction: idleFraction) - milesSinceFill, 0)
    }

    /// Keep a safety reserve: recommend fueling when remaining range minus
    /// the reserve no longer comfortably covers the next opportunity.
    static let reserveMiles: Double = 40

    static func shouldRecommendFuel(
        rangeRemainingMiles: Double, milesToNextStation: Double, reserveMiles: Double = reserveMiles
    ) -> Bool {
        rangeRemainingMiles - reserveMiles <= milesToNextStation
    }
}

/// Persisted vehicle + live driving-habit tracking (rolling average speed and
/// idle fraction from GPS fixes while navigating) + tank odometer.
@MainActor
final class VehicleStore: ObservableObject {
    @Published var profile: VehicleProfile? {
        didSet { persistProfile() }
    }
    /// Miles driven since the last fill-up (persisted — a trip can span
    /// app launches).
    @Published private(set) var milesSinceFill: Double {
        didSet { defaults.set(milesSinceFill, forKey: Self.milesKey) }
    }

    /// Rolling driving habits (exponential decay so the last ~hour dominates).
    private(set) var averageSpeedMph: Double = 55
    private(set) var idleFraction: Double = 0

    /// TOWING: separate consumption pattern — the multiplier applies at
    /// read time so towing miles never contaminate normal-pattern learning.
    @Published var towingActive = false

    /// Refuel-prediction learning (analog-gauge answers), persisted.
    @Published private(set) var refuelLearning = RefuelLearning() {
        didSet {
            if let data = try? JSONEncoder().encode(refuelLearning) {
                defaults.set(data, forKey: Self.learningKey)
            }
        }
    }

    /// VEHICLE TELEMETRY hook: when a source exists (OEM cloud API such as
    /// FordPass/Tesla Fleet, a Smartcar-style aggregator, or a Bluetooth
    /// OBD-II reader), it supplies real fuel fraction + tire pressures and
    /// overrides the odometer estimate. CarPlay itself never provides these
    /// to third-party apps.
    var telemetry: () -> (fuelFraction: Double?, tirePressuresPsi: [Double]?) = { (nil, nil) }

    /// Trailer/towing signal ladder: OEM cloud (FordPass-class trailer
    /// status), OBD OEM PIDs, or MFi accessory — ANY source returning true
    /// flips the app's towing mode automatically (AppModel observes this).
    var telemetryTowingDetected: () -> Bool? = { nil }

    private let defaults: UserDefaults
    private static let profileKey = "flows.vehicleProfile"
    private static let milesKey = "flows.milesSinceFill"
    private static let learningKey = "flows.refuelLearning"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        milesSinceFill = defaults.double(forKey: Self.milesKey)
        if let data = defaults.data(forKey: Self.profileKey),
           let saved = try? JSONDecoder().decode(VehicleProfile.self, from: data) {
            profile = saved
        }
        if let data = defaults.data(forKey: Self.learningKey),
           let saved = try? JSONDecoder().decode(RefuelLearning.self, from: data) {
            refuelLearning = saved
        }
    }

    /// Model's guess at the tank fraction RIGHT NOW (before any refuel).
    var predictedFuelFraction: Double? {
        profile?.fuelFractionAfter(milesSinceFill: milesSinceFill,
                                   averageSpeedMph: averageSpeedMph,
                                   idleFraction: idleFraction)
    }

    /// Analog-gauge answer: the driver says where the needle was BEFORE
    /// filling. Trains the learning, then assumes a full tank.
    func recordRefuel(reportedFractionBefore: Double) {
        if let predicted = predictedFuelFraction {
            var learning = refuelLearning
            learning.record(predictedFraction: predicted,
                            reportedFraction: reportedFractionBefore)
            refuelLearning = learning
        }
        filledUp()
    }

    /// Feed one GPS fix: accumulate tank consumption and update habit averages.
    func recordFix(speedMps: Double, deltaMeters: Double) {
        // `milesSinceFill` tracks tank ENERGY consumed, in normal-mile
        // equivalents — a mile driven while towing burns 1/towingEconomyFactor
        // (≈1.33) normal-miles of range, so it must be charged at the economy
        // in force WHEN it was driven. The old code added raw miles and applied
        // the towing factor to the whole remaining range, which re-discounted
        // already-consumed miles and OVER-estimated remaining range while towing.
        let miles = max(deltaMeters, 0) / 1609.344
        milesSinceFill += towingActive ? miles / TowingLimits.towingEconomyFactor : miles
        let mph = max(speedMps, 0) * 2.236936
        // Time constant = 1/alpha samples: 0.0003 at 1 Hz ≈ 55 min — the
        // documented "last hour". The old 0.02 was a ~50 SECOND window, so a
        // single stoplight drove idleFraction to ~0.9 and halved the
        // predicted range while parked.
        let alpha = 0.0003
        if mph > 1 {
            averageSpeedMph = averageSpeedMph * (1 - alpha) + mph * alpha
        }
        idleFraction = idleFraction * (1 - alpha) + (mph <= 1 ? 1 : 0) * alpha
    }

    /// The driver filled the tank (arriving at a gas stop, or told us so).
    func filledUp() {
        milesSinceFill = 0
    }

    var expectedRangeMiles: Double? {
        guard let profile else { return nil }
        // Real telemetry (OEM API / OBD reader) wins over the odometer model.
        if let fraction = telemetry().fuelFraction {
            let full = profile.effectiveRangeMiles(
                averageSpeedMph: averageSpeedMph, idleFraction: idleFraction)
            return full * min(max(fraction, 0), 1)
                * (towingActive ? TowingLimits.towingEconomyFactor : 1)
        }
        return profile.expectedRangeMiles(
            milesSinceFill: milesSinceFill,
            averageSpeedMph: averageSpeedMph, idleFraction: idleFraction)
            * (towingActive ? TowingLimits.towingEconomyFactor : 1)
    }

    private func persistProfile() {
        if let profile, let data = try? JSONEncoder().encode(profile) {
            defaults.set(data, forKey: Self.profileKey)
        } else if profile == nil {
            defaults.removeObject(forKey: Self.profileKey)
        }
    }
}
