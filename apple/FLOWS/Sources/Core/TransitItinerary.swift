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

    var totalSeconds: TimeInterval { legs.compactMap(\.seconds).reduce(0, +) }
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
}

/// Rental cars at the FAR END of a transit trip — the traveller rode the
/// train/bus, so they arrive without a car; the last-mile walk works for a
/// hotel but not for a week of errands. Offices come from MKLocalSearch
/// (keyless, the same source as every POI pick) near the destination; this
/// type ranks them and supplies a booking link. Any operator MapKit knows
/// appears — Hertz, Enterprise, a local independent — biggest brands first.
enum RentalCars {
    struct Office {
        let name: String
        let miles: Double        // from the trip destination
        let url: URL?            // office's own page, else the brand's site
    }

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

    /// Keyless booking fallback when MapKit has no office URL: the brand's
    /// own reservation site. Unrecognized brands get nil (the row still
    /// shows — name + distance are useful without a link).
    static func bookingURL(name: String?) -> URL? {
        let site = flows_rides_rental_booking_site(name ?? "", name != nil).text
        return site.isEmpty ? nil : URL(string: site)
    }

    /// Compare prices across brands in one place. FLOWS's partner link, so a
    /// booking made from here is credited to it; the brand rows beside it
    /// still go to each company's own site.
    static var compareURL: URL? {
        URL(string: flows_rides_rental_compare_url().text)
    }

    /// The same, for ONE place: the partner's own landing page for that city
    /// ("…/usa-wisconsin/milwaukee?a_aid=FAWN"), built the way their
    /// landing-page generator builds it. A place FLOWS cannot name that way
    /// falls back to `compareURL`.
    static func compareURL(near placemark: CLPlacemark?) -> URL? {
        guard let placemark else { return compareURL }
        return compareURL(country: placemark.isoCountryCode ?? "",
                          region: placemark.administrativeArea ?? "",
                          city: placemark.locality ?? placemark.subAdministrativeArea ?? "")
    }

    /// The same from a place FLOWS already names itself — an airport in its
    /// own table carries its country, state and city.
    static func compareURL(country: String, region: String, city: String) -> URL? {
        URL(string: flows_rides_rental_landing_url(country, region, city).text) ?? compareURL
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

/// The three transit toggles on the Routes card. Rail/bus route through
/// stations; plane boards at the nearest commercial airports.
enum TransitMode: CaseIterable, Hashable { case rail, bus, plane }

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
        /// Plain words for what pulls up: "Bus", "Train", "Subway".
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
