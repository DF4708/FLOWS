// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! flows-core — FLOWS compute core (Phase R0 proof-of-concept).
//!
//! See docs/RUST_SWIFT_MIGRATION.md. This crate is the first slice of the
//! R → Rust port: pure, side-effect-free functions verified byte-identical
//! to their R oracle. It is the compute library for the transit engine and
//! the offline tooling (gtfs-ftt, the trainers).
//!
//! Modules:
//!   risk     — risk band classification (port of R/scoring.R)
//!   scoring  — piecewise hazard scoring + the R/forecast.R predictors
//!   families — hazard families and the two-tier realized-risk model
//!              (port of R/families.R: weights, noisy-OR, primary vs
//!              secondary, alert classification, area naming)
//!   distance — Euclidean distance kernel (scalar reference; R-bridge only)
//!   polyline — encoded-polyline decoder (safe; the hand-asm and raw-pointer
//!              variants were both retired on measurement — see bin/bench.rs)
//!
//! There is no FFI module. `#[no_mangle]` is itself rejected by
//! `forbid(unsafe_code)`, so a C-ABI export and a forbidden crate cannot
//! coexist — and when the last export turned out to have no caller, the
//! honest resolution was to delete it rather than weaken the lint to `deny`
//! for a diagnostic nothing read. The Swift app is Swift-native today; the
//! boundary returns with the transit engine, through swift-bridge, which
//! exports via `#[export_name]` and is verified to compile under this same
//! `forbid` (docs/RUST_SWIFT_MIGRATION.md).
//!
//! Nothing here performs I/O or holds state; every function is a pure
//! transform, which is exactly why it can be verified against R exactly.
//!
//! # Safe-Rust enforcement (3.15)
//!
//! `unsafe_code` is FORBIDDEN crate-wide, with no carve-out — `forbid` cannot
//! be lifted by an inner `allow`, so this is the strongest form the compiler
//! offers. Getting here took three deletions rather than three rewrites: the
//! raw-pointer polyline kernel (retired on measurement, 3.15 being explicit
//! that a benchmark buys no exception), five FFI exports the Swift app never
//! referenced, and finally the two pointer-passing exports themselves —
//! `flows_polyline_decode`, whose Swift caller already had a value-identical
//! native decoder, and `flows_transit_plan`, which had no caller at all.
//!
//! What crosses to Swift now is one value-oriented export returning an i64,
//! which is the shape 3.25.5 permits and needs no unsafe. When the transit
//! engine goes live and a real bulk boundary is required, the decision is
//! recorded in docs/RUST_SWIFT_MIGRATION.md: swift-bridge, verified to
//! compile under this same `forbid`.
#![forbid(unsafe_code)]

pub mod ch;
pub mod distance;
pub mod families;
pub mod polyline;
pub mod risk;
pub mod routing;
pub mod scoring;
pub mod transit;

pub use families::{
    alert_family, dominant_family, family_weight, flood_elevation_multiplier, is_primary,
    is_secondary, noisy_or, peak_family, ranking_risk, realized_risk, SECONDARY_CEILING,
};
pub use risk::{risk_band, RiskBand, RISK_GREEN_MIN, RISK_RED_MIN, RISK_YELLOW_MIN};
pub use scoring::{
    forecast_composite, piecewise_score, piecewise_score_rowwise, pop_risk, temperature_anomalous,
    temperature_risk, wind_risk,
};
