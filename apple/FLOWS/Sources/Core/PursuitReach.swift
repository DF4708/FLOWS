// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
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
///
/// Computed in rust/flows-core (vehicle_policy.rs) and called through
/// rust/flows-bridge; the constants are read from Rust. Pinned bit for bit to
/// the Swift this replaced by
/// rust/flows-bridge/tests/fixtures/swift_vehicle_policy_oracle.tsv.
enum PursuitReach {

    /// Blended urban/highway escape speed when no posted limits are found.
    static let defaultSpeedMph = flows_vehicle_policy_pursuit_default_speed_mph()
    /// Even "just happened" draws a visible circle (the subject moved).
    static let minimumRadiusMeters = flows_vehicle_policy_pursuit_minimum_radius_meters()
    /// Cap: past ~3 h the circle covers whole regions and stops informing.
    static let maximumElapsedSeconds: TimeInterval = flows_vehicle_policy_pursuit_maximum_elapsed_seconds()

    static func radiusMeters(elapsedSeconds: TimeInterval, speedMph: Double) -> Double {
        flows_vehicle_policy_pursuit_radius_meters(elapsedSeconds, speedMph)
    }
}
