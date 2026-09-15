// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Other ways to travel and the offline trail: the nearest Amtrak station,
//! the breadcrumb trail's rules, the plane option, rush-hour traffic checks,
//! the outlined risk areas, transit fares and the walk-plus-ride offer —
//! `AmtrakStations.swift`, `BreadcrumbTrail.swift`, `AirTravel.swift`,
//! `Mobility.swift` and `HybridWalk.swift` at commit bea472d, the last before
//! their facade switch.
//!
//! | here | Swift |
//! |---|---|
//! | [`nearest_within`] | `AmtrakStations.nearest(to:within:in:)` |
//! | [`should_record`], [`way_back_meters`] | `BreadcrumbTrail.shouldRecord`, `wayBack().meters` |
//! | [`worth_flying`], [`flight_seconds`], [`door_seconds`], [`fare_estimate`], [`airport_score`], [`pick_airport`] | `AirTravel` |
//! | [`is_peak`], [`local_minutes`], [`traffic_interval_seconds`] | `TrafficCadence` |
//! | [`risk_clusters`], [`risk_hull`] | `RiskBlob.clusters`, `.hull` |
//! | [`amtrak_fare`], [`greyhound_fare`], [`LOCAL_BUS_FARE`], [`LOCAL_RAIL_FARE`] | `TransitFares` |
//! | [`ride_cost`], [`meets_bar`], [`evaluate_ride`], [`prefix_coordinates`] | `HybridWalk` |
//!
//! # Fidelity
//!
//! Pinned by `flows-bridge/tests/fixtures/swift_modes_oracle.tsv`. Distances
//! are the geo kernel's [`meters`] in the Swift's argument order; every
//! `min(by:)` keeps its first winner; the hull's sort is Swift's own
//! ([`crate::learning::swift_sort_by`]); folds run in index order; a time of
//! day truncates as `truncatingRemainder` does. Where the Swift trapped (a
//! longitude that is not a number reaching `Int`) the port answers nothing.
//! Step wording, ticket and ride links, and the stored trail stay in Swift.

use crate::fcmp::{smax, swift_int};
use crate::geo::meters;
use crate::learning::swift_sort_by;
use crate::swift_text as st;

/// A point as (latitude, longitude), degrees.
pub type Point = (f64, f64);

// ============================================================ AmtrakStations

/// `AmtrakStations.nearest`: the first nearest station (`min(by:)` on
/// meters from the station to `point`), kept only within `max_meters`.
#[must_use]
pub fn nearest_within(point: Point, max_meters: f64, stations: &[Point]) -> Option<usize> {
    let mut best: Option<(usize, f64)> = None;
    for (i, &s) in stations.iter().enumerate() {
        let d = meters(s.0, s.1, point.0, point.1);
        // `min(by:)`: a later station replaces the best only when strictly
        // nearer, so a NaN distance never takes the lead from a number.
        let replaces = match best {
            None => true,
            Some((_, bd)) => d < bd,
        };
        if replaces {
            best = Some((i, d));
        }
    }
    best.and_then(|(i, d)| (d <= max_meters).then_some(i))
}

// ============================================================ BreadcrumbTrail

/// A crumb is kept only this far from the last one, meters.
pub const MIN_STEP_METERS: f64 = 25.0;
/// Crumbs the trail keeps (about 150 km of 25 m steps).
pub const MAX_POINTS: usize = 6_000;

/// `BreadcrumbTrail.shouldRecord`: a finite fix away from (0, 0), and at
/// least [`MIN_STEP_METERS`] from the last crumb when there is one.
#[must_use]
pub fn should_record(c: Point, last: Option<Point>) -> bool {
    if !(c.0.is_finite() && c.1.is_finite() && (c.0.abs() > 0.0001 || c.1.abs() > 0.0001)) {
        return false;
    }
    last.is_none_or(|l| meters(l.0, l.1, c.0, c.1) >= MIN_STEP_METERS)
}

/// `wayBack().meters`: the trail walked newest first, hop by hop.
#[must_use]
pub fn way_back_meters(oldest_first: &[Point]) -> f64 {
    let mut total = 0.0;
    for w in oldest_first.windows(2).rev() {
        total += meters(w[1].0, w[1].1, w[0].0, w[0].1);
    }
    total
}

// ============================================================ AirTravel

/// Below this trip length flying cannot beat the road, miles.
pub const MIN_TRIP_MILES: f64 = 100.0;
/// Airports closer than this leave no flight worth taking, miles.
pub const MIN_AIRPORT_GAP_MILES: f64 = 60.0;
/// Arrive this early, seconds.
pub const BOARD_BUFFER_SECONDS: f64 = 5_400.0;
/// Deplane, bags and exit, seconds.
pub const ALIGHT_BUFFER_SECONDS: f64 = 1_800.0;

/// `AirTravel.worthFlying`.
#[must_use]
pub fn worth_flying(trip_miles: f64) -> bool {
    trip_miles >= MIN_TRIP_MILES
}

/// `AirTravel.flightSeconds`: 45 minutes of taxi, climb and descent plus
/// cruise at 460 mph; 0 for no positive distance.
#[must_use]
pub fn flight_seconds(airport_miles: f64) -> f64 {
    if airport_miles > 0.0 {
        2_700.0 + airport_miles / 460.0 * 3_600.0
    } else {
        0.0
    }
}

/// `AirTravel.doorSeconds`: early arrival, the flight, then bags and exit.
#[must_use]
pub fn door_seconds(airport_miles: f64) -> f64 {
    BOARD_BUFFER_SECONDS + flight_seconds(airport_miles) + ALIGHT_BUFFER_SECONDS
}

/// `AirTravel.fareEstimate`: $39 plus 11¢ a mile, at least $59.
#[must_use]
pub fn fare_estimate(airport_miles: f64) -> f64 {
    smax(59.0, 39.0 + airport_miles * 0.11)
}

/// `AirTravel.airportScore`: `None` for heliports, strips and military
/// fields; 0 for "international", 1 for "airport", else 2 — by substring of
/// the lowercased name.
#[must_use]
pub fn airport_score(name: &str) -> Option<i64> {
    const REJECT: [&str; 13] = [
        "heliport",
        "helipad",
        "seaplane",
        "airstrip",
        "airpark",
        "air park",
        "air force",
        "afb",
        "air base",
        "naval",
        "army",
        "airfield",
        "balloonport",
    ];
    let lower = st::lowercased(name);
    if REJECT.iter().any(|w| st::contains(&lower, w)) {
        return None;
    }
    if st::contains(&lower, "international") {
        return Some(0);
    }
    if st::contains(&lower, "airport") {
        return Some(1);
    }
    Some(2)
}

/// `AirTravel.pickIndex`: among candidates within `max_meters` that the name
/// does not reject, the lowest score, then the nearest (`min(by:)`, first
/// winner). `candidates` are (name, meters).
#[must_use]
pub fn pick_airport(candidates: &[(&str, f64)], max_meters: f64) -> Option<usize> {
    let mut best: Option<(usize, i64, f64)> = None;
    for (i, &(name, m)) in candidates.iter().enumerate() {
        let Some(score) = airport_score(name).filter(|_| m <= max_meters) else {
            continue;
        };
        let replaces = match best {
            None => true,
            Some((_, bs, bm)) => {
                if score != bs {
                    score < bs
                } else {
                    m < bm
                }
            }
        };
        if replaces {
            best = Some((i, score, m));
        }
    }
    best.map(|(i, _, _)| i)
}

// ============================================================ TrafficCadence

/// Traffic checks in the rush windows, seconds.
pub const PEAK_SECONDS: f64 = 240.0;
/// Traffic checks otherwise, seconds.
pub const OFF_PEAK_SECONDS: f64 = 720.0;
/// Seconds from 1970 to Foundation's reference date.
const REFERENCE_TO_1970: f64 = 978_307_200.0;

/// `TrafficCadence.isPeak`: 7–9, 11:30–13, 14:30–16 and 16:30–18:30 local.
#[must_use]
pub fn is_peak(local_minutes: i64) -> bool {
    (420..540).contains(&local_minutes)
        || (690..780).contains(&local_minutes)
        || (870..960).contains(&local_minutes)
        || (990..1_110).contains(&local_minutes)
}

/// `TrafficCadence.localMinutes`: minutes into the solar day at a longitude
/// (15° an hour), for an instant given as seconds since Foundation's
/// reference date. `None` where the Swift trapped (the minutes are not a
/// number).
#[must_use]
pub fn local_minutes(reference_seconds: f64, longitude: f64) -> Option<i64> {
    let utc = (reference_seconds + REFERENCE_TO_1970) % 86_400.0;
    let offset = longitude / 15.0 * 3_600.0;
    let mut local = (utc + offset) % 86_400.0;
    if local < 0.0 {
        local += 86_400.0;
    }
    swift_int(local / 60.0)
}

/// `TrafficCadence.intervalSeconds`; `None` where the Swift trapped.
#[must_use]
pub fn traffic_interval_seconds(reference_seconds: f64, longitude: f64) -> Option<f64> {
    let m = local_minutes(reference_seconds, longitude)?;
    Some(if is_peak(m) {
        PEAK_SECONDS
    } else {
        OFF_PEAK_SECONDS
    })
}

// ============================================================ RiskBlob

/// `RiskBlob.clusters`: grow a cluster from the last remaining point,
/// taking every remaining point within `adjacency_meters` of each member in
/// turn; the answer is the points' indices, in the Swift's cluster order.
#[must_use]
pub fn risk_clusters(points: &[Point], adjacency_meters: f64) -> Vec<Vec<usize>> {
    let mut remaining: Vec<(usize, Point)> = points.iter().copied().enumerate().collect();
    let mut out = Vec::new();
    while let Some(seed) = remaining.pop() {
        let mut cluster = vec![seed.0];
        let mut frontier = vec![seed];
        while let Some((_, p)) = frontier.pop() {
            let near: Vec<usize> = remaining
                .iter()
                .enumerate()
                .filter(|(_, (_, q))| meters(q.0, q.1, p.0, p.1) <= adjacency_meters)
                .map(|(offset, _)| offset)
                .collect();
            for &offset in near.iter().rev() {
                let q = remaining.remove(offset);
                cluster.push(q.0);
                frontier.push(q);
            }
        }
        out.push(cluster);
    }
    out
}

/// `RiskBlob.hull`: the monotone-chain convex hull padded outward from its
/// centroid by `pad_meters`; one or two points (or none) outline a diamond
/// around their centroid.
#[must_use]
pub fn risk_hull(points: &[Point], pad_meters: f64) -> Vec<Point> {
    let pad = pad_meters / 111_320.0;
    if points.len() <= 2 {
        let n = points.len().max(1) as f64;
        let lat = points.iter().fold(0.0, |a, p| a + p.0) / n;
        let lon = points.iter().fold(0.0, |a, p| a + p.1) / n;
        return vec![
            (lat + pad, lon),
            (lat, lon + pad * 1.4),
            (lat - pad, lon),
            (lat, lon - pad * 1.4),
        ];
    }
    let mut order: Vec<usize> = (0..points.len()).collect();
    swift_sort_by(&mut order, |a, b| {
        let (pa, pb) = (points[a], points[b]);
        if pa.1 != pb.1 {
            pa.1 < pb.1
        } else {
            pa.0 < pb.0
        }
    });
    let sorted: Vec<Point> = order.into_iter().map(|i| points[i]).collect();
    let cross =
        |o: Point, a: Point, b: Point| (a.1 - o.1) * (b.0 - o.0) - (a.0 - o.0) * (b.1 - o.1);
    let chain = |seq: &mut dyn Iterator<Item = Point>| {
        let mut hull: Vec<Point> = Vec::new();
        for p in seq {
            while hull.len() >= 2 && cross(hull[hull.len() - 2], hull[hull.len() - 1], p) <= 0.0 {
                hull.pop();
            }
            hull.push(p);
        }
        hull
    };
    let mut lower = chain(&mut sorted.iter().copied());
    let mut upper = chain(&mut sorted.iter().rev().copied());
    lower.pop();
    upper.pop();
    let ring: Vec<Point> = lower.into_iter().chain(upper).collect();
    let n = ring.len() as f64;
    let c_lat = ring.iter().fold(0.0, |a, p| a + p.0) / n;
    let c_lon = ring.iter().fold(0.0, |a, p| a + p.1) / n;
    ring.into_iter()
        .map(|p| {
            let (d_lat, d_lon) = (p.0 - c_lat, p.1 - c_lon);
            let len = smax((d_lat * d_lat + d_lon * d_lon).sqrt(), 1e-9);
            (p.0 + d_lat / len * pad, p.1 + d_lon / len * pad)
        })
        .collect()
}

// ============================================================ TransitFares

/// A local bus ride.
pub const LOCAL_BUS_FARE: f64 = 2.25;
/// A local rail or subway ride.
pub const LOCAL_RAIL_FARE: f64 = 2.75;

/// `TransitFares.amtrak`: 15¢ a mile, at least $15.
#[must_use]
pub fn amtrak_fare(miles: f64) -> f64 {
    smax(15.0, miles * 0.15)
}

/// `TransitFares.greyhound`: 12¢ a mile, at least $12.
#[must_use]
pub fn greyhound_fare(miles: f64) -> f64 {
    smax(12.0, miles * 0.12)
}

// ============================================================ HybridWalk

/// Rideshare pickup fee.
pub const BASE_FARE_USD: f64 = 3.0;
/// Rideshare rate per mile.
pub const PER_MILE_USD: f64 = 1.10;
/// The walker's wallet cap.
pub const COST_CAP_USD: f64 = 25.0;
/// The ride must cut this fraction of the walk-alone time…
pub const MIN_SAVED_FRACTION: f64 = 0.40;
/// …and at least this many seconds.
pub const MIN_SAVED_SECONDS: f64 = 900.0;
/// Walks shorter than this never get an offer, seconds.
pub const MIN_WALK_ALONE_SECONDS: f64 = 1_800.0;

/// `HybridWalk.rideCostUSD`.
#[must_use]
pub fn ride_cost(miles: f64) -> f64 {
    BASE_FARE_USD + PER_MILE_USD * miles
}

/// `HybridWalk.maxAffordableRideMiles`.
#[must_use]
pub fn max_affordable_ride_miles() -> f64 {
    (COST_CAP_USD - BASE_FARE_USD) / PER_MILE_USD
}

/// `HybridWalk.meetsBar`: affordable, and at least 40% and 15 minutes faster
/// than walking alone.
#[must_use]
pub fn meets_bar(walk_alone_seconds: f64, total_seconds: f64, cost_usd: f64) -> bool {
    if !(cost_usd <= COST_CAP_USD && walk_alone_seconds > 0.0) {
        return false;
    }
    let saved = walk_alone_seconds - total_seconds;
    saved >= MIN_SAVED_SECONDS && saved / walk_alone_seconds >= MIN_SAVED_FRACTION
}

/// A walk-plus-ride offer.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RideOffer {
    /// Miles ridden.
    pub ride_miles: f64,
    /// Seconds riding.
    pub ride_seconds: f64,
    /// Seconds walking after the drop-off.
    pub walk_seconds: f64,
    /// Estimated fare.
    pub cost_usd: f64,
}

/// `HybridWalk.evaluate`: the whole trip by car when the cap affords it,
/// else the first affordable miles with the rest walked (prorated); `None`
/// unless the walk is long enough, the numbers are positive and the offer
/// meets the bar.
#[must_use]
pub fn evaluate_ride(
    walk_alone_seconds: f64,
    drive_seconds: f64,
    trip_miles: f64,
) -> Option<RideOffer> {
    if !(walk_alone_seconds >= MIN_WALK_ALONE_SECONDS && drive_seconds > 0.0 && trip_miles > 0.0) {
        return None;
    }
    let offer = if ride_cost(trip_miles) <= COST_CAP_USD {
        RideOffer {
            ride_miles: trip_miles,
            ride_seconds: drive_seconds,
            walk_seconds: 0.0,
            cost_usd: ride_cost(trip_miles),
        }
    } else {
        let ride_miles = max_affordable_ride_miles();
        let fraction = ride_miles / trip_miles;
        RideOffer {
            ride_miles,
            ride_seconds: drive_seconds * fraction,
            walk_seconds: walk_alone_seconds * (1.0 - fraction),
            cost_usd: ride_cost(ride_miles),
        }
    };
    meets_bar(
        walk_alone_seconds,
        offer.ride_seconds + offer.walk_seconds,
        offer.cost_usd,
    )
    .then_some(offer)
}

/// `HybridWalk.prefixCoordinates`: the first `meters` of a line, the last
/// point interpolated between the vertices that straddle the mark; the whole
/// line when it is shorter; the first point alone for a line under two
/// points or a mark that is not positive.
#[must_use]
pub fn prefix_coordinates(coords: &[Point], meters_mark: f64) -> Vec<Point> {
    let measurable = coords.len() >= 2 && meters_mark > 0.0;
    if !measurable {
        return coords.first().map(|&c| vec![c]).unwrap_or_default();
    }
    let mut out = vec![coords[0]];
    let mut travelled = 0.0;
    for i in 1..coords.len() {
        let (a, b) = (coords[i - 1], coords[i]);
        let span = meters(a.0, a.1, b.0, b.1);
        if travelled + span >= meters_mark && span > 0.0 {
            let f = (meters_mark - travelled) / span;
            out.push((a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f));
            return out;
        }
        travelled += span;
        out.push(b);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stations_trail_and_flights() {
        let stations = [(43.07, -89.4), (41.88, -87.63)];
        assert_eq!(nearest_within((43.0, -89.4), 50_000.0, &stations), Some(0));
        assert_eq!(nearest_within((43.0, -89.4), 1_000.0, &stations), None);
        assert!(should_record((43.0, -89.0), None));
        assert!(!should_record((0.00005, 0.00005), None));
        assert!(!should_record((43.0, -89.0), Some((43.0001, -89.0))));
        let trail = [(43.0, -89.0), (43.001, -89.0), (43.002, -89.0)];
        assert!((way_back_meters(&trail) - 222.64).abs() < 0.1);
        assert_eq!(flight_seconds(0.0), 0.0);
        assert_eq!(door_seconds(460.0), 5_400.0 + 2_700.0 + 3_600.0 + 1_800.0);
        assert_eq!(fare_estimate(10.0), 59.0);
        assert_eq!(airport_score("Truax Field AFB"), None);
        assert_eq!(airport_score("O'Hare International"), Some(0));
        assert_eq!(
            pick_airport(
                &[("Regional Field", 1_000.0), ("Mitchell Airport", 9_000.0)],
                50_000.0
            ),
            Some(1)
        );
    }

    #[test]
    fn cadence_blobs_fares_and_rides() {
        assert!(is_peak(480));
        assert!(!is_peak(540));
        assert_eq!(local_minutes(-978_307_200.0, 0.0), Some(0));
        assert_eq!(local_minutes(0.0, f64::NAN), None);
        let pts = [(43.0, -89.0), (43.01, -89.0), (45.0, -89.0)];
        assert_eq!(risk_clusters(&pts, 5_000.0), vec![vec![2], vec![1, 0]]);
        assert_eq!(risk_hull(&[], 1_000.0).len(), 4);
        assert_eq!(
            risk_hull(&[(0.0, 0.0), (0.0, 1.0), (1.0, 0.0), (0.2, 0.2)], 0.0).len(),
            3
        );
        assert_eq!(amtrak_fare(10.0), 15.0);
        assert!((max_affordable_ride_miles() - 20.0).abs() < 1e-12);
        assert!(evaluate_ride(3_600.0, 600.0, 5.0).is_some());
        assert!(evaluate_ride(1_000.0, 600.0, 5.0).is_none());
        let line = [(43.0, -89.0), (43.01, -89.0)];
        assert_eq!(prefix_coordinates(&line, 0.0), vec![(43.0, -89.0)]);
        assert_eq!(prefix_coordinates(&line, 1e9), line.to_vec());
        assert_eq!(prefix_coordinates(&line, 556.6).len(), 2);
    }
}
