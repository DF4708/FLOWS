// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::risk_area`, behind Swift's
//! `RiskAreaFallback`. Implementations live in `flows-core`; this file only
//! crosses.
//!
//! - A ring crosses dense, `[lat0, lon0, lat1, lon1, …]`; an odd last value
//!   is dropped. Points come back the same way, and one point is two values.
//! - Nothing in these rules indexes past an end or divides an integer, so
//!   none should panic. If one does: no lattice points and no circle (the
//!   sweep samples nothing new, the blob stays), an empty answer for a
//!   centroid, anchor or samples (Swift then answers as for an empty ring),
//!   no wait for a blob (it draws now), and `contains` answers inside, so an
//!   alert is never dropped because a check failed.

use crate::contain;
use flows_core::risk_area as ra;

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        fn flows_risk_area_in_zip_box(lat: f64, lon: f64) -> bool;
        fn flows_risk_area_blob_waits(
            lat: f64,
            lon: f64,
            lookups_done: bool,
            placed_before: bool,
        ) -> bool;
        fn flows_risk_area_lattice(
            center_lat: f64,
            center_lon: f64,
            span_lat: f64,
            span_lon: f64,
            per_side: i64,
        ) -> Vec<f64>;
        fn flows_risk_area_circle_ring(
            lat: f64,
            lon: f64,
            radius_meters: f64,
            points: i64,
        ) -> Vec<f64>;
        fn flows_risk_area_centroid(ring: &[f64]) -> Vec<f64>;
        fn flows_risk_area_icon_anchor(ring: &[f64]) -> Vec<f64>;
        fn flows_risk_area_interior_samples(ring: &[f64], limit: i64) -> Vec<f64>;
        fn flows_risk_area_contains(ring: &[f64], lat: f64, lon: f64) -> bool;
    }
}

fn ring(flat: &[f64]) -> Vec<ra::Point> {
    flat.chunks_exact(2).map(|p| (p[0], p[1])).collect()
}

fn dense(points: &[ra::Point]) -> Vec<f64> {
    points.iter().flat_map(|p| [p.0, p.1]).collect()
}

pub fn flows_risk_area_in_zip_box(lat: f64, lon: f64) -> bool {
    contain(false, || ra::in_zip_box(lat, lon))
}

pub fn flows_risk_area_blob_waits(
    lat: f64,
    lon: f64,
    lookups_done: bool,
    placed_before: bool,
) -> bool {
    contain(false, || {
        ra::blob_waits(lat, lon, lookups_done, placed_before)
    })
}

pub fn flows_risk_area_lattice(
    center_lat: f64,
    center_lon: f64,
    span_lat: f64,
    span_lon: f64,
    per_side: i64,
) -> Vec<f64> {
    contain(Vec::new(), || {
        dense(&ra::lattice(
            center_lat, center_lon, span_lat, span_lon, per_side,
        ))
    })
}

pub fn flows_risk_area_circle_ring(
    lat: f64,
    lon: f64,
    radius_meters: f64,
    points: i64,
) -> Vec<f64> {
    contain(Vec::new(), || {
        dense(&ra::circle_ring(lat, lon, radius_meters, points))
    })
}

pub fn flows_risk_area_centroid(flat: &[f64]) -> Vec<f64> {
    contain(Vec::new(), || {
        let c = ra::centroid(&ring(flat));
        vec![c.0, c.1]
    })
}

pub fn flows_risk_area_icon_anchor(flat: &[f64]) -> Vec<f64> {
    contain(Vec::new(), || {
        let c = ra::icon_anchor(&ring(flat));
        vec![c.0, c.1]
    })
}

pub fn flows_risk_area_interior_samples(flat: &[f64], limit: i64) -> Vec<f64> {
    contain(Vec::new(), || {
        dense(&ra::interior_samples(&ring(flat), limit))
    })
}

pub fn flows_risk_area_contains(flat: &[f64], lat: f64, lon: f64) -> bool {
    contain(true, || ra::contains(&ring(flat), (lat, lon)))
}
