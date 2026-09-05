// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
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

/// Reachability: a station you have already driven past is not an option.
final class FuelReachabilityTests: XCTestCase {
    private let here = CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40)

    private func north(_ km: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: here.latitude + km * 1000 / 111_320,
                               longitude: here.longitude)
    }

    func testAStationBehindTheVehicleIsNotReachable() {
        // The bug: the scan kept any station inside a straight-line radius
        // and called it "ahead", so pumps already passed counted toward
        // "you still have options" and the last-chance warning stayed quiet.
        XCTAssertFalse(FuelWarning.isReachable(
            station: north(-8), from: here, courseDegrees: 0, routeAhead: []))
    }

    func testAStationAheadIsReachable() {
        XCTAssertTrue(FuelWarning.isReachable(
            station: north(8), from: here, courseDegrees: 0, routeAhead: []))
    }

    func testAStationJustOffABendStaysReachable() {
        // 60° off the nose is still the road ahead, not behind.
        let offBend = CLLocationCoordinate2D(latitude: here.latitude + 0.04,
                                             longitude: here.longitude + 0.06)
        XCTAssertTrue(FuelWarning.isReachable(
            station: offBend, from: here, courseDegrees: 0, routeAhead: []))
    }

    func testWithARouteTheROUTEDecidesNotTheHeading() {
        // Route runs south while the vehicle momentarily points north (a
        // turn in progress). The station on the route is still reachable.
        XCTAssertTrue(FuelWarning.isReachable(
            station: north(-8), from: here, courseDegrees: 0,
            routeAhead: [north(-4), north(-8), north(-12)]))
    }

    func testAStationFarOffTheRouteCorridorIsNotReachable() {
        XCTAssertFalse(FuelWarning.isReachable(
            station: north(60), from: here, courseDegrees: -1,
            routeAhead: [north(-4), north(-8)]))
    }

    func testParkedWithNoCourseAndNoRouteKeepsEverything() {
        // Nothing can be ruled out, so nothing is — silently dropping real
        // options would be the worse error.
        XCTAssertTrue(FuelWarning.isReachable(
            station: north(-8), from: here, courseDegrees: -1, routeAhead: []))
    }
}

/// Auto-tune must follow weather transmitters without stealing music.
final class RadioAutoTuneTests: XCTestCase {
    private let here = CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40)

    private func station(_ id: String, _ lat: Double) -> RadioTuning.Station {
        RadioTuning.Station(id: id,
                            coordinate: CLLocationCoordinate2D(latitude: lat,
                                                               longitude: -89.40))
    }

    func testAnUnplaceablePlayingStationStillYieldsAtTheTuningLayer() {
        // The pure rule is unchanged and correct for a NOAA relay with no
        // coordinates — the FIX lives in TruckerRadio, which no longer asks
        // about a station that isn't a weather channel at all.
        XCTAssertEqual(RadioTuning.retarget(
            playingID: "no-coords", playingCoordinate: nil, position: here,
            stations: [station("madison", 43.07)]), "madison")
    }

    func testATransmitterAlreadyNearestStaysPut() {
        XCTAssertNil(RadioTuning.retarget(
            playingID: "madison",
            playingCoordinate: CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40),
            position: here, stations: [station("madison", 43.07)]))
    }
}

/// Towing forces route-safety filters — including at launch.
final class TowingFilterTests: XCTestCase {
    func testTowingCarriesTheFullSafetySet() {
        // A rig under tow must not be routed over a mountain grade, under a
        // low bridge, across a weight-limited one, or into a crosswind.
        let s = RouteFilter.towingSafety
        XCTAssertTrue(s.contains(.mountainGrades))
        XCTAssertTrue(s.contains(.lowBridges))
        XCTAssertTrue(s.contains(.bridgeWeight))
        XCTAssertTrue(s.contains(.noHighWinds))
    }
}

/// Google's content must be credited wherever it is shown.
@MainActor
final class RatingsCreditTests: XCTestCase {
    private let gKey = "flows.googlePlacesKey"
    private let yKey = "flows.yelpKey"
    private var savedG: String?
    private var savedY: String?

    override func setUp() {
        savedG = UserDefaults.standard.string(forKey: gKey)
        savedY = UserDefaults.standard.string(forKey: yKey)
        UserDefaults.standard.removeObject(forKey: gKey)
        UserDefaults.standard.removeObject(forKey: yKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedG, forKey: gKey)
        UserDefaults.standard.set(savedY, forKey: yKey)
    }

    func testNoProviderConfiguredCreditsNobody() {
        // FLOWS shows only its own data — inventing a credit would be worse
        // than none.
        XCTAssertNil(RatingsProvider.creditLine)
    }

    func testAGoogleKeyCreditsGoogle() {
        // The stars are drawn over an APPLE map, so there is no Google
        // chrome to carry the attribution their terms require. It has to
        // travel with the content.
        UserDefaults.standard.set("k", forKey: gKey)
        XCTAssertEqual(RatingsProvider.creditLine, "Powered by Google")
    }

    func testGoogleWinsWhenBothKeysArePresent() {
        // The credit must name whoever actually answered, and the fetch
        // ladder tries Google first.
        UserDefaults.standard.set("k", forKey: gKey)
        UserDefaults.standard.set("y", forKey: yKey)
        XCTAssertEqual(RatingsProvider.creditLine, "Powered by Google")
    }

    func testYelpAloneCreditsYelp() {
        UserDefaults.standard.set("y", forKey: yKey)
        XCTAssertEqual(RatingsProvider.creditLine, "Ratings by Yelp")
    }

    func testAnEmptyKeyIsNotAConfiguredProvider() {
        // The settings field writes "" when cleared, not nil.
        UserDefaults.standard.set("", forKey: gKey)
        UserDefaults.standard.set("", forKey: yKey)
        XCTAssertNil(RatingsProvider.creditLine)
    }
}

/// Every behaviour store seals on ONE queue, so erasing can be ordered.
final class BehaviorPersistQueueTests: XCTestCase {
    func testTheSharedQueueIsSerialAndOrdersWorkBeforeAnyLaterCall() {
        // The erase bug: the key was deleted while a sealed write was still
        // queued, so the write ran afterwards, found no key, minted a fresh
        // one, and re-sealed the driver's history in readable form. A single
        // FIFO queue is what makes "delete the key last" mean it.
        var order: [Int] = []
        let done = expectation(description: "drained")
        for i in 0..<50 {
            SecureBehaviorStore.persistQueue.async { order.append(i) }
        }
        SecureBehaviorStore.persistQueue.async {   // stands in for destroyKey
            order.append(999)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(order, Array(0..<50) + [999])
    }
}

/// Which radio directory mirrors the app will talk to.
final class RadioMirrorAllowlistTests: XCTestCase {
    func testTheKnownEuropeanAndNorthAmericanMirrorsAreAllowed() {
        for h in ["de1.api.radio-browser.info", "de2.api.radio-browser.info",
                  "nl1.api.radio-browser.info", "at1.api.radio-browser.info",
                  "fi1.api.radio-browser.info", "us1.api.radio-browser.info"] {
            XCTAssertTrue(RadioBrowser.isAllowedMirror(h), h)
        }
    }

    func testMirrorsFromDisallowedCountriesAreRefused() {
        // Standing rule: no service operated from Russia, China, Iran or
        // North Korea. The directory is volunteer-run and any of these could
        // appear in the runtime list tomorrow; the allowlist is positive, so
        // they are refused without needing to be named.
        for h in ["ru1.api.radio-browser.info", "cn1.api.radio-browser.info",
                  "ir1.api.radio-browser.info", "kp1.api.radio-browser.info"] {
            XCTAssertFalse(RadioBrowser.isAllowedMirror(h), h)
        }
    }

    func testAnythingOffTheDirectorysOwnDomainIsRefused() {
        // A lookalike or a hijacked entry must not pass just because the
        // country code is fine.
        XCTAssertFalse(RadioBrowser.isAllowedMirror("de1.api.radio-browser.info.evil.com"))
        XCTAssertFalse(RadioBrowser.isAllowedMirror("de1.radio-browser.info"))
        XCTAssertFalse(RadioBrowser.isAllowedMirror("api.radio-browser.info"))
        XCTAssertFalse(RadioBrowser.isAllowedMirror("deX.api.radio-browser.info"))
    }
}

/// The diagnostic journal is exportable; the driver's words stay out of it.
final class HandoffLogRedactionTests: XCTestCase {
    func testTheLogNameNeverCarriesTheDictatedGenre() {
        let s = PlaybackFallback.Source.radio(genre: "my private playlist name")
        XCTAssertEqual(s.logName, "radio")
        XCTAssertFalse(s.logName.contains("private"))
    }

    func testEveryCaseHasAStableName() {
        let all: [PlaybackFallback.Source] = [.localLibrary, .radio(genre: "x"),
                                              .nothingAvailable, .keepPlaying]
        XCTAssertEqual(Set(all.map(\.logName)).count, all.count)
    }
}
