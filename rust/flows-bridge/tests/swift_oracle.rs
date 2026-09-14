// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle: every line of the fixture is an input and the
//! output the ORIGINAL Swift implementation produced for it, before the Swift
//! was replaced by calls into Rust. Every function is compared BIT FOR BIT.
//!
//! The fixture is never regenerated from Rust. To extend it, check out the
//! commit named in its header and rerun the Swift harness described there.

use flows_bridge::risk::*;
use flows_core::families as fam;

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

/// Records where Rust deliberately does not reproduce the Swift original,
/// each with its reason. Every entry must still diverge — a fixed divergence
/// fails the test until its entry is removed, so this list cannot rot.
const KNOWN_DIVERGENCES: &[(&str, &str)] = &[(
    "af\ts:73746f726dcc81\t-",
    "Swift's String.contains matches whole grapheme clusters, so \"storm\u{301}\" \
     (a combining accent on the m) does not contain \"storm\"; Rust matches bytes. \
     Exact parity needs grapheme-break tables; no real alert name has this shape, \
     and the family yielded is a capped predictor. Pinned in families.rs.",
)];

#[test]
fn rust_reproduces_the_original_swift_bit_for_bit() {
    let text = include_str!("fixtures/swift_risk_oracle.tsv");
    let mut failures: Vec<(String, String)> = Vec::new();
    let mut checked = 0usize;
    let dense_names: Vec<&str> = (0..fam::DENSE_FAMILY_COUNT)
        .filter_map(fam::dense_family)
        .collect();
    let mut fail = |line: &str, got: String, want: String| {
        failures.push((
            line.to_string(),
            format!("\n    got  {got}\n    want {want}"),
        ));
    };
    for line in text
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
    {
        let f: Vec<&str> = line.split('\t').collect();
        checked += 1;
        let eqd = |got: f64, want: &str| got.to_bits() == d(want).to_bits();
        match f[0] {
            "const" => {
                let got = match f[1] {
                    "riskGreenMin" => flows_risk_green_min(),
                    "riskYellowMin" => flows_risk_yellow_min(),
                    "secondaryCeiling" => flows_secondary_ceiling(),
                    "acuteNudge" => flows_acute_nudge(),
                    other => panic!("unknown const {other}"),
                };
                if !eqd(got, f[2]) {
                    fail(line, bits(got), f[2].into())
                }
            }
            "table" => {
                let want: Vec<String> = list(f[2]).into_iter().map(s).collect();
                let got = match f[1] {
                    "primaryOrder" => flows_primary_families(),
                    "secondaryOrder" => flows_secondary_families(),
                    "acuteFamilies" => {
                        let mut v = flows_acute_families();
                        v.sort();
                        v
                    }
                    other => panic!("unknown table {other}"),
                };
                if got != want {
                    fail(line, format!("{got:?}"), format!("{want:?}"))
                }
            }
            "weight" => {
                let name = s(f[1]);
                let names = flows_weighted_family_names();
                let values = flows_weighted_family_values();
                let got = names.iter().position(|n| *n == name).map(|i| values[i]);
                if got.map(|g| g.to_bits()) != Some(d(f[2]).to_bits()) {
                    fail(line, format!("{got:?}"), f[2].into())
                }
            }
            "band" => {
                let got = flows_risk_band_code(d(f[1]));
                if got.to_string() != f[2] {
                    fail(line, got.to_string(), f[2].into())
                }
            }
            "pw" => {
                let g = flows_piecewise_score(d(f[1]), d(f[2]), d(f[3]), d(f[4]));
                if !eqd(g, f[5]) {
                    fail(line, bits(g), f[5].into())
                }
            }
            "tr" => {
                let g = flows_temperature_risk(d(f[1]), d(f[2]), d(f[3]), d(f[4]), d(f[5]));
                if !eqd(g, f[6]) {
                    fail(line, bits(g), f[6].into())
                }
            }
            "ta" => {
                let g = flows_temperature_anomalous(d(f[1]), d(f[2]), d(f[3]), d(f[4]), d(f[5]));
                if (if g { "1" } else { "0" }) != f[6] {
                    fail(line, g.to_string(), f[6].into())
                }
            }
            "wr" => {
                let g = flows_wind_risk(d(f[1]));
                if !eqd(g, f[2]) {
                    fail(line, bits(g), f[2].into())
                }
            }
            "pr" => {
                let g = flows_pop_risk(d(f[1]));
                if !eqd(g, f[2]) {
                    fail(line, bits(g), f[2].into())
                }
            }
            "fc" => {
                let g = flows_forecast_composite(d(f[1]), d(f[2]), d(f[3]));
                if !eqd(g, f[4]) {
                    fail(line, bits(g), f[4].into())
                }
            }
            "no" => {
                let names: Vec<String> = list(f[1]).into_iter().map(s).collect();
                let scores: Vec<f64> = list(f[2]).into_iter().map(d).collect();
                let g = flows_noisy_or_named(&names.join("\u{1f}"), &scores);
                if !eqd(g, f[3]) {
                    fail(line, bits(g), f[3].into())
                }
            }
            "rr" => {
                // The same encoding the Swift facade builds.
                let names: Vec<String> = list(f[1]).into_iter().map(s).collect();
                let scores: Vec<f64> = list(f[2]).into_iter().map(d).collect();
                let mut dense = vec![f64::NAN; fam::DENSE_FAMILY_COUNT];
                for (n, v) in names.iter().zip(&scores) {
                    if let Some(i) = fam::dense_family_index(n) {
                        dense[i] = *v;
                    }
                }
                let g = flows_realized_risk_dense(&dense);
                if !eqd(g, f[3]) {
                    fail(line, bits(g), f[3].into())
                }
            }
            "pf" | "df" => {
                let names: Vec<String> = list(f[1]).into_iter().map(s).collect();
                let scores: Vec<f64> = list(f[2]).into_iter().map(d).collect();
                let joined = names.join("\u{1f}");
                let pos = if f[0] == "pf" {
                    flows_peak_family_position(&joined, &scores, d(f[3]))
                } else {
                    flows_dominant_family_position(&joined, &scores, d(f[3]))
                };
                let got = usize::try_from(pos)
                    .ok()
                    .and_then(|p| names.get(p))
                    .cloned();
                let want = (f[4] != "-").then(|| s(f[4]));
                if got != want {
                    fail(line, format!("{got:?}"), format!("{want:?}"))
                }
            }
            "rd" => {
                let g = flows_displayed_band(d(f[1]), d(f[2]));
                if !eqd(g, f[3]) {
                    fail(line, bits(g), f[3].into())
                }
            }
            "fe" => {
                let (e, lo, q) = (opt(f[1]), opt(f[2]), opt(f[3]));
                let g = flows_flood_elevation_multiplier(
                    e.unwrap_or(0.0),
                    e.is_some(),
                    lo.unwrap_or(0.0),
                    lo.is_some(),
                    q.unwrap_or(0.0),
                    q.is_some(),
                    d(f[4]),
                );
                if !eqd(g, f[5]) {
                    fail(line, bits(g), f[5].into())
                }
            }
            "rk" => {
                let g = flows_ranking_risk(d(f[1]), d(f[2]), d(f[3]), d(f[4]));
                if !eqd(g, f[5]) {
                    fail(line, bits(g), f[5].into())
                }
            }
            "af" => {
                let ev = s(f[1]);
                let idx = flows_alert_family_index(&ev);
                let got = usize::try_from(idx)
                    .ok()
                    .and_then(|i| dense_names.get(i))
                    .map(|n| (*n).to_string());
                let want = (f[2] != "-").then(|| s(f[2]));
                if got != want {
                    fail(line, format!("{got:?} for {ev:?}"), format!("{want:?}"))
                }
            }
            "pl" => {
                let bytes: Vec<u8> = list(f[1])
                    .into_iter()
                    .map(|h| u8::from_str_radix(h, 16).expect("byte"))
                    .collect();
                let want: Vec<u64> = list(f[2]).into_iter().map(|h| d(h).to_bits()).collect();
                let got: Vec<u64> = flows_decode_polyline_lonlat(&bytes)
                    .iter()
                    .map(|x| x.to_bits())
                    .collect();
                if got != want {
                    fail(
                        line,
                        format!("{} values", got.len()),
                        format!("{} values", want.len()),
                    )
                }
            }
            other => panic!("unknown oracle record {other}"),
        }
    }
    assert!(checked > 7000, "fixture truncated: {checked} records");
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
