// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// The clock rules, and the whole path from a schedule feed on disk to a time
/// a rider reads. Times in a GTFS feed are stored in the operator's zone, not
/// the station's, and the service day starts at noon-minus-12h, not midnight —
/// both are silent, plausible, hours-wrong failures if taken the easy way.
final class TransitTimesTests: XCTestCase {
    /// Foundation writes a NARROW NO-BREAK SPACE (U+202F) before AM/PM, which
    /// looks exactly like a space and is not one.
    private func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ")
    }
    private let us = Locale(identifier: "en_US")
    private let eastern = "America/New_York"

    // MARK: the clock

    func testStoredTimesAreTheAgencysNotTheStations() {
        // Amtrak keeps Eastern time for the whole network, so the Coast
        // Starlight's Seattle departure is stored as 12:55:00.
        let moment = TransitClock.instant(
            serviceDate: 20260923, agencyZone: eastern, seconds: 12 * 3600 + 55 * 60
        )
        guard let dep = moment else { return XCTFail("no instant") }
        XCTAssertEqual(
            plain(TransitClock.clock(dep, zone: "America/Los_Angeles", locale: us)), "9:55 AM",
            "a Seattle departure stored as 12:55 Eastern is 9:55 AM on the platform"
        )
        XCTAssertEqual(plain(TransitClock.clock(dep, zone: eastern, locale: us)), "12:55 PM")
    }

    func testServiceDayStartsAtNoonMinusTwelveHoursNotMidnight() {
        // On the two days a year the clocks change, midnight is the wrong
        // anchor — an hour late in spring, an hour early in autumn.
        for date in [20270314, 20271107, 20260923] {
            let moment = TransitClock.instant(
                serviceDate: date, agencyZone: eastern, seconds: 8 * 3600
            )
            guard let moment else { return XCTFail("no instant for \(date)") }
            XCTAssertEqual(
                plain(TransitClock.clock(moment, zone: eastern, locale: us)), "8:00 AM",
                "08:00:00 is 8 AM on \(date) too"
            )
        }
    }

    func testTimesPastMidnightStayOnTheirOwnServiceDay() {
        let moment = TransitClock.instant(
            serviceDate: 20260923, agencyZone: eastern, seconds: 25 * 3600 + 30 * 60
        )
        guard let moment else { return XCTFail("no instant") }
        XCTAssertEqual(plain(TransitClock.clock(moment, zone: eastern, locale: us)), "1:30 AM")
    }

    func testImpossibleDatesAndZonesAreRefused() {
        XCTAssertNil(TransitClock.dayStart(serviceDate: 20260231, agencyZone: eastern),
                     "February 31st must be refused, not rolled into March")
        XCTAssertNil(TransitClock.instant(serviceDate: 20260923, agencyZone: "Mars/Olympus", seconds: 0))
        XCTAssertNil(TransitClock.instant(serviceDate: 20260923, agencyZone: eastern, seconds: -1))
    }

    func testTheZoneIsNamedOnlyWhenTheTripCrossesOne() {
        let board = TransitClock.instant(serviceDate: 20260923, agencyZone: eastern, seconds: 7 * 3600 + 15 * 60)
        let alight = TransitClock.instant(serviceDate: 20260923, agencyZone: eastern, seconds: 8 * 3600 + 57 * 60)
        guard let board, let alight else { return XCTFail("no instants") }
        XCTAssertEqual(
            plain(TransitClock.span(board: board, boardZone: "America/Chicago",
                                    alight: alight, alightZone: "America/Chicago", locale: us)),
            "6:15 AM – 7:57 AM"
        )
        XCTAssertEqual(
            plain(TransitClock.span(board: board, boardZone: "America/Denver",
                                    alight: alight, alightZone: "America/Chicago", locale: us)),
            "5:15 AM – 7:57 AM Central time",
            "crossing a zone, the arrival says which clock it is on"
        )
    }

    func testZoneWordsAreWordsARiderWouldUse() {
        XCTAssertEqual(TransitClock.zoneWord("America/Chicago", locale: us), "Central")
        XCTAssertEqual(TransitClock.zoneWord("America/Los_Angeles", locale: us), "Pacific")
        XCTAssertEqual(TransitClock.zoneWord("Mars/Olympus", locale: us), "")
    }

    // MARK: the whole path — a feed on disk becomes a departure board

    /// A feed shaped like Amtrak's: the agency keeps Eastern time while the
    /// stations are in Central and Mountain.
    private func writeFeed() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flows-transit-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files: [String: String] = [
            "agency.txt": "agency_id,agency_name,agency_timezone\n1,Test Rail,America/New_York\n",
            "feed_info.txt":
                "feed_publisher_name,feed_publisher_url,feed_lang,feed_version\n"
                + "Test,http://example.invalid,en,20260921\n",
            "stops.txt":
                "stop_id,stop_name,stop_timezone,stop_lat,stop_lon\n"
                + "MKE,Milwaukee Intermodal Station,America/Chicago,43.0344,-87.9176\n"
                + "CHI,Chicago Union Station,America/Chicago,41.8789,-87.6399\n"
                + "DEN,Denver Union Station,America/Denver,39.7525,-105.0000\n",
            "routes.txt":
                "route_id,route_short_name,route_long_name,route_type\nR1,,Hiawatha Service,2\n"
                + "R2,,Mountain Flyer,2\n",
            "calendar.txt":
                "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,"
                + "start_date,end_date\nWK,1,1,1,1,1,1,1,20260901,20261231\n",
            "trips.txt": "route_id,service_id,trip_id\nR1,WK,t1\nR2,WK,t2\n",
            "stop_times.txt":
                "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n"
                + "t1,07:15:00,07:15:00,MKE,1\n"
                + "t1,08:57:00,08:57:00,CHI,2\n"
                + "t2,10:00:00,10:00:00,CHI,1\n"
                + "t2,22:00:00,22:00:00,DEN,2\n",
        ]
        for (name, body) in files {
            try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir.path
    }

    func testAFeedOnDiskBecomesRealDepartureTimes() throws {
        let feed = try writeFeed()
        defer { try? FileManager.default.removeItem(atPath: feed) }
        let prefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("flows-transit-shard-\(UUID().uuidString)").path
        defer {
            try? FileManager.default.removeItem(atPath: prefix + ".ftt")
            try? FileManager.default.removeItem(atPath: prefix + ".fts")
        }

        XCTAssertEqual(TransitShard.agencyZone(feedDirectory: feed), eastern,
                       "the zone is readable before the timetable is built")

        let stamp = try TransitShard.build(
            feedDirectory: feed, prefix: prefix, serviceDate: 20260923
        )
        XCTAssertEqual(stamp.serviceDate, 20260923)
        XCTAssertEqual(stamp.agencyZone, eastern)
        XCTAssertEqual(stamp.published, 20260921)

        let milwaukee = CLLocationCoordinate2D(latitude: 43.0389, longitude: -87.9065)
        let chicago = CLLocationCoordinate2D(latitude: 41.8781, longitude: -87.6298)
        let sixThirtyAM = try XCTUnwrap(
            TransitClock.instant(serviceDate: 20260923, agencyZone: eastern, seconds: 6 * 3600)
        )
        let answer = try TransitShard.departures(
            prefix: prefix, from: milwaukee, to: chicago, departing: sixThirtyAM, stamp: stamp
        )

        XCTAssertEqual(answer.ends.boardName, "Milwaukee Intermodal Station")
        XCTAssertEqual(answer.ends.boardCode, "MKE")
        XCTAssertEqual(answer.ends.alightCode, "CHI")
        XCTAssertLessThan(answer.ends.boardMeters, 2_000)

        let first = try XCTUnwrap(answer.departures.first)
        XCTAssertEqual(first.transfers, 0)
        XCTAssertEqual(first.rides.count, 1)
        XCTAssertEqual(first.rides[0].routeName, "Hiawatha Service")
        XCTAssertEqual(first.departSeconds, 7 * 3600 + 15 * 60, "stored in the agency's zone")

        let board = try XCTUnwrap(TransitShard.moment(first.departSeconds, stamp))
        let alight = try XCTUnwrap(TransitShard.moment(first.arriveSeconds, stamp))
        XCTAssertEqual(
            plain(TransitClock.clock(board, zone: first.rides[0].boardZone, locale: us)), "6:15 AM",
            "the rider catches the 6:15, not the 7:15 the file stores"
        )
        XCTAssertEqual(
            plain(TransitClock.clock(alight, zone: first.rides[0].alightZone, locale: us)), "7:57 AM"
        )
    }

    func testCrossingZonesTheArrivalIsTheArrivalStationsClock() throws {
        let feed = try writeFeed()
        defer { try? FileManager.default.removeItem(atPath: feed) }
        let prefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("flows-transit-shard-\(UUID().uuidString)").path
        defer {
            try? FileManager.default.removeItem(atPath: prefix + ".ftt")
            try? FileManager.default.removeItem(atPath: prefix + ".fts")
        }
        let stamp = try TransitShard.build(
            feedDirectory: feed, prefix: prefix, serviceDate: 20260923
        )
        let answer = try TransitShard.departures(
            prefix: prefix,
            from: CLLocationCoordinate2D(latitude: 41.8781, longitude: -87.6298),
            to: CLLocationCoordinate2D(latitude: 39.7392, longitude: -104.9903),
            departing: try XCTUnwrap(
                TransitClock.instant(serviceDate: 20260923, agencyZone: eastern, seconds: 6 * 3600)
            ),
            stamp: stamp
        )
        let ride = try XCTUnwrap(answer.departures.first?.rides.first)
        let board = try XCTUnwrap(TransitShard.moment(ride.departSeconds, stamp))
        let alight = try XCTUnwrap(TransitShard.moment(ride.arriveSeconds, stamp))
        XCTAssertEqual(plain(TransitClock.clock(board, zone: ride.boardZone, locale: us)), "9:00 AM",
                       "10:00 Eastern leaves Chicago at 9 AM")
        XCTAssertEqual(plain(TransitClock.clock(alight, zone: ride.alightZone, locale: us)), "8:00 PM",
                       "22:00 Eastern arrives in Denver at 8 PM, not 10 PM")
    }

    func testAskingOnTheWrongDayIsRefusedNotAnswered() throws {
        let feed = try writeFeed()
        defer { try? FileManager.default.removeItem(atPath: feed) }
        let prefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("flows-transit-shard-\(UUID().uuidString)").path
        defer {
            try? FileManager.default.removeItem(atPath: prefix + ".ftt")
            try? FileManager.default.removeItem(atPath: prefix + ".fts")
        }
        let stamp = try TransitShard.build(
            feedDirectory: feed, prefix: prefix, serviceDate: 20260923
        )
        let tomorrow = try XCTUnwrap(
            TransitClock.instant(serviceDate: 20260925, agencyZone: eastern, seconds: 9 * 3600)
        )
        XCTAssertThrowsError(
            try TransitShard.departures(
                prefix: prefix,
                from: CLLocationCoordinate2D(latitude: 43.0389, longitude: -87.9065),
                to: CLLocationCoordinate2D(latitude: 41.8781, longitude: -87.6298),
                departing: tomorrow, stamp: stamp
            ),
            "yesterday's timetable must not answer today's question"
        )
    }

    func testNoStationNearbyIsSaidInPlainWords() throws {
        let feed = try writeFeed()
        defer { try? FileManager.default.removeItem(atPath: feed) }
        let prefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("flows-transit-shard-\(UUID().uuidString)").path
        defer {
            try? FileManager.default.removeItem(atPath: prefix + ".ftt")
            try? FileManager.default.removeItem(atPath: prefix + ".fts")
        }
        let stamp = try TransitShard.build(
            feedDirectory: feed, prefix: prefix, serviceDate: 20260923
        )
        do {
            _ = try TransitShard.departures(
                prefix: prefix,
                from: CLLocationCoordinate2D(latitude: 21.3069, longitude: -157.8583),
                to: CLLocationCoordinate2D(latitude: 41.8781, longitude: -87.6298),
                departing: try XCTUnwrap(
                    TransitClock.instant(serviceDate: 20260923, agencyZone: eastern, seconds: 6 * 3600)
                ),
                stamp: stamp
            )
            XCTFail("Honolulu is not near a station in this feed")
        } catch let failure as TransitShard.Failure {
            XCTAssertEqual(failure, .noneNearby)
            XCTAssertFalse(failure.plainText.contains("/"), "no file paths in rider-facing words")
            XCTAssertFalse(failure.plainText.contains("ftt"))
        }
    }

    // MARK: what the card ends up saying

    private func answer(
        rides: [TransitShard.Ride], laterDepartures: [Int] = [], transfers: Int = 0,
        published: Int = 20260921
    ) -> TransitShard.Answer {
        let stamp = TransitShard.Stamp(
            serviceDate: 20260923, published: published, agencyZone: eastern
        )
        let first = TransitShard.Departure(
            rides: rides,
            departSeconds: rides.first?.departSeconds ?? 0,
            arriveSeconds: rides.last?.arriveSeconds ?? 0,
            transfers: transfers, walkSeconds: 0
        )
        let later = laterDepartures.map { secs in
            TransitShard.Departure(
                rides: rides, departSeconds: secs, arriveSeconds: secs + 3600,
                transfers: transfers, walkSeconds: 0
            )
        }
        return TransitShard.Answer(
            stamp: stamp,
            ends: TransitShard.Ends(
                boardName: rides.first?.boardName ?? "", boardCode: "", boardZone: "",
                boardMeters: 400,
                alightName: rides.last?.alightName ?? "", alightCode: "", alightZone: "",
                alightMeters: 900
            ),
            departures: [first] + later
        )
    }

    private func ride(
        _ route: String, board: String, boardZone: String, depart: Int,
        alight: String, alightZone: String, arrive: Int
    ) -> TransitShard.Ride {
        TransitShard.Ride(
            boardName: board, boardCode: "", boardZone: boardZone,
            alightName: alight, alightCode: "", alightZone: alightZone,
            routeName: route, mode: 0, departSeconds: depart, arriveSeconds: arrive
        )
    }

    func testTheCardNamesTheTrainAndTheClockTheRiderReads() throws {
        let hiawatha = ride(
            "Hiawatha Service",
            board: "Milwaukee Intermodal Station", boardZone: "America/Chicago",
            depart: 7 * 3600 + 15 * 60,
            alight: "Chicago Union Station", alightZone: "America/Chicago",
            arrive: 8 * 3600 + 57 * 60
        )
        let schedule = try XCTUnwrap(TransitShard.schedule(
            from: answer(rides: [hiawatha], laterDepartures: [9 * 3600 + 15 * 60,
                                                              11 * 3600 + 15 * 60]),
            credit: "Schedule from Amtrak", locale: us
        ))
        XCTAssertEqual(plain(schedule.clockSpan), "6:15 AM – 7:57 AM")
        XCTAssertEqual(schedule.routeName, "Hiawatha Service")
        XCTAssertEqual(plain(schedule.plainLine), "6:15 AM – 7:57 AM · Hiawatha Service")
        XCTAssertEqual(plain(schedule.laterLine), "Then 8:15 AM, 10:15 AM")
        XCTAssertEqual(schedule.rideSeconds, 102 * 60)
        XCTAssertEqual(schedule.asOf, "Times as of Sep 21")
        XCTAssertEqual(schedule.boardName, "Milwaukee Intermodal Station")
    }

    func testAChangeOfTrainsIsSaidPlainlyNotNamedAfterTheFirst() throws {
        let one = ride("Hiawatha Service", board: "Milwaukee Intermodal Station",
                       boardZone: "America/Chicago", depart: 7 * 3600,
                       alight: "Chicago Union Station", alightZone: "America/Chicago",
                       arrive: 9 * 3600)
        let two = ride("Southwest Chief", board: "Chicago Union Station",
                       boardZone: "America/Chicago", depart: 10 * 3600,
                       alight: "Kansas City", alightZone: "America/Chicago",
                       arrive: 18 * 3600)
        let schedule = try XCTUnwrap(TransitShard.schedule(
            from: answer(rides: [one, two], transfers: 1),
            credit: "Schedule from Amtrak", locale: us
        ))
        XCTAssertEqual(schedule.routeName, "1 change",
                       "naming only the first train would hide the change")
        XCTAssertEqual(schedule.alightName, "Kansas City", "the far end, not the first stop")
    }

    func testALastTrainSaysNothingAboutALaterOne() throws {
        let last = ride("Empire Builder", board: "Milwaukee Intermodal Station",
                        boardZone: "America/Chicago", depart: 22 * 3600,
                        alight: "Chicago Union Station", alightZone: "America/Chicago",
                        arrive: 23 * 3600 + 30 * 60)
        let schedule = try XCTUnwrap(TransitShard.schedule(
            from: answer(rides: [last]), credit: "Schedule from Amtrak", locale: us
        ))
        XCTAssertTrue(schedule.laterClocks.isEmpty)
        XCTAssertEqual(schedule.laterLine, "", "no empty 'Then' on the card")
    }

    func testAFeedThatNeverSaidWhenItWasPublishedShowsNoDate() throws {
        let hop = ride("Hiawatha Service", board: "A", boardZone: eastern, depart: 3600,
                       alight: "B", alightZone: eastern, arrive: 7200)
        let schedule = try XCTUnwrap(TransitShard.schedule(
            from: answer(rides: [hop], published: 0), credit: "Schedule from Amtrak", locale: us
        ))
        XCTAssertEqual(schedule.asOf, "")
        XCTAssertEqual(schedule.credit, "Schedule from Amtrak", "the operator is still credited")
    }

    func testAConnectingBusIsNamedNotHiddenBehindAChange() throws {
        // Amtrak reaches 110 towns only by connecting coach: Bakersfield to
        // San Diego is a bus to Los Angeles, then the Surfliner. Both belong
        // on the card, and the bus has to say it is a bus.
        let coach = TransitShard.Ride(
            boardName: "Bakersfield", boardCode: "BFD", boardZone: "America/Los_Angeles",
            alightName: "Los Angeles", alightCode: "LAX", alightZone: "America/Los_Angeles",
            routeName: "Amtrak Thruway Connecting Service", mode: 3,
            departSeconds: 12 * 3600 + 35 * 60, arriveSeconds: 14 * 3600 + 45 * 60
        )
        let surfliner = TransitShard.Ride(
            boardName: "Los Angeles", boardCode: "LAX", boardZone: "America/Los_Angeles",
            alightName: "San Diego", alightCode: "SAN", alightZone: "America/Los_Angeles",
            routeName: "Pacific Surfliner", mode: 0,
            departSeconds: 15 * 3600 + 10 * 60, arriveSeconds: 18 * 3600 + 7 * 60
        )
        let schedule = try XCTUnwrap(TransitShard.schedule(
            from: answer(rides: [coach, surfliner], transfers: 1),
            credit: "Schedule from Amtrak", locale: us
        ))
        XCTAssertEqual(schedule.legs.count, 2)
        XCTAssertEqual(schedule.legs[0].vehicle, "Bus", "the connecting leg is a bus")
        XCTAssertEqual(schedule.legs[1].vehicle, "Train")
        XCTAssertEqual(
            schedule.legs[0].vehicleLine, "Bus · Amtrak Thruway Connecting Service"
        )
        XCTAssertEqual(schedule.legs[1].vehicleLine, "Train · Pacific Surfliner")
        // Eastern in the file, Pacific on the kerb.
        XCTAssertEqual(plain(schedule.legs[0].clockSpan), "9:35 AM – 11:45 AM")
        XCTAssertEqual(plain(schedule.legs[1].clockSpan), "12:10 PM – 3:07 PM")
        XCTAssertEqual(schedule.routeName, "1 change")
    }

    func testASingleRideStillGetsOneLeg() throws {
        let hop = ride("Hiawatha Service", board: "Milwaukee", boardZone: "America/Chicago",
                       depart: 7 * 3600 + 15 * 60, alight: "Chicago",
                       alightZone: "America/Chicago", arrive: 8 * 3600 + 57 * 60)
        let schedule = try XCTUnwrap(TransitShard.schedule(
            from: answer(rides: [hop]), credit: "Schedule from Amtrak", locale: us
        ))
        XCTAssertEqual(schedule.legs.count, 1)
        XCTAssertEqual(schedule.legs[0].vehicleLine, "Train · Hiawatha Service")
    }

    func testTheVehicleIsSaidInWordsARiderUses() {
        XCTAssertEqual(TransitShard.vehicleWord(0), "Train")
        XCTAssertEqual(TransitShard.vehicleWord(1), "Subway")
        XCTAssertEqual(TransitShard.vehicleWord(2), "Bus")
        XCTAssertEqual(TransitShard.vehicleWord(3), "Bus", "a coach is a bus to the person riding it")
        XCTAssertEqual(TransitShard.vehicleWord(4), "Train")
    }
}
