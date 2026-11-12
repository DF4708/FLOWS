// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::risk_advice`, behind Swift's
//! `RiskAdvice`. Implementations live in `flows-core`; this file only
//! crosses.
//!
//! - The advice comes back as its lines; a panic answers the band's lines
//!   for a kind it does not know (still advice, never none for a risk).
//! - "May be across the border" answers yes on a panic, so both countries
//!   are asked (unknown, never a missed alert list).
//! - The other border tests answer no on a panic, which reads the point as
//!   US, the original's own default for a doubtful point.
//! - The official page comes back as its address; a panic answers an empty
//!   text, which the facade reads as no page (never the wrong agency's).

use crate::contain;
use flows_core::risk_advice as ra;

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        fn flows_risk_advice_actions(kind_name: &str, band: i64) -> Vec<String>;
        fn flows_risk_advice_is_north(lat: f64, lon: f64) -> bool;
        fn flows_risk_advice_canada_below(lat: f64, lon: f64) -> bool;
        fn flows_risk_advice_is_across(lat: f64, lon: f64) -> bool;
        fn flows_risk_advice_may_be_across(lat: f64, lon: f64) -> bool;
        fn flows_risk_advice_official_url(lat: f64, lon: f64) -> String;
        fn flows_risk_advice_southern_border_lat(lon: f64) -> f64;
    }
}

/// The band as the core numbers it; anything else is read as red, as the
/// original's `default` read any band but green and yellow.
fn band(code: i64) -> u8 {
    u8::try_from(code.clamp(0, 3)).unwrap_or(ra::RED)
}

fn lines(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| (*s).to_string()).collect()
}

pub fn flows_risk_advice_actions(kind_name: &str, band_code: i64) -> Vec<String> {
    let b = band(band_code);
    contain(lines(ra::default_actions(b)), || {
        lines(ra::actions(kind_name, b))
    })
}

pub fn flows_risk_advice_is_north(lat: f64, lon: f64) -> bool {
    contain(false, || ra::is_north_of_the_border(lat, lon))
}

pub fn flows_risk_advice_canada_below(lat: f64, lon: f64) -> bool {
    contain(false, || ra::is_canada_below_the_bands(lat, lon))
}

pub fn flows_risk_advice_is_across(lat: f64, lon: f64) -> bool {
    contain(false, || ra::is_across_the_border(lat, lon))
}

pub fn flows_risk_advice_may_be_across(lat: f64, lon: f64) -> bool {
    contain(true, || ra::may_be_across_the_border(lat, lon))
}

pub fn flows_risk_advice_official_url(lat: f64, lon: f64) -> String {
    contain(String::new(), || ra::official_url(lat, lon))
}

pub fn flows_risk_advice_southern_border_lat(lon: f64) -> f64 {
    contain(f64::NAN, || ra::us_southern_border_lat(lon))
}
