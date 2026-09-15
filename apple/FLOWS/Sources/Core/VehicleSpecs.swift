// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Curated vehicle-spec table: pick make → model and the profile fills
/// itself — EPA-style city/highway economy, tank (or battery) size, and the
/// factory height that seeds the low-bridge filter automatically.
///
/// Values are manufacturer-typical for recent model years (EPA fuel-economy
/// listings + manufacturer spec sheets), rounded; trims vary, so the editor
/// keeps everything adjustable after autofill. Combined economy uses the
/// EPA 55% city / 45% highway blend.
struct VehicleSpec: Equatable, Identifiable {
    let make: String
    let model: String
    let fuelType: FuelType
    let cityMPU: Double       // mi per unit (gal or kWh) city
    let highwayMPU: Double    // mi per unit highway
    let tankUnits: Double     // gal, or usable kWh for electric
    let heightFeet: Double    // factory roof height
    /// Towing ratings (manufacturer-typical; nil = not published/rated).
    var gvwrLbs: Double? = nil
    var towCapacityLbs: Double? = nil
    var gcwrLbs: Double? = nil
    /// Maker steep-grade guidance in PERCENT, where the class's driver
    /// handbooks publish one (heavy chassis: the sustained grade above which
    /// engine braking is called for). nil = derive the grade-slider default
    /// from the weight/towing heuristic instead
    /// (`FilterLimits.vehicleDefaultMaxGradeDegrees`).
    var publishedMaxGradePercent: Double? = nil
    /// Manufacturer top speed (mph) where published — the right end of the
    /// HUD speed bar. Most entries leave it nil and take the default.
    var topSpeedMph: Double? = nil

    var id: String { "\(make) \(model)" }

    var towingRatings: TowingLimits.Ratings {
        TowingLimits.Ratings(gvwrLbs: gvwrLbs, towCapacityLbs: towCapacityLbs,
                             gcwrLbs: gcwrLbs)
    }

    /// EPA combined blend: 1 / (0.55/city + 0.45/highway), computed in Rust.
    var combinedMPU: Double {
        flows_trip_vehicle_combined_miles_per_unit(cityMPU, highwayMPU)
    }

    var profile: VehicleProfile {
        VehicleProfile(make: make, model: model, fuelType: fuelType,
                       tankCapacityUnits: tankUnits,
                       ratedMilesPerUnit: flows_trip_vehicle_rated_miles_per_unit(cityMPU, highwayMPU),
                       cityMilesPerUnit: cityMPU,
                       highwayMilesPerUnit: highwayMPU)
    }
}

/// The curated table lives in rust/flows-core (trip_vehicle.rs) and is read
/// once through rust/flows-bridge as three parallel lists — makes, models and
/// ten numbers a row — so Swift holds no copy of a figure. The lookups run in
/// Rust too. Pinned bit for bit to the Swift this replaced by
/// rust/flows-bridge/tests/fixtures/swift_trip_vehicle_oracle.tsv.
enum VehicleSpecs {
    static let all: [VehicleSpec] = {
        let makes = flows_trip_vehicle_spec_makes().map { $0.as_str().toString() }
        let models = flows_trip_vehicle_spec_models().map { $0.as_str().toString() }
        let numbers = Array(flows_trip_vehicle_spec_numbers())
        let slots = Int(flows_trip_vehicle_spec_number_slots())
        // Fuel code, city, highway, tank, height, GVWR, tow capacity, GCWR,
        // published grade, top speed — the last five NaN when unpublished.
        guard slots == 10, models.count == makes.count, numbers.count == makes.count * slots else {
            return []
        }
        func rating(_ v: Double) -> Double? { v.isNaN ? nil : v }
        var rows: [VehicleSpec] = []
        rows.reserveCapacity(makes.count)
        for r in makes.indices {
            let b = r * slots
            guard let code = UInt8(exactly: numbers[b]), let fuel = FuelType(rustCode: code) else { continue }
            rows.append(VehicleSpec(
                make: makes[r], model: models[r], fuelType: fuel,
                cityMPU: numbers[b + 1], highwayMPU: numbers[b + 2],
                tankUnits: numbers[b + 3], heightFeet: numbers[b + 4],
                gvwrLbs: rating(numbers[b + 5]), towCapacityLbs: rating(numbers[b + 6]),
                gcwrLbs: rating(numbers[b + 7]), publishedMaxGradePercent: rating(numbers[b + 8]),
                topSpeedMph: rating(numbers[b + 9])))
        }
        return rows
    }()

    /// Distinct makes, table order preserved.
    static var makes: [String] {
        flows_trip_vehicle_distinct_makes().map { $0.as_str().toString() }
    }

    /// Models for one make (the filterable table the editor drives).
    static func models(make: String) -> [VehicleSpec] {
        flows_trip_vehicle_spec_rows_for_make(make).compactMap { row in
            guard let i = Int(exactly: row), i < all.count else { return nil }
            return all[i]
        }
    }

    static func spec(make: String, model: String) -> VehicleSpec? {
        let i = flows_trip_vehicle_spec_index(make, model)
        guard i >= 0, Int(i) < all.count else { return nil }
        return all[Int(i)]
    }

    /// Lowest factory height in the table — the height slider's floor
    /// (a sedan, not an arbitrary 10 ft).
    static var minimumHeightFeet: Double {
        flows_trip_vehicle_minimum_height_feet()
    }
}
