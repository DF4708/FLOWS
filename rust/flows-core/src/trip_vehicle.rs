// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Trip and vehicle: trip costs and needs, crash decisions, vehicle specs and
//! profile math, EPA class specs.
//!
//! Ported from the app's Swift (TripCosts, TripNeeds, CrashLogic, VehicleSpecs,
//! VehicleProfile, EPAVehicleDatabase at commit a007de0) and pinned bit for bit
//! by the frozen Swift oracle in
//! `flows-bridge/tests/fixtures/swift_trip_vehicle_oracle.tsv`.
//!
//! Every function is a pure transform: no clock, calendar, locale or I/O, no
//! shared state, deterministic for its arguments, and none panics. Minimum and
//! maximum use `crate::fcmp` (Swift's operand order and NaN behaviour), never
//! `f64::min`/`max`.
//!
//! # Codes shared with Swift
//!
//! - Fuel type: 0 gas, 1 diesel, 2 electric (Swift `FuelType.allCases` order).
//! - Food category: 0..9 in Swift `FoodCategory.allCases` order.
//! - Trip need: a fuel code, `10 + food category`, or 20 for rest.
//!
//! # Text rules
//!
//! The Swift originals lowercase with `String.lowercased()`, split words on
//! `Character.isLetter`, and match phrases with `String.contains`, all of which
//! work on grapheme clusters. This module reproduces that for the rules it
//! carries: scalar-wise lowercase (no final-sigma context, as Swift), letters by
//! the first scalar's Alphabetic property (plus the private-use letters Apple's
//! runtime adds), and cluster boundaries by the grapheme-break classes that can
//! touch an ASCII word: Extend, ZWJ and SpacingMark join the scalar before them,
//! Prepend joins the scalar after it, and Control, CR and LF break on both
//! sides. The class tables were swept from the Swift runtime over every scalar
//! and are checked against it by the oracle. Hangul syllable, Indic conjunct,
//! emoji ZWJ and regional-indicator joins are not modelled; they can only
//! change an answer when they sit between a Prepend or a letter-like pictograph
//! and an English word, and the oracle's allow-list names those inputs.

use crate::fcmp::{smax, smin, sunit};
use std::cmp::Ordering;

// =============================================================================
// Shared codes
// =============================================================================

/// Fuel code for gasoline.
pub const FUEL_GAS: u8 = 0;
/// Fuel code for diesel.
pub const FUEL_DIESEL: u8 = 1;
/// Fuel code for electricity (a "unit" is one kWh).
pub const FUEL_ELECTRIC: u8 = 2;

/// Swift `FuelType` raw values, indexed by fuel code. They are the fuel
/// stop labels the trip schedule orders by.
pub const FUEL_TYPE_NAMES: [&str; 3] = ["Gas", "Diesel", "Electric"];

/// Swift `FoodCategory` raw values, in `allCases` order. The trip schedule
/// draws a category by position, so the order is part of every schedule.
pub const FOOD_CATEGORY_NAMES: [&str; 9] = [
    "Fast food",
    "Pizza",
    "American",
    "Mexican",
    "Italian",
    "Chinese",
    "Greek",
    "Coffee",
    "Breakfast",
];

/// Need code offset for a food stop: `NEED_FOOD_BASE + category`.
pub const NEED_FOOD_BASE: u8 = 10;
/// Need code for a rest stop.
pub const NEED_REST: u8 = 20;

// =============================================================================
// TripCosts
// =============================================================================

/// The EPA-average light-duty vehicle assumed when no profile exists, in
/// miles per gallon.
pub const DEFAULT_MILES_PER_UNIT: f64 = 25.0;
/// The fuel assumed when no profile exists (gasoline).
pub const DEFAULT_FUEL: u8 = FUEL_GAS;

/// Combustion CO₂ in grams per unit of fuel: gasoline 8,887 g/gal, diesel
/// 10,180 g/gal, electricity 390 g/kWh (US grid average).
///
/// Units: grams per gallon, or per kWh for electric. NaN for a code outside
/// 0..=2 (the Swift enum cannot produce one). Panics: none.
#[must_use]
pub fn grams_co2_per_unit(fuel: u8) -> f64 {
    match fuel {
        FUEL_GAS => 8_887.0,
        FUEL_DIESEL => 10_180.0,
        FUEL_ELECTRIC => 390.0,
        _ => f64::NAN,
    }
}

/// Published per-passenger-mile CO₂ for mass transit, in grams: local bus
/// 105, local rail 65, intercity coach 56, Amtrak 113. Panics: none.
#[must_use]
pub fn transit_grams_co2_per_mile(rail: bool, long_haul: bool) -> f64 {
    if long_haul {
        return if rail { 113.0 } else { 56.0 };
    }
    if rail {
        65.0
    } else {
        105.0
    }
}

/// A drive's estimated fuel cost in US dollars: miles ÷ miles-per-unit ×
/// price-per-unit, left to right.
///
/// `None` unless `miles` is finite and not negative and both rates are
/// positive (a NaN rate is refused). A present answer can still be NaN
/// (zero miles at an infinite price), exactly as Swift. Panics: none.
#[must_use]
pub fn drive_fuel_cost_usd(miles: f64, miles_per_unit: f64, price_per_unit: f64) -> Option<f64> {
    if !(miles.is_finite() && miles >= 0.0 && miles_per_unit > 0.0 && price_per_unit > 0.0) {
        return None;
    }
    Some(miles / miles_per_unit * price_per_unit)
}

/// Drive CO₂ in grams per mile from the vehicle's economy. `None` unless
/// `miles_per_unit` is positive, or for an unknown fuel code. Panics: none.
#[must_use]
pub fn drive_grams_co2_per_mile(fuel: u8, miles_per_unit: f64) -> Option<f64> {
    if fuel > FUEL_ELECTRIC || miles_per_unit <= 0.0 || miles_per_unit.is_nan() {
        return None;
    }
    Some(grams_co2_per_unit(fuel) / miles_per_unit)
}

// =============================================================================
// TripNeeds
// =============================================================================

const SPLITMIX_GAMMA: u64 = 0x9E37_79B9_7F4A_7C15;

/// The state a SplitMix64 generator starts in for `seed` (seed + γ, wrapping).
/// Panics: none.
#[must_use]
pub fn splitmix64_initial_state(seed: u64) -> u64 {
    seed.wrapping_add(SPLITMIX_GAMMA)
}

/// One SplitMix64 state step (state + γ, wrapping). Panics: none.
#[must_use]
pub fn splitmix64_advance(state: u64) -> u64 {
    state.wrapping_add(SPLITMIX_GAMMA)
}

/// The SplitMix64 output mix of an advanced state. Panics: none.
#[must_use]
pub fn splitmix64_mix(state: u64) -> u64 {
    let mut z = state;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

/// The deterministic generator behind the food-category draw: SplitMix64
/// seeded as the Swift `TripNeeds.SplitMix64` is (the seed is advanced once at
/// construction and again before every output).
#[derive(Clone, Debug)]
pub struct SplitMix64 {
    state: u64,
}

impl SplitMix64 {
    /// A generator for `seed`. Panics: none.
    #[must_use]
    pub fn new(seed: u64) -> Self {
        Self {
            state: splitmix64_initial_state(seed),
        }
    }

    /// The next 64-bit output. Panics: none.
    pub fn next_u64(&mut self) -> u64 {
        self.state = splitmix64_advance(self.state);
        splitmix64_mix(self.state)
    }
}

/// The label Swift's `TripNeeds.Need.label` gives a need code: the fuel's raw
/// value, `"Food · <category>"`, or `"Rest"`. `None` for an unknown code.
/// The schedule orders stops at the same mile by this text. Panics: none.
#[must_use]
pub fn need_label(code: u8) -> Option<String> {
    let (prefix, name) = need_label_parts(code)?;
    Some(format!("{prefix}{name}"))
}

fn need_label_parts(code: u8) -> Option<(&'static str, &'static str)> {
    match code {
        c if c <= FUEL_ELECTRIC => FUEL_TYPE_NAMES.get(usize::from(c)).map(|n| ("", *n)),
        NEED_REST => Some(("", "Rest")),
        c => {
            let i = usize::from(c.checked_sub(NEED_FOOD_BASE)?);
            FOOD_CATEGORY_NAMES.get(i).map(|n| ("Food \u{b7} ", *n))
        }
    }
}

/// Swift `String <` on the two labels. The labels are ASCII plus U+00B7 and
/// already NFC, where Swift's ordering is the UTF-8 byte order.
fn label_order(a: u8, b: u8) -> Ordering {
    let bytes = |c: u8| {
        let (p, n) = need_label_parts(c).unwrap_or(("", ""));
        p.bytes().chain(n.bytes())
    };
    bytes(a).cmp(bytes(b))
}

/// One scheduled stop: the trip mile it falls at and its need code.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScheduledNeed {
    /// Odometer mile along the trip.
    pub mile: f64,
    /// Need code (see the module docs).
    pub code: u8,
}

/// The most stops a schedule may hold. The Swift original has no bound and
/// runs until memory is gone when the trip length is infinite; past this many
/// stops the port returns the empty schedule instead. The editor's slider
/// floors keep a real schedule under about 2,300 stops on a 10,000-mile trip.
pub const SCHEDULE_STOP_CAP: usize = 1_000_000;

fn cadence_stops(interval: f64, total_miles: f64, budget: usize) -> Option<usize> {
    if interval <= 0.0 || interval.is_nan() {
        return Some(0);
    }
    let mut mile = interval;
    let mut n = 0usize;
    while mile < total_miles {
        n += 1;
        if n > budget {
            return None;
        }
        mile += interval;
    }
    Some(n)
}

/// The whole stop schedule for a trip, as `TripNeeds.schedule` builds it.
///
/// `intervals` are the gas, diesel, electric, food and rest cadences in miles;
/// a nil cadence is NaN (Swift skips a cadence that is nil or not positive, so
/// NaN is the same answer). Each cadence is unrolled by repeated addition,
/// `mile += interval` while `mile < total_miles`, in that order; every food
/// stop draws its category as `SplitMix64(seed) % 9`. Stops are then ordered by
/// mile, and at the same mile by label text. No two stops share both, so the
/// order is total.
///
/// Empty when `total_miles` is not positive, and empty past
/// [`SCHEDULE_STOP_CAP`] stops (where Swift would exhaust memory). Deterministic
/// for its arguments. Panics: none.
#[must_use]
pub fn schedule(total_miles: f64, intervals: &[f64; 5], seed: u64) -> Vec<ScheduledNeed> {
    if total_miles <= 0.0 || total_miles.is_nan() {
        return Vec::new();
    }
    let mut budget = SCHEDULE_STOP_CAP;
    let mut total = 0usize;
    for &interval in intervals {
        match cadence_stops(interval, total_miles, budget) {
            Some(n) => {
                budget -= n;
                total += n;
            }
            None => return Vec::new(),
        }
    }
    let mut events = Vec::with_capacity(total);
    let mut unroll = |interval: f64, need: &mut dyn FnMut() -> u8| {
        if interval <= 0.0 || interval.is_nan() {
            return;
        }
        let mut mile = interval;
        while mile < total_miles {
            events.push(ScheduledNeed { mile, code: need() });
            mile += interval;
        }
    };
    unroll(intervals[0], &mut || FUEL_GAS);
    unroll(intervals[1], &mut || FUEL_DIESEL);
    unroll(intervals[2], &mut || FUEL_ELECTRIC);
    let mut rng = SplitMix64::new(seed);
    let categories = FOOD_CATEGORY_NAMES.len() as u64;
    unroll(intervals[3], &mut || {
        // The remainder is below 9, so the narrowing is exact.
        NEED_FOOD_BASE + (rng.next_u64() % categories) as u8
    });
    unroll(intervals[4], &mut || NEED_REST);
    // Miles are never NaN here (cadences are positive and a stop is only
    // recorded while `mile < total_miles`), so `!=` then `<` is a total order.
    events.sort_by(|a, b| {
        if a.mile != b.mile {
            if a.mile < b.mile {
                Ordering::Less
            } else {
                Ordering::Greater
            }
        } else {
            label_order(a.code, b.code)
        }
    });
    events
}

/// Position of the first scheduled stop strictly past `after_mile` (Swift
/// `schedule.first { $0.mile > mile }`), or `None`. Panics: none.
#[must_use]
pub fn next_need_index(after_mile: f64, miles: &[f64]) -> Option<usize> {
    miles.iter().position(|&m| m > after_mile)
}

/// Remaining trip seconds with unplanned stopped time folded in:
/// `baseline + max(stop_delay, 0)` in Swift's `max` semantics (a NaN delay
/// propagates). Seconds in, seconds out. Panics: none.
#[must_use]
pub fn adjusted_remaining_seconds(baseline: f64, stop_delay_seconds: f64) -> f64 {
    baseline + smax(stop_delay_seconds, 0.0)
}

// =============================================================================
// CrashLogic
// =============================================================================

/// Moderate impact, in g: a spike this strong needs corroboration.
pub const IMPACT_G_FORCE: f64 = 5.0;
/// Hard impact, in g: fires without corroboration.
pub const HARD_IMPACT_G_FORCE: f64 = 8.0;
/// Corroboration level, in g, for the samples around a moderate impact.
pub const CONFIRM_IMPACT_G_FORCE: f64 = 2.5;
/// Road speed required just before an impact, in m/s (about 20 mph).
pub const MIN_PRE_IMPACT_SPEED_MPS: f64 = 8.9;
/// Near-standstill required just after, in m/s (about 10 mph).
pub const CRASH_STOP_SPEED_MPS: f64 = 4.5;
/// Fraction of the pre-impact speed that must be lost.
pub const MIN_SPEED_DROP_FRACTION: f64 = 0.55;
/// Farthest from the driven road corridor a crash is believed, in meters.
pub const MAX_METERS_FROM_ROAD: f64 = 60.0;

/// Replies that ask for help. Single words match whole words; entries with a
/// space match as substrings. Order is the Swift list's.
pub const ASSIST_WORDS: &[&str] = &[
    "yes",
    "yeah",
    "yep",
    "yup",
    "please",
    "help",
    "hurt",
    "injured",
    "bleeding",
    "trapped",
    "stuck",
    "can't move",
    "cant move",
    "call 911",
    "call nine one one",
    "call an ambulance",
    "ambulance",
    "i need help",
    "need help",
    "get help",
    "send help",
    "emergency",
    "sos",
    "mayday",
    "affirmative",
    "do it",
    "go ahead",
    "hurry",
];

/// Replies that stand the check-in down. Checked before [`ASSIST_WORDS`].
pub const OK_WORDS: &[&str] = &[
    "no",
    "nope",
    "nah",
    "negative",
    "i'm ok",
    "im ok",
    "i am ok",
    "i'm okay",
    "im okay",
    "i am okay",
    "we're ok",
    "were ok",
    "we're fine",
    "i'm fine",
    "im fine",
    "i am fine",
    "all good",
    "it's fine",
    "its fine",
    "i'm good",
    "im good",
    "i am good",
    "false alarm",
    "cancel",
    "stop asking",
    "dismiss",
    "never mind",
    "nevermind",
    "no thanks",
    "don't call",
    "dont call",
    "stand down",
];

/// One acceleration magnitude, in g, at or above the moderate-impact level.
/// Panics: none.
#[must_use]
pub fn is_impact_acceleration(acceleration_g: f64) -> bool {
    acceleration_g >= IMPACT_G_FORCE
}

/// The impact decision over a rolling window of acceleration magnitudes in g
/// (newest last): a peak at or above 8 g fires; a peak at or above 5 g fires
/// when at least three samples reach 2.5 g.
///
/// The peak is Swift's `max()`: the first sample, replaced by each later one it
/// is less than, so a leading NaN stays the peak (and fires nothing) while a
/// later NaN is passed over. An empty window is no impact. Panics: none.
#[must_use]
pub fn is_impact_window(window: &[f64]) -> bool {
    let Some((&first, rest)) = window.split_first() else {
        return false;
    };
    let mut peak = first;
    for &e in rest {
        if peak < e {
            peak = e;
        }
    }
    if peak >= HARD_IMPACT_G_FORCE {
        return true;
    }
    if peak < IMPACT_G_FORCE || peak.is_nan() {
        return false;
    }
    window
        .iter()
        .filter(|&&g| g >= CONFIRM_IMPACT_G_FORCE)
        .count()
        >= 3
}

/// The crash decision: an impact window, AND at least 8.9 m/s before, AND at
/// most 4.5 m/s after, AND a speed drop of at least 55% of
/// `max(before, 0.001)`, AND (when known) within 60 m of the road.
///
/// Speeds are m/s, distance meters; `None` distance is allowed, as is NaN
/// (it fails `> 60` the same way). Panics: none.
#[must_use]
pub fn is_crash(
    window: &[f64],
    speed_before_mps: f64,
    speed_after_mps: f64,
    meters_from_road: Option<f64>,
) -> bool {
    if !is_impact_window(window) {
        return false;
    }
    if speed_before_mps < MIN_PRE_IMPACT_SPEED_MPS || speed_before_mps.is_nan() {
        return false;
    }
    if speed_after_mps > CRASH_STOP_SPEED_MPS || speed_after_mps.is_nan() {
        return false;
    }
    let drop = (speed_before_mps - speed_after_mps) / smax(speed_before_mps, 0.001);
    if drop < MIN_SPEED_DROP_FRACTION || drop.is_nan() {
        return false;
    }
    if let Some(meters) = meters_from_road {
        if meters > MAX_METERS_FROM_ROAD {
            return false;
        }
    }
    true
}

/// Interpret a spoken reply to the crash check-in: `Some(true)` wants help,
/// `Some(false)` stands down, `None` is unclear (keep asking).
///
/// The transcript is lowercased; single vocabulary words match whole words
/// (runs of letter or apostrophe clusters), phrases match as substrings on
/// cluster boundaries. Stand-down words are checked first, so "no, I don't
/// need help" never asks for help. Panics: none.
#[must_use]
pub fn interpret_reply(transcript: &str) -> Option<bool> {
    let lower = swift_lowercased(transcript);
    let words = swift_words(&lower);
    let matches = |vocab: &[&str]| {
        vocab.iter().any(|entry| {
            if entry.contains(' ') {
                swift_contains(&lower, entry)
            } else {
                words.iter().any(|w| w == entry)
            }
        })
    };
    if matches(OK_WORDS) {
        return Some(false);
    }
    if matches(ASSIST_WORDS) {
        return Some(true);
    }
    None
}

// =============================================================================
// HOSRules
// =============================================================================

/// A 30-minute break is due after this much cumulative driving, in seconds (8 h).
pub const HOS_BREAK_DUE_SECONDS: f64 = 28_800.0;
/// The break warning opens this long before it is due, in seconds (30 min).
pub const HOS_WARN_BEFORE_BREAK_SECONDS: f64 = 1_800.0;
/// Driving stops at this much driving in the window, in seconds (11 h).
pub const HOS_DAILY_DRIVING_LIMIT_SECONDS: f64 = 39_600.0;
/// A stop at least this long resets the break clock, in seconds (30 min).
pub const HOS_BREAK_RESET_SECONDS: f64 = 1_800.0;

/// FMCSA hours-of-service state for the trucker timer.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum HosStatus {
    /// Nothing due.
    Ok,
    /// Inside the warning window; seconds until the break is due.
    BreakSoon {
        /// `28_800 - driving_seconds`.
        seconds_until_due: f64,
    },
    /// Eight hours reached.
    BreakDue,
    /// Eleven hours reached.
    LimitReached,
}

/// Hours-of-service status after `driving_seconds` of driving. Checked from
/// the limit down, as Swift; a NaN clock is `Ok`. Panics: none.
#[must_use]
pub fn hos_status(driving_seconds: f64) -> HosStatus {
    if driving_seconds >= HOS_DAILY_DRIVING_LIMIT_SECONDS {
        return HosStatus::LimitReached;
    }
    if driving_seconds >= HOS_BREAK_DUE_SECONDS {
        return HosStatus::BreakDue;
    }
    let until_due = HOS_BREAK_DUE_SECONDS - driving_seconds;
    if until_due <= HOS_WARN_BEFORE_BREAK_SECONDS {
        return HosStatus::BreakSoon {
            seconds_until_due: until_due,
        };
    }
    HosStatus::Ok
}

// =============================================================================
// VehicleSpecs
// =============================================================================

/// One row of the curated vehicle-spec table. Economy is miles per unit
/// (gallon, or kWh for electric); tank is gallons or usable kWh; height feet;
/// weights pounds; grade percent; speed mph. `None` is unpublished.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VehicleSpecRow {
    /// Maker name; a lookup key persisted in saved profiles, byte for byte.
    pub make: &'static str,
    /// Model name; a lookup key persisted in saved profiles, byte for byte.
    pub model: &'static str,
    /// Fuel code.
    pub fuel: u8,
    /// City economy.
    pub city_mpu: f64,
    /// Highway economy.
    pub highway_mpu: f64,
    /// Tank or usable battery size.
    pub tank_units: f64,
    /// Factory roof height.
    pub height_feet: f64,
    /// Gross vehicle weight rating.
    pub gvwr_lbs: Option<f64>,
    /// Tow capacity.
    pub tow_capacity_lbs: Option<f64>,
    /// Gross combined weight rating.
    pub gcwr_lbs: Option<f64>,
    /// Maker steep-grade guidance.
    pub published_max_grade_percent: Option<f64>,
    /// Manufacturer top speed.
    pub top_speed_mph: Option<f64>,
}

#[allow(clippy::too_many_arguments)]
const fn row(
    make: &'static str,
    model: &'static str,
    fuel: u8,
    city_mpu: f64,
    highway_mpu: f64,
    tank_units: f64,
    height_feet: f64,
    gvwr_lbs: Option<f64>,
    tow_capacity_lbs: Option<f64>,
    gcwr_lbs: Option<f64>,
    published_max_grade_percent: Option<f64>,
    top_speed_mph: Option<f64>,
) -> VehicleSpecRow {
    VehicleSpecRow {
        make,
        model,
        fuel,
        city_mpu,
        highway_mpu,
        tank_units,
        height_feet,
        gvwr_lbs,
        tow_capacity_lbs,
        gcwr_lbs,
        published_max_grade_percent,
        top_speed_mph,
    }
}

/// The curated table, in the Swift table's order (the editor's make and model
/// menus keep it). Generated from the frozen oracle.
#[rustfmt::skip]
pub const VEHICLE_SPECS: &[VehicleSpecRow] = &[
    row("Toyota", "Corolla", FUEL_GAS, 32.0, 41.0, 13.2, 4.8, Some(3910.0), Some(1500.0), None, None, None),
    row("Toyota", "Camry", FUEL_GAS, 28.0, 39.0, 15.8, 4.7, Some(4400.0), Some(1000.0), None, None, None),
    row("Toyota", "Prius", FUEL_GAS, 57.0, 56.0, 11.3, 4.8, Some(4025.0), Some(1750.0), None, None, None),
    row("Honda", "Civic", FUEL_GAS, 31.0, 40.0, 12.4, 4.6, Some(3968.0), Some(1000.0), None, None, None),
    row("Honda", "Accord", FUEL_GAS, 29.0, 37.0, 14.8, 4.7, Some(4295.0), Some(1000.0), None, None, None),
    row("Hyundai", "Elantra", FUEL_GAS, 32.0, 41.0, 12.4, 4.6, Some(3990.0), Some(1300.0), None, None, None),
    row("Nissan", "Altima", FUEL_GAS, 27.0, 37.0, 16.2, 4.7, Some(4390.0), Some(1000.0), None, None, None),
    row("Nissan", "Versa", FUEL_GAS, 32.0, 40.0, 10.8, 4.8, Some(3729.0), Some(900.0), None, None, None),
    row("Subaru", "Impreza", FUEL_GAS, 27.0, 34.0, 13.2, 4.8, Some(4145.0), Some(1200.0), None, None, None),
    row("Toyota", "RAV4", FUEL_GAS, 27.0, 35.0, 14.5, 5.6, Some(4750.0), Some(1500.0), Some(6005.0), None, None),
    row("Toyota", "Highlander", FUEL_GAS, 22.0, 29.0, 17.9, 5.7, Some(6000.0), Some(5000.0), Some(11000.0), None, None),
    row("Toyota", "4Runner", FUEL_GAS, 16.0, 19.0, 23.0, 6.0, Some(6300.0), Some(5000.0), Some(11300.0), None, None),
    row("Honda", "CR-V", FUEL_GAS, 28.0, 34.0, 14.0, 5.5, Some(4600.0), Some(1500.0), Some(6100.0), None, None),
    row("Honda", "Pilot", FUEL_GAS, 19.0, 27.0, 18.5, 5.9, Some(6054.0), Some(5000.0), Some(11200.0), None, None),
    row("Ford", "Explorer", FUEL_GAS, 21.0, 28.0, 17.9, 5.8, Some(6160.0), Some(5300.0), Some(11500.0), None, None),
    row("Ford", "Escape", FUEL_GAS, 27.0, 34.0, 14.8, 5.5, Some(4700.0), Some(3500.0), Some(8200.0), None, None),
    row("Chevrolet", "Equinox", FUEL_GAS, 26.0, 31.0, 14.9, 5.4, Some(4519.0), Some(1500.0), Some(6000.0), None, None),
    row("Chevrolet", "Tahoe", FUEL_GAS, 15.0, 20.0, 24.0, 6.3, Some(7500.0), Some(8400.0), Some(15000.0), None, None),
    row("Jeep", "Grand Cherokee", FUEL_GAS, 19.0, 26.0, 23.0, 5.9, Some(6500.0), Some(6200.0), Some(12700.0), None, None),
    row("Jeep", "Wrangler", FUEL_GAS, 20.0, 24.0, 21.5, 6.1, Some(5800.0), Some(3500.0), Some(9350.0), None, None),
    row("Subaru", "Outback", FUEL_GAS, 26.0, 32.0, 18.5, 5.6, Some(4915.0), Some(3500.0), Some(8400.0), None, None),
    row("Ford", "F-150", FUEL_GAS, 20.0, 26.0, 26.0, 6.4, Some(7050.0), Some(11200.0), Some(17100.0), None, None),
    row("Ford", "F-250 Super Duty (diesel)", FUEL_DIESEL, 15.0, 19.0, 34.0, 6.8, Some(10800.0), Some(20000.0), Some(30000.0), None, None),
    row("Chevrolet", "Silverado 1500", FUEL_GAS, 19.0, 24.0, 24.0, 6.3, Some(7200.0), Some(9500.0), Some(16000.0), None, None),
    row("Chevrolet", "Silverado 2500HD (diesel)", FUEL_DIESEL, 14.0, 18.0, 36.0, 6.7, Some(11350.0), Some(18500.0), Some(27500.0), None, None),
    row("Ram", "1500", FUEL_GAS, 20.0, 25.0, 26.0, 6.5, Some(6900.0), Some(8300.0), Some(14950.0), None, None),
    row("Ram", "2500 (diesel)", FUEL_DIESEL, 14.0, 19.0, 32.0, 6.7, Some(10000.0), Some(19990.0), Some(28300.0), None, None),
    row("Toyota", "Tacoma", FUEL_GAS, 20.0, 26.0, 18.2, 6.0, Some(5600.0), Some(6500.0), Some(11360.0), None, None),
    row("Toyota", "Tundra", FUEL_GAS, 18.0, 23.0, 22.5, 6.5, Some(7210.0), Some(11500.0), Some(17870.0), None, None),
    row("GMC", "Sierra 1500", FUEL_GAS, 19.0, 24.0, 24.0, 6.3, Some(7200.0), Some(9500.0), Some(16000.0), None, None),
    row("Ford", "Transit (low roof)", FUEL_GAS, 15.0, 19.0, 25.0, 6.9, Some(9070.0), Some(5000.0), Some(14000.0), None, None),
    row("Ford", "Transit (high roof)", FUEL_GAS, 15.0, 19.0, 25.0, 9.1, Some(9500.0), Some(4500.0), Some(14000.0), None, None),
    row("Mercedes-Benz", "Sprinter (standard roof, diesel)", FUEL_DIESEL, 19.0, 23.0, 24.5, 7.9, Some(9050.0), Some(5000.0), Some(13550.0), None, None),
    row("Mercedes-Benz", "Sprinter (high roof, diesel)", FUEL_DIESEL, 19.0, 23.0, 24.5, 9.0, Some(9990.0), Some(5000.0), Some(15250.0), None, None),
    row("Ram", "ProMaster (high roof)", FUEL_GAS, 14.0, 18.0, 24.0, 8.6, Some(9350.0), Some(6910.0), Some(16255.0), None, None),
    row("Ford", "E-450 Econoline cutaway", FUEL_GAS, 8.0, 11.0, 55.0, 10.5, Some(14500.0), Some(10000.0), Some(22000.0), Some(8.0), None),
    row("Mercedes-Benz", "Sprinter 3500 (diesel)", FUEL_DIESEL, 17.0, 21.0, 24.5, 9.1, Some(11030.0), Some(7500.0), Some(15250.0), None, None),
    row("Chrysler", "Pacifica", FUEL_GAS, 19.0, 28.0, 19.0, 5.8, Some(6055.0), Some(3600.0), Some(9650.0), None, None),
    row("Honda", "Odyssey", FUEL_GAS, 19.0, 28.0, 19.5, 5.8, Some(6019.0), Some(3500.0), Some(9542.0), None, None),
    row("Tesla", "Model 3", FUEL_ELECTRIC, 4.4, 4.0, 58.0, 4.7, Some(4960.0), Some(2000.0), None, None, None),
    row("Tesla", "Model Y", FUEL_ELECTRIC, 4.1, 3.7, 75.0, 5.3, Some(5525.0), Some(3500.0), None, None, None),
    row("Ford", "Mustang Mach-E", FUEL_ELECTRIC, 3.9, 3.4, 72.0, 5.3, Some(5544.0), Some(2300.0), None, None, None),
    row("Ford", "F-150 Lightning", FUEL_ELECTRIC, 2.3, 1.9, 98.0, 6.5, Some(8250.0), Some(10000.0), Some(19500.0), None, None),
    row("Hyundai", "Ioniq 5", FUEL_ELECTRIC, 4.0, 3.4, 74.0, 5.3, Some(5390.0), Some(2300.0), None, None, None),
    row("Chevrolet", "Equinox EV", FUEL_ELECTRIC, 3.9, 3.3, 85.0, 5.4, Some(5850.0), Some(1500.0), None, None, None),
    row("Rivian", "R1T", FUEL_ELECTRIC, 2.6, 2.2, 128.0, 6.0, Some(8532.0), Some(11000.0), Some(20000.0), None, None),
    row("RV", "Class C motorhome", FUEL_GAS, 9.0, 11.0, 55.0, 11.0, Some(14500.0), Some(7500.0), Some(22000.0), Some(8.0), None),
    row("RV", "Class A motorhome (diesel)", FUEL_DIESEL, 7.0, 9.0, 100.0, 12.5, Some(32000.0), Some(10000.0), Some(42000.0), Some(7.0), None),
    row("Generic", "Sedan", FUEL_GAS, 28.0, 38.0, 14.5, 4.7, Some(4300.0), Some(1000.0), None, None, None),
    row("Generic", "SUV", FUEL_GAS, 22.0, 28.0, 17.5, 5.7, Some(6200.0), Some(5000.0), None, None, None),
    row("Generic", "Pickup truck", FUEL_GAS, 19.0, 24.0, 25.0, 6.4, Some(7000.0), Some(9000.0), Some(15500.0), None, None),
    row("Generic", "Cargo van", FUEL_GAS, 15.0, 19.0, 25.0, 8.5, Some(9000.0), Some(6000.0), None, None, None),
    row("Generic", "Bus", FUEL_DIESEL, 6.0, 8.0, 100.0, 10.5, Some(36200.0), Some(10000.0), Some(46200.0), Some(7.0), None),
    row("Generic", "Motorhome (Class A)", FUEL_DIESEL, 7.0, 9.0, 100.0, 12.5, Some(32000.0), Some(10000.0), Some(42000.0), Some(7.0), None),
    row("Freightliner", "Cascadia (semi)", FUEL_DIESEL, 6.0, 7.5, 240.0, 13.5, Some(35000.0), Some(45000.0), Some(80000.0), Some(6.0), None),
    row("Peterbilt", "579 (semi)", FUEL_DIESEL, 6.0, 7.5, 240.0, 13.5, Some(35000.0), Some(45000.0), Some(80000.0), Some(6.0), None),
    row("Kenworth", "T680 (semi)", FUEL_DIESEL, 6.0, 7.5, 240.0, 13.5, Some(35000.0), Some(45000.0), Some(80000.0), Some(6.0), None),
    row("Volvo", "VNL (semi)", FUEL_DIESEL, 6.2, 7.8, 240.0, 13.5, Some(35000.0), Some(45000.0), Some(80000.0), Some(6.0), None),
    row("International", "LT (semi)", FUEL_DIESEL, 6.0, 7.4, 240.0, 13.5, Some(35000.0), Some(45000.0), Some(80000.0), Some(6.0), None),
    row("Box truck", "26 ft straight truck", FUEL_DIESEL, 8.0, 10.0, 60.0, 13.0, Some(25999.0), Some(8000.0), Some(33500.0), Some(8.0), None),
    row("Box truck", "16 ft box truck", FUEL_GAS, 9.0, 12.0, 33.0, 12.0, Some(14500.0), Some(6000.0), Some(20500.0), Some(8.0), None),
];

/// Swift `String ==` between arbitrary input and an ASCII table key. Swift
/// compares canonical equivalents; the only scalars whose decomposition is
/// ASCII are ASCII itself and the singletons U+212A (K), U+037E (;) and
/// U+1FEF (`), so mapping those is exact for an ASCII key.
fn swift_equals_ascii_key(input: &str, key: &str) -> bool {
    let mut k = key.bytes();
    for c in input.chars() {
        let folded = match c {
            '\u{212A}' => 'K',
            '\u{037E}' => ';',
            '\u{1FEF}' => '`',
            other => other,
        };
        match (u8::try_from(u32::from(folded)), k.next()) {
            (Ok(b), Some(kb)) if b == kb => {}
            _ => return false,
        }
    }
    k.next().is_none()
}

/// Distinct makes in table order (the make menu). Panics: none.
#[must_use]
pub fn vehicle_makes() -> Vec<&'static str> {
    let mut out: Vec<&'static str> = Vec::new();
    for r in VEHICLE_SPECS {
        if !out.contains(&r.make) {
            out.push(r.make);
        }
    }
    out
}

/// Table positions of every row whose make equals `make` under Swift string
/// equality, in table order (the model menu). Panics: none.
#[must_use]
pub fn vehicle_spec_rows_for_make(make: &str) -> Vec<usize> {
    VEHICLE_SPECS
        .iter()
        .enumerate()
        .filter(|(_, r)| swift_equals_ascii_key(make, r.make))
        .map(|(i, _)| i)
        .collect()
}

/// Table position of the first row matching `make` and `model` under Swift
/// string equality, or `None`. Panics: none.
#[must_use]
pub fn vehicle_spec_index(make: &str, model: &str) -> Option<usize> {
    VEHICLE_SPECS.iter().position(|r| {
        swift_equals_ascii_key(make, r.make) && swift_equals_ascii_key(model, r.model)
    })
}

/// The lowest factory height in the table, in feet (the height slider's
/// floor): Swift `min()`, first-minimum, 4.5 for an empty table. Panics: none.
#[must_use]
pub fn minimum_height_feet() -> f64 {
    let Some((first, rest)) = VEHICLE_SPECS.split_first() else {
        return 4.5;
    };
    let mut low = first.height_feet;
    for r in rest {
        if r.height_feet < low {
            low = r.height_feet;
        }
    }
    low
}

/// EPA combined economy, `1 / (0.55 / city + 0.45 / highway)`, in the
/// economy's own units. Panics: none.
#[must_use]
pub fn combined_miles_per_unit(city_mpu: f64, highway_mpu: f64) -> f64 {
    1.0 / (0.55 / city_mpu + 0.45 / highway_mpu)
}

/// Swift `(x * 10).rounded() / 10`: to the nearest tenth, halves away from
/// zero. Panics: none.
#[must_use]
pub fn round_to_tenth(x: f64) -> f64 {
    (x * 10.0).round() / 10.0
}

/// The rated economy a spec writes into a new profile: the combined figure
/// rounded to a tenth. Persisted as `ratedMilesPerUnit`. Panics: none.
#[must_use]
pub fn rated_miles_per_unit(city_mpu: f64, highway_mpu: f64) -> f64 {
    round_to_tenth(combined_miles_per_unit(city_mpu, highway_mpu))
}

// =============================================================================
// VehicleProfile and VehicleStore
// =============================================================================

/// Safety reserve kept when deciding to recommend fuel, in miles.
pub const RESERVE_MILES: f64 = 40.0;

/// The economy fields of a saved vehicle profile. Presence matters: the
/// speed curve needs both city and highway, while the range model only asks
/// whether city is present.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VehicleEconomy {
    /// Tank or battery size in fuel units.
    pub tank_capacity_units: f64,
    /// Rated combined miles per unit.
    pub rated_miles_per_unit: f64,
    /// City miles per unit, when the spec table supplied it.
    pub city_miles_per_unit: Option<f64>,
    /// Highway miles per unit, when the spec table supplied it.
    pub highway_miles_per_unit: Option<f64>,
}

/// Habit multiplier on economy: `-1.2%` per mph above 55, idling costs half
/// its fraction, clamped to [0.5, 1] in Swift's `min`/`max` order. Panics: none.
#[must_use]
pub fn efficiency_factor(average_speed_mph: f64, idle_fraction: f64) -> f64 {
    let speed_penalty = smax(average_speed_mph - 55.0, 0.0) * 0.012;
    let idle_penalty = smin(smax(idle_fraction, 0.0), 1.0) * 0.5;
    smin(smax(1.0 - speed_penalty - idle_penalty, 0.5), 1.0)
}

impl VehicleEconomy {
    /// Full-tank range at rated economy, `tank * rated`, in miles. Panics: none.
    #[must_use]
    pub fn rated_range_miles(&self) -> f64 {
        self.tank_capacity_units * self.rated_miles_per_unit
    }

    /// Speed-aware economy in miles per unit: city below 30 mph, a linear
    /// ramp to highway by 55, highway to 65, then `-1.2%` per mph floored at
    /// 60% of highway. The rated figure unless both city and highway are
    /// present. `mph` below each bound is Swift's `..<` (a NaN speed takes the
    /// last case). Panics: none.
    #[must_use]
    pub fn miles_per_unit_at_speed(&self, mph: f64) -> f64 {
        let (Some(city), Some(highway)) = (self.city_miles_per_unit, self.highway_miles_per_unit)
        else {
            return self.rated_miles_per_unit;
        };
        if mph < 30.0 {
            city
        } else if mph < 55.0 {
            city + (highway - city) * (mph - 30.0) / 25.0
        } else if mph < 65.0 {
            highway
        } else {
            smax(highway * (1.0 - (mph - 65.0) * 0.012), highway * 0.6)
        }
    }

    /// Full-tank range at the given habits, in miles. With a city figure: tank
    /// × speed-aware economy × the idle factor; otherwise rated range × the
    /// habit factor. Panics: none.
    #[must_use]
    pub fn effective_range_miles(&self, average_speed_mph: f64, idle_fraction: f64) -> f64 {
        if self.city_miles_per_unit.is_some() {
            let idle_factor = smin(smax(1.0 - sunit(idle_fraction) * 0.5, 0.5), 1.0);
            return self.tank_capacity_units
                * self.miles_per_unit_at_speed(average_speed_mph)
                * idle_factor;
        }
        self.rated_range_miles() * efficiency_factor(average_speed_mph, idle_fraction)
    }

    /// Fraction of a tank left after `miles_since_fill`, clamped to [0, 1]; 0
    /// when the effective range is not positive. Panics: none.
    #[must_use]
    pub fn fuel_fraction_after(
        &self,
        miles_since_fill: f64,
        average_speed_mph: f64,
        idle_fraction: f64,
    ) -> f64 {
        let range = self.effective_range_miles(average_speed_mph, idle_fraction);
        if range <= 0.0 || range.is_nan() {
            return 0.0;
        }
        sunit(1.0 - miles_since_fill / range)
    }

    /// Miles left in the tank, `max(effective range - miles since fill, 0)`.
    /// Panics: none.
    #[must_use]
    pub fn expected_range_miles(
        &self,
        miles_since_fill: f64,
        average_speed_mph: f64,
        idle_fraction: f64,
    ) -> f64 {
        smax(
            self.effective_range_miles(average_speed_mph, idle_fraction) - miles_since_fill,
            0.0,
        )
    }
}

/// Recommend fuel when `range - reserve <= miles to the next station`
/// (the boundary counts). Panics: none.
#[must_use]
pub fn should_recommend_fuel(
    range_remaining_miles: f64,
    miles_to_next_station: f64,
    reserve_miles: f64,
) -> bool {
    range_remaining_miles - reserve_miles <= miles_to_next_station
}

/// The learned driving state `VehicleStore` keeps: tank miles since the last
/// fill (normal-economy equivalents), and the rolling average speed (mph) and
/// idle fraction.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DrivingHabits {
    /// Miles charged against the tank since the last fill.
    pub miles_since_fill: f64,
    /// Exponentially weighted average moving speed, mph.
    pub average_speed_mph: f64,
    /// Exponentially weighted fraction of fixes at or below 1 mph.
    pub idle_fraction: f64,
}

const HABIT_ALPHA: f64 = 0.0003;

/// One GPS fix folded into the habits, as `VehicleStore.recordFix`: the
/// distance (floored at 0, meters to miles) is charged at the towing economy
/// when towing; the speed (floored at 0, m/s to mph) moves the average when
/// above 1 mph; the idle fraction always moves, toward 1 at or below 1 mph.
/// Swift `max` semantics throughout, so a NaN input propagates as it did.
/// Panics: none.
#[must_use]
pub fn record_fix(
    habits: DrivingHabits,
    speed_mps: f64,
    delta_meters: f64,
    towing: bool,
    towing_economy_factor: f64,
) -> DrivingHabits {
    let miles = smax(delta_meters, 0.0) / 1609.344;
    let miles_since_fill = habits.miles_since_fill
        + if towing {
            miles / towing_economy_factor
        } else {
            miles
        };
    let mph = smax(speed_mps, 0.0) * 2.236936;
    let average_speed_mph = if mph > 1.0 {
        habits.average_speed_mph * (1.0 - HABIT_ALPHA) + mph * HABIT_ALPHA
    } else {
        habits.average_speed_mph
    };
    let idle = if mph <= 1.0 { 1.0 } else { 0.0 };
    let idle_fraction = habits.idle_fraction * (1.0 - HABIT_ALPHA) + idle * HABIT_ALPHA;
    DrivingHabits {
        miles_since_fill,
        average_speed_mph,
        idle_fraction,
    }
}

/// Whether a persisted speed/idle shape may be resumed: a finite, positive
/// average speed and a finite idle fraction. Panics: none.
#[must_use]
pub fn restore_driving_accepts(average_speed_mph: f64, idle_fraction: f64) -> bool {
    average_speed_mph.is_finite() && average_speed_mph > 0.0 && idle_fraction.is_finite()
}

/// The idle fraction a resumed shape keeps: Swift `min(max(x, 0), 1)`.
/// Panics: none.
#[must_use]
pub fn restore_driving_idle(idle_fraction: f64) -> f64 {
    sunit(idle_fraction)
}

/// The range the app acts on, `VehicleStore.expectedRangeMiles` for a store
/// with a profile: with a telemetry fuel fraction, full effective range ×
/// the clamped fraction; otherwise the odometer model. Either way multiplied
/// by the towing factor when towing (by 1 otherwise), left to right. Miles.
/// Panics: none.
#[must_use]
pub fn store_expected_range_miles(
    economy: &VehicleEconomy,
    habits: DrivingHabits,
    telemetry_fuel_fraction: Option<f64>,
    towing: bool,
    towing_economy_factor: f64,
) -> f64 {
    let towing_multiplier = if towing { towing_economy_factor } else { 1.0 };
    if let Some(fraction) = telemetry_fuel_fraction {
        let full = economy.effective_range_miles(habits.average_speed_mph, habits.idle_fraction);
        return full * sunit(fraction) * towing_multiplier;
    }
    economy.expected_range_miles(
        habits.miles_since_fill,
        habits.average_speed_mph,
        habits.idle_fraction,
    ) * towing_multiplier
}

// =============================================================================
// EPAClassSpecs
// =============================================================================

/// Typical physical specs for an EPA vehicle class: tank gallons, height feet,
/// and GVWR and tow capacity in pounds where the class has a typical figure.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ClassPhysical {
    /// Tank, gallons.
    pub tank: f64,
    /// Height, feet.
    pub height: f64,
    /// Gross vehicle weight rating, pounds.
    pub gvwr: Option<f64>,
    /// Tow capacity, pounds.
    pub tow_capacity: Option<f64>,
}

const fn physical(tank: f64, height: f64, gvwr: Option<f64>, tow: Option<f64>) -> ClassPhysical {
    ClassPhysical {
        tank,
        height,
        gvwr,
        tow_capacity: tow,
    }
}

/// Map an EPA `VClass` string to typical specs by the Swift substring ladder,
/// first match wins: pickup; sport utility or suv; van (passenger vans are
/// lower); minivan; wagon; compact, subcompact, mini or two seater; large;
/// otherwise sedan-shaped. The minivan rung is unreachable because every
/// "minivan" contains "van" first, exactly as in Swift. Panics: none.
#[must_use]
pub fn epa_class_physical(vclass: &str) -> ClassPhysical {
    let lower = swift_lowercased(vclass);
    let has = |needle: &str| swift_contains(&lower, needle);
    if has("pickup") {
        return physical(25.0, 6.4, Some(7000.0), Some(9000.0));
    }
    if has("sport utility") || has("suv") {
        return physical(17.5, 5.7, Some(6200.0), Some(5000.0));
    }
    if has("van") {
        let height = if has("passenger") { 6.8 } else { 8.5 };
        return physical(25.0, height, Some(9000.0), Some(6000.0));
    }
    if has("minivan") {
        return physical(19.0, 5.8, Some(6100.0), Some(3500.0));
    }
    if has("wagon") {
        return physical(15.5, 5.0, None, None);
    }
    if has("compact") || has("subcompact") || has("mini") || has("two seater") {
        return physical(12.5, 4.7, None, None);
    }
    if has("large") {
        return physical(17.0, 4.8, None, None);
    }
    physical(14.5, 4.7, None, None)
}

/// Clamp a class-typical tank so implied range stays within 650 miles: past
/// that, `600 / combined` rounded to a tenth. Panics: none.
#[must_use]
pub fn epa_validated_tank(tank: f64, combined_mpu: f64) -> f64 {
    let implied_range = tank * combined_mpu;
    if implied_range > 650.0 {
        return round_to_tenth(600.0 / combined_mpu);
    }
    tank
}

/// EPA `fuelType1` text to a fuel code: electric if it mentions
/// "electricity", else diesel if "diesel", else gas. Panics: none.
#[must_use]
pub fn epa_fuel_type(fuel: &str) -> u8 {
    let lower = swift_lowercased(fuel);
    if swift_contains(&lower, "electricity") {
        return FUEL_ELECTRIC;
    }
    if swift_contains(&lower, "diesel") {
        return FUEL_DIESEL;
    }
    FUEL_GAS
}

// =============================================================================
// Swift text semantics
// =============================================================================

/// Swift `String.lowercased()`: each scalar's full lowercase mapping, with no
/// context (a word-final capital sigma becomes σ, not ς). Panics: none.
#[must_use]
pub fn swift_lowercased(s: &str) -> String {
    s.chars().flat_map(char::to_lowercase).collect()
}

/// Private-use scalars Apple's Swift runtime reports as letters, which the
/// Unicode Alphabetic property (and Rust's `char::is_alphabetic`) does not.
const SWIFT_EXTRA_LETTERS: &[(u32, u32)] = &[
    (0xF882, 0xF882),
    (0xF89A, 0xF89E),
    (0xF8A2, 0xF8A7),
    (0xF8B8, 0xF8B8),
    (0xF8C1, 0xF8D6),
];

/// Scalars that join the grapheme cluster before them (Extend, ZWJ,
/// SpacingMark): every scalar `c` for which Swift counts `"a" + c` as one
/// Character. Swept from the Swift runtime; checked by the oracle.
#[rustfmt::skip]
const GRAPHEME_ATTACH: &[(u32, u32)] = &[
    (0x0300, 0x036F), (0x0483, 0x0489), (0x0591, 0x05BD), (0x05BF, 0x05BF), (0x05C1, 0x05C2),
    (0x05C4, 0x05C5), (0x05C7, 0x05C7), (0x0610, 0x061A), (0x064B, 0x065F), (0x0670, 0x0670),
    (0x06D6, 0x06DC), (0x06DF, 0x06E4), (0x06E7, 0x06E8), (0x06EA, 0x06ED), (0x0711, 0x0711),
    (0x0730, 0x074A), (0x07A6, 0x07B0), (0x07EB, 0x07F3), (0x07FD, 0x07FD), (0x0816, 0x0819),
    (0x081B, 0x0823), (0x0825, 0x0827), (0x0829, 0x082D), (0x0859, 0x085B), (0x0897, 0x089F),
    (0x08CA, 0x08E1), (0x08E3, 0x0903), (0x093A, 0x093C), (0x093E, 0x094F), (0x0951, 0x0957),
    (0x0962, 0x0963), (0x0981, 0x0983), (0x09BC, 0x09BC), (0x09BE, 0x09C4), (0x09C7, 0x09C8),
    (0x09CB, 0x09CD), (0x09D7, 0x09D7), (0x09E2, 0x09E3), (0x09FE, 0x09FE), (0x0A01, 0x0A03),
    (0x0A3C, 0x0A3C), (0x0A3E, 0x0A42), (0x0A47, 0x0A48), (0x0A4B, 0x0A4D), (0x0A51, 0x0A51),
    (0x0A70, 0x0A71), (0x0A75, 0x0A75), (0x0A81, 0x0A83), (0x0ABC, 0x0ABC), (0x0ABE, 0x0AC5),
    (0x0AC7, 0x0AC9), (0x0ACB, 0x0ACD), (0x0AE2, 0x0AE3), (0x0AFA, 0x0AFF), (0x0B01, 0x0B03),
    (0x0B3C, 0x0B3C), (0x0B3E, 0x0B44), (0x0B47, 0x0B48), (0x0B4B, 0x0B4D), (0x0B55, 0x0B57),
    (0x0B62, 0x0B63), (0x0B82, 0x0B82), (0x0BBE, 0x0BC2), (0x0BC6, 0x0BC8), (0x0BCA, 0x0BCD),
    (0x0BD7, 0x0BD7), (0x0C00, 0x0C04), (0x0C3C, 0x0C3C), (0x0C3E, 0x0C44), (0x0C46, 0x0C48),
    (0x0C4A, 0x0C4D), (0x0C55, 0x0C56), (0x0C62, 0x0C63), (0x0C81, 0x0C83), (0x0CBC, 0x0CBC),
    (0x0CBE, 0x0CC4), (0x0CC6, 0x0CC8), (0x0CCA, 0x0CCD), (0x0CD5, 0x0CD6), (0x0CE2, 0x0CE3),
    (0x0CF3, 0x0CF3), (0x0D00, 0x0D03), (0x0D3B, 0x0D3C), (0x0D3E, 0x0D44), (0x0D46, 0x0D48),
    (0x0D4A, 0x0D4D), (0x0D57, 0x0D57), (0x0D62, 0x0D63), (0x0D81, 0x0D83), (0x0DCA, 0x0DCA),
    (0x0DCF, 0x0DD4), (0x0DD6, 0x0DD6), (0x0DD8, 0x0DDF), (0x0DF2, 0x0DF3), (0x0E31, 0x0E31),
    (0x0E33, 0x0E3A), (0x0E47, 0x0E4E), (0x0EB1, 0x0EB1), (0x0EB3, 0x0EBC), (0x0EC8, 0x0ECE),
    (0x0F18, 0x0F19), (0x0F35, 0x0F35), (0x0F37, 0x0F37), (0x0F39, 0x0F39), (0x0F3E, 0x0F3F),
    (0x0F71, 0x0F84), (0x0F86, 0x0F87), (0x0F8D, 0x0F97), (0x0F99, 0x0FBC), (0x0FC6, 0x0FC6),
    (0x102D, 0x1037), (0x1039, 0x103E), (0x1056, 0x1059), (0x105E, 0x1060), (0x1071, 0x1074),
    (0x1082, 0x1082), (0x1084, 0x1086), (0x108D, 0x108D), (0x109D, 0x109D), (0x135D, 0x135F),
    (0x1712, 0x1715), (0x1732, 0x1734), (0x1752, 0x1753), (0x1772, 0x1773), (0x17B4, 0x17D3),
    (0x17DD, 0x17DD), (0x180B, 0x180D), (0x180F, 0x180F), (0x1885, 0x1886), (0x18A9, 0x18A9),
    (0x1920, 0x192B), (0x1930, 0x193B), (0x1A17, 0x1A1B), (0x1A55, 0x1A5E), (0x1A60, 0x1A60),
    (0x1A62, 0x1A62), (0x1A65, 0x1A7C), (0x1A7F, 0x1A7F), (0x1AB0, 0x1ADD), (0x1AE0, 0x1AEB),
    (0x1B00, 0x1B04), (0x1B34, 0x1B44), (0x1B6B, 0x1B73), (0x1B80, 0x1B82), (0x1BA1, 0x1BAD),
    (0x1BE6, 0x1BF3), (0x1C24, 0x1C37), (0x1CD0, 0x1CD2), (0x1CD4, 0x1CE8), (0x1CED, 0x1CED),
    (0x1CF4, 0x1CF4), (0x1CF7, 0x1CF9), (0x1DC0, 0x1DFF), (0x200C, 0x200D), (0x20D0, 0x20F0),
    (0x2CEF, 0x2CF1), (0x2D7F, 0x2D7F), (0x2DE0, 0x2DFF), (0x302A, 0x302F), (0x3099, 0x309A),
    (0xA66F, 0xA672), (0xA674, 0xA67D), (0xA69E, 0xA69F), (0xA6F0, 0xA6F1), (0xA802, 0xA802),
    (0xA806, 0xA806), (0xA80B, 0xA80B), (0xA823, 0xA827), (0xA82C, 0xA82C), (0xA880, 0xA881),
    (0xA8B4, 0xA8C5), (0xA8E0, 0xA8F1), (0xA8FF, 0xA8FF), (0xA926, 0xA92D), (0xA947, 0xA953),
    (0xA980, 0xA983), (0xA9B3, 0xA9C0), (0xA9E5, 0xA9E5), (0xAA29, 0xAA36), (0xAA43, 0xAA43),
    (0xAA4C, 0xAA4D), (0xAA7C, 0xAA7C), (0xAAB0, 0xAAB0), (0xAAB2, 0xAAB4), (0xAAB7, 0xAAB8),
    (0xAABE, 0xAABF), (0xAAC1, 0xAAC1), (0xAAEB, 0xAAEF), (0xAAF5, 0xAAF6), (0xABE3, 0xABEA),
    (0xABEC, 0xABED), (0xFB1E, 0xFB1E), (0xFE00, 0xFE0F), (0xFE20, 0xFE2F), (0xFF9E, 0xFF9F),
    (0x101FD, 0x101FD), (0x102E0, 0x102E0), (0x10376, 0x1037A), (0x10A01, 0x10A03), (0x10A05, 0x10A06),
    (0x10A0C, 0x10A0F), (0x10A38, 0x10A3A), (0x10A3F, 0x10A3F), (0x10AE5, 0x10AE6), (0x10D24, 0x10D27),
    (0x10D69, 0x10D6D), (0x10EAB, 0x10EAC), (0x10EFA, 0x10EFF), (0x10F46, 0x10F50), (0x10F82, 0x10F85),
    (0x11000, 0x11002), (0x11038, 0x11046), (0x11070, 0x11070), (0x11073, 0x11074), (0x1107F, 0x11082),
    (0x110B0, 0x110BA), (0x110C2, 0x110C2), (0x11100, 0x11102), (0x11127, 0x11134), (0x11145, 0x11146),
    (0x11173, 0x11173), (0x11180, 0x11182), (0x111B3, 0x111C0), (0x111C9, 0x111CC), (0x111CE, 0x111CF),
    (0x1122C, 0x11237), (0x1123E, 0x1123E), (0x11241, 0x11241), (0x112DF, 0x112EA), (0x11300, 0x11303),
    (0x1133B, 0x1133C), (0x1133E, 0x11344), (0x11347, 0x11348), (0x1134B, 0x1134D), (0x11357, 0x11357),
    (0x11362, 0x11363), (0x11366, 0x1136C), (0x11370, 0x11374), (0x113B8, 0x113C0), (0x113C2, 0x113C2),
    (0x113C5, 0x113C5), (0x113C7, 0x113CA), (0x113CC, 0x113D0), (0x113D2, 0x113D2), (0x113E1, 0x113E2),
    (0x11435, 0x11446), (0x1145E, 0x1145E), (0x114B0, 0x114C3), (0x115AF, 0x115B5), (0x115B8, 0x115C0),
    (0x115DC, 0x115DD), (0x11630, 0x11640), (0x116AB, 0x116B7), (0x1171D, 0x1171F), (0x11722, 0x1172B),
    (0x1182C, 0x1183A), (0x11930, 0x11935), (0x11937, 0x11938), (0x1193B, 0x1193E), (0x11940, 0x11940),
    (0x11942, 0x11943), (0x119D1, 0x119D7), (0x119DA, 0x119E0), (0x119E4, 0x119E4), (0x11A01, 0x11A0A),
    (0x11A33, 0x11A39), (0x11A3B, 0x11A3E), (0x11A47, 0x11A47), (0x11A51, 0x11A5B), (0x11A8A, 0x11A99),
    (0x11B60, 0x11B67), (0x11C2F, 0x11C36), (0x11C38, 0x11C3F), (0x11C92, 0x11CA7), (0x11CA9, 0x11CB6),
    (0x11D31, 0x11D36), (0x11D3A, 0x11D3A), (0x11D3C, 0x11D3D), (0x11D3F, 0x11D45), (0x11D47, 0x11D47),
    (0x11D8A, 0x11D8E), (0x11D90, 0x11D91), (0x11D93, 0x11D97), (0x11EF3, 0x11EF6), (0x11F00, 0x11F01),
    (0x11F03, 0x11F03), (0x11F34, 0x11F3A), (0x11F3E, 0x11F42), (0x11F5A, 0x11F5A), (0x13440, 0x13440),
    (0x13447, 0x13455), (0x1611E, 0x1612F), (0x16AF0, 0x16AF4), (0x16B30, 0x16B36), (0x16F4F, 0x16F4F),
    (0x16F51, 0x16F87), (0x16F8F, 0x16F92), (0x16FE4, 0x16FE4), (0x16FF0, 0x16FF1), (0x1BC9D, 0x1BC9E),
    (0x1CF00, 0x1CF2D), (0x1CF30, 0x1CF46), (0x1D165, 0x1D169), (0x1D16D, 0x1D172), (0x1D17B, 0x1D182),
    (0x1D185, 0x1D18B), (0x1D1AA, 0x1D1AD), (0x1D242, 0x1D244), (0x1DA00, 0x1DA36), (0x1DA3B, 0x1DA6C),
    (0x1DA75, 0x1DA75), (0x1DA84, 0x1DA84), (0x1DA9B, 0x1DA9F), (0x1DAA1, 0x1DAAF), (0x1E000, 0x1E006),
    (0x1E008, 0x1E018), (0x1E01B, 0x1E021), (0x1E023, 0x1E024), (0x1E026, 0x1E02A), (0x1E08F, 0x1E08F),
    (0x1E130, 0x1E136), (0x1E2AE, 0x1E2AE), (0x1E2EC, 0x1E2EF), (0x1E4EC, 0x1E4EF), (0x1E5EE, 0x1E5EF),
    (0x1E6E3, 0x1E6E3), (0x1E6E6, 0x1E6E6), (0x1E6EE, 0x1E6EF), (0x1E6F5, 0x1E6F5), (0x1E8D0, 0x1E8D6),
    (0x1E944, 0x1E94A), (0x1F3FB, 0x1F3FF), (0xE0020, 0xE007F), (0xE0100, 0xE01EF),
];

/// Scalars that join the cluster after them (Prepend): every `c` for which
/// Swift counts `c + "a"` as one Character.
#[rustfmt::skip]
const GRAPHEME_PREPEND: &[(u32, u32)] = &[
    (0x0600, 0x0605), (0x06DD, 0x06DD), (0x070F, 0x070F), (0x0890, 0x0891), (0x08E2, 0x08E2),
    (0x0D4E, 0x0D4E), (0x110BD, 0x110BD), (0x110CD, 0x110CD), (0x111C2, 0x111C3), (0x113D1, 0x113D1),
    (0x1193F, 0x1193F), (0x11941, 0x11941), (0x11A84, 0x11A89), (0x11D46, 0x11D46), (0x11F02, 0x11F02),
];

/// Scalars that break clusters on both sides (Control, CR, LF): every `c`
/// for which Swift counts `U+0600 + c` as two Characters.
#[rustfmt::skip]
const GRAPHEME_CONTROL: &[(u32, u32)] = &[
    (0x0000, 0x001F), (0x007F, 0x009F), (0x00AD, 0x00AD), (0x061C, 0x061C), (0x180E, 0x180E),
    (0x200B, 0x200B), (0x200E, 0x200F), (0x2028, 0x202E), (0x2060, 0x206F), (0xFEFF, 0xFEFF),
    (0xFFF0, 0xFFFB), (0x13430, 0x1343F), (0x1BCA0, 0x1BCA3), (0x1D173, 0x1D17A), (0xE0000, 0xE001F),
    (0xE0080, 0xE00FF), (0xE01F0, 0xE0FFF),
];

fn in_ranges(ranges: &[(u32, u32)], c: char) -> bool {
    let v = u32::from(c);
    ranges
        .binary_search_by(|&(lo, hi)| {
            if hi < v {
                Ordering::Less
            } else if lo > v {
                Ordering::Greater
            } else {
                Ordering::Equal
            }
        })
        .is_ok()
}

/// Swift `Character.isLetter` for a cluster starting with `c`: the first
/// scalar's Alphabetic property, as the Swift runtime reports it. Panics: none.
#[must_use]
pub fn swift_is_letter(c: char) -> bool {
    c.is_alphabetic() || in_ranges(SWIFT_EXTRA_LETTERS, c)
}

/// Whether `c` joins the grapheme cluster before it. Panics: none.
#[must_use]
pub fn grapheme_attaches_to_previous(c: char) -> bool {
    in_ranges(GRAPHEME_ATTACH, c)
}

/// Whether `c` joins the grapheme cluster after it. Panics: none.
#[must_use]
pub fn grapheme_prepends(c: char) -> bool {
    in_ranges(GRAPHEME_PREPEND, c)
}

/// Whether `c` breaks clusters on both sides. Panics: none.
#[must_use]
pub fn grapheme_breaks_both_sides(c: char) -> bool {
    in_ranges(GRAPHEME_CONTROL, c)
}

/// A cluster boundary between adjacent scalars, by the modelled rules
/// (grapheme-break rules GB4, GB5, GB9, GB9a, GB9b, else a break).
fn is_boundary(prev: char, next: char) -> bool {
    if grapheme_breaks_both_sides(prev) || grapheme_breaks_both_sides(next) {
        return true;
    }
    !(grapheme_attaches_to_previous(next) || grapheme_prepends(prev))
}

/// Swift `haystack.contains(needle)` for an ASCII needle without CR or LF:
/// a byte match whose ends fall on cluster boundaries (no Prepend before it,
/// nothing attaching after it). Every such needle character is its own
/// cluster inside the match, so this is the Character-sequence match Swift
/// performs. Panics: none.
#[must_use]
pub fn swift_contains(haystack: &str, needle: &str) -> bool {
    let (h, n) = (haystack.as_bytes(), needle.as_bytes());
    let (Some(&first), Some(&last)) = (n.first(), n.last()) else {
        return true;
    };
    if n.len() > h.len() {
        return false;
    }
    (0..=h.len() - n.len()).any(|i| {
        if !h[i..].starts_with(n) {
            return false;
        }
        // An ASCII byte is always a char boundary, so both slices are valid.
        let before = haystack[..i].chars().next_back();
        let after = haystack[i + n.len()..].chars().next();
        before.is_none_or(|p| is_boundary(p, char::from(first)))
            && after.is_none_or(|a| is_boundary(char::from(last), a))
    })
}

/// Swift `lower.split(whereSeparator: { !$0.isLetter && $0 != "'" })`: the
/// maximal runs of clusters that start with a letter or are exactly an
/// apostrophe, empty runs omitted. Slices of `lower`. Panics: none.
#[must_use]
pub fn swift_words(lower: &str) -> Vec<&str> {
    let mut words = Vec::new();
    let mut run_start: Option<usize> = None;
    let mut chars = lower.char_indices().peekable();
    while let Some((start, c)) = chars.next() {
        // Extend the cluster while the next scalar does not start a new one.
        let mut prev = c;
        let mut end = start + c.len_utf8();
        while let Some(&(i, next)) = chars.peek() {
            if is_boundary(prev, next) {
                break;
            }
            prev = next;
            end = i + next.len_utf8();
            chars.next();
        }
        let is_separator = !swift_is_letter(c) && &lower[start..end] != "'";
        match (is_separator, run_start) {
            (true, Some(s)) => {
                words.push(&lower[s..start]);
                run_start = None;
            }
            (false, None) => run_start = Some(start),
            _ => {}
        }
    }
    if let Some(s) = run_start {
        words.push(&lower[s..]);
    }
    words
}

// =============================================================================
// Tests: behaviour claims (the oracle test pins every bit)
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fuel_cost_refuses_unknown_economy_but_keeps_a_nan_answer() {
        assert_eq!(drive_fuel_cost_usd(300.0, 30.0, 3.5), Some(35.0));
        assert_eq!(drive_fuel_cost_usd(300.0, 0.0, 3.5), None);
        assert_eq!(drive_fuel_cost_usd(f64::NAN, 30.0, 3.5), None);
        assert_eq!(drive_fuel_cost_usd(-1.0, 30.0, 3.5), None);
        // Zero miles at an infinite price: present, and NaN, as in Swift.
        assert!(drive_fuel_cost_usd(0.0, 1.0, f64::INFINITY).is_some_and(f64::is_nan));
        assert_eq!(
            drive_grams_co2_per_mile(FUEL_GAS, 25.0),
            Some(8_887.0 / 25.0)
        );
        assert_eq!(drive_grams_co2_per_mile(7, 25.0), None);
        assert!(transit_grams_co2_per_mile(true, false) < 8_887.0 / 25.0);
    }

    #[test]
    fn the_hybrid_van_schedule_unrolls_every_cadence_in_mile_order() {
        let iv = [f64::NAN, 350.0, 500.0, 100.0, 200.0];
        let s = schedule(2000.0, &iv, 42);
        let miles_of = |code: u8| -> Vec<f64> {
            s.iter()
                .filter(|e| e.code == code)
                .map(|e| e.mile)
                .collect()
        };
        assert_eq!(
            miles_of(FUEL_DIESEL),
            vec![350.0, 700.0, 1050.0, 1400.0, 1750.0]
        );
        assert_eq!(miles_of(FUEL_ELECTRIC), vec![500.0, 1000.0, 1500.0]);
        assert_eq!(s.iter().filter(|e| (10..19).contains(&e.code)).count(), 19);
        assert!(s.windows(2).all(|w| w[0].mile <= w[1].mile));
        // At mile 1000: Diesel? no, 1000 = electric, food, rest — ordered by label.
        let at: Vec<u8> = s
            .iter()
            .filter(|e| e.mile == 1000.0)
            .map(|e| e.code)
            .collect();
        assert_eq!(at.len(), 3);
        assert_eq!(at[0], FUEL_ELECTRIC);
        assert!((10..19).contains(&at[1]));
        assert_eq!(at[2], NEED_REST);
    }

    #[test]
    fn a_schedule_is_empty_for_a_non_positive_trip_or_past_the_cap() {
        let iv = [100.0, f64::NAN, f64::NAN, f64::NAN, f64::NAN];
        assert!(schedule(0.0, &iv, 0).is_empty());
        assert!(schedule(f64::NAN, &iv, 0).is_empty());
        // An infinite trip never ends in Swift; the port stops at the cap.
        assert!(schedule(f64::INFINITY, &iv, 0).is_empty());
        let just_under = [1.0, f64::NAN, f64::NAN, f64::NAN, f64::NAN];
        assert_eq!(
            schedule(SCHEDULE_STOP_CAP as f64 + 1.0, &just_under, 0).len(),
            SCHEDULE_STOP_CAP
        );
        assert!(schedule(SCHEDULE_STOP_CAP as f64 + 2.0, &just_under, 0).is_empty());
    }

    #[test]
    fn next_need_is_strictly_ahead() {
        let miles = [100.0, 200.0, 350.0];
        assert_eq!(next_need_index(0.0, &miles), Some(0));
        assert_eq!(next_need_index(100.0, &miles), Some(1));
        assert_eq!(next_need_index(350.0, &miles), None);
        assert_eq!(next_need_index(f64::NAN, &miles), None);
        assert_eq!(adjusted_remaining_seconds(1234.0, -50.0), 1234.0);
        assert!(adjusted_remaining_seconds(1234.0, f64::NAN).is_nan());
    }

    #[test]
    fn labels_order_as_swift_strings() {
        assert_eq!(need_label(FUEL_DIESEL).as_deref(), Some("Diesel"));
        assert_eq!(
            need_label(NEED_FOOD_BASE).as_deref(),
            Some("Food \u{b7} Fast food")
        );
        assert_eq!(need_label(NEED_REST).as_deref(), Some("Rest"));
        assert_eq!(need_label(19), None);
        let mut codes: Vec<u8> = (0..=20).filter(|&c| need_label(c).is_some()).collect();
        codes.sort_by(|&a, &b| label_order(a, b));
        let labels: Vec<String> = codes.iter().filter_map(|&c| need_label(c)).collect();
        let mut sorted = labels.clone();
        sorted.sort();
        assert_eq!(labels, sorted);
        sorted.dedup();
        assert_eq!(
            sorted.len(),
            13,
            "labels are distinct, so the schedule order is total"
        );
    }

    #[test]
    fn a_lone_spike_is_a_phone_drop_but_a_corroborated_one_is_an_impact() {
        let mut rest = vec![1.0; 24];
        rest.push(5.5);
        assert!(!is_impact_window(&rest));
        rest[23] = 8.5;
        assert!(is_impact_window(&rest));
        assert!(is_impact_window(&[1.0, 1.2, 5.5, 3.1, 2.8, 2.6, 1.5]));
        assert!(!is_impact_window(&[]));
        // Swift max(): a leading NaN is the peak, a later one is skipped.
        assert!(!is_impact_window(&[f64::NAN, 9.0]));
        assert!(is_impact_window(&[1.0, f64::NAN, 9.0]));
    }

    #[test]
    fn a_crash_needs_road_speed_a_sudden_stop_and_a_road() {
        let w = [1.0, 1.2, 5.5, 3.1, 2.8, 2.6, 1.5];
        assert!(is_crash(&w, 29.0, 0.0, Some(5.0)));
        assert!(is_crash(&w, 29.0, 0.0, None));
        assert!(!is_crash(&w, 25.0, 22.0, Some(900.0)));
        assert!(!is_crash(&w, 25.0, 0.0, Some(900.0)));
        assert!(!is_crash(&w, 1.5, 0.0, Some(3.0)));
        assert!(!is_crash(&w, 30.0, 20.0, Some(4.0)));
        assert!(is_crash(&w, 29.0, 0.0, Some(f64::NAN)));
    }

    #[test]
    fn replies_match_words_on_boundaries_and_stand_down_first() {
        assert_eq!(interpret_reply("Yes I need help"), Some(true));
        assert_eq!(interpret_reply("call 911"), Some(true));
        assert_eq!(interpret_reply("no I'm fine"), Some(false));
        assert_eq!(interpret_reply("never mind, don't call"), Some(false));
        assert_eq!(interpret_reply("I don't know what happened"), None);
        assert_eq!(interpret_reply("it was fine yesterday"), None);
        // A combining accent makes a different word, as a Swift Character does.
        assert_eq!(interpret_reply("no\u{301}"), None);
        assert_eq!(interpret_reply("i'm ok\u{301}"), None);
        // A curly apostrophe separates, in both.
        assert_eq!(interpret_reply("i\u{2019}m ok"), None);
    }

    #[test]
    fn hours_of_service_counts_down_to_the_break_then_the_limit() {
        assert_eq!(hos_status(3.0 * 3600.0), HosStatus::Ok);
        assert_eq!(
            hos_status(7.5 * 3600.0 + 60.0),
            HosStatus::BreakSoon {
                seconds_until_due: 1740.0
            }
        );
        assert_eq!(hos_status(8.0 * 3600.0), HosStatus::BreakDue);
        assert_eq!(hos_status(11.0 * 3600.0), HosStatus::LimitReached);
        assert_eq!(hos_status(f64::NAN), HosStatus::Ok);
    }

    #[test]
    fn spec_lookup_uses_swift_equality_on_ascii_keys() {
        assert!(VEHICLE_SPECS
            .iter()
            .all(|r| r.make.is_ascii() && r.model.is_ascii()));
        let camry = vehicle_spec_index("Toyota", "Camry").expect("Camry");
        assert_eq!(VEHICLE_SPECS[camry].tank_units, 15.8);
        assert_eq!(vehicle_spec_index("toyota", "Camry"), None);
        // The Kelvin sign is canonically K.
        assert_eq!(
            vehicle_spec_index("\u{212A}enworth", "T680 (semi)"),
            vehicle_spec_index("Kenworth", "T680 (semi)")
        );
        assert!(vehicle_spec_rows_for_make("Toyota")
            .iter()
            .all(|&i| VEHICLE_SPECS[i].make == "Toyota"));
        let makes = vehicle_makes();
        assert_eq!(makes.first(), Some(&"Toyota"));
        let mut dedup = makes.clone();
        dedup.dedup();
        assert_eq!(makes.len(), dedup.len());
        let low = minimum_height_feet();
        assert!(low > 4.0 && low < 5.0);
    }

    #[test]
    fn economy_interpolates_by_speed_and_the_range_model_charges_habits() {
        let camry = VehicleEconomy {
            tank_capacity_units: 15.8,
            rated_miles_per_unit: 32.0,
            city_miles_per_unit: Some(28.0),
            highway_miles_per_unit: Some(39.0),
        };
        assert_eq!(camry.miles_per_unit_at_speed(20.0), 28.0);
        assert!((camry.miles_per_unit_at_speed(42.5) - 33.5).abs() < 1e-9);
        assert_eq!(camry.miles_per_unit_at_speed(60.0), 39.0);
        assert!((camry.miles_per_unit_at_speed(75.0) - 39.0 * 0.88).abs() < 1e-9);
        let van = VehicleEconomy {
            tank_capacity_units: 25.0,
            rated_miles_per_unit: 20.0,
            city_miles_per_unit: None,
            highway_miles_per_unit: None,
        };
        assert_eq!(van.rated_range_miles(), 500.0);
        assert!((efficiency_factor(75.0, 0.0) - 0.76).abs() < 1e-9);
        assert!((van.expected_range_miles(250.0, 75.0, 0.0) - 130.0).abs() < 1e-9);
        assert!(should_recommend_fuel(65.0, 25.0, RESERVE_MILES));
        assert!(!should_recommend_fuel(130.0, 25.0, RESERVE_MILES));
        // City present without highway: flat rated economy, idle factor only.
        let city_only = VehicleEconomy {
            highway_miles_per_unit: None,
            ..camry
        };
        assert_eq!(city_only.effective_range_miles(80.0, 0.0), 15.8 * 32.0);
    }

    #[test]
    fn habits_track_speed_idle_and_towing_miles() {
        let mut h = DrivingHabits {
            miles_since_fill: 0.0,
            average_speed_mph: 55.0,
            idle_fraction: 0.0,
        };
        for _ in 0..10 {
            h = record_fix(h, 33.5, 100.0, false, 0.75);
        }
        assert!((h.miles_since_fill - 1000.0 / 1609.344).abs() < 1e-9);
        assert!(h.average_speed_mph > 55.0);
        let towed = record_fix(h, 0.0, 1609.344, true, 0.75);
        assert!((towed.miles_since_fill - h.miles_since_fill - 1.0 / 0.75).abs() < 1e-12);
        assert_eq!(towed.average_speed_mph, h.average_speed_mph);
        assert!(towed.idle_fraction > h.idle_fraction);
        assert!(restore_driving_accepts(30.0, 2.0));
        assert!(!restore_driving_accepts(0.0, 0.5));
        assert_eq!(restore_driving_idle(2.0), 1.0);
    }

    #[test]
    fn epa_classes_follow_the_substring_ladder() {
        let pickup = epa_class_physical("Standard Pickup Trucks 2WD");
        assert_eq!(pickup.height, 6.4);
        assert!(pickup.tow_capacity.is_some());
        assert_eq!(epa_class_physical("Compact Cars").tow_capacity, None);
        // "minivan" contains "van": the minivan rung is never reached.
        assert_eq!(epa_class_physical("Minivan - 2WD").tank, 25.0);
        assert_eq!(epa_class_physical("Vans, Passenger Type").height, 6.8);
        assert_eq!(epa_fuel_type("Electricity"), FUEL_ELECTRIC);
        assert_eq!(epa_fuel_type("Premium Gasoline"), FUEL_GAS);
        assert_eq!(epa_validated_tank(25.0, 30.0), 20.0);
        assert_eq!(epa_validated_tank(25.0, 26.0), 25.0);
    }

    #[test]
    fn swift_contains_respects_cluster_boundaries() {
        assert!(swift_contains("vans\u{301}", "van"));
        assert!(!swift_contains("van\u{301}s", "van"));
        assert!(!swift_contains("\u{600}van", "van"));
        assert!(swift_contains("\u{600}\nvan", "van"));
        assert!(swift_contains("\r\nvan", "van"));
        assert!(!swift_contains("storm\u{301}", "storm"));
        assert_eq!(swift_words("no\u{301} yes"), vec!["no\u{301}", "yes"]);
        assert_eq!(swift_lowercased("ΟΔΟΣ"), "οδοσ");
    }
}
