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

    var lengthMiles: Double { endMile - startMile }
    var gradeDegrees: Double { atan(gradePercent / 100) * 180 / .pi }
}

enum GradeProfile {

    /// Segment table from an elevation profile: elevations[i] at
    /// startMile + i·spacing. Missing samples (nil — a failed EPQS call)
    /// break the chain rather than fabricating a grade across the gap.
    static func segments(
        elevations: [Double?], spacingMeters: Double, startMile: Double = 0
    ) -> [GradeSegment] {
        guard spacingMeters > 0, elevations.count > 1 else { return [] }
        let mileSpacing = spacingMeters / 1609.344
        var out: [GradeSegment] = []
        for i in 1..<elevations.count {
            guard let a = elevations[i - 1], let b = elevations[i] else { continue }
            out.append(GradeSegment(
                startMile: startMile + Double(i - 1) * mileSpacing,
                endMile: startMile + Double(i) * mileSpacing,
                gradePercent: (b - a) / spacingMeters * 100))
        }
        return out
    }

    /// Steepest segments by |grade|, worst first — the route card's table.
    static func steepest(_ segments: [GradeSegment], top: Int = 3) -> [GradeSegment] {
        Array(segments.sorted { abs($0.gradePercent) > abs($1.gradePercent) }.prefix(top))
    }

    /// The next steep CLIMB ahead of `mile` within `lookaheadMiles` — the
    /// "6.5% grade in 2 mi" HUD chip (descents matter for brakes too, so
    /// magnitude decides; the sign is reported).
    static func nextSteep(
        after mile: Double, in segments: [GradeSegment],
        thresholdPercent: Double = 6, lookaheadMiles: Double = 8
    ) -> GradeSegment? {
        segments
            .filter { $0.endMile > mile && $0.startMile < mile + lookaheadMiles
                && abs($0.gradePercent) >= thresholdPercent }
            // Earliest ahead; on a tie (an overlapping coarse+fine segment at the
            // same start) prefer the STEEPER, so the chip reports the real grade,
            // not a distance-averaged coarse one — and the pick is deterministic.
            .min { a, b in
                a.startMile != b.startMile
                    ? a.startMile < b.startMile
                    : abs(a.gradePercent) > abs(b.gradePercent)
            }
    }
}
