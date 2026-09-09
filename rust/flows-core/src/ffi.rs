// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! C-ABI FFI surface — how the Swift app calls into the Rust core.
//!
//! Raw C ABI by design (smallest surface, no codegen dependency). Swift binds
//! symbols via dlsym in dev (libflows_core.dylib) and static-links the .a for
//! device builds:
//!
//!   // Swift
//!   let n = flows_polyline_decode(bytes, len, out, capPairs)
//!
//! The surface is deliberately the smallest thing Swift actually calls
//! (3.6, 3.25.5). Five exports — `flows_risk_label`, `flows_distance_matrix`,
//! `flows_dijkstra_c`, `flows_ch_query_c`, `flows_ch_path_c` — were removed
//! after a search of the whole Swift app found zero references to any of
//! them: four were `unsafe extern "C"` and the fifth handed a raw pointer
//! across the boundary, all of it dead weight against 3.15 and 5.3. What
//! remains is `flows_polyline_decode`, `flows_transit_plan` and
//! `flows_transit_selftest`.
//!
//! REMAINING STANDARD GAP (3.15/3.25.5): the two bulk-array exports below
//! still take raw pointers and are therefore `unsafe`. The standard's
//! remedy for buffer-passing bridges is a safe binding generator or a
//! serialization boundary, which is an architectural change to the Swift
//! interface — see docs/RUST_SWIFT_MIGRATION.md. `flows_transit_selftest`
//! is already a value-oriented export and needs no unsafe.

/// Decode a Google encoded polyline into interleaved lon,lat doubles.
/// `bytes`/`len` is the encoded string (need not be NUL-terminated); `out`
/// receives up to `cap_pairs` pairs (2 doubles each, lon first — matching the
/// R decoder's column order). Returns the TOTAL number of pairs in the input,
/// which may exceed `cap_pairs`; call with `out == NULL` / `cap_pairs == 0`
/// to size the buffer first (a `len / 2 + 1` pair buffer is always enough).
/// Returns -1 on a NULL `bytes` with nonzero `len`. Swift owns the buffer —
/// same allocation-across-FFI-free pattern as `flows_distance_matrix`.
///
/// # Safety
/// `bytes` must be valid for `len` reads and `out` for `2 * cap_pairs` f64
/// writes (or NULL with `cap_pairs == 0`). Standard C-ABI contract.
#[no_mangle]
pub unsafe extern "C" fn flows_polyline_decode(
    bytes: *const u8,
    len: usize,
    out: *mut f64,
    cap_pairs: usize,
) -> i64 {
    if bytes.is_null() && len != 0 {
        return -1;
    }
    // Same catch_unwind discipline as every other computing entry point: a
    // panic must never unwind across extern "C" (that aborts the host
    // process) — the caller sees -1 instead.
    let computed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let encoded = if len == 0 {
            &[][..]
        } else {
            std::slice::from_raw_parts(bytes, len)
        };
        let mut deltas: Vec<i64> = Vec::new();
        crate::polyline::decode_deltas(encoded, &mut deltas);
        let n_pairs = deltas.len() / 2;
        if !out.is_null() && cap_pairs > 0 {
            let os = std::slice::from_raw_parts_mut(out, 2 * cap_pairs.min(n_pairs));
            let mut lat: i64 = 0;
            let mut lon: i64 = 0;
            for (i, pair) in deltas.chunks_exact(2).take(cap_pairs).enumerate() {
                // Wrapping adds: every VALID polyline keeps the cumulative
                // sums within ±2*180e5, where wrapping_add is bit-identical
                // to +. Only a hostile stream of near-2^49 deltas can wrap,
                // and it must not trap an overflow-checked build mid-decode.
                lat = lat.wrapping_add(pair[0]);
                lon = lon.wrapping_add(pair[1]);
                os[2 * i] = lon as f64 / 1e5;
                os[2 * i + 1] = lat as f64 / 1e5;
            }
        }
        n_pairs as i64
    }));
    computed.unwrap_or(-1)
}

// -----------------------------------------------------------------------------
// Transit routing (RAPTOR) — C-ABI surface so the Swift app runs the on-device
// engine. Same conventions as the shims above: Swift owns all output buffers,
// nothing is allocated across the boundary, every entry point is catch_unwind-
// wrapped (a panic must never cross extern "C"), and two-pass sizing lets the
// caller size the journey/leg buffers before filling them.
// -----------------------------------------------------------------------------

/// One reconstructed leg, flat for the C ABI. `kind`: 0 = ride, 1 = walk.
/// `route`/`trip` are `u32::MAX` on a walk. `mode` is `transit::Mode as u8`.
#[repr(C)]
pub struct FfiLeg {
    pub kind: u8,
    pub mode: u8,
    pub _pad: u16,
    pub from_stop: u32,
    pub to_stop: u32,
    pub dep: u32,
    pub arr: u32,
    pub route: u32,
    pub trip: u32,
}

/// One Pareto journey, flat. Its legs occupy `out_legs[first_leg .. first_leg + n_legs]`.
#[repr(C)]
pub struct FfiJourney {
    pub first_leg: u32,
    pub n_legs: u32,
    pub arrival: u32,
    pub n_transfers: u32,
    pub walk_secs: u32,
}

/// Rebuild an in-memory [`crate::transit::Timetable`] from the caller's flat CSR
/// arrays. Every offset/id is bounds-checked; any inconsistency returns `None`
/// (the caller then gets a -1 status) rather than risking UB or a panic.
///
/// # Safety
/// All non-null pointers must be valid for the lengths implied by the counts and
/// the offset arrays (`route_pat_off`/`route_ev_off` have `n_routes + 1` entries).
#[allow(clippy::too_many_arguments)]
unsafe fn build_timetable_ffi(
    n_stops: u32,
    stop_lat_e6: *const i32,
    stop_lon_e6: *const i32,
    n_routes: u32,
    route_pat_off: *const u32,
    route_pat_stops: *const u32,
    route_ntrips: *const u32,
    route_ev_off: *const u32,
    ev_arr: *const u32,
    ev_dep: *const u32,
    route_mode: *const u8,
    n_fp: u32,
    fp_from: *const u32,
    fp_to: *const u32,
    fp_secs: *const u32,
) -> Option<crate::transit::Timetable> {
    use crate::transit::{Mode, StopEvent, TimetableBuilder};
    let ns = n_stops as usize;
    if ns == 0 || stop_lat_e6.is_null() || stop_lon_e6.is_null() {
        return None;
    }
    let lat = std::slice::from_raw_parts(stop_lat_e6, ns);
    let lon = std::slice::from_raw_parts(stop_lon_e6, ns);
    let mut b = TimetableBuilder::new();
    for i in 0..ns {
        b.add_stop(lat[i], lon[i]);
    }

    let nr = n_routes as usize;
    if nr > 0 {
        if route_pat_off.is_null()
            || route_pat_stops.is_null()
            || route_ntrips.is_null()
            || route_ev_off.is_null()
            || ev_arr.is_null()
            || ev_dep.is_null()
            || route_mode.is_null()
        {
            return None;
        }
        let pat_off = std::slice::from_raw_parts(route_pat_off, nr + 1);
        let ev_off = std::slice::from_raw_parts(route_ev_off, nr + 1);
        let ntrips = std::slice::from_raw_parts(route_ntrips, nr);
        let modes = std::slice::from_raw_parts(route_mode, nr);
        // Offsets must be monotonic and start at 0 (CSR invariant).
        if pat_off[0] != 0
            || ev_off[0] != 0
            || pat_off.windows(2).any(|w| w[1] < w[0])
            || ev_off.windows(2).any(|w| w[1] < w[0])
        {
            return None;
        }
        let pat_total = pat_off[nr] as usize;
        let ev_total = ev_off[nr] as usize;
        let pat_stops = std::slice::from_raw_parts(route_pat_stops, pat_total);
        let arr = std::slice::from_raw_parts(ev_arr, ev_total);
        let dep = std::slice::from_raw_parts(ev_dep, ev_total);
        for r in 0..nr {
            let (ps, pe) = (pat_off[r] as usize, pat_off[r + 1] as usize);
            let n_pat = pe.checked_sub(ps)?;
            if n_pat < 2 {
                return None;
            }
            let pattern = pat_stops[ps..pe].to_vec();
            if pattern.iter().any(|&s| s as usize >= ns) {
                return None;
            }
            let nt = ntrips[r] as usize;
            let (es, ee) = (ev_off[r] as usize, ev_off[r + 1] as usize);
            if ee.checked_sub(es)? != nt * n_pat {
                return None;
            }
            let mut trips: Vec<Vec<StopEvent>> = Vec::with_capacity(nt);
            for t in 0..nt {
                let base = es + t * n_pat;
                trips.push(
                    (0..n_pat)
                        .map(|j| StopEvent {
                            arr: arr[base + j],
                            dep: dep[base + j],
                        })
                        .collect(),
                );
            }
            // An unrecognized byte is a caller error, not a Commuter train.
            // This catch-all used to admit every value 4..=255 into domain
            // state as a specific, valid mode, so a one-byte offset mistake
            // on the Swift side produced a plausible timetable in which every
            // leg was mislabelled — and both the sizing pass and the fill
            // pass returned success. The .ftt decoder already refuses the
            // same byte (transit/ftt.rs); the boundary now agrees with it.
            let mode = match modes[r] {
                0 => Mode::Rail,
                1 => Mode::Subway,
                2 => Mode::Bus,
                3 => Mode::Coach,
                4 => Mode::Commuter,
                _ => return None,
            };
            b.add_route(&pattern, trips, mode);
        }
    }

    let nf = n_fp as usize;
    if nf > 0 {
        if fp_from.is_null() || fp_to.is_null() || fp_secs.is_null() {
            return None;
        }
        let ff = std::slice::from_raw_parts(fp_from, nf);
        let ft = std::slice::from_raw_parts(fp_to, nf);
        let fs = std::slice::from_raw_parts(fp_secs, nf);
        for i in 0..nf {
            if (ff[i] as usize) < ns && (ft[i] as usize) < ns && ff[i] != ft[i] {
                b.add_footpath(ff[i], ft[i], fs[i]);
            }
        }
    }
    Some(b.build())
}

/// Ceiling on `max_rounds` accepted across the FFI. RAPTOR allocates
/// `(max_rounds + 1) * n_stops` labels per state array, so a runaway value
/// dies in the allocator — an abort `catch_unwind` cannot intercept. Real
/// journeys need single-digit rounds; 32 is far beyond any Pareto frontier.
const FFI_MAX_ROUNDS: u32 = 32;

/// Plan Pareto-optimal transit journeys over a flat-array timetable. Two-pass:
/// call with `out_journeys`/`out_legs` NULL to get the required sizes in
/// `out_counts` (`[n_journeys, n_legs]`), then again with buffers of at least
/// that size to fill them. Returns 0 on success, -1 on null/invalid input
/// (out-of-range `source`/`target`, `max_rounds` above [`FFI_MAX_ROUNDS`], or
/// fill-pass buffers smaller than the pass-1 counts).
///
/// # Safety
/// Pointers must satisfy the lengths in [`build_timetable_ffi`]; `out_counts` must
/// hold 2 `u32`s; `out_journeys`/`out_legs` (when non-null) their `cap` elements.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn flows_transit_plan(
    n_stops: u32,
    stop_lat_e6: *const i32,
    stop_lon_e6: *const i32,
    n_routes: u32,
    route_pat_off: *const u32,
    route_pat_stops: *const u32,
    route_ntrips: *const u32,
    route_ev_off: *const u32,
    ev_arr: *const u32,
    ev_dep: *const u32,
    route_mode: *const u8,
    n_fp: u32,
    fp_from: *const u32,
    fp_to: *const u32,
    fp_secs: *const u32,
    source: u32,
    target: u32,
    depart: u32,
    max_rounds: u32,
    out_journeys: *mut FfiJourney,
    cap_journeys: u32,
    out_legs: *mut FfiLeg,
    cap_legs: u32,
    out_counts: *mut u32,
) -> i32 {
    use crate::transit::LegKind;
    if out_counts.is_null() {
        return -1;
    }
    if max_rounds > FFI_MAX_ROUNDS || source >= n_stops || target >= n_stops {
        return -1;
    }
    let computed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let tt = match build_timetable_ffi(
            n_stops,
            stop_lat_e6,
            stop_lon_e6,
            n_routes,
            route_pat_off,
            route_pat_stops,
            route_ntrips,
            route_ev_off,
            ev_arr,
            ev_dep,
            route_mode,
            n_fp,
            fp_from,
            fp_to,
            fp_secs,
        ) {
            Some(t) => t,
            None => return -1,
        };
        let journeys = crate::transit::plan(&tt, source, target, depart, max_rounds);
        let n_l: usize = journeys.iter().map(|j| j.legs.len()).sum();
        let counts = std::slice::from_raw_parts_mut(out_counts, 2);
        counts[0] = journeys.len() as u32;
        counts[1] = n_l as u32;
        // Sizing pass: report counts only.
        if out_journeys.is_null() || out_legs.is_null() {
            return 0;
        }
        // Fill pass: undersized buffers are a contract violation. Succeeding
        // anyway would emit journey records whose leg ranges point past
        // cap_legs — out-of-bounds indices under a success status. The
        // required counts are already in out_counts for the caller to resize.
        if (cap_journeys as usize) < journeys.len() || (cap_legs as usize) < n_l {
            return -1;
        }
        let jbuf = std::slice::from_raw_parts_mut(out_journeys, cap_journeys as usize);
        let lbuf = std::slice::from_raw_parts_mut(out_legs, cap_legs as usize);
        let mut leg_idx = 0usize;
        for (ji, j) in journeys.iter().enumerate() {
            if ji >= jbuf.len() {
                break;
            }
            let first = leg_idx as u32;
            for leg in &j.legs {
                if leg_idx >= lbuf.len() {
                    break;
                }
                lbuf[leg_idx] = FfiLeg {
                    kind: if leg.kind == LegKind::Ride { 0 } else { 1 },
                    mode: leg.mode as u8,
                    _pad: 0,
                    from_stop: leg.from_stop,
                    to_stop: leg.to_stop,
                    dep: leg.dep,
                    arr: leg.arr,
                    route: leg.route,
                    trip: leg.trip,
                };
                leg_idx += 1;
            }
            jbuf[ji] = FfiJourney {
                first_leg: first,
                n_legs: j.legs.len() as u32,
                arrival: j.arrival,
                n_transfers: j.n_transfers,
                walk_secs: j.walk_secs,
            };
        }
        0
    }));
    computed.unwrap_or(-1)
}

/// Self-test: build a canonical two-leg transfer timetable INTERNALLY, run
/// RAPTOR, and return the plan's arrival time (1500) — or -1 on any failure.
/// A dead-simple way for the app to prove, in one C-ABI call, that the
/// compiled-and-linked RAPTOR engine actually runs on-device (the transit analog of the
/// polyline decoder's linkage check).
#[no_mangle]
pub extern "C" fn flows_transit_selftest() -> i64 {
    let computed = std::panic::catch_unwind(|| {
        use crate::transit::{plan, Mode, StopEvent, TimetableBuilder};
        let mut b = TimetableBuilder::new();
        let a = b.add_stop(0, 0);
        let bb = b.add_stop(0, 1_000_000);
        let c = b.add_stop(0, 2_000_000);
        b.add_route(
            &[a, bb],
            vec![vec![
                StopEvent { arr: 0, dep: 0 },
                StopEvent { arr: 600, dep: 600 },
            ]],
            Mode::Rail,
        );
        b.add_route(
            &[bb, c],
            vec![vec![
                StopEvent { arr: 900, dep: 900 },
                StopEvent {
                    arr: 1500,
                    dep: 1500,
                },
            ]],
            Mode::Rail,
        );
        let tt = b.build();
        let js = plan(&tt, a, c, 0, 8);
        if js.len() == 1 && js[0].n_transfers == 1 && js[0].legs.len() == 2 && js[0].arrival == 1500
        {
            js[0].arrival as i64
        } else {
            -1
        }
    });
    computed.unwrap_or(-1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_polyline_decode_two_pass() {
        let enc = "_p~iF~ps|U_ulLnnqC_mqNvxq`@";
        // pass 1: size query
        let n = unsafe { flows_polyline_decode(enc.as_ptr(), enc.len(), std::ptr::null_mut(), 0) };
        assert_eq!(n, 3);
        // pass 2: fill
        let mut buf = vec![0.0f64; 2 * n as usize];
        let n2 =
            unsafe { flows_polyline_decode(enc.as_ptr(), enc.len(), buf.as_mut_ptr(), n as usize) };
        assert_eq!(n2, 3);
        assert_eq!(buf[0].to_bits(), (-120.2f64).to_bits()); // lon first
        assert_eq!(buf[1].to_bits(), 38.5f64.to_bits());
        // capped fill only writes cap pairs but still reports the total
        let mut small = vec![0.0f64; 2];
        let n3 = unsafe { flows_polyline_decode(enc.as_ptr(), enc.len(), small.as_mut_ptr(), 1) };
        assert_eq!(n3, 3);
        assert_eq!(small[1].to_bits(), 38.5f64.to_bits());
        // degenerate inputs
        assert_eq!(
            unsafe { flows_polyline_decode(std::ptr::null(), 5, std::ptr::null_mut(), 0) },
            -1
        );
        assert_eq!(
            unsafe { flows_polyline_decode(std::ptr::null(), 0, std::ptr::null_mut(), 0) },
            0
        );
    }

    #[test]
    fn ffi_transit_selftest_runs_raptor() {
        // The C-ABI entry runs the whole RAPTOR engine and returns the canonical
        // transfer plan's arrival time — the on-device linkage proof.
        assert_eq!(flows_transit_selftest(), 1500);
    }

    #[test]
    fn ffi_transit_plan_two_pass_marshals_a_transfer() {
        // Timetable: stops A(0) B(1) C(2); route0 A->B, route1 B->C. Plan A->C.
        let lat = [0i32, 0, 0];
        let lon = [0i32, 1_000_000, 2_000_000];
        let pat_off = [0u32, 2, 4]; // route0 stops [0,1], route1 stops [1,2]
        let pat_stops = [0u32, 1, 1, 2];
        let ntrips = [1u32, 1];
        let ev_off = [0u32, 2, 4]; // 1 trip * 2 stops each
        let ev_arr = [0u32, 600, 900, 1500];
        let ev_dep = [0u32, 600, 900, 1500];
        let modes = [0u8, 0];
        // Pass 1: size.
        let mut counts = [0u32; 2];
        let rc = unsafe {
            flows_transit_plan(
                3,
                lat.as_ptr(),
                lon.as_ptr(),
                2,
                pat_off.as_ptr(),
                pat_stops.as_ptr(),
                ntrips.as_ptr(),
                ev_off.as_ptr(),
                ev_arr.as_ptr(),
                ev_dep.as_ptr(),
                modes.as_ptr(),
                0,
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                0,
                2,
                0,
                8,
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                0,
                counts.as_mut_ptr(),
            )
        };
        assert_eq!(rc, 0);
        assert_eq!(counts[0], 1, "one Pareto journey");
        assert_eq!(counts[1], 2, "two ride legs");
        // Pass 2: fill.
        let mut journeys: Vec<FfiJourney> = (0..counts[0])
            .map(|_| FfiJourney {
                first_leg: 0,
                n_legs: 0,
                arrival: 0,
                n_transfers: 0,
                walk_secs: 0,
            })
            .collect();
        let mut legs: Vec<FfiLeg> = (0..counts[1])
            .map(|_| FfiLeg {
                kind: 0,
                mode: 0,
                _pad: 0,
                from_stop: 0,
                to_stop: 0,
                dep: 0,
                arr: 0,
                route: u32::MAX,
                trip: u32::MAX,
            })
            .collect();
        let rc2 = unsafe {
            flows_transit_plan(
                3,
                lat.as_ptr(),
                lon.as_ptr(),
                2,
                pat_off.as_ptr(),
                pat_stops.as_ptr(),
                ntrips.as_ptr(),
                ev_off.as_ptr(),
                ev_arr.as_ptr(),
                ev_dep.as_ptr(),
                modes.as_ptr(),
                0,
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                0,
                2,
                0,
                8,
                journeys.as_mut_ptr(),
                counts[0],
                legs.as_mut_ptr(),
                counts[1],
                counts.as_mut_ptr(),
            )
        };
        assert_eq!(rc2, 0);
        assert_eq!(journeys[0].arrival, 1500);
        assert_eq!(journeys[0].n_transfers, 1);
        assert_eq!(journeys[0].n_legs, 2);
        assert_eq!(legs[0].kind, 0); // ride A->B
        assert_eq!(legs[0].from_stop, 0);
        assert_eq!(legs[1].to_stop, 2); // ride B->C
    }

    #[test]
    fn ffi_transit_plan_bounds_rounds_ids_and_fill_buffers() {
        // Same timetable as the two-pass test: route0 A->B, route1 B->C.
        let lat = [0i32, 0, 0];
        let lon = [0i32, 1_000_000, 2_000_000];
        let pat_off = [0u32, 2, 4];
        let pat_stops = [0u32, 1, 1, 2];
        let ntrips = [1u32, 1];
        let ev_off = [0u32, 2, 4];
        let ev_arr = [0u32, 600, 900, 1500];
        let ev_dep = [0u32, 600, 900, 1500];
        let modes = [0u8, 0];
        let mut counts = [0u32; 2];
        let sizing = |source: u32, target: u32, rounds: u32, counts: &mut [u32; 2]| unsafe {
            flows_transit_plan(
                3,
                lat.as_ptr(),
                lon.as_ptr(),
                2,
                pat_off.as_ptr(),
                pat_stops.as_ptr(),
                ntrips.as_ptr(),
                ev_off.as_ptr(),
                ev_arr.as_ptr(),
                ev_dep.as_ptr(),
                modes.as_ptr(),
                0,
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                source,
                target,
                0,
                rounds,
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                0,
                counts.as_mut_ptr(),
            )
        };
        // A runaway max_rounds must hit the -1 contract, never the allocator.
        assert_eq!(sizing(0, 2, 100_000, &mut counts), -1);
        // Out-of-range stop ids: -1, matching the rest of the validation.
        assert_eq!(sizing(99, 2, 8, &mut counts), -1);
        assert_eq!(sizing(0, 99, 8, &mut counts), -1);
        // Valid sizing pass, then a fill pass with an undersized legs buffer:
        // -1 rather than journey ranges pointing past cap_legs.
        assert_eq!(sizing(0, 2, 8, &mut counts), 0);
        assert_eq!((counts[0], counts[1]), (1, 2));
        let mut journeys: Vec<FfiJourney> = (0..counts[0])
            .map(|_| FfiJourney {
                first_leg: 0,
                n_legs: 0,
                arrival: 0,
                n_transfers: 0,
                walk_secs: 0,
            })
            .collect();
        let mut legs = [FfiLeg {
            kind: 0,
            mode: 0,
            _pad: 0,
            from_stop: 0,
            to_stop: 0,
            dep: 0,
            arr: 0,
            route: u32::MAX,
            trip: u32::MAX,
        }];
        let rc = unsafe {
            flows_transit_plan(
                3,
                lat.as_ptr(),
                lon.as_ptr(),
                2,
                pat_off.as_ptr(),
                pat_stops.as_ptr(),
                ntrips.as_ptr(),
                ev_off.as_ptr(),
                ev_arr.as_ptr(),
                ev_dep.as_ptr(),
                modes.as_ptr(),
                0,
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                0,
                2,
                0,
                8,
                journeys.as_mut_ptr(),
                counts[0],
                legs.as_mut_ptr(),
                1,
                counts.as_mut_ptr(),
            )
        };
        assert_eq!(rc, -1, "undersized legs buffer must not report success");
    }

    #[test]
    fn ffi_transit_plan_rejects_bad_input_without_panic() {
        let mut counts = [0u32; 2];
        // Null stops with a nonzero count → -1, never UB/panic across the ABI.
        let rc = unsafe {
            flows_transit_plan(
                3,
                std::ptr::null(),
                std::ptr::null(),
                0,
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                0,
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                0,
                1,
                0,
                8,
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                0,
                counts.as_mut_ptr(),
            )
        };
        assert_eq!(rc, -1);
    }
}
