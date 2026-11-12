// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the planning map's risk-area geometry:
//! records from the ORIGINAL `RiskAreaFallback` at commit ORIGINAL_COMMIT,
//! before the rules moved to `flows_core::risk_area`.
//!
//! Every answer must be the same bits, except the circle's vertices: Swift's
//! Release build fuses the circle's `sin` and `cos` into `__sincos_stret`,
//! which can be one unit in the last place off the standalone calls Rust
//! makes. A vertex there must be within two units in the last place of
//! Swift's plus 1e-15 of the circle's radius in degrees (far under a
//! micrometre on the ground), and a non-finite one must be non-finite the
//! same way.

use flows_core::risk_area::{
    blob_waits, centroid, circle_ring, contains, icon_anchor, in_zip_box, interior_samples,
    lattice, Point,
};
use std::collections::HashMap;

const ORIGINAL_COMMIT: &str = "f7ea216";
const RECORDS: [(&str, usize); 4] = [("z", 1561), ("l", 1817), ("c", 626), ("r", 723)];
const LIMITS: [i64; 9] = [-1, 0, 1, 2, 3, 5, 9, 16, 17];
const DEFAULT_LIMIT: i64 = 9;
const DEFAULT_POINTS: i64 = 32;

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}

fn hx(x: f64) -> String {
    format!("{:x}", x.to_bits())
}

fn pt(p: Point) -> String {
    format!("{}:{}", hx(p.0), hx(p.1))
}

fn pts(a: &[Point]) -> String {
    a.iter().map(|&p| pt(p)).collect::<Vec<_>>().join(",")
}

fn parse_pts(f: &str) -> Vec<Point> {
    if f.is_empty() {
        return Vec::new();
    }
    f.split(',')
        .map(|p| {
            let (a, b) = p.split_once(':').expect("lat:lon");
            (d(a), d(b))
        })
        .collect()
}

fn b01(b: bool) -> &'static str {
    if b {
        "1"
    } else {
        "0"
    }
}

/// One unit in the last place of `x`'s magnitude.
fn ulp(x: f64) -> f64 {
    let a = x.abs();
    f64::from_bits(a.to_bits() + 1) - a
}

/// A circle coordinate Rust computed against the one Swift printed: the same
/// bits, the same kind of non-finite, or within the sincos tolerance.
fn close(rust: f64, swift: f64, radius_degrees: f64) -> bool {
    if rust.to_bits() == swift.to_bits() {
        return true;
    }
    if !rust.is_finite() || !swift.is_finite() {
        return rust.is_nan() && swift.is_nan()
            || rust.is_infinite() && swift.is_infinite() && rust.signum() == swift.signum();
    }
    (rust - swift).abs() <= 2.0 * ulp(swift) + radius_degrees.abs() * 1e-15
}

#[test]
fn rust_matches_the_frozen_swift_risk_area_fallback_oracle() {
    let fixture = include_str!("fixtures/swift_risk_area_fallback_oracle.tsv");
    assert!(
        fixture.contains(ORIGINAL_COMMIT),
        "the header names the original commit"
    );
    let mut counts: HashMap<&str, usize> = HashMap::new();
    let mut bad = Vec::new();
    let mut circle_off_by_bits = 0usize;
    for line in fixture.lines().filter(|l| !l.starts_with('#')) {
        let f: Vec<&str> = line.split('\t').collect();
        *counts.entry(f[0]).or_default() += 1;
        match f[0] {
            "z" => {
                let (lat, lon) = (d(f[1]), d(f[2]));
                let mut got = vec![b01(in_zip_box(lat, lon))];
                for done in [false, true] {
                    for placed in [false, true] {
                        got.push(b01(blob_waits(lat, lon, done, placed)));
                    }
                }
                if got.iter().copied().ne(f[3..].iter().copied()) {
                    bad.push(format!("{line}\n  rust: {}", got.join("\t")));
                }
            }
            "l" => {
                let per: i64 = f[5].parse().expect("perSide");
                let got = pts(&lattice(d(f[1]), d(f[2]), d(f[3]), d(f[4]), per));
                if got != f[6] {
                    bad.push(format!("{line}\n  rust: {got}"));
                }
            }
            "c" => {
                let (lat, lon, r) = (d(f[1]), d(f[2]), d(f[3]));
                let points = if f[4] == "d" {
                    DEFAULT_POINTS
                } else {
                    f[4].parse().expect("points")
                };
                let got = circle_ring(lat, lon, r, points);
                let want = parse_pts(f[5]);
                let d_lat = r / 111_320.0;
                let d_lon = r / (111_320.0 * (lat * std::f64::consts::PI / 180.0).cos().max(1e-6));
                let ok = got.len() == want.len()
                    && got.iter().zip(&want).all(|(g, w)| {
                        if g.0.to_bits() != w.0.to_bits() || g.1.to_bits() != w.1.to_bits() {
                            circle_off_by_bits += 1;
                        }
                        close(g.0, w.0, d_lat) && close(g.1, w.1, d_lon)
                    });
                if !ok {
                    bad.push(format!("{line}\n  rust: {}", pts(&got)));
                }
            }
            "r" => {
                let ring = parse_pts(f[1]);
                let mut samples: Vec<String> = LIMITS
                    .iter()
                    .map(|&l| pts(&interior_samples(&ring, l)))
                    .collect();
                samples.push(pts(&interior_samples(&ring, DEFAULT_LIMIT)));
                let probes = parse_pts(f[5]);
                let got = [
                    pt(centroid(&ring)),
                    pt(icon_anchor(&ring)),
                    samples.join("|"),
                    f[5].to_owned(),
                    probes.iter().map(|&p| b01(contains(&ring, p))).collect(),
                ];
                if got.iter().map(String::as_str).ne(f[2..].iter().copied()) {
                    bad.push(format!("{line}\n  rust: {}", got.join("\t")));
                }
            }
            other => panic!("unknown record kind {other}"),
        }
    }
    for (k, n) in RECORDS {
        assert_eq!(counts.get(k).copied().unwrap_or(0), n, "{k} records");
    }
    let total: usize = RECORDS.iter().map(|(_, n)| n).sum();
    eprintln!("circle vertices off by bits (within tolerance): {circle_off_by_bits}");
    assert!(
        bad.is_empty(),
        "{} of {total} records differ:\n{}",
        bad.len(),
        bad.iter().take(6).cloned().collect::<Vec<_>>().join("\n")
    );
}

/// The original's `contains` answers outside for a ring under three points
/// (`guard ring.count >= 3`). A two-point ring is the case the fixture
/// cannot reach: its two edges are the same segment walked both ways, and
/// rounding can put their crossings an ulp apart, so the even–odd test alone
/// would answer inside for a point between them. The probes sit on both
/// crossings and their neighbours.
#[test]
fn a_ring_under_three_points_holds_nothing() {
    let vals: [f64; 9] = [
        -3.7,
        -1.0,
        -0.1,
        0.0,
        0.3,
        1.0 / 3.0,
        0.7,
        2.9,
        41.123_456_789,
    ];
    let near = |x: f64| [x.next_down(), x, x.next_up()];
    let mut gaps = 0usize;
    for &a0 in &vals {
        for &a1 in &vals {
            for &b0 in &vals {
                for &b1 in &vals {
                    let ring = [(a0, a1), (b0, b1)];
                    for &p0 in &vals {
                        let x1 = a1 + (p0 - a0) / (b0 - a0) * (b1 - a1);
                        let x2 = b1 + (p0 - b0) / (a0 - b0) * (a1 - b1);
                        if x1.to_bits() != x2.to_bits() {
                            gaps += 1;
                        }
                        for p1 in near(x1).into_iter().chain(near(x2)) {
                            assert!(!contains(&ring, (p0, p1)), "{ring:?} {p0} {p1}");
                            assert!(!contains(&ring[..1], (p0, p1)));
                        }
                    }
                }
            }
        }
    }
    assert!(!contains(&[], (0.0, 0.0)));
    assert!(
        gaps > 0,
        "some probe sits between two crossings an ulp apart"
    );
}
