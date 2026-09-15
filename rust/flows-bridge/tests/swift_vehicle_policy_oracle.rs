// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for vehicle policy: every line of the fixture is
//! an input and the output the ORIGINAL Swift implementation produced for it,
//! before the Swift was replaced by calls into Rust. Every function is
//! compared BIT FOR BIT, through the same bridge functions the Swift facades
//! call and with the same encodings they build.
//!
//! The fixture is never regenerated from Rust. To extend it, check out the
//! commit named in its header and rerun the Swift harness described in
//! `oracle-harness/vehicle_policy/README.md`.

use flows_bridge::vehicle_policy::*;
use flows_core::vehicle_policy as vp;

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}
fn opt(h: &str) -> Option<f64> {
    (h != "-").then(|| d(h))
}
fn s(h: &str) -> String {
    let hex = h
        .strip_prefix("s:")
        .unwrap_or_else(|| panic!("bad string field {h}"));
    let bytes: Vec<u8> = (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).expect("hex byte"))
        .collect();
    String::from_utf8(bytes).expect("oracle strings are UTF-8")
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
fn bits(x: f64) -> String {
    format!("{:016x}", x.to_bits())
}
fn obits(x: Option<f64>) -> Option<u64> {
    x.map(f64::to_bits)
}
/// Decode an answer that crosses as NaN for absent.
fn nan_absent(x: f64) -> Option<f64> {
    (!x.is_nan()).then_some(x)
}
/// The `value, has_` pair a facade builds from a Swift optional.
fn flag(x: Option<f64>) -> (f64, bool) {
    (x.unwrap_or(0.0), x.is_some())
}
fn bit(b: bool) -> &'static str {
    if b {
        "1"
    } else {
        "0"
    }
}
fn triple(item: &str) -> [f64; 3] {
    let v: Vec<f64> = item.split('/').map(d).collect();
    assert_eq!(v.len(), 3, "bad segment {item}");
    [v[0], v[1], v[2]]
}
fn triple_bits(flat: &[f64]) -> Vec<u64> {
    flat.iter().map(|x| x.to_bits()).collect()
}
fn ranges(body: &str) -> Vec<(u32, u32)> {
    list(body)
        .into_iter()
        .map(|r| {
            let (a, b) = r.split_once('-').expect("range");
            (
                u32::from_str_radix(a, 16).expect("range start"),
                u32::from_str_radix(b, 16).expect("range end"),
            )
        })
        .collect()
}

/// The facade's `GradeProfile.steepest`: empty in, empty out, without crossing.
fn steepest_facade(flat: &[f64], top: i64) -> Vec<f64> {
    if flat.is_empty() {
        return Vec::new();
    }
    flows_vehicle_policy_grade_steepest(flat, top)
}
/// The facade's `GradeProfile.nextSteep`: the chosen segment's triple.
fn next_steep_facade(mile: f64, flat: &[f64], threshold: f64, lookahead: f64) -> Option<Vec<u64>> {
    if flat.is_empty() {
        return None;
    }
    let idx = flows_vehicle_policy_grade_next_steep_index(mile, flat, threshold, lookahead);
    usize::try_from(idx)
        .ok()
        .and_then(|i| flat.get(3 * i..3 * i + 3))
        .map(triple_bits)
}

#[allow(clippy::too_many_arguments)]
fn drive(
    speed: f64,
    accel: f64,
    grade: f64,
    wind: f64,
    from: Option<f64>,
    heading: Option<f64>,
    cruise: f64,
    city: Option<f64>,
    highway: Option<f64>,
    loaded: Option<f64>,
    vehicle: Option<f64>,
    towing: bool,
    fuel: Option<f64>,
) -> (f64, u8) {
    let (f, hf) = flag(from);
    let (h, hh) = flag(heading);
    let (c, hc) = flag(city);
    let (hw, hhw) = flag(highway);
    let (l, hl) = flag(loaded);
    let (v, hv) = flag(vehicle);
    let (fu, hfu) = flag(fuel);
    (
        flows_vehicle_policy_drive_score(
            speed, accel, grade, wind, f, hf, h, hh, cruise, c, hc, hw, hhw, l, hl, v, hv, towing,
            fu, hfu,
        ),
        flows_vehicle_policy_drive_verdict_code(
            speed, accel, grade, wind, f, hf, h, hh, cruise, c, hc, hw, hhw, l, hl, v, hv, towing,
            fu, hfu,
        ),
    )
}

/// Records where Rust deliberately does not reproduce the Swift original,
/// each with its reason. Every entry must still diverge — a fixed divergence
/// fails the test until its entry is removed, so this list cannot rot.
const KNOWN_DIVERGENCES: &[(&str, &str)] = &[];

#[test]
fn rust_reproduces_the_original_swift_vehicle_policy_bit_for_bit() {
    let text = include_str!("fixtures/swift_vehicle_policy_oracle.tsv");
    let lines: Vec<&str> = text
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
        .collect();
    let palette = |name: &str| -> Vec<f64> {
        let line = lines
            .iter()
            .find(|l| l.starts_with(&format!("palette\t{name}\t")))
            .unwrap_or_else(|| panic!("palette {name} missing"));
        list(line.split('\t').nth(2).expect("palette body"))
            .into_iter()
            .map(d)
            .collect()
    };
    let gp = palette("GP");
    let mp = palette("MP");
    let coded = |codes: &str| -> Vec<f64> {
        list(codes)
            .into_iter()
            .flat_map(|c| {
                let v: Vec<usize> = c.split('.').map(|x| x.parse().expect("code")).collect();
                [mp[v[0]], mp[v[1]], gp[v[2]]]
            })
            .collect()
    };
    let default_cruise = flows_vehicle_policy_drive_default_efficient_cruise_mph();

    let mut failures: Vec<(String, String)> = Vec::new();
    let mut checked = 0usize;
    let mut fail = |line: &str, got: String, want: String| {
        failures.push((
            line.to_string(),
            format!("\n    got  {got}\n    want {want}"),
        ));
    };
    for line in &lines {
        let line = *line;
        let f: Vec<&str> = line.split('\t').collect();
        checked += 1;
        let eqd = |got: f64, want: &str| got.to_bits() == d(want).to_bits();
        match f[0] {
            "const" => {
                let got = match f[1] {
                    "stateToleranceMph" => flows_vehicle_policy_state_tolerance_mph(),
                    "excessOverLimitMph" => flows_vehicle_policy_excess_over_limit_mph(),
                    "excessAbsoluteMph" => flows_vehicle_policy_excess_absolute_mph(),
                    "speedSignTolerance" => flows_vehicle_policy_speed_sign_tolerance_mph(),
                    "speedSignOverBy" => flows_vehicle_policy_speed_sign_over_by_mph(),
                    "pursuitDefaultSpeedMph" => flows_vehicle_policy_pursuit_default_speed_mph(),
                    "pursuitMinimumRadiusMeters" => {
                        flows_vehicle_policy_pursuit_minimum_radius_meters()
                    }
                    "pursuitMaximumElapsedSeconds" => {
                        flows_vehicle_policy_pursuit_maximum_elapsed_seconds()
                    }
                    "towingEconomyFactor" => flows_vehicle_policy_towing_economy_factor(),
                    "filterDefaultVehicleHeightMeters" => {
                        flows_vehicle_policy_filter_default_vehicle_height_meters()
                    }
                    "filterDefaultMaxGradePercent" => {
                        flows_vehicle_policy_filter_default_max_grade_percent()
                    }
                    "filterDefaultClearanceMarginMeters" => {
                        flows_vehicle_policy_filter_default_clearance_margin_meters()
                    }
                    "driveIdleSpeedMph" => flows_vehicle_policy_drive_idle_speed_mph(),
                    "driveInputsDefaultCruiseMph" => default_cruise,
                    "filterDefaultRigWeightIsNil" => {
                        // The facade keeps `rigWeightLbs: Double? = nil`; nothing crosses.
                        if f[2] != "1" {
                            fail(line, "nil".into(), f[2].into());
                        }
                        continue;
                    }
                    other => panic!("unknown const {other}"),
                };
                if !eqd(got, f[2]) {
                    fail(line, bits(got), f[2].into())
                }
            }
            "table" => {
                let want: Vec<String> = list(f[2]).into_iter().map(s).collect();
                let got = match f[1] {
                    "compassPoints" => flows_vehicle_policy_compass_points(),
                    other => panic!("unknown table {other}"),
                };
                if got != want {
                    fail(line, format!("{got:?}"), format!("{want:?}"))
                }
            }
            "palette" => {}
            "utab" => {
                let (pred, table): (fn(char) -> bool, &[u32]) = match f[1] {
                    "isNumber" => (vp::swift_is_number, vp::SWIFT_NUMBER_RANGES),
                    "attachesAfter5" | "attachesAfterDot" | "attachesAfterH" | "attachesAfterS" => {
                        (vp::swift_joins_previous, vp::SWIFT_JOINS_PREVIOUS_RANGES)
                    }
                    "prependsToM" | "prependsToK" => (
                        vp::swift_prepends_to_next,
                        vp::SWIFT_PREPENDS_TO_NEXT_RANGES,
                    ),
                    "whitespaces" => (vp::swift_is_whitespace, vp::SWIFT_WHITESPACE_RANGES),
                    other => panic!("unknown utab {other}"),
                };
                let want = ranges(f[2]);
                let embedded: Vec<(u32, u32)> =
                    table.chunks_exact(2).map(|c| (c[0], c[1])).collect();
                if embedded != want {
                    fail(
                        line,
                        "embedded table differs".into(),
                        "fixture ranges".into(),
                    );
                }
                let mut at = 0usize;
                for v in 0..=0x10_FFFFu32 {
                    let Some(c) = char::from_u32(v) else {
                        continue;
                    };
                    while at < want.len() && want[at].1 < v {
                        at += 1;
                    }
                    let inside = at < want.len() && want[at].0 <= v;
                    if pred(c) != inside {
                        fail(
                            line,
                            format!("U+{v:04X} -> {}", pred(c)),
                            inside.to_string(),
                        );
                        break;
                    }
                }
            }
            "el" => {
                let g = flows_vehicle_policy_estimated_limit_mph(d(f[1]));
                if !eqd(g, f[2]) {
                    fail(line, bits(g), f[2].into())
                }
            }
            "efl" => {
                let (p, hp) = flag(opt(f[1]));
                let g = flows_vehicle_policy_effective_limit_mph(p, hp, d(f[2]));
                if !eqd(g, f[3]) {
                    fail(line, bits(g), f[3].into())
                }
            }
            "st" | "ft" => {
                let (p, hp) = flag(opt(f[1]));
                let g = if f[0] == "st" {
                    flows_vehicle_policy_state_threshold_mph(p, hp)
                } else {
                    flows_vehicle_policy_federal_threshold_mph(p, hp)
                };
                if obits(nan_absent(g)) != obits(opt(f[2])) {
                    fail(line, bits(g), f[2].into())
                }
            }
            "sd" => {
                let (p, hp) = flag(opt(f[2]));
                let g = flows_vehicle_policy_standing_code(d(f[1]), p, hp);
                if g.to_string() != f[3] {
                    fail(line, g.to_string(), f[3].into())
                }
            }
            "cp" => {
                let idx = flows_vehicle_policy_compass_point_index(&s(f[1]));
                let got = if idx < 0 {
                    "-".to_string()
                } else {
                    idx.to_string()
                };
                if got != f[2] {
                    fail(line, got, f[2].into())
                }
            }
            "pm" => {
                let raw = s(f[1]);
                let g = flows_vehicle_policy_parse_maxspeed_mph(&raw);
                if obits(nan_absent(g)) != obits(opt(f[2])) {
                    fail(line, format!("{} for {raw:?}", bits(g)), f[2].into())
                }
            }
            "jg" => {
                let (l, hl) = flag(opt(f[2]));
                let g = flows_vehicle_policy_judge_code(d(f[1]), l, hl);
                if g.to_string() != f[3] {
                    fail(line, g.to_string(), f[3].into())
                }
            }
            "pr" => {
                let g = flows_vehicle_policy_pursuit_radius_meters(d(f[1]), d(f[2]));
                if !eqd(g, f[3]) {
                    fail(line, bits(g), f[3].into())
                }
            }
            "er" => {
                let code = match s(f[2]).as_str() {
                    "Gas" => 0,
                    "Diesel" => 1,
                    "Electric" => 2,
                    other => panic!("unknown fuel {other}"),
                };
                let v = flows_vehicle_policy_towing_estimated_ratings(d(f[1]), code);
                let got: Vec<Option<u64>> =
                    v.iter().take(3).map(|x| obits(nan_absent(*x))).collect();
                let want: Vec<Option<u64>> = f[3..6].iter().map(|h| obits(opt(h))).collect();
                let est = v.get(3).map(|x| bit(*x != 0.0));
                if v.len() != 4 || got != want || est != Some(f[6]) {
                    fail(line, format!("{v:?}"), f[3..7].join(" "))
                }
            }
            "eg" => {
                let (g, hg) = flag(opt(f[1]));
                let (t, ht) = flag(opt(f[2]));
                let (c, hc) = flag(opt(f[3]));
                let got = flows_vehicle_policy_towing_has_effective_gcwr(hg, ht, hc)
                    .then(|| flows_vehicle_policy_towing_effective_gcwr_lbs(g, hg, t, ht, c, hc));
                if obits(got) != obits(opt(f[4])) {
                    fail(line, format!("{got:?}"), f[4].into())
                }
            }
            "tc" => {
                let (g, hg) = flag(opt(f[3]));
                let (t, ht) = flag(opt(f[4]));
                let (c, hc) = flag(opt(f[5]));
                let v = flows_vehicle_policy_towing_check(d(f[1]), d(f[2]), g, hg, t, ht, c, hc);
                let got: Vec<String> = v
                    .iter()
                    .zip(["G", "T", "C"])
                    .filter(|(x, _)| !x.is_nan())
                    .map(|(x, k)| format!("{k}:{}", x.to_bits()))
                    .collect();
                let want: Vec<String> = list(f[6])
                    .into_iter()
                    .map(|item| {
                        let (k, h) = item.split_once(':').expect("violation");
                        format!("{k}:{}", d(h).to_bits())
                    })
                    .collect();
                if v.len() != 3 || got != want {
                    fail(line, format!("{got:?}"), format!("{want:?}"))
                }
            }
            "dp" => {
                let g = flows_vehicle_policy_degrees_to_percent(d(f[1]));
                if !eqd(g, f[2]) {
                    fail(line, bits(g), f[2].into())
                }
            }
            "pc" => {
                // The facade answers nil and [] before crossing.
                let got = if f[3] == "-" {
                    true
                } else {
                    let c: Vec<f64> = list(f[3]).into_iter().map(d).collect();
                    c.is_empty() || flows_vehicle_policy_passes_clearances(d(f[1]), d(f[2]), &c)
                };
                if bit(got) != f[4] {
                    fail(line, bit(got).into(), f[4].into())
                }
            }
            "pg" => {
                let (r, hr) = flag(opt(f[2]));
                let got = flows_vehicle_policy_passes_grade(d(f[1]), r, hr);
                if bit(got) != f[3] {
                    fail(line, bit(got).into(), f[3].into())
                }
            }
            "pw" => {
                let (rig, has_rig) = flag(opt(f[1]));
                let got = if f[2] == "-" {
                    true
                } else {
                    let w: Vec<f64> = list(f[2]).into_iter().map(d).collect();
                    w.is_empty() || flows_vehicle_policy_passes_weight_limits(rig, has_rig, &w)
                };
                if bit(got) != f[3] {
                    fail(line, bit(got).into(), f[3].into())
                }
            }
            "vd" => {
                let (p, hp) = flag(opt(f[1]));
                let (g, hg) = flag(opt(f[2]));
                let (c, hc) = flag(opt(f[3]));
                let got = flows_vehicle_policy_default_max_grade_degrees(
                    p,
                    hp,
                    g,
                    hg,
                    c,
                    hc,
                    d(f[4]),
                    f[5] == "1",
                    d(f[6]),
                );
                if !eqd(got, f[7]) {
                    fail(line, bits(got), f[7].into())
                }
            }
            "gs" => {
                let e: Vec<Option<f64>> = list(f[1]).into_iter().map(opt).collect();
                let start = opt(f[3]).unwrap_or(0.0);
                let got = if e.is_empty() {
                    Vec::new()
                } else {
                    let values: Vec<f64> = e.iter().map(|x| x.unwrap_or(0.0)).collect();
                    let present: Vec<u8> = e.iter().map(|x| u8::from(x.is_some())).collect();
                    flows_vehicle_policy_grade_segments(&values, &present, d(f[2]), start)
                };
                let want: Vec<f64> = list(f[4]).into_iter().flat_map(triple).collect();
                if triple_bits(&got) != triple_bits(&want) {
                    fail(
                        line,
                        format!("{} values", got.len()),
                        format!("{} values", want.len()),
                    )
                }
            }
            "gtp" => {
                let codes: Vec<usize> = list(f[1])
                    .into_iter()
                    .map(|c| c.parse().expect("code"))
                    .collect();
                let flat: Vec<f64> = codes
                    .iter()
                    .enumerate()
                    .flat_map(|(i, c)| [i as f64, i as f64 + 1.0, gp[*c]])
                    .collect();
                let top: i64 = f[2].parse().expect("top");
                let got = steepest_facade(&flat, top);
                let want: Vec<f64> = list(f[3])
                    .into_iter()
                    .flat_map(|i| {
                        let i: usize = i.parse().expect("index");
                        [flat[3 * i], flat[3 * i + 1], flat[3 * i + 2]]
                    })
                    .collect();
                if triple_bits(&got) != triple_bits(&want) {
                    let order: Vec<f64> = got.chunks(3).map(|c| c[0]).collect();
                    fail(line, format!("{order:?}"), f[3].into())
                }
            }
            "gt" => {
                let flat: Vec<f64> = list(f[1]).into_iter().flat_map(triple).collect();
                let got = steepest_facade(&flat, f[2].parse().expect("top"));
                let want: Vec<f64> = list(f[3]).into_iter().flat_map(triple).collect();
                if triple_bits(&got) != triple_bits(&want) {
                    fail(line, format!("{got:?}"), format!("{want:?}"))
                }
            }
            "gn" | "gnd" => {
                let (mile, threshold, lookahead, codes, want) = if f[0] == "gn" {
                    (d(f[1]), d(f[2]), d(f[3]), f[4], f[5])
                } else {
                    (
                        d(f[1]),
                        flows_vehicle_policy_grade_steep_threshold_percent(),
                        flows_vehicle_policy_grade_lookahead_miles(),
                        f[2],
                        f[3],
                    )
                };
                let flat = coded(codes);
                let got = next_steep_facade(mile, &flat, threshold, lookahead);
                let want = (want != "-").then(|| triple_bits(&coded(&format!("L1:{want}"))));
                if got != want {
                    fail(line, format!("{got:?}"), format!("{want:?}"))
                }
            }
            "dd" => {
                let g = flows_vehicle_policy_drive_drag_penalty(d(f[1]), d(f[2]));
                if !eqd(g, f[3]) {
                    fail(line, bits(g), f[3].into())
                }
            }
            "ddd" => {
                let g = flows_vehicle_policy_drive_drag_penalty(d(f[1]), default_cruise);
                if !eqd(g, f[2]) {
                    fail(line, bits(g), f[2].into())
                }
            }
            "dg" => {
                let g = flows_vehicle_policy_drive_grade_penalty(d(f[1]));
                if !eqd(g, f[2]) {
                    fail(line, bits(g), f[2].into())
                }
            }
            "dth" => {
                let g = flows_vehicle_policy_drive_throttle_penalty(d(f[1]));
                if !eqd(g, f[2]) {
                    fail(line, bits(g), f[2].into())
                }
            }
            "dh" => {
                let (fr, hf) = flag(opt(f[2]));
                let (h, hh) = flag(opt(f[3]));
                let g = flows_vehicle_policy_drive_headwind_mph(d(f[1]), fr, hf, h, hh);
                if !eqd(g, f[4]) {
                    fail(line, bits(g), f[4].into())
                }
            }
            "ds" | "ec" => {
                let (c, hc) = flag(opt(f[1]));
                let (h, hh) = flag(opt(f[2]));
                let g = if f[0] == "ds" {
                    flows_vehicle_policy_drive_drag_sensitivity(c, hc, h, hh)
                } else {
                    flows_vehicle_policy_drive_efficient_cruise_mph(c, hc, h, hh)
                };
                if !eqd(g, f[3]) {
                    fail(line, bits(g), f[3].into())
                }
            }
            "de" => {
                let towing = f[12] == "1";
                let (score, verdict) = drive(
                    d(f[1]),
                    d(f[2]),
                    d(f[3]),
                    d(f[4]),
                    opt(f[5]),
                    opt(f[6]),
                    d(f[7]),
                    opt(f[8]),
                    opt(f[9]),
                    opt(f[10]),
                    opt(f[11]),
                    towing,
                    opt(f[13]),
                );
                let (l, hl) = flag(opt(f[10]));
                let (v, hv) = flag(opt(f[11]));
                let (fu, hfu) = flag(opt(f[13]));
                let load = flows_vehicle_policy_drive_load_factor(l, hl, v, hv, towing, fu, hfu);
                let (fr, hf) = flag(opt(f[5]));
                let (h, hh) = flag(opt(f[6]));
                let air = flows_vehicle_policy_drive_airspeed_mph(d(f[1]), d(f[4]), fr, hf, h, hh);
                if !eqd(score, f[14])
                    || verdict.to_string() != f[15]
                    || !eqd(load, f[16])
                    || !eqd(air, f[17])
                {
                    fail(
                        line,
                        format!("{} {verdict} {} {}", bits(score), bits(load), bits(air)),
                        f[14..18].join(" "),
                    )
                }
            }
            "dc" => {
                let cruise = opt(f[4]).unwrap_or(default_cruise);
                let (score, verdict) = drive(
                    d(f[1]),
                    d(f[2]),
                    d(f[3]),
                    0.0,
                    None,
                    None,
                    cruise,
                    None,
                    None,
                    None,
                    None,
                    false,
                    None,
                );
                if !eqd(score, f[5]) || verdict.to_string() != f[6] {
                    fail(
                        line,
                        format!("{} {verdict}", bits(score)),
                        f[5..7].join(" "),
                    )
                }
            }
            other => panic!("unknown oracle record {other}"),
        }
    }
    assert!(checked > 14_000, "fixture truncated: {checked} records");
    let (known, unknown): (Vec<_>, Vec<_>) = failures
        .into_iter()
        .partition(|(line, _)| KNOWN_DIVERGENCES.iter().any(|(k, _)| k == line));
    if !unknown.is_empty() {
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
