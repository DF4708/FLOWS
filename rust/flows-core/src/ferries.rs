// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The ferries that run where no timetable feed covers them.
//!
//! The ship card reads ferries' own timetables first. About sixty operators
//! publish one; the federal ferry census lists 162 operators and 905 routes
//! (`ferries_table.rs`, BTS 2024, public domain). For a route with no
//! timetable the census still says who runs it, between which terminals, how
//! long a crossing takes, in which season, and whether cars go aboard — so
//! the card can say a ferry runs there and send the rider to its operator
//! for the times, instead of saying no ferry runs at all.

use crate::ferries_table::{FERRY_OPERATORS, FERRY_ROUTES, FERRY_TERMINALS};
use crate::seasonal::haversine_km;

/// A ferry terminal in service.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FerryTerminal {
    /// The census's id.
    pub id: u32,
    pub name: &'static str,
    pub city: &'static str,
    /// State or province code: "WA", "BC".
    pub state: &'static str,
    pub lat: f64,
    pub lon: f64,
}

/// Who runs a route, and their own site — where the times and tickets are.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FerryOperator {
    pub id: u32,
    pub name: &'static str,
    /// Empty when the census has none.
    pub url: &'static str,
}

/// One operator's route between two terminals.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FerryRoute {
    /// The census's name for it: "Bainbridge - Colman Dock/Pier 52".
    pub name: &'static str,
    /// Terminal ids; a route runs both ways.
    pub a: u32,
    pub b: u32,
    pub operator: u32,
    pub miles: f64,
    /// A typical crossing, in minutes; 0 when not reported.
    pub minutes: u32,
    /// First and last day of service: [month, day, month, day]; all zero
    /// when not reported.
    pub season: [u8; 4],
    /// One-way crossings in the census year; 0 when not reported.
    pub trips_per_year: u32,
    /// Cars carried that year: some, none, or not reported.
    pub cars: Option<bool>,
}

impl FerryRoute {
    /// Whether it runs on a month and day. Unreported seasons count as
    /// running — the card sends the rider to the operator for times either
    /// way. A season that wraps the new year (Nov–Mar) is handled.
    #[must_use]
    pub fn runs_on(&self, month: u8, day: u8) -> bool {
        let [m1, d1, m2, d2] = self.season;
        if m1 == 0 || m2 == 0 {
            return true;
        }
        let at = (month, day);
        let (start, end) = ((m1, d1), (m2, d2));
        if start <= end {
            start <= at && at <= end
        } else {
            at >= start || at <= end
        }
    }

    /// Crossings a day, on average over its season (both ways together).
    #[must_use]
    pub fn crossings_a_day(&self) -> f64 {
        if self.trips_per_year == 0 {
            return 0.0;
        }
        f64::from(self.trips_per_year) / f64::from(self.season_days())
    }

    fn season_days(&self) -> u32 {
        let [m1, d1, m2, d2] = self.season;
        if m1 == 0 || m2 == 0 {
            return 365;
        }
        let day_of_year = |m: u8, d: u8| -> u32 {
            const BEFORE: [u32; 12] = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
            BEFORE[usize::from(m.clamp(1, 12)) - 1] + u32::from(d)
        };
        let (start, end) = (day_of_year(m1, d1), day_of_year(m2, d2));
        if start <= end {
            end - start + 1
        } else {
            365 - start + end + 1
        }
    }
}

/// A terminal by census id.
#[must_use]
pub fn terminal(id: u32) -> Option<&'static FerryTerminal> {
    FERRY_TERMINALS
        .binary_search_by_key(&id, |t| t.id)
        .ok()
        .map(|i| &FERRY_TERMINALS[i])
}

/// An operator by census id.
#[must_use]
pub fn operator(id: u32) -> Option<&'static FerryOperator> {
    FERRY_OPERATORS
        .binary_search_by_key(&id, |o| o.id)
        .ok()
        .map(|i| &FERRY_OPERATORS[i])
}

/// A route between a terminal near the start and one near the destination,
/// in the direction the rider goes.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Crossing {
    pub route: &'static FerryRoute,
    pub board: &'static FerryTerminal,
    pub alight: &'static FerryTerminal,
    pub operator: &'static FerryOperator,
    /// From the start to the boarding terminal, and from the landing to the
    /// destination, as the crow flies.
    pub board_meters: f64,
    pub alight_meters: f64,
}

/// The census routes with a terminal within `reach_meters` of `from` and the
/// other within it of `to`, least ground to cover at the two ends first, at
/// most `limit`. One route, two operators (a shared segment) is two answers.
#[must_use]
pub fn crossings(
    from: (f64, f64),
    to: (f64, f64),
    reach_meters: f64,
    limit: usize,
) -> Vec<Crossing> {
    let finite = |p: (f64, f64)| p.0.is_finite() && p.1.is_finite();
    if !finite(from) || !finite(to) || reach_meters.is_nan() || reach_meters <= 0.0 || limit == 0 {
        return Vec::new();
    }
    let meters = |p: (f64, f64), t: &FerryTerminal| haversine_km(p.0, p.1, t.lat, t.lon) * 1000.0;
    let mut found: Vec<Crossing> = Vec::new();
    for route in FERRY_ROUTES {
        let (Some(a), Some(b), Some(op)) = (
            terminal(route.a),
            terminal(route.b),
            operator(route.operator),
        ) else {
            continue;
        };
        for (board, alight) in [(a, b), (b, a)] {
            let (on, off) = (meters(from, board), meters(to, alight));
            if on <= reach_meters && off <= reach_meters {
                found.push(Crossing {
                    route,
                    board,
                    alight,
                    operator: op,
                    board_meters: on,
                    alight_meters: off,
                });
            }
        }
    }
    found.sort_by(|x, y| {
        (x.board_meters + x.alight_meters)
            .total_cmp(&(y.board_meters + y.alight_meters))
            .then(x.route.name.cmp(y.route.name))
            .then(x.operator.id.cmp(&y.operator.id))
    });
    found.truncate(limit);
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    const SEATTLE: (f64, f64) = (47.6097, -122.3331);
    const WINSLOW: (f64, f64) = (47.6262, -122.5212);
    const JUNEAU: (f64, f64) = (58.3019, -134.4197);
    const HAINES: (f64, f64) = (59.2358, -135.4453);

    #[test]
    fn the_tables_are_sorted_and_every_route_resolves() {
        assert!(FERRY_ROUTES.len() > 500, "{}", FERRY_ROUTES.len());
        for w in FERRY_TERMINALS.windows(2) {
            assert!(w[0].id < w[1].id);
        }
        for w in FERRY_OPERATORS.windows(2) {
            assert!(w[0].id < w[1].id);
        }
        for r in FERRY_ROUTES {
            assert!(
                terminal(r.a).is_some() && terminal(r.b).is_some(),
                "{}",
                r.name
            );
            assert!(operator(r.operator).is_some(), "{}", r.name);
        }
    }

    #[test]
    fn seattle_to_bainbridge_is_the_state_ferry() {
        let found = crossings(SEATTLE, WINSLOW, 5_000.0, 3);
        let first = found.first().expect("a ferry");
        assert!(
            first.operator.name.contains("Washington State Ferries"),
            "{first:?}"
        );
        assert!(first.board.city.contains("Seattle") || first.board.name.contains("Colman"));
        assert_eq!(first.alight.city, "Bainbridge Island");
        assert_eq!(first.route.minutes, 35);
        assert_eq!(first.route.cars, Some(true));
    }

    #[test]
    fn a_ferry_with_no_timetable_feed_is_still_known() {
        // The Alaska Marine Highway publishes no GTFS.
        let found = crossings(JUNEAU, HAINES, 40_000.0, 3);
        let first = found.first().expect("the Marine Highway");
        assert!(
            first.operator.name.contains("Alaska Marine Highway"),
            "{first:?}"
        );
        assert!(first.operator.url.starts_with("https://"));
        assert!(first.route.minutes > 60);
    }

    #[test]
    fn a_season_is_a_season() {
        let badger = FERRY_ROUTES
            .iter()
            .find(|r| r.name == "Ludington - Manitowoc")
            .expect("the SS Badger");
        assert!(badger.runs_on(7, 4));
        assert!(!badger.runs_on(1, 15), "not in January");
        assert_eq!(badger.cars, None, "the census left its car count blank");
        let winter = FerryRoute {
            season: [11, 1, 3, 31],
            ..*badger
        };
        assert!(winter.runs_on(12, 25) && winter.runs_on(2, 1) && !winter.runs_on(7, 1));
        let unknown = FerryRoute {
            season: [0; 4],
            ..*badger
        };
        assert!(unknown.runs_on(1, 1));
        assert!(badger.crossings_a_day() > 1.0);
    }

    #[test]
    fn nowhere_near_the_water_finds_nothing() {
        assert!(crossings((39.7392, -104.9903), (38.8339, -104.8214), 40_000.0, 3).is_empty());
        assert!(crossings((f64::NAN, 0.0), WINSLOW, 5_000.0, 3).is_empty());
        assert!(crossings(SEATTLE, WINSLOW, 0.0, 3).is_empty());
    }
}
