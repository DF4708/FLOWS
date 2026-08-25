// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import MapKit
import XCTest

/// The planning-burst path: the gate's elevated lane for user-initiated
/// route scoring, the geocode-time straight-line prefetch, and the
/// progressive (provisional) corridor view the cards show while cells land.
/// All pure or locally-instantiable — no network.
final class PlanningBurstTests: XCTestCase {

    // MARK: RequestGate burst lane

    /// Concurrency tracker shared by the gate tests.
    private actor Peak {
        var cur = 0
        var hi = 0
        func enter() { cur += 1; hi = Swift.max(hi, cur) }
        func leave() { cur -= 1 }
        func peak() -> Int { hi }
        func reset() { cur = 0; hi = 0 }
    }

    /// Push `count` holds through the gate and report the peak concurrency.
    private func drive(_ gate: RequestGate, count: Int, peak: Peak) async -> Int {
        await peak.reset()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask {
                    try? await gate.withPermit {
                        await peak.enter()
                        try? await Task.sleep(for: .milliseconds(25))
                        await peak.leave()
                    }
                }
            }
        }
        return await peak.peak()
    }

    /// The burst lane raises the effective ceiling while open and the pool
    /// shrinks back once it closes — the ceiling is a hard cap in BOTH modes.
    func testPlanningBurstRaisesAndRestoresCeiling() async {
        let gate = RequestGate(baseCeiling: { 2 }, burstCeiling: { 5 })
        let peak = Peak()

        let atRest = await drive(gate, count: 12, peak: peak)
        XCTAssertGreaterThan(atRest, 0)
        XCTAssertLessThanOrEqual(atRest, 2)

        await gate.beginPlanningBurst()
        let bursting = await drive(gate, count: 12, peak: peak)
        XCTAssertGreaterThan(bursting, 2)          // proof the lane opened
        XCTAssertLessThanOrEqual(bursting, 5)      // …and stayed capped
        await gate.endPlanningBurst()

        let after = await drive(gate, count: 12, peak: peak)
        XCTAssertLessThanOrEqual(after, 2)
    }

    /// Bursts are refcounted: the ceiling stays up until the LAST one ends
    /// (concurrent route scorings each open their own).
    func testPlanningBurstRefcounts() async {
        let gate = RequestGate(baseCeiling: { 2 }, burstCeiling: { 5 })
        let peak = Peak()
        await gate.beginPlanningBurst()
        await gate.beginPlanningBurst()
        await gate.endPlanningBurst()
        let stillBursting = await drive(gate, count: 12, peak: peak)
        XCTAssertGreaterThan(stillBursting, 2)
        await gate.endPlanningBurst()
        let closed = await drive(gate, count: 12, peak: peak)
        XCTAssertLessThanOrEqual(closed, 2)
    }

    /// A leaked burst (begin with no end — a cancelled hydration in the worst
    /// spot) self-heals: past the safety window the ceiling is background
    /// again even though the refcount never hit zero.
    func testPlanningBurstSafetyWindowExpires() async {
        let gate = RequestGate(baseCeiling: { 2 }, burstCeiling: { 6 },
                               burstSafetyWindow: 0.05)
        let peak = Peak()
        await gate.beginPlanningBurst()
        try? await Task.sleep(for: .milliseconds(150))
        let after = await drive(gate, count: 10, peak: peak)
        XCTAssertLessThanOrEqual(after, 2)
    }

    /// Parked waiters are admitted the moment a burst opens — the queued
    /// fetches of the plan that triggered the burst must not trickle out at
    /// the background pace.
    func testBurstAdmitsParkedWaiters() async {
        let gate = RequestGate(baseCeiling: { 1 }, burstCeiling: { 4 })
        let peak = Peak()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? await gate.withPermit {
                        await peak.enter()
                        try? await Task.sleep(for: .milliseconds(40))
                        await peak.leave()
                    }
                }
            }
            group.addTask {
                // Let the 8 holds queue at ceiling 1, then open the lane.
                try? await Task.sleep(for: .milliseconds(10))
                await gate.beginPlanningBurst()
            }
        }
        await gate.endPlanningBurst()
        let hi = await peak.peak()
        XCTAssertGreaterThan(hi, 1)          // waiters actually joined mid-flight
        XCTAssertLessThanOrEqual(hi, 4)
    }

    // MARK: straight-line prefetch cells

    /// Short corridor: the line yields one representative point per 0.25°
    /// cell, covering both endpoints, within the politeness cap.
    func testPrefetchCellsShortCorridor() {
        let madison = CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40)
        let milwaukee = CLLocationCoordinate2D(latitude: 43.04, longitude: -87.91)
        let cells = WeatherAlertService.prefetchCells(from: madison, to: milwaukee)
        XCTAssertFalse(cells.isEmpty)
        XCTAssertLessThanOrEqual(cells.count, 16)
        let keys = cells.map(WeatherAlertService.cellKey)
        XCTAssertEqual(Set(keys).count, keys.count)   // one point per cell
        XCTAssertTrue(keys.contains(WeatherAlertService.cellKey(madison)))
        XCTAssertTrue(keys.contains(WeatherAlertService.cellKey(milwaukee)))
    }

    /// Long corridor: measured against real MKDirections corridors, the
    /// straight line stops predicting the roads (4–6% cell overlap at
    /// ~950 mi) — prefetching it would spend NWS requests on cells no route
    /// crosses, so the gate returns nothing at all.
    func testPrefetchCellsGateLongCorridor() {
        let augusta = CLLocationCoordinate2D(latitude: 33.47, longitude: -82.08)
        let milwaukee = CLLocationCoordinate2D(latitude: 43.04, longitude: -87.91)
        XCTAssertTrue(WeatherAlertService.prefetchCells(from: augusta, to: milwaukee).isEmpty)
        // The cap is the gate: lifting it brings the same line back.
        XCTAssertGreaterThan(
            WeatherAlertService.prefetchCells(from: augusta, to: milwaukee, maxCells: 1000).count,
            16)
    }

    /// Degenerate span: identical endpoints still produce their one cell.
    func testPrefetchCellsSamePoint() {
        let pt = CLLocationCoordinate2D(latitude: 43.0, longitude: -89.0)
        let cells = WeatherAlertService.prefetchCells(from: pt, to: pt)
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(WeatherAlertService.cellKey(cells[0]), WeatherAlertService.cellKey(pt))
    }

    // MARK: provisional corridor view

    private func alert(
        id: String, event: String = "Flood Warning", severity: Double,
        expires: Date? = nil
    ) -> WeatherAlertService.NWSAlert {
        var a = WeatherAlertService.NWSAlert(
            id: id, event: event, headline: event, severityScore: severity, polygon: nil)
        a.expires = expires
        return a
    }

    /// The three sample states must stay distinguishable: landed-with-alert
    /// carries the risk, landed-clear is a real zero, and NOT-YET-LANDED is
    /// nil — never zero, so "unknown" can never render as "clear".
    func testProvisionalSamplesDistinguishUnknownFromClear() {
        let inAlert = CLLocationCoordinate2D(latitude: 43.0, longitude: -89.0)
        let unknown = CLLocationCoordinate2D(latitude: 44.0, longitude: -88.0)
        let clear = CLLocationCoordinate2D(latitude: 45.0, longitude: -87.0)
        let out = WeatherAlertService.provisionalSamples(
            samples: [inAlert, unknown, clear],
            cellAlerts: [
                WeatherAlertService.cellKey(inAlert): [alert(id: "a", severity: 0.88)],
                WeatherAlertService.cellKey(clear): [],
            ],
            arrivalOffsets: nil, now: Date())
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0]?.risk ?? 0, 0.88, accuracy: 1e-9)
        XCTAssertEqual(out[0]?.worstEvent, "Flood Warning")
        XCTAssertEqual(out[0]?.alertID, "a")
        XCTAssertNil(out[1])                       // still in flight → unknown
        XCTAssertNotNil(out[2])                    // landed, genuinely clear
        XCTAssertEqual(out[2]?.risk ?? -1, 0, accuracy: 1e-9)
    }

    /// Same time-awareness as the final pass: an alert that expires before
    /// the driver reaches its stretch contributes nothing there.
    func testProvisionalSamplesRespectArrivalExpiry() {
        let pt = CLLocationCoordinate2D(latitude: 43.0, longitude: -89.0)
        let now = Date()
        let cellAlerts = [WeatherAlertService.cellKey(pt):
                            [alert(id: "a", severity: 0.88,
                                   expires: now.addingTimeInterval(600))]]
        let out = WeatherAlertService.provisionalSamples(
            samples: [pt, pt], cellAlerts: cellAlerts,
            arrivalOffsets: [0, 3600], now: now)
        XCTAssertEqual(out[0]?.risk ?? 0, 0.88, accuracy: 1e-9)   // active on arrival
        XCTAssertEqual(out[1]?.risk ?? -1, 0, accuracy: 1e-9)     // expired by then
    }

    /// Several alerts in one cell → the worst active one names the sample.
    func testProvisionalSamplesPickWorst() {
        let pt = CLLocationCoordinate2D(latitude: 43.0, longitude: -89.0)
        let out = WeatherAlertService.provisionalSamples(
            samples: [pt],
            cellAlerts: [WeatherAlertService.cellKey(pt): [
                alert(id: "minor", event: "Dense Fog Advisory", severity: 0.45),
                alert(id: "severe", event: "Tornado Warning", severity: 0.95),
            ]],
            arrivalOffsets: nil, now: Date())
        XCTAssertEqual(out[0]?.risk ?? 0, 0.95, accuracy: 1e-9)
        XCTAssertEqual(out[0]?.alertID, "severe")
    }

    // MARK: grade display geometry

    /// Precomputed 3D grade-overlay geometry: slices must carry the vertices
    /// whose cumulative distance falls inside each segment's mile span, and
    /// steep markers must land at segment midpoints — same semantics as the
    /// per-frame walk this replaced.
    func testGradeDisplayGeometry() {
        // Straight north line: 21 vertices every ~0.01° lat ≈ 1,113 m.
        let coords = (0..<21).map {
            CLLocationCoordinate2D(latitude: 43.0 + Double($0) * 0.01, longitude: -89.0)
        }
        let poly = MKPolyline(coordinates: coords, count: coords.count)
        let stepMiles = 1_113.2 / 1609.344   // ≈ 0.692 mi between vertices
        let profile = [
            GradeSegment(startMile: 0, endMile: stepMiles * 4, gradePercent: 2),
            GradeSegment(startMile: stepMiles * 4, endMile: stepMiles * 8, gradePercent: 7),
            GradeSegment(startMile: stepMiles * 8, endMile: stepMiles * 12, gradePercent: -9),
        ]
        let out = RouteService.gradeDisplayGeometry(of: poly, profile: profile)

        XCTAssertEqual(out.slices.count, 3)
        // First slice spans vertices 0…4 (cumulative 0 through 4 steps).
        XCTAssertEqual(out.slices[0].coords.count, 5)
        XCTAssertEqual(out.slices[0].coords.first?.latitude ?? 0, 43.0, accuracy: 1e-9)
        XCTAssertEqual(out.slices[0].gradePercent, 2)
        // Steep segments (≥6%) get midpoint markers, sign preserved.
        XCTAssertEqual(out.markers.count, 2)
        XCTAssertEqual(out.markers[0].gradePercent, 7)
        XCTAssertEqual(out.markers[1].gradePercent, -9)
        // Marker for the 7% segment sits at ~6 steps (midpoint of 4…8).
        XCTAssertEqual(out.markers[0].coordinate.latitude, 43.06, accuracy: 0.011)

        // Degenerate inputs stay empty, never trap.
        XCTAssertTrue(RouteService.gradeDisplayGeometry(of: poly, profile: []).slices.isEmpty)
        let dot = MKPolyline(coordinates: [coords[0]], count: 1)
        XCTAssertTrue(RouteService.gradeDisplayGeometry(of: dot, profile: profile).markers.isEmpty)
    }

    // MARK: PlannedRoute provisional accessors

    private func sample(_ risk: Double) -> RiskSample {
        RiskSample(coordinate: .init(latitude: 0, longitude: 0), risk: risk)
    }

    /// The card's "so far" band and mid-scoring strip: worst KNOWN risk, band
    /// shares over all samples, and the still-checking share carried as a
    /// nil band (rendered as pending — never as clear).
    func testProvisionalWorstAndFractions() {
        var r = PlannedRoute(route: MKRoute(), sourceName: "A", destinationName: "B")
        XCTAssertNil(r.provisionalWorstRisk)
        XCTAssertTrue(r.provisionalFractions.isEmpty)

        r.provisionalSamples = [nil, sample(0.1), sample(0.5), sample(0.8)]
        XCTAssertEqual(r.provisionalWorstRisk ?? 0, 0.8, accuracy: 1e-9)

        let fractions = r.provisionalFractions
        XCTAssertEqual(fractions.count, 4)
        XCTAssertEqual(fractions.map(\.band), [.clear, .green, .yellow, nil])
        for f in fractions { XCTAssertEqual(f.fraction, 0.25, accuracy: 1e-9) }
        XCTAssertEqual(fractions.map(\.fraction).reduce(0, +), 1, accuracy: 1e-9)
    }
}
