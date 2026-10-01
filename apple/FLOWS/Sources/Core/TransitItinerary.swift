// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import MapKit

/// A multi-leg public-transit itinerary drawn and stepped IN FLOWS — not handed
/// off to Apple Maps. Three legs:
///   1. WALK from the start to the boarding station — or DRIVE + park when the
///      station is beyond a reasonable walk (a suburban start with a
///      downtown-only terminal produced a "5 h 14 m walk" leg; the traveller
///      has a car at the START, so park-and-ride is the honest first leg),
///   2. the intercity RIDE (rail/bus),
///   3. WALK from the ARRIVAL station to the destination.
/// Leg 3 is the important one: the traveller took the train, so they do NOT
/// have their car at the far end — the last mile is a walk (or local transit),
/// never a drive. MapKit supplies real geometry + turn-by-turn for the WALK
/// legs. The RIDE leg is drawn along the real ground corridor (MapKit's road
/// geometry between stations — exactly what a coach drives, and a close proxy
/// for the rail corridor) and its time is a transparent estimate scaled from
/// the drive time. The exact rail shape and stop-by-stop schedule still need
/// GTFS (Amtrak / VIA Rail / Mobility Database); until that lands the ride is
/// labelled honestly as corridor-approximate.
/// A fare the operator published in its own timetable files — not an
/// estimate. `from` marks the least of several that fit (Cape May–Lewes:
/// adult fares by season).
struct TransitFare: Equatable {
    let cents: Int
    /// ISO 4217: "USD", "CAD".
    let currency: String
    var from: Bool = false

    var amount: Double { Double(cents) / 100 }

    /// "$10.25", "from $10.00", "free" — in the rider's own way of writing
    /// money, for the operator's currency.
    func text(locale: Locale = .current) -> String {
        if cents == 0 && !from { return "free" }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = locale
        f.currencyCode = currency
        let money = f.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
        return from ? "from \(money)" : money
    }

    /// Several rides' fares as one, when every one is known and in one
    /// currency — nil otherwise, so a total is never half a guess.
    static func total(_ fares: [TransitFare?]) -> TransitFare? {
        guard let first = fares.first ?? nil else { return nil }
        var cents = 0
        var from = false
        for fare in fares {
            guard let fare, fare.currency == first.currency else { return nil }
            cents += fare.cents
            from = from || fare.from
        }
        return TransitFare(cents: cents, currency: first.currency, from: from)
    }
}

struct TransitLeg: Identifiable {
    enum Kind { case walk, drive, ride }
    let id = UUID()
    let kind: Kind
    let fromName: String
    let toName: String
    let seconds: TimeInterval?
    let miles: Double?
    /// WALK: the real pedestrian route. RIDE: the ground corridor between
    /// stations (MapKit road geometry; a straight link only if unroutable).
    let polyline: MKPolyline?
    /// WALK: MapKit step instructions. RIDE: board / ride / alight.
    let steps: [String]
    /// A city bus or train ridden to or from the main ride (or door to door
    /// on a short trip), from the city's own timetable — not the main ride.
    var local = false
    /// What pulls up on a city ride: "Bus" or "Train".
    var vehicle: String? = nil
    /// A DRIVE leg in a rental car the rider picks up at its start.
    var rental = false
    /// A RIDE's fare as its operator published it; nil when it did not.
    var fare: TransitFare? = nil
}

struct TransitItinerary {
    let mode: String                 // "Amtrak" / "Greyhound" / "Rail" / "Bus"
    let legs: [TransitLeg]
    let fare: Double
    /// For the optional "open the live schedule in Maps" secondary action.
    let mapsDestination: MKMapItem
    /// True rail geometry for the ride leg isn't available yet (needs GTFS);
    /// the UI shows an honest note when so.
    let rideGeometryIsApproximate: Bool
    /// The ride line came from a real MapKit road route (true) vs. the straight
    /// station-to-station connector fallback (false). Gates the "follows the
    /// roads/corridor" claim so it never overstates a straight-line fallback.
    var rideGeometryIsReal: Bool = true
    /// Every fare in `fare` is the operators' own, published — none estimated.
    var fareIsPublished = false
    /// Door to door once the timetables have answered — see
    /// ``doorToDoor(before:schedule:after:)``. Nil on an estimate.
    var doorToDoorSeconds: TimeInterval? = nil

    /// What the card's header says the trip takes. The legs alone leave out
    /// every wait for a connection: Chicago to Milwaukee by train and two
    /// city buses read 2 h 28 m when its own timetable said 2 h 43 m.
    var totalSeconds: TimeInterval {
        doorToDoorSeconds ?? legs.compactMap(\.seconds).reduce(0, +)
    }

    /// Door to door around a timetable: `before` getting to the first vehicle,
    /// the timetable's own span from boarding it to leaving the last one —
    /// every connection's wait inside it — and `after` from there. The wait
    /// for the first vehicle is not counted: a rider leaves later instead.
    /// Nil without a timetable's clock.
    static func doorToDoor(before: TimeInterval?, schedule: TransitSchedule?,
                           after: TimeInterval?) -> TimeInterval? {
        guard let on = schedule?.boardAt, let off = schedule?.alightAt, off >= on else {
            return nil
        }
        return (before ?? 0) + off.timeIntervalSince(on) + (after ?? 0)
    }

    /// The long ride — the train, coach or flight — as opposed to a city bus
    /// or train ridden to or from it.
    var mainRide: TransitLeg? {
        legs.first { $0.kind == .ride && !$0.local }
    }
}

/// Pure helpers (pinned by FLOWSTests).
enum TransitPlanning {
    /// Straight station-to-station link — the fallback drawn only when MapKit
    /// can't route the ground corridor (e.g. an over-water leg with no ferry).
    static func connector(
        _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D
    ) -> MKPolyline {
        var pts = [a, b]
        return MKPolyline(coordinates: &pts, count: 2)
    }

    /// Door-to-door overhead vs. solo driving: a scheduled service is slower
    /// than a car over the same corridor (station dwell, intermediate stops,
    /// transfers, boarding). Applied to a real MapKit drive time so the ride
    /// estimate is anchored to measured road data, not a guessed speed.
    /// Long-haul US rail rides slower than a bus here — circuitous track and
    /// mandatory transfers (e.g. Miami→NYC→Toronto) — so its factor is higher.
    static func rideMultiplier(_ mode: String) -> Double {
        flows_rides_ride_multiplier(mode)
    }

    /// Fallback effective speed (mph) when there is no drivable base time —
    /// distance ÷ this. Deliberately conservative; exact times need GTFS.
    /// Kept MONOTONIC with `rideMultiplier` (flows_core::travel_modes).
    static func fallbackMPH(_ mode: String) -> Double {
        flows_rides_fallback_mph(mode)
    }

    /// Ride seconds: scale a real drive time by the mode's door-to-door
    /// overhead; fall back to distance ÷ effective speed when no drivable
    /// path exists. A transparent, mode-differentiated estimate that replaces
    /// Apple's opaque `.transit` ETA — labelled an estimate until GTFS lands.
    static func rideDuration(
        mode: String, driveSeconds: TimeInterval?, miles: Double
    ) -> TimeInterval {
        flows_rides_ride_duration(mode, driveSeconds ?? 0, driveSeconds != nil, miles)
    }

    /// Board / ride / alight instructions for the ride leg.
    static func rideSteps(
        mode: String, board: String, alight: String, seconds: TimeInterval?
    ) -> [String] {
        ["Board the \(shownName(mode)) at \(board)",
         "Ride \(durationPhrase(seconds))",
         "Get off at \(alight)"]
    }

    /// What a ride is called on a card. Every coach between cities was
    /// called "Greyhound", though Badger Bus, Jefferson Lines and others run
    /// many of those routes (Badger Bus is Milwaukee to Madison) — "intercity
    /// bus" is true of all of them. The mode key stays, for the fares and
    /// times it selects.
    static func shownName(_ mode: String) -> String {
        mode == "Greyhound" ? "intercity bus" : mode
    }

    static func durationPhrase(_ s: TimeInterval?) -> String {
        guard let s, s > 0 else { return "(check the schedule)" }
        let m = Int(s / 60)
        return m >= 90 ? "about \(m / 60)h \(m % 60)m" : "about \(m) min"
    }

    /// Compact leg-time label.
    static func fmt(_ s: TimeInterval?) -> String {
        guard let s else { return "—" }
        let m = Int(s / 60)
        return m >= 90 ? String(format: "%dh %02dm", m / 60, m % 60) : "\(m) min"
    }

    /// A city ride as a rider says it: "the 30 bus", "the 12 Teutonia Avenue
    /// bus", "the Blue Line", "the bus". A name that is or starts with a route
    /// number reads before the vehicle; a line's own name needs no vehicle
    /// word.
    static func cityRide(vehicle: String, name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let word = vehicle.lowercased()
        if trimmed.isEmpty || trimmed.lowercased() == word { return "the \(word)" }
        let numbered = trimmed.first?.isNumber ?? false
        return numbered || trimmed.count <= 4 ? "the \(trimmed) \(word)" : "the \(trimmed)"
    }

    /// The symbol for a city vehicle: a bus for "Bus", a ferry for "Ferry", a
    /// train otherwise.
    static func vehicleSymbol(_ vehicle: String?) -> String {
        switch vehicle {
        case "Bus": return "bus.fill"
        case "Ferry": return "ferry.fill"
        default: return "tram.fill"
        }
    }

    /// The third line of a drive-and-park leg: what happens at the far end,
    /// now that the car stays behind.
    static func farEndNote(_ egress: TripShape.Egress) -> String {
        switch egress {
        case .walk: return "Your car stays here — the far end is on foot"
        case .local: return "Your car stays here — take the city bus or train at the far end"
        case .rental: return "Your car stays here — a rental car waits at the far end"
        case .rentOrRide: return "Your car stays here — rent or ride at the far end"
        }
    }
}

/// Rental cars at the FAR END of a transit trip — the traveller rode the
/// train/bus, so they arrive without a car; the last-mile walk works for a
/// hotel but not for a week of errands. Offices come from MKLocalSearch
/// (keyless, the same source as every POI pick) near the destination; this
/// type ranks them. Any operator MapKit knows appears — Hertz, Enterprise, a
/// local independent — biggest brands first.
///
/// Every booking goes through FLOWS's DiscoverCars partner link (code FAWN):
/// the owner's rule (2026-09-29) for searches and results alike. The offices
/// say who rents cars there and how far away; the partner page is where the
/// rider compares them and books.
/// Rental cars, through FLOWS's DiscoverCars partner links. Every booking
/// goes through the partner page for a PLACE — the counter is whichever
/// company the traveller books there — so FLOWS names the place and never a
/// brand. (The cards once named the nearest counter the map knew, "Rental
/// car from Avis", for a car the traveller might book from Hertz.)
enum RentalCars {
    /// The DiscoverCars city a traveller near a point books a car in — its
    /// name and where it is — or nil when no rental city is near.
    static func pickup(near c: CLLocationCoordinate2D)
        -> (name: String, coordinate: CLLocationCoordinate2D)? {
        let parts = flows_rides_rental_pickup_near(c.latitude, c.longitude).text
            .split(separator: "\u{1F}", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty,
              let lat = Double(parts[1]), let lon = Double(parts[2]) else { return nil }
        return (String(parts[0]), CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    /// Compare prices across brands in one place — FLOWS's partner link, so a
    /// booking made from here is credited to it. The homepage, for when no
    /// place is known.
    static var compareURL: URL? {
        URL(string: flows_rides_rental_compare_url().text)
    }

    /// Where every disclosure of the rental partnership points — the owner's
    /// rule: terms, sources and the Settings disclosure all use this link.
    static var partnerProgramURL: URL? {
        URL(string: flows_rides_rental_partner_program_url().text)
    }

    /// The disclosure, in plain words. FLOWS is paid when someone books
    /// through its links, and anyone reading about the app's sources is told.
    static let partnerDisclosure =
        "FLOWS is paid a fee when you book a rental car through its "
        + "DiscoverCars links."

    /// The partner's page for renting near ONE point: the nearest DiscoverCars
    /// city ("…/usa-wisconsin/milwaukee?a_aid=FAWN"), else its state, else
    /// the homepage. Built from DiscoverCars' own list of places — the map's
    /// names are not theirs (Mexico City is "mexico/mexico"), and links
    /// guessed from map names landed on 404s.
    static func compareURL(near coordinate: CLLocationCoordinate2D) -> URL? {
        URL(string: flows_rides_rental_landing_near(coordinate.latitude, coordinate.longitude).text)
            ?? compareURL
    }

    /// The arrival airport's own rental page ("…/usa-illinois/chicago/ord")
    /// when DiscoverCars lists it; otherwise the best page near the airport.
    static func compareURL(airport code: String, at coordinate: CLLocationCoordinate2D) -> URL? {
        URL(string: flows_rides_rental_landing_airport(code, coordinate.latitude,
                                                       coordinate.longitude).text)
            ?? compareURL
    }

}

/// The EXACT ticket to buy for a transit itinerary — carrier booking page +
/// a label naming the precise ride (board → alight), so FLOWS directs the
/// traveler to the purchase instead of handing off to Maps.
enum TransitTickets {
    /// (label, url) for the ride leg. Long-haul modes go to the carrier's
    /// booking site; local transit uses the boarding station's own page when
    /// MapKit knows it (usually the agency), else nil (fares are on-board /
    /// agency-app for most local systems — the label still names the ride).
    static func ticket(mode: String, board: String, alight: String,
                       stationURL: URL? = nil) -> (label: String, url: URL?) {
        let ride = "\(board) → \(alight)"
        switch mode {
        case "Amtrak":
            // amtrak.com/tickets opens a page with nothing on it but the
            // menus — the owner pressed it and got exactly that. The
            // boarding station's own Amtrak page is the useful one (times,
            // services, and the booking form); their front page, which
            // carries that form, is the fallback.
            return ("Buy Amtrak ticket: \(ride)",
                    amtrakStationURL(stationURL) ?? URL(string: "https://www.amtrak.com"))
        case "Greyhound":
            // Where Greyhound itself says to buy, in its own schedule feed.
            return ("Bus tickets, Greyhound and partner lines: \(ride)",
                    URL(string: "https://shop.greyhound.com"))
        case "Rail":
            return ("Rail fare: \(ride)", stationURL)
        default:
            return ("Bus fare: \(ride)", stationURL)
        }
    }

    /// The station's own page on amtrak.com, when that is what the map knew
    /// about it ("amtrak.com/stations/mke"). Any other site — a city page, a
    /// transit agency — is not an Amtrak ticket and is left alone.
    static func amtrakStationURL(_ url: URL?) -> URL? {
        guard let url, let host = url.host()?.lowercased(),
              host == "amtrak.com" || host.hasSuffix(".amtrak.com") else { return nil }
        return url
    }
}

/// The toggles on the Routes card: train, bus, plane, a ship and a rental
/// car. Any mix of them is ONE trip — `TripShape` says how the pieces fit
/// together.
enum TransitMode: CaseIterable, Hashable { case rail, bus, plane, ship, rental }

/// What the rider means by the toggles they switched on, read as one trip by
/// `flows_core::trip_shape` — the owner's rule, pinned there by a test for
/// every combination. "Car, bus and train" drives to the train and takes the
/// bus from it; "walk, bus and plane" rides the bus to the airport and from
/// it — unless a rental car is on too, which is then picked up where the
/// plane lands.
struct TripShape: Equatable {
    /// The long way. `short` is a trip with none: the city's own buses and
    /// trains, or a rental car, go door to door.
    enum Main: Int { case short = 0, plane, train, coach, ship }
    /// How the rider reaches the main ride.
    enum Access: Int {
        /// Walk when the station is close, drive and park when it is not.
        case ownCar = 0
        /// Walk, with a ride share offered when the walk is long.
        case onFoot
        /// The city's buses or trains, when they beat walking.
        case local
    }
    /// How the rider gets from the main ride to where they are going.
    enum Egress: Int { case walk = 0, local, rental, rentOrRide }

    let main: Main
    let access: Access
    let egress: Egress
    /// What the far end becomes when the city has no timetable, or its buses
    /// and trains do not beat walking.
    let egressFallback: Egress
    /// The city vehicles the rider accepts, as the timetable's mode bits —
    /// handed straight to `TransitShard.departures(vehicles:)`.
    let localVehicles: Int
    let cards: Int
    /// The one kind of city vehicle the rider chose — "bus" or "train" — or
    /// nil when they chose both or neither. Names it when another kind has
    /// to carry a leg.
    let cityChoice: String?

    /// The whole trip — main ride and both ends — on one card.
    static let cardMain = 1
    /// A short trip on the city's buses and trains, door to door.
    static let cardLocal = 2
    /// A short trip in a rental car picked up near the start.
    static let cardRental = 4
    /// The plane was on, but this is not a trip to fly: its card says why.
    static let cardPlaneNote = 8

    init(onFoot: Bool, modes: Set<TransitMode>, tripMiles: Double) {
        let packed = flows_transit_trip_shape(
            onFoot, modes.contains(.rail), modes.contains(.bus), modes.contains(.plane),
            modes.contains(.rental), modes.contains(.ship), tripMiles)
        func byte(_ index: Int64) -> Int { Int((packed >> (8 * index)) & 0xFF) }
        main = Main(rawValue: byte(0)) ?? .short
        access = Access(rawValue: byte(1)) ?? .ownCar
        egress = Egress(rawValue: byte(2)) ?? .walk
        egressFallback = Egress(rawValue: byte(3)) ?? .walk
        localVehicles = byte(4)
        cards = byte(5)
        switch (modes.contains(.bus), modes.contains(.rail)) {
        case (true, false): cityChoice = "bus"
        case (false, true): cityChoice = "train"
        default: cityChoice = nil
        }
    }

    func shows(_ card: Int) -> Bool { cards & card != 0 }

    /// The card that holds the whole trip, keyed by its main ride.
    var mainMode: TransitMode? {
        switch main {
        case .plane: return .plane
        case .train: return .rail
        case .coach: return .bus
        case .ship: return .ship
        case .short: return nil
        }
    }

    /// The key of a short trip's city card: the bus when it was chosen, the
    /// train when only the train was.
    static func localMode(_ modes: Set<TransitMode>) -> TransitMode {
        modes.contains(.bus) ? .bus : .rail
    }

    /// The toggles a card stands for, so its X turns off exactly those. The
    /// whole-trip card is every toggle but a plane that only left a note.
    func modes(ofCard key: TransitMode, active: Set<TransitMode>) -> Set<TransitMode> {
        if key == mainMode {
            return shows(Self.cardPlaneNote) ? active.subtracting([.plane]) : active
        }
        switch key {
        case .plane: return [.plane]
        case .ship: return [.ship]
        case .rental: return [.rental]
        case .rail, .bus: return active.intersection([.rail, .bus])
        }
    }

    /// Past this many miles a train or bus toggle means the intercity service.
    static var longHaulMiles: Double { flows_transit_long_haul_miles() }

    /// A walk to a station longer than this is driven, or offered a ride share.
    static var farWalkSeconds: TimeInterval { flows_transit_far_walk_seconds() }

    /// The mask that boards every city vehicle.
    static var allVehicles: Int { Int(flows_transit_all_vehicles()) }

    /// The mask of the vehicles that float — ferries, water taxis.
    static var shipVehicles: Int { Int(flows_transit_ship_vehicles()) }

    /// The city's buses and trains, never a ship: what stands in for a chosen
    /// bus or train that cannot make a leg.
    static var landVehicles: Int { Int(flows_transit_land_vehicles()) }

    /// Whether a city trip on any vehicle, taking `otherSeconds`, should
    /// replace the one on the chosen vehicles (nil: they cannot make it).
    static func otherVehicleWins(chosenSeconds: TimeInterval?,
                                 otherSeconds: TimeInterval) -> Bool {
        flows_transit_other_vehicle_wins(chosenSeconds ?? 0, chosenSeconds != nil, otherSeconds)
    }

    /// Whether a city ride taking `transitSeconds` door to door (waiting
    /// included) should replace a walk of `walkSeconds`.
    static func transitBeatsWalk(walkSeconds: TimeInterval?,
                                 transitSeconds: TimeInterval) -> Bool {
        flows_transit_beats_walk(walkSeconds ?? 0, walkSeconds != nil, transitSeconds)
    }
}

/// The real published times for a ride, read from the operator's own schedule.
///
/// Everything else on a transit card is FLOWS estimating — a road-corridor
/// proxy for the track, a fare fitted from published averages. This is not an
/// estimate: it is the timetable, so it says the train, the clock, and who
/// published it, and the card presents it as different in kind.
struct TransitSchedule: Equatable {
    /// One vehicle the traveller actually gets on.
    ///
    /// A trip that rides a connecting bus and then a train is two of these,
    /// and both belong on screen: the bus IS the last leg for the 110 towns
    /// Amtrak reaches only by coach, and folding it into "1 change" is how
    /// someone stands on a platform waiting for a train that was never coming.
    struct Leg: Equatable {
        /// "9:35 AM – 11:45 AM", in each end's own clock.
        let clockSpan: String
        /// Plain words for what pulls up: "Bus" or "Train".
        let vehicle: String
        /// What the operator calls the service, when it says more than the
        /// vehicle word does.
        let name: String
        let boardName: String
        let alightName: String

        /// "Bus · Amtrak Thruway Connecting Service", or plain "Train" when
        /// the service has no name worth repeating.
        var vehicleLine: String {
            name.isEmpty || name == vehicle ? vehicle : "\(vehicle) · \(name)"
        }
    }

    /// Each vehicle in order. Always at least one.
    let legs: [Leg]
    /// The stations the timetable actually uses, which may not be the ones a
    /// map search picked.
    let boardName: String
    let alightName: String
    /// What the operator calls the service — "Hiawatha Service".
    let routeName: String
    /// "6:15 AM – 7:57 AM", with the zone named when the trip crosses one.
    let clockSpan: String
    /// How long the ride itself takes, by the timetable.
    let rideSeconds: TimeInterval
    /// Departure times after this one today, already on a clock face.
    let laterClocks: [String]
    /// "Schedule from Amtrak" — shown wherever its times are.
    let credit: String
    /// "Times as of Sep 22", so a rider can judge how fresh this is.
    let asOf: String
    /// When the first vehicle leaves and the last one arrives, with each
    /// end's zone — what joining several operators' times into one trip
    /// needs. Nil on a schedule that was not built from a timetable.
    var boardAt: Date? = nil
    var boardZone: String = ""
    var alightAt: Date? = nil
    var alightZone: String = ""
    /// The operators whose times these are, as riders know them.
    var operators: [String] = []

    /// One trip's timetables in the order they are ridden — a city bus to the
    /// station, the train, a city bus from it — as ONE schedule: every
    /// vehicle named, one clock door to door, every operator credited.
    ///
    /// "Then 8:15 AM" is dropped from a joined schedule: a later train does
    /// not bring a later bus with it, so the line would promise a trip no
    /// timetable was asked about.
    static func joined(_ parts: [TransitSchedule], locale: Locale = .current) -> TransitSchedule? {
        guard let first = parts.first, let last = parts.last else { return nil }
        if parts.count == 1 { return first }
        let legs = parts.flatMap(\.legs)
        guard !legs.isEmpty else { return nil }
        var operators: [String] = []
        for name in parts.flatMap(\.operators) where !operators.contains(name) {
            operators.append(name)
        }
        var credits: [String] = []
        for credit in parts.map(\.credit) where !credit.isEmpty && !credits.contains(credit) {
            credits.append(credit)
        }
        let span: String
        let seconds: TimeInterval
        if let on = first.boardAt, let off = last.alightAt {
            span = TransitClock.span(board: on, boardZone: first.boardZone,
                                     alight: off, alightZone: last.alightZone, locale: locale)
            seconds = off.timeIntervalSince(on)
        } else {
            span = "\(first.clockSpan) … \(last.clockSpan)"
            seconds = parts.map(\.rideSeconds).reduce(0, +)
        }
        let changes = legs.count - 1
        return TransitSchedule(
            legs: legs,
            boardName: first.boardName,
            alightName: last.alightName,
            routeName: changes == 0 ? first.routeName
                : (changes == 1 ? "1 change" : "\(changes) changes"),
            clockSpan: span,
            rideSeconds: seconds,
            laterClocks: [],
            // Named operator by operator when every part says who it is from;
            // otherwise each part's own credit line, so none goes missing.
            credit: parts.allSatisfy { !$0.operators.isEmpty }
                ? TransitFeeds.credit(for: operators) : credits.joined(separator: " · "),
            asOf: parts.first { !$0.asOf.isEmpty }?.asOf ?? "",
            boardAt: first.boardAt,
            boardZone: first.boardZone,
            alightAt: last.alightAt,
            alightZone: last.alightZone,
            operators: operators)
    }

    /// One plain line for the card. No jargon, no station codes.
    var plainLine: String {
        routeName.isEmpty ? clockSpan : "\(clockSpan) · \(routeName)"
    }

    /// "Then 8:15 AM, 10:15 AM" — empty when this is the last one today.
    var laterLine: String {
        laterClocks.isEmpty ? "" : "Then " + laterClocks.joined(separator: ", ")
    }
}

/// One computed transit option — the content of a rail/bus/plane card.
/// Lives on AppModel (not view @State): rotating the phone flips the size
/// class, which rebuilds the chrome tree and would clear view-local state
/// mid-choice.
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
    /// Real times from the operator's timetable, once it has been read. Nil
    /// until then — the card shows its estimate immediately and this arrives
    /// after, so a schedule download never holds the choices up.
    var schedule: TransitSchedule?
    /// Where to book a car at the far end — the traveller arrives WITHOUT
    /// one: the partner's page for the city (or airport) they get off in, so
    /// a booking made from the card is credited to FLOWS.
    var rentalCompareURL: URL? = RentalCars.compareURL
    /// The DiscoverCars place that page books in ("Madison"), when known.
    var rentalPlace: String? = nil
    /// Plain lines the rider should read before the legs — a city train
    /// standing in for the bus they chose, and why.
    var notes: [String] = []
    /// Searches a card can offer when FLOWS has no timetable to show — the
    /// ferries and cruises the ship card points to.
    var links: [LabeledLink] = []
    /// The plane card for a trip too short to fly: it says so, and offers
    /// the flights anyway for a rider who wants to see them.
    var offersFlightsAnyway = false
}

/// A link with the words a card shows for it.
struct LabeledLink: Hashable {
    let label: String
    let url: URL
}

/// Ships: ferries and water taxis publish timetables, and the ship card reads
/// them (`TransitFeeds.shipSources`). Cruise lines publish none, so a cruise
/// is a terminal the map can find and a search the rider can open — nothing
/// booked for them, nothing guessed.
enum ShipTravel {
    /// How far from each end a ferry terminal may be: about a half-hour drive.
    static let terminalReachMeters = 40_000.0
    /// How far from the start a cruise terminal may be and still be offered.
    static let cruiseReachMeters = 150_000.0

    /// A ferry the federal ferry census lists (BTS, 2024, public domain)
    /// between a terminal near the start and one near the destination — for
    /// the water no timetable feed covers. It says who runs it, how long a
    /// crossing takes, when in the year it sails and whether cars go aboard;
    /// never the times, which the card sends the rider to the operator for.
    struct Crossing: Equatable {
        let route: String
        let operatorName: String
        let operatorURL: URL?
        let boardName: String
        let boardCoordinate: CLLocationCoordinate2D
        let alightName: String
        let alightCoordinate: CLLocationCoordinate2D
        /// A typical crossing; nil when the census has none.
        let minutes: Int?
        /// [first month, day, last month, day]; nil when not reported.
        let season: (Int, Int, Int, Int)?
        let crossingsADay: Double
        /// Cars aboard: yes, no, or not reported.
        let cars: Bool?

        static func == (a: Crossing, b: Crossing) -> Bool {
            a.route == b.route && a.operatorName == b.operatorName && a.boardName == b.boardName
        }

        /// Whether it sails on a date, by its season in the rider's calendar.
        /// A season the census did not report counts as sailing.
        func sails(on date: Date, calendar: Calendar = .current) -> Bool {
            guard let (m1, d1, m2, d2) = season else { return true }
            let p = calendar.dateComponents([.month, .day], from: date)
            let at = (p.month ?? 1) * 100 + (p.day ?? 1)
            let (start, end) = (m1 * 100 + d1, m2 * 100 + d2)
            return start <= end ? (start...end).contains(at) : at >= start || at <= end
        }

        /// "May 17 – Oct 6"; nil when it sails all year or the census did
        /// not say.
        func seasonText(locale: Locale = .current) -> String? {
            guard let (m1, d1, m2, d2) = season, !(m1 == 1 && d1 == 1 && m2 == 12 && d2 == 31)
            else { return nil }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC") ?? .current
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = cal.timeZone
            f.setLocalizedDateFormatFromTemplate("MMMd")
            func day(_ m: Int, _ d: Int) -> String? {
                cal.date(from: DateComponents(year: 2025, month: m, day: d)).map(f.string(from:))
            }
            guard let a = day(m1, d1), let b = day(m2, d2) else { return nil }
            return "\(a) – \(b)"
        }
    }

    /// The census ferries from a terminal within `reachMeters` of `start`
    /// to one within it of `end`, least ground to cover first.
    static func crossings(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D,
                          reachMeters: Double = terminalReachMeters,
                          limit: Int = 3) -> [Crossing] {
        var out: [Crossing] = []
        for row in flows_transit_ferry_crossings(start.latitude, start.longitude,
                                                 end.latitude, end.longitude,
                                                 reachMeters, Int64(limit)) {
            let f = row.as_str().toString()
                .split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 20, f[0] == "ferry",
                  let bLat = Double(f[6]), let bLon = Double(f[7]),
                  let aLat = Double(f[10]), let aLon = Double(f[11])
            else { continue }
            let minutes = Int(f[12]).flatMap { $0 > 0 ? $0 : nil }
            let season: (Int, Int, Int, Int)? = {
                guard let m1 = Int(f[14]), let d1 = Int(f[15]), let m2 = Int(f[16]),
                      let d2 = Int(f[17]), m1 > 0, m2 > 0 else { return nil }
                return (m1, d1, m2, d2)
            }()
            func place(_ name: String, _ city: String) -> String {
                city.isEmpty || name.localizedCaseInsensitiveContains(city) ? name : "\(name), \(city)"
            }
            out.append(Crossing(
                route: f[1], operatorName: f[2],
                operatorURL: f[3].isEmpty ? nil : URL(string: f[3]),
                boardName: place(f[4], f[5]),
                boardCoordinate: CLLocationCoordinate2D(latitude: bLat, longitude: bLon),
                alightName: place(f[8], f[9]),
                alightCoordinate: CLLocationCoordinate2D(latitude: aLat, longitude: aLon),
                minutes: minutes, season: season,
                crossingsADay: Double(f[18]) ?? 0,
                cars: f[19] == "1" ? true : f[19] == "0" ? false : nil))
        }
        return out
    }

    /// Whether a ferry that lands at `landing` is the way from `start` to
    /// `end`: it must leave the rider well on — within 60% of the distance
    /// they started from, or 2 km. Seattle's water taxi lands in West
    /// Seattle, eleven kilometres from Bainbridge Island, and was offered
    /// as the way there when no other boat's timetable was read.
    static func sailingHelps(start: CLLocationCoordinate2D, landing: CLLocationCoordinate2D,
                             end: CLLocationCoordinate2D) -> Bool {
        func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
            CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }
        return meters(landing, end) <= max(2_000, 0.6 * meters(start, end))
    }

    /// The rider's word for a place, or nil when it names no place ("Current
    /// location", "your start"), which a search could not use.
    static func placeWord(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        guard !trimmed.isEmpty, !lower.hasPrefix("current"), !lower.hasPrefix("your ") else {
            return nil
        }
        return trimmed
    }

    /// A web search for ferries between two places — from the start when it
    /// has a name, else to the destination alone.
    static func ferrySearchURL(from: String, to: String) -> URL? {
        guard let there = placeWord(to) else { return nil }
        let query = placeWord(from).map { "ferry from \($0) to \(there)" } ?? "ferry to \(there)"
        return search(query)
    }

    /// A web search for cruises leaving a terminal, toward a place when it
    /// has a name.
    static func cruiseSearchURL(from terminal: String, toward: String) -> URL? {
        guard let port = placeWord(terminal) else { return nil }
        return search(placeWord(toward).map { "cruises from \(port) to \($0)" }
                      ?? "cruises from \(port)")
    }

    /// Whether a map result reads as a cruise terminal: it says "cruise", or
    /// it is a port by name ("Port Everglades", "PortMiami") — and not an
    /// airport, whose name holds "port" inside another word.
    static func isCruiseTerminal(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("portmiami") { return true }
        let words = lower.split { !$0.isLetter }.map(String.init)
        return words.contains("cruise") || words.contains("cruises") || words.contains("port")
    }

    private static func search(_ query: String) -> URL? {
        var parts = URLComponents(string: "https://www.google.com/search")
        parts?.queryItems = [URLQueryItem(name: "q", value: query)]
        return parts?.url
    }
}

/// The walk + paid-ride card's computed pieces (walking mode only). On the
/// model for the same rotation-survival reason as TransitOption.
struct HybridOption {
    let walkAloneSeconds: TimeInterval
    let offer: HybridWalk.Offer
    let uberURL: URL?
    let lyftURL: URL?
    let itinerary: TransitItinerary
}
