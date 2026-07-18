// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// The transfer proof the user asked for: every expected value in
/// RiskEquationVectors.swift was computed BY the original R functions
/// (R/scoring.R piecewise_score / temperature_risk, R/forecast.R weights).
/// The Swift ports must match to double precision.
final class RiskEquationsTests: XCTestCase {

    func testPiecewiseScoreMatchesR() {
        for (v, lo, me, hi, expected) in RiskEquationVectors.piecewise {
            let got = RiskEquations.piecewiseScore(v, low: lo, medium: me, high: hi)
            XCTAssertEqual(got, expected, accuracy: 1e-12,
                           "piecewise(\(v), \(lo), \(me), \(hi))")
        }
    }

    func testTemperatureRiskMatchesR() {
        for (t, cl, ch, rl, rh, expected) in RiskEquationVectors.temperature {
            let got = RiskEquations.temperatureRisk(
                tempF: t, comfortLowF: cl, comfortHighF: ch,
                recordLowF: rl, recordHighF: rh)
            XCTAssertEqual(got, expected, accuracy: 1e-12, "temperature(\(t))")
        }
    }

    func testForecastCompositeMatchesR() {
        for (a, b, c, expected) in RiskEquationVectors.forecastComposite {
            XCTAssertEqual(RiskEquations.forecastComposite(temp: a, wind: b, pop: c),
                           expected, accuracy: 1e-12)
        }
    }

    func testFamilyWeightsMatchR() {
        // R/families.R:471 — exact values.
        XCTAssertEqual(RiskEquations.familyWeights["wind"], 0.64)
        XCTAssertEqual(RiskEquations.familyWeights["flood"], 0.96)
        XCTAssertEqual(RiskEquations.familyWeights["convective"], 0.92)
        XCTAssertEqual(RiskEquations.familyWeights["radiation"], 0.52)
    }

    func testNoisyOrShape() {
        // 1 − (1−0.96·0.5)(1−0.64·0.5) = 1 − 0.52·0.68
        let got = RiskEquations.noisyOr([("flood", 0.5), ("wind", 0.5)])
        XCTAssertEqual(got, 1 - 0.52 * 0.68, accuracy: 1e-12)
        XCTAssertEqual(RiskEquations.noisyOr([]), 0)
    }
}
