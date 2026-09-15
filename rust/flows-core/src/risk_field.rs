// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The ZIP-level risk field the app renders: the FRB1 bundle reader, the
//! nearest-centroid lookup through a 0.2° grid, the viewport selection and
//! the week-correct harmonic rescore — `RiskFieldService.swift` at commit
//! a007de0, function by function.
//!
//! | here | Swift |
//! |---|---|
//! | [`RiskField::parse_frb1`] | `parseFRB1` |
//! | [`RiskField::from_columns`] | the JSON path's entry building, then `load()` |
//! | [`RiskField::nearest`] | `nearestEntry(to:)` behind `scoreRow(at:)` and `summary(at:)` |
//! | [`RiskField::select`] | `selectZips` behind `zips(in:family:limit:)` |
//! | [`RiskField::harmonic_rescore`] | `harmonicRescore` |
//! | [`cell`], [`cell_key`] | `cell`, `cellKey`, `buildGrid` |
//!
//! # Fidelity
//!
//! Pinned to the original by
//! `flows-bridge/tests/fixtures/swift_risk_field_oracle.tsv`. The lookup's
//! longitude window widens with latitude exactly as the Swift's does, ties
//! fall to the first candidate met in the same cell order, the viewport
//! selection sorts with Swift's own algorithm ([`crate::learning::swift_sort_by`])
//! so equal and NaN scores land where they did, and corrupt shards are
//! refused, never repaired.
//!
//! Where the Swift trapped — a coordinate that is not a number reaching
//! `Int`, an index sum that overflows — the port answers `None` or leaves the
//! entry out, and says so at each site.
//!
//! Nothing here performs I/O: the bytes and the columns are handed in, the
//! field holds them, and every query is a pure read.

use crate::climate::{HarmonicTable, WeekTrig};
use crate::fcmp::{smax, swift_int};
use crate::fmath;
use crate::learning::swift_sort_by;
use crate::swift_text;
use std::collections::BTreeMap;
use std::f64::consts::PI;

/// Grid cells per degree (0.2° cells).
pub const CELLS_PER_DEGREE: f64 = 5.0;
/// Stride between grid rows in a cell key.
pub const CELL_KEY_STRIDE: i64 = 100_000;
/// The field's reach: a centroid farther than this (degrees, longitude
/// cosine-scaled) answers nothing — about 30 km.
pub const REACH_DEGREES: f64 = 0.27;
/// Cell rows searched either side of the query's.
pub const ROW_WINDOW: i64 = 2;
/// The smallest and largest longitude half-window, in cells.
pub const COLUMN_WINDOW_MIN: i64 = 2;
/// See [`COLUMN_WINDOW_MIN`].
pub const COLUMN_WINDOW_MAX: i64 = 6;
/// The cosine floor that keeps a near-pole query's window finite.
pub const COSINE_FLOOR: f64 = 0.15;
/// The FRB1 header length in bytes.
pub const FRB1_HEADER_LEN: usize = 28;

/// A 0.2° cell index along one axis: `Int((degrees * 5).rounded(.down))`.
/// `None` where the Swift trapped (a coordinate that is not a number).
#[must_use]
pub fn cell(degrees: f64) -> Option<i64> {
    swift_int((degrees * CELLS_PER_DEGREE).floor())
}

/// `cellKey(y, x)`: `y &* 100_000 &+ x`, wrapping as the Swift's did.
#[must_use]
pub fn cell_key(y: i64, x: i64) -> i64 {
    y.wrapping_mul(CELL_KEY_STRIDE).wrapping_add(x)
}

/// FNV-1a 64 over bytes.
fn fnv1a64(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325_u64, |h, &b| {
        (h ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

/// One ZIP's row of the field.
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    /// The five-character code.
    pub zip: String,
    /// Centroid latitude, degrees.
    pub lat: f64,
    /// Centroid longitude, degrees.
    pub lon: f64,
    /// Family scores, aligned with the field's families (the JSON path may
    /// carry a different count; the readers check).
    pub scores: Vec<f64>,
    /// The hazard summary text, when the bundle carries one.
    pub summary: Option<String>,
    /// The simplified polygon as (latitude, longitude) pairs, when the entry
    /// carries one with at least three points; only these entries are drawn.
    pub ring: Option<Vec<(f64, f64)>>,
}

/// The loaded field.
#[derive(Clone, Debug)]
pub struct RiskField {
    generated: String,
    families: Vec<String>,
    /// `Dictionary(uniqueKeysWithValues:)` in the Swift: a duplicated family
    /// name trapped there; here the first index stands.
    family_index: BTreeMap<String, usize>,
    entries: Vec<Entry>,
    /// The 0.2° cell → entry indices, in entry order.
    grid: BTreeMap<i64, Vec<usize>>,
}

/// A little-endian reader with the Swift parser's bounds discipline.
struct Reader<'a> {
    data: &'a [u8],
    off: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let end = self.off.checked_add(n)?;
        if end > self.data.len() {
            return None;
        }
        let out = &self.data[self.off..end];
        self.off = end;
        Some(out)
    }
    fn u8(&mut self) -> Option<u8> {
        self.take(1).map(|b| b[0])
    }
    fn u16(&mut self) -> Option<u16> {
        self.take(2).map(|b| u16::from_le_bytes([b[0], b[1]]))
    }
    /// `String(decoding:as: UTF8.self)`: invalid sequences become U+FFFD.
    fn text(&mut self, n: usize) -> Option<String> {
        self.take(n)
            .map(|b| String::from_utf8_lossy(b).into_owned())
    }
}

fn u32_at(data: &[u8], at: usize) -> Option<u32> {
    data.get(at..at + 4)
        .and_then(|b| b.try_into().ok())
        .map(u32::from_le_bytes)
}
fn u64_at(data: &[u8], at: usize) -> Option<u64> {
    data.get(at..at + 8)
        .and_then(|b| b.try_into().ok())
        .map(u64::from_le_bytes)
}

impl RiskField {
    /// `parseFRB1`: the binary risk bundle `bundle-frb.rs` writes — a 28-byte
    /// header (magic, version 1, family and ZIP counts, the generated
    /// stamp's length, FNV-1a-64 over the payload), then the stamp,
    /// length-prefixed family names, five-byte ZIP codes, centroids as
    /// (lon, lat) doubles, row-major scores, length-prefixed summaries (0 =
    /// none) and rings (fewer than three points = none). Every section is
    /// bounds-checked, the hash must match, and nothing may trail: a corrupt
    /// shard is `None`, never repaired.
    ///
    /// Deterministic; allocates the field; panics: none.
    #[must_use]
    pub fn parse_frb1(data: &[u8]) -> Option<RiskField> {
        if data.len() <= FRB1_HEADER_LEN || &data[..4] != b"FRB1" {
            return None;
        }
        if u32_at(data, 4)? != 1 {
            return None;
        }
        let n_fams = u32_at(data, 8)? as usize;
        let n_zips = u32_at(data, 12)? as usize;
        let gen_len = u32_at(data, 16)? as usize;
        let stored_hash = u64_at(data, 20)?;
        if n_fams == 0 {
            return None;
        }
        if fnv1a64(&data[FRB1_HEADER_LEN..]) != stored_hash {
            return None;
        }
        let mut r = Reader {
            data,
            off: FRB1_HEADER_LEN,
        };
        let generated = r.text(gen_len)?;
        let mut families = Vec::with_capacity(n_fams);
        for _ in 0..n_fams {
            let len = usize::from(r.u8()?);
            families.push(r.text(len)?);
        }
        let zip_bytes = r.take(n_zips.checked_mul(5)?)?;
        let zips: Vec<String> = zip_bytes
            .chunks(5)
            .map(|c| String::from_utf8_lossy(c).into_owned())
            .collect();
        let centroids = r.take(n_zips.checked_mul(16)?)?;
        let scores = r.take(n_zips.checked_mul(n_fams)?.checked_mul(8)?)?;
        let mut summaries = Vec::with_capacity(n_zips);
        for _ in 0..n_zips {
            let len = usize::from(r.u16()?);
            let text = r.text(len)?;
            summaries.push((len > 0).then_some(text));
        }
        let mut rings = Vec::with_capacity(n_zips);
        for _ in 0..n_zips {
            let npts = usize::from(r.u16()?);
            let points = r.take(npts.checked_mul(16)?)?;
            rings.push((npts >= 3).then(|| {
                points
                    .chunks(16)
                    .map(|p| {
                        let lon = f64::from_le_bytes(p[..8].try_into().unwrap_or([0; 8]));
                        let lat = f64::from_le_bytes(p[8..].try_into().unwrap_or([0; 8]));
                        (lat, lon)
                    })
                    .collect::<Vec<_>>()
            }));
        }
        if r.off != data.len() {
            return None;
        }
        let f64_at = |bytes: &[u8], at: usize| {
            f64::from_le_bytes(bytes[at..at + 8].try_into().unwrap_or([0; 8]))
        };
        let entries: Vec<Entry> = (0..n_zips)
            .map(|i| Entry {
                zip: zips[i].clone(),
                lat: f64_at(centroids, i * 16 + 8),
                lon: f64_at(centroids, i * 16),
                scores: (0..n_fams)
                    .map(|f| f64_at(scores, (i * n_fams + f) * 8))
                    .collect(),
                summary: summaries[i].clone(),
                ring: rings[i].clone(),
            })
            .collect();
        Some(RiskField::from_entries(generated, families, entries))
    }

    /// The field from entries the caller has already read (the JSON path):
    /// the family index and the grid are built here, as `load()` built them.
    ///
    /// Deterministic; allocates the field; panics: none.
    #[must_use]
    pub fn from_entries(
        generated: String,
        families: Vec<String>,
        entries: Vec<Entry>,
    ) -> RiskField {
        let mut family_index = BTreeMap::new();
        for (i, name) in families.iter().enumerate() {
            family_index.entry(name.clone()).or_insert(i);
        }
        let grid = Self::build_grid(&entries);
        RiskField {
            generated,
            families,
            family_index,
            entries,
            grid,
        }
    }

    /// `buildGrid`: the 0.2° cell → entry-index map, indices in entry order.
    /// An entry whose centroid cannot be placed (the Swift trapped) is left
    /// out of the grid and is never found.
    fn build_grid(entries: &[Entry]) -> BTreeMap<i64, Vec<usize>> {
        let mut grid: BTreeMap<i64, Vec<usize>> = BTreeMap::new();
        for (i, e) in entries.iter().enumerate() {
            if let (Some(cy), Some(cx)) = (cell(e.lat), cell(e.lon)) {
                grid.entry(cell_key(cy, cx)).or_default().push(i);
            }
        }
        grid
    }

    /// The bundle's generation stamp.
    #[must_use]
    pub fn generated(&self) -> &str {
        &self.generated
    }

    /// The family names, in bundle order.
    #[must_use]
    pub fn families(&self) -> &[String] {
        &self.families
    }

    /// `familyIndex(_:)`: the position of a family name.
    #[must_use]
    pub fn family_index(&self, family: &str) -> Option<usize> {
        self.family_index.get(family).copied()
    }

    /// The entries, in bundle order.
    #[must_use]
    pub fn entries(&self) -> &[Entry] {
        &self.entries
    }

    /// `nearestEntry(to:)`: the entry whose centroid is nearest the query in
    /// cosine-scaled degrees, searched over ±2 cell rows and a longitude
    /// window that widens with latitude (`0.27 / max(cos φ, 0.15) / 0.2`
    /// cells, rounded up, kept to 2…6), within [`REACH_DEGREES`]. Ties fall
    /// to the first candidate met, cells row by row and column by column,
    /// each cell in entry order. `None` beyond the reach, and where the Swift
    /// trapped: a query that cannot be placed, or a cell index that
    /// overflows.
    ///
    /// Deterministic (platform libm `cos`); panics: none.
    #[must_use]
    pub fn nearest(&self, lat: f64, lon: f64) -> Option<usize> {
        let cy = cell(lat)?;
        let cx = cell(lon)?;
        let cos_lat = fmath::cos(lat * PI / 180.0);
        let columns = swift_int(
            (REACH_DEGREES / smax(cos_lat, COSINE_FLOOR) / (1.0 / CELLS_PER_DEGREE)).ceil(),
        )?;
        let dx_max = columns.clamp(COLUMN_WINDOW_MIN, COLUMN_WINDOW_MAX);
        let mut best: Option<(usize, f64)> = None;
        for dy in -ROW_WINDOW..=ROW_WINDOW {
            for dx in -dx_max..=dx_max {
                let key = cell_key(cy.checked_add(dy)?, cx.checked_add(dx)?);
                for &idx in self.grid.get(&key).map_or(&[][..], Vec::as_slice) {
                    let e = &self.entries[idx];
                    let d_lat = e.lat - lat;
                    let d_lon = (e.lon - lon) * cos_lat;
                    let d2 = d_lat * d_lat + d_lon * d_lon;
                    if best.is_none_or(|(_, bd)| d2 < bd) {
                        best = Some((idx, d2));
                    }
                }
            }
        }
        let (idx, d2) = best?;
        (d2 < REACH_DEGREES * REACH_DEGREES).then_some(idx)
    }

    /// `selectZips`: the entries with a ring whose centroid lies inside the
    /// box (inclusive), worst score first for family `fi` (a missing score
    /// reads 0), the first `limit` of them. Candidates come from the cells
    /// the box overlaps when that walk is finite, positive, no larger than
    /// the entry count and within ±10⁷ cells; otherwise from every entry.
    /// Candidate indices are ascending before Swift's stable sort, so equal
    /// scores keep bundle order. A negative family index reads 0 and a
    /// negative limit is empty (both trapped the Swift).
    ///
    /// Deterministic; allocates the answer; panics: none.
    #[must_use]
    pub fn select(
        &self,
        lat_min: f64,
        lat_max: f64,
        lon_min: f64,
        lon_max: f64,
        fi: i64,
        limit: i64,
    ) -> Vec<usize> {
        let cy_min = (lat_min * CELLS_PER_DEGREE).floor();
        let cy_max = (lat_max * CELLS_PER_DEGREE).floor();
        let cx_min = (lon_min * CELLS_PER_DEGREE).floor();
        let cx_max = (lon_max * CELLS_PER_DEGREE).floor();
        let cell_count = (cy_max - cy_min + 1.0) * (cx_max - cx_min + 1.0);
        let walkable = cell_count.is_finite()
            && cell_count > 0.0
            && cell_count <= self.entries.len() as f64
            && cy_min >= -1e7
            && cy_max <= 1e7
            && cx_min >= -1e7
            && cx_max <= 1e7;
        let mut candidates: Vec<usize> = if walkable {
            let mut out = Vec::new();
            let (cy_lo, cy_hi) = (cy_min as i64, cy_max as i64);
            let (cx_lo, cx_hi) = (cx_min as i64, cx_max as i64);
            let mut cy = cy_lo;
            while cy <= cy_hi {
                let mut cx = cx_lo;
                while cx <= cx_hi {
                    if let Some(ids) = self.grid.get(&cell_key(cy, cx)) {
                        out.extend_from_slice(ids);
                    }
                    cx += 1;
                }
                cy += 1;
            }
            out.sort_unstable();
            out
        } else {
            (0..self.entries.len()).collect()
        };
        candidates.retain(|&i| {
            let e = &self.entries[i];
            e.lat >= lat_min
                && e.lat <= lat_max
                && e.lon >= lon_min
                && e.lon <= lon_max
                && e.ring.is_some()
        });
        let score = |i: usize| -> f64 {
            usize::try_from(fi)
                .ok()
                .and_then(|f| self.entries[i].scores.get(f))
                .copied()
                .unwrap_or(0.0)
        };
        swift_sort_by(&mut candidates, |a, b| score(a) > score(b));
        candidates.truncate(usize::try_from(limit).unwrap_or(0));
        candidates
    }

    /// `harmonicRescore`: every ring-less (national) entry whose ZIP the
    /// harmonic table knows gets its covered families rebuilt for the week —
    /// `fam_idx` pairs a bundle family index with the table's — and the
    /// count of rebuilt entries is answered. Ringed entries carry live
    /// engine scores and are never touched. A score the table cannot give
    /// (an index it does not hold) leaves the old value.
    ///
    /// Deterministic; panics: none.
    pub fn harmonic_rescore(
        &mut self,
        table: &HarmonicTable,
        trig: &WeekTrig,
        fam_idx: &[(usize, usize)],
    ) -> usize {
        let zip_row = table.zip_index_map();
        let mut rebuilt = 0;
        for e in self.entries.iter_mut().filter(|e| e.ring.is_none()) {
            let Some(&zi) = zip_row.get(&e.zip) else {
                continue;
            };
            let width = e.scores.len();
            for &(bi, hi) in fam_idx.iter().filter(|(bi, _)| *bi < width) {
                if let (Ok(zi), Ok(hi)) = (i64::try_from(zi), i64::try_from(hi)) {
                    if let Some(s) = table.score(zi, hi, trig) {
                        e.scores[bi] = s;
                    }
                }
            }
            rebuilt += 1;
        }
        rebuilt
    }

    /// The `(bundle, harmonic)` family index pairs `load()` built: each
    /// bundle family that the table also names, by Swift's `==`.
    #[must_use]
    pub fn family_pairs(&self, table: &HarmonicTable) -> Vec<(usize, usize)> {
        self.families
            .iter()
            .enumerate()
            .filter_map(|(i, name)| {
                table
                    .families()
                    .iter()
                    .position(|f| swift_text::eq(f, name))
                    .map(|h| (i, h))
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn le32(v: u32, out: &mut Vec<u8>) {
        out.extend_from_slice(&v.to_le_bytes());
    }

    /// The two-family, two-ZIP shard the Swift test hand-assembles.
    fn shard() -> Vec<u8> {
        let mut p = Vec::new();
        let generated = b"2026-07-04T11:39:45Z";
        p.extend_from_slice(generated);
        for fam in ["wind", "fire"] {
            p.push(fam.len() as u8);
            p.extend_from_slice(fam.as_bytes());
        }
        p.extend_from_slice(b"0100199999");
        for v in [-72.6258_f64, 42.0624, -100.5, 40.25] {
            p.extend_from_slice(&v.to_le_bytes());
        }
        for v in [0.125_f64, 0.5, 0.0, 0.043] {
            p.extend_from_slice(&v.to_le_bytes());
        }
        p.extend_from_slice(&5u16.to_le_bytes());
        p.extend_from_slice(b"windy");
        p.extend_from_slice(&0u16.to_le_bytes());
        p.extend_from_slice(&0u16.to_le_bytes());
        p.extend_from_slice(&3u16.to_le_bytes());
        for (lon, lat) in [(-100.0, 40.0), (-100.1, 40.1), (-100.2, 40.0)] {
            p.extend_from_slice(&f64::to_le_bytes(lon));
            p.extend_from_slice(&f64::to_le_bytes(lat));
        }
        let mut out = b"FRB1".to_vec();
        le32(1, &mut out);
        le32(2, &mut out);
        le32(2, &mut out);
        le32(generated.len() as u32, &mut out);
        out.extend_from_slice(&fnv1a64(&p).to_le_bytes());
        out.extend_from_slice(&p);
        out
    }

    #[test]
    fn the_shard_round_trips_and_corruption_is_refused() {
        let s = shard();
        let field = RiskField::parse_frb1(&s).expect("valid shard");
        assert_eq!(field.generated(), "2026-07-04T11:39:45Z");
        assert_eq!(field.families(), ["wind", "fire"]);
        let e = field.entries();
        assert_eq!(e.len(), 2);
        assert_eq!(e[0].zip, "01001");
        assert_eq!((e[0].lat, e[0].lon), (42.0624, -72.6258));
        assert_eq!(e[0].scores, [0.125, 0.5]);
        assert_eq!(e[0].summary.as_deref(), Some("windy"));
        assert!(e[0].ring.is_none());
        assert_eq!(e[1].scores, [0.0, 0.043]);
        assert!(e[1].summary.is_none());
        assert_eq!(e[1].ring.as_ref().map(Vec::len), Some(3));
        assert_eq!(e[1].ring.as_ref().map(|r| r[1]), Some((40.1, -100.1)));
        assert_eq!(field.family_index("fire"), Some(1));
        assert_eq!(field.family_index("flood"), None);
        let mut corrupt = s.clone();
        corrupt[40] ^= 0xFF;
        assert!(RiskField::parse_frb1(&corrupt).is_none());
        assert!(RiskField::parse_frb1(&s[..s.len() - 5]).is_none());
        let mut magic = s.clone();
        magic[..4].copy_from_slice(b"XXXX");
        assert!(RiskField::parse_frb1(&magic).is_none());
        let mut trailing = s;
        trailing.push(0);
        assert!(RiskField::parse_frb1(&trailing).is_none());
    }

    fn entry(zip: &str, lat: f64, lon: f64, score: f64, ring: bool) -> Entry {
        Entry {
            zip: zip.to_string(),
            lat,
            lon,
            scores: vec![score],
            summary: None,
            ring: ring.then(|| vec![(lat, lon), (lat, lon), (lat, lon)]),
        }
    }

    #[test]
    fn nearest_stays_within_reach_and_widens_north() {
        let field = RiskField::from_entries(
            String::new(),
            vec!["wind".into()],
            vec![
                entry("a", 43.0, -89.4, 0.1, true),
                entry("b", 43.1, -89.4, 0.2, false),
                entry("c", 70.0, -150.0, 0.3, false),
            ],
        );
        assert_eq!(field.nearest(43.01, -89.4), Some(0));
        assert_eq!(field.nearest(43.09, -89.4), Some(1));
        assert_eq!(field.nearest(44.0, -89.4), None);
        // At 70°N a 0.6° longitude offset is within reach once cosine-scaled.
        assert_eq!(field.nearest(70.0, -150.6), Some(2));
        assert_eq!(field.nearest(f64::NAN, -89.4), None);
    }

    #[test]
    fn select_keeps_ringed_entries_in_the_box_worst_first_in_bundle_order() {
        let field = RiskField::from_entries(
            String::new(),
            vec!["wind".into()],
            vec![
                entry("a", 43.0, -89.4, 0.5, true),
                entry("b", 43.1, -89.3, 0.9, true),
                entry("c", 43.2, -89.2, 0.9, true),
                entry("d", 43.3, -89.1, 1.0, false),
                entry("e", 50.0, -89.0, 1.0, true),
            ],
        );
        assert_eq!(field.select(42.0, 44.0, -90.0, -89.0, 0, 10), vec![1, 2, 0]);
        assert_eq!(field.select(42.0, 44.0, -90.0, -89.0, 0, 2), vec![1, 2]);
        assert_eq!(
            field.select(-90.0, 90.0, -180.0, 180.0, 0, 10),
            vec![4, 1, 2, 0]
        );
        assert!(field.select(80.0, 85.0, 100.0, 120.0, 0, 10).is_empty());
        assert_eq!(field.select(42.0, 44.0, -90.0, -89.0, 7, 10), vec![0, 1, 2]);
        assert!(field.select(42.0, 44.0, -90.0, -89.0, 0, -1).is_empty());
    }
}
