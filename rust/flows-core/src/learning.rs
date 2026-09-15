// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Learned models: everyday radius, traffic delay, road efficiency, buffer and
//! refuel learning, the driving profile's ETA correction, and destination
//! prediction.
//!
//! State stays in Swift: the `Codable` stores, their sealed files and
//! UserDefaults entries, and the persisted key strings. These are the pure
//! update and predict functions over the values Swift passes in.
//!
//! Ported from the app's Swift at commit a007de0 and pinned bit for bit by the
//! frozen oracle in `flows-bridge/tests/fixtures/swift_learning_oracle.tsv`.
//! Swift semantics are reproduced exactly, including where they surprise:
//! - `min`/`max` are Swift's ([`crate::fcmp`]), so NaN travels the way it did
//!   in the app, and the argument order is the Swift source's;
//! - sorts are Swift's own stable sort ([`swift_sort_by`]): insertion sort
//!   below 64 elements, run merging above. Ties keep input order, and even a
//!   comparator made inconsistent by NaN orders elements as the app did;
//! - folds run from 0 in index order, as Swift's `reduce(0, +)` does;
//! - `Int(x)` from a Double traps in Swift outside its range, and so does Int
//!   overflow. Every in-range result is reproduced; each trapping case returns
//!   a documented value instead, named at the function.
//! - half-life decay is written `(t / -half_life).exp2()`, never
//!   `0.5.powf(t / half_life)`: the app's Release build compiles `pow(0.5, x)`
//!   to `exp2(-x)` (LLVM rewrites a power-of-two base), and so does an
//!   optimised Rust build, but a debug build calls libm `pow`, which differs
//!   by one ulp for about 0.4 % of arguments. The sign sits on the divisor,
//!   not on the quotient, so a NaN age keeps its sign in every build as it
//!   does in the app. The fixtures, being Release output, hold these values.
//!
//! Nothing here reads a clock, a calendar, a time zone or a locale. Callers
//! pass epoch or reference-date seconds, and the weekday and hour they already
//! computed. No function holds state, so any thread may call any of them.

use crate::fcmp::{smax, smin};

// =============================================================================
// Swift's stable sort
// =============================================================================

/// Sort `v` in place exactly as Swift 5's `Array.sort(by:)` does.
///
/// `lt(a, b)` is Swift's `areInIncreasingOrder`. The stdlib algorithm is
/// reproduced step for step: a whole-array insertion sort below 64 elements;
/// above that, natural runs (strictly descending ones reversed) extended to a
/// minimum length by insertion sort and merged under the stdlib's run-stack
/// invariants, preferring the earlier run on ties.
///
/// For a consistent comparator this is simply a stable sort. For one made
/// inconsistent by NaN, only this exact sequence of comparisons reproduces
/// the order the app produced.
///
/// Deterministic. Panics: none — every index stays inside `v` by
/// construction.
pub fn swift_sort_by<T: Copy>(v: &mut [T], mut lt: impl FnMut(T, T) -> bool) {
    let n = v.len();
    if n < 2 {
        return;
    }
    let min_run = min_merge_run_length(n);
    if n <= min_run {
        insertion_sort(v, 0, n, 1, &mut lt);
        return;
    }
    let mut buffer: Vec<T> = Vec::with_capacity(n);
    let mut runs: Vec<(usize, usize)> = Vec::new();
    let mut start = 0;
    while start < n {
        let (mut end, descending) = find_next_run(v, start, &mut lt);
        if descending {
            v[start..end].reverse();
        }
        if end < n && end - start < min_run {
            let new_end = n.min(start + min_run);
            insertion_sort(v, start, new_end, end, &mut lt);
            end = new_end;
        }
        runs.push((start, end));
        merge_top_runs(v, &mut runs, &mut buffer, &mut lt);
        start = end;
    }
    while runs.len() > 1 {
        let last = runs.len() - 1;
        merge_runs(v, &mut runs, last, &mut buffer, &mut lt);
    }
}

/// The stdlib's `_minimumMergeRunLength`: `c` itself below 64, otherwise the
/// top six bits of `c`, rounded up.
fn min_merge_run_length(c: usize) -> usize {
    const BITS_TO_USE: u32 = 6;
    let c64 = c as u64;
    if c64 < (1u64 << BITS_TO_USE) {
        return c;
    }
    // Int.bitWidth is 64 on every Apple target; leading_zeros <= 57 here.
    let offset = (64 - BITS_TO_USE) - c64.leading_zeros();
    let mask = (1u64 << offset) - 1;
    ((c64 >> offset) + u64::from(c64 & mask != 0)) as usize
}

/// The stdlib's `_insertionSort(within: lo..<hi, sortedEnd:)`.
fn insertion_sort<T: Copy>(
    v: &mut [T],
    lo: usize,
    hi: usize,
    sorted_end: usize,
    lt: &mut impl FnMut(T, T) -> bool,
) {
    let mut end = sorted_end;
    while end < hi {
        let mut i = end;
        // Swift's repeat-while: i > lo on entry, so i - 1 never underflows.
        loop {
            let j = i - 1;
            if !lt(v[i], v[j]) {
                break;
            }
            v.swap(i, j);
            i = j;
            if i == lo {
                break;
            }
        }
        end += 1;
    }
}

/// The stdlib's `_findNextRun`: the end of the run starting at `start`, and
/// whether it is strictly descending.
fn find_next_run<T: Copy>(
    v: &[T],
    start: usize,
    lt: &mut impl FnMut(T, T) -> bool,
) -> (usize, bool) {
    let n = v.len();
    let mut current = start + 1;
    if current == n {
        return (current, false);
    }
    let descending = lt(v[current], v[start]);
    loop {
        let previous = current;
        current += 1;
        if !(current < n && descending == lt(v[current], v[previous])) {
            break;
        }
    }
    (current, descending)
}

/// The stdlib's `_merge(low:mid:high:buffer:)`: the shorter side is buffered;
/// a low buffer merges forward, a high buffer merges backward, and on a tie
/// the element from the earlier run is placed first.
fn merge<T: Copy>(
    v: &mut [T],
    low: usize,
    mid: usize,
    high: usize,
    buffer: &mut Vec<T>,
    lt: &mut impl FnMut(T, T) -> bool,
) {
    buffer.clear();
    if mid - low < high - mid {
        buffer.extend_from_slice(&v[low..mid]);
        let buffer_high = buffer.len();
        let mut buffer_low = 0;
        let mut dest_low = low;
        let mut src_low = mid;
        while buffer_low < buffer_high && src_low < high {
            if lt(v[src_low], buffer[buffer_low]) {
                v[dest_low] = v[src_low];
                src_low += 1;
            } else {
                v[dest_low] = buffer[buffer_low];
                buffer_low += 1;
            }
            dest_low += 1;
        }
        let rest = buffer_high - buffer_low;
        v[dest_low..dest_low + rest].copy_from_slice(&buffer[buffer_low..buffer_high]);
    } else {
        buffer.extend_from_slice(&v[mid..high]);
        let mut buffer_high = buffer.len();
        let mut dest_high = high;
        let mut src_low = mid;
        // Swift tracks destLow separately; it always equals src_low.
        while 0 < buffer_high && low < src_low {
            dest_high -= 1;
            if lt(buffer[buffer_high - 1], v[src_low - 1]) {
                src_low -= 1;
                v[dest_high] = v[src_low];
            } else {
                buffer_high -= 1;
                v[dest_high] = buffer[buffer_high];
            }
        }
        v[src_low..src_low + buffer_high].copy_from_slice(&buffer[..buffer_high]);
    }
}

/// The stdlib's `_mergeRuns(at: i)`: merge run `i` into run `i - 1`.
fn merge_runs<T: Copy>(
    v: &mut [T],
    runs: &mut Vec<(usize, usize)>,
    i: usize,
    buffer: &mut Vec<T>,
    lt: &mut impl FnMut(T, T) -> bool,
) {
    let low = runs[i - 1].0;
    let middle = runs[i].0;
    let high = runs[i].1;
    merge(v, low, middle, high, buffer, lt);
    runs[i - 1] = (low, high);
    runs.remove(i);
}

/// The stdlib's `_mergeTopRuns`: restore the run-stack invariants
/// W > X + Y, X > Y + Z, Y > Z by merging from the top.
fn merge_top_runs<T: Copy>(
    v: &mut [T],
    runs: &mut Vec<(usize, usize)>,
    buffer: &mut Vec<T>,
    lt: &mut impl FnMut(T, T) -> bool,
) {
    let len = |r: (usize, usize)| r.1 - r.0;
    while runs.len() > 1 {
        let mut last = runs.len() - 1;
        // Swift tests W <= X + Y, then X <= Y + Z, with the same body for
        // both: merge Y with the smaller of X and Z.
        let w_breaks =
            last >= 3 && len(runs[last - 3]) <= len(runs[last - 2]) + len(runs[last - 1]);
        if w_breaks || (last >= 2 && len(runs[last - 2]) <= len(runs[last - 1]) + len(runs[last])) {
            if len(runs[last - 2]) < len(runs[last]) {
                last -= 1;
            }
        } else if len(runs[last - 1]) > len(runs[last]) {
            break;
        }
        merge_runs(v, runs, last, buffer, lt);
    }
}

/// Swift's `Int(x)` for an integral Double: `None` where Swift traps (NaN,
/// infinities, and values outside `-2^63 ... 2^63 - 1`).
pub fn swift_int(x: f64) -> Option<i64> {
    // The stdlib precondition, verbatim: x > -2^63 - 2048 && x < 2^63.
    (x > -9_223_372_036_854_777_856.0 && x < 9_223_372_036_854_775_808.0).then_some(x as i64)
}

// =============================================================================
// Everyday radius (EverydayRadius.swift)
// =============================================================================

/// The starting everyday radius, miles, used until enough trips are seen.
pub const EVERYDAY_DEFAULT_MILES: f64 = 20.0;
/// Lower sanity rail on the learned radius, miles.
pub const EVERYDAY_FLOOR_MILES: f64 = 3.0;
/// Upper sanity rail on the learned radius, miles.
pub const EVERYDAY_HARD_CAP_MILES: f64 = 150.0;
/// Trips (raw count, before filtering) before the quantile replaces the default.
pub const EVERYDAY_MIN_TRIPS_FOR_RADIUS: i64 = 30;
/// Trip lengths kept, most recent last.
pub const EVERYDAY_TRIP_WINDOW: i64 = 200;
/// Remembered places per category before one is evicted.
pub const EVERYDAY_MAX_PLACES_PER_CATEGORY: i64 = 50;
/// The quantile of recent trip lengths that sets the radius.
pub const EVERYDAY_RADIUS_QUANTILE: f64 = 0.85;
/// Fixed divisor for the normalised category feature. Frozen training contract.
pub const EVERYDAY_FEATURE_INDEX_SPACE: i64 = 16;
/// Length of the lookup-context feature vector. Frozen training contract.
pub const EVERYDAY_FEATURE_COUNT: i64 = 8;

/// Category storage key (the Swift `EverydayCategory` raw value) → its frozen
/// feature ordinal. A new category takes the next unused ordinal; an existing
/// one is never renumbered, because anything trained on the old encoding would
/// silently change meaning.
pub const EVERYDAY_CATEGORIES: [(&str, i64); 10] = [
    ("food", 0),
    ("fuel", 1),
    ("stores", 2),
    ("rest", 3),
    ("shelter", 4),
    ("medical", 5),
    ("hotels", 6),
    ("gyms", 7),
    ("parking", 8),
    ("showers", 9),
];

/// Inclusive-rank quantile `q` of the finite, non-negative values.
///
/// Values that are NaN, infinite or negative are ignored (-0.0 is kept). The
/// rest are sorted with Swift's sort, so a -0.0/+0.0 tie keeps input order,
/// and the result is `clean[lo] * (1 - f) + clean[hi] * f` with
/// `position = clamp(q, 0, 1) * (n - 1)`.
///
/// `None` when nothing survives the filter. Also `None` for a NaN `q` with at
/// least one survivor — Swift crashed there (`Int(NaN)`). Deterministic.
/// Panics: none.
pub fn everyday_quantile(values: &[f64], q: f64) -> Option<f64> {
    let mut clean: Vec<f64> = values
        .iter()
        .copied()
        .filter(|v| v.is_finite() && *v >= 0.0)
        .collect();
    swift_sort_by(&mut clean, |a, b| a < b);
    let last = clean.len().checked_sub(1)?;
    let position = smin(smax(q, 0.0), 1.0) * last as f64;
    let lower = position.floor();
    if lower.is_nan() {
        return None;
    }
    // position lies in [0, last], so the cast is exact.
    let lower_index = lower as usize;
    let upper_index = (lower_index + 1).min(last);
    let fraction = position - lower_index as f64;
    Some(clean[lower_index] * (1.0 - fraction) + clean[upper_index] * fraction)
}

/// The everyday radius, miles: the default until at least 30 trips are held
/// (raw count), then the p85 of the trip lengths held between 3 and 150; the
/// default again when no trip length is usable. Deterministic. Panics: none.
pub fn everyday_radius_miles(trip_miles: &[f64]) -> f64 {
    if (trip_miles.len() as u64) < EVERYDAY_MIN_TRIPS_FOR_RADIUS as u64 {
        return EVERYDAY_DEFAULT_MILES;
    }
    match everyday_quantile(trip_miles, EVERYDAY_RADIUS_QUANTILE) {
        Some(q) => smin(smax(q, EVERYDAY_FLOOR_MILES), EVERYDAY_HARD_CAP_MILES),
        None => EVERYDAY_DEFAULT_MILES,
    }
}

/// Mean trip length, miles, summed from 0 in index order; `None` when empty.
/// Deterministic. Panics: none.
pub fn everyday_mean_trip_miles(trip_miles: &[f64]) -> Option<f64> {
    if trip_miles.is_empty() {
        return None;
    }
    Some(trip_miles.iter().fold(0.0, |a, &x| a + x) / trip_miles.len() as f64)
}

/// Sample standard deviation (n − 1) of the trip lengths, miles; `None` below
/// two trips. Deterministic. Panics: none.
pub fn everyday_trip_miles_sd(trip_miles: &[f64]) -> Option<f64> {
    if trip_miles.len() < 2 {
        return None;
    }
    let mean = everyday_mean_trip_miles(trip_miles)?;
    let squares = trip_miles
        .iter()
        .fold(0.0, |a, &x| a + (x - mean) * (x - mean));
    Some((squares / (trip_miles.len() - 1) as f64).sqrt())
}

/// Whether a completed trip's straight-line miles may enter the window:
/// finite and not negative (-0.0 is accepted). Panics: none.
pub fn everyday_accepts_trip(miles: f64) -> bool {
    miles.is_finite() && miles >= 0.0
}

/// Time-of-day bucket for a clock hour: six 4-hour bins, wrapping, so -1 is
/// bucket 5 and 24 is bucket 0. Total over every i64. Panics: none.
///
/// Not the traffic model's bucket (which clamps the hour) nor ChoiceLog's
/// (`min(hour / 4, 5)`); the three differ out of range and are kept apart.
pub fn everyday_hour_bucket(hour: i64) -> i64 {
    // Swift: (((hour % 24) + 24) % 24) / 4 — the non-negative residue, which
    // is rem_euclid for every i64 (no step can overflow).
    hour.rem_euclid(24) / 4
}

/// The frozen feature ordinal of a category storage key; `None` for a key
/// that is not a category. Exact byte match. Panics: none.
pub fn everyday_feature_index(raw: &str) -> Option<i64> {
    EVERYDAY_CATEGORIES
        .iter()
        .find(|(name, _)| *name == raw)
        .map(|(_, index)| *index)
}

/// The lookup-context feature vector, in its frozen order:
/// `[sin a, cos a, weekend, startLat/90, startLon/180, placeLat/90,
/// placeLon/180, featureIndex/16]` with `a = 2π·hourBucket/6`. Degrees in,
/// roughly [-1, 1] out. Deterministic (the platform libm's sin and cos, as in
/// Swift). Panics: none.
#[allow(clippy::too_many_arguments)]
pub fn everyday_features(
    hour_bucket: i64,
    weekend: bool,
    start_lat: f64,
    start_lon: f64,
    place_lat: f64,
    place_lon: f64,
    feature_index: i64,
) -> [f64; 8] {
    let a = 2.0 * std::f64::consts::PI * hour_bucket as f64 / 6.0;
    let c = feature_index as f64;
    [
        a.sin(),
        a.cos(),
        if weekend { 1.0 } else { 0.0 },
        start_lat / 90.0,
        start_lon / 180.0,
        place_lat / 90.0,
        place_lon / 180.0,
        c / EVERYDAY_FEATURE_INDEX_SPACE as f64,
    ]
}

/// The order remembered places are offered in: most used first, then most
/// seen, then most recent tap (epoch seconds), then name ascending by bytes.
///
/// Returns input positions in display order; `None` when the four lists
/// differ in length. Swift compared the name with `String <`; for names in
/// Unicode NFC that is byte order, so callers pass NFC names (the Swift
/// facade normalises them). Swift's sort is reproduced, so ties keep input
/// order and a NaN tap time orders as it did. Panics: none.
pub fn everyday_ranked_order(
    uses: &[i64],
    seen: &[i64],
    last_used: &[f64],
    names: &[&str],
) -> Option<Vec<usize>> {
    let n = uses.len();
    if seen.len() != n || last_used.len() != n || names.len() != n {
        return None;
    }
    let mut order: Vec<usize> = (0..n).collect();
    // Swift: ($1.uses, $1.seen, $1.lastUsedT, $0.name)
    //      < ($0.uses, $0.seen, $0.lastUsedT, $1.name)
    swift_sort_by(&mut order, |a, b| {
        if uses[b] != uses[a] {
            return uses[b] < uses[a];
        }
        if seen[b] != seen[a] {
            return seen[b] < seen[a];
        }
        if last_used[b] != last_used[a] {
            return last_used[b] < last_used[a];
        }
        names[a] < names[b]
    });
    Some(order)
}

/// Which remembered place to drop when a category overflows: the FIRST place
/// with the smallest (uses, seen, last tap) tuple, compared as Swift compares
/// tuples. `None` when empty or the lists differ in length. Panics: none.
pub fn everyday_evict_index(uses: &[i64], seen: &[i64], last_used: &[f64]) -> Option<usize> {
    let n = uses.len();
    if n == 0 || seen.len() != n || last_used.len() != n {
        return None;
    }
    let less = |x: usize, y: usize| {
        if uses[x] != uses[y] {
            return uses[x] < uses[y];
        }
        if seen[x] != seen[y] {
            return seen[x] < seen[y];
        }
        last_used[x] < last_used[y]
    };
    let mut result = 0;
    for e in 1..n {
        if less(e, result) {
            result = e;
        }
    }
    Some(result)
}

// =============================================================================
// Decay shared by the traffic and road-efficiency models
// =============================================================================

/// A decay factor at or above this is too small to bother applying; the
/// elapsed interval is then skipped, not accumulated.
pub const DECAY_SKIP_AT: f64 = 0.999;

/// What one `decay(to: now)` call does to a store.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DecayPlan {
    /// Multiply every cell's weighted sum and weight by `factor`.
    pub apply: bool,
    /// `0.5^((now − last)/halfLife)` when computed; 1 when not.
    pub factor: f64,
    /// The store's `lastDecay` afterwards, epoch seconds.
    pub last_decay: f64,
}

/// Plan a half-life decay from `last_decay` to `now` (epoch seconds).
///
/// - `last_decay` not > 0, or `now` not later: nothing decays; a `last_decay`
///   of exactly zero (either sign) becomes `now`, anything else is kept.
/// - factor ≥ 0.999 (or NaN): nothing decays and `last_decay` is kept, so
///   that short interval is never applied — the shipping behaviour, since each
///   record then sets `last_decay = now`.
/// - otherwise every cell is scaled by the factor and `last_decay` = `now`.
///
/// Deterministic (platform libm `pow`, as in Swift). Panics: none.
pub fn decay_plan(last_decay: f64, now: f64, half_life_seconds: f64) -> DecayPlan {
    if !(last_decay > 0.0 && now > last_decay) {
        let kept = if last_decay == 0.0 { now } else { last_decay };
        return DecayPlan {
            apply: false,
            factor: 1.0,
            last_decay: kept,
        };
    }
    // Swift's Release build compiles pow(0.5, x) as exp2(x / -1); written out with the sign on the divisor so every build agrees (module doc).
    let factor = ((now - last_decay) / -half_life_seconds).exp2();
    if factor < DECAY_SKIP_AT {
        DecayPlan {
            apply: true,
            factor,
            last_decay: now,
        }
    } else {
        // Includes a NaN factor, as Swift's `guard factor < 0.999` did.
        DecayPlan {
            apply: false,
            factor,
            last_decay,
        }
    }
}

/// Every value multiplied by `factor` (`value * factor`, in that operand
/// order), in input order. Panics: none.
pub fn scale_all(values: &[f64], factor: f64) -> Vec<f64> {
    values.iter().map(|v| v * factor).collect()
}

// =============================================================================
// Traffic delay (TrafficLearning.swift)
// =============================================================================

/// Observations halve in influence after this many seconds (120 days).
pub const TRAFFIC_HALF_LIFE_SECONDS: f64 = 120.0 * 24.0 * 3600.0;
/// Trips in a cell before it may move an ETA.
pub const TRAFFIC_CONFIDENT_AFTER: i64 = 4;
/// Largest learned delay factor.
pub const TRAFFIC_MAX_FACTOR: f64 = 2.5;
/// Smallest learned delay factor.
pub const TRAFFIC_MIN_FACTOR: f64 = 0.7;
/// A trip averaging at least this many mph ran on highway.
pub const HIGHWAY_MIN_MPH: f64 = 45.0;
/// A router estimate must exceed this many seconds to teach anything.
pub const TRAFFIC_MIN_PREDICTED_SECONDS: f64 = 60.0;
/// Observed delay ratios are held in `[0.5, 3.0]` before folding in.
pub const TRAFFIC_RATIO_LOW: f64 = 0.5;
/// See [`TRAFFIC_RATIO_LOW`].
pub const TRAFFIC_RATIO_HIGH: f64 = 3.0;

/// The weather buckets the delay model learns on, in the Swift
/// `TrafficWeather.allCases` order; the discriminant is the bridge code.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrafficWeather {
    Clear = 0,
    Rain = 1,
    Snow = 2,
    Ice = 3,
    Fog = 4,
    Wind = 5,
}

/// The persisted raw value of each [`TrafficWeather`], by code. These strings
/// are embedded in stored cell keys and must never change.
pub const TRAFFIC_WEATHER_NAMES: [&str; 6] = ["clear", "rain", "snow", "ice", "fog", "wind"];

/// The weather bucket for a hazard family name (`None` = no family): rain for
/// `qpf_flood`/`precip`/`tropical`, snow for `winter`, ice, fog for
/// `fog`/`haze`, wind; clear for anything else. Exact, case-sensitive match.
/// Panics: none.
pub fn traffic_weather_from_family(family: Option<&str>) -> TrafficWeather {
    match family {
        Some("qpf_flood" | "precip" | "tropical") => TrafficWeather::Rain,
        Some("winter") => TrafficWeather::Snow,
        Some("ice") => TrafficWeather::Ice,
        Some("fog" | "haze") => TrafficWeather::Fog,
        Some("wind") => TrafficWeather::Wind,
        _ => TrafficWeather::Clear,
    }
}

/// Whether a trip that averaged `average_mph` counts as highway (≥ 45; NaN is
/// local). Panics: none.
pub fn road_class_is_highway(average_mph: f64) -> bool {
    average_mph >= HIGHWAY_MIN_MPH
}

/// One learned delay cell: a decaying sum of delay ratios, its decaying
/// weight, and the raw (undecayed) trip count.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DelayCell {
    pub weighted_sum: f64,
    pub weight: f64,
    pub count: i64,
}

impl DelayCell {
    /// Mean delay ratio; 1 (no adjustment) unless the weight is positive.
    pub fn mean(self) -> f64 {
        if self.weight > 0.0 {
            self.weighted_sum / self.weight
        } else {
            1.0
        }
    }
}

/// Whether a finished trip may teach the delay model: the router promised
/// more than 60 s and the trip took a positive time. Checked before any
/// decay. Panics: none.
pub fn traffic_accepts(predicted_seconds: f64, actual_seconds: f64) -> bool {
    predicted_seconds > TRAFFIC_MIN_PREDICTED_SECONDS && actual_seconds > 0.0
}

/// Fold one accepted trip into its (already decayed) cell: the ratio
/// actual ÷ predicted held in [0.5, 3] is added to the sum, the weight gains
/// 1, the count gains 1. `None` when the count is `i64::MAX` — Swift crashed
/// there (Int overflow); the observation is then dropped. Panics: none.
pub fn traffic_add(
    cell: DelayCell,
    predicted_seconds: f64,
    actual_seconds: f64,
) -> Option<DelayCell> {
    let ratio = smin(
        smax(actual_seconds / predicted_seconds, TRAFFIC_RATIO_LOW),
        TRAFFIC_RATIO_HIGH,
    );
    let count = cell.count.checked_add(1)?;
    Some(DelayCell {
        weighted_sum: cell.weighted_sum + ratio,
        weight: cell.weight + 1.0,
        count,
    })
}

/// The learned ETA multiplier. A local trip reads its neighbourhood's local
/// cell, then the pooled highway cell; a highway trip reads only the pooled
/// highway cell. The first cell with at least 4 trips gives its mean held in
/// [0.7, 2.5]; otherwise 1. `None` marks a cell that does not exist.
/// Panics: none.
pub fn traffic_factor(
    is_highway: bool,
    local: Option<DelayCell>,
    pooled: Option<DelayCell>,
) -> f64 {
    let ladder = if is_highway {
        [pooled, None]
    } else {
        [local, pooled]
    };
    for cell in ladder.into_iter().flatten() {
        if cell.count >= TRAFFIC_CONFIDENT_AFTER {
            return smin(smax(cell.mean(), TRAFFIC_MIN_FACTOR), TRAFFIC_MAX_FACTOR);
        }
    }
    1.0
}

/// The ETA this model expects, seconds: `router_seconds × factor`.
/// Panics: none.
pub fn traffic_adjusted_seconds(
    router_seconds: f64,
    is_highway: bool,
    local: Option<DelayCell>,
    pooled: Option<DelayCell>,
) -> f64 {
    router_seconds * traffic_factor(is_highway, local, pooled)
}

/// Extra whole minutes over the router's estimate, rounded half away from
/// zero. `None` when that is not a representable Int (a NaN or infinite
/// router estimate) — Swift crashed there. Panics: none.
pub fn traffic_delay_minutes(
    router_seconds: f64,
    is_highway: bool,
    local: Option<DelayCell>,
    pooled: Option<DelayCell>,
) -> Option<i64> {
    let extra =
        traffic_adjusted_seconds(router_seconds, is_highway, local, pooled) - router_seconds;
    swift_int((extra / 60.0).round())
}

/// Whether a cell holding `count` trips has earned a say (≥ 4). An absent
/// cell counts 0. Panics: none.
pub fn traffic_is_confident(count: i64) -> bool {
    count >= TRAFFIC_CONFIDENT_AFTER
}

// =============================================================================
// Road efficiency (RoadEfficiencyLearning.swift)
// =============================================================================

/// Measurements halve in influence after this many seconds (180 days).
pub const EFFICIENCY_HALF_LIFE_SECONDS: f64 = 180.0 * 24.0 * 3600.0;
/// Measured miles in a cell before it may override the rated economy.
pub const EFFICIENCY_CONFIDENT_MILES: f64 = 25.0;
/// Smallest learned ÷ rated economy ratio.
pub const EFFICIENCY_MIN_RATIO: f64 = 0.5;
/// Largest learned ÷ rated economy ratio.
pub const EFFICIENCY_MAX_RATIO: f64 = 1.6;
/// A stretch must exceed this many miles to be measured.
pub const EFFICIENCY_MIN_MILES: f64 = 0.5;
/// A stretch must burn more than this many fuel units to be measured.
pub const EFFICIENCY_MIN_UNITS: f64 = 0.001;

/// One learned economy cell: a decaying miles-weighted sum of miles per unit,
/// its decaying weight (miles), and the raw miles measured.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EfficiencyCell {
    pub weighted_sum: f64,
    pub weight: f64,
    pub miles: f64,
}

impl EfficiencyCell {
    /// Mean miles per unit; 0 unless the weight is positive.
    pub fn mean(self) -> f64 {
        if self.weight > 0.0 {
            self.weighted_sum / self.weight
        } else {
            0.0
        }
    }
}

/// Whether a measured stretch may teach the model: more than 0.5 miles, more
/// than 0.001 units, and a finite positive miles-per-unit. Checked before any
/// decay. Panics: none.
pub fn efficiency_accepts(miles_driven: f64, units_burned: f64) -> bool {
    if !(miles_driven > EFFICIENCY_MIN_MILES && units_burned > EFFICIENCY_MIN_UNITS) {
        return false;
    }
    let measured = miles_driven / units_burned;
    measured.is_finite() && measured > 0.0
}

/// Fold one accepted stretch into its (already decayed) cell, weighted by
/// distance: sum += (miles ÷ units) × miles, weight += miles, miles += miles.
/// Panics: none.
pub fn efficiency_add(
    cell: EfficiencyCell,
    miles_driven: f64,
    units_burned: f64,
) -> EfficiencyCell {
    let measured = miles_driven / units_burned;
    EfficiencyCell {
        weighted_sum: cell.weighted_sum + measured * miles_driven,
        weight: cell.weight + miles_driven,
        miles: cell.miles + miles_driven,
    }
}

/// The economy to plan with, miles per unit. Same ladder as
/// [`traffic_factor`]; the first cell with at least 25 measured miles and a
/// positive mean gives `rated × clamp(mean ÷ rated, 0.5, 1.6)`; otherwise the
/// rated figure. Panics: none.
pub fn efficiency_economy(
    rated_miles_per_unit: f64,
    is_highway: bool,
    local: Option<EfficiencyCell>,
    pooled: Option<EfficiencyCell>,
) -> f64 {
    let ladder = if is_highway {
        [pooled, None]
    } else {
        [local, pooled]
    };
    for cell in ladder.into_iter().flatten() {
        if cell.miles >= EFFICIENCY_CONFIDENT_MILES && cell.mean() > 0.0 {
            let ratio = smin(
                smax(cell.mean() / rated_miles_per_unit, EFFICIENCY_MIN_RATIO),
                EFFICIENCY_MAX_RATIO,
            );
            return rated_miles_per_unit * ratio;
        }
    }
    rated_miles_per_unit
}

/// Whether a cell with `miles` measured can speak for its road (≥ 25). An
/// absent cell counts 0. Panics: none.
pub fn efficiency_is_confident(miles: f64) -> bool {
    miles >= EFFICIENCY_CONFIDENT_MILES
}

// =============================================================================
// Streaming buffer depth (BufferLearning.swift)
// =============================================================================

/// Weight on the newest buffer-depth sample.
pub const BUFFER_ALPHA: f64 = 0.35;
/// Samples before the learned mean replaces the documented prior.
pub const BUFFER_MIN_SAMPLES_TO_TRUST: i64 = 3;
/// Shortest plausible buffer depth, seconds (inclusive).
pub const BUFFER_PLAUSIBLE_LOW: f64 = 1.0;
/// Longest plausible buffer depth, seconds (inclusive).
pub const BUFFER_PLAUSIBLE_HIGH: f64 = 180.0;

/// Whether a measured buffer depth (seconds) is a real sample: finite and in
/// [1, 180]. Panics: none.
pub fn buffer_is_usable(sample: f64) -> bool {
    sample.is_finite() && (BUFFER_PLAUSIBLE_LOW..=BUFFER_PLAUSIBLE_HIGH).contains(&sample)
}

/// The running mean after one sample: unchanged for an unusable sample
/// (discarded, not clamped), the sample itself as the first mean, else
/// `mean × 0.65 + sample × 0.35`. Panics: none.
pub fn buffer_updated(mean: Option<f64>, sample: f64) -> Option<f64> {
    if !buffer_is_usable(sample) {
        return mean;
    }
    Some(match mean {
        None => sample,
        Some(m) => m * (1.0 - BUFFER_ALPHA) + sample * BUFFER_ALPHA,
    })
}

/// How long to wait (seconds): the learned mean once it exists and has at
/// least 3 samples, else the prior. Panics: none.
pub fn buffer_wait_seconds(prior: f64, learned_mean: Option<f64>, samples: i64) -> f64 {
    match learned_mean {
        Some(mean) if samples >= BUFFER_MIN_SAMPLES_TO_TRUST => mean,
        _ => prior,
    }
}

// =============================================================================
// Refuel check-ins and the stale gauge (RefuelLearning.swift)
// =============================================================================

/// Accuracy below which the gauge keeps asking.
pub const REFUEL_ACCURACY_FLOOR: f64 = 0.8;
/// Answers the accuracy is computed over (the most recent).
pub const REFUEL_WINDOW: i64 = 10;
/// Answers retained in the store (the most recent).
pub const REFUEL_RETAINED: i64 = 50;
/// A gap this long, seconds (a week), makes the fuel reading untrustworthy.
pub const STALE_GAUGE_GAP_SECONDS: f64 = 7.0 * 86_400.0;

/// Rolling accuracy over the last 10 answers: `max(0, 1 − mean error)`, with
/// the Swift argument order, so a NaN mean gives 0 rather than NaN. 0 with no
/// answers. Panics: none.
pub fn refuel_accuracy(errors: &[f64]) -> f64 {
    if errors.is_empty() {
        return 0.0;
    }
    let start = errors.len().saturating_sub(REFUEL_WINDOW as usize);
    let recent = &errors[start..];
    let sum = recent.iter().fold(0.0, |a, &e| a + e);
    smax(0.0, 1.0 - sum / recent.len() as f64)
}

/// One answered check-in's error: `|clamp(predicted) − clamp(reported)|`, each
/// fraction held in [0, 1] with Swift's min/max (a NaN passes through).
/// Panics: none.
pub fn refuel_error(predicted_fraction: f64, reported_fraction: f64) -> f64 {
    let p = smin(smax(predicted_fraction, 0.0), 1.0);
    let r = smin(smax(reported_fraction, 0.0), 1.0);
    (p - r).abs()
}

/// Whether to ask the gauge question: check-ins enabled and accuracy under
/// 0.8. Panics: none.
pub fn refuel_should_prompt(check_ins_enabled: bool, accuracy: f64) -> bool {
    check_ins_enabled && accuracy < REFUEL_ACCURACY_FLOOR
}

/// Whether the fuel reading went stale: the app was last used (seconds, any
/// fixed epoch; the Swift facade passes reference-date seconds, which is what
/// `Date` stores) at least a week before `now`. Never on a first run
/// (`None`). Panics: none.
pub fn gauge_went_stale(last_used: Option<f64>, now: f64) -> bool {
    last_used.is_some_and(|last| now - last >= STALE_GAUGE_GAP_SECONDS)
}

// =============================================================================
// Personal ETA correction (DrivingProfile.swift)
// =============================================================================

/// Smallest actual ÷ predicted ratio that is driving style.
pub const ETA_MIN_PLAUSIBLE_RATIO: f64 = 0.6;
/// Largest actual ÷ predicted ratio that is driving style.
pub const ETA_MAX_PLAUSIBLE_RATIO: f64 = 1.8;
/// Samples before the correction may move an ETA.
pub const ETA_MIN_SAMPLES_TO_APPLY: i64 = 5;
/// Corrections closer to 1 than this are noise.
pub const ETA_MIN_MEANINGFUL_DEVIATION: f64 = 0.03;
/// Smallest applied ETA multiplier.
pub const ETA_CLAMP_LOW: f64 = 0.75;
/// Largest applied ETA multiplier.
pub const ETA_CLAMP_HIGH: f64 = 1.4;
/// Floor on the per-sample learning rate.
pub const ETA_ALPHA_FLOOR: f64 = 0.08;
/// Predicted and driving times must exceed this many seconds.
pub const ETA_MIN_SECONDS: f64 = 60.0;

/// The learned ETA state Swift persists.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EtaState {
    /// EWMA of ln(actual ÷ predicted).
    pub log_ratio: f64,
    /// Samples folded in.
    pub samples: i64,
}

/// The multiplier for a routing ETA: 1 below 5 samples or when `exp(log
/// ratio)` is within 0.03 of 1 (NaN included); otherwise held in [0.75, 1.4].
/// Deterministic (platform libm `exp`). Panics: none.
pub fn eta_multiplier(log_ratio: f64, samples: i64) -> f64 {
    if samples < ETA_MIN_SAMPLES_TO_APPLY {
        return 1.0;
    }
    let raw = log_ratio.exp();
    if (raw - 1.0).abs() >= ETA_MIN_MEANINGFUL_DEVIATION {
        smin(smax(raw, ETA_CLAMP_LOW), ETA_CLAMP_HIGH)
    } else {
        // Includes NaN, as Swift's `guard abs(raw - 1) >= …` did.
        1.0
    }
}

/// Fold one arrival (seconds) into the correction. Chosen stop time
/// (`max(stopped, 0)`, NaN kept) is removed first; predicted and driving time
/// must both be finite and over 60 s, and their ratio in [0.6, 1.8]. The rate
/// is `max(1/(n+1), 0.08)`; the new log ratio is
/// `old × (1 − rate) + ln(ratio) × rate`.
///
/// `None` when the arrival is rejected, and when `samples` is `i64::MAX` —
/// Swift crashed there (Int overflow); the profile is then left unchanged.
/// Deterministic (platform libm `log`). Panics: none.
pub fn eta_record(
    state: EtaState,
    predicted_seconds: f64,
    actual_seconds: f64,
    stopped_seconds: f64,
) -> Option<EtaState> {
    let driving = actual_seconds - smax(stopped_seconds, 0.0);
    if !(predicted_seconds > ETA_MIN_SECONDS
        && driving > ETA_MIN_SECONDS
        && predicted_seconds.is_finite()
        && driving.is_finite())
    {
        return None;
    }
    let ratio = driving / predicted_seconds;
    if !(ETA_MIN_PLAUSIBLE_RATIO..=ETA_MAX_PLAUSIBLE_RATIO).contains(&ratio) {
        return None;
    }
    let samples = state.samples.checked_add(1)?;
    let alpha = smax(1.0 / samples as f64, ETA_ALPHA_FLOOR);
    Some(EtaState {
        log_ratio: state.log_ratio * (1.0 - alpha) + ratio.ln() * alpha,
        samples,
    })
}

// =============================================================================
// Destination prediction (DestinationPrediction.swift)
// =============================================================================

/// Recency half-life, days.
pub const DESTINATION_RECENCY_HALF_LIFE_DAYS: f64 = 21.0;
/// Weight on a tap in the exact current context.
pub const DESTINATION_CONTEXT_WEIGHT: f64 = 3.0;
/// Weight on a tap in this hour bucket and day type, from anywhere.
pub const DESTINATION_TIME_WEIGHT: f64 = 1.5;
/// Weight on any tap ever.
pub const DESTINATION_BASE_WEIGHT: f64 = 1.0;
/// Recency given to a place with no recorded use time.
pub const DESTINATION_UNUSED_RECENCY: f64 = 0.35;
/// Seconds per day for the recency age.
pub const SECONDS_PER_DAY: f64 = 86_400.0;
/// Normalised top score needed to offer a prediction unprompted.
pub const DESTINATION_CONFIDENT_SCORE: f64 = 0.5;
/// Evidence needed to offer a prediction unprompted.
pub const DESTINATION_CONFIDENT_MIN_EVIDENCE: i64 = 3;

/// Evidence for one place.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Evidence {
    /// Taps in the current context.
    pub context_hits: i64,
    /// Taps in this hour bucket and day type, from anywhere.
    pub time_hits: i64,
    /// All taps ever.
    pub total_hits: i64,
    /// Epoch seconds of the latest use; not > 0 means never recorded.
    pub last_used: f64,
}

/// Which plain-words reason explains a candidate; Swift owns the words.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DestinationReason {
    /// contextHits ≥ 3: "You usually go here about now".
    UsuallyNow = 0,
    /// contextHits > 0: "You've come here at this time".
    CameAtThisTime = 1,
    /// timeHits ≥ 3: "A regular stop at this hour".
    RegularAtThisHour = 2,
    /// totalHits ≥ 5: "One of your regular places".
    RegularPlace = 3,
    /// Otherwise: "You've been here recently".
    Recent = 4,
}

/// The reason for a candidate, tested in that order. Panics: none.
pub fn destination_reason(context_hits: i64, time_hits: i64, total_hits: i64) -> DestinationReason {
    if context_hits >= 3 {
        DestinationReason::UsuallyNow
    } else if context_hits > 0 {
        DestinationReason::CameAtThisTime
    } else if time_hits >= 3 {
        DestinationReason::RegularAtThisHour
    } else if total_hits >= 5 {
        DestinationReason::RegularPlace
    } else {
        DestinationReason::Recent
    }
}

/// One ranked destination.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RankedDestination {
    /// Position in the evidence list.
    pub index: usize,
    /// Score ÷ best score.
    pub score: f64,
    pub reason: DestinationReason,
}

/// Rank places for the driver's current moment (`now`, epoch seconds).
///
/// counts = 3·context + 1.5·time + 1·total (in that order); places without
/// positive counts are dropped. recency = `0.5^(max(now − last, 0)/86400/21)`
/// when `last_used` > 0, else 0.35. score = counts × recency. The best score is
/// the first maximum; unless it is > 0 the answer is empty. The survivors are
/// sorted by descending score with Swift's sort (ties keep input order), the
/// first `limit` kept, each score divided by the best.
///
/// A negative `limit` with a positive best score gives an empty answer —
/// Swift crashed there (a negative `prefix`). Deterministic (platform libm
/// `pow`). Panics: none.
pub fn destination_rank(evidence: &[Evidence], now: f64, limit: i64) -> Vec<RankedDestination> {
    let mut scored: Vec<(usize, f64)> = Vec::new();
    for (i, e) in evidence.iter().enumerate() {
        let counts = e.context_hits as f64 * DESTINATION_CONTEXT_WEIGHT
            + e.time_hits as f64 * DESTINATION_TIME_WEIGHT
            + e.total_hits as f64 * DESTINATION_BASE_WEIGHT;
        if counts > 0.0 {
            let age_days = smax(now - e.last_used, 0.0) / SECONDS_PER_DAY;
            let recency = if e.last_used > 0.0 {
                // Swift's Release build compiles pow(0.5, x) as exp2(x / -1); written out with the sign on the divisor so every build agrees (module doc).
                (age_days / -DESTINATION_RECENCY_HALF_LIFE_DAYS).exp2()
            } else {
                DESTINATION_UNUSED_RECENCY
            };
            scored.push((i, counts * recency));
        }
    }
    // Swift's Sequence.max(): the running best is replaced only when best < e.
    let Some((&(_, first), rest)) = scored.split_first() else {
        return Vec::new();
    };
    let mut best = first;
    for &(_, s) in rest {
        if best < s {
            best = s;
        }
    }
    // A NaN best also answers nothing, as Swift's `guard best > 0` did.
    let positive = best > 0.0;
    if !positive {
        return Vec::new();
    }
    let Ok(limit) = usize::try_from(limit) else {
        return Vec::new();
    };
    let mut order: Vec<usize> = (0..scored.len()).collect();
    swift_sort_by(&mut order, |a, b| scored[a].1 > scored[b].1);
    order
        .into_iter()
        .take(limit)
        .map(|k| {
            let (index, score) = scored[k];
            let e = evidence[index];
            RankedDestination {
                index,
                score: score / best,
                reason: destination_reason(e.context_hits, e.time_hits, e.total_hits),
            }
        })
        .collect()
}

/// Whether to offer the top prediction unprompted: there is one, its score is
/// at least 0.5, and `minimum_evidence` is at least 3. Panics: none.
pub fn destination_is_confident(top_score: Option<f64>, minimum_evidence: i64) -> bool {
    top_score.is_some_and(|s| {
        s >= DESTINATION_CONFIDENT_SCORE && minimum_evidence >= DESTINATION_CONFIDENT_MIN_EVIDENCE
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = self.0;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^ (z >> 31)
        }
        fn below(&mut self, n: u64) -> u64 {
            self.next() % n
        }
    }

    #[test]
    fn swift_sort_is_a_stable_sort_for_a_consistent_comparator() {
        let mut rng = Rng(1);
        for n in [0usize, 1, 2, 3, 20, 63, 64, 65, 100, 129, 257, 1000, 3000] {
            for _ in 0..20 {
                let keys: Vec<(u64, usize)> = (0..n).map(|i| (rng.below(7), i)).collect();
                let mut ours = keys.clone();
                swift_sort_by(&mut ours, |a, b| a.0 < b.0);
                let mut std_stable = keys.clone();
                std_stable.sort_by_key(|k| k.0);
                assert_eq!(ours, std_stable, "n = {n}");
            }
        }
    }

    #[test]
    fn swift_sort_survives_a_comparator_that_is_not_an_order() {
        let mut rng = Rng(2);
        for n in [5usize, 64, 200, 1500] {
            let mut v: Vec<f64> = (0..n)
                .map(|_| [f64::NAN, 1.0, 2.0, -0.0, 0.0][rng.below(5) as usize])
                .collect();
            let before = v.len();
            swift_sort_by(&mut v, |a, b| a > b);
            assert_eq!(v.len(), before);
        }
    }

    #[test]
    fn min_run_length_matches_the_stdlib_formula() {
        assert_eq!(min_merge_run_length(63), 63);
        assert_eq!(min_merge_run_length(64), 32);
        assert_eq!(min_merge_run_length(65), 33);
        assert_eq!(min_merge_run_length(1000), 63);
        assert_eq!(min_merge_run_length(1024), 32);
    }

    #[test]
    fn swift_int_accepts_exactly_the_range_swift_does() {
        assert_eq!(swift_int(-9_223_372_036_854_775_808.0), Some(i64::MIN));
        assert_eq!(swift_int(9_223_372_036_854_775_808.0), None);
        assert_eq!(
            swift_int(9_223_372_036_854_774_784.0),
            Some(9_223_372_036_854_774_784)
        );
        assert_eq!(swift_int(f64::NAN), None);
        assert_eq!(swift_int(f64::NEG_INFINITY), None);
        assert_eq!(swift_int(-2.0), Some(-2));
    }

    #[test]
    fn the_radius_waits_for_thirty_trips_then_follows_p85_within_the_rails() {
        assert_eq!(everyday_radius_miles(&[4.0; 29]), 20.0);
        assert!(everyday_radius_miles(&[4.0; 30]) < 5.0);
        assert_eq!(everyday_radius_miles(&[35.0; 40]), 35.0);
        assert_eq!(everyday_radius_miles(&[400.0; 40]), 150.0);
        assert_eq!(everyday_radius_miles(&[0.2; 40]), 3.0);
        // Thirty unusable lengths: the gate passes on raw count, the quantile
        // has nothing, and the default stands.
        assert_eq!(everyday_radius_miles(&[f64::NAN; 30]), 20.0);
    }

    #[test]
    fn the_quantile_interpolates_and_ignores_unusable_values() {
        let v = [1.0, 2.0, 3.0, 4.0, 5.0];
        assert_eq!(everyday_quantile(&v, 0.0), Some(1.0));
        assert_eq!(everyday_quantile(&v, 1.0), Some(5.0));
        assert_eq!(everyday_quantile(&v, 0.25), Some(2.0));
        assert_eq!(everyday_quantile(&[], 0.5), None);
        assert_eq!(
            everyday_quantile(&[f64::NAN, -3.0, 4.0, 4.0], 0.5),
            Some(4.0)
        );
        // Where Swift trapped: a NaN rank over real values.
        assert_eq!(everyday_quantile(&[1.0], f64::NAN), None);
        assert_eq!(everyday_quantile(&[-1.0], f64::NAN), None);
    }

    #[test]
    fn hour_buckets_wrap_over_every_integer() {
        assert_eq!(everyday_hour_bucket(0), 0);
        assert_eq!(everyday_hour_bucket(23), 5);
        assert_eq!(everyday_hour_bucket(24), 0);
        assert_eq!(everyday_hour_bucket(-1), 5);
        // i64::MIN % 24 is -8 in Swift: ((-8 + 24) % 24) / 4 = 4.
        assert_eq!(everyday_hour_bucket(i64::MIN), 4);
        assert!((0..=5).contains(&everyday_hour_bucket(i64::MAX)));
    }

    #[test]
    fn feature_ordinals_are_frozen_and_unique() {
        assert_eq!(everyday_feature_index("food"), Some(0));
        assert_eq!(everyday_feature_index("gyms"), Some(7));
        assert_eq!(everyday_feature_index("showers"), Some(9));
        assert_eq!(everyday_feature_index("Food"), None);
        let mut seen: Vec<i64> = EVERYDAY_CATEGORIES.iter().map(|c| c.1).collect();
        seen.sort_unstable();
        seen.dedup();
        assert_eq!(seen.len(), EVERYDAY_CATEGORIES.len());
        assert!(seen.iter().all(|i| *i < EVERYDAY_FEATURE_INDEX_SPACE));
        let v = everyday_features(2, false, 43.0, -89.0, 43.1, -89.1, 1);
        assert_eq!(v.len() as i64, EVERYDAY_FEATURE_COUNT);
        assert_eq!(v[7], 1.0 / 16.0);
    }

    #[test]
    fn places_rank_by_use_then_sightings_then_recency_then_name() {
        let order = everyday_ranked_order(
            &[0, 5, 2, 2],
            &[1, 1, 3, 3],
            &[0.0, 1.0, 2.0, 2.0],
            &["Rarely", "Often", "b", "a"],
        );
        assert_eq!(order, Some(vec![1, 3, 2, 0]));
        assert_eq!(everyday_ranked_order(&[1], &[], &[], &[]), None);
    }

    #[test]
    fn eviction_takes_the_first_least_used_place() {
        assert_eq!(
            everyday_evict_index(&[1, 0, 0, 0], &[1, 2, 1, 1], &[0.0, 0.0, 5.0, 5.0]),
            Some(2)
        );
        assert_eq!(everyday_evict_index(&[], &[], &[]), None);
    }

    #[test]
    fn short_decay_intervals_are_skipped_and_zero_starts_the_clock() {
        let start = decay_plan(0.0, 100.0, TRAFFIC_HALF_LIFE_SECONDS);
        assert!(!start.apply);
        assert_eq!(start.last_decay, 100.0);
        let short = decay_plan(1.7e9, 1.7e9 + 3600.0, TRAFFIC_HALF_LIFE_SECONDS);
        assert!(!short.apply);
        assert_eq!(short.last_decay, 1.7e9);
        let year = decay_plan(1.7e9, 1.7e9 + 365.0 * 86_400.0, TRAFFIC_HALF_LIFE_SECONDS);
        assert!(year.apply && year.factor < 0.25);
        assert_eq!(year.last_decay, 1.7e9 + 365.0 * 86_400.0);
        let backwards = decay_plan(10.0, 5.0, TRAFFIC_HALF_LIFE_SECONDS);
        assert!(!backwards.apply);
        assert_eq!(backwards.last_decay, 10.0);
    }

    #[test]
    fn traffic_waits_for_four_trips_and_pools_highways() {
        let cell = |count| {
            Some(DelayCell {
                weighted_sum: 4.5,
                weight: 3.0,
                count,
            })
        };
        assert_eq!(traffic_factor(false, cell(3), None), 1.0);
        assert_eq!(traffic_factor(false, cell(4), None), 1.5);
        assert_eq!(traffic_factor(false, None, cell(4)), 1.5);
        assert_eq!(traffic_factor(true, cell(9), None), 1.0);
        assert_eq!(
            traffic_delay_minutes(1800.0, false, cell(6), None),
            Some(15)
        );
        // Where Swift trapped: an infinite router estimate.
        assert_eq!(
            traffic_delay_minutes(f64::INFINITY, false, cell(6), None),
            None
        );
        assert!(!traffic_accepts(60.0, 900.0));
        assert!(!traffic_accepts(900.0, -5.0));
        let full = DelayCell {
            weighted_sum: 0.0,
            weight: 0.0,
            count: i64::MAX,
        };
        assert_eq!(traffic_add(full, 900.0, 900.0), None);
        assert_eq!(
            traffic_weather_from_family(Some("qpf_flood")),
            TrafficWeather::Rain
        );
        assert_eq!(traffic_weather_from_family(None), TrafficWeather::Clear);
        assert_eq!(TRAFFIC_WEATHER_NAMES[TrafficWeather::Wind as usize], "wind");
        assert!(road_class_is_highway(45.0) && !road_class_is_highway(f64::NAN));
    }

    #[test]
    fn economy_stands_rated_until_twenty_five_miles_and_is_clamped() {
        let cell = |miles| {
            Some(EfficiencyCell {
                weighted_sum: 1200.0,
                weight: 60.0,
                miles,
            })
        };
        assert_eq!(efficiency_economy(30.0, false, cell(24.9), None), 30.0);
        assert_eq!(efficiency_economy(30.0, false, cell(60.0), None), 20.0);
        assert_eq!(efficiency_economy(10.0, false, cell(60.0), None), 16.0);
        assert!(!efficiency_accepts(5.0, 0.0));
        assert!(!efficiency_accepts(0.5, 1.0));
    }

    #[test]
    fn buffer_samples_outside_one_to_180_seconds_are_discarded() {
        assert_eq!(buffer_updated(None, 20.0), Some(20.0));
        assert_eq!(buffer_updated(Some(20.0), 600.0), Some(20.0));
        assert_eq!(buffer_updated(Some(20.0), f64::NAN), Some(20.0));
        assert_eq!(
            buffer_updated(Some(20.0), 30.0),
            Some(20.0 * 0.65 + 30.0 * 0.35)
        );
        assert_eq!(buffer_wait_seconds(30.0, Some(9.0), 2), 30.0);
        assert_eq!(buffer_wait_seconds(30.0, Some(9.0), 3), 9.0);
    }

    #[test]
    fn refuel_accuracy_is_zero_for_nan_not_nan() {
        assert_eq!(refuel_accuracy(&[]), 0.0);
        assert_eq!(refuel_accuracy(&[0.05; 5]), 0.95);
        let nan = refuel_error(f64::NAN, 0.5);
        assert!(nan.is_nan());
        assert_eq!(refuel_accuracy(&[nan]).to_bits(), 0.0f64.to_bits());
        assert!(refuel_should_prompt(true, refuel_accuracy(&[nan])));
        assert!(!refuel_should_prompt(false, 0.0));
        assert!(gauge_went_stale(Some(0.0), STALE_GAUGE_GAP_SECONDS));
        assert!(!gauge_went_stale(None, 1e12));
    }

    #[test]
    fn eta_correction_needs_five_plausible_trips_and_is_clamped() {
        let mut s = EtaState {
            log_ratio: 0.0,
            samples: 0,
        };
        for _ in 0..8 {
            s = eta_record(s, 3600.0, 4320.0, 0.0).expect("plausible");
        }
        let m = eta_multiplier(s.log_ratio, s.samples);
        assert!(m > 1.1 && m < 1.3);
        assert_eq!(eta_record(s, 3600.0, 36_000.0, 0.0), None);
        assert_eq!(eta_record(s, 3600.0, 7200.0, f64::NAN), None);
        assert_eq!(eta_multiplier(5.0, 100), ETA_CLAMP_HIGH);
        assert_eq!(eta_multiplier(f64::NAN, 100), 1.0);
        let full = EtaState {
            log_ratio: 0.0,
            samples: i64::MAX,
        };
        assert_eq!(eta_record(full, 3600.0, 3600.0, 0.0), None);
    }

    #[test]
    fn context_beats_raw_frequency_and_unscored_places_are_dropped() {
        let now = 1.7e9;
        let ev = [
            Evidence {
                context_hits: 0,
                time_hits: 1,
                total_hits: 44,
                last_used: now - 86_400.0,
            },
            Evidence {
                context_hits: 9,
                time_hits: 12,
                total_hits: 30,
                last_used: now - 86_400.0,
            },
            Evidence {
                context_hits: 0,
                time_hits: 0,
                total_hits: 0,
                last_used: now,
            },
        ];
        let ranked = destination_rank(&ev, now, 4);
        assert_eq!(ranked.len(), 2);
        assert_eq!(ranked[0].index, 1);
        assert_eq!(ranked[0].score, 1.0);
        assert_eq!(ranked[0].reason, DestinationReason::UsuallyNow);
        // Where Swift trapped: a negative limit once something scores.
        assert!(destination_rank(&ev, now, -1).is_empty());
        assert!(destination_is_confident(Some(1.0), 3));
        assert!(!destination_is_confident(Some(1.0), 2));
        assert!(!destination_is_confident(None, 99));
    }
}
