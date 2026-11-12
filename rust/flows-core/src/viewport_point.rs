// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! What the map's sweep makes of one point: which hazard families show
//! there, what the risk band is fed, and what names the badge. Swift's
//! `ViewportPointRules` at the commit that gathered the rules out of the map
//! view. Pinned by
//! `flows-bridge/tests/fixtures/swift_viewport_point_oracle.tsv`.
//!
//! Families are kept in name order, so every answer is a function of the
//! readings and never of the order they arrived in.

use crate::families::{dominant_family, is_primary};
use crate::risk::RISK_YELLOW_MIN;
use std::collections::BTreeMap;

/// A point shows from this score up, on the blended forecast or any family.
pub const SHOW_FLOOR: f64 = 0.25;
/// A flood family below this on the gauges alone is only "it may rain".
pub const FLOOD_NAME_FLOOR: f64 = 0.45;
/// An alert names the badge from this severity up.
pub const ALERT_NAME_FLOOR: f64 = 0.6;
/// A closure names the badge from this score up.
pub const CLOSURE_NAME_FLOOR: f64 = 0.8;
/// A family names an area from this score up.
const DOMINANT_FLOOR: f64 = 0.45;

/// The band's own families, in the order the bridge returns them.
pub const BAND_FAMILIES: [&str; 15] = [
    "fire",
    "qpf_flood",
    "convective",
    "seismic",
    "tropical",
    "tsunami",
    "volcanic",
    "avalanche",
    "wind",
    "heat",
    "cold",
    "air",
    "radiation",
    "precip",
    "winter",
];

/// The live readings at one point, each already scored 0 to 1.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Live {
    pub fire: f64,
    pub seismic: f64,
    pub volcanic: f64,
    pub avalanche: f64,
    pub tropical: f64,
    pub tsunami: f64,
    /// The severe-storm outlook.
    pub convective: f64,
    pub space_radiation: f64,
    /// The river gauges alone.
    pub flood_realized: f64,
    /// Air quality; `None` when there is no reading.
    pub air: Option<f64>,
    pub uv: f64,
}

/// Swift's `max(x, y)`: `y` unless `y >= x` fails, so a not-a-number second
/// operand loses and a not-a-number first operand stays.
fn swift_max(x: f64, y: f64) -> f64 {
    if y >= x {
        y
    } else {
        x
    }
}

/// `ViewportPointRules.displayFamilies`: the forecast's families with the
/// live readings laid over them, or `None` when neither the blended `score`
/// nor any one family reaches [`SHOW_FLOOR`].
///
/// A name given twice in `forecast` keeps its last score. Deterministic;
/// panics: none.
#[must_use]
pub fn display_families(
    score: f64,
    forecast: &[(&str, f64)],
    live: &Live,
) -> Option<BTreeMap<String, f64>> {
    let mut families: BTreeMap<String, f64> = forecast
        .iter()
        .map(|(name, value)| ((*name).to_string(), *value))
        .collect();
    let existing = |m: &BTreeMap<String, f64>, k: &str| m.get(k).copied().unwrap_or(0.0);
    families.insert("fire".to_string(), live.fire);
    families.insert("seismic".to_string(), live.seismic);
    let flood = swift_max(existing(&families, "qpf_flood"), live.flood_realized);
    families.insert("qpf_flood".to_string(), flood);
    if let Some(air) = live.air {
        families.insert("air".to_string(), air);
    }
    // Space weather and UV share a family.
    let radiation = swift_max(live.space_radiation, live.uv);
    if radiation > 0.0 {
        families.insert("radiation".to_string(), radiation);
    }
    for (name, value) in [
        ("volcanic", live.volcanic),
        ("avalanche", live.avalanche),
        ("tropical", live.tropical),
        ("tsunami", live.tsunami),
    ] {
        if value > 0.0 {
            families.insert(name.to_string(), value);
        }
    }
    if live.convective > 0.0 {
        let storms = swift_max(existing(&families, "convective"), live.convective);
        families.insert("convective".to_string(), storms);
    }
    (score >= SHOW_FLOOR || families.values().any(|v| *v >= SHOW_FLOOR)).then_some(families)
}

/// What names the badge.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Icon {
    /// This family.
    Family(String),
    /// The flood family won on rain chance alone.
    RainChance,
    /// No family is elevated: the forecast names it.
    Forecast,
    /// The alert in force here.
    Alert,
    /// The road is closed.
    Closure,
}

/// A point that shows.
#[derive(Debug, Clone, PartialEq)]
pub struct Point {
    /// The display families, with a closure added.
    pub families: BTreeMap<String, f64>,
    /// What the risk band is fed.
    pub band_input: BTreeMap<String, f64>,
    pub icon: Icon,
}

/// `ViewportPointRules.point`: the band's input and the badge's name.
///
/// The worst display family names the badge (the blended "environmental"
/// composite never does); a warning for a primary family at
/// [`ALERT_NAME_FLOOR`] or more names it over that; a closure at
/// [`CLOSURE_NAME_FLOOR`] or more names it unless the alert did; and when
/// the name came from a predictor, a realized primary at Yellow or worse
/// names it instead. Equal primaries go to the lower family name.
///
/// Deterministic; panics: none.
#[must_use]
pub fn point(
    shown: &[(&str, f64)],
    flood_realized: f64,
    convective: f64,
    precip_risk: f64,
    alert_family: Option<&str>,
    alert_severity: f64,
    closed: f64,
) -> Point {
    let mut families: BTreeMap<String, f64> = shown
        .iter()
        .map(|(name, value)| ((*name).to_string(), *value))
        .collect();
    let named: Vec<(&str, f64)> = families
        .iter()
        .filter(|(name, _)| name.as_str() != "environmental")
        .map(|(name, value)| (name.as_str(), *value))
        .collect();
    let top = dominant_family(&named, DOMINANT_FLOOR).map(str::to_string);
    let mut icon = match top.as_deref() {
        Some("qpf_flood") if flood_realized < FLOOD_NAME_FLOOR => Icon::RainChance,
        Some(family) => Icon::Family(family.to_string()),
        None => Icon::Forecast,
    };
    let named_by_alert =
        alert_family.is_some_and(|family| alert_severity >= ALERT_NAME_FLOOR && is_primary(family));
    if named_by_alert {
        icon = Icon::Alert;
    }
    let of = |k: &str| families.get(k).copied().unwrap_or(0.0);
    let mut band_input: BTreeMap<String, f64> = BAND_FAMILIES
        .iter()
        .map(|name| {
            let value = match *name {
                "qpf_flood" => flood_realized,
                "convective" => convective,
                "precip" => precip_risk,
                other => of(other),
            };
            ((*name).to_string(), value)
        })
        .collect();
    // A warning is a realized primary; a watch or advisory is a predictor.
    if let Some(family) = alert_family {
        let now = band_input.get(family).copied().unwrap_or(0.0);
        band_input.insert(family.to_string(), swift_max(now, alert_severity));
    }
    if closed > 0.0 {
        band_input.insert("closure".to_string(), closed);
        families.insert("closure".to_string(), closed);
        if closed >= CLOSURE_NAME_FLOOR && !named_by_alert {
            icon = Icon::Closure;
        }
    }
    let icon_is_primary = top.as_deref().is_some_and(is_primary);
    // In name order, a later primary replaces the worst only when strictly
    // worse: ties go to the lower name.
    let mut worst: Option<(&str, f64)> = None;
    for (name, value) in &band_input {
        if is_primary(name) && worst.is_none_or(|(_, best)| best < *value) {
            worst = Some((name.as_str(), *value));
        }
    }
    // `closed < floor`, as written: a not-a-number closure blocks this.
    if !named_by_alert && closed < CLOSURE_NAME_FLOOR && !icon_is_primary {
        if let Some((name, value)) = worst {
            if value >= RISK_YELLOW_MIN {
                icon = Icon::Family(name.to_string());
            }
        }
    }
    Point {
        families,
        band_input,
        icon,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn quiet() -> Live {
        Live::default()
    }

    #[test]
    fn a_quiet_point_does_not_show_and_one_family_is_enough() {
        assert_eq!(display_families(0.24, &[("wind", 0.2)], &quiet()), None);
        assert!(display_families(0.25, &[], &quiet()).is_some());
        let shown = display_families(0.0, &[("wind", 0.25)], &quiet()).unwrap();
        // Fire, quake and flood are always listed, even at zero.
        assert_eq!(
            shown.keys().map(String::as_str).collect::<Vec<_>>(),
            ["fire", "qpf_flood", "seismic", "wind"]
        );
    }

    #[test]
    fn live_readings_lie_over_the_forecast() {
        let live = Live {
            fire: 0.7,
            flood_realized: 0.3,
            convective: 0.5,
            space_radiation: 0.1,
            uv: 0.4,
            air: Some(0.0),
            ..quiet()
        };
        let shown = display_families(
            0.0,
            &[("fire", 0.1), ("qpf_flood", 0.6), ("convective", 0.2)],
            &live,
        )
        .unwrap();
        assert_eq!(shown["fire"], 0.7);
        assert_eq!(shown["qpf_flood"], 0.6);
        assert_eq!(shown["convective"], 0.5);
        assert_eq!(shown["radiation"], 0.4);
        assert_eq!(shown["air"], 0.0);
        assert!(!shown.contains_key("volcanic"));
    }

    #[test]
    fn rain_chance_alone_is_not_a_flood() {
        let p = point(&[("qpf_flood", 0.6)], 0.44, 0.0, 0.6, None, 0.0, 0.0);
        assert_eq!(p.icon, Icon::RainChance);
        let p = point(&[("qpf_flood", 0.6)], 0.45, 0.0, 0.6, None, 0.0, 0.0);
        assert_eq!(p.icon, Icon::Family("qpf_flood".to_string()));
        // The band is fed the gauges, not the rain chance.
        assert_eq!(p.band_input["qpf_flood"], 0.45);
        assert_eq!(p.band_input["precip"], 0.6);
    }

    #[test]
    fn nothing_elevated_leaves_the_name_to_the_forecast() {
        let p = point(
            &[("environmental", 0.9), ("wind", 0.3)],
            0.0,
            0.0,
            0.0,
            None,
            0.0,
            0.0,
        );
        assert_eq!(p.icon, Icon::Forecast);
        assert_eq!(p.band_input.len(), 15);
    }

    #[test]
    fn a_warning_names_the_badge_and_keeps_it_over_a_closure() {
        let shown = [("wind", 0.5)];
        let p = point(&shown, 0.0, 0.0, 0.0, Some("storm"), 0.6, 0.9);
        assert_eq!(p.icon, Icon::Alert);
        assert_eq!(p.band_input["storm"], 0.6);
        assert_eq!(p.band_input["closure"], 0.9);
        assert_eq!(p.families["closure"], 0.9);
        // Below the floor, or for a predictor family, the alert does not name it.
        let p = point(&shown, 0.0, 0.0, 0.0, Some("storm"), 0.59, 0.9);
        assert_eq!(p.icon, Icon::Closure);
        let p = point(&shown, 0.0, 0.0, 0.0, Some("wind"), 0.9, 0.5);
        assert_eq!(p.icon, Icon::Family("wind".to_string()));
        assert_eq!(p.band_input["wind"], 0.9);
    }

    #[test]
    fn a_realized_primary_names_the_badge_over_a_predictor() {
        // Wind leads the display; the gauges are at Yellow.
        let p = point(
            &[("wind", 0.9), ("qpf_flood", 0.7)],
            0.7,
            0.0,
            0.0,
            None,
            0.0,
            0.0,
        );
        assert_eq!(p.icon, Icon::Family("qpf_flood".to_string()));
        // Just under Yellow, the predictor keeps it.
        let p = point(
            &[("wind", 0.9), ("qpf_flood", 0.69)],
            0.69,
            0.0,
            0.0,
            None,
            0.0,
            0.0,
        );
        assert_eq!(p.icon, Icon::Family("wind".to_string()));
        // A primary that already names it is left alone.
        let p = point(
            &[("fire", 0.8), ("seismic", 0.95)],
            0.0,
            0.0,
            0.0,
            None,
            0.0,
            0.0,
        );
        assert_eq!(p.icon, Icon::Family("seismic".to_string()));
    }

    #[test]
    fn equal_primaries_go_to_the_lower_name() {
        let p = point(
            &[("wind", 0.99), ("tsunami", 0.8), ("fire", 0.8)],
            0.0,
            0.0,
            0.0,
            None,
            0.0,
            0.0,
        );
        // Wind led (a predictor), so the worst primary names it.
        assert_eq!(p.icon, Icon::Family("fire".to_string()));
    }
}
