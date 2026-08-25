// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// One Amtrak rail station from the bundled list. `code` is Amtrak's own
/// three-letter station code (NYP, CHI, LAX…), which also names the station's
/// page on amtrak.com.
struct AmtrakStation: Codable, Equatable {
    let code: String
    let name: String
    let lat: Double
    let lon: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// The station's page on Amtrak's site — same scheme as the `stop_url`
    /// column of the source feed (amtrak.com/stations/<code>).
    var url: URL? {
        URL(string: "https://www.amtrak.com/stations/\(code.lowercased())")
    }
}

/// The bundled Amtrak rail-station list (Resources/amtrak_stations.json) and
/// the pure nearest-station selection over it. MKLocalSearch kept failing to
/// find real Amtrak stations for most rail plans ("Amtrak station" near a
/// suburb returns cafés named Amtrak, or nothing) — but Amtrak publishes every
/// station location, so board/alight selection is now an offline lookup, with
/// the network search only as an off-list fallback.
///
/// Data source: Amtrak's public GTFS feed
/// (https://content.amtrak.com/content/gtfs/GTFS.zip), stops.txt, retrieved
/// 2026-07-30, filtered to stations served by rail routes (route_type 2 —
/// Thruway bus-only stops excluded). 536 stations; name/code/lat/lon only.
enum AmtrakStations {
    /// The JSON envelope: `source` + `retrieved` document provenance inside
    /// the data file itself; only `stations` is read.
    private struct File: Codable { let stations: [AmtrakStation] }

    /// The bundled list, decoded once. Empty only if the resource is missing
    /// or corrupt — callers treat that as "no station found" and fall back to
    /// the network search.
    static let all: [AmtrakStation] = load(
        from: Bundle.main.url(forResource: "amtrak_stations", withExtension: "json"))

    static func load(from url: URL?) -> [AmtrakStation] {
        guard let url, let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.stations
    }

    /// Nearest station to a point, or nil when none lies within `maxMeters` —
    /// the same sane-radius rule the search path uses, so a plan far from any
    /// rail never "boards" a station in the wrong city.
    static func nearest(
        to point: CLLocationCoordinate2D,
        within maxMeters: CLLocationDistance,
        in stations: [AmtrakStation] = all
    ) -> AmtrakStation? {
        stations
            .min { POIRanking.meters($0.coordinate, point)
                 < POIRanking.meters($1.coordinate, point) }
            .flatMap { POIRanking.meters($0.coordinate, point) <= maxMeters ? $0 : nil }
    }
}
