// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Piecewise hazard scoring — byte-identical port of R/scoring.R
//! `piecewise_score`, the single primitive behind ~20 hazard scorers (AQI,
//! FFG, NWPS gauges, wind, POP, UV, seismic, convective, WPC, radnet…).
//!
//! It maps a raw hazard reading through three ascending breakpoints
//! (low, medium, high) onto the shared green/yellow/red [0,1] scale, so every
//! hazard lands on one comparable axis. The band constants are the SAME
//! literals as R/global.R and Rust risk.rs — reused here, not redefined, so
//! the risk bands and the score curve can never drift apart.

use crate::risk::{RISK_GREEN_MIN, RISK_RED_MIN, RISK_YELLOW_MIN};

/// Scalar piecewise score. Byte-identical to R `piecewise_score(value, low,
/// medium, high)` including the exact comparison structure and operation order
/// (so IEEE-754 f64 results match bit-for-bit):
///   * value non-finite or <= 0            -> 0
///   * value <= low                        -> 0
///   * value <= medium (green band)        -> GREEN  + (YELLOW-GREEN)*((value-low)   / max(medium-low,  1e-9))
///   * value <= high   (yellow band)       -> YELLOW + (RED-YELLOW) *((value-medium) / max(high-medium, 1e-9))
///   * value >  high   (red extrapolation) -> min(1, RED + (1-RED)*((value-high) / max(high, 1e-9)))
///
/// Branch structure mirrors R's early returns exactly; there is no clever
/// re-association of the arithmetic, which is what preserves bit-equality.
#[inline]
pub fn piecewise_score(value: f64, low: f64, medium: f64, high: f64) -> f64 {
    if !value.is_finite() || value <= 0.0 {
        return 0.0;
    }
    // Non-finite thresholds -> 0, matching the R vector path's valid-mask
    // (vector_piecewise_score_rowwise_rimpl). Without this guard, Rust's
    // NaN-swallowing .min/.max (they return the non-NaN operand, unlike R's
    // pmin/pmax) fabricated a score of 1.0 from an NA threshold while the R
    // fallback returned 0 — same input, opposite hazard, depending on whether
    // the dylib loaded. (The R SCALAR piecewise_score errors on NA thresholds,
    // so no caller can depend on scalar-NA behaviour; the vector semantics is
    // the one contract that must match.)
    if !(low.is_finite() && medium.is_finite() && high.is_finite()) {
        return 0.0;
    }
    if value <= low {
        return 0.0;
    }
    if value <= medium {
        return RISK_GREEN_MIN
            + (RISK_YELLOW_MIN - RISK_GREEN_MIN) * ((value - low) / (medium - low).max(1e-9));
    }
    if value <= high {
        return RISK_YELLOW_MIN
            + (RISK_RED_MIN - RISK_YELLOW_MIN) * ((value - medium) / (high - medium).max(1e-9));
    }
    (RISK_RED_MIN + (1.0 - RISK_RED_MIN) * ((value - high) / high.max(1e-9))).min(1.0)
}

/// Per-element (rowwise) piecewise score — byte-identical port of R/scoring.R
/// `vector_piecewise_score_rowwise`'s inner logic, where the (low, mid, high)
/// thresholds vary PER element (spatially-varying hazard thresholds, the
/// per-zip risk builder). A row scores only if the value AND all three
/// thresholds are finite and value > 0; otherwise 0. Bands are mutually
/// exclusive (green: low<v<=mid, yellow: mid<v<=high, red: v>high), so the
/// branch order is irrelevant to the result. Same operation order as R for
/// bit-identical f64 results.
#[inline]
pub fn piecewise_score_rowwise(value: f64, low: f64, mid: f64, high: f64) -> f64 {
    if !(value.is_finite() && low.is_finite() && mid.is_finite() && high.is_finite() && value > 0.0)
    {
        return 0.0;
    }
    if value > low && value <= mid {
        return RISK_GREEN_MIN
            + (RISK_YELLOW_MIN - RISK_GREEN_MIN) * ((value - low) / (mid - low).max(1e-9));
    }
    if value > mid && value <= high {
        return RISK_YELLOW_MIN
            + (RISK_RED_MIN - RISK_YELLOW_MIN) * ((value - mid) / (high - mid).max(1e-9));
    }
    if value > high {
        return (RISK_RED_MIN + (1.0 - RISK_RED_MIN) * ((value - high) / high.max(1e-9))).min(1.0);
    }
    0.0
}

/// Symmetric temperature risk — byte-identical port of R/scoring.R
/// `temperature_risk`. 0 inside the comfort band, ramping linearly to 1 at the
/// record low (cold side) or record high (hot side). One of the few hazards
/// where 0 is both possible and intentional. Same comparison structure and
/// operation order as R, so IEEE-754 f64 results match bit-for-bit on the real
/// domain (finite comfort/record bounds; the scalar R form errors on NA
/// bounds, which never occur — profiles are always populated).
#[inline]
pub fn temperature_risk(
    temp_f: f64,
    comfort_low_f: f64,
    comfort_high_f: f64,
    record_low_f: f64,
    record_high_f: f64,
) -> f64 {
    if !temp_f.is_finite() {
        return 0.0;
    }
    if temp_f >= comfort_low_f && temp_f <= comfort_high_f {
        return 0.0;
    }
    if temp_f < comfort_low_f {
        return ((comfort_low_f - temp_f) / (comfort_low_f - record_low_f).max(1e-9)).min(1.0);
    }
    ((temp_f - comfort_high_f) / (record_high_f - comfort_high_f).max(1e-9)).min(1.0)
}

// ---------------------------------------------------------------- forecast
//
// The canonical thresholds and weights from `R/forecast.R:226-228`. These sit
// on top of `piecewise_score` and are what turns a raw NWS gridpoint forecast
// into the predictor scores the two-tier model in `crate::families` consumes.

/// Wind risk from sustained miles per hour — `R/forecast.R` thresholds.
///
/// 15 mph begins to matter to a high-profile vehicle, 28 is the advisory
/// band, 45 is where driving becomes unsafe for one.
#[inline]
#[must_use]
pub fn wind_risk(mph: f64) -> f64 {
    piecewise_score(mph, 15.0, 28.0, 45.0)
}

/// Precipitation-probability risk from percent — `R/forecast.R` thresholds.
///
/// A PREDICTOR, never proof: this is the chance of rain, not water on the
/// road. `crate::families` files it as a secondary for exactly that reason.
#[inline]
#[must_use]
pub fn pop_risk(pct: f64) -> f64 {
    piecewise_score(pct, 25.0, 50.0, 75.0)
}

/// The R engine's composite forecast score:
/// `min(1, 0.45·temp + 0.30·wind + 0.25·pop)`.
///
/// Weights are exact from `R/forecast.R`. Temperature leads because heat and
/// cold disable a vehicle and its occupants over hours, while wind and rain
/// are acute but usually survivable by slowing down.
#[inline]
#[must_use]
pub fn forecast_composite(temp: f64, wind: f64, pop: f64) -> f64 {
    (0.45 * temp + 0.30 * wind + 0.25 * pop).min(1.0)
}

/// Is this temperature an UNUSUAL deviation for this climate — outside about
/// one standard deviation of local norms?
///
/// The climate envelope gives comfort and record bounds; treating the record
/// as roughly the tail of the local distribution puts σ ≈ (record − comfort)/3
/// per side.
///
/// This GATES PRESENTATION only — heat and cold badges and tints — and is
/// deliberately not part of any risk equation. A mildly warm day scores a
/// small risk honestly but is not noteworthy enough to draw on a map, and
/// conflating "scores nonzero" with "worth showing" is what fills a display
/// with noise. R parity of the scores themselves is unaffected.
#[must_use]
pub fn temperature_anomalous(
    temp_f: f64,
    comfort_low_f: f64,
    comfort_high_f: f64,
    record_low_f: f64,
    record_high_f: f64,
) -> bool {
    if !temp_f.is_finite() {
        return false;
    }
    if temp_f > comfort_high_f {
        let sigma = ((record_high_f - comfort_high_f) / 3.0).max(1e-9);
        return temp_f - comfort_high_f > sigma;
    }
    if temp_f < comfort_low_f {
        let sigma = ((comfort_low_f - record_low_f) / 3.0).max(1e-9);
        return comfort_low_f - temp_f > sigma;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn temperature_risk_bands() {
        // Inside comfort -> 0; non-finite -> 0.
        assert_eq!(temperature_risk(70.0, 60.0, 80.0, 0.0, 110.0), 0.0);
        assert_eq!(temperature_risk(f64::NAN, 60.0, 80.0, 0.0, 110.0), 0.0);
        assert_eq!(temperature_risk(60.0, 60.0, 80.0, 0.0, 110.0), 0.0); // == comfort_low
        assert_eq!(temperature_risk(80.0, 60.0, 80.0, 0.0, 110.0), 0.0); // == comfort_high
                                                                         // Cold side halfway to record low.
        assert!((temperature_risk(30.0, 60.0, 80.0, 0.0, 110.0) - 0.5).abs() < 1e-12);
        // Hot side halfway to record high.
        assert!((temperature_risk(95.0, 60.0, 80.0, 0.0, 110.0) - 0.5).abs() < 1e-12);
        // Past records -> clamped at 1.
        assert_eq!(temperature_risk(-50.0, 60.0, 80.0, 0.0, 110.0), 1.0);
        assert_eq!(temperature_risk(200.0, 60.0, 80.0, 0.0, 110.0), 1.0);
    }

    #[test]
    fn boundaries_and_bands() {
        // Below/at low -> 0; non-finite/<=0 -> 0.
        assert_eq!(piecewise_score(f64::NAN, 25.0, 75.0, 150.0), 0.0);
        assert_eq!(piecewise_score(f64::INFINITY, 25.0, 75.0, 150.0), 0.0);
        assert_eq!(piecewise_score(-5.0, 25.0, 75.0, 150.0), 0.0);
        assert_eq!(piecewise_score(0.0, 25.0, 75.0, 150.0), 0.0);
        assert_eq!(piecewise_score(25.0, 25.0, 75.0, 150.0), 0.0); // == low
                                                                   // Green band lower edge just above low.
        let g = piecewise_score(26.0, 25.0, 75.0, 150.0);
        assert!(g > RISK_GREEN_MIN && g < RISK_YELLOW_MIN);
        // Exactly medium -> top of green band = YELLOW min.
        assert!((piecewise_score(75.0, 25.0, 75.0, 150.0) - RISK_YELLOW_MIN).abs() < 1e-12);
        // Exactly high -> top of yellow band = RED min.
        assert!((piecewise_score(150.0, 25.0, 75.0, 150.0) - RISK_RED_MIN).abs() < 1e-12);
        // Far above high -> clamped at 1.
        assert_eq!(piecewise_score(1e9, 25.0, 75.0, 150.0), 1.0);
        // Non-finite thresholds -> 0 (match the R vector valid-mask; the old
        // behaviour fabricated 1.0 via NaN-swallowing min/max).
        assert_eq!(piecewise_score(50.0, f64::NAN, 75.0, 150.0), 0.0);
        assert_eq!(piecewise_score(50.0, 25.0, f64::INFINITY, 150.0), 0.0);
        assert_eq!(piecewise_score(50.0, 25.0, 75.0, f64::NAN), 0.0);
    }

    // ---- R/forecast.R predictors ----

    #[test]
    fn the_forecast_thresholds_are_the_r_ones() {
        // Below the low threshold nothing scores; at each threshold the score
        // lands exactly on the band cut the R engine put there.
        assert_eq!(wind_risk(10.0), 0.0);
        assert!((wind_risk(15.0) - 0.0).abs() < 1e-12); // <= low is still 0
        assert!((wind_risk(28.0) - crate::risk::RISK_YELLOW_MIN).abs() < 1e-12);
        assert!((wind_risk(45.0) - crate::risk::RISK_RED_MIN).abs() < 1e-12);
        assert_eq!(pop_risk(20.0), 0.0);
        assert!((pop_risk(50.0) - crate::risk::RISK_YELLOW_MIN).abs() < 1e-12);
        assert!((pop_risk(75.0) - crate::risk::RISK_RED_MIN).abs() < 1e-12);
    }

    #[test]
    fn the_forecast_predictors_are_monotone_and_bounded() {
        let mut last = -1.0;
        for mph in [0.0, 10.0, 20.0, 30.0, 50.0, 100.0, 500.0] {
            let v = wind_risk(mph);
            assert!((0.0..=1.0).contains(&v), "{mph} -> {v}");
            assert!(v >= last, "wind risk fell from {last} to {v} at {mph}");
            last = v;
        }
    }

    #[test]
    fn the_composite_weights_are_exact_and_capped() {
        assert!((forecast_composite(1.0, 0.0, 0.0) - 0.45).abs() < 1e-12);
        assert!((forecast_composite(0.0, 1.0, 0.0) - 0.30).abs() < 1e-12);
        assert!((forecast_composite(0.0, 0.0, 1.0) - 0.25).abs() < 1e-12);
        assert_eq!(forecast_composite(1.0, 1.0, 1.0), 1.0);
        // the weights sum to 1, so a maxed forecast is exactly 1 before the cap
        assert_eq!(forecast_composite(2.0, 2.0, 2.0), 1.0);
    }

    #[test]
    fn only_a_real_deviation_is_anomalous() {
        // comfort 50-80, records 0-110. The two sides have DIFFERENT sigmas:
        // warm is (110-80)/3 = 10, cold is (50-0)/3 = 16.67. A climate whose
        // record low is far away tolerates more cold before it is remarkable,
        // which is the intended behaviour and worth pinning explicitly.
        let anom = |t: f64| temperature_anomalous(t, 50.0, 80.0, 0.0, 110.0);
        assert!(!anom(65.0), "inside the comfort band");
        assert!(!anom(85.0), "5 above comfort is inside sigma 10");
        assert!(anom(95.0), "15 above comfort clears sigma 10");
        assert!(!anom(45.0), "5 below comfort is inside sigma 16.67");
        assert!(!anom(35.0), "15 below comfort is STILL inside sigma 16.67");
        assert!(anom(30.0), "20 below comfort clears sigma 16.67");
        assert!(!anom(f64::NAN));
    }

    #[test]
    fn anomalous_gates_presentation_without_touching_the_score() {
        // A mildly warm day scores honestly and still is not drawn.
        let risk = temperature_risk(85.0, 50.0, 80.0, 0.0, 110.0);
        assert!(risk > 0.0, "the score must be honest: {risk}");
        assert!(!temperature_anomalous(85.0, 50.0, 80.0, 0.0, 110.0));
    }
}
