// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// When the screen turns dark, and how the AM/FM dial is arranged.
final class DaylightAndDialTests: XCTestCase {
    private let madison = CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40)
    private let miami = CLLocationCoordinate2D(latitude: 25.76, longitude: -80.19)
    private let barrow = CLLocationCoordinate2D(latitude: 71.29, longitude: -156.79)

    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    // MARK: the sun, not the clock

    func testMiddayIsDayAndMidnightIsNight() {
        // 18:00 UTC is noon in Madison; 06:00 UTC is midnight.
        XCTAssertFalse(DaylightClock.isNight(at: madison, now: utc(2026, 6, 21, 18)))
        XCTAssertTrue(DaylightClock.isNight(at: madison, now: utc(2026, 6, 21, 6)))
    }

    func testMidsummerSunsetIsKnownToTheMinute() {
        // Madison, 21 June 2026: the sun sets at 20:40 local and civil dusk
        // follows at 21:15 (02:15 UTC the next day) — both verified against
        // published almanac times. A quarter-hour before is light, and
        // three-quarters after is not. This is the whole point: a fixed
        // "dark at 8 pm" rule would dim the screen in broad daylight.
        XCTAssertFalse(DaylightClock.isNight(at: madison, now: utc(2026, 6, 22, 2)))
        XCTAssertTrue(DaylightClock.isNight(at: madison, now: utc(2026, 6, 22, 3)))
    }

    func testDuskIsHoursApartAcrossTheCountryOnTheSameDay() {
        // Miami's midsummer dusk comes much earlier in the evening than
        // Madison's — the same wall-clock hour is dark in one and light in
        // the other, which no fixed schedule can express.
        let t = utc(2026, 6, 22, 1, 30)     // 20:30 in Miami, 20:30 in Madison
        XCTAssertTrue(DaylightClock.isNight(at: miami, now: t))
        XCTAssertFalse(DaylightClock.isNight(at: madison, now: t))
    }

    func testWinterAfternoonIsAlreadyDarkUpNorth() {
        // 23:00 UTC on the solstice is 17:00 in Madison — after dusk.
        XCTAssertTrue(DaylightClock.isNight(at: madison, now: utc(2026, 12, 21, 23)))
    }

    func testPolarDayAndPolarNightStillAnswer() {
        // Above the Arctic circle there is no dawn or dusk to compare
        // against for months. The answer must still be right, not nil.
        XCTAssertFalse(DaylightClock.isNight(at: barrow, now: utc(2026, 6, 21, 12)))
        XCTAssertTrue(DaylightClock.isNight(at: barrow, now: utc(2026, 12, 21, 12)))
    }

    func testTheNextChangeIsAlwaysAheadAndWithinADay() {
        for hour in stride(from: 0, to: 24, by: 3) {
            let now = utc(2026, 3, 15, hour)
            let next = DaylightClock.nextChange(at: madison, now: now)
            XCTAssertGreaterThan(next, now)
            XCTAssertLessThan(next.timeIntervalSince(now), 86_400 + 3_600)
        }
    }

    func testTheAppearanceActuallyFlipsAcrossTheBoundary() {
        // Whatever it is now, it must be the other thing on the far side of
        // the next boundary — otherwise the screen never turns over.
        let now = utc(2026, 9, 10, 20)
        let before = DaylightClock.isNight(at: madison, now: now)
        let after = DaylightClock.isNight(
            at: madison,
            now: DaylightClock.nextChange(at: madison, now: now)
                .addingTimeInterval(60))
        XCTAssertNotEqual(before, after)
    }

    // MARK: the AM/FM dial

    func testStationsAreFiledByWhatADriverWouldCallThem() {
        XCTAssertEqual(BroadcastRadio.kind(forTags: "news,npr,talk"), .news)
        XCTAssertEqual(BroadcastRadio.kind(forTags: "classic country,country"), .country)
        XCTAssertEqual(BroadcastRadio.kind(forTags: "top 40,hits"), .pop)
        XCTAssertEqual(BroadcastRadio.kind(forTags: "bebop,big band"), .jazz)
    }

    func testTheNarrowKindWinsOverTheBroadOne() {
        // "christian rock" is Christian, not Rock; "sports talk" is Sports,
        // not News; "regional mexican pop" is Spanish, not Pop.
        XCTAssertEqual(BroadcastRadio.kind(forTags: "christian rock,rock"), .christian)
        XCTAssertEqual(BroadcastRadio.kind(forTags: "sports talk,talk"), .sports)
        XCTAssertEqual(BroadcastRadio.kind(forTags: "regional mexican,pop"), .latin)
        XCTAssertEqual(BroadcastRadio.kind(forTags: "classic rock,rock"), .rock)
    }

    func testAStationWithNothingToSayIsNotFiled() {
        XCTAssertNil(BroadcastRadio.kind(forTags: ""))
        XCTAssertNil(BroadcastRadio.kind(forTags: "misc,miscellaneous"))
    }

    func testEveryKindCanActuallyBeReached() {
        // A kind with no tag that reaches it would be a dead entry in the
        // picker — every one must be selectable by at least one of its own
        // words, given the match order.
        for kind in BroadcastRadio.Kind.allCases {
            let word = kind.tagWords.first ?? ""
            XCTAssertEqual(BroadcastRadio.kind(forTags: word), kind,
                           "\(kind.title) is unreachable through its own tag")
        }
    }

    func testTheDialPositionIsReadOutOfTheName() {
        XCTAssertEqual(BroadcastRadio.dialLabel(from: "105.7 WAPL"), "105.7 FM")
        XCTAssertEqual(BroadcastRadio.dialLabel(from: "WXXM \"Rewind 92.1\""), "92.1 FM")
        XCTAssertEqual(BroadcastRadio.dialLabel(from: "WGN 720"), "720 AM")
    }

    func testNumbersThatArentDialPositionsAreIgnored() {
        // A year, a bitrate, a channel number — none of these are a place
        // on the dial, and printing one as "128 AM" would be nonsense.
        XCTAssertNil(BroadcastRadio.dialLabel(from: "Radio 128k stream"))
        XCTAssertNil(BroadcastRadio.dialLabel(from: "Best of 1985"))
        XCTAssertNil(BroadcastRadio.dialLabel(from: "Channel 42"))
    }

    // MARK: seeking

    private func station(_ id: String, _ lat: Double? = nil,
                         bitrate: Int = 128) -> BroadcastRadio.Station {
        BroadcastRadio.Station(id: id, name: id, url: "https://x/\(id)",
                               tags: "rock", latitude: lat,
                               longitude: lat == nil ? nil : -89.4,
                               bitrate: bitrate, kind: .rock)
    }

    func testSeekWrapsAtBothEndsAndNeverDeadEnds() {
        let list = [station("a"), station("b"), station("c")]
        XCTAssertEqual(BroadcastRadio.step(from: "c", in: list, forward: true)?.id, "a")
        XCTAssertEqual(BroadcastRadio.step(from: "a", in: list, forward: false)?.id, "c")
        XCTAssertEqual(BroadcastRadio.step(from: "a", in: list, forward: true)?.id, "b")
    }

    func testSeekingWithNothingPlayingStartsAtAnEnd() {
        let list = [station("a"), station("b")]
        XCTAssertEqual(BroadcastRadio.step(from: nil, in: list, forward: true)?.id, "a")
        XCTAssertEqual(BroadcastRadio.step(from: nil, in: list, forward: false)?.id, "b")
    }

    func testSeekingAnEmptyKindIsSilentRatherThanACrash() {
        XCTAssertNil(BroadcastRadio.step(from: nil, in: [], forward: true))
        XCTAssertNil(BroadcastRadio.step(from: "gone", in: [], forward: false))
    }

    func testLocalBeatsLoudWhenRankingTheDial() {
        // "Local radio" means the broadcaster down the road, not the
        // highest-bitrate stream three states away.
        let here = CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40)
        let ranked = BroadcastRadio.ranked(
            [station("far", 40.0, bitrate: 320), station("near", 43.1, bitrate: 64)],
            near: here)
        XCTAssertEqual(ranked.first?.id, "near")
    }

    func testUnplaceableStationsSinkBelowLocatedOnes() {
        let here = CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40)
        let ranked = BroadcastRadio.ranked(
            [station("nowhere", nil, bitrate: 320), station("somewhere", 43.1)],
            near: here)
        XCTAssertEqual(ranked.first?.id, "somewhere")
    }
}
