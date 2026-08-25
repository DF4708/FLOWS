// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// The walk + paid-ride option (pinned by FLOWSTests). When the planner is in
/// walking mode the traveler has said "no car, no fare" — so a rideshare
/// segment is offered ONLY when the numbers clear a significance bar: the
/// ride must cut the door-to-door time by at least 40% AND cost at most $25
/// (estimated), AND save enough absolute minutes to matter. Anything less is
/// money the walker didn't want to spend.
///
/// Cost model: flat pickup fee + per-mile rate, in line with published
/// US rideshare averages. Always labelled an estimate — Uber/Lyft price
/// dynamically and set the real fare.
enum HybridWalk {
    static let baseFareUSD = 3.0
    static let perMileUSD = 1.10
    /// The walker's wallet cap — a ride estimated over this is never offered.
    static let costCapUSD = 25.0
    /// The significance bar: the ride must cut total time by at least this
    /// fraction of the walk-alone time…
    static let minSavedFraction = 0.40
    /// …and by at least this many seconds, so a 4-minute "40% saving" on a
    /// ten-minute stroll never pitches a fare.
    static let minSavedSeconds: TimeInterval = 15 * 60
    /// Walks shorter than this never get a ride offer at all.
    static let minWalkAloneSeconds: TimeInterval = 30 * 60

    static func rideCostUSD(miles: Double) -> Double {
        baseFareUSD + perMileUSD * miles
    }

    /// Longest ride the cap can buy — the partial-segment length when the
    /// whole trip would blow the budget.
    static var maxAffordableRideMiles: Double {
        (costCapUSD - baseFareUSD) / perMileUSD
    }

    struct Offer: Equatable {
        var rideMiles: Double
        var rideSeconds: TimeInterval
        /// Walk remaining after the drop-off (0 = the ride covers the whole
        /// trip).
        var walkSeconds: TimeInterval
        var costUSD: Double
        var totalSeconds: TimeInterval { rideSeconds + walkSeconds }
    }

    /// The significance rule, on its own so the UI can re-check with real
    /// routed numbers after the estimate passes: affordable AND >= 40% faster
    /// AND >= 15 minutes saved.
    static func meetsBar(walkAloneSeconds: TimeInterval,
                         totalSeconds: TimeInterval,
                         costUSD: Double) -> Bool {
        guard costUSD <= costCapUSD, walkAloneSeconds > 0 else { return false }
        let saved = walkAloneSeconds - totalSeconds
        return saved >= minSavedSeconds
            && saved / walkAloneSeconds >= minSavedFraction
    }

    /// Decide the ride segment for a walking trip. Whole-trip ride when the
    /// cap affords it; otherwise ride the first affordable miles and walk the
    /// rest (pickup at the start is the one place a car is reliably hailable).
    /// The partial walk remainder is prorated from the walk-alone time; the
    /// UI re-routes the real remainder and re-checks `meetsBar`. Returns nil
    /// whenever the bar isn't met — no offer is the default, not the fallback.
    static func evaluate(walkAloneSeconds: TimeInterval,
                         driveSeconds: TimeInterval,
                         tripMiles: Double) -> Offer? {
        guard walkAloneSeconds >= minWalkAloneSeconds,
              driveSeconds > 0, tripMiles > 0 else { return nil }
        let offer: Offer
        if rideCostUSD(miles: tripMiles) <= costCapUSD {
            offer = Offer(rideMiles: tripMiles, rideSeconds: driveSeconds,
                          walkSeconds: 0,
                          costUSD: rideCostUSD(miles: tripMiles))
        } else {
            let rideMiles = maxAffordableRideMiles
            let fraction = rideMiles / tripMiles
            offer = Offer(rideMiles: rideMiles,
                          rideSeconds: driveSeconds * fraction,
                          walkSeconds: walkAloneSeconds * (1 - fraction),
                          costUSD: rideCostUSD(miles: rideMiles))
        }
        guard meetsBar(walkAloneSeconds: walkAloneSeconds,
                       totalSeconds: offer.totalSeconds,
                       costUSD: offer.costUSD) else { return nil }
        return offer
    }

    // -- Drop-off geometry ----------------------------------------------------

    /// The route prefix covering the first `meters` of a polyline's
    /// coordinates, ending exactly at the distance mark (last point
    /// interpolated between the straddling vertices). The full path comes
    /// back when `meters` runs past the end. The last element is the
    /// drop-off point.
    static func prefixCoordinates(_ coords: [CLLocationCoordinate2D],
                                  meters: Double) -> [CLLocationCoordinate2D] {
        guard coords.count >= 2, meters > 0 else {
            return coords.isEmpty ? [] : [coords[0]]
        }
        var out = [coords[0]]
        var travelled = 0.0
        for i in 1..<coords.count {
            let span = POIRanking.meters(coords[i - 1], coords[i])
            if travelled + span >= meters, span > 0 {
                let f = (meters - travelled) / span
                out.append(CLLocationCoordinate2D(
                    latitude: coords[i - 1].latitude
                        + (coords[i].latitude - coords[i - 1].latitude) * f,
                    longitude: coords[i - 1].longitude
                        + (coords[i].longitude - coords[i - 1].longitude) * f))
                return out
            }
            travelled += span
            out.append(coords[i])
        }
        return out
    }

    // -- Keyless deep links ---------------------------------------------------

    private static func fmt(_ v: Double) -> String { String(format: "%.5f", v) }

    /// Uber universal link (m.uber.com/ul/) — opens the app when installed,
    /// the mobile site otherwise. No API key involved.
    static func uberURL(pickup: CLLocationCoordinate2D, pickupName: String,
                        drop: CLLocationCoordinate2D, dropName: String) -> URL? {
        var parts = URLComponents(string: "https://m.uber.com/ul/")
        parts?.queryItems = [
            URLQueryItem(name: "action", value: "setPickup"),
            URLQueryItem(name: "pickup[latitude]", value: fmt(pickup.latitude)),
            URLQueryItem(name: "pickup[longitude]", value: fmt(pickup.longitude)),
            URLQueryItem(name: "pickup[nickname]", value: pickupName),
            URLQueryItem(name: "dropoff[latitude]", value: fmt(drop.latitude)),
            URLQueryItem(name: "dropoff[longitude]", value: fmt(drop.longitude)),
            URLQueryItem(name: "dropoff[nickname]", value: dropName),
        ]
        return parts?.url
    }

    /// Lyft web deep link — same keyless pattern.
    static func lyftURL(pickup: CLLocationCoordinate2D,
                        drop: CLLocationCoordinate2D) -> URL? {
        var parts = URLComponents(string: "https://lyft.com/ride")
        parts?.queryItems = [
            URLQueryItem(name: "id", value: "lyft"),
            URLQueryItem(name: "pickup[latitude]", value: fmt(pickup.latitude)),
            URLQueryItem(name: "pickup[longitude]", value: fmt(pickup.longitude)),
            URLQueryItem(name: "destination[latitude]", value: fmt(drop.latitude)),
            URLQueryItem(name: "destination[longitude]", value: fmt(drop.longitude)),
        ]
        return parts?.url
    }
}
