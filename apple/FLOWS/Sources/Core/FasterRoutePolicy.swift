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

/// When FLOWS takes a faster route on the driver's behalf. The owner
/// (2026-09-21): "Faster route navigation should automatically be approved
/// unless it increases the route risk level" — with Clear and Green counted
/// as one low level. The rules are Rust (`flows_core::travel_modes`,
/// `families::ahead_display_risk`); this is their facade.
enum FasterRoutePolicy {
    enum Verdict: Equatable {
        /// Taken without asking.
        case switchNow
        /// The faster road raises the risk level: the driver is asked.
        case riskier
        /// The risk can't be told: the driver is asked.
        case unknown
        /// No road saves enough time, or none keeps the driver's choices.
        case notFaster
    }

    /// The engine's off-route distance: farther than this from a road's line
    /// is off it.
    static let offRoadMeters: CLLocationDistance = 60

    /// The displayed risk of the part of `leg` still ahead of the vehicle,
    /// `alongMeters` into it; nil until the leg is scored, or when nothing is
    /// ahead. A faster road replaces the road ahead, not the miles driven —
    /// and a red check point just behind the vehicle is not risk ahead.
    static func aheadRisk(of leg: PlannedRoute, alongMeters: Double) -> Double? {
        guard leg.weatherScored, !leg.riskSamples.isEmpty, !leg.riskSegments.isEmpty
        else { return nil }
        let samples = leg.riskSamples.map(\.risk)
        let lengths = leg.riskSegments.map(\.lengthMeters)
        let answer = samples.withUnsafeBufferPointer { s in
            lengths.withUnsafeBufferPointer { l in
                flows_ahead_display_risk(s, l, alongMeters)
            }
        }
        return answer.isNaN ? nil : answer
    }

    /// Whether `candidate` keeps the driver's own choices: the No tolls and
    /// No highways filters, the leg's toll-free or local-roads plan, and — on
    /// a leg with no tolls — no toll road.
    static func keepsRoadChoice(_ candidate: PlannedRoute, leg: PlannedRoute,
                                filters: Set<RouteFilter>) -> Bool {
        flows_modes_keeps_road_choice(
            code(leg.planKind), leg.hasTolls, code(candidate.planKind), candidate.hasTolls,
            candidate.hasHighways, filters.contains(.noTolls), filters.contains(.noHighways))
    }

    /// Whether the candidate saves enough to be worth a switch: FLOWS's own
    /// "same time" tolerance (8% of the shorter trip, 2 to 15 minutes).
    static func savesEnough(currentSeconds: Double, candidateSeconds: Double) -> Bool {
        flows_modes_faster_saves_enough(
            currentSeconds, candidateSeconds,
            RouteService.etaTieTolerance(shorterETA: candidateSeconds))
    }

    /// Switch unless the candidate is Red or raises the level of the road
    /// ahead; anything that can't be told is asked, never switched. Both
    /// risks come from `aheadRisk` on roads scored the same way at the same
    /// moment (nil when a score is missing or incomplete). `limitsUnchecked`:
    /// something the driver filters on (a rig's bridges, weights and grades,
    /// flood zones) can't be checked on the new road before it starts.
    static func riskVerdict(candidateRisk: Double?, aheadRisk: Double?,
                            limitsUnchecked: Bool) -> Verdict {
        switch flows_modes_faster_risk_verdict(
            candidateRisk != nil, candidateRisk ?? .nan,
            aheadRisk != nil, aheadRisk ?? .nan, limitsUnchecked) {
        case 0: return .switchNow
        case 1: return .riskier
        default: return .unknown
        }
    }

    /// A route's line as coordinates.
    static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let n = polyline.pointCount
        guard n > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: n)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
        return coords
    }

    /// A stretch of a candidate off the current road: meters along the
    /// candidate from where it leaves to where it comes back (infinite when
    /// it never does).
    typealias Span = (from: Double, to: Double)

    /// The stretches of `candidate` off `road`'s line (Rust `off_line_spans`,
    /// within 10 m point to segment, so an exit ramp beside the mainline
    /// counts as off it). Empty when it never leaves — it is the road itself
    /// — or when either line has too little to compare.
    static func offLineSpans(candidate: [CLLocationCoordinate2D],
                             road: [CLLocationCoordinate2D]) -> [Span] {
        guard candidate.count > 1, !road.isEmpty else { return [] }
        let flat = candidate.map(\.latitude).withUnsafeBufferPointer { cla in
            candidate.map(\.longitude).withUnsafeBufferPointer { clo in
                road.map(\.latitude).withUnsafeBufferPointer { rla in
                    road.map(\.longitude).withUnsafeBufferPointer { rlo in
                        Array(flows_modes_off_line_spans(cla, clo, rla, rlo))
                    }
                }
            }
        }
        return stride(from: 0, to: flat.count - 1, by: 2).map { (from: flat[$0], to: flat[$0 + 1]) }
    }

    /// Where `candidate` leaves `road`: meters along the candidate to its
    /// last vertex on the road's line. nil when it never leaves.
    static func divergeAlong(candidate: [CLLocationCoordinate2D],
                             road: [CLLocationCoordinate2D]) -> CLLocationDistance? {
        offLineSpans(candidate: candidate, road: road).first?.from
    }

    /// The check-point spacing to weigh a candidate at, so every stretch off
    /// the current road gets check points of its own (Rust
    /// `detour_check_spacing`: a third of the shortest stretch, 2 to 40 km,
    /// at most 28 stretches, so each check point gets a forecast). The usual
    /// 40 km when nothing differs.
    static func checkSpacing(spans: [Span], candidateMeters: Double) -> CLLocationDistance {
        guard !spans.isEmpty else { return corridorCheckMeters }
        let flat = spans.flatMap { [$0.from, $0.to] }
        return flat.withUnsafeBufferPointer { flows_modes_detour_check_spacing($0, candidateMeters) }
    }

    /// The spacing a road is scored at for the map, the watch and the trip.
    static let corridorCheckMeters: CLLocationDistance = 40_000

    /// Whether every stretch off the current road has a check point inside
    /// it on `scored` (the one at the car doesn't count). When one has none,
    /// the part that makes the roads differ was never looked at.
    static func detourChecked(spans: [Span], on scored: PlannedRoute) -> Bool {
        guard !spans.isEmpty else { return true }
        let alongs = checkAlongs(of: scored)
        guard alongs.count > 1 else { return false }
        let flat = spans.flatMap { [$0.from, $0.to] }
        return flat.withUnsafeBufferPointer { s in
            alongs.withUnsafeBufferPointer { flows_modes_spans_checked(s, $0) }
        }
    }

    /// Meters along a scored road to each of its check points: 0 at the
    /// first, then each stretch's length added.
    static func checkAlongs(of scored: PlannedRoute) -> [Double] {
        guard !scored.riskSamples.isEmpty else { return [] }
        var alongs = [0.0]
        for segment in scored.riskSegments { alongs.append(alongs[alongs.count - 1] + segment.lengthMeters) }
        return alongs
    }

    /// Whether a car at `position` can still take `candidate`: on its line
    /// (within the engine's 60 m), and short of where it leaves the current
    /// road by a margin (ten seconds at `speedMps`, at least 200 m). The
    /// candidate was planned from where the car was before it was scored; if
    /// the car has since passed the turn-off, switching would be followed at
    /// once by a replan back.
    static func canStillTake(candidate: [CLLocationCoordinate2D], divergeAlong: CLLocationDistance?,
                             position: CLLocationCoordinate2D, speedMps: Double) -> Bool {
        guard !candidate.isEmpty else { return false }
        let hit = candidate.map(\.latitude).withUnsafeBufferPointer { la in
            candidate.map(\.longitude).withUnsafeBufferPointer { lo in
                Array(flows_modes_nearest_on_line(la, lo, position.latitude, position.longitude))
            }
        }
        guard hit.count == 2, hit[1] <= offRoadMeters else { return false }
        guard let diverge = divergeAlong else { return true }
        let margin = max(max(speedMps, 0) * 10, 200)
        return hit[0] + margin < diverge
    }

    /// The filters that keep a vehicle out of harm's way: a rig's bridges,
    /// weights and grades, flood zones and crosswinds. Broken, they outrank
    /// the driver's road choices.
    static let safetyFilters: Set<RouteFilter> =
        [.lowBridges, .bridgeWeight, .mountainGrades, .noFloodRisk, .noHighWinds]

    /// The safety filters about the rig physically fitting the road — a
    /// bridge it can't pass under or a weight sign it's over — rather than
    /// the weather on it: a road like that is no way out of anything.
    /// Grades aren't here: a rig can climb a 6% grade, slowly, and a steep
    /// Clear road is a better escape than a gentle Red one.
    static let rigFilters: Set<RouteFilter> = [.lowBridges, .bridgeWeight]

    /// The risk level a reroute away from risk escapes by: Red above Yellow
    /// above the rest. The owner counts Clear and Green as one low level
    /// (2026-09-21), as the faster-route switch does (Rust `switch_level`).
    static func rerouteLevel(_ risk: Double) -> Int {
        switch FlowsCore.riskBand(score: risk) {
        case .red: return 2
        case .yellow: return 1
        case .green, .clear: return 0
        }
    }

    /// The road to drive when FLOWS swaps in a leg the driver didn't pick
    /// card by card: a reroute, the way to an added stop, the way on from
    /// it. These used to take the router's first car route, dropping the
    /// driver's road choices. Wins: the fewest broken safety filters, then
    /// keeping the road choices (`keepsRoadChoice`), then the first in the
    /// router's order. A filter that can't be checked yet (a road not
    /// scored, its attributes not loaded) passes, as it does on the route
    /// cards. nil when there is no candidate.
    ///
    /// `calmest`: a reroute away from risk. Only the rig's own bridges and
    /// weight signs come before the risk level (a road the rig can't pass is
    /// no way out); then the other safety filters (grades, wind, flood), the
    /// road choices, and the lowest risk, ties to the sooner arrival. A toll,
    /// a crosswind or a grade filter must never hold the driver on a riskier
    /// road than one that is there to take.
    static func swapPick(_ candidates: [PlannedRoute], leg: PlannedRoute,
                         filters: Set<RouteFilter>, limits: FilterLimits,
                         calmest: Bool) -> PlannedRoute? {
        let safety = filters.intersection(safetyFilters)
        let rig = safety.intersection(rigFilters)
        func broken(_ set: Set<RouteFilter>, _ c: PlannedRoute) -> Int {
            set.filter { !$0.passes(c, limits: limits) }.count
        }
        let ranks: [[Int]] = candidates.map { c in
            let choice = keepsRoadChoice(c, leg: leg, filters: filters) ? 0 : 1
            guard calmest else { return [broken(safety, c), choice] }
            return [broken(rig, c), rerouteLevel(c.weatherRisk),
                    broken(safety.subtracting(rig), c), choice]
        }
        guard let best = ranks.min(by: { $0.lexicographicallyPrecedes($1) }) else { return nil }
        let pool = candidates.indices.filter { ranks[$0] == best }.map { candidates[$0] }
        guard calmest else { return pool.first }
        return pool.min { ($0.weatherRisk, $0.eta) < ($1.weatherRisk, $1.eta) }
    }

    private static func code(_ kind: RoutePlanKind) -> UInt8 {
        switch kind {
        case .standard: return 0
        case .avoidHighways: return 1
        case .tollFree: return 2
        }
    }
}
