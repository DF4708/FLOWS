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

/// Legs FLOWS swaps in mid-trip (a reroute, the way to an added stop, the
/// way on from it), the live picture of the road ahead, and what the driver
/// is told about them.
final class LegSwapAndRoadAheadTests: XCTestCase {
    /// A road the router says has tolls and/or highways.
    private final class Road: MKRoute {
        private let tolls: Bool
        private let highways: Bool
        init(tolls: Bool = false, highways: Bool = false) {
            self.tolls = tolls
            self.highways = highways
            super.init()
        }
        override var hasTolls: Bool { tolls }
        override var hasHighways: Bool { highways }
    }

    private func route(_ road: MKRoute = Road(), kind: RoutePlanKind = .standard,
                       risk: Double = 0, eta: Double = 600) -> PlannedRoute {
        var r = PlannedRoute(route: road, sourceName: "A", destinationName: "B", planKind: kind)
        r.weatherRisk = risk
        r.etaOverride = eta
        return r
    }

    private let here = CLLocationCoordinate2D(latitude: 41.0, longitude: -104.8)

    // MARK: the road a swapped leg takes

    /// A leg with no tolls was a choice (the card without a toll badge): the
    /// way to an added stop keeps it, even when the tolled road is faster.
    func testASwappedLegKeepsTheDriversRoadChoices() {
        let leg = route()
        let tolled = route(Road(tolls: true), eta: 300)
        let free = route(eta: 420)
        let pick = FasterRoutePolicy.swapPick([tolled, free], leg: leg, filters: [],
                                              limits: FilterLimits(), calmest: false)
        XCTAssertEqual(pick?.id, free.id)
        // No highways, set by the driver (or by walking): the local road.
        let freeway = route(Road(highways: true), eta: 300)
        XCTAssertEqual(FasterRoutePolicy.swapPick([freeway, free], leg: leg, filters: [.noHighways],
                                                  limits: FilterLimits(), calmest: false)?.id,
                       free.id)
        // With nothing kept by any, the router's first still goes.
        XCTAssertEqual(FasterRoutePolicy.swapPick([tolled, freeway], leg: leg,
                                                  filters: [.noHighways],
                                                  limits: FilterLimits(), calmest: false)?.id,
                       tolled.id)
        XCTAssertNil(FasterRoutePolicy.swapPick([], leg: leg, filters: [],
                                                limits: FilterLimits(), calmest: false))
    }

    /// A known low bridge outranks a toll: a trailer under an 11 ft post is
    /// a crash, a toll is money. Unknown clearances pass, as on the cards.
    func testASafetyFilterOutranksARoadChoice() {
        let leg = route()
        var lowBridge = route(eta: 300)
        lowBridge.clearancesMeters = [3.35]   // 11 ft
        let tolled = route(Road(tolls: true), eta: 420)
        let limits = FilterLimits()   // 13'6" with the 2 ft margin
        XCTAssertEqual(FasterRoutePolicy.swapPick([lowBridge, tolled], leg: leg,
                                                  filters: [.lowBridges], limits: limits,
                                                  calmest: false)?.id,
                       tolled.id)
        // Clearances not loaded yet: nothing known against it.
        let unknown = route(eta: 300)
        XCTAssertEqual(FasterRoutePolicy.swapPick([unknown, tolled], leg: leg,
                                                  filters: [.lowBridges], limits: limits,
                                                  calmest: false)?.id,
                       unknown.id)
    }

    /// A reroute away from risk takes the calmest road that qualifies at the
    /// lowest risk level there is — not a calmer one of the same level that
    /// breaks the driver's choices (Clear and Green are one low level).
    func testAReroutePicksTheCalmestQualifyingRoad() {
        let leg = route(kind: .tollFree)
        let yellow = route(risk: 0.7, eta: 300)
        let green = route(risk: 0.5, eta: 900)
        let clearButTolled = route(Road(tolls: true), risk: 0.1, eta: 600)
        let pick = FasterRoutePolicy.swapPick([yellow, clearButTolled, green], leg: leg,
                                              filters: [], limits: FilterLimits(), calmest: true)
        XCTAssertEqual(pick?.id, green.id)
        // Equal risk: the sooner arrival.
        let sooner = route(risk: 0.5, eta: 600)
        XCTAssertEqual(FasterRoutePolicy.swapPick([green, sooner], leg: leg, filters: [],
                                                  limits: FilterLimits(), calmest: true)?.id,
                       sooner.id)
    }

    /// A toll never holds a reroute in the storm it escapes: a Clear toll
    /// road beats a toll-free Red one, No tolls or not, and the stormy road
    /// itself isn't picked again. Yellow beats Red the same way.
    func testARoadChoiceNeverHoldsARerouteInTheStorm() {
        let leg = route()   // no tolls on it, so a toll road breaks the choice
        let stormy = route(risk: 0.95, eta: 300)
        let red = route(risk: 0.9, eta: 400)
        let clearTolled = route(Road(tolls: true), risk: 0.1, eta: 600)
        for filters: Set<RouteFilter> in [[], [.noTolls]] {
            XCTAssertEqual(FasterRoutePolicy.swapPick([stormy, red, clearTolled], leg: leg,
                                                      filters: filters, limits: FilterLimits(),
                                                      calmest: true)?.id,
                           clearTolled.id)
        }
        let yellowTolled = route(Road(tolls: true), risk: 0.75, eta: 600)
        XCTAssertEqual(FasterRoutePolicy.swapPick([red, yellowTolled], leg: leg,
                                                  filters: [.noTolls], limits: FilterLimits(),
                                                  calmest: true)?.id,
                       yellowTolled.id)
        // The way to an added stop isn't weighed by risk: the choice holds.
        XCTAssertEqual(FasterRoutePolicy.swapPick([red, clearTolled], leg: leg, filters: [],
                                                  limits: FilterLimits(), calmest: false)?.id,
                       red.id)
    }

    /// Towing on a reroute: a crosswind on a Green road is less risk than a
    /// Red road with none, so the weather filters rank after the level —
    /// and within one level they still win. The rig's own limits come
    /// first: a road the trailer can't fit under is no way out.
    func testARigsLimitsComeFirstAndItsWeatherFiltersAfterTheLevel() {
        let leg = route()
        let towing = RouteFilter.towingSafety
        func scored(_ risk: Double, wind: Double = 0) -> PlannedRoute {
            var r = route(risk: risk, eta: 600)
            r.weatherScored = true
            r.familyPeaks = ["wind": wind]
            return r
        }
        let calmRed = scored(0.9)
        let windyGreen = scored(0.5, wind: 0.75)
        XCTAssertEqual(FasterRoutePolicy.swapPick([calmRed, windyGreen], leg: leg, filters: towing,
                                                  limits: FilterLimits(), calmest: true)?.id,
                       windyGreen.id)
        let windyClear = scored(0.2, wind: 0.75)
        let calmGreen = scored(0.6)
        XCTAssertEqual(FasterRoutePolicy.swapPick([windyClear, calmGreen], leg: leg,
                                                  filters: towing, limits: FilterLimits(),
                                                  calmest: true)?.id,
                       calmGreen.id)
        var lowBridgeClear = scored(0.1)
        lowBridgeClear.clearancesMeters = [3.35]   // 11 ft, under a 13'6" rig
        XCTAssertEqual(FasterRoutePolicy.swapPick([lowBridgeClear, calmRed], leg: leg,
                                                  filters: towing, limits: FilterLimits(),
                                                  calmest: true)?.id,
                       calmRed.id)
        // A grade is no wall: a rig climbs 6.3%, slowly. A steep Clear road
        // beats a gentle Red one in a Tornado Warning.
        var steepClear = scored(0.2)
        steepClear.maxGradePercent = 6.3
        var gentleRed = scored(0.9)
        gentleRed.maxGradePercent = 5.5
        XCTAssertEqual(FasterRoutePolicy.swapPick([gentleRed, steepClear], leg: leg,
                                                  filters: towing, limits: FilterLimits(),
                                                  calmest: true)?.id,
                       steepClear.id)
        // Between two roads at one level, the grade still counts.
        var steepGreen = scored(0.5)
        steepGreen.maxGradePercent = 6.3
        var gentleGreen = scored(0.55)
        gentleGreen.maxGradePercent = 5.5
        XCTAssertEqual(FasterRoutePolicy.swapPick([steepGreen, gentleGreen], leg: leg,
                                                  filters: towing, limits: FilterLimits(),
                                                  calmest: true)?.id,
                       gentleGreen.id)
    }

    /// The level a reroute escapes by: Clear and Green are one low level.
    func testRerouteLevels() {
        XCTAssertEqual(FasterRoutePolicy.rerouteLevel(0.1), 0)
        XCTAssertEqual(FasterRoutePolicy.rerouteLevel(0.5), 0)
        XCTAssertEqual(FasterRoutePolicy.rerouteLevel(0.75), 1)
        XCTAssertEqual(FasterRoutePolicy.rerouteLevel(0.9), 2)
    }

    /// With every route breaking a filter, the list shows the one breaking
    /// the fewest; a spoken yes takes the same one.
    func testClosestMatchBreaksTheFewestFilters() {
        var windy = route(risk: 0.2, eta: 300)
        windy.weatherScored = true
        windy.familyPeaks = ["wind": 0.9]
        let tolled = route(Road(tolls: true), risk: 0.4, eta: 600)
        var both = route(Road(tolls: true), risk: 0.1, eta: 200)
        both.weatherScored = true
        both.familyPeaks = ["wind": 0.9]
        let filters: Set<RouteFilter> = [.noTolls, .noHighWinds]
        XCTAssertEqual(RouteFilter.closestMatch(in: [both, tolled, windy], filters: filters,
                                                limits: FilterLimits())?.id,
                       windy.id)   // one broken each; the calmer
        XCTAssertNil(RouteFilter.closestMatch(in: [], filters: filters, limits: FilterLimits()))
    }

    // MARK: the needs clock across a reroute

    /// A reroute 110 miles in keeps the rest stop at mile 120 — 10 miles
    /// ahead, not 120 from the new leg's start. A stop restarts the clock.
    func testARerouteKeepsTheRestCountdown() {
        let before = TripNeeds.milesSinceStop(beforeLeg: 0, drivenOnLastLegMeters: 110 * 1609.344,
                                              stopped: false)
        XCTAssertEqual(before, 110, accuracy: 1e-9)
        // A second reroute 5 miles on keeps counting.
        XCTAssertEqual(TripNeeds.milesSinceStop(beforeLeg: before,
                                                drivenOnLastLegMeters: 5 * 1609.344,
                                                stopped: false),
                       115, accuracy: 1e-9)
        XCTAssertEqual(TripNeeds.milesSinceStop(beforeLeg: before, drivenOnLastLegMeters: 1_000,
                                                stopped: true), 0)
        // The schedule runs from the stop through the new leg (100 more miles).
        let schedule = TripNeeds.schedule(totalMiles: before + 100,
                                          intervals: TripNeeds.Intervals(restMiles: 120))
        let next = TripNeeds.next(after: before, in: schedule)
        XCTAssertEqual(next?.need, .rest)
        XCTAssertEqual(next?.mile ?? 0, 120, accuracy: 1e-9)
    }

    // MARK: the road ahead, live

    private func sample(_ risk: Double, _ event: String?) -> RiskSample {
        RiskSample(coordinate: here, risk: risk, worstEvent: event, alertID: event)
    }

    /// Check points every 10 km: a Flood Warning at the first, a Tornado
    /// Warning at the third, a Wind Advisory at the last.
    private func scoredLeg() -> PlannedRoute {
        var r = route()
        r.alertEvents = ["Flood Warning"]   // what planning saw
        r.riskSamples = [sample(0.6, "Flood Warning"), sample(0.1, nil),
                         sample(0.95, "Tornado Warning"), sample(0.4, "Wind Advisory")]
        r.riskSegments = [10_000, 10_000, 10_000].map {
            RiskSegment(coordinates: [], risk: 0, lengthMeters: $0)
        }
        return r
    }

    /// A warning the live watch painted on mid-drive is named, worst first;
    /// one the car has passed is not. The plan-time list said "No weather
    /// alerts" through a Tornado Warning issued an hour in.
    func testTheRoadAheadNamesLiveAlertsWorstFirst() {
        let leg = scoredLeg()
        XCTAssertEqual(leg.alertEventsAhead(alongMeters: 15_000),
                       ["Tornado Warning", "Wind Advisory"])
        // Inside the first stretch, its first check point still counts.
        XCTAssertEqual(leg.alertEventsAhead(alongMeters: 5_000),
                       ["Tornado Warning", "Flood Warning", "Wind Advisory"])
        // At the third check point, the first is well behind.
        XCTAssertEqual(leg.alertEventsAhead(alongMeters: 20_000),
                       ["Tornado Warning", "Wind Advisory"])
        // Nothing scored yet: the plan-time list is all there is.
        XCTAssertEqual(route().alertEventsAhead(alongMeters: 0), [])
        var unscored = route()
        unscored.alertEvents = ["Flood Warning"]
        XCTAssertEqual(unscored.alertEventsAhead(alongMeters: 0), ["Flood Warning"])
        // An alert that is never the worst at any check point (a Flood
        // Warning inside a Tornado Warning stretch) is still named once the
        // live watch has seen it; the watch's list leads, each alert once.
        var watched = scoredLeg()
        watched.watchedAlertEvents = ["Tornado Warning", "Flash Flood Warning"]
        XCTAssertEqual(watched.alertEventsAhead(alongMeters: 15_000),
                       ["Tornado Warning", "Flash Flood Warning", "Wind Advisory"])
    }

    // MARK: warning shapes on the driven route

    private func polygon(_ event: String, expires: Date?, at lat: Double = 41.0)
        -> WeatherAlertService.AlertPolygon {
        WeatherAlertService.AlertPolygon(
            coordinates: [CLLocationCoordinate2D(latitude: lat, longitude: -104.8),
                          CLLocationCoordinate2D(latitude: lat + 0.1, longitude: -104.8),
                          CLLocationCoordinate2D(latitude: lat + 0.1, longitude: -104.7)],
            severity: 0.95, event: event, expires: expires)
    }

    /// An expired warning's shape leaves the map with its banner; one that
    /// doesn't say when it ends stays.
    func testExpiredWarningShapesLeave() {
        let now = Date()
        let expired = polygon("Tornado Warning", expires: now.addingTimeInterval(-60))
        let open = polygon("Flood Advisory", expires: nil, at: 42)
        XCTAssertTrue(expired.hasExpired(at: now))
        XCTAssertFalse(open.hasExpired(at: now))
        let merged = WeatherAlertService.mergedPolygons([expired, open], live: [], now: now)
        XCTAssertEqual(merged.map(\.event), ["Flood Advisory"])
    }

    /// A shape already drawn stays as it is (no redraw every pass) unless
    /// its warning was extended; a new one joins.
    func testLiveShapesMergeWithoutRedrawing() {
        let now = Date()
        let ends = now.addingTimeInterval(1_800)
        let drawn = polygon("Tornado Warning", expires: ends)
        let same = polygon("Tornado Warning", expires: ends)
        let kept = WeatherAlertService.mergedPolygons([drawn], live: [same], now: now)
        XCTAssertEqual(kept.map(\.id), [drawn.id])
        let extended = polygon("Tornado Warning", expires: ends.addingTimeInterval(1_800))
        let newer = WeatherAlertService.mergedPolygons([drawn], live: [extended], now: now)
        XCTAssertEqual(newer.map(\.id), [extended.id])
        let other = polygon("Severe Thunderstorm Warning", expires: ends, at: 43)
        XCTAssertEqual(WeatherAlertService.mergedPolygons([drawn], live: [other], now: now).count, 2)
    }

    // MARK: what is said

    /// The rising-risk prompt is spoken: what raised it, one period, no
    /// promise of a spoken answer nobody listens for.
    func testTheRisingRiskPromptIsSpoken() {
        XCTAssertEqual(SiriSummaries.escalationPrompt(headline: "Tornado Warning ahead"),
                       "Your route is getting riskier. Tornado Warning ahead.")
        XCTAssertEqual(SiriSummaries.escalationPrompt(headline: "Road closed ahead."),
                       "Your route is getting riskier. Road closed ahead.")
        let long = String(repeating: "Flooding reported on the highway. ", count: 10)
        XCTAssertLessThanOrEqual(SiriSummaries.escalationPrompt(headline: long).count, 200)
    }

    /// A trip planned while another is driven is taken by a yes — nothing
    /// is on screen to pick.
    func testATripOfferSaysHowToTakeIt() {
        XCTAssertEqual(
            SiriSummaries.tripOffer(name: "Cheyenne", meters: 100 * 1609.344, seconds: 5_400,
                                    whileDriving: true),
            "Route to Cheyenne: about 100 miles and 1 hour 30 minutes. "
                + "Say: go ahead in FLOWS to switch to it.")
        XCTAssertEqual(
            SiriSummaries.tripOffer(name: "Cheyenne", meters: 100 * 1609.344, seconds: 5_400,
                                    whileDriving: false),
            "Route to Cheyenne: about 100 miles and 1 hour 30 minutes. "
                + "Say: go ahead in FLOWS — or pick a route on screen.")
        XCTAssertEqual(
            SiriSummaries.tripOfferChanged(meters: 90 * 1609.344, seconds: 6_000),
            "That route no longer fits your filters. The best one left is about 90 miles "
                + "and 1 hour 40 minutes. Say: go ahead in FLOWS to take it.")
    }
}
