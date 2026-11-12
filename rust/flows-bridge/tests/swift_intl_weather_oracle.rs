// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the international weather rules: 4,225
//! records from the ORIGINAL `IntlWeatherParsing` at commit 66e95db, before
//! the rules moved to `flows_core::intl_weather`. Every number is compared
//! bit for bit.
//!
//! A record lists the station's fields as the original saw them (see
//! `oracle-harness/intl_weather/main.swift`). This test finds a field the way
//! a Swift dictionary does, by canonical equivalence, and hands Rust what the
//! facade hands it: the NFC names, the numbers, and each name's `-uom` text.

use flows_core::intl_weather::{
    air_temp_f, celsius_to_f, kmh_to_mph, ms_to_mph, smn_conditions, wind_mph, WindField,
};
use flows_core::swift_text;
use std::collections::HashMap;

const ORIGINAL_COMMIT: &str = "66e95db";
const RECORDS: [(&str, usize); 5] = [
    ("c", 300),
    ("at", 600),
    ("w", 1600),
    ("wp", 1325),
    ("smn", 400),
];
const AIR_TEMP_KEYS: [&str; 3] = ["air_temp", "air_temp_1", "avg_air_temp_pst1hr"];

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}
fn hx(x: f64) -> String {
    format!("{:x}", x.to_bits())
}
fn opt(v: Option<f64>) -> String {
    v.map_or("-".to_string(), hx)
}
fn od(h: &str) -> Option<f64> {
    (h != "-").then(|| d(h))
}
fn text(h: &str) -> String {
    let bytes: Vec<u8> = (0..h.len())
        .step_by(2)
        .map(|i| {
            u8::from_str_radix(&h[i..i + 2], 16).unwrap_or_else(|_| panic!("bad hex text {h}"))
        })
        .collect();
    String::from_utf8(bytes).unwrap_or_else(|_| panic!("text not UTF-8 {h}"))
}

/// One field of a station's dictionary.
struct Entry {
    key: String,
    nfc: String,
    number: Option<f64>,
    text: Option<String>,
}

fn entries(f: &str) -> Vec<Entry> {
    if f.is_empty() {
        return Vec::new();
    }
    f.split(',')
        .map(|e| {
            let p: Vec<&str> = e.split('/').collect();
            assert_eq!(p.len(), 4, "entry fields");
            Entry {
                key: text(p[0]),
                nfc: text(p[1]),
                number: od(p[2]),
                text: (p[3] != "-").then(|| text(p[3])),
            }
        })
        .collect()
}

/// The field a Swift dictionary answers for `key`.
fn lookup<'a>(all: &'a [Entry], key: &str) -> Option<&'a Entry> {
    all.iter().find(|e| swift_text::eq(&e.key, key))
}

#[test]
fn rust_reproduces_the_original_swift_intl_weather_rules() {
    let content = include_str!("fixtures/swift_intl_weather_oracle.tsv");
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
            "c" => {
                let v = d(f[1]);
                (
                    format!("{} {} {}", f[2], f[3], f[4]),
                    format!(
                        "{} {} {}",
                        hx(celsius_to_f(v)),
                        hx(kmh_to_mph(v)),
                        hx(ms_to_mph(v))
                    ),
                )
            }
            "at" => {
                let all = entries(f[1]);
                let candidates: Vec<Option<f64>> = AIR_TEMP_KEYS
                    .iter()
                    .map(|k| lookup(&all, k).and_then(|e| e.number))
                    .collect();
                (f[2].to_string(), opt(air_temp_f(&candidates)))
            }
            "w" | "wp" => {
                let all = entries(f[1]);
                let units: Vec<Option<String>> = all
                    .iter()
                    .map(|e| lookup(&all, &format!("{}-uom", e.key)).and_then(|u| u.text.clone()))
                    .collect();
                let fields: Vec<WindField<'_>> = all
                    .iter()
                    .zip(&units)
                    .map(|(e, u)| WindField {
                        key: &e.nfc,
                        speed: e.number,
                        unit: u.as_deref(),
                    })
                    .collect();
                (f[2].to_string(), opt(wind_mph(&fields)))
            }
            "smn" => {
                let (t, w) = smn_conditions(od(f[1]), od(f[2]), od(f[3]));
                (
                    format!("{} {} {}", f[5], f[6], f[7]),
                    format!("{} {} {}", opt(t), opt(w), f[4]),
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
        "{} of 4225 records differ:\n{}",
        failures.len(),
        failures
            .iter()
            .take(20)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}
