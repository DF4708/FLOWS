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
    /// Per-mode transit options (true = rail, false = bus) — car, train, AND
    /// bus can all be selected together; the planner shows every option.
    @State private var transitOptions: [Bool: TransitOption] = [:]
    /// Which transit modes are toggled ON (multi-select).
    @State private var activeTransitModes: Set<Bool> = []
    /// The in-flight transit computation, so a fresh mode tap cancels the last
    /// one — otherwise a slower stale result could overwrite the newer itinerary.
    // Per-mode (rail=true / bus=false) so cancelling one never orphans the
    // other, and so the cancel actually targets a live task (the single var
    // was never assigned — every Task.isCancelled guard was dead, letting a
    // stale itinerary overwrite fresh state).
    @State private var transitTasks: [Bool: Task<Void, Never>] = [:]

    private func replanForMode() async {
        guard let ep = model.lastPlanEndpointsPublic else { return }
        transitTasks.values.forEach { $0.cancel() }   // a drive replan supersedes any in-flight transit calc
        transitTasks = [:]
        if let planned = try? await model.plan(from: ep.from, fromName: ep.fromName,
                                               to: ep.to, toName: ep.toName) {
            model.present(routes: planned)   // clears model.transitItinerary
            transitOptions = [:]             // …drop the now-stale transit cards too
            activeTransitModes = []          // …and untoggle rail/bus
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
    private func computeTransit(rail: Bool) async {
        guard let ep = model.lastPlanEndpointsPublic else { return }
        let miles = POIRanking.meters(ep.from, ep.to) / 1609.344
        let longHaul = miles > 60
        let kind = longHaul ? (rail ? "Amtrak" : "Greyhound") : (rail ? "Rail" : "Bus")

        // @Sendable: these run concurrently via `async let`; they capture only
        // Sendable value-type locals (longHaul/rail/kind), never self or model.
        @Sendable func station(near c: CLLocationCoordinate2D) async -> MKMapItem? {
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
            let maxMeters = longHaul ? 120_000.0 : 20_000.0
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
            // No local rail → still be useful: find the CLOSEST rail anywhere
            // within intercity range and recommend it by name + distance.
            var detail = "No station within range of the start point."
            if rail, !longHaul {
                let r = MKLocalSearch.Request()
                r.naturalLanguageQuery = "Amtrak train station"
                r.region = MKCoordinateRegion(center: ep.from,
                    latitudinalMeters: 240_000, longitudinalMeters: 240_000)
                if let nearest = (try? await MKLocalSearch(request: r).start())?
                    .mapItems.min(by: {
                        POIRanking.meters($0.placemark.coordinate, ep.from)
                            < POIRanking.meters($1.placemark.coordinate, ep.from) }) {
                    let mi = POIRanking.meters(nearest.placemark.coordinate, ep.from) / 1609.344
                    detail = String(format: "No local rail nearby. Closest train: %@, %.0f mi away — drive there or take the bus option.",
                                    nearest.name ?? "Amtrak station", mi)
                }
            }
            transitOptions[rail] = TransitOption(
                title: rail ? "No rail found nearby" : "No bus service found nearby",
                detail: detail,
                fare: 0, destination: MKMapItem(placemark: MKPlacemark(coordinate: ep.to)))
            return
        }
        let alight = await alightTask
        if Task.isCancelled { return }   // a newer mode tap superseded this one
        let boardC = board.placemark.coordinate
        let alightC = alight?.placemark.coordinate ?? ep.to

        // A real pedestrian route (polyline + steps + ETA), MapKit's one
        // transit-adjacent thing it WILL give apps.
        @Sendable func walk(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D)
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
        // Leg 3 only when an arrival station was found — the no-car last mile.
        @Sendable func maybeWalk(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                       _ enabled: Bool) async -> (MKPolyline?, TimeInterval?, [String], Double?) {
            enabled ? await walk(a, b) : (nil, nil, [], nil)
        }
        // The ride's GROUND corridor: MapKit road geometry + real drive time +
        // road miles between stations. A coach literally drives this; for rail
        // it's a close corridor proxy until GTFS shapes land. Beats a straight
        // line that cuts across water/terrain, and the drive time anchors the
        // ride estimate to measured road data instead of Apple's opaque
        // `.transit` ETA (which returned near-identical times for bus and rail).
        @Sendable func rideGeometry(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D)
            async -> (MKPolyline?, Double?, TimeInterval?) {
            let req = MKDirections.Request()
            req.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
            req.destination = MKMapItem(placemark: MKPlacemark(coordinate: b))
            req.transportType = .automobile
            guard let route = (try? await MKDirections(request: req).calculate())?
                .routes.first else { return (nil, nil, nil) }
            return (route.polyline, route.distance / 1609.344, route.expectedTravelTime)
        }

        // Rental counters near the destination — any operator MapKit knows
        // (Hertz, Enterprise, a local independent), keyless like every other
        // POI source. The traveller arrives car-less; three biggest-brand
        // offices with distance + booking link answer "now what?".
        @Sendable func rentalOffices(_ dest: CLLocationCoordinate2D)
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

        // The four requests are independent — run them concurrently.
        async let w1 = walk(ep.from, boardC)
        async let rideG = rideGeometry(boardC, alightC)
        async let w3 = maybeWalk(alightC, ep.to, alight != nil)
        async let rentalsNearDest = rentalOffices(ep.to)
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
            let (drivePoly, driveMi, driveSecs) = await rideGeometry(ep.from, boardC)
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
        transitOptions[rail] = TransitOption(
            title: "\(kind) via \(boardName)",
            detail: "\(accessVerb) \(TransitPlanning.fmt(accessLeg.seconds)) to \(boardName) · "
                    + "\(kind.lowercased()) ride \(TransitPlanning.fmt(rideSec))\(tail) · est. fare "
                    + String(format: "$%.2f (carriers set final pricing).", fare),
            fare: fare, destination: dest,
            ticketLabel: ticketLabel, ticketURL: ticketURL,
            itinerary: itinerary,
            rentals: await rentalsNearDest)
    }

    /// One rail/bus toggle button: colored while its mode is active.
    private func transitToggle(rail: Bool, symbol: String, help: String) -> some View {
        let isOn = activeTransitModes.contains(rail)
        return Button {
            if isOn {
                // Toggle THIS mode off; other selections stay.
                transitTasks[rail]?.cancel(); transitTasks[rail] = nil
                activeTransitModes.remove(rail)
                transitOptions[rail] = nil
                if activeTransitModes.isEmpty { model.transitItinerary = nil }
                else if let other = transitOptions[!rail]?.itinerary {
                    model.transitItinerary = other
                }
            } else {
                activeTransitModes.insert(rail)
                transitTasks[rail]?.cancel()
                transitTasks[rail] = Task { await computeTransit(rail: rail) }
            }
        } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                .foregroundStyle(isOn ? .white : .primary)
                .frame(width: 26, height: 26)
                .background(isOn ? (rail ? Color.purple : Color.blue)
                                 : Color.black.opacity(0.06))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func transitCard(_ t: TransitOption, rail: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(t.title, systemImage: "tram.fill")
                    .font(.system(size: 13, weight: .bold))
                // Cross-mode banners: transit is "Cheapest" when its estimated
                // fare undercuts every drive option's fuel estimate, and it is
                // effectively always the CO₂ winner per passenger-mile — say so.
                if let itin = t.itinerary {
                    if itin.fare > 0, !choices.isEmpty,
                       itin.fare < choices.map({ fuelCost($0) }).min() ?? .infinity {
                        Text("Cheapest")
                            .font(.system(size: 10, weight: .heavy))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.9))
                            .foregroundStyle(.white).clipShape(Capsule())
                    }
                    Text("CO₂-efficient")
                        .font(.system(size: 10, weight: .heavy))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.mint.opacity(0.9))
                        .foregroundStyle(.white).clipShape(Capsule())
                        .help("Mass transit emits far less CO₂ per passenger-mile than driving")
                }
                Spacer()
                if let itin = t.itinerary {
                    Text("\(TransitPlanning.fmt(itin.totalSeconds))"
                         + (itin.fare > 0 ? " · ~$\(String(format: "%.0f", itin.fare)) est." : ""))
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                Button {
                    transitTasks[rail]?.cancel(); transitTasks[rail] = nil
                    activeTransitModes.remove(rail)
                    transitOptions[rail] = nil
                    if activeTransitModes.isEmpty { model.transitItinerary = nil }
                    else if let other = transitOptions[!rail]?.itinerary {
                        model.transitItinerary = other
                    }
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
                    transitLegRow(leg, isLast: i == itin.legs.count - 1)
                }
                if itin.rideGeometryIsApproximate {
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
    /// station access), or ride (board/alight).
    private func transitLegRow(_ leg: TransitLeg, isLast: Bool) -> some View {
        let (symbol, color): (String, Color) = switch leg.kind {
        case .walk: ("figure.walk", .green)
        case .drive: ("car.fill", .blue)
        case .ride: ("tram.fill", .purple)
        }
        let title: String = switch leg.kind {
        case .walk: isLast ? "Walk to \(leg.toName)  (no car — you rode transit)"
                           : "Walk to \(leg.toName)"
        case .drive: "Drive to \(leg.toName) — park & ride"
        case .ride: "Ride the \(leg.fromName) → \(leg.toName)"
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
                // Rail/bus are TOGGLES: tinted while active, tap again to turn
                // off (back to drive-only choices).
                transitToggle(rail: true, symbol: "tram.fill",
                              help: "Rail option: local rail/subway, or Amtrak for long trips")
                transitToggle(rail: false, symbol: "bus.fill",
                              help: "Bus option: local transit, or Greyhound for long trips")
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
            ForEach([true, false].filter { transitOptions[$0] != nil }, id: \.self) { rail in
                if let opt = transitOptions[rail] { transitCard(opt, rail: rail) }
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
