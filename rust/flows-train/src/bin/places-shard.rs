// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! FLOWS offline POI shard builder — pure std, ZERO external crates, the same
//! discipline as `flows-core` / `flows-train`.
//!
//! Compiles the Foursquare OS Places TSV (Apache 2.0; produced by the repo
//! tooling `scripts/fsq_places_to_tsv.py` — python is conversion tooling only,
//! never a product dependency) into one binary shard per US state/territory:
//! `data/places/<XX>.fps`, plus `data/places/index.json`.
//!
//! ## `.fps` v1 ("FPS1") layout — little-endian throughout
//!
//! ```text
//! offset  size  field
//! 0..4     4    magic  "FPS1"
//! 4..8     4    version u32                 (== 1)
//! 8..12    4    record count u32
//! 12..20   8    grid-index offset u64       (absolute, from start of file)
//! 20..28   8    fnv1a-64 body hash u64      (over bytes[32..] — records+grid;
//!                validated on read, a corrupt shard is refused, not "repaired")
//! 28..32   4    grid cell count u32
//! 32..     —    records, sorted by (0.2 deg grid cell key, name):
//!                lat f32, lon f32, group u8, flags u8,
//!                then u16-length-prefixed UTF-8: name, street, city, website,
//!                tel, then postcode u32 (0 = none)
//! grid-index offset..
//!          —    grid index: cell count entries of
//!                (cellKey i64, startRecord u32, count u32), sorted by cellKey
//!                for binary search
//! ```
//!
//! Cell key: `lat5 = floor(lat*5)`, `lon5 = floor(lon*5)` (0.2 deg cells),
//! `cellKey = (lat5 + 9000) * 100_000 + (lon5 + 18_000)` — always positive,
//! and ordering by key clusters south-to-north, west-to-east.
//!
//! Groups: 0=fuel 1=food 2=stores 3=hotel 4=medical 5=tourist 6=transit
//! 7=rest/truckstop. `flags` is reserved (0 in v1).
//!
//! Usage: places-shard <fsq_places_us.tsv> <out dir e.g. data/places>

use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::io::{self, BufRead, BufReader, Write};
use std::path::Path;

/// File magic: the first four bytes of every `.fps`.
pub const FPS_MAGIC: [u8; 4] = *b"FPS1";
/// Format version this tool writes and the only one it accepts.
pub const FPS_VERSION: u32 = 1;
/// Fixed header size in bytes.
pub const FPS_HEADER_LEN: usize = 32;
/// Longest string stored per field (bytes). Fields are clipped at a UTF-8
/// boundary so a u16 length prefix always suffices and shards stay lean.
const MAX_FIELD_BYTES: usize = 512;

/// FNV-1a 64-bit — the body integrity hash (same function as `ftt.rs`; tiny,
/// deterministic, dependency-free).
fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

/// One point of interest as stored in a shard.
#[derive(Debug, Clone, PartialEq)]
pub struct Place {
    pub lat: f32,
    pub lon: f32,
    pub group: u8,
    pub flags: u8,
    pub name: String,
    pub street: String,
    pub city: String,
    pub website: String,
    pub tel: String,
    /// 5-digit ZIP, 0 = none.
    pub postcode: u32,
}

/// 0.2 deg grid cell key for a coordinate — the sort key and the grid-index
/// lookup key. Uses floor (not trunc) so western/southern hemispheres bin
/// correctly.
pub fn cell_key(lat: f32, lon: f32) -> i64 {
    let lat5 = (lat as f64 * 5.0).floor() as i64;
    let lon5 = (lon as f64 * 5.0).floor() as i64;
    (lat5 + 9000) * 100_000 + (lon5 + 18_000)
}

fn put_u16(out: &mut Vec<u8>, v: u16) {
    out.extend_from_slice(&v.to_le_bytes());
}
fn put_u32(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_le_bytes());
}

/// Clip `s` to at most `MAX_FIELD_BYTES` bytes on a UTF-8 char boundary.
fn clipped(s: &str) -> &str {
    if s.len() <= MAX_FIELD_BYTES {
        return s;
    }
    let mut end = MAX_FIELD_BYTES;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

fn put_str(out: &mut Vec<u8>, s: &str) {
    let c = clipped(s);
    put_u16(out, c.len() as u16);
    out.extend_from_slice(c.as_bytes());
}

/// Encode places into `.fps` v1 bytes. Sorts a copy by (cell, name) — the
/// same bytes always come out of the same set of places.
pub fn to_bytes(places: &[Place]) -> Vec<u8> {
    let mut order: Vec<usize> = (0..places.len()).collect();
    order.sort_by(|&a, &b| {
        let (pa, pb) = (&places[a], &places[b]);
        cell_key(pa.lat, pa.lon)
            .cmp(&cell_key(pb.lat, pb.lon))
            .then_with(|| pa.name.cmp(&pb.name))
            .then_with(|| pa.lon.total_cmp(&pb.lon))
            .then_with(|| pa.lat.total_cmp(&pb.lat))
    });

    // --- Body part 1: records in sorted order, building the grid runs. ---
    let mut body = Vec::new();
    let mut grid: Vec<(i64, u32, u32)> = Vec::new();
    for (i, &pi) in order.iter().enumerate() {
        let p = &places[pi];
        let key = cell_key(p.lat, p.lon);
        match grid.last_mut() {
            Some(last) if last.0 == key => last.2 += 1,
            _ => grid.push((key, i as u32, 1)),
        }
        body.extend_from_slice(&p.lat.to_le_bytes());
        body.extend_from_slice(&p.lon.to_le_bytes());
        body.push(p.group);
        body.push(p.flags);
        put_str(&mut body, &p.name);
        put_str(&mut body, &p.street);
        put_str(&mut body, &p.city);
        put_str(&mut body, &p.website);
        put_str(&mut body, &p.tel);
        put_u32(&mut body, p.postcode);
    }

    // --- Body part 2: the grid index (already sorted — records were). ---
    let grid_off = (FPS_HEADER_LEN + body.len()) as u64;
    for &(key, start, count) in &grid {
        body.extend_from_slice(&key.to_le_bytes());
        put_u32(&mut body, start);
        put_u32(&mut body, count);
    }

    // --- Header. ---
    let mut out = Vec::with_capacity(FPS_HEADER_LEN + body.len());
    out.extend_from_slice(&FPS_MAGIC);
    put_u32(&mut out, FPS_VERSION);
    put_u32(&mut out, places.len() as u32);
    out.extend_from_slice(&grid_off.to_le_bytes());
    out.extend_from_slice(&fnv1a64(&body).to_le_bytes());
    put_u32(&mut out, grid.len() as u32);
    debug_assert_eq!(out.len(), FPS_HEADER_LEN);
    out.extend_from_slice(&body);
    out
}

/// A decoded shard: records in file order plus the grid index.
pub struct Shard {
    pub places: Vec<Place>,
    grid: Vec<(i64, u32, u32)>,
}

impl Shard {
    /// All records in the 0.2 deg cell containing (`lat`, `lon`) — binary
    /// search on the grid index, then the contiguous record run.
    pub fn in_cell(&self, lat: f32, lon: f32) -> &[Place] {
        let key = cell_key(lat, lon);
        match self.grid.binary_search_by_key(&key, |e| e.0) {
            Ok(i) => {
                let (_, start, count) = self.grid[i];
                &self.places[start as usize..(start + count) as usize]
            }
            Err(_) => &[],
        }
    }
}

fn bad(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg)
}

struct Cursor<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn take(&mut self, n: usize) -> io::Result<&'a [u8]> {
        // pos+n can't overflow: pos <= buf.len() and n is checked against the
        // remainder, both far below usize::MAX for any real file.
        if self.buf.len() - self.pos < n {
            return Err(bad("fps: truncated record"));
        }
        let s = &self.buf[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }
    fn f32(&mut self) -> io::Result<f32> {
        Ok(f32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u8(&mut self) -> io::Result<u8> {
        Ok(self.take(1)?[0])
    }
    fn u16(&mut self) -> io::Result<u16> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap()))
    }
    fn u32(&mut self) -> io::Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn i64(&mut self) -> io::Result<i64> {
        Ok(i64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn str(&mut self) -> io::Result<String> {
        let n = self.u16()? as usize;
        let raw = self.take(n)?;
        String::from_utf8(raw.to_vec()).map_err(|_| bad("fps: invalid UTF-8"))
    }
}

/// Decode `.fps` v1 bytes. Refuses wrong magic/version, any truncation, any
/// out-of-range grid entry, and any body whose fnv1a-64 hash does not match
/// the header — corrupt data is rejected, never partially loaded.
pub fn from_bytes(bytes: &[u8]) -> io::Result<Shard> {
    if bytes.len() < FPS_HEADER_LEN {
        return Err(bad("fps: shorter than the fixed header"));
    }
    if bytes[0..4] != FPS_MAGIC {
        return Err(bad("fps: bad magic (not an .fps file)"));
    }
    let mut h = Cursor { buf: bytes, pos: 4 };
    let version = h.u32()?;
    if version != FPS_VERSION {
        return Err(bad("fps: unsupported version"));
    }
    let n_records = h.u32()? as usize;
    let grid_off = u64::from_le_bytes(h.take(8)?.try_into().unwrap()) as usize;
    let hash = u64::from_le_bytes(h.take(8)?.try_into().unwrap());
    let n_cells = h.u32()? as usize;

    if grid_off < FPS_HEADER_LEN || grid_off > bytes.len() {
        return Err(bad("fps: grid offset out of range"));
    }
    if bytes.len() - grid_off != n_cells * 16 {
        return Err(bad("fps: grid size does not match the header count"));
    }
    if fnv1a64(&bytes[FPS_HEADER_LEN..]) != hash {
        return Err(bad("fps: body hash mismatch (corrupt shard)"));
    }

    let mut c = Cursor {
        buf: &bytes[..grid_off],
        pos: FPS_HEADER_LEN,
    };
    let mut places = Vec::with_capacity(n_records);
    for _ in 0..n_records {
        places.push(Place {
            lat: c.f32()?,
            lon: c.f32()?,
            group: c.u8()?,
            flags: c.u8()?,
            name: c.str()?,
            street: c.str()?,
            city: c.str()?,
            website: c.str()?,
            tel: c.str()?,
            postcode: c.u32()?,
        });
    }
    if c.pos != grid_off {
        return Err(bad("fps: record section length mismatch"));
    }

    let mut g = Cursor {
        buf: bytes,
        pos: grid_off,
    };
    let mut grid = Vec::with_capacity(n_cells);
    let mut prev_key = i64::MIN;
    for _ in 0..n_cells {
        let key = g.i64()?;
        let start = g.u32()?;
        let count = g.u32()?;
        if key <= prev_key {
            return Err(bad("fps: grid keys not strictly ascending"));
        }
        prev_key = key;
        let end = (start as usize).checked_add(count as usize);
        if end.is_none() || end.unwrap() > n_records {
            return Err(bad("fps: grid run out of record range"));
        }
        grid.push((key, start, count));
    }
    Ok(Shard { places, grid })
}

// ---------------------------------------------------------------------------
// TSV -> per-state shards
// ---------------------------------------------------------------------------

/// Leading-digits ZIP parse: "53534-1234" -> 53534, junk -> 0.
fn parse_zip(s: &str) -> u32 {
    let digits: String = s.chars().take_while(|c| c.is_ascii_digit()).collect();
    if digits.len() == 5 {
        digits.parse().unwrap_or(0)
    } else {
        0
    }
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn run(tsv: &Path, out_dir: &Path) -> io::Result<()> {
    let mut by_state: BTreeMap<String, Vec<Place>> = BTreeMap::new();
    let mut group_counts = [0u64; 8];
    let mut skipped = 0u64;

    let reader = BufReader::new(fs::File::open(tsv)?);
    for line in reader.lines() {
        let line = line?;
        if line.is_empty() {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        // group lat lon name street city region postcode website tel category
        if f.len() != 11 {
            skipped += 1;
            continue;
        }
        let (group, lat, lon) = match (
            f[0].parse::<u8>(),
            f[1].parse::<f32>(),
            f[2].parse::<f32>(),
        ) {
            (Ok(g), Ok(la), Ok(lo)) if g < 8 && la.is_finite() && lo.is_finite() => (g, la, lo),
            _ => {
                skipped += 1;
                continue;
            }
        };
        let state = f[6];
        if state.len() != 2 || !state.bytes().all(|b| b.is_ascii_uppercase()) {
            skipped += 1;
            continue;
        }
        group_counts[group as usize] += 1;
        by_state.entry(state.to_string()).or_default().push(Place {
            lat,
            lon,
            group,
            flags: 0,
            name: f[3].to_string(),
            street: f[4].to_string(),
            city: f[5].to_string(),
            website: f[8].to_string(),
            tel: f[9].to_string(),
            postcode: parse_zip(f[7]),
        });
    }

    fs::create_dir_all(out_dir)?;
    let mut index_entries = Vec::new();
    let mut total_records = 0u64;
    let mut total_bytes = 0u64;
    let mut largest = (String::new(), 0u64);
    let mut smallest = (String::new(), u64::MAX);
    for (state, places) in &by_state {
        let bytes = to_bytes(places);
        let path = out_dir.join(format!("{state}.fps"));
        let mut fh = fs::File::create(&path)?;
        fh.write_all(&bytes)?;
        fh.flush()?;
        let n = places.len() as u64;
        let b = bytes.len() as u64;
        total_records += n;
        total_bytes += b;
        if b > largest.1 {
            largest = (state.clone(), b);
        }
        if b < smallest.1 {
            smallest = (state.clone(), b);
        }
        index_entries.push(format!(
            "    \"{}\": {{ \"records\": {}, \"bytes\": {} }}",
            json_escape(state),
            n,
            b
        ));
    }

    let index = format!(
        "{{\n  \"format\": \"FPS1\",\n  \"version\": {},\n  \"states\": {{\n{}\n  }},\n  \
         \"total_records\": {},\n  \"total_bytes\": {}\n}}\n",
        FPS_VERSION,
        index_entries.join(",\n"),
        total_records,
        total_bytes
    );
    fs::write(out_dir.join("index.json"), index)?;

    println!("wrote {} state shards -> {}", by_state.len(), out_dir.display());
    println!("  records: {total_records}   bytes: {total_bytes}   skipped lines: {skipped}");
    const GROUPS: [&str; 8] = [
        "fuel", "food", "stores", "hotel", "medical", "tourist", "transit", "rest/truckstop",
    ];
    for (g, name) in GROUPS.iter().enumerate() {
        println!("  group {g} ({name}): {}", group_counts[g]);
    }
    println!(
        "  largest shard: {} ({} bytes)   smallest: {} ({} bytes)",
        largest.0, largest.1, smallest.0, smallest.1
    );
    Ok(())
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: places-shard <fsq_places_us.tsv> <out dir>");
        std::process::exit(2);
    }
    if let Err(e) = run(Path::new(&args[1]), Path::new(&args[2])) {
        eprintln!("places-shard: {e}");
        std::process::exit(1);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Deterministic tiny LCG so tests never touch a RNG crate or the clock.
    struct Lcg(u64);
    impl Lcg {
        fn next(&mut self) -> u64 {
            self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            self.0 >> 33
        }
        fn f32_in(&mut self, lo: f32, hi: f32) -> f32 {
            lo + (self.next() % 10_000) as f32 / 10_000.0 * (hi - lo)
        }
    }

    fn synthetic(n: usize) -> Vec<Place> {
        let mut r = Lcg(0x5eed);
        (0..n)
            .map(|i| Place {
                lat: r.f32_in(42.4, 47.3),
                lon: r.f32_in(-92.9, -86.2),
                group: (i % 8) as u8,
                flags: 0,
                name: format!("Place {i} \u{00e9}\u{6771}"),
                street: format!("{i} Main St"),
                city: "Madison".to_string(),
                website: if i % 3 == 0 { String::new() } else { format!("https://x{i}.example") },
                tel: format!("(608) 555-{i:04}"),
                postcode: if i % 5 == 0 { 0 } else { 53000 + (i as u32 % 999) },
            })
            .collect()
    }

    #[test]
    fn round_trip_preserves_every_field() {
        let places = synthetic(500);
        let shard = from_bytes(&to_bytes(&places)).expect("decode");
        assert_eq!(shard.places.len(), places.len());
        // Same multiset: sort both the same way and compare.
        let mut a = places.clone();
        a.sort_by(|x, y| {
            cell_key(x.lat, x.lon)
                .cmp(&cell_key(y.lat, y.lon))
                .then_with(|| x.name.cmp(&y.name))
                .then_with(|| x.lon.total_cmp(&y.lon))
                .then_with(|| x.lat.total_cmp(&y.lat))
        });
        assert_eq!(shard.places, a);
        // Records must arrive cell-sorted so grid runs are contiguous.
        let keys: Vec<i64> = shard.places.iter().map(|p| cell_key(p.lat, p.lon)).collect();
        assert!(keys.windows(2).all(|w| w[0] <= w[1]));
    }

    #[test]
    fn grid_lookup_matches_brute_force() {
        let places = synthetic(2000);
        let shard = from_bytes(&to_bytes(&places)).expect("decode");
        let mut r = Lcg(0xfeed);
        let mut hits = 0;
        for _ in 0..300 {
            let (lat, lon) = (r.f32_in(42.4, 47.3), r.f32_in(-92.9, -86.2));
            let key = cell_key(lat, lon);
            let mut expect: Vec<&Place> = places
                .iter()
                .filter(|p| cell_key(p.lat, p.lon) == key)
                .collect();
            expect.sort_by(|x, y| x.name.cmp(&y.name).then_with(|| x.lon.total_cmp(&y.lon)));
            let got = shard.in_cell(lat, lon);
            hits += got.len();
            assert_eq!(got.len(), expect.len());
            for (g, e) in got.iter().zip(&expect) {
                assert_eq!(&g, e);
            }
        }
        assert!(hits > 0, "test region must actually hit occupied cells");
        // A cell far outside the synthetic bounding box is empty, not a panic.
        assert!(shard.in_cell(-33.9, 151.2).is_empty());
    }

    #[test]
    fn hash_rejects_corruption() {
        let bytes = to_bytes(&synthetic(50));
        assert!(from_bytes(&bytes).is_ok());
        // Flip one byte in the record section.
        let mut bad_body = bytes.clone();
        bad_body[FPS_HEADER_LEN + 9] ^= 0x40;
        assert!(from_bytes(&bad_body).is_err());
        // Flip one byte in the grid index.
        let mut bad_grid = bytes.clone();
        let n = bad_grid.len();
        bad_grid[n - 3] ^= 0x01;
        assert!(from_bytes(&bad_grid).is_err());
        // Wrong magic and wrong version are refused outright.
        let mut bad_magic = bytes.clone();
        bad_magic[0] = b'X';
        assert!(from_bytes(&bad_magic).is_err());
        let mut bad_version = bytes;
        bad_version[4] = 9;
        assert!(from_bytes(&bad_version).is_err());
    }

    #[test]
    fn truncation_never_panics_and_always_errors() {
        let bytes = to_bytes(&synthetic(40));
        // Every truncation length must be a clean error (header, mid-record,
        // mid-length-prefix, mid-grid) — never a panic, never an Ok.
        for cut in 0..bytes.len() - 1 {
            assert!(from_bytes(&bytes[..cut]).is_err(), "cut at {cut} must fail");
        }
        // A length prefix pointing past the end of the record section is
        // caught even when the hash is recomputed to match.
        let mut forged = bytes.clone();
        let name_len_at = FPS_HEADER_LEN + 10; // first record's name length
        forged[name_len_at] = 0xff;
        forged[name_len_at + 1] = 0xff;
        let grid_off = u64::from_le_bytes(forged[12..20].try_into().unwrap()) as usize;
        let _ = grid_off;
        let h = fnv1a64(&forged[FPS_HEADER_LEN..]);
        forged[20..28].copy_from_slice(&h.to_le_bytes());
        assert!(from_bytes(&forged).is_err());
    }

    #[test]
    fn oversized_fields_are_clipped_on_utf8_boundaries() {
        let mut p = synthetic(1);
        p[0].name = "\u{00e9}".repeat(600); // 1200 bytes of 2-byte chars
        let shard = from_bytes(&to_bytes(&p)).expect("decode");
        assert!(shard.places[0].name.len() <= MAX_FIELD_BYTES);
        assert!(shard.places[0].name.chars().all(|c| c == '\u{00e9}'));
    }

    #[test]
    fn zip_parse_is_defensive() {
        assert_eq!(parse_zip("53534"), 53534);
        assert_eq!(parse_zip("53534-1234"), 53534);
        assert_eq!(parse_zip(""), 0);
        assert_eq!(parse_zip("ABC12"), 0);
        assert_eq!(parse_zip("1234"), 0);
    }
}
