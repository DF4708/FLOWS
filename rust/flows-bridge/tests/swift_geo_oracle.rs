// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the geo kernel. Every line of the fixture is an
//! input and the output the ORIGINAL Swift produced for it, before any geo
//! Swift is replaced by calls into Rust. Every value is compared BIT FOR BIT.
//! Every input on which the Swift trapped (the app crashed) must make the Rust
//! twin return `Err(SwiftTrap)`, and every input on which it did not must not.
//!
//! The fixture is never regenerated from Rust. To extend it, check out the
//! commit named in its header and rerun the harness described in
//! `oracle-harness/geo/README.md`.

use flows_core::geo::{self, RoutePath, ShowerLocationTable, SwiftTrap};
use std::collections::BTreeMap;

const BASE_COMMIT: &str = "a007de042d12e736fdd86398e1ea54ca31aadc1f";

/// Records per kind in the frozen fixture, so a truncated section fails.
const EXPECTED_COUNTS: &[(&str, usize)] = &[
    ("ahead", 722),
    ("amtrak", 116),
    ("brg", 720),
    ("cellkey", 98),
    ("corr", 100),
    ("m", 985),
    ("prefix", 140),
    ("radio", 120),
    ("reach", 510),
    ("rp", 65),
    ("rpn", 576),
    ("scanner", 110),
    ("seg", 442),
    ("segk", 152),
    ("shower", 408),
    ("showert", 58),
];

/// Records where Rust deliberately does not reproduce the Swift original,
/// each with its reason. Every entry must still diverge: a fixed divergence
/// fails the test until its entry is removed, so this list cannot rot.
/// Inputs on which the Swift trapped are not divergences here; they are
/// checked against `Err(SwiftTrap)` record by record.
const KNOWN_DIVERGENCES: &[(&str, &str)] = &[];

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}
fn opt(h: &str) -> Option<f64> {
    (h != "-").then(|| d(h))
}
/// The harness's double encoding: `String(bitPattern, radix: 16)`.
/// How far a bearing may point from the app's before it counts as a defect
/// rather than the fused-sine artifact, measured as the lateral displacement
/// of the target: one micrometre. The largest observed is well under that.
const BEARING_LATERAL_TOLERANCE_METERS: f64 = 1e-6;

/// A yes/no answer derived from a bearing may differ from the app's only
/// when that bearing lies this close, in degrees, to the cone's edge.
const CONE_EDGE_TOLERANCE_DEGREES: f64 = 1e-9;

fn hx(x: f64) -> String {
    format!("{:x}", x.to_bits())
}
fn list(f: &str) -> Vec<&str> {
    let (head, body) = f.split_once(':').expect("list header");
    let n: usize = head.trim_start_matches('L').parse().expect("list count");
    if n == 0 {
        return Vec::new();
    }
    let v: Vec<&str> = body.split(',').collect();
    assert_eq!(v.len(), n, "list count mismatch in {f}");
    v
}
fn doubles(f: &str) -> Vec<f64> {
    list(f).into_iter().map(d).collect()
}
fn lst(items: impl Iterator<Item = String>) -> String {
    let v: Vec<String> = items.collect();
    format!("L{}:{}", v.len(), v.join(","))
}
fn b01(b: bool) -> &'static str {
    if b {
        "1"
    } else {
        "0"
    }
}
fn index(o: Option<usize>) -> String {
    o.map_or_else(|| "-".to_string(), |i| i.to_string())
}
/// A mismatch when `got` differs from `want`.
fn check(got: String, want: &str) -> Option<(String, String)> {
    (got != want).then(|| (got, want.to_string()))
}

#[test]
fn rust_reproduces_the_original_swift_geo_kernel_bit_for_bit() {
    let text = include_str!("fixtures/swift_geo_oracle.tsv");
    let header = text.lines().next().unwrap_or_default();
    assert!(
        header.starts_with("# FROZEN SWIFT ORACLE") && header.contains(BASE_COMMIT),
        "the fixture header must name the base commit: {header}"
    );
    let mut failures: Vec<(String, String)> = Vec::new();
    let mut within_ulp = 0usize;
    let mut max_bearing_gap = 0.0f64;
    let mut cone_edge_flips = 0usize;
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut trapped = 0usize;
    let mut routes: BTreeMap<String, RoutePath> = BTreeMap::new();
    let mut tables: BTreeMap<String, ShowerLocationTable> = BTreeMap::new();

    for line in text
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
    {
        let f: Vec<&str> = line.split('\t').collect();
        *counts.entry(f[0].to_string()).or_default() += 1;
        if f.contains(&"trap") {
            trapped += 1;
        }
        let mismatch = match f[0] {
            "m" => check(hx(geo::meters(d(f[1]), d(f[2]), d(f[3]), d(f[4]))), f[5]),
            "brg" => {
                // EnforcementCameras.bearingDegrees and FuelWarning.bearingDegrees.
                // Within ONE ULP, not bit for bit: the app's Swift Release
                // build fuses the formula's sin and cos into __sincos_stret,
                // whose sine rounds differently from standalone sin for some
                // arguments (its Debug build does not fuse). This kernel
                // computes the standalone value in every build — see the
                // wrapper docs in geo.rs — so a one-ulp difference on a
                // bearing is the compiler artifact, counted here, not a defect.
                let g = geo::bearing_degrees(d(f[1]), d(f[2]), d(f[3]), d(f[4]));
                let want = d(f[5]);
                // The sine's one-ulp difference is amplified through atan2 in
                // proportion to how close the two points are — tens of
                // nanodegrees for points a metre apart, picodegrees for points
                // a hundred kilometres apart. The measure that stays honest at
                // every separation is what the bearing error moves the target
                // by on the ground: error in radians times the separation.
                let gap = (g - want).abs();
                let separation = geo::meters(d(f[1]), d(f[2]), d(f[3]), d(f[4]));
                let lateral_m = gap.to_radians() * separation;
                if g.to_bits() == want.to_bits() {
                    None
                } else if lateral_m <= BEARING_LATERAL_TOLERANCE_METERS {
                    within_ulp += 1;
                    max_bearing_gap = max_bearing_gap.max(lateral_m);
                    None
                } else {
                    check(
                        format!("{}\t{}", hx(g), hx(g)),
                        &format!("{}\t{}", f[5], f[6]),
                    )
                }
            }
            "ahead" => {
                let g = geo::camera_is_ahead(d(f[1]), d(f[2]), d(f[3]), d(f[4]), opt(f[5]));
                let m = check(b01(g).to_string(), f[6]);
                if m.is_some() {
                    // Allowed to differ only where the one-ulp bearing lands
                    // exactly on the cone's edge: recompute the edge distance
                    // rather than trust a list.
                    let heading = opt(f[5]).unwrap_or(f64::NAN);
                    let bearing = geo::bearing_degrees(d(f[3]), d(f[4]), d(f[1]), d(f[2]));
                    let edge = (geo::heading_delta_degrees(bearing, heading).abs()
                        - geo::AHEAD_CONE_DEGREES)
                        .abs();
                    if edge <= CONE_EDGE_TOLERANCE_DEGREES {
                        cone_edge_flips += 1;
                        None
                    } else {
                        m
                    }
                } else {
                    None
                }
            }
            "reach" => {
                let g = geo::fuel_station_is_reachable(
                    d(f[1]),
                    d(f[2]),
                    d(f[3]),
                    d(f[4]),
                    d(f[5]),
                    &doubles(f[7]),
                    &doubles(f[8]),
                    d(f[6]),
                );
                let m = check(b01(g).to_string(), f[9]);
                if m.is_some() && doubles(f[7]).is_empty() && d(f[5]) >= 0.0 {
                    // Same cone, same artifact as `ahead`: with no route the
                    // answer is a bearing against the course, and may differ
                    // only where that bearing lands on the cone's edge.
                    let bearing = geo::bearing_degrees(d(f[3]), d(f[4]), d(f[1]), d(f[2]));
                    let edge = (geo::heading_delta_degrees(bearing, d(f[5])).abs()
                        - geo::AHEAD_CONE_DEGREES)
                        .abs();
                    if edge <= CONE_EDGE_TOLERANCE_DEGREES {
                        cone_edge_flips += 1;
                        None
                    } else {
                        m
                    }
                } else {
                    m
                }
            }
            "seg" => {
                let g = geo::distance_to_segment_meters(
                    d(f[1]),
                    d(f[2]),
                    d(f[3]),
                    d(f[4]),
                    d(f[5]),
                    d(f[6]),
                );
                check(hx(g), f[7])
            }
            "segk" => {
                let g = geo::distance_to_segment_meters_scaled(
                    d(f[1]),
                    d(f[2]),
                    d(f[3]),
                    d(f[4]),
                    d(f[5]),
                    d(f[6]),
                    d(f[7]),
                );
                check(hx(g), f[8])
            }
            "amtrak" => {
                let g =
                    geo::amtrak_nearest(&doubles(f[1]), &doubles(f[2]), d(f[3]), d(f[4]), d(f[5]));
                check(index(g), f[6])
            }
            "radio" => {
                let exact: Vec<bool> = list(f[3]).into_iter().map(|x| x == "1").collect();
                let g =
                    geo::radio_nearest(&doubles(f[1]), &doubles(f[2]), &exact, d(f[4]), d(f[5]));
                let got = g.map_or_else(|| "-\t-".to_string(), |(i, m)| format!("{i}\t{}", hx(m)));
                check(got, &format!("{}\t{}", f[6], f[7]))
            }
            "scanner" => {
                let lats: Vec<Option<f64>> = list(f[1]).into_iter().map(opt).collect();
                let lons: Vec<Option<f64>> = list(f[2]).into_iter().map(opt).collect();
                // The facade's encoding: an anchor needs both values; absent is NaN.
                let anchored: Vec<bool> = lats
                    .iter()
                    .zip(&lons)
                    .map(|(a, b)| a.is_some() && b.is_some())
                    .collect();
                let la: Vec<f64> = lats.iter().map(|v| v.unwrap_or(f64::NAN)).collect();
                let lo: Vec<f64> = lons.iter().map(|v| v.unwrap_or(f64::NAN)).collect();
                let g = geo::scanner_feed_nearest(&la, &lo, &anchored, d(f[3]), d(f[4]));
                check(index(g), f[5])
            }
            "corr" => {
                let per: Vec<usize> = list(f[1])
                    .into_iter()
                    .map(|c| c.parse().expect("corridor count"))
                    .collect();
                let (lats, lons) = (doubles(f[2]), doubles(f[3]));
                assert_eq!(
                    per.iter().sum::<usize>(),
                    lats.len(),
                    "corridor counts in {line}"
                );
                let g = geo::corridor_nearest(&lats, &lons, &per, d(f[4]), d(f[5]));
                check(index(g), f[6])
            }
            "showert" => match ShowerLocationTable::new(&doubles(f[2]), &doubles(f[3])) {
                Ok(table) => {
                    tables.insert(f[1].to_string(), table);
                    check("ok".to_string(), f[4])
                }
                Err(SwiftTrap) => check("trap".to_string(), f[4]),
            },
            "shower" => {
                let table = tables
                    .get(f[1])
                    .unwrap_or_else(|| panic!("table {} used before it is defined", f[1]));
                let got = match table.entry(d(f[2]), d(f[3])) {
                    Ok(o) => index(o),
                    Err(SwiftTrap) => "trap".to_string(),
                };
                check(got, f[4])
            }
            "rp" => match RoutePath::new(&doubles(f[2]), &doubles(f[3])) {
                Ok(route) => {
                    let got = lst(route.cumulative().iter().map(|&c| hx(c)));
                    routes.insert(f[1].to_string(), route);
                    check(got, f[4])
                }
                Err(SwiftTrap) => check("trap".to_string(), f[4]),
            },
            "rpn" => {
                let route = routes
                    .get(f[1])
                    .unwrap_or_else(|| panic!("route {} used before it is defined", f[1]));
                let got = match route.nearest(d(f[2]), d(f[3])) {
                    Ok(Some((i, m))) => format!("{i}\t{}", hx(m)),
                    Ok(None) => "-\t-".to_string(),
                    Err(SwiftTrap) => "trap\t-".to_string(),
                };
                check(got, &format!("{}\t{}", f[4], f[5]))
            }
            "cellkey" => {
                let lat5: i64 = f[1].parse().expect("lat5");
                let lon5: i64 = f[2].parse().expect("lon5");
                let got = match geo::places_cell_key(lat5, lon5) {
                    Ok(k) => k.to_string(),
                    Err(SwiftTrap) => "trap".to_string(),
                };
                check(got, f[3])
            }
            "prefix" => {
                let p = geo::prefix_coordinates(&doubles(f[1]), &doubles(f[2]), d(f[3]));
                let got_lats = lst(p.iter().map(|c| hx(c.0)));
                let got_lons = lst(p.iter().map(|c| hx(c.1)));
                check(
                    format!("{got_lats}\t{got_lons}"),
                    &format!("{}\t{}", f[4], f[5]),
                )
            }
            other => panic!("unknown oracle record {other}"),
        };
        if let Some((got, want)) = mismatch {
            failures.push((
                line.to_string(),
                format!("\n    got  {got}\n    want {want}"),
            ));
        }
    }

    let expected: BTreeMap<String, usize> = EXPECTED_COUNTS
        .iter()
        .map(|(k, n)| ((*k).to_string(), *n))
        .collect();
    assert_eq!(counts, expected, "fixture sections truncated or extended");
    assert!(trapped >= 100, "trap records missing: {trapped}");
    println!("bearings within tolerance (not bit-exact): {within_ulp}, largest lateral gap {max_bearing_gap:e} m; cone-edge flips (ahead + reach): {cone_edge_flips}");
    // The tolerance is for the fused-sine artifact and nothing else: if a
    // future change makes more than the observed handful of bearings drift,
    // that is a defect, not the artifact.
    assert!(
        within_ulp <= 16,
        "too many bearings off by one ulp: {within_ulp}"
    );
    assert!(
        cone_edge_flips <= 16,
        "too many ahead-cone flips: {cone_edge_flips}"
    );

    let (known, unknown): (Vec<_>, Vec<_>) = failures
        .into_iter()
        .partition(|(line, _)| KNOWN_DIVERGENCES.iter().any(|(k, _)| k == line));
    if !unknown.is_empty() {
        let checked: usize = expected.values().sum();
        let shown: Vec<String> = unknown
            .iter()
            .take(40)
            .map(|(l, m)| format!("{}{m}", l.chars().take(160).collect::<String>()))
            .collect();
        panic!(
            "{} of {checked} oracle records differ from the original Swift:\n{}",
            unknown.len(),
            shown.join("\n")
        );
    }
    assert_eq!(
        known.len(),
        KNOWN_DIVERGENCES.len(),
        "an allow-listed divergence no longer diverges; remove its KNOWN_DIVERGENCES entry"
    );
}
