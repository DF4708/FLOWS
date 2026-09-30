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
//!      ␟ board_lat ␟ board_lon ␟ alight_lat ␟ alight_lon
//! ```
//!
//! A departures query also takes a vehicle mask — `transit::Mode` bits, 0 for
//! every vehicle — so a rider who chose the bus is planned on buses alone.
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
        fn flows_transit_build_many(
            gtfs_dirs: &str,
            shift_secs: &[f64],
            prefix: &str,
            service_date: i64,
        ) -> Vec<String>;
        fn flows_transit_info(prefix: &str) -> Vec<String>;
        fn flows_transit_city_feeds(latitude: f64, longitude: f64, limit: i64) -> Vec<String>;
        fn flows_transit_ship_feeds(
            latitude: f64,
            longitude: f64,
            reach_km: f64,
            limit: i64,
        ) -> Vec<String>;
        fn flows_transit_departures(
            prefix: &str,
            from_latitude: f64,
            from_longitude: f64,
            to_latitude: f64,
            to_longitude: f64,
            max_station_meters: f64,
            depart_seconds: i64,
            limit: i64,
            vehicles: i64,
        ) -> Vec<String>;
        fn flows_transit_trip_shape(
            on_foot: bool,
            train: bool,
            bus: bool,
            plane: bool,
            rental: bool,
            ship: bool,
            trip_miles: f64,
        ) -> i64;
        fn flows_transit_beats_walk(
            walk_seconds: f64,
            walk_known: bool,
            transit_seconds: f64,
        ) -> bool;
        fn flows_transit_other_vehicle_wins(
            chosen_seconds: f64,
            chosen_known: bool,
            other_seconds: f64,
        ) -> bool;
        fn flows_transit_all_vehicles() -> i64;
        fn flows_transit_ship_vehicles() -> i64;
        fn flows_transit_land_vehicles() -> i64;
        fn flows_transit_long_haul_miles() -> f64;
        fn flows_transit_far_walk_seconds() -> f64;
    }
}

use std::path::Path;

use crate::contain;
use flows_core::transit::gtfs::{FeedInput, LINK_WALK_MPS};
use flows_core::transit::shard::{self, BuildReport, Departure, NearStop, Shard};
use flows_core::transit::{Time, ALL_VEHICLES, LAND_VEHICLES, SHIP_VEHICLES};
use flows_core::trip_shape::{self, Picked};

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
            Ok(r) => report_rows(&r),
        }
    })
}

fn report_rows(r: &BuildReport) -> Vec<String> {
    vec![
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
    ]
}

/// The city timetables that could carry the last leg of a trip ending at a
/// point, best first: `feed␟id␟operator␟url␟licence␟minLat␟maxLat␟minLon␟maxLon␟mirror`
/// (the mirror is the catalog's copy, tried when the publisher's link fails).
/// The table is compiled in (see `flows_core::transit::feeds`), so this never
/// touches the network. Feeds whose licence needs written permission for
/// commercial use are never returned.
pub fn flows_transit_city_feeds(latitude: f64, longitude: f64, limit: i64) -> Vec<String> {
    contain(Vec::new(), || {
        let limit = usize::try_from(limit).unwrap_or(0).min(8);
        flows_core::transit::feeds::covering(latitude, longitude, limit)
            .iter()
            .map(|f| feed_row(f))
            .collect()
    })
}

/// The timetables of operators that run boats within `reach_km` of a point,
/// nearest first, in the same rows as [`flows_transit_city_feeds`]. A ship
/// trip asks these alone (`flows_core::transit::feeds::ships_near`).
pub fn flows_transit_ship_feeds(
    latitude: f64,
    longitude: f64,
    reach_km: f64,
    limit: i64,
) -> Vec<String> {
    contain(Vec::new(), || {
        let limit = usize::try_from(limit).unwrap_or(0).min(8);
        flows_core::transit::feeds::ships_near(latitude, longitude, reach_km, limit)
            .iter()
            .map(|f| feed_row(f))
            .collect()
    })
}

fn feed_row(f: &flows_core::transit::feeds::CityFeed) -> String {
    format!(
        "feed{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{:.6}{UNIT}{:.6}{UNIT}{:.6}{UNIT}{:.6}{UNIT}{}",
        f.id,
        flows_core::transit::feeds::operator_name(f.provider).replace(UNIT, " "),
        f.url,
        f.licence,
        f.min_lat,
        f.max_lat,
        f.min_lon,
        f.max_lon,
        f.mirror
    )
}

/// The most a feed's clock can sit from the reference's: two days. Any real
/// pair of zones is within 26 hours; a shift past this is a caller's bug,
/// and refusing it beats building a timetable of nonsense times.
const MAX_SHIFT_SECS: f64 = 48.0 * 3600.0;

/// Build ONE shard from several feeds, so a trip can ride one operator's
/// train and another's bus. `gtfs_dirs` is the unzipped directories joined by
/// U+001F; `shift_secs` holds, for each, the seconds that move its times into
/// the FIRST feed's clock (Swift works these out — it has the timezone
/// database). The first feed must load; later ones that cannot are reported
/// as `skipped␟index␟reason` rows rather than failing the trains.
///
/// Rows: `info`, `built`, `linked␟pairs`, then any `skipped` rows.
pub fn flows_transit_build_many(
    gtfs_dirs: &str,
    shift_secs: &[f64],
    prefix: &str,
    service_date: i64,
) -> Vec<String> {
    contain(err_rows("transit: build panicked"), || {
        let Some(date) = u32::try_from(service_date).ok().filter(|d| *d >= 19000101) else {
            return err_rows("transit: a merged timetable needs its service date");
        };
        let dirs: Vec<&str> = gtfs_dirs.split(UNIT).collect();
        if dirs.len() != shift_secs.len() {
            return err_rows("transit: each feed needs exactly one shift");
        }
        let mut feeds = Vec::with_capacity(dirs.len());
        for (dir, &shift) in dirs.iter().zip(shift_secs) {
            if dir.is_empty() || !shift.is_finite() || shift.abs() > MAX_SHIFT_SECS {
                return err_rows("transit: a feed has no directory or an impossible shift");
            }
            feeds.push(FeedInput {
                dir: Path::new(dir),
                shift_secs: shift as i32,
            });
        }
        match shard::build_many(&feeds, date, Path::new(prefix)) {
            Err(e) => err_rows(e),
            Ok(r) => {
                let mut rows = report_rows(&r);
                rows.push(format!("linked{UNIT}{}", r.n_feed_links));
                for (index, why) in &r.skipped {
                    // A reason is free text from a parser; keep it one field.
                    let why = why.replace(UNIT, " ");
                    rows.push(format!("skipped{UNIT}{index}{UNIT}{why}"));
                }
                rows
            }
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
            "leg{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}{UNIT}{}\
             {UNIT}{:.6}{UNIT}{:.6}{UNIT}{:.6}{UNIT}{:.6}",
            l.board_name,
            l.board_code,
            l.board_zone,
            l.alight_name,
            l.alight_code,
            l.alight_zone,
            l.route_name,
            l.mode,
            l.dep,
            l.arr,
            l.board_lat,
            l.board_lon,
            l.alight_lat,
            l.alight_lon
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
    vehicles: i64,
) -> Vec<String> {
    contain(err_rows("transit: departures panicked"), || {
        let s = match open_or_err(prefix) {
            Err(rows) => return rows,
            Ok(s) => s,
        };
        let depart = u32::try_from(depart_seconds.max(0)).unwrap_or(0);
        let want = usize::try_from(limit).unwrap_or(0).clamp(1, 8);
        let vehicles = vehicle_mask(vehicles);

        const CANDIDATES: usize = 5;
        let boards = s.nearest_stops_vehicles(
            from_latitude,
            from_longitude,
            max_station_meters,
            CANDIDATES,
            vehicles,
        );
        let alights = s.nearest_stops_vehicles(
            to_latitude,
            to_longitude,
            max_station_meters,
            CANDIDATES,
            vehicles,
        );
        if boards.is_empty() || alights.is_empty() {
            return err_rows("transit: no station near one end of this trip");
        }

        // Choose the pair of stops by the whole TRIP, not by which is closest:
        // the walk to the first stop (it delays when you can board), the
        // ride with five minutes charged per change, and the walk from the
        // last stop. The stop nearest a destination is often the one needing
        // an extra one-minute bus — seen live: Chicago to UW-Milwaukee chose
        // the closest campus stop and paid for it with a third change.
        let walk = |meters: f64| -> Time { (meters.max(0.0) / LINK_WALK_MPS).ceil() as Time };
        let mut best: Option<(&NearStop, &NearStop, Time, u64)> = None;
        for b in &boards {
            for a in &alights {
                if b.stop == a.stop {
                    continue;
                }
                let leave = depart.saturating_add(walk(b.meters));
                let Some(d) = s
                    .board_vehicles(b.stop, a.stop, leave, 1, vehicles)
                    .into_iter()
                    .next()
                else {
                    continue;
                };
                let total = d.cost() + u64::from(walk(a.meters));
                // Strictly better only: on a tie the nearer pair, tried
                // first, stands — the same answer every time.
                if best.is_none_or(|(_, _, _, c)| total < c) {
                    best = Some((b, a, leave, total));
                }
            }
        }
        let Some((b, a, leave, _)) = best else {
            return err_rows("transit: no ride between those stations today");
        };
        let found = s.board_vehicles(b.stop, a.stop, leave, want, vehicles);
        let mut out = vec![
            info_row(&s),
            format!("od{UNIT}{}{UNIT}{}", near_fields(b), near_fields(a)),
        ];
        for d in found.iter().take(want) {
            dep_rows(d, &mut out);
        }
        out
    })
}

/// The vehicles a query may board, from the Swift side's mask of
/// `transit::Mode` bits. Zero, or anything that is not a mask, means the
/// rider named no vehicle — every one is allowed.
fn vehicle_mask(vehicles: i64) -> u8 {
    match u8::try_from(vehicles) {
        Ok(v) if v != 0 && v & !ALL_VEHICLES == 0 => v,
        _ => ALL_VEHICLES,
    }
}

/// One selection of toggles read as one trip (`flows_core::trip_shape`),
/// packed a byte per part.
pub fn flows_transit_trip_shape(
    on_foot: bool,
    train: bool,
    bus: bool,
    plane: bool,
    rental: bool,
    ship: bool,
    trip_miles: f64,
) -> i64 {
    let picked = Picked {
        on_foot,
        train,
        bus,
        plane,
        rental,
        ship,
    };
    contain(0, || {
        trip_shape::pack(trip_shape::shape(picked, trip_miles))
    })
}

/// Whether a city ride of `transit_seconds` should replace a walk.
pub fn flows_transit_beats_walk(walk_seconds: f64, walk_known: bool, transit_seconds: f64) -> bool {
    contain(false, || {
        trip_shape::transit_beats_walk(walk_known.then_some(walk_seconds), transit_seconds)
    })
}

/// Whether a city trip on any vehicle should replace the rider's chosen one.
pub fn flows_transit_other_vehicle_wins(
    chosen_seconds: f64,
    chosen_known: bool,
    other_seconds: f64,
) -> bool {
    contain(false, || {
        trip_shape::other_vehicle_wins(chosen_known.then_some(chosen_seconds), other_seconds)
    })
}

/// The mask that boards every vehicle — a rider who chose them all.
pub fn flows_transit_all_vehicles() -> i64 {
    i64::from(ALL_VEHICLES)
}

/// The mask of the vehicles that float.
pub fn flows_transit_ship_vehicles() -> i64 {
    i64::from(SHIP_VEHICLES)
}

/// The city's buses and trains: what stands in for a chosen bus or train
/// that cannot make a leg — never a ship.
pub fn flows_transit_land_vehicles() -> i64 {
    i64::from(LAND_VEHICLES)
}

/// Past this many miles a train or bus toggle means the intercity service.
pub fn flows_transit_long_haul_miles() -> f64 {
    trip_shape::LONG_HAUL_MILES
}

/// A walk to a station longer than this is driven, or offered a ride share.
pub fn flows_transit_far_walk_seconds() -> f64 {
    trip_shape::FAR_WALK_SECONDS
}

#[cfg(test)]
mod tests {
    use super::*;

    fn is_err(rows: &[String]) -> bool {
        rows.len() == 1 && rows[0].starts_with("err\u{1F}")
    }

    #[test]
    fn a_merge_refuses_inputs_it_cannot_place() {
        let two = format!("/a{UNIT}/b");
        assert!(
            is_err(&flows_transit_build_many(&two, &[0.0], "/tmp/x", 20260929)),
            "two feeds, one shift"
        );
        assert!(
            is_err(&flows_transit_build_many(
                &two,
                &[0.0, f64::NAN],
                "/tmp/x",
                20260929
            )),
            "a shift that is not a number"
        );
        assert!(
            is_err(&flows_transit_build_many(
                &two,
                &[0.0, 49.0 * 3600.0],
                "/tmp/x",
                20260929
            )),
            "no two real zones are two days apart"
        );
        assert!(
            is_err(&flows_transit_build_many(&two, &[0.0, 3600.0], "/tmp/x", 0)),
            "a merge must be told its day"
        );
        assert!(
            is_err(&flows_transit_build_many(
                &format!("/a{UNIT}"),
                &[0.0, 0.0],
                "/tmp/x",
                20260929
            )),
            "an empty directory name"
        );
    }

    #[test]
    fn a_trip_ending_in_milwaukee_is_offered_its_buses() {
        let rows = flows_transit_city_feeds(43.0389, -87.9065, 3);
        assert!(!rows.is_empty());
        let f: Vec<&str> = rows[0].split(UNIT).collect();
        assert_eq!(f.len(), 10, "{:?}", rows[0]);
        assert!(
            f[9].starts_with("https://"),
            "every feed has the catalog mirror"
        );
        assert_eq!(f[0], "feed");
        assert!(f[3].starts_with("http"));
        assert!(
            flows_transit_city_feeds(35.0, -40.0, 3).is_empty(),
            "mid-Atlantic"
        );
        assert!(flows_transit_city_feeds(43.0, -87.9, 0).is_empty());
    }

    #[test]
    fn a_vehicle_mask_that_is_not_one_means_every_vehicle() {
        use flows_core::transit::{BUS_VEHICLES, TRAIN_VEHICLES};
        assert_eq!(vehicle_mask(0), ALL_VEHICLES);
        assert_eq!(vehicle_mask(-1), ALL_VEHICLES);
        assert_eq!(vehicle_mask(1 << 9), ALL_VEHICLES);
        assert_eq!(
            vehicle_mask(0b100_0000),
            ALL_VEHICLES,
            "a bit no vehicle has"
        );
        assert_eq!(
            vehicle_mask(SHIP_VEHICLES.into()),
            SHIP_VEHICLES,
            "the ship's own bit"
        );
        assert_eq!(vehicle_mask(i64::from(BUS_VEHICLES)), BUS_VEHICLES);
        assert_eq!(vehicle_mask(i64::from(TRAIN_VEHICLES)), TRAIN_VEHICLES);
    }

    #[test]
    fn the_trip_shape_crosses_as_the_core_packs_it() {
        let packed = flows_transit_trip_shape(false, true, true, false, false, false, 400.0);
        let core = trip_shape::pack(trip_shape::shape(
            Picked {
                on_foot: false,
                train: true,
                bus: true,
                plane: false,
                rental: false,
                ship: false,
            },
            400.0,
        ));
        assert_eq!(packed, core);
        assert_eq!(packed & 0xFF, trip_shape::Main::Train as i64);
        assert!(flows_transit_beats_walk(0.0, false, 60.0));
        assert!(!flows_transit_beats_walk(600.0, true, 590.0));
        assert!(flows_transit_other_vehicle_wins(0.0, false, 60.0));
        assert!(!flows_transit_other_vehicle_wins(1_000.0, true, 900.0));
        assert_eq!(flows_transit_all_vehicles(), i64::from(ALL_VEHICLES));
        let ship = flows_transit_trip_shape(true, false, true, false, false, true, 12.0);
        assert_eq!(
            ship & 0xFF,
            trip_shape::Main::Ship as i64,
            "the ship is the ride"
        );
        assert_eq!(
            flows_transit_ship_vehicles() & flows_transit_land_vehicles(),
            0
        );
        assert_eq!(
            flows_transit_ship_vehicles() | flows_transit_land_vehicles(),
            flows_transit_all_vehicles()
        );
        let rows = flows_transit_ship_feeds(47.6062, -122.3321, 30.0, 4);
        assert!(
            rows.iter()
                .any(|r| r.starts_with("feed\u{1F}mdb-283\u{1F}")),
            "{rows:?}"
        );
        assert!(
            flows_transit_ship_feeds(39.7392, -104.9903, 30.0, 4).is_empty(),
            "Denver"
        );
        assert!(flows_transit_long_haul_miles() > 0.0);
        assert!(flows_transit_far_walk_seconds() > 0.0);
    }

    #[test]
    fn a_missing_first_feed_is_an_error_row_not_a_panic() {
        let rows = flows_transit_build_many(
            "/definitely/not/a/feed",
            &[0.0],
            "/tmp/flows_bridge_no_shard",
            20260929,
        );
        assert!(is_err(&rows), "got {rows:?}");
    }
}
