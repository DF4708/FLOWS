// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::corridor_watch`, behind Swift's
//! `CorridorWatchRules`. Implementations live in `flows-core`; this file
//! only crosses.
//!
//! - A slice comes back as one list: 1 when the pass is a window (else 0),
//!   its first and last check point, then the seconds to each check point of
//!   the pass. An EMPTY list means the call failed (a count that is negative
//!   or past [`MAX_CHECK_POINTS`], or a panic inside).
//! - A reading's `peak_index` is -1 for no check points.
//! - The fold takes check points as flat (latitude, longitude, risk) triples
//!   with one alert code each (Swift numbers the distinct alerts; equal
//!   codes mean the same alert), and answers one number per route check
//!   point: the window check point that repaints it, or -1. An EMPTY list
//!   means the call failed; the facade then repaints nothing.
//!
//! swift-bridge must never see an empty buffer, so an empty column is a
//! one-element placeholder and its count says it holds nothing.

#[swift_bridge::bridge]
mod ffi {
    // How far ahead a pass looks (meters) and how often (seconds).
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsCorridorWindow {
        lookahead: f64,
        cadence: f64,
    }
    // One pass: `peak_index` is -1 for no check points.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsCorridorReading {
        mean: f64,
        peak: f64,
        peak_index: f64,
    }

    extern "Rust" {
        fn flows_corridor_window(speed: f64) -> FlowsCorridorWindow;
        fn flows_corridor_seconds_per_meter(eta: f64, distance_meters: f64) -> f64;
        fn flows_corridor_average_mph(distance_meters: f64, eta: f64) -> f64;
        fn flows_corridor_match_meters() -> f64;
        fn flows_corridor_repaint_margin() -> f64;
        fn flows_corridor_slice(
            count: i64,
            spacing: f64,
            along: f64,
            lookahead: f64,
            seconds_per_meter: f64,
        ) -> Vec<f64>;
        fn flows_corridor_reading(risks: &[f64], count: i64) -> FlowsCorridorReading;
        fn flows_corridor_fold(
            route: &[f64],
            route_codes: &[i64],
            route_count: i64,
            window: &[f64],
            window_codes: &[i64],
            window_count: i64,
        ) -> Vec<f64>;
    }
}

use crate::contain;
use ffi::{FlowsCorridorReading, FlowsCorridorWindow};
use flows_core::corridor_watch as cw;

/// More check points than any road has (one every 40 km): a count past this
/// is refused rather than answered with a list that long.
pub const MAX_CHECK_POINTS: usize = 100_000;

/// `CorridorWatchRules.window(speed:)`.
pub fn flows_corridor_window(speed: f64) -> FlowsCorridorWindow {
    let (lookahead, cadence) = cw::window(speed);
    FlowsCorridorWindow { lookahead, cadence }
}

/// `CorridorWatchRules.secondsPerMeter`.
pub fn flows_corridor_seconds_per_meter(eta: f64, distance_meters: f64) -> f64 {
    cw::seconds_per_meter(eta, distance_meters)
}

/// `CorridorWatchRules.averageMph`.
pub fn flows_corridor_average_mph(distance_meters: f64, eta: f64) -> f64 {
    cw::average_mph(distance_meters, eta)
}

/// `CorridorWatchRules.matchMeters`.
pub fn flows_corridor_match_meters() -> f64 {
    cw::MATCH_METERS
}

/// `CorridorWatchRules.repaintMargin`.
pub fn flows_corridor_repaint_margin() -> f64 {
    cw::REPAINT_MARGIN
}

/// `CorridorWatchRules.slice` (see the module notes for the layout).
pub fn flows_corridor_slice(
    count: i64,
    spacing: f64,
    along: f64,
    lookahead: f64,
    seconds_per_meter: f64,
) -> Vec<f64> {
    contain(Vec::new(), || {
        let Some(count) = usize::try_from(count)
            .ok()
            .filter(|&c| c <= MAX_CHECK_POINTS)
        else {
            return Vec::new();
        };
        let s = cw::slice(count, spacing, along, lookahead, seconds_per_meter);
        let (ranged, lo, hi) = match s.range {
            Some((lo, hi)) => (1.0, lo as f64, hi as f64),
            None => (0.0, 0.0, 0.0),
        };
        let mut out = Vec::with_capacity(s.offsets.len() + 3);
        out.extend([ranged, lo, hi]);
        out.extend(s.offsets);
        out
    })
}

/// `CorridorWatchRules.reading` over the first `count` risks. A count the
/// column does not hold reads as no check points.
pub fn flows_corridor_reading(risks: &[f64], count: i64) -> FlowsCorridorReading {
    let none = || FlowsCorridorReading {
        mean: 0.0,
        peak: 0.0,
        peak_index: -1.0,
    };
    contain(none(), || {
        let Some(risks) = usize::try_from(count).ok().and_then(|n| risks.get(..n)) else {
            return none();
        };
        let r = cw::reading(risks);
        FlowsCorridorReading {
            mean: r.mean,
            peak: r.peak,
            peak_index: r.peak_index.map_or(-1.0, |i| i as f64),
        }
    })
}

/// The check points from their triples and codes; `None` when the columns
/// hold fewer than `count`.
fn marks(triples: &[f64], codes: &[i64], count: i64) -> Option<Vec<cw::Mark>> {
    let n = usize::try_from(count).ok()?;
    let triples = triples.get(..n.checked_mul(3)?)?;
    let codes = codes.get(..n)?;
    triples
        .chunks_exact(3)
        .zip(codes)
        .map(|(t, &code)| {
            Some(cw::Mark {
                lat: *t.first()?,
                lon: *t.get(1)?,
                risk: *t.get(2)?,
                code,
            })
        })
        .collect()
}

/// `CorridorWatchRules.fold` (see the module notes for the layout).
pub fn flows_corridor_fold(
    route: &[f64],
    route_codes: &[i64],
    route_count: i64,
    window: &[f64],
    window_codes: &[i64],
    window_count: i64,
) -> Vec<f64> {
    contain(Vec::new(), || {
        let (Some(route), Some(window)) = (
            marks(route, route_codes, route_count),
            marks(window, window_codes, window_count),
        ) else {
            return Vec::new();
        };
        cw::fold(&route, &window)
            .into_iter()
            .map(|s| s.map_or(-1.0, |i| i as f64))
            .collect()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_slice_crosses_as_its_range_then_its_offsets() {
        let v = flows_corridor_slice(10, 40_000.0, 100_000.0, 54_000.0, 0.04);
        assert_eq!(v, vec![1.0, 2.0, 4.0, 0.0, 800.0, 2_400.0]);
        let whole = flows_corridor_slice(2, 40_000.0, f64::NAN, 5_000.0, 1.0);
        assert_eq!(whole, vec![0.0, 0.0, 0.0, 0.0, 0.0]);
    }

    #[test]
    fn a_count_that_cannot_be_a_road_is_refused() {
        assert!(flows_corridor_slice(-1, 40_000.0, 0.0, 5_000.0, 1.0).is_empty());
        assert!(flows_corridor_slice(i64::MAX, 40_000.0, 0.0, 5_000.0, 1.0).is_empty());
    }

    #[test]
    fn a_reading_ignores_the_placeholder_behind_a_zero_count() {
        let none = flows_corridor_reading(&[9.0], 0);
        assert_eq!((none.mean, none.peak, none.peak_index), (0.0, 0.0, -1.0));
        let r = flows_corridor_reading(&[0.25, 0.75], 2);
        assert_eq!((r.mean, r.peak, r.peak_index), (0.5, 0.75, 1.0));
        let short = flows_corridor_reading(&[0.25], 2);
        assert_eq!(short.peak_index, -1.0);
    }

    #[test]
    fn the_fold_answers_one_source_per_route_check_point() {
        let route = [43.0, -90.0, 0.25, 43.4, -90.0, 0.25];
        let window = [43.0, -90.0, 0.5, 43.4, -90.0, 0.25];
        assert_eq!(
            flows_corridor_fold(&route, &[0, 0], 2, &window, &[0, 0], 2),
            vec![0.0, -1.0]
        );
        // A new alert on the second check point repaints it.
        assert_eq!(
            flows_corridor_fold(&route, &[0, 0], 2, &window, &[0, 3], 2),
            vec![0.0, 1.0]
        );
        // Columns that do not line up: the failure answer.
        assert!(flows_corridor_fold(&route, &[0], 2, &window, &[0, 0], 2).is_empty());
        // A zero count ignores its placeholders.
        assert_eq!(
            flows_corridor_fold(&route, &[0, 0], 2, &[0.0], &[0], 0),
            vec![-1.0, -1.0]
        );
    }
}
