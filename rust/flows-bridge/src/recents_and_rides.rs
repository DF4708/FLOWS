// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::recents_and_rides` and the ride estimates
//! in `flows_core::travel_modes`: pasted coordinates, recent places, the
//! suggestion blend, rental counters and the emergency radio's station
//! rules. Functions are named `flows_rides_…`.
//!
//! Boundary encodings, chosen so nothing Swift sends can be misread:
//! - a point that may be missing is [`FlowsRidesPoint`]; a transmitter's
//!   position is [`FlowsRidesPosition`];
//! - an optional argument is a value plus a `has_` flag; optional text comes
//!   back as a string that is empty for none (no answer is ever empty text);
//! - a list of texts crosses as one joined string plus each text's UTF-8
//!   length;
//! - recent places cross as parallel columns (name, last use, uses); the
//!   merge answers the merged place's use count first, then the new order as
//!   indices into the old list, `-1` standing for the merged place;
//! - the suggestion blend answers a pinned row `i` as `i` and a completion
//!   `j` as `-(j + 1)`;
//! - a radio purpose is its code (see [`rr::radio_purpose`]).
//!
//! Every column travels with its count, so the facades send a one-element
//! placeholder for an empty list: swift-bridge must never see an empty
//! buffer. Every function is a thin forwarder through [`contain`].

#![allow(clippy::too_many_arguments)] // flattened Swift signatures

use crate::{contain, split_texts};
use ffi::{FlowsRidesPoint, FlowsRidesPosition};
use flows_core::recents_and_rides as rr;
use flows_core::travel_modes as tm;

#[swift_bridge::bridge]
mod ffi {
    // A point that may be missing: `lat` and `lon` mean something only when
    // `has` is true.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsRidesPoint {
        has: bool,
        lat: f64,
        lon: f64,
    }
    // A transmitter's position: exact when it carries its own coordinates,
    // otherwise the middle of its state.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsRidesPosition {
        has: bool,
        lat: f64,
        lon: f64,
        exact: bool,
    }

    extern "Rust" {
        // ---- pasted coordinates ----
        fn flows_rides_parse_coordinate(text: &str) -> FlowsRidesPoint;

        // ---- recent places ----
        fn flows_rides_recents_cap() -> i64;
        fn flows_rides_recent_score(uses: i64, last_used: f64, now: f64) -> f64;
        fn flows_rides_recordable_name(name: &str) -> String;
        fn flows_rides_merged_recents(
            names: &str,
            name_lengths: &[i64],
            last_used: &[f64],
            uses: &[i64],
            count: i64,
            new_name: &str,
            new_last_used: f64,
            new_uses: i64,
            now: f64,
        ) -> Vec<i64>;
        fn flows_rides_matching_recents(
            names: &str,
            name_lengths: &[i64],
            count: i64,
            fragment: &str,
            limit: i64,
        ) -> Vec<i64>;
        fn flows_rides_blend_suggestions(
            pinned: &str,
            pinned_lengths: &[i64],
            pinned_count: i64,
            completions: &str,
            completion_lengths: &[i64],
            completion_count: i64,
            cap: i64,
        ) -> Vec<i64>;

        // ---- ride estimates ----
        fn flows_rides_ride_multiplier(mode: &str) -> f64;
        fn flows_rides_fallback_mph(mode: &str) -> f64;
        fn flows_rides_ride_duration(
            mode: &str,
            drive_seconds: f64,
            has_drive: bool,
            miles: f64,
        ) -> f64;

        // ---- rental counters ----
        fn flows_rides_rental_brands() -> String;
        fn flows_rides_rental_brand_lengths() -> Vec<i64>;
        fn flows_rides_rental_brand_rank(name: &str, has_name: bool) -> i64;
        fn flows_rides_rental_booking_site(name: &str, has_name: bool) -> String;
        fn flows_rides_recommend_rentals(
            names: &str,
            name_lengths: &[i64],
            miles: &[f64],
            count: i64,
            limit: i64,
        ) -> Vec<i64>;

        // ---- the emergency radio ----
        fn flows_rides_radio_purpose(channel: &str) -> u8;
        fn flows_rides_radio_is_car_band(channel: &str) -> bool;
        fn flows_rides_radio_advance(index: i64, count: i64, step: i64) -> i64;
        fn flows_rides_radio_state_code(name: &str) -> String;
        fn flows_rides_radio_position(
            name: &str,
            lat: f64,
            has_lat: bool,
            lon: f64,
            has_lon: bool,
        ) -> FlowsRidesPosition;
    }
}

// ------------------------------------------------------------------ helpers

/// A count from Swift as a length no longer than `available`.
fn clamp(count: i64, available: usize) -> usize {
    usize::try_from(count).unwrap_or(0).min(available)
}

/// An index for Swift.
fn index(i: usize) -> i64 {
    i64::try_from(i).unwrap_or(i64::MAX)
}

/// The first `count` texts of a joined column, or `None` when the lengths do
/// not split it.
fn texts<'a>(joined: &'a str, lengths: &[i64], count: i64) -> Option<Vec<&'a str>> {
    split_texts(joined, lengths, clamp(count, lengths.len()))
}

const NO_POINT: FlowsRidesPoint = FlowsRidesPoint {
    has: false,
    lat: 0.0,
    lon: 0.0,
};

const NO_POSITION: FlowsRidesPosition = FlowsRidesPosition {
    has: false,
    lat: 0.0,
    lon: 0.0,
    exact: false,
};

// ------------------------------------------------------------------ coordinates

/// `CoordinateInput.parse`.
pub fn flows_rides_parse_coordinate(text: &str) -> FlowsRidesPoint {
    contain(NO_POINT, || {
        rr::parse_coordinate(text).map_or(NO_POINT, |(lat, lon)| FlowsRidesPoint {
            has: true,
            lat,
            lon,
        })
    })
}

// ------------------------------------------------------------------ recents

/// `RecentDestinations.cap`.
pub fn flows_rides_recents_cap() -> i64 {
    index(rr::RECENTS_CAP)
}

/// `RecentDestinations.score`.
pub fn flows_rides_recent_score(uses: i64, last_used: f64, now: f64) -> f64 {
    contain(0.0, || rr::recent_score(uses, last_used, now))
}

/// The name `record` keeps, or empty text when it keeps nothing.
pub fn flows_rides_recordable_name(name: &str) -> String {
    contain(String::new(), || {
        rr::recordable_name(name).unwrap_or_default().to_string()
    })
}

/// `RecentDestinations.merged`: the merged place's use count, then the new
/// order as indices into the old list (`-1` for the merged place). Places
/// cross without their coordinates: the order and the count never read
/// them, and Swift keeps them.
pub fn flows_rides_merged_recents(
    names: &str,
    name_lengths: &[i64],
    last_used: &[f64],
    uses: &[i64],
    count: i64,
    new_name: &str,
    new_last_used: f64,
    new_uses: i64,
    now: f64,
) -> Vec<i64> {
    contain(vec![new_uses], || {
        let n = clamp(count, last_used.len().min(uses.len()));
        let Some(names) = texts(names, name_lengths, index(n)) else {
            return vec![new_uses];
        };
        let list: Vec<rr::Recent> = names
            .iter()
            .enumerate()
            .map(|(i, name)| rr::Recent {
                name: (*name).to_string(),
                latitude: 0.0,
                longitude: 0.0,
                last_used: last_used[i],
                uses: uses[i],
            })
            .collect();
        let new = rr::Recent {
            name: new_name.to_string(),
            latitude: 0.0,
            longitude: 0.0,
            last_used: new_last_used,
            uses: new_uses,
        };
        let (merged_uses, order) = rr::merged_recent_order(&list, &new, now);
        std::iter::once(merged_uses)
            .chain(order.into_iter().map(|slot| slot.map_or(-1, index)))
            .collect()
    })
}

/// `RecentDestinations.matching`: indices into the ranked names.
pub fn flows_rides_matching_recents(
    names: &str,
    name_lengths: &[i64],
    count: i64,
    fragment: &str,
    limit: i64,
) -> Vec<i64> {
    contain(Vec::new(), || {
        texts(names, name_lengths, count).map_or_else(Vec::new, |names| {
            rr::matching_recents(&names, fragment, clamp(limit, usize::MAX))
                .into_iter()
                .map(index)
                .collect()
        })
    })
}

/// `DestinationSearch.blend`: a pinned row `i` as `i`, a completion `j` as
/// `-(j + 1)`.
pub fn flows_rides_blend_suggestions(
    pinned: &str,
    pinned_lengths: &[i64],
    pinned_count: i64,
    completions: &str,
    completion_lengths: &[i64],
    completion_count: i64,
    cap: i64,
) -> Vec<i64> {
    contain(Vec::new(), || {
        let (Some(pinned), Some(completions)) = (
            texts(pinned, pinned_lengths, pinned_count),
            texts(completions, completion_lengths, completion_count),
        ) else {
            return Vec::new();
        };
        rr::blend_suggestions(&pinned, &completions, clamp(cap, usize::MAX))
            .into_iter()
            .map(|row| match row {
                rr::Blended::Pinned(i) => index(i),
                rr::Blended::Completion(j) => -index(j) - 1,
            })
            .collect()
    })
}

// ------------------------------------------------------------------ rides

/// `TransitPlanning.rideMultiplier`.
pub fn flows_rides_ride_multiplier(mode: &str) -> f64 {
    contain(2.0, || tm::ride_multiplier(mode))
}

/// `TransitPlanning.fallbackMPH`.
pub fn flows_rides_fallback_mph(mode: &str) -> f64 {
    contain(12.0, || tm::fallback_mph(mode))
}

/// `TransitPlanning.rideDuration`.
pub fn flows_rides_ride_duration(
    mode: &str,
    drive_seconds: f64,
    has_drive: bool,
    miles: f64,
) -> f64 {
    contain(0.0, || {
        tm::ride_duration(mode, has_drive.then_some(drive_seconds), miles)
    })
}

// ------------------------------------------------------------------ rentals

/// `RentalCars.brandOrder`, joined.
pub fn flows_rides_rental_brands() -> String {
    rr::RENTAL_BRANDS.concat()
}

/// Each brand's UTF-8 length in [`flows_rides_rental_brands`].
pub fn flows_rides_rental_brand_lengths() -> Vec<i64> {
    rr::RENTAL_BRANDS.iter().map(|b| index(b.len())).collect()
}

/// `RentalCars.brandRank(name:)`.
pub fn flows_rides_rental_brand_rank(name: &str, has_name: bool) -> i64 {
    contain(index(rr::RENTAL_BRANDS.len()), || {
        index(rr::rental_brand_rank(has_name.then_some(name)))
    })
}

/// `RentalCars.bookingURL(name:)`'s site, or empty text for none.
pub fn flows_rides_rental_booking_site(name: &str, has_name: bool) -> String {
    contain(String::new(), || {
        rr::rental_booking_site(has_name.then_some(name))
            .unwrap_or_default()
            .to_string()
    })
}

/// `RentalCars.recommend`: indices of the offices worth showing.
pub fn flows_rides_recommend_rentals(
    names: &str,
    name_lengths: &[i64],
    miles: &[f64],
    count: i64,
    limit: i64,
) -> Vec<i64> {
    contain(Vec::new(), || {
        let n = clamp(count, miles.len());
        texts(names, name_lengths, index(n)).map_or_else(Vec::new, |names| {
            rr::recommend_rentals(&names, &miles[..n], clamp(limit, usize::MAX))
                .into_iter()
                .map(index)
                .collect()
        })
    })
}

// ------------------------------------------------------------------ radio

/// `TruckerRadio.shortPurpose`'s code.
pub fn flows_rides_radio_purpose(channel: &str) -> u8 {
    contain(4, || rr::radio_purpose(channel))
}

/// Whether `TruckerRadio.carBandLabel` has a label.
pub fn flows_rides_radio_is_car_band(channel: &str) -> bool {
    contain(false, || rr::radio_is_car_band(channel))
}

/// `TruckerRadio.advance`.
pub fn flows_rides_radio_advance(index: i64, count: i64, step: i64) -> i64 {
    contain(0, || rr::radio_advance(index, count, step))
}

/// `TruckerRadio.stateCode(of:)`, or empty text for none.
pub fn flows_rides_radio_state_code(name: &str) -> String {
    contain(String::new(), || {
        rr::radio_state_code(name).unwrap_or_default()
    })
}

/// `TruckerRadio.position(of:)`.
pub fn flows_rides_radio_position(
    name: &str,
    lat: f64,
    has_lat: bool,
    lon: f64,
    has_lon: bool,
) -> FlowsRidesPosition {
    contain(NO_POSITION, || {
        rr::radio_position(name, has_lat.then_some(lat), has_lon.then_some(lon)).map_or(
            NO_POSITION,
            |(lat, lon, exact)| FlowsRidesPosition {
                has: true,
                lat,
                lon,
                exact,
            },
        )
    })
}
