// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The live hazard feeds and the alert service, interpreted: every score a
//! live feed contributes at a point, the snapshot clip and the per-point
//! assembly the map sweep and the route scorer share, the alert service's
//! geometry and severity rules, and the CRE fuel files' tag scan — from
//! `LiveHazardFeeds.swift`, `LiveHazardScoring.swift`,
//! `WeatherAlertService.swift` and `PrimarySources.swift` at commit f36ee9e,
//! the last before the facade switch.
//!
//! | here | Swift |
//! |---|---|
//! | [`air_score`] … [`closure_score`], [`point_in_polygon`] | `HazardFeedScores` |
//! | [`Snapshot::clipped`], [`live`], [`LiveFamilies::band_input_contribution`] | `LiveHazardSnapshot.clipped`, `HazardFeedScores.live`, `LiveFamilies.bandInputContribution` |
//! | [`severity_score`], [`cell_key`], [`provisional_samples`], [`states_containing`], [`marine_regions_containing`], [`ring_contains`], [`alerts_covering`], [`all_rings`], [`corridor_noisy_or`], [`corridor_coverage`], [`worst_first`] | `WeatherAlertService` statics and the pure steps of `corridorRisk` |
//! | [`backup_severity`] | `BackupWarningsCache.severity(phenomena:)` |
//! | [`parse_fuel_prices`], [`parse_fuel_places`] | `MexicoFuelParsing` |
//!
//! # Fidelity
//!
//! Pinned by `flows-bridge/tests/fixtures/swift_hazard_feeds_oracle.tsv`.
//! Swift's `min`/`max` are [`crate::fcmp`]'s; distances are the geo kernel's
//! [`meters`] in the Swift's argument order; the worst-first sort is Swift's
//! own ([`crate::learning::swift_sort_by`]); string cases compare
//! canonically through [`crate::swift_text`]. One order the Swift never
//! fixed — the states whose boxes hold a point came out of a dictionary in
//! per-launch hash order — is answered in code order here, and the callers
//! only ever used it as a set.
//!
//! Nothing here fetches, caches or holds state; the feeds are handed in.

use crate::climate::is_active;
use crate::fcmp::{smax, smin, swift_int};
use crate::fmath;
use crate::geo::{distance_to_segment_meters_scaled, meters, METERS_PER_DEGREE};
use crate::learning::swift_sort_by;
use crate::swift_text as st;
use std::collections::BTreeMap;
use std::f64::consts::PI;

/// A point as (latitude, longitude), degrees.
pub type Point = (f64, f64);

/// The reach (m) of a fire hotspot.
pub const HOTSPOT_REACH_METERS: f64 = 30_000.0;
/// The reach (m) of a recent quake.
pub const QUAKE_REACH_METERS: f64 = 150_000.0;
/// Hours a quake stays recent.
pub const QUAKE_FRESH_HOURS: f64 = 24.0;
/// The smoke and evacuation fringe (m) around a fire perimeter.
pub const PERIMETER_BUFFER_METERS: f64 = 12_000.0;
/// The reach (m) of a flood gauge.
pub const GAUGE_REACH_METERS: f64 = 20_000.0;
/// The reach (m) of mapped water.
pub const WATER_REACH_METERS: f64 = 6_000.0;
/// The reach (m) of an elevated volcano.
pub const VOLCANO_REACH_METERS: f64 = 80_000.0;
/// The reach (m) of a tsunami event.
pub const TSUNAMI_REACH_METERS: f64 = 500_000.0;
/// A reported full closure this close (m) is a blocked road.
pub const CLOSURE_FULL_METERS: f64 = 300.0;
/// Past this (m) a closure no longer matters.
pub const CLOSURE_REACH_METERS: f64 = 2_000.0;
/// The margin (degrees) a snapshot clip keeps around its box.
pub const CLIP_MARGIN_DEGREES: f64 = 6.0;
/// The alert grid's cells per degree (0.25° cells).
pub const ALERT_CELLS_PER_DEGREE: f64 = 4.0;

// ============================================================ HazardFeedScores

/// `airScore(usAQI:)`: US AQI to 0…1 on the EPA category edges.
#[must_use]
pub fn air_score(us_aqi: f64) -> f64 {
    if us_aqi < 50.0 {
        us_aqi / 50.0 * 0.2
    } else if us_aqi < 100.0 {
        0.2 + (us_aqi - 50.0) / 50.0 * 0.25
    } else if us_aqi < 150.0 {
        0.45 + (us_aqi - 100.0) / 50.0 * 0.25
    } else if us_aqi < 200.0 {
        0.7 + (us_aqi - 150.0) / 50.0 * 0.2
    } else {
        smin(0.9 + (us_aqi - 200.0) / 300.0 * 0.1, 1.0)
    }
}

/// `uvScore(index:)`: UV index to 0…1 on the WHO bands.
#[must_use]
pub fn uv_score(index: f64) -> f64 {
    if index < 3.0 {
        index / 3.0 * 0.2
    } else if index < 6.0 {
        0.2 + (index - 3.0) / 3.0 * 0.2
    } else if index < 8.0 {
        0.4 + (index - 6.0) / 2.0 * 0.2
    } else if index < 11.0 {
        0.6 + (index - 8.0) / 3.0 * 0.25
    } else {
        smin(0.85 + (index - 11.0) / 5.0 * 0.15, 1.0)
    }
}

/// `fireScore(hotspots:at:)`: the strongest nearby detection — proximity
/// within 30 km times radiative power (100 MW is severe) — never a noisy-OR,
/// which a swarm of correlated pixels saturated.
#[must_use]
pub fn fire_score(hotspots: &[(f64, f64, f64)], p: Point) -> f64 {
    let mut best = 0.0;
    for &(lat, lon, frp) in hotspots {
        let d = meters(lat, lon, p.0, p.1);
        if d >= HOTSPOT_REACH_METERS || d.is_nan() {
            continue;
        }
        let proximity = 1.0 - d / HOTSPOT_REACH_METERS;
        let power = smin(smax(frp, 1.0) / 100.0, 1.0);
        best = smax(best, smin(0.3 + 0.7 * power, 1.0) * proximity);
    }
    best
}

/// `seismicScore(quakes:at:)`: magnitude past M3, decayed by distance (150
/// km) and age (24 h).
#[must_use]
pub fn seismic_score(quakes: &[(f64, f64, f64, f64)], p: Point) -> f64 {
    let mut best = 0.0;
    for &(lat, lon, magnitude, age_hours) in quakes {
        let d = meters(lat, lon, p.0, p.1);
        if !(d < QUAKE_REACH_METERS && age_hours < QUAKE_FRESH_HOURS) {
            continue;
        }
        let mag = smin(smax(magnitude - 3.0, 0.0) / 4.0, 1.0);
        let near = 1.0 - d / QUAKE_REACH_METERS;
        let fresh = 1.0 - age_hours / QUAKE_FRESH_HOURS;
        best = smax(best, mag * near * (0.5 + 0.5 * fresh));
    }
    best
}

/// `pointInPolygon`: the ray cast, on raw longitudes (a ring straddling the
/// antimeridian tests wrong, as the Swift's did and documented).
#[must_use]
pub fn point_in_polygon(p: Point, ring: &[Point]) -> bool {
    if ring.len() < 3 {
        return false;
    }
    let mut inside = false;
    let mut j = ring.len() - 1;
    for i in 0..ring.len() {
        let (a, b) = (ring[i], ring[j]);
        if (a.0 > p.0) != (b.0 > p.0) {
            let t = (p.0 - a.0) / (b.0 - a.0);
            if p.1 < a.1 + t * (b.1 - a.1) {
                inside = !inside;
            }
        }
        j = i;
    }
    inside
}

/// `firePerimeterScore(perimeters:at:)`: inside a mapped fire is 1; within
/// the 12 km fringe the nearest EDGE ramps down at weight 0.7; a one-point
/// ring is a hotspot at the same weight. Rings whose box lies beyond the
/// fringe are skipped without trigonometry.
#[must_use]
pub fn fire_perimeter_score(perimeters: &[Vec<Point>], p: Point) -> f64 {
    let mut best = 0.0;
    let m_per_deg_lat = METERS_PER_DEGREE;
    let m_per_deg_lon = METERS_PER_DEGREE * fmath::cos(p.0 * PI / 180.0);
    let buffer = PERIMETER_BUFFER_METERS;
    for ring in perimeters {
        if ring.len() < 2 {
            if let Some(&only) = ring.first() {
                let d = meters(only.0, only.1, p.0, p.1);
                if d < buffer {
                    best = smax(best, (1.0 - d / buffer) * 0.7);
                }
            }
            continue;
        }
        let (mut min_lat, mut max_lat) = (ring[0].0, ring[0].0);
        let (mut min_lon, mut max_lon) = (ring[0].1, ring[0].1);
        for c in ring {
            min_lat = smin(min_lat, c.0);
            max_lat = smax(max_lat, c.0);
            min_lon = smin(min_lon, c.1);
            max_lon = smax(max_lon, c.1);
        }
        let d_lat = smax(0.0, smax(min_lat - p.0, p.0 - max_lat)) * m_per_deg_lat;
        let d_lon = smax(0.0, smax(min_lon - p.1, p.1 - max_lon)) * m_per_deg_lon;
        if d_lat * d_lat + d_lon * d_lon > buffer * buffer {
            continue;
        }
        let mut inside = false;
        let mut min_d = f64::INFINITY;
        let mut prev = ring.len() - 1;
        for i in 0..ring.len() {
            let (a, b) = (ring[i], ring[prev]);
            if (a.0 > p.0) != (b.0 > p.0) {
                let t = (p.0 - a.0) / (b.0 - a.0);
                if p.1 < a.1 + t * (b.1 - a.1) {
                    inside = !inside;
                }
            }
            min_d = smin(
                min_d,
                distance_to_segment_meters_scaled(
                    p.0,
                    p.1,
                    ring[prev].0,
                    ring[prev].1,
                    ring[i].0,
                    ring[i].1,
                    m_per_deg_lon,
                ),
            );
            prev = i;
        }
        if inside {
            return 1.0;
        }
        if min_d < buffer {
            best = smax(best, (1.0 - min_d / buffer) * 0.7);
        }
    }
    best
}

/// `floodCategoryScore`: the NWPS observed category.
#[must_use]
pub fn flood_category_score(category: &str) -> f64 {
    if st::eq(category, "action") {
        0.25
    } else if st::eq(category, "minor") {
        0.45
    } else if st::eq(category, "moderate") {
        0.70
    } else if st::eq(category, "major") {
        1.0
    } else {
        0.0
    }
}

/// `floodGaugeScore(gauges:at:)`: nearest gauge at or above flood stage
/// within 20 km, category times proximity.
#[must_use]
pub fn flood_gauge_score(gauges: &[(f64, f64, String)], p: Point) -> f64 {
    let mut best = 0.0;
    for (lat, lon, category) in gauges {
        let base = flood_category_score(category);
        if base <= 0.0 || base.is_nan() {
            continue;
        }
        let d = meters(*lat, *lon, p.0, p.1);
        if d >= GAUGE_REACH_METERS || d.is_nan() {
            continue;
        }
        best = smax(best, base * (1.0 - 0.5 * d / GAUGE_REACH_METERS));
    }
    best
}

/// `waterProximityScore(waterPoints:at:)`: 1 at a confirmed water sample,
/// tapering to 0 by 6 km.
#[must_use]
pub fn water_proximity_score(water_points: &[Point], p: Point) -> f64 {
    let mut best = 0.0;
    for &w in water_points {
        let d = meters(w.0, w.1, p.0, p.1);
        if d >= WATER_REACH_METERS || d.is_nan() {
            continue;
        }
        best = smax(best, 1.0 - d / WATER_REACH_METERS);
    }
    best
}

/// `spaceWeatherScore(scale:)`: one NOAA scale (0…5) to 0…1.
#[must_use]
pub fn space_weather_score(scale: i64) -> f64 {
    match scale.clamp(0, 5) {
        0 => 0.0,
        1 => 0.15,
        2 => 0.30,
        3 => 0.55,
        4 => 0.78,
        _ => 1.0,
    }
}

/// `radiationSpaceWeatherScore`: the S scale at full weight, the G scale
/// weighted toward the poles.
#[must_use]
pub fn radiation_space_weather_score(s_scale: i64, g_scale: i64, latitude: f64) -> f64 {
    let s = space_weather_score(s_scale);
    let lat_weight = smin(smax((latitude.abs() - 30.0) / 30.0, 0.2), 1.0);
    let g = space_weather_score(g_scale) * lat_weight;
    smax(s, g)
}

/// `volcanoAlertScore`: the USGS level word, any case.
#[must_use]
pub fn volcano_alert_score(level: &str) -> f64 {
    let upper = st::uppercased(level);
    if st::eq(&upper, "WARNING") {
        1.0
    } else if st::eq(&upper, "WATCH") {
        0.72
    } else if st::eq(&upper, "ADVISORY") {
        0.42
    } else {
        0.0
    }
}

/// `volcanicScore(volcanoes:at:)`: nearest elevated volcano within 80 km.
#[must_use]
pub fn volcanic_score(volcanoes: &[(f64, f64, String)], p: Point) -> f64 {
    let mut best = 0.0;
    for (lat, lon, level) in volcanoes {
        let base = volcano_alert_score(level);
        if base <= 0.0 || base.is_nan() {
            continue;
        }
        let d = meters(*lat, *lon, p.0, p.1);
        if d >= VOLCANO_REACH_METERS || d.is_nan() {
            continue;
        }
        best = smax(best, base * (1.0 - 0.5 * d / VOLCANO_REACH_METERS));
    }
    best
}

/// `avalancheRatingScore`: the EAWS danger rating (1 Low … 5 Extreme).
#[must_use]
pub fn avalanche_rating_score(rating: i64) -> f64 {
    match rating.clamp(0, 5) {
        0 => 0.0,
        1 => 0.25,
        2 => 0.45,
        3 => 0.72,
        4 => 0.90,
        _ => 1.0,
    }
}

/// `avalancheScore(zones:at:)`: the rating of the zone the point falls in.
#[must_use]
pub fn avalanche_score(zones: &[(Vec<Vec<Point>>, i64)], p: Point) -> f64 {
    let mut best = 0.0;
    for (rings, rating) in zones {
        let s = avalanche_rating_score(*rating);
        if s <= best || s.is_nan() {
            continue;
        }
        if rings.iter().any(|r| point_in_polygon(p, r)) {
            best = s;
        }
    }
    best
}

/// `tropicalIntensityScore(maxWindKt:)`: Saffir–Simpson bands to 0…1.
#[must_use]
pub fn tropical_intensity_score(max_wind_kt: f64) -> f64 {
    if max_wind_kt < 34.0 {
        0.30
    } else if max_wind_kt < 64.0 {
        0.52
    } else if max_wind_kt < 83.0 {
        0.72
    } else if max_wind_kt < 96.0 {
        0.82
    } else if max_wind_kt < 113.0 {
        0.90
    } else if max_wind_kt < 137.0 {
        0.96
    } else {
        1.0
    }
}

/// `tropicalScore(storms:at:)`: nearest active storm within a reach that
/// grows with intensity (150 km to 400 km).
#[must_use]
pub fn tropical_score(storms: &[(f64, f64, f64)], p: Point) -> f64 {
    let mut best = 0.0;
    for &(lat, lon, kt) in storms {
        let d = meters(lat, lon, p.0, p.1);
        let reach = 150_000.0 + 250_000.0 * smin(smax((kt - 34.0) / 103.0, 0.0), 1.0);
        if d >= reach || d.is_nan() {
            continue;
        }
        best = smax(best, tropical_intensity_score(kt) * (1.0 - 0.6 * d / reach));
    }
    best
}

/// `tsunamiLevelScore`: the product level word, any case, by substring.
#[must_use]
pub fn tsunami_level_score(level: &str) -> f64 {
    let l = st::lowercased(level);
    if st::contains(&l, "warning") {
        1.0
    } else if st::contains(&l, "advisory") {
        0.82
    } else if st::contains(&l, "watch") {
        0.72
    } else {
        0.0
    }
}

/// `tsunamiScore(events:at:)`: level times proximity within 500 km.
#[must_use]
pub fn tsunami_score(events: &[(f64, f64, String)], p: Point) -> f64 {
    let mut best = 0.0;
    for (lat, lon, level) in events {
        let base = tsunami_level_score(level);
        if base <= 0.0 || base.is_nan() {
            continue;
        }
        let d = meters(*lat, *lon, p.0, p.1);
        if d >= TSUNAMI_REACH_METERS || d.is_nan() {
            continue;
        }
        best = smax(best, base * (1.0 - 0.5 * d / TSUNAMI_REACH_METERS));
    }
    best
}

/// `spcCategoricalScore(dn:)`: the SPC outlook code.
#[must_use]
pub fn spc_categorical_score(dn: i64) -> f64 {
    match dn {
        2 => 0.35,
        3 => 0.45,
        4 => 0.60,
        5 => 0.72,
        6 => 0.88,
        8 => 1.0,
        _ => 0.0,
    }
}

/// `outlookScore(zones:at:)`: the highest-scoring outlook polygon holding
/// the point.
#[must_use]
pub fn outlook_score(zones: &[(Vec<Vec<Point>>, f64)], p: Point) -> f64 {
    let mut best = 0.0;
    for (rings, score) in zones {
        if *score <= best || score.is_nan() {
            continue;
        }
        if rings.iter().any(|r| point_in_polygon(p, r)) {
            best = *score;
        }
    }
    best
}

/// `closureScore(closures:at:)`: 1 within 300 m of a reported full closure,
/// ramping to 0 at 2 km.
#[must_use]
pub fn closure_score(closures: &[Point], p: Point) -> f64 {
    let mut best = 0.0;
    for &c in closures {
        let d = meters(c.0, c.1, p.0, p.1);
        if d <= CLOSURE_FULL_METERS {
            return 1.0;
        }
        if d < CLOSURE_REACH_METERS {
            best = smax(best, 1.0 - (d - CLOSURE_FULL_METERS) / 1_700.0);
        }
    }
    best
}

// ============================================================ LiveHazardScoring

/// `LiveHazardSnapshot`: every live feed, fetched once for an area.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Snapshot {
    /// Fire hotspots as (lat, lon, radiative power MW).
    pub hotspots: Vec<(f64, f64, f64)>,
    /// Active fire perimeters.
    pub perimeters: Vec<Vec<Point>>,
    /// Recent quakes as (lat, lon, magnitude, age hours).
    pub quakes: Vec<(f64, f64, f64, f64)>,
    /// NOAA space weather (R, S, G).
    pub space: (i64, i64, i64),
    /// Elevated volcanoes as (lat, lon, alert level).
    pub volcanoes: Vec<(f64, f64, String)>,
    /// Avalanche zones as (rings, rating).
    pub avalanche_zones: Vec<(Vec<Vec<Point>>, i64)>,
    /// Tropical storms as (lat, lon, max wind kt).
    pub storms: Vec<(f64, f64, f64)>,
    /// Tsunami events as (lat, lon, level).
    pub tsunamis: Vec<(f64, f64, String)>,
    /// SPC outlook zones as (rings, score).
    pub spc_zones: Vec<(Vec<Vec<Point>>, f64)>,
}

fn rings_touch(rings: &[Vec<Point>], s: f64, n: f64, w: f64, e: f64) -> bool {
    rings.iter().any(|ring| {
        let Some(&first) = ring.first() else {
            return false;
        };
        let (mut rs, mut rn, mut rw, mut re) = (first.0, first.0, first.1, first.1);
        for c in ring {
            rs = smin(rs, c.0);
            rn = smax(rn, c.0);
            rw = smin(rw, c.1);
            re = smax(re, c.1);
        }
        rs <= n && rn >= s && rw <= e && re >= w
    })
}

impl Snapshot {
    /// `clipped(minLat:minLon:maxLat:maxLon:)`: the snapshot with every
    /// point or ring that cannot influence a score inside the box removed
    /// (a 6° margin; the widest scorer reaches 500 km).
    #[must_use]
    pub fn clipped(&self, min_lat: f64, min_lon: f64, max_lat: f64, max_lon: f64) -> Snapshot {
        let m = CLIP_MARGIN_DEGREES;
        let (s, n, w, e) = (min_lat - m, max_lat + m, min_lon - m, max_lon + m);
        let inside = |lat: f64, lon: f64| lat >= s && lat <= n && lon >= w && lon <= e;
        Snapshot {
            hotspots: self
                .hotspots
                .iter()
                .copied()
                .filter(|h| inside(h.0, h.1))
                .collect(),
            perimeters: self
                .perimeters
                .iter()
                .filter(|r| rings_touch(std::slice::from_ref(*r), s, n, w, e))
                .cloned()
                .collect(),
            quakes: self
                .quakes
                .iter()
                .copied()
                .filter(|q| inside(q.0, q.1))
                .collect(),
            space: self.space,
            volcanoes: self
                .volcanoes
                .iter()
                .filter(|v| inside(v.0, v.1))
                .cloned()
                .collect(),
            avalanche_zones: self
                .avalanche_zones
                .iter()
                .filter(|z| rings_touch(&z.0, s, n, w, e))
                .cloned()
                .collect(),
            storms: self
                .storms
                .iter()
                .copied()
                .filter(|t| inside(t.0, t.1))
                .collect(),
            tsunamis: self
                .tsunamis
                .iter()
                .filter(|t| inside(t.0, t.1))
                .cloned()
                .collect(),
            spc_zones: self
                .spc_zones
                .iter()
                .filter(|z| rings_touch(&z.0, s, n, w, e))
                .cloned()
                .collect(),
        }
    }
}

/// `HazardFeedScores.LiveFamilies`: one point's raw score from each feed.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LiveFamilies {
    pub fire: f64,
    pub seismic: f64,
    pub space_radiation: f64,
    pub volcanic: f64,
    pub avalanche: f64,
    pub tropical: f64,
    pub tsunami: f64,
    pub convective: f64,
}

/// The band-input family names, in [`LiveFamilies::values`] order.
pub const LIVE_FAMILY_NAMES: [&str; 8] = [
    "fire",
    "seismic",
    "radiation",
    "volcanic",
    "avalanche",
    "tropical",
    "tsunami",
    "convective",
];

impl LiveFamilies {
    /// The eight scores in [`LIVE_FAMILY_NAMES`] order.
    #[must_use]
    pub fn values(&self) -> [f64; 8] {
        [
            self.fire,
            self.seismic,
            self.space_radiation,
            self.volcanic,
            self.avalanche,
            self.tropical,
            self.tsunami,
            self.convective,
        ]
    }

    /// `bandInputContribution`: the families that registered (`> 0`), named.
    #[must_use]
    pub fn band_input_contribution(&self) -> Vec<(&'static str, f64)> {
        LIVE_FAMILY_NAMES
            .iter()
            .zip(self.values())
            .filter(|(_, v)| *v > 0.0)
            .map(|(n, v)| (*n, v))
            .collect()
    }
}

/// `HazardFeedScores.live(at:snapshot:)`.
#[must_use]
pub fn live(p: Point, s: &Snapshot) -> LiveFamilies {
    LiveFamilies {
        fire: smax(
            fire_score(&s.hotspots, p),
            fire_perimeter_score(&s.perimeters, p),
        ),
        seismic: seismic_score(&s.quakes, p),
        space_radiation: radiation_space_weather_score(s.space.1, s.space.2, p.0),
        volcanic: volcanic_score(&s.volcanoes, p),
        avalanche: avalanche_score(&s.avalanche_zones, p),
        tropical: tropical_score(&s.storms, p),
        tsunami: tsunami_score(&s.tsunamis, p),
        convective: outlook_score(&s.spc_zones, p),
    }
}

// ============================================================ WeatherAlertService

/// `severityScore`: the NWS severity word, any case; unknown reads 0.30.
#[must_use]
pub fn severity_score(severity: &str) -> f64 {
    let l = st::lowercased(severity);
    if st::eq(&l, "extreme") {
        0.95
    } else if st::eq(&l, "severe") {
        0.88
    } else if st::eq(&l, "moderate") {
        0.72
    } else if st::eq(&l, "minor") {
        0.45
    } else {
        0.30
    }
}

/// `BackupWarningsCache.severity(phenomena:)`: IEM phenomena codes.
#[must_use]
pub fn backup_severity(phenomena: &str) -> f64 {
    if st::eq(phenomena, "TO") {
        0.95
    } else if st::eq(phenomena, "MA") {
        0.72
    } else {
        0.88
    }
}

/// `cellKey`: the 0.25° cell of a point, `"y|x"` of the rounded indices.
/// `None` where the Swift trapped (a coordinate that is not a number).
#[must_use]
pub fn cell_key(p: Point) -> Option<String> {
    let y = swift_int((p.0 * ALERT_CELLS_PER_DEGREE).round())?;
    let x = swift_int((p.1 * ALERT_CELLS_PER_DEGREE).round())?;
    Some(format!("{y}|{x}"))
}

/// An alert as the corridor scorer sees it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Alert {
    pub id: String,
    pub event: String,
    pub severity_score: f64,
    /// The polygon's outer ring when the feed provides geometry.
    pub polygon: Option<Vec<Point>>,
    /// Remaining rings of a MultiPolygon alert.
    pub extra_rings: Vec<Vec<Point>>,
    /// Expiry, reference seconds.
    pub expires: Option<f64>,
    /// NWS zone URLs this alert covers.
    pub affected_zones: Vec<String>,
}

/// One sample's worst active alert.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Sample {
    pub risk: f64,
    pub worst_event: Option<String>,
    pub alert_id: Option<String>,
}

/// `provisionalSamples`: per sample, the worst alert of its cell still active
/// at arrival, or `None` for a cell with no data. Ties keep the first alert.
/// A sample that cannot be placed (the Swift trapped) has no data.
#[must_use]
pub fn provisional_samples(
    samples: &[Point],
    cell_alerts: &BTreeMap<String, Vec<Alert>>,
    arrival_offsets: Option<&[f64]>,
    now: f64,
) -> Vec<Option<Sample>> {
    samples
        .iter()
        .enumerate()
        .map(|(i, &pt)| {
            let hits = cell_alerts.get(&cell_key(pt)?)?;
            let offset = arrival_offsets
                .and_then(|a| a.get(i))
                .copied()
                .unwrap_or(0.0);
            let mut worst: Option<&Alert> = None;
            for a in hits.iter().filter(|a| is_active(a.expires, offset, now)) {
                if worst.is_none_or(|w| w.severity_score < a.severity_score) {
                    worst = Some(a);
                }
            }
            Some(Sample {
                risk: worst.map_or(0.0, |w| w.severity_score),
                worst_event: worst.map(|w| w.event.clone()),
                alert_id: worst.map(|w| w.id.clone()),
            })
        })
        .collect()
}

/// The rough state boxes as (code, south, west, north, east), in code order.
pub const STATE_BOXES: &[(&str, f64, f64, f64, f64)] = &[
    ("AL", 30.1, -88.5, 35.0, -84.9),
    ("AR", 33.0, -94.6, 36.5, -89.6),
    ("AZ", 31.3, -114.8, 37.0, -109.0),
    ("CA", 32.5, -124.4, 42.0, -114.1),
    ("CO", 37.0, -109.1, 41.0, -102.0),
    ("CT", 41.0, -73.7, 42.1, -71.8),
    ("DE", 38.5, -75.8, 39.8, -75.0),
    ("FL", 24.5, -87.6, 31.0, -80.0),
    ("GA", 30.4, -85.6, 35.0, -80.8),
    ("IA", 40.4, -96.6, 43.5, -90.1),
    ("ID", 42.0, -117.2, 49.0, -111.0),
    ("IL", 37.0, -91.5, 42.5, -87.0),
    ("IN", 37.8, -88.1, 41.8, -84.8),
    ("KS", 37.0, -102.1, 40.0, -94.6),
    ("KY", 36.5, -89.6, 39.1, -81.9),
    ("LA", 28.9, -94.0, 33.0, -88.8),
    ("MA", 41.2, -73.5, 42.9, -69.9),
    ("MD", 37.9, -79.5, 39.7, -75.0),
    ("ME", 43.1, -71.1, 47.5, -66.9),
    ("MI", 41.7, -90.4, 48.3, -82.4),
    ("MN", 43.5, -97.2, 49.4, -89.5),
    ("MO", 36.0, -95.8, 40.6, -89.1),
    ("MS", 30.2, -91.7, 35.0, -88.1),
    ("MT", 44.4, -116.1, 49.0, -104.0),
    ("NC", 33.8, -84.3, 36.6, -75.5),
    ("ND", 45.9, -104.1, 49.0, -96.6),
    ("NE", 40.0, -104.1, 43.0, -95.3),
    ("NH", 42.7, -72.6, 45.3, -70.6),
    ("NJ", 38.9, -75.6, 41.4, -73.9),
    ("NM", 31.3, -109.1, 37.0, -103.0),
    ("NV", 35.0, -120.0, 42.0, -114.0),
    ("NY", 40.5, -79.8, 45.0, -71.9),
    ("OH", 38.4, -84.8, 42.0, -80.5),
    ("OK", 33.6, -103.0, 37.0, -94.4),
    ("OR", 42.0, -124.6, 46.3, -116.5),
    ("PA", 39.7, -80.5, 42.3, -74.7),
    ("RI", 41.1, -71.9, 42.0, -71.1),
    ("SC", 32.0, -83.4, 35.2, -78.5),
    ("SD", 42.5, -104.1, 45.9, -96.4),
    ("TN", 35.0, -90.3, 36.7, -81.6),
    ("TX", 25.8, -106.6, 36.5, -93.5),
    ("UT", 37.0, -114.1, 42.0, -109.0),
    ("VA", 36.5, -83.7, 39.5, -75.2),
    ("VT", 42.7, -73.4, 45.0, -71.5),
    ("WA", 45.5, -124.8, 49.0, -116.9),
    ("WI", 42.5, -92.9, 47.1, -86.2),
    ("WV", 37.2, -82.6, 40.6, -77.7),
    ("WY", 41.0, -111.1, 45.0, -104.0),
];

/// `statesContaining`: every state whose box holds the point, in code order
/// (the Swift read a dictionary, so its order changed per launch; every
/// caller used the answer as a set).
#[must_use]
pub fn states_containing(p: Point) -> Vec<&'static str> {
    STATE_BOXES
        .iter()
        .filter(|&&(_, s, w, n, e)| p.0 >= s && p.0 <= n && p.1 >= w && p.1 <= e)
        .map(|&(code, ..)| code)
        .collect()
}

/// `marineRegionsContaining`: the marine regions a cell near the water must
/// also union, with their `marine:` prefix.
#[must_use]
pub fn marine_regions_containing(p: Point) -> Vec<&'static str> {
    let mut out = Vec::new();
    if p.1 <= -115.0 && (30.0..=50.0).contains(&p.0) {
        out.push("marine:PA");
    }
    if p.1 >= -83.0 && (24.0..=46.0).contains(&p.0) {
        out.push("marine:AT");
    }
    if p.0 <= 31.5 && (-98.0..=-80.0).contains(&p.1) {
        out.push("marine:GM");
    }
    if (40.5..=49.5).contains(&p.0) && (-93.0..=-75.5).contains(&p.1) {
        out.push("marine:GL");
    }
    out
}

/// `ringContains`: box pre-reject, then the ray cast.
#[must_use]
pub fn ring_contains(p: Point, ring: &[Point]) -> bool {
    if ring.len() < 3 {
        return false;
    }
    let (mut min_lat, mut max_lat) = (ring[0].0, ring[0].0);
    let (mut min_lon, mut max_lon) = (ring[0].1, ring[0].1);
    for c in ring {
        min_lat = smin(min_lat, c.0);
        max_lat = smax(max_lat, c.0);
        min_lon = smin(min_lon, c.1);
        max_lon = smax(max_lon, c.1);
    }
    if !(p.0 >= min_lat && p.0 <= max_lat && p.1 >= min_lon && p.1 <= max_lon) {
        return false;
    }
    point_in_polygon(p, ring)
}

/// `alertsCovering`: which alerts cover the point — by their own rings when
/// they have any with three points, else by their zones' rings. Answered as
/// indices into `alerts`.
#[must_use]
pub fn alerts_covering(
    p: Point,
    alerts: &[Alert],
    zone_rings: &BTreeMap<String, Vec<Vec<Point>>>,
) -> Vec<usize> {
    alerts
        .iter()
        .enumerate()
        .filter(|(_, a)| {
            let mut rings: Vec<&Vec<Point>> = Vec::new();
            if let Some(poly) = a.polygon.as_ref().filter(|r| r.len() >= 3) {
                rings.push(poly);
            }
            rings.extend(a.extra_rings.iter().filter(|r| r.len() >= 3));
            if !rings.is_empty() {
                return rings.iter().any(|r| ring_contains(p, r));
            }
            a.affected_zones.iter().any(|z| {
                zone_rings
                    .get(z)
                    .is_some_and(|rings| rings.iter().any(|r| ring_contains(p, r)))
            })
        })
        .map(|(i, _)| i)
        .collect()
}

/// `allRings(of:maxPoints:)`'s shape step: each raw ring (its coordinates as
/// number lists, as GeoJSON carries them) with at least three coordinates is
/// decimated to at most `max_points` by a stride of `count / max_points +
/// 1`, then read as (lat, lon) from coordinates with at least two numbers;
/// a ring left with fewer than three points is dropped.
#[must_use]
pub fn all_rings(raws: &[Vec<Vec<f64>>], max_points: usize) -> Vec<Vec<Point>> {
    raws.iter()
        .filter_map(|raw| {
            if raw.len() < 3 {
                return None;
            }
            let step = if raw.len() > max_points {
                raw.len() / max_points.max(1) + 1
            } else {
                1
            };
            let ring: Vec<Point> = raw
                .iter()
                .step_by(step)
                .filter(|c| c.len() >= 2)
                .map(|c| (c[1], c[0]))
                .collect();
            (ring.len() >= 3).then_some(ring)
        })
        .collect()
}

/// The corridor's noisy-OR: each alert contributes severity × coverage,
/// clamped to 0…1, and the survivals multiply.
#[must_use]
pub fn corridor_noisy_or(severities: &[f64], coverages: &[f64]) -> f64 {
    let mut survival = 1.0;
    for (s, c) in severities.iter().zip(coverages) {
        survival *= 1.0 - smin(smax(s * c, 0.0), 1.0);
    }
    1.0 - survival
}

/// The corridor's coverage: the share of samples with any risk (0 for none).
#[must_use]
pub fn corridor_coverage(risks: &[f64]) -> f64 {
    if risks.is_empty() {
        return 0.0;
    }
    risks.iter().filter(|&&r| r > 0.0).count() as f64 / risks.len() as f64
}

/// The alerts worst first — Swift's own sort on `severity >`, so ties keep
/// their order — as indices into `severities`.
#[must_use]
pub fn worst_first(severities: &[f64]) -> Vec<usize> {
    let mut order: Vec<usize> = (0..severities.len()).collect();
    swift_sort_by(&mut order, |a, b| severities[a] > severities[b]);
    order
}

// ============================================================ MexicoFuelParsing

/// `parsePrices`: `<place place_id="…">…<gas_price type="…">v</gas_price>…</place>`
/// scanned flat; a place with no readable price is dropped; a repeated id
/// keeps its last prices, as the Swift dictionary did. The value is read as
/// a `Substring`, so one holding a NUL is unreadable (the place scan reads a
/// trimmed `String`, which ends at a NUL).
#[must_use]
pub fn parse_fuel_prices(xml: &str) -> BTreeMap<String, BTreeMap<String, f64>> {
    let mut out: BTreeMap<String, BTreeMap<String, f64>> = BTreeMap::new();
    let mut search = 0;
    while let Some((_, id_start)) = st::find_in(xml, "<place place_id=\"", search, xml.len()) {
        let Some((id_end, after_id)) = st::find_in(xml, "\"", id_start, xml.len()) else {
            break;
        };
        let Some((close, after_close)) = st::find_in(xml, "</place>", after_id, xml.len()) else {
            break;
        };
        let id = xml[id_start..id_end].to_string();
        let mut prices: BTreeMap<String, f64> = BTreeMap::new();
        let mut inner = after_id;
        while let Some((_, t_start)) = st::find_in(xml, "<gas_price type=\"", inner, close) {
            let Some((t_end, after_t)) = st::find_in(xml, "\"", t_start, close) else {
                break;
            };
            let Some((_, v_start)) = st::find_in(xml, ">", after_t, close) else {
                break;
            };
            let Some((v_end, after_v)) = st::find_in(xml, "<", v_start, close) else {
                break;
            };
            // `Double(inner[…])` reads a Substring: an embedded NUL fails it.
            if let Some(v) = st::swift_double_substring(&xml[v_start..v_end]) {
                prices.insert(xml[t_start..t_end].to_string(), v);
            }
            inner = after_v;
        }
        if !prices.is_empty() {
            out.insert(id, prices);
        }
        search = after_close;
    }
    out
}

/// `parsePlaces`: `<place place_id="…"><x>lon</x><y>lat</y>…</place>` scanned
/// flat; kept when both read and the latitude lies in 13…34 exclusive.
#[must_use]
pub fn parse_fuel_places(xml: &str) -> BTreeMap<String, Point> {
    let mut out: BTreeMap<String, Point> = BTreeMap::new();
    let mut search = 0;
    while let Some((_, id_start)) = st::find_in(xml, "<place place_id=\"", search, xml.len()) {
        let Some((id_end, after_id)) = st::find_in(xml, "\"", id_start, xml.len()) else {
            break;
        };
        let Some((close, after_close)) = st::find_in(xml, "</place>", after_id, xml.len()) else {
            break;
        };
        let id = xml[id_start..id_end].to_string();
        let body = &xml[after_id..close];
        let tag = |name: &str| -> Option<f64> {
            let (_, s) = st::find(body, &format!("<{name}>"))?;
            let (e, _) = st::find_in(body, &format!("</{name}>"), s, body.len())?;
            st::swift_double(st::trim_whitespace_newlines(&body[s..e]))
        };
        if let (Some(x), Some(y)) = (tag("x"), tag("y")) {
            if y > 13.0 && y < 34.0 {
                out.insert(id, (y, x));
            }
        }
        search = after_close;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ring(pts: &[(f64, f64)]) -> Vec<Point> {
        pts.to_vec()
    }

    #[test]
    fn scores_follow_the_swift_bands() {
        assert_eq!(air_score(25.0), 0.1);
        assert!(air_score(f64::NAN).is_nan());
        assert!((uv_score(11.0) - 0.85).abs() < 1e-12);
        assert_eq!(space_weather_score(9), 1.0);
        assert_eq!(avalanche_rating_score(-3), 0.0);
        assert_eq!(spc_categorical_score(7), 0.0);
        assert_eq!(tropical_intensity_score(f64::NAN), 1.0);
        assert_eq!(flood_category_score("major"), 1.0);
        assert_eq!(volcano_alert_score("watch"), 0.72);
        assert_eq!(tsunami_level_score("Tsunami Warning"), 1.0);
        assert_eq!(severity_score("EXTREME"), 0.95);
        assert_eq!(backup_severity("TO"), 0.95);
    }

    #[test]
    fn polygons_and_perimeters() {
        let square = ring(&[(43.0, -89.5), (43.0, -89.0), (43.5, -89.0), (43.5, -89.5)]);
        assert!(point_in_polygon((43.25, -89.25), &square));
        assert!(!point_in_polygon((44.0, -89.25), &square));
        assert!(!point_in_polygon((43.25, -89.25), &square[..2]));
        assert_eq!(
            fire_perimeter_score(std::slice::from_ref(&square), (43.25, -89.25)),
            1.0
        );
        let fringe = fire_perimeter_score(std::slice::from_ref(&square), (43.55, -89.25));
        assert!(fringe > 0.0 && fringe < 0.7, "{fringe}");
        assert_eq!(fire_perimeter_score(&[square], (45.0, -89.25)), 0.0);
        assert!(ring_contains(
            (43.25, -89.25),
            &ring(&[(43.0, -89.5), (43.0, -89.0), (43.5, -89.0), (43.5, -89.5)])
        ));
        assert_eq!(
            all_rings(
                &[vec![
                    vec![-89.5, 43.0],
                    vec![-89.0, 43.0],
                    vec![-89.0, 43.5],
                    vec![1.0]
                ]],
                150
            ),
            vec![ring(&[(43.0, -89.5), (43.0, -89.0), (43.5, -89.0)])]
        );
        assert_eq!(all_rings(&[vec![vec![0.0, 0.0]; 400]], 150)[0].len(), 134);
    }

    #[test]
    fn the_live_assembly_and_the_clip() {
        let snap = Snapshot {
            hotspots: vec![(43.0, -89.4, 200.0), (60.0, -150.0, 5.0)],
            space: (0, 3, 4),
            ..Snapshot::default()
        };
        let clipped = snap.clipped(42.0, -90.0, 44.0, -89.0);
        assert_eq!(clipped.hotspots.len(), 1);
        let f = live((43.0, -89.4), &clipped);
        assert!(f.fire > 0.9 && f.space_radiation > 0.0);
        let names: Vec<&str> = f
            .band_input_contribution()
            .iter()
            .map(|(n, _)| *n)
            .collect();
        assert_eq!(names, vec!["fire", "radiation"]);
    }

    #[test]
    fn cells_states_and_the_corridor_math() {
        assert_eq!(cell_key((43.07, -89.4)).as_deref(), Some("172|-358"));
        assert_eq!(cell_key((f64::NAN, 0.0)), None);
        assert_eq!(states_containing((43.07, -89.4)), vec!["MI", "WI"]);
        assert_eq!(states_containing((41.9, -87.7)), vec!["IL", "MI"]);
        assert_eq!(marine_regions_containing((45.0, -87.0)), vec!["marine:GL"]);
        assert!((corridor_noisy_or(&[0.9, 0.5], &[0.5, 1.0]) - (1.0 - 0.55 * 0.5)).abs() < 1e-12);
        assert_eq!(corridor_coverage(&[0.0, 0.2, 0.0, 0.5]), 0.5);
        assert_eq!(corridor_coverage(&[]), 0.0);
        assert_eq!(worst_first(&[0.5, 0.9, 0.9, 0.1]), vec![1, 2, 0, 3]);
        let alerts = vec![
            Alert {
                id: "a".into(),
                event: "Flood Warning".into(),
                severity_score: 0.88,
                expires: Some(100.0),
                ..Alert::default()
            },
            Alert {
                id: "b".into(),
                event: "Wind Advisory".into(),
                severity_score: 0.45,
                expires: None,
                ..Alert::default()
            },
        ];
        let mut cells = BTreeMap::new();
        cells.insert("172|-358".to_string(), alerts);
        let got = provisional_samples(
            &[(43.07, -89.4), (0.0, 0.0)],
            &cells,
            Some(&[0.0, 0.0]),
            50.0,
        );
        assert_eq!(
            got[0].as_ref().map(|s| s.alert_id.clone()),
            Some(Some("a".into()))
        );
        assert!(got[1].is_none());
        let late = provisional_samples(&[(43.07, -89.4)], &cells, None, 150.0);
        assert_eq!(late[0].as_ref().map(|s| s.risk), Some(0.45));
    }

    #[test]
    fn the_cre_files_scan_flat() {
        let prices = "<places><place place_id=\"1\"><gas_price type=\"regular\">23.7</gas_price><gas_price type=\"diesel\">25.4</gas_price></place><place place_id=\"2\"><gas_price type=\"regular\">abc</gas_price></place></places>";
        let got = parse_fuel_prices(prices);
        assert_eq!(got.len(), 1);
        assert_eq!(got["1"]["diesel"], 25.4);
        let places = "<place place_id=\"1\"><x>-99.13</x><y> 19.43 </y></place><place place_id=\"2\"><x>-99</x><y>40</y></place>";
        let got = parse_fuel_places(places);
        assert_eq!(got.get("1"), Some(&(19.43, -99.13)));
        assert!(!got.contains_key("2"));
    }
}
