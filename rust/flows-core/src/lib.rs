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
//!
//! # Safe-Rust enforcement (3.15)
//!
//! `unsafe_code` is denied crate-wide. The single exception is the `ffi`
//! module, which carries an explicit `#[allow(unsafe_code)]` because its two
//! remaining bulk-array exports take raw pointers from Swift; the standard's
//! remedy for that shape is a binding generator or a serialization boundary,
//! which is an open architectural decision (docs/RUST_SWIFT_MIGRATION.md).
//! The deny means unsafe cannot reappear anywhere else in the crate without
//! a compiler error — which is exactly what caught nothing today, because
//! the raw-pointer polyline kernel was retired to earn this line.
#![deny(unsafe_code)]

pub mod ch;
pub mod distance;
// The one carve-out, narrowed to a single module and named here so it is
// visible in the crate root rather than buried at a call site.
#[allow(unsafe_code)]
pub mod ffi;
pub mod polyline;
pub mod risk;
pub mod routing;
pub mod scoring;
pub mod transit;

pub use risk::{risk_band, RiskBand, RISK_GREEN_MIN, RISK_RED_MIN, RISK_YELLOW_MIN};
pub use scoring::{piecewise_score, piecewise_score_rowwise, temperature_risk};
