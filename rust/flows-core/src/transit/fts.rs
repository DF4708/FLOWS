// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! `.fts` v1 — the labels that ride alongside a [`super::ftt`] shard: what each
//! stop is CALLED, what CLOCK it keeps, and when the feed was published.
//!
//! The `.ftt` carries only what RAPTOR reads — positions and times — because
//! every byte in it is resident during a query. But a rider does not board
//! "stop 417 at 46800"; they board "Milwaukee Intermodal Station at 7:05 AM".
//! Those strings are touched once per rendered itinerary, so they live in a
//! separate file that is read and dropped, and the `.ftt` stays exactly the
//! tested, hashed v1 it already was.
//!
//! **Zones are the reason this file exists.** Per the GTFS reference every time
//! in `stop_times.txt` is measured from midnight in the AGENCY's timezone,
//! wherever the stop happens to be. Amtrak publishes one agency zone
//! (`America/New_York`) and four stop zones, so the Coast Starlight's Seattle
//! departure is stored as `12:55:00` and printed as 9:55 AM. A shard that
//! forgot its zones would print every western time three hours late — the one
//! failure that makes a departure board worse than no departure board.
//!
//! Layout (little-endian, the `.ftt` conventions):
//!
//! ```text
//! HEADER (64 bytes)
//!   0..4    magic "FTS1"
//!   4..8    format version    u32 (= 1)
//!   8..12   n_stops           u32  (must equal the paired .ftt's)
//!   12..16  n_routes          u32  (must equal the paired .ftt's)
//!   16..20  n_zones           u32
//!   20..24  service_date      u32  (YYYYMMDD)
//!   24..28  feed_published    u32  (YYYYMMDD, 0 = unknown)
//!   28..32  agency_zone       u32  (index into ZONES)
//!   32..40  paired .ftt body hash u64 (a shard and its labels are refused
//!                                      unless they came from the same build)
//!   40..48  body length       u64
//!   48..56  fnv1a-64 body hash u64
//!   56..64  reserved (zero)
//! BODY
//!   ZONES    n_zones  x (off u32, len u32)   -- IANA ids, into TEXT
//!   STOPS    n_stops  x (name_off u32, name_len u32,
//!                        code_off u32, code_len u32, zone u32)
//!   ROUTES   n_routes x (off u32, len u32)
//!   TEXT     utf-8 bytes
//! ```
//!
//! Pure std, no external crates. Every offset is bounds-checked and every
//! string UTF-8-validated on read: a truncated or tampered sidecar is refused,
//! never half-trusted.

use std::fs;
use std::io::{self, Write};
use std::path::Path;

/// File magic: the first four bytes of every `.fts`.
pub const FTS_MAGIC: [u8; 4] = *b"FTS1";
/// Format version this module writes and the only one it accepts.
pub const FTS_VERSION: u32 = 1;
/// Fixed header size in bytes.
pub const FTS_HEADER_LEN: usize = 64;

/// What a shard's stops and routes are called, and which clock each keeps.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Labels {
    /// Dense stop index → display name ("Chicago Union Station").
    pub stop_names: Vec<String>,
    /// Dense stop index → the operator's own code ("CHI"), for deep links like
    /// `amtrak.com/stations/chi`. Empty when the feed has none.
    pub stop_codes: Vec<String>,
    /// Dense stop index → IANA zone the stop's CLOCK reads in — not the zone
    /// its times are stored in. See the module docs.
    pub stop_zones: Vec<String>,
    /// Engine route index → display name ("Southwest Chief").
    pub route_names: Vec<String>,
    /// The zone every stop time in this shard is measured from.
    pub agency_zone: String,
    /// Service date the shard was built for (YYYYMMDD).
    pub service_date: u32,
    /// When the publisher cut the feed (YYYYMMDD), 0 when unknown.
    pub feed_published: u32,
}

/// FNV-1a 64-bit — same body hash the `.ftt` uses.
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

/// Interns strings into one TEXT blob, so the 646 Amtrak stops that share four
/// zone ids store the id once.
#[derive(Default)]
struct TextPool {
    bytes: Vec<u8>,
    seen: std::collections::HashMap<String, (u32, u32)>,
}

impl TextPool {
    fn intern(&mut self, s: &str) -> (u32, u32) {
        if let Some(&span) = self.seen.get(s) {
            return span;
        }
        let span = (self.bytes.len() as u32, s.len() as u32);
        self.bytes.extend_from_slice(s.as_bytes());
        self.seen.insert(s.to_string(), span);
        span
    }
}

/// Encode [`Labels`] into `.fts` v1 bytes, paired to the `.ftt` whose body
/// hashes to `ftt_body_hash` (see [`super::ftt::body_hash`]). Deterministic.
pub fn to_bytes(labels: &Labels, ftt_body_hash: u64) -> Vec<u8> {
    let n_stops = labels.stop_names.len();
    let n_routes = labels.route_names.len();

    // Zones are interned into their own dense table first: a stop stores a
    // 4-byte index, not a repeated "America/Los_Angeles".
    let mut zone_ids: Vec<String> = Vec::new();
    let mut zone_index: std::collections::HashMap<String, u32> = std::collections::HashMap::new();
    let mut zone_of = |z: &str| -> u32 {
        if let Some(&i) = zone_index.get(z) {
            return i;
        }
        let i = zone_ids.len() as u32;
        zone_ids.push(z.to_string());
        zone_index.insert(z.to_string(), i);
        i
    };
    let mut stop_zone_idx: Vec<u32> = Vec::with_capacity(n_stops);
    for i in 0..n_stops {
        stop_zone_idx.push(zone_of(
            labels.stop_zones.get(i).map(String::as_str).unwrap_or(""),
        ));
    }
    let agency_zone_idx = zone_of(&labels.agency_zone);

    let mut text = TextPool::default();
    let zone_spans: Vec<(u32, u32)> = zone_ids.iter().map(|z| text.intern(z)).collect();
    let stop_spans: Vec<((u32, u32), (u32, u32))> = (0..n_stops)
        .map(|i| {
            let name = labels.stop_names.get(i).map(String::as_str).unwrap_or("");
            let code = labels.stop_codes.get(i).map(String::as_str).unwrap_or("");
            (text.intern(name), text.intern(code))
        })
        .collect();
    let route_spans: Vec<(u32, u32)> = labels.route_names.iter().map(|r| text.intern(r)).collect();

    let mut body = Vec::new();
    for (off, len) in &zone_spans {
        put_u32(&mut body, *off);
        put_u32(&mut body, *len);
    }
    for (i, ((n_off, n_len), (c_off, c_len))) in stop_spans.iter().enumerate() {
        put_u32(&mut body, *n_off);
        put_u32(&mut body, *n_len);
        put_u32(&mut body, *c_off);
        put_u32(&mut body, *c_len);
        put_u32(&mut body, stop_zone_idx[i]);
    }
    for (off, len) in &route_spans {
        put_u32(&mut body, *off);
        put_u32(&mut body, *len);
    }
    body.extend_from_slice(&text.bytes);

    let mut out = Vec::with_capacity(FTS_HEADER_LEN + body.len());
    out.extend_from_slice(&FTS_MAGIC);
    put_u32(&mut out, FTS_VERSION);
    put_u32(&mut out, n_stops as u32);
    put_u32(&mut out, n_routes as u32);
    put_u32(&mut out, zone_ids.len() as u32);
    put_u32(&mut out, labels.service_date);
    put_u32(&mut out, labels.feed_published);
    put_u32(&mut out, agency_zone_idx);
    out.extend_from_slice(&ftt_body_hash.to_le_bytes());
    out.extend_from_slice(&(body.len() as u64).to_le_bytes());
    out.extend_from_slice(&fnv1a64(&body).to_le_bytes());
    out.extend_from_slice(&[0u8; FTS_HEADER_LEN - 56]); // reserved
    debug_assert_eq!(out.len(), FTS_HEADER_LEN);
    out.extend_from_slice(&body);
    out
}

/// Write `labels` to `path` as `.fts` v1.
pub fn write_fts(labels: &Labels, ftt_body_hash: u64, path: &Path) -> io::Result<()> {
    let bytes = to_bytes(labels, ftt_body_hash);
    let mut f = fs::File::create(path)?;
    f.write_all(&bytes)?;
    f.sync_all()
}

fn bad(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg)
}

#[inline]
fn u32_at(b: &[u8], off: usize) -> u32 {
    u32::from_le_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]])
}

#[inline]
fn u64_at(b: &[u8], off: usize) -> u64 {
    let mut v = [0u8; 8];
    v.copy_from_slice(&b[off..off + 8]);
    u64::from_le_bytes(v)
}

/// Decode `.fts` v1 bytes. `ftt_body_hash` is the hash of the shard these
/// labels are supposed to belong to; a mismatch is refused, because labels from
/// one build applied to another build's indices name the wrong stations —
/// silently, and plausibly.
pub fn from_bytes(bytes: &[u8], ftt_body_hash: u64) -> io::Result<Labels> {
    if bytes.len() < FTS_HEADER_LEN {
        return Err(bad("fts: shorter than its header"));
    }
    if bytes[0..4] != FTS_MAGIC {
        return Err(bad("fts: bad magic"));
    }
    let version = u32_at(bytes, 4);
    if version != FTS_VERSION {
        return Err(bad("fts: unsupported format version"));
    }
    let n_stops = u32_at(bytes, 8) as usize;
    let n_routes = u32_at(bytes, 12) as usize;
    let n_zones = u32_at(bytes, 16) as usize;
    let service_date = u32_at(bytes, 20);
    let feed_published = u32_at(bytes, 24);
    let agency_zone_idx = u32_at(bytes, 28) as usize;
    let paired = u64_at(bytes, 32);
    if paired != ftt_body_hash {
        return Err(bad("fts: labels do not belong to this timetable"));
    }
    let body_len = u64_at(bytes, 40) as usize;
    let want_hash = u64_at(bytes, 48);
    let body = bytes
        .get(FTS_HEADER_LEN..FTS_HEADER_LEN + body_len)
        .ok_or_else(|| bad("fts: body truncated"))?;
    if fnv1a64(body) != want_hash {
        return Err(bad("fts: body hash mismatch"));
    }

    let zones_len = n_zones
        .checked_mul(8)
        .ok_or_else(|| bad("fts: n_zones overflows"))?;
    let stops_len = n_stops
        .checked_mul(20)
        .ok_or_else(|| bad("fts: n_stops overflows"))?;
    let routes_len = n_routes
        .checked_mul(8)
        .ok_or_else(|| bad("fts: n_routes overflows"))?;
    let text_start = zones_len
        .checked_add(stops_len)
        .and_then(|v| v.checked_add(routes_len))
        .ok_or_else(|| bad("fts: sections overflow"))?;
    if body.len() < text_start {
        return Err(bad("fts: sections do not fit the body"));
    }
    let text = &body[text_start..];

    let span = |off: u32, len: u32| -> io::Result<String> {
        let a = off as usize;
        let b = a
            .checked_add(len as usize)
            .ok_or_else(|| bad("fts: string span overflows"))?;
        let s = text
            .get(a..b)
            .ok_or_else(|| bad("fts: string out of range"))?;
        std::str::from_utf8(s)
            .map(str::to_string)
            .map_err(|_| bad("fts: string is not utf-8"))
    };

    let mut zones = Vec::with_capacity(n_zones);
    for i in 0..n_zones {
        let o = i * 8;
        zones.push(span(u32_at(body, o), u32_at(body, o + 4))?);
    }
    let zone_at = |i: usize| -> io::Result<String> {
        zones
            .get(i)
            .cloned()
            .ok_or_else(|| bad("fts: zone index out of range"))
    };

    let mut stop_names = Vec::with_capacity(n_stops);
    let mut stop_codes = Vec::with_capacity(n_stops);
    let mut stop_zones = Vec::with_capacity(n_stops);
    for i in 0..n_stops {
        let o = zones_len + i * 20;
        stop_names.push(span(u32_at(body, o), u32_at(body, o + 4))?);
        stop_codes.push(span(u32_at(body, o + 8), u32_at(body, o + 12))?);
        stop_zones.push(zone_at(u32_at(body, o + 16) as usize)?);
    }

    let mut route_names = Vec::with_capacity(n_routes);
    for i in 0..n_routes {
        let o = zones_len + stops_len + i * 8;
        route_names.push(span(u32_at(body, o), u32_at(body, o + 4))?);
    }

    Ok(Labels {
        stop_names,
        stop_codes,
        stop_zones,
        route_names,
        agency_zone: zone_at(agency_zone_idx)?,
        service_date,
        feed_published,
    })
}

/// Read a `.fts` file, checking it was built beside the `.ftt` whose body
/// hashes to `ftt_body_hash`.
pub fn read_fts(path: &Path, ftt_body_hash: u64) -> io::Result<Labels> {
    from_bytes(&fs::read(path)?, ftt_body_hash)
}
