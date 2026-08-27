// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// REAL lane-level guidance, from OpenStreetMap's `turn:lanes` tag.
///
/// MapKit publishes no lane data, so the previous version could only repeat
/// lane phrasing when Apple happened to include it. OSM tags the lanes
/// themselves — `left|through|through;right` means three lanes, left-to-right
/// in the direction of travel, the last of which serves both through and
/// right. That is exactly what a driver needs at an interchange, it is
/// keyless, and FLOWS already reads OSM through Overpass for clearances,
/// weight limits and speed limits.
///
/// Pure parsing + matching; the fetch lives in LiveHazardFeedFetcher.
enum LaneData {

    /// What a single lane permits. Ordered so `arrow` can pick the most
    /// representative movement when a lane serves several.
    enum Turn: String, Equatable {
        case sharpLeft, left, slightLeft
        case through
        case slightRight, right, sharpRight
        case mergeToLeft, mergeToRight
        case reverse          // U-turn lane
        case none             // tagged but unspecified

        /// OSM spells these with underscores.
        static func from(_ raw: String) -> Turn? {
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "sharp_left": return .sharpLeft
            case "left": return .left
            case "slight_left": return .slightLeft
            case "through": return .through
            case "slight_right": return .slightRight
            case "right": return .right
            case "sharp_right": return .sharpRight
            case "merge_to_left": return .mergeToLeft
            case "merge_to_right": return .mergeToRight
            case "reverse": return .reverse
            case "none", "": return Turn.none
            default: return nil
            }
        }

        /// The arrow drawn for a lane offering this movement.
        var symbol: String {
            switch self {
            case .sharpLeft, .left: return "arrow.turn.up.left"
            case .slightLeft, .mergeToLeft: return "arrow.up.left"
            case .through, .none: return "arrow.up"
            case .slightRight, .mergeToRight: return "arrow.up.right"
            case .right, .sharpRight: return "arrow.turn.up.right"
            case .reverse: return "arrow.uturn.down"
            }
        }

        /// Which way this movement heads — used to match the maneuver.
        var side: ManeuverSymbol.Side {
            switch self {
            case .sharpLeft, .left, .slightLeft, .mergeToLeft, .reverse: return .left
            case .sharpRight, .right, .slightRight, .mergeToRight: return .right
            case .through, .none: return ManeuverSymbol.Side.none
            }
        }
    }

    /// One lane, left to right in the direction of travel.
    struct Lane: Equatable {
        let turns: [Turn]

        /// The movement this lane is best drawn as: the turn it offers that
        /// isn't simply "through", so a through+right lane draws as a right.
        var primary: Turn {
            turns.first { $0 != .through && $0 != Turn.none } ?? .through
        }

        var symbol: String { primary.symbol }

        func allows(_ side: ManeuverSymbol.Side) -> Bool {
            switch side {
            case .none: return turns.contains(.through) || turns.contains(Turn.none)
            default: return turns.contains { $0.side == side }
            }
        }
    }

    /// Parse an OSM `turn:lanes` value. Empty lane entries are legal and
    /// mean "unspecified", not "missing".
    static func parse(turnLanes: String) -> [Lane] {
        let trimmed = turnLanes.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.components(separatedBy: "|").map { field in
            let turns = field.components(separatedBy: ";")
                .compactMap(Turn.from)
            return Lane(turns: turns.isEmpty ? [Turn.none] : turns)
        }
    }

    /// Which lanes serve the upcoming maneuver — the ones to fill green.
    /// A maneuver with no matching lane returns EMPTY rather than guessing:
    /// highlighting the wrong lane at an interchange is the failure this
    /// whole feature exists to prevent.
    static func recommended(lanes: [Lane], maneuver: ManeuverSymbol.Side) -> Set<Int> {
        guard !lanes.isEmpty else { return [] }
        let matching = lanes.indices.filter { lanes[$0].allows(maneuver) }
        return Set(matching)
    }

    /// Plain-words summary of the highlighted lanes ("2 right lanes").
    static func summary(lanes: [Lane], recommended: Set<Int>) -> String? {
        guard !recommended.isEmpty, !lanes.isEmpty,
              recommended.count < lanes.count else { return nil }
        let n = recommended.count
        let plural = n == 1 ? "lane" : "lanes"
        // Where do they sit? Left edge, right edge, or the middle.
        let sorted = recommended.sorted()
        if sorted.first == 0 { return "Use the \(n) left \(plural)" }
        if sorted.last == lanes.count - 1 { return "Use the \(n) right \(plural)" }
        return "Use the \(n) middle \(plural)"
    }
}
