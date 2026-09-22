// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::places`: the route-aware stop ranking,
//! the FPS1 shard index and the stop search's rules. Functions are named
//! `flows_places_…`; the two opaque types' methods are Swift methods.
//!
//! Boundary encodings, chosen so nothing Swift sends can be misread:
//! - a route is [`FlowsRoutePath`], built once per leg from two coordinate
//!   columns; a stop's route metrics come back as `[ahead, detour]`, or empty
//!   when the route cannot place it;
//! - candidates cross as parallel columns, an optional as a value column and
//!   a presence column (1 or 0); rankings answer candidate indices in order;
//! - a list of texts crosses as one joined string and each text's UTF-8
//!   length (plus a presence column where a text may be nil), never a
//!   separator, so any name splits back exactly; grouped key lists add their
//!   group sizes;
//! - a shard is [`FlowsPlacesIndex`]: the offset tables only. The shard's
//!   bytes stay in Swift's memory-mapped `Data` and are lent to every call,
//!   so the mapping is never copied; a query answers record indices, and a
//!   record's numbers and texts are read by index;
//! - (index, meters) and (source, index) answers are flat pairs;
//! - a kind is its `POIService.Kind` declaration index, a fuel its
//!   `FuelType.rustCode`.
//!
//! swift-bridge must never see an empty buffer, so the facades answer the
//! empty cases themselves or send one placeholder that the counts ignore.
//! Every function is a thin forwarder through [`contain`], so a panic inside
//! the core becomes the documented fallback instead of crossing into Swift.

// The glue swift-bridge generates for an opaque type casts a pointer to its
// own type; the lint is about that generated code, not ours.
#![allow(clippy::unnecessary_cast)]

use crate::contain;
use ffi::{FlowsPlacesCellKey, FlowsPlacesKindPolicy, FlowsPlacesLimits, FlowsPlacesNearest};
use flows_core::places as pl;

#[swift_bridge::bridge]
mod ffi {
    // (swift-bridge 0.1.59 rejects doc attributes on shared structs, so these
    // are plain comments.)
    //
    // The nearest route vertex; `index` and `off_route` mean something only
    // when `has` is true.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsPlacesNearest {
        has: bool,
        index: i64,
        off_route: f64,
    }
    // A shard cell key; `key` means something only when `has` is true.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsPlacesCellKey {
        has: bool,
        key: i64,
    }
    // What the stop search does differently per kind; `has` is false past
    // the kinds. `shard_groups` holds group `g` as bit `g`, 0 = not in the
    // offline dataset.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsPlacesKindPolicy {
        has: bool,
        max_detour_meters: f64,
        max_detour_trucker_meters: f64,
        region_meters: f64,
        shard_groups: u32,
        closed_fallback: bool,
        empty_fallback: bool,
        habit_pins: bool,
        nearest_leads: bool,
        ratings_lookup: bool,
        brand_cost_tier: bool,
        shower_ladder: bool,
        location_dedup: bool,
    }
    // The ranking's constants and the search's row and hit limits.
    #[swift_bridge(swift_repr = "struct")]
    struct FlowsPlacesLimits {
        backtrack_tolerance_meters: f64,
        max_detour_meters: f64,
        detour_speed_mps: f64,
        dollars_per_hour: f64,
        average_nightly_price: f64,
        ranked_rows: i64,
        instant_rows: i64,
        fallback_rows: i64,
        search_enough_hits: i64,
        named_enough_hits: i64,
        named_centers: i64,
        named_region_meters: f64,
    }

    extern "Rust" {
        // ---- the route ----
        type FlowsRoutePath;
        fn flows_places_route_path(lats: &[f64], lons: &[f64]) -> FlowsRoutePath;
        fn flows_places_route_path_empty() -> FlowsRoutePath;
        fn cumulative(self: &FlowsRoutePath) -> Vec<f64>;
        fn nearest(self: &FlowsRoutePath, lat: f64, lon: f64) -> FlowsPlacesNearest;
        fn annotate(self: &FlowsRoutePath, lat: f64, lon: f64, vehicle_along: f64) -> Vec<f64>;
        fn rank_along(
            self: &FlowsRoutePath,
            kind: u8,
            has_fuel: bool,
            fuel: u8,
            trucker: bool,
            has_position: bool,
            lat: f64,
            lon: f64,
            item_lats: &[f64],
            item_lons: &[f64],
            prices: &[f64],
            has_price: &[u8],
            ratings: &[f64],
            has_rating: &[u8],
            names_joined: &str,
            name_lens: &[i64],
            name_present: &[u8],
        ) -> Vec<f64>;
        fn flows_places_route_decimation_step(count: i64) -> i64;

        // ---- the rankers ----
        fn flows_places_admissible(ahead_meters: f64, detour_meters: f64, max_detour: f64) -> bool;
        fn flows_places_rank_food(
            ahead: &[f64],
            detour: &[f64],
            prices: &[f64],
            has_price: &[u8],
            ratings: &[f64],
            has_rating: &[u8],
            max_detour: f64,
        ) -> Vec<i64>;
        fn flows_places_rank_fuel(
            ahead: &[f64],
            detour: &[f64],
            prices: &[f64],
            has_price: &[u8],
            ratings: &[f64],
            has_rating: &[u8],
            fill_units: f64,
            average_price_per_unit: f64,
            max_detour: f64,
        ) -> Vec<i64>;
        fn flows_places_rank_hotels(
            ahead: &[f64],
            detour: &[f64],
            prices: &[f64],
            has_price: &[u8],
            ratings: &[f64],
            has_rating: &[u8],
            average_nightly: f64,
            max_detour: f64,
        ) -> Vec<i64>;
        fn flows_places_rank_parking(
            ahead: &[f64],
            detour: &[f64],
            prices: &[f64],
            has_price: &[u8],
            ratings: &[f64],
            has_rating: &[u8],
            cost_tiers: &[i64],
            max_detour: f64,
        ) -> Vec<i64>;
        fn flows_places_rank_stores(
            ahead: &[f64],
            detour: &[f64],
            prices: &[f64],
            has_price: &[u8],
            ratings: &[f64],
            has_rating: &[u8],
            market_ranks: &[i64],
            max_detour: f64,
        ) -> Vec<i64>;
        fn flows_places_parking_cost_tier(name: &str, has_name: bool) -> i64;
        fn flows_places_store_market_share_rank(name: &str, has_name: bool) -> i64;
        fn flows_places_store_market_share_order() -> Vec<String>;
        fn flows_places_fuel_fill_units(fuel: u8) -> f64;
        fn flows_places_fuel_average_price(fuel: u8) -> f64;
        fn flows_places_limits() -> FlowsPlacesLimits;

        // ---- the stop search's rules ----
        fn flows_places_kind_policy(kind: u8) -> FlowsPlacesKindPolicy;
        fn flows_places_search_center_cap(query_count: i64) -> i64;
        fn flows_places_center_picks(count: i64, cap: i64) -> Vec<i64>;
        fn flows_places_first_nearest(lats: &[f64], lons: &[f64], lat: f64, lon: f64) -> i64;
        fn flows_places_rank_by_distance(
            lats: &[f64],
            lons: &[f64],
            lat: f64,
            lon: f64,
            limit: i64,
        ) -> Vec<f64>;
        fn flows_places_attribute_id(name: &str, latitude: f64, longitude: f64) -> String;
        fn flows_places_dedup(
            location_only: bool,
            names_joined: &str,
            name_lens: &[i64],
            name_present: &[u8],
            lats: &[f64],
            lons: &[f64],
        ) -> Vec<i64>;
        fn flows_places_pinned(
            keys_joined: &str,
            key_lens: &[i64],
            everyday_count: i64,
            closed_count: i64,
            ranked_count: i64,
        ) -> Vec<i64>;
        fn flows_places_merge(
            keys_joined: &str,
            key_lens: &[i64],
            everyday_count: i64,
            network_count: i64,
        ) -> Vec<i64>;
        fn flows_places_shower_brand(name: &str) -> u8;
        fn flows_places_truck_parking_admissible(name: &str) -> bool;

        // ---- the FPS1 shard ----
        type FlowsPlacesIndex;
        fn flows_places_index_parse(data: &[u8]) -> Option<FlowsPlacesIndex>;
        fn flows_places_cell_key(lat5: i64, lon5: i64) -> FlowsPlacesCellKey;
        fn count(self: &FlowsPlacesIndex) -> i64;
        fn places_near(
            self: &FlowsPlacesIndex,
            data: &[u8],
            lat: f64,
            lon: f64,
            groups: &[u8],
            radius_meters: f64,
            limit: i64,
        ) -> Vec<i64>;
        fn place_numbers(self: &FlowsPlacesIndex, data: &[u8], index: i64) -> Vec<f64>;
        fn place_texts(self: &FlowsPlacesIndex, data: &[u8], index: i64) -> Vec<String>;
    }
}

/// The route behind Swift's `POIRanking.RoutePath`.
pub struct FlowsRoutePath(pl::RoutePath);

/// The shard index behind Swift's `PlacesShard`; the bytes stay in Swift.
pub struct FlowsPlacesIndex(pl::PlacesIndex);

const NO_HIT: FlowsPlacesNearest = FlowsPlacesNearest {
    has: false,
    index: -1,
    off_route: f64::NAN,
};

fn as_i64(n: usize) -> i64 {
    i64::try_from(n).unwrap_or(-1)
}

fn indices(v: Vec<usize>) -> Vec<i64> {
    v.into_iter().map(as_i64).collect()
}

fn points(lats: &[f64], lons: &[f64]) -> Vec<pl::Point> {
    lats.iter().zip(lons).map(|(&a, &b)| (a, b)).collect()
}

fn optionals(values: &[f64], present: &[u8]) -> Vec<Option<f64>> {
    values
        .iter()
        .zip(present)
        .map(|(&v, &p)| (p != 0).then_some(v))
        .collect()
}

/// The candidate columns, zipped to the shortest.
fn candidates(
    ahead: &[f64],
    detour: &[f64],
    prices: &[f64],
    has_price: &[u8],
    ratings: &[f64],
    has_rating: &[u8],
) -> Vec<pl::Candidate> {
    let prices = optionals(prices, has_price);
    let ratings = optionals(ratings, has_rating);
    ahead
        .iter()
        .zip(detour)
        .zip(prices.iter().zip(&ratings))
        .map(|((&a, &d), (&p, &r))| pl::Candidate {
            ahead_meters: a,
            detour_meters: d,
            price_per_unit: p,
            rating: r,
        })
        .collect()
}

/// A joined column of texts that may be nil.
fn optional_texts<'a>(
    joined: &'a str,
    lens: &[i64],
    present: &[u8],
    count: usize,
) -> Option<Vec<Option<&'a str>>> {
    let all = crate::split_texts(joined, lens, count)?;
    (present.len() >= count).then(|| {
        all.into_iter()
            .zip(present)
            .map(|(t, &p)| (p != 0).then_some(t))
            .collect()
    })
}

pub fn flows_places_route_path(lats: &[f64], lons: &[f64]) -> FlowsRoutePath {
    FlowsRoutePath(contain(pl::RoutePath::new(Vec::new()), || {
        pl::RoutePath::new(points(lats, lons))
    }))
}

pub fn flows_places_route_path_empty() -> FlowsRoutePath {
    FlowsRoutePath(pl::RoutePath::new(Vec::new()))
}

pub fn flows_places_route_decimation_step(count: i64) -> i64 {
    as_i64(pl::route_decimation_step(
        usize::try_from(count).unwrap_or(0),
    ))
}

impl FlowsRoutePath {
    pub fn cumulative(&self) -> Vec<f64> {
        self.0.cumulative().to_vec()
    }

    pub fn nearest(&self, lat: f64, lon: f64) -> FlowsPlacesNearest {
        contain(NO_HIT, || match self.0.nearest((lat, lon)) {
            Some((i, off_route)) => FlowsPlacesNearest {
                has: true,
                index: as_i64(i),
                off_route,
            },
            None => NO_HIT,
        })
    }

    /// `[ahead, detour]`, or empty when the route cannot place the stop.
    pub fn annotate(&self, lat: f64, lon: f64, vehicle_along: f64) -> Vec<f64> {
        contain(Vec::new(), || {
            pl::annotate(&self.0, (lat, lon), vehicle_along, None, None)
                .map_or_else(Vec::new, |c| vec![c.ahead_meters, c.detour_meters])
        })
    }

    /// `POIService.rank` with this route: rows as `[item, ahead, detour]`
    /// triples, flat. Empty when the names column does not split.
    #[allow(clippy::too_many_arguments)]
    pub fn rank_along(
        &self,
        kind: u8,
        has_fuel: bool,
        fuel: u8,
        trucker: bool,
        has_position: bool,
        lat: f64,
        lon: f64,
        item_lats: &[f64],
        item_lons: &[f64],
        prices: &[f64],
        has_price: &[u8],
        ratings: &[f64],
        has_rating: &[u8],
        names_joined: &str,
        name_lens: &[i64],
        name_present: &[u8],
    ) -> Vec<f64> {
        contain(Vec::new(), || {
            let items = points(item_lats, item_lons);
            let Some(names) = optional_texts(names_joined, name_lens, name_present, items.len())
            else {
                return Vec::new();
            };
            pl::rank_along(
                &self.0,
                kind,
                has_fuel.then_some(fuel),
                trucker,
                has_position.then_some((lat, lon)),
                &items,
                &optionals(prices, has_price),
                &optionals(ratings, has_rating),
                &names,
            )
            .into_iter()
            .flat_map(|r| [r.item as f64, r.ahead_meters, r.detour_meters])
            .collect()
        })
    }
}

pub fn flows_places_admissible(ahead_meters: f64, detour_meters: f64, max_detour: f64) -> bool {
    pl::admissible(
        &pl::Candidate {
            ahead_meters,
            detour_meters,
            price_per_unit: None,
            rating: None,
        },
        max_detour,
    )
}

pub fn flows_places_rank_food(
    ahead: &[f64],
    detour: &[f64],
    prices: &[f64],
    has_price: &[u8],
    ratings: &[f64],
    has_rating: &[u8],
    max_detour: f64,
) -> Vec<i64> {
    contain(Vec::new(), || {
        let c = candidates(ahead, detour, prices, has_price, ratings, has_rating);
        indices(pl::rank_food(&c, max_detour))
    })
}

#[allow(clippy::too_many_arguments)]
pub fn flows_places_rank_fuel(
    ahead: &[f64],
    detour: &[f64],
    prices: &[f64],
    has_price: &[u8],
    ratings: &[f64],
    has_rating: &[u8],
    fill_units: f64,
    average_price_per_unit: f64,
    max_detour: f64,
) -> Vec<i64> {
    contain(Vec::new(), || {
        let c = candidates(ahead, detour, prices, has_price, ratings, has_rating);
        indices(pl::rank_fuel(
            &c,
            fill_units,
            average_price_per_unit,
            max_detour,
        ))
    })
}

#[allow(clippy::too_many_arguments)]
pub fn flows_places_rank_hotels(
    ahead: &[f64],
    detour: &[f64],
    prices: &[f64],
    has_price: &[u8],
    ratings: &[f64],
    has_rating: &[u8],
    average_nightly: f64,
    max_detour: f64,
) -> Vec<i64> {
    contain(Vec::new(), || {
        let c = candidates(ahead, detour, prices, has_price, ratings, has_rating);
        indices(pl::rank_hotels(&c, average_nightly, max_detour))
    })
}

#[allow(clippy::too_many_arguments)]
pub fn flows_places_rank_parking(
    ahead: &[f64],
    detour: &[f64],
    prices: &[f64],
    has_price: &[u8],
    ratings: &[f64],
    has_rating: &[u8],
    cost_tiers: &[i64],
    max_detour: f64,
) -> Vec<i64> {
    contain(Vec::new(), || {
        let c = candidates(ahead, detour, prices, has_price, ratings, has_rating);
        indices(pl::rank_parking(&c, cost_tiers, max_detour))
    })
}

#[allow(clippy::too_many_arguments)]
pub fn flows_places_rank_stores(
    ahead: &[f64],
    detour: &[f64],
    prices: &[f64],
    has_price: &[u8],
    ratings: &[f64],
    has_rating: &[u8],
    market_ranks: &[i64],
    max_detour: f64,
) -> Vec<i64> {
    contain(Vec::new(), || {
        let c = candidates(ahead, detour, prices, has_price, ratings, has_rating);
        let ranks: Vec<usize> = market_ranks
            .iter()
            .map(|&r| usize::try_from(r).unwrap_or(usize::MAX))
            .collect();
        indices(pl::rank_stores(&c, &ranks, max_detour))
    })
}

pub fn flows_places_parking_cost_tier(name: &str, has_name: bool) -> i64 {
    contain(1, || pl::parking_cost_tier(has_name.then_some(name)))
}

pub fn flows_places_store_market_share_rank(name: &str, has_name: bool) -> i64 {
    contain(as_i64(pl::STORE_MARKET_SHARE_ORDER.len()), || {
        as_i64(pl::store_market_share_rank(has_name.then_some(name)))
    })
}

pub fn flows_places_store_market_share_order() -> Vec<String> {
    pl::STORE_MARKET_SHARE_ORDER
        .iter()
        .map(|b| (*b).to_string())
        .collect()
}

/// The typical fill for a fuel code; NaN past the fuels.
pub fn flows_places_fuel_fill_units(fuel: u8) -> f64 {
    pl::fuel_costs(fuel).map_or(f64::NAN, |c| c.0)
}

/// The fleet-average unit price for a fuel code; NaN past the fuels.
pub fn flows_places_fuel_average_price(fuel: u8) -> f64 {
    pl::fuel_costs(fuel).map_or(f64::NAN, |c| c.1)
}

pub fn flows_places_limits() -> FlowsPlacesLimits {
    FlowsPlacesLimits {
        backtrack_tolerance_meters: pl::BACKTRACK_TOLERANCE_METERS,
        max_detour_meters: pl::MAX_DETOUR_METERS,
        detour_speed_mps: pl::DETOUR_SPEED_MPS,
        dollars_per_hour: pl::DOLLARS_PER_HOUR,
        average_nightly_price: pl::AVERAGE_NIGHTLY_PRICE,
        ranked_rows: as_i64(pl::RANKED_ROWS),
        instant_rows: as_i64(pl::INSTANT_ROWS),
        fallback_rows: as_i64(pl::FALLBACK_ROWS),
        search_enough_hits: as_i64(pl::SEARCH_ENOUGH_HITS),
        named_enough_hits: as_i64(pl::NAMED_ENOUGH_HITS),
        named_centers: as_i64(pl::NAMED_CENTERS),
        named_region_meters: pl::NAMED_REGION_METERS,
    }
}

pub fn flows_places_kind_policy(kind: u8) -> FlowsPlacesKindPolicy {
    match pl::kind_policy(kind) {
        Some(p) => FlowsPlacesKindPolicy {
            has: true,
            max_detour_meters: p.max_detour_meters,
            max_detour_trucker_meters: p.max_detour_trucker_meters,
            region_meters: p.region_meters,
            shard_groups: p.shard_groups,
            closed_fallback: p.closed_fallback,
            empty_fallback: p.empty_fallback,
            habit_pins: p.habit_pins,
            nearest_leads: p.nearest_leads,
            ratings_lookup: p.ratings_lookup,
            brand_cost_tier: p.brand_cost_tier,
            shower_ladder: p.shower_ladder,
            location_dedup: p.location_dedup,
        },
        None => FlowsPlacesKindPolicy {
            has: false,
            max_detour_meters: pl::MAX_DETOUR_METERS,
            max_detour_trucker_meters: pl::MAX_DETOUR_METERS,
            region_meters: 0.0,
            shard_groups: 0,
            closed_fallback: false,
            empty_fallback: false,
            habit_pins: false,
            nearest_leads: false,
            ratings_lookup: false,
            brand_cost_tier: false,
            shower_ladder: false,
            location_dedup: false,
        },
    }
}

pub fn flows_places_search_center_cap(query_count: i64) -> i64 {
    as_i64(pl::search_center_cap(
        usize::try_from(query_count).unwrap_or(0),
    ))
}

pub fn flows_places_center_picks(count: i64, cap: i64) -> Vec<i64> {
    contain(Vec::new(), || {
        indices(pl::center_picks(
            usize::try_from(count).unwrap_or(0),
            usize::try_from(cap).unwrap_or(0),
        ))
    })
}

/// The first nearest point's index; -1 for no points.
pub fn flows_places_first_nearest(lats: &[f64], lons: &[f64], lat: f64, lon: f64) -> i64 {
    contain(-1, || {
        pl::first_nearest(&points(lats, lons), (lat, lon)).map_or(-1, as_i64)
    })
}

/// `[index, meters]` pairs, nearest first, the first `limit`.
pub fn flows_places_rank_by_distance(
    lats: &[f64],
    lons: &[f64],
    lat: f64,
    lon: f64,
    limit: i64,
) -> Vec<f64> {
    contain(Vec::new(), || {
        pl::rank_by_distance(&points(lats, lons), (lat, lon), limit)
            .into_iter()
            .flat_map(|(i, m)| [i as f64, m])
            .collect()
    })
}

pub fn flows_places_attribute_id(name: &str, latitude: f64, longitude: f64) -> String {
    contain(format!("{name}|-|-"), || {
        pl::attribute_id(name, latitude, longitude)
    })
}

/// The surviving row indices; empty when the names column does not split.
pub fn flows_places_dedup(
    location_only: bool,
    names_joined: &str,
    name_lens: &[i64],
    name_present: &[u8],
    lats: &[f64],
    lons: &[f64],
) -> Vec<i64> {
    contain(Vec::new(), || {
        let pts = points(lats, lons);
        optional_texts(names_joined, name_lens, name_present, pts.len())
            .map_or_else(Vec::new, |names| {
                indices(pl::dedup_rows(location_only, &names, &pts))
            })
    })
}

/// The remembered rows that keep their pin; the key column holds the
/// remembered, closed and ranked keys in that order.
pub fn flows_places_pinned(
    keys_joined: &str,
    key_lens: &[i64],
    everyday_count: i64,
    closed_count: i64,
    ranked_count: i64,
) -> Vec<i64> {
    contain(Vec::new(), || {
        let (Ok(e), Ok(c), Ok(r)) = (
            usize::try_from(everyday_count),
            usize::try_from(closed_count),
            usize::try_from(ranked_count),
        ) else {
            return Vec::new();
        };
        let Some(keys) = e
            .checked_add(c)
            .and_then(|n| n.checked_add(r))
            .and_then(|n| crate::split_texts(keys_joined, key_lens, n))
        else {
            return Vec::new();
        };
        indices(pl::pinned_rows(&keys[..e], &keys[e..e + c], &keys[e + c..]))
    })
}

/// `[source, index]` pairs (0 remembered, 1 network); the key column holds
/// the remembered keys, then the network keys.
pub fn flows_places_merge(
    keys_joined: &str,
    key_lens: &[i64],
    everyday_count: i64,
    network_count: i64,
) -> Vec<i64> {
    contain(Vec::new(), || {
        let (Ok(e), Ok(n)) = (
            usize::try_from(everyday_count),
            usize::try_from(network_count),
        ) else {
            return Vec::new();
        };
        let Some(keys) = e
            .checked_add(n)
            .and_then(|t| crate::split_texts(keys_joined, key_lens, t))
        else {
            return Vec::new();
        };
        pl::merge_everyday_first(&keys[..e], &keys[e..])
            .into_iter()
            .flat_map(|(source, i)| [i64::from(source), as_i64(i)])
            .collect()
    })
}

pub fn flows_places_shower_brand(name: &str) -> u8 {
    contain(0, || pl::shower_brand(name))
}

/// Whether a truck-parking hit is somewhere a truck can park; false on
/// containment (a car park is not offered to a truck).
pub fn flows_places_truck_parking_admissible(name: &str) -> bool {
    contain(false, || pl::truck_parking_admissible(name))
}

pub fn flows_places_index_parse(data: &[u8]) -> Option<FlowsPlacesIndex> {
    contain(None, || pl::PlacesIndex::parse(data).map(FlowsPlacesIndex))
}

pub fn flows_places_cell_key(lat5: i64, lon5: i64) -> FlowsPlacesCellKey {
    match pl::cell_key(lat5, lon5) {
        Some(key) => FlowsPlacesCellKey { has: true, key },
        None => FlowsPlacesCellKey { has: false, key: 0 },
    }
}

impl FlowsPlacesIndex {
    pub fn count(&self) -> i64 {
        as_i64(self.0.len())
    }

    /// Record indices, nearest first.
    pub fn places_near(
        &self,
        data: &[u8],
        lat: f64,
        lon: f64,
        groups: &[u8],
        radius_meters: f64,
        limit: i64,
    ) -> Vec<i64> {
        contain(Vec::new(), || {
            self.0
                .places_near(data, (lat, lon), groups, radius_meters, limit)
                .into_iter()
                .map(|(r, _)| as_i64(r))
                .collect()
        })
    }

    /// `[lat, lon, group, postcode]`, or empty past the table.
    pub fn place_numbers(&self, data: &[u8], index: i64) -> Vec<f64> {
        contain(Vec::new(), || {
            usize::try_from(index)
                .ok()
                .and_then(|i| self.0.place(data, i))
                .map_or_else(Vec::new, |p| {
                    vec![p.lat, p.lon, f64::from(p.group), f64::from(p.postcode)]
                })
        })
    }

    /// `[name, street, city, website, tel]`, or empty past the table.
    pub fn place_texts(&self, data: &[u8], index: i64) -> Vec<String> {
        contain(Vec::new(), || {
            usize::try_from(index)
                .ok()
                .and_then(|i| self.0.place(data, i))
                .map_or_else(Vec::new, |p| {
                    vec![p.name, p.street, p.city, p.website, p.tel]
                })
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_columns_split_by_length_and_refuse_bad_lengths() {
        assert_eq!(
            crate::split_texts("a|bcé", &[2, 4], 2),
            Some(vec!["a|", "bcé"])
        );
        assert_eq!(crate::split_texts("abc", &[1, 1, 1], 0), Some(vec![]));
        assert_eq!(
            crate::split_texts("é", &[1], 1),
            None,
            "a length that splits a character"
        );
        assert_eq!(crate::split_texts("abc", &[-1], 1), None);
        assert_eq!(crate::split_texts("abc", &[4], 1), None);
        assert_eq!(
            optional_texts("ab", &[1, 1], &[1, 0], 2),
            Some(vec![Some("a"), None])
        );
    }

    #[test]
    fn grouped_key_columns_pin_and_merge() {
        // remembered a, b, c; closed b; ranked a, c
        assert_eq!(flows_places_pinned("abcbac", &[1; 6], 3, 1, 2), vec![0, 2]);
        assert_eq!(flows_places_merge("abba", &[1; 4], 2, 2), vec![1, 1, 1, 0]);
        assert!(
            flows_places_merge("ab", &[1, 1], 2, 2).is_empty(),
            "a short column"
        );
    }

    #[test]
    fn the_route_crosses_whole() {
        let route = flows_places_route_path(&[43.0, 43.0], &[-89.0, -88.9]);
        assert_eq!(route.cumulative().len(), 2);
        assert!(route.nearest(43.0, -89.0).has);
        assert!(!flows_places_route_path_empty().nearest(43.0, -89.0).has);
        assert_eq!(route.annotate(f64::NAN, 0.0, 0.0), Vec::<f64>::new());
        let rows = route.rank_along(
            1,
            false,
            0,
            false,
            false,
            0.0,
            0.0,
            &[43.0],
            &[-88.95],
            &[0.0],
            &[0],
            &[0.0],
            &[0],
            "",
            &[0],
            &[0],
        );
        assert_eq!(rows.len(), 3);
        assert!(!flows_places_kind_policy(13).has);
        assert_eq!(flows_places_limits().ranked_rows, 8);
    }
}
