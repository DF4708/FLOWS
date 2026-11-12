// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the national weather alerts: records from the
//! ORIGINAL `WMOAlertParsing` at commit ORIGINAL_COMMIT, before its rules
//! moved to `flows_core::wmo_alerts`. Every answer must be the same bits and
//! the same text. The diacritic folding stays in Swift; the records carry
//! Swift's folded text, which the Rust reads as the facade hands it in.

use flows_core::wmo_alerts::{
    beside_belize, beside_costa_rica, event_in_risk_words, feed_code, names_heavy_rain, parse_cap,
    parse_rss_items, polygon_coords, south_of_mexico, BelizeSide, Point,
};
use std::collections::HashMap;

const ORIGINAL_COMMIT: &str = "923174c";
const RECORDS: [(&str, usize); 6] = [
    ("f", 3724),
    ("p", 433),
    ("r", 536),
    ("c", 533),
    ("e", 964),
    ("h", 2369),
];

fn d(h: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(h, 16).unwrap_or_else(|_| panic!("bad hex double {h}")))
}

fn hx(x: f64) -> String {
    format!("{:x}", x.to_bits())
}

fn th(s: &str) -> String {
    s.bytes().map(|b| format!("{b:02x}")).collect()
}

fn ot(s: Option<&str>) -> String {
    s.map_or_else(|| "-".to_string(), th)
}

fn unhex(h: &str) -> String {
    let bytes: Vec<u8> = (0..h.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&h[i..i + 2], 16).expect("hex byte"))
        .collect();
    String::from_utf8(bytes).expect("utf-8 record text")
}

fn b01(b: bool) -> &'static str {
    if b {
        "1"
    } else {
        "0"
    }
}

fn ring_str(r: &[Point]) -> String {
    r.iter()
        .map(|&(a, b)| format!("{}:{}", hx(a), hx(b)))
        .collect::<Vec<_>>()
        .join(";")
}

fn answer(f: &[&str]) -> Vec<String> {
    match f[0] {
        "f" => {
            let (lat, lon) = (d(f[1]), d(f[2]));
            let side = match beside_belize(lat, lon) {
                BelizeSide::Belize => "b",
                BelizeSide::Mexico => "m",
                BelizeSide::Unsure => "u",
            };
            vec![
                ot(feed_code(lat, lon)),
                b01(south_of_mexico(lat, lon)).to_string(),
                side.to_string(),
                b01(beside_costa_rica(lat, lon)).to_string(),
            ]
        }
        "p" => vec![ring_str(&polygon_coords(&unhex(f[1])))],
        "r" => vec![parse_rss_items(&unhex(f[1]))
            .iter()
            .map(|i| {
                [&i.link, &i.event, &i.severity, &i.expires, &i.published]
                    .iter()
                    .map(|s| th(s))
                    .collect::<Vec<_>>()
                    .join(":")
            })
            .collect::<Vec<_>>()
            .join(",")],
        "c" => match parse_cap(&unhex(f[1])) {
            None => vec!["-".to_string()],
            Some(p) => vec![
                th(&p.event),
                th(&p.severity),
                p.polygons
                    .iter()
                    .map(|r| ring_str(r))
                    .collect::<Vec<_>>()
                    .join("|"),
                ot(p.area_desc.as_deref()),
                ot(p.expires.as_deref()),
                ot(p.effective.as_deref()),
                ot(p.web.as_deref()),
                ot(p.description.as_deref()),
                b01(p.is_live).to_string(),
                ot(p.identifier.as_deref()),
                p.references
                    .iter()
                    .map(|r| th(r))
                    .collect::<Vec<_>>()
                    .join(","),
            ],
        },
        "e" => {
            let event = unhex(f[1]);
            let severity = unhex(f[2]);
            let folded_event = unhex(f[5]);
            let folded_rain = unhex(f[6]);
            vec![th(&event_in_risk_words(
                &event,
                &folded_event,
                &severity,
                &folded_rain,
            ))]
        }
        "h" => vec![b01(names_heavy_rain(&unhex(f[3]))).to_string()],
        k => panic!("unknown record kind {k}"),
    }
}

/// The fields of a record the Swift answered, against which `answer` is set.
fn expected(f: &[&str]) -> Vec<String> {
    let range = match f[0] {
        "f" => 3..7,
        "p" | "r" => 2..3,
        "c" => 2..f.len(),
        "e" => 4..5,
        "h" => 2..3,
        k => panic!("unknown record kind {k}"),
    };
    f[range].iter().map(|s| (*s).to_string()).collect()
}

#[test]
fn the_rust_gives_the_original_swift_answers() {
    let text = include_str!("fixtures/swift_wmo_alerts_oracle.tsv");
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
