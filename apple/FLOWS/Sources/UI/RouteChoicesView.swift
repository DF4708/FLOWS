// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import MapKit
import SwiftUI

/// Alternate-route comparison cards. Tap a card to HIGHLIGHT that route on
/// the map (risk-colored, alternates gray) and frame its corridor; tap GO to
/// start turn-by-turn. Each card carries what an informed choice needs:
/// via-road, ETA + delta vs the fastest, distance, tolls/highways, the FLOWS
/// risk band, a stacked strip showing how much of the corridor sits in each
/// band, and the worst active alert.
struct RouteChoicesView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var camera: MapCameraPosition

    private var choices: [PlannedRoute] { model.filteredChoices }

    struct TransitOption {
        let title: String
        let detail: String
        let fare: Double
        let destination: MKMapItem
        /// The EXACT ticket for the ride: label naming board → alight, plus the
        /// carrier's booking page (Amtrak/Greyhound) or the station/agency URL.
        var ticketLabel: String?
        var ticketURL: URL?
        /// This option's own itinerary — rail and bus cards coexist, each with
        /// its own legs; tapping a card draws ITS itinerary on the map.
        var itinerary: TransitItinerary?
        /// Rental counters near the destination — the traveller arrives
        /// WITHOUT a car (that's the whole point of leg 3 being a walk).
        var rentals: [RentalCars.Office] = []
    }
    /// The three transit toggles. Rail/bus route through stations; plane
    /// boards at the nearest commercial airports.
    enum TransitMode: CaseIterable, Hashable { case rail, bus, plane }
    /// Per-mode transit options — car, train, bus, AND plane can all be
    /// selected together; the planner shows every option.
    @State private var transitOptions: [TransitMode: TransitOption] = [:]
    /// Which transit modes are toggled ON (multi-select).
    @State private var activeTransitModes: Set<TransitMode> = []
    /// The in-flight transit computation, so a fresh mode tap cancels the last
    /// one — otherwise a slower stale result could overwrite the newer itinerary.
    // Per-mode so cancelling one never orphans the others, and so the cancel
    // actually targets a live task (the single var was never assigned — every
    // Task.isCancelled guard was dead, letting a stale itinerary overwrite
    // fresh state).
    @State private var transitTasks: [TransitMode: Task<Void, Never>] = [:]
    /// The walk + paid-ride option, present only in walking mode and only
    /// when the ride clears the significance bar (HybridWalk).
    @State private var hybridOption: HybridOption?

    private func replanForMode() async {
        guard let ep = model.lastPlanEndpointsPublic else { return }
        transitTasks.values.forEach { $0.cancel() }   // a drive replan supersedes any in-flight transit calc
        transitTasks = [:]
        if let planned = try? await model.plan(from: ep.from, fromName: ep.fromName,
                                               to: ep.to, toName: ep.toName) {
            model.present(routes: planned)   // clears model.transitItinerary
            transitOptions = [:]             // …drop the now-stale transit cards too
            activeTransitModes = []          // …and untoggle rail/bus/plane
            hybridOption = nil               // …the walk+ride offer recomputes for the new plan
        }
    }

    /// One computation per toggled mode: rail/bus route via stations; plane
    /// boards at the nearest commercial airports.
    private func computeTransit(mode: TransitMode) async {
        switch mode {
        case .plane: await computeAirTransit()
        case .rail: await computeGroundTransit(rail: true)
        case .bus: await computeGroundTransit(rail: false)
        }
    }

    /// Rail/bus option: walk to the best station, ride (transit ETA where
    /// Apple has coverage), fare DISCLOSED as an estimate. Long trips route
    /// to Amtrak (rail) / Greyhound (bus). Multi-system chains ride Apple's
    /// transit data where covered; turn-by-turn hands off to Maps.
    /// Build a full multi-leg itinerary drawn + stepped IN FLOWS: walk to the
    /// boarding station, ride, then WALK from the ARRIVAL station to the
    /// destination. The traveller took the train, so the last mile is never a
    /// drive — leg 3 is always walking (local transit later). MapKit gives real
    /// geometry + steps for the walk legs; the ride leg's true rail shape needs
    /// GTFS, so it's drawn station-to-station and labelled approximate.
    private func computeGroundTransit(rail: Bool) async {
        let tMode: TransitMode = rail ? .rail : .bus
        guard let ep = model.lastPlanEndpointsPublic else { return }
        let miles = POIRanking.meters(ep.from, ep.to) / 1609.344
        let longHaul = miles > 60
        let kind = longHaul ? (rail ? "Amtrak" : "Greyhound") : (rail ? "Rail" : "Bus")

        // @Sendable: these run concurrently via `async let`; they capture only
        // Sendable value-type locals (longHaul/rail/kind), never self or model.
        @Sendable func station(near c: CLLocationCoordinate2D) async -> MKMapItem? {
            let maxMeters = longHaul ? 120_000.0 : 20_000.0
            // Amtrak board/alight comes from the BUNDLED station list first —
            // Amtrak publishes every station location, so this is an offline
            // exact lookup where the text search missed most stations. The
            // network search below stays as the off-list fallback and the
            // only source for local rail and all bus.
            if longHaul, rail,
               let s = AmtrakStations.nearest(to: c, within: maxMeters) {
                let item = MKMapItem(placemark: MKPlacemark(coordinate: s.coordinate))
                item.name = s.name
                item.url = s.url
                return item
            }
            let r = MKLocalSearch.Request()
            r.naturalLanguageQuery = longHaul ? (rail ? "Amtrak station" : "Greyhound bus station")
                                              : (rail ? "train station" : "bus station transit center")
            r.region = MKCoordinateRegion(center: c,
                latitudinalMeters: longHaul ? 60_000 : 8_000,
                longitudinalMeters: longHaul ? 60_000 : 8_000)
            guard let items = (try? await MKLocalSearch(request: r).start())?.mapItems
            else { return nil }
            // MKLocalSearch's `region` is a relevance BIAS, not a hard filter:
            // with no in-region match it returns the nearest station anywhere
            // (Greyhound left Canada in 2021, so "Greyhound near Toronto" yields
            // Atlanta). Reject anything past a sane radius so we never alight in
            // the wrong city and "walk" interstate — and take the NEAREST match.
            return items
                .filter { POIRanking.meters($0.placemark.coordinate, c) <= maxMeters }
                .min { POIRanking.meters($0.placemark.coordinate, c)
                     < POIRanking.meters($1.placemark.coordinate, c) }
        }
        // Boarding station near the start AND arrival station near the
        // destination — the second is what makes the off-the-train leg real.
        async let boardTask = station(near: ep.from)
        async let alightTask = station(near: ep.to)
        guard let board = await boardTask else {
            if Task.isCancelled { return }   // don't let a superseded tap clear newer state
            model.transitItinerary = nil
            // No rail in range → still be useful: the bundled list names the
            // CLOSEST Amtrak station within intercity range, offline.
            var detail = "No station within range of the start point."
            if rail, let nearest = AmtrakStations.nearest(to: ep.from, within: 240_000) {
                let mi = POIRanking.meters(nearest.coordinate, ep.from) / 1609.344
                detail = String(format: "No rail close by. Closest train: %@, %.0f mi away — drive there or take the bus option.",
                                nearest.name, mi)
            }
            transitOptions[tMode] = TransitOption(
                title: rail ? "No rail found nearby" : "No bus service found nearby",
                detail: detail,
                fare: 0, destination: MKMapItem(placemark: MKPlacemark(coordinate: ep.to)))
            return
        }
        let alight = await alightTask
        if Task.isCancelled { return }   // a newer mode tap superseded this one
        let boardC = board.placemark.coordinate
        let alightC = alight?.placemark.coordinate ?? ep.to

        // The four requests are independent — run them concurrently. (The
        // fetch helpers are shared with the plane + walk-hybrid paths; they
        // live at file scope and capture nothing.)
        async let w1 = transitWalk(ep.from, boardC)
        async let rideG = transitDrive(boardC, alightC)
        async let w3 = transitWalkIf(alight != nil, alightC, ep.to)
        async let rentalsNearDest = transitRentals(near: ep.to)
        let (w1poly, w1sec, w1steps, w1mi) = await w1
        let (ridePolyOpt, rideRoadMi, driveSec) = await rideG
        let last = await w3

        // Prefer real road miles; when directions failed, inflate the straight-
        // line span by a circuity factor so the fallback estimate errs long, not
        // optimistically short (it feeds both the time and the displayed miles).
        let rideMi = rideRoadMi ?? POIRanking.meters(boardC, alightC) / 1609.344 * 1.2
        let rideSec = TransitPlanning.rideDuration(
            mode: kind, driveSeconds: driveSec, miles: rideMi)
        let ridePoly = ridePolyOpt ?? TransitPlanning.connector(boardC, alightC)

        let boardName = board.name ?? "the boarding station"
        let startName = ep.fromName.isEmpty ? "your start" : ep.fromName
        let destName = ep.toName.isEmpty ? "your destination" : ep.toName
        // No arrival station in range → the ride heads for the destination
        // city itself (the tail note flags that the last mile is unplanned).
        let alightName = alight?.name ?? destName

        // Skip a degenerate ride when start and destination share one station
        // (both resolve to the same stop): a 0-mile "Ride X → X" is meaningless,
        // so the itinerary collapses to the walk legs.
        let hasRide = rideMi >= 0.3
        // ACCESS leg: walk when the station is walkable; beyond ~45 min the
        // honest first leg is park-and-ride — the traveller HAS a car at the
        // start (this is a driving app), and "walk 5 h 14 m to the terminal"
        // buried a 90-minute trip inside a 6-hour total.
        var accessLeg = TransitLeg(kind: .walk, fromName: startName, toName: boardName,
                                   seconds: w1sec, miles: w1mi,
                                   polyline: w1poly, steps: w1steps)
        // WALKING MODE: the traveller has NO car — never park-and-ride. A
        // station beyond a comfortable walk gets a ride-share first leg
        // instead (Uber/Lyft deep links need no account keys; the links open
        // their apps/sites with the pickup and drop-in already filled).
        if model.walkingMode {
            if (w1sec ?? .infinity) > 2700 {
                accessLeg = TransitLeg(
                    kind: .walk, fromName: startName, toName: boardName,
                    seconds: w1sec, miles: w1mi, polyline: w1poly,
                    steps: ["The station is a long walk (\(TransitPlanning.fmt(w1sec)))",
                            "A ride share can cover this first leg:",
                            "Uber: m.uber.com — set drop-off to \(boardName)",
                            "Lyft: lyft.com/ride — set drop-off to \(boardName)"])
            }
        } else if (w1sec ?? .infinity) > 2700 {
            let (drivePoly, driveMi, driveSecs) = await transitDrive(ep.from, boardC)
            if let driveSecs {
                accessLeg = TransitLeg(
                    kind: .drive, fromName: startName, toName: boardName,
                    seconds: driveSecs, miles: driveMi, polyline: drivePoly,
                    steps: ["Drive to \(boardName)",
                            "Park at or near the station",
                            "Your car stays here — the far end is on foot"])
            }
        }
        var legs: [TransitLeg] = [accessLeg]
        if hasRide {
            legs.append(TransitLeg(kind: .ride, fromName: boardName, toName: alightName,
                       seconds: rideSec, miles: rideMi, polyline: ridePoly,
                       steps: TransitPlanning.rideSteps(mode: kind, board: boardName,
                                                        alight: alightName, seconds: rideSec)))
        }
        // Leg 3 is ALWAYS a walk — the traveller rode transit, so the last mile
        // is never a drive. With a real arrival station we route it exactly;
        // without one we still end on foot and say to plan the last mile.
        let lastSteps: [String] = alight != nil
            ? (last.2.isEmpty ? ["Walk from \(alightName) to \(destName)"] : last.2)
            : ["Continue to \(destName) on foot — plan the last mile locally"]
        legs.append(TransitLeg(kind: .walk, fromName: alightName, toName: destName,
                               seconds: last.1, miles: last.3, polyline: last.0, steps: lastSteps))

        // Fare from the RIDE distance (road miles board→alight), matching the
        // drawn geometry and the time — not the great-circle endpoint span. No
        // ride (walk-only collapse) → no fare, so no phantom minimum shows.
        let fare = hasRide
            ? (longHaul ? (rail ? TransitFares.amtrak(miles: rideMi)
                                : TransitFares.greyhound(miles: rideMi))
                        : (rail ? TransitFares.localRail() : TransitFares.localBus()))
            : 0
        let dest = MKMapItem(placemark: MKPlacemark(coordinate: ep.to))
        if Task.isCancelled { return }   // a newer mode tap superseded this one
        let itinerary = TransitItinerary(
            mode: kind, legs: legs, fare: fare, mapsDestination: dest,
            rideGeometryIsApproximate: hasRide,
            rideGeometryIsReal: ridePolyOpt != nil)
        model.transitItinerary = itinerary   // latest computed draws on the map

        let tail = alight != nil
            ? " · then walk \(TransitPlanning.fmt(last.1)) from \(alightName)"
            : " · no arrival station found — plan the last mile at \(destName)"
        // The EXACT ticket to buy for this ride, listed on the card.
        var ticketLabel: String?
        var ticketURL: URL?
        if hasRide {
            let t = TransitTickets.ticket(mode: kind, board: boardName,
                                          alight: alightName, stationURL: board.url)
            ticketLabel = t.label
            ticketURL = t.url
        }
        // Final guard: a mode re-tap / drive replan may have superseded this
        // computation during the last awaits — don't commit a stale itinerary.
        if Task.isCancelled { return }
        let accessVerb = accessLeg.kind == .drive ? "Drive" : "Walk"
        transitOptions[tMode] = TransitOption(
            title: "\(kind) via \(boardName)",
            detail: "\(accessVerb) \(TransitPlanning.fmt(accessLeg.seconds)) to \(boardName) · "
                    + "\(kind.lowercased()) ride \(TransitPlanning.fmt(rideSec))\(tail) · est. fare "
                    + String(format: "$%.2f (carriers set final pricing).", fare),
            fare: fare, destination: dest,
            ticketLabel: ticketLabel, ticketURL: ticketURL,
            itinerary: itinerary,
            rentals: await rentalsNearDest)
    }

    /// Plane option: board at the nearest airport with airline service to the
    /// start, land at the nearest to the destination. Airport time (arrive
    /// early, bags) is INSIDE the leg time so the total is honest; the fare
    /// line says plainly that airlines set prices. The flight draws as a
    /// geodesic arc — planes don't follow roads.
    private func computeAirTransit() async {
        guard let ep = model.lastPlanEndpointsPublic else { return }
        let tripMiles = POIRanking.meters(ep.from, ep.to) / 1609.344
        let dest = MKMapItem(placemark: MKPlacemark(coordinate: ep.to))
        guard AirTravel.worthFlying(tripMiles: tripMiles) else {
            if Task.isCancelled { return }
            transitOptions[.plane] = TransitOption(
                title: "Flying won't help here",
                detail: String(format: "This trip is about %.0f miles. With "
                               + "airport time added, a flight only beats the "
                               + "road past %.0f miles.",
                               tripMiles, AirTravel.minTripMiles),
                fare: 0, destination: dest)
            return
        }
        // Nearest airport that can actually board a passenger flight: MapKit's
        // .airport category near the point, then the name-based commercial
        // filter (pure, tested) drops heliports/private strips and prefers
        // internationals; nearest wins within a score tier.
        @Sendable func airport(near c: CLLocationCoordinate2D) async -> MKMapItem? {
            let r = MKLocalSearch.Request()
            r.naturalLanguageQuery = "airport"
            r.pointOfInterestFilter = MKPointOfInterestFilter(including: [.airport])
            r.region = MKCoordinateRegion(center: c,
                latitudinalMeters: 150_000, longitudinalMeters: 150_000)
            guard let items = (try? await MKLocalSearch(request: r).start())?.mapItems
            else { return nil }
            let picked = AirTravel.pickIndex(items.map {
                AirTravel.Candidate(name: $0.name ?? "",
                                    meters: POIRanking.meters($0.placemark.coordinate, c))
            }, maxMeters: 150_000)
            return picked.map { items[$0] }
        }
        async let boardTask = airport(near: ep.from)
        async let alightTask = airport(near: ep.to)
        let (boardOpt, alightOpt) = await (boardTask, alightTask)
        if Task.isCancelled { return }
        guard let board = boardOpt, let alight = alightOpt,
              POIRanking.meters(board.placemark.coordinate,
                                alight.placemark.coordinate) / 1609.344
                  >= AirTravel.minAirportGapMiles else {
            transitOptions[.plane] = TransitOption(
                title: "No flight fits this trip",
                detail: boardOpt == nil || alightOpt == nil
                    ? "No airport with airline service found near one end of the trip."
                    : "Both ends of the trip use the same nearby airport — flying can't shorten it.",
                fare: 0, destination: dest)
            return
        }
        let boardC = board.placemark.coordinate
        let alightC = alight.placemark.coordinate
        let boardName = board.name ?? "the departure airport"
        let alightName = alight.name ?? "the arrival airport"
        let startName = ep.fromName.isEmpty ? "your start" : ep.fromName
        let destName = ep.toName.isEmpty ? "your destination" : ep.toName
        let airportMiles = POIRanking.meters(boardC, alightC) / 1609.344

        // Airport access, the last mile, and rentals at the ARRIVAL airport
        // (the flyer lands car-less — same reuse as the train cards), all
        // independent, all concurrent.
        async let w1 = transitWalk(ep.from, boardC)
        async let w3 = transitWalk(alightC, ep.to)
        async let rentalsAtAirport = transitRentals(near: alightC)
        let (w1poly, w1sec, w1steps, w1mi) = await w1

        // Same access rule as the station cards: walk when walkable, else
        // drive + park.
        var accessLeg = TransitLeg(kind: .walk, fromName: startName, toName: boardName,
                                   seconds: w1sec, miles: w1mi,
                                   polyline: w1poly, steps: w1steps)
        if (w1sec ?? .infinity) > 2700 {
            let (drivePoly, driveMi, driveSecs) = await transitDrive(ep.from, boardC)
            if let driveSecs {
                accessLeg = TransitLeg(
                    kind: .drive, fromName: startName, toName: boardName,
                    seconds: driveSecs, miles: driveMi, polyline: drivePoly,
                    steps: ["Drive to \(boardName)",
                            "Park at or near the airport",
                            "Your car stays here — rent or ride at the far end"])
            }
        }

        var arcPoints = [boardC, alightC]
        let arc = MKGeodesicPolyline(coordinates: &arcPoints, count: 2)
        let flySec = AirTravel.doorSeconds(airportMiles: airportMiles)
        let flyLeg = TransitLeg(kind: .ride, fromName: boardName, toName: alightName,
                                seconds: flySec, miles: airportMiles, polyline: arc,
                                steps: AirTravel.flightSteps(board: boardName,
                                                             alight: alightName,
                                                             airportMiles: airportMiles))

        // Last mile from the arrival airport: walk when it's a real walk;
        // otherwise an honest "rent or ride" leg — airports rarely end on foot.
        let last = await w3
        var legs = [accessLeg, flyLeg]
        if let lastSec = last.1, lastSec <= 2700 {
            legs.append(TransitLeg(kind: .walk, fromName: alightName, toName: destName,
                                   seconds: lastSec, miles: last.3, polyline: last.0,
                                   steps: last.2.isEmpty
                                       ? ["Walk from \(alightName) to \(destName)"]
                                       : last.2))
        } else {
            let (drivePoly, driveMi, driveSecs) = await transitDrive(alightC, ep.to)
            legs.append(TransitLeg(kind: .drive, fromName: alightName, toName: destName,
                                   seconds: driveSecs, miles: driveMi, polyline: drivePoly,
                                   steps: ["Rent a car or get a ride at \(alightName)",
                                           "Go to \(destName) — rental counters listed below"]))
        }

        let fare = AirTravel.fareEstimate(airportMiles: airportMiles)
        if Task.isCancelled { return }
        let itinerary = TransitItinerary(
            mode: "Plane", legs: legs, fare: fare, mapsDestination: dest,
            rideGeometryIsApproximate: true)
        model.transitItinerary = itinerary

        let ticket = AirTravel.ticket(board: boardName, alight: alightName,
                                      airportURL: board.url)
        let accessVerb = accessLeg.kind == .drive ? "Drive" : "Walk"
        if Task.isCancelled { return }
        transitOptions[.plane] = TransitOption(
            title: "Plane via \(boardName)",
            detail: "\(accessVerb) \(TransitPlanning.fmt(accessLeg.seconds)) to \(boardName) · "
                    + "flight \(TransitPlanning.fmt(flySec)) counting airport time · est. fare "
                    + String(format: "$%.0f — airlines set the real price.", fare),
            fare: fare, destination: dest,
            ticketLabel: ticket.label, ticketURL: ticket.url,
            itinerary: itinerary,
            rentals: await rentalsAtAirport)
    }

    // MARK: - Walk + paid ride (walking mode)

    /// The walk + paid-ride card's computed pieces.
    struct HybridOption {
        let walkAloneSeconds: TimeInterval
        let offer: HybridWalk.Offer
        let uberURL: URL?
        let lyftURL: URL?
        let itinerary: TransitItinerary
    }

    /// Walking mode's "best time for the money" option: a paid ride segment,
    /// offered ONLY when it clears HybridWalk's significance bar (>= 40% and
    /// >= 15 min saved, <= $25 est.). Whole-trip ride when the cap affords
    /// it; otherwise ride the first affordable miles from the start and walk
    /// the rest — with the walk remainder re-routed for real and the bar
    /// re-checked before anything is offered.
    private func computeHybrid() async {
        hybridOption = nil
        guard model.walkingMode, let ep = model.lastPlanEndpointsPublic,
              let walkRoute = choices.min(by: { $0.eta < $1.eta })
        else { return }
        let walkAlone = walkRoute.eta
        let (drivePolyOpt, driveMiOpt, driveSecOpt) = await transitDrive(ep.from, ep.to)
        guard let drivePoly = drivePolyOpt, let driveSec = driveSecOpt else { return }
        let tripMiles = driveMiOpt ?? walkRoute.distanceMeters / 1609.344
        guard var offer = HybridWalk.evaluate(walkAloneSeconds: walkAlone,
                                              driveSeconds: driveSec,
                                              tripMiles: tripMiles) else { return }
        let startName = ep.fromName.isEmpty ? "your start" : ep.fromName
        let destName = ep.toName.isEmpty ? "your destination" : ep.toName

        var ridePoly: MKPolyline = drivePoly
        var drop = ep.to
        var dropName = destName
        var walkLeg: TransitLeg?
        if offer.walkSeconds > 0 {
            // Partial ride: drop off at the wallet cap's distance along the
            // drive route, then route the REAL walk remainder and re-check
            // the bar with routed numbers — the estimate opens the door,
            // reality decides.
            let prefix = HybridWalk.prefixCoordinates(
                Self.coordinates(of: drivePoly),
                meters: offer.rideMiles * 1609.344)
            guard prefix.count >= 2, let dropC = prefix.last else { return }
            drop = dropC
            dropName = "the drop-off point"
            var pts = prefix
            ridePoly = MKPolyline(coordinates: &pts, count: pts.count)
            let (wPoly, wSec, wSteps, wMi) = await transitWalk(drop, ep.to)
            guard let wSec else { return }
            offer.walkSeconds = wSec
            guard HybridWalk.meetsBar(walkAloneSeconds: walkAlone,
                                      totalSeconds: offer.totalSeconds,
                                      costUSD: offer.costUSD) else { return }
            walkLeg = TransitLeg(kind: .walk, fromName: dropName, toName: destName,
                                 seconds: wSec, miles: wMi, polyline: wPoly,
                                 steps: wSteps.isEmpty
                                     ? ["Walk the rest of the way to \(destName)"]
                                     : wSteps)
        }

        var legs = [TransitLeg(kind: .drive, fromName: startName, toName: dropName,
                               seconds: offer.rideSeconds, miles: offer.rideMiles,
                               polyline: ridePoly,
                               steps: ["Get your ride at \(startName)",
                                       "Ride \(TransitPlanning.durationPhrase(offer.rideSeconds))",
                                       "Get out at \(dropName)"])]
        if let walkLeg { legs.append(walkLeg) }
        if Task.isCancelled { return }
        hybridOption = HybridOption(
            walkAloneSeconds: walkAlone, offer: offer,
            uberURL: HybridWalk.uberURL(pickup: ep.from, pickupName: startName,
                                        drop: drop,
                                        dropName: walkLeg == nil ? destName : "Drop-off"),
            lyftURL: HybridWalk.lyftURL(pickup: ep.from, drop: drop),
            itinerary: TransitItinerary(
                mode: "Walk + ride", legs: legs, fare: offer.costUSD,
                mapsDestination: MKMapItem(placemark: MKPlacemark(coordinate: ep.to)),
                rideGeometryIsApproximate: false))
    }

    /// All vertices of a polyline (drop-off interpolation runs over these).
    private static func coordinates(of poly: MKPolyline) -> [CLLocationCoordinate2D] {
        let n = poly.pointCount
        guard n > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid, count: n)
        poly.getCoordinates(&coords, range: NSRange(location: 0, length: n))
        return coords
    }

    /// One transit toggle button: colored while its mode is active.
    private func transitToggle(_ mode: TransitMode, symbol: String, help: String) -> some View {
        let isOn = activeTransitModes.contains(mode)
        let tint: Color = switch mode {
        case .rail: .purple
        case .bus: .blue
        case .plane: .indigo
        }
        return Button {
            if isOn {
                deactivate(mode)   // toggle THIS mode off; other selections stay
            } else {
                activeTransitModes.insert(mode)
                transitTasks[mode]?.cancel()
                transitTasks[mode] = Task { await computeTransit(mode: mode) }
            }
        } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                .foregroundStyle(isOn ? .white : .primary)
                .frame(width: 26, height: 26)
                .background(isOn ? tint : Color.black.opacity(0.06))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Turn a transit mode off and surface whichever remaining active mode
    /// has a computed itinerary; the map clears only when nothing is left.
    private func deactivate(_ mode: TransitMode) {
        transitTasks[mode]?.cancel(); transitTasks[mode] = nil
        activeTransitModes.remove(mode)
        transitOptions[mode] = nil
        if let next = TransitMode.allCases.first(where: {
            activeTransitModes.contains($0) && transitOptions[$0]?.itinerary != nil
        }) {
            model.transitItinerary = transitOptions[next]?.itinerary
        } else if activeTransitModes.isEmpty,
                  model.transitItinerary?.mode != "Walk + ride" {
            model.transitItinerary = nil
        }
    }

    private func transitCard(_ t: TransitOption, mode: TransitMode) -> some View {
        let symbol = switch mode {
        case .rail: "tram.fill"
        case .bus: "bus.fill"
        case .plane: "airplane"
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(t.title, systemImage: symbol)
                    .font(.system(size: 13, weight: .bold))
                // Cross-mode banners: transit is "Cheapest" when its estimated
                // fare undercuts every drive option's fuel estimate, and rail/
                // bus are effectively always the CO₂ winner per passenger-mile
                // — say so. Flying is NOT (per-seat emissions rival driving),
                // so the plane card never wears the green chip.
                if let itin = t.itinerary {
                    if itin.fare > 0, !choices.isEmpty,
                       itin.fare < choices.map({ fuelCost($0) }).min() ?? .infinity {
                        Text("Cheapest")
                            .font(.system(size: 10, weight: .heavy))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.9))
                            .foregroundStyle(.white).clipShape(Capsule())
                    }
                    if mode != .plane {
                        Text("CO₂-efficient")
                            .font(.system(size: 10, weight: .heavy))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.mint.opacity(0.9))
                            .foregroundStyle(.white).clipShape(Capsule())
                            .help("Mass transit emits far less CO₂ per passenger-mile than driving")
                    }
                }
                Spacer()
                if let itin = t.itinerary {
                    Text("\(TransitPlanning.fmt(itin.totalSeconds))"
                         + (itin.fare > 0 ? " · ~$\(String(format: "%.0f", itin.fare)) est." : ""))
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                Button {
                    deactivate(mode)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            // In-app itinerary: every leg, with the ARRIVAL-station walk called
            // out — you took the train, so the last mile is on foot, not a drive.
            if let itin = t.itinerary {
                // A "transit" option whose ACCESS WALK dominates (suburban
                // start, downtown-only station) is technically correct but
                // reads as a normal ride — call the walk out up front instead
                // of letting a 5-hour hike hide inside a 6h47m total.
                if let firstWalk = itin.legs.first, firstWalk.kind == .walk,
                   let walkSec = firstWalk.seconds, walkSec > 3600,
                   let ride = itin.legs.first(where: { $0.kind == .ride }),
                   walkSec > (ride.seconds ?? 0) {
                    Label("Mostly walking: the nearest stop is "
                          + "\(TransitPlanning.fmt(walkSec)) on foot — "
                          + "consider driving or a rideshare to the station",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                }
                ForEach(Array(itin.legs.enumerated()), id: \.offset) { i, leg in
                    transitLegRow(leg, isLast: i == itin.legs.count - 1,
                                  plane: mode == .plane)
                }
                if itin.mode == "Plane" {
                    // The flight's honesty note: an arc is not a filed flight
                    // path, and every time here includes the airport waiting.
                    Text("Flight drawn as a straight arc; times include airport "
                         + "waiting and are estimates — airlines set schedules "
                         + "and prices.")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                } else if itin.rideGeometryIsApproximate {
                    let isRail = itin.mode == "Amtrak" || itin.mode == "Rail"
                    // "Walk legs are exact" only holds when every walk leg actually
                    // routed — a leg with no pedestrian route is a synthetic line.
                    let walksExact = itin.legs
                        .filter { $0.kind == .walk }.allSatisfy { $0.polyline != nil }
                    let walkNote = walksExact
                        ? "Walk legs are exact."
                        : "One walk leg couldn't be routed and is shown as an estimate."
                    // The geometry claim must match what's drawn: only claim the
                    // ride follows roads when MapKit actually road-routed it; on the
                    // straight-connector fallback, say so. The time is scaled from
                    // MapKit's measured drive time (distance ÷ speed only in the
                    // no-road fallback), so it's an estimate — not a "distance estimate".
                    let rideNote: String = !itin.rideGeometryIsReal
                        ? "Ride line couldn't be road-routed — drawn straight between "
                          + "stations; the time is an estimate. "
                        : (isRail
                           ? "Ride line follows the highway corridor as a proxy and the time "
                             + "is an estimate — exact rail geometry & schedule arrive with GTFS. "
                           : "Ride line follows the roads the coach drives; the time is an "
                             + "estimate — exact schedule arrives with GTFS. ")
                    Text(rideNote + walkNote)
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                // The EXACT ticket for this ride — carrier booking page in-line;
                // never a hand-off to Maps.
                if let label = t.ticketLabel {
                    if let url = t.ticketURL {
                        Link(destination: url) {
                            Label(label, systemImage: "ticket.fill")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.purple.opacity(0.9))
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                    } else {
                        Label("\(label) — pay on board / agency app",
                              systemImage: "ticket")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                // Wheels at the far end: the traveller arrives WITHOUT a car
                // (leg 3 is a walk by design). Nearest office per brand,
                // biggest brands first — any operator MapKit knows, with the
                // office's own page (or the brand's booking site) linked.
                if !t.rentals.isEmpty {
                    Divider()
                    Label("Rental cars at the destination",
                          systemImage: "car.2.fill")
                        .font(.caption2.weight(.bold))
                    ForEach(Array(t.rentals.enumerated()), id: \.offset) { _, office in
                        HStack(spacing: 4) {
                            Text("\(office.name) · \(String(format: "%.1f mi", office.miles))")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if let url = office.url {
                                Link("Book", destination: url)
                                    .font(.system(size: 10, weight: .bold))
                            }
                        }
                    }
                }
            } else {
                Text(t.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // Tapping a transit card draws ITS itinerary on the map (rail and bus
        // cards can both be open; the tapped one is shown).
        .onTapGesture {
            if let itin = t.itinerary { model.transitItinerary = itin }
        }
    }

    /// One itinerary leg: walk (real MapKit steps), drive (park-and-ride
    /// access, an arrival-airport "rent or ride", or a hailed car on the
    /// walk-hybrid card), or ride (board/alight — train, bus, or flight).
    private func transitLegRow(_ leg: TransitLeg, isLast: Bool,
                               plane: Bool = false, hail: Bool = false) -> some View {
        let (symbol, color): (String, Color) = switch leg.kind {
        case .walk: ("figure.walk", .green)
        case .drive: ("car.fill", .blue)
        case .ride: (plane ? "airplane" : "tram.fill", .purple)
        }
        let title: String = switch leg.kind {
        case .walk: isLast && !hail ? "Walk to \(leg.toName)  (no car — you rode transit)"
                                    : "Walk to \(leg.toName)"
        case .drive: hail ? "Ride to \(leg.toName) — paid car"
                   : isLast ? "Get a ride or rental to \(leg.toName)"
                   : "Drive to \(leg.toName) — park & ride"
        case .ride: plane ? "Fly \(leg.fromName) → \(leg.toName)"
                          : "Ride the \(leg.fromName) → \(leg.toName)"
        }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 4)
                    Text(TransitPlanning.fmt(leg.seconds))
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(leg.steps.prefix(isLast || leg.kind != .walk ? 3 : 2).enumerated()),
                        id: \.offset) { _, s in
                    Text("• \(s)").font(.system(size: 9)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var fastestETA: TimeInterval {
        choices.map(\.eta).min() ?? 0
    }

    /// "$12 fuel est." line for a card; nil when economy/price are unknowable.
    private func fuelCostText(_ route: PlannedRoute) -> String? {
        let cost = fuelCost(route)
        guard cost > 0.5 else { return nil }
        return String(format: "~$%.0f fuel est.", cost)
    }

    /// Least-violating route when filters empty the list — ties broken by
    /// weather risk then ETA.
    private var closestMatch: PlannedRoute? {
        model.routeChoices.min { a, b in
            let va = model.violationCount(a), vb = model.violationCount(b)
            if va != vb { return va < vb }
            if a.weatherRisk != b.weatherRisk { return a.weatherRisk < b.weatherRisk }
            return a.eta < b.eta
        }
    }

    /// "Safest" = lowest normalized corridor risk, decided once every route
    /// has been scored (mirrors the web router's safest profile).
    private var safestID: UUID? {
        let scored = choices.filter(\.weatherScored)
        guard scored.count == choices.count, scored.count > 1,
              let best = scored.min(by: { $0.weatherRisk < $1.weatherRisk })
        else { return nil }
        return best.id
    }

    /// Estimated out-of-pocket fuel cost for a drive route: the driver's own
    /// vehicle economy when a profile exists, else the EPA-average car so
    /// routes stay comparable. State fuel price from the current locale.
    private func fuelCost(_ route: PlannedRoute) -> Double {
        let mpu = model.vehicle.profile?.ratedMilesPerUnit ?? TripCosts.defaultMilesPerUnit
        let fuel = model.vehicle.profile?.fuelType ?? TripCosts.defaultFuel
        let price = FuelPrices.estimate(fuel: fuel, state: model.currentStateCode)
        return TripCosts.driveFuelCostUSD(
            miles: route.distanceMeters / 1609.344, milesPerUnit: mpu,
            pricePerUnit: price) ?? 0
    }

    /// "Cheapest" = lowest estimated fuel cost, ties to fewer tolls. Decided
    /// once all routes are scored so the banner doesn't jump mid-hydration.
    private var cheapestID: UUID? {
        let scored = choices.filter(\.weatherScored)
        guard scored.count == choices.count, scored.count > 1 else { return nil }
        return scored.min(by: {
            let (a, b) = (fuelCost($0), fuelCost($1))
            if abs(a - b) > 0.01 { return a < b }
            return ($0.hasTolls ? 1 : 0) < ($1.hasTolls ? 1 : 0)
        })?.id
    }

    /// "Efficient" = least fuel burned (car) — with one vehicle the shortest
    /// distance wins; CO₂-efficiency for mass transit is flagged on the
    /// transit card instead (per-passenger-mile emissions beat any car).
    private var efficientID: UUID? {
        let scored = choices.filter(\.weatherScored)
        guard scored.count == choices.count, scored.count > 1 else { return nil }
        return scored.min(by: { $0.distanceMeters < $1.distanceMeters })?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Routes")
                    .font(.system(size: 15, weight: .bold))
                // Walk ↔ drive toggle: walking uses Apple's pedestrian
                // network (sidewalks/crossings where mapped, real pace).
                Toggle(isOn: Binding(
                    get: { model.walkingMode },
                    set: { model.walkingMode = $0; Task { await replanForMode() } })) {
                    Image(systemName: model.walkingMode ? "figure.walk" : "car.fill")
                        .font(.system(size: 12, weight: .bold))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
                // Rail/bus/plane are TOGGLES: tinted while active, tap again
                // to turn off (back to drive-only choices).
                transitToggle(.rail, symbol: "tram.fill",
                              help: "Rail option: local rail/subway, or Amtrak for long trips")
                transitToggle(.bus, symbol: "bus.fill",
                              help: "Bus option: local transit, or Greyhound for long trips")
                transitToggle(.plane, symbol: "airplane",
                              help: "Plane option: fly between the nearest airports with airline service")
                // (Tourist stops live in the FILTER grid below — a route
                // option, not a transportation mode.)
                Spacer()
                Button {
                    model.routeChoices = []
                    model.highlightedRouteID = nil
                    // Walking is a per-choice mode, not a persistent setting:
                    // leaving it set made the NEXT plan silently request a
                    // pedestrian route (which can fail at driving distances),
                    // leaving the planner stuck "on walking" with no routes.
                    model.walkingMode = false
                    model.mode = .planning
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if let notice = model.plannerNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .padding(8)
                    .background(Theme.riskYellow.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if !model.walkingMode { filterChips }
            ForEach(TransitMode.allCases.filter { transitOptions[$0] != nil },
                    id: \.self) { mode in
                if let opt = transitOptions[mode] { transitCard(opt, mode: mode) }
            }
            // Walking mode's money-vs-time option — only when walking is the
            // sole selection and the ride clears the significance bar.
            if model.walkingMode, activeTransitModes.isEmpty,
               let h = hybridOption {
                hybridCard(h)
            }
            ScrollView {
                VStack(spacing: 8) {
                    if choices.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No route satisfies every active filter — searching for one…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if let closest = closestMatch {
                                Text("Closest match (violates \(model.violationCount(closest)) filter\(model.violationCount(closest) == 1 ? "" : "s")):")
                                    .font(.caption.weight(.semibold))
                                RouteCard(
                                    route: closest,
                                    keyPoints: keyPoints(for: closest),
                                    fastestETA: closest.eta,
                                    isSafest: false,
                                    isCheapest: false,
                                    isEfficient: false,
                                    fuelCostText: fuelCostText(closest),
                                    isHighlighted: closest.id == model.highlightedRouteID,
                                    onHighlight: { highlight(closest) },
                                    onGo: { model.select(route: closest) })
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    ForEach(choices) { route in
                        RouteCard(
                            route: route,
                            keyPoints: keyPoints(for: route),
                            fastestETA: fastestETA,
                            isSafest: route.id == safestID,
                            isCheapest: route.id == cheapestID,
                            isEfficient: route.id == efficientID,
                            fuelCostText: fuelCostText(route),
                            isHighlighted: route.id == model.highlightedRouteID,
                            onHighlight: { highlight(route) },
                            onGo: { model.select(route: route) })
                    }
                }
            }
        }
        .floatingCard()
        // Recompute the walk+ride offer whenever the plan or the walking
        // toggle changes (the id flips; .task cancels the stale run itself).
        .task(id: "\(model.walkingMode)|\(choices.first?.id.uuidString ?? "-")") {
            await computeHybrid()
        }
    }

    /// The walk + paid-ride card (walking mode only). Plain words, the saving
    /// up front, both hail links, and the price labelled as our guess.
    private func hybridCard(_ h: HybridOption) -> some View {
        let cost = String(format: "%.0f", h.offer.costUSD)
        let savedPct = Int(((h.walkAloneSeconds - h.offer.totalSeconds)
                            / max(h.walkAloneSeconds, 1) * 100).rounded())
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Walk + a paid ride", systemImage: "figure.walk.motion")
                    .font(.system(size: 13, weight: .bold))
                Text("Best time for the money")
                    .font(.system(size: 10, weight: .heavy))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.9))
                    .foregroundStyle(.white).clipShape(Capsule())
                Spacer()
                Text("\(TransitPlanning.fmt(h.offer.totalSeconds)) · ~$\(cost) est.")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Button {
                    hybridOption = nil
                    if model.transitItinerary?.mode == "Walk + ride" {
                        model.transitItinerary = nil
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(h.offer.walkSeconds > 0
                 ? "Walking the whole way takes \(TransitPlanning.fmt(h.walkAloneSeconds)). "
                   + "Ride the first \(String(format: "%.0f", h.offer.rideMiles)) miles "
                   + "for about $\(cost), walk the rest, and get there \(savedPct)% sooner."
                 : "Walking the whole way takes \(TransitPlanning.fmt(h.walkAloneSeconds)). "
                   + "A ride costs about $\(cost) and gets you there \(savedPct)% sooner.")
                .font(.caption)
            ForEach(Array(h.itinerary.legs.enumerated()), id: \.offset) { i, leg in
                transitLegRow(leg, isLast: i == h.itinerary.legs.count - 1, hail: true)
            }
            HStack(spacing: 8) {
                if let uber = h.uberURL {
                    Link(destination: uber) { hailButtonLabel("Open Uber") }
                }
                if let lyft = h.lyftURL {
                    Link(destination: lyft) { hailButtonLabel("Open Lyft") }
                }
                Spacer()
            }
            Text("Uber and Lyft set the real price — $\(cost) is our guess from the miles.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // Tapping draws the ride + walk legs on the map, like the transit cards.
        .onTapGesture { model.transitItinerary = h.itinerary }
    }

    private func hailButtonLabel(_ text: String) -> some View {
        Label(text, systemImage: "car.fill")
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.black.opacity(0.85))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }

    /// Trucker-preset filter buttons in a wrap grid — every chip visible, no
    /// hidden horizontal scroll. The two data-gated presets render dimmed
    /// until we have truck-attribute / elevation data.
    private var filterChips: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 106), spacing: 6)],
                  alignment: .leading, spacing: 6) {
            ForEach(RouteFilter.allCases) { filter in
                let active = model.routeFilters.contains(filter)
                Button {
                    model.toggleFilter(filter)
                } label: {
                    Text(filter.rawValue)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(active ? Theme.cta : Color.black.opacity(0.05))
                        .foregroundStyle(active ? .white : .primary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The pros/cons beneath each option — comparative, so the driver sees
    /// what distinguishes THIS route from the others.
    private func keyPoints(for route: PlannedRoute) -> [(text: String, good: Bool)] {
        var points: [(String, Bool)] = []
        let others = choices.filter { $0.id != route.id }
        guard !others.isEmpty else { return [] }

        if route.eta > fastestETA + 60 {
            points.append(("+\(Int((route.eta - fastestETA) / 60)) min vs fastest", false))
        }
        // The overall band is distance-weighted; the worst STRETCH still gets
        // named so a short bad section is never hidden by a green majority.
        if route.weatherScored {
            let peakBand = FlowsCore.riskBand(score: route.peakRisk)
            if peakBand != FlowsCore.riskBand(score: route.weatherRisk),
               let miles = route.milesByBand.first(where: { $0.band == peakBand })?.miles {
                points.append((String(format: "Worst stretch: %@ for %.0f mi",
                                      peakBand.rawValue, miles), false))
            }
        }
        // Tourist filter on → each card counts the pinned attractions within a
        // worthwhile detour of ITS corridor, so scenic options impact choice.
        if model.routeFilters.contains(.tourist), !model.poi.results.isEmpty,
           !route.riskSamples.isEmpty {
            let near = model.poi.results.filter { r in
                route.riskSamples.contains {
                    POIRanking.meters($0.coordinate, r.item.placemark.coordinate) < 40_000
                }
            }.count
            if near > 0 {
                points.append(("\(near) tourist stop\(near == 1 ? "" : "s") along this route", true))
            }
        }
        if let shortest = choices.map(\.distanceMeters).min(),
           route.distanceMeters <= shortest {
            points.append((String(format: "Shortest — %.0f mi", route.distanceMeters / 1609.344), true))
        }
        if route.weatherScored, choices.allSatisfy(\.weatherScored) {
            if route.id == safestID {
                points.append(("Lowest weather risk of the options", true))
            } else if let worst = choices.max(by: { $0.weatherRisk < $1.weatherRisk }),
                      worst.id == route.id, route.weatherRisk >= FlowsCore.riskGreenMin {
                points.append(("Highest weather risk of the options", false))
            }
            let redYellow = route.milesByBand
                .filter { $0.band == .red || $0.band == .yellow }
                .reduce(0.0) { $0 + $1.miles }
            if redYellow >= 1 {
                points.append((String(format: "%.0f mi in yellow+ conditions", redYellow), false))
            }
        }
        if !route.hasTolls, others.contains(where: \.hasTolls) {
            points.append(("Avoids all tolls", true))
        }
        if route.planKind == .avoidHighways {
            points.append(("Back roads — slower but steadier", true))
        }
        if route.congestionRatio >= 1.35 {
            points.append(("Traffic-prone corridor at this hour", false))
        }
        if (route.familyPeaks["wind"] ?? 0) >= FlowsCore.riskYellowMin {
            points.append(("Elevated wind exposure — high-profile caution", false))
        }
        return Array(points.prefix(4))
    }

    private func highlight(_ route: PlannedRoute) {
        model.highlightedRouteID = route.id
        let rect = route.route.polyline.boundingMapRect
        withAnimation {
            var fit = rect.insetBy(dx: -rect.width * 0.2, dy: -rect.height * 0.2)
            // The Routes panel covers the map's left edge — grow the rect
            // leftward so the route itself centers in the VISIBLE map area.
            fit.origin.x -= fit.size.width * 0.35
            fit.size.width *= 1.35
            camera = .rect(fit)
        }
    }
}

// MARK: - Shared MapKit fetches (station, plane, and walk-hybrid paths).
// File-scope, capture nothing, safe to run concurrently via `async let`.

/// A real pedestrian route (polyline + steps + ETA), MapKit's one
/// transit-adjacent thing it WILL give apps.
private func transitWalk(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D)
    async -> (MKPolyline?, TimeInterval?, [String], Double?) {
    let req = MKDirections.Request()
    req.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
    req.destination = MKMapItem(placemark: MKPlacemark(coordinate: b))
    req.transportType = .walking
    guard let route = (try? await MKDirections(request: req).calculate())?
        .routes.first else { return (nil, nil, [], nil) }
    let steps = route.steps.map(\.instructions).filter { !$0.isEmpty }
    return (route.polyline, route.expectedTravelTime,
            Array(steps.prefix(6)), route.distance / 1609.344)
}

/// Walk leg only when enabled (an arrival station was found) — the no-car
/// last mile.
private func transitWalkIf(_ enabled: Bool, _ a: CLLocationCoordinate2D,
                           _ b: CLLocationCoordinate2D)
    async -> (MKPolyline?, TimeInterval?, [String], Double?) {
    enabled ? await transitWalk(a, b) : (nil, nil, [], nil)
}

/// Road route between two points: geometry + road miles + real drive time.
/// The ride legs use it as the GROUND corridor (a coach literally drives it;
/// for rail it's a close corridor proxy until GTFS shapes land — beats a
/// straight line that cuts across water/terrain), and the drive time anchors
/// ride estimates to measured road data instead of Apple's opaque `.transit`
/// ETA (which returned near-identical times for bus and rail). The hybrid
/// walk option uses it for the paid-ride segment.
private func transitDrive(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D)
    async -> (MKPolyline?, Double?, TimeInterval?) {
    let req = MKDirections.Request()
    req.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
    req.destination = MKMapItem(placemark: MKPlacemark(coordinate: b))
    req.transportType = .automobile
    guard let route = (try? await MKDirections(request: req).calculate())?
        .routes.first else { return (nil, nil, nil) }
    return (route.polyline, route.distance / 1609.344, route.expectedTravelTime)
}

/// Rental counters near a point — any operator MapKit knows (Hertz,
/// Enterprise, a local independent), keyless like every other POI source.
/// The traveller arrives car-less; three biggest-brand offices with distance
/// + booking link answer "now what?". Transit cards center this on the
/// destination; the plane card centers it on the arrival airport.
private func transitRentals(near dest: CLLocationCoordinate2D)
    async -> [RentalCars.Office] {
    let req = MKLocalSearch.Request()
    req.naturalLanguageQuery = "car rental"
    req.pointOfInterestFilter = MKPointOfInterestFilter(including: [.carRental])
    req.region = MKCoordinateRegion(center: dest,
                                    latitudinalMeters: 30_000,
                                    longitudinalMeters: 30_000)
    let items = (try? await MKLocalSearch(request: req).start())?.mapItems ?? []
    return RentalCars.recommend(items.map { item in
        RentalCars.Office(
            name: item.name ?? "Car rental",
            miles: POIRanking.meters(item.placemark.coordinate, dest) / 1609.344,
            url: item.url ?? RentalCars.bookingURL(name: item.name))
    })
}

private struct RouteCard: View {
    @EnvironmentObject var model: AppModel
    let route: PlannedRoute
    let keyPoints: [(text: String, good: Bool)]
    let fastestETA: TimeInterval
    let isSafest: Bool
    let isCheapest: Bool
    let isEfficient: Bool
    let fuelCostText: String?
    let isHighlighted: Bool
    let onHighlight: () -> Void
    let onGo: () -> Void

    /// Full risk description is collapsed by default so GO stays above the
    /// fold on every card; the strip + key points carry the summary.
    @State private var showDetails = false

    var body: some View {
        // Not a Button: the GO Button nests inside, and nested buttons double-
        // fire on macOS. Tap anywhere else on the card to highlight.
        Group {
            VStack(alignment: .leading, spacing: 6) {
                // Profile chips — the web router's fastest/safest/metro triad.
                HStack(spacing: 5) {
                    if route.isWalkingEstimate { profileChip("Walking est.", .green) }
                    if deltaText == "Fastest" { profileChip("Fastest", Theme.cta) }
                    if isSafest { profileChip("Safest", Theme.riskGreen) }
                    if isCheapest { profileChip("Cheapest", .orange) }
                    if isEfficient { profileChip("Efficient", .mint) }
                    if route.planKind == .avoidHighways { profileChip("Local roads", .blue) }
                    if route.planKind == .tollFree { profileChip("Toll-free", .teal) }
                    Spacer()
                    // ALWAYS-designated trucker pick: high clearance, gentle
                    // grades, low wind, highways + trucker amenities — the
                    // brown truck sits top-right of its card.
                    if model.truckerRouteID == route.id {
                        Image(systemName: "truck.box.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Color.brown)
                            .clipShape(Circle())
                            .help("Best route for trucks: clearance, grades, wind, amenities")
                    }
                    riskBadge
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(etaText)
                        .font(.system(size: 17, weight: .bold))
                    if deltaText != "Fastest" {
                        Text(deltaText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text("\(milesText) · via \(route.via)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if route.hasTolls {
                        Label("Tolls", systemImage: "dollarsign.circle")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    if let fuelCostText {
                        Text(fuelCostText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if route.hasHighways {
                        Image(systemName: "road.lanes")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                // Key points — the at-a-glance pros/cons for this option.
                if !keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(keyPoints.enumerated()), id: \.offset) { _, point in
                            HStack(spacing: 5) {
                                Image(systemName: point.good
                                      ? "checkmark.circle.fill" : "minus.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(point.good ? Theme.riskGreen : Theme.riskYellow)
                                Text(point.text)
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                if route.weatherScored && !route.riskFractions.isEmpty {
                    riskStrip
                }
                if route.weatherScored, showDetails {
                    riskDescription
                }
                HStack {
                    if route.weatherScored {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showDetails.toggle() }
                        } label: {
                            Label(showDetails ? "Hide details" : "Risk details",
                                  systemImage: showDetails ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(isHighlighted ? "Shown on map" : "Tap to view on map")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    // GO is gated on weather scoring: navigation must not start
                    // on a route whose risk is still being computed — the card
                    // shows a progress capsule until hydration lands, so the
                    // sequencing (plan → score → GO) is enforced, not implied.
                    if route.weatherScored {
                        Button("GO", action: onGo)
                            .font(.system(size: 15, weight: .heavy))
                            .buttonStyle(.plain)
                            .frame(width: 72, height: 36)
                            .background(Theme.cta)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Scoring…")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 92, height: 36)
                        .background(Color.black.opacity(0.06))
                        .clipShape(Capsule())
                        .help("GO unlocks when weather risk scoring completes")
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(isHighlighted ? 0.07 : 0.03))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isHighlighted ? Theme.cta : .clear, lineWidth: 2))
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: onHighlight)
    }

    /// Stacked bar: fraction of the corridor in each risk band — "how much
    /// risk area am I accepting" at a glance, mirroring the map's segment
    /// colors.
    private var riskStrip: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(route.riskFractions.enumerated()), id: \.offset) { _, item in
                    Rectangle()
                        .fill(item.band.color.opacity(item.band == .clear ? 0.35 : 0.9))
                        .frame(width: geo.size.width * item.fraction)
                }
            }
        }
        .frame(height: 5)
        .clipShape(Capsule())
    }

    /// The R route summary, under each card (route_pathfind.R
    /// build_route_summary parity): peak/avg risk, exposure miles per band,
    /// the riskiest ZIPs' hazard descriptions, and active alert events.
    @ViewBuilder
    private var riskDescription: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Peak / average in band words — decimals are engineer-speak.
            HStack(spacing: 4) {
                Text("Peaks")
                let peakBand = FlowsCore.riskBand(score: route.peakRisk)
                Text(peakBand.rawValue)
                    .fontWeight(.bold)
                    .foregroundStyle(peakBand == .clear ? Color.secondary : peakBand.color)
                Text("· typically \(FlowsCore.riskBand(score: route.avgRisk).rawValue.lowercased())")
                    .foregroundStyle(.secondary)
            }
            .font(.footnote.weight(.semibold))

            // Physical attributes (verifiable data: USGS grades, OSM
            // clearances, FEMA flood zones) — "checking…" while hydrating.
            Text(attributeLine)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Exposure miles per band — where the risk physically is.
            if !route.milesByBand.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(route.milesByBand.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 3) {
                            Circle().fill(item.band.color).frame(width: 7, height: 7)
                            Text(String(format: "%.0f mi %@", item.miles, item.band.rawValue.lowercased()))
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // The grade TABLE, localized: the three steepest measured
            // segments with their mile positions — honest, inspectable
            // steepness instead of one smoothed number.
            if !route.gradeProfile.isEmpty {
                let steepest = GradeProfile.steepest(route.gradeProfile, top: 3)
                    .filter { abs($0.gradePercent) >= 3 }
                if !steepest.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(steepest.enumerated()), id: \.offset) { _, seg in
                            Text(String(format: "%.1f%% @ mi %.0f",
                                        seg.gradePercent, seg.startMile))
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            // Hazard descriptions of the riskiest ZIPs crossed (the web
            // app's risk_type_summary_text).
            ForEach(route.hazardSummaries, id: \.self) { text in
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // Explicit clearance confirmation on the trucker pick.
            if model.truckerRouteID == route.id, model.routeFilters.contains(.lowBridges) {
                if let cl = route.clearancesMeters {
                    Label(cl.isEmpty
                          ? "Clearance checked: no posted low bridges on this route"
                          : String(format: "Clearance checked: lowest post %.0f'%.0f\" — clears your vehicle",
                                   (cl.min()! / 0.3048).rounded(.down),
                                   ((cl.min()! / 0.3048) - (cl.min()! / 0.3048).rounded(.down)) * 12),
                          systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.riskGreen)
                } else {
                    Label("Clearance check in progress…", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let gap = route.evChargingGapMiles {
                Label(String(format: "No charger found near mile %.0f — verify "
                             + "range before taking this route", gap),
                      systemImage: "bolt.slash.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.riskRed)
            }

            // Active alerts on top of the field.
            if route.alertCoverage > 0 {
                Text(exposureLine)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(badgeColor)
                if !route.alertEvents.isEmpty {
                    Text(route.alertEvents.prefix(3).joined(separator: " · ")
                         + (route.alertEvents.count > 3 ? " · +\(route.alertEvents.count - 3) more" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if route.hazardSummaries.isEmpty {
                // "All clear" must agree with the band bar: a corridor that
                // peaks YELLOW+ with no named hazard is elevated by forecast
                // conditions (rain/wind predictors), not actually clear.
                // A green peak is normal driving weather — don't call it
                // "elevated" (green sits above clear, below yellow).
                Text(route.peakRisk >= FlowsCore.riskYellowMin
                     ? "No active alerts — elevated by forecast conditions along the corridor."
                     : "All clear — no active alerts or elevated conditions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Attributes in the driver's units, marked against THEIR limits when
    /// the matching filter is active — so moving a slider visibly changes
    /// these verdicts (and can exclude the route).
    private var attributeLine: String {
        let limits = model.filterLimits
        var parts: [String] = []
        if let g = route.maxGradePercent {
            let degrees = atan(g / 100) * 180 / .pi
            var text = String(format: "Max grade %.1f° (%.1f%%)", degrees, g)
            if model.routeFilters.contains(.mountainGrades) {
                text += limits.passesGrade(g) ? " ✓" : " ✗ over your limit"
            }
            parts.append(text)
        } else {
            parts.append(route.attributesScored ? "Grade: no data" : "Grade: checking…")
        }
        if let clearances = route.clearancesMeters {
            if let worst = clearances.min() {
                let feet = worst / 0.3048
                var text = String(format: "Lowest clearance %d'%d\"",
                                  Int(feet), Int((feet - Double(Int(feet))) * 12))
                if model.routeFilters.contains(.lowBridges) {
                    text += limits.passesClearances(clearances)
                        ? " ✓" : " ✗ too low for your vehicle"
                }
                parts.append(text)
            } else { parts.append("No posted low clearances") }
        } else if route.clearanceDataUnavailable {
            parts.append("Bridges: no OSM data")
        } else { parts.append("Bridges: checking…") }
        if let weightLimits = route.weightLimitsLbs {
            if let lowest = weightLimits.min() {
                var text = String(format: "Lowest weight sign %.0f lb", lowest)
                // Verdict only when the driver has GIVEN a weight — a ✓
                // against no entered weight would be an empty promise.
                if model.routeFilters.contains(.bridgeWeight), limits.rigWeightLbs != nil {
                    text += limits.passesWeightLimits(weightLimits)
                        ? " ✓" : " ✗ too heavy for this road"
                }
                parts.append(text)
            } else { parts.append("No posted weight limits") }
        } else if !route.clearanceDataUnavailable {
            // Weight limits ride the same Overpass fetch as the clearances —
            // "no OSM data" above already covers the failure case.
            parts.append("Weight limits: checking…")
        }
        if let f = route.femaFloodFraction {
            parts.append(String(format: "FEMA flood %.0f%%", f * 100))
        } else {
            parts.append(route.attributesScored
                         ? "Floodplain: no data" : "Floodplain: checking…")
        }
        return parts.joined(separator: " · ")
    }

    private func profileChip(_ label: String, _ color: Color) -> some View {
        Text(label)
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    /// "34% of route in alert areas (~320 mi)".
    private var exposureLine: String {
        let pct = Int((route.alertCoverage * 100).rounded())
        let miles = route.distanceMeters / 1609.344 * route.alertCoverage
        return "\(pct)% of route in alert areas (~\(Int(miles.rounded())) mi)"
    }

    private var etaText: String {
        let mins = Int((route.eta / 60).rounded())
        if mins >= 48 * 60 {   // multi-day walks read in days, not 260 h
            return String(format: "%.1f days", route.eta / 86_400)
        }
        return mins >= 90 ? String(format: "%d h %02d min", mins / 60, mins % 60) : "\(mins) min"
    }

    private var deltaText: String {
        let delta = Int(((route.eta - fastestETA) / 60).rounded())
        return delta <= 0 ? "Fastest" : "+\(delta) min"
    }

    private var milesText: String {
        String(format: "%.0f mi", route.distanceMeters / 1609.344)
    }

    /// Review finding: this used `color == .blue` as a "clear band" sentinel —
    /// compare the band, not the color it happens to map to.
    private var badgeColor: Color {
        route.riskBand == .clear ? .secondary : route.riskBand.color
    }

    @ViewBuilder
    private var riskBadge: some View {
        if !route.weatherScored {
            // Routes render before their corridor weather has been scored;
            // the badge hydrates in place a few seconds later.
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Weather…")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.06))
            .clipShape(Capsule())
        } else {
            // Labeled so it can't be misread against the peak line: this is
            // the whole-route normalized band, peaks can be worse.
            Text(route.riskBand == .clear ? "No risk overall" : "Overall \(route.riskBand.rawValue)")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(badgeColor.opacity(route.riskBand == .clear ? 0.12 : 0.2))
                .foregroundStyle(route.riskBand == .clear ? .secondary : badgeColor)
                .clipShape(Capsule())
        }
    }
}
