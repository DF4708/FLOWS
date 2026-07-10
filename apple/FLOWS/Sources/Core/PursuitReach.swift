// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: d.foster@marquette.edu
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// The red-alert reach circle: from the incident's location and time, how
/// far could a vehicle plausibly have driven BY NOW at the speeds the roads
/// around the incident allow? The circle grows as time passes. Pure math —
/// the nearby speed limit comes from OSM (RouteAttributeFetcher) with a
/// blended default when none is posted nearby.
enum PursuitReach {

    /// Blended urban/highway escape speed when no posted limits are found.
    static let defaultSpeedMph = 45.0
    /// Even "just happened" draws a visible circle (the subject moved).
    static let minimumRadiusMeters = 800.0
    /// Cap: past ~3 h the circle covers whole regions and stops informing.
    static let maximumElapsedSeconds: TimeInterval = 3 * 3600

    static func radiusMeters(elapsedSeconds: TimeInterval, speedMph: Double) -> Double {
        let elapsed = min(max(elapsedSeconds, 0), maximumElapsedSeconds)
        let mps = max(speedMph, 5) * 0.44704
        return max(elapsed * mps, minimumRadiusMeters)
    }
}
