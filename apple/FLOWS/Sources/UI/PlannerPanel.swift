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
    @Environment(\.openURL) private var openURL
    @Binding var camera: MapCameraPosition
    /// Compact layouts stack the choices panel ACROSS THE TOP, so a framed
    /// route has to sit in the map ABOVE it — the top of the screen is the
    /// most valuable map space, so the cards live at the bottom near the
    /// thumb. Regular layouts put the panel down the left side instead.
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var panelEdge: CameraZoom.PanelEdge {
        sizeClass == .compact ? .bottom : .leading
    }
    #else
    private let panelEdge = CameraZoom.PanelEdge.leading
    #endif

    @State private var searchQuery = ""
    @StateObject private var destSearch = DestinationSearch()
    /// The start field gets the SAME live suggestions as the destination —
    /// a typed "from" deserves addresses, places, and recents too.
    @StateObject private var sourceSearch = DestinationSearch()
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?
    /// Which field's suggestion list is up. Raised when that field takes
    /// focus, lowered a beat after focus leaves — not by the focus change
    /// itself, so a row survives the click that picks it.
    @State private var listUp: Field?

    enum Field { case destination, source }

    /// Fields live on the model so Edit-from-choosing round-trips intact.
    private var source: String { model.plannerSource }
    private var hasGPS: Bool { model.location.coordinate != nil }
    /// "From where?" shows when the GPS switch is off, and always when there
    /// is no GPS at all (the primary flow must never dead-end on a Mac
    /// without location access). The switch lives on the model, so a
    /// rotation's view rebuild keeps it.
    private var showSourceField: Bool {
        !model.plannerUseGPS || !hasGPS
    }
    private var usingGPSSource: Bool {
        hasGPS && model.plannerUseGPS
    }

    /// No fix, nothing typed, but a Home or a learned everyday area to
    /// start from — the Mac's usual state.
    private var usingFallbackStart: Bool {
        !hasGPS && source.trimmingCharacters(in: .whitespaces).isEmpty
            && model.bestKnownPosition != nil
    }

    /// The GPS switch: on by default; off, the planner asks "From where?".
    /// Off and greyed when there is no GPS to use.
    private var gpsToggle: some View {
        Toggle(isOn: Binding(
            get: { usingGPSSource },
            set: { on in
                model.plannerUseGPS = on
                if on {
                    model.plannerSource = ""
                    model.plannerSourcePick = nil
                } else {
                    focusedField = .source
                }
            })) {
            Label("GPS", systemImage: "location.fill")
                .scaledFont(.footnote, weight: .semibold)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .fixedSize()
        .disabled(!hasGPS)
        .help(hasGPS ? "Start from where you are; off lets you type a start"
                     : "No GPS on this device — type a start")
    }

    /// Plan the way back too: arriving offers "Head back".
    private var roundTripToggle: some View {
        Toggle(isOn: $model.roundTrip) {
            Label("Round trip", systemImage: "arrow.triangle.2.circlepath")
                .scaledFont(.footnote, weight: .semibold)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .fixedSize()
        .help("Come back to where you started: at the destination, Head back plans the way home")
    }

    /// Why the start field is showing when the driver didn't turn GPS off.
    @ViewBuilder
    private var sourceNote: some View {
        if !hasGPS {
            HStack(spacing: 6) {
                Text(sourceRowText)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                if model.location.denied, let url = locationSettingsURL {
                    // The one way back to the permission after "Don't Allow".
                    Button("Open Settings") { openURL(url) }
                        .scaledFont(.caption, weight: .semibold)
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                }
            }
        }
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
            // The trip's two switches, then the X.
            HStack(spacing: 12) {
                gpsToggle
                roundTripToggle
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
                    // The stored providers must not retain the model, so the
                    // weak capture is taken ONCE here and every provider reads
                    // that binding — a `[weak model]` on each inner closure
                    // while this outer closure captured `model` strongly is
                    // what the compiler flags (ImplicitStrongCapture).
                    .onAppear { [weak model] in
                        destSearch.recentsProvider = { fragment in
                            model?.recents.matching(fragment) ?? []
                        }
                        sourceSearch.recentsProvider = { fragment in
                            model?.recents.matching(fragment) ?? []
                        }
                        // Contextual predictions on the destination field only —
                        // the START is where the driver already is.
                        destSearch.predictionProvider = {
                            guard let model else { return [] }
                            return EverydayPlaces.shared.predictions(
                                from: model.effectivePosition ?? model.location.coordinate,
                                limit: 3)
                        }
                    }
                Spacer(minLength: 0)
                // X = minimize, not close: the planner tucks into the round
                // search icon at the top right and comes back from there.
                Button {
                    // The keyboard goes with the planner; it stayed up over
                    // the map after the planner tucked away.
                    focusedField = nil
                    withAnimation(.easeInOut(duration: 0.2)) {
                        _ = model.collapsedPanels.insert("planner")
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Tuck the planner away")
            }
            // GPS off: where the trip starts, ABOVE where it goes.
            if showSourceField {
                Text("From where?")
                    .scaledFont(size: 15, weight: .bold)
                sourceNote
                // Same pill styling as the destination — the roundedBorder
                // style had a near-unclickable hit target on macOS.
                TextField(usingFallbackStart || (!hasGPS && model.bestKnownPosition != nil)
                          ? "Start address — empty starts from \(model.bestKnownPosition?.label ?? "home")"
                          : "Start address, place, city, or ZIP",
                          text: $model.plannerSource)
                    .textFieldStyle(.plain)
                    .scaledFont(size: 16)
                    .frame(minHeight: Theme.tapMinimum)
                    .padding(.horizontal, 14)
                    .background(Theme.fill(0.04))
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                    .focused($focusedField, equals: .source)
                    .autocorrectionDisabled()
                    .onSubmit {
                        // Return walks on to Where to? until it is filled.
                        if model.plannerDestination.trimmingCharacters(in: .whitespaces).isEmpty {
                            focusedField = .destination
                        } else {
                            Task { await plan() }
                        }
                    }
                // The start field completes like the destination does.
                if listUp == .source {
                    // Capped and scrolling like the destination's list: an
                    // uncapped list of eight rows ran Plan route off a small
                    // Mac window.
                    ScrollWhenTight(maxHeight: min(280, golden.size.height / 3), growsOnly: true) {
                        suggestionList(sourceSearch.suggestions) { sug in
                            sourceSearch.accept()
                            model.plannerSource = sug.searchText
                            model.plannerSourcePick = sug.pick
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
                    .background(sourceSearch.suggestions.isEmpty ? Color.clear : Theme.fill(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            Text("Where to?")
                .scaledFont(size: 15, weight: .bold)
            HStack(spacing: 6) {
                TextField("Address, place, city, or ZIP", text: $model.plannerDestination)
                    .textFieldStyle(.plain)
                    .scaledFont(size: 16)
                    .frame(minHeight: Theme.tapMinimum)
                    .padding(.horizontal, 14)
                    .background(Theme.fill(0.04))
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                    .focused($focusedField, equals: .destination)
                    // On the Mac, clicking a suggestion first moves focus
                    // OFF the field; the list was keyed on focus alone, so it
                    // vanished before the click could land and no suggestion
                    // was ever selectable. The list is raised when a field
                    // TAKES focus and lowered a moment after focus leaves —
                    // never in the same pass as the click, which tore the row
                    // out from under the pointer between its press and its
                    // release and lost the very first pick after launch.
                    .onChange(of: focusedField) { previous, current in
                        if let current {
                            listUp = current
                            return
                        }
                        let left = previous
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            if focusedField == nil, listUp == left { listUp = nil }
                        }
                    }
                    // Place names are proper nouns — the system completion
                    // popup only ever "corrects" them, and its window ate the
                    // first click aimed at Plan route.
                    .autocorrectionDisabled()
                    .onSubmit {
                        // Return walks to the start field when one is still
                        // needed (no GPS and nothing to fall back on, or the
                        // driver asked to type one); otherwise it plans.
                        if showSourceField, !usingFallbackStart,
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
                    // Solid yellow either way; whether it is saved yet is
                    // said to VoiceOver and in the help text.
                    Image(systemName: "star.fill")
                        .scaledFont(size: 20, weight: .semibold)
                        .foregroundStyle(Color.yellow)
                        .frame(width: 56, height: Theme.tapMinimum)
                        .background(Theme.fill(0.04))
                        .clipShape(Capsule())
                }
                .accessibilityLabel(destinationIsFavorite
                                    ? "Saved as a favorite" : "Save as a favorite")
                .menuIndicator(.hidden)
                // Plain: on the Mac a Menu draws its own pull-down bezel,
                // which put the star a different height from the field.
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .disabled(model.plannerDestination.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(destinationIsFavorite ? "Saved as a favorite"
                                            : "Save this destination as a favorite")
            }
            // Live lookup while typing: closest matches first (addresses,
            // places, partial words like "pharma"), the driver's recent
            // destinations, and pasted coordinates. Tapping one plans it.
            // ScrollWhenTight (from the layout branch) lets the list alone
            // scroll on a short window — a phone on its side — so Plan route
            // stays reachable; the richer rows (icon by kind, distance,
            // recents and predictions) come from the search work. Both
            // survive: their scroll behaviour wrapping our row rendering.
            // The list stays up, empty, while its field has focus: between a
            // keystroke and the results that follow it the suggestions are
            // often empty, and a list that went away there lost the height
            // it had grown to.
            if listUp == .destination {
                // As tall as its rows, up to a cap, and ONE copy of them.
                // A plain ScrollView always grew to its cap, so one recent
                // place sat on a tall empty box that pushed the cards above
                // it out of room. ScrollWhenTight used to be a ViewThatFits
                // holding the list twice, and as suggestions changed under
                // the pointer it swapped which copy was live: on the Mac the
                // click landed on a row that had just been replaced. It now
                // holds one copy.
                // Never more than a third of the window: at the Mac's
                // smallest window a full 280 pt list ran Plan route off the
                // bottom.
                // It grows but does not shrink while it is open: results
                // arrive after each keystroke, and a list that shrank and
                // grew again moved the field above it under the pointer.
                ScrollWhenTight(maxHeight: min(280, golden.size.height / 3), growsOnly: true) {
                    suggestionList(destSearch.suggestions) { sug in
                        destSearch.accept()
                        model.plannerDestination = sug.searchText
                        model.plannerDestinationPick = sug.pick
                        listUp = nil
                        // GPS off and no start typed yet: the start comes
                        // first — planning from an empty start only said
                        // "Couldn't find that place".
                        if showSourceField, !usingFallbackStart,
                           model.plannerSource.trimmingCharacters(in: .whitespaces).isEmpty {
                            focusedField = .source
                        } else {
                            focusedField = nil
                            Task { await plan() }
                        }
                    }
                }
                .background(destSearch.suggestions.isEmpty ? Color.clear : Theme.fill(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                    .scaledFont(.footnote)
                    .foregroundStyle(Theme.riskRed)
            }

        }
        .onAppear {
            focusedField = .destination
            listUp = .destination   // the focus change to a field raises it; this is the first one
        }
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
                // The same first-click rule as Plan route: while the field
                // above is being edited, the Mac spends the click ending that
                // edit and the row's action never fires — which is why the
                // first pick after launch did nothing.
                #if os(macOS)
                .overlay { FirstClickCatcher { onPick(sug) } }
                #endif
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
            && (hasGPS || usingFallbackStart
                || !source.trimmingCharacters(in: .whitespaces).isEmpty)
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
                                  panelEdge: CameraZoom.PanelEdge = .leading,
                                  windowAspect: Double = 2.0,
                                  panelFraction: Double
                                    = CameraZoom.choicesPanelFraction) -> MKMapRect {
        CameraZoom.framedRect(rect, panelEdge: panelEdge,
                              windowAspect: windowAspect,
                              panelFraction: panelFraction)
    }

    /// Plain-words error text — never surface raw framework errors like
    /// "kCLErrorDomain error 8" (geocoder found nothing) to the driver
    /// (RouteError.plainMessage, pinned by tests).
    private static func friendlyError(_ error: Error) -> String {
        RouteError.plainMessage(for: error)
    }

    /// The system page where FLOWS's location switch lives.
    private var locationSettingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
        #endif
    }

    /// Where a field's text plans to: the picked row's own point while the
    /// field still holds its text, else a geocoder lookup.
    private func resolve(_ text: String, pick: PlannerPick?) async throws
        -> (CLLocationCoordinate2D, String) {
        if let pick, pick.stands(for: text) { return (pick.coordinate, pick.name) }
        return try await model.router.geocode(text, near: model.location.coordinate)
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
                // The highlighted route, which the filters may have moved
                // off the first.
                if let planned = await model.planToFavorite(fav),
                   let first = model.routeChoices.first(where: { $0.id == model.highlightedRouteID })
                    ?? planned.first,
                   let rect = CameraZoom.usableRect(first.route.polyline.boundingMapRect) {
                    withAnimation {
                        camera = .rect(Self.choicesCameraRect(
                        rect,
                        panelEdge: panelEdge,
                        windowAspect: golden.size.height / max(golden.size.width, 1),
                        panelFraction: panelEdge == .bottom ? golden.choicesPanelFraction
                                                  : CameraZoom.choicesPanelFraction))
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
                .background(Theme.fill(0.05))
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
            // Named for what the driver typed, not the lookup's name
            // (FavoriteAddress.typed).
            let (coord, _) = try await resolve(text, pick: model.plannerDestinationPick)
            if let favorite = FavoriteAddress.typed(text, symbol: symbol, at: coord) {
                model.favorites.add(favorite)
            }
        } catch {
            errorMessage = Self.friendlyError(error)
        }
    }

    /// Why "From where?" is up when the driver didn't switch GPS off.
    private var sourceRowText: String {
        // Location turned off for FLOWS is not "no GPS": say which, so the
        // driver knows it can be turned back on.
        let off = model.location.denied
        // Allowed, but the first fix hasn't come in yet (the first seconds
        // after launch): not "no GPS".
        if model.location.authorized, !off {
            return "Finding where you are — or type a start."
        }
        if let p = model.bestKnownPosition, source.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\(off ? "Location is off for FLOWS" : "No GPS on this device") — "
                + "starting from \(p.label) unless you type a start."
        }
        if off { return "Location is off for FLOWS — turn it on, or type a start." }
        return "No GPS on this device — type a start."
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
        // A stop picked for the last plan's route is not this plan's.
        model.plannedStop = nil
        do {
            // GPS is the source unless a start was typed (or GPS is absent).
            // Source and destination geocode CONCURRENTLY so the destination
            // never queues behind a typed start.
            let from: (CLLocationCoordinate2D, String)
            let to: (CLLocationCoordinate2D, String)
            FlowsDiag.log(.info, "plan", "start: source=\(usingGPSSource ? "gps" : usingFallbackStart ? "fallback" : "typed")")
            // A field filled from a row with its own place (recent, map
            // point, prediction) plans to that point with no lookup.
            if usingGPSSource || usingFallbackStart {
                guard let start = model.bestKnownPosition else { throw RouteError.noStart }
                from = (start.coordinate, start.label)
                to = try await resolve(model.plannerDestination, pick: model.plannerDestinationPick)
                FlowsDiag.log(.info, "plan", "geocoded destination")
            } else {
                async let fromF = resolve(source, pick: model.plannerSourcePick)
                to = try await resolve(model.plannerDestination, pick: model.plannerDestinationPick)
                from = try await fromF
                FlowsDiag.log(.info, "plan", "geocoded start and destination")
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
            // Frame the full corridor while choosing — the highlighted
            // route's, which the filters may have moved off the first.
            // A null bounding rect (geometry not in yet) would frame the
            // camera on 0,0 — the Atlantic off Africa.
            if let first = model.routeChoices.first(where: { $0.id == model.highlightedRouteID })
                ?? planned.first,
               let rect = CameraZoom.usableRect(first.route.polyline.boundingMapRect) {
                withAnimation {
                    camera = .rect(Self.choicesCameraRect(
                        rect,
                        panelEdge: panelEdge,
                        windowAspect: golden.size.height / max(golden.size.width, 1),
                        panelFraction: panelEdge == .bottom ? golden.choicesPanelFraction
                                                  : CameraZoom.choicesPanelFraction))
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
