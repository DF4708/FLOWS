// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Bicriteria RAPTOR over a [`Timetable`]: earliest arrival while minimizing the
//! number of transfers. Round `k` of the loop uses at most `k` trips (so `k-1`
//! transfers); scanning `max_rounds` rounds yields, for each transfer count, the
//! earliest arrival — and the strictly-improving rounds are exactly the
//! **Pareto frontier** over (arrival, transfers). That is what surfaces to the UI
//! as "fast but more transfers" vs. "fewer transfers but slower".
//!
//! Transfers (walking between nearby stops) and rides live in one loop over one
//! merged timetable, so an intercity ride, a station-to-platform walk, and a
//! local subway ride chain with no special-casing. The algorithm is pure array
//! walking — no priority queue, no allocation in the hot loop beyond the fixed
//! per-round label arrays — matching the CSR discipline in `routing.rs`/`ch.rs`.

use super::{Mode, Time, Timetable};

/// Sentinel "unreached" arrival time.
pub const INF_TIME: Time = Time::MAX;

/// How a stop was reached with `k` trips — enough to walk the itinerary back.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Parent {
    /// Not reached at this round.
    Unreached,
    /// The origin, seeded at round 0.
    Source,
    /// Arrived by riding `route`'s `trip`, boarding at stop `board` (pattern
    /// position `board_pos`) and alighting at pattern position `alight_pos`.
    Ride {
        route: u32,
        trip: u32,
        board: u32,
        board_pos: u32,
        alight_pos: u32,
    },
    /// Arrived on foot from `from` in `secs` (a source walk at round 0, or a
    /// transfer after a ride at round `k`).
    Walk { from: u32, secs: Time },
}

/// One itinerary leg — a ride or a walk.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LegKind {
    Ride,
    Walk,
}

/// A concrete leg of a reconstructed journey.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Leg {
    pub kind: LegKind,
    pub from_stop: u32,
    pub to_stop: u32,
    pub dep: Time,
    pub arr: Time,
    /// Ride legs only; `u32::MAX` on a walk.
    pub route: u32,
    /// Ride legs only; `u32::MAX` on a walk.
    pub trip: u32,
    /// Ride legs only (ignored on a walk).
    pub mode: Mode,
}

/// A full origin→destination itinerary: an ordered leg list plus its summary
/// criteria. `n_transfers` is the honest count from the legs (ride legs minus one).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Journey {
    pub legs: Vec<Leg>,
    pub arrival: Time,
    pub n_transfers: u32,
    pub walk_secs: Time,
}

/// Mutable per-query RAPTOR state. Kept in one struct so `plan` and
/// `earliest_arrival` share the loop without recomputation.
struct Raptor<'a> {
    tt: &'a Timetable,
    /// `round_arr[k][stop]` = earliest arrival at `stop` using at most `k` trips.
    round_arr: Vec<Vec<Time>>,
    /// `parent[k][stop]` = how `stop` is reached with at most `k` trips.
    parent: Vec<Vec<Parent>>,
    /// `best_arr[stop]` = earliest arrival over all rounds so far (for pruning).
    best_arr: Vec<Time>,
    /// The rounds actually populated (`0..=rounds_run`).
    rounds_run: u32,
}

impl<'a> Raptor<'a> {
    fn run(tt: &'a Timetable, source: u32, target: u32, depart: Time, max_rounds: u32) -> Self {
        let n = tt.n_stops();
        let k_max = max_rounds as usize;
        let mut r = Raptor {
            tt,
            round_arr: vec![vec![INF_TIME; n]; k_max + 1],
            parent: vec![vec![Parent::Unreached; n]; k_max + 1],
            best_arr: vec![INF_TIME; n],
            rounds_run: 0,
        };

        // --- Round 0: the origin, plus everything a source walk reaches. ---
        r.round_arr[0][source as usize] = depart;
        r.parent[0][source as usize] = Parent::Source;
        r.best_arr[source as usize] = depart;
        let mut queue: Vec<u32> = vec![source];
        for fp in tt.footpaths_at(source) {
            let arr = depart.saturating_add(fp.secs);
            if arr < r.best_arr[fp.to as usize] {
                r.round_arr[0][fp.to as usize] = arr;
                r.best_arr[fp.to as usize] = arr;
                r.parent[0][fp.to as usize] = Parent::Walk {
                    from: source,
                    secs: fp.secs,
                };
                queue.push(fp.to);
            }
        }

        // --- Rounds 1..=max_rounds. ---
        // Per-round scratch hoisted OUT of the loop: route_hop was an
        // O(n_routes) allocate+fill per round and touched/trip_marked fresh
        // Vecs — reused now, with route_hop reset only at its touched
        // entries after each round.
        let mut marked = vec![false; n];
        let mut route_hop: Vec<u32> = vec![u32::MAX; tt.n_routes()];
        let mut touched_routes: Vec<u32> = Vec::new();
        let mut trip_marked: Vec<u32> = Vec::new();
        for k in 1..=k_max {
            r.rounds_run = k as u32;
            // A stop reachable with k-1 trips is reachable with k; carry forward
            // both the arrival bound and its provenance so reconstruction of a
            // round-k journey can follow a boarding stop back through round k-1.
            // split_at_mut gives DISJOINT flat prev/cur rows: the copy lands in
            // the already-allocated row k (the old per-round `.clone()`
            // allocated a fresh n-length Vec and threw away its INF-fill), and
            // the scan below reads/writes plain slices instead of nested Vec
            // derefs the optimizer can't prove disjoint.
            let (prev_rounds, cur_rounds) = r.round_arr.split_at_mut(k);
            let prev_row: &[Time] = &prev_rounds[k - 1];
            let cur_row: &mut [Time] = &mut cur_rounds[0];
            cur_row.copy_from_slice(prev_row);
            let (prev_parents, cur_parents) = r.parent.split_at_mut(k);
            let cur_parent: &mut [Parent] = &mut cur_parents[0];
            cur_parent.copy_from_slice(&prev_parents[k - 1]);

            // Collect the routes touching any stop marked in the previous round,
            // each at the EARLIEST pattern position we can board it from.
            // route -> earliest boardable position (u32::MAX if not queued).
            touched_routes.clear();
            for &p in &queue {
                for sr in tt.routes_at(p) {
                    let cur = route_hop[sr.route as usize];
                    if cur == u32::MAX {
                        touched_routes.push(sr.route);
                        route_hop[sr.route as usize] = sr.pos;
                    } else if sr.pos < cur {
                        route_hop[sr.route as usize] = sr.pos;
                    }
                }
            }
            queue.clear();

            // Scan each touched route once, from its earliest boardable stop.
            trip_marked.clear();
            for &route in &touched_routes {
                let hop = route_hop[route as usize];
                let len = tt.route_len(route);
                let route_stops = tt.route_stop_ids(route);
                let mut cur_trip: Option<u32> = None;
                let mut board_stop = 0u32;
                let mut board_pos = 0u32;
                let mut pos = hop;
                // Target pruning bound, loaded ONCE per route scan instead of
                // per stop (stores to best_arr[stop_id] alias it, so the
                // compiler could never hoist this load): the only in-scan
                // store that can lower it is the alight store at the target
                // itself, mirrored into the local below. Footpath relaxation
                // runs after all route scans, so the values are identical.
                let mut target_bound = r.best_arr[target as usize];
                while pos < len {
                    let stop_id = route_stops[pos as usize];
                    // (1) Alight: if riding a trip, try to improve this stop.
                    if let Some(t) = cur_trip {
                        let arr = tt.event(route, t, pos).arr;
                        let bound = r.best_arr[stop_id as usize].min(target_bound);
                        if arr < bound {
                            cur_row[stop_id as usize] = arr;
                            r.best_arr[stop_id as usize] = arr;
                            if stop_id == target {
                                target_bound = arr;
                            }
                            cur_parent[stop_id as usize] = Parent::Ride {
                                route,
                                trip: t,
                                board: board_stop,
                                board_pos,
                                alight_pos: pos,
                            };
                            if !marked[stop_id as usize] {
                                marked[stop_id as usize] = true;
                                trip_marked.push(stop_id);
                            }
                        }
                    }
                    // (2) Board: if we were here with <=k-1 trips early enough to
                    // catch a trip departing no sooner, hop on the earliest one —
                    // only ever moving to a strictly earlier trip.
                    let prev = prev_row[stop_id as usize];
                    if prev != INF_TIME {
                        if let Some(et) = tt.earliest_trip(route, pos, prev) {
                            let take = match cur_trip {
                                None => true,
                                Some(cur) => et < cur,
                            };
                            if take {
                                cur_trip = Some(et);
                                board_stop = stop_id;
                                board_pos = pos;
                            }
                        }
                    }
                    pos += 1;
                }
            }
            // Reset route_hop at ONLY the entries this round touched — the
            // O(n_routes) refill was per-round waste.
            for &route in &touched_routes {
                route_hop[route as usize] = u32::MAX;
            }

            // Relax bounded footpaths from the stops trips improved this round.
            // Footpaths are transitively reduced offline, so a single hop suffices.
            for &q in &trip_marked {
                let base = cur_row[q as usize];
                for fp in tt.footpaths_at(q) {
                    let arr = base.saturating_add(fp.secs);
                    if arr < cur_row[fp.to as usize] {
                        cur_row[fp.to as usize] = arr;
                        if arr < r.best_arr[fp.to as usize] {
                            r.best_arr[fp.to as usize] = arr;
                        }
                        cur_parent[fp.to as usize] = Parent::Walk {
                            from: q,
                            secs: fp.secs,
                        };
                        if !marked[fp.to as usize] {
                            marked[fp.to as usize] = true;
                        }
                        // Footpath targets seed the next round's route scan too.
                        queue.push(fp.to);
                    }
                }
            }
            // The trip-marked stops also seed the next round.
            for &q in &trip_marked {
                queue.push(q);
            }
            // Reset the mark flags for the next round (cheap; `marked` is a scratch
            // dedup within a round, not a running set).
            for &q in &trip_marked {
                marked[q as usize] = false;
            }
            for &q in &queue {
                marked[q as usize] = false;
            }

            if queue.is_empty() {
                break;
            }
        }
        r
    }

    /// Reconstruct the itinerary that reaches `target` with exactly `k` rounds.
    fn reconstruct(&self, k: usize, target: u32) -> Journey {
        let mut legs: Vec<Leg> = Vec::new();
        let mut cur_k = k;
        let mut cur = target;
        loop {
            match self.parent[cur_k][cur as usize] {
                Parent::Source => break,
                Parent::Unreached => break,
                Parent::Walk { from, secs } => {
                    let arr = self.round_arr[cur_k][cur as usize];
                    legs.push(Leg {
                        kind: LegKind::Walk,
                        from_stop: from,
                        to_stop: cur,
                        dep: arr.saturating_sub(secs),
                        arr,
                        route: u32::MAX,
                        trip: u32::MAX,
                        mode: Mode::Rail,
                    });
                    cur = from;
                    // A walk stays within the same round (footpaths don't consume
                    // a trip); the from-stop's round-`cur_k` parent is the ride.
                }
                Parent::Ride {
                    route,
                    trip,
                    board,
                    board_pos,
                    alight_pos,
                } => {
                    let dep = self.tt.event(route, trip, board_pos).dep;
                    let arr = self.tt.event(route, trip, alight_pos).arr;
                    legs.push(Leg {
                        kind: LegKind::Ride,
                        from_stop: board,
                        to_stop: cur,
                        dep,
                        arr,
                        route,
                        trip,
                        mode: self.tt.route_mode(route),
                    });
                    cur = board;
                    cur_k -= 1;
                }
            }
        }
        legs.reverse();
        let n_rides = legs.iter().filter(|l| l.kind == LegKind::Ride).count() as u32;
        let walk_secs = legs
            .iter()
            .filter(|l| l.kind == LegKind::Walk)
            .map(|l| l.arr.saturating_sub(l.dep))
            .sum();
        Journey {
            arrival: self.round_arr[k][target as usize],
            n_transfers: n_rides.saturating_sub(1),
            walk_secs,
            legs,
        }
    }
}

/// Plan the Pareto-optimal itineraries from `source` to `target` departing at
/// `depart`, exploring up to `max_rounds` trips. Returns journeys on the
/// (arrival-time, transfer-count) frontier — each additional allowed transfer is
/// kept only if it yields a **strictly earlier** arrival — ordered by increasing
/// transfers (so index 0 is the fewest-transfers option).
pub fn plan(
    tt: &Timetable,
    source: u32,
    target: u32,
    depart: Time,
    max_rounds: u32,
) -> Vec<Journey> {
    if source == target {
        return Vec::new();
    }
    let r = Raptor::run(tt, source, target, depart, max_rounds);

    // Candidate journeys: one per round whose target arrival strictly improved on
    // the best with fewer trips. The round index is only an UPPER bound on the
    // trip count — because `parent[k]` carries a stop's fewer-trip provenance
    // forward, a round-k reconstruction can use fewer than k rides. So reconstruct,
    // count transfers from the actual legs, then take the true non-dominated set.
    let mut cand: Vec<Journey> = Vec::new();
    let mut prev = INF_TIME;
    for k in 0..=r.rounds_run as usize {
        let arr = r.round_arr[k][target as usize];
        if arr < prev {
            let j = r.reconstruct(k, target);
            if !j.legs.is_empty() {
                cand.push(j);
            }
            prev = arr;
        }
    }

    // Pareto filter over (arrival↓, transfers↓): sort by transfers then arrival and
    // keep a journey only if it arrives strictly earlier than every fewer-transfer
    // option kept so far — dropping any dominated point. The result is ordered by
    // increasing transfers with strictly decreasing arrival: exactly the tradeoff
    // set ("fewer transfers but slower" → "more transfers but faster") the UI shows.
    cand.sort_by(|a, b| {
        a.n_transfers
            .cmp(&b.n_transfers)
            .then(a.arrival.cmp(&b.arrival))
    });
    let mut out: Vec<Journey> = Vec::new();
    let mut best_arr = INF_TIME;
    for j in cand {
        if j.arrival < best_arr {
            best_arr = j.arrival;
            out.push(j);
        }
    }
    out
}

/// The earliest arrival at `target` over ALL transfer counts (up to `max_rounds`),
/// or [`INF_TIME`] if unreachable. This is the unbounded-transfer optimum RAPTOR
/// converges to — the quantity checked against the reference algorithm.
pub fn earliest_arrival(
    tt: &Timetable,
    source: u32,
    target: u32,
    depart: Time,
    max_rounds: u32,
) -> Time {
    if source == target {
        return depart;
    }
    let r = Raptor::run(tt, source, target, depart, max_rounds);
    r.best_arr[target as usize]
}

// -----------------------------------------------------------------------------
// Tests — the capability proofs (transfers, local+intercity in one graph, Pareto)
// and the correctness gate against a reference time-dependent Dijkstra.
// -----------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use crate::transit::{Mode, StopEvent, Time, TimetableBuilder, INF_TIME as INF};

    /// `(arr, dep)` at one stop.
    fn ev(arr: Time, dep: Time) -> StopEvent {
        StopEvent { arr, dep }
    }

    /// A round-number of rounds generous enough to converge on small graphs.
    const K: u32 = 12;

    #[test]
    fn direct_ride_no_transfer() {
        // A --route0--> B --route0--> C, one trip. Plan A->C = one ride, 0 transfers.
        let mut b = TimetableBuilder::new();
        let a = b.add_stop(0, 0);
        let bb = b.add_stop(0, 1_000_000);
        let c = b.add_stop(0, 2_000_000);
        b.add_route(
            &[a, bb, c],
            vec![vec![ev(0, 0), ev(600, 630), ev(1200, 1200)]],
            Mode::Rail,
        );
        let js = plan(&b.build(), a, c, 0, K);
        assert_eq!(js.len(), 1, "one Pareto option");
        assert_eq!(js[0].n_transfers, 0);
        assert_eq!(js[0].legs.len(), 1);
        assert_eq!(js[0].legs[0].kind, LegKind::Ride);
        assert_eq!(js[0].arrival, 1200);
    }

    #[test]
    fn multi_hop_transfer_at_shared_station() {
        // route0: A->B ; route1: B->C. A->C must transfer at B (Miami->Atlanta->
        // Chicago in miniature). One graph, one query, two rides + one transfer.
        let mut b = TimetableBuilder::new();
        let a = b.add_stop(0, 0);
        let bb = b.add_stop(0, 1_000_000);
        let c = b.add_stop(0, 2_000_000);
        b.add_route(&[a, bb], vec![vec![ev(0, 0), ev(600, 600)]], Mode::Rail);
        b.add_route(&[bb, c], vec![vec![ev(900, 900), ev(1500, 1500)]], Mode::Rail);
        let js = plan(&b.build(), a, c, 0, K);
        assert_eq!(js.len(), 1);
        let j = &js[0];
        assert_eq!(j.n_transfers, 1, "one transfer at the shared station B");
        assert_eq!(j.legs.len(), 2);
        assert!(j.legs.iter().all(|l| l.kind == LegKind::Ride));
        assert_eq!(j.legs[0].from_stop, a);
        assert_eq!(j.legs[0].to_stop, bb);
        assert_eq!(j.legs[1].from_stop, bb);
        assert_eq!(j.legs[1].to_stop, c);
        assert_eq!(j.arrival, 1500);
    }

    #[test]
    fn walking_transfer_between_nearby_stops() {
        // route0: A->B (rail). Walk B->C (300 m footpath). route1: C->D (subway).
        // The plan must include the WALK leg between the two networks' stations.
        let mut b = TimetableBuilder::new();
        let a = b.add_stop(0, 0);
        let bb = b.add_stop(0, 1_000_000);
        let c = b.add_stop(10, 1_000_010);
        let d = b.add_stop(0, 2_000_000);
        b.add_route(&[a, bb], vec![vec![ev(0, 0), ev(600, 600)]], Mode::Rail);
        b.add_route(&[c, d], vec![vec![ev(900, 900), ev(1500, 1500)]], Mode::Subway);
        b.add_footpath(bb, c, 120); // 2-minute walk between stations
        let js = plan(&b.build(), a, d, 0, K);
        assert_eq!(js.len(), 1);
        let j = &js[0];
        let kinds: Vec<LegKind> = j.legs.iter().map(|l| l.kind).collect();
        assert_eq!(kinds, vec![LegKind::Ride, LegKind::Walk, LegKind::Ride]);
        let walk = j.legs.iter().find(|l| l.kind == LegKind::Walk).unwrap();
        assert_eq!(walk.from_stop, bb);
        assert_eq!(walk.to_stop, c);
        assert_eq!(walk.arr - walk.dep, 120);
        assert_eq!(j.arrival, 1500);
        // Local subway leg carries its mode through.
        assert_eq!(j.legs[2].mode, Mode::Subway);
    }

    #[test]
    fn pareto_frontier_fast_vs_fewer_transfers() {
        // Two ways A->C:
        //   direct route2 A->C: slow (arrive 3000), 0 transfers.
        //   route0 A->B + route1 B->C: fast (arrive 1500), 1 transfer.
        // A Pareto planner must return BOTH — neither dominates the other.
        let mut b = TimetableBuilder::new();
        let a = b.add_stop(0, 0);
        let bb = b.add_stop(0, 1_000_000);
        let c = b.add_stop(0, 2_000_000);
        b.add_route(&[a, bb], vec![vec![ev(0, 0), ev(600, 600)]], Mode::Rail);
        b.add_route(&[bb, c], vec![vec![ev(700, 700), ev(1500, 1500)]], Mode::Rail);
        b.add_route(&[a, c], vec![vec![ev(0, 0), ev(3000, 3000)]], Mode::Coach);
        let js = plan(&b.build(), a, c, 0, K);
        assert_eq!(js.len(), 2, "both frontier options returned");
        // Ordered by increasing transfers: index 0 = the direct (0-transfer) coach,
        // index 1 = the faster 1-transfer chain.
        assert_eq!(js[0].n_transfers, 0);
        assert_eq!(js[0].arrival, 3000);
        assert_eq!(js[1].n_transfers, 1);
        assert_eq!(js[1].arrival, 1500);
        // The faster option arrives earlier but costs a transfer — a real tradeoff.
        assert!(js[1].arrival < js[0].arrival);
        assert!(js[1].n_transfers > js[0].n_transfers);
    }

    #[test]
    fn misses_early_trip_then_catches_a_later_one() {
        // Two trips on route0. Departing at t=500 misses the 0-dep trip and must
        // board the 1000-dep trip.
        let mut b = TimetableBuilder::new();
        let a = b.add_stop(0, 0);
        let c = b.add_stop(0, 1_000_000);
        b.add_route(
            &[a, c],
            vec![vec![ev(0, 0), ev(600, 600)], vec![ev(1000, 1000), ev(1600, 1600)]],
            Mode::Bus,
        );
        let js = plan(&b.build(), a, c, 500, K);
        assert_eq!(js.len(), 1);
        assert_eq!(js[0].arrival, 1600, "catches the later trip, not the missed one");
        assert_eq!(js[0].legs[0].dep, 1000);
    }

    #[test]
    fn unreachable_returns_empty() {
        // route0: A->B ; route1: C->D. No path A->D (no shared stop, no footpath).
        let mut b = TimetableBuilder::new();
        let a = b.add_stop(0, 0);
        let bb = b.add_stop(0, 1);
        let c = b.add_stop(0, 2);
        let d = b.add_stop(0, 3);
        b.add_route(&[a, bb], vec![vec![ev(0, 0), ev(600, 600)]], Mode::Rail);
        b.add_route(&[c, d], vec![vec![ev(0, 0), ev(600, 600)]], Mode::Rail);
        let tt = b.build();
        assert!(plan(&tt, a, d, 0, K).is_empty());
        assert_eq!(earliest_arrival(&tt, a, d, 0, K), INF);
    }

    // ---- Correctness gate: RAPTOR earliest arrival == reference Dijkstra. ----

    /// A tiny deterministic LCG so random timetables are reproducible without any
    /// external rng crate (Numerical Recipes constants).
    struct Lcg(u64);
    impl Lcg {
        fn next(&mut self) -> u64 {
            self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            self.0
        }
        fn range(&mut self, lo: u32, hi: u32) -> u32 {
            lo + (self.next() >> 33) as u32 % (hi - lo)
        }
    }

    /// Reference earliest-arrival (unbounded transfers) by time-dependent
    /// label-setting Dijkstra over the SAME timetable — the independent oracle.
    /// Settling a stop at its final arrival, then boarding the earliest catchable
    /// trip on every serving route and relaxing every downstream stop, plus every
    /// footpath, yields the true earliest arrival.
    fn reference_earliest(tt: &crate::transit::Timetable, source: u32, target: u32, depart: Time) -> Time {
        let n = tt.n_stops();
        let mut arr = vec![INF; n];
        let mut settled = vec![false; n];
        arr[source as usize] = depart;
        loop {
            let mut u = usize::MAX;
            let mut best = INF;
            for s in 0..n {
                if !settled[s] && arr[s] < best {
                    best = arr[s];
                    u = s;
                }
            }
            if u == usize::MAX {
                break;
            }
            settled[u] = true;
            let a = arr[u];
            for fp in tt.footpaths_at(u as u32) {
                let cand = a.saturating_add(fp.secs);
                if cand < arr[fp.to as usize] {
                    arr[fp.to as usize] = cand;
                }
            }
            for sr in tt.routes_at(u as u32) {
                if let Some(t) = tt.earliest_trip(sr.route, sr.pos, a) {
                    let len = tt.route_len(sr.route);
                    let mut pos = sr.pos + 1;
                    while pos < len {
                        let s2 = tt.route_stop_ids(sr.route)[pos as usize];
                        let cand = tt.event(sr.route, t, pos).arr;
                        if cand < arr[s2 as usize] {
                            arr[s2 as usize] = cand;
                        }
                        pos += 1;
                    }
                }
            }
        }
        arr[target as usize]
    }

    /// Build a valid random timetable: routes share a fixed cumulative
    /// arrival/dwell offset pattern shifted by an increasing per-trip base, so
    /// trips never overtake (a RAPTOR precondition) by construction.
    fn random_timetable(seed: u64) -> (crate::transit::Timetable, u32) {
        let mut rng = Lcg(seed);
        let mut b = TimetableBuilder::new();
        let n_stops = rng.range(5, 11);
        for _ in 0..n_stops {
            b.add_stop(rng.range(0, 1000) as i32, rng.range(0, 1000) as i32);
        }
        let n_routes = rng.range(3, 8);
        for _ in 0..n_routes {
            // Pick a distinct ordered stop subset of length 2..=4.
            let plen = rng.range(2, 5).min(n_stops);
            let mut pattern: Vec<u32> = Vec::new();
            let mut guard = 0;
            while (pattern.len() as u32) < plen && guard < 100 {
                let s = rng.range(0, n_stops);
                if !pattern.contains(&s) {
                    pattern.push(s);
                }
                guard += 1;
            }
            if pattern.len() < 2 {
                continue;
            }
            // Fixed offset pattern (cumulative), shared by all trips of this route.
            let mut arr_off = vec![0u32];
            let mut dep_off = vec![0u32];
            for _ in 1..pattern.len() {
                let travel = rng.range(200, 900);
                let prev_dep = *dep_off.last().unwrap();
                let a = prev_dep + travel;
                let dwell = rng.range(0, 120);
                arr_off.push(a);
                dep_off.push(a + dwell);
            }
            let n_trips = rng.range(1, 5);
            let mut base = rng.range(0, 600);
            let mut trips = Vec::new();
            for _ in 0..n_trips {
                let mut trip = Vec::new();
                for j in 0..pattern.len() {
                    trip.push(ev(base + arr_off[j], base + dep_off[j]));
                }
                trips.push(trip);
                base += rng.range(300, 1200); // strictly increasing => non-overtaking
            }
            b.add_route(&pattern, trips, Mode::Bus);
        }
        // Random footpaths, then TRANSITIVELY CLOSED (all-pairs shortest walk via
        // Floyd–Warshall). Closure matches the engine's contract — the offline
        // builder emits a bounded, transitively-reduced/closed footpath set, so a
        // single walk hop per transfer reaches everything walkable. Without this
        // the reference Dijkstra (which chains walk→walk) and RAPTOR (one walk per
        // transfer) would disagree on a technicality that never occurs in
        // production, masking the ride/transfer correctness the gate exists to check.
        let n = n_stops as usize;
        let mut w = vec![vec![INF; n]; n];
        for (i, row) in w.iter_mut().enumerate() {
            row[i] = 0;
        }
        let n_fp = rng.range(0, n_stops);
        for _ in 0..n_fp {
            let x = rng.range(0, n_stops) as usize;
            let y = rng.range(0, n_stops) as usize;
            if x != y {
                let s = rng.range(30, 400);
                if s < w[x][y] {
                    w[x][y] = s;
                }
            }
        }
        for k in 0..n {
            for i in 0..n {
                if w[i][k] == INF {
                    continue;
                }
                for j in 0..n {
                    let cand = w[i][k].saturating_add(w[k][j]);
                    if cand < w[i][j] {
                        w[i][j] = cand;
                    }
                }
            }
        }
        for (i, row) in w.iter().enumerate() {
            for (j, &wij) in row.iter().enumerate() {
                if i != j && wij != INF {
                    b.add_footpath(i as u32, j as u32, wij);
                }
            }
        }
        (b.build(), n_stops)
    }

    #[test]
    fn correctness_gate_matches_reference_dijkstra() {
        // For many random timetables and OD pairs, RAPTOR's earliest arrival must
        // equal the independent time-dependent Dijkstra oracle — the ch.rs-vs-
        // Dijkstra discipline applied to transit.
        let mut checks = 0;
        for seed in 1..=60u64 {
            let (tt, n) = random_timetable(seed.wrapping_mul(0x9E3779B97F4A7C15));
            for s in 0..n {
                for t in 0..n {
                    if s == t {
                        continue;
                    }
                    let depart = (seed as u32 * 7) % 500;
                    let got = earliest_arrival(&tt, s, t, depart, n + 2);
                    let want = reference_earliest(&tt, s, t, depart);
                    assert_eq!(
                        got, want,
                        "seed {seed}: earliest {s}->{t}@{depart}: raptor {got} != dijkstra {want}"
                    );
                    checks += 1;
                }
            }
        }
        assert!(checks > 1000, "gate should exercise many OD pairs, ran {checks}");
    }

    #[test]
    fn plan_frontier_arrivals_are_reachable_and_ordered() {
        // Cross-check plan() against earliest_arrival(): the last (most-transfers)
        // frontier journey must arrive at the global earliest, and arrivals must
        // strictly decrease as transfers increase.
        for seed in 1..=40u64 {
            let (tt, n) = random_timetable(seed.wrapping_mul(0xD1B54A32D192ED03));
            for s in 0..n {
                for t in 0..n {
                    if s == t {
                        continue;
                    }
                    let js = plan(&tt, s, t, 0, n + 2);
                    let best = earliest_arrival(&tt, s, t, 0, n + 2);
                    if best == INF {
                        assert!(js.is_empty());
                        continue;
                    }
                    assert!(!js.is_empty());
                    assert_eq!(js.last().unwrap().arrival, best, "frontier reaches the optimum");
                    for w in js.windows(2) {
                        assert!(w[1].arrival < w[0].arrival, "arrival strictly improves");
                        assert!(w[1].n_transfers > w[0].n_transfers, "at a transfer cost");
                    }
                    // Every journey's legs must chain end-to-end from s to t.
                    for j in &js {
                        assert_eq!(j.legs.first().unwrap().from_stop, s);
                        assert_eq!(j.legs.last().unwrap().to_stop, t);
                        for w in j.legs.windows(2) {
                            assert_eq!(w[0].to_stop, w[1].from_stop, "legs must chain");
                        }
                    }
                }
            }
        }
    }
}
