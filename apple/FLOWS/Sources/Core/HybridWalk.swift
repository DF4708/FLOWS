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
///
/// The cost model, the bar and the drop-off geometry are computed in
/// rust/flows-core (travel_modes.rs); the hail links stay here.
enum HybridWalk {
    static let baseFareUSD = flows_modes_ride_constants()[0]
    static let perMileUSD = flows_modes_ride_constants()[1]
    /// The walker's wallet cap — a ride estimated over this is never offered.
    static let costCapUSD = flows_modes_ride_constants()[2]
    /// The significance bar: the ride must cut total time by at least this
    /// fraction of the walk-alone time…
    static let minSavedFraction = flows_modes_ride_constants()[3]
    /// …and by at least this many seconds, so a 4-minute "40% saving" on a
    /// ten-minute stroll never pitches a fare.
    static let minSavedSeconds: TimeInterval = flows_modes_ride_constants()[4]
    /// Walks shorter than this never get a ride offer at all.
    static let minWalkAloneSeconds: TimeInterval = flows_modes_ride_constants()[5]

    static func rideCostUSD(miles: Double) -> Double {
        flows_modes_ride_cost(miles)
    }

    /// Longest ride the cap can buy — the partial-segment length when the
    /// whole trip would blow the budget.
    static var maxAffordableRideMiles: Double {
        flows_modes_ride_constants()[6]
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
        flows_modes_meets_bar(walkAloneSeconds, totalSeconds, costUSD)
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
        let o = flows_modes_evaluate_ride(walkAloneSeconds, driveSeconds, tripMiles)
        guard o.has else { return nil }
        return Offer(rideMiles: o.ride_miles, rideSeconds: o.ride_seconds,
                     walkSeconds: o.walk_seconds, costUSD: o.cost_usd)
    }

    // -- Drop-off geometry ----------------------------------------------------

    /// The route prefix covering the first `meters` of a polyline's
    /// coordinates, ending exactly at the distance mark (last point
    /// interpolated between the straddling vertices). The full path comes
    /// back when `meters` runs past the end. The last element is the
    /// drop-off point.
    static func prefixCoordinates(_ coords: [CLLocationCoordinate2D],
                                  meters: Double) -> [CLLocationCoordinate2D] {
        guard !coords.isEmpty else { return [] }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let flat = Array(lats.withUnsafeBufferPointer { la in
            lons.withUnsafeBufferPointer { lo in flows_modes_prefix_coordinates(la, lo, meters) }
        })
        return stride(from: 0, to: flat.count - 1, by: 2).map {
            CLLocationCoordinate2D(latitude: flat[$0], longitude: flat[$0 + 1])
        }
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
