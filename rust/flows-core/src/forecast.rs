// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The forecast predictors: a point forecast (temperature, wind, chance of
//! rain) scored against the location's climate profile —
//! `ForecastConditions.forecastScore` and `.predictorFamilies` at commit
//! a007de0. These are the SECONDARY side of the realized-risk model: what the
//! forecast makes likelier, never a realized primary.
//!
//! | here | Swift |
//! |---|---|
//! | [`forecast_score`] | `ForecastConditions.forecastScore(latitude:longitude:elevationMeters:)` |
//! | [`predictor_families`], [`PREDICTOR_FAMILY_NAMES`] | `ForecastConditions.predictorFamilies(latitude:longitude:elevationMeters:)` |
//!
//! Both read the location's profile through [`crate::climate::climate_profile`]
//! and the R equations through [`crate::scoring`]; the composition here is
//! the Swift's, with its `min(1, x)` as [`crate::fcmp::smin`] so a NaN sum
//! answers 1 as it did. Pinned by
//! `flows-bridge/tests/fixtures/swift_forecast_oracle.tsv`, whose harness
//! ran the original Swift over the same Rust equations it already called.

use crate::climate::climate_profile;
use crate::fcmp::smin;
use crate::scoring::{forecast_composite, piecewise_score, pop_risk, temperature_risk, wind_risk};

/// The point forecast a provider answered; each value may be missing.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Conditions {
    /// Air temperature, °F.
    pub temperature_f: Option<f64>,
    /// Sustained wind, mph.
    pub wind_mph: Option<f64>,
    /// Chance of precipitation, percent.
    pub pop_percent: Option<f64>,
}

/// The predictor families [`predictor_families`] answers, in order.
pub const PREDICTOR_FAMILY_NAMES: [&str; 6] =
    ["wind", "precip", "heat", "cold", "winter", "convective"];

/// The temperature assumed for the heat, cold, winter and convective tests
/// when the forecast has none.
pub const ASSUMED_TEMPERATURE_F: f64 = 70.0;
/// At or below this temperature the forecast's wind and rain read as winter.
pub const WINTER_TEMPERATURE_F: f64 = 34.0;
/// Above this temperature the forecast's rain and wind read as convective.
pub const CONVECTIVE_TEMPERATURE_F: f64 = 60.0;

/// `forecastScore`: the R composite — temperature against the profile's
/// comfort and record edges, wind and chance of rain against its thresholds
/// — with a missing value scoring 0.
///
/// Deterministic; panics: none.
#[must_use]
pub fn forecast_score(
    c: &Conditions,
    latitude: f64,
    longitude: f64,
    elevation_meters: Option<f64>,
) -> f64 {
    let band = climate_profile(latitude, longitude, elevation_meters);
    let t = c.temperature_f.map_or(0.0, |x| {
        temperature_risk(
            x,
            band.comfort_low_f,
            band.comfort_high_f,
            band.record_low_f,
            band.record_high_f,
        )
    });
    let w = c.wind_mph.map_or(0.0, |x| {
        piecewise_score(x, band.wind_low, band.wind_medium, band.wind_high)
    });
    let p = c.pop_percent.map_or(0.0, |x| {
        piecewise_score(x, band.pop_low, band.pop_medium, band.pop_high)
    });
    forecast_composite(t, w, p)
}

/// `predictorFamilies`: wind and rain on the national thresholds, heat or
/// cold from the temperature's side of the comfort band, winter (`min(1,
/// 0.2·wind + 0.8·rain)` at or below 34 °F) and convective (`min(1, 0.6·rain
/// + 0.4·wind)` above 60 °F, else 0.3·rain); a missing temperature reads as
/// 70 °F. The order is [`PREDICTOR_FAMILY_NAMES`].
///
/// Deterministic; panics: none.
#[must_use]
pub fn predictor_families(
    c: &Conditions,
    latitude: f64,
    longitude: f64,
    elevation_meters: Option<f64>,
) -> [f64; 6] {
    let band = climate_profile(latitude, longitude, elevation_meters);
    let t = c.temperature_f.map_or(0.0, |x| {
        temperature_risk(
            x,
            band.comfort_low_f,
            band.comfort_high_f,
            band.record_low_f,
            band.record_high_f,
        )
    });
    let w = c.wind_mph.map_or(0.0, wind_risk);
    let p = c.pop_percent.map_or(0.0, pop_risk);
    let temp = c.temperature_f.unwrap_or(ASSUMED_TEMPERATURE_F);
    let heat = if temp > band.comfort_high_f { t } else { 0.0 };
    let cold = if temp < band.comfort_low_f { t } else { 0.0 };
    let winter = if temp <= WINTER_TEMPERATURE_F {
        smin(1.0, 0.2 * w + 0.8 * p)
    } else {
        0.0
    };
    let convective = if temp > CONVECTIVE_TEMPERATURE_F {
        smin(1.0, 0.6 * p + 0.4 * w)
    } else {
        p * 0.3
    };
    [w, p, heat, cold, winter, convective]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_hot_windy_wet_madison_afternoon_reads_as_heat_and_storms() {
        let c = Conditions {
            temperature_f: Some(95.0),
            wind_mph: Some(30.0),
            pop_percent: Some(70.0),
        };
        let f = predictor_families(&c, 43.07, -89.4, None);
        assert!(f[2] > 0.0 && f[3] == 0.0, "heat, not cold: {f:?}");
        assert!(f[4] == 0.0 && f[5] > 0.5, "convective, not winter: {f:?}");
        assert!(forecast_score(&c, 43.07, -89.4, None) > 0.5);
    }

    #[test]
    fn a_missing_forecast_scores_nothing_and_a_nan_sum_caps_at_one() {
        let none = Conditions::default();
        assert_eq!(predictor_families(&none, 43.0, -89.0, None), [0.0; 6]);
        assert_eq!(forecast_score(&none, 43.0, -89.0, None), 0.0);
        let odd = Conditions {
            temperature_f: Some(20.0),
            wind_mph: Some(f64::NAN),
            pop_percent: Some(f64::INFINITY),
        };
        // piecewise_score answers 0 for a non-finite value, so winter is 0 here…
        assert_eq!(predictor_families(&odd, 43.0, -89.0, None)[4], 0.0);
        // …and Swift's min(1, NaN) is 1, which smin keeps.
        assert_eq!(smin(1.0, f64::NAN), 1.0);
    }
}
