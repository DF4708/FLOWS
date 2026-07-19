// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! FLOWS 20-year historical hazard baseline — pure std, ZERO external crates,
//! the same discipline as `flows-core` / `flows-train` / `national-bundle`.
//!
//! Replaces the hand-encoded seasonal climatology with REAL hazard frequencies
//! from NOAA NCEI Storm Events (details CSVs, 2005-2024): per ZCTA x
//! week-of-year x hazard family. Events with a begin lat/lon snap to the
//! nearest ZCTA centroid (0.2-degree grid index over the Census gazetteer);
//! county-coded events (CZ_TYPE == "C") spread over that county's ZCTAs via
//! the Census ZCTA<->county relationship file with weight 1/n (weights sum to
//! 1 per event). Zone-coded events (CZ_TYPE == "Z", ~36% of all records —
//! nearly ALL winter/heat/cold/wind zone products) resolve through the NWS
//! zone<->county correlation file (data/reference/nws_zone_county.dbx) to the
//! zone's counties, falling back to matching CZ_NAME against the state's
//! county names (exact, then whole-word containment); the still-unresolved
//! remainder is counted and reported.
//!
//! SCORE FORMULA (documented per the score discipline in national-bundle.rs):
//!   raw cell value  v = sum of event weights in (zip, week, family) over the
//!                       20 years (county-spread events contribute 1/n each;
//!                       severe-magnitude events contribute 1.5, see below)
//!   per family      p95 = 95th percentile (nearest-rank) of NONZERO cells
//!   score(v)        = min(0.6, 0.6 * ln(1+v) / ln(1+p95))   for v > 0
//!   floor           scores < 0.05 are treated as noise and emitted as 0
//! A climatological/historical PRIOR may never reach the 0.699 yellow cut:
//! every score is hard-capped at 0.6 (< 0.699), the exact cap discipline of
//! national-bundle.rs. The p95 normalizer means the top ~5% of active cells
//! for a family saturate at the cap and everything else scales log-linearly.
//!
//! MAGNITUDE (where present): a modest severity boost only — hail >= 2.0 in
//! or measured/estimated wind >= 65 kt count 1.5x instead of 1x. Magnitude
//! never creates a mapping, it only weights one.
//!
//! OUTPUTS (all under the repo root):
//!   A. data/runtime_cache/app_risk_bundle.json rebuilt: any entry carrying a
//!      "p" ring is preserved BYTE-FOR-BYTE via the raw-slice scanner from
//!      national-bundle.rs. (As of the one-system merge in 5ed9cc0 the bundle
//!      has ZERO ring-carrying entries — the R "Wisconsin" engine was retired
//!      and the field regenerated with no specials — so this preservation is
//!      a no-op safety net today; it still protects a ring entry if one is
//!      ever reintroduced.) Every other entry's "s"
//!      becomes max(existing climatology, history score at the CLI week). The
//!      previous bundle is backed up to app_risk_bundle.pre_history.json once
//!      (the backup is never overwritten on re-runs).
//!   B. data/runtime_cache/history_dense.bin    dense u8 table (layout below)
//!      data/runtime_cache/history_harmonic.bin 5xf32 Fourier table (below)
//!   C. data/runtime_cache/history_training_rows.csv rows in the exact format
//!      flows-train's read_csv expects: oLat,oLon,dLat,dLon,week,y,weight,cross
//!
//! BINARY LAYOUTS (all integers/floats little-endian):
//!   history_dense.bin:
//!     magic  "FLHD" | u32 version=1 | u32 n_zips | u32 n_weeks=52
//!     u32 n_families | per family: u8 name_len + name bytes
//!     zip index: n_zips * 5 ASCII bytes (sorted ascending)
//!     data: n_zips * 52 * n_families u8 = round(score * 255)   (score <= 0.6)
//!   history_harmonic.bin:
//!     magic  "FLHH" | u32 version=1 | u32 n_zips | u32 n_families
//!     per family: u8 name_len + name bytes
//!     zip index: n_zips * 5 ASCII bytes (sorted ascending)
//!     data: n_zips * n_families * 5 f32 = mean,a1,b1,a2,b2 where
//!       score(w) ~= clamp(mean + a1 cos t + b1 sin t + a2 cos 2t + b2 sin 2t,
//!                         0, 0.6),  t = 2*pi*w/52
//!     (DFT coefficients: a_k = (2/52) sum s_w cos(k t_w), b_k likewise sin)
//!
//! Usage: history-baseline <storm-events-dir> <current-week 0-51>
//! (no system clock inside the tool — scripts/build_history_baseline.sh
//! computes the week and passes it in, same convention as national-bundle)

use std::borrow::Cow;
use std::collections::{BTreeMap, HashMap};
use std::env;
use std::f64::consts::PI;
use std::fs;
use std::path::{Path, PathBuf};

const BUNDLE_REL: &str = "data/runtime_cache/app_risk_bundle.json";
const BACKUP_REL: &str = "data/runtime_cache/app_risk_bundle.pre_history.json";
const GAZ_REL: &str = "data/reference/2024_Gaz_zcta_national.txt";
const REL_REL: &str = "data/reference/tab20_zcta520_county20_natl.txt";
const ZONE_REL: &str = "data/reference/nws_zone_county.dbx";
const DENSE_REL: &str = "data/runtime_cache/history_dense.bin";
const HARM_REL: &str = "data/runtime_cache/history_harmonic.bin";
const ROWS_REL: &str = "data/runtime_cache/history_training_rows.csv";

// Score discipline: a historical prior may never reach the yellow cut.
const SCORE_MAX: f64 = 0.6; // hard cap, < 0.699
const SCORE_FLOOR: f64 = 0.05; // below this a signal is noise -> emit 0
const SUMMARY_MIN: f64 = 0.3; // name the top family only when it clears this

const N_WEEKS: usize = 52;
const GRID_DEG: f64 = 0.2; // gazetteer grid-index cell size

// The hazard families the 20-year history can speak to, in table order.
// (Bundle families with no event basis — environmental, radiation, seismic —
// are never touched by the merge.)
const FAMS: [&str; 8] = ["convective", "qpf_flood", "winter", "wind", "heat", "cold", "fire", "air"];
const F_CONV: usize = 0;
const F_QPF: usize = 1;
const F_WINTER: usize = 2;
const F_WIND: usize = 3;
const F_HEAT: usize = 4;
const F_COLD: usize = 5;
const F_FIRE: usize = 6;
const F_AIR: usize = 7;
const NF: usize = FAMS.len();

// ---------------------------------------------------------------- CSV reader

/// RFC-4180-ish record reader over one file's text. Handles quoted fields
/// containing commas AND newlines (Storm Events narratives have both) and ""
/// escapes. Yields (start, end, was_quoted) spans; `field()` materializes.
struct CsvRecords<'a> {
    text: &'a str,
    pos: usize,
}

impl<'a> CsvRecords<'a> {
    fn new(text: &'a str) -> Self {
        CsvRecords { text, pos: 0 }
    }

    /// Fill `spans` with the next record's field spans; false at EOF.
    fn next_record(&mut self, spans: &mut Vec<(usize, usize, bool)>) -> bool {
        spans.clear();
        let b = self.text.as_bytes();
        let n = b.len();
        let mut i = self.pos;
        if i >= n {
            return false;
        }
        loop {
            if b.get(i) == Some(&b'"') {
                // quoted field: scan to the closing quote, honoring "" escapes
                let start = i + 1;
                let mut j = start;
                while j < n {
                    if b[j] == b'"' {
                        if b.get(j + 1) == Some(&b'"') {
                            j += 2; // escaped quote, keep going
                        } else {
                            break; // closing quote
                        }
                    } else {
                        j += 1;
                    }
                }
                spans.push((start, j.min(n), true));
                i = (j + 1).min(n);
            } else {
                let start = i;
                while i < n && b[i] != b',' && b[i] != b'\n' && b[i] != b'\r' {
                    i += 1;
                }
                spans.push((start, i, false));
            }
            match b.get(i) {
                Some(&b',') => i += 1,
                Some(&b'\r') => {
                    i += 1;
                    if b.get(i) == Some(&b'\n') {
                        i += 1;
                    }
                    break;
                }
                Some(&b'\n') => {
                    i += 1;
                    break;
                }
                None => break,
                Some(_) => {
                    // stray bytes after a closing quote: skip to next delimiter
                    while i < n && b[i] != b',' && b[i] != b'\n' && b[i] != b'\r' {
                        i += 1;
                    }
                }
            }
        }
        self.pos = i;
        true
    }
}

/// Materialize a field: borrowed unless it contains "" escapes.
fn field<'a>(text: &'a str, span: (usize, usize, bool)) -> Cow<'a, str> {
    let raw = &text[span.0..span.1];
    if span.2 && raw.contains("\"\"") {
        Cow::Owned(raw.replace("\"\"", "\""))
    } else {
        Cow::Borrowed(raw)
    }
}

// ---------------------------------------------------------------- calendar

fn is_leap(y: u32) -> bool {
    (y.is_multiple_of(4) && !y.is_multiple_of(100)) || y.is_multiple_of(400)
}

/// Week-of-year 0..51 from yyyymm + day (week 51 absorbs days 358..366),
/// the same fixed 7-day-bucket convention the app's week feature uses.
fn week_of_year(yearmonth: u32, day: u32) -> Option<u32> {
    let (y, m) = (yearmonth / 100, yearmonth % 100);
    if !(1..=12).contains(&m) || day == 0 || day > 31 {
        return None;
    }
    const CUM: [u32; 12] = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
    let mut doy = CUM[(m - 1) as usize] + day;
    if m > 2 && is_leap(y) {
        doy += 1;
    }
    Some(((doy - 1) / 7).min(51))
}

// ---------------------------------------------------------------- gazetteer

#[derive(Debug, PartialEq)]
struct Zcta {
    zip: String,
    lat: f64,
    lon: f64,
}

/// Parse one tab-separated gazetteer data line given header column indices.
/// The last column (INTPTLONG) is space-padded — trim every field.
fn parse_gaz_line(line: &str, i_geoid: usize, i_lat: usize, i_lon: usize) -> Option<Zcta> {
    let cols: Vec<&str> = line.split('\t').collect();
    let geoid = cols.get(i_geoid)?.trim();
    if geoid.len() != 5 || !geoid.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let lat: f64 = cols.get(i_lat)?.trim().parse().ok()?;
    let lon: f64 = cols.get(i_lon)?.trim().parse().ok()?;
    Some(Zcta { zip: geoid.to_string(), lat, lon })
}

fn read_gazetteer(path: &Path) -> Result<Vec<Zcta>, String> {
    let text = fs::read_to_string(path)
        .map_err(|e| format!("cannot read gazetteer {}: {e}", path.display()))?;
    let mut lines = text.lines();
    let header = lines.next().ok_or("gazetteer is empty")?;
    let cols: Vec<&str> = header.split('\t').map(str::trim).collect();
    let idx = |name: &str| {
        cols.iter().position(|c| *c == name).ok_or_else(|| format!("gazetteer header missing {name}"))
    };
    let (i_geoid, i_lat, i_lon) = (idx("GEOID")?, idx("INTPTLAT")?, idx("INTPTLONG")?);
    let mut z: Vec<Zcta> = lines.filter_map(|l| parse_gaz_line(l, i_geoid, i_lat, i_lon)).collect();
    z.sort_by(|a, b| a.zip.cmp(&b.zip));
    z.dedup_by(|a, b| a.zip == b.zip);
    Ok(z)
}

/// 0.2-degree grid index over ZCTA centroids for nearest-centroid snapping.
struct ZipGrid {
    cells: HashMap<(i32, i32), Vec<u32>>,
}

impl ZipGrid {
    fn build(zctas: &[Zcta]) -> ZipGrid {
        let mut cells: HashMap<(i32, i32), Vec<u32>> = HashMap::new();
        for (i, z) in zctas.iter().enumerate() {
            cells.entry(Self::cell(z.lat, z.lon)).or_default().push(i as u32);
        }
        ZipGrid { cells }
    }

    fn cell(lat: f64, lon: f64) -> (i32, i32) {
        ((lat / GRID_DEG).floor() as i32, (lon / GRID_DEG).floor() as i32)
    }

    /// Nearest ZCTA centroid by equirectangular distance, searching outward
    /// ring by ring (plus one guard ring past the first hit). None only if
    /// nothing lives within `max_ring` cells (~ max_ring * 0.2 degrees).
    fn nearest(&self, zctas: &[Zcta], lat: f64, lon: f64, max_ring: i32) -> Option<u32> {
        let (cr, cc) = Self::cell(lat, lon);
        let coslat = lat.to_radians().cos().max(0.05);
        let mut best: Option<(f64, u32)> = None;
        let mut found_ring: Option<i32> = None;
        for r in 0..=max_ring {
            if let Some(fr) = found_ring {
                if r > fr + 1 {
                    break; // one guard ring past the first hit is enough
                }
            }
            for dr in -r..=r {
                for dc in -r..=r {
                    if dr.abs() != r && dc.abs() != r {
                        continue; // ring perimeter only
                    }
                    if let Some(v) = self.cells.get(&(cr + dr, cc + dc)) {
                        for &i in v {
                            let z = &zctas[i as usize];
                            let dlat = z.lat - lat;
                            let dlon = (z.lon - lon) * coslat;
                            let d2 = dlat * dlat + dlon * dlon;
                            if best.is_none_or(|(b, _)| d2 < b) {
                                best = Some((d2, i));
                            }
                        }
                        if found_ring.is_none() {
                            found_ring = Some(r);
                        }
                    }
                }
            }
        }
        best.map(|(_, i)| i)
    }
}

// ---------------------------------------------------------------- county rel

/// County lookup tables from the Census 2020 ZCTA<->county relationship file
/// (pipe-delimited, UTF-8 BOM on the header, rows with an empty ZCTA are
/// county area outside any ZCTA and are skipped).
struct Counties {
    /// county GEOID (5-digit) -> ZCTA indices
    zips: HashMap<String, Vec<u32>>,
    /// state FIPS (2-digit) -> [(normalized upper-case county name, GEOID)]
    names_by_state: HashMap<String, Vec<(String, String)>>,
}

/// "Baldwin County" -> "BALDWIN": upper-case, legal suffix stripped, so it can
/// be compared against NWS zone names.
fn normalize_county_name(name: &str) -> String {
    let n = name.trim().to_ascii_uppercase();
    for suf in
        [" CITY AND BOROUGH", " CENSUS AREA", " MUNICIPALITY", " COUNTY", " PARISH", " BOROUGH", " CITY"]
    {
        if let Some(stripped) = n.strip_suffix(suf) {
            return stripped.to_string();
        }
    }
    n
}

fn read_county_rel(path: &Path, zip_idx: &HashMap<String, u32>) -> Result<Counties, String> {
    let text =
        fs::read_to_string(path).map_err(|e| format!("cannot read rel file {}: {e}", path.display()))?;
    let text = text.strip_prefix('\u{feff}').unwrap_or(&text);
    let mut lines = text.lines();
    let header = lines.next().ok_or("rel file is empty")?;
    let cols: Vec<&str> = header.split('|').map(str::trim).collect();
    let idx = |name: &str| {
        cols.iter().position(|c| *c == name).ok_or_else(|| format!("rel header missing {name}"))
    };
    let (i_zcta, i_cty, i_name) =
        (idx("GEOID_ZCTA5_20")?, idx("GEOID_COUNTY_20")?, idx("NAMELSAD_COUNTY_20")?);
    let mut out =
        Counties { zips: HashMap::new(), names_by_state: HashMap::new() };
    for line in lines {
        let cols: Vec<&str> = line.split('|').collect();
        let (Some(z), Some(c)) = (cols.get(i_zcta).map(|s| s.trim()), cols.get(i_cty).map(|s| s.trim()))
        else {
            continue;
        };
        if c.len() == 5 {
            // record the county name once, ZCTA or not
            let names = out.names_by_state.entry(c[..2].to_string()).or_default();
            if !names.iter().any(|(_, g)| g == c) {
                if let Some(nm) = cols.get(i_name) {
                    names.push((normalize_county_name(nm), c.to_string()));
                }
            }
        }
        if z.len() != 5 || c.len() != 5 {
            continue; // empty-ZCTA rows: county land outside every ZCTA
        }
        if let Some(&i) = zip_idx.get(z) {
            let v = out.zips.entry(c.to_string()).or_default();
            if !v.contains(&i) {
                v.push(i);
            }
        }
    }
    Ok(out)
}

// ---------------------------------------------------------------- zones

/// State FIPS -> USPS abbreviation (static data, not a dependency), needed to
/// join Storm Events' numeric STATE_FIPS against the NWS correlation file.
const STATE_FIPS_ABBR: [(u32, &str); 57] = [
    (1, "AL"), (2, "AK"), (4, "AZ"), (5, "AR"), (6, "CA"), (8, "CO"), (9, "CT"),
    (10, "DE"), (11, "DC"), (12, "FL"), (13, "GA"), (15, "HI"), (16, "ID"),
    (17, "IL"), (18, "IN"), (19, "IA"), (20, "KS"), (21, "KY"), (22, "LA"),
    (23, "ME"), (24, "MD"), (25, "MA"), (26, "MI"), (27, "MN"), (28, "MS"),
    (29, "MO"), (30, "MT"), (31, "NE"), (32, "NV"), (33, "NH"), (34, "NJ"),
    (35, "NM"), (36, "NY"), (37, "NC"), (38, "ND"), (39, "OH"), (40, "OK"),
    (41, "OR"), (42, "PA"), (44, "RI"), (45, "SC"), (46, "SD"), (47, "TN"),
    (48, "TX"), (49, "UT"), (50, "VT"), (51, "VA"), (53, "WA"), (54, "WV"),
    (55, "WI"), (56, "WY"), (60, "AS"), (66, "GU"), (69, "MP"), (72, "PR"),
    (74, "UM"), (78, "VI"),
];

fn state_abbr(fips: u32) -> Option<&'static str> {
    STATE_FIPS_ABBR.iter().find(|(f, _)| *f == fips).map(|(_, a)| *a)
}

/// NWS zone<->county correlation file (pipe-delimited "bp" file):
///   STATE|ZONE|CWA|NAME|STATE_ZONE|COUNTY|FIPS|TIME_ZONE|FE_AREA|LAT|LON
/// One row per (zone, county) pair. Returns (state_abbr, 3-digit zone) ->
/// deduped ZCTA indices of every county the zone touches. Missing file is
/// non-fatal (zone events then rely on the name-match fallback).
fn read_zone_county(
    path: &Path,
    county_zips: &HashMap<String, Vec<u32>>,
) -> HashMap<(String, String), Vec<u32>> {
    let mut map: HashMap<(String, String), Vec<u32>> = HashMap::new();
    let Ok(text) = fs::read_to_string(path) else {
        return map;
    };
    for line in text.lines() {
        let cols: Vec<&str> = line.split('|').collect();
        if cols.len() < 7 {
            continue;
        }
        let (st, zone, fips) = (cols[0].trim(), cols[1].trim(), cols[6].trim());
        if st.len() != 2 || zone.is_empty() || fips.len() != 5 {
            continue;
        }
        if let Some(zips) = county_zips.get(fips) {
            let key = (st.to_string(), format!("{:0>3}", zone));
            let v = map.entry(key).or_default();
            for &z in zips {
                if !v.contains(&z) {
                    v.push(z);
                }
            }
        }
    }
    map
}

/// Whole-word containment: `needle` appears in `hay` bounded by non-alnum
/// (so "SOUTHEAST YUMA COUNTY" matches county "YUMA", but "PARKER VALLEY"
/// does not match county "PARK").
fn contains_word(hay: &str, needle: &str) -> bool {
    if needle.is_empty() {
        return false;
    }
    let h = hay.as_bytes();
    let mut start = 0;
    while let Some(pos) = hay[start..].find(needle) {
        let i = start + pos;
        let before_ok = i == 0 || !h[i - 1].is_ascii_alphanumeric();
        let after = i + needle.len();
        let after_ok = after >= h.len() || !h[after].is_ascii_alphanumeric();
        if before_ok && after_ok {
            return true;
        }
        start = i + 1;
    }
    false
}

/// Fallback zone resolution by name: exact county-name match first, else the
/// union of every county whose name appears whole-word in the zone name.
fn zones_by_name(
    state_fips2: &str,
    zone_name_upper: &str,
    counties: &Counties,
) -> Vec<u32> {
    let Some(names) = counties.names_by_state.get(state_fips2) else {
        return Vec::new();
    };
    if let Some((_, geoid)) = names.iter().find(|(n, _)| n == zone_name_upper) {
        return counties.zips.get(geoid).cloned().unwrap_or_default();
    }
    let mut out: Vec<u32> = Vec::new();
    for (n, geoid) in names {
        if contains_word(zone_name_upper, n) {
            if let Some(zips) = counties.zips.get(geoid) {
                for &z in zips {
                    if !out.contains(&z) {
                        out.push(z);
                    }
                }
            }
        }
    }
    out
}

// ---------------------------------------------------------------- families

/// EVENT_TYPE -> up to two families (tropical systems hit wind AND qpf_flood,
/// mirroring national-bundle's tropical mapping — the bundle has no tropical
/// family). Case-insensitive substring tests, most-specific first; "wind
/// chill" must resolve to cold before the generic "wind" test fires.
fn families_for(event_type: &str) -> Vec<usize> {
    let t = event_type.to_ascii_lowercase();
    let has = |s: &str| t.contains(s);
    if has("tornado") || has("thunderstorm wind") || has("hail") || has("lightning") || has("waterspout") {
        vec![F_CONV]
    } else if has("flood") || has("tsunami") || has("seiche") || has("heavy rain") {
        // flash flood / coastal flood / lakeshore flood all contain "flood";
        // Heavy Rain (24k events, previously unmapped) is flood-precursor
        // signal — the one defensible addition from the ingestion report.
        vec![F_QPF]
    } else if has("winter storm")
        || has("heavy snow")
        || has("ice storm")
        || has("blizzard")
        || has("winter weather")
        || has("lake-effect")
        || has("sleet")
        || has("freezing")
        || has("avalanche")
    {
        vec![F_WINTER]
    } else if has("hurricane") || has("tropical storm") || has("tropical depression") || has("storm surge") {
        vec![F_WIND, F_QPF]
    } else if has("excessive heat") || has("heat") {
        vec![F_HEAT]
    } else if has("extreme cold") || has("wind chill") || has("cold") || has("frost") {
        vec![F_COLD]
    } else if has("high wind") || has("strong wind") || has("wind") {
        vec![F_WIND]
    } else if has("wildfire") || has("dense smoke") {
        vec![F_FIRE]
    } else if has("drought") || has("dust") {
        vec![F_AIR]
    } else {
        vec![]
    }
}

/// Event weight: 1.0 baseline; MAGNITUDE (where present) gives a modest 1.5x
/// severity boost for big hail (>= 2 in) or damaging wind (>= 65 kt).
fn event_weight(event_type_lower: &str, magnitude: Option<f64>) -> f64 {
    match magnitude {
        Some(m) if event_type_lower.contains("hail") && m >= 2.0 => 1.5,
        Some(m) if event_type_lower.contains("wind") && m >= 65.0 => 1.5,
        _ => 1.0,
    }
}

// ---------------------------------------------------------------- history table

/// Dense per-(zip, week, family) accumulation and its score conversion.
struct History {
    /// zip-major: counts[(zip * 52 + week) * NF + fam], raw event weights
    counts: Vec<f32>,
    n_zips: usize,
}

impl History {
    fn new(n_zips: usize) -> History {
        History { counts: vec![0.0; n_zips * N_WEEKS * NF], n_zips }
    }

    #[inline]
    fn add(&mut self, zip: u32, week: u32, fam: usize, w: f64) {
        self.counts[(zip as usize * N_WEEKS + week as usize) * NF + fam] += w as f32;
    }

    #[inline]
    fn count(&self, zip: usize, week: usize, fam: usize) -> f64 {
        self.counts[(zip * N_WEEKS + week) * NF + fam] as f64
    }

    /// Per-family p95 over NONZERO cells (nearest-rank), the score normalizer.
    fn p95_per_family(&self) -> [f64; NF] {
        let mut out = [0.0; NF];
        for (f, o) in out.iter_mut().enumerate() {
            let mut v: Vec<f32> = (0..self.n_zips * N_WEEKS)
                .map(|i| self.counts[i * NF + f])
                .filter(|&c| c > 0.0)
                .collect();
            if v.is_empty() {
                continue;
            }
            v.sort_by(|a, b| a.partial_cmp(b).unwrap());
            let rank = ((v.len() as f64 * 0.95).ceil() as usize).clamp(1, v.len());
            *o = v[rank - 1] as f64;
        }
        out
    }
}

/// score(v) = min(0.6, 0.6 * ln(1+v)/ln(1+p95)), values under 0.05 -> 0.
/// See the module docs for the full rationale (p95 cells saturate at the cap;
/// the cap keeps a 20-year prior strictly below the 0.699 yellow cut).
fn score_from_count(v: f64, p95: f64) -> f64 {
    if v <= 0.0 || p95 <= 0.0 {
        return 0.0;
    }
    let s = (SCORE_MAX * (1.0 + v).ln() / (1.0 + p95).ln()).min(SCORE_MAX);
    if s < SCORE_FLOOR {
        0.0
    } else {
        s
    }
}

// ---------------------------------------------------------------- harmonics

/// DFT of a 52-week curve down to mean + 2 harmonics: [mean, a1, b1, a2, b2].
fn harmonic_fit(curve: &[f64; N_WEEKS]) -> [f32; 5] {
    let n = N_WEEKS as f64;
    let mean = curve.iter().sum::<f64>() / n;
    let mut c = [mean as f32, 0.0, 0.0, 0.0, 0.0];
    for k in 1..=2 {
        let (mut a, mut b) = (0.0, 0.0);
        for (w, &s) in curve.iter().enumerate() {
            let t = 2.0 * PI * (k as f64) * (w as f64) / n;
            a += s * t.cos();
            b += s * t.sin();
        }
        c[2 * k - 1] = (2.0 * a / n) as f32;
        c[2 * k] = (2.0 * b / n) as f32;
    }
    c
}

/// Reconstruct week w from [mean, a1, b1, a2, b2], clamped to the score range.
fn harmonic_eval(c: &[f32; 5], w: usize) -> f64 {
    let t = 2.0 * PI * (w as f64) / N_WEEKS as f64;
    let v = c[0] as f64
        + c[1] as f64 * t.cos()
        + c[2] as f64 * t.sin()
        + c[3] as f64 * (2.0 * t).cos()
        + c[4] as f64 * (2.0 * t).sin();
    v.clamp(0.0, SCORE_MAX)
}

// ------------------------------------------------------- raw JSON scan (A)
// The byte-preserving scanner, same technique as national-bundle.rs: R-engine
// entries are carried through as raw slices, never re-encoded.

/// Byte-preserving split of the existing bundle:
/// (prefix up to the `"zips"` key, raw per-zip object slices, suffix after `]`).
fn split_bundle(text: &str) -> Result<(&str, Vec<&str>, &str), String> {
    let bytes = text.as_bytes();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut esc = false;
    let mut key_start: Option<usize> = None;
    let mut last_key: Option<(usize, usize)> = None;
    let mut i = 0usize;
    let mut zips_key_pos: Option<usize> = None;
    let mut array_open: Option<usize> = None;
    while i < bytes.len() {
        let b = bytes[i];
        if in_str {
            if esc {
                esc = false;
            } else if b == b'\\' {
                esc = true;
            } else if b == b'"' {
                in_str = false;
                if depth == 1 && key_start.is_some() {
                    last_key = Some((key_start.unwrap(), i));
                    key_start = None;
                }
            }
            i += 1;
            continue;
        }
        match b {
            b'"' => {
                in_str = true;
                if depth == 1 {
                    key_start = Some(i);
                }
            }
            b'{' | b'[' => depth += 1,
            b'}' | b']' => depth -= 1,
            b':' => {
                if depth == 1 {
                    if let Some((ks, ke)) = last_key {
                        if &text[ks + 1..ke] == "zips" {
                            zips_key_pos = Some(ks);
                            let mut j = i + 1;
                            while j < bytes.len() && bytes[j].is_ascii_whitespace() {
                                j += 1;
                            }
                            if bytes.get(j) == Some(&b'[') {
                                array_open = Some(j);
                            }
                            break;
                        }
                    }
                    last_key = None;
                }
            }
            _ => {}
        }
        i += 1;
    }
    let (key_pos, open) = match (zips_key_pos, array_open) {
        (Some(k), Some(o)) => (k, o),
        _ => return Err("bundle has no top-level \"zips\" array".into()),
    };
    let mut entries = Vec::new();
    let mut j = open + 1;
    loop {
        while j < bytes.len() && (bytes[j].is_ascii_whitespace() || bytes[j] == b',') {
            j += 1;
        }
        if j >= bytes.len() {
            return Err("unterminated zips array".into());
        }
        if bytes[j] == b']' {
            j += 1;
            break;
        }
        if bytes[j] != b'{' {
            return Err(format!("unexpected byte {:?} in zips array", bytes[j] as char));
        }
        let start = j;
        let mut d = 0i32;
        let mut s = false;
        let mut e = false;
        while j < bytes.len() {
            let b = bytes[j];
            if s {
                if e {
                    e = false;
                } else if b == b'\\' {
                    e = true;
                } else if b == b'"' {
                    s = false;
                }
            } else {
                match b {
                    b'"' => s = true,
                    b'{' => d += 1,
                    b'}' => {
                        d -= 1;
                        if d == 0 {
                            j += 1;
                            break;
                        }
                    }
                    _ => {}
                }
            }
            j += 1;
        }
        if d != 0 {
            return Err("unbalanced object in zips array".into());
        }
        entries.push(&text[start..j]);
    }
    Ok((&text[..key_pos], entries, &text[j..]))
}

/// Top-level (key, raw value slice) pairs of one raw JSON object slice.
fn top_level_pairs(obj: &str) -> Vec<(&str, &str)> {
    let bytes = obj.as_bytes();
    let mut pairs = Vec::new();
    let mut i = 1; // past '{'
    let n = bytes.len();
    loop {
        while i < n && (bytes[i].is_ascii_whitespace() || bytes[i] == b',') {
            i += 1;
        }
        if i >= n || bytes[i] == b'}' {
            break;
        }
        if bytes[i] != b'"' {
            break; // malformed; bail with what we have
        }
        let ks = i + 1;
        let mut j = ks;
        let mut esc = false;
        while j < n {
            if esc {
                esc = false;
            } else if bytes[j] == b'\\' {
                esc = true;
            } else if bytes[j] == b'"' {
                break;
            }
            j += 1;
        }
        let key = &obj[ks..j];
        i = j + 1;
        while i < n && (bytes[i].is_ascii_whitespace() || bytes[i] == b':') {
            i += 1;
        }
        // scan the value (string / object / array / scalar)
        let vs = i;
        let mut depth = 0i32;
        let mut in_str = false;
        let mut esc2 = false;
        while i < n {
            let b = bytes[i];
            if in_str {
                if esc2 {
                    esc2 = false;
                } else if b == b'\\' {
                    esc2 = true;
                } else if b == b'"' {
                    in_str = false;
                    if depth == 0 {
                        i += 1;
                        break;
                    }
                }
                i += 1;
                continue;
            }
            match b {
                b'"' => in_str = true,
                b'{' | b'[' => depth += 1,
                b'}' | b']' => {
                    if depth == 0 {
                        break; // object's closing '}' (scalar value ended)
                    }
                    depth -= 1;
                    if depth == 0 {
                        i += 1;
                        break;
                    }
                }
                b',' => {
                    if depth == 0 {
                        break;
                    }
                }
                _ => {}
            }
            i += 1;
        }
        pairs.push((key, obj[vs..i].trim_end()));
    }
    pairs
}

/// Minimal float formatting matching the R export style: fixed decimals,
/// trailing zeros (and a bare trailing dot) trimmed, "-0" normalized to "0".
fn fmt_num(x: f64, decimals: usize) -> String {
    let mut s = format!("{x:.decimals$}");
    if s.contains('.') {
        while s.ends_with('0') {
            s.pop();
        }
        if s.ends_with('.') {
            s.pop();
        }
    }
    if s == "-0" {
        s = "0".into();
    }
    s
}

fn summary_family_label(family: &str) -> &str {
    match family {
        "qpf_flood" => "flood",
        other => other,
    }
}

/// Extract the families array (of plain strings) from the bundle prefix text.
fn parse_families(text: &str) -> Result<Vec<String>, String> {
    let key = "\"families\":";
    let kpos = text.find(key).ok_or("bundle has no families key")?;
    let rest = &text[kpos + key.len()..];
    let open = rest.find('[').ok_or("families is not an array")?;
    let close = rest[open..].find(']').ok_or("unterminated families array")? + open;
    let inner = &rest[open + 1..close];
    let fams: Vec<String> = inner
        .split(',')
        .map(|s| s.trim().trim_matches('"').to_string())
        .filter(|s| !s.is_empty())
        .collect();
    if fams.is_empty() {
        return Err("families array is empty".into());
    }
    Ok(fams)
}

// ---------------------------------------------------------------- merge (A)

struct MergeStats {
    wi_kept: usize,
    rescored: usize,
    unchanged: usize,
    bytes: usize,
}

/// Rebuild the bundle text: entries with a top-level "p" ring (the R-engine
/// Wisconsin entries) are carried through BYTE-FOR-BYTE; every other entry's
/// "s" becomes max(existing, history at `week`), with the summary "t"
/// regenerated under the same > SUMMARY_MIN rule national-bundle uses.
fn rebuild_bundle(
    original: &str,
    week: u32,
    history_score: &dyn Fn(&str, u32, usize) -> f64, // (zip, week, FAMS index)
) -> Result<(String, MergeStats), String> {
    let (prefix, entries, suffix) = split_bundle(original)?;
    let families = parse_families(prefix)?;
    // bundle family position -> FAMS table index (None: no history basis)
    let fam_map: Vec<Option<usize>> =
        families.iter().map(|f| FAMS.iter().position(|g| g == f)).collect();

    // idempotent metadata: drop any previous history_* keys from the prefix
    let mut clean_prefix = prefix.to_string();
    while let Some(p) = clean_prefix.find("\"history_baseline\":") {
        let rest = &clean_prefix[p..];
        let end = rest.find("\"history_week\":").and_then(|q| {
            let after = &rest[q..];
            after.find(',').map(|c| p + q + c + 1)
        });
        match end {
            Some(e) => clean_prefix.replace_range(p..e, ""),
            None => break,
        }
    }

    let mut stats = MergeStats { wi_kept: 0, rescored: 0, unchanged: 0, bytes: 0 };
    let mut out = String::with_capacity(original.len() + 64);
    out.push_str(&clean_prefix);
    out.push_str("\"history_baseline\":true,\"history_week\":");
    out.push_str(&week.to_string());
    out.push_str(",\"zips\":[");
    let mut first = true;
    for e in entries {
        if !first {
            out.push(',');
        }
        first = false;
        let pairs = top_level_pairs(e);
        let has_ring = pairs.iter().any(|(k, _)| *k == "p");
        if has_ring {
            out.push_str(e); // R-engine entry: byte-for-byte
            stats.wi_kept += 1;
            continue;
        }
        let z = pairs
            .iter()
            .find(|(k, _)| *k == "z")
            .map(|(_, v)| v.trim_matches('"'))
            .ok_or("national entry missing \"z\"")?;
        let c_raw = pairs.iter().find(|(k, _)| *k == "c").map(|(_, v)| *v).unwrap_or("[0,0]");
        let s_raw = pairs.iter().find(|(k, _)| *k == "s").map(|(_, v)| *v).unwrap_or("[]");
        let mut s: Vec<f64> = s_raw
            .trim_start_matches('[')
            .trim_end_matches(']')
            .split(',')
            .filter_map(|v| v.trim().parse().ok())
            .collect();
        s.resize(families.len(), 0.0);
        let mut hist_won = vec![false; families.len()];
        for (i, fam) in fam_map.iter().enumerate() {
            if let Some(f) = *fam {
                let h = history_score(z, week, f);
                // ties count as history-won so re-running the merge on its own
                // output is a fixed point (labels never flip back to seasonal)
                if h > 0.0 && h >= s[i] {
                    s[i] = h;
                    hist_won[i] = true;
                }
            }
        }
        let rebuilt = {
            let s_json: Vec<String> = s.iter().map(|&v| fmt_num(v, 3)).collect();
            let mut ent = format!("{{\"z\":\"{}\",\"c\":{},\"s\":[{}]", z, c_raw, s_json.join(","));
            let mut top = 0usize;
            for (i, &v) in s.iter().enumerate() {
                if v > s[top] {
                    top = i;
                }
            }
            if s[top] > SUMMARY_MIN {
                let label = summary_family_label(&families[top]);
                if hist_won[top] {
                    ent.push_str(&format!(
                        ",\"t\":\"Historical baseline: elevated {label} risk (20-yr storm climatology)\""
                    ));
                } else {
                    ent.push_str(&format!(
                        ",\"t\":\"Seasonal baseline: elevated {label} risk (climatology)\""
                    ));
                }
            }
            ent.push('}');
            ent
        };
        if rebuilt == e {
            stats.unchanged += 1;
        } else {
            stats.rescored += 1;
        }
        out.push_str(&rebuilt);
    }
    out.push(']');
    out.push_str(suffix);
    stats.bytes = out.len();
    Ok((out, stats))
}

// ---------------------------------------------------------------- outputs B

fn push_u32(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_le_bytes());
}

fn header_common(magic: &[u8; 4], n_zips: u32, third: u32, fams: &[&str], zips: &[&str]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(magic);
    push_u32(&mut out, 1); // version
    push_u32(&mut out, n_zips);
    push_u32(&mut out, third);
    if magic == b"FLHD" {
        push_u32(&mut out, fams.len() as u32);
    }
    for f in fams {
        out.push(f.len() as u8);
        out.extend_from_slice(f.as_bytes());
    }
    for z in zips {
        debug_assert_eq!(z.len(), 5);
        out.extend_from_slice(z.as_bytes());
    }
    out
}

// ---------------------------------------------------------------- main run

fn find_repo_root() -> Result<PathBuf, String> {
    let mut dir = env::current_dir().map_err(|e| e.to_string())?;
    for _ in 0..6 {
        if dir.join(BUNDLE_REL).is_file() {
            return Ok(dir);
        }
        match dir.parent() {
            Some(p) => dir = p.to_path_buf(),
            None => break,
        }
    }
    Err(format!("could not locate {BUNDLE_REL} walking up from the current directory"))
}

#[derive(Default)]
struct ParseStats {
    per_year: BTreeMap<u32, u64>,
    records: u64,
    mapped_latlon: u64,
    mapped_county: u64,
    mapped_zone_corr: u64,
    mapped_zone_name: u64,
    skipped_zone: u64,
    skipped_unknown_county: u64,
    skipped_bad_date: u64,
    skipped_far_latlon: u64,
    unmapped_types: HashMap<String, u64>,
}

#[allow(clippy::too_many_arguments)]
fn ingest_file(
    text: &str,
    zctas: &[Zcta],
    grid: &ZipGrid,
    counties: &Counties,
    zone_map: &HashMap<(String, String), Vec<u32>>,
    zone_name_memo: &mut HashMap<(String, String), Vec<u32>>,
    hist: &mut History,
    stats: &mut ParseStats,
) -> Result<(), String> {
    let mut rd = CsvRecords::new(text);
    let mut spans: Vec<(usize, usize, bool)> = Vec::with_capacity(64);
    if !rd.next_record(&mut spans) {
        return Err("empty storm events file".into());
    }
    let headers: Vec<String> = spans.iter().map(|&s| field(text, s).trim().to_string()).collect();
    let col = |name: &str| -> Result<usize, String> {
        headers.iter().position(|h| h == name).ok_or_else(|| format!("missing column {name}"))
    };
    let i_ym = col("BEGIN_YEARMONTH")?;
    let i_day = col("BEGIN_DAY")?;
    let i_type = col("EVENT_TYPE")?;
    let i_sfips = col("STATE_FIPS")?;
    let i_cztype = col("CZ_TYPE")?;
    let i_czfips = col("CZ_FIPS")?;
    let i_czname = col("CZ_NAME")?;
    let i_lat = col("BEGIN_LAT")?;
    let i_lon = col("BEGIN_LON")?;
    let i_mag = col("MAGNITUDE")?;

    while rd.next_record(&mut spans) {
        if spans.len() <= i_lon.max(i_mag).max(i_czfips) {
            continue; // truncated/blank line
        }
        stats.records += 1;
        let get = |i: usize| field(text, spans[i]);
        let ym: u32 = match get(i_ym).trim().parse() {
            Ok(v) => v,
            Err(_) => {
                stats.skipped_bad_date += 1;
                continue;
            }
        };
        *stats.per_year.entry(ym / 100).or_insert(0) += 1;
        let day: u32 = get(i_day).trim().parse().unwrap_or(0);
        let Some(week) = week_of_year(ym, day) else {
            stats.skipped_bad_date += 1;
            continue;
        };
        let etype = get(i_type);
        let fams = families_for(&etype);
        if fams.is_empty() {
            *stats.unmapped_types.entry(etype.trim().to_string()).or_insert(0) += 1;
            continue;
        }
        let mag: Option<f64> = get(i_mag).trim().parse().ok();
        let w = event_weight(&etype.to_ascii_lowercase(), mag);

        let lat: Option<f64> = get(i_lat).trim().parse().ok();
        let lon: Option<f64> = get(i_lon).trim().parse().ok();
        if let (Some(la), Some(lo)) = (lat, lon) {
            // plausible North-America coordinates only
            if (15.0..=75.0).contains(&la) && (-180.0..=-50.0).contains(&lo) {
                if let Some(zi) = grid.nearest(zctas, la, lo, 10) {
                    for &f in &fams {
                        hist.add(zi, week, f, w);
                    }
                    stats.mapped_latlon += 1;
                } else {
                    stats.skipped_far_latlon += 1;
                }
                continue;
            }
        }
        let cz_type = get(i_cztype);
        let cz_type = cz_type.trim();
        let sf: u32 = get(i_sfips).trim().parse().unwrap_or(0);
        let cf: u32 = get(i_czfips).trim().parse().unwrap_or(0);
        if cz_type == "C" {
            let geoid = format!("{sf:02}{cf:03}");
            if let Some(zips) = counties.zips.get(&geoid) {
                if !zips.is_empty() {
                    let share = w / zips.len() as f64; // spread weights sum to w
                    for &zi in zips {
                        for &f in &fams {
                            hist.add(zi, week, f, share);
                        }
                    }
                    stats.mapped_county += 1;
                    continue;
                }
            }
            stats.skipped_unknown_county += 1;
        } else {
            // zone-coded without usable lat/lon: NWS zone->county correlation
            // first, then county-name matching on CZ_NAME, else skip
            let mut resolved: Option<(&[u32], bool)> = None;
            if let Some(ab) = state_abbr(sf) {
                if let Some(zips) = zone_map.get(&(ab.to_string(), format!("{cf:03}"))) {
                    if !zips.is_empty() {
                        resolved = Some((zips, true));
                    }
                }
            }
            let state2 = format!("{sf:02}");
            if resolved.is_none() {
                let name_key = (state2.clone(), get(i_czname).trim().to_ascii_uppercase());
                let zips = zone_name_memo
                    .entry(name_key)
                    .or_insert_with_key(|(st, nm)| zones_by_name(st, nm, counties));
                if !zips.is_empty() {
                    resolved = Some((zips, false));
                }
            }
            match resolved {
                Some((zips, via_corr)) => {
                    let share = w / zips.len() as f64; // spread weights sum to w
                    for &zi in zips {
                        for &f in &fams {
                            hist.add(zi, week, f, share);
                        }
                    }
                    if via_corr {
                        stats.mapped_zone_corr += 1;
                    } else {
                        stats.mapped_zone_name += 1;
                    }
                }
                None => stats.skipped_zone += 1,
            }
        }
    }
    Ok(())
}

fn run(storm_dir: &Path, week: u32) -> Result<(), String> {
    let root = find_repo_root()?;
    let t0 = std::time::Instant::now();

    // ---- inputs
    let zctas = read_gazetteer(&root.join(GAZ_REL))?;
    let zip_idx: HashMap<String, u32> =
        zctas.iter().enumerate().map(|(i, z)| (z.zip.clone(), i as u32)).collect();
    let grid = ZipGrid::build(&zctas);
    let counties = read_county_rel(&root.join(REL_REL), &zip_idx)?;
    let zone_map = read_zone_county(&root.join(ZONE_REL), &counties.zips);
    println!(
        "zctas: {}  counties_mapped: {}  nws_zones_mapped: {}",
        zctas.len(),
        counties.zips.len(),
        zone_map.len()
    );

    // ---- ingest all yearly CSVs
    let mut files: Vec<PathBuf> = fs::read_dir(storm_dir)
        .map_err(|e| format!("cannot list {}: {e}", storm_dir.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "csv"))
        .collect();
    files.sort();
    if files.is_empty() {
        return Err(format!("no .csv files in {}", storm_dir.display()));
    }
    let mut hist = History::new(zctas.len());
    let mut stats = ParseStats::default();
    let mut zone_name_memo: HashMap<(String, String), Vec<u32>> = HashMap::new();
    for f in &files {
        let text = fs::read_to_string(f).map_err(|e| format!("read {}: {e}", f.display()))?;
        ingest_file(
            &text,
            &zctas,
            &grid,
            &counties,
            &zone_map,
            &mut zone_name_memo,
            &mut hist,
            &mut stats,
        )?;
    }
    println!("files: {}  records: {}", files.len(), stats.records);
    for (y, n) in &stats.per_year {
        println!("  year {y}: {n} events");
    }
    println!(
        "mapped: latlon {}  county-spread {}  zone-corr {}  zone-name {}  | skipped: zone-unresolved {}  unknown-county {}  bad-date {}  far-latlon {}",
        stats.mapped_latlon,
        stats.mapped_county,
        stats.mapped_zone_corr,
        stats.mapped_zone_name,
        stats.skipped_zone,
        stats.skipped_unknown_county,
        stats.skipped_bad_date,
        stats.skipped_far_latlon
    );
    let mut unmapped: Vec<(&String, &u64)> = stats.unmapped_types.iter().collect();
    unmapped.sort_by(|a, b| b.1.cmp(a.1));
    let unmapped_total: u64 = unmapped.iter().map(|(_, &n)| n).sum();
    println!("unmapped event types: {} distinct, {} events", unmapped.len(), unmapped_total);
    for (t, n) in &unmapped {
        println!("  UNMAPPED {n:>7}  {t}");
    }

    // ---- scores
    let p95 = hist.p95_per_family();
    for (f, name) in FAMS.iter().enumerate() {
        println!("p95[{name}] = {}", p95[f]);
    }
    // zips with any signal, in (already sorted) gazetteer order
    let mut active: Vec<usize> = Vec::new();
    'z: for zi in 0..zctas.len() {
        for wk in 0..N_WEEKS {
            for (f, &p95f) in p95.iter().enumerate() {
                if score_from_count(hist.count(zi, wk, f), p95f) > 0.0 {
                    active.push(zi);
                    continue 'z;
                }
            }
        }
    }
    println!("zips with signal: {} / {}", active.len(), zctas.len());

    // dense float table for the active zips (source of truth for B and C)
    let mut dense: Vec<f64> = vec![0.0; active.len() * N_WEEKS * NF];
    for (ai, &zi) in active.iter().enumerate() {
        for wk in 0..N_WEEKS {
            for f in 0..NF {
                dense[(ai * N_WEEKS + wk) * NF + f] =
                    score_from_count(hist.count(zi, wk, f), p95[f]);
            }
        }
    }

    // ---- OUTPUT B1: dense u8
    let zip_strs: Vec<&str> = active.iter().map(|&zi| zctas[zi].zip.as_str()).collect();
    let mut dense_bin =
        header_common(b"FLHD", active.len() as u32, N_WEEKS as u32, &FAMS, &zip_strs);
    dense_bin.reserve(dense.len());
    for &s in &dense {
        dense_bin.push((s * 255.0).round() as u8);
    }
    let dense_path = root.join(DENSE_REL);
    fs::write(&dense_path, &dense_bin).map_err(|e| format!("write dense: {e}"))?;
    println!("dense:    {} bytes -> {}", dense_bin.len(), dense_path.display());

    // ---- OUTPUT B2: harmonic 5xf32 + max reconstruction error
    let mut harm_bin = header_common(b"FLHH", active.len() as u32, NF as u32, &FAMS, &zip_strs);
    harm_bin.reserve(active.len() * NF * 5 * 4);
    let mut max_err = 0.0f64;
    let mut sum_err = 0.0f64;
    let mut cells = 0u64;
    for ai in 0..active.len() {
        for f in 0..NF {
            let mut curve = [0.0f64; N_WEEKS];
            for (wk, c) in curve.iter_mut().enumerate() {
                *c = dense[(ai * N_WEEKS + wk) * NF + f];
            }
            let coef = harmonic_fit(&curve);
            for c in coef {
                harm_bin.extend_from_slice(&c.to_le_bytes());
            }
            for (wk, &truth) in curve.iter().enumerate() {
                let err = (harmonic_eval(&coef, wk) - truth).abs();
                if err > max_err {
                    max_err = err;
                }
                sum_err += err;
                cells += 1;
            }
        }
    }
    let harm_path = root.join(HARM_REL);
    fs::write(&harm_path, &harm_bin).map_err(|e| format!("write harmonic: {e}"))?;
    println!("harmonic: {} bytes -> {}", harm_bin.len(), harm_path.display());
    println!(
        "harmonic reconstruction vs dense: max_abs_err {:.4}  mean_abs_err {:.5}  cells {}",
        max_err,
        sum_err / cells.max(1) as f64,
        cells
    );

    // ---- OUTPUT A: rebuilt bundle (backup first, once)
    let bundle_path = root.join(BUNDLE_REL);
    let backup_path = root.join(BACKUP_REL);
    let original =
        fs::read_to_string(&bundle_path).map_err(|e| format!("read bundle: {e}"))?;
    if !backup_path.exists() {
        fs::write(&backup_path, &original).map_err(|e| format!("write backup: {e}"))?;
        println!("backup -> {}", backup_path.display());
    } else {
        println!("backup already exists, left untouched: {}", backup_path.display());
    }
    let active_pos: HashMap<&str, usize> =
        zip_strs.iter().enumerate().map(|(i, z)| (*z, i)).collect();
    let lookup = |zip: &str, wk: u32, f: usize| -> f64 {
        active_pos
            .get(zip)
            .map(|&ai| dense[(ai * N_WEEKS + wk as usize) * NF + f])
            .unwrap_or(0.0)
    };
    let (rebuilt, mstats) = rebuild_bundle(&original, week, &lookup)?;
    let tmp = bundle_path.with_extension("json.tmp");
    fs::write(&tmp, &rebuilt).map_err(|e| format!("write bundle tmp: {e}"))?;
    fs::rename(&tmp, &bundle_path).map_err(|e| format!("rename onto bundle: {e}"))?;
    println!(
        "bundle: wi_kept {}  rescored {}  unchanged {}  bytes {}",
        mstats.wi_kept, mstats.rescored, mstats.unchanged, mstats.bytes
    );

    // ---- OUTPUT C: training rows in flows-train's read_csv format
    // (oLat,oLon,dLat,dLon,week,y,weight,cross — o == d == the ZIP centroid,
    //  y = the zip-week's max family score, weight 1, cross 0)
    let mut csv = String::with_capacity(active.len() * N_WEEKS * 24);
    csv.push_str("oLat,oLon,dLat,dLon,week,risk,weight,cross\n");
    let mut n_rows = 0u64;
    for (ai, &zi) in active.iter().enumerate() {
        let z = &zctas[zi];
        for wk in 0..N_WEEKS {
            let mut y = 0.0f64;
            for f in 0..NF {
                y = y.max(dense[(ai * N_WEEKS + wk) * NF + f]);
            }
            if y <= 0.0 {
                continue;
            }
            csv.push_str(&format!(
                "{},{},{},{},{},{},1,0\n",
                fmt_num(z.lat, 4),
                fmt_num(z.lon, 4),
                fmt_num(z.lat, 4),
                fmt_num(z.lon, 4),
                wk,
                fmt_num(y, 4)
            ));
            n_rows += 1;
        }
    }
    let rows_path = root.join(ROWS_REL);
    fs::write(&rows_path, &csv).map_err(|e| format!("write training rows: {e}"))?;
    println!("training rows: {} -> {} ({} bytes)", n_rows, rows_path.display(), csv.len());

    println!("done in {:.1}s", t0.elapsed().as_secs_f64());
    Ok(())
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let (dir, week) = match (args.get(1), args.get(2).and_then(|s| s.parse::<u32>().ok())) {
        (Some(d), Some(w)) if w <= 51 => (PathBuf::from(d), w),
        _ => {
            eprintln!("usage: history-baseline <storm-events-dir> <current-week 0-51>");
            std::process::exit(2);
        }
    };
    if let Err(e) = run(&dir, week) {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}

// ---------------------------------------------------------------- tests

#[cfg(test)]
mod tests {
    use super::*;

    // ---- CSV quoting (Storm Events narratives contain commas, quotes, newlines)
    #[test]
    fn csv_quoted_commas_newlines_and_escapes() {
        let text = "A,B,C\n1,\"x, y\",3\n4,\"line one\nline two\",6\n7,\"he said \"\"hi\"\"\",9\n";
        let mut rd = CsvRecords::new(text);
        let mut s = Vec::new();
        assert!(rd.next_record(&mut s));
        assert_eq!(s.len(), 3);
        assert!(rd.next_record(&mut s));
        assert_eq!(field(text, s[1]), "x, y");
        assert_eq!(field(text, s[2]), "3");
        assert!(rd.next_record(&mut s));
        assert_eq!(field(text, s[1]), "line one\nline two");
        assert!(rd.next_record(&mut s));
        assert_eq!(field(text, s[1]), "he said \"hi\"");
        assert!(!rd.next_record(&mut s));
    }

    #[test]
    fn csv_crlf_and_trailing_empty_fields() {
        let text = "A,B\r\n1,\r\n,2\r\n";
        let mut rd = CsvRecords::new(text);
        let mut s = Vec::new();
        assert!(rd.next_record(&mut s));
        assert!(rd.next_record(&mut s));
        assert_eq!(field(text, s[0]), "1");
        assert_eq!(field(text, s[1]), "");
        assert!(rd.next_record(&mut s));
        assert_eq!(field(text, s[0]), "");
        assert_eq!(field(text, s[1]), "2");
        assert!(!rd.next_record(&mut s));
    }

    // ---- calendar
    #[test]
    fn week_of_year_buckets() {
        assert_eq!(week_of_year(202401, 1), Some(0));
        assert_eq!(week_of_year(202401, 7), Some(0));
        assert_eq!(week_of_year(202401, 8), Some(1));
        assert_eq!(week_of_year(202412, 31), Some(51)); // day 366 clamps into 51
        assert_eq!(week_of_year(202312, 31), Some(51));
        assert_eq!(week_of_year(200402, 29), Some(8)); // leap day valid
        assert_eq!(week_of_year(202413, 1), None);
        assert_eq!(week_of_year(202401, 0), None);
    }

    // ---- family mapping
    #[test]
    fn event_type_mapping() {
        let f = |t: &str| families_for(t);
        assert_eq!(f("Tornado"), vec![F_CONV]);
        assert_eq!(f("Marine Thunderstorm Wind"), vec![F_CONV]);
        assert_eq!(f("Hail"), vec![F_CONV]);
        assert_eq!(f("Waterspout"), vec![F_CONV]);
        assert_eq!(f("Flash Flood"), vec![F_QPF]);
        assert_eq!(f("Lakeshore Flood"), vec![F_QPF]);
        assert_eq!(f("Tsunami"), vec![F_QPF]);
        assert_eq!(f("Winter Storm"), vec![F_WINTER]);
        assert_eq!(f("Lake-Effect Snow"), vec![F_WINTER]);
        assert_eq!(f("Freezing Fog"), vec![F_WINTER]);
        assert_eq!(f("Avalanche"), vec![F_WINTER]);
        assert_eq!(f("Hurricane (Typhoon)"), vec![F_WIND, F_QPF]);
        assert_eq!(f("Storm Surge/Tide"), vec![F_WIND, F_QPF]);
        assert_eq!(f("Excessive Heat"), vec![F_HEAT]);
        assert_eq!(f("Heat"), vec![F_HEAT]);
        assert_eq!(f("Extreme Cold/Wind Chill"), vec![F_COLD]);
        assert_eq!(f("Cold/Wind Chill"), vec![F_COLD]); // "wind chill" beats "wind"
        assert_eq!(f("Frost/Freeze"), vec![F_COLD]);
        assert_eq!(f("High Wind"), vec![F_WIND]);
        assert_eq!(f("Marine Strong Wind"), vec![F_WIND]);
        assert_eq!(f("Wildfire"), vec![F_FIRE]);
        assert_eq!(f("Dense Smoke"), vec![F_FIRE]);
        assert_eq!(f("Drought"), vec![F_AIR]);
        assert_eq!(f("Dust Storm"), vec![F_AIR]);
        assert!(f("Dense Fog").is_empty());
        assert!(f("Rip Current").is_empty());
    }

    // ---- county spread weights sum to 1
    #[test]
    fn county_spread_weights_sum_to_one() {
        let mut hist = History::new(5);
        let zips: Vec<u32> = vec![0, 2, 4];
        let w = 1.0;
        let share = w / zips.len() as f64;
        for &zi in &zips {
            hist.add(zi, 10, F_CONV, share);
        }
        let total: f64 = (0..5).map(|z| hist.count(z, 10, F_CONV)).sum();
        // counts accumulate in f32 -> allow f32-level slack
        assert!((total - 1.0).abs() < 1e-6, "spread weights must sum to the event weight");
        assert!((hist.count(0, 10, F_CONV) - 1.0 / 3.0).abs() < 1e-6);
        assert_eq!(hist.count(1, 10, F_CONV), 0.0);
    }

    // ---- score discipline
    #[test]
    fn score_formula_bounds_and_floor() {
        let p95 = 40.0;
        assert_eq!(score_from_count(0.0, p95), 0.0);
        // at p95 the score saturates at the cap
        assert!((score_from_count(p95, p95) - SCORE_MAX).abs() < 1e-12);
        // far above p95 still capped, always under the yellow cut
        assert_eq!(score_from_count(10.0 * p95, p95), SCORE_MAX);
        // Documentation-assert: the cap must sit under the app's yellow cut.
        #[allow(clippy::assertions_on_constants)]
        {
            assert!(SCORE_MAX < 0.699);
        }
        // tiny counts fall under the floor -> 0
        assert_eq!(score_from_count(0.05, p95), 0.0);
        // monotone in between
        let (a, b) = (score_from_count(2.0, p95), score_from_count(8.0, p95));
        assert!(0.0 < a && a < b && b < SCORE_MAX);
    }

    // ---- harmonics
    #[test]
    fn harmonic_round_trip_on_synthetic_curves() {
        // A curve that IS mean + 2 harmonics reconstructs (near-)exactly.
        let mut curve = [0.0f64; N_WEEKS];
        for (w, c) in curve.iter_mut().enumerate() {
            let t = 2.0 * PI * w as f64 / 52.0;
            *c = 0.3 + 0.1 * t.cos() + 0.05 * t.sin() - 0.04 * (2.0 * t).cos()
                + 0.02 * (2.0 * t).sin();
        }
        let coef = harmonic_fit(&curve);
        for (w, &truth) in curve.iter().enumerate() {
            assert!(
                (harmonic_eval(&coef, w) - truth).abs() < 1e-4,
                "pure-harmonic curve must round-trip"
            );
        }
        // A single-week spike is the worst case; error stays bounded by the
        // spike height (the fit spreads it), and eval clamps to [0, SCORE_MAX].
        let mut spike = [0.0f64; N_WEEKS];
        spike[20] = SCORE_MAX;
        let coef = harmonic_fit(&spike);
        for (w, &sw) in spike.iter().enumerate() {
            let v = harmonic_eval(&coef, w);
            assert!((0.0..=SCORE_MAX).contains(&v));
            assert!((v - sw).abs() <= SCORE_MAX);
        }
    }

    // ---- WI byte-preservation through the merge
    #[test]
    fn wi_entries_preserved_byte_for_byte() {
        let wi = concat!(
            "{\"z\":\"53703\",\"c\":[-89.3851,43.0731],\"s\":[0.1,0.2],",
            "\"t\":\"say \\\"hi\\\" {ok}\",\"p\":[[-89.4,43.0],[-89.3,43.1],[-89.4,43.1]]}"
        );
        let src = format!(
            "{{\"generated_utc\":\"x\",\"families\":[\"wind\",\"winter\"],\"zips\":[{},{}]}}",
            wi, "{\"z\":\"55401\",\"c\":[-93.27,44.98],\"s\":[0,0.1]}"
        );
        // history: winter 0.5 for 55401 at week 0; nothing for the WI zip
        let lookup = |zip: &str, _wk: u32, f: usize| -> f64 {
            if zip == "55401" && FAMS[f] == "winter" {
                0.5
            } else {
                0.0
            }
        };
        let (out, stats) = rebuild_bundle(&src, 0, &lookup).expect("merge");
        assert!(out.contains(wi), "R-engine entry must be carried byte-for-byte");
        assert_eq!(stats.wi_kept, 1);
        assert_eq!(stats.rescored, 1);
        // 55401: winter max(0.1, 0.5) = 0.5, history won -> historical summary
        assert!(out.contains("{\"z\":\"55401\",\"c\":[-93.27,44.98],\"s\":[0,0.5],\"t\":\"Historical baseline: elevated winter risk (20-yr storm climatology)\"}"),
            "merged entry wrong: {out}");
        assert!(out.contains("\"history_baseline\":true,\"history_week\":0,"));
        // idempotency: merging the output again yields exactly one history key
        let (out2, stats2) = rebuild_bundle(&out, 0, &lookup).expect("re-merge");
        assert_eq!(out2.matches("\"history_baseline\"").count(), 1);
        assert_eq!(out2, out);
        assert_eq!(stats2.wi_kept, 1);
    }

    // ---- unchanged national entries survive byte-identically
    #[test]
    fn untouched_national_entries_are_byte_identical() {
        let nat = "{\"z\":\"97201\",\"c\":[-122.69,45.5],\"s\":[0,0]}";
        let nat_t = concat!(
            "{\"z\":\"33101\",\"c\":[-80.1937,25.7743],\"s\":[0.35,0.31],",
            "\"t\":\"Seasonal baseline: elevated wind risk (climatology)\"}"
        );
        let src = format!(
            "{{\"families\":[\"wind\",\"qpf_flood\"],\"zips\":[{nat},{nat_t}]}}"
        );
        let lookup = |_z: &str, _w: u32, _f: usize| 0.0;
        let (out, stats) = rebuild_bundle(&src, 27, &lookup).expect("merge");
        assert!(out.contains(nat));
        assert!(out.contains(nat_t), "summary text must be reproduced exactly: {out}");
        assert_eq!(stats.unchanged, 2);
        assert_eq!(stats.rescored, 0);
    }

    // ---- raw object pair scanner
    #[test]
    fn top_level_pairs_scans_nested_values() {
        let obj = "{\"z\":\"1\",\"c\":[-1,2],\"s\":[0,0.3],\"t\":\"a \\\"q\\\", b\",\"p\":[[1,2],[3,4]]}";
        let pairs = top_level_pairs(obj);
        let get = |k: &str| pairs.iter().find(|(a, _)| *a == k).map(|(_, v)| *v);
        assert_eq!(get("z"), Some("\"1\""));
        assert_eq!(get("c"), Some("[-1,2]"));
        assert_eq!(get("s"), Some("[0,0.3]"));
        assert_eq!(get("t"), Some("\"a \\\"q\\\", b\""));
        assert_eq!(get("p"), Some("[[1,2],[3,4]]"));
    }

    // ---- event weight (MAGNITUDE severity boost)
    #[test]
    fn magnitude_weighting() {
        assert_eq!(event_weight("hail", Some(2.5)), 1.5);
        assert_eq!(event_weight("hail", Some(1.0)), 1.0);
        assert_eq!(event_weight("thunderstorm wind", Some(70.0)), 1.5);
        assert_eq!(event_weight("thunderstorm wind", Some(50.0)), 1.0);
        assert_eq!(event_weight("tornado", None), 1.0);
    }

    // ---- zone resolution
    #[test]
    fn zone_name_matching_word_boundaries() {
        assert!(contains_word("SOUTHEAST YUMA COUNTY", "YUMA"));
        assert!(contains_word("YUMA", "YUMA"));
        assert!(!contains_word("PARKER VALLEY", "PARK")); // PARKER != PARK
        assert!(!contains_word("KOFA", "OFA"));
        assert!(contains_word("ST. CLAIR/GRATIOT", "ST. CLAIR"));
        assert!(!contains_word("ANYTHING", ""));
    }

    #[test]
    fn zone_fallback_unions_matched_counties() {
        let mut counties =
            Counties { zips: HashMap::new(), names_by_state: HashMap::new() };
        counties.zips.insert("04013".into(), vec![1, 2]);
        counties.zips.insert("04012".into(), vec![3]);
        counties.names_by_state.insert(
            "04".into(),
            vec![("MARICOPA".into(), "04013".into()), ("LA PAZ".into(), "04012".into())],
        );
        // exact name
        assert_eq!(zones_by_name("04", "MARICOPA", &counties), vec![1, 2]);
        // whole-word containment
        assert_eq!(zones_by_name("04", "CENTRAL LA PAZ", &counties), vec![3]);
        // multi-county zone name unions both
        let mut multi = zones_by_name("04", "MARICOPA/LA PAZ LINE", &counties);
        multi.sort();
        assert_eq!(multi, vec![1, 2, 3]);
        // no match
        assert!(zones_by_name("04", "TONOPAH DESERT", &counties).is_empty());
    }

    #[test]
    fn county_name_normalization_and_state_fips() {
        assert_eq!(normalize_county_name("Baldwin County"), "BALDWIN");
        assert_eq!(normalize_county_name("St. Bernard Parish"), "ST. BERNARD");
        assert_eq!(normalize_county_name("Juneau City and Borough"), "JUNEAU");
        assert_eq!(normalize_county_name("Baltimore city"), "BALTIMORE");
        assert_eq!(state_abbr(4), Some("AZ"));
        assert_eq!(state_abbr(55), Some("WI"));
        assert_eq!(state_abbr(72), Some("PR"));
        assert_eq!(state_abbr(99), None);
    }

    // ---- grid nearest
    #[test]
    fn grid_nearest_snaps_to_closest_centroid() {
        let zctas = vec![
            Zcta { zip: "10001".into(), lat: 40.75, lon: -73.99 },
            Zcta { zip: "07030".into(), lat: 40.74, lon: -74.03 },
            Zcta { zip: "90210".into(), lat: 34.10, lon: -118.41 },
        ];
        let grid = ZipGrid::build(&zctas);
        let i = grid.nearest(&zctas, 40.751, -73.991, 10).expect("hit");
        assert_eq!(zctas[i as usize].zip, "10001");
        let i = grid.nearest(&zctas, 34.0, -118.4, 10).expect("hit");
        assert_eq!(zctas[i as usize].zip, "90210");
        // far away from everything within the ring budget -> None
        assert!(grid.nearest(&zctas, 60.0, -150.0, 5).is_none());
    }
}
