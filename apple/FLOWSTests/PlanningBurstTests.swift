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
        func enter() {
            cur += 1
            hi = Swift.max(hi, cur)
        }
        func leave() { cur -= 1 }
        func peak() -> Int { hi }
        func reset() {
            cur = 0
            hi = 0
        }
    }

    /// Push `count` holds through the gate and report the peak concurrency.
    private static func drive(_ gate: RequestGate, count: Int, peak: Peak) async -> Int {
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

        let atRest = await Self.drive(gate, count: 12, peak: peak)
        XCTAssertGreaterThan(atRest, 0)
        XCTAssertLessThanOrEqual(atRest, 2)

        await gate.beginPlanningBurst()
        let bursting = await Self.drive(gate, count: 12, peak: peak)
        XCTAssertGreaterThan(bursting, 2)  // proof the lane opened
        XCTAssertLessThanOrEqual(bursting, 5)  // …and stayed capped
        await gate.endPlanningBurst()

        let after = await Self.drive(gate, count: 12, peak: peak)
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
        let stillBursting = await Self.drive(gate, count: 12, peak: peak)
        XCTAssertGreaterThan(stillBursting, 2)
        await gate.endPlanningBurst()
        let closed = await Self.drive(gate, count: 12, peak: peak)
        XCTAssertLessThanOrEqual(closed, 2)
    }

    /// The scoped form pairs begin/end by construction: the lane is open
    /// exactly for the duration of the operation and closed after, so a new
    /// burst site cannot leak the elevated ceiling.
    func testWithPlanningBurstScopesTheCeiling() async {
        let gate = RequestGate(baseCeiling: { 2 }, burstCeiling: { 5 })
        let peak = Peak()
        await gate.withPlanningBurst {
            let inside = await Self.drive(gate, count: 12, peak: peak)
            XCTAssertGreaterThan(inside, 2)
            XCTAssertLessThanOrEqual(inside, 5)
        }
        let after = await Self.drive(gate, count: 12, peak: peak)
        XCTAssertLessThanOrEqual(after, 2)
    }

    /// A leaked burst (begin with no end — a cancelled hydration in the worst
    /// spot) self-heals: past the safety window the ceiling is background
    /// again even though the refcount never hit zero.
    func testPlanningBurstSafetyWindowExpires() async {
        let gate = RequestGate(
            baseCeiling: { 2 }, burstCeiling: { 6 },
            burstSafetyWindow: 0.05)
        let peak = Peak()
        await gate.beginPlanningBurst()
        try? await Task.sleep(for: .milliseconds(150))
        let after = await Self.drive(gate, count: 10, peak: peak)
        XCTAssertLessThanOrEqual(after, 2)
    }

    /// A low-priority request (the map's hazard sweep) waits behind every
    /// normal one, even one that queued after it.
    func testLowPriorityWaitsBehindNormalRequests() async {
        actor Order {
            var seen: [String] = []
            var holding = false
            func hold() { holding = true }
            func add(_ s: String) { seen.append(s) }
            func all() -> [String] { seen }
        }
        let gate = RequestGate(baseCeiling: { 1 }, burstCeiling: { 1 })
        let order = Order()
        // Each step waits for the line to show the one before it, not for a
        // fixed time: on a busy machine a fixed wait let the holder finish
        // before the normal request had queued. The wait is bounded so a
        // broken gate fails the test instead of hanging it.
        @Sendable func until(_ ready: @Sendable ((normal: Int, low: Int)) -> Bool) async {
            for _ in 0..<2_000 {
                if ready(await gate.parked) { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await gate.withPermit {
                    await order.hold()
                    await until { $0.normal == 1 && $0.low == 1 }
                    await order.add("holder")
                }
            }
            for _ in 0..<2_000 where !(await order.holding) {
                try? await Task.sleep(for: .milliseconds(5))
            }
            group.addTask {
                try? await gate.withPermit(low: true) { await order.add("low") }
            }
            await until { $0.low == 1 }
            group.addTask {
                try? await gate.withPermit { await order.add("normal") }
            }
        }
        let seen = await order.all()
        XCTAssertEqual(seen, ["holder", "normal", "low"])
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
        XCTAssertGreaterThan(hi, 1)  // waiters actually joined mid-flight
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
        XCTAssertEqual(Set(keys).count, keys.count)  // one point per cell
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
        XCTAssertNil(out[1])  // still in flight → unknown
        XCTAssertNotNil(out[2])  // landed, genuinely clear
        XCTAssertEqual(out[2]?.risk ?? -1, 0, accuracy: 1e-9)
    }

    /// Same time-awareness as the final pass: an alert that expires before
    /// the driver reaches its stretch contributes nothing there.
    func testProvisionalSamplesRespectArrivalExpiry() {
        let pt = CLLocationCoordinate2D(latitude: 43.0, longitude: -89.0)
        let now = Date()
        let cellAlerts = [
            WeatherAlertService.cellKey(pt):
                [
                    alert(
                        id: "a", severity: 0.88,
                        expires: now.addingTimeInterval(600))
                ]
        ]
        let out = WeatherAlertService.provisionalSamples(
            samples: [pt, pt], cellAlerts: cellAlerts,
            arrivalOffsets: [0, 3600], now: now)
        XCTAssertEqual(out[0]?.risk ?? 0, 0.88, accuracy: 1e-9)  // active on arrival
        XCTAssertEqual(out[1]?.risk ?? -1, 0, accuracy: 1e-9)  // expired by then
    }

    /// Several alerts in one cell → the worst active one names the sample.
    func testProvisionalSamplesPickWorst() {
        let pt = CLLocationCoordinate2D(latitude: 43.0, longitude: -89.0)
        let out = WeatherAlertService.provisionalSamples(
            samples: [pt],
            cellAlerts: [
                WeatherAlertService.cellKey(pt): [
                    alert(id: "minor", event: "Dense Fog Advisory", severity: 0.45),
                    alert(id: "severe", event: "Tornado Warning", severity: 0.95),
                ]
            ],
            arrivalOffsets: nil, now: Date())
        XCTAssertEqual(out[0]?.risk ?? 0, 0.95, accuracy: 1e-9)
        XCTAssertEqual(out[0]?.alertID, "severe")
    }

    /// A warning names the sample over the stronger-rated watch around it.
    func testProvisionalSamplesPickTheWarningOverItsWatch() {
        let pt = CLLocationCoordinate2D(latitude: 43.0, longitude: -89.0)
        let out = WeatherAlertService.provisionalSamples(
            samples: [pt],
            cellAlerts: [
                WeatherAlertService.cellKey(pt): [
                    alert(id: "watch", event: "Tornado Watch", severity: 0.95),
                    alert(id: "svr", event: "Severe Thunderstorm Warning", severity: 0.88),
                ]
            ],
            arrivalOffsets: nil, now: Date())
        XCTAssertEqual(out[0]?.alertID, "svr")
        XCTAssertEqual(out[0]?.worstEvent, "Severe Thunderstorm Warning")
    }

    // MARK: the road between check points

    /// ~42.6 km of road along 40°N between two check points, with a vertex
    /// in the middle: points every 5 km, each tagged with the nearer end.
    func testBetweenPointsWalkTheRoadAndNameTheNearerCheckPoint() {
        let a = CLLocationCoordinate2D(latitude: 40, longitude: -100)
        let mid = CLLocationCoordinate2D(latitude: 40, longitude: -99.75)
        let b = CLLocationCoordinate2D(latitude: 40, longitude: -99.5)
        let out = WeatherAlertService.betweenPoints(samples: [a, b], between: [[a, mid, b]])
        XCTAssertEqual(out.count, 8)  // 5…40 km of 42.6
        XCTAssertEqual(out.filter { $0.sample == 0 }.count, 4)  // the first half
        XCTAssertEqual(out.filter { $0.sample == 1 }.count, 4)
        XCTAssertEqual(POIRanking.meters(a, out[0].point), 5_000, accuracy: 60)
        // along the road, in order
        XCTAssertTrue(zip(out, out.dropFirst()).allSatisfy { $0.point.longitude < $1.point.longitude })
    }

    func testBetweenPointsLeaveShortRunsAndMissingRoadAlone() {
        let a = CLLocationCoordinate2D(latitude: 40, longitude: -100)
        let near = CLLocationCoordinate2D(latitude: 40, longitude: -99.97)  // ~2.6 km
        XCTAssertTrue(WeatherAlertService.betweenPoints(samples: [a, near], between: [[a, near]]).isEmpty)
        XCTAssertTrue(WeatherAlertService.betweenPoints(samples: [a, near], between: nil).isEmpty)
        XCTAssertTrue(WeatherAlertService.betweenPoints(samples: [a], between: [[a]]).isEmpty)
        // a garbled run (one point, or not a number) yields nothing, never a trap
        let junk = CLLocationCoordinate2D(latitude: .nan, longitude: .nan)
        XCTAssertTrue(WeatherAlertService.betweenPoints(samples: [a, near], between: [[a], [junk, junk]]).isEmpty)
    }

    /// The work is bounded: past the cap the far end is left to its check
    /// points, and what is kept is still in route order.
    func testBetweenPointsStopAtTheCap() {
        let samples = (0...30).map { CLLocationCoordinate2D(latitude: 40, longitude: -100 + 0.5 * Double($0)) }
        let runs = (0..<30).map { [samples[$0], samples[$0 + 1]] }
        let all = WeatherAlertService.betweenPoints(samples: samples, between: runs)
        XCTAssertEqual(all.count, 30 * 8)  // 8 per 42.6 km gap
        let capped = WeatherAlertService.betweenPoints(samples: samples, between: runs, cap: 20)
        XCTAssertEqual(capped.count, 20)
        XCTAssertEqual(capped.map { $0.point.longitude }, all.prefix(20).map { $0.point.longitude })
    }

    func testRunsBetweenRejoinsTheTwoPaintedHalves() {
        let p = (0..<5).map { CLLocationCoordinate2D(latitude: 40, longitude: -100 + 0.1 * Double($0)) }
        // one gap drawn as two halves sharing p[2]
        let halves = [
            RiskSegment(coordinates: [p[0], p[1], p[2]], risk: 0, lengthMeters: 1, sampleIndex: 0),
            RiskSegment(coordinates: [p[2], p[3], p[4]], risk: 0, lengthMeters: 1, sampleIndex: 1),
        ]
        let runs = WeatherAlertService.runsBetween(halves, gaps: 1)
        XCTAssertEqual(runs?.first?.count, 5)
        XCTAssertNil(WeatherAlertService.runsBetween(halves, gaps: 2))  // not that route's segments
        XCTAssertNil(WeatherAlertService.runsBetween([], gaps: 0))
    }

    // MARK: state-level alert resolution (client-side spatial join)

    func testParseAlertFeaturesPolygonAndZoneShapes() {
        let features: [[String: Any]] = [
            [
                "id": "urn:a",
                "properties": [
                    "id": "urn:a", "event": "Tornado Warning",
                    "headline": "TW", "severity": "Extreme",
                    "affectedZones": ["https://api.weather.gov/zones/forecast/WIZ064"],
                ],
                "geometry": [
                    "type": "Polygon",
                    "coordinates": [
                        [
                            [-89.5, 42.9], [-89.5, 43.1], [-89.3, 43.1],
                            [-89.3, 42.9], [-89.5, 42.9],
                        ]
                    ],
                ],
            ],
            [
                "id": "urn:b",
                "properties": [
                    "id": "urn:b", "event": "Winter Storm Warning",
                    "headline": "WSW", "severity": "Moderate",
                    "affectedZones": ["z1", "z2"],
                ],
                "geometry": NSNull(),
            ],
        ]
        let parsed = WeatherAlertService.parseAlertFeatures(features)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].id, "urn:a")
        XCTAssertEqual(parsed[0].severityScore, 0.95, accuracy: 1e-9)
        XCTAssertEqual(parsed[0].polygon?.count, 5)
        XCTAssertEqual(
            parsed[0].affectedZones,
            ["https://api.weather.gov/zones/forecast/WIZ064"])
        XCTAssertNil(parsed[1].polygon)  // geometry: null survives as nil
        XCTAssertEqual(parsed[1].severityScore, 0.72, accuracy: 1e-9)
        XCTAssertEqual(parsed[1].affectedZones, ["z1", "z2"])
    }

    /// An alert is in force until the EVENT ends, not until its message
    /// lapses (with no end given: testAnAlertWithNoEndRunsAsLongAsItsKind).
    func testACancelledAlertIsNotALiveWarning() {
        func alert(_ type: String) -> [String: Any] {
            [
                "id": "urn:x",
                "properties": [
                    "id": "urn:x", "event": "Tornado Warning", "headline": "TOR",
                    "severity": "Extreme", "messageType": type,
                    "expires": "2026-12-01T04:00:00-06:00",
                ],
                "geometry": NSNull(),
            ]
        }
        XCTAssertEqual(WeatherAlertService.parseAlertFeatures([alert("Alert")]).count, 1)
        XCTAssertEqual(WeatherAlertService.parseAlertFeatures([alert("Update")]).count, 1)
        XCTAssertTrue(WeatherAlertService.parseAlertFeatures([alert("Cancel")]).isEmpty)
    }

    func testAnAlertLastsUntilItsEventEnds() throws {
        func alert(_ extra: [String: Any]) -> [String: Any] {
            [
                "id": "urn:x",
                "properties": [
                    "id": "urn:x", "event": "Winter Storm Warning", "headline": "WSW",
                    "severity": "Severe", "expires": "2026-12-01T04:00:00-06:00",
                ]
                .merging(extra) { $1 },
                "geometry": NSNull(),
            ]
        }
        let parse = { (extra: [String: Any]) in
            WeatherAlertService.parseAlertFeatures([alert(extra)]).first?.expires
        }
        let message = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-01T10:00:00Z"))
        let ends = try XCTUnwrap(parse(["ends": "2026-12-01T20:00:00-06:00"]))
        XCTAssertEqual(ends.timeIntervalSince(message), 16 * 3600, "until the storm ends at 20:00")
        let early = try XCTUnwrap(parse(["ends": "2026-12-01T02:00:00-06:00"]))
        XCTAssertEqual(early, message, "never before the message itself lapses")
    }

    /// The device learns how long each kind of alert runs from the alerts
    /// that state their end, in proportion to how many it has seen (owner,
    /// 2026-11-11), and forgets it all on erase.
    func testAlertLengthsAreLearnedInProportionToWhatWasSeen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flows-alert-lengths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let memory = AlertLengthMemory(directory: dir)
        let iso = ISO8601DateFormatter()
        let parse: (String) -> Date? = { iso.date(from: $0) }
        func storm(
            _ n: Int, hours: Int, action: String = "NEW",
            extra: [String: Any] = [:]
        ) -> [String: Any] {
            let ends = iso.string(
                from: try! XCTUnwrap(parse("2026-12-01T00:00:00Z"))
                    .addingTimeInterval(Double(hours) * 3600))
            let props: [String: Any] = [
                "id": "urn:storm:\(n):\(action)", "event": "Winter Storm Warning",
                "onset": "2026-12-01T00:00:00Z", "ends": ends,
                "parameters": [
                    "VTEC": ["/O.\(action).KBUF.WS.W.\(String(format: "%04d", n)).261201T0000Z-261203T0000Z/"]
                ],
            ]
            return ["id": "urn:storm:\(n):\(action)", "properties": props.merging(extra) { $1 }]
        }
        XCTAssertEqual(memory.usualHours(event: "Winter Storm Warning"), 27, accuracy: 1e-9)
        XCTAssertEqual(memory.eventCount, 0)

        // Twenty storms of 54 hours: half way, in ratio, from 27 to 54.
        let twenty = (1...20).map { storm($0, hours: 54) }
        memory.record(AlertLengthLearning.samples(from: twenty, parse: parse))
        XCTAssertEqual(memory.eventCount, 20)
        XCTAssertEqual(
            memory.usualHours(event: "Winter Storm Warning"),
            27 * 2.0.squareRoot(), accuracy: 1e-9)
        // The same list again, and an update of one storm under a new
        // message id, count nothing twice.
        memory.record(AlertLengthLearning.samples(from: twenty, parse: parse))
        memory.record(
            AlertLengthLearning.samples(
                from: [storm(7, hours: 54, action: "CON")], parse: parse))
        XCTAssertEqual(memory.eventCount, 20)
        XCTAssertEqual(
            memory.usualHours(event: "Winter Storm Warning"),
            27 * 2.0.squareRoot(), accuracy: 1e-9)
        // An update of a storm already under way gives its own send time as
        // the start (the VTEC start reads zeros). It must not shorten a
        // storm whose start was seen, and a storm first met half way
        // through teaches nothing: its true start is not known.
        func underWay(_ n: Int) -> [String: Any] {
            [
                "id": "urn:storm:\(n):late",
                "properties": [
                    "id": "urn:storm:\(n):late", "event": "Winter Storm Warning",
                    "messageType": "Update",
                    "onset": "2026-12-03T00:00:00Z", "ends": "2026-12-03T06:00:00Z",
                    "parameters": [
                        "VTEC": ["/O.CON.KBUF.WS.W.\(String(format: "%04d", n)).000000T0000Z-261203T0600Z/"]
                    ],
                ] as [String: Any],
            ]
        }
        memory.record(AlertLengthLearning.samples(from: [underWay(7), underWay(99)], parse: parse))
        XCTAssertEqual(memory.eventCount, 20)
        XCTAssertEqual(
            memory.usualHours(event: "Winter Storm Warning"),
            27 * 2.0.squareRoot(), accuracy: 1e-9)
        // Other kinds are untouched.
        XCTAssertEqual(memory.usualHours(event: "Flood Warning"), 42, accuracy: 1e-9)

        // An alert with no end now runs the learned length.
        let noEnd: [String: Any] = [
            "id": "urn:x",
            "properties": [
                "id": "urn:x", "event": "Winter Storm Warning",
                "headline": "Winter Storm Warning", "severity": "Severe",
                "expires": "2026-12-01T10:00:00Z",
            ],
            "geometry": NSNull(),
        ]
        let message = try XCTUnwrap(parse("2026-12-01T10:00:00Z"))
        let taught = try XCTUnwrap(
            WeatherAlertService.parseAlertFeatures([noEnd], lengths: memory).first?.expires)
        XCTAssertEqual(
            taught.timeIntervalSince(message) / 3600,
            27 * 2.0.squareRoot() * 1.38, accuracy: 1e-6)
        let plain = try XCTUnwrap(
            WeatherAlertService.parseAlertFeatures([noEnd], lengths: nil).first?.expires)
        XCTAssertEqual(plain.timeIntervalSince(message) / 3600, 27 * 1.38, accuracy: 1e-6)

        // What teaches nothing: a cancel, no end, no start, a length that is
        // not a believable event.
        let nothing = AlertLengthLearning.samples(
            from: [
                storm(30, hours: 54, extra: ["messageType": "Cancel"]),
                noEnd,
                storm(31, hours: 0),
                storm(32, hours: 5_000),
            ], parse: parse)
        XCTAssertEqual(nothing, [])

        // Kept across launches, sealed; gone on erase.
        let saved = expectation(description: "saved")
        SecureBehaviorStore.persistQueue.async { saved.fulfill() }
        wait(for: [saved], timeout: 5)
        XCTAssertEqual(AlertLengthMemory(directory: dir).eventCount, 20)
        let raw = try Data(contentsOf: dir.appendingPathComponent("flows_alert_lengths.json"))
        XCTAssertNil(String(data: raw, encoding: .utf8).flatMap { $0.range(of: "KBUF") })
        memory.erase()
        XCTAssertEqual(memory.eventCount, 0)
        XCTAssertEqual(memory.usualHours(event: "Winter Storm Warning"), 27, accuracy: 1e-9)
        XCTAssertEqual(AlertLengthMemory(directory: dir).eventCount, 0)
    }

    /// With no end given, an alert runs as long as its kind usually does,
    /// by how severe, how wide and how sure it is (owner, 2026-11-11), from
    /// when it began.
    func testAnAlertWithNoEndRunsAsLongAsItsKind() throws {
        func alert(_ event: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            [
                "id": "urn:x",
                "properties": [
                    "id": "urn:x", "event": event, "headline": event,
                    "severity": "Severe", "expires": "2026-12-01T04:00:00-06:00",
                ]
                .merging(extra) { $1 },
                "geometry": NSNull(),
            ]
        }
        func hoursPastMessage(_ event: String, _ extra: [String: Any] = [:]) throws -> Double {
            let message = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-01T10:00:00Z"))
            let end = try XCTUnwrap(
                WeatherAlertService.parseAlertFeatures([alert(event, extra)]).first?.expires)
            return end.timeIntervalSince(message) / 3600
        }
        // No start on record: a winter storm's 27 hours, at Severe (0.5 + 0.88).
        XCTAssertEqual(try hoursPastMessage("Winter Storm Warning"), 27 * 1.38, accuracy: 1e-6)
        // Counted from when it began, two hours before the message lapses.
        XCTAssertEqual(
            try hoursPastMessage("Winter Storm Warning", ["sent": "2026-12-01T02:00:00-06:00"]),
            27 * 1.38 - 2, accuracy: 1e-6)
        // Begun long ago and still told about: a quarter of its life more.
        XCTAssertEqual(
            try hoursPastMessage("Winter Storm Warning", ["sent": "2026-11-20T02:00:00-06:00"]),
            27 * 1.38 / 4, accuracy: 1e-6)
        // The kind decides: a hurricane far outlasts a short statement, and
        // a fire the chance of one.
        let statement = try hoursPastMessage("Special Weather Statement")
        XCTAssertEqual(statement, 1 * 1.38, accuracy: 1e-6)
        XCTAssertEqual(try hoursPastMessage("Hurricane Warning"), 42 * 1.38, accuracy: 1e-6)
        XCTAssertEqual(try hoursPastMessage("Red Flag Warning"), 8 * 1.38, accuracy: 1e-6)
        XCTAssertEqual(try hoursPastMessage("Fire Warning"), 72 * 1.38, accuracy: 1e-6)
        // Wider and seen run longer: four zones is 1.3 times, seen a quarter more.
        XCTAssertEqual(
            try hoursPastMessage(
                "Fire Warning",
                [
                    "affectedZones": ["a", "b", "c", "d"],
                    "certainty": "Observed",
                ]),
            72 * 1.38 * 1.3 * 1.25, accuracy: 1e-6)
        // Less severe runs shorter.
        XCTAssertEqual(
            try hoursPastMessage("Fire Warning", ["severity": "Minor"]),
            72 * 0.95, accuracy: 1e-6)
        // Nothing learned yet in a test run: the measured table alone, the
        // same as with no memory at all.
        XCTAssertEqual(
            WeatherAlertService.parseAlertFeatures([alert("Hurricane Warning")], lengths: nil)
                .first?.expires,
            WeatherAlertService.parseAlertFeatures([alert("Hurricane Warning")]).first?.expires)
        // The facade never answers before the message lapses.
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let end = RiskTiming.unknownEnd(
            event: "", severityScore: .nan, zones: 0,
            certainty: nil, onset: nil, message: now)
        XCTAssertEqual(end.timeIntervalSince(now), 12 * 3600, accuracy: 1e-6)
    }

    func testStatesContainingUsesBBoxOverlap() {
        let madison = CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40)
        XCTAssertTrue(WeatherAlertService.statesContaining(madison).contains("WI"))
        // Mid-Pacific: on no state's table → the per-point path.
        let ocean = CLLocationCoordinate2D(latitude: 25.0, longitude: -157.0)
        XCTAssertTrue(WeatherAlertService.statesContaining(ocean).isEmpty)
    }

    /// Water-adjacent cells must union their marine REGION list — the live
    /// parity harness's only oracle mismatches were offshore cells whose
    /// marine alerts state lists never carry. The "marine:" prefix keeps
    /// region codes from colliding with state codes ("AL" is both Alabama
    /// and Alaska waters).
    func testMarineRegionSources() {
        let pacificCoast = CLLocationCoordinate2D(latitude: 34.8, longitude: -121.7)
        XCTAssertEqual(WeatherAlertService.marineRegionsContaining(pacificCoast), ["marine:PA"])
        let chesapeake = CLLocationCoordinate2D(latitude: 37.0, longitude: -76.1)
        XCTAssertEqual(WeatherAlertService.marineRegionsContaining(chesapeake), ["marine:AT"])
        let mackinac = CLLocationCoordinate2D(latitude: 45.8, longitude: -84.7)
        XCTAssertEqual(WeatherAlertService.marineRegionsContaining(mackinac), ["marine:GL"])
        let kansas = CLLocationCoordinate2D(latitude: 38.5, longitude: -98.0)
        XCTAssertTrue(WeatherAlertService.marineRegionsContaining(kansas).isEmpty)
    }

    /// The join must mirror the server's per-point semantics: a polygon
    /// alert matches by its rings ONLY (the polygon is the affected area,
    /// more precise than the zones it also lists); a geometry-null alert
    /// matches through its zones' rings; an alert whose zone rings are
    /// absent can never match.
    func testAlertsCoveringJoinSemantics() {
        func ring(
            _ latLo: Double, _ latHi: Double,
            _ lonLo: Double, _ lonHi: Double
        ) -> [CLLocationCoordinate2D] {
            [
                .init(latitude: latLo, longitude: lonLo), .init(latitude: latHi, longitude: lonLo),
                .init(latitude: latHi, longitude: lonHi), .init(latitude: latLo, longitude: lonHi),
            ]
        }
        let west = ring(42.9, 43.1, -89.5, -89.3)
        let east = ring(42.9, 43.1, -88.2, -88.0)
        var polyAlert = WeatherAlertService.NWSAlert(
            id: "poly", event: "Flood Warning", headline: "h",
            severityScore: 0.88, polygon: west)
        polyAlert.affectedZones = ["zEast"]  // listed, but polygon wins
        var zoneAlert = alert(id: "zone", event: "Winter Storm Warning", severity: 0.72)
        zoneAlert.affectedZones = ["zEast"]
        var lostAlert = alert(id: "lost", severity: 0.45)
        lostAlert.affectedZones = ["zMissing"]
        let zoneRings = ["zEast": [east]]

        let inWest = CLLocationCoordinate2D(latitude: 43.0, longitude: -89.4)
        let inEast = CLLocationCoordinate2D(latitude: 43.0, longitude: -88.1)
        let outside = CLLocationCoordinate2D(latitude: 44.5, longitude: -91.0)

        let westHits = WeatherAlertService.alertsCovering(
            inWest, alerts: [polyAlert, zoneAlert, lostAlert], zoneRings: zoneRings)
        XCTAssertEqual(westHits.map(\.id), ["poly"])
        let eastHits = WeatherAlertService.alertsCovering(
            inEast, alerts: [polyAlert, zoneAlert, lostAlert], zoneRings: zoneRings)
        // polygon alert does NOT match via its listed zone — rings only.
        XCTAssertEqual(eastHits.map(\.id), ["zone"])
        XCTAssertTrue(
            WeatherAlertService.alertsCovering(
                outside, alerts: [polyAlert, zoneAlert, lostAlert], zoneRings: zoneRings
            ).isEmpty)
        // extraRings participate for multi-part polygon alerts.
        var multi = WeatherAlertService.NWSAlert(
            id: "multi", event: "Flood Warning", headline: "h",
            severityScore: 0.9, polygon: west)
        multi.extraRings = [east]
        XCTAssertEqual(
            WeatherAlertService.alertsCovering(
                inEast, alerts: [multi], zoneRings: [:]
            ).map(\.id), ["multi"])
    }

    // MARK: ETA tie tolerance (route ordering)

    /// The tie window must be PROPORTIONAL to the trip. It was a flat 300 s,
    /// which is 25% of a twenty-minute errand and 0.8% of a ten-hour haul —
    /// so a calmer route could essentially never win a short trip and almost
    /// always won a long one, an inversion nobody chose.
    func testETATieToleranceScalesWithTripLength() {
        // Short errand: the floor applies, so safety still has a real window.
        XCTAssertEqual(RouteService.etaTieTolerance(shorterETA: 20 * 60), 120, accuracy: 1e-9)
        // Two-hour drive: 8% ≈ 9.6 min.
        XCTAssertEqual(RouteService.etaTieTolerance(shorterETA: 2 * 3600), 576, accuracy: 1e-9)
        // Ten-hour haul: capped at 15 min rather than 48.
        XCTAssertEqual(RouteService.etaTieTolerance(shorterETA: 10 * 3600), 900, accuracy: 1e-9)
        // Monotone, and always inside the rails.
        var previous = 0.0
        for minutes in stride(from: 5.0, through: 900.0, by: 5) {
            let t = RouteService.etaTieTolerance(shorterETA: minutes * 60)
            XCTAssertGreaterThanOrEqual(t, 120)
            XCTAssertLessThanOrEqual(t, 900)
            XCTAssertGreaterThanOrEqual(t, previous)
            previous = t
        }
        // Degenerate input can't produce a negative or NaN window.
        XCTAssertEqual(RouteService.etaTieTolerance(shorterETA: 0), 120, accuracy: 1e-9)
        XCTAssertEqual(RouteService.etaTieTolerance(shorterETA: -500), 120, accuracy: 1e-9)
    }

    /// The old flat window is what this replaced — assert the new behaviour
    /// actually differs where it mattered, so a regression to a constant is
    /// caught rather than silently accepted.
    func testETATieToleranceDiffersFromTheOldFlatWindow() {
        XCTAssertNotEqual(RouteService.etaTieTolerance(shorterETA: 20 * 60), 300)
        XCTAssertNotEqual(RouteService.etaTieTolerance(shorterETA: 10 * 3600), 300)
    }

    // MARK: trucker clearance gate

    /// A KNOWN low bridge must DISQUALIFY a route for a semi, not cost it
    /// points. Under the old additive scoring a clearance-failing route
    /// scored 6 (highways + grade + wind) and could tie or beat a
    /// clearance-PASSING one — the badge could point a truck at a bridge it
    /// cannot clear. Unknown data must still pass, or corridors without OSM
    /// height tags would lose the badge entirely.
    func testSemiClearanceIsADisqualifierNotAPenalty() {
        let semi = FilterLimits(
            vehicleHeightMeters: 13.5 * 0.3048,
            maxGradePercent: FilterLimits.degreesToPercent(6))
        // 12'6" bridge — below a 13'6" semi plus its safety margin.
        let tooLow = [12.5 * 0.3048]
        XCTAssertFalse(semi.passesClearances(tooLow), "a 12'6\" bridge must fail a semi")
        // Generous clearance passes.
        XCTAssertTrue(semi.passesClearances([16.0 * 0.3048]))
        // UNKNOWN clearance data still passes — the app-wide rule that
        // missing data never excludes a route.
        XCTAssertTrue(semi.passesClearances(nil))
        XCTAssertTrue(semi.passesClearances([]))
    }

    // MARK: steep-grade markers

    /// Steep-grade signs (3D terrain) land at the midpoints of the stretches
    /// at 6% or steeper — same semantics as the per-frame walk this replaced.
    func testSteepMarkers() {
        // Straight north line: 21 vertices every ~0.01° lat ≈ 1,113 m.
        let coords = (0..<21).map {
            CLLocationCoordinate2D(latitude: 43.0 + Double($0) * 0.01, longitude: -89.0)
        }
        let poly = MKPolyline(coordinates: coords, count: coords.count)
        let stepMiles = 1_113.2 / 1609.344  // ≈ 0.692 mi between vertices
        let profile = [
            GradeSegment(startMile: 0, endMile: stepMiles * 4, gradePercent: 2),
            GradeSegment(startMile: stepMiles * 4, endMile: stepMiles * 8, gradePercent: 7),
            GradeSegment(startMile: stepMiles * 8, endMile: stepMiles * 12, gradePercent: -9),
        ]
        let markers = RouteService.steepMarkers(of: poly, profile: profile)

        // Steep segments (≥6%) get midpoint markers, sign preserved; the 2%
        // stretch gets none.
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers[0].gradePercent, 7)
        XCTAssertEqual(markers[1].gradePercent, -9)
        // Marker for the 7% segment sits at ~6 steps (midpoint of 4…8).
        XCTAssertEqual(markers[0].coordinate.latitude, 43.06, accuracy: 0.011)

        // Degenerate inputs stay empty, never trap.
        XCTAssertTrue(RouteService.steepMarkers(of: poly, profile: []).isEmpty)
        let dot = MKPolyline(coordinates: [coords[0]], count: 1)
        XCTAssertTrue(RouteService.steepMarkers(of: dot, profile: profile).isEmpty)
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

    /// The off-route replan starts before it is scored, so its weather score
    /// and its physical attributes land on the live leg in either order.
    /// Each pass folds in only its own fields: a whole-route write let the
    /// later pass wipe the earlier one's (the line lost its colours, or the
    /// grades vanished).
    func testScoreAndAttributesFoldInWithoutWipingEachOther() {
        let road = MKRoute()
        var live = PlannedRoute(route: road, sourceName: "A", destinationName: "B")
        live.isWalkingEstimate = true
        live.etaOverride = 600

        var scored = live
        scored.weatherRisk = 0.7
        scored.weatherScored = true
        scored.riskSamples = [sample(0.2), sample(0.7)]
        scored.riskSegments = [RiskSegment(coordinates: [], risk: 0.7, lengthMeters: 900)]
        scored.alertHeadlines = ["Flood Warning"]
        scored.peakRisk = 0.7
        scored.familyPeaks = ["wind": 0.4]

        var attributes = live
        attributes.maxGradePercent = 9
        attributes.clearancesMeters = [3.9]
        attributes.femaFloodFraction = 0.25
        attributes.attributesScored = true

        // Attributes first, then the score…
        var a = live
        a.takeAttributes(from: attributes)
        a.takeScore(from: scored)
        // …and the score first, then the attributes.
        var b = live
        b.takeScore(from: scored)
        b.takeAttributes(from: attributes)

        for r in [a, b] {
            XCTAssertEqual(r.id, live.id)
            XCTAssertEqual(r.weatherRisk, 0.7)
            XCTAssertTrue(r.weatherScored)
            XCTAssertEqual(r.riskSamples.map(\.risk), [0.2, 0.7])
            XCTAssertEqual(r.riskSegments.count, 1)
            XCTAssertEqual(r.alertHeadlines, ["Flood Warning"])
            XCTAssertEqual(r.peakRisk, 0.7)
            XCTAssertEqual(r.familyPeaks, ["wind": 0.4])
            XCTAssertEqual(r.maxGradePercent, 9)
            XCTAssertEqual(r.clearancesMeters, [3.9])
            XCTAssertEqual(r.femaFloodFraction, 0.25)
            XCTAssertTrue(r.attributesScored)
            // Neither pass touches what the leg itself carries.
            XCTAssertTrue(r.isWalkingEstimate)
            XCTAssertEqual(r.etaOverride, 600)
        }
    }

    /// The replan's long-walk estimate uses the planner's pace: 3.1 mph and
    /// 10% for rests.
    func testWalkingEstimatePace() {
        XCTAssertEqual(PlannedRoute.walkingEstimateSeconds(meters: 1_390), 1_100, accuracy: 1e-9)
        XCTAssertEqual(PlannedRoute.walkingEstimateSeconds(meters: 0), 0)
    }

    /// A plan that is still asking keeps the burst open past the safety
    /// window: the window used to run from the burst's start alone, and a
    /// long plan dropped to the background pace partway through.
    func testRequestsInsideTheBurstRenewTheWindow() async {
        let gate = RequestGate(
            baseCeiling: { 2 }, burstCeiling: { 6 },
            burstSafetyWindow: 0.2)
        let peak = Peak()
        let late = await gate.withPlanningBurst {
            // Longer than the window in all, a request every 100 ms.
            for _ in 0..<5 {
                try? await gate.withPermit { try? await Task.sleep(for: .milliseconds(100)) }
            }
            return await Self.drive(gate, count: 18, peak: peak)
        }
        XCTAssertGreaterThan(late, 2, "the burst ran out though the plan was still working")
        XCTAssertLessThanOrEqual(late, 6)
    }

    /// Requests from OUTSIDE the plan do not hold a leaked burst open.
    func testOutsideRequestsDoNotRenewALeakedBurst() async {
        let gate = RequestGate(
            baseCeiling: { 2 }, burstCeiling: { 6 },
            burstSafetyWindow: 0.2)
        let peak = Peak()
        await gate.beginPlanningBurst()
        for _ in 0..<4 {
            try? await gate.withPermit { try? await Task.sleep(for: .milliseconds(100)) }
        }
        let after = await Self.drive(gate, count: 10, peak: peak)
        XCTAssertLessThanOrEqual(after, 2)
    }

    // MARK: Tire sensors that keep up with the vehicle

    /// A car alongside, then beside this one at a red light, then heard once
    /// more as both pull away, is not this vehicle's tires: the stop between
    /// two hears is not company.
    func testANeighbourAtARedLightIsNotOurTire() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var s = VehicleLink.Sensor(position: "FL", psi: 33, lastHeard: t0)
        for i in 0..<10 { s.heardWhileMoving(at: t0.addingTimeInterval(Double(i)), lastStill: nil) }
        XCTAssertFalse(s.keptUp)  // nine seconds alongside
        // Two and a half minutes at the light, then heard again.
        let stood = t0.addingTimeInterval(60)
        s.heardWhileMoving(at: t0.addingTimeInterval(160), lastStill: stood)
        XCTAssertFalse(s.keptUp)
        XCTAssertEqual(s.company, 9, accuracy: 1e-9)
    }

    /// Two minutes of driving in earshot is this vehicle's sensor; a gap
    /// longer than `longestGap` counts for nothing.
    func testSteadyCompanyIsOurTire() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var s = VehicleLink.Sensor(position: "FL", psi: 33, lastHeard: t0)
        for i in 0...12 { s.heardWhileMoving(at: t0.addingTimeInterval(Double(i) * 10), lastStill: nil) }
        XCTAssertEqual(s.company, 120, accuracy: 1e-9)
        XCTAssertTrue(s.keptUp)
        var gappy = VehicleLink.Sensor(position: "FR", psi: 33, lastHeard: t0)
        for i in 0..<12 {
            gappy.heardWhileMoving(
                at: t0.addingTimeInterval(Double(i) * (VehicleLink.Sensor.longestGap + 1)),
                lastStill: nil)
        }
        XCTAssertEqual(gappy.company, 0, accuracy: 1e-9)
        XCTAssertFalse(gappy.keptUp)
    }

    // MARK: A learned-trips file that will not decode

    /// It is moved to one side (not written over), read back by a build
    /// that can decode it, and shredded once past its time.
    func testAnUndecodableStoreIsKeptAsideThenAgesOut() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flows-aside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("store")
        let aside = dir.appendingPathComponent("aside")
        let now = Date()

        SecureBehaviorStore.save(SeasonalStore(), to: store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path))
        SeasonalRiskModel.keepAside(store, at: aside, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path))
        XCTAssertNotNil(SeasonalRiskModel.openAside(aside, now: now.addingTimeInterval(86_400)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path))

        let late = now.addingTimeInterval(SeasonalRiskModel.asideKeptSeconds + 1)
        XCTAssertNil(SeasonalRiskModel.openAside(aside, now: late))
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))
    }

    /// The file put aside comes back next to the trips made since: neither
    /// side's routes are lost, and a shared route keeps the longer history.
    func testAStorePutAsideIsFoldedIntoTheTripsMadeSince() {
        func record(_ trips: Int) -> RouteRecord {
            var r = RouteRecord()
            r.tripCount = trips
            return r
        }
        func key(_ a: Double, _ b: Double) -> RouteKey {
            RouteKey(
                origin: CLLocationCoordinate2D(latitude: a, longitude: -a),
                dest: CLLocationCoordinate2D(latitude: b, longitude: -b))
        }
        let shared = key(10, 20)
        let oldOnly = key(30, 40)
        let newOnly = key(50, 60)
        var older = SeasonalStore()
        older.routes[shared] = record(40)
        older.routes[oldOnly] = record(7)
        var newer = SeasonalStore()
        newer.routes[shared] = record(2)
        newer.routes[newOnly] = record(1)

        let both = newer.joined(withOlder: older)
        XCTAssertEqual(both.routes[shared]?.tripCount, 40)
        XCTAssertEqual(both.routes[oldOnly]?.tripCount, 7)
        XCTAssertEqual(both.routes[newOnly]?.tripCount, 1)
        // A route driven more since than before keeps the newer record.
        newer.routes[shared] = record(41)
        XCTAssertEqual(newer.joined(withOlder: older).routes[shared]?.tripCount, 41)
    }
}
