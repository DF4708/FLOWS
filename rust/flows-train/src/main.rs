// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! FLOWS route-risk head trainer (phase 2a) — pure std, ZERO external crates,
//! the same discipline as `flows-core`. Reads the app's flat training export
//! (real, decaying-weighted per-route/week observations) plus low-weight
//! physical seed rows, fits a small MLP (features -> risk 0..1) by Adam, and
//! writes the weights the Swift `LearnedHead` runs, in a plain-JSON contract:
//!
//!   { "w1": [[in]*hidden], "b1": [hidden], "w2": [hidden], "b2": f,
//!     "version": n, "in": 6, "hidden": 16 }
//!
//! The FEATURE ORDER is identical to Swift `RouteFeatures.vector` — change one,
//! change both:
//!   [ sin(2π·week/52), cos(2π·week/52), oLat/90, dLat/90,
//!     min(haversine_km, 4000)/4000, crossCountry ]

use std::env;
use std::f64::consts::PI;
use std::fs;

const NI: usize = 8; // input features (v2: + origin/dest longitude)
const NH: usize = 16; // hidden units

// ---------------------------------------------------------------- features

fn haversine_km(a_lat: f64, a_lon: f64, b_lat: f64, b_lon: f64) -> f64 {
    let (r, to_rad) = (6371.0_f64, PI / 180.0);
    let d_lat = (b_lat - a_lat) * to_rad;
    let d_lon = (b_lon - a_lon) * to_rad;
    let s = (d_lat / 2.0).sin().powi(2)
        + (a_lat * to_rad).cos() * (b_lat * to_rad).cos() * (d_lon / 2.0).sin().powi(2);
    2.0 * r * s.sqrt().atan2((1.0 - s).sqrt())
}

fn features(o_lat: f64, o_lon: f64, d_lat: f64, d_lon: f64, week: f64, cross: bool) -> [f64; NI] {
    let a = 2.0 * PI * week / 52.0;
    let dist = haversine_km(o_lat, o_lon, d_lat, d_lon);
    // v2 contract: longitudes included — without them Phoenix and Moore, OK
    // (same latitude band) were indistinguishable, collapsing desert-heat and
    // tornado-alley climatology into one blur. IDENTICAL order in Swift
    // RouteFeatures.vector; change one side => change both + version bump.
    [
        a.sin(),
        a.cos(),
        o_lat / 90.0,
        d_lat / 90.0,
        o_lon / 180.0,
        d_lon / 180.0,
        dist.min(4000.0) / 4000.0,
        if cross { 1.0 } else { 0.0 },
    ]
}

struct Row {
    x: [f64; NI],
    y: f64,
    w: f64,
}

// ---------------------------------------------------------------- seed data

/// Physically-plausible seed rows so the head is useful before real trips:
/// cold-season road risk growing with latitude and peaking mid-winter, plus a
/// tropical bump for southern coastal corridors in late summer. Low weight, so
/// a handful of real observations quickly outvote them.
fn seed_rows() -> Vec<Row> {
    // (o_lat, o_lon, d_lat, d_lon, cross)
    let routes: [(f64, f64, f64, f64, bool); 10] = [
        (43.07, -89.40, 43.20, -89.20, false), // Madison local
        (44.98, -93.27, 45.10, -93.10, false), // Minneapolis local (cold)
        (25.76, -80.19, 26.10, -80.30, false), // Miami local (tropical)
        (34.05, -118.24, 34.20, -118.10, false), // LA local
        (40.71, -74.01, 40.90, -74.20, false), // NYC local
        (25.76, -80.19, 41.88, -87.63, true),  // Miami -> Chicago
        (47.61, -122.33, 34.05, -118.24, true), // Seattle -> LA
        (41.88, -87.63, 39.74, -104.99, true), // Chicago -> Denver
        (29.76, -95.37, 32.78, -96.80, true),  // Houston -> Dallas
        (42.36, -71.06, 38.90, -77.04, true),  // Boston -> DC
    ];
    let mut rows = Vec::new();
    for &(o_lat, o_lon, d_lat, d_lon, cross) in &routes {
        let mid = (o_lat + d_lat) / 2.0;
        for w in 0..52 {
            let week = w as f64;
            let winter = (2.0 * PI * week / 52.0).cos().max(0.0);
            let mut r = 0.12 + 0.55 * winter * ((mid - 30.0) / 30.0).max(0.0);
            if mid < 32.0 && (32..=44).contains(&w) {
                r += 0.30 * (PI * (week - 32.0) / 12.0).sin();
            }
            if cross {
                r += 0.05;
            }
            rows.push(Row {
                x: features(o_lat, o_lon, d_lat, d_lon, week, cross),
                y: r.clamp(0.05, 0.95),
                w: 2.0,
            });
        }
    }
    rows
}

/// The app's flat CSV export (header + rows). Missing/garbled ⇒ seed only.
fn read_csv(path: &str) -> Vec<Row> {
    let mut rows = Vec::new();
    let Ok(text) = fs::read_to_string(path) else { return rows };
    for line in text.lines() {
        if line.starts_with("oLat") || line.trim().is_empty() {
            continue;
        }
        let f: Vec<f64> = line.split(',').filter_map(|s| s.trim().parse().ok()).collect();
        // Drop any row with a non-finite field: `f[5].clamp(0,1)` on a NaN
        // returns NaN, and one NaN row poisons the whole gradient — the
        // trainer would then write an all-NaN model that ships.
        if f.len() >= 8 && f.iter().take(8).all(|v| v.is_finite()) {
            rows.push(Row {
                x: features(f[0], f[1], f[2], f[3], f[4], f[7] > 0.5),
                y: f[5].clamp(0.0, 1.0),
                w: f[6].max(0.0),
            });
        }
    }
    rows
}

// ---------------------------------------------------------------- MLP + Adam

#[derive(Clone)]
struct Net {
    w1: [[f64; NI]; NH],
    b1: [f64; NH],
    w2: [f64; NH],
    b2: f64,
}
impl Net {
    fn zero() -> Net {
        Net { w1: [[0.0; NI]; NH], b1: [0.0; NH], w2: [0.0; NH], b2: 0.0 }
    }
}

/// Deterministic LCG so training is reproducible without a rand crate.
struct Lcg(u64);
impl Lcg {
    fn unit(&mut self) -> f64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        (self.0 >> 11) as f64 / (1u64 << 53) as f64
    }
    fn sym(&mut self, a: f64) -> f64 {
        (self.unit() * 2.0 - 1.0) * a
    }
}

fn init() -> Net {
    let mut rng = Lcg(0x1234_5678_9abc_def0);
    let mut n = Net::zero();
    let a1 = (6.0 / (NI + NH) as f64).sqrt(); // Xavier
    let a2 = (6.0 / (NH + 1) as f64).sqrt();
    for j in 0..NH {
        for i in 0..NI {
            n.w1[j][i] = rng.sym(a1);
        }
        n.w2[j] = rng.sym(a2);
    }
    n
}

#[inline]
fn adam(p: &mut f64, g: f64, m: &mut f64, v: &mut f64, t: i32, lr: f64) {
    let (b1, b2, eps) = (0.9, 0.999, 1e-8);
    *m = b1 * *m + (1.0 - b1) * g;
    *v = b2 * *v + (1.0 - b2) * g * g;
    let mh = *m / (1.0 - b1.powi(t));
    let vh = *v / (1.0 - b2.powi(t));
    *p -= lr * mh / (vh.sqrt() + eps);
}

/// Forward pass returning (pred, hidden, pre-activation) for backprop.
///
/// FMA + two-way accumulator split: the dot products were single serial
/// fadd chains bound by ~3-cycle add latency; two independent partials cut
/// the chain in half and `mul_add` fuses each step's rounding. This
/// reassociates the sum and changes the low bits — LEGAL in the trainer
/// (train() already accepts fp-order variance from thread chunking, and the
/// Swift contract is feature order + weight JSON, not bit-exact training) —
/// and BANNED in flows-core, whose kernels document the stricter rule
/// (distance.rs: byte-identical to the R oracle, no FMA).
fn forward(n: &Net, x: &[f64; NI]) -> (f64, [f64; NH], [f64; NH]) {
    let mut z1 = [0.0; NH];
    let mut h = [0.0; NH];
    for j in 0..NH {
        let w = &n.w1[j];
        let mut s0 = n.b1[j];
        let mut s1 = 0.0;
        let mut i = 0;
        while i + 1 < NI {
            s0 = w[i].mul_add(x[i], s0);
            s1 = w[i + 1].mul_add(x[i + 1], s1);
            i += 2;
        }
        if i < NI {
            s0 = w[i].mul_add(x[i], s0);
        }
        let s = s0 + s1;
        z1[j] = s;
        h[j] = s.max(0.0); // relu
    }
    let mut z2a = n.b2;
    let mut z2b = 0.0;
    let mut j = 0;
    while j + 1 < NH {
        z2a = n.w2[j].mul_add(h[j], z2a);
        z2b = n.w2[j + 1].mul_add(h[j + 1], z2b);
        j += 2;
    }
    if j < NH {
        z2a = n.w2[j].mul_add(h[j], z2a);
    }
    let z2 = z2a + z2b;
    (1.0 / (1.0 + (-z2).exp()), h, z1) // sigmoid
}

/// Gradient of one row-chunk (the parallel unit). Pure function of
/// (net, rows, row weights). `wws[k]` is rows[k].w / wmean, hoisted out of
/// the epoch loop by train(): the divisor is fixed for the whole run, so the
/// per-row division was recomputed identically ~400x per row (~460M fdiv on
/// the 20-year set). Same operands, same division, computed once.
fn chunk_grad(net: &Net, rows: &[Row], wws: &[f64]) -> Net {
    let mut g = Net::zero();
    for (r, &ww) in rows.iter().zip(wws) {
        let (pred, h, z1) = forward(net, &r.x);
        let dz2 = 2.0 * ww * (pred - r.y) * pred * (1.0 - pred); // MSE·sigmoid
        g.b2 += dz2;
        for j in 0..NH {
            g.w2[j] = dz2.mul_add(h[j], g.w2[j]);
            let dz1 = if z1[j] > 0.0 { dz2 * net.w2[j] } else { 0.0 };
            g.b1[j] += dz1;
            for i in 0..NI {
                g.w1[j][i] = dz1.mul_add(r.x[i], g.w1[j][i]);
            }
        }
    }
    g
}

fn add_grad(into: &mut Net, g: &Net) {
    into.b2 += g.b2;
    for j in 0..NH {
        into.w2[j] += g.w2[j];
        into.b1[j] += g.b1[j];
        for i in 0..NI {
            into.w1[j][i] += g.w1[j][i];
        }
    }
}

fn train(rows: &[Row], epochs: i32, lr: f64) -> Net {
    let mut net = init();
    let (mut m, mut v) = (Net::zero(), Net::zero());
    let n = rows.len().max(1) as f64;
    let wmean = (rows.iter().map(|r| r.w).sum::<f64>() / n).max(1e-9);
    // Full-batch gradient, PARALLEL across cores: each thread sums its chunk's
    // gradient (identical math to the serial loop; only fp summation order
    // differs, within Adam's noise floor). ~cores× faster on the 1.16M-row
    // 20-year history set; small row counts stay serial (thread spawn costs
    // more than it saves).
    let workers = std::thread::available_parallelism().map(|p| p.get()).unwrap_or(1);
    // Row weights normalized ONCE — wmean is fixed for the whole run (see
    // chunk_grad's doc comment).
    let wws: Vec<f64> = rows.iter().map(|r| r.w / wmean).collect();
    for ep in 1..=epochs {
        let g = if rows.len() < 4_096 || workers < 2 {
            chunk_grad(&net, rows, &wws)
        } else {
            // DYNAMIC self-scheduling instead of one equal chunk per worker:
            // Apple Silicon cores are asymmetric (P+E), so a static split
            // finishes when the slowest E-core does. Workers claim fixed-size
            // chunks from an atomic counter; partial gradients land BY CHUNK
            // INDEX and reduce in ascending order, so the summation order is
            // deterministic for a given row count — independent of which
            // core ran which chunk.
            const CHUNK: usize = 32_768;
            let n_chunks = rows.len().div_ceil(CHUNK);
            let next = std::sync::atomic::AtomicUsize::new(0);
            let net_ref = &net;
            let wws_ref = &wws;
            std::thread::scope(|s| {
                let handles: Vec<_> = (0..workers)
                    .map(|_| {
                        let next = &next;
                        s.spawn(move || {
                            let mut out: Vec<(usize, Net)> = Vec::new();
                            loop {
                                let k = next
                                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                                if k >= n_chunks {
                                    break;
                                }
                                let lo = k * CHUNK;
                                let hi = (lo + CHUNK).min(rows.len());
                                out.push((k, chunk_grad(net_ref, &rows[lo..hi],
                                                        &wws_ref[lo..hi])));
                            }
                            out
                        })
                    })
                    .collect();
                let mut parts: Vec<Option<Net>> = (0..n_chunks).map(|_| None).collect();
                for h in handles {
                    if let Ok(chunks) = h.join() {
                        for (k, g) in chunks {
                            parts[k] = Some(g);
                        }
                    }
                }
                let mut total = Net::zero();
                for p in parts.into_iter().flatten() {
                    add_grad(&mut total, &p);
                }
                total
            })
        };
        adam(&mut net.b2, g.b2 / n, &mut m.b2, &mut v.b2, ep, lr);
        for j in 0..NH {
            adam(&mut net.w2[j], g.w2[j] / n, &mut m.w2[j], &mut v.w2[j], ep, lr);
            adam(&mut net.b1[j], g.b1[j] / n, &mut m.b1[j], &mut v.b1[j], ep, lr);
            for i in 0..NI {
                adam(&mut net.w1[j][i], g.w1[j][i] / n, &mut m.w1[j][i], &mut v.w1[j][i], ep, lr);
            }
        }
    }
    net
}

fn rmse(net: &Net, rows: &[Row]) -> f64 {
    if rows.is_empty() {
        return 0.0;
    }
    let se: f64 = rows.iter().map(|r| (forward(net, &r.x).0 - r.y).powi(2)).sum();
    (se / rows.len() as f64).sqrt()
}

// ---------------------------------------------------------------- output

fn write_head(net: &Net, version: i64, rows: usize, path: &str) {
    let mut s = String::from("{\"w1\":[");
    for (j, row) in net.w1.iter().enumerate() {
        if j > 0 {
            s.push(',');
        }
        s.push('[');
        for (i, val) in row.iter().enumerate() {
            if i > 0 {
                s.push(',');
            }
            s.push_str(&val.to_string());
        }
        s.push(']');
    }
    s.push_str("],\"b1\":[");
    for (j, val) in net.b1.iter().enumerate() {
        if j > 0 {
            s.push(',');
        }
        s.push_str(&val.to_string());
    }
    s.push_str("],\"w2\":[");
    for (j, val) in net.w2.iter().enumerate() {
        if j > 0 {
            s.push(',');
        }
        s.push_str(&val.to_string());
    }
    s.push_str(&format!(
        "],\"b2\":{},\"version\":{},\"in\":{},\"hidden\":{},\"rows\":{}}}",
        net.b2, version, NI, NH, rows
    ));
    let tmp = format!("{path}.tmp");
    if fs::write(&tmp, &s).is_ok() {
        let _ = fs::rename(&tmp, path); // atomic drop-in for the app
    }
}

fn next_version(models_dir: &str) -> i64 {
    let vf = format!("{models_dir}/version.txt");
    let v = fs::read_to_string(&vf).ok().and_then(|s| s.trim().parse::<i64>().ok()).unwrap_or(0) + 1;
    let _ = fs::write(&vf, v.to_string());
    v
}

fn main() {
    let home = env::var("HOME").unwrap_or_default();
    let app_support = format!("{home}/Library/Application Support");
    let csv = format!("{app_support}/flows_training_export.csv");
    let head_out = format!("{app_support}/flows_route_head.json");
    let models = "models";
    let _ = fs::create_dir_all(models);
    let _ = fs::create_dir_all(&app_support);

    let mut rows = seed_rows();
    let n_seed = rows.len();
    let real = read_csv(&csv);
    let n_real = real.len();
    rows.extend(real);
    eprintln!("training on {} rows ({n_real} real on-device, {n_seed} seed)", rows.len());

    // Deterministic 90/10 split (every 10th row -> validation): the held-out
    // number is what generalization actually looks like.
    let mut tr: Vec<Row> = Vec::with_capacity(rows.len());
    let mut va: Vec<Row> = Vec::new();
    for (i, r) in rows.into_iter().enumerate() {
        if i % 10 == 9 { va.push(r) } else { tr.push(r) }
    }
    let t0 = std::time::Instant::now();
    let net = train(&tr, 400, 0.02);
    eprintln!(
        "  train RMSE = {:.4} | val RMSE = {:.4} | {:.1}s on {} threads",
        rmse(&net, &tr), rmse(&net, &va), t0.elapsed().as_secs_f64(),
        std::thread::available_parallelism().map(|p| p.get()).unwrap_or(1));

    let version = next_version(models);
    write_head(&net, version, tr.len() + va.len(), &head_out);
    write_head(&net, version, tr.len() + va.len(), &format!("{models}/route_head_v{version}.json"));
    eprintln!("  wrote v{version} -> {head_out}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn training_reduces_error_and_head_is_valid() {
        let rows = seed_rows();
        let net = train(&rows, 400, 0.02);
        // The seed patterns are learnable → RMSE well under a naive 0.5.
        assert!(rmse(&net, &rows) < 0.2, "seed model failed to fit");
        // Forward matches Swift LearnedHead: relu hidden, sigmoid output ∈ (0,1).
        let p = forward(&net, &features(45.0, -93.0, 45.2, -93.1, 0.0, false)).0;
        assert!(p > 0.0 && p < 1.0);
    }

    #[test]
    fn features_match_swift_contract() {
        let f = features(43.0, -89.0, 44.0, -88.0, 0.0, false);
        assert!((f[0] - 0.0).abs() < 1e-12); // sin(0)
        assert!((f[1] - 1.0).abs() < 1e-12); // cos(0)
        assert!((f[2] - 43.0 / 90.0).abs() < 1e-12);
        assert!((f[4] - (-89.0 / 180.0)).abs() < 1e-12); // v2: origin longitude
        assert!((f[5] - (-88.0 / 180.0)).abs() < 1e-12); // v2: dest longitude
        assert_eq!(f[7], 0.0); // crossCountry moved to the tail
        assert_eq!(NI, 8);
        // Longitude separates same-latitude places (the Phoenix/Moore fix).
        let phx = features(33.45, -112.07, 33.45, -112.07, 26.0, false);
        let moore = features(33.45, -97.49, 33.45, -97.49, 26.0, false);
        assert!(phx != moore);
    }
}
