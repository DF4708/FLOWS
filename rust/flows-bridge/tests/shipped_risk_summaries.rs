// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Every summary the shipped risk bundle carries reaches the screen in plain
//! words. The bundle (apple/FLOWS/Resources/app_risk_bundle.frb1) was
//! written before the trainers wrote plain lines, so each ZIP's line goes
//! through the function the app reads it with, `flows_risk_summary_plain`;
//! a rebuilt bundle with a new form is checked here too.

use flows_bridge::risk_field::flows_risk_summary_plain;
use flows_core::risk_field::RiskField;
use std::collections::BTreeMap;
use std::path::PathBuf;

/// Words no driver should have to read on a summary line.
const JARGON: [&str; 13] = [
    "baseline",
    "climatology",
    "convective",
    "elevated",
    "qpf",
    "environmental",
    "seismic",
    "volcanic",
    "precip",
    "radiation",
    "tropical",
    "20-yr",
    "(",
];

#[test]
fn every_shipped_summary_reads_in_plain_words() {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../apple/FLOWS/Resources/app_risk_bundle.frb1");
    let data = std::fs::read(&path).expect("the shipped risk bundle is in the repo");
    let field = RiskField::parse_frb1(&data).expect("the shipped risk bundle parses");
    let mut lines: BTreeMap<String, usize> = BTreeMap::new();
    for entry in field.entries() {
        let Some(text) = entry.summary.as_deref() else {
            continue;
        };
        let line = flows_risk_summary_plain(text);
        assert!(!line.is_empty(), "{}: {text:?} reads as nothing", entry.zip);
        let lower = line.to_lowercase();
        for word in JARGON {
            assert!(
                !lower.contains(word),
                "{}: {text:?} reads as {line:?}, which says {word:?}",
                entry.zip
            );
        }
        assert!(
            line.starts_with(|c: char| c.is_ascii_uppercase()) && line.ends_with('.'),
            "{}: {line:?} is not a sentence",
            entry.zip
        );
        *lines.entry(line).or_default() += 1;
    }
    let total: usize = lines.values().sum();
    assert!(
        total > 20_000,
        "the shipped bundle carries its summaries (read {total})"
    );
    for (line, count) in &lines {
        println!("{count:>6}  {line}");
    }
}
