// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Trip cost + CO₂ estimates powering the "Cheapest" and "Efficient" route
/// banners. All outputs are ESTIMATES and labeled so in the UI.
///
/// The arithmetic and the emission factors live in rust/flows-core
/// (trip_vehicle.rs) and are called through rust/flows-bridge; Swift holds no
/// copy of a factor. Pinned bit for bit to the Swift this replaced by
/// rust/flows-bridge/tests/fixtures/swift_trip_vehicle_oracle.tsv.
enum TripCosts {
    /// Combustion CO₂ per unit of fuel burned (EPA), grams — a kWh for an EV.
    static func gramsCO2PerUnit(_ fuel: FuelType) -> Double {
        flows_trip_vehicle_grams_co2_per_unit(fuel.rustCode)
    }

    /// Published per-passenger-mile CO₂ for mass transit, grams.
    static func transitGramsCO2PerMile(rail: Bool, longHaul: Bool) -> Double {
        flows_trip_vehicle_transit_grams_co2_per_mile(rail, longHaul)
    }

    /// Drive fuel cost: miles ÷ miles-per-unit × price-per-unit. nil when the
    /// vehicle economy is unknown (no profile) — the banner then falls back to
    /// the EPA average car so routes stay comparable with each other.
    static func driveFuelCostUSD(miles: Double, milesPerUnit: Double,
                                 pricePerUnit: Double) -> Double? {
        flows_trip_vehicle_drive_fuel_cost_usd(miles, milesPerUnit, pricePerUnit).some
    }

    /// Drive CO₂ grams per mile from the vehicle's economy.
    static func driveGramsCO2PerMile(fuel: FuelType, milesPerUnit: Double) -> Double? {
        flows_trip_vehicle_drive_grams_co2_per_mile(fuel.rustCode, milesPerUnit).some
    }

    /// EPA average light-duty vehicle when no profile exists.
    static let defaultMilesPerUnit = flows_trip_vehicle_default_miles_per_unit()
    static let defaultFuel = FuelType(rustCode: flows_trip_vehicle_default_fuel_code()) ?? .gas
}

// MARK: - The bridge's codes for the app's enumerations

/// rust/flows-bridge (trip_vehicle) names a fuel by code and a trip need by
/// code; these are the only place Swift spells those codes, so every facade
/// encodes the way the oracle does.
extension FuelType {
    /// 0 gas, 1 diesel, 2 electric — the order of
    /// `flows_trip_vehicle_fuel_type_names()`.
    var rustCode: UInt8 {
        switch self {
        case .gas: return 0
        case .diesel: return 1
        case .electric: return 2
        }
    }

    init?(rustCode code: UInt8) {
        switch code {
        case 0: self = .gas
        case 1: self = .diesel
        case 2: self = .electric
        default: return nil
        }
    }
}

extension FoodCategory {
    /// Position in `allCases`, the order of
    /// `flows_trip_vehicle_food_category_names()`.
    var rustCode: UInt8 {
        UInt8(FoodCategory.allCases.firstIndex(of: self) ?? 0)
    }

    init?(rustCode code: UInt8) {
        let all = FoodCategory.allCases
        guard Int(code) < all.count else { return nil }
        self = all[Int(code)]
    }
}

extension TripVehicleOptional {
    /// The Swift optional the struct carries: `value` only when `is_some` is 1.
    var some: Double? { is_some == 1 ? value : nil }
}
