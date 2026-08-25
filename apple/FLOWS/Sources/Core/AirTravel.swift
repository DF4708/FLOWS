// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// Pure helpers behind the plane option (pinned by FLOWSTests): airport
/// selection, honest door-to-door flight timing, a fare figure disclosed as
/// carrier-set, and keyless ticket links. Airports come from MKLocalSearch
/// (`.airport` POI category) in the UI layer; everything decidable without
/// the network lives here.
enum AirTravel {
    /// Below this trip length flying cannot beat the road once airport time
    /// is added (arrive early + security + taxi + bags ≈ 2 h on its own).
    static let minTripMiles: Double = 100

    static func worthFlying(tripMiles: Double) -> Bool {
        tripMiles >= minTripMiles
    }

    /// Board and alight airports this close together mean the flight itself
    /// is shorter than the airport overhead — no flight fits the trip.
    static let minAirportGapMiles: Double = 60

    // -- Timing ---------------------------------------------------------------

    /// Show up this early (security + boarding)…
    static let boardBufferSeconds: TimeInterval = 90 * 60
    /// …and budget this to get off, collect bags, and exit.
    static let alightBufferSeconds: TimeInterval = 30 * 60

    /// In-air seconds for the airport-to-airport distance: taxi/climb/descent
    /// overhead plus cruise at an effective ground speed. Estimates only —
    /// schedules are the airlines'.
    static func flightSeconds(airportMiles: Double) -> TimeInterval {
        guard airportMiles > 0 else { return 0 }
        return 45 * 60 + airportMiles / 460 * 3600
    }

    /// The whole airport-to-curb leg: early arrival + flight + deplane/bags.
    /// This is what the itinerary shows, so a "1 h flight" never hides the
    /// two hours of airport around it.
    static func doorSeconds(airportMiles: Double) -> TimeInterval {
        boardBufferSeconds + flightSeconds(airportMiles: airportMiles)
            + alightBufferSeconds
    }

    // -- Fare -----------------------------------------------------------------

    /// Ballpark one-way fare — floor plus a per-mile slope, in line with
    /// published US domestic averages. Always disclosed as an estimate the
    /// airlines control.
    static func fareEstimate(airportMiles: Double) -> Double {
        max(59, 39 + airportMiles * 0.11)
    }

    // -- Airport selection ----------------------------------------------------

    struct Candidate {
        let name: String
        let meters: Double
    }

    /// Commercial-airport preference from the name alone: heliports, private
    /// strips, and military fields are rejected outright; "International"
    /// outranks everything else; then plain "Airport"; then the rest.
    /// Returns nil for rejects.
    static func airportScore(name: String) -> Int? {
        let lower = name.lowercased()
        let reject = ["heliport", "helipad", "seaplane", "airstrip", "airpark",
                      "air park", "air force", "afb", "air base", "naval",
                      "army", "airfield", "balloonport"]
        if reject.contains(where: { lower.contains($0) }) { return nil }
        if lower.contains("international") { return 0 }
        if lower.contains("airport") { return 1 }
        return 2
    }

    /// Best candidate: lowest score first (international > airport > other),
    /// nearest breaks ties; anything past `maxMeters` or rejected by name is
    /// out. Returns the index into `candidates`.
    static func pickIndex(_ candidates: [Candidate], maxMeters: Double) -> Int? {
        candidates.indices
            .compactMap { i -> (Int, Int, Double)? in
                guard candidates[i].meters <= maxMeters,
                      let score = airportScore(name: candidates[i].name)
                else { return nil }
                return (i, score, candidates[i].meters)
            }
            .min { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2 }
            .map { $0.0 }
    }

    // -- Steps + ticket -------------------------------------------------------

    /// Board / fly / land instructions in plain words, with the airport
    /// buffers stated so the total time is explainable.
    static func flightSteps(board: String, alight: String,
                            airportMiles: Double) -> [String] {
        ["Get to \(board) 90 minutes early",
         "Fly \(TransitPlanning.durationPhrase(flightSeconds(airportMiles: airportMiles)))",
         "Land at \(alight) — bags and exit take about 30 minutes"]
    }

    /// Keyless neutral flight search for the airport pair — plain-text query,
    /// no API key, works in any browser.
    static func flightSearchURL(from board: String, to alight: String) -> URL? {
        var parts = URLComponents(string: "https://www.google.com/travel/flights")
        parts?.queryItems = [URLQueryItem(name: "q",
                                          value: "flights from \(board) to \(alight)")]
        return parts?.url
    }

    /// Ticket link for the card: the boarding airport's own page when MapKit
    /// knows it, else the neutral flight search. Label names the exact pair.
    static func ticket(board: String, alight: String, airportURL: URL?)
        -> (label: String, url: URL?) {
        ("Find flights: \(board) → \(alight)",
         airportURL ?? flightSearchURL(from: board, to: alight))
    }
}
