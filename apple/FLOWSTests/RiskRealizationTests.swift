// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// The primary/secondary realization model (`RiskEquations.realizedRisk`):
/// primary hazards (you're in the fire / water over the road / ground moving)
/// can reach Red alone; secondary predictors (wind, heat, cold, haze, UV) only
/// AMPLIFY a realized primary and, on their own, never read life-threatening.
/// These assert the design properties, not byte-identity to a prior version —
/// this is new semantics replacing `max(composite, worstFamily)`.
final class RiskRealizationTests: XCTestCase {
    private let RED = 0.8751     // RISK_RED_MIN
    private let GREEN = 0.3980   // RISK_GREEN_MIN

    // A pile of secondary predictors — even ALL maxed — must never read Red.
    func testSecondariesAloneNeverReachRed() {
        let r = RiskEquations.realizedRisk(
            ["wind": 1, "heat": 1, "cold": 1, "air": 1, "radiation": 1])
        XCTAssertLessThanOrEqual(r, RiskEquations.secondaryCeiling)
        XCTAssertLessThan(r, RED, "secondaries alone must stay below Red")
    }

    // The user's case: several small overlapping risks don't SUM to lethal.
    func testManySmallSecondariesDoNotCompoundToLethal() {
        let smalls: [String: Double] = [
            "wind": 0.4, "heat": 0.4, "cold": 0.4, "air": 0.4, "radiation": 0.4]
        XCTAssertLessThan(RiskEquations.realizedRisk(smalls), RED)
    }

    // A UV/air/wind reading, even at 100%, is not lethal-while-driving.
    func testMaxedSingleSecondaryIsAdvisoryNotLethal() {
        for fam in ["radiation", "air", "wind", "heat", "cold"] {
            XCTAssertLessThan(RiskEquations.realizedRisk([fam: 1.0]), RED,
                              "\(fam) at 100% must be an advisory, not Red")
        }
    }

    // A realized primary (observed event / detection) keeps its full severity
    // → Red on its own.
    func testRealizedPrimaryReachesRed() {
        for fam in ["fire", "qpf_flood", "seismic", "tsunami", "tropical", "volcanic"] {
            XCTAssertGreaterThanOrEqual(RiskEquations.realizedRisk([fam: 0.95]), RED,
                                        "a realized \(fam) must reach Red")
        }
    }

    // Forecasts/outlooks are predictors, not proof: an SPC severe-weather
    // OUTLOOK or an avalanche DANGER RATING advises but never turns the road Red
    // on its own — only a realized warning/closure (not yet wired) would.
    func testForecastOutlooksAreCappedNotRed() {
        XCTAssertLessThan(RiskEquations.realizedRisk(["convective": 1.0]), RED,
                          "an SPC OUTLOOK is a probability, not a tornado on the road")
        XCTAssertLessThan(RiskEquations.realizedRisk(["avalanche": 1.0]), RED,
                          "an avalanche DANGER RATING is a forecast, not an avalanche")
    }

    // Driving-safety split: a FORECAST (precip probability, snow prediction) is
    // a predictor, not a blocked road — capped advisory, never Red. But a
    // REALIZED flood (gauge over the road) is a primary → Red.
    func testForecastIsPredictorRealizedFloodIsPrimary() {
        XCTAssertLessThan(RiskEquations.realizedRisk(["precip": 1.0]), RED,
                          "rain PROBABILITY alone is not a lethal flood")
        XCTAssertLessThan(RiskEquations.realizedRisk(["winter": 1.0]), RED,
                          "a snow FORECAST is a prediction, not a blocked road")
        XCTAssertGreaterThanOrEqual(RiskEquations.realizedRisk(["qpf_flood": 0.95]), RED,
                                    "a realized gauge flood over the road IS Red")
    }

    // Predictors amplify the REALIZED hazard they predict: a gauge flood in
    // heavy rain reads worse than the gauge flood alone.
    func testPrecipAmplifiesRealizedFlood() {
        let floodOnly = RiskEquations.realizedRisk(["qpf_flood": 0.7])
        let floodInRain = RiskEquations.realizedRisk(["qpf_flood": 0.7, "precip": 0.9, "wind": 0.6])
        XCTAssertGreaterThan(floodInRain, floodOnly)
    }

    // Predictors SPIKE a realized primary: fire + fire-weather > fire alone,
    // and a near-realized fire in extreme fire-weather crosses into Red.
    func testPredictorsAmplifyRealizedPrimary() {
        let fireOnly = RiskEquations.realizedRisk(["fire": 0.7])
        let fireInWeather = RiskEquations.realizedRisk(["fire": 0.7, "wind": 0.9, "heat": 0.8])
        XCTAssertGreaterThan(fireInWeather, fireOnly, "fire-weather must amplify a realized fire")
        XCTAssertGreaterThanOrEqual(
            RiskEquations.realizedRisk(["fire": 0.85, "wind": 0.95, "heat": 0.9]), RED)
    }

    // With NO primary, predictors amplify NOTHING into Red — only advise.
    func testNoPrimaryMeansNoAmplificationToRed() {
        XCTAssertLessThan(
            RiskEquations.realizedRisk(["wind": 1.0, "heat": 1.0, "cold": 1.0]), RED)
    }

    // Two independent realized primaries compound above either alone.
    func testTwoPrimariesCompound() {
        let one = RiskEquations.realizedRisk(["qpf_flood": 0.7])
        let two = RiskEquations.realizedRisk(["qpf_flood": 0.7, "seismic": 0.7])
        XCTAssertGreaterThan(two, one)
        XCTAssertLessThanOrEqual(two, 1.0)
    }

    // The originally-reported shape: a moderate fire reads Green (elevated, not
    // 0%, not lethal); an active/inside-perimeter fire (1.0) reads Red.
    func testFireBandsMatchIntent() {
        let moderate = RiskEquations.realizedRisk(["fire": 0.5])
        XCTAssertGreaterThanOrEqual(moderate, GREEN)   // not 0%
        XCTAssertLessThan(moderate, RED)               // not lethal
        XCTAssertGreaterThanOrEqual(RiskEquations.realizedRisk(["fire": 1.0]), RED)
    }

    // The derived `environmental` composite (and any unknown key) is ignored, so
    // it can't double-count the temp/wind/pop its constituents already carry.
    func testDerivedKeysIgnored() {
        let withEnv = RiskEquations.realizedRisk(["fire": 0.6, "environmental": 0.9])
        let withoutEnv = RiskEquations.realizedRisk(["fire": 0.6])
        XCTAssertEqual(withEnv, withoutEnv)
    }

    // NWS alert events classify to the right family, and — via that family's
    // set membership — the right tier. In-progress-danger WARNINGS are primaries
    // (Red-capable); watches/advisories/condition warnings are predictors. This
    // is what lets the route band alerts exactly as the map does.
    func testAlertClassification() {
        // realized, in-progress danger → PRIMARY family (can reach Red)
        for (ev, fam) in [("Tornado Warning", "storm"),
                          ("Severe Thunderstorm Warning", "storm"),
                          ("Flash Flood Warning", "qpf_flood"),
                          ("Flood Warning", "qpf_flood"),
                          ("Tsunami Warning", "tsunami"),
                          ("Hurricane Warning", "tropical")] {
            XCTAssertEqual(RiskEquations.alertFamily(ev), fam, "\(ev)")
            XCTAssertTrue(RiskEquations.primaryFamilies.contains(fam))
            XCTAssertGreaterThanOrEqual(RiskEquations.realizedRisk([fam: 0.9]), RED,
                                        "a realized \(ev) must reach Red")
        }
        // forecasts / watches / condition warnings → PREDICTOR (never Red alone)
        for ev in ["Winter Storm Warning", "Blizzard Warning", "Ice Storm Warning",
                   "High Wind Warning", "Red Flag Warning", "Excessive Heat Warning",
                   "Wind Chill Warning", "Flood Watch", "Severe Thunderstorm Watch",
                   "Tornado Watch", "Air Quality Alert"] {
            guard let fam = RiskEquations.alertFamily(ev) else {
                XCTFail("\(ev) should classify"); continue
            }
            XCTAssertTrue(RiskEquations.secondaryFamilies.contains(fam),
                          "\(ev) → \(fam) must be a predictor")
            XCTAssertLessThan(RiskEquations.realizedRisk([fam: 1.0]), RED,
                              "\(ev) alone must not reach Red")
        }
    }

    // Temperature σ-gate: only UNUSUAL deviations (> ~1σ = (record−comfort)/3
    // past the comfort band) present on the map; ordinary warm days don't.
    func testTemperatureAnomalyGate() {
        // Marine climate: comfort 45–72, records 12/106 → σ_hot ≈ 11.3°F.
        func hot(_ t: Double) -> Bool {
            RiskEquations.temperatureAnomalous(
                tempF: t, comfortLowF: 45, comfortHighF: 72, recordLowF: 12, recordHighF: 106)
        }
        XCTAssertFalse(hot(75), "3°F over comfort is an ordinary warm day")
        XCTAssertFalse(hot(80), "still inside 1σ")
        XCTAssertTrue(hot(90), "well past 1σ — genuinely unusual heat")
        XCTAssertFalse(hot(60), "inside the comfort band")
        // Cold side: σ_cold = (45−12)/3 = 11 → 30°F is anomalous, 40°F is not.
        XCTAssertTrue(RiskEquations.temperatureAnomalous(
            tempF: 30, comfortLowF: 45, comfortHighF: 72, recordLowF: 12, recordHighF: 106))
        XCTAssertFalse(RiskEquations.temperatureAnomalous(
            tempF: 40, comfortLowF: 45, comfortHighF: 72, recordLowF: 12, recordHighF: 106))
        XCTAssertFalse(RiskEquations.temperatureAnomalous(
            tempF: .nan, comfortLowF: 45, comfortHighF: 72, recordLowF: 12, recordHighF: 106))
    }

    // Relative-elevation flood amplifier: valley floor in heavy rain amplifies
    // most; ridge amplifies none; no rain → no amplification; flat terrain or
    // missing elevation → rain-only bump; multiplier stays in [1, 2].
    func testFloodElevationMultiplier() {
        func m(_ e: Double?, lo: Double?, hi: Double?, q: Double?) -> Double {
            RiskEquations.floodElevationMultiplier(
                sampleElevation: e, minElevation: lo, maxElevation: hi, qpfInches: q)
        }
        XCTAssertEqual(m(100, lo: 100, hi: 500, q: 2.0), 2.0, accuracy: 1e-9,
                       "valley floor + 2in rain = full 2× amplification")
        XCTAssertEqual(m(500, lo: 100, hi: 500, q: 2.0), 1.0, accuracy: 1e-9,
                       "ridge top amplifies nothing")
        XCTAssertEqual(m(300, lo: 100, hi: 500, q: 2.0), 1.5, accuracy: 1e-9)
        XCTAssertEqual(m(100, lo: 100, hi: 500, q: 0), 1.0, "no rain, no amplification")
        XCTAssertEqual(m(100, lo: 100, hi: 500, q: nil), 1.0)
        XCTAssertEqual(m(nil, lo: nil, hi: nil, q: 2.0), 1.5, accuracy: 1e-9,
                       "no elevation data: rain-only mid bump")
        XCTAssertEqual(m(2500, lo: 2400, hi: 2404, q: 1.0), 1.25, accuracy: 1e-9,
                       "flat corridor (<5 m relief): terrain signal ignored")
        // The MOUNTAIN TOWN case: high absolute elevation, but the LOCAL low.
        XCTAssertGreaterThan(m(2400, lo: 2400, hi: 2900, q: 1.5),
                             m(2900, lo: 2400, hi: 2900, q: 1.5),
                             "an 8,000 ft valley floor still floods relative to its own terrain")
        for q in [0.1, 1.0, 5.0] {
            let v = m(200, lo: 100, hi: 500, q: q)
            XCTAssertGreaterThanOrEqual(v, 1); XCTAssertLessThanOrEqual(v, 2)
        }
    }

    // A DOT-reported road closure is PROOF — the realized blocked-road primary
    // that bands Red on its own (uncleared snow, washout, slide).
    func testClosureIsRealizedPrimary() {
        XCTAssertTrue(RiskEquations.primaryFamilies.contains("closure"))
        XCTAssertGreaterThanOrEqual(RiskEquations.realizedRisk(["closure": 1.0]), RED)
        // Distance model: on the closure = 1; ~1 km away decays; 3 km = 0.
        let closures = [(lat: 43.0, lon: -89.0)]
        XCTAssertEqual(HazardFeedScores.closureScore(
            closures: closures, at: CLLocationCoordinate2D(latitude: 43.0, longitude: -89.0)), 1.0)
        let oneKm = CLLocationCoordinate2D(latitude: 43.009, longitude: -89.0)
        let s = HazardFeedScores.closureScore(closures: closures, at: oneKm)
        XCTAssertGreaterThan(s, 0.2); XCTAssertLessThan(s, 1.0)
        let farPt = CLLocationCoordinate2D(latitude: 43.03, longitude: -89.0)
        XCTAssertEqual(HazardFeedScores.closureScore(closures: closures, at: farPt), 0)
    }

    // Ticket links: long-haul modes carry a carrier booking URL; local modes
    // fall back to the station/agency page and always name the exact ride.
    func testTransitTickets() {
        let amtrak = TransitTickets.ticket(mode: "Amtrak", board: "Columbia",
                                           alight: "Chicago Union", stationURL: nil)
        XCTAssertTrue(amtrak.label.contains("Columbia → Chicago Union"))
        XCTAssertEqual(amtrak.url?.host, "www.amtrak.com")
        let grey = TransitTickets.ticket(mode: "Greyhound", board: "A", alight: "B",
                                         stationURL: nil)
        XCTAssertEqual(grey.url?.host, "www.greyhound.com")
        let agency = URL(string: "https://www.cityliner.org")!
        let local = TransitTickets.ticket(mode: "Bus", board: "5th St", alight: "Main",
                                          stationURL: agency)
        XCTAssertEqual(local.url, agency)
        XCTAssertTrue(local.label.contains("5th St → Main"))
    }

    // Bounds + degenerate input across the full range.
    func testBoundsAndEmpty() {
        XCTAssertEqual(RiskEquations.realizedRisk([:]), 0)
        for fam in ["fire", "wind", "qpf_flood", "radiation", "seismic", "cold"] {
            for s in stride(from: -0.5, through: 1.5, by: 0.1) {
                let r = RiskEquations.realizedRisk([fam: s])
                XCTAssertGreaterThanOrEqual(r, 0)
                XCTAssertLessThanOrEqual(r, 1)
            }
        }
    }
}
