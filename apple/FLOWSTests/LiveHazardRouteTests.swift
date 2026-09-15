// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest
// The test target compiles the app sources directly; there is no FLOWS module to import.

/// The route scorer sees the same live hazards the map does.
///
/// The icon rules (dust storm kind, every family has an icon) are pinned on
/// the Rust side: the display table is UI code the test target cannot see.
final class LiveHazardRouteTests: XCTestCase {
    private let pt = CLLocationCoordinate2D(latitude: 39.0, longitude: -105.0)

    func testAnActiveFireOnTheRouteIsRedWithNoAlert() {
        // A hotspot on the sample, no NWS alert, no field row, no forecast:
        // the route used to score this 0. It is a realized primary.
        let snap = LiveHazardSnapshot(hotspots: [(lat: 39.0, lon: -105.0, frp: 500)])
        let live = HazardFeedScores.live(at: pt, snapshot: snap).bandInputContribution
        XCTAssertGreaterThan(live["fire"] ?? 0, 0)
        let risk = RiskEquations.realizedRisk(RiskEquations.bandInput(
            field: { _ in 0 }, onDevice: [:], alertEvent: nil, alertSeverity: 0, live: live))
        XCTAssertEqual(FlowsCore.riskBand(score: risk), .red, "\(risk)")
    }

    func testNothingLiveChangesNothing() {
        // Empty snapshot: the band input is bit-identical to the call without it.
        let live = HazardFeedScores.live(at: pt, snapshot: .empty).bandInputContribution
        XCTAssertTrue(live.isEmpty)
        let field: (String) -> Double = { $0 == "wind" ? 0.4 : 0 }
        let a = RiskEquations.bandInput(field: field, onDevice: ["heat": 0.3], alertEvent: "Heat Advisory", alertSeverity: 0.5)
        let b = RiskEquations.bandInput(field: field, onDevice: ["heat": 0.3], alertEvent: "Heat Advisory", alertSeverity: 0.5, live: live)
        XCTAssertEqual(a.count, b.count)
        for (k, v) in a { XCTAssertEqual(b[k]?.bitPattern, v.bitPattern, k) }
    }

    func testLiveMergesByMaxNeverBySum() {
        // Two sources of the same family keep the larger; nothing adds.
        let field: (String) -> Double = { $0 == "convective" ? 0.5 : 0 }
        let out = RiskEquations.bandInput(field: field, onDevice: [:], alertEvent: nil, alertSeverity: 0,
                                          live: ["convective": 0.3, "fire": 0.6])
        XCTAssertEqual(out["convective"], 0.5)
        XCTAssertEqual(out["fire"], 0.6)
    }

    func testLiveScoresAreTheSweepsExpressions() {
        // Each field of `live` must be the exact component the map sweep used
        // inline, so moving both onto this function changed no map number.
        let snap = LiveHazardSnapshot(
            hotspots: [(lat: 39.05, lon: -105.02, frp: 120)],
            perimeters: [[CLLocationCoordinate2D(latitude: 38.9, longitude: -105.1),
                          CLLocationCoordinate2D(latitude: 39.1, longitude: -105.1),
                          CLLocationCoordinate2D(latitude: 39.1, longitude: -104.9)]],
            quakes: [(lat: 39.3, lon: -105.3, magnitude: 5.5, ageHours: 2)],
            space: (r: 0, s: 3, g: 4),
            volcanoes: [(lat: 39.2, lon: -105.0, level: "WARNING")],
            storms: [(lat: 39.5, lon: -104.5, maxWindKt: 90)],
            tsunamis: [(lat: 40.0, lon: -106.0, level: "warning")],
            spcZones: [(rings: [[CLLocationCoordinate2D(latitude: 38.0, longitude: -106.0),
                                 CLLocationCoordinate2D(latitude: 40.0, longitude: -106.0),
                                 CLLocationCoordinate2D(latitude: 40.0, longitude: -104.0),
                                 CLLocationCoordinate2D(latitude: 38.0, longitude: -104.0)]], score: 0.7)])
        let live = HazardFeedScores.live(at: pt, snapshot: snap)
        XCTAssertEqual(live.fire.bitPattern, max(HazardFeedScores.fireScore(hotspots: snap.hotspots, at: pt),
                                                  HazardFeedScores.firePerimeterScore(perimeters: snap.perimeters, at: pt)).bitPattern)
        XCTAssertEqual(live.seismic.bitPattern, HazardFeedScores.seismicScore(quakes: snap.quakes, at: pt).bitPattern)
        XCTAssertEqual(live.spaceRadiation.bitPattern,
                       HazardFeedScores.radiationSpaceWeatherScore(sScale: 3, gScale: 4, latitude: pt.latitude).bitPattern)
        XCTAssertEqual(live.volcanic.bitPattern, HazardFeedScores.volcanicScore(volcanoes: snap.volcanoes, at: pt).bitPattern)
        XCTAssertEqual(live.tropical.bitPattern, HazardFeedScores.tropicalScore(storms: snap.storms, at: pt).bitPattern)
        XCTAssertEqual(live.tsunami.bitPattern, HazardFeedScores.tsunamiScore(events: snap.tsunamis, at: pt).bitPattern)
        XCTAssertEqual(live.convective.bitPattern, HazardFeedScores.outlookScore(zones: snap.spcZones, at: pt).bitPattern)
        XCTAssertGreaterThan(live.convective, 0, "the point is inside the outlook polygon")
    }

    func testClippingDropsOnlyWhatCannotScore() {
        // Inside, just outside the margin, just inside it, and a ring
        // crossing the box. The margin is measured from the box's EDGE
        // (maxLat 39.5), not from the sample point.
        let far = 39.5 + LiveHazardSnapshot.clipMarginDegrees + 0.5
        let near = 39.5 + LiveHazardSnapshot.clipMarginDegrees - 0.5
        let snap = LiveHazardSnapshot(
            hotspots: [(lat: 39.0, lon: -105.0, frp: 1), (lat: far, lon: -105.0, frp: 1), (lat: near, lon: -105.0, frp: 1)],
            perimeters: [[CLLocationCoordinate2D(latitude: 38.0, longitude: -120.0),
                          CLLocationCoordinate2D(latitude: 40.0, longitude: -120.0),
                          CLLocationCoordinate2D(latitude: 40.0, longitude: -100.0)],   // spans the box
                         [CLLocationCoordinate2D(latitude: 60.0, longitude: -105.0),
                          CLLocationCoordinate2D(latitude: 61.0, longitude: -105.0),
                          CLLocationCoordinate2D(latitude: 61.0, longitude: -104.0)]],  // far north
            tsunamis: [(lat: 39.0, lon: -105.0 - LiveHazardSnapshot.clipMarginDegrees - 1, level: "warning")])
        let c = snap.clipped(minLat: 38.5, minLon: -105.5, maxLat: 39.5, maxLon: -104.5)
        XCTAssertEqual(c.hotspots.count, 2)
        XCTAssertEqual(c.perimeters.count, 1)
        XCTAssertTrue(c.tsunamis.isEmpty)
        // A kept point inside scores identically before and after clipping.
        XCTAssertEqual(HazardFeedScores.live(at: pt, snapshot: c), HazardFeedScores.live(at: pt, snapshot: snap))
    }

    func testTheMarginExceedsEveryScorerRadius() {
        // tsunamiScore reaches 500 km; six degrees of latitude is 667 km.
        XCTAssertGreaterThan(LiveHazardSnapshot.clipMarginDegrees * 111_320, 500_000)
    }
}
