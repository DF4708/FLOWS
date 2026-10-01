// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Rental-car links that land somewhere real.
//!
//! The owner's affiliate is DiscoverCars; its landing pages live at
//! `discovercars.com/{region}/{city}[/{location}]`, and a page that does not
//! exist is a 404 the traveller hits the moment they need a car. FLOWS used
//! to guess those paths from map names, and DiscoverCars names places its own
//! way — Mexico City is `mexico/mexico`, Quebec City is `canada/quebec` — so
//! some guesses were wrong. Every path here comes from DiscoverCars' own list
//! (see `flows-train`'s `rental-places-table`), so it resolves by
//! construction.
//!
//! Two links, from most to least specific:
//! - [`landing_for_airport`] — the page for the arrival airport itself,
//!   `usa-illinois/chicago/ord`, when DiscoverCars lists that airport;
//! - [`landing_near`] — the nearest DiscoverCars city to a point, then that
//!   city's state or country page, then the partner homepage.
//!
//! Every link goes through [`partner_link`], the one place that decides how a
//! path becomes a link with FLOWS's partner code on it.

use crate::recents_and_rides::{RENTAL_COMPARE_URL, RENTAL_PARTNER_CODE};
use crate::rental_places_table::{RENTAL_AIRPORTS, RENTAL_CITIES};
use crate::seasonal::haversine_km;

/// One of DiscoverCars' rental cities.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RentalCity {
    pub country: &'static str,
    /// "usa-illinois", "canada", "mexico" — the first path segment.
    pub region: &'static str,
    pub name: &'static str,
    /// "chicago", "quebec", "mexico" — DiscoverCars' own spelling.
    pub slug: &'static str,
    pub lat: f64,
    pub lon: f64,
}

/// An airport DiscoverCars lists as a pick-up location, under the city it
/// files it in (ORD under Chicago, not the suburb it sits in).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RentalAirport {
    pub iata: &'static str,
    pub region: &'static str,
    pub city: &'static str,
}

/// A rental city this close to where someone arrives is where they would
/// pick a car up.
pub const NEAR_CITY_KM: f64 = 60.0;

/// Farther than [`NEAR_CITY_KM`] from every city, the nearest one's state or
/// country page is still the right place to start — out to this far. Past
/// it, a state page would be a guess, and the homepage is honest.
pub const NEAR_REGION_KM: f64 = 250.0;

/// The whole link for a DiscoverCars path, with FLOWS's partner code. An
/// empty path is the partner homepage.
#[must_use]
pub fn partner_link(path: &str) -> String {
    let path = path.trim_matches('/');
    if path.is_empty() {
        RENTAL_COMPARE_URL.to_string()
    } else {
        format!("https://www.discovercars.com/{path}?a_aid={RENTAL_PARTNER_CODE}")
    }
}

/// The nearest rental city to a point, and how far it is in kilometres.
#[must_use]
pub fn nearest_city(lat: f64, lon: f64) -> Option<(&'static RentalCity, f64)> {
    if !lat.is_finite() || !lon.is_finite() {
        return None;
    }
    RENTAL_CITIES
        .iter()
        .map(|c| (c, haversine_km(lat, lon, c.lat, c.lon)))
        .min_by(|a, b| a.1.total_cmp(&b.1))
}

/// The DiscoverCars path for renting near a point: the nearest city within
/// [`NEAR_CITY_KM`], else that city's region within [`NEAR_REGION_KM`], else
/// empty (the homepage).
#[must_use]
pub fn path_near(lat: f64, lon: f64) -> String {
    match nearest_city(lat, lon) {
        Some((c, km)) if km <= NEAR_CITY_KM => format!("{}/{}", c.region, c.slug),
        Some((c, km)) if km <= NEAR_REGION_KM => c.region.to_string(),
        _ => String::new(),
    }
}

/// Where a traveller near a point picks a rental car up, by DiscoverCars'
/// own list: its nearest city within [`NEAR_CITY_KM`], the place the partner
/// page books in. The counter is whichever company the traveller books
/// there, so FLOWS names the place, never a brand. `None` when no city is
/// that close.
#[must_use]
pub fn pickup_near(lat: f64, lon: f64) -> Option<&'static RentalCity> {
    match nearest_city(lat, lon) {
        Some((c, km)) if km <= NEAR_CITY_KM => Some(c),
        _ => None,
    }
}

/// The partner link for renting near a point. See [`path_near`].
#[must_use]
pub fn landing_near(lat: f64, lon: f64) -> String {
    partner_link(&path_near(lat, lon))
}

/// Where DiscoverCars lists an airport, if it does.
#[must_use]
pub fn airport(iata: &str) -> Option<&'static RentalAirport> {
    let code = iata.trim().to_ascii_uppercase();
    RENTAL_AIRPORTS
        .binary_search_by(|a| a.iata.cmp(code.as_str()))
        .ok()
        .map(|i| &RENTAL_AIRPORTS[i])
}

/// The partner link for renting at an arrival airport: its own page when
/// DiscoverCars lists it, otherwise the best page near the airport.
#[must_use]
pub fn landing_for_airport(iata: &str, lat: f64, lon: f64) -> String {
    match airport(iata) {
        Some(a) => partner_link(&format!(
            "{}/{}/{}",
            a.region,
            a.city,
            a.iata.to_ascii_lowercase()
        )),
        None => landing_near(lat, lon),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_pickup_is_the_discovercars_city_not_a_brand() {
        // Downtown Milwaukee books in Milwaukee; the middle of Lake
        // Michigan is no city's.
        let city = pickup_near(43.0389, -87.9065).expect("Milwaukee is a rental city");
        assert_eq!(city.name, "Milwaukee");
        assert_eq!(city.region, "usa-wisconsin");
        assert!(pickup_near(43.5, -86.9).is_none());
        assert!(pickup_near(f64::NAN, 0.0).is_none());
    }

    #[test]
    fn the_places_that_used_to_404_now_land() {
        // Map names FLOWS once turned into links that did not exist.
        assert_eq!(
            landing_near(19.4326, -99.1332),
            "https://www.discovercars.com/mexico/mexico?a_aid=FAWN",
            "Mexico City"
        );
        assert_eq!(
            landing_near(46.8139, -71.2080),
            "https://www.discovercars.com/canada/quebec?a_aid=FAWN",
            "Quebec City"
        );
        assert_eq!(
            landing_near(40.7128, -74.0060),
            "https://www.discovercars.com/usa-new-york/new-york?a_aid=FAWN",
            "New York City"
        );
    }

    #[test]
    fn an_arrival_airport_gets_its_own_page() {
        assert_eq!(
            landing_for_airport("ORD", 41.9786, -87.9048),
            "https://www.discovercars.com/usa-illinois/chicago/ord?a_aid=FAWN",
            "filed under Chicago, not Rosemont where it sits"
        );
        assert_eq!(
            landing_for_airport("yyz", 43.6777, -79.6248),
            "https://www.discovercars.com/canada/toronto/yyz?a_aid=FAWN"
        );
    }

    #[test]
    fn an_airport_discovercars_does_not_list_falls_back_to_the_city() {
        // "ZZZ" is no airport: the link is the best page near the point.
        assert_eq!(
            landing_for_airport("ZZZ", 43.0389, -87.9065),
            landing_near(43.0389, -87.9065)
        );
        assert!(landing_near(43.0389, -87.9065).contains("/usa-wisconsin/"));
    }

    #[test]
    fn far_from_everything_the_link_is_still_honest() {
        // Mid-Atlantic: no city, no state — the partner homepage.
        assert_eq!(landing_near(35.0, -40.0), RENTAL_COMPARE_URL);
        assert_eq!(landing_near(f64::NAN, 0.0), RENTAL_COMPARE_URL);
        assert_eq!(partner_link(""), RENTAL_COMPARE_URL);
        assert_eq!(
            partner_link("/usa-texas/"),
            "https://www.discovercars.com/usa-texas?a_aid=FAWN"
        );
    }

    #[test]
    fn every_airport_points_at_a_city_in_the_table() {
        for a in RENTAL_AIRPORTS {
            assert!(
                RENTAL_CITIES
                    .iter()
                    .any(|c| c.region == a.region && c.slug == a.city),
                "{} → {}/{}",
                a.iata,
                a.region,
                a.city
            );
        }
        let codes: Vec<&str> = RENTAL_AIRPORTS.iter().map(|a| a.iata).collect();
        let mut sorted = codes.clone();
        sorted.sort_unstable();
        assert_eq!(codes, sorted, "sorted, so lookups can binary-search");
    }
}
