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
/// can actually resolve, or it is dropped. Everything here is pure, computed
/// in rust/flows-core (alert_text.rs) and pinned by FLOWSTests and by
/// rust/flows-bridge/tests/fixtures/swift_alert_text_oracle.tsv.
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
        var phrases: [String] { flows_alert_text_phrases(rustCode).map { $0.text } }

        /// The kind's position in `allCases`, the code alert_text.rs uses.
        var rustCode: UInt8 { UInt8(Kind.allCases.firstIndex(of: self) ?? 0) }

        init?(rustCode code: UInt8) {
            guard Int(code) < Kind.allCases.count else { return nil }
            self = Kind.allCases[Int(code)]
        }
    }

    /// Kinds tried in order — the specific before the general. A call that
    /// says "motor vehicle accident with injury" is a crash, not a medical;
    /// one that says "officer" AND "structure fire" is the fire.
    static let matchOrder: [Kind] = flows_alert_text_match_order().compactMap { Kind(rustCode: $0) }

    /// What kind of call this transcript describes, or nil when nothing in
    /// it is recognizable. Silence beats a guess.
    static func kind(inTranscript text: String) -> Kind? {
        let code = flows_alert_text_call_kind(text)
        return code < 0 ? nil : Kind(rustCode: UInt8(code))
    }

    // MARK: pulling a place out of the words

    /// Road-type words a dispatcher actually says. Used to find the tail of
    /// an address or a cross-street pair.
    static let roadWords: [String] = flows_alert_text_road_words().map { $0.text }

    /// A place mentioned in a transcript, as text to be geocoded.
    ///
    /// Two shapes are worth trusting: a street ADDRESS ("2100 Washington
    /// Road") and a CROSS STREET pair ("Belair Road and Columbia Road").
    /// Anything vaguer — a unit number, a landmark nickname, a beat code —
    /// is not a location this app can put a pin on, so it returns nil and
    /// the incident is dropped.
    static func placePhrase(inTranscript text: String) -> String? {
        let phrase = flows_alert_text_place_phrase(text).text
        return phrase.isEmpty ? nil : phrase
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
        flows_alert_text_lifetime_seconds(kind.rustCode)
    }

    static func isExpired(_ incident: Incident, now: Date = Date()) -> Bool {
        flows_alert_text_is_expired(incident.kind.rustCode,
                                    incident.heardAt.timeIntervalSinceReferenceDate,
                                    now.timeIntervalSinceReferenceDate)
    }

    /// How far from the driver an incident is worth drawing. Beyond this it
    /// is somebody else's town.
    static let relevantMeters: Double = flows_alert_text_pin_constants()[0]

    /// Keep only what is still live and still near the driver or the route
    /// corridor. `corridor` is a coarse sample of the route.
    static func visible(_ incidents: [Incident],
                        near position: CLLocationCoordinate2D?,
                        corridor: [CLLocationCoordinate2D] = [],
                        now: Date = Date()) -> [Incident] {
        guard !incidents.isEmpty else { return [] }
        let kinds = incidents.map { $0.kind.rustCode }
        let lats = incidents.map(\.coordinate.latitude), lons = incidents.map(\.coordinate.longitude)
        let heard = incidents.map { $0.heardAt.timeIntervalSinceReferenceDate }
        // An empty corridor crosses as one placeholder point its count ignores.
        let cLats = corridor.isEmpty ? [0] : corridor.map(\.latitude)
        let cLons = corridor.isEmpty ? [0] : corridor.map(\.longitude)
        let kept = kinds.withUnsafeBufferPointer { k in
            lats.withUnsafeBufferPointer { la in
                lons.withUnsafeBufferPointer { lo in
                    heard.withUnsafeBufferPointer { h in
                        cLats.withUnsafeBufferPointer { cla in
                            cLons.withUnsafeBufferPointer { clo in
                                flows_alert_text_visible(k, la, lo, h, position != nil,
                                                         position?.latitude ?? 0, position?.longitude ?? 0,
                                                         cla, clo, Int64(corridor.count),
                                                         now.timeIntervalSinceReferenceDate)
                            }
                        }
                    }
                }
            }
        }
        return kept.map { incidents[Int($0)] }
    }

    /// Fold a new incident into a list, replacing an earlier report of the
    /// same thing rather than stacking pins on one corner.
    ///
    /// Dispatch repeats itself constantly — the same call is read out to
    /// several units — so without this a single crash becomes a cluster.
    static let duplicateMeters: Double = flows_alert_text_pin_constants()[1]

    static func merged(_ existing: [Incident], adding new: Incident) -> [Incident] {
        guard !existing.isEmpty else { return [new] }
        let kinds = existing.map { $0.kind.rustCode }
        let lats = existing.map(\.coordinate.latitude), lons = existing.map(\.coordinate.longitude)
        let kept = kinds.withUnsafeBufferPointer { k in
            lats.withUnsafeBufferPointer { la in
                lons.withUnsafeBufferPointer { lo in
                    flows_alert_text_merged_keep(k, la, lo, new.kind.rustCode,
                                                 new.coordinate.latitude, new.coordinate.longitude)
                }
            }
        }
        var out = kept.map { existing[Int($0)] }
        out.append(new)
        return out
    }
}
