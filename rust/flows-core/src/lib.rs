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
//! to their R oracle. It is the compute library behind the app's risk
//! equations and polyline decoding (through flows-bridge), the transit engine,
//! and the offline tooling (gtfs-ftt, the trainers).
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
//! flows-core has no FFI of its own and never will: `#[no_mangle]` is
//! rejected by `forbid(unsafe_code)`. The app reaches these functions through
//! the separate `flows-bridge` crate, whose swift-bridge declarations forward
//! here; this crate does not know Swift exists.
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
//! Nothing here crosses a language boundary. `flows-bridge` holds the
//! swift-bridge declarations and forwards into this crate, so the domain code
//! stays dependency-free and free of unsafe. (swift-bridge's generated glue
//! does contain `unsafe`; it lives in flows-bridge, not here — see that
//! crate's Cargo.toml.)
#![forbid(unsafe_code)]

pub mod alerts;
pub mod ch;
pub mod climate;
pub mod distance;
pub mod families;
pub mod fcmp;
pub(crate) mod fmath;
pub mod geo;
pub mod learning;
pub mod places_text;
pub mod polyline;
pub mod risk;
pub mod routing;
pub mod scoring;
pub mod seasonal;
pub mod transit;
pub mod trip_vehicle;
pub mod vehicle_policy;

pub use families::{
    alert_family, dominant_family, family_weight, flood_elevation_multiplier, is_primary,
    is_secondary, noisy_or, peak_family, ranking_risk, realized_risk, SECONDARY_CEILING,
};
pub use risk::{risk_band, RiskBand, RISK_GREEN_MIN, RISK_RED_MIN, RISK_YELLOW_MIN};
pub use scoring::{
    forecast_composite, piecewise_score, piecewise_score_rowwise, pop_risk, temperature_anomalous,
    temperature_risk, wind_risk,
};
