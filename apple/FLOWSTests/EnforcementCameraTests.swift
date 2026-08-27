// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import XCTest

/// Fixed speed and red-light cameras: reading them out of OpenStreetMap,
/// and deciding which one is actually in front of the vehicle.
final class EnforcementCameraTests: XCTestCase {
    private let here = CLLocationCoordinate2D(latitude: 43.0700, longitude: -89.4000)

    /// A point `meters` due north of `here`.
    private func north(_ meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: here.latitude + meters / 111_320,
                               longitude: here.longitude)
    }

    private func camera(_ id: String, _ c: CLLocationCoordinate2D,
                        kind: EnforcementCameras.Kind = .speed,
                        limit: Double? = nil) -> EnforcementCameras.Camera {
        EnforcementCameras.Camera(id: id, coordinate: c, kind: kind, limitMph: limit)
    }

    // MARK: reading the tags

    func testTheCommonSpeedCameraTagIsRecognized() {
        XCTAssertEqual(EnforcementCameras.kind(fromTags: ["highway": "speed_camera"]),
                       .speed)
    }

    func testARedLightCameraIsNotFiledAsASpeedCamera() {
        XCTAssertEqual(
            EnforcementCameras.kind(fromTags: ["enforcement": "traffic_signals"]),
            .redLight)
        XCTAssertEqual(
            EnforcementCameras.kind(fromTags: ["traffic_signals": "camera"]),
            .redLight)
    }

    func testADeviceThatCatchesBothSaysSo() {
        XCTAssertEqual(EnforcementCameras.kind(
            fromTags: ["highway": "speed_camera",
                       "enforcement": "traffic_signals"]), .both)
    }

    func testOrdinaryRoadFurnitureIsNotACamera() {
        XCTAssertNil(EnforcementCameras.kind(fromTags: ["highway": "traffic_signals"]))
        XCTAssertNil(EnforcementCameras.kind(fromTags: ["amenity": "parking"]))
        XCTAssertNil(EnforcementCameras.kind(fromTags: [:]))
    }

    func testABareLimitOnACameraIsKilometresPerHour() {
        // OSM's convention: a number with no unit is km/h. Reading 50 as
        // 50 mph would warn a driver they're speeding when they're not.
        let kph = EnforcementCameras.limitMph(fromTags: ["maxspeed": "50"])
        XCTAssertEqual(kph ?? 0, 31.07, accuracy: 0.05)
        XCTAssertEqual(EnforcementCameras.limitMph(fromTags: ["maxspeed": "45 mph"]), 45)
        XCTAssertNil(EnforcementCameras.limitMph(fromTags: [:]))
    }

    // MARK: which one is in front of you

    func testTheNearestCameraAheadIsTheOneWarnedAbout() {
        let cams = [camera("far", north(500)), camera("near", north(200))]
        let hit = EnforcementCameras.imminent(among: cams, at: here,
                                              headingDegrees: 0)
        XCTAssertEqual(hit?.camera.id, "near")
    }

    func testACameraBehindYouIsNotWarnedAbout() {
        // Driving north, with the only camera to the south. Warning here
        // would teach the driver to ignore the warning.
        let cams = [camera("behind", north(-200))]
        XCTAssertNil(EnforcementCameras.imminent(among: cams, at: here,
                                                 headingDegrees: 0))
    }

    func testTheOppositeCarriagewayDoesNotTriggerAWarning() {
        // A camera 80 m back on the other side is CLOSER than one 400 m up
        // the road — distance alone picks the wrong one, so heading decides.
        let cams = [camera("oncoming", north(-80)), camera("mine", north(400))]
        let hit = EnforcementCameras.imminent(among: cams, at: here,
                                              headingDegrees: 0)
        XCTAssertEqual(hit?.camera.id, "mine")
    }

    func testACameraAlreadyPassedDropsOut() {
        let cams = [camera("underfoot", north(20))]
        XCTAssertNil(EnforcementCameras.imminent(among: cams, at: here,
                                                 headingDegrees: 0))
    }

    func testACameraTooFarOffStaysQuiet() {
        let cams = [camera("miles", north(3_000))]
        XCTAssertNil(EnforcementCameras.imminent(among: cams, at: here,
                                                 headingDegrees: 0))
    }

    func testWithNoHeadingEverythingCounts() {
        // Stopped, or a fix with no course: there is nothing better to say
        // than "there is a camera near you".
        let cams = [camera("somewhere", north(-200))]
        XCTAssertNotNil(EnforcementCameras.imminent(among: cams, at: here,
                                                    headingDegrees: nil))
        XCTAssertNotNil(EnforcementCameras.imminent(among: cams, at: here,
                                                    headingDegrees: -1))
    }

    func testBearingIsMeasuredFromNorthClockwise() {
        XCTAssertEqual(EnforcementCameras.bearingDegrees(from: here, to: north(100)),
                       0, accuracy: 0.5)
        let east = CLLocationCoordinate2D(latitude: here.latitude,
                                          longitude: here.longitude + 0.001)
        XCTAssertEqual(EnforcementCameras.bearingDegrees(from: here, to: east),
                       90, accuracy: 0.5)
    }

    // MARK: what it says

    func testTheWarningNamesTheDistanceInRoundFeet() {
        let line = EnforcementCameras.warning(
            for: camera("c", north(300)), meters: 300,
            speedMph: 30, postedLimitMph: 35)
        XCTAssertTrue(line.hasPrefix("Speed camera in "), line)
        XCTAssertTrue(line.contains("feet"), line)
    }

    func testTheLimitIsOnlyMentionedWhenTheDriverIsOverIt() {
        let legal = EnforcementCameras.warning(
            for: camera("c", north(300), limit: 35), meters: 300,
            speedMph: 33, postedLimitMph: 35)
        XCTAssertFalse(legal.contains("limit"), legal)
        let speeding = EnforcementCameras.warning(
            for: camera("c", north(300), limit: 35), meters: 300,
            speedMph: 48, postedLimitMph: 35)
        XCTAssertTrue(speeding.contains("limit 35"), speeding)
    }

    func testTheCamerasOwnLimitBeatsTheRoads() {
        // A school-zone camera enforcing 20 on a 35 road: the camera's
        // number is the one that matters at that spot.
        let line = EnforcementCameras.warning(
            for: camera("c", north(300), limit: 20), meters: 300,
            speedMph: 34, postedLimitMph: 35)
        XCTAssertTrue(line.contains("limit 20"), line)
    }

    func testARedLightCameraSaysWhatItIs() {
        let line = EnforcementCameras.warning(
            for: camera("c", north(300), kind: .redLight), meters: 300,
            speedMph: 25, postedLimitMph: 30)
        XCTAssertTrue(line.hasPrefix("Red light camera"), line)
    }
}
