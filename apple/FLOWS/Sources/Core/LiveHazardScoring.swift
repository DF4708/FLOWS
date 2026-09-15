// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// The live hazard feeds, fetched once for an area, scored per point.
///
/// The map sweep and the route scorer used to differ here: the sweep scored
/// every grid point against fire perimeters and hotspots, earthquakes, space
/// weather, volcanoes, avalanche zones, tropical storms, tsunami events and
/// the SPC outlook, while the route scorer saw none of them — so a route
/// through an active wildfire with no NWS alert was not Red while the map
/// beside it was. Both now score through `HazardFeedScores.live`, from one
/// snapshot per area, and the route folds the result into the same two-tier
/// band input the map uses.
struct LiveHazardSnapshot {
    var hotspots: [(lat: Double, lon: Double, frp: Double)] = []
    var perimeters: [[CLLocationCoordinate2D]] = []
    var quakes: [(lat: Double, lon: Double, magnitude: Double, ageHours: Double)] = []
    var space: (r: Int, s: Int, g: Int) = (0, 0, 0)
    var volcanoes: [(lat: Double, lon: Double, level: String)] = []
    var avalancheZones: [(rings: [[CLLocationCoordinate2D]], rating: Int)] = []
    var storms: [(lat: Double, lon: Double, maxWindKt: Double)] = []
    var tsunamis: [(lat: Double, lon: Double, level: String)] = []
    var spcZones: [(rings: [[CLLocationCoordinate2D]], score: Double)] = []

    static let empty = LiveHazardSnapshot()

    /// The widest influence any scorer has: `tsunamiScore` reaches 500 km.
    /// Six degrees of latitude is 667 km, and six degrees of longitude is at
    /// least 500 km anywhere south of 41° N — the clip keeps every point that
    /// could score, and at higher latitudes keeps more than it needs, which
    /// is the safe direction.
    static let clipMarginDegrees = 6.0

    /// The same snapshot with every point or ring that cannot influence a
    /// score inside the box removed.
    ///
    /// The map scores at most 49 grid points; a route has hundreds of
    /// samples, and the HMS hotspot file is continent-wide and uncapped, so
    /// scoring each sample against every hotspot would be millions of
    /// distance calls on the planning path. Clipping is one linear pass. It
    /// changes no score: a point farther than the margin from the box is
    /// farther than any scorer's radius from every sample in it.
    func clipped(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) -> LiveHazardSnapshot {
        let m = Self.clipMarginDegrees
        let s = minLat - m, n = maxLat + m, w = minLon - m, e = maxLon + m
        func inside(_ lat: Double, _ lon: Double) -> Bool {
            lat >= s && lat <= n && lon >= w && lon <= e
        }
        func ringsTouch(_ rings: [[CLLocationCoordinate2D]]) -> Bool {
            rings.contains { ring in
                guard let first = ring.first else { return false }
                var rs = first.latitude, rn = first.latitude
                var rw = first.longitude, re = first.longitude
                for c in ring {
                    rs = min(rs, c.latitude); rn = max(rn, c.latitude)
                    rw = min(rw, c.longitude); re = max(re, c.longitude)
                }
                return rs <= n && rn >= s && rw <= e && re >= w
            }
        }
        var out = self
        out.hotspots = hotspots.filter { inside($0.lat, $0.lon) }
        out.perimeters = perimeters.filter { ringsTouch([$0]) }
        out.quakes = quakes.filter { inside($0.lat, $0.lon) }
        out.volcanoes = volcanoes.filter { inside($0.lat, $0.lon) }
        out.avalancheZones = avalancheZones.filter { ringsTouch($0.rings) }
        out.storms = storms.filter { inside($0.lat, $0.lon) }
        out.tsunamis = tsunamis.filter { inside($0.lat, $0.lon) }
        out.spcZones = spcZones.filter { ringsTouch($0.rings) }
        return out
    }
}

extension LiveHazardFeedFetcher {
    /// Every live feed the map sweep uses, fetched concurrently and clipped
    /// to the box. Each fetch is cached by its own TTL inside the fetcher, so
    /// a second call for a nearby box is cheap.
    func liveSnapshot(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)
        async -> LiveHazardSnapshot {
        async let hotspots = hotspots()
        async let quakes = recentQuakes()
        async let perimeters = firePerimeters(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
        async let space = spaceWeather()
        async let volcanoes = elevatedVolcanoes()
        async let avalanche = avalanche()
        async let storms = tropicalStorms()
        async let tsunamis = tsunamiEvents()
        async let spc = convectiveOutlook()
        let snap = LiveHazardSnapshot(
            hotspots: await hotspots, perimeters: await perimeters, quakes: await quakes,
            space: await space, volcanoes: await volcanoes, avalancheZones: await avalanche,
            storms: await storms, tsunamis: await tsunamis, spcZones: await spc)
        return snap.clipped(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
    }
}

extension HazardFeedScores {
    /// One point's raw score from each live feed. Every field is the exact
    /// expression the map sweep evaluated inline before this existed, so the
    /// map's numbers are unchanged and the route gets the same ones.
    struct LiveFamilies: Equatable {
        var fire: Double
        var seismic: Double
        /// Space weather only; the sweep adds the per-point UV reading itself.
        var spaceRadiation: Double
        var volcanic: Double
        var avalanche: Double
        var tropical: Double
        var tsunami: Double
        var convective: Double

        /// The families this point's live feeds put into the two-tier band
        /// input — only those that registered. Merged by max per key, so the
        /// order they are read in cannot reach a product.
        var bandInputContribution: [String: Double] {
            var out: [String: Double] = [:]
            if fire > 0 { out["fire"] = fire }
            if seismic > 0 { out["seismic"] = seismic }
            if spaceRadiation > 0 { out["radiation"] = spaceRadiation }
            if volcanic > 0 { out["volcanic"] = volcanic }
            if avalanche > 0 { out["avalanche"] = avalanche }
            if tropical > 0 { out["tropical"] = tropical }
            if tsunami > 0 { out["tsunami"] = tsunami }
            if convective > 0 { out["convective"] = convective }
            return out
        }
    }

    static func live(at pt: CLLocationCoordinate2D, snapshot s: LiveHazardSnapshot) -> LiveFamilies {
        LiveFamilies(
            fire: max(fireScore(hotspots: s.hotspots, at: pt),
                      firePerimeterScore(perimeters: s.perimeters, at: pt)),
            seismic: seismicScore(quakes: s.quakes, at: pt),
            spaceRadiation: radiationSpaceWeatherScore(
                sScale: s.space.s, gScale: s.space.g, latitude: pt.latitude),
            volcanic: volcanicScore(volcanoes: s.volcanoes, at: pt),
            avalanche: avalancheScore(zones: s.avalancheZones, at: pt),
            tropical: tropicalScore(storms: s.storms, at: pt),
            tsunami: tsunamiScore(events: s.tsunamis, at: pt),
            convective: outlookScore(zones: s.spcZones, at: pt))
    }
}
