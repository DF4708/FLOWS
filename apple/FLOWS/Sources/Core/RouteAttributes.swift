// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// Physical route attributes from public data sources — what unlocks the
/// trucker filters that used to be "no data" placeholders:
///   * Mountain grades — USGS EPQS point elevations sampled along the route
///     → max sustained grade %.
///   * Low bridges — OpenStreetMap Overpass `maxheight` ways near the
///     corridor → count of clearances below the 13'6" standard trailer.
///   * Flood exposure — FEMA NFHL flood-zone lookups (regulatory/historical
///     floodplain, which encodes localized elevation) — combined by the
///     filter with the live QPF/flood field and active flood alerts.
/// All fetches are best-effort with timeouts; nil = unknown → a filter never
/// excludes a route on missing data.
enum RouteAttributes {

    /// Max sustained grade (%) between consecutive elevation samples.
    /// Pure — unit-tested in FLOWSTests.
    static func maxGradePercent(
        elevations: [Double?], spacingMeters: Double
    ) -> Double? {
        guard spacingMeters > 0 else { return nil }
        var maxGrade = 0.0
        var sawPair = false
        for i in 1..<max(elevations.count, 1) {
            guard let a = elevations[i - 1], let b = elevations[i] else { continue }
            sawPair = true
            maxGrade = max(maxGrade, abs(b - a) / spacingMeters * 100)
        }
        return sawPair ? maxGrade : nil
    }

    /// Parse an OSM `maxheight` tag into meters. Formats seen in the wild:
    /// "4.1", "4.1 m", "13'6\"", "13 ft". Pure — unit-tested.
    static func clearanceMeters(fromOSM tag: String) -> Double? {
        let t = tag.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty || t == "default" || t == "none" || t == "unsigned" { return nil }
        // feet'inches"
        if let apos = t.firstIndex(of: "'") {
            let feet = Double(t[t.startIndex..<apos].trimmingCharacters(in: .whitespaces))
            let rest = t[t.index(after: apos)...]
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespaces)
            let inches = rest.isEmpty ? 0 : (Double(rest) ?? 0)
            guard let feet else { return nil }
            return (feet * 12 + inches) * 0.0254
        }
        if t.hasSuffix("ft") || t.hasSuffix("feet") {
            let v = t.replacingOccurrences(of: "feet", with: "")
                .replacingOccurrences(of: "ft", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Double(v).map { $0 * 0.3048 }
        }
        // Metric: strip only a TRAILING unit (m / meter / metre), longest-first,
        // and accept a decimal comma ("3,5 m" appears in the global OSM dataset).
        // The old `replacingOccurrences(of: "m")` stripped every 'm' and couldn't
        // parse a decimal comma, silently dropping a real low bridge so a tall
        // vehicle could be routed under it.
        var v = t
        for unit in ["metres", "meters", "metre", "meter", "m"] where v.hasSuffix(unit) {
            v = String(v.dropLast(unit.count))
            break
        }
        v = v.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return Double(v)
    }

    /// 13'6" — the standard US trailer clearance threshold.
    static let lowClearanceThresholdMeters = 4.115

    /// FEMA flood zones starting with A or V are the regulatory high-risk
    /// (1%-annual-chance) floodplain.
    static func isHighRiskFloodZone(_ zone: String) -> Bool {
        let z = zone.trimmingCharacters(in: .whitespaces).uppercased()
        return z.hasPrefix("A") || z.hasPrefix("V")
    }
}

/// Network side: cached, capped, best-effort fetchers for the attributes.
actor RouteAttributeFetcher {
    static let shared = RouteAttributeFetcher()

    // DELIBERATELY unbounded: terrain elevation and FEMA zone membership are
    // static facts — refetching them is pure waste, and the ~0.01° key
    // rounding bounds growth to the corridors actually driven this session.
    private var elevationCache: [String: Double?] = [:]
    private var floodZoneCache: [String: Bool?] = [:]   // key -> high-risk?
    private var clearanceCache: [String:
        (fetched: Date, hits: [(meters: Double, lat: Double, lon: Double)])] = [:]

    private func key(_ c: CLLocationCoordinate2D) -> String {
        "\(Int((c.latitude * 100).rounded()))|\(Int((c.longitude * 100).rounded()))"
    }

    /// One live fetch per rounded coordinate: grade sampling and the flood
    /// waterline probe hit the same cells from concurrent route hydrations,
    /// and each miss used to spawn its own EPQS/NFHL request through the
    /// actor's reentrancy window.
    private var elevationInFlight: [String: Task<Double?, Never>] = [:]
    private var floodZoneInFlight: [String: Task<Bool?, Never>] = [:]

    /// USGS EPQS point elevation (meters); nil on failure/no-coverage.
    /// Failures are NOT cached — an outage tonight must not read as
    /// "no elevation here" forever once the service recovers. (Dead-host
    /// fan-outs are contained by ThrottledNet's per-host breaker.)
    func elevation(at c: CLLocationCoordinate2D) async -> Double? {
        let k = key(c)
        if let cached = elevationCache[k] { return cached }
        if let running = elevationInFlight[k] { return await running.value }
        let lat = c.latitude, lon = c.longitude
        let task = Task<Double?, Never> {
            guard let url = URL(string: String(
                format: "https://epqs.nationalmap.gov/v1/json?x=%.5f&y=%.5f&wkid=4326&units=Meters&includeDate=false",
                lon, lat)),
               let (data, resp) = try? await ThrottledNet.fetch(url),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            if let v = json["value"] as? Double { return v }
            if let s = json["value"] as? String { return Double(s) }
            return nil
        }
        elevationInFlight[k] = task
        let value = await task.value
        elevationInFlight[k] = nil
        guard let value else { return nil }
        elevationCache[k] = value
        return value
    }

    /// FEMA NFHL: is the point inside a high-risk (A*/V*) flood zone?
    /// nil on failure (unknown ≠ safe ≠ risky).
    func highRiskFloodZone(at c: CLLocationCoordinate2D) async -> Bool? {
        let k = key(c)
        if let cached = floodZoneCache[k] { return cached }
        if let running = floodZoneInFlight[k] { return await running.value }
        let lat = c.latitude, lon = c.longitude
        let task = Task<Bool?, Never> {
            let urlString = "https://hazards.fema.gov/arcgis/rest/services/public/NFHL/MapServer/28/query"
                + String(format: "?geometry=%.5f,%.5f", lon, lat)
                + "&geometryType=esriGeometryPoint&inSR=4326&spatialRel=esriSpatialRelIntersects"
                + "&outFields=FLD_ZONE&returnGeometry=false&f=json"
            guard let url = URL(string: urlString),
               let (data, resp) = try? await ThrottledNet.fetch(url),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let features = json["features"] as? [[String: Any]]
            else { return nil }
            let zones = features.compactMap {
                ($0["attributes"] as? [String: Any])?["FLD_ZONE"] as? String
            }
            return zones.contains(where: RouteAttributes.isHighRiskFloodZone)
        }
        floodZoneInFlight[k] = task
        let result = await task.value
        floodZoneInFlight[k] = nil
        // Cache real answers (true/false), never failures — a FEMA hiccup
        // must not pin "unknown" on this cell for the app's lifetime.
        if result != nil { floodZoneCache[k] = result }
        return result
    }

    /// OSM Overpass: posted clearances (meters, below 5.5 m) inside the
    /// corridor bounding boxes — compared against the vehicle-height slider.
    /// nil on failure/rate-limit.
    /// Returns (clearanceMeters, lat, lon) so the caller keeps only posts
    /// actually ON the route — the ±3 km corridor boxes also catch parking
    /// garages and side-street underpasses (a 6 ft garage bar was failing
    /// whole interstates like I-65).
    func clearances(inBoxes boxes: [(s: Double, w: Double, n: Double, e: Double)])
        async -> [(meters: Double, lat: Double, lon: Double)]? {
        guard !boxes.isEmpty else { return [] }
        // Bridges are static infrastructure — re-scoring the same route (same
        // corridor boxes) must not re-query Overpass, which is strictly
        // rate-limited. Key on the rounded boxes; only successes are cached
        // (a failure must stay retryable), on a long TTL that still stretches
        // on a strained device.
        let cacheKey = boxes.map { String(format: "%.2f,%.2f,%.2f,%.2f", $0.s, $0.w, $0.n, $0.e) }
            .joined(separator: ";")
        if let c = clearanceCache[cacheKey],
           Date().timeIntervalSince(c.fetched) < AdaptiveTuning.shared.ttl(6 * 3600) {
            return c.hits
        }
        let clauses = boxes.map {
            String(format: "way[\"maxheight\"](%.4f,%.4f,%.4f,%.4f);", $0.s, $0.w, $0.n, $0.e)
        }.joined()
        let query = "[out:json][timeout:10];(\(clauses));out center tags;"
        // Primary + mirror: the main instance rate-limits under load, which
        // used to leave the route card in "Bridges: checking…" forever.
        // Verified 2026-07-05: primary healthy (69 elements on the Madison
        // box); kumi mirror was down — a third instance keeps the ladder up.
        // Overpass mirrors, all EU-hosted and reputable: the main German
        // instance, Kumi Systems (Austria), and OpenStreetMap France. Route
        // corridor coordinates are POSTed here, so the endpoint set is
        // deliberately limited to trusted operators — no mirrors hosted in
        // or operated from sanctioned/adversarial jurisdictions.
        for endpoint in ["https://overpass-api.de/api/interpreter",
                         "https://overpass.kumi.systems/api/interpreter",
                         "https://overpass.openstreetmap.fr/api/interpreter"] {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 12
            request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)"
                .data(using: .utf8)
            guard let (data, resp) = try? await ThrottledNet.fetch(request),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let elements = json["elements"] as? [[String: Any]]
            else { continue }
            let hits: [(meters: Double, lat: Double, lon: Double)] = elements.compactMap { el in
                guard let tags = el["tags"] as? [String: Any],
                      let mh = tags["maxheight"] as? String,
                      let m = RouteAttributes.clearanceMeters(fromOSM: mh),
                      m < 5.5 else { return nil }
                let center = el["center"] as? [String: Any]
                let lat = (center?["lat"] as? Double) ?? (el["lat"] as? Double) ?? 0
                let lon = (center?["lon"] as? Double) ?? (el["lon"] as? Double) ?? 0
                return (m, lat, lon)
            }
            clearanceCache[cacheKey] = (Date(), hits)
            if clearanceCache.count > 60 {
                CacheEviction.dropOldestHalf(&clearanceCache) { $0.fetched }
            }
            return hits
        }
        return nil
    }
}
