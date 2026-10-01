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
/// Live average fuel prices from the U.S. Energy Information Administration's
/// weekly Gasoline and Diesel Fuel Update (eia.gov/petroleum/gasdiesel — a
/// U.S. government work, public domain; keyless). One page prices the nation,
/// its regions and nine states; every state reads its own figure or its
/// region's (rust/flows-core places_text.rs `eia_state_prices`). Fetched at
/// most twice a day, for all states at once; no location is sent. Feeds
/// FuelPrices.estimate as a fresher override of the static state-factor
/// table — labeled "est." in the UI either way (an average, not a station
/// price). It replaced AAA's state pages on 2026-10-01: AAA reserves all
/// rights to them and its terms allow personal, non-commercial use only.
final class EIAFuelPrices: @unchecked Sendable {
    static let shared = EIAFuelPrices()

    private let lock = NSLock()
    private var prices: [String: (gas: Double, diesel: Double)] = [:]
    private var fetchedAt: Date?

    func cached(_ code: String) -> (gas: Double, diesel: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let at = fetchedAt, Date().timeIntervalSince(at) < 43_200 else { return nil }
        return prices[code]
    }

    /// Fetch the week's table once per 12 h (EIA publishes it each Monday).
    func refresh() async {
        guard isStale,
              let url = URL(string: flows_places_text_eia_weekly_url().text),
              let (data, resp) = try? await ThrottledNet.fetch(url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return }
        let parsed = Self.parse(html)
        guard !parsed.isEmpty else { return }
        store(parsed)
    }

    private var isStale: Bool {
        lock.lock(); defer { lock.unlock() }
        return fetchedAt.map { Date().timeIntervalSince($0) >= 43_200 } ?? true
    }

    /// Synchronous mutation point (NSLock is not await-safe; this never awaits).
    private func store(_ parsed: [String: (gas: Double, diesel: Double)]) {
        lock.lock(); defer { lock.unlock() }
        prices = parsed
        fetchedAt = Date()
    }

    /// Pure parse (testable offline), done in Rust: every state's (gas,
    /// diesel) for the latest week; empty when the page did not parse.
    static func parse(_ html: String) -> [String: (gas: Double, diesel: Double)] {
        let flat = flows_places_text_eia_prices(html)
        let codes = flows_places_text_state_codes()
        var out: [String: (gas: Double, diesel: Double)] = [:]
        for i in 0..<min(codes.len(), flat.len() / 2) {
            let gas = flat[2 * i], diesel = flat[2 * i + 1]
            if !gas.isNaN, !diesel.isNaN {
                out[codes[i].text] = (gas, diesel)
            }
        }
        return out
    }
}

/// The estimates are computed in rust/flows-core (places_text.rs) and called
/// through rust/flows-bridge — the state tables, the MXN conversion and the
/// rounding all live there; this store keeps the live EIA cache and hands its
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
    /// Fresher truth first: EIA's live weekly average for the state or its
    /// region (keyless, 12-h cache) overrides the static factor table when
    /// present.
    static func estimate(fuel: FuelType, state: String?) -> Double {
        let raw = flows_places_text_fuel_state_code(state ?? "", state != nil).text
        let code: String? = raw.isEmpty ? nil : raw
        let live = code.flatMap { EIAFuelPrices.shared.cached($0) }
        return flows_places_text_fuel_estimate(
            fuel.rustCode, code ?? "", code != nil, live?.gas ?? 0, live?.diesel ?? 0, live != nil)
    }
}
