// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation
import XCTest
// The test target compiles the app sources directly; there is no FLOWS module to import.

/// The owner's rule for alerts: specific to the threat, never spam, and the
/// most immediate risk to the driver's life first. The classifier lives in
/// rust/flows-core (alerts.rs); these tests exercise it through the same
/// facades the app calls.
final class AlertPrecedenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testATornadoWarningOutranksAGraverSoundingFloodAdvisory() {
        // CAP severity alone would have picked the advisory (0.95 > 0.72).
        let tornado = ImminentAlerts.threatRank(event: "Tornado Warning", severityScore: 0.72)
        let advisory = ImminentAlerts.threatRank(event: "Flood Advisory", severityScore: 0.95)
        XCTAssertGreaterThan(tornado, advisory)
        let candidates = [
            ImminentAlerts.Candidate(alertID: "advisory", distanceMeters: 2_000, severityScore: 0.95, threatRank: advisory),
            ImminentAlerts.Candidate(alertID: "tornado", distanceMeters: 9_000, severityScore: 0.72, threatRank: tornado),
        ]
        XCTAssertEqual(ImminentAlerts.firstImminent(candidates, speedMps: 29)?.alertID, "tornado")
    }

    func testALookoutWinsOnlyAnEmptyField() {
        let amber = ImminentAlerts.threatRank(event: "AMBER Alert", severityScore: 0.95)
        let wind = ImminentAlerts.threatRank(event: "Wind Advisory", severityScore: 0.45)
        XCTAssertEqual(amber, 0)
        XCTAssertGreaterThan(wind, amber)
        let both = [
            ImminentAlerts.Candidate(alertID: "amber", distanceMeters: 500, severityScore: 0.95, threatRank: amber),
            ImminentAlerts.Candidate(alertID: "wind", distanceMeters: 5_000, severityScore: 0.45, threatRank: wind),
        ]
        XCTAssertEqual(ImminentAlerts.firstImminent(both, speedMps: 29)?.alertID, "wind")
        XCTAssertEqual(ImminentAlerts.firstImminent([both[0]], speedMps: 29)?.alertID, "amber")
        // and a lookout is still classified as one
        XCTAssertEqual(ImminentAlerts.classify(event: "AMBER Alert", severityScore: 0.95, expires: nil, now: now), .lookout)
    }

    func testFireWeatherIsAPredictorNotAReasonToShelter() {
        // A Red Flag Warning used to sit on the life-safety list and command
        // "shelter now" like a tornado. It is fire weather.
        XCTAssertFalse(ImminentAlerts.isLifeSafetyEvent("Red Flag Warning"))
        XCTAssertEqual(ImminentAlerts.classify(event: "Red Flag Warning", severityScore: 0.72,
                                               expires: now.addingTimeInterval(3600), now: now), .restArea)
        XCTAssertEqual(ImminentAlerts.threatRank(event: "Red Flag Warning", severityScore: 0.72), 1)
        // An actual fire still is.
        XCTAssertTrue(ImminentAlerts.isLifeSafetyEvent("Fire Warning"))
        XCTAssertEqual(ImminentAlerts.classify(event: "Fire Warning", severityScore: 0.3, expires: nil, now: now), .shelter)
    }

    func testATornadoEmergencyIsLifeSafety() {
        XCTAssertTrue(ImminentAlerts.isLifeSafetyEvent("Tornado Emergency"))
        XCTAssertEqual(ImminentAlerts.threatRank(event: "Tornado Emergency", severityScore: 0.5), 3)
    }

    func testRanksAreOrderedByThreatToLife() {
        let ranks = [
            ("Tornado Warning", 0.72), ("Flash Flood Warning", 0.72), ("Wind Advisory", 0.72), ("Silver Alert", 0.95),
        ].map { ImminentAlerts.threatRank(event: $0.0, severityScore: $0.1) }
        XCTAssertEqual(ranks, [3, 2, 1, 0])
        // A Red CAP severity lifts an otherwise plain alert to a realized rank;
        // below that, a Frost Advisory is a classified predictor (the cold
        // family) and ranks 1, and only an event nothing classifies ranks 0.
        XCTAssertEqual(ImminentAlerts.threatRank(event: "Frost Advisory", severityScore: 0.95), 2)
        XCTAssertEqual(ImminentAlerts.threatRank(event: "Frost Advisory", severityScore: 0.3), 1)
        XCTAssertEqual(ImminentAlerts.threatRank(event: "Special Marine Bulletin", severityScore: 0.3), 0)
    }

    func testShelterAndActionStillFollowTheTables() {
        XCTAssertEqual(ShelterPolicy.kind(forEvent: "Dust Storm Warning", severityScore: 0.95), .inVehicle)
        XCTAssertEqual(ShelterPolicy.kind(forEvent: "Tornado Watch", severityScore: 0.7), .sturdyBuilding)
        XCTAssertEqual(ShelterPolicy.kind(forEvent: "Flash Flood Emergency", severityScore: 0.3), .officialShelter)
        XCTAssertEqual(ImminentAlerts.classify(event: "Wind Advisory", severityScore: 0.7,
                                               expires: now.addingTimeInterval(3600), now: now), .restArea)
        XCTAssertEqual(ImminentAlerts.classify(event: "Wind Advisory", severityScore: 0.7,
                                               expires: now.addingTimeInterval(-60), now: now), .monitor)
    }

    func testEquallyRankedAlertsFallBackToSeverityThenDistance() {
        let r = ImminentAlerts.threatRank(event: "Flash Flood Warning", severityScore: 0.72)
        let c = [
            ImminentAlerts.Candidate(alertID: "near-mild", distanceMeters: 1_000, severityScore: 0.72, threatRank: r),
            ImminentAlerts.Candidate(alertID: "far-severe", distanceMeters: 8_000, severityScore: 0.88, threatRank: r),
            ImminentAlerts.Candidate(alertID: "nearest-severe", distanceMeters: 3_000, severityScore: 0.88, threatRank: r),
        ]
        XCTAssertEqual(ImminentAlerts.firstImminent(c, speedMps: 29)?.alertID, "nearest-severe")
    }
}
