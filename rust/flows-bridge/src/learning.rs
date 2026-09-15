// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::learning`: the everyday radius, the
//! traffic-delay and road-efficiency models, buffer and refuel learning, the
//! personal ETA correction and destination prediction. Implementations live in
//! `flows-core`; this file only crosses.
//!
//! Boundary encodings, chosen so nothing Swift sends can be misread:
//! - an optional argument is a value plus a `has_` flag, never NaN; an
//!   optional number comes back as [`ffi::FlowsLearningOptional`] (`is_some`
//!   1 or 0), because a present answer can itself be NaN;
//! - a learned cell crosses as its fields; an optional cell as the fields plus
//!   a `has_` flag; an updated cell comes back with `has` 0 where the Swift
//!   trapped (a count at `Int.max`);
//! - a decay is a plan: `apply` (1 or 0), the factor, and the store's
//!   `lastDecay` afterwards — the Swift facade scales its own cells;
//! - names cross joined by U+001F (never part of a place name); positions
//!   come back as `f64` lists (every position is a small integer) or a single
//!   `i32`, -1 for none;
//! - destinations come back as flat `[index, score, reason code]` triples;
//!   the reason's words are Swift's;
//! - a fuel or weather kind is its code, the Swift `allCases` order.
//!
//! Every function is a pure transform, safe from any thread. Slices are never
//! empty when they cross: each Swift facade answers the empty case itself.

use crate::contain;
use ffi::{
    FlowsLearningCell, FlowsLearningCellUpdate, FlowsLearningDecay, FlowsLearningEta,
    FlowsLearningOptional,
};
use flows_core::learning as lr;

/// Names cross joined by this byte, which no place or family name contains.
const JOIN: char = '\u{1F}';

#[swift_bridge::bridge]
mod ffi {
    // (swift-bridge 0.1.59 rejects doc attributes on shared structs, so these
    // are plain comments.)
    //
    // An optional number: `value` is meaningful only when `is_some` is 1.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsLearningOptional {
        is_some: f64,
        value: f64,
    }
    // A learned cell: the traffic model's (weighted_sum, weight, count) or the
    // efficiency model's (weighted_sum, weight, miles) — `count` carries
    // whichever third field the model keeps.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsLearningCell {
        weighted_sum: f64,
        weight: f64,
        count: f64,
    }
    // An updated cell; `has` 0 where the Swift trapped and the observation is
    // dropped.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsLearningCellUpdate {
        has: f64,
        weighted_sum: f64,
        weight: f64,
        count: f64,
    }
    // What one decay(to:) does: scale every cell by `factor` when `apply` is
    // 1; `last_decay` is the store's stamp afterwards.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsLearningDecay {
        apply: f64,
        factor: f64,
        last_decay: f64,
    }
    // The ETA correction after one arrival; `has` 0 when the arrival was
    // rejected (the profile is unchanged).
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsLearningEta {
        has: f64,
        log_ratio: f64,
        samples: i64,
    }

    extern "Rust" {
        // ---- everyday radius ----
        fn flows_learning_everyday_default_miles() -> f64;
        fn flows_learning_everyday_floor_miles() -> f64;
        fn flows_learning_everyday_hard_cap_miles() -> f64;
        fn flows_learning_everyday_min_trips_for_radius() -> i64;
        fn flows_learning_everyday_trip_window() -> i64;
        fn flows_learning_everyday_max_places_per_category() -> i64;
        fn flows_learning_everyday_feature_index_space() -> i64;
        fn flows_learning_everyday_feature_count() -> i64;
        fn flows_learning_everyday_quantile(values: &[f64], q: f64) -> FlowsLearningOptional;
        fn flows_learning_everyday_radius_miles(trip_miles: &[f64]) -> f64;
        fn flows_learning_everyday_mean_trip_miles(trip_miles: &[f64]) -> FlowsLearningOptional;
        fn flows_learning_everyday_trip_miles_sd(trip_miles: &[f64]) -> FlowsLearningOptional;
        fn flows_learning_everyday_miles(a_lat: f64, a_lon: f64, b_lat: f64, b_lon: f64) -> f64;
        fn flows_learning_everyday_accepts_trip(miles: f64) -> bool;
        fn flows_learning_everyday_hour_bucket(hour: i64) -> i64;
        fn flows_learning_everyday_feature_index(raw: &str) -> i32;
        fn flows_learning_everyday_features(
            hour_bucket: i64,
            weekend: bool,
            start_lat: f64,
            start_lon: f64,
            place_lat: f64,
            place_lon: f64,
            feature_index: i64,
        ) -> Vec<f64>;
        fn flows_learning_everyday_ranked_order(
            uses: &[i64],
            seen: &[i64],
            last_used: &[f64],
            names_joined: &str,
        ) -> Vec<f64>;
        fn flows_learning_everyday_evict_index(
            uses: &[i64],
            seen: &[i64],
            last_used: &[f64],
        ) -> i32;

        // ---- decay shared by the traffic and efficiency models ----
        fn flows_learning_decay_plan(
            last_decay: f64,
            now: f64,
            half_life_seconds: f64,
        ) -> FlowsLearningDecay;

        // ---- traffic delay ----
        fn flows_learning_traffic_half_life_seconds() -> f64;
        fn flows_learning_traffic_confident_after() -> i64;
        fn flows_learning_traffic_max_factor() -> f64;
        fn flows_learning_traffic_min_factor() -> f64;
        fn flows_learning_traffic_weather_names() -> Vec<String>;
        fn flows_learning_traffic_weather_from_family(family: &str, has_family: bool) -> u8;
        fn flows_learning_road_class_is_highway(average_mph: f64) -> bool;
        fn flows_learning_delay_cell_mean(weighted_sum: f64, weight: f64) -> f64;
        fn flows_learning_traffic_accepts(predicted_seconds: f64, actual_seconds: f64) -> bool;
        fn flows_learning_traffic_add(
            weighted_sum: f64,
            weight: f64,
            count: i64,
            predicted_seconds: f64,
            actual_seconds: f64,
        ) -> FlowsLearningCellUpdate;
        fn flows_learning_traffic_factor(
            is_highway: bool,
            local: FlowsLearningCell,
            has_local: bool,
            pooled: FlowsLearningCell,
            has_pooled: bool,
        ) -> f64;
        fn flows_learning_traffic_adjusted_seconds(
            router_seconds: f64,
            is_highway: bool,
            local: FlowsLearningCell,
            has_local: bool,
            pooled: FlowsLearningCell,
            has_pooled: bool,
        ) -> f64;
        fn flows_learning_traffic_delay_minutes(
            router_seconds: f64,
            is_highway: bool,
            local: FlowsLearningCell,
            has_local: bool,
            pooled: FlowsLearningCell,
            has_pooled: bool,
        ) -> FlowsLearningOptional;
        fn flows_learning_traffic_is_confident(count: i64) -> bool;

        // ---- road efficiency ----
        fn flows_learning_efficiency_half_life_seconds() -> f64;
        fn flows_learning_efficiency_confident_miles() -> f64;
        fn flows_learning_efficiency_min_ratio() -> f64;
        fn flows_learning_efficiency_max_ratio() -> f64;
        fn flows_learning_efficiency_cell_mean(weighted_sum: f64, weight: f64) -> f64;
        fn flows_learning_efficiency_accepts(miles_driven: f64, units_burned: f64) -> bool;
        fn flows_learning_efficiency_add(
            weighted_sum: f64,
            weight: f64,
            miles: f64,
            miles_driven: f64,
            units_burned: f64,
        ) -> FlowsLearningCell;
        fn flows_learning_efficiency_economy(
            rated_miles_per_unit: f64,
            is_highway: bool,
            local: FlowsLearningCell,
            has_local: bool,
            pooled: FlowsLearningCell,
            has_pooled: bool,
        ) -> f64;
        fn flows_learning_efficiency_is_confident(miles: f64) -> bool;

        // ---- streaming buffer depth ----
        fn flows_learning_buffer_alpha() -> f64;
        fn flows_learning_buffer_min_samples_to_trust() -> i64;
        fn flows_learning_buffer_plausible_low() -> f64;
        fn flows_learning_buffer_plausible_high() -> f64;
        fn flows_learning_buffer_is_usable(sample: f64) -> bool;
        fn flows_learning_buffer_updated(
            mean: f64,
            has_mean: bool,
            sample: f64,
        ) -> FlowsLearningOptional;
        fn flows_learning_buffer_wait_seconds(
            prior: f64,
            learned_mean: f64,
            has_mean: bool,
            samples: i64,
        ) -> f64;

        // ---- refuel check-ins and the stale gauge ----
        fn flows_learning_refuel_accuracy_floor() -> f64;
        fn flows_learning_refuel_window() -> i64;
        fn flows_learning_refuel_retained() -> i64;
        fn flows_learning_stale_gauge_gap_seconds() -> f64;
        fn flows_learning_refuel_accuracy(errors: &[f64]) -> f64;
        fn flows_learning_refuel_error(predicted_fraction: f64, reported_fraction: f64) -> f64;
        fn flows_learning_refuel_should_prompt(check_ins_enabled: bool, accuracy: f64) -> bool;
        fn flows_learning_gauge_went_stale(last_used: f64, has_last_used: bool, now: f64) -> bool;

        // ---- the personal ETA correction ----
        fn flows_learning_eta_min_plausible_ratio() -> f64;
        fn flows_learning_eta_max_plausible_ratio() -> f64;
        fn flows_learning_eta_min_samples_to_apply() -> i64;
        fn flows_learning_eta_min_meaningful_deviation() -> f64;
        fn flows_learning_eta_clamp_low() -> f64;
        fn flows_learning_eta_clamp_high() -> f64;
        fn flows_learning_eta_multiplier(log_ratio: f64, samples: i64) -> f64;
        fn flows_learning_eta_record(
            log_ratio: f64,
            samples: i64,
            predicted_seconds: f64,
            actual_seconds: f64,
            stopped_seconds: f64,
        ) -> FlowsLearningEta;

        // ---- destination prediction ----
        fn flows_learning_destination_recency_half_life_days() -> f64;
        fn flows_learning_destination_context_weight() -> f64;
        fn flows_learning_destination_time_weight() -> f64;
        fn flows_learning_destination_base_weight() -> f64;
        fn flows_learning_destination_reason(
            context_hits: i64,
            time_hits: i64,
            total_hits: i64,
        ) -> u8;
        fn flows_learning_destination_rank(
            context_hits: &[i64],
            time_hits: &[i64],
            total_hits: &[i64],
            last_used: &[f64],
            now: f64,
            limit: i64,
        ) -> Vec<f64>;
        fn flows_learning_destination_is_confident(
            top_score: f64,
            has_top: bool,
            minimum_evidence: i64,
        ) -> bool;
    }
}

const NONE: FlowsLearningOptional = FlowsLearningOptional {
    is_some: 0.0,
    value: f64::NAN,
};
fn optional(v: Option<f64>) -> FlowsLearningOptional {
    match v {
        Some(value) => FlowsLearningOptional {
            is_some: 1.0,
            value,
        },
        None => NONE,
    }
}
fn option(value: f64, has: bool) -> Option<f64> {
    has.then_some(value)
}
fn delay_cell(c: FlowsLearningCell, has: bool) -> Option<lr::DelayCell> {
    has.then_some(lr::DelayCell {
        weighted_sum: c.weighted_sum,
        weight: c.weight,
        // A count that is not an integer never comes from the store.
        count: c.count as i64,
    })
}
fn efficiency_cell(c: FlowsLearningCell, has: bool) -> Option<lr::EfficiencyCell> {
    has.then_some(lr::EfficiencyCell {
        weighted_sum: c.weighted_sum,
        weight: c.weight,
        miles: c.count,
    })
}
fn position(p: Option<usize>) -> i32 {
    p.and_then(|i| i32::try_from(i).ok()).unwrap_or(-1)
}
fn positions(v: Option<Vec<usize>>) -> Vec<f64> {
    v.unwrap_or_default()
        .into_iter()
        .map(|i| i as f64)
        .collect()
}

// ---- everyday radius ----

pub fn flows_learning_everyday_default_miles() -> f64 {
    lr::EVERYDAY_DEFAULT_MILES
}
pub fn flows_learning_everyday_floor_miles() -> f64 {
    lr::EVERYDAY_FLOOR_MILES
}
pub fn flows_learning_everyday_hard_cap_miles() -> f64 {
    lr::EVERYDAY_HARD_CAP_MILES
}
pub fn flows_learning_everyday_min_trips_for_radius() -> i64 {
    lr::EVERYDAY_MIN_TRIPS_FOR_RADIUS
}
pub fn flows_learning_everyday_trip_window() -> i64 {
    lr::EVERYDAY_TRIP_WINDOW
}
pub fn flows_learning_everyday_max_places_per_category() -> i64 {
    lr::EVERYDAY_MAX_PLACES_PER_CATEGORY
}
pub fn flows_learning_everyday_feature_index_space() -> i64 {
    lr::EVERYDAY_FEATURE_INDEX_SPACE
}
pub fn flows_learning_everyday_feature_count() -> i64 {
    lr::EVERYDAY_FEATURE_COUNT
}
pub fn flows_learning_everyday_quantile(values: &[f64], q: f64) -> FlowsLearningOptional {
    contain(NONE, || optional(lr::everyday_quantile(values, q)))
}
/// Fallback: the default radius, the Swift's own answer for no usable trips.
pub fn flows_learning_everyday_radius_miles(trip_miles: &[f64]) -> f64 {
    contain(lr::EVERYDAY_DEFAULT_MILES, || {
        lr::everyday_radius_miles(trip_miles)
    })
}
pub fn flows_learning_everyday_mean_trip_miles(trip_miles: &[f64]) -> FlowsLearningOptional {
    contain(NONE, || optional(lr::everyday_mean_trip_miles(trip_miles)))
}
pub fn flows_learning_everyday_trip_miles_sd(trip_miles: &[f64]) -> FlowsLearningOptional {
    contain(NONE, || optional(lr::everyday_trip_miles_sd(trip_miles)))
}
pub fn flows_learning_everyday_miles(a_lat: f64, a_lon: f64, b_lat: f64, b_lon: f64) -> f64 {
    contain(f64::NAN, || lr::everyday_miles(a_lat, a_lon, b_lat, b_lon))
}
pub fn flows_learning_everyday_accepts_trip(miles: f64) -> bool {
    contain(false, || lr::everyday_accepts_trip(miles))
}
pub fn flows_learning_everyday_hour_bucket(hour: i64) -> i64 {
    contain(0, || lr::everyday_hour_bucket(hour))
}
/// The frozen feature ordinal of a category key, -1 for a key that is not one.
pub fn flows_learning_everyday_feature_index(raw: &str) -> i32 {
    contain(-1, || {
        lr::everyday_feature_index(raw)
            .and_then(|i| i32::try_from(i).ok())
            .unwrap_or(-1)
    })
}
#[allow(clippy::too_many_arguments)]
pub fn flows_learning_everyday_features(
    hour_bucket: i64,
    weekend: bool,
    start_lat: f64,
    start_lon: f64,
    place_lat: f64,
    place_lon: f64,
    feature_index: i64,
) -> Vec<f64> {
    contain(Vec::new(), || {
        lr::everyday_features(
            hour_bucket,
            weekend,
            start_lat,
            start_lon,
            place_lat,
            place_lon,
            feature_index,
        )
        .to_vec()
    })
}
/// Display order as input positions; empty when the lists disagree in length.
pub fn flows_learning_everyday_ranked_order(
    uses: &[i64],
    seen: &[i64],
    last_used: &[f64],
    names_joined: &str,
) -> Vec<f64> {
    contain(Vec::new(), || {
        let names: Vec<&str> = names_joined.split(JOIN).collect();
        positions(lr::everyday_ranked_order(uses, seen, last_used, &names))
    })
}
pub fn flows_learning_everyday_evict_index(uses: &[i64], seen: &[i64], last_used: &[f64]) -> i32 {
    contain(-1, || {
        position(lr::everyday_evict_index(uses, seen, last_used))
    })
}

// ---- decay ----

/// Fallback: nothing decays and the stamp is kept.
pub fn flows_learning_decay_plan(
    last_decay: f64,
    now: f64,
    half_life_seconds: f64,
) -> FlowsLearningDecay {
    contain(
        FlowsLearningDecay {
            apply: 0.0,
            factor: 1.0,
            last_decay,
        },
        || {
            let p = lr::decay_plan(last_decay, now, half_life_seconds);
            FlowsLearningDecay {
                apply: if p.apply { 1.0 } else { 0.0 },
                factor: p.factor,
                last_decay: p.last_decay,
            }
        },
    )
}

// ---- traffic delay ----

pub fn flows_learning_traffic_half_life_seconds() -> f64 {
    lr::TRAFFIC_HALF_LIFE_SECONDS
}
pub fn flows_learning_traffic_confident_after() -> i64 {
    lr::TRAFFIC_CONFIDENT_AFTER
}
pub fn flows_learning_traffic_max_factor() -> f64 {
    lr::TRAFFIC_MAX_FACTOR
}
pub fn flows_learning_traffic_min_factor() -> f64 {
    lr::TRAFFIC_MIN_FACTOR
}
pub fn flows_learning_traffic_weather_names() -> Vec<String> {
    contain(Vec::new(), || {
        lr::TRAFFIC_WEATHER_NAMES
            .iter()
            .map(|n| n.to_string())
            .collect()
    })
}
/// Fallback: clear, the Swift's own answer for an unknown family.
pub fn flows_learning_traffic_weather_from_family(family: &str, has_family: bool) -> u8 {
    contain(lr::TrafficWeather::Clear as u8, || {
        lr::traffic_weather_from_family(has_family.then_some(family)) as u8
    })
}
pub fn flows_learning_road_class_is_highway(average_mph: f64) -> bool {
    contain(false, || lr::road_class_is_highway(average_mph))
}
/// Fallback 1: no adjustment.
pub fn flows_learning_delay_cell_mean(weighted_sum: f64, weight: f64) -> f64 {
    contain(1.0, || {
        lr::DelayCell {
            weighted_sum,
            weight,
            count: 0,
        }
        .mean()
    })
}
pub fn flows_learning_traffic_accepts(predicted_seconds: f64, actual_seconds: f64) -> bool {
    contain(false, || {
        lr::traffic_accepts(predicted_seconds, actual_seconds)
    })
}
pub fn flows_learning_traffic_add(
    weighted_sum: f64,
    weight: f64,
    count: i64,
    predicted_seconds: f64,
    actual_seconds: f64,
) -> FlowsLearningCellUpdate {
    let dropped = || FlowsLearningCellUpdate {
        has: 0.0,
        weighted_sum,
        weight,
        count: count as f64,
    };
    contain(dropped(), || {
        let cell = lr::DelayCell {
            weighted_sum,
            weight,
            count,
        };
        match lr::traffic_add(cell, predicted_seconds, actual_seconds) {
            Some(c) => FlowsLearningCellUpdate {
                has: 1.0,
                weighted_sum: c.weighted_sum,
                weight: c.weight,
                count: c.count as f64,
            },
            None => dropped(),
        }
    })
}
pub fn flows_learning_traffic_factor(
    is_highway: bool,
    local: FlowsLearningCell,
    has_local: bool,
    pooled: FlowsLearningCell,
    has_pooled: bool,
) -> f64 {
    contain(1.0, || {
        lr::traffic_factor(
            is_highway,
            delay_cell(local, has_local),
            delay_cell(pooled, has_pooled),
        )
    })
}
pub fn flows_learning_traffic_adjusted_seconds(
    router_seconds: f64,
    is_highway: bool,
    local: FlowsLearningCell,
    has_local: bool,
    pooled: FlowsLearningCell,
    has_pooled: bool,
) -> f64 {
    contain(router_seconds, || {
        lr::traffic_adjusted_seconds(
            router_seconds,
            is_highway,
            delay_cell(local, has_local),
            delay_cell(pooled, has_pooled),
        )
    })
}
/// Absent where the minutes are not a representable integer (the Swift crashed).
pub fn flows_learning_traffic_delay_minutes(
    router_seconds: f64,
    is_highway: bool,
    local: FlowsLearningCell,
    has_local: bool,
    pooled: FlowsLearningCell,
    has_pooled: bool,
) -> FlowsLearningOptional {
    contain(NONE, || {
        optional(
            lr::traffic_delay_minutes(
                router_seconds,
                is_highway,
                delay_cell(local, has_local),
                delay_cell(pooled, has_pooled),
            )
            .map(|m| m as f64),
        )
    })
}
pub fn flows_learning_traffic_is_confident(count: i64) -> bool {
    contain(false, || lr::traffic_is_confident(count))
}

// ---- road efficiency ----

pub fn flows_learning_efficiency_half_life_seconds() -> f64 {
    lr::EFFICIENCY_HALF_LIFE_SECONDS
}
pub fn flows_learning_efficiency_confident_miles() -> f64 {
    lr::EFFICIENCY_CONFIDENT_MILES
}
pub fn flows_learning_efficiency_min_ratio() -> f64 {
    lr::EFFICIENCY_MIN_RATIO
}
pub fn flows_learning_efficiency_max_ratio() -> f64 {
    lr::EFFICIENCY_MAX_RATIO
}
/// Fallback 0: no measured economy.
pub fn flows_learning_efficiency_cell_mean(weighted_sum: f64, weight: f64) -> f64 {
    contain(0.0, || {
        lr::EfficiencyCell {
            weighted_sum,
            weight,
            miles: 0.0,
        }
        .mean()
    })
}
pub fn flows_learning_efficiency_accepts(miles_driven: f64, units_burned: f64) -> bool {
    contain(false, || lr::efficiency_accepts(miles_driven, units_burned))
}
pub fn flows_learning_efficiency_add(
    weighted_sum: f64,
    weight: f64,
    miles: f64,
    miles_driven: f64,
    units_burned: f64,
) -> FlowsLearningCell {
    let unchanged = FlowsLearningCell {
        weighted_sum,
        weight,
        count: miles,
    };
    contain(unchanged, || {
        let c = lr::efficiency_add(
            lr::EfficiencyCell {
                weighted_sum,
                weight,
                miles,
            },
            miles_driven,
            units_burned,
        );
        FlowsLearningCell {
            weighted_sum: c.weighted_sum,
            weight: c.weight,
            count: c.miles,
        }
    })
}
pub fn flows_learning_efficiency_economy(
    rated_miles_per_unit: f64,
    is_highway: bool,
    local: FlowsLearningCell,
    has_local: bool,
    pooled: FlowsLearningCell,
    has_pooled: bool,
) -> f64 {
    contain(rated_miles_per_unit, || {
        lr::efficiency_economy(
            rated_miles_per_unit,
            is_highway,
            efficiency_cell(local, has_local),
            efficiency_cell(pooled, has_pooled),
        )
    })
}
pub fn flows_learning_efficiency_is_confident(miles: f64) -> bool {
    contain(false, || lr::efficiency_is_confident(miles))
}

// ---- streaming buffer depth ----

pub fn flows_learning_buffer_alpha() -> f64 {
    lr::BUFFER_ALPHA
}
pub fn flows_learning_buffer_min_samples_to_trust() -> i64 {
    lr::BUFFER_MIN_SAMPLES_TO_TRUST
}
pub fn flows_learning_buffer_plausible_low() -> f64 {
    lr::BUFFER_PLAUSIBLE_LOW
}
pub fn flows_learning_buffer_plausible_high() -> f64 {
    lr::BUFFER_PLAUSIBLE_HIGH
}
pub fn flows_learning_buffer_is_usable(sample: f64) -> bool {
    contain(false, || lr::buffer_is_usable(sample))
}
pub fn flows_learning_buffer_updated(
    mean: f64,
    has_mean: bool,
    sample: f64,
) -> FlowsLearningOptional {
    contain(optional(option(mean, has_mean)), || {
        optional(lr::buffer_updated(option(mean, has_mean), sample))
    })
}
pub fn flows_learning_buffer_wait_seconds(
    prior: f64,
    learned_mean: f64,
    has_mean: bool,
    samples: i64,
) -> f64 {
    contain(prior, || {
        lr::buffer_wait_seconds(prior, option(learned_mean, has_mean), samples)
    })
}

// ---- refuel check-ins and the stale gauge ----

pub fn flows_learning_refuel_accuracy_floor() -> f64 {
    lr::REFUEL_ACCURACY_FLOOR
}
pub fn flows_learning_refuel_window() -> i64 {
    lr::REFUEL_WINDOW
}
pub fn flows_learning_refuel_retained() -> i64 {
    lr::REFUEL_RETAINED
}
pub fn flows_learning_stale_gauge_gap_seconds() -> f64 {
    lr::STALE_GAUGE_GAP_SECONDS
}
pub fn flows_learning_refuel_accuracy(errors: &[f64]) -> f64 {
    contain(0.0, || lr::refuel_accuracy(errors))
}
pub fn flows_learning_refuel_error(predicted_fraction: f64, reported_fraction: f64) -> f64 {
    contain(f64::NAN, || {
        lr::refuel_error(predicted_fraction, reported_fraction)
    })
}
pub fn flows_learning_refuel_should_prompt(check_ins_enabled: bool, accuracy: f64) -> bool {
    contain(false, || {
        lr::refuel_should_prompt(check_ins_enabled, accuracy)
    })
}
pub fn flows_learning_gauge_went_stale(last_used: f64, has_last_used: bool, now: f64) -> bool {
    contain(false, || {
        lr::gauge_went_stale(option(last_used, has_last_used), now)
    })
}

// ---- the personal ETA correction ----

pub fn flows_learning_eta_min_plausible_ratio() -> f64 {
    lr::ETA_MIN_PLAUSIBLE_RATIO
}
pub fn flows_learning_eta_max_plausible_ratio() -> f64 {
    lr::ETA_MAX_PLAUSIBLE_RATIO
}
pub fn flows_learning_eta_min_samples_to_apply() -> i64 {
    lr::ETA_MIN_SAMPLES_TO_APPLY
}
pub fn flows_learning_eta_min_meaningful_deviation() -> f64 {
    lr::ETA_MIN_MEANINGFUL_DEVIATION
}
pub fn flows_learning_eta_clamp_low() -> f64 {
    lr::ETA_CLAMP_LOW
}
pub fn flows_learning_eta_clamp_high() -> f64 {
    lr::ETA_CLAMP_HIGH
}
/// Fallback 1: no correction.
pub fn flows_learning_eta_multiplier(log_ratio: f64, samples: i64) -> f64 {
    contain(1.0, || lr::eta_multiplier(log_ratio, samples))
}
pub fn flows_learning_eta_record(
    log_ratio: f64,
    samples: i64,
    predicted_seconds: f64,
    actual_seconds: f64,
    stopped_seconds: f64,
) -> FlowsLearningEta {
    let unchanged = || FlowsLearningEta {
        has: 0.0,
        log_ratio,
        samples,
    };
    contain(unchanged(), || {
        match lr::eta_record(
            lr::EtaState { log_ratio, samples },
            predicted_seconds,
            actual_seconds,
            stopped_seconds,
        ) {
            Some(s) => FlowsLearningEta {
                has: 1.0,
                log_ratio: s.log_ratio,
                samples: s.samples,
            },
            None => unchanged(),
        }
    })
}

// ---- destination prediction ----

pub fn flows_learning_destination_recency_half_life_days() -> f64 {
    lr::DESTINATION_RECENCY_HALF_LIFE_DAYS
}
pub fn flows_learning_destination_context_weight() -> f64 {
    lr::DESTINATION_CONTEXT_WEIGHT
}
pub fn flows_learning_destination_time_weight() -> f64 {
    lr::DESTINATION_TIME_WEIGHT
}
pub fn flows_learning_destination_base_weight() -> f64 {
    lr::DESTINATION_BASE_WEIGHT
}
/// Fallback 4: "recently", the weakest reason.
pub fn flows_learning_destination_reason(context_hits: i64, time_hits: i64, total_hits: i64) -> u8 {
    contain(lr::DestinationReason::Recent as u8, || {
        lr::destination_reason(context_hits, time_hits, total_hits) as u8
    })
}
/// Flat `[index, score, reason code]` triples in rank order; empty when the
/// lists disagree in length.
pub fn flows_learning_destination_rank(
    context_hits: &[i64],
    time_hits: &[i64],
    total_hits: &[i64],
    last_used: &[f64],
    now: f64,
    limit: i64,
) -> Vec<f64> {
    contain(Vec::new(), || {
        let n = context_hits.len();
        if time_hits.len() != n || total_hits.len() != n || last_used.len() != n {
            return Vec::new();
        }
        let evidence: Vec<lr::Evidence> = (0..n)
            .map(|i| lr::Evidence {
                context_hits: context_hits[i],
                time_hits: time_hits[i],
                total_hits: total_hits[i],
                last_used: last_used[i],
            })
            .collect();
        lr::destination_rank(&evidence, now, limit)
            .iter()
            .flat_map(|r| [r.index as f64, r.score, f64::from(r.reason as u8)])
            .collect()
    })
}
pub fn flows_learning_destination_is_confident(
    top_score: f64,
    has_top: bool,
    minimum_evidence: i64,
) -> bool {
    contain(false, || {
        lr::destination_is_confident(option(top_score, has_top), minimum_evidence)
    })
}
