// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Places: the route-aware stop ranking, the FPS1 offline-places shard and
//! its nearby query, and the stop search's rules — `POIRanking.swift`,
//! `PlacesStore.swift` and the decisions inside `POIService.swift` at commit
//! 0f8894b, the last before their facade switch.
//!
//! | here | Swift |
//! |---|---|
//! | [`RoutePath`], [`RoutePath::nearest`], [`annotate`], [`admissible`] | `POIRanking.RoutePath`, `.nearest(to:)`, `annotate`, `admissible` |
//! | [`rank_food`], [`rank_fuel`], [`rank_hotels`], [`rank_parking`], [`rank_stores`] | the rankers (the items stay with the caller; the answers are orders of indices) |
//! | [`parking_cost_tier`], [`store_market_share_rank`], [`STORE_MARKET_SHARE_ORDER`], [`fuel_costs`] | `parkingCostTier`, `storeMarketShareRank`, `storeMarketShareOrder`, `FuelType.fillUnits` / `.averagePricePerUnit` |
//! | [`PlacesIndex`], [`PlacesIndex::places_near`], [`PlacesIndex::place`], [`cell_key`] | `PlacesShard`, `.places(near:groups:radiusMeters:limit:)`, `decode(recordAt:)`, `.cellKey` |
//! | [`rank_by_distance`] | the store's cross-shard merge, the service's no-route and essential fallbacks |
//! | [`kind_policy`], [`rank_along`], [`merge_everyday_first`], [`attribute_id`] | `POIService`'s per-kind rules and `rank`, `merged`, `EverydayPlace.attributeID` |
//! | [`first_nearest`], [`center_picks`], [`route_decimation_step`], [`dedup_rows`], [`pinned_rows`], [`shower_brand`] | the corridor start, the search centres, the route thinning, the result dedup, the habit pins and the shower brand pick inside `search` and `beginCorridorSearch` |
//!
//! # Fidelity
//!
//! Pinned by `flows-bridge/tests/fixtures/swift_places_oracle.tsv`. The
//! nearest-vertex search keeps the Swift's expanding-ring grid with its early
//! exit and full-scan fallback and its exact comparator, so the same vertex
//! wins the same tie; every ordering is Swift's own sort
//! ([`crate::learning::swift_sort_by`]) on the Swift's comparator, NaN
//! included; distances are the geo kernel's [`meters`]; names compare as
//! Swift strings do ([`crate::swift_text`]). The shard's cell lookup is the
//! Swift's own binary search, so a crafted grid with repeated or unsorted
//! keys finds the same cell. Where the Swift trapped — a coordinate that is
//! not a number reaching `Int`, a cell range that runs backwards, a negative
//! limit — the port answers nothing and says so at the site.
//!
//! The shard's bytes are never owned here: [`PlacesIndex`] keeps the offset
//! tables the Swift kept, and every query borrows the caller's buffer, so a
//! memory-mapped shard stays mapped (clean, file-backed pages) instead of
//! becoming a copy. Nothing here performs I/O.

use crate::fcmp::{smax, swift_int};
use crate::fmath;
use crate::geo::meters;
use crate::learning::swift_sort_by;
use crate::swift_text as st;
use std::collections::{HashMap, HashSet};
use std::f64::consts::PI;

/// A point as (latitude, longitude), degrees.
pub type Point = (f64, f64);

/// Meters in a degree, the kernel's constant.
pub const METERS_PER_DEGREE: f64 = 111_320.0;

// ============================================================ RoutePath

/// The route grid's cell side, degrees (about 11 km of latitude).
pub const ROUTE_CELL_DEGREES: f64 = 0.1;
/// Rings searched before the nearest-vertex search falls back to a full scan.
pub const ROUTE_MAX_RINGS: i64 = 16;

/// The best vertex so far, as the Swift kept it: no index yet, and the
/// greatest finite distance.
#[derive(Clone, Copy)]
struct Best {
    index: Option<usize>,
    distance: f64,
}

impl Best {
    fn new() -> Best {
        Best {
            index: None,
            distance: f64::MAX,
        }
    }

    /// `d < bestD || (d == bestD && (bestIdx < 0 || i < bestIdx))`: an
    /// infinite or NaN distance never takes the first place.
    fn offer(&mut self, i: usize, d: f64) {
        if d < self.distance || (d == self.distance && self.index.is_none_or(|b| i < b)) {
            self.index = Some(i);
            self.distance = d;
        }
    }

    fn answer(self) -> Option<(usize, f64)> {
        self.index.map(|i| (i, self.distance))
    }
}

/// The grid cell of a point, `(x, y)` = (longitude, latitude) indices;
/// `None` where the Swift trapped (a coordinate that is not a number or out
/// of `Int` range).
fn route_cell(p: Point) -> Option<(i64, i64)> {
    Some((
        swift_int((p.1 / ROUTE_CELL_DEGREES).floor())?,
        swift_int((p.0 / ROUTE_CELL_DEGREES).floor())?,
    ))
}

fn cell_at(x: Option<i64>, y: Option<i64>) -> Option<(i64, i64)> {
    Some((x?, y?))
}

/// The active route's geometry, flattened once per leg, with a 0.1° grid
/// over its vertices.
#[derive(Clone, Debug)]
pub struct RoutePath {
    coords: Vec<Point>,
    cumulative: Vec<f64>,
    grid: HashMap<(i64, i64), Vec<usize>>,
}

impl RoutePath {
    /// `RoutePath(coords:)`: meters from the origin to each vertex (the
    /// kernel's distance, hop by hop) and the vertex grid. A vertex that
    /// cannot be placed on the grid (where the Swift trapped) is left out of
    /// it; the full-scan fallback still sees it.
    ///
    /// Deterministic; panics: none.
    #[must_use]
    pub fn new(coords: Vec<Point>) -> RoutePath {
        let mut running = 0.0;
        let mut cumulative = Vec::with_capacity(coords.len());
        let mut grid: HashMap<(i64, i64), Vec<usize>> = HashMap::new();
        let mut prev: Option<Point> = None;
        for (i, &c) in coords.iter().enumerate() {
            if let Some(p) = prev {
                running += meters(p.0, p.1, c.0, c.1);
            }
            cumulative.push(running);
            if let Some(cell) = route_cell(c) {
                grid.entry(cell).or_default().push(i);
            }
            prev = Some(c);
        }
        RoutePath {
            coords,
            cumulative,
            grid,
        }
    }

    /// The vertices.
    #[must_use]
    pub fn coords(&self) -> &[Point] {
        &self.coords
    }

    /// Meters from the origin to each vertex.
    #[must_use]
    pub fn cumulative(&self) -> &[f64] {
        &self.cumulative
    }

    fn consider(&self, best: &mut Best, cell: Option<(i64, i64)>, p: Point) {
        let Some(indices) = cell.and_then(|c| self.grid.get(&c)) else {
            return;
        };
        for &i in indices {
            let c = self.coords[i];
            best.offer(i, meters(c.0, c.1, p.0, p.1));
        }
    }

    /// `nearest(to:)`: the nearest vertex and its off-route meters. The
    /// query's cell is scanned, then each surrounding ring's border, until
    /// ring `r` lies farther than the best found (`r · cellMinMeters >
    /// best`); past sixteen rings, a full scan. The lowest index wins an
    /// exact tie. `None` for an empty route, a query that cannot be placed
    /// (where the Swift trapped), or distances that are never finite.
    ///
    /// Deterministic (platform libm `cos`); panics: none.
    #[must_use]
    pub fn nearest(&self, p: Point) -> Option<(usize, f64)> {
        if self.coords.is_empty() {
            return None;
        }
        let (cx0, cy0) = route_cell(p)?;
        let cell_min_meters =
            ROUTE_CELL_DEGREES * METERS_PER_DEGREE * smax(fmath::cos(p.0 * PI / 180.0), 0.1);
        let mut best = Best::new();
        for r in 0..=ROUTE_MAX_RINGS {
            if r == 0 {
                self.consider(&mut best, Some((cx0, cy0)), p);
            } else {
                for dx in -r..=r {
                    let x = cx0.checked_add(dx);
                    self.consider(&mut best, cell_at(x, cy0.checked_sub(r)), p);
                    self.consider(&mut best, cell_at(x, cy0.checked_add(r)), p);
                }
                for dy in (-r + 1)..=(r - 1) {
                    let y = cy0.checked_add(dy);
                    self.consider(&mut best, cell_at(cx0.checked_sub(r), y), p);
                    self.consider(&mut best, cell_at(cx0.checked_add(r), y), p);
                }
            }
            if best.index.is_some() && r as f64 * cell_min_meters > best.distance {
                return best.answer();
            }
        }
        let mut best = Best::new();
        for (i, c) in self.coords.iter().enumerate() {
            best.offer(i, meters(c.0, c.1, p.0, p.1));
        }
        best.answer()
    }
}

// ============================================================ the rankers

/// Tolerated backtrack (GPS jitter, a station at the previous exit), meters.
pub const BACKTRACK_TOLERANCE_METERS: f64 = 500.0;
/// The hard corridor deviation cap, meters.
pub const MAX_DETOUR_METERS: f64 = 12_000.0;
/// Assumed detour driving speed for time costing, m/s (about 30 mph).
pub const DETOUR_SPEED_MPS: f64 = 13.4;
/// What an hour of the driver's time is worth in the fuel cost model.
pub const DOLLARS_PER_HOUR: f64 = 30.0;
/// Typical US nightly rate, the hotel value model's neutral price.
pub const AVERAGE_NIGHTLY_PRICE: f64 = 120.0;

/// A candidate stop's route metrics; the item itself stays with the caller.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Candidate {
    /// Meters ahead of the vehicle along the route (negative = behind).
    pub ahead_meters: f64,
    /// Straight-line meters off the corridor.
    pub detour_meters: f64,
    /// Unit price when a price source is available.
    pub price_per_unit: Option<f64>,
    /// Public review rating 0…5 when a source is available.
    pub rating: Option<f64>,
}

/// `annotate`: a stop's route metrics; `None` when the route cannot place it.
#[must_use]
pub fn annotate(
    route: &RoutePath,
    p: Point,
    vehicle_along: f64,
    price_per_unit: Option<f64>,
    rating: Option<f64>,
) -> Option<Candidate> {
    let (index, off_route) = route.nearest(p)?;
    Some(Candidate {
        ahead_meters: route.cumulative[index] - vehicle_along,
        detour_meters: off_route,
        price_per_unit,
        rating,
    })
}

/// `admissible`: ahead of the vehicle within the jitter tolerance and within
/// the corridor deviation cap.
#[must_use]
pub fn admissible(c: &Candidate, max_detour: f64) -> bool {
    c.ahead_meters > -BACKTRACK_TOLERANCE_METERS && c.detour_meters <= max_detour
}

/// The admissible candidates' indices, in order, then Swift's sort under `lt`.
fn ranked(cands: &[Candidate], max_detour: f64, lt: impl Fn(usize, usize) -> bool) -> Vec<usize> {
    let mut order: Vec<usize> = (0..cands.len())
        .filter(|&i| admissible(&cands[i], max_detour))
        .collect();
    swift_sort_by(&mut order, lt);
    order
}

/// Along-route meters plus three times the detour.
fn soonest(c: &Candidate) -> f64 {
    c.ahead_meters + 3.0 * c.detour_meters
}

/// Hours for the detour there and back.
fn detour_hours(c: &Candidate) -> f64 {
    (2.0 * c.detour_meters / DETOUR_SPEED_MPS) / 3600.0
}

/// `rankFood`: soonest reachable first.
#[must_use]
pub fn rank_food(cands: &[Candidate], max_detour: f64) -> Vec<usize> {
    ranked(cands, max_detour, |a, b| {
        soonest(&cands[a]) < soonest(&cands[b])
    })
}

/// `rankFuel`: fill cost plus detour time cost, cheapest first; an unpriced
/// station fills at the average price.
#[must_use]
pub fn rank_fuel(
    cands: &[Candidate],
    fill_units: f64,
    average_price_per_unit: f64,
    max_detour: f64,
) -> Vec<usize> {
    let total = |c: &Candidate| {
        c.price_per_unit.unwrap_or(average_price_per_unit) * fill_units
            + detour_hours(c) * DOLLARS_PER_HOUR
    };
    ranked(cands, max_detour, |a, b| {
        total(&cands[a]) < total(&cands[b])
    })
}

/// `rankHotels`: rating (weight 2, neutral 3.5 stars) minus price relative
/// to the average night minus detour time (weight 1.5), best value first.
#[must_use]
pub fn rank_hotels(cands: &[Candidate], average_nightly: f64, max_detour: f64) -> Vec<usize> {
    let value = |c: &Candidate| {
        let rating = c.rating.unwrap_or(3.5) / 5.0;
        let price = c.price_per_unit.unwrap_or(average_nightly) / smax(average_nightly, 1.0);
        rating * 2.0 - price - detour_hours(c) * 1.5
    };
    ranked(cands, max_detour, |a, b| {
        value(&cands[a]) > value(&cands[b])
    })
}

/// `parkingCostTier(name:)`: free lots, street parking and park-and-ride 0;
/// garages, ramps, valet, premium and airport 2; anything else 1 — by
/// substring of the lowercased name.
#[must_use]
pub fn parking_cost_tier(name: Option<&str>) -> i64 {
    let lower = st::lowercased(name.unwrap_or(""));
    let has = |w: &str| st::contains(&lower, w);
    if has("free") || has("park & ride") || has("park and ride") || has("street parking") {
        return 0;
    }
    if has("garage") || has("ramp") || has("valet") || has("premium") || has("airport") {
        return 2;
    }
    1
}

/// `rankParking`: a cost tier is worth about 4 km of detour, then soonest
/// reachable in kilometres; a live price replaces the tier. `cost_tiers` is
/// the tier per candidate.
#[must_use]
pub fn rank_parking(cands: &[Candidate], cost_tiers: &[i64], max_detour: f64) -> Vec<usize> {
    let score = |i: usize| {
        let c = &cands[i];
        let tier = cost_tiers.get(i).copied().unwrap_or(1) as f64;
        c.price_per_unit.unwrap_or(tier * 4.0) + soonest(c) / 1000.0
    };
    ranked(cands, max_detour, |a, b| score(a) < score(b))
}

/// National-brand market-share order (lower = bigger), lowercase: the
/// stores' tie-break when ratings are unavailable.
pub const STORE_MARKET_SHARE_ORDER: [&str; 46] = [
    "walmart",
    "amazon fresh",
    "costco",
    "kroger",
    "home depot",
    "target",
    "lowe's",
    "lowes",
    "albertsons",
    "safeway",
    "publix",
    "aldi",
    "sam's club",
    "best buy",
    "meijer",
    "heb",
    "h-e-b",
    "dollar general",
    "dollar tree",
    "walgreens",
    "cvs",
    "whole foods",
    "trader joe",
    "menards",
    "ace hardware",
    "tractor supply",
    "petsmart",
    "petco",
    "autozone",
    "o'reilly",
    "oreilly",
    "advance auto",
    "napa",
    "bass pro",
    "cabela",
    "academy sports",
    "sportsman's warehouse",
    "scheels",
    "big 5",
    "tj maxx",
    "ross",
    "kohl's",
    "macy's",
    "nordstrom",
    "burlington",
    "marshalls",
];

/// `storeMarketShareRank(name:)`: the first brand the lowercased name
/// contains, or the table's length (after every known brand) for an unknown,
/// empty or absent name.
#[must_use]
pub fn store_market_share_rank(name: Option<&str>) -> usize {
    let Some(lower) = name.map(st::lowercased).filter(|l| !l.is_empty()) else {
        return STORE_MARKET_SHARE_ORDER.len();
    };
    STORE_MARKET_SHARE_ORDER
        .iter()
        .position(|brand| st::contains(&lower, brand))
        .unwrap_or(STORE_MARKET_SHARE_ORDER.len())
}

/// `rankStores`: highest rating first; unrated stores follow, bigger brand
/// first, then soonest reachable. `market_ranks` is
/// [`store_market_share_rank`] per candidate.
#[must_use]
pub fn rank_stores(cands: &[Candidate], market_ranks: &[usize], max_detour: f64) -> Vec<usize> {
    let lt = |a: usize, b: usize| -> bool {
        let (ca, cb) = (&cands[a], &cands[b]);
        match (ca.rating, cb.rating) {
            (Some(ra), Some(rb)) => {
                if ra != rb {
                    return ra > rb;
                }
            }
            (Some(_), None) => return true,
            (None, Some(_)) => return false,
            (None, None) => {
                let ma = market_ranks
                    .get(a)
                    .copied()
                    .unwrap_or(STORE_MARKET_SHARE_ORDER.len());
                let mb = market_ranks
                    .get(b)
                    .copied()
                    .unwrap_or(STORE_MARKET_SHARE_ORDER.len());
                if ma != mb {
                    return ma < mb;
                }
            }
        }
        soonest(ca) < soonest(cb)
    };
    ranked(cands, max_detour, lt)
}

/// `FuelType.fillUnits` and `.averagePricePerUnit` by fuel code (0 gas,
/// 1 diesel, 2 electric): the typical fill (gallons, gallons, kWh) and the
/// fleet-average unit price that keeps unpriced stations comparable.
#[must_use]
pub fn fuel_costs(fuel: u8) -> Option<(f64, f64)> {
    match fuel {
        0 => Some((15.0, 3.20)),
        1 => Some((25.0, 3.90)),
        2 => Some((60.0, 0.36)),
        _ => None,
    }
}

/// Items by straight-line meters to `center` (the kernel's distance from the
/// item), Swift's sort, the first `limit`, as (index, meters). Empty for a
/// negative limit, where the Swift trapped.
#[must_use]
pub fn rank_by_distance(points: &[Point], center: Point, limit: i64) -> Vec<(usize, f64)> {
    let Ok(limit) = usize::try_from(limit) else {
        return Vec::new();
    };
    let distances: Vec<f64> = points
        .iter()
        .map(|&p| meters(p.0, p.1, center.0, center.1))
        .collect();
    let mut order: Vec<usize> = (0..points.len()).collect();
    swift_sort_by(&mut order, |a, b| distances[a] < distances[b]);
    order
        .into_iter()
        .take(limit)
        .map(|i| (i, distances[i]))
        .collect()
}

// ============================================================ the stop search's rules

/// Stop kinds, in `POIService.Kind` declaration order.
pub mod kind {
    /// Fuel.
    pub const FUEL: u8 = 0;
    /// Food.
    pub const FOOD: u8 = 1;
    /// Stores.
    pub const STORES: u8 = 2;
    /// Tourist stops.
    pub const TOURIST: u8 = 3;
    /// Rest areas.
    pub const REST: u8 = 4;
    /// Hotels.
    pub const HOTEL: u8 = 5;
    /// Hospitals and urgent care.
    pub const MEDICAL: u8 = 6;
    /// Shelters.
    pub const SHELTER: u8 = 7;
    /// Gyms.
    pub const GYMS: u8 = 8;
    /// Trucker showers.
    pub const SHOWER: u8 = 9;
    /// Truck parking.
    pub const TRUCK_PARKING: u8 = 10;
    /// Parking.
    pub const PARKING: u8 = 11;
    /// Weigh stations.
    pub const WEIGH_STATION: u8 = 12;
    /// How many kinds there are.
    pub const COUNT: u8 = 13;
}

/// What the stop search does differently per kind.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct KindPolicy {
    /// The corridor detour cap, meters.
    pub max_detour_meters: f64,
    /// The cap in long-haul trucker mode.
    pub max_detour_trucker_meters: f64,
    /// The side of the search box around each centre, meters.
    pub region_meters: f64,
    /// The offline shard's group bytes as bits (bit `g` = group `g`); 0 when
    /// the kind is not in the dataset.
    pub shard_groups: u32,
    /// When every ranked stop is closed, the full ranked list shows anyway.
    pub closed_fallback: bool,
    /// When the ranking drops every hit, the nearest raw hits show.
    pub empty_fallback: bool,
    /// Remembered everyday stops may pin to the top.
    pub habit_pins: bool,
    /// The absolute nearest hit leads, whatever the direction.
    pub nearest_leads: bool,
    /// Ratings, price tier and hours are looked up.
    pub ratings_lookup: bool,
    /// A chain's known price tier fills in when no rating source has one.
    pub brand_cost_tier: bool,
    /// Rows carry shower availability.
    pub shower_ladder: bool,
    /// Duplicate hits are the same place by location alone.
    pub location_dedup: bool,
}

/// The per-kind rules of `POIService` (`rank`'s detour caps, `search`'s box
/// sizes, `shardGroups`, and the kind sets its fallbacks and decorations
/// test); `None` for a code past the kinds.
#[must_use]
pub fn kind_policy(k: u8) -> Option<KindPolicy> {
    use kind::*;
    if k >= COUNT {
        return None;
    }
    let (max_detour_meters, max_detour_trucker_meters) = match k {
        HOTEL | STORES => (25_000.0, 45_000.0),
        MEDICAL => (60_000.0, 60_000.0),
        TOURIST => (50_000.0, 50_000.0),
        _ => (MAX_DETOUR_METERS, 32_000.0),
    };
    let region_meters = match k {
        HOTEL => 45_000.0,
        MEDICAL => 60_000.0,
        STORES => 40_000.0,
        TOURIST => 50_000.0,
        _ => 24_000.0,
    };
    let shard_groups = match k {
        FUEL => 1 << 0,
        FOOD => 1 << 1,
        STORES => 1 << 2,
        HOTEL => 1 << 3,
        MEDICAL => 1 << 4,
        TOURIST => 1 << 5,
        REST | TRUCK_PARKING | SHOWER => 1 << 7,
        _ => 0,
    };
    let essential = matches!(k, FUEL | FOOD | MEDICAL | STORES | SHELTER);
    Some(KindPolicy {
        max_detour_meters,
        max_detour_trucker_meters,
        region_meters,
        shard_groups,
        closed_fallback: essential,
        empty_fallback: essential || matches!(k, SHOWER | REST | TRUCK_PARKING),
        habit_pins: k != MEDICAL,
        nearest_leads: k == MEDICAL,
        ratings_lookup: matches!(k, HOTEL | FOOD | STORES | GYMS | SHELTER),
        brand_cost_tier: matches!(k, FOOD | STORES | HOTEL | PARKING | GYMS),
        shower_ladder: matches!(k, FUEL | SHOWER | TRUCK_PARKING),
        location_dedup: k == WEIGH_STATION,
    })
}

/// `shardGroups(for:)`: the group bytes, ascending; `None` when the kind is
/// not in the dataset.
#[must_use]
pub fn shard_groups(k: u8) -> Option<Vec<u8>> {
    let bits = kind_policy(k)?.shard_groups;
    (bits != 0).then(|| (0..32u8).filter(|g| bits & (1 << g) != 0).collect())
}

/// Rows a ranking answers.
pub const RANKED_ROWS: usize = 8;
/// Remembered stops shown before the network answers.
pub const INSTANT_ROWS: usize = 8;
/// Raw hits shown when the ranking drops them all.
pub const FALLBACK_ROWS: usize = 12;
/// Raw hits after which a sweep stops asking more centres.
pub const SEARCH_ENOUGH_HITS: usize = 60;
/// The same, for a search by name.
pub const NAMED_ENOUGH_HITS: usize = 30;
/// Centres a search by name asks.
pub const NAMED_CENTERS: usize = 5;
/// The box side for a search by name, meters.
pub const NAMED_REGION_METERS: f64 = 30_000.0;

/// Vertices a route keeps for ranking, so the nearest-vertex search stays
/// sub-millisecond.
pub const ROUTE_MAX_VERTICES: usize = 1500;

/// `beginCorridorSearch`'s thinning: every vertex up to
/// [`ROUTE_MAX_VERTICES`], else every `count / 1500 + 1`-th.
#[must_use]
pub fn route_decimation_step(count: usize) -> usize {
    if count > ROUTE_MAX_VERTICES {
        count / ROUTE_MAX_VERTICES + 1
    } else {
        1
    }
}

/// Centres a sweep asks: fewer when each centre runs several queries.
#[must_use]
pub fn search_center_cap(query_count: usize) -> usize {
    if query_count > 1 {
        3
    } else {
        5
    }
}

/// The corridor points a sweep searches around, spread evenly: all of them
/// when they fit in `cap - 1` slots, else every `count / (cap - 1)`-th.
/// Empty for a cap under 2, where the Swift divided by zero.
#[must_use]
pub fn center_picks(count: usize, cap: usize) -> Vec<usize> {
    let slots = cap.saturating_sub(1);
    if count <= slots {
        return (0..count).collect();
    }
    if slots == 0 {
        return Vec::new();
    }
    let step = (count / slots).max(1);
    (0..count).step_by(step).take(slots).collect()
}

/// `min(by:)` on straight-line meters to `target`: the first point no later
/// point is strictly nearer than. `None` for no points.
#[must_use]
pub fn first_nearest(points: &[Point], target: Point) -> Option<usize> {
    let mut best: Option<(usize, f64)> = None;
    for (i, p) in points.iter().enumerate() {
        let d = meters(p.0, p.1, target.0, target.1);
        match best {
            None => best = Some((i, d)),
            Some((_, bd)) if d < bd => best = Some((i, d)),
            Some(_) => {}
        }
    }
    best.map(|(i, _)| i)
}

/// `EverydayPlace.attributeID`: `name|Int(lat·500)|Int(lon·500)`, a name and
/// a cell about 220 m on a side. Where the Swift trapped (a coordinate that
/// is not a number or out of `Int` range) the cell is written `-|-`.
#[must_use]
pub fn attribute_id(name: &str, latitude: f64, longitude: f64) -> String {
    match (swift_int(latitude * 500.0), swift_int(longitude * 500.0)) {
        (Some(a), Some(b)) => format!("{name}|{a}|{b}"),
        _ => format!("{name}|-|-"),
    }
}

/// The weigh-station key: `Int(lat·100)|Int(lon·100)`, about 1 km, or `-|-`.
fn location_key(p: Point) -> String {
    match (swift_int(p.0 * 100.0), swift_int(p.1 * 100.0)) {
        (Some(a), Some(b)) => format!("{a}|{b}"),
        _ => "-|-".to_string(),
    }
}

/// `search`'s dedup: the first hit of each key survives, keys comparing as
/// Swift strings (canonical equivalence). The key is the name (`?` when
/// absent) and the 220 m cell, or the 1 km cell alone when `location_only`.
#[must_use]
pub fn dedup_rows(location_only: bool, names: &[Option<&str>], points: &[Point]) -> Vec<usize> {
    let mut seen: HashSet<Vec<char>> = HashSet::new();
    (0..points.len())
        .filter(|&i| {
            let p = points[i];
            let key = if location_only {
                location_key(p)
            } else {
                attribute_id(names.get(i).copied().flatten().unwrap_or("?"), p.0, p.1)
            };
            seen.insert(st::nfd(&key))
        })
        .collect()
}

/// The habit pins: remembered rows whose key no closed row carries and,
/// once ranked rows exist, whose key a ranked row carries.
#[must_use]
pub fn pinned_rows(everyday: &[&str], closed: &[&str], ranked: &[&str]) -> Vec<usize> {
    let closed: HashSet<Vec<char>> = closed.iter().map(|k| st::nfd(k)).collect();
    let ranked_set: HashSet<Vec<char>> = ranked.iter().map(|k| st::nfd(k)).collect();
    (0..everyday.len())
        .filter(|&i| {
            let k = st::nfd(everyday[i]);
            !closed.contains(&k) && (ranked.is_empty() || ranked_set.contains(&k))
        })
        .collect()
}

/// `merged(everyday:network:)` as `(source, index)` pairs, source 0 the
/// remembered rows and 1 the network rows: remembered rows lead in their
/// order, each replaced by the first network row with its key; network rows
/// follow in ranked order; a key appears once.
#[must_use]
pub fn merge_everyday_first(everyday: &[&str], network: &[&str]) -> Vec<(u8, usize)> {
    if everyday.is_empty() {
        return (0..network.len()).map(|j| (1, j)).collect();
    }
    let network_keys: Vec<Vec<char>> = network.iter().map(|k| st::nfd(k)).collect();
    let mut first_by_key: HashMap<&[char], usize> = HashMap::new();
    for (j, k) in network_keys.iter().enumerate() {
        first_by_key.entry(k.as_slice()).or_insert(j);
    }
    let mut seen: HashSet<Vec<char>> = HashSet::new();
    let mut out = Vec::new();
    for (i, key) in everyday.iter().enumerate() {
        let k = st::nfd(key);
        let hit = first_by_key.get(k.as_slice()).copied();
        if !seen.insert(k) {
            continue;
        }
        out.push(hit.map_or((0, i), |j| (1, j)));
    }
    for (j, k) in network_keys.into_iter().enumerate() {
        if seen.insert(k) {
            out.push((1, j));
        }
    }
    out
}

/// The shower brand a stop's name names: 1 Pilot or Flying J, 2 Love's,
/// 3 TA or Petro, 0 none — matches on the lowercased name anchored the way
/// the Swift anchored them, so "Loveland" names nothing. "Vista Travel" does
/// name TA, through "ta travel": kept as the Swift answered it.
#[must_use]
pub fn shower_brand(name: &str) -> u8 {
    let lower = st::lowercased(name);
    let has = |w: &str| st::contains(&lower, w);
    if has("pilot") || has("flying j") {
        1
    } else if has("love's") || has("loves travel") {
        2
    } else if st::has_prefix(&lower, "ta ")
        || has("travelcenters")
        || has("ta travel")
        || has("petro ")
        || st::has_suffix(&lower, "petro")
    {
        3
    } else {
        0
    }
}

/// One ranked row: the item's index and its route metrics.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RankedRow {
    /// Index into the items handed in.
    pub item: usize,
    /// Meters ahead along the route (straight-line meters without a route).
    pub ahead_meters: f64,
    /// Meters off the corridor (0 without a route).
    pub detour_meters: f64,
    /// The unit price handed in.
    pub price_per_unit: Option<f64>,
    /// The rating handed in.
    pub rating: Option<f64>,
}

/// `POIService.rank` with a route: the vehicle's place along it (0 without a
/// position the route can place), each item annotated (the items, prices
/// and ratings zipped to the shortest), the kind's detour cap, then parking
/// by cost tier, stores by rating and brand, hotels by value, a chosen fuel
/// by total cost (a trucker's fill four times over), anything else soonest
/// first — the first eight. Empty for a kind code past the kinds.
#[allow(clippy::too_many_arguments)]
#[must_use]
pub fn rank_along(
    route: &RoutePath,
    k: u8,
    fuel: Option<u8>,
    trucker: bool,
    position: Option<Point>,
    items: &[Point],
    prices: &[Option<f64>],
    ratings: &[Option<f64>],
    names: &[Option<&str>],
) -> Vec<RankedRow> {
    let Some(policy) = kind_policy(k) else {
        return Vec::new();
    };
    let vehicle_along = position
        .and_then(|p| route.nearest(p))
        .map_or(0.0, |(i, _)| route.cumulative[i]);
    let n = items.len().min(prices.len()).min(ratings.len());
    let mut item_of = Vec::with_capacity(n);
    let mut cands = Vec::with_capacity(n);
    for i in 0..n {
        if let Some(c) = annotate(route, items[i], vehicle_along, prices[i], ratings[i]) {
            item_of.push(i);
            cands.push(c);
        }
    }
    let cap = if trucker {
        policy.max_detour_trucker_meters
    } else {
        policy.max_detour_meters
    };
    let name_of = |c: usize| names.get(item_of[c]).copied().flatten();
    let order = if k == kind::PARKING {
        let tiers: Vec<i64> = (0..cands.len())
            .map(|c| parking_cost_tier(name_of(c)))
            .collect();
        rank_parking(&cands, &tiers, cap)
    } else if k == kind::STORES {
        let ranks: Vec<usize> = (0..cands.len())
            .map(|c| store_market_share_rank(name_of(c)))
            .collect();
        rank_stores(&cands, &ranks, cap)
    } else if k == kind::HOTEL {
        rank_hotels(&cands, AVERAGE_NIGHTLY_PRICE, cap)
    } else if let Some((fill, average)) = fuel.and_then(fuel_costs) {
        let fill = fill * if trucker { 4.0 } else { 1.0 };
        rank_fuel(&cands, fill, average, cap)
    } else {
        rank_food(&cands, cap)
    };
    order
        .into_iter()
        .take(RANKED_ROWS)
        .map(|c| RankedRow {
            item: item_of[c],
            ahead_meters: cands[c].ahead_meters,
            detour_meters: cands[c].detour_meters,
            price_per_unit: cands[c].price_per_unit,
            rating: cands[c].rating,
        })
        .collect()
}

// ============================================================ the FPS1 shard

/// The FPS1 header length.
pub const FPS1_HEADER_LEN: usize = 32;
/// The smallest record: the fixed prefix, five empty strings, the postcode.
pub const FPS1_MIN_RECORD_LEN: usize = 24;

/// One offline place.
#[derive(Clone, Debug, PartialEq)]
pub struct Place {
    /// Latitude, from the record's `f32`.
    pub lat: f64,
    /// Longitude, from the record's `f32`.
    pub lon: f64,
    /// The dataset group (0 fuel, 1 food, 2 stores, 3 hotel, 4 medical,
    /// 5 tourist, 6 transit, 7 rest or truck stop).
    pub group: u8,
    /// Name.
    pub name: String,
    /// Street address.
    pub street: String,
    /// City.
    pub city: String,
    /// Website.
    pub website: String,
    /// Telephone.
    pub tel: String,
    /// Postcode.
    pub postcode: u32,
}

/// `PlacesShard.cellKey(lat5:lon5:)`: `(lat5 + 9000) · 100 000 + (lon5 +
/// 18 000)` for 0.2° cells; `None` where the Swift trapped on overflow.
#[must_use]
pub fn cell_key(lat5: i64, lon5: i64) -> Option<i64> {
    lat5.checked_add(9_000)?
        .checked_mul(100_000)?
        .checked_add(lon5.checked_add(18_000)?)
}

fn bytes_at<const N: usize>(d: &[u8], at: usize) -> Option<[u8; N]> {
    d.get(at..at.checked_add(N)?)?.try_into().ok()
}
fn u16_at(d: &[u8], at: usize) -> Option<u16> {
    bytes_at(d, at).map(u16::from_le_bytes)
}
fn u32_at(d: &[u8], at: usize) -> Option<u32> {
    bytes_at(d, at).map(u32::from_le_bytes)
}
fn u64_at(d: &[u8], at: usize) -> Option<u64> {
    bytes_at(d, at).map(u64::from_le_bytes)
}
fn i64_at(d: &[u8], at: usize) -> Option<i64> {
    bytes_at(d, at).map(i64::from_le_bytes)
}
fn f32_at(d: &[u8], at: usize) -> Option<f32> {
    bytes_at(d, at).map(f32::from_le_bytes)
}

/// FNV-1a, 64-bit.
#[must_use]
pub fn fnv1a64(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325_u64, |h, &b| {
        (h ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

/// The index of a validated FPS1 shard: the byte offset of every record and
/// the cell table. The shard's bytes stay with the caller and are handed to
/// each query.
#[derive(Clone, Debug)]
pub struct PlacesIndex {
    data_len: usize,
    record_offsets: Vec<u32>,
    cell_keys: Vec<i64>,
    cell_start: Vec<u32>,
    cell_count: Vec<u32>,
}

impl PlacesIndex {
    /// `PlacesShard(data:)`: the header (magic, version 1, record count, grid
    /// offset within `u32`, FNV-1a-64 over everything past the header, cell
    /// count, the grid ending the file, the record count bounded by the
    /// smallest record), then the record walk (every length in bounds, ending
    /// exactly at the grid), then the grid (every cell's records inside the
    /// table). Anything else is `None`: a corrupt shard is refused, never
    /// repaired.
    ///
    /// Deterministic; allocates the offset tables; panics: none.
    #[must_use]
    pub fn parse(data: &[u8]) -> Option<PlacesIndex> {
        if data.len() <= FPS1_HEADER_LEN || &data[..4] != b"FPS1" || u32_at(data, 4)? != 1 {
            return None;
        }
        let n_records = u32_at(data, 8)? as usize;
        let grid_offset_raw = u64_at(data, 12)?;
        if grid_offset_raw > u64::from(u32::MAX) {
            return None;
        }
        let grid_offset = grid_offset_raw as usize;
        let stored_hash = u64_at(data, 20)?;
        let n_cells = u32_at(data, 28)? as usize;
        if grid_offset < FPS1_HEADER_LEN
            || grid_offset.checked_add(n_cells.checked_mul(16)?)? != data.len()
            || n_records > (grid_offset - FPS1_HEADER_LEN) / FPS1_MIN_RECORD_LEN
        {
            return None;
        }
        if fnv1a64(&data[FPS1_HEADER_LEN..]) != stored_hash {
            return None;
        }
        let mut record_offsets = Vec::with_capacity(n_records);
        let mut off = FPS1_HEADER_LEN;
        for _ in 0..n_records {
            if off + 10 > grid_offset {
                return None;
            }
            record_offsets.push(u32::try_from(off).ok()?);
            off += 10;
            for _ in 0..5 {
                if off + 2 > grid_offset {
                    return None;
                }
                let len = usize::from(u16_at(data, off)?);
                off += 2 + len;
                if off > grid_offset {
                    return None;
                }
            }
            off += 4;
            if off > grid_offset {
                return None;
            }
        }
        if off != grid_offset {
            return None;
        }
        let mut cell_keys = Vec::with_capacity(n_cells);
        let mut cell_start = Vec::with_capacity(n_cells);
        let mut cell_count = Vec::with_capacity(n_cells);
        for c in 0..n_cells {
            let at = grid_offset + c * 16;
            cell_keys.push(i64_at(data, at)?);
            cell_start.push(u32_at(data, at + 8)?);
            cell_count.push(u32_at(data, at + 12)?);
        }
        if (0..n_cells).any(|c| cell_start[c] as usize + cell_count[c] as usize > n_records) {
            return None;
        }
        Some(PlacesIndex {
            data_len: data.len(),
            record_offsets,
            cell_keys,
            cell_start,
            cell_count,
        })
    }

    /// The record count.
    #[must_use]
    pub fn len(&self) -> usize {
        self.record_offsets.len()
    }

    /// Whether the shard holds no records.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.record_offsets.is_empty()
    }

    /// The Swift's binary search over the cell keys, verbatim, so a crafted
    /// grid with repeated or unsorted keys answers the same cell.
    fn cell_index(&self, key: i64) -> Option<usize> {
        let (mut lo, mut hi) = (0_i64, self.cell_keys.len() as i64 - 1);
        while lo <= hi {
            let mid = (lo + hi) / 2;
            let k = self.cell_keys[mid as usize];
            if k == key {
                return Some(mid as usize);
            }
            if k < key {
                lo = mid + 1;
            } else {
                hi = mid - 1;
            }
        }
        None
    }

    fn string_at(data: &[u8], off: &mut usize) -> Option<String> {
        let len = usize::from(u16_at(data, *off)?);
        *off += 2;
        let bytes = data.get(*off..*off + len)?;
        *off += len;
        Some(String::from_utf8_lossy(bytes).into_owned())
    }

    /// `decode(recordAt:)`: one record, ill-formed UTF-8 replaced as Swift's
    /// `String(decoding:as:)` replaces it. `None` past the table or for a
    /// buffer that is not the one parsed.
    #[must_use]
    pub fn place(&self, data: &[u8], index: usize) -> Option<Place> {
        if data.len() != self.data_len {
            return None;
        }
        let mut off = *self.record_offsets.get(index)? as usize;
        let lat = f32_at(data, off)?;
        let lon = f32_at(data, off + 4)?;
        let group = *data.get(off + 8)?;
        off += 10;
        let name = Self::string_at(data, &mut off)?;
        let street = Self::string_at(data, &mut off)?;
        let city = Self::string_at(data, &mut off)?;
        let website = Self::string_at(data, &mut off)?;
        let tel = Self::string_at(data, &mut off)?;
        let postcode = u32_at(data, off)?;
        Some(Place {
            lat: f64::from(lat),
            lon: f64::from(lon),
            group,
            name,
            street,
            city,
            website,
            tel,
            postcode,
        })
    }

    /// `places(near:groups:radiusMeters:limit:)`: every record of the groups
    /// within the radius, nearest first (Swift's sort), the first `limit`,
    /// as (record index, meters). Only the 0.2° cells the radius covers are
    /// walked, south to north and west to east. Empty where the Swift
    /// trapped — a centre or radius that reaches `Int` as not a number, a
    /// cell range that runs backwards, a negative limit — and for a buffer
    /// that is not the one parsed; a cell whose key overflows holds nothing.
    ///
    /// Deterministic (platform libm `cos`); panics: none.
    #[must_use]
    pub fn places_near(
        &self,
        data: &[u8],
        center: Point,
        groups: &[u8],
        radius_meters: f64,
        limit: i64,
    ) -> Vec<(usize, f64)> {
        if data.len() != self.data_len {
            return Vec::new();
        }
        let d_lat = radius_meters / METERS_PER_DEGREE;
        let d_lon =
            radius_meters / smax(METERS_PER_DEGREE * fmath::cos(center.0 * PI / 180.0), 1.0);
        let bounds = (
            swift_int(((center.0 - d_lat) * 5.0).floor()),
            swift_int(((center.0 + d_lat) * 5.0).floor()),
            swift_int(((center.1 - d_lon) * 5.0).floor()),
            swift_int(((center.1 + d_lon) * 5.0).floor()),
        );
        let (Some(lat5_lo), Some(lat5_hi), Some(lon5_lo), Some(lon5_hi)) = bounds else {
            return Vec::new();
        };
        if lat5_lo > lat5_hi || lon5_lo > lon5_hi {
            return Vec::new();
        }
        let Ok(limit) = usize::try_from(limit) else {
            return Vec::new();
        };
        let mut out: Vec<(usize, f64)> = Vec::new();
        for lat5 in lat5_lo..=lat5_hi {
            for lon5 in lon5_lo..=lon5_hi {
                let Some(ci) = cell_key(lat5, lon5).and_then(|k| self.cell_index(k)) else {
                    continue;
                };
                let start = self.cell_start[ci] as usize;
                for r in start..start + self.cell_count[ci] as usize {
                    let Some(&off) = self.record_offsets.get(r) else {
                        continue;
                    };
                    let off = off as usize;
                    let (Some(lat), Some(lon), Some(group)) =
                        (f32_at(data, off), f32_at(data, off + 4), data.get(off + 8))
                    else {
                        continue;
                    };
                    if !groups.contains(group) {
                        continue;
                    }
                    let d = meters(f64::from(lat), f64::from(lon), center.0, center.1);
                    if d <= radius_meters {
                        out.push((r, d));
                    }
                }
            }
        }
        let mut order: Vec<usize> = (0..out.len()).collect();
        swift_sort_by(&mut order, |a, b| out[a].1 < out[b].1);
        order.into_iter().take(limit).map(|k| out[k]).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn straight() -> RoutePath {
        RoutePath::new(
            (0..141)
                .map(|k| (43.0, -90.0 + f64::from(k) * 0.01))
                .collect(),
        )
    }

    #[test]
    fn the_route_grid_finds_the_nearest_vertex() {
        let route = straight();
        let (i, off) = route.nearest((43.0, -89.5)).expect("on the route");
        assert_eq!(i, 50);
        assert!(off < 1.0);
        assert_eq!(route.nearest((f64::NAN, -89.5)), None);
        assert_eq!(RoutePath::new(Vec::new()).nearest((f64::NAN, 0.0)), None);
        let (k, far) = route.nearest((50.0, -70.0)).expect("the full scan");
        assert_eq!(k, 140);
        assert!(far > 1_000_000.0);
        let doubled = RoutePath::new(vec![(43.0, -89.0), (43.0, -89.0), (43.0, -88.0)]);
        assert_eq!(
            doubled.nearest((43.0, -89.0)).map(|h| h.0),
            Some(0),
            "the lower index wins a tie"
        );
        assert_eq!(
            doubled.cumulative(),
            &[0.0, 0.0, meters(43.0, -89.0, 43.0, -88.0)]
        );
    }

    #[test]
    fn the_rankers_filter_and_order() {
        let route = straight();
        let along = route.cumulative()[70];
        let behind = annotate(&route, (43.0, -89.8), along, None, None).unwrap();
        let ahead = annotate(&route, (43.0, -89.0), along, None, None).unwrap();
        assert_eq!(rank_food(&[behind, ahead], MAX_DETOUR_METERS), vec![1]);
        let far = annotate(&route, (43.5, -89.0), 0.0, None, None).unwrap();
        let close = annotate(&route, (43.0, -89.0), 0.0, None, None).unwrap();
        assert_eq!(rank_food(&[far, close], MAX_DETOUR_METERS), vec![1]);
        let pricey = annotate(&route, (43.0, -89.9), 0.0, Some(3.80), None).unwrap();
        let cheap = annotate(&route, (43.02, -89.0), 0.0, Some(3.20), None).unwrap();
        assert_eq!(
            rank_fuel(&[pricey, cheap], 15.0, 3.50, MAX_DETOUR_METERS)[0],
            1
        );
        let plain = Candidate {
            ahead_meters: 100.0,
            detour_meters: 50.0,
            price_per_unit: None,
            rating: None,
        };
        let rated = Candidate {
            rating: Some(4.5),
            ..plain
        };
        assert_eq!(
            rank_stores(&[plain, rated], &[3, 46], MAX_DETOUR_METERS),
            vec![1, 0]
        );
        assert_eq!(
            rank_hotels(&[plain, rated], AVERAGE_NIGHTLY_PRICE, MAX_DETOUR_METERS),
            vec![1, 0]
        );
        assert_eq!(
            rank_parking(&[plain, plain], &[2, 0], MAX_DETOUR_METERS),
            vec![1, 0]
        );
        assert_eq!(parking_cost_tier(Some("Free City Lot")), 0);
        assert_eq!(parking_cost_tier(Some("Main Street Garage")), 2);
        assert_eq!(parking_cost_tier(None), 1);
        assert_eq!(store_market_share_rank(Some("Walmart Supercenter")), 0);
        assert_eq!(store_market_share_rank(Some("Bob's")), 46);
        assert_eq!(store_market_share_rank(None), 46);
        assert_eq!(fuel_costs(1), Some((25.0, 3.90)));
        assert_eq!(fuel_costs(3), None);
    }

    #[test]
    fn the_search_rules() {
        let p = kind_policy(kind::HOTEL).unwrap();
        assert_eq!(
            (
                p.max_detour_meters,
                p.max_detour_trucker_meters,
                p.region_meters
            ),
            (25_000.0, 45_000.0, 45_000.0)
        );
        assert!(!kind_policy(kind::MEDICAL).unwrap().habit_pins);
        assert!(kind_policy(kind::MEDICAL).unwrap().nearest_leads);
        assert!(kind_policy(kind::REST).unwrap().empty_fallback);
        assert!(!kind_policy(kind::REST).unwrap().closed_fallback);
        assert!(kind_policy(kind::WEIGH_STATION).unwrap().location_dedup);
        assert_eq!(kind_policy(kind::COUNT), None);
        assert_eq!(shard_groups(kind::SHOWER), Some(vec![7]));
        assert_eq!(shard_groups(kind::GYMS), None);
        assert_eq!((search_center_cap(1), search_center_cap(2)), (5, 3));
        assert_eq!(
            (
                route_decimation_step(1500),
                route_decimation_step(1501),
                route_decimation_step(4500)
            ),
            (1, 2, 4)
        );
        assert_eq!(center_picks(3, 5), vec![0, 1, 2]);
        assert_eq!(center_picks(10, 5), vec![0, 2, 4, 6]);
        assert_eq!(center_picks(10, 3), vec![0, 5]);
        assert_eq!(center_picks(4, 1), Vec::<usize>::new());
        assert_eq!(center_picks(0, 1), Vec::<usize>::new());
        assert_eq!(
            first_nearest(&[(1.0, 1.0), (0.0, 0.0), (0.0, 0.0)], (0.0, 0.0)),
            Some(1)
        );
        assert_eq!(first_nearest(&[], (0.0, 0.0)), None);
        assert_eq!(
            attribute_id("Kwik Trip", 43.07, -89.4),
            "Kwik Trip|21535|-44700"
        );
        assert_eq!(attribute_id("x", f64::NAN, 0.0), "x|-|-");
        let names = [Some("Caf\u{e9}"), Some("Cafe\u{301}"), None, Some("?")];
        let pts = [
            (43.07, -89.4),
            (43.0701, -89.4001),
            (43.07, -89.4),
            (43.07, -89.4),
        ];
        assert_eq!(dedup_rows(false, &names, &pts), vec![0, 2]);
        assert_eq!(
            dedup_rows(
                true,
                &names,
                &[(43.07, -89.4), (43.071, -89.401), (43.08, -89.4)]
            ),
            vec![0, 2]
        );
        assert_eq!(pinned_rows(&["a", "b", "c"], &["b"], &[]), vec![0, 2]);
        assert_eq!(pinned_rows(&["a", "b", "c"], &[], &["c"]), vec![2]);
        assert_eq!(
            merge_everyday_first(&["a", "b", "a"], &["c", "b", "c"]),
            vec![(0, 0), (1, 1), (1, 0)]
        );
        assert_eq!(merge_everyday_first(&[], &["c", "c"]), vec![(1, 0), (1, 1)]);
        assert_eq!(shower_brand("Pilot Travel Center"), 1);
        assert_eq!(shower_brand("Love's Travel Stop"), 2);
        assert_eq!(shower_brand("TA Travel Center"), 3);
        assert_eq!(shower_brand("Speedway Petro"), 3);
        // The original's anchored matches still read "vis-TA TRAVEL" as TA
        // (docs/RUST_SWIFT_MIGRATION.md, findings kept out of the port).
        assert_eq!(shower_brand("Vista Travel"), 3);
        assert_eq!(shower_brand("Loveland Diner"), 0);
        let order = rank_by_distance(&[(43.1, -89.4), (43.0, -89.4)], (43.0, -89.4), 8);
        assert_eq!(order[0].0, 1);
        assert!(rank_by_distance(&[(0.0, 0.0)], (0.0, 0.0), -1).is_empty());
    }

    #[test]
    fn rank_along_dispatches_by_kind_and_caps_rows() {
        let route = straight();
        let items: Vec<Point> = (0..12)
            .map(|k| (43.0, -89.9 + f64::from(k) * 0.1))
            .collect();
        let none = vec![None; 12];
        let names: Vec<Option<&str>> = vec![None; 12];
        let rows = rank_along(
            &route,
            kind::FOOD,
            None,
            false,
            Some((43.0, -90.0)),
            &items,
            &none,
            &none,
            &names,
        );
        assert_eq!(rows.len(), RANKED_ROWS);
        assert_eq!(rows[0].item, 0);
        let short = rank_along(
            &route,
            kind::FOOD,
            None,
            false,
            None,
            &items,
            &none[..3],
            &none,
            &names,
        );
        assert_eq!(short.len(), 3, "zipped to the shortest");
        assert!(rank_along(&route, 99, None, false, None, &items, &none, &none, &names).is_empty());
    }

    fn shard(recs: &[(f32, f32, u8, &str)]) -> Vec<u8> {
        let mut body: Vec<u8> = Vec::new();
        for &(lat, lon, group, name) in recs {
            body.extend_from_slice(&lat.to_le_bytes());
            body.extend_from_slice(&lon.to_le_bytes());
            body.push(group);
            body.push(0);
            for s in [name, "1 Main St", "Madison", "", ""] {
                body.extend_from_slice(&(s.len() as u16).to_le_bytes());
                body.extend_from_slice(s.as_bytes());
            }
            body.extend_from_slice(&53703u32.to_le_bytes());
        }
        let grid_offset = 32 + body.len();
        body.extend_from_slice(&cell_key(215, -447).unwrap().to_le_bytes());
        body.extend_from_slice(&0u32.to_le_bytes());
        body.extend_from_slice(&(recs.len() as u32).to_le_bytes());
        let mut d = b"FPS1".to_vec();
        d.extend_from_slice(&1u32.to_le_bytes());
        d.extend_from_slice(&(recs.len() as u32).to_le_bytes());
        d.extend_from_slice(&(grid_offset as u64).to_le_bytes());
        d.extend_from_slice(&fnv1a64(&body).to_le_bytes());
        d.extend_from_slice(&1u32.to_le_bytes());
        d.extend_from_slice(&body);
        d
    }

    #[test]
    fn the_shard_parses_queries_and_refuses_corruption() {
        let s = shard(&[
            (43.07, -89.40, 0, "Test Fuel"),
            (43.08, -89.41, 2, "Test Store"),
        ]);
        let index = PlacesIndex::parse(&s).expect("valid shard");
        assert_eq!(index.len(), 2);
        let fuel = index.places_near(&s, (43.07, -89.40), &[0], 5_000.0, 10);
        assert_eq!(fuel.len(), 1);
        assert_eq!(index.place(&s, fuel[0].0).unwrap().name, "Test Fuel");
        assert_eq!(
            index
                .places_near(&s, (43.07, -89.40), &[0, 2], 5_000.0, 10)
                .len(),
            2
        );
        assert!(index
            .places_near(&s, (33.45, -112.07), &[0], 5_000.0, 10)
            .is_empty());
        assert!(index
            .places_near(&s, (43.07, -89.40), &[0], f64::NAN, 10)
            .is_empty());
        assert!(index
            .places_near(&s, (43.07, -89.40), &[0], -50_000.0, 10)
            .is_empty());
        assert!(index
            .places_near(&s, (43.07, -89.40), &[0], 5_000.0, -1)
            .is_empty());
        assert!(
            index
                .places_near(&s[..s.len() - 1], (43.07, -89.40), &[0], 5_000.0, 10)
                .is_empty(),
            "another buffer"
        );
        let mut corrupt = s.clone();
        corrupt[40] ^= 0xFF;
        assert!(PlacesIndex::parse(&corrupt).is_none());
        assert!(PlacesIndex::parse(&s[..40]).is_none());
        let mut magic = s.clone();
        magic[0] = b'X';
        assert!(PlacesIndex::parse(&magic).is_none());
        assert_eq!(cell_key(215, -447), Some(921_517_553));
        assert_eq!(cell_key(i64::MAX, 0), None);
    }
}
