// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the map sweep's per-point rules: 3,600
//! records from the ORIGINAL `ViewportPointRules` at commit 6a716f6, before
//! the rules moved to `flows_core::viewport_point`. Every family list is
//! compared name for name and bit for bit, every badge name exactly.

use flows_core::viewport_point::{display_families, point, Icon, Live};
use std::collections::{BTreeMap, HashMap};

const ORIGINAL_COMMIT: &str = "6a716f6";
const RECORDS: [(&str, usize); 2] = [("df", 1200), ("pt", 2400)];

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}
/// "name=hex" joined by ";", in the order written.
fn pairs(f: &str) -> Vec<(&str, f64)> {
    if f.is_empty() {
        return Vec::new();
    }
    f.split(';')
        .map(|p| {
            let (name, value) = p.split_once('=').unwrap_or_else(|| panic!("bad pair {p}"));
            (name, d(value))
        })
        .collect()
}
fn listed(m: &BTreeMap<String, f64>) -> String {
    m.iter()
        .map(|(name, value)| format!("{name}={:x}", value.to_bits()))
        .collect::<Vec<_>>()
        .join(";")
}

#[test]
fn rust_reproduces_the_original_swift_viewport_point_rules() {
    let content = include_str!("fixtures/swift_viewport_point_oracle.tsv");
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
            "df" => {
                assert_eq!(f.len(), 15, "df fields");
                let live = Live {
                    fire: d(f[3]),
                    seismic: d(f[4]),
                    volcanic: d(f[5]),
                    avalanche: d(f[6]),
                    tropical: d(f[7]),
                    tsunami: d(f[8]),
                    convective: d(f[9]),
                    space_radiation: d(f[10]),
                    flood_realized: d(f[11]),
                    air: (f[12] != "-").then(|| d(f[12])),
                    uv: d(f[13]),
                };
                (
                    f[14].to_string(),
                    display_families(d(f[1]), &pairs(f[2]), &live)
                        .map_or("-".to_string(), |m| listed(&m)),
                )
            }
            "pt" => {
                assert_eq!(f.len(), 11, "pt fields");
                let p = point(
                    &pairs(f[1]),
                    d(f[2]),
                    d(f[3]),
                    d(f[4]),
                    (f[5] != "-").then_some(f[5]),
                    d(f[6]),
                    d(f[7]),
                );
                let icon = match &p.icon {
                    Icon::Family(family) => format!("f:{family}"),
                    Icon::RainChance => "rain".to_string(),
                    Icon::Forecast => "forecast".to_string(),
                    Icon::Alert => "alert".to_string(),
                    Icon::Closure => "closure".to_string(),
                };
                (
                    format!("{} | {} | {}", f[8], f[9], f[10]),
                    format!(
                        "{} | {} | {icon}",
                        listed(&p.families),
                        listed(&p.band_input)
                    ),
                )
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
        "{} of 3600 records differ:\n{}",
        failures.len(),
        failures
            .iter()
            .take(10)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}
