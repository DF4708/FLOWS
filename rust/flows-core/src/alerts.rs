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
    // Another country's rain notice below the flood threshold, as the app
    // names it ("Freezing Rain Advisory" is ice, above).
    if e.contains("rain advisory") {
        return DisplayKind::Rain;
    }
    // No English rule knew it: Mexico and Costa Rica name theirs in Spanish.
    spanish_display_kind(&e)
}

/// Lowercase text with its Spanish accents taken off, so "Ciclón" and
/// "CICLON" and "ciclon" are one word.
fn fold_spanish(lowercase: &str) -> String {
    lowercase
        .chars()
        .map(|c| match c {
            'á' => 'a',
            'é' => 'e',
            'í' => 'i',
            'ó' => 'o',
            'ú' | 'ü' => 'u',
            'ñ' => 'n',
            other => other,
        })
        .collect()
}

/// [`display_kind`] for an event named in Spanish ("Aviso de lluvias",
/// "Aviso de Frente Frío"), asked only once every English rule has passed —
/// so no English name changes its icon. The kinds and their order are the
/// English table's. Each word must stand alone (or in its plural): "calor"
/// is heat, "caloric" is nothing. Rain has no English rule (US alerts name
/// the flood, not the rain) but is what "Aviso de lluvias" is about.
fn spanish_display_kind(lowercase: &str) -> DisplayKind {
    let e = fold_spanish(lowercase);
    let words: Vec<&str> = e
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .collect();
    let word = |stems: &[&str]| {
        words.iter().any(|w| {
            stems.iter().any(|s| {
                w.strip_prefix(s)
                    .is_some_and(|rest| matches!(rest, "" | "s" | "es"))
            })
        })
    };
    if word(&["huracan", "ciclon", "marejada"]) {
        return DisplayKind::Tropical;
    }
    if e.contains("tormenta de polvo") || e.contains("tormenta de arena") || word(&["tolvanera"]) {
        return DisplayKind::Dust;
    }
    if word(&["polvo"]) {
        return DisplayKind::Air;
    }
    if word(&["inundacion", "crecida", "desbordamiento"]) {
        return DisplayKind::Flood;
    }
    // "Nevada" alone is also a US state in an English name: the singular
    // counts as snowfall only beside another Spanish word.
    let spanish_beside = words.iter().any(|w| {
        matches!(
            *w,
            "aviso"
                | "alerta"
                | "advertencia"
                | "vigilancia"
                | "por"
                | "de"
                | "la"
                | "una"
                | "fuerte"
                | "intensa"
                | "caida"
        )
    });
    let snowfall = words.contains(&"nevadas") || (words.contains(&"nevada") && spanish_beside);
    if snowfall || word(&["nieve", "invernal"]) {
        return DisplayKind::Snow;
    }
    if word(&["helada", "hielo", "congelante"]) {
        return DisplayKind::Ice;
    }
    if word(&["tormenta", "severa", "severo"]) {
        return DisplayKind::Storm;
    }
    if word(&["calor"]) {
        return DisplayKind::Heat;
    }
    if word(&["frio"]) {
        return DisplayKind::Cold;
    }
    if word(&["viento"]) {
        return DisplayKind::Wind;
    }
    if word(&["incendio"]) {
        return DisplayKind::Fire;
    }
    if word(&["niebla", "neblina"]) {
        return DisplayKind::Fog;
    }
    if word(&["humo"]) || e.contains("calidad del aire") {
        return DisplayKind::Air;
    }
    if word(&["ceniza"]) {
        return DisplayKind::Volcanic;
    }
    if word(&["avalancha", "alud"]) {
        return DisplayKind::Avalanche;
    }
    if word(&["maremoto"]) {
        return DisplayKind::Tsunami;
    }
    if word(&["lluvia"]) {
        return DisplayKind::Rain;
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

/// How long each kind of event usually runs, in hours, first match wins
/// (so "flash flood" is read before "flood", "red flag" before "fire", a
/// watch before its warning).
///
/// Measured, not guessed: each figure is the middle (median) length, from
/// first issue to final end, of the official US events of that kind in the
/// Iowa Environmental Mesonet archive of National Weather Service watches,
/// warnings and advisories (public domain; read 2026-11-11). Years 2022 to
/// 2024, and 2020 to 2024 for the rare kinds (hurricane, tropical storm,
/// storm surge, snow squall, dust storm, extreme wind, red flag). The count
/// of events behind each figure is beside it. Wildfires are from the
/// national incident records instead (National Interagency Fire Center,
/// 2014 to 2026: from discovery to containment). Both are US only. A kind
/// with under twenty events on record is not measured from them: rows
/// marked "set by hand" say what there was.
pub const USUAL_EVENT_HOURS: &[(&[&str], f64)] = &[
    // Watches run shorter than the warnings that follow them.
    (&["hurricane watch", "typhoon watch"], 30.0), // 30.1 h, 65 events
    (&["tropical storm watch"], 21.0),             // 20.7 h, 197
    (&["storm surge watch"], 25.0),                // 25.1 h, 84
    (&["storm surge"], 48.0),                      // 48.0 h, 70
    // Hurricane warnings 42.1 h (57), tropical storm warnings 42.6 h (234).
    (&["hurricane", "typhoon", "tropical", "cyclone"], 42.0),
    (&["volcan", "ashfall"], 15.0), // ashfall advisories 2008-2024: 14.6 h, 23
    (&["flash flood watch"], 9.0),  // 9.0 h, 147
    (&["flash flood"], 3.0),        // 3.1 h, 12,457
    // Coastal 12.8 h (268), lakeshore 12.0 h (21).
    (&["coastal flood", "lakeshore flood"], 13.0),
    // Warnings, watches and advisories together, 2008-2024: 48 events, half
    // under 2.6 h, a quarter over 17.6 h. The three-quarter mark is used and
    // not the middle: waves keep coming for hours, and dropping a tsunami
    // alert early is the mistake that costs lives.
    (&["tsunami"], 18.0),
    (&["flood advisory"], 3.0), // 2.9 h, 27,311
    (&["flood watch"], 17.0),   // 16.6 h, 2,288
    // River flood warnings: 41.8 h, 8,805 (a tenth ran past 19 days). A
    // "Flood Warning" for an area rather than a river is shorter (6.0 h,
    // 3,838) under the same name; the river figure is used, as rivers are
    // the floods told "until further notice".
    (&["flood", "hydrologic"], 42.0),
    // Red flag warnings 8.0 h (5,474), fire weather watches 8.0 h (119):
    // the chance of fire is one burning day; a fire is days.
    (&["red flag", "fire weather"], 8.0),
    // Wildfires of 100 acres or more, discovery to containment: 71.5 h,
    // 14,146 fires. Size decides far more than anything else here: 36 h
    // under 1,000 acres, 170 h to 10,000, 740 h to 100,000. An evacuation
    // has no record of its own and is kept as long as the fire.
    (&["fire", "evacuation"], 72.0),
    (&["tornado watch"], 6.0),      // 6.0 h, 1,789
    (&["thunderstorm watch"], 5.6), // 5.6 h, 4,120
    (&["tornado"], 0.5),            // 0.5 h, 8,487
    // Severe thunderstorm warnings 0.7 h (63,498), snow squalls 0.7 h (1,145).
    (&["thunderstorm", "snow squall"], 0.7),
    // Special marine warnings 0.9 h (17,248), dust storms 1.1 h (510).
    (&["special marine", "dust storm"], 1.0),
    (&["extreme wind"], 2.0), // 2.0 h, 27
    // Statements drawn as an area on the map, eight weeks of 2024: 0.6 h in
    // the middle and nine in ten under 0.9 h (5,482). The longer figure is
    // used: a statement with no area drawn is the longer kind, and those
    // are not on record.
    (&["special weather statement", "short term"], 1.0),
    (&["blizzard"], 22.0),       // 21.8 h, 358
    (&["ice storm"], 20.0),      // 20.2 h, 83
    (&["lake effect"], 27.0),    // 27.0 h, 60
    (&["winter storm"], 27.0),   // 27.0 h, 2,113
    (&["winter weather"], 18.0), // 18.0 h, 6,308
    // Set by hand: the winter kinds the rows above do not name.
    (&["winter", "snow", "avalanche", "freezing rain"], 24.0),
    (&["wind chill"], 19.0), // 19.0 h, 293
    (&["cold"], 9.0),        // 9.0 h, 48 advisories (2 warnings: 12.8 h)
    // Extreme heat warnings 9.0 h (1,137), heat advisories 8.0 h (4,030):
    // told a day at a time, though a quarter of the warnings ran past 34 h.
    (&["heat"], 9.0),
    // Freeze warnings 8.0 h (1,653), frost advisories 7.0 h (1,778).
    (&["freeze", "frost"], 8.0),
    (&["fog"], 7.0),             // 6.9 h, 5,096
    (&["high surf"], 30.0),      // 30.1 h, 977
    (&["air stagnation"], 96.0), // 96.5 h, 55
    // Not in the warnings archive (no event code): read from the messages
    // themselves, 25 offices, 2023-2024: 24.2 h, 1,685 (fetch_air.sh).
    (&["air quality"], 24.0),
    // High wind warnings 14.0 h (1,859), wind advisories 12.0 h (5,778).
    (&["wind"], 13.0),
];

/// How much longer an event runs for each doubling of the counties or
/// forecast zones it names. Measured from the same records: across the
/// eighteen kinds with enough events at both ends, an event naming sixteen
/// or more zones ran 1.6 times as long as one naming a single zone (the
/// middle kind; from no longer at all for heat advisories to four times for
/// coastal floods), which is 0.15 a doubling over four doublings.
pub const UNKNOWN_END_REACH_STEP: f64 = 0.15;

/// The usual length of an event no row of [`USUAL_EVENT_HOURS`] names: the
/// flat 12 hours every alert with no end time was kept before 2026-11-11.
pub const UNKNOWN_END_DEFAULT_HOURS: f64 = 12.0;
/// The shortest and longest an alert with no end time is taken to run.
pub const UNKNOWN_END_MIN_HOURS: f64 = 0.5;
pub const UNKNOWN_END_MAX_HOURS: f64 = 168.0;
/// The share of its life an alert is kept past its message, however long
/// ago it began: an event still being told about has not ended.
pub const UNKNOWN_END_TAIL: f64 = 0.25;

/// How long, in hours from its start, an alert that gives no end time is
/// taken to run (owner, 2026-11-11: by how long such events last and how
/// severe this one is, not a flat 12 hours).
///
/// `hours = usual × severity × reach × certainty`, kept within
/// [`UNKNOWN_END_MIN_HOURS`]..=[`UNKNOWN_END_MAX_HOURS`]:
///
/// * `usual`: [`USUAL_EVENT_HOURS`] for the event's kind, the measured
///   middle length of such events.
/// * `severity`: `0.5 + severity_score` (CAP score 0..1), so Minor is about
///   the usual length and Extreme about one and a half times it. Checked
///   against the records, not fitted to them: warnings ran 1.2 to 1.5
///   times as long as the advisories of the same weather (winter storm 27 h
///   to 18 h, high wind 14 h to 12 h), and at Severe (about 1.4 times) the
///   answer lands near the length three in four past events stayed under
///   (winter storm 37 h against 40 h, hurricane 58 h against 51 h, flash
///   flood 4.1 h against 4.0 h). River floods spread wider than this: major
///   ones ran three times as long as minor ones (119 h to 38 h).
/// * `reach`: [`UNKNOWN_END_REACH_STEP`] more for each doubling of `zones`
///   (the counties or forecast zones named), up to 1.6 times at sixteen: a
///   fire across counties outlasts one in a single zone.
/// * `certainty`: the CAP word; 1.25 observed, 0.75 possible, 0.5 unlikely.
///   Set by hand: the archive does not record the word. A watch is told as
///   "possible", and has its own measured row besides.
#[must_use]
pub fn unknown_end_hours(event: &str, severity_score: f64, zones: u32, certainty: &str) -> f64 {
    unknown_end_hours_learned(event, severity_score, zones, certainty, 0, 0.0)
}

/// The name a kind of event is learned under: the first word of its row in
/// [`USUAL_EVENT_HOURS`], or "other" for an event no row names.
#[must_use]
pub fn usual_event_kind(event: &str) -> &'static str {
    let e = lower(event);
    USUAL_EVENT_HOURS
        .iter()
        .find(|(words, _)| any(&e, words))
        .and_then(|(words, _)| words.first().copied())
        .unwrap_or("other")
}

/// The measured usual length of this kind of event, before any learning.
#[must_use]
pub fn usual_event_hours(event: &str) -> f64 {
    let e = lower(event);
    USUAL_EVENT_HOURS
        .iter()
        .find(|(words, _)| any(&e, words))
        .map_or(UNKNOWN_END_DEFAULT_HOURS, |&(_, hours)| hours)
}

/// How many seen events the measured table counts as. With twenty events of
/// a kind seen on this device, the answer sits halfway (in ratio) between
/// the table and what the device saw; with sixty, three quarters of the way.
pub const LEARN_PRIOR_EVENTS: f64 = 20.0;
/// The most events of one kind that count: past this the table's share
/// stops shrinking, so the national record always keeps a say (a tenth).
pub const LEARN_MAX_EVENTS: u32 = 180;
/// Learning never takes a kind below half its measured length (an alert
/// dropped early is the unsafe side) or above three times it.
pub const LEARN_MIN_FACTOR: f64 = 0.5;
pub const LEARN_MAX_FACTOR: f64 = 3.0;
/// A seen length outside this, in hours, is a bad record, not an event.
pub const LEARN_SAMPLE_MIN_HOURS: f64 = 0.1;
pub const LEARN_SAMPLE_MAX_HOURS: f64 = 720.0;

/// Whether one seen event's length, in hours, may be learned from.
#[must_use]
pub fn length_sample_usable(hours: f64) -> bool {
    hours.is_finite() && (LEARN_SAMPLE_MIN_HOURS..=LEARN_SAMPLE_MAX_HOURS).contains(&hours)
}

/// The usual length of a kind once this device has seen `count` events of
/// it, whose lengths have the mean natural logarithm `mean_ln` (lengths of
/// weather events spread by ratio, so they are averaged as logarithms: the
/// geometric mean, which for such data sits at the median the table holds).
///
/// `ln(usual) = (K × ln(measured) + n × mean_ln) / (K + n)`, with
/// `K` = [`LEARN_PRIOR_EVENTS`] and `n` = `count` (at most
/// [`LEARN_MAX_EVENTS`]): the table is treated as `K` events already seen,
/// so each event the device adds moves the answer in proportion, a lot at
/// first and less as the count grows. Kept within [`LEARN_MIN_FACTOR`] and
/// [`LEARN_MAX_FACTOR`] of the measured length. Nothing seen, or a count or
/// mean that is not a number, is the measured length.
#[must_use]
pub fn learned_usual_hours(measured: f64, count: u32, mean_ln: f64) -> f64 {
    if count == 0 || !mean_ln.is_finite() || !measured.is_finite() || measured <= 0.0 {
        return measured;
    }
    let n = f64::from(count.min(LEARN_MAX_EVENTS));
    let ln = (LEARN_PRIOR_EVENTS * measured.ln() + n * mean_ln) / (LEARN_PRIOR_EVENTS + n);
    let learned = ln.exp();
    if !learned.is_finite() {
        return measured;
    }
    learned.clamp(measured * LEARN_MIN_FACTOR, measured * LEARN_MAX_FACTOR)
}

/// [`unknown_end_hours`] with what this device has learned about the kind:
/// `count` events seen, of mean log length `mean_ln`
/// ([`learned_usual_hours`]).
#[must_use]
pub fn unknown_end_hours_learned(
    event: &str,
    severity_score: f64,
    zones: u32,
    certainty: &str,
    count: u32,
    mean_ln: f64,
) -> f64 {
    let usual = learned_usual_hours(usual_event_hours(event), count, mean_ln);
    let severity = if severity_score.is_finite() {
        0.5 + severity_score.clamp(0.0, 1.0)
    } else {
        1.0
    };
    let reach = 1.0 + UNKNOWN_END_REACH_STEP * f64::from(zones.clamp(1, 16).ilog2());
    let c = lower(certainty);
    let sure: f64 = if c.contains("observed") {
        1.25
    } else if c.contains("unlikely") {
        0.5
    } else if c.contains("possible") {
        0.75
    } else {
        1.0
    };
    (usual * severity * reach * sure).clamp(UNKNOWN_END_MIN_HOURS, UNKNOWN_END_MAX_HOURS)
}

/// When an alert with no end time is taken to end, on the clock `onset` and
/// `message` are given in (seconds): its life from when it began, and never
/// less than [`UNKNOWN_END_TAIL`] of that life past the message's own lapse.
/// With no `onset` the life runs from the message.
#[must_use]
pub fn unknown_end(
    event: &str,
    severity_score: f64,
    zones: u32,
    certainty: &str,
    onset: Option<f64>,
    message: f64,
) -> f64 {
    unknown_end_learned(
        event,
        severity_score,
        zones,
        certainty,
        onset,
        message,
        0,
        0.0,
    )
}

/// [`unknown_end`] with what this device has learned about the kind
/// ([`unknown_end_hours_learned`]).
#[must_use]
#[allow(clippy::too_many_arguments)]
pub fn unknown_end_learned(
    event: &str,
    severity_score: f64,
    zones: u32,
    certainty: &str,
    onset: Option<f64>,
    message: f64,
    count: u32,
    mean_ln: f64,
) -> f64 {
    let life =
        unknown_end_hours_learned(event, severity_score, zones, certainty, count, mean_ln) * 3600.0;
    let tail = message + life * UNKNOWN_END_TAIL;
    match onset {
        Some(began) if began.is_finite() => tail.max(began + life),
        _ => tail.max(message + life),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_alert_with_no_end_runs_as_long_as_its_kind_and_severity() {
        let h = |event, severity, zones, certainty| {
            unknown_end_hours(event, severity, zones, certainty)
        };
        // The same severity, reach and certainty: the kind decides.
        let by_kind = |event| h(event, 0.72, 1, "Likely");
        // (A river in flood runs as long as a hurricane warning: 42 hours.)
        assert!(by_kind("Storm Surge Warning") > by_kind("Hurricane Warning"));
        assert!(by_kind("Hurricane Warning") >= by_kind("Flood Warning"));
        assert!(by_kind("Flood Warning") > by_kind("Winter Storm Warning"));
        assert!(by_kind("Winter Storm Warning") > by_kind("Winter Weather Advisory"));
        assert!(by_kind("Winter Weather Advisory") > by_kind("High Wind Warning"));
        assert!(by_kind("Winter Storm Warning") > by_kind("Flash Flood Warning"));
        assert!(by_kind("Flash Flood Warning") > by_kind("Special Weather Statement"));
        assert!(by_kind("Special Weather Statement") > by_kind("Severe Thunderstorm Warning"));
        assert!(by_kind("Severe Thunderstorm Warning") > by_kind("Tornado Warning"));
        // The measured lengths, each read by its own row.
        let usual = |event| h(event, 0.5, 1, "Likely");
        for (event, hours) in [
            ("Hurricane Warning", 42.0),
            ("Tropical Storm Warning", 42.0),
            ("Hurricane Watch", 30.0),
            ("Tropical Storm Watch", 21.0),
            ("Storm Surge Watch", 25.0),
            ("Storm Surge Warning", 48.0),
            ("Flash Flood Warning", 3.0),
            ("Flash Flood Watch", 9.0),
            ("Coastal Flood Warning", 13.0),
            ("Flood Advisory", 3.0),
            ("Flood Watch", 17.0),
            ("Flood Warning", 42.0),
            ("Tornado Watch", 6.0),
            ("Severe Thunderstorm Watch", 5.6),
            ("Tornado Warning", 0.5),
            ("Severe Thunderstorm Warning", 0.7),
            ("Snow Squall Warning", 0.7),
            ("Special Marine Warning", 1.0),
            ("Extreme Wind Warning", 2.0),
            ("Blizzard Warning", 22.0),
            ("Ice Storm Warning", 20.0),
            ("Lake Effect Snow Warning", 27.0),
            ("Winter Storm Warning", 27.0),
            ("Winter Storm Watch", 27.0),
            ("Winter Weather Advisory", 18.0),
            ("Avalanche Warning", 24.0),
            ("Wind Chill Warning", 19.0),
            ("Extreme Cold Warning", 9.0),
            ("Extreme Heat Warning", 9.0),
            ("Heat Advisory", 9.0),
            ("Freeze Warning", 8.0),
            ("Frost Advisory", 8.0),
            ("Dense Fog Advisory", 7.0),
            ("High Surf Advisory", 30.0),
            ("Air Stagnation Advisory", 96.0),
            ("Air Quality Alert", 24.0),
            ("High Wind Warning", 13.0),
            ("Wind Advisory", 13.0),
        ] {
            assert_eq!(usual(event), hours, "{event}");
        }
        // A fire outlasts the chance of one; "red flag" is not read as "fire".
        assert_eq!(by_kind("Red Flag Warning"), 8.0 * (0.5 + 0.72));
        assert_eq!(by_kind("Fire Weather Watch"), 8.0 * (0.5 + 0.72));
        assert_eq!(by_kind("Fire Warning"), 72.0 * (0.5 + 0.72));
        // An event nothing names keeps the old 12 hours as its usual length.
        assert_eq!(h("Civil Emergency Message", 0.5, 1, "Likely"), 12.0);
        // More severe runs longer.
        assert!(h("Flood Warning", 0.95, 1, "Likely") > h("Flood Warning", 0.45, 1, "Likely"));
        // Wider runs longer, 0.15 per doubling, up to 1.6 times.
        assert_eq!(h("Fire Warning", 0.5, 4, "Likely"), 72.0 * 1.3);
        assert_eq!(h("Fire Warning", 0.5, 16, "Likely"), 72.0 * 1.6);
        assert_eq!(h("Fire Warning", 0.5, 400, "Likely"), 72.0 * 1.6);
        assert_eq!(h("Fire Warning", 0.5, 0, "Likely"), 72.0);
        // Seen is longer than may be.
        assert_eq!(h("Fire Warning", 0.5, 1, "Observed"), 90.0);
        assert_eq!(h("Fire Warning", 0.5, 1, "Possible"), 54.0);
        assert_eq!(h("Fire Warning", 0.5, 1, "Unlikely"), 36.0);
        // A watch has its own measured length, shorter than its warning.
        assert_eq!(h("Hurricane Watch", 0.5, 1, "Possible"), 30.0 * 0.75);
        // Within half an hour and a week, whatever comes in.
        assert_eq!(h("Air Stagnation Advisory", 1.0, 16, "Observed"), 168.0);
        assert_eq!(h("Tornado Warning", 0.0, 1, "Unlikely"), 0.5);
        assert_eq!(h("Flood Warning", f64::NAN, 1, ""), 42.0);
    }

    #[test]
    fn the_usual_length_moves_in_proportion_to_what_the_device_has_seen() {
        let near = |a: f64, b: f64| (a - b).abs() < 1e-9 * b.max(1.0);
        // Nothing seen, or nothing usable: the measured table.
        assert_eq!(learned_usual_hours(27.0, 0, 3.0), 27.0);
        assert_eq!(learned_usual_hours(27.0, 5, f64::NAN), 27.0);
        assert_eq!(learned_usual_hours(27.0, 5, f64::INFINITY), 27.0);
        // Seeing what the table says changes nothing.
        assert!(near(learned_usual_hours(27.0, 40, 27.0_f64.ln()), 27.0));
        // Events of 54 hours against a table of 27: one event moves it a
        // twenty-first of the way (in ratio), twenty half way, sixty three
        // quarters.
        let seen = 54.0_f64.ln();
        let part = |n: f64| 27.0 * 2.0_f64.powf(n / (20.0 + n));
        assert!(near(learned_usual_hours(27.0, 1, seen), part(1.0)));
        assert!(near(learned_usual_hours(27.0, 20, seen), part(20.0)));
        assert!(near(learned_usual_hours(27.0, 60, seen), part(60.0)));
        assert!(learned_usual_hours(27.0, 1, seen) < learned_usual_hours(27.0, 2, seen));
        // The table always keeps a tenth of the say.
        assert_eq!(
            learned_usual_hours(27.0, 180, seen),
            learned_usual_hours(27.0, 1_000_000, seen)
        );
        assert!(learned_usual_hours(27.0, 1_000_000, seen) < 54.0);
        // Never under half the measured length, never over three times it.
        assert_eq!(learned_usual_hours(27.0, 180, 0.2_f64.ln()), 13.5);
        assert_eq!(learned_usual_hours(27.0, 180, 700.0_f64.ln()), 81.0);
        // A length is learned from only when it is a believable event.
        assert!(length_sample_usable(0.5) && length_sample_usable(720.0));
        assert!(!length_sample_usable(0.05) && !length_sample_usable(721.0));
        assert!(!length_sample_usable(f64::NAN) && !length_sample_usable(-3.0));
        // Each kind is learned under its own name, and the answer follows.
        assert_eq!(usual_event_kind("Winter Storm Warning"), "winter storm");
        assert_eq!(usual_event_kind("Hurricane Watch"), "hurricane watch");
        assert_eq!(usual_event_kind("Flood Warning"), "flood");
        assert_eq!(usual_event_kind("Civil Emergency Message"), "other");
        assert_eq!(usual_event_hours("Winter Storm Warning"), 27.0);
        assert_eq!(usual_event_hours("Civil Emergency Message"), 12.0);
        let plain = unknown_end_hours("Winter Storm Warning", 0.5, 1, "Likely");
        let taught = unknown_end_hours_learned("Winter Storm Warning", 0.5, 1, "Likely", 20, seen);
        assert_eq!(plain, 27.0);
        assert!(near(taught, part(20.0)));
        let hour = 3600.0;
        let end = unknown_end_learned(
            "Winter Storm Warning",
            0.5,
            1,
            "Likely",
            Some(0.0),
            hour,
            20,
            seen,
        );
        assert!(near(end, part(20.0) * hour));
    }

    #[test]
    fn an_unknown_end_is_never_before_the_message_lapses() {
        let hour = 3600.0;
        // Just begun: the whole life from the start.
        let end = unknown_end("Fire Warning", 0.5, 1, "Likely", Some(0.0), hour);
        assert_eq!(end, 72.0 * hour);
        // Begun a week ago and still told about: a quarter of its life more.
        let end = unknown_end("Fire Warning", 0.5, 1, "Likely", Some(0.0), 200.0 * hour);
        assert_eq!(end, 218.0 * hour);
        // No start on record: the life runs from the message.
        let end = unknown_end("Fire Warning", 0.5, 1, "Likely", None, 10.0 * hour);
        assert_eq!(end, 82.0 * hour);
        let end = unknown_end(
            "Fire Warning",
            0.5,
            1,
            "Likely",
            Some(f64::NAN),
            10.0 * hour,
        );
        assert_eq!(end, 82.0 * hour);
        // A short statement no longer lingers half a day.
        let end = unknown_end(
            "Special Weather Statement",
            0.72,
            1,
            "Observed",
            Some(0.0),
            hour,
        );
        assert!(end > hour && end < 4.0 * hour, "{end}");
    }

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
    fn spanish_alert_names_get_the_icon_their_english_ones_do() {
        for (event, kind) in [
            ("Aviso de lluvias", DisplayKind::Rain),
            ("Aviso de Ciclón Tropical", DisplayKind::Tropical),
            ("AVISO DE CICLON", DisplayKind::Tropical),
            ("Aviso de Huracán", DisplayKind::Tropical),
            ("Aviso de Frente Frío", DisplayKind::Cold),
            ("Aviso de frente frio", DisplayKind::Cold),
            ("Alerta por inundación", DisplayKind::Flood),
            ("Inundaciones", DisplayKind::Flood),
            ("Aviso de tormenta", DisplayKind::Storm),
            ("Tormentas eléctricas", DisplayKind::Storm),
            ("Aviso de viento", DisplayKind::Wind),
            ("Vientos fuertes", DisplayKind::Wind),
            ("Banco de niebla", DisplayKind::Fog),
            ("Onda de calor", DisplayKind::Heat),
            ("Aviso de nevada", DisplayKind::Snow),
            ("Nevadas", DisplayKind::Snow),
            ("Aviso de heladas", DisplayKind::Ice),
            ("Tormenta de polvo", DisplayKind::Dust),
            ("Incendio forestal", DisplayKind::Fire),
            ("Caída de ceniza", DisplayKind::Volcanic),
            // More than one word: the English order decides, as in English.
            ("Aviso de lluvias por Ciclón", DisplayKind::Tropical),
            ("Lluvias e inundaciones", DisplayKind::Flood),
        ] {
            assert_eq!(display_kind(event), kind, "{event}");
        }
    }

    #[test]
    fn the_state_of_nevada_is_not_snowfall() {
        assert_ne!(display_kind("Nevada Emergency Message"), DisplayKind::Snow);
        assert_eq!(display_kind("Nevada fuerte"), DisplayKind::Snow);
    }

    #[test]
    fn english_names_keep_the_icons_they_had() {
        // What each English rule answered before the Spanish words came,
        // and names no rule knows — Spanish words inside English ones
        // ("caloric", "humor", "frio" in "Frion") are not Spanish words.
        for (event, kind) in [
            ("Tornado Warning", DisplayKind::Tornado),
            ("Tropical Storm Warning", DisplayKind::Tropical),
            ("Storm Surge Watch", DisplayKind::Tropical),
            ("Flash Flood Warning", DisplayKind::Flood),
            ("Winter Storm Warning", DisplayKind::Snow),
            ("Freezing Rain Advisory", DisplayKind::Ice),
            ("Severe Thunderstorm Warning", DisplayKind::Storm),
            ("Excessive Heat Warning", DisplayKind::Heat),
            ("Wind Chill Advisory", DisplayKind::Cold),
            ("High Wind Warning", DisplayKind::Wind),
            ("Red Flag Warning", DisplayKind::Fire),
            ("Dense Fog Advisory", DisplayKind::Fog),
            ("Air Quality Alert", DisplayKind::Air),
            ("Ashfall Warning", DisplayKind::Volcanic),
            ("Avalanche Warning", DisplayKind::Avalanche),
            ("Tsunami Warning", DisplayKind::Tsunami),
            ("Heavy Rain Warning", DisplayKind::Generic),
            ("Rain Advisory", DisplayKind::Rain),
            ("Freezing Rain Advisory", DisplayKind::Ice),
            ("Child Abduction Emergency", DisplayKind::Generic),
            ("Caloric Humor Prelude Alert", DisplayKind::Generic),
            ("Civil Emergency Message", DisplayKind::Generic),
            ("", DisplayKind::Generic),
        ] {
            assert_eq!(display_kind(event), kind, "{event}");
        }
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
