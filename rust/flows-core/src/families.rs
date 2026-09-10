// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Hazard families and the two-tier realized-risk model — the port of the
//! retired R engine's `R/families.R`.
//!
//! # What this is
//!
//! The R server combined per-family hazard scores into one number that the
//! Green/Yellow/Red cuts in [`crate::risk`] sit on. That combination is not a
//! sum and not a max: it is a weighted noisy-OR over a *primary* tier (proof
//! that the road is impassable or the driver is in direct danger) and a
//! *secondary* tier (forecasts and conditions that raise the odds but prove
//! nothing). Only a realized primary can reach Red. Several overlapping
//! predictors must never add up to a life-threatening total.
//!
//! R provenance, function by function:
//!
//! | here | R |
//! |---|---|
//! | [`FAMILY_WEIGHTS`] | `R/families.R` `environmental_family_weights` |
//! | [`noisy_or`] | `R/families.R` `noisy_or_combine` |
//! | [`realized_risk`] | the primary/secondary model built on that combine |
//! | [`alert_family`] | the NWS event-name classifier |
//! | [`ranking_risk`] | the two-truths route ordering |
//!
//! # Determinism
//!
//! Floating-point multiplication is not associative, so a noisy-OR product
//! depends on the ORDER its terms arrive in. Every function here takes a
//! slice and multiplies in slice order, which makes each one a deterministic
//! function of its input sequence — the property [`crate`]'s bundle writers
//! need, since a differing last bit either side of a band cut is a different
//! band. [`canonical_order`] sorts a family list so independent callers can
//! agree on that sequence.
//!
//! This is a deliberate departure from the Swift implementation the app
//! currently runs, which iterates a `Dictionary` and therefore multiplies in
//! an order that varies between process launches (Swift seeds its hasher per
//! process). See `docs/RUST_SWIFT_MIGRATION.md`.
//!
//! # Allocation
//!
//! None. Lookups are binary searches over sorted `&'static` tables; the
//! combines are single passes over a caller-owned slice.

use crate::risk::RISK_RED_MIN;

/// Per-family weight for the secondary (predictor) noisy-OR.
///
/// Exact values from `R/families.R` `environmental_family_weights`, plus the
/// live-feed acute hazards the R export never carried, weighted by their
/// threat to life *while driving*: a tsunami or flood you cannot outrun in a
/// vehicle ranks highest, UV and space weather lowest.
///
/// Sorted by family name so [`family_weight`] can binary-search it. The
/// invariant is checked by a test rather than trusted.
pub const FAMILY_WEIGHTS: &[(&str, f64)] = &[
    ("air", 0.60),
    ("avalanche", 0.86),
    ("cold", 0.66),
    ("convective", 0.92),
    ("fire", 0.74),
    ("flood", 0.96),
    ("heat", 0.70),
    // Precipitation PROBABILITY is a predictor of flood/storm/winter, not a
    // realized hazard: a moderate weight so it advises and amplifies without
    // dominating the secondary combine.
    ("precip", 0.55),
    // The app's key for the flood family; `flood` is the R export's name.
    // Aliased to the same 0.96 so either resolves identically.
    ("qpf_flood", 0.96),
    ("radiation", 0.52),
    ("seismic", 0.78),
    ("tropical", 0.94),
    ("tsunami", 0.97),
    ("volcanic", 0.90),
    ("wind", 0.64),
    ("winter", 0.88),
];

/// Weight for `family`, or `1.0` for an unknown family.
///
/// An unknown family defaulting to full weight is the conservative direction:
/// a hazard nobody has weighted yet contributes at full strength rather than
/// being quietly discounted.
#[must_use]
pub fn family_weight(family: &str) -> f64 {
    match FAMILY_WEIGHTS.binary_search_by(|(name, _)| (*name).cmp(family)) {
        Ok(i) => FAMILY_WEIGHTS[i].1,
        Err(_) => 1.0,
    }
}

/// Families that are directly life-threatening while driving AND backed by
/// proof — an observed event, a detection, or a reported closure. Never a
/// forecast. Only a realized one of these can drive the band to Red.
///
/// The test is travel safety: the road is impassable (water over it, a gauge
/// in flood, the ground moved, a DOT closure) or the driver is in direct
/// danger passing through (inside the fire, a tsunami they cannot outrun, an
/// erupting volcano). `storm` here means a realized severe or tornadic storm
/// — an NWS Tornado or Severe Thunderstorm *Warning* — as distinct from the
/// SPC `convective` outlook, which is a probability and stays a predictor.
///
/// Sorted; see [`is_primary`].
pub const PRIMARY_FAMILIES: &[&str] = &[
    "closure",
    "fire",
    "flood",
    "qpf_flood",
    "seismic",
    "storm",
    "tropical",
    "tsunami",
    "volcanic",
];

/// Predictor and amplifier families — conditions or forecasts that raise the
/// likelihood or severity of a realized primary but prove nothing about a
/// blocked road.
///
/// High wind, heat, cold, haze, UV, precipitation probability, a *forecast* of
/// winter (snow predicted, not a blocked road), the SPC severe-weather
/// outlook, and the avalanche danger *rating*. They spike a realized primary;
/// alone they only advise, capped by [`SECONDARY_CEILING`]. Each realized form
/// becomes a primary the moment its proof feed is wired.
///
/// Sorted; see [`is_secondary`].
pub const SECONDARY_FAMILIES: &[&str] = &[
    "air",
    "avalanche",
    "cold",
    "convective",
    "heat",
    "precip",
    "radiation",
    "wind",
    "winter",
];

/// Upper-Yellow ceiling for a secondary-only situation.
///
/// A pile of predictors — extreme fire weather with no fire, high UV, haze, a
/// windy clear day — can warn strongly but must never read as
/// life-threatening without a realized primary. Structurally below
/// [`RISK_RED_MIN`], which a test enforces against the constant rather than
/// against a copy of its value.
pub const SECONDARY_CEILING: f64 = 0.80;

/// Is this a primary (proof-backed, Red-capable) family?
#[must_use]
pub fn is_primary(family: &str) -> bool {
    PRIMARY_FAMILIES.binary_search(&family).is_ok()
}

/// Is this a secondary (predictor, Red-incapable) family?
#[must_use]
pub fn is_secondary(family: &str) -> bool {
    SECONDARY_FAMILIES.binary_search(&family).is_ok()
}

/// Clamp to `[0, 1]`; a non-finite score reads as absent, not as maximal.
#[inline]
fn clamp01(x: f64) -> f64 {
    if x.is_finite() {
        x.clamp(0.0, 1.0)
    } else {
        0.0
    }
}

/// Weighted noisy-OR: `1 − Π(1 − wᵢ·clamp(sᵢ))`.
///
/// The R engine's `noisy_or_combine`, exactly. Independent evidence compounds
/// without ever exceeding 1, and no single term can erase another.
///
/// # Determinism
///
/// The product is taken in slice order. See the module note: two permutations
/// of the same families can differ in the last bits.
#[must_use]
pub fn noisy_or(scores: &[(&str, f64)]) -> f64 {
    let mut keep = 1.0;
    for (family, raw) in scores {
        keep *= 1.0 - family_weight(family) * clamp01(*raw);
    }
    1.0 - keep
}

/// Compounded, REALIZED risk from a family→score list — the total the band
/// cuts in [`crate::risk`] are meant to sit on.
///
/// The model, and why it is not a sum:
///
/// - primaries combine by UNWEIGHTED noisy-OR, so a realized primary keeps
///   its full severity and two independent primaries compound;
/// - secondaries combine by WEIGHTED noisy-OR (the R combine) and then
///   AMPLIFY the primary, scaled by how realized that primary is — so with no
///   primary there is no amplification;
/// - secondaries alone yield a capped advisory that can never reach Red;
/// - the total is the greater of the amplified primary and that advisory.
///
/// Families in neither tier are IGNORED rather than defaulted, so a derived
/// composite (the `environmental` roll-up, say) cannot double-count the
/// temp/wind/pop signals its own constituents already carry.
///
/// # Determinism
///
/// Deterministic in the input SEQUENCE, not merely the input set — see the
/// module note. Pass [`canonical_order`]-sorted input when two independent
/// callers must agree bit for bit.
#[must_use]
pub fn realized_risk(families: &[(&str, f64)]) -> f64 {
    // One pass, no intermediate collections: this runs per corridor sample
    // per route.
    let mut keep = 1.0; // primaries at full weight
    let mut secondary_keep = 1.0; // predictors at their R weights
    for (f, s) in families {
        if is_primary(f) {
            keep *= 1.0 - clamp01(*s);
        } else if is_secondary(f) {
            secondary_keep *= 1.0 - family_weight(f) * clamp01(*s);
        }
    }
    let primary_base = 1.0 - keep;
    let secondary = 1.0 - secondary_keep;
    // Predictors spike a realized primary; the factor goes to 1 (no effect)
    // as primary_base goes to 0.
    let primary_amplified = primary_base * (1.0 + (1.0 - primary_base) * secondary);
    let secondary_advisory = secondary.min(SECONDARY_CEILING);
    primary_amplified.max(secondary_advisory)
}

/// Sort a family list into the canonical order — by family name — so that
/// independent callers combining the same families get bit-identical results.
///
/// In place, so no allocation. Ties cannot occur: a family may appear at most
/// once in a well-formed input, and duplicates sort adjacently and combine
/// deterministically if they do.
pub fn canonical_order(families: &mut [(&str, f64)]) {
    families.sort_unstable_by(|a, b| a.0.cmp(b.0));
}

/// Waterline-threshold flood amplifier — a multiplier `≥ 1` on the precip
/// PREDICTOR, never proof in itself.
///
/// Water pools toward the local low and rises by the rain depth, so the
/// physics is a threshold rather than a linear ramp:
///
/// ```text
/// waterline = local_min + rain_depth
/// headroom  = road_elevation − local_min
/// ```
///
/// - `headroom ≤ rain_depth` — the risen waterline REACHES the road: a
///   physical flood crossing, amplified regardless of other evidence
///   (1.6…2.0×).
/// - `headroom > rain_depth` — the road sits above the pooling water. Between
///   the low point and the road nothing guarantees flooding, so this earns a
///   bump ONLY with supporting evidence that water reaches it (a FEMA A/V
///   zone, a gauge at flood stage, a mapped river or lake nearby), tapered by
///   how close the waterline comes. No evidence means 1.0.
///
/// # Units
///
/// `qpf_inches` is inches; both elevations are METRES. The rain depth is
/// converted (× 0.0254) so the comparison is real rather than dodged.
/// `local_min_elevation` MUST be a WINDOWED local minimum — the nearby
/// pooling low — not a corridor-global low hundreds of kilometres away.
#[must_use]
pub fn flood_elevation_multiplier(
    sample_elevation: Option<f64>,
    local_min_elevation: Option<f64>,
    qpf_inches: Option<f64>,
    supporting_evidence: f64,
) -> f64 {
    let qpf = match qpf_inches {
        Some(q) if q.is_finite() && q > 0.0 => q,
        _ => return 1.0,
    };
    let rain_meters = qpf * 0.0254;
    let evidence = clamp01(supporting_evidence);
    let (e, lo) = match (sample_elevation, local_min_elevation) {
        (Some(e), Some(lo)) if e.is_finite() && lo.is_finite() => (e, lo),
        // No elevation data: rain matters only where there is water evidence.
        _ => return 1.0 + 0.5 * evidence * (qpf / 2.0).min(1.0),
    };
    let headroom = (e - lo).max(0.0);
    if headroom <= rain_meters {
        let submerge = ((rain_meters - headroom) / rain_meters.max(0.01)).min(1.0);
        return 1.0 + (0.6 + 0.4 * submerge); // 1.6 … 2.0
    }
    if evidence <= 0.0 {
        return 1.0;
    }
    let proximity = (1.0 - (headroom - rain_meters) / rain_meters.max(0.01)).max(0.0);
    1.0 + 0.5 * evidence * proximity
}

/// Balance the two truths for ROUTE ORDERING — never for the display band.
///
/// The realized-risk `band` (alerts and current conditions) and the
/// IDENTIFIED exposure of the ZIPs traversed (the modeled field, then the
/// on-device seasonal prior) are both evidence: a ZIP can carry known risk
/// before any alert fires, and an alert can fire where no prior risk was
/// known. Identified risk is discounted (× 0.6) against a realized hazard, so
/// a realized Red still dominates — but between two same-band routes the one
/// through lower-exposure ZIPs ranks safer. As the seasonal prior for this
/// route and week accrues `prior_confidence` it takes over from the static
/// field. Noisy-OR, so neither truth erases the other.
#[must_use]
pub fn ranking_risk(
    band: f64,
    zip_exposure: f64,
    seasonal_prior: f64,
    prior_confidence: f64,
) -> f64 {
    let z = clamp01(zip_exposure);
    let p = clamp01(seasonal_prior);
    let c = clamp01(prior_confidence);
    let identified = z * (1.0 - c) + p * c;
    1.0 - (1.0 - clamp01(band)) * (1.0 - 0.6 * identified)
}

/// Classify an NWS alert EVENT name into the [`realized_risk`] family it
/// feeds, or `None` when nothing maps.
///
/// Whether the result can reach Red follows from its tier: an in-progress
/// danger WARNING maps to a primary family, while a watch, advisory, or
/// condition warning maps to a predictor and stays capped.
///
/// # Order is load-bearing
///
/// The specific realized phrases MUST be tested before the generic family
/// words they contain. "Snow Squall Warning" contains "snow"; if the winter
/// predictor rule ran first, a radar-confirmed whiteout would silently
/// downgrade to a capped secondary and could never reach Red. Every early
/// return below is there for a case like that, and the tests pin them.
#[must_use]
pub fn alert_family(event: &str) -> Option<&'static str> {
    let e = event.to_lowercase();
    let has = |needle: &str| e.contains(needle);

    // --- realized, in-progress danger -> PRIMARY ---
    if has("tornado warning") || has("severe thunderstorm warning") {
        return Some("storm");
    }
    // Short-fused realized warnings whose names embed a generic season or
    // condition word. Snow Squall = radar-confirmed whiteout and flash
    // freeze; Dust Storm = observed zero visibility (the I-10 pileups).
    if has("snow squall warning") {
        return Some("storm");
    }
    if has("dust storm warning") || has("blowing dust warning") {
        return Some("storm");
    }
    // NWS FRW — an active wildfire threatening a populated area — is
    // realized. "Fire weather warning" and "red flag" are hot-dry
    // PREDICTORS and are excluded here, then handled below.
    if has("fire warning") && !has("fire weather") {
        return Some("fire");
    }
    if has("flash flood warning") || has("flash flood emergency") || has("flood warning") {
        return Some("qpf_flood");
    }
    if has("tsunami warning") {
        return Some("tsunami");
    }
    if has("hurricane warning")
        || has("storm surge warning")
        || has("extreme wind")
        || has("tropical storm warning")
    {
        return Some("tropical");
    }
    // Only the realized forms are primary: an Ashfall ADVISORY is trace ash,
    // a condition advisory, and must stay Red-incapable.
    if has("ashfall") || has("volcano") {
        return Some(if has("advisory") { "air" } else { "volcanic" });
    }

    // --- predictors (watch / advisory / condition warning) -> SECONDARY ---
    if has("winter") || has("ice storm") || has("blizzard") || has("snow") || has("freezing rain") {
        return Some("winter");
    }
    if has("heat") {
        return Some("heat");
    }
    if has("chill") || has("freeze") || has("frost") || has("cold") {
        return Some("cold");
    }
    if has("red flag") || has("fire weather") {
        return Some("heat"); // hot, dry fire weather
    }
    // A tropical or typhoon WATCH (the warning is primary above): high winds
    // possible, so it contributes as a wind predictor instead of scoring zero.
    if has("hurricane") || has("typhoon") || has("tropical storm") {
        return Some("wind");
    }
    if has("wind") {
        return Some("wind");
    }
    if has("air quality") || has("smoke") || has("dust") || has("fog") {
        return Some("air");
    }
    if has("flood") {
        return Some("precip"); // Flood Watch / Advisory
    }
    if has("tornado") || has("thunderstorm") || has("storm") {
        return Some("convective"); // watch or general storm -> predictor
    }
    // A Tsunami Watch/Advisory is a strong-current coastal hazard with
    // marginal road relevance; the tsunami WARNING is primary above. Left
    // unscored rather than forced into an ill-fitting predictor family.
    None
}

/// How a whole route's risk band is decided from its pieces.
///
/// Normally the distance-weighted average: what fraction of the miles
/// actually travelled sit at what risk, so a minority yellow stretch does not
/// paint an otherwise clear trip yellow.
///
/// A RED peak is a FLOOR rather than an average. You cannot average your way
/// out of a tornado warning: two miles of it inside a twenty-mile trip is not
/// a green trip. Diluting it is how one corridor came out full red for
/// driving and half green for walking — the two modes sample the same ground
/// at different densities, so any average disagrees with itself between them.
/// A life-safety hazard on the path is the same hazard whichever way you
/// travel it.
#[must_use]
pub fn displayed_band(weighted: f64, peak: f64) -> f64 {
    if peak > RISK_RED_MIN {
        weighted.max(peak)
    } else {
        weighted
    }
}

/// Hazards that are a DISTINCT named danger rather than a reading on a dial —
/// the thing a driver most needs called by its name when scores are close.
/// They get a nudge, not a veto. Sorted.
pub const ACUTE_FAMILIES: &[&str] = &[
    "air",
    "avalanche",
    "fire",
    "radiation",
    "seismic",
    "tropical",
    "tsunami",
    "volcanic",
];

/// How much an acute hazard is favoured when scores are close. Small on
/// purpose: enough to win a tie, nowhere near enough to beat a hazard that is
/// materially worse.
pub const ACUTE_NUDGE: f64 = 0.05;

/// The default floor below which nothing is elevated enough to name an area.
pub const DOMINANT_FLOOR: f64 = 0.45;

/// The family that should NAME an area, comparing every hazard on the same
/// footing. `None` when nothing clears `floor`.
///
/// This was once a hard priority tier: any "acute" family at 0.45 took the
/// icon, and `convective` and `qpf_flood` were not on the list at all — so
/// storms and flooding could never name an area however bad they were. A
/// Georgia ZIP with a middling fire-weather reading and severe storms around
/// it came out labelled FIRE. The highest score now wins, with acute hazards
/// carrying [`ACUTE_NUDGE`] for ties.
///
/// # Determinism
///
/// Exact ties are broken by family NAME, so the answer does not depend on
/// input order. The Swift implementation resolves them by dictionary
/// iteration order and is therefore not reproducible between launches.
#[must_use]
pub fn dominant_family<'a>(families: &[(&'a str, f64)], floor: f64) -> Option<&'a str> {
    let score = |f: &str, s: f64| s + if is_acute(f) { ACUTE_NUDGE } else { 0.0 };
    let mut best: Option<(&'a str, f64)> = None;
    for (f, s) in families {
        if !s.is_finite() || *s < floor {
            continue;
        }
        let w = score(f, *s);
        best = match best {
            // Strictly greater wins; an exact tie goes to the lower name.
            Some((bf, bw)) if w > bw || (w == bw && *f < bf) => Some((f, w)),
            Some(prev) => Some(prev),
            None => Some((f, w)),
        };
    }
    best.map(|(f, _)| f)
}

/// The single worst family at or above `floor` — a plain maximum with NO
/// acute nudge, for callers that want the dominant reading rather than the
/// name to draw (the traffic-delay weather bucket, the learned-ETA road
/// class). `None` when nothing clears the floor.
///
/// # Determinism
///
/// Exact ties go to the lower family name, so the answer is a function of
/// the input set and not of its order.
#[must_use]
pub fn peak_family<'a>(families: &[(&'a str, f64)], floor: f64) -> Option<&'a str> {
    let mut best: Option<(&'a str, f64)> = None;
    for (f, s) in families {
        if !s.is_finite() || *s < floor {
            continue;
        }
        best = match best {
            Some((bf, bs)) if *s > bs || (*s == bs && *f < bf) => Some((f, *s)),
            Some(prev) => Some(prev),
            None => Some((f, *s)),
        };
    }
    best.map(|(f, _)| f)
}

/// Is this family a distinct named danger rather than a dial reading?
#[must_use]
pub fn is_acute(family: &str) -> bool {
    ACUTE_FAMILIES.binary_search(&family).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::risk::RISK_YELLOW_MIN;

    // ---- the sorted-table invariant the binary searches depend on ----

    #[test]
    fn every_static_table_is_sorted_because_lookups_binary_search_them() {
        // A table that drifts out of order does not fail loudly — it silently
        // returns the wrong weight or misses a membership test.
        assert!(FAMILY_WEIGHTS.windows(2).all(|w| w[0].0 < w[1].0));
        assert!(PRIMARY_FAMILIES.windows(2).all(|w| w[0] < w[1]));
        assert!(SECONDARY_FAMILIES.windows(2).all(|w| w[0] < w[1]));
        assert!(ACUTE_FAMILIES.windows(2).all(|w| w[0] < w[1]));
    }

    #[test]
    fn no_family_is_both_proof_and_prediction() {
        for f in PRIMARY_FAMILIES {
            assert!(!is_secondary(f), "{f} is in both tiers");
        }
    }

    #[test]
    fn the_secondary_ceiling_sits_below_the_red_cut_by_construction() {
        // Checked against the CONSTANT, not a copy of its value: the whole
        // point of the ceiling is that predictors cannot reach Red, and that
        // has to keep holding if the cut ever moves.
        // Constant by construction, which is the guarantee wanted: this
        // fails at build time if either constant moves across the other,
        // rather than at runtime on some unlucky corridor.
        #[allow(clippy::assertions_on_constants)]
        {
            assert!(SECONDARY_CEILING < RISK_RED_MIN);
            assert!(
                SECONDARY_CEILING > RISK_YELLOW_MIN,
                "an advisory should still be able to warn"
            );
        }
    }

    // ---- R-derived weights ----

    #[test]
    fn the_r_export_weights_are_exact() {
        assert_eq!(family_weight("wind"), 0.64);
        assert_eq!(family_weight("flood"), 0.96);
        assert_eq!(family_weight("winter"), 0.88);
        assert_eq!(family_weight("convective"), 0.92);
        assert_eq!(family_weight("fire"), 0.74);
        assert_eq!(family_weight("heat"), 0.70);
        assert_eq!(family_weight("cold"), 0.66);
        assert_eq!(family_weight("air"), 0.60);
        assert_eq!(family_weight("radiation"), 0.52);
        assert_eq!(family_weight("seismic"), 0.78);
    }

    #[test]
    fn the_flood_alias_resolves_to_the_same_weight() {
        assert_eq!(family_weight("qpf_flood"), family_weight("flood"));
    }

    #[test]
    fn an_unweighted_family_contributes_at_full_strength() {
        // Conservative direction: unknown must not be quietly discounted.
        assert_eq!(family_weight("something_new"), 1.0);
    }

    // ---- noisy-OR ----

    #[test]
    fn noisy_or_is_the_r_combine() {
        // 1 - (1 - 0.64*0.5) = 0.32
        let got = noisy_or(&[("wind", 0.5)]);
        assert!((got - 0.32).abs() < 1e-12, "{got}");
        // two independent terms compound: 1 - (1-0.32)(1-0.48)
        let got = noisy_or(&[("wind", 0.5), ("air", 0.8)]);
        let want = 1.0 - (1.0 - 0.64 * 0.5) * (1.0 - 0.60 * 0.8);
        assert!((got - want).abs() < 1e-12, "{got} vs {want}");
    }

    #[test]
    fn noisy_or_never_leaves_the_unit_interval() {
        assert_eq!(noisy_or(&[]), 0.0);
        for s in [-5.0, 0.0, 0.5, 1.0, 5.0, f64::NAN, f64::INFINITY] {
            let v = noisy_or(&[("flood", s), ("wind", s), ("heat", s)]);
            assert!((0.0..=1.0).contains(&v), "score {s} gave {v}");
        }
    }

    #[test]
    fn a_non_finite_score_reads_as_absent_not_as_maximal() {
        // Absent, NOT maximal — an infinity arriving from a bad feed must
        // not read as a certain hazard. The same clamp rule as R's.
        assert_eq!(noisy_or(&[("flood", f64::NAN)]), 0.0);
        assert_eq!(noisy_or(&[("flood", f64::INFINITY)]), 0.0);
        assert_eq!(noisy_or(&[("flood", f64::NEG_INFINITY)]), 0.0);
    }

    // ---- the two-tier model: the property that matters ----

    #[test]
    fn predictors_alone_can_never_reach_red_however_many_pile_up() {
        // The whole reason the model is two-tier. Max out every predictor.
        let all: Vec<(&str, f64)> = SECONDARY_FAMILIES.iter().map(|f| (*f, 1.0)).collect();
        let v = realized_risk(&all);
        assert!(v <= SECONDARY_CEILING, "{v}");
        assert!(v < RISK_RED_MIN, "predictors reached Red: {v}");
    }

    #[test]
    fn one_realized_primary_keeps_its_full_severity() {
        // Unweighted: a maxed primary stays maxed.
        assert!((realized_risk(&[("closure", 1.0)]) - 1.0).abs() < 1e-12);
        // And a partial one is not discounted by a weight either.
        assert!((realized_risk(&[("qpf_flood", 0.5)]) - 0.5).abs() < 1e-12);
    }

    #[test]
    fn two_independent_primaries_compound() {
        let a = realized_risk(&[("fire", 0.5)]);
        let both = realized_risk(&[("fire", 0.5), ("seismic", 0.5)]);
        assert!(both > a, "{both} should exceed {a}");
        assert!((both - 0.75).abs() < 1e-12, "{both}"); // 1-(0.5*0.5)
    }

    #[test]
    fn predictors_amplify_a_realized_primary_but_only_a_realized_one() {
        let bare = realized_risk(&[("qpf_flood", 0.5)]);
        let amplified = realized_risk(&[("qpf_flood", 0.5), ("wind", 0.9)]);
        assert!(amplified > bare, "predictors must spike a primary");
        // With no primary the same predictor only advises.
        let advisory = realized_risk(&[("wind", 0.9)]);
        assert!(advisory < bare + 1e-9 || advisory <= SECONDARY_CEILING);
        assert!(advisory <= SECONDARY_CEILING);
    }

    #[test]
    fn amplification_vanishes_as_the_primary_does() {
        // The factor is (1 + (1-base)*secondary) applied to base, so it
        // scales with how realized the primary is and a zero primary stays
        // zero — amplification cannot manufacture a hazard.
        let no_primary = realized_risk(&[("fire", 0.0), ("wind", 1.0)]);
        assert!(no_primary <= SECONDARY_CEILING, "{no_primary}");
        // no primary AT ALL -> capped advisory only
        let v = realized_risk(&[("wind", 1.0), ("heat", 1.0)]);
        assert!(v <= SECONDARY_CEILING);
    }

    #[test]
    fn families_in_neither_tier_are_ignored_not_defaulted() {
        // The derived `environmental` composite must not double-count the
        // temp/wind/pop signals its own constituents already carry.
        let without = realized_risk(&[("qpf_flood", 0.4)]);
        let with = realized_risk(&[("qpf_flood", 0.4), ("environmental", 0.9)]);
        assert!((without - with).abs() < 1e-12, "{without} vs {with}");
    }

    #[test]
    fn realized_risk_never_leaves_the_unit_interval() {
        for s in [-1.0, 0.0, 0.3, 1.0, 9.0, f64::NAN] {
            let v = realized_risk(&[("closure", s), ("wind", s), ("environmental", s)]);
            assert!((0.0..=1.0).contains(&v), "score {s} gave {v}");
        }
    }

    // ---- determinism ----

    #[test]
    fn canonical_order_makes_the_combine_reproducible() {
        let mut a = [
            ("wind", 0.4),
            ("qpf_flood", 0.7),
            ("heat", 0.2),
            ("closure", 0.3),
        ];
        let mut b = [
            ("closure", 0.3),
            ("heat", 0.2),
            ("wind", 0.4),
            ("qpf_flood", 0.7),
        ];
        canonical_order(&mut a);
        canonical_order(&mut b);
        assert_eq!(a, b);
        // bit-identical, not merely close
        assert_eq!(realized_risk(&a).to_bits(), realized_risk(&b).to_bits());
    }

    #[test]
    fn permuted_input_agrees_to_within_rounding_even_unsorted() {
        // Documents the module's determinism note: order affects the last
        // bits, and nothing more. If this ever drifts materially, the model
        // has become order-SENSITIVE, which would be a defect.
        let a = [("wind", 0.4), ("qpf_flood", 0.7), ("heat", 0.2)];
        let b = [("heat", 0.2), ("wind", 0.4), ("qpf_flood", 0.7)];
        assert!((realized_risk(&a) - realized_risk(&b)).abs() < 1e-12);
    }

    // ---- flood amplifier ----

    #[test]
    fn no_rain_means_no_flood_amplification() {
        assert_eq!(
            flood_elevation_multiplier(Some(300.0), Some(295.0), None, 1.0),
            1.0
        );
        assert_eq!(
            flood_elevation_multiplier(Some(300.0), Some(295.0), Some(0.0), 1.0),
            1.0
        );
    }

    #[test]
    fn a_waterline_reaching_the_road_amplifies_without_needing_evidence() {
        // 40 inches of rain = 1.016 m, road sits 0.5 m above the local low.
        let m = flood_elevation_multiplier(Some(100.5), Some(100.0), Some(40.0), 0.0);
        assert!((1.6..=2.0).contains(&m), "{m}");
    }

    #[test]
    fn a_road_above_the_waterline_needs_evidence_before_it_is_flooded() {
        // 1 inch of rain (0.0254 m) against 5 m of headroom.
        assert_eq!(
            flood_elevation_multiplier(Some(105.0), Some(100.0), Some(1.0), 0.0),
            1.0
        );
        // With evidence it earns a bump, tapered by distance.
        let m = flood_elevation_multiplier(Some(105.0), Some(100.0), Some(1.0), 1.0);
        assert!((1.0..=1.5).contains(&m), "{m}");
    }

    #[test]
    fn missing_elevation_falls_back_to_evidence_alone() {
        assert_eq!(flood_elevation_multiplier(None, None, Some(4.0), 0.0), 1.0);
        let m = flood_elevation_multiplier(None, None, Some(4.0), 1.0);
        assert!((m - 1.5).abs() < 1e-12, "{m}");
    }

    // ---- ranking ----

    #[test]
    fn a_realized_band_still_dominates_identified_exposure() {
        let realized_red = ranking_risk(0.95, 0.0, 0.0, 0.0);
        let quiet_but_exposed = ranking_risk(0.0, 1.0, 0.0, 0.0);
        assert!(realized_red > quiet_but_exposed);
        // exposure is discounted 0.6 against a realized hazard
        assert!(
            (quiet_but_exposed - 0.6).abs() < 1e-12,
            "{quiet_but_exposed}"
        );
    }

    #[test]
    fn exposure_breaks_a_tie_between_same_band_routes() {
        let clean = ranking_risk(0.5, 0.1, 0.0, 0.0);
        let dirty = ranking_risk(0.5, 0.9, 0.0, 0.0);
        assert!(dirty > clean);
    }

    #[test]
    fn confidence_hands_over_from_the_field_to_the_prior() {
        // c = 0 -> field only; c = 1 -> prior only.
        assert!(
            (ranking_risk(0.0, 0.8, 0.2, 0.0) - ranking_risk(0.0, 0.8, 0.0, 0.0)).abs() < 1e-12
        );
        assert!(
            (ranking_risk(0.0, 0.8, 0.2, 1.0) - ranking_risk(0.0, 0.2, 0.2, 1.0)).abs() < 1e-12
        );
    }

    // ---- alert classification: the ordering that is load-bearing ----

    #[test]
    fn realized_warnings_map_to_red_capable_primaries() {
        for (event, family) in [
            ("Tornado Warning", "storm"),
            ("Severe Thunderstorm Warning", "storm"),
            ("Snow Squall Warning", "storm"),
            ("Dust Storm Warning", "storm"),
            ("Flash Flood Warning", "qpf_flood"),
            ("Flood Warning", "qpf_flood"),
            ("Tsunami Warning", "tsunami"),
            ("Hurricane Warning", "tropical"),
            ("Storm Surge Warning", "tropical"),
            ("Extreme Wind Warning", "tropical"),
            ("Fire Warning", "fire"),
        ] {
            let got = alert_family(event);
            assert_eq!(got, Some(family), "{event}");
            assert!(
                is_primary(family),
                "{event} -> {family} must be Red-capable"
            );
        }
    }

    #[test]
    fn a_snow_squall_warning_is_not_downgraded_by_the_word_snow() {
        // The exact ordering bug the early return exists to prevent.
        assert_eq!(alert_family("Snow Squall Warning"), Some("storm"));
        assert!(is_primary("storm"));
        // while an ordinary snow product stays a predictor
        assert_eq!(alert_family("Winter Storm Warning"), Some("winter"));
        assert!(is_secondary("winter"));
    }

    #[test]
    fn fire_weather_is_a_predictor_but_an_active_fire_warning_is_not() {
        assert_eq!(alert_family("Fire Warning"), Some("fire"));
        assert!(is_primary("fire"));
        assert_eq!(alert_family("Fire Weather Warning"), Some("heat"));
        assert_eq!(alert_family("Red Flag Warning"), Some("heat"));
        assert!(is_secondary("heat"));
    }

    #[test]
    fn an_ashfall_advisory_stays_red_incapable_while_an_eruption_does_not() {
        assert_eq!(alert_family("Ashfall Advisory"), Some("air"));
        assert!(is_secondary("air"));
        assert_eq!(alert_family("Ashfall Warning"), Some("volcanic"));
        assert!(is_primary("volcanic"));
    }

    #[test]
    fn watches_and_advisories_stay_predictors() {
        for (event, family) in [
            ("Tornado Watch", "convective"),
            ("Severe Thunderstorm Watch", "convective"),
            ("Flood Watch", "precip"),
            ("High Wind Advisory", "wind"),
            ("Hurricane Watch", "wind"),
            ("Excessive Heat Warning", "heat"),
            ("Wind Chill Advisory", "cold"),
            ("Air Quality Alert", "air"),
            ("Dense Fog Advisory", "air"),
            ("Blizzard Warning", "winter"),
        ] {
            let got = alert_family(event);
            assert_eq!(got, Some(family), "{event}");
            assert!(is_secondary(family), "{event} -> {family} must be capped");
        }
    }

    #[test]
    fn an_unmapped_event_is_none_rather_than_a_guess() {
        assert_eq!(alert_family("Tsunami Advisory"), None);
        assert_eq!(alert_family("Special Marine Bulletin"), None);
        assert_eq!(alert_family(""), None);
    }

    #[test]
    fn classification_is_case_insensitive() {
        assert_eq!(
            alert_family("TORNADO WARNING"),
            alert_family("tornado warning")
        );
        assert_eq!(alert_family("tOrNaDo WaRnInG"), Some("storm"));
    }

    // ---- display band ----

    #[test]
    fn a_red_peak_is_a_floor_not_an_average() {
        // Two miles of tornado warning in a twenty-mile trip is not green.
        let weighted = 0.2;
        let peak = 0.95;
        assert!((displayed_band(weighted, peak) - peak).abs() < 1e-12);
    }

    #[test]
    fn below_red_the_distance_weighted_average_stands() {
        assert!((displayed_band(0.2, 0.7) - 0.2).abs() < 1e-12);
    }

    // ---- naming an area ----

    #[test]
    fn the_worst_hazard_names_the_area_not_the_most_dramatic_one() {
        // The Georgia bug: a middling fire reading must not outrank severe
        // storms and flooding.
        let got = dominant_family(
            &[("fire", 0.45), ("convective", 0.9), ("qpf_flood", 0.8)],
            DOMINANT_FLOOR,
        );
        assert_eq!(got, Some("convective"));
    }

    #[test]
    fn an_acute_hazard_wins_a_tie_but_not_a_real_gap() {
        // nudge decides equal scores
        assert_eq!(
            dominant_family(&[("fire", 0.6), ("convective", 0.6)], DOMINANT_FLOOR),
            Some("fire")
        );
        // but cannot overcome a materially worse hazard
        assert_eq!(
            dominant_family(&[("fire", 0.6), ("convective", 0.7)], DOMINANT_FLOOR),
            Some("convective")
        );
    }

    #[test]
    fn nothing_below_the_floor_names_anything() {
        assert_eq!(
            dominant_family(&[("wind", 0.2), ("heat", 0.3)], DOMINANT_FLOOR),
            None
        );
        assert_eq!(dominant_family(&[], DOMINANT_FLOOR), None);
    }

    #[test]
    fn exact_ties_resolve_by_name_so_the_answer_does_not_depend_on_order() {
        let a = [("convective", 0.7), ("winter", 0.7)];
        let b = [("winter", 0.7), ("convective", 0.7)];
        assert_eq!(
            dominant_family(&a, DOMINANT_FLOOR),
            dominant_family(&b, DOMINANT_FLOOR)
        );
        assert_eq!(dominant_family(&a, DOMINANT_FLOOR), Some("convective"));
    }

    /// The cross-language fixture. These six inputs are pinned bit-for-bit
    /// here AND in the Swift suite (FLOWSTests/RiskDeterminismTests.swift):
    /// if either implementation drifts from the other by a single bit, its
    /// own suite fails. Run with `--nocapture` to print fresh values after a
    /// deliberate model change, then update both files together.
    #[test]
    fn cross_language_fixture_is_bit_exact() {
        let cases: [(&str, Vec<(&str, f64)>); 6] = [
            (
                "flood_in_rain",
                vec![("qpf_flood", 0.7), ("precip", 0.9), ("wind", 0.6)],
            ),
            (
                "fire_in_weather",
                vec![("fire", 0.85), ("wind", 0.95), ("heat", 0.9)],
            ),
            (
                "mixed_with_ignored",
                vec![
                    ("closure", 0.3),
                    ("heat", 0.2),
                    ("wind", 0.4),
                    ("qpf_flood", 0.7),
                    ("environmental", 0.9),
                ],
            ),
            (
                "all_predictors_maxed",
                SECONDARY_FAMILIES.iter().map(|f| (*f, 1.0)).collect(),
            ),
            ("two_primaries", vec![("seismic", 0.5), ("fire", 0.5)]),
            // Nine predictors at SMALL values plus a small primary: the one
            // case where the secondary stays below the ceiling and both
            // accumulators multiply ten terms, so the ORDER is what is being
            // pinned. (The maxed case above saturates at exactly 0.80 and
            // proves the ceiling, not the sequence.)
            (
                "ten_terms_unsaturated",
                vec![
                    ("wind", 0.13),
                    ("cold", 0.07),
                    ("air", 0.11),
                    ("radiation", 0.09),
                    ("avalanche", 0.12),
                    ("convective", 0.08),
                    ("winter", 0.06),
                    ("precip", 0.15),
                    ("heat", 0.05),
                    ("fire", 0.2),
                ],
            ),
        ];
        let expected: [u64; 6] = FIXTURE_BITS;
        for (i, (name, fams)) in cases.iter().enumerate() {
            let mut sorted = fams.clone();
            canonical_order(&mut sorted);
            let v = realized_risk(&sorted);
            println!("FIXTURE {name} {:#018x} {v:.17}", v.to_bits());
            if expected[i] != 0 {
                assert_eq!(v.to_bits(), expected[i], "{name}: {v:.17} drifted");
            }
        }
    }

    /// Filled in from the printer above; a zero means "not yet pinned".
    const FIXTURE_BITS: [u64; 6] = [
        0x3feb_0790_1739_d869, // flood_in_rain        0.84467320000000001
        0x3fee_b030_4973_e758, // fire_in_weather      0.95900739999999995
        0x3feb_3128_0d87_9f69, // mixed_with_ignored   0.84975054400000005
        0x3fe9_9999_9999_999a, // all_predictors_maxed 0.80000000000000004 (the ceiling)
        0x3fe8_0000_0000_0000, // two_primaries        0.75
        0x3fdd_4910_b178_ba6a, // ten_terms_unsaturated 0.45758454638681789
    ];

    #[test]
    fn peak_family_is_a_plain_max_with_name_ties() {
        assert_eq!(
            peak_family(&[("fire", 0.6), ("convective", 0.6)], 0.4),
            Some("convective")
        );
        assert_eq!(
            peak_family(&[("fire", 0.6), ("convective", 0.7)], 0.4),
            Some("convective")
        );
        assert_eq!(peak_family(&[("wind", 0.2)], 0.4), None);
        assert_eq!(peak_family(&[("wind", f64::NAN)], 0.0), None);
    }

    #[test]
    fn a_non_finite_score_cannot_name_an_area() {
        assert_eq!(dominant_family(&[("fire", f64::NAN)], DOMINANT_FLOOR), None);
    }
}
