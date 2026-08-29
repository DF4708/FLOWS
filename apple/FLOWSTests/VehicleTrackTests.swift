// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import MapKit
import XCTest

/// Drawing the vehicle: sliding between fixes, which way it faces, and what
/// shape it is.
final class VehicleTrackTests: XCTestCase {
    private let here = CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40)

    private func north(_ meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: here.latitude + meters / 111_320,
                               longitude: here.longitude)
    }

    // MARK: sliding, not hopping

    func testOrdinaryTravelBetweenFixesSlides() {
        // A second at highway speed is about 30 m — that's travel, and the
        // marker should move smoothly across it.
        XCTAssertTrue(VehicleTrack.shouldAnimate(from: here, to: north(30)))
    }

    func testAGPSCorrectionSnapsInsteadOfDrivingThroughBuildings() {
        // Leaving a tunnel the fix can jump hundreds of metres. Animating
        // that draws the car crossing blocks it never drove.
        XCTAssertFalse(VehicleTrack.shouldAnimate(from: here, to: north(400)))
    }

    func testTheSlideLastsAboutAsLongAsTheGapBetweenFixes() {
        XCTAssertEqual(VehicleTrack.slideSeconds(gap: 1.0), 1.0, accuracy: 0.001)
    }

    func testABurstOfFixesDoesNotAnimateInAFlicker() {
        XCTAssertEqual(VehicleTrack.slideSeconds(gap: 0.01), VehicleTrack.minSlide)
    }

    func testALongGapDoesNotLeaveTheMarkerCrawling() {
        XCTAssertEqual(VehicleTrack.slideSeconds(gap: 60), VehicleTrack.maxSlide)
    }

    // MARK: which way it points

    func testAParkedVehicleHoldsItsLastDirectionRatherThanSpinning() {
        // GPS course is noise at a standstill. A car waiting at a light must
        // not rotate on the spot.
        XCTAssertEqual(VehicleTrack.heading(courseDegrees: 271, speedMps: 0.1,
                                            previous: 90), 90)
        XCTAssertNil(VehicleTrack.heading(courseDegrees: -1, speedMps: 0,
                                          previous: nil))
    }

    func testAMovingVehicleUsesTheReportedCourse() {
        XCTAssertEqual(VehicleTrack.heading(courseDegrees: 180, speedMps: 20,
                                            previous: 90), 180)
    }

    func testAFixWithNoCourseKeepsTheLastKnownDirection() {
        XCTAssertEqual(VehicleTrack.heading(courseDegrees: -1, speedMps: 20,
                                            previous: 45), 45)
    }

    func testTurningAcrossNorthTakesTheShortWayRound() {
        // 350° to 10° is a 20° turn, not a 340° spin.
        let eased = VehicleTrack.easedHeading(from: 350, to: 10, fraction: 0.5)
        XCTAssertEqual(eased, 0, accuracy: 0.001)
    }

    func testEasingStaysInsideACompassCircle() {
        for target in stride(from: 0.0, to: 360.0, by: 37) {
            let h = VehicleTrack.easedHeading(from: 12, to: target, fraction: 1)
            XCTAssertGreaterThanOrEqual(h, 0)
            XCTAssertLessThan(h, 360)
        }
    }

    // MARK: which drawing to use

    func testLookingStraightDownShowsTheRoof() {
        XCTAssertEqual(VehicleAspect.forCamera(pitchDegrees: 0,
                                               relativeBearing: 0), .top)
    }

    func testFollowingBehindShowsTheBack() {
        XCTAssertEqual(VehicleAspect.forCamera(pitchDegrees: 60,
                                               relativeBearing: 0), .rear)
    }

    func testACameraFacingTheCarShowsItsFront() {
        XCTAssertEqual(VehicleAspect.forCamera(pitchDegrees: 60,
                                               relativeBearing: 180), .front)
    }

    func testACameraOffToTheSideShowsTheSide() {
        XCTAssertEqual(VehicleAspect.forCamera(pitchDegrees: 60,
                                               relativeBearing: 90), .side)
    }

    // MARK: what shape it is

    func testAnEighteenWheelerIsNotDrawnAsAHatchback() {
        XCTAssertEqual(VehicleShape.matching(make: "Freightliner", model: "Cascadia",
                                             gvwrLbs: 80_000, isTrucker: true), .semi)
    }

    func testWeightDecidesBeforeTheNameDoes() {
        // A box truck badged with a car-sounding model is still a box truck.
        XCTAssertEqual(VehicleShape.matching(make: "Isuzu", model: "Elf",
                                             gvwrLbs: 14_000, isTrucker: false), .box)
    }

    func testCommonBodiesAreRecognizedByName() {
        let cases: [(String, String, VehicleShape)] = [
            ("Ford", "F-150", .pickup),
            ("Honda", "Odyssey", .van),
            ("Toyota", "4Runner", .suv),
            ("Honda", "Civic", .car),
        ]
        for (make, model, want) in cases {
            XCTAssertEqual(VehicleShape.matching(make: make, model: model,
                                                 gvwrLbs: nil, isTrucker: false),
                           want, "\(make) \(model)")
        }
    }

    func testWithNoVehicleOnFileTruckerModeStillGetsATruck() {
        XCTAssertEqual(VehicleShape.matching(make: nil, model: nil,
                                             gvwrLbs: nil, isTrucker: true), .semi)
        XCTAssertEqual(VehicleShape.matching(make: nil, model: nil,
                                             gvwrLbs: nil, isTrucker: false), .car)
    }

    func testEveryShapeHasADrawingForEveryAngle() {
        // A name that isn't a real SF Symbol renders as an empty box on the
        // map, so every combination must at least be non-empty here — the
        // names themselves were checked against the installed symbol set.
        for shape in VehicleShape.allCases {
            for aspect in VehicleAspect.allCases {
                XCTAssertFalse(shape.symbol(aspect).isEmpty,
                               "\(shape.rawValue)/\(aspect.rawValue)")
            }
            XCTAssertFalse(shape.title.isEmpty)
        }
    }

    // MARK: keeping the vehicle in the part of the map you can see

    func testTheAimPointShiftsWhenChromeCoversTheTop() {
        // Chrome on top means the open band is lower, so the camera must aim
        // ahead of the vehicle to push it down into view.
        let shifted = CameraZoom.chaseCenter(vehicle: here, headingDegrees: 0,
                                             distanceMeters: 1_000,
                                             topCover: 0.3, bottomCover: 0.1)
        XCTAssertGreaterThan(shifted.latitude, here.latitude)
    }

    func testAnUncoveredMapAimsStraightAtTheVehicle() {
        let same = CameraZoom.chaseCenter(vehicle: here, headingDegrees: 90,
                                          distanceMeters: 1_000,
                                          topCover: 0.2, bottomCover: 0.2)
        XCTAssertEqual(same.latitude, here.latitude, accuracy: 1e-9)
        XCTAssertEqual(same.longitude, here.longitude, accuracy: 1e-9)
    }

    func testTheShiftFollowsTheHeading() {
        // Heading east, the aim point moves east — not north.
        let east = CameraZoom.chaseCenter(vehicle: here, headingDegrees: 90,
                                          distanceMeters: 1_000,
                                          topCover: 0.3, bottomCover: 0.1)
        XCTAssertGreaterThan(east.longitude, here.longitude)
        XCTAssertEqual(east.latitude, here.latitude, accuracy: 1e-6)
    }

    // MARK: the null-island jump

    func testAnEmptyRouteRectIsRefusedRatherThanFramingTheAtlantic() {
        // MKPolyline with no points has a NULL bounding rect, and a null
        // rect reads as 0,0 — off West Africa. That was the "why is it
        // showing me Africa and Europe" jump.
        XCTAssertNil(CameraZoom.usableRect(.null))
        XCTAssertNil(CameraZoom.usableRect(MKMapRect(x: 0, y: 0, width: 0, height: 0)))
    }

    func testARealRouteRectIsAccepted() {
        let rect = MKMapRect(x: 1_000, y: 2_000, width: 5_000, height: 4_000)
        let kept = CameraZoom.usableRect(rect)
        XCTAssertNotNil(kept)
        XCTAssertEqual(kept?.origin.x, rect.origin.x)
        XCTAssertEqual(kept?.size.width, rect.size.width)
    }
}

/// Framing a route clear of whichever edge the chrome covers.
final class PanelFramingTests: XCTestCase {
    /// A route rect somewhere with room around it.
    private let route = MKMapRect(x: 40_000_000, y: 90_000_000,
                                  width: 400_000, height: 200_000)

    private func framed(_ edge: CameraZoom.PanelEdge) -> MKMapRect {
        CameraZoom.framedRect(route, panelEdge: edge,
                              windowAspect: 2.0, panelFraction: 0.4)
    }

    func testABottomPanelLiftsTheRouteUpTheScreen() {
        // MKMapRect y runs SOUTHWARD, so aiming further south puts the route
        // higher on screen — clear of cards sitting at the thumb end.
        // Measured at the CENTRE: the union with the route deliberately
        // clamps the origin so the whole line stays framed.
        XCTAssertGreaterThan(framed(.bottom).midY, route.midY)
    }

    func testATopPanelPushesTheRouteDownTheScreen() {
        XCTAssertLessThan(framed(.top).midY, route.midY)
    }

    func testTheTwoVerticalEdgesShiftOppositeWays() {
        XCTAssertGreaterThan(framed(.bottom).midY, framed(.top).midY)
    }

    func testASidePanelShiftsSidewaysNotVertically() {
        let side = framed(.leading)
        XCTAssertLessThan(side.midX, route.midX)
        XCTAssertEqual(side.midY, route.midY, accuracy: 1)
    }

    func testTheWHOLERouteSurvivesEveryShift() {
        // Whatever the shift does, selecting a card must still show the
        // entire route — that is what the union is for.
        for edge in [CameraZoom.PanelEdge.top, .bottom, .leading] {
            let f = framed(edge)
            XCTAssertLessThanOrEqual(f.minX, route.minX, "\(edge) clipped the west end")
            XCTAssertGreaterThanOrEqual(f.maxX, route.maxX, "\(edge) clipped the east end")
            XCTAssertLessThanOrEqual(f.minY, route.minY, "\(edge) clipped the north end")
            XCTAssertGreaterThanOrEqual(f.maxY, route.maxY, "\(edge) clipped the south end")
        }
    }

    func testNoPanelMeansNoShift() {
        let unshifted = CameraZoom.framedRect(route, panelEdge: .bottom,
                                              windowAspect: 2.0, panelFraction: 0)
        XCTAssertEqual(unshifted.midY, route.midY, accuracy: 1)
    }
}
