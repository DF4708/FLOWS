// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// What counts as shelter from a given hazard, and how long to sit it out.
final class ShelterPolicyTests: XCTestCase {

    // MARK: matching the shelter to the threat

    func testAnOrdinaryThunderstormIsWaitedOutInAnyOpenBuilding() {
        // The bug this exists for: a driver was told there was no shelter on
        // a route lined with open restaurants, because the search asked for
        // "storm shelter" — a facility that barely exists as a mapped place.
        let kind = ShelterPolicy.kind(forEvent: "Severe Thunderstorm Warning",
                                      severityScore: 0.65)
        XCTAssertEqual(kind, .anyBuilding)
        XCTAssertTrue(kind.searchQueries.contains("restaurant"))
    }

    func testAViolentStormNeedsSomethingSolid() {
        XCTAssertEqual(ShelterPolicy.kind(forEvent: "Severe Thunderstorm Warning",
                                          severityScore: 0.85), .sturdyBuilding)
    }

    func testATornadoOnTheGroundIsNotAnApplebees() {
        XCTAssertEqual(ShelterPolicy.kind(forEvent: "Tornado Warning",
                                          severityScore: 0.95), .officialShelter)
    }

    func testATornadoWATCHIsStillOnlyGetReady() {
        // A watch means conditions are favourable, not that one is coming
        // down the road — a solid building is the proportionate answer.
        XCTAssertEqual(ShelterPolicy.kind(forEvent: "Tornado Watch",
                                          severityScore: 0.7), .sturdyBuilding)
    }

    func testAnEvacuationMeansLeave() {
        for event in ["Evacuation Order", "Wildfire Evacuation",
                      "Radiological Hazard Warning"] {
            XCTAssertEqual(ShelterPolicy.kind(forEvent: event, severityScore: 0.9),
                           .officialShelter, event)
        }
    }

    func testVisibilityHazardsAreSolvedByStopping() {
        // Fog and heavy rain hurt because of driving, not because buildings
        // fail. Pulling over IS the remedy, and the vehicle is the shelter.
        for event in ["Dense Fog Advisory", "Heavy Rain Warning",
                      "Blowing Dust Advisory"] {
            XCTAssertEqual(ShelterPolicy.kind(forEvent: event, severityScore: 0.7),
                           .inVehicle, event)
        }
    }

    func testTheAdviceForEachKindIsPlainAndDifferent() {
        let all: [ShelterPolicy.Kind] = [.inVehicle, .anyBuilding,
                                         .sturdyBuilding, .officialShelter]
        XCTAssertEqual(Set(all.map(\.advice)).count, all.count)
        for k in all { XCTAssertFalse(k.advice.isEmpty) }
    }

    func testEveryKindHasSomewhereRealToLookFor() {
        for k in [ShelterPolicy.Kind.inVehicle, .anyBuilding,
                  .sturdyBuilding, .officialShelter] {
            XCTAssertFalse(k.searchQueries.isEmpty, k.rawValue)
            // Each term is its own search — MKLocalSearch matches a query as
            // a phrase, so a term with several words in it must be a real
            // phrase ("public library"), never a list of alternatives.
            for q in k.searchQueries {
                XCTAssertLessThanOrEqual(q.split(separator: " ").count, 3, q)
            }
        }
    }

    // MARK: how long to wait

    func testTheWaitIsTheAlertsOwnRemainingLife() {
        let now = Date()
        let wait = ShelterPolicy.waitSeconds(
            expires: now.addingTimeInterval(40 * 60), now: now)
        XCTAssertEqual(wait, 40 * 60, accuracy: 1)
    }

    func testAnAlreadyExpiredAlertStillGivesAMinuteOrTwo() {
        let now = Date()
        XCTAssertEqual(ShelterPolicy.waitSeconds(
            expires: now.addingTimeInterval(-60), now: now),
                       ShelterPolicy.minimumWait)
    }

    func testAVeryLongWarningIsCappedToSomethingAPersonWillSitThrough() {
        let now = Date()
        XCTAssertEqual(ShelterPolicy.waitSeconds(
            expires: now.addingTimeInterval(12 * 3600), now: now),
                       ShelterPolicy.maximumWait)
    }

    func testNoPublishedExpiryGetsAnHonestDefault() {
        let wait = ShelterPolicy.waitSeconds(expires: nil)
        XCTAssertEqual(wait, ShelterPolicy.unknownExpiryWait)
        // …and it does not round UP into an hour the driver never agreed to.
        XCTAssertLessThan(wait, 3600)
    }

    // MARK: the countdown

    func testTheCountdownReadsLikeAClock() {
        XCTAssertEqual(ShelterPolicy.countdownText(45), "0:45")
        XCTAssertEqual(ShelterPolicy.countdownText(9 * 60 + 5), "9:05")
        XCTAssertEqual(ShelterPolicy.countdownText(3600 + 5 * 60), "1 h 05 min")
    }

    func testTheCountdownNeverGoesNegative() {
        XCTAssertEqual(ShelterPolicy.countdownText(-30), "0:00")
    }

    // MARK: the week-away blind spot

    func testAWeekAwayMakesTheFuelGaugeStale() {
        let now = Date()
        XCTAssertTrue(StaleGauge.wentStale(
            lastUsed: now.addingTimeInterval(-8 * 86_400), now: now))
        XCTAssertFalse(StaleGauge.wentStale(
            lastUsed: now.addingTimeInterval(-2 * 86_400), now: now))
    }

    func testAFirstRunHasNoStaleGaugeToAskAbout() {
        // Nothing was ever recorded, so nothing can have gone stale — asking
        // a brand-new user whether they just refuelled is nonsense.
        XCTAssertFalse(StaleGauge.wentStale(lastUsed: nil))
    }
}

/// What the app tells a driver to DO about each kind of alert.
final class AlertActionTests: XCTestCase {

    func testAChildAbductionIsAThingToWatchForNotShelterFrom() {
        // The bug this exists for: an AMBER alert offered a "Shelter here"
        // button and advised "get inside any open building". You do not take
        // cover from a child abduction — you watch the road and call 911.
        for event in ["Child Abduction Emergency", "AMBER Alert",
                      "Blue Alert", "Silver Alert"] {
            XCTAssertEqual(ImminentAlerts.classify(event: event,
                                                   severityScore: 0.95,
                                                   expires: nil), .lookout, event)
        }
    }

    func testARealHazardStillOffersShelter() {
        XCTAssertEqual(ImminentAlerts.classify(event: "Tornado Warning",
                                               severityScore: 0.95,
                                               expires: nil), .shelter)
    }

    func testALookoutIsCheckedBeforeTheLifeSafetySweep() {
        // "Law enforcement warning" is on BOTH lists; the lookout reading
        // has to win, or it comes back as a shelter alert again.
        XCTAssertEqual(ImminentAlerts.classify(event: "Law Enforcement Warning",
                                               severityScore: 0.9,
                                               expires: nil), .lookout)
    }

    func testATransientStormStillSuggestsWaitingItOut() {
        XCTAssertEqual(
            ImminentAlerts.classify(event: "Wind Advisory", severityScore: 0.7,
                                    expires: Date().addingTimeInterval(3600)),
            .restArea)
    }

    func testQuietWeatherIsJustMonitored() {
        XCTAssertEqual(ImminentAlerts.classify(event: "Frost Advisory",
                                               severityScore: 0.3,
                                               expires: nil), .monitor)
    }
}
