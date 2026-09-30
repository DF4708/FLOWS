// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// A train operator's timetable and a city's, merged so one trip can ride the
/// train and then the bus. Each feed counts time from midnight in its own
/// zone, feeds never mention each other's stops, and the rider must see each
/// operator's times on that operator's own clock — so these pin the shift,
/// the walk between a station and the bus bay, and the clock on each leg.
final class TransitMergeTests: XCTestCase {
    private let eastern = "America/New_York"
    private let central = "America/Chicago"
    private let us = Locale(identifier: "en_US")
    /// Foundation puts a NARROW NO-BREAK SPACE (U+202F) before AM/PM.
    private func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }

    // MARK: moving a feed into another's clock

    func testAFeedsShiftIsTheGapBetweenTheTwoDayStarts() {
        func shift(_ from: String, _ into: String, _ date: Int) -> Int? {
            TransitClock.shift(from: from, into: into, serviceDate: date)
        }
        XCTAssertEqual(shift(central, eastern, 20260929), 3600, "08:00 Central is 09:00 Eastern")
        XCTAssertEqual(shift("America/Los_Angeles", eastern, 20260929), 10800)
        XCTAssertEqual(shift(eastern, eastern, 20260929), 0)
        // Clock-change days: both US zones change, the gap does not.
        XCTAssertEqual(shift(central, eastern, 20270314), 3600)
        XCTAssertEqual(shift(central, eastern, 20271107), 3600)
        XCTAssertEqual(shift("America/Halifax", eastern, 20260929), -3600, "east of the reference")
        XCTAssertNil(shift("Mars/Olympus", eastern, 20260929))
    }

    func testPhoenixIsWhyTheShiftIsNotAFixedNumber() {
        // Arizona skips daylight saving: an hour behind Denver in summer,
        // level with it in winter. A table of fixed zone gaps gets one wrong.
        XCTAssertEqual(
            TransitClock.shift(from: "America/Phoenix", into: "America/Denver", serviceDate: 20260715),
            3600
        )
        XCTAssertEqual(
            TransitClock.shift(from: "America/Phoenix", into: "America/Denver", serviceDate: 20260115),
            0
        )
    }

    // MARK: which feeds, what they are called, who is credited

    private func city(_ name: String, _ op: String, lat: ClosedRange<Double>,
                      lon: ClosedRange<Double>) -> TransitFeeds.Source {
        TransitFeeds.Source(
            name: name, url: URL(string: "https://example.invalid/\(name).zip")!,
            operatorName: op,
            area: .init(minLatitude: lat.lowerBound, maxLatitude: lat.upperBound,
                        minLongitude: lon.lowerBound, maxLongitude: lon.upperBound)
        )
    }

    func testATripAsksForAmtrakPlusOnlyTheCityItEndsIn() {
        let chicago = city("cta", "CTA", lat: 41.6...42.1, lon: -87.95 ... -87.5)
        let la = city("lametro", "LA Metro", lat: 33.7...34.4, lon: -118.7 ... -117.9)
        let toHollywood = TransitFeeds.sources(endingAt: 34.1016, -118.3385, from: [chicago, la])
        XCTAssertEqual(toHollywood.map(\.name), ["amtrak", "lametro"])
        let toNowhere = TransitFeeds.sources(endingAt: 44.0, -103.0, from: [chicago, la])
        XCTAssertEqual(toNowhere.map(\.name), ["amtrak"], "no city feed there: Amtrak alone")
        XCTAssertEqual(
            TransitFeeds.sources(endingAt: 34.1, -118.3, from: []).map(\.name), ["amtrak"],
            "with no city feeds allowed, behaviour is exactly the old Amtrak-only card"
        )
    }

    func testAmtrakAloneKeepsTheCacheNameItAlwaysHad() {
        // Changing it would silently rebuild every timetable already on a
        // phone the day this ships.
        XCTAssertEqual(TransitFeeds.shardName([TransitFeeds.amtrak], date: 20260929),
                       "amtrak-20260929")
        let la = city("lametro", "LA Metro", lat: 33.7...34.4, lon: -118.7 ... -117.9)
        XCTAssertEqual(TransitFeeds.shardName([TransitFeeds.amtrak, la], date: 20260929),
                       "amtrak+lametro-20260929")
    }

    func testEveryOperatorWhoseTimesAreShownIsNamed() {
        XCTAssertEqual(TransitFeeds.amtrak.credit, "Schedule from Amtrak", "unchanged")
        XCTAssertEqual(TransitFeeds.credit(for: ["Amtrak", "LA Metro"]),
                       "Schedules from Amtrak and LA Metro")
        XCTAssertEqual(TransitFeeds.credit(for: ["Amtrak", "Metra", "CTA"]),
                       "Schedules from Amtrak, Metra and CTA")
        XCTAssertEqual(TransitFeeds.credit(for: []), "")
    }

    func testOnlyPastDaysShardsAreSwept() {
        XCTAssertTrue(TransitFeeds.isShard("amtrak-20260928.ftt", before: 20260929))
        XCTAssertTrue(TransitFeeds.isShard("amtrak+lametro-20260901.fts", before: 20260929),
                      "a merge asked for once must not sit in the cache forever")
        XCTAssertFalse(TransitFeeds.isShard("amtrak-20260929.ftt", before: 20260929), "today's")
        XCTAssertFalse(TransitFeeds.isShard("amtrak-20260930.ftt", before: 20260929),
                       "tomorrow's — the operator may already be on it")
        XCTAssertFalse(TransitFeeds.isShard("amtrak", before: 20260929), "the feed folder")
        XCTAssertFalse(TransitFeeds.isShard("stops.txt", before: 20260929))
        XCTAssertFalse(TransitFeeds.isShard("notes-12.ftt", before: 20260929), "not a date")
    }

    // MARK: the whole path — two feeds on disk become one trip

    private func write(_ files: [String: String]) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flows-merge-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in files {
            try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir.path
    }

    private let calendar =
        "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n"
        + "WK,1,1,1,1,1,0,0,20260901,20261231\n"

    /// Eastern-time railway: one run, Start 09:00 → Union 10:00 (Eastern).
    private func railFeed() throws -> String {
        try write([
            "agency.txt": "agency_id,agency_name,agency_timezone\n1,Rail,America/New_York\n",
            "stops.txt": "stop_id,stop_name,stop_timezone,stop_lat,stop_lon\n"
                + "START,Start,America/Chicago,42.00000,-88.00000\n"
                + "UNION,Union Station,America/Chicago,41.87890,-87.63990\n",
            "routes.txt": "route_id,route_short_name,route_long_name,route_type\nR,,Lakeshore,2\n",
            "calendar.txt": calendar,
            "trips.txt": "route_id,service_id,trip_id\nR,WK,r1\n",
            "stop_times.txt": "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n"
                + "r1,09:00:00,09:00:00,START,1\nr1,10:00:00,10:00:00,UNION,2\n",
        ])
    }

    /// Central-time city bus from a bay ~150 m from the station. Its stops
    /// name no zone, so they keep the bus operator's — Central.
    private func busFeed() throws -> String {
        try write([
            "agency.txt": "agency_id,agency_name,agency_timezone\n1,City Bus,America/Chicago\n",
            "stops.txt": "stop_id,stop_name,stop_lat,stop_lon\n"
                + "UNIONBUS,Union Bus Bay,41.88025,-87.63990\n"
                + "UPTOWN,Uptown,41.96500,-87.65500\n",
            "routes.txt": "route_id,route_short_name,route_long_name,route_type\nB,22,Clark,3\n",
            "calendar.txt": calendar,
            "trips.txt": "route_id,service_id,trip_id\nB,WK,b1\nB,WK,b2\n",
            "stop_times.txt": "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n"
                + "b1,09:10:00,09:10:00,UNIONBUS,1\nb1,09:40:00,09:40:00,UPTOWN,2\n"
                + "b2,08:10:00,08:10:00,UNIONBUS,1\nb2,08:40:00,08:40:00,UPTOWN,2\n",
        ])
    }

    private func prefix() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("flows-merge-shard-\(UUID().uuidString)").path
    }

    private func clean(_ paths: String...) {
        for p in paths {
            try? FileManager.default.removeItem(atPath: p)
            try? FileManager.default.removeItem(atPath: p + ".ftt")
            try? FileManager.default.removeItem(atPath: p + ".fts")
        }
    }

    func testTheTrainThenTheCityBusIsOneTripOnEachOperatorsClock() throws {
        let (rail, bus, out) = (try railFeed(), try busFeed(), prefix())
        defer { clean(rail, bus, out) }
        let date = 20260929
        let shift = try XCTUnwrap(TransitClock.shift(from: central, into: eastern, serviceDate: date))

        let merged = try TransitShard.build(
            feeds: [.init(directory: rail, shiftSeconds: 0), .init(directory: bus, shiftSeconds: shift)],
            prefix: out, serviceDate: date
        )
        XCTAssertEqual(merged.stamp.agencyZone, eastern, "the first feed's clock")
        XCTAssertEqual(merged.links, 1, "the station and the bus bay")
        XCTAssertTrue(merged.skipped.isEmpty)

        let answer = try TransitShard.departures(
            prefix: out,
            from: CLLocationCoordinate2D(latitude: 42.0, longitude: -88.0),
            to: CLLocationCoordinate2D(latitude: 41.965, longitude: -87.655),
            departing: try XCTUnwrap(TransitClock.instant(serviceDate: date, agencyZone: eastern,
                                                          seconds: 6 * 3600)),
            stamp: merged.stamp
        )
        let schedule = try XCTUnwrap(TransitShard.schedule(from: answer, credit: "x", locale: us))
        XCTAssertEqual(schedule.legs.map(\.vehicle), ["Train", "Bus"])
        XCTAssertEqual(schedule.legs[1].vehicleLine, "Bus · 22 Clark")
        XCTAssertEqual(schedule.legs[0].boardName, "Start")
        XCTAssertEqual(schedule.legs[1].boardName, "Union Bus Bay")
        // Stored 09:00 Eastern; the train leaves Start at 8:00 on Start's clock.
        XCTAssertEqual(plain(schedule.legs[0].clockSpan), "8:00 AM – 9:00 AM")
        // Stored 09:10 Central, shifted to 10:10 Eastern, shown back on the
        // bus bay's own clock: 9:10 AM. The 08:10 bus left before the train
        // arrived and must not be the one offered.
        XCTAssertEqual(plain(schedule.legs[1].clockSpan), "9:10 AM – 9:40 AM")
        XCTAssertEqual(schedule.routeName, "1 change")
    }

    func testABrokenCityFeedLeavesTheTrainsIntactAndSaysSo() throws {
        let (rail, out) = (try railFeed(), prefix())
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("flows-merge-no-such-feed-\(UUID().uuidString)").path
        defer { clean(rail, out) }
        let merged = try TransitShard.build(
            feeds: [.init(directory: rail, shiftSeconds: 0), .init(directory: missing, shiftSeconds: 3600)],
            prefix: out, serviceDate: 20260929
        )
        XCTAssertEqual(merged.skipped.keys.sorted(), [1])
        XCTAssertTrue(merged.skipped[1]?.contains("not a directory") ?? false)
        XCTAssertEqual(merged.links, 0)
        XCTAssertNotNil(TransitShard.stamp(prefix: out), "the train timetable was still built")
    }

    func testNoFeedsIsRefusedBeforeReachingRust() {
        // An empty shift buffer across the bridge is undefined behaviour in
        // swift-bridge; the facade must answer this itself.
        XCTAssertThrowsError(try TransitShard.build(feeds: [], prefix: prefix(), serviceDate: 20260929))
    }

    // MARK: the feed keeper itself — merge, lapse, offline

    /// A cache folder of our own, laid out the way `TransitFeeds` keeps one:
    /// a sub-folder per feed holding its extracted files.
    private func cache(rail: Bool = true, bus: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flows-feeds-test-\(UUID().uuidString)", isDirectory: true)
        func put(_ folder: String, from dir: String) throws {
            let target = root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: dir, toPath: target.path)
            try Data().write(to: target.appendingPathComponent(".fetched"))
            try? FileManager.default.removeItem(atPath: dir)
        }
        if rail { try put("amtrak", from: try railFeed()) }
        if let bus { try put("citybus", from: bus) }
        return root
    }

    private var cityBus: TransitFeeds.Source {
        TransitFeeds.Source(
            name: "citybus", url: URL(string: "https://example.invalid/citybus.zip")!,
            operatorName: "City Bus",
            area: .init(minLatitude: 41.6, maxLatitude: 42.1,
                        minLongitude: -87.95, maxLongitude: -87.5)
        )
    }

    /// Noon Eastern on the 29th: the service day both feeds are read for.
    private var noonOnThe29th: Date {
        TransitClock.instant(serviceDate: 20260929, agencyZone: eastern, seconds: 12 * 3600)!
    }

    private func exists(_ root: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }

    func testTheKeeperMergesAmtrakWithTheCityAndCreditsBoth() async throws {
        let root = try cache(bus: try busFeed())
        defer { try? FileManager.default.removeItem(at: root) }
        let keeper = TransitFeeds(cacheRoot: root)

        let ready = try await keeper.ready([TransitFeeds.amtrak, cityBus],
                                           on: noonOnThe29th, allowNetwork: false)
        XCTAssertTrue(ready.prefix.hasSuffix("amtrak+citybus-20260929"))
        XCTAssertEqual(ready.credit, "Schedules from Amtrak and City Bus")
        XCTAssertEqual(ready.stamp.agencyZone, eastern)

        // Asked again the same day: the same timetable, not a rebuild.
        let again = try await keeper.ready([TransitFeeds.amtrak, cityBus],
                                           on: noonOnThe29th, allowNetwork: false)
        XCTAssertEqual(again, ready)
    }

    func testALapsedCityFeedIsLeftOutAndNotCredited() async throws {
        // The city's calendar ended on the 1st. Its times must not appear, its
        // name must not be credited, and no shard may be left on disk that
        // claims to hold it.
        let lapsed = try write([
            "agency.txt": "agency_id,agency_name,agency_timezone\n1,City Bus,America/Chicago\n",
            "stops.txt": "stop_id,stop_name,stop_lat,stop_lon\nUNIONBUS,Union Bus Bay,41.88025,-87.63990\n"
                + "UPTOWN,Uptown,41.96500,-87.65500\n",
            "routes.txt": "route_id,route_short_name,route_long_name,route_type\nB,22,Clark,3\n",
            "calendar.txt": "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,"
                + "start_date,end_date\nWK,1,1,1,1,1,0,0,20260801,20260901\n",
            "trips.txt": "route_id,service_id,trip_id\nB,WK,b1\n",
            "stop_times.txt": "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n"
                + "b1,09:10:00,09:10:00,UNIONBUS,1\nb1,09:40:00,09:40:00,UPTOWN,2\n",
        ])
        let root = try cache(bus: lapsed)
        defer { try? FileManager.default.removeItem(at: root) }
        let keeper = TransitFeeds(cacheRoot: root)

        let ready = try await keeper.ready([TransitFeeds.amtrak, cityBus],
                                           on: noonOnThe29th, allowNetwork: false)
        XCTAssertTrue(ready.prefix.hasSuffix("amtrak-20260929"), "Amtrak alone, its usual name")
        XCTAssertEqual(ready.credit, "Schedule from Amtrak")
        XCTAssertFalse(exists(root, "amtrak+citybus-20260929.ftt"),
                       "no shard may claim a feed it does not hold")
    }

    func testACityFeedNotYetDownloadedIsSimplyAbsentOffline() async throws {
        // Mid-drive nothing is fetched; a city feed not already on the phone
        // is left out and the train times still come back.
        let root = try cache(bus: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = try await TransitFeeds(cacheRoot: root)
            .ready([TransitFeeds.amtrak, cityBus], on: noonOnThe29th, allowNetwork: false)
        XCTAssertTrue(ready.prefix.hasSuffix("amtrak-20260929"))
        XCTAssertEqual(ready.credit, "Schedule from Amtrak")
    }

    func testNoTrainTimetableOfflineIsSaidPlainly() async throws {
        let root = try cache(rail: false, bus: try busFeed())
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await TransitFeeds(cacheRoot: root)
                .ready([TransitFeeds.amtrak, cityBus], on: noonOnThe29th, allowNetwork: false)
            XCTFail("the first feed is required")
        } catch let failure as TransitFeeds.Failure {
            XCTAssertEqual(failure, .notCachedAndOffline)
        }
    }

    func testYesterdaysShardsGoWhenTodaysIsBuilt() async throws {
        let root = try cache(bus: try busFeed())
        defer { try? FileManager.default.removeItem(at: root) }
        for stale in ["amtrak-20260928.ftt", "amtrak+citybus-20260901.fts"] {
            try Data([1]).write(to: root.appendingPathComponent(stale))
        }
        _ = try await TransitFeeds(cacheRoot: root)
            .ready([TransitFeeds.amtrak, cityBus], on: noonOnThe29th, allowNetwork: false)
        XCTAssertFalse(exists(root, "amtrak-20260928.ftt"))
        XCTAssertFalse(exists(root, "amtrak+citybus-20260901.fts"))
        XCTAssertTrue(exists(root, "amtrak+citybus-20260929.ftt"))
        XCTAssertTrue(exists(root, "amtrak"), "the feed folders are never swept")
    }
}
