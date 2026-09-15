// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Floating-point `min`/`max` and `Int(Double)` with the edge semantics of
//! the shipping app.
//!
//! The app's risk equations were written in Swift, whose generic `min(x, y)`
//! is `y < x ? y : x` and `max(x, y)` is `y >= x ? y : x`. Rust's `f64::min`
//! and `f64::max` are IEEE `minNum`/`maxNum`: they discard a NaN operand and
//! may return either zero for `+0.0` against `-0.0`. On in-domain inputs the
//! two agree bit for bit; on NaN, infinities and signed zeros they do not.
//!
//! Moving the equations out of Swift must not change a single number a driver
//! has seen, so every equation the app calls is written with these, and the
//! frozen Swift oracle (`flows-bridge/tests/fixtures/swift_risk_oracle.tsv`)
//! pins the result.

/// Swift's `min(x, y)`: `y < x ? y : x`.
#[inline]
#[must_use]
pub fn smin(x: f64, y: f64) -> f64 {
    if y < x {
        y
    } else {
        x
    }
}

/// Swift's `max(x, y)`: `y >= x ? y : x`.
#[inline]
#[must_use]
pub fn smax(x: f64, y: f64) -> f64 {
    if y >= x {
        y
    } else {
        x
    }
}

/// Swift's `min(max(x, 0), 1)` — no finiteness check: a NaN passes through.
#[inline]
#[must_use]
pub fn sunit(x: f64) -> f64 {
    smin(smax(x, 0.0), 1.0)
}

/// Swift's `Int(x)` for a `Double`: `None` where Swift traps — NaN, the
/// infinities, and values outside `-2^63 - 2048 < x < 2^63` (the stdlib's
/// precondition, verbatim); otherwise `x` truncated toward zero.
#[inline]
#[must_use]
pub fn swift_int(x: f64) -> Option<i64> {
    (x > -9_223_372_036_854_777_856.0 && x < 9_223_372_036_854_775_808.0).then_some(x as i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nan_and_signed_zero_follow_swift_not_ieee_minnum() {
        // Swift max(NaN, 1) is NaN (1 >= NaN is false); f64::max gives 1.
        assert!(smax(f64::NAN, 1.0).is_nan());
        assert_eq!(smax(1.0, f64::NAN), 1.0);
        assert!(smin(f64::NAN, 1.0).is_nan());
        assert_eq!(smin(1.0, f64::NAN), 1.0);
        // On a signed-zero tie max returns y and min returns x.
        assert_eq!(smax(0.0, -0.0).to_bits(), (-0.0f64).to_bits());
        assert_eq!(smax(-0.0, 0.0).to_bits(), 0.0f64.to_bits());
        assert_eq!(smin(-0.0, 0.0).to_bits(), (-0.0f64).to_bits());
        assert!(sunit(f64::NAN).is_nan());
        assert_eq!(sunit(-0.0).to_bits(), 0.0f64.to_bits());
    }

    #[test]
    fn swift_int_accepts_exactly_the_range_swift_does() {
        assert_eq!(swift_int(-1.5), Some(-1));
        assert_eq!(swift_int(-2.0), Some(-2));
        assert_eq!(swift_int(-9_223_372_036_854_775_808.0), Some(i64::MIN));
        assert_eq!(
            swift_int(9_223_372_036_854_775_808.0_f64.next_down()),
            Some(9_223_372_036_854_774_784)
        );
        assert_eq!(swift_int(9_223_372_036_854_775_808.0), None);
        assert_eq!(
            swift_int((-9_223_372_036_854_775_808.0_f64).next_down()),
            None
        );
        assert_eq!(swift_int(f64::NAN), None);
        assert_eq!(swift_int(f64::INFINITY), None);
        assert_eq!(swift_int(f64::NEG_INFINITY), None);
    }
}
