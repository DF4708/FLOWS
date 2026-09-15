// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::forecast`: the forecast predictors.
//! Functions are named `flows_forecast_…`. Each optional forecast value
//! crosses as a value plus a `has_` flag; the family scores come back in
//! [`flows_forecast_predictor_family_names`] order.
//!
//! Every function is a thin forwarder through [`contain`], so a panic inside
//! the core becomes the documented fallback (no risk) instead of crossing
//! into Swift.

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        fn flows_forecast_predictor_family_names() -> Vec<String>;
        fn flows_forecast_score(
            temperature_f: f64,
            has_temperature: bool,
            wind_mph: f64,
            has_wind: bool,
            pop_percent: f64,
            has_pop: bool,
            latitude: f64,
            longitude: f64,
            elevation_meters: f64,
            has_elevation: bool,
        ) -> f64;
        fn flows_forecast_predictor_families(
            temperature_f: f64,
            has_temperature: bool,
            wind_mph: f64,
            has_wind: bool,
            pop_percent: f64,
            has_pop: bool,
            latitude: f64,
            longitude: f64,
            elevation_meters: f64,
            has_elevation: bool,
        ) -> Vec<f64>;
    }
}

use crate::contain;
use flows_core::forecast as fc;

fn conditions(
    temperature_f: f64,
    has_temperature: bool,
    wind_mph: f64,
    has_wind: bool,
    pop_percent: f64,
    has_pop: bool,
) -> fc::Conditions {
    fc::Conditions {
        temperature_f: has_temperature.then_some(temperature_f),
        wind_mph: has_wind.then_some(wind_mph),
        pop_percent: has_pop.then_some(pop_percent),
    }
}

pub fn flows_forecast_predictor_family_names() -> Vec<String> {
    fc::PREDICTOR_FAMILY_NAMES
        .iter()
        .map(|n| (*n).to_string())
        .collect()
}

#[allow(clippy::too_many_arguments)]
pub fn flows_forecast_score(
    temperature_f: f64,
    has_temperature: bool,
    wind_mph: f64,
    has_wind: bool,
    pop_percent: f64,
    has_pop: bool,
    latitude: f64,
    longitude: f64,
    elevation_meters: f64,
    has_elevation: bool,
) -> f64 {
    contain(0.0, || {
        fc::forecast_score(
            &conditions(
                temperature_f,
                has_temperature,
                wind_mph,
                has_wind,
                pop_percent,
                has_pop,
            ),
            latitude,
            longitude,
            has_elevation.then_some(elevation_meters),
        )
    })
}

#[allow(clippy::too_many_arguments)]
pub fn flows_forecast_predictor_families(
    temperature_f: f64,
    has_temperature: bool,
    wind_mph: f64,
    has_wind: bool,
    pop_percent: f64,
    has_pop: bool,
    latitude: f64,
    longitude: f64,
    elevation_meters: f64,
    has_elevation: bool,
) -> Vec<f64> {
    contain(vec![0.0; 6], || {
        fc::predictor_families(
            &conditions(
                temperature_f,
                has_temperature,
                wind_mph,
                has_wind,
                pop_percent,
                has_pop,
            ),
            latitude,
            longitude,
            has_elevation.then_some(elevation_meters),
        )
        .to_vec()
    })
}
