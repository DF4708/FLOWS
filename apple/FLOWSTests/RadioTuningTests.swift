// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// The NOAA Weather Radio tuner: does it play the station for where the
/// vehicle IS, and does it hand off cleanly when the drive crosses into the
/// next transmitter's coverage?
final class RadioTuningTests: XCTestCase {
    private func station(_ id: String, _ lat: Double, _ lon: Double,
                         exact: Bool = true) -> RadioTuning.Station {
        RadioTuning.Station(id: id,
                            coordinate: CLLocationCoordinate2D(latitude: lat,
                                                               longitude: lon),
                            isExact: exact)
    }

    /// Three real transmitters roughly along I-94 in Wisconsin.
    private var wisconsin: [RadioTuning.Station] {
        [station("Madison", 43.07, -89.40),
         station("Milwaukee", 43.04, -87.91),
         station("Green Bay", 44.51, -88.02)]
    }

    func testPicksTheTransmitterYouAreSittingUnder() {
        let atMadison = CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40)
        XCTAssertEqual(RadioTuning.nearest(to: atMadison, in: wisconsin)?.station.id,
                       "Madison")
    }

    func testHandsOffOnceTheNextStationIsClearlyCloser() {
        // Arrived in Milwaukee with the Madison relay still playing.
        let atMilwaukee = CLLocationCoordinate2D(latitude: 43.04, longitude: -87.91)
        let next = RadioTuning.retarget(
            playingID: "Madison",
            playingCoordinate: CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40),
            position: atMilwaukee, stations: wisconsin)
        XCTAssertEqual(next, "Milwaukee")
    }

    func testDoesNotFlapOnTheBoundaryBetweenTwoCoverageAreas() {
        // Halfway between the two, where the distances are equal: switching
        // here would flip back and forth every few seconds down the highway.
        let halfway = CLLocationCoordinate2D(latitude: 43.055, longitude: -88.655)
        let next = RadioTuning.retarget(
            playingID: "Madison",
            playingCoordinate: CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40),
            position: halfway, stations: wisconsin)
        XCTAssertNil(next)
    }

    func testStaysPutWhenTheStationPlayingIsAlreadyTheClosest() {
        let atMadison = CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40)
        XCTAssertNil(RadioTuning.retarget(
            playingID: "Madison",
            playingCoordinate: CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40),
            position: atMadison, stations: wisconsin))
    }

    func testNeverStartsPlayingOnItsOwn() {
        // Nothing on the air — driving anywhere must not begin audio.
        XCTAssertNil(RadioTuning.retarget(
            playingID: nil, playingCoordinate: nil,
            position: CLLocationCoordinate2D(latitude: 43.04, longitude: -87.91),
            stations: wisconsin))
    }

    func testAnUnplaceableStationYieldsToAnyLocatedOne() {
        // The playing relay came off the directory with no coordinates; any
        // station the app can actually place is an improvement.
        let next = RadioTuning.retarget(
            playingID: "Unknown", playingCoordinate: nil,
            position: CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40),
            stations: wisconsin)
        XCTAssertEqual(next, "Madison")
    }

    func testAnExactListingWinsATieWithAStateFallback() {
        let here = CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40)
        let both = [station("guessed", 43.07, -89.40, exact: false),
                    station("listed", 43.07, -89.40)]
        XCTAssertEqual(RadioTuning.nearest(to: here, in: both)?.station.id, "listed")
    }

    func testTheShippedStationListCoversTheCountry() {
        // The bundled relays are what auto-tune has to work with — every one
        // of them must carry a position, or it is invisible to the tuner.
        guard let url = Bundle(for: Self.self)
            .url(forResource: "nwr_stations", withExtension: "json")
        else { return XCTFail("nwr_stations.json is not in the bundle") }
        struct Row: Decodable { var name: String; var latitude: Double?; var longitude: Double? }
        let rows = try? JSONDecoder().decode([Row].self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(rows?.count ?? 0, 50)
        XCTAssertTrue(rows?.allSatisfy { $0.latitude != nil && $0.longitude != nil } ?? false)
    }
}
