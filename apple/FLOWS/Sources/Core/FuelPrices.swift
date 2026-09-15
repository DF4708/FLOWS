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
        let code = flows_places_text_uppercased(stateCode).text
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

    /// Pure parse (testable offline), done in Rust: the four $-prices after
    /// "Current Avg." are Regular / Mid / Premium / Diesel, in column order.
    /// Positional, so a value is NEVER skipped — dropping one (e.g. a $9+
    /// diesel print, or a template change) would silently shift the next
    /// row's Regular into the Diesel column, a wrong-but-plausible number. Any
    /// out-of-band value fails the whole parse and the static state-factor
    /// estimate serves instead. The scan is bounded to the row (600 characters
    /// past the anchor) so it can't wander into "Yesterday Avg.".
    static func parseCurrentAvg(_ html: String) -> (gas: Double, diesel: Double)? {
        let p = flows_places_text_parse_current_avg(html)
        return p.has == 1 ? (gas: p.gas, diesel: p.diesel) : nil
    }
}

/// The estimates are computed in rust/flows-core (places_text.rs) and called
/// through rust/flows-bridge — the state tables, the MXN conversion and the
/// rounding all live there; this store keeps the live AAA cache and hands its
/// answer across. Pinned to the original Swift by
/// rust/flows-bridge/tests/fixtures/swift_places_text_oracle.tsv.
enum FuelPrices {
    /// Baselines (US national, $/gal; electric $/kWh at public L2/DCFC).
    static let nationalGas = flows_places_text_national_gas()
    static let nationalDiesel = flows_places_text_national_diesel()
    static let nationalKWh = flows_places_text_national_kwh()

    /// CRE publishes MXN per LITER; the whole cost model runs in USD per
    /// GALLON. Approximate FX, release-updated — ranking needs the right
    /// ORDER OF MAGNITUDE, not the daily rate: unconverted, a real 23 MXN/L
    /// posted price scored as $23/gal and ranked BELOW every unpriced
    /// station's $3.20 default (stations with real data always lost).
    static let mxnPerUSD = flows_places_text_mxn_per_usd()
    static let litersPerGallon = flows_places_text_liters_per_gallon()
    static func usdPerGallon(mxnPerLiter: Double) -> Double {
        flows_places_text_usd_per_gallon(mxnPerLiter)
    }

    /// Mexico state-average baseline (typical posted MXN/L, converted) — the
    /// US national figure is wrong there in both level and meaning.
    static func mexicoEstimate(fuel: FuelType) -> Double {
        flows_places_text_mexico_estimate(fuel.rustCode)
    }

    /// Full state names → codes (MKPlacemark.administrativeArea may be either),
    /// from the table in Rust.
    static let stateNameToCode: [String: String] = {
        let names = flows_places_text_state_names(), codes = flows_places_text_state_codes()
        var m: [String: String] = [:]
        for i in 0..<min(names.len(), codes.len()) {
            m[names[i].text] = codes[i].text
        }
        return m
    }()

    /// Estimated price per unit for a fuel type in a state ("WI", or a full
    /// name). Unknown/foreign states fall back to the national baseline.
    /// Fresher truth first: AAA's live state average (keyless scrape, 12-h
    /// cache) overrides the static factor table when present.
    static func estimate(fuel: FuelType, state: String?) -> Double {
        let raw = flows_places_text_fuel_state_code(state ?? "", state != nil).text
        let code: String? = raw.isEmpty ? nil : raw
        let live = code.flatMap { AAAFuelPrices.shared.cached($0) }
        return flows_places_text_fuel_estimate(
            fuel.rustCode, code ?? "", code != nil, live?.gas ?? 0, live?.diesel ?? 0, live != nil)
    }
}
