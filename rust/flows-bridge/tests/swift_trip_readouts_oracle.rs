// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the trip readouts: 2,609 records from the
//! ORIGINAL `TripReadouts` at commit 1cc992f, before the numbers moved to
//! `flows_core::trip_readouts`. Every count is compared exactly, every
//! number bit for bit.

use flows_core::trip_readouts::{
    clock, exposure_miles, exposure_percent, grade_at, mile_places, miles, minutes, minutes_saved,
    planner_mile_places, spoken_miles, turn_feet, Clock, SpokenMiles,
};
use std::collections::HashMap;

const ORIGINAL_COMMIT: &str = "1cc992f";
const RECORDS: [(&str, usize); 8] = [
    ("tf", 397),
    ("mp", 300),
    ("sm", 389),
    ("mn", 246),
    ("ck", 392),
    ("ms", 240),
    ("xp", 245),
    ("gr", 400),
];

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}
fn hx(x: f64) -> String {
    format!("{:x}", x.to_bits())
}
fn opt<T: ToString>(v: Option<T>) -> String {
    v.map_or("-".to_string(), |x| x.to_string())
}
/// Stretches joined by ";", each start/end/grade joined by "/".
fn stretches(f: &str) -> Vec<[f64; 3]> {
    if f.is_empty() {
        return Vec::new();
    }
    f.split(';')
        .map(|r| {
            let v: Vec<f64> = r.split('/').map(d).collect();
            assert_eq!(v.len(), 3, "stretch fields");
            [v[0], v[1], v[2]]
        })
        .collect()
}

#[test]
fn rust_reproduces_the_original_swift_trip_readouts() {
    let content = include_str!("fixtures/swift_trip_readouts_oracle.tsv");
    assert!(
        content
            .lines()
            .next()
            .unwrap_or_default()
            .contains(ORIGINAL_COMMIT),
        "fixture header must name the original commit"
    );
    let mut failures: Vec<String> = Vec::new();
    let mut seen: HashMap<&str, usize> = HashMap::new();
    for (at, line) in content
        .lines()
        .enumerate()
        .filter(|(_, l)| !l.starts_with('#') && !l.is_empty())
    {
        let f: Vec<&str> = line.split('\t').collect();
        *seen.entry(f[0]).or_default() += 1;
        let (want, got): (String, String) = match f[0] {
            "tf" => (f[2].to_string(), opt(turn_feet(d(f[1])))),
            "mp" => {
                let m = d(f[1]);
                (
                    format!("{} {} {}", f[2], f[3], f[4]),
                    format!(
                        "{} {} {}",
                        mile_places(m),
                        planner_mile_places(m),
                        hx(miles(m))
                    ),
                )
            }
            "sm" => (
                f[2].to_string(),
                match spoken_miles(d(f[1])) {
                    SpokenMiles::One => "one".to_string(),
                    SpokenMiles::Whole(n) => format!("w:{n}"),
                    SpokenMiles::Tenths(t) => format!("t:{}", hx(t)),
                },
            ),
            "mn" => (f[2].to_string(), minutes(d(f[1])).to_string()),
            "ck" => (
                f[3].to_string(),
                match clock(d(f[1]), f[2] == "1") {
                    Clock::Minutes(m) => format!("m:{m}"),
                    Clock::Hours(h, m) => format!("h:{h}:{m}"),
                    Clock::Days(days) => format!("d:{}", hx(days)),
                },
            ),
            "ms" => (
                f[3].to_string(),
                minutes_saved(d(f[1]), d(f[2])).to_string(),
            ),
            "xp" => (
                format!("{} {}", f[3], f[4]),
                format!(
                    "{} {}",
                    exposure_percent(d(f[1])),
                    exposure_miles(d(f[2]), d(f[1]))
                ),
            ),
            "gr" => (f[3].to_string(), hx(grade_at(d(f[1]), &stretches(f[2])))),
            other => panic!("unknown record kind {other}"),
        };
        if want != got {
            failures.push(format!("line {}: {} want {want} got {got}", at + 1, f[0]));
        }
    }
    for (kind, count) in RECORDS {
        assert_eq!(seen.get(kind).copied(), Some(count), "{kind} records");
    }
    assert!(
        failures.is_empty(),
        "{} of 2609 records differ:\n{}",
        failures.len(),
        failures
            .iter()
            .take(20)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}
