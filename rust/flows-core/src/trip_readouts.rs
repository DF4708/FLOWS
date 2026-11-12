// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The numbers behind the trip's distance and time readouts: Swift's
//! `TripReadouts` at the commit that gathered them out of the views. The
//! words stay in Swift; the numbers, cut-offs and rounding are here.
//!
//! Swift's `rounded()` is half away from zero, which is `f64::round`.
//! Where the Swift trapped turning a number that is not finite, or too
//! large, into an integer, these use Rust's saturating cast: not-a-number
//! is 0, too large is the largest integer. Pinned by
//! `flows-bridge/tests/fixtures/swift_trip_readouts_oracle.tsv`.

const METERS_PER_MILE: f64 = 1609.344;
const METERS_PER_FOOT: f64 = 0.3048;

/// Miles in a distance of meters.
#[must_use]
pub fn miles(meters: f64) -> f64 {
    meters / METERS_PER_MILE
}

/// `TripReadouts.turnFeet`: feet to show for a turn closer than 0.19 miles,
/// to the nearest 50 and never below 50; `None` further out.
///
/// Deterministic; panics: none.
#[must_use]
pub fn turn_feet(meters: f64) -> Option<i64> {
    (miles(meters) < 0.19)
        .then(|| (((meters / METERS_PER_FOOT / 50.0).round() * 50.0) as i64).max(50))
}

/// `TripReadouts.milePlaces`: one digit after the point below 9.95 miles,
/// none from there.
#[must_use]
pub fn mile_places(meters: f64) -> i64 {
    i64::from(miles(meters) < 9.95)
}

/// `TripReadouts.plannerMilePlaces`: one digit under ten miles, none beyond.
#[must_use]
pub fn planner_mile_places(meters: f64) -> i64 {
    i64::from(miles(meters) < 10.0)
}

/// How Siri says a distance.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SpokenMiles {
    /// "1 mile"
    One,
    /// "12 miles"
    Whole(i64),
    /// "0.4 miles"
    Tenths(f64),
}

/// `TripReadouts.spokenMiles`: under ten miles the distance is rounded to
/// a tenth, and reads as "1 mile", a whole number, or tenths; from ten
/// miles it is a whole number.
///
/// Deterministic; panics: none.
#[must_use]
pub fn spoken_miles(meters: f64) -> SpokenMiles {
    let miles = miles(meters);
    if miles < 10.0 {
        let rounded = (miles * 10.0).round() / 10.0;
        if rounded == 1.0 {
            return SpokenMiles::One;
        }
        return if rounded == rounded.round() {
            SpokenMiles::Whole(rounded as i64)
        } else {
            SpokenMiles::Tenths(rounded)
        };
    }
    SpokenMiles::Whole(miles.round() as i64)
}

/// `TripReadouts.minutes`: whole minutes in a time of seconds, rounded.
#[must_use]
pub fn minutes(seconds: f64) -> i64 {
    (seconds / 60.0).round() as i64
}

/// How a time reads.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Clock {
    /// "45 min"
    Minutes(i64),
    /// "2 h 05 min": hours, minutes past the hour.
    Hours(i64, i64),
    /// "10.8 days"
    Days(f64),
}

/// `TripReadouts.clock`: minutes up to 89, hours and minutes from 90; with
/// `days`, two days or more reads in days.
///
/// Deterministic; panics: none.
#[must_use]
pub fn clock(seconds: f64, days: bool) -> Clock {
    let mins = minutes(seconds);
    if days && mins >= 48 * 60 {
        return Clock::Days(seconds / 86_400.0);
    }
    if mins >= 90 {
        Clock::Hours(mins / 60, mins % 60)
    } else {
        Clock::Minutes(mins)
    }
}

/// `TripReadouts.minutesSaved`: whole minutes a faster road saves, at
/// least 1.
#[must_use]
pub fn minutes_saved(eta: f64, faster: f64) -> i64 {
    (((eta - faster) / 60.0).round() as i64).max(1)
}

/// `TripReadouts.exposurePercent`: the share of a route inside alert
/// areas, as a whole percent.
#[must_use]
pub fn exposure_percent(coverage: f64) -> i64 {
    (coverage * 100.0).round() as i64
}

/// `TripReadouts.exposureMiles`: whole miles of a route inside alert areas.
#[must_use]
pub fn exposure_miles(meters: f64, coverage: f64) -> i64 {
    (miles(meters) * coverage).round() as i64
}

/// `TripReadouts.grade(atMile:in:)`: the grade of the first stretch that
/// holds this mile (both ends included), level road where none does.
/// Stretches are (start mile, end mile, grade percent).
///
/// Deterministic; panics: none.
#[must_use]
pub fn grade_at(mile: f64, profile: &[[f64; 3]]) -> f64 {
    profile
        .iter()
        .find(|s| mile >= s[0] && mile <= s[1])
        .map_or(0.0, |s| s[2])
}

#[cfg(test)]
mod tests {
    use super::*;

    const MILE: f64 = 1609.344;

    #[test]
    fn a_close_turn_reads_in_feet_never_below_fifty() {
        assert_eq!(turn_feet(0.0), Some(50));
        assert_eq!(turn_feet(-20.0), Some(50));
        assert_eq!(turn_feet(137.16), Some(450));
        assert_eq!(turn_feet(0.18 * MILE), Some(950));
        assert_eq!(turn_feet(0.19 * MILE), None);
        assert_eq!(turn_feet(f64::NAN), None);
        // The Swift trapped here.
        assert_eq!(turn_feet(f64::NEG_INFINITY), Some(50));
    }

    #[test]
    fn miles_keep_a_tenth_below_ten() {
        assert_eq!(mile_places(9.94 * MILE), 1);
        assert_eq!(mile_places(9.96 * MILE), 0);
        assert_eq!(planner_mile_places(9.96 * MILE), 1);
        assert_eq!(planner_mile_places(10.0 * MILE), 0);
        assert_eq!(mile_places(f64::NAN), 0);
    }

    #[test]
    fn siri_says_one_mile_whole_miles_or_tenths() {
        assert_eq!(spoken_miles(MILE), SpokenMiles::One);
        assert_eq!(spoken_miles(5.0 * MILE), SpokenMiles::Whole(5));
        assert_eq!(spoken_miles(640.0), SpokenMiles::Tenths(0.4));
        assert_eq!(spoken_miles(212.4 * MILE), SpokenMiles::Whole(212));
        // The Swift trapped on these.
        assert_eq!(spoken_miles(f64::NAN), SpokenMiles::Whole(0));
        assert_eq!(spoken_miles(f64::INFINITY), SpokenMiles::Whole(i64::MAX));
        assert_eq!(
            spoken_miles(f64::NEG_INFINITY),
            SpokenMiles::Whole(i64::MIN)
        );
    }

    #[test]
    fn a_time_reads_in_minutes_hours_or_days() {
        assert_eq!(clock(89.0 * 60.0, true), Clock::Minutes(89));
        assert_eq!(clock(90.0 * 60.0, true), Clock::Hours(1, 30));
        assert_eq!(clock(125.0 * 60.0, false), Clock::Hours(2, 5));
        assert_eq!(clock(172_800.0, true), Clock::Days(2.0));
        assert_eq!(clock(172_800.0, false), Clock::Hours(48, 0));
        assert_eq!(clock(29.0, false), Clock::Minutes(0));
        // The Swift trapped on these.
        assert_eq!(clock(f64::NAN, true), Clock::Minutes(0));
        assert_eq!(clock(f64::INFINITY, true), Clock::Days(f64::INFINITY));
        assert_eq!(minutes(f64::INFINITY), i64::MAX);
    }

    #[test]
    fn saved_minutes_and_alert_share_round() {
        assert_eq!(minutes_saved(1_000.0, 990.0), 1);
        assert_eq!(minutes_saved(1_000.0, 1_200.0), 1);
        assert_eq!(minutes_saved(1_000.0, 700.0), 5);
        assert_eq!(minutes_saved(f64::NAN, 700.0), 1);
        assert_eq!(exposure_percent(0.345), 35);
        assert_eq!(exposure_miles(100.0 * MILE, 0.345), 35);
        assert_eq!(exposure_percent(f64::NAN), 0);
    }

    #[test]
    fn the_grade_is_the_first_stretch_that_holds_the_mile() {
        let p = [[0.0, 1.0, 2.0], [1.0, 2.0, -3.0], [4.0, 5.0, 6.0]];
        assert_eq!(grade_at(0.5, &p), 2.0);
        assert_eq!(grade_at(1.0, &p), 2.0);
        assert_eq!(grade_at(1.5, &p), -3.0);
        assert_eq!(grade_at(3.0, &p), 0.0);
        assert_eq!(grade_at(f64::NAN, &p), 0.0);
        assert_eq!(grade_at(1.0, &[]), 0.0);
    }
}
