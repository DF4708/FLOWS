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

/// The map's display rules from the September functions check: which
/// warning a clustered badge names on its tap card, which route badges give
/// way to the planning map's own, when a rough risk area waits for its ZIP
/// outline, which routes the map draws as options, and where the text-size
/// slider's thumb sits.
final class MapDisplayTests: XCTestCase {

    private func item(_ kind: String, lat: Double, lon: Double, score: Double)
        -> BadgeClustering.Item<String> {
        .init(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
              kind: kind, score: score)
    }

    // MARK: badge labels — the warning a badge names on its tap card

    func testWarningReachesABadgeThatMovedOffItsPoint() {
        // Clustering and the ZIP snap move a badge off every sweep point; a
        // warning ~5 km away still names it. (The old lookup wanted the
        // exact coordinate and found nothing.)
        let badge = item("tornado", lat: 43.00, lon: -89.00, score: 0.9)
        let warned = [(item: item("tornado", lat: 43.04, lon: -89.02, score: 0.9),
                       label: "Tornado Warning")]
        XCTAssertEqual(BadgeClustering.labels(for: [badge], from: warned,
                                              radiusMeters: 20_000),
                       ["Tornado Warning"])
    }

    func testWarningOfAnotherKindOrTooFarNamesNothing() {
        let badge = item("flood", lat: 43.00, lon: -89.00, score: 0.7)
        let otherKind = [(item: item("snow", lat: 43.01, lon: -89.00, score: 0.8),
                          label: "Winter Storm Watch")]
        XCTAssertEqual(BadgeClustering.labels(for: [badge], from: otherKind,
                                              radiusMeters: 20_000), [nil],
                       "a snow watch must not caption a flood badge")
        let farAway = [(item: item("flood", lat: 44.00, lon: -89.00, score: 0.8),
                        label: "Flood Warning")]   // ~111 km
        XCTAssertEqual(BadgeClustering.labels(for: [badge], from: farAway,
                                              radiusMeters: 20_000), [nil])
    }

    func testEachWarningJoinsOnlyItsNearestBadge() {
        // Two storm badges ~33 km apart; the warning sits by the east one.
        let west = item("storm", lat: 43.0, lon: -89.4, score: 0.8)
        let east = item("storm", lat: 43.0, lon: -89.0, score: 0.8)
        let warned = [(item: item("storm", lat: 43.0, lon: -89.05, score: 0.9),
                       label: "Severe Thunderstorm Warning")]
        XCTAssertEqual(BadgeClustering.labels(for: [west, east], from: warned,
                                              radiusMeters: 50_000),
                       [nil, "Severe Thunderstorm Warning"])
    }

    func testTheWorstWarningNamesTheBadge() {
        let badge = item("flood", lat: 43.0, lon: -89.0, score: 0.9)
        let warned = [
            (item: item("flood", lat: 43.01, lon: -89.0, score: 0.5), label: "Flood Advisory"),
            (item: item("flood", lat: 43.02, lon: -89.0, score: 0.95), label: "Flash Flood Warning"),
            (item: item("flood", lat: 43.00, lon: -89.01, score: 0.6), label: "Flood Watch"),
        ]
        XCTAssertEqual(BadgeClustering.labels(for: [badge], from: warned,
                                              radiusMeters: 20_000),
                       ["Flash Flood Warning"])
    }

    func testNoBadgesOrNoWarningsGiveNoLabels() {
        XCTAssertEqual(BadgeClustering.labels(
            for: [BadgeClustering.Item<String>](),
            from: [(item: item("fire", lat: 40, lon: -110, score: 0.9), label: "Red Flag Warning")],
            radiusMeters: 50_000), [])
        XCTAssertEqual(BadgeClustering.labels(
            for: [item("fire", lat: 40, lon: -110, score: 0.9)], from: [],
            radiusMeters: 50_000), [nil])
    }

    // MARK: route badges beside the planning map's own

    /// The route badges left to draw, by kind; the unnamed triangle
    /// ("hazard") is the one minor kind here.
    private func unshown(_ badges: [BadgeClustering.Item<String>],
                         shown: [BadgeClustering.Item<String>],
                         areas: [[CLLocationCoordinate2D]] = []) -> [String] {
        BadgeClustering.unshown(badges, shown: shown, areas: areas,
                                mergeMeters: 20_000, minor: { $0.kind == "hazard" })
            .map(\.kind)
    }

    func testASameKindBadgeNearbyIsOneSymbolTwice() {
        let route = [item("rain", lat: 43.00, lon: -89.00, score: 0.5)]
        XCTAssertEqual(unshown(route, shown: [item("rain", lat: 43.05, lon: -89.00, score: 0.5)]),
                       [], "a rain badge ~6 km from the map's own rain badge")
        XCTAssertEqual(unshown(route, shown: [item("rain", lat: 44.00, lon: -89.00, score: 0.5)]),
                       ["rain"], "~111 km away it marks another area")
    }

    func testTheUnnamedTriangleGivesWayToAnyBadgeNearby() {
        // No warning on the route: its gray triangle beside the map's own
        // Rain chance badge was two symbols for one area.
        let shown = [item("rain", lat: 43.05, lon: -89.00, score: 0.5)]
        XCTAssertEqual(unshown([item("hazard", lat: 43.00, lon: -89.00, score: 0.5)],
                               shown: shown), [])
        // A named hazard of another kind is a different hazard: it stays.
        XCTAssertEqual(unshown([item("tornado", lat: 43.00, lon: -89.00, score: 0.9)],
                               shown: shown), ["tornado"])
    }

    func testTheUnnamedTriangleGoesInsideAnAreaTheMapDraws() {
        // A big ZIP whose own badge sits at its middle, ~55 km from a route
        // badge in its far corner: past the merge distance, same area.
        let zip = [CLLocationCoordinate2D(latitude: 42.5, longitude: -89.5),
                   CLLocationCoordinate2D(latitude: 42.5, longitude: -88.5),
                   CLLocationCoordinate2D(latitude: 43.5, longitude: -88.5),
                   CLLocationCoordinate2D(latitude: 43.5, longitude: -89.5)]
        let shown = [item("rain", lat: 43.0, lon: -89.0, score: 0.5)]
        XCTAssertEqual(unshown([item("hazard", lat: 43.4, lon: -89.4, score: 0.5)],
                               shown: shown, areas: [zip]), [])
        XCTAssertEqual(unshown([item("hazard", lat: 43.7, lon: -89.4, score: 0.5)],
                               shown: shown, areas: [zip]), ["hazard"],
                       "outside the ZIP and far from its badge")
        XCTAssertEqual(unshown([item("tornado", lat: 43.4, lon: -89.4, score: 0.9)],
                               shown: shown, areas: [zip]), ["tornado"],
                       "a named warning keeps its symbol inside the area")
    }

    func testNothingShownKeepsEveryRouteBadge() {
        let route = [item("hazard", lat: 43.0, lon: -89.0, score: 0.5),
                     item("flood", lat: 43.5, lon: -89.0, score: 0.7)]
        XCTAssertEqual(unshown(route, shown: []), ["hazard", "flood"])
    }

    // MARK: blobs — when a rough risk area waits for its ZIP outline

    private let madison = CLLocationCoordinate2D(latitude: 43.07, longitude: -89.40)
    private let toronto = CLLocationCoordinate2D(latitude: 43.65, longitude: -79.38)

    func testANewUSPointWaitsForItsZIPOutline() {
        XCTAssertTrue(RiskAreaFallback.blobWaits(at: madison, lookupsDone: false,
                                                 placedBefore: false))
        XCTAssertFalse(RiskAreaFallback.blobWaits(at: madison, lookupsDone: true,
                                                  placedBefore: false),
                       "once looked up, a point with no ZIP outline gets its blob")
    }

    func testAPointTheLastLookupsPlacedKeepsItsBlob() {
        // Toronto sits inside the rough US box, so the box alone held its
        // blob back at every re-sweep, though its lookup never finds a ZIP.
        XCTAssertTrue(RiskAreaFallback.inZIPBox(toronto))
        XCTAssertFalse(RiskAreaFallback.blobWaits(at: toronto, lookupsDone: false,
                                                  placedBefore: true))
        XCTAssertTrue(RiskAreaFallback.blobWaits(at: toronto, lookupsDone: false,
                                                 placedBefore: false),
                      "new to the map, it waits like any point in the box")
    }

    func testOutsideTheBoxABlobNeverWaits() {
        let edmonton = CLLocationCoordinate2D(latitude: 53.55, longitude: -113.49)
        let mexicoCity = CLLocationCoordinate2D(latitude: 19.43, longitude: -99.13)
        for c in [edmonton, mexicoCity] {
            XCTAssertFalse(RiskAreaFallback.inZIPBox(c))
            XCTAssertFalse(RiskAreaFallback.blobWaits(at: c, lookupsDone: false,
                                                      placedBefore: false))
        }
    }

    // MARK: offered routes — what the map draws as gray alternates

    private func route(clearancesFeet: [Double]?) -> PlannedRoute {
        var r = PlannedRoute(route: MKRoute(), sourceName: "A", destinationName: "B")
        r.clearancesMeters = clearancesFeet?.map { $0 * 0.3048 }
        return r
    }

    func testARouteAFilterHidIsNotOffered() {
        let tall = FilterLimits(vehicleHeightMeters: 11 * 0.3048)
        let underLowBridge = route(clearancesFeet: [12])   // 11 ft + 2 ft margin fails
        let clear = route(clearancesFeet: [16])
        let offered = RouteFilter.offered([underLowBridge, clear],
                                          filters: [.lowBridges], limits: tall)
        XCTAssertEqual(offered.map(\.id), [clear.id])
    }

    func testNoFiltersOfferEveryRoute() {
        let a = route(clearancesFeet: [12]), b = route(clearancesFeet: nil)
        XCTAssertEqual(RouteFilter.offered([a, b], filters: [],
                                           limits: FilterLimits()).map(\.id),
                       [a.id, b.id])
    }

    func testNothingPassingKeepsEveryRouteForTheClosestMatch() {
        // The list falls back to its closest match among these, so the map
        // must not empty out.
        let tall = FilterLimits(vehicleHeightMeters: 13.5 * 0.3048)
        let a = route(clearancesFeet: [12]), b = route(clearancesFeet: [14])
        XCTAssertEqual(RouteFilter.offered([a, b], filters: [.lowBridges],
                                           limits: tall).map(\.id),
                       [a.id, b.id])
    }

    func testSliderLimitsCompareByValue() {
        // The map re-checks its highlight when a slider changes the limits.
        XCTAssertEqual(FilterLimits(vehicleHeightMeters: 3), FilterLimits(vehicleHeightMeters: 3))
        XCTAssertNotEqual(FilterLimits(vehicleHeightMeters: 3), FilterLimits(vehicleHeightMeters: 4))
        XCTAssertNotEqual(FilterLimits(rigWeightLbs: 9_000), FilterLimits(rigWeightLbs: nil))
    }

    // MARK: text-size slider — the thumb shows the size in use

    func testPhoneAtExtraSmallPutsTheThumbAtTheSmallEnd() {
        // Following the phone still draws .xSmall (free below); the thumb
        // used to sit at Large, two steps from the text on screen.
        XCTAssertEqual(TextScale.index(of: .xSmall), 0)
        XCTAssertEqual(TextScale.steps[TextScale.index(of: .small)], .small)
        XCTAssertEqual(TextScale.steps[TextScale.index(of: .large)], .large)
        XCTAssertEqual(TextScale.index(of: .accessibility5), TextScale.steps.count - 1)
    }
}
