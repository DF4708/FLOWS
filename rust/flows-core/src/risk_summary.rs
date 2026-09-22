// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The one line a ZIP's risk summary is read in, in plain words: "Storms are
//! common here in some seasons.", not "Seasonal baseline: elevated
//! convective risk (climatology)".
//!
//! No line says "this time of year": the text is written once, for the week
//! the bundle was built (the shipped one for July 4, 2026), and the app
//! rescores a ZIP's numbers for the current week but never its text, so a
//! line about the build week would be read, wrongly, all winter.
//!
//! The risk bundle's per-ZIP summary (`"t"`) is written by the trainers
//! (`flows-train`: `national-bundle` for the seasonal baseline,
//! `history-baseline` for the 20-year storm record) and shown as-is on the
//! route card's risk details and the map's tap card. The trainers write it
//! with [`seasonal`] and [`historical`]; a bundle written before them still
//! says it the old way (and `national-bundle` carries old entries through
//! unchanged), so `bundle-frb` writes every summary through [`plain`], which
//! rewrites the old lines and leaves any other text alone, and the app reads
//! every summary through it too, whatever bundle it loaded.
//!
//! | here | used by |
//! |---|---|
//! | [`seasonal`] | `national-bundle`, `history-baseline` (a season-won ZIP) |
//! | [`historical`] | `history-baseline` (a history-won ZIP) |
//! | [`plain`] | `bundle-frb`; `RiskSummaryText.plain` in `RiskFieldService.swift`, behind `summary(at:)` |
//!
//! Every sentence is plain JSON string content (no quote, backslash or
//! control character), so a trainer can splice it between quotes as is.

/// What the old seasonal line started with, before its family label.
const OLD_SEASONAL: &str = "seasonal baseline:";
/// What the old 20-year line started with, before its family label.
const OLD_HISTORICAL: &str = "historical baseline:";

/// What a family is called in a sentence, and whether it takes "are"/"have"
/// (plural) or "is"/"has". Keys are the bundle's family names; `flood` (the
/// R export's name, and the old lines' label for `qpf_flood`) and `storm`
/// read the same as their families. Each names what the bundle's score for
/// that family counts (history-baseline's `families_for`), which is not
/// always what the live feeds mean by it: the bundle's `air` is droughts and
/// dust storms, not smoke or air quality.
const WORDS: &[(&str, &str, bool)] = &[
    ("air", "Very dry weather", false),
    ("avalanche", "Avalanches", true),
    ("cold", "Very cold days", true),
    ("convective", "Storms", true),
    ("environmental", "Bad weather", false),
    ("fire", "Wildfires", true),
    ("flood", "Flooding", false),
    ("heat", "Very hot days", true),
    ("precip", "Heavy rains", true),
    ("qpf_flood", "Flooding", false),
    ("radiation", "Days with strong sun", true),
    ("seismic", "Earthquakes", true),
    ("storm", "Storms", true),
    ("tropical", "Hurricanes", true),
    ("tsunami", "Tsunamis", true),
    ("volcanic", "Volcano eruptions", true),
    ("wind", "Strong winds", true),
    ("winter", "Snow and ice storms", true),
];

/// What names a family no table row knows: never the raw key.
const UNKNOWN: (&str, bool) = ("Bad weather", false);

/// The sentence subject for `family` (case and surrounding space ignored),
/// and whether it is plural.
fn words(family: &str) -> (&'static str, bool) {
    let key = family.trim().to_ascii_lowercase();
    WORDS
        .iter()
        .find(|(k, _, _)| *k == key)
        .map_or(UNKNOWN, |&(_, subject, plural)| (subject, plural))
}

/// The seasonal baseline's line: "Storms are common here in some seasons."
///
/// Deterministic; allocates the sentence; panics: none.
#[must_use]
pub fn seasonal(family: &str) -> String {
    let (subject, plural) = words(family);
    let verb = if plural { "are" } else { "is" };
    format!("{subject} {verb} common here in some seasons.")
}

/// The 20-year storm record's line: "Flooding has been common here over the
/// last 20 years."
///
/// Deterministic; allocates the sentence; panics: none.
#[must_use]
pub fn historical(family: &str) -> String {
    let (subject, plural) = words(family);
    let verb = if plural { "have" } else { "has" };
    format!("{subject} {verb} been common here over the last 20 years.")
}

/// A bundle summary as a driver reads it. The old trainer lines
/// ("Seasonal baseline: elevated convective risk (climatology)", "Historical
/// baseline: elevated flood risk (20-yr storm climatology)") become
/// [`seasonal`] and [`historical`] lines for the family they name; an old
/// line whose family can't be read says "Bad weather". Any other text comes
/// back unchanged, so a summary already in plain words passes through, and
/// reading a line twice changes nothing.
///
/// Deterministic; allocates the answer; panics: none.
#[must_use]
pub fn plain(text: &str) -> String {
    let trimmed = text.trim_start();
    let lower = trimmed.to_ascii_lowercase();
    let (rest, is_historical) = if let Some(rest) = lower.strip_prefix(OLD_SEASONAL) {
        (rest, false)
    } else if let Some(rest) = lower.strip_prefix(OLD_HISTORICAL) {
        (rest, true)
    } else {
        return text.to_string();
    };
    let family = old_label(rest).unwrap_or("");
    if is_historical {
        historical(family)
    } else {
        seasonal(family)
    }
}

/// The family label in an old line's tail: the word(s) between "elevated"
/// and "risk" (" elevated convective risk (climatology)" → "convective").
fn old_label(tail: &str) -> Option<&str> {
    let after = tail.trim_start().strip_prefix("elevated")?;
    let end = after.find(" risk")?;
    let label = after[..end].trim();
    (!label.is_empty()).then_some(label)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The bundle's own families (national-bundle's FAMS) and the families
    /// the app's weight table knows.
    const FAMILIES: [&str; 17] = [
        "air",
        "avalanche",
        "cold",
        "convective",
        "environmental",
        "fire",
        "flood",
        "heat",
        "precip",
        "qpf_flood",
        "radiation",
        "seismic",
        "tropical",
        "tsunami",
        "volcanic",
        "wind",
        "winter",
    ];

    /// Words no driver should have to read.
    const JARGON: [&str; 11] = [
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
    ];

    #[test]
    fn the_table_is_sorted_and_names_every_family() {
        let keys: Vec<&str> = WORDS.iter().map(|(k, _, _)| *k).collect();
        let mut sorted = keys.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(keys, sorted, "WORDS stays sorted, one row per key");
        for family in FAMILIES {
            assert!(keys.contains(&family), "{family} has plain words");
        }
    }

    #[test]
    fn each_line_reads_as_a_plain_sentence() {
        assert_eq!(
            seasonal("convective"),
            "Storms are common here in some seasons."
        );
        assert_eq!(
            historical("qpf_flood"),
            "Flooding has been common here over the last 20 years."
        );
        assert_eq!(
            seasonal("environmental"),
            "Bad weather is common here in some seasons."
        );
        assert_eq!(
            historical("environmental"),
            "Bad weather has been common here over the last 20 years."
        );
    }

    #[test]
    fn no_sentence_carries_jargon_or_breaks_a_json_string() {
        for family in FAMILIES.iter().copied().chain(["storm", "", "mystery"]) {
            for line in [seasonal(family), historical(family)] {
                let lower = line.to_ascii_lowercase();
                for word in JARGON {
                    assert!(!lower.contains(word), "{line:?} says {word:?}");
                }
                assert!(
                    !line
                        .chars()
                        .any(|c| c == '"' || c == '\\' || c.is_control()),
                    "{line:?} would break the bundle's JSON"
                );
                assert!(line.ends_with('.'));
            }
        }
    }

    #[test]
    fn an_unknown_family_is_bad_weather_never_its_key() {
        assert_eq!(
            seasonal("mystery"),
            "Bad weather is common here in some seasons."
        );
        assert_eq!(seasonal(" Convective "), seasonal("convective"));
    }

    /// Every old line the shipped bundle carries (app_risk_bundle.frb1,
    /// built Aug 25 2026), and the forms the old trainers wrote.
    #[test]
    fn every_old_line_in_the_shipped_bundle_is_rewritten() {
        let cases = [
            (
                "Seasonal baseline: elevated convective risk (climatology)",
                "Storms are common here in some seasons.",
            ),
            (
                "Seasonal baseline: elevated heat risk (climatology)",
                "Very hot days are common here in some seasons.",
            ),
            (
                "Seasonal baseline: elevated flood risk (climatology)",
                "Flooding is common here in some seasons.",
            ),
            (
                "Seasonal baseline: elevated wind risk (climatology)",
                "Strong winds are common here in some seasons.",
            ),
            (
                "Historical baseline: elevated convective risk (20-yr storm climatology)",
                "Storms have been common here over the last 20 years.",
            ),
            (
                "Historical baseline: elevated flood risk (20-yr storm climatology)",
                "Flooding has been common here over the last 20 years.",
            ),
            (
                "Historical baseline: elevated heat risk (20-yr storm climatology)",
                "Very hot days have been common here over the last 20 years.",
            ),
            (
                "Historical baseline: elevated wind risk (20-yr storm climatology)",
                "Strong winds have been common here over the last 20 years.",
            ),
            (
                "Historical baseline: elevated fire risk (20-yr storm climatology)",
                "Wildfires have been common here over the last 20 years.",
            ),
            (
                "Historical baseline: elevated air risk (20-yr storm climatology)",
                "Very dry weather has been common here over the last 20 years.",
            ),
            (
                "Historical baseline: elevated winter risk (20-yr storm climatology)",
                "Snow and ice storms have been common here over the last 20 years.",
            ),
        ];
        for (old, new) in cases {
            assert_eq!(plain(old), new, "{old}");
        }
    }

    #[test]
    fn an_old_line_it_cannot_read_still_never_shows() {
        for old in [
            "Seasonal baseline: elevated risk (climatology)",
            "Seasonal baseline:",
            "Historical baseline: something else",
            "  seasonal BASELINE: Elevated Convective Risk (climatology)",
        ] {
            let line = plain(old);
            let lower = line.to_ascii_lowercase();
            assert!(
                !lower.contains("baseline") && !lower.contains("climatology"),
                "{old:?} → {line:?}"
            );
        }
        assert_eq!(
            plain("  seasonal BASELINE: Elevated Convective Risk (climatology)"),
            "Storms are common here in some seasons."
        );
    }

    #[test]
    fn other_text_passes_through_and_a_second_read_changes_nothing() {
        for text in [
            "windy",
            "",
            "Flooding is likely near the river.",
            "baseline",
        ] {
            assert_eq!(plain(text), text);
        }
        for family in FAMILIES {
            for line in [seasonal(family), historical(family)] {
                assert_eq!(plain(&line), line);
            }
        }
    }
}
