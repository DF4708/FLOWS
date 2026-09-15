// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// The route's grade TABLE: per-segment grades at known mile positions, so
/// steepness is a localized, inspectable quantity — not one smoothed max.
/// Planning fills it from the coarse+refined elevation passes; while
/// driving, the lookahead sampler appends fine (~300 m) segments so even
/// neighborhood hills register in the table.
struct GradeSegment: Equatable {
    let startMile: Double
    let endMile: Double
    /// Signed percent (positive = climb in travel direction).
    let gradePercent: Double

    /// The grade as an angle for display, computed in Rust.
    var gradeDegrees: Double { flows_vehicle_policy_grade_degrees(gradePercent) }
}

/// The table's construction, its steepest rows and the next-steep search are
/// computed in rust/flows-core (vehicle_policy.rs) and called through
/// rust/flows-bridge — segments cross as flat (start, end, grade) triples;
/// a missing elevation crosses as a value plus a presence byte. Pinned bit
/// for bit to the Swift this replaced by
/// rust/flows-bridge/tests/fixtures/swift_vehicle_policy_oracle.tsv.
enum GradeProfile {
    /// Flat triples to segments.
    private static func segments(fromFlat flat: RustVec<Double>) -> [GradeSegment] {
        var out: [GradeSegment] = []
        var i = 0
        while i + 2 < flat.len() {
            out.append(GradeSegment(startMile: flat[i], endMile: flat[i + 1], gradePercent: flat[i + 2]))
            i += 3
        }
        return out
    }

    private static func flat(_ segments: [GradeSegment]) -> [Double] {
        segments.flatMap { [$0.startMile, $0.endMile, $0.gradePercent] }
    }


    /// Segment table from an elevation profile: elevations[i] at
    /// startMile + i·spacing. Missing samples (nil — a failed EPQS call)
    /// break the chain rather than fabricating a grade across the gap.
    static func segments(
        elevations: [Double?], spacingMeters: Double, startMile: Double = 0
    ) -> [GradeSegment] {
        // Fewer than two samples is no table (the Swift's own answer, and an
        // empty buffer never crosses).
        guard elevations.count > 1 else { return [] }
        let values = elevations.map { $0 ?? 0 }
        let present: [UInt8] = elevations.map { $0 == nil ? 0 : 1 }
        let flat = values.withUnsafeBufferPointer { v in
            present.withUnsafeBufferPointer { p in
                flows_vehicle_policy_grade_segments(v, p, spacingMeters, startMile)
            }
        }
        return segments(fromFlat: flat)
    }

    /// Steepest segments by |grade|, worst first — the route card's table.
    static func steepest(_ segments: [GradeSegment], top: Int = 3) -> [GradeSegment] {
        guard !segments.isEmpty else { return [] }
        let triples = flat(segments)
        return Self.segments(fromFlat: triples.withUnsafeBufferPointer { flows_vehicle_policy_grade_steepest($0, Int64(top)) })
    }

    /// The next steep CLIMB ahead of `mile` within `lookaheadMiles` — the
    /// "6.5% grade in 2 mi" HUD chip (descents matter for brakes too, so
    /// magnitude decides; the sign is reported).
    static func nextSteep(
        after mile: Double, in segments: [GradeSegment],
        thresholdPercent: Double = flows_vehicle_policy_grade_steep_threshold_percent(),
        lookaheadMiles: Double = flows_vehicle_policy_grade_lookahead_miles()
    ) -> GradeSegment? {
        guard !segments.isEmpty else { return nil }
        let triples = flat(segments)
        let i = triples.withUnsafeBufferPointer {
            flows_vehicle_policy_grade_next_steep_index(mile, $0, thresholdPercent, lookaheadMiles)
        }
        guard i >= 0, Int(i) < segments.count else { return nil }
        return segments[Int(i)]
    }
}
