// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen Swift oracle for reading a turn-by-turn instruction: records
//! from the ORIGINAL `ManeuverSymbol`, `LaneGuidance` and `LaneBox` at
//! commit ORIGINAL_COMMIT, before the rules moved to `flows_core::maneuver`.
//!
//! The `u-*` records are ICU's and Swift's character classes, which
//! `swift_text_tables.rs` turns into `swift_text`'s tables; this test reads
//! the instruction (`m`), lit-lane (`h`) and lane-box (`b`) records and
//! turns Rust's answers back into the words Swift showed.

use flows_core::maneuver::{
    advice, exit_number, highlighted, lane_box, lane_phrase, side, stripped_destination, symbol,
    turn, LaneSide, SYMBOL_NAMES,
};
use std::collections::HashMap;

const ORIGINAL_COMMIT: &str = "9e8fcef";
const RECORDS: [(&str, usize); 3] = [("m", 8229), ("h", 378), ("b", 1594)];

fn text(h: &str) -> String {
    let bytes: Vec<u8> = (0..h.len())
        .step_by(2)
        .map(|i| {
            u8::from_str_radix(&h[i..i + 2], 16).unwrap_or_else(|_| panic!("bad hex text {h}"))
        })
        .collect();
    String::from_utf8(bytes).unwrap_or_else(|_| panic!("text not UTF-8 {h}"))
}

fn side_code(s: LaneSide) -> u8 {
    s as u8
}

fn side_word(s: LaneSide) -> &'static str {
    match s {
        LaneSide::Left => "left",
        LaneSide::Right => "right",
        LaneSide::Center => "center",
    }
}

fn phrase(p: Option<(LaneSide, i64)>) -> String {
    p.map_or_else(|| "-".to_owned(), |(s, n)| format!("{},{n}", side_code(s)))
}

/// The advice field as the harness wrote it: count, side, and the words.
fn advice_field(instruction: &str) -> String {
    let Some(a) = advice(instruction) else {
        return "-".to_owned();
    };
    let words = if a.keep {
        format!("Keep {}", side_word(a.side))
    } else {
        let plural = if a.count == 1 { "lane" } else { "lanes" };
        format!("Use the {} {} {plural}", a.count, side_word(a.side))
    };
    let hex: String = words.bytes().map(|b| format!("{b:02x}")).collect();
    format!("{},{},{hex}", a.count, side_code(a.side))
}

fn ints(f: &str) -> Vec<i64> {
    if f.is_empty() {
        Vec::new()
    } else {
        f.split(',').map(|v| v.parse().expect("number")).collect()
    }
}

#[test]
fn rust_matches_the_frozen_swift_maneuver_symbol_oracle() {
    let fixture = include_str!("fixtures/swift_maneuver_symbol_oracle.tsv");
    assert!(
        fixture.contains(ORIGINAL_COMMIT),
        "the header names the original commit"
    );
    let mut counts: HashMap<&str, usize> = HashMap::new();
    let mut bad = Vec::new();
    for line in fixture.lines().filter(|l| !l.starts_with('#')) {
        let f: Vec<&str> = line.split('\t').collect();
        if f[0].starts_with("u-") {
            continue;
        }
        *counts.entry(f[0]).or_default() += 1;
        match f[0] {
            "m" => {
                let s = text(f[1]);
                let got = [
                    SYMBOL_NAMES[usize::from(symbol(&s))]
                        .bytes()
                        .map(|b| format!("{b:02x}"))
                        .collect::<String>(),
                    side(&s).to_string(),
                    turn(&s).to_string(),
                    advice_field(&s),
                    exit_number(&s).map_or_else(
                        || "-".to_owned(),
                        |e| e.bytes().map(|b| format!("{b:02x}")).collect(),
                    ),
                    stripped_destination(&s)
                        .bytes()
                        .map(|b| format!("{b:02x}"))
                        .collect(),
                    phrase(lane_phrase(&s)),
                    phrase(lane_phrase(&flows_core::swift_text::lowercased(&s))),
                ];
                if got.iter().map(String::as_str).ne(f[2..].iter().copied()) {
                    bad.push(format!("{line}\n  rust: {}", got.join("\t")));
                }
            }
            "h" => {
                let count: i64 = f[1].parse().expect("count");
                let side = match f[2] {
                    "0" => LaneSide::Left,
                    "1" => LaneSide::Right,
                    _ => LaneSide::Center,
                };
                let total: i64 = f[3].parse().expect("total");
                let (lo, hi) = highlighted(count, side, total);
                let got: Vec<i64> = (lo..hi).collect();
                if got != ints(f[4]) {
                    bad.push(format!("{line}\n  rust: {got:?}"));
                }
            }
            "b" => {
                let primaries: Vec<u8> = ints(f[2])
                    .into_iter()
                    .map(|t| u8::try_from(t).expect("turn"))
                    .collect();
                let got = lane_box(&primaries, &ints(f[3]), &text(f[1]))
                    .iter()
                    .map(|a| format!("{}:{}:{}", a.turn, u8::from(a.lit), u8::from(a.u_turn_left)))
                    .collect::<Vec<_>>()
                    .join(",");
                if got != f[4] {
                    bad.push(format!("{line}\n  rust: {got}"));
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

/// Every class the hand-matched patterns use, checked against the fixture's
/// range records over the whole scalar domain: ICU's for `lane_phrase`,
/// Swift Regex's (each scalar as a Character of its own) for `exit_number`.
#[test]
fn the_regex_classes_match_the_frozen_records_for_every_scalar() {
    use flows_core::swift_text::{icu, swift_regex};
    let fixture = include_str!("fixtures/swift_maneuver_symbol_oracle.tsv");
    let rx = |c: char, class: fn(&str) -> bool| class(c.encode_utf8(&mut [0; 4]));
    let classes: [(&str, &dyn Fn(char) -> bool); 13] = [
        ("u-icu-digit", &icu::is_digit),
        ("u-icu-space", &icu::is_space),
        ("u-icu-word", &icu::is_word),
        ("u-icu-skip", &icu::is_skip),
        ("u-cws", &icu::is_character_whitespace),
        ("u-rx-digit", &|c| rx(c, swift_regex::is_digit)),
        ("u-rx-space", &|c| rx(c, swift_regex::is_space)),
        ("u-rx-word", &|c| rx(c, swift_regex::is_word)),
        ("u-rx-ci-az", &|c| {
            rx(c, swift_regex::is_case_insensitive_az)
        }),
        ("u-rx-ci-e", &|c| {
            swift_regex::case_insensitive_is(c.encode_utf8(&mut [0; 4]), 'e')
        }),
        ("u-rx-ci-x", &|c| {
            swift_regex::case_insensitive_is(c.encode_utf8(&mut [0; 4]), 'x')
        }),
        ("u-rx-ci-i", &|c| {
            swift_regex::case_insensitive_is(c.encode_utf8(&mut [0; 4]), 'i')
        }),
        ("u-rx-ci-t", &|c| {
            swift_regex::case_insensitive_is(c.encode_utf8(&mut [0; 4]), 't')
        }),
    ];
    for (kind, class) in classes {
        let ranges: Vec<(u32, u32)> = fixture
            .lines()
            .filter_map(|l| {
                let f: Vec<&str> = l.split('\t').collect();
                (f[0] == kind).then(|| {
                    let h = |s: &str| u32::from_str_radix(s, 16).expect("hex");
                    (h(f[1]), h(f[2]))
                })
            })
            .collect();
        assert!(!ranges.is_empty(), "no {kind} records");
        let wrong: Vec<u32> = (0..=0x10_FFFF_u32)
            .filter_map(char::from_u32)
            .filter(|&c| {
                let v = c as u32;
                class(c) != ranges.iter().any(|&(lo, hi)| (lo..=hi).contains(&v))
            })
            .map(|c| c as u32)
            .take(8)
            .collect();
        assert!(wrong.is_empty(), "{kind} differs at {wrong:X?}");
    }
}

/// Swift Regex's classes for Characters of several scalars (marks, joiners,
/// skin tones, Prepend scalars before a letter, flags, CR LF): the first
/// scalar decides `\d`, `\s` and the word test (a "_" with more on it is no
/// word Character), and no such Character is an
/// ASCII letter.
#[test]
fn the_swift_regex_classes_match_the_frozen_characters_of_several_scalars() {
    use flows_core::swift_text::swift_regex;
    let fixture = include_str!("fixtures/swift_maneuver_symbol_oracle.tsv");
    let mut seen = 0;
    let mut wrong = Vec::new();
    for line in fixture.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        if f[0] != "u-rx-cluster" {
            continue;
        }
        seen += 1;
        let c = text(f[1]);
        let got: String = [
            swift_regex::is_digit(&c),
            swift_regex::is_space(&c),
            swift_regex::is_word(&c),
            swift_regex::is_case_insensitive_az(&c),
            swift_regex::case_insensitive_is(&c, 'e'),
            swift_regex::case_insensitive_is(&c, 'x'),
            swift_regex::case_insensitive_is(&c, 'i'),
            swift_regex::case_insensitive_is(&c, 't'),
        ]
        .iter()
        .map(|&b| if b { '1' } else { '0' })
        .collect();
        if got != f[2] {
            wrong.push(format!("{} want {} got {got}", f[1], f[2]));
        }
    }
    assert_eq!(seen, 1948, "u-rx-cluster records");
    assert!(
        wrong.is_empty(),
        "{} of {seen} differ:\n{}",
        wrong.len(),
        wrong
            .iter()
            .take(200)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}
