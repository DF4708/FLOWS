// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! One classifier for alert event names — the threat, how to draw it, where
//! to shelter from it, and how it ranks against every other alert.
//!
//! The app used to classify the same NWS event name three ways in three
//! files: a display table in `HazardStyle`, a shelter table in
//! `ShelterPolicy`, and life-safety and lookout keyword lists in
//! `ImminentAlerts`, beside the band family in [`crate::families`]. They had
//! drifted: a Red Flag Warning — fire *weather*, a predictor on the band side
//! — was on the life-safety list and commanded "shelter now" like a tornado;
//! a Tornado Emergency, the most extreme tornado product, was not on that
//! list at all; a Dust Storm Warning drew an air-quality icon while banding
//! as a realized storm. The owner's rule is that an alert is specific to the
//! threat posed, no alert spams the driver, and the most immediate risk to
//! life takes precedence. Every table now lives here, and the frozen oracle
//! (`flows-bridge/tests/fixtures/swift_alerts_oracle.tsv`) pins each output
//! to what the Swift tables said, with the deliberate changes allow-listed.
//!
//! # Text matching
//!
//! Every rule lowercases the event and tests substrings, in a fixed order, as
//! the Swift did. Rust compares bytes; Swift compares grapheme clusters. The
//! two differ only for combining marks on ASCII letters, which no alert feed
//! produces; the oracle records that shape and the allow-list names it.

use crate::families::{alert_family, is_primary};
use crate::risk::{risk_band, RiskBand, RISK_GREEN_MIN};

/// The icon a driver sees for an alert. Names are the app's `HazardKind`
/// names, and [`DISPLAY_KIND_NAMES`] is indexed by `DisplayKind as usize`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum DisplayKind {
    Generic = 0,
    Tornado,
    Storm,
    Flood,
    Snow,
    Ice,
    Heat,
    Cold,
    Wind,
    Fire,
    Tropical,
    Fog,
    Dust,
    Air,
    Volcanic,
    Avalanche,
    Tsunami,
    /// Precipitation chance: what a flood family draws before any gauge
    /// confirms water on the road.
    Rain,
    /// A DOT-reported closure — proof the road is blocked.
    Closure,
    Radiation,
    Seismic,
}

/// `HazardKind.name` for each [`DisplayKind`], in discriminant order.
pub const DISPLAY_KIND_NAMES: &[&str] = &[
    "Hazard",
    "Tornado",
    "Storm",
    "Flood",
    "Snow",
    "Ice",
    "Heat",
    "Cold",
    "Wind",
    "Fire",
    "Tropical",
    "Fog",
    "Dust storm",
    "Air/Smoke",
    "Volcanic",
    "Avalanche",
    "Tsunami",
    "Rain chance",
    "Road closed",
    "Radiation/UV",
    "Seismic",
];

impl DisplayKind {
    #[must_use]
    pub fn name(self) -> &'static str {
        DISPLAY_KIND_NAMES[self as usize]
    }
}

/// Where to be when the alert reaches you.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ShelterKind {
    /// Stay in the vehicle: the hazard is the road, not the sky.
    InVehicle = 0,
    /// Any building beats a car.
    AnyBuilding,
    /// A sturdy building: the storm can take a roof or a car.
    SturdyBuilding,
    /// An official shelter: leave the area.
    OfficialShelter,
}

/// What the app should do about an alert about to be reached.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Action {
    Monitor = 0,
    RestArea,
    Shelter,
    Lookout,
}

/// The lowercase event, once, for every rule.
fn lower(event: &str) -> String {
    event.to_lowercase()
}

fn any(e: &str, needles: &[&str]) -> bool {
    needles.iter().any(|n| e.contains(n))
}

// ---- display ----

/// The icon for an event. Rules in the order the display table tested them:
/// a Dust Storm or Blowing Dust *Warning* is its own kind (the realized
/// whiteout); a plain dust advisory is air quality.
#[must_use]
pub fn display_kind(event: &str) -> DisplayKind {
    let e = lower(event);
    if e.contains("tornado") {
        return DisplayKind::Tornado;
    }
    if e.contains("hurricane") || e.contains("tropical") || e.contains("surge") {
        return DisplayKind::Tropical;
    }
    if e.contains("dust storm") || e.contains("blowing dust") {
        return DisplayKind::Dust;
    }
    if e.contains("dust") {
        return DisplayKind::Air;
    }
    if e.contains("extreme wind") {
        return DisplayKind::Tropical;
    }
    if e.contains("flood") {
        return DisplayKind::Flood;
    }
    if any(&e, &["blizzard", "snow", "winter"]) {
        return DisplayKind::Snow;
    }
    if any(&e, &["ice", "freezing", "frost"]) {
        return DisplayKind::Ice;
    }
    if any(&e, &["thunder", "severe", "storm", "special weather"]) {
        return DisplayKind::Storm;
    }
    if e.contains("heat") {
        return DisplayKind::Heat;
    }
    if e.contains("chill") || e.contains("cold") {
        return DisplayKind::Cold;
    }
    if e.contains("wind") {
        return DisplayKind::Wind;
    }
    if e.contains("fire") || e.contains("red flag") {
        return DisplayKind::Fire;
    }
    if e.contains("fog") {
        return DisplayKind::Fog;
    }
    if e.contains("smoke") || e.contains("air quality") {
        return DisplayKind::Air;
    }
    if any(&e, &["volcan", "ashfall", "ash advisory"]) {
        return DisplayKind::Volcanic;
    }
    if e.contains("avalanche") {
        return DisplayKind::Avalanche;
    }
    if e.contains("tsunami") {
        return DisplayKind::Tsunami;
    }
    DisplayKind::Generic
}

/// The icon for a BAND FAMILY — the name the two-tier model gives a hazard —
/// when no alert names the area. Every primary and secondary family has one;
/// the families module's tests and this module's agree on the list, so a
/// family added there without an icon here fails a test rather than drawing
/// the generic triangle (which "storm", "flood" and "precip" did until 2026).
#[must_use]
pub fn display_kind_for_family(family: &str) -> DisplayKind {
    match family {
        "winter" => DisplayKind::Snow,
        "qpf_flood" | "flood" => DisplayKind::Flood,
        "convective" | "storm" => DisplayKind::Storm,
        "precip" => DisplayKind::Rain,
        "fire" => DisplayKind::Fire,
        "heat" => DisplayKind::Heat,
        "cold" => DisplayKind::Cold,
        "wind" => DisplayKind::Wind,
        "air" => DisplayKind::Air,
        "radiation" => DisplayKind::Radiation,
        "seismic" => DisplayKind::Seismic,
        "tropical" => DisplayKind::Tropical,
        "volcanic" => DisplayKind::Volcanic,
        "avalanche" => DisplayKind::Avalanche,
        "tsunami" => DisplayKind::Tsunami,
        "closure" => DisplayKind::Closure,
        _ => DisplayKind::Generic,
    }
}

// ---- shelter ----

/// Leave the area: the hazard is not survivable in place.
pub const EVACUATION_HAZARDS: &[&str] = &[
    "evacuation",
    "wildfire",
    "fire warning",
    "radiological",
    "nuclear",
    "hazardous materials",
    "flash flood emergency",
    "dam failure",
];

/// The sky can take a roof or a car: a sturdy building, or an official
/// shelter for the warning.
pub const STRUCTURAL_HAZARDS: &[&str] = &[
    "tornado",
    "hurricane",
    "typhoon",
    "tropical storm",
    "extreme wind",
    "derecho",
    "tsunami",
];

/// The road is the hazard: the vehicle, pulled over, is the shelter.
pub const DRIVING_HAZARDS: &[&str] = &[
    "dense fog",
    "freezing fog",
    "hydroplan",
    "heavy rain",
    "downpour",
    "blowing dust",
    "dust storm",
    "blowing snow",
    "whiteout",
    "lake effect",
    "black ice",
    "ice storm",
    "winter weather",
];

/// Severity at or above which a storm or flood alert asks for a sturdy
/// building rather than any building or the vehicle, and below which a
/// structural *watch* asks for a sturdy building rather than a shelter.
pub const SHELTER_SEVERITY_CUT: f64 = 0.8;

/// Where to shelter from `event` at CAP `severity_score` (0..1).
#[must_use]
pub fn shelter_kind(event: &str, severity_score: f64) -> ShelterKind {
    let e = lower(event);
    if any(&e, EVACUATION_HAZARDS) {
        return ShelterKind::OfficialShelter;
    }
    if any(&e, STRUCTURAL_HAZARDS) {
        return if e.contains("watch") && severity_score < SHELTER_SEVERITY_CUT {
            ShelterKind::SturdyBuilding
        } else {
            ShelterKind::OfficialShelter
        };
    }
    if any(&e, DRIVING_HAZARDS) {
        return ShelterKind::InVehicle;
    }
    let strong = severity_score >= SHELTER_SEVERITY_CUT;
    if e.contains("thunderstorm") || e.contains("severe weather") {
        return if strong {
            ShelterKind::SturdyBuilding
        } else {
            ShelterKind::AnyBuilding
        };
    }
    if e.contains("flood") {
        return if strong {
            ShelterKind::SturdyBuilding
        } else {
            ShelterKind::InVehicle
        };
    }
    if e.contains("hail") || e.contains("lightning") {
        return ShelterKind::AnyBuilding;
    }
    if strong {
        ShelterKind::SturdyBuilding
    } else {
        ShelterKind::AnyBuilding
    }
}

// ---- life safety, lookout, action, rank ----

/// Events that are an immediate risk to the driver's life: shelter now.
///
/// Deliberately NOT here, though the Swift list had it: "red flag warning".
/// It is fire *weather* — hot, dry, windy — and a predictor on the band side;
/// telling a driver to shelter from a forecast is the spam the owner's rule
/// forbids. Deliberately ADDED: "tornado emergency", the highest tornado
/// product, which the Swift list missed because it looked only for
/// "tornado warning".
pub const LIFE_SAFETY_KEYWORDS: &[&str] = &[
    "tornado warning",
    "tornado emergency",
    "hurricane warning",
    "typhoon warning",
    "extreme wind warning",
    "fire warning",
    "flash flood emergency",
    "tsunami warning",
    "radiological",
    "nuclear",
    "hazardous materials",
    "shelter in place",
    "civil danger",
    "evacuation",
    "child abduction",
    "amber alert",
    "blue alert",
    "silver alert",
    "law enforcement warning",
    "civil emergency",
];

/// Events that ask the driver to watch for someone, not to protect
/// themselves. A lookout never outranks a threat to the driver's own life.
pub const LOOKOUT_KEYWORDS: &[&str] = &[
    "child abduction",
    "amber alert",
    "blue alert",
    "silver alert",
    "endangered",
    "missing person",
    "law enforcement warning",
];

#[must_use]
pub fn is_life_safety(event: &str) -> bool {
    any(&lower(event), LIFE_SAFETY_KEYWORDS)
}

#[must_use]
pub fn is_lookout(event: &str) -> bool {
    any(&lower(event), LOOKOUT_KEYWORDS)
}

/// Severity at or above which a short-lived alert earns a rest-area stop.
pub const UPPER_YELLOW_MIN: f64 = 0.60;
/// An alert expiring within this many seconds is one you can wait out.
pub const TRANSIENT_HORIZON_SECONDS: f64 = 2.0 * 3600.0;

/// What to do about an alert about to be reached.
///
/// `seconds_until_expiry` is `expires − now`, or `None` for an alert with no
/// expiry. A lookout is a lookout whatever its severity; a life-safety event
/// or a Red-banded severity is shelter; a strong alert that expires within
/// the horizon is a rest-area wait; everything else is monitored.
#[must_use]
pub fn action(event: &str, severity_score: f64, seconds_until_expiry: Option<f64>) -> Action {
    let e = lower(event);
    if any(&e, LOOKOUT_KEYWORDS) {
        return Action::Lookout;
    }
    if any(&e, LIFE_SAFETY_KEYWORDS) || risk_band(severity_score) == RiskBand::Red {
        return Action::Shelter;
    }
    if severity_score >= UPPER_YELLOW_MIN {
        if let Some(s) = seconds_until_expiry {
            if s > 0.0 && s <= TRANSIENT_HORIZON_SECONDS {
                return Action::RestArea;
            }
        }
    }
    Action::Monitor
}

/// How an alert ranks against every other alert the driver could be shown.
///
/// The owner's rule: the most immediate risk to the driver's life takes
/// precedence, and no alert spams. So:
///
/// | rank | meaning |
/// |---|---|
/// | 3 | an immediate risk to life ([`is_life_safety`]) |
/// | 2 | a realized primary (the band family is Red-capable) or a Red CAP severity |
/// | 1 | any other classified predictor, or a severity at or above the green cut |
/// | 0 | a lookout, or an event nothing classifies |
///
/// A lookout ranks 0 even when its keywords are also on the life-safety
/// list: an AMBER Alert asks the driver to watch for a car, not to save
/// their own life, and must never displace a tornado warning.
#[must_use]
pub fn threat_rank(event: &str, severity_score: f64) -> u8 {
    let e = lower(event);
    if any(&e, LOOKOUT_KEYWORDS) {
        return 0;
    }
    if any(&e, LIFE_SAFETY_KEYWORDS) {
        return 3;
    }
    let family = alert_family(event);
    if family.is_some_and(is_primary) || risk_band(severity_score) == RiskBand::Red {
        return 2;
    }
    if family.is_some() || (severity_score.is_finite() && severity_score >= RISK_GREEN_MIN) {
        return 1;
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_names_match_the_enum_one_to_one() {
        assert_eq!(DISPLAY_KIND_NAMES.len(), DisplayKind::Seismic as usize + 1);
        assert_eq!(DisplayKind::Dust.name(), "Dust storm");
        assert_eq!(DisplayKind::Generic.name(), "Hazard");
    }

    #[test]
    fn every_band_family_has_an_icon() {
        use crate::families::{PRIMARY_FAMILIES, SECONDARY_FAMILIES};
        for f in PRIMARY_FAMILIES.iter().chain(SECONDARY_FAMILIES) {
            assert_ne!(display_kind_for_family(f), DisplayKind::Generic, "{f}");
        }
        assert_eq!(display_kind_for_family("precip"), DisplayKind::Rain);
        assert_eq!(display_kind_for_family("storm"), DisplayKind::Storm);
        assert_eq!(
            display_kind_for_family("not-a-family"),
            DisplayKind::Generic
        );
    }

    #[test]
    fn a_dust_storm_warning_is_its_own_kind_and_a_dust_advisory_is_air() {
        assert_eq!(display_kind("Dust Storm Warning"), DisplayKind::Dust);
        assert_eq!(display_kind("Blowing Dust Warning"), DisplayKind::Dust);
        assert_eq!(display_kind("Dust Advisory"), DisplayKind::Air);
        // and the band side still calls the warning a realized storm
        assert_eq!(alert_family("Dust Storm Warning"), Some("storm"));
    }

    #[test]
    fn fire_weather_is_not_a_reason_to_shelter() {
        // The deliberate change: a Red Flag Warning is a predictor everywhere now.
        assert!(!is_life_safety("Red Flag Warning"));
        assert_eq!(
            action("Red Flag Warning", 0.72, Some(3600.0)),
            Action::RestArea
        );
        assert_eq!(threat_rank("Red Flag Warning", 0.72), 1);
        // while an actual fire still is
        assert!(is_life_safety("Fire Warning"));
        assert_eq!(action("Fire Warning", 0.3, None), Action::Shelter);
        assert_eq!(threat_rank("Fire Warning", 0.3), 3);
    }

    #[test]
    fn a_tornado_emergency_is_life_safety() {
        assert!(is_life_safety("Tornado Emergency"));
        assert_eq!(threat_rank("Tornado Emergency", 0.5), 3);
        assert_eq!(display_kind("Tornado Emergency"), DisplayKind::Tornado);
    }

    #[test]
    fn the_most_immediate_risk_to_life_outranks_everything() {
        // A tornado warning with a modest CAP severity beats a flood
        // advisory with an extreme one, and beats every lookout.
        assert!(threat_rank("Tornado Warning", 0.72) > threat_rank("Flood Advisory", 0.95));
        assert!(threat_rank("Tornado Warning", 0.30) > threat_rank("AMBER Alert", 0.95));
        // a realized primary outranks a predictor
        assert!(threat_rank("Flash Flood Warning", 0.72) > threat_rank("Wind Advisory", 0.72));
        // a lookout ranks lowest even with life-safety keywords
        assert_eq!(threat_rank("Law Enforcement Warning", 0.95), 0);
        assert_eq!(
            action("Law Enforcement Warning", 0.95, None),
            Action::Lookout
        );
    }

    #[test]
    fn shelter_follows_the_tables_in_order() {
        assert_eq!(
            shelter_kind("Flash Flood Emergency", 0.3),
            ShelterKind::OfficialShelter
        );
        assert_eq!(
            shelter_kind("Tornado Watch", 0.7),
            ShelterKind::SturdyBuilding
        );
        assert_eq!(
            shelter_kind("Tornado Watch", 0.9),
            ShelterKind::OfficialShelter
        );
        assert_eq!(
            shelter_kind("Tornado Warning", 0.3),
            ShelterKind::OfficialShelter
        );
        assert_eq!(
            shelter_kind("Dust Storm Warning", 0.95),
            ShelterKind::InVehicle
        );
        assert_eq!(
            shelter_kind("Severe Thunderstorm Warning", 0.72),
            ShelterKind::AnyBuilding
        );
        assert_eq!(
            shelter_kind("Severe Thunderstorm Warning", 0.88),
            ShelterKind::SturdyBuilding
        );
        assert_eq!(shelter_kind("Flood Warning", 0.72), ShelterKind::InVehicle);
        assert_eq!(
            shelter_kind("Frost Advisory", 0.3),
            ShelterKind::AnyBuilding
        );
    }

    #[test]
    fn a_transient_strong_alert_is_a_rest_area_wait() {
        assert_eq!(
            action("Wind Advisory", 0.72, Some(3600.0)),
            Action::RestArea
        );
        assert_eq!(action("Wind Advisory", 0.72, None), Action::Monitor);
        assert_eq!(
            action("Wind Advisory", 0.72, Some(3.0 * 3600.0)),
            Action::Monitor
        );
        assert_eq!(action("Wind Advisory", 0.72, Some(-5.0)), Action::Monitor); // already expired
        assert_eq!(action("Wind Advisory", 0.45, Some(3600.0)), Action::Monitor);
        assert_eq!(action("Frost Advisory", 0.95, None), Action::Shelter); // red severity alone
    }

    #[test]
    fn classification_is_case_insensitive_and_total() {
        assert_eq!(
            display_kind("TORNADO WARNING"),
            display_kind("tornado warning")
        );
        assert_eq!(display_kind(""), DisplayKind::Generic);
        assert_eq!(shelter_kind("", 0.0), ShelterKind::AnyBuilding);
        assert_eq!(threat_rank("", f64::NAN), 0);
        assert_eq!(action("", f64::NAN, None), Action::Monitor);
    }
}
