// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift's `String` behaviour, in safe Rust with no dependencies, for the
//! text the ported brand, price and tag code handles (`places_text`).
//!
//! Six facts about Swift text decide every answer in that code. Each is
//! reproduced here from tables the frozen-oracle harness read out of the
//! Swift 6.4 runtime ([`tables`], checked scalar by scalar by
//! `flows-bridge/tests/swift_places_text_oracle.rs`):
//!
//! - A `Character` is an extended grapheme cluster (UAX #29 with the
//!   Indic-conjunct rule), so `count`, `prefix`, `split` and `filter` see
//!   clusters — [`graphemes`], [`cluster_count`], [`prefix_clusters`].
//! - `Character.isLetter` and `isNumber` read the cluster's first scalar —
//!   [`is_word_start`], [`is_number_start`].
//! - `lowercased()` and `uppercased()` map scalar by scalar with the full
//!   one-to-many mappings and no context: a final sigma stays σ, İ becomes
//!   i̇, ß becomes SS — [`lowercased`], [`uppercased`].
//! - `==` is canonical equivalence: `"café" == "cafe\u{301}"` and
//!   `"\u{212A}S" == "KS"` — [`eq`], through [`nfd`].
//! - Foundation's `range(of:)`, `contains`, `components(separatedBy:)` and
//!   `replacingOccurrences` match whole clusters canonically, so `"$\u{301}"`
//!   holds no `"$"` — [`find`], [`contains`], [`components`], [`replacing`];
//!   `hasSuffix` compares clusters — [`has_suffix`]; `trimmingCharacters(in:
//!   .whitespaces)` trims scalars — [`trim_whitespace`].
//! - `Double(String)` is Darwin's `strtod` behind Swift's own checks —
//!   [`swift_double`]; `Double(Substring)` differs only at an embedded NUL —
//!   [`swift_double_substring`].
//!
//! Nothing here reads a locale or holds state; every function is a pure
//! transform of its arguments, and none panics on any input.

mod number;
pub(crate) mod tables;

pub use number::{swift_double, swift_double_substring};

use tables::{
    CCC_RANGES, CCC_RANGES_STRIDE, GCB_RANGES, GCB_RANGES_STRIDE, LOWER_MAP, LOWER_MAP_STRIDE,
    NFD_MAP, NFD_MAP_STRIDE, NUMBER_RANGES, NUMBER_RANGES_STRIDE, UPPER_MAP, UPPER_MAP_STRIDE,
    WHITESPACE_RANGES, WHITESPACE_RANGES_STRIDE, WORD_RANGES, WORD_RANGES_STRIDE,
};

// ------------------------------------------------------------ table lookups

/// The entry of a table of `lo, hi, …` rows (sorted, disjoint) whose range
/// holds `v`, as a slice of the row; `None` when no range does.
fn range_entry(table: &[u32], stride: usize, v: u32) -> Option<&[u32]> {
    let rows = table.len() / stride;
    // The last row whose `lo` is at or below `v`.
    let mut lo = 0usize;
    let mut hi = rows;
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if table[mid * stride] <= v {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    let row = lo.checked_sub(1)?;
    let entry = &table[row * stride..(row + 1) * stride];
    (v <= entry[1]).then_some(entry)
}

/// The row of a table of `scalar, …` rows (sorted by scalar) for `v`.
fn map_entry(table: &[u32], stride: usize, v: u32) -> Option<&[u32]> {
    let rows = table.len() / stride;
    let mut lo = 0usize;
    let mut hi = rows;
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        let key = table[mid * stride];
        if key == v {
            return Some(&table[mid * stride..(mid + 1) * stride]);
        }
        if key < v {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    None
}

/// Push the non-zero scalars of a mapping row's tail.
fn push_mapping(out: &mut String, mapping: &[u32]) {
    for &v in mapping {
        if v != 0 {
            out.extend(char::from_u32(v));
        }
    }
}

// ------------------------------------------------------- Character classes

/// `Character.isLetter || isNumber` of the cluster that starts with `c`.
#[must_use]
pub fn is_word_scalar(c: char) -> bool {
    range_entry(WORD_RANGES, WORD_RANGES_STRIDE, c as u32).is_some()
}

/// `Character.isNumber` of the cluster that starts with `c`.
#[must_use]
pub fn is_number_scalar(c: char) -> bool {
    range_entry(NUMBER_RANGES, NUMBER_RANGES_STRIDE, c as u32).is_some()
}

/// `CharacterSet.whitespaces.contains(c)`.
#[must_use]
pub fn is_whitespace(c: char) -> bool {
    range_entry(WHITESPACE_RANGES, WHITESPACE_RANGES_STRIDE, c as u32).is_some()
}

/// `Character.isLetter || isNumber` for a cluster: its first scalar decides;
/// an empty cluster answers false.
#[must_use]
pub fn is_word_start(cluster: &str) -> bool {
    cluster.chars().next().is_some_and(is_word_scalar)
}

/// `Character.isNumber` for a cluster: its first scalar decides.
#[must_use]
pub fn is_number_start(cluster: &str) -> bool {
    cluster.chars().next().is_some_and(is_number_scalar)
}

/// The canonical combining class of a scalar (0 for a starter).
#[must_use]
pub fn combining_class(c: char) -> u32 {
    range_entry(CCC_RANGES, CCC_RANGES_STRIDE, c as u32).map_or(0, |row| row[2])
}

// ------------------------------------------------------- grapheme clusters

/// Grapheme_Cluster_Break classes as the harness's probes tell them apart
/// (the codes are those `gen_tables.py` writes).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Gcb {
    Other,
    Control,
    Cr,
    Lf,
    /// GCB=Extend that also carries Indic_Conjunct_Break=Extend.
    Extend,
    /// GCB=Extend without it (the zero-width non-joiner).
    ExtendPlain,
    SpacingMark,
    Prepend,
    ExtPict,
    Consonant,
    Linker,
    Zwj,
    Ri,
    L,
    V,
    T,
    Lv,
    Lvt,
}

impl Gcb {
    fn from_code(code: u32) -> Gcb {
        match code {
            1 => Gcb::Control,
            2 => Gcb::Cr,
            3 => Gcb::Lf,
            4 => Gcb::Extend,
            5 => Gcb::ExtendPlain,
            6 => Gcb::SpacingMark,
            7 => Gcb::Prepend,
            8 => Gcb::ExtPict,
            9 => Gcb::Consonant,
            10 => Gcb::Linker,
            11 => Gcb::Zwj,
            12 => Gcb::Ri,
            13 => Gcb::L,
            14 => Gcb::V,
            15 => Gcb::T,
            16 => Gcb::Lv,
            17 => Gcb::Lvt,
            _ => Gcb::Other,
        }
    }

    /// The code `gen_tables.py` writes for this class (0 for `Other`).
    fn code(self) -> u32 {
        match self {
            Gcb::Other => 0,
            Gcb::Control => 1,
            Gcb::Cr => 2,
            Gcb::Lf => 3,
            Gcb::Extend => 4,
            Gcb::ExtendPlain => 5,
            Gcb::SpacingMark => 6,
            Gcb::Prepend => 7,
            Gcb::ExtPict => 8,
            Gcb::Consonant => 9,
            Gcb::Linker => 10,
            Gcb::Zwj => 11,
            Gcb::Ri => 12,
            Gcb::L => 13,
            Gcb::V => 14,
            Gcb::T => 15,
            Gcb::Lv => 16,
            Gcb::Lvt => 17,
        }
    }

    /// GCB=Extend in the rules: both Extend classes and the linker.
    fn is_extend(self) -> bool {
        matches!(self, Gcb::Extend | Gcb::ExtendPlain | Gcb::Linker)
    }

    /// Indic_Conjunct_Break=Extend, the run allowed between a consonant, its
    /// linker and the next consonant.
    fn is_incb_extend(self) -> bool {
        matches!(self, Gcb::Extend | Gcb::Zwj)
    }

    fn is_control(self) -> bool {
        matches!(self, Gcb::Control | Gcb::Cr | Gcb::Lf)
    }
}

/// The grapheme-break class of a scalar.
fn gcb(c: char) -> Gcb {
    range_entry(GCB_RANGES, GCB_RANGES_STRIDE, c as u32)
        .map_or(Gcb::Other, |row| Gcb::from_code(row[2]))
}

/// The grapheme-break class of a scalar as the code `gen_tables.py` writes
/// (0 for `Other`), for the oracle test.
#[must_use]
pub fn grapheme_class_code(c: char) -> u32 {
    gcb(c).code()
}

/// What the rules remember about the scalars before a boundary decision.
#[derive(Default)]
struct BreakState {
    /// Consecutive regional indicators ending at the previous scalar.
    ri_run: usize,
    /// 1 inside `ExtPict Extend*`, 2 right after the ZWJ that follows it.
    pict: u8,
    /// Every scalar since the last consonant was an InCB extend or linker.
    consonant_run: bool,
    /// …and at least one of them was a linker.
    linker_seen: bool,
}

impl BreakState {
    fn push(&mut self, cur: Gcb) {
        self.ri_run = if cur == Gcb::Ri { self.ri_run + 1 } else { 0 };
        self.pict = match cur {
            Gcb::ExtPict => 1,
            c if c.is_extend() => u8::from(self.pict == 1),
            Gcb::Zwj => {
                if self.pict == 1 {
                    2
                } else {
                    0
                }
            }
            _ => 0,
        };
        match cur {
            Gcb::Consonant => {
                self.consonant_run = true;
                self.linker_seen = false;
            }
            Gcb::Linker => {
                if self.consonant_run {
                    self.linker_seen = true;
                }
            }
            c if c.is_incb_extend() => {}
            _ => {
                self.consonant_run = false;
                self.linker_seen = false;
            }
        }
    }

    /// Is there a cluster boundary between `prev` and `cur`, given the state
    /// after `prev`? UAX #29 rules GB3 to GB13 in order, then GB999.
    fn breaks(&self, prev: Gcb, cur: Gcb) -> bool {
        if prev == Gcb::Cr && cur == Gcb::Lf {
            return false;
        }
        if prev.is_control() || cur.is_control() {
            return true;
        }
        match (prev, cur) {
            (Gcb::L, Gcb::L | Gcb::V | Gcb::Lv | Gcb::Lvt)
            | (Gcb::Lv | Gcb::V, Gcb::V | Gcb::T)
            | (Gcb::Lvt | Gcb::T, Gcb::T) => return false,
            _ => {}
        }
        if cur.is_extend() || cur == Gcb::Zwj || cur == Gcb::SpacingMark {
            return false;
        }
        if prev == Gcb::Prepend {
            return false;
        }
        if cur == Gcb::Consonant && self.consonant_run && self.linker_seen {
            return false;
        }
        if prev == Gcb::Zwj && self.pict == 2 && cur == Gcb::ExtPict {
            return false;
        }
        if prev == Gcb::Ri && cur == Gcb::Ri && self.ri_run % 2 == 1 {
            return false;
        }
        true
    }
}

/// The byte offset where the cluster starting at `start` ends.
fn cluster_end(text: &str, start: usize) -> usize {
    let mut chars = text[start..].char_indices();
    let Some((_, first)) = chars.next() else {
        return start;
    };
    let mut prev = gcb(first);
    let mut state = BreakState::default();
    state.push(prev);
    for (i, c) in chars {
        let cur = gcb(c);
        if state.breaks(prev, cur) {
            return start + i;
        }
        state.push(cur);
        prev = cur;
    }
    text.len()
}

/// The `Character`s of a string, in order, as slices of it.
pub struct Graphemes<'a> {
    text: &'a str,
    pos: usize,
}

impl<'a> Iterator for Graphemes<'a> {
    type Item = &'a str;

    fn next(&mut self) -> Option<&'a str> {
        if self.pos >= self.text.len() {
            return None;
        }
        let end = cluster_end(self.text, self.pos);
        let item = &self.text[self.pos..end];
        self.pos = end;
        Some(item)
    }
}

/// Swift's `for character in string`: the extended grapheme clusters.
#[must_use]
pub fn graphemes(text: &str) -> Graphemes<'_> {
    Graphemes { text, pos: 0 }
}

/// Swift's `string.count`.
#[must_use]
pub fn cluster_count(text: &str) -> usize {
    graphemes(text).count()
}

/// Swift's `String(string.prefix(n))`: the first `n` clusters.
#[must_use]
pub fn prefix_clusters(text: &str, n: usize) -> &str {
    let mut end = 0;
    for (k, cluster) in graphemes(text).enumerate() {
        if k == n {
            break;
        }
        end += cluster.len();
    }
    &text[..end]
}

/// The byte offsets of every cluster boundary in `text`, first `0`, last
/// `text.len()` (just `[0]` for an empty string).
fn boundaries(text: &str) -> Vec<usize> {
    let mut out = vec![0];
    let mut pos = 0;
    for cluster in graphemes(text) {
        pos += cluster.len();
        out.push(pos);
    }
    out
}

// ------------------------------------------------------------------ casing

/// Swift's `lowercased()`: every scalar's full lowercase mapping, no context.
#[must_use]
pub fn lowercased(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match map_entry(LOWER_MAP, LOWER_MAP_STRIDE, c as u32) {
            Some(row) => push_mapping(&mut out, &row[1..]),
            None => out.push(c),
        }
    }
    out
}

/// Swift's `uppercased()`: every scalar's full uppercase mapping, no context.
#[must_use]
pub fn uppercased(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match map_entry(UPPER_MAP, UPPER_MAP_STRIDE, c as u32) {
            Some(row) => push_mapping(&mut out, &row[1..]),
            None => out.push(c),
        }
    }
    out
}

// ------------------------------------------------- canonical equivalence

const HANGUL_BASE: u32 = 0xAC00;
const HANGUL_LAST: u32 = 0xD7A3;
const JAMO_L_BASE: u32 = 0x1100;
const JAMO_V_BASE: u32 = 0x1161;
const JAMO_T_BASE: u32 = 0x11A7;
const JAMO_V_COUNT: u32 = 21;
const JAMO_T_COUNT: u32 = 28;

/// Append the full canonical decomposition of one scalar.
fn decompose(c: char, out: &mut Vec<char>) {
    let v = c as u32;
    if (HANGUL_BASE..=HANGUL_LAST).contains(&v) {
        let index = v - HANGUL_BASE;
        let l = JAMO_L_BASE + index / (JAMO_V_COUNT * JAMO_T_COUNT);
        let vowel = JAMO_V_BASE + (index % (JAMO_V_COUNT * JAMO_T_COUNT)) / JAMO_T_COUNT;
        let t = JAMO_T_BASE + index % JAMO_T_COUNT;
        out.extend(char::from_u32(l));
        out.extend(char::from_u32(vowel));
        if t != JAMO_T_BASE {
            out.extend(char::from_u32(t));
        }
        return;
    }
    match map_entry(NFD_MAP, NFD_MAP_STRIDE, v) {
        Some(row) => out.extend(
            row[1..]
                .iter()
                .filter(|&&d| d != 0)
                .filter_map(|&d| char::from_u32(d)),
        ),
        None => out.push(c),
    }
}

/// Swift's `String ==` seen as a normal form: the full canonical
/// decomposition with combining marks in canonical order (NFD).
#[must_use]
pub fn nfd(text: &str) -> Vec<char> {
    let mut out = Vec::with_capacity(text.len());
    for c in text.chars() {
        decompose(c, &mut out);
    }
    // Canonical ordering: each run of non-starters is stably sorted by class.
    let mut i = 0;
    while i < out.len() {
        if combining_class(out[i]) == 0 {
            i += 1;
            continue;
        }
        let start = i;
        while i < out.len() && combining_class(out[i]) != 0 {
            i += 1;
        }
        out[start..i].sort_by_key(|&c| combining_class(c));
    }
    out
}

/// Swift's `a == b` on strings: canonical equivalence.
#[must_use]
pub fn eq(a: &str, b: &str) -> bool {
    if a == b {
        return true;
    }
    if a.is_ascii() && b.is_ascii() {
        return false;
    }
    nfd(a) == nfd(b)
}

/// The ASCII spelling of a string when it is canonically equivalent to one
/// (`"\u{212A}S"` is `"KS"`); `None` otherwise. Dictionary lookups against
/// ASCII keys are exact on this.
#[must_use]
pub fn ascii_form(text: &str) -> Option<String> {
    if text.is_ascii() {
        return Some(text.to_string());
    }
    let d = nfd(text);
    d.iter()
        .all(char::is_ascii)
        .then(|| d.into_iter().collect())
}

// ------------------------------------------------------ Foundation search

/// Foundation's `range(of:)` inside `hay[from..to]` (byte offsets on cluster
/// boundaries of `hay`): the first run of whole clusters canonically equal to
/// `needle`, as its byte range. `None` for an empty needle, as Foundation
/// answers, for offsets that are not cluster boundaries, and when nothing
/// matches.
#[must_use]
pub fn find_in(hay: &str, needle: &str, from: usize, to: usize) -> Option<(usize, usize)> {
    if needle.is_empty() || from >= to || to > hay.len() {
        return None;
    }
    let all = boundaries(hay);
    let first = all.binary_search(&from).ok()?;
    let last = all.binary_search(&to).ok()?;
    let bounds = &all[first..=last];
    let target = nfd(needle);
    for (si, &s) in bounds.iter().enumerate().take(bounds.len() - 1) {
        for &e in &bounds[si + 1..] {
            let run = nfd(&hay[s..e]);
            if run.len() > target.len() || !target.starts_with(&run) {
                break;
            }
            if run.len() == target.len() {
                return Some((s, e));
            }
        }
    }
    None
}

/// Foundation's `range(of:)` over the whole string.
#[must_use]
pub fn find(hay: &str, needle: &str) -> Option<(usize, usize)> {
    find_in(hay, needle, 0, hay.len())
}

/// Foundation's `contains(_:)` for a string argument.
#[must_use]
pub fn contains(hay: &str, needle: &str) -> bool {
    find(hay, needle).is_some()
}

/// Foundation's `components(separatedBy:)`: the pieces between successive
/// matches, empty pieces included; a string with no match is one piece.
#[must_use]
pub fn components(text: &str, separator: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut pos = 0;
    while let Some((a, b)) = find_in(text, separator, pos, text.len()) {
        out.push(text[pos..a].to_string());
        pos = b;
    }
    out.push(text[pos..].to_string());
    out
}

/// Foundation's `replacingOccurrences(of:with:)`: every successive match
/// replaced.
#[must_use]
pub fn replacing(text: &str, target: &str, replacement: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut pos = 0;
    while let Some((a, b)) = find_in(text, target, pos, text.len()) {
        out.push_str(&text[pos..a]);
        out.push_str(replacement);
        pos = b;
    }
    out.push_str(&text[pos..]);
    out
}

/// Swift's `hasSuffix`: the last clusters compared one to one, canonically.
/// An empty suffix is always present.
#[must_use]
pub fn has_suffix(text: &str, suffix: &str) -> bool {
    let tail: Vec<&str> = graphemes(suffix).collect();
    if tail.is_empty() {
        return true;
    }
    let own: Vec<&str> = graphemes(text).collect();
    if own.len() < tail.len() {
        return false;
    }
    own[own.len() - tail.len()..]
        .iter()
        .zip(&tail)
        .all(|(a, b)| eq(a, b))
}

/// `trimmingCharacters(in: .whitespaces)`: scalars, from both ends.
#[must_use]
pub fn trim_whitespace(text: &str) -> &str {
    text.trim_matches(is_whitespace)
}

/// `CharacterSet.whitespacesAndNewlines.contains(c)`.
#[must_use]
pub fn is_whitespace_or_newline(c: char) -> bool {
    range_entry(
        tables::WHITESPACE_NEWLINE_RANGES,
        tables::WHITESPACE_NEWLINE_RANGES_STRIDE,
        c as u32,
    )
    .is_some()
}

/// `trimmingCharacters(in: .whitespacesAndNewlines)`: scalars, from both ends.
#[must_use]
pub fn trim_whitespace_newlines(text: &str) -> &str {
    text.trim_matches(is_whitespace_or_newline)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sizes(scalars: &[u32]) -> Vec<usize> {
        let s: String = scalars.iter().filter_map(|&v| char::from_u32(v)).collect();
        graphemes(&s).map(|g| g.chars().count()).collect()
    }

    #[test]
    fn clusters_follow_the_runtime_on_the_probed_shapes() {
        assert_eq!(sizes(&[0x65, 0x301]), vec![2]);
        assert_eq!(sizes(&[0xD, 0xA]), vec![2]);
        assert_eq!(sizes(&[0xA, 0xD]), vec![1, 1]);
        assert_eq!(sizes(&[0x1F600, 0x200D, 0x1F600]), vec![3]);
        assert_eq!(sizes(&[0x1F600, 0x200D, 0x200D, 0x1F600]), vec![3, 1]);
        assert_eq!(sizes(&[0x1F1FA, 0x1F1F8, 0x1F1E6]), vec![2, 1]);
        assert_eq!(sizes(&[0x1100, 0x1161, 0x11A8]), vec![3]);
        assert_eq!(sizes(&[0x915, 0x94D, 0x937]), vec![3]);
        assert_eq!(sizes(&[0x61, 0x94D, 0x915]), vec![2, 1]);
        assert_eq!(sizes(&[0x600, 0x24]), vec![2]);
        assert_eq!(sizes(&[0x24, 0x600]), vec![1, 1]);
        assert_eq!(sizes(&[0x0, 0x301]), vec![1, 1]);
        assert_eq!(sizes(&[0x24, 0xFE0F, 0x24]), vec![2, 1]);
        assert_eq!(cluster_count("\u{1F1FA}\u{1F1F8}"), 1);
        assert_eq!(cluster_count("\u{DF}x"), 2);
        assert_eq!(prefix_clusters("a\u{301}bcdefghij", 8), "a\u{301}bcdefgh");
    }

    #[test]
    fn casing_is_the_full_mapping_without_context() {
        assert_eq!(lowercased("\u{130}"), "i\u{307}");
        assert_eq!(
            lowercased("\u{39F}\u{394}\u{39F}\u{3A3}"),
            "\u{3BF}\u{3B4}\u{3BF}\u{3C3}"
        );
        assert_eq!(lowercased("\u{212A}"), "k");
        assert_eq!(uppercased("\u{DF}"), "SS");
        assert_eq!(uppercased("\u{FB01}"), "FI");
        assert_eq!(uppercased("\u{1C5}"), "\u{1C4}");
        assert_eq!(lowercased("\u{1C5}"), "\u{1C6}");
        assert_eq!(uppercased("\u{3C2}"), "\u{3A3}");
    }

    #[test]
    fn equality_is_canonical_equivalence() {
        assert!(eq("Caf\u{E9}", "Cafe\u{301}"));
        assert!(eq("\u{212A}S", "KS"));
        assert!(!eq("a\u{301}\u{308}", "a\u{308}\u{301}"));
        assert!(eq("a\u{316}\u{301}", "a\u{301}\u{316}"));
        assert!(!eq("\u{FF21}", "A"));
        assert!(eq("\u{AC01}", "\u{1100}\u{1161}\u{11A8}"));
        assert_eq!(ascii_form("\u{212A}ansas"), Some("Kansas".to_string()));
        assert_eq!(ascii_form("W\u{301}I"), None);
    }

    #[test]
    fn foundation_search_matches_whole_clusters_canonically() {
        assert_eq!(find("$\u{301}5", "$"), None);
        assert_eq!(find("\u{600}$3", "$"), None);
        assert_eq!(find("$\u{600}", "$"), Some((0, 1)));
        assert_eq!(find("$\u{FE0F}$", "$"), Some((4, 5)));
        assert_eq!(find("\u{AD}$3", "$"), Some((2, 3)));
        assert_eq!(find("Current Avg.\u{301} $2", "Current Avg."), None);
        assert_eq!(find("Current Avg.\u{AD} $2", "Current Avg."), Some((0, 12)));
        assert_eq!(find("caf\u{E9}", "cafe\u{301}"), Some((0, 5)));
        assert_eq!(find("cafe\u{301}", "caf\u{E9}"), Some((0, 6)));
        assert_eq!(find("aaa", "aa"), Some((0, 2)));
        assert_eq!(find("$\r\n", "$\r"), None);
        assert_eq!(find("abc", ""), None);
        assert_eq!(components("a||b", "|"), vec!["a", "", "b"]);
        assert_eq!(components("|", "|"), vec!["", ""]);
        assert_eq!(
            components("left|\u{301}right", "|"),
            vec!["left|\u{301}right"]
        );
        assert_eq!(components("a|\u{301}|b", "|"), vec!["a|\u{301}", "b"]);
        assert_eq!(components("", "|"), vec![""]);
        assert_eq!(replacing("45 m\u{301}ph", "mph", ""), "45 m\u{301}ph");
        assert_eq!(replacing("45 mph mph", "mph", ""), "45  ");
        assert_eq!(replacing("'\u{301}s", "'", ""), "'\u{301}s");
        assert!(has_suffix("x\u{200D}mph", "mph"));
        assert!(!has_suffix("\u{600}mph", "mph"));
        assert!(!has_suffix("45 mph\u{301}", "mph"));
        assert!(has_suffix("caf\u{E9}", "e\u{301}"));
        assert!(!has_suffix("x\u{1F1FA}\u{1F1F8}", "\u{1F1F8}"));
        assert!(has_suffix("", ""));
        assert!(!has_suffix("", "mph"));
        assert_eq!(trim_whitespace(" \u{301}WI"), "\u{301}WI");
        assert_eq!(trim_whitespace("\u{200B}WI\u{3000}"), "WI");
        assert_eq!(trim_whitespace("\u{85}WI"), "\u{85}WI");
    }

    #[test]
    fn character_classes_read_the_first_scalar() {
        assert!(is_word_start("e\u{301}"));
        assert!(!is_word_start("\u{301}"));
        assert!(is_number_start("1\u{FE0F}\u{20E3}"));
        assert!(is_word_start("\u{2160}") && is_number_start("\u{2160}"));
        assert!(is_number_start("\u{BD}"));
        assert!(is_word_start("\u{93E}"));
        assert!(!is_word_start("$"));
        assert!(!is_word_start(""));
    }
}
