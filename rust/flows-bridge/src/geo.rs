// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::geo`. Functions are named `flows_geo_…`.
//!
//! The kernel crosses with its callers. Today that is the fuel warning's
//! bearing and reachability test and the saved corridor nearest a position;
//! the rest (`POIRanking.meters` and its many callers) moves with wave 3.
//!
//! Point lists cross as latitude and longitude columns with a count, and a
//! list of corridors as flat columns plus each corridor's point count, so the
//! facades can send a one-element placeholder for an empty list: swift-bridge
//! must never see an empty buffer. An index answer is `-1` for none. Every
//! function is a thin forwarder through [`contain`].

#![allow(clippy::too_many_arguments)] // flattened Swift signatures

use crate::contain;
use flows_core::geo;

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        fn flows_geo_bearing_degrees(a_lat: f64, a_lon: f64, b_lat: f64, b_lon: f64) -> f64;
        fn flows_geo_ahead_cone_degrees() -> f64;
        fn flows_geo_fuel_corridor_meters() -> f64;
        fn flows_geo_fuel_station_is_reachable(
            station_lat: f64,
            station_lon: f64,
            here_lat: f64,
            here_lon: f64,
            course_degrees: f64,
            route_lats: &[f64],
            route_lons: &[f64],
            route_count: i64,
            corridor_meters: f64,
        ) -> bool;
        fn flows_geo_corridor_nearest(
            lats: &[f64],
            lons: &[f64],
            point_counts: &[i64],
            corridor_count: i64,
            lat: f64,
            lon: f64,
        ) -> i64;
    }
}

/// A count from Swift as a length no longer than `available`.
fn clamp(count: i64, available: usize) -> usize {
    usize::try_from(count).unwrap_or(0).min(available)
}

/// `geo::bearing_degrees`. A panic answers NaN.
pub fn flows_geo_bearing_degrees(a_lat: f64, a_lon: f64, b_lat: f64, b_lon: f64) -> f64 {
    contain(f64::NAN, || {
        geo::bearing_degrees(a_lat, a_lon, b_lat, b_lon)
    })
}

/// `geo::AHEAD_CONE_DEGREES`.
pub fn flows_geo_ahead_cone_degrees() -> f64 {
    geo::AHEAD_CONE_DEGREES
}

/// `geo::FUEL_CORRIDOR_METERS`.
pub fn flows_geo_fuel_corridor_meters() -> f64 {
    geo::FUEL_CORRIDOR_METERS
}

/// `geo::fuel_station_is_reachable` over the first `route_count` route
/// points. A panic answers true: nothing is ruled out.
pub fn flows_geo_fuel_station_is_reachable(
    station_lat: f64,
    station_lon: f64,
    here_lat: f64,
    here_lon: f64,
    course_degrees: f64,
    route_lats: &[f64],
    route_lons: &[f64],
    route_count: i64,
    corridor_meters: f64,
) -> bool {
    contain(true, || {
        let n = clamp(route_count, route_lats.len().min(route_lons.len()));
        geo::fuel_station_is_reachable(
            station_lat,
            station_lon,
            here_lat,
            here_lon,
            course_degrees,
            &route_lats[..n],
            &route_lons[..n],
            corridor_meters,
        )
    })
}

/// `geo::corridor_nearest` over the first `corridor_count` corridors, `-1`
/// for none. A panic answers none.
pub fn flows_geo_corridor_nearest(
    lats: &[f64],
    lons: &[f64],
    point_counts: &[i64],
    corridor_count: i64,
    lat: f64,
    lon: f64,
) -> i64 {
    contain(-1, || {
        let counts: Vec<usize> = point_counts[..clamp(corridor_count, point_counts.len())]
            .iter()
            .map(|&c| usize::try_from(c).unwrap_or(0))
            .collect();
        geo::corridor_nearest(lats, lons, &counts, lat, lon)
            .map_or(-1, |i| i64::try_from(i).unwrap_or(-1))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn placeholders_behind_a_zero_count_are_never_read() {
        assert_eq!(
            flows_geo_corridor_nearest(&[0.0], &[0.0], &[0], 0, 1.0, 1.0),
            -1
        );
        // No route: the course cone decides, and a negative course keeps the station.
        assert!(flows_geo_fuel_station_is_reachable(
            1.0,
            1.0,
            0.0,
            0.0,
            -1.0,
            &[50.0],
            &[50.0],
            0,
            8_000.0
        ));
        assert!(!flows_geo_fuel_station_is_reachable(
            1.0,
            1.0,
            0.0,
            0.0,
            -1.0,
            &[50.0],
            &[50.0],
            1,
            8_000.0
        ));
    }
}
