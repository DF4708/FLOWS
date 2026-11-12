// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::maneuver`, behind Swift's
//! `ManeuverSymbol`, `LaneGuidance` and `LaneBox`. Implementations live in
//! `flows-core`; this file only crosses.
//!
//! - The symbol comes back as its index in `maneuver::SYMBOL_NAMES`; a
//!   panic answers straight ahead (5).
//! - Sides are `places_text`'s codes (0 left, 1 right, 2 none) and turns
//!   are its `TURN_NAMES` codes; a panic answers no side and through.
//! - Lane advice comes back as `count << 3 | side << 1 | keep`, the side
//!   being 0 left, 1 right, 2 center and `keep` set for "keep left/right";
//!   `-1` means none, and so does a panic or a count that does not fit.
//!   The lane phrase alone comes back the same way, `keep` clear.
//! - The exit number comes back empty for none (a match is never empty).
//! - The lit lanes come back as `[lo, hi]`, half open.
//! - The lane box takes the road's lane turns, then `-1`, then the
//!   recommended lane indices, so the list is never empty; it answers three
//!   numbers per arrow: the turn, lit (1 or 0) and whether a U-turn curls
//!   left (1 or 0). A turn code outside `TURN_NAMES` or a panic answers no
//!   arrows, and Swift draws none.

use crate::contain;
use flows_core::maneuver as mv;
use flows_core::places_text::{SIDE_NONE, TURN_NAMES, TURN_THROUGH};

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        fn flows_maneuver_symbol(instruction: &str) -> i64;
        fn flows_maneuver_side(instruction: &str) -> u8;
        fn flows_maneuver_turn(instruction: &str) -> u8;
        fn flows_maneuver_stripped_destination(text: &str) -> String;
        fn flows_maneuver_lane_phrase(lowercased: &str) -> i64;
        fn flows_maneuver_advice(instruction: &str) -> i64;
        fn flows_maneuver_exit_number(instruction: &str) -> String;
        fn flows_maneuver_highlighted(count: i64, side: i64, total: i64) -> Vec<i64>;
        fn flows_maneuver_lane_box(lanes_then_recommended: &[i64], instruction: &str) -> Vec<i64>;
    }
}

const NONE: i64 = -1;
const UP: i64 = 5;

pub fn flows_maneuver_symbol(instruction: &str) -> i64 {
    contain(UP, || i64::from(mv::symbol(instruction)))
}

pub fn flows_maneuver_side(instruction: &str) -> u8 {
    contain(SIDE_NONE, || mv::side(instruction))
}

pub fn flows_maneuver_turn(instruction: &str) -> u8 {
    contain(TURN_THROUGH, || mv::turn(instruction))
}

pub fn flows_maneuver_stripped_destination(text: &str) -> String {
    contain(text.to_owned(), || {
        mv::stripped_destination(text).to_owned()
    })
}

fn encode(count: i64, side: mv::LaneSide, keep: bool) -> i64 {
    count
        .checked_mul(8)
        .filter(|_| count >= 0)
        .map_or(NONE, |c| c | (side as i64) << 1 | i64::from(keep))
}

pub fn flows_maneuver_lane_phrase(lowercased: &str) -> i64 {
    contain(NONE, || {
        mv::lane_phrase(lowercased).map_or(NONE, |(side, count)| encode(count, side, false))
    })
}

pub fn flows_maneuver_advice(instruction: &str) -> i64 {
    contain(NONE, || {
        mv::advice(instruction).map_or(NONE, |a| encode(a.count, a.side, a.keep))
    })
}

pub fn flows_maneuver_exit_number(instruction: &str) -> String {
    contain(String::new(), || {
        mv::exit_number(instruction).unwrap_or_default()
    })
}

fn lane_side(code: i64) -> Option<mv::LaneSide> {
    match code {
        0 => Some(mv::LaneSide::Left),
        1 => Some(mv::LaneSide::Right),
        2 => Some(mv::LaneSide::Center),
        _ => None,
    }
}

pub fn flows_maneuver_highlighted(count: i64, side: i64, total: i64) -> Vec<i64> {
    contain(vec![0, 0], || {
        let Some(side) = lane_side(side) else {
            return vec![0, 0];
        };
        let (lo, hi) = mv::highlighted(count, side, total);
        vec![lo, hi]
    })
}

pub fn flows_maneuver_lane_box(lanes_then_recommended: &[i64], instruction: &str) -> Vec<i64> {
    contain(Vec::new(), || {
        let Some(split) = lanes_then_recommended.iter().position(|&v| v == NONE) else {
            return Vec::new();
        };
        let (lanes, rest) = lanes_then_recommended.split_at(split);
        let Some(primaries) = lanes
            .iter()
            .map(|&t| {
                u8::try_from(t)
                    .ok()
                    .filter(|&t| usize::from(t) < TURN_NAMES.len())
            })
            .collect::<Option<Vec<u8>>>()
        else {
            return Vec::new();
        };
        mv::lane_box(&primaries, &rest[1..], instruction)
            .into_iter()
            .flat_map(|a| {
                [
                    i64::from(a.turn),
                    i64::from(a.lit),
                    i64::from(a.u_turn_left),
                ]
            })
            .collect()
    })
}
