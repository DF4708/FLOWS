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
enum SpeedSign {

    /// Parse an OSM `maxspeed` value to mph. Handles "55 mph", bare km/h
    /// numbers ("80" → 50 mph), "none" (German autobahn), and walking zones.
    /// Returns nil for anything it can't read, so the sign stays blank
    /// rather than guessing.
    static func parseMaxspeed(_ raw: String) -> Double? {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lower.isEmpty else { return nil }
        // Derestricted autobahn: a real answer, but not a number to post.
        if lower == "none" || lower == "signals" || lower == "variable" { return nil }
        if lower == "walk" { return 5 }
        let digits = lower.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits), value > 0 else { return nil }
        if lower.contains("mph") { return value }
        if lower.contains("knots") { return value * 1.15078 }
        // OSM's bare number is km/h by specification.
        return value / 1.609344
    }

    /// Speeding judgment for the readout's color. A few mph over is normal
    /// driving and shouldn't paint the HUD red; well over is worth seeing.
    enum Judgment: Equatable { case under, slightlyOver, over }

    /// Tolerance before "over" reads as speeding (mph) — matches the slack
    /// in a typical speedometer and in enforcement practice.
    static let tolerance = 5.0
    /// Beyond this much over, the readout goes red.
    static let overBy = 10.0

    static func judge(speedMph: Double, limitMph: Double?) -> Judgment {
        guard let limitMph, limitMph > 0 else { return .under }
        let excess = speedMph - limitMph
        if excess >= overBy { return .over }
        if excess >= tolerance { return .slightlyOver }
        return .under
    }

    /// Whether the pair belongs on screen at all. It's a DRIVING instrument:
    /// a walker has no posted limit to keep, and a passenger on a plane,
    /// bus, or train isn't the one driving.
    static func shouldShow(isNavigating: Bool, isWalking: Bool,
                           isPassengerTransit: Bool) -> Bool {
        isNavigating && !isWalking && !isPassengerTransit
    }
}
