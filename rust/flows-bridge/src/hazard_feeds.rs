// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::hazard_feeds`: the live feed scores, the
//! snapshot they are read from, the alert service's rules and the CRE fuel
//! scan. Functions are named `flows_hazard_…`.
//!
//! Points cross as parallel `lats`/`lons` lists and rings as one flat pair
//! of lists with `ring_lens` in front; a list of zones adds `zone_ring_counts`.
//! Text lists are joined by U+001F. swift-bridge must never see an empty
//! buffer, so a facade answers the empty case itself (no feed scores 0) or
//! passes a one-element placeholder the counts ignore.
//!
//! The snapshot is one opaque type, [`FlowsHazardSnapshot`], built once from
//! the fetched feeds and then scored per point in place; `clipped` answers a
//! new one and the getters read its lists back for the facade's own copy.
//! Optional answers are `-1` for no index and the empty string for no key.
//! Every forwarder runs through [`contain`].

// The glue swift-bridge generates for `&mut self` methods on an opaque type
// casts a pointer to its own type; the lint is about that generated code.
#![allow(clippy::unnecessary_cast)]

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        // ---- scalar tables ----
        fn flows_hazard_air_score(us_aqi: f64) -> f64;
        fn flows_hazard_uv_score(index: f64) -> f64;
        fn flows_hazard_space_weather_score(scale: i64) -> f64;
        fn flows_hazard_radiation_space_weather_score(
            s_scale: i64,
            g_scale: i64,
            latitude: f64,
        ) -> f64;
        fn flows_hazard_volcano_alert_score(level: &str) -> f64;
        fn flows_hazard_avalanche_rating_score(rating: i64) -> f64;
        fn flows_hazard_tropical_intensity_score(max_wind_kt: f64) -> f64;
        fn flows_hazard_tsunami_level_score(level: &str) -> f64;
        fn flows_hazard_spc_categorical_score(dn: i64) -> f64;
        fn flows_hazard_flood_category_score(category: &str) -> f64;
        fn flows_hazard_severity_score(severity: &str) -> f64;
        fn flows_hazard_backup_severity(phenomena: &str) -> f64;

        // ---- point lists ----
        fn flows_hazard_fire_score(
            lats: &[f64],
            lons: &[f64],
            frps: &[f64],
            lat: f64,
            lon: f64,
        ) -> f64;
        fn flows_hazard_seismic_score(
            lats: &[f64],
            lons: &[f64],
            magnitudes: &[f64],
            age_hours: &[f64],
            lat: f64,
            lon: f64,
        ) -> f64;
        fn flows_hazard_water_proximity_score(
            lats: &[f64],
            lons: &[f64],
            lat: f64,
            lon: f64,
        ) -> f64;
        fn flows_hazard_closure_score(lats: &[f64], lons: &[f64], lat: f64, lon: f64) -> f64;
        fn flows_hazard_tropical_score(
            lats: &[f64],
            lons: &[f64],
            max_wind_kts: &[f64],
            lat: f64,
            lon: f64,
        ) -> f64;
        fn flows_hazard_flood_gauge_score(
            lats: &[f64],
            lons: &[f64],
            categories_joined: &str,
            lat: f64,
            lon: f64,
        ) -> f64;
        fn flows_hazard_volcanic_score(
            lats: &[f64],
            lons: &[f64],
            levels_joined: &str,
            lat: f64,
            lon: f64,
        ) -> f64;
        fn flows_hazard_tsunami_score(
            lats: &[f64],
            lons: &[f64],
            levels_joined: &str,
            lat: f64,
            lon: f64,
        ) -> f64;

        // ---- rings ----
        fn flows_hazard_point_in_polygon(lats: &[f64], lons: &[f64], lat: f64, lon: f64) -> bool;
        fn flows_hazard_ring_contains(lats: &[f64], lons: &[f64], lat: f64, lon: f64) -> bool;
        fn flows_hazard_fire_perimeter_score(
            ring_lens: &[i64],
            lats: &[f64],
            lons: &[f64],
            lat: f64,
            lon: f64,
        ) -> f64;
        fn flows_hazard_avalanche_score(
            zone_ring_counts: &[i64],
            ratings: &[i64],
            ring_lens: &[i64],
            lats: &[f64],
            lons: &[f64],
            lat: f64,
            lon: f64,
        ) -> f64;
        fn flows_hazard_outlook_score(
            zone_ring_counts: &[i64],
            scores: &[f64],
            ring_lens: &[i64],
            lats: &[f64],
            lons: &[f64],
            lat: f64,
            lon: f64,
        ) -> f64;

        // ---- the alert service ----
        fn flows_hazard_cell_key(lat: f64, lon: f64) -> String;
        fn flows_hazard_states_containing(lat: f64, lon: f64) -> Vec<String>;
        fn flows_hazard_marine_regions_containing(lat: f64, lon: f64) -> Vec<String>;
        fn flows_hazard_provisional_samples(
            sample_lats: &[f64],
            sample_lons: &[f64],
            alert_severities: &[f64],
            alert_expires: &[f64],
            alert_has_expires: &[i64],
            cell_keys_joined: &str,
            cell_alert_counts: &[i64],
            cell_alert_indices: &[i64],
            arrival_offsets: &[f64],
            has_offsets: bool,
            now: f64,
        ) -> Vec<f64>;
        fn flows_hazard_alerts_covering(
            lat: f64,
            lon: f64,
            alert_ring_counts: &[i64],
            alert_zone_counts: &[i64],
            ring_lens: &[i64],
            lats: &[f64],
            lons: &[f64],
            alert_zones_joined: &str,
            zone_names_joined: &str,
            zone_ring_counts: &[i64],
            zone_ring_lens: &[i64],
            zone_lats: &[f64],
            zone_lons: &[f64],
        ) -> Vec<i64>;
        fn flows_hazard_all_rings(
            ring_coord_counts: &[i64],
            coord_lens: &[i64],
            values: &[f64],
            max_points: i64,
        ) -> Vec<f64>;
        fn flows_hazard_corridor_noisy_or(severities: &[f64], coverages: &[f64]) -> f64;
        fn flows_hazard_corridor_coverage(risks: &[f64]) -> f64;
        fn flows_hazard_worst_first(severities: &[f64]) -> Vec<i64>;

        // ---- the CRE fuel files ----
        fn flows_hazard_fuel_prices(xml: &str) -> Vec<String>;
        fn flows_hazard_fuel_places(xml: &str) -> Vec<String>;

        // ---- the live snapshot ----
        fn flows_hazard_clip_margin_degrees() -> f64;
        type FlowsHazardSnapshot;
        fn flows_hazard_snapshot_new() -> FlowsHazardSnapshot;
        fn add_hotspots(self: &mut FlowsHazardSnapshot, lats: &[f64], lons: &[f64], frps: &[f64]);
        fn add_perimeters(
            self: &mut FlowsHazardSnapshot,
            ring_lens: &[i64],
            lats: &[f64],
            lons: &[f64],
        );
        fn add_quakes(
            self: &mut FlowsHazardSnapshot,
            lats: &[f64],
            lons: &[f64],
            magnitudes: &[f64],
            age_hours: &[f64],
        );
        fn set_space(self: &mut FlowsHazardSnapshot, r: i64, s: i64, g: i64);
        fn add_volcanoes(
            self: &mut FlowsHazardSnapshot,
            lats: &[f64],
            lons: &[f64],
            levels_joined: &str,
        );
        fn add_avalanche_zones(
            self: &mut FlowsHazardSnapshot,
            zone_ring_counts: &[i64],
            ratings: &[i64],
            ring_lens: &[i64],
            lats: &[f64],
            lons: &[f64],
        );
        fn add_storms(
            self: &mut FlowsHazardSnapshot,
            lats: &[f64],
            lons: &[f64],
            max_wind_kts: &[f64],
        );
        fn add_tsunamis(
            self: &mut FlowsHazardSnapshot,
            lats: &[f64],
            lons: &[f64],
            levels_joined: &str,
        );
        fn add_spc_zones(
            self: &mut FlowsHazardSnapshot,
            zone_ring_counts: &[i64],
            scores: &[f64],
            ring_lens: &[i64],
            lats: &[f64],
            lons: &[f64],
        );
        fn clipped(
            self: &FlowsHazardSnapshot,
            min_lat: f64,
            min_lon: f64,
            max_lat: f64,
            max_lon: f64,
        ) -> FlowsHazardSnapshot;
        fn live(self: &FlowsHazardSnapshot, lat: f64, lon: f64) -> Vec<f64>;
        fn hotspots_flat(self: &FlowsHazardSnapshot) -> Vec<f64>;
        fn perimeters_flat(self: &FlowsHazardSnapshot) -> Vec<f64>;
        fn quakes_flat(self: &FlowsHazardSnapshot) -> Vec<f64>;
        fn space(self: &FlowsHazardSnapshot) -> Vec<i64>;
        fn volcanoes_flat(self: &FlowsHazardSnapshot) -> Vec<f64>;
        fn volcano_levels(self: &FlowsHazardSnapshot) -> Vec<String>;
        fn avalanche_zones_flat(self: &FlowsHazardSnapshot) -> Vec<f64>;
        fn avalanche_ratings(self: &FlowsHazardSnapshot) -> Vec<i64>;
        fn storms_flat(self: &FlowsHazardSnapshot) -> Vec<f64>;
        fn tsunamis_flat(self: &FlowsHazardSnapshot) -> Vec<f64>;
        fn tsunami_levels(self: &FlowsHazardSnapshot) -> Vec<String>;
        fn spc_zones_flat(self: &FlowsHazardSnapshot) -> Vec<f64>;
        fn spc_scores(self: &FlowsHazardSnapshot) -> Vec<f64>;
    }
}

use crate::contain;
use flows_core::hazard_feeds as hf;
use flows_core::hazard_feeds::{Alert, Point, Snapshot};
use std::collections::BTreeMap;

const JOIN: char = '\u{1F}';

fn split_joined(joined: &str) -> Vec<String> {
    if joined.is_empty() {
        Vec::new()
    } else {
        joined.split(JOIN).map(str::to_string).collect()
    }
}
fn points(lats: &[f64], lons: &[f64]) -> Vec<Point> {
    lats.iter().copied().zip(lons.iter().copied()).collect()
}
fn triples(lats: &[f64], lons: &[f64], third: &[f64]) -> Vec<(f64, f64, f64)> {
    lats.iter()
        .zip(lons)
        .zip(third)
        .map(|((&a, &b), &c)| (a, b, c))
        .collect()
}
fn named(lats: &[f64], lons: &[f64], joined: &str) -> Vec<(f64, f64, String)> {
    lats.iter()
        .zip(lons)
        .zip(split_joined(joined))
        .map(|((&a, &b), s)| (a, b, s))
        .collect()
}
fn count(n: i64) -> usize {
    usize::try_from(n).unwrap_or(0)
}
/// Rings from `ring_lens` over one flat pair of lists.
fn rings(ring_lens: &[i64], lats: &[f64], lons: &[f64]) -> Vec<Vec<Point>> {
    let pts = points(lats, lons);
    let mut at = 0usize;
    ring_lens
        .iter()
        .map(|&len| {
            let n = count(len).min(pts.len().saturating_sub(at));
            let ring = pts[at..at + n].to_vec();
            at += n;
            ring
        })
        .collect()
}
/// Zones as groups of rings.
fn zones(
    zone_ring_counts: &[i64],
    ring_lens: &[i64],
    lats: &[f64],
    lons: &[f64],
) -> Vec<Vec<Vec<Point>>> {
    let all = rings(ring_lens, lats, lons);
    let mut at = 0usize;
    zone_ring_counts
        .iter()
        .map(|&c| {
            let n = count(c).min(all.len().saturating_sub(at));
            let zone = all[at..at + n].to_vec();
            at += n;
            zone
        })
        .collect()
}
fn as_i64(n: usize) -> i64 {
    i64::try_from(n).unwrap_or(-1)
}
/// Rings flattened with their shape in front: `[n, len_1, …, len_n, lat, lon, …]`.
fn flat_rings(rings: &[Vec<Point>]) -> Vec<f64> {
    let mut out = vec![rings.len() as f64];
    out.extend(rings.iter().map(|r| r.len() as f64));
    for r in rings {
        for &(lat, lon) in r {
            out.push(lat);
            out.push(lon);
        }
    }
    out
}
/// Zones flattened: `[n_zones, rings_1, …, rings_n, <flat rings of all zones>]`.
fn flat_zones(zones: &[Vec<Vec<Point>>]) -> Vec<f64> {
    let mut out = vec![zones.len() as f64];
    out.extend(zones.iter().map(|z| z.len() as f64));
    let all: Vec<Vec<Point>> = zones.iter().flatten().cloned().collect();
    out.extend(flat_rings(&all));
    out
}

// ---- scalar tables: NaN is the fallback for a score, as for every equation ----

pub fn flows_hazard_air_score(us_aqi: f64) -> f64 {
    contain(f64::NAN, || hf::air_score(us_aqi))
}
pub fn flows_hazard_uv_score(index: f64) -> f64 {
    contain(f64::NAN, || hf::uv_score(index))
}
pub fn flows_hazard_space_weather_score(scale: i64) -> f64 {
    contain(f64::NAN, || hf::space_weather_score(scale))
}
pub fn flows_hazard_radiation_space_weather_score(
    s_scale: i64,
    g_scale: i64,
    latitude: f64,
) -> f64 {
    contain(f64::NAN, || {
        hf::radiation_space_weather_score(s_scale, g_scale, latitude)
    })
}
pub fn flows_hazard_volcano_alert_score(level: &str) -> f64 {
    contain(f64::NAN, || hf::volcano_alert_score(level))
}
pub fn flows_hazard_avalanche_rating_score(rating: i64) -> f64 {
    contain(f64::NAN, || hf::avalanche_rating_score(rating))
}
pub fn flows_hazard_tropical_intensity_score(max_wind_kt: f64) -> f64 {
    contain(f64::NAN, || hf::tropical_intensity_score(max_wind_kt))
}
pub fn flows_hazard_tsunami_level_score(level: &str) -> f64 {
    contain(f64::NAN, || hf::tsunami_level_score(level))
}
pub fn flows_hazard_spc_categorical_score(dn: i64) -> f64 {
    contain(f64::NAN, || hf::spc_categorical_score(dn))
}
pub fn flows_hazard_flood_category_score(category: &str) -> f64 {
    contain(f64::NAN, || hf::flood_category_score(category))
}
pub fn flows_hazard_severity_score(severity: &str) -> f64 {
    contain(f64::NAN, || hf::severity_score(severity))
}
pub fn flows_hazard_backup_severity(phenomena: &str) -> f64 {
    contain(f64::NAN, || hf::backup_severity(phenomena))
}

// ---- point lists ----

pub fn flows_hazard_fire_score(
    lats: &[f64],
    lons: &[f64],
    frps: &[f64],
    lat: f64,
    lon: f64,
) -> f64 {
    contain(f64::NAN, || {
        hf::fire_score(&triples(lats, lons, frps), (lat, lon))
    })
}
pub fn flows_hazard_seismic_score(
    lats: &[f64],
    lons: &[f64],
    magnitudes: &[f64],
    age_hours: &[f64],
    lat: f64,
    lon: f64,
) -> f64 {
    contain(f64::NAN, || {
        let quakes: Vec<(f64, f64, f64, f64)> = lats
            .iter()
            .zip(lons)
            .zip(magnitudes)
            .zip(age_hours)
            .map(|(((&a, &b), &m), &h)| (a, b, m, h))
            .collect();
        hf::seismic_score(&quakes, (lat, lon))
    })
}
pub fn flows_hazard_water_proximity_score(lats: &[f64], lons: &[f64], lat: f64, lon: f64) -> f64 {
    contain(f64::NAN, || {
        hf::water_proximity_score(&points(lats, lons), (lat, lon))
    })
}
pub fn flows_hazard_closure_score(lats: &[f64], lons: &[f64], lat: f64, lon: f64) -> f64 {
    contain(f64::NAN, || {
        hf::closure_score(&points(lats, lons), (lat, lon))
    })
}
pub fn flows_hazard_tropical_score(
    lats: &[f64],
    lons: &[f64],
    max_wind_kts: &[f64],
    lat: f64,
    lon: f64,
) -> f64 {
    contain(f64::NAN, || {
        hf::tropical_score(&triples(lats, lons, max_wind_kts), (lat, lon))
    })
}
pub fn flows_hazard_flood_gauge_score(
    lats: &[f64],
    lons: &[f64],
    categories_joined: &str,
    lat: f64,
    lon: f64,
) -> f64 {
    contain(f64::NAN, || {
        hf::flood_gauge_score(&named(lats, lons, categories_joined), (lat, lon))
    })
}
pub fn flows_hazard_volcanic_score(
    lats: &[f64],
    lons: &[f64],
    levels_joined: &str,
    lat: f64,
    lon: f64,
) -> f64 {
    contain(f64::NAN, || {
        hf::volcanic_score(&named(lats, lons, levels_joined), (lat, lon))
    })
}
pub fn flows_hazard_tsunami_score(
    lats: &[f64],
    lons: &[f64],
    levels_joined: &str,
    lat: f64,
    lon: f64,
) -> f64 {
    contain(f64::NAN, || {
        hf::tsunami_score(&named(lats, lons, levels_joined), (lat, lon))
    })
}

// ---- rings ----

pub fn flows_hazard_point_in_polygon(lats: &[f64], lons: &[f64], lat: f64, lon: f64) -> bool {
    contain(false, || {
        hf::point_in_polygon((lat, lon), &points(lats, lons))
    })
}
pub fn flows_hazard_ring_contains(lats: &[f64], lons: &[f64], lat: f64, lon: f64) -> bool {
    contain(false, || hf::ring_contains((lat, lon), &points(lats, lons)))
}
pub fn flows_hazard_fire_perimeter_score(
    ring_lens: &[i64],
    lats: &[f64],
    lons: &[f64],
    lat: f64,
    lon: f64,
) -> f64 {
    contain(f64::NAN, || {
        hf::fire_perimeter_score(&rings(ring_lens, lats, lons), (lat, lon))
    })
}
pub fn flows_hazard_avalanche_score(
    zone_ring_counts: &[i64],
    ratings: &[i64],
    ring_lens: &[i64],
    lats: &[f64],
    lons: &[f64],
    lat: f64,
    lon: f64,
) -> f64 {
    contain(f64::NAN, || {
        let z: Vec<(Vec<Vec<Point>>, i64)> = zones(zone_ring_counts, ring_lens, lats, lons)
            .into_iter()
            .zip(ratings.iter().copied())
            .collect();
        hf::avalanche_score(&z, (lat, lon))
    })
}
pub fn flows_hazard_outlook_score(
    zone_ring_counts: &[i64],
    scores: &[f64],
    ring_lens: &[i64],
    lats: &[f64],
    lons: &[f64],
    lat: f64,
    lon: f64,
) -> f64 {
    contain(f64::NAN, || {
        let z: Vec<(Vec<Vec<Point>>, f64)> = zones(zone_ring_counts, ring_lens, lats, lons)
            .into_iter()
            .zip(scores.iter().copied())
            .collect();
        hf::outlook_score(&z, (lat, lon))
    })
}

// ---- the alert service ----

pub fn flows_hazard_cell_key(lat: f64, lon: f64) -> String {
    contain(String::new(), || {
        hf::cell_key((lat, lon)).unwrap_or_default()
    })
}
pub fn flows_hazard_states_containing(lat: f64, lon: f64) -> Vec<String> {
    contain(Vec::new(), || {
        hf::states_containing((lat, lon))
            .into_iter()
            .map(str::to_string)
            .collect()
    })
}
pub fn flows_hazard_marine_regions_containing(lat: f64, lon: f64) -> Vec<String> {
    contain(Vec::new(), || {
        hf::marine_regions_containing((lat, lon))
            .into_iter()
            .map(str::to_string)
            .collect()
    })
}

/// Per sample three numbers: has-data (0/1), risk, and the index of the
/// worst alert (-1 for none), from alerts given as parallel lists and cells
/// as `cell_keys_joined` with each cell's alert indices in `cell_alert_indices`
/// counted by `cell_alert_counts`.
#[allow(clippy::too_many_arguments)]
pub fn flows_hazard_provisional_samples(
    sample_lats: &[f64],
    sample_lons: &[f64],
    alert_severities: &[f64],
    alert_expires: &[f64],
    alert_has_expires: &[i64],
    cell_keys_joined: &str,
    cell_alert_counts: &[i64],
    cell_alert_indices: &[i64],
    arrival_offsets: &[f64],
    has_offsets: bool,
    now: f64,
) -> Vec<f64> {
    contain(Vec::new(), || {
        let alerts: Vec<Alert> = alert_severities
            .iter()
            .enumerate()
            .map(|(k, &s)| Alert {
                id: k.to_string(),
                severity_score: s,
                expires: (alert_has_expires.get(k).copied().unwrap_or(0) != 0)
                    .then(|| alert_expires.get(k).copied().unwrap_or(0.0)),
                ..Alert::default()
            })
            .collect();
        let mut cells: BTreeMap<String, Vec<Alert>> = BTreeMap::new();
        let mut at = 0usize;
        for (key, &n) in split_joined(cell_keys_joined)
            .into_iter()
            .zip(cell_alert_counts)
        {
            let n = count(n).min(cell_alert_indices.len().saturating_sub(at));
            let hits = cell_alert_indices[at..at + n]
                .iter()
                .filter_map(|&k| alerts.get(count(k)).cloned())
                .collect();
            at += n;
            cells.insert(key, hits);
        }
        let offsets = has_offsets.then_some(arrival_offsets);
        hf::provisional_samples(&points(sample_lats, sample_lons), &cells, offsets, now)
            .iter()
            .flat_map(|s| match s {
                None => [0.0, 0.0, -1.0],
                Some(s) => [
                    1.0,
                    s.risk,
                    s.alert_id
                        .as_deref()
                        .and_then(|id| id.parse::<f64>().ok())
                        .unwrap_or(-1.0),
                ],
            })
            .collect()
    })
}

/// The covering alerts' indices. Alerts give their rings (polygon first,
/// then extra rings, as `alert_ring_counts` over one flat ring list) and
/// their zone names (`alert_zone_counts` over `alert_zones_joined`); the
/// zone geometry table gives `zone_names_joined` with `zone_ring_counts`
/// over its own flat ring list.
#[allow(clippy::too_many_arguments)]
pub fn flows_hazard_alerts_covering(
    lat: f64,
    lon: f64,
    alert_ring_counts: &[i64],
    alert_zone_counts: &[i64],
    ring_lens: &[i64],
    lats: &[f64],
    lons: &[f64],
    alert_zones_joined: &str,
    zone_names_joined: &str,
    zone_ring_counts: &[i64],
    zone_ring_lens: &[i64],
    zone_lats: &[f64],
    zone_lons: &[f64],
) -> Vec<i64> {
    contain(Vec::new(), || {
        let alert_rings = zones(alert_ring_counts, ring_lens, lats, lons);
        let zone_names = split_joined(alert_zones_joined);
        let mut zone_at = 0usize;
        let alerts: Vec<Alert> = alert_rings
            .into_iter()
            .enumerate()
            .map(|(k, mut rings)| {
                let n = count(alert_zone_counts.get(k).copied().unwrap_or(0))
                    .min(zone_names.len().saturating_sub(zone_at));
                let affected = zone_names[zone_at..zone_at + n].to_vec();
                zone_at += n;
                let polygon = if rings.is_empty() {
                    None
                } else {
                    Some(rings.remove(0))
                };
                Alert {
                    id: k.to_string(),
                    polygon,
                    extra_rings: rings,
                    affected_zones: affected,
                    ..Alert::default()
                }
            })
            .collect();
        let zone_rings: BTreeMap<String, Vec<Vec<Point>>> = split_joined(zone_names_joined)
            .into_iter()
            .zip(zones(
                zone_ring_counts,
                zone_ring_lens,
                zone_lats,
                zone_lons,
            ))
            .collect();
        hf::alerts_covering((lat, lon), &alerts, &zone_rings)
            .into_iter()
            .map(as_i64)
            .collect()
    })
}

/// GeoJSON outer rings decimated: each raw ring's coordinates are number
/// lists (`coord_lens` over `values`), `ring_coord_counts` coordinates per
/// ring; the answer is the flat-ring form.
pub fn flows_hazard_all_rings(
    ring_coord_counts: &[i64],
    coord_lens: &[i64],
    values: &[f64],
    max_points: i64,
) -> Vec<f64> {
    contain(Vec::new(), || {
        let mut coords: Vec<Vec<f64>> = Vec::with_capacity(coord_lens.len());
        let mut at = 0usize;
        for &len in coord_lens {
            let n = count(len).min(values.len().saturating_sub(at));
            coords.push(values[at..at + n].to_vec());
            at += n;
        }
        let mut raws: Vec<Vec<Vec<f64>>> = Vec::with_capacity(ring_coord_counts.len());
        let mut c_at = 0usize;
        for &n in ring_coord_counts {
            let n = count(n).min(coords.len().saturating_sub(c_at));
            raws.push(coords[c_at..c_at + n].to_vec());
            c_at += n;
        }
        flat_rings(&hf::all_rings(&raws, count(max_points)))
    })
}
pub fn flows_hazard_corridor_noisy_or(severities: &[f64], coverages: &[f64]) -> f64 {
    contain(f64::NAN, || hf::corridor_noisy_or(severities, coverages))
}
pub fn flows_hazard_corridor_coverage(risks: &[f64]) -> f64 {
    contain(0.0, || hf::corridor_coverage(risks))
}
pub fn flows_hazard_worst_first(severities: &[f64]) -> Vec<i64> {
    contain(Vec::new(), || {
        hf::worst_first(severities)
            .into_iter()
            .map(as_i64)
            .collect()
    })
}

// ---- the CRE fuel files: one string per place, fields joined by U+001F ----

/// `id U+001F type=bits U+001D type=bits …`, prices as IEEE bit patterns in hex.
pub fn flows_hazard_fuel_prices(xml: &str) -> Vec<String> {
    contain(Vec::new(), || {
        hf::parse_fuel_prices(xml)
            .iter()
            .map(|(id, prices)| {
                let pairs: Vec<String> = prices
                    .iter()
                    .map(|(t, v)| format!("{t}={:x}", v.to_bits()))
                    .collect();
                format!("{id}{JOIN}{}", pairs.join("\u{1D}"))
            })
            .collect()
    })
}
/// `id U+001F lat-bits U+001F lon-bits`.
pub fn flows_hazard_fuel_places(xml: &str) -> Vec<String> {
    contain(Vec::new(), || {
        hf::parse_fuel_places(xml)
            .iter()
            .map(|(id, p)| format!("{id}{JOIN}{:x}{JOIN}{:x}", p.0.to_bits(), p.1.to_bits()))
            .collect()
    })
}

// ---- the live snapshot ----

/// The live feeds behind Swift's `LiveHazardSnapshot`.
pub struct FlowsHazardSnapshot(Snapshot);

pub fn flows_hazard_clip_margin_degrees() -> f64 {
    hf::CLIP_MARGIN_DEGREES
}

pub fn flows_hazard_snapshot_new() -> FlowsHazardSnapshot {
    FlowsHazardSnapshot(Snapshot::default())
}

impl FlowsHazardSnapshot {
    pub fn add_hotspots(&mut self, lats: &[f64], lons: &[f64], frps: &[f64]) {
        self.0.hotspots.extend(triples(lats, lons, frps));
    }
    pub fn add_perimeters(&mut self, ring_lens: &[i64], lats: &[f64], lons: &[f64]) {
        self.0.perimeters.extend(rings(ring_lens, lats, lons));
    }
    pub fn add_quakes(
        &mut self,
        lats: &[f64],
        lons: &[f64],
        magnitudes: &[f64],
        age_hours: &[f64],
    ) {
        self.0.quakes.extend(
            lats.iter()
                .zip(lons)
                .zip(magnitudes)
                .zip(age_hours)
                .map(|(((&a, &b), &m), &h)| (a, b, m, h)),
        );
    }
    pub fn set_space(&mut self, r: i64, s: i64, g: i64) {
        self.0.space = (r, s, g);
    }
    pub fn add_volcanoes(&mut self, lats: &[f64], lons: &[f64], levels_joined: &str) {
        self.0.volcanoes.extend(named(lats, lons, levels_joined));
    }
    pub fn add_avalanche_zones(
        &mut self,
        zone_ring_counts: &[i64],
        ratings: &[i64],
        ring_lens: &[i64],
        lats: &[f64],
        lons: &[f64],
    ) {
        self.0.avalanche_zones.extend(
            zones(zone_ring_counts, ring_lens, lats, lons)
                .into_iter()
                .zip(ratings.iter().copied()),
        );
    }
    pub fn add_storms(&mut self, lats: &[f64], lons: &[f64], max_wind_kts: &[f64]) {
        self.0.storms.extend(triples(lats, lons, max_wind_kts));
    }
    pub fn add_tsunamis(&mut self, lats: &[f64], lons: &[f64], levels_joined: &str) {
        self.0.tsunamis.extend(named(lats, lons, levels_joined));
    }
    pub fn add_spc_zones(
        &mut self,
        zone_ring_counts: &[i64],
        scores: &[f64],
        ring_lens: &[i64],
        lats: &[f64],
        lons: &[f64],
    ) {
        self.0.spc_zones.extend(
            zones(zone_ring_counts, ring_lens, lats, lons)
                .into_iter()
                .zip(scores.iter().copied()),
        );
    }
    pub fn clipped(
        &self,
        min_lat: f64,
        min_lon: f64,
        max_lat: f64,
        max_lon: f64,
    ) -> FlowsHazardSnapshot {
        FlowsHazardSnapshot(self.0.clipped(min_lat, min_lon, max_lat, max_lon))
    }
    /// The eight live family scores, in `LIVE_FAMILY_NAMES` order.
    pub fn live(&self, lat: f64, lon: f64) -> Vec<f64> {
        let s = &self.0;
        contain(vec![0.0; 8], || hf::live((lat, lon), s).values().to_vec())
    }
    pub fn hotspots_flat(&self) -> Vec<f64> {
        self.0
            .hotspots
            .iter()
            .flat_map(|&(a, b, c)| [a, b, c])
            .collect()
    }
    pub fn perimeters_flat(&self) -> Vec<f64> {
        flat_rings(&self.0.perimeters)
    }
    pub fn quakes_flat(&self) -> Vec<f64> {
        self.0
            .quakes
            .iter()
            .flat_map(|&(a, b, c, d)| [a, b, c, d])
            .collect()
    }
    pub fn space(&self) -> Vec<i64> {
        vec![self.0.space.0, self.0.space.1, self.0.space.2]
    }
    pub fn volcanoes_flat(&self) -> Vec<f64> {
        self.0.volcanoes.iter().flat_map(|v| [v.0, v.1]).collect()
    }
    pub fn volcano_levels(&self) -> Vec<String> {
        self.0.volcanoes.iter().map(|v| v.2.clone()).collect()
    }
    pub fn avalanche_zones_flat(&self) -> Vec<f64> {
        let zones: Vec<Vec<Vec<Point>>> =
            self.0.avalanche_zones.iter().map(|z| z.0.clone()).collect();
        flat_zones(&zones)
    }
    pub fn avalanche_ratings(&self) -> Vec<i64> {
        self.0.avalanche_zones.iter().map(|z| z.1).collect()
    }
    pub fn storms_flat(&self) -> Vec<f64> {
        self.0
            .storms
            .iter()
            .flat_map(|&(a, b, c)| [a, b, c])
            .collect()
    }
    pub fn tsunamis_flat(&self) -> Vec<f64> {
        self.0.tsunamis.iter().flat_map(|t| [t.0, t.1]).collect()
    }
    pub fn tsunami_levels(&self) -> Vec<String> {
        self.0.tsunamis.iter().map(|t| t.2.clone()).collect()
    }
    pub fn spc_zones_flat(&self) -> Vec<f64> {
        let zones: Vec<Vec<Vec<Point>>> = self.0.spc_zones.iter().map(|z| z.0.clone()).collect();
        flat_zones(&zones)
    }
    pub fn spc_scores(&self) -> Vec<f64> {
        self.0.spc_zones.iter().map(|z| z.1).collect()
    }
}
