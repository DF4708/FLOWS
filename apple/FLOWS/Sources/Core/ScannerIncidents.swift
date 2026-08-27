// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation

/// Reading emergency dispatch traffic into temporary map icons.
///
/// HOW THIS IS ALLOWED TO WORK. The audio is transcribed ON THIS DEVICE and
/// never leaves it: no upload, no server, no shared transcript store. What
/// reaches the map is a handful of derived markers — a kind, a place, and a
/// time — that expire on their own. The stream itself is never rebroadcast,
/// re-served, or written to disk, because redistribution is exactly what
/// every scanner provider's terms forbid. The feed list is supplied by the
/// operator of the app (see ScannerFeedStore), so the listening relationship
/// stays theirs.
///
/// WHY IT IS CAUTIOUS. Dispatch audio is compressed, clipped and full of
/// codes; speech recognition on it is imperfect; and a wrong red "medical"
/// pin on a driver's map is worse than no pin at all. So nothing is plotted
/// on a guess. An incident needs a recognizable KIND and a location the app
/// can actually resolve, or it is dropped. Everything here is pure and
/// pinned by FLOWSTests.
enum ScannerIncidents {

    /// What kind of call it is. Colours match the map legend's language:
    /// blue for police, red for medical, orange for fire.
    enum Kind: String, CaseIterable, Identifiable, Codable {
        case police, medical, fire, rescue, traffic, hazard

        var id: String { rawValue }

        /// Plain words for the map callout.
        var title: String {
            switch self {
            case .police: return "Police"
            case .medical: return "Medical"
            case .fire: return "Fire"
            case .rescue: return "Rescue"
            case .traffic: return "Crash"
            case .hazard: return "Hazard"
            }
        }

        var symbol: String {
            switch self {
            case .police: return "shield.fill"
            case .medical: return "cross.fill"
            case .fire: return "flame.fill"
            case .rescue: return "figure.wave"
            case .traffic: return "car.2.fill"
            case .hazard: return "exclamationmark.triangle.fill"
            }
        }

        /// The glow colour, by name so the UI layer owns the actual Color.
        var colorName: String {
            switch self {
            case .police: return "blue"
            case .medical: return "red"
            case .fire: return "orange"
            case .rescue: return "green"
            case .traffic: return "yellow"
            case .hazard: return "purple"
            }
        }

        /// Phrases that mean this kind of call. Ordered most specific first
        /// inside each list; the matcher tries kinds in `matchOrder`.
        var phrases: [String] {
            switch self {
            case .traffic:
                return ["motor vehicle accident", "mva", "vehicle accident",
                        "traffic collision", "ten fifty", "10-50",
                        "car accident", "collision", "vehicle rollover",
                        "hit and run", "vehicle versus"]
            case .fire:
                return ["structure fire", "working fire", "brush fire",
                        "vehicle fire", "smoke showing", "fire alarm",
                        "engine responding", "ladder responding",
                        "fully involved", "grass fire"]
            case .medical:
                return ["cardiac arrest", "difficulty breathing", "medical call",
                        "unresponsive", "chest pain", "overdose", "seizure",
                        "ems responding", "medic", "ambulance", "injury",
                        "unconscious"]
            case .rescue:
                return ["water rescue", "swift water", "extrication",
                        "trapped", "rescue squad", "entrapment",
                        "person in the water"]
            case .hazard:
                return ["hazmat", "gas leak", "power line down", "wires down",
                        "tree down", "spill", "roadway blocked",
                        "road closed", "downed pole"]
            case .police:
                return ["shots fired", "in pursuit", "pursuit", "traffic stop",
                        "suspicious vehicle", "burglary", "robbery",
                        "domestic", "disturbance", "warrant", "signal 10",
                        "officer", "units responding", "be on the lookout",
                        "bolo", "subject"]
            }
        }
    }

    /// Kinds tried in order — the specific before the general. A call that
    /// says "motor vehicle accident with injury" is a crash, not a medical;
    /// one that says "officer" AND "structure fire" is the fire.
    static let matchOrder: [Kind] = [.traffic, .fire, .rescue, .hazard,
                                     .medical, .police]

    /// What kind of call this transcript describes, or nil when nothing in
    /// it is recognizable. Silence beats a guess.
    static func kind(inTranscript text: String) -> Kind? {
        let hay = " " + text.lowercased() + " "
        for kind in matchOrder where kind.phrases.contains(where: {
            hay.contains(" " + $0) || hay.contains($0 + " ")
        }) {
            return kind
        }
        return nil
    }

    // MARK: pulling a place out of the words

    /// Road-type words a dispatcher actually says. Used to find the tail of
    /// an address or a cross-street pair.
    static let roadWords = ["street", "st", "avenue", "ave", "road", "rd",
                            "drive", "dr", "boulevard", "blvd", "lane", "ln",
                            "highway", "hwy", "parkway", "pkwy", "court", "ct",
                            "place", "pl", "way", "trail", "terrace", "circle",
                            "route", "interstate", "freeway", "turnpike"]

    /// A place mentioned in a transcript, as text to be geocoded.
    ///
    /// Two shapes are worth trusting: a street ADDRESS ("2100 Washington
    /// Road") and a CROSS STREET pair ("Belair Road and Columbia Road").
    /// Anything vaguer — a unit number, a landmark nickname, a beat code —
    /// is not a location this app can put a pin on, so it returns nil and
    /// the incident is dropped.
    static func placePhrase(inTranscript text: String) -> String? {
        let words = text.lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ").map(String.init)
        guard words.count >= 2 else { return nil }

        // Cross streets: "<name> road and <name> road", "<name> and <name>".
        for (i, w) in words.enumerated() where w == "and" || w == "at" {
            guard i >= 2, i + 2 < words.count else { continue }
            let left = Array(words[max(0, i - 3)..<i])
            let right = Array(words[(i + 1)...min(words.count - 1, i + 3)])
            guard left.contains(where: roadWords.contains),
                  right.contains(where: roadWords.contains) else { continue }
            return (left + ["and"] + right).joined(separator: " ")
        }

        // Street address: a number followed within a few words by a road word.
        for (i, w) in words.enumerated() {
            guard let n = Int(w), n > 0, n < 100_000 else { continue }
            let tail = words[(i + 1)...min(words.count - 1, i + 4)]
            guard let end = tail.firstIndex(where: roadWords.contains) else { continue }
            return words[i...end].joined(separator: " ")
        }
        return nil
    }

    // MARK: what gets drawn, and for how long

    /// One transcribed call, once its place has been resolved.
    struct Incident: Identifiable, Equatable {
        let id: String
        let kind: Kind
        let coordinate: CLLocationCoordinate2D
        /// The words the place came from — shown so a driver can judge it.
        let placeText: String
        let heardAt: Date

        static func == (a: Incident, b: Incident) -> Bool { a.id == b.id }
    }

    /// How long a marker stays on the map.
    ///
    /// These are TEMPORARY by nature: a traffic stop is over in minutes and
    /// a stale pin is a lie about where the police are. Fires and hazards
    /// last longer because the road stays affected longer.
    static func lifetime(for kind: Kind) -> TimeInterval {
        switch kind {
        case .police: return 12 * 60
        case .medical: return 20 * 60
        case .traffic: return 35 * 60
        case .rescue: return 35 * 60
        case .fire: return 45 * 60
        case .hazard: return 60 * 60
        }
    }

    static func isExpired(_ incident: Incident, now: Date = Date()) -> Bool {
        now.timeIntervalSince(incident.heardAt) >= lifetime(for: incident.kind)
    }

    /// How far from the driver an incident is worth drawing. Beyond this it
    /// is somebody else's town.
    static let relevantMeters: Double = 25_000

    /// Keep only what is still live and still near the driver or the route
    /// corridor. `corridor` is a coarse sample of the route.
    static func visible(_ incidents: [Incident],
                        near position: CLLocationCoordinate2D?,
                        corridor: [CLLocationCoordinate2D] = [],
                        now: Date = Date()) -> [Incident] {
        incidents.filter { incident in
            guard !isExpired(incident, now: now) else { return false }
            if let position,
               POIRanking.meters(incident.coordinate, position) <= relevantMeters {
                return true
            }
            return corridor.contains {
                POIRanking.meters(incident.coordinate, $0) <= relevantMeters
            }
        }
    }

    /// Fold a new incident into a list, replacing an earlier report of the
    /// same thing rather than stacking pins on one corner.
    ///
    /// Dispatch repeats itself constantly — the same call is read out to
    /// several units — so without this a single crash becomes a cluster.
    static let duplicateMeters: Double = 250

    static func merged(_ existing: [Incident], adding new: Incident) -> [Incident] {
        var out = existing.filter { prior in
            !(prior.kind == new.kind
              && POIRanking.meters(prior.coordinate, new.coordinate) <= duplicateMeters)
        }
        out.append(new)
        return out
    }
}
