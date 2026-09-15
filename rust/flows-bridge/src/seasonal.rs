// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::seasonal`: the seasonal risk model's
//! accumulators, gates, keys, evictions and home, the route features, the
//! learned head and its fine-tune, and the model's policy. Implementations
//! live in `flows-core`; this file only crosses.
//!
//! Boundary encodings, chosen so nothing Swift sends can be misread:
//! - a week stat is [`ffi::FlowsSeasonalWeekStat`]; lists of stats cross flat,
//!   five numbers a stat (`count` as a number: it is a small integer);
//! - an optional argument is a value plus a `has_` flag, never NaN; an
//!   optional number comes back as [`ffi::FlowsSeasonalOptional`];
//! - a learned head crosses flat: `[hidden, b2, b1…, w2…, row widths…, w1 rows…]`
//!   (rows may be ragged); the predict buffer carries the input first,
//!   `[n, x…, head…]`, so a head with no hidden units and an empty input still
//!   cross as one non-empty buffer; a tuned head comes back the same way with
//!   the sample count in front, or empty for "no tune";
//! - training rows cross as sixteen numbers a row, each of the eight columns
//!   as a value and a presence flag, because a present NaN and an absent
//!   column mean different things to the Swift they replace;
//! - home entries cross as seven numbers each (cell present, lat, lon,
//!   weighted, last seen, first seen, trips); routes for the legacy home as
//!   three (lat, lon, trips); origin stats for eviction as two (weighted,
//!   last seen); hubs as (lat, lon) pairs; cells for the prior as fifteen
//!   numbers plus three presence flags;
//! - positions come back as `f64` lists (small integers), a code as `u8`.
//!
//! Every function is a pure transform, safe from any thread. Slices are never
//! empty when they cross: each Swift facade answers the empty case itself.

use crate::contain;
use ffi::{
    FlowsSeasonalCell, FlowsSeasonalHome, FlowsSeasonalOptional, FlowsSeasonalOriginStat,
    FlowsSeasonalPrior, FlowsSeasonalWeekStat,
};
use flows_core::seasonal as sea;
use flows_core::seasonal::{
    Head, HeadMeta, OriginEntry, OriginStat, RowInput, TrainingCell, WeekStat,
};

#[swift_bridge::bridge]
mod ffi {
    // (swift-bridge 0.1.59 rejects doc attributes on shared structs, so these
    // are plain comments.)
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsSeasonalOptional {
        is_some: f64,
        value: f64,
    }
    // Decaying-weighted accumulators for one (route or edge, week) cell.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsSeasonalWeekStat {
        w_sum: f64,
        w_observed: f64,
        w_sq_err: f64,
        last_t: f64,
        count: i64,
    }
    // The seasonal prior; `has` 0 before the frequency gate or with no weight.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsSeasonalPrior {
        has: f64,
        risk: f64,
        confidence: f64,
    }
    // An origin cell's history.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsSeasonalOriginStat {
        weighted: f64,
        last_seen: f64,
        first_seen: f64,
        trips: i64,
    }
    // A parsed cell key; `has` 0 when the key does not parse.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsSeasonalCell {
        has: f64,
        lat: i64,
        lon: i64,
    }
    // A home anchor; `has` 0 for none.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsSeasonalHome {
        has: f64,
        lat: f64,
        lon: f64,
        trips: i64,
    }

    extern "Rust" {
        fn flows_seasonal_cross_country_km() -> f64;
        fn flows_seasonal_local_trip_threshold() -> i64;
        fn flows_seasonal_cross_country_trip_threshold() -> i64;
        fn flows_seasonal_min_week_samples_for_confidence() -> f64;
        fn flows_seasonal_decay_half_life_weeks() -> f64;
        fn flows_seasonal_home_min_trips() -> i64;
        fn flows_seasonal_max_edges() -> i64;
        fn flows_seasonal_max_origins() -> i64;
        fn flows_seasonal_origin_half_life_days() -> f64;
        fn flows_seasonal_relocation_margin() -> f64;
        fn flows_seasonal_relocation_min_days() -> f64;
        fn flows_seasonal_route_feature_count() -> i64;
        fn flows_seasonal_tune_epochs() -> i64;
        fn flows_seasonal_tune_learning_rate() -> f64;
        fn flows_seasonal_tune_anchor() -> f64;
        fn flows_seasonal_tune_min_trips() -> i64;
        fn flows_seasonal_tune_min_interval_seconds() -> f64;
        fn flows_seasonal_tune_min_new_trips() -> i64;

        fn flows_seasonal_week_stat_decayed(
            stat: FlowsSeasonalWeekStat,
            t: f64,
            half_life_weeks: f64,
        ) -> FlowsSeasonalWeekStat;
        fn flows_seasonal_week_stat_added(
            stat: FlowsSeasonalWeekStat,
            observed: f64,
            predicted: f64,
            t: f64,
            half_life_weeks: f64,
        ) -> FlowsSeasonalWeekStat;
        fn flows_seasonal_mean_observed(w_sum: f64, w_observed: f64) -> f64;
        fn flows_seasonal_is_modeled(trip_count: i64, cross_country: bool) -> bool;
        fn flows_seasonal_is_cross_country(distance_km: f64) -> bool;
        fn flows_seasonal_next_count(count: i64) -> i64;
        fn flows_seasonal_prior_week_keys(week: i64) -> Vec<f64>;
        fn flows_seasonal_prior(
            trip_count: i64,
            cross_country: bool,
            week: i64,
            cells: &[f64],
            present: &[f64],
            now: f64,
        ) -> FlowsSeasonalPrior;
        fn flows_seasonal_accuracy(
            trip_count: i64,
            stats: &[f64],
            now: f64,
        ) -> FlowsSeasonalOptional;
        fn flows_seasonal_mean_in_order(values: &[f64]) -> FlowsSeasonalOptional;
        fn flows_seasonal_training_rows(cells: &[f64], now: f64) -> Vec<f64>;

        fn flows_seasonal_route_cell(degrees: f64) -> FlowsSeasonalOptional;
        fn flows_seasonal_route_cell_degrees(cell: i64) -> f64;
        fn flows_seasonal_path_edge_keys(hubs: &[f64]) -> Vec<String>;
        fn flows_seasonal_origin_key(lat: i64, lon: i64) -> String;
        fn flows_seasonal_parse_origin_key(key: &str) -> FlowsSeasonalCell;

        fn flows_seasonal_origin_decayed(weighted: f64, last_seen: f64, now: f64) -> f64;
        fn flows_seasonal_origin_after_trip(
            prior: FlowsSeasonalOriginStat,
            t: f64,
        ) -> FlowsSeasonalOriginStat;
        fn flows_seasonal_origins_over_cap(count: i64) -> bool;
        fn flows_seasonal_origin_evictions(stats: &[f64], now: f64) -> Vec<f64>;
        fn flows_seasonal_edge_freshness(last_ts: &[f64]) -> f64;
        fn flows_seasonal_edges_over_cap(count: i64) -> bool;
        fn flows_seasonal_edge_evictions(freshness: &[f64]) -> Vec<f64>;
        fn flows_seasonal_learned_home(
            entries: &[f64],
            now: f64,
            current_lat: i64,
            current_lon: i64,
            has_current: bool,
        ) -> FlowsSeasonalHome;
        fn flows_seasonal_legacy_home(routes: &[f64]) -> FlowsSeasonalHome;

        fn flows_seasonal_route_features(
            o_lat: f64,
            o_lon: f64,
            d_lat: f64,
            d_lon: f64,
            week: i64,
            cross_country: bool,
        ) -> Vec<f64>;
        fn flows_seasonal_head_predict(buffer: &[f64]) -> f64;
        fn flows_seasonal_fine_tune(
            head: &[f64],
            rows: &[f64],
            epochs: i64,
            learning_rate: f64,
            anchor: f64,
        ) -> Vec<f64>;
        fn flows_seasonal_mean_squared_error(head: &[f64], rows: &[f64]) -> FlowsSeasonalOptional;
        fn flows_seasonal_tuned_rows(base_rows: i64, has_base_rows: bool, samples: i64) -> i64;
        fn flows_seasonal_choose_head(
            has_local: bool,
            local_rows: i64,
            has_local_rows: bool,
            local_tuned: bool,
            has_local_tuned: bool,
            has_bundled: bool,
            bundled_rows: i64,
            has_bundled_rows: bool,
        ) -> u8;
        fn flows_seasonal_tune_due(
            total_trips: i64,
            seconds_since_last_tune: f64,
            has_last_tune: bool,
            tuned_at_trip_count: i64,
        ) -> bool;
        fn flows_seasonal_accept_tune(tuned_mse: f64, base_mse: f64) -> bool;
        fn flows_seasonal_blend_prior(modeled: f64, observed_risk: f64, confidence: f64) -> f64;
        fn flows_seasonal_week_of_year(ordinal_day: i64, has_ordinal_day: bool) -> i64;
    }
}

const NONE: FlowsSeasonalOptional = FlowsSeasonalOptional {
    is_some: 0.0,
    value: f64::NAN,
};
const NO_HOME: FlowsSeasonalHome = FlowsSeasonalHome {
    has: 0.0,
    lat: f64::NAN,
    lon: f64::NAN,
    trips: 0,
};
fn optional(v: Option<f64>) -> FlowsSeasonalOptional {
    match v {
        Some(value) => FlowsSeasonalOptional {
            is_some: 1.0,
            value,
        },
        None => NONE,
    }
}
fn stat_in(s: &FlowsSeasonalWeekStat) -> WeekStat {
    WeekStat {
        w_sum: s.w_sum,
        w_observed: s.w_observed,
        w_sq_err: s.w_sq_err,
        last_t: s.last_t,
        count: s.count,
    }
}
fn stat_out(s: WeekStat) -> FlowsSeasonalWeekStat {
    FlowsSeasonalWeekStat {
        w_sum: s.w_sum,
        w_observed: s.w_observed,
        w_sq_err: s.w_sq_err,
        last_t: s.last_t,
        count: s.count,
    }
}
/// Five numbers to a stat; `None` for a slice that is not a whole number of stats.
fn stats_in(flat: &[f64]) -> Option<Vec<WeekStat>> {
    if !flat.len().is_multiple_of(5) {
        return None;
    }
    Some(
        flat.chunks_exact(5)
            .map(|c| WeekStat {
                w_sum: c[0],
                w_observed: c[1],
                w_sq_err: c[2],
                last_t: c[3],
                count: c[4] as i64,
            })
            .collect(),
    )
}
fn home_out(h: Option<sea::Home>) -> FlowsSeasonalHome {
    match h {
        Some(h) => FlowsSeasonalHome {
            has: 1.0,
            lat: h.lat,
            lon: h.lon,
            trips: h.trips,
        },
        None => NO_HOME,
    }
}
fn positions(v: Vec<usize>) -> Vec<f64> {
    v.into_iter().map(|i| i as f64).collect()
}

// ---- the flat head codec ----

/// `[hidden, b2, b1…, w2…, widths…, w1 rows…]` to a head; `None` for a buffer
/// that does not describe one.
fn decode_head(flat: &[f64]) -> Option<Head> {
    let hidden = usize::try_from(*flat.first()? as i64).ok()?;
    if flat.first()?.fract() != 0.0 {
        return None;
    }
    let b2 = *flat.get(1)?;
    let mut at = 2usize;
    let take = |at: &mut usize, n: usize| -> Option<Vec<f64>> {
        let end = at.checked_add(n)?;
        let v = flat.get(*at..end)?.to_vec();
        *at = end;
        Some(v)
    };
    let b1 = take(&mut at, hidden)?;
    let w2 = take(&mut at, hidden)?;
    let widths = take(&mut at, hidden)?;
    let mut w1 = Vec::with_capacity(hidden);
    for w in widths {
        if w.fract() != 0.0 || w < 0.0 {
            return None;
        }
        w1.push(take(&mut at, w as usize)?);
    }
    if at != flat.len() {
        return None;
    }
    Some(Head { w1, b1, w2, b2 })
}
fn encode_head(h: &Head) -> Vec<f64> {
    let mut out = vec![h.w1.len() as f64, h.b2];
    out.extend_from_slice(&h.b1);
    out.extend_from_slice(&h.w2);
    out.extend(h.w1.iter().map(|r| r.len() as f64));
    for r in &h.w1 {
        out.extend_from_slice(r);
    }
    out
}
/// Sixteen numbers a row: each column as a value and a presence flag.
fn decode_rows(flat: &[f64]) -> Option<Vec<RowInput>> {
    if !flat.len().is_multiple_of(16) {
        return None;
    }
    let col = |c: &[f64], i: usize| (c[2 * i + 1] != 0.0).then_some(c[2 * i]);
    Some(
        flat.chunks_exact(16)
            .map(|c| RowInput {
                o_lat: col(c, 0),
                o_lon: col(c, 1),
                d_lat: col(c, 2),
                d_lon: col(c, 3),
                week: col(c, 4),
                target: col(c, 5),
                weight: col(c, 6),
                cross_country: col(c, 7),
            })
            .collect(),
    )
}

// ---- constants ----

pub fn flows_seasonal_cross_country_km() -> f64 {
    sea::CROSS_COUNTRY_KM
}
pub fn flows_seasonal_local_trip_threshold() -> i64 {
    sea::LOCAL_TRIP_THRESHOLD
}
pub fn flows_seasonal_cross_country_trip_threshold() -> i64 {
    sea::CROSS_COUNTRY_TRIP_THRESHOLD
}
pub fn flows_seasonal_min_week_samples_for_confidence() -> f64 {
    sea::MIN_WEEK_SAMPLES_FOR_CONFIDENCE
}
pub fn flows_seasonal_decay_half_life_weeks() -> f64 {
    sea::DECAY_HALF_LIFE_WEEKS
}
pub fn flows_seasonal_home_min_trips() -> i64 {
    sea::HOME_MIN_TRIPS
}
pub fn flows_seasonal_max_edges() -> i64 {
    sea::MAX_EDGES as i64
}
pub fn flows_seasonal_max_origins() -> i64 {
    sea::MAX_ORIGINS as i64
}
pub fn flows_seasonal_origin_half_life_days() -> f64 {
    sea::ORIGIN_HALF_LIFE_DAYS
}
pub fn flows_seasonal_relocation_margin() -> f64 {
    sea::RELOCATION_MARGIN
}
pub fn flows_seasonal_relocation_min_days() -> f64 {
    sea::RELOCATION_MIN_DAYS
}
pub fn flows_seasonal_route_feature_count() -> i64 {
    sea::ROUTE_FEATURE_COUNT as i64
}
pub fn flows_seasonal_tune_epochs() -> i64 {
    sea::TUNE_EPOCHS
}
pub fn flows_seasonal_tune_learning_rate() -> f64 {
    sea::TUNE_LEARNING_RATE
}
pub fn flows_seasonal_tune_anchor() -> f64 {
    sea::TUNE_ANCHOR
}
pub fn flows_seasonal_tune_min_trips() -> i64 {
    sea::TUNE_MIN_TRIPS
}
pub fn flows_seasonal_tune_min_interval_seconds() -> f64 {
    sea::TUNE_MIN_INTERVAL_SECONDS
}
pub fn flows_seasonal_tune_min_new_trips() -> i64 {
    sea::TUNE_MIN_NEW_TRIPS
}

// ---- accumulators and the prior ----

pub fn flows_seasonal_week_stat_decayed(
    stat: FlowsSeasonalWeekStat,
    t: f64,
    half_life_weeks: f64,
) -> FlowsSeasonalWeekStat {
    let unchanged = stat_in(&stat);
    contain(stat_out(unchanged), || {
        stat_out(unchanged.decayed(t, half_life_weeks))
    })
}
pub fn flows_seasonal_week_stat_added(
    stat: FlowsSeasonalWeekStat,
    observed: f64,
    predicted: f64,
    t: f64,
    half_life_weeks: f64,
) -> FlowsSeasonalWeekStat {
    let unchanged = stat_in(&stat);
    contain(stat_out(unchanged), || {
        stat_out(unchanged.added(observed, predicted, t, half_life_weeks))
    })
}
pub fn flows_seasonal_mean_observed(w_sum: f64, w_observed: f64) -> f64 {
    contain(0.0, || sea::mean_observed(w_sum, w_observed))
}
pub fn flows_seasonal_is_modeled(trip_count: i64, cross_country: bool) -> bool {
    contain(false, || sea::is_modeled(trip_count, cross_country))
}
pub fn flows_seasonal_is_cross_country(distance_km: f64) -> bool {
    contain(false, || sea::is_cross_country(distance_km))
}
pub fn flows_seasonal_next_count(count: i64) -> i64 {
    contain(count, || sea::next_count(count))
}
/// The three week keys the prior reads, in the prior's order; empty where the
/// Swift trapped on the week arithmetic.
pub fn flows_seasonal_prior_week_keys(week: i64) -> Vec<f64> {
    contain(Vec::new(), || {
        sea::prior_week_keys(week).map_or(Vec::new(), |k| k.iter().map(|w| *w as f64).collect())
    })
}
/// `cells` are the stats at [`flows_seasonal_prior_week_keys`], fifteen numbers,
/// and `present` three flags (1 where the store holds that week).
pub fn flows_seasonal_prior(
    trip_count: i64,
    cross_country: bool,
    week: i64,
    cells: &[f64],
    present: &[f64],
    now: f64,
) -> FlowsSeasonalPrior {
    let none = || FlowsSeasonalPrior {
        has: 0.0,
        risk: f64::NAN,
        confidence: f64::NAN,
    };
    contain(none(), || {
        let Some(stats) = stats_in(cells) else {
            return none();
        };
        if stats.len() != 3 || present.len() != 3 {
            return none();
        }
        let mut slots: [Option<WeekStat>; 3] = [None, None, None];
        for (i, slot) in slots.iter_mut().enumerate() {
            *slot = (present[i] != 0.0).then_some(stats[i]);
        }
        match sea::seasonal_prior(trip_count, cross_country, week, slots, now) {
            Some((risk, confidence)) => FlowsSeasonalPrior {
                has: 1.0,
                risk,
                confidence,
            },
            None => none(),
        }
    })
}
pub fn flows_seasonal_accuracy(trip_count: i64, stats: &[f64], now: f64) -> FlowsSeasonalOptional {
    contain(NONE, || {
        stats_in(stats).map_or(NONE, |s| optional(sea::accuracy(trip_count, &s, now)))
    })
}
pub fn flows_seasonal_mean_in_order(values: &[f64]) -> FlowsSeasonalOptional {
    contain(NONE, || optional(sea::mean_in_order(values)))
}
/// Cells cross eleven numbers each: oLat, oLon, dLat, dLon cells, week, cross
/// (1 or 0), then the five stat numbers. Rows come back eight numbers each.
pub fn flows_seasonal_training_rows(cells: &[f64], now: f64) -> Vec<f64> {
    contain(Vec::new(), || {
        if !cells.len().is_multiple_of(11) {
            return Vec::new();
        }
        let parsed: Vec<TrainingCell> = cells
            .chunks_exact(11)
            .map(|c| TrainingCell {
                o_lat: c[0] as i64,
                o_lon: c[1] as i64,
                d_lat: c[2] as i64,
                d_lon: c[3] as i64,
                week: c[4] as i64,
                cross_country: c[5] != 0.0,
                stat: WeekStat {
                    w_sum: c[6],
                    w_observed: c[7],
                    w_sq_err: c[8],
                    last_t: c[9],
                    count: c[10] as i64,
                },
            })
            .collect();
        sea::training_rows(&parsed, now)
            .iter()
            .flatten()
            .copied()
            .collect()
    })
}

// ---- keys ----

/// Absent where the Swift trapped (NaN, infinite or out-of-range degrees).
pub fn flows_seasonal_route_cell(degrees: f64) -> FlowsSeasonalOptional {
    contain(NONE, || {
        optional(sea::route_cell(degrees).map(|c| c as f64))
    })
}
pub fn flows_seasonal_route_cell_degrees(cell: i64) -> f64 {
    contain(f64::NAN, || sea::route_cell_degrees(cell))
}
/// Edge keys along a hub path given as (lat, lon) pairs; empty where a
/// coordinate trapped the Swift (the facade guards the short path itself).
pub fn flows_seasonal_path_edge_keys(hubs: &[f64]) -> Vec<String> {
    contain(Vec::new(), || {
        if !hubs.len().is_multiple_of(2) {
            return Vec::new();
        }
        let pairs: Vec<(f64, f64)> = hubs.chunks_exact(2).map(|c| (c[0], c[1])).collect();
        sea::path_edge_keys(&pairs).unwrap_or_default()
    })
}
pub fn flows_seasonal_origin_key(lat: i64, lon: i64) -> String {
    contain(String::new(), || sea::origin_key(lat, lon))
}
pub fn flows_seasonal_parse_origin_key(key: &str) -> FlowsSeasonalCell {
    let none = || FlowsSeasonalCell {
        has: 0.0,
        lat: 0,
        lon: 0,
    };
    contain(none(), || match sea::parse_origin_key(key) {
        Some((lat, lon)) => FlowsSeasonalCell { has: 1.0, lat, lon },
        None => none(),
    })
}

// ---- origins, edges, home ----

pub fn flows_seasonal_origin_decayed(weighted: f64, last_seen: f64, now: f64) -> f64 {
    contain(f64::NAN, || sea::origin_decayed(weighted, last_seen, now))
}
pub fn flows_seasonal_origin_after_trip(
    prior: FlowsSeasonalOriginStat,
    t: f64,
) -> FlowsSeasonalOriginStat {
    let before = OriginStat {
        weighted: prior.weighted,
        last_seen: prior.last_seen,
        first_seen: prior.first_seen,
        trips: prior.trips,
    };
    let out = |s: OriginStat| FlowsSeasonalOriginStat {
        weighted: s.weighted,
        last_seen: s.last_seen,
        first_seen: s.first_seen,
        trips: s.trips,
    };
    contain(out(before), || out(sea::origin_after_trip(before, t)))
}
pub fn flows_seasonal_origins_over_cap(count: i64) -> bool {
    contain(false, || {
        usize::try_from(count).is_ok_and(sea::origins_over_cap)
    })
}
/// Origin stats cross as (weighted, last seen) pairs, in the order the store
/// iterates; positions to evict come back, least first.
pub fn flows_seasonal_origin_evictions(stats: &[f64], now: f64) -> Vec<f64> {
    contain(Vec::new(), || {
        if !stats.len().is_multiple_of(2) {
            return Vec::new();
        }
        let pairs: Vec<(f64, f64)> = stats.chunks_exact(2).map(|c| (c[0], c[1])).collect();
        positions(sea::origin_evictions(&pairs, now))
    })
}
pub fn flows_seasonal_edge_freshness(last_ts: &[f64]) -> f64 {
    contain(0.0, || sea::edge_freshness(last_ts))
}
pub fn flows_seasonal_edges_over_cap(count: i64) -> bool {
    contain(false, || {
        usize::try_from(count).is_ok_and(sea::edges_over_cap)
    })
}
pub fn flows_seasonal_edge_evictions(freshness: &[f64]) -> Vec<f64> {
    contain(Vec::new(), || positions(sea::edge_evictions(freshness)))
}
/// Entries cross seven numbers each: cell present (1 or 0), lat, lon,
/// weighted, last seen, first seen, trips — in the order the store iterates.
pub fn flows_seasonal_learned_home(
    entries: &[f64],
    now: f64,
    current_lat: i64,
    current_lon: i64,
    has_current: bool,
) -> FlowsSeasonalHome {
    contain(NO_HOME, || {
        if !entries.len().is_multiple_of(7) {
            return NO_HOME;
        }
        let parsed: Vec<OriginEntry> = entries
            .chunks_exact(7)
            .map(|c| OriginEntry {
                cell: (c[0] != 0.0).then_some((c[1] as i64, c[2] as i64)),
                stat: OriginStat {
                    weighted: c[3],
                    last_seen: c[4],
                    first_seen: c[5],
                    trips: c[6] as i64,
                },
            })
            .collect();
        home_out(sea::learned_home(
            &parsed,
            now,
            has_current.then_some((current_lat, current_lon)),
        ))
    })
}
/// Routes cross three numbers each: origin lat cell, lon cell, trip count.
pub fn flows_seasonal_legacy_home(routes: &[f64]) -> FlowsSeasonalHome {
    contain(NO_HOME, || {
        if !routes.len().is_multiple_of(3) {
            return NO_HOME;
        }
        let parsed: Vec<(i64, i64, i64)> = routes
            .chunks_exact(3)
            .map(|c| (c[0] as i64, c[1] as i64, c[2] as i64))
            .collect();
        home_out(sea::legacy_home(&parsed))
    })
}

// ---- features, the head, the tune ----

pub fn flows_seasonal_route_features(
    o_lat: f64,
    o_lon: f64,
    d_lat: f64,
    d_lon: f64,
    week: i64,
    cross_country: bool,
) -> Vec<f64> {
    contain(Vec::new(), || {
        sea::route_features(o_lat, o_lon, d_lat, d_lon, week, cross_country).to_vec()
    })
}
/// `buffer` is `[n, x…, head…]`; NaN for a buffer that is not a head.
pub fn flows_seasonal_head_predict(buffer: &[f64]) -> f64 {
    contain(f64::NAN, || {
        let n = usize::try_from(*buffer.first().unwrap_or(&f64::NAN) as i64).unwrap_or(usize::MAX);
        let Some(x) = buffer.get(1..1usize.saturating_add(n)) else {
            return f64::NAN;
        };
        let Some(head) = buffer.get(1usize.saturating_add(n)..).and_then(decode_head) else {
            return f64::NAN;
        };
        sea::head_predict(&head, x)
    })
}
/// The tuned head, flat with the sample count in front; empty for "no tune".
pub fn flows_seasonal_fine_tune(
    head: &[f64],
    rows: &[f64],
    epochs: i64,
    learning_rate: f64,
    anchor: f64,
) -> Vec<f64> {
    contain(Vec::new(), || {
        let (Some(base), Some(rows)) = (decode_head(head), decode_rows(rows)) else {
            return Vec::new();
        };
        match sea::fine_tune(&base, &rows, epochs, learning_rate, anchor) {
            Some(t) => {
                let mut out = vec![t.samples as f64];
                out.extend(encode_head(&t.head));
                out
            }
            None => Vec::new(),
        }
    })
}
pub fn flows_seasonal_mean_squared_error(head: &[f64], rows: &[f64]) -> FlowsSeasonalOptional {
    contain(NONE, || {
        let (Some(h), Some(r)) = (decode_head(head), decode_rows(rows)) else {
            return NONE;
        };
        optional(sea::mean_squared_error(&h, &r))
    })
}
pub fn flows_seasonal_tuned_rows(base_rows: i64, has_base_rows: bool, samples: i64) -> i64 {
    contain(samples, || {
        sea::tuned_rows(has_base_rows.then_some(base_rows), samples)
    })
}
/// 0 none, 1 the on-device head, 2 the bundled baseline.
#[allow(clippy::too_many_arguments)]
pub fn flows_seasonal_choose_head(
    has_local: bool,
    local_rows: i64,
    has_local_rows: bool,
    local_tuned: bool,
    has_local_tuned: bool,
    has_bundled: bool,
    bundled_rows: i64,
    has_bundled_rows: bool,
) -> u8 {
    contain(0, || {
        let local = has_local.then_some(HeadMeta {
            rows: has_local_rows.then_some(local_rows),
            tuned_on_device: has_local_tuned.then_some(local_tuned),
        });
        let bundled = has_bundled.then_some(HeadMeta {
            rows: has_bundled_rows.then_some(bundled_rows),
            tuned_on_device: None,
        });
        match sea::choose_head(local, bundled) {
            sea::HeadChoice::None => 0,
            sea::HeadChoice::Local => 1,
            sea::HeadChoice::Bundled => 2,
        }
    })
}
pub fn flows_seasonal_tune_due(
    total_trips: i64,
    seconds_since_last_tune: f64,
    has_last_tune: bool,
    tuned_at_trip_count: i64,
) -> bool {
    contain(false, || {
        sea::tune_due(
            total_trips,
            has_last_tune.then_some(seconds_since_last_tune),
            tuned_at_trip_count,
        )
    })
}
pub fn flows_seasonal_accept_tune(tuned_mse: f64, base_mse: f64) -> bool {
    contain(false, || sea::accept_tune(tuned_mse, base_mse))
}
pub fn flows_seasonal_blend_prior(modeled: f64, observed_risk: f64, confidence: f64) -> f64 {
    contain(f64::NAN, || {
        sea::blend_prior(modeled, observed_risk, confidence)
    })
}
pub fn flows_seasonal_week_of_year(ordinal_day: i64, has_ordinal_day: bool) -> i64 {
    contain(0, || {
        sea::week_of_year(has_ordinal_day.then_some(ordinal_day))
    })
}
