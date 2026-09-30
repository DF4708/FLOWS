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
    @Environment(\.golden) private var golden
    @Binding var camera: MapCameraPosition
    /// Compact stacks this panel across the BOTTOM (the map's top half is
    /// the most valuable space on the screen, and the cards sit near the
    /// thumb); regular puts it down the left side. Decides which way a
    /// framed route is shifted to clear it.
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var panelEdge: CameraZoom.PanelEdge {
        sizeClass == .compact ? .bottom : .leading
    }
    #else
    private let panelEdge = CameraZoom.PanelEdge.leading
    #endif

    private var choices: [PlannedRoute] { model.filteredChoices }

    // Transit toggles, option cards, in-flight tasks, and the walk+ride offer
    // all live on AppModel (TransitMode/TransitOption/HybridOption in Core) —
    // a rotation's size-class flip rebuilds this view and would have wiped
    // view-local @State mid-choice. present(routes:) clears them per plan.

    private func replanForMode() async {
        guard let ep = model.lastPlanEndpointsPublic else { return }
        // A drive replan supersedes any in-flight transit calc; present()
        // below clears the option cards and walk+ride offer too.
        model.transitTasks.values.forEach { $0.cancel() }
        model.transitTasks = [:]
        if let planned = try? await model.plan(from: ep.from, fromName: ep.fromName,
                                               to: ep.to, toName: ep.toName) {
            // The same trip on foot or by car, so the train, bus, plane and
            // rental toggles stay on: "walk, bus and plane" is one choice
            // whichever order it was made in, and present() — built for a
            // new destination — turned them all off when Walk came last.
            let chosen = model.activeTransitModes
            model.present(routes: planned)
            // (Behind a trip being driven, present() leaves the transit state
            // to that trip, and so does this.)
            guard model.mode == .choosing else { return }
            model.activeTransitModes = chosen
        }
        // Read them again for the new way of travel (TripShape): a walker
        // rides the bus to the station where a driver drove.
        guard model.mode == .choosing else { return }
        reshapeTransit()
    }

    // MARK: - The selection as one trip

    /// The toggles as ONE trip. Any change to them changes the trip — "car
    /// and train" drives to the station and walks at the far end; add the bus
    /// and the far end is the city bus — so every change cancels what was
    /// computing and starts again from `TripShape`.
    private func reshapeTransit() {
        model.transitTasks.values.forEach { $0.cancel() }
        model.transitTasks = [:]
        model.transitOptions = [:]
        model.roadChosenOverTransit = false
        if model.transitItinerary?.mode != "Walk + ride" { model.transitItinerary = nil }
        guard !model.activeTransitModes.isEmpty, let shape = currentShape() else { return }
        launchCards(shape, active: model.activeTransitModes)
    }

    /// Draw a card's trip on the map as it computes — unless the rider has
    /// since tapped a road to look at it: the map hides the roads under a
    /// transit trip, so a timetable answering later took their road away.
    private func draw(_ itinerary: TransitItinerary) {
        if !model.roadChosenOverTransit { model.transitItinerary = itinerary }
    }

    /// The trip the toggles describe right now (or `modes`, when given).
    private func currentShape(_ modes: Set<TransitMode>? = nil) -> TripShape? {
        guard let ep = model.lastPlanEndpointsPublic else { return nil }
        return TripShape(onFoot: model.walkingMode, modes: modes ?? model.activeTransitModes,
                         tripMiles: POIRanking.meters(ep.from, ep.to) / 1609.344)
    }

    /// Start computing every card `shape` calls for. Each card is keyed by
    /// the mode it leads with; a toggle folded into another card's trip (the
    /// bus to the airport) has no card of its own.
    private func launchCards(_ shape: TripShape, active: Set<TransitMode>) {
        if shape.shows(TripShape.cardMain), let key = shape.mainMode {
            model.transitTasks[key] = Task {
                switch shape.main {
                case .plane:
                    // No flight fits (no airport with airline service near
                    // one end): the ground toggles still make a trip.
                    let flew = await computeAirTransit(shape)
                    if !flew { groundInstead(of: active) }
                case .train: await computeGroundTransit(rail: true, shape: shape)
                case .coach: await computeGroundTransit(rail: false, shape: shape)
                case .short: break
                }
            }
        }
        if shape.shows(TripShape.cardLocal) {
            let key = TripShape.localMode(active)
            model.transitTasks[key] = Task { await computeCityTrip(key, shape: shape) }
        }
        if shape.shows(TripShape.cardRental) {
            model.transitTasks[.rental] = Task { await computeRentalTrip(shape) }
        }
        if shape.shows(TripShape.cardPlaneNote) {
            model.transitTasks[.plane] = Task { _ = await computeAirTransit(nil) }
        }
    }

    /// The plane was the main ride but no flight fits: plan the rest of the
    /// selection without it, and leave the plane card to say why.
    private func groundInstead(of active: Set<TransitMode>) {
        if Task.isCancelled { return }
        let rest = active.subtracting([.plane])
        guard !rest.isEmpty, let shape = currentShape(rest) else { return }
        launchCards(shape, active: rest)
    }

    /// The way to the main ride as the card first shows it — no timetable
    /// needed. Walk when the stop is close; past a long walk, drive and park
    /// (own car) or take a ride share (on foot). The city's buses and trains
    /// come after, in `cityPart`, once their timetable answers.
    private func accessPart(
        _ shape: TripShape, from start: CLLocationCoordinate2D, startName: String,
        to stop: CLLocationCoordinate2D, stopName: String, place: String,
        walk: WalkResult, parkNote: String
    ) async -> TripPart {
        let walkLeg = TransitLeg(kind: .walk, fromName: startName, toName: stopName,
                                 seconds: walk.seconds, miles: walk.miles,
                                 polyline: walk.polyline, steps: walk.steps)
        guard (walk.seconds ?? .infinity) > TripShape.farWalkSeconds else {
            return TripPart(legs: [walkLeg], seconds: walk.seconds)
        }
        // A driver HAS a car at the start: "walk 5 h 14 m to the terminal"
        // buried a 90-minute trip inside a 6-hour total.
        if shape.access == .ownCar {
            let (poly, miles, seconds) = await transitDrive(start, stop)
            if let seconds {
                return TripPart(legs: [TransitLeg(
                    kind: .drive, fromName: startName, toName: stopName,
                    seconds: seconds, miles: miles, polyline: poly,
                    steps: ["Drive to \(stopName)", "Park at or near the \(place)", parkNote])],
                    seconds: seconds)
            }
            return TripPart(legs: [walkLeg], seconds: walk.seconds)
        }
        // On foot: never park-and-ride. Uber/Lyft links need no account
        // keys; they open with the pickup and drop-off filled in.
        return TripPart(legs: [TransitLeg(
            kind: .walk, fromName: startName, toName: stopName,
            seconds: walk.seconds, miles: walk.miles, polyline: walk.polyline,
            steps: ["The \(place) is a long walk (\(TransitPlanning.fmt(walk.seconds)))",
                    "A ride share can cover this first leg:",
                    "Uber: m.uber.com — set drop-off to \(stopName)",
                    "Lyft: lyft.com/ride — set drop-off to \(stopName)"])],
            seconds: walk.seconds)
    }

    /// The way from the main ride as the card first shows it. `.local` is
    /// never passed here — it waits on the city's timetable (`cityPart`) and
    /// shows its fallback until then.
    private func egressPart(
        _ egress: TripShape.Egress, from stop: CLLocationCoordinate2D, stopName: String,
        stationFound: Bool, to dest: CLLocationCoordinate2D, destName: String,
        walk: WalkResult
    ) async -> TripPart {
        switch egress {
        case .rental:
            // The rider asked for a car at the far end: pick it up where the
            // train, bus or plane gets in, and drive the rest.
            let (poly, miles, seconds) = await transitDrive(stop, dest)
            return TripPart(legs: [TransitLeg(
                kind: .drive, fromName: stopName, toName: destName,
                seconds: seconds, miles: miles, polyline: poly,
                steps: ["Pick up a rental car at \(stopName)",
                        "Drive to \(destName)",
                        "Compare prices and book below"],
                rental: true)], seconds: seconds)
        case .rentOrRide:
            // From an airport: walk when it is a real walk; otherwise an
            // honest ride-share or rent-or-ride leg.
            if let seconds = walk.seconds, seconds <= TripShape.farWalkSeconds {
                return TripPart(legs: [TransitLeg(
                    kind: .walk, fromName: stopName, toName: destName,
                    seconds: seconds, miles: walk.miles, polyline: walk.polyline,
                    steps: walk.steps.isEmpty ? ["Walk from \(stopName) to \(destName)"]
                                              : walk.steps)], seconds: seconds)
            }
            if model.walkingMode {
                return TripPart(legs: [TransitLeg(
                    kind: .walk, fromName: stopName, toName: destName,
                    seconds: walk.seconds, miles: walk.miles, polyline: walk.polyline,
                    steps: ["\(destName) is a long way from \(stopName)",
                            "A ride share can cover this last leg:",
                            "Uber: m.uber.com — set drop-off to \(destName)",
                            "Lyft: lyft.com/ride — set drop-off to \(destName)"])],
                    seconds: walk.seconds)
            }
            let (poly, miles, seconds) = await transitDrive(stop, dest)
            return TripPart(legs: [TransitLeg(
                kind: .drive, fromName: stopName, toName: destName,
                seconds: seconds, miles: miles, polyline: poly,
                steps: ["Rent a car or get a ride at \(stopName)",
                        "Go to \(destName) — rental counters listed below"])],
                seconds: seconds)
        case .walk, .local:
            // The rider rode transit, so the last mile is never a drive. With
            // a real arrival station it is routed exactly; without one it
            // still ends on foot and says to plan the last mile.
            let steps: [String] = stationFound
                ? (walk.steps.isEmpty ? ["Walk from \(stopName) to \(destName)"] : walk.steps)
                : ["Continue to \(destName) on foot — plan the last mile locally"]
            return TripPart(legs: [TransitLeg(
                kind: .walk, fromName: stopName, toName: destName,
                seconds: walk.seconds, miles: walk.miles, polyline: walk.polyline,
                steps: steps)], seconds: walk.seconds)
        }
    }

    /// The city's trip for one leg on the vehicles the rider chose — or on
    /// any of the city's vehicles when none of the chosen ones makes the trip,
    /// or another gets there fifteen minutes sooner, with a line saying so.
    /// "Walk, bus and plane" means the city's transit to the airport; where
    /// the airport's link is a train (Minneapolis), buses alone went by way
    /// of St. Paul.
    private func bestCityTrip(
        _ shape: TripShape, from start: CLLocationCoordinate2D, fromName: String,
        to end: CLLocationCoordinate2D, toName: String, departing: Date
    ) async -> (trip: CityTrip, note: String?)? {
        let mayFetch = model.mode != .navigating
        let chosen = await cityTrip(from: start, fromName: fromName, to: end, toName: toName,
                                    departing: departing, vehicles: shape.localVehicles,
                                    mayFetch: mayFetch)
        guard let word = shape.cityChoice, shape.localVehicles != TripShape.allVehicles,
              !Task.isCancelled,
              let any = await cityTrip(from: start, fromName: fromName, to: end, toName: toName,
                                       departing: departing, vehicles: TripShape.allVehicles,
                                       mayFetch: mayFetch),
              TripShape.otherVehicleWins(chosenSeconds: chosen?.seconds,
                                         otherSeconds: any.seconds)
        else { return chosen.map { ($0, nil) } }
        let other = word == "bus" ? "train" : "bus"
        let note = chosen == nil
            ? "No city \(word) makes this part of the trip, so it rides the city's \(other)."
            : "The city's \(other) is much quicker here than any \(word), so this part rides it."
        return (any, note)
    }

    /// The city's buses and trains for one leg — to the station or airport,
    /// or from it — when they get there at least five minutes sooner than
    /// walking. Nil when the city has no timetable FLOWS can read, no ride
    /// fits, or walking is as good.
    private func cityPart(
        _ shape: TripShape, from start: CLLocationCoordinate2D, fromName: String,
        to end: CLLocationCoordinate2D, toName: String,
        departing: Date, walkSeconds: TimeInterval?
    ) async -> TripPart? {
        guard let best = await bestCityTrip(shape, from: start, fromName: fromName,
                                            to: end, toName: toName, departing: departing),
              TripShape.transitBeatsWalk(walkSeconds: walkSeconds,
                                         transitSeconds: best.trip.seconds)
        else { return nil }
        return TripPart(legs: best.trip.legs, schedule: best.trip.schedule,
                        seconds: best.trip.seconds, note: best.note)
    }

    /// What city rides cost on top of the main fare: the usual local fare for
    /// each bus or train boarded.
    private func cityFare(_ legs: [TransitLeg]) -> Double {
        legs.filter { $0.kind == .ride && $0.local }.reduce(0) {
            $0 + ($1.vehicle == "Bus" ? TransitFares.localBus() : TransitFares.localRail())
        }
    }

    /// Rail/bus main ride: the way to the boarding station, the ride (transit
    /// ETA scaled from the drive, fare DISCLOSED as an estimate — Amtrak's
    /// real times replace the estimate when its timetable answers), and the
    /// way from the arrival station. Long trips route to Amtrak (rail) /
    /// Greyhound (bus); short ones are the city's own trains and buses.
    ///
    /// The shape says how the ends go: "car, bus and train" drives to the
    /// station and takes the city bus from the far one; a rental car toggle
    /// picks a car up where the train gets in. The card shows at once with
    /// what is quick to know — a walk, a drive, a rental — and then again as
    /// the city's and Amtrak's timetables answer.
    private func computeGroundTransit(rail: Bool, shape: TripShape) async {
        let tMode: TransitMode = rail ? .rail : .bus
        guard let ep = model.lastPlanEndpointsPublic else { return }
        let miles = POIRanking.meters(ep.from, ep.to) / 1609.344
        let longHaul = miles > TripShape.longHaulMiles
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
            // Before declaring there is no service, ASK THE TIMETABLE. The
            // bundled list is rail-served stations only, so the 110 towns
            // Amtrak reaches by connecting coach — Bakersfield, Eureka,
            // Arcata — look unserved to a map search and are not. Bakersfield
            // has 400,000 people and a daily coach to a Surfliner.
            if rail, longHaul,
               let train = await publishedTrain(from: ep.from, to: ep.to, departing: Date()) {
                if Task.isCancelled { return }
                model.transitOptions[tMode] = TransitOption(
                    title: "Train via \(train.schedule.boardName)",
                    detail: "Amtrak serves \(train.schedule.boardName). FLOWS can't draw the way to "
                            + "the stop from here, so check locally how to reach it.",
                    fare: 0,
                    destination: MKMapItem(placemark: MKPlacemark(coordinate: ep.to)),
                    schedule: train.schedule)
                return
            }
            // Still nothing scheduled → be useful anyway: the bundled list
            // names the CLOSEST Amtrak station within intercity range, offline.
            var detail = "No station within range of the start point."
            if rail, let nearest = AmtrakStations.nearest(to: ep.from, within: 240_000) {
                let mi = POIRanking.meters(nearest.coordinate, ep.from) / 1609.344
                detail = String(format: "No rail close by. Closest train: %@, %.0f mi away — drive there or take the bus option.",
                                nearest.name, mi)
            }
            model.transitOptions[tMode] = TransitOption(
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
        // Rentals at the ARRIVAL STATION, not at the trip's destination: the
        // traveller steps off the train there and the miles they read are
        // the walk to the counter. Measured from the same point, so a "0.3
        // mi" office is 0.3 mi from the platform. (The plane card already
        // searched around its arrival airport.)
        async let rentalsNearDest = transitRentals(near: alightC)
        let walkIn = await w1
        let (ridePolyOpt, rideRoadMi, driveSec) = await rideG
        let walkOut = await w3

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
        let rideLeg: TransitLeg? = hasRide
            ? TransitLeg(kind: .ride, fromName: boardName, toName: alightName,
                         seconds: rideSec, miles: rideMi, polyline: ridePoly,
                         steps: TransitPlanning.rideSteps(mode: kind, board: boardName,
                                                          alight: alightName, seconds: rideSec))
            : nil
        // Fare from the RIDE distance (road miles board→alight), matching the
        // drawn geometry and the time — not the great-circle endpoint span. No
        // ride (walk-only collapse) → no fare, so no phantom minimum shows.
        let mainFare = hasRide
            ? (longHaul ? (rail ? TransitFares.amtrak(miles: rideMi)
                                : TransitFares.greyhound(miles: rideMi))
                        : (rail ? TransitFares.localRail() : TransitFares.localBus()))
            : 0
        let dest = MKMapItem(placemark: MKPlacemark(coordinate: ep.to))
        // The EXACT ticket to buy for this ride, listed on the card.
        var ticketLabel: String?
        var ticketURL: URL?
        if hasRide {
            let t = TransitTickets.ticket(mode: kind, board: boardName,
                                          alight: alightName, stationURL: board.url)
            ticketLabel = t.label
            ticketURL = t.url
        }
        var rentals = await rentalsNearDest
        // Where the traveller gets off, not where they set out from: that is
        // where they would pick a car up. No arrival station means the
        // destination itself.
        var compare = RentalCars.compareURL(near: alight?.placemark.coordinate ?? ep.to)

        /// Put the trip on its card — once with what is quick to know, then
        /// again as the timetables answer. `offName` is where the ride ends:
        /// the map's station at first, the timetable's once it answers;
        /// `offKnown` says it is a real station the last leg starts from.
        func publish(_ access: TripPart, _ egress: TripPart, train: TransitSchedule?,
                     offName: String, offKnown: Bool) {
            // Once the timetable answers, the ride takes the train's own time,
            // not the estimate scaled from the drive.
            let ride: TransitLeg? = rideLeg.map { leg in
                let seconds = train.map(\.rideSeconds).flatMap { $0 > 0 ? $0 : nil }
                guard seconds != nil || offName != leg.toName else { return leg }
                return TransitLeg(
                    kind: .ride, fromName: leg.fromName, toName: offName,
                    seconds: seconds ?? leg.seconds, miles: leg.miles, polyline: leg.polyline,
                    steps: TransitPlanning.rideSteps(mode: kind, board: boardName,
                                                     alight: offName,
                                                     seconds: seconds ?? leg.seconds))
            }
            let legs = access.legs + (ride.map { [$0] } ?? []) + egress.legs
            let fare = mainFare + cityFare(legs)
            // One timetable door to door: the city ride to the station, the
            // train, the city ride from it — shown only once the train's own
            // times are known, so the clock is the trip's.
            let schedule = train.flatMap {
                TransitSchedule.joined([access.schedule, $0, egress.schedule].compactMap { $0 })
            }
            var itinerary = TransitItinerary(
                mode: kind, legs: legs, fare: fare, mapsDestination: dest,
                rideGeometryIsApproximate: hasRide,
                rideGeometryIsReal: ridePolyOpt != nil)
            // A city part's own first (or last) leg is the walk to (or from)
            // its stop; the rest of it is inside the timetable's span.
            itinerary.doorToDoorSeconds = TransitItinerary.doorToDoor(
                before: access.schedule != nil ? access.legs.first?.seconds : access.seconds,
                schedule: schedule,
                after: egress.schedule != nil ? egress.legs.last?.seconds : egress.seconds)
            draw(itinerary)   // latest computed draws on the map
            let accessVerb = access.legs.contains { $0.local } ? "City bus or train"
                : access.legs.first?.kind == .drive ? "Drive" : "Walk"
            let tail = egress.legs.contains { $0.rental } ? " · then a rental car from \(offName)"
                : egress.legs.contains { $0.local } ? " · then the city bus or train from \(offName)"
                : offKnown ? " · then walk \(TransitPlanning.fmt(egress.seconds)) from \(offName)"
                : " · no arrival station found — plan the last mile at \(destName)"
            // The ride as the legs show it: the timetable's time once known.
            let rideShown = ride?.seconds ?? rideSec
            model.transitOptions[tMode] = TransitOption(
                title: "\(kind) via \(boardName)",
                detail: "\(accessVerb) \(TransitPlanning.fmt(access.seconds)) to \(boardName) · "
                        + "\(kind.lowercased()) ride \(TransitPlanning.fmt(rideShown))\(tail) · est. fare "
                        + String(format: "$%.2f (carriers set final pricing).", fare),
                fare: fare, destination: dest,
                ticketLabel: ticketLabel, ticketURL: ticketURL,
                itinerary: itinerary,
                schedule: schedule,
                rentals: rentals,
                rentalCompareURL: compare,
                notes: [access.note, egress.note].compactMap { $0 })
        }

        // At once: the walk or drive to the station, and the rental car or the
        // walk at the far end.
        let quickAccess = await accessPart(
            shape, from: ep.from, startName: startName, to: boardC, stopName: boardName,
            place: "station", walk: walkIn, parkNote: TransitPlanning.farEndNote(shape.egress))
        let quickEgress = await egressPart(
            shape.egress == .local ? shape.egressFallback : shape.egress,
            from: alightC, stopName: alightName, stationFound: alight != nil,
            to: ep.to, destName: destName, walk: walkOut)
        if Task.isCancelled { return }
        publish(quickAccess, quickEgress, train: nil, offName: alightName, offKnown: alight != nil)

        // Then the timetables. Deliberately AFTER the card is up: reading one
        // may mean a download, and no one should watch a spinner to find out
        // a train exists.
        var access = quickAccess
        if shape.access == .local,
           let city = await cityPart(shape, from: ep.from, fromName: startName, to: boardC,
                                     toName: boardName, departing: Date(),
                                     walkSeconds: walkIn.seconds) {
            access = city
        }
        if Task.isCancelled { return }
        // Amtrak's real times, asked from the station the rider is going to,
        // for when they get there — a drive of 40 minutes is not a 7-hour
        // walk, which is what asking from the start charged it.
        var train: PublishedTrain?
        if rail, longHaul, hasRide {
            train = await publishedTrain(
                from: boardC, to: ep.to,
                departing: Date().addingTimeInterval(access.seconds ?? 0))
        }
        if Task.isCancelled { return }
        // The station the train really stops at, when its timetable says —
        // not always the one the map picked: for the towns Amtrak reaches by
        // connecting coach, the timetable's stop is elsewhere, and the card
        // walked the rider from a station the schedule never mentioned.
        var egress = quickEgress
        var offName = alightName
        var offKnown = alight != nil
        var walk = walkOut
        var offAt = alightC
        if let train, let at = train.alightCoordinate, POIRanking.meters(at, alightC) > 200 {
            offAt = at
            offName = train.alightName
            offKnown = true
            walk = await transitWalk(at, ep.to)
            egress = await egressPart(
                shape.egress == .local ? shape.egressFallback : shape.egress,
                from: at, stopName: offName, stationFound: true,
                to: ep.to, destName: destName, walk: walk)
            rentals = await transitRentals(near: at)
            compare = RentalCars.compareURL(near: at)
        }
        if shape.egress == .local {
            // From there, when it really gets in; the estimate stands in when
            // there is no timetable.
            let arriving = train?.arrive
                ?? Date().addingTimeInterval((access.seconds ?? 0) + (hasRide ? rideSec : 0))
            if let city = await cityPart(shape, from: offAt, fromName: offName, to: ep.to,
                                         toName: destName, departing: arriving,
                                         walkSeconds: walk.seconds) {
                egress = city
            }
        }
        if Task.isCancelled { return }
        if train != nil || access.schedule != nil || egress.schedule != nil {
            publish(access, egress, train: train?.schedule, offName: offName, offKnown: offKnown)
        }
    }

    /// Amtrak's own answer for a train leaving near `from` for near `to`
    /// after `departing`: its times, and where and when it really gets in.
    private struct PublishedTrain {
        let schedule: TransitSchedule
        let alightName: String
        let alightCoordinate: CLLocationCoordinate2D?
        let arrive: Date?
    }

    /// What Amtrak's timetable says, if anything. Anything missing — no
    /// timetable, no service today, no station near either end — is nil,
    /// because an honest estimate beats a blank where a time should be.
    private func publishedTrain(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
                                departing: Date) async -> PublishedTrain? {
        // A driver's connection belongs to the road ahead, not to a schedule
        // refresh; mid-drive we use a timetable only if one is already here.
        let mayFetch = model.mode != .navigating
        guard let ready = try? await TransitFeeds.shared.ready(
                TransitFeeds.amtrak, on: departing, allowNetwork: mayFetch),
              let answer = try? TransitShard.departures(
                prefix: ready.prefix, from: from, to: to,
                departing: departing, stamp: ready.stamp),
              let schedule = TransitShard.schedule(
                from: answer, credit: ready.credit, operators: ready.operators),
              let first = answer.departures.first, let last = first.rides.last
        else { return nil }
        return PublishedTrain(
            schedule: schedule, alightName: last.alightName,
            alightCoordinate: last.alightCoordinate,
            arrive: TransitShard.moment(first.arriveSeconds, answer.stamp))
    }

    /// A short trip on the city's own buses and trains, door to door, read
    /// from the city's timetable and held to the vehicles the rider chose.
    /// With no timetable to read, the estimate cards FLOWS always made stand
    /// in for it.
    private func computeCityTrip(_ key: TransitMode, shape: TripShape) async {
        guard let ep = model.lastPlanEndpointsPublic else { return }
        let dest = MKMapItem(placemark: MKPlacemark(coordinate: ep.to))
        let startName = ep.fromName.isEmpty ? "your start" : ep.fromName
        let destName = ep.toName.isEmpty ? "your destination" : ep.toName
        model.transitOptions[key] = TransitOption(
            title: "City bus and train",
            detail: "Looking up the city's own bus and train times…",
            fare: 0, destination: dest)
        guard let best = await bestCityTrip(
            shape, from: ep.from, fromName: startName, to: ep.to, toName: destName,
            departing: Date())
        else {
            if Task.isCancelled { return }
            model.transitOptions[key] = nil
            let chosen = model.activeTransitModes
            if chosen.contains(.rail) { await computeGroundTransit(rail: true, shape: shape) }
            if chosen.contains(.bus) { await computeGroundTransit(rail: false, shape: shape) }
            return
        }
        if Task.isCancelled { return }
        let (trip, note) = (best.trip, best.note)
        let fare = cityFare(trip.legs)
        var vehicles: [String] = []
        for leg in trip.legs where leg.local {
            if let word = leg.vehicle, !vehicles.contains(word) { vehicles.append(word) }
        }
        var itinerary = TransitItinerary(
            mode: "City", legs: trip.legs, fare: fare, mapsDestination: dest,
            rideGeometryIsApproximate: true, rideGeometryIsReal: false)
        itinerary.doorToDoorSeconds = TransitItinerary.doorToDoor(
            before: trip.legs.first?.seconds, schedule: trip.schedule,
            after: trip.legs.last?.seconds)
        draw(itinerary)
        let what = vehicles.isEmpty ? "Bus" : vehicles.joined(separator: " + ")
        model.transitOptions[key] = TransitOption(
            title: "\(what) from \(trip.schedule.boardName)",
            detail: "\(trip.schedule.clockSpan) · "
                    + String(format: "est. fare $%.2f (the city sets the price).", fare),
            fare: fare, destination: dest,
            itinerary: itinerary, schedule: trip.schedule,
            notes: note.map { [$0] } ?? [])
    }

    /// A rental car picked up near the start and driven the whole way — the
    /// rental toggle on a trip with no train, bus or plane for it to meet.
    private func computeRentalTrip(_ shape: TripShape) async {
        guard let ep = model.lastPlanEndpointsPublic else { return }
        let dest = MKMapItem(placemark: MKPlacemark(coordinate: ep.to))
        let startName = ep.fromName.isEmpty ? "your start" : ep.fromName
        let destName = ep.toName.isEmpty ? "your destination" : ep.toName
        let compare = RentalCars.compareURL(near: ep.from)
        let offices = await transitRentals(near: ep.from)
        if Task.isCancelled { return }
        // The nearest counter of the brands worth showing is the one to walk
        // to; the rest stay listed with their miles.
        guard let office = offices.filter({ $0.coordinate != nil })
                .min(by: { $0.miles < $1.miles }),
              let officeC = office.coordinate else {
            model.transitOptions[.rental] = TransitOption(
                title: "Rent a car",
                detail: "FLOWS found no rental counter near \(startName). "
                        + "Compare prices near there below.",
                fare: 0, destination: dest, rentals: [], rentalCompareURL: compare)
            return
        }
        async let walkTask = transitWalk(ep.from, officeC)
        async let driveTask = transitDrive(officeC, ep.to)
        let access = await accessPart(
            shape, from: ep.from, startName: startName, to: officeC, stopName: office.name,
            place: "rental counter", walk: await walkTask,
            parkNote: "Your car stays here while you have the rental")
        let (poly, miles, seconds) = await driveTask
        if Task.isCancelled { return }
        let legs = access.legs + [TransitLeg(
            kind: .drive, fromName: office.name, toName: destName,
            seconds: seconds, miles: miles, polyline: poly,
            steps: ["Pick up a rental car at \(office.name)",
                    "Drive to \(destName)",
                    "Compare prices and book below"],
            rental: true)]
        let itinerary = TransitItinerary(
            mode: "Rental car", legs: legs, fare: 0, mapsDestination: dest,
            rideGeometryIsApproximate: false)
        draw(itinerary)
        model.transitOptions[.rental] = TransitOption(
            title: "Rental car from \(office.name)",
            detail: "\(access.legs.first?.kind == .drive ? "Drive" : "Walk") "
                    + "\(TransitPlanning.fmt(access.seconds)) to \(office.name) · "
                    + "drive \(TransitPlanning.fmt(seconds)) to \(destName).",
            fare: 0, destination: dest,
            itinerary: itinerary, rentals: offices, rentalCompareURL: compare)
    }

    /// Plane main ride: board at the nearest airport with airline service to
    /// the start, land at the nearest to the destination. Airport time
    /// (arrive early, bags) is INSIDE the leg time so the total is honest; the
    /// fare line says plainly that airlines set prices. The flight draws as a
    /// geodesic arc — planes don't follow roads.
    ///
    /// `shape` says how the ends go — "walk, bus and plane" rides the city bus
    /// to the airport and from it; a rental toggle picks a car up where the
    /// plane lands. Nil for a plane toggled onto a trip too short to fly,
    /// whose card only says so. Returns whether a flight card was made, so a
    /// trip with no airport in reach can be planned on the ground instead.
    private func computeAirTransit(_ shape: TripShape?) async -> Bool {
        guard let ep = model.lastPlanEndpointsPublic else { return false }
        let tripMiles = POIRanking.meters(ep.from, ep.to) / 1609.344
        let dest = MKMapItem(placemark: MKPlacemark(coordinate: ep.to))
        guard AirTravel.worthFlying(tripMiles: tripMiles) else {
            if Task.isCancelled { return false }
            model.transitOptions[.plane] = TransitOption(
                title: "Flying won't help here",
                detail: String(format: "This trip is about %.0f miles. With "
                               + "airport time added, a flight only beats the "
                               + "road past %.0f miles.",
                               tripMiles, AirTravel.minTripMiles),
                fare: 0, destination: dest)
            return false
        }
        let shape = shape ?? TripShape(onFoot: model.walkingMode, modes: [.plane],
                                       tripMiles: tripMiles)
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
        // The airports FLOWS carries answer first: the table knows which
        // fields airlines actually serve, it cannot be throttled, and it
        // works with no signal. A map search only fills in for a place the
        // table has never heard of.
        let ends = AirTravel.flightEnds(from: ep.from, to: ep.to)
        var boardC = ends?.board.coordinate
        var alightC = ends?.alight.coordinate
        var boardLabel = ends?.board.label
        var alightLabel = ends?.alight.label
        var boardItem: MKMapItem?
        if ends == nil {
            async let boardTask = airport(near: ep.from)
            async let alightTask = airport(near: ep.to)
            let (boardOpt, alightOpt) = await (boardTask, alightTask)
            if Task.isCancelled { return false }
            boardC = boardOpt?.placemark.coordinate
            alightC = alightOpt?.placemark.coordinate
            boardLabel = boardOpt?.name
            alightLabel = alightOpt?.name
            boardItem = boardOpt
        }
        if Task.isCancelled { return false }
        guard let boardC, let alightC,
              POIRanking.meters(boardC, alightC) / 1609.344
                  >= AirTravel.minAirportGapMiles else {
            let nothingNear = boardC == nil || alightC == nil
            model.transitOptions[.plane] = TransitOption(
                title: "No flight fits this trip",
                detail: nothingNear
                    ? "No airport with airline service is within "
                        + "\(Int((AirTravel.maxDriveMeters / 1609.344).rounded())) miles of one "
                        + "end of the trip."
                    : "Both ends of the trip use the same nearby airport — flying can't shorten it.",
                fare: 0, destination: dest)
            return false
        }
        let boardName = boardLabel ?? "the departure airport"
        let alightName = alightLabel ?? "the arrival airport"
        let startName = ep.fromName.isEmpty ? "your start" : ep.fromName
        let destName = ep.toName.isEmpty ? "your destination" : ep.toName
        let airportMiles = POIRanking.meters(boardC, alightC) / 1609.344

        // Airport access, the last mile, and rentals at the ARRIVAL airport
        // (the flyer lands car-less — same reuse as the train cards), all
        // independent, all concurrent.
        async let w1 = transitWalk(ep.from, boardC)
        async let w3 = transitWalk(alightC, ep.to)
        async let rentalsAtAirport = transitRentals(near: alightC)
        let walkIn = await w1
        let walkOut = await w3

        var arcPoints = [boardC, alightC]
        let arc = MKGeodesicPolyline(coordinates: &arcPoints, count: 2)
        let flySec = AirTravel.doorSeconds(airportMiles: airportMiles)
        let flyLeg = TransitLeg(kind: .ride, fromName: boardName, toName: alightName,
                                seconds: flySec, miles: airportMiles, polyline: arc,
                                steps: AirTravel.flightSteps(board: boardName,
                                                             alight: alightName,
                                                             airportMiles: airportMiles))
        // What people actually pay for a flight this long (US DOT), not the
        // old ballpark that read 2–3× cheap beside a drive's fuel cost.
        let flightFare = AirTravel.typicalFare(airportMiles: airportMiles)
        let ticket = AirTravel.ticket(board: boardName, alight: alightName,
                                      boardCode: ends?.board.code,
                                      alightCode: ends?.alight.code,
                                      airportURL: boardItem?.url)
        let rentals = await rentalsAtAirport
        // The airport the flight lands at — its own rental page when
        // DiscoverCars lists it ("…/chicago/ord"), else the best page near it.
        let compare = ends.map {
            RentalCars.compareURL(airport: $0.alight.code, at: $0.alight.coordinate)
        } ?? RentalCars.compareURL

        func publish(_ access: TripPart, _ egress: TripPart) {
            let legs = access.legs + [flyLeg] + egress.legs
            let fare = flightFare + cityFare(legs)
            let itinerary = TransitItinerary(
                mode: "Plane", legs: legs, fare: fare, mapsDestination: dest,
                rideGeometryIsApproximate: true)
            draw(itinerary)
            let accessVerb = access.legs.contains { $0.local } ? "City bus or train"
                : access.legs.first?.kind == .drive ? "Drive" : "Walk"
            model.transitOptions[.plane] = TransitOption(
                title: "Plane via \(boardName)",
                detail: "\(accessVerb) \(TransitPlanning.fmt(access.seconds)) to \(boardName) · "
                        + "flight \(TransitPlanning.fmt(flySec)) counting airport time · "
                        + String(format: "about $%.0f, the usual fare for this far — "
                                 + "airlines set the real price.", fare),
                fare: fare, destination: dest,
                ticketLabel: ticket.label, ticketURL: ticket.url,
                itinerary: itinerary,
                rentals: rentals,
                rentalCompareURL: compare,
                notes: [access.note, egress.note].compactMap { $0 })
        }

        let quickAccess = await accessPart(
            shape, from: ep.from, startName: startName, to: boardC, stopName: boardName,
            place: "airport", walk: walkIn, parkNote: TransitPlanning.farEndNote(shape.egress))
        let quickEgress = await egressPart(
            shape.egress == .local ? shape.egressFallback : shape.egress,
            from: alightC, stopName: alightName, stationFound: true,
            to: ep.to, destName: destName, walk: walkOut)
        if Task.isCancelled { return false }
        publish(quickAccess, quickEgress)

        // Then the city's buses and trains, to the airport and from it, once
        // their timetables answer.
        var access = quickAccess
        if shape.access == .local,
           let city = await cityPart(shape, from: ep.from, fromName: startName, to: boardC,
                                     toName: boardName, departing: Date(),
                                     walkSeconds: walkIn.seconds) {
            access = city
        }
        if Task.isCancelled { return true }
        var egress = quickEgress
        if shape.egress == .local {
            let landed = Date().addingTimeInterval((access.seconds ?? 0) + flySec)
            if let city = await cityPart(shape, from: alightC, fromName: alightName, to: ep.to,
                                         toName: destName, departing: landed,
                                         walkSeconds: walkOut.seconds) {
                egress = city
            }
        }
        if Task.isCancelled { return true }
        if access.schedule != nil || egress.schedule != nil {
            publish(access, egress)
        }
        return true
    }

    // MARK: - Walk + paid ride (walking mode)

    /// Walking mode's "best time for the money" option: a paid ride segment,
    /// offered ONLY when it clears HybridWalk's significance bar (>= 40% and
    /// >= 15 min saved, <= $25 est.). Whole-trip ride when the cap affords
    /// it; otherwise ride the first affordable miles from the start and walk
    /// the rest — with the walk remainder re-routed for real and the bar
    /// re-checked before anything is offered.
    private func computeHybrid(key: String) async {
        // Same plan as the last computation (or a dismissal): keep what's
        // there. Without this, the rotation-rebuilt view re-ran the .task
        // and resurrected a dismissed offer.
        guard key != model.hybridOptionKey else { return }
        model.hybridOptionKey = key
        model.hybridOption = nil
        // Every walk, not the filtered cards: an empty filtered list must not
        // cancel the offer.
        guard model.walkingMode, let ep = model.lastPlanEndpointsPublic,
              let walkRoute = model.routeChoices.min(by: { $0.eta < $1.eta })
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
        model.hybridOption = HybridOption(
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

    /// One transit toggle button: colored while its mode is active. Every
    /// toggle reshapes the whole trip — a bus added to a train trip is the bus
    /// from the far station, not a second card.
    private func transitToggle(_ mode: TransitMode, symbol: String, help: String) -> some View {
        let isOn = model.activeTransitModes.contains(mode)
        let tint: Color = switch mode {
        case .rail: .purple
        case .bus: .blue
        case .plane: .indigo
        case .rental: .teal
        }
        return Button {
            if isOn {
                model.activeTransitModes.remove(mode)
            } else {
                model.activeTransitModes.insert(mode)
            }
            reshapeTransit()
        } label: {
            // Golden sizing AND Dynamic Type — both sides improved this.
            Image(systemName: symbol)
                .scaledFont(size: golden.iconSmall * 0.46, weight: .bold)
                .foregroundStyle(isOn ? .white : .primary)
                .frame(width: golden.iconSmall, height: golden.iconSmall)
                .background(isOn ? tint : Theme.fill(0.06))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Close one card, and turn off the toggles it stands for — the whole
    /// trip's card stands for every toggle folded into it. The other cards
    /// stay as they are: none of them depends on the one closed. The map
    /// clears only when nothing drawable is left.
    private func dismissCard(_ key: TransitMode) {
        let active = model.activeTransitModes
        let gone = currentShape()?.modes(ofCard: key, active: active) ?? [key]
        for mode in gone.union([key]) {
            model.transitTasks[mode]?.cancel()
            model.transitTasks[mode] = nil
            model.transitOptions[mode] = nil
        }
        model.activeTransitModes.subtract(gone)
        if model.roadChosenOverTransit {
            // The rider is looking at a road; closing a card leaves it be.
        } else if let next = TransitMode.allCases.first(where: {
            model.transitOptions[$0]?.itinerary != nil
        }) {
            model.transitItinerary = model.transitOptions[next]?.itinerary
        } else if model.transitItinerary?.mode != "Walk + ride" {
            // Siblings may still be computing — better an empty map for a
            // moment than the CLOSED card's route still drawn as if chosen;
            // each sibling task assigns its own itinerary when it lands.
            model.transitItinerary = nil
        }
    }

    /// What the drawn line is and is not, for an itinerary whose ride
    /// geometry is a stand-in. The geometry claim must match what's drawn:
    /// only claim the ride follows roads when MapKit actually road-routed
    /// it; on the straight-connector fallback, say so. The time is scaled
    /// from MapKit's measured drive time (distance ÷ speed only in the
    /// no-road fallback), so it's an estimate — not a "distance estimate".
    /// "Walk legs are exact" only holds when every walk leg actually routed:
    /// a leg with no pedestrian route is a synthetic line. City bus and train
    /// legs are the other way round: their times are the city's timetable,
    /// and only their lines are straight. Once the operator's timetable has
    /// answered (`timetable`), the ride's time is its own, not a guess.
    private func geometryNote(_ itinerary: TransitItinerary, timetable: Bool) -> String {
        let isRail = itinerary.mode == "Amtrak" || itinerary.mode == "Rail"
        let walksExact = itinerary.legs
            .filter { $0.kind == .walk }.allSatisfy { $0.polyline != nil }
        let walkNote = walksExact
            ? "Walk legs are exact."
            : "One walk leg couldn't be routed and is shown as an estimate."
        let cityNote = itinerary.legs.contains { $0.local }
            ? "City bus and train lines are drawn straight from stop to stop; "
                + "their times are the city's own. "
            : ""
        guard itinerary.mainRide != nil else { return cityNote + walkNote }
        let rideNote: String
        if timetable {
            rideNote = itinerary.rideGeometryIsReal
                ? "Ride line follows the highway as a stand-in; its times are the "
                    + "timetable's own. "
                : "Ride line is drawn straight between stations; its times are the "
                    + "timetable's own. "
        } else if !itinerary.rideGeometryIsReal {
            rideNote = "Ride line couldn't be road-routed — drawn straight between "
                + "stations; the time is an estimate. "
        } else if isRail {
            rideNote = "Ride line follows the highway as a stand-in and the time is "
                + "a guess — real train lines and times come later. "
        } else {
            rideNote = "Ride line follows the roads the bus drives; the time is a "
                + "guess — real bus times come later. "
        }
        return rideNote + cityNote + walkNote
    }

    /// How long the first walk is when it DOMINATES the trip (over an hour,
    /// and longer than the ride itself) — a "transit" option that is really
    /// a hike to the station; nil when the access walk is ordinary.
    private func dominatingAccessWalk(_ itinerary: TransitItinerary) -> TimeInterval? {
        guard let firstWalk = itinerary.legs.first, firstWalk.kind == .walk,
              let walkSec = firstWalk.seconds, walkSec > 3600,
              let ride = itinerary.mainRide ?? itinerary.legs.first(where: { $0.kind == .ride }),
              walkSec > (ride.seconds ?? 0)
        else { return nil }
        return walkSec
    }

    /// The rental rows' heading, named for where their miles are measured
    /// FROM — the stop the traveller steps off at (or, for a rental car
    /// taken from the start, the start). "At the destination" read as miles
    /// from the trip's end, which is not what a traveller standing on the
    /// platform needs.
    private func rentalHeading(_ itinerary: TransitItinerary) -> String {
        guard let alight = itinerary.mainRide?.toName, !alight.isEmpty else {
            if itinerary.mainRide == nil, let start = itinerary.legs.first?.fromName,
               !start.isEmpty {
                return "Rental cars near \(start)"
            }
            return "Rental cars where you get off"
        }
        return "Rental cars near \(alight)"
    }

    /// The timetable's own words: when it leaves, when it gets in, what it is
    /// called, and when the next one goes. Extracted so the compiler does not
    /// have to type-check it inside the already-large detail builder.
    @ViewBuilder
    private func publishedTimesRow(_ s: TransitSchedule) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(s.plainLine, systemImage: "clock.fill")
                .scaledFont(.caption, weight: .bold)
                .foregroundStyle(.primary)
            if s.legs.count > 1 {
                // Every vehicle named. For the 110 towns Amtrak reaches only
                // by connecting coach, the bus IS the ride — showing just the
                // train would leave someone waiting on the wrong platform.
                ForEach(Array(s.legs.enumerated()), id: \.offset) { _, leg in
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(leg.clockSpan) · \(leg.vehicleLine)")
                            .scaledFont(.caption2, weight: .semibold)
                        Text("\(leg.boardName) to \(leg.alightName)")
                            .scaledFont(size: 9)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("\(s.boardName) to \(s.alightName)")
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !s.laterLine.isEmpty {
                Text(s.laterLine)
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(s.asOf.isEmpty ? s.credit : "\(s.credit) · \(s.asOf)")
                .scaledFont(size: 9)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    /// The open itinerary under a transit card: its legs, what the drawn
    /// line is and is not, the ticket, and wheels at the far end. Its own
    /// function because the card's body, with all of this inline, put the
    /// type-checker past its limit.
    @ViewBuilder
    private func itineraryDetail(_ itin: TransitItinerary, _ t: TransitOption,
                                 mode: TransitMode) -> some View {
        // A "transit" option whose ACCESS WALK dominates (suburban
        // start, downtown-only station) is technically correct but
        // reads as a normal ride — call the walk out up front instead
        // of letting a 5-hour hike hide inside a 6h47m total.
        if let walkSec = dominatingAccessWalk(itin) {
            Label("Mostly walking: the nearest stop is "
                  + "\(TransitPlanning.fmt(walkSec)) on foot — "
                  + "consider driving or a rideshare to the station",
                  systemImage: "exclamationmark.triangle.fill")
                .scaledFont(.caption2, weight: .bold)
                .foregroundStyle(.orange)
        }
        // A city vehicle the rider did not choose, carrying a leg: said
        // before the legs, so the train is no surprise to a bus rider.
        ForEach(t.notes, id: \.self) { note in
            Label(note, systemImage: "info.circle.fill")
                .scaledFont(.caption2, weight: .semibold)
                .foregroundStyle(.secondary)
        }
        ForEach(Array(itin.legs.enumerated()), id: \.offset) { i, leg in
            transitLegRow(leg, isLast: i == itin.legs.count - 1,
                          plane: mode == .plane && itin.mode == "Plane")
        }
        if itin.mode == "Plane" {
            // The flight's honesty note: an arc is not a filed flight
            // path, and every time here includes the airport waiting.
            Text("Flight drawn as a straight arc; times include airport "
                 + "waiting and are estimates — airlines set schedules "
                 + "and prices.")
                .scaledFont(size: 9).foregroundStyle(.secondary)
        } else if itin.rideGeometryIsApproximate {
            Text(geometryNote(itin, timetable: t.schedule != nil))
                .scaledFont(size: 9).foregroundStyle(.secondary)
        }
        // The EXACT ticket for this ride — carrier booking page in-line;
        // never a hand-off to Maps.
        if let label = t.ticketLabel {
            if let url = t.ticketURL {
                Link(destination: url) {
                    Label(label, systemImage: "ticket.fill")
                        .scaledFont(.caption, weight: .bold)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.purple.opacity(0.9))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            } else {
                Label("\(label) — pay on board / agency app",
                      systemImage: "ticket")
                    .scaledFont(.caption2, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
        }
        // Wheels at the far end: the traveller arrives WITHOUT a car
        // (leg 3 is a walk by design). Nearest office per brand,
        // biggest brands first — any operator MapKit knows, with the
        // office's own page (or the brand's booking site) linked.
        // Shown whenever the rider asked for a rental car, too — with no
        // counter found nearby, the partner page still lists who rents there.
        if !t.rentals.isEmpty || itin.legs.contains(where: \.rental) {
            Divider()
            // Named for where the miles are measured FROM — the stop
            // the traveller steps off at. "At the destination" read
            // as miles from the trip's end, which is not what a
            // traveller standing on the platform needs.
            Label(rentalHeading(itin), systemImage: "car.2.fill")
                .scaledFont(.caption2, weight: .bold)
            ForEach(Array(t.rentals.enumerated()), id: \.offset) { _, office in
                HStack(spacing: 4) {
                    Text("\(office.name) · \(String(format: "%.1f mi", office.miles))")
                        .scaledFont(size: 10)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    // Every booking is FLOWS's partner link (code FAWN) for
                    // this place — the owner's rule for results as well as
                    // searches. The partner page lists this company's cars
                    // beside the rest.
                    if let url = t.rentalCompareURL {
                        Link("Book", destination: url)
                            .scaledFont(size: 10, weight: .bold)
                    }
                }
            }
            // One place to compare the companies against each other, on the
            // same partner page.
            if let compare = t.rentalCompareURL {
                Link(t.rentals.isEmpty ? "Compare rental car prices and book"
                                       : "Compare prices at all of them",
                     destination: compare)
                    .scaledFont(size: 10, weight: .semibold)
            }
        }
    }

    private func transitCard(_ t: TransitOption, mode: TransitMode) -> some View {
        let symbol = switch mode {
        case .rail: "tram.fill"
        case .bus: "bus.fill"
        case .plane: "airplane"
        case .rental: "key.fill"
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(t.title, systemImage: symbol)
                    .scaledFont(size: 13, weight: .bold)
                // Cross-mode banners: transit is "Cheapest" when its estimated
                // fare undercuts every drive option's fuel estimate (never beside
                // a walk, which costs nothing), and rail/bus are effectively
                // always the CO₂ winner per passenger-mile
                // — say so. Flying is NOT (per-seat emissions rival driving),
                // so the plane card never wears the green chip.
                if let itin = t.itinerary {
                    if itin.fare > 0, !choices.isEmpty,
                       itin.fare < choices.map({ fuelCost($0) }).min() ?? .infinity {
                        Text("Cheapest")
                            .scaledFont(size: 10, weight: .heavy)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.9))
                            .foregroundStyle(.white).clipShape(Capsule())
                    }
                    if mode != .plane, mode != .rental {
                        Text("Less pollution")
                            .scaledFont(size: 10, weight: .heavy)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.mint.opacity(0.9))
                            .foregroundStyle(.white).clipShape(Capsule())
                            .help("A train or bus makes far less pollution per rider than a car")
                    }
                }
                Spacer()
                if let itin = t.itinerary {
                    Text("\(TransitPlanning.fmt(itin.totalSeconds))"
                         + (itin.fare > 0 ? " · ~$\(String(format: "%.0f", itin.fare)) est." : ""))
                        .scaledFont(.caption2, weight: .semibold).foregroundStyle(.secondary)
                }
                Button {
                    dismissCard(mode)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            // Real times, whenever the operator's timetable could be read —
            // above the itinerary, and shown even when there is no drawn
            // itinerary at all, because a town reachable only by connecting
            // coach has a real departure and no route FLOWS can draw to it.
            if let s = t.schedule {
                publishedTimesRow(s)
            }
            // In-app itinerary: every leg, with the ARRIVAL-station walk called
            // out — you took the train, so the last mile is on foot, not a drive.
            if let itin = t.itinerary {
                itineraryDetail(itin, t, mode: mode)
            } else {
                Text(t.detail).scaledFont(.caption).foregroundStyle(.secondary)
                // No counter found near the start: the partner page for the
                // place still lists every company that rents there.
                if mode == .rental, let compare = t.rentalCompareURL {
                    Link("Compare prices and book", destination: compare)
                        .scaledFont(size: 10, weight: .semibold)
                }
            }
        }
        .padding(8)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // Tapping a transit card draws ITS itinerary on the map (rail and bus
        // cards can both be open; the tapped one is shown).
        .onTapGesture {
            if let itin = t.itinerary {
                model.roadChosenOverTransit = false
                model.transitItinerary = itin
            }
        }
    }

    /// One itinerary leg: walk (real MapKit steps), drive (park-and-ride
    /// access, an arrival-airport "rent or ride", or a hailed car on the
    /// walk-hybrid card), or ride (board/alight — train, bus, or flight).
    private func transitLegRow(_ leg: TransitLeg, isLast: Bool,
                               plane: Bool = false, hail: Bool = false) -> some View {
        let rideSymbol = leg.local ? TransitPlanning.vehicleSymbol(leg.vehicle)
            : plane ? "airplane" : "tram.fill"
        let (symbol, color): (String, Color) = switch leg.kind {
        case .walk: ("figure.walk", .green)
        case .drive: (leg.rental ? "key.fill" : "car.fill", .blue)
        case .ride: (rideSymbol, .purple)
        }
        let title: String = switch leg.kind {
        case .walk: isLast && !hail ? "Walk to \(leg.toName)  (no car — you rode transit)"
                                    : "Walk to \(leg.toName)"
        case .drive: hail ? "Ride to \(leg.toName) — paid car"
                   : leg.rental ? "Drive a rental car to \(leg.toName)"
                   : isLast ? "Get a ride or rental to \(leg.toName)"
                   : "Drive to \(leg.toName) — park & ride"
        case .ride: leg.local ? "\(leg.vehicle ?? "Bus") to \(leg.toName)"
                  : plane ? "Fly \(leg.fromName) → \(leg.toName)"
                          : "Ride the \(leg.fromName) → \(leg.toName)"
        }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .scaledFont(size: 12, weight: .bold)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title)
                        .scaledFont(size: 11, weight: .semibold)
                    Spacer(minLength: 4)
                    Text(TransitPlanning.fmt(leg.seconds))
                        .scaledFont(size: 10, weight: .semibold).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(leg.steps.prefix(isLast || leg.kind != .walk ? 3 : 2).enumerated()),
                        id: \.offset) { _, s in
                    Text("• \(s)").scaledFont(size: 9).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Per-render snapshot of the card list and everything derived from it.
    /// Built ONCE per body evaluation: `model.filteredChoices` is a full
    /// filter pass over the routes, and reading it (and the designation ids)
    /// through computed vars from every card re-ran that pass ~50× per
    /// render — per scoring progress tick, now that cards update live.
    private struct CardContext {
        let choices: [PlannedRoute]
        let fastestETA: TimeInterval
        let safestID: UUID?
        let cheapestID: UUID?
        let efficientID: UUID?
        let truckerID: UUID?
    }

    private func makeCardContext() -> CardContext {
        let choices = model.filteredChoices
        return CardContext(
            choices: choices,
            fastestETA: choices.map(\.eta).min() ?? 0,
            safestID: safestID(in: choices),
            cheapestID: cheapestID(in: choices),
            efficientID: efficientID(in: choices),
            truckerID: model.truckerRouteID)
    }

    /// "$12 fuel est." line for a card; nil when economy/price are unknowable,
    /// and for a walk, which burns none.
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
    private func safestID(in choices: [PlannedRoute]) -> UUID? {
        let scored = choices.filter(\.weatherScored)
        guard scored.count == choices.count, scored.count > 1,
              let best = scored.min(by: { $0.weatherRisk < $1.weatherRisk })
        else { return nil }
        return best.id
    }

    /// Estimated out-of-pocket fuel cost for a drive route: the driver's own
    /// vehicle economy when a profile exists, else the EPA-average car so
    /// routes stay comparable. State fuel price from the current locale. A
    /// walk costs nothing — so it shows no fuel line, and a transit fare is
    /// never "Cheapest" beside it.
    private func fuelCost(_ route: PlannedRoute) -> Double {
        let mpu = model.vehicle.profile?.ratedMilesPerUnit ?? TripCosts.defaultMilesPerUnit
        let fuel = model.vehicle.profile?.fuelType ?? TripCosts.defaultFuel
        let price = FuelPrices.estimate(fuel: fuel, state: model.currentStateCode)
        return TripCosts.routeFuelCostUSD(
            isWalk: route.isWalk, miles: route.distanceMeters / 1609.344,
            milesPerUnit: mpu, pricePerUnit: price) ?? 0
    }

    /// "Cheapest" = lowest estimated fuel cost, with a toll counted against
    /// a route (CheapestRoute). Decided once all routes are scored so the
    /// banner doesn't jump mid-hydration.
    private func cheapestID(in choices: [PlannedRoute]) -> UUID? {
        let scored = choices.filter(\.weatherScored)
        guard scored.count == choices.count, scored.count > 1 else { return nil }
        return CheapestRoute.pick(scored.map {
            CheapestRoute.Candidate(id: $0.id, fuelUSD: fuelCost($0), hasTolls: $0.hasTolls,
                                    isWalk: $0.isWalk)
        })
    }

    /// "Efficient" = least fuel burned (car) — with one vehicle the shortest
    /// distance wins (EfficientRoute; walks burn none and earn no chip);
    /// CO₂-efficiency for mass transit is flagged on the transit card instead
    /// (per-passenger-mile emissions beat any car).
    private func efficientID(in choices: [PlannedRoute]) -> UUID? {
        let scored = choices.filter(\.weatherScored)
        guard scored.count == choices.count, scored.count > 1 else { return nil }
        return EfficientRoute.pick(scored.map {
            EfficientRoute.Candidate(id: $0.id, meters: $0.distanceMeters, isWalk: $0.isWalk)
        })
    }

    private var routesTitle: some View {
        Text("Routes")
            .scaledFont(size: 15, weight: .bold)
            .lineLimit(1)
            .fixedSize()   // a landscape phone wrapped this to "Route / s"
    }

    /// Walk ↔ drive, then train, bus, plane and rental car.
    @ViewBuilder
    private var modeToggles: some View {
        // Drive | Walk: walking uses Apple's pedestrian network
        // (sidewalks/crossings where mapped, real pace). Two named choices —
        // an on/off switch read "off" for driving.
        Picker("Travel by", selection: Binding(
            get: { model.walkingMode },
            set: { walking in
                guard walking != model.walkingMode else { return }
                model.walkingMode = walking
                Task { await replanForMode() }
            })) {
            Text("Drive").tag(false)
            Text("Walk").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        // Train/bus/plane/rental are TOGGLES: tinted while active, tap again
        // to turn off. Any mix of them is one trip (TripShape): car, bus and
        // train drives to the train and takes the bus from the far station.
        transitToggle(.rail, symbol: "tram.fill",
                      help: "Rail option: local rail/subway, or Amtrak for long trips")
        transitToggle(.bus, symbol: "bus.fill",
                      help: "Bus option: local transit, or Greyhound for long trips")
        transitToggle(.plane, symbol: "airplane",
                      help: "Plane option: fly between the nearest airports with airline service")
        transitToggle(.rental, symbol: "key.fill",
                      help: "Rental car: pick one up where your train, bus or plane gets in — or near the start")
        // (Tourist stops live in the FILTER grid below — a route
        // option, not a transportation mode.)
    }

    /// X = minimize, not abandon: the panel tucks into the round routes icon
    /// at the top right; the trip pill's Edit is how a plan is actually
    /// discarded.
    private var tuckButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                _ = model.collapsedPanels.insert("routes")
            }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Tuck the route list away")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // One row when it fits; in a narrow list (the Mac with settings
            // open) the mode toggles fold onto a second line instead of
            // pushing the card past its column. The header holds no state
            // of its own, so laying it out twice to measure is safe.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    routesTitle
                    modeToggles
                    Spacer()
                    tuckButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        routesTitle
                        Spacer()
                        tuckButton
                    }
                    HStack(spacing: 8) {
                        modeToggles
                    }
                }
            }
            if let notice = model.plannerNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(.caption, weight: .semibold)
                    .padding(8)
                    .background(Theme.riskYellow.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if !model.walkingMode { filterChips }
            ScrollView {
                // One snapshot for the whole list — every derived value the
                // cards share is computed here exactly once per render.
                let ctx = makeCardContext()
                VStack(spacing: 8) {
                    // Transit cards scroll WITH the route cards: three open
                    // itineraries stack taller than a phone screen, and
                    // outside the scroll they pushed the route list off the
                    // bottom edge on compact layouts.
                    ForEach(TransitMode.allCases.filter { model.transitOptions[$0] != nil },
                            id: \.self) { mode in
                        if let opt = model.transitOptions[mode] { transitCard(opt, mode: mode) }
                    }
                    // Walking mode's money-vs-time option — only when walking
                    // is the sole selection and the ride clears the
                    // significance bar.
                    if model.walkingMode, model.activeTransitModes.isEmpty,
                       let h = model.hybridOption {
                        hybridCard(h)
                    }
                    // ctx.choices, not choices: the per-render snapshot
                    // computes the filtered list once instead of ~50 times
                    // per render. Their transit-cards-inside-the-scroll fix
                    // and that snapshot are independent wins; keep both.
                    // Only when there ARE routes: with none at all (a walk
                    // with no path) the notice above says why, and filter
                    // text under it blamed the filters.
                    if ctx.choices.isEmpty, !model.routeChoices.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            // "Looking" only while a search really runs;
                            // it used to say so forever.
                            Text(model.routeSearchesInFlight > 0
                                 ? "No route fits every filter — looking for one…"
                                 : "No route fits every filter.")
                                .scaledFont(.footnote)
                                .foregroundStyle(.secondary)
                            if let closest = closestMatch {
                                // Named before its GO: a count hid WHICH one
                                // (a low bridge, a weight limit, high wind).
                                Text("Closest match — it doesn't fit: "
                                     + model.brokenFilters(closest).map(\.rawValue)
                                        .joined(separator: ", "))
                                    .scaledFont(.caption, weight: .semibold)
                                RouteCard(
                                    route: closest,
                                    keyPoints: keyPoints(for: closest, ctx: ctx),
                                    // Against every route: its own ETA made
                                    // it "Fastest" even when it was slowest.
                                    fastestETA: model.routeChoices.map(\.eta).min() ?? closest.eta,
                                    isSafest: false,
                                    isCheapest: false,
                                    isEfficient: false,
                                    isTrucker: ctx.truckerID == closest.id,
                                    fuelCostText: fuelCostText(closest),
                                    isHighlighted: closest.id == model.highlightedRouteID,
                                    onHighlight: { highlight(closest) },
                                    onGo: { model.select(route: closest) })
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    ForEach(ctx.choices) { route in
                        RouteCard(
                            route: route,
                            keyPoints: keyPoints(for: route, ctx: ctx),
                            fastestETA: ctx.fastestETA,
                            isSafest: route.id == ctx.safestID,
                            isCheapest: route.id == ctx.cheapestID,
                            isEfficient: route.id == ctx.efficientID,
                            isTrucker: ctx.truckerID == route.id,
                            fuelCostText: fuelCostText(route),
                            isHighlighted: route.id == model.highlightedRouteID,
                            onHighlight: { highlight(route) },
                            onGo: { model.select(route: route) })
                    }
                }
                // Cards align to their own edges, so scrolling never leaves
                // one sliced across the panel's bottom.
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
        .collapsibleMenu("routes")
        .floatingCard()
        // Recompute the walk+ride offer whenever the plan or the walking
        // toggle changes (the id flips; .task cancels the stale run itself).
        // The key also rides into computeHybrid so a rotation-rebuilt view
        // (same id) skips recomputing what the model already holds.
        .task(id: hybridKey) {
            await computeHybrid(key: hybridKey)
        }
    }

    /// Plan identity for the walk+ride offer: the walking toggle + lead route.
    private var hybridKey: String {
        "\(model.walkingMode)|\(model.routeChoices.first?.id.uuidString ?? "-")"
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
                    .scaledFont(size: 13, weight: .bold)
                Text("Best time for the money")
                    .scaledFont(size: 10, weight: .heavy)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.9))
                    .foregroundStyle(.white).clipShape(Capsule())
                Spacer()
                Text("\(TransitPlanning.fmt(h.offer.totalSeconds)) · ~$\(cost) est.")
                    .scaledFont(.caption2, weight: .semibold).foregroundStyle(.secondary)
                Button {
                    model.hybridOption = nil
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
                .scaledFont(.caption)
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
                .scaledFont(size: 9).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        // Tapping draws the ride + walk legs on the map, like the transit cards.
        .onTapGesture {
            model.roadChosenOverTransit = false
            model.transitItinerary = h.itinerary
        }
    }

    private func hailButtonLabel(_ text: String) -> some View {
        Label(text, systemImage: "car.fill")
            .scaledFont(.caption, weight: .bold)
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
                        .scaledFont(.caption, weight: .semibold)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(active ? Theme.cta : Theme.fill(0.05))
                        .foregroundStyle(active ? Theme.onCTA : Color.primary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The pros/cons beneath each option — comparative, so the driver sees
    /// what distinguishes THIS route from the others. Reads shared values
    /// from the per-render CardContext instead of recomputing them per card.
    private func keyPoints(for route: PlannedRoute, ctx: CardContext) -> [(text: String, good: Bool)] {
        var points: [(String, Bool)] = []
        // An electric car's range gap leads on EVERY card — a lone route and
        // the closest match too — and is never cut by the cap below: it is
        // the only warning that the car may not get there, and it used to
        // sit inside the collapsed Risk details, under a GO on the card face.
        if let gap = route.evChargingGapMiles {
            points.append((String(format: "No charger found near mile %.0f — check your range", gap),
                           false))
        }
        let choices = ctx.choices
        let fastestETA = ctx.fastestETA
        let others = choices.filter { $0.id != route.id }
        guard !others.isEmpty else { return points }

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
        // Tourist filter on → each card counts the attractions within a
        // worthwhile detour of ITS corridor, so scenic options impact choice.
        // (model.touristCounts — the same per-route sweep the tourist sort
        // uses.)
        if model.routeFilters.contains(.tourist), let near = model.touristCounts[route.id],
           near > 0 {
            points.append(("\(near) tourist stop\(near == 1 ? "" : "s") along this route", true))
        }
        if let shortest = choices.map(\.distanceMeters).min(),
           route.distanceMeters <= shortest {
            points.append((String(format: "Shortest — %.0f mi", route.distanceMeters / 1609.344), true))
        }
        if route.weatherScored, choices.allSatisfy(\.weatherScored) {
            if route.id == ctx.safestID {
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
        // The same judgment as the Avoid traffic chip: slower in traffic than
        // the calmest card on the same kind of road. (Traffic is no walk's
        // concern.)
        if !route.isWalk, !RouteFilter.avoidTraffic.passes(route, among: choices) {
            points.append(("More traffic than a similar route right now", false))
        }
        if (route.familyPeaks["wind"] ?? 0) >= FlowsCore.riskYellowMin {
            points.append(("Strong winds — take care in a tall vehicle", false))
        }
        return Array(points.prefix(4))
    }

    private func highlight(_ route: PlannedRoute) {
        model.highlightChosen(route.id)
        // The map hides the roads while a train, bus or plane is drawn
        // (ContentView), so tapping a road card with one up moved the camera
        // to a route it never drew. The road the rider tapped is what shows;
        // tapping a transit card brings its trip back.
        model.roadChosenOverTransit = true
        model.transitItinerary = nil
        // Same framing rule as the first plan: grow the rect on whichever
        // side the panel covers, so the route lands in the map the driver
        // can actually see (PlannerPanel.choicesCameraRect).
        // A route whose line hasn't arrived yet has a NULL bounding rect,
        // which the camera reads as 0,0 — the Atlantic off Africa. Leave the
        // map where it is rather than jumping there.
        guard let rect = CameraZoom.usableRect(route.route.polyline.boundingMapRect)
        else { return }
        withAnimation {
            camera = .rect(CameraZoom.framedRect(
                rect,
                panelEdge: panelEdge,
                windowAspect: golden.size.height / max(golden.size.width, 1),
                panelFraction: panelEdge == .bottom ? golden.choicesPanelFraction
                                          : CameraZoom.choicesPanelFraction))
        }
    }
}

// MARK: - Shared MapKit fetches (station, plane, and walk-hybrid paths).
// File-scope, capture nothing, safe to run concurrently via `async let`.

/// A routed walk: the pedestrian line, how long, the steps, how far.
private typealias WalkResult =
    (polyline: MKPolyline?, seconds: TimeInterval?, steps: [String], miles: Double?)

/// One piece of a trip — the way to the main ride, or the way from it —
/// with the city's timetable for it when it rides the city.
private struct TripPart {
    var legs: [TransitLeg]
    var schedule: TransitSchedule? = nil
    /// Door to door, waiting included, when known.
    var seconds: TimeInterval?
    /// A line the rider should read about this piece — a city train carrying
    /// a leg the bus they chose could not.
    var note: String? = nil
}

/// A real pedestrian route (polyline + steps + ETA), MapKit's one
/// transit-adjacent thing it WILL give apps.
private func transitWalk(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D)
    async -> WalkResult {
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
                           _ b: CLLocationCoordinate2D) async -> WalkResult {
    enabled ? await transitWalk(a, b) : (nil, nil, [], nil)
}

/// How far from a point a city stop may be and still be walked to — about
/// half an hour on foot.
private let cityStopMeters = 2_000.0

/// A leg ridden on the city's own buses and trains, from its timetable.
private struct CityTrip {
    /// The walk to the first stop, each ride (and the walk between two stops
    /// when a change needs one), and the walk from the last stop.
    let legs: [TransitLeg]
    let schedule: TransitSchedule
    /// Door to door from the moment asked about, waiting included.
    let seconds: TimeInterval
}

/// Ask the city's timetable for a leg from `start` to `end` leaving after
/// `departing`, boarding only `vehicles` (TripShape's mask of the
/// timetable's mode bits). Nil when no city feed covers the leg, the feed
/// cannot be read, or nothing the rider chose runs between the two.
private func cityTrip(from start: CLLocationCoordinate2D, fromName: String,
                      to end: CLLocationCoordinate2D, toName: String,
                      departing: Date, vehicles: Int, mayFetch: Bool) async -> CityTrip? {
    let sources = TransitFeeds.citySources(from: start.latitude, start.longitude,
                                           to: end.latitude, end.longitude)
    guard !sources.isEmpty,
          let ready = try? await TransitFeeds.shared.ready(
              sources, on: departing, allowNetwork: mayFetch),
          let answer = try? TransitShard.departures(
              prefix: ready.prefix, from: start, to: end, departing: departing,
              stamp: ready.stamp, maxStationMeters: cityStopMeters, limit: 3,
              vehicles: vehicles),
          let schedule = TransitShard.schedule(
              from: answer, credit: ready.credit, operators: ready.operators),
          let first = answer.departures.first,
          let firstRide = first.rides.first, let firstStop = firstRide.boardCoordinate,
          let lastRide = first.rides.last, let lastStop = lastRide.alightCoordinate,
          let off = TransitShard.moment(first.arriveSeconds, answer.stamp)
    else { return nil }
    async let walkInTask = transitWalk(start, firstStop)
    async let walkOutTask = transitWalk(lastStop, end)
    let walkIn = await walkInTask
    let walkOut = await walkOutTask

    var legs = [TransitLeg(
        kind: .walk, fromName: fromName, toName: firstRide.boardName,
        seconds: walkIn.seconds, miles: walkIn.miles, polyline: walkIn.polyline,
        steps: walkIn.steps.isEmpty ? ["Walk to \(firstRide.boardName)"] : walkIn.steps)]
    var previous: TransitShard.Ride?
    for ride in first.rides {
        guard let on = ride.boardCoordinate, let offStop = ride.alightCoordinate else { continue }
        // A change between two different stops is a short walk; drawn
        // straight and timed at the timetable's own walking pace (1.1 m/s).
        if let previous, let was = previous.alightCoordinate {
            let meters = POIRanking.meters(was, on)
            if meters > 30 {
                legs.append(TransitLeg(
                    kind: .walk, fromName: previous.alightName, toName: ride.boardName,
                    seconds: meters / 1.1, miles: meters / 1609.344,
                    polyline: TransitPlanning.connector(was, on),
                    steps: ["Walk to \(ride.boardName) to change"]))
            }
        }
        let vehicle = TransitShard.vehicleWord(ride.mode)
        var steps: [String] = []
        if let leaves = TransitShard.moment(ride.departSeconds, answer.stamp),
           let arrives = TransitShard.moment(ride.arriveSeconds, answer.stamp) {
            steps.append(TransitClock.span(board: leaves, boardZone: ride.boardZone,
                                           alight: arrives, alightZone: ride.alightZone))
        }
        steps.append("Take \(TransitPlanning.cityRide(vehicle: vehicle, name: ride.routeName)) "
                     + "at \(ride.boardName)")
        steps.append("Get off at \(ride.alightName)")
        legs.append(TransitLeg(
            kind: .ride, fromName: ride.boardName, toName: ride.alightName,
            seconds: TimeInterval(ride.arriveSeconds - ride.departSeconds),
            miles: POIRanking.meters(on, offStop) / 1609.344,
            polyline: TransitPlanning.connector(on, offStop), steps: steps,
            local: true, vehicle: vehicle))
        previous = ride
    }
    legs.append(TransitLeg(
        kind: .walk, fromName: lastRide.alightName, toName: toName,
        seconds: walkOut.seconds, miles: walkOut.miles, polyline: walkOut.polyline,
        steps: walkOut.steps.isEmpty ? ["Walk from \(lastRide.alightName) to \(toName)"]
                                     : walkOut.steps))
    let arrive = off.addingTimeInterval(walkOut.seconds ?? 0)
    return CityTrip(legs: legs, schedule: schedule,
                    seconds: max(0, arrive.timeIntervalSince(departing)))
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
/// The traveller arrives car-less; three biggest-brand offices with their
/// distance answer "now what?", and the partner page books one. Transit
/// cards center this on the arrival station, the plane card on the arrival
/// airport, a rental taken from the start on the start.
private func transitRentals(near dest: CLLocationCoordinate2D)
    async -> [RentalCars.Office] {
    let req = MKLocalSearch.Request()
    req.naturalLanguageQuery = "car rental"
    req.pointOfInterestFilter = MKPointOfInterestFilter(including: [.carRental])
    req.region = MKCoordinateRegion(center: dest,
                                    latitudinalMeters: 30_000,
                                    longitudinalMeters: 30_000)
    // Where the OS allows it, the box is a hard limit rather than a hint.
    if #available(iOS 18.0, macOS 15.0, *) {
        req.regionPriority = .required
    }
    let items = (try? await MKLocalSearch(request: req).start())?.mapItems ?? []
    // The region is a relevance BIAS, not a filter: a search at the Minneapolis
    // airport from a phone in Chicago listed Chicago counters 340 miles off.
    // A counter past the search box is not one to pick a car up at.
    return RentalCars.recommend(items.map { item in
        RentalCars.Office(
            name: item.name ?? "Car rental",
            miles: POIRanking.meters(item.placemark.coordinate, dest) / 1609.344,
            coordinate: item.placemark.coordinate)
    }.filter { $0.miles <= RentalCars.maxOfficeMiles })
}

private struct RouteCard: View {
    @EnvironmentObject var model: AppModel
    let route: PlannedRoute
    let keyPoints: [(text: String, good: Bool)]
    let fastestETA: TimeInterval
    let isSafest: Bool
    let isCheapest: Bool
    let isEfficient: Bool
    /// Trucker designation resolved by the parent — reading
    /// model.truckerRouteID here re-ran its scoring sort once per card.
    let isTrucker: Bool
    let fuelCostText: String?
    let isHighlighted: Bool
    let onHighlight: () -> Void
    let onGo: () -> Void

    /// Full risk description is collapsed by default so GO stays above the
    /// fold on every card; the strip + key points carry the summary.
    @State private var showDetails = false

    /// The weather retries ran out on this still-unchecked route.
    private var weatherCheckGaveUp: Bool {
        !route.weatherScored && model.weatherCheckGaveUp.contains(route.id)
    }

    var body: some View {
        // Not a Button: the GO Button nests inside, and nested buttons double-
        // fire on macOS. Tap anywhere else on the card to highlight.
        Group {
            VStack(alignment: .leading, spacing: 6) {
                // Profile chips — the web router's fastest/safest/metro triad.
                HStack(spacing: 5) {
                    // The chips a route earned. On a narrow card they scroll
                    // sideways rather than squeezing each other into
                    // unreadable slivers.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            if route.isWalkingEstimate { profileChip("Walking est.", .green) }
                            if deltaText == "Fastest" { profileChip("Fastest", Theme.cta) }
                            if isSafest { profileChip("Safest", Theme.riskGreen) }
                            if isCheapest { profileChip("Cheapest", .orange) }
                            if isEfficient { profileChip("Efficient", .mint) }
                            if route.planKind == .avoidHighways { profileChip("Local roads", .blue) }
                            if route.planKind == .tollFree { profileChip("Toll-free", .teal) }
                        }
                    }
                    // A chip cut mid-word at the clip edge ("Cheapes") read as
                    // a bug on a landscape phone; a trailing fade says "more".
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: 14)
                        })
                    Spacer(minLength: 4)
                    // ALWAYS-designated trucker pick: high clearance, gentle
                    // grades, low wind, highways + trucker amenities — the
                    // brown truck sits top-right of its card.
                    if isTrucker {
                        Image(systemName: "truck.box.fill")
                            .scaledFont(size: 14, weight: .bold)
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
                        .scaledFont(size: 17, weight: .bold)
                    if deltaText != "Fastest" {
                        Text(deltaText)
                            .scaledFont(.caption, weight: .semibold)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text("\(milesText) · via \(route.via)")
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if route.hasTolls {
                        Label("Tolls", systemImage: "dollarsign.circle")
                            .scaledFont(.caption2, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    if let fuelCostText {
                        Text(fuelCostText)
                            .scaledFont(.caption2, weight: .semibold)
                            .foregroundStyle(.secondary)
                    }
                    // (No bare highway icon here: nothing said what it meant,
                    // and the "via" road already names the highway.)
                }
                // Key points — the at-a-glance pros/cons for this option.
                if !keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(keyPoints.enumerated()), id: \.offset) { _, point in
                            HStack(spacing: 5) {
                                Image(systemName: point.good
                                      ? "checkmark.circle.fill" : "minus.circle.fill")
                                    .scaledFont(.caption2)
                                    .foregroundStyle(point.good ? Theme.riskGreen : Theme.riskYellow)
                                Text(point.text)
                                    .scaledFont(.caption)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                if route.weatherScored && !route.riskFractions.isEmpty {
                    riskStrip
                } else if !route.weatherScored, !route.provisionalFractions.isEmpty {
                    provisionalStrip
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
                                .scaledFont(.caption, weight: .semibold)
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    } else if weatherCheckGaveUp {
                        Text("Couldn't check the weather on this route")
                            .scaledFont(.caption, weight: .semibold)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(isHighlighted ? "Shown on map" : "Tap to view on map")
                            .scaledFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    // GO is gated on weather scoring: navigation must not start
                    // on a route whose risk is still being computed — the card
                    // shows a progress capsule until hydration lands, so the
                    // sequencing (plan → score → GO) is enforced, not implied.
                    if route.weatherScored {
                        Button("GO", action: onGo)
                            .scaledFont(size: 15, weight: .heavy)
                            .buttonStyle(.plain)
                            .frame(width: 72, height: 36)
                            .background(Theme.cta)
                            .foregroundStyle(Theme.onCTA)
                            .clipShape(Capsule())
                    } else if weatherCheckGaveUp {
                        // The retries ran out: an outcome and a way to try
                        // again, not a spinner that never stops. GO stays
                        // locked.
                        Button {
                            model.retryWeatherCheck()
                        } label: {
                            Label("Try again", systemImage: "arrow.clockwise")
                                .scaledFont(.caption, weight: .bold)
                                .frame(minWidth: 92)
                                .frame(height: 36)
                                .padding(.horizontal, 8)
                                .background(Theme.fill(0.06))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("GO unlocks when the weather check is done")
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            // Percent of corridor cells already checked — the
                            // driver sees scoring MOVE on a slow connection.
                            Text(route.scoringProgress > 0
                                 ? "Checking weather… \(Int((route.scoringProgress * 100).rounded()))%"
                                 : "Checking weather…")
                                .scaledFont(.caption, weight: .semibold)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                        .frame(minWidth: 92)
                        .frame(height: 36)
                        .padding(.horizontal, 8)
                        .background(Theme.fill(0.06))
                        .clipShape(Capsule())
                        .help("GO unlocks when the weather check is done")
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

    /// Mid-scoring strip: the checked share of the corridor in band colors,
    /// the still-checking share in neutral gray — on a slow connection risk
    /// appears as cells land instead of the whole card spinning. A gray
    /// stretch means "not checked yet", never "clear".
    private var provisionalStrip: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(route.provisionalFractions.enumerated()), id: \.offset) { _, item in
                    Rectangle()
                        .fill(item.band.map { $0.color.opacity($0 == .clear ? 0.35 : 0.9) }
                              ?? Color.secondary.opacity(0.15))
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
            .scaledFont(.footnote, weight: .semibold)

            // Physical attributes (verifiable data: USGS grades, OSM
            // clearances, FEMA flood zones) — "checking…" while hydrating.
            Text(attributeLine)
                .scaledFont(.caption)
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
                .scaledFont(.caption)
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
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // Explicit clearance confirmation on the trucker pick — judged
            // against YOUR height (the badge itself is picked for a 13'6"
            // semi), so a taller rig sees the red verdict, not a green one.
            if isTrucker, model.routeFilters.contains(.lowBridges) {
                if let cl = route.clearancesMeters {
                    let clears = model.filterLimits.passesClearances(cl)
                    Label(cl.min().map {
                        "Clearance checked: lowest post " + FilterLimits.feetAndInches(meters: $0)
                            + (clears ? " — clears your vehicle" : " — too low for your vehicle")
                    } ?? "Clearance checked: no posted low bridges on this route",
                          systemImage: clears ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .scaledFont(.caption, weight: .bold)
                        .foregroundStyle(clears ? Theme.riskGreen : Theme.riskRed)
                } else {
                    Label("Clearance check in progress…", systemImage: "clock")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let gap = route.evChargingGapMiles {
                Label(String(format: "No charger found near mile %.0f — verify "
                             + "range before taking this route", gap),
                      systemImage: "bolt.slash.fill")
                    .scaledFont(.footnote, weight: .bold)
                    .foregroundStyle(Theme.riskRed)
            }

            // Active alerts on top of the field.
            if route.alertCoverage > 0 {
                Text(exposureLine)
                    .scaledFont(.footnote, weight: .semibold)
                    .foregroundStyle(badgeColor)
                if !route.alertEvents.isEmpty {
                    Text(route.alertEvents.prefix(3).joined(separator: " · ")
                         + (route.alertEvents.count > 3 ? " · +\(route.alertEvents.count - 3) more" : ""))
                        .scaledFont(.caption)
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
                     ? "No active alerts — the forecast raises the risk along this route."
                     : "All clear — no active alerts or elevated conditions.")
                    .scaledFont(.caption)
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
                var text = "Lowest clearance " + FilterLimits.feetAndInches(meters: worst)
                if model.routeFilters.contains(.lowBridges) {
                    text += limits.passesClearances(clearances)
                        ? " ✓" : " ✗ too low for your vehicle"
                }
                parts.append(text)
            } else { parts.append("No posted low clearances") }
        } else if route.clearanceDataUnavailable {
            parts.append("Bridge heights: no map data")
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
            // "no map data" above already covers the failure case.
            parts.append("Weight limits: checking…")
        }
        if let f = route.femaFloodFraction {
            parts.append(String(format: "Flood zone %.0f%%", f * 100))
        } else {
            parts.append(route.attributesScored
                         ? "Floodplain: no data" : "Floodplain: checking…")
        }
        return parts.joined(separator: " · ")
    }

    private func profileChip(_ label: String, _ color: Color) -> some View {
        Text(label)
            .scaledFont(.caption2, weight: .heavy)
            // One line, never hyphenated: a route that wins on every count
            // wears four of these, and "Cheap-est" across two lines is not
            // a label anyone can read at a glance.
            .lineLimit(1)
            .fixedSize()
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
            if let worst = route.provisionalWorstRisk {
                // Cells are landing: show the worst band seen SO FAR, still
                // clearly in progress (spinner stays). Never a final claim —
                // GO stays locked until the full verdict.
                let band = FlowsCore.riskBand(score: worst)
                HStack(spacing: 5) {
                    // No spinner once the check has given up.
                    if !weatherCheckGaveUp { ProgressView().controlSize(.mini) }
                    Text(band == .clear ? "Clear so far" : "\(band.rawValue) so far")
                }
                .scaledFont(.caption, weight: .semibold)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background((band == .clear ? Color.secondary : band.color)
                    .opacity(band == .clear ? 0.12 : 0.2))
                .foregroundStyle(band == .clear ? Color.secondary : band.color)
                .clipShape(Capsule())
            } else {
                // Routes render before their corridor weather has been scored;
                // the badge hydrates in place a few seconds later.
                HStack(spacing: 5) {
                    if !weatherCheckGaveUp { ProgressView().controlSize(.mini) }
                    Text(weatherCheckGaveUp ? "Weather unknown" : "Weather…")
                }
                .scaledFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.06))
                .clipShape(Capsule())
            }
        } else {
            // Labeled so it can't be misread against the peak line: this is
            // the whole-route normalized band, peaks can be worse. Named as
            // the map key names it ("Clear"): "No risk" promised too much.
            Text("Overall \(route.riskBand.rawValue)")
                .scaledFont(.caption, weight: .bold)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(badgeColor.opacity(route.riskBand == .clear ? 0.12 : 0.2))
                .foregroundStyle(route.riskBand == .clear ? .secondary : badgeColor)
                .clipShape(Capsule())
        }
    }
}
