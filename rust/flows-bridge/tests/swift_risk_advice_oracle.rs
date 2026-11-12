// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the risk advice and the border lines: records
//! from the ORIGINAL `RiskAdvice` at commit ORIGINAL_COMMIT, before its rules
//! moved to `flows_core::risk_advice`. Every answer must be the same bits and
//! the same text, the official page's address included.

use flows_core::risk_advice::{
    actions, is_across_the_border, is_canada_below_the_bands, is_north_of_the_border,
    may_be_across_the_border, official_url, us_southern_border_lat,
};
use std::collections::HashMap;

const ORIGINAL_COMMIT: &str = "3d08766";
const RECORDS: [(&str, usize); 2] = [("a", 1636), ("g", 41936)];

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}

fn hx(x: f64) -> String {
    format!("{:x}", x.to_bits())
}

fn th(s: &str) -> String {
    s.bytes().map(|b| format!("{b:02x}")).collect()
}

fn unhex(h: &str) -> String {
    let bytes: Vec<u8> = (0..h.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&h[i..i + 2], 16).expect("hex byte"))
        .collect();
    String::from_utf8(bytes).expect("utf-8 record text")
}

fn b01(b: bool) -> String {
    if b { "1" } else { "0" }.to_string()
}

fn answer(f: &[&str]) -> Vec<String> {
    match f[0] {
        "a" => {
            let band: u8 = f[2].parse().expect("band");
            let lines = actions(&unhex(f[1]), band);
            vec![lines.iter().map(|l| th(l)).collect::<Vec<_>>().join(",")]
        }
        "g" => {
            let (lat, lon) = (d(f[1]), d(f[2]));
            vec![
                b01(is_north_of_the_border(lat, lon)),
                b01(is_canada_below_the_bands(lat, lon)),
                b01(is_across_the_border(lat, lon)),
                b01(may_be_across_the_border(lat, lon)),
                official_url(lat, lon),
                hx(us_southern_border_lat(lon)),
            ]
        }
        k => panic!("unknown record kind {k}"),
    }
}

/// The fields of a record the Swift answered, against which `answer` is set.
fn expected(f: &[&str]) -> Vec<String> {
    let range = match f[0] {
        "a" => 3..4,
        "g" => 3..9,
        k => panic!("unknown record kind {k}"),
    };
    f[range].iter().map(|s| (*s).to_string()).collect()
}

#[test]
fn the_rust_gives_the_original_swift_answers() {
    let text = include_str!("fixtures/swift_risk_advice_oracle.tsv");
    assert!(
        text.contains(&format!("at commit {ORIGINAL_COMMIT}")),
        "the fixture names its commit"
    );
    let mut counts: HashMap<&str, usize> = HashMap::new();
    let mut wrong: HashMap<&str, usize> = HashMap::new();
    let mut shown = 0;
    for line in text.lines().filter(|l| !l.starts_with('#')) {
        let f: Vec<&str> = line.split('\t').collect();
        *counts.entry(f[0]).or_default() += 1;
        let (want, got) = (expected(&f), answer(&f));
        if want != got {
            *wrong.entry(f[0]).or_default() += 1;
            if shown < 12 {
                shown += 1;
                eprintln!("{line}\n  rust: {}", got.join("\t"));
            }
        }
    }
    for (kind, n) in RECORDS {
        assert_eq!(counts.get(kind).copied().unwrap_or(0), n, "{kind} records");
    }
    assert_eq!(
        counts.values().sum::<usize>(),
        RECORDS.iter().map(|r| r.1).sum::<usize>()
    );
    assert!(wrong.is_empty(), "records that differ: {wrong:?}");
}
