// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! On-device public-transit routing — the pure-Rust engine that gives FLOWS real
//! multi-hop intercity routing with **transfers**, **local** subway/bus legs on
//! real networks, and **mixed-mode Pareto** itineraries (fast-but-more-transfers
//! vs. fewer-transfers-but-slower). It replaces the MapKit stopgap, which could do
//! none of these because MapKit exposes no transit routing to third-party apps.
//!
//! Algorithm: RAPTOR (Round-bAsed Public Transit Optimized Router,
//! Delling/Pajor/Werneck). Round `k` = at most `k-1` transfers, so the
//! time-vs-transfers Pareto frontier falls out of the rounds for free; local and
//! intercity networks live in ONE merged timetable, so a query rides an intercity
//! route, transfers at a station that is also a local stop, then rides local
//! rounds — with no special-casing. Pure array-walking: no priority queue, no
//! external crate. See `docs/TRANSIT_ROUTING.md`.
//!
//! Phase 0 (this module): the in-memory CSR [`Timetable`] + [`TimetableBuilder`]
//! and bicriteria RAPTOR ([`raptor`]). The mmap `.ftt` reader, the offline GTFS
//! builder, region-scoping, and the FFI surface land in later phases; the CSR
//! layout here is exactly what the `.ftt` sections deserialize into, so the engine
//! does not change when real feeds arrive.

pub mod ftt;
pub mod gtfs;
pub mod raptor;

pub use raptor::{plan, Journey, Leg, LegKind, INF_TIME};

/// Seconds since the service day's midnight. GTFS permits times past 24:00:00
/// (a trip that departs after midnight), so this is a plain monotone counter, not
/// a wall clock — 25 bits already covers a full year of seconds, and `u32` leaves
/// headroom, matching the `.ftt` STOPEVENTS field width.
pub type Time = u32;

/// A boarding/alighting event for one (trip, stop): when the vehicle arrives and
/// when it departs. 8 bytes — the memory-dominant unit at NA scale, so the whole
/// resident budget reduces to `8 × Σ stop-events` (see the module docs).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StopEvent {
    pub arr: Time,
    pub dep: Time,
}

/// A stop with a fixed-point position. `1e6`-scaled `i32` lat/lon halves the STOPS
/// section vs. `f64` and is exact to ~0.1 m — plenty for boarding resolution.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stop {
    pub lat_e6: i32,
    pub lon_e6: i32,
}

/// Which vehicle a route runs — carried through so the UI can label a leg subway
/// vs. coach and the planner can weight modes later. Byte-sized for the `.ftt`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Mode {
    Rail = 0,
    Subway = 1,
    Bus = 2,
    Coach = 3,
    Commuter = 4,
}

/// A RAPTOR "route": a maximal set of trips that visit the **identical ordered
/// stop sequence** and do not overtake one another (so trips sort consistently by
/// departure at every stop). GTFS `route_id`s are split into as many RAPTOR routes
/// as they have distinct stop patterns; the offline builder does that split, and
/// [`TimetableBuilder`] assumes each `add_route` is already one clean pattern.
///
/// Stored CSR-style in [`Timetable`]: this struct only holds the offsets/counts
/// that slice into the shared flat arrays, mirroring the `.ftt` ROUTES section.
#[derive(Clone, Copy, Debug)]
struct RouteMeta {
    /// Index into `Timetable::route_stops` where this route's stop ids begin.
    stop_start: u32,
    /// Number of stops in the pattern (also the stride of one trip's stop-events).
    n_stops: u32,
    /// Index into `Timetable::stop_events` where trip 0's events begin. Trip `t`,
    /// stop position `j` is at `event_start + t * n_stops + j` (trip-major).
    event_start: u32,
    /// Number of trips on this route.
    n_trips: u32,
    pub mode: Mode,
}

/// One (route, position) membership: "route `route` visits this stop at index
/// `pos` in its pattern." RAPTOR uses this to find, for a marked stop, the routes
/// worth scanning and where along them to start.
#[derive(Clone, Copy, Debug)]
struct StopRoute {
    route: u32,
    pos: u32,
}

/// A walking transfer between two nearby stops: reach `to` `secs` after arriving
/// at the from-stop. Bounded and transitively reduced offline so the set stays
/// near-linear. Self-loops are not stored.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Footpath {
    pub to: u32,
    pub secs: Time,
}

/// The immutable, CSR-packed timetable a query runs over. In Phase 0 it is built in
/// memory by [`TimetableBuilder`]; in Phase 1 the same field layout is a zero-copy
/// view over the mmap'd `.ftt` sections — the algorithm is identical either way.
pub struct Timetable {
    pub(crate) stops: Vec<Stop>,

    // Routes, CSR. `routes[r]` describes route r; its stop ids live in
    // `route_stops[stop_start .. stop_start + n_stops]`, and its stop-events in
    // `stop_events[event_start .. event_start + n_trips * n_stops]` (trip-major).
    routes: Vec<RouteMeta>,
    route_stops: Vec<u32>,
    stop_events: Vec<StopEvent>,

    // Stop -> routes serving it, CSR by stop.
    stop_route_off: Vec<u32>,
    stop_routes: Vec<StopRoute>,

    // Stop -> outgoing footpaths, CSR by stop.
    footpath_off: Vec<u32>,
    footpaths: Vec<Footpath>,
}

impl Timetable {
    #[inline]
    pub fn n_stops(&self) -> usize {
        self.stops.len()
    }

    #[inline]
    pub fn n_routes(&self) -> usize {
        self.routes.len()
    }

    #[inline]
    pub fn stop(&self, s: u32) -> Stop {
        self.stops[s as usize]
    }

    /// Stop ids visited by route `r`, in pattern order.
    #[inline]
    fn route_stop_ids(&self, r: u32) -> &[u32] {
        let m = &self.routes[r as usize];
        let a = m.stop_start as usize;
        &self.route_stops[a..a + m.n_stops as usize]
    }

    /// Number of stops in route `r`'s pattern.
    #[inline]
    fn route_len(&self, r: u32) -> u32 {
        self.routes[r as usize].n_stops
    }

    /// Number of trips on route `r`.
    #[inline]
    fn route_n_trips(&self, r: u32) -> u32 {
        self.routes[r as usize].n_trips
    }

    /// Vehicle mode of route `r`.
    #[inline]
    fn route_mode(&self, r: u32) -> Mode {
        self.routes[r as usize].mode
    }

    /// The stop-event for route `r`, trip `t`, stop position `pos` (trip-major).
    #[inline]
    fn event(&self, r: u32, t: u32, pos: u32) -> StopEvent {
        let m = &self.routes[r as usize];
        let idx = m.event_start as usize + (t as usize) * (m.n_stops as usize) + pos as usize;
        self.stop_events[idx]
    }

    /// The (route, position) memberships of stop `s`.
    #[inline]
    fn routes_at(&self, s: u32) -> &[StopRoute] {
        let a = self.stop_route_off[s as usize] as usize;
        let b = self.stop_route_off[s as usize + 1] as usize;
        &self.stop_routes[a..b]
    }

    /// The outgoing footpaths of stop `s`.
    #[inline]
    fn footpaths_at(&self, s: u32) -> &[Footpath] {
        let a = self.footpath_off[s as usize] as usize;
        let b = self.footpath_off[s as usize + 1] as usize;
        &self.footpaths[a..b]
    }

    /// Earliest trip of route `r` boardable at position `pos` no sooner than
    /// `after`: the first trip whose departure at `pos` is `>= after`, or `None`
    /// if the last trip has already left. Trips are sorted non-overtaking, so
    /// `dep(r, ·, pos)` is non-decreasing in the trip index — BINARY SEARCH for
    /// the first qualifying trip, O(log T_r) instead of O(T_r) per stop scan
    /// (RAPTOR calls this at every stop of every scanned route, per round).
    #[inline]
    fn earliest_trip(&self, r: u32, pos: u32, after: Time) -> Option<u32> {
        let n_trips = self.route_n_trips(r);
        let (mut lo, mut hi) = (0u32, n_trips);
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            if self.event(r, mid, pos).dep >= after {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        if lo < n_trips {
            Some(lo)
        } else {
            None
        }
    }
}

/// A trip is its per-stop `(arr, dep)` events, one per stop in the route pattern.
pub type TripEvents = Vec<StopEvent>;

/// Ergonomic construction of a [`Timetable`] for tests and (later) as the shape the
/// offline `.ftt` builder emits. Add stops, then routes (each already one clean,
/// non-overtaking stop pattern), then footpaths; `build` computes the CSR arrays.
#[derive(Default)]
pub struct TimetableBuilder {
    stops: Vec<Stop>,
    routes: Vec<PendingRoute>,
    footpaths: Vec<Vec<Footpath>>,
}

struct PendingRoute {
    stops: Vec<u32>,
    trips: Vec<TripEvents>,
    mode: Mode,
}

impl TimetableBuilder {
    pub fn new() -> Self {
        Self::default()
    }

    /// Add a stop, returning its dense id.
    pub fn add_stop(&mut self, lat_e6: i32, lon_e6: i32) -> u32 {
        let id = self.stops.len() as u32;
        self.stops.push(Stop { lat_e6, lon_e6 });
        self.footpaths.push(Vec::new());
        id
    }

    /// Add one RAPTOR route: a stop pattern plus its trips. Each trip must supply
    /// exactly one `(arr, dep)` per stop in `stops`. Trips are sorted here by
    /// departure at the first stop; callers must supply non-overtaking trips (the
    /// offline builder guarantees this by splitting overtaking trips into separate
    /// routes). Returns the route id.
    pub fn add_route(&mut self, stops: &[u32], trips: Vec<TripEvents>, mode: Mode) -> u32 {
        assert!(stops.len() >= 2, "a route needs at least two stops");
        for t in &trips {
            assert_eq!(t.len(), stops.len(), "each trip needs one event per stop");
        }
        let mut trips = trips;
        trips.sort_by_key(|t| t[0].dep);
        let id = self.routes.len() as u32;
        self.routes.push(PendingRoute {
            stops: stops.to_vec(),
            trips,
            mode,
        });
        id
    }

    /// Add a directed walking transfer `from -> to` taking `secs`. Add both
    /// directions if the walk is symmetric.
    pub fn add_footpath(&mut self, from: u32, to: u32, secs: Time) {
        assert!(from != to, "footpaths are between distinct stops");
        self.footpaths[from as usize].push(Footpath { to, secs });
    }

    /// Freeze into the immutable CSR [`Timetable`].
    pub fn build(self) -> Timetable {
        let n_stops = self.stops.len();

        // Flatten routes into the shared CSR arrays and, in the same pass, record
        // every (route, pos) membership so we can invert it to stop -> routes.
        let mut routes = Vec::with_capacity(self.routes.len());
        let mut route_stops = Vec::new();
        let mut stop_events = Vec::new();
        let mut memberships: Vec<Vec<StopRoute>> = vec![Vec::new(); n_stops];

        for (r, pr) in self.routes.iter().enumerate() {
            let stop_start = route_stops.len() as u32;
            let event_start = stop_events.len() as u32;
            let n_pattern = pr.stops.len() as u32;

            for (pos, &s) in pr.stops.iter().enumerate() {
                route_stops.push(s);
                memberships[s as usize].push(StopRoute {
                    route: r as u32,
                    pos: pos as u32,
                });
            }
            // Trip-major: all of trip 0's events, then trip 1's, ...
            for trip in &pr.trips {
                stop_events.extend_from_slice(trip);
            }
            routes.push(RouteMeta {
                stop_start,
                n_stops: n_pattern,
                event_start,
                n_trips: pr.trips.len() as u32,
                mode: pr.mode,
            });
        }

        // Invert memberships into CSR (stop_route_off has n_stops + 1 entries).
        let mut stop_route_off = Vec::with_capacity(n_stops + 1);
        let mut stop_routes = Vec::new();
        stop_route_off.push(0u32);
        for m in &memberships {
            stop_routes.extend_from_slice(m);
            stop_route_off.push(stop_routes.len() as u32);
        }

        // Footpaths into CSR (footpath_off has n_stops + 1 entries).
        let mut footpath_off = Vec::with_capacity(n_stops + 1);
        let mut footpaths = Vec::new();
        footpath_off.push(0u32);
        for fps in &self.footpaths {
            footpaths.extend_from_slice(fps);
            footpath_off.push(footpaths.len() as u32);
        }

        Timetable {
            stops: self.stops,
            routes,
            route_stops,
            stop_events,
            stop_route_off,
            stop_routes,
            footpath_off,
            footpaths,
        }
    }
}
