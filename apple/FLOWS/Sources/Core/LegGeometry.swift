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

/// The road of one leg as numbers: its points, the meters to each, where
/// each step ends, and the rules that read them. Which point a fix is at,
/// how far the turn and the end are, the point a way ahead, where a path is
/// cut in half or into check points and where the steep signs stand.
///
/// The rules run in Rust (`flows_core::leg_geometry`); this is the Swift
/// face of them. A leg is built once in Rust and held by handle, which is
/// read-only after it is built and so safe to hand between tasks
/// (`RustShared`). An answer Rust cannot give is never guessed at: the
/// drive stands where it was, or the path is cut the plain way.
struct LegGeometry: Sendable {
    /// Every point of the leg, step after step.
    let points: [CLLocationCoordinate2D]
    /// Meters from the start to `points[i]`.
    let cumulative: [CLLocationDistance]
    /// The index into `points` where each step ends.
    let stepEnd: [Int]
    private let shared: RustShared<FlowsLegGeometry>

    /// The leg from its steps' points. A step with no points is left out
    /// (the caller leaves its words out too).
    init(steps: [[CLLocationCoordinate2D]]) {
        let held = steps.filter { !$0.isEmpty }
        let points = held.flatMap { $0 }
        guard !points.isEmpty else {
            self.points = []
            cumulative = []
            stepEnd = []
            shared = RustShared(flows_leg_geometry_empty())
            return
        }
        let lats = points.map(\.latitude)
        let lons = points.map(\.longitude)
        let counts = held.map { Int64($0.count) }
        let made = lats.lent { la in
            lons.lent { lo in
                counts.lent { c in flows_leg_geometry(la, lo, c) }
            }
        }
        let cumulative = Array(made.cumulative())
        let stepEnd = Array(made.step_ends()).map { Int($0) }
        // A leg Rust could not build, or one that does not fit the points,
        // is a leg with no road: nothing is matched against it.
        guard cumulative.count == points.count, stepEnd.count == held.count,
            stepEnd.allSatisfy({ points.indices.contains($0) })
        else {
            self.points = []
            self.cumulative = []
            self.stepEnd = []
            shared = RustShared(flows_leg_geometry_empty())
            return
        }
        self.points = points
        self.cumulative = cumulative
        self.stepEnd = stepEnd
        shared = RustShared(made)
    }

    /// The point of the leg nearest a fix and how far off it is: read in a
    /// window around the last match, and over the whole leg only when the
    /// window lost the vehicle (a rejoin, a jump). nil on a leg with no
    /// points.
    func match(last: Int, fix: CLLocationCoordinate2D) -> (index: Int, meters: CLLocationDistance)? {
        guard !points.isEmpty else { return nil }
        let hit = shared.handle.match_fix(Int64(last), fix.latitude, fix.longitude)
        guard hit.count == 2, let index = Int(exactly: hit[0]), points.indices.contains(index)
        else { return nil }
        return (index, hit[1])
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
        guard !stepEnd.isEmpty, cumulative.indices.contains(nearest) else { return nil }
        let p = shared.handle.progress(Int64(nearest), Int64(step))
        guard p.count == 6, let current = Int(exactly: p[0]), current >= 0 else { return nil }
        return Progress(
            step: current, toManeuver: p[1], along: p[2], remaining: p[3], fractionLeft: p[4],
            stepSpacing: p[5])
    }

    /// The index of the first point `meters` or more ahead of a matched
    /// point along the leg, the last point when the leg ends sooner; nil on
    /// a leg with no points or for a point it does not hold.
    func ahead(from index: Int, meters: CLLocationDistance) -> Int? {
        guard !points.isEmpty, cumulative.indices.contains(index) else { return nil }
        let found = Int(shared.handle.ahead(Int64(index), meters))
        return points.indices.contains(found) ? found : nil
    }

    /// Seconds to wait before asking for a new road again after `failures`
    /// searches in a row found none: 15, 30, 60, then 120 at most.
    static func rerouteWait(failures: Int) -> TimeInterval {
        flows_leg_reroute_wait(Int64(failures))
    }

    // MARK: a path with no steps

    /// A path as the two columns Rust reads.
    private static func columns(_ coords: [CLLocationCoordinate2D]) -> (lats: [Double], lons: [Double]) {
        (coords.map(\.latitude), coords.map(\.longitude))
    }

    /// The index of the point a steep-grade sign stands at, for each stretch
    /// of the profile at 6% or steeper (the first 12): the first point at or
    /// past the stretch's midpoint, never the first point of the path.
    static func steepMarkerIndices(
        _ coords: [CLLocationCoordinate2D], profile: [GradeSegment]
    ) -> [(index: Int, gradePercent: Double)] {
        guard coords.count > 1, !profile.isEmpty else { return [] }
        let (lats, lons) = columns(coords)
        let starts = profile.map(\.startMile)
        let ends = profile.map(\.endMile)
        let grades = profile.map(\.gradePercent)
        let flat = lats.lent { la in
            lons.lent { lo in
                starts.lent { s in
                    ends.lent { e in
                        grades.lent { g in Array(flows_leg_steep_markers(la, lo, s, e, g)) }
                    }
                }
            }
        }
        guard flat.count.isMultiple(of: 2) else { return [] }
        var markers: [(index: Int, gradePercent: Double)] = []
        for at in stride(from: 0, to: flat.count, by: 2) {
            guard let index = Int(exactly: flat[at]), coords.indices.contains(index) else { return [] }
            markers.append((index, flat[at + 1]))
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
        /// At a point both halves carry (a path whose meters are not
        /// numbers).
        case at(Int)
        /// A path of fewer than two points: both halves are the path.
        case whole
    }

    static func cut(_ coords: [CLLocationCoordinate2D]) -> Cut {
        guard coords.count >= 2 else { return .whole }
        let (lats, lons) = columns(coords)
        let answer = lats.lent { la in lons.lent { lo in Array(flows_leg_cut(la, lo)) } }
        // An answer Rust could not give halves the points: both halves
        // still cover the whole path.
        let plain = Cut.at(coords.count / 2)
        guard answer.count == 4, let index = Int(exactly: answer[1]) else { return plain }
        switch answer[0] {
        case 2 where index >= 1 && index < coords.count:
            return .between(before: index, midLatitude: answer[2], midLongitude: answer[3])
        case 1 where coords.indices.contains(index):
            return .at(index)
        default:
            return plain
        }
    }

    /// The most pieces the plain cut makes when Rust cannot answer.
    private static let plainPieces = 64

    /// The indices where a path is cut into check points about
    /// `everyMeters` apart: each point where the meters since the last cut
    /// reach `everyMeters`. The path's first point is a check point too
    /// and is not in the list; the last is in it only when the meters
    /// reach `everyMeters` there.
    static func checkPointIndices(
        _ coords: [CLLocationCoordinate2D], everyMeters: CLLocationDistance
    ) -> [Int] {
        guard coords.count >= 2 else { return [] }
        let (lats, lons) = columns(coords)
        let answer = lats.lent { la in
            lons.lent { lo in Array(flows_leg_check_points(la, lo, everyMeters)) }
        }
        var cuts: [Int] = []
        var good = answer.first == 1
        var floor = 0
        for value in answer.dropFirst() where good {
            // Each cut is a later point than the one before.
            if let index = Int(exactly: value), index > floor, index < coords.count {
                cuts.append(index)
                floor = index
            } else {
                good = false
            }
        }
        if good { return cuts }
        // An answer Rust could not give must not leave a long road with no
        // check points: cut it evenly by its points instead.
        let step = max(1, coords.count / plainPieces)
        return Array(stride(from: step, to: coords.count - 1, by: step))
    }
}
