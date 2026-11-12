// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import FlowsBridge
import Foundation

/// When the planning map outlines a risk point with its real ZIP boundary,
/// and when a rough hull ("blob") stands in for it.
///
/// The rules run in Rust (flows-core `risk_area`, pinned by a frozen oracle
/// of this file's original Swift). A ring crosses as `[lat, lon, lat, lon,
/// …]`.
enum RiskAreaFallback {
    /// The box the ZIP layer is asked about (`ZCTAFetcher`): the lower 48,
    /// roughly. It also takes in southern Canada, northern Mexico and the
    /// Great Lakes, where no ZIP ever comes back — so only a point's own
    /// lookup, never this box, says it has no ZIP.
    static func inZIPBox(_ c: CLLocationCoordinate2D) -> Bool {
        flows_risk_area_in_zip_box(c.latitude, c.longitude)
    }

    /// Whether a risk point's blob waits for this sweep's ZIP lookups
    /// instead of drawing now. Inside the box a blob is a placeholder that
    /// snaps into the ZIP outline a moment later, so a point new to the map
    /// waits for its outline. A point an earlier sweep's lookups already
    /// placed keeps what they decided: for Toronto or open water that is its
    /// blob for good, and waiting again blinked it out at every re-sweep.
    /// Outside the box the blob is the only answer and never waits.
    static func blobWaits(
        at c: CLLocationCoordinate2D, lookupsDone: Bool,
        placedBefore: Bool
    ) -> Bool {
        flows_risk_area_blob_waits(c.latitude, c.longitude, lookupsDone, placedBefore)
    }

    /// The planning sweep's sample points: a lattice fixed to the MAP, not
    /// to the camera. The spacing is the smallest rung of a fixed ladder
    /// (each rung √2 apart) that keeps about `perSide` points across the
    /// view, and the points sit on whole multiples of it — so a small pan, a
    /// zoom within one rung, or the five-minute re-sweep samples the SAME
    /// places. A grid centred on the camera slid with every pan: each sweep
    /// read slightly different spots, caught different ZIPs, and risk areas
    /// came and went though the weather had not changed.
    static func lattice(
        centerLatitude: Double, centerLongitude: Double,
        spanLatitude: Double, spanLongitude: Double,
        perSide: Int
    ) -> [CLLocationCoordinate2D] {
        points(
            Array(
                flows_risk_area_lattice(
                    centerLatitude, centerLongitude, spanLatitude, spanLongitude, Int64(perSide))))
    }

    /// A circle as a ring of `points` vertices — the outline for risk with no
    /// ZIP under it (open water, Canada, Mexico). It was a padded hull,
    /// which for one point is a box: "squares over the lake".
    static func circleRing(
        center: CLLocationCoordinate2D, radiusMeters: Double,
        points: Int = 32
    ) -> [CLLocationCoordinate2D] {
        Self.points(
            Array(flows_risk_area_circle_ring(center.latitude, center.longitude, radiusMeters, Int64(points))))
    }

    /// Where an area's one icon stands: the shape's centroid when that lies
    /// inside it, else the middle of the widest stretch of the shape along
    /// the centroid's latitude — a crescent-shaped ZIP's centroid can sit in
    /// the next ZIP over, and its icon with it.
    static func iconAnchor(of ring: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        point(dense(ring).lent { Array(flows_risk_area_icon_anchor($0)) })
    }

    /// Shoelace (area-weighted) centroid — the middle of the SHAPE, not of
    /// its vertices; the vertex mean for a ring with no area.
    static func centroid(of ring: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        point(dense(ring).lent { Array(flows_risk_area_centroid($0)) })
    }

    /// Up to `limit` points spread inside a shape — its icon anchor first,
    /// then a grid over its bounding box kept to the points inside it. A
    /// warning's polygon is drawn by the ZIPs these points fall in.
    static func interiorSamples(
        of ring: [CLLocationCoordinate2D],
        limit: Int = 9
    ) -> [CLLocationCoordinate2D] {
        points(dense(ring).lent { Array(flows_risk_area_interior_samples($0, Int64(limit))) })
    }

    /// Even–odd point-in-polygon.
    static func contains(_ ring: [CLLocationCoordinate2D], _ p: CLLocationCoordinate2D) -> Bool {
        dense(ring).lent { flows_risk_area_contains($0, p.latitude, p.longitude) }
    }

    private static func dense(_ ring: [CLLocationCoordinate2D]) -> [Double] {
        var flat: [Double] = []
        flat.reserveCapacity(ring.count * 2)
        for c in ring {
            flat.append(c.latitude)
            flat.append(c.longitude)
        }
        return flat
    }

    private static func points(_ flat: [Double]) -> [CLLocationCoordinate2D] {
        stride(from: 0, to: flat.count - 1, by: 2).map {
            CLLocationCoordinate2D(latitude: flat[$0], longitude: flat[$0 + 1])
        }
    }

    /// One point; `(0, 0)` (an empty ring's answer) if the bridge sent none.
    private static func point(_ flat: [Double]) -> CLLocationCoordinate2D {
        flat.count == 2 ? CLLocationCoordinate2D(latitude: flat[0], longitude: flat[1]) : CLLocationCoordinate2D()
    }
}
