// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! ferries-table — every ferry route in the United States, from the federal
//! ferry census, compiled into `flows-core` so the ship card can say a ferry
//! runs where no timetable feed covers it.
//!
//! WHY: the ship card reads ferries' own timetables (GTFS), and only about
//! sixty ferry operators publish one. The Alaska Marine Highway, the SS
//! Badger across Lake Michigan and the Catalina boats publish none, so a trip
//! over their water read "No ferry for this trip". The census knows they run,
//! between which terminals, how long a crossing takes, in which season, and
//! whether cars go aboard — not the times, which the card says plainly.
//!
//! SOURCE: the Bureau of Transportation Statistics' National Census of Ferry
//! Operators, 2024 (<https://data.bts.gov>, "2024 NCFO …" files). A work of
//! the United States Government: public domain, free for commercial use with
//! nothing owed (the owner's rule, 2026-09-30, keeps FLOWS licence-free).
//!
//! Inputs (download with `scripts/fetch_ferry_census.sh`):
//!   terminals.csv          2024 NCFO Terminals File
//!   segments.csv           2024 NCFO Segments File
//!   operator_segments.csv  2024 NCFO Operator Segment File
//!   operators.csv          2024 NCFO Operators File
//!
//! Usage: ferries-table <dir with the four CSVs> <out.rs>
//! (the file it writes is `flows-core/src/ferries_table.rs`, committed —
//! run it again when BTS publishes the next census)

#![forbid(unsafe_code)]

use std::collections::{BTreeMap, HashMap};
use std::env;
use std::fs;
use std::path::Path;
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

/// A table's rows as header name → value, skipping blank lines.
fn table(dir: &Path, name: &str) -> Result<Vec<HashMap<String, String>>, String> {
    let path = dir.join(name);
    let text =
        fs::read_to_string(&path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    let text = text.trim_start_matches('\u{feff}');
    let mut lines = text.lines();
    let header: Vec<String> = fields(lines.next().ok_or(format!("{name} is empty"))?)
        .into_iter()
        .map(|h| h.trim().to_ascii_lowercase())
        .collect();
    Ok(lines
        .filter(|l| !l.trim().is_empty())
        .map(|l| {
            header
                .iter()
                .cloned()
                .zip(fields(l).into_iter().map(|v| v.trim().to_string()))
                .collect()
        })
        .collect())
}

fn get<'a>(row: &'a HashMap<String, String>, key: &str) -> &'a str {
    row.get(key).map(String::as_str).unwrap_or("")
}

/// "11-May" → (5, 11); None for "NA" or anything else.
fn month_day(s: &str) -> Option<(u8, u8)> {
    let (day, month) = s.split_once('-')?;
    let day: u8 = day.trim().parse().ok()?;
    let months = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ];
    let m = months
        .iter()
        .position(|m| month.trim().to_ascii_lowercase().starts_with(m))?;
    (1..=31).contains(&day).then_some((m as u8 + 1, day))
}

/// A Rust string literal's body.
fn escaped(text: &str) -> String {
    text.replace('\\', "\\\\").replace('"', "\\\"")
}

struct Terminal {
    name: String,
    city: String,
    state: String,
    lat: f64,
    lon: f64,
}

struct Route {
    segment: u32,
    operator: u32,
    name: String,
    a: u32,
    b: u32,
    miles: f64,
    minutes: u32,
    season: [u8; 4],
    trips_per_year: u32,
    /// Cars carried in the census year: some, none, or not reported (the SS
    /// Badger, a car ferry, left the count blank).
    cars: Option<bool>,
}

fn run(dir: &Path, output: &str) -> Result<(), String> {
    // Terminals still in service, with a real position.
    let mut terminals: BTreeMap<u32, Terminal> = BTreeMap::new();
    for row in table(dir, "terminals.csv")? {
        let Ok(id) = get(&row, "terminal_id").parse::<u32>() else {
            continue;
        };
        if get(&row, "in_operation") != "1" {
            continue;
        }
        let (Ok(lat), Ok(lon)) = (
            get(&row, "latitude").parse::<f64>(),
            get(&row, "longitude").parse::<f64>(),
        ) else {
            continue;
        };
        if !(-90.0..=90.0).contains(&lat) || !(-180.0..=180.0).contains(&lon) || lat == 0.0 {
            continue;
        }
        terminals.insert(
            id,
            Terminal {
                name: get(&row, "terminal_name").to_string(),
                city: get(&row, "term_city").to_string(),
                state: get(&row, "term_state").to_string(),
                lat,
                lon,
            },
        );
    }

    let mut operators: BTreeMap<u32, (String, String)> = BTreeMap::new();
    for row in table(dir, "operators.csv")? {
        let Ok(id) = get(&row, "operator_id").parse::<u32>() else {
            continue;
        };
        let url = get(&row, "url");
        let url = if url.starts_with("http://") || url.starts_with("https://") {
            url.to_string()
        } else {
            String::new()
        };
        operators.insert(id, (get(&row, "operator_name").to_string(), url));
    }

    // segment id → (name, terminal a, terminal b)
    let mut segments: HashMap<u32, (String, u32, u32)> = HashMap::new();
    for row in table(dir, "segments.csv")? {
        let (Ok(id), Ok(a), Ok(b)) = (
            get(&row, "segment_id").parse::<u32>(),
            get(&row, "seg_terminal1_id").parse::<u32>(),
            get(&row, "seg_terminal2_id").parse::<u32>(),
        ) else {
            continue;
        };
        segments.insert(id, (get(&row, "segment_name").to_string(), a, b));
    }

    let mut routes: Vec<Route> = Vec::new();
    for row in table(dir, "operator_segments.csv")? {
        let (Ok(operator), Ok(segment)) = (
            get(&row, "operator_id").parse::<u32>(),
            get(&row, "segment_id").parse::<u32>(),
        ) else {
            continue;
        };
        let Some((name, a, b)) = segments.get(&segment) else {
            continue;
        };
        if a == b || !terminals.contains_key(a) || !terminals.contains_key(b) {
            continue;
        }
        if !operators.contains_key(&operator) {
            continue;
        }
        let season = match (
            month_day(get(&row, "segment_season_start")),
            month_day(get(&row, "segment_season_end")),
        ) {
            (Some((m1, d1)), Some((m2, d2))) => [m1, d1, m2, d2],
            _ => [0; 4],
        };
        routes.push(Route {
            segment,
            operator,
            name: name.clone(),
            a: *a,
            b: *b,
            miles: get(&row, "segment_length").parse().unwrap_or(0.0),
            minutes: get(&row, "average_trip_time").parse().unwrap_or(0),
            season,
            trips_per_year: get(&row, "trips_per_year").parse().unwrap_or(0),
            cars: get(&row, "vehicles").parse::<f64>().ok().map(|v| v > 0.0),
        });
    }
    routes.sort_by_key(|r| (r.segment, r.operator));
    routes.dedup_by_key(|r| (r.segment, r.operator));
    if routes.len() < 500 || terminals.len() < 300 {
        return Err(format!(
            "only {} routes and {} terminals survived — the census columns changed?",
            routes.len(),
            terminals.len()
        ));
    }
    // Only the terminals and operators a route uses.
    let used_terminals: std::collections::BTreeSet<u32> =
        routes.iter().flat_map(|r| [r.a, r.b]).collect();
    let used_operators: std::collections::BTreeSet<u32> =
        routes.iter().map(|r| r.operator).collect();

    let mut out = String::with_capacity(routes.len() * 200 + 4096);
    out.push_str(
        "// -----------------------------------------------------------------------------\n\
         // Copyright (c) 2026 David B. Foster. All rights reserved.\n\
         // Contact: wizeman555@gmail.com\n\
         // Unauthorized copying, distribution, modification, or use of this file, in\n\
         // whole or in part, is strictly prohibited without the express written\n\
         // permission of the copyright holder.\n\
         // -----------------------------------------------------------------------------\n\n\
         //! GENERATED by `flows-train`'s `ferries-table` from the Bureau of\n\
         //! Transportation Statistics' 2024 National Census of Ferry Operators —\n\
         //! do not edit by hand; run the tool again.\n\
         //!\n\
         //! Every ferry route the census lists in service, the terminals it joins\n\
         //! and the operator who runs it. Source: <https://data.bts.gov>, a work\n\
         //! of the United States Government, public domain.\n\n\
         use super::ferries::{FerryOperator, FerryRoute, FerryTerminal};\n\n",
    );
    out.push_str(&format!(
        "/// Terminals in service, sorted by census id ({}).\n\
         pub static FERRY_TERMINALS: &[FerryTerminal] = &[\n",
        used_terminals.len()
    ));
    for id in &used_terminals {
        let t = &terminals[id];
        out.push_str(&format!(
            "    FerryTerminal {{ id: {id}, name: \"{}\", city: \"{}\", state: \"{}\", \
             lat: {:.6}, lon: {:.6} }},\n",
            escaped(&t.name),
            escaped(&t.city),
            escaped(&t.state),
            t.lat,
            t.lon
        ));
    }
    out.push_str("];\n\n");
    out.push_str(&format!(
        "/// Operators, sorted by census id ({}).\n\
         pub static FERRY_OPERATORS: &[FerryOperator] = &[\n",
        used_operators.len()
    ));
    for id in &used_operators {
        let (name, url) = &operators[id];
        out.push_str(&format!(
            "    FerryOperator {{ id: {id}, name: \"{}\", url: \"{}\" }},\n",
            escaped(name),
            escaped(url)
        ));
    }
    out.push_str("];\n\n");
    out.push_str(&format!(
        "/// Routes, one per operator and segment ({}).\n\
         pub static FERRY_ROUTES: &[FerryRoute] = &[\n",
        routes.len()
    ));
    for r in &routes {
        out.push_str(&format!(
            "    FerryRoute {{ name: \"{}\", a: {}, b: {}, operator: {}, miles: {:.1}, \
             minutes: {}, season: [{}, {}, {}, {}], trips_per_year: {}, cars: {:?} }},\n",
            escaped(&r.name),
            r.a,
            r.b,
            r.operator,
            r.miles,
            r.minutes,
            r.season[0],
            r.season[1],
            r.season[2],
            r.season[3],
            r.trips_per_year,
            r.cars
        ));
    }
    out.push_str("];\n");
    fs::write(output, out).map_err(|e| format!("cannot write {output}: {e}"))?;
    println!(
        "{} routes, {} terminals, {} operators -> {output}",
        routes.len(),
        used_terminals.len(),
        used_operators.len()
    );
    Ok(())
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: ferries-table <dir with the census CSVs> <out.rs>");
        process::exit(2);
    }
    if let Err(e) = run(Path::new(&args[1]), &args[2]) {
        eprintln!("ferries-table: {e}");
        process::exit(1);
    }
}
