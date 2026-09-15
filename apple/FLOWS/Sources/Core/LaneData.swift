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
/// The parsing and the lane matching are computed in rust/flows-core
/// (places_text.rs) and called through rust/flows-bridge; lanes cross flat as
/// turn codes with -1 closing each lane, and turns and sides are codes in
/// declaration order. Pinned to the original Swift by
/// rust/flows-bridge/tests/fixtures/swift_places_text_oracle.tsv. The fetch
/// lives in LiveHazardFeedFetcher.
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

        /// Turns by the bridge's code, in declaration order.
        static let byCode: [Turn] = [.sharpLeft, .left, .slightLeft, .through, .slightRight, .right,
                                     .sharpRight, .mergeToLeft, .mergeToRight, .reverse, Turn.none]
        var rustCode: UInt8 { UInt8(Turn.byCode.firstIndex(of: self) ?? 10) }

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
        var side: ManeuverSymbol.Side { ManeuverSymbol.Side(rustCode: flows_places_text_turn_side(rustCode)) }
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
            guard !turns.isEmpty else { return false }   // an empty buffer never crosses
            let codes = turns.map { Int64($0.rustCode) }
            return codes.withUnsafeBufferPointer { flows_places_text_lane_allows($0, side.rustCode) }
        }

        /// The flat form the bridge reads: turn codes, then -1.
        fileprivate var flat: [Int64] { turns.map { Int64($0.rustCode) } + [-1] }
    }

    /// Parse an OSM `turn:lanes` value. Empty lane entries are legal and
    /// mean "unspecified", not "missing".
    static func parse(turnLanes: String) -> [Lane] {
        var lanes: [Lane] = []
        var turns: [Turn] = []
        for code in flows_places_text_parse_turn_lanes(turnLanes) {
            if code < 0 {
                lanes.append(Lane(turns: turns.isEmpty ? [Turn.none] : turns))
                turns = []
            } else if let turn = Turn.byCode.indices.contains(Int(code)) ? Turn.byCode[Int(code)] : nil {
                turns.append(turn)
            }
        }
        return lanes
    }

    /// Which lanes serve the upcoming maneuver — the ones to fill green.
    /// A maneuver with no matching lane returns EMPTY rather than guessing:
    /// highlighting the wrong lane at an interchange is the failure this
    /// whole feature exists to prevent.
    static func recommended(lanes: [Lane], maneuver: ManeuverSymbol.Side) -> Set<Int> {
        guard !lanes.isEmpty else { return [] }
        let flat = lanes.flatMap(\.flat)
        let indices = flat.withUnsafeBufferPointer { flows_places_text_recommended_lanes($0, maneuver.rustCode) }
        return Set(indices.map { Int($0) })
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

extension ManeuverSymbol.Side {
    /// The bridge's code: 0 left, 1 right, 2 none.
    var rustCode: UInt8 {
        switch self {
        case .left: return 0
        case .right: return 1
        case .none: return 2
        }
    }
    init(rustCode: UInt8) {
        switch rustCode {
        case 0: self = .left
        case 1: self = .right
        default: self = .none
        }
    }
}
