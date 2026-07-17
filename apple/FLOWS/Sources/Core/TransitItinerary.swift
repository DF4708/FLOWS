// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
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
        switch mode {
        case "Amtrak": return 1.45     // intercity rail, transfer-heavy long-haul
        case "Greyhound": return 1.35  // intercity coach: highway + terminal dwell
        case "Rail": return 1.30       // local/commuter rail + subway
        default: return 2.00           // local bus: frequent stops, headways
        }
    }

    /// Fallback effective speed (mph) when there is no drivable base time —
    /// distance ÷ this. Deliberately conservative; exact times need GTFS.
    /// Kept MONOTONIC with `rideMultiplier`: within a comparable pair the
    /// higher-overhead mode also has the lower speed, so which mode is "slower"
    /// never flips between the drive-scaled path and this fallback path
    /// (intercity: Amtrak 40 < Greyhound 44; local: Bus 12 < Rail 22).
    static func fallbackMPH(_ mode: String) -> Double {
        switch mode {
        case "Amtrak": return 40
        case "Greyhound": return 44
        case "Rail": return 22
        default: return 12
        }
    }

    /// Ride seconds: scale a real drive time by the mode's door-to-door
    /// overhead; fall back to distance ÷ effective speed when no drivable
    /// path exists. A transparent, mode-differentiated estimate that replaces
    /// Apple's opaque `.transit` ETA — labelled an estimate until GTFS lands.
    static func rideDuration(
        mode: String, driveSeconds: TimeInterval?, miles: Double
    ) -> TimeInterval {
        if let d = driveSeconds, d > 0 { return d * rideMultiplier(mode) }
        let mph = fallbackMPH(mode)
        return mph > 0 && miles > 0 ? miles / mph * 3600 : 0
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
    static let brandOrder: [String] = [
        "enterprise", "hertz", "avis", "budget", "national", "alamo",
        "sixt", "thrifty", "dollar", "zipcar", "turo", "u-haul",
    ]

    /// Index into the brand table (case-insensitive substring), or count
    /// (= after every known brand) when unrecognized.
    static func brandRank(name: String?) -> Int {
        guard let lower = name?.lowercased(), !lower.isEmpty
        else { return brandOrder.count }
        return brandOrder.firstIndex(where: { lower.contains($0) })
            ?? brandOrder.count
    }

    /// Keyless booking fallback when MapKit has no office URL: the brand's
    /// own reservation site. Unrecognized brands get nil (the row still
    /// shows — name + distance are useful without a link).
    static func bookingURL(name: String?) -> URL? {
        guard let lower = name?.lowercased() else { return nil }
        let sites: [(String, String)] = [
            ("enterprise", "https://www.enterprise.com"),
            ("hertz", "https://www.hertz.com"),
            ("avis", "https://www.avis.com"),
            ("budget", "https://www.budget.com"),
            ("national", "https://www.nationalcar.com"),
            ("alamo", "https://www.alamo.com"),
            ("sixt", "https://www.sixt.com"),
            ("thrifty", "https://www.thrifty.com"),
            ("dollar", "https://www.dollar.com"),
            ("zipcar", "https://www.zipcar.com"),
            ("turo", "https://turo.com"),
            ("u-haul", "https://www.uhaul.com"),
        ]
        return sites.first(where: { lower.contains($0.0) })
            .flatMap { URL(string: $0.1) }
    }

    /// Pick the offices worth showing: nearest office PER BRAND (an
    /// Enterprise downtown and one at the airport are the same booking),
    /// ordered by brand size then distance, capped at three. Unknown local
    /// agencies keep their own name as the dedupe key so two different
    /// independents both survive.
    static func recommend(_ offices: [Office], limit: Int = 3) -> [Office] {
        var bestPerBrand: [String: Office] = [:]
        for o in offices {
            let rank = brandRank(name: o.name)
            let key = rank < brandOrder.count
                ? brandOrder[rank] : o.name.lowercased()
            if let held = bestPerBrand[key], held.miles <= o.miles { continue }
            bestPerBrand[key] = o
        }
        return bestPerBrand.values
            .sorted {
                let (ra, rb) = (brandRank(name: $0.name), brandRank(name: $1.name))
                return ra != rb ? ra < rb : $0.miles < $1.miles
            }
            .prefix(limit).map { $0 }
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
            return ("Buy Amtrak ticket: \(ride)", URL(string: "https://www.amtrak.com/tickets"))
        case "Greyhound":
            return ("Buy Greyhound ticket: \(ride)", URL(string: "https://www.greyhound.com"))
        case "Rail":
            return ("Rail fare: \(ride)", stationURL)
        default:
            return ("Bus fare: \(ride)", stationURL)
        }
    }
}
