// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import MapKit
import XCTest

/// The navigation camera's zoom policy: distance shown follows the distance
/// between intersections; walking pins close; flights phase between
/// walking-close at the airports and continent-wide at cruise.
final class CameraZoomTests: XCTestCase {

    func testWalkingViewIsTheClosest() {
        XCTAssertLessThan(CameraZoom.walkingAltitude, CameraZoom.cityAltitude)
        XCTAssertLessThan(CameraZoom.walkingAltitude, CameraZoom.intersectionAltitude)
    }

    func testCityBlocksHoldTheCloseView() {
        // 300 m blocks, next turn comfortably ahead, city speed.
        let alt = CameraZoom.drivingAltitude(intersectionSpacingMeters: 300,
                                             distanceToManeuverMeters: 280,
                                             speedMps: 12)
        XCTAssertEqual(alt, CameraZoom.cityAltitude, accuracy: 1)
    }

    func testHighwayStretchReadsFar() {
        // 12 km between off-ramps at 70 mph → the ceiling, speed-stretched.
        let alt = CameraZoom.drivingAltitude(intersectionSpacingMeters: 12_000,
                                             distanceToManeuverMeters: 8_000,
                                             speedMps: 31)
        XCTAssertEqual(alt, CameraZoom.highwayAltitude, accuracy: 1)
        // Faster still sees proportionally farther, capped at 1.5×.
        let fast = CameraZoom.drivingAltitude(intersectionSpacingMeters: 12_000,
                                              distanceToManeuverMeters: 8_000,
                                              speedMps: 60)
        XCTAssertEqual(fast, CameraZoom.highwayAltitude * 1.5, accuracy: 1)
    }

    func testImminentTurnPinsToTheIntersection() {
        let alt = CameraZoom.drivingAltitude(intersectionSpacingMeters: 12_000,
                                             distanceToManeuverMeters: 200,
                                             speedMps: 31)
        XCTAssertEqual(alt, CameraZoom.intersectionAltitude)
    }

    func testViewTightensApproachingTheExit() {
        // Long highway step, but the exit is 500 m out: the shown distance
        // caps at ~2× the road left, so the view is already well below the
        // highway ceiling before the tight intersection zoom takes over.
        let approaching = CameraZoom.drivingAltitude(
            intersectionSpacingMeters: 12_000,
            distanceToManeuverMeters: 500,
            speedMps: 31)
        XCTAssertLessThan(approaching, CameraZoom.highwayAltitude / 2)
        XCTAssertGreaterThan(approaching, CameraZoom.intersectionAltitude)
    }

    func testAltitudeGrowsWithIntersectionSpacing() {
        var last = 0.0
        for spacing in [200.0, 600, 1_500, 3_000, 6_000, 12_000] {
            let alt = CameraZoom.drivingAltitude(intersectionSpacingMeters: spacing,
                                                 distanceToManeuverMeters: 20_000,
                                                 speedMps: 20)
            XCTAssertGreaterThanOrEqual(alt, last)
            last = alt
        }
    }

    // MARK: framing the route clear of the panel

    /// A typical trip: wide east-west, thin north-south (Madison→Milwaukee
    /// shaped). This is the case that breaks naive "grow the rect" framing.
    private var wideRoute: MKMapRect {
        MKMapRect(x: 1_000_000, y: 2_000_000, width: 40_000, height: 900)
    }

    func testTopPanelPushesTheRouteDownIntoTheOpenMap() {
        let framed = CameraZoom.framedRect(wideRoute, panelEdge: .top,
                                           windowAspect: 2.17)
        // The camera centers NORTH of the route (smaller y), so the route
        // draws lower on screen — below the panel.
        XCTAssertLessThan(framed.midY, wideRoute.midY)
        // …and the zoom is untouched: shifting, not growing.
        XCTAssertEqual(framed.size.width,
                       wideRoute.insetBy(dx: -wideRoute.width * 0.2,
                                         dy: -wideRoute.height * 0.2).size.width,
                       accuracy: 1)
    }

    func testTheShiftIsBigEnoughToMatterOnAWideRoute() {
        // The bug this replaces: growing a width-constrained rect's height
        // moved the route by nothing. The shift must scale with the FITTED
        // span (width × aspect), not the route's own hairline height.
        let framed = CameraZoom.framedRect(wideRoute, panelEdge: .top,
                                           windowAspect: 2.17)
        let shift = wideRoute.midY - framed.midY
        XCTAssertGreaterThan(shift, wideRoute.size.height * 10,
                             "shift must come from the fitted span, not route height")
    }

    func testSidePanelPushesTheRouteRight() {
        let framed = CameraZoom.framedRect(wideRoute, panelEdge: .leading,
                                           windowAspect: 2.17)
        XCTAssertLessThan(framed.midX, wideRoute.midX)
        XCTAssertEqual(framed.midY, wideRoute.midY, accuracy: 1)
    }

    func testNoPanelNoShift() {
        let framed = CameraZoom.framedRect(wideRoute, panelEdge: .top,
                                           windowAspect: 2.17, panelFraction: 0)
        XCTAssertEqual(framed.midY, wideRoute.midY, accuracy: 1)
    }

    func testFlightPhasesWalkCruiseAndGlide() {
        // On the ground at either airport: the walking view.
        XCTAssertEqual(CameraZoom.flightAltitude(metersToNearestAirport: 0),
                       CameraZoom.walkingAltitude)
        XCTAssertEqual(CameraZoom.flightAltitude(metersToNearestAirport: 2_500),
                       CameraZoom.walkingAltitude)
        // Far from both: cruise.
        XCTAssertEqual(CameraZoom.flightAltitude(metersToNearestAirport: 40_000),
                       CameraZoom.cruiseAltitude)
        XCTAssertEqual(CameraZoom.flightAltitude(metersToNearestAirport: 300_000),
                       CameraZoom.cruiseAltitude)
        // Climb-out/approach glides monotonically between the two.
        var last = CameraZoom.walkingAltitude
        for d in [3_000.0, 10_000, 20_000, 30_000, 39_000] {
            let alt = CameraZoom.flightAltitude(metersToNearestAirport: d)
            XCTAssertGreaterThan(alt, last)
            XCTAssertLessThan(alt, CameraZoom.cruiseAltitude)
            last = alt
        }
    }
}
