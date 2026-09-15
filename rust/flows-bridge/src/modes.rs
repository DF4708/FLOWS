// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::media_policy` and
//! `flows_core::travel_modes`: the link, device, playback and transmitter
//! decisions and the travel-mode rules. Functions are named `flows_modes_…`.
//!
//! Boundary encodings, chosen so nothing Swift sends can be misread:
//! - an optional argument is a value plus a `has_` flag; an optional answer
//!   is a shared struct with `has`, or `-1` for no index;
//! - an enum is its declaration-order code (link tier, fallback source,
//!   player), a device tier its raw value, a thermal state its raw value;
//! - stations and candidates cross as parallel columns, flags as bytes, names
//!   as one joined string plus each name's UTF-8 length;
//! - point lists cross as latitude and longitude columns and come back as a
//!   flat (lat, lon) list; clusters come back as `[count, lengths…,
//!   indices…]`;
//! - a list of constants comes back in the order its function documents.
//!
//! swift-bridge must never see an empty buffer, so the facades answer the
//! empty cases themselves or send a placeholder the counts ignore. Every
//! function is a thin forwarder through [`contain`], so a panic inside the
//! core becomes the documented fallback instead of crossing into Swift.

use crate::contain;
use ffi::{FlowsModesMinutes, FlowsModesNearest, FlowsModesRideOffer, FlowsModesTuning};
use flows_core::media_policy as mp;
use flows_core::travel_modes as tm;

#[swift_bridge::bridge]
mod ffi {
    // (swift-bridge 0.1.59 rejects doc attributes on shared structs, so these
    // are plain comments.)
    //
    // How hard the device may work.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsModesTuning {
        max_in_flight: i64,
        planning_max_in_flight: i64,
        viewport_grid_span: i64,
        ttl_multiplier: f64,
        debounce_seconds: f64,
    }
    // The nearest transmitter; `index` and `meters` mean something only when
    // `has` is true.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsModesNearest {
        has: bool,
        index: i64,
        meters: f64,
    }
    // Local minutes of day and the traffic-check interval; `has` is false
    // where the Swift trapped.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsModesMinutes {
        has: bool,
        minutes: i64,
        interval_seconds: f64,
    }
    // A walk-plus-ride offer; `has` is false when none is made.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsModesRideOffer {
        has: bool,
        ride_miles: f64,
        ride_seconds: f64,
        walk_seconds: f64,
        cost_usd: f64,
    }

    extern "Rust" {
        // ---- the data link ----
        fn flows_modes_signal_tier(
            radio_technology: &str,
            has_technology: bool,
            on_wifi: bool,
            offline: bool,
        ) -> u8;
        fn flows_modes_should_pre_stage(
            tier: u8,
            buffer_draining: bool,
            recent_stalls: i64,
        ) -> bool;
        fn flows_modes_is_draining(
            previous: f64,
            has_previous: bool,
            current: f64,
            has_current: bool,
        ) -> bool;

        // ---- the device ----
        fn flows_modes_device_tier(cores: i64, memory_gb: f64) -> u8;
        fn flows_modes_tuning_settings(tier: u8, thermal: i64, low_power: bool)
            -> FlowsModesTuning;

        // ---- playback ----
        fn flows_modes_on_connection_lost(
            is_playing: bool,
            needs_network: bool,
            has_local_music: bool,
            last_genre: &str,
            has_genre: bool,
        ) -> u8;
        fn flows_modes_fallback_genre(last_genre: &str, has_genre: bool) -> String;
        fn flows_modes_should_restore(
            handed_off: bool,
            connection_held: bool,
            driver_chose_since: bool,
        ) -> bool;
        fn flows_modes_restore_hold_seconds() -> f64;
        fn flows_modes_grace_seconds(source: u8, measured_buffer: f64, has_buffer: bool) -> f64;
        fn flows_modes_grace_caps() -> Vec<f64>;

        // ---- transmitters and stations ----
        fn flows_modes_nearest_station(
            lat: f64,
            lon: f64,
            lats: &[f64],
            lons: &[f64],
            exact: &[u8],
        ) -> FlowsModesNearest;
        fn flows_modes_retarget(
            playing_id: &str,
            playing_lat: f64,
            playing_lon: f64,
            has_playing_coordinate: bool,
            lat: f64,
            lon: f64,
            ids_joined: &str,
            id_lens: &[i64],
            lats: &[f64],
            lons: &[f64],
            exact: &[u8],
        ) -> i64;
        fn flows_modes_switch_margin() -> f64;
        fn flows_modes_nearest_within(
            lat: f64,
            lon: f64,
            max_meters: f64,
            lats: &[f64],
            lons: &[f64],
        ) -> i64;

        // ---- the breadcrumb trail ----
        fn flows_modes_should_record(
            lat: f64,
            lon: f64,
            last_lat: f64,
            last_lon: f64,
            has_last: bool,
        ) -> bool;
        fn flows_modes_way_back_meters(lats: &[f64], lons: &[f64]) -> f64;
        fn flows_modes_min_step_meters() -> f64;
        fn flows_modes_max_points() -> i64;

        // ---- flying ----
        fn flows_modes_worth_flying(trip_miles: f64) -> bool;
        fn flows_modes_flight_seconds(airport_miles: f64) -> f64;
        fn flows_modes_door_seconds(airport_miles: f64) -> f64;
        fn flows_modes_fare_estimate(airport_miles: f64) -> f64;
        fn flows_modes_airport_score(name: &str) -> i64;
        fn flows_modes_pick_airport(
            names_joined: &str,
            name_lens: &[i64],
            meters: &[f64],
            max_meters: f64,
        ) -> i64;
        fn flows_modes_air_constants() -> Vec<f64>;

        // ---- traffic checks, risk areas, fares ----
        fn flows_modes_is_peak(local_minutes: i64) -> bool;
        fn flows_modes_local_minutes(reference_seconds: f64, longitude: f64) -> FlowsModesMinutes;
        fn flows_modes_traffic_constants() -> Vec<f64>;
        fn flows_modes_risk_clusters(lats: &[f64], lons: &[f64], adjacency_meters: f64)
            -> Vec<i64>;
        fn flows_modes_risk_hull(
            lats: &[f64],
            lons: &[f64],
            count: i64,
            pad_meters: f64,
        ) -> Vec<f64>;
        fn flows_modes_amtrak_fare(miles: f64) -> f64;
        fn flows_modes_greyhound_fare(miles: f64) -> f64;
        fn flows_modes_local_fares() -> Vec<f64>;

        // ---- walk plus ride ----
        fn flows_modes_ride_cost(miles: f64) -> f64;
        fn flows_modes_meets_bar(
            walk_alone_seconds: f64,
            total_seconds: f64,
            cost_usd: f64,
        ) -> bool;
        fn flows_modes_evaluate_ride(
            walk_alone_seconds: f64,
            drive_seconds: f64,
            trip_miles: f64,
        ) -> FlowsModesRideOffer;
        fn flows_modes_prefix_coordinates(lats: &[f64], lons: &[f64], meters: f64) -> Vec<f64>;
        fn flows_modes_ride_constants() -> Vec<f64>;
    }
}

type Point = (f64, f64);

fn points(lats: &[f64], lons: &[f64]) -> Vec<Point> {
    lats.iter().zip(lons).map(|(&a, &b)| (a, b)).collect()
}

fn flat(points: &[Point]) -> Vec<f64> {
    points.iter().flat_map(|&(a, b)| [a, b]).collect()
}

fn index_or_none(i: Option<usize>) -> i64 {
    i.and_then(|i| i64::try_from(i).ok()).unwrap_or(-1)
}

pub fn flows_modes_signal_tier(
    radio_technology: &str,
    has_technology: bool,
    on_wifi: bool,
    offline: bool,
) -> u8 {
    contain(mp::tier::FAIR, || {
        mp::signal_tier(has_technology.then_some(radio_technology), on_wifi, offline)
    })
}

pub fn flows_modes_should_pre_stage(tier: u8, buffer_draining: bool, recent_stalls: i64) -> bool {
    mp::should_pre_stage(tier, buffer_draining, recent_stalls)
}

pub fn flows_modes_is_draining(
    previous: f64,
    has_previous: bool,
    current: f64,
    has_current: bool,
) -> bool {
    mp::is_draining(
        has_previous.then_some(previous),
        has_current.then_some(current),
    )
}

pub fn flows_modes_device_tier(cores: i64, memory_gb: f64) -> u8 {
    mp::device_tier(cores, memory_gb)
}

pub fn flows_modes_tuning_settings(tier: u8, thermal: i64, low_power: bool) -> FlowsModesTuning {
    let s = mp::tuning_settings(tier, thermal, low_power);
    FlowsModesTuning {
        max_in_flight: s.max_in_flight,
        planning_max_in_flight: s.planning_max_in_flight,
        viewport_grid_span: s.viewport_grid_span,
        ttl_multiplier: s.ttl_multiplier,
        debounce_seconds: s.debounce_seconds,
    }
}

pub fn flows_modes_on_connection_lost(
    is_playing: bool,
    needs_network: bool,
    has_local_music: bool,
    last_genre: &str,
    has_genre: bool,
) -> u8 {
    contain(mp::fallback::KEEP_PLAYING, || {
        mp::on_connection_lost(
            is_playing,
            needs_network,
            has_local_music,
            has_genre.then_some(last_genre),
        )
        .0
    })
}

/// The genre radio would tune: trimmed of whitespace and newlines.
pub fn flows_modes_fallback_genre(last_genre: &str, has_genre: bool) -> String {
    contain(String::new(), || {
        mp::on_connection_lost(true, true, false, has_genre.then_some(last_genre)).1
    })
}

pub fn flows_modes_should_restore(
    handed_off: bool,
    connection_held: bool,
    driver_chose_since: bool,
) -> bool {
    mp::should_restore(handed_off, connection_held, driver_chose_since)
}

pub fn flows_modes_restore_hold_seconds() -> f64 {
    mp::RESTORE_HOLD_SECONDS
}

pub fn flows_modes_grace_seconds(source: u8, measured_buffer: f64, has_buffer: bool) -> f64 {
    mp::grace_seconds(source, has_buffer.then_some(measured_buffer))
}

/// `[radio floor, radio cap, Apple Music cap, Spotify cap, other-app watch]`.
pub fn flows_modes_grace_caps() -> Vec<f64> {
    vec![
        mp::RADIO_FLOOR_SECONDS,
        mp::RADIO_CAP_SECONDS,
        mp::APPLE_MUSIC_CAP_SECONDS,
        mp::SPOTIFY_CAP_SECONDS,
        mp::OTHER_APP_WATCH_SECONDS,
    ]
}

pub fn flows_modes_nearest_station(
    lat: f64,
    lon: f64,
    lats: &[f64],
    lons: &[f64],
    exact: &[u8],
) -> FlowsModesNearest {
    let none = FlowsModesNearest {
        has: false,
        index: -1,
        meters: f64::NAN,
    };
    contain(none, || {
        let stations: Vec<(Point, bool)> = points(lats, lons)
            .into_iter()
            .zip(exact)
            .map(|(p, &e)| (p, e != 0))
            .collect();
        match mp::nearest_station((lat, lon), &stations) {
            Some((i, meters)) => FlowsModesNearest {
                has: true,
                index: index_or_none(Some(i)),
                meters,
            },
            None => FlowsModesNearest {
                has: false,
                index: -1,
                meters: f64::NAN,
            },
        }
    })
}

/// The station index to switch to, or -1 to stay (also when the id column
/// does not split).
#[allow(clippy::too_many_arguments)]
pub fn flows_modes_retarget(
    playing_id: &str,
    playing_lat: f64,
    playing_lon: f64,
    has_playing_coordinate: bool,
    lat: f64,
    lon: f64,
    ids_joined: &str,
    id_lens: &[i64],
    lats: &[f64],
    lons: &[f64],
    exact: &[u8],
) -> i64 {
    contain(-1, || {
        let n = lats.len().min(lons.len()).min(exact.len());
        let Some(ids) = crate::split_texts(ids_joined, id_lens, n) else {
            return -1;
        };
        let stations: Vec<(&str, Point, bool)> = (0..n)
            .map(|i| (ids[i], (lats[i], lons[i]), exact[i] != 0))
            .collect();
        index_or_none(mp::retarget(
            Some(playing_id),
            has_playing_coordinate.then_some((playing_lat, playing_lon)),
            (lat, lon),
            &stations,
        ))
    })
}

pub fn flows_modes_switch_margin() -> f64 {
    mp::SWITCH_MARGIN
}

pub fn flows_modes_nearest_within(
    lat: f64,
    lon: f64,
    max_meters: f64,
    lats: &[f64],
    lons: &[f64],
) -> i64 {
    contain(-1, || {
        index_or_none(tm::nearest_within(
            (lat, lon),
            max_meters,
            &points(lats, lons),
        ))
    })
}

pub fn flows_modes_should_record(
    lat: f64,
    lon: f64,
    last_lat: f64,
    last_lon: f64,
    has_last: bool,
) -> bool {
    tm::should_record((lat, lon), has_last.then_some((last_lat, last_lon)))
}

pub fn flows_modes_way_back_meters(lats: &[f64], lons: &[f64]) -> f64 {
    contain(f64::NAN, || tm::way_back_meters(&points(lats, lons)))
}

pub fn flows_modes_min_step_meters() -> f64 {
    tm::MIN_STEP_METERS
}

pub fn flows_modes_max_points() -> i64 {
    index_or_none(Some(tm::MAX_POINTS))
}

pub fn flows_modes_worth_flying(trip_miles: f64) -> bool {
    tm::worth_flying(trip_miles)
}

pub fn flows_modes_flight_seconds(airport_miles: f64) -> f64 {
    tm::flight_seconds(airport_miles)
}

pub fn flows_modes_door_seconds(airport_miles: f64) -> f64 {
    tm::door_seconds(airport_miles)
}

pub fn flows_modes_fare_estimate(airport_miles: f64) -> f64 {
    tm::fare_estimate(airport_miles)
}

/// The airport score, or -1 when the name rejects the field.
pub fn flows_modes_airport_score(name: &str) -> i64 {
    contain(-1, || tm::airport_score(name).unwrap_or(-1))
}

/// The picked candidate's index, or -1 (also when the names do not split).
pub fn flows_modes_pick_airport(
    names_joined: &str,
    name_lens: &[i64],
    meters: &[f64],
    max_meters: f64,
) -> i64 {
    contain(-1, || {
        let Some(names) = crate::split_texts(names_joined, name_lens, meters.len()) else {
            return -1;
        };
        let candidates: Vec<(&str, f64)> = names.into_iter().zip(meters.iter().copied()).collect();
        index_or_none(tm::pick_airport(&candidates, max_meters))
    })
}

/// `[minimum trip miles, minimum airport gap miles, board buffer seconds,
/// alight buffer seconds]`.
pub fn flows_modes_air_constants() -> Vec<f64> {
    vec![
        tm::MIN_TRIP_MILES,
        tm::MIN_AIRPORT_GAP_MILES,
        tm::BOARD_BUFFER_SECONDS,
        tm::ALIGHT_BUFFER_SECONDS,
    ]
}

pub fn flows_modes_is_peak(local_minutes: i64) -> bool {
    tm::is_peak(local_minutes)
}

pub fn flows_modes_local_minutes(reference_seconds: f64, longitude: f64) -> FlowsModesMinutes {
    match (
        tm::local_minutes(reference_seconds, longitude),
        tm::traffic_interval_seconds(reference_seconds, longitude),
    ) {
        (Some(minutes), Some(interval_seconds)) => FlowsModesMinutes {
            has: true,
            minutes,
            interval_seconds,
        },
        _ => FlowsModesMinutes {
            has: false,
            minutes: 0,
            interval_seconds: tm::OFF_PEAK_SECONDS,
        },
    }
}

/// `[peak seconds, off-peak seconds]`.
pub fn flows_modes_traffic_constants() -> Vec<f64> {
    vec![tm::PEAK_SECONDS, tm::OFF_PEAK_SECONDS]
}

/// `[count, lengths…, indices…]`.
pub fn flows_modes_risk_clusters(lats: &[f64], lons: &[f64], adjacency_meters: f64) -> Vec<i64> {
    contain(vec![0], || {
        let clusters = tm::risk_clusters(&points(lats, lons), adjacency_meters);
        let mut out = vec![index_or_none(Some(clusters.len()))];
        out.extend(clusters.iter().map(|c| index_or_none(Some(c.len()))));
        out.extend(clusters.iter().flatten().map(|&i| index_or_none(Some(i))));
        out
    })
}

/// The padded outline of the first `count` points, flat (lat, lon).
pub fn flows_modes_risk_hull(lats: &[f64], lons: &[f64], count: i64, pad_meters: f64) -> Vec<f64> {
    contain(Vec::new(), || {
        let n = usize::try_from(count).unwrap_or(0);
        let pts: Vec<Point> = points(lats, lons).into_iter().take(n).collect();
        flat(&tm::risk_hull(&pts, pad_meters))
    })
}

pub fn flows_modes_amtrak_fare(miles: f64) -> f64 {
    tm::amtrak_fare(miles)
}

pub fn flows_modes_greyhound_fare(miles: f64) -> f64 {
    tm::greyhound_fare(miles)
}

/// `[local bus, local rail]`.
pub fn flows_modes_local_fares() -> Vec<f64> {
    vec![tm::LOCAL_BUS_FARE, tm::LOCAL_RAIL_FARE]
}

pub fn flows_modes_ride_cost(miles: f64) -> f64 {
    tm::ride_cost(miles)
}

pub fn flows_modes_meets_bar(walk_alone_seconds: f64, total_seconds: f64, cost_usd: f64) -> bool {
    tm::meets_bar(walk_alone_seconds, total_seconds, cost_usd)
}

pub fn flows_modes_evaluate_ride(
    walk_alone_seconds: f64,
    drive_seconds: f64,
    trip_miles: f64,
) -> FlowsModesRideOffer {
    match tm::evaluate_ride(walk_alone_seconds, drive_seconds, trip_miles) {
        Some(o) => FlowsModesRideOffer {
            has: true,
            ride_miles: o.ride_miles,
            ride_seconds: o.ride_seconds,
            walk_seconds: o.walk_seconds,
            cost_usd: o.cost_usd,
        },
        None => FlowsModesRideOffer {
            has: false,
            ride_miles: 0.0,
            ride_seconds: 0.0,
            walk_seconds: 0.0,
            cost_usd: 0.0,
        },
    }
}

pub fn flows_modes_prefix_coordinates(lats: &[f64], lons: &[f64], meters: f64) -> Vec<f64> {
    contain(Vec::new(), || {
        flat(&tm::prefix_coordinates(&points(lats, lons), meters))
    })
}

/// `[base fare, per mile, cost cap, minimum saved fraction, minimum saved
/// seconds, minimum walk-alone seconds, longest affordable ride miles]`.
pub fn flows_modes_ride_constants() -> Vec<f64> {
    vec![
        tm::BASE_FARE_USD,
        tm::PER_MILE_USD,
        tm::COST_CAP_USD,
        tm::MIN_SAVED_FRACTION,
        tm::MIN_SAVED_SECONDS,
        tm::MIN_WALK_ALONE_SECONDS,
        tm::max_affordable_ride_miles(),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clusters_and_hulls_cross_whole() {
        let flat_clusters =
            flows_modes_risk_clusters(&[43.0, 43.01, 45.0], &[-89.0, -89.0, -89.0], 5_000.0);
        assert_eq!(flat_clusters, vec![2, 1, 2, 2, 1, 0]);
        assert_eq!(
            flows_modes_risk_hull(&[0.0], &[0.0], 0, 1_000.0).len(),
            8,
            "no points: a diamond at the origin"
        );
        assert_eq!(
            flows_modes_retarget(
                "A",
                0.0,
                0.0,
                false,
                43.4,
                -89.0,
                "AB",
                &[1, 1],
                &[43.0, 43.5],
                &[-89.0, -89.0],
                &[1, 1]
            ),
            1
        );
        assert_eq!(
            flows_modes_retarget(
                "A",
                0.0,
                0.0,
                false,
                43.4,
                -89.0,
                "AB",
                &[5, 1],
                &[43.0, 43.5],
                &[-89.0, -89.0],
                &[1, 1]
            ),
            -1
        );
        assert_eq!(flows_modes_airport_score("Naval Air Station"), -1);
        assert!(!flows_modes_local_minutes(0.0, f64::NAN).has);
        assert_eq!(flows_modes_fallback_genre(" rock ", true), "rock");
        assert!(!flows_modes_evaluate_ride(100.0, 1.0, 1.0).has);
    }
}
