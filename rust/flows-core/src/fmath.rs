// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The platform libm, one call per function.
//!
//! When one function evaluates both `sin(x)` and `cos(x)`, an optimising
//! backend may fuse the pair into the C library's `__sincos_stret`, whose
//! sine differs from the standalone `sin` by one unit in the last place for
//! some arguments — and whether it fuses depends on the compiler, the
//! optimisation level and the shape of the code around the calls. The app's
//! Swift Release build fuses; its Debug build does not (measured on one
//! input: fused sine `3fe3bb4b91330e6a`, standalone `3fe3bb4b91330e6b`).
//!
//! Routing every trigonometric call through its own non-inlined function
//! denies the backend the pair, so every kernel here computes the standalone
//! value in every build: identical in debug and release. The oracles for
//! trig-bearing code (geo, climate) therefore pin their contract in physical
//! terms — a bearing to a micrometre at the target, an instant to a
//! millisecond — never as bits (see `docs/LEARNINGS.md`, "Two calls the
//! optimiser turns into one").

/// `sin` as its own libm call.
#[inline(never)]
#[must_use]
pub(crate) fn sin(x: f64) -> f64 {
    x.sin()
}

/// `cos` as its own libm call.
#[inline(never)]
#[must_use]
pub(crate) fn cos(x: f64) -> f64 {
    x.cos()
}

/// `tan` as its own libm call.
#[inline(never)]
#[must_use]
pub(crate) fn tan(x: f64) -> f64 {
    x.tan()
}

/// `asin` as its own libm call.
#[inline(never)]
#[must_use]
pub(crate) fn asin(x: f64) -> f64 {
    x.asin()
}

/// `acos` as its own libm call.
#[inline(never)]
#[must_use]
pub(crate) fn acos(x: f64) -> f64 {
    x.acos()
}
