// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! airports-table — the North American airports that airlines actually fly
//! to, compiled into `flows-core` so the plane card never has to ask a map
//! search whether an airport exists.
//!
//! WHY: the plane card's only source of airports was one live MKLocalSearch
//! per trip end. An empty or throttled answer became "No flight fits this
//! trip" for a route with obvious service (Milwaukee → Augusta), and the
//! name filter rejected real airports whose names carry a military word.
//! A table settles it offline: it is small, it does not rate-limit, and it
//! knows which airports have SCHEDULED SERVICE, which no map search does.
//!
//! SOURCE: OurAirports `airports.csv` (<https://ourairports.com/data/>),
//! released to the public domain: "All data is released to the Public
//! Domain, and comes with no guarantee of accuracy or fitness for use."
//! Attribution is requested, not required; FLOWS credits it in Settings.
//!
//! Kept: `scheduled_service == yes`, a three-letter IATA code, an airport
//! type (not a heliport or a seaplane base), in the US, Canada or Mexico —
//! the app's ground. Everything else is dropped, which is what takes 86,116
//! rows down to a table worth compiling in.
//!
//! Usage: airports-table <airports.csv> <out.rs>
//! (the file it writes is `flows-core/src/airports_table.rs`, committed —
//! run it again when the source data is refreshed)

// 3.15: this crate holds no unsafe, and the compiler now keeps it that way.
#![forbid(unsafe_code)]

use std::env;
use std::fs;
use std::process;

/// One CSV line split on commas outside quotes, with `""` unescaped.
fn fields(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_quotes = false;
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' if in_quotes && chars.peek() == Some(&'"') => {
                cur.push('"');
                chars.next();
            }
            '"' => in_quotes = !in_quotes,
            ',' if !in_quotes => out.push(std::mem::take(&mut cur)),
            _ => cur.push(c),
        }
    }
    out.push(cur);
    out
}

/// The column index of each header this tool reads.
struct Columns {
    kind: usize,
    name: usize,
    lat: usize,
    lon: usize,
    country: usize,
    region: usize,
    municipality: usize,
    scheduled: usize,
    iata: usize,
}

impl Columns {
    fn find(header: &str) -> Result<Columns, String> {
        let names = fields(header);
        let at = |want: &str| -> Result<usize, String> {
            names
                .iter()
                .position(|n| n == want)
                .ok_or_else(|| format!("airports.csv has no {want:?} column"))
        };
        Ok(Columns {
            kind: at("type")?,
            name: at("name")?,
            lat: at("latitude_deg")?,
            lon: at("longitude_deg")?,
            country: at("iso_country")?,
            region: at("iso_region")?,
            municipality: at("municipality")?,
            scheduled: at("scheduled_service")?,
            iata: at("iata_code")?,
        })
    }
}

/// A Rust string literal's body: the source data carries quotes and
/// backslashes in a few names ("Gustavo Díaz Ordaz \"Puerto Vallarta\"").
fn escaped(text: &str) -> String {
    text.replace('\\', "\\\\").replace('"', "\\\"")
}

fn run(input: &str, output: &str) -> Result<(), String> {
    let csv = fs::read_to_string(input).map_err(|e| format!("cannot read {input}: {e}"))?;
    let mut lines = csv.lines();
    let header = lines.next().ok_or("airports.csv is empty")?;
    let col = Columns::find(header)?;
    let wanted_countries = ["US", "CA", "MX"];

    /// code, name, city, country, region, latitude, longitude, size
    type Row = (
        String,
        String,
        String,
        String,
        String,
        f64,
        f64,
        &'static str,
    );
    let mut rows: Vec<Row> = Vec::new();
    for line in lines {
        if line.trim().is_empty() {
            continue;
        }
        let f = fields(line);
        let get = |i: usize| f.get(i).map(String::as_str).unwrap_or("");
        if get(col.scheduled) != "yes" {
            continue;
        }
        let iata = get(col.iata).trim().to_ascii_uppercase();
        if iata.len() != 3 || !iata.chars().all(|c| c.is_ascii_uppercase()) {
            continue;
        }
        let country = get(col.country).trim().to_ascii_uppercase();
        if !wanted_countries.contains(&country.as_str()) {
            continue;
        }
        let size = match get(col.kind) {
            "large_airport" => "Size::Large",
            "medium_airport" => "Size::Medium",
            "small_airport" => "Size::Small",
            _ => continue,
        };
        let (Ok(lat), Ok(lon)) = (get(col.lat).parse::<f64>(), get(col.lon).parse::<f64>()) else {
            continue;
        };
        if !(-90.0..=90.0).contains(&lat) || !(-180.0..=180.0).contains(&lon) {
            continue;
        }
        rows.push((
            iata,
            get(col.name).trim().to_string(),
            get(col.municipality).trim().to_string(),
            country,
            get(col.region).trim().to_ascii_uppercase(),
            lat,
            lon,
            size,
        ));
    }
    rows.sort_by(|a, b| a.0.cmp(&b.0));
    rows.dedup_by(|a, b| a.0 == b.0);
    if rows.len() < 400 {
        return Err(format!(
            "only {} airports survived the filter — the source columns changed?",
            rows.len()
        ));
    }

    let mut out = String::with_capacity(rows.len() * 96 + 2048);
    out.push_str(
        "// -----------------------------------------------------------------------------\n\
         // Copyright (c) 2026 David B. Foster. All rights reserved.\n\
         // Contact: wizeman555@gmail.com\n\
         // Unauthorized copying, distribution, modification, or use of this file, in\n\
         // whole or in part, is strictly prohibited without the express written\n\
         // permission of the copyright holder.\n\
         // -----------------------------------------------------------------------------\n\n\
         //! GENERATED by `flows-train`'s `airports-table` from OurAirports'\n\
         //! public-domain `airports.csv` — do not edit by hand; run the tool again.\n\
         //!\n\
         //! Every airport in the US, Canada and Mexico that has an IATA code and\n\
         //! scheduled airline service. Source: <https://ourairports.com/data/>,\n\
         //! public domain.\n\n\
         use super::airports::{Airport, Size};\n\n",
    );
    out.push_str(&format!(
        "/// The table, sorted by IATA code ({} airports).\n\
         pub static AIRPORTS: &[Airport] = &[\n",
        rows.len()
    ));
    for (iata, name, muni, country, region, lat, lon, size) in &rows {
        out.push_str(&format!(
            "    Airport {{ iata: \"{iata}\", name: \"{}\", city: \"{}\", country: \"{country}\", \
             region: \"{region}\", lat: {lat:.6}, lon: {lon:.6}, size: {size} }},\n",
            escaped(name),
            escaped(muni)
        ));
    }
    out.push_str("];\n");
    fs::write(output, out).map_err(|e| format!("cannot write {output}: {e}"))?;
    println!("{} airports -> {output}", rows.len());
    Ok(())
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let (Some(input), Some(output)) = (args.get(1), args.get(2)) else {
        eprintln!("usage: airports-table <airports.csv> <out.rs>");
        process::exit(2);
    };
    if let Err(e) = run(input, output) {
        eprintln!("airports-table: {e}");
        process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quoted_fields_split_and_unescape() {
        let f = fields("\"1\",\"a,b\",\"say \"\"hi\"\"\",,\"x\"");
        assert_eq!(f, vec!["1", "a,b", "say \"hi\"", "", "x"]);
    }

    #[test]
    fn a_literal_keeps_quotes_and_backslashes_legal() {
        assert_eq!(escaped("Díaz \"PV\""), "Díaz \\\"PV\\\"");
        assert_eq!(escaped("a\\b"), "a\\\\b");
    }

    #[test]
    fn columns_are_found_by_name_not_position() {
        let header = "\"id\",\"ident\",\"type\",\"name\",\"latitude_deg\",\"longitude_deg\",\
                      \"elevation_ft\",\"continent\",\"iso_country\",\"iso_region\",\
                      \"municipality\",\"scheduled_service\",\"icao_code\",\"iata_code\"";
        let col = Columns::find(header).expect("columns");
        assert_eq!(col.kind, 2);
        assert_eq!(col.iata, 13);
        assert_eq!(col.scheduled, 11);
        assert!(Columns::find("\"id\",\"name\"").is_err());
    }
}
