// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Alert text and dispatch audio: the reroute prompt's decision, the vehicle
//! and person descriptions pulled from red-alert text, and the call kind,
//! place and map-pin rules for transcribed dispatch — `EscalationPolicy.swift`,
//! `AlertEntityParser.swift` and `ScannerIncidents.swift`, the three wave-1
//! files that were never ported.
//!
//! | here | Swift |
//! |---|---|
//! | [`evaluate_escalation`], [`SUSTAINED_RISE`], [`DISMISS_MARGIN`], [`DEFERRED_BASELINE`] | `EscalationPolicy.evaluate` and its constants |
//! | [`describes_an_entity`], [`vehicle`], [`person`], [`COLOR_NAMES`], [`BRANDS`] | `AlertEntityParser` |
//! | [`kind_in_transcript`], [`place_phrase`], [`lifetime_seconds`], [`is_expired`], [`visible`], [`merged_keep`] | `ScannerIncidents` |
//!
//! # Fidelity
//!
//! Pinned by `flows-bridge/tests/fixtures/swift_alert_text_oracle.tsv`. Text
//! follows Swift's own rules ([`crate::swift_text`]): lowercasing, Foundation's
//! cluster-aligned search, the case-insensitive search in the en_US locale
//! (from the runtime's fold table), `split(separator:)` on clusters and
//! `Int(String)`. The band behind the acute prompt is [`crate::risk::risk_band`],
//! the one the risk facade already uses. Titles, symbols, colour names and
//! the dismissal bookkeeping stay in Swift.

use crate::geo::meters;
use crate::risk::{risk_band, RiskBand, RISK_YELLOW_MIN};
use crate::swift_text as st;

/// A point as (latitude, longitude), degrees.
pub type Point = (f64, f64);

// ============================================================ EscalationPolicy

/// How far the mean must rise above the accepted baseline.
pub const SUSTAINED_RISE: f64 = 0.12;
/// How much worse a new prompt must be than the last one dismissed.
pub const DISMISS_MARGIN: f64 = 0.05;
/// The baseline of a leg whose first complete score has not arrived.
pub const DEFERRED_BASELINE: f64 = -1.0;

/// Prompt kinds, in `EscalationPolicy.Trigger` declaration order.
pub mod trigger {
    /// The whole window got worse.
    pub const SUSTAINED: u8 = 0;
    /// A realized Red somewhere in the window.
    pub const ACUTE: u8 = 1;
}

/// `EscalationPolicy.evaluate`: the baseline to keep and the prompt to raise,
/// as (kind, risk). A deferred baseline takes the first complete mean and
/// raises nothing; an incomplete reading raises nothing; an acute Red peak
/// (worse than the last dismissal by the margin, or naming an alert not yet
/// dismissed — ids compared as Swift strings) wins over a sustained rise.
#[allow(clippy::too_many_arguments)]
#[must_use]
pub fn evaluate_escalation(
    complete: bool,
    mean: f64,
    peak: f64,
    peak_alert_id: Option<&str>,
    baseline: f64,
    dismissed_risk: f64,
    dismissed_alert_ids: &[&str],
) -> (f64, Option<(u8, f64)>) {
    if baseline < 0.0 {
        return (if complete { mean } else { baseline }, None);
    }
    if !complete {
        return (baseline, None);
    }
    let unseen = peak_alert_id.is_some_and(|id| !dismissed_alert_ids.iter().any(|d| st::eq(d, id)));
    let acute = matches!(risk_band(peak), RiskBand::Red)
        && (peak > dismissed_risk + DISMISS_MARGIN || unseen);
    if acute {
        return (baseline, Some((trigger::ACUTE, peak)));
    }
    let sustained = mean >= RISK_YELLOW_MIN
        && mean > baseline + SUSTAINED_RISE
        && mean > dismissed_risk + DISMISS_MARGIN;
    (baseline, sustained.then_some((trigger::SUSTAINED, mean)))
}

// ============================================================ AlertEntityParser

/// The colour vocabulary, multi-word first.
pub const COLOR_NAMES: &[&str] = &[
    "dark blue",
    "light blue",
    "dark green",
    "light green",
    "dark gray",
    "light gray",
    "red",
    "blue",
    "green",
    "black",
    "white",
    "silver",
    "gray",
    "grey",
    "yellow",
    "orange",
    "purple",
    "brown",
    "tan",
    "gold",
    "maroon",
    "beige",
    "pink",
];

/// Brands shown as a text badge.
pub const BRANDS: &[&str] = &[
    "Toyota",
    "Ford",
    "Chevrolet",
    "Chevy",
    "Honda",
    "Nissan",
    "Dodge",
    "Ram",
    "GMC",
    "Jeep",
    "Hyundai",
    "Kia",
    "Subaru",
    "Mazda",
    "Tesla",
    "Volkswagen",
    "BMW",
    "Mercedes",
    "Audi",
    "Lexus",
    "Buick",
    "Cadillac",
    "Chrysler",
    "Volvo",
    "Acura",
    "Infiniti",
    "Lincoln",
    "Mitsubishi",
    "Pontiac",
    "Saturn",
    "Freightliner",
    "Peterbilt",
    "Kenworth",
];

/// Vehicle kinds, in `AlertEntityParser.VehicleKind.allCases` order.
pub mod vehicle_kind {
    /// Truck.
    pub const TRUCK: u8 = 0;
    /// SUV.
    pub const SUV: u8 = 1;
    /// Van.
    pub const VAN: u8 = 2;
    /// Sedan.
    pub const SEDAN: u8 = 3;
    /// Motorcycle.
    pub const MOTORCYCLE: u8 = 4;
    /// Bus.
    pub const BUS: u8 = 5;
}

const VEHICLE_WORDS: &[(&str, u8)] = &[
    ("pickup truck", vehicle_kind::TRUCK),
    ("pickup", vehicle_kind::TRUCK),
    ("truck", vehicle_kind::TRUCK),
    ("suv", vehicle_kind::SUV),
    ("sport utility", vehicle_kind::SUV),
    ("minivan", vehicle_kind::VAN),
    ("van", vehicle_kind::VAN),
    ("sedan", vehicle_kind::SEDAN),
    ("coupe", vehicle_kind::SEDAN),
    ("hatchback", vehicle_kind::SEDAN),
    ("motorcycle", vehicle_kind::MOTORCYCLE),
    ("bus", vehicle_kind::BUS),
    ("car", vehicle_kind::SEDAN),
];

/// Clusters either side of a match that count as "the same breath".
const WINDOW_CLUSTERS: usize = 60;

/// `AlertEntityParser.describesAnEntity`: the AMBER family and
/// law-enforcement emergencies, by substring of the lowercased event.
#[must_use]
pub fn describes_an_entity(event: &str) -> bool {
    let lower = st::lowercased(event);
    [
        "amber",
        "child abduction",
        "blue alert",
        "silver alert",
        "endangered",
        "missing",
        "law enforcement",
        "civil emergency",
    ]
    .iter()
    .any(|w| st::contains(&lower, w))
}

/// A vehicle description: colour, kind code, brand.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VehicleEntity {
    /// The named colour near the vehicle word.
    pub color: Option<&'static str>,
    /// The kind code.
    pub kind: u8,
    /// The brand near it (Chevy reads as Chevrolet).
    pub brand: Option<&'static str>,
}

/// `AlertEntityParser.vehicle(in:)`: the first vehicle word the lowercased
/// text contains, with the first colour and the first brand (case-insensitive)
/// within 60 clusters of its first occurrence.
#[must_use]
pub fn vehicle(text: &str) -> Option<VehicleEntity> {
    let lower = st::lowercased(text);
    let &(word, kind) = VEHICLE_WORDS
        .iter()
        .find(|(w, _)| st::contains(&lower, w))?;
    let (lo, hi) = st::find(&lower, word)?;
    let window = st::cluster_window(&lower, lo, hi, WINDOW_CLUSTERS, WINDOW_CLUSTERS);
    let color = COLOR_NAMES
        .iter()
        .copied()
        .find(|c| st::contains(window, c));
    let brand = BRANDS
        .iter()
        .copied()
        .find(|b| st::contains_case_insensitive(window, b))
        .map(|b| if b == "Chevy" { "Chevrolet" } else { b });
    Some(VehicleEntity { color, kind, brand })
}

/// `AlertEntityParser.person(in:)`: `None` without a person word; a child
/// when any child word appears; the colour near the first clothing word that
/// has one.
#[must_use]
pub fn person(text: &str) -> Option<(bool, Option<&'static str>)> {
    let lower = st::lowercased(text);
    let child = [
        "child",
        "boy",
        "girl",
        "infant",
        "toddler",
        "juvenile",
        "-year-old",
        "year old",
    ]
    .iter()
    .any(|w| st::contains(&lower, w));
    let adult = ["man", "woman", "male", "female", "adult", "suspect"]
        .iter()
        .any(|w| st::contains(&lower, w));
    if !(child || adult) {
        return None;
    }
    let mut color = None;
    for clothing in [
        "wearing", "shirt", "jacket", "hoodie", "dress", "pants", "clothing", "hair",
    ] {
        if let Some((lo, hi)) = st::find(&lower, clothing) {
            let window = st::cluster_window(&lower, lo, hi, WINDOW_CLUSTERS, WINDOW_CLUSTERS);
            if let Some(c) = COLOR_NAMES
                .iter()
                .copied()
                .find(|c| st::contains(window, c))
            {
                color = Some(c);
                break;
            }
        }
    }
    Some((child, color))
}

// ============================================================ ScannerIncidents

/// Call kinds, in `ScannerIncidents.Kind.allCases` order.
pub mod call_kind {
    /// Police.
    pub const POLICE: u8 = 0;
    /// Medical.
    pub const MEDICAL: u8 = 1;
    /// Fire.
    pub const FIRE: u8 = 2;
    /// Rescue.
    pub const RESCUE: u8 = 3;
    /// A crash.
    pub const TRAFFIC: u8 = 4;
    /// A road hazard.
    pub const HAZARD: u8 = 5;
}

/// The phrases that mean a kind of call, most specific first.
#[must_use]
pub fn phrases(kind: u8) -> &'static [&'static str] {
    match kind {
        call_kind::TRAFFIC => &[
            "crash",
            "wreck",
            "accident",
            "rollover",
            "pileup",
            "pile up",
            "jackknifed",
            "overturned",
            "motor vehicle accident",
            "mva",
            "vehicle accident",
            "traffic collision",
            "ten fifty",
            "10-50",
            "car accident",
            "collision",
            "vehicle rollover",
            "hit and run",
            "vehicle versus",
        ],
        call_kind::FIRE => &[
            "structure fire",
            "working fire",
            "brush fire",
            "vehicle fire",
            "smoke showing",
            "fire alarm",
            "engine responding",
            "ladder responding",
            "fully involved",
            "grass fire",
        ],
        call_kind::MEDICAL => &[
            "cardiac arrest",
            "difficulty breathing",
            "medical call",
            "unresponsive",
            "chest pain",
            "overdose",
            "seizure",
            "ems responding",
            "medic",
            "ambulance",
            "injury",
            "unconscious",
        ],
        call_kind::RESCUE => &[
            "water rescue",
            "swift water",
            "extrication",
            "entrapment",
            "pin in",
            "pinned in",
            "trapped",
            "rescue squad",
            "entrapment",
            "person in the water",
        ],
        call_kind::HAZARD => &[
            "hazmat",
            "gas leak",
            "power line down",
            "wires down",
            "tree down",
            "spill",
            "roadway blocked",
            "road closed",
            "downed pole",
        ],
        _ => &[
            "shots fired",
            "in pursuit",
            "pursuit",
            "traffic stop",
            "suspicious vehicle",
            "burglary",
            "robbery",
            "domestic",
            "disturbance",
            "warrant",
            "signal 10",
            "officer",
            "units responding",
            "be on the lookout",
            "bolo",
            "subject",
        ],
    }
}

/// Kinds tried in order, the specific before the general.
pub const MATCH_ORDER: [u8; 6] = [
    call_kind::TRAFFIC,
    call_kind::FIRE,
    call_kind::RESCUE,
    call_kind::HAZARD,
    call_kind::MEDICAL,
    call_kind::POLICE,
];

/// Road-type words a dispatcher says.
pub const ROAD_WORDS: &[&str] = &[
    "street",
    "st",
    "avenue",
    "ave",
    "road",
    "rd",
    "drive",
    "dr",
    "boulevard",
    "blvd",
    "lane",
    "ln",
    "highway",
    "hwy",
    "parkway",
    "pkwy",
    "court",
    "ct",
    "place",
    "pl",
    "way",
    "trail",
    "terrace",
    "circle",
    "route",
    "interstate",
    "freeway",
    "turnpike",
];

/// How far from the driver or the corridor a pin is drawn, meters.
pub const RELEVANT_METERS: f64 = 25_000.0;
/// Two reports of one kind this close are the same call, meters.
pub const DUPLICATE_METERS: f64 = 250.0;

/// `ScannerIncidents.kind(inTranscript:)`: the first kind in match order with
/// a phrase starting or ending at a space of `" " + lowercased + " "`.
#[must_use]
pub fn kind_in_transcript(text: &str) -> Option<u8> {
    let hay = format!(" {} ", st::lowercased(text));
    MATCH_ORDER.iter().copied().find(|&kind| {
        phrases(kind)
            .iter()
            .any(|p| st::contains(&hay, &format!(" {p}")) || st::contains(&hay, &format!("{p} ")))
    })
}

fn is_road_word(w: &str) -> bool {
    ROAD_WORDS.iter().any(|r| st::eq(w, r))
}

/// `ScannerIncidents.placePhrase(inTranscript:)`: punctuation to spaces, the
/// words split on spaces, then a cross-street pair around "and"/"at" (a road
/// word on both sides within three words), else a street address (a number
/// from 1 to 99,999 followed within four words by a road word).
#[must_use]
pub fn place_phrase(text: &str) -> Option<String> {
    let mut cleaned = st::lowercased(text);
    for p in [",", ".", ";", ":", "!", "?"] {
        cleaned = st::replacing(&cleaned, p, " ");
    }
    let words = st::split_spaces(&cleaned);
    if words.len() < 2 {
        return None;
    }
    for (i, w) in words.iter().enumerate() {
        if !(st::eq(w, "and") || st::eq(w, "at")) || i < 2 || i + 2 >= words.len() {
            continue;
        }
        let left = &words[i.saturating_sub(3)..i];
        let right = &words[i + 1..=(words.len() - 1).min(i + 3)];
        if left.iter().any(|w| is_road_word(w)) && right.iter().any(|w| is_road_word(w)) {
            let mut parts: Vec<&str> = left.to_vec();
            parts.push("and");
            parts.extend_from_slice(right);
            return Some(parts.join(" "));
        }
    }
    for (i, w) in words.iter().enumerate() {
        let Some(n) = st::parse_swift_int(w) else {
            continue;
        };
        if n <= 0 || n >= 100_000 || i + 1 >= words.len() {
            continue;
        }
        let last = (words.len() - 1).min(i + 4);
        if let Some(end) = (i + 1..=last).find(|&j| is_road_word(words[j])) {
            return Some(words[i..=end].join(" "));
        }
    }
    None
}

/// `ScannerIncidents.lifetime(for:)`, seconds; a code past the kinds lives as
/// a hazard.
#[must_use]
pub fn lifetime_seconds(kind: u8) -> f64 {
    match kind {
        call_kind::POLICE => 720.0,
        call_kind::MEDICAL => 1_200.0,
        call_kind::TRAFFIC | call_kind::RESCUE => 2_100.0,
        call_kind::FIRE => 2_700.0,
        _ => 3_600.0,
    }
}

/// `ScannerIncidents.isExpired`, instants as seconds since the reference date.
#[must_use]
pub fn is_expired(kind: u8, heard_at: f64, now: f64) -> bool {
    now - heard_at >= lifetime_seconds(kind)
}

/// `ScannerIncidents.visible`: the indices of incidents (kind, point, heard
/// at) still live and within 25 km of the position or of any corridor point.
#[must_use]
pub fn visible(
    incidents: &[(u8, Point, f64)],
    position: Option<Point>,
    corridor: &[Point],
    now: f64,
) -> Vec<usize> {
    (0..incidents.len())
        .filter(|&i| {
            let (kind, p, heard) = incidents[i];
            if is_expired(kind, heard, now) {
                return false;
            }
            if position.is_some_and(|q| meters(p.0, p.1, q.0, q.1) <= RELEVANT_METERS) {
                return true;
            }
            corridor
                .iter()
                .any(|c| meters(p.0, p.1, c.0, c.1) <= RELEVANT_METERS)
        })
        .collect()
}

/// `ScannerIncidents.merged`: the indices of existing (kind, point) incidents
/// that survive a new report — all but those of its kind within 250 m. The
/// caller appends the new incident.
#[must_use]
pub fn merged_keep(existing: &[(u8, Point)], new_kind: u8, new_point: Point) -> Vec<usize> {
    (0..existing.len())
        .filter(|&i| {
            let (kind, p) = existing[i];
            !(kind == new_kind && meters(p.0, p.1, new_point.0, new_point.1) <= DUPLICATE_METERS)
        })
        .collect()
}
