// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import MapKit
import SwiftUI

/// Root view — one Apple Maps surface, mode-dependent chrome floated over it.
/// The same adaptive rules as the web app's responsive CSS, expressed in
/// size classes: compact width (iPhone) stacks panels top/bottom; regular
/// width (iPad, macOS) floats them in the corners like the desktop web UI.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var camera: MapCameraPosition = .automatic

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private let isCompact = false
    #endif

    var body: some View {
        ZStack {
            mapLayer
            chromeLayer
        }
        .onReceive(model.navigation.$guidance) { guidance in
            // Navigation camera: chase the GPS fix at the engine's altitude.
            guard model.mode == .navigating, let g = guidance,
                  let coord = model.location.coordinate else { return }
            withAnimation(.easeInOut(duration: 0.8)) {
                camera = .camera(MapCamera(
                    centerCoordinate: coord,
                    distance: g.cameraAltitude,
                    heading: model.location.course >= 0 ? model.location.course : 0,
                    pitch: 55))
            }
        }
    }

    private var mapLayer: some View {
        Map(position: $camera) {
            UserAnnotation()
            // Selected (or candidate) routes drawn in FLOWS risk colors.
            if let route = model.navigation.route, model.mode == .navigating {
                MapPolyline(route.route.polyline)
                    .stroke(routeColor(route), lineWidth: 7)
            }
            ForEach(model.poi.results, id: \.self) { item in
                Marker(item.name ?? "Stop",
                       systemImage: model.poi.activeKind?.symbol ?? "mappin",
                       coordinate: item.placemark.coordinate)
            }
        }
        // Apple's traffic layer is exactly the "live conditions" underlay the
        // web app approximates with 511 feeds — free, continent-wide.
        .mapStyle(.standard(elevation: .flat, showsTraffic: true))
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var chromeLayer: some View {
        switch model.mode {
        case .planning, .choosing:
            PlanningChrome(isCompact: isCompact, camera: $camera)
        case .navigating:
            NavigationHUD(isCompact: isCompact)
        }
    }

    private func routeColor(_ route: PlannedRoute) -> Color {
        switch route.riskBand {
        case .clear: return .blue
        case .green: return Theme.riskGreen
        case .yellow: return Theme.riskYellow
        case .red: return Theme.riskRed
        }
    }
}

/// Planning-mode chrome: planner card + route choices, placed per platform.
private struct PlanningChrome: View {
    @EnvironmentObject private var model: AppModel
    let isCompact: Bool
    @Binding var camera: MapCameraPosition

    var body: some View {
        if isCompact {
            VStack {
                if model.mode == .choosing {
                    RouteChoicesView(camera: $camera)
                        .frame(maxHeight: 320)
                    Spacer()
                }
                Spacer()
                PlannerPanel(camera: $camera)
            }
            .padding(8)
        } else {
            HStack(alignment: .top) {
                if model.mode == .choosing {
                    RouteChoicesView(camera: $camera)
                        .frame(width: 380)
                }
                Spacer()
                PlannerPanel(camera: $camera)
                    .frame(width: 380)
            }
            .padding(16)
        }
    }
}
