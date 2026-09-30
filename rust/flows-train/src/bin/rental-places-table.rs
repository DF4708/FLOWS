// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! rental-places-table — DiscoverCars' own list of rental cities in the US,
//! Canada and Mexico, each with a map position, and the airports it lists as
//! pick-up locations, compiled into `flows-core` so every rental link FLOWS
//! builds is one DiscoverCars actually has.
//!
//! WHY: links built from map names 404'd wherever DiscoverCars names a place
//! its own way — "Mexico City" is `mexico/mexico`, "Quebec City" is
//! `canada/quebec`. Built from DiscoverCars' own slugs, they resolve.
//!
//! INPUTS come from `scripts/fetch_rental_places.sh` (DiscoverCars' landing-
//! page generator data; positions from public-domain sources, placed by
//! `rental-positions`):
//!   rental_cities.tsv:   country, region slug, name, city slug, lat, lon, population
//!   rental_airports.tsv: IATA code, region slug, city slug
//!
//! Usage: rental-places-table <rental_cities.tsv> <rental_airports.tsv> <out.rs>

// 3.15: this crate holds no unsafe, and the compiler now keeps it that way.
#![forbid(unsafe_code)]

use std::env;
use std::fs;
use std::process;

/// A Rust string literal's body, with invisible characters dropped.
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
}

/// A slug as DiscoverCars writes one: lowercase letters, digits and single
/// inner hyphens. Anything else in a column means the input is not what this
/// tool expects, and a malformed slug would make a broken link.
fn is_slug(s: &str) -> bool {
    !s.is_empty()
        && !s.starts_with('-')
        && !s.ends_with('-')
        && !s.contains("--")
        && s.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

struct City {
    country: String,
    region: String,
    name: String,
    slug: String,
    lat: f64,
    lon: f64,
}

fn read_cities(path: &str) -> Result<Vec<City>, String> {
    let text = fs::read_to_string(path).map_err(|e| format!("cannot read {path}: {e}"))?;
    let mut out = Vec::new();
    for (n, line) in text
        .lines()
        .enumerate()
        .filter(|(_, l)| !l.trim().is_empty())
    {
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 6 {
            return Err(format!("{path}:{}: expected 6+ columns", n + 1));
        }
        let (Ok(lat), Ok(lon)) = (f[4].parse::<f64>(), f[5].parse::<f64>()) else {
            return Err(format!("{path}:{}: bad position", n + 1));
        };
        if !matches!(f[0], "US" | "CA" | "MX") || !is_slug(f[1]) || !is_slug(f[3]) {
            return Err(format!("{path}:{}: bad country or slug in {line:?}", n + 1));
        }
        out.push(City {
            country: f[0].to_string(),
            region: f[1].to_string(),
            name: f[2].to_string(),
            slug: f[3].to_string(),
            lat,
            lon,
        });
    }
    out.sort_by(|a, b| (&a.region, &a.slug).cmp(&(&b.region, &b.slug)));
    out.dedup_by(|a, b| a.region == b.region && a.slug == b.slug);
    Ok(out)
}

fn read_airports(path: &str) -> Result<Vec<(String, String, String)>, String> {
    let text = fs::read_to_string(path).map_err(|e| format!("cannot read {path}: {e}"))?;
    let mut out = Vec::new();
    for (n, line) in text
        .lines()
        .enumerate()
        .filter(|(_, l)| !l.trim().is_empty())
    {
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 3
            || f[0].len() != 3
            || !f[0].bytes().all(|b| b.is_ascii_uppercase())
            || !is_slug(f[1])
            || !is_slug(f[2])
        {
            return Err(format!("{path}:{}: bad airport row {line:?}", n + 1));
        }
        out.push((f[0].to_string(), f[1].to_string(), f[2].to_string()));
    }
    out.sort();
    out.dedup_by(|a, b| a.0 == b.0);
    Ok(out)
}

fn run(args: &[String]) -> Result<(), String> {
    let (Some(cities), Some(airports), Some(output)) = (args.get(1), args.get(2), args.get(3))
    else {
        return Err(
            "usage: rental-places-table <rental_cities.tsv> <rental_airports.tsv> <out.rs>".into(),
        );
    };
    let cities = read_cities(cities)?;
    let airports = read_airports(airports)?;
    if cities.len() < 2000 {
        return Err(format!(
            "only {} cities — the inputs look wrong",
            cities.len()
        ));
    }
    // Every airport must point at a city in the table: its link is that
    // city's page plus the code, and a city that is not there is a 404.
    for (code, region, city) in &airports {
        if !cities
            .iter()
            .any(|c| &c.region == region && &c.slug == city)
        {
            return Err(format!(
                "{code} is filed under {region}/{city}, which is not in the city list"
            ));
        }
    }

    let mut out = String::with_capacity(cities.len() * 120 + airports.len() * 80 + 2048);
    out.push_str(
        "// -----------------------------------------------------------------------------\n\
         // Copyright (c) 2026 David B. Foster. All rights reserved.\n\
         // Contact: wizeman555@gmail.com\n\
         // Unauthorized copying, distribution, modification, or use of this file, in\n\
         // whole or in part, is strictly prohibited without the express written\n\
         // permission of the copyright holder.\n\
         // -----------------------------------------------------------------------------\n\n\
         //! GENERATED by `flows-train`'s `rental-places-table` from DiscoverCars'\n\
         //! landing-page generator data, with positions from public-domain sources\n\
         //! (US Census, USGS GNIS, Natural Earth, NGA GNS, OurAirports) — do not\n\
         //! edit by hand; run `scripts/fetch_rental_places.sh` and the tool again.\n\n\
         use super::rental_places::{RentalAirport, RentalCity};\n\n",
    );
    out.push_str(&format!(
        "/// DiscoverCars' rental cities, sorted by region then slug ({} cities).\n\
         pub static RENTAL_CITIES: &[RentalCity] = &[\n",
        cities.len()
    ));
    for c in &cities {
        out.push_str(&format!(
            "    RentalCity {{ country: \"{}\", region: \"{}\", name: \"{}\", slug: \"{}\", lat: {:.5}, lon: {:.5} }},\n",
            c.country,
            c.region,
            escaped(&c.name),
            c.slug,
            c.lat,
            c.lon
        ));
    }
    out.push_str("];\n\n");
    out.push_str(&format!(
        "/// Airports DiscoverCars lists as pick-up locations, sorted by code\n\
         /// ({} airports), each under the city it files them in.\n\
         pub static RENTAL_AIRPORTS: &[RentalAirport] = &[\n",
        airports.len()
    ));
    for (code, region, city) in &airports {
        out.push_str(&format!(
            "    RentalAirport {{ iata: \"{code}\", region: \"{region}\", city: \"{city}\" }},\n"
        ));
    }
    out.push_str("];\n");
    fs::write(output, out).map_err(|e| format!("cannot write {output}: {e}"))?;
    println!(
        "{} cities, {} airports -> {output}",
        cities.len(),
        airports.len()
    );
    Ok(())
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if let Err(e) = run(&args) {
        eprintln!("rental-places-table: {e}");
        process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugs_are_what_discovercars_writes() {
        assert!(is_slug("usa-illinois"));
        assert!(is_slug("st-louis"));
        assert!(is_slug("yyz"));
        assert!(!is_slug("St Louis"));
        assert!(!is_slug("-x"));
        assert!(!is_slug("a--b"));
        assert!(!is_slug(""));
        assert!(!is_slug("québec"));
    }

    #[test]
    fn names_keep_quotes_legal_and_drop_hidden_marks() {
        assert_eq!(escaped("Redwood City\u{200E}"), "Redwood City");
        assert_eq!(escaped("say \"hi\""), "say \\\"hi\\\"");
    }
}
