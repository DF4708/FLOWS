// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! Swift boundary for `flows_core::transit::shard`: build a shard from a feed
//! the device downloaded, and ask it what leaves after now.
//!
//! Everything crosses as tagged rows joined by the unit separator (U+001F),
//! which no station name carries. A tag leads each row so the answer can grow
//! new row kinds without the Swift side mis-reading the old ones:
//!
//! ```text
//! err  ␟ message
//! info ␟ service_date ␟ feed_published ␟ agency_zone
//! od   ␟ name ␟ code ␟ zone ␟ meters ␟ name ␟ code ␟ zone ␟ meters   (board, alight)
//! dep  ␟ dep_secs ␟ arr_secs ␟ transfers ␟ walk_secs ␟ n_legs
//! leg  ␟ board_name ␟ board_code ␟ board_zone
//!      ␟ alight_name ␟ alight_code ␟ alight_zone
//!      ␟ route_name ␟ mode ␟ dep_secs ␟ arr_secs
//! ```
//!
//! Times are seconds from the service day's start, in the agency's zone — NOT
//! a wall clock and NOT local to the station. Swift turns them into clocks
//! (`TransitClock`), because that conversion needs a timezone database that
//! Foundation has and this crate does not. An answer always carries at least
//! one row, so nothing ever hands Swift an empty buffer.

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        fn flows_transit_agency_zone(gtfs_dir: &str) -> String;
        fn flows_transit_build(gtfs_dir: &str, prefix: &str, service_date: i64) -> Vec<String>;
        fn flows_transit_info(prefix: &str) -> Vec<String>;
        fn flows_transit_departures(
            prefix: &str,
            from_latitude: f64,
            from_longitude: f64,
            to_latitude: f64,
            to_longitude: f64,
            max_station_meters: f64,
            depart_seconds: i64,
            limit: i64,
        ) -> Vec<String>;
    }
}

use std::path::Path;

use crate::contain;
use flows_core::transit::shard::{self, Departure, NearStop, Shard};

/// The separator between fields. U+001F is not a character a station name,
/// route name or zone id carries.
const UNIT: char = '\u{1F}';

fn err_rows(message: impl AsRef<str>) -> Vec<String> {
    vec![format!("err{UNIT}{}", message.as_ref())]
}

/// The zone a feed keeps its times in, read from `agency.txt` alone — the one
/// question that must be answered BEFORE building, because "which service day
/// is it right now?" is a question in the agency's zone, not the device's. A
/// rider in Honolulu at 9pm is already on tomorrow's Amtrak timetable.
pub fn flows_transit_agency_zone(gtfs_dir: &str) -> String {
    contain(String::new(), || {
        flows_core::transit::gtfs::agency_timezone(Path::new(gtfs_dir)).unwrap_or_default()
    })
}

/// Build `<prefix>.ftt` + `<prefix>.fts` from an unzipped feed directory.
/// `service_date` is YYYYMMDD; pass 0 to let the feed's own calendar choose.
pub fn flows_transit_build(gtfs_dir: &str, prefix: &str, service_date: i64) -> Vec<String> {
    contain(err_rows("transit: build panicked"), || {
        let date = u32::try_from(service_date).ok().filter(|d| *d >= 19000101);
        match shard::build(Path::new(gtfs_dir), date, Path::new(prefix)) {
            Err(e) => err_rows(e),
            Ok(r) => vec![
                format!(
                    "info{UNIT}{}{UNIT}{}{UNIT}{}",
                    r.service_date, r.feed_published, r.agency_zone
                ),
                format!(
                    "built{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}",
                    r.n_stops,
                    r.n_routes,
                    r.n_trips,
                    r.n_events,
                    r.ftt_bytes + r.fts_bytes
                ),
            ],
        }
    })
}

fn open_or_err(prefix: &str) -> Result<Shard, Vec<String>> {
    shard::open(Path::new(prefix)).map_err(|e| err_rows(e.to_string()))
}

fn info_row(s: &Shard) -> String {
    format!(
        "info{UNIT}{}{UNIT}{}{UNIT}{}",
        s.labels.service_date, s.labels.feed_published, s.labels.agency_zone
    )
}

/// What a shard on disk is: its service date, publication date and zone. Used
/// to decide whether the cached feed is still the right day before any query.
pub fn flows_transit_info(prefix: &str) -> Vec<String> {
    contain(err_rows("transit: info panicked"), || {
        match open_or_err(prefix) {
            Err(rows) => rows,
            Ok(s) => vec![info_row(&s)],
        }
    })
}

fn near_fields(n: &NearStop) -> String {
    format!(
        "{}{UNIT}{}{UNIT}{}{UNIT}{:.0}",
        n.name, n.code, n.zone, n.meters
    )
}

fn dep_rows(d: &Departure, out: &mut Vec<String>) {
    out.push(format!(
        "dep{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}",
        d.dep,
        d.arr,
        d.n_transfers,
        d.walk_secs,
        d.legs.len()
    ));
    for l in &d.legs {
        out.push(format!(
            "leg{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}",
            l.board_name,
            l.board_code,
            l.board_zone,
            l.alight_name,
            l.alight_code,
            l.alight_zone,
            l.route_name,
            l.mode,
            l.dep,
            l.arr
        ));
    }
}

/// What leaves after `depart_seconds` from the station nearest the origin to
/// the station nearest the destination.
///
/// Both ends try several nearby stations, nearest first, and the first PAIR
/// that actually produces a ride wins: the closest station is often not the
/// one this train calls at, and a rider would rather walk an extra block than
/// be told there is no train.
#[allow(clippy::too_many_arguments)] // the bridge mirrors the Swift call
pub fn flows_transit_departures(
    prefix: &str,
    from_latitude: f64,
    from_longitude: f64,
    to_latitude: f64,
    to_longitude: f64,
    max_station_meters: f64,
    depart_seconds: i64,
    limit: i64,
) -> Vec<String> {
    contain(err_rows("transit: departures panicked"), || {
        let s = match open_or_err(prefix) {
            Err(rows) => return rows,
            Ok(s) => s,
        };
        let depart = u32::try_from(depart_seconds.max(0)).unwrap_or(0);
        let want = usize::try_from(limit).unwrap_or(0).clamp(1, 8);

        const CANDIDATES: usize = 4;
        let boards = s.nearest_stops(
            from_latitude,
            from_longitude,
            max_station_meters,
            CANDIDATES,
        );
        let alights = s.nearest_stops(to_latitude, to_longitude, max_station_meters, CANDIDATES);
        if boards.is_empty() || alights.is_empty() {
            return err_rows("transit: no station near one end of this trip");
        }

        // Try pairs by how far the rider walks in TOTAL, not board-first:
        // iterating the boards in order would pit the nearest station against
        // the farthest arrival before trying the second-nearest against the
        // closest one, and send someone across town to save a block.
        let mut pairs: Vec<(&NearStop, &NearStop)> = boards
            .iter()
            .flat_map(|b| alights.iter().map(move |a| (b, a)))
            .filter(|(b, a)| b.stop != a.stop)
            .collect();
        pairs.sort_by(|x, y| (x.0.meters + x.1.meters).total_cmp(&(y.0.meters + y.1.meters)));

        for (b, a) in pairs {
            let found = s.board(b.stop, a.stop, depart, want);
            if found.is_empty() {
                continue;
            }
            let mut out = vec![
                info_row(&s),
                format!("od{UNIT}{}{UNIT}{}", near_fields(b), near_fields(a)),
            ];
            for d in found.iter().take(want) {
                dep_rows(d, &mut out);
            }
            return out;
        }
        err_rows("transit: no ride between those stations today")
    })
}
