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
/// the network lives here. The numbers and choices are computed in
/// rust/flows-core (travel_modes.rs); the step wording and links stay here.
enum AirTravel {
    /// Below this trip length flying cannot beat the road once airport time
    /// is added (arrive early + security + taxi + bags ≈ 2 h on its own).
    static let minTripMiles: Double = flows_modes_air_constants()[0]

    static func worthFlying(tripMiles: Double) -> Bool {
        flows_modes_worth_flying(tripMiles)
    }

    /// Board and alight airports this close together mean the flight itself
    /// is shorter than the airport overhead — no flight fits the trip.
    static let minAirportGapMiles: Double = flows_modes_air_constants()[1]

    // -- Timing ---------------------------------------------------------------

    /// Show up this early (security + boarding)…
    static let boardBufferSeconds: TimeInterval = flows_modes_air_constants()[2]
    /// …and budget this to get off, collect bags, and exit.
    static let alightBufferSeconds: TimeInterval = flows_modes_air_constants()[3]

    /// In-air seconds for the airport-to-airport distance: taxi/climb/descent
    /// overhead plus cruise at an effective ground speed. Estimates only —
    /// schedules are the airlines'.
    static func flightSeconds(airportMiles: Double) -> TimeInterval {
        flows_modes_flight_seconds(airportMiles)
    }

    /// The whole airport-to-curb leg: early arrival + flight + deplane/bags.
    /// This is what the itinerary shows, so a "1 h flight" never hides the
    /// two hours of airport around it.
    static func doorSeconds(airportMiles: Double) -> TimeInterval {
        flows_modes_door_seconds(airportMiles)
    }

    // -- Fare -----------------------------------------------------------------

    /// Ballpark one-way fare — floor plus a per-mile slope, in line with
    /// published US domestic averages. Always disclosed as an estimate the
    /// airlines control.
    static func fareEstimate(airportMiles: Double) -> Double {
        flows_modes_fare_estimate(airportMiles)
    }

    // -- Airports with airline service ---------------------------------------

    /// One airport from the table FLOWS carries (rust/flows-core airports.rs,
    /// built from OurAirports' public-domain data): every airport in the US,
    /// Canada and Mexico with a code and SCHEDULED SERVICE.
    struct Airport: Equatable {
        /// "MKE" — what a booking search wants.
        let code: String
        /// "Milwaukee Mitchell International Airport".
        let name: String
        /// "Milwaukee" — the city it serves, which is how people name it.
        let city: String
        /// "US", "CA" or "MX".
        let country: String
        /// "US-WI" — the state or province, which a rental landing page is
        /// named for.
        let region: String
        /// "large", "medium" or "small".
        let size: String
        let coordinate: CLLocationCoordinate2D
        /// Straight-line meters from the point that was asked about.
        let meters: Double

        static func == (a: Airport, b: Airport) -> Bool { a.code == b.code }

        /// "Milwaukee (MKE)" — the plain name for a card or a spoken line.
        var label: String { city.isEmpty ? "\(name) (\(code))" : "\(city) (\(code))" }
    }

    /// How far FLOWS will drive to an airport, in meters.
    static var maxDriveMeters: Double { flows_airports_max_drive_meters() }

    /// The airports with airline service near a point, best first (nearest,
    /// with a large airport worth a longer drive).
    static func nearest(to c: CLLocationCoordinate2D, limit: Int = 3) -> [Airport] {
        airports(flows_airports_nearest(c.latitude, c.longitude, Int64(limit)),
                 places: flows_airports_nearest_places(c.latitude, c.longitude, Int64(limit)))
    }

    /// The two ends of a flight for this trip — board, then alight — or none
    /// when no flight fits it. The MAP SEARCH this replaced turned an empty
    /// or throttled answer into "no flight fits this trip" for routes with
    /// daily service, and judged airports by name.
    static func flightEnds(from: CLLocationCoordinate2D,
                           to: CLLocationCoordinate2D) -> (board: Airport, alight: Airport)? {
        let gap = minAirportGapMiles * 1609.344
        let rows = flows_airports_pair(from.latitude, from.longitude,
                                       to.latitude, to.longitude, gap)
        let places = flows_airports_pair_places(from.latitude, from.longitude,
                                                to.latitude, to.longitude, gap)
        let found = airports(rows, places: places)
        guard found.count == 2 else { return nil }
        return (found[0], found[1])
    }

    /// The bridge's rows ("IATA␟name␟city␟country␟size") beside their three
    /// doubles each (latitude, longitude, meters).
    private static func airports(_ rows: RustVec<RustString>,
                                 places: RustVec<Double>) -> [Airport] {
        var numbers: [Double] = []
        for value in places { numbers.append(value) }
        var out: [Airport] = []
        var i = 0
        for row in rows {
            let text: String = row.as_str().toString()
            let parts: [String] = text
                .split(separator: "\u{1F}", omittingEmptySubsequences: false)
                .map(String.init)
            let base = i * 3
            i += 1
            guard parts.count == 6, numbers.count >= base + 3 else { continue }
            let place = CLLocationCoordinate2D(latitude: numbers[base],
                                               longitude: numbers[base + 1])
            let airport = Airport(code: parts[0], name: parts[1], city: parts[2],
                                  country: parts[3], region: parts[4], size: parts[5],
                                  coordinate: place, meters: numbers[base + 2])
            out.append(airport)
        }
        return out
    }

    // -- Airport selection (the map-search fallback) --------------------------

    struct Candidate {
        let name: String
        let meters: Double
    }

    /// Commercial-airport preference from the name alone: heliports, private
    /// strips, and military fields are rejected outright; "International"
    /// outranks everything else; then plain "Airport"; then the rest.
    /// Returns nil for rejects.
    static func airportScore(name: String) -> Int? {
        let score = flows_modes_airport_score(name)
        return score < 0 ? nil : Int(score)
    }

    /// Best candidate: lowest score first (international > airport > other),
    /// nearest breaks ties; anything past `maxMeters` or rejected by name is
    /// out. Returns the index into `candidates`.
    static func pickIndex(_ candidates: [Candidate], maxMeters: Double) -> Int? {
        guard !candidates.isEmpty else { return nil }
        let meters = candidates.map(\.meters)
        let i = RustTextColumn(candidates.map(\.name)).with { joined, lens, _ in
            meters.withUnsafeBufferPointer { m in flows_modes_pick_airport(joined, lens, m, maxMeters) }
        }
        return i < 0 ? nil : Int(i)
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
