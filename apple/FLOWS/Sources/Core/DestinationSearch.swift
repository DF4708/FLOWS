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

/// Live "Where to?" suggestions: street addresses, building/business names,
/// and partial words ("pharma" → pharmacies), CLOSEST-FIRST. Backed by
/// MKLocalSearchCompleter with the search region biased to the driver's
/// position — Apple resolves the fragment against nearby results first and
/// widens on its own, so typing "Publix" surfaces the closest Publix without
/// FLOWS ever scanning a whole database.
@MainActor
final class DestinationSearch: NSObject, ObservableObject {
    struct Suggestion: Identifiable, Equatable {
        let id = UUID()
        /// "Publix Super Market" / "160 Convention Center Dr"
        let title: String
        /// "Augusta, GA" — locality context for disambiguation.
        let subtitle: String
        /// The text to plan against (title + locality).
        var searchText: String {
            subtitle.isEmpty ? title : "\(title), \(subtitle)"
        }
    }

    @Published private(set) var suggestions: [Suggestion] = []

    private let completer = MKLocalSearchCompleter()
    /// Set while programmatically filling the field from a tapped suggestion,
    /// so the fill itself doesn't re-open the suggestion list.
    private var suppressNextUpdate = false

    override init() {
        super.init()
        completer.delegate = self
        // Addresses AND named places AND raw query fragments — the full
        // "convention center by name, home address, or 'pharma'" surface.
        completer.resultTypes = [.address, .pointOfInterest, .query]
    }

    /// Feed the current field text. `near` biases results closest-first
    /// (~50 km box around the driver; Apple expands outward as needed).
    func update(fragment: String, near center: CLLocationCoordinate2D?) {
        if suppressNextUpdate {
            // One programmatic fill only — and if the fill produced no change
            // event (equal text), the next real keystroke must not be eaten.
            suppressNextUpdate = false
            return
        }
        let trimmed = fragment.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            suggestions = []
            completer.queryFragment = ""
            return
        }
        if let center {
            completer.region = MKCoordinateRegion(
                center: center, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        completer.queryFragment = trimmed
    }

    /// The user tapped a suggestion — clear the list and swallow the field
    /// update the programmatic fill is about to trigger.
    func accept() {
        suppressNextUpdate = true
        suggestions = []
    }

    func clear() {
        suggestions = []
    }
}

extension DestinationSearch: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // Copy to value types before hopping actors (MKLocalSearchCompletion
        // is not Sendable).
        let rows = completer.results.prefix(6).map {
            Suggestion(title: $0.title, subtitle: $0.subtitle)
        }
        Task { @MainActor in self.suggestions = Array(rows) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter,
                               didFailWithError error: Error) {
        // Suggestion failures are silent — the field still plans on submit.
        Task { @MainActor in self.suggestions = [] }
    }
}
