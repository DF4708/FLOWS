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
        // flows_core::recents_and_rides::parse_coordinate.
        let point = flows_rides_parse_coordinate(text)
        return point.has ? CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon) : nil
    }

    /// Plain display name for a parsed point ("Map point 43.0731, -89.4012").
    static func displayName(_ c: CLLocationCoordinate2D) -> String {
        String(format: "Map point %.4f, %.4f", c.latitude, c.longitude)
    }
}

/// A planner field filled from a row that carries its own place (recent,
/// predicted, map point, favorite): planning goes straight to that point
/// while the field still holds `text`. Planning re-geocoded the row's text
/// instead — "Map point 43.0731, -89.4012" is no address, and a recent
/// saved under its town name landed in the town's centre.
struct PlannerPick {
    let text: String
    let coordinate: CLLocationCoordinate2D
    let name: String

    /// The pick stands until the driver changes the field (spaces at the
    /// ends aside).
    func stands(for fieldText: String) -> Bool {
        fieldText.trimmingCharacters(in: .whitespaces) == text.trimmingCharacters(in: .whitespaces)
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
    nonisolated static let cap = Int(flows_rides_recents_cap())

    init(directory: URL? = nil) {
        let dir = directory
            ?? (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        url = dir.appendingPathComponent("flows_recent_destinations.json")
        // ENCRYPTED AT REST: a destination history is a map of someone's
        // life. Sealed with the device-only key; upgraded in place from any
        // plaintext file an earlier build left behind.
        if let data = SecureBehaviorStore.readMigrating(url),
           let loaded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = loaded
        }
    }

    /// A plan landed for this destination — remember it (dedupe by name,
    /// newest state wins, capped at the lowest-ranked entry).
    func record(name: String, coordinate: CLLocationCoordinate2D, now: Date = Date()) {
        // Empty when the name is blank or "current location" in any case.
        let trimmed = flows_rides_recordable_name(name).text
        guard !trimmed.isEmpty else { return }
        entries = Self.merged(entries, adding: Entry(
            name: trimmed, latitude: coordinate.latitude, longitude: coordinate.longitude,
            lastUsed: now, uses: 1), now: now)
        SecureBehaviorStore.save(entries, to: url)
    }

    /// Pure merge (tested): dedupe by case-insensitive name (uses
    /// accumulate), rank by frequency-decayed recency, cap.
    nonisolated static func merged(_ list: [Entry], adding new: Entry, now: Date) -> [Entry] {
        // flows_core::recents_and_rides::merged_recent_order: the merged
        // place's use count, then the order as indices, -1 for the merged
        // place (the new name, place and time with that count).
        let names = RustTextColumn(list.map(\.name))
        let lastUsed = list.isEmpty ? [0] : list.map { $0.lastUsed.timeIntervalSinceReferenceDate }
        let uses = list.isEmpty ? [0] : list.map { Int64($0.uses) }
        let answer = names.with { joined, lengths, _ in
            lastUsed.withUnsafeBufferPointer { lu in
                uses.withUnsafeBufferPointer { us in
                    Array(flows_rides_merged_recents(
                        joined, lengths, lu, us, Int64(list.count),
                        new.name, new.lastUsed.timeIntervalSinceReferenceDate, Int64(new.uses),
                        now.timeIntervalSinceReferenceDate))
                }
            }
        }
        // A real answer is the count and at least one index; the bridge's
        // failure fallback is the count alone, and then the list stays.
        guard answer.count >= 2, let mergedUses = answer.first else { return list }
        var merged = new
        merged.uses = Int(mergedUses)
        return answer.dropFirst().map { $0 < 0 ? merged : list[Int($0)] }
    }

    /// Frequency × two-week recency half-life: the daily coffee run outranks
    /// last month's one-off even if the one-off is slightly fresher than one
    /// of its visits.
    nonisolated static func score(_ e: Entry, now: Date) -> Double {
        flows_rides_recent_score(Int64(e.uses), e.lastUsed.timeIntervalSinceReferenceDate,
                                 now.timeIntervalSinceReferenceDate)
    }

    /// Forget every recorded destination.
    func erase() {
        entries = []
        SecureBehaviorStore.shred(url)
    }

    /// Entries matching a typed fragment (empty fragment = the top of the
    /// list), best first.
    func matching(_ fragment: String, limit: Int = 3) -> [Entry] {
        // flows_core::recents_and_rides::matching_recents, over the entries
        // in rank order.
        let names = RustTextColumn(entries.map(\.name))
        let picks = names.with { joined, lengths, _ in
            Array(flows_rides_matching_recents(joined, lengths, Int64(entries.count),
                                               fragment, Int64(limit)))
        }
        return picks.map { entries[Int($0)] }
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
            case predicted    // where they usually go at this hour, from here
            case coordinate   // pasted lat/lon
        }
        /// What the row IS, not when it was made. A fresh UUID per rebuild
        /// gave every keystroke's rows new identities, so SwiftUI replaced
        /// the row under the pointer and the click that picked it was lost.
        var id: String { "\(title)|\(subtitle)|\(kind)" }
        /// "Publix Super Market" / "160 Convention Center Dr"
        let title: String
        /// "Augusta, GA" — locality context for disambiguation.
        let subtitle: String
        var kind: Kind = .completion
        /// Known for recents and coordinates — those rows can show distance
        /// and plan without a geocoder round trip.
        var coordinate: CLLocationCoordinate2D? = nil
        var distanceMeters: Double? = nil
        /// The text to plan against.
        ///
        /// Only a COMPLETION's subtitle is locality context ("Augusta, GA")
        /// worth folding into the query. The other kinds use the subtitle as
        /// a badge — "Recent", "Exact map point", or the reason a prediction
        /// was made — and appending one of those produced queries like
        /// "Sun Prairie, Recent", which geocodes to nothing and shows the
        /// driver "couldn't find that place" for a town they visit weekly.
        /// Those rows all carry their own `coordinate` anyway, so they never
        /// needed a geocoder round trip in the first place.
        var searchText: String {
            guard kind == .completion, !subtitle.isEmpty else { return title }
            return "\(title), \(subtitle)"
        }

        /// A row with its own coordinate plans there directly, named by its
        /// title; a completion (no coordinate) is looked up.
        var pick: PlannerPick? {
            coordinate.map { PlannerPick(text: searchText, coordinate: $0, name: title) }
        }

        static func == (lhs: Suggestion, rhs: Suggestion) -> Bool {
            lhs.title == rhs.title && lhs.subtitle == rhs.subtitle && lhs.kind == rhs.kind
        }
    }

    @Published private(set) var suggestions: [Suggestion] = []

    /// Recents source, injected by the owner (keeps this type free of any
    /// store dependency): fragment → matching entries.
    var recentsProvider: (String) -> [RecentDestinations.Entry] = { _ in [] }
    /// Contextual predictions for an EMPTY field — "where are you going
    /// right now", from the time, the day, and where the driver is standing.
    /// Only offered before they start typing: once they type, they have told
    /// us where they're going and guessing is just noise.
    var predictionProvider: () -> [DestinationPrediction.Candidate] = { [] }

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
        // Empty field: lead with where this driver usually goes at this hour,
        // on this kind of day, from about here. Each row carries its own
        // reason, so a suggestion about someone's own movements is never
        // unexplained.
        if trimmed.isEmpty {
            for p in predictionProvider() {
                pinned.append(Suggestion(
                    title: p.name, subtitle: p.reason,
                    kind: .predicted, coordinate: p.coordinate,
                    distanceMeters: distance(p.coordinate)))
            }
        }
        for r in recentsProvider(trimmed) {
            pinned.append(Suggestion(
                title: r.name, subtitle: "Recent",
                kind: .recent, coordinate: r.coordinate,
                distanceMeters: distance(r.coordinate)))
        }
        pinnedRows = Self.blend(pinned: [], completions: pinned, cap: 8)

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
        // flows_core::recents_and_rides::blend_suggestions: a pinned row i
        // as i, a completion j as -(j + 1).
        let p = RustTextColumn(pinned.map(\.title))
        let c = RustTextColumn(completions.map(\.title))
        let rows = p.with { pj, pl, _ in
            c.with { cj, cl, _ in
                Array(flows_rides_blend_suggestions(pj, pl, Int64(pinned.count),
                                                    cj, cl, Int64(completions.count), Int64(cap)))
            }
        }
        return rows.map { $0 >= 0 ? pinned[Int($0)] : completions[Int(-$0 - 1)] }
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
