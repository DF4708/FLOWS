// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The road of one leg as numbers: Swift's `LegGeometry` at the commit that
//! gathered it out of `NavigationEngine` and `RouteService`. The points, the
//! meters to each, where each step ends, and the rules that read them: which
//! point a fix is at, how far the turn and the end are, the point a way
//! ahead, where a path is cut in half or into check points and where the
//! steep signs stand.
//!
//! Distances are the short-range kernel ([`crate::geo::meters`]), hop by
//! hop. Swift's `max(x, 0)` answers 0 when `0 >= x` and `x` otherwise, so a
//! number that is not one stays; `min(x, 120)` answers 120 only when
//! `120 < x`. Pinned by
//! `flows-bridge/tests/fixtures/swift_leg_geometry_oracle.tsv`.

use crate::geo::meters;

/// A point as (latitude, longitude) in degrees.
pub type Point = (f64, f64);

/// Points the window looks behind the last matched point.
pub const WINDOW_BEHIND: usize = 12;
/// Points the window looks ahead of the last matched point.
pub const WINDOW_AHEAD: usize = 80;
/// How far off the window's best may be before the whole leg is read.
pub const WINDOW_LOST_METERS: f64 = 250.0;
/// A stretch this steep (percent, either way) gets a sign.
pub const STEEP_PERCENT: f64 = 6.0;
/// The most steep signs on one route.
pub const MOST_STEEP_MARKERS: usize = 12;
const METERS_PER_MILE: f64 = 1609.344;

/// Swift's `max(x, 0)`.
fn at_least_zero(x: f64) -> f64 {
    if 0.0 >= x {
        0.0
    } else {
        x
    }
}

/// The leg's geometry, flattened once per leg.
#[derive(Debug, Clone, PartialEq)]
pub struct Leg {
    points: Vec<Point>,
    cumulative: Vec<f64>,
    step_end: Vec<usize>,
}

/// Where the drive stands at a matched point.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Progress {
    /// The step now being driven: moved on past every step whose end the
    /// point has reached, never past the last.
    pub step: usize,
    /// Meters to the end of that step.
    pub to_maneuver: f64,
    /// Meters travelled along the leg.
    pub along: f64,
    /// Meters to the leg's end.
    pub remaining: f64,
    /// The share of the leg still ahead, 0 on a leg with no length.
    pub fraction_left: f64,
    /// The length of the step being driven.
    pub step_spacing: f64,
}

impl Leg {
    /// `LegGeometry(steps:)`: `step_counts` says how many of `points` each
    /// step holds, in order. A step of no points is left out. `None` when
    /// the counts do not add up to the points.
    ///
    /// Deterministic; panics: none.
    #[must_use]
    pub fn new(points: Vec<Point>, step_counts: &[usize]) -> Option<Leg> {
        let mut step_end = Vec::with_capacity(step_counts.len());
        let mut held = 0usize;
        for &count in step_counts {
            if count == 0 {
                continue;
            }
            held = held.checked_add(count)?;
            step_end.push(held - 1);
        }
        if held != points.len() {
            return None;
        }
        let mut cumulative = Vec::with_capacity(points.len());
        let mut running = 0.0;
        let mut prev: Option<Point> = None;
        for &c in &points {
            if let Some(p) = prev {
                running += meters(p.0, p.1, c.0, c.1);
            }
            cumulative.push(running);
            prev = Some(c);
        }
        Some(Leg {
            points,
            cumulative,
            step_end,
        })
    }

    /// Meters from the start to each point.
    #[must_use]
    pub fn cumulative(&self) -> &[f64] {
        &self.cumulative
    }

    /// The index of the point each step ends at.
    #[must_use]
    pub fn step_end(&self) -> &[usize] {
        &self.step_end
    }

    /// The nearest point in `lo..hi` to a fix: the first of equal bests,
    /// and `lo` with the largest finite number when nothing is nearer.
    fn scan(&self, lo: usize, hi: usize, fix: Point) -> (usize, f64) {
        let mut best = (lo, f64::MAX);
        for i in lo..hi {
            let p = self.points[i];
            let d = meters(p.0, p.1, fix.0, fix.1);
            if d < best.1 {
                best = (i, d);
            }
        }
        best
    }

    /// `LegGeometry.match`: the point nearest a fix and how far off it is,
    /// read in a window around the last match and over the whole leg only
    /// when the window's best is more than [`WINDOW_LOST_METERS`] off.
    /// `None` on a leg with no points.
    ///
    /// Deterministic; panics: none.
    #[must_use]
    pub fn match_fix(&self, last: usize, fix: Point) -> Option<(usize, f64)> {
        let n = self.points.len();
        if n == 0 {
            return None;
        }
        let hi = last.saturating_add(WINDOW_AHEAD).min(n);
        let lo = last.saturating_sub(WINDOW_BEHIND).min(hi);
        let found = self.scan(lo, hi, fix);
        Some(if found.1 > WINDOW_LOST_METERS {
            self.scan(0, n, fix)
        } else {
            found
        })
    }

    /// `LegGeometry.progress`: `None` on a leg with no points or for a
    /// point the leg does not hold.
    ///
    /// Deterministic; panics: none.
    #[must_use]
    pub fn progress(&self, nearest: usize, step: usize) -> Option<Progress> {
        let last_step = self.step_end.len().checked_sub(1)?;
        let here = *self.cumulative.get(nearest)?;
        let total = *self.cumulative.last()?;
        let mut current = step;
        while current < last_step && nearest >= self.step_end[current] {
            current += 1;
        }
        let step_index = current.min(last_step);
        let maneuver = self.cumulative[self.step_end[step_index]];
        let step_start = if step_index == 0 {
            0
        } else {
            self.step_end[step_index - 1]
        };
        let remaining = at_least_zero(total - here);
        Some(Progress {
            step: current,
            to_maneuver: at_least_zero(maneuver - here),
            along: here,
            remaining,
            fraction_left: if total > 0.0 { remaining / total } else { 0.0 },
            step_spacing: maneuver - self.cumulative[step_start],
        })
    }

    /// `LegGeometry.ahead`: the first point `meters` or more past point
    /// `index` along the leg, the last point when the leg ends sooner.
    /// `None` on a leg with no points or for a point it does not hold.
    ///
    /// Deterministic; panics: none.
    #[must_use]
    pub fn ahead(&self, index: usize, meters: f64) -> Option<usize> {
        let target = *self.cumulative.get(index)? + meters;
        Some(
            (index..self.cumulative.len())
                .find(|&i| self.cumulative[i] >= target)
                .unwrap_or(self.cumulative.len() - 1),
        )
    }
}

/// `LegGeometry.rerouteWait`: seconds before asking for a new road again
/// after `failures` searches in a row found none: 15, 30, 60, then 120.
#[must_use]
pub fn reroute_wait(failures: i64) -> f64 {
    let wait = 15.0 * 2f64.powf(failures as f64 - 1.0);
    if 120.0 < wait {
        120.0
    } else {
        wait
    }
}

/// `LegGeometry.steepMarkerIndices`: for each stretch `(start mile, end
/// mile, grade percent)` at [`STEEP_PERCENT`] or steeper, the index of the
/// first point at or past its midpoint (never the path's first point) and
/// its grade; the first [`MOST_STEEP_MARKERS`].
///
/// Deterministic; panics: none.
#[must_use]
pub fn steep_marker_indices(coords: &[Point], profile: &[(f64, f64, f64)]) -> Vec<(usize, f64)> {
    let n = coords.len();
    if n <= 1 || profile.is_empty() {
        return Vec::new();
    }
    let mut prefix = vec![0.0; n];
    for i in 1..n {
        let (a, b) = (coords[i - 1], coords[i]);
        prefix[i] = prefix[i - 1] + meters(a.0, a.1, b.0, b.1);
    }
    let first_at_or_above = |target: f64| {
        let (mut lo, mut hi) = (0usize, n);
        while lo < hi {
            let mid = (lo + hi) / 2;
            if prefix[mid] >= target {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        lo
    };
    let mut markers = Vec::new();
    for &(start_mile, end_mile, grade) in profile {
        if grade.is_nan() || grade.abs() < STEEP_PERCENT {
            continue;
        }
        if markers.len() >= MOST_STEEP_MARKERS {
            break;
        }
        let target = (start_mile + end_mile) / 2.0 * METERS_PER_MILE;
        markers.push((first_at_or_above(target).clamp(1, n - 1), grade));
    }
    markers
}

/// Where a path is cut at its own halfway point by length.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Cut {
    /// Between point `before - 1` and point `before`, at `mid`.
    Between {
        /// The first point of the second half after the midpoint.
        before: usize,
        /// The midpoint both halves carry.
        mid: Point,
    },
    /// At a point both halves carry (a path standing still).
    At(usize),
    /// A path of fewer than two points: both halves are the path.
    Whole,
}

/// `LegGeometry.cut`.
///
/// Deterministic; panics: none.
#[must_use]
pub fn cut(coords: &[Point]) -> Cut {
    if coords.len() < 2 {
        return Cut::Whole;
    }
    let hop = |i: usize| {
        let (a, b) = (coords[i - 1], coords[i]);
        meters(a.0, a.1, b.0, b.1)
    };
    let mut total = 0.0;
    for i in 1..coords.len() {
        total += hop(i);
    }
    let half = total / 2.0;
    let mut walked = 0.0;
    for i in 1..coords.len() {
        let h = hop(i);
        if walked + h >= half {
            let t = if h > 0.0 { (half - walked) / h } else { 0.0 };
            let (a, b) = (coords[i - 1], coords[i]);
            return Cut::Between {
                before: i,
                mid: (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t),
            };
        }
        walked += h;
    }
    Cut::At(coords.len() / 2)
}

/// `LegGeometry.checkPointIndices`: each point where the meters since the
/// last cut reach `every_meters`.
///
/// Deterministic; panics: none.
#[must_use]
pub fn check_point_indices(coords: &[Point], every_meters: f64) -> Vec<usize> {
    let mut cuts = Vec::new();
    let mut since_last = 0.0;
    for i in 1..coords.len() {
        let (a, b) = (coords[i - 1], coords[i]);
        since_last += meters(a.0, a.1, b.0, b.1);
        if since_last >= every_meters {
            cuts.push(i);
            since_last = 0.0;
        }
    }
    cuts
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A road north along a meridian, one point every 0.001° (111.32 m).
    fn north(points: usize) -> Vec<Point> {
        (0..points)
            .map(|i| (40.0 + i as f64 * 0.001, -90.0))
            .collect()
    }

    #[test]
    fn a_leg_holds_its_meters_and_step_ends() {
        let leg = Leg::new(north(6), &[2, 0, 3, 1]).expect("counts add up");
        assert_eq!(leg.step_end(), [1, 4, 5]);
        assert_eq!(leg.cumulative().len(), 6);
        assert_eq!(leg.cumulative()[0], 0.0);
        assert!((leg.cumulative()[5] - 556.6).abs() < 0.01);
        assert!(Leg::new(north(6), &[2, 3]).is_none());
        let empty = Leg::new(Vec::new(), &[]).expect("an empty leg");
        assert!(empty.match_fix(0, (40.0, -90.0)).is_none());
        assert!(empty.progress(0, 0).is_none());
        assert!(empty.ahead(0, 10.0).is_none());
    }

    #[test]
    fn a_fix_is_matched_in_the_window_first() {
        // A road out and back over itself: 200 points north, 200 back.
        let mut road = north(200);
        road.extend(north(200).into_iter().rev());
        let leg = Leg::new(road, &[400]).expect("leg");
        let fix = (40.05, -90.0);
        // From the start the window does not reach it: the whole leg is read
        // and the first of the two passes wins.
        assert_eq!(leg.match_fix(0, fix).map(|m| m.0), Some(50));
        // Near the way back, the window holds the second pass.
        assert_eq!(leg.match_fix(340, fix).map(|m| m.0), Some(349));
        // A stale index past the leg's end reads the whole leg.
        assert_eq!(leg.match_fix(9_000, fix).map(|m| m.0), Some(50));
        // A fix that is not a number matches the first point, endlessly far.
        assert_eq!(leg.match_fix(100, (f64::NAN, 0.0)), Some((0, f64::MAX)));
    }

    #[test]
    fn progress_moves_the_step_on_and_measures_what_is_left() {
        let leg = Leg::new(north(11), &[3, 4, 4]).expect("leg");
        let hop = leg.cumulative()[1];
        let p = leg.progress(0, 0).expect("progress");
        assert_eq!(p.step, 0);
        assert_eq!(p.to_maneuver, leg.cumulative()[2]);
        assert_eq!(p.fraction_left, 1.0);
        // At the end of the first step the next one is driven.
        let p = leg.progress(2, 0).expect("progress");
        assert_eq!(p.step, 1);
        assert_eq!(p.to_maneuver, leg.cumulative()[6] - leg.cumulative()[2]);
        assert_eq!(p.step_spacing, leg.cumulative()[6] - leg.cumulative()[2]);
        // The step never moves back, and never past the last.
        assert_eq!(leg.progress(0, 2).expect("progress").step, 2);
        let p = leg.progress(10, 0).expect("progress");
        assert_eq!(
            (p.step, p.to_maneuver, p.remaining, p.fraction_left),
            (2, 0.0, 0.0, 0.0)
        );
        assert!((p.along - 10.0 * hop).abs() < 1e-6);
        // A step past the last reads the last step's end.
        assert_eq!(leg.progress(4, 7).expect("progress").step, 7);
        assert!(leg.progress(11, 0).is_none());
    }

    #[test]
    fn a_leg_with_no_length_has_nothing_left() {
        let leg = Leg::new(vec![(40.0, -90.0); 3], &[3]).expect("leg");
        let p = leg.progress(1, 0).expect("progress");
        assert_eq!((p.remaining, p.fraction_left), (0.0, 0.0));
    }

    #[test]
    fn the_point_ahead_is_the_first_far_enough() {
        let leg = Leg::new(north(11), &[11]).expect("leg");
        assert_eq!(leg.ahead(2, 0.0), Some(2));
        assert_eq!(leg.ahead(2, 300.0), Some(5));
        assert_eq!(leg.ahead(2, 5_000.0), Some(10));
        assert_eq!(leg.ahead(2, f64::NAN), Some(10));
        assert_eq!(leg.ahead(11, 1.0), None);
    }

    #[test]
    fn the_reroute_wait_doubles_to_two_minutes() {
        let waits: Vec<f64> = (1..=6).map(reroute_wait).collect();
        assert_eq!(waits, [15.0, 30.0, 60.0, 120.0, 120.0, 120.0]);
        assert_eq!(reroute_wait(0), 7.5);
    }

    #[test]
    fn steep_signs_stand_at_the_middle_of_steep_stretches() {
        let road = north(101); // about 11.1 km, 6.9 miles
        let profile = [
            (0.0, 2.0, 3.0),
            (2.0, 4.0, -7.5),
            (4.0, 6.0, 6.0),
            (6.0, 60.0, 9.0),
        ];
        let marks = steep_marker_indices(&road, &profile);
        assert_eq!(marks.len(), 3);
        // Mile 3 is 4,828 m: the first point at or past it is index 44.
        assert_eq!(marks[0], (44, -7.5));
        assert_eq!(marks[1].1, 6.0);
        // A stretch whose middle is past the road stands at its last point.
        assert_eq!(marks[2], (100, 9.0));
        // A middle at the start never stands on the first point.
        assert_eq!(steep_marker_indices(&road, &[(0.0, 0.0, 8.0)]), [(1, 8.0)]);
        assert!(steep_marker_indices(&road[..1], &profile).is_empty());
        assert!(steep_marker_indices(&road, &[]).is_empty());
        let many = vec![(1.0, 2.0, 10.0); 20];
        assert_eq!(steep_marker_indices(&road, &many).len(), 12);
    }

    #[test]
    fn a_path_is_cut_at_half_its_length() {
        assert_eq!(cut(&north(1)), Cut::Whole);
        match cut(&north(2)) {
            Cut::Between { before, mid } => {
                assert_eq!(before, 1);
                assert!((mid.0 - 40.0005).abs() < 1e-9);
                assert_eq!(mid.1, -90.0);
            }
            other => panic!("{other:?}"),
        }
        // A long second hop: the half falls inside it.
        match cut(&[(40.0, -90.0), (40.001, -90.0), (40.004, -90.0)]) {
            Cut::Between { before, .. } => assert_eq!(before, 2),
            other => panic!("{other:?}"),
        }
        // A path standing still is cut at its first hop, at that point.
        assert_eq!(
            cut(&[(40.0, -90.0); 4]),
            Cut::Between {
                before: 1,
                mid: (40.0, -90.0)
            }
        );
        // A path with a hop that is not a number is halved by points.
        assert_eq!(
            cut(&[(40.0, -90.0), (f64::NAN, 0.0), (41.0, -90.0)]),
            Cut::At(1)
        );
    }

    #[test]
    fn check_points_fall_where_the_meters_add_up() {
        let road = north(11); // hops of 111.32 m
        assert_eq!(check_point_indices(&road, 300.0), [3, 6, 9]);
        assert_eq!(check_point_indices(&road, 0.0), (1..11).collect::<Vec<_>>());
        assert!(check_point_indices(&road, 5_000.0).is_empty());
        assert!(check_point_indices(&road, f64::NAN).is_empty());
        assert!(check_point_indices(&road[..1], 1.0).is_empty());
        assert!(check_point_indices(&[], 1.0).is_empty());
    }
}
