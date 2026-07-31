// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import XCTest

/// Long-trip share: the 200-mile triggers, the daily odometer's midnight
/// reset, recipient ranking, the message text, and the sms: recipe.
final class TripShareTests: XCTestCase {

    private let mile = TripShareLogic.metersPerMile

    // MARK: the 200-mile triggers — strictly OVER, either condition

    func testLongPlottedRouteTriggersTheOffer() {
        XCTAssertTrue(TripShareLogic.shouldOffer(routeMeters: 201 * mile,
                                                 drivenTodayMeters: 0))
        XCTAssertFalse(TripShareLogic.shouldOffer(routeMeters: 199 * mile,
                                                  drivenTodayMeters: 0))
        // Exactly 200.0 miles is not "over 200" — the boundary stays quiet.
        XCTAssertFalse(TripShareLogic.shouldOffer(routeMeters: 200 * mile,
                                                  drivenTodayMeters: 0))
    }

    func testBigDrivingDayTriggersEvenOnAShortLeg() {
        // A 15-mile hop late in a 200+ mile day still offers.
        XCTAssertTrue(TripShareLogic.shouldOffer(routeMeters: 15 * mile,
                                                 drivenTodayMeters: 201 * mile))
        XCTAssertFalse(TripShareLogic.shouldOffer(routeMeters: 15 * mile,
                                                  drivenTodayMeters: 200 * mile))
        XCTAssertFalse(TripShareLogic.shouldOffer(routeMeters: 0, drivenTodayMeters: 0))
    }

    // MARK: daily odometer — accumulates, resets at midnight, never runs down

    func testDailyLogAccumulatesAndResetsOnANewDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day1 = Date(timeIntervalSince1970: 1_750_000_000)
        let day2 = day1.addingTimeInterval(86_400)

        var log = DailyDriveLog.empty(on: day1, calendar: calendar)
        log.add(meters: 500, at: day1, calendar: calendar)
        log.add(meters: 250, at: day1, calendar: calendar)
        XCTAssertEqual(log.meters, 750)

        // First movement of the next day starts the count over.
        log.add(meters: 100, at: day2, calendar: calendar)
        XCTAssertEqual(log.meters, 100)
        XCTAssertEqual(log.day, calendar.startOfDay(for: day2))

        // A negative GPS glitch never drives the total down.
        log.add(meters: -50, at: day2, calendar: calendar)
        XCTAssertEqual(log.meters, 100)
    }

    // MARK: recipient ranking — frequency + recency, decayed together

    private func recipient(_ name: String, sharesAgoDays: [Double],
                           now: Date) -> ShareRecipient {
        ShareRecipient(name: name, phone: "555\(name.count)",
                       shareDates: sharesAgoDays.map {
                           now.addingTimeInterval(-$0 * 86_400)
                       })
    }

    func testRankingPrefersFrequentRecentPeople() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let often = recipient("often", sharesAgoDays: [1, 3, 8], now: now)
        let once = recipient("once", sharesAgoDays: [2], now: now)
        XCTAssertEqual(TripShareLogic.ranked([once, often], now: now).map(\.name),
                       ["often", "once"])
    }

    func testRankingDecaysStalePiles() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        // Five shares ~10 half-lives ago score ≈ 0.005 — two from today win.
        let stale = recipient("stale", sharesAgoDays: [300, 301, 302, 303, 304], now: now)
        let current = recipient("current", sharesAgoDays: [0, 1], now: now)
        XCTAssertEqual(TripShareLogic.ranked([stale, current], now: now).map(\.name),
                       ["current", "stale"])
    }

    // MARK: the message — where, when, and a map link; plain words

    func testShareMessageSaysWhereWhenAndMap() {
        // 2026-03-05 22:40 UTC — formatter is pinned POSIX/en_US but uses the
        // local zone, so assert via the same formatter rather than a literal.
        let arrival = Date(timeIntervalSince1970: 1_772_750_400)
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "h:mm a"

        let message = TripShareLogic.shareMessage(
            destination: "Denver, CO", arrival: arrival,
            latitude: 39.73915, longitude: -104.99025)
        XCTAssertEqual(message, """
            On my way to Denver, CO.
            I should get there around \(clock.string(from: arrival)).
            Map: https://maps.apple.com/?daddr=39.73915,-104.99025
            """)
    }

    func testShareMessageDropsTheMapLineWithoutACoordinate() {
        let message = TripShareLogic.shareMessage(
            destination: "Home", arrival: Date(timeIntervalSince1970: 1_772_750_400),
            latitude: nil, longitude: nil)
        XCTAssertFalse(message.contains("maps.apple.com"),
                       "no coordinate must never become a 0,0 map link")
    }

    // MARK: sms: URL — byte-for-byte the crash flow's recipe

    func testSMSLinkMatchesTheCrashFlowRecipe() {
        XCTAssertEqual(
            TripShareLogic.smsURLString(number: "+1 (555) 010-2030",
                                        body: "On my way"),
            "sms:+15550102030?&body=On%20my%20way")
        // No digits → nothing useful could open.
        XCTAssertNil(TripShareLogic.smsURLString(number: "n/a", body: "hi"))
    }

    // MARK: history store — dedupe by digits, caps, persistence round-trip

    @MainActor
    func testShareHistoryDedupesPersistsAndCaps() throws {
        let suite = "flows.tests.tripshare"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let store = ShareHistoryStore(defaults: defaults)
        // Same person typed two ways stays ONE entry with two share dates.
        store.recordShare(name: "Dana", phone: "+1 (555) 010-2030", at: now)
        store.recordShare(name: "Dana", phone: "15550102030",
                          at: now.addingTimeInterval(60))
        XCTAssertEqual(store.recipients.count, 1)
        XCTAssertEqual(store.recipients[0].shareDates.count, 2)

        // Relaunch (fresh store, same defaults) reads the history back.
        let relaunched = ShareHistoryStore(defaults: defaults)
        XCTAssertEqual(relaunched.recipients, store.recipients)

        // Per-person dates cap at 10; the OLDEST fall off.
        for i in 0..<20 {
            relaunched.recordShare(name: "Dana", phone: "15550102030",
                                   at: now.addingTimeInterval(Double(i) * 3600))
        }
        XCTAssertEqual(relaunched.recipients[0].shareDates.count,
                       ShareHistoryStore.maxDatesPerRecipient)

        // The recipient list caps at 12, evicting the WEAKEST suggestion —
        // heavily-used Dana survives a parade of one-off strangers.
        for i in 0..<20 {
            relaunched.recordShare(name: "Stranger \(i)", phone: "555000\(i)",
                                   at: now.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(relaunched.recipients.count, ShareHistoryStore.maxRecipients)
        XCTAssertTrue(relaunched.recipients.contains { $0.name == "Dana" })

        // Suggestions come back best-first: Dana's ten recent shares beat
        // any single-share stranger.
        XCTAssertEqual(relaunched.suggestions(now: now.addingTimeInterval(86_400))
            .first?.name, "Dana")
        defaults.removePersistentDomain(forName: suite)
    }
}
