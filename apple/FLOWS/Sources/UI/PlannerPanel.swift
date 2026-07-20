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
    @Binding var camera: MapCameraPosition

    @State private var searchQuery = ""
    @State private var overrideSource = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    enum Field { case destination, source }

    /// Fields live on the model so Edit-from-choosing round-trips intact.
    private var source: String { model.plannerSource }
    private var hasGPS: Bool { model.location.coordinate != nil }
    /// No GPS → the source field is always shown (the primary flow must
    /// never dead-end on a Mac without location access).
    private var showSourceField: Bool { overrideSource || !hasGPS }
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
            Text("Where to?")
                .font(.system(size: 15, weight: .bold))
            HStack(spacing: 6) {
                TextField("Destination ZIP, county, or city", text: $model.plannerDestination)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
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
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(destinationIsFavorite ? Color.yellow : Color.secondary)
                        .frame(width: Theme.tapMinimum, height: Theme.tapMinimum)
                        .background(Color.black.opacity(0.04))
                        .clipShape(Circle())
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.plannerDestination.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Save this destination as a favorite")
            }

            // Source row: GPS by default, tap to override. When there's no
            // GPS fix the field shows automatically with an explanation.
            HStack(spacing: 6) {
                Image(systemName: usingGPSSource ? "location.fill" : "mappin.circle")
                    .font(.footnote)
                    .foregroundStyle(usingGPSSource ? .blue : .secondary)
                Text(sourceRowText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if hasGPS {
                    Button(showSourceField ? "Use GPS" : "Enter your own location") {
                        overrideSource.toggle()
                        if !overrideSource { model.plannerSource = "" }
                    }
                    .font(.caption2.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
            if showSourceField {
                // Same pill styling as the destination — the roundedBorder
                // style had a near-unclickable hit target on macOS.
                TextField("Source ZIP, county, or city", text: $model.plannerSource)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .frame(minHeight: Theme.tapMinimum)
                    .padding(.horizontal, 14)
                    .background(Color.black.opacity(0.04))
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                    .focused($focusedField, equals: .source)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await plan() } }
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
        .floatingCard()
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
            let (coord, _) = try await model.router.geocode(searchQuery)
            withAnimation {
                camera = .region(MKCoordinateRegion(
                    center: coord,
                    latitudinalMeters: 60_000, longitudinalMeters: 60_000))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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
                        camera = .rect(first.route.polyline.boundingMapRect.insetBy(
                            dx: -first.route.polyline.boundingMapRect.width * 0.2,
                            dy: -first.route.polyline.boundingMapRect.height * 0.2))
                    }
                } else {
                    errorMessage = "Couldn't plan to \(fav.name) — no GPS fix or no route."
                }
            }
        } label: {
            Label(fav.name, systemImage: fav.symbol.systemImage)
                .font(.system(size: 13, weight: .semibold))
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
            let (coord, name) = try await model.router.geocode(text)
            model.favorites.add(FavoriteAddress(
                name: name, symbol: symbol,
                latitude: coord.latitude, longitude: coord.longitude))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var sourceRowText: String {
        if usingGPSSource { return "From: Current Location" }
        if !hasGPS { return "From: (no GPS on this device — enter a start)" }
        return "From:"
    }

    private func plan() async {
        // Reentry guard: the button's action AND its simultaneous tap gesture
        // can both fire on one click — the second call must be a no-op.
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            // GPS is the source unless a start was typed (or GPS is absent).
            let from: (CLLocationCoordinate2D, String)
            if usingGPSSource {
                guard let here = model.location.coordinate else {
                    throw RouteError.notFound("current location (no GPS fix yet)")
                }
                from = (here, "Current location")
            } else {
                from = try await model.router.geocode(source)
            }
            let to = try await model.router.geocode(model.plannerDestination)
            // Routes appear as soon as directions return; weather badges
            // hydrate asynchronously inside present(routes:). Planning goes
            // through the model so filter toggles can replan variants later.
            let planned = try await model.plan(
                from: from.0, fromName: from.1,
                to: to.0, toName: to.1)
            model.present(routes: planned)
            // Frame the full corridor while choosing.
            if let first = planned.first {
                withAnimation {
                    camera = .rect(first.route.polyline.boundingMapRect.insetBy(
                        dx: -first.route.polyline.boundingMapRect.width * 0.2,
                        dy: -first.route.polyline.boundingMapRect.height * 0.2))
                }
            }
        } catch {
            errorMessage = error.localizedDescription
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
