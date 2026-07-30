// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
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
/// Live state-average fuel prices scraped politely from AAA's PUBLIC state
/// pages (gasprices.aaa.com — keyless, refreshed at most twice a day per
/// state). A public posting by the operator, not platform content; polite,
/// low-volume, cached. Feeds FuelPrices.estimate as a fresher override of the
/// static state-factor table — labeled "est." in the UI either way (it's a
/// state average, not a station price).
final class AAAFuelPrices: @unchecked Sendable {
    static let shared = AAAFuelPrices()

    private let lock = NSLock()
    private var cache: [String: (gas: Double, diesel: Double, at: Date)] = [:]

    func cached(_ code: String) -> (gas: Double, diesel: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let c = cache[code], Date().timeIntervalSince(c.at) < 43_200 else { return nil }
        return (c.gas, c.diesel)
    }

    /// Fetch a state's Current Avg row (Regular/Mid/Premium/Diesel) once per
    /// 12 h. Parsing anchors on the "Current Avg." cell — the four following
    /// $-prices are the columns in order.
    func refresh(stateCode: String) async {
        let code = stateCode.uppercased()
        if cached(code) != nil { return }
        guard code.count == 2,
              let url = URL(string: "https://gasprices.aaa.com/?state=\(code)"),
              let (data, resp) = try? await ThrottledNet.fetch(url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8),
              let parsed = Self.parseCurrentAvg(html) else { return }
        store(code: code, gas: parsed.gas, diesel: parsed.diesel)
    }

    /// Synchronous mutation point (NSLock is not await-safe; this never awaits).
    private func store(code: String, gas: Double, diesel: Double) {
        lock.lock(); defer { lock.unlock() }
        cache[code] = (gas: gas, diesel: diesel, at: Date())
    }

    /// Pure parse (testable offline): the four $-prices after "Current Avg."
    /// are Regular / Mid / Premium / Diesel, in column order. Positional, so
    /// a value is NEVER skipped — dropping one (e.g. a $9+ diesel print, or a
    /// template change) would silently shift the next row's Regular into the
    /// Diesel column, a wrong-but-plausible number. Any out-of-band value
    /// fails the whole parse and the static state-factor estimate serves
    /// instead. The scan is bounded to the row (600 chars past the anchor) so
    /// it can't wander into "Yesterday Avg.".
    static func parseCurrentAvg(_ html: String) -> (gas: Double, diesel: Double)? {
        guard let anchor = html.range(of: "Current Avg.") else { return nil }
        let windowEnd = html.index(anchor.upperBound, offsetBy: 600,
                                   limitedBy: html.endIndex) ?? html.endIndex
        var prices: [Double] = []
        var search = anchor.upperBound
        while prices.count < 4,
              let d = html.range(of: "$", range: search..<windowEnd) {
            let tail = String(html[d.upperBound...].prefix(8))
            let num = String(tail.prefix(while: { $0.isNumber || $0 == "." }))
            guard let v = Double(num) else { search = d.upperBound; continue }
            guard v > 1, v < 12 else { return nil }   // sanity band, no silent skip
            prices.append(v)
            search = d.upperBound
        }
        guard prices.count == 4 else { return nil }
        return (gas: prices[0], diesel: prices[3])
    }
}

enum FuelPrices {
    /// Baselines (US national, $/gal; electric $/kWh at public L2/DCFC).
    static let nationalGas = 3.10
    static let nationalDiesel = 3.80
    static let nationalKWh = 0.36

    /// CRE publishes MXN per LITER; the whole cost model runs in USD per
    /// GALLON. Approximate FX, release-updated — ranking needs the right
    /// ORDER OF MAGNITUDE, not the daily rate: unconverted, a real 23 MXN/L
    /// posted price scored as $23/gal and ranked BELOW every unpriced
    /// station's $3.20 default (stations with real data always lost).
    static let mxnPerUSD = 17.0
    static let litersPerGallon = 3.78541
    static func usdPerGallon(mxnPerLiter: Double) -> Double {
        mxnPerLiter / mxnPerUSD * litersPerGallon
    }

    /// Mexico state-average baseline (typical posted MXN/L, converted) — the
    /// US national figure is wrong there in both level and meaning.
    static func mexicoEstimate(fuel: FuelType) -> Double {
        switch fuel {
        case .gas: return (usdPerGallon(mxnPerLiter: 23.7) * 100).rounded() / 100
        case .diesel: return (usdPerGallon(mxnPerLiter: 25.4) * 100).rounded() / 100
        case .electric: return nationalKWh   // CFE public charging is comparable
        }
    }

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
        // Fresher truth first: AAA's live state average (keyless scrape,
        // 12-h cache) overrides the static factor table when present.
        if let code, let live = AAAFuelPrices.shared.cached(code) {
            switch fuel {
            case .gas: return (live.gas * 100).rounded() / 100
            case .diesel: return (live.diesel * 100).rounded() / 100
            case .electric: break   // AAA doesn't publish $/kWh
            }
        }
        let factor = code.flatMap { stateFactor[$0] } ?? 1.0
        switch fuel {
        case .gas: return (nationalGas * factor * 100).rounded() / 100
        case .diesel: return (nationalDiesel * factor * 100).rounded() / 100
        case .electric: return (nationalKWh * factor * 100).rounded() / 100
        }
    }
}
