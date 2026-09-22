// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Risk equations, family tables, and the polyline decoder, as Swift calls
//! them. Implementations live in `flows-core`; this file only crosses.
//!
//! Boundary encodings, chosen so nothing Swift sends can be misread:
//! - a family→score dictionary for the per-sample combine is a dense
//!   `&[f64]` with one slot per `flows_core::families::dense_family`, NaN for
//!   absent — no strings cross on the hot path;
//! - a dictionary whose keys may be arbitrary (naming, noisy-OR) is the keys
//!   joined by U+001F plus a parallel `&[f64]`; the result is a POSITION in
//!   that list, so no string crosses back;
//! - an optional `f64` is a value plus a `has_` flag.
//!
//! A length or count mismatch is rejected with the documented sentinel, never
//! guessed around.

use crate::contain;
use flows_core::families as fam;
use flows_core::{polyline, risk, scoring};

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        fn flows_risk_green_min() -> f64;
        fn flows_risk_yellow_min() -> f64;
        fn flows_risk_red_min() -> f64;
        fn flows_secondary_ceiling() -> f64;
        fn flows_acute_nudge() -> f64;
        fn flows_primary_families() -> Vec<String>;
        fn flows_secondary_families() -> Vec<String>;
        fn flows_acute_families() -> Vec<String>;
        fn flows_weighted_family_names() -> Vec<String>;
        fn flows_weighted_family_values() -> Vec<f64>;

        fn flows_risk_band_code(score: f64) -> u8;
        fn flows_piecewise_score(value: f64, low: f64, medium: f64, high: f64) -> f64;
        fn flows_temperature_risk(
            temp_f: f64,
            comfort_low_f: f64,
            comfort_high_f: f64,
            record_low_f: f64,
            record_high_f: f64,
        ) -> f64;
        fn flows_temperature_anomalous(
            temp_f: f64,
            comfort_low_f: f64,
            comfort_high_f: f64,
            record_low_f: f64,
            record_high_f: f64,
        ) -> bool;
        fn flows_wind_risk(mph: f64) -> f64;
        fn flows_pop_risk(pct: f64) -> f64;
        fn flows_forecast_composite(temp: f64, wind: f64, pop: f64) -> f64;

        fn flows_noisy_or_named(names: &str, scores: &[f64]) -> f64;
        fn flows_realized_risk_dense(scores: &[f64]) -> f64;
        fn flows_flood_elevation_multiplier(
            sample_elevation: f64,
            has_sample_elevation: bool,
            local_min_elevation: f64,
            has_local_min_elevation: bool,
            qpf_inches: f64,
            has_qpf_inches: bool,
            supporting_evidence: f64,
        ) -> f64;
        fn flows_ranking_risk(
            band: f64,
            zip_exposure: f64,
            seasonal_prior: f64,
            prior_confidence: f64,
        ) -> f64;
        fn flows_alert_family_index(event: &str) -> i32;
        fn flows_peak_family_position(names: &str, scores: &[f64], floor: f64) -> i32;
        fn flows_dominant_family_position(names: &str, scores: &[f64], floor: f64) -> i32;
        fn flows_displayed_band(weighted: f64, peak: f64) -> f64;
        fn flows_ahead_display_risk(
            sample_risks: &[f64],
            seg_lengths: &[f64],
            along_meters: f64,
        ) -> f64;

        fn flows_decode_polyline_lonlat(bytes: &[u8]) -> Vec<f64>;
    }
}

const NAME_SEPARATOR: char = '\u{1f}';

/// Split U+001F-joined names; `None` unless the count matches `expected`.
/// An empty string with zero expected names is the empty list.
fn split_names(names: &str, expected: usize) -> Option<Vec<&str>> {
    if expected == 0 {
        return names.is_empty().then(Vec::new);
    }
    let v: Vec<&str> = names.split(NAME_SEPARATOR).collect();
    (v.len() == expected).then_some(v)
}

fn to_strings(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| (*s).to_string()).collect()
}

fn position_of(names: &[&str], winner: Option<&str>) -> i32 {
    // Names are unique (they come from a dictionary), and the winner is one
    // of them by construction; compare by address so equal strings in a
    // malformed call cannot be confused.
    winner
        .and_then(|w| {
            names
                .iter()
                .position(|n| std::ptr::eq(n.as_ptr(), w.as_ptr()) && n.len() == w.len())
        })
        .and_then(|p| i32::try_from(p).ok())
        .unwrap_or(-1)
}

// ---- constants and tables: fallbacks are NaN / empty ----

pub fn flows_risk_green_min() -> f64 {
    risk::RISK_GREEN_MIN
}
pub fn flows_risk_yellow_min() -> f64 {
    risk::RISK_YELLOW_MIN
}
pub fn flows_risk_red_min() -> f64 {
    risk::RISK_RED_MIN
}
pub fn flows_secondary_ceiling() -> f64 {
    fam::SECONDARY_CEILING
}
pub fn flows_acute_nudge() -> f64 {
    fam::ACUTE_NUDGE
}
pub fn flows_primary_families() -> Vec<String> {
    contain(Vec::new(), || to_strings(fam::PRIMARY_FAMILIES))
}
pub fn flows_secondary_families() -> Vec<String> {
    contain(Vec::new(), || to_strings(fam::SECONDARY_FAMILIES))
}
pub fn flows_acute_families() -> Vec<String> {
    contain(Vec::new(), || to_strings(fam::ACUTE_FAMILIES))
}
pub fn flows_weighted_family_names() -> Vec<String> {
    contain(Vec::new(), || {
        fam::FAMILY_WEIGHTS
            .iter()
            .map(|(n, _)| (*n).to_string())
            .collect()
    })
}
pub fn flows_weighted_family_values() -> Vec<f64> {
    contain(Vec::new(), || {
        fam::FAMILY_WEIGHTS.iter().map(|(_, w)| *w).collect()
    })
}

// ---- scalar equations: fallback NaN (false for the anomaly gate) ----

/// 0 clear, 1 green, 2 yellow, 3 red.
pub fn flows_risk_band_code(score: f64) -> u8 {
    contain(0, || match risk::risk_band(score) {
        risk::RiskBand::Transparent => 0,
        risk::RiskBand::Green => 1,
        risk::RiskBand::Yellow => 2,
        risk::RiskBand::Red => 3,
    })
}
pub fn flows_piecewise_score(value: f64, low: f64, medium: f64, high: f64) -> f64 {
    contain(f64::NAN, || {
        scoring::piecewise_score(value, low, medium, high)
    })
}
pub fn flows_temperature_risk(t: f64, cl: f64, ch: f64, rl: f64, rh: f64) -> f64 {
    contain(f64::NAN, || scoring::temperature_risk(t, cl, ch, rl, rh))
}
pub fn flows_temperature_anomalous(t: f64, cl: f64, ch: f64, rl: f64, rh: f64) -> bool {
    contain(false, || scoring::temperature_anomalous(t, cl, ch, rl, rh))
}
pub fn flows_wind_risk(mph: f64) -> f64 {
    contain(f64::NAN, || scoring::wind_risk(mph))
}
pub fn flows_pop_risk(pct: f64) -> f64 {
    contain(f64::NAN, || scoring::pop_risk(pct))
}
pub fn flows_forecast_composite(temp: f64, wind: f64, pop: f64) -> f64 {
    contain(f64::NAN, || scoring::forecast_composite(temp, wind, pop))
}

// ---- family combines ----

/// Weighted noisy-OR over `names[i]` / `scores[i]` in list order. NaN when the
/// name count does not match the scores.
pub fn flows_noisy_or_named(names: &str, scores: &[f64]) -> f64 {
    contain(f64::NAN, || match split_names(names, scores.len()) {
        Some(ns) => {
            let pairs: Vec<(&str, f64)> = ns.into_iter().zip(scores.iter().copied()).collect();
            fam::noisy_or(&pairs)
        }
        None => f64::NAN,
    })
}

/// Realized risk over the dense encoding. NaN when the slice is the wrong length.
pub fn flows_realized_risk_dense(scores: &[f64]) -> f64 {
    contain(f64::NAN, || {
        fam::realized_risk_dense(scores).unwrap_or(f64::NAN)
    })
}

pub fn flows_flood_elevation_multiplier(
    sample_elevation: f64,
    has_sample_elevation: bool,
    local_min_elevation: f64,
    has_local_min_elevation: bool,
    qpf_inches: f64,
    has_qpf_inches: bool,
    supporting_evidence: f64,
) -> f64 {
    contain(f64::NAN, || {
        fam::flood_elevation_multiplier(
            has_sample_elevation.then_some(sample_elevation),
            has_local_min_elevation.then_some(local_min_elevation),
            has_qpf_inches.then_some(qpf_inches),
            supporting_evidence,
        )
    })
}

pub fn flows_ranking_risk(band: f64, zip: f64, prior: f64, confidence: f64) -> f64 {
    contain(f64::NAN, || fam::ranking_risk(band, zip, prior, confidence))
}

/// Dense slot of the family an alert event feeds, or -1 when none maps.
pub fn flows_alert_family_index(event: &str) -> i32 {
    contain(-1, || {
        fam::alert_family(event)
            .and_then(fam::dense_family_index)
            .and_then(|i| i32::try_from(i).ok())
            .unwrap_or(-1)
    })
}

/// Position of the peak family in the joined list, or -1 (none, or a count mismatch).
pub fn flows_peak_family_position(names: &str, scores: &[f64], floor: f64) -> i32 {
    contain(-1, || match split_names(names, scores.len()) {
        Some(ns) => {
            let pairs: Vec<(&str, f64)> = ns.iter().copied().zip(scores.iter().copied()).collect();
            position_of(&ns, fam::peak_family(&pairs, floor))
        }
        None => -1,
    })
}

/// Position of the family that names an area, or -1 (none, or a count mismatch).
pub fn flows_dominant_family_position(names: &str, scores: &[f64], floor: f64) -> i32 {
    contain(-1, || match split_names(names, scores.len()) {
        Some(ns) => {
            let pairs: Vec<(&str, f64)> = ns.iter().copied().zip(scores.iter().copied()).collect();
            position_of(&ns, fam::dominant_family(&pairs, floor))
        }
        None => -1,
    })
}

pub fn flows_displayed_band(weighted: f64, peak: f64) -> f64 {
    contain(f64::NAN, || fam::displayed_band(weighted, peak))
}

/// The displayed risk of the part of a leg still ahead, from its check points
/// and the stretches between them (one fewer); NaN when there is
/// none (nothing ahead, mismatched lists, a value that is not a number).
pub fn flows_ahead_display_risk(
    sample_risks: &[f64],
    seg_lengths: &[f64],
    along_meters: f64,
) -> f64 {
    contain(f64::NAN, || {
        fam::ahead_display_risk(sample_risks, seg_lengths, along_meters).unwrap_or(f64::NAN)
    })
}

/// Interleaved `[lon, lat, …]` degrees; empty on containment.
pub fn flows_decode_polyline_lonlat(bytes: &[u8]) -> Vec<f64> {
    contain(Vec::new(), || polyline::decode_lonlat(bytes))
}
