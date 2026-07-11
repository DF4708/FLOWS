// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation
import MapKit

/// Hybrid traffic-check cadence: local rush windows get tight checks, quiet
/// hours get lazy ones. LOCAL time derives from longitude (15°/hour), so a
/// route crossing time zones re-anchors automatically. Pure, tested.
enum TrafficCadence {
    /// Peak windows (local): morning commute+school 7–9, lunch 11:30–13,
    /// school release 14:30–16, evening commute+dinner 16:30–18:30.
    static let peakSeconds: TimeInterval = 240      // 4 min in the windows
    static let offPeakSeconds: TimeInterval = 720   // 12 min otherwise

    static func isPeak(localMinutes m: Int) -> Bool {
        (m >= 7 * 60 && m < 9 * 60)
            || (m >= 11 * 60 + 30 && m < 13 * 60)
            || (m >= 14 * 60 + 30 && m < 16 * 60)
            || (m >= 16 * 60 + 30 && m < 18 * 60 + 30)
    }

    /// Local minutes-of-day at a longitude (solar approximation, ±30 min of
    /// civil time — plenty for rush-window detection).
    static func localMinutes(now: Date, longitude: Double) -> Int {
        let utcSeconds = now.timeIntervalSince1970
            .truncatingRemainder(dividingBy: 86_400)
        let offset = longitude / 15 * 3600
        var local = (utcSeconds + offset).truncatingRemainder(dividingBy: 86_400)
        if local < 0 { local += 86_400 }
        return Int(local / 60)
    }

    static func intervalSeconds(now: Date, longitude: Double) -> TimeInterval {
        isPeak(localMinutes: localMinutes(now: now, longitude: longitude))
            ? peakSeconds : offPeakSeconds
    }

    /// Coordinate ~`meters` further along a polyline from `from` meters in.
    static func pointAlong(
        polyline: MKPolyline, from: Double, meters: Double
    ) -> CLLocationCoordinate2D? {
        let pts = RouteService.samplePoints(of: polyline, everyMeters: 5_000)
        guard !pts.isEmpty else { return nil }
        let idx = Int((from + meters) / 5_000)
        return pts[min(max(idx, 0), pts.count - 1)]
    }
}

/// Contiguous-area outlines for the normalized risk layer: adjacent elevated
/// grid points cluster (grid-neighbor adjacency), and each cluster draws as
/// a convex-hull polygon — an outline of the AFFECTED AREA, not a circle.
/// (Inside Wisconsin the real ZIP polygons still win.) Pure, tested.
enum RiskBlob {
    /// Cluster points whose spacing is ≤ `adjacency` meters (grid neighbors).
    static func clusters(
        _ points: [CLLocationCoordinate2D], adjacencyMeters: Double
    ) -> [[CLLocationCoordinate2D]] {
        var remaining = points
        var out: [[CLLocationCoordinate2D]] = []
        while let seed = remaining.popLast() {
            var cluster = [seed]
            var frontier = [seed]
            while let p = frontier.popLast() {
                let near = remaining.enumerated().filter {
                    POIRanking.meters($0.element, p) <= adjacencyMeters
                }
                for (offset, q) in near.sorted(by: { $0.offset > $1.offset }) {
                    remaining.remove(at: offset)
                    cluster.append(q)
                    frontier.append(q)
                }
            }
            out.append(cluster)
        }
        return out
    }

    /// Convex hull (monotone chain), padded outward by `padMeters` so a
    /// single point still outlines a small area.
    static func hull(
        _ points: [CLLocationCoordinate2D], padMeters: Double
    ) -> [CLLocationCoordinate2D] {
        let padDeg = padMeters / 111_320
        guard points.count > 2 else {
            // 1–2 points → a small diamond outline around the centroid.
            let lat = points.map(\.latitude).reduce(0, +) / Double(max(points.count, 1))
            let lon = points.map(\.longitude).reduce(0, +) / Double(max(points.count, 1))
            return [
                CLLocationCoordinate2D(latitude: lat + padDeg, longitude: lon),
                CLLocationCoordinate2D(latitude: lat, longitude: lon + padDeg * 1.4),
                CLLocationCoordinate2D(latitude: lat - padDeg, longitude: lon),
                CLLocationCoordinate2D(latitude: lat, longitude: lon - padDeg * 1.4),
            ]
        }
        let sorted = points.sorted {
            $0.longitude != $1.longitude ? $0.longitude < $1.longitude
                : $0.latitude < $1.latitude
        }
        func cross(_ o: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D,
                   _ b: CLLocationCoordinate2D) -> Double {
            (a.longitude - o.longitude) * (b.latitude - o.latitude)
                - (a.latitude - o.latitude) * (b.longitude - o.longitude)
        }
        var lower: [CLLocationCoordinate2D] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [CLLocationCoordinate2D] = []
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        let ring = Array(lower.dropLast() + upper.dropLast())
        // Pad outward from the centroid.
        let cLat = ring.map(\.latitude).reduce(0, +) / Double(ring.count)
        let cLon = ring.map(\.longitude).reduce(0, +) / Double(ring.count)
        return ring.map { p in
            let dLat = p.latitude - cLat, dLon = p.longitude - cLon
            let len = max((dLat * dLat + dLon * dLon).squareRoot(), 1e-9)
            return CLLocationCoordinate2D(
                latitude: p.latitude + dLat / len * padDeg,
                longitude: p.longitude + dLon / len * padDeg)
        }
    }
}

/// Walking + transit options. Apple gives full WALKING routes (pedestrian
/// network: sidewalks/crossings where mapped, roads elsewhere, real walking
/// pace) and TRANSIT ETAs — but not transit geometry, so transit options
/// present as cards (walk leg + transit ETA + fare estimate) that hand off
/// to Maps for turn-by-turn. Fare DISCLOSURES are estimates: local bus
/// ~$2.25 flat, rail/subway ~$2.75, Amtrak ≈ $0.15/mi (min $15), Greyhound
/// ≈ $0.12/mi (min $12).
enum TransitFares {
    static func localBus() -> Double { 2.25 }
    static func localRail() -> Double { 2.75 }
    static func amtrak(miles: Double) -> Double { max(15, miles * 0.15) }
    static func greyhound(miles: Double) -> Double { max(12, miles * 0.12) }
}
