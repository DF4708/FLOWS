// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! `flows_core::swift_text::tables` is generated from the frozen oracles' `u-*`
//! records: the Swift runtime's own text tables, read out scalar by scalar by
//! the harnesses. This test builds the file from the fixtures and fails when
//! the checked-in copy differs, so a fixture change cannot leave a stale
//! table behind. After a fixture changes, rewrite the file with
//!
//! ```sh
//! FLOWS_WRITE_SWIFT_TEXT_TABLES=1 cargo test -p flows-bridge --test swift_text_tables
//! ```
//!
//! Where each table comes from:
//! - `fixtures/swift_places_text_oracle.tsv`: word and number starts,
//!   whitespace, the grapheme-break probe patterns, the full lower- and
//!   uppercase mappings, the canonical decompositions and combining classes;
//! - `fixtures/swift_hazard_feeds_oracle.tsv`: the `u-wsnl` records
//!   (`CharacterSet.whitespacesAndNewlines`);
//! - `fixtures/swift_alert_text_oracle.tsv`: the case-insensitive search's
//!   folds (a `u-fold` record kept where a `u-ci-fold` record says the search
//!   applies it) and the `u-ci-after` ranges (scalars that keep a match from
//!   ending just before them);
//! - `fixtures/swift_tags_and_replies_oracle.tsv`: the single `u-letter`
//!   record (`Character.isLetter`, as ranges over every scalar).
//!
//! `swift_places_text_oracle.rs` and its siblings then check every table
//! against the same records over the whole scalar domain.

use std::collections::BTreeSet;
use std::fmt::Write as _;
use std::path::PathBuf;

/// Set to rewrite `tables.rs` instead of comparing with it.
const WRITE_ENV: &str = "FLOWS_WRITE_SWIFT_TEXT_TABLES";

/// The 17 probes of `u-gcb`, in the harness's order, name a
/// Grapheme_Cluster_Break class (plus Extended_Pictographic and the
/// Indic_Conjunct_Break properties). Codes are those of `swift_text::Gcb`;
/// `Other` is not stored, it is the default.
const PATTERNS: &[(&str, Option<u32>)] = &[
    ("10000000000000000", None),     // Other
    ("00000000000000000", Some(1)),  // Control
    ("00000000000000001", Some(2)),  // CR (only CR + LF is one Character)
    ("00000000000000010", Some(3)),  // LF
    ("11011001010101100", Some(4)),  // Extend, Indic_Conjunct_Break=Extend
    ("11011001010100000", Some(5)),  // Extend without it (ZWNJ)
    ("11001001010100000", Some(6)),  // SpacingMark
    ("10100110101000000", Some(7)),  // Prepend
    ("10001000000000000", Some(8)),  // Extended_Pictographic
    ("10000000000100000", Some(9)),  // Indic_Conjunct_Break=Consonant
    ("11011001010111100", Some(10)), // Indic_Conjunct_Break=Linker
    ("11001001010101100", Some(11)), // ZWJ
    ("10000100000000000", Some(12)), // Regional_Indicator
    ("10000011100000000", Some(13)), // L
    ("10000001111000000", Some(14)), // V
    ("10000000011000000", Some(15)), // T
    ("10000001101000000", Some(16)), // LV
    ("10000001001000000", Some(17)), // LVT
];

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn fixture(name: &str) -> String {
    let path = root().join("tests/fixtures").join(name);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

fn hex(field: &str) -> u32 {
    u32::from_str_radix(field, 16).unwrap_or_else(|_| panic!("bad hex {field:?}"))
}

/// A mapping column: hex scalars separated by `sep`.
fn scalars(field: &str, sep: char) -> Vec<u32> {
    field.split(sep).map(hex).collect()
}

fn pair(f: &[&str]) -> Vec<u32> {
    vec![hex(f[1]), hex(f[2])]
}

/// Every table, in the order the file lists them, with its first column.
#[derive(Default)]
struct Tables {
    word: Vec<Vec<u32>>,
    num: Vec<Vec<u32>>,
    letter: Vec<Vec<u32>>,
    ws: Vec<Vec<u32>>,
    wsnl: Vec<Vec<u32>>,
    gcb: Vec<Vec<u32>>,
    ccc: Vec<Vec<u32>>,
    lower: Vec<(u32, Vec<u32>)>,
    upper: Vec<(u32, Vec<u32>)>,
    nfd: Vec<(u32, Vec<u32>)>,
    fold: Vec<(u32, Vec<u32>)>,
    after: Vec<Vec<u32>>,
}

fn read_tables() -> Tables {
    let mut t = Tables::default();

    for line in fixture("swift_tags_and_replies_oracle.tsv").lines() {
        if let Some(rest) = line.strip_prefix("u-letter\t") {
            let f: Vec<&str> = rest.split('\t').collect();
            t.letter = f[1]
                .split(',')
                .map(|r| {
                    let (lo, hi) = r
                        .split_once('-')
                        .unwrap_or_else(|| panic!("bad range {r:?}"));
                    vec![hex(lo), hex(hi)]
                })
                .collect();
            let declared: usize = f[0].parse().expect("u-letter count");
            assert_eq!(
                t.letter.len(),
                declared,
                "u-letter: range count does not match its record"
            );
        }
    }

    let mut fold: Vec<(u32, Vec<u32>)> = Vec::new();
    let mut applied: BTreeSet<u32> = BTreeSet::new();
    for line in fixture("swift_alert_text_oracle.tsv").lines() {
        let f: Vec<&str> = line.split('\t').collect();
        match f[0] {
            "u-fold" => fold.push((
                hex(f[1]),
                if f[2].is_empty() {
                    Vec::new()
                } else {
                    scalars(f[2], ' ')
                },
            )),
            "u-ci-fold" if f[2] == "1" => {
                applied.insert(hex(f[1]));
            }
            "u-ci-after" => t.after.push(pair(&f)),
            _ => {}
        }
    }
    t.fold = fold
        .into_iter()
        .filter(|(s, _)| applied.contains(s))
        .collect();

    for line in fixture("swift_hazard_feeds_oracle.tsv").lines() {
        if line.starts_with("u-wsnl\t") {
            let f: Vec<&str> = line.split('\t').collect();
            t.wsnl.push(pair(&f));
        }
    }

    for line in fixture("swift_places_text_oracle.tsv").lines() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        match f[0] {
            "u-word" => t.word.push(pair(&f)),
            "u-num" => t.num.push(pair(&f)),
            "u-ws" => t.ws.push(pair(&f)),
            "u-gcb" => {
                let code = PATTERNS
                    .iter()
                    .find(|(p, _)| *p == f[3])
                    .unwrap_or_else(|| {
                        panic!(
                            "unknown grapheme probe pattern {} at {}-{}: add it to PATTERNS and to swift_text::Gcb",
                            f[3], f[1], f[2]
                        )
                    })
                    .1;
                if let Some(code) = code {
                    t.gcb.push(vec![hex(f[1]), hex(f[2]), code]);
                }
            }
            "u-ccc" => t.ccc.push(vec![
                hex(f[1]),
                hex(f[2]),
                f[3].parse().expect("decimal combining class"),
            ]),
            "u-lower" => t.lower.push((hex(f[1]), scalars(f[2], ','))),
            "u-upper" => t.upper.push((hex(f[1]), scalars(f[2], ','))),
            "u-nfd" => t.nfd.push((hex(f[1]), scalars(f[2], ','))),
            _ => {}
        }
    }
    t
}

fn check_sorted(name: &str, keys: &[u32]) {
    assert!(!keys.is_empty(), "no {name} records");
    assert!(
        keys.windows(2).all(|w| w[0] < w[1]),
        "{name} is not sorted and unique"
    );
}

/// Each mapping as one row: the scalar, the mapping, and zeros to `width`.
fn padded(rows: &[(u32, Vec<u32>)], width: usize, name: &str) -> Vec<Vec<u32>> {
    rows.iter()
        .map(|(scalar, mapping)| {
            assert!(
                mapping.len() < width,
                "{name}: mapping of {scalar:x} longer than {}",
                width - 1
            );
            let mut row = vec![*scalar];
            row.extend(mapping);
            row.resize(width, 0);
            row
        })
        .collect()
}

/// rustfmt's `max_width`. Packing an array of short literals, it counts the
/// space after every item, the line's last one included, so a packed line
/// ends at 99 columns at most.
const MAX_WIDTH: usize = 100;

/// One table: its doc lines, the values packed the way rustfmt packs an
/// array of short literals (as many to a line as fit), so the file is already
/// in `cargo fmt`'s form, and its stride.
fn array(name: &str, doc: &[&str], stride: usize, rows: &[Vec<u32>]) -> String {
    let mut out = String::new();
    for d in doc {
        let _ = writeln!(out, "/// {d}");
    }
    let _ = writeln!(out, "pub const {name}: &[u32] = &[");
    let mut line = String::new();
    for v in rows.iter().flatten() {
        let item = format!("0x{v:X},");
        if line.is_empty() {
            line = format!("    {item}");
        } else if line.len() + 1 + item.len() < MAX_WIDTH {
            line.push(' ');
            line.push_str(&item);
        } else {
            let _ = writeln!(out, "{line}");
            line = format!("    {item}");
        }
    }
    if !line.is_empty() {
        let _ = writeln!(out, "{line}");
    }
    let _ = writeln!(out, "];");
    let _ = writeln!(out, "/// Numbers per entry of [`{name}`].");
    let _ = writeln!(out, "pub const {name}_STRIDE: usize = {stride};");
    out.push('\n');
    out
}

fn generate() -> String {
    let t = read_tables();
    let first = |rows: &[Vec<u32>]| rows.iter().map(|r| r[0]).collect::<Vec<u32>>();
    let first_map = |rows: &[(u32, Vec<u32>)]| rows.iter().map(|r| r.0).collect::<Vec<u32>>();
    for (name, keys) in [
        ("word", first(&t.word)),
        ("num", first(&t.num)),
        ("ws", first(&t.ws)),
        ("wsnl", first(&t.wsnl)),
        ("gcb", first(&t.gcb)),
        ("ccc", first(&t.ccc)),
        ("lower", first_map(&t.lower)),
        ("upper", first_map(&t.upper)),
        ("nfd", first_map(&t.nfd)),
        ("fold", first_map(&t.fold)),
        ("ci-after", first(&t.after)),
        ("letter", first(&t.letter)),
    ] {
        check_sorted(name, &keys);
    }
    let fold_width = 1 + t.fold.iter().map(|(_, m)| m.len()).max().unwrap_or(0);

    let body = [
        array("WORD_RANGES", &["Scalars whose `Character` answers `isLetter || isNumber`, as inclusive `lo, hi` pairs."], 2, &t.word),
        array("NUMBER_RANGES", &["Scalars whose `Character` answers `isNumber`, as inclusive `lo, hi` pairs."], 2, &t.num),
        array("LETTER_RANGES", &["Scalars whose `Character` answers `isLetter` (the Alphabetic property), as inclusive", "`lo, hi` pairs (from the tags-and-replies fixture)."], 2, &t.letter),
        array("WHITESPACE_RANGES", &["`CharacterSet.whitespaces`, as inclusive `lo, hi` pairs."], 2, &t.ws),
        array("WHITESPACE_NEWLINE_RANGES", &["`CharacterSet.whitespacesAndNewlines`, as inclusive `lo, hi` pairs (from the", "hazard-feeds fixture)."], 2, &t.wsnl),
        array("GCB_RANGES", &["Grapheme-break classes as `lo, hi, class` triples (the codes of `Gcb`); a", "scalar in no range is `Other`."], 3, &t.gcb),
        array("CCC_RANGES", &["Canonical combining classes as `lo, hi, ccc` triples; a scalar in no range has class 0."], 3, &t.ccc),
        array("LOWER_MAP", &["`Unicode.Scalar.Properties.lowercaseMapping` where it is not the scalar itself:", "`scalar, first, second` with 0 for an absent second."], 3, &padded(&t.lower, 3, "lower")),
        array("UPPER_MAP", &["`Unicode.Scalar.Properties.uppercaseMapping` where it is not the scalar itself:", "`scalar, first, second, third` with 0 for absent places."], 4, &padded(&t.upper, 4, "upper")),
        array("NFD_MAP", &["Full canonical decompositions outside the Hangul syllables, which decompose", "arithmetically: `scalar, d0, d1, d2, d3` with 0 for absent places."], 5, &padded(&t.nfd, 5, "nfd")),
        array("FOLD_MAP", &["The folds Foundation's case-insensitive search applies (en_US), where a scalar", "does not fold to itself: `scalar, f0, f1, f2` with 0 for absent places (from the", "alert-text fixture)."], fold_width, &padded(&t.fold, fold_width, "fold")),
        array("CI_AFTER_BLOCKER_RANGES", &["Scalars that keep a case-insensitive match from ending just before them, as", "inclusive `lo, hi` pairs (from the alert-text fixture)."], 2, &t.after),
    ]
    .concat();

    let header = format!(
        "// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The Swift runtime's text tables, as the frozen oracle read them.
//!
//! GENERATED by `flows-bridge/tests/swift_text_tables.rs` from the `u-*`
//! records of the frozen oracle fixtures; do not edit by hand. Every table is
//! sorted by its first column for binary search, and
//! `swift_places_text_oracle.rs` checks each one against the fixture over the
//! whole scalar domain.
//!
//! Counts: {} word ranges, {} number ranges, {} letter ranges, {} whitespace ranges
//! ({} with newlines),
//! {} grapheme-class ranges, {} combining-class ranges, {} lowercase
//! mappings, {} uppercase mappings, {} decompositions.

#![allow(clippy::unreadable_literal)]

",
        t.word.len(),
        t.num.len(),
        t.letter.len(),
        t.ws.len(),
        t.wsnl.len(),
        t.gcb.len(),
        t.ccc.len(),
        t.lower.len(),
        t.upper.len(),
        t.nfd.len()
    );
    format!("{header}{}\n", body.trim_end_matches('\n'))
}

#[test]
fn swift_text_tables_are_what_the_fixtures_generate() {
    let path = root().join("../flows-core/src/swift_text/tables.rs");
    let generated = generate();
    if std::env::var_os(WRITE_ENV).is_some() {
        std::fs::write(&path, &generated).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        println!("wrote {}", path.display());
        return;
    }
    let current =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    assert!(
        current == generated,
        "{} differs from what the fixtures generate; rewrite it with {WRITE_ENV}=1 \
         cargo test -p flows-bridge --test swift_text_tables",
        path.display()
    );
}
