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
///   * Bridge weight — `maxweight` ways from the SAME Overpass sweep →
///     posted limits compared against the driver's vehicle + towing weight.
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

    /// Parse an OSM `maxweight` tag into POUNDS. The OSM default unit is
    /// metric tonnes; formats seen in the wild: "7.5", "7.5 t", "3,5",
    /// "10000 lbs", "5 st" (US short tons), "3500 kg". Pure — unit-tested.
    static func weightLimitLbs(fromOSM tag: String) -> Double? {
        let t = tag.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty || t == "default" || t == "none" || t == "unsigned" { return nil }
        func number(_ s: Substring) -> Double? {
            Double(s.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ",", with: "."))
        }
        let lbsPerTonne = 2204.62
        // Longest suffix first so "5 st" (short tons) never reads as "t".
        let units: [(suffix: String, lbsPerUnit: Double)] = [
            ("tonnes", lbsPerTonne), ("tonne", lbsPerTonne),
            // US mappers write "10 tons" meaning SHORT tons (20,000 lb).
            // Reading it as metric (22,046 lb) was ~10% too permissive on a
            // safety filter — bare ton/tons is the conservative 2,000 lb.
            ("tons", 2000), ("ton", 2000),
            ("lbs", 1), ("lb", 1),
            ("kg", 2.20462),
            ("st", 2000),          // US short ton
            ("t", lbsPerTonne),
        ]
        for unit in units where t.hasSuffix(unit.suffix) {
            return number(t.dropLast(unit.suffix.count)).map { $0 * unit.lbsPerUnit }
        }
        // Bare number → metric tonnes (the OSM default).
        return number(t[...]).map { $0 * lbsPerTonne }
    }

    /// Posted limits at or above 100,000 lb don't restrict anything FLOWS
    /// models (the US federal interstate max is 80,000 lb) — ignored as
    /// "no practical limit", like clearances above 5.5 m.
    static let weightLimitCapLbs = 100_000.0

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

    // Elevation and FEMA zone membership are static facts, so entries never
    // go stale — but "bounded by corridors driven this session" is a weaker
    // bound than it sounds at a 0.01° key (a heavy replanning session
    // reaches five figures), so both carry the same overflow cap as
    // restrictionCache below. Undated caches → dropHalf.
    private var elevationCache: [String: Double?] = [:]
    private var floodZoneCache: [String: Bool?] = [:]   // key -> high-risk?
    private var restrictionCache: [String:
        (fetched: Date,
         clearances: [(meters: Double, lat: Double, lon: Double)],
         weights: [(lbs: Double, lat: Double, lon: Double)])] = [:]

    private func key(_ c: CLLocationCoordinate2D) -> String {
        "\(Int((c.latitude * 100).rounded()))|\(Int((c.longitude * 100).rounded()))"
    }

    /// One live fetch per rounded coordinate: grade sampling and the flood
    /// waterline probe hit the same cells from concurrent route hydrations,
    /// and each miss used to spawn its own EPQS/NFHL request through the
    /// actor's reentrancy window.
    private var elevationInFlight: [String: Task<Double?, Never>] = [:]
    private var floodZoneInFlight: [String: Task<Bool?, Never>] = [:]

    /// BATCHED elevations, order-aligned with `points` — ONE Open-Meteo
    /// request per 100 points (keyless, already an app provider for
    /// air-quality; Copernicus GLO-90 DEM) with the per-point EPQS fetcher
    /// as the fallback for anything the batch can't answer. A route's
    /// attribute pass asked EPQS ~105 separate questions; this asks 1-2.
    /// Bonus: GLO-90 is continent-wide, so grades now resolve on Canadian
    /// and Mexican corridors where EPQS has no coverage. Grade sampling at
    /// ≥1.2 km spacing is insensitive to the DEMs' vertical-accuracy
    /// difference (a few m RMSE over ≥1.2 km is <0.4% grade). Same
    /// contracts as elevation(at:): per-cell cache, failures never cached.
    func elevations(at points: [CLLocationCoordinate2D]) async -> [Double?] {
        var out = [Double?](repeating: nil, count: points.count)
        var missing: [(Int, CLLocationCoordinate2D)] = []
        for (i, p) in points.enumerated() {
            if let cached = elevationCache[key(p)] {
                out[i] = cached
            } else {
                missing.append((i, p))
            }
        }
        guard !missing.isEmpty else { return out }
        var start = 0
        while start < missing.count {
            let chunk = Array(missing[start..<min(start + 100, missing.count)])
            start += chunk.count
            let lats = chunk.map { String(format: "%.5f", $0.1.latitude) }.joined(separator: ",")
            let lons = chunk.map { String(format: "%.5f", $0.1.longitude) }.joined(separator: ",")
            guard let url = URL(string:
                "https://api.open-meteo.com/v1/elevation?latitude=\(lats)&longitude=\(lons)"),
                  let (data, resp) = try? await ThrottledNet.fetch(url),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let elevs = json["elevation"] as? [Double], elevs.count == chunk.count
            else {
                FlowsDiag.logThrottled(
                    key: "elev.batchFail", .warn, "elevation",
                    "Open-Meteo batch failed — \(chunk.count) points riding per-point EPQS")
                continue   // whole chunk rides the EPQS fallback below
            }
            for (j, (i, p)) in chunk.enumerated() {
                out[i] = elevs[j]
                elevationCache[key(p)] = elevs[j]
            }
        }
        if elevationCache.count > 4000 { CacheEviction.dropHalf(&elevationCache) }
        // Anything the batch couldn't answer: the per-point EPQS path, with
        // its own cache/coalescing/no-failure-caching semantics.
        await withTaskGroup(of: (Int, Double?).self) { group in
            for (i, p) in missing where out[i] == nil {
                group.addTask { (i, await self.elevation(at: p)) }
            }
            for await (i, v) in group { out[i] = v }
        }
        return out
    }

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
        if elevationCache.count > 4000 { CacheEviction.dropHalf(&elevationCache) }
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
        if result != nil {
            floodZoneCache[k] = result
            if floodZoneCache.count > 4000 { CacheEviction.dropHalf(&floodZoneCache) }
        }
        return result
    }

    /// OSM Overpass: posted clearances (meters, below 5.5 m) AND posted
    /// weight limits (pounds, below the relevance cap) inside the corridor
    /// bounding boxes — clearances feed the vehicle-height slider, weight
    /// limits the bridge-weight check. Both tags ride ONE query so the
    /// second check adds no Overpass load (the instances are strictly
    /// rate-limited). nil on failure/rate-limit.
    /// Coordinates ride along so the caller keeps only posts actually ON the
    /// route — the ±3 km corridor boxes also catch parking garages and
    /// side-street underpasses (a 6 ft garage bar was failing whole
    /// interstates like I-65).
    func postedRestrictions(inBoxes boxes: [(s: Double, w: Double, n: Double, e: Double)])
        async -> (clearances: [(meters: Double, lat: Double, lon: Double)],
                  weights: [(lbs: Double, lat: Double, lon: Double)])? {
        guard !boxes.isEmpty else { return ([], []) }
        // Bridges are static infrastructure — re-scoring the same route (same
        // corridor boxes) must not re-query Overpass, which is strictly
        // rate-limited. Key on the rounded boxes; only successes are cached
        // (a failure must stay retryable), on a long TTL that still stretches
        // on a strained device.
        let cacheKey = boxes.map { String(format: "%.2f,%.2f,%.2f,%.2f", $0.s, $0.w, $0.n, $0.e) }
            .joined(separator: ";")
        if let c = restrictionCache[cacheKey],
           Date().timeIntervalSince(c.fetched) < AdaptiveTuning.shared.ttl(6 * 3600) {
            return (c.clearances, c.weights)
        }
        let clauses = boxes.map {
            let bbox = String(format: "%.4f,%.4f,%.4f,%.4f", $0.s, $0.w, $0.n, $0.e)
            return "way[\"maxheight\"](\(bbox));way[\"maxweight\"](\(bbox));"
        }.joined()
        let query = "[out:json][timeout:10];(\(clauses));out center tags;"
        // The shared mirror ladder (LiveHazardFeedFetcher.overpassEndpoints)
        // — the main instance rate-limits under load, which used to leave
        // the route card in "Bridges: checking…" forever. This query POSTs
        // route corridor coordinates, which is why that endpoint set is
        // limited to trusted EU operators.
        for endpoint in LiveHazardFeedFetcher.overpassEndpoints {
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
            var clearanceHits: [(meters: Double, lat: Double, lon: Double)] = []
            var weightHits: [(lbs: Double, lat: Double, lon: Double)] = []
            for el in elements {
                guard let tags = el["tags"] as? [String: Any] else { continue }
                let center = el["center"] as? [String: Any]
                let lat = (center?["lat"] as? Double) ?? (el["lat"] as? Double) ?? 0
                let lon = (center?["lon"] as? Double) ?? (el["lon"] as? Double) ?? 0
                if let mh = tags["maxheight"] as? String,
                   let m = RouteAttributes.clearanceMeters(fromOSM: mh), m < 5.5 {
                    clearanceHits.append((m, lat, lon))
                }
                if let mw = tags["maxweight"] as? String,
                   let lbs = RouteAttributes.weightLimitLbs(fromOSM: mw),
                   lbs < RouteAttributes.weightLimitCapLbs {
                    weightHits.append((lbs, lat, lon))
                }
            }
            restrictionCache[cacheKey] = (Date(), clearanceHits, weightHits)
            if restrictionCache.count > 60 {
                CacheEviction.dropOldestHalf(&restrictionCache) { $0.fetched }
            }
            return (clearanceHits, weightHits)
        }
        return nil
    }
}
