// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::leg_geometry`, behind Swift's
//! `LegGeometry`. Implementations live in `flows-core`; this file only
//! crosses.
//!
//! - a leg is [`FlowsLegGeometry`], built once per leg from two coordinate
//!   columns and the count of points in each step. Swift keeps the points;
//!   the handle answers the meters to each, where each step ends, and the
//!   driving questions.
//! - a path with no steps crosses as two coordinate columns per call.
//!
//! Answers come back as one column, and an empty column is the failure
//! answer (buffers that do not agree, an index the leg does not hold where
//! Swift says so too, or a panic inside):
//!
//! - `match_fix`: `[index, meters off]`.
//! - `progress`: `[step, to the turn, along, left, share left, step
//!   length]`.
//! - `ahead`: the index, -1 for none.
//! - `flows_leg_steep_markers`: `index, grade` for each sign.
//! - `flows_leg_cut`: `[kind, index, lat, lon]`; kind 0 is the whole path,
//!   1 a cut at a point, 2 a cut between two points at the midpoint given.
//! - `flows_leg_check_points`: `[1]` and then the indices, so a path with
//!   no cuts is not taken for a failure.
//!
//! swift-bridge must never see an empty buffer, so Swift answers the empty
//! cases itself: a leg with no points is `flows_leg_geometry_empty`, and a
//! path of fewer than two points or an empty profile never crosses.

// The glue swift-bridge generates for an opaque type casts a pointer to its
// own type; the lint is about that generated code, not ours.
#![allow(clippy::unnecessary_cast)]

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        type FlowsLegGeometry;
        fn flows_leg_geometry(lats: &[f64], lons: &[f64], step_counts: &[i64]) -> FlowsLegGeometry;
        fn flows_leg_geometry_empty() -> FlowsLegGeometry;
        fn cumulative(self: &FlowsLegGeometry) -> Vec<f64>;
        fn step_ends(self: &FlowsLegGeometry) -> Vec<i64>;
        fn match_fix(self: &FlowsLegGeometry, last: i64, lat: f64, lon: f64) -> Vec<f64>;
        fn progress(self: &FlowsLegGeometry, nearest: i64, step: i64) -> Vec<f64>;
        fn ahead(self: &FlowsLegGeometry, index: i64, meters: f64) -> i64;

        fn flows_leg_reroute_wait(failures: i64) -> f64;
        fn flows_leg_steep_markers(
            lats: &[f64],
            lons: &[f64],
            start_miles: &[f64],
            end_miles: &[f64],
            grades: &[f64],
        ) -> Vec<f64>;
        fn flows_leg_cut(lats: &[f64], lons: &[f64]) -> Vec<f64>;
        fn flows_leg_check_points(lats: &[f64], lons: &[f64], every_meters: f64) -> Vec<f64>;
    }
}

use crate::contain;
use flows_core::leg_geometry as lg;

/// The longest wait there is: what a failed call answers, so a broken rule
/// asks for a new road less often, never more.
const LONGEST_WAIT: f64 = 120.0;

/// A leg, or nothing when the buffers did not agree: then every answer is
/// the failure answer.
pub struct FlowsLegGeometry(Option<lg::Leg>);

fn as_i64(n: usize) -> i64 {
    i64::try_from(n).unwrap_or(-1)
}

/// An index as a double. Every index a buffer can hold is exact.
fn as_f64(n: usize) -> f64 {
    n as f64
}

/// The two columns as points; `None` when they differ in length.
fn points(lats: &[f64], lons: &[f64]) -> Option<Vec<lg::Point>> {
    (lats.len() == lons.len()).then(|| lats.iter().zip(lons).map(|(&a, &b)| (a, b)).collect())
}

pub fn flows_leg_geometry(lats: &[f64], lons: &[f64], step_counts: &[i64]) -> FlowsLegGeometry {
    FlowsLegGeometry(contain(None, || {
        let counts: Vec<usize> = step_counts
            .iter()
            .map(|&c| usize::try_from(c).ok())
            .collect::<Option<_>>()?;
        lg::Leg::new(points(lats, lons)?, &counts)
    }))
}

pub fn flows_leg_geometry_empty() -> FlowsLegGeometry {
    FlowsLegGeometry(lg::Leg::new(Vec::new(), &[]))
}

impl FlowsLegGeometry {
    pub fn cumulative(&self) -> Vec<f64> {
        self.0
            .as_ref()
            .map_or_else(Vec::new, |l| l.cumulative().to_vec())
    }

    pub fn step_ends(&self) -> Vec<i64> {
        self.0.as_ref().map_or_else(Vec::new, |l| {
            l.step_end().iter().map(|&i| as_i64(i)).collect()
        })
    }

    /// `[index, meters off]`, or empty on a leg with no points.
    pub fn match_fix(&self, last: i64, lat: f64, lon: f64) -> Vec<f64> {
        contain(Vec::new(), || {
            let last = usize::try_from(last.max(0)).unwrap_or(0);
            self.0
                .as_ref()
                .and_then(|l| l.match_fix(last, (lat, lon)))
                .map_or_else(Vec::new, |(i, m)| vec![as_f64(i), m])
        })
    }

    /// `[step, to the turn, along, left, share left, step length]`, or
    /// empty for a point the leg does not hold.
    pub fn progress(&self, nearest: i64, step: i64) -> Vec<f64> {
        contain(Vec::new(), || {
            let Ok(nearest) = usize::try_from(nearest) else {
                return Vec::new();
            };
            let step = usize::try_from(step.max(0)).unwrap_or(0);
            self.0
                .as_ref()
                .and_then(|l| l.progress(nearest, step))
                .map_or_else(Vec::new, |p| {
                    vec![
                        as_f64(p.step),
                        p.to_maneuver,
                        p.along,
                        p.remaining,
                        p.fraction_left,
                        p.step_spacing,
                    ]
                })
        })
    }

    /// The index, -1 for a point the leg does not hold.
    pub fn ahead(&self, index: i64, meters: f64) -> i64 {
        contain(-1, || {
            let Ok(index) = usize::try_from(index) else {
                return -1;
            };
            self.0
                .as_ref()
                .and_then(|l| l.ahead(index, meters))
                .map_or(-1, as_i64)
        })
    }
}

pub fn flows_leg_reroute_wait(failures: i64) -> f64 {
    contain(LONGEST_WAIT, || lg::reroute_wait(failures))
}

pub fn flows_leg_steep_markers(
    lats: &[f64],
    lons: &[f64],
    start_miles: &[f64],
    end_miles: &[f64],
    grades: &[f64],
) -> Vec<f64> {
    contain(Vec::new(), || {
        let Some(coords) = points(lats, lons) else {
            return Vec::new();
        };
        if start_miles.len() != end_miles.len() || start_miles.len() != grades.len() {
            return Vec::new();
        }
        let profile: Vec<(f64, f64, f64)> = start_miles
            .iter()
            .zip(end_miles)
            .zip(grades)
            .map(|((&s, &e), &g)| (s, e, g))
            .collect();
        lg::steep_marker_indices(&coords, &profile)
            .into_iter()
            .flat_map(|(i, grade)| [as_f64(i), grade])
            .collect()
    })
}

pub fn flows_leg_cut(lats: &[f64], lons: &[f64]) -> Vec<f64> {
    contain(Vec::new(), || {
        let Some(coords) = points(lats, lons) else {
            return Vec::new();
        };
        match lg::cut(&coords) {
            lg::Cut::Whole => vec![0.0, 0.0, 0.0, 0.0],
            lg::Cut::At(i) => vec![1.0, as_f64(i), 0.0, 0.0],
            lg::Cut::Between { before, mid } => vec![2.0, as_f64(before), mid.0, mid.1],
        }
    })
}

pub fn flows_leg_check_points(lats: &[f64], lons: &[f64], every_meters: f64) -> Vec<f64> {
    contain(Vec::new(), || {
        let Some(coords) = points(lats, lons) else {
            return Vec::new();
        };
        let mut out = vec![1.0];
        out.extend(
            lg::check_point_indices(&coords, every_meters)
                .into_iter()
                .map(as_f64),
        );
        out
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    // Three points a hundredth of a degree apart going north, in two steps.
    const LATS: [f64; 3] = [40.0, 40.01, 40.02];
    const LONS: [f64; 3] = [-90.0, -90.0, -90.0];

    #[test]
    fn a_leg_answers_its_columns_and_the_driving_questions() {
        let leg = flows_leg_geometry(&LATS, &LONS, &[2, 1]);
        let cumulative = leg.cumulative();
        assert_eq!(cumulative.len(), 3);
        assert_eq!(cumulative[0], 0.0);
        assert!(cumulative[2] > cumulative[1] && cumulative[1] > 1_000.0);
        assert_eq!(leg.step_ends(), [1, 2]);

        let hit = leg.match_fix(0, 40.0101, -90.0);
        assert_eq!(hit.len(), 2);
        assert_eq!(hit[0], 1.0);
        assert!(hit[1] < 20.0);

        let p = leg.progress(1, 0);
        assert_eq!(p.len(), 6);
        assert_eq!(p[0], 1.0); // the point reached the first step's end
        assert_eq!(p[2], cumulative[1]);
        assert_eq!(p[3], cumulative[2] - cumulative[1]);

        assert_eq!(leg.ahead(0, 1.0), 1);
        assert_eq!(leg.ahead(0, 1e9), 2);
    }

    #[test]
    fn what_the_leg_does_not_hold_answers_the_failure() {
        let leg = flows_leg_geometry(&LATS, &LONS, &[2, 1]);
        assert!(leg.progress(3, 0).is_empty());
        assert!(leg.progress(-1, 0).is_empty());
        assert_eq!(leg.ahead(3, 10.0), -1);
        assert_eq!(leg.ahead(-1, 10.0), -1);
        // A negative last match reads from the start, as Swift's did.
        assert_eq!(leg.match_fix(-5, 40.0, -90.0)[0], 0.0);

        let empty = flows_leg_geometry_empty();
        assert!(empty.cumulative().is_empty());
        assert!(empty.step_ends().is_empty());
        assert!(empty.match_fix(0, 40.0, -90.0).is_empty());
        assert!(empty.progress(0, 0).is_empty());
        assert_eq!(empty.ahead(0, 10.0), -1);
    }

    #[test]
    fn buffers_that_do_not_agree_make_a_leg_that_answers_nothing() {
        for leg in [
            flows_leg_geometry(&LATS, &LONS[..2], &[2, 1]),
            flows_leg_geometry(&LATS, &LONS, &[2, 2]),
            flows_leg_geometry(&LATS, &LONS, &[4, -1]),
        ] {
            assert!(leg.cumulative().is_empty());
            assert!(leg.step_ends().is_empty());
            assert!(leg.match_fix(0, 40.0, -90.0).is_empty());
            assert!(leg.progress(0, 0).is_empty());
            assert_eq!(leg.ahead(0, 10.0), -1);
        }
    }

    #[test]
    fn the_wait_doubles_to_two_minutes() {
        assert_eq!(flows_leg_reroute_wait(1), 15.0);
        assert_eq!(flows_leg_reroute_wait(2), 30.0);
        assert_eq!(flows_leg_reroute_wait(3), 60.0);
        assert_eq!(flows_leg_reroute_wait(4), 120.0);
        assert_eq!(flows_leg_reroute_wait(40), 120.0);
    }

    #[test]
    fn steep_signs_cross_as_index_and_grade() {
        let miles = flows_leg_geometry(&LATS, &LONS, &[3]).cumulative()[2] / 1609.344;
        let out = flows_leg_steep_markers(
            &LATS,
            &LONS,
            &[0.0, miles / 2.0],
            &[miles / 2.0, miles],
            &[2.0, -7.5],
        );
        assert_eq!(out, [2.0, -7.5]);
        assert!(flows_leg_steep_markers(&LATS, &LONS, &[0.0], &[1.0, 2.0], &[7.0]).is_empty());
        assert!(flows_leg_steep_markers(&LATS, &LONS[..1], &[0.0], &[1.0], &[7.0]).is_empty());
    }

    #[test]
    fn a_cut_says_its_kind() {
        let between = flows_leg_cut(&[40.0, 40.02], &[-90.0, -90.0]);
        assert_eq!(between[..2], [2.0, 1.0]);
        assert!((between[2] - 40.01).abs() < 1e-9);
        assert_eq!(between[3], -90.0);
        // A path standing still is cut at its first hop, on the spot.
        assert_eq!(
            flows_leg_cut(&[40.0; 4], &[-90.0; 4]),
            [2.0, 1.0, 40.0, -90.0]
        );
        // A path whose meters are not numbers is halved by its points.
        assert_eq!(
            flows_leg_cut(&[f64::NAN; 4], &[-90.0; 4]),
            [1.0, 2.0, 0.0, 0.0]
        );
        assert_eq!(flows_leg_cut(&[40.0], &[-90.0]), [0.0; 4]);
        assert!(flows_leg_cut(&LATS, &LONS[..2]).is_empty());
    }

    #[test]
    fn check_points_lead_with_the_ok_flag() {
        // Far apart: no cuts, and still not the failure answer.
        assert_eq!(flows_leg_check_points(&LATS, &LONS, 1e9), [1.0]);
        // The last point is a cut when the meters reach the spacing there.
        assert_eq!(flows_leg_check_points(&LATS, &LONS, 1.0), [1.0, 1.0, 2.0]);
        assert!(flows_leg_check_points(&LATS, &LONS[..2], 1.0).is_empty());
    }
}
