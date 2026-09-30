// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! rental-positions — a map position for each of DiscoverCars' rental cities,
//! from public-domain sources only.
//!
//! WHY: the positions came from GeoNames (CC BY 4.0). The owner's rule
//! (2026-09-30): where a public-domain source can do the job, FLOWS uses it,
//! so the app owes nothing to anyone for its data.
//!
//! SOURCES, all public domain (US government works, or released as such):
//!   US:       the Census Bureau's gazetteers — places (cities, villages,
//!             census-designated places) and county subdivisions (the
//!             townships and towns that are New Jersey's, New York's and New
//!             England's municipalities) — sized by its 2024 estimates, and by
//!             its 2010 count for the census-designated places the estimates
//!             skip; USGS GNIS populated places for each town's centre.
//!   Canada,   Natural Earth populated places (with population), and NGA's
//!   Mexico:   GEOnet Names Server populated places ("no licensing
//!             requirements or restrictions").
//!   Airports: FLOWS's own table (OurAirports, public domain).
//!
//! HOW, for each city name (and its variants: "Quebec City" is "Québec"):
//!   Airports serving the city are the ones DiscoverCars files under it, else
//!   ones named for it.
//!   US: the name's main Census place is its most populous — a township only
//!   when it holds over ten times the people of any place of the name. A GNIS
//!   centre inside it wins: the Census point is the middle of the boundary,
//!   and San Francisco's takes in the Farallon Islands, putting it in the
//!   Pacific. A lone GNIS point far from every Census place of the name is a
//!   crossroads sharing it (Four Corners by Tampa, not the town by Disney
//!   World).
//!   Canada and Mexico: with airports, the biggest listed place by one
//!   (Natural Earth files a "Mazatlán, Sonora" at Hermosillo; Deer Lake has an
//!   airport in Newfoundland and in Ontario); else Natural Earth's biggest;
//!   else GNS's only place, or its one seat of government among several.
//!   Still several: the one other rental cities crowd around, when the crowd
//!   is eight times any rival's (Queens' Elmhurst, not the one by Jamestown).
//!   Still nothing: an airport serving the city.
//! A city none of them places is left out: a traveller near it gets the
//! nearest placed city, or the state or country page.
//!
//! Usage: rental-positions <cities.tsv> <places.txt> <cousubs.txt>
//!            <places2010.txt> <sub-est.csv> <gnis.txt> <ne_camx.tsv>
//!            <gns_ca.txt> <gns_mx.txt> <airports.tsv> <rental_airports.tsv>
//!            <out.tsv>
//!   cities.tsv:          country, region slug, name, city slug, then any
//!                        columns to pass through (the fetch script's city id)
//!   places.txt:          Census 2025_Gaz_place_national.txt
//!   cousubs.txt:         Census 2025_Gaz_cousubs_national.txt
//!   places2010.txt:      Census Gaz_places_national.txt (2010, with POP10)
//!   sub-est.csv:         Census sub-est2024.csv (city and town estimates)
//!   gnis.txt:            USGS DomesticNames_National.txt
//!   ne_camx.tsv:         iso_a2, name, admin-1 name, latitude, longitude,
//!                        pop_max
//!   gns_ca/gns_mx.txt:   NGA GNS Canada.zip / Mexico.zip,
//!                        fc_files/Populated_Places.txt
//!   airports.tsv:        IATA, city, country, region, lat, lon (from
//!                        airports_table.rs)
//!   rental_airports.tsv: IATA, region slug, city slug (DiscoverCars' filings)
//!   out.tsv:             country, region slug, name, city slug, lat, lon,
//!                        people (0 when no source counts them), then the
//!                        passed-through columns (rental-places-table's input)

#![forbid(unsafe_code)]

use std::collections::HashMap;
use std::env;
use std::fs;
use std::process;

/// USPS code → state name, for the Census files (GNIS spells names out).
const STATES: &[(&str, &str)] = &[
    ("AL", "Alabama"),
    ("AK", "Alaska"),
    ("AZ", "Arizona"),
    ("AR", "Arkansas"),
    ("CA", "California"),
    ("CO", "Colorado"),
    ("CT", "Connecticut"),
    ("DE", "Delaware"),
    ("DC", "District of Columbia"),
    ("FL", "Florida"),
    ("GA", "Georgia"),
    ("HI", "Hawaii"),
    ("ID", "Idaho"),
    ("IL", "Illinois"),
    ("IN", "Indiana"),
    ("IA", "Iowa"),
    ("KS", "Kansas"),
    ("KY", "Kentucky"),
    ("LA", "Louisiana"),
    ("ME", "Maine"),
    ("MD", "Maryland"),
    ("MA", "Massachusetts"),
    ("MI", "Michigan"),
    ("MN", "Minnesota"),
    ("MS", "Mississippi"),
    ("MO", "Missouri"),
    ("MT", "Montana"),
    ("NE", "Nebraska"),
    ("NV", "Nevada"),
    ("NH", "New Hampshire"),
    ("NJ", "New Jersey"),
    ("NM", "New Mexico"),
    ("NY", "New York"),
    ("NC", "North Carolina"),
    ("ND", "North Dakota"),
    ("OH", "Ohio"),
    ("OK", "Oklahoma"),
    ("OR", "Oregon"),
    ("PA", "Pennsylvania"),
    ("RI", "Rhode Island"),
    ("SC", "South Carolina"),
    ("SD", "South Dakota"),
    ("TN", "Tennessee"),
    ("TX", "Texas"),
    ("UT", "Utah"),
    ("VT", "Vermont"),
    ("VA", "Virginia"),
    ("WA", "Washington"),
    ("WV", "West Virginia"),
    ("WI", "Wisconsin"),
    ("WY", "Wyoming"),
    ("PR", "Puerto Rico"),
];

/// A name as it is compared: lowercase, accents folded, punctuation and
/// spaces dropped ("Water Mill" is "Watermill", "La Plata" "Laplata"),
/// "saint"/"st." one word, as are "mount"/"mt.", "fort"/"ft.", "point"/"pt.".
fn key(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    for c in name.chars() {
        let c = match c {
            'á' | 'à' | 'â' | 'ä' | 'ã' | 'å' | 'ā' | 'Á' | 'À' | 'Â' | 'Ä' | 'Ã' | 'Å' | 'Ā' => {
                'a'
            }
            'é' | 'è' | 'ê' | 'ë' | 'ē' | 'É' | 'È' | 'Ê' | 'Ë' | 'Ē' => 'e',
            'í' | 'ì' | 'î' | 'ï' | 'ī' | 'Í' | 'Ì' | 'Î' | 'Ï' | 'Ī' => 'i',
            'ó' | 'ò' | 'ô' | 'ö' | 'õ' | 'ō' | 'Ó' | 'Ò' | 'Ô' | 'Ö' | 'Õ' | 'Ō' => {
                'o'
            }
            'ú' | 'ù' | 'û' | 'ü' | 'ū' | 'Ú' | 'Ù' | 'Û' | 'Ü' | 'Ū' => 'u',
            'ñ' | 'Ñ' => 'n',
            'ç' | 'Ç' => 'c',
            // Hawaiian ʻokina and the apostrophes: dropped ("Lānaʻi" is "Lanai").
            'ʻ' | '’' | '‘' | '\'' => continue,
            c => c,
        };
        if c.is_alphanumeric() {
            out.extend(c.to_lowercase());
        } else if !out.ends_with(' ') {
            out.push(' ');
        }
    }
    out.split_whitespace()
        .map(|w| match w {
            "saint" => "st",
            "sainte" => "ste",
            "mount" => "mt",
            "fort" => "ft",
            "point" => "pt",
            w => w,
        })
        .collect()
}

/// The names a Census place goes by, without its legal description:
/// "Milwaukee city" → "Milwaukee", "Edison township" → "Edison", "Boise City
/// city" → "Boise City", "Indianapolis city (balance)" → "Indianapolis", and
/// "San Buenaventura (Ventura) city" → both "San Buenaventura" and "Ventura".
/// The description is the trailing run of lowercase words (and "CDP").
/// Also the name a traveller uses for a consolidated city ("Nashville-
/// Davidson metropolitan government (balance)" → "Nashville",
/// "Louisville/Jefferson County …" → "Louisville", "Macon-Bibb County" →
/// "Macon"), a township joined to another ("Parsippany-Troy Hills" →
/// "Parsippany"), a Massachusetts city that keeps "Town" ("Braintree Town
/// city" → "Braintree"), and "Urban Honolulu" → "Honolulu".
fn census_names(raw: &str, subdivision: bool) -> Vec<String> {
    let raw = raw.trim();
    let joined = subdivision
        || raw.ends_with("(balance)")
        || raw.contains(" government")
        || raw.contains(" urban county")
        || raw.ends_with(" County");
    let raw = raw.trim_end_matches("(balance)").trim();
    let mut words: Vec<&str> = raw.split(' ').collect();
    while words.len() > 1 {
        let last = words[words.len() - 1];
        let described = last == "CDP" || last.chars().next().is_some_and(|c| c.is_lowercase());
        if !described {
            break;
        }
        words.pop();
    }
    let name = words.join(" ");
    let mut out = match (name.find(" ("), name.strip_suffix(')')) {
        (Some(open), Some(inner)) => vec![name[..open].to_string(), inner[open + 2..].to_string()],
        _ => vec![name.clone()],
    };
    if let Some((first, _)) = name.split_once(['-', '/']).filter(|_| joined) {
        out.push(first.to_string());
    }
    if let Some(bare) = name.strip_suffix(" Town").filter(|b| !b.is_empty()) {
        out.push(bare.to_string());
    }
    if let Some(bare) = name.strip_prefix("Urban ") {
        out.push(bare.to_string());
    }
    out
}

/// Kilometres between two (lat, lon) points, great circle.
fn km(a: (f64, f64), b: (f64, f64)) -> f64 {
    let (la1, lo1, la2, lo2) = (
        a.0.to_radians(),
        a.1.to_radians(),
        b.0.to_radians(),
        b.1.to_radians(),
    );
    let x = ((la2 - la1) / 2.0).sin().powi(2)
        + la1.cos() * la2.cos() * ((lo2 - lo1) / 2.0).sin().powi(2);
    12_742.0 * x.sqrt().atan2((1.0 - x).sqrt())
}

/// A Census place or town: its middle point, land and water (m²), people
/// (0 when the Census gives no count), and whether it governs itself (else a
/// census-designated place).
struct CensusPlace {
    at: (f64, f64),
    land: f64,
    water: f64,
    people: f64,
    governed: bool,
}

impl CensusPlace {
    /// Whether `point` (a GNIS town centre) is this place: within 2.5 times
    /// the radius of a circle its size, plus 3 km — Anchorage's middle is 33
    /// km from its downtown and Yuma's 25, while a Hamilton 35 km from
    /// Hamilton Township's is another town. A place mostly water (San
    /// Francisco, the Farallon Islands in it) has its middle out at sea, so it
    /// cannot say, and counts.
    fn holds(&self, point: (f64, f64)) -> bool {
        let radius_km = ((self.land + self.water) / std::f64::consts::PI).sqrt() / 1000.0;
        self.water > self.land || km(self.at, point) <= 2.5 * radius_km + 3.0
    }
}

/// Of a name's Census places, the one a traveller means: the most people,
/// then a governed place before a census-designated one, then the bigger.
fn main_place(places: &[CensusPlace]) -> Option<&CensusPlace> {
    places.iter().max_by(|a, b| {
        (a.people, a.governed, a.land)
            .partial_cmp(&(b.people, b.governed, b.land))
            .unwrap_or(std::cmp::Ordering::Equal)
    })
}

/// The index of the biggest of `cands` (lat, lon, size) within 50 km of one
/// of `anchors` (airports) — nearest one when sizes tie.
fn by_airport(anchors: &[(f64, f64)], cands: &[(f64, f64, f64)]) -> Option<usize> {
    cands
        .iter()
        .enumerate()
        .filter_map(|(i, &(lat, lon, size))| {
            let d = anchors
                .iter()
                .map(|a| km((lat, lon), *a))
                .fold(f64::INFINITY, f64::min);
            (d <= 50.0).then_some((size, -d, i))
        })
        .max_by(|a, b| a.0.total_cmp(&b.0).then(a.1.total_cmp(&b.1)))
        .map(|(_, _, i)| i)
}

/// Names whose only public-domain match is another town: GNS lists just a
/// Prince Edward Island hamlet called Surrey, not the BC city DiscoverCars
/// rents in. Better unplaced (a traveller there gets the nearest placed city)
/// than 4,400 km off.
const WRONG_TOWN: &[(&str, &str)] = &[("CA", "surrey")];

/// The one spot `points` all mark — every one within 10 km of the first (a
/// place listed twice) — or None.
fn one_spot(points: &[(f64, f64)]) -> Option<(f64, f64)> {
    let first = *points.first()?;
    points
        .iter()
        .all(|p| km(*p, first) <= 10.0)
        .then_some(first)
}

/// The names to look a city up by, compared as keys: its own; without a
/// trailing "City" ("Quebec City" is Natural Earth's "Québec"), "Township"
/// or "DC"; then with "Beach" or "City" added (Florida's "Boynton" is Boynton
/// Beach, California's "Big Bear" Big Bear City).
fn names(name: &str) -> Vec<String> {
    let mut out = vec![key(name)];
    for suffix in [" City", " city", " Township", " DC"] {
        if let Some(bare) = name.strip_suffix(suffix) {
            out.push(key(bare));
        }
    }
    out.push(key(&format!("{name} Beach")));
    out.push(key(&format!("{name} City")));
    let mut seen = Vec::new();
    out.retain(|k| {
        !k.is_empty() && !seen.contains(k) && {
            seen.push(k.clone());
            true
        }
    });
    out
}

/// A file as text: a byte-order mark dropped, and Latin-1 bytes (the
/// Census's estimates file) read as replacement characters rather than
/// refused — only its codes and numbers are read.
fn read(path: &str) -> Result<String, String> {
    let bytes = fs::read(path).map_err(|e| format!("cannot read {path}: {e}"))?;
    Ok(String::from_utf8_lossy(&bytes)
        .trim_start_matches('\u{feff}')
        .to_string())
}

/// The column numbers of `names` in a header line.
fn columns(path: &str, header: &str, sep: char, names: &[&str]) -> Result<Vec<usize>, String> {
    let head: Vec<&str> = header.split(sep).map(str::trim).collect();
    names
        .iter()
        .map(|n| {
            head.iter()
                .position(|h| h == n)
                .ok_or_else(|| format!("{path}: no {n} column"))
        })
        .collect()
}

/// Places by (country, name key): every (lat, lon, size) of the name.
type Sized = HashMap<(String, String), Vec<(f64, f64, f64)>>;

/// What the sources say about one name.
enum Found {
    /// Placed, by this source, with the people living there (0 unknown).
    At((f64, f64), &'static str, f64),
    /// Several places of the name, none preferred.
    Among(Vec<(f64, f64)>),
    Nothing,
}

/// One rental city as it is worked out.
struct City<'a> {
    fields: [&'a str; 4],
    /// Columns after the four, passed through (the fetch script's city id).
    rest: Vec<&'a str>,
    at: Option<((f64, f64), &'static str, f64)>,
    among: Vec<(f64, f64)>,
    airport: Option<(f64, f64)>,
}

fn run(args: &[String]) -> Result<(), String> {
    let state_name: HashMap<&str, &str> = STATES.iter().copied().collect();

    // People: the Census's 2024 estimates for cities and towns, by GEOID
    // (state + place, or state + county + subdivision)…
    let mut people: HashMap<String, f64> = HashMap::new();
    let text = read(&args[5])?;
    for line in text.lines().skip(1) {
        let f: Vec<&str> = line.split(',').collect();
        if f.len() < 16 {
            continue;
        }
        let geoid = match f[0] {
            "162" => format!("{}{}", f[1], f[3]),
            "061" => format!("{}{}{}", f[1], f[2], f[4]),
            _ => continue,
        };
        // The last column is the 2024 estimate, even where a quoted name
        // held a comma.
        if let Ok(p) = f[f.len() - 1].trim().parse::<f64>() {
            people.insert(geoid, p);
        }
    }
    // …and its 2010 count for census-designated places, which the estimates
    // skip.
    let text = read(&args[4])?;
    let mut lines = text.lines();
    let c = columns(
        &args[4],
        lines.next().unwrap_or(""),
        '\t',
        &["GEOID", "POP10"],
    )?;
    for line in lines {
        let f: Vec<&str> = line.split('\t').collect();
        if let (Some(g), Some(Ok(p))) = (f.get(c[0]), f.get(c[1]).map(|p| p.trim().parse::<f64>()))
        {
            people.entry(g.trim().to_string()).or_insert(p);
        }
    }

    // Census places, then county subdivisions (townships and towns): (state
    // key, name key) → every one of the name. Subdivisions count only where
    // no place has the name or they hold over ten times its people —
    // Washington, Pennsylvania is the city, not the slightly bigger
    // Washington Township 200 km east, but Marlboro, New Jersey is the
    // 41,852-person township, not a hamlet the Census draws as a CDP.
    let mut census: [HashMap<(String, String), Vec<CensusPlace>>; 2] = Default::default();
    for (path, subdivisions) in [(&args[2], false), (&args[3], true)] {
        let text = read(path)?;
        let mut lines = text.lines();
        let c = columns(
            path,
            lines.next().unwrap_or(""),
            '|',
            &[
                "USPS",
                "GEOID",
                "NAME",
                "FUNCSTAT",
                "ALAND",
                "AWATER",
                "INTPTLAT",
                "INTPTLONG",
            ],
        )?;
        for line in lines {
            let f: Vec<&str> = line.split('|').map(str::trim).collect();
            if f.len() <= c.iter().copied().max().unwrap_or(0) {
                continue;
            }
            let Some(state) = state_name.get(f[c[0]]) else {
                continue;
            };
            let (Ok(lat), Ok(lon)) = (f[c[6]].parse::<f64>(), f[c[7]].parse::<f64>()) else {
                continue;
            };
            // A subdivision that is only a statistical area (a census county
            // division), a fiction or defunct is no town anyone names.
            let status = f[c[3]];
            if subdivisions && matches!(status, "S" | "F" | "I" | "N") {
                continue;
            }
            for name in census_names(f[c[2]], subdivisions) {
                census[usize::from(subdivisions)]
                    .entry((key(state), key(&name)))
                    .or_default()
                    .push(CensusPlace {
                        at: (lat, lon),
                        land: f[c[4]].parse().unwrap_or(0.0),
                        water: f[c[5]].parse().unwrap_or(0.0),
                        people: people.get(f[c[1]]).copied().unwrap_or(0.0),
                        governed: status != "S",
                    });
            }
        }
    }

    // GNIS populated places: (state key, name key) → every position.
    let mut gnis: HashMap<(String, String), Vec<(f64, f64)>> = HashMap::new();
    let text = read(&args[6])?;
    let mut lines = text.lines();
    let c = columns(
        &args[6],
        lines.next().unwrap_or(""),
        '|',
        &[
            "feature_name",
            "feature_class",
            "state_name",
            "prim_lat_dec",
            "prim_long_dec",
        ],
    )?;
    for line in lines {
        let f: Vec<&str> = line.split('|').collect();
        if f.len() <= c.iter().copied().max().unwrap_or(0) || f[c[1]] != "Populated Place" {
            continue;
        }
        let (Ok(lat), Ok(lon)) = (f[c[3]].parse::<f64>(), f[c[4]].parse::<f64>()) else {
            continue;
        };
        if lat == 0.0 && lon == 0.0 {
            continue;
        }
        gnis.entry((key(f[c[2]]), key(f[c[0]])))
            .or_default()
            .push((lat, lon));
    }

    // Natural Earth, Canada and Mexico: (country, name key) → every place.
    let mut natural: Sized = HashMap::new();
    for line in read(&args[7])?.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 6 {
            continue;
        }
        let (Ok(lat), Ok(lon)) = (f[3].parse::<f64>(), f[4].parse::<f64>()) else {
            continue;
        };
        let pop: f64 = f[5].parse().unwrap_or(0.0);
        natural
            .entry((f[0].to_string(), key(f[1])))
            .or_default()
            .push((lat, lon, pop));
    }

    // GNS, Canada and Mexico: (country, name key) → every place, with its
    // standing: a capital 3, a province's or state's seat 2, a
    // municipality's 1, a town 0. Abandoned, historical and destroyed places
    // are left out; a variant name (GNS files Coquitlam only as one) counts
    // only where no place has the name as its own.
    let mut gns: [Sized; 2] = Default::default();
    for (path, country) in [(&args[8], "CA"), (&args[9], "MX")] {
        let text = read(path)?;
        let mut lines = text.lines();
        let c = columns(
            path,
            lines.next().unwrap_or(""),
            '\t',
            &["full_nm_nd", "nt", "lat_dd", "long_dd", "desig_cd"],
        )?;
        for line in lines {
            let f: Vec<&str> = line.split('\t').map(str::trim).collect();
            if f.len() <= c.iter().copied().max().unwrap_or(0) {
                continue;
            }
            let standing = match f[c[4]] {
                "PPLC" => 3.0,
                "PPLA" => 2.0,
                "PPLA2" => 1.0,
                "PPLQ" | "PPLH" | "PPLW" | "PPLCH" => continue,
                _ => 0.0,
            };
            let (Ok(lat), Ok(lon)) = (f[c[2]].parse::<f64>(), f[c[3]].parse::<f64>()) else {
                continue;
            };
            gns[usize::from(f[c[1]] == "V")]
                .entry((country.to_string(), key(f[c[0]])))
                .or_default()
                .push((lat, lon, standing));
        }
    }

    // FLOWS's airports: (country, state key, city key) → positions, and IATA
    // code → position. The state is a US airport's own ("US-PA" →
    // "pennsylvania"), since the US has a Springfield in half its states;
    // Canada and Mexico's rental cities carry no province, so theirs is "".
    let mut airports: HashMap<(String, String, String), Vec<(f64, f64)>> = HashMap::new();
    let mut by_code: HashMap<String, (f64, f64)> = HashMap::new();
    for line in read(&args[10])?.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 6 {
            continue;
        }
        let (Ok(lat), Ok(lon)) = (f[4].parse::<f64>(), f[5].parse::<f64>()) else {
            continue;
        };
        by_code.insert(f[0].to_string(), (lat, lon));
        let state = if f[2] == "US" {
            match state_name.get(f[3].trim_start_matches("US-")) {
                Some(s) => key(s),
                None => continue,
            }
        } else {
            String::new()
        };
        airports
            .entry((f[2].to_string(), state, key(f[1])))
            .or_default()
            .push((lat, lon));
    }
    // The airports DiscoverCars files under each city: (region, slug) →
    // positions. Where it files one, the town is by it: its Lincoln is the
    // New Brunswick one Fredericton's airport stands in, not Lincoln,
    // Ontario.
    let mut filed: HashMap<(String, String), Vec<(f64, f64)>> = HashMap::new();
    for line in read(&args[11])?.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        if let (3.., Some(at)) = (f.len(), f.first().and_then(|c| by_code.get(*c))) {
            filed
                .entry((f[1].to_string(), f[2].to_string()))
                .or_default()
                .push(*at);
        }
    }

    // A US name in a state (key); `anchors` are airports serving the city.
    let in_us = |state: &str, n: &str, anchors: &[(f64, f64)]| -> Found {
        let k = (state.to_string(), n.to_string());
        let people_of = |v: &[CensusPlace]| main_place(v).map_or(0.0, |m| m.people);
        let places: &[CensusPlace] = match (census[0].get(&k), census[1].get(&k)) {
            // A place the Census has not counted (a CDP drawn after 2010,
            // like Wayne on the Main Line) counts as 1,000.
            (Some(p), Some(t)) if people_of(t) > 10.0 * people_of(p).max(1000.0) => t,
            (Some(p), _) => p,
            (None, Some(t)) => t,
            (None, None) => &[],
        };
        let main = main_place(places);
        // The people of the main place, when `p` is in it.
        let people = |p: (f64, f64)| main.filter(|m| m.holds(p)).map_or(0.0, |m| m.people);
        match gnis.get(&k).map(Vec::as_slice) {
            Some([only]) if places.is_empty() || places.iter().any(|p| p.holds(*only)) => {
                Found::At(*only, "GNIS", people(*only))
            }
            // Several: the one in the main Census place, else the one by an
            // airport serving the name, else the Census place's own middle.
            Some(several) if several.len() > 1 => {
                let in_main = main.and_then(|m| {
                    several
                        .iter()
                        .filter(|p| m.holds(**p))
                        .min_by(|a, b| km(**a, m.at).total_cmp(&km(**b, m.at)))
                        .copied()
                });
                let sized: Vec<(f64, f64, f64)> =
                    several.iter().map(|&(la, lo)| (la, lo, 0.0)).collect();
                if let Some(p) = in_main.or_else(|| by_airport(anchors, &sized).map(|i| several[i]))
                {
                    Found::At(p, "GNIS", people(p))
                } else if let Some(m) = main {
                    Found::At(m.at, "Census", m.people)
                } else if let Some(p) = one_spot(several) {
                    Found::At(p, "GNIS", 0.0)
                } else {
                    Found::Among(several.to_vec())
                }
            }
            _ => main.map_or(Found::Nothing, |m| Found::At(m.at, "Census", m.people)),
        }
    };

    // A Canadian or Mexican name; `anchors` are airports serving the city.
    let in_camx = |country: &str, n: &str, anchors: &[(f64, f64)]| -> Found {
        let k = (country.to_string(), n.to_string());
        if WRONG_TOWN.contains(&(country, n)) {
            return Found::Nothing;
        }
        let ne = natural.get(&k).cloned().unwrap_or_default();
        let named = gns[0]
            .get(&k)
            .or_else(|| gns[1].get(&k))
            .cloned()
            .unwrap_or_default();
        if !anchors.is_empty() {
            // Natural Earth's places (sized by people) ahead of GNS's
            // (sized by standing, 0–3).
            let mut cands: Vec<(f64, f64, f64)> =
                ne.iter().map(|&(la, lo, p)| (la, lo, 10.0 + p)).collect();
            cands.extend(named.iter().copied());
            // None by the airport: the listed places are other towns of the
            // name, and the airport stands in (below).
            return match by_airport(anchors, &cands) {
                Some(i) if i < ne.len() => {
                    Found::At((cands[i].0, cands[i].1), "Natural Earth", ne[i].2)
                }
                Some(i) => Found::At((cands[i].0, cands[i].1), "GNS", 0.0),
                None => Found::Nothing,
            };
        }
        if let Some(&(la, lo, p)) = ne.iter().max_by(|a, b| a.2.total_cmp(&b.2)) {
            return Found::At((la, lo), "Natural Earth", p);
        }
        let points: Vec<(f64, f64)> = named.iter().map(|&(la, lo, _)| (la, lo)).collect();
        if let Some(p) = one_spot(&points) {
            return Found::At(p, "GNS", 0.0);
        }
        // Several: the one seat of government among them.
        let top = named.iter().map(|g| g.2).fold(0.0, f64::max);
        let seats: Vec<&(f64, f64, f64)> = named.iter().filter(|g| g.2 == top).collect();
        match seats.as_slice() {
            [seat] if top > 0.0 => Found::At((seat.0, seat.1), "GNS", 0.0),
            _ if points.is_empty() => Found::Nothing,
            _ => Found::Among(points),
        }
    };

    // First pass: every city the sources place by themselves.
    let text = read(&args[1])?;
    let mut cities: Vec<City> = Vec::new();
    for line in text.lines() {
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 4 {
            continue;
        }
        let (country, region, name, slug) = (f[0], f[1], f[2], f[3]);
        // "usa-new-york" → "newyork"; "usa-washington-dc" → DC. Canada and
        // Mexico: "" (see the airports above).
        let state = if country == "US" {
            key(&match region.trim_start_matches("usa-") {
                "washington-dc" => "district of columbia".to_string(),
                s => s.replace('-', " "),
            })
        } else {
            String::new()
        };
        // Airports serving the city: those DiscoverCars files under it,
        // else those named for it.
        let filed_here = filed
            .get(&(region.to_string(), slug.to_string()))
            .cloned()
            .unwrap_or_default();
        let named_for = |n: &str| {
            airports
                .get(&(country.to_string(), state.clone(), n.to_string()))
                .cloned()
                .unwrap_or_default()
        };
        let mut city = City {
            fields: [country, region, name, slug],
            rest: f[4..].to_vec(),
            at: None,
            among: Vec::new(),
            airport: None,
        };
        for n in names(name) {
            let anchors = if filed_here.is_empty() {
                named_for(&n)
            } else {
                filed_here.clone()
            };
            let found = if country == "US" {
                in_us(&state, &n, &anchors)
            } else {
                in_camx(country, &n, &anchors)
            };
            match found {
                Found::At(p, source, people) => {
                    city.at = Some((p, source, people));
                    break;
                }
                Found::Among(points) if city.among.is_empty() => city.among = points,
                _ => {}
            }
        }
        // For the last resort: an airport DiscoverCars files under the city
        // (so every city an airport is filed under is placed), else those
        // named for it when they are all in one spot (two far apart say
        // nothing about which).
        city.airport = filed_here
            .first()
            .copied()
            .or_else(|| names(name).iter().find_map(|n| one_spot(&named_for(n))));
        cities.push(city);
    }

    // Second pass: of several places of a name, the one other rental cities
    // crowd around (two or more within 50 km) — when the crowd is at least
    // eight times any rival's. Queens' Elmhurst has 137 around it, the
    // Elmhurst by Jamestown 4. Closer calls say nothing: Burnaby, Ontario
    // has more than Burnaby, BC, and Orange County's La Jolla more than San
    // Diego's.
    let placed: Vec<(&str, (f64, f64))> = cities
        .iter()
        .filter_map(|c| c.at.map(|(p, _, _)| (c.fields[0], p)))
        .collect();
    for city in cities.iter_mut().filter(|c| c.at.is_none()) {
        let around: Vec<usize> = city
            .among
            .iter()
            .map(|p| {
                placed
                    .iter()
                    .filter(|(country, q)| *country == city.fields[0] && km(*p, *q) <= 50.0)
                    .count()
            })
            .collect();
        if let Some(best) = (0..around.len()).max_by_key(|&i| around[i]) {
            let rival = (0..around.len())
                .filter(|&i| i != best)
                .map(|i| around[i])
                .max()
                .unwrap_or(0);
            if around[best] >= 2 && around[best] >= 8 * rival {
                city.at = Some((city.among[best], "other rental cities", 0.0));
            }
        }
        if city.at.is_none() {
            city.at = city.airport.map(|p| (p, "an airport", 0.0));
        }
    }

    let mut out = String::new();
    let mut tally: Vec<(&str, usize)> = Vec::new();
    for city in &cities {
        let Some(((lat, lon), source, people)) = city.at else {
            continue;
        };
        let [country, region, name, slug] = city.fields;
        out.push_str(&format!(
            "{country}\t{region}\t{name}\t{slug}\t{lat:.5}\t{lon:.5}\t{people:.0}"
        ));
        for extra in &city.rest {
            out.push('\t');
            out.push_str(extra);
        }
        out.push('\n');
        match tally.iter_mut().find(|(s, _)| *s == source) {
            Some((_, n)) => *n += 1,
            None => tally.push((source, 1)),
        }
    }
    fs::write(&args[12], out).map_err(|e| format!("cannot write {}: {e}", args[12]))?;
    let placed: usize = tally.iter().map(|(_, n)| n).sum();
    let by: Vec<String> = tally.iter().map(|(s, n)| format!("{s} {n}")).collect();
    println!(
        "{placed} of {} cities placed ({}) -> {}",
        cities.len(),
        by.join(", "),
        args[12]
    );
    for city in cities.iter().filter(|c| c.at.is_none()) {
        println!("  not placed: {}", city.fields[..3].join(" "));
    }
    Ok(())
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() != 13 {
        eprintln!(
            "usage: rental-positions <cities.tsv> <places.txt> <cousubs.txt> <places2010.txt> \
             <sub-est.csv> <gnis.txt> <ne_camx.tsv> <gns_ca.txt> <gns_mx.txt> <airports.tsv> \
             <rental_airports.tsv> <out.tsv>"
        );
        process::exit(2);
    }
    if let Err(e) = run(&args) {
        eprintln!("rental-positions: {e}");
        process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn place(at: (f64, f64), land_km2: f64, water_km2: f64, people: f64) -> CensusPlace {
        CensusPlace {
            at,
            land: land_km2 * 1e6,
            water: water_km2 * 1e6,
            people,
            governed: true,
        }
    }

    #[test]
    fn names_compare_the_way_people_spell_them() {
        assert_eq!(key("St. Albert"), key("Saint Albert"));
        assert_eq!(key("Water Mill"), key("Watermill"));
        assert_eq!(key("La Plata"), key("Laplata"));
        assert_eq!(key("Lighthouse Pt"), key("Lighthouse Point"));
        assert_eq!(key("Lānaʻi"), key("Lanai"));
        assert_eq!(key("Querétaro"), key("Queretaro"));
        assert_ne!(key("Springfield"), key("West Springfield"));
    }

    #[test]
    fn census_names_drop_the_legal_description() {
        assert_eq!(census_names("Milwaukee city", false), ["Milwaukee"]);
        assert_eq!(census_names("Boise City city", false), ["Boise City"]);
        assert_eq!(
            census_names("San Buenaventura (Ventura) city", false),
            ["San Buenaventura", "Ventura"]
        );
        assert_eq!(
            census_names(
                "Nashville-Davidson metropolitan government (balance)",
                false
            ),
            ["Nashville-Davidson", "Nashville"]
        );
        assert_eq!(
            census_names("Braintree Town city", false),
            ["Braintree Town", "Braintree"]
        );
        assert_eq!(
            census_names("Urban Honolulu CDP", false),
            ["Urban Honolulu", "Honolulu"]
        );
        assert_eq!(
            census_names("Parsippany-Troy Hills township", true),
            ["Parsippany-Troy Hills", "Parsippany"]
        );
        // An ordinary hyphenated city keeps its one name.
        assert_eq!(census_names("Winston-Salem city", false), ["Winston-Salem"]);
    }

    #[test]
    fn a_town_centre_belongs_to_the_place_around_it() {
        // Anchorage: huge, its middle 33 km from downtown.
        let anchorage = place((61.17425, -149.284329), 4420.0, 620.0, 290_000.0);
        assert!(anchorage.holds((61.2180556, -149.9002778)));
        // Four Corners, Florida: the crossroads by Tampa is another town.
        let four_corners = place((28.333179, -81.647492), 123.1, 8.8, 26_000.0);
        assert!(!four_corners.holds((27.9161332, -82.7295451)));
        // San Francisco is mostly water: its middle is at sea and cannot say.
        let san_francisco = place((37.727239, -123.032229), 120.9, 479.7, 800_000.0);
        assert!(san_francisco.holds((37.775, -122.4194444)));
    }

    #[test]
    fn the_main_place_is_the_most_populous() {
        let small = place((0.0, 0.0), 50.0, 0.0, 1_000.0);
        let big = place((1.0, 1.0), 5.0, 0.0, 90_000.0);
        let places = [small, big];
        assert_eq!(main_place(&places).map(|p| p.people), Some(90_000.0));
    }

    #[test]
    fn an_airport_picks_the_town_beside_it() {
        // Deer Lake: Newfoundland's by YDF, Ontario's far away.
        let ydf = [(49.208159, -57.396147)];
        let towns = [
            (52.617033, -94.066595, 3743.0),
            (49.1744, -57.426919, 4163.0),
        ];
        assert_eq!(by_airport(&ydf, &towns), Some(1));
        assert_eq!(by_airport(&[(0.0, 0.0)], &towns), None);
    }

    #[test]
    fn one_spot_is_a_place_listed_twice() {
        assert_eq!(
            one_spot(&[(49.183333, -57.433333), (49.1744, -57.426919)]),
            Some((49.183333, -57.433333))
        );
        assert_eq!(one_spot(&[(49.18, -57.43), (52.63, -94.07)]), None);
        assert_eq!(one_spot(&[]), None);
    }

    #[test]
    fn a_city_is_looked_up_by_its_other_names_too() {
        let n = names("Quebec City");
        assert_eq!(n[0], key("Quebec City"));
        assert!(n.contains(&key("Quebec")));
        assert!(names("Boynton").contains(&key("Boynton Beach")));
        assert!(names("Washington DC").contains(&key("Washington")));
        assert!(names("Clinton Township").contains(&key("Clinton")));
    }
}
