// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// Live police and fire calls that cities publish as free public data — the
/// lawful, keyless way to put calls on the map. Broadcastify's terms require a
/// paid licence for any app that plays or transcribes its streams (owner,
/// 2026-10-01: open city data now, Broadcastify audio once licensed). Each
/// call becomes the same fading pin the scanner draws (ScannerIncidents).
///
/// Only feeds that are public domain AND minutes behind are listed: a call
/// hours old is a false alarm. Checked 2026-10-01 — San Francisco police
/// (PDDL, ~20 min behind) and Seattle fire (public domain, every 5 min).
/// Cincinnati is public domain but a day behind, Montgomery County MD and
/// Seattle police hours to days; Dallas is live but under an attribution
/// licence (owner rule: ask first). A new city is one entry in `feeds`.
enum OpenDispatch {

    /// One city's feed: where it is, where to read it, and how its rows name
    /// the call, the place and the time (Socrata's JSON API, keyless).
    struct Feed: Identifiable, Equatable {
        let id: String
        let city: String
        /// What it carries, in plain words ("Police calls").
        let what: String
        let centerLat: Double
        let centerLon: Double
        /// How far from the centre the city's calls reach.
        let radiusMeters: Double
        /// The newest rows first.
        let url: String
        let idField: String
        /// The call's name; the first field with text wins.
        let typeFields: [String]
        let timeField: String
        /// A GeoJSON point field, or separate latitude/longitude fields.
        let pointField: String?
        let latField: String?
        let lonField: String?
        let placeField: String
        /// The rows' clock: local time with no zone written down.
        let timeZone: String
        /// Rows kept by priority (nil keeps every row): San Francisco's A
        /// (emergency) and B (urgent), not its routine C calls.
        let priorityField: String?
        let priorities: [String]
        /// Words in a call's name → its kind, in order; else `defaultKind`.
        let kindWords: [KindWord]
        let defaultKind: ScannerIncidents.Kind
        let licence: String
        /// How far behind the city publishes, for the card.
        let delay: String

        struct KindWord: Equatable {
            let word: String
            let kind: ScannerIncidents.Kind
        }
    }

    static let feeds: [Feed] = [
        Feed(id: "sf-police", city: "San Francisco", what: "Police calls",
             centerLat: 37.7749, centerLon: -122.4194, radiusMeters: 16_000,
             url: "https://data.sf.gov/resource/gnap-fj3t.json"
                + "?$order=received_datetime%20DESC&$limit=300",
             idField: "cad_number",
             typeFields: ["call_type_final_desc", "call_type_original_desc"],
             timeField: "received_datetime",
             pointField: "intersection_point", latField: nil, lonField: nil,
             placeField: "intersection_name",
             timeZone: "America/Los_Angeles",
             priorityField: "priority_final", priorities: ["A", "B"],
             // No "fire": police calls name it in "SHOTS FIRED", which is a
             // police call, not a fire.
             kindWords: [.init(word: "medical", kind: .medical),
                         .init(word: "injur", kind: .medical),
                         .init(word: "collision", kind: .traffic)],
             defaultKind: .police,
             licence: "City of San Francisco, public domain (PDDL)",
             delay: "about 20 minutes behind"),
        Feed(id: "seattle-fire", city: "Seattle", what: "Fire and medical calls",
             centerLat: 47.6062, centerLon: -122.3321, radiusMeters: 18_000,
             url: "https://data.seattle.gov/resource/kzjm-xkqj.json"
                + "?$order=datetime%20DESC&$limit=200",
             idField: "incident_number",
             typeFields: ["type"],
             timeField: "datetime",
             pointField: nil, latField: "latitude", lonField: "longitude",
             placeField: "address",
             timeZone: "America/Los_Angeles",
             priorityField: nil, priorities: [],
             kindWords: [.init(word: "aid", kind: .medical),
                         .init(word: "medic", kind: .medical),
                         .init(word: "mvi", kind: .traffic),
                         .init(word: "motor vehicle", kind: .traffic),
                         .init(word: "rescue", kind: .rescue),
                         .init(word: "hazmat", kind: .hazard),
                         .init(word: "hazardous", kind: .hazard),
                         .init(word: "fire", kind: .fire)],
             defaultKind: .fire,
             licence: "City of Seattle, public domain",
             delay: "about 5 minutes behind"),
    ]

    /// How long a city call stays on the map: an hour (fires an hour and a
    /// half) — it arrives minutes late, so the scanner's 12-minute police
    /// pin would be gone before it was drawn.
    static func lifetime(for kind: ScannerIncidents.Kind) -> TimeInterval {
        kind == .fire || kind == .hazard ? 5_400 : 3_600
    }

    /// The feeds whose city the position is in or near, nearest first;
    /// every feed when there is no position.
    static func covering(_ position: CLLocationCoordinate2D?) -> [Feed] {
        guard let position else { return feeds }
        return feeds
            .map { ($0, POIRanking.meters(position, CLLocationCoordinate2D(
                latitude: $0.centerLat, longitude: $0.centerLon))) }
            .filter { $0.1 <= $0.0.radiusMeters + 25_000 }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// The feeds nearest first, wherever the position is — the card's list.
    static func byDistance(from position: CLLocationCoordinate2D?) -> [Feed] {
        guard let position else { return feeds }
        return feeds.sorted {
            POIRanking.meters(position, CLLocationCoordinate2D(latitude: $0.centerLat,
                                                               longitude: $0.centerLon))
                < POIRanking.meters(position, CLLocationCoordinate2D(latitude: $1.centerLat,
                                                                     longitude: $1.centerLon))
        }
    }

    /// A call's kind: the feed's words in order, else its default.
    static func kind(of type: String, in feed: Feed) -> ScannerIncidents.Kind {
        let lower = type.lowercased()
        return feed.kindWords.first { lower.contains($0.word) }?.kind ?? feed.defaultKind
    }

    /// The calls in one page of a feed still young enough to pin, as
    /// incidents dated by when the call came in (not when FLOWS read it).
    /// Rows without a place, a time, a name or (where the feed rates them)
    /// an urgent priority are skipped; so is a point at 0,0.
    static func incidents(from data: Data, feed: Feed,
                          now: Date = Date()) -> [ScannerIncidents.Incident] {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.timeZone = TimeZone(identifier: feed.timeZone)
        parse.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        var out: [ScannerIncidents.Incident] = []
        for row in rows {
            if let field = feed.priorityField {
                guard let p = row[field] as? String, feed.priorities.contains(p) else { continue }
            }
            guard let rawTime = row[feed.timeField] as? String,
                  let at = parse.date(from: rawTime),
                  let type = feed.typeFields.lazy.compactMap({ row[$0] as? String })
                    .first(where: { !$0.isEmpty }),
                  let coordinate = Self.coordinate(row, feed: feed) else { continue }
            let kind = Self.kind(of: type, in: feed)
            let age = now.timeIntervalSince(at)
            guard age >= -600, age < lifetime(for: kind) else { continue }
            let rowID = (row[feed.idField] as? String) ?? "\(rawTime)|\(type)"
            let place = (row[feed.placeField] as? String) ?? ""
            out.append(ScannerIncidents.Incident(
                id: "\(feed.id)|\(rowID)", kind: kind, coordinate: coordinate,
                placeText: Self.readable(type) + (place.isEmpty ? "" : " — \(place)"),
                heardAt: min(at, now), lifetime: lifetime(for: kind)))
        }
        return out
    }

    private static func coordinate(_ row: [String: Any], feed: Feed) -> CLLocationCoordinate2D? {
        var lat: Double?, lon: Double?
        if let field = feed.pointField,
           let point = row[field] as? [String: Any],
           let c = point["coordinates"] as? [Double], c.count == 2 {
            lon = c[0]; lat = c[1]
        } else if let la = feed.latField, let lo = feed.lonField {
            lat = (row[la] as? String).flatMap(Double.init) ?? (row[la] as? Double)
            lon = (row[lo] as? String).flatMap(Double.init) ?? (row[lo] as? Double)
        }
        guard let lat, let lon, abs(lat) > 0.01 || abs(lon) > 0.01,
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// "SHOTS FIRED" → "Shots fired": the cities write in capitals.
    static func readable(_ type: String) -> String {
        let lower = type.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    /// Words that make a call worth saying out loud when it is near: a gun,
    /// a robbery, a stabbing, a fire — not an alarm going off or a traffic
    /// stop.
    static let threatWords = ["shot", "shoot", "gun", "firearm", "armed", "weapon",
                              "robbery", "stab", "carjack", "hostage", "kidnap",
                              "explosi", "bomb", "fire"]
    static let notThreatWords = ["alarm", "fireworks", "false"]

    /// Serious enough to speak up about when it is within `threatMeters`.
    static func isThreat(_ incident: ScannerIncidents.Incident) -> Bool {
        let text = incident.placeText.lowercased()
        let name = text.components(separatedBy: " — ").first ?? text
        guard !notThreatWords.contains(where: { name.contains($0) }) else { return false }
        return threatWords.contains { name.contains($0) }
    }

    /// How near a threat must be to be said out loud: about a mile.
    static let threatMeters: Double = 1_600
}
