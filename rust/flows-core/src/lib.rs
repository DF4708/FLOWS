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
//!   distance — Euclidean distance kernel (scalar + auto-vectorised)
//!   polyline — encoded-polyline decoder (AArch64 asm hot loop + portable Rust)
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

pub use risk::{risk_band, RiskBand, RISK_GREEN_MIN, RISK_RED_MIN, RISK_YELLOW_MIN};
pub use scoring::{piecewise_score, piecewise_score_rowwise, temperature_risk};
