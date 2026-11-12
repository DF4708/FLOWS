// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::viewport_point`, behind Swift's
//! `ViewportPointRules`. Implementations live in `flows-core`; this file
//! only crosses.
//!
//! Families cross as U+001F-joined names beside a column of scores, with
//! the count of names said out loud. Answers come back as one column:
//!
//! - `flows_viewport_display`: Swift sends every name the answer could
//!   hold, the forecast's first (`forecast_count` of them, with their
//!   scores) and the live families after. The answer is `[shows]` and then,
//!   for each name sent, `present, score`.
//! - `flows_viewport_point`: the answer is `icon kind, name source, name
//!   index`, then `present, score` for the closure among the families that
//!   show, for the closure in the band and for the alert's family in the
//!   band, and then
//!   the fifteen band families in `flows_viewport_band_names` order. Icon
//!   kinds: 0 a family, 1 rain chance, 2 the forecast, 3 the alert,
//!   4 a closure. A family's name is found in the names sent (source 0), in
//!   the band names (1), is the alert's family (2) or is "closure" (3).
//!
//! An empty column is the failure answer: a count the buffers do not hold,
//! or a panic inside. Swift then shows the point on what it was given.
//!
//! swift-bridge must never see an empty buffer, so with no names Swift
//! sends a one-score column and a count of zero.

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        fn flows_viewport_band_names() -> String;
        fn flows_viewport_display(
            score: f64,
            names: &str,
            scores: &[f64],
            count: i64,
            forecast_count: i64,
            live: &[f64],
            has_air: bool,
        ) -> Vec<f64>;
        fn flows_viewport_point(
            names: &str,
            scores: &[f64],
            count: i64,
            flood_realized: f64,
            convective: f64,
            precip_risk: f64,
            alert_family: &str,
            has_alert: bool,
            alert_severity: f64,
            closed: f64,
        ) -> Vec<f64>;
    }
}

use crate::contain;
use flows_core::viewport_point as vp;

const NAME_SEPARATOR: char = '\u{1f}';
/// More families than any table holds; a larger count is a bad call.
const MAX_FAMILIES: usize = 256;
/// The live column: fire, seismic, volcanic, avalanche, tropical, tsunami,
/// convective, space radiation, gauge flood, air, uv.
const LIVE_FIELDS: usize = 11;

/// The first `count` names beside their scores; `None` when the buffers do
/// not hold that many.
fn named<'a>(names: &'a str, scores: &[f64], count: i64) -> Option<Vec<(&'a str, f64)>> {
    let count = usize::try_from(count).ok().filter(|&c| c <= MAX_FAMILIES)?;
    if count == 0 {
        return Some(Vec::new());
    }
    let ns: Vec<&str> = names.split(NAME_SEPARATOR).collect();
    (ns.len() == count && scores.len() >= count)
        .then(|| ns.into_iter().zip(scores.iter().copied()).collect())
}

/// The band's fifteen families, U+001F-joined, in the order
/// `flows_viewport_point` returns their scores.
pub fn flows_viewport_band_names() -> String {
    vp::BAND_FAMILIES.join("\u{1f}")
}

/// `ViewportPointRules.displayFamilies` (see the module notes for the layout).
pub fn flows_viewport_display(
    score: f64,
    names: &str,
    scores: &[f64],
    count: i64,
    forecast_count: i64,
    live: &[f64],
    has_air: bool,
) -> Vec<f64> {
    contain(Vec::new(), || {
        let (Some(all), Ok(forecast_count)) =
            (named(names, scores, count), usize::try_from(forecast_count))
        else {
            return Vec::new();
        };
        if forecast_count > all.len() || live.len() != LIVE_FIELDS {
            return Vec::new();
        }
        let readings = vp::Live {
            fire: live[0],
            seismic: live[1],
            volcanic: live[2],
            avalanche: live[3],
            tropical: live[4],
            tsunami: live[5],
            convective: live[6],
            space_radiation: live[7],
            flood_realized: live[8],
            air: has_air.then_some(live[9]),
            uv: live[10],
        };
        let shown = vp::display_families(score, &all[..forecast_count], &readings);
        let mut out = Vec::with_capacity(1 + 2 * all.len());
        out.push(if shown.is_some() { 1.0 } else { 0.0 });
        for (name, _) in &all {
            match shown.as_ref().and_then(|m| m.get(*name)) {
                Some(value) => out.extend([1.0, *value]),
                None => out.extend([0.0, 0.0]),
            }
        }
        out
    })
}

/// `ViewportPointRules.point` (see the module notes for the layout).
#[allow(clippy::too_many_arguments)]
pub fn flows_viewport_point(
    names: &str,
    scores: &[f64],
    count: i64,
    flood_realized: f64,
    convective: f64,
    precip_risk: f64,
    alert_family: &str,
    has_alert: bool,
    alert_severity: f64,
    closed: f64,
) -> Vec<f64> {
    contain(Vec::new(), || {
        let Some(shown) = named(names, scores, count) else {
            return Vec::new();
        };
        let alert = has_alert.then_some(alert_family);
        let p = vp::point(
            &shown,
            flood_realized,
            convective,
            precip_risk,
            alert,
            alert_severity,
            closed,
        );
        let (kind, source, index) = match &p.icon {
            vp::Icon::Family(family) => {
                let found = shown
                    .iter()
                    .position(|(name, _)| name == family)
                    .map(|i| (0.0, i))
                    .or_else(|| {
                        vp::BAND_FAMILIES
                            .iter()
                            .position(|name| name == family)
                            .map(|i| (1.0, i))
                    })
                    .or_else(|| (alert == Some(family.as_str())).then_some((2.0, 0)))
                    .or_else(|| (family == "closure").then_some((3.0, 0)));
                match found {
                    Some((source, i)) => (0.0, source, i as f64),
                    // Not reachable: the name is always one of those four.
                    None => return Vec::new(),
                }
            }
            vp::Icon::RainChance => (1.0, 0.0, 0.0),
            vp::Icon::Forecast => (2.0, 0.0, 0.0),
            vp::Icon::Alert => (3.0, 0.0, 0.0),
            vp::Icon::Closure => (4.0, 0.0, 0.0),
        };
        let present = |v: Option<&f64>| match v {
            Some(value) => [1.0, *value],
            None => [0.0, 0.0],
        };
        let mut out = Vec::with_capacity(9 + vp::BAND_FAMILIES.len());
        out.extend([kind, source, index]);
        out.extend(present(p.families.get("closure")));
        out.extend(present(p.band_input.get("closure")));
        out.extend(present(alert.and_then(|family| p.band_input.get(family))));
        out.extend(
            vp::BAND_FAMILIES
                .iter()
                .map(|name| p.band_input.get(*name).copied().unwrap_or(0.0)),
        );
        out
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const QUIET: [f64; 11] = [0.0; 11];

    #[test]
    fn the_display_answers_per_name_sent() {
        // One forecast family, then the live names Swift adds.
        let names = "wind\u{1f}fire\u{1f}seismic\u{1f}qpf_flood\u{1f}air";
        let scores = [0.3, 0.0, 0.0, 0.0, 0.0];
        let mut live = QUIET;
        live[0] = 0.7;
        live[9] = 0.2;
        let out = flows_viewport_display(0.0, names, &scores, 5, 1, &live, false);
        assert_eq!(out, [1.0, 1.0, 0.3, 1.0, 0.7, 1.0, 0.0, 1.0, 0.0, 0.0, 0.0]);
        // With an air reading, air is present.
        let out = flows_viewport_display(0.0, names, &scores, 5, 1, &live, true);
        assert_eq!(&out[9..], [1.0, 0.2]);
        // A quiet point does not show.
        let out =
            flows_viewport_display(0.0, names, &[0.2, 0.0, 0.0, 0.0, 0.0], 5, 1, &QUIET, false);
        assert_eq!(out[0], 0.0);
    }

    #[test]
    fn a_bad_call_answers_an_empty_column() {
        assert!(flows_viewport_display(0.9, "wind", &[0.3], 2, 1, &QUIET, false).is_empty());
        assert!(flows_viewport_display(0.9, "wind", &[0.3], 1, 2, &QUIET, false).is_empty());
        assert!(flows_viewport_display(0.9, "wind", &[0.3], 1, 1, &[0.0; 3], false).is_empty());
        assert!(flows_viewport_display(0.9, "wind", &[0.3], -1, 0, &QUIET, false).is_empty());
        assert!(
            flows_viewport_point("wind", &[0.3], 2, 0.0, 0.0, 0.0, "-", false, 0.0, 0.0).is_empty()
        );
    }

    #[test]
    fn no_names_cross_as_a_count_of_zero() {
        let out = flows_viewport_display(0.25, "-", &[0.0], 0, 0, &QUIET, false);
        assert_eq!(out, [1.0]);
        let out = flows_viewport_point("-", &[0.0], 0, 0.0, 0.0, 0.0, "-", false, 0.0, 0.0);
        assert_eq!(out.len(), 24);
        // Nothing elevated: the forecast names it.
        assert_eq!(&out[..3], [2.0, 0.0, 0.0]);
    }

    #[test]
    fn the_point_names_its_family_by_where_it_was_sent() {
        let band: Vec<&str> = vp::BAND_FAMILIES.to_vec();
        assert_eq!(
            flows_viewport_band_names()
                .split('\u{1f}')
                .collect::<Vec<_>>(),
            band
        );
        // Wind leads the display: source 0, index 1.
        let out = flows_viewport_point(
            "heat\u{1f}wind",
            &[0.1, 0.9],
            2,
            0.0,
            0.0,
            0.4,
            "-",
            false,
            0.0,
            0.0,
        );
        assert_eq!(&out[..3], [0.0, 0.0, 1.0]);
        assert_eq!(&out[3..9], [0.0; 6]);
        assert_eq!(out[9 + 8], 0.9, "wind in the band");
        assert_eq!(out[9 + 13], 0.4, "precip in the band");
        // The gauges at Yellow take the name from wind: a band family.
        let out = flows_viewport_point(
            "heat\u{1f}wind",
            &[0.1, 0.9],
            2,
            0.7,
            0.0,
            0.0,
            "-",
            false,
            0.0,
            0.0,
        );
        assert_eq!(&out[..3], [0.0, 1.0, 1.0]);
        // A closure under its own floor but at Yellow: "closure".
        let out = flows_viewport_point("wind", &[0.9], 1, 0.0, 0.0, 0.0, "-", false, 0.0, 0.75);
        assert_eq!(&out[..7], [0.0, 3.0, 0.0, 1.0, 0.75, 1.0, 0.75]);
        // A warning names it, and its score crosses.
        let out = flows_viewport_point("wind", &[0.9], 1, 0.0, 0.0, 0.0, "storm", true, 0.8, 0.9);
        assert_eq!(&out[..9], [3.0, 0.0, 0.0, 1.0, 0.9, 1.0, 0.9, 1.0, 0.8]);
        // An alert filed under "closure" with no closure reported: in the band only.
        let out = flows_viewport_point("wind", &[0.9], 1, 0.0, 0.0, 0.0, "closure", true, 0.3, 0.0);
        assert_eq!(&out[3..9], [0.0, 0.0, 1.0, 0.3, 1.0, 0.3]);
    }
}
