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

/// The corridor blend is one Rust call (`RouteBlend.blend`). These hold it
/// to the Swift band input the other tests pin (`RiskEquations.bandInput`),
/// so the two can never drift apart, and check what a road must do: a fire,
/// a danger alert or a closed road on it is Red; nothing on it is not.
final class RouteBlendTests: XCTestCase {
    private let pt = CLLocationCoordinate2D(latitude: 39.0, longitude: -105.0)

    private func sample(_ event: String? = nil, _ severity: Double = 0) -> RiskSample {
        RiskSample(coordinate: pt, risk: severity, worstEvent: event)
    }

    func testNoCheckPointsIsAnEmptyAnswer() {
        let a = RouteBlend.blend(samples: [], field: nil, live: .empty)
        XCTAssertTrue(a.risks.isEmpty)
        XCTAssertTrue(a.peaks.isEmpty)
        XCTAssertEqual(a.identifiedSum, 0)
        XCTAssertFalse(a.liveUnchecked)
    }

    func testAQuietRoadIsScoredAndChecked() {
        let a = RouteBlend.blend(samples: [sample(), sample()], field: nil, live: .empty)
        XCTAssertEqual(a.risks.count, 2)
        XCTAssertFalse(a.liveUnchecked)
        XCTAssertTrue(a.peaks.isEmpty)
        for r in a.risks { XCTAssertEqual(FlowsCore.riskBand(score: r), .clear, "\(r)") }
    }

    func testOnePointMatchesTheSwiftBandInputBitForBit() {
        let snap = LiveHazardSnapshot(hotspots: [(lat: 39.0, lon: -105.0, frp: 500)])
        let live = HazardFeedScores.live(at: pt, snapshot: snap).bandInputContribution
        let cases: [(String?, Double, LiveHazardSnapshot?, [String: Double])] = [
            (nil, 0, nil, [:]),
            ("Heat Advisory", 0.5, nil, [:]),
            ("Tornado Warning", 0.9, nil, [:]),
            ("Evacuation Immediate", 0.8, nil, [:]),
            ("Winter Storm Watch", 0.6, nil, [:]),
            (nil, 0, snap, live),
            ("Red Flag Warning", 0.7, snap, live),
        ]
        for (event, severity, snapshot, contribution) in cases {
            let want = RiskEquations.realizedRisk(
                RiskEquations.bandInput(
                    field: { _ in 0 }, onDevice: [:], alertEvent: event, alertSeverity: severity,
                    live: contribution))
            let got = RouteBlend.blend(samples: [sample(event, severity)], field: nil, live: snapshot)
            XCTAssertEqual(got.risks.first?.bitPattern, want.bitPattern, "\(event ?? "no alert")")
        }
    }

    func testAFieldRowAndAForecastMatchTheSwiftBandInput() {
        let families = ["environmental", "wind", "qpf_flood", "heat", "air"]
        let scores = [0.3, 0.4, 0.2, 0.6, 0.5]
        let field = RiskField(
            generated: "test", families: families,
            entries: [
                RiskFieldService.ZipEntry(
                    zip: "80135", centroid: pt, scores: scores, summary: nil, ring: nil)
            ])
        XCTAssertNotNil(field)
        let c = ForecastConditions(
            temperatureF: 96, windMph: 38, windFromDegrees: nil, popPercent: 70, qpfInches: nil)
        let dev = c.predictorFamilies(
            latitude: pt.latitude, longitude: pt.longitude, elevationMeters: 1800)
        let want = RiskEquations.realizedRisk(
            RiskEquations.bandInput(
                field: { fam in families.firstIndex(of: fam).map { scores[$0] } ?? 0 },
                onDevice: dev, alertEvent: nil, alertSeverity: 0))
        let got = RouteBlend.blend(samples: [sample()], onDevice: [0: (c, 1800)], field: field)
        XCTAssertEqual(got.risks.first?.bitPattern, want.bitPattern)
        XCTAssertEqual(got.identifiedSum, 0.3)
        XCTAssertEqual(got.peaks["wind"], max(0.4, dev["wind"] ?? 0))
    }

    func testAFireOnTheRoadIsRedAndNamed() {
        let snap = LiveHazardSnapshot(hotspots: [(lat: 39.0, lon: -105.0, frp: 500)])
        let a = RouteBlend.blend(samples: [sample()], field: nil, live: snap)
        XCTAssertEqual(FlowsCore.riskBand(score: a.risks.first ?? 0), .red)
        XCTAssertGreaterThan(a.peaks["fire"] ?? 0, 0)
        XCTAssertFalse(a.liveUnchecked)
        // The same road with no live feeds handed in is not Red.
        let b = RouteBlend.blend(samples: [sample()], field: nil)
        XCTAssertNotEqual(FlowsCore.riskBand(score: b.risks.first ?? 1), .red)
        XCTAssertNil(b.peaks["fire"])
    }

    func testAClosedRoadOnTheRoadIsRed() {
        let closed = HazardFeedScores.PreparedPoints([(lat: 39.0, lon: -105.0)])
        let a = RouteBlend.blend(samples: [sample()], field: nil, closures: closed)
        XCTAssertEqual(FlowsCore.riskBand(score: a.risks.first ?? 0), .red)
    }

    func testAPointBorrowsItsNeighboursForecast() {
        let windy = ForecastConditions(
            temperatureF: 60, windMph: 70, windFromDegrees: nil, popPercent: 0, qpfInches: nil)
        let road = [sample(), sample(), sample(), sample()]
        let a = RouteBlend.blend(samples: road, onDevice: [0: (windy, nil)], field: nil)
        // Points 1 and 2 are within two of the fetched point; point 3 is not.
        XCTAssertEqual(a.risks[1].bitPattern, a.risks[0].bitPattern)
        XCTAssertEqual(a.risks[2].bitPattern, a.risks[0].bitPattern)
        XCTAssertLessThan(a.risks[3], a.risks[0])
        XCTAssertGreaterThan(a.peaks["wind"] ?? 0, 0)
    }
}
