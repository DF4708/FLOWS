// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
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
    /// EPA VClass → (tank gal, height ft, GVWR, tow capacity) typicals.
    static func physical(forVClass vclass: String)
        -> (tank: Double, height: Double, gvwr: Double?, towCap: Double?) {
        let lower = vclass.lowercased()
        if lower.contains("pickup") {
            return (25, 6.4, 7000, 9000)
        }
        if lower.contains("sport utility") || lower.contains("suv") {
            return (17.5, 5.7, 6200, 5000)
        }
        if lower.contains("van") {
            return (25, lower.contains("passenger") ? 6.8 : 8.5, 9000, 6000)
        }
        if lower.contains("minivan") {
            return (19, 5.8, 6100, 3500)
        }
        if lower.contains("wagon") {
            return (15.5, 5.0, nil, nil)
        }
        if lower.contains("compact") || lower.contains("subcompact")
            || lower.contains("mini") || lower.contains("two seater") {
            return (12.5, 4.7, nil, nil)
        }
        if lower.contains("large") {
            return (17, 4.8, nil, nil)
        }
        // Midsize cars and anything else sedan-shaped.
        return (14.5, 4.7, nil, nil)
    }

    /// Sanity clamp: a small-car class must never inherit a van-size tank
    /// (validated against EPA economy — a 30+ mpg vehicle with a 25 gal
    /// tank would claim 750 mi of range, which no compact has).
    static func validatedTank(_ tank: Double, combinedMPU: Double) -> Double {
        let impliedRange = tank * combinedMPU
        if impliedRange > 650 { return (600 / combinedMPU * 10).rounded() / 10 }
        return tank
    }

    /// EPA fuelType1 string → FLOWS fuel type.
    static func fuelType(forEPA fuel: String) -> FuelType {
        let lower = fuel.lowercased()
        if lower.contains("electricity") { return .electric }
        if lower.contains("diesel") { return .diesel }
        return .gas
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
