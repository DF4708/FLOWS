// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// Regional fuel price ESTIMATES so the price column is populated with a
/// meaningful number instead of "$ —". These are state-level averages in the
/// spirit of EIA/AAA weekly tables (baseline national averages with the
/// well-known state offsets: West Coast/Hawaii high, Gulf/Plains low),
/// rounded to the dime — clearly labeled "est. state avg" in the UI, and a
/// station-level licensed feed (GasBuddy/OPIS) plugs into the same
/// `priceProvider` to replace them per station.
enum FuelPrices {
    /// Baselines (US national, $/gal; electric $/kWh at public L2/DCFC).
    static let nationalGas = 3.10
    static let nationalDiesel = 3.80
    static let nationalKWh = 0.36

    /// State multipliers vs national (gas & diesel move together closely).
    static let stateFactor: [String: Double] = [
        "CA": 1.48, "HI": 1.45, "WA": 1.32, "OR": 1.22, "NV": 1.20, "AK": 1.18,
        "AZ": 1.08, "IL": 1.09, "PA": 1.08, "NY": 1.07, "CT": 1.06, "VT": 1.05,
        "ME": 1.04, "MA": 1.04, "RI": 1.03, "NJ": 1.02, "MI": 1.02, "IN": 1.02,
        "FL": 1.01, "MD": 1.01, "NH": 1.00, "CO": 1.00, "UT": 1.05, "ID": 1.06,
        "MT": 1.02, "WY": 0.98, "ND": 0.97, "SD": 0.97, "NE": 0.96, "KS": 0.93,
        "OK": 0.90, "TX": 0.91, "LA": 0.92, "MS": 0.90, "AL": 0.92, "AR": 0.92,
        "TN": 0.93, "KY": 0.95, "MO": 0.93, "IA": 0.96, "MN": 0.98, "WI": 0.98,
        "OH": 1.00, "WV": 1.00, "VA": 0.98, "NC": 0.96, "SC": 0.94, "GA": 0.95,
        "DE": 1.00, "DC": 1.06, "NM": 0.97,
    ]

    /// Full state names → codes (MKPlacemark.administrativeArea may be either).
    static let stateNameToCode: [String: String] = [
        "california": "CA", "hawaii": "HI", "washington": "WA", "oregon": "OR",
        "nevada": "NV", "alaska": "AK", "arizona": "AZ", "illinois": "IL",
        "pennsylvania": "PA", "new york": "NY", "connecticut": "CT",
        "vermont": "VT", "maine": "ME", "massachusetts": "MA",
        "rhode island": "RI", "new jersey": "NJ", "michigan": "MI",
        "indiana": "IN", "florida": "FL", "maryland": "MD",
        "new hampshire": "NH", "colorado": "CO", "utah": "UT", "idaho": "ID",
        "montana": "MT", "wyoming": "WY", "north dakota": "ND",
        "south dakota": "SD", "nebraska": "NE", "kansas": "KS",
        "oklahoma": "OK", "texas": "TX", "louisiana": "LA",
        "mississippi": "MS", "alabama": "AL", "arkansas": "AR",
        "tennessee": "TN", "kentucky": "KY", "missouri": "MO", "iowa": "IA",
        "minnesota": "MN", "wisconsin": "WI", "ohio": "OH",
        "west virginia": "WV", "virginia": "VA", "north carolina": "NC",
        "south carolina": "SC", "georgia": "GA", "delaware": "DE",
        "district of columbia": "DC", "new mexico": "NM",
    ]

    /// Estimated price per unit for a fuel type in a state ("WI", or a full
    /// name). Unknown/foreign states fall back to the national baseline.
    static func estimate(fuel: FuelType, state: String?) -> Double {
        let code: String? = state.flatMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.count == 2 { return trimmed.uppercased() }
            return stateNameToCode[trimmed.lowercased()]
        }
        let factor = code.flatMap { stateFactor[$0] } ?? 1.0
        switch fuel {
        case .gas: return (nationalGas * factor * 100).rounded() / 100
        case .diesel: return (nationalDiesel * factor * 100).rounded() / 100
        case .electric: return (nationalKWh * factor * 100).rounded() / 100
        }
    }
}
