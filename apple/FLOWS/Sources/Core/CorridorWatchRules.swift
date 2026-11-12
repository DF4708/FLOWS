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

/// The rules of the live corridor watch, in one place: how far ahead to
/// look, which check points that is, when each will be reached, what one
/// pass adds up to, and which of the route's own check points a pass
/// repaints. They sat inline in AppModel and WeatherAlertService, where no
/// test could see them.
///
/// Computed in rust/flows-core (corridor_watch.rs) and called through
/// rust/flows-bridge; pinned bit for bit to the Swift this replaced by
/// rust/flows-bridge/tests/fixtures/swift_corridor_watch_oracle.tsv.
enum CorridorWatchRules {
    /// How far AHEAD to watch scales with speed (about 30 minutes of travel:
    /// walking watches 5 km, highway driving up to 150 km), and the refresh
    /// tightens as speed rises. Speed in meters a second.
    static func window(speed: Double) -> (lookahead: Double, cadence: Double) {
        let w = flows_corridor_window(speed)
        return (w.lookahead, w.cadence)
    }

    /// The route's pace, for "when will the driver reach this check point".
    static func secondsPerMeter(eta: Double, distanceMeters: Double) -> Double {
        flows_corridor_seconds_per_meter(eta, distanceMeters)
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
    ///
    /// A window that cannot be placed (a position that is not a number, a
    /// route with no check points: the Swift this replaced crashed) watches
    /// every check point. Offsets are time-to-reach from the vehicle, not
    /// the window start: measuring from the window's first check point
    /// overstated each by up to a full lookahead, discounting alerts that
    /// expire in that time as if the driver arrived far later than they will.
    static func slice(
        count: Int, spacing: Double, along: Double, lookahead: Double, secondsPerMeter: Double
    ) -> Slice {
        // The call gave no answer: every check point, each reached "now",
        // so no alert is discounted for ending before the driver arrives.
        let everything = Slice(
            lo: 0, hi: 0, ranged: false, offsets: Array(repeating: 0, count: max(count, 0)))
        let v = flows_corridor_slice(Int64(count), spacing, along, lookahead, secondsPerMeter)
        guard v.len() >= 3 else { return everything }
        let ranged = v[0] != 0
        guard v[1].isFinite, v[2].isFinite else { return everything }
        let (lo, hi) = (Int(v[1]), Int(v[2]))
        let n = v.len() - 3
        // The answer must fit the route it was asked about.
        guard n == (ranged ? hi - lo + 1 : count), !ranged || (lo >= 0 && lo <= hi && hi < count) else {
            return everything
        }
        return Slice(lo: lo, hi: hi, ranged: ranged, offsets: (0..<n).map { v[$0 + 3] })
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
        // An empty list never crosses.
        guard !risks.isEmpty else { return Reading(mean: 0, peak: 0, peakIndex: nil) }
        let r = risks.lent { flows_corridor_reading($0, Int64(risks.count)) }
        let index = r.peak_index >= 0 && r.peak_index < Double(risks.count) ? Int(r.peak_index) : nil
        return Reading(mean: r.mean, peak: r.peak, peakIndex: index)
    }

    /// A check point as the fold reads it.
    struct Mark {
        let coordinate: CLLocationCoordinate2D
        let risk: Double
        let worstEvent: String?
        let alertID: String?
    }

    /// A window check point belongs to the route check point within this far.
    static let matchMeters = flows_corridor_match_meters()
    /// A risk that moved less than this does not repaint the route.
    static let repaintMargin = flows_corridor_repaint_margin()

    /// Folds one pass back into the route's own check points. The answer has
    /// one entry per route check point: the window check point that repaints
    /// it (the last one, when several do), or nil when it stays as it is.
    static func fold(route: [Mark], window: [Mark]) -> [Int?] {
        let unchanged = [Int?](repeating: nil, count: route.count)
        // An empty list never crosses.
        guard !route.isEmpty, !window.isEmpty else { return unchanged }
        // Alerts cross as numbers: the same event and id, the same number.
        struct Alert: Hashable {
            let event: String?
            let id: String?
        }
        var numbers: [Alert: Int64] = [:]
        func columns(_ marks: [Mark]) -> (triples: [Double], codes: [Int64]) {
            var triples: [Double] = []
            triples.reserveCapacity(marks.count * 3)
            var codes: [Int64] = []
            codes.reserveCapacity(marks.count)
            for m in marks {
                triples.append(m.coordinate.latitude)
                triples.append(m.coordinate.longitude)
                triples.append(m.risk)
                let alert = Alert(event: m.worstEvent, id: m.alertID)
                let next = Int64(numbers.count)
                codes.append(numbers[alert, default: next])
                numbers[alert] = codes[codes.count - 1]
            }
            return (triples, codes)
        }
        let r = columns(route)
        let w = columns(window)
        let v = r.triples.lent { rt in
            r.codes.lent { rc in
                w.triples.lent { wt in
                    w.codes.lent { wc in
                        flows_corridor_fold(rt, rc, Int64(route.count), wt, wc, Int64(window.count))
                    }
                }
            }
        }
        // The call gave no answer: nothing is repainted this pass.
        guard v.len() == route.count else { return unchanged }
        return (0..<route.count).map {
            let source = v[$0]
            return source >= 0 && source < Double(window.count) ? Int(source) : nil
        }
    }

    /// The speed a route averages, for which kind of road it mostly is.
    static func averageMph(distanceMeters: Double, eta: Double) -> Double {
        flows_corridor_average_mph(distanceMeters, eta)
    }
}
