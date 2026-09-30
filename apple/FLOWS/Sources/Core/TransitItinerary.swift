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
        ["Board the \(mode) at \(board)",
         "Ride \(durationPhrase(seconds))",
         "Get off at \(alight)"]
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

    /// The symbol for a city vehicle: a bus for "Bus", a train otherwise.
    static func vehicleSymbol(_ vehicle: String?) -> String {
        vehicle == "Bus" ? "bus.fill" : "tram.fill"
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
enum RentalCars {
    struct Office {
        let name: String
        let miles: Double        // from where the rider picks the car up
        /// Where the counter is, so a rider can be routed to it.
        var coordinate: CLLocationCoordinate2D? = nil
    }

    /// How far a counter may be from where the rider picks the car up and
    /// still be listed — the edge of the 30 km box the map is asked about.
    static let maxOfficeMiles = 20.0

    /// US rental-brand order (fleet size / market share; lower = bigger).
    /// Enterprise Holdings brands lead (Enterprise/National/Alamo), then
    /// Hertz group (Hertz/Dollar/Thrifty), then Avis Budget, then the rest;
    /// unknown local agencies sort after every recognized brand.
    static let brandOrder: [String] = {
        // flows_core::recents_and_rides::RENTAL_BRANDS, split by UTF-8 length.
        let joined = Array(flows_rides_rental_brands().text.utf8)
        var at = 0
        return flows_rides_rental_brand_lengths().map { length in
            let end = at + Int(length)
            defer { at = end }
            return String(decoding: joined[at..<end], as: UTF8.self)
        }
    }()

    /// Index into the brand table (case-insensitive substring), or count
    /// (= after every known brand) when unrecognized.
    static func brandRank(name: String?) -> Int {
        Int(flows_rides_rental_brand_rank(name ?? "", name != nil))
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

    /// Pick the offices worth showing: nearest office PER BRAND (an
    /// Enterprise downtown and one at the airport are the same booking),
    /// ordered by brand size then distance, capped at three. Unknown local
    /// agencies keep their own name as the dedupe key so two different
    /// independents both survive.
    static func recommend(_ offices: [Office], limit: Int = 3) -> [Office] {
        // flows_core::recents_and_rides::recommend_rentals. Offices that do
        // not order (same brand rank, equal or unknown miles) keep the order
        // their brands first appeared; Swift's Dictionary left them to the
        // launch's hash seed.
        let names = RustTextColumn(offices.map(\.name))
        let miles = offices.isEmpty ? [0] : offices.map(\.miles)
        let picks = names.with { joined, lengths, _ in
            miles.withUnsafeBufferPointer { m in
                Array(flows_rides_recommend_rentals(joined, lengths, m, Int64(offices.count),
                                                    Int64(limit)))
            }
        }
        return picks.map { offices[Int($0)] }
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
            return ("Buy Greyhound ticket: \(ride)",
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

/// The toggles on the Routes card: train, bus, plane and a rental car. Any
/// mix of them is ONE trip — `TripShape` says how the pieces fit together.
enum TransitMode: CaseIterable, Hashable { case rail, bus, plane, rental }

/// What the rider means by the toggles they switched on, read as one trip by
/// `flows_core::trip_shape` — the owner's rule, pinned there by a test for
/// every combination. "Car, bus and train" drives to the train and takes the
/// bus from it; "walk, bus and plane" rides the bus to the airport and from
/// it — unless a rental car is on too, which is then picked up where the
/// plane lands.
struct TripShape: Equatable {
    /// The long way. `short` is a trip with none: the city's own buses and
    /// trains, or a rental car, go door to door.
    enum Main: Int { case short = 0, plane, train, coach }
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
            modes.contains(.rental), tripMiles)
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
    /// Rental counters near the destination — the traveller arrives
    /// WITHOUT a car (that's the whole point of leg 3 being a walk).
    var rentals: [RentalCars.Office] = []
    /// Compare those counters' prices in one place — the partner's landing
    /// page for the city the traveller gets off in, so a booking made from
    /// the card is credited to FLOWS.
    var rentalCompareURL: URL? = RentalCars.compareURL
    /// Plain lines the rider should read before the legs — a city train
    /// standing in for the bus they chose, and why.
    var notes: [String] = []
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
