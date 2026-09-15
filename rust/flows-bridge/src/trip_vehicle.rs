// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::trip_vehicle`: trip costs and needs, the
//! crash and hours-of-service decisions, vehicle specs and range math, EPA
//! class specs. Implementations live in `flows-core`; this file only crosses.
//!
//! Boundary encodings, chosen so nothing Swift sends can be misread:
//! - a fuel type is its code (0 gas, 1 diesel, 2 electric); a trip need is a
//!   fuel code, `10 + food category`, or 20 for rest;
//! - an optional argument is a value plus a `has_` flag, except a trip-needs
//!   cadence, which is NaN for nil (Swift skips nil and NaN alike);
//! - an optional result is [`ffi::TripVehicleOptional`] (`is_some` 1 or 0),
//!   because a present answer can itself be NaN;
//! - optional spec and class figures are NaN for nil: they are table
//!   literals, never NaN when present;
//! - a schedule is `[mile, code, mile, code, …]`; the spec table is three
//!   parallel lists (makes, models, and [`SPEC_NUMBER_SLOTS`] numbers a row);
//! - a position is an `i32`, -1 for none.
//!
//! A length or count mismatch gets the documented fallback, never a guess.
//! Every function is a pure transform, safe from any thread.

use crate::contain;
use ffi::{TripVehicleClassPhysical, TripVehicleHabits, TripVehicleHosStatus, TripVehicleOptional};
use flows_core::trip_vehicle as tv;

#[swift_bridge::bridge]
mod ffi {
    // (swift-bridge 0.1.59 rejects doc attributes on shared structs, so these
    // are plain comments.)
    //
    // An optional number: `value` is meaningful only when `is_some` is 1.
    #[swift_bridge(swift_repr = "struct")]
    struct TripVehicleOptional {
        is_some: f64,
        value: f64,
    }

    // Hours-of-service status: `code` 0 ok, 1 break soon (with
    // `seconds_until_due`), 2 break due, 3 limit reached.
    #[swift_bridge(swift_repr = "struct")]
    struct TripVehicleHosStatus {
        code: f64,
        seconds_until_due: f64,
    }

    // The learned driving state a GPS fix updates.
    #[swift_bridge(swift_repr = "struct")]
    struct TripVehicleHabits {
        miles_since_fill: f64,
        average_speed_mph: f64,
        idle_fraction: f64,
    }

    // Class-typical physical specs; `gvwr` and `tow_capacity` NaN for nil.
    #[swift_bridge(swift_repr = "struct")]
    struct TripVehicleClassPhysical {
        tank: f64,
        height: f64,
        gvwr: f64,
        tow_capacity: f64,
    }

    extern "Rust" {
        fn flows_trip_vehicle_fuel_type_names() -> Vec<String>;
        fn flows_trip_vehicle_food_category_names() -> Vec<String>;
        fn flows_trip_vehicle_need_label(code: u8) -> String;

        fn flows_trip_vehicle_default_miles_per_unit() -> f64;
        fn flows_trip_vehicle_default_fuel_code() -> u8;
        fn flows_trip_vehicle_grams_co2_per_unit(fuel: u8) -> f64;
        fn flows_trip_vehicle_transit_grams_co2_per_mile(rail: bool, long_haul: bool) -> f64;
        fn flows_trip_vehicle_drive_fuel_cost_usd(
            miles: f64,
            miles_per_unit: f64,
            price_per_unit: f64,
        ) -> TripVehicleOptional;
        fn flows_trip_vehicle_drive_grams_co2_per_mile(
            fuel: u8,
            miles_per_unit: f64,
        ) -> TripVehicleOptional;

        fn flows_trip_vehicle_schedule(total_miles: f64, intervals: &[f64], seed: u64) -> Vec<f64>;
        fn flows_trip_vehicle_next_need_index(after_mile: f64, miles: &[f64]) -> i32;
        fn flows_trip_vehicle_adjusted_remaining_seconds(
            baseline: f64,
            stop_delay_seconds: f64,
        ) -> f64;
        fn flows_trip_vehicle_splitmix64_initial_state(seed: u64) -> u64;
        fn flows_trip_vehicle_splitmix64_advance(state: u64) -> u64;
        fn flows_trip_vehicle_splitmix64_mix(state: u64) -> u64;

        fn flows_trip_vehicle_impact_g_force() -> f64;
        fn flows_trip_vehicle_hard_impact_g_force() -> f64;
        fn flows_trip_vehicle_confirm_impact_g_force() -> f64;
        fn flows_trip_vehicle_min_pre_impact_speed_mps() -> f64;
        fn flows_trip_vehicle_crash_stop_speed_mps() -> f64;
        fn flows_trip_vehicle_min_speed_drop_fraction() -> f64;
        fn flows_trip_vehicle_max_meters_from_road() -> f64;
        fn flows_trip_vehicle_assist_words() -> Vec<String>;
        fn flows_trip_vehicle_ok_words() -> Vec<String>;
        fn flows_trip_vehicle_is_impact_acceleration(acceleration_g: f64) -> bool;
        fn flows_trip_vehicle_is_impact_window(window: &[f64]) -> bool;
        fn flows_trip_vehicle_is_crash(
            window: &[f64],
            speed_before_mps: f64,
            speed_after_mps: f64,
            meters_from_road: f64,
            has_meters_from_road: bool,
        ) -> bool;
        fn flows_trip_vehicle_interpret_reply(transcript: &str) -> i32;

        fn flows_trip_vehicle_hos_break_due_seconds() -> f64;
        fn flows_trip_vehicle_hos_warn_before_break_seconds() -> f64;
        fn flows_trip_vehicle_hos_daily_driving_limit_seconds() -> f64;
        fn flows_trip_vehicle_hos_break_reset_seconds() -> f64;
        fn flows_trip_vehicle_hos_status(driving_seconds: f64) -> TripVehicleHosStatus;

        fn flows_trip_vehicle_spec_number_slots() -> u32;
        fn flows_trip_vehicle_spec_makes() -> Vec<String>;
        fn flows_trip_vehicle_spec_models() -> Vec<String>;
        fn flows_trip_vehicle_spec_numbers() -> Vec<f64>;
        fn flows_trip_vehicle_distinct_makes() -> Vec<String>;
        fn flows_trip_vehicle_spec_rows_for_make(make: &str) -> Vec<f64>;
        fn flows_trip_vehicle_spec_index(make: &str, model: &str) -> i32;
        fn flows_trip_vehicle_minimum_height_feet() -> f64;
        fn flows_trip_vehicle_combined_miles_per_unit(city_mpu: f64, highway_mpu: f64) -> f64;
        fn flows_trip_vehicle_rated_miles_per_unit(city_mpu: f64, highway_mpu: f64) -> f64;

        fn flows_trip_vehicle_reserve_miles() -> f64;
        fn flows_trip_vehicle_efficiency_factor(average_speed_mph: f64, idle_fraction: f64) -> f64;
        fn flows_trip_vehicle_rated_range_miles(
            tank_capacity_units: f64,
            rated_miles_per_unit: f64,
        ) -> f64;
        fn flows_trip_vehicle_miles_per_unit_at_speed(
            tank_capacity_units: f64,
            rated_miles_per_unit: f64,
            city_miles_per_unit: f64,
            has_city_miles_per_unit: bool,
            highway_miles_per_unit: f64,
            has_highway_miles_per_unit: bool,
            mph: f64,
        ) -> f64;
        fn flows_trip_vehicle_effective_range_miles(
            tank_capacity_units: f64,
            rated_miles_per_unit: f64,
            city_miles_per_unit: f64,
            has_city_miles_per_unit: bool,
            highway_miles_per_unit: f64,
            has_highway_miles_per_unit: bool,
            average_speed_mph: f64,
            idle_fraction: f64,
        ) -> f64;
        fn flows_trip_vehicle_fuel_fraction_after(
            tank_capacity_units: f64,
            rated_miles_per_unit: f64,
            city_miles_per_unit: f64,
            has_city_miles_per_unit: bool,
            highway_miles_per_unit: f64,
            has_highway_miles_per_unit: bool,
            miles_since_fill: f64,
            average_speed_mph: f64,
            idle_fraction: f64,
        ) -> f64;
        fn flows_trip_vehicle_expected_range_miles(
            tank_capacity_units: f64,
            rated_miles_per_unit: f64,
            city_miles_per_unit: f64,
            has_city_miles_per_unit: bool,
            highway_miles_per_unit: f64,
            has_highway_miles_per_unit: bool,
            miles_since_fill: f64,
            average_speed_mph: f64,
            idle_fraction: f64,
        ) -> f64;
        fn flows_trip_vehicle_should_recommend_fuel(
            range_remaining_miles: f64,
            miles_to_next_station: f64,
            reserve_miles: f64,
        ) -> bool;

        fn flows_trip_vehicle_restore_driving_accepts(
            average_speed_mph: f64,
            idle_fraction: f64,
        ) -> bool;
        fn flows_trip_vehicle_restore_driving_idle(idle_fraction: f64) -> f64;
        fn flows_trip_vehicle_record_fix(
            miles_since_fill: f64,
            average_speed_mph: f64,
            idle_fraction: f64,
            speed_mps: f64,
            delta_meters: f64,
            towing: bool,
            towing_economy_factor: f64,
        ) -> TripVehicleHabits;
        fn flows_trip_vehicle_store_expected_range_miles(
            tank_capacity_units: f64,
            rated_miles_per_unit: f64,
            city_miles_per_unit: f64,
            has_city_miles_per_unit: bool,
            highway_miles_per_unit: f64,
            has_highway_miles_per_unit: bool,
            miles_since_fill: f64,
            average_speed_mph: f64,
            idle_fraction: f64,
            telemetry_fuel_fraction: f64,
            has_telemetry_fuel_fraction: bool,
            towing: bool,
            towing_economy_factor: f64,
        ) -> f64;

        fn flows_trip_vehicle_epa_class_physical(vclass: &str) -> TripVehicleClassPhysical;
        fn flows_trip_vehicle_epa_validated_tank(tank: f64, combined_mpu: f64) -> f64;
        fn flows_trip_vehicle_epa_fuel_type_code(fuel: &str) -> u8;
    }
}

/// Numbers per spec row in [`flows_trip_vehicle_spec_numbers`]: fuel code,
/// city, highway, tank, height, GVWR, tow capacity, GCWR, published grade,
/// top speed (the last five NaN when unpublished).
pub const SPEC_NUMBER_SLOTS: usize = 10;

const NONE: TripVehicleOptional = TripVehicleOptional {
    is_some: 0.0,
    value: f64::NAN,
};

fn optional(v: Option<f64>) -> TripVehicleOptional {
    match v {
        Some(value) => TripVehicleOptional {
            is_some: 1.0,
            value,
        },
        None => NONE,
    }
}

fn strings(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| (*s).to_string()).collect()
}

fn position(p: Option<usize>) -> i32 {
    p.and_then(|i| i32::try_from(i).ok()).unwrap_or(-1)
}

fn economy(
    tank: f64,
    rated: f64,
    city: f64,
    has_city: bool,
    highway: f64,
    has_highway: bool,
) -> tv::VehicleEconomy {
    tv::VehicleEconomy {
        tank_capacity_units: tank,
        rated_miles_per_unit: rated,
        city_miles_per_unit: has_city.then_some(city),
        highway_miles_per_unit: has_highway.then_some(highway),
    }
}

fn nan_for_none(v: Option<f64>) -> f64 {
    v.unwrap_or(f64::NAN)
}

// ---- codes and tables: fallbacks are empty ----

pub fn flows_trip_vehicle_fuel_type_names() -> Vec<String> {
    contain(Vec::new(), || strings(&tv::FUEL_TYPE_NAMES))
}
pub fn flows_trip_vehicle_food_category_names() -> Vec<String> {
    contain(Vec::new(), || strings(&tv::FOOD_CATEGORY_NAMES))
}
/// The need's label text; empty for an unknown code.
pub fn flows_trip_vehicle_need_label(code: u8) -> String {
    contain(String::new(), || tv::need_label(code).unwrap_or_default())
}

// ---- trip costs: fallback NaN / none ----

pub fn flows_trip_vehicle_default_miles_per_unit() -> f64 {
    tv::DEFAULT_MILES_PER_UNIT
}
pub fn flows_trip_vehicle_default_fuel_code() -> u8 {
    tv::DEFAULT_FUEL
}
pub fn flows_trip_vehicle_grams_co2_per_unit(fuel: u8) -> f64 {
    contain(f64::NAN, || tv::grams_co2_per_unit(fuel))
}
pub fn flows_trip_vehicle_transit_grams_co2_per_mile(rail: bool, long_haul: bool) -> f64 {
    contain(f64::NAN, || tv::transit_grams_co2_per_mile(rail, long_haul))
}
pub fn flows_trip_vehicle_drive_fuel_cost_usd(
    miles: f64,
    miles_per_unit: f64,
    price_per_unit: f64,
) -> TripVehicleOptional {
    contain(NONE, || {
        optional(tv::drive_fuel_cost_usd(
            miles,
            miles_per_unit,
            price_per_unit,
        ))
    })
}
pub fn flows_trip_vehicle_drive_grams_co2_per_mile(
    fuel: u8,
    miles_per_unit: f64,
) -> TripVehicleOptional {
    contain(NONE, || {
        optional(tv::drive_grams_co2_per_mile(fuel, miles_per_unit))
    })
}

// ---- trip needs ----

/// `[mile, code, …]` for the schedule. `intervals` must hold exactly the five
/// cadences (gas, diesel, electric, food, rest; NaN for nil); any other
/// length, or containment, is the empty schedule.
pub fn flows_trip_vehicle_schedule(total_miles: f64, intervals: &[f64], seed: u64) -> Vec<f64> {
    contain(Vec::new(), || {
        let Ok(iv) = <&[f64; 5]>::try_from(intervals) else {
            return Vec::new();
        };
        tv::schedule(total_miles, iv, seed)
            .iter()
            .flat_map(|e| [e.mile, f64::from(e.code)])
            .collect()
    })
}
/// Position of the first mile strictly past `after_mile`; -1 for none or on
/// containment.
pub fn flows_trip_vehicle_next_need_index(after_mile: f64, miles: &[f64]) -> i32 {
    contain(-1, || position(tv::next_need_index(after_mile, miles)))
}
pub fn flows_trip_vehicle_adjusted_remaining_seconds(
    baseline: f64,
    stop_delay_seconds: f64,
) -> f64 {
    contain(f64::NAN, || {
        tv::adjusted_remaining_seconds(baseline, stop_delay_seconds)
    })
}
/// Wrapping integer steps; nothing here can panic, and 0 is the documented
/// containment value.
pub fn flows_trip_vehicle_splitmix64_initial_state(seed: u64) -> u64 {
    contain(0, || tv::splitmix64_initial_state(seed))
}
pub fn flows_trip_vehicle_splitmix64_advance(state: u64) -> u64 {
    contain(0, || tv::splitmix64_advance(state))
}
pub fn flows_trip_vehicle_splitmix64_mix(state: u64) -> u64 {
    contain(0, || tv::splitmix64_mix(state))
}

// ---- crash decisions: fallback "no impact" / "unclear" ----

pub fn flows_trip_vehicle_impact_g_force() -> f64 {
    tv::IMPACT_G_FORCE
}
pub fn flows_trip_vehicle_hard_impact_g_force() -> f64 {
    tv::HARD_IMPACT_G_FORCE
}
pub fn flows_trip_vehicle_confirm_impact_g_force() -> f64 {
    tv::CONFIRM_IMPACT_G_FORCE
}
pub fn flows_trip_vehicle_min_pre_impact_speed_mps() -> f64 {
    tv::MIN_PRE_IMPACT_SPEED_MPS
}
pub fn flows_trip_vehicle_crash_stop_speed_mps() -> f64 {
    tv::CRASH_STOP_SPEED_MPS
}
pub fn flows_trip_vehicle_min_speed_drop_fraction() -> f64 {
    tv::MIN_SPEED_DROP_FRACTION
}
pub fn flows_trip_vehicle_max_meters_from_road() -> f64 {
    tv::MAX_METERS_FROM_ROAD
}
pub fn flows_trip_vehicle_assist_words() -> Vec<String> {
    contain(Vec::new(), || strings(tv::ASSIST_WORDS))
}
pub fn flows_trip_vehicle_ok_words() -> Vec<String> {
    contain(Vec::new(), || strings(tv::OK_WORDS))
}
pub fn flows_trip_vehicle_is_impact_acceleration(acceleration_g: f64) -> bool {
    contain(false, || tv::is_impact_acceleration(acceleration_g))
}
pub fn flows_trip_vehicle_is_impact_window(window: &[f64]) -> bool {
    contain(false, || tv::is_impact_window(window))
}
pub fn flows_trip_vehicle_is_crash(
    window: &[f64],
    speed_before_mps: f64,
    speed_after_mps: f64,
    meters_from_road: f64,
    has_meters_from_road: bool,
) -> bool {
    contain(false, || {
        tv::is_crash(
            window,
            speed_before_mps,
            speed_after_mps,
            has_meters_from_road.then_some(meters_from_road),
        )
    })
}
/// 1 wants help, 0 stands down, -1 unclear (and the containment value, so a
/// fault keeps the check-in asking).
pub fn flows_trip_vehicle_interpret_reply(transcript: &str) -> i32 {
    contain(-1, || match tv::interpret_reply(transcript) {
        Some(true) => 1,
        Some(false) => 0,
        None => -1,
    })
}

// ---- hours of service: fallback ok ----

pub fn flows_trip_vehicle_hos_break_due_seconds() -> f64 {
    tv::HOS_BREAK_DUE_SECONDS
}
pub fn flows_trip_vehicle_hos_warn_before_break_seconds() -> f64 {
    tv::HOS_WARN_BEFORE_BREAK_SECONDS
}
pub fn flows_trip_vehicle_hos_daily_driving_limit_seconds() -> f64 {
    tv::HOS_DAILY_DRIVING_LIMIT_SECONDS
}
pub fn flows_trip_vehicle_hos_break_reset_seconds() -> f64 {
    tv::HOS_BREAK_RESET_SECONDS
}
pub fn flows_trip_vehicle_hos_status(driving_seconds: f64) -> TripVehicleHosStatus {
    let status = |code: f64, seconds_until_due: f64| TripVehicleHosStatus {
        code,
        seconds_until_due,
    };
    contain(status(0.0, f64::NAN), || {
        match tv::hos_status(driving_seconds) {
            tv::HosStatus::Ok => status(0.0, f64::NAN),
            tv::HosStatus::BreakSoon { seconds_until_due } => status(1.0, seconds_until_due),
            tv::HosStatus::BreakDue => status(2.0, f64::NAN),
            tv::HosStatus::LimitReached => status(3.0, f64::NAN),
        }
    })
}

// ---- vehicle specs ----

pub fn flows_trip_vehicle_spec_number_slots() -> u32 {
    SPEC_NUMBER_SLOTS as u32
}
pub fn flows_trip_vehicle_spec_makes() -> Vec<String> {
    contain(Vec::new(), || {
        tv::VEHICLE_SPECS
            .iter()
            .map(|r| r.make.to_string())
            .collect()
    })
}
pub fn flows_trip_vehicle_spec_models() -> Vec<String> {
    contain(Vec::new(), || {
        tv::VEHICLE_SPECS
            .iter()
            .map(|r| r.model.to_string())
            .collect()
    })
}
/// [`SPEC_NUMBER_SLOTS`] numbers per row, rows in table order.
pub fn flows_trip_vehicle_spec_numbers() -> Vec<f64> {
    contain(Vec::new(), || {
        tv::VEHICLE_SPECS
            .iter()
            .flat_map(|r| {
                [
                    f64::from(r.fuel),
                    r.city_mpu,
                    r.highway_mpu,
                    r.tank_units,
                    r.height_feet,
                    nan_for_none(r.gvwr_lbs),
                    nan_for_none(r.tow_capacity_lbs),
                    nan_for_none(r.gcwr_lbs),
                    nan_for_none(r.published_max_grade_percent),
                    nan_for_none(r.top_speed_mph),
                ]
            })
            .collect()
    })
}
pub fn flows_trip_vehicle_distinct_makes() -> Vec<String> {
    contain(Vec::new(), || strings(&tv::vehicle_makes()))
}
/// Table positions (exact small integers) of the rows for `make`.
pub fn flows_trip_vehicle_spec_rows_for_make(make: &str) -> Vec<f64> {
    contain(Vec::new(), || {
        tv::vehicle_spec_rows_for_make(make)
            .into_iter()
            .filter_map(|i| u32::try_from(i).ok().map(f64::from))
            .collect()
    })
}
pub fn flows_trip_vehicle_spec_index(make: &str, model: &str) -> i32 {
    contain(-1, || position(tv::vehicle_spec_index(make, model)))
}
/// Fallback 4.5 ft, the Swift original's own answer for an empty table: a NaN
/// here would be the lower bound of a slider range.
pub fn flows_trip_vehicle_minimum_height_feet() -> f64 {
    contain(4.5, tv::minimum_height_feet)
}
pub fn flows_trip_vehicle_combined_miles_per_unit(city_mpu: f64, highway_mpu: f64) -> f64 {
    contain(f64::NAN, || {
        tv::combined_miles_per_unit(city_mpu, highway_mpu)
    })
}
pub fn flows_trip_vehicle_rated_miles_per_unit(city_mpu: f64, highway_mpu: f64) -> f64 {
    contain(f64::NAN, || tv::rated_miles_per_unit(city_mpu, highway_mpu))
}

// ---- vehicle profile: fallback NaN (false for the recommendation) ----

pub fn flows_trip_vehicle_reserve_miles() -> f64 {
    tv::RESERVE_MILES
}
pub fn flows_trip_vehicle_efficiency_factor(average_speed_mph: f64, idle_fraction: f64) -> f64 {
    contain(f64::NAN, || {
        tv::efficiency_factor(average_speed_mph, idle_fraction)
    })
}
pub fn flows_trip_vehicle_rated_range_miles(
    tank_capacity_units: f64,
    rated_miles_per_unit: f64,
) -> f64 {
    contain(f64::NAN, || {
        economy(
            tank_capacity_units,
            rated_miles_per_unit,
            0.0,
            false,
            0.0,
            false,
        )
        .rated_range_miles()
    })
}
pub fn flows_trip_vehicle_miles_per_unit_at_speed(
    tank: f64,
    rated: f64,
    city: f64,
    has_city: bool,
    highway: f64,
    has_highway: bool,
    mph: f64,
) -> f64 {
    contain(f64::NAN, || {
        economy(tank, rated, city, has_city, highway, has_highway).miles_per_unit_at_speed(mph)
    })
}
#[allow(clippy::too_many_arguments)]
pub fn flows_trip_vehicle_effective_range_miles(
    tank: f64,
    rated: f64,
    city: f64,
    has_city: bool,
    highway: f64,
    has_highway: bool,
    average_speed_mph: f64,
    idle_fraction: f64,
) -> f64 {
    contain(f64::NAN, || {
        economy(tank, rated, city, has_city, highway, has_highway)
            .effective_range_miles(average_speed_mph, idle_fraction)
    })
}
#[allow(clippy::too_many_arguments)]
pub fn flows_trip_vehicle_fuel_fraction_after(
    tank: f64,
    rated: f64,
    city: f64,
    has_city: bool,
    highway: f64,
    has_highway: bool,
    miles_since_fill: f64,
    average_speed_mph: f64,
    idle_fraction: f64,
) -> f64 {
    contain(f64::NAN, || {
        economy(tank, rated, city, has_city, highway, has_highway).fuel_fraction_after(
            miles_since_fill,
            average_speed_mph,
            idle_fraction,
        )
    })
}
#[allow(clippy::too_many_arguments)]
pub fn flows_trip_vehicle_expected_range_miles(
    tank: f64,
    rated: f64,
    city: f64,
    has_city: bool,
    highway: f64,
    has_highway: bool,
    miles_since_fill: f64,
    average_speed_mph: f64,
    idle_fraction: f64,
) -> f64 {
    contain(f64::NAN, || {
        economy(tank, rated, city, has_city, highway, has_highway).expected_range_miles(
            miles_since_fill,
            average_speed_mph,
            idle_fraction,
        )
    })
}
pub fn flows_trip_vehicle_should_recommend_fuel(
    range_remaining_miles: f64,
    miles_to_next_station: f64,
    reserve_miles: f64,
) -> bool {
    contain(false, || {
        tv::should_recommend_fuel(range_remaining_miles, miles_to_next_station, reserve_miles)
    })
}

// ---- vehicle store ----

/// Fallback false: a fault leaves the store's defaults in place.
pub fn flows_trip_vehicle_restore_driving_accepts(
    average_speed_mph: f64,
    idle_fraction: f64,
) -> bool {
    contain(false, || {
        tv::restore_driving_accepts(average_speed_mph, idle_fraction)
    })
}
/// Fallback 0, the store's own starting idle fraction.
pub fn flows_trip_vehicle_restore_driving_idle(idle_fraction: f64) -> f64 {
    contain(0.0, || tv::restore_driving_idle(idle_fraction))
}
/// The habits after one fix. Fallback: the habits passed in, unchanged.
pub fn flows_trip_vehicle_record_fix(
    miles_since_fill: f64,
    average_speed_mph: f64,
    idle_fraction: f64,
    speed_mps: f64,
    delta_meters: f64,
    towing: bool,
    towing_economy_factor: f64,
) -> TripVehicleHabits {
    let unchanged = TripVehicleHabits {
        miles_since_fill,
        average_speed_mph,
        idle_fraction,
    };
    contain(unchanged, || {
        let h = tv::record_fix(
            tv::DrivingHabits {
                miles_since_fill,
                average_speed_mph,
                idle_fraction,
            },
            speed_mps,
            delta_meters,
            towing,
            towing_economy_factor,
        );
        TripVehicleHabits {
            miles_since_fill: h.miles_since_fill,
            average_speed_mph: h.average_speed_mph,
            idle_fraction: h.idle_fraction,
        }
    })
}
#[allow(clippy::too_many_arguments)]
pub fn flows_trip_vehicle_store_expected_range_miles(
    tank: f64,
    rated: f64,
    city: f64,
    has_city: bool,
    highway: f64,
    has_highway: bool,
    miles_since_fill: f64,
    average_speed_mph: f64,
    idle_fraction: f64,
    telemetry_fuel_fraction: f64,
    has_telemetry_fuel_fraction: bool,
    towing: bool,
    towing_economy_factor: f64,
) -> f64 {
    contain(f64::NAN, || {
        tv::store_expected_range_miles(
            &economy(tank, rated, city, has_city, highway, has_highway),
            tv::DrivingHabits {
                miles_since_fill,
                average_speed_mph,
                idle_fraction,
            },
            has_telemetry_fuel_fraction.then_some(telemetry_fuel_fraction),
            towing,
            towing_economy_factor,
        )
    })
}

// ---- EPA class specs ----

/// Fallback: the ladder's own sedan-shaped default (14.5 gal, 4.7 ft, no
/// ratings), so a fault never puts NaN into the editor's sliders.
pub fn flows_trip_vehicle_epa_class_physical(vclass: &str) -> TripVehicleClassPhysical {
    let encode = |p: tv::ClassPhysical| TripVehicleClassPhysical {
        tank: p.tank,
        height: p.height,
        gvwr: nan_for_none(p.gvwr),
        tow_capacity: nan_for_none(p.tow_capacity),
    };
    let sedan = encode(tv::ClassPhysical {
        tank: 14.5,
        height: 4.7,
        gvwr: None,
        tow_capacity: None,
    });
    contain(sedan, || encode(tv::epa_class_physical(vclass)))
}
/// Fallback: the tank as given, unclamped.
pub fn flows_trip_vehicle_epa_validated_tank(tank: f64, combined_mpu: f64) -> f64 {
    contain(tank, || tv::epa_validated_tank(tank, combined_mpu))
}
/// Fallback 0 (gas), the ladder's own default.
pub fn flows_trip_vehicle_epa_fuel_type_code(fuel: &str) -> u8 {
    contain(tv::FUEL_GAS, || tv::epa_fuel_type(fuel))
}
