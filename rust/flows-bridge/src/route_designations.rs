// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::route_designations`, behind Swift's
//! `SafestRoute`, `CheapestRoute`, `EfficientRoute`, `TruckerDesignation`
//! and `FastestRoute`. Implementations live in `flows-core`; this file only
//! crosses.
//!
//! - Candidates cross as flat rows of numbers, a flag as 0 or 1:
//!   safest (risk, scored); cheapest (fuel, tolls, walk); efficient
//!   (meters, walk); trucker (clears, highways, avoids, grade, wind, walk,
//!   eta).
//! - A pick is the winning row's index, or -1 for none. A call that fails
//!   (a count the rows do not hold, a panic inside) answers -1: no chip.
//! - Minutes are -1 for none; a real answer is never below 1.
//!
//! swift-bridge must never see an empty buffer, so Swift answers an empty
//! list itself and never crosses with one.

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        fn flows_designation_toll_allowance_usd() -> f64;
        fn flows_designation_safest(rows: &[f64], count: i64) -> i64;
        fn flows_designation_cheapest(rows: &[f64], count: i64) -> i64;
        fn flows_designation_efficient(rows: &[f64], count: i64) -> i64;
        fn flows_designation_trucker(rows: &[f64], count: i64) -> i64;
        fn flows_designation_trucker_score(
            has_highways: bool,
            avoids_highways: bool,
            grade_ok: bool,
            wind_ok: bool,
        ) -> f64;
        fn flows_designation_fastest_eta(etas: &[f64], count: i64) -> f64;
        fn flows_designation_chip_minutes(eta: f64, fastest: f64) -> i64;
        fn flows_designation_key_point_minutes(eta: f64, fastest: f64) -> i64;
    }
}

use crate::contain;
use flows_core::route_designations as rd;

/// The first `count` rows of `width` numbers each; `None` when the buffer
/// does not hold them.
fn rows(buffer: &[f64], count: i64, width: usize) -> Option<Vec<&[f64]>> {
    let count = usize::try_from(count).ok()?;
    let held = buffer.get(..count.checked_mul(width)?)?;
    Some(held.chunks_exact(width).collect())
}

fn flag(x: Option<&f64>) -> bool {
    x.is_some_and(|&v| v != 0.0)
}

fn number(x: Option<&f64>) -> f64 {
    x.copied().unwrap_or(f64::NAN)
}

fn index(pick: Option<usize>) -> i64 {
    pick.and_then(|i| i64::try_from(i).ok()).unwrap_or(-1)
}

/// `CheapestRoute.tollAllowanceUSD`.
pub fn flows_designation_toll_allowance_usd() -> f64 {
    rd::TOLL_ALLOWANCE_USD
}

/// `SafestRoute.pick` over rows of (risk, scored).
pub fn flows_designation_safest(buffer: &[f64], count: i64) -> i64 {
    contain(-1, || {
        let Some(rows) = rows(buffer, count, 2) else {
            return -1;
        };
        let risks: Vec<f64> = rows.iter().map(|r| number(r.first())).collect();
        let scored: Vec<bool> = rows.iter().map(|r| flag(r.get(1))).collect();
        index(rd::safest(&risks, &scored))
    })
}

/// `CheapestRoute.pick` over rows of (fuel, tolls, walk).
pub fn flows_designation_cheapest(buffer: &[f64], count: i64) -> i64 {
    contain(-1, || {
        let Some(rows) = rows(buffer, count, 3) else {
            return -1;
        };
        let routes: Vec<rd::Cost> = rows
            .iter()
            .map(|r| rd::Cost {
                fuel_usd: number(r.first()),
                has_tolls: flag(r.get(1)),
                is_walk: flag(r.get(2)),
            })
            .collect();
        index(rd::cheapest(&routes))
    })
}

/// `EfficientRoute.pick` over rows of (meters, walk).
pub fn flows_designation_efficient(buffer: &[f64], count: i64) -> i64 {
    contain(-1, || {
        let Some(rows) = rows(buffer, count, 2) else {
            return -1;
        };
        let meters: Vec<f64> = rows.iter().map(|r| number(r.first())).collect();
        let walk: Vec<bool> = rows.iter().map(|r| flag(r.get(1))).collect();
        index(rd::efficient(&meters, &walk))
    })
}

/// `TruckerDesignation.pick` over rows of (clears, highways, avoids, grade,
/// wind, walk, eta).
pub fn flows_designation_trucker(buffer: &[f64], count: i64) -> i64 {
    contain(-1, || {
        let Some(rows) = rows(buffer, count, 7) else {
            return -1;
        };
        let routes: Vec<rd::Truck> = rows
            .iter()
            .map(|r| rd::Truck {
                clears_bridges: flag(r.first()),
                has_highways: flag(r.get(1)),
                avoids_highways: flag(r.get(2)),
                grade_ok: flag(r.get(3)),
                wind_ok: flag(r.get(4)),
                is_walk: flag(r.get(5)),
                eta: number(r.get(6)),
            })
            .collect();
        index(rd::trucker(&routes))
    })
}

/// `TruckerDesignation.score`.
pub fn flows_designation_trucker_score(
    has_highways: bool,
    avoids_highways: bool,
    grade_ok: bool,
    wind_ok: bool,
) -> f64 {
    rd::trucker_score(&rd::Truck {
        clears_bridges: true,
        has_highways,
        avoids_highways,
        grade_ok,
        wind_ok,
        eta: 0.0,
        is_walk: false,
    })
}

/// `FastestRoute.eta` over the first `count` ETAs. Not a number when the
/// call fails: no route is then called fastest or behind.
pub fn flows_designation_fastest_eta(etas: &[f64], count: i64) -> f64 {
    contain(f64::NAN, || {
        usize::try_from(count)
            .ok()
            .and_then(|n| etas.get(..n))
            .and_then(rd::fastest_eta)
            .unwrap_or(f64::NAN)
    })
}

/// `FastestRoute.chipMinutes`; -1 for "this is the fastest".
pub fn flows_designation_chip_minutes(eta: f64, fastest: f64) -> i64 {
    rd::chip_minutes(eta, fastest).unwrap_or(-1)
}

/// `FastestRoute.keyPointMinutes`; -1 for "not more than a minute behind".
pub fn flows_designation_key_point_minutes(eta: f64, fastest: f64) -> i64 {
    rd::key_point_minutes(eta, fastest).unwrap_or(-1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_cross_as_an_index_or_minus_one() {
        assert_eq!(flows_designation_safest(&[0.5, 1.0, 0.25, 1.0], 2), 1);
        assert_eq!(flows_designation_safest(&[0.5, 1.0, 0.25, 0.0], 2), -1);
        assert_eq!(
            flows_designation_cheapest(&[10.0, 1.0, 0.0, 14.0, 0.0, 0.0], 2),
            1
        );
        assert_eq!(flows_designation_efficient(&[9.0, 0.0, 7.0, 0.0], 2), 1);
        let trucks = [
            0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 100.0, // cannot clear
            1.0, 0.0, 0.0, 1.0, 1.0, 0.0, 200.0,
        ];
        assert_eq!(flows_designation_trucker(&trucks, 2), 1);
        assert_eq!(
            flows_designation_trucker_score(true, false, true, true),
            6.0
        );
        assert_eq!(
            flows_designation_trucker_score(true, true, false, true),
            1.0
        );
    }

    #[test]
    fn a_count_the_rows_do_not_hold_is_no_pick() {
        assert_eq!(flows_designation_safest(&[0.5, 1.0, 0.25, 1.0], 3), -1);
        assert_eq!(flows_designation_safest(&[0.5, 1.0], -1), -1);
        assert_eq!(flows_designation_cheapest(&[10.0, 0.0], 1), -1);
        assert_eq!(flows_designation_trucker(&[1.0; 7], i64::MAX), -1);
        assert!(flows_designation_fastest_eta(&[1.0], 2).is_nan());
    }

    #[test]
    fn time_behind_crosses_as_minutes_or_minus_one() {
        assert_eq!(
            flows_designation_fastest_eta(&[300.0, 200.0, 0.0], 2),
            200.0
        );
        assert_eq!(flows_designation_chip_minutes(200.0, 200.0), -1);
        assert_eq!(flows_designation_chip_minutes(229.0, 200.0), 1);
        assert_eq!(flows_designation_key_point_minutes(260.0, 200.0), -1);
        assert_eq!(flows_designation_key_point_minutes(350.0, 200.0), 2);
        assert_eq!(flows_designation_toll_allowance_usd(), 5.0);
    }
}
