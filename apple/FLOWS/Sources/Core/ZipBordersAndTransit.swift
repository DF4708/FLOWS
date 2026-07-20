// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// REAL ZIP borders for the risk overlay outside Wisconsin: the Census
/// TIGERweb ZCTA layer (keyless ArcGIS REST, probed live) returns the ZIP
/// Code Tabulation Area polygon CONTAINING any point — so an elevated risk
/// point renders as its actual ZIP outline, not a synthetic shape. US only
/// (Canada/Mexico fall back to cluster hulls); results cache by ZCTA.
actor ZCTAFetcher {
    static let shared = ZCTAFetcher()

    struct ZCTA: Sendable {
        let code: String
        let ring: [CLLocationCoordinate2D]
    }

    private var cache: [String: ZCTA] = [:]       // cell key → ZCTA
    private var byCode: [String: ZCTA] = [:]
    private var inFlight = Set<String>()

    private func cellKey(_ c: CLLocationCoordinate2D) -> String {
        "\(Int((c.latitude * 20).rounded()))|\(Int((c.longitude * 20).rounded()))"
    }

    /// The ZIP polygon containing `point` (nil while loading / outside US).
    func zcta(containing point: CLLocationCoordinate2D) async -> ZCTA? {
        let key = cellKey(point)
        if let hit = cache[key] { return hit }
        guard !inFlight.contains(key) else { return nil }
        // US envelope only — TIGERweb has no Canada/Mexico coverage.
        guard point.latitude > 24, point.latitude < 50,
              point.longitude > -125, point.longitude < -66 else { return nil }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        let url = "https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/"
            + "PUMA_TAD_TAZ_UGA_ZCTA/MapServer/1/query"
            + String(format: "?geometry=%.4f,%.4f", point.longitude, point.latitude)
            + "&geometryType=esriGeometryPoint&inSR=4326"
            + "&spatialRel=esriSpatialRelIntersects&outFields=ZCTA5"
            + "&returnGeometry=true&outSR=4326&geometryPrecision=4&f=json"
        guard let u = URL(string: url),
              let (data, resp) = try? await ThrottledNet.fetch(u),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]],
              let first = features.first,
              let attrs = first["attributes"] as? [String: Any],
              let code = attrs["ZCTA5"] as? String,
              let geometry = first["geometry"] as? [String: Any],
              let rings = geometry["rings"] as? [[[Double]]],
              let outer = rings.max(by: { $0.count < $1.count }) else { return nil }
        // Decimate long rings for map drawing.
        let step = max(outer.count / 200, 1)
        let ring = stride(from: 0, to: outer.count, by: step).compactMap { i -> CLLocationCoordinate2D? in
            let pt = outer[i]
            guard pt.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pt[1], longitude: pt[0])
        }
        guard ring.count >= 3 else { return nil }
        let z = byCode[code] ?? ZCTA(code: code, ring: ring)
        byCode[code] = z
        cache[key] = z
        if cache.count > 400 { CacheEviction.dropHalf(&cache) }
        return z
    }
}

/// TomTom Fuel Prices (the one near-free live station-price source): with a
/// key from developer.tomtom.com (free daily tier), fuel search near a
/// station returns `priceInfo` per site where TomTom licenses it. Ladder:
/// TomTom station price → state-average estimate.
actor TomTomFuel {
    static let shared = TomTomFuel()

    var apiKey = ""
    func setKey(_ key: String) { apiKey = key }

    /// Station prices with a 6 h TTL — pump prices reprice daily-ish, and the
    /// old undated cache pinned a price for the whole app session.
    private var cache: [String: (fetched: Date, price: Double?)] = [:]
    private let ttl: TimeInterval = 21_600

    func price(near point: CLLocationCoordinate2D, fuel: FuelType) async -> Double? {
        guard !apiKey.isEmpty else { return nil }
        let key = "\(Int(point.latitude * 500))|\(Int(point.longitude * 500))|\(fuel.rawValue)"
        if let hit = cache[key], Date().timeIntervalSince(hit.fetched) < ttl {
            return hit.price
        }
        let url = "https://api.tomtom.com/search/2/poiSearch/gas%20station.json"
            + "?key=\(apiKey)&lat=\(point.latitude)&lon=\(point.longitude)"
            + "&radius=500&limit=1&fuelSet=\(fuel == .diesel ? "Diesel" : "Petrol")"
        var out: Double?
        if let u = URL(string: url),
           let (data, resp) = try? await ThrottledNet.fetch(u),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = json["results"] as? [[String: Any]],
           let first = results.first,
           let priceInfo = first["priceInfo"] as? [String: Any],
           let prices = priceInfo["fuelPrices"] as? [[String: Any]],
           let p = prices.first?["price"] as? Double {
            out = p
        }
        cache[key] = (Date(), out)
        if cache.count > 300 {
            CacheEviction.dropOldestHalf(&cache) { $0.fetched }
        }
        return out
    }
}
