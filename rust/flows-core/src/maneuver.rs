// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Reading a turn-by-turn instruction: Swift's `ManeuverSymbol`,
//! `LaneGuidance` and `LaneBox` before their rules moved here. MapKit gives
//! only the words of a step, so the arrow, the side, the lane advice, the
//! exit number and the lane box all come from the text.
//!
//! Text follows Swift's own rules through [`crate::swift_text`]: `contains`
//! and `range(of:)` are Foundation's, `lowercased` and `uppercased` are the
//! standard library's. Two readings were regular expressions, matched by
//! hand here with classes read out of the runtime by the oracle harness. The
//! lane phrase ran on ICU (`NSRegularExpression`), scalar by scalar, with
//! ICU's `\d`, `\s` and `\b`. The exit number ran on Swift Regex
//! (`range(of:options: .regularExpression)`), Character by Character, with
//! its simple `\b` and ASCII-only case-insensitive letters. Pinned by
//! `flows-bridge/tests/fixtures/swift_maneuver_symbol_oracle.tsv`.

use crate::places_text::{SIDE_LEFT, SIDE_NONE, SIDE_RIGHT, TURN_THROUGH};
use crate::swift_text::{self, icu, swift_regex};

/// The arrow for an instruction, as the SF Symbol names [`SYMBOL_NAMES`] lists.
pub const SYMBOL_NAMES: [&str; 9] = [
    "mappin.circle.fill",
    "arrow.uturn.down",
    "arrow.triangle.turn.up.right.circle",
    "arrow.up.left",
    "arrow.up.right",
    "arrow.up",
    "arrow.merge",
    "arrow.turn.up.left",
    "arrow.turn.up.right",
];
const ARRIVE: u8 = 0;
const UTURN: u8 = 1;
const ROUNDABOUT: u8 = 2;
const UP_LEFT: u8 = 3;
const UP_RIGHT: u8 = 4;
const UP: u8 = 5;
const MERGE: u8 = 6;
const TURN_LEFT: u8 = 7;
const TURN_RIGHT: u8 = 8;

// Lane turns, in `places_text::TURN_NAMES`' order.
const SHARP_LEFT: u8 = 0;
const LEFT: u8 = 1;
const SLIGHT_LEFT: u8 = 2;
const SLIGHT_RIGHT: u8 = 4;
const RIGHT: u8 = 5;
const SHARP_RIGHT: u8 = 6;
const MERGE_TO_LEFT: u8 = 7;
const MERGE_TO_RIGHT: u8 = 8;
const REVERSE: u8 = 9;

fn has(s: &str, needle: &str) -> bool {
    swift_text::contains(s, needle)
}

/// "slight", "bear ", "keep " or "stay ": a gentle move, or none.
fn gentle(s: &str) -> bool {
    has(s, "slight") || has(s, "bear ") || has(s, "keep ") || has(s, "stay ")
}

/// `symbol(for:)`: the index in [`SYMBOL_NAMES`]. The most specific phrasing
/// wins: arrival, a U-turn, a roundabout, a gentle move, a merge, a ramp or
/// exit (right when it names no side), a sharp turn, a plain turn; anything
/// else is straight ahead, never a guessed direction.
#[must_use]
pub fn symbol(instruction: &str) -> u8 {
    let s = swift_text::lowercased(instruction);
    if has(&s, "arrive") || has(&s, "you have arrived") {
        return ARRIVE;
    }
    if has(&s, "u-turn") || has(&s, "make a u turn") {
        return UTURN;
    }
    if has(&s, "roundabout") || has(&s, "traffic circle") || has(&s, "rotary") {
        return ROUNDABOUT;
    }
    if gentle(&s) {
        return match side(&s) {
            SIDE_LEFT => UP_LEFT,
            SIDE_RIGHT => UP_RIGHT,
            _ => UP,
        };
    }
    if has(&s, "merge") {
        return MERGE;
    }
    if has(&s, "exit") || has(&s, "ramp") || has(&s, "sharp") {
        return if side(&s) == SIDE_LEFT {
            TURN_LEFT
        } else {
            TURN_RIGHT
        };
    }
    if has(&s, "turn") || has(&s, "left") || has(&s, "right") {
        match side(&s) {
            SIDE_LEFT => return TURN_LEFT,
            SIDE_RIGHT => return TURN_RIGHT,
            _ => {}
        }
    }
    UP
}

/// `side(of:)`: which way the instruction turns, from its lowercased words
/// before the destination clause ([`stripped_destination`]); when both
/// "left" and "right" are there, the first one.
#[must_use]
pub fn side(instruction: &str) -> u8 {
    let lower = swift_text::lowercased(instruction);
    let s = stripped_destination(&lower);
    match (swift_text::find(s, "left"), swift_text::find(s, "right")) {
        (Some(_), None) => SIDE_LEFT,
        (None, Some(_)) => SIDE_RIGHT,
        (Some((l, _)), Some((r, _))) => {
            if l < r {
                SIDE_LEFT
            } else {
                SIDE_RIGHT
            }
        }
        (None, None) => SIDE_NONE,
    }
}

/// `strippedDestination`: the text before the first of the destination
/// markers found, tried in this order, so a street called "Right Fork"
/// cannot steer the arrow.
#[must_use]
pub fn stripped_destination(s: &str) -> &str {
    for marker in [" onto ", " on to ", " toward ", " towards ", " to stay on "] {
        if let Some((lo, _)) = swift_text::find(s, marker) {
            return &s[..lo];
        }
    }
    s
}

/// `turn(for:)`: the lane movement the instruction asks for, in
/// `places_text::TURN_NAMES`' codes. The same reading as [`symbol`]: a ramp
/// or exit that names no side is a right one.
#[must_use]
pub fn turn(instruction: &str) -> u8 {
    let s = swift_text::lowercased(instruction);
    if has(&s, "u-turn") || has(&s, "make a u turn") {
        return REVERSE;
    }
    let side = side(&s);
    let pick = |left: u8, right: u8, none: u8| match side {
        SIDE_LEFT => left,
        SIDE_RIGHT => right,
        _ => none,
    };
    if gentle(&s) {
        return pick(SLIGHT_LEFT, SLIGHT_RIGHT, TURN_THROUGH);
    }
    if has(&s, "merge") {
        return pick(MERGE_TO_LEFT, MERGE_TO_RIGHT, MERGE_TO_RIGHT);
    }
    if has(&s, "exit") || has(&s, "ramp") {
        return pick(LEFT, RIGHT, RIGHT);
    }
    if has(&s, "sharp") {
        return pick(SHARP_LEFT, SHARP_RIGHT, TURN_THROUGH);
    }
    pick(LEFT, RIGHT, TURN_THROUGH)
}

/// Which side of the roadway stated lanes sit on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LaneSide {
    /// The left lanes.
    Left = 0,
    /// The right lanes.
    Right = 1,
    /// The center (or middle) lanes.
    Center = 2,
}

/// Lane advice an instruction states: how many lanes, on which side, and
/// whether it came from "keep left" / "keep right" (the words say "Keep
/// left") rather than a lane phrase ("Use the 2 right lanes").
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Advice {
    /// How many lanes the driver should be in.
    pub count: i64,
    /// Which side those lanes are on.
    pub side: LaneSide,
    /// From "keep/stay left/right", not a lane phrase.
    pub keep: bool,
}

/// `LaneGuidance.advice(for:)`: a lane phrase in the lowercased text, else
/// "keep left" / "stay left" (one lane, left), else the same for right.
#[must_use]
pub fn advice(instruction: &str) -> Option<Advice> {
    let s = swift_text::lowercased(instruction);
    if let Some((side, count)) = lane_phrase(&s) {
        return Some(Advice {
            count,
            side,
            keep: false,
        });
    }
    let keep = |side| {
        Some(Advice {
            count: 1,
            side,
            keep: true,
        })
    };
    if has(&s, "keep left") || has(&s, "stay left") {
        return keep(LaneSide::Left);
    }
    if has(&s, "keep right") || has(&s, "stay right") {
        return keep(LaneSide::Right);
    }
    None
}

/// The lane counts Apple writes, as digits or words; any other digit counts
/// as one lane.
const LANE_NUMBERS: [(&str, i64); 12] = [
    ("1", 1),
    ("2", 2),
    ("3", 3),
    ("4", 4),
    ("5", 5),
    ("6", 6),
    ("one", 1),
    ("two", 2),
    ("three", 3),
    ("four", 4),
    ("five", 5),
    ("six", 6),
];

/// The text as scalars, the steps ICU's matcher takes.
struct Scalars {
    chars: Vec<char>,
}

impl Scalars {
    fn new(text: &str) -> Self {
        Self {
            chars: text.chars().collect(),
        }
    }

    fn len(&self) -> usize {
        self.chars.len()
    }

    /// ICU's `\b` before scalar `pos`: never just before a scalar it looks
    /// through (Grapheme_Extend or a format character); otherwise a word
    /// scalar on exactly one side, the side before skipping back over those
    /// scalars and the end of the text counting as no word.
    fn boundary(&self, pos: usize) -> bool {
        let here = match self.chars.get(pos) {
            Some(&c) if icu::is_skip(c) => return false,
            Some(&c) => icu::is_word(c),
            None => false,
        };
        let before = self.chars[..pos.min(self.len())]
            .iter()
            .rev()
            .find(|&&c| !icu::is_skip(c))
            .is_some_and(|&c| icu::is_word(c));
        here != before
    }

    /// The literal `word` (exact scalars) at `pos`: where it ends.
    fn literal(&self, pos: usize, word: &str) -> Option<usize> {
        let mut at = pos;
        for w in word.chars() {
            if self.chars.get(at) != Some(&w) {
                return None;
            }
            at += 1;
        }
        Some(at)
    }

    /// `\s+` at `pos`, greedy: where it ends, if it takes one scalar or more.
    /// What follows it in both patterns can never be a space, so the greedy
    /// length is the only one that can match.
    fn spaces(&self, pos: usize) -> Option<usize> {
        let end = pos
            + self.chars[pos.min(self.len())..]
                .iter()
                .take_while(|&&c| icu::is_space(c))
                .count();
        (end > pos).then_some(end)
    }

    /// `(\d|one|two|three|four|five|six)` at `pos`: where it ends. At most
    /// one choice can match at a place.
    fn number(&self, pos: usize) -> Option<usize> {
        if self.chars.get(pos).is_some_and(|&c| icu::is_digit(c)) {
            return Some(pos + 1);
        }
        ["one", "two", "three", "four", "five", "six"]
            .iter()
            .find_map(|w| self.literal(pos, w))
    }

    /// `(left|right|center|middle)\s+(?:N\s+)?lanes?\b` at `pos`: the side
    /// word's end, the count's span when it is there, and the match's end.
    fn side_lanes(&self, pos: usize) -> Option<(LaneSide, Option<(usize, usize)>)> {
        let (side, at) = [
            ("left", LaneSide::Left),
            ("right", LaneSide::Right),
            ("center", LaneSide::Center),
            ("middle", LaneSide::Center),
        ]
        .iter()
        .find_map(|(w, side)| self.literal(pos, w).map(|end| (*side, end)))?;
        let at = self.spaces(at)?;
        if let Some(n_end) = self.number(at) {
            if let Some(after) = self.spaces(n_end) {
                if self.lanes(after) {
                    return Some((side, Some((at, n_end))));
                }
            }
        }
        self.lanes(at).then_some((side, None))
    }

    /// `lanes?\b` at `pos`.
    fn lanes(&self, pos: usize) -> bool {
        let Some(end) = self.literal(pos, "lane") else {
            return false;
        };
        (self.chars.get(end) == Some(&'s') && self.boundary(end + 1)) || self.boundary(end)
    }

    fn text(&self, span: (usize, usize)) -> String {
        self.chars[span.0..span.1].iter().collect()
    }
}

/// `LaneGuidance.lanePhrase(in:)` on already lowercased text: the first match
/// of `\b(?:N\s+)?(left|right|center|middle)\s+(?:N\s+)?lanes?\b`, N being
/// `(\d|one|two|three|four|five|six)`. The side is left, right, or center
/// for "center" and "middle"; the count is the first number's when it is
/// there, else the second's, read from [`LANE_NUMBERS`] (a digit outside it,
/// such as "7" or an Arabic-Indic three, counts one lane; so does no number).
#[must_use]
pub fn lane_phrase(s: &str) -> Option<(LaneSide, i64)> {
    let t = Scalars::new(s);
    for pos in 0..=t.len() {
        if !t.boundary(pos) {
            continue;
        }
        let with_count = t.number(pos).and_then(|n_end| {
            let at = t.spaces(n_end)?;
            t.side_lanes(at).map(|(side, _)| (side, Some((pos, n_end))))
        });
        let found = with_count.or_else(|| t.side_lanes(pos));
        if let Some((side, count)) = found {
            let count = count
                .map(|span| t.text(span))
                .and_then(|n| LANE_NUMBERS.iter().find(|(w, _)| *w == n).map(|&(_, v)| v));
            return Some((side, count.unwrap_or(1)));
        }
    }
    None
}

/// `exitNumber(in:)`: the first match of `(?i)\bexit\s+\d{1,4}[a-z]?\b` in
/// the instruction as written, split into Characters at whitespace, its last
/// piece uppercased ("Take exit 142a toward I-94 E" gives "142A"); `None`
/// when there is no match. `range(of:options: .regularExpression)` runs on
/// Swift Regex, not ICU: it steps whole Characters and its `\b` is the simple
/// one, a change between a word Character and any other (`swift_regex`).
#[must_use]
pub fn exit_number(instruction: &str) -> Option<String> {
    let clusters: Vec<&str> = swift_text::graphemes(instruction).collect();
    let (start, end) =
        (0..=clusters.len()).find_map(|pos| exit_match(&clusters, pos).map(|end| (pos, end)))?;
    let mut last: Option<&[&str]> = None;
    for piece in clusters[start..end].split(|c| swift_regex::is_space(c)) {
        if !piece.is_empty() {
            last = Some(piece);
        }
    }
    last.map(|piece| swift_text::uppercased(&piece.concat()))
}

/// The exit pattern at Character `pos`: the Character where the match ends.
fn exit_match(clusters: &[&str], pos: usize) -> Option<usize> {
    let word = |i: usize| clusters.get(i).is_some_and(|c| swift_regex::is_word(c));
    let boundary = |i: usize| i.checked_sub(1).is_some_and(word) != word(i);
    if !boundary(pos) {
        return None;
    }
    for (i, letter) in ['e', 'x', 'i', 't'].into_iter().enumerate() {
        if !swift_regex::case_insensitive_is(clusters.get(pos + i)?, letter) {
            return None;
        }
    }
    let spaces = clusters[pos + 4..]
        .iter()
        .take_while(|c| swift_regex::is_space(c))
        .count();
    if spaces == 0 {
        return None;
    }
    // `\s` and `\d` share no Character, so the spaces never give one back.
    let digits_at = pos + 4 + spaces;
    let digits = clusters[digits_at..]
        .iter()
        .take(4)
        .take_while(|c| swift_regex::is_digit(c))
        .count();
    if digits == 0 {
        return None;
    }
    // The pattern is greedy and could give digits back, but every `\d`
    // Character is also a word Character (the `u-rx-*` classes pin it), so
    // fewer digits end between two word Characters: never at `\b`, never
    // before a letter. Only the full run of digits can match.
    let q = digits_at + digits;
    if clusters
        .get(q)
        .is_some_and(|c| swift_regex::is_case_insensitive_az(c))
        && boundary(q + 1)
    {
        Some(q + 1)
    } else {
        boundary(q).then_some(q)
    }
}

/// `LaneGuidance.highlighted(advice:total:)`: which of `total` lanes to light,
/// as the half-open range `lo..hi` (empty when `lo >= hi`). Left lanes from the
/// left edge, right lanes from the right edge, center lanes centered (rounding
/// left). A count below zero, where Swift traps, lights nothing.
#[must_use]
pub fn highlighted(count: i64, side: LaneSide, total: i64) -> (i64, i64) {
    if total <= 0 || count <= 0 {
        return (0, 0);
    }
    let n = count.min(total);
    match side {
        LaneSide::Left => (0, n),
        LaneSide::Right => (total - n, total),
        LaneSide::Center => {
            let start = ((total - n) / 2).max(0);
            (start, (start + n).min(total))
        }
    }
}

/// One arrow of the lane box: the movement, lit or not, and whether a U-turn
/// arrow curls to the left.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Arrow {
    /// The lane movement, in `places_text::TURN_NAMES`' codes.
    pub turn: u8,
    /// One of the lanes to be in.
    pub lit: bool,
    /// A U-turn arrow curls to the left (true) or the right.
    pub u_turn_left: bool,
}

/// `LaneBox.arrows`: from the road's own lanes (`primaries`, each lane's main
/// movement) when there are any, lit where `recommended` says, a U-turn on
/// the left half curling left; else from the instruction's lane advice, the
/// stated lanes lit with the maneuver and two more lanes shown (three at
/// least); else one lit arrow for the maneuver.
#[must_use]
pub fn lane_box(primaries: &[u8], recommended: &[i64], instruction: &str) -> Vec<Arrow> {
    if !primaries.is_empty() {
        let half = primaries.len().div_ceil(2);
        return primaries
            .iter()
            .enumerate()
            .map(|(i, &turn)| Arrow {
                turn,
                lit: i64::try_from(i).is_ok_and(|i| recommended.contains(&i)),
                u_turn_left: i < half,
            })
            .collect();
    }
    let maneuver = turn(instruction);
    let curls_left = side(instruction) != SIDE_RIGHT;
    if let Some(a) = advice(instruction) {
        let total = (a.count + 2).max(3);
        let (lo, hi) = highlighted(a.count, a.side, total);
        return (0..total)
            .map(|i| {
                let lit = (lo..hi).contains(&i);
                Arrow {
                    turn: if lit { maneuver } else { TURN_THROUGH },
                    lit,
                    u_turn_left: curls_left,
                }
            })
            .collect();
    }
    vec![Arrow {
        turn: maneuver,
        lit: true,
        u_turn_left: curls_left,
    }]
}
