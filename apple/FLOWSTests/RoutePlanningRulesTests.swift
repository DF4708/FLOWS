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

/// The trip-planning rules behind the choice cards: which filters judge a
/// walk, what walking and towing may take back, Avoid traffic next to the
/// other routes, the Cheapest chip and tolls, the error line, picked rows,
/// and favorites named for what was typed. All pure — no network.
final class RoutePlanningRulesTests: XCTestCase {

    // MARK: filters on foot

    /// The chips are hidden while walking, so only the walk's own No
    /// highways may judge it — Avoid traffic (on by default) timed walks
    /// against car speeds and threw every one out.
    func testWalkingIsJudgedOnlyByNoHighways() {
        let on: Set<RouteFilter> = [.avoidTraffic, .noTolls, .noHighways, .lowBridges]
        XCTAssertEqual(RouteFilter.judging(on, walking: true), [.noHighways])
        XCTAssertEqual(RouteFilter.judging([.avoidTraffic], walking: true), [])
        XCTAssertEqual(RouteFilter.judging(on, walking: false), on)
    }

    // MARK: modes give back only what they added

    func testWalkingKeepsANoHighwaysTheDriverChose() {
        // Chosen before walking: walking adds nothing, so leaving it takes
        // nothing away.
        let chosen = RouteFilter.forcing([.noHighways], onto: [.avoidTraffic, .noHighways])
        XCTAssertEqual(chosen.filters, [.avoidTraffic, .noHighways])
        XCTAssertTrue(chosen.added.isEmpty)
        XCTAssertEqual(chosen.filters.subtracting(chosen.added), [.avoidTraffic, .noHighways])

        // Not chosen: walking adds it and takes it back.
        let added = RouteFilter.forcing([.noHighways], onto: [.avoidTraffic])
        XCTAssertEqual(added.added, [.noHighways])
        XCTAssertEqual(added.filters.subtracting(added.added), [.avoidTraffic])
    }

    func testTowingKeepsAFilterChosenBeforeIt() {
        let towing = RouteFilter.forcing(RouteFilter.towingSafety, onto: [.avoidTraffic, .lowBridges])
        XCTAssertEqual(towing.filters, RouteFilter.towingSafety.union([.avoidTraffic]))
        XCTAssertFalse(towing.added.contains(.lowBridges))
        // Towing off: the driver's No low bridges is still on.
        XCTAssertEqual(towing.filters.subtracting(towing.added), [.avoidTraffic, .lowBridges])
    }

    // MARK: Avoid traffic

    func testAvoidTrafficNeverEmptiesAnInTownPlan() {
        // A 2 am errand on city streets: ~1.6 on the fixed scale, which the
        // old 1.35 cutoff read as traffic on every route.
        let town: [(ratio: Double, highways: Bool)] = [(1.62, false), (1.70, false)]
        XCTAssertTrue(RouteFilter.avoidsTraffic(ratio: 1.62, highways: false, among: town))
        XCTAssertTrue(RouteFilter.avoidsTraffic(ratio: 1.70, highways: false, among: town))
        // Nothing to compare with: nothing to avoid.
        XCTAssertTrue(RouteFilter.avoidsTraffic(ratio: 3, highways: true, among: []))
    }

    func testLocalRoadsAreJudgedAgainstLocalRoads() {
        // Beside a free-flowing interstate, the local-roads option is slower
        // by its speed limits, not by traffic — it stays.
        let mixed: [(ratio: Double, highways: Bool)] = [(1.02, true), (1.55, false)]
        XCTAssertTrue(RouteFilter.avoidsTraffic(ratio: 1.55, highways: false, among: mixed))
        XCTAssertTrue(RouteFilter.avoidsTraffic(ratio: 1.02, highways: true, among: mixed))
    }

    func testAJammedHighwayFailsNextToAMovingOne() {
        let highways: [(ratio: Double, highways: Bool)] = [(1.05, true), (1.60, true)]
        XCTAssertFalse(RouteFilter.avoidsTraffic(ratio: 1.60, highways: true, among: highways))
        XCTAssertTrue(RouteFilter.avoidsTraffic(ratio: 1.05, highways: true, among: highways))
    }

    // MARK: Cheapest and tolls

    func testCheapestGivesWayToATollFreeRouteWithinTheAllowance() {
        let tolled = UUID(), tollFree = UUID(), longWay = UUID()
        // 100 mi with tolls vs 103 mi without: $0.40 more fuel pays no toll.
        XCTAssertEqual(CheapestRoute.pick([
            .init(id: tolled, fuelUSD: 13.00, hasTolls: true),
            .init(id: tollFree, fuelUSD: 13.40, hasTolls: false),
        ]), tollFree)
        // A toll-free way that burns $12 more leaves the tolled road cheapest.
        XCTAssertEqual(CheapestRoute.pick([
            .init(id: tolled, fuelUSD: 13, hasTolls: true),
            .init(id: longWay, fuelUSD: 25, hasTolls: false),
        ]), tolled)
        // No tolls anywhere: the lowest fuel.
        XCTAssertEqual(CheapestRoute.pick([
            .init(id: longWay, fuelUSD: 25, hasTolls: false),
            .init(id: tollFree, fuelUSD: 13.4, hasTolls: false),
        ]), tollFree)
        XCTAssertNil(CheapestRoute.pick([]))
    }

    // MARK: the planner's error line

    /// A route that doesn't exist won't appear on a retry, so its message
    /// must not say "try again".
    func testPlanningErrorsSayWhetherARetryCanHelp() {
        let noDirections = NSError(domain: MKErrorDomain,
                                   code: Int(MKError.Code.directionsNotFound.rawValue))
        XCTAssertEqual(RouteError.plainMessage(for: noDirections),
                       "No drivable route found between those places.")
        XCTAssertEqual(RouteError.plainMessage(for: RouteError.noRoute),
                       "No drivable route found between those points.")
        XCTAssertEqual(RouteError.plainMessage(for: RouteError.notFound("Zzyzx Rd")),
                       "Couldn't find “Zzyzx Rd”. Try a ZIP, city, or county.")
        let noRetry: [Error] = [noDirections, RouteError.noRoute, RouteError.noStart]
        for error in noRetry {
            XCTAssertFalse(RouteError.plainMessage(for: error).contains("Try again"))
        }
        // The old mappings stay.
        XCTAssertEqual(RouteError.plainMessage(for: NSError(domain: kCLErrorDomain, code: 8)),
                       "Couldn't find that place. Check the spelling or add a city or state.")
        XCTAssertEqual(RouteError.plainMessage(for: URLError(.notConnectedToInternet)),
                       "No internet right now — try again when you're back in coverage.")
        XCTAssertEqual(RouteError.plainMessage(for: NSError(domain: "other", code: 1)),
                       "Couldn't plan that route. Try again in a moment.")
    }

    // MARK: Try again beside the bridge and hill checks

    /// Try again scores a copy of the card taken before the first pass's
    /// bridge and hill checks landed. Its score must land without wiping
    /// them: gone, a known low bridge passed No low bridges.
    func testAWeatherScoreLandsWithoutWipingTheBridgeChecks() {
        let copy = PlannedRoute(route: MKRoute(), sourceName: "A", destinationName: "B")
        var card = copy
        card.clearancesMeters = [3.3]   // about 11 ft
        card.maxGradePercent = 8
        card.attributesScored = true
        card.scoringProgress = 0.5
        card.provisionalSamples = [
            RiskSample(coordinate: .init(latitude: 0, longitude: 0), risk: 0.4), nil,
        ]

        var complete = copy
        complete.weatherRisk = 0.3
        complete.weatherScored = true
        let landed = complete.landing(on: card)
        XCTAssertEqual(landed.id, card.id)
        XCTAssertTrue(landed.weatherScored)
        XCTAssertEqual(landed.weatherRisk, 0.3)
        XCTAssertEqual(landed.clearancesMeters, [3.3])
        XCTAssertEqual(landed.maxGradePercent, 8)
        XCTAssertTrue(landed.attributesScored)
        XCTAssertFalse(RouteFilter.lowBridges.passes(landed))
        XCTAssertTrue(RouteFilter.lowBridges.passes(complete))   // what a whole write left

        // Still incomplete: the card keeps its "so far" picture too.
        let partial = copy.landing(on: card)
        XCTAssertFalse(partial.weatherScored)
        XCTAssertEqual(partial.scoringProgress, 0.5)
        XCTAssertEqual(partial.provisionalSamples.count, 2)
        XCTAssertEqual(partial.clearancesMeters, [3.3])
    }

    // MARK: picked rows plan to their own point

    func testARowWithItsOwnPlacePlansThereWithoutALookup() throws {
        let c = CLLocationCoordinate2D(latitude: 43.0731, longitude: -89.4012)
        let recent = DestinationSearch.Suggestion(
            title: "Augusta", subtitle: "Recent", kind: .recent, coordinate: c)
        let pick = try XCTUnwrap(recent.pick)
        XCTAssertEqual(pick.name, "Augusta")
        XCTAssertEqual(pick.coordinate.latitude, 43.0731, accuracy: 1e-9)
        XCTAssertEqual(pick.coordinate.longitude, -89.4012, accuracy: 1e-9)
        // It stands while the field holds its text, and not once edited.
        XCTAssertTrue(pick.stands(for: "Augusta"))
        XCTAssertTrue(pick.stands(for: "Augusta "))
        XCTAssertFalse(pick.stands(for: "Augusta, ME"))

        // A pasted point's title is no address — the pick carries the point.
        let point = DestinationSearch.Suggestion(
            title: CoordinateInput.displayName(c), subtitle: "Exact map point",
            kind: .coordinate, coordinate: c)
        XCTAssertEqual(point.pick?.text, "Map point 43.0731, -89.4012")

        // A completion has no point of its own and is looked up as before.
        XCTAssertNil(DestinationSearch.Suggestion(title: "Publix", subtitle: "Augusta, GA").pick)
    }

    // MARK: favorites keep what was typed

    @MainActor
    func testTwoFavoritesInOneTownStayApart() throws {
        let suiteName = "flows.tests.favorites.sametown"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let home = try XCTUnwrap(FavoriteAddress.typed(
            " 1 Infinite Loop, Cupertino, CA ", symbol: .home,
            at: CLLocationCoordinate2D(latitude: 37.3318, longitude: -122.0312)))
        let office = try XCTUnwrap(FavoriteAddress.typed(
            "10600 N Tantau Ave, Cupertino", symbol: .office,
            at: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)))
        XCTAssertEqual(home.name, "1 Infinite Loop, Cupertino, CA")
        XCTAssertNil(FavoriteAddress.typed("   ", symbol: .other,
                                           at: CLLocationCoordinate2D(latitude: 0, longitude: 0)))

        let store = FavoritesStore(defaults: defaults)
        store.add(home)
        store.add(office)
        XCTAssertEqual(store.favorites.count, 2)
        // The star matches the typed text, so it fills for a saved place.
        XCTAssertTrue(store.contains(name: "1 Infinite Loop, Cupertino, CA"))
        XCTAssertTrue(store.contains(name: "10600 N Tantau Ave, Cupertino"))
    }
}
