// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! FLOWS national ZIP risk baseline — pure std, ZERO external crates, the same
//! discipline as `flows-core` / `flows-train`.
//!
//! Merges a seasonal-climatology identified-risk baseline for every CONUS ZCTA
//! into `data/runtime_cache/app_risk_bundle.json` so every state gets a dense
//! choropleth. Any entry carrying a ring `p` is preserved BYTE-FOR-BYTE (its
//! raw JSON object slice is carried through untouched — floats are never
//! re-encoded). Historically that protected the R "Wisconsin" engine's
//! ring-carrying entries; since the one-system merge (5ed9cc0) the bundle has
//! ZERO ring entries, so preservation is a no-op safety net kept for the case
//! a ring entry is ever reintroduced. National entries carry centroid
//! `c` as [lon, lat] and scores `s` aligned with the bundle's own `families`
//! array, no ring `p` (the app fetches ZCTA rings on demand).
//!
//! Climatology is a PRIOR, not a realized hazard: every score is conservative,
//! in [0.05, 0.6] when present and hard-capped well below the 0.699 yellow cut.
//! Same physics family as `flows-train` seed_rows(): northern winter risk on a
//! week-of-year sinusoid scaled by latitude; gulf/atlantic tropical bump weeks
//! 32-44; plains wind exposure; desert/southern summer heat.
//!
//! Usage: national-bundle <week 0-51>
//! (week passed explicitly so output is reproducible; wrapper passes real week)

use std::env;
use std::f64::consts::PI;
use std::fs;
use std::path::{Path, PathBuf};

const BUNDLE_REL: &str = "data/runtime_cache/app_risk_bundle.json";
const GAZ_REL: &str = "data/reference/2024_Gaz_zcta_national.txt";

// CONUS bounding box.
const LAT_MIN: f64 = 24.0;
const LAT_MAX: f64 = 50.0;
const LON_MIN: f64 = -125.0;
const LON_MAX: f64 = -66.0;

// Score discipline: a climatological prior may never reach the yellow cut.
const SCORE_MAX: f64 = 0.6; // hard cap, < 0.699
const SCORE_FLOOR: f64 = 0.05; // below this a signal is noise -> emit 0
const SUMMARY_MIN: f64 = 0.3; // name the top family only when it clears this

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
        cols.iter()
            .position(|c| *c == name)
            .ok_or_else(|| format!("gazetteer header missing {name}"))
    };
    let (i_geoid, i_lat, i_lon) = (idx("GEOID")?, idx("INTPTLAT")?, idx("INTPTLONG")?);
    Ok(lines.filter_map(|l| parse_gaz_line(l, i_geoid, i_lat, i_lon)).collect())
}

fn in_conus(lat: f64, lon: f64) -> bool {
    (LAT_MIN..=LAT_MAX).contains(&lat) && (LON_MIN..=LON_MAX).contains(&lon)
}

// ---------------------------------------------------------------- climatology

/// Linear ramp: 0 below `lo`, 1 above `hi`, linear between. Soft region edges.
fn ramp(x: f64, lo: f64, hi: f64) -> f64 {
    ((x - lo) / (hi - lo)).clamp(0.0, 1.0)
}

/// Box with soft shoulders: rises over [lo, lo+soft], falls over [hi-soft, hi].
fn soft_box(x: f64, lo: f64, hi: f64, soft: f64) -> f64 {
    ramp(x, lo, lo + soft) * (1.0 - ramp(x, hi - soft, hi))
}

/// Seasonal phases, week 0..51. cos peaks at week 0 (mid-winter), the same
/// convention as flows-train seed_rows().
fn winter_phase(week: u32) -> f64 {
    (2.0 * PI * week as f64 / 52.0).cos().max(0.0)
}
fn summer_phase(week: u32) -> f64 {
    (-(2.0 * PI * week as f64 / 52.0).cos()).max(0.0)
}

/// Gulf/Atlantic tropical-season bump, weeks 32..=44 (same window and shape as
/// seed_rows), scaled by a coastal-region weight.
fn tropical_signal(lat: f64, lon: f64, week: u32) -> f64 {
    if !(32..=44).contains(&week) {
        return 0.0;
    }
    let season = (PI * (week as f64 - 32.0) / 12.0).sin();
    // Gulf coast: southern, between Texas and Florida.
    let gulf = soft_box(lat, 24.0, 32.0, 2.0) * soft_box(lon, -98.5, -80.0, 2.0);
    // Southern Atlantic seaboard: east of the Appalachians, below the Carolinas.
    let atlantic = soft_box(lat, 24.0, 36.5, 2.5) * ramp(lon, -83.5, -80.5);
    season * gulf.max(atlantic)
}

/// Great Plains wind-exposure weight (year-round corridor).
fn plains_weight(lat: f64, lon: f64) -> f64 {
    soft_box(lon, -105.5, -94.0, 3.0) * soft_box(lat, 27.0, 49.5, 3.0)
}

/// Climatological score for one bundle family at (lat, lon, week).
/// Families with no climatological basis return 0. Every non-zero score is in
/// [SCORE_FLOOR, SCORE_MAX] — a prior can never reach the 0.699 yellow cut.
fn family_score(family: &str, lat: f64, lon: f64, week: u32) -> f64 {
    let tropical = tropical_signal(lat, lon, week);
    let raw = match family {
        // Northern winter, latitude x mid-winter sinusoid (seed_rows physics).
        "winter" => 0.55 * winter_phase(week) * ramp(lat, 30.0, 47.0),
        // Cold stress: same season, biased further north.
        "cold" => 0.5 * winter_phase(week) * ramp(lat, 35.0, 48.0),
        // Convective season: plains + southeast, spring through summer.
        "convective" => {
            let season = if (10..=38).contains(&week) {
                (PI * (week as f64 - 10.0) / 28.0).sin()
            } else {
                0.0
            };
            let region = soft_box(lon, -105.0, -78.0, 5.0) * soft_box(lat, 26.0, 47.0, 5.0);
            0.45 * season * region
        }
        // Summer heat: desert southwest strongly, deep south moderately.
        "heat" => {
            let desert = soft_box(lon, -120.0, -103.0, 3.0) * soft_box(lat, 29.0, 38.5, 2.5);
            let south = 1.0 - ramp(lat, 30.0, 38.0);
            0.55 * summer_phase(week) * (desert + 0.45 * south).min(1.0)
        }
        // Plains exposure year-round + tropical-cyclone wind on the coast.
        "wind" => 0.3 * plains_weight(lat, lon) + 0.35 * tropical,
        // Gulf/southeast moisture baseline + tropical-cyclone rain.
        "qpf_flood" => {
            let southeast = (1.0 - ramp(lat, 30.0, 36.0)) * ramp(lon, -100.0, -92.0);
            0.15 * southeast + 0.45 * tropical
        }
        // environmental / fire / air / radiation / seismic: no seasonal
        // climatology basis in this baseline -> 0.
        _ => 0.0,
    };
    let s = raw.clamp(0.0, SCORE_MAX);   // == min(MAX).max(0) for these bounds
    if s < SCORE_FLOOR {
        0.0
    } else {
        s
    }
}

// ---------------------------------------------------------------- raw JSON scan

/// Byte-preserving split of the existing bundle:
/// (prefix up to the `"zips"` key, raw per-zip object slices, suffix after `]`).
/// A tiny depth/string-aware scanner — the R-engine entries are carried through
/// verbatim, never re-encoded.
fn split_bundle(text: &str) -> Result<(&str, Vec<&str>, &str), String> {
    let bytes = text.as_bytes();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut esc = false;
    let mut key_start: Option<usize> = None;
    let mut last_key: Option<(usize, usize)> = None; // (start of opening quote, end)
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
                            // find the '[' that opens the array
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
    // Scan the array items (objects), balancing braces / respecting strings.
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

/// Extract the string value of top-level key "z" from a raw zip object slice.
fn raw_zip_code(obj: &str) -> Option<String> {
    let bytes = obj.as_bytes();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut esc = false;
    let mut str_start = 0usize;
    let mut pending_key: Option<String> = None;
    let mut want_value = false;
    for (i, &b) in bytes.iter().enumerate() {
        if in_str {
            if esc {
                esc = false;
            } else if b == b'\\' {
                esc = true;
            } else if b == b'"' {
                in_str = false;
                let s = &obj[str_start + 1..i];
                if depth == 1 {
                    if want_value {
                        if pending_key.as_deref() == Some("z") {
                            return Some(s.to_string());
                        }
                        want_value = false;
                        pending_key = None;
                    } else {
                        pending_key = Some(s.to_string());
                    }
                }
            }
            continue;
        }
        match b {
            b'"' => {
                in_str = true;
                str_start = i;
            }
            b'{' | b'[' => depth += 1,
            b'}' | b']' => depth -= 1,
            b':' => {
                if depth == 1 && pending_key.is_some() {
                    want_value = true;
                }
            }
            b',' => {
                if depth == 1 {
                    pending_key = None;
                    want_value = false;
                }
            }
            _ => {}
        }
    }
    None
}

// ---------------------------------------------------------------- emit

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

/// Build one national entry's raw JSON: {"z":..,"c":[lon,lat],"s":[..],"t":..}
/// No "p" ring — the app fetches ZCTA rings on demand.
fn national_entry(z: &Zcta, families: &[String], week: u32) -> String {
    let scores: Vec<f64> =
        families.iter().map(|f| family_score(f, z.lat, z.lon, week)).collect();
    let s_json: Vec<String> = scores.iter().map(|&v| fmt_num(v, 3)).collect();
    let mut out = format!(
        "{{\"z\":\"{}\",\"c\":[{},{}],\"s\":[{}]",
        z.zip,
        fmt_num(z.lon, 4),
        fmt_num(z.lat, 4),
        s_json.join(",")
    );
    let mut top = 0usize;
    for (i, &v) in scores.iter().enumerate() {
        if v > scores[top] {
            top = i;
        }
    }
    if scores[top] > SUMMARY_MIN {
        out.push_str(&format!(
            ",\"t\":\"Seasonal baseline: elevated {} risk (climatology)\"",
            summary_family_label(&families[top])
        ));
    }
    out.push('}');
    out
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

// ---------------------------------------------------------------- main

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

fn run(week: u32) -> Result<(), String> {
    let root = find_repo_root()?;
    let bundle_path = root.join(BUNDLE_REL);
    let gaz_path = root.join(GAZ_REL);

    let original = fs::read_to_string(&bundle_path)
        .map_err(|e| format!("cannot read bundle {}: {e}", bundle_path.display()))?;
    let (prefix, kept_raw, suffix) = split_bundle(&original)?;
    let families = parse_families(prefix)?;

    let mut covered: Vec<String> = Vec::with_capacity(kept_raw.len());
    for e in &kept_raw {
        covered.push(raw_zip_code(e).ok_or("R-engine entry missing \"z\"")?);
    }
    let covered_set: std::collections::HashSet<&str> =
        covered.iter().map(String::as_str).collect();

    let mut zctas = read_gazetteer(&gaz_path)?;
    zctas.retain(|z| in_conus(z.lat, z.lon) && !covered_set.contains(z.zip.as_str()));
    zctas.sort_by(|a, b| a.zip.cmp(&b.zip));
    zctas.dedup_by(|a, b| a.zip == b.zip);

    let national: Vec<String> =
        zctas.iter().map(|z| national_entry(z, &families, week)).collect();

    // prefix ends just before the `"zips"` key (so its trailing ',' is intact);
    // inject metadata, then R-engine raw entries first, then national by zip.
    let mut out = String::with_capacity(original.len() + national.len() * 96);
    out.push_str(prefix);
    out.push_str("\"national_baseline\":true,\"national_week\":");
    out.push_str(&week.to_string());
    out.push_str(",\"zips\":[");
    let mut first = true;
    for e in kept_raw.iter().copied().chain(national.iter().map(String::as_str)) {
        if !first {
            out.push(',');
        }
        first = false;
        out.push_str(e);
    }
    out.push(']');
    out.push_str(suffix);

    // Atomic write: temp file in the same directory, then rename.
    let tmp = bundle_path.with_extension("json.tmp");
    fs::write(&tmp, &out).map_err(|e| format!("write {}: {e}", tmp.display()))?;
    fs::rename(&tmp, &bundle_path).map_err(|e| format!("rename onto bundle: {e}"))?;

    println!("families: {}", families.len());
    println!("r_engine_entries_kept: {}", kept_raw.len());
    println!("national_entries_added: {}", national.len());
    println!("total_entries: {}", kept_raw.len() + national.len());
    println!("bytes: {}", out.len());
    Ok(())
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let week: u32 = match args.get(1).and_then(|s| s.parse().ok()) {
        Some(w) if w <= 51 => w,
        _ => {
            eprintln!("usage: national-bundle <week 0-51>");
            std::process::exit(2);
        }
    };
    if let Err(e) = run(week) {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}

// ---------------------------------------------------------------- tests

#[cfg(test)]
mod tests {
    use super::*;

    const FAMS: [&str; 11] = [
        "environmental", "wind", "qpf_flood", "winter", "fire", "convective",
        "heat", "cold", "air", "radiation", "seismic",
    ];

    #[test]
    fn gazetteer_line_parses_with_trailing_padding() {
        let line = "53703\t166836392\t798613\t64.416\t0.308\t43.073051\t-89.385100                \t";
        let z = parse_gaz_line(line, 0, 5, 6).expect("line should parse");
        assert_eq!(z.zip, "53703");
        assert!((z.lat - 43.073051).abs() < 1e-9);
        assert!((z.lon + 89.3851).abs() < 1e-9);
        // header / malformed lines are rejected
        assert!(parse_gaz_line("GEOID\tA\tB\tC\tD\tINTPTLAT\tINTPTLONG", 0, 5, 6).is_none());
        assert!(parse_gaz_line("5370\t1\t2\t3\t4\t43.0\t-89.0", 0, 5, 6).is_none());
    }

    #[test]
    fn conus_filter() {
        assert!(in_conus(25.7617, -80.1918)); // Miami
        assert!(in_conus(47.6062, -122.3321)); // Seattle
        assert!(!in_conus(61.2181, -149.9003)); // Anchorage
        assert!(!in_conus(21.3069, -157.8583)); // Honolulu
        assert!(!in_conus(18.1806, -66.7500)); // San Juan (lat below 24)
    }

    #[test]
    fn scores_bounded_below_yellow_cut() {
        // grid over CONUS x every week x every family
        let mut lat = LAT_MIN;
        while lat <= LAT_MAX {
            let mut lon = LON_MIN;
            while lon <= LON_MAX {
                for week in 0..52 {
                    for f in FAMS {
                        let s = family_score(f, lat, lon, week);
                        assert!((0.0..=SCORE_MAX).contains(&s) && s < 0.699,
                            "{f} out of bounds at ({lat},{lon}) wk{week}: {s}");
                        assert!(s == 0.0 || s >= SCORE_FLOOR,
                            "{f} nonzero but under floor at ({lat},{lon}) wk{week}: {s}");
                    }
                }
                lon += 1.0;
            }
            lat += 1.0;
        }
    }

    #[test]
    fn no_basis_families_are_zero() {
        for f in ["environmental", "fire", "air", "radiation", "seismic"] {
            for week in [0, 13, 27, 36, 44] {
                assert_eq!(family_score(f, 36.0, -98.0, week), 0.0, "{f} wk{week}");
            }
        }
    }

    #[test]
    fn climatology_shape_spot_checks() {
        // Miami tropical season (week 36): coastal wind + flood present.
        assert!(family_score("qpf_flood", 25.76, -80.19, 36) > 0.3);
        assert!(family_score("wind", 25.76, -80.19, 36) > 0.2);
        // Miami mid-summer outside the window (week 27): no tropical bump.
        assert_eq!(tropical_signal(25.76, -80.19, 27), 0.0);
        // Minneapolis mid-winter: winter high; mid-summer: winter zero.
        assert!(family_score("winter", 44.98, -93.27, 0) > 0.4);
        assert_eq!(family_score("winter", 44.98, -93.27, 26), 0.0);
        // Phoenix summer heat.
        assert!(family_score("heat", 33.45, -112.07, 27) > 0.3);
        // Oklahoma plains wind, any season.
        assert!(family_score("wind", 35.47, -97.52, 5) > 0.2);
        // Miami has no winter risk ever.
        for week in 0..52 {
            assert_eq!(family_score("winter", 25.76, -80.19, week), 0.0);
        }
    }

    #[test]
    fn bundle_split_preserves_entries_byte_for_byte() {
        let src = concat!(
            "{\"generated_utc\":\"2026-07-04T11:39:45Z\",\"horizon\":\"live\",",
            "\"families\":[\"wind\",\"winter\"],\"zips\":[",
            "{\"z\":\"53703\",\"c\":[-89.3851,43.0731],\"s\":[0.1,0.2],",
            "\"t\":\"say \\\"hi\\\" {ok}\",\"p\":[[-89.4,43.0],[-89.3,43.1],[-89.4,43.1]]},",
            "{\"z\":\"53511\",\"c\":[-89.0,42.5],\"s\":[0,0.452]}",
            "]}"
        );
        let (prefix, entries, suffix) = split_bundle(src).expect("split");
        assert!(prefix.ends_with("\"families\":[\"wind\",\"winter\"],"));
        assert_eq!(suffix, "}");
        assert_eq!(entries.len(), 2);
        // byte-for-byte: raw slices reassemble to the original array body
        assert_eq!(
            format!("{}\"zips\":[{}]{}", prefix, entries.join(","), suffix),
            src
        );
        assert_eq!(raw_zip_code(entries[0]).as_deref(), Some("53703"));
        assert_eq!(raw_zip_code(entries[1]).as_deref(), Some("53511"));
    }

    #[test]
    fn families_parse_from_prefix() {
        let prefix = "{\"generated_utc\":\"x\",\"families\":[\"wind\",\"qpf_flood\"],";
        assert_eq!(parse_families(prefix).unwrap(), vec!["wind", "qpf_flood"]);
    }

    #[test]
    fn national_entry_shape() {
        let fams: Vec<String> = FAMS.iter().map(|s| s.to_string()).collect();
        // Miami in tropical season -> summary names flood, no "p" ring.
        let z = Zcta { zip: "33101".into(), lat: 25.7743, lon: -80.1937 };
        let e = national_entry(&z, &fams, 36);
        assert!(e.starts_with("{\"z\":\"33101\",\"c\":[-80.1937,25.7743],\"s\":["));
        assert!(e.contains("Seasonal baseline: elevated flood risk (climatology)"));
        assert!(!e.contains("\"p\":"));
        // Quiet zip/week -> no summary key at all.
        let q = Zcta { zip: "97201".into(), lat: 45.5, lon: -122.69 };
        let eq = national_entry(&q, &fams, 27);
        assert!(!eq.contains("\"t\":"));
    }

    #[test]
    fn number_formatting_is_minimal() {
        assert_eq!(fmt_num(0.45200000, 3), "0.452");
        assert_eq!(fmt_num(0.0, 3), "0");
        assert_eq!(fmt_num(-0.00001, 3), "0");
        assert_eq!(fmt_num(-89.38510, 4), "-89.3851");
        assert_eq!(fmt_num(0.15, 3), "0.15");
    }
}
