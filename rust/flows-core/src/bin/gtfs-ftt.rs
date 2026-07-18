// -----------------------------------------------------------------------------
// Copyright (c) David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! `gtfs-ftt` — the offline GTFS → `.ftt` converter (Phase 1 of the transit
//! plan, see docs/TRANSIT_ROUTING.md). Never ships on-device; it is the only
//! writer of `.ftt` shards. Pure std, zero external crates.
//!
//! ```text
//! gtfs-ftt <gtfs-dir> <out.ftt> [YYYYMMDD] [--verify] [--plan FROM_STOP_ID TO_STOP_ID HH:MM]
//! ```
//!
//! - `<gtfs-dir>`: an UNZIPPED GTFS feed directory (scripts/fetch_gtfs.sh).
//! - `[YYYYMMDD]`: the service date to build. Defaults to the first weekday
//!   the feed's calendar covers with active service — the converter NEVER
//!   reads the system clock; wrappers (scripts/build_ftt.sh) pass "today" in.
//! - `--verify`: after writing, read the .ftt back, check byte-identical
//!   re-encode, auto-pick two busy far-apart stops, and run RAPTOR on both the
//!   original and the reloaded timetable, asserting identical plans.
//! - `--plan A B HH:MM`: like --verify but between the given GTFS stop_ids at
//!   the given departure time.

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Instant;

use flows_core::transit::gtfs::{fmt_time, load_gtfs, GtfsLoad};
use flows_core::transit::{ftt, plan, LegKind};

fn usage() -> String {
    "usage: gtfs-ftt <gtfs-dir> <out.ftt> [YYYYMMDD] [--verify] [--plan FROM_STOP_ID TO_STOP_ID HH:MM]"
        .to_string()
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("gtfs-ftt: {e}");
            ExitCode::FAILURE
        }
    }
}

struct Args {
    gtfs_dir: PathBuf,
    out: PathBuf,
    date: Option<u32>,
    verify: bool,
    plan_req: Option<(String, String, u32)>,
}

fn parse_args() -> Result<Args, String> {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let mut pos: Vec<String> = Vec::new();
    let mut verify = false;
    let mut plan_req = None;
    let mut i = 0;
    while i < argv.len() {
        match argv[i].as_str() {
            "--verify" => verify = true,
            "--plan" => {
                if i + 3 >= argv.len() {
                    return Err(format!("--plan needs FROM TO HH:MM\n{}", usage()));
                }
                let hm = &argv[i + 3];
                let depart = parse_hhmm(hm).ok_or_else(|| format!("bad --plan time '{hm}'"))?;
                plan_req = Some((argv[i + 1].clone(), argv[i + 2].clone(), depart));
                i += 3;
            }
            "-h" | "--help" => return Err(usage()),
            other => pos.push(other.to_string()),
        }
        i += 1;
    }
    if pos.len() < 2 || pos.len() > 3 {
        return Err(usage());
    }
    let date = match pos.get(2) {
        None => None,
        Some(s) => Some(
            s.parse::<u32>()
                .ok()
                .filter(|d| *d >= 19000101 && *d <= 21001231)
                .ok_or_else(|| format!("bad date '{s}' (want YYYYMMDD)"))?,
        ),
    };
    Ok(Args {
        gtfs_dir: PathBuf::from(&pos[0]),
        out: PathBuf::from(&pos[1]),
        date,
        verify,
        plan_req,
    })
}

fn parse_hhmm(s: &str) -> Option<u32> {
    let (h, m) = s.split_once(':')?;
    let h: u32 = h.parse().ok()?;
    let m: u32 = m.parse().ok()?;
    if m > 59 {
        return None;
    }
    Some(h * 3600 + m * 60)
}

fn run() -> Result<(), String> {
    let args = parse_args()?;

    // --- Parse + build the service-day timetable. ---
    let t0 = Instant::now();
    let load = load_gtfs(&args.gtfs_dir, args.date).map_err(|e| e.to_string())?;
    let t_parse = t0.elapsed();
    let tt = &load.timetable;
    println!(
        "parsed {}: service date {} | {} stops, {} engine routes ({} overtake splits), \
         {} trips ({} gtfs trips, {} dropped), {} stop-events | {:.2}s",
        args.gtfs_dir.display(),
        load.service_date,
        tt.n_stops(),
        tt.n_routes(),
        load.n_overtake_splits,
        load.n_trips,
        load.n_gtfs_trips,
        load.n_dropped_trips,
        load.n_events,
        t_parse.as_secs_f64()
    );

    // --- Write the .ftt. ---
    let t1 = Instant::now();
    ftt::write_ftt(tt, &args.out).map_err(|e| format!("write {}: {e}", args.out.display()))?;
    let t_write = t1.elapsed();
    let size = std::fs::metadata(&args.out).map(|m| m.len()).unwrap_or(0);
    println!(
        "wrote {} ({:.2} MB, {} B/stop-event incl. header) | {:.3}s",
        args.out.display(),
        size as f64 / 1e6,
        if load.n_events > 0 { size as usize / load.n_events } else { 0 },
        t_write.as_secs_f64()
    );

    if !(args.verify || args.plan_req.is_some()) {
        return Ok(());
    }

    // --- Read back + verify. ---
    let t2 = Instant::now();
    let tt2 = ftt::read_ftt(&args.out).map_err(|e| format!("read-back: {e}"))?;
    let t_read = t2.elapsed();
    if ftt::to_bytes(tt) != ftt::to_bytes(&tt2) {
        return Err("VERIFY FAILED: reloaded timetable is not byte-identical".into());
    }
    println!(
        "read back {} in {:.3}s — byte-identical re-encode OK",
        args.out.display(),
        t_read.as_secs_f64()
    );

    // --- Pick the OD pair. ---
    let (src, dst, depart) = match &args.plan_req {
        Some((from, to, depart)) => {
            let find = |id: &str| -> Result<u32, String> {
                load.stop_ids
                    .iter()
                    .position(|s| s == id)
                    .map(|i| i as u32)
                    .ok_or_else(|| format!("stop_id '{id}' not in this feed"))
            };
            (find(from)?, find(to)?, *depart)
        }
        None => auto_pick(&load).ok_or("no served stops to plan between")?,
    };
    println!(
        "\nplan: {} ({}) -> {} ({}) departing {}",
        load.stop_ids[src as usize],
        load.stop_names[src as usize],
        load.stop_ids[dst as usize],
        load.stop_names[dst as usize],
        fmt_time(depart)
    );

    // --- Plan on the RELOADED timetable; assert equality with the original. ---
    let t3 = Instant::now();
    let journeys = plan(&tt2, src, dst, depart, 10);
    let t_plan = t3.elapsed();
    if journeys != plan(tt, src, dst, depart, 10) {
        return Err("VERIFY FAILED: plans differ between original and reloaded .ftt".into());
    }
    println!(
        "raptor: {} Pareto journey(s) in {:.2} ms (identical on original vs reloaded)",
        journeys.len(),
        t_plan.as_secs_f64() * 1e3
    );
    if journeys.is_empty() {
        println!("  (unreachable at this departure time)");
    }
    for (i, j) in journeys.iter().enumerate() {
        println!(
            "\n  option {}: arrive {} | {} transfer(s), {} min walking",
            i + 1,
            fmt_time(j.arrival),
            j.n_transfers,
            j.walk_secs / 60
        );
        for leg in &j.legs {
            let from = leg.from_stop as usize;
            let to = leg.to_stop as usize;
            match leg.kind {
                LegKind::Ride => println!(
                    "    {} ride  [{}] {} -> {} (arr {})",
                    fmt_time(leg.dep),
                    load.route_names.get(leg.route as usize).map(String::as_str).unwrap_or("?"),
                    load.stop_names[from],
                    load.stop_names[to],
                    fmt_time(leg.arr)
                ),
                LegKind::Walk => println!(
                    "    {} walk  {} -> {} ({}s)",
                    fmt_time(leg.dep),
                    load.stop_names[from],
                    load.stop_names[to],
                    leg.arr - leg.dep
                ),
            }
        }
    }
    Ok(())
}

/// Auto-pick a demonstrative OD pair: the busiest stop as the origin and, among
/// the top-visited stops, the one geographically farthest from it as the
/// destination; depart 08:00. Falls back through later departures if needed.
fn auto_pick(load: &GtfsLoad) -> Option<(u32, u32, u32)> {
    let tt = &load.timetable;
    let src = (0..tt.n_stops())
        .max_by_key(|&s| load.stop_visits[s])
        .filter(|&s| load.stop_visits[s] > 0)? as u32;

    let mut busy: Vec<u32> = (0..tt.n_stops() as u32)
        .filter(|&s| load.stop_visits[s as usize] > 0 && s != src)
        .collect();
    busy.sort_by_key(|&s| std::cmp::Reverse(load.stop_visits[s as usize]));
    busy.truncate(200);

    let sp = tt.stop(src);
    let dst = *busy.iter().max_by_key(|&&s| {
        let p = tt.stop(s);
        let dy = (p.lat_e6 - sp.lat_e6) as i64;
        let dx = (p.lon_e6 - sp.lon_e6) as i64;
        dy * dy + dx * dx
    })?;

    for depart in [8 * 3600u32, 12 * 3600, 6 * 3600, 17 * 3600] {
        if !plan(tt, src, dst, depart, 10).is_empty() {
            return Some((src, dst, depart));
        }
    }
    Some((src, dst, 8 * 3600))
}
