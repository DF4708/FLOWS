// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the leg geometry rules: 4,815 records from
//! the ORIGINAL `LegGeometry` at commit 231ef58, before the rules moved to
//! `flows_core::leg_geometry`. Every distance is compared bit for bit and
//! every index exactly.

use flows_core::leg_geometry::{
    check_point_indices, cut, reroute_wait, steep_marker_indices, Cut, Leg, Point,
};
use std::collections::HashMap;

const ORIGINAL_COMMIT: &str = "231ef58";
const RECORDS: [(&str, usize); 8] = [
    ("leg", 81),
    ("mt", 1501),
    ("pg", 1200),
    ("ah", 700),
    ("rw", 52),
    ("sm", 500),
    ("ct", 81),
    ("cp", 700),
];

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}
fn hx(v: f64) -> String {
    format!("{:x}", v.to_bits())
}
fn n(s: &str) -> usize {
    s.parse().unwrap_or_else(|_| panic!("bad count {s}"))
}
fn point(s: &str) -> Point {
    let (lat, lon) = s.split_once(',').unwrap_or_else(|| panic!("bad point {s}"));
    (d(lat), d(lon))
}
fn joined<T: ToString>(items: impl IntoIterator<Item = T>) -> String {
    items
        .into_iter()
        .map(|i| i.to_string())
        .collect::<Vec<_>>()
        .join(";")
}

/// What a leg record holds: the leg, and its points as a path.
struct Held {
    leg: Leg,
    points: Vec<Point>,
}

#[test]
fn rust_reproduces_the_original_swift_leg_geometry_rules() {
    let content = include_str!("fixtures/swift_leg_geometry_oracle.tsv");
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
    let mut legs: Vec<Held> = Vec::new();
    for (at, line) in content
        .lines()
        .enumerate()
        .filter(|(_, l)| !l.starts_with('#') && !l.is_empty())
    {
        let f: Vec<&str> = line.split('\t').collect();
        *seen.entry(f[0]).or_default() += 1;
        let (want, got): (String, String) = match f[0] {
            "leg" => {
                assert_eq!(f.len(), 4, "leg fields");
                let steps: Vec<Vec<Point>> = f[1]
                    .split('|')
                    .map(|s| {
                        if s.is_empty() {
                            Vec::new()
                        } else {
                            s.split(';').map(point).collect()
                        }
                    })
                    .collect();
                let counts: Vec<usize> = steps.iter().map(Vec::len).collect();
                let points: Vec<Point> = steps.into_iter().flatten().collect();
                let leg = Leg::new(points.clone(), &counts).expect("the counts add up");
                let got = format!(
                    "{} | {}",
                    joined(leg.cumulative().iter().map(|v| hx(*v))),
                    joined(leg.step_end())
                );
                legs.push(Held { leg, points });
                (format!("{} | {}", f[2], f[3]), got)
            }
            "mt" => {
                assert_eq!(f.len(), 6, "mt fields");
                let got = legs[n(f[1])]
                    .leg
                    .match_fix(n(f[2]), point(f[3]))
                    .map_or("- -".to_string(), |(i, m)| format!("{i} {}", hx(m)));
                (format!("{} {}", f[4], f[5]), got)
            }
            "pg" => {
                assert_eq!(f.len(), 10, "pg fields");
                let got = legs[n(f[1])].leg.progress(n(f[2]), n(f[3])).map_or(
                    "- - - - - -".to_string(),
                    |p| {
                        format!(
                            "{} {} {} {} {} {}",
                            p.step,
                            hx(p.to_maneuver),
                            hx(p.along),
                            hx(p.remaining),
                            hx(p.fraction_left),
                            hx(p.step_spacing)
                        )
                    },
                );
                (f[4..].join(" "), got)
            }
            "ah" => {
                assert_eq!(f.len(), 5, "ah fields");
                let got = legs[n(f[1])]
                    .leg
                    .ahead(n(f[2]), d(f[3]))
                    .map_or("-".to_string(), |i| i.to_string());
                (f[4].to_string(), got)
            }
            "rw" => {
                assert_eq!(f.len(), 3, "rw fields");
                let failures: i64 = f[1].parse().expect("failures");
                (f[2].to_string(), hx(reroute_wait(failures)))
            }
            "sm" => {
                assert_eq!(f.len(), 4, "sm fields");
                let profile: Vec<(f64, f64, f64)> = if f[2].is_empty() {
                    Vec::new()
                } else {
                    f[2].split(';')
                        .map(|s| {
                            let v: Vec<f64> = s.split(',').map(d).collect();
                            (v[0], v[1], v[2])
                        })
                        .collect()
                };
                let got = joined(
                    steep_marker_indices(&legs[n(f[1])].points, &profile)
                        .into_iter()
                        .map(|(i, grade)| format!("{i},{}", hx(grade))),
                );
                (f[3].to_string(), got)
            }
            "ct" => {
                assert_eq!(f.len(), 3, "ct fields");
                let got = match cut(&legs[n(f[1])].points) {
                    Cut::Whole => "w".to_string(),
                    Cut::At(i) => format!("a:{i}"),
                    Cut::Between { before, mid } => {
                        format!("b:{before}:{}:{}", hx(mid.0), hx(mid.1))
                    }
                };
                (f[2].to_string(), got)
            }
            "cp" => {
                assert_eq!(f.len(), 4, "cp fields");
                let got = joined(check_point_indices(&legs[n(f[1])].points, d(f[2])));
                (f[3].to_string(), got)
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
        "{} of 4815 records differ:\n{}",
        failures.len(),
        failures
            .iter()
            .take(10)
            .map(|l| l.chars().take(400).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n")
    );
}
