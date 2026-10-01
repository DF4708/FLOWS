// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// The owner's second October round: city 911 lists as pins, logos and local
/// tiles in the stop list, and buttons in even rows.
final class OpenDispatchTests: XCTestCase {
    private let sf = OpenDispatch.feeds.first { $0.id == "sf-police" }!
    private let seattle = OpenDispatch.feeds.first { $0.id == "seattle-fire" }!

    /// "2026-10-01T14:48:13.000" in the feed's own clock.
    private func date(_ text: String, _ zone: String = "America/Los_Angeles") -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: zone)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f.date(from: text)!
    }

    func testSanFranciscoUrgentCallsBecomePolicePins() throws {
        let rows = """
        [{"cad_number":"1","received_datetime":"2026-10-01T14:48:13.000",
          "call_type_final_desc":"SHOTS FIRED","priority_final":"A",
          "intersection_name":"DUBOCE AVE \\\\ NOE ST",
          "intersection_point":{"type":"Point","coordinates":[-122.4335,37.7691]}},
         {"cad_number":"2","received_datetime":"2026-10-01T14:47:54.000",
          "call_type_final_desc":"TRAFFIC STOP","priority_final":"C",
          "intersection_point":{"type":"Point","coordinates":[-122.43,37.77]}},
         {"cad_number":"3","received_datetime":"2026-10-01T12:00:00.000",
          "call_type_final_desc":"ROBBERY","priority_final":"A",
          "intersection_point":{"type":"Point","coordinates":[-122.42,37.78]}},
         {"cad_number":"4","received_datetime":"2026-10-01T14:40:00.000",
          "call_type_final_desc":"ASSAULT","priority_final":"B",
          "intersection_point":{"type":"Point","coordinates":[0,0]}}]
        """
        let now = date("2026-10-01T15:05:00.000")
        let pins = OpenDispatch.incidents(from: Data(rows.utf8), feed: sf, now: now)
        // Routine C calls, calls hours old and rows with no place are left out.
        XCTAssertEqual(pins.map(\.id), ["sf-police|1"])
        let shots = try XCTUnwrap(pins.first)
        XCTAssertEqual(shots.kind, .police)
        XCTAssertEqual(shots.coordinate.latitude, 37.7691, accuracy: 1e-9)
        XCTAssertTrue(shots.placeText.hasPrefix("Shots fired — DUBOCE AVE"))
        XCTAssertEqual(shots.heardAt, date("2026-10-01T14:48:13.000"))
        XCTAssertEqual(shots.lifetime, 3_600, "an hour: the city publishes ~20 minutes late")
        XCTAssertTrue(OpenDispatch.isThreat(shots))
    }

    func testSeattleCallsTakeTheirKindFromTheirName() {
        let rows = """
        [{"incident_number":"F1","type":"Aid Response","datetime":"2026-10-01T14:58:00.000",
          "latitude":"47.674083","longitude":"-122.25953","address":"6346 Ne Radford Dr"},
         {"incident_number":"F2","type":"Automatic Fire Alarm Resd","datetime":"2026-10-01T14:59:00.000",
          "latitude":"47.6","longitude":"-122.3","address":"1 Main St"},
         {"incident_number":"F3","type":"Fire in Building","datetime":"2026-10-01T15:00:00.000",
          "latitude":"47.61","longitude":"-122.31","address":"2 Main St"},
         {"incident_number":"F4","type":"MVI - Motor Vehicle Incident","datetime":"2026-10-01T15:01:00.000",
          "latitude":"47.62","longitude":"-122.32","address":"3 Main St"}]
        """
        let now = date("2026-10-01T15:05:00.000")
        let pins = OpenDispatch.incidents(from: Data(rows.utf8), feed: seattle, now: now)
        XCTAssertEqual(pins.map(\.kind), [.medical, .fire, .fire, .traffic])
        XCTAssertEqual(pins.map(OpenDispatch.isThreat), [false, false, true, false],
                       "a fire alarm going off is not a fire")
        XCTAssertTrue(OpenDispatch.incidents(from: Data("<html>".utf8), feed: seattle).isEmpty)
    }

    func testTheFeedForWhereTheDriverIs() {
        let mission = CLLocationCoordinate2D(latitude: 37.76, longitude: -122.42)
        XCTAssertEqual(OpenDispatch.covering(mission).map(\.id), ["sf-police"])
        let madison = CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40)
        XCTAssertTrue(OpenDispatch.covering(madison).isEmpty, "no Wisconsin city publishes one yet")
        XCTAssertEqual(OpenDispatch.byDistance(from: madison).count, OpenDispatch.feeds.count)
    }
}

final class StopTileTests: XCTestCase {
    func testMajorChainsHaveALogoAndLocalPlacesDoNot() {
        XCTAssertEqual(BrandMark.logoDomain(for: "Walmart Supercenter"), "walmart.com")
        XCTAssertEqual(BrandMark.logoDomain(for: "Starbucks"), "starbucks.com")
        XCTAssertEqual(BrandMark.logoDomain(for: "Holiday Inn Express"), "ihg.com",
                       "the hotel, not the Holiday gas stations")
        XCTAssertEqual(BrandMark.logoDomain(for: "Holiday Stationstores"), "holidaystationstores.com")
        XCTAssertNil(BrandMark.logoDomain(for: "Napa Valley Grill"))
        XCTAssertNil(BrandMark.logoDomain(for: "Rheta's Market"))
        XCTAssertNil(BrandMark.logoURL(for: "Starbucks", clientID: ""),
                     "no client ID: no logo is asked for")
        XCTAssertEqual(BrandMark.logoURL(for: "Starbucks", clientID: "abc")?.absoluteString,
                       "https://cdn.brandfetch.io/domain/starbucks.com/w/96/h/96/fallback/404/type/icon?c=abc")
    }

    func testLocalPlacesGetInitialsFromTheirName() {
        XCTAssertEqual(LocalMarks.initialCandidates("Rheta's Market").first, "RM")
        XCTAssertEqual(LocalMarks.initialCandidates("The Corner Cafe").first, "CC")
        XCTAssertEqual(LocalMarks.initialCandidates("Sushi").first, "SU")
        XCTAssertEqual(LocalMarks.initialCandidates("").first, "?")
    }

    func testNoTwoLocalTilesInAListMatch() {
        // Same initials everywhere: the colours must all differ.
        let names = (0..<12).map { "Main Street \($0)" }
        let marks = LocalMarks.assign(names)
        let pairs = marks.map { "\($0.initials)|\($0.background.r)|\($0.background.g)|\($0.background.b)" }
        XCTAssertEqual(Set(pairs).count, names.count)
        // The same name keeps the same tile from one list to the next.
        XCTAssertEqual(LocalMarks.assign(["Rheta's Market"]), LocalMarks.assign(["Rheta's Market"]))
    }
}

final class BalancedRowsTests: XCTestCase {
    func testButtonsShareRowsEvenly() {
        XCTAssertEqual(BalancedRows.counts(items: 9, fitPerRow: 4), [3, 3, 3])
        XCTAssertEqual(BalancedRows.counts(items: 7, fitPerRow: 4), [4, 3])
        XCTAssertEqual(BalancedRows.counts(items: 5, fitPerRow: 4), [3, 2])
        XCTAssertEqual(BalancedRows.counts(items: 9, fitPerRow: 9), [9])
        XCTAssertEqual(BalancedRows.counts(items: 3, fitPerRow: 2), [1, 1, 1],
                       "never one alone beside a fuller row")
        XCTAssertEqual(BalancedRows.counts(items: 0, fitPerRow: 4), [])
    }
}
