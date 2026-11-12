// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::trip_readouts`, behind Swift's
//! `TripReadouts`. Implementations live in `flows-core`; this file only
//! crosses.
//!
//! - Feet are -1 for "show miles"; a real answer is never below 50.
//! - A spoken distance crosses as a kind (0 "1 mile", 1 whole miles,
//!   2 tenths) and its number; a clock as a kind (0 minutes, 1 hours and
//!   minutes, 2 days) and its parts.
//! - Grade stretches cross as flat (start, end, grade) triples. A count
//!   the buffer does not hold, or a panic inside, answers level road.
//!
//! swift-bridge must never see an empty buffer, so Swift answers an empty
//! grade table itself and never crosses with one.

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        fn flows_readout_miles(meters: f64) -> f64;
        fn flows_readout_turn_feet(meters: f64) -> i64;
        fn flows_readout_mile_places(meters: f64) -> i64;
        fn flows_readout_planner_mile_places(meters: f64) -> i64;
        fn flows_readout_spoken_kind(meters: f64) -> i64;
        fn flows_readout_spoken_whole(meters: f64) -> i64;
        fn flows_readout_spoken_tenths(meters: f64) -> f64;
        fn flows_readout_minutes(seconds: f64) -> i64;
        fn flows_readout_clock_kind(seconds: f64, days: bool) -> i64;
        fn flows_readout_clock_hours(seconds: f64) -> i64;
        fn flows_readout_clock_minutes(seconds: f64) -> i64;
        fn flows_readout_clock_days(seconds: f64) -> f64;
        fn flows_readout_minutes_saved(eta: f64, faster: f64) -> i64;
        fn flows_readout_exposure_percent(coverage: f64) -> i64;
        fn flows_readout_exposure_miles(meters: f64, coverage: f64) -> i64;
        fn flows_readout_grade_at(mile: f64, stretches: &[f64], count: i64) -> f64;
    }
}

use crate::contain;
use flows_core::trip_readouts as tr;

/// `TripReadouts.miles`.
pub fn flows_readout_miles(meters: f64) -> f64 {
    tr::miles(meters)
}

/// `TripReadouts.turnFeet`; -1 for "show miles".
pub fn flows_readout_turn_feet(meters: f64) -> i64 {
    tr::turn_feet(meters).unwrap_or(-1)
}

/// `TripReadouts.milePlaces`.
pub fn flows_readout_mile_places(meters: f64) -> i64 {
    tr::mile_places(meters)
}

/// `TripReadouts.plannerMilePlaces`.
pub fn flows_readout_planner_mile_places(meters: f64) -> i64 {
    tr::planner_mile_places(meters)
}

/// `TripReadouts.spokenMiles`, the kind: 0 "1 mile", 1 whole, 2 tenths.
pub fn flows_readout_spoken_kind(meters: f64) -> i64 {
    match tr::spoken_miles(meters) {
        tr::SpokenMiles::One => 0,
        tr::SpokenMiles::Whole(_) => 1,
        tr::SpokenMiles::Tenths(_) => 2,
    }
}

/// The whole miles of a spoken distance; 1 for "1 mile", 0 for tenths.
pub fn flows_readout_spoken_whole(meters: f64) -> i64 {
    match tr::spoken_miles(meters) {
        tr::SpokenMiles::One => 1,
        tr::SpokenMiles::Whole(n) => n,
        tr::SpokenMiles::Tenths(_) => 0,
    }
}

/// The miles of a spoken distance in tenths; not a number for the other
/// kinds.
pub fn flows_readout_spoken_tenths(meters: f64) -> f64 {
    match tr::spoken_miles(meters) {
        tr::SpokenMiles::Tenths(t) => t,
        _ => f64::NAN,
    }
}

/// `TripReadouts.minutes`.
pub fn flows_readout_minutes(seconds: f64) -> i64 {
    tr::minutes(seconds)
}

/// `TripReadouts.clock`, the kind: 0 minutes, 1 hours and minutes, 2 days.
pub fn flows_readout_clock_kind(seconds: f64, days: bool) -> i64 {
    match tr::clock(seconds, days) {
        tr::Clock::Minutes(_) => 0,
        tr::Clock::Hours(..) => 1,
        tr::Clock::Days(_) => 2,
    }
}

/// The whole hours of a time read in hours and minutes.
pub fn flows_readout_clock_hours(seconds: f64) -> i64 {
    tr::minutes(seconds) / 60
}

/// The minutes past the hour of a time read in hours and minutes.
pub fn flows_readout_clock_minutes(seconds: f64) -> i64 {
    tr::minutes(seconds) % 60
}

/// The days of a time read in days.
pub fn flows_readout_clock_days(seconds: f64) -> f64 {
    match tr::clock(seconds, true) {
        tr::Clock::Days(d) => d,
        _ => seconds / 86_400.0,
    }
}

/// `TripReadouts.minutesSaved`.
pub fn flows_readout_minutes_saved(eta: f64, faster: f64) -> i64 {
    tr::minutes_saved(eta, faster)
}

/// `TripReadouts.exposurePercent`.
pub fn flows_readout_exposure_percent(coverage: f64) -> i64 {
    tr::exposure_percent(coverage)
}

/// `TripReadouts.exposureMiles`.
pub fn flows_readout_exposure_miles(meters: f64, coverage: f64) -> i64 {
    tr::exposure_miles(meters, coverage)
}

/// `TripReadouts.grade(atMile:in:)` over the first `count` (start, end,
/// grade) triples. Level road when the call fails.
pub fn flows_readout_grade_at(mile: f64, stretches: &[f64], count: i64) -> f64 {
    contain(0.0, || {
        let held = usize::try_from(count)
            .ok()
            .and_then(|n| n.checked_mul(3))
            .and_then(|n| stretches.get(..n));
        let Some(held) = held else {
            return 0.0;
        };
        let profile: Vec<[f64; 3]> = held
            .chunks_exact(3)
            .filter_map(|c| <[f64; 3]>::try_from(c).ok())
            .collect();
        tr::grade_at(mile, &profile)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const MILE: f64 = 1609.344;

    #[test]
    fn distances_cross_as_feet_places_and_spoken_kinds() {
        assert_eq!(flows_readout_turn_feet(137.16), 450);
        assert_eq!(flows_readout_turn_feet(MILE), -1);
        assert_eq!(flows_readout_mile_places(MILE), 1);
        assert_eq!(flows_readout_planner_mile_places(12.0 * MILE), 0);
        assert_eq!(flows_readout_miles(MILE), 1.0);
        assert_eq!(flows_readout_spoken_kind(MILE), 0);
        assert_eq!(flows_readout_spoken_kind(5.0 * MILE), 1);
        assert_eq!(flows_readout_spoken_whole(5.0 * MILE), 5);
        assert_eq!(flows_readout_spoken_kind(640.0), 2);
        assert_eq!(flows_readout_spoken_tenths(640.0), 0.4);
        assert!(flows_readout_spoken_tenths(MILE).is_nan());
    }

    #[test]
    fn times_cross_as_a_kind_and_its_parts() {
        assert_eq!(flows_readout_minutes(150.0), 3);
        assert_eq!(flows_readout_clock_kind(89.0 * 60.0, true), 0);
        assert_eq!(flows_readout_clock_kind(125.0 * 60.0, false), 1);
        assert_eq!(flows_readout_clock_hours(125.0 * 60.0), 2);
        assert_eq!(flows_readout_clock_minutes(125.0 * 60.0), 5);
        assert_eq!(flows_readout_clock_kind(172_800.0, true), 2);
        assert_eq!(flows_readout_clock_kind(172_800.0, false), 1);
        assert_eq!(flows_readout_clock_days(172_800.0), 2.0);
        assert_eq!(flows_readout_minutes_saved(1_000.0, 700.0), 5);
        assert_eq!(flows_readout_exposure_percent(0.345), 35);
        assert_eq!(flows_readout_exposure_miles(100.0 * MILE, 0.345), 35);
    }

    #[test]
    fn a_grade_table_the_buffer_does_not_hold_is_level_road() {
        let table = [0.0, 1.0, 2.0, 1.0, 2.0, -3.0];
        assert_eq!(flows_readout_grade_at(1.5, &table, 2), -3.0);
        assert_eq!(flows_readout_grade_at(0.5, &table, 1), 2.0);
        assert_eq!(flows_readout_grade_at(1.5, &table, 1), 0.0);
        assert_eq!(flows_readout_grade_at(0.5, &table, 3), 0.0);
        assert_eq!(flows_readout_grade_at(0.5, &table, -1), 0.0);
        assert_eq!(flows_readout_grade_at(0.5, &table, i64::MAX), 0.0);
    }
}
