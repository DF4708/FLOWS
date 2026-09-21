// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the emergency radio's relay-directory scrape:
//! the records produced by the ORIGINAL `TruckerRadio.relayChannels(
//! fromDirectory:bundled:)` at the commit that made it a pure static, linked
//! against the bridge, before it moved to
//! `flows_core::recents_and_rides::relay_spans`. Every relay's name, link and
//! carried coordinates are compared byte for byte and bit for bit, built the
//! way the Swift facade builds them.

use flows_core::recents_and_rides as rr;
use std::collections::BTreeMap;

const ORIGINAL_COMMIT: &str = "17622c5";
const FS: char = '\u{1F}';
const RS: char = '\u{1E}';
/// The detail the Swift facade gives every scraped relay.
const DETAIL: &str = "NOAA Weather Radio relay (weatherusa.net)";

const KINDS: &[(&str, usize)] = &[("rs-relays", RECORDS)];
const RECORDS: usize = 1203;

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}
fn od(f: &str) -> Option<f64> {
    (f != "-").then(|| d(f))
}
fn hx(x: f64) -> String {
    format!("{:x}", x.to_bits())
}
fn hdo(x: Option<f64>) -> String {
    x.map_or_else(|| "-".to_string(), hx)
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
/// `"L<n>:" + rows joined by U+001E`.
fn rows(f: &str) -> Vec<&str> {
    let (n, body) = f
        .strip_prefix('L')
        .and_then(|rest| rest.split_once(':'))
        .unwrap_or_else(|| panic!("bad row list {f}"));
    let n: usize = n.parse().expect("count");
    if n == 0 {
        return Vec::new();
    }
    let out: Vec<&str> = body.split(RS).collect();
    assert_eq!(out.len(), n, "row count in {f}");
    out
}
fn row_text(v: &[String]) -> String {
    format!("L{}:{}", v.len(), v.join(&RS.to_string()))
}

/// A bundled station: its name and its coordinates.
struct Bundled {
    name: String,
    lat: Option<f64>,
    lon: Option<f64>,
}

fn record(f: &[&str]) -> Option<String> {
    match f[0] {
        "rs-relays" => {
            let html = text(f[1]);
            let bundled: Vec<Bundled> = rows(f[2])
                .into_iter()
                .map(|row| {
                    let c: Vec<&str> = row.split(FS).collect();
                    assert_eq!(c.len(), 5, "channel fields in {row}");
                    Bundled {
                        name: text(c[0]),
                        lat: od(c[3]),
                        lon: od(c[4]),
                    }
                })
                .collect();
            let names: Vec<&str> = bundled.iter().map(|b| b.name.as_str()).collect();
            let located: Vec<bool> = bundled
                .iter()
                .map(|b| b.lat.is_some() && b.lon.is_some())
                .collect();
            let got = rr::relay_spans(&html, &names, &located).map_or_else(
                || "-".to_string(),
                |spans| {
                    row_text(
                        &spans
                            .iter()
                            .map(|s| {
                                let (lat, lon) = s
                                    .bundled
                                    .map_or((None, None), |k| (bundled[k].lat, bundled[k].lon));
                                let name = format!(
                                    "{}{}",
                                    rr::RELAY_NAME_PREFIX,
                                    &html[s.label.0..s.label.1]
                                );
                                [
                                    ht(&name),
                                    ht(DETAIL),
                                    ht(&html[s.url.0..s.url.1]),
                                    hdo(lat),
                                    hdo(lon),
                                ]
                                .join(&FS.to_string())
                            })
                            .collect::<Vec<_>>(),
                    )
                },
            );
            (got != f[3]).then(|| format!("got {got}"))
        }
        other => Some(format!("unknown record kind {other}")),
    }
}

#[test]
fn rust_reproduces_the_original_swift_relay_scrape_bit_for_bit() {
    let fixture = include_str!("fixtures/swift_relay_scrape_oracle.tsv");
    let header = fixture.lines().next().unwrap_or_default();
    assert!(
        header.starts_with("# FROZEN SWIFT ORACLE") && header.contains(ORIGINAL_COMMIT),
        "the fixture header must name the original commit: {header}"
    );
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut failures: Vec<String> = Vec::new();
    let mut parsed = 0usize;
    for line in fixture
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
    {
        let f: Vec<&str> = line.split('\t').collect();
        *counts.entry(f[0].to_string()).or_default() += 1;
        if f.get(3).is_some_and(|r| *r != "-") {
            parsed += 1;
        }
        if let Some(got) = record(&f) {
            let shown: String = line.chars().take(200).collect();
            failures.push(format!(
                "{shown}\n    {}",
                got.chars().take(200).collect::<String>()
            ));
        }
    }
    let expected: BTreeMap<String, usize> =
        KINDS.iter().map(|&(k, n)| (k.to_string(), n)).collect();
    assert_eq!(counts, expected, "record kinds and counts");
    assert!(
        parsed > 50,
        "too few pages parsed ({parsed}) to pin the merge"
    );
    let total: usize = counts.values().sum();
    println!(
        "relay-scrape oracle: {total} records ({parsed} pages parsed), {} mismatches",
        failures.len()
    );
    assert!(
        failures.is_empty(),
        "{} of {total} records differ from the Swift original; first:\n{}",
        failures.len(),
        failures
            .iter()
            .take(12)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}
