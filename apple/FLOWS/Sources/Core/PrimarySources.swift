// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// PRIMARY sources for data the brokers resell — the weather.com/NOAA
/// pattern: go where the aggregators get it.
///
///  * MEXICO FUEL — the CRE (energy regulator) mandates publication of
///    every station's prices. Two public XMLs (probed live): `prices`
///    (regular/premium/diesel, MXN per LITER, by station id) + `places`
///    (station name + coordinates). Joined = real station-level prices for
///    the entire country, keyless. This is the upstream the paid apps use.
///
///  * US WORK ZONES — the DOT's WZDx program: a public registry of state
///    DOT work-zone GeoJSON feeds (tokens included in the registry rows).
///    Live roadwork locations along the corridor, straight from each DOT.
enum MexicoFuelParsing {
    /// Flat-XML tag scan (the CRE files are simple, ~3 MB each).
    static func parsePrices(_ xml: String) -> [String: [String: Double]] {
        var out: [String: [String: Double]] = [:]
        var search = xml[xml.startIndex...]
        while let open = search.range(of: "<place place_id=\"") {
            guard let idEnd = search.range(of: "\"", range: open.upperBound..<search.endIndex),
                  let close = search.range(of: "</place>", range: idEnd.upperBound..<search.endIndex)
            else { break }
            let id = String(search[open.upperBound..<idEnd.lowerBound])
            let body = search[idEnd.upperBound..<close.lowerBound]
            var prices: [String: Double] = [:]
            var inner = body[body.startIndex...]
            while let t = inner.range(of: "<gas_price type=\"") {
                guard let tEnd = inner.range(of: "\"", range: t.upperBound..<inner.endIndex),
                      let vStart = inner.range(of: ">", range: tEnd.upperBound..<inner.endIndex),
                      let vEnd = inner.range(of: "<", range: vStart.upperBound..<inner.endIndex)
                else { break }
                let type = String(inner[t.upperBound..<tEnd.lowerBound])
                if let v = Double(inner[vStart.upperBound..<vEnd.lowerBound]) {
                    prices[type] = v
                }
                inner = inner[vEnd.upperBound...]
            }
            if !prices.isEmpty { out[id] = prices }
            search = search[close.upperBound...]
        }
        return out
    }

    static func parsePlaces(_ xml: String) -> [String: CLLocationCoordinate2D] {
        var out: [String: CLLocationCoordinate2D] = [:]
        var search = xml[xml.startIndex...]
        while let open = search.range(of: "<place place_id=\"") {
            guard let idEnd = search.range(of: "\"", range: open.upperBound..<search.endIndex),
                  let close = search.range(of: "</place>", range: idEnd.upperBound..<search.endIndex)
            else { break }
            let id = String(search[open.upperBound..<idEnd.lowerBound])
            let body = String(search[idEnd.upperBound..<close.lowerBound])
            func tag(_ name: String) -> Double? {
                guard let s = body.range(of: "<\(name)>"),
                      let e = body.range(of: "</\(name)>", range: s.upperBound..<body.endIndex)
                else { return nil }
                return Double(body[s.upperBound..<e.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let x = tag("x"), let y = tag("y"), y > 13, y < 34 {
                out[id] = CLLocationCoordinate2D(latitude: y, longitude: x)
            }
            search = search[close.upperBound...]
        }
        return out
    }
}

/// Loads + joins the CRE files (6 h TTL) and answers nearest-station price
/// queries via a coarse grid index.
actor MexicoFuelPrices {
    static let shared = MexicoFuelPrices()

    struct Station {
        let coordinate: CLLocationCoordinate2D
        let prices: [String: Double]   // "regular"/"premium"/"diesel", MXN/L
    }

    private var grid: [Int: [Station]] = [:]
    private var loaded = Date.distantPast
    private var loading = false

    private func cellKey(_ c: CLLocationCoordinate2D) -> Int {
        Int((c.latitude * 50).rounded()) &* 100_000 &+ Int((c.longitude * 50).rounded())
    }

    private func ensureLoaded() async {
        guard Date().timeIntervalSince(loaded) > 6 * 3600, !loading else { return }
        loading = true
        defer { loading = false }
        guard let pricesURL = URL(string: "https://publicacionexterna.azurewebsites.net/publicaciones/prices"),
              let placesURL = URL(string: "https://publicacionexterna.azurewebsites.net/publicaciones/places") else { return }
        async let pricesData = try? ThrottledNet.fetch(pricesURL).0
        async let placesData = try? ThrottledNet.fetch(placesURL).0
        guard let pd = await pricesData, let ld = await placesData,
              let pricesXML = String(data: pd, encoding: .utf8),
              let placesXML = String(data: ld, encoding: .utf8) else { return }
        let prices = MexicoFuelParsing.parsePrices(pricesXML)
        let places = MexicoFuelParsing.parsePlaces(placesXML)
        var g: [Int: [Station]] = [:]
        for (id, coord) in places {
            guard let p = prices[id] else { continue }
            g[cellKey(coord), default: []].append(Station(coordinate: coord, prices: p))
        }
        grid = g
        loaded = Date()
    }

    /// Real posted price (MXN/liter) at the station nearest `point`
    /// (within ~300 m), for a FLOWS fuel type.
    func price(near point: CLLocationCoordinate2D, fuel: FuelType) async -> Double? {
        await ensureLoaded()
        guard fuel != .electric else { return nil }
        let key = fuel == .diesel ? "diesel" : "regular"
        let base = cellKey(point)
        var best: (Double, Double)?   // (distance, price)
        for dy in -1...1 {
            for dx in -1...1 {
                for s in grid[base &+ dy &* 100_000 &+ dx] ?? [] {
                    guard let p = s.prices[key] else { continue }
                    let d = POIRanking.meters(s.coordinate, point)
                    if d < 300, d < (best?.0 ?? .infinity) { best = (d, p) }
                }
            }
        }
        return best?.1
    }
}

/// US DOT WZDx work zones: registry (keyless) → the state's GeoJSON feed
/// (registry rows carry their access tokens) → zones near the corridor.
actor WorkZones {
    static let shared = WorkZones()

    struct Zone: Sendable {
        let coordinate: CLLocationCoordinate2D
        let road: String
    }

    private var registry: [String: String] = [:]   // state name → feed URL
    private var registryLoaded = Date.distantPast
    private var zones: [String: (fetched: Date, zones: [Zone])] = [:]

    private func loadRegistry() async {
        guard Date().timeIntervalSince(registryLoaded) > 24 * 3600 else { return }
        guard let url = URL(string:
            "https://data.transportation.gov/resource/69qe-yiui.json?$limit=200"),
              let (data, resp) = try? await ThrottledNet.fetch(url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        var out: [String: String] = [:]
        for row in rows where (row["active"] as? Bool ?? false)
            && (row["format"] as? String)?.lowercased() == "geojson" {
            guard let state = row["state"] as? String,
                  let urlDict = row["url"] as? [String: Any],
                  let feed = urlDict["url"] as? String else { continue }
            out[state.lowercased()] = feed
        }
        registry = out
        registryLoaded = Date()
    }

    /// Work zones for a state (30-min TTL). `stateName` lowercase full name.
    func zones(stateName: String) async -> [Zone] {
        await loadRegistry()
        if let cached = zones[stateName], Date().timeIntervalSince(cached.fetched) < 1800 {
            return cached.zones
        }
        guard let feed = registry[stateName], let url = URL(string: feed),
              let (data, resp) = try? await ThrottledNet.fetch(url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else { return [] }
        let parsed: [Zone] = features.compactMap { f in
            guard let geo = f["geometry"] as? [String: Any] else { return nil }
            var coord: CLLocationCoordinate2D?
            if let c = geo["coordinates"] as? [Double], c.count >= 2 {
                coord = CLLocationCoordinate2D(latitude: c[1], longitude: c[0])
            } else if let line = geo["coordinates"] as? [[Double]], let first = line.first,
                      first.count >= 2 {
                coord = CLLocationCoordinate2D(latitude: first[1], longitude: first[0])
            }
            guard let coord else { return nil }
            let props = f["properties"] as? [String: Any]
            let core = props?["core_details"] as? [String: Any]
            let road = (core?["road_names"] as? [String])?.first
                ?? (props?["road_name"] as? String) ?? "roadwork"
            return Zone(coordinate: coord, road: road)
        }
        zones[stateName] = (Date(), parsed)
        return parsed
    }
}
