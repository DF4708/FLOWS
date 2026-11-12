// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The tourist stop card's rules: Swift's `TouristInfo` before its rules
//! moved here. Which entry-fee line a place gets, which plain-words kind it
//! is, and which of a Monday-first week of hours lines is today.
//!
//! Swift keeps the words and the name's clean-up: `TouristInfo.normalized`
//! folds diacritics with Foundation (a rule that depends on the base letter
//! before each mark, not one scalar at a time), lowercases, and turns long
//! dashes into hyphens. The rules here take that cleaned name and answer
//! with codes. Text follows Swift's own rules through [`crate::swift_text`]:
//! `contains` is Foundation's (an empty needle is never contained) and a
//! key's length is its count of Characters.
//!
//! One choice is new. When two fee-table keys of the same length are both
//! in a name, the original's `max` kept whichever the dictionary listed
//! first, which changes from run to run; here the key with the smaller
//! UTF-8 bytes wins. Pinned by
//! `flows-bridge/tests/fixtures/swift_tourist_info_oracle.tsv`.

use crate::swift_text;

/// Which "Cost to get in" line a place gets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fee {
    /// A national park in the fee table: the note of the key at this index.
    Table(usize),
    /// A national park the table does not name.
    ParkDefault,
    /// Another national site (monument, memorial, seashore, and so on).
    SiteDefault,
    /// Anything else: prices vary.
    Varies,
}

/// The national sites, other than parks, that get the "most are free" line.
pub const NATIONAL_SITES: [&str; 9] = [
    "national monument",
    "national memorial",
    "national historic",
    "national historical",
    "national seashore",
    "national lakeshore",
    "national recreation",
    "national battlefield",
    "national preserve",
];

/// `feeNote`'s choice for a cleaned name. A national park takes the longest
/// table key (in Characters) the name holds, so "glacier bay" beats
/// "glacier"; a tie goes to the smaller key by bytes.
#[must_use]
pub fn fee(normalized: &str, keys: &[&str]) -> Fee {
    if swift_text::contains(normalized, "national park") {
        let mut best: Option<(usize, usize)> = None;
        for (i, key) in keys.iter().enumerate() {
            if !swift_text::contains(normalized, key) {
                continue;
            }
            let len = swift_text::cluster_count(key);
            let better = match best {
                None => true,
                Some((best_len, best_i)) => {
                    len > best_len || (len == best_len && key.as_bytes() < keys[best_i].as_bytes())
                }
            };
            if better {
                best = Some((len, i));
            }
        }
        return best.map_or(Fee::ParkDefault, |(_, i)| Fee::Table(i));
    }
    if NATIONAL_SITES
        .iter()
        .any(|site| swift_text::contains(normalized, site))
    {
        Fee::SiteDefault
    } else {
        Fee::Varies
    }
}

/// The card header's plain-words kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Kind {
    NationalPark = 0,
    Museum = 1,
    ThemePark = 2,
    Zoo = 3,
    Aquarium = 4,
    Park = 5,
    Landmark = 6,
    StatePark = 7,
    Monument = 8,
    Cave = 9,
    Waterfall = 10,
    Beach = 11,
    Trail = 12,
    Garden = 13,
    WorthAStop = 14,
}

/// MapKit's point-of-interest raw values the card names directly.
const CATEGORIES: [(&str, Kind); 7] = [
    ("MKPOICategoryNationalPark", Kind::NationalPark),
    ("MKPOICategoryMuseum", Kind::Museum),
    ("MKPOICategoryAmusementPark", Kind::ThemePark),
    ("MKPOICategoryZoo", Kind::Zoo),
    ("MKPOICategoryAquarium", Kind::Aquarium),
    ("MKPOICategoryPark", Kind::Park),
    ("MKPOICategoryLandmark", Kind::Landmark),
];

/// Name words in the order they are tried; the first that the name holds
/// decides.
const WORDS: [(&str, Kind); 13] = [
    ("national park", Kind::NationalPark),
    ("state park", Kind::StatePark),
    ("museum", Kind::Museum),
    ("zoo", Kind::Zoo),
    ("aquarium", Kind::Aquarium),
    ("monument", Kind::Monument),
    ("memorial", Kind::Monument),
    ("cave", Kind::Cave),
    ("cavern", Kind::Cave),
    ("falls", Kind::Waterfall),
    ("beach", Kind::Beach),
    ("trail", Kind::Trail),
    ("garden", Kind::Garden),
];

/// `plainKind`: the MapKit category when it is one the card names (compared
/// as Swift compares strings), else the first word of [`WORDS`] the cleaned
/// name holds, else "park", else a place worth a stop.
#[must_use]
pub fn kind(normalized: &str, category: Option<&str>) -> Kind {
    if let Some(raw) = category {
        if let Some((_, k)) = CATEGORIES.iter().find(|(c, _)| swift_text::eq(raw, c)) {
            return *k;
        }
    }
    if let Some((_, k)) = WORDS
        .iter()
        .find(|(w, _)| swift_text::contains(normalized, w))
    {
        return *k;
    }
    if swift_text::contains(normalized, "park") {
        Kind::Park
    } else {
        Kind::WorthAStop
    }
}

/// `mondayFirstIndex`: Calendar's weekday (1 is Sunday) as an index into a
/// Monday-first week. Swift's `%` keeps the dividend's sign, as Rust's does;
/// the sum is taken wide so the five largest weekdays, where Swift's `+ 5`
/// would trap, answer instead.
#[must_use]
pub fn monday_first_index(weekday: i64) -> i64 {
    // In 0 ..= ±6, so the narrowing is exact.
    #[allow(clippy::cast_possible_truncation)]
    let index = ((i128::from(weekday) + 5) % 7) as i64;
    index
}
