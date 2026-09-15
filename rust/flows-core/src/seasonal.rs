// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Seasonal risk model and route-head fine-tuning math (state and persistence
//! stay in Swift).
//!
//! The app's on-device learning (`SeasonalRiskModel.swift`,
//! `RouteHeadTrainer.swift`) keeps its Codable stores, its sealed files and
//! its Calendar in Swift. Every number and every decision those stores make
//! is computed here, over plain values Swift passes in:
//! - the decaying per-week accumulator ([`WeekStat`]) and the frequency gate;
//! - the seasonal prior, the calibration RMSE and the flat training rows;
//! - the persisted key strings (route and hub cells, edge and origin keys);
//! - the origin-cell update, both eviction orders, and the learned home;
//! - the frozen 8-feature route vector, the MLP forward pass, and the
//!   warm-started fine-tune with its mean squared error;
//! - the head choice, the fine-tune gates and the ranking blend.
//!
//! Fidelity: the frozen oracle
//! `flows-bridge/tests/fixtures/swift_seasonal_oracle.tsv` holds the outputs of
//! the Swift this replaced, and the Rust reproduces them bit for bit. Swift's
//! `min`/`max` come from [`crate::fcmp`]; folds run in the order Swift passes
//! the values; sorts are stable; no float sum uses `Iterator::sum`, whose
//! identity is `-0.0` where Swift's `reduce(0, +)` starts from `+0.0`; no
//! `mul_add`, because Swift does not contract.
//!
//! Where Swift TRAPS (integer overflow, `Int(Double)` out of range, a
//! negative range bound, an index past a ragged row), the functions return a
//! documented non-panicking value instead. Those inputs crashed the app; no
//! driver has seen an answer for them.
//!
//! Determinism: every function is a pure function of its arguments. Panics:
//! none.

use crate::fcmp::{smax, smin, sunit};
use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::f64::consts::PI;

// ---------------------------------------------------------------- constants

/// Seconds in a week, the unit of [`WeekStat`] decay (Swift `7.0 * 24 * 3600`).
pub const SECONDS_PER_WEEK: f64 = 7.0 * 24.0 * 3600.0;
/// Seconds in a day, the unit of origin-cell decay and relocation age.
pub const SECONDS_PER_DAY: f64 = 86_400.0;
/// A trip at least this long (km) marks its route cross-country.
pub const CROSS_COUNTRY_KM: f64 = 300.0;
/// Trips before a local route may steer ranking.
pub const LOCAL_TRIP_THRESHOLD: i64 = 6;
/// Trips before a cross-country route may steer ranking (rare but valuable).
pub const CROSS_COUNTRY_TRIP_THRESHOLD: i64 = 2;
/// Target-week weight at which the seasonal prior's confidence reaches 1.
pub const MIN_WEEK_SAMPLES_FOR_CONFIDENCE: f64 = 5.0;
/// Half-life, in weeks, of a route or edge week's weight.
pub const DECAY_HALF_LIFE_WEEKS: f64 = 52.0;
/// Origin trips (all cells) before a home is inferred.
pub const HOME_MIN_TRIPS: i64 = 15;
/// The edge graph is evicted back to half of this once it grows past it.
pub const MAX_EDGES: usize = 4_000;
/// The origin map is evicted by half once it grows past this many cells.
pub const MAX_ORIGINS: usize = 200;
/// Half-life, in days, of an origin cell's trip weight.
pub const ORIGIN_HALF_LIFE_DAYS: f64 = 30.0;
/// A challenger cell must outweigh the home in force by this factor…
pub const RELOCATION_MARGIN: f64 = 1.5;
/// …and have been in use at least this many days.
pub const RELOCATION_MIN_DAYS: f64 = 30.0;
/// Width of the route feature vector; the head contract.
pub const ROUTE_FEATURE_COUNT: usize = 8;
/// Fine-tune defaults: full passes, gradient step, pull back to the baseline.
pub const TUNE_EPOCHS: i64 = 60;
/// Default fine-tune learning rate.
pub const TUNE_LEARNING_RATE: f64 = 0.01;
/// Default elastic anchor strength toward the baseline head.
pub const TUNE_ANCHOR: f64 = 0.02;
/// Trips recorded before any fine-tune.
pub const TUNE_MIN_TRIPS: i64 = 12;
/// Seconds between fine-tunes.
pub const TUNE_MIN_INTERVAL_SECONDS: f64 = 86_400.0;
/// New trips since the last fine-tune before another.
pub const TUNE_MIN_NEW_TRIPS: i64 = 5;
/// Weeks in the seasonal year the prior wraps around.
pub const WEEKS_PER_YEAR: i64 = 52;
/// The last week index `week_of_year` returns.
pub const LAST_WEEK: i64 = 51;

// ---------------------------------------------------------------- Swift ints

/// Swift `Int(x)`: truncation toward zero, or `None` exactly where Swift
/// traps (NaN, ±∞, or outside `[-2^63, 2^63)`).
#[must_use]
pub fn swift_int(x: f64) -> Option<i64> {
    // -2^63 is exact; no double lies strictly between it and the next one
    // below, so `>=` here is Swift's `> -9223372036854777856.0`.
    if (-9_223_372_036_854_775_808.0..9_223_372_036_854_775_808.0).contains(&x) {
        Some(x as i64)
    } else {
        None
    }
}

/// Swift `Int(x)` where Swift would trap: saturate like `as` (NaN → 0).
/// Used only to give a trapping input some non-panicking answer.
#[must_use]
pub fn trapped_int(x: f64) -> i64 {
    x as i64
}

/// Swift's `Int(_ text:)` for base 10: an optional `+`/`-`, then one or more
/// ASCII digits, no overflow; anything else is `None`.
#[must_use]
pub fn swift_parse_int(text: &str) -> Option<i64> {
    let bytes = text.as_bytes();
    let (negative, digits) = match bytes.split_first() {
        Some((b'-', rest)) => (true, rest),
        Some((b'+', rest)) => (false, rest),
        _ => (false, bytes),
    };
    if digits.is_empty() {
        return None;
    }
    let mut value: i64 = 0;
    for &b in digits {
        if !b.is_ascii_digit() {
            return None;
        }
        let d = i64::from(b - b'0');
        value = value.checked_mul(10)?;
        value = if negative {
            value.checked_sub(d)?
        } else {
            value.checked_add(d)?
        };
    }
    Some(value)
}

// ---------------------------------------------------------------- WeekStat

/// Decaying-weighted accumulators for one (route or edge, week) cell.
///
/// `count` is the undecayed sample count, an integer as in Swift.
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct WeekStat {
    /// Σ weights.
    pub w_sum: f64,
    /// Σ weight · observed.
    pub w_observed: f64,
    /// Σ weight · (predicted − observed)².
    pub w_sq_err: f64,
    /// Epoch seconds of the last update.
    pub last_t: f64,
    /// Raw sample count.
    pub count: i64,
}

impl WeekStat {
    /// The cell's weights faded to time `t` (epoch seconds) by
    /// `0.5^(weeks / half_life_weeks)`. Unchanged unless `count > 0`,
    /// `t > last_t` and `half_life_weeks > 0` (so NaN changes nothing).
    #[must_use]
    pub fn decayed(self, t: f64, half_life_weeks: f64) -> WeekStat {
        if !(self.count > 0 && t > self.last_t && half_life_weeks > 0.0) {
            return self;
        }
        let weeks = (t - self.last_t) / SECONDS_PER_WEEK;
        let f = 0.5_f64.powf(weeks / half_life_weeks);
        WeekStat {
            w_sum: self.w_sum * f,
            w_observed: self.w_observed * f,
            w_sq_err: self.w_sq_err * f,
            last_t: t,
            count: self.count,
        }
    }

    /// Fold one observation in: decay to `t`, clamp both values to 0…1
    /// (NaN passes through, as Swift's `min(max(x, 0), 1)`), add weight 1,
    /// `last_t = max(last_t, t)`, `count + 1`.
    ///
    /// `count == i64::MAX` crashed Swift; it saturates here.
    #[must_use]
    pub fn added(self, observed: f64, predicted: f64, t: f64, half_life_weeks: f64) -> WeekStat {
        let s = self.decayed(t, half_life_weeks);
        let o = sunit(observed);
        let p = sunit(predicted);
        WeekStat {
            w_sum: s.w_sum + 1.0,
            w_observed: s.w_observed + o,
            w_sq_err: s.w_sq_err + (p - o) * (p - o),
            last_t: smax(s.last_t, t),
            count: s.count.saturating_add(1),
        }
    }

    /// Decaying-weighted mean observed risk; 0 unless `w_sum > 0`.
    #[must_use]
    pub fn mean(self) -> f64 {
        mean_observed(self.w_sum, self.w_observed)
    }
}

/// `w_sum > 0 ? w_observed / w_sum : 0`.
#[must_use]
pub fn mean_observed(w_sum: f64, w_observed: f64) -> f64 {
    if w_sum > 0.0 {
        w_observed / w_sum
    } else {
        0.0
    }
}

// ---------------------------------------------------------------- routes

/// The frequency gate: may a route with `trip_count` trips steer ranking?
#[must_use]
pub fn is_modeled(trip_count: i64, cross_country: bool) -> bool {
    let gate = if cross_country {
        CROSS_COUNTRY_TRIP_THRESHOLD
    } else {
        LOCAL_TRIP_THRESHOLD
    };
    trip_count >= gate
}

/// Does a trip of `distance_km` mark its route cross-country? (NaN: no.)
#[must_use]
pub fn is_cross_country(distance_km: f64) -> bool {
    distance_km >= CROSS_COUNTRY_KM
}

/// A counter after one more trip. `i64::MAX` crashed Swift; it saturates.
#[must_use]
pub fn next_count(count: i64) -> i64 {
    count.saturating_add(1)
}

/// The (week offset, weight) pairs the prior reads, in Swift's loop order.
pub const PRIOR_OFFSETS: [(i64, f64); 3] = [(0, 1.0), (-1, 0.5), (1, 0.5)];

/// The week keys the prior reads for `week`, wrapped into 0…51, in
/// [`PRIOR_OFFSETS`] order. `None` where `week ± 1` overflows (Swift trapped).
#[must_use]
pub fn prior_week_keys(week: i64) -> Option<[i64; 3]> {
    let mut keys = [0_i64; 3];
    for (slot, (dw, _)) in keys.iter_mut().zip(PRIOR_OFFSETS) {
        *slot = (week.checked_add(dw)? % WEEKS_PER_YEAR + WEEKS_PER_YEAR) % WEEKS_PER_YEAR;
    }
    Some(keys)
}

/// The learned seasonal prior `(risk, confidence)` for a route at `week`.
///
/// `cells` are the route's stats at [`prior_week_keys`] (None where absent).
/// Risk is the decayed weighted mean over the target week (×1) and its two
/// neighbours (×0.5); confidence is `min(1, target w_sum / 5)`. `None` before
/// the frequency gate, when no weight remains, or where Swift trapped on the
/// week arithmetic.
#[must_use]
pub fn seasonal_prior(
    trip_count: i64,
    cross_country: bool,
    week: i64,
    cells: [Option<WeekStat>; 3],
    now: f64,
) -> Option<(f64, f64)> {
    if !is_modeled(trip_count, cross_country) {
        return None;
    }
    prior_week_keys(week)?;
    let (mut w_sum, mut w_obs, mut target_weight) = (0.0, 0.0, 0.0);
    for ((dw, wt), cell) in PRIOR_OFFSETS.iter().zip(cells) {
        let Some(stat) = cell else { continue };
        let ws = stat.decayed(now, DECAY_HALF_LIFE_WEEKS);
        w_sum += wt * ws.w_sum;
        w_obs += wt * ws.w_observed;
        if *dw == 0 {
            target_weight = ws.w_sum;
        }
    }
    if w_sum <= 0.0 || w_sum.is_nan() {
        return None;
    }
    Some((
        w_obs / w_sum,
        smin(1.0, target_weight / MIN_WEEK_SAMPLES_FOR_CONFIDENCE),
    ))
}

/// Decaying-weighted RMSE of prediction vs. observation over a route's weeks,
/// folded in the order given. `None` unless `trip_count > 0` and weight remains.
#[must_use]
pub fn accuracy(trip_count: i64, weeks: &[WeekStat], now: f64) -> Option<f64> {
    if trip_count <= 0 {
        return None;
    }
    let (mut w_sum, mut w_err) = (0.0, 0.0);
    for stat in weeks {
        let ws = stat.decayed(now, DECAY_HALF_LIFE_WEEKS);
        w_sum += ws.w_sum;
        w_err += ws.w_sq_err;
    }
    if w_sum <= 0.0 || w_sum.is_nan() {
        return None;
    }
    Some((w_err / w_sum).sqrt())
}

/// Swift `values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)`,
/// summed from `+0.0` in the order given.
#[must_use]
pub fn mean_in_order(values: &[f64]) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    let mut total = 0.0;
    for v in values {
        total += v;
    }
    Some(total / values.len() as f64)
}

/// One (route, week) cell of the store, as the training export reads it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TrainingCell {
    /// Route origin latitude cell (0.1° units).
    pub o_lat: i64,
    /// Route origin longitude cell.
    pub o_lon: i64,
    /// Route destination latitude cell.
    pub d_lat: i64,
    /// Route destination longitude cell.
    pub d_lon: i64,
    /// Week key.
    pub week: i64,
    /// The route's cross-country flag.
    pub cross_country: bool,
    /// The week's accumulators.
    pub stat: WeekStat,
}

/// Flat training rows `[oLat, oLon, dLat, dLon, week, target, weight,
/// crossCountry]` (degrees; target = decayed mean; weight = decayed `w_sum`),
/// one per cell with weight remaining at `now`, in the order given.
#[must_use]
pub fn training_rows(cells: &[TrainingCell], now: f64) -> Vec<[f64; 8]> {
    let mut rows = Vec::new();
    for c in cells {
        let ws = c.stat.decayed(now, DECAY_HALF_LIFE_WEEKS);
        if ws.w_sum <= 0.0 || ws.w_sum.is_nan() {
            continue;
        }
        rows.push([
            route_cell_degrees(c.o_lat),
            route_cell_degrees(c.o_lon),
            route_cell_degrees(c.d_lat),
            route_cell_degrees(c.d_lon),
            c.week as f64,
            ws.mean(),
            ws.w_sum,
            if c.cross_country { 1.0 } else { 0.0 },
        ]);
    }
    rows
}

// ---------------------------------------------------------------- keys

/// Route cell: `Int((degrees * 10).rounded())` (0.1°, half away from zero).
/// `None` where Swift trapped (NaN, ±∞, beyond `Int`).
#[must_use]
pub fn route_cell(degrees: f64) -> Option<i64> {
    swift_int((degrees * 10.0).round())
}

/// Hub cell: `Int((degrees * 100).rounded())` (0.01°, ~1.1 km).
#[must_use]
pub fn hub_cell(degrees: f64) -> Option<i64> {
    swift_int((degrees * 100.0).round())
}

/// A route cell back to degrees: `Double(cell) / 10`.
#[must_use]
pub fn route_cell_degrees(cell: i64) -> f64 {
    cell as f64 / 10.0
}

/// An undirected road edge between two hub cells, endpoints sorted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EdgeKey {
    /// Lesser endpoint latitude cell.
    pub a_lat: i64,
    /// Lesser endpoint longitude cell.
    pub a_lon: i64,
    /// Greater endpoint latitude cell.
    pub b_lat: i64,
    /// Greater endpoint longitude cell.
    pub b_lon: i64,
}

/// The edge between hubs 1 and 2: each quantized to [`hub_cell`], ordered so
/// the lexicographically smaller `(lat, lon)` comes first (ties keep hub 1).
/// `None` where Swift trapped on a coordinate.
#[must_use]
pub fn edge_key(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> Option<EdgeKey> {
    let p1 = (hub_cell(lat1)?, hub_cell(lon1)?);
    let p2 = (hub_cell(lat2)?, hub_cell(lon2)?);
    let (a, b) = if p1 <= p2 { (p1, p2) } else { (p2, p1) };
    Some(EdgeKey {
        a_lat: a.0,
        a_lon: a.1,
        b_lat: b.0,
        b_lon: b.1,
    })
}

/// [`edge_key`] with Swift's trap replaced by saturating quantization.
#[must_use]
pub fn edge_key_saturating(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> EdgeKey {
    let q = |v: f64| hub_cell(v).unwrap_or_else(|| trapped_int((v * 100.0).round()));
    let p1 = (q(lat1), q(lon1));
    let p2 = (q(lat2), q(lon2));
    let (a, b) = if p1 <= p2 { (p1, p2) } else { (p2, p1) };
    EdgeKey {
        a_lat: a.0,
        a_lon: a.1,
        b_lat: b.0,
        b_lon: b.1,
    }
}

/// The persisted edge-graph key: `"aLat,aLon,bLat,bLon"` in decimal.
#[must_use]
pub fn edge_key_string(k: EdgeKey) -> String {
    format!("{},{},{},{}", k.a_lat, k.a_lon, k.b_lat, k.b_lon)
}

/// Keys of the consecutive edges along a hub path given as `(lat, lon)`
/// pairs, in path order (one fewer than the hubs; empty below two hubs).
/// `None` if any coordinate trapped in Swift.
#[must_use]
pub fn path_edge_keys(hubs: &[(f64, f64)]) -> Option<Vec<String>> {
    let mut keys = Vec::with_capacity(hubs.len().saturating_sub(1));
    for pair in hubs.windows(2) {
        let (h1, h2) = (pair[0], pair[1]);
        keys.push(edge_key_string(edge_key(h1.0, h1.1, h2.0, h2.1)?));
    }
    Some(keys)
}

/// The persisted origin-cell key: `"lat|lon"` in decimal 0.1° cells.
#[must_use]
pub fn origin_key(lat: i64, lon: i64) -> String {
    format!("{lat}|{lon}")
}

/// Parse an origin key the way the store reads it back: split on `|`
/// dropping empty pieces, require exactly two, each a Swift `Int`.
///
/// Swift splits on grapheme clusters, this on bytes. They can only disagree
/// where a `|` joins a neighbouring mark into one cluster, and that mark then
/// sits inside a piece and fails the digits-only parse on both sides, so the
/// answer is the same (pinned by the oracle's malformed keys).
#[must_use]
pub fn parse_origin_key(key: &str) -> Option<(i64, i64)> {
    let mut pieces = key.split('|').filter(|p| !p.is_empty());
    let lat = pieces.next()?;
    let lon = pieces.next()?;
    if pieces.next().is_some() {
        return None;
    }
    Some((swift_parse_int(lat)?, swift_parse_int(lon)?))
}

// ---------------------------------------------------------------- evictions

/// Swift's `<` as a total preorder: numbers by value (`-0 == +0`), NaN after
/// every number. On NaN-free input this is exactly `<`, so a stable sort
/// gives Swift's stable sort; NaN cannot reach these keys from the app.
fn swift_less_order(a: f64, b: f64) -> Ordering {
    match a.partial_cmp(&b) {
        Some(o) => o,
        None => a.is_nan().cmp(&b.is_nan()),
    }
}

/// Positions of `keys` in stable ascending order.
fn stable_ascending(keys: &[f64]) -> Vec<usize> {
    let mut order: Vec<usize> = (0..keys.len()).collect();
    order.sort_by(|&i, &j| swift_less_order(keys[i], keys[j]));
    order
}

/// An origin cell's trip history.
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct OriginStat {
    /// Trips decayed toward the last update.
    pub weighted: f64,
    /// Epoch seconds of the last trip (0 = never).
    pub last_seen: f64,
    /// Epoch seconds of the first trip (0 = unset).
    pub first_seen: f64,
    /// Raw trip count.
    pub trips: i64,
}

/// An origin weight decayed to `now`: `weighted · 0.5^(max(now − last_seen, 0)
/// / 86400 / 30)`.
#[must_use]
pub fn origin_decayed(weighted: f64, last_seen: f64, now: f64) -> f64 {
    let days = smax(now - last_seen, 0.0) / SECONDS_PER_DAY;
    weighted * 0.5_f64.powf(days / ORIGIN_HALF_LIFE_DAYS)
}

/// An origin cell after a trip at `t`: decay (only if `last_seen > 0`), add 1,
/// count the trip, stamp `last_seen`, and set `first_seen` if it was 0.
/// `trips == i64::MAX` crashed Swift; it saturates.
#[must_use]
pub fn origin_after_trip(prior: OriginStat, t: f64) -> OriginStat {
    let mut s = prior;
    if s.last_seen > 0.0 {
        let days = smax(t - s.last_seen, 0.0) / SECONDS_PER_DAY;
        s.weighted *= 0.5_f64.powf(days / ORIGIN_HALF_LIFE_DAYS);
    }
    s.weighted += 1.0;
    s.trips = s.trips.saturating_add(1);
    s.last_seen = t;
    if s.first_seen == 0.0 {
        s.first_seen = t;
    }
    s
}

/// Is an origin map of `count` cells over its bound?
#[must_use]
pub fn origins_over_cap(count: usize) -> bool {
    count > MAX_ORIGINS
}

/// Which origin cells to evict: none unless there are more than
/// [`MAX_ORIGINS`]; otherwise the `len / 2` least-weighted at `now`, as
/// positions in `(weighted, last_seen)` order given, least first. Ties keep
/// the given order (Swift's sort is stable over its iteration order).
#[must_use]
pub fn origin_evictions(stats: &[(f64, f64)], now: f64) -> Vec<usize> {
    if !origins_over_cap(stats.len()) {
        return Vec::new();
    }
    let keys: Vec<f64> = stats
        .iter()
        .map(|&(w, last)| origin_decayed(w, last, now))
        .collect();
    let mut order = stable_ascending(&keys);
    order.truncate(stats.len() / 2);
    order
}

/// An edge record's freshness: the largest `last_t` of its weeks in the order
/// given (Swift `max()`: a later value replaces only if strictly greater), or
/// 0 for a record with no weeks.
#[must_use]
pub fn edge_freshness(last_ts: &[f64]) -> f64 {
    let Some((&first, rest)) = last_ts.split_first() else {
        return 0.0;
    };
    let mut best = first;
    for &e in rest {
        if best < e {
            best = e;
        }
    }
    best
}

/// Is an edge graph of `count` edges over its bound?
#[must_use]
pub fn edges_over_cap(count: usize) -> bool {
    count > MAX_EDGES
}

/// Which edges to evict: none unless there are more than [`MAX_EDGES`];
/// otherwise the `len − MAX_EDGES / 2` least fresh, as positions in the
/// order given, least first, ties in the given order.
#[must_use]
pub fn edge_evictions(freshness: &[f64]) -> Vec<usize> {
    if !edges_over_cap(freshness.len()) {
        return Vec::new();
    }
    let mut order = stable_ascending(freshness);
    order.truncate(freshness.len() - MAX_EDGES / 2);
    order
}

// ---------------------------------------------------------------- home

/// One entry of the origin map, as the learned-home scan reads it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OriginEntry {
    /// The parsed cell, or `None` when the key does not parse.
    pub cell: Option<(i64, i64)>,
    /// The stored history.
    pub stat: OriginStat,
}

/// A home anchor: degrees plus the trips that back it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Home {
    /// Latitude, degrees.
    pub lat: f64,
    /// Longitude, degrees.
    pub lon: f64,
    /// Trips.
    pub trips: i64,
}

fn home_of(cell: (i64, i64), trips: i64) -> Home {
    Home {
        lat: route_cell_degrees(cell.0),
        lon: route_cell_degrees(cell.1),
        trips,
    }
}

/// The learned home anchor from the origin map, entries in the order Swift
/// iterates it.
///
/// Best = the first entry with the greatest decayed weight among parseable
/// cells. `None` without one, or when all entries' trips (parseable or not)
/// sum below [`HOME_MIN_TRIPS`]. With no `current` anchor, or one not in the
/// map, best wins. Otherwise best replaces the incumbent (the first entry in
/// the `current` cell) only if its weight is at least 1.5× and it was first
/// seen at least 30 days before `now`. A trip-sum overflow crashed Swift and
/// is `None` here.
#[must_use]
pub fn learned_home(
    entries: &[OriginEntry],
    now: f64,
    current: Option<(i64, i64)>,
) -> Option<Home> {
    let mut best: Option<(&OriginEntry, (i64, i64), f64)> = None;
    for e in entries {
        let Some(cell) = e.cell else { continue };
        let w = origin_decayed(e.stat.weighted, e.stat.last_seen, now);
        match best {
            Some((_, _, bw)) if bw.partial_cmp(&w) != Some(Ordering::Less) => {}
            _ => best = Some((e, cell, w)),
        }
    }
    let (b, b_cell, b_w) = best?;
    let mut total: i64 = 0;
    for e in entries {
        total = total.checked_add(e.stat.trips)?;
    }
    if total < HOME_MIN_TRIPS {
        return None;
    }
    let Some(cur) = current else {
        return Some(home_of(b_cell, b.stat.trips));
    };
    let Some(incumbent) = entries.iter().find(|e| e.cell == Some(cur)) else {
        return Some(home_of(b_cell, b.stat.trips));
    };
    if b_cell == cur {
        return Some(home_of(cur, incumbent.stat.trips));
    }
    let i_w = origin_decayed(incumbent.stat.weighted, incumbent.stat.last_seen, now);
    let established_days = smax(now - b.stat.first_seen, 0.0) / SECONDS_PER_DAY;
    if b_w >= i_w * RELOCATION_MARGIN && established_days >= RELOCATION_MIN_DAYS {
        return Some(home_of(b_cell, b.stat.trips));
    }
    Some(home_of(cur, incumbent.stat.trips))
}

/// The pre-origin-tracking home: trip counts summed per route-origin cell,
/// routes in the order given; the cell with the most trips if at least
/// [`HOME_MIN_TRIPS`].
///
/// Ties go to the cell that appears first. Swift took the first maximum in
/// the iteration order of a fresh Dictionary, which is per allocation, so
/// its tie winner was not a function of the store. A per-cell sum overflow
/// crashed Swift and is `None` here.
#[must_use]
pub fn legacy_home(routes: &[(i64, i64, i64)]) -> Option<Home> {
    let mut cells: Vec<((i64, i64), i64)> = Vec::new();
    let mut index: BTreeMap<(i64, i64), usize> = BTreeMap::new();
    for &(lat, lon, trips) in routes {
        match index.get(&(lat, lon)) {
            Some(&i) => {
                let slot = cells.get_mut(i)?;
                slot.1 = slot.1.checked_add(trips)?;
            }
            None => {
                index.insert((lat, lon), cells.len());
                cells.push(((lat, lon), trips));
            }
        }
    }
    let (first, rest) = cells.split_first()?;
    let mut best = first;
    for c in rest {
        if best.1 < c.1 {
            best = c;
        }
    }
    (best.1 >= HOME_MIN_TRIPS).then(|| home_of(best.0, best.1))
}

// ---------------------------------------------------------------- features

/// Great-circle kilometres (haversine, R = 6371), evaluated in Swift's order.
#[must_use]
pub fn haversine_km(a_lat: f64, a_lon: f64, b_lat: f64, b_lon: f64) -> f64 {
    let r = 6371.0;
    let to_rad = PI / 180.0;
    let d_lat = (b_lat - a_lat) * to_rad;
    let d_lon = (b_lon - a_lon) * to_rad;
    let s = (d_lat / 2.0).sin() * (d_lat / 2.0).sin()
        + (a_lat * to_rad).cos()
            * (b_lat * to_rad).cos()
            * (d_lon / 2.0).sin()
            * (d_lon / 2.0).sin();
    2.0 * r * s.sqrt().atan2((1.0 - s).sqrt())
}

/// The frozen v2 route/week feature vector, in contract order:
/// `[sin a, cos a, oLat/90, dLat/90, oLon/180, dLon/180,
///   min(haversine km, 4000)/4000, crossCountry]` with `a = 2π·week/52`.
/// Changing the order invalidates every trained head.
#[must_use]
pub fn route_features(
    o_lat: f64,
    o_lon: f64,
    d_lat: f64,
    d_lon: f64,
    week: i64,
    cross_country: bool,
) -> [f64; ROUTE_FEATURE_COUNT] {
    let a = 2.0 * PI * week as f64 / 52.0;
    let dist = haversine_km(o_lat, o_lon, d_lat, d_lon);
    [
        a.sin(),
        a.cos(),
        o_lat / 90.0,
        d_lat / 90.0,
        o_lon / 180.0,
        d_lon / 180.0,
        smin(dist, 4000.0) / 4000.0,
        if cross_country { 1.0 } else { 0.0 },
    ]
}

// ---------------------------------------------------------------- head

/// A small MLP: ReLU hidden layer, sigmoid output. Rows of `w1` may be
/// ragged, and the three hidden-layer lengths may disagree (a corrupt head
/// file must degrade, not crash).
#[derive(Clone, Debug, PartialEq, Default)]
pub struct Head {
    /// `[hidden][in]` weights.
    pub w1: Vec<Vec<f64>>,
    /// `[hidden]` biases.
    pub b1: Vec<f64>,
    /// `[hidden]` output weights.
    pub w2: Vec<f64>,
    /// Output bias.
    pub b2: f64,
}

impl Head {
    /// Input width the head was trained for: the first row's length, or 0.
    #[must_use]
    pub fn input_width(&self) -> usize {
        self.w1.first().map_or(0, Vec::len)
    }
}

/// The head's risk in (0, 1) for `x`, tolerant of shape: hidden units run to
/// the shortest of `b1`, `w1`, `w2`; each row reads `min(row, x)` inputs.
#[must_use]
pub fn head_predict(head: &Head, x: &[f64]) -> f64 {
    let mut out = head.b2;
    for ((b, row), w) in head.b1.iter().zip(&head.w1).zip(&head.w2) {
        let mut s = *b;
        for (wi, xi) in row.iter().zip(x) {
            s += wi * xi;
        }
        out += w * smax(0.0, s);
    }
    1.0 / (1.0 + (-out).exp())
}

/// One `trainingRows` dictionary: `None` for an absent key.
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct RowInput {
    /// `oLat` (default 0).
    pub o_lat: Option<f64>,
    /// `oLon` (default 0).
    pub o_lon: Option<f64>,
    /// `dLat` (default 0).
    pub d_lat: Option<f64>,
    /// `dLon` (default 0).
    pub d_lon: Option<f64>,
    /// `week` (default 0), truncated to an integer.
    pub week: Option<f64>,
    /// `target`; a row without a finite one is skipped.
    pub target: Option<f64>,
    /// `weight` (default 1), floored at 0.
    pub weight: Option<f64>,
    /// `crossCountry` (default 0); true when above 0.5.
    pub cross_country: Option<f64>,
}

/// A row's features, target clamp and weight, or the row skipped (`Ok(None)`)
/// or a Swift trap on its week (`Err`).
fn sample_of(r: &RowInput) -> Result<Option<([f64; ROUTE_FEATURE_COUNT], f64)>, ()> {
    let Some(target) = r.target else {
        return Ok(None);
    };
    if !target.is_finite() {
        return Ok(None);
    }
    let week = swift_int(r.week.unwrap_or(0.0)).ok_or(())?;
    let x = route_features(
        r.o_lat.unwrap_or(0.0),
        r.o_lon.unwrap_or(0.0),
        r.d_lat.unwrap_or(0.0),
        r.d_lon.unwrap_or(0.0),
        week,
        r.cross_country.unwrap_or(0.0) > 0.5,
    );
    Ok(Some((x, sunit(target))))
}

/// A fine-tuned head and the number of rows it learned from.
#[derive(Clone, Debug, PartialEq)]
pub struct TuneOutcome {
    /// The tuned weights (rows keep any entries past the input width).
    pub head: Head,
    /// Rows with a finite target.
    pub samples: usize,
}

/// Warm-started, anchored fine-tune of `base` on the driver's rows.
///
/// Full-batch gradient descent on weighted sigmoid-MSE for `epochs` passes:
/// `dOut = (out − y)·out·(1 − out)·w`, step `lr / max(Σw, 1)`, plus
/// `anchor · (θ − θ_base)` pulling every weight back toward the baseline.
/// Sums run in row order, hidden units in order, inputs in order.
///
/// `None` when the input width is not 8, the hidden lengths disagree, there
/// are no rows or no finite targets, or the result is not all finite. Also
/// `None` where Swift crashed: a sampled row's week outside `Int`, a negative
/// `epochs`, or a hidden row shorter than the input width.
#[must_use]
pub fn fine_tune(
    base: &Head,
    rows: &[RowInput],
    epochs: i64,
    learning_rate: f64,
    anchor: f64,
) -> Option<TuneOutcome> {
    let width = base.input_width();
    if width != ROUTE_FEATURE_COUNT
        || base.b1.len() != base.w1.len()
        || base.w2.len() != base.w1.len()
        || rows.is_empty()
    {
        return None;
    }
    let mut samples: Vec<([f64; ROUTE_FEATURE_COUNT], f64, f64)> = Vec::with_capacity(rows.len());
    for r in rows {
        let Some((x, y)) = sample_of(r).ok()? else {
            continue;
        };
        samples.push((x, y, smax(r.weight.unwrap_or(1.0), 0.0)));
    }
    if samples.is_empty() || epochs < 0 {
        return None;
    }
    if epochs > 0 && base.w1.iter().any(|row| row.len() < width) {
        return None;
    }

    let hidden = base.w1.len();
    let (base_w1, base_b1, base_w2, base_b2) = (&base.w1, &base.b1, &base.w2, base.b2);
    let mut w1 = base.w1.clone();
    let mut b1 = base.b1.clone();
    let mut w2 = base.w2.clone();
    let mut b2 = base.b2;
    let mut h = vec![0.0; hidden];

    for _ in 0..epochs {
        let mut gw1 = vec![[0.0; ROUTE_FEATURE_COUNT]; hidden];
        let mut gb1 = vec![0.0; hidden];
        let mut gw2 = vec![0.0; hidden];
        let mut gb2 = 0.0;
        let mut total_weight = 0.0;

        for (x, y, w) in &samples {
            let mut pre_out = b2;
            for (((hj, bj), row), w2j) in h.iter_mut().zip(&b1).zip(&w1).zip(&w2) {
                let mut acc = *bj;
                for (wk, xk) in row.iter().zip(x) {
                    acc += wk * xk;
                }
                *hj = smax(acc, 0.0);
                pre_out += w2j * *hj;
            }
            let out = 1.0 / (1.0 + (-pre_out).exp());
            let d_out = (out - y) * out * (1.0 - out) * w;
            total_weight += w;
            gb2 += d_out;
            for ((((hj, w2j), gw2j), gb1j), gw1j) in h
                .iter()
                .zip(&w2)
                .zip(gw2.iter_mut())
                .zip(gb1.iter_mut())
                .zip(gw1.iter_mut())
            {
                *gw2j += d_out * hj;
                if *hj <= 0.0 || hj.is_nan() {
                    continue;
                }
                let d_hidden = d_out * w2j;
                *gb1j += d_hidden;
                for (g, xk) in gw1j.iter_mut().zip(x) {
                    *g += d_hidden * xk;
                }
            }
        }

        let scale = learning_rate / smax(total_weight, 1.0);
        b2 -= scale * gb2 + anchor * (b2 - base_b2);
        for j in 0..hidden {
            w2[j] -= scale * gw2[j] + anchor * (w2[j] - base_w2[j]);
            b1[j] -= scale * gb1[j] + anchor * (b1[j] - base_b1[j]);
            for (k, g) in gw1[j].iter().enumerate() {
                w1[j][k] -= scale * g + anchor * (w1[j][k] - base_w1[j][k]);
            }
        }
    }

    let finite = w1.iter().all(|r| r.iter().all(|v| v.is_finite()))
        && b1.iter().all(|v| v.is_finite())
        && w2.iter().all(|v| v.is_finite())
        && b2.is_finite();
    finite.then_some(TuneOutcome {
        head: Head { w1, b1, w2, b2 },
        samples: samples.len(),
    })
}

/// Unweighted mean squared error of `head` (tolerant forward pass) over the
/// rows with a finite target; `None` when there are none, or where Swift
/// crashed on a sampled row's week.
#[must_use]
pub fn mean_squared_error(head: &Head, rows: &[RowInput]) -> Option<f64> {
    let (mut total, mut n) = (0.0, 0.0);
    for r in rows {
        let Some((x, y)) = sample_of(r).ok()? else {
            continue;
        };
        let d = head_predict(head, &x) - y;
        total += d * d;
        n += 1.0;
    }
    (n > 0.0).then(|| total / n)
}

/// A tuned head's informational row count: `(base rows ?? 0) + samples`.
/// Overflow crashed Swift; it saturates.
#[must_use]
pub fn tuned_rows(base_rows: Option<i64>, samples: i64) -> i64 {
    base_rows.unwrap_or(0).saturating_add(samples)
}

// ---------------------------------------------------------------- policy

/// What a head file says about itself.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct HeadMeta {
    /// `rows`, when present.
    pub rows: Option<i64>,
    /// `tunedOnDevice`, when present.
    pub tuned_on_device: Option<bool>,
}

/// Which decoded head runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HeadChoice {
    /// No head: the statistical prior alone.
    None,
    /// The on-device head.
    Local,
    /// The shipped baseline.
    Bundled,
}

/// The on-device head when it was tuned on this device; otherwise the one
/// with more rows (a tie keeps the local head); otherwise whichever exists.
#[must_use]
pub fn choose_head(local: Option<HeadMeta>, bundled: Option<HeadMeta>) -> HeadChoice {
    match (local, bundled) {
        (Some(l), Some(b)) => {
            if l.tuned_on_device.unwrap_or(false) || l.rows.unwrap_or(0) >= b.rows.unwrap_or(0) {
                HeadChoice::Local
            } else {
                HeadChoice::Bundled
            }
        }
        (Some(_), None) => HeadChoice::Local,
        (None, Some(_)) => HeadChoice::Bundled,
        (None, None) => HeadChoice::None,
    }
}

/// Is a fine-tune due? At least 12 trips, at least a day since the last tune
/// (`seconds_since_last_tune`, `None` if never; NaN counts as due), and at
/// least 5 trips since it. A subtraction overflow crashed Swift and is `false`.
#[must_use]
pub fn tune_due(
    total_trips: i64,
    seconds_since_last_tune: Option<f64>,
    tuned_at_trip_count: i64,
) -> bool {
    if total_trips < TUNE_MIN_TRIPS {
        return false;
    }
    if seconds_since_last_tune.is_some_and(|gap| gap < TUNE_MIN_INTERVAL_SECONDS) {
        return false;
    }
    total_trips
        .checked_sub(tuned_at_trip_count)
        .is_some_and(|new_trips| new_trips >= TUNE_MIN_NEW_TRIPS)
}

/// Keep a fine-tune only if it scores no worse than the baseline on the
/// driver's own rows.
#[must_use]
pub fn accept_tune(tuned_mse: f64, base_mse: f64) -> bool {
    tuned_mse <= base_mse
}

/// The ranking prior: the head's prediction moved toward the driver's own
/// observed mean by confidence clamped to 0…1 (NaN passes through).
#[must_use]
pub fn blend_prior(modeled: f64, observed_risk: f64, confidence: f64) -> f64 {
    let c = sunit(confidence);
    modeled * (1.0 - c) + observed_risk * c
}

/// Week of year 0…51 from the Calendar's day-of-year (`None` reads as day 1):
/// `(day − 1) / 7`, clamped. `day == i64::MIN` crashed Swift and is week 0.
#[must_use]
pub fn week_of_year(ordinal_day: Option<i64>) -> i64 {
    match ordinal_day.unwrap_or(1).checked_sub(1) {
        Some(d) => (d / 7).clamp(0, LAST_WEEK),
        None => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stat(w_sum: f64, w_observed: f64, last_t: f64, count: i64) -> WeekStat {
        WeekStat {
            w_sum,
            w_observed,
            w_sq_err: 0.0,
            last_t,
            count,
        }
    }

    #[test]
    fn a_year_halves_a_weeks_weight_and_nothing_decays_without_samples() {
        let s = stat(8.0, 4.0, 0.0, 3);
        let one_year = s.decayed(52.0 * SECONDS_PER_WEEK, DECAY_HALF_LIFE_WEEKS);
        assert_eq!(one_year.w_sum, 4.0);
        assert_eq!(one_year.last_t, 52.0 * SECONDS_PER_WEEK);
        assert_eq!(stat(8.0, 4.0, 0.0, 0).decayed(1e9, 52.0).w_sum, 8.0);
        assert_eq!(
            s.decayed(-1.0, 52.0),
            s,
            "time running backwards changes nothing"
        );
        assert_eq!(
            s.decayed(1e9, f64::NAN),
            s,
            "a NaN half-life changes nothing"
        );
    }

    #[test]
    fn an_observation_is_clamped_counted_and_never_moves_time_back() {
        let s = stat(1.0, 0.5, 100.0, 1).added(f64::NAN, 2.0, 50.0, 52.0);
        assert!(s.w_observed.is_nan(), "Swift's clamp passes NaN through");
        assert_eq!(s.last_t, 100.0);
        assert_eq!(s.count, 2);
        assert_eq!(
            stat(0.0, 0.0, 0.0, i64::MAX)
                .added(0.5, 0.5, 1.0, 52.0)
                .count,
            i64::MAX
        );
    }

    #[test]
    fn cross_country_routes_steer_ranking_on_fewer_trips() {
        assert!(!is_modeled(5, false) && is_modeled(6, false));
        assert!(!is_modeled(1, true) && is_modeled(2, true));
        assert!(
            is_cross_country(300.0) && !is_cross_country(299.999) && !is_cross_country(f64::NAN)
        );
    }

    #[test]
    fn the_prior_wraps_the_year_and_saturates_confidence() {
        assert_eq!(prior_week_keys(0), Some([0, 51, 1]));
        assert_eq!(prior_week_keys(51), Some([51, 50, 0]));
        assert_eq!(prior_week_keys(-53), Some([51, 50, 0]));
        assert_eq!(prior_week_keys(i64::MAX), None);
        let full = stat(10.0, 8.0, 0.0, 10);
        let (risk, confidence) =
            seasonal_prior(6, false, 3, [Some(full), None, None], 0.0).expect("modeled");
        assert_eq!((risk, confidence), (0.8, 1.0));
        assert_eq!(
            seasonal_prior(5, false, 3, [Some(full), None, None], 0.0),
            None
        );
        let neighbour_only =
            seasonal_prior(2, true, 3, [None, Some(full), None], 0.0).expect("weight");
        assert_eq!(
            neighbour_only,
            (0.8, 0.0),
            "no target week: full neighbour risk, zero confidence"
        );
    }

    #[test]
    fn keys_round_half_away_from_zero_and_sort_edges() {
        assert_eq!(route_cell(0.05), Some(1));
        assert_eq!(route_cell(-0.05), Some(-1));
        assert_eq!(route_cell(f64::NAN), None);
        assert_eq!(route_cell(9.3e17), None);
        let k = edge_key(40.02, -83.0, 40.0, -83.0).expect("finite");
        assert_eq!(edge_key_string(k), "4000,-8300,4002,-8300");
        assert_eq!(origin_key(i64::MIN, 0), "-9223372036854775808|0");
        assert_eq!(parse_origin_key("430||-894"), Some((430, -894)));
        assert_eq!(parse_origin_key("+5|-0"), Some((5, 0)));
        assert_eq!(parse_origin_key("430|-894|1"), None);
        assert_eq!(parse_origin_key("99999999999999999999|1"), None);
    }

    #[test]
    fn evictions_drop_the_stalest_half_and_keep_ties_in_order() {
        assert!(origin_evictions(&vec![(1.0, 0.0); MAX_ORIGINS], 0.0).is_empty());
        let mut stats = vec![(5.0, 0.0); MAX_ORIGINS + 1];
        stats[7] = (1.0, 0.0);
        let doomed = origin_evictions(&stats, 0.0);
        assert_eq!(doomed.len(), MAX_ORIGINS.div_ceil(2));
        assert_eq!(doomed[0], 7);
        assert_eq!(
            doomed[1..],
            (0..101).filter(|&i| i != 7).take(99).collect::<Vec<_>>()[..]
        );
        assert_eq!(edge_freshness(&[]), 0.0);
        assert_eq!(edge_freshness(&[3.0, 9.0, 4.0]), 9.0);
        let fresh: Vec<f64> = (0..=MAX_EDGES).map(|i| i as f64).collect();
        assert_eq!(
            edge_evictions(&fresh),
            (0..=MAX_EDGES / 2).collect::<Vec<_>>()
        );
    }

    #[test]
    fn home_moves_only_for_a_clearly_dominant_established_cell() {
        let e = |cell, weighted, first_seen, trips| OriginEntry {
            cell: Some(cell),
            stat: OriginStat {
                weighted,
                last_seen: 1e9,
                first_seen,
                trips,
            },
        };
        let month_ago = 1e9 - 30.0 * SECONDS_PER_DAY;
        let old = e((430, -894), 2.0, 1.0, 10);
        let new_city = e((419, -874), 3.0, month_ago, 10);
        let home = learned_home(&[old, new_city], 1e9, Some((430, -894))).expect("home");
        assert_eq!((home.lat, home.lon), (41.9, -87.4));
        let recent = e((419, -874), 3.0, month_ago + 1.0, 10);
        let stays = learned_home(&[old, recent], 1e9, Some((430, -894))).expect("home");
        assert_eq!((stays.lat, stays.lon, stays.trips), (43.0, -89.4, 10));
        assert_eq!(learned_home(&[e((1, 1), 1.0, 1.0, 14)], 1e9, None), None);
        assert_eq!(
            learned_home(
                &[e((1, 1), 1.0, 1.0, i64::MAX), e((2, 2), 0.5, 1.0, 1)],
                1e9,
                None
            ),
            None
        );
        let legacy = legacy_home(&[(1, 1, 8), (2, 2, 9), (1, 1, 8)]).expect("16 trips");
        assert_eq!((legacy.lat, legacy.lon, legacy.trips), (0.1, 0.1, 16));
    }

    #[test]
    fn the_feature_contract_keeps_its_order() {
        let x = route_features(43.0, -89.0, 44.0, -88.0, 0, true);
        assert_eq!(x[0], 0.0);
        assert_eq!(x[1], 1.0);
        assert_eq!(x[2], 43.0 / 90.0);
        assert_eq!(x[3], 44.0 / 90.0);
        assert_eq!(x[4], -89.0 / 180.0);
        assert_eq!(x[5], -88.0 / 180.0);
        assert_eq!(x[7], 1.0);
        assert!(
            route_features(0.0, 0.0, f64::NAN, 0.0, 0, false)[6].is_nan(),
            "Swift's min keeps NaN"
        );
    }

    #[test]
    fn predict_tolerates_ragged_heads_and_relu_zeroes_nan() {
        let head = Head {
            w1: vec![vec![1.0], vec![1.0, 1.0, 1.0]],
            b1: vec![0.0, f64::NAN],
            w2: vec![1.0, 1.0, 5.0],
            b2: 0.0,
        };
        assert_eq!(
            head_predict(&head, &[0.5, 9.0]),
            1.0 / (1.0 + (-0.5_f64).exp())
        );
        assert_eq!(head_predict(&Head::default(), &[]), 0.5);
    }

    #[test]
    fn a_fine_tune_moves_toward_the_rows_but_stays_anchored() {
        let base = Head {
            w1: vec![vec![0.1; ROUTE_FEATURE_COUNT]; 4],
            b1: vec![0.0; 4],
            w2: vec![0.1; 4],
            b2: 0.0,
        };
        let rows: Vec<RowInput> = (0..40)
            .map(|i| RowInput {
                o_lat: Some(43.0),
                o_lon: Some(-89.0),
                d_lat: Some(44.0),
                d_lon: Some(-88.0),
                week: Some(f64::from(i % 52)),
                target: Some(0.8),
                weight: Some(1.0),
                cross_country: Some(0.0),
            })
            .collect();
        let tuned =
            fine_tune(&base, &rows, TUNE_EPOCHS, TUNE_LEARNING_RATE, TUNE_ANCHOR).expect("tunes");
        assert_eq!(tuned.samples, 40);
        let before = mean_squared_error(&base, &rows).expect("rows");
        let after = mean_squared_error(&tuned.head, &rows).expect("rows");
        assert!(after < before);
        assert!(tuned
            .head
            .w1
            .iter()
            .flatten()
            .all(|w| (w - 0.1).abs() < 0.5));
        assert_eq!(fine_tune(&base, &[], 60, 0.01, 0.02), None);
        assert_eq!(
            fine_tune(&base, &rows, -1, 0.01, 0.02),
            None,
            "Swift trapped on 0..<-1"
        );
        let nan_week = RowInput {
            week: Some(f64::NAN),
            ..rows[0]
        };
        assert_eq!(
            mean_squared_error(&base, &[nan_week]),
            None,
            "Swift trapped on Int(NaN)"
        );
    }

    #[test]
    fn policy_gates() {
        let meta = |rows, tuned| {
            Some(HeadMeta {
                rows,
                tuned_on_device: tuned,
            })
        };
        assert_eq!(
            choose_head(meta(Some(1), Some(true)), meta(Some(9), None)),
            HeadChoice::Local
        );
        assert_eq!(
            choose_head(meta(Some(1), None), meta(Some(9), None)),
            HeadChoice::Bundled
        );
        assert_eq!(
            choose_head(meta(None, None), meta(None, None)),
            HeadChoice::Local
        );
        assert_eq!(choose_head(None, None), HeadChoice::None);
        assert!(tune_due(12, None, 7) && !tune_due(12, None, 8) && !tune_due(11, None, 0));
        assert!(!tune_due(20, Some(86_399.0), 0) && tune_due(20, Some(f64::NAN), 0));
        assert!(!tune_due(i64::MAX, None, -1));
        assert!(accept_tune(0.1, 0.1) && !accept_tune(f64::NAN, 1.0));
        assert_eq!(blend_prior(0.2, 0.6, 2.0), 0.6);
        assert_eq!(week_of_year(Some(1)), 0);
        assert_eq!(week_of_year(Some(366)), 51);
        assert_eq!(week_of_year(None), 0);
        assert_eq!(week_of_year(Some(i64::MIN)), 0);
        assert_eq!(
            mean_in_order(&[-0.0]).map(f64::to_bits),
            Some(0.0_f64.to_bits())
        );
    }
}
