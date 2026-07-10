// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// LIVE, KEYLESS North-America-wide sources for the risk families the WI
/// export couldn't cover on its own — important safety information, so each
/// family now has a real feed (all probed live before shipping):
///   * fire     — NOAA HMS satellite fire hotspots (GOES; US+CA+MX) PLUS the
///                interagency WFIGS active-perimeter polygons (you're IN or
///                near a mapped fire, not just downwind of a hotspot).
///   * qpf_flood— live NWS/NWPS river gauges: real observed flood category
///                (action/minor/moderate/major) on top of precip probability.
///   * air      — Open-Meteo air quality (US AQI / PM2.5, global grid)
///   * radiation— Open-Meteo UV index PLUS NOAA SWPC space weather (the solar
///                radiation-storm S-scale and geomagnetic G-scale) — the
///                geophysical end the UV number can't see. Radiological
///                EMERGENCIES additionally arrive as CAP alerts.
///   * seismic  — USGS earthquake feed (M3+, bounded to NA)
///   * volcanic — USGS HANS elevated-volcano alert levels (US live status,
///                joined to a NA/Central-America volcano coordinate table).
///   * avalanche— Avalanche.org (US danger polygons) + Avalanche Canada
///                (per-region bulletins) EAWS 1–5 danger ratings.
///   * tropical — NHC active-storm positions + intensity.
///   * tsunami  — NWS Tsunami Warning Centers (NTWC + PTWC) CAP feeds.
///   * convective— SPC Day-1 categorical severe-weather outlook polygons.
/// The score MAPPINGS are pure (HazardFeedScores) and pinned by FLOWSTests;
/// this actor does the fetching/caching.
enum HazardFeedScores {

    /// US AQI → 0…1 risk (EPA category edges: 50/100/150/200/300).
    static func airScore(usAQI: Double) -> Double {
        switch usAQI {
        case ..<50: return usAQI / 50 * 0.2
        case ..<100: return 0.2 + (usAQI - 50) / 50 * 0.25
        case ..<150: return 0.45 + (usAQI - 100) / 50 * 0.25
        case ..<200: return 0.7 + (usAQI - 150) / 50 * 0.2
        default: return min(0.9 + (usAQI - 200) / 300 * 0.1, 1)
        }
    }

    /// UV index → 0…1 (WHO bands: 3 moderate, 6 high, 8 very high, 11 extreme).
    static func uvScore(index: Double) -> Double {
        switch index {
        case ..<3: return index / 3 * 0.2
        case ..<6: return 0.2 + (index - 3) / 3 * 0.2
        case ..<8: return 0.4 + (index - 6) / 2 * 0.2
        case ..<11: return 0.6 + (index - 8) / 3 * 0.25
        default: return min(0.85 + (index - 11) / 5 * 0.15, 1)
        }
    }

    /// Fire hotspots near a point → 0…1: each detection contributes by
    /// distance (30 km reach) and radiative power; noisy-OR combined.
    static func fireScore(
        hotspots: [(lat: Double, lon: Double, frp: Double)],
        at point: CLLocationCoordinate2D
    ) -> Double {
        // Score by the STRONGEST nearby detection, not a noisy-OR over all of
        // them. NOAA HMS reports dozens of correlated detections around one fire,
        // and a noisy-OR (which assumes independence) let a swarm of weak, distant
        // pixels multiply up to a false RED. Max-of-detection reflects the actual
        // proximity/intensity of the worst signal and can't be saturated by count.
        var best = 0.0
        for h in hotspots {
            let d = POIRanking.meters(
                CLLocationCoordinate2D(latitude: h.lat, longitude: h.lon), point)
            guard d < 30_000 else { continue }
            let proximity = 1 - d / 30_000
            let power = min(max(h.frp, 1) / 100, 1)   // 100 MW = severe
            best = max(best, min(0.3 + 0.7 * power, 1) * proximity)
        }
        return best
    }

    /// Recent quakes near a point → 0…1: magnitude past M3, decayed by
    /// distance (150 km) and age (24 h).
    static func seismicScore(
        quakes: [(lat: Double, lon: Double, magnitude: Double, ageHours: Double)],
        at point: CLLocationCoordinate2D
    ) -> Double {
        var best = 0.0
        for q in quakes {
            let d = POIRanking.meters(
                CLLocationCoordinate2D(latitude: q.lat, longitude: q.lon), point)
            guard d < 150_000, q.ageHours < 24 else { continue }
            let mag = min(max(q.magnitude - 3, 0) / 4, 1)        // M7+ = 1
            let near = 1 - d / 150_000
            let fresh = 1 - q.ageHours / 24
            best = max(best, mag * near * (0.5 + 0.5 * fresh))
        }
        return best
    }

    // MARK: fire perimeters — WFIGS active-incident polygons (NIFC)

    /// Ray-cast point-in-polygon (ring is a closed lon/lat outline).
    /// Uses raw longitude arithmetic, so a ring straddling the ±180°
    /// antimeridian would test wrong — not a concern here since every feed's
    /// polygons (WFIGS/SPC/avalanche/NWS) are queried within a NA bounding box
    /// well east of 180°.
    static func pointInPolygon(
        _ p: CLLocationCoordinate2D, _ ring: [CLLocationCoordinate2D]
    ) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.latitude > p.latitude) != (b.latitude > p.latitude) {
                let t = (p.latitude - a.latitude) / (b.latitude - a.latitude)
                if p.longitude < a.longitude + t * (b.longitude - a.longitude) {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }

    /// Distance in meters from `p` to the SEGMENT a→b, via a local
    /// equirectangular projection (exact enough at fire-perimeter scale).
    static func distanceToSegmentMeters(
        _ p: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D
    ) -> Double {
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(p.latitude * .pi / 180)
        // p at the origin; a, b in local meters.
        let ax = (a.longitude - p.longitude) * mPerDegLon
        let ay = (a.latitude - p.latitude) * mPerDegLat
        let bx = (b.longitude - p.longitude) * mPerDegLon
        let by = (b.latitude - p.latitude) * mPerDegLat
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return (ax * ax + ay * ay).squareRoot() }
        let t = max(0, min(1, -(ax * dx + ay * dy) / len2))
        let cx = ax + t * dx, cy = ay + t * dy
        return (cx * cx + cy * cy).squareRoot()
    }

    /// Active fire perimeters near a point → 0…1: inside a mapped fire is 1.0;
    /// a 12 km buffer ramps down for the smoke/evacuation fringe.
    static func firePerimeterScore(
        perimeters: [[CLLocationCoordinate2D]], at point: CLLocationCoordinate2D
    ) -> Double {
        var best = 0.0
        for ring in perimeters {
            if pointInPolygon(point, ring) { return 1.0 }
            // Distance to the nearest EDGE, not the nearest vertex — WFIGS
            // perimeters have long segments between sparse vertices, so a
            // vertex-only distance left a point beside a long edge reading far
            // from the fire and the smoke buffer never fired.
            var minD = Double.infinity
            if ring.count >= 2 {
                var prev = ring.count - 1
                for i in 0..<ring.count {
                    minD = min(minD, distanceToSegmentMeters(point, ring[prev], ring[i]))
                    prev = i
                }
            } else if let only = ring.first {
                minD = POIRanking.meters(only, point)
            }
            if minD < 12_000 { best = max(best, (1 - minD / 12_000) * 0.7) }
        }
        return best
    }

    // MARK: flood — live NWS/NWPS river-gauge flood categories

    /// NWPS observed flood category → 0…1.
    static func floodCategoryScore(_ category: String) -> Double {
        switch category {
        case "action": return 0.25
        case "minor": return 0.45
        case "moderate": return 0.70
        case "major": return 1.0
        default: return 0   // no_flooding / not_defined / obs_not_current / out_of_service
        }
    }

    /// Nearest gauge at/above flood stage within ~20 km → category × proximity.
    static func floodGaugeScore(
        gauges: [(lat: Double, lon: Double, category: String)],
        at point: CLLocationCoordinate2D
    ) -> Double {
        var best = 0.0
        for g in gauges {
            let base = floodCategoryScore(g.category)
            guard base > 0 else { continue }
            let d = POIRanking.meters(
                CLLocationCoordinate2D(latitude: g.lat, longitude: g.lon), point)
            guard d < 20_000 else { continue }
            best = max(best, base * (1 - 0.5 * d / 20_000))
        }
        return best
    }

    // MARK: radiation — NOAA SWPC space weather (S / G scales)

    /// A single NOAA space-weather scale (0…5) → 0…1. Quiet levels (0–2) stay
    /// advisory-low; a strong storm (3+) ramps toward the top of the band.
    static func spaceWeatherScore(scale: Int) -> Double {
        switch max(0, min(scale, 5)) {
        case 0: return 0
        case 1: return 0.15
        case 2: return 0.30
        case 3: return 0.55
        case 4: return 0.78
        default: return 1.0
        }
    }

    /// Radiation-family contribution from space weather: the solar radiation
    /// storm (S) at full weight, the geomagnetic storm (G) weighted by
    /// latitude (its GPS/aurora effects concentrate toward the poles).
    static func radiationSpaceWeatherScore(
        sScale: Int, gScale: Int, latitude: Double
    ) -> Double {
        let s = spaceWeatherScore(scale: sScale)
        let latWeight = min(max((abs(latitude) - 30) / 30, 0.2), 1.0)
        let g = spaceWeatherScore(scale: gScale) * latWeight
        return max(s, g)
    }

    // MARK: volcanic — USGS HANS elevated-volcano alert levels

    /// USGS volcano alert level → 0…1, banded to driving danger: ADVISORY
    /// (unrest) = green, WATCH (eruption imminent/underway) = yellow, WARNING
    /// (hazardous eruption) = red.
    static func volcanoAlertScore(_ level: String) -> Double {
        switch level.uppercased() {
        case "WARNING": return 1.0
        case "WATCH": return 0.72
        case "ADVISORY": return 0.42
        default: return 0   // NORMAL / unset
        }
    }

    /// Nearest elevated volcano within ~80 km (ashfall/proximity) → level ×
    /// proximity.
    static func volcanicScore(
        volcanoes: [(lat: Double, lon: Double, level: String)],
        at point: CLLocationCoordinate2D
    ) -> Double {
        var best = 0.0
        for v in volcanoes {
            let base = volcanoAlertScore(v.level)
            guard base > 0 else { continue }
            let d = POIRanking.meters(
                CLLocationCoordinate2D(latitude: v.lat, longitude: v.lon), point)
            guard d < 80_000 else { continue }
            best = max(best, base * (1 - 0.5 * d / 80_000))
        }
        return best
    }

    // MARK: avalanche — EAWS/North-American danger ratings (1 Low … 5 Extreme)

    /// EAWS danger rating → 0…1, banded to lethality: most avalanche deaths
    /// occur at Considerable (3) and High (4), so 3 = yellow, 4 = red.
    static func avalancheRatingScore(_ rating: Int) -> Double {
        switch max(0, min(rating, 5)) {
        case 0: return 0
        case 1: return 0.25   // Low — green
        case 2: return 0.45   // Moderate — green
        case 3: return 0.72   // Considerable — yellow (most accidents)
        case 4: return 0.90   // High — red
        default: return 1.0   // Extreme — red
        }
    }

    /// Danger rating of the forecast zone the point falls inside (US polygons
    /// or Canadian bbox rings) → 0…1.
    static func avalancheScore(
        zones: [(rings: [[CLLocationCoordinate2D]], rating: Int)],
        at point: CLLocationCoordinate2D
    ) -> Double {
        var best = 0.0
        for z in zones {
            let s = avalancheRatingScore(z.rating)
            guard s > best else { continue }
            if z.rings.contains(where: { pointInPolygon(point, $0) }) { best = s }
        }
        return best
    }

    // MARK: tropical — NHC active-storm intensity + reach

    /// Max sustained wind (knots) → 0…1, banded to driving danger: a Cat-1
    /// hurricane (do-not-drive) is already yellow, Cat-3+ (major) is red.
    static func tropicalIntensityScore(maxWindKt: Double) -> Double {
        switch maxWindKt {
        case ..<34: return 0.30    // tropical depression — green
        case ..<64: return 0.52    // tropical storm — green
        case ..<83: return 0.72    // category 1 — yellow
        case ..<96: return 0.82    // category 2 — yellow
        case ..<113: return 0.90   // category 3 — red (major)
        case ..<137: return 0.96   // category 4 — red
        default: return 1.0        // category 5 — red
        }
    }

    /// Nearest active storm, with a hazard radius that grows with intensity
    /// (~150 km tropical storm → ~400 km major hurricane).
    static func tropicalScore(
        storms: [(lat: Double, lon: Double, maxWindKt: Double)],
        at point: CLLocationCoordinate2D
    ) -> Double {
        var best = 0.0
        for s in storms {
            let d = POIRanking.meters(
                CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon), point)
            let reach = 150_000 + 250_000 * min(max((s.maxWindKt - 34) / 103, 0), 1)
            guard d < reach else { continue }
            best = max(best, tropicalIntensityScore(maxWindKt: s.maxWindKt)
                       * (1 - 0.6 * d / reach))
        }
        return best
    }

    // MARK: tsunami — NWS Tsunami Warning Center CAP levels

    /// Product level word → 0…1 (Information/Statement/Cancellation = 0),
    /// banded to action: Watch (prepare) = yellow, Advisory (dangerous
    /// currents, stay off coast) = high yellow, Warning (evacuate) = red.
    static func tsunamiLevelScore(_ level: String) -> Double {
        let l = level.lowercased()
        if l.contains("warning") { return 1.0 }
        if l.contains("advisory") { return 0.82 }
        if l.contains("watch") { return 0.72 }
        return 0
    }

    /// Active tsunami warning/watch near the event epicenter (broad coastal
    /// threat radius) → level × proximity.
    static func tsunamiScore(
        events: [(lat: Double, lon: Double, level: String)],
        at point: CLLocationCoordinate2D
    ) -> Double {
        var best = 0.0
        for e in events {
            let base = tsunamiLevelScore(e.level)
            guard base > 0 else { continue }
            let d = POIRanking.meters(
                CLLocationCoordinate2D(latitude: e.lat, longitude: e.lon), point)
            guard d < 500_000 else { continue }
            best = max(best, base * (1 - 0.5 * d / 500_000))
        }
        return best
    }

    // MARK: convective — SPC categorical severe-weather outlook

    /// SPC categorical outlook `dn` code → 0…1, banded to driving danger:
    /// SLGT = yellow, MDT/HIGH (tornado-outbreak potential) = red.
    static func spcCategoricalScore(dn: Int) -> Double {
        switch dn {
        case 2: return 0.35   // TSTM  general thunderstorms
        case 3: return 0.45   // MRGL  marginal
        case 4: return 0.60   // SLGT  slight
        case 5: return 0.72   // ENH   enhanced
        case 6: return 0.88   // MDT   moderate (red)
        case 8: return 1.0    // HIGH  high (red)
        default: return 0
        }
    }

    /// Highest score among outlook polygons the point falls inside.
    static func outlookScore(
        zones: [(rings: [[CLLocationCoordinate2D]], score: Double)],
        at point: CLLocationCoordinate2D
    ) -> Double {
        var best = 0.0
        for z in zones where z.score > best {
            if z.rings.contains(where: { pointInPolygon(point, $0) }) { best = z.score }
        }
        return best
    }

    /// DOT-reported road closure near a point → 0…1. A closure is PROOF of a
    /// blocked road — the realized primary the user's rule demands ("you need
    /// proof of blocked roads"). 1.0 within 300 m of a reported full closure,
    /// ramping to 0 at 2 km (a closure one block over still matters; one two
    /// towns over doesn't).
    static func closureScore(
        closures: [(lat: Double, lon: Double)], at point: CLLocationCoordinate2D
    ) -> Double {
        var best = 0.0
        for c in closures {
            let d = POIRanking.meters(
                CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon), point)
            if d <= 300 { return 1.0 }
            if d < 2_000 { best = max(best, 1 - (d - 300) / 1_700) }
        }
        return best
    }
}

/// Fetch + cache layer for the live feeds (viewport-scoped, polite TTLs).
actor LiveHazardFeedFetcher {
    static let shared = LiveHazardFeedFetcher()

    // MARK: fire — NOAA HMS hotspots (one NA-wide file, 30-min TTL)

    private var fireHotspots: [(lat: Double, lon: Double, frp: Double)] = []
    private var fireFetched = Date.distantPast
    private var fireInFlight: Task<[(lat: Double, lon: Double, frp: Double)], Never>?

    func hotspots() async -> [(lat: Double, lon: Double, frp: Double)] {
        if Date().timeIntervalSince(fireFetched) < AdaptiveTuning.shared.ttl(1800) { return fireHotspots }
        if let inFlight = fireInFlight { return await inFlight.value }
        let task = Task<[(lat: Double, lon: Double, frp: Double)], Never> {
            // Today's file, falling back to yesterday around UTC midnight.
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd"
            fmt.timeZone = TimeZone(identifier: "UTC")
            let ymFmt = DateFormatter()
            ymFmt.dateFormat = "yyyy/MM"
            ymFmt.timeZone = TimeZone(identifier: "UTC")
            for dayOffset in [0.0, -86_400] {
                let day = Date().addingTimeInterval(dayOffset)
                let url = "https://satepsanone.nesdis.noaa.gov/pub/FIRE/web/HMS/"
                    + "Fire_Points/Text/\(ymFmt.string(from: day))/hms_fire\(fmt.string(from: day)).txt"
                guard let u = URL(string: url),
                      let (data, resp) = try? await ThrottledNet.fetch(u),
                      (resp as? HTTPURLResponse)?.statusCode == 200,
                      let text = String(data: data, encoding: .utf8) else { continue }
                var out: [(Double, Double, Double)] = []
                for line in text.split(separator: "\n").dropFirst() {
                    let cols = line.split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces)
                    }
                    guard cols.count >= 8, let lon = Double(cols[0]),
                          let lat = Double(cols[1]), let frp = Double(cols[7]) else { continue }
                    out.append((lat, lon, frp))
                }
                if !out.isEmpty { return out }
            }
            return []
        }
        fireInFlight = task
        let result = await task.value
        if !result.isEmpty || fireHotspots.isEmpty {
            fireHotspots = result
            fireFetched = result.isEmpty
                ? Date().addingTimeInterval(-1800 + 300) : Date()   // 5-min retry on failure
        }
        fireInFlight = nil
        return fireHotspots
    }

    // MARK: seismic — USGS M3+ last 24 h over NA (5-min TTL)

    private var quakes: [(lat: Double, lon: Double, magnitude: Double, ageHours: Double)] = []
    private var quakesFetched = Date.distantPast

    func recentQuakes() async -> [(lat: Double, lon: Double, magnitude: Double, ageHours: Double)] {
        if Date().timeIntervalSince(quakesFetched) < AdaptiveTuning.shared.ttl(300) { return quakes }
        let url = "https://earthquake.usgs.gov/fdsnws/event/1/query?format=geojson"
            + "&starttime=\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400)))"
            + "&minmagnitude=3&minlatitude=14&maxlatitude=72"
            + "&minlongitude=-170&maxlongitude=-50&limit=200"
        guard let u = URL(string: url),
              let (data, resp) = try? await ThrottledNet.fetch(u),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else { return quakes }
        let now = Date().timeIntervalSince1970 * 1000
        quakes = features.compactMap { f in
            guard let geo = f["geometry"] as? [String: Any],
                  let coords = geo["coordinates"] as? [Double], coords.count >= 2,
                  let props = f["properties"] as? [String: Any],
                  let mag = props["mag"] as? Double,
                  let t = props["time"] as? Double else { return nil }
            return (coords[1], coords[0], mag, (now - t) / 3_600_000)
        }
        quakesFetched = Date()
        return quakes
    }

    // MARK: space weather — NOAA SWPC scales (R/S/G), 30-min TTL

    private var spaceWx: (r: Int, s: Int, g: Int) = (0, 0, 0)
    private var spaceWxFetched = Date.distantPast

    /// Current NOAA space-weather scales: radio blackout (R), solar radiation
    /// storm (S), geomagnetic storm (G), each 0…5. One small global JSON.
    func spaceWeather() async -> (r: Int, s: Int, g: Int) {
        if Date().timeIntervalSince(spaceWxFetched) < AdaptiveTuning.shared.ttl(1800) { return spaceWx }
        guard let u = URL(string: "https://services.swpc.noaa.gov/products/noaa-scales.json"),
              let (data, resp) = try? await ThrottledNet.fetch(u),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let now = json["0"] as? [String: Any] else { return spaceWx }
        func scale(_ k: String) -> Int {
            guard let blk = now[k] as? [String: Any],
                  let s = blk["Scale"] as? String, let v = Int(s) else { return 0 }
            return v
        }
        spaceWx = (scale("R"), scale("S"), scale("G"))
        spaceWxFetched = Date()
        return spaceWx
    }

    // MARK: fire perimeters — WFIGS interagency active polygons, viewport TTL

    private var firePerimCache: [String: (Date, [[CLLocationCoordinate2D]])] = [:]

    /// Active-fire perimeter outlines intersecting a bbox (30-min TTL). Outer
    /// rings only — the score cares about being inside/near, not holes.
    func firePerimeters(
        minLat: Double, minLon: Double, maxLat: Double, maxLon: Double
    ) async -> [[CLLocationCoordinate2D]] {
        let key = "\(Int(minLat * 4))|\(Int(minLon * 4))|\(Int(maxLat * 4))|\(Int(maxLon * 4))"
        if let c = firePerimCache[key], Date().timeIntervalSince(c.0) < AdaptiveTuning.shared.ttl(1800) { return c.1 }
        let base = "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/"
            + "WFIGS_Interagency_Perimeters/FeatureServer/0/query"
        var comps = URLComponents(string: base)
        comps?.queryItems = [
            .init(name: "where", value: "1=1"),
            .init(name: "geometry", value: "\(minLon),\(minLat),\(maxLon),\(maxLat)"),
            .init(name: "geometryType", value: "esriGeometryEnvelope"),
            .init(name: "inSR", value: "4326"),
            .init(name: "spatialRel", value: "esriSpatialRelIntersects"),
            .init(name: "outFields", value: "poly_IncidentName"),
            .init(name: "returnGeometry", value: "true"),
            .init(name: "outSR", value: "4326"),
            .init(name: "f", value: "geojson"),
            .init(name: "resultRecordCount", value: "60"),
        ]
        var rings: [[CLLocationCoordinate2D]] = []
        if let u = comps?.url,
           let (data, resp) = try? await ThrottledNet.fetch(u),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let features = json["features"] as? [[String: Any]] {
            func ring(_ raw: [[Double]]) -> [CLLocationCoordinate2D] {
                raw.compactMap { $0.count >= 2
                    ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }
            }
            for f in features {
                guard let geo = f["geometry"] as? [String: Any],
                      let type = geo["type"] as? String else { continue }
                if type == "Polygon", let coords = geo["coordinates"] as? [[[Double]]],
                   let outer = coords.first {
                    rings.append(ring(outer))
                } else if type == "MultiPolygon",
                          let polys = geo["coordinates"] as? [[[[Double]]]] {
                    for poly in polys where poly.first != nil { rings.append(ring(poly[0])) }
                }
            }
            firePerimCache[key] = (Date(), rings)
        }
        if firePerimCache.count > 40 { firePerimCache = [:] }
        return rings
    }

    // MARK: flood — NWS/NWPS river gauges at flood stage, viewport TTL

    private var floodCache: [String: (Date, [(lat: Double, lon: Double, category: String)])] = [:]

    /// River gauges in a bbox with their observed flood category (15-min TTL).
    func floodGauges(
        minLat: Double, minLon: Double, maxLat: Double, maxLon: Double
    ) async -> [(lat: Double, lon: Double, category: String)] {
        let key = "\(Int(minLat * 4))|\(Int(minLon * 4))|\(Int(maxLat * 4))|\(Int(maxLon * 4))"
        if let c = floodCache[key], Date().timeIntervalSince(c.0) < AdaptiveTuning.shared.ttl(900) { return c.1 }
        let url = "https://api.water.noaa.gov/nwps/v1/gauges?bbox.xmin=\(minLon)"
            + "&bbox.ymin=\(minLat)&bbox.xmax=\(maxLon)&bbox.ymax=\(maxLat)&srid=EPSG_4326"
        var out: [(lat: Double, lon: Double, category: String)] = []
        if let u = URL(string: url),
           let (data, resp) = try? await ThrottledNet.fetch(u),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let gauges = json["gauges"] as? [[String: Any]] {
            for g in gauges {
                guard let lat = g["latitude"] as? Double,
                      let lon = g["longitude"] as? Double,
                      let status = g["status"] as? [String: Any],
                      let obs = status["observed"] as? [String: Any],
                      let cat = obs["floodCategory"] as? String else { continue }
                out.append((lat, lon, cat))
            }
            floodCache[key] = (Date(), out)
        }
        if floodCache.count > 40 { floodCache = [:] }
        return out
    }

    // MARK: volcanic — USGS HANS elevated volcanoes (US live status), 30-min TTL

    /// Coordinates for the NA + Central-America + Caribbean volcanoes that
    /// realistically go elevated. HANS supplies live US alert LEVELS but not
    /// coordinates, so we join by name; non-US status arrives via CAP alerts.
    private static let volcanoCoords: [String: (Double, Double)] = [
        "kilauea": (19.421, -155.287), "mauna loa": (19.475, -155.608),
        "great sitkin": (52.076, -176.130), "shishaldin": (54.756, -163.970),
        "pavlof": (55.417, -161.894), "cleveland": (52.825, -169.944),
        "veniaminof": (56.170, -159.389), "trident": (58.236, -155.100),
        "mount st. helens": (46.200, -122.180), "mount rainier": (46.853, -121.760),
        "mount hood": (45.374, -121.696), "mount shasta": (41.409, -122.193),
        "lassen volcanic center": (40.492, -121.508), "redoubt": (60.485, -152.742),
        "augustine": (59.363, -153.430), "spurr": (61.299, -152.251),
        "iliamna": (60.032, -153.090), "makushin": (53.891, -166.925),
        "akutan": (54.134, -165.986), "popocatepetl": (19.023, -98.622),
        "colima": (19.514, -103.620), "fuego": (14.473, -90.880),
        "pacaya": (14.382, -90.601), "santa maria": (14.756, -91.552),
        "poas": (10.200, -84.233), "turrialba": (10.025, -83.767),
        "arenal": (10.463, -84.703), "masaya": (11.984, -86.161),
        "soufriere hills": (16.720, -62.180),
    ]

    private var volcanoes: [(lat: Double, lon: Double, level: String)] = []
    private var volcanoesFetched = Date.distantPast

    func elevatedVolcanoes() async -> [(lat: Double, lon: Double, level: String)] {
        if Date().timeIntervalSince(volcanoesFetched) < AdaptiveTuning.shared.ttl(1800) { return volcanoes }
        guard let u = URL(string:
            "https://volcanoes.usgs.gov/hans-public/api/volcano/getElevatedVolcanoes"),
              let (data, resp) = try? await ThrottledNet.fetch(u),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return volcanoes }
        var out: [(lat: Double, lon: Double, level: String)] = []
        for row in rows {
            guard let name = (row["volcano_name"] as? String)?.lowercased(),
                  let coord = Self.volcanoCoords[name],
                  let level = row["alert_level"] as? String else { continue }
            out.append((coord.0, coord.1, level))
        }
        volcanoes = out
        volcanoesFetched = Date()
        return volcanoes
    }

    // MARK: avalanche — Avalanche.org (US polygons) + Avalanche Canada (bbox), 3-h TTL

    private var avalancheZones: [(rings: [[CLLocationCoordinate2D]], rating: Int)] = []
    private var avalancheFetched = Date.distantPast

    func avalanche() async -> [(rings: [[CLLocationCoordinate2D]], rating: Int)] {
        if Date().timeIntervalSince(avalancheFetched) < AdaptiveTuning.shared.ttl(10_800) { return avalancheZones }
        var zones: [(rings: [[CLLocationCoordinate2D]], rating: Int)] = []
        // US — GeoJSON zones with danger_level 0…5.
        if let u = URL(string: "https://api.avalanche.org/v2/public/products/map-layer"),
           let (data, resp) = try? await ThrottledNet.fetch(u),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let features = json["features"] as? [[String: Any]] {
            for f in features {
                let props = f["properties"] as? [String: Any]
                let rating = (props?["danger_level"] as? Int)
                    ?? Int((props?["danger_level"] as? Double) ?? 0)
                guard rating > 0, let geo = f["geometry"] as? [String: Any],
                      let type = geo["type"] as? String else { continue }
                var rings: [[CLLocationCoordinate2D]] = []
                if type == "Polygon", let c = geo["coordinates"] as? [[[Double]]],
                   let outer = c.first {
                    rings = [outer.compactMap { $0.count >= 2
                        ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }]
                } else if type == "MultiPolygon",
                          let polys = geo["coordinates"] as? [[[[Double]]]] {
                    rings = polys.compactMap { $0.first?.compactMap { p in
                        p.count >= 2 ? CLLocationCoordinate2D(latitude: p[1], longitude: p[0]) : nil } }
                }
                if !rings.isEmpty { zones.append((rings, rating)) }
            }
        }
        // Canada — per-region bulletins carry a bbox + banded danger ratings.
        if let u = URL(string: "https://api.avalanche.ca/forecasts/en/products"),
           let (data, resp) = try? await ThrottledNet.fetch(u),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let products = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for p in products {
                guard let area = p["area"] as? [String: Any],
                      let bbox = area["bbox"] as? [Double], bbox.count >= 4 else { continue }
                let report = p["report"] as? [String: Any]
                let ratings = report?["dangerRatings"] as? [[String: Any]] ?? []
                var maxRating = 0
                for day in ratings {
                    guard let r = day["ratings"] as? [String: Any] else { continue }
                    for band in r.values {
                        guard let bd = band as? [String: Any],
                              let rate = bd["rating"] as? [String: Any],
                              let v = rate["value"] as? String,
                              let n = Int(v.prefix { $0.isNumber }) else { continue }
                        maxRating = max(maxRating, n)
                    }
                }
                guard maxRating > 0 else { continue }
                // Read the bbox POSITIONALLY with order-detection, not by sign.
                // Sign-partitioning silently dropped a whole zone whenever a value
                // landed on 0 or the four values didn't split 2-and-2 — a lethal BC
                // danger zone could read false-green. GeoJSON bbox is
                // [minLon,minLat,maxLon,maxLat]; some feeds emit lat-first. Canadian
                // lons are negative, lats positive — pick the ordering whose paired
                // slots at indices 0/2 are the negative (longitude) ones.
                let vals = Array(bbox.prefix(4))
                guard vals.count == 4 else { continue }
                let w, e, s, n: Double
                if vals[0] < 0 && vals[2] < 0 {          // [lon, lat, lon, lat]
                    w = min(vals[0], vals[2]); e = max(vals[0], vals[2])
                    s = min(vals[1], vals[3]); n = max(vals[1], vals[3])
                } else {                                  // [lat, lon, lat, lon]
                    s = min(vals[0], vals[2]); n = max(vals[0], vals[2])
                    w = min(vals[1], vals[3]); e = max(vals[1], vals[3])
                }
                guard w < e, s < n else { continue }
                let ring = [
                    CLLocationCoordinate2D(latitude: s, longitude: w),
                    CLLocationCoordinate2D(latitude: n, longitude: w),
                    CLLocationCoordinate2D(latitude: n, longitude: e),
                    CLLocationCoordinate2D(latitude: s, longitude: e),
                ]
                zones.append(([ring], maxRating))
            }
        }
        if !zones.isEmpty || avalancheZones.isEmpty {
            avalancheZones = zones
            avalancheFetched = Date()
        }
        return avalancheZones
    }

    // MARK: tropical — NHC active storms, 30-min TTL

    private var storms: [(lat: Double, lon: Double, maxWindKt: Double)] = []
    private var stormsFetched = Date.distantPast

    func tropicalStorms() async -> [(lat: Double, lon: Double, maxWindKt: Double)] {
        if Date().timeIntervalSince(stormsFetched) < AdaptiveTuning.shared.ttl(1800) { return storms }
        guard let u = URL(string: "https://www.nhc.noaa.gov/CurrentStorms.json"),
              let (data, resp) = try? await ThrottledNet.fetch(u),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = json["activeStorms"] as? [[String: Any]] else { return storms }
        storms = active.compactMap { s in
            guard let lat = s["latitudeNumeric"] as? Double,
                  let lon = s["longitudeNumeric"] as? Double else { return nil }
            // "intensity" is a kt string ("65"); default to tropical-storm force.
            let kt = (s["intensity"] as? String).flatMap(Double.init)
                ?? (s["intensity"] as? Double) ?? 35
            return (lat, lon, kt)
        }
        stormsFetched = Date()
        return storms
    }

    // MARK: tsunami — NWS Tsunami Warning Centers (NTWC + PTWC) CAP/Atom, 10-min TTL

    private var tsunamis: [(lat: Double, lon: Double, level: String)] = []
    private var tsunamisFetched = Date.distantPast

    func tsunamiEvents() async -> [(lat: Double, lon: Double, level: String)] {
        if Date().timeIntervalSince(tsunamisFetched) < AdaptiveTuning.shared.ttl(600) { return tsunamis }
        var out: [(lat: Double, lon: Double, level: String)] = []
        for feed in ["https://www.tsunami.gov/events/xml/PAAQAtom.xml",
                     "https://www.tsunami.gov/events/xml/PHEBAtom.xml"] {
            guard let u = URL(string: feed),
                  let (data, resp) = try? await ThrottledNet.fetch(u),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let xml = String(data: data, encoding: .utf8) else { continue }
            // The product level ("Tsunami Warning/Watch/Advisory") appears in
            // a title at feed and/or entry level; scan the whole document for
            // the strongest word rather than trusting one title's position.
            // A cancellation still contains the word, so exclude it.
            func first(_ tag: String) -> String? {
                guard let s = xml.range(of: "<\(tag)>"),
                      let e = xml.range(of: "</\(tag)>", range: s.upperBound..<xml.endIndex)
                else { return nil }
                return String(xml[s.upperBound..<e.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Classify PER <entry>, not per document: one "cancel" anywhere
            // was suppressing every event, and a "tsunami warning" in an
            // unrelated entry/title inflated all of them.
            for entry in xml.components(separatedBy: "<entry>").dropFirst() {
                let lower = entry.lowercased()
                guard !lower.contains("cancel") else { continue }
                let level: String
                if lower.contains("tsunami warning") { level = "warning" }
                else if lower.contains("tsunami advisory") { level = "advisory" }
                else if lower.contains("tsunami watch") { level = "watch" }
                else { continue }   // information/statement → no threat
                func entryTag(_ tag: String) -> String? {
                    guard let s0 = entry.range(of: "<\(tag)>"),
                          let e0 = entry.range(of: "</\(tag)>", range: s0.upperBound..<entry.endIndex)
                    else { return nil }
                    return String(entry[s0.upperBound..<e0.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard let latS = entryTag("geo:lat"), let lonS = entryTag("geo:long"),
                      let lat = Double(latS), let lon = Double(lonS) else { continue }
                out.append((lat, lon, level))
            }
        }
        tsunamis = out
        tsunamisFetched = Date()
        return tsunamis
    }

    // MARK: convective — SPC Day-1 categorical outlook (US), 1-h TTL

    private var spcZones: [(rings: [[CLLocationCoordinate2D]], score: Double)] = []
    private var spcFetched = Date.distantPast

    /// SPC Day-1 categorical severe-weather outlook polygons (national, small).
    func convectiveOutlook() async -> [(rings: [[CLLocationCoordinate2D]], score: Double)] {
        if Date().timeIntervalSince(spcFetched) < AdaptiveTuning.shared.ttl(3600) { return spcZones }
        let url = "https://mapservices.weather.noaa.gov/vector/rest/services/outlooks/"
            + "SPC_wx_outlks/MapServer/1/query?where=1%3D1&outFields=dn"
            + "&returnGeometry=true&outSR=4326&f=geojson"
        guard let u = URL(string: url),
              let (data, resp) = try? await ThrottledNet.fetch(u),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else { return spcZones }
        var zones: [(rings: [[CLLocationCoordinate2D]], score: Double)] = []
        for f in features {
            let props = f["properties"] as? [String: Any]
            let dn = (props?["dn"] as? Int) ?? Int((props?["dn"] as? Double) ?? 0)
            let score = HazardFeedScores.spcCategoricalScore(dn: dn)
            guard score > 0, let geo = f["geometry"] as? [String: Any],
                  let type = geo["type"] as? String else { continue }
            var rings: [[CLLocationCoordinate2D]] = []
            if type == "Polygon", let c = geo["coordinates"] as? [[[Double]]],
               let outer = c.first {
                rings = [outer.compactMap { $0.count >= 2
                    ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }]
            } else if type == "MultiPolygon",
                      let polys = geo["coordinates"] as? [[[[Double]]]] {
                rings = polys.compactMap { $0.first?.compactMap { p in
                    p.count >= 2 ? CLLocationCoordinate2D(latitude: p[1], longitude: p[0]) : nil } }
            }
            if !rings.isEmpty { zones.append((rings, score)) }
        }
        if !zones.isEmpty || spcZones.isEmpty {
            spcZones = zones
            spcFetched = Date()
        }
        return spcZones
    }

    // MARK: nearby speed limits — OSM maxspeed for the pursuit circle

    private var speedCache: [String: Double] = [:]

    /// Highest posted limit within ~2 km of a point (mph), for how fast a
    /// fleeing vehicle could plausibly travel. Default blends urban/highway.
    func maxSpeedMph(near point: CLLocationCoordinate2D) async -> Double {
        let key = "\(Int(point.latitude * 50))|\(Int(point.longitude * 50))"
        if let cached = speedCache[key] { return cached }
        let query = "[out:json][timeout:10];way[\"maxspeed\"](around:2000,"
            + "\(point.latitude),\(point.longitude));out tags 40;"
        var mph = PursuitReach.defaultSpeedMph
        if var comps = URLComponents(string: "https://overpass-api.de/api/interpreter") {
            comps.queryItems = [URLQueryItem(name: "data", value: query)]
            if let u = comps.url,
               let (data, resp) = try? await ThrottledNet.fetch(u),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let elements = json["elements"] as? [[String: Any]] {
                var best = 0.0
                for el in elements {
                    guard let tags = el["tags"] as? [String: Any],
                          let raw = tags["maxspeed"] as? String else { continue }
                    let digits = raw.prefix { $0.isNumber }
                    guard let value = Double(digits) else { continue }
                    // "55 mph" vs bare km/h numbers.
                    let asMph = raw.lowercased().contains("mph") ? value : value / 1.609344
                    best = max(best, min(asMph, 80))
                }
                if best > 0 { mph = best }
            }
        }
        speedCache[key] = mph
        if speedCache.count > 100 { speedCache = [:] }
        return mph
    }

    // MARK: air + UV — Open-Meteo per ~0.5° cell (30-min TTL)

    private struct AirCell { let aqi: Double?; let uv: Double?; let fetched: Date }
    private var airCells: [String: AirCell] = [:]
    private var airInFlight: [String: Task<(aqi: Double?, uv: Double?), Never>] = [:]

    func airAndUV(at point: CLLocationCoordinate2D) async -> (aqi: Double?, uv: Double?) {
        let key = "\(Int((point.latitude * 2).rounded()))|\(Int((point.longitude * 2).rounded()))"
        if let cell = airCells[key],
           Date().timeIntervalSince(cell.fetched) < AdaptiveTuning.shared.ttl(1800) {
            return (cell.aqi, cell.uv)
        }
        // Coalesce: a viewport sweep calls this for ~25 grid points that often
        // land in the same ~50 km cell — without this each would spawn its own
        // pair of Open-Meteo requests. Concurrent callers share one fetch.
        if let inFlight = airInFlight[key] { return await inFlight.value }
        let lat = point.latitude, lon = point.longitude
        // fetchFirstHourly is static (no instance state) so the child task
        // captures nothing — no self, no Sendable warning.
        let task = Task<(aqi: Double?, uv: Double?), Never> {
            async let aqiResp = Self.fetchFirstHourly(
                "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=\(lat)"
                + "&longitude=\(lon)&hourly=us_aqi&forecast_days=1", field: "us_aqi")
            async let uvResp = Self.fetchFirstHourly(
                "https://api.open-meteo.com/v1/forecast?latitude=\(lat)"
                + "&longitude=\(lon)&hourly=uv_index&forecast_days=1", field: "uv_index")
            return (await aqiResp, await uvResp)
        }
        airInFlight[key] = task
        let (aqi, uv) = await task.value
        airCells[key] = AirCell(aqi: aqi, uv: uv, fetched: Date())
        airInFlight[key] = nil
        if airCells.count > 200 { airCells = [:] }
        return (aqi, uv)
    }

    /// Current-hour value from an Open-Meteo hourly series. Static: no instance
    /// state, so concurrent callers need capture nothing.
    private static func fetchFirstHourly(_ url: String, field: String) async -> Double? {
        guard let u = URL(string: url),
              let (data, resp) = try? await ThrottledNet.fetch(u),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hourly = json["hourly"] as? [String: Any],
              let values = hourly[field] as? [Any],
              let times = hourly["time"] as? [String] else { return nil }
        // Pick the entry for the current UTC hour (series starts at 00:00).
        let hour = Calendar(identifier: .gregorian).with {
            $0.timeZone = TimeZone(identifier: "UTC")!
        }.component(.hour, from: Date())
        let idx = min(hour, values.count - 1, times.count - 1)
        return idx >= 0 ? values[idx] as? Double : nil
    }

    // MARK: road closures — FHWA Work Zone Data Exchange (open state feeds)

    /// The WZDx feed registry (data.transportation.gov, public Socrata JSON):
    /// which state DOTs publish open work-zone/closure feeds. 24-h TTL;
    /// feeds that require an API key are skipped (avoid-paid rule).
    private var wzdxRegistry: [(state: String, url: URL)] = []
    private var wzdxRegistryFetched = Date.distantPast
    /// Per-state closure points, 15-min TTL. Failures cache empty so a dead
    /// feed doesn't re-fetch every sweep.
    private var closureCache: [String: (Date, [(lat: Double, lon: Double)])] = [:]

    /// Rough state bounding boxes (CONUS) — picks which feeds serve a viewport.
    private static let stateBBoxes: [String: (s: Double, w: Double, n: Double, e: Double)] = [
        "AL": (30.1, -88.5, 35.0, -84.9), "AZ": (31.3, -114.8, 37.0, -109.0),
        "AR": (33.0, -94.6, 36.5, -89.6), "CA": (32.5, -124.4, 42.0, -114.1),
        "CO": (37.0, -109.1, 41.0, -102.0), "CT": (41.0, -73.7, 42.1, -71.8),
        "DE": (38.5, -75.8, 39.8, -75.0), "FL": (24.5, -87.6, 31.0, -80.0),
        "GA": (30.4, -85.6, 35.0, -80.8), "ID": (42.0, -117.2, 49.0, -111.0),
        "IL": (37.0, -91.5, 42.5, -87.0), "IN": (37.8, -88.1, 41.8, -84.8),
        "IA": (40.4, -96.6, 43.5, -90.1), "KS": (37.0, -102.1, 40.0, -94.6),
        "KY": (36.5, -89.6, 39.1, -81.9), "LA": (28.9, -94.0, 33.0, -88.8),
        "ME": (43.1, -71.1, 47.5, -66.9), "MD": (37.9, -79.5, 39.7, -75.0),
        "MA": (41.2, -73.5, 42.9, -69.9), "MI": (41.7, -90.4, 48.3, -82.4),
        "MN": (43.5, -97.2, 49.4, -89.5), "MS": (30.2, -91.7, 35.0, -88.1),
        "MO": (36.0, -95.8, 40.6, -89.1), "MT": (44.4, -116.1, 49.0, -104.0),
        "NE": (40.0, -104.1, 43.0, -95.3), "NV": (35.0, -120.0, 42.0, -114.0),
        "NH": (42.7, -72.6, 45.3, -70.6), "NJ": (38.9, -75.6, 41.4, -73.9),
        "NM": (31.3, -109.1, 37.0, -103.0), "NY": (40.5, -79.8, 45.0, -71.9),
        "NC": (33.8, -84.3, 36.6, -75.5), "ND": (45.9, -104.1, 49.0, -96.6),
        "OH": (38.4, -84.8, 42.0, -80.5), "OK": (33.6, -103.0, 37.0, -94.4),
        "OR": (42.0, -124.6, 46.3, -116.5), "PA": (39.7, -80.5, 42.3, -74.7),
        "RI": (41.1, -71.9, 42.0, -71.1), "SC": (32.0, -83.4, 35.2, -78.5),
        "SD": (42.5, -104.1, 45.9, -96.4), "TN": (35.0, -90.3, 36.7, -81.6),
        "TX": (25.8, -106.6, 36.5, -93.5), "UT": (37.0, -114.1, 42.0, -109.0),
        "VT": (42.7, -73.4, 45.0, -71.5), "VA": (36.5, -83.7, 39.5, -75.2),
        "WA": (45.5, -124.8, 49.0, -116.9), "WV": (37.2, -82.6, 40.6, -77.7),
        "WI": (42.5, -92.9, 47.1, -86.2), "WY": (41.0, -111.1, 45.0, -104.0),
    ]

    private func ensureWZDxRegistry() async {
        guard Date().timeIntervalSince(wzdxRegistryFetched) > 86_400 else { return }
        wzdxRegistryFetched = Date()   // one attempt per day even on failure
        guard let u = URL(string:
                "https://data.transportation.gov/resource/69qe-yiui.json?$limit=200"),
              let (data, resp) = try? await ThrottledNet.fetch(u),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        var out: [(String, URL)] = []
        for row in rows {
            // Field names in the registry have drifted across versions —
            // probe the plausible keys defensively.
            let state = ((row["state"] as? String)
                ?? (row["issuingorganization"] as? String) ?? "").uppercased()
            let needsKey = ((row["needapikey"] as? String) ?? "").lowercased()
            let active = ((row["active"] as? String) ?? "true").lowercased()
            guard state.count == 2, needsKey != "yes", needsKey != "true",
                  active != "false", active != "no",
                  let urlStr = (row["url"] as? String)
                    ?? ((row["url"] as? [String: Any])?["url"] as? String),
                  let url = URL(string: urlStr) else { continue }
            out.append((state, url))
        }
        if !out.isEmpty { wzdxRegistry = out }
    }

    /// DOT-reported full closures inside a bbox: WZDx GeoJSON features whose
    /// vehicle_impact is all-lanes-closed. Feeds fetched per state, 15-min TTL,
    /// at most 3 states per call — closures are the realized "road is blocked"
    /// proof (uncleared snow, flood over road, work zone) that can band Red.
    func roadClosures(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)
        async -> [(lat: Double, lon: Double)] {
        await ensureWZDxRegistry()
        guard !wzdxRegistry.isEmpty else { return [] }
        let states = Self.stateBBoxes.filter { _, b in
            b.s < maxLat && b.n > minLat && b.w < maxLon && b.e > minLon
        }.map(\.key)
        var out: [(lat: Double, lon: Double)] = []
        var seenPts = Set<String>()
        var fetched = 0
        for (state, url) in wzdxRegistry where states.contains(state) {
            // Cache per FEED (a state can publish several); the old per-state
            // key made later feeds always hit the first feed's fresh cache.
            let cacheKey = "\(state)|\(url.absoluteString.hashValue)"
            if let cached = closureCache[cacheKey],
               Date().timeIntervalSince(cached.0) < AdaptiveTuning.shared.ttl(900) {
                out.append(contentsOf: cached.1)
                continue
            }
            guard fetched < 3 else { continue }   // request budget per sweep
            fetched += 1
            var points: [(lat: Double, lon: Double)] = []
            if let (data, resp) = try? await ThrottledNet.fetch(url),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let features = json["features"] as? [[String: Any]] {
                for f in features {
                    guard let props = f["properties"] as? [String: Any] else { continue }
                    let impact = ((props["vehicle_impact"] as? String) ?? "").lowercased()
                    guard impact == "all-lanes-closed" else { continue }
                    guard let geom = f["geometry"] as? [String: Any],
                          let coords = geom["coordinates"] else { continue }
                    // LineString [[lon,lat],…] or Point [lon,lat].
                    if let line = coords as? [[Double]], let first = line.first,
                       first.count >= 2 {
                        points.append((lat: first[1], lon: first[0]))
                        if line.count > 2, let mid = line[safe: line.count / 2],
                           mid.count >= 2 {
                            points.append((lat: mid[1], lon: mid[0]))
                        }
                    } else if let pt = coords as? [Double], pt.count >= 2 {
                        points.append((lat: pt[1], lon: pt[0]))
                    }
                }
            }
            closureCache[cacheKey] = (Date(), points)   // failures cache empty
            out.append(contentsOf: points)
        }
        out = out.filter { seenPts.insert("\($0.lat),\($0.lon)").inserted }
        return out.filter {
            $0.lat >= minLat && $0.lat <= maxLat && $0.lon >= minLon && $0.lon <= maxLon
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Calendar {
    func with(_ mutate: (inout Calendar) -> Void) -> Calendar {
        var copy = self
        mutate(&copy)
        return copy
    }
}
