// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Trip cost + CO₂ estimates powering the "Cheapest" and "Efficient" route
/// banners. Pure math over the services the app already has (FuelPrices state
/// estimates, the vehicle profile's rated miles-per-unit, published per-mode
/// emission factors). All outputs are ESTIMATES and labeled so in the UI.
enum TripCosts {
    /// Combustion CO₂ per unit of fuel burned (EPA): gasoline 8,887 g/gal,
    /// diesel 10,180 g/gal. Electric uses the US grid average ~390 g/kWh
    /// (eGRID) — "unit" for an EV is one kWh, matching miles-per-unit.
    static func gramsCO2PerUnit(_ fuel: FuelType) -> Double {
        switch fuel {
        case .gas: return 8_887
        case .diesel: return 10_180
        case .electric: return 390
        }
    }

    /// Published per-passenger-mile CO₂ for mass transit (FTA/UIC averages):
    /// local bus ~105 g, local rail/subway ~65 g, intercity coach ~56 g,
    /// Amtrak ~113 g.
    static func transitGramsCO2PerMile(rail: Bool, longHaul: Bool) -> Double {
        if longHaul { return rail ? 113 : 56 }
        return rail ? 65 : 105
    }

    /// Drive fuel cost: miles ÷ miles-per-unit × price-per-unit. nil when the
    /// vehicle economy is unknown (no profile) — the banner then falls back to
    /// the EPA average car so routes stay comparable with each other.
    static func driveFuelCostUSD(miles: Double, milesPerUnit: Double,
                                 pricePerUnit: Double) -> Double? {
        guard miles.isFinite, miles >= 0, milesPerUnit > 0, pricePerUnit > 0
        else { return nil }
        return miles / milesPerUnit * pricePerUnit
    }

    /// Drive CO₂ grams per mile from the vehicle's economy.
    static func driveGramsCO2PerMile(fuel: FuelType, milesPerUnit: Double) -> Double? {
        guard milesPerUnit > 0 else { return nil }
        return gramsCO2PerUnit(fuel) / milesPerUnit
    }

    /// EPA average light-duty vehicle when no profile exists: 25 mpg gasoline.
    static let defaultMilesPerUnit = 25.0
    static let defaultFuel = FuelType.gas
}
