// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! `.ftt` v1 — the FLOWS Transit Timetable binary format (see
//! `docs/TRANSIT_ROUTING.md`). One little-endian file per shard holding a
//! versioned header plus **exactly the flat CSR arrays [`Timetable`] holds**,
//! in declaration order, so reading is a straight section-by-section decode
//! into the same structs RAPTOR already runs over — the engine does not change
//! when a timetable arrives from disk instead of [`super::TimetableBuilder`].
//!
//! Layout (all integers little-endian):
//!
//! ```text
//! HEADER (64 bytes)
//!   0..4    magic  "FTT1"
//!   4..8    format version   u32  (= 1)
//!   8..12   n_stops          u32
//!   12..16  n_routes         u32
//!   16..20  n_route_stops    u32
//!   20..24  n_stop_events    u32
//!   24..28  n_stop_routes    u32
//!   28..32  n_footpaths      u32
//!   32..40  body length      u64
//!   40..48  fnv1a-64 body hash u64  (validated on read — a corrupt shard is
//!                                    refused, never trusted)
//!   48..64  reserved (zero)
//! BODY (sections back-to-back, each 4-byte-aligned by construction)
//!   STOPS          n_stops        x (lat_e6 i32, lon_e6 i32)
//!   ROUTES         n_routes       x (stop_start u32, n_stops u32,
//!                                    event_start u32, n_trips u32, mode u32)
//!   ROUTE_STOPS    n_route_stops  x u32
//!   STOPEVENTS     n_stop_events  x (arr u32, dep u32)
//!   STOP_ROUTE_OFF (n_stops + 1)  x u32
//!   STOP_ROUTES    n_stop_routes  x (route u32, pos u32)
//!   FOOTPATH_OFF   (n_stops + 1)  x u32
//!   FOOTPATHS      n_footpaths    x (to u32, secs u32)
//! ```
//!
//! v1 is a sequential read into owned `Vec`s (small shards, instant loads);
//! because every section is fixed-width, little-endian and 4-byte aligned, the
//! same layout upgrades to the planned mmap-in-place zero-copy reader without
//! a format change. Pure std, no external crates.

use std::fs;
use std::io::{self, Write};
use std::path::Path;

use super::{Footpath, Mode, RouteMeta, Stop, StopEvent, StopRoute, Timetable};

/// File magic: the first four bytes of every `.ftt`.
pub const FTT_MAGIC: [u8; 4] = *b"FTT1";
/// Format version this module writes and the only one it accepts.
pub const FTT_VERSION: u32 = 1;
/// Fixed header size in bytes.
pub const FTT_HEADER_LEN: usize = 64;

/// FNV-1a 64-bit — the body integrity hash (matches the design doc; tiny,
/// deterministic, dependency-free).
fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

#[inline]
fn put_u32(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_le_bytes());
}

#[inline]
fn put_i32(out: &mut Vec<u8>, v: i32) {
    out.extend_from_slice(&v.to_le_bytes());
}

/// Encode a [`Timetable`] into `.ftt` v1 bytes (header + body). Deterministic:
/// the same timetable always yields the same bytes.
pub fn to_bytes(tt: &Timetable) -> Vec<u8> {
    // --- Body: the CSR arrays, in Timetable declaration order. ---
    let mut body = Vec::new();
    for s in &tt.stops {
        put_i32(&mut body, s.lat_e6);
        put_i32(&mut body, s.lon_e6);
    }
    for r in &tt.routes {
        put_u32(&mut body, r.stop_start);
        put_u32(&mut body, r.n_stops);
        put_u32(&mut body, r.event_start);
        put_u32(&mut body, r.n_trips);
        put_u32(&mut body, r.mode as u32);
    }
    for &s in &tt.route_stops {
        put_u32(&mut body, s);
    }
    for e in &tt.stop_events {
        put_u32(&mut body, e.arr);
        put_u32(&mut body, e.dep);
    }
    for &o in &tt.stop_route_off {
        put_u32(&mut body, o);
    }
    for sr in &tt.stop_routes {
        put_u32(&mut body, sr.route);
        put_u32(&mut body, sr.pos);
    }
    for &o in &tt.footpath_off {
        put_u32(&mut body, o);
    }
    for f in &tt.footpaths {
        put_u32(&mut body, f.to);
        put_u32(&mut body, f.secs);
    }

    // --- Header. ---
    let mut out = Vec::with_capacity(FTT_HEADER_LEN + body.len());
    out.extend_from_slice(&FTT_MAGIC);
    put_u32(&mut out, FTT_VERSION);
    put_u32(&mut out, tt.stops.len() as u32);
    put_u32(&mut out, tt.routes.len() as u32);
    put_u32(&mut out, tt.route_stops.len() as u32);
    put_u32(&mut out, tt.stop_events.len() as u32);
    put_u32(&mut out, tt.stop_routes.len() as u32);
    put_u32(&mut out, tt.footpaths.len() as u32);
    out.extend_from_slice(&(body.len() as u64).to_le_bytes());
    out.extend_from_slice(&fnv1a64(&body).to_le_bytes());
    out.extend_from_slice(&[0u8; FTT_HEADER_LEN - 48]); // reserved
    debug_assert_eq!(out.len(), FTT_HEADER_LEN);
    out.extend_from_slice(&body);
    out
}

/// Write `tt` to `path` as `.ftt` v1.
pub fn write_ftt(tt: &Timetable, path: &Path) -> io::Result<()> {
    let bytes = to_bytes(tt);
    let mut f = fs::File::create(path)?;
    f.write_all(&bytes)?;
    f.flush()
}

/// The body hash recorded in a `.ftt`'s header — the shard's identity. The
/// `.fts` sidecar stores this so a set of labels can only ever be applied to
/// the timetable it was built from (see [`super::fts`]). Returns `None` for
/// bytes that are not a readable `.ftt` header.
pub fn body_hash(bytes: &[u8]) -> Option<u64> {
    if bytes.len() < FTT_HEADER_LEN || bytes[0..4] != FTT_MAGIC {
        return None;
    }
    let mut v = [0u8; 8];
    v.copy_from_slice(&bytes[40..48]);
    Some(u64::from_le_bytes(v))
}

fn bad(msg: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg.into())
}

/// Sequential little-endian cursor over the body with hard bounds errors —
/// a malformed file must produce `Err`, never a panic or UB.
struct Cur<'a> {
    b: &'a [u8],
    pos: usize,
}

impl<'a> Cur<'a> {
    fn u32(&mut self) -> io::Result<u32> {
        let end = self.pos + 4;
        if end > self.b.len() {
            return Err(bad("ftt: truncated body"));
        }
        let v = u32::from_le_bytes(self.b[self.pos..end].try_into().unwrap());
        self.pos = end;
        Ok(v)
    }

    fn i32(&mut self) -> io::Result<i32> {
        Ok(self.u32()? as i32)
    }
}

/// Validate a CSR offset array: starts at 0, non-decreasing, ends at `total`.
fn check_offsets(off: &[u32], total: u32, what: &str) -> io::Result<()> {
    if off.first() != Some(&0) {
        return Err(bad(format!("ftt: {what} offsets must start at 0")));
    }
    if off.windows(2).any(|w| w[1] < w[0]) {
        return Err(bad(format!("ftt: {what} offsets must be non-decreasing")));
    }
    if off.last() != Some(&total) {
        return Err(bad(format!(
            "ftt: {what} offsets must end at the section count"
        )));
    }
    Ok(())
}

/// Decode `.ftt` v1 bytes into a [`Timetable`]. Refuses wrong magic/version,
/// truncation, hash mismatch, and any internally inconsistent counts/ids —
/// a corrupt shard must never reach RAPTOR, in whole or in part.
///
/// Every check is one pass over a section, so the work is linear in the
/// file's size whatever the file says about itself:
///
/// * the routes TILE `ROUTE_STOPS` and `STOPEVENTS` — each route's slice
///   starts where the one before ended and the last ends at the section's
///   end, as the writer lays them down. Slices that merely fit could overlap,
///   and a few thousand routes all naming the whole event table made the
///   sweep below thousands of passes over it;
/// * within a trip times never go backwards, and across a route's trips no
///   trip overtakes another;
/// * `STOP_ROUTES` is exactly the inverse of the route patterns: every entry
///   filed under a stop names a (route, position) that IS that stop, and
///   every (route, position) is filed once.
pub fn from_bytes(bytes: &[u8]) -> io::Result<Timetable> {
    if bytes.len() < FTT_HEADER_LEN {
        return Err(bad("ftt: shorter than the fixed header"));
    }
    if bytes[0..4] != FTT_MAGIC {
        return Err(bad("ftt: bad magic (not an .ftt file)"));
    }
    let mut h = Cur { b: bytes, pos: 4 };
    let version = h.u32()?;
    if version != FTT_VERSION {
        return Err(bad(format!("ftt: unsupported version {version}")));
    }
    let n_stops = h.u32()?;
    let n_routes = h.u32()?;
    let n_route_stops = h.u32()?;
    let n_events = h.u32()?;
    let n_stop_routes = h.u32()?;
    let n_footpaths = h.u32()?;
    let body_len = u64::from_le_bytes(bytes[32..40].try_into().unwrap());
    let hash = u64::from_le_bytes(bytes[40..48].try_into().unwrap());

    let body = &bytes[FTT_HEADER_LEN..];
    if body.len() as u64 != body_len {
        return Err(bad("ftt: body length does not match header"));
    }
    // Exact size check before any decode: sections are fixed-width. Summed
    // in 64 bits, where six 32-bit counts times their widths cannot wrap; in
    // `usize` they did on a 32-bit target (the Watch), and a file could name
    // counts whose wrapped sum matched a body far too small for them.
    let expect = u64::from(n_stops) * 8
        + u64::from(n_routes) * 20
        + u64::from(n_route_stops) * 4
        + u64::from(n_events) * 8
        + (u64::from(n_stops) + 1) * 4
        + u64::from(n_stop_routes) * 8
        + (u64::from(n_stops) + 1) * 4
        + u64::from(n_footpaths) * 8;
    if body_len != expect {
        return Err(bad("ftt: body length does not match the header counts"));
    }
    if fnv1a64(body) != hash {
        return Err(bad("ftt: body hash mismatch (corrupt shard refused)"));
    }
    // Each count is now known to fit the body that is in memory, so it fits
    // `usize` and is safe to allocate for.
    let (n_stops, n_routes, n_route_stops, n_events, n_stop_routes, n_footpaths) = (
        n_stops as usize,
        n_routes as usize,
        n_route_stops as usize,
        n_events as usize,
        n_stop_routes as usize,
        n_footpaths as usize,
    );

    let mut c = Cur { b: body, pos: 0 };

    let mut stops = Vec::with_capacity(n_stops);
    for _ in 0..n_stops {
        stops.push(Stop {
            lat_e6: c.i32()?,
            lon_e6: c.i32()?,
        });
    }

    let mut routes = Vec::with_capacity(n_routes);
    // Where the next route's pattern and events must begin (see above).
    let (mut pat_at, mut ev_at) = (0u64, 0u64);
    for _ in 0..n_routes {
        let stop_start = c.u32()?;
        let n_pat = c.u32()?;
        let event_start = c.u32()?;
        let n_trips = c.u32()?;
        let mode = match c.u32()? {
            0 => Mode::Rail,
            1 => Mode::Subway,
            2 => Mode::Bus,
            3 => Mode::Coach,
            4 => Mode::Commuter,
            5 => Mode::Ship,
            m => return Err(bad(format!("ftt: unknown mode byte {m}"))),
        };
        if n_pat < 2 {
            return Err(bad("ftt: a route needs at least two stops"));
        }
        if u64::from(stop_start) != pat_at {
            return Err(bad("ftt: route patterns overlap or leave a gap"));
        }
        pat_at += u64::from(n_pat);
        if pat_at > n_route_stops as u64 {
            return Err(bad("ftt: route pattern out of ROUTE_STOPS bounds"));
        }
        if u64::from(event_start) != ev_at {
            return Err(bad("ftt: route events overlap or leave a gap"));
        }
        // Checked: two 32-bit counts multiply into 64 bits without wrapping,
        // but the running sum is the file's word too.
        ev_at = ev_at
            .checked_add(u64::from(n_trips) * u64::from(n_pat))
            .filter(|&end| end <= n_events as u64)
            .ok_or_else(|| bad("ftt: route events out of STOPEVENTS bounds"))?;
        routes.push(RouteMeta {
            stop_start,
            n_stops: n_pat,
            event_start,
            n_trips,
            mode,
        });
    }
    if pat_at != n_route_stops as u64 || ev_at != n_events as u64 {
        return Err(bad("ftt: routes do not account for every stop and event"));
    }

    let mut route_stops = Vec::with_capacity(n_route_stops);
    for _ in 0..n_route_stops {
        let s = c.u32()?;
        if s as usize >= n_stops {
            return Err(bad("ftt: route stop id out of range"));
        }
        route_stops.push(s);
    }

    let mut stop_events = Vec::with_capacity(n_events);
    for _ in 0..n_events {
        stop_events.push(StopEvent {
            arr: c.u32()?,
            dep: c.u32()?,
        });
    }

    // Non-overtaking invariant: `earliest_trip` binary-searches departures at
    // every pattern position, which requires dep (and arr) non-decreasing in
    // the trip index, and arr <= dep within each event (the converter's
    // chain-split guarantees all three). And a trip runs forwards: it reaches
    // a stop no earlier than it left the one before (the converter floors
    // every trip so). A shard violating either decodes cleanly but yields
    // silently wrong itineraries — a ride that arrives before it left —
    // so refuse it here. The routes' event slices are disjoint (checked
    // above), so this visits each event once.
    for r in &routes {
        let base = r.event_start as usize;
        let np = r.n_stops as usize;
        for t in 0..r.n_trips as usize {
            for j in 0..np {
                let e = stop_events[base + t * np + j];
                if e.arr > e.dep {
                    return Err(bad("ftt: event arrives after it departs"));
                }
                if j > 0 && e.arr < stop_events[base + t * np + j - 1].dep {
                    return Err(bad("ftt: a trip goes back in time"));
                }
                if t > 0 {
                    let p = stop_events[base + (t - 1) * np + j];
                    if e.dep < p.dep || e.arr < p.arr {
                        return Err(bad("ftt: trips overtake within a route"));
                    }
                }
            }
        }
    }

    let mut stop_route_off = Vec::with_capacity(n_stops + 1);
    for _ in 0..=n_stops {
        stop_route_off.push(c.u32()?);
    }
    check_offsets(&stop_route_off, n_stop_routes as u32, "stop->route")?;

    let mut stop_routes = Vec::with_capacity(n_stop_routes);
    for _ in 0..n_stop_routes {
        let route = c.u32()?;
        let pos = c.u32()?;
        if route as usize >= n_routes {
            return Err(bad("ftt: stop->route id out of range"));
        }
        if pos >= routes[route as usize].n_stops {
            return Err(bad("ftt: stop->route position out of the route pattern"));
        }
        stop_routes.push(StopRoute { route, pos });
    }
    // The memberships are the route patterns turned inside out, and nothing
    // else: RAPTOR finds the routes to scan from them, so one filed under
    // the wrong stop boards a vehicle where it does not call, and one left
    // out hides a route from everyone waiting there. Each entry must name a
    // pattern slot holding the stop it is filed under; with as many entries
    // as slots and no slot named twice, every slot is filed exactly once.
    if n_stop_routes != n_route_stops {
        return Err(bad("ftt: stop->route count is not the pattern count"));
    }
    let mut filed = vec![false; n_route_stops];
    for s in 0..n_stops {
        let (a, b) = (stop_route_off[s] as usize, stop_route_off[s + 1] as usize);
        for sr in &stop_routes[a..b] {
            let slot = routes[sr.route as usize].stop_start as usize + sr.pos as usize;
            if route_stops[slot] as usize != s {
                return Err(bad("ftt: stop->route entry is not that stop's"));
            }
            if std::mem::replace(&mut filed[slot], true) {
                return Err(bad("ftt: stop->route entry filed twice"));
            }
        }
    }

    let mut footpath_off = Vec::with_capacity(n_stops + 1);
    for _ in 0..=n_stops {
        footpath_off.push(c.u32()?);
    }
    check_offsets(&footpath_off, n_footpaths as u32, "footpath")?;

    let mut footpaths = Vec::with_capacity(n_footpaths);
    for _ in 0..n_footpaths {
        let to = c.u32()?;
        let secs = c.u32()?;
        if to as usize >= n_stops {
            return Err(bad("ftt: footpath target out of range"));
        }
        footpaths.push(Footpath { to, secs });
    }

    debug_assert_eq!(c.pos, body.len());
    let change_secs = super::change_secs_of(n_stops, &footpath_off, &footpaths);
    Ok(Timetable {
        stops,
        routes,
        route_stops,
        stop_events,
        stop_route_off,
        stop_routes,
        footpath_off,
        footpaths,
        change_secs,
    })
}

/// Read a `.ftt` v1 file into a [`Timetable`].
pub fn read_ftt(path: &Path) -> io::Result<Timetable> {
    let bytes = fs::read(path)?;
    from_bytes(&bytes)
}

// -----------------------------------------------------------------------------
// Tests — round-trip byte equality, plan equality, and corrupt-shard refusal.
// -----------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use crate::transit::{plan, Mode, StopEvent, Time, TimetableBuilder};
    use std::path::PathBuf;

    fn ev(arr: Time, dep: Time) -> StopEvent {
        StopEvent { arr, dep }
    }

    /// A timetable exercising every section: multiple routes/modes, multi-trip
    /// routes, footpaths, and a stop with no service (offset-array edge).
    fn rich_timetable() -> crate::transit::Timetable {
        let mut b = TimetableBuilder::new();
        let a = b.add_stop(43_073_051, -89_401_230);
        let bb = b.add_stop(43_074_000, -89_390_000);
        let c = b.add_stop(43_080_000, -89_380_000);
        let d = b.add_stop(43_090_000, -89_370_000);
        let _lonely = b.add_stop(0, 0); // no routes, no footpaths
        b.add_route(
            &[a, bb, c],
            vec![
                vec![ev(0, 0), ev(600, 630), ev(1200, 1200)],
                vec![ev(900, 900), ev(1500, 1530), ev(2100, 2100)],
            ],
            Mode::Rail,
        );
        b.add_route(
            &[c, d],
            vec![vec![ev(1400, 1400), ev(2000, 2000)]],
            Mode::Subway,
        );
        b.add_route(&[a, d], vec![vec![ev(0, 0), ev(4000, 4000)]], Mode::Coach);
        b.add_footpath(bb, c, 120);
        b.add_footpath(c, bb, 120);
        b.build()
    }

    fn tmp_path(name: &str) -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "flows_ftt_test_{}_{}.ftt",
            name,
            std::process::id()
        ));
        p
    }

    #[test]
    fn a_ferry_route_keeps_its_ship_mode() {
        let mut b = TimetableBuilder::new();
        let a = b.add_stop(40_701_000, -74_013_000);
        let c = b.add_stop(40_643_000, -74_073_000);
        b.add_route(&[a, c], vec![vec![ev(0, 0), ev(1500, 1500)]], Mode::Ship);
        let tt = b.build();
        let back = from_bytes(&to_bytes(&tt)).unwrap();
        assert_eq!(back.route_mode(0), Mode::Ship);
        assert_eq!(to_bytes(&back), to_bytes(&tt));
    }

    #[test]
    fn round_trip_is_byte_equal_and_plans_are_identical() {
        let tt = rich_timetable();
        let path = tmp_path("roundtrip");
        write_ftt(&tt, &path).unwrap();
        let tt2 = read_ftt(&path).unwrap();

        // Byte-equal arrays: the reloaded timetable re-encodes to the same bytes
        // (covers every field of every section), and each array matches directly.
        assert_eq!(
            to_bytes(&tt),
            to_bytes(&tt2),
            "re-encode must be byte-identical"
        );
        assert_eq!(tt.stops, tt2.stops);
        assert_eq!(tt.route_stops, tt2.route_stops);
        assert_eq!(tt.stop_events, tt2.stop_events);
        assert_eq!(tt.stop_route_off, tt2.stop_route_off);
        assert_eq!(tt.footpath_off, tt2.footpath_off);
        assert_eq!(tt.footpaths, tt2.footpaths);
        assert_eq!(tt.routes.len(), tt2.routes.len());
        for (x, y) in tt.routes.iter().zip(tt2.routes.iter()) {
            assert_eq!(x.stop_start, y.stop_start);
            assert_eq!(x.n_stops, y.n_stops);
            assert_eq!(x.event_start, y.event_start);
            assert_eq!(x.n_trips, y.n_trips);
            assert_eq!(x.mode, y.mode);
        }
        assert_eq!(tt.stop_routes.len(), tt2.stop_routes.len());
        for (x, y) in tt.stop_routes.iter().zip(tt2.stop_routes.iter()) {
            assert_eq!(x.route, y.route);
            assert_eq!(x.pos, y.pos);
        }

        // RAPTOR must produce identical plans on original vs reloaded for every
        // OD pair and a few departure times.
        let n = tt.n_stops() as u32;
        for s in 0..n {
            for t in 0..n {
                if s == t {
                    continue;
                }
                for depart in [0u32, 700, 1450] {
                    assert_eq!(
                        plan(&tt, s, t, depart, 8),
                        plan(&tt2, s, t, depart, 8),
                        "plan {s}->{t}@{depart} differs after .ftt round-trip"
                    );
                }
            }
        }
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn corrupt_or_malformed_files_are_refused() {
        let tt = rich_timetable();
        let good = to_bytes(&tt);

        // Flipped body byte -> hash mismatch.
        let mut flipped = good.clone();
        let i = FTT_HEADER_LEN + 5;
        flipped[i] ^= 0xFF;
        assert!(
            from_bytes(&flipped).is_err(),
            "hash mismatch must be refused"
        );

        // Truncated body.
        assert!(from_bytes(&good[..good.len() - 1]).is_err());
        // Shorter than the header.
        assert!(from_bytes(&good[..32]).is_err());

        // Wrong magic.
        let mut wrong = good.clone();
        wrong[0] = b'X';
        assert!(from_bytes(&wrong).is_err());

        // Wrong version.
        let mut v2 = good.clone();
        v2[4..8].copy_from_slice(&2u32.to_le_bytes());
        assert!(from_bytes(&v2).is_err());

        // Out-of-range stop id inside a route pattern (fix the hash so only the
        // semantic validation can catch it).
        let mut bad_stop = good.clone();
        let route_stops_at = FTT_HEADER_LEN + tt.n_stops() * 8 + tt.n_routes() * 20;
        bad_stop[route_stops_at..route_stops_at + 4].copy_from_slice(&999u32.to_le_bytes());
        let h = fnv1a64(&bad_stop[FTT_HEADER_LEN..]);
        bad_stop[40..48].copy_from_slice(&h.to_le_bytes());
        assert!(
            from_bytes(&bad_stop).is_err(),
            "out-of-range stop id must be refused"
        );

        // Empty and garbage inputs.
        assert!(from_bytes(&[]).is_err());
        assert!(from_bytes(&[0u8; 64]).is_err());
    }

    #[test]
    fn out_of_order_or_negative_dwell_trips_are_refused() {
        let tt = rich_timetable();
        let good = to_bytes(&tt);
        let ev_at =
            FTT_HEADER_LEN + tt.n_stops() * 8 + tt.n_routes() * 20 + tt.route_stops.len() * 4;
        let rehash = |b: &mut [u8]| {
            let h = fnv1a64(&b[FTT_HEADER_LEN..]);
            b[40..48].copy_from_slice(&h.to_le_bytes());
        };

        // Swap route0's two trips (3 stops x 8 bytes each): departures at
        // every position now DECREASE across the trip index, which would
        // break earliest_trip's binary search.
        let mut swapped = good.clone();
        let first = swapped[ev_at..ev_at + 24].to_vec();
        swapped.copy_within(ev_at + 24..ev_at + 48, ev_at);
        swapped[ev_at + 24..ev_at + 48].copy_from_slice(&first);
        rehash(&mut swapped);
        assert!(
            from_bytes(&swapped).is_err(),
            "overtaking trip order must be refused"
        );

        // An event that departs before it arrives is equally invalid.
        let mut neg_dwell = good.clone();
        neg_dwell[ev_at..ev_at + 4].copy_from_slice(&999u32.to_le_bytes()); // arr > dep(=0)
        rehash(&mut neg_dwell);
        assert!(from_bytes(&neg_dwell).is_err(), "arr > dep must be refused");

        // The untouched bytes still decode (the sweep has no false positives).
        assert!(from_bytes(&good).is_ok());
    }

    /// Re-hash a tampered file so only the semantic checks can refuse it.
    fn rehash(b: &mut [u8]) {
        let h = fnv1a64(&b[FTT_HEADER_LEN..]);
        b[40..48].copy_from_slice(&h.to_le_bytes());
    }

    #[test]
    fn routes_sharing_or_skipping_table_rows_are_refused() {
        let tt = rich_timetable();
        let good = to_bytes(&tt);
        let routes_at = FTT_HEADER_LEN + tt.n_stops() * 8;
        // Route 1 (2 stops, 1 trip) pointed at route 0's events: in bounds,
        // so the old bounds check let it through, and any number of routes
        // could name the same rows — the sweep then ran once per route.
        let mut shared_events = good.clone();
        shared_events[routes_at + 20 + 8..routes_at + 20 + 12].copy_from_slice(&0u32.to_le_bytes());
        rehash(&mut shared_events);
        assert!(from_bytes(&shared_events).is_err(), "shared event rows");
        // The same for the pattern rows.
        let mut shared_pattern = good.clone();
        shared_pattern[routes_at + 20..routes_at + 24].copy_from_slice(&0u32.to_le_bytes());
        rehash(&mut shared_pattern);
        assert!(from_bytes(&shared_pattern).is_err(), "shared pattern rows");
        // A trip count of zero on the last route leaves its events owned by
        // nobody: the tables no longer add up.
        let mut orphaned = good.clone();
        orphaned[routes_at + 40 + 12..routes_at + 40 + 16].copy_from_slice(&0u32.to_le_bytes());
        rehash(&mut orphaned);
        assert!(from_bytes(&orphaned).is_err(), "orphaned event rows");
    }

    #[test]
    fn a_trip_that_goes_back_in_time_is_refused() {
        let tt = rich_timetable();
        let mut bytes = to_bytes(&tt);
        let ev_at =
            FTT_HEADER_LEN + tt.n_stops() * 8 + tt.n_routes() * 20 + tt.route_stops.len() * 4;
        // Route 0, trip 0 leaves its first stop at 700 and reaches the next
        // at 600. Each event alone is fine (arr <= dep) and no trip is
        // overtaken (the next trip leaves at 900).
        bytes[ev_at + 4..ev_at + 8].copy_from_slice(&700u32.to_le_bytes());
        rehash(&mut bytes);
        assert!(from_bytes(&bytes).is_err());
    }

    #[test]
    fn stop_routes_that_are_not_the_patterns_inverse_are_refused() {
        let tt = rich_timetable();
        let good = to_bytes(&tt);
        let sr_at = FTT_HEADER_LEN
            + tt.n_stops() * 8
            + tt.n_routes() * 20
            + tt.route_stops.len() * 4
            + tt.stop_events.len() * 8
            + (tt.n_stops() + 1) * 4;
        // Entries 1 and 2 belong to different stops: swapped, each is filed
        // under a stop its route does not call at in that position.
        let mut swapped = good.clone();
        let first = swapped[sr_at + 8..sr_at + 16].to_vec();
        swapped.copy_within(sr_at + 16..sr_at + 24, sr_at + 8);
        swapped[sr_at + 16..sr_at + 24].copy_from_slice(&first);
        rehash(&mut swapped);
        assert!(from_bytes(&swapped).is_err(), "filed under the wrong stop");
        // Entry 1 a copy of entry 0 (both under stop 0): one membership
        // twice, another missing.
        let mut twice = good.clone();
        twice.copy_within(sr_at..sr_at + 8, sr_at + 8);
        rehash(&mut twice);
        assert!(from_bytes(&twice).is_err(), "filed twice");
        assert!(from_bytes(&good).is_ok());
    }

    #[test]
    fn counts_whose_sizes_wrap_32_bits_are_refused() {
        // 2^29 stops x 8 bytes is 2^32: summed in 32 bits it wrapped to the
        // few bytes of offsets a file this small does hold.
        let mut bytes = vec![0u8; FTT_HEADER_LEN + 8];
        bytes[0..4].copy_from_slice(&FTT_MAGIC);
        bytes[4..8].copy_from_slice(&FTT_VERSION.to_le_bytes());
        bytes[8..12].copy_from_slice(&(1u32 << 29).to_le_bytes());
        bytes[32..40].copy_from_slice(&8u64.to_le_bytes());
        rehash(&mut bytes);
        assert!(from_bytes(&bytes).is_err());
    }

    #[test]
    fn a_same_stop_change_time_rides_through_the_file() {
        let mut b = TimetableBuilder::new();
        let a = b.add_stop(0, 0);
        let c = b.add_stop(1, 1);
        b.add_route(&[a, c], vec![vec![ev(0, 0), ev(600, 600)]], Mode::Bus);
        b.add_footpath(c, c, 180);
        let tt = b.build();
        let back = from_bytes(&to_bytes(&tt)).unwrap();
        assert_eq!(back.change_secs(c), 180);
        assert_eq!(back.change_secs(a), 0);
        assert_eq!(to_bytes(&back), to_bytes(&tt));
    }

    #[test]
    fn header_counts_match_the_timetable() {
        let tt = rich_timetable();
        let bytes = to_bytes(&tt);
        assert_eq!(&bytes[0..4], b"FTT1");
        let n_stops = u32::from_le_bytes(bytes[8..12].try_into().unwrap());
        let n_routes = u32::from_le_bytes(bytes[12..16].try_into().unwrap());
        assert_eq!(n_stops as usize, tt.n_stops());
        assert_eq!(n_routes as usize, tt.n_routes());
        let body_len = u64::from_le_bytes(bytes[32..40].try_into().unwrap()) as usize;
        assert_eq!(body_len, bytes.len() - FTT_HEADER_LEN);
    }
}
