// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! bench — pure-std timing over fixed seeded corpora for the native hot
//! paths, filling the measurement gap left when the R harness retired.
//! Deterministic inputs (LCG-seeded), medians over repeated runs, zero
//! dependencies. Reported, never asserted — this is a thermometer, not a
//! gate; the correctness gates live in the test suites.
//!
//! The polyline bake-off here is what RETIRED the hand-asm kernel
//! (2026-07-19: asm 3.20 ns/byte vs raw-pointer portable 2.59 — rustc
//! out-scheduled it). The two remaining kernels keep each other honest.

use flows_core::polyline::bench as pk;
use flows_core::routing::CsrGraph;
use flows_core::ch::ContractionHierarchy;
use std::time::Instant;

struct Lcg(u64);
impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0
    }
    fn f64(&mut self) -> f64 {
        (self.next() >> 11) as f64 / (1u64 << 53) as f64
    }
}

/// Encode one signed value as a zigzag base-63 varint (polyline wire format).
fn encode_value(v: i64, out: &mut Vec<u8>) {
    let mut u = ((v << 1) ^ (v >> 63)) as u64;
    loop {
        let mut chunk = (u & 0x1f) as u8;
        u >>= 5;
        if u > 0 {
            chunk |= 0x20;
        }
        out.push(chunk + 63);
        if u == 0 {
            break;
        }
    }
}

/// Median-of-runs wall time for `f`, in nanoseconds per corpus pass.
fn time<F: FnMut()>(runs: usize, mut f: F) -> u128 {
    let mut samples: Vec<u128> = Vec::with_capacity(runs);
    for _ in 0..runs {
        let t = Instant::now();
        f();
        samples.push(t.elapsed().as_nanos());
    }
    samples.sort_unstable();
    samples[runs / 2]
}

fn main() {
    // ---- polyline corpus: 2,000 route-like polylines, ~200 pts each ----
    let mut rng = Lcg(4708);
    let mut corpus: Vec<Vec<u8>> = Vec::new();
    let mut total_deltas = 0usize;
    for _ in 0..2_000 {
        let n = 50 + (rng.f64() * 300.0) as usize;
        let mut enc = Vec::new();
        for _ in 0..n {
            // Dense route deltas: mostly small (1-2 byte varints), occasional
            // large jump — the shape real MapKit polylines have.
            let mag = if rng.f64() < 0.05 { 500_000.0 } else { 300.0 };
            let d = ((rng.f64() - 0.5) * 2.0 * mag) as i64;
            encode_value(d, &mut enc);
            total_deltas += 1;
        }
        corpus.push(enc);
    }
    let bytes: usize = corpus.iter().map(Vec::len).sum();
    println!("polyline corpus: {} polylines, {} deltas, {} bytes", corpus.len(), total_deltas, bytes);

    let mut sink = 0i64; // defeat dead-code elimination
    let mut out: Vec<i64> = Vec::with_capacity(4_096);

    let t_rust = time(21, || {
        for enc in &corpus {
            out.clear();
            pk::deltas_rust(enc, &mut out);
            sink ^= out.last().copied().unwrap_or(0);
        }
    });
    let t_raw = time(21, || {
        for enc in &corpus {
            out.clear();
            pk::deltas_rust_rawptr(enc, &mut out);
            sink ^= out.last().copied().unwrap_or(0);
        }
    });
    println!("decode_deltas  portable(Vec::push): {:>9} ns/pass  ({:.2} ns/byte)",
             t_rust, t_rust as f64 / bytes as f64);
    println!("decode_deltas  portable(raw ptr)  : {:>9} ns/pass  ({:.2} ns/byte)",
             t_raw, t_raw as f64 / bytes as f64);
    // ---- CH: preprocess + query on a seeded weighted grid ----
    let side = 60usize; // 3,600 nodes, ~7,080 undirected edges
    let n = side * side;
    let mut edges: Vec<(u32, u32, f64)> = Vec::new();
    for y in 0..side {
        for x in 0..side {
            let a = (y * side + x) as u32;
            if x + 1 < side {
                edges.push((a, a + 1, 1.0 + rng.f64()));
            }
            if y + 1 < side {
                edges.push((a, a + side as u32, 1.0 + rng.f64()));
            }
        }
    }
    let mut adj: Vec<Vec<(u32, f64)>> = vec![Vec::new(); n];
    for &(a, b, w) in &edges {
        adj[a as usize].push((b, w));
        adj[b as usize].push((a, w));
    }
    // CSR straight from the adjacency (pub-field construction, as ffi does).
    let mut offsets: Vec<u32> = Vec::with_capacity(n + 1);
    let mut targets: Vec<u32> = Vec::new();
    let mut weights: Vec<f64> = Vec::new();
    offsets.push(0);
    for nbrs in &adj {
        for &(t, w) in nbrs {
            targets.push(t);
            weights.push(w);
        }
        offsets.push(targets.len() as u32);
    }
    let g = CsrGraph { offsets, targets, weights };
    let t0 = Instant::now();
    let ch = ContractionHierarchy::preprocess(&g);
    let prep_ms = t0.elapsed().as_millis();
    let queries: Vec<(usize, usize)> =
        (0..500).map(|_| ((rng.next() as usize) % n, (rng.next() as usize) % n)).collect();
    let mut acc = 0.0f64;
    let t_q = time(11, || {
        for &(s, t) in &queries {
            acc += ch.query(s, t);
        }
    });
    println!("ch: preprocess {n} nodes = {prep_ms} ms; {} queries = {} ns/pass ({} ns/query)",
             queries.len(), t_q, t_q / queries.len() as u128);
    // Keep the sinks alive.
    if sink == i64::MIN && acc.is_nan() {
        println!("(unreachable sink print {sink} {acc})");
    }
}
