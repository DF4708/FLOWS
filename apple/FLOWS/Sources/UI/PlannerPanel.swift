// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import CoreLocation
import MapKit
import SwiftUI

/// The web app's route card, in Swift: Search section + Route planner with
/// "Source ZIP, county, or city" / destination fields and a black pill CTA.
struct PlannerPanel: View {
    @EnvironmentObject private var model: AppModel
    @Binding var camera: MapCameraPosition

    @State private var searchQuery = ""
    @State private var source = ""
    @State private var destination = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var routes: [PlannedRoute] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search")
                .font(.system(size: 15, weight: .bold))
            HStack(spacing: 8) {
                TextField("Search by ZIP code, county name, or city name", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .frame(minHeight: Theme.tapMinimum)
                    .padding(.horizontal, 14)
                    .background(Color.black.opacity(0.04))
                    .clipShape(Capsule())
                    .onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }
                    .buttonStyle(PillCTAStyle())
                    .frame(width: 110)
            }

            Divider()

            Text("Route planner")
                .font(.system(size: 15, weight: .bold))
            HStack(spacing: 8) {
                TextField("Source ZIP, county, or city", text: $source)
                    .textFieldStyle(.roundedBorder)
                TextField("Destination ZIP, county, or city", text: $destination)
                    .textFieldStyle(.roundedBorder)
            }
            Button(isWorking ? "Planning…" : "Plan route") {
                Task { await plan() }
            }
            .buttonStyle(PillCTAStyle())
            .disabled(isWorking || destination.isEmpty)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(Theme.riskRed)
            }
        }
        .floatingCard()
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

    private func plan() async {
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            // Blank source = "from where I am", like every navigation app.
            let from: (CLLocationCoordinate2D, String)
            if source.isEmpty {
                guard let here = model.location.coordinate else {
                    throw RouteError.notFound("current location (no GPS fix yet)")
                }
                from = (here, "Current location")
            } else {
                from = try await model.router.geocode(source)
            }
            let to = try await model.router.geocode(destination)
            let planned = try await model.router.planRoutes(
                from: from.0, fromName: from.1,
                to: to.0, toName: to.1,
                alerts: model.alerts)
            model.routeChoices = planned
            model.mode = .choosing
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
