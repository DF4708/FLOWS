// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import Foundation
import MapKit

/// Exact-coordinate input: overlanders, dispatchers, and off-grid meetups
/// share raw lat/lon ("43.0731, -89.4012", "N 43.0731 W 89.4012",
/// "43.0731N 89.4012W"). Parsed locally — a pasted coordinate plans
/// instantly, with no network and no geocoder involved.
enum CoordinateInput {
    /// nil unless the WHOLE text is exactly two coordinate components.
    /// Hemisphere letters may prefix or suffix either component; S and W
    /// negate; without letters the order is latitude, longitude. Anything
    /// else (street numbers, extra words, out-of-range values) is not a
    /// coordinate.
    static func parse(_ text: String) -> CLLocationCoordinate2D? {
        let cleaned = text.uppercased()
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ";", with: " ")
            .replacingOccurrences(of: "°", with: " ")
        var comps: [(value: Double, hemi: Character?)] = []
        // A hemisphere letter that arrives BEFORE its number ("N 43.07") —
        // consumed by the next numeric token.
        var pendingHemi: Character?
        for token in cleaned.split(separator: " ") where !token.isEmpty {
            var body = String(token)
            var hemi: Character?
            if let first = body.first, "NSEW".contains(first) {
                hemi = first
                body.removeFirst()
            }
            if let last = body.last, "NSEW".contains(last) {
                guard hemi == nil else { return nil }   // "N43W" nonsense
                hemi = last
                body.removeLast()
            }
            // A hemisphere letter as its own token: label the number beside it.
            if body.isEmpty {
                guard let hemi else { return nil }
                if let i = comps.indices.last, comps[i].hemi == nil {
                    comps[i].hemi = hemi   // "43.07 N"
                } else if pendingHemi == nil {
                    pendingHemi = hemi     // "N 43.07"
                } else {
                    return nil
                }
                continue
            }
            guard let value = Double(body) else { return nil }
            comps.append((value, hemi ?? pendingHemi))
            pendingHemi = nil
        }
        guard comps.count == 2, pendingHemi == nil else { return nil }

        func signed(_ c: (value: Double, hemi: Character?)) -> Double {
            switch c.hemi {
            case "S", "W": return -abs(c.value)
            case "N", "E": return abs(c.value)
            default: return c.value
            }
        }
        var lat: Double?
        var lon: Double?
        for c in comps {
            switch c.hemi {
            case "N", "S": guard lat == nil else { return nil }; lat = signed(c)
            case "E", "W": guard lon == nil else { return nil }; lon = signed(c)
            default: break
            }
        }
        // Letter-free components fill the remaining slots in lat, lon order.
        var rest = comps.filter { $0.hemi == nil }.map { signed($0) }.makeIterator()
        if lat == nil { lat = rest.next() }
        if lon == nil { lon = rest.next() }
        guard rest.next() == nil, let lat, let lon,
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Plain display name for a parsed point ("Map point 43.0731, -89.4012").
    static func displayName(_ c: CLLocationCoordinate2D) -> String {
        String(format: "Map point %.4f, %.4f", c.latitude, c.longitude)
    }
}

/// Recently planned destinations: one tap re-plans, instantly and OFFLINE —
/// the places a driver actually goes are a dozen names, not a search index.
/// Small persisted list, ranked by frequency-decayed recency.
@MainActor
final class RecentDestinations: ObservableObject {
    struct Entry: Codable, Equatable, Identifiable {
        var name: String
        var latitude: Double
        var longitude: Double
        var lastUsed: Date
        var uses: Int
        var id: String { name.lowercased() }
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    @Published private(set) var entries: [Entry] = []
    private let url: URL
    /// nonisolated: the pure `merged`/`score` helpers (and their tests) run
    /// off the main actor.
    nonisolated static let cap = 20

    init(directory: URL? = nil) {
        let dir = directory
            ?? (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = dir.appendingPathComponent("flows_recent_destinations.json")
        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = loaded
        }
    }

    /// A plan landed for this destination — remember it (dedupe by name,
    /// newest state wins, capped at the lowest-ranked entry).
    func record(name: String, coordinate: CLLocationCoordinate2D, now: Date = Date()) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.lowercased() != "current location" else { return }
        entries = Self.merged(entries, adding: Entry(
            name: trimmed, latitude: coordinate.latitude, longitude: coordinate.longitude,
            lastUsed: now, uses: 1), now: now)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Pure merge (tested): dedupe by case-insensitive name (uses
    /// accumulate), rank by frequency-decayed recency, cap.
    nonisolated static func merged(_ list: [Entry], adding new: Entry, now: Date) -> [Entry] {
        var out = list
        if let i = out.firstIndex(where: { $0.id == new.id }) {
            out[i].uses += 1
            out[i].lastUsed = new.lastUsed
            out[i].latitude = new.latitude
            out[i].longitude = new.longitude
            out[i].name = new.name
        } else {
            out.append(new)
        }
        out.sort { score($0, now: now) > score($1, now: now) }
        return Array(out.prefix(cap))
    }

    /// Frequency × two-week recency half-life: the daily coffee run outranks
    /// last month's one-off even if the one-off is slightly fresher than one
    /// of its visits.
    nonisolated static func score(_ e: Entry, now: Date) -> Double {
        let ageDays = max(now.timeIntervalSince(e.lastUsed), 0) / 86_400
        return Double(e.uses) * pow(0.5, ageDays / 14)
    }

    /// Entries matching a typed fragment (empty fragment = the top of the
    /// list), best first.
    func matching(_ fragment: String, limit: Int = 3) -> [Entry] {
        let f = fragment.trimmingCharacters(in: .whitespaces).lowercased()
        let hits = f.isEmpty
            ? entries
            : entries.filter { $0.name.lowercased().contains(f) }
        return Array(hits.prefix(limit))
    }
}

/// Live "Where to?" suggestions: street addresses, building/business names,
/// partial words ("pharma" → pharmacies), RECENT destinations, and pasted
/// coordinates — closest/most-used first. Backed by MKLocalSearchCompleter
/// with the search region biased to the driver's position; recents and
/// coordinates resolve locally, so those rows work with no network at all.
@MainActor
final class DestinationSearch: NSObject, ObservableObject {
    struct Suggestion: Identifiable, Equatable {
        enum Kind: Equatable {
            case completion   // Apple completer row
            case recent       // a place this driver has planned before
            case coordinate   // pasted lat/lon
        }
        let id = UUID()
        /// "Publix Super Market" / "160 Convention Center Dr"
        let title: String
        /// "Augusta, GA" — locality context for disambiguation.
        let subtitle: String
        var kind: Kind = .completion
        /// Known for recents and coordinates — those rows can show distance
        /// and plan without a geocoder round trip.
        var coordinate: CLLocationCoordinate2D? = nil
        var distanceMeters: Double? = nil
        /// The text to plan against (title + locality).
        var searchText: String {
            subtitle.isEmpty ? title : "\(title), \(subtitle)"
        }

        static func == (lhs: Suggestion, rhs: Suggestion) -> Bool {
            lhs.title == rhs.title && lhs.subtitle == rhs.subtitle && lhs.kind == rhs.kind
        }
    }

    @Published private(set) var suggestions: [Suggestion] = []

    /// Recents source, injected by the owner (keeps this type free of any
    /// store dependency): fragment → matching entries.
    var recentsProvider: (String) -> [RecentDestinations.Entry] = { _ in [] }

    private let completer = MKLocalSearchCompleter()
    /// Set while programmatically filling the field from a tapped suggestion,
    /// so the fill itself doesn't re-open the suggestion list.
    private var suppressNextUpdate = false
    /// Locally-resolved rows (coordinate + recents) pinned ABOVE whatever the
    /// completer delivers asynchronously.
    private var pinnedRows: [Suggestion] = []

    override init() {
        super.init()
        completer.delegate = self
        // Addresses AND named places AND raw query fragments — the full
        // "convention center by name, home address, or 'pharma'" surface.
        completer.resultTypes = [.address, .pointOfInterest, .query]
    }

    /// Feed the current field text. `near` biases results closest-first
    /// (~50 km box around the driver; Apple expands outward as needed) and
    /// provides the distance shown on locally-resolved rows.
    func update(fragment: String, near center: CLLocationCoordinate2D?) {
        if suppressNextUpdate {
            // One programmatic fill only — and if the fill produced no change
            // event (equal text), the next real keystroke must not be eaten.
            suppressNextUpdate = false
            return
        }
        let trimmed = fragment.trimmingCharacters(in: .whitespaces)

        func distance(_ c: CLLocationCoordinate2D) -> Double? {
            center.map { POIRanking.meters($0, c) }
        }
        var pinned: [Suggestion] = []
        if let point = CoordinateInput.parse(trimmed) {
            pinned.append(Suggestion(
                title: CoordinateInput.displayName(point), subtitle: "Exact map point",
                kind: .coordinate, coordinate: point, distanceMeters: distance(point)))
        }
        for r in recentsProvider(trimmed) {
            pinned.append(Suggestion(
                title: r.name, subtitle: "Recent",
                kind: .recent, coordinate: r.coordinate,
                distanceMeters: distance(r.coordinate)))
        }
        pinnedRows = pinned

        guard trimmed.count >= 2 else {
            // Short fragment: no completer round trip — but a focused empty
            // field still offers the driver's recent places.
            suggestions = pinned
            completer.queryFragment = ""
            return
        }
        suggestions = pinned
        if let center {
            completer.region = MKCoordinateRegion(
                center: center, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        completer.queryFragment = trimmed
    }

    /// Pure blend (tested): pinned local rows first, then completer rows
    /// minus anything that duplicates a pinned title, capped.
    nonisolated static func blend(
        pinned: [Suggestion], completions: [Suggestion], cap: Int = 8
    ) -> [Suggestion] {
        let pinnedTitles = Set(pinned.map { $0.title.lowercased() })
        let fresh = completions.filter { !pinnedTitles.contains($0.title.lowercased()) }
        return Array((pinned + fresh).prefix(cap))
    }

    /// The user tapped a suggestion — clear the list and swallow the field
    /// update the programmatic fill is about to trigger.
    func accept() {
        suppressNextUpdate = true
        suggestions = []
        pinnedRows = []
    }

    func clear() {
        suggestions = []
        pinnedRows = []
    }
}

extension DestinationSearch: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // Copy to value types before hopping actors (MKLocalSearchCompletion
        // is not Sendable).
        let rows = completer.results.prefix(6).map {
            Suggestion(title: $0.title, subtitle: $0.subtitle)
        }
        Task { @MainActor in
            self.suggestions = Self.blend(pinned: self.pinnedRows, completions: Array(rows))
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter,
                               didFailWithError error: Error) {
        // Completer failures keep the locally-resolved rows — recents and
        // coordinates work offline; only Apple's completions go quiet.
        Task { @MainActor in self.suggestions = self.pinnedRows }
    }
}
