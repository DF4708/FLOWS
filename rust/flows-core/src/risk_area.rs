// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The planning map's risk-area geometry: Swift's `RiskAreaFallback` before
//! its rules moved here. When a risk point waits for its ZIP outline, the
//! sweep's lattice fixed to the map, the circle drawn where no ZIP is, and a
//! ring's centroid, icon anchor, interior samples and even–odd test.
//!
//! A point is `(latitude, longitude)` in degrees. Every rule is the
//! original's arithmetic in the original's order, so the answers are the
//! same bits, with one exception: the circle's sine and cosine go through
//! [`crate::fmath`], and Swift's Release build fuses that pair into
//! `__sincos_stret`, which can be one unit in the last place off. The
//! circle is pinned to a micrometre on the ground instead of to the bit.
//!
//! Three places differ only where the original never answers or answers by
//! chance:
//! - the lattice stops when a step of one no longer moves its index (an
//!   infinite bound, or a multiple past 2^53), or at [`LATTICE_CAP`] points;
//!   the original loops there until memory runs out;
//! - the icon anchor's crossings sort exactly as Swift sorts them (an
//!   insertion sort below 64, which is what Swift's sort is there) and, past
//!   that, by a stable sort; only a ring with a NaN coordinate and 64 or more
//!   crossings could then line up differently, and Swift's own order there
//!   depends on its merge sort's run lengths.
//!
//! Pinned by `flows-bridge/tests/fixtures/swift_risk_area_fallback_oracle.tsv`.

use crate::fmath;

/// A point: latitude, then longitude, in degrees.
pub type Point = (f64, f64);

/// The most lattice points one sweep returns. The app asks for at most
/// seven per side (about 64 points); the original never finishes where this
/// cuts in.
pub const LATTICE_CAP: usize = 1 << 22;

/// The box the ZIP layer is asked about: the lower 48, roughly.
#[must_use]
pub fn in_zip_box(lat: f64, lon: f64) -> bool {
    lat > 24.0 && lat < 50.0 && lon > -125.0 && lon < -66.0
}

/// Whether a risk point's blob waits for this sweep's ZIP lookups.
#[must_use]
pub fn blob_waits(lat: f64, lon: f64, lookups_done: bool, placed_before: bool) -> bool {
    in_zip_box(lat, lon) && !lookups_done && !placed_before
}

/// The smallest rung of the √2 ladder at or above `wanted`; 1 for a
/// non-finite or non-positive one. Swift's Release build turns its
/// `pow(2, x)` into `exp2(x)`.
fn rung(wanted: f64) -> f64 {
    if !wanted.is_finite() || wanted <= 0.0 {
        return 1.0;
    }
    ((2.0 * wanted.log2()).ceil() / 2.0).exp2()
}

/// The sweep's sample points, on whole multiples of a rung of the ladder.
#[must_use]
pub fn lattice(
    center_lat: f64,
    center_lon: f64,
    span_lat: f64,
    span_lon: f64,
    per_side: i64,
) -> Vec<Point> {
    // Swift's `Double(Int)` rounds to nearest, as `as f64` does.
    #[allow(clippy::cast_precision_loss)]
    let across = per_side.max(1) as f64;
    let step_lat = rung(span_lat / across);
    let step_lon = rung(span_lon / across);
    let lat0 = center_lat - span_lat / 2.0;
    let lat1 = center_lat + span_lat / 2.0;
    let lon0 = center_lon - span_lon / 2.0;
    let lon1 = center_lon + span_lon / 2.0;
    let mut out = Vec::new();
    let mut i = (lat0 / step_lat).ceil();
    while i * step_lat <= lat1 {
        let mut j = (lon0 / step_lon).ceil();
        while j * step_lon <= lon1 {
            if out.len() >= LATTICE_CAP {
                return out;
            }
            out.push((i * step_lat, j * step_lon));
            let next = j + 1.0;
            if next == j {
                return out;
            }
            j = next;
        }
        let next = i + 1.0;
        if next == i {
            return out;
        }
        i = next;
    }
    out
}

/// A circle as a ring of `max(points, 3)` vertices around a center.
#[must_use]
pub fn circle_ring(
    center_lat: f64,
    center_lon: f64,
    radius_meters: f64,
    points: i64,
) -> Vec<Point> {
    let d_lat = radius_meters / 111_320.0;
    let d_lon = radius_meters
        / (111_320.0 * swift_max2(fmath::cos(center_lat * std::f64::consts::PI / 180.0), 1e-6));
    let n = points.max(3);
    #[allow(clippy::cast_precision_loss)]
    let nf = n as f64;
    (0..n)
        .map(|k| {
            #[allow(clippy::cast_precision_loss)]
            let a = k as f64 / nf * 2.0 * std::f64::consts::PI;
            (
                center_lat + d_lat * fmath::sin(a),
                center_lon + d_lon * fmath::cos(a),
            )
        })
        .collect()
}

/// Swift's `max(x, y)`: `y >= x ? y : x`, so a NaN `x` comes back (Rust's
/// `f64::max` would answer `y`).
fn swift_max2(x: f64, y: f64) -> f64 {
    if y >= x {
        y
    } else {
        x
    }
}

/// Shoelace (area-weighted) centroid; the vertex mean for a ring with no
/// area; `(0, 0)` for an empty one.
#[must_use]
pub fn centroid(ring: &[Point]) -> Point {
    if ring.is_empty() {
        return (0.0, 0.0);
    }
    let n = ring.len();
    let mut area = 0.0;
    let mut cx = 0.0;
    let mut cy = 0.0;
    for i in 0..n {
        let a = ring[i];
        let b = ring[(i + 1) % n];
        let cross = a.1 * b.0 - b.1 * a.0;
        area += cross;
        cx += (a.1 + b.1) * cross;
        cy += (a.0 + b.0) * cross;
    }
    if f64::abs(area) > 1e-12 {
        return (cy / (3.0 * area), cx / (3.0 * area));
    }
    #[allow(clippy::cast_precision_loss)]
    let count = n as f64;
    // `reduce(0, +)` starts from +0.0; Rust's `Sum` starts from -0.0.
    let lat = ring.iter().fold(0.0, |s, p| s + p.0) / count;
    let lon = ring.iter().fold(0.0, |s, p| s + p.1) / count;
    (lat, lon)
}

/// Swift's sort of a `[Double]` by `<`: below 64 elements its sort is an
/// insertion sort after its first run, which places every element where a
/// plain insertion sort does.
fn swift_sort(xs: &mut [f64]) {
    if xs.len() >= 64 && !xs.iter().any(|x| x.is_nan()) {
        // Without NaN `<` is a strict weak order: every stable sort agrees.
        xs.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        return;
    }
    for i in 1..xs.len() {
        let mut k = i;
        while k > 0 && xs[k] < xs[k - 1] {
            xs.swap(k, k - 1);
            k -= 1;
        }
    }
}

/// Where an area's one icon stands: the centroid when it lies inside the
/// ring, else the middle of the widest stretch along the centroid's
/// latitude.
#[must_use]
pub fn icon_anchor(ring: &[Point]) -> Point {
    let c = centroid(ring);
    if ring.len() < 3 || contains(ring, c) {
        return c;
    }
    let n = ring.len();
    let mut xs = Vec::new();
    for i in 0..n {
        let a = ring[i];
        let b = ring[(i + 1) % n];
        if (a.0 <= c.0) != (b.0 <= c.0) {
            let t = (c.0 - a.0) / (b.0 - a.0);
            xs.push(a.1 + t * (b.1 - a.1));
        }
    }
    swift_sort(&mut xs);
    let mut best: Option<(f64, f64)> = None;
    let mut k = 0;
    while k + 1 < xs.len() {
        let wider = match best {
            None => true,
            Some((s0, s1)) => xs[k + 1] - xs[k] > s1 - s0,
        };
        if wider {
            best = Some((xs[k], xs[k + 1]));
        }
        k += 2;
    }
    match best {
        Some((s0, s1)) => (c.0, (s0 + s1) / 2.0),
        None => c,
    }
}

/// Swift's `min()`: the first element, replaced by every later one less
/// than it.
fn swift_min(xs: impl Iterator<Item = f64>) -> Option<f64> {
    xs.reduce(|r, e| if e < r { e } else { r })
}

/// Swift's `max()`: the first element, replaced by every later one it is
/// less than.
fn swift_max(xs: impl Iterator<Item = f64>) -> Option<f64> {
    xs.reduce(|r, e| if r < e { e } else { r })
}

/// Up to `limit` points spread inside a ring: its icon anchor first, then a
/// 4 × 4 grid over its bounding box kept to the points inside it.
#[must_use]
pub fn interior_samples(ring: &[Point], limit: i64) -> Vec<Point> {
    if ring.len() < 3 || limit <= 0 {
        return Vec::new();
    }
    let mut out = vec![icon_anchor(ring)];
    let (Some(la0), Some(la1), Some(lo0), Some(lo1)) = (
        swift_min(ring.iter().map(|p| p.0)),
        swift_max(ring.iter().map(|p| p.0)),
        swift_min(ring.iter().map(|p| p.1)),
        swift_max(ring.iter().map(|p| p.1)),
    ) else {
        return out;
    };
    let side = 4;
    for i in 0..side {
        for j in 0..side {
            let p = (
                la0 + (la1 - la0) * (f64::from(i) + 0.5) / f64::from(side),
                lo0 + (lo1 - lo0) * (f64::from(j) + 0.5) / f64::from(side),
            );
            if contains(ring, p) {
                out.push(p);
            }
        }
    }
    let Ok(limit) = usize::try_from(limit) else {
        return out;
    };
    if out.len() <= limit {
        return out;
    }
    if limit == 1 {
        return vec![out[0]];
    }
    #[allow(clippy::cast_precision_loss)]
    let stride = (out.len() - 1) as f64 / (limit - 1) as f64;
    (0..limit)
        .map(|k| {
            #[allow(
                clippy::cast_precision_loss,
                clippy::cast_possible_truncation,
                clippy::cast_sign_loss
            )]
            let at = (k as f64 * stride).round() as usize;
            out[at.min(out.len() - 1)]
        })
        .collect()
}

/// Even–odd point-in-polygon.
#[must_use]
pub fn contains(ring: &[Point], p: Point) -> bool {
    if ring.len() < 3 {
        return false;
    }
    let mut inside = false;
    let mut j = ring.len() - 1;
    for i in 0..ring.len() {
        let a = ring[i];
        let b = ring[j];
        if (a.0 > p.0) != (b.0 > p.0) {
            let x = a.1 + (p.0 - a.0) / (b.0 - a.0) * (b.1 - a.1);
            if p.1 < x {
                inside = !inside;
            }
        }
        j = i;
    }
    inside
}
