// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// The rules of the live corridor watch, in one place: how far ahead to
/// look, which check points that is, when each will be reached, what one
/// pass adds up to, and which of the route's own check points a pass
/// repaints. They sat inline in AppModel and WeatherAlertService, where no
/// test could see them.
enum CorridorWatchRules {
    /// How far AHEAD to watch scales with speed (about 30 minutes of travel:
    /// walking watches 5 km, highway driving up to 150 km), and the refresh
    /// tightens as speed rises. Speed in meters a second.
    static func window(speed: Double) -> (lookahead: Double, cadence: Double) {
        let lookahead = min(max(speed * 1800, 5_000), 150_000)
        let cadence: Double = speed > 20 ? 120 : (speed > 3 ? 180 : 300)
        return (lookahead, cadence)
    }

    /// The route's pace, for "when will the driver reach this check point".
    static func secondsPerMeter(eta: Double, distanceMeters: Double) -> Double {
        eta / max(distanceMeters, 1)
    }

    /// The check points one pass looks at.
    struct Slice: Equatable {
        /// First and last check point of the window. Meaningful only when
        /// `ranged`; otherwise the pass looks at every check point.
        let lo: Int
        let hi: Int
        let ranged: Bool
        /// Seconds from the VEHICLE to each check point of the pass, never
        /// below 0.
        let offsets: [Double]
    }

    /// Check point i sits about `i * spacing` meters along the route; the
    /// window runs from the vehicle (`along`) to `lookahead` past it.
    static func slice(
        count: Int, spacing: Double, along: Double, lookahead: Double, secondsPerMeter: Double
    ) -> Slice {
        // Clamp in Double first: Int(4.5e303) traps when lookahead is
        // .greatestFiniteMagnitude.
        let maxIdx = Double(count - 1)
        let lo = Int(min(max(along / spacing, 0), maxIdx))
        let hi = Int(min(max((along + lookahead) / spacing + 1, 0), maxIdx))
        let ranged = lo <= hi
        // Offsets are time-to-reach from the vehicle, not the window start:
        // measuring from the window's first check point overstated each by
        // up to a full lookahead, discounting alerts that expire in that
        // time as if the driver arrived far later than they will.
        let base = ranged ? Double(lo) * spacing : 0
        let n = ranged ? hi - lo + 1 : count
        let offsets = (0..<n).map {
            max(0, (base + Double($0) * spacing - along) * secondsPerMeter)
        }
        return Slice(lo: lo, hi: hi, ranged: ranged, offsets: offsets)
    }

    /// One pass, reduced to what the escalation decision needs.
    struct Reading: Equatable {
        /// The plain mean: the window's check points are evenly spaced, so
        /// this is like-for-like with the distance-weighted route band.
        let mean: Double
        /// The worst check point, and which one it is.
        let peak: Double
        let peakIndex: Int?
    }

    static func reading(_ risks: [Double]) -> Reading {
        let peak = risks.enumerated().max { $0.element < $1.element }
        return Reading(
            mean: risks.isEmpty ? 0 : risks.reduce(0, +) / Double(risks.count),
            peak: peak?.element ?? 0, peakIndex: peak?.offset)
    }

    /// A check point as the fold reads it.
    struct Mark {
        let coordinate: CLLocationCoordinate2D
        let risk: Double
        let worstEvent: String?
        let alertID: String?
    }

    /// A window check point belongs to the route check point within this far.
    static let matchMeters = 600.0
    /// A risk that moved less than this does not repaint the route.
    static let repaintMargin = 0.02

    /// Folds one pass back into the route's own check points. The answer has
    /// one entry per route check point: the window check point that repaints
    /// it (the last one, when several do), or nil when it stays as it is.
    static func fold(route: [Mark], window: [Mark]) -> [Int?] {
        var state = route
        var source = [Int?](repeating: nil, count: route.count)
        for (wi, w) in window.enumerated() {
            var bi = -1
            var bd = matchMeters
            for (i, s) in state.enumerated() {
                let d = POIRanking.meters(s.coordinate, w.coordinate)
                if d < bd {
                    bd = d
                    bi = i
                }
            }
            guard bi >= 0 else { continue }
            let old = state[bi]
            if abs(old.risk - w.risk) > repaintMargin || old.worstEvent != w.worstEvent
                || old.alertID != w.alertID
            {
                state[bi] = Mark(
                    coordinate: old.coordinate, risk: w.risk,
                    worstEvent: w.worstEvent, alertID: w.alertID)
                source[bi] = wi
            }
        }
        return source
    }

    /// The speed a route averages, for which kind of road it mostly is.
    static func averageMph(distanceMeters: Double, eta: Double) -> Double {
        eta > 0 ? (distanceMeters / 1609.344) / (eta / 3600) : 30
    }
}
