// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import MapKit
import SwiftUI

/// The planner card. Destination-first: the hero field is "Where to?", and
/// the source defaults to the live GPS fix (with an optional From override),
/// so the everyday flow is type-destination → Plan. Search section retained
/// for web-app parity (find a place on the map without routing to it).
struct PlannerPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.golden) private var golden
    @Binding var camera: MapCameraPosition
    /// Compact layouts stack the choices panel ACROSS THE TOP, so a framed
    /// route has to sit in the map below it; regular layouts put the panel
    /// down the left side instead.
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var panelOnTop: Bool { sizeClass == .compact }
    #else
    private let panelOnTop = false
    #endif

    @State private var searchQuery = ""
    @StateObject private var destSearch = DestinationSearch()
    /// The start field gets the SAME live suggestions as the destination —
    /// a typed "from" deserves addresses, places, and recents too.
    @StateObject private var sourceSearch = DestinationSearch()
    @State private var overrideSource = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    enum Field { case destination, source }

    /// Fields live on the model so Edit-from-choosing round-trips intact.
    private var source: String { model.plannerSource }
    private var hasGPS: Bool { model.location.coordinate != nil }
    /// No GPS → the source field is always shown (the primary flow must
    /// never dead-end on a Mac without location access). A TYPED start also
    /// keeps the field visible: the model holds the text, so a rotation's
    /// view rebuild (which resets `overrideSource`) must not hide an
    /// override that is still in effect.
    private var showSourceField: Bool {
        overrideSource || !hasGPS
            || !source.trimmingCharacters(in: .whitespaces).isEmpty
    }
    private var usingGPSSource: Bool {
        hasGPS && source.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Starred addresses: one press plans a route there from the GPS
            // fix — no typing.
            if !model.favorites.favorites.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.favorites.favorites) { fav in
                            favoriteChip(fav)
                        }
                    }
                }
            }
            HStack {
                Text("Where to?")
                    .scaledFont(size: 15, weight: .bold)
                    .onChange(of: model.plannerDestination) { _, text in
                        destSearch.update(fragment: text, near: model.location.coordinate)
                    }
                    .onChange(of: model.plannerSource) { _, text in
                        sourceSearch.update(fragment: text, near: model.location.coordinate)
                    }
                    // Focusing an empty field offers the driver's RECENT places
                    // before a single character is typed (works offline).
                    .onChange(of: focusedField) { _, field in
                        switch field {
                        case .destination:
                            destSearch.update(fragment: model.plannerDestination,
                                              near: model.location.coordinate)
                        case .source:
                            sourceSearch.update(fragment: model.plannerSource,
                                                near: model.location.coordinate)
                        case nil:
                            break
                        }
                    }
                    .onAppear {
                        destSearch.recentsProvider = { [weak model] fragment in
                            model?.recents.matching(fragment) ?? []
                        }
                        sourceSearch.recentsProvider = { [weak model] fragment in
                            model?.recents.matching(fragment) ?? []
                        }
                        // Contextual predictions on the destination field only —
                        // the START is where the driver already is.
                        destSearch.predictionProvider = { [weak model] in
                            guard let model else { return [] }
                            return EverydayPlaces.shared.predictions(
                                from: model.effectivePosition ?? model.location.coordinate,
                                limit: 3)
                        }
                    }
                Spacer()
                // X = minimize, not close: the planner tucks into the round
                // search icon at the top right and comes back from there.
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        _ = model.collapsedPanels.insert("planner")
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Tuck the planner away")
            }
            HStack(spacing: 6) {
                TextField("Address, place, city, or ZIP", text: $model.plannerDestination)
                    .textFieldStyle(.plain)
                    .scaledFont(size: 16)
                    .frame(minHeight: Theme.tapMinimum)
                    .padding(.horizontal, 14)
                    .background(Color.black.opacity(0.04))
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                    .focused($focusedField, equals: .destination)
                    // Place names are proper nouns — the system completion
                    // popup only ever "corrects" them, and its window ate the
                    // first click aimed at Plan route.
                    .autocorrectionDisabled()
                    .onSubmit {
                        // Return walks to the start field when one is still
                        // needed (no GPS); otherwise it plans.
                        if showSourceField,
                           model.plannerSource.trimmingCharacters(in: .whitespaces).isEmpty {
                            focusedField = .source
                        } else {
                            Task { await plan() }
                        }
                    }
                // Star: save the typed destination as a favorite, tagged with
                // its role symbol (home / office / …).
                Menu {
                    ForEach(FavoriteAddress.Symbol.allCases) { symbol in
                        Button {
                            Task { await saveFavorite(as: symbol) }
                        } label: {
                            Label("Save as \(symbol.rawValue)", systemImage: symbol.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: destinationIsFavorite ? "star.fill" : "star")
                        .scaledFont(size: 20, weight: .semibold)
                        .foregroundStyle(destinationIsFavorite ? Color.yellow : Color.secondary)
                        .frame(width: 56, height: Theme.tapMinimum)
                        .background(Color.black.opacity(0.04))
                        .clipShape(Capsule())
                }
                .accessibilityLabel(destinationIsFavorite
                                    ? "Saved as a favorite" : "Save as a favorite")
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.plannerDestination.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Save this destination as a favorite")
            }
            // Live lookup while typing: closest matches first (addresses,
            // places, partial words like "pharma"), the driver's recent
            // destinations, and pasted coordinates. Tapping one plans it.
            // ScrollWhenTight (from the layout branch) lets the list alone
            // scroll on a short window — a phone on its side — so Plan route
            // stays reachable; the richer rows (icon by kind, distance,
            // recents and predictions) come from the search work. Both
            // survive: their scroll behaviour wrapping our row rendering.
            if focusedField == .destination, !destSearch.suggestions.isEmpty {
                ScrollWhenTight {
                    suggestionList(destSearch.suggestions) { sug in
                        destSearch.accept()
                        model.plannerDestination = sug.searchText
                        focusedField = nil
                        Task { await plan() }
                    }
                }
            }

            // Source row: GPS by default, tap to override. When there's no
            // GPS fix the field shows automatically with an explanation.
            HStack(spacing: 6) {
                Image(systemName: usingGPSSource ? "location.fill" : "mappin.circle")
                    .font(.footnote)
                    .foregroundStyle(usingGPSSource ? .blue : .secondary)
                    // The icon carries the GPS-vs-manual distinction that
                    // the text alone leaves to color.
                    .accessibilityLabel(usingGPSSource
                                        ? "Starting from your location"
                                        : "Starting from a typed place")
                Text(sourceRowText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if hasGPS {
                    // Keyed off the VISIBLE state, not just `overrideSource`:
                    // with a typed start the field shows regardless, and
                    // "Use GPS" must clear it in one press.
                    Button(showSourceField ? "Use GPS" : "Enter your own location") {
                        if showSourceField {
                            overrideSource = false
                            model.plannerSource = ""
                        } else {
                            overrideSource = true
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
            if showSourceField {
                // Same pill styling as the destination — the roundedBorder
                // style had a near-unclickable hit target on macOS.
                TextField("Start address, place, city, or ZIP", text: $model.plannerSource)
                    .textFieldStyle(.plain)
                    .scaledFont(size: 16)
                    .frame(minHeight: Theme.tapMinimum)
                    .padding(.horizontal, 14)
                    .background(Color.black.opacity(0.04))
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                    .focused($focusedField, equals: .source)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await plan() } }
                // The start field completes like the destination does.
                if focusedField == .source, !sourceSearch.suggestions.isEmpty {
                    suggestionList(sourceSearch.suggestions) { sug in
                        sourceSearch.accept()
                        model.plannerSource = sug.searchText
                        // A filled start + a filled destination = ready; jump
                        // straight to planning. Otherwise walk to Where to?.
                        if model.plannerDestination.trimmingCharacters(in: .whitespaces).isEmpty {
                            focusedField = .destination
                        } else {
                            focusedField = nil
                            Task { await plan() }
                        }
                    }
                }
            }

            Button(isWorking ? "Planning…" : "Plan route") {
                Task { await plan() }
            }
            .buttonStyle(PillCTAStyle())
            .disabled(!planEnabled)
            // macOS: while a text field is editing, SwiftUI spends the click
            // ENDING the session — the button action (and even simultaneous
            // gestures) never fire, so the first Plan click silently did
            // nothing. The AppKit overlay receives the raw mouseUp ahead of
            // SwiftUI's text machinery and fires reliably on the FIRST click.
            #if os(macOS)
            .overlay {
                if planEnabled {
                    FirstClickCatcher {
                        focusedField = nil
                        Task { await plan() }
                    }
                }
            }
            #endif

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Theme.riskRed)
            }

        }
        .onAppear { focusedField = .destination }
        .collapsibleMenu("planner")
        .floatingCard()
    }

    /// One suggestion list for both fields: icon says WHAT each row is
    /// (recent / exact point / lookup), distance says how far when known —
    /// recents and coordinates resolve locally, so those rows work offline.
    private func suggestionList(
        _ suggestions: [DestinationSearch.Suggestion],
        onPick: @escaping (DestinationSearch.Suggestion) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions) { sug in
                Button {
                    onPick(sug)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: icon(for: sug.kind))
                            .scaledFont(size: 13, weight: .semibold)
                            .foregroundStyle(sug.kind == .completion ? Color.secondary : Theme.cta)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sug.title)
                                .scaledFont(size: 14, weight: .semibold)
                                .foregroundStyle(.primary)
                            if !sug.subtitle.isEmpty {
                                Text(sug.subtitle)
                                    .scaledFont(size: 11)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 4)
                        if let meters = sug.distanceMeters {
                            Text(Self.milesText(meters))
                                .scaledFont(size: 11, weight: .semibold)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if sug.id != suggestions.last?.id {
                    Divider()
                }
            }
        }
        .background(Color.black.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func icon(for kind: DestinationSearch.Suggestion.Kind) -> String {
        switch kind {
        case .recent: return "clock.arrow.circlepath"
        case .predicted: return "sparkles"
        case .coordinate: return "mappin.and.ellipse"
        case .completion: return "magnifyingglass"
        }
    }

    /// "0.4 mi" under ten miles, whole miles beyond.
    static func milesText(_ meters: Double) -> String {
        let miles = meters / 1609.344
        return miles < 10
            ? String(format: "%.1f mi", miles)
            : String(format: "%.0f mi", miles)
    }

    /// One truth for "can Plan fire": the button's disabled state and its
    /// click-swallow fallback gesture must always agree.
    private var planEnabled: Bool {
        !isWorking && !model.plannerDestination.isEmpty
            && (hasGPS || !source.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func search() async {
        guard !searchQuery.isEmpty else { return }
        errorMessage = nil
        do {
            let (coord, _) = try await model.router.geocode(
                searchQuery, near: model.location.coordinate)
            withAnimation {
                camera = .region(MKCoordinateRegion(
                    center: coord,
                    latitudinalMeters: 60_000, longitudinalMeters: 60_000))
            }
        } catch {
            errorMessage = Self.friendlyError(error)
        }
    }

    /// Frame a route for the choosing layout — the geometry lives in
    /// CameraZoom.framedRect (pure, tested).
    static func choicesCameraRect(_ rect: MKMapRect,
                                  panelOnTop: Bool = false,
                                  windowAspect: Double = 2.0) -> MKMapRect {
        CameraZoom.framedRect(rect, panelOnTop: panelOnTop,
                              windowAspect: windowAspect)
    }

    /// Plain-words error text — never surface raw framework errors like
    /// "kCLErrorDomain error 8" (geocoder found nothing) to the driver.
    private static func friendlyError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == kCLErrorDomain {
            switch ns.code {
            case 8: return "Couldn't find that place. Check the spelling or add a city or state."
            case 2: return "No internet right now — try again when you're back in coverage."
            default: return "Couldn't look that up right now. Try again in a moment."
            }
        }
        if (error as? URLError) != nil {
            return "No internet right now — try again when you're back in coverage."
        }
        return "Couldn't plan that route. Try again in a moment."
    }

    // MARK: favorites

    private var destinationIsFavorite: Bool {
        model.favorites.contains(name: model.plannerDestination.trimmingCharacters(in: .whitespaces))
    }

    private func favoriteChip(_ fav: FavoriteAddress) -> some View {
        Button {
            Task {
                isWorking = true
                defer { isWorking = false }
                if let planned = await model.planToFavorite(fav), let first = planned.first {
                    withAnimation {
                        camera = .rect(Self.choicesCameraRect(
                        first.route.polyline.boundingMapRect,
                        panelOnTop: panelOnTop,
                        windowAspect: golden.size.height / max(golden.size.width, 1)))
                    }
                } else {
                    errorMessage = "Couldn't plan to \(fav.name) — no GPS fix or no route."
                }
            }
        } label: {
            Label(fav.name, systemImage: fav.symbol.systemImage)
                .scaledFont(size: 13, weight: .semibold)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .background(Color.black.opacity(0.05))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                model.favorites.remove(fav)
            } label: {
                Label("Remove favorite", systemImage: "trash")
            }
        }
    }

    private func saveFavorite(as symbol: FavoriteAddress.Symbol) async {
        let text = model.plannerDestination.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        errorMessage = nil
        do {
            let (coord, name) = try await model.router.geocode(
                text, near: model.location.coordinate)
            model.favorites.add(FavoriteAddress(
                name: name, symbol: symbol,
                latitude: coord.latitude, longitude: coord.longitude))
        } catch {
            errorMessage = Self.friendlyError(error)
        }
    }

    private var sourceRowText: String {
        if usingGPSSource { return "From: Current Location" }
        if !hasGPS { return "From: (no GPS on this device — enter a start)" }
        return "From:"
    }

    private func plan() async {
        destSearch.clear()   // suggestions down once a plan starts
        sourceSearch.clear()
        // Reentry guard: the button's action AND its simultaneous tap gesture
        // can both fire on one click — the second call must be a no-op.
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            // GPS is the source unless a start was typed (or GPS is absent).
            // Source and destination geocode CONCURRENTLY so the destination
            // never queues behind a typed start.
            let from: (CLLocationCoordinate2D, String)
            let to: (CLLocationCoordinate2D, String)
            if usingGPSSource {
                guard let here = model.location.coordinate else {
                    throw RouteError.notFound("current location (no GPS fix yet)")
                }
                from = (here, "Current location")
                to = try await model.router.geocode(
                    model.plannerDestination, near: model.location.coordinate)
            } else {
                async let fromF = model.router.geocode(source, near: model.location.coordinate)
                to = try await model.router.geocode(
                    model.plannerDestination, near: model.location.coordinate)
                from = try await fromF
            }
            // Routes appear as soon as directions return; weather badges
            // hydrate asynchronously inside present(routes:), and the
            // corridor prefetch fires inside model.plan — the choke point
            // every planning path shares. Planning goes through the model so
            // filter toggles can replan variants later.
            let planned = try await model.plan(
                from: from.0, fromName: from.1,
                to: to.0, toName: to.1)
            model.present(routes: planned)
            // Frame the full corridor while choosing.
            if let first = planned.first {
                withAnimation {
                    camera = .rect(Self.choicesCameraRect(
                        first.route.polyline.boundingMapRect,
                        panelOnTop: panelOnTop,
                        windowAspect: golden.size.height / max(golden.size.width, 1)))
                }
            }
        } catch {
            errorMessage = Self.friendlyError(error)
        }
    }
}

#if os(macOS)
/// AppKit-level click catcher for a button that sits next to text fields.
/// SwiftUI-native fields CONSUME the click that ends their editing session —
/// the button's action (and even simultaneous gestures) never see it, so the
/// first click "does nothing". A real NSView receives the event from AppKit's
/// dispatch BEFORE SwiftUI's text machinery, making the first click land
/// every time. Fires on mouse-up inside bounds, like a normal button.
private struct FirstClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.action = action
        return view
    }

    func updateNSView(_ view: ClickView, context: Context) {
        view.action = action
    }

    final class ClickView: NSView {
        var action: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {}   // claim the click
        override func mouseUp(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            if bounds.contains(p) { action?() }
        }
    }
}
#endif
