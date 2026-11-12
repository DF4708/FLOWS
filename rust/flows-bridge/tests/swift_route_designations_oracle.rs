// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the route designations: 2,038 records from
//! the ORIGINAL `SafestRoute`, `CheapestRoute`, `EfficientRoute`,
//! `TruckerDesignation` and `FastestRoute` at commit ea53276, before the
//! rules moved to `flows_core::route_designations`. Every pick and count is
//! compared exactly, every number bit for bit.

use flows_core::route_designations::{
    cheapest, chip_minutes, efficient, fastest_eta, key_point_minutes, safest, trucker,
    trucker_score, Cost, Truck,
};
use std::collections::HashMap;

const ORIGINAL_COMMIT: &str = "ea53276";
const RECORDS: [(&str, usize); 7] = [
    ("sf", 300),
    ("ch", 400),
    ("ef", 200),
    ("tr", 400),
    ("fe", 150),
    ("cm", 294),
    ("kp", 294),
];

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}
fn hx(x: f64) -> String {
    format!("{:x}", x.to_bits())
}
fn flag(f: &str) -> bool {
    match f {
        "1" => true,
        "0" => false,
        other => panic!("bad flag {other}"),
    }
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
/// Records joined by ";", each with `fields` parts joined by "/".
fn rows(f: &str, fields: usize) -> Vec<Vec<&str>> {
    if f.is_empty() {
        return Vec::new();
    }
    f.split(';')
        .map(|r| {
            let v: Vec<&str> = r.split('/').collect();
            assert_eq!(v.len(), fields, "route fields");
            v
        })
        .collect()
}
fn opt<T: ToString>(v: Option<T>) -> String {
    v.map_or("-".to_string(), |x| x.to_string())
}

#[test]
fn rust_reproduces_the_original_swift_route_designations() {
    let content = include_str!("fixtures/swift_route_designations_oracle.tsv");
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
            "sf" => {
                let risks: Vec<f64> = list(f[1]).into_iter().map(d).collect();
                let scored: Vec<bool> = list(f[2]).into_iter().map(flag).collect();
                (f[3].to_string(), opt(safest(&risks, &scored)))
            }
            "ch" => {
                let routes: Vec<Cost> = rows(f[1], 3)
                    .iter()
                    .map(|v| Cost {
                        fuel_usd: d(v[0]),
                        has_tolls: flag(v[1]),
                        is_walk: flag(v[2]),
                    })
                    .collect();
                (f[2].to_string(), opt(cheapest(&routes)))
            }
            "ef" => {
                let meters: Vec<f64> = list(f[1]).into_iter().map(d).collect();
                let walk: Vec<bool> = list(f[2]).into_iter().map(flag).collect();
                (f[3].to_string(), opt(efficient(&meters, &walk)))
            }
            "tr" => {
                let routes: Vec<Truck> = rows(f[1], 7)
                    .iter()
                    .map(|v| Truck {
                        clears_bridges: flag(v[0]),
                        has_highways: flag(v[1]),
                        avoids_highways: flag(v[2]),
                        grade_ok: flag(v[3]),
                        wind_ok: flag(v[4]),
                        is_walk: flag(v[5]),
                        eta: d(v[6]),
                    })
                    .collect();
                let scores: Vec<String> = routes.iter().map(|t| hx(trucker_score(t))).collect();
                (
                    format!("{} {}", list(f[2]).join(","), f[3]),
                    format!("{} {}", scores.join(","), opt(trucker(&routes))),
                )
            }
            "fe" => {
                let etas: Vec<f64> = list(f[1]).into_iter().map(d).collect();
                (f[2].to_string(), opt(fastest_eta(&etas).map(hx)))
            }
            "cm" => (f[3].to_string(), opt(chip_minutes(d(f[1]), d(f[2])))),
            "kp" => (f[3].to_string(), opt(key_point_minutes(d(f[1]), d(f[2])))),
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
        "{} of 2038 records differ:\n{}",
        failures.len(),
        failures
            .iter()
            .take(20)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}
