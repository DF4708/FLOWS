// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation
import MapKit

/// Hybrid traffic-check cadence: local rush windows get tight checks, quiet
/// hours get lazy ones. LOCAL time derives from longitude (15°/hour), so a
/// route crossing time zones re-anchors automatically. Computed in
/// rust/flows-core (travel_modes.rs), pinned by the modes oracle.
enum TrafficCadence {
    /// Peak windows (local): morning commute+school 7–9, lunch 11:30–13,
    /// school release 14:30–16, evening commute+dinner 16:30–18:30.
    static let peakSeconds: TimeInterval = flows_modes_traffic_constants()[0]     // 4 min in the windows
    static let offPeakSeconds: TimeInterval = flows_modes_traffic_constants()[1]  // 12 min otherwise

    static func isPeak(localMinutes m: Int) -> Bool {
        flows_modes_is_peak(Int64(m))
    }

    /// Local minutes-of-day at a longitude (solar approximation, ±30 min of
    /// civil time — plenty for rush-window detection). A longitude that is
    /// not a number (where this used to trap) reads as midnight.
    static func localMinutes(now: Date, longitude: Double) -> Int {
        let m = flows_modes_local_minutes(now.timeIntervalSinceReferenceDate, longitude)
        return m.has ? Int(m.minutes) : 0
    }

    static func intervalSeconds(now: Date, longitude: Double) -> TimeInterval {
        flows_modes_local_minutes(now.timeIntervalSinceReferenceDate, longitude).interval_seconds
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
/// (Inside Wisconsin the real ZIP polygons still win.) Computed in
/// rust/flows-core (travel_modes.rs), pinned by the modes oracle.
enum RiskBlob {
    /// Cluster points whose spacing is ≤ `adjacency` meters (grid neighbors).
    static func clusters(
        _ points: [CLLocationCoordinate2D], adjacencyMeters: Double
    ) -> [[CLLocationCoordinate2D]] {
        guard !points.isEmpty else { return [] }
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        let flat = Array(lats.withUnsafeBufferPointer { la in
            lons.withUnsafeBufferPointer { lo in flows_modes_risk_clusters(la, lo, adjacencyMeters) }
        })
        // [count, lengths…, indices…]
        guard let count = flat.first else { return [] }
        var at = 1 + Int(count)
        var out: [[CLLocationCoordinate2D]] = []
        for k in 0..<Int(count) {
            let len = Int(flat[1 + k])
            out.append(flat[at..<(at + len)].map { points[Int($0)] })
            at += len
        }
        return out
    }

    /// Convex hull (monotone chain), padded outward by `padMeters` so a
    /// single point still outlines a small area.
    static func hull(
        _ points: [CLLocationCoordinate2D], padMeters: Double
    ) -> [CLLocationCoordinate2D] {
        // An empty list crosses as one placeholder point the count ignores.
        let lats = points.isEmpty ? [0] : points.map(\.latitude)
        let lons = points.isEmpty ? [0] : points.map(\.longitude)
        let flat = Array(lats.withUnsafeBufferPointer { la in
            lons.withUnsafeBufferPointer { lo in
                flows_modes_risk_hull(la, lo, Int64(points.count), padMeters)
            }
        })
        return stride(from: 0, to: flat.count - 1, by: 2).map {
            CLLocationCoordinate2D(latitude: flat[$0], longitude: flat[$0 + 1])
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
    static func localBus() -> Double { flows_modes_local_fares()[0] }
    static func localRail() -> Double { flows_modes_local_fares()[1] }
    static func amtrak(miles: Double) -> Double { flows_modes_amtrak_fare(miles) }
    static func greyhound(miles: Double) -> Double { flows_modes_greyhound_fare(miles) }
}
