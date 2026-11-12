// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::badges`, behind Swift's
//! `BadgeClustering`. Implementations live in `flows-core`; this file only
//! crosses.
//!
//! - A list of items crosses as `[lat, lon, score, …]` triples beside one
//!   kind number per item; extra values on either side are dropped.
//! - `cluster` answers `[seed, lat, lon, …]` triples, the seed an index
//!   into the items (exact as a double). The other lists answer indices,
//!   `-1` for none; `near_pairs` answers `[badge, shown, …]` pairs.
//! - Areas cross as one point count per ring, then `[lat, lon, …]` for
//!   all rings in turn.
//! - Nothing here should panic. If something does, every answer falls to
//!   the side that hides no hazard: each item its own badge, every icon
//!   kept, no label moved, a warning counted as one and never the same
//!   hazard as another badge, no pair to ask about, and every route badge
//!   drawn.

use crate::contain;
use flows_core::badges::{self as bc, Item, Point};
use std::collections::HashSet;

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        fn flows_badges_cluster(points: &[f64], kinds: &[i64], min_sep: f64) -> Vec<f64>;
        fn flows_badges_declutter(points: &[f64], kinds: &[i64], min_sep: f64) -> Vec<i64>;
        fn flows_badges_labels(
            badge_points: &[f64],
            badge_kinds: &[i64],
            labelled_points: &[f64],
            labelled_kinds: &[i64],
            radius: f64,
        ) -> Vec<i64>;
        fn flows_badges_is_warning(event: &str) -> bool;
        fn flows_badges_same_hazard(
            has_badge: bool,
            badge_event: &str,
            has_shown: bool,
            shown_event: &str,
        ) -> bool;
        fn flows_badges_near_pairs(
            badge_points: &[f64],
            badge_kinds: &[i64],
            shown_points: &[f64],
            shown_kinds: &[i64],
            merge: f64,
        ) -> Vec<i64>;
        fn flows_badges_unshown(
            badge_points: &[f64],
            badge_kinds: &[i64],
            shown_points: &[f64],
            shown_kinds: &[i64],
            ring_lens: &[i64],
            ring_points: &[f64],
            merge: f64,
            minor: &[u8],
            same_pairs: &[i64],
        ) -> Vec<i64>;
    }
}

fn items(points: &[f64], kinds: &[i64]) -> Vec<Item> {
    points
        .chunks_exact(3)
        .zip(kinds)
        .map(|(p, &kind)| Item {
            lat: p[0],
            lon: p[1],
            kind,
            score: p[2],
        })
        .collect()
}

fn rings(lens: &[i64], flat: &[f64]) -> Vec<Vec<Point>> {
    let pts: Vec<Point> = flat.chunks_exact(2).map(|p| (p[0], p[1])).collect();
    let mut at = 0usize;
    lens.iter()
        .map(|&len| {
            let n = usize::try_from(len)
                .unwrap_or(0)
                .min(pts.len().saturating_sub(at));
            let ring = pts[at..at + n].to_vec();
            at += n;
            ring
        })
        .collect()
}

fn index(i: usize) -> i64 {
    i64::try_from(i).unwrap_or(-1)
}

pub fn flows_badges_cluster(points: &[f64], kinds: &[i64], min_sep: f64) -> Vec<f64> {
    let list = items(points, kinds);
    let own: Vec<f64> = list
        .iter()
        .enumerate()
        .flat_map(|(i, it)| [i as f64, it.lat, it.lon])
        .collect();
    contain(own, || {
        bc::cluster(&list, min_sep)
            .iter()
            .flat_map(|b| [b.seed as f64, b.lat, b.lon])
            .collect()
    })
}

pub fn flows_badges_declutter(points: &[f64], kinds: &[i64], min_sep: f64) -> Vec<i64> {
    let list = items(points, kinds);
    let all: Vec<i64> = (0..list.len()).map(index).collect();
    contain(all, || {
        bc::declutter(&list, min_sep)
            .into_iter()
            .map(index)
            .collect()
    })
}

pub fn flows_badges_labels(
    badge_points: &[f64],
    badge_kinds: &[i64],
    labelled_points: &[f64],
    labelled_kinds: &[i64],
    radius: f64,
) -> Vec<i64> {
    let badges = items(badge_points, badge_kinds);
    let labelled = items(labelled_points, labelled_kinds);
    contain(vec![-1; badges.len()], || {
        bc::labels(&badges, &labelled, radius)
            .into_iter()
            .map(|l| l.map_or(-1, index))
            .collect()
    })
}

pub fn flows_badges_is_warning(event: &str) -> bool {
    contain(true, || bc::is_warning(event))
}

pub fn flows_badges_same_hazard(
    has_badge: bool,
    badge_event: &str,
    has_shown: bool,
    shown_event: &str,
) -> bool {
    contain(false, || {
        bc::same_hazard(
            has_badge.then_some(badge_event),
            has_shown.then_some(shown_event),
        )
    })
}

pub fn flows_badges_near_pairs(
    badge_points: &[f64],
    badge_kinds: &[i64],
    shown_points: &[f64],
    shown_kinds: &[i64],
    merge: f64,
) -> Vec<i64> {
    let badges = items(badge_points, badge_kinds);
    let shown = items(shown_points, shown_kinds);
    contain(Vec::new(), || {
        bc::near_same_kind(&badges, &shown, merge)
            .into_iter()
            .flat_map(|(b, s)| [index(b), index(s)])
            .collect()
    })
}

#[allow(clippy::too_many_arguments)]
pub fn flows_badges_unshown(
    badge_points: &[f64],
    badge_kinds: &[i64],
    shown_points: &[f64],
    shown_kinds: &[i64],
    ring_lens: &[i64],
    ring_points: &[f64],
    merge: f64,
    minor: &[u8],
    same_pairs: &[i64],
) -> Vec<i64> {
    let badges = items(badge_points, badge_kinds);
    let all: Vec<i64> = (0..badges.len()).map(index).collect();
    contain(all, || {
        let shown = items(shown_points, shown_kinds);
        let areas = rings(ring_lens, ring_points);
        let same: HashSet<(i64, i64)> = same_pairs.chunks_exact(2).map(|p| (p[0], p[1])).collect();
        bc::unshown(
            &badges,
            &shown,
            &areas,
            merge,
            |b| minor.get(b).is_some_and(|&m| m != 0),
            |b, s| same.contains(&(index(b), index(s))),
        )
        .into_iter()
        .map(index)
        .collect()
    })
}
