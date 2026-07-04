// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import SwiftUI

/// App-wide mode: plan on a continent-scale map, then flip to a time-sensitive
/// zoomed turn-by-turn view once a route is chosen (see NavigationEngine for
/// the zoom policy).
enum AppMode: Equatable {
    case planning            // browse map, search, enter route endpoints
    case choosing            // alternates returned, user picks one
    case navigating          // turn-by-turn against GPS + speed
}

@MainActor
final class AppModel: ObservableObject {
    @Published var mode: AppMode = .planning
    @Published var routeChoices: [PlannedRoute] = []

    let location = LocationService()
    let router = RouteService()
    let poi = POIService()
    let alerts = WeatherAlertService()
    let navigation: NavigationEngine

    init() {
        navigation = NavigationEngine(location: location)
    }

    /// Route selection is the mode flip: planning is continent-wide and lazy,
    /// navigation is local and eager (camera follows GPS, updates every fix).
    func select(route: PlannedRoute) {
        routeChoices = []
        navigation.start(route: route)
        mode = .navigating
        // Warm what matters for the next few minutes of driving, nothing more:
        // POIs and weather alerts along the corridor ahead, not the continent.
        poi.beginCorridorSearch(along: route)
        alerts.beginCorridorWatch(along: route)
    }

    func endNavigation() {
        navigation.stop()
        poi.reset()
        mode = .planning
    }
}

@main
struct FLOWSApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        #endif
    }
}
