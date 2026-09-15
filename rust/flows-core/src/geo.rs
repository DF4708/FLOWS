// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Geo kernel: the equirectangular distance behind about 90 app call sites, bearing, point-to-segment, heading wraps, first-minimum nearest searches, grid keys.
//!
//! Every item here is the Rust twin of a Swift original at commit
//! `a007de042d12e736fdd86398e1ea54ca31aadc1f`, named in its docs, and every
//! one is pinned bit for bit by the frozen oracle
//! `flows-bridge/tests/fixtures/swift_geo_oracle.tsv`.
//!
//! Nothing in the app calls these yet. `POIRanking.meters` sits in about 90
//! call sites, many inside loops that move in later waves; switching it now
//! would put a language crossing inside each of them. The Swift switches when
//! its compute callers have moved (docs/RUST_SWIFT_MIGRATION.md, plan of
//! record, wave 1).
//!
//! # Swift semantics, kept exactly
//!
//! - **Operation order.** Each expression is the Swift's, term for term.
//!   `(a + b) * PI / 360` means `((a + b) * PI) / 360`: no folded constant, no
//!   reordering. Neither compiler fuses `a * b + c` into a multiply-add.
//! - **libm.** `sin`, `cos` and `atan2` are the platform's. On Apple targets
//!   the Swift calls and these calls resolve to the same libSystem functions;
//!   the oracle is what proves it. `sqrt`, `floor` and `%` (C `fmod`) are exact
//!   IEEE operations on every platform.
//! - **min/max.** Swift's generic `min`/`max` through [`crate::fcmp`], never
//!   `f64::min`, `f64::max` or `clamp`.
//! - **First minimum.** Swift's `min(by:)` keeps its first element and
//!   replaces it only when the predicate says a later element is smaller. So
//!   the first of equal minima wins, a NaN in first place is never displaced,
//!   and a later NaN is never taken. Each search states its own tie rule, taken
//!   from its original.
//! - **Traps.** Swift's `Int(Double)` traps on NaN, on infinities and on
//!   values outside `Int64`, and its `Int` arithmetic traps on overflow. The
//!   app crashes there. These twins return `Err(SwiftTrap)` on exactly those
//!   inputs instead of panicking. Swift's `Int` is 64-bit on every Apple target
//!   the app builds for.
//!
//! # Inputs
//!
//! Angles and coordinates are degrees; distances are meters. A list of points
//! arrives as parallel latitude and longitude slices. A point exists for each
//! index present in both slices, so the tail of a longer slice is ignored.
//!
//! Every function is pure and deterministic and none panics: indexing is
//! checked or bounded by construction, and integer arithmetic is checked.

use crate::fcmp::{smax, smin};
use std::collections::BTreeMap;
use std::f64::consts::PI;

/// `sin` and `cos` as their own libm calls, never a fused pair: see
/// [`crate::fmath`] for why the shipping app's bearings can differ from these
/// by one unit in the last place, and the geo oracle for the tolerance that
/// pins it (bearings within one micrometre of lateral displacement at the
/// target; an ahead-cone answer allowed to differ only within a nanodegree of
/// the cone's edge). Measured on one input: fused sine `3fe3bb4b91330e6a`,
/// standalone `3fe3bb4b91330e6b`.
use crate::fmath::{cos as lm_cos, sin as lm_sin};

/// Meters per degree of latitude, and of longitude at the equator, in every
/// equirectangular formula ported here (`111_320.0` in the Swift).
pub const METERS_PER_DEGREE: f64 = 111_320.0;

/// Half-width in degrees of the cone ahead of the direction of travel that
/// counts as "ahead", inclusive: `EnforcementCameras.isAhead`'s literal `100`
/// and `FuelWarning.aheadConeDegrees`. The two agree.
pub const AHEAD_CONE_DEGREES: f64 = 100.0;

/// `FuelWarning.isReachable`'s default corridor, in meters.
pub const FUEL_CORRIDOR_METERS: f64 = 8_000.0;

/// `POIRanking.RoutePath.cellDeg`: the route vertex grid's cell size, degrees.
pub const ROUTE_CELL_DEGREES: f64 = 0.1;

/// `POIRanking.RoutePath.nearest`'s `maxRings`: rings scanned before the full
/// linear scan takes over.
pub const ROUTE_MAX_RINGS: i64 = 16;

/// `ShowerAvailability.LocationTable.cellDeg`: the table's cell size in
/// degrees, and the half-width of its strict match box (`< 0.01`).
pub const SHOWER_CELL_DEGREES: f64 = 0.01;

/// The input made the original Swift trap: an `Int(Double)` of a NaN,
/// infinite or out-of-range value, or an `Int` overflow. The app crashed
/// there; the twin reports it instead. Every function returning this lists the
/// trapping inputs in its docs, and the oracle pins each case against a Swift
/// child process that actually trapped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SwiftTrap;

// ---------------------------------------------------------------------------
// Distance, bearing, segment
// ---------------------------------------------------------------------------

/// `POIRanking.meters(a, b)`: the app-wide short-range distance, in meters,
/// between two points in degrees, by the equirectangular approximation.
///
/// The longitude difference is scaled by the cosine of the mean latitude,
/// `cos((a_lat + b_lat) * PI / 360)`, in that operation order. No input is
/// validated: NaN and infinities propagate as the Swift's do.
///
/// Deterministic; panics: none.
#[must_use]
pub fn meters(a_lat: f64, a_lon: f64, b_lat: f64, b_lon: f64) -> f64 {
    let d_lat = (b_lat - a_lat) * METERS_PER_DEGREE;
    let d_lon = (b_lon - a_lon) * METERS_PER_DEGREE * ((a_lat + b_lat) * PI / 360.0).cos();
    (d_lat * d_lat + d_lon * d_lon).sqrt()
}

/// `EnforcementCameras.bearingDegrees(from: a, to: b)`, and its identical copy
/// `FuelWarning.bearingDegrees`: the initial great-circle compass bearing from
/// `a` to `b`, in degrees.
///
/// A negative `atan2` result has 360 added. The Swift documents `0..<360`, but
/// two edges follow from its arithmetic and are kept: `atan2` returning `-0.0`
/// yields `-0.0`, and a tiny negative angle yields exactly `360.0` after
/// rounding. NaN propagates.
///
/// Deterministic; panics: none.
#[must_use]
pub fn bearing_degrees(a_lat: f64, a_lon: f64, b_lat: f64, b_lon: f64) -> f64 {
    let rad = PI / 180.0;
    let d_lon = (b_lon - a_lon) * rad;
    let y = lm_sin(d_lon) * lm_cos(b_lat * rad);
    let x = lm_cos(a_lat * rad) * lm_sin(b_lat * rad)
        - lm_sin(a_lat * rad) * lm_cos(b_lat * rad) * lm_cos(d_lon);
    let deg = y.atan2(x) / rad;
    if deg < 0.0 {
        deg + 360.0
    } else {
        deg
    }
}

/// The signed angle, in degrees, from a heading to a bearing, wrapped once
/// toward `-180...180`: `(bearing - heading)` truncating-remainder 360, then
/// minus 360 when above 180, then plus 360 when below -180.
///
/// This is the wrap inside both `EnforcementCameras.isAhead` and
/// `FuelWarning.isReachable` (the two are identical). NaN and infinite
/// operands give NaN.
///
/// Deterministic; panics: none.
#[must_use]
pub fn heading_delta_degrees(bearing: f64, heading: f64) -> f64 {
    let mut delta = (bearing - heading) % 360.0;
    if delta > 180.0 {
        delta -= 360.0;
    }
    if delta < -180.0 {
        delta += 360.0;
    }
    delta
}

/// `EnforcementCameras.isAhead(target, from: position, headingDegrees:)`: is
/// the target within [`AHEAD_CONE_DEGREES`] (inclusive) of the heading, seen
/// from the position?
///
/// With no heading, or a heading that is not `>= 0` (negative, or NaN), the
/// answer is `true`: nothing can be ruled out. A NaN bearing or delta answers
/// `false`.
///
/// Deterministic; panics: none.
#[must_use]
pub fn camera_is_ahead(
    target_lat: f64,
    target_lon: f64,
    position_lat: f64,
    position_lon: f64,
    heading_degrees: Option<f64>,
) -> bool {
    match heading_degrees {
        Some(heading) if heading >= 0.0 => {
            let bearing = bearing_degrees(position_lat, position_lon, target_lat, target_lon);
            heading_delta_degrees(bearing, heading).abs() <= AHEAD_CONE_DEGREES
        }
        _ => true,
    }
}

/// `FuelWarning.isReachable(station:from:courseDegrees:routeAhead:corridorMeters:)`:
/// is a station still somewhere the driver can reach?
///
/// - With at least one route point ahead: `true` when any route point is
///   within `corridor_meters` (inclusive) of the station, by [`meters`] from
///   the station to the point.
/// - With no route: `true` when the course is not `>= 0` (negative or NaN);
///   otherwise `true` when the bearing from `here` to the station is within
///   [`AHEAD_CONE_DEGREES`] of the course, inclusive.
///
/// The Swift default corridor is [`FUEL_CORRIDOR_METERS`].
///
/// Deterministic; panics: none.
#[must_use]
#[allow(clippy::too_many_arguments)] // the Swift signature's inputs, flattened to degrees
pub fn fuel_station_is_reachable(
    station_lat: f64,
    station_lon: f64,
    here_lat: f64,
    here_lon: f64,
    course_degrees: f64,
    route_lats: &[f64],
    route_lons: &[f64],
    corridor_meters: f64,
) -> bool {
    let mut route = route_lats.iter().zip(route_lons).peekable();
    if route.peek().is_some() {
        return route
            .any(|(&lat, &lon)| meters(station_lat, station_lon, lat, lon) <= corridor_meters);
    }
    if course_degrees >= 0.0 {
        let bearing = bearing_degrees(here_lat, here_lon, station_lat, station_lon);
        heading_delta_degrees(bearing, course_degrees).abs() <= AHEAD_CONE_DEGREES
    } else {
        true
    }
}

/// `HazardFeedScores.distanceToSegmentMeters(p, a, b)`: meters from `p` to the
/// segment `a`-`b`, in a local equirectangular projection around `p` whose
/// longitude scale is `111_320 * cos(p_lat * PI / 180)`.
///
/// Forwards to [`distance_to_segment_meters_scaled`]. Deterministic; panics:
/// none.
#[must_use]
pub fn distance_to_segment_meters(
    p_lat: f64,
    p_lon: f64,
    a_lat: f64,
    a_lon: f64,
    b_lat: f64,
    b_lon: f64,
) -> f64 {
    distance_to_segment_meters_scaled(
        p_lat,
        p_lon,
        a_lat,
        a_lon,
        b_lat,
        b_lon,
        METERS_PER_DEGREE * lm_cos(p_lat * PI / 180.0),
    )
}

/// `HazardFeedScores.distanceToSegmentMeters(p, a, b, mPerDegLon:)`: the hot
/// loop overload, with the longitude scale (meters per degree) supplied.
///
/// A zero-length segment gives the distance to `a`. Otherwise the projection
/// parameter is clamped as Swift's `max(0, min(1, t))`, so a NaN `t` becomes
/// 1 (the far endpoint), where `f64::clamp` would give NaN.
///
/// Deterministic; panics: none.
#[must_use]
pub fn distance_to_segment_meters_scaled(
    p_lat: f64,
    p_lon: f64,
    a_lat: f64,
    a_lon: f64,
    b_lat: f64,
    b_lon: f64,
    m_per_deg_lon: f64,
) -> f64 {
    let m_per_deg_lat = METERS_PER_DEGREE;
    let ax = (a_lon - p_lon) * m_per_deg_lon;
    let ay = (a_lat - p_lat) * m_per_deg_lat;
    let bx = (b_lon - p_lon) * m_per_deg_lon;
    let by = (b_lat - p_lat) * m_per_deg_lat;
    let dx = bx - ax;
    let dy = by - ay;
    let len2 = dx * dx + dy * dy;
    if len2 == 0.0 {
        return (ax * ax + ay * ay).sqrt();
    }
    let t = smax(0.0, smin(1.0, -(ax * dx + ay * dy) / len2));
    let cx = ax + t * dx;
    let cy = ay + t * dy;
    (cx * cx + cy * cy).sqrt()
}

/// `HybridWalk.prefixCoordinates(coords, meters:)`: the route prefix covering
/// the first `meters_mark` meters, as `(lat, lon)` pairs, ending exactly at the
/// mark.
///
/// - Fewer than two points, or a mark that is not `> 0` (zero, negative,
///   NaN): the first point alone, or nothing for an empty route.
/// - Spans are [`meters`] from each point to the next, accumulated left to
///   right. At the first span with `travelled + span >= mark` and `span > 0`,
///   the last point is interpolated as `a + (b - a) * f` per axis, with
///   `f = (mark - travelled) / span`, and the prefix ends.
/// - A mark past the end returns every point.
///
/// Deterministic; panics: none.
#[must_use]
pub fn prefix_coordinates(lats: &[f64], lons: &[f64], meters_mark: f64) -> Vec<(f64, f64)> {
    let points: Vec<(f64, f64)> = lats.iter().copied().zip(lons.iter().copied()).collect();
    let Some(&first) = points.first() else {
        return Vec::new();
    };
    let mark_is_positive = meters_mark > 0.0;
    if points.len() < 2 || !mark_is_positive {
        return vec![first];
    }
    let mut out = vec![first];
    let mut travelled = 0.0;
    for pair in points.windows(2) {
        let &[(a_lat, a_lon), (b_lat, b_lon)] = pair else {
            continue;
        };
        let span = meters(a_lat, a_lon, b_lat, b_lon);
        if travelled + span >= meters_mark && span > 0.0 {
            let f = (meters_mark - travelled) / span;
            out.push((a_lat + (b_lat - a_lat) * f, a_lon + (b_lon - a_lon) * f));
            return out;
        }
        travelled += span;
        out.push((b_lat, b_lon));
    }
    out
}

// ---------------------------------------------------------------------------
// First-minimum nearest searches
// ---------------------------------------------------------------------------

/// Swift's `min(by: <)` over `(index, distance)`: keep the first, replace only
/// on a strictly smaller distance.
fn first_min(items: impl Iterator<Item = (usize, f64)>) -> Option<(usize, f64)> {
    let mut best: Option<(usize, f64)> = None;
    for (i, d) in items {
        let replace = match best {
            None => true,
            Some((_, best_d)) => d < best_d,
        };
        if replace {
            best = Some((i, d));
        }
    }
    best
}

/// The first minimum of [`meters`] from each point to a query point, as
/// `(index, meters)`: Swift's `points.map { meters($0, query) }.min(by: <)`.
///
/// Ties keep the earliest index. A NaN distance at the first point is never
/// displaced, and a later NaN is never taken. `None` for no points.
///
/// Deterministic; panics: none.
#[must_use]
pub fn first_min_meters(lats: &[f64], lons: &[f64], lat: f64, lon: f64) -> Option<(usize, f64)> {
    first_min(
        lats.iter()
            .zip(lons)
            .enumerate()
            .map(|(i, (&p_lat, &p_lon))| (i, meters(p_lat, p_lon, lat, lon))),
    )
}

/// `AmtrakStations.nearest(to:within:in:)`: the index of the first nearest
/// station, or `None` when there is none or it lies beyond `max_meters`.
///
/// The radius is tested after the minimum is chosen, inclusive. A NaN
/// distance or radius therefore answers `None`.
///
/// Deterministic; panics: none.
#[must_use]
pub fn amtrak_nearest(
    lats: &[f64],
    lons: &[f64],
    lat: f64,
    lon: f64,
    max_meters: f64,
) -> Option<usize> {
    first_min_meters(lats, lons, lat, lon).and_then(|(i, d)| (d <= max_meters).then_some(i))
}

/// `RadioTuning.nearest(to:in:)`: the closest transmitter as
/// `(index, meters)`.
///
/// A later station replaces the current best when it is strictly closer, or
/// when the distances are equal and the later one is an exact listing while
/// the best is not. So an exact listing beats an earlier state fallback at the
/// same distance, and otherwise the first of equal minima wins. Equality is
/// IEEE `==`, so a NaN distance is compared with `<` and never replaces.
///
/// Deterministic; panics: none.
#[must_use]
pub fn radio_nearest(
    lats: &[f64],
    lons: &[f64],
    exact: &[bool],
    lat: f64,
    lon: f64,
) -> Option<(usize, f64)> {
    let mut best: Option<(usize, f64, bool)> = None;
    for (i, ((&s_lat, &s_lon), &is_exact)) in lats.iter().zip(lons).zip(exact).enumerate() {
        let d = meters(s_lat, s_lon, lat, lon);
        let replace = match best {
            None => true,
            Some((_, best_d, best_exact)) => {
                if d == best_d {
                    is_exact && !best_exact
                } else {
                    d < best_d
                }
            }
        };
        if replace {
            best = Some((i, d, is_exact));
        }
    }
    best.map(|(i, d, _)| (i, d))
}

/// `ScannerFeedStore.nearest(to:in:)`: the index of the first nearest feed
/// among those with an anchor (`anchored[i]`, meaning both latitude and
/// longitude are present). Unanchored feeds are skipped, and their slice
/// values are ignored.
///
/// Deterministic; panics: none.
#[must_use]
pub fn scanner_feed_nearest(
    lats: &[f64],
    lons: &[f64],
    anchored: &[bool],
    lat: f64,
    lon: f64,
) -> Option<usize> {
    first_min(
        lats.iter()
            .zip(lons)
            .zip(anchored)
            .enumerate()
            .filter(|(_, (_, has))| **has)
            .map(|(i, ((&f_lat, &f_lon), _))| (i, meters(f_lat, f_lon, lat, lon))),
    )
    .map(|(i, _)| i)
}

/// The nearest a list of points comes to a query, in meters:
/// `coords.map { meters($0, position) }.min() ?? .infinity`, as in
/// `CorridorRetention.keep` and `OfflineCorridorStore.nearest`.
///
/// An empty list is infinitely far. The first-minimum rule applies, so a NaN
/// at the first point is the answer.
///
/// Deterministic; panics: none.
#[must_use]
pub fn min_meters_to_point(lats: &[f64], lons: &[f64], lat: f64, lon: f64) -> f64 {
    first_min_meters(lats, lons, lat, lon).map_or(f64::INFINITY, |(_, d)| d)
}

/// `OfflineCorridorStore.nearest(to:)`: the index of the corridor whose road
/// passes nearest the query.
///
/// Corridors arrive flattened: `counts[c]` points each, in order, taken from
/// the parallel slices (the decoded `SavedCorridor.coordinates`). A corridor
/// is scored by [`min_meters_to_point`]; one with no points is infinitely far.
/// The first minimum wins. A count running past the slices takes only the
/// points that exist.
///
/// Deterministic; panics: none.
#[must_use]
pub fn corridor_nearest(
    lats: &[f64],
    lons: &[f64],
    counts: &[usize],
    lat: f64,
    lon: f64,
) -> Option<usize> {
    let n = lats.len().min(lons.len());
    let mut start = 0usize;
    first_min(counts.iter().enumerate().map(|(c, &count)| {
        let end = start.saturating_add(count).min(n);
        let from = start.min(n);
        start = start.saturating_add(count);
        let c_lats = lats.get(from..end).unwrap_or(&[]);
        let c_lons = lons.get(from..end).unwrap_or(&[]);
        (c, min_meters_to_point(c_lats, c_lons, lat, lon))
    }))
    .map(|(c, _)| c)
}

// ---------------------------------------------------------------------------
// Grid keys
// ---------------------------------------------------------------------------

/// Swift's `Int(x)` for a double: truncation toward zero.
///
/// `Err(SwiftTrap)` for NaN, for infinities, and for values outside
/// `[-2^63, 2^63)`, where Swift traps.
///
/// Deterministic; panics: none.
pub fn swift_int(x: f64) -> Result<i64, SwiftTrap> {
    const TWO_POW_63: f64 = 9_223_372_036_854_775_808.0;
    if (-TWO_POW_63..TWO_POW_63).contains(&x) {
        Ok(x as i64)
    } else {
        Err(SwiftTrap)
    }
}

/// A grid cell index, `Int((degrees / cell_degrees).rounded(.down))`.
///
/// `Err(SwiftTrap)` where the floored quotient is not a valid `Int` (see
/// [`swift_int`]). Deterministic; panics: none.
pub fn grid_cell_index(degrees: f64, cell_degrees: f64) -> Result<i64, SwiftTrap> {
    swift_int((degrees / cell_degrees).floor())
}

/// `POIRanking.RoutePath.cell(_:)`: the 0.1-degree cell of a route vertex or
/// query, as `(x, y)` = (longitude index, latitude index).
///
/// `Err(SwiftTrap)` for a non-finite coordinate or one whose quotient by 0.1
/// leaves `Int`. Deterministic; panics: none.
pub fn route_path_cell(lat: f64, lon: f64) -> Result<(i64, i64), SwiftTrap> {
    let x = grid_cell_index(lon, ROUTE_CELL_DEGREES)?;
    let y = grid_cell_index(lat, ROUTE_CELL_DEGREES)?;
    Ok((x, y))
}

/// `ShowerAvailability.LocationTable.cell(_:_:)`: the 0.01-degree cell of a
/// table entry or query, as `(x, y)` = (longitude index, latitude index).
///
/// `Err(SwiftTrap)` for a non-finite coordinate or one whose quotient by 0.01
/// leaves `Int`. Deterministic; panics: none.
pub fn shower_table_cell(lat: f64, lon: f64) -> Result<(i64, i64), SwiftTrap> {
    let x = grid_cell_index(lon, SHOWER_CELL_DEGREES)?;
    let y = grid_cell_index(lat, SHOWER_CELL_DEGREES)?;
    Ok((x, y))
}

/// `PlacesShard.cellKey(lat5:lon5:)`: the FPS1 places shard's 0.2-degree cell
/// key, `(lat5 + 9_000) * 100_000 + (lon5 + 18_000)`, positive for every real
/// coordinate.
///
/// `Err(SwiftTrap)` when any step overflows `Int64`, where Swift traps. This
/// is the Swift reader's key from integer cell indices; the Rust shard writer
/// (`flows-train` `places-shard`) computes its own from `f32` coordinates and
/// is not this function. Deterministic; panics: none.
pub fn places_cell_key(lat5: i64, lon5: i64) -> Result<i64, SwiftTrap> {
    let lat_part = lat5
        .checked_add(9_000)
        .and_then(|v| v.checked_mul(100_000))
        .ok_or(SwiftTrap)?;
    let lon_part = lon5.checked_add(18_000).ok_or(SwiftTrap)?;
    lat_part.checked_add(lon_part).ok_or(SwiftTrap)
}

/// The best-so-far of a grid scan: `d < bestD || (d == bestD && (bestIdx < 0
/// || i < bestIdx))`, starting from `Double.greatestFiniteMagnitude`. So an
/// infinite or NaN distance is never taken, and on an exact tie the lowest
/// index wins whatever order the cells were visited in.
struct LowestIndexBest {
    index: Option<usize>,
    distance: f64,
}

impl LowestIndexBest {
    fn new() -> Self {
        Self {
            index: None,
            distance: f64::MAX,
        }
    }

    fn offer(&mut self, i: usize, d: f64) {
        let take =
            d < self.distance || (d == self.distance && self.index.is_none_or(|best| i < best));
        if take {
            self.index = Some(i);
            self.distance = d;
        }
    }
}

/// Index lists per cell, each ascending because indices are appended in order.
type CellGrid = BTreeMap<(i64, i64), Vec<usize>>;

// ---------------------------------------------------------------------------
// POIRanking.RoutePath
// ---------------------------------------------------------------------------

/// `POIRanking.RoutePath`: a route's vertices, the meters along the route to
/// each vertex, and a 0.1-degree grid over the vertices for nearest-vertex
/// queries.
///
/// The grid is read by key only, never iterated, so no map order can reach an
/// answer.
#[derive(Debug, Clone)]
pub struct RoutePath {
    lats: Vec<f64>,
    lons: Vec<f64>,
    cumulative: Vec<f64>,
    grid: CellGrid,
}

impl RoutePath {
    /// `RoutePath(coords:)`. Cumulative meters start at 0 and add [`meters`]
    /// from each vertex to the next, left to right.
    ///
    /// `Err(SwiftTrap)` when any vertex has no valid cell
    /// ([`route_path_cell`]): a NaN or infinite coordinate, or one beyond
    /// about 9.2e17 degrees. Deterministic; panics: none.
    pub fn new(lats: &[f64], lons: &[f64]) -> Result<Self, SwiftTrap> {
        let n = lats.len().min(lons.len());
        let mut kept_lats = Vec::with_capacity(n);
        let mut kept_lons = Vec::with_capacity(n);
        let mut cumulative = Vec::with_capacity(n);
        let mut grid = CellGrid::new();
        let mut running = 0.0;
        let mut prev: Option<(f64, f64)> = None;
        for (i, (&lat, &lon)) in lats.iter().zip(lons).enumerate() {
            if let Some((p_lat, p_lon)) = prev {
                running += meters(p_lat, p_lon, lat, lon);
            }
            cumulative.push(running);
            grid.entry(route_path_cell(lat, lon)?).or_default().push(i);
            kept_lats.push(lat);
            kept_lons.push(lon);
            prev = Some((lat, lon));
        }
        Ok(Self {
            lats: kept_lats,
            lons: kept_lons,
            cumulative,
            grid,
        })
    }

    /// Number of vertices.
    #[must_use]
    pub fn len(&self) -> usize {
        self.lats.len()
    }

    /// `true` for a route with no vertices.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.lats.is_empty()
    }

    /// `RoutePath.cumulative`: meters from the first vertex to each vertex.
    #[must_use]
    pub fn cumulative(&self) -> &[f64] {
        &self.cumulative
    }

    /// `RoutePath.nearest(to:)`: the nearest vertex to a query as
    /// `(index, off-route meters)`, by [`meters`] from vertex to query.
    ///
    /// The Swift's expanding-ring search, reproduced step for step:
    /// 1. An empty route answers `None` before the query is examined.
    /// 2. `cellMinMeters = 0.1 * 111_320 * max(cos(lat * PI / 180), 0.1)`.
    /// 3. For ring `r` in `0...16`: ring 0 is the query's cell; ring `r` is the
    ///    top and bottom rows (x from `-r` to `r`), then the left and right
    ///    columns (y from `-r + 1` to `r - 1`). After each ring, a found vertex
    ///    is returned once `r * cellMinMeters > best`.
    /// 4. Otherwise a full scan in index order decides.
    ///
    /// Ties go to the lowest index, whatever order the cells were visited in,
    /// and an infinite or NaN distance is never taken. The ring bound is
    /// not a proof of exactness (it uses the query's latitude), so the answer
    /// is the ring search's, not a full scan's.
    ///
    /// `Err(SwiftTrap)` for a query with no valid cell on a non-empty route,
    /// and when ring `r` reaches a cell index outside `Int64` (a query whose
    /// cell index is exactly `-2^63` traps at ring 1). Deterministic; panics:
    /// none.
    pub fn nearest(&self, lat: f64, lon: f64) -> Result<Option<(usize, f64)>, SwiftTrap> {
        if self.lats.is_empty() {
            return Ok(None);
        }
        let (cx, cy) = route_path_cell(lat, lon)?;
        let cell_min_meters = ROUTE_CELL_DEGREES * 111_320.0 * smax(lm_cos(lat * PI / 180.0), 0.1);
        let mut best = LowestIndexBest::new();
        for r in 0..=ROUTE_MAX_RINGS {
            if r == 0 {
                self.consider((cx, cy), lat, lon, &mut best);
            } else {
                // Ring r computes c0.x ± r and c0.y ± r in Swift Int arithmetic
                // before its first lookup, so any overflow traps the whole call.
                let (Some(x_lo), Some(x_hi), Some(y_lo), Some(y_hi)) = (
                    cx.checked_sub(r),
                    cx.checked_add(r),
                    cy.checked_sub(r),
                    cy.checked_add(r),
                ) else {
                    return Err(SwiftTrap);
                };
                for x in x_lo..=x_hi {
                    self.consider((x, y_lo), lat, lon, &mut best);
                    self.consider((x, y_hi), lat, lon, &mut best);
                }
                // y_lo < y_hi, so neither step can overflow.
                for y in (y_lo + 1)..=(y_hi - 1) {
                    self.consider((x_lo, y), lat, lon, &mut best);
                    self.consider((x_hi, y), lat, lon, &mut best);
                }
            }
            if let Some(i) = best.index {
                if (r as f64) * cell_min_meters > best.distance {
                    return Ok(Some((i, best.distance)));
                }
            }
        }
        let mut best = LowestIndexBest::new();
        for (i, (&v_lat, &v_lon)) in self.lats.iter().zip(&self.lons).enumerate() {
            best.offer(i, meters(v_lat, v_lon, lat, lon));
        }
        Ok(best.index.map(|i| (i, best.distance)))
    }

    fn consider(&self, cell: (i64, i64), lat: f64, lon: f64, best: &mut LowestIndexBest) {
        let Some(indices) = self.grid.get(&cell) else {
            return;
        };
        for &i in indices {
            if let (Some(&v_lat), Some(&v_lon)) = (self.lats.get(i), self.lons.get(i)) {
                best.offer(i, meters(v_lat, v_lon, lat, lon));
            }
        }
    }
}

// ---------------------------------------------------------------------------
// ShowerAvailability.LocationTable
// ---------------------------------------------------------------------------

/// `ShowerAvailability.LocationTable`: bundled truck-stop locations on a
/// 0.01-degree grid, for "which listed stop is this?" lookups. Swift keeps the
/// decoded entries; this holds only their coordinates and answers indices.
///
/// The grid is read by key only, never iterated.
#[derive(Debug, Clone)]
pub struct ShowerLocationTable {
    lats: Vec<f64>,
    lons: Vec<f64>,
    grid: CellGrid,
}

impl ShowerLocationTable {
    /// `LocationTable(entries:)`.
    ///
    /// `Err(SwiftTrap)` when any entry has no valid cell
    /// ([`shower_table_cell`]). Deterministic; panics: none.
    pub fn new(lats: &[f64], lons: &[f64]) -> Result<Self, SwiftTrap> {
        let n = lats.len().min(lons.len());
        let mut kept_lats = Vec::with_capacity(n);
        let mut kept_lons = Vec::with_capacity(n);
        let mut grid = CellGrid::new();
        for (i, (&lat, &lon)) in lats.iter().zip(lons).enumerate() {
            grid.entry(shower_table_cell(lat, lon)?)
                .or_default()
                .push(i);
            kept_lats.push(lat);
            kept_lons.push(lon);
        }
        Ok(Self {
            lats: kept_lats,
            lons: kept_lons,
            grid,
        })
    }

    /// `LocationTable.entry(nearLat:lon:)`: the index of the nearest entry
    /// inside the strict box `|Δlat| < 0.01` and `|Δlon| < 0.01`.
    ///
    /// Only the query's cell and its eight neighbours are scanned (rows from
    /// y-1 to y+1, x from x-1 to x+1 within each). Distance is the squared
    /// degree difference `Δlat * Δlat + Δlon * Δlon`; ties go to the lowest
    /// index.
    ///
    /// `Err(SwiftTrap)` for a query with no valid cell (checked before
    /// anything else, even on an empty table), and when x±1 or y±1 leaves
    /// `Int64`. Deterministic; panics: none.
    pub fn entry(&self, lat: f64, lon: f64) -> Result<Option<usize>, SwiftTrap> {
        let (cx, cy) = shower_table_cell(lat, lon)?;
        // All nine cells are built unconditionally in Swift Int arithmetic.
        let (Some(x_lo), Some(x_hi), Some(y_lo), Some(y_hi)) = (
            cx.checked_sub(1),
            cx.checked_add(1),
            cy.checked_sub(1),
            cy.checked_add(1),
        ) else {
            return Err(SwiftTrap);
        };
        let mut best = LowestIndexBest::new();
        for y in [y_lo, cy, y_hi] {
            for x in [x_lo, cx, x_hi] {
                let Some(indices) = self.grid.get(&(x, y)) else {
                    continue;
                };
                for &i in indices {
                    let (Some(&e_lat), Some(&e_lon)) = (self.lats.get(i), self.lons.get(i)) else {
                        continue;
                    };
                    if (e_lat - lat).abs() < SHOWER_CELL_DEGREES
                        && (e_lon - lon).abs() < SHOWER_CELL_DEGREES
                    {
                        let d = (e_lat - lat) * (e_lat - lat) + (e_lon - lon) * (e_lon - lon);
                        best.offer(i, d);
                    }
                }
            }
        }
        Ok(best.index)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_degree_of_latitude_is_111_320_meters_and_longitude_shrinks_with_mean_latitude() {
        assert_eq!(meters(10.0, 20.0, 11.0, 20.0), 111_320.0);
        assert_eq!(meters(0.0, 0.0, 0.0, 1.0), 111_320.0);
        let at_60 = meters(59.5, 0.0, 60.5, 0.0);
        assert_eq!(at_60, 111_320.0);
        let lon_at_60 = meters(60.0, 0.0, 60.0, 1.0);
        assert!((lon_at_60 - 55_660.0).abs() < 1e-6, "{lon_at_60}");
        assert_eq!(meters(43.0, -89.0, 43.0, -89.0).to_bits(), 0.0f64.to_bits());
        assert!(meters(f64::NAN, 0.0, 0.0, 0.0).is_nan());
    }

    #[test]
    fn distance_is_symmetric_for_finite_points() {
        let (a, b) = ((43.07, -89.40), (41.88, -87.63));
        assert_eq!(
            meters(a.0, a.1, b.0, b.1).to_bits(),
            meters(b.0, b.1, a.0, a.1).to_bits()
        );
    }

    #[test]
    fn bearings_point_at_the_compass_and_keep_swifts_edges() {
        assert_eq!(bearing_degrees(0.0, 0.0, 1.0, 0.0), 0.0);
        assert!((bearing_degrees(0.0, 0.0, 0.0, 1.0) - 90.0).abs() < 1e-9);
        assert!((bearing_degrees(0.0, 0.0, -1.0, 0.0) - 180.0).abs() < 1e-9);
        assert!((bearing_degrees(0.0, 0.0, 0.0, -1.0) - 270.0).abs() < 1e-9);
        // atan2(-0, +x) is -0, and -0 is not < 0: the Swift returns -0.
        assert_eq!(
            bearing_degrees(0.0, 0.0, 1.0, -0.0).to_bits(),
            (-0.0f64).to_bits()
        );
        assert!(bearing_degrees(f64::NAN, 0.0, 1.0, 0.0).is_nan());
    }

    #[test]
    fn heading_delta_wraps_once_toward_plus_minus_180() {
        assert_eq!(heading_delta_degrees(10.0, 350.0), 20.0);
        assert_eq!(heading_delta_degrees(350.0, 10.0), -20.0);
        assert_eq!(heading_delta_degrees(180.0, 0.0), 180.0);
        assert_eq!(heading_delta_degrees(0.0, 180.0), -180.0);
        assert_eq!(heading_delta_degrees(0.0, 540.0), -180.0);
        assert!(heading_delta_degrees(0.0, f64::INFINITY).is_nan());
    }

    #[test]
    fn a_camera_is_ahead_inside_the_cone_and_everything_is_ahead_without_a_heading() {
        // Target due north of the position.
        assert!(camera_is_ahead(1.0, 0.0, 0.0, 0.0, Some(0.0)));
        assert!(!camera_is_ahead(1.0, 0.0, 0.0, 0.0, Some(180.0)));
        assert!(camera_is_ahead(1.0, 0.0, 0.0, 0.0, None));
        assert!(camera_is_ahead(1.0, 0.0, 0.0, 0.0, Some(-1.0)));
        assert!(camera_is_ahead(1.0, 0.0, 0.0, 0.0, Some(f64::NAN)));
        assert!(camera_is_ahead(1.0, 0.0, 0.0, 0.0, Some(-0.0)));
    }

    #[test]
    fn a_route_decides_reachability_before_the_course_does() {
        let (route_lats, route_lons) = ([43.0, 43.1], [-89.0, -89.0]);
        // Station 1 km from the second route point, course pointing away.
        let reach = |corridor| {
            fuel_station_is_reachable(
                43.1 + 1_000.0 / 111_320.0,
                -89.0,
                43.0,
                -89.0,
                180.0,
                &route_lats,
                &route_lons,
                corridor,
            )
        };
        assert!(reach(FUEL_CORRIDOR_METERS));
        assert!(!reach(500.0));
        // No route: the course cone decides; a negative course keeps everything.
        assert!(!fuel_station_is_reachable(
            44.0,
            -89.0,
            43.0,
            -89.0,
            180.0,
            &[],
            &[],
            8_000.0
        ));
        assert!(fuel_station_is_reachable(
            44.0,
            -89.0,
            43.0,
            -89.0,
            0.0,
            &[],
            &[],
            8_000.0
        ));
        assert!(fuel_station_is_reachable(
            44.0,
            -89.0,
            43.0,
            -89.0,
            -1.0,
            &[],
            &[],
            8_000.0
        ));
    }

    #[test]
    fn segment_distance_clamps_to_the_endpoints_and_a_nan_parameter_to_the_far_one() {
        // p beyond b along the segment's direction: distance to b.
        let d = distance_to_segment_meters_scaled(0.0, 3.0, 0.0, 0.0, 0.0, 1.0, 111_320.0);
        assert_eq!(d, 2.0 * 111_320.0);
        // Perpendicular foot inside the segment.
        let d = distance_to_segment_meters_scaled(1.0, 0.5, 0.0, 0.0, 0.0, 1.0, 111_320.0);
        assert_eq!(d, 111_320.0);
        // Zero-length segment: distance to a.
        let d = distance_to_segment_meters_scaled(1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 111_320.0);
        assert_eq!(d, 111_320.0);
        // An overflowing segment makes t = inf / inf = NaN. Swift's
        // max(0, min(1, t)) turns that into 1, the far endpoint, so the answer
        // is |b - p| = inf; f64::clamp would have carried NaN through.
        let d = distance_to_segment_meters_scaled(0.0, 0.0, 0.0, -1e200, 0.0, 1e200, 1.0);
        assert_eq!(d, f64::INFINITY);
    }

    #[test]
    fn prefix_ends_exactly_at_the_mark() {
        let lats = [0.0, 0.0, 0.0];
        let lons = [0.0, 1.0, 2.0];
        assert_eq!(prefix_coordinates(&[], &[], 5.0), vec![]);
        assert_eq!(
            prefix_coordinates(&lats[..1], &lons[..1], 5.0),
            vec![(0.0, 0.0)]
        );
        assert_eq!(prefix_coordinates(&lats, &lons, 0.0), vec![(0.0, 0.0)]);
        assert_eq!(prefix_coordinates(&lats, &lons, f64::NAN), vec![(0.0, 0.0)]);
        let half = prefix_coordinates(&lats, &lons, 111_320.0 * 1.5);
        assert_eq!(half, vec![(0.0, 0.0), (0.0, 1.0), (0.0, 1.5)]);
        let whole = prefix_coordinates(&lats, &lons, 1e9);
        assert_eq!(whole, vec![(0.0, 0.0), (0.0, 1.0), (0.0, 2.0)]);
    }

    #[test]
    fn first_minimum_keeps_the_earliest_tie_and_a_leading_nan() {
        let lats = [1.0, 0.5, 0.5, 0.25];
        let lons = [0.0, 0.0, 0.0, 0.0];
        assert_eq!(
            first_min_meters(&lats[..3], &lons[..3], 0.0, 0.0).map(|b| b.0),
            Some(1)
        );
        assert_eq!(
            first_min_meters(&lats, &lons, 0.0, 0.0).map(|b| b.0),
            Some(3)
        );
        let with_nan = [f64::NAN, 0.25];
        assert_eq!(
            first_min_meters(&with_nan, &[0.0, 0.0], 0.0, 0.0).map(|b| b.0),
            Some(0)
        );
        assert_eq!(first_min_meters(&[], &[], 0.0, 0.0), None);
        assert_eq!(min_meters_to_point(&[], &[], 0.0, 0.0), f64::INFINITY);
    }

    #[test]
    fn amtrak_tests_the_radius_after_choosing_the_nearest() {
        let (lats, lons) = ([0.5, 0.1], [0.0, 0.0]);
        assert_eq!(amtrak_nearest(&lats, &lons, 0.0, 0.0, 20_000.0), Some(1));
        assert_eq!(amtrak_nearest(&lats, &lons, 0.0, 0.0, 1_000.0), None);
        assert_eq!(amtrak_nearest(&lats, &lons, 0.0, 0.0, f64::NAN), None);
    }

    #[test]
    fn an_exact_radio_listing_beats_an_earlier_fallback_at_the_same_distance_only() {
        let (lats, lons) = ([1.0, 1.0, 1.0], [0.0, 0.0, 0.0]);
        assert_eq!(
            radio_nearest(&lats, &lons, &[false, true, true], 0.0, 0.0).map(|b| b.0),
            Some(1)
        );
        assert_eq!(
            radio_nearest(&lats, &lons, &[true, false, true], 0.0, 0.0).map(|b| b.0),
            Some(0)
        );
        assert_eq!(
            radio_nearest(&lats, &lons, &[false, false, false], 0.0, 0.0).map(|b| b.0),
            Some(0)
        );
    }

    #[test]
    fn scanner_feeds_without_an_anchor_are_skipped() {
        let (lats, lons) = ([0.0, 5.0, 0.1], [0.0, 0.0, 0.0]);
        assert_eq!(
            scanner_feed_nearest(&lats, &lons, &[false, true, true], 0.0, 0.0),
            Some(2)
        );
        assert_eq!(
            scanner_feed_nearest(&lats, &lons, &[false, false, false], 0.0, 0.0),
            None
        );
    }

    #[test]
    fn an_empty_corridor_is_infinitely_far_and_the_first_nearest_corridor_wins() {
        let lats = [5.0, 1.0, 1.0];
        let lons = [0.0, 0.0, 0.0];
        assert_eq!(
            corridor_nearest(&lats, &lons, &[0, 1, 1, 1], 0.0, 0.0),
            Some(2)
        );
        assert_eq!(corridor_nearest(&lats, &lons, &[0, 0], 0.0, 0.0), Some(0));
        assert_eq!(corridor_nearest(&lats, &lons, &[], 0.0, 0.0), None);
        // A count past the slices keeps only what exists.
        assert_eq!(corridor_nearest(&lats, &lons, &[1, 9], 0.0, 0.0), Some(1));
    }

    #[test]
    fn swift_int_accepts_exactly_the_int64_range() {
        assert_eq!(swift_int(-1.5), Ok(-1));
        assert_eq!(swift_int(-9_223_372_036_854_775_808.0), Ok(i64::MIN));
        assert_eq!(
            swift_int(9_223_372_036_854_775_808.0_f64.next_down()),
            Ok(9_223_372_036_854_774_784)
        );
        assert_eq!(swift_int(9_223_372_036_854_775_808.0), Err(SwiftTrap));
        assert_eq!(
            swift_int((-9_223_372_036_854_775_808.0_f64).next_down()),
            Err(SwiftTrap)
        );
        assert_eq!(swift_int(f64::NAN), Err(SwiftTrap));
        assert_eq!(swift_int(f64::NEG_INFINITY), Err(SwiftTrap));
    }

    #[test]
    fn grid_cells_floor_toward_negative_infinity() {
        assert_eq!(route_path_cell(-0.05, 0.05), Ok((0, -1)));
        assert_eq!(shower_table_cell(0.019, -0.001), Ok((-1, 1)));
        assert_eq!(route_path_cell(f64::NAN, 0.0), Err(SwiftTrap));
    }

    #[test]
    fn places_cell_keys_are_positive_for_real_coordinates_and_trap_on_overflow() {
        assert_eq!(places_cell_key(0, 0), Ok(900_018_000));
        assert_eq!(places_cell_key(-450, -900), Ok(855_017_100));
        assert_eq!(
            places_cell_key(92_233_720_368_547 - 9_000, 57_807),
            Ok(i64::MAX)
        );
        assert_eq!(
            places_cell_key(92_233_720_368_547 - 9_000, 57_808),
            Err(SwiftTrap)
        );
        assert_eq!(places_cell_key(i64::MAX, 0), Err(SwiftTrap));
    }

    #[test]
    fn route_path_accumulates_and_finds_the_lowest_index_among_equal_vertices() {
        let lats = [43.0, 43.01, 43.0, 43.01];
        let lons = [-89.0, -89.0, -89.0, -89.0];
        let route = RoutePath::new(&lats, &lons).expect("finite route");
        assert_eq!(route.len(), 4);
        let step = meters(43.0, -89.0, 43.01, -89.0);
        assert_eq!(
            route.cumulative(),
            &[0.0, step, step + step, step + step + step]
        );
        assert_eq!(route.nearest(43.0, -89.0), Ok(Some((0, 0.0))));
        assert_eq!(route.nearest(43.01, -89.0), Ok(Some((1, 0.0))));
    }

    #[test]
    fn route_path_matches_a_full_scan_near_the_route_and_falls_back_far_from_it() {
        let lats: Vec<f64> = (0..200).map(|i| 40.0 + f64::from(i) * 0.01).collect();
        let lons: Vec<f64> = (0..200).map(|i| -100.0 - f64::from(i) * 0.013).collect();
        let route = RoutePath::new(&lats, &lons).expect("finite route");
        for (q_lat, q_lon) in [(40.5, -100.7), (41.0, -102.0), (10.0, 10.0), (40.0, -100.0)] {
            let mut full = LowestIndexBest::new();
            for (i, (&a, &b)) in lats.iter().zip(&lons).enumerate() {
                full.offer(i, meters(a, b, q_lat, q_lon));
            }
            assert_eq!(
                route.nearest(q_lat, q_lon),
                Ok(full.index.map(|i| (i, full.distance)))
            );
        }
    }

    #[test]
    fn route_path_ring_search_can_miss_a_nearer_vertex_above_the_cosine_clamp() {
        // Recorded behaviour of the Swift, not an endorsement: RoutePath.nearest
        // claims the full scan's answer, but its ring bound clamps cos at 0.1.
        // Above about 84.26 degrees a longitude cell is narrower than the bound
        // assumes, so the search stops after ring 1 with vertex 0 (1,050 m
        // north) while vertex 1, two cells east, is 971 m away. The oracle's
        // `hilat` route records the same answer from the Swift.
        let lats = [85.0 + 1_050.0 / 111_320.0, 85.0];
        let lons = [0.0999, 0.2];
        let route = RoutePath::new(&lats, &lons).expect("finite route");
        let (ring_index, ring_meters) = route
            .nearest(85.0, 0.0999)
            .expect("no trap")
            .expect("a vertex");
        let to_second = meters(85.0, 0.2, 85.0, 0.0999);
        assert_eq!(ring_index, 0);
        assert!(to_second < ring_meters, "{to_second} vs {ring_meters}");
    }

    #[test]
    fn bearing_can_be_exactly_360_where_swift_documents_under_360() {
        // An oracle input: atan2 returns a tiny negative angle, and adding 360
        // rounds to 360.0.
        let deg = bearing_degrees(
            f64::from_bits(0x4066_8000_0000_0001),
            f64::from_bits(0x4066_8000_0000_0001),
            f64::from_bits(0xc050_3901_c0b0_3d96),
            f64::from_bits(0xc076_8000_0000_0000),
        );
        assert_eq!(deg.to_bits(), 360.0f64.to_bits());
    }

    #[test]
    fn route_path_traps_where_swift_traps_and_not_before_the_empty_check() {
        let empty = RoutePath::new(&[], &[]).expect("empty route");
        assert_eq!(empty.nearest(f64::NAN, 0.0), Ok(None));
        assert!(RoutePath::new(&[f64::NAN], &[0.0]).is_err());
        let route = RoutePath::new(&[43.0], &[-89.0]).expect("finite route");
        assert_eq!(route.nearest(f64::INFINITY, 0.0), Err(SwiftTrap));
        // A query whose longitude cell index is exactly Int.min traps at ring 1.
        assert_eq!(
            route_path_cell(0.0, -922_337_203_685_477_632.0).map(|c| c.0),
            Ok(i64::MIN)
        );
        assert_eq!(
            route.nearest(0.0, -922_337_203_685_477_632.0),
            Err(SwiftTrap)
        );
    }

    #[test]
    fn shower_table_matches_inside_the_strict_box_with_lowest_index_ties() {
        let lats = [35.0, 35.004, 35.004, 35.02];
        let lons = [-97.0, -97.0, -97.0, -97.0];
        let table = ShowerLocationTable::new(&lats, &lons).expect("finite table");
        assert_eq!(table.entry(35.005, -97.0), Ok(Some(1)));
        assert_eq!(table.entry(35.0, -97.02), Ok(None));
        assert_eq!(table.entry(35.5, -97.0), Ok(None));
        let empty = ShowerLocationTable::new(&[], &[]).expect("empty table");
        assert_eq!(empty.entry(f64::NAN, 0.0), Err(SwiftTrap));
        assert_eq!(empty.entry(-92_233_720_368_547_760.0, 0.0), Err(SwiftTrap));
    }
}
