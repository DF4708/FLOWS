// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Brand, price and tag text: the name-matching and parsing behind the
//! places table, ported function by function from the Swift at commit
//! a007de0 on top of [`crate::swift_text`], which gives every string
//! operation Swift's own meaning.
//!
//! | here | Swift |
//! |---|---|
//! | [`words`], [`cost_tier`], [`website`], [`gym_has_showers`], [`parking_fee`], [`shelter_type`], [`is_shelter_noise`], [`asked_name_matches`] | `BrandKnowledge` |
//! | [`country_for_coordinate`], [`check_breakpoints`], [`cost_tier_for_check`], [`estimated_nightly`], [`yelp_cost_tier`] | `RatingsAndCost` |
//! | [`shower_for_name`], [`shower_ladder`], [`shower_table_entry`], [`city_keys`] | `ShowerAvailability` |
//! | [`usd_per_gallon`], [`mexico_estimate`], [`fuel_state_code`], [`fuel_estimate`], [`parse_current_avg`] | `FuelPrices`, `AAAFuelPrices.parseCurrentAvg` |
//! | [`parse_turn_lanes`], [`recommended_lanes`] | `LaneData` |
//! | [`camera_kind`], [`camera_limit_mph`] | `EnforcementCameras` |
//!
//! # Fidelity
//!
//! Every answer matches the Swift it replaced on the frozen oracle
//! `flows-bridge/tests/fixtures/swift_places_text_oracle.tsv`, produced by the
//! original code over adversarial text (combining marks, joiners, prepends,
//! flags, conjuncts, fullwidth and Kelvin letters, NULs, every whitespace).
//! Getting there is a matter of using the right primitive for each Swift
//! call: `==` and dictionary keys are canonical equivalence ([`swift_text::eq`]),
//! `contains`/`components`/`replacingOccurrences` are cluster-aligned matches,
//! `count`/`prefix`/`filter` see clusters, `isLetter`/`isNumber` read a
//! cluster's first scalar, and `Double(String)` is Darwin's `strtod`.
//!
//! Enumerations cross as codes in the Swift declaration order: countries 0 us,
//! 1 canada, 2 mexico; shelter types 0 storm, 1 flood, 2 cooling, 3 warming,
//! 4 emergency; shower availability 0 standard, 1 likely, 2 none, 3 disproven,
//! 4 unknown; lane turns [`TURN_NAMES`]; maneuver sides 0 left, 1 right,
//! 2 none; camera kinds 0 speed, 1 red light, 2 both. Fuel codes are the
//! `trip_vehicle` ones.
//!
//! Nothing here performs I/O, reads a clock or holds mutable state: the brand
//! tables are built once from their spellings and never change.

use crate::fcmp::swift_int;
use crate::swift_text as st;
use crate::trip_vehicle::{FUEL_DIESEL, FUEL_ELECTRIC, FUEL_GAS};
use std::sync::OnceLock;

// =============================================================================
// BrandKnowledge
// =============================================================================

/// `BrandKnowledge.words`: lowercased word runs. Apostrophes vanish so
/// "McDonald's" and "McDonalds" are the same word; every other cluster that
/// is not a letter or number splits ("Chick-fil-A" is chick, fil, a).
///
/// Deterministic; allocates the words; panics: none.
#[must_use]
pub fn words(text: &str) -> Vec<String> {
    let lower = st::lowercased(text);
    let stripped = st::replacing(&st::replacing(&lower, "'", ""), "\u{2019}", "");
    let mut out = Vec::new();
    let mut current = String::new();
    for cluster in st::graphemes(&stripped) {
        if st::is_word_start(cluster) {
            current.push_str(cluster);
        } else if !current.is_empty() {
            out.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        out.push(current);
    }
    out
}

/// `BrandKnowledge.contains(_:in:)`: the run of words appears contiguously,
/// word for word (`==`, canonical), inside the name's words.
fn contains_run(run: &[String], name_words: &[String]) -> bool {
    if run.is_empty() || run.len() > name_words.len() {
        return false;
    }
    (0..=name_words.len() - run.len()).any(|start| {
        run.iter()
            .zip(&name_words[start..])
            .all(|(b, w)| st::eq(w, b))
    })
}

/// A word in the list, by Swift `==`.
fn has_word(name_words: &[String], word: &str) -> bool {
    name_words.iter().any(|w| st::eq(w, word))
}

/// `BrandKnowledge.askedName(_:matches:)`: the asked-for words appear
/// contiguously, as standalone words, inside the place's name.
///
/// Deterministic; panics: none.
#[must_use]
pub fn asked_name_matches(asked: &str, name: &str) -> bool {
    contains_run(&words(asked), &words(name))
}

/// A brand row: its spelling, its words, its cost tier and (hotels) its site.
struct Brand {
    words: Vec<String>,
    /// Clusters in the joined words: the second key of "longest match".
    letters: usize,
    tier: i64,
    site: Option<&'static str>,
}

impl Brand {
    fn new(token: &str, tier: i64, site: Option<&'static str>) -> Brand {
        let words = words(token);
        let letters = st::cluster_count(&words.concat());
        Brand {
            words,
            letters,
            tier,
            site,
        }
    }
}

/// Tiers follow the income-anchored "$" scale: 1 fits a minimum-wage budget,
/// 5 is top-percentile territory. Spellings and order are the Swift's.
const DINING: &[(&str, i64)] = &[
    ("Wendy's", 1),
    ("McDonald's", 1),
    ("Subway", 1),
    ("Taco Bell", 1),
    ("Burger King", 1),
    ("KFC", 1),
    ("Chick-fil-A", 1),
    ("Waffle House", 1),
    ("Arby's", 1),
    ("Dairy Queen", 1),
    ("Popeyes", 1),
    ("Dunkin", 1),
    ("Sonic Drive-In", 1),
    ("Hardee's", 1),
    ("Carl's Jr", 1),
    ("Chili's", 2),
    ("Applebee's", 2),
    ("Olive Garden", 2),
    ("Cracker Barrel", 2),
    ("Denny's", 2),
    ("IHOP", 2),
    ("Panera Bread", 2),
    ("Panera", 2),
    ("Starbucks", 2),
    ("Outback Steakhouse", 3),
    ("Outback", 3),
    ("Texas Roadhouse", 3),
    ("LongHorn Steakhouse", 3),
    ("Red Lobster", 3),
];

const STORES: &[(&str, i64)] = &[
    ("Walmart", 1),
    ("Dollar General", 1),
    ("Aldi", 1),
    ("Dollar Tree", 1),
    ("Family Dollar", 1),
    ("Lidl", 1),
    ("Target", 2),
    ("Kroger", 2),
    ("Publix", 2),
    ("Walgreens", 2),
    ("CVS", 2),
    ("Safeway", 2),
    ("Meijer", 2),
    ("Whole Foods", 3),
    ("Best Buy", 3),
];

/// Hotel chains carry the brand's own booking site.
const HOTELS: &[(&str, i64, &str)] = &[
    ("Motel 6", 1, "https://www.motel6.com"),
    ("Super 8", 1, "https://www.wyndhamhotels.com/super-8"),
    ("Econo Lodge", 1, "https://www.choicehotels.com/econo-lodge"),
    ("Red Roof Inn", 1, "https://www.redroof.com"),
    ("Days Inn", 2, "https://www.wyndhamhotels.com/days-inn"),
    ("La Quinta", 2, "https://www.wyndhamhotels.com/laquinta"),
    ("Comfort Inn", 2, "https://www.choicehotels.com/comfort-inn"),
    ("Quality Inn", 2, "https://www.choicehotels.com/quality-inn"),
    ("Best Western", 2, "https://www.bestwestern.com"),
    ("Holiday Inn", 3, "https://www.ihg.com/holidayinn"),
    ("Hampton Inn", 3, "https://www.hilton.com/en/hampton"),
    ("Hilton Garden Inn", 3, "https://www.hilton.com"),
    ("Embassy Suites", 3, "https://www.hilton.com"),
    ("DoubleTree", 3, "https://www.hilton.com"),
    (
        "Courtyard by Marriott",
        3,
        "https://www.marriott.com/courtyard",
    ),
    (
        "Courtyard Marriott",
        3,
        "https://www.marriott.com/courtyard",
    ),
    ("Fairfield Inn", 2, "https://www.marriott.com/fairfield"),
    ("Hilton", 4, "https://www.hilton.com"),
    ("Marriott", 4, "https://www.marriott.com"),
    ("Hyatt", 4, "https://www.hyatt.com"),
    ("Sheraton", 4, "https://www.marriott.com/sheraton"),
    ("Westin", 4, "https://www.marriott.com/westin"),
    ("Ritz-Carlton", 5, "https://www.ritzcarlton.com"),
    ("Four Seasons", 5, "https://www.fourseasons.com"),
    ("Waldorf Astoria", 5, "https://www.waldorfastoria.com"),
    ("Waldorf", 5, "https://www.waldorfastoria.com"),
];

/// Chains where member showers are the brand standard (true) or famously
/// absent (false).
const GYM_SHOWERS: &[(&str, bool)] = &[
    ("Planet Fitness", true),
    ("LA Fitness", true),
    ("Gold's Gym", true),
    ("Anytime Fitness", true),
    ("Crunch Fitness", true),
    ("Crunch", true),
    ("24 Hour Fitness", true),
    ("YMCA", true),
    ("YWCA", true),
    ("Life Time", true),
    ("Equinox", true),
    ("Curves", false),
];

/// Commercial operators that only run paid facilities.
const PAID_PARKING_OPERATORS: &[&str] = &[
    "LAZ",
    "LAZ Parking",
    "SP+",
    "SP Plus",
    "Impark",
    "Diamond Parking",
    "ABM Parking",
    "Ace Parking",
    "Premium Parking",
];

struct BrandTables {
    hotels: Vec<Brand>,
    all: Vec<Brand>,
    gyms: Vec<(Brand, bool)>,
    paid_parking: Vec<Vec<String>>,
}

fn tables() -> &'static BrandTables {
    static TABLES: OnceLock<BrandTables> = OnceLock::new();
    TABLES.get_or_init(|| {
        let hotels: Vec<Brand> = HOTELS
            .iter()
            .map(|&(t, tier, site)| Brand::new(t, tier, Some(site)))
            .collect();
        let mut all: Vec<Brand> = DINING
            .iter()
            .chain(STORES)
            .map(|&(t, tier)| Brand::new(t, tier, None))
            .collect();
        all.extend(
            HOTELS
                .iter()
                .map(|&(t, tier, site)| Brand::new(t, tier, Some(site))),
        );
        BrandTables {
            hotels,
            all,
            gyms: GYM_SHOWERS
                .iter()
                .map(|&(t, showers)| (Brand::new(t, 0, None), showers))
                .collect(),
            paid_parking: PAID_PARKING_OPERATORS.iter().map(|t| words(t)).collect(),
        }
    })
}

/// `BrandKnowledge.best`: the longest matching brand — more words beat
/// fewer, then more letters — and on a tie the first in table order (Swift's
/// `max(by:)` keeps the earlier element).
fn best<'a>(name_words: &[String], table: impl Iterator<Item = &'a Brand>) -> Option<&'a Brand> {
    let mut winner: Option<&Brand> = None;
    for brand in table.filter(|b| contains_run(&b.words, name_words)) {
        let better =
            winner.is_none_or(|w| (w.words.len(), w.letters) < (brand.words.len(), brand.letters));
        if better {
            winner = Some(brand);
        }
    }
    winner
}

/// `BrandKnowledge.costTier(name:)`: 1…5 for a known national brand.
///
/// Deterministic; panics: none.
#[must_use]
pub fn cost_tier(name: &str) -> Option<i64> {
    best(&words(name), tables().all.iter()).map(|b| b.tier)
}

/// `BrandKnowledge.website(name:)`: the hotel chain's own site.
///
/// Deterministic; panics: none.
#[must_use]
pub fn website(name: &str) -> Option<&'static str> {
    best(&words(name), tables().hotels.iter()).and_then(|b| b.site)
}

/// `BrandKnowledge.gymHasShowers(name:)`: true, false, or unknown (`None`).
///
/// Deterministic; panics: none.
#[must_use]
pub fn gym_has_showers(name: &str) -> Option<bool> {
    let nw = words(name);
    let mut winner: Option<&(Brand, bool)> = None;
    for row in tables()
        .gyms
        .iter()
        .filter(|(b, _)| contains_run(&b.words, &nw))
    {
        let better = winner
            .is_none_or(|(w, _)| (w.words.len(), w.letters) < (row.0.words.len(), row.0.letters));
        if better {
            winner = Some(row);
        }
    }
    winner.map(|(_, showers)| *showers)
}

/// `BrandKnowledge.parkingFee(name:)`: true costs money, false is free,
/// `None` when the name says neither. An explicit "free" beats structure
/// words; a paid operator beats everything.
///
/// Deterministic; panics: none.
#[must_use]
pub fn parking_fee(name: &str) -> Option<bool> {
    let nw = words(name);
    if tables().paid_parking.iter().any(|op| contains_run(op, &nw)) {
        return Some(true);
    }
    let run = |s: &str| contains_run(&words(s), &nw);
    if has_word(&nw, "free")
        || run("rest area")
        || run("park and ride")
        || run("park ride")
        || run("welcome center")
    {
        return Some(false);
    }
    if st::contains(name, "$")
        || has_word(&nw, "paid")
        || has_word(&nw, "garage")
        || has_word(&nw, "valet")
        || has_word(&nw, "pay")
        || has_word(&nw, "metered")
    {
        return Some(true);
    }
    None
}

/// Shelter types in the Swift's order; the general case last.
pub const SHELTER_TYPE_NAMES: [&str; 5] = [
    "Storm shelter",
    "Flood shelter",
    "Cooling center",
    "Warming center",
    "Emergency shelter",
];

fn classify_shelter(ws: &[String]) -> Option<u8> {
    if has_word(ws, "tornado") || has_word(ws, "storm") {
        return Some(0);
    }
    if has_word(ws, "flood") || has_word(ws, "tsunami") || contains_run(&words("high ground"), ws) {
        return Some(1);
    }
    if has_word(ws, "cooling") {
        return Some(2);
    }
    if has_word(ws, "warming") {
        return Some(3);
    }
    None
}

/// `BrandKnowledge.shelterType(name:query:)`: from the name first, the query
/// second, else the general case (code 4), as [`SHELTER_TYPE_NAMES`].
///
/// Deterministic; panics: none.
#[must_use]
pub fn shelter_type(name: &str, query: &str) -> u8 {
    classify_shelter(&words(name))
        .or_else(|| classify_shelter(&words(query)))
        .unwrap_or(4)
}

const SHELTER_NOISE: [&str; 10] = [
    "animal",
    "pet",
    "pets",
    "humane",
    "spca",
    "wildlife",
    "kennel",
    "veterinary",
    "homeless",
    "thrift",
];

/// `BrandKnowledge.isShelterNoise(name:)`: animal shelters and service
/// offices the shelter queries surface.
///
/// Deterministic; panics: none.
#[must_use]
pub fn is_shelter_noise(name: &str) -> bool {
    let ws = words(name);
    SHELTER_NOISE.iter().any(|noise| has_word(&ws, noise))
}

// =============================================================================
// RatingsAndCost
// =============================================================================

/// Country codes: 0 us, 1 canada, 2 mexico.
pub const COUNTRY_NAMES: [&str; 3] = ["us", "canada", "mexico"];

/// `Country.checkBreakpoints`: average per-person check edges of tiers 1…4
/// in local currency.
#[must_use]
pub fn check_breakpoints(country: u8) -> [f64; 4] {
    match country {
        1 => [16.0, 40.0, 80.0, 160.0],
        2 => [90.0, 250.0, 600.0, 1500.0],
        _ => [12.0, 30.0, 60.0, 120.0],
    }
}

/// `Country.forCoordinate`: rough North American boxes with the US–Mexico
/// border as three line segments and the Rio Grande diagonal.
///
/// Deterministic; panics: none.
#[must_use]
pub fn country_for_coordinate(latitude: f64, longitude: f64) -> u8 {
    let is_mexico = || {
        if !(longitude > -118.0 && longitude < -86.0) {
            return false;
        }
        if latitude < 25.9 {
            return true;
        }
        if longitude < -114.7 {
            return latitude < 32.5;
        }
        if longitude < -106.4 {
            return latitude < 31.3;
        }
        if longitude < -97.1 {
            let border_lat = 31.75 - 0.63 * (longitude + 106.4);
            return latitude < border_lat;
        }
        false
    };
    if is_mexico() {
        return 2;
    }
    if latitude > 49.0 {
        return 1;
    }
    if latitude > 44.8 && longitude > -83.6 && longitude < -52.0 {
        return 1;
    }
    if latitude > 43.4 && longitude > -81.8 && longitude < -76.3 {
        return 1;
    }
    0
}

/// `RatingsAndCost.costTier(averageCheck:country:)`: the first edge the
/// check does not exceed, else 5 (a NaN check is 5).
///
/// Deterministic; panics: none.
#[must_use]
pub fn cost_tier_for_check(average_check: f64, country: u8) -> i64 {
    for (i, edge) in check_breakpoints(country).iter().enumerate() {
        if average_check <= *edge {
            return i as i64 + 1;
        }
    }
    5
}

/// `RatingsAndCost.estimatedNightly(costTier:)`: typical US nightly rate for
/// a tier; an unknown tier reads as the mid-market median.
///
/// Deterministic; panics: none.
#[must_use]
pub fn estimated_nightly(cost_tier: Option<i64>) -> f64 {
    match cost_tier {
        Some(1) => 75.0,
        Some(3) => 190.0,
        Some(4) => 320.0,
        Some(5) => 500.0,
        _ => 120.0,
    }
}

/// `RatingsAndCost.costTier(yelpPrice:rating:)`: the count of `"$"`
/// characters; Yelp's top band splits on a 4.5-star rating.
///
/// Deterministic; panics: none.
#[must_use]
pub fn yelp_cost_tier(yelp_price: &str, rating: Option<f64>) -> i64 {
    let count = st::graphemes(yelp_price).filter(|c| st::eq(c, "$")).count();
    match count {
        0 => 1,
        1..=3 => count as i64,
        _ => {
            if rating.unwrap_or(0.0) >= 4.5 {
                5
            } else {
                4
            }
        }
    }
}

// ---- ShowerAvailability ----

/// Shower availability codes in the Swift's order.
pub const SHOWER_NAMES: [&str; 5] = [
    "Showers",
    "Showers likely",
    "No showers",
    "No showers (reported)",
    "",
];

const SHOWERS_STANDARD: [&str; 8] = [
    "love's",
    "loves travel",
    "pilot",
    "flying j",
    "ta travel",
    "travelcenters of america",
    "petro stopping",
    "sapp bros",
];
const SHOWERS_LIKELY: [&str; 4] = ["kwik trip", "road ranger", "ambest", "roady"];
const SHOWERS_NONE: [&str; 11] = [
    "buc-ee", "bucee", "casey's", "caseys", "speedway", "circle k", "7-eleven", "kum & go",
    "quiktrip", "wawa", "sheetz",
];

/// `ShowerAvailability.forStop(named:)`: the brand default by name.
///
/// Deterministic; panics: none.
#[must_use]
pub fn shower_for_name(name: Option<&str>) -> u8 {
    let lower = st::lowercased(name.unwrap_or(""));
    if SHOWERS_STANDARD.iter().any(|b| st::contains(&lower, b)) {
        return 0;
    }
    if SHOWERS_LIKELY.iter().any(|b| st::contains(&lower, b)) {
        return 1;
    }
    if SHOWERS_NONE.iter().any(|b| st::contains(&lower, b)) {
        return 2;
    }
    4
}

/// `ShowerAvailability.forStop(named:lat:lon:table:)`, with the store's
/// lookups done: `has_position` says both coordinates were given,
/// `disproved` is the driver's report at that place, `tag` the table entry's
/// shower tag when an entry was found and tagged. Report, then tag ("no" is
/// none, anything else standard), then the brand.
///
/// Deterministic; panics: none.
#[must_use]
pub fn shower_ladder(
    name: Option<&str>,
    has_position: bool,
    disproved: bool,
    tag: Option<&str>,
) -> u8 {
    if has_position {
        if disproved {
            return 3;
        }
        if let Some(tag) = tag {
            return if st::eq(tag, "no") { 2 } else { 0 };
        }
    }
    shower_for_name(name)
}

/// Side of the shower table's grid cells, degrees.
pub const SHOWER_CELL_DEGREES: f64 = 0.01;

fn shower_cell(degrees: f64) -> Option<i64> {
    swift_int((degrees / SHOWER_CELL_DEGREES).floor())
}

/// `LocationTable.entry(nearLat:lon:)`: the nearest entry within the ±0.01°
/// box of a stop, ties to the lowest index, looked up through the 0.01° grid
/// the Swift keeps (an entry is seen only when its cell is within one of the
/// stop's on both axes, exactly as that grid sees it). `None` for a stop
/// that cannot be placed, where the Swift trapped; an entry that cannot be
/// placed is never seen.
///
/// Deterministic; panics: none.
#[must_use]
pub fn shower_table_entry(lats: &[f64], lons: &[f64], lat: f64, lon: f64) -> Option<usize> {
    let qx = shower_cell(lon)?;
    let qy = shower_cell(lat)?;
    let mut best: Option<(usize, f64)> = None;
    for (i, (&elat, &elon)) in lats.iter().zip(lons).enumerate() {
        let (Some(ex), Some(ey)) = (shower_cell(elon), shower_cell(elat)) else {
            continue;
        };
        let near = |a: i64, b: i64| a.checked_sub(b).is_some_and(|d| d.abs() <= 1);
        if !near(ex, qx) || !near(ey, qy) {
            continue;
        }
        if !((elat - lat).abs() < SHOWER_CELL_DEGREES && (elon - lon).abs() < SHOWER_CELL_DEGREES) {
            continue;
        }
        let d = (elat - lat) * (elat - lat) + (elon - lon) * (elon - lon);
        if best.is_none_or(|(_, bd)| d < bd) {
            best = Some((i, d));
        }
    }
    best.map(|(i, _)| i)
}

/// `CityTable.showers(state:city:)`'s two keys, in the order tried:
/// `state|city` with the city's spaces as hyphens, then as spelled; both
/// lowercased. The store looks them up with Swift's own key equality.
///
/// Deterministic; panics: none.
#[must_use]
pub fn city_keys(state: &str, city: &str) -> (String, String) {
    let state = st::lowercased(state);
    let city = st::lowercased(city);
    (
        format!("{state}|{}", st::replacing(&city, " ", "-")),
        format!("{state}|{city}"),
    )
}

// =============================================================================
// FuelPrices
// =============================================================================

/// US national baseline, $/gal of gasoline.
pub const NATIONAL_GAS: f64 = 3.10;
/// US national baseline, $/gal of diesel.
pub const NATIONAL_DIESEL: f64 = 3.80;
/// US national baseline, $/kWh at public charging.
pub const NATIONAL_KWH: f64 = 0.36;
/// Approximate pesos per dollar, release-updated: ranking needs the order of
/// magnitude, not the daily rate.
pub const MXN_PER_USD: f64 = 17.0;
/// Liters in a US gallon.
pub const LITERS_PER_GALLON: f64 = 3.78541;

/// `FuelPrices.usdPerGallon(mxnPerLiter:)`.
///
/// Deterministic; panics: none.
#[must_use]
pub fn usd_per_gallon(mxn_per_liter: f64) -> f64 {
    mxn_per_liter / MXN_PER_USD * LITERS_PER_GALLON
}

/// `FuelPrices.mexicoEstimate(fuel:)`: typical posted MXN/L converted and
/// rounded to the cent; public charging as the US figure.
///
/// Deterministic; panics: none.
#[must_use]
pub fn mexico_estimate(fuel: u8) -> f64 {
    match fuel {
        FUEL_DIESEL => (usd_per_gallon(25.4) * 100.0).round() / 100.0,
        FUEL_ELECTRIC => NATIONAL_KWH,
        _ => (usd_per_gallon(23.7) * 100.0).round() / 100.0,
    }
}

/// State multipliers against the national baselines.
pub const STATE_FACTORS: &[(&str, f64)] = &[
    ("AK", 1.18),
    ("AL", 0.92),
    ("AR", 0.92),
    ("AZ", 1.08),
    ("CA", 1.48),
    ("CO", 1.00),
    ("CT", 1.06),
    ("DC", 1.06),
    ("DE", 1.00),
    ("FL", 1.01),
    ("GA", 0.95),
    ("HI", 1.45),
    ("IA", 0.96),
    ("ID", 1.06),
    ("IL", 1.09),
    ("IN", 1.02),
    ("KS", 0.93),
    ("KY", 0.95),
    ("LA", 0.92),
    ("MA", 1.04),
    ("MD", 1.01),
    ("ME", 1.04),
    ("MI", 1.02),
    ("MN", 0.98),
    ("MO", 0.93),
    ("MS", 0.90),
    ("MT", 1.02),
    ("NC", 0.96),
    ("ND", 0.97),
    ("NE", 0.96),
    ("NH", 1.00),
    ("NJ", 1.02),
    ("NM", 0.97),
    ("NV", 1.20),
    ("NY", 1.07),
    ("OH", 1.00),
    ("OK", 0.90),
    ("OR", 1.22),
    ("PA", 1.08),
    ("RI", 1.03),
    ("SC", 0.94),
    ("SD", 0.97),
    ("TN", 0.93),
    ("TX", 0.91),
    ("UT", 1.05),
    ("VA", 0.98),
    ("VT", 1.05),
    ("WA", 1.32),
    ("WI", 0.98),
    ("WV", 1.00),
    ("WY", 0.98),
];

/// Full state names (lowercase) to codes; a placemark may carry either.
pub const STATE_NAMES: &[(&str, &str)] = &[
    ("alabama", "AL"),
    ("alaska", "AK"),
    ("arizona", "AZ"),
    ("arkansas", "AR"),
    ("california", "CA"),
    ("colorado", "CO"),
    ("connecticut", "CT"),
    ("delaware", "DE"),
    ("district of columbia", "DC"),
    ("florida", "FL"),
    ("georgia", "GA"),
    ("hawaii", "HI"),
    ("idaho", "ID"),
    ("illinois", "IL"),
    ("indiana", "IN"),
    ("iowa", "IA"),
    ("kansas", "KS"),
    ("kentucky", "KY"),
    ("louisiana", "LA"),
    ("maine", "ME"),
    ("maryland", "MD"),
    ("massachusetts", "MA"),
    ("michigan", "MI"),
    ("minnesota", "MN"),
    ("mississippi", "MS"),
    ("missouri", "MO"),
    ("montana", "MT"),
    ("nebraska", "NE"),
    ("nevada", "NV"),
    ("new hampshire", "NH"),
    ("new jersey", "NJ"),
    ("new mexico", "NM"),
    ("new york", "NY"),
    ("north carolina", "NC"),
    ("north dakota", "ND"),
    ("ohio", "OH"),
    ("oklahoma", "OK"),
    ("oregon", "OR"),
    ("pennsylvania", "PA"),
    ("rhode island", "RI"),
    ("south carolina", "SC"),
    ("south dakota", "SD"),
    ("tennessee", "TN"),
    ("texas", "TX"),
    ("utah", "UT"),
    ("vermont", "VT"),
    ("virginia", "VA"),
    ("washington", "WA"),
    ("west virginia", "WV"),
    ("wisconsin", "WI"),
    ("wyoming", "WY"),
];

/// The state code `FuelPrices.estimate` derives from a placemark's state:
/// a two-character spelling uppercased as given (so the store's live-price
/// cache can be asked with Swift's key equality), or the code of a full
/// name; `None` for no state or an unknown spelling.
///
/// Deterministic; panics: none.
#[must_use]
pub fn fuel_state_code(state: Option<&str>) -> Option<String> {
    let trimmed = st::trim_whitespace(state?);
    if st::cluster_count(trimmed) == 2 {
        return Some(st::uppercased(trimmed));
    }
    let lowered = st::lowercased(trimmed);
    STATE_NAMES
        .iter()
        .find(|(name, _)| st::eq(name, &lowered))
        .map(|(_, code)| (*code).to_string())
}

/// The state factor for a code, by Swift's key equality.
fn state_factor(code: &str) -> Option<f64> {
    let ascii = st::ascii_form(code)?;
    STATE_FACTORS
        .iter()
        .find(|(k, _)| *k == ascii)
        .map(|(_, f)| *f)
}

/// `FuelPrices.estimate(fuel:state:)` once the store has looked up its live
/// AAA average for `code` (`live` = gas, diesel): the live price rounded to
/// the cent when there is one for a fuel AAA publishes, else the national
/// baseline scaled by the state's factor (1.0 for an unknown state).
///
/// Deterministic; panics: none.
#[must_use]
pub fn fuel_estimate(fuel: u8, code: Option<&str>, live: Option<(f64, f64)>) -> f64 {
    if let (Some(_), Some((gas, diesel))) = (code, live) {
        match fuel {
            FUEL_GAS => return (gas * 100.0).round() / 100.0,
            FUEL_DIESEL => return (diesel * 100.0).round() / 100.0,
            _ => {}
        }
    }
    let factor = code.and_then(state_factor).unwrap_or(1.0);
    match fuel {
        FUEL_DIESEL => (NATIONAL_DIESEL * factor * 100.0).round() / 100.0,
        FUEL_ELECTRIC => (NATIONAL_KWH * factor * 100.0).round() / 100.0,
        _ => (NATIONAL_GAS * factor * 100.0).round() / 100.0,
    }
}

/// Characters past the anchor the AAA scan may read.
pub const AAA_WINDOW_CHARACTERS: usize = 600;

/// `AAAFuelPrices.parseCurrentAvg`: the four `$` prices after "Current Avg."
/// are Regular, Mid, Premium and Diesel, in column order and never skipped:
/// a price outside 1…12 fails the whole parse. The scan stays within 600
/// characters of the anchor; each price is the run of digits and points in
/// the eight characters after its `$`, read as Swift reads a `Double`.
///
/// Deterministic; panics: none.
#[must_use]
pub fn parse_current_avg(html: &str) -> Option<(f64, f64)> {
    let index = st::ClusterIndex::new(html);
    let (_, anchor_end) = index.find("Current Avg.")?;
    let mut window_end = anchor_end;
    for (n, cluster) in st::graphemes(&html[anchor_end..]).enumerate() {
        if n == AAA_WINDOW_CHARACTERS {
            break;
        }
        window_end += cluster.len();
    }
    let mut prices: Vec<f64> = Vec::with_capacity(4);
    let mut search = anchor_end;
    while prices.len() < 4 {
        let Some((_, dollar_end)) = index.find_in("$", search, window_end) else {
            break;
        };
        let tail = st::prefix_clusters(&html[dollar_end..], 8);
        let number: String = st::graphemes(tail)
            .take_while(|c| st::is_number_start(c) || st::eq(c, "."))
            .collect();
        search = dollar_end;
        let Some(value) = st::swift_double(&number) else {
            continue;
        };
        if !(value > 1.0 && value < 12.0) {
            return None;
        }
        prices.push(value);
    }
    (prices.len() == 4).then(|| (prices[0], prices[3]))
}

// =============================================================================
// LaneData
// =============================================================================

/// `LaneData.Turn` names, indexed by code, in the Swift's order.
pub const TURN_NAMES: [&str; 11] = [
    "sharpLeft",
    "left",
    "slightLeft",
    "through",
    "slightRight",
    "right",
    "sharpRight",
    "mergeToLeft",
    "mergeToRight",
    "reverse",
    "none",
];

/// The turn tagged but unspecified.
pub const TURN_NONE: u8 = 10;
/// The turn straight ahead.
pub const TURN_THROUGH: u8 = 3;

/// OSM spellings of the turns, by code.
const TURN_SPELLINGS: [&str; 11] = [
    "sharp_left",
    "left",
    "slight_left",
    "through",
    "slight_right",
    "right",
    "sharp_right",
    "merge_to_left",
    "merge_to_right",
    "reverse",
    "none",
];

/// `Turn.from(_:)`: trimmed, lowercased, matched by `==`; the empty entry is
/// the unspecified turn.
fn turn_from(raw: &str) -> Option<u8> {
    let t = st::lowercased(st::trim_whitespace(raw));
    if t.is_empty() {
        return Some(TURN_NONE);
    }
    TURN_SPELLINGS
        .iter()
        .position(|s| st::eq(&t, s))
        .map(|i| i as u8)
}

/// `LaneData.parse(turnLanes:)`: lanes left to right, each the turns it
/// permits; an empty or unreadable lane entry is the unspecified turn.
///
/// Deterministic; allocates the lanes; panics: none.
#[must_use]
pub fn parse_turn_lanes(turn_lanes: &str) -> Vec<Vec<u8>> {
    let trimmed = st::trim_whitespace(turn_lanes);
    if trimmed.is_empty() {
        return Vec::new();
    }
    st::components(trimmed, "|")
        .iter()
        .map(|field| {
            let turns: Vec<u8> = st::components(field, ";")
                .iter()
                .filter_map(|t| turn_from(t))
                .collect();
            if turns.is_empty() {
                vec![TURN_NONE]
            } else {
                turns
            }
        })
        .collect()
}

/// Maneuver sides in the Swift's order: 0 left, 1 right, 2 none.
pub const SIDE_LEFT: u8 = 0;
/// See [`SIDE_LEFT`].
pub const SIDE_RIGHT: u8 = 1;
/// See [`SIDE_LEFT`].
pub const SIDE_NONE: u8 = 2;

/// `Turn.side`: which way a movement heads.
#[must_use]
pub fn turn_side(turn: u8) -> u8 {
    match turn {
        0..=2 | 7 | 9 => SIDE_LEFT,
        4..=6 | 8 => SIDE_RIGHT,
        _ => SIDE_NONE,
    }
}

/// `Lane.allows(_:)`: a straight maneuver wants a through or unspecified
/// lane; a turn wants a lane heading its way.
#[must_use]
pub fn lane_allows(turns: &[u8], side: u8) -> bool {
    if side == SIDE_NONE {
        turns.contains(&TURN_THROUGH) || turns.contains(&TURN_NONE)
    } else {
        turns.iter().any(|&t| turn_side(t) == side)
    }
}

/// `LaneData.recommended(lanes:maneuver:)`: the indices of the lanes that
/// serve the maneuver; none when no lane does (never a guess).
///
/// Deterministic; panics: none.
#[must_use]
pub fn recommended_lanes(lanes: &[Vec<u8>], side: u8) -> Vec<usize> {
    lanes
        .iter()
        .enumerate()
        .filter(|(_, turns)| lane_allows(turns, side))
        .map(|(i, _)| i)
        .collect()
}

// =============================================================================
// EnforcementCameras
// =============================================================================

/// Camera kinds in the Swift's order: 0 speed, 1 red light, 2 both.
pub const CAMERA_KIND_NAMES: [&str; 3] = ["speed", "redLight", "both"];

/// `EnforcementCameras.kind(fromTags:)` over the four tags it reads.
///
/// Deterministic; panics: none.
#[must_use]
pub fn camera_kind(
    highway: Option<&str>,
    enforcement: Option<&str>,
    traffic_signals: Option<&str>,
    red_light_camera: Option<&str>,
) -> Option<u8> {
    let highway = highway.unwrap_or("");
    let enforcement = enforcement.unwrap_or("");
    let signals = traffic_signals.unwrap_or("");
    let is_speed = st::eq(highway, "speed_camera")
        || st::contains(enforcement, "maxspeed")
        || st::contains(enforcement, "average_speed");
    let is_light = st::contains(enforcement, "traffic_signals")
        || st::contains(signals, "camera")
        || red_light_camera.is_some_and(|r| st::eq(r, "yes"));
    match (is_speed, is_light) {
        (true, true) => Some(2),
        (true, false) => Some(0),
        (false, true) => Some(1),
        (false, false) => None,
    }
}

/// Miles in a kilometre, as the Swift wrote it.
pub const MILES_PER_KILOMETER: f64 = 0.621371;

/// `EnforcementCameras.limitMph(fromTags:)`: a `maxspeed` ending in "mph"
/// is read as is; a bare number is km/h.
///
/// Deterministic; panics: none.
#[must_use]
pub fn camera_limit_mph(maxspeed: Option<&str>) -> Option<f64> {
    let lowered = st::lowercased(maxspeed?);
    let raw = st::trim_whitespace(&lowered);
    if raw.is_empty() {
        return None;
    }
    if st::has_suffix(raw, "mph") {
        return st::swift_double(st::trim_whitespace(&st::replacing(raw, "mph", "")));
    }
    let kph = st::swift_double(raw)?;
    Some(kph * MILES_PER_KILOMETER)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_split_as_the_original_did() {
        assert_eq!(words("McDonald's"), vec!["mcdonalds"]);
        assert_eq!(words("Chick-fil-A"), vec!["chick", "fil", "a"]);
        assert_eq!(words("SP+"), vec!["sp"]);
        assert_eq!(words("Motel\u{200B}6"), vec!["motel", "6"]);
        assert_eq!(words("Hilton\u{FE0F}"), vec!["hilton\u{FE0F}"]);
        assert_eq!(words("M\u{301}cDonald's"), vec!["m\u{301}cdonalds"]);
        assert!(words("").is_empty());
    }

    #[test]
    fn the_longest_brand_wins_and_ties_go_to_table_order() {
        assert_eq!(cost_tier("Hampton Inn by Hilton"), Some(3));
        assert_eq!(cost_tier("Hilton Nashville Downtown"), Some(4));
        assert_eq!(cost_tier("Hiltonia Cafe"), None);
        assert_eq!(cost_tier("Motel 6 Super 8"), Some(1));
        assert_eq!(
            website("Days Inn by Wyndham"),
            Some("https://www.wyndhamhotels.com/days-inn")
        );
        assert_eq!(website("Walmart"), None);
        assert_eq!(gym_has_showers("Curves"), Some(false));
        assert_eq!(gym_has_showers("Crunch Fitness Curves"), Some(true));
        assert_eq!(gym_has_showers("Bob's Barbell Club"), None);
        assert_eq!(parking_fee("Free Parking Garage"), Some(false));
        assert_eq!(parking_fee("$5 Event Parking"), Some(true));
        assert_eq!(parking_fee("$\u{301}5 lot"), None);
        assert_eq!(parking_fee("LAZ Free"), Some(true));
        assert_eq!(parking_fee("Elm Street Lot"), None);
        assert_eq!(shelter_type("Community Center", "flood"), 1);
        assert_eq!(shelter_type("Downtown Warming Center", ""), 3);
        assert_eq!(shelter_type("Civic Center", ""), 4);
        assert!(is_shelter_noise("Happy Paws Animal Shelter"));
        assert!(!is_shelter_noise("Petersburg Civic Center"));
        assert!(asked_name_matches("Starbucks", "Starbucks Coffee"));
        assert!(!asked_name_matches("Star", "Starbucks"));
        assert!(asked_name_matches("Kwik Trip", "\u{212A}wik Trip"));
        assert!(!asked_name_matches("", "Starbucks"));
    }

    #[test]
    fn countries_tiers_and_showers() {
        assert_eq!(country_for_coordinate(29.76, -95.37), 0);
        assert_eq!(country_for_coordinate(25.67, -100.31), 2);
        assert_eq!(country_for_coordinate(43.65, -79.38), 1);
        assert_eq!(country_for_coordinate(f64::NAN, -100.0), 0);
        assert_eq!(cost_tier_for_check(12.0, 0), 1);
        assert_eq!(cost_tier_for_check(12.5, 0), 2);
        assert_eq!(cost_tier_for_check(f64::NAN, 1), 5);
        assert_eq!(estimated_nightly(None), 120.0);
        assert_eq!(estimated_nightly(Some(i64::MIN)), 120.0);
        assert_eq!(yelp_cost_tier("$$$$", Some(4.5)), 5);
        assert_eq!(yelp_cost_tier("$$$$", Some(f64::NAN)), 4);
        assert_eq!(yelp_cost_tier("$\u{301}$$$$", None), 4);
        assert_eq!(yelp_cost_tier("US$", None), 1);
        assert_eq!(shower_for_name(Some("Love\u{2019}s")), 4);
        assert_eq!(shower_for_name(Some("LOVE'S")), 0);
        assert_eq!(shower_for_name(Some("Circle \u{212A}")), 2);
        assert_eq!(shower_for_name(None), 4);
        assert_eq!(shower_ladder(Some("Pilot"), true, true, None), 3);
        assert_eq!(shower_ladder(Some("Pilot"), true, false, Some("No")), 0);
        assert_eq!(shower_ladder(Some("Pilot"), true, false, Some("no")), 2);
        assert_eq!(shower_ladder(Some("Pilot"), false, true, Some("no")), 0);
        let lats = [41.0, 41.005, 41.0];
        let lons = [-95.0, -95.0, -95.0];
        assert_eq!(shower_table_entry(&lats, &lons, 41.0, -95.0), Some(0));
        assert_eq!(shower_table_entry(&lats, &lons, 41.004, -95.0), Some(1));
        assert_eq!(shower_table_entry(&lats, &lons, 41.02, -95.0), None);
        assert_eq!(shower_table_entry(&lats, &lons, f64::NAN, -95.0), None);
        assert_eq!(
            city_keys("TX", "El Paso"),
            ("tx|el-paso".to_string(), "tx|el paso".to_string())
        );
    }

    #[test]
    fn fuel_estimates_and_the_aaa_row() {
        assert_eq!(fuel_state_code(Some(" wisconsin ")).as_deref(), Some("WI"));
        assert_eq!(
            fuel_state_code(Some("\u{212A}S")).as_deref(),
            Some("\u{212A}S")
        );
        assert_eq!(
            fuel_state_code(Some("\u{212A}ansas")).as_deref(),
            Some("KS")
        );
        assert_eq!(fuel_state_code(Some("W I")), None);
        assert_eq!(fuel_state_code(None), None);
        assert_eq!(
            fuel_estimate(FUEL_GAS, Some("\u{212A}S"), None),
            (NATIONAL_GAS * 0.93 * 100.0).round() / 100.0
        );
        assert_eq!(
            fuel_estimate(FUEL_GAS, Some("KS"), Some((3.335, 4.015))),
            3.34
        );
        assert_eq!(
            fuel_estimate(FUEL_ELECTRIC, Some("KS"), Some((3.335, 4.015))),
            (NATIONAL_KWH * 0.93 * 100.0).round() / 100.0
        );
        assert_eq!(fuel_estimate(FUEL_DIESEL, None, None), NATIONAL_DIESEL);
        assert_eq!(mexico_estimate(FUEL_ELECTRIC), NATIONAL_KWH);
        let row = "<tr><td>Current Avg.</td>\n<td>$3.6840</td><td>$4.2100</td><td>$4.8310</td><td>$4.5810</td></tr>";
        assert_eq!(parse_current_avg(row), Some((3.684, 4.581)));
        assert_eq!(parse_current_avg("Current Avg. $1 $2 $3 $4"), None);
        assert_eq!(
            parse_current_avg("Current Avg. $abc $3.45 $3.5 $3.6 $3.7"),
            Some((3.45, 3.7))
        );
        assert_eq!(parse_current_avg("Current Avg.\u{301} $2 $3 $4 $5"), None);
        assert_eq!(
            parse_current_avg("Current Avg.\u{AD} $2 $3 $4 $5"),
            Some((2.0, 5.0))
        );
        assert_eq!(
            parse_current_avg("Current Avg. $\u{663}.45 $2 $3 $4 $5"),
            Some((2.0, 5.0))
        );
        assert_eq!(parse_current_avg("Current Avg. $.5 $2 $3 $4"), None);
    }

    #[test]
    fn lanes_and_cameras() {
        assert_eq!(
            parse_turn_lanes("left|through|through;right"),
            vec![vec![1], vec![3], vec![3, 5]]
        );
        assert_eq!(
            parse_turn_lanes("||right"),
            vec![vec![10], vec![10], vec![5]]
        );
        assert_eq!(parse_turn_lanes("  "), Vec::<Vec<u8>>::new());
        assert_eq!(parse_turn_lanes("left|\u{301}right"), vec![vec![10]]);
        assert_eq!(parse_turn_lanes("\u{200B}left"), vec![vec![1]]);
        assert_eq!(
            recommended_lanes(&parse_turn_lanes("left|through|through;right"), SIDE_RIGHT),
            vec![2]
        );
        assert_eq!(
            recommended_lanes(&parse_turn_lanes("left|through|through;right"), SIDE_NONE),
            vec![1, 2]
        );
        assert_eq!(
            camera_kind(Some("speed_camera"), Some("traffic_signals"), None, None),
            Some(2)
        );
        assert_eq!(camera_kind(None, None, None, Some("yes")), Some(1));
        assert_eq!(camera_kind(Some("traffic_signals"), None, None, None), None);
        assert_eq!(camera_limit_mph(Some("45 mph")), Some(45.0));
        assert_eq!(
            camera_limit_mph(Some("50")),
            Some(50.0 * MILES_PER_KILOMETER)
        );
        assert_eq!(camera_limit_mph(Some("45 mph\u{301}")), None);
        assert_eq!(camera_limit_mph(Some("mph")), None);
        assert_eq!(
            camera_limit_mph(Some("0X1P3")),
            Some(8.0 * MILES_PER_KILOMETER)
        );
        assert_eq!(camera_limit_mph(Some("  ")), None);
        assert_eq!(camera_limit_mph(None), None);
    }
}
