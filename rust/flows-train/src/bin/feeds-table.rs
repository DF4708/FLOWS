// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! feeds-table — every public-transit timetable in the US, Canada and Mexico
//! that can be downloaded WITHOUT an API key, compiled into `flows-core` so
//! the train card can find the city bus at the end of a trip with no service
//! of our own to ask.
//!
//! SOURCE: MobilityData's Mobility Database catalog
//! (<https://github.com/MobilityData/mobility-database-catalogs>, the CSV at
//! <https://bit.ly/catalogs-csv>). The catalog itself needs no account; its
//! API does. Each FEED keeps its own publisher's terms — the table carries
//! each one's licence link where the catalog has one, so the app can show it.
//!
//! Kept: static GTFS, in the US, Canada or Mexico, whose download needs no
//! key (`urls.authentication_type` empty or 0), with a direct download link,
//! a usable bounding box, not marked deprecated or inactive, and not
//! redirected to a newer entry. The owner's rule (2026-09-29): "Include API
//! key free ones by default as primary."
//!
//! Usage:
//!   feeds-table <catalog.csv> <out.rs>
//!       [--coverage <targets.tsv>]   report which capitals / largest cities
//!                                    have a feed (see the TSV format below)
//!       [--licences <out.tsv>]       dump the feeds that state a licence
//!
//! targets.tsv: country, admin1, region name, role, city, lat, lon, population
//! (tab-separated, one place per line — built from GeoNames).

// 3.15: this crate holds no unsafe, and the compiler now keeps it that way.
#![forbid(unsafe_code)]

use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::process;

/// Every record of a CSV file, honouring RFC 4180: commas and line breaks
/// inside quotes are data, and `""` inside quotes is one quote. The catalog's
/// free-text `note` column carries both, so a line-at-a-time split would
/// shear records in two.
fn records(text: &str) -> Vec<Vec<String>> {
    let mut out = Vec::new();
    let mut row = Vec::new();
    let mut cur = String::new();
    let mut in_quotes = false;
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' if in_quotes && chars.peek() == Some(&'"') => {
                cur.push('"');
                chars.next();
            }
            '"' => in_quotes = !in_quotes,
            ',' if !in_quotes => row.push(std::mem::take(&mut cur)),
            '\r' if !in_quotes => {}
            '\n' if !in_quotes => {
                row.push(std::mem::take(&mut cur));
                if row.iter().any(|f| !f.is_empty()) {
                    out.push(std::mem::take(&mut row));
                } else {
                    row.clear();
                }
            }
            _ => cur.push(c),
        }
    }
    if !cur.is_empty() || !row.is_empty() {
        row.push(cur);
        out.push(row);
    }
    out
}

/// Licences read by hand on 2026-09-29 that forbid commercial use without the
/// publisher's written permission. FLOWS earns referral fees, which makes its
/// use commercial, so these feeds are kept in the table but marked, and the app
/// leaves them out until permission is on file. Each entry is a piece of the
/// licence link and the words that decided it.
const NEEDS_PERMISSION: &[(&str, &str)] = &[
    (
        "kitsaptransit.com",
        "commercial use … expressly prohibited without the written permission",
    ),
    (
        "data.whitehorse.ca",
        "not … for commercial purposes, without the prior written consent",
    ),
    (
        "stlaval.ca",
        "aucune utilisation commerciale … sans l'autorisation … par écrit",
    ),
    ("rtcwashoe.com", "personal, noncommercial use only"),
    (
        "rabaride.com",
        "commercial purposes without RABA's express prior written consent",
    ),
    (
        "proxy.busone.app",
        "per usi commerciali … contatta prima (commercial use: contact first)",
    ),
    (
        "metrobus.com/gtfs",
        "you must identify … whether the use … is for commercial purposes",
    ),
];

/// A Rust string literal's body. Invisible characters are dropped, not
/// escaped: the catalog has zero-width spaces inside names ("Metropolitan Area
/// of \u{200B}\u{200B}Guadalajara") that would ride into the app's text unseen.
fn escaped(text: &str) -> String {
    text.chars()
        .filter(|c| {
            !matches!(
                c,
                '\u{200B}'..='\u{200F}' | '\u{2060}' | '\u{FEFF}' | '\u{00AD}'
            )
        })
        .collect::<String>()
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace(['\n', '\r'], " ")
}

struct Feed {
    /// The catalog's id: "mdb-1234", "tld-764", "ntd-80003" in the current
    /// export; a bare number in the older one, which is given the "mdb-" form.
    id: String,
    country: String,
    region: String,
    city: String,
    provider: String,
    name: String,
    url: String,
    mirror: String,
    licence: String,
    official: bool,
    /// Its licence forbids commercial use without written permission (see
    /// [`NEEDS_PERMISSION`]).
    needs_permission: bool,
    /// "active" in the catalog. An inactive feed is kept but ranked after
    /// active ones: the catalog has stopped maintaining it, which is not the
    /// same as the agency having stopped publishing (Milwaukee's is marked
    /// inactive). The app already skips a lapsed or unreachable city feed.
    active: bool,
    min_lat: f64,
    max_lat: f64,
    min_lon: f64,
    max_lon: f64,
}

impl Feed {
    fn covers(&self, lat: f64, lon: f64) -> bool {
        (self.min_lat..=self.max_lat).contains(&lat) && (self.min_lon..=self.max_lon).contains(&lon)
    }

    /// Rough area in square degrees — only ever compared with another's.
    fn area(&self) -> f64 {
        (self.max_lat - self.min_lat) * (self.max_lon - self.min_lon)
    }
}

/// The rows kept, and a count of why each other row was dropped.
fn select(rows: &[Vec<String>]) -> Result<(Vec<Feed>, BTreeMap<String, usize>), String> {
    let header = rows.first().ok_or("the catalog is empty")?;
    let at = |want: &str| -> Result<usize, String> {
        header
            .iter()
            .position(|h| h == want)
            .ok_or_else(|| format!("the catalog has no {want:?} column"))
    };
    // The current export (feeds_v2.csv) names it "id"; the older one
    // (sources.csv) "mdb_source_id".
    let c_id = at("id").or_else(|_| at("mdb_source_id"))?;
    let c_type = at("data_type")?;
    let c_country = at("location.country_code")?;
    let c_region = at("location.subdivision_name")?;
    let c_city = at("location.municipality")?;
    let c_provider = at("provider")?;
    let c_official = at("is_official")?;
    let c_name = at("name")?;
    let c_url = at("urls.direct_download")?;
    let c_auth = at("urls.authentication_type")?;
    let c_latest = at("urls.latest")?;
    let c_licence = at("urls.license")?;
    let c_min_lat = at("location.bounding_box.minimum_latitude")?;
    let c_max_lat = at("location.bounding_box.maximum_latitude")?;
    let c_min_lon = at("location.bounding_box.minimum_longitude")?;
    let c_max_lon = at("location.bounding_box.maximum_longitude")?;
    let c_status = at("status")?;
    let c_redirect = at("redirect.id")?;

    let mut kept = Vec::new();
    let mut dropped: BTreeMap<String, usize> = BTreeMap::new();
    let mut drop = |why: &str| *dropped.entry(why.to_string()).or_default() += 1;
    for r in &rows[1..] {
        let get = |i: usize| r.get(i).map(|s| s.trim()).unwrap_or("");
        if get(c_type) != "gtfs" {
            drop("not static GTFS");
            continue;
        }
        let country = get(c_country).to_ascii_uppercase();
        if !matches!(country.as_str(), "US" | "CA" | "MX") {
            drop("outside US/CA/MX");
            continue;
        }
        if !matches!(get(c_auth), "" | "0") {
            drop("needs an API key or login");
            continue;
        }
        // The publisher's own link when it gives one; otherwise MobilityData's
        // mirror of the latest copy, which serves byte ranges like any bucket.
        let is_link = |s: &str| s.starts_with("https://") || s.starts_with("http://");
        let url = if is_link(get(c_url)) {
            get(c_url)
        } else if is_link(get(c_latest)) {
            get(c_latest)
        } else {
            drop("no download link at all");
            continue;
        };
        let status = get(c_status).to_ascii_lowercase();
        // Deprecated means REPLACED by another entry; inactive only means the
        // catalog stopped maintaining it, so it stays (ranked last).
        if status == "deprecated" {
            drop("deprecated (replaced by another entry)");
            continue;
        }
        if !get(c_redirect).is_empty() {
            drop("redirected to a newer entry");
            continue;
        }
        let num = |i: usize| get(i).parse::<f64>().ok().filter(|v| v.is_finite());
        let (Some(min_lat), Some(max_lat), Some(min_lon), Some(max_lon)) = (
            num(c_min_lat),
            num(c_max_lat),
            num(c_min_lon),
            num(c_max_lon),
        ) else {
            drop("no bounding box");
            continue;
        };
        // A box the wrong way round, or one spanning most of the continent,
        // cannot say which city a trip ends in.
        if min_lat >= max_lat
            || min_lon >= max_lon
            || max_lat - min_lat > 25.0
            || max_lon - min_lon > 40.0
        {
            drop("unusable bounding box");
            continue;
        }
        let raw_id = get(c_id);
        if raw_id.is_empty() {
            drop("no source id");
            continue;
        }
        let id = if raw_id.bytes().all(|b| b.is_ascii_digit()) {
            format!("mdb-{raw_id}")
        } else {
            raw_id.to_string()
        };
        kept.push(Feed {
            id,
            country,
            region: get(c_region).to_string(),
            city: get(c_city).to_string(),
            provider: get(c_provider).to_string(),
            name: get(c_name).to_string(),
            url: url.to_string(),
            mirror: get(c_latest).to_string(),
            licence: get(c_licence).to_string(),
            official: get(c_official).eq_ignore_ascii_case("true"),
            needs_permission: NEEDS_PERMISSION
                .iter()
                .any(|(host, _)| get(c_licence).contains(host) || url.contains(host)),
            active: status != "inactive",
            min_lat,
            max_lat,
            min_lon,
            max_lon,
        });
    }
    kept.sort_by(|a, b| a.id.cmp(&b.id));
    kept.dedup_by(|a, b| a.id == b.id);
    Ok((kept, dropped))
}

fn write_table(feeds: &[Feed], output: &str) -> Result<(), String> {
    let mut out = String::with_capacity(feeds.len() * 420 + 4096);
    out.push_str(
        "// -----------------------------------------------------------------------------\n\
         // Copyright (c) 2026 David B. Foster. All rights reserved.\n\
         // Contact: wizeman555@gmail.com\n\
         // Unauthorized copying, distribution, modification, or use of this file, in\n\
         // whole or in part, is strictly prohibited without the express written\n\
         // permission of the copyright holder.\n\
         // -----------------------------------------------------------------------------\n\n\
         //! GENERATED by `flows-train`'s `feeds-table` from MobilityData's Mobility\n\
         //! Database catalog — do not edit by hand; run the tool again.\n\
         //!\n\
         //! Every static GTFS feed in the US, Canada and Mexico downloadable without\n\
         //! an API key. Each feed keeps its own publisher's terms; `licence` is the\n\
         //! catalog's link to them where it has one, empty where it has none.\n\n\
         use super::feeds::CityFeed;\n\n",
    );
    out.push_str(&format!(
        "/// The table, sorted by catalog id ({} feeds).\n\
         pub static CITY_FEEDS: &[CityFeed] = &[\n",
        feeds.len()
    ));
    for f in feeds {
        out.push_str(&format!(
            "    CityFeed {{ id: \"{}\", country: \"{}\", region: \"{}\", city: \"{}\", provider: \"{}\", \
             name: \"{}\", url: \"{}\", mirror: \"{}\", licence: \"{}\", official: {}, needs_permission: {}, active: {}, \
             min_lat: {:.6}, max_lat: {:.6}, min_lon: {:.6}, max_lon: {:.6} }},\n",
            escaped(&f.id),
            f.country,
            escaped(&f.region),
            escaped(&f.city),
            escaped(&f.provider),
            escaped(&f.name),
            escaped(&f.url),
            escaped(&f.mirror),
            escaped(&f.licence),
            f.official,
            f.needs_permission,
            f.active,
            f.min_lat,
            f.max_lat,
            f.min_lon,
            f.max_lon
        ));
    }
    out.push_str("];\n");
    fs::write(output, out).map_err(|e| format!("cannot write {output}: {e}"))
}

/// For every target place, the feeds whose box holds it — best first by the
/// same rule the app uses (official feeds, then the smallest box) — and a
/// list of places with none.
fn coverage(feeds: &[Feed], targets: &str) -> Result<(), String> {
    let text = fs::read_to_string(targets).map_err(|e| format!("cannot read {targets}: {e}"))?;
    let mut gaps = Vec::new();
    let mut n = 0usize;
    let mut by_country: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        let t: Vec<&str> = line.split('\t').collect();
        if t.len() < 8 {
            continue;
        }
        let (country, region, role, city) = (t[0], t[2], t[3], t[4]);
        let (Ok(lat), Ok(lon)) = (t[5].parse::<f64>(), t[6].parse::<f64>()) else {
            continue;
        };
        n += 1;
        let mut hits: Vec<&Feed> = feeds
            .iter()
            .filter(|f| !f.needs_permission && f.covers(lat, lon))
            .collect();
        hits.sort_by(|a, b| {
            b.official
                .cmp(&a.official)
                .then(b.active.cmp(&a.active))
                .then(a.area().total_cmp(&b.area()))
        });
        let entry = by_country.entry(country.to_string()).or_default();
        entry.0 += 1;
        if hits.is_empty() {
            gaps.push(format!("{country}  {region:<24} {role:<16} {city}"));
        } else {
            entry.1 += 1;
        }
        let best: Vec<String> = hits
            .iter()
            .take(3)
            .map(|f| format!("{} [{}]", f.provider, f.id))
            .collect();
        println!(
            "{country}\t{region}\t{role}\t{city}\t{}\t{}",
            hits.len(),
            best.join("; ")
        );
    }
    println!("\n== coverage ==");
    for (c, (all, have)) in &by_country {
        println!("{c}: {have} of {all} places have at least one API-key-free feed");
    }
    println!("{} places checked; {} with none:", n, gaps.len());
    for g in &gaps {
        println!("  {g}");
    }
    Ok(())
}

fn run(args: &[String]) -> Result<(), String> {
    let (Some(input), Some(output)) = (args.get(1), args.get(2)) else {
        return Err(
            "usage: feeds-table <catalog.csv> <out.rs> [--coverage targets.tsv] \
                    [--licences out.tsv]"
                .into(),
        );
    };
    let text = fs::read_to_string(input).map_err(|e| format!("cannot read {input}: {e}"))?;
    let rows = records(&text);
    let (feeds, dropped) = select(&rows)?;
    if feeds.len() < 300 {
        return Err(format!(
            "only {} feeds survived the filter — the catalog's columns changed?",
            feeds.len()
        ));
    }
    write_table(&feeds, output)?;

    let mut by_country: BTreeMap<&str, usize> = BTreeMap::new();
    for f in &feeds {
        *by_country.entry(f.country.as_str()).or_default() += 1;
    }
    println!(
        "{} catalog rows; kept {} feeds -> {output}",
        rows.len() - 1,
        feeds.len()
    );
    for (c, k) in &by_country {
        println!("  {c}: {k}");
    }
    println!(
        "  stating a licence: {}; marked official: {}",
        feeds.iter().filter(|f| !f.licence.is_empty()).count(),
        feeds.iter().filter(|f| f.official).count()
    );
    println!(
        "  needing written permission for commercial use (left out by the app): {}",
        feeds.iter().filter(|f| f.needs_permission).count()
    );
    println!("dropped:");
    for (why, k) in &dropped {
        println!("  {k:>5}  {why}");
    }

    let mut i = 3;
    while i < args.len() {
        match args[i].as_str() {
            "--coverage" => {
                let path = args.get(i + 1).ok_or("--coverage needs a file")?;
                println!();
                coverage(&feeds, path)?;
                i += 2;
            }
            "--licences" => {
                let path = args.get(i + 1).ok_or("--licences needs a file")?;
                let mut out = String::new();
                for f in feeds.iter().filter(|f| !f.licence.is_empty()) {
                    out.push_str(&format!(
                        "{}\t{}\t{}\t{}\t{}\n",
                        f.id, f.country, f.provider, f.name, f.licence
                    ));
                }
                fs::write(path, out).map_err(|e| format!("cannot write {path}: {e}"))?;
                i += 2;
            }
            other => return Err(format!("unknown option {other:?}")),
        }
    }
    Ok(())
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if let Err(e) = run(&args) {
        eprintln!("feeds-table: {e}");
        process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_hold_commas_and_line_breaks() {
        let rows = records("a,b,c\n1,\"x, y\",\"two\nlines\"\n2,\"say \"\"hi\"\"\",\r\n");
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[1], vec!["1", "x, y", "two\nlines"]);
        assert_eq!(rows[2], vec!["2", "say \"hi\"", ""]);
    }

    #[test]
    fn a_literal_stays_legal() {
        assert_eq!(escaped("a \"b\"\\c\nd"), "a \\\"b\\\"\\\\c d");
        assert_eq!(
            escaped("of \u{200B}\u{200B}Guadalajara"),
            "of Guadalajara",
            "no hidden characters"
        );
    }

    fn catalog(rows: &[&str]) -> Vec<Vec<String>> {
        let header = "mdb_source_id,data_type,entity_type,location.country_code,\
            location.subdivision_name,location.municipality,provider,is_official,\
            is_producer_url_unstable,is_seasonal,name,note,feed_contact_email,static_reference,\
            urls.direct_download,urls.authentication_type,urls.authentication_info,\
            urls.api_key_parameter_name,urls.latest,urls.license,\
            location.bounding_box.minimum_latitude,location.bounding_box.maximum_latitude,\
            location.bounding_box.minimum_longitude,location.bounding_box.maximum_longitude,\
            location.bounding_box.extracted_on,status,features,redirect.id,redirect.comment";
        let mut text = header.to_string();
        for r in rows {
            text.push('\n');
            text.push_str(r);
        }
        text.push('\n');
        records(&text)
    }

    #[test]
    fn only_key_free_north_american_static_feeds_are_kept() {
        let rows = catalog(&[
            // kept
            "1,gtfs,,US,Illinois,Chicago,CTA,True,False,False,,,,,https://x/cta.zip,,,,https://m/1.zip,https://lic,41.6,42.1,-87.95,-87.5,,active,,,",
            // needs a key
            "2,gtfs,,US,New York,New York,MTA,True,False,False,,,,,https://x/mta.zip,2,,api_key,,,40.4,41.0,-74.3,-73.7,,active,,,",
            // realtime, not static
            "3,gtfs-rt,vp,US,Illinois,Chicago,CTA,True,False,False,,,,,https://x/rt,,,,,,41.6,42.1,-87.95,-87.5,,active,,,",
            // outside NA
            "4,gtfs,,FR,Paris,Paris,RATP,True,False,False,,,,,https://x/ratp.zip,,,,,,48.8,48.9,2.2,2.5,,active,,,",
            // deprecated
            "5,gtfs,,CA,Ontario,Toronto,TTC,True,False,False,,,,,https://x/ttc.zip,,,,,,43.5,43.9,-79.7,-79.1,,deprecated,,,",
            // redirected to a newer entry
            "6,gtfs,,MX,Jalisco,Guadalajara,SITEUR,False,False,False,,,,,https://x/gdl.zip,,,,,,20.5,20.8,-103.5,-103.2,,active,,7,",
            // no box
            "8,gtfs,,US,Texas,Austin,CapMetro,True,False,False,,,,,https://x/cm.zip,0,,,,,,,,,,active,,,",
        ]);
        let (kept, dropped) = select(&rows).unwrap();
        assert_eq!(
            kept.iter().map(|f| f.id.as_str()).collect::<Vec<_>>(),
            vec!["mdb-1"]
        );
        assert!(kept[0].official);
        assert_eq!(kept[0].licence, "https://lic");
        assert_eq!(dropped.values().sum::<usize>(), 6);
    }
}
