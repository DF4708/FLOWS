// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// ALL makes and models — the EPA fueleconomy.gov web service (keyless,
/// public domain): year → make → model menus plus real city/highway economy
/// and the EPA vehicle CLASS for every trim sold in the US since 1984.
/// Tank size and height aren't in the EPA data, so the CLASS maps to
/// typical physical specs (pure mapping, pinned by FLOWSTests) — and stays
/// hand-adjustable in the editor. The curated table remains the fast path;
/// this is the everything-else path.
enum EPAClassSpecs {
    // The class table, the tank clamp and the fuel mapping live in
    // rust/flows-core (trip_vehicle.rs) and are called through
    // rust/flows-bridge, pinned bit for bit to the Swift this replaced by
    // rust/flows-bridge/tests/fixtures/swift_trip_vehicle_oracle.tsv.

    /// EPA VClass → (tank gal, height ft, GVWR, tow capacity) typicals.
    static func physical(forVClass vclass: String)
        -> (tank: Double, height: Double, gvwr: Double?, towCap: Double?) {
        // NaN crosses back for a rating the class does not publish.
        let p = flows_trip_vehicle_epa_class_physical(vclass)
        return (p.tank, p.height, p.gvwr.isNaN ? nil : p.gvwr,
                p.tow_capacity.isNaN ? nil : p.tow_capacity)
    }

    /// Sanity clamp: a small-car class must never inherit a van-size tank
    /// (validated against EPA economy — a 30+ mpg vehicle with a 25 gal
    /// tank would claim 750 mi of range, which no compact has).
    static func validatedTank(_ tank: Double, combinedMPU: Double) -> Double {
        flows_trip_vehicle_epa_validated_tank(tank, combinedMPU)
    }

    /// EPA fuelType1 string → FLOWS fuel type.
    static func fuelType(forEPA fuel: String) -> FuelType {
        FuelType(rustCode: flows_trip_vehicle_epa_fuel_type_code(fuel)) ?? .gas
    }
}

/// Live menus + vehicle details from fueleconomy.gov (tiny XML responses).
actor EPAVehicleDatabase {
    static let shared = EPAVehicleDatabase()

    private var menuCache: [String: [String]] = [:]

    /// Model years, newest first (EPA goes back to 1984).
    func years() async -> [String] {
        await menu("https://www.fueleconomy.gov/ws/rest/vehicle/menu/year")
    }

    func makes(year: String) async -> [String] {
        await menu("https://www.fueleconomy.gov/ws/rest/vehicle/menu/make?year=\(year)")
    }

    func models(year: String, make: String) async -> [String] {
        let escaped = make.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? make
        return await menu(
            "https://www.fueleconomy.gov/ws/rest/vehicle/menu/model?year=\(year)&make=\(escaped)")
    }

    struct Details {
        let cityMPU: Double
        let highwayMPU: Double
        let vClass: String
        let fuelType: FuelType
    }

    /// First trim's economy + class for a year/make/model.
    func details(year: String, make: String, model: String) async -> Details? {
        let m = make.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? make
        let mo = model.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? model
        guard let optionsXML = await fetch(
            "https://www.fueleconomy.gov/ws/rest/vehicle/menu/options?year=\(year)&make=\(m)&model=\(mo)"),
            let id = firstTag("value", in: optionsXML),
            let xml = await fetch("https://www.fueleconomy.gov/ws/rest/vehicle/\(id)"),
            let city = firstTag("city08", in: xml).flatMap(Double.init),
            let highway = firstTag("highway08", in: xml).flatMap(Double.init)
        else { return nil }
        let vclass = firstTag("VClass", in: xml) ?? "Midsize Cars"
        let fuel = firstTag("fuelType1", in: xml) ?? "Regular Gasoline"
        return Details(cityMPU: city, highwayMPU: highway, vClass: vclass,
                       fuelType: EPAClassSpecs.fuelType(forEPA: fuel))
    }

    private func menu(_ url: String) async -> [String] {
        if let cached = menuCache[url] { return cached }
        guard let xml = await fetch(url) else { return [] }
        let items = allTags("value", in: xml)
        menuCache[url] = items
        return items
    }

    private func fetch(_ url: String) async -> String? {
        guard let u = URL(string: url),
              let (data, resp) = try? await ThrottledNet.fetch(u),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // Tiny, dependency-free XML tag scraping (EPA's responses are flat).
    nonisolated private func firstTag(_ tag: String, in xml: String) -> String? {
        allTags(tag, in: xml).first
    }

    nonisolated private func allTags(_ tag: String, in xml: String) -> [String] {
        var out: [String] = []
        var search = xml[xml.startIndex...]
        while let open = search.range(of: "<\(tag)>"),
              let close = search.range(of: "</\(tag)>", range: open.upperBound..<search.endIndex) {
            out.append(String(search[open.upperBound..<close.lowerBound])
                .replacingOccurrences(of: "&amp;", with: "&"))
            search = search[close.upperBound...]
        }
        return out
    }
}
