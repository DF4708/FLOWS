// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the live corridor watch's rules: 1,500
//! records from the ORIGINAL `CorridorWatchRules` at commit 7c34c97 — the
//! Swift that left `AppModel` and `WeatherAlertService` — before the rules
//! moved to `flows_core::corridor_watch`. Every number is compared bit for
//! bit, every index and flag exactly.

use flows_core::corridor_watch::{
    average_mph, fold, reading, seconds_per_meter, slice, window, Mark,
};
use std::collections::HashMap;

const ORIGINAL_COMMIT: &str = "7c34c97";
const RECORDS: [(&str, usize); 6] = [
    ("win", 200),
    ("spm", 150),
    ("mph", 150),
    ("sl", 400),
    ("rd", 200),
    ("fd", 400),
];

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}
fn hx(x: f64) -> String {
    format!("{:x}", x.to_bits())
}
/// The items of an `L<n>:a,b,c` list.
fn list(f: &str) -> Vec<&str> {
    let (n, body) = f
        .strip_prefix('L')
        .and_then(|r| r.split_once(':'))
        .unwrap_or_else(|| panic!("bad list {f}"));
    let items: Vec<&str> = if body.is_empty() {
        Vec::new()
    } else {
        body.split(',').collect()
    };
    assert_eq!(n.parse::<usize>().ok(), Some(items.len()), "list count");
    items
}
/// Check points, with one code per distinct (event, id) pair: the texts are
/// compared as the fixture spells them, which is one-to-one with the text.
fn marks<'a>(f: &'a str, codes: &mut HashMap<(&'a str, &'a str), i64>) -> Vec<Mark> {
    if f.is_empty() {
        return Vec::new();
    }
    f.split(';')
        .map(|m| {
            let v: Vec<&str> = m.split('/').collect();
            assert_eq!(v.len(), 5, "check point fields");
            let next = codes.len() as i64;
            let code = *codes.entry((v[3], v[4])).or_insert(next);
            Mark {
                lat: d(v[0]),
                lon: d(v[1]),
                risk: d(v[2]),
                code,
            }
        })
        .collect()
}

#[test]
fn rust_reproduces_the_original_swift_corridor_watch_rules() {
    let content = include_str!("fixtures/swift_corridor_watch_oracle.tsv");
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
            "win" => {
                let (lookahead, cadence) = window(d(f[1]));
                (
                    f[2..4].join(" "),
                    format!("{} {}", hx(lookahead), hx(cadence)),
                )
            }
            "spm" => (f[3].to_string(), hx(seconds_per_meter(d(f[1]), d(f[2])))),
            "mph" => (f[3].to_string(), hx(average_mph(d(f[1]), d(f[2])))),
            "sl" => {
                let count: usize = f[1].parse().expect("count");
                let s = slice(count, d(f[2]), d(f[3]), d(f[4]), d(f[5]));
                let offsets: Vec<String> = s.offsets.iter().map(|&o| hx(o)).collect();
                let got = match s.range {
                    Some((lo, hi)) => format!("1 {lo} {hi} {}", offsets.join(",")),
                    None => format!("0 - - {}", offsets.join(",")),
                };
                (
                    format!("{} {} {} {}", f[6], f[7], f[8], list(f[9]).join(",")),
                    got,
                )
            }
            "rd" => {
                let risks: Vec<f64> = list(f[1]).into_iter().map(d).collect();
                let r = reading(&risks);
                (
                    f[2..5].join(" "),
                    format!(
                        "{} {} {}",
                        hx(r.mean),
                        hx(r.peak),
                        r.peak_index.map_or("-".to_string(), |i| i.to_string())
                    ),
                )
            }
            "fd" => {
                let mut codes = HashMap::new();
                let route = marks(f[1], &mut codes);
                let win = marks(f[2], &mut codes);
                let got: Vec<String> = fold(&route, &win)
                    .into_iter()
                    .map(|s| s.map_or("-".to_string(), |i| i.to_string()))
                    .collect();
                (list(f[3]).join(","), got.join(","))
            }
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
        "{} of 1500 records differ:\n{}",
        failures.len(),
        failures
            .iter()
            .take(20)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}
