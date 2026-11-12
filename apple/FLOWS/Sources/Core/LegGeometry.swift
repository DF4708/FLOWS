// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// The road of one leg as numbers: its points, the meters to each, where
/// each step ends, and the rules that read them. Which point a fix is at,
/// how far the turn and the end are, the point a way ahead, where a path is
/// cut in half or into check points and where the steep signs stand. They
/// sat inside NavigationEngine and RouteService, where no test could reach
/// the driving ones.
struct LegGeometry: Sendable {
    /// Every point of the leg, step after step.
    let points: [CLLocationCoordinate2D]
    /// Meters from the start to `points[i]`.
    let cumulative: [CLLocationDistance]
    /// The index into `points` where each step ends.
    let stepEnd: [Int]

    /// How far the window looks behind and ahead of the last matched point,
    /// and how far off the window's best may be before the whole leg is read.
    static let windowBehind = 12
    static let windowAhead = 80
    static let windowLostMeters = 250.0

    /// The leg from its steps' points. A step with no points is left out
    /// (the caller leaves its words out too).
    init(steps: [[CLLocationCoordinate2D]]) {
        var points: [CLLocationCoordinate2D] = []
        var cumulative: [CLLocationDistance] = []
        var stepEnd: [Int] = []
        var running: CLLocationDistance = 0
        var prev: CLLocationCoordinate2D?
        for step in steps where !step.isEmpty {
            for c in step {
                // Allocation-free hop distance: this walks every vertex of
                // the whole route at leg start.
                if let p = prev { running += POIRanking.meters(p, c) }
                points.append(c)
                cumulative.append(running)
                prev = c
            }
            stepEnd.append(points.count - 1)
        }
        self.points = points
        self.cumulative = cumulative
        self.stepEnd = stepEnd
    }

    /// The point of the leg nearest a fix and how far off it is: read in a
    /// window around the last match, and over the whole leg only when the
    /// window lost the vehicle (a rejoin, a jump). nil on a leg with no
    /// points.
    func match(last: Int, fix: CLLocationCoordinate2D) -> (index: Int, meters: CLLocationDistance)? {
        guard !points.isEmpty else { return nil }
        func scan(_ range: Range<Int>) -> (idx: Int, dist: CLLocationDistance) {
            var bestI = range.lowerBound
            var bestD = CLLocationDistance.greatestFiniteMagnitude
            for i in range {
                let d = POIRanking.meters(points[i], fix)
                if d < bestD {
                    bestD = d
                    bestI = i
                }
            }
            return (bestI, bestD)
        }
        // Clamp lo so lo <= hi always holds: defense in depth against a
        // stale index outliving a route swap (forming lo..<hi with lo > hi
        // traps). The reroute path resets the index, this guards the rest.
        let last = max(last, 0)
        let hi = min(last + Self.windowAhead, points.count)
        let lo = min(max(last - Self.windowBehind, 0), hi)
        var (nearest, nearestDist) = scan(lo..<hi)
        if nearestDist > Self.windowLostMeters {  // window lost the vehicle: one full rescan
            (nearest, nearestDist) = scan(0..<points.count)
        }
        return (nearest, nearestDist)
    }

    /// Where the drive stands at a matched point.
    struct Progress: Equatable {
        /// The step now being driven: moved on past every step whose end
        /// the point has reached, never past the last.
        var step: Int
        var toManeuver: CLLocationDistance
        /// Meters travelled along the leg.
        var along: CLLocationDistance
        var remaining: CLLocationDistance
        /// The share of the leg still ahead, 0 on a leg with no length.
        var fractionLeft: Double
        /// The length of the step being driven, from the turn behind to the
        /// one ahead: what the camera's zoom reads.
        var stepSpacing: CLLocationDistance
    }

    /// nil on a leg with no points, or for a point the leg does not hold.
    func progress(nearest: Int, step: Int) -> Progress? {
        guard !stepEnd.isEmpty, cumulative.indices.contains(nearest), let total = cumulative.last
        else { return nil }
        var current = max(step, 0)
        // Advance instruction step when we pass its end point.
        while current < stepEnd.count - 1 && nearest >= stepEnd[current] {
            current += 1
        }
        let stepIdx = min(current, stepEnd.count - 1)
        let maneuverIdx = stepEnd[stepIdx]
        let toManeuver = max(cumulative[maneuverIdx] - cumulative[nearest], 0)
        let remaining = max(total - cumulative[nearest], 0)
        let stepStart = stepIdx == 0 ? 0 : stepEnd[stepIdx - 1]
        return Progress(
            step: current,
            toManeuver: toManeuver,
            along: cumulative[nearest],
            remaining: remaining,
            fractionLeft: total > 0 ? remaining / total : 0,
            stepSpacing: cumulative[maneuverIdx] - cumulative[stepStart])
    }

    /// The index of the first point `meters` or more ahead of a matched
    /// point along the leg, the last point when the leg ends sooner; nil on
    /// a leg with no points or for a point it does not hold.
    func ahead(from index: Int, meters: CLLocationDistance) -> Int? {
        guard !points.isEmpty, cumulative.indices.contains(index) else { return nil }
        let target = cumulative[index] + meters
        for i in index..<cumulative.count where cumulative[i] >= target {
            return i
        }
        return points.count - 1
    }

    /// Seconds to wait before asking for a new road again after `failures`
    /// searches in a row found none: 15, 30, 60, then 120 at most.
    static func rerouteWait(failures: Int) -> TimeInterval {
        min(15 * pow(2, Double(failures - 1)), 120)
    }

    // MARK: a path with no steps

    /// The index of the point a steep-grade sign stands at, for each stretch
    /// of the profile at 6% or steeper (the first 12): the first point at or
    /// past the stretch's midpoint, never the first point of the path.
    static func steepMarkerIndices(
        _ coords: [CLLocationCoordinate2D], profile: [GradeSegment]
    ) -> [(index: Int, gradePercent: Double)] {
        let n = coords.count
        guard n > 1, !profile.isEmpty else { return [] }
        var prefix = [Double](repeating: 0, count: n)
        for i in 1..<n { prefix[i] = prefix[i - 1] + POIRanking.meters(coords[i - 1], coords[i]) }

        // First vertex index whose cumulative distance reaches `target`.
        func firstIndex(atOrAbove target: Double) -> Int {
            var lo = 0
            var hi = n
            while lo < hi {
                let mid = (lo + hi) / 2
                if prefix[mid] >= target { hi = mid } else { lo = mid + 1 }
            }
            return lo
        }

        var markers: [(index: Int, gradePercent: Double)] = []
        for seg in profile where abs(seg.gradePercent) >= 6 {
            if markers.count >= 12 { break }
            let target = (seg.startMile + seg.endMile) / 2 * 1609.344
            let i = min(max(firstIndex(atOrAbove: target), 1), n - 1)
            markers.append((i, seg.gradePercent))
        }
        return markers
    }

    /// Where a path is cut at its own halfway point by length.
    enum Cut: Equatable {
        /// Between point `before - 1` and point `before`, at the midpoint
        /// given: the first half is the points below `before` and then the
        /// midpoint, the second is the midpoint and then the points from
        /// `before` on.
        case between(before: Int, midLatitude: Double, midLongitude: Double)
        /// At a point both halves carry (a path standing still).
        case at(Int)
        /// A path of fewer than two points: both halves are the path.
        case whole
    }

    static func cut(_ coords: [CLLocationCoordinate2D]) -> Cut {
        guard coords.count >= 2 else { return .whole }
        var total = 0.0
        for i in 1..<coords.count { total += POIRanking.meters(coords[i - 1], coords[i]) }
        let half = total / 2
        var walked = 0.0
        for i in 1..<coords.count {
            let hop = POIRanking.meters(coords[i - 1], coords[i])
            if walked + hop >= half {
                let t = hop > 0 ? (half - walked) / hop : 0
                return .between(
                    before: i,
                    midLatitude: coords[i - 1].latitude
                        + (coords[i].latitude - coords[i - 1].latitude) * t,
                    midLongitude: coords[i - 1].longitude
                        + (coords[i].longitude - coords[i - 1].longitude) * t)
            }
            walked += hop
        }
        // Every hop was zero length (a path standing still): halve the points.
        return .at(coords.count / 2)
    }

    /// The indices where a path is cut into check points about
    /// `everyMeters` apart: each point where the meters since the last cut
    /// reach `everyMeters`. The path's first and last points are check
    /// points too and are not in the list.
    static func checkPointIndices(
        _ coords: [CLLocationCoordinate2D], everyMeters: CLLocationDistance
    ) -> [Int] {
        var cuts: [Int] = []
        var sinceLast: CLLocationDistance = 0
        for i in coords.indices.dropFirst() {
            // POIRanking.meters, not CLLocation.distance: this loop walks
            // every vertex of the polyline (~30k on a long route) and is run
            // several times per route. The equirectangular error (<0.1% at
            // vertex hop lengths) only shifts a sample boundary against the
            // 40 km threshold by at most one vertex.
            sinceLast += POIRanking.meters(coords[i - 1], coords[i])
            if sinceLast >= everyMeters {
                cuts.append(i)
                sinceLast = 0
            }
        }
        return cuts
    }
}
