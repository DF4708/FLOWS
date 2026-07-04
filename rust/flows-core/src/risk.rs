//! Risk band classification — byte-identical port of R/scoring.R.
//!
//! The R oracle (`risk_label_from_score`, `risk_rgb_hex`) and these Rust
//! functions must agree on every input, especially the band boundaries.
//! The thresholds are the same literals as `global.R`:
//!   RISK_GREEN_MIN  = 0.3980
//!   RISK_YELLOW_MIN = 0.6990
//!   RISK_RED_MIN    = 0.8751
//!
//! Note the *exact* R comparison structure, reproduced precisely:
//!   Green  : score >= GREEN_MIN  && score <  YELLOW_MIN
//!   Yellow : score >= YELLOW_MIN && score <= RED_MIN
//!   Red    : score >  RED_MIN
//! Non-finite (NaN / infinite) → Transparent, matching R's `is.finite` gate.
//! This is the class of NA-handling bug that R only caught at runtime; here
//! the `f64::is_finite` check makes it explicit and unmissable.

pub const RISK_GREEN_MIN: f64 = 0.3980;
pub const RISK_YELLOW_MIN: f64 = 0.6990;
pub const RISK_RED_MIN: f64 = 0.8751;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RiskBand {
    Transparent,
    Green,
    Yellow,
    Red,
}

impl RiskBand {
    /// Matches R `risk_label_from_score` string output exactly.
    pub fn label(self) -> &'static str {
        match self {
            RiskBand::Transparent => "Transparent",
            RiskBand::Green => "Green",
            RiskBand::Yellow => "Yellow",
            RiskBand::Red => "Red",
        }
    }

    /// Matches R `risk_rgb_hex` output exactly ("transparent" is lowercase
    /// in R; the coloured bands are the CSS hex codes).
    pub fn rgb_hex(self) -> &'static str {
        match self {
            RiskBand::Transparent => "transparent",
            RiskBand::Green => "#2ecc71",
            RiskBand::Yellow => "#f1c40f",
            RiskBand::Red => "#dc3545",
        }
    }
}

/// Classify a 0..1 score into its risk band. Byte-identical to the R
/// implementation including the boundary comparisons and the
/// non-finite → Transparent rule. Reference (readable) implementation —
/// `risk_band_branchless` is the hot-path variant held to equality with it.
pub fn risk_band(score: f64) -> RiskBand {
    if !score.is_finite() {
        return RiskBand::Transparent;
    }
    if score > RISK_RED_MIN {
        RiskBand::Red
    } else if (RISK_YELLOW_MIN..=RISK_RED_MIN).contains(&score) {
        RiskBand::Yellow
    } else if (RISK_GREEN_MIN..RISK_YELLOW_MIN).contains(&score) {
        RiskBand::Green
    } else {
        RiskBand::Transparent
    }
}

/// Sorted band table. `BANDS[i]` is the band once `i` thresholds are crossed.
const BANDS: [RiskBand; 4] = [
    RiskBand::Transparent,
    RiskBand::Green,
    RiskBand::Yellow,
    RiskBand::Red,
];

/// Ascending cut points for the `>=` comparisons (GREEN, YELLOW). RED is a
/// strict `>` boundary handled separately to preserve R's asymmetric
/// semantics (Yellow is [YELLOW, RED] *inclusive*, Red is score > RED).
const RISK_CUTS_GE: [f64; 2] = [RISK_GREEN_MIN, RISK_YELLOW_MIN];

/// Branchless classification via arithmetic — the reference hot-path form.
/// No data-dependent branches: each threshold comparison yields a bool cast
/// to u8, summed into a band index, then a direct table lookup. Kept as the
/// oracle the binary-search variant is proven equal to.
///
/// Correctness follows from the R boundary semantics:
///   score <  GREEN           -> 0 -> Transparent
///   score in [GREEN, YELLOW) -> 1 -> Green
///   score in [YELLOW, RED]   -> 2 -> Yellow   (RED uses `>`, so == RED = Yellow)
///   score >  RED             -> 3 -> Red
///   non-finite               -> 0 -> Transparent
#[inline]
pub fn risk_band_branchless(score: f64) -> RiskBand {
    let finite = score.is_finite() as u8;
    let g = (score >= RISK_GREEN_MIN) as u8;
    let y = (score >= RISK_YELLOW_MIN) as u8;
    let r = (score > RISK_RED_MIN) as u8;
    let idx = (finite * (g + y + r)) as usize;
    BANDS[idx]
}

/// Binary-search classification — the standard lookup form. `partition_point`
/// is a **branchless binary search** in Rust's std (conditional-move based),
/// so this is simultaneously (a) a binary search, (b) loop-free, and
/// (c) branchless — satisfying the lookup + no-loops SOP at once. O(log n)
/// comparisons over the sorted cut table instead of the arithmetic form's
/// unconditional sum; for the tiny 2-element cut table the two are a wash,
/// but the pattern scales to larger sorted lookup tables (gauge thresholds,
/// legend stops, per-state index bounds) where binary search is the clear win.
///
/// The RED boundary is a strict `>` and asymmetric to the `>=` cuts, so it is
/// added after the binary search rather than folded into the sorted table —
/// this preserves R's exact `<= RED_MIN => Yellow` semantics.
///
/// Non-finite handling: NaN makes every `>=`/`>` predicate false, so it maps to
/// 0 → Transparent on its own. But `+inf` clears every cut (`inf >= cut` and
/// `inf > RED` are all true), which alone would yield Red — WRONG vs R's
/// `is.finite` gate. So we multiply the whole index by `finite` (the same
/// branchless gate `risk_band_branchless` uses): non-finite → idx 0 →
/// Transparent, with no data-dependent branch. (Regression: `+inf` previously
/// misclassified as Red — caught by fast_variants_equal_reference_everywhere.)
#[inline]
pub fn risk_band_bsearch(score: f64) -> RiskBand {
    // partition_point returns the count of leading elements satisfying the
    // predicate — i.e. how many `>=` cuts `score` clears. Branchless in std.
    let finite = score.is_finite() as usize;
    let base = RISK_CUTS_GE.partition_point(|&cut| score >= cut);
    let idx = finite * (base + (score > RISK_RED_MIN) as usize);
    BANDS[idx]
}

#[cfg(test)]
mod tests {
    use super::*;

    // These are the exact boundary cases the R SQA suite (gate [8]) and the
    // mutation harness assert on. If any of these drift, the Rust port is
    // NOT byte-identical to R and must not replace it.
    #[test]
    fn boundary_cases_match_r_oracle() {
        let cases: &[(f64, &str)] = &[
            (0.100, "Transparent"),
            (0.397, "Transparent"),
            (0.398, "Green"),   // == GREEN_MIN
            (0.399, "Green"),
            (0.500, "Green"),
            (0.698, "Green"),
            (0.699, "Yellow"),  // == YELLOW_MIN
            (0.700, "Yellow"),
            (0.875, "Yellow"),
            (0.8751, "Yellow"), // == RED_MIN (<=)
            (0.8752, "Red"),    // just above RED_MIN
            (0.900, "Red"),
            (1.000, "Red"),
            (f64::NAN, "Transparent"),
            (f64::INFINITY, "Transparent"),
            (f64::NEG_INFINITY, "Transparent"),
        ];
        for (score, expect) in cases {
            assert_eq!(
                risk_band(*score).label(),
                *expect,
                "risk_band({score}) label mismatch vs R oracle"
            );
        }
    }

    #[test]
    fn rgb_hex_matches_r_oracle() {
        assert_eq!(risk_band(0.1).rgb_hex(), "transparent");
        assert_eq!(risk_band(0.5).rgb_hex(), "#2ecc71");
        assert_eq!(risk_band(0.7).rgb_hex(), "#f1c40f");
        assert_eq!(risk_band(0.9).rgb_hex(), "#dc3545");
    }

    // Both fast variants — the branchless-arithmetic form AND the
    // branchless-binary-search form — must equal the readable reference on
    // every input, including boundaries and non-finite values. If any diverge,
    // that variant is wrong and must not ship.
    #[test]
    fn fast_variants_equal_reference_everywhere() {
        let boundary = [0.100_f64, 0.397, 0.398, 0.399, 0.500, 0.698, 0.699,
                        0.700, 0.875, 0.8751, 0.8752, 0.900, 1.000,
                        f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -1.0, 2.0];
        for &s in &boundary {
            assert_eq!(risk_band_branchless(s), risk_band(s),
                       "branchless != reference at score {s}");
            assert_eq!(risk_band_bsearch(s), risk_band(s),
                       "bsearch != reference at score {s}");
        }
        // Dense sweep to catch any off-boundary drift in either variant.
        let mut x = -0.5_f64;
        while x <= 1.5 {
            assert_eq!(risk_band_branchless(x), risk_band(x),
                       "branchless != reference at score {x}");
            assert_eq!(risk_band_bsearch(x), risk_band(x),
                       "bsearch != reference at score {x}");
            x += 0.0001;
        }
    }
}
