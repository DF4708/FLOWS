// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the forecast predictors:
//! `ForecastConditions.forecastScore` and `.predictorFamilies` at commit
//! a007de0, run by a harness linked against the Rust bridge (the original
//! `RiskEquations` was already a facade over the Rust equations, and the
//! original `ClimateProfiles` and `LatitudeBands` were compiled in), before
//! the composition moved to `flows_core::forecast`. Every number is compared
//! bit for bit.

use flows_core::forecast::{forecast_score, predictor_families, Conditions};
use std::collections::BTreeMap;

const BASE_COMMIT: &str = "a007de042d12e736fdd86398e1ea54ca31aadc1f";

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}
fn optd(t: &str) -> Option<f64> {
    (t != "-").then(|| d(t))
}
fn hx(x: f64) -> String {
    format!("{:x}", x.to_bits())
}

#[test]
fn rust_reproduces_the_original_swift_forecast_predictors_bit_for_bit() {
    let content = include_str!("fixtures/swift_forecast_oracle.tsv");
    assert!(
        content
            .lines()
            .next()
            .unwrap_or_default()
            .contains(BASE_COMMIT),
        "fixture header must name the base commit"
    );
    let mut failures: Vec<String> = Vec::new();
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for line in content
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
    {
        let f: Vec<&str> = line.split('\t').collect();
        *counts.entry(f[0].to_string()).or_default() += 1;
        let c = Conditions {
            temperature_f: optd(f[1]),
            wind_mph: optd(f[2]),
            pop_percent: optd(f[3]),
        };
        let (lat, lon, elev) = (d(f[4]), d(f[5]), optd(f[6]));
        let got = match f[0] {
            "fc-score" => hx(forecast_score(&c, lat, lon, elev)),
            "fc-fam" => {
                let fam = predictor_families(&c, lat, lon, elev);
                format!(
                    "L6:{}",
                    fam.iter().map(|&v| hx(v)).collect::<Vec<_>>().join(",")
                )
            }
            other => panic!("unknown record kind {other}"),
        };
        if got != f[7] {
            failures.push(format!("{line}\n    got  {got}"));
        }
    }
    let total: usize = counts.values().sum();
    assert!(total >= 4_500, "fixture truncated: {total}");
    assert_eq!(counts.len(), 2, "record kinds: {counts:?}");
    assert!(
        failures.is_empty(),
        "{} of {total} oracle records differ from the original Swift:\n{}",
        failures.len(),
        failures
            .iter()
            .take(40)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}
