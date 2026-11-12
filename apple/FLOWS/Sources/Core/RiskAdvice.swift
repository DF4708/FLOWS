// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import FlowsBridge
import Foundation

/// Expert-recommended actions for a tapped risk symbol, SCALED to the band —
/// mild elevation gets proportionate advice (no "heavy coats" for a slightly
/// cool day in that latitude band). Sources: NWS safety guidance
/// (weather.gov/safety), CDC extreme-temperature guidance, FEMA/Ready.gov.
/// The advice and the border lines live in Rust (`flows_core::risk_advice`);
/// this facade only crosses. Pinned by FLOWSTests and the frozen oracle in
/// `rust/flows-bridge/tests/fixtures/swift_risk_advice_oracle.tsv`.
enum RiskAdvice {

    /// Advice lines for a hazard kind name ("Cold", "Heat", "Flood"…) at a
    /// band. `.clear` returns nothing — no risk, no advice.
    static func actions(kindName: String, band: RiskBand) -> [String] {
        flows_risk_advice_actions(kindName, code(band)).map { $0.text }
    }

    /// Could the point be in Canada or Mexico? Wide on purpose, the other
    /// way round from `officialURL` (which reads a doubtful point as US). A
    /// US state's box takes in the far bank too (Toronto and Windsor sit in
    /// New York's and Michigan's, Tijuana and Juárez in California's and
    /// Texas's), and a state's alert list answers "none" for them; asked by
    /// the point, the Weather Service itself says "not ours" and the
    /// country's own service is asked. A US town caught here loses nothing:
    /// it is asked by its point too. So: across the line, or within a
    /// quarter degree of it, or in the two places the line's bands leave
    /// out, Ontario between Detroit and Niagara and Vancouver Island.
    static func mayBeAcrossTheBorder(latitude: Double, longitude: Double) -> Bool {
        flows_risk_advice_may_be_across(latitude, longitude)
    }

    /// Is the point plainly in Canada or Mexico, by the lines `officialURL`
    /// splits the agencies by?
    static func isAcrossTheBorder(latitude: Double, longitude: Double) -> Bool {
        flows_risk_advice_is_across(latitude, longitude)
    }

    /// The official page for a location's active hazards: the NWS point
    /// page (US), ECCC (Canada), SMN (Mexico) — always resolvable, always
    /// the issuing agency. US is the default; a location routes to a foreign
    /// agency only when it is unambiguously across the border. An empty
    /// answer from Rust (only on a contained panic) reads as no page, never
    /// the wrong agency's.
    static func officialURL(latitude: Double, longitude: Double) -> URL? {
        let address = flows_risk_advice_official_url(latitude, longitude).text
        return address.isEmpty ? nil : URL(string: address)
    }

    /// Canada that `isNorthOfTheBorder`'s bands leave on the US side:
    /// southern Ontario and Vancouver Island. Only the official link asks
    /// this; the alert fetch already asks both countries there
    /// (`mayBeAcrossTheBorder`).
    static func isCanadaBelowTheBands(latitude lat: Double, longitude lon: Double) -> Bool {
        flows_risk_advice_canada_below(lat, lon)
    }

    /// Is the point on the Canadian side of the border? West to east, the
    /// border as the bands the Weather Service and Environment Canada split
    /// it by: the 49th parallel, the Rainy River and Superior, Huron's
    /// Michigan shore, Lake Ontario, the St. Lawrence, the 45th parallel,
    /// Maine's outline, and the Maritimes beyond it. Alaska (US) is read
    /// first, ahead of its high latitude. Border towns within ~0.05° are
    /// inherently ambiguous at this resolution.
    static func isNorthOfTheBorder(latitude lat: Double, longitude lon: Double) -> Bool {
        flows_risk_advice_is_north(lat, lon)
    }

    /// The latitude of the US–Mexico border for the WESTERN segment
    /// (longitude in [-117.2, -97.4]): the Californias line, the Sonora/AZ and
    /// NM lines, then the Rio Grande from El Paso to Brownsville. A point
    /// south of this (within the longitude band) is Mexico. Towns on the
    /// Mexican bank within ~0.05° read as US, the default.
    static func usSouthernBorderLat(longitude lon: Double) -> Double {
        flows_risk_advice_southern_border_lat(lon)
    }

    private static func code(_ band: RiskBand) -> Int64 {
        switch band {
        case .clear: 0
        case .green: 1
        case .yellow: 2
        case .red: 3
        }
    }
}
