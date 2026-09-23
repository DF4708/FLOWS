// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! A **shard**: one region's timetable (`.ftt`) plus its labels (`.fts`), and
//! the two things the app actually asks of them — "which station is near me?"
//! and "what leaves after now, and when does it get in?".
//!
//! This is the whole surface the Swift side needs, kept in Rust so the bridge
//! stays a thin forwarder. Two rules shape it:
//!
//! * **No clock.** Nothing here reads the system time. A query takes seconds
//!   since the service day's midnight and returns the same; the caller owns the
//!   conversion, because the conversion needs a timezone database and Rust has
//!   none. See [`super::fts`] for why the zones ride along.
//! * **No panics on bad input.** A shard can arrive truncated, stale or from a
//!   feed that changed shape. Every entry point returns `Result` or an empty
//!   answer; none of them index blindly.

use std::io;
use std::path::{Path, PathBuf};

use super::fts::{self, Labels};
use super::ftt;
use super::gtfs;
use super::raptor::{self, Journey};
use super::{Time, Timetable};
use crate::seasonal::haversine_km;

/// The default RAPTOR round cap: 4 rounds = up to 3 transfers, which covers
/// every real intercity itinerary while keeping a query bounded.
pub const DEFAULT_MAX_ROUNDS: u32 = 4;

/// A timetable and its labels, read from `<prefix>.ftt` and `<prefix>.fts`.
pub struct Shard {
    pub timetable: Timetable,
    pub labels: Labels,
}

/// What a build produced — the counts the caller logs and shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BuildReport {
    pub ftt_path: PathBuf,
    pub fts_path: PathBuf,
    pub n_stops: usize,
    pub n_routes: usize,
    pub n_trips: usize,
    pub n_events: usize,
    pub service_date: u32,
    pub feed_published: u32,
    pub agency_zone: String,
    pub ftt_bytes: usize,
    pub fts_bytes: usize,
}

/// Build a shard from an unzipped GTFS directory: `<prefix>.ftt` gets the CSR
/// arrays RAPTOR runs over, `<prefix>.fts` gets the names, station codes and
/// zones. Both are written or neither is — the `.fts` carries the `.ftt`'s body
/// hash, so a half-finished pair is refused at open rather than mis-labelling
/// stations.
pub fn build(gtfs_dir: &Path, date: Option<u32>, prefix: &Path) -> Result<BuildReport, String> {
    let load = gtfs::load_gtfs(gtfs_dir, date).map_err(|e| e.to_string())?;
    write(&load, prefix)
}

/// Write an already-parsed feed as a shard pair. Split out from [`build`] so a
/// caller that already holds the load (the converter CLI, which then verifies
/// it) does not parse the feed twice.
pub fn write(load: &gtfs::GtfsLoad, prefix: &Path) -> Result<BuildReport, String> {
    let ftt_bytes = ftt::to_bytes(&load.timetable);
    let hash = ftt::body_hash(&ftt_bytes)
        .ok_or_else(|| "shard: encoded .ftt has no header".to_string())?;

    // The operator's own code is the stop_id for every North American rail feed
    // we ship (Amtrak's "CHI", VIA's "TRTO"), and it is what station deep links
    // are keyed by. Codes that are just row numbers are harmless: the caller
    // only uses one when it looks like a code.
    let labels = Labels {
        stop_names: load.stop_names.clone(),
        stop_codes: load.stop_ids.clone(),
        stop_zones: load.stop_zones.clone(),
        route_names: load.route_names.clone(),
        agency_zone: load.agency_timezone.clone(),
        service_date: load.service_date,
        feed_published: load.feed_published,
    };
    let fts_bytes = fts::to_bytes(&labels, hash);

    let ftt_path = with_ext(prefix, "ftt");
    let fts_path = with_ext(prefix, "fts");
    if let Some(dir) = ftt_path.parent() {
        if !dir.as_os_str().is_empty() {
            std::fs::create_dir_all(dir).map_err(|e| format!("shard: {}: {e}", dir.display()))?;
        }
    }
    std::fs::write(&ftt_path, &ftt_bytes)
        .map_err(|e| format!("shard: {}: {e}", ftt_path.display()))?;
    std::fs::write(&fts_path, &fts_bytes)
        .map_err(|e| format!("shard: {}: {e}", fts_path.display()))?;

    Ok(BuildReport {
        ftt_path,
        fts_path,
        n_stops: load.timetable.n_stops(),
        n_routes: load.timetable.n_routes(),
        n_trips: load.n_trips,
        n_events: load.n_events,
        service_date: load.service_date,
        feed_published: load.feed_published,
        agency_zone: load.agency_timezone.clone(),
        ftt_bytes: ftt_bytes.len(),
        fts_bytes: fts_bytes.len(),
    })
}

fn with_ext(prefix: &Path, ext: &str) -> PathBuf {
    let mut p = prefix.as_os_str().to_os_string();
    p.push(".");
    p.push(ext);
    PathBuf::from(p)
}

/// Read `<prefix>.ftt` + `<prefix>.fts`. Refuses a mismatched pair, a corrupt
/// body, and labels whose counts disagree with the timetable.
pub fn open(prefix: &Path) -> io::Result<Shard> {
    let raw = std::fs::read(with_ext(prefix, "ftt"))?;
    let hash = ftt::body_hash(&raw)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "shard: not an .ftt"))?;
    let timetable = ftt::from_bytes(&raw)?;
    let labels = fts::read_fts(&with_ext(prefix, "fts"), hash)?;
    if labels.stop_names.len() != timetable.n_stops()
        || labels.route_names.len() != timetable.n_routes()
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "shard: label counts disagree with the timetable",
        ));
    }
    Ok(Shard { timetable, labels })
}

/// A station near a point: which stop, how far, and what to call it.
#[derive(Clone, Debug, PartialEq)]
pub struct NearStop {
    pub stop: u32,
    pub meters: f64,
    pub name: String,
    pub code: String,
    pub zone: String,
}

/// One ride in a rendered itinerary. Times are seconds from the service day's
/// midnight **in the shard's agency zone** — the caller turns them into clocks.
#[derive(Clone, Debug, PartialEq)]
pub struct RideLeg {
    pub board_name: String,
    pub board_code: String,
    pub board_zone: String,
    pub alight_name: String,
    pub alight_code: String,
    pub alight_zone: String,
    pub route_name: String,
    pub mode: u8,
    pub dep: Time,
    pub arr: Time,
}

/// A departure the app can show: the rides, the walking between them, and the
/// totals. `walk_secs` is time on foot transferring, not the walk to the first
/// station — that is the caller's, who knows where the rider actually is.
#[derive(Clone, Debug, PartialEq)]
pub struct Departure {
    pub legs: Vec<RideLeg>,
    pub dep: Time,
    pub arr: Time,
    pub n_transfers: u32,
    pub walk_secs: Time,
}

impl Shard {
    /// The service date these times belong to (YYYYMMDD).
    pub fn service_date(&self) -> u32 {
        self.labels.service_date
    }

    /// The zone every time in this shard is measured from.
    pub fn agency_zone(&self) -> &str {
        &self.labels.agency_zone
    }

    /// The nearest stops to a point that something actually calls at, closest
    /// first, within `max_meters`. `limit` caps the list; a rider near two
    /// stations should see the one their train stops at, so the caller plans
    /// from several and keeps whichever produces a journey.
    pub fn nearest_stops(
        &self,
        lat: f64,
        lon: f64,
        max_meters: f64,
        limit: usize,
    ) -> Vec<NearStop> {
        if limit == 0
            || !lat.is_finite()
            || !lon.is_finite()
            || max_meters <= 0.0
            || max_meters.is_nan()
        {
            return Vec::new();
        }
        let mut found: Vec<(f64, u32)> = Vec::new();
        for s in 0..self.timetable.n_stops() as u32 {
            if self.timetable.n_routes_at(s) == 0 {
                continue;
            }
            let p = self.timetable.stop(s);
            let m = haversine_km(lat, lon, p.lat_e6 as f64 / 1e6, p.lon_e6 as f64 / 1e6) * 1000.0;
            if m <= max_meters {
                found.push((m, s));
            }
        }
        found.sort_by(|a, b| a.0.total_cmp(&b.0).then(a.1.cmp(&b.1)));
        found.truncate(limit);
        found
            .into_iter()
            .map(|(meters, stop)| NearStop {
                stop,
                meters,
                name: self.stop_name(stop),
                code: self.stop_code(stop),
                zone: self.stop_zone(stop),
            })
            .collect()
    }

    fn stop_name(&self, s: u32) -> String {
        self.labels
            .stop_names
            .get(s as usize)
            .cloned()
            .unwrap_or_default()
    }

    fn stop_code(&self, s: u32) -> String {
        self.labels
            .stop_codes
            .get(s as usize)
            .cloned()
            .unwrap_or_default()
    }

    fn stop_zone(&self, s: u32) -> String {
        self.labels
            .stop_zones
            .get(s as usize)
            .filter(|z| !z.is_empty())
            .cloned()
            .unwrap_or_else(|| self.labels.agency_zone.clone())
    }

    fn route_name(&self, r: u32) -> String {
        self.labels
            .route_names
            .get(r as usize)
            .cloned()
            .unwrap_or_default()
    }

    /// Plan from `source` to `target` leaving no earlier than `depart` seconds
    /// after service midnight, and render the Pareto set as departures. A
    /// journey with no ride at all (pure walking) is dropped: it is not a
    /// departure, and the caller already knows how to walk.
    pub fn departures(&self, source: u32, target: u32, depart: Time) -> Vec<Departure> {
        let n = self.timetable.n_stops() as u32;
        if source >= n || target >= n || source == target {
            return Vec::new();
        }
        raptor::plan(&self.timetable, source, target, depart, DEFAULT_MAX_ROUNDS)
            .into_iter()
            .filter_map(|j| self.render(&j))
            .collect()
    }

    /// A departure BOARD: the next `count` distinct departures from `source`
    /// to `target` at or after `after`, earliest first.
    ///
    /// Not the same thing as [`Self::departures`], and the difference matters
    /// on screen. One RAPTOR query answers "leaving now, what are my options?"
    /// — a Pareto set trading arrival time against transfers, all of which may
    /// ride the SAME train. A rider reading a card wants the other question:
    /// "when does one go, and when is the next?". So each round takes the
    /// earliest-departing journey and asks again from one second later.
    pub fn board(&self, source: u32, target: u32, after: Time, count: usize) -> Vec<Departure> {
        let mut out = Vec::new();
        let mut from_time = after;
        for _ in 0..count {
            // Among journeys that leave at the same moment, the one that gets
            // there soonest is the one to name.
            let best = self
                .departures(source, target, from_time)
                .into_iter()
                .min_by_key(|d| (d.dep, d.arr));
            let Some(d) = best else { break };
            from_time = d.dep.saturating_add(1);
            out.push(d);
        }
        out
    }

    fn render(&self, j: &Journey) -> Option<Departure> {
        let legs: Vec<RideLeg> = j
            .legs
            .iter()
            .filter(|l| l.kind == raptor::LegKind::Ride)
            .map(|l| RideLeg {
                board_name: self.stop_name(l.from_stop),
                board_code: self.stop_code(l.from_stop),
                board_zone: self.stop_zone(l.from_stop),
                alight_name: self.stop_name(l.to_stop),
                alight_code: self.stop_code(l.to_stop),
                alight_zone: self.stop_zone(l.to_stop),
                route_name: self.route_name(l.route),
                mode: l.mode as u8,
                dep: l.dep,
                arr: l.arr,
            })
            .collect();
        let dep = legs.first()?.dep;
        Some(Departure {
            legs,
            dep,
            arr: j.arrival,
            n_transfers: j.n_transfers,
            walk_secs: j.walk_secs,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transit::fts;

    /// A two-timezone feed, because that is the case that breaks: the agency
    /// keeps Eastern time, one station is in Mountain, and the stored 09:00 is
    /// 7:00 AM on that platform.
    fn write_feed(name: &str) -> PathBuf {
        let mut dir = std::env::temp_dir();
        dir.push(format!("flows_shard_{}_{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let files: &[(&str, &str)] = &[
            (
                "agency.txt",
                "agency_id,agency_name,agency_timezone\n1,Test Rail,America/New_York\n",
            ),
            (
                "feed_info.txt",
                "feed_publisher_name,feed_publisher_url,feed_lang,feed_version,feed_start_date\n\
                 Test,http://example.invalid,en,20260921,20260923\n",
            ),
            (
                "stops.txt",
                "stop_id,stop_name,stop_timezone,stop_lat,stop_lon\n\
                 EAS,East Station,America/New_York,40.70,-74.00\n\
                 MID,Middle Station,,39.95,-75.16\n\
                 WES,West Station,America/Denver,39.74,-104.98\n\
                 GHOST,Nobody Calls Here,America/New_York,40.71,-74.01\n",
            ),
            (
                "routes.txt",
                "route_id,route_short_name,route_long_name,route_type\nR1,,Western Star,2\n",
            ),
            (
                "calendar.txt",
                "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n\
                 WK,1,1,1,1,1,1,1,20260901,20261231\n",
            ),
            ("trips.txt", "route_id,service_id,trip_id\nR1,WK,t1\n"),
            (
                "stop_times.txt",
                "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n\
                 t1,09:00:00,09:00:00,EAS,1\n\
                 t1,10:30:00,10:35:00,MID,2\n\
                 t1,18:00:00,18:00:00,WES,3\n",
            ),
        ];
        for (f, c) in files {
            std::fs::write(dir.join(f), c).unwrap();
        }
        dir
    }

    fn build_tmp(name: &str) -> (PathBuf, PathBuf, Shard) {
        let dir = write_feed(name);
        let mut prefix = std::env::temp_dir();
        prefix.push(format!("flows_shard_out_{}_{}", name, std::process::id()));
        let report = build(&dir, Some(20260923), &prefix).unwrap();
        assert_eq!(report.service_date, 20260923);
        let s = open(&prefix).unwrap();
        (dir, prefix, s)
    }

    fn clean(dir: &Path, prefix: &Path) {
        let _ = std::fs::remove_dir_all(dir);
        let _ = std::fs::remove_file(with_ext(prefix, "ftt"));
        let _ = std::fs::remove_file(with_ext(prefix, "fts"));
    }

    #[test]
    fn a_shard_round_trips_its_labels() {
        let (dir, prefix, s) = build_tmp("roundtrip");
        assert_eq!(s.agency_zone(), "America/New_York");
        assert_eq!(s.service_date(), 20260923);
        assert_eq!(s.labels.feed_published, 20260921, "feed_version is a date");
        assert_eq!(s.labels.stop_names.len(), s.timetable.n_stops());
        assert_eq!(s.labels.route_names.len(), s.timetable.n_routes());
        let west = s.labels.stop_codes.iter().position(|c| c == "WES").unwrap();
        assert_eq!(s.labels.stop_names[west], "West Station");
        assert_eq!(s.labels.stop_zones[west], "America/Denver");
        clean(&dir, &prefix);
    }

    #[test]
    fn a_blank_stop_timezone_inherits_the_agency() {
        let (dir, prefix, s) = build_tmp("blanktz");
        let mid = s.labels.stop_codes.iter().position(|c| c == "MID").unwrap();
        assert_eq!(
            s.labels.stop_zones[mid], "America/New_York",
            "GTFS: a stop with no zone of its own keeps the agency's"
        );
        clean(&dir, &prefix);
    }

    #[test]
    fn a_departure_carries_the_zone_of_each_end() {
        let (dir, prefix, s) = build_tmp("zones");
        let from = s.labels.stop_codes.iter().position(|c| c == "EAS").unwrap() as u32;
        let to = s.labels.stop_codes.iter().position(|c| c == "WES").unwrap() as u32;
        let ds = s.departures(from, to, 8 * 3600);
        assert_eq!(ds.len(), 1, "one train a day");
        let d = &ds[0];
        assert_eq!(d.dep, 9 * 3600, "stored in the AGENCY's zone");
        assert_eq!(d.arr, 18 * 3600);
        assert_eq!(d.n_transfers, 0);
        let leg = &d.legs[0];
        assert_eq!(leg.board_zone, "America/New_York");
        assert_eq!(leg.alight_zone, "America/Denver");
        assert_eq!(leg.board_name, "East Station");
        assert_eq!(leg.alight_code, "WES");
        assert_eq!(leg.route_name, "Western Star");
        clean(&dir, &prefix);
    }

    #[test]
    fn a_board_lists_later_trains_not_the_same_one_twice() {
        let (dir, prefix, s) = build_tmp("board");
        let from = s.labels.stop_codes.iter().position(|c| c == "EAS").unwrap() as u32;
        let to = s.labels.stop_codes.iter().position(|c| c == "WES").unwrap() as u32;
        // One train a day in this feed: a board of four must still be one
        // entry, never the same departure repeated or looped forever.
        let board = s.board(from, to, 0, 4);
        assert_eq!(board.len(), 1);
        assert_eq!(board[0].dep, 9 * 3600);
        // And a Pareto query at the same moment may hold several options,
        // all of them THIS train — which is why a board is not that list.
        let pareto = s.departures(from, to, 0);
        assert!(pareto.iter().all(|d| d.dep == 9 * 3600));
        clean(&dir, &prefix);
    }

    #[test]
    fn a_train_already_gone_is_not_a_departure() {
        let (dir, prefix, s) = build_tmp("gone");
        let from = s.labels.stop_codes.iter().position(|c| c == "EAS").unwrap() as u32;
        let to = s.labels.stop_codes.iter().position(|c| c == "WES").unwrap() as u32;
        assert!(
            s.departures(from, to, 12 * 3600).is_empty(),
            "the 09:00 has left; nothing else runs"
        );
        assert!(s.departures(from, from, 0).is_empty(), "same stop");
        let n = s.timetable.n_stops() as u32;
        assert!(s.departures(n, 0, 0).is_empty(), "out-of-range stop");
        clean(&dir, &prefix);
    }

    #[test]
    fn nearest_skips_stops_nothing_calls_at() {
        let (dir, prefix, s) = build_tmp("nearest");
        // Sitting on top of GHOST, which no trip ever visits.
        let near = s.nearest_stops(40.71, -74.01, 5_000.0, 3);
        assert!(!near.is_empty());
        assert_eq!(
            near[0].code, "EAS",
            "a station no train calls at is not a station to wait at"
        );
        assert!(near[0].meters < 2_000.0);
        assert!(near.iter().all(|n| n.code != "GHOST"));
        assert!(
            s.nearest_stops(40.71, -74.01, 5.0, 3).is_empty(),
            "nothing within five metres"
        );
        assert!(s.nearest_stops(40.71, -74.01, 5_000.0, 0).is_empty());
        assert!(s.nearest_stops(f64::NAN, -74.01, 5_000.0, 3).is_empty());
        clean(&dir, &prefix);
    }

    #[test]
    fn labels_from_another_build_are_refused() {
        let (dir, prefix, _s) = build_tmp("mismatch");
        let raw = std::fs::read(with_ext(&prefix, "ftt")).unwrap();
        let hash = ftt::body_hash(&raw).unwrap();
        let labels = fts::read_fts(&with_ext(&prefix, "fts"), hash).unwrap();
        // Same labels, stamped as belonging to a different timetable.
        let bytes = fts::to_bytes(&labels, hash ^ 1);
        std::fs::write(with_ext(&prefix, "fts"), &bytes).unwrap();
        let err = match open(&prefix) {
            Ok(_) => panic!("mismatched labels were accepted"),
            Err(e) => e,
        };
        assert!(err.to_string().contains("do not belong"), "got: {err}");
        clean(&dir, &prefix);
    }

    #[test]
    fn a_corrupt_sidecar_is_refused_not_guessed() {
        let (dir, prefix, _s) = build_tmp("corrupt");
        let raw = std::fs::read(with_ext(&prefix, "ftt")).unwrap();
        let hash = ftt::body_hash(&raw).unwrap();
        let good = std::fs::read(with_ext(&prefix, "fts")).unwrap();

        assert!(
            fts::from_bytes(&good[..FTS_HEADER_LEN_TEST], hash).is_err(),
            "no body"
        );
        let mut flipped = good.clone();
        let last = flipped.len() - 1;
        flipped[last] ^= 0xff;
        assert!(
            fts::from_bytes(&flipped, hash).is_err(),
            "body hash guards the text"
        );
        let mut wrong_magic = good.clone();
        wrong_magic[0] = b'X';
        assert!(fts::from_bytes(&wrong_magic, hash).is_err(), "magic");
        let mut wrong_version = good.clone();
        wrong_version[4] = 9;
        assert!(fts::from_bytes(&wrong_version, hash).is_err(), "version");
        clean(&dir, &prefix);
    }

    const FTS_HEADER_LEN_TEST: usize = 64;
}
