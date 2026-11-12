// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Which route earns which chip — Swift's `SafestRoute`, `CheapestRoute`,
//! `EfficientRoute`, `TruckerDesignation` and `FastestRoute` at the commit
//! that gathered the last of them out of the routes view. Every pick is the
//! index of the winning candidate.
//!
//! Each "lowest" is Swift's `min(by:)`: the first candidate, displaced only
//! by a later one the comparison puts strictly before it. The comparisons
//! are ported as written, including the ones that are not an ordering (a
//! NaN, the one-cent fuel tie). Pinned by
//! `flows-bridge/tests/fixtures/swift_route_designations_oracle.tsv`.

/// A tolled route gives "Cheapest" up to a toll-free one that costs no more
/// than this much extra in fuel.
pub const TOLL_ALLOWANCE_USD: f64 = 5.0;

/// Swift's `min(by:)`: the first item, displaced by each later item `before`
/// puts strictly ahead of the current one.
fn swift_min_by<T: Copy>(
    items: impl IntoIterator<Item = T>,
    before: impl Fn(T, T) -> bool,
) -> Option<T> {
    let mut best: Option<T> = None;
    for item in items {
        best = match best {
            Some(b) if !before(item, b) => Some(b),
            _ => Some(item),
        };
    }
    best
}

/// `SafestRoute.pick`: the lowest corridor risk, once every route has been
/// scored, and only when at least two routes differ (some route is riskier
/// than the pick).
///
/// Deterministic; panics: none.
#[must_use]
pub fn safest(risks: &[f64], scored: &[bool]) -> Option<usize> {
    if risks.len() != scored.len() || risks.len() < 2 || scored.iter().any(|&s| !s) {
        return None;
    }
    let (at, best) = swift_min_by(risks.iter().copied().enumerate(), |a, b| a.1 < b.1)?;
    risks.iter().any(|&r| r > best).then_some(at)
}

/// A route as "Cheapest" reads it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Cost {
    pub fuel_usd: f64,
    pub has_tolls: bool,
    pub is_walk: bool,
}

fn cheaper(a: &Cost, b: &Cost) -> bool {
    if (a.fuel_usd - b.fuel_usd).abs() > 0.01 {
        a.fuel_usd < b.fuel_usd
    } else {
        !a.has_tolls && b.has_tolls
    }
}

/// `CheapestRoute.pick`: the lowest fuel, ties (within a cent) to toll-free;
/// a tolled winner gives way to the cheapest toll-free route within
/// [`TOLL_ALLOWANCE_USD`]. `None` for no candidates or any walk.
///
/// Deterministic; panics: none.
#[must_use]
pub fn cheapest(routes: &[Cost]) -> Option<usize> {
    if routes.iter().any(|r| r.is_walk) {
        return None;
    }
    let (at, lowest) = swift_min_by(routes.iter().enumerate(), |a, b| cheaper(a.1, b.1))?;
    if !lowest.has_tolls {
        return Some(at);
    }
    let toll_free = swift_min_by(
        routes.iter().enumerate().filter(|(_, r)| !r.has_tolls),
        |a, b| cheaper(a.1, b.1),
    );
    match toll_free {
        Some((free_at, free)) if free.fuel_usd - lowest.fuel_usd <= TOLL_ALLOWANCE_USD => {
            Some(free_at)
        }
        _ => Some(at),
    }
}

/// `EfficientRoute.pick`: the shortest drive; `None` for no candidates or
/// any walk.
///
/// Deterministic; panics: none.
#[must_use]
pub fn efficient(meters: &[f64], is_walk: &[bool]) -> Option<usize> {
    if meters.len() != is_walk.len() || is_walk.iter().any(|&w| w) {
        return None;
    }
    swift_min_by(meters.iter().copied().enumerate(), |a, b| a.1 < b.1).map(|(at, _)| at)
}

/// A route as the trucker badge reads it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Truck {
    /// Passes every known clearance on the route (unknown passes).
    pub clears_bridges: bool,
    pub has_highways: bool,
    pub avoids_highways: bool,
    pub grade_ok: bool,
    pub wind_ok: bool,
    pub eta: f64,
    pub is_walk: bool,
}

/// `TruckerDesignation.score`: highways it does not avoid 3, a gentle grade
/// 2, low wind 1.
///
/// Deterministic; panics: none.
#[must_use]
pub fn trucker_score(t: &Truck) -> f64 {
    let mut s = 0.0;
    if t.has_highways && !t.avoids_highways {
        s += 3.0;
    }
    if t.grade_ok {
        s += 2.0;
    }
    if t.wind_ok {
        s += 1.0;
    }
    s
}

/// `TruckerDesignation.pick`: among drives that clear every known bridge,
/// the best score, then the shortest ETA; `None` when no drive clears. A
/// known low bridge disqualifies a route outright.
///
/// Deterministic; panics: none.
#[must_use]
pub fn trucker(routes: &[Truck]) -> Option<usize> {
    swift_min_by(
        routes
            .iter()
            .enumerate()
            .filter(|(_, t)| t.clears_bridges && !t.is_walk)
            .map(|(at, t)| (at, trucker_score(t), t.eta)),
        |a, b| if a.1 != b.1 { a.1 > b.1 } else { a.2 < b.2 },
    )
    .map(|(at, _, _)| at)
}

/// `FastestRoute.eta`: Swift's `min()` over the ETAs: the first, displaced
/// by each later one below it (a NaN first is never displaced).
///
/// Deterministic; panics: none.
#[must_use]
pub fn fastest_eta(etas: &[f64]) -> Option<f64> {
    swift_min_by(etas.iter().copied(), |a, b| a < b)
}

/// `FastestRoute.chipMinutes`: minutes behind the fastest, rounded, at
/// least 1; `None` when this route is the fastest (or its ETA is not a
/// number). Where the Swift trapped (a gap too large for an integer) the
/// answer is the largest integer: such a route is never called fastest.
///
/// Deterministic; panics: none.
#[must_use]
pub fn chip_minutes(eta: f64, fastest: f64) -> Option<i64> {
    // A saturating cast: the gap is positive here, never NaN.
    (eta > fastest).then(|| (((eta - fastest) / 60.0).round() as i64).max(1))
}

/// `FastestRoute.keyPointMinutes`: whole minutes behind the fastest; `None`
/// when it is not more than a minute behind. Saturates where the Swift
/// trapped.
///
/// Deterministic; panics: none.
#[must_use]
pub fn key_point_minutes(eta: f64, fastest: f64) -> Option<i64> {
    (eta > fastest + 60.0).then(|| ((eta - fastest) / 60.0) as i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safest_needs_every_route_scored_and_a_difference() {
        assert_eq!(safest(&[0.5, 0.25, 0.75], &[true, true, true]), Some(1));
        // The first of equal lowest.
        assert_eq!(safest(&[0.25, 0.25, 0.75], &[true, true, true]), Some(0));
        // A clear day: none is safest.
        assert_eq!(safest(&[0.0, 0.0], &[true, true]), None);
        assert_eq!(safest(&[0.5, 0.25], &[true, false]), None);
        assert_eq!(safest(&[0.5], &[true]), None);
        assert_eq!(safest(&[], &[]), None);
    }

    fn cost(fuel_usd: f64, has_tolls: bool) -> Cost {
        Cost {
            fuel_usd,
            has_tolls,
            is_walk: false,
        }
    }

    #[test]
    fn a_tolled_route_gives_cheapest_up_within_the_allowance() {
        assert_eq!(cheapest(&[cost(12.0, false), cost(10.0, false)]), Some(1));
        // The toll-free route costs $4 more in fuel: it wins.
        assert_eq!(cheapest(&[cost(10.0, true), cost(14.0, false)]), Some(1));
        // $6 more: the tolled route keeps it.
        assert_eq!(cheapest(&[cost(10.0, true), cost(16.0, false)]), Some(0));
        // Within a cent: toll-free first.
        assert_eq!(cheapest(&[cost(10.0, true), cost(10.005, false)]), Some(1));
        assert_eq!(cheapest(&[cost(10.0, true)]), Some(0));
        assert_eq!(cheapest(&[]), None);
        let walk = Cost {
            fuel_usd: 0.0,
            has_tolls: false,
            is_walk: true,
        };
        assert_eq!(cheapest(&[cost(10.0, false), walk]), None);
    }

    #[test]
    fn efficient_is_the_shortest_drive() {
        assert_eq!(efficient(&[9.0, 7.0, 7.0], &[false, false, false]), Some(1));
        assert_eq!(efficient(&[9.0, 7.0], &[false, true]), None);
        assert_eq!(efficient(&[], &[]), None);
    }

    fn truck(clears_bridges: bool, has_highways: bool, eta: f64) -> Truck {
        Truck {
            clears_bridges,
            has_highways,
            avoids_highways: false,
            grade_ok: true,
            wind_ok: true,
            eta,
            is_walk: false,
        }
    }

    #[test]
    fn a_known_low_bridge_never_wears_the_trucker_badge() {
        // The best-scoring route cannot clear: the other wins.
        assert_eq!(
            trucker(&[truck(false, true, 100.0), truck(true, false, 200.0)]),
            Some(1)
        );
        // Equal scores: the shorter ETA, the first of equals.
        assert_eq!(
            trucker(&[
                truck(true, true, 300.0),
                truck(true, true, 200.0),
                truck(true, true, 200.0)
            ]),
            Some(1)
        );
        assert_eq!(trucker(&[truck(false, true, 100.0)]), None);
        let walk = Truck {
            is_walk: true,
            ..truck(true, true, 50.0)
        };
        assert_eq!(trucker(&[walk]), None);
        assert_eq!(trucker_score(&truck(true, true, 0.0)), 6.0);
    }

    #[test]
    fn time_behind_the_fastest() {
        assert_eq!(fastest_eta(&[300.0, 200.0, 250.0]), Some(200.0));
        assert_eq!(fastest_eta(&[]), None);
        assert_eq!(chip_minutes(200.0, 200.0), None);
        // 29 seconds slower is not "Fastest": at least a minute.
        assert_eq!(chip_minutes(229.0, 200.0), Some(1));
        assert_eq!(chip_minutes(350.0, 200.0), Some(3));
        assert_eq!(chip_minutes(f64::NAN, 200.0), None);
        assert_eq!(chip_minutes(f64::INFINITY, 200.0), Some(i64::MAX));
        assert_eq!(key_point_minutes(260.0, 200.0), None);
        assert_eq!(key_point_minutes(350.0, 200.0), Some(2));
        assert_eq!(key_point_minutes(f64::INFINITY, 200.0), Some(i64::MAX));
    }
}
