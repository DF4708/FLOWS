// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
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

    var id: String { "\(make) \(model)" }

    var towingRatings: TowingLimits.Ratings {
        TowingLimits.Ratings(gvwrLbs: gvwrLbs, towCapacityLbs: towCapacityLbs,
                             gcwrLbs: gcwrLbs)
    }

    /// EPA combined blend: 1 / (0.55/city + 0.45/highway).
    var combinedMPU: Double {
        1 / (0.55 / cityMPU + 0.45 / highwayMPU)
    }

    var profile: VehicleProfile {
        VehicleProfile(make: make, model: model, fuelType: fuelType,
                       tankCapacityUnits: tankUnits,
                       ratedMilesPerUnit: (combinedMPU * 10).rounded() / 10,
                       cityMilesPerUnit: cityMPU,
                       highwayMilesPerUnit: highwayMPU)
    }
}

enum VehicleSpecs {
    static let all: [VehicleSpec] = [
        // ---- sedans / compacts (heights ~4.6–4.9 ft) ----
        VehicleSpec(make: "Toyota", model: "Corolla", fuelType: .gas, cityMPU: 32, highwayMPU: 41, tankUnits: 13.2, heightFeet: 4.8, gvwrLbs: 3910, towCapacityLbs: 1500),
        VehicleSpec(make: "Toyota", model: "Camry", fuelType: .gas, cityMPU: 28, highwayMPU: 39, tankUnits: 15.8, heightFeet: 4.7, gvwrLbs: 4400, towCapacityLbs: 1000),
        VehicleSpec(make: "Toyota", model: "Prius", fuelType: .gas, cityMPU: 57, highwayMPU: 56, tankUnits: 11.3, heightFeet: 4.8, gvwrLbs: 4025, towCapacityLbs: 1750),
        VehicleSpec(make: "Honda", model: "Civic", fuelType: .gas, cityMPU: 31, highwayMPU: 40, tankUnits: 12.4, heightFeet: 4.6, gvwrLbs: 3968, towCapacityLbs: 1000),
        VehicleSpec(make: "Honda", model: "Accord", fuelType: .gas, cityMPU: 29, highwayMPU: 37, tankUnits: 14.8, heightFeet: 4.7, gvwrLbs: 4295, towCapacityLbs: 1000),
        VehicleSpec(make: "Hyundai", model: "Elantra", fuelType: .gas, cityMPU: 32, highwayMPU: 41, tankUnits: 12.4, heightFeet: 4.6, gvwrLbs: 3990, towCapacityLbs: 1300),
        VehicleSpec(make: "Nissan", model: "Altima", fuelType: .gas, cityMPU: 27, highwayMPU: 37, tankUnits: 16.2, heightFeet: 4.7, gvwrLbs: 4390, towCapacityLbs: 1000),
        VehicleSpec(make: "Nissan", model: "Versa", fuelType: .gas, cityMPU: 32, highwayMPU: 40, tankUnits: 10.8, heightFeet: 4.8, gvwrLbs: 3729, towCapacityLbs: 900),
        VehicleSpec(make: "Subaru", model: "Impreza", fuelType: .gas, cityMPU: 27, highwayMPU: 34, tankUnits: 13.2, heightFeet: 4.8, gvwrLbs: 4145, towCapacityLbs: 1200),

        // ---- SUVs / crossovers (heights ~5.3–6.0 ft) ----
        VehicleSpec(make: "Toyota", model: "RAV4", fuelType: .gas, cityMPU: 27, highwayMPU: 35, tankUnits: 14.5, heightFeet: 5.6, gvwrLbs: 4750, towCapacityLbs: 1500, gcwrLbs: 6005),
        VehicleSpec(make: "Toyota", model: "Highlander", fuelType: .gas, cityMPU: 22, highwayMPU: 29, tankUnits: 17.9, heightFeet: 5.7, gvwrLbs: 6000, towCapacityLbs: 5000, gcwrLbs: 11000),
        VehicleSpec(make: "Toyota", model: "4Runner", fuelType: .gas, cityMPU: 16, highwayMPU: 19, tankUnits: 23.0, heightFeet: 6.0, gvwrLbs: 6300, towCapacityLbs: 5000, gcwrLbs: 11300),
        VehicleSpec(make: "Honda", model: "CR-V", fuelType: .gas, cityMPU: 28, highwayMPU: 34, tankUnits: 14.0, heightFeet: 5.5, gvwrLbs: 4600, towCapacityLbs: 1500, gcwrLbs: 6100),
        VehicleSpec(make: "Honda", model: "Pilot", fuelType: .gas, cityMPU: 19, highwayMPU: 27, tankUnits: 18.5, heightFeet: 5.9, gvwrLbs: 6054, towCapacityLbs: 5000, gcwrLbs: 11200),
        VehicleSpec(make: "Ford", model: "Explorer", fuelType: .gas, cityMPU: 21, highwayMPU: 28, tankUnits: 17.9, heightFeet: 5.8, gvwrLbs: 6160, towCapacityLbs: 5300, gcwrLbs: 11500),
        VehicleSpec(make: "Ford", model: "Escape", fuelType: .gas, cityMPU: 27, highwayMPU: 34, tankUnits: 14.8, heightFeet: 5.5, gvwrLbs: 4700, towCapacityLbs: 3500, gcwrLbs: 8200),
        VehicleSpec(make: "Chevrolet", model: "Equinox", fuelType: .gas, cityMPU: 26, highwayMPU: 31, tankUnits: 14.9, heightFeet: 5.4, gvwrLbs: 4519, towCapacityLbs: 1500, gcwrLbs: 6000),
        VehicleSpec(make: "Chevrolet", model: "Tahoe", fuelType: .gas, cityMPU: 15, highwayMPU: 20, tankUnits: 24.0, heightFeet: 6.3, gvwrLbs: 7500, towCapacityLbs: 8400, gcwrLbs: 15000),
        VehicleSpec(make: "Jeep", model: "Grand Cherokee", fuelType: .gas, cityMPU: 19, highwayMPU: 26, tankUnits: 23.0, heightFeet: 5.9, gvwrLbs: 6500, towCapacityLbs: 6200, gcwrLbs: 12700),
        VehicleSpec(make: "Jeep", model: "Wrangler", fuelType: .gas, cityMPU: 20, highwayMPU: 24, tankUnits: 21.5, heightFeet: 6.1, gvwrLbs: 5800, towCapacityLbs: 3500, gcwrLbs: 9350),
        VehicleSpec(make: "Subaru", model: "Outback", fuelType: .gas, cityMPU: 26, highwayMPU: 32, tankUnits: 18.5, heightFeet: 5.6, gvwrLbs: 4915, towCapacityLbs: 3500, gcwrLbs: 8400),

        // ---- pickups (heights ~6.3–6.8 ft) ----
        VehicleSpec(make: "Ford", model: "F-150", fuelType: .gas, cityMPU: 20, highwayMPU: 26, tankUnits: 26.0, heightFeet: 6.4, gvwrLbs: 7050, towCapacityLbs: 11200, gcwrLbs: 17100),
        VehicleSpec(make: "Ford", model: "F-250 Super Duty (diesel)", fuelType: .diesel, cityMPU: 15, highwayMPU: 19, tankUnits: 34.0, heightFeet: 6.8, gvwrLbs: 10800, towCapacityLbs: 20000, gcwrLbs: 30000),
        VehicleSpec(make: "Chevrolet", model: "Silverado 1500", fuelType: .gas, cityMPU: 19, highwayMPU: 24, tankUnits: 24.0, heightFeet: 6.3, gvwrLbs: 7200, towCapacityLbs: 9500, gcwrLbs: 16000),
        VehicleSpec(make: "Chevrolet", model: "Silverado 2500HD (diesel)", fuelType: .diesel, cityMPU: 14, highwayMPU: 18, tankUnits: 36.0, heightFeet: 6.7, gvwrLbs: 11350, towCapacityLbs: 18500, gcwrLbs: 27500),
        VehicleSpec(make: "Ram", model: "1500", fuelType: .gas, cityMPU: 20, highwayMPU: 25, tankUnits: 26.0, heightFeet: 6.5, gvwrLbs: 6900, towCapacityLbs: 8300, gcwrLbs: 14950),
        VehicleSpec(make: "Ram", model: "2500 (diesel)", fuelType: .diesel, cityMPU: 14, highwayMPU: 19, tankUnits: 32.0, heightFeet: 6.7, gvwrLbs: 10000, towCapacityLbs: 19990, gcwrLbs: 28300),
        VehicleSpec(make: "Toyota", model: "Tacoma", fuelType: .gas, cityMPU: 20, highwayMPU: 26, tankUnits: 18.2, heightFeet: 6.0, gvwrLbs: 5600, towCapacityLbs: 6500, gcwrLbs: 11360),
        VehicleSpec(make: "Toyota", model: "Tundra", fuelType: .gas, cityMPU: 18, highwayMPU: 23, tankUnits: 22.5, heightFeet: 6.5, gvwrLbs: 7210, towCapacityLbs: 11500, gcwrLbs: 17870),
        VehicleSpec(make: "GMC", model: "Sierra 1500", fuelType: .gas, cityMPU: 19, highwayMPU: 24, tankUnits: 24.0, heightFeet: 6.3, gvwrLbs: 7200, towCapacityLbs: 9500, gcwrLbs: 16000),

        // ---- vans (roof options change height a LOT) ----
        VehicleSpec(make: "Ford", model: "Transit (low roof)", fuelType: .gas, cityMPU: 15, highwayMPU: 19, tankUnits: 25.0, heightFeet: 6.9, gvwrLbs: 9070, towCapacityLbs: 5000, gcwrLbs: 14000),
        VehicleSpec(make: "Ford", model: "Transit (high roof)", fuelType: .gas, cityMPU: 15, highwayMPU: 19, tankUnits: 25.0, heightFeet: 9.1, gvwrLbs: 9500, towCapacityLbs: 4500, gcwrLbs: 14000),
        VehicleSpec(make: "Mercedes-Benz", model: "Sprinter (standard roof, diesel)", fuelType: .diesel, cityMPU: 19, highwayMPU: 23, tankUnits: 24.5, heightFeet: 7.9, gvwrLbs: 9050, towCapacityLbs: 5000, gcwrLbs: 13550),
        VehicleSpec(make: "Mercedes-Benz", model: "Sprinter (high roof, diesel)", fuelType: .diesel, cityMPU: 19, highwayMPU: 23, tankUnits: 24.5, heightFeet: 9.0, gvwrLbs: 9990, towCapacityLbs: 5000, gcwrLbs: 15250),
        VehicleSpec(make: "Ram", model: "ProMaster (high roof)", fuelType: .gas, cityMPU: 14, highwayMPU: 18, tankUnits: 24.0, heightFeet: 8.6, gvwrLbs: 9350, towCapacityLbs: 6910, gcwrLbs: 16255),
        VehicleSpec(make: "Ford", model: "E-450 Econoline cutaway", fuelType: .gas, cityMPU: 8, highwayMPU: 11, tankUnits: 55.0, heightFeet: 10.5, gvwrLbs: 14500, towCapacityLbs: 10000, gcwrLbs: 22000),
        VehicleSpec(make: "Mercedes-Benz", model: "Sprinter 3500 (diesel)", fuelType: .diesel, cityMPU: 17, highwayMPU: 21, tankUnits: 24.5, heightFeet: 9.1, gvwrLbs: 11030, towCapacityLbs: 7500, gcwrLbs: 15250),
        VehicleSpec(make: "Chrysler", model: "Pacifica", fuelType: .gas, cityMPU: 19, highwayMPU: 28, tankUnits: 19.0, heightFeet: 5.8, gvwrLbs: 6055, towCapacityLbs: 3600, gcwrLbs: 9650),
        VehicleSpec(make: "Honda", model: "Odyssey", fuelType: .gas, cityMPU: 19, highwayMPU: 28, tankUnits: 19.5, heightFeet: 5.8, gvwrLbs: 6019, towCapacityLbs: 3500, gcwrLbs: 9542),

        // ---- electric (mi/kWh; usable battery kWh) ----
        VehicleSpec(make: "Tesla", model: "Model 3", fuelType: .electric, cityMPU: 4.4, highwayMPU: 4.0, tankUnits: 58, heightFeet: 4.7, gvwrLbs: 4960, towCapacityLbs: 2000),
        VehicleSpec(make: "Tesla", model: "Model Y", fuelType: .electric, cityMPU: 4.1, highwayMPU: 3.7, tankUnits: 75, heightFeet: 5.3, gvwrLbs: 5525, towCapacityLbs: 3500),
        VehicleSpec(make: "Ford", model: "Mustang Mach-E", fuelType: .electric, cityMPU: 3.9, highwayMPU: 3.4, tankUnits: 72, heightFeet: 5.3, gvwrLbs: 5544, towCapacityLbs: 2300),
        VehicleSpec(make: "Ford", model: "F-150 Lightning", fuelType: .electric, cityMPU: 2.3, highwayMPU: 1.9, tankUnits: 98, heightFeet: 6.5, gvwrLbs: 8250, towCapacityLbs: 10000, gcwrLbs: 19500),
        VehicleSpec(make: "Hyundai", model: "Ioniq 5", fuelType: .electric, cityMPU: 4.0, highwayMPU: 3.4, tankUnits: 74, heightFeet: 5.3, gvwrLbs: 5390, towCapacityLbs: 2300),
        VehicleSpec(make: "Chevrolet", model: "Equinox EV", fuelType: .electric, cityMPU: 3.9, highwayMPU: 3.3, tankUnits: 85, heightFeet: 5.4, gvwrLbs: 5850, towCapacityLbs: 1500),
        VehicleSpec(make: "Rivian", model: "R1T", fuelType: .electric, cityMPU: 2.6, highwayMPU: 2.2, tankUnits: 128, heightFeet: 6.0, gvwrLbs: 8532, towCapacityLbs: 11000, gcwrLbs: 20000),

        // ---- RVs / motorhomes ----
        VehicleSpec(make: "RV", model: "Class C motorhome", fuelType: .gas, cityMPU: 9, highwayMPU: 11, tankUnits: 55, heightFeet: 11.0, gvwrLbs: 14500, towCapacityLbs: 7500, gcwrLbs: 22000),
        VehicleSpec(make: "RV", model: "Class A motorhome (diesel)", fuelType: .diesel, cityMPU: 7, highwayMPU: 9, tankUnits: 100, heightFeet: 12.5, gvwrLbs: 32000, towCapacityLbs: 10000, gcwrLbs: 42000),

        // ---- generic classes (type fallback when the exact model isn't
        // listed: "trucks" vs "sedans" vs "bus" — typical figures) ----
        VehicleSpec(make: "Generic", model: "Sedan", fuelType: .gas, cityMPU: 28, highwayMPU: 38, tankUnits: 14.5, heightFeet: 4.7, gvwrLbs: 4300, towCapacityLbs: 1000),
        VehicleSpec(make: "Generic", model: "SUV", fuelType: .gas, cityMPU: 22, highwayMPU: 28, tankUnits: 17.5, heightFeet: 5.7, gvwrLbs: 6200, towCapacityLbs: 5000),
        VehicleSpec(make: "Generic", model: "Pickup truck", fuelType: .gas, cityMPU: 19, highwayMPU: 24, tankUnits: 25.0, heightFeet: 6.4, gvwrLbs: 7000, towCapacityLbs: 9000, gcwrLbs: 15500),
        VehicleSpec(make: "Generic", model: "Cargo van", fuelType: .gas, cityMPU: 15, highwayMPU: 19, tankUnits: 25.0, heightFeet: 8.5, gvwrLbs: 9000, towCapacityLbs: 6000),
        VehicleSpec(make: "Generic", model: "Bus", fuelType: .diesel, cityMPU: 6, highwayMPU: 8, tankUnits: 100.0, heightFeet: 10.5, gvwrLbs: 36200, towCapacityLbs: 10000, gcwrLbs: 46200),
        VehicleSpec(make: "Generic", model: "Motorhome (Class A)", fuelType: .diesel, cityMPU: 7, highwayMPU: 9, tankUnits: 100.0, heightFeet: 12.5, gvwrLbs: 32000, towCapacityLbs: 10000, gcwrLbs: 42000),

        // ---- heavy trucks (13'6" standard trailer height) ----
        VehicleSpec(make: "Freightliner", model: "Cascadia (semi)", fuelType: .diesel, cityMPU: 6.0, highwayMPU: 7.5, tankUnits: 240, heightFeet: 13.5, gvwrLbs: 35000, towCapacityLbs: 45000, gcwrLbs: 80000),
        VehicleSpec(make: "Peterbilt", model: "579 (semi)", fuelType: .diesel, cityMPU: 6.0, highwayMPU: 7.5, tankUnits: 240, heightFeet: 13.5, gvwrLbs: 35000, towCapacityLbs: 45000, gcwrLbs: 80000),
        VehicleSpec(make: "Kenworth", model: "T680 (semi)", fuelType: .diesel, cityMPU: 6.0, highwayMPU: 7.5, tankUnits: 240, heightFeet: 13.5, gvwrLbs: 35000, towCapacityLbs: 45000, gcwrLbs: 80000),
        VehicleSpec(make: "Volvo", model: "VNL (semi)", fuelType: .diesel, cityMPU: 6.2, highwayMPU: 7.8, tankUnits: 240, heightFeet: 13.5, gvwrLbs: 35000, towCapacityLbs: 45000, gcwrLbs: 80000),
        VehicleSpec(make: "International", model: "LT (semi)", fuelType: .diesel, cityMPU: 6.0, highwayMPU: 7.4, tankUnits: 240, heightFeet: 13.5, gvwrLbs: 35000, towCapacityLbs: 45000, gcwrLbs: 80000),
        VehicleSpec(make: "Box truck", model: "26 ft straight truck", fuelType: .diesel, cityMPU: 8, highwayMPU: 10, tankUnits: 60, heightFeet: 13.0, gvwrLbs: 25999, towCapacityLbs: 8000, gcwrLbs: 33500),
        VehicleSpec(make: "Box truck", model: "16 ft box truck", fuelType: .gas, cityMPU: 9, highwayMPU: 12, tankUnits: 33, heightFeet: 12.0, gvwrLbs: 14500, towCapacityLbs: 6000, gcwrLbs: 20500),
    ]

    /// Distinct makes, table order preserved.
    static var makes: [String] {
        var seen = Set<String>()
        return all.compactMap { seen.insert($0.make).inserted ? $0.make : nil }
    }

    /// Models for one make (the filterable table the editor drives).
    static func models(make: String) -> [VehicleSpec] {
        all.filter { $0.make == make }
    }

    static func spec(make: String, model: String) -> VehicleSpec? {
        all.first { $0.make == make && $0.model == model }
    }

    /// Lowest factory height in the table — the height slider's floor
    /// (a sedan, not an arbitrary 10 ft).
    static var minimumHeightFeet: Double {
        all.map(\.heightFeet).min() ?? 4.5
    }
}
