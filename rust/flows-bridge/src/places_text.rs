// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::places_text`: brand knowledge, cost tiers
//! and showers, fuel estimates and the AAA row, lane tags, camera tags.
//! Functions are named `flows_places_text_…`.
//!
//! Text crosses as Swift `String`s (`&str` here; the generated glue reads the
//! UTF-8 in place). An absent optional argument is a value plus a `has_`
//! flag or, for a tag the Swift read with `?? ""`, the empty string. Optional
//! answers are a code with a sentinel (0 for no tier, -1 for no index, "" for
//! no site or code) or [`ffi::FlowsPlacesTextOptional`]. Enumerations are the
//! codes `places_text` documents. Lanes cross flat: each lane's turn codes
//! followed by -1.
//!
//! Every function is a thin forwarder through [`contain`], so a panic inside
//! the core becomes the documented fallback instead of crossing into Swift.

#[swift_bridge::bridge]
mod ffi {
    // An optional number: `value` is meaningful only when `is_some` is 1.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsPlacesTextOptional {
        is_some: f64,
        value: f64,
    }
    // The AAA row's prices; `has` 0 when the page did not parse.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsPlacesTextPrices {
        has: f64,
        gas: f64,
        diesel: f64,
    }

    extern "Rust" {
        // ---- BrandKnowledge ----
        fn flows_places_text_cost_tier(name: &str) -> i64;
        fn flows_places_text_website(name: &str) -> String;
        fn flows_places_text_gym_has_showers(name: &str) -> i32;
        fn flows_places_text_parking_fee(name: &str) -> i32;
        fn flows_places_text_shelter_type(name: &str, query: &str) -> u8;
        fn flows_places_text_is_shelter_noise(name: &str) -> bool;
        fn flows_places_text_asked_name_matches(asked: &str, name: &str) -> bool;

        // ---- RatingsAndCost ----
        fn flows_places_text_country_for_coordinate(latitude: f64, longitude: f64) -> u8;
        fn flows_places_text_check_breakpoints(country: u8) -> Vec<f64>;
        fn flows_places_text_cost_tier_for_check(average_check: f64, country: u8) -> i64;
        fn flows_places_text_estimated_nightly(cost_tier: i64, has_tier: bool) -> f64;
        fn flows_places_text_yelp_cost_tier(price: &str, rating: f64, has_rating: bool) -> i64;

        // ---- ShowerAvailability ----
        fn flows_places_text_shower_for_name(name: &str, has_name: bool) -> u8;
        fn flows_places_text_shower_ladder(
            name: &str,
            has_name: bool,
            has_position: bool,
            disproved: bool,
            tag: &str,
            has_tag: bool,
        ) -> u8;
        fn flows_places_text_shower_table_entry(
            lats: &[f64],
            lons: &[f64],
            latitude: f64,
            longitude: f64,
        ) -> i64;
        fn flows_places_text_city_keys(state: &str, city: &str) -> Vec<String>;
        fn flows_places_text_lowercased(text: &str) -> String;
        fn flows_places_text_uppercased(text: &str) -> String;

        // ---- FuelPrices ----
        fn flows_places_text_national_gas() -> f64;
        fn flows_places_text_national_diesel() -> f64;
        fn flows_places_text_national_kwh() -> f64;
        fn flows_places_text_mxn_per_usd() -> f64;
        fn flows_places_text_liters_per_gallon() -> f64;
        fn flows_places_text_usd_per_gallon(mxn_per_liter: f64) -> f64;
        fn flows_places_text_mexico_estimate(fuel: u8) -> f64;
        fn flows_places_text_fuel_state_code(state: &str, has_state: bool) -> String;
        fn flows_places_text_fuel_estimate(
            fuel: u8,
            code: &str,
            has_code: bool,
            live_gas: f64,
            live_diesel: f64,
            has_live: bool,
        ) -> f64;
        fn flows_places_text_parse_current_avg(html: &str) -> FlowsPlacesTextPrices;
        fn flows_places_text_state_names() -> Vec<String>;
        fn flows_places_text_state_codes() -> Vec<String>;

        // ---- LaneData ----
        fn flows_places_text_parse_turn_lanes(turn_lanes: &str) -> Vec<i64>;
        fn flows_places_text_turn_side(turn: u8) -> u8;
        fn flows_places_text_lane_allows(turns: &[i64], side: u8) -> bool;
        fn flows_places_text_recommended_lanes(lanes_flat: &[i64], side: u8) -> Vec<i64>;

        // ---- EnforcementCameras ----
        fn flows_places_text_camera_kind(
            highway: &str,
            enforcement: &str,
            traffic_signals: &str,
            red_light_camera: &str,
        ) -> i32;
        fn flows_places_text_camera_limit_mph(
            maxspeed: &str,
            has_maxspeed: bool,
        ) -> FlowsPlacesTextOptional;
    }
}

use crate::contain;
use ffi::{FlowsPlacesTextOptional, FlowsPlacesTextPrices};
use flows_core::places_text as pt;
use flows_core::swift_text as st;

const NONE: FlowsPlacesTextOptional = FlowsPlacesTextOptional {
    is_some: 0.0,
    value: 0.0,
};
const NO_PRICES: FlowsPlacesTextPrices = FlowsPlacesTextPrices {
    has: 0.0,
    gas: 0.0,
    diesel: 0.0,
};

fn option(value: &str, has: bool) -> Option<&str> {
    has.then_some(value)
}
fn tri(v: Option<bool>) -> i32 {
    v.map_or(-1, i32::from)
}

// ---- BrandKnowledge: an unknown brand answers nothing ----

pub fn flows_places_text_cost_tier(name: &str) -> i64 {
    contain(0, || pt::cost_tier(name).unwrap_or(0))
}
pub fn flows_places_text_website(name: &str) -> String {
    contain(String::new(), || {
        pt::website(name).unwrap_or("").to_string()
    })
}
pub fn flows_places_text_gym_has_showers(name: &str) -> i32 {
    contain(-1, || tri(pt::gym_has_showers(name)))
}
pub fn flows_places_text_parking_fee(name: &str) -> i32 {
    contain(-1, || tri(pt::parking_fee(name)))
}
pub fn flows_places_text_shelter_type(name: &str, query: &str) -> u8 {
    contain(4, || pt::shelter_type(name, query))
}
pub fn flows_places_text_is_shelter_noise(name: &str) -> bool {
    contain(false, || pt::is_shelter_noise(name))
}
pub fn flows_places_text_asked_name_matches(asked: &str, name: &str) -> bool {
    contain(false, || pt::asked_name_matches(asked, name))
}

// ---- RatingsAndCost: the US and the mid-market answers are the fallbacks ----

pub fn flows_places_text_country_for_coordinate(latitude: f64, longitude: f64) -> u8 {
    contain(0, || pt::country_for_coordinate(latitude, longitude))
}
pub fn flows_places_text_check_breakpoints(country: u8) -> Vec<f64> {
    contain(Vec::new(), || pt::check_breakpoints(country).to_vec())
}
pub fn flows_places_text_cost_tier_for_check(average_check: f64, country: u8) -> i64 {
    contain(5, || pt::cost_tier_for_check(average_check, country))
}
pub fn flows_places_text_estimated_nightly(cost_tier: i64, has_tier: bool) -> f64 {
    contain(120.0, || {
        pt::estimated_nightly(has_tier.then_some(cost_tier))
    })
}
pub fn flows_places_text_yelp_cost_tier(price: &str, rating: f64, has_rating: bool) -> i64 {
    contain(1, || {
        pt::yelp_cost_tier(price, has_rating.then_some(rating))
    })
}

// ---- ShowerAvailability: unknown is the fallback ----

pub fn flows_places_text_shower_for_name(name: &str, has_name: bool) -> u8 {
    contain(4, || pt::shower_for_name(option(name, has_name)))
}
pub fn flows_places_text_shower_ladder(
    name: &str,
    has_name: bool,
    has_position: bool,
    disproved: bool,
    tag: &str,
    has_tag: bool,
) -> u8 {
    contain(4, || {
        pt::shower_ladder(
            option(name, has_name),
            has_position,
            disproved,
            option(tag, has_tag),
        )
    })
}
pub fn flows_places_text_shower_table_entry(
    lats: &[f64],
    lons: &[f64],
    latitude: f64,
    longitude: f64,
) -> i64 {
    contain(-1, || {
        pt::shower_table_entry(lats, lons, latitude, longitude)
            .and_then(|i| i64::try_from(i).ok())
            .unwrap_or(-1)
    })
}
pub fn flows_places_text_city_keys(state: &str, city: &str) -> Vec<String> {
    contain(Vec::new(), || {
        let (hyphenated, spelled) = pt::city_keys(state, city);
        vec![hyphenated, spelled]
    })
}
pub fn flows_places_text_lowercased(text: &str) -> String {
    contain(text.to_string(), || st::lowercased(text))
}
pub fn flows_places_text_uppercased(text: &str) -> String {
    contain(text.to_string(), || st::uppercased(text))
}

// ---- FuelPrices: the national baseline is the fallback ----

pub fn flows_places_text_national_gas() -> f64 {
    pt::NATIONAL_GAS
}
pub fn flows_places_text_national_diesel() -> f64 {
    pt::NATIONAL_DIESEL
}
pub fn flows_places_text_national_kwh() -> f64 {
    pt::NATIONAL_KWH
}
pub fn flows_places_text_mxn_per_usd() -> f64 {
    pt::MXN_PER_USD
}
pub fn flows_places_text_liters_per_gallon() -> f64 {
    pt::LITERS_PER_GALLON
}
pub fn flows_places_text_usd_per_gallon(mxn_per_liter: f64) -> f64 {
    contain(f64::NAN, || pt::usd_per_gallon(mxn_per_liter))
}
pub fn flows_places_text_mexico_estimate(fuel: u8) -> f64 {
    contain(pt::NATIONAL_GAS, || pt::mexico_estimate(fuel))
}
pub fn flows_places_text_fuel_state_code(state: &str, has_state: bool) -> String {
    contain(String::new(), || {
        pt::fuel_state_code(option(state, has_state)).unwrap_or_default()
    })
}
pub fn flows_places_text_fuel_estimate(
    fuel: u8,
    code: &str,
    has_code: bool,
    live_gas: f64,
    live_diesel: f64,
    has_live: bool,
) -> f64 {
    contain(pt::NATIONAL_GAS, || {
        pt::fuel_estimate(
            fuel,
            option(code, has_code),
            has_live.then_some((live_gas, live_diesel)),
        )
    })
}
/// The full state names, lowercase, parallel to [`flows_places_text_state_codes`].
pub fn flows_places_text_state_names() -> Vec<String> {
    pt::STATE_NAMES
        .iter()
        .map(|(n, _)| (*n).to_string())
        .collect()
}
pub fn flows_places_text_state_codes() -> Vec<String> {
    pt::STATE_NAMES
        .iter()
        .map(|(_, c)| (*c).to_string())
        .collect()
}
pub fn flows_places_text_parse_current_avg(html: &str) -> FlowsPlacesTextPrices {
    contain(NO_PRICES, || match pt::parse_current_avg(html) {
        Some((gas, diesel)) => FlowsPlacesTextPrices {
            has: 1.0,
            gas,
            diesel,
        },
        None => NO_PRICES,
    })
}

// ---- LaneData: no lanes is the fallback ----

pub fn flows_places_text_parse_turn_lanes(turn_lanes: &str) -> Vec<i64> {
    contain(Vec::new(), || {
        let mut flat = Vec::new();
        for lane in pt::parse_turn_lanes(turn_lanes) {
            flat.extend(lane.iter().map(|&t| i64::from(t)));
            flat.push(-1);
        }
        flat
    })
}
pub fn flows_places_text_turn_side(turn: u8) -> u8 {
    contain(pt::SIDE_NONE, || pt::turn_side(turn))
}
/// Turn codes from a flat lane, dropping anything that is not a code.
fn turn_codes(flat: &[i64]) -> Vec<u8> {
    flat.iter().filter_map(|&t| u8::try_from(t).ok()).collect()
}
/// Lanes from the flat form: each lane's codes end with -1.
fn lanes(flat: &[i64]) -> Vec<Vec<u8>> {
    flat.split(|&t| t == -1)
        .filter(|lane| !lane.is_empty())
        .map(turn_codes)
        .collect()
}
pub fn flows_places_text_lane_allows(turns: &[i64], side: u8) -> bool {
    contain(false, || pt::lane_allows(&turn_codes(turns), side))
}
pub fn flows_places_text_recommended_lanes(lanes_flat: &[i64], side: u8) -> Vec<i64> {
    contain(Vec::new(), || {
        pt::recommended_lanes(&lanes(lanes_flat), side)
            .into_iter()
            .filter_map(|i| i64::try_from(i).ok())
            .collect()
    })
}

// ---- EnforcementCameras: no camera and no limit are the fallbacks ----

pub fn flows_places_text_camera_kind(
    highway: &str,
    enforcement: &str,
    traffic_signals: &str,
    red_light_camera: &str,
) -> i32 {
    contain(-1, || {
        pt::camera_kind(
            Some(highway),
            Some(enforcement),
            Some(traffic_signals),
            Some(red_light_camera),
        )
        .map_or(-1, i32::from)
    })
}
pub fn flows_places_text_camera_limit_mph(
    maxspeed: &str,
    has_maxspeed: bool,
) -> FlowsPlacesTextOptional {
    contain(NONE, || {
        match pt::camera_limit_mph(option(maxspeed, has_maxspeed)) {
            Some(value) => FlowsPlacesTextOptional {
                is_some: 1.0,
                value,
            },
            None => NONE,
        }
    })
}
