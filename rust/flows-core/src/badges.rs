// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The map's hazard badges: Swift's `BadgeClustering` before its rules moved
//! here. One badge per risk area by greedy worst-first clustering, the icons
//! thinned so the map never crowds, the label each badge carries, and which
//! of a route's badges the planning map already shows.
//!
//! An item is a point in degrees, a hazard kind and a score. The Swift is
//! generic over the kind; here a kind is a number, and the Swift facade
//! numbers its kinds so that two items share a number exactly when their
//! kinds are equal. Every rule is the original's arithmetic in the
//! original's order, so the answers are the same bits and the same picks.
//!
//! One place differs, where the original never answers: the spatial grid
//! (64 or more items and a positive spacing) traps in Swift when a cell
//! number does not fit an `Int` (a NaN or infinite coordinate, or a
//! spacing so small that a coordinate over it passes 2^63). Here those
//! inputs take the linear scan, which the grid exists only to speed up.
//!
//! Pinned by `flows-bridge/tests/fixtures/swift_badge_clustering_oracle.tsv`.

use crate::fcmp::{smax, smin, swift_int};
use crate::fmath;
use crate::geo::meters;
use crate::hazard_feeds::point_in_polygon;
use crate::learning::swift_sort_by;
use crate::swift_text;
use std::collections::HashMap;
use std::f64::consts::PI;

/// A point: latitude, then longitude, in degrees.
pub type Point = (f64, f64);

/// One badge candidate.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Item {
    /// Latitude, degrees.
    pub lat: f64,
    /// Longitude, degrees.
    pub lon: f64,
    /// The hazard kind; equal numbers are equal kinds.
    pub kind: i64,
    /// How bad it is; the worst goes first.
    pub score: f64,
}

/// One cluster's badge: the item that seeded it (an index into the input)
/// and its members' score-weighted centroid. The badge keeps the seed's
/// kind and score.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Badge {
    /// The seed's index in the items passed to [`cluster`].
    pub seed: usize,
    /// The centroid's latitude.
    pub lat: f64,
    /// The centroid's longitude.
    pub lon: f64,
}

/// Above this many items the original replaced its linear seed scan by a
/// grid. Both give the same answer whenever the grid can be built.
const GRID_THRESHOLD: usize = 64;

/// The original's metres per degree, shared with [`meters`].
const METERS_PER_DEGREE: f64 = 111_320.0;

fn dist(a: &Item, b: &Item) -> f64 {
    meters(a.lat, a.lon, b.lat, b.lon)
}

/// `cluster(_:minSeparationMeters:)`: the badges, worst first.
///
/// Items sort by score, worst first, exactly as Swift's sort orders them.
/// Each joins the earliest seed of its own kind closer than `min_sep`
/// metres, else seeds a cluster of its own. A badge sits at its members'
/// centroid weighted by `max(score, 1e-4)`.
#[must_use]
pub fn cluster(items: &[Item], min_sep: f64) -> Vec<Badge> {
    let mut order: Vec<usize> = (0..items.len()).collect();
    swift_sort_by(&mut order, |a, b| items[a].score > items[b].score);
    let groups = grid_groups(items, &order, min_sep)
        .unwrap_or_else(|| linear_groups(items, &order, min_sep));
    groups
        .iter()
        .map(|group| {
            let w = |i: usize| smax(items[i].score, 1e-4);
            let weight = group.iter().fold(0.0, |acc, &i| acc + w(i));
            let lat = group.iter().fold(0.0, |acc, &i| acc + items[i].lat * w(i)) / weight;
            let lon = group.iter().fold(0.0, |acc, &i| acc + items[i].lon * w(i)) / weight;
            Badge {
                seed: group[0],
                lat,
                lon,
            }
        })
        .collect()
}

/// The linear form: each item scans every seed, first match wins.
fn linear_groups(items: &[Item], order: &[usize], min_sep: f64) -> Vec<Vec<usize>> {
    let mut groups: Vec<Vec<usize>> = Vec::new();
    for &i in order {
        let item = &items[i];
        let hit = groups.iter().position(|g| {
            let seed = &items[g[0]];
            seed.kind == item.kind && dist(seed, item) < min_sep
        });
        match hit {
            Some(si) => groups[si].push(i),
            None => groups.push(vec![i]),
        }
    }
    groups
}

/// The grid form, or `None` below the threshold, for a spacing that is not
/// positive, or where a cell number would trap in Swift.
fn grid_groups(items: &[Item], order: &[usize], min_sep: f64) -> Option<Vec<Vec<usize>>> {
    if order.len() < GRID_THRESHOLD || min_sep.is_nan() || min_sep <= 0.0 {
        return None;
    }
    let max_abs_lat = order
        .iter()
        .fold(0.0, |acc, &i| smax(acc, items[i].lat.abs()));
    let cos_min = smax(fmath::cos(max_abs_lat * PI / 180.0), 1e-6);
    let lat_cell = min_sep / METERS_PER_DEGREE;
    let lon_cell = min_sep / (METERS_PER_DEGREE * cos_min);
    let cells: Vec<(i64, i64)> = order
        .iter()
        .map(|&i| {
            let cx = swift_int((items[i].lon / lon_cell).floor())?;
            let cy = swift_int((items[i].lat / lat_cell).floor())?;
            // The original adds -1 and +1 to both.
            cx.checked_sub(1)?.checked_add(2)?;
            cy.checked_sub(1)?.checked_add(2)?;
            Some((cx, cy))
        })
        .collect::<Option<_>>()?;
    let mut grid: HashMap<(i64, i64, i64), Vec<usize>> = HashMap::new();
    let mut groups: Vec<Vec<usize>> = Vec::new();
    for (&i, &(cx, cy)) in order.iter().zip(&cells) {
        let item = &items[i];
        let mut best: Option<usize> = None;
        for dx in -1..=1 {
            for dy in -1..=1 {
                let Some(idxs) = grid.get(&(item.kind, cx + dx, cy + dy)) else {
                    continue;
                };
                for &si in idxs {
                    if best.is_some_and(|b| si >= b) {
                        continue;
                    }
                    if dist(&items[groups[si][0]], item) < min_sep {
                        best = Some(si);
                    }
                }
            }
        }
        match best {
            Some(si) => groups[si].push(i),
            None => {
                grid.entry((item.kind, cx, cy))
                    .or_default()
                    .push(groups.len());
                groups.push(vec![i]);
            }
        }
    }
    Some(groups)
}

/// `declutter(_:minSeparationMeters:)`: the indices of the icons kept,
/// worst first (equal scores in input order). An icon is kept unless one
/// already kept, of any kind, stands closer than `min_sep` metres.
#[must_use]
pub fn declutter(items: &[Item], min_sep: f64) -> Vec<usize> {
    let mut order: Vec<usize> = (0..items.len()).collect();
    swift_sort_by(&mut order, |a, b| {
        let (x, y) = (items[a].score, items[b].score);
        if x != y {
            x > y
        } else {
            a < b
        }
    });
    let mut kept: Vec<usize> = Vec::new();
    for i in order {
        if kept.iter().any(|&k| dist(&items[k], &items[i]) < min_sep) {
            continue;
        }
        kept.push(i);
    }
    kept
}

/// `labels(for:from:radiusMeters:)`: for each badge, the index of the
/// labelled item whose label it carries, or `None`. Each labelled item
/// joins the nearest badge of its kind closer than `radius` metres (the
/// first on a tie); a badge takes the worst item that joined it (the first
/// on a tie).
#[must_use]
pub fn labels(badges: &[Item], labelled: &[Item], radius: f64) -> Vec<Option<usize>> {
    let mut best: Vec<Option<(f64, usize)>> = vec![None; badges.len()];
    for (li, item) in labelled.iter().enumerate() {
        let mut nearest: Option<(usize, f64)> = None;
        for (i, badge) in badges.iter().enumerate() {
            if badge.kind != item.kind {
                continue;
            }
            let d = dist(badge, item);
            if d < radius && d < nearest.map_or(f64::INFINITY, |n| n.1) {
                nearest = Some((i, d));
            }
        }
        let Some((i, _)) = nearest else { continue };
        if item.score > best[i].map_or(f64::NEG_INFINITY, |b| b.0) {
            best[i] = Some((item.score, li));
        }
    }
    best.into_iter().map(|b| b.map(|b| b.1)).collect()
}

/// `isWarning(_:)`: whether an alert event names a warning or an
/// emergency, by Swift's `lowercased()` and Foundation's `contains`.
#[must_use]
pub fn is_warning(event: &str) -> bool {
    let lower = swift_text::lowercased(event);
    swift_text::contains(&lower, "warning") || swift_text::contains(&lower, "emergency")
}

/// `sameHazard(badgeEvent:shownEvent:)`: a warning is the same hazard only
/// as a badge naming that warning (Swift's `==`, canonical equivalence);
/// any other badge is one hazard with its kind.
#[must_use]
pub fn same_hazard(badge_event: Option<&str>, shown_event: Option<&str>) -> bool {
    let Some(badge) = badge_event.filter(|b| is_warning(b)) else {
        return true;
    };
    shown_event.is_some_and(|s| swift_text::eq(s, badge))
}

/// A ring's latitude and longitude bounds, folded the way Swift's `min`
/// and `max` fold them.
struct Bounds {
    min_lat: f64,
    max_lat: f64,
    min_lon: f64,
    max_lon: f64,
}

impl Bounds {
    fn of(ring: &[Point]) -> Bounds {
        let mut b = Bounds {
            min_lat: f64::INFINITY,
            max_lat: f64::NEG_INFINITY,
            min_lon: f64::INFINITY,
            max_lon: f64::NEG_INFINITY,
        };
        for &(lat, lon) in ring {
            b.min_lat = smin(b.min_lat, lat);
            b.max_lat = smax(b.max_lat, lat);
            b.min_lon = smin(b.min_lon, lon);
            b.max_lon = smax(b.max_lon, lon);
        }
        b
    }

    fn contains(&self, lat: f64, lon: f64) -> bool {
        lat >= self.min_lat && lat <= self.max_lat && lon >= self.min_lon && lon <= self.max_lon
    }
}

/// `unshown(_:shown:areas:mergeMeters:minor:sameHazard:)`: the indices of
/// the badges a first layer does not already show, in order.
///
/// A badge goes when a shown badge of its kind that `same(badge, shown)`
/// accepts sits closer than `merge` metres. A badge `minor` marks also goes
/// when any shown badge sits that close, or when it lies inside one of the
/// `areas`. `same` is asked only for shown badges of the badge's own kind
/// that are near it; `minor` only for badges that pass the first test.
#[must_use]
pub fn unshown(
    badges: &[Item],
    shown: &[Item],
    areas: &[Vec<Point>],
    merge: f64,
    mut minor: impl FnMut(usize) -> bool,
    mut same: impl FnMut(usize, usize) -> bool,
) -> Vec<usize> {
    let bounds: Vec<Bounds> = areas.iter().map(|r| Bounds::of(r)).collect();
    let mut out = Vec::new();
    for (bi, badge) in badges.iter().enumerate() {
        let near: Vec<usize> = (0..shown.len())
            .filter(|&si| dist(&shown[si], badge) < merge)
            .collect();
        if near
            .iter()
            .any(|&si| shown[si].kind == badge.kind && same(bi, si))
        {
            continue;
        }
        if !minor(bi) {
            out.push(bi);
            continue;
        }
        if !near.is_empty() {
            continue;
        }
        let inside = areas.iter().zip(&bounds).any(|(ring, b)| {
            b.contains(badge.lat, badge.lon) && point_in_polygon((badge.lat, badge.lon), ring)
        });
        if !inside {
            out.push(bi);
        }
    }
    out
}

/// The (badge, shown) index pairs [`unshown`] would ask its `same` rule
/// about: a shown badge of the badge's kind closer than `merge` metres.
/// A caller whose rule is costly answers only these, and nothing else is
/// asked.
#[must_use]
pub fn near_same_kind(badges: &[Item], shown: &[Item], merge: f64) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    for (bi, badge) in badges.iter().enumerate() {
        for (si, s) in shown.iter().enumerate() {
            if s.kind == badge.kind && dist(s, badge) < merge {
                out.push((bi, si));
            }
        }
    }
    out
}
