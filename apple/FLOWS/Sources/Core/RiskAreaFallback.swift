// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// When the planning map outlines a risk point with its real ZIP boundary,
/// and when a rough hull ("blob") stands in for it.
enum RiskAreaFallback {
    /// The box the ZIP layer is asked about (`ZCTAFetcher`): the lower 48,
    /// roughly. It also takes in southern Canada, northern Mexico and the
    /// Great Lakes, where no ZIP ever comes back — so only a point's own
    /// lookup, never this box, says it has no ZIP.
    static func inZIPBox(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude > 24 && c.latitude < 50 && c.longitude > -125 && c.longitude < -66
    }

    /// Whether a risk point's blob waits for this sweep's ZIP lookups
    /// instead of drawing now. Inside the box a blob is a placeholder that
    /// snaps into the ZIP outline a moment later, so a point new to the map
    /// waits for its outline. A point an earlier sweep's lookups already
    /// placed keeps what they decided: for Toronto or open water that is its
    /// blob for good, and waiting again blinked it out at every re-sweep.
    /// Outside the box the blob is the only answer and never waits.
    static func blobWaits(at c: CLLocationCoordinate2D, lookupsDone: Bool,
                          placedBefore: Bool) -> Bool {
        inZIPBox(c) && !lookupsDone && !placedBefore
    }

    /// The planning sweep's sample points: a lattice fixed to the MAP, not
    /// to the camera. The spacing is the smallest rung of a fixed ladder
    /// (each rung √2 apart) that keeps about `perSide` points across the
    /// view, and the points sit on whole multiples of it — so a small pan, a
    /// zoom within one rung, or the five-minute re-sweep samples the SAME
    /// places. A grid centred on the camera slid with every pan: each sweep
    /// read slightly different spots, caught different ZIPs, and risk areas
    /// came and went though the weather had not changed.
    static func lattice(centerLatitude: Double, centerLongitude: Double,
                        spanLatitude: Double, spanLongitude: Double,
                        perSide: Int) -> [CLLocationCoordinate2D] {
        let across = Double(max(perSide, 1))
        func rung(_ wanted: Double) -> Double {
            guard wanted.isFinite, wanted > 0 else { return 1 }
            return pow(2, (2 * log2(wanted)).rounded(.up) / 2)
        }
        let stepLat = rung(spanLatitude / across)
        let stepLon = rung(spanLongitude / across)
        let lat0 = centerLatitude - spanLatitude / 2, lat1 = centerLatitude + spanLatitude / 2
        let lon0 = centerLongitude - spanLongitude / 2, lon1 = centerLongitude + spanLongitude / 2
        var out: [CLLocationCoordinate2D] = []
        // Whole multiples by index, not by repeated addition: a running sum
        // drifts, and a drifted point is a different point to every cache.
        var i = (lat0 / stepLat).rounded(.up)
        while i * stepLat <= lat1 {
            var j = (lon0 / stepLon).rounded(.up)
            while j * stepLon <= lon1 {
                out.append(CLLocationCoordinate2D(latitude: i * stepLat, longitude: j * stepLon))
                j += 1
            }
            i += 1
        }
        return out
    }

    /// A circle as a ring of `points` vertices — the outline for risk with no
    /// ZIP under it (open water, Canada, Mexico). It was a padded hull,
    /// which for one point is a box: "squares over the lake".
    static func circleRing(center: CLLocationCoordinate2D, radiusMeters: Double,
                           points: Int = 32) -> [CLLocationCoordinate2D] {
        let dLat = radiusMeters / 111_320
        let dLon = radiusMeters / (111_320 * max(cos(center.latitude * .pi / 180), 1e-6))
        return (0..<max(points, 3)).map { k in
            let a = Double(k) / Double(max(points, 3)) * 2 * .pi
            return CLLocationCoordinate2D(latitude: center.latitude + dLat * sin(a),
                                          longitude: center.longitude + dLon * cos(a))
        }
    }

    /// Where an area's one icon stands: the shape's centroid when that lies
    /// inside it, else the middle of the widest stretch of the shape along
    /// the centroid's latitude — a crescent-shaped ZIP's centroid can sit in
    /// the next ZIP over, and its icon with it.
    static func iconAnchor(of ring: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        let c = centroid(of: ring)
        guard ring.count >= 3, !contains(ring, c) else { return c }
        var xs: [Double] = []
        for i in 0..<ring.count {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            if (a.latitude <= c.latitude) != (b.latitude <= c.latitude) {
                let t = (c.latitude - a.latitude) / (b.latitude - a.latitude)
                xs.append(a.longitude + t * (b.longitude - a.longitude))
            }
        }
        xs.sort()
        var best: (Double, Double)?
        var k = 0
        while k + 1 < xs.count {
            if best == nil || xs[k + 1] - xs[k] > best!.1 - best!.0 { best = (xs[k], xs[k + 1]) }
            k += 2
        }
        guard let span = best else { return c }
        return CLLocationCoordinate2D(latitude: c.latitude, longitude: (span.0 + span.1) / 2)
    }

    /// Shoelace (area-weighted) centroid — the middle of the SHAPE, not of
    /// its vertices; the vertex mean for a ring with no area.
    static func centroid(of ring: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        guard !ring.isEmpty else { return CLLocationCoordinate2D() }
        var area = 0.0, cx = 0.0, cy = 0.0
        for i in 0..<ring.count {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let cross = a.longitude * b.latitude - b.longitude * a.latitude
            area += cross
            cx += (a.longitude + b.longitude) * cross
            cy += (a.latitude + b.latitude) * cross
        }
        if abs(area) > 1e-12 {
            return CLLocationCoordinate2D(latitude: cy / (3 * area), longitude: cx / (3 * area))
        }
        let lat = ring.map(\.latitude).reduce(0, +) / Double(ring.count)
        let lon = ring.map(\.longitude).reduce(0, +) / Double(ring.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Up to `limit` points spread inside a shape — its icon anchor first,
    /// then a grid over its bounding box kept to the points inside it. A
    /// warning's polygon is drawn by the ZIPs these points fall in.
    static func interiorSamples(of ring: [CLLocationCoordinate2D],
                                limit: Int = 9) -> [CLLocationCoordinate2D] {
        guard ring.count >= 3, limit > 0 else { return [] }
        var out = [iconAnchor(of: ring)]
        let lats = ring.map(\.latitude), lons = ring.map(\.longitude)
        guard let la0 = lats.min(), let la1 = lats.max(),
              let lo0 = lons.min(), let lo1 = lons.max() else { return out }
        let side = 4
        for i in 0..<side {
            for j in 0..<side {
                let p = CLLocationCoordinate2D(
                    latitude: la0 + (la1 - la0) * (Double(i) + 0.5) / Double(side),
                    longitude: lo0 + (lo1 - lo0) * (Double(j) + 0.5) / Double(side))
                if contains(ring, p) { out.append(p) }
            }
        }
        // Spread across the shape rather than the first row of it.
        guard out.count > limit else { return out }
        let stride = Double(out.count - 1) / Double(limit - 1)
        return (0..<limit).map { out[Int((Double($0) * stride).rounded())] }
    }

    /// Even–odd point-in-polygon.
    static func contains(_ ring: [CLLocationCoordinate2D], _ p: CLLocationCoordinate2D) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.latitude > p.latitude) != (b.latitude > p.latitude) {
                let x = a.longitude + (p.latitude - a.latitude) / (b.latitude - a.latitude)
                    * (b.longitude - a.longitude)
                if p.longitude < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}
