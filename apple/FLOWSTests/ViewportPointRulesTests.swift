// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

// The test target compiles the app sources directly; there is no FLOWS module to import.

/// What the map's sweep makes of one point is computed in Rust behind
/// `ViewportPointRules`. These hold the rules a driver sees: which points
/// show, what names the badge, and what the risk band is fed.
final class ViewportPointRulesTests: XCTestCase {
    private typealias Rules = ViewportPointRules

    private func point(
        _ shown: [String: Double], flood: Double = 0, storms: Double = 0, precip: Double = 0,
        alert: String? = nil, severity: Double = 0, closed: Double = 0
    ) -> Rules.Point {
        Rules.point(
            families: shown, live: Rules.Live(convective: storms, floodRealized: flood), precipRisk: precip,
            alertFamily: alert, alertSeverity: severity, closed: closed)
    }

    func testAQuietPointDoesNotShowAndOneFamilyIsEnough() {
        XCTAssertNil(Rules.displayFamilies(score: 0.24, forecast: ["wind": 0.2], live: Rules.Live()))
        XCTAssertNotNil(Rules.displayFamilies(score: 0.25, forecast: [:], live: Rules.Live()))
        // Fire, quake and flood are always listed, even at zero.
        XCTAssertEqual(
            Rules.displayFamilies(score: 0, forecast: ["wind": 0.25], live: Rules.Live()),
            ["wind": 0.25, "fire": 0, "seismic": 0, "qpf_flood": 0])
        // A live reading alone shows the point.
        XCTAssertNotNil(Rules.displayFamilies(score: 0, forecast: [:], live: Rules.Live(tsunami: 0.25)))
    }

    func testLiveReadingsLieOverTheForecast() {
        let live = Rules.Live(
            fire: 0.7, convective: 0.5, spaceRadiation: 0.1, floodRealized: 0.3, air: 0, uv: 0.4)
        let shown = Rules.displayFamilies(
            score: 0, forecast: ["fire": 0.1, "qpf_flood": 0.6, "convective": 0.2, "heat": 0.3], live: live)
        XCTAssertEqual(
            shown,
            [
                // The fire perimeter replaces the forecast; flood and storms keep the worse of the two.
                "fire": 0.7, "qpf_flood": 0.6, "convective": 0.5, "heat": 0.3, "seismic": 0,
                // Space weather and UV share a family; an air reading of zero is still a reading.
                "radiation": 0.4, "air": 0,
            ])
    }

    func testRainChanceAloneIsNotAFlood() {
        XCTAssertEqual(point(["qpf_flood": 0.6], flood: 0.44, precip: 0.6).icon, .rainChance)
        let flooded = point(["qpf_flood": 0.6], flood: 0.45, precip: 0.6)
        XCTAssertEqual(flooded.icon, .family("qpf_flood"))
        // The band is fed the gauges, not the rain chance.
        XCTAssertEqual(flooded.bandInput["qpf_flood"], 0.45)
        XCTAssertEqual(flooded.bandInput["precip"], 0.6)
        XCTAssertEqual(flooded.bandInput.count, 15)
    }

    func testNothingElevatedLeavesTheNameToTheForecast() {
        // The blended composite is not a hazard and never names the badge.
        XCTAssertEqual(point(["environmental": 0.9, "wind": 0.3]).icon, .forecast)
        XCTAssertEqual(point([:]).icon, .forecast)
    }

    func testAWarningNamesTheBadgeAndKeepsItOverAClosure() {
        let both = point(["wind": 0.5], alert: "storm", severity: 0.6, closed: 0.9)
        XCTAssertEqual(both.icon, .alert)
        XCTAssertEqual(both.bandInput["storm"], 0.6)
        XCTAssertEqual(both.bandInput["closure"], 0.9)
        XCTAssertEqual(both.families, ["wind": 0.5, "closure": 0.9])
        // Under the floor the closure names it.
        XCTAssertEqual(point(["wind": 0.5], alert: "storm", severity: 0.59, closed: 0.9).icon, .closure)
        // A wind advisory is a predictor: it feeds the band and names nothing.
        let advisory = point(["wind": 0.5], alert: "wind", severity: 0.9, closed: 0.5)
        XCTAssertEqual(advisory.icon, .family("wind"))
        XCTAssertEqual(advisory.bandInput["wind"], 0.9)
    }

    func testARealizedPrimaryNamesTheBadgeOverAPredictor() {
        // Wind leads the display; the gauges are at Yellow.
        XCTAssertEqual(point(["wind": 0.9, "qpf_flood": 0.7], flood: 0.7).icon, .family("qpf_flood"))
        // Just under Yellow, the predictor keeps it.
        XCTAssertEqual(point(["wind": 0.9, "qpf_flood": 0.69], flood: 0.69).icon, .family("wind"))
        // A closure under its own floor, but at Yellow, still names it.
        XCTAssertEqual(point(["wind": 0.9], closed: 0.75).icon, .family("closure"))
    }

    func testEqualPrimariesGoToTheLowerName() {
        // It used to follow Dictionary order, which changes between launches.
        for _ in 0..<20 {
            XCTAssertEqual(point(["wind": 0.99, "tsunami": 0.8, "fire": 0.8]).icon, .family("fire"))
        }
    }
}
