// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// The rules behind the iOS 27 Siri schema intents: a Siri trip ask never
/// replans the road being driven, a stop already on the trip is not added
/// twice, and identifiers Siri hands back only ever name FLOWS's own places
/// and stations.
final class SiriSchemaRulesTests: XCTestCase {
    typealias R = SiriSchemaRules

    // MARK: trip requests

    func testPlanKeepsTheModeOnScreenWhenTheAskMatches() {
        XCTAssertEqual(
            R.tripRequest(
                mode: .driving, preferences: [], walkingNow: false,
                filters: [], tripUnderway: false),
            .plan(walking: nil, addFilters: []))
        XCTAssertEqual(
            R.tripRequest(
                mode: .walking, preferences: [], walkingNow: true,
                filters: [.noTolls], tripUnderway: true),
            .plan(walking: nil, addFilters: []))
    }

    func testPlanSwitchesModeAndAddsOnlyMissingFiltersWhenNoTrip() {
        XCTAssertEqual(
            R.tripRequest(
                mode: .walking, preferences: [], walkingNow: false,
                filters: [], tripUnderway: false),
            .plan(walking: true, addFilters: []))
        XCTAssertEqual(
            R.tripRequest(
                mode: .driving, preferences: [.avoidTolls, .avoidHighways],
                walkingNow: true, filters: [.noTolls], tripUnderway: false),
            .plan(walking: false, addFilters: [.noHighways]))
    }

    func testAnAskThatChangesTheLiveTripMustWaitForItToEnd() {
        XCTAssertEqual(
            R.tripRequest(
                mode: .walking, preferences: [], walkingNow: false,
                filters: [], tripUnderway: true), .finishTripFirst)
        XCTAssertEqual(
            R.tripRequest(
                mode: .driving, preferences: [.avoidHighways], walkingNow: false,
                filters: [.noTolls], tripUnderway: true), .finishTripFirst)
        // A preference already on is no change.
        XCTAssertEqual(
            R.tripRequest(
                mode: .driving, preferences: [.avoidTolls], walkingNow: false,
                filters: [.noTolls, .avoidTraffic], tripUnderway: true),
            .plan(walking: nil, addFilters: []))
    }

    func testPreferencesReportOnlyTheTwoSiriKnowsInAFixedOrder() {
        XCTAssertEqual(R.preferences(in: []), [])
        XCTAssertEqual(
            R.preferences(in: [.noHighways, .avoidTraffic, .noTolls]),
            [.avoidTolls, .avoidHighways])
        XCTAssertEqual(R.preferences(in: [.bridgeWeight, .noHighways]), [.avoidHighways])
        XCTAssertEqual(R.TripPreference.avoidTolls.filter, .noTolls)
        XCTAssertEqual(R.TripPreference.avoidHighways.filter, .noHighways)
        XCTAssertEqual(R.TripMode(walking: true), .walking)
        XCTAssertFalse(R.TripMode.driving.walks)
    }

    // MARK: waypoints

    private func c(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func testStopsAlreadyOnTheTripAreNotAddedAgain() {
        let home = c(40.0, -75.0)
        // ~55 m north of home: the same stop. ~1.1 km north: a new one.
        let near = c(40.0005, -75.0)
        let far = c(40.01, -75.0)
        XCTAssertEqual(R.newWaypoints([near, far], existing: [home]), [1])
        XCTAssertEqual(R.newWaypoints([home], existing: [home]), [])
        XCTAssertEqual(R.newWaypoints([far], existing: []), [0])
    }

    func testTheSameStopAskedTwiceCountsOnce() {
        let a = c(41.0, -74.0)
        let a2 = c(41.0009, -74.0)  // ~100 m away
        let b = c(41.1, -74.0)
        XCTAssertEqual(R.newWaypoints([a, a2, b, a], existing: []), [0, 2])
    }

    func testPointsNotOnEarthAreSkipped() {
        let bad = [c(.nan, 0), c(91, 0), c(0, 181), c(.infinity, 3)]
        XCTAssertEqual(R.newWaypoints(bad + [c(10, 10)], existing: []), [4])
    }

    // MARK: identifiers

    func testPlaceIDsRoundTrip() throws {
        let id = try XCTUnwrap(R.placeID(c(37.774929, -122.419416), name: "Main St, Suite 4"))
        let back = try XCTUnwrap(R.place(fromID: id))
        XCTAssertEqual(back.coordinate.latitude, 37.774929, accuracy: 1e-6)
        XCTAssertEqual(back.coordinate.longitude, -122.419416, accuracy: 1e-6)
        XCTAssertEqual(back.name, "Main St, Suite 4")  // commas in the name survive
        let unnamed = try XCTUnwrap(R.placeID(c(1, 2), name: nil))
        XCTAssertNil(try XCTUnwrap(R.place(fromID: unnamed)).name)
    }

    func testPlaceIDsRejectBadInput() {
        XCTAssertNil(R.placeID(c(.nan, 0), name: "x"))
        XCTAssertNil(R.place(fromID: ""))
        XCTAssertNil(R.place(fromID: "12.0,13.0"))
        XCTAssertNil(R.place(fromID: "abc,13.0,x"))
        XCTAssertNil(R.place(fromID: "95.0,13.0,x"))
        XCTAssertNil(R.place(fromID: "1.0,2.0," + String(repeating: "a", count: R.maxNameLength + 1)))
        // A long name is cut so the identifier still reads back.
        let long = String(repeating: "b", count: R.maxNameLength + 50)
        XCTAssertEqual(R.place(fromID: R.placeID(c(1, 2), name: long)!)?.name?.count, R.maxNameLength)
    }

    func testStationRefsRoundTripAndRejectStrangers() {
        let radio = R.StationRef.directory(url: "https://stream.example/a.mp3")
        XCTAssertEqual(R.StationRef(id: radio.id), radio)
        let wx = R.StationRef.weather(name: "KEC49 Philadelphia")
        XCTAssertEqual(R.StationRef(id: wx.id), wx)
        XCTAssertNil(R.StationRef(id: "https://stream.example/a.mp3"))
        XCTAssertNil(R.StationRef(id: "radio:"))
        XCTAssertNil(R.StationRef(id: "weather:"))
        XCTAssertNil(R.StationRef(id: "radio:" + String(repeating: "u", count: R.maxURLLength + 1)))
        XCTAssertNil(R.StationRef(id: "weather:" + String(repeating: "n", count: R.maxNameLength + 1)))
    }

    // MARK: stations

    func testWeatherRadioIsAskedByWord() {
        XCTAssertTrue(R.wantsWeatherRadio("NOAA weather radio"))
        XCTAssertTrue(R.wantsWeatherRadio("the Weather station"))
        XCTAssertTrue(R.wantsWeatherRadio("noaa"))
        XCTAssertFalse(R.wantsWeatherRadio("Weatherly FM"))
        XCTAssertFalse(R.wantsWeatherRadio("jazz"))
        XCTAssertFalse(R.wantsWeatherRadio(""))
    }

    func testStationsRankExactThenContainsThenRest() {
        let names = ["Classic Rock 101", "WXPN", "Rock", "Jazz 88", "Rôck Hits"]
        XCTAssertEqual(R.rankStations(names: names, query: " rock "), [2, 0, 4, 1, 3])
        XCTAssertEqual(R.rankStations(names: names, query: ""), [0, 1, 2, 3, 4])
        XCTAssertEqual(R.rankStations(names: names, query: "rock", limit: 2), [2, 0])
        XCTAssertEqual(R.rankStations(names: names, query: "rock", limit: -1), [])
        let many = (0..<30).map { "Station \($0)" }
        XCTAssertEqual(R.rankStations(names: many, query: "x").count, R.maxStations)
    }
}
