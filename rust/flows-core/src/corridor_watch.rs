// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The rules of the live corridor watch — Swift's `CorridorWatchRules` at
//! the commit that gathered them out of `AppModel` and
//! `WeatherAlertService`: how far ahead a pass looks ([`window`]), which
//! check points that is and when each is reached ([`slice`]), what one pass
//! adds up to ([`reading`]), and which of the route's own check points a
//! pass repaints ([`fold`]).
//!
//! Every `max`/`min` is the Swift's ([`crate::fcmp`]); distances are
//! [`crate::geo::meters`]. Where the Swift trapped (a check-point index that
//! is not a number, or a route with no check points) the pass looks at every
//! check point instead: a watch that cannot place its window must not stop
//! watching. Pinned by
//! `flows-bridge/tests/fixtures/swift_corridor_watch_oracle.tsv`.

use crate::fcmp::{smax, smin, swift_int};
use crate::geo::meters;

/// A window check point belongs to the route check point within this far.
pub const MATCH_METERS: f64 = 600.0;
/// A risk that moved less than this does not repaint the route.
pub const REPAINT_MARGIN: f64 = 0.02;

/// `CorridorWatchRules.window(speed:)`: `(lookahead meters, cadence
/// seconds)` for a speed in meters a second. About 30 minutes of travel,
/// between 5 km and 150 km; refreshed every 2, 3 or 5 minutes as speed
/// falls. A NaN speed gives a NaN lookahead and the slowest cadence.
///
/// Deterministic; panics: none.
#[must_use]
pub fn window(speed: f64) -> (f64, f64) {
    let lookahead = smin(smax(speed * 1800.0, 5_000.0), 150_000.0);
    let cadence = if speed > 20.0 {
        120.0
    } else if speed > 3.0 {
        180.0
    } else {
        300.0
    };
    (lookahead, cadence)
}

/// `CorridorWatchRules.secondsPerMeter`: the route's pace,
/// `eta / max(distance, 1)`.
///
/// Deterministic; panics: none.
#[must_use]
pub fn seconds_per_meter(eta: f64, distance_meters: f64) -> f64 {
    eta / smax(distance_meters, 1.0)
}

/// `CorridorWatchRules.averageMph`: the speed a route averages, 30 where it
/// has no positive duration.
///
/// Deterministic; panics: none.
#[must_use]
pub fn average_mph(distance_meters: f64, eta: f64) -> f64 {
    if eta > 0.0 {
        (distance_meters / 1609.344) / (eta / 3600.0)
    } else {
        30.0
    }
}

/// The check points one pass looks at.
#[derive(Debug, Clone, PartialEq)]
pub struct Slice {
    /// First and last check point of the window, when the pass is a window;
    /// `None` when it looks at every check point.
    pub range: Option<(usize, usize)>,
    /// Seconds from the vehicle to each check point of the pass, never
    /// below 0 (a NaN reads as 0, as Swift's `max(0, x)` does).
    pub offsets: Vec<f64>,
}

/// `CorridorWatchRules.slice`: check point `i` sits about `i * spacing`
/// meters along the route; the window runs from the vehicle (`along`) to
/// `lookahead` past it, one check point further, clamped to the route.
///
/// The pass is every check point when the window is empty (its end before
/// its start), and — where the Swift trapped — when an index is not a
/// number or the route has no check points.
///
/// Deterministic; panics: none.
#[must_use]
pub fn slice(
    count: usize,
    spacing: f64,
    along: f64,
    lookahead: f64,
    seconds_per_meter: f64,
) -> Slice {
    let max_idx = count as f64 - 1.0;
    let lo = swift_int(smin(smax(along / spacing, 0.0), max_idx));
    let hi = swift_int(smin(
        smax((along + lookahead) / spacing + 1.0, 0.0),
        max_idx,
    ));
    let range = match (lo, hi) {
        (Some(lo), Some(hi)) if lo <= hi => usize::try_from(lo)
            .ok()
            .zip(usize::try_from(hi).ok())
            .filter(|&(_, hi)| hi < count),
        _ => None,
    };
    let (base, n) = match range {
        Some((lo, hi)) => (lo as f64 * spacing, hi - lo + 1),
        None => (0.0, count),
    };
    let offsets = (0..n)
        .map(|i| smax(0.0, (base + i as f64 * spacing - along) * seconds_per_meter))
        .collect();
    Slice { range, offsets }
}

/// One pass, reduced to what the escalation decision needs.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Reading {
    /// The plain mean of the window's risks, 0 for none.
    pub mean: f64,
    /// The worst check point's risk, 0 for none.
    pub peak: f64,
    /// Which check point that is.
    pub peak_index: Option<usize>,
}

/// `CorridorWatchRules.reading`: the mean is the running sum from 0 in
/// order, over the count; the peak is Swift's `max(by: <)` — the first of
/// equal maxima, and a NaN at the first check point is never displaced.
///
/// Deterministic; panics: none.
#[must_use]
pub fn reading(risks: &[f64]) -> Reading {
    let mut best: Option<(usize, f64)> = None;
    let mut sum = 0.0;
    for (i, &r) in risks.iter().enumerate() {
        sum += r;
        let replace = match best {
            None => true,
            Some((_, b)) => b < r,
        };
        if replace {
            best = Some((i, r));
        }
    }
    Reading {
        mean: if risks.is_empty() {
            0.0
        } else {
            sum / risks.len() as f64
        },
        peak: best.map_or(0.0, |(_, r)| r),
        peak_index: best.map(|(i, _)| i),
    }
}

/// A check point as the fold reads it. `code` stands for its alert (event
/// and id together): two check points carry the same alert exactly when
/// their codes are equal.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Mark {
    pub lat: f64,
    pub lon: f64,
    pub risk: f64,
    pub code: i64,
}

/// `CorridorWatchRules.fold`: one entry per route check point — the window
/// check point that repaints it (the last one, when several do), or `None`
/// when it stays as it is.
///
/// Each window check point, in order, belongs to the first nearest route
/// check point strictly within [`MATCH_METERS`]; it repaints that one when
/// the risk moved by more than [`REPAINT_MARGIN`] or the alert changed,
/// read against what earlier window check points already repainted.
///
/// Deterministic; panics: none.
#[must_use]
pub fn fold(route: &[Mark], window: &[Mark]) -> Vec<Option<usize>> {
    let mut state: Vec<(f64, i64)> = route.iter().map(|m| (m.risk, m.code)).collect();
    let mut source = vec![None; route.len()];
    for (wi, w) in window.iter().enumerate() {
        let mut best: Option<usize> = None;
        let mut best_d = MATCH_METERS;
        for (i, s) in route.iter().enumerate() {
            let d = meters(s.lat, s.lon, w.lat, w.lon);
            if d < best_d {
                best_d = d;
                best = Some(i);
            }
        }
        let Some(bi) = best else { continue };
        let Some(slot) = state.get_mut(bi) else {
            continue;
        };
        if (slot.0 - w.risk).abs() > REPAINT_MARGIN || slot.1 != w.code {
            *slot = (w.risk, w.code);
            if let Some(s) = source.get_mut(bi) {
                *s = Some(wi);
            }
        }
    }
    source
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_window_is_half_an_hour_of_travel_between_5_and_150_km() {
        assert_eq!(window(0.0), (5_000.0, 300.0));
        assert_eq!(window(3.0), (5_400.0, 300.0));
        assert_eq!(window(3.5), (6_300.0, 180.0));
        assert_eq!(window(20.0), (36_000.0, 180.0));
        assert_eq!(window(30.0), (54_000.0, 120.0));
        assert_eq!(window(200.0), (150_000.0, 120.0));
        assert_eq!(window(-1.0), (5_000.0, 300.0));
        let (lookahead, cadence) = window(f64::NAN);
        assert!(lookahead.is_nan());
        assert_eq!(cadence, 300.0);
    }

    #[test]
    fn a_slice_runs_from_the_vehicle_to_one_check_point_past_the_lookahead() {
        // 10 check points 40 km apart; the vehicle 100 km in, looking 54 km.
        let s = slice(10, 40_000.0, 100_000.0, 54_000.0, 0.04);
        assert_eq!(s.range, Some((2, 4)));
        // The check point behind the vehicle is "now"; the next are 20 km
        // and 60 km ahead.
        assert_eq!(s.offsets, vec![0.0, 800.0, 2_400.0]);
    }

    #[test]
    fn a_slice_stops_at_the_route_end_and_survives_an_endless_lookahead() {
        let s = slice(3, 40_000.0, 0.0, f64::MAX, 1.0);
        assert_eq!(s.range, Some((0, 2)));
        assert_eq!(s.offsets, vec![0.0, 40_000.0, 80_000.0]);
        let past = slice(3, 40_000.0, 500_000.0, 5_000.0, 1.0);
        assert_eq!(past.range, Some((2, 2)));
        assert_eq!(past.offsets, vec![0.0]);
    }

    #[test]
    fn a_window_that_cannot_be_placed_watches_every_check_point() {
        // Backwards window.
        let back = slice(5, 40_000.0, 120_000.0, -100_000.0, 1.0);
        assert_eq!(back.range, None);
        assert_eq!(back.offsets.len(), 5);
        // Where the Swift trapped.
        let nan = slice(5, 40_000.0, f64::NAN, 5_000.0, 1.0);
        assert_eq!(nan.range, None);
        assert_eq!(nan.offsets, vec![0.0; 5]);
        let none = slice(0, 40_000.0, 0.0, 5_000.0, 1.0);
        assert_eq!(none.range, None);
        assert!(none.offsets.is_empty());
    }

    #[test]
    fn a_reading_is_the_plain_mean_and_the_first_worst() {
        assert_eq!(
            reading(&[]),
            Reading {
                mean: 0.0,
                peak: 0.0,
                peak_index: None
            }
        );
        let r = reading(&[0.25, 0.75, 0.5, 0.75]);
        assert_eq!(r.mean, 0.5625);
        assert_eq!(r.peak, 0.75);
        assert_eq!(r.peak_index, Some(1));
        // A NaN first is never displaced; a later NaN is never taken.
        let first = reading(&[f64::NAN, 0.9]);
        assert!(first.peak.is_nan());
        assert_eq!(first.peak_index, Some(0));
        let later = reading(&[0.25, f64::NAN]);
        assert_eq!(later.peak, 0.25);
        assert!(later.mean.is_nan());
    }

    fn mark(lat: f64, risk: f64, code: i64) -> Mark {
        Mark {
            lat,
            lon: -90.0,
            risk,
            code,
        }
    }

    #[test]
    fn a_pass_repaints_the_check_point_it_sits_on_when_risk_or_alert_moved() {
        let route = [
            mark(43.0, 0.25, 0),
            mark(43.4, 0.25, 0),
            mark(43.8, 0.25, 0),
        ];
        let window = [
            // Same place, risk up: repaints.
            mark(43.0, 0.5, 0),
            // Same place, risk moved 0.01, same alert: stays.
            mark(43.4, 0.26, 0),
            // Same place, same risk, new alert: repaints.
            mark(43.8, 0.25, 7),
            // 1.1 km from any check point: belongs to none.
            mark(43.41, 0.9, 9),
        ];
        assert_eq!(fold(&route, &window), vec![Some(0), None, Some(2)]);
    }

    #[test]
    fn a_later_window_point_reads_what_an_earlier_one_repainted() {
        let route = [mark(43.0, 0.25, 0)];
        // The second moves back within the margin of the FIRST's value, not
        // of the route's: it stays, and the first is the source.
        let window = [mark(43.0, 0.5, 0), mark(43.0, 0.51, 0)];
        assert_eq!(fold(&route, &window), vec![Some(0)]);
        // The second moves on again: it is the source.
        let window = [mark(43.0, 0.5, 0), mark(43.0, 0.75, 0)];
        assert_eq!(fold(&route, &window), vec![Some(1)]);
        assert_eq!(fold(&[], &window), Vec::<Option<usize>>::new());
    }

    #[test]
    fn pace_and_average_speed() {
        assert_eq!(seconds_per_meter(3_600.0, 100_000.0), 0.036);
        assert_eq!(seconds_per_meter(3_600.0, 0.0), 3_600.0);
        assert_eq!(average_mph(1_609.344 * 60.0, 3_600.0), 60.0);
        assert_eq!(average_mph(5_000.0, 0.0), 30.0);
        assert_eq!(average_mph(5_000.0, f64::NAN), 30.0);
    }
}
