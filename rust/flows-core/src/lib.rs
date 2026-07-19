// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! flows-core — FLOWS compute core (Phase R0 proof-of-concept).
//!
//! See docs/RUST_SWIFT_MIGRATION.md. This crate is the first slice of the
//! R → Rust port: pure, side-effect-free functions verified byte-identical
//! to their R oracle. It links into the Swift UI as a staticlib
//! (libflows_core.a) via the C-ABI surface in `ffi`.
//!
//! Modules:
//!   risk     — risk band classification (port of R/scoring.R)
//!   scoring  — piecewise hazard scoring (port of R/scoring.R piecewise_score)
//!   distance — Euclidean distance kernel (scalar reference; R-bridge only)
//!   polyline — encoded-polyline decoder (raw-pointer fast kernel + safe oracle;
//!              the hand-asm variant was retired when bin/bench.rs showed rustc
//!              out-scheduling it — asm must beat the compiler to ship)
//!   ffi      — C-ABI exports for Swift
//!
//! Nothing here performs I/O or holds state; every function is a pure
//! transform, which is exactly why it can be verified against R exactly.

pub mod ch;
pub mod distance;
pub mod ffi;
pub mod polyline;
pub mod risk;
pub mod routing;
pub mod scoring;
pub mod transit;

pub use risk::{risk_band, RiskBand, RISK_GREEN_MIN, RISK_RED_MIN, RISK_YELLOW_MIN};
pub use scoring::{piecewise_score, piecewise_score_rowwise, temperature_risk};
