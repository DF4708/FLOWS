// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

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
/// non-finite → Transparent rule.
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
}
