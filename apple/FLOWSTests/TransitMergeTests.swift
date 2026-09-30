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

    func testACityLegAsksForTheCitiesItStartsAndEndsIn() {
        let chicago = city("cta", "CTA", lat: 41.6...42.1, lon: -87.95 ... -87.5)
        let la = city("lametro", "LA Metro", lat: 33.7...34.4, lon: -118.7 ... -117.9)
        let region = city("metrolink", "Metrolink", lat: 33.5...34.8, lon: -119.0 ... -116.8)
        // Union Station to Hollywood: LA Metro holds both ends, and so does
        // the wider regional system — one city's own buses first.
        let inLA = TransitFeeds.citySources(from: 34.0562, -118.2365, to: 34.1016, -118.3385,
                                            cities: [chicago, la, region])
        XCTAssertEqual(inLA.map(\.name), ["lametro", "metrolink"])
        XCTAssertFalse(inLA.contains { $0.name == "amtrak" },
                       "the train is its own leg, asked separately")
        // O'Hare to Hollywood is no city leg at all — but each end's own
        // feed is still offered, one per end.
        let apart = TransitFeeds.citySources(from: 41.9786, -87.9048, to: 34.1016, -118.3385,
                                             cities: [chicago, la])
        XCTAssertEqual(apart.map(\.name), ["cta", "lametro"])
        XCTAssertTrue(TransitFeeds.citySources(from: 44.0, -103.0, to: 44.1, -103.1,
                                               cities: [chicago, la]).isEmpty,
                      "no city feed there: no city leg")
        XCTAssertEqual(TransitFeeds.citySources(from: 34.0562, -118.2365, to: 34.1016, -118.3385,
                                                cities: [chicago, la, region], limit: 1)
                        .map(\.name), ["lametro"])
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

    func testARiderWhoChoseTheBusIsNeverPutOnTheTrain() throws {
        let (rail, bus, out) = (try railFeed(), try busFeed(), prefix())
        defer { clean(rail, bus, out) }
        let date = 20260929
        let shift = try XCTUnwrap(TransitClock.shift(from: central, into: eastern, serviceDate: date))
        let merged = try TransitShard.build(
            feeds: [.init(directory: rail, shiftSeconds: 0), .init(directory: bus, shiftSeconds: shift)],
            prefix: out, serviceDate: date
        )
        let start = CLLocationCoordinate2D(latitude: 42.0, longitude: -88.0)
        let uptown = CLLocationCoordinate2D(latitude: 41.965, longitude: -87.655)
        let six = try XCTUnwrap(TransitClock.instant(serviceDate: date, agencyZone: eastern,
                                                     seconds: 6 * 3600))
        let busOnly = TripShape(onFoot: true, modes: [.bus], tripMiles: 5).localVehicles
        XCTAssertThrowsError(try TransitShard.departures(
            prefix: out, from: start, to: uptown, departing: six, stamp: merged.stamp,
            vehicles: busOnly), "the only way from Start is the train")

        // Everything allowed: both rides, each saying where its stops are.
        let any = try TransitShard.departures(
            prefix: out, from: start, to: uptown, departing: six, stamp: merged.stamp)
        let rides = try XCTUnwrap(any.departures.first?.rides)
        XCTAssertEqual(rides.count, 2)
        XCTAssertEqual(try XCTUnwrap(rides[0].boardCoordinate?.latitude), 42.0, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(rides[1].boardCoordinate?.latitude), 41.88025, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(rides[1].alightCoordinate?.longitude), -87.655, accuracy: 1e-6)

        // From the bus bay, the bus-only rider gets the bus.
        let bay = CLLocationCoordinate2D(latitude: 41.88025, longitude: -87.63990)
        let ten = try XCTUnwrap(TransitClock.instant(serviceDate: date, agencyZone: eastern,
                                                     seconds: 10 * 3600))
        let byBus = try TransitShard.departures(
            prefix: out, from: bay, to: uptown, departing: ten, stamp: merged.stamp,
            vehicles: busOnly)
        XCTAssertEqual(byBus.departures.first?.rides.map(\.mode), [2])
    }

    // MARK: any mix of toggles is one trip

    func testCarBusAndTrainDrivesToTheTrainAndTakesTheBusFromIt() {
        let s = TripShape(onFoot: false, modes: [.rail, .bus], tripMiles: 300)
        XCTAssertEqual(s.main, .train)
        XCTAssertEqual(s.access, .ownCar)
        XCTAssertEqual(s.egress, .local)
        XCTAssertEqual(s.mainMode, .rail)
        XCTAssertTrue(s.shows(TripShape.cardMain))
        XCTAssertFalse(s.shows(TripShape.cardLocal), "one trip, one card")
        XCTAssertEqual(s.modes(ofCard: .rail, active: [.rail, .bus]), [.rail, .bus],
                       "closing the trip turns off the bus folded into it")
    }

    func testAnotherCityVehicleMustSaveFifteenMinutes() {
        XCTAssertTrue(TripShape.otherVehicleWins(chosenSeconds: nil, otherSeconds: 1_800),
                      "no bus makes the trip: the train does")
        XCTAssertTrue(TripShape.otherVehicleWins(chosenSeconds: 4_000, otherSeconds: 1_800),
                      "Minneapolis: the light rail beats buses by way of St. Paul")
        XCTAssertFalse(TripShape.otherVehicleWins(chosenSeconds: 2_400, otherSeconds: 1_800),
                       "ten minutes is not enough to overrule the rider")
        XCTAssertEqual(TripShape(onFoot: true, modes: [.bus, .plane], tripMiles: 600).cityChoice,
                       "bus")
        XCTAssertNil(TripShape(onFoot: true, modes: [.bus, .rail], tripMiles: 6).cityChoice)
        XCTAssertEqual(TripShape(onFoot: true, modes: [.bus, .rail], tripMiles: 6).localVehicles,
                       TripShape.allVehicles)
    }

    func testWalkBusAndPlaneRidesTheBusBothWaysUnlessARentalIsOn() {
        let bus = TripShape(onFoot: true, modes: [.bus, .plane], tripMiles: 600)
        XCTAssertEqual(bus.main, .plane)
        XCTAssertEqual(bus.access, .local)
        XCTAssertEqual(bus.egress, .local)
        XCTAssertEqual(bus.egressFallback, .rentOrRide)
        XCTAssertNotEqual(bus.localVehicles, 0)

        let rental = TripShape(onFoot: true, modes: [.bus, .plane, .rental], tripMiles: 600)
        XCTAssertEqual(rental.access, .local, "still the bus to the airport")
        XCTAssertEqual(rental.egress, .rental, "and a car where the plane lands")
        XCTAssertEqual(rental.modes(ofCard: .plane, active: [.bus, .plane, .rental]),
                       [.bus, .plane, .rental])
    }

    func testAShortTripKeepsItsCardsApart() {
        let s = TripShape(onFoot: true, modes: [.bus, .rental, .plane], tripMiles: 8)
        XCTAssertEqual(s.main, .short)
        XCTAssertNil(s.mainMode)
        XCTAssertTrue(s.shows(TripShape.cardLocal))
        XCTAssertTrue(s.shows(TripShape.cardRental))
        XCTAssertTrue(s.shows(TripShape.cardPlaneNote))
        XCTAssertEqual(TripShape.localMode([.bus, .rental]), .bus)
        XCTAssertEqual(TripShape.localMode([.rail]), .rail)
        XCTAssertEqual(s.modes(ofCard: .rental, active: [.bus, .rental, .plane]), [.rental])
        XCTAssertEqual(s.modes(ofCard: .plane, active: [.bus, .rental, .plane]), [.plane])
    }

    func testACityRideMustBeatTheWalk() {
        XCTAssertTrue(TripShape.transitBeatsWalk(walkSeconds: 3_600, transitSeconds: 1_200))
        XCTAssertFalse(TripShape.transitBeatsWalk(walkSeconds: 1_300, transitSeconds: 1_200))
        XCTAssertTrue(TripShape.transitBeatsWalk(walkSeconds: nil, transitSeconds: 9_000))
        XCTAssertEqual(TripShape.longHaulMiles, 60)
        XCTAssertEqual(TripShape.farWalkSeconds, 2_700)
    }

    func testOneTripsTimetablesReadAsOneSchedule() throws {
        let zone = central
        func part(_ vehicle: String, _ name: String, from: String, to: String,
                  _ on: TimeInterval, _ off: TimeInterval, _ op: String) -> TransitSchedule {
            let a = Date(timeIntervalSince1970: on), b = Date(timeIntervalSince1970: off)
            let span = TransitClock.span(board: a, boardZone: zone, alight: b,
                                         alightZone: zone, locale: us)
            return TransitSchedule(
                legs: [.init(clockSpan: span, vehicle: vehicle, name: name,
                             boardName: from, alightName: to)],
                boardName: from, alightName: to, routeName: name, clockSpan: span,
                rideSeconds: off - on, laterClocks: ["later"], credit: "Schedule from \(op)",
                asOf: "Times as of Sep 22", boardAt: a, boardZone: zone, alightAt: b,
                alightZone: zone, operators: [op])
        }
        // 2026-09-29 13:00Z = 8:00 AM Central.
        let t0: TimeInterval = 1_790_686_800
        let toStation = part("Bus", "30", from: "Home", to: "Station", t0, t0 + 1_200, "MCTS")
        let train = part("Train", "Hiawatha", from: "Station", to: "Union", t0 + 1_800,
                         t0 + 7_200, "Amtrak")
        let fromStation = part("Bus", "22", from: "Union Bay", to: "Uptown", t0 + 7_800,
                               t0 + 9_600, "CTA")
        let one = try XCTUnwrap(TransitSchedule.joined([toStation, train, fromStation], locale: us))
        XCTAssertEqual(one.legs.map(\.vehicle), ["Bus", "Train", "Bus"])
        XCTAssertEqual(one.routeName, "2 changes")
        XCTAssertEqual(plain(one.clockSpan), "8:00 AM – 10:40 AM")
        XCTAssertEqual(one.rideSeconds, 9_600)
        XCTAssertEqual(one.credit, "Schedules from MCTS, Amtrak and CTA")
        XCTAssertTrue(one.laterClocks.isEmpty, "a later train brings no later bus with it")
        XCTAssertEqual(one.boardName, "Home")
        XCTAssertEqual(one.alightName, "Uptown")
        XCTAssertEqual(TransitSchedule.joined([train]), train)
        XCTAssertNil(TransitSchedule.joined([]))

        // Door to door: 10 minutes' walk to the first bus, the timetable's
        // 8:00 → 10:40 with every connection's wait inside it, 5 minutes'
        // walk after — 2 h 55 m, not the rides and walks added up.
        XCTAssertEqual(TransitItinerary.doorToDoor(before: 600, schedule: one, after: 300),
                       600 + 9_600 + 300)
        XCTAssertEqual(TransitItinerary.doorToDoor(before: nil, schedule: one, after: nil), 9_600)
        let noClock = TransitSchedule(
            legs: one.legs, boardName: "A", alightName: "B", routeName: "", clockSpan: "",
            rideSeconds: 60, laterClocks: [], credit: "", asOf: "")
        XCTAssertNil(TransitItinerary.doorToDoor(before: 600, schedule: noClock, after: 300),
                     "an estimate has no clock, and its total stays its legs'")
    }

    func testCityRidesAreSaidTheWayRidersSayThem() {
        XCTAssertEqual(TransitPlanning.cityRide(vehicle: "Bus", name: "30"), "the 30 bus")
        XCTAssertEqual(TransitPlanning.cityRide(vehicle: "Bus", name: "12 Teutonia Avenue"),
                       "the 12 Teutonia Avenue bus", "a route number leads, so the vehicle follows")
        XCTAssertEqual(TransitPlanning.cityRide(vehicle: "Train", name: "Blue Line"), "the Blue Line")
        XCTAssertEqual(TransitPlanning.cityRide(vehicle: "Bus", name: ""), "the bus")
        XCTAssertEqual(TransitPlanning.cityRide(vehicle: "Train", name: "Train"), "the train")
        XCTAssertEqual(TransitPlanning.vehicleSymbol("Bus"), "bus.fill")
        XCTAssertEqual(TransitPlanning.vehicleSymbol("Train"), "tram.fill")
        XCTAssertTrue(TransitPlanning.farEndNote(.rental).contains("rental car"))
        XCTAssertTrue(TransitPlanning.farEndNote(.local).contains("city bus"))
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

    // MARK: the compiled-in table — key-free feeds on by default

    func testALegInMilwaukeeIsOfferedMilwaukeesBuses() {
        // Milwaukee Intermodal Station to the lakefront.
        let sources = TransitFeeds.citySources(from: 43.0345, -87.9171, to: 43.0389, -87.9065)
        XCTAssertGreaterThanOrEqual(sources.count, 1, "Milwaukee has a key-free feed")
        // "Milwaukee County Transit System (MCTS)" — named as riders say it.
        XCTAssertTrue(sources.contains { $0.operatorName == "MCTS" },
                      "\(sources.map(\.operatorName))")
        XCTAssertTrue(sources.allSatisfy {
            $0.area?.contains(latitude: 43.0389, longitude: -87.9065) ?? false
        })
        XCTAssertTrue(sources.allSatisfy { $0.mirror?.host == "files.mobilitydatabase.org" },
                      "every city feed carries the catalog's copy for when its own link dies")
    }

    func testALegAsksForNoMoreCityFeedsThanTheLimit() {
        // Downtown Los Angeles sits inside dozens of feeds' boxes.
        let sources = TransitFeeds.citySources(from: 34.0562, -118.2365, to: 34.0522, -118.2437)
        XCTAssertLessThanOrEqual(sources.count, TransitFeeds.cityFeedLimit)
        XCTAssertEqual(Set(sources.map(\.name)).count, sources.count, "no feed twice")
    }

    func testTheOpenOceanHasNoCityLeg() {
        // Not a lake: some feeds' boxes span Lake Superior. A box is where a
        // feed's service ends up, not where it runs.
        XCTAssertTrue(TransitFeeds.citySources(from: 35.0, -40.0, to: 35.1, -40.1).isEmpty,
                      "mid-Atlantic has no buses")
    }

    func testAFeedFitsByTheMemoryItsBuildCanTakeNotAFixedSize() {
        func entry(_ unpacked: Int, _ packed: Int) -> GTFSZip.Entry {
            .init(name: "stop_times.txt", method: 8, compressedSize: packed,
                  uncompressedSize: unpacked, headerOffset: 0)
        }
        // Chicago's CTA: 367 MB of stop times, 54 MB as its archive stores
        // them. The old fixed 80 MB line refused it on every phone.
        let cta = [entry(367_361_926, 53_821_322)]
        XCTAssertEqual(TransitFeeds.worstCaseBuildBytes(cta), 367_361_926)
        XCTAssertTrue(TransitFeeds.fitsDevice(cta, budget: 1 << 30, maxDownload: 200 << 20),
                      "a phone with a gigabyte to spare builds Chicago")
        XCTAssertFalse(TransitFeeds.fitsDevice(cta, budget: 300 << 20, maxDownload: 200 << 20),
                       "one with less than the worst case does not")
        XCTAssertFalse(TransitFeeds.fitsDevice(cta, budget: 1 << 30, maxDownload: 50 << 20),
                       "nor past the download limit")
        XCTAssertTrue(TransitFeeds.fitsDevice([entry(1_600_000, 300_000), entry(60 << 20, 9 << 20)],
                                              budget: 62 << 20, maxDownload: 10 << 20),
                      "the files add up, and these fit")
        XCTAssertFalse(TransitFeeds.fitsDevice([entry(1_600_000, 300_000), entry(61 << 20, 9 << 20)],
                                               budget: 62 << 20, maxDownload: 10 << 20))
        XCTAssertTrue(TransitFeeds.fitsDevice([], budget: 0, maxDownload: 0))
        XCTAssertGreaterThan(TransitFeeds.buildMemoryBudget, 0)
    }

    func testAFeedOnDiskIsMeasuredInEitherForm() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flows-fit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0x41, count: 1_000).write(to: dir.appendingPathComponent("stops.txt"))
        var packed = Data("FZ01".utf8) + Data([0, 0, 0, 0])
        withUnsafeBytes(of: UInt64(5_000_000).littleEndian) { packed.append(contentsOf: $0) }
        packed.append(Data(repeating: 0, count: 10))
        try packed.write(to: dir.appendingPathComponent("stop_times.txt.fz"))
        try Data("not ours".utf8).write(to: dir.appendingPathComponent("shapes.txt"))
        XCTAssertEqual(TransitFeeds.worstCaseBuildBytes(feedDirectory: dir), 5_001_000,
                       "the packed header's length and the plain file's; shapes.txt is never read")
    }

    func testAFileIsCopiedAPieceAtATimeAfterItsHeader() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flows-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("chunk")
        let bytes = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: source)
        let target = dir.appendingPathComponent("stop_times.txt.fz")
        let range = 1_234..<2_600_000   // spans pieces of a megabyte
        try TransitFeeds.copy(source, range, to: target, after: Data("HEAD".utf8))
        XCTAssertEqual(try Data(contentsOf: target), Data("HEAD".utf8) + bytes.subdata(in: range))
        XCTAssertThrowsError(
            try TransitFeeds.copy(source, 2_999_000..<3_000_500, to: target, after: Data()),
            "a download that came down short is not copied as if whole")
    }

    func testAHostThatWillNotServeRangesIsJudgedByItsWholeSize() {
        let limit = 60 << 20
        XCTAssertTrue(TransitFeeds.acceptsDownload(length: 400 << 20, servesRanges: true, limit: limit),
                      "with ranges only the index and a few files come down")
        XCTAssertFalse(TransitFeeds.acceptsDownload(length: 400 << 20, servesRanges: false, limit: limit),
                       "without them, 400 MB would land in a phone's memory")
        XCTAssertTrue(TransitFeeds.acceptsDownload(length: 20 << 20, servesRanges: false, limit: limit))
        XCTAssertTrue(TransitFeeds.acceptsDownload(length: nil, servesRanges: false, limit: limit),
                      "unknown length: the session's resource limit is the backstop")
    }
}
