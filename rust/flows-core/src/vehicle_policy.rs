// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Vehicle policy: the speed bar's legal lines, the posted-limit parser, the
//! towing ratings and their violations, the route filter limits, the grade
//! table, the pursuit reach circle and the drive-efficiency verdict.
//!
//! This is the port of the app's Swift, function by function:
//!
//! | here | Swift (commit a007de0) |
//! |---|---|
//! | [`estimated_limit_mph`], [`effective_limit_mph`], [`state_threshold_mph`], [`federal_threshold_mph`], [`standing`] | `SpeedLaw` |
//! | [`COMPASS_POINTS`], [`compass_point_index`] | `CompassReading.points` |
//! | [`parse_maxspeed_mph`], [`judge`] | `SpeedSign` |
//! | [`pursuit_radius_meters`] | `PursuitReach.radiusMeters` |
//! | [`estimated_ratings`], [`effective_gcwr_lbs`], [`towing_check`], [`TOWING_ECONOMY_FACTOR`] | `TowingLimits` |
//! | [`degrees_to_percent`], [`passes_clearances`], [`passes_grade`], [`passes_weight_limits`], [`vehicle_default_max_grade_degrees`] | `FilterLimits` |
//! | [`grade_segments`], [`steepest`], [`next_steep`] | `GradeProfile` |
//! | [`drag_penalty`] … [`verdict`], [`efficient_cruise_mph`] | `DriveEfficiency` |
//!
//! # Fidelity
//!
//! Every function reproduces the Swift it replaced bit for bit, NaN, signed
//! zero and infinities included, and the frozen oracle
//! `flows-bridge/tests/fixtures/swift_vehicle_policy_oracle.tsv` pins it.
//! Getting there takes:
//! - Swift's `min`/`max` from [`crate::fcmp`], argument order kept, never
//!   `f64::min`/`max`/`clamp`;
//! - `switch x { case ..<a: … }` read as `x < a`, so a NaN falls through to
//!   the `default` arm exactly as it does in Swift;
//! - a Swift optional as `Option<f64>`, never as NaN, wherever Swift tells a
//!   present NaN apart from nil;
//! - `tan`, `atan` and `cos` from the platform libm, which is what the Swift
//!   called on Apple platforms;
//! - Swift's own sort algorithm for [`steepest`], so a NaN grade (which makes
//!   the comparator inconsistent) orders exactly as it did;
//! - Swift's grapheme-cluster `String` semantics in [`parse_maxspeed_mph`],
//!   using Unicode property tables read from the Swift runtime.
//!
//! # Determinism, allocation, panics
//!
//! Every function is a pure transform of its arguments: no state, no I/O, no
//! clock, no locale. The grade functions and the parser allocate their
//! results; everything else is allocation-free. No function panics.

use crate::fcmp::{smax, smin};
use std::f64::consts::PI;

// =============================================================================
// SpeedLaw
// =============================================================================

/// Slack past the posted limit before the yellow line (mph): speedometers
/// read high and enforcement allows for it.
pub const STATE_TOLERANCE_MPH: f64 = 5.0;
/// Gross excess over the posted limit where the red line sits (mph).
pub const EXCESS_OVER_LIMIT_MPH: f64 = 20.0;
/// Absolute ceiling on the red line (mph): 20 over a fast road is already
/// past what any state treats as excessive.
pub const EXCESS_ABSOLUTE_MPH: f64 = 85.0;

/// The ordinary limit (mph) for the kind of road being driven, estimated from
/// travel speed when OSM has no posted limit: under 30 → 25, under 42 → 35,
/// under 52 → 45, under 62 → 55, otherwise (NaN included) 65.
///
/// Deterministic; panics: none.
#[must_use]
pub fn estimated_limit_mph(speed_mph: f64) -> f64 {
    if speed_mph < 30.0 {
        25.0
    } else if speed_mph < 42.0 {
        35.0
    } else if speed_mph < 52.0 {
        45.0
    } else if speed_mph < 62.0 {
        55.0
    } else {
        65.0
    }
}

/// A posted limit counts only when present and `> 0` (so NaN never counts).
fn posted(limit_mph: Option<f64>) -> Option<f64> {
    limit_mph.filter(|v| *v > 0.0)
}

/// The limit (mph) the speed bar draws its lines from: the posted limit when
/// present and `> 0`, otherwise [`estimated_limit_mph`] of the travel speed.
///
/// Deterministic; panics: none.
#[must_use]
pub fn effective_limit_mph(posted_limit_mph: Option<f64>, speed_mph: f64) -> f64 {
    match posted(posted_limit_mph) {
        Some(p) => p,
        None => estimated_limit_mph(speed_mph),
    }
}

/// The speed (mph) where the bar turns yellow: posted limit plus
/// [`STATE_TOLERANCE_MPH`]. `None` when nothing is posted (absent, `<= 0` or
/// NaN). A present answer is never NaN.
///
/// Deterministic; panics: none.
#[must_use]
pub fn state_threshold_mph(posted_limit_mph: Option<f64>) -> Option<f64> {
    posted(posted_limit_mph).map(|p| p + STATE_TOLERANCE_MPH)
}

/// The speed (mph) where the bar turns red: Swift `min(posted + 20, 85)`.
/// `None` when nothing is posted. A present answer is never NaN.
///
/// Deterministic; panics: none.
#[must_use]
pub fn federal_threshold_mph(posted_limit_mph: Option<f64>) -> Option<f64> {
    posted(posted_limit_mph).map(|p| smin(p + EXCESS_OVER_LIMIT_MPH, EXCESS_ABSOLUTE_MPH))
}

/// What the driver is doing, legally speaking.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Standing {
    /// Under the yellow line, or nothing posted.
    Legal,
    /// At or past the yellow line: a state traffic violation.
    StateViolation,
    /// At or past the red line: excessive speed.
    FederalViolation,
}

/// The driver's standing: federal when `speed >= red line`, else state when
/// `speed >= yellow line`, else legal. Nothing posted is always legal. The red
/// line is tested first, so where it sits below the yellow one (posted over
/// 80) a speed past it is federal.
///
/// Deterministic; panics: none.
#[must_use]
pub fn standing(speed_mph: f64, posted_limit_mph: Option<f64>) -> Standing {
    let (Some(federal), Some(state)) = (
        federal_threshold_mph(posted_limit_mph),
        state_threshold_mph(posted_limit_mph),
    ) else {
        return Standing::Legal;
    };
    if speed_mph >= federal {
        Standing::FederalViolation
    } else if speed_mph >= state {
        Standing::StateViolation
    } else {
        Standing::Legal
    }
}

/// The 16-point compass, clockwise from north. The NWS forecast reader turns
/// a wind word into degrees as `index * 22.5`.
pub const COMPASS_POINTS: [&str; 16] = [
    "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW",
    "NNW",
];

/// Position of `word` in [`COMPASS_POINTS`], matched exactly (the caller has
/// already trimmed and uppercased it), or `None`. The same answer as Swift's
/// `points.firstIndex(of:)`: no other string is canonically equivalent to
/// these ASCII words.
///
/// Deterministic; panics: none.
#[must_use]
pub fn compass_point_index(word: &str) -> Option<usize> {
    COMPASS_POINTS.iter().position(|p| *p == word)
}

// =============================================================================
// SpeedSign
// =============================================================================

/// Excess over the limit (mph) at which the readout reads slightly over.
pub const SPEED_SIGN_TOLERANCE_MPH: f64 = 5.0;
/// Excess over the limit (mph) at which the readout reads over.
pub const SPEED_SIGN_OVER_BY_MPH: f64 = 10.0;
/// What a `walk` posting means (mph).
pub const WALK_MPH: f64 = 5.0;
/// Kilometres per mile, dividing a bare OSM number (km/h by specification).
pub const KM_PER_MILE: f64 = 1.609344;
/// Miles per hour in one knot.
pub const MPH_PER_KNOT: f64 = 1.15078;

/// The speeding judgment for the readout's color.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Judgment {
    /// Less than 5 over, or no limit known.
    Under,
    /// At least 5 over.
    SlightlyOver,
    /// At least 10 over.
    Over,
}

/// Judge `speed − limit` against 10 then 5 mph. No limit (absent, `<= 0` or
/// NaN) is always [`Judgment::Under`]: missing data never accuses.
///
/// Deterministic; panics: none.
#[must_use]
pub fn judge(speed_mph: f64, limit_mph: Option<f64>) -> Judgment {
    let Some(limit) = posted(limit_mph) else {
        return Judgment::Under;
    };
    let excess = speed_mph - limit;
    if excess >= SPEED_SIGN_OVER_BY_MPH {
        Judgment::Over
    } else if excess >= SPEED_SIGN_TOLERANCE_MPH {
        Judgment::SlightlyOver
    } else {
        Judgment::Under
    }
}

/// The posted limit in mph from an OSM `maxspeed` value, or `None`.
///
/// The rule, as the Swift wrote it: lowercase; trim `CharacterSet.whitespaces`
/// from both ends; empty, `none`, `signals` and `variable` are `None`; `walk`
/// is 5; otherwise take the leading run of characters that are numbers or
/// `.`, parse it as a `Double`, and require it `> 0`. The value is mph when
/// the text contains `mph`, knots (× 1.15078) when it contains `knots`, and
/// otherwise km/h (÷ 1.609344).
///
/// Swift's `String` works on grapheme clusters, so this follows it exactly:
/// a combining mark on the last digit makes that digit a different character
/// (the parse fails), a combining mark on a trailing `.` ends the run before
/// it, `55½` fails because `½` is a number `Double` cannot read, and `mph`
/// only counts when it stands as three whole characters. The Unicode
/// properties involved are [`swift_is_number`], [`swift_joins_previous`],
/// [`swift_prepends_to_next`] and [`swift_is_whitespace`].
///
/// Deterministic; allocates the lowercased copy; panics: none. A present
/// answer is `> 0` (possibly `+inf`) and never NaN.
#[must_use]
pub fn parse_maxspeed_mph(raw: &str) -> Option<f64> {
    let lowered = raw.to_lowercase();
    let lower = lowered.trim_matches(swift_is_whitespace);
    if lower.is_empty() || lower == "none" || lower == "signals" || lower == "variable" {
        return None;
    }
    if lower == "walk" {
        return Some(WALK_MPH);
    }
    let value = numeric_prefix(lower)?
        .parse::<f64>()
        .ok()
        .filter(|v| *v > 0.0)?;
    if grapheme_contains(lower, "mph") {
        Some(value)
    } else if grapheme_contains(lower, "knots") {
        Some(value * MPH_PER_KNOT)
    } else {
        Some(value / KM_PER_MILE)
    }
}

/// The prefix Swift's `lower.prefix { $0.isNumber || $0 == "." }` yields, when
/// `Double(_:)` could accept it; `None` when that prefix is empty or would hold
/// a non-ASCII character (which `Double` rejects).
fn numeric_prefix(s: &str) -> Option<&str> {
    let k = s
        .bytes()
        .take_while(|b| b.is_ascii_digit() || *b == b'.')
        .count();
    let run = s.get(..k).filter(|r| !r.is_empty())?;
    let Some(next) = s.get(k..).and_then(|rest| rest.chars().next()) else {
        return Some(run);
    };
    if next.is_ascii() {
        // An ASCII character never joins the one before it.
        return Some(run);
    }
    if swift_joins_previous(next) {
        // `next` belongs to the run's last character. A digit so extended is
        // still a number, so the prefix keeps it and `Double` fails; a dot so
        // extended is no longer ".", so the prefix stops before it.
        return if run.ends_with('.') {
            run.get(..k - 1)
        } else {
            None
        };
    }
    if swift_is_number(next) {
        None
    } else {
        Some(run)
    }
}

/// Swift's `hay.contains(needle)` for an ASCII `needle`: an occurrence counts
/// only when it starts and ends on grapheme-cluster boundaries.
fn grapheme_contains(hay: &str, needle: &str) -> bool {
    let mut from = 0;
    while let Some(pos) = hay.get(from..).and_then(|h| h.find(needle)) {
        let start = from + pos;
        let end = start + needle.len();
        let starts_clean = hay
            .get(..start)
            .and_then(|h| h.chars().next_back())
            .is_none_or(|p| !swift_prepends_to_next(p));
        let ends_clean = hay
            .get(end..)
            .and_then(|h| h.chars().next())
            .is_none_or(|n| !swift_joins_previous(n));
        if starts_clean && ends_clean {
            return true;
        }
        // The needle starts with an ASCII byte, so this is a char boundary.
        from = start + 1;
    }
    false
}

/// True when `c` lies in one of the inclusive `[first, last]` pairs of `table`.
fn in_ranges(table: &[u32], c: char) -> bool {
    let v = u32::from(c);
    let (mut lo, mut hi) = (0usize, table.len() / 2);
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if table.get(2 * mid).is_some_and(|&first| first <= v) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    lo.checked_sub(1)
        .and_then(|i| table.get(2 * i + 1))
        .is_some_and(|&last| v <= last)
}

/// Swift's `Character.isNumber` for a character whose first scalar is `c`
/// (Unicode `Numeric_Type` is not `None`).
///
/// Deterministic; panics: none.
#[must_use]
pub fn swift_is_number(c: char) -> bool {
    in_ranges(SWIFT_NUMBER_RANGES, c)
}

/// True when `c` joins the character before it into one grapheme cluster
/// after an ASCII letter, digit or `.` (Grapheme_Cluster_Break Extend, ZWJ
/// or SpacingMark), as the Swift runtime segments.
///
/// Deterministic; panics: none.
#[must_use]
pub fn swift_joins_previous(c: char) -> bool {
    in_ranges(SWIFT_JOINS_PREVIOUS_RANGES, c)
}

/// True when `c` joins the character after it into one grapheme cluster
/// before an ASCII letter (Grapheme_Cluster_Break Prepend), as the Swift
/// runtime segments.
///
/// Deterministic; panics: none.
#[must_use]
pub fn swift_prepends_to_next(c: char) -> bool {
    in_ranges(SWIFT_PREPENDS_TO_NEXT_RANGES, c)
}

/// Membership in Foundation's `CharacterSet.whitespaces`, which
/// `trimmingCharacters(in:)` strips scalar by scalar.
///
/// Deterministic; panics: none.
#[must_use]
pub fn swift_is_whitespace(c: char) -> bool {
    in_ranges(SWIFT_WHITESPACE_RANGES, c)
}

// Inclusive [first, last] scalar ranges, flattened in pairs, read from the
// Swift runtime by the oracle harness (`utab` records) over every scalar and
// pinned by the oracle over the whole scalar domain. Regenerate them from
// the fixture, never by hand.

/// Scalars for which Swift's `Character.isNumber` is true.
pub const SWIFT_NUMBER_RANGES: &[u32] = &[
    0x30, 0x39, 0xB2, 0xB3, 0xB9, 0xB9, 0xBC, 0xBE, 0x660, 0x669, 0x6F0, 0x6F9, 0x7C0, 0x7C9,
    0x966, 0x96F, 0x9E6, 0x9EF, 0x9F4, 0x9F9, 0xA66, 0xA6F, 0xAE6, 0xAEF, 0xB66, 0xB6F, 0xB72,
    0xB77, 0xBE6, 0xBF2, 0xC66, 0xC6F, 0xC78, 0xC7E, 0xCE6, 0xCEF, 0xD58, 0xD5E, 0xD66, 0xD78,
    0xDE6, 0xDEF, 0xE50, 0xE59, 0xED0, 0xED9, 0xF20, 0xF33, 0x1040, 0x1049, 0x1090, 0x1099, 0x1369,
    0x137C, 0x16EE, 0x16F0, 0x17E0, 0x17E9, 0x17F0, 0x17F9, 0x1810, 0x1819, 0x1946, 0x194F, 0x19D0,
    0x19DA, 0x1A80, 0x1A89, 0x1A90, 0x1A99, 0x1B50, 0x1B59, 0x1BB0, 0x1BB9, 0x1C40, 0x1C49, 0x1C50,
    0x1C59, 0x2070, 0x2070, 0x2074, 0x2079, 0x2080, 0x2089, 0x2150, 0x2182, 0x2185, 0x2189, 0x2460,
    0x249B, 0x24EA, 0x24FF, 0x2776, 0x2793, 0x2CFD, 0x2CFD, 0x3007, 0x3007, 0x3021, 0x3029, 0x3038,
    0x303A, 0x3192, 0x3195, 0x3220, 0x3229, 0x3248, 0x324F, 0x3251, 0x325F, 0x3280, 0x3289, 0x32B1,
    0x32BF, 0x3405, 0x3405, 0x3483, 0x3483, 0x382A, 0x382A, 0x3B4D, 0x3B4D, 0x4E00, 0x4E00, 0x4E03,
    0x4E03, 0x4E07, 0x4E07, 0x4E09, 0x4E09, 0x4E24, 0x4E24, 0x4E5D, 0x4E5D, 0x4E8C, 0x4E8C, 0x4E94,
    0x4E94, 0x4E96, 0x4E96, 0x4EAC, 0x4EAC, 0x4EBF, 0x4EC0, 0x4EDF, 0x4EDF, 0x4EE8, 0x4EE8, 0x4F0D,
    0x4F0D, 0x4F70, 0x4F70, 0x4FE9, 0x4FE9, 0x5006, 0x5006, 0x5104, 0x5104, 0x5146, 0x5146, 0x5169,
    0x5169, 0x516B, 0x516B, 0x516D, 0x516D, 0x5341, 0x5341, 0x5343, 0x5345, 0x534C, 0x534C, 0x53C1,
    0x53C4, 0x56DB, 0x56DB, 0x58F1, 0x58F1, 0x58F9, 0x58F9, 0x5E7A, 0x5E7A, 0x5EFE, 0x5EFF, 0x5F0C,
    0x5F0E, 0x5F10, 0x5F10, 0x62D0, 0x62D0, 0x62FE, 0x62FE, 0x634C, 0x634C, 0x67D2, 0x67D2, 0x6D1E,
    0x6D1E, 0x6F06, 0x6F06, 0x7396, 0x7396, 0x767E, 0x767E, 0x7695, 0x7695, 0x79ED, 0x79ED, 0x8086,
    0x8086, 0x842C, 0x842C, 0x8CAE, 0x8CAE, 0x8CB3, 0x8CB3, 0x8D30, 0x8D30, 0x920E, 0x920E, 0x94A9,
    0x94A9, 0x9621, 0x9621, 0x9646, 0x9646, 0x964C, 0x964C, 0x9678, 0x9678, 0x96F6, 0x96F6, 0xA620,
    0xA629, 0xA6E6, 0xA6EF, 0xA830, 0xA835, 0xA8D0, 0xA8D9, 0xA900, 0xA909, 0xA9D0, 0xA9D9, 0xA9F0,
    0xA9F9, 0xAA50, 0xAA59, 0xABF0, 0xABF9, 0xF96B, 0xF96B, 0xF973, 0xF973, 0xF978, 0xF978, 0xF9B2,
    0xF9B2, 0xF9D1, 0xF9D1, 0xF9D3, 0xF9D3, 0xF9FD, 0xF9FD, 0xFF10, 0xFF19, 0x10107, 0x10133,
    0x10140, 0x10178, 0x1018A, 0x1018B, 0x102E1, 0x102FB, 0x10320, 0x10323, 0x10341, 0x10341,
    0x1034A, 0x1034A, 0x103D1, 0x103D5, 0x104A0, 0x104A9, 0x10858, 0x1085F, 0x10879, 0x1087F,
    0x108A7, 0x108AF, 0x108FB, 0x108FF, 0x10916, 0x1091B, 0x109BC, 0x109BD, 0x109C0, 0x109CF,
    0x109D2, 0x109FF, 0x10A40, 0x10A48, 0x10A7D, 0x10A7E, 0x10A9D, 0x10A9F, 0x10AEB, 0x10AEF,
    0x10B58, 0x10B5F, 0x10B78, 0x10B7F, 0x10BA9, 0x10BAF, 0x10CFA, 0x10CFF, 0x10D30, 0x10D39,
    0x10D40, 0x10D49, 0x10E60, 0x10E7E, 0x10F1D, 0x10F26, 0x10F51, 0x10F54, 0x10FC5, 0x10FCB,
    0x11052, 0x1106F, 0x110F0, 0x110F9, 0x11136, 0x1113F, 0x111D0, 0x111D9, 0x111E1, 0x111F4,
    0x112F0, 0x112F9, 0x11450, 0x11459, 0x114D0, 0x114D9, 0x11650, 0x11659, 0x116C0, 0x116C9,
    0x116D0, 0x116E3, 0x11730, 0x1173B, 0x118E0, 0x118F2, 0x11950, 0x11959, 0x11BF0, 0x11BF9,
    0x11C50, 0x11C6C, 0x11D50, 0x11D59, 0x11DA0, 0x11DA9, 0x11DE0, 0x11DE9, 0x11F50, 0x11F59,
    0x11FC0, 0x11FD4, 0x12038, 0x12039, 0x12079, 0x12079, 0x12226, 0x12226, 0x1222B, 0x1222B,
    0x1230B, 0x1230B, 0x1230D, 0x1230D, 0x12399, 0x12399, 0x12400, 0x1246E, 0x16130, 0x16139,
    0x16A60, 0x16A69, 0x16AC0, 0x16AC9, 0x16B50, 0x16B59, 0x16B5B, 0x16B61, 0x16D70, 0x16D79,
    0x16E80, 0x16E96, 0x16FF4, 0x16FF6, 0x1CCF0, 0x1CCF9, 0x1D2C0, 0x1D2D3, 0x1D2E0, 0x1D2F3,
    0x1D360, 0x1D378, 0x1D7CE, 0x1D7FF, 0x1E140, 0x1E149, 0x1E2F0, 0x1E2F9, 0x1E4F0, 0x1E4F9,
    0x1E5F1, 0x1E5FA, 0x1E8C7, 0x1E8CF, 0x1E950, 0x1E959, 0x1EC71, 0x1ECAB, 0x1ECAD, 0x1ECAF,
    0x1ECB1, 0x1ECB4, 0x1ED01, 0x1ED2D, 0x1ED2F, 0x1ED3D, 0x1F100, 0x1F10C, 0x1FBF0, 0x1FBF9,
    0x20001, 0x20001, 0x20064, 0x20064, 0x200E2, 0x200E2, 0x20121, 0x20121, 0x2092A, 0x2092A,
    0x20983, 0x20983, 0x2098C, 0x2098C, 0x2099C, 0x2099C, 0x20AEA, 0x20AEA, 0x20AFD, 0x20AFD,
    0x20B19, 0x20B19, 0x22390, 0x22390, 0x22998, 0x22998, 0x23B1B, 0x23B1B, 0x2626D, 0x2626D,
    0x2F890, 0x2F890,
];

/// Scalars that join the preceding ASCII letter, digit or `.` into one
/// grapheme cluster (the same set after `5`, `.`, `h` and `s`).
pub const SWIFT_JOINS_PREVIOUS_RANGES: &[u32] = &[
    0x300, 0x36F, 0x483, 0x489, 0x591, 0x5BD, 0x5BF, 0x5BF, 0x5C1, 0x5C2, 0x5C4, 0x5C5, 0x5C7,
    0x5C7, 0x610, 0x61A, 0x64B, 0x65F, 0x670, 0x670, 0x6D6, 0x6DC, 0x6DF, 0x6E4, 0x6E7, 0x6E8,
    0x6EA, 0x6ED, 0x711, 0x711, 0x730, 0x74A, 0x7A6, 0x7B0, 0x7EB, 0x7F3, 0x7FD, 0x7FD, 0x816,
    0x819, 0x81B, 0x823, 0x825, 0x827, 0x829, 0x82D, 0x859, 0x85B, 0x897, 0x89F, 0x8CA, 0x8E1,
    0x8E3, 0x903, 0x93A, 0x93C, 0x93E, 0x94F, 0x951, 0x957, 0x962, 0x963, 0x981, 0x983, 0x9BC,
    0x9BC, 0x9BE, 0x9C4, 0x9C7, 0x9C8, 0x9CB, 0x9CD, 0x9D7, 0x9D7, 0x9E2, 0x9E3, 0x9FE, 0x9FE,
    0xA01, 0xA03, 0xA3C, 0xA3C, 0xA3E, 0xA42, 0xA47, 0xA48, 0xA4B, 0xA4D, 0xA51, 0xA51, 0xA70,
    0xA71, 0xA75, 0xA75, 0xA81, 0xA83, 0xABC, 0xABC, 0xABE, 0xAC5, 0xAC7, 0xAC9, 0xACB, 0xACD,
    0xAE2, 0xAE3, 0xAFA, 0xAFF, 0xB01, 0xB03, 0xB3C, 0xB3C, 0xB3E, 0xB44, 0xB47, 0xB48, 0xB4B,
    0xB4D, 0xB55, 0xB57, 0xB62, 0xB63, 0xB82, 0xB82, 0xBBE, 0xBC2, 0xBC6, 0xBC8, 0xBCA, 0xBCD,
    0xBD7, 0xBD7, 0xC00, 0xC04, 0xC3C, 0xC3C, 0xC3E, 0xC44, 0xC46, 0xC48, 0xC4A, 0xC4D, 0xC55,
    0xC56, 0xC62, 0xC63, 0xC81, 0xC83, 0xCBC, 0xCBC, 0xCBE, 0xCC4, 0xCC6, 0xCC8, 0xCCA, 0xCCD,
    0xCD5, 0xCD6, 0xCE2, 0xCE3, 0xCF3, 0xCF3, 0xD00, 0xD03, 0xD3B, 0xD3C, 0xD3E, 0xD44, 0xD46,
    0xD48, 0xD4A, 0xD4D, 0xD57, 0xD57, 0xD62, 0xD63, 0xD81, 0xD83, 0xDCA, 0xDCA, 0xDCF, 0xDD4,
    0xDD6, 0xDD6, 0xDD8, 0xDDF, 0xDF2, 0xDF3, 0xE31, 0xE31, 0xE33, 0xE3A, 0xE47, 0xE4E, 0xEB1,
    0xEB1, 0xEB3, 0xEBC, 0xEC8, 0xECE, 0xF18, 0xF19, 0xF35, 0xF35, 0xF37, 0xF37, 0xF39, 0xF39,
    0xF3E, 0xF3F, 0xF71, 0xF84, 0xF86, 0xF87, 0xF8D, 0xF97, 0xF99, 0xFBC, 0xFC6, 0xFC6, 0x102D,
    0x1037, 0x1039, 0x103E, 0x1056, 0x1059, 0x105E, 0x1060, 0x1071, 0x1074, 0x1082, 0x1082, 0x1084,
    0x1086, 0x108D, 0x108D, 0x109D, 0x109D, 0x135D, 0x135F, 0x1712, 0x1715, 0x1732, 0x1734, 0x1752,
    0x1753, 0x1772, 0x1773, 0x17B4, 0x17D3, 0x17DD, 0x17DD, 0x180B, 0x180D, 0x180F, 0x180F, 0x1885,
    0x1886, 0x18A9, 0x18A9, 0x1920, 0x192B, 0x1930, 0x193B, 0x1A17, 0x1A1B, 0x1A55, 0x1A5E, 0x1A60,
    0x1A60, 0x1A62, 0x1A62, 0x1A65, 0x1A7C, 0x1A7F, 0x1A7F, 0x1AB0, 0x1ADD, 0x1AE0, 0x1AEB, 0x1B00,
    0x1B04, 0x1B34, 0x1B44, 0x1B6B, 0x1B73, 0x1B80, 0x1B82, 0x1BA1, 0x1BAD, 0x1BE6, 0x1BF3, 0x1C24,
    0x1C37, 0x1CD0, 0x1CD2, 0x1CD4, 0x1CE8, 0x1CED, 0x1CED, 0x1CF4, 0x1CF4, 0x1CF7, 0x1CF9, 0x1DC0,
    0x1DFF, 0x200C, 0x200D, 0x20D0, 0x20F0, 0x2CEF, 0x2CF1, 0x2D7F, 0x2D7F, 0x2DE0, 0x2DFF, 0x302A,
    0x302F, 0x3099, 0x309A, 0xA66F, 0xA672, 0xA674, 0xA67D, 0xA69E, 0xA69F, 0xA6F0, 0xA6F1, 0xA802,
    0xA802, 0xA806, 0xA806, 0xA80B, 0xA80B, 0xA823, 0xA827, 0xA82C, 0xA82C, 0xA880, 0xA881, 0xA8B4,
    0xA8C5, 0xA8E0, 0xA8F1, 0xA8FF, 0xA8FF, 0xA926, 0xA92D, 0xA947, 0xA953, 0xA980, 0xA983, 0xA9B3,
    0xA9C0, 0xA9E5, 0xA9E5, 0xAA29, 0xAA36, 0xAA43, 0xAA43, 0xAA4C, 0xAA4D, 0xAA7C, 0xAA7C, 0xAAB0,
    0xAAB0, 0xAAB2, 0xAAB4, 0xAAB7, 0xAAB8, 0xAABE, 0xAABF, 0xAAC1, 0xAAC1, 0xAAEB, 0xAAEF, 0xAAF5,
    0xAAF6, 0xABE3, 0xABEA, 0xABEC, 0xABED, 0xFB1E, 0xFB1E, 0xFE00, 0xFE0F, 0xFE20, 0xFE2F, 0xFF9E,
    0xFF9F, 0x101FD, 0x101FD, 0x102E0, 0x102E0, 0x10376, 0x1037A, 0x10A01, 0x10A03, 0x10A05,
    0x10A06, 0x10A0C, 0x10A0F, 0x10A38, 0x10A3A, 0x10A3F, 0x10A3F, 0x10AE5, 0x10AE6, 0x10D24,
    0x10D27, 0x10D69, 0x10D6D, 0x10EAB, 0x10EAC, 0x10EFA, 0x10EFF, 0x10F46, 0x10F50, 0x10F82,
    0x10F85, 0x11000, 0x11002, 0x11038, 0x11046, 0x11070, 0x11070, 0x11073, 0x11074, 0x1107F,
    0x11082, 0x110B0, 0x110BA, 0x110C2, 0x110C2, 0x11100, 0x11102, 0x11127, 0x11134, 0x11145,
    0x11146, 0x11173, 0x11173, 0x11180, 0x11182, 0x111B3, 0x111C0, 0x111C9, 0x111CC, 0x111CE,
    0x111CF, 0x1122C, 0x11237, 0x1123E, 0x1123E, 0x11241, 0x11241, 0x112DF, 0x112EA, 0x11300,
    0x11303, 0x1133B, 0x1133C, 0x1133E, 0x11344, 0x11347, 0x11348, 0x1134B, 0x1134D, 0x11357,
    0x11357, 0x11362, 0x11363, 0x11366, 0x1136C, 0x11370, 0x11374, 0x113B8, 0x113C0, 0x113C2,
    0x113C2, 0x113C5, 0x113C5, 0x113C7, 0x113CA, 0x113CC, 0x113D0, 0x113D2, 0x113D2, 0x113E1,
    0x113E2, 0x11435, 0x11446, 0x1145E, 0x1145E, 0x114B0, 0x114C3, 0x115AF, 0x115B5, 0x115B8,
    0x115C0, 0x115DC, 0x115DD, 0x11630, 0x11640, 0x116AB, 0x116B7, 0x1171D, 0x1171F, 0x11722,
    0x1172B, 0x1182C, 0x1183A, 0x11930, 0x11935, 0x11937, 0x11938, 0x1193B, 0x1193E, 0x11940,
    0x11940, 0x11942, 0x11943, 0x119D1, 0x119D7, 0x119DA, 0x119E0, 0x119E4, 0x119E4, 0x11A01,
    0x11A0A, 0x11A33, 0x11A39, 0x11A3B, 0x11A3E, 0x11A47, 0x11A47, 0x11A51, 0x11A5B, 0x11A8A,
    0x11A99, 0x11B60, 0x11B67, 0x11C2F, 0x11C36, 0x11C38, 0x11C3F, 0x11C92, 0x11CA7, 0x11CA9,
    0x11CB6, 0x11D31, 0x11D36, 0x11D3A, 0x11D3A, 0x11D3C, 0x11D3D, 0x11D3F, 0x11D45, 0x11D47,
    0x11D47, 0x11D8A, 0x11D8E, 0x11D90, 0x11D91, 0x11D93, 0x11D97, 0x11EF3, 0x11EF6, 0x11F00,
    0x11F01, 0x11F03, 0x11F03, 0x11F34, 0x11F3A, 0x11F3E, 0x11F42, 0x11F5A, 0x11F5A, 0x13440,
    0x13440, 0x13447, 0x13455, 0x1611E, 0x1612F, 0x16AF0, 0x16AF4, 0x16B30, 0x16B36, 0x16F4F,
    0x16F4F, 0x16F51, 0x16F87, 0x16F8F, 0x16F92, 0x16FE4, 0x16FE4, 0x16FF0, 0x16FF1, 0x1BC9D,
    0x1BC9E, 0x1CF00, 0x1CF2D, 0x1CF30, 0x1CF46, 0x1D165, 0x1D169, 0x1D16D, 0x1D172, 0x1D17B,
    0x1D182, 0x1D185, 0x1D18B, 0x1D1AA, 0x1D1AD, 0x1D242, 0x1D244, 0x1DA00, 0x1DA36, 0x1DA3B,
    0x1DA6C, 0x1DA75, 0x1DA75, 0x1DA84, 0x1DA84, 0x1DA9B, 0x1DA9F, 0x1DAA1, 0x1DAAF, 0x1E000,
    0x1E006, 0x1E008, 0x1E018, 0x1E01B, 0x1E021, 0x1E023, 0x1E024, 0x1E026, 0x1E02A, 0x1E08F,
    0x1E08F, 0x1E130, 0x1E136, 0x1E2AE, 0x1E2AE, 0x1E2EC, 0x1E2EF, 0x1E4EC, 0x1E4EF, 0x1E5EE,
    0x1E5EF, 0x1E6E3, 0x1E6E3, 0x1E6E6, 0x1E6E6, 0x1E6EE, 0x1E6EF, 0x1E6F5, 0x1E6F5, 0x1E8D0,
    0x1E8D6, 0x1E944, 0x1E94A, 0x1F3FB, 0x1F3FF, 0xE0020, 0xE007F, 0xE0100, 0xE01EF,
];

/// Scalars that join the following ASCII letter into one grapheme cluster
/// (the same set before `m` and `k`).
pub const SWIFT_PREPENDS_TO_NEXT_RANGES: &[u32] = &[
    0x600, 0x605, 0x6DD, 0x6DD, 0x70F, 0x70F, 0x890, 0x891, 0x8E2, 0x8E2, 0xD4E, 0xD4E, 0x110BD,
    0x110BD, 0x110CD, 0x110CD, 0x111C2, 0x111C3, 0x113D1, 0x113D1, 0x1193F, 0x1193F, 0x11941,
    0x11941, 0x11A84, 0x11A89, 0x11D46, 0x11D46, 0x11F02, 0x11F02,
];

/// Scalars in Foundation's `CharacterSet.whitespaces`.
pub const SWIFT_WHITESPACE_RANGES: &[u32] = &[
    0x9, 0x9, 0x20, 0x20, 0xA0, 0xA0, 0x1680, 0x1680, 0x2000, 0x200B, 0x202F, 0x202F, 0x205F,
    0x205F, 0x3000, 0x3000,
];

// =============================================================================
// PursuitReach
// =============================================================================

/// Blended escape speed (mph) when no posted limits are found nearby.
pub const PURSUIT_DEFAULT_SPEED_MPH: f64 = 45.0;
/// The smallest reach circle (m): even "just happened" draws one.
pub const PURSUIT_MINIMUM_RADIUS_METERS: f64 = 800.0;
/// Elapsed time is capped here (s, 3 h): past it the circle stops informing.
pub const PURSUIT_MAXIMUM_ELAPSED_SECONDS: f64 = 3.0 * 3600.0;
/// Metres per second in one mile per hour.
pub const MPS_PER_MPH: f64 = 0.44704;
/// The slowest escape speed the circle assumes (mph).
pub const PURSUIT_MINIMUM_SPEED_MPH: f64 = 5.0;

/// How far (m) a fleeing vehicle or moving hazard could have travelled since
/// onset: elapsed seconds clamped to `[0, 3 h]`, times `max(speed, 5)` mph in
/// m/s, never under 800 m. Swift `min`/`max` semantics, so a NaN elapsed time
/// propagates through the clamp and the floor keeps the product.
///
/// Deterministic; panics: none.
#[must_use]
pub fn pursuit_radius_meters(elapsed_seconds: f64, speed_mph: f64) -> f64 {
    let elapsed = smin(smax(elapsed_seconds, 0.0), PURSUIT_MAXIMUM_ELAPSED_SECONDS);
    let mps = smax(speed_mph, PURSUIT_MINIMUM_SPEED_MPH) * MPS_PER_MPH;
    // `mps * elapsed`, not `elapsed * mps`: the operand order the app's Release build
    // emits, so when both are NaN the speed's NaN propagates, as on the device.
    smax(mps * elapsed, PURSUIT_MINIMUM_RADIUS_METERS)
}

// =============================================================================
// TowingLimits
// =============================================================================

/// The fuel-economy multiplier while towing.
pub const TOWING_ECONOMY_FACTOR: f64 = 0.75;
/// Extra GVWR (lb) an electric vehicle's pack adds to its class estimate.
pub const EV_GVWR_EXTRA_LBS: f64 = 1_200.0;

/// A vehicle's manufacturer ratings, in pounds; `None` when unknown.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TowingRatings {
    /// Max allowable weight of the vehicle itself.
    pub gvwr_lbs: Option<f64>,
    /// Max weight the vehicle is rated to pull.
    pub tow_capacity_lbs: Option<f64>,
    /// Max weight of the whole rig.
    pub gcwr_lbs: Option<f64>,
}

/// The fuel a vehicle runs on, as the towing estimate distinguishes it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FuelKind {
    /// Gasoline.
    Gas,
    /// Diesel.
    Diesel,
    /// Battery electric.
    Electric,
}

/// Class-typical ratings from vehicle height (ft), for vehicles with no
/// published figures: under 5 → 4,300 / 1,000 / no GCWR; under 6 → 6,000 /
/// 3,500 / 11,000; under 7 → 7,100 / 9,000 / 15,500; under 10 → 9,500 /
/// 5,000 / 15,000; otherwise (NaN included) 26,000 / 10,000 / 36,000. An
/// electric vehicle adds [`EV_GVWR_EXTRA_LBS`] to the GVWR. Always an
/// estimate; the caller labels it so.
///
/// Deterministic; panics: none.
#[must_use]
pub fn estimated_ratings(height_feet: f64, fuel: FuelKind) -> TowingRatings {
    let (gvwr, tow, gcwr) = if height_feet < 5.0 {
        (4_300.0, 1_000.0, None)
    } else if height_feet < 6.0 {
        (6_000.0, 3_500.0, Some(11_000.0))
    } else if height_feet < 7.0 {
        (7_100.0, 9_000.0, Some(15_500.0))
    } else if height_feet < 10.0 {
        (9_500.0, 5_000.0, Some(15_000.0))
    } else {
        (26_000.0, 10_000.0, Some(36_000.0))
    };
    let gvwr = if fuel == FuelKind::Electric {
        gvwr + EV_GVWR_EXTRA_LBS
    } else {
        gvwr
    };
    TowingRatings {
        gvwr_lbs: Some(gvwr),
        tow_capacity_lbs: Some(tow),
        gcwr_lbs: gcwr,
    }
}

/// The GCWR (lb) the check uses: the published one, else GVWR + tow capacity
/// when both are known, else `None`. A present answer can be NaN (a NaN or
/// opposite-infinity sum), which is why this is an `Option`.
///
/// Deterministic; panics: none.
#[must_use]
pub fn effective_gcwr_lbs(ratings: &TowingRatings) -> Option<f64> {
    ratings
        .gcwr_lbs
        .or(match (ratings.gvwr_lbs, ratings.tow_capacity_lbs) {
            (Some(g), Some(t)) => Some(g + t),
            _ => None,
        })
}

/// One exceeded rating and by how much (lb). Never NaN.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum TowingViolation {
    /// The loaded vehicle is over its GVWR.
    OverGvwr(f64),
    /// The trailer is over the tow capacity.
    OverTowCapacity(f64),
    /// Vehicle plus trailer is over the effective GCWR.
    OverGcwr(f64),
}

/// Which ratings the rig exceeds, in the fixed order GVWR, tow capacity,
/// GCWR. A rating counts only when known and strictly exceeded; unknown
/// ratings never fabricate a violation. The combined weight is
/// `(vehicle + towed)`, then minus the GCWR.
///
/// Deterministic; allocates at most three entries; panics: none.
#[must_use]
pub fn towing_check(
    vehicle_weight_lbs: f64,
    towed_weight_lbs: f64,
    ratings: &TowingRatings,
) -> Vec<TowingViolation> {
    let mut out = Vec::new();
    if let Some(gvwr) = ratings.gvwr_lbs {
        if vehicle_weight_lbs > gvwr {
            out.push(TowingViolation::OverGvwr(vehicle_weight_lbs - gvwr));
        }
    }
    if let Some(cap) = ratings.tow_capacity_lbs {
        if towed_weight_lbs > cap {
            out.push(TowingViolation::OverTowCapacity(towed_weight_lbs - cap));
        }
    }
    if let Some(gcwr) = effective_gcwr_lbs(ratings) {
        if vehicle_weight_lbs + towed_weight_lbs > gcwr {
            out.push(TowingViolation::OverGcwr(
                vehicle_weight_lbs + towed_weight_lbs - gcwr,
            ));
        }
    }
    out
}

// =============================================================================
// FilterLimits
// =============================================================================

/// The filter's default vehicle height (m): 13 ft 6 in.
pub const DEFAULT_VEHICLE_HEIGHT_METERS: f64 = 4.115;
/// The filter's default grade limit (percent).
pub const DEFAULT_MAX_GRADE_PERCENT: f64 = 6.0;
/// Breathing room a posted clearance must leave over the vehicle (m): 2 ft.
pub const DEFAULT_CLEARANCE_MARGIN_METERS: f64 = 0.6096;
/// Tolerance on the clearance and weight comparisons.
pub const LIMIT_TOLERANCE: f64 = 1e-9;

/// Grade percent from the slider's degrees: `tan(degrees · π / 180) · 100`.
///
/// Deterministic (platform libm `tan`); panics: none.
#[must_use]
pub fn degrees_to_percent(degrees: f64) -> f64 {
    (degrees * PI / 180.0).tan() * 100.0
}

/// True when every posted clearance (m) is passable: fails when any clearance
/// is `<= (height + margin) + 1e-9`. No data (`None`) and no postings (empty)
/// both pass.
///
/// Deterministic; panics: none.
#[must_use]
pub fn passes_clearances(
    vehicle_height_meters: f64,
    clearance_margin_meters: f64,
    clearances_meters: Option<&[f64]>,
) -> bool {
    let Some(clearances) = clearances_meters else {
        return true;
    };
    let minimum_passable = vehicle_height_meters + clearance_margin_meters;
    !clearances
        .iter()
        .any(|c| *c <= minimum_passable + LIMIT_TOLERANCE)
}

/// True when the route's steepest grade (percent, `None` counts as 0) is
/// strictly under the limit.
///
/// Deterministic; panics: none.
#[must_use]
pub fn passes_grade(max_grade_percent: f64, route_max_grade_percent: Option<f64>) -> bool {
    route_max_grade_percent.unwrap_or(0.0) < max_grade_percent
}

/// True when every posted weight limit (lb) carries the rig: fails when any
/// limit is `< rig − 1e-9`, so the limit itself passes. No data, no postings,
/// no rig weight and a rig weight that is not `> 0` (NaN included) all pass.
///
/// Deterministic; panics: none.
#[must_use]
pub fn passes_weight_limits(rig_weight_lbs: Option<f64>, limits_lbs: Option<&[f64]>) -> bool {
    let (Some(limits), Some(rig)) = (limits_lbs, rig_weight_lbs.filter(|r| *r > 0.0)) else {
        return true;
    };
    !limits.iter().any(|l| *l < rig - LIMIT_TOLERANCE)
}

/// The grade slider's default (degrees) for a vehicle.
///
/// 1. Start from the maker's published guidance (percent) when present, else
///    the GVWR ladder (under 6,000 → 18, under 10,000 → 15, under 14,000 →
///    12, under 26,000 → 9, otherwise 6), else the height ladder (under 5.5 ft
///    → 18, under 7 → 15, under 9.5 → 12, otherwise 9). A present NaN takes
///    its ladder's last arm, as in Swift.
/// 2. When towing or the trailer weighs `> 0`: cap at 10; with a known tow
///    capacity `> 0` the trailer is heavy at `>= 60 %` of it and caps at 6 when
///    `>= 100 %`; without one it is heavy at `>= 5,000` lb; heavy caps at 8.
/// 3. `atan(percent / 100) · 180 / π`, clamped to `[2, 15]` with Swift
///    `min`/`max`, rounded to the 0.5° step (half away from zero).
///
/// Deterministic (platform libm `atan`); panics: none.
#[must_use]
pub fn vehicle_default_max_grade_degrees(
    published_max_grade_percent: Option<f64>,
    gvwr_lbs: Option<f64>,
    tow_capacity_lbs: Option<f64>,
    height_feet: f64,
    towing: bool,
    trailer_weight_lbs: f64,
) -> f64 {
    let mut percent = if let Some(published) = published_max_grade_percent {
        published
    } else if let Some(gvwr) = gvwr_lbs {
        if gvwr < 6_000.0 {
            18.0
        } else if gvwr < 10_000.0 {
            15.0
        } else if gvwr < 14_000.0 {
            12.0
        } else if gvwr < 26_000.0 {
            9.0
        } else {
            6.0
        }
    } else if height_feet < 5.5 {
        18.0
    } else if height_feet < 7.0 {
        15.0
    } else if height_feet < 9.5 {
        12.0
    } else {
        9.0
    };
    if towing || trailer_weight_lbs > 0.0 {
        percent = smin(percent, 10.0);
        let heavy_trailer = if let Some(cap) = tow_capacity_lbs.filter(|c| *c > 0.0) {
            if trailer_weight_lbs >= cap {
                percent = smin(percent, 6.0);
            }
            trailer_weight_lbs >= cap * 0.6
        } else {
            trailer_weight_lbs >= 5_000.0
        };
        if heavy_trailer {
            percent = smin(percent, 8.0);
        }
    }
    let degrees = (percent / 100.0).atan() * 180.0 / PI;
    let clamped = smin(smax(degrees, 2.0), 15.0);
    (clamped * 2.0).round() / 2.0
}

// =============================================================================
// GradeProfile
// =============================================================================

/// Metres in one mile.
pub const MILE_METERS: f64 = 1609.344;
/// Default magnitude (percent) at which a segment counts as steep ahead.
pub const STEEP_THRESHOLD_PERCENT: f64 = 6.0;
/// Default lookahead (miles) for the next steep segment.
pub const STEEP_LOOKAHEAD_MILES: f64 = 8.0;

/// One row of the route's grade table.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GradeSegment {
    /// Where the segment starts along the route (miles).
    pub start_mile: f64,
    /// Where it ends (miles).
    pub end_mile: f64,
    /// Signed grade (percent, positive climbs in travel direction).
    pub grade_percent: f64,
}

/// The grade table from an elevation profile sampled every `spacing_meters`
/// from `start_mile`. Segment `i − 1 → i` exists when both samples are
/// present: it spans `start + (i − 1) · s` to `start + i · s` miles, with
/// `s = spacing / 1609.344` computed once, and grade `(b − a) / spacing ·
/// 100`. A missing sample breaks the chain. Empty unless `spacing > 0` and
/// there are at least two samples.
///
/// Deterministic; allocates the table; panics: none.
#[must_use]
pub fn grade_segments(
    elevations: &[Option<f64>],
    spacing_meters: f64,
    start_mile: f64,
) -> Vec<GradeSegment> {
    let usable = spacing_meters > 0.0 && elevations.len() > 1;
    if !usable {
        return Vec::new();
    }
    let mile_spacing = spacing_meters / MILE_METERS;
    let mut out = Vec::new();
    for (i, pair) in elevations.windows(2).enumerate() {
        // `i` is Swift's `i - 1`.
        if let [Some(a), Some(b)] = pair {
            out.push(GradeSegment {
                start_mile: start_mile + i as f64 * mile_spacing,
                end_mile: start_mile + (i + 1) as f64 * mile_spacing,
                grade_percent: (b - a) / spacing_meters * 100.0,
            });
        }
    }
    out
}

/// The `top` steepest segments by `|grade|`, steepest first, ties in input
/// order. Sorted with Swift's own algorithm ([`swift_sorted_by`]), so a NaN
/// grade lands where Swift put it. A negative `top`, where Swift traps, is
/// the empty table.
///
/// Deterministic; allocates; panics: none.
#[must_use]
pub fn steepest(segments: &[GradeSegment], top: i64) -> Vec<GradeSegment> {
    let Ok(top) = usize::try_from(top) else {
        return Vec::new();
    };
    let mut sorted = swift_sorted_by(segments, |a, b| {
        a.grade_percent.abs() > b.grade_percent.abs()
    });
    sorted.truncate(top);
    sorted
}

/// Index of the next steep segment ahead of `mile`: among segments with
/// `end > mile`, `start < mile + lookahead` and `|grade| >= threshold`, the
/// earliest start, the steeper on equal starts, the first in input order on a
/// full tie (Swift `filter` then `min(by:)`). `None` when none qualifies.
///
/// Deterministic; panics: none.
#[must_use]
pub fn next_steep(
    mile: f64,
    segments: &[GradeSegment],
    threshold_percent: f64,
    lookahead_miles: f64,
) -> Option<usize> {
    let earlier = |a: &GradeSegment, b: &GradeSegment| {
        if a.start_mile != b.start_mile {
            a.start_mile < b.start_mile
        } else {
            a.grade_percent.abs() > b.grade_percent.abs()
        }
    };
    let mut best: Option<usize> = None;
    for (i, s) in segments.iter().enumerate() {
        let ahead = s.end_mile > mile
            && s.start_mile < mile + lookahead_miles
            && s.grade_percent.abs() >= threshold_percent;
        if !ahead {
            continue;
        }
        best = match best.and_then(|b| segments.get(b).map(|r| (b, r))) {
            Some((b, r)) if !earlier(s, r) => Some(b),
            _ => Some(i),
        };
    }
    best
}

/// Swift's `Array.sorted(by:)`, step for step: the stdlib's run-detecting
/// merge sort (`_stableSortImpl`). For a consistent comparator it is the
/// stable sort; for an inconsistent one (a NaN key) it gives the order Swift
/// gives, which no other stable sort is obliged to.
fn swift_sorted_by<T: Copy>(items: &[T], mut less: impl FnMut(&T, &T) -> bool) -> Vec<T> {
    let mut v = items.to_vec();
    let count = v.len();
    let min_run = minimum_merge_run_length(count);
    if count <= min_run {
        if count > 0 {
            insertion_sort(&mut v, 0, count, 1, &mut less);
        }
        return v;
    }
    let mut buffer: Vec<T> = Vec::with_capacity(count);
    let mut runs: Vec<(usize, usize)> = Vec::new();
    let mut start = 0;
    while start < count {
        let (mut end, descending) = find_next_run(&v, start, &mut less);
        if descending {
            v[start..end].reverse();
        }
        if end < count && end - start < min_run {
            let new_end = count.min(start + min_run);
            insertion_sort(&mut v, start, new_end, end, &mut less);
            end = new_end;
        }
        runs.push((start, end));
        merge_top_runs(&mut v, &mut runs, &mut buffer, &mut less);
        start = end;
    }
    while runs.len() > 1 {
        let at = runs.len() - 2;
        merge_runs(&mut v, &mut runs, at, &mut buffer, &mut less);
    }
    v
}

/// Swift's `_minimumMergeRunLength` on a 64-bit `Int`.
fn minimum_merge_run_length(count: usize) -> usize {
    const BITS_TO_USE: u32 = 6;
    if count < (1 << BITS_TO_USE) {
        return count;
    }
    let c = count as u64;
    let offset = (64 - BITS_TO_USE) - c.leading_zeros();
    let mask = (1u64 << offset) - 1;
    let run = (c >> offset) + u64::from(c & mask != 0);
    usize::try_from(run).unwrap_or(count)
}

/// Swift's `_insertionSort(within: lo..<hi, sortedEnd:)`.
fn insertion_sort<T: Copy>(
    v: &mut [T],
    lo: usize,
    hi: usize,
    sorted_end: usize,
    less: &mut impl FnMut(&T, &T) -> bool,
) {
    let mut sorted_end = sorted_end;
    while sorted_end != hi {
        let mut i = sorted_end;
        loop {
            let j = i - 1;
            if !less(&v[i], &v[j]) {
                break;
            }
            v.swap(i, j);
            i = j;
            if i == lo {
                break;
            }
        }
        sorted_end += 1;
    }
}

/// Swift's `_findNextRun`: the end of the run starting at `start`, and whether
/// it is strictly descending.
fn find_next_run<T>(v: &[T], start: usize, less: &mut impl FnMut(&T, &T) -> bool) -> (usize, bool) {
    let mut previous = start;
    let mut current = start + 1;
    if current >= v.len() {
        return (current, false);
    }
    let descending = less(&v[current], &v[previous]);
    loop {
        previous = current;
        current += 1;
        if !(current < v.len() && descending == less(&v[current], &v[previous])) {
            break;
        }
    }
    (current, descending)
}

/// Swift's `_mergeTopRuns`: merge until the run-length invariants hold.
fn merge_top_runs<T: Copy>(
    v: &mut [T],
    runs: &mut Vec<(usize, usize)>,
    buffer: &mut Vec<T>,
    less: &mut impl FnMut(&T, &T) -> bool,
) {
    let len = |r: (usize, usize)| r.1 - r.0;
    while runs.len() > 1 {
        let mut last = runs.len() - 1;
        let broken = (last >= 3
            && len(runs[last - 3]) <= len(runs[last - 2]) + len(runs[last - 1]))
            || (last >= 2 && len(runs[last - 2]) <= len(runs[last - 1]) + len(runs[last]))
            || len(runs[last - 1]) <= len(runs[last]);
        if !broken {
            break;
        }
        if last >= 2 && len(runs[last - 2]) < len(runs[last]) {
            last -= 1;
        }
        merge_runs(v, runs, last - 1, buffer, less);
    }
}

/// Swift's `_mergeRuns`: merge `runs[at]` with `runs[at + 1]`.
fn merge_runs<T: Copy>(
    v: &mut [T],
    runs: &mut Vec<(usize, usize)>,
    at: usize,
    buffer: &mut Vec<T>,
    less: &mut impl FnMut(&T, &T) -> bool,
) {
    let (low, middle) = runs[at];
    let high = runs[at + 1].1;
    merge(v, low, middle, high, buffer, less);
    runs[at] = (low, high);
    runs.remove(at + 1);
}

/// Swift's `_merge`: the shorter side goes to the buffer; forward merge when
/// the low side is strictly shorter, backward otherwise; equal keys keep the
/// low side first.
fn merge<T: Copy>(
    v: &mut [T],
    low: usize,
    mid: usize,
    high: usize,
    buffer: &mut Vec<T>,
    less: &mut impl FnMut(&T, &T) -> bool,
) {
    buffer.clear();
    if mid - low < high - mid {
        buffer.extend_from_slice(&v[low..mid]);
        let (mut dest, mut buf, mut src) = (low, 0, mid);
        while buf < buffer.len() && src < high {
            if less(&v[src], &buffer[buf]) {
                v[dest] = v[src];
                src += 1;
            } else {
                v[dest] = buffer[buf];
                buf += 1;
            }
            dest += 1;
        }
        for x in &buffer[buf..] {
            v[dest] = *x;
            dest += 1;
        }
    } else {
        buffer.extend_from_slice(&v[mid..high]);
        let (mut buf_high, mut dest_high, mut src_high, mut dest_low) =
            (buffer.len(), high, mid, mid);
        while buf_high > 0 && src_high > low {
            dest_high -= 1;
            if less(&buffer[buf_high - 1], &v[src_high - 1]) {
                src_high -= 1;
                v[dest_high] = v[src_high];
                dest_low -= 1;
            } else {
                buf_high -= 1;
                v[dest_high] = buffer[buf_high];
            }
        }
        for (k, x) in buffer[..buf_high].iter().enumerate() {
            v[dest_low + k] = *x;
        }
    }
}

// =============================================================================
// DriveEfficiency
// =============================================================================

/// Below this speed (mph), with no real acceleration, the vehicle is idling.
pub const IDLE_SPEED_MPH: f64 = 2.0;
/// Acceleration (mph/s) at or under which a stopped vehicle counts as idling.
pub const IDLE_ACCEL_MPH_PER_SEC: f64 = 0.1;
/// Where economy peaks before drag takes over (mph), when nothing better is known.
pub const DEFAULT_EFFICIENT_CRUISE_MPH: f64 = 55.0;
/// Scores at or under this are efficient.
pub const EFFICIENT_SCORE_MAX: f64 = 0.25;
/// Scores at or under this (and over [`EFFICIENT_SCORE_MAX`]) are fair.
pub const FAIR_SCORE_MAX: f64 = 0.75;

/// Everything the efficiency score reads. `None` fields take their documented
/// averages.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DriveInputs {
    /// Current speed (mph).
    pub speed_mph: f64,
    /// Smoothed acceleration (mph/s).
    pub accel_mph_per_sec: f64,
    /// Road grade underfoot (percent).
    pub grade_percent: f64,
    /// Wind speed (mph).
    pub wind_mph: f64,
    /// Direction the wind blows from (degrees).
    pub wind_from_degrees: Option<f64>,
    /// Direction of travel (degrees).
    pub heading_degrees: Option<f64>,
    /// Where the vehicle's economy peaks (mph).
    pub efficient_cruise_mph: f64,
    /// City economy (miles per unit).
    pub city_mpu: Option<f64>,
    /// Highway economy (miles per unit).
    pub highway_mpu: Option<f64>,
    /// Laden weight (lb).
    pub loaded_weight_lbs: Option<f64>,
    /// The vehicle's own weight (lb).
    pub vehicle_weight_lbs: Option<f64>,
    /// Towing, or crawling in a low gear.
    pub towing: bool,
    /// Fraction of the tank remaining.
    pub fuel_fraction: Option<f64>,
}

/// The leading icon's three states.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DriveVerdict {
    /// Smooth, in the sweet spot.
    Efficient,
    /// Steady but not thrifty.
    Fair,
    /// Heavy throttle, high drag, a hill, or idling.
    Wasteful,
}

/// Drag penalty past the efficient cruise: `over = (speed − cruise) / cruise`,
/// then `over · over · 2`; 0 unless `speed > cruise`.
///
/// Deterministic; panics: none.
#[must_use]
pub fn drag_penalty(speed_mph: f64, efficient_cruise_mph: f64) -> f64 {
    if speed_mph > efficient_cruise_mph {
        let over = (speed_mph - efficient_cruise_mph) / efficient_cruise_mph;
        over * over * 2.0
    } else {
        0.0
    }
}

/// Climbing costs `grade / 6`; a descent credits `max(grade / 12, −0.4)`.
///
/// Deterministic; panics: none.
#[must_use]
pub fn grade_penalty(grade_percent: f64) -> f64 {
    if grade_percent >= 0.0 {
        grade_percent / 6.0
    } else {
        smax(grade_percent / 12.0, -0.4)
    }
}

/// Acceleration costs `accel / 2.5`; coasting credits `max(accel / 8, −0.3)`.
///
/// Deterministic; panics: none.
#[must_use]
pub fn throttle_penalty(accel_mph_per_sec: f64) -> f64 {
    if accel_mph_per_sec > 0.0 {
        accel_mph_per_sec / 2.5
    } else {
        smax(accel_mph_per_sec / 8.0, -0.3)
    }
}

/// The headwind component along the direction of travel (mph):
/// `wind · cos((from − heading) · π / 180)`; 0 unless the wind is `> 0`,
/// both directions are known and the heading is `>= 0`.
///
/// Deterministic (platform libm `cos`); panics: none.
#[must_use]
pub fn headwind_mph(
    wind_mph: f64,
    wind_from_degrees: Option<f64>,
    heading_degrees: Option<f64>,
) -> f64 {
    match (wind_from_degrees, heading_degrees) {
        (Some(from), Some(heading)) if wind_mph > 0.0 && heading >= 0.0 => {
            wind_mph * ((from - heading) * PI / 180.0).cos()
        }
        _ => 0.0,
    }
}

/// The air the vehicle is pushing (mph): `max(speed + headwind, 0)`.
///
/// Deterministic; panics: none.
#[must_use]
pub fn airspeed_mph(i: &DriveInputs) -> f64 {
    smax(
        i.speed_mph + headwind_mph(i.wind_mph, i.wind_from_degrees, i.heading_degrees),
        0.0,
    )
}

/// Drag sensitivity from the city→highway gain: `min(max(1.35 / max(gain,
/// 0.6), 0.7), 1.8)` with `gain = highway / city`; 1 unless both are known
/// and `city > 0`.
///
/// Deterministic; panics: none.
#[must_use]
pub fn drag_sensitivity(city_mpu: Option<f64>, highway_mpu: Option<f64>) -> f64 {
    match (city_mpu, highway_mpu) {
        (Some(city), Some(highway)) if city > 0.0 => {
            let gain = highway / city;
            smin(smax(1.35 / smax(gain, 0.6), 0.7), 1.8)
        }
        _ => 1.0,
    }
}

/// Mass factor: 1, or `min(max(loaded / vehicle, 1), 2.5)` when both weights
/// are known and the vehicle's is `> 0`; plus `0.04 · min(max(fuel, 0), 1)`
/// when the fuel fraction is known; plus 0.35 when towing.
///
/// Deterministic; panics: none.
#[must_use]
pub fn load_factor(i: &DriveInputs) -> f64 {
    let mut ratio = 1.0;
    if let (Some(loaded), Some(base)) = (i.loaded_weight_lbs, i.vehicle_weight_lbs) {
        if base > 0.0 {
            ratio = smin(smax(loaded / base, 1.0), 2.5);
        }
    }
    if let Some(fuel) = i.fuel_fraction {
        ratio += 0.04 * smin(smax(fuel, 0.0), 1.0);
    }
    if i.towing {
        ratio += 0.35;
    }
    ratio
}

/// The blended score, 0 ideal: `(throttle · load + drag · sensitivity) +
/// grade · load`, where drag keys off [`airspeed_mph`].
///
/// Deterministic; panics: none.
#[must_use]
pub fn score(i: &DriveInputs) -> f64 {
    let load = load_factor(i);
    let throttle = throttle_penalty(i.accel_mph_per_sec) * load;
    let grade = grade_penalty(i.grade_percent) * load;
    let drag = drag_penalty(airspeed_mph(i), i.efficient_cruise_mph)
        * drag_sensitivity(i.city_mpu, i.highway_mpu);
    throttle + drag + grade
}

/// The icon: wasteful when idling (`speed < 2` and `accel <= 0.1`), else
/// efficient at `score <= 0.25`, fair at `<= 0.75`, wasteful otherwise (a NaN
/// score included).
///
/// Deterministic; panics: none.
#[must_use]
pub fn verdict(i: &DriveInputs) -> DriveVerdict {
    if i.speed_mph < IDLE_SPEED_MPH && i.accel_mph_per_sec <= IDLE_ACCEL_MPH_PER_SEC {
        return DriveVerdict::Wasteful;
    }
    let s = score(i);
    if s <= EFFICIENT_SCORE_MAX {
        DriveVerdict::Efficient
    } else if s <= FAIR_SCORE_MAX {
        DriveVerdict::Fair
    } else {
        DriveVerdict::Wasteful
    }
}

/// The efficient cruise speed (mph) for a vehicle. The Swift checks whether
/// highway economy beats city economy and then returns 55 on both paths, so
/// this is [`DEFAULT_EFFICIENT_CRUISE_MPH`] for every input.
///
/// Deterministic; panics: none.
#[must_use]
pub fn efficient_cruise_mph(city_mpu: Option<f64>, highway_mpu: Option<f64>) -> f64 {
    let _ = (city_mpu, highway_mpu);
    DEFAULT_EFFICIENT_CRUISE_MPH
}

#[cfg(test)]
mod tests {
    use super::*;

    fn inputs(speed: f64, accel: f64, grade: f64) -> DriveInputs {
        DriveInputs {
            speed_mph: speed,
            accel_mph_per_sec: accel,
            grade_percent: grade,
            wind_mph: 0.0,
            wind_from_degrees: None,
            heading_degrees: None,
            efficient_cruise_mph: DEFAULT_EFFICIENT_CRUISE_MPH,
            city_mpu: None,
            highway_mpu: None,
            loaded_weight_lbs: None,
            vehicle_weight_lbs: None,
            towing: false,
            fuel_fraction: None,
        }
    }

    #[test]
    fn the_yellow_line_is_five_over_and_the_red_line_twenty_over_capped_at_85() {
        assert_eq!(state_threshold_mph(Some(55.0)), Some(60.0));
        assert_eq!(federal_threshold_mph(Some(55.0)), Some(75.0));
        assert_eq!(federal_threshold_mph(Some(75.0)), Some(EXCESS_ABSOLUTE_MPH));
        assert_eq!(standing(57.0, Some(55.0)), Standing::Legal);
        assert_eq!(standing(62.0, Some(55.0)), Standing::StateViolation);
        assert_eq!(standing(76.0, Some(55.0)), Standing::FederalViolation);
    }

    #[test]
    fn nothing_posted_never_accuses_the_driver() {
        for p in [None, Some(0.0), Some(-0.0), Some(-5.0), Some(f64::NAN)] {
            assert_eq!(state_threshold_mph(p), None);
            assert_eq!(federal_threshold_mph(p), None);
            assert_eq!(standing(100.0, p), Standing::Legal);
            assert_eq!(judge(95.0, p), Judgment::Under);
        }
    }

    #[test]
    fn an_untagged_road_gets_the_limit_for_its_kind() {
        assert_eq!(effective_limit_mph(None, 22.0), 25.0);
        assert_eq!(effective_limit_mph(None, 48.0), 45.0);
        assert_eq!(effective_limit_mph(None, 72.0), 65.0);
        assert_eq!(effective_limit_mph(Some(65.0), 12.0), 65.0);
        // A NaN speed matches no range and takes the last arm, as in Swift.
        assert_eq!(estimated_limit_mph(f64::NAN), 65.0);
    }

    #[test]
    fn a_maxspeed_tag_reads_mph_knots_and_bare_kmh() {
        assert_eq!(parse_maxspeed_mph("55 mph"), Some(55.0));
        assert_eq!(parse_maxspeed_mph("70 MPH"), Some(70.0));
        assert_eq!(parse_maxspeed_mph("80"), Some(80.0 / KM_PER_MILE));
        assert_eq!(parse_maxspeed_mph("10 knots"), Some(10.0 * MPH_PER_KNOT));
        assert_eq!(parse_maxspeed_mph("walk"), Some(WALK_MPH));
        for unreadable in ["none", "signals", "variable", "", "fast", "0", " \t"] {
            assert_eq!(parse_maxspeed_mph(unreadable), None, "{unreadable:?}");
        }
    }

    #[test]
    fn the_parse_follows_swift_grapheme_clusters_not_bytes() {
        // A combining mark on the last digit makes a character Double cannot read.
        assert_eq!(parse_maxspeed_mph("55\u{301} mph"), None);
        // On a trailing dot it ends the run before the dot: "5." is 5.
        assert_eq!(parse_maxspeed_mph("5..\u{301}mph"), Some(5.0));
        // A number Double cannot read ends the parse, not the run.
        assert_eq!(parse_maxspeed_mph("55\u{bd} mph"), None);
        // "mph" with a mark on its h is not the word mph: the bare number is km/h.
        assert_eq!(
            parse_maxspeed_mph("55 mph\u{301}"),
            Some(55.0 / KM_PER_MILE)
        );
        // The Kelvin sign lowercases to k in both languages.
        assert_eq!(parse_maxspeed_mph("WAL\u{212a}"), Some(WALK_MPH));
    }

    #[test]
    fn judgment_tolerates_normal_driving() {
        assert_eq!(judge(58.0, Some(55.0)), Judgment::Under);
        assert_eq!(judge(61.0, Some(55.0)), Judgment::SlightlyOver);
        assert_eq!(judge(70.0, Some(55.0)), Judgment::Over);
    }

    #[test]
    fn the_reach_circle_grows_with_time_and_is_floored_and_capped() {
        let r = pursuit_radius_meters(25.0 * 60.0, 55.0);
        assert!((r - 25.0 * 60.0 * 55.0 * MPS_PER_MPH).abs() < 1.0);
        assert_eq!(
            pursuit_radius_meters(0.0, 55.0),
            PURSUIT_MINIMUM_RADIUS_METERS
        );
        assert_eq!(
            pursuit_radius_meters(10.0 * 3600.0, 55.0),
            pursuit_radius_meters(3.0 * 3600.0, 55.0)
        );
    }

    #[test]
    fn towing_violations_come_in_rating_order_and_unknowns_never_fabricate_one() {
        let f150 = TowingRatings {
            gvwr_lbs: Some(7050.0),
            tow_capacity_lbs: Some(11200.0),
            gcwr_lbs: Some(17100.0),
        };
        assert!(towing_check(6500.0, 8000.0, &f150).is_empty());
        assert_eq!(
            towing_check(7500.0, 1000.0, &f150),
            vec![TowingViolation::OverGvwr(450.0)]
        );
        assert_eq!(
            towing_check(7000.0, 12000.0, &f150),
            vec![
                TowingViolation::OverTowCapacity(800.0),
                TowingViolation::OverGcwr(1900.0)
            ]
        );
        let unrated = TowingRatings {
            gvwr_lbs: None,
            tow_capacity_lbs: None,
            gcwr_lbs: None,
        };
        assert!(towing_check(99999.0, 99999.0, &unrated).is_empty());
        assert_eq!(effective_gcwr_lbs(&unrated), None);
        let summed = TowingRatings {
            gcwr_lbs: None,
            ..f150
        };
        assert_eq!(effective_gcwr_lbs(&summed), Some(18250.0));
    }

    #[test]
    fn class_estimates_add_the_ev_pack_to_gvwr_only() {
        let gas = estimated_ratings(6.4, FuelKind::Gas);
        let ev = estimated_ratings(6.4, FuelKind::Electric);
        assert_eq!(gas.gvwr_lbs, Some(7100.0));
        assert_eq!(ev.gvwr_lbs, Some(8300.0));
        assert_eq!(ev.tow_capacity_lbs, gas.tow_capacity_lbs);
        assert_eq!(estimated_ratings(4.0, FuelKind::Diesel).gcwr_lbs, None);
        assert_eq!(
            estimated_ratings(f64::NAN, FuelKind::Gas).gvwr_lbs,
            Some(26000.0)
        );
    }

    #[test]
    fn a_ten_foot_van_cannot_pass_a_twelve_foot_post() {
        let van = 10.0 * 0.3048;
        let m = DEFAULT_CLEARANCE_MARGIN_METERS;
        assert!(!passes_clearances(van, m, Some(&[12.0 * 0.3048])));
        assert!(passes_clearances(
            van,
            m,
            Some(&[(12.0 + 1.0 / 12.0) * 0.3048])
        ));
        assert!(!passes_clearances(
            van,
            m,
            Some(&[13.5 * 0.3048, 12.0 * 0.3048])
        ));
        assert!(passes_clearances(van, m, None));
        assert!(passes_clearances(van, m, Some(&[])));
    }

    #[test]
    fn a_rig_at_the_posted_weight_passes_and_no_weight_never_excludes() {
        assert!(passes_weight_limits(Some(15000.0), Some(&[15000.0])));
        assert!(!passes_weight_limits(Some(15000.0), Some(&[14999.0])));
        assert!(!passes_weight_limits(
            Some(15000.0),
            Some(&[40000.0, 12000.0])
        ));
        assert!(passes_weight_limits(None, Some(&[12000.0])));
        assert!(passes_weight_limits(Some(0.0), Some(&[12000.0])));
        assert!(passes_weight_limits(Some(f64::NAN), Some(&[12000.0])));
        assert!(passes_weight_limits(Some(15000.0), None));
    }

    #[test]
    fn the_grade_limit_is_strict_and_unknown_grade_passes() {
        let limit = degrees_to_percent(14.0);
        assert!((limit - 24.933).abs() < 0.001);
        assert!(passes_grade(limit, Some(20.0)));
        assert!(!passes_grade(limit, Some(26.0)));
        assert!(passes_grade(limit, None));
        assert!(!passes_grade(6.0, Some(6.0)));
    }

    #[test]
    fn the_grade_slider_default_follows_weight_towing_and_clamps() {
        let d = vehicle_default_max_grade_degrees;
        assert_eq!(d(None, Some(3910.0), Some(1500.0), 4.8, false, 0.0), 10.0);
        assert_eq!(d(None, Some(7050.0), Some(11200.0), 6.4, false, 0.0), 8.5);
        assert_eq!(d(None, Some(10800.0), Some(20000.0), 6.8, false, 0.0), 7.0);
        assert_eq!(d(None, Some(14500.0), Some(6000.0), 12.0, false, 0.0), 5.0);
        assert_eq!(
            d(Some(6.0), Some(35000.0), Some(45000.0), 13.5, false, 0.0),
            3.5
        );
        assert_eq!(d(None, Some(7050.0), Some(11200.0), 6.4, true, 2000.0), 5.5);
        assert_eq!(d(None, Some(7050.0), Some(11200.0), 6.4, true, 8000.0), 4.5);
        assert_eq!(
            d(None, Some(7050.0), Some(11200.0), 6.4, true, 11200.0),
            3.5
        );
        assert_eq!(d(None, Some(7050.0), None, 6.4, true, 6000.0), 4.5);
        assert_eq!(d(None, None, None, 13.5, false, 0.0), 5.0);
        let extreme = d(Some(1.0), Some(99000.0), Some(0.0), 20.0, true, 99000.0);
        assert!((2.0..=15.0).contains(&extreme));
    }

    #[test]
    fn the_grade_table_localizes_a_hill_and_a_gap_breaks_the_chain() {
        let e = [
            Some(100.0),
            Some(100.0),
            Some(100.0),
            Some(124.0),
            Some(124.0),
        ];
        let segs = grade_segments(&e, 300.0, 0.0);
        assert_eq!(segs.len(), 4);
        let top = steepest(&segs, 1);
        assert!((top[0].grade_percent - 8.0).abs() < 1e-9);
        assert!((top[0].start_mile - 600.0 / MILE_METERS).abs() < 1e-9);
        assert!(grade_segments(&[Some(100.0), None, Some(200.0)], 300.0, 0.0).is_empty());
        assert!(grade_segments(&e, 0.0, 0.0).is_empty());
        assert!(grade_segments(&e, f64::NAN, 0.0).is_empty());
    }

    #[test]
    fn steepest_keeps_ties_in_input_order_and_a_negative_top_is_empty() {
        let seg = |s: f64, g: f64| GradeSegment {
            start_mile: s,
            end_mile: s + 1.0,
            grade_percent: g,
        };
        let segs: Vec<GradeSegment> = (0..200)
            .map(|i| {
                seg(
                    f64::from(i),
                    f64::from(i % 5) * if i % 2 == 0 { 1.0 } else { -1.0 },
                )
            })
            .collect();
        let sorted = steepest(&segs, 200);
        for w in sorted.windows(2) {
            let (a, b) = (w[0], w[1]);
            assert!(a.grade_percent.abs() >= b.grade_percent.abs());
            if a.grade_percent.abs() == b.grade_percent.abs() {
                assert!(a.start_mile < b.start_mile, "ties keep input order");
            }
        }
        assert!(steepest(&segs, -1).is_empty());
        // NaN grades make the comparator inconsistent; the sort still finishes.
        let nan: Vec<GradeSegment> = (0..300)
            .map(|i| {
                seg(
                    f64::from(i),
                    if i % 3 == 0 {
                        f64::NAN
                    } else {
                        f64::from(i % 7)
                    },
                )
            })
            .collect();
        assert_eq!(steepest(&nan, 300).len(), 300);
    }

    #[test]
    fn next_steep_takes_the_earliest_then_the_steeper() {
        let seg = |s: f64, g: f64| GradeSegment {
            start_mile: s,
            end_mile: s + 1.0,
            grade_percent: g,
        };
        let segs = [seg(1.0, 2.0), seg(5.0, 7.5), seg(20.0, 9.0)];
        let t = STEEP_THRESHOLD_PERCENT;
        let l = STEEP_LOOKAHEAD_MILES;
        assert_eq!(next_steep(3.0, &segs, t, l), Some(1));
        assert_eq!(next_steep(7.0, &segs, t, l), None);
        assert_eq!(next_steep(0.0, &[seg(2.0, -8.0)], t, l), Some(0));
        let overlap = [seg(4.0, 6.5), seg(4.0, -9.0), seg(4.0, 9.0)];
        assert_eq!(next_steep(0.0, &overlap, t, l), Some(1));
    }

    #[test]
    fn idling_throttle_drag_and_hills_decide_the_icon() {
        assert_eq!(verdict(&inputs(55.0, 0.0, 0.0)), DriveVerdict::Efficient);
        assert_eq!(verdict(&inputs(40.0, 4.0, 0.0)), DriveVerdict::Wasteful);
        assert_eq!(verdict(&inputs(95.0, 0.0, 0.0)), DriveVerdict::Wasteful);
        assert_eq!(verdict(&inputs(65.0, 0.0, 6.0)), DriveVerdict::Wasteful);
        assert_eq!(verdict(&inputs(0.0, 0.0, 0.0)), DriveVerdict::Wasteful);
        assert_ne!(verdict(&inputs(1.0, 1.5, 0.0)), DriveVerdict::Wasteful);
        // The score bands are inclusive: grade 1.5 scores exactly 0.25.
        assert_eq!(score(&inputs(55.0, 0.0, 1.5)), 0.25);
        assert_eq!(verdict(&inputs(55.0, 0.0, 1.5)), DriveVerdict::Efficient);
    }

    #[test]
    fn wind_weight_and_shape_all_move_the_score() {
        assert!((headwind_mph(20.0, Some(90.0), Some(90.0)) - 20.0).abs() < 0.01);
        assert!((headwind_mph(20.0, Some(270.0), Some(90.0)) + 20.0).abs() < 0.01);
        assert_eq!(headwind_mph(30.0, None, Some(90.0)), 0.0);
        assert_eq!(headwind_mph(30.0, Some(90.0), Some(-1.0)), 0.0);
        assert!(
            drag_sensitivity(Some(15.0), Some(16.0)) > drag_sensitivity(Some(26.0), Some(35.0))
        );
        assert_eq!(drag_sensitivity(None, None), 1.0);
        let base = inputs(45.0, 2.0, 4.0);
        let towing = DriveInputs {
            towing: true,
            ..base
        };
        assert!(score(&towing) > score(&base));
        assert!(grade_penalty(-50.0) > -0.5);
        assert!(throttle_penalty(-2.0) < 0.0);
        // Swift max keeps a NaN first operand; f64::max would not.
        assert!(grade_penalty(f64::NAN).is_nan());
        assert_eq!(efficient_cruise_mph(Some(20.0), Some(30.0)), 55.0);
    }

    #[test]
    fn the_compass_table_is_clockwise_from_north() {
        assert_eq!(compass_point_index("N"), Some(0));
        assert_eq!(compass_point_index("E"), Some(4));
        assert_eq!(compass_point_index("NNW"), Some(15));
        assert_eq!(compass_point_index("n"), None);
    }

    #[test]
    fn unicode_lookups_find_range_edges() {
        assert!(swift_is_number('0') && swift_is_number('9') && !swift_is_number('a'));
        assert!(swift_joins_previous('\u{301}') && !swift_joins_previous('a'));
        assert!(swift_prepends_to_next('\u{600}') && !swift_prepends_to_next('m'));
        assert!(
            swift_is_whitespace(' ')
                && swift_is_whitespace('\u{3000}')
                && !swift_is_whitespace('\n')
        );
    }
}
