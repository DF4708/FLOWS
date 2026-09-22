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
///
/// The range and economy math lives in rust/flows-core (trip_vehicle.rs) and
/// is called through rust/flows-bridge — a nil city/highway split crosses as
/// a value plus a `has` flag — pinned bit for bit to the Swift this replaced
/// by rust/flows-bridge/tests/fixtures/swift_trip_vehicle_oracle.tsv. The
/// persisted fields, `displayName` and the store stay here.
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

    /// The vehicle's own top speed, when a spec supplied one — the right
    /// end of the HUD's speed bar. Nil falls back to a sane ceiling.
    var topSpeedMph: Double? {
        VehicleSpecs.spec(make: make, model: model)?.topSpeedMph
    }

    /// Full-tank range at rated economy, before habit adjustments.
    var ratedRangeMiles: Double {
        flows_trip_vehicle_rated_range_miles(tankCapacityUnits, ratedMilesPerUnit)
    }

    /// Habit multiplier on economy: 1.0 at or below 55 mph with no idling;
    /// −1.2% per mph above 55 (drag), and idling time is pure loss (an hour
    /// stopped with the engine running moves nothing). Clamped to [0.5, 1].
    static func efficiencyFactor(averageSpeedMph: Double, idleFraction: Double) -> Double {
        flows_trip_vehicle_efficiency_factor(averageSpeedMph, idleFraction)
    }

    /// Speed-aware economy when the spec table supplied a city/highway
    /// split: city figure through 30 mph, linear city→highway ramp from
    /// 30–55, highway at 55–65, then the −1.2%/mph drag penalty past 65.
    /// Falls back to the flat rated number for hand-entered vehicles.
    func milesPerUnit(atSpeedMph mph: Double) -> Double {
        flows_trip_vehicle_miles_per_unit_at_speed(
            tankCapacityUnits, ratedMilesPerUnit,
            cityMilesPerUnit ?? 0, cityMilesPerUnit != nil,
            highwayMilesPerUnit ?? 0, highwayMilesPerUnit != nil, mph)
    }

    /// The tank's effective range at the given habits: the city/highway
    /// interpolation (when known) handles the speed dependence; the habit
    /// factor then only charges what the split doesn't (idling; drag past
    /// 55 for flat-rated vehicles).
    func effectiveRangeMiles(averageSpeedMph: Double, idleFraction: Double) -> Double {
        flows_trip_vehicle_effective_range_miles(
            tankCapacityUnits, ratedMilesPerUnit,
            cityMilesPerUnit ?? 0, cityMilesPerUnit != nil,
            highwayMilesPerUnit ?? 0, highwayMilesPerUnit != nil,
            averageSpeedMph, idleFraction)
    }

    /// Fraction of a tank left after `milesSinceFill` at the given habits.
    func fuelFractionAfter(
        milesSinceFill: Double, averageSpeedMph: Double, idleFraction: Double
    ) -> Double {
        flows_trip_vehicle_fuel_fraction_after(
            tankCapacityUnits, ratedMilesPerUnit,
            cityMilesPerUnit ?? 0, cityMilesPerUnit != nil,
            highwayMilesPerUnit ?? 0, highwayMilesPerUnit != nil,
            milesSinceFill, averageSpeedMph, idleFraction)
    }

    /// Miles of driving left in the tank at the given habits.
    func expectedRangeMiles(
        milesSinceFill: Double, averageSpeedMph: Double, idleFraction: Double
    ) -> Double {
        flows_trip_vehicle_expected_range_miles(
            tankCapacityUnits, ratedMilesPerUnit,
            cityMilesPerUnit ?? 0, cityMilesPerUnit != nil,
            highwayMilesPerUnit ?? 0, highwayMilesPerUnit != nil,
            milesSinceFill, averageSpeedMph, idleFraction)
    }

    /// Keep a safety reserve: recommend fueling when remaining range minus
    /// the reserve no longer comfortably covers the next opportunity.
    static let reserveMiles: Double = flows_trip_vehicle_reserve_miles()

    static func shouldRecommendFuel(
        rangeRemainingMiles: Double, milesToNextStation: Double, reserveMiles: Double = reserveMiles
    ) -> Bool {
        flows_trip_vehicle_should_recommend_fuel(rangeRemainingMiles, milesToNextStation, reserveMiles)
    }
}

/// One real fuel reading (Smartcar cloud, or a plug-in car reader) and when
/// it arrived.
struct FuelReading: Equatable {
    var fraction: Double
    var at: Date

    /// How long a real reading may stand in for the odometer model. The cloud
    /// was read once at launch and a reader's last value outlived the reader,
    /// so an hours-old tank froze the range and kept every fuel warning quiet.
    static let maxAgeSeconds: TimeInterval = 10 * 60

    /// The freshest reading still young enough to trust, or nil.
    static func freshest(_ readings: [FuelReading?], now: Date = Date()) -> FuelReading? {
        readings.compactMap { $0 }
            .filter { now.timeIntervalSince($0.at) <= maxAgeSeconds }
            .max { $0.at < $1.at }
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
        didSet {
            // Persist when it has MOVED, not on every GPS fix: this wrote
            // UserDefaults once a second for the whole drive. Half a mile
            // of slack is invisible to the range model; a fill-up (zero)
            // always lands at once.
            if let p = persistedMilesSinceFill,
               abs(milesSinceFill - p) < 0.5, milesSinceFill != 0 { return }
            defaults.set(milesSinceFill, forKey: Self.milesKey)
            persistedMilesSinceFill = milesSinceFill
        }
    }
    private var persistedMilesSinceFill: Double?

    /// Rolling driving habits (exponential decay so the last ~hour dominates).
    /// Seeded from the persisted, encrypted DrivingProfile via
    /// `restoreDriving` so a launch resumes a learned driver instead of
    /// starting over at a 55 mph default.
    private(set) var averageSpeedMph: Double = 55
    private(set) var idleFraction: Double = 0

    /// Resume the learned speed/idle shape (called once at startup).
    func restoreDriving(averageSpeedMph: Double, idleFraction: Double) {
        guard flows_trip_vehicle_restore_driving_accepts(averageSpeedMph, idleFraction) else { return }
        self.averageSpeedMph = averageSpeedMph
        self.idleFraction = flows_trip_vehicle_restore_driving_idle(idleFraction)
    }

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
    /// overrides the odometer estimate — while the reading is current
    /// (`FuelReading.freshest`). CarPlay itself never provides these to
    /// third-party apps.
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

    /// The tank as the driver sees it: a current real reading when there is
    /// one, the odometer model otherwise — the same source the range beside
    /// the gauge uses. Real data also stops the refuel check-ins that reset
    /// the model, so the model alone sank to E beside a healthy range.
    var displayedFuelFraction: Double? {
        guard profile != nil else { return nil }
        return telemetry().fuelFraction ?? predictedFuelFraction
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
        // equivalents: a mile driven while towing is charged at the towing
        // economy WHEN it was driven. The habit averages decay over ~55 min
        // (alpha 0.0003 at 1 Hz). All of it is computed in Rust.
        let habits = flows_trip_vehicle_record_fix(
            milesSinceFill, averageSpeedMph, idleFraction,
            speedMps, deltaMeters, towingActive, TowingLimits.towingEconomyFactor)
        milesSinceFill = habits.miles_since_fill
        averageSpeedMph = habits.average_speed_mph
        idleFraction = habits.idle_fraction
    }

    /// The driver filled the tank (arriving at a gas stop, or told us so).
    func filledUp() {
        milesSinceFill = 0
    }

    var expectedRangeMiles: Double? {
        guard let profile else { return nil }
        // Real telemetry (OEM API / OBD reader) wins over the odometer model;
        // the towing multiplier applies at read time either way.
        let fraction = telemetry().fuelFraction
        return flows_trip_vehicle_store_expected_range_miles(
            profile.tankCapacityUnits, profile.ratedMilesPerUnit,
            profile.cityMilesPerUnit ?? 0, profile.cityMilesPerUnit != nil,
            profile.highwayMilesPerUnit ?? 0, profile.highwayMilesPerUnit != nil,
            milesSinceFill, averageSpeedMph, idleFraction,
            fraction ?? 0, fraction != nil,
            towingActive, TowingLimits.towingEconomyFactor)
    }

    private func persistProfile() {
        if let profile, let data = try? JSONEncoder().encode(profile) {
            defaults.set(data, forKey: Self.profileKey)
        } else if profile == nil {
            defaults.removeObject(forKey: Self.profileKey)
        }
    }
}
