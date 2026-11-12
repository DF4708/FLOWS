// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import FlowsBridge
import Foundation

/// The arrow that matches what the instruction actually says.
///
/// MapKit does not expose a maneuver TYPE on `MKRoute.Step` — only the
/// human-readable instruction — so the symbol is read from that text. A
/// banner showing a right turn while the words say "turn left" is worse than
/// no icon at all, which is why this is pure and heavily pinned by tests.
///
/// The rules run in Rust (flows-core `maneuver`, pinned by a frozen oracle of
/// this file's original Swift, its two regular expressions included);
/// Swift keeps the symbol names and the words.
enum ManeuverSymbol {

    /// The SF Symbols, in `maneuver::SYMBOL_NAMES`' order.
    static let symbolNames = [
        "mappin.circle.fill", "arrow.uturn.down", "arrow.triangle.turn.up.right.circle",
        "arrow.up.left", "arrow.up.right", "arrow.up", "arrow.merge",
        "arrow.turn.up.left", "arrow.turn.up.right",
    ]

    /// SF Symbol for an instruction. Order matters: the most specific
    /// phrasings are matched before the general ones ("slight left" before
    /// "left"; "u-turn" before "turn"). The SHAPE of the maneuver wins over
    /// the KIND of road it happens on: "slight left onto the ramp" is a slight
    /// left, not a ramp. Nothing recognised gives a neutral arrow, never a
    /// guessed direction.
    static func symbol(for instruction: String) -> String {
        let i = Int(flows_maneuver_symbol(instruction))
        return symbolNames.indices.contains(i) ? symbolNames[i] : "arrow.up"
    }

    enum Side { case left, right, none }

    /// Which way the instruction turns. "Left" and "right" also appear as
    /// street names ("turn onto Left Fork Rd"), so the word is only taken as
    /// a direction when it isn't part of the destination phrase — the text
    /// after "onto"/"on to"/"toward" is stripped before matching. When both
    /// appear, the FIRST one is the maneuver.
    static func side(of instruction: String) -> Side {
        Side(rustCode: flows_maneuver_side(instruction))
    }

    /// Drop the destination clause so a street called "Right Fork" can't
    /// steer the arrow.
    static func strippedDestination(_ s: String) -> String {
        flows_maneuver_stripped_destination(s).text
    }
}

/// Lane guidance, when the instruction actually carries it.
///
/// Apple's instructions sometimes name the lanes ("Use the 2 right lanes to
/// turn right", "Keep left at the fork"). MapKit exposes no structured lane
/// data, so this reads what the text states and NOTHING more — a fabricated
/// lane diagram at an interchange is exactly the kind of confident wrongness
/// that gets a driver into the wrong lane at speed. When the words don't say,
/// `nil` comes back and the banner shows no lanes.
enum LaneGuidance {
    /// Which side of the roadway the recommended lanes sit on.
    enum Side: Equatable {
        case left, right, center

        /// The bridge's code: 0 left, 1 right, 2 center.
        var rustCode: Int64 {
            switch self {
            case .left: return 0
            case .right: return 1
            case .center: return 2
            }
        }
        init(rustCode: Int64) {
            switch rustCode {
            case 0: self = .left
            case 1: self = .right
            default: self = .center
            }
        }
        var word: String {
            switch self {
            case .left: return "left"
            case .right: return "right"
            case .center: return "center"
            }
        }
    }

    struct Advice: Equatable {
        /// How many lanes the driver should be in (as stated).
        let laneCount: Int
        /// Which side those lanes are on.
        let side: Side
        /// Plain-words summary for the label.
        let text: String
    }

    /// The bridge's `count << 3 | side << 1 | keep`, or nil for its -1.
    private static func decode(_ v: Int64) -> (count: Int, side: Side, keep: Bool)? {
        guard v >= 0 else { return nil }
        return (Int(v >> 3), Side(rustCode: (v >> 1) & 3), v & 1 == 1)
    }

    /// Parse lane advice out of an instruction, or nil when it states none.
    /// Only a lane PHRASE counts ("use the 2 right lanes", "the left 3
    /// lanes"); "Keep left at the fork" implies a side without naming lanes.
    static func advice(for instruction: String) -> Advice? {
        guard let a = decode(flows_maneuver_advice(instruction)) else { return nil }
        if a.keep {
            return Advice(laneCount: a.count, side: a.side, text: "Keep \(a.side.word)")
        }
        let plural = a.count == 1 ? "lane" : "lanes"
        return Advice(
            laneCount: a.count, side: a.side,
            text: "Use the \(a.count) \(a.side.word) \(plural)")
    }

    /// "the 2 right lanes", "the left 3 lanes", "the three left lanes", "the
    /// middle lane" in lowercased text: the side and the count (1 when none
    /// is stated). Apple writes the count as a digit or a word, on either
    /// side of the side word. nil when the text has no such phrase.
    static func lanePhrase(in s: String) -> (side: Side, count: Int)? {
        decode(flows_maneuver_lane_phrase(s)).map { ($0.side, $0.count) }
    }

    /// Which of `total` lanes to fill green, left to right (0-indexed).
    /// A drawing helper, so the diagram and the words can't disagree.
    static func highlighted(advice: Advice, total: Int) -> Set<Int> {
        let r = Array(flows_maneuver_highlighted(Int64(advice.laneCount), advice.side.rustCode, Int64(total)))
        guard r.count == 2, r[0] < r[1] else { return [] }
        return Set(Int(r[0])..<Int(r[1]))
    }
}

extension ManeuverSymbol {
    /// The exit number an instruction names ("Take exit 142A toward I-94 E"
    /// → "142A"), for the big exit sign beside the compass; nil when it names
    /// no numbered exit ("take the exit toward Madison", "the 2nd exit" of a
    /// roundabout).
    static func exitNumber(in instruction: String) -> String? {
        let n = flows_maneuver_exit_number(instruction).text
        return n.isEmpty ? nil : n
    }

    /// The lane movement an instruction asks for — what the lit arrows in
    /// the lane box show. The same reading as `symbol(for:)`: a ramp or
    /// exit that names no side is a right one.
    static func turn(for instruction: String) -> LaneData.Turn {
        let code = Int(flows_maneuver_turn(instruction))
        return LaneData.Turn.byCode.indices.contains(code) ? LaneData.Turn.byCode[code] : .through
    }
}

/// The arrow box beside the directions: one arrow per lane, each drawn as
/// the movement its lane serves (straight, left, right, a U-turn on the left
/// or the right), the lanes to be in lit green. Lane by lane from the road's
/// own tagged lanes when there are any; from what the instruction says when
/// it names lanes ("use the 2 right lanes"); else one arrow for the turn.
enum LaneBox {
    struct Arrow: Equatable {
        let turn: LaneData.Turn
        let lit: Bool
        /// A U-turn arrow curls to the left (true) or the right.
        let uTurnLeft: Bool
    }

    static func arrows(
        lanes: [LaneData.Lane], recommended: Set<Int>,
        instruction: String
    ) -> [Arrow] {
        // Never empty: the -1 between the lanes and the recommended ones.
        let flat = lanes.map { Int64($0.primary.rustCode) } + [-1] + recommended.map { Int64($0) }
        let v = flat.lent { Array(flows_maneuver_lane_box($0, instruction)) }
        return stride(from: 0, to: v.count - 2, by: 3).compactMap { i in
            let t = Int(v[i])
            guard LaneData.Turn.byCode.indices.contains(t) else { return nil }
            return Arrow(turn: LaneData.Turn.byCode[t], lit: v[i + 1] == 1, uTurnLeft: v[i + 2] == 1)
        }
    }
}
