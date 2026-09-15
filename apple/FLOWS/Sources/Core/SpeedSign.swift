// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// The live speed pair on the HUD: what the road is posted at, and how fast
/// the vehicle is actually going. Pure parsing + judgment, pinned by
/// FLOWSTests; the Overpass lookup lives in LiveHazardFeedFetcher.
///
/// Posted limits come from OpenStreetMap's `maxspeed` tag, which is
/// community-maintained and sometimes absent or stale — so the sign only
/// shows a number when one was actually found, and never invents one.
///
/// The parse and the judgment are computed in rust/flows-core
/// (vehicle_policy.rs) and called through rust/flows-bridge, pinned bit for
/// bit to the Swift this replaced — grapheme-cluster string semantics
/// included — by rust/flows-bridge/tests/fixtures/swift_vehicle_policy_oracle.tsv.
enum SpeedSign {

    /// Parse an OSM `maxspeed` value to mph. Handles "55 mph", bare km/h
    /// numbers ("80" → 50 mph), "none" (German autobahn), and walking zones.
    /// Returns nil for anything it can't read, so the sign stays blank
    /// rather than guessing.
    static func parseMaxspeed(_ raw: String) -> Double? {
        // NaN crosses back for "no number posted"; a parsed limit never is NaN.
        let mph = flows_vehicle_policy_parse_maxspeed_mph(raw)
        return mph.isNaN ? nil : mph
    }

    /// Speeding judgment for the readout's color. A few mph over is normal
    /// driving and shouldn't paint the HUD red; well over is worth seeing.
    enum Judgment: Equatable { case under, slightlyOver, over }

    /// Tolerance before "over" reads as speeding (mph) — matches the slack
    /// in a typical speedometer and in enforcement practice.
    static let tolerance = flows_vehicle_policy_speed_sign_tolerance_mph()
    /// Beyond this much over, the readout goes red.
    static let overBy = flows_vehicle_policy_speed_sign_over_by_mph()

    static func judge(speedMph: Double, limitMph: Double?) -> Judgment {
        switch flows_vehicle_policy_judge_code(speedMph, limitMph ?? 0, limitMph != nil) {
        case 2: return .over
        case 1: return .slightlyOver
        default: return .under
        }
    }

    /// Whether the pair belongs on screen at all. It's a DRIVING instrument:
    /// a walker has no posted limit to keep, and a passenger on a plane,
    /// bus, or train isn't the one driving.
    static func shouldShow(isNavigating: Bool, isWalking: Bool,
                           isPassengerTransit: Bool) -> Bool {
        isNavigating && !isWalking && !isPassengerTransit
    }
}
