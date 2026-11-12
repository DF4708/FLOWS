// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for the tourist stop card's rules: 6,716
//! records from the ORIGINAL `TouristInfo` at commit 2b9201f, before the
//! rules moved to `flows_core::tourist_info`.
//!
//! Each fee and kind record carries the name as Swift cleaned it
//! (`TouristInfo.normalized`, which stays in Swift); this test hands Rust
//! that cleaned name, as the facade does, and turns Rust's code back into
//! the card's words.

use flows_core::tourist_info::{fee, kind, monday_first_index, Fee, Kind};
use std::collections::HashMap;

const ORIGINAL_COMMIT: &str = "2b9201f";
const RECORDS: [(&str, usize); 4] = [("t", 14), ("f", 3965), ("k", 2668), ("d", 69)];

const PARK_DEFAULT: &str = "Free at most park spots. Big parks often charge for each car.";
const SITE_DEFAULT: &str = "Free at most sites like this. Some charge a small fee.";
const VARIES: &str = "Prices vary \u{2014} check before you go.";

fn kind_words(k: Kind) -> &'static str {
    match k {
        Kind::NationalPark => "National park",
        Kind::Museum => "Museum",
        Kind::ThemePark => "Theme park",
        Kind::Zoo => "Zoo",
        Kind::Aquarium => "Aquarium",
        Kind::Park => "Park",
        Kind::Landmark => "Landmark",
        Kind::StatePark => "State park",
        Kind::Monument => "Monument",
        Kind::Cave => "Cave",
        Kind::Waterfall => "Waterfall",
        Kind::Beach => "Beach",
        Kind::Trail => "Trail",
        Kind::Garden => "Garden",
        Kind::WorthAStop => "Place worth a stop",
    }
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

fn list(f: &str) -> Vec<String> {
    if f.is_empty() {
        Vec::new()
    } else {
        f.split(',').map(text).collect()
    }
}

#[test]
fn rust_matches_the_frozen_swift_tourist_info_oracle() {
    let fixture = include_str!("fixtures/swift_tourist_info_oracle.tsv");
    assert!(
        fixture.contains(ORIGINAL_COMMIT),
        "the header names the original commit"
    );
    let mut tables: HashMap<&str, (Vec<String>, Vec<String>)> = HashMap::new();
    let mut counts: HashMap<&str, usize> = HashMap::new();
    let mut bad = Vec::new();
    for line in fixture.lines().filter(|l| !l.starts_with('#')) {
        let f: Vec<&str> = line.split('\t').collect();
        *counts.entry(f[0]).or_default() += 1;
        match f[0] {
            "t" => {
                let keys = list(f[2]);
                let notes = list(f[3]);
                assert_eq!(keys.len(), notes.len(), "table {}", f[1]);
                tables.insert(f[1], (keys, notes));
            }
            "f" => {
                let (keys, notes) = &tables[f[1]];
                let key_refs: Vec<&str> = keys.iter().map(String::as_str).collect();
                let got = match fee(&text(f[3]), &key_refs) {
                    Fee::Table(i) => notes[i].as_str(),
                    Fee::ParkDefault => PARK_DEFAULT,
                    Fee::SiteDefault => SITE_DEFAULT,
                    Fee::Varies => VARIES,
                };
                if got != text(f[4]) {
                    bad.push(format!("{line}\n  rust: {got}"));
                }
            }
            "k" => {
                let category = (f[2] != "-").then(|| text(f[2]));
                let got = kind_words(kind(&text(f[3]), category.as_deref()));
                if got != text(f[4]) {
                    bad.push(format!("{line}\n  rust: {got}"));
                }
            }
            "d" => {
                let weekday: i64 = f[1].parse().expect("weekday");
                let want: i64 = f[2].parse().expect("index");
                if monday_first_index(weekday) != want {
                    bad.push(line.to_string());
                }
            }
            other => panic!("unknown record kind {other}"),
        }
    }
    for (k, n) in RECORDS {
        assert_eq!(counts.get(k).copied().unwrap_or(0), n, "{k} records");
    }
    let total: usize = RECORDS.iter().map(|(_, n)| n).sum();
    assert!(
        bad.is_empty(),
        "{} of {total} records differ:\n{}",
        bad.len(),
        bad.iter().take(12).cloned().collect::<Vec<_>>().join("\n")
    );
}

/// The one rule the oracle cannot pin: between two keys of the same length
/// that a park's name both holds, the smaller by bytes wins, whatever order
/// the keys come in.
#[test]
fn a_tie_between_equal_keys_goes_to_the_smaller_bytes() {
    let name = "olympic glacier national park";
    assert_eq!(fee(name, &["olympic", "glacier"]), Fee::Table(1));
    assert_eq!(fee(name, &["glacier", "olympic"]), Fee::Table(0));
    // Length is counted in Characters: "e\u{301}" is one, as long as "x".
    let marked = "x e\u{301} national park";
    assert_eq!(fee(marked, &["x", "e\u{301}"]), Fee::Table(1));
    assert_eq!(fee(marked, &["e\u{301}", "x"]), Fee::Table(0));
    assert_eq!(fee(marked, &["x", "e\u{301}", "xe"]), Fee::Table(1));
}

/// Swift's `weekday + 5` traps on the five largest weekdays; Rust answers.
#[test]
fn the_weekdays_swift_cannot_add_to_still_answer() {
    for w in (i64::MAX - 4)..=i64::MAX {
        let want = i64::try_from((i128::from(w) + 5) % 7).expect("small");
        assert_eq!(monday_first_index(w), want);
    }
}
