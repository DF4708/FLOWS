// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The frozen classifier oracle: what the three Swift alert classifiers said
//! for 185 event names before they were replaced by `flows_core::alerts`.
//! Compared field by field; the deliberate changes are allow-listed with
//! their reasons, and each entry must still diverge or the test fails.

use flows_core::alerts::{self, Action, ShelterKind};

fn s(h: &str) -> String {
    let hex = h.strip_prefix("s:").expect("string field");
    let bytes: Vec<u8> = (0..hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).expect("hex"))
        .collect();
    String::from_utf8(bytes).expect("utf-8")
}

const SEVERITIES: [f64; 5] = [0.30, 0.45, 0.72, 0.88, 0.95];

fn shelter_name(k: ShelterKind) -> &'static str {
    match k {
        ShelterKind::InVehicle => "inVehicle",
        ShelterKind::AnyBuilding => "anyBuilding",
        ShelterKind::SturdyBuilding => "sturdyBuilding",
        ShelterKind::OfficialShelter => "officialShelter",
    }
}

fn action_name(a: Action) -> &'static str {
    match a {
        Action::Monitor => "monitor",
        Action::RestArea => "restArea",
        Action::Shelter => "shelter",
        Action::Lookout => "lookout",
    }
}

/// (event, field) pairs where Rust deliberately differs from the Swift tables.
const KNOWN_DIVERGENCES: &[(&str, &str, &str)] = &[
    ("Red Flag Warning", "ls", "fire weather is a predictor, not a reason to shelter (owner's rule: alerts specific to the threat, no spam)"),
    ("Red Flag Warning", "ac", "with life-safety removed, the action follows severity and expiry like any predictor"),
    ("Red Flag Warning", "an", "same, without an expiry"),
    ("Red Flag Warning (fire weather)", "ls", "same event with a suffix"),
    ("Red Flag Warning (fire weather)", "ac", "same"),
    ("Red Flag Warning (fire weather)", "an", "same"),
    ("Tornado Emergency", "ls", "the highest tornado product was missing from the life-safety list"),
    ("Tornado Emergency", "ac", "life-safety now: shelter at every severity"),
    ("Tornado Emergency", "an", "same, without an expiry"),
    ("Storm\u{301}", "af", "Swift matches grapheme clusters; Rust matches bytes (no feed emits a combining mark on an ASCII keyword)"),
];

#[test]
fn rust_reproduces_the_swift_alert_tables_except_where_it_means_to() {
    let text = include_str!("fixtures/swift_alerts_oracle.tsv");
    let mut unexpected: Vec<String> = Vec::new();
    let mut seen_known: Vec<(String, String)> = Vec::new();
    let mut checked = 0usize;
    for line in text
        .lines()
        .filter(|l| !l.starts_with('#') && !l.is_empty())
    {
        let f: Vec<&str> = line.split('\t').collect();
        assert_eq!(f[0], "ev");
        let event = s(f[1]);
        checked += 1;
        let mut report = |field: &str, got: String, want: String| {
            if got == want {
                return;
            }
            if KNOWN_DIVERGENCES
                .iter()
                .any(|(e, fl, _)| *e == event && *fl == field)
            {
                seen_known.push((event.clone(), field.to_string()));
            } else {
                unexpected.push(format!("{event:?} {field}: got {got} want {want}"));
            }
        };
        report(
            "af",
            alerts::display_kind(&event).name().to_string(),
            s(f[2]),
        );
        let sh: Vec<&str> = SEVERITIES
            .iter()
            .map(|v| shelter_name(alerts::shelter_kind(&event, *v)))
            .collect();
        report("sh", sh.join(","), f[3].to_string());
        report(
            "ls",
            if alerts::is_life_safety(&event) {
                "1"
            } else {
                "0"
            }
            .to_string(),
            f[4].to_string(),
        );
        report(
            "lo",
            if alerts::is_lookout(&event) { "1" } else { "0" }.to_string(),
            f[5].to_string(),
        );
        let ac: Vec<&str> = SEVERITIES
            .iter()
            .map(|v| action_name(alerts::action(&event, *v, Some(3600.0))))
            .collect();
        report("ac", ac.join(","), f[6].to_string());
        let an: Vec<&str> = SEVERITIES
            .iter()
            .map(|v| action_name(alerts::action(&event, *v, None)))
            .collect();
        report("an", an.join(","), f[7].to_string());
    }
    assert!(checked >= 180, "fixture truncated: {checked}");
    assert!(
        unexpected.is_empty(),
        "{} unexpected divergences:\n{}",
        unexpected.len(),
        unexpected.join("\n")
    );
    for (e, fl, _) in KNOWN_DIVERGENCES {
        assert!(
            seen_known.iter().any(|(se, sf)| se == e && sf == fl),
            "allow-listed divergence no longer diverges: {e:?} {fl}; remove its entry"
        );
    }
}
