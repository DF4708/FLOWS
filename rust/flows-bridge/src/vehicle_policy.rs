// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Vehicle policy as Swift calls it: the speed bar's legal lines, the
//! posted-limit parser, towing ratings, the route filter limits, the grade
//! table, the pursuit reach circle and the drive-efficiency verdict.
//! Implementations live in `flows_core::vehicle_policy`; this file only
//! crosses.
//!
//! Boundary encodings, chosen so nothing Swift sends can be misread:
//! - an optional input is a value plus a `has_` flag, never NaN, because the
//!   Swift tells a present NaN apart from nil;
//! - an optional answer that is never NaN when present (the thresholds, the
//!   parsed limit) returns NaN for absent; the effective GCWR can be a
//!   present NaN, so its presence crosses on its own;
//! - codes: standing 0 legal, 1 state, 2 federal; judgment 0 under, 1 slightly
//!   over, 2 over; verdict 0 efficient, 1 fair, 2 wasteful; fuel 0 gas,
//!   1 diesel, 2 electric;
//! - a grade table is flat `[start_mile, end_mile, grade_percent]` triples;
//!   elevations are values plus a parallel byte, 1 present and 0 nil;
//! - estimated ratings are `[gvwr, tow, gcwr, estimated]`, NaN absent and
//!   `estimated` 1 or 0; violations are `[over_gvwr, over_tow, over_gcwr]`
//!   in that order, NaN where the rating is not exceeded.
//!
//! A length or code the encoding does not allow is rejected with the
//! documented fallback, never guessed around.

use crate::contain;
use flows_core::vehicle_policy as vp;

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        fn flows_vehicle_policy_state_tolerance_mph() -> f64;
        fn flows_vehicle_policy_excess_over_limit_mph() -> f64;
        fn flows_vehicle_policy_excess_absolute_mph() -> f64;
        fn flows_vehicle_policy_speed_sign_tolerance_mph() -> f64;
        fn flows_vehicle_policy_speed_sign_over_by_mph() -> f64;
        fn flows_vehicle_policy_pursuit_default_speed_mph() -> f64;
        fn flows_vehicle_policy_pursuit_minimum_radius_meters() -> f64;
        fn flows_vehicle_policy_pursuit_maximum_elapsed_seconds() -> f64;
        fn flows_vehicle_policy_towing_economy_factor() -> f64;
        fn flows_vehicle_policy_filter_default_vehicle_height_meters() -> f64;
        fn flows_vehicle_policy_filter_default_max_grade_percent() -> f64;
        fn flows_vehicle_policy_filter_default_clearance_margin_meters() -> f64;
        fn flows_vehicle_policy_grade_steep_threshold_percent() -> f64;
        fn flows_vehicle_policy_grade_lookahead_miles() -> f64;
        fn flows_vehicle_policy_drive_idle_speed_mph() -> f64;
        fn flows_vehicle_policy_drive_default_efficient_cruise_mph() -> f64;
        fn flows_vehicle_policy_compass_points() -> Vec<String>;

        fn flows_vehicle_policy_estimated_limit_mph(speed_mph: f64) -> f64;
        fn flows_vehicle_policy_effective_limit_mph(
            posted_limit_mph: f64,
            has_posted_limit_mph: bool,
            speed_mph: f64,
        ) -> f64;
        fn flows_vehicle_policy_state_threshold_mph(
            posted_limit_mph: f64,
            has_posted_limit_mph: bool,
        ) -> f64;
        fn flows_vehicle_policy_federal_threshold_mph(
            posted_limit_mph: f64,
            has_posted_limit_mph: bool,
        ) -> f64;
        fn flows_vehicle_policy_standing_code(
            speed_mph: f64,
            posted_limit_mph: f64,
            has_posted_limit_mph: bool,
        ) -> u8;
        fn flows_vehicle_policy_compass_point_index(word: &str) -> i32;

        fn flows_vehicle_policy_parse_maxspeed_mph(raw: &str) -> f64;
        fn flows_vehicle_policy_judge_code(
            speed_mph: f64,
            limit_mph: f64,
            has_limit_mph: bool,
        ) -> u8;

        fn flows_vehicle_policy_pursuit_radius_meters(elapsed_seconds: f64, speed_mph: f64) -> f64;

        fn flows_vehicle_policy_towing_estimated_ratings(
            height_feet: f64,
            fuel_code: u8,
        ) -> Vec<f64>;
        fn flows_vehicle_policy_towing_has_effective_gcwr(
            has_gvwr_lbs: bool,
            has_tow_capacity_lbs: bool,
            has_gcwr_lbs: bool,
        ) -> bool;
        fn flows_vehicle_policy_towing_effective_gcwr_lbs(
            gvwr_lbs: f64,
            has_gvwr_lbs: bool,
            tow_capacity_lbs: f64,
            has_tow_capacity_lbs: bool,
            gcwr_lbs: f64,
            has_gcwr_lbs: bool,
        ) -> f64;
        fn flows_vehicle_policy_towing_check(
            vehicle_weight_lbs: f64,
            towed_weight_lbs: f64,
            gvwr_lbs: f64,
            has_gvwr_lbs: bool,
            tow_capacity_lbs: f64,
            has_tow_capacity_lbs: bool,
            gcwr_lbs: f64,
            has_gcwr_lbs: bool,
        ) -> Vec<f64>;

        fn flows_vehicle_policy_degrees_to_percent(degrees: f64) -> f64;
        fn flows_vehicle_policy_passes_clearances(
            vehicle_height_meters: f64,
            clearance_margin_meters: f64,
            clearances_meters: &[f64],
        ) -> bool;
        fn flows_vehicle_policy_passes_grade(
            max_grade_percent: f64,
            route_max_grade_percent: f64,
            has_route_max_grade_percent: bool,
        ) -> bool;
        fn flows_vehicle_policy_passes_weight_limits(
            rig_weight_lbs: f64,
            has_rig_weight_lbs: bool,
            limits_lbs: &[f64],
        ) -> bool;
        fn flows_vehicle_policy_default_max_grade_degrees(
            published_max_grade_percent: f64,
            has_published_max_grade_percent: bool,
            gvwr_lbs: f64,
            has_gvwr_lbs: bool,
            tow_capacity_lbs: f64,
            has_tow_capacity_lbs: bool,
            height_feet: f64,
            towing: bool,
            trailer_weight_lbs: f64,
        ) -> f64;

        fn flows_vehicle_policy_grade_segments(
            elevations: &[f64],
            present: &[u8],
            spacing_meters: f64,
            start_mile: f64,
        ) -> Vec<f64>;
        fn flows_vehicle_policy_grade_steepest(segments: &[f64], top: i64) -> Vec<f64>;
        fn flows_vehicle_policy_grade_next_steep_index(
            mile: f64,
            segments: &[f64],
            threshold_percent: f64,
            lookahead_miles: f64,
        ) -> i64;

        fn flows_vehicle_policy_drive_drag_penalty(
            speed_mph: f64,
            efficient_cruise_mph: f64,
        ) -> f64;
        fn flows_vehicle_policy_drive_grade_penalty(grade_percent: f64) -> f64;
        fn flows_vehicle_policy_drive_throttle_penalty(accel_mph_per_sec: f64) -> f64;
        fn flows_vehicle_policy_drive_headwind_mph(
            wind_mph: f64,
            wind_from_degrees: f64,
            has_wind_from_degrees: bool,
            heading_degrees: f64,
            has_heading_degrees: bool,
        ) -> f64;
        fn flows_vehicle_policy_drive_airspeed_mph(
            speed_mph: f64,
            wind_mph: f64,
            wind_from_degrees: f64,
            has_wind_from_degrees: bool,
            heading_degrees: f64,
            has_heading_degrees: bool,
        ) -> f64;
        fn flows_vehicle_policy_drive_drag_sensitivity(
            city_mpu: f64,
            has_city_mpu: bool,
            highway_mpu: f64,
            has_highway_mpu: bool,
        ) -> f64;
        fn flows_vehicle_policy_drive_load_factor(
            loaded_weight_lbs: f64,
            has_loaded_weight_lbs: bool,
            vehicle_weight_lbs: f64,
            has_vehicle_weight_lbs: bool,
            towing: bool,
            fuel_fraction: f64,
            has_fuel_fraction: bool,
        ) -> f64;
        fn flows_vehicle_policy_drive_score(
            speed_mph: f64,
            accel_mph_per_sec: f64,
            grade_percent: f64,
            wind_mph: f64,
            wind_from_degrees: f64,
            has_wind_from_degrees: bool,
            heading_degrees: f64,
            has_heading_degrees: bool,
            efficient_cruise_mph: f64,
            city_mpu: f64,
            has_city_mpu: bool,
            highway_mpu: f64,
            has_highway_mpu: bool,
            loaded_weight_lbs: f64,
            has_loaded_weight_lbs: bool,
            vehicle_weight_lbs: f64,
            has_vehicle_weight_lbs: bool,
            towing: bool,
            fuel_fraction: f64,
            has_fuel_fraction: bool,
        ) -> f64;
        fn flows_vehicle_policy_drive_verdict_code(
            speed_mph: f64,
            accel_mph_per_sec: f64,
            grade_percent: f64,
            wind_mph: f64,
            wind_from_degrees: f64,
            has_wind_from_degrees: bool,
            heading_degrees: f64,
            has_heading_degrees: bool,
            efficient_cruise_mph: f64,
            city_mpu: f64,
            has_city_mpu: bool,
            highway_mpu: f64,
            has_highway_mpu: bool,
            loaded_weight_lbs: f64,
            has_loaded_weight_lbs: bool,
            vehicle_weight_lbs: f64,
            has_vehicle_weight_lbs: bool,
            towing: bool,
            fuel_fraction: f64,
            has_fuel_fraction: bool,
        ) -> u8;
        fn flows_vehicle_policy_drive_efficient_cruise_mph(
            city_mpu: f64,
            has_city_mpu: bool,
            highway_mpu: f64,
            has_highway_mpu: bool,
        ) -> f64;
    }
}

fn opt(value: f64, has: bool) -> Option<f64> {
    has.then_some(value)
}

fn nan_absent(value: Option<f64>) -> f64 {
    value.unwrap_or(f64::NAN)
}

fn ratings(
    gvwr_lbs: f64,
    has_gvwr_lbs: bool,
    tow_capacity_lbs: f64,
    has_tow_capacity_lbs: bool,
    gcwr_lbs: f64,
    has_gcwr_lbs: bool,
) -> vp::TowingRatings {
    vp::TowingRatings {
        gvwr_lbs: opt(gvwr_lbs, has_gvwr_lbs),
        tow_capacity_lbs: opt(tow_capacity_lbs, has_tow_capacity_lbs),
        gcwr_lbs: opt(gcwr_lbs, has_gcwr_lbs),
    }
}

/// Flat triples to segments; `None` unless the length is a multiple of 3.
fn segments_from(flat: &[f64]) -> Option<Vec<vp::GradeSegment>> {
    flat.len().is_multiple_of(3).then(|| {
        flat.chunks_exact(3)
            .filter_map(|c| match c {
                [start_mile, end_mile, grade_percent] => Some(vp::GradeSegment {
                    start_mile: *start_mile,
                    end_mile: *end_mile,
                    grade_percent: *grade_percent,
                }),
                _ => None,
            })
            .collect()
    })
}

fn flat_from(segments: &[vp::GradeSegment]) -> Vec<f64> {
    segments
        .iter()
        .flat_map(|s| [s.start_mile, s.end_mile, s.grade_percent])
        .collect()
}

#[allow(clippy::too_many_arguments)]
fn drive_inputs(
    speed_mph: f64,
    accel_mph_per_sec: f64,
    grade_percent: f64,
    wind_mph: f64,
    wind_from_degrees: f64,
    has_wind_from_degrees: bool,
    heading_degrees: f64,
    has_heading_degrees: bool,
    efficient_cruise_mph: f64,
    city_mpu: f64,
    has_city_mpu: bool,
    highway_mpu: f64,
    has_highway_mpu: bool,
    loaded_weight_lbs: f64,
    has_loaded_weight_lbs: bool,
    vehicle_weight_lbs: f64,
    has_vehicle_weight_lbs: bool,
    towing: bool,
    fuel_fraction: f64,
    has_fuel_fraction: bool,
) -> vp::DriveInputs {
    vp::DriveInputs {
        speed_mph,
        accel_mph_per_sec,
        grade_percent,
        wind_mph,
        wind_from_degrees: opt(wind_from_degrees, has_wind_from_degrees),
        heading_degrees: opt(heading_degrees, has_heading_degrees),
        efficient_cruise_mph,
        city_mpu: opt(city_mpu, has_city_mpu),
        highway_mpu: opt(highway_mpu, has_highway_mpu),
        loaded_weight_lbs: opt(loaded_weight_lbs, has_loaded_weight_lbs),
        vehicle_weight_lbs: opt(vehicle_weight_lbs, has_vehicle_weight_lbs),
        towing,
        fuel_fraction: opt(fuel_fraction, has_fuel_fraction),
    }
}

// ---- constants and the compass table: fallback NaN / empty ----

pub fn flows_vehicle_policy_state_tolerance_mph() -> f64 {
    contain(f64::NAN, || vp::STATE_TOLERANCE_MPH)
}
pub fn flows_vehicle_policy_excess_over_limit_mph() -> f64 {
    contain(f64::NAN, || vp::EXCESS_OVER_LIMIT_MPH)
}
pub fn flows_vehicle_policy_excess_absolute_mph() -> f64 {
    contain(f64::NAN, || vp::EXCESS_ABSOLUTE_MPH)
}
pub fn flows_vehicle_policy_speed_sign_tolerance_mph() -> f64 {
    contain(f64::NAN, || vp::SPEED_SIGN_TOLERANCE_MPH)
}
pub fn flows_vehicle_policy_speed_sign_over_by_mph() -> f64 {
    contain(f64::NAN, || vp::SPEED_SIGN_OVER_BY_MPH)
}
pub fn flows_vehicle_policy_pursuit_default_speed_mph() -> f64 {
    contain(f64::NAN, || vp::PURSUIT_DEFAULT_SPEED_MPH)
}
pub fn flows_vehicle_policy_pursuit_minimum_radius_meters() -> f64 {
    contain(f64::NAN, || vp::PURSUIT_MINIMUM_RADIUS_METERS)
}
pub fn flows_vehicle_policy_pursuit_maximum_elapsed_seconds() -> f64 {
    contain(f64::NAN, || vp::PURSUIT_MAXIMUM_ELAPSED_SECONDS)
}
pub fn flows_vehicle_policy_towing_economy_factor() -> f64 {
    contain(f64::NAN, || vp::TOWING_ECONOMY_FACTOR)
}
pub fn flows_vehicle_policy_filter_default_vehicle_height_meters() -> f64 {
    contain(f64::NAN, || vp::DEFAULT_VEHICLE_HEIGHT_METERS)
}
pub fn flows_vehicle_policy_filter_default_max_grade_percent() -> f64 {
    contain(f64::NAN, || vp::DEFAULT_MAX_GRADE_PERCENT)
}
pub fn flows_vehicle_policy_filter_default_clearance_margin_meters() -> f64 {
    contain(f64::NAN, || vp::DEFAULT_CLEARANCE_MARGIN_METERS)
}
pub fn flows_vehicle_policy_grade_steep_threshold_percent() -> f64 {
    contain(f64::NAN, || vp::STEEP_THRESHOLD_PERCENT)
}
pub fn flows_vehicle_policy_grade_lookahead_miles() -> f64 {
    contain(f64::NAN, || vp::STEEP_LOOKAHEAD_MILES)
}
pub fn flows_vehicle_policy_drive_idle_speed_mph() -> f64 {
    contain(f64::NAN, || vp::IDLE_SPEED_MPH)
}
pub fn flows_vehicle_policy_drive_default_efficient_cruise_mph() -> f64 {
    contain(f64::NAN, || vp::DEFAULT_EFFICIENT_CRUISE_MPH)
}
/// The 16 compass words clockwise from north; empty on containment.
pub fn flows_vehicle_policy_compass_points() -> Vec<String> {
    contain(Vec::new(), || {
        vp::COMPASS_POINTS
            .iter()
            .map(|p| (*p).to_string())
            .collect()
    })
}

// ---- SpeedLaw: fallback NaN (absent for the thresholds), 0 legal ----

pub fn flows_vehicle_policy_estimated_limit_mph(speed_mph: f64) -> f64 {
    contain(f64::NAN, || vp::estimated_limit_mph(speed_mph))
}
pub fn flows_vehicle_policy_effective_limit_mph(
    posted_limit_mph: f64,
    has_posted_limit_mph: bool,
    speed_mph: f64,
) -> f64 {
    contain(f64::NAN, || {
        vp::effective_limit_mph(opt(posted_limit_mph, has_posted_limit_mph), speed_mph)
    })
}
/// The yellow line, NaN when nothing is posted.
pub fn flows_vehicle_policy_state_threshold_mph(
    posted_limit_mph: f64,
    has_posted_limit_mph: bool,
) -> f64 {
    contain(f64::NAN, || {
        nan_absent(vp::state_threshold_mph(opt(
            posted_limit_mph,
            has_posted_limit_mph,
        )))
    })
}
/// The red line, NaN when nothing is posted.
pub fn flows_vehicle_policy_federal_threshold_mph(
    posted_limit_mph: f64,
    has_posted_limit_mph: bool,
) -> f64 {
    contain(f64::NAN, || {
        nan_absent(vp::federal_threshold_mph(opt(
            posted_limit_mph,
            has_posted_limit_mph,
        )))
    })
}
/// 0 legal, 1 state violation, 2 federal violation; 0 on containment, so a
/// failure never accuses the driver.
pub fn flows_vehicle_policy_standing_code(
    speed_mph: f64,
    posted_limit_mph: f64,
    has_posted_limit_mph: bool,
) -> u8 {
    contain(0, || {
        match vp::standing(speed_mph, opt(posted_limit_mph, has_posted_limit_mph)) {
            vp::Standing::Legal => 0,
            vp::Standing::StateViolation => 1,
            vp::Standing::FederalViolation => 2,
        }
    })
}
/// Position of an already-normalized wind word in the compass table, or -1.
pub fn flows_vehicle_policy_compass_point_index(word: &str) -> i32 {
    contain(-1, || {
        vp::compass_point_index(word)
            .and_then(|i| i32::try_from(i).ok())
            .unwrap_or(-1)
    })
}

// ---- SpeedSign: fallback NaN (nothing posted), 0 under ----

/// The posted limit in mph, NaN when the tag posts no number.
pub fn flows_vehicle_policy_parse_maxspeed_mph(raw: &str) -> f64 {
    contain(f64::NAN, || nan_absent(vp::parse_maxspeed_mph(raw)))
}
/// 0 under, 1 slightly over, 2 over; 0 on containment.
pub fn flows_vehicle_policy_judge_code(speed_mph: f64, limit_mph: f64, has_limit_mph: bool) -> u8 {
    contain(0, || {
        match vp::judge(speed_mph, opt(limit_mph, has_limit_mph)) {
            vp::Judgment::Under => 0,
            vp::Judgment::SlightlyOver => 1,
            vp::Judgment::Over => 2,
        }
    })
}

// ---- PursuitReach: fallback NaN ----

pub fn flows_vehicle_policy_pursuit_radius_meters(elapsed_seconds: f64, speed_mph: f64) -> f64 {
    contain(f64::NAN, || {
        vp::pursuit_radius_meters(elapsed_seconds, speed_mph)
    })
}

// ---- TowingLimits ----

/// `[gvwr, tow, gcwr, estimated]`, NaN absent, `estimated` 1.0. Empty for a
/// fuel code other than 0 gas, 1 diesel, 2 electric, and on containment.
pub fn flows_vehicle_policy_towing_estimated_ratings(height_feet: f64, fuel_code: u8) -> Vec<f64> {
    contain(Vec::new(), || {
        let fuel = match fuel_code {
            0 => vp::FuelKind::Gas,
            1 => vp::FuelKind::Diesel,
            2 => vp::FuelKind::Electric,
            _ => return Vec::new(),
        };
        let r = vp::estimated_ratings(height_feet, fuel);
        vec![
            nan_absent(r.gvwr_lbs),
            nan_absent(r.tow_capacity_lbs),
            nan_absent(r.gcwr_lbs),
            1.0,
        ]
    })
}
/// Whether an effective GCWR exists for ratings with these fields present;
/// false on containment (an unknown rating never fabricates a violation).
pub fn flows_vehicle_policy_towing_has_effective_gcwr(
    has_gvwr_lbs: bool,
    has_tow_capacity_lbs: bool,
    has_gcwr_lbs: bool,
) -> bool {
    contain(false, || {
        vp::effective_gcwr_lbs(&ratings(
            0.0,
            has_gvwr_lbs,
            0.0,
            has_tow_capacity_lbs,
            0.0,
            has_gcwr_lbs,
        ))
        .is_some()
    })
}
/// The effective GCWR's value. Meaningful only when
/// [`flows_vehicle_policy_towing_has_effective_gcwr`] is true (it can be a
/// present NaN); NaN when absent and on containment.
pub fn flows_vehicle_policy_towing_effective_gcwr_lbs(
    gvwr_lbs: f64,
    has_gvwr_lbs: bool,
    tow_capacity_lbs: f64,
    has_tow_capacity_lbs: bool,
    gcwr_lbs: f64,
    has_gcwr_lbs: bool,
) -> f64 {
    contain(f64::NAN, || {
        nan_absent(vp::effective_gcwr_lbs(&ratings(
            gvwr_lbs,
            has_gvwr_lbs,
            tow_capacity_lbs,
            has_tow_capacity_lbs,
            gcwr_lbs,
            has_gcwr_lbs,
        )))
    })
}
/// `[over_gvwr, over_tow, over_gcwr]` by how many pounds, NaN where not
/// exceeded (an exceeded amount is never NaN). Empty on containment.
#[allow(clippy::too_many_arguments)]
pub fn flows_vehicle_policy_towing_check(
    vehicle_weight_lbs: f64,
    towed_weight_lbs: f64,
    gvwr_lbs: f64,
    has_gvwr_lbs: bool,
    tow_capacity_lbs: f64,
    has_tow_capacity_lbs: bool,
    gcwr_lbs: f64,
    has_gcwr_lbs: bool,
) -> Vec<f64> {
    contain(Vec::new(), || {
        let r = ratings(
            gvwr_lbs,
            has_gvwr_lbs,
            tow_capacity_lbs,
            has_tow_capacity_lbs,
            gcwr_lbs,
            has_gcwr_lbs,
        );
        let mut slots = vec![f64::NAN; 3];
        for v in vp::towing_check(vehicle_weight_lbs, towed_weight_lbs, &r) {
            match v {
                vp::TowingViolation::OverGvwr(by) => slots[0] = by,
                vp::TowingViolation::OverTowCapacity(by) => slots[1] = by,
                vp::TowingViolation::OverGcwr(by) => slots[2] = by,
            }
        }
        slots
    })
}

// ---- FilterLimits: admission falls back to true (unknown never excludes) ----

pub fn flows_vehicle_policy_degrees_to_percent(degrees: f64) -> f64 {
    contain(f64::NAN, || vp::degrees_to_percent(degrees))
}
pub fn flows_vehicle_policy_passes_clearances(
    vehicle_height_meters: f64,
    clearance_margin_meters: f64,
    clearances_meters: &[f64],
) -> bool {
    contain(true, || {
        vp::passes_clearances(
            vehicle_height_meters,
            clearance_margin_meters,
            Some(clearances_meters),
        )
    })
}
pub fn flows_vehicle_policy_passes_grade(
    max_grade_percent: f64,
    route_max_grade_percent: f64,
    has_route_max_grade_percent: bool,
) -> bool {
    contain(true, || {
        vp::passes_grade(
            max_grade_percent,
            opt(route_max_grade_percent, has_route_max_grade_percent),
        )
    })
}
pub fn flows_vehicle_policy_passes_weight_limits(
    rig_weight_lbs: f64,
    has_rig_weight_lbs: bool,
    limits_lbs: &[f64],
) -> bool {
    contain(true, || {
        vp::passes_weight_limits(opt(rig_weight_lbs, has_rig_weight_lbs), Some(limits_lbs))
    })
}
#[allow(clippy::too_many_arguments)]
pub fn flows_vehicle_policy_default_max_grade_degrees(
    published_max_grade_percent: f64,
    has_published_max_grade_percent: bool,
    gvwr_lbs: f64,
    has_gvwr_lbs: bool,
    tow_capacity_lbs: f64,
    has_tow_capacity_lbs: bool,
    height_feet: f64,
    towing: bool,
    trailer_weight_lbs: f64,
) -> f64 {
    contain(f64::NAN, || {
        vp::vehicle_default_max_grade_degrees(
            opt(published_max_grade_percent, has_published_max_grade_percent),
            opt(gvwr_lbs, has_gvwr_lbs),
            opt(tow_capacity_lbs, has_tow_capacity_lbs),
            height_feet,
            towing,
            trailer_weight_lbs,
        )
    })
}

// ---- GradeProfile: fallback empty / -1 ----

/// Flat triples; empty when the two buffers differ in length, and on containment.
pub fn flows_vehicle_policy_grade_segments(
    elevations: &[f64],
    present: &[u8],
    spacing_meters: f64,
    start_mile: f64,
) -> Vec<f64> {
    contain(Vec::new(), || {
        if elevations.len() != present.len() {
            return Vec::new();
        }
        let samples: Vec<Option<f64>> = elevations
            .iter()
            .zip(present)
            .map(|(e, p)| (*p != 0).then_some(*e))
            .collect();
        flat_from(&vp::grade_segments(&samples, spacing_meters, start_mile))
    })
}
/// The `top` steepest as flat triples; empty for a length not a multiple of
/// 3, a negative `top` (where Swift trapped), and on containment.
pub fn flows_vehicle_policy_grade_steepest(segments: &[f64], top: i64) -> Vec<f64> {
    contain(Vec::new(), || match segments_from(segments) {
        Some(table) => flat_from(&vp::steepest(&table, top)),
        None => Vec::new(),
    })
}
/// Index of the next steep segment (in triples), or -1: none qualifies, a
/// length not a multiple of 3, or containment.
pub fn flows_vehicle_policy_grade_next_steep_index(
    mile: f64,
    segments: &[f64],
    threshold_percent: f64,
    lookahead_miles: f64,
) -> i64 {
    contain(-1, || {
        segments_from(segments)
            .and_then(|table| vp::next_steep(mile, &table, threshold_percent, lookahead_miles))
            .and_then(|i| i64::try_from(i).ok())
            .unwrap_or(-1)
    })
}

// ---- DriveEfficiency: fallback NaN, verdict 1 fair ----

pub fn flows_vehicle_policy_drive_drag_penalty(speed_mph: f64, efficient_cruise_mph: f64) -> f64 {
    contain(f64::NAN, || {
        vp::drag_penalty(speed_mph, efficient_cruise_mph)
    })
}
pub fn flows_vehicle_policy_drive_grade_penalty(grade_percent: f64) -> f64 {
    contain(f64::NAN, || vp::grade_penalty(grade_percent))
}
pub fn flows_vehicle_policy_drive_throttle_penalty(accel_mph_per_sec: f64) -> f64 {
    contain(f64::NAN, || vp::throttle_penalty(accel_mph_per_sec))
}
pub fn flows_vehicle_policy_drive_headwind_mph(
    wind_mph: f64,
    wind_from_degrees: f64,
    has_wind_from_degrees: bool,
    heading_degrees: f64,
    has_heading_degrees: bool,
) -> f64 {
    contain(f64::NAN, || {
        vp::headwind_mph(
            wind_mph,
            opt(wind_from_degrees, has_wind_from_degrees),
            opt(heading_degrees, has_heading_degrees),
        )
    })
}
pub fn flows_vehicle_policy_drive_airspeed_mph(
    speed_mph: f64,
    wind_mph: f64,
    wind_from_degrees: f64,
    has_wind_from_degrees: bool,
    heading_degrees: f64,
    has_heading_degrees: bool,
) -> f64 {
    contain(f64::NAN, || {
        let mut i = drive_inputs(
            speed_mph, 0.0, 0.0, wind_mph, 0.0, false, 0.0, false, 0.0, 0.0, false, 0.0, false,
            0.0, false, 0.0, false, false, 0.0, false,
        );
        i.wind_from_degrees = opt(wind_from_degrees, has_wind_from_degrees);
        i.heading_degrees = opt(heading_degrees, has_heading_degrees);
        vp::airspeed_mph(&i)
    })
}
pub fn flows_vehicle_policy_drive_drag_sensitivity(
    city_mpu: f64,
    has_city_mpu: bool,
    highway_mpu: f64,
    has_highway_mpu: bool,
) -> f64 {
    contain(f64::NAN, || {
        vp::drag_sensitivity(
            opt(city_mpu, has_city_mpu),
            opt(highway_mpu, has_highway_mpu),
        )
    })
}
pub fn flows_vehicle_policy_drive_load_factor(
    loaded_weight_lbs: f64,
    has_loaded_weight_lbs: bool,
    vehicle_weight_lbs: f64,
    has_vehicle_weight_lbs: bool,
    towing: bool,
    fuel_fraction: f64,
    has_fuel_fraction: bool,
) -> f64 {
    contain(f64::NAN, || {
        let i = drive_inputs(
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            false,
            0.0,
            false,
            0.0,
            0.0,
            false,
            0.0,
            false,
            loaded_weight_lbs,
            has_loaded_weight_lbs,
            vehicle_weight_lbs,
            has_vehicle_weight_lbs,
            towing,
            fuel_fraction,
            has_fuel_fraction,
        );
        vp::load_factor(&i)
    })
}
#[allow(clippy::too_many_arguments)]
pub fn flows_vehicle_policy_drive_score(
    speed_mph: f64,
    accel_mph_per_sec: f64,
    grade_percent: f64,
    wind_mph: f64,
    wind_from_degrees: f64,
    has_wind_from_degrees: bool,
    heading_degrees: f64,
    has_heading_degrees: bool,
    efficient_cruise_mph: f64,
    city_mpu: f64,
    has_city_mpu: bool,
    highway_mpu: f64,
    has_highway_mpu: bool,
    loaded_weight_lbs: f64,
    has_loaded_weight_lbs: bool,
    vehicle_weight_lbs: f64,
    has_vehicle_weight_lbs: bool,
    towing: bool,
    fuel_fraction: f64,
    has_fuel_fraction: bool,
) -> f64 {
    contain(f64::NAN, || {
        vp::score(&drive_inputs(
            speed_mph,
            accel_mph_per_sec,
            grade_percent,
            wind_mph,
            wind_from_degrees,
            has_wind_from_degrees,
            heading_degrees,
            has_heading_degrees,
            efficient_cruise_mph,
            city_mpu,
            has_city_mpu,
            highway_mpu,
            has_highway_mpu,
            loaded_weight_lbs,
            has_loaded_weight_lbs,
            vehicle_weight_lbs,
            has_vehicle_weight_lbs,
            towing,
            fuel_fraction,
            has_fuel_fraction,
        ))
    })
}
/// 0 efficient, 1 fair, 2 wasteful; 1 on containment.
#[allow(clippy::too_many_arguments)]
pub fn flows_vehicle_policy_drive_verdict_code(
    speed_mph: f64,
    accel_mph_per_sec: f64,
    grade_percent: f64,
    wind_mph: f64,
    wind_from_degrees: f64,
    has_wind_from_degrees: bool,
    heading_degrees: f64,
    has_heading_degrees: bool,
    efficient_cruise_mph: f64,
    city_mpu: f64,
    has_city_mpu: bool,
    highway_mpu: f64,
    has_highway_mpu: bool,
    loaded_weight_lbs: f64,
    has_loaded_weight_lbs: bool,
    vehicle_weight_lbs: f64,
    has_vehicle_weight_lbs: bool,
    towing: bool,
    fuel_fraction: f64,
    has_fuel_fraction: bool,
) -> u8 {
    contain(1, || {
        match vp::verdict(&drive_inputs(
            speed_mph,
            accel_mph_per_sec,
            grade_percent,
            wind_mph,
            wind_from_degrees,
            has_wind_from_degrees,
            heading_degrees,
            has_heading_degrees,
            efficient_cruise_mph,
            city_mpu,
            has_city_mpu,
            highway_mpu,
            has_highway_mpu,
            loaded_weight_lbs,
            has_loaded_weight_lbs,
            vehicle_weight_lbs,
            has_vehicle_weight_lbs,
            towing,
            fuel_fraction,
            has_fuel_fraction,
        )) {
            vp::DriveVerdict::Efficient => 0,
            vp::DriveVerdict::Fair => 1,
            vp::DriveVerdict::Wasteful => 2,
        }
    })
}
pub fn flows_vehicle_policy_drive_efficient_cruise_mph(
    city_mpu: f64,
    has_city_mpu: bool,
    highway_mpu: f64,
    has_highway_mpu: bool,
) -> f64 {
    contain(f64::NAN, || {
        vp::efficient_cruise_mph(
            opt(city_mpu, has_city_mpu),
            opt(highway_mpu, has_highway_mpu),
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn malformed_buffers_take_the_documented_fallbacks() {
        assert!(flows_vehicle_policy_grade_segments(&[1.0, 2.0], &[1], 300.0, 0.0).is_empty());
        assert!(flows_vehicle_policy_grade_steepest(&[1.0, 2.0], 3).is_empty());
        assert_eq!(
            flows_vehicle_policy_grade_next_steep_index(0.0, &[1.0, 2.0], 6.0, 8.0),
            -1
        );
        assert!(flows_vehicle_policy_towing_estimated_ratings(6.0, 3).is_empty());
        assert!(flows_vehicle_policy_grade_steepest(&[0.0, 1.0, 7.0], -1).is_empty());
    }

    #[test]
    fn absent_answers_cross_as_nan_and_present_ones_as_values() {
        assert!(flows_vehicle_policy_state_threshold_mph(0.0, false).is_nan());
        assert_eq!(flows_vehicle_policy_state_threshold_mph(55.0, true), 60.0);
        assert!(flows_vehicle_policy_parse_maxspeed_mph("none").is_nan());
        assert_eq!(flows_vehicle_policy_parse_maxspeed_mph("55 mph"), 55.0);
        let v = flows_vehicle_policy_towing_check(
            7000.0, 12000.0, 7050.0, true, 11200.0, true, 17100.0, true,
        );
        assert!(v[0].is_nan());
        assert_eq!(v[1], 800.0);
        assert_eq!(v[2], 1900.0);
    }
}
