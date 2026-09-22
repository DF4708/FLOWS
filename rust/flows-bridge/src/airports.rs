// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::airports`: which airports with airline
//! service sit near a point, and which two ends a trip would fly between.
//!
//! Each airport crosses as ONE joined text — code, name, city, country,
//! region and size separated by the unit separator (U+001F), which no name
//! contains — plus its coordinates and the straight-line meters to the query
//! in a parallel list of three doubles per row. The pair call answers the two
//! rows in board, alight order, or nothing at all.
//!
//! Every function is a thin forwarder through [`contain`], so a panic inside
//! the core becomes the documented fallback instead of crossing into Swift.

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        fn flows_airports_nearest(latitude: f64, longitude: f64, limit: i64) -> Vec<String>;
        fn flows_airports_nearest_places(latitude: f64, longitude: f64, limit: i64) -> Vec<f64>;
        fn flows_airports_pair(
            from_latitude: f64,
            from_longitude: f64,
            to_latitude: f64,
            to_longitude: f64,
            min_gap_meters: f64,
        ) -> Vec<String>;
        fn flows_airports_pair_places(
            from_latitude: f64,
            from_longitude: f64,
            to_latitude: f64,
            to_longitude: f64,
            min_gap_meters: f64,
        ) -> Vec<f64>;
        fn flows_airports_max_drive_meters() -> f64;
    }
}

use crate::contain;
use flows_core::airports::{self, Airport, Size};
use flows_core::geo;

/// The separator between an airport's fields. U+001F is not a character any
/// name carries, so a name holding any punctuation still splits back exactly.
const UNIT: char = '\u{1F}';

fn size_name(size: Size) -> &'static str {
    match size {
        Size::Large => "large",
        Size::Medium => "medium",
        Size::Small => "small",
    }
}

fn joined(a: &Airport) -> String {
    format!(
        "{}{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}",
        a.iata,
        a.name,
        a.city,
        a.country,
        a.region,
        size_name(a.size)
    )
}

fn places(a: &Airport, from: (f64, f64)) -> [f64; 3] {
    [a.lat, a.lon, geo::meters(from.0, from.1, a.lat, a.lon)]
}

fn limit_of(limit: i64) -> usize {
    usize::try_from(limit).unwrap_or(0).min(16)
}

/// The airports near a point, best first: each row "IATA␟name␟city␟country␟region␟size".
pub fn flows_airports_nearest(latitude: f64, longitude: f64, limit: i64) -> Vec<String> {
    contain(Vec::new(), || {
        airports::nearest(
            latitude,
            longitude,
            limit_of(limit),
            airports::MAX_DRIVE_METERS,
        )
        .iter()
        .map(|a| joined(a))
        .collect()
    })
}

/// The same airports' latitude, longitude and straight-line meters from the
/// query, three doubles per row, in the same order as
/// [`flows_airports_nearest`].
pub fn flows_airports_nearest_places(latitude: f64, longitude: f64, limit: i64) -> Vec<f64> {
    contain(Vec::new(), || {
        airports::nearest(
            latitude,
            longitude,
            limit_of(limit),
            airports::MAX_DRIVE_METERS,
        )
        .iter()
        .flat_map(|a| places(a, (latitude, longitude)))
        .collect()
    })
}

fn pair_of(
    from_latitude: f64,
    from_longitude: f64,
    to_latitude: f64,
    to_longitude: f64,
    min_gap_meters: f64,
) -> Option<(&'static Airport, &'static Airport)> {
    airports::pair(
        (from_latitude, from_longitude),
        (to_latitude, to_longitude),
        airports::MAX_DRIVE_METERS,
        min_gap_meters,
    )
}

/// The two ends of a flight for this trip — board first, then alight — or an
/// empty answer when the trip has no flight.
pub fn flows_airports_pair(
    from_latitude: f64,
    from_longitude: f64,
    to_latitude: f64,
    to_longitude: f64,
    min_gap_meters: f64,
) -> Vec<String> {
    contain(Vec::new(), || {
        pair_of(
            from_latitude,
            from_longitude,
            to_latitude,
            to_longitude,
            min_gap_meters,
        )
        .map(|(b, a)| vec![joined(b), joined(a)])
        .unwrap_or_default()
    })
}

/// The pair's coordinates and the drive to each: board's three doubles, then
/// alight's, matching [`flows_airports_pair`].
pub fn flows_airports_pair_places(
    from_latitude: f64,
    from_longitude: f64,
    to_latitude: f64,
    to_longitude: f64,
    min_gap_meters: f64,
) -> Vec<f64> {
    contain(Vec::new(), || {
        pair_of(
            from_latitude,
            from_longitude,
            to_latitude,
            to_longitude,
            min_gap_meters,
        )
        .map(|(b, a)| {
            let mut out = Vec::with_capacity(6);
            out.extend_from_slice(&places(b, (from_latitude, from_longitude)));
            out.extend_from_slice(&places(a, (to_latitude, to_longitude)));
            out
        })
        .unwrap_or_default()
    })
}

/// How far the core will drive to an airport (meters), so Swift says the same.
pub fn flows_airports_max_drive_meters() -> f64 {
    airports::MAX_DRIVE_METERS
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_owners_trip_crosses_as_two_rows() {
        let rows = flows_airports_pair(43.0389, -87.9065, 33.5337, -82.1307, 100_000.0);
        assert_eq!(rows.len(), 2);
        let board: Vec<&str> = rows[0].split(UNIT).collect();
        assert_eq!(board[0], "MKE");
        assert_eq!(board[2], "Milwaukee");
        assert_eq!(board[3], "US");
        assert_eq!(board[4], "US-WI");
        assert_eq!(board[5], "large");
        assert!(rows[1].starts_with("AGS"));
        let places = flows_airports_pair_places(43.0389, -87.9065, 33.5337, -82.1307, 100_000.0);
        assert_eq!(places.len(), 6);
        assert!(
            places[2] < 20_000.0,
            "MKE is close to Milwaukee: {}",
            places[2]
        );
        assert!(places[5] < 40_000.0, "AGS is close to Evans: {}", places[5]);
    }

    #[test]
    fn a_trip_with_no_flight_crosses_as_nothing() {
        assert!(flows_airports_pair(43.0389, -87.9065, 43.0731, -89.4012, 160_000.0).is_empty());
        assert!(
            flows_airports_pair_places(43.0389, -87.9065, 43.0731, -89.4012, 160_000.0).is_empty()
        );
    }

    #[test]
    fn nearest_rows_and_places_line_up() {
        let rows = flows_airports_nearest(43.0731, -89.4012, 3);
        let places = flows_airports_nearest_places(43.0731, -89.4012, 3);
        assert_eq!(rows.len(), 3);
        assert_eq!(places.len(), 9);
        assert!(rows[0].starts_with("MSN"));
        for row in &rows {
            assert_eq!(row.split(UNIT).count(), 6, "{row}");
        }
        assert!(places[2] <= places[5], "nearest first");
        assert!(flows_airports_nearest(43.0731, -89.4012, 0).is_empty());
        assert!(flows_airports_max_drive_meters() > 100_000.0);
    }
}
