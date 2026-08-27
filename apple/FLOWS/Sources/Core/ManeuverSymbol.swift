// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

import Foundation

/// The arrow that matches what the instruction actually says.
///
/// MapKit does not expose a maneuver TYPE on `MKRoute.Step` — only the
/// human-readable instruction — so the symbol is read from that text. A
/// banner showing a right turn while the words say "turn left" is worse than
/// no icon at all, which is why this is pure and heavily pinned by tests.
enum ManeuverSymbol {

    /// SF Symbol for an instruction. Order matters: the most specific
    /// phrasings are matched before the general ones ("slight left" before
    /// "left"; "u-turn" before "turn").
    static func symbol(for instruction: String) -> String {
        let s = instruction.lowercased()

        // Arrival and departure bookend every route.
        if s.contains("arrive") || s.contains("you have arrived") { return "mappin.circle.fill" }
        if s.contains("u-turn") || s.contains("make a u turn") { return "arrow.uturn.down" }

        // Roundabouts name their exit rather than a direction.
        if s.contains("roundabout") || s.contains("traffic circle") || s.contains("rotary") {
            return "arrow.triangle.turn.up.right.circle"
        }

        // The SHAPE of the maneuver wins over the KIND of road it happens
        // on: "slight left onto the ramp" is a slight left, not a ramp.
        if s.contains("slight") || s.contains("bear ")
            || s.contains("keep ") || s.contains("stay ") {
            return side(of: s) == .left ? "arrow.up.left" : "arrow.up.right"
        }

        // Ramps and merges read differently from a street turn.
        if s.contains("merge") { return "arrow.merge" }
        if s.contains("exit") || s.contains("ramp") {
            return side(of: s) == .left
                ? "arrow.turn.up.left" : "arrow.turn.up.right"
        }

        // Sharp turns.
        if s.contains("sharp") {
            return side(of: s) == .left
                ? "arrow.turn.up.left" : "arrow.turn.up.right"
        }

        // Plain turns — the common case.
        if s.contains("turn") || s.contains("left") || s.contains("right") {
            switch side(of: s) {
            case .left: return "arrow.turn.up.left"
            case .right: return "arrow.turn.up.right"
            case .none: break
            }
        }

        if s.contains("continue") || s.contains("head ") || s.contains("proceed") {
            return "arrow.up"
        }
        // Nothing recognised: a neutral arrow, never a guessed direction.
        return "arrow.up"
    }

    enum Side { case left, right, none }

    /// Which way the instruction turns. "Left" and "right" also appear as
    /// street names ("turn onto Left Fork Rd"), so the word is only taken as
    /// a direction when it isn't part of the destination phrase — the text
    /// after "onto"/"on to"/"toward" is stripped before matching.
    static func side(of instruction: String) -> Side {
        let s = strippedDestination(instruction.lowercased())
        let left = s.contains("left")
        let right = s.contains("right")
        if left && !right { return .left }
        if right && !left { return .right }
        if left && right {
            // Both present: the FIRST one is the maneuver, the later one is
            // usually part of a road name.
            let li = s.range(of: "left")!.lowerBound
            let ri = s.range(of: "right")!.lowerBound
            return li < ri ? .left : .right
        }
        return .none
    }

    /// Drop the destination clause so a street called "Right Fork" can't
    /// steer the arrow.
    static func strippedDestination(_ s: String) -> String {
        for marker in [" onto ", " on to ", " toward ", " towards ", " to stay on "] {
            if let r = s.range(of: marker) { return String(s[s.startIndex..<r.lowerBound]) }
        }
        return s
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
    enum Side: Equatable { case left, right, center }

    struct Advice: Equatable {
        /// How many lanes the driver should be in (as stated).
        let laneCount: Int
        /// Which side those lanes are on.
        let side: Side
        /// Plain-words summary for the label.
        let text: String
    }

    /// Parse lane advice out of an instruction, or nil when it states none.
    static func advice(for instruction: String) -> Advice? {
        let s = instruction.lowercased()
        // "Use the 2 right lanes to turn right" / "use the left 3 lanes"
        if s.contains("lane") {
            let side: Side = s.contains("left") ? .left
                           : s.contains("right") ? .right : .center
            let count = laneCount(in: s) ?? 1
            let plural = count == 1 ? "lane" : "lanes"
            let sideWord = side == .left ? "left" : side == .right ? "right" : "center"
            return Advice(laneCount: count, side: side,
                          text: "Use the \(count) \(sideWord) \(plural)")
        }
        // "Keep left at the fork" implies a side without naming lanes.
        if s.contains("keep left") || s.contains("stay left") {
            return Advice(laneCount: 1, side: .left, text: "Keep left")
        }
        if s.contains("keep right") || s.contains("stay right") {
            return Advice(laneCount: 1, side: .right, text: "Keep right")
        }
        return nil
    }

    /// The first small integer in the text — "use the 2 right lanes" → 2.
    /// Words are handled too, since Apple writes both.
    static func laneCount(in s: String) -> Int? {
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5]
        for (word, n) in words where s.contains(word + " ") { return n }
        var digits = ""
        for ch in s {
            if ch.isNumber { digits.append(ch) }
            else if !digits.isEmpty { break }
        }
        guard let n = Int(digits), (1...6).contains(n) else { return nil }
        return n
    }

    /// Which of `total` lanes to fill green, left to right (0-indexed).
    /// A drawing helper, so the diagram and the words can't disagree.
    static func highlighted(advice: Advice, total: Int) -> Set<Int> {
        guard total > 0 else { return [] }
        let n = min(advice.laneCount, total)
        switch advice.side {
        case .left:
            return Set(0..<n)
        case .right:
            return Set((total - n)..<total)
        case .center:
            let start = max((total - n) / 2, 0)
            return Set(start..<min(start + n, total))
        }
    }
}
