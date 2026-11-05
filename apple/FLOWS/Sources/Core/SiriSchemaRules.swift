// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// The pure rules behind the iOS 27 Siri schema intents (FLOWSSchemaIntents):
/// which waypoints are new to a trip, what a spoken travel mode and road
/// preferences change, and how a station or place travels through Siri as
/// an identifier. No App Intents types here, so FLOWSTests pins every rule
/// on any OS the tests run on.
enum SiriSchemaRules {

    // MARK: travel mode and road preferences

    /// The two ways FLOWS plans a trip by itself. Transit has its own
    /// planner and no "start a trip" path yet, so it is not offered to Siri.
    enum TripMode: String, CaseIterable {
        case driving
        case walking

        var walks: Bool { self == .walking }

        init(walking: Bool) { self = walking ? .walking : .driving }
    }

    /// Road choices Siri can ask for, each one of the planner's own filters.
    /// Only the two a spoken ask maps onto without guessing.
    enum TripPreference: String, CaseIterable {
        case avoidTolls
        case avoidHighways

        var filter: RouteFilter {
            switch self {
            case .avoidTolls: return .noTolls
            case .avoidHighways: return .noHighways
            }
        }
    }

    /// The preferences the planner's filters already say, in a fixed order
    /// (what the trip reports back to Siri).
    static func preferences(in filters: Set<RouteFilter>) -> [TripPreference] {
        TripPreference.allCases.filter { filters.contains($0.filter) }
    }

    /// What a Siri trip request does before planning.
    enum TripRequest: Equatable {
        /// Plan now. `walking` is the mode to switch to (nil: keep the one
        /// on screen); `addFilters` are filters to turn on first. Filters
        /// are only ever added: Siri never turns off one the driver chose.
        case plan(walking: Bool?, addFilters: Set<RouteFilter>)
        /// The ask changes the mode or the filters while a trip is being
        /// driven. Changing them under the live trip would replan the road
        /// being driven, so the driver ends it first.
        case finishTripFirst
    }

    static func tripRequest(mode: TripMode, preferences: Set<TripPreference>,
                            walkingNow: Bool, filters: Set<RouteFilter>,
                            tripUnderway: Bool) -> TripRequest {
        let switchMode = mode.walks != walkingNow
        let add = Set(preferences.map(\.filter)).subtracting(filters)
        if tripUnderway && (switchMode || !add.isEmpty) { return .finishTripFirst }
        return .plan(walking: switchMode ? mode.walks : nil, addFilters: add)
    }

    // MARK: waypoints

    /// How close two points are to count as the same stop. A store's map
    /// pin and its entrance are rarely more than a parking lot apart.
    static let sameStopMeters: CLLocationDistance = 150

    /// Most places looked at in one "change my stops" ask; each may cost a
    /// lookup, and Siri sends the list.
    static let maxWaypoints = 10

    /// The positions in `asked` that are not already in the trip: not within
    /// `sameStopMeters` of a point in `existing` or of an earlier ask. Siri
    /// sends the whole list it wants on the route, so the stops already on
    /// it come back and must not be added twice.
    static func newWaypoints(_ asked: [CLLocationCoordinate2D],
                             existing: [CLLocationCoordinate2D],
                             within meters: CLLocationDistance = sameStopMeters) -> [Int] {
        var kept: [CLLocationCoordinate2D] = existing
        var fresh: [Int] = []
        for (i, point) in asked.enumerated() where isValid(point) {
            if kept.contains(where: { POIRanking.meters($0, point) <= meters }) { continue }
            kept.append(point)
            fresh.append(i)
        }
        return fresh
    }

    // MARK: identifiers

    /// Longest place or station name an identifier may carry; Siri hands
    /// identifiers back, so what is read from one is bounded.
    static let maxNameLength = 200
    static let maxURLLength = 2048

    static func isValid(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude.isFinite && c.longitude.isFinite
            && abs(c.latitude) <= 90 && abs(c.longitude) <= 180
    }

    /// A place's identifier: its point and name, so it means the same place
    /// whenever Siri hands it back ("lat,lon,name", six decimals: about
    /// 10 cm). Nil for a point that is not on Earth.
    static func placeID(_ c: CLLocationCoordinate2D, name: String?) -> String? {
        guard isValid(c) else { return nil }
        let label = String((name ?? "").prefix(maxNameLength))
        return String(format: "%.6f,%.6f,", c.latitude, c.longitude) + label
    }

    /// The point and name in a place identifier, or nil when it isn't one.
    static func place(fromID id: String) -> (coordinate: CLLocationCoordinate2D, name: String?)? {
        let parts = id.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let lat = Double(parts[0]), let lon = Double(parts[1]),
              parts[2].count <= maxNameLength else { return nil }
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        guard isValid(c) else { return nil }
        return (c, parts[2].isEmpty ? nil : String(parts[2]))
    }

    /// Which station an identifier names. A station is only ever played
    /// from FLOWS's own lists: the identifier picks one, it never supplies
    /// a stream of its own.
    enum StationRef: Equatable {
        /// An AM/FM station from the radio directory, by its stream URL.
        case directory(url: String)
        /// A NOAA weather radio relay, by its name in the station list.
        case weather(name: String)

        var id: String {
            switch self {
            case .directory(let url): return "radio:" + url
            case .weather(let name): return "weather:" + name
            }
        }

        init?(id: String) {
            if id.hasPrefix("radio:") {
                let url = String(id.dropFirst("radio:".count))
                guard !url.isEmpty, url.count <= SiriSchemaRules.maxURLLength else { return nil }
                self = .directory(url: url)
            } else if id.hasPrefix("weather:") {
                let name = String(id.dropFirst("weather:".count))
                guard !name.isEmpty, name.count <= SiriSchemaRules.maxNameLength else { return nil }
                self = .weather(name: name)
            } else {
                return nil
            }
        }
    }

    // MARK: picking a station from what was said

    /// True when the ask is for weather radio rather than a music station
    /// ("weather radio", "NOAA", "the weather station").
    static func wantsWeatherRadio(_ text: String) -> Bool {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        return words.contains("noaa") || words.contains("weather")
    }

    /// Most stations handed back for one ask.
    static let maxStations = 10

    /// Station order for an ask: a name that is the ask comes first, then
    /// names that contain it, then the rest in the directory's own order
    /// (its search already ranks by votes). Indices into `names`, at most
    /// `limit` of them.
    static func rankStations(names: [String], query: String,
                             limit: Int = maxStations) -> [Int] {
        func fold(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let q = fold(query)
        func tier(_ name: String) -> Int {
            let n = fold(name)
            if !q.isEmpty && n == q { return 0 }
            if !q.isEmpty && n.contains(q) { return 1 }
            return 2
        }
        let order = names.indices.sorted { a, b in
            let (ta, tb) = (tier(names[a]), tier(names[b]))
            return ta != tb ? ta < tb : a < b
        }
        return Array(order.prefix(max(0, limit)))
    }
}
