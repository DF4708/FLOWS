// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::long_trips`: the fuel warning, the
//! long-trip share and the saved road corridors. Functions are named
//! `flows_long_trips_…`.
//!
//! Boundary encodings, chosen so nothing Swift sends can be misread:
//! - stations cross as parallel columns (miles ahead, price, priced flag)
//!   with a count;
//! - a list of date lists crosses as one flat column of seconds since the
//!   reference date plus each list's length;
//! - phones cross as one joined string plus each phone's UTF-8 length;
//! - corridors cross as flat latitude and longitude columns plus each
//!   corridor's point count; destinations as value columns plus a has-flag
//!   column; an optional point as a value pair plus a `has_` flag;
//! - an index answer is `-1` for none; the fuel level is `0` for none, `-1`
//!   for unreachable and `n > 0` for last chances with `n` stations left;
//! - a share plan is `[matched index or -1, renames, dropped dates, order
//!   length or -1, order…]`, and empty when nothing is recorded;
//! - a list of constants comes back in the order its function documents.
//!
//! Every column travels with its count, so the facades send a one-element
//! placeholder for an empty list: swift-bridge must never see an empty
//! buffer. Every function is a thin forwarder through [`contain`], so a panic
//! inside the core becomes the documented fallback instead of crossing into
//! Swift.

#![allow(clippy::too_many_arguments)] // flattened Swift signatures

use crate::{contain, split_texts};
use ffi::FlowsLongTripsDay;
use flows_core::long_trips as lt;

#[swift_bridge::bridge]
mod ffi {
    // The day odometer after a drive: the day's start and its meters.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsLongTripsDay {
        day: f64,
        meters: f64,
    }

    extern "Rust" {
        // ---- fuel ----
        fn flows_long_trips_fuel_severity(fraction: f64) -> f64;
        fn flows_long_trips_fuel_band(fraction: f64) -> u8;
        fn flows_long_trips_warn_at_reachable_count() -> i64;
        fn flows_long_trips_reachable_stations(
            miles: &[f64],
            prices: &[f64],
            priced: &[u8],
            count: i64,
            range_miles: f64,
            reserve_miles: f64,
        ) -> Vec<i64>;
        fn flows_long_trips_fuel_level(
            miles: &[f64],
            prices: &[f64],
            priced: &[u8],
            count: i64,
            range_miles: f64,
            reserve_miles: f64,
        ) -> i64;
        fn flows_long_trips_cheapest_station(
            miles: &[f64],
            prices: &[f64],
            priced: &[u8],
            count: i64,
            range_miles: f64,
            reserve_miles: f64,
        ) -> i64;

        // ---- the long-trip share ----
        fn flows_long_trips_should_offer_share(route_meters: f64, driven_today_meters: f64)
            -> bool;
        fn flows_long_trips_share_constants() -> Vec<f64>;
        fn flows_long_trips_share_caps() -> Vec<i64>;
        fn flows_long_trips_daily_drive_add(
            day: f64,
            meters: f64,
            today: f64,
            delta: f64,
        ) -> FlowsLongTripsDay;
        fn flows_long_trips_ranked_recipients(
            dates: &[f64],
            date_counts: &[i64],
            recipient_count: i64,
            now: f64,
        ) -> Vec<i64>;
        fn flows_long_trips_normalized_phone(phone: &str) -> String;
        fn flows_long_trips_record_share(
            phones: &str,
            phone_lengths: &[i64],
            dates: &[f64],
            date_counts: &[i64],
            recipient_count: i64,
            name: &str,
            phone: &str,
            date: f64,
        ) -> Vec<i64>;

        // ---- saved corridors ----
        fn flows_long_trips_corridor_constants() -> Vec<f64>;
        fn flows_long_trips_corridor_limits() -> Vec<i64>;
        fn flows_long_trips_keep_corridor(
            saved_at: f64,
            lats: &[f64],
            lons: &[f64],
            count: i64,
            now: f64,
            lat: f64,
            lon: f64,
            has_position: bool,
        ) -> bool;
        fn flows_long_trips_prune_corridors(
            saved_at: &[f64],
            lats: &[f64],
            lons: &[f64],
            point_counts: &[i64],
            corridor_count: i64,
            now: f64,
            lat: f64,
            lon: f64,
            has_position: bool,
        ) -> Vec<i64>;
        fn flows_long_trips_worth_saving(trip_meters: f64) -> bool;
        fn flows_long_trips_supersedes(
            newer_lat: f64,
            newer_lon: f64,
            has_newer: bool,
            older_lat: f64,
            older_lon: f64,
            has_older: bool,
        ) -> bool;
        fn flows_long_trips_decimate(
            lats: &[f64],
            lons: &[f64],
            count: i64,
            step_meters: f64,
            limit: i64,
        ) -> Vec<i64>;
        fn flows_long_trips_record_corridor(
            saved_at: &[f64],
            end_lats: &[f64],
            end_lons: &[f64],
            has_end: &[u8],
            corridor_count: i64,
            new_lat: f64,
            new_lon: f64,
            has_new: bool,
            now: f64,
        ) -> Vec<i64>;
    }
}

// ------------------------------------------------------------------ helpers

/// A count from Swift as a length no longer than `available`.
fn clamp(count: i64, available: usize) -> usize {
    usize::try_from(count).unwrap_or(0).min(available)
}

/// An index answer: `-1` for none.
fn index(i: Option<usize>) -> i64 {
    i.map_or(-1, |i| i64::try_from(i).unwrap_or(i64::MAX))
}

/// A list of indices for Swift.
fn indices(list: Vec<usize>) -> Vec<i64> {
    list.into_iter().map(|i| index(Some(i))).collect()
}

/// The first `count` stations from their columns.
fn stations(miles: &[f64], prices: &[f64], priced: &[u8], count: i64) -> Vec<lt::Station> {
    let n = clamp(count, miles.len().min(prices.len()).min(priced.len()));
    (0..n)
        .map(|i| lt::Station {
            miles_ahead: miles[i],
            price: (priced[i] != 0).then_some(prices[i]),
        })
        .collect()
}

/// Consecutive runs of `flat`, `lengths[k]` long each, for the first `count`
/// lengths; a run past the end of `flat` takes what exists.
fn runs<'a>(flat: &'a [f64], lengths: &[i64], count: i64) -> Vec<&'a [f64]> {
    let mut start = 0usize;
    lengths[..clamp(count, lengths.len())]
        .iter()
        .map(|&len| {
            let from = start.min(flat.len());
            start = start.saturating_add(usize::try_from(len).unwrap_or(0));
            &flat[from..start.min(flat.len())]
        })
        .collect()
}

/// An optional point from a value pair and its flag.
fn point(lat: f64, lon: f64, has: bool) -> Option<lt::Point> {
    has.then_some((lat, lon))
}

// ------------------------------------------------------------------ fuel

/// `lt::fuel_severity`. A panic answers NaN.
pub fn flows_long_trips_fuel_severity(fraction: f64) -> f64 {
    contain(f64::NAN, || lt::fuel_severity(fraction))
}

/// `lt::fuel_band` as its code: 0 green, 1 yellow, 2 red. A panic answers
/// green.
pub fn flows_long_trips_fuel_band(fraction: f64) -> u8 {
    contain(0, || lt::fuel_band(fraction) as u8)
}

/// `lt::WARN_AT_REACHABLE_COUNT`.
pub fn flows_long_trips_warn_at_reachable_count() -> i64 {
    index(Some(lt::WARN_AT_REACHABLE_COUNT))
}

/// `lt::reachable_stations` over the first `count` stations. A panic answers
/// no station.
pub fn flows_long_trips_reachable_stations(
    miles: &[f64],
    prices: &[f64],
    priced: &[u8],
    count: i64,
    range_miles: f64,
    reserve_miles: f64,
) -> Vec<i64> {
    contain(Vec::new(), || {
        let s = stations(miles, prices, priced, count);
        indices(lt::reachable_stations(&s, range_miles, reserve_miles))
    })
}

/// `lt::fuel_level` as `0` none, `-1` unreachable, `n` last chances. A panic
/// answers none.
pub fn flows_long_trips_fuel_level(
    miles: &[f64],
    prices: &[f64],
    priced: &[u8],
    count: i64,
    range_miles: f64,
    reserve_miles: f64,
) -> i64 {
    contain(0, || {
        let s = stations(miles, prices, priced, count);
        match lt::fuel_level(&s, range_miles, reserve_miles) {
            lt::FuelLevel::None => 0,
            lt::FuelLevel::LastChances(n) => index(Some(n)),
            lt::FuelLevel::Unreachable => -1,
        }
    })
}

/// `lt::cheapest_station`, `-1` for none. A panic answers none.
pub fn flows_long_trips_cheapest_station(
    miles: &[f64],
    prices: &[f64],
    priced: &[u8],
    count: i64,
    range_miles: f64,
    reserve_miles: f64,
) -> i64 {
    contain(-1, || {
        let s = stations(miles, prices, priced, count);
        index(lt::cheapest_station(&s, range_miles, reserve_miles))
    })
}

// ------------------------------------------------------------------ share

/// `lt::should_offer_share`. A panic answers false.
pub fn flows_long_trips_should_offer_share(route_meters: f64, driven_today_meters: f64) -> bool {
    contain(false, || {
        lt::should_offer_share(route_meters, driven_today_meters)
    })
}

/// `[LONG_TRIP_MILES, METERS_PER_MILE]`.
pub fn flows_long_trips_share_constants() -> Vec<f64> {
    vec![lt::LONG_TRIP_MILES, lt::METERS_PER_MILE]
}

/// `[MAX_RECIPIENTS, MAX_DATES_PER_RECIPIENT]`.
pub fn flows_long_trips_share_caps() -> Vec<i64> {
    indices(vec![lt::MAX_RECIPIENTS, lt::MAX_DATES_PER_RECIPIENT])
}

/// `lt::daily_drive_add`. A panic leaves the log as it was.
pub fn flows_long_trips_daily_drive_add(
    day: f64,
    meters: f64,
    today: f64,
    delta: f64,
) -> FlowsLongTripsDay {
    contain(FlowsLongTripsDay { day, meters }, || {
        let (day, meters) = lt::daily_drive_add(day, meters, today, delta);
        FlowsLongTripsDay { day, meters }
    })
}

/// `lt::ranked_recipients` over the first `recipient_count` date lists. A
/// panic answers the recipients in their stored order.
pub fn flows_long_trips_ranked_recipients(
    dates: &[f64],
    date_counts: &[i64],
    recipient_count: i64,
    now: f64,
) -> Vec<i64> {
    let stored = clamp(recipient_count, date_counts.len());
    contain(indices((0..stored).collect()), || {
        let lists = runs(dates, date_counts, recipient_count);
        indices(lt::ranked_recipients(&lists, now))
    })
}

/// `lt::normalized_phone`. A panic answers no digits.
pub fn flows_long_trips_normalized_phone(phone: &str) -> String {
    contain(String::new(), || lt::normalized_phone(phone))
}

/// `lt::record_share` as a plan (module docs); empty when nothing is
/// recorded, when the phone lengths do not split the joined phones, or on a
/// panic.
pub fn flows_long_trips_record_share(
    phones: &str,
    phone_lengths: &[i64],
    dates: &[f64],
    date_counts: &[i64],
    recipient_count: i64,
    name: &str,
    phone: &str,
    date: f64,
) -> Vec<i64> {
    contain(Vec::new(), || {
        let n = clamp(recipient_count, phone_lengths.len().min(date_counts.len()));
        let Some(phone_list) = split_texts(phones, phone_lengths, n) else {
            return Vec::new();
        };
        let lists = runs(dates, date_counts, recipient_count);
        let Some(plan) = lt::record_share(&phone_list, &lists, name, phone, date) else {
            return Vec::new();
        };
        let mut out = vec![
            index(plan.matched),
            i64::from(plan.renames),
            index(Some(plan.dropped_dates)),
        ];
        match plan.order {
            Some(order) => {
                out.push(index(Some(order.len())));
                out.extend(indices(order));
            }
            None => out.push(-1),
        }
        out
    })
}

// ------------------------------------------------------------------ corridors

/// `[MAX_AGE_SECONDS, ARRIVED_METERS, PASSED_METERS, MIN_TRIP_METERS,
/// DECIMATE_STEP_METERS]`.
pub fn flows_long_trips_corridor_constants() -> Vec<f64> {
    vec![
        lt::MAX_AGE_SECONDS,
        lt::ARRIVED_METERS,
        lt::PASSED_METERS,
        lt::MIN_TRIP_METERS,
        lt::DECIMATE_STEP_METERS,
    ]
}

/// `[MAX_STORED, DECIMATE_LIMIT]`.
pub fn flows_long_trips_corridor_limits() -> Vec<i64> {
    vec![index(Some(lt::MAX_STORED)), lt::DECIMATE_LIMIT]
}

/// `lt::keep_corridor` over the first `count` points. A panic answers true:
/// nothing that might still help is thrown away.
pub fn flows_long_trips_keep_corridor(
    saved_at: f64,
    lats: &[f64],
    lons: &[f64],
    count: i64,
    now: f64,
    lat: f64,
    lon: f64,
    has_position: bool,
) -> bool {
    contain(true, || {
        let n = clamp(count, lats.len().min(lons.len()));
        let corridor = lt::Corridor {
            saved_at,
            lats: &lats[..n],
            lons: &lons[..n],
        };
        lt::keep_corridor(corridor, now, point(lat, lon, has_position))
    })
}

/// `lt::prune_corridors` over the first `corridor_count` corridors. A panic
/// answers the corridors in their stored order.
pub fn flows_long_trips_prune_corridors(
    saved_at: &[f64],
    lats: &[f64],
    lons: &[f64],
    point_counts: &[i64],
    corridor_count: i64,
    now: f64,
    lat: f64,
    lon: f64,
    has_position: bool,
) -> Vec<i64> {
    let stored = clamp(corridor_count, saved_at.len().min(point_counts.len()));
    contain(indices((0..stored).collect()), || {
        let lat_runs = runs(lats, point_counts, corridor_count);
        let lon_runs = runs(lons, point_counts, corridor_count);
        let corridors: Vec<lt::Corridor<'_>> = (0..stored)
            .map(|c| lt::Corridor {
                saved_at: saved_at[c],
                lats: lat_runs[c],
                lons: lon_runs[c],
            })
            .collect();
        indices(lt::prune_corridors(
            &corridors,
            now,
            point(lat, lon, has_position),
        ))
    })
}

/// `lt::worth_saving`. A panic answers false.
pub fn flows_long_trips_worth_saving(trip_meters: f64) -> bool {
    contain(false, || lt::worth_saving(trip_meters))
}

/// `lt::supersedes`. A panic answers false.
pub fn flows_long_trips_supersedes(
    newer_lat: f64,
    newer_lon: f64,
    has_newer: bool,
    older_lat: f64,
    older_lon: f64,
    has_older: bool,
) -> bool {
    contain(false, || {
        lt::supersedes(
            point(newer_lat, newer_lon, has_newer),
            point(older_lat, older_lon, has_older),
        )
    })
}

/// `lt::decimate` over the first `count` points. A panic answers no points.
pub fn flows_long_trips_decimate(
    lats: &[f64],
    lons: &[f64],
    count: i64,
    step_meters: f64,
    limit: i64,
) -> Vec<i64> {
    contain(Vec::new(), || {
        let n = clamp(count, lats.len().min(lons.len()));
        indices(lt::decimate(&lats[..n], &lons[..n], step_meters, limit))
    })
}

/// `lt::record_corridor` over the first `corridor_count` stored corridors;
/// the index `corridor_count` stands for the new corridor. A panic answers
/// the new corridor alone.
pub fn flows_long_trips_record_corridor(
    saved_at: &[f64],
    end_lats: &[f64],
    end_lons: &[f64],
    has_end: &[u8],
    corridor_count: i64,
    new_lat: f64,
    new_lon: f64,
    has_new: bool,
    now: f64,
) -> Vec<i64> {
    let n = clamp(
        corridor_count,
        saved_at
            .len()
            .min(end_lats.len())
            .min(end_lons.len())
            .min(has_end.len()),
    );
    contain(indices(vec![n]), || {
        let ends: Vec<Option<lt::Point>> = (0..n)
            .map(|i| point(end_lats[i], end_lons[i], has_end[i] != 0))
            .collect();
        indices(lt::record_corridor(
            &saved_at[..n],
            &ends,
            point(new_lat, new_lon, has_new),
            now,
        ))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn placeholders_behind_a_zero_count_are_never_read() {
        assert_eq!(
            flows_long_trips_fuel_level(&[5.0], &[3.0], &[1], 0, 100.0, 40.0),
            -1
        );
        assert_eq!(
            flows_long_trips_cheapest_station(&[5.0], &[3.0], &[1], 0, 100.0, 40.0),
            -1
        );
        assert!(flows_long_trips_ranked_recipients(&[0.0], &[0], 0, 0.0).is_empty());
        assert_eq!(
            flows_long_trips_record_corridor(&[0.0], &[0.0], &[0.0], &[0], 0, 1.0, 1.0, true, 5.0),
            vec![0]
        );
        assert_eq!(
            flows_long_trips_prune_corridors(&[0.0], &[0.0], &[0.0], &[0], 0, 0.0, 0.0, 0.0, false),
            Vec::<i64>::new()
        );
    }

    #[test]
    fn a_share_plan_round_trips_through_the_encoding() {
        let phones = "+1 (555) 010-2030";
        let plan = flows_long_trips_record_share(
            phones,
            &[17],
            &[1.0, 2.0],
            &[2],
            1,
            "Dana",
            "15550102030",
            3.0,
        );
        assert_eq!(plan, vec![0, 1, 0, -1]);
        assert!(
            flows_long_trips_record_share(phones, &[17], &[1.0], &[1], 1, "", "n/a", 3.0)
                .is_empty()
        );
        // A length that cuts a character in two is refused, not misread.
        assert!(
            flows_long_trips_record_share("\u{E9}", &[1], &[1.0], &[1], 1, "", "5", 3.0).is_empty()
        );
    }

    #[test]
    fn levels_and_bands_use_their_documented_codes() {
        assert_eq!(flows_long_trips_fuel_band(1.0), 0);
        assert_eq!(flows_long_trips_fuel_band(0.25), 1);
        assert_eq!(flows_long_trips_fuel_band(0.0), 2);
        assert_eq!(
            flows_long_trips_fuel_level(&[4.0, 8.0], &[0.0, 0.0], &[0, 0], 2, 50.0, 40.0),
            2
        );
    }
}
