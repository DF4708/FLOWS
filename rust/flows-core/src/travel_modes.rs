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
//! their facade switch. The ride estimates (`TransitPlanning`) followed from
//! `TransitItinerary.swift` at commit c206b98, pinned with the recents and
//! rentals by `swift_recents_and_rides_oracle.tsv`.
//!
//! | here | Swift |
//! |---|---|
//! | [`nearest_within`] | `AmtrakStations.nearest(to:within:in:)` |
//! | [`should_record`], [`way_back_meters`] | `BreadcrumbTrail.shouldRecord`, `wayBack().meters` |
//! | [`worth_flying`], [`flight_seconds`], [`door_seconds`], [`fare_estimate`], [`airport_score`], [`pick_airport`] | `AirTravel` |
//! | [`is_peak`], [`local_minutes`], [`traffic_interval_seconds`] | `TrafficCadence` |
//! | [`risk_clusters`], [`risk_hull`] | `RiskBlob.clusters`, `.hull` |
//! | [`amtrak_fare`], [`greyhound_fare`], [`LOCAL_BUS_FARE`], [`LOCAL_RAIL_FARE`] | `TransitFares` |
//! | [`ride_multiplier`], [`fallback_mph`], [`ride_duration`] | `TransitPlanning` |
//! | [`ride_cost`], [`meets_bar`], [`evaluate_ride`], [`prefix_coordinates`] | `HybridWalk` |
//! | [`keeps_road_choice`], [`faster_saves_enough`], [`faster_risk_verdict`], [`off_line_spans`], [`diverge_along`], [`detour_check_spacing`], [`spans_checked`], [`nearest_on_line`] | new: `FasterRoutePolicy` (taking a faster route on the driver's behalf) |
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
use crate::risk::{risk_band, RiskBand};
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

// ======================================================== faster route

// Not ports: the rules for taking a faster route on the driver's behalf
// (owner, 2026-09-21: "Faster route navigation should automatically be
// approved unless it increases the route risk level").

/// `RoutePlanKind` codes.
pub const PLAN_STANDARD: u8 = 0;
/// The local-roads (avoid-highways) plan.
pub const PLAN_AVOID_HIGHWAYS: u8 = 1;
/// The toll-free plan.
pub const PLAN_TOLL_FREE: u8 = 2;

/// The faster road is taken.
pub const FASTER_SWITCH: u8 = 0;
/// The faster road is riskier: the driver is asked instead.
pub const FASTER_RISKIER: u8 = 1;
/// The risk can't be told: the driver is asked instead.
pub const FASTER_UNKNOWN: u8 = 2;

/// Whether a candidate keeps the driver's own road choices: the No tolls and
/// No highways filters, the leg's toll-free or local-roads plan, and — for a
/// leg with no tolls — no tolls (a driver who picked the card without a toll
/// badge chose that, filter or not). A person approving each switch could
/// catch a toll road; a switch made on their behalf must not bring one back.
#[must_use]
pub fn keeps_road_choice(
    leg_kind: u8,
    leg_has_tolls: bool,
    candidate_kind: u8,
    candidate_has_tolls: bool,
    candidate_has_highways: bool,
    no_tolls: bool,
    no_highways: bool,
) -> bool {
    let tolls_refused = no_tolls || leg_kind == PLAN_TOLL_FREE || !leg_has_tolls;
    let highways_refused =
        no_highways || (leg_kind == PLAN_AVOID_HIGHWAYS && candidate_kind != PLAN_AVOID_HIGHWAYS);
    !(tolls_refused && candidate_has_tolls || highways_refused && candidate_has_highways)
}

/// Whether a candidate saves at least `tolerance_seconds` (all finite).
#[must_use]
pub fn faster_saves_enough(
    current_seconds: f64,
    candidate_seconds: f64,
    tolerance_seconds: f64,
) -> bool {
    current_seconds.is_finite()
        && candidate_seconds.is_finite()
        && tolerance_seconds.is_finite()
        && current_seconds - candidate_seconds >= tolerance_seconds
}

/// The risk level a switch compares: the owner counts Clear and Green as one
/// low level (2026-09-21), so only Yellow and Red rise above it.
fn switch_level(risk: f64) -> u8 {
    match risk_band(risk) {
        RiskBand::Red => 2,
        RiskBand::Yellow => 1,
        RiskBand::Green | RiskBand::Transparent => 0,
    }
}

/// Whether a faster road is taken on the driver's behalf: [`FASTER_SWITCH`]
/// unless it is Red or raises the level of the road still ahead
/// ([`FASTER_RISKIER`]). Anything that can't be told is
/// [`FASTER_UNKNOWN`] — never switched: an incomplete score, an unknown
/// road ahead, a value that is not a number, or limits the new road can't
/// be checked against yet (a trailer's bridges and grades).
#[must_use]
pub fn faster_risk_verdict(
    candidate_complete: bool,
    candidate_risk: f64,
    ahead_known: bool,
    ahead_risk: f64,
    limits_unchecked: bool,
) -> u8 {
    if limits_unchecked
        || !candidate_complete
        || !ahead_known
        || !candidate_risk.is_finite()
        || !ahead_risk.is_finite()
    {
        return FASTER_UNKNOWN;
    }
    let candidate = switch_level(candidate_risk);
    if candidate == 2 || candidate > switch_level(ahead_risk) {
        FASTER_RISKIER
    } else {
        FASTER_SWITCH
    }
}

/// Two routes' lines are the same road within this. MapKit draws one road
/// the same way in every answer, so a vertex of one lies on the other's line
/// to within a few metres, while an exit ramp running beside the mainline
/// sits farther off.
pub const SHARED_ROAD_METERS: f64 = 10.0;

/// How many road vertices behind and ahead of the last match
/// [`off_line_spans`] searches, so it walks both lines forward together.
const ROAD_WINDOW_BACK: usize = 8;
const ROAD_WINDOW_AHEAD: usize = 400;

/// Meters from `p` to `line`'s segments starting at vertex indices `lo..hi`
/// (a lone vertex when the line has one), and the first nearest segment's
/// start. `None` for an empty range.
fn line_distance(line: &[Point], p: Point, lo: usize, hi: usize) -> Option<(usize, f64)> {
    if line.is_empty() {
        return None;
    }
    if line.len() == 1 {
        return Some((0, meters(line[0].0, line[0].1, p.0, p.1)));
    }
    let mut best: Option<(usize, f64)> = None;
    for s in lo..hi.min(line.len() - 1) {
        let (a, b) = (line[s], line[s + 1]);
        let d = crate::geo::distance_to_segment_meters(p.0, p.1, a.0, a.1, b.0, b.1);
        if best.is_none_or(|(_, bd)| d < bd) {
            best = Some((s, d));
        }
    }
    best
}

/// The stretches of `candidate` that are off `road`'s line (farther than
/// [`SHARED_ROAD_METERS`]): meters along the candidate from its last vertex
/// on the road before each stretch to its first vertex back on it, or
/// `f64::INFINITY` when it never rejoins. Empty when it never leaves: it is
/// the road itself. The candidate's first vertex (the car's own fix) is not
/// tested. The road is searched in a window around the last match, walking
/// forward with the candidate, so a long route costs its length times the
/// window, not both lengths multiplied.
#[must_use]
pub fn off_line_spans(candidate: &[Point], road: &[Point]) -> Vec<(f64, f64)> {
    let mut spans = Vec::new();
    if candidate.len() < 2 || road.is_empty() {
        return spans;
    }
    let Some((mut j, _)) = line_distance(road, candidate[1], 0, road.len()) else {
        return spans;
    };
    let mut along = 0.0;
    let mut last_on = 0.0;
    let mut off_from: Option<f64> = None;
    for i in 1..candidate.len() {
        let (a, b) = (candidate[i - 1], candidate[i]);
        along += meters(a.0, a.1, b.0, b.1);
        let lo = j.saturating_sub(ROAD_WINDOW_BACK);
        let hi = j.saturating_add(ROAD_WINDOW_AHEAD);
        let hit = line_distance(road, b, lo, hi);
        // A distance that is not a number is off the road.
        let on = matches!(hit, Some((_, d)) if d <= SHARED_ROAD_METERS);
        if let Some((k, _)) = hit {
            j = k;
        }
        if on {
            if let Some(from) = off_from.take() {
                spans.push((from, along));
            }
            last_on = along;
        } else if off_from.is_none() {
            off_from = Some(last_on);
        }
    }
    if let Some(from) = off_from {
        spans.push((from, f64::INFINITY));
    }
    spans
}

/// Where `candidate` leaves `road`: meters along the candidate to its last
/// vertex on the road's line before the first of its [`off_line_spans`].
/// `None` when it never leaves.
#[must_use]
pub fn diverge_along(candidate: &[Point], road: &[Point]) -> Option<f64> {
    off_line_spans(candidate, road)
        .first()
        .map(|&(from, _)| from)
}

/// The spacing FLOWS scores a road's check points at.
pub const CORRIDOR_CHECK_METERS: f64 = 40_000.0;
/// The closest check points a detour is scored at.
pub const DETOUR_CHECK_MIN_METERS: f64 = 2_000.0;
/// The most stretches a road weighed for a switch is cut into. With its two
/// ends that is at most 30 check points, and the scorer fetches a forecast
/// at every other one of the first 30 (`corridorForecasts` in the app): each
/// check point stays within reach of one. With more, the far ones (a detour
/// 100 km ahead) were weighed without their forecast.
pub const DETOUR_CHECK_POINTS_MAX: f64 = 28.0;

/// The check-point spacing for weighing a faster road whose stretches off
/// the current road are `spans` (see [`off_line_spans`]), on a candidate
/// `candidate_meters` long: a third of the shortest stretch (so each gets
/// check points of its own), from [`DETOUR_CHECK_MIN_METERS`] up to the
/// usual [`CORRIDOR_CHECK_METERS`], and never more than
/// [`DETOUR_CHECK_POINTS_MAX`] stretches. A road checked only every 40 km has
/// no check point on a 10 km detour: the two roads would be compared on the
/// points they share. The usual spacing when nothing can be told.
#[must_use]
pub fn detour_check_spacing(spans: &[(f64, f64)], candidate_meters: f64) -> f64 {
    let shortest = spans
        .iter()
        .map(|&(from, to)| to.min(candidate_meters) - from)
        .filter(|m| m.is_finite() && *m > 0.0)
        .fold(f64::INFINITY, f64::min);
    if !shortest.is_finite() || !candidate_meters.is_finite() || candidate_meters <= 0.0 {
        return CORRIDOR_CHECK_METERS;
    }
    (shortest / 3.0)
        .max(DETOUR_CHECK_MIN_METERS)
        .max(candidate_meters / DETOUR_CHECK_POINTS_MAX)
        .min(CORRIDOR_CHECK_METERS)
}

/// Whether every stretch in `spans` has a check point inside it, the check
/// points sitting `check_alongs` meters along the candidate (the first, at
/// the car, is not one: it is where the car already is). A stretch that
/// never rejoins runs to the end. When one has none, the stretch that makes
/// the roads differ was never looked at: FLOWS asks instead of switching.
/// A check point within [`SPAN_END_SLACK_METERS`] of a stretch's end is its
/// turn-off or rejoin vertex, on the road: the positions come from adding
/// stretch lengths, the ends from one running sum, and the two can differ
/// in the last bits.
#[must_use]
pub fn spans_checked(spans: &[(f64, f64)], check_alongs: &[f64]) -> bool {
    spans.iter().all(|&(from, to)| {
        check_alongs
            .iter()
            .skip(1)
            .any(|&a| a > from + SPAN_END_SLACK_METERS && a < to - SPAN_END_SLACK_METERS)
    })
}

/// How close to a detour's end a check point is taken for the end itself.
pub const SPAN_END_SLACK_METERS: f64 = 1.0;

/// Where `p` sits on `line`: meters along the line to the nearest point on
/// its nearest segment, and meters off it. `None` for an empty line.
#[must_use]
pub fn nearest_on_line(line: &[Point], p: Point) -> Option<(f64, f64)> {
    let (s, off) = line_distance(line, p, 0, line.len())?;
    let mut along = 0.0;
    for w in line[..=s].windows(2) {
        along += meters(w[0].0, w[0].1, w[1].0, w[1].1);
    }
    // The foot of the perpendicular, along the segment from its start.
    let to_start = meters(line[s].0, line[s].1, p.0, p.1);
    let into = (to_start * to_start - off * off).max(0.0).sqrt();
    Some((along + if into.is_finite() { into } else { 0.0 }, off))
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

// ============================================================ TransitPlanning

/// `TransitPlanning.rideMultiplier`: a scheduled service's door-to-door
/// overhead over driving the same corridor alone (station dwell, stops,
/// transfers). Long-haul US rail, transfer-heavy, rides slower than a coach.
#[must_use]
pub fn ride_multiplier(mode: &str) -> f64 {
    if st::eq(mode, "Amtrak") {
        1.45
    } else if st::eq(mode, "Greyhound") {
        1.35
    } else if st::eq(mode, "Rail") {
        1.30
    } else {
        2.00
    }
}

/// `TransitPlanning.fallbackMPH`: the effective speed when no drivable base
/// time exists, in the same order as [`ride_multiplier`] so which mode is
/// slower never flips between the two paths.
#[must_use]
pub fn fallback_mph(mode: &str) -> f64 {
    if st::eq(mode, "Amtrak") {
        40.0
    } else if st::eq(mode, "Greyhound") {
        44.0
    } else if st::eq(mode, "Rail") {
        22.0
    } else {
        12.0
    }
}

/// `TransitPlanning.rideDuration`: a real drive time scaled by the mode's
/// overhead; otherwise distance over the fallback speed; 0 when neither is
/// known.
#[must_use]
pub fn ride_duration(mode: &str, drive_seconds: Option<f64>, miles: f64) -> f64 {
    if let Some(drive) = drive_seconds.filter(|&d| d > 0.0) {
        return drive * ride_multiplier(mode);
    }
    let mph = fallback_mph(mode);
    if mph > 0.0 && miles > 0.0 {
        miles / mph * 3600.0
    } else {
        0.0
    }
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

    // ---- faster route ----

    #[test]
    fn the_drivers_road_choices_are_kept() {
        // (leg kind, leg has tolls) → (candidate kind, tolls, highways)
        // under (No tolls, No highways).
        let keeps = |leg: u8,
                     leg_tolls: bool,
                     cand: u8,
                     tolls: bool,
                     highways: bool,
                     no_tolls: bool,
                     no_highways: bool| {
            keeps_road_choice(leg, leg_tolls, cand, tolls, highways, no_tolls, no_highways)
        };
        // No tolls on: a toll road is refused, a free one kept.
        assert!(!keeps(
            PLAN_STANDARD,
            true,
            PLAN_STANDARD,
            true,
            true,
            true,
            false
        ));
        assert!(keeps(
            PLAN_STANDARD,
            true,
            PLAN_STANDARD,
            false,
            true,
            true,
            false
        ));
        // No highways on.
        assert!(!keeps(
            PLAN_STANDARD,
            true,
            PLAN_AVOID_HIGHWAYS,
            false,
            true,
            false,
            true
        ));
        // A toll-free leg never takes a toll road.
        assert!(!keeps(
            PLAN_TOLL_FREE,
            false,
            PLAN_STANDARD,
            true,
            true,
            false,
            false
        ));
        assert!(keeps(
            PLAN_TOLL_FREE,
            false,
            PLAN_STANDARD,
            false,
            true,
            false,
            false
        ));
        // A leg with no tolls, picked without the filter: still no toll road.
        assert!(!keeps(
            PLAN_STANDARD,
            false,
            PLAN_STANDARD,
            true,
            true,
            false,
            false
        ));
        assert!(keeps(
            PLAN_STANDARD,
            false,
            PLAN_STANDARD,
            false,
            true,
            false,
            false
        ));
        // A local-roads leg keeps local roads: another local-roads plan may
        // touch a highway, a standard one may not.
        assert!(keeps(
            PLAN_AVOID_HIGHWAYS,
            true,
            PLAN_AVOID_HIGHWAYS,
            false,
            true,
            false,
            false
        ));
        assert!(!keeps(
            PLAN_AVOID_HIGHWAYS,
            true,
            PLAN_STANDARD,
            false,
            true,
            false,
            false
        ));
        assert!(keeps(
            PLAN_AVOID_HIGHWAYS,
            true,
            PLAN_STANDARD,
            false,
            false,
            false,
            false
        ));
        // A standard leg that has tolls, with no filters, takes anything.
        assert!(keeps(
            PLAN_STANDARD,
            true,
            PLAN_STANDARD,
            true,
            true,
            false,
            false
        ));
    }

    #[test]
    fn a_switch_must_save_the_tolerance() {
        assert!(faster_saves_enough(3_600.0, 3_000.0, 600.0));
        assert!(!faster_saves_enough(3_600.0, 3_100.0, 600.0));
        assert!(!faster_saves_enough(f64::NAN, 3_000.0, 600.0));
        assert!(!faster_saves_enough(3_600.0, 3_000.0, f64::INFINITY));
    }

    #[test]
    fn clear_and_green_are_one_level() {
        // Clear ahead, Green candidate: taken (owner, 2026-09-21).
        assert_eq!(
            faster_risk_verdict(true, 0.5, true, 0.1, false),
            FASTER_SWITCH
        );
        // Green ahead, Clear candidate: taken.
        assert_eq!(
            faster_risk_verdict(true, 0.1, true, 0.5, false),
            FASTER_SWITCH
        );
        // Yellow candidate over a Green road ahead: asked.
        assert_eq!(
            faster_risk_verdict(true, 0.75, true, 0.5, false),
            FASTER_RISKIER
        );
        // Yellow over Yellow: taken.
        assert_eq!(
            faster_risk_verdict(true, 0.75, true, 0.8, false),
            FASTER_SWITCH
        );
        // Red is always asked, even over a Red road ahead.
        assert_eq!(
            faster_risk_verdict(true, 0.9, true, 0.95, false),
            FASTER_RISKIER
        );
    }

    #[test]
    fn anything_unknown_is_asked_never_switched() {
        assert_eq!(
            faster_risk_verdict(false, 0.1, true, 0.1, false),
            FASTER_UNKNOWN
        );
        assert_eq!(
            faster_risk_verdict(true, 0.1, false, 0.1, false),
            FASTER_UNKNOWN
        );
        assert_eq!(
            faster_risk_verdict(true, 0.1, true, 0.1, true),
            FASTER_UNKNOWN
        );
        assert_eq!(
            faster_risk_verdict(true, f64::NAN, true, 0.1, false),
            FASTER_UNKNOWN
        );
        assert_eq!(
            faster_risk_verdict(true, 0.1, true, f64::NAN, false),
            FASTER_UNKNOWN
        );
    }

    /// Points `step` metres apart heading north from `lat0` on `lon`.
    fn north(lat0: f64, lon: f64, count: usize, step: f64) -> Vec<Point> {
        (0..count)
            .map(|i| (lat0 + i as f64 * step / 111_320.0, lon))
            .collect()
    }

    #[test]
    fn a_road_that_follows_the_line_never_leaves_it() {
        let road = north(43.0, -89.4, 51, 100.0);
        assert_eq!(diverge_along(&road, &road), None);
        // Sparse vertices on the same straight line still lie on it.
        let sparse = north(43.0, -89.4, 6, 1_000.0);
        assert_eq!(diverge_along(&sparse, &road), None);
    }

    #[test]
    fn the_turn_off_is_the_last_vertex_on_the_road() {
        let road = north(43.0, -89.4, 51, 100.0);
        // 2 km on the road, then 20 m to the side (a ramp beside it), then away.
        let mut candidate = north(43.0, -89.4, 21, 100.0);
        let last = *candidate.last().unwrap();
        candidate.push((last.0 + 100.0 / 111_320.0, -89.4 + 20.0 / 81_400.0));
        candidate.push((last.0 + 200.0 / 111_320.0, -89.4 + 300.0 / 81_400.0));
        let at = diverge_along(&candidate, &road).unwrap();
        assert!((at - 2_000.0).abs() < 5.0, "{at}");
    }

    #[test]
    fn the_first_vertex_is_the_cars_fix_and_is_not_tested() {
        let road = north(43.0, -89.4, 51, 100.0);
        // The fix is 30 m off the road (GPS error); the rest follows it.
        let mut candidate = north(43.0, -89.4, 20, 100.0);
        candidate[0].1 += 30.0 / 81_400.0;
        assert_eq!(diverge_along(&candidate, &road), None);
        assert_eq!(diverge_along(&candidate[..1], &road), None);
        assert_eq!(diverge_along(&candidate, &[]), None);
    }

    /// Points `step` metres apart heading east from `(lat, lon0)`.
    fn east(lat: f64, lon0: f64, count: usize, step: f64) -> Vec<Point> {
        (0..count)
            .map(|i| (lat, lon0 + i as f64 * step / 81_400.0))
            .collect()
    }

    #[test]
    fn a_detour_is_the_stretch_between_leaving_and_rejoining() {
        // The road runs 10 km north. The candidate follows it 2 km, swings
        // 500 m east, runs 3 km north beside it, and comes back at 5 km.
        let road = north(43.0, -89.4, 101, 100.0);
        let mut candidate = north(43.0, -89.4, 21, 100.0);
        let side = -89.4 + 500.0 / 81_400.0;
        candidate.extend(north(43.0 + 2_000.0 / 111_320.0, side, 31, 100.0));
        candidate.extend(north(43.0 + 5_000.0 / 111_320.0, -89.4, 51, 100.0));
        let spans = off_line_spans(&candidate, &road);
        assert_eq!(spans.len(), 1, "{spans:?}");
        let (from, to) = spans[0];
        // Leaves at 2 km; the swing out and back adds 1 km to the 5 km north.
        assert!((from - 2_000.0).abs() < 5.0, "{from}");
        assert!((to - 6_000.0).abs() < 20.0, "{to}");
        assert_eq!(diverge_along(&candidate, &road), Some(from));
        // The road itself never leaves.
        assert!(off_line_spans(&road, &road).is_empty());
    }

    #[test]
    fn a_detour_that_never_rejoins_runs_to_the_end() {
        let road = north(43.0, -89.4, 51, 100.0);
        let mut candidate = north(43.0, -89.4, 11, 100.0);
        candidate.extend(east(
            43.0 + 1_000.0 / 111_320.0,
            -89.4 + 100.0 / 81_400.0,
            20,
            100.0,
        ));
        let spans = off_line_spans(&candidate, &road);
        assert_eq!(spans.len(), 1);
        assert!((spans[0].0 - 1_000.0).abs() < 5.0);
        assert_eq!(spans[0].1, f64::INFINITY);
        assert!(off_line_spans(&candidate[..1], &road).is_empty());
        assert!(off_line_spans(&candidate, &[]).is_empty());
    }

    #[test]
    fn a_short_detour_gets_check_points_of_its_own() {
        // A 10 km detour on a 25 km road: every 3.3 km, not every 40.
        let s = detour_check_spacing(&[(5_000.0, 15_000.0)], 25_000.0);
        assert!((s - 10_000.0 / 3.0).abs() < 1e-9, "{s}");
        // Never closer than 2 km, never more than 28 stretches, never wider
        // than the usual 40 km.
        assert_eq!(detour_check_spacing(&[(0.0, 900.0)], 25_000.0), 2_000.0);
        let long = detour_check_spacing(&[(0.0, 6_000.0)], 600_000.0);
        assert!((long - 600_000.0 / 28.0).abs() < 1e-9, "{long}");
        assert_eq!(
            detour_check_spacing(&[(0.0, 500_000.0)], 600_000.0),
            40_000.0
        );
        // The shortest stretch sets it; one that never rejoins ends at the end.
        let two = [(1_000.0, 31_000.0), (40_000.0, f64::INFINITY)];
        assert_eq!(detour_check_spacing(&two, 46_000.0), 2_000.0);
        // Nothing to tell: the usual spacing.
        assert_eq!(detour_check_spacing(&[], 25_000.0), CORRIDOR_CHECK_METERS);
        assert_eq!(
            detour_check_spacing(&[(0.0, 1.0)], f64::NAN),
            CORRIDOR_CHECK_METERS
        );
    }

    #[test]
    fn a_switch_needs_a_check_point_on_every_detour() {
        let spans = [(2_000.0, 12_000.0), (30_000.0, f64::INFINITY)];
        assert!(spans_checked(&spans, &[0.0, 5_000.0, 40_000.0]));
        // Nothing on the first detour: the check point at the car doesn't
        // count, nor one exactly where the road rejoins.
        assert!(!spans_checked(&spans, &[0.0, 12_000.0, 40_000.0]));
        assert!(!spans_checked(&[(0.0, 10_000.0)], &[5_000.0]));
        // Nor one a hair inside either end: the turn-off or rejoin vertex,
        // its position added up another way.
        let ends = [(2_000.0, 12_000.0)];
        assert!(!spans_checked(&ends, &[0.0, 12_000.0 - 1e-9]));
        assert!(!spans_checked(&ends, &[0.0, 2_000.0 + 1e-9]));
        assert!(spans_checked(&ends, &[0.0, 2_002.0]));
        // One that never rejoins counts the last check point, at the end.
        assert!(spans_checked(
            &[(30_000.0, f64::INFINITY)],
            &[0.0, 31_000.0]
        ));
        assert!(spans_checked(&[], &[0.0]));
    }

    #[test]
    fn a_point_is_placed_along_the_line() {
        let line = north(43.0, -89.4, 11, 100.0);
        // 250 m along, 20 m to the east.
        let p = (43.0 + 250.0 / 111_320.0, -89.4 + 20.0 / 81_400.0);
        let (along, off) = nearest_on_line(&line, p).unwrap();
        assert!((along - 250.0).abs() < 2.0, "{along}");
        assert!((off - 20.0).abs() < 2.0, "{off}");
        assert_eq!(nearest_on_line(&[], p), None);
    }

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
