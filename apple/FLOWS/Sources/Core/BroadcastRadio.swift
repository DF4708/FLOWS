// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import AVFoundation
import CoreLocation
import Foundation

/// AM and FM radio — the stations already on the dial, played over their own
/// public streams. This is the DEFAULT listening in FLOWS: it needs no
/// account, no subscription, and no app to be installed.
///
/// It has nothing to do with the emergency radio. That one carries NOAA
/// Weather Radio and highway advisories, plays one relay chosen by where you
/// are, and exists for warnings. This one is music and talk, chosen by KIND,
/// and the driver steps through the stations of a kind with back and
/// forward. They never play at once — a car has one pair of speakers.
///
/// Stations come from the Radio Browser directory (radio-browser.info), a
/// keyless community catalogue of broadcasters' own public streams. It is
/// run from Germany, Austria and the Netherlands, which keeps the project's
/// standing rule about where a service is operated from.
enum BroadcastRadio {
    /// What a driver actually asks for. Plain words on purpose — "adult
    /// contemporary" and "urban rhythmic" are trade terms, not English.
    enum Kind: String, CaseIterable, Identifiable, Codable {
        case news, country, rock, pop, hipHop, oldies, classical
        case jazz, latin, sports, christian

        var id: String { rawValue }

        var title: String {
            switch self {
            case .news: return "News & Talk"
            case .country: return "Country"
            case .rock: return "Rock"
            case .pop: return "Pop & Hits"
            case .hipHop: return "Hip-Hop & R&B"
            case .oldies: return "Oldies"
            case .classical: return "Classical"
            case .jazz: return "Jazz"
            case .latin: return "Spanish"
            case .sports: return "Sports"
            case .christian: return "Christian"
            }
        }

        var symbol: String {
            switch self {
            case .news: return "newspaper.fill"
            case .country: return "guitars.fill"
            // Not another guitar: "guitars" and "guitars.fill" are the
            // same drawing at chip size, so Country and Rock were
            // indistinguishable in the picker.
            case .rock: return "amplifier"
            case .pop: return "music.note"
            case .hipHop: return "waveform"
            case .oldies: return "backward.end.fill"
            case .classical: return "pianokeys"
            case .jazz: return "music.quarternote.3"
            case .latin: return "globe.americas.fill"
            case .sports: return "sportscourt.fill"
            case .christian: return "book.closed.fill"
            }
        }

        /// Directory tags that mean this kind. Ordered so the most specific
        /// kinds are tested first — "classic rock" must not land in Oldies
        /// and "christian rock" must not land in Rock.
        var tagWords: [String] {
            switch self {
            case .sports: return ["sport", "sports talk"]
            case .christian: return ["christian", "gospel", "worship",
                                     "catholic", "religio"]
            case .latin: return ["spanish", "latin", "regional mexican",
                                 "reggaeton", "salsa", "ranchera", "tejano",
                                 "banda", "espanol", "español"]
            case .classical: return ["classical", "opera", "symphon",
                                     "baroque", "orchestr"]
            case .jazz: return ["jazz", "bebop", "swing", "big band", "blues"]
            case .news: return ["news", "talk", "npr", "public radio",
                                "current affairs", "information", "politics"]
            case .country: return ["country", "bluegrass", "americana",
                                   "honky", "western"]
            case .oldies: return ["oldies", "classic hits", "50s", "60s",
                                  "70s", "80s", "nostalgia", "adult hits",
                                  "doo-wop", "motown"]
            case .hipHop: return ["hip hop", "hip-hop", "hiphop", "rap",
                                  "r&b", "rnb", "rhythm", "urban", "soul",
                                  "funk"]
            case .rock: return ["rock", "metal", "punk", "grunge",
                                "alternative", "indie"]
            case .pop: return ["pop", "top 40", "top40", "hits", "dance",
                               "electronic", "house", "chart", "contempo"]
            }
        }

        /// The order kinds are tested in — narrow before broad, so a station
        /// tagged "christian rock" is Christian and one tagged "classic
        /// rock" is Rock rather than Oldies.
        static let matchOrder: [Kind] = [
            .sports, .christian, .latin, .classical, .jazz, .news,
            .country, .hipHop, .oldies, .rock, .pop,
        ]
    }

    /// One broadcaster's stream.
    struct Station: Codable, Identifiable, Equatable, Hashable {
        var id: String            // the directory's stable station uuid
        var name: String
        var url: String
        var tags: String
        var latitude: Double?
        var longitude: Double?
        var bitrate: Int
        /// Which kind it was filed under (decided once, at catalogue time).
        var kind: Kind

        /// "WAPL 105.7" → "105.7 FM". Many entries carry the dial position
        /// in the name; showing it is what makes this feel like a radio and
        /// not a playlist. nil when the name has no frequency in it.
        var dialLabel: String? { BroadcastRadio.dialLabel(from: name) }

        var streamURL: URL? {
            let secured = url.hasPrefix("http://")
                ? "https://" + url.dropFirst("http://".count) : url
            return URL(string: secured)
        }
    }

    /// Which kind a set of directory tags belongs to, or nil for a station
    /// whose tags say nothing a driver would recognize.
    static func kind(forTags tags: String) -> Kind? {
        let hay = tags.lowercased()
        guard !hay.isEmpty else { return nil }
        for kind in Kind.matchOrder where kind.tagWords.contains(
            where: { hay.contains($0) }) {
            return kind
        }
        return nil
    }

    /// The dial position hiding in a station's name, normalized.
    ///
    /// FM frequencies are 87.5–108 and always carry a decimal; AM are whole
    /// numbers from 530 to 1700. Anything else in a name — a year, a
    /// bitrate, a channel number — is not a dial position and is ignored.
    static func dialLabel(from name: String) -> String? {
        var best: String?
        var current = ""
        func consider(_ token: String) {
            guard !token.isEmpty else { return }
            if token.contains("."), let v = Double(token),
               v >= 87.5, v <= 108.0 {
                best = best ?? String(format: "%.1f FM", v)
            } else if !token.contains("."), let v = Int(token),
                      v >= 530, v <= 1_700 {
                best = best ?? "\(v) AM"
            }
        }
        for ch in name {
            if ch.isNumber || ch == "." {
                current.append(ch)
            } else {
                consider(current)
                current = ""
            }
        }
        consider(current)
        return best
    }

    /// Rank stations for a driver at `position`: located ones nearest first,
    /// then the rest by bitrate. A local broadcaster is the point — a
    /// higher-bitrate stream from three states away is not "local radio".
    static func ranked(_ stations: [Station],
                       near position: CLLocationCoordinate2D?) -> [Station] {
        stations.sorted { a, b in
            switch (distance(a, position), distance(b, position)) {
            case let (x?, y?) where x != y: return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.bitrate > b.bitrate
            }
        }
    }

    private static func distance(_ s: Station,
                                 _ p: CLLocationCoordinate2D?) -> Double? {
        guard let p, let la = s.latitude, let lo = s.longitude else { return nil }
        return POIRanking.meters(CLLocationCoordinate2D(latitude: la,
                                                        longitude: lo), p)
    }

}
