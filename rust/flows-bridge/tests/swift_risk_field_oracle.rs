// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the risk-field reader: 6,335 records produced
//! by the ORIGINAL `RiskFieldService` at commit a007de0 — the FRB1 parser
//! over hand-built, random and corrupt shards; the loaded service's
//! `scoreRow`, `summary` and `zips(in:)` over 21 shards written to a temp
//! repo; the static `selectZips` over random entry sets; and
//! `harmonicRescore` against synthetic FLHH tables — before that code moved
//! to `flows_core::risk_field`. Every number is compared bit for bit and
//! every order exactly.

use flows_core::climate::{parse_flhh, HarmonicTable, WeekTrig};
use flows_core::risk_field::{Entry, RiskField};
use std::collections::BTreeMap;

const BASE_COMMIT: &str = "a007de042d12e736fdd86398e1ea54ca31aadc1f";
const FS: char = '\u{1F}';
const RS: char = '\u{1E}';

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}
fn hx(x: f64) -> String {
    format!("{:x}", x.to_bits())
}
fn i(t: &str) -> i64 {
    t.parse().unwrap_or_else(|_| panic!("bad int {t}"))
}
fn text(field: &str) -> String {
    let body = field
        .strip_prefix("t:")
        .unwrap_or_else(|| panic!("bad text {field}"));
    let bytes = body.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut k = 0;
    while k < bytes.len() {
        if bytes[k] == b'\\' {
            let hex = std::str::from_utf8(&bytes[k + 1..k + 3]).expect("escape");
            out.push(u8::from_str_radix(hex, 16).expect("escape byte"));
            k += 3;
        } else {
            out.push(bytes[k]);
            k += 1;
        }
    }
    String::from_utf8(out).expect("Swift strings are UTF-8")
}
fn ht(s: &str) -> String {
    let mut out = String::from("t:");
    for b in s.bytes() {
        if (0x20..=0x7E).contains(&b) && b != b'\\' {
            out.push(b as char);
        } else {
            out.push_str(&format!("\\{b:02x}"));
        }
    }
    out
}
fn hto(s: Option<&str>) -> String {
    s.map_or_else(|| "-".to_string(), ht)
}
fn bytes(field: &str) -> Vec<u8> {
    let hex = field
        .strip_prefix("b:")
        .unwrap_or_else(|| panic!("bad bytes {field}"));
    (0..hex.len())
        .step_by(2)
        .map(|k| u8::from_str_radix(&hex[k..k + 2], 16).expect("hex byte"))
        .collect()
}
fn list(f: &str) -> Vec<&str> {
    let (head, body) = f.split_once(':').unwrap_or_else(|| panic!("bad list {f}"));
    let n: usize = head.trim_start_matches('L').parse().expect("list count");
    if n == 0 {
        return Vec::new();
    }
    let v: Vec<&str> = body.split(',').collect();
    assert_eq!(v.len(), n, "list count in {f}");
    v
}
fn lst(items: &[String]) -> String {
    format!("L{}:{}", items.len(), items.join(","))
}

/// One entry as the harness wrote it: fields joined by U+001F.
fn ent_out(e: &Entry) -> String {
    let scores: Vec<String> = e.scores.iter().map(|&s| hx(s)).collect();
    let ring = e.ring.as_ref().map_or_else(
        || "-".to_string(),
        |r| {
            r.iter()
                .map(|&(lat, lon)| format!("{}/{}", hx(lat), hx(lon)))
                .collect::<Vec<_>>()
                .join(",")
        },
    );
    [
        ht(&e.zip),
        hx(e.lat),
        hx(e.lon),
        scores.join(","),
        hto(e.summary.as_deref()),
        ring,
    ]
    .join(&FS.to_string())
}
fn ents_out(entries: &[Entry]) -> String {
    entries
        .iter()
        .map(ent_out)
        .collect::<Vec<_>>()
        .join(&RS.to_string())
}
fn ent_in(field: &str) -> Entry {
    let f: Vec<&str> = field.split(FS).collect();
    assert_eq!(f.len(), 6, "entry fields in {field}");
    Entry {
        zip: text(f[0]),
        lat: d(f[1]),
        lon: d(f[2]),
        scores: if f[3].is_empty() {
            Vec::new()
        } else {
            f[3].split(',').map(d).collect()
        },
        summary: (f[4] != "-").then(|| text(f[4])),
        ring: (f[5] != "-").then(|| {
            f[5].split(',')
                .map(|p| {
                    let (lat, lon) = p.split_once('/').expect("ring point");
                    (d(lat), d(lon))
                })
                .collect()
        }),
    }
}
fn ents_in(field: &str) -> Vec<Entry> {
    if field.is_empty() {
        return Vec::new();
    }
    field.split(RS).map(ent_in).collect()
}
fn zips_out(field: &RiskField, indices: &[usize]) -> String {
    lst(&indices
        .iter()
        .map(|&i| ht(&field.entries()[i].zip))
        .collect::<Vec<_>>())
}

#[test]
fn rust_reproduces_the_original_swift_risk_field_reader() {
    let content = include_str!("fixtures/swift_risk_field_oracle.tsv");
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
    let mut check = |kind: &str, line: &str, got: String, want: &str| {
        if got != want {
            failures.push(format!(
                "{kind}\t{}\n    got  {}\n    want {}",
                line.chars().take(200).collect::<String>(),
                got.chars().take(400).collect::<String>(),
                want.chars().take(400).collect::<String>()
            ));
        }
    };
    let mut shards: BTreeMap<String, RiskField> = BTreeMap::new();
    let mut sets: BTreeMap<String, RiskField> = BTreeMap::new();
    let mut tables: BTreeMap<String, HarmonicTable> = BTreeMap::new();

    for line in content
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
    {
        let f: Vec<&str> = line.split('\t').collect();
        *counts.entry(f[0].to_string()).or_default() += 1;
        match f[0] {
            "rf-parse" => {
                let got = match RiskField::parse_frb1(&bytes(f[2])) {
                    None => "-".to_string(),
                    Some(field) => [
                        ht(field.generated()),
                        lst(&field.families().iter().map(|s| ht(s)).collect::<Vec<_>>()),
                        ents_out(field.entries()),
                    ]
                    .join("\t"),
                };
                check("rf-parse", line, got, &f[3..].join("\t"));
            }
            "rf-shard" => {
                let field =
                    RiskField::parse_frb1(&bytes(f[2])).expect("a shard the service loaded");
                shards.insert(f[1].to_string(), field);
            }
            "rf-families" => {
                let field = &shards[f[1]];
                let got = format!(
                    "{}\t{}",
                    lst(&field.families().iter().map(|s| ht(s)).collect::<Vec<_>>()),
                    ht(field.generated())
                );
                check("rf-families", line, got, &f[2..4].join("\t"));
            }
            "rf-near" => {
                let field = &shards[f[1]];
                let hit = field.nearest(d(f[2]), d(f[3])).map(|k| &field.entries()[k]);
                let row = hit.map_or_else(
                    || "-".to_string(),
                    |e| lst(&e.scores.iter().map(|&s| hx(s)).collect::<Vec<_>>()),
                );
                let summary = hto(hit.and_then(|e| e.summary.as_deref()));
                check(
                    "rf-near",
                    line,
                    format!("{row}\t{summary}"),
                    &f[4..6].join("\t"),
                );
            }
            "rf-zips" => {
                let field = &shards[f[1]];
                let (c_lat, c_lon, d_lat, d_lon) = (d(f[2]), d(f[3]), d(f[4]), d(f[5]));
                let got = match field.family_index(&text(f[6])) {
                    None => "L0:".to_string(),
                    Some(fi) => zips_out(
                        field,
                        &field.select(
                            c_lat - d_lat / 2.0,
                            c_lat + d_lat / 2.0,
                            c_lon - d_lon / 2.0,
                            c_lon + d_lon / 2.0,
                            fi as i64,
                            i(f[7]),
                        ),
                    ),
                };
                check("rf-zips", line, got, f[8]);
            }
            "rf-set" => {
                sets.insert(
                    f[1].to_string(),
                    RiskField::from_entries(String::new(), Vec::new(), ents_in(f[2])),
                );
            }
            "rf-select" => {
                let field = &sets[f[1]];
                let got = zips_out(
                    field,
                    &field.select(d(f[2]), d(f[3]), d(f[4]), d(f[5]), i(f[6]), i(f[7])),
                );
                check("rf-select", line, got, f[8]);
            }
            "rf-table" => {
                tables.insert(
                    f[1].to_string(),
                    parse_flhh(&bytes(f[2])).expect("a table the Swift read"),
                );
            }
            "rf-rescore" => {
                let table = &tables[f[1]];
                let families: Vec<String> = list(f[3]).into_iter().map(text).collect();
                let mut field = RiskField::from_entries(String::new(), families, ents_in(f[4]));
                let pairs = field.family_pairs(table);
                let rebuilt = field.harmonic_rescore(table, &WeekTrig::new(i(f[2])), &pairs);
                check(
                    "rf-rescore",
                    line,
                    format!("{rebuilt}\t{}", ents_out(field.entries())),
                    &f[5..7].join("\t"),
                );
            }
            other => panic!("unknown record kind {other}"),
        }
    }
    let total: usize = counts.values().sum();
    assert!(total >= 6_000, "fixture truncated: {total}");
    assert_eq!(counts.len(), 9, "record kinds: {counts:?}");
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
