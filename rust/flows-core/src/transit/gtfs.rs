// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! GTFS-Schedule → [`Timetable`] — the offline ingestion half of Phase 1.
//! Pure std (zero external crates): an owned RFC-4180 CSV reader, GTFS time /
//! date arithmetic, service-calendar expansion, `frequencies.txt` expansion,
//! and the load-bearing RAPTOR derivation — trips grouped by **identical
//! ordered stop sequence** per GTFS route, sorted by first departure, with
//! **overtaking trips split into separate engine routes** so `earliest_trip`'s
//! binary-search invariant (departure non-decreasing in trip index at every
//! stop) always holds.
//!
//! This module reads an already-unzipped GTFS directory (see
//! `scripts/fetch_gtfs.sh`); nothing here ever ships on-device — the app only
//! sees the `.ftt` this feeds into (`transit::ftt`).
//!
//! Handled GTFS surface: `stops.txt`, `routes.txt`, `trips.txt`,
//! `stop_times.txt`, `calendar.txt` and/or `calendar_dates.txt` (either model
//! alone works — NYC subway is calendar_dates-only), optional `transfers.txt`
//! (→ footpaths) and optional `frequencies.txt` (headway trips expanded to
//! concrete departures). Quoted CSV fields (embedded commas/quotes/newlines),
//! CRLF, UTF-8 BOM, missing optional columns, `H:MM:SS`/`HH:MM:SS` times past
//! 24:00:00, and blank non-timepoint times (linearly interpolated) are all
//! handled. GTFS times are agency-local; a single feed is internally
//! consistent — cross-timezone normalization happens at the multi-shard
//! stitch, not here (see docs/TRANSIT_ROUTING.md).

use std::collections::HashMap;
use std::fmt;
use std::fs::File;
use std::io::{self, BufRead, BufReader};
use std::path::Path;

use super::{Mode, Time, Timetable, TimetableBuilder, TripEvents, StopEvent};

/// Ingestion error: an I/O failure or a described feed problem.
#[derive(Debug)]
pub struct GtfsError(pub String);

impl fmt::Display for GtfsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for GtfsError {}

impl From<io::Error> for GtfsError {
    fn from(e: io::Error) -> Self {
        GtfsError(format!("io: {e}"))
    }
}

fn err(msg: impl Into<String>) -> GtfsError {
    GtfsError(msg.into())
}

// -----------------------------------------------------------------------------
// CSV — owned RFC-4180 reader (streaming, record-at-a-time).
// -----------------------------------------------------------------------------

/// Hard per-field ceiling. No real GTFS field approaches 1 MiB; a field that
/// does means a stray quote is swallowing the rest of the file, and the parse
/// must fail loudly instead of buffering without bound (the reader's contract
/// is streaming, record-at-a-time memory).
const MAX_FIELD_BYTES: usize = 1 << 20;

/// Streaming RFC-4180 CSV record reader over any [`BufRead`]. Handles quoted
/// fields containing commas, `""`-escaped quotes, and embedded newlines; CRLF
/// and LF line endings; a UTF-8 BOM on the first record; and skips blank
/// lines. Never loads the whole file (NYC-scale `stop_times.txt` is ~2 GB);
/// a field past [`MAX_FIELD_BYTES`] is an error, not an allocation.
pub(crate) struct CsvReader<R: BufRead> {
    r: R,
    first: bool,
}

impl<R: BufRead> CsvReader<R> {
    pub(crate) fn new(r: R) -> Self {
        CsvReader { r, first: true }
    }

    /// Next record, or `None` at EOF. Blank lines are skipped.
    pub(crate) fn next_record(&mut self) -> io::Result<Option<Vec<String>>> {
        loop {
            match self.raw_record()? {
                None => return Ok(None),
                Some(rec) => {
                    if rec.len() == 1 && rec[0].is_empty() {
                        continue; // blank line
                    }
                    return Ok(Some(rec));
                }
            }
        }
    }

    fn raw_record(&mut self) -> io::Result<Option<Vec<String>>> {
        let mut fields: Vec<String> = Vec::new();
        let mut field: Vec<u8> = Vec::new();
        let mut in_quotes = false;
        let mut consumed_anything = false;

        let finish = |bytes: &mut Vec<u8>| -> String {
            let s = String::from_utf8_lossy(bytes).trim().to_string();
            bytes.clear();
            s
        };

        loop {
            let mut line: Vec<u8> = Vec::new();
            let n = self.r.read_until(b'\n', &mut line)?;
            if n == 0 {
                // EOF: emit the pending record, if any bytes were consumed.
                if !consumed_anything {
                    return Ok(None);
                }
                fields.push(finish(&mut field));
                return Ok(Some(fields));
            }
            consumed_anything = true;
            let mut start = 0usize;
            if self.first {
                self.first = false;
                if line.starts_with(&[0xEF, 0xBB, 0xBF]) {
                    start = 3; // strip UTF-8 BOM
                }
            }

            let mut i = start;
            while i < line.len() {
                let c = line[i];
                if in_quotes {
                    if c == b'"' {
                        if i + 1 < line.len() && line[i + 1] == b'"' {
                            field.push(b'"'); // escaped quote
                            i += 2;
                            continue;
                        }
                        in_quotes = false;
                    } else {
                        field.push(c);
                    }
                } else {
                    match c {
                        b'"' => in_quotes = true,
                        b',' => fields.push(finish(&mut field)),
                        b'\r' => {} // CRLF (or stray CR): dropped
                        b'\n' => {
                            fields.push(finish(&mut field));
                            return Ok(Some(fields));
                        }
                        _ => field.push(c),
                    }
                }
                i += 1;
            }
            if field.len() > MAX_FIELD_BYTES {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "csv: field exceeds the 1 MiB cap (unbalanced quote?)",
                ));
            }
            // Line ended while inside quotes: the '\n' read_until consumed is
            // already in `line` and was pushed as field content above; the
            // record simply continues on the next line. (A line can also end
            // without '\n' at EOF — the next read returns 0 and finishes the
            // record.)
        }
    }
}

/// Column lookup by (case-insensitive, trimmed) header name.
struct Header {
    idx: HashMap<String, usize>,
}

impl Header {
    fn new(row: &[String]) -> Self {
        let mut idx = HashMap::new();
        for (i, name) in row.iter().enumerate() {
            idx.entry(name.trim().to_ascii_lowercase()).or_insert(i);
        }
        Header { idx }
    }

    fn get(&self, name: &str) -> Option<usize> {
        self.idx.get(name).copied()
    }

    fn req(&self, name: &str, file: &str) -> Result<usize, GtfsError> {
        self.get(name)
            .ok_or_else(|| err(format!("{file}: missing required column '{name}'")))
    }
}

/// Field accessor tolerant of short rows and absent optional columns.
fn f(row: &[String], i: Option<usize>) -> &str {
    i.and_then(|i| row.get(i)).map(String::as_str).unwrap_or("")
}

/// A named GTFS file, opened: its parsed header + a line reader (None when
/// the file is absent — most GTFS extras are optional).
type OpenedCsv = Option<(Header, CsvReader<BufReader<File>>)>;

fn open_csv(dir: &Path, name: &str) -> Result<OpenedCsv, GtfsError> {
    let path = dir.join(name);
    if !path.exists() {
        return Ok(None);
    }
    let mut r = CsvReader::new(BufReader::new(File::open(&path)?));
    match r.next_record()? {
        None => Ok(None), // empty file == absent
        Some(h) => Ok(Some((Header::new(&h), r))),
    }
}

// -----------------------------------------------------------------------------
// GTFS time & date arithmetic (pure integer math, no system clock).
// -----------------------------------------------------------------------------

/// Parse a GTFS `HH:MM:SS` (or `H:MM:SS`) time into seconds since service
/// midnight. Hours may exceed 24 (service past midnight — "25:30:00" is valid
/// and later than any same-service-day 24h time). Blank/invalid → `None`.
pub(crate) fn parse_gtfs_time(s: &str) -> Option<Time> {
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    let mut it = s.split(':');
    let (h, m, sec) = (it.next()?, it.next()?, it.next()?);
    if it.next().is_some() {
        return None;
    }
    let h: u32 = h.trim().parse().ok()?;
    let m: u32 = m.trim().parse().ok()?;
    let sec: u32 = sec.trim().parse().ok()?;
    // GTFS allows hours past 24 for trips after midnight, but never anywhere
    // near this — cap at 48 h so h*3600 can't overflow u32 in release (which
    // would wrap a garbage hour to a valid-looking time).
    if h > 48 || m > 59 || sec > 59 {
        return None;
    }
    Some(h * 3600 + m * 60 + sec)
}

/// Parse a GTFS `YYYYMMDD` date. Validates month/day ranges.
fn parse_date(s: &str) -> Option<u32> {
    let s = s.trim();
    if s.len() != 8 || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let v: u32 = s.parse().ok()?;
    let (m, d) = ((v / 100) % 100, v % 100);
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    Some(v)
}

/// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm —
/// exact integer arithmetic, valid across the Gregorian calendar).
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as u64; // [0, 399]
    let mp = ((m + 9) % 12) as u64; // March = 0
    let doy = (153 * mp + 2) / 5 + (d as u64 - 1); // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146097 + doe as i64 - 719468
}

/// Inverse of [`days_from_civil`].
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32; // [1, 12]
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn date_to_days(date: u32) -> i64 {
    days_from_civil((date / 10000) as i64, (date / 100) % 100, date % 100)
}

fn days_to_date(days: i64) -> u32 {
    let (y, m, d) = civil_from_days(days);
    (y as u32) * 10000 + m * 100 + d
}

/// Weekday of a `YYYYMMDD` date, 0 = Monday .. 6 = Sunday.
/// (1970-01-01 was a Thursday.)
pub(crate) fn weekday_index(date: u32) -> usize {
    (((date_to_days(date) % 7) + 7 + 3) % 7) as usize
}

// -----------------------------------------------------------------------------
// Service calendar — calendar.txt weekly patterns + calendar_dates exceptions.
// -----------------------------------------------------------------------------

struct ServiceCalendar {
    /// (service_id, active-weekday flags Mon..Sun, start YYYYMMDD, end YYYYMMDD)
    weekly: Vec<(String, [bool; 7], u32, u32)>,
    /// exception_type 1: (date -> service_ids added that date)
    added: HashMap<u32, Vec<String>>,
    /// exception_type 2: (service_id, date) removed
    removed: std::collections::HashSet<(String, u32)>,
    /// All dates mentioned anywhere (for the default-date scan).
    min_date: Option<u32>,
    max_date: Option<u32>,
}

impl ServiceCalendar {
    fn load(dir: &Path) -> Result<Self, GtfsError> {
        let mut cal = ServiceCalendar {
            weekly: Vec::new(),
            added: HashMap::new(),
            removed: std::collections::HashSet::new(),
            min_date: None,
            max_date: None,
        };
        let span = |d: u32, cal: &mut ServiceCalendar| {
            cal.min_date = Some(cal.min_date.map_or(d, |m| m.min(d)));
            cal.max_date = Some(cal.max_date.map_or(d, |m| m.max(d)));
        };

        if let Some((h, mut r)) = open_csv(dir, "calendar.txt")? {
            let sid = h.req("service_id", "calendar.txt")?;
            let days = [
                h.get("monday"),
                h.get("tuesday"),
                h.get("wednesday"),
                h.get("thursday"),
                h.get("friday"),
                h.get("saturday"),
                h.get("sunday"),
            ];
            let (cs, ce) = (h.get("start_date"), h.get("end_date"));
            while let Some(row) = r.next_record()? {
                let id = f(&row, Some(sid)).to_string();
                if id.is_empty() {
                    continue;
                }
                let mut flags = [false; 7];
                for (i, col) in days.iter().enumerate() {
                    flags[i] = f(&row, *col).trim() == "1";
                }
                let (Some(start), Some(end)) = (parse_date(f(&row, cs)), parse_date(f(&row, ce)))
                else {
                    continue;
                };
                span(start, &mut cal);
                span(end, &mut cal);
                cal.weekly.push((id, flags, start, end));
            }
        }

        if let Some((h, mut r)) = open_csv(dir, "calendar_dates.txt")? {
            let sid = h.req("service_id", "calendar_dates.txt")?;
            let dcol = h.req("date", "calendar_dates.txt")?;
            let ecol = h.req("exception_type", "calendar_dates.txt")?;
            while let Some(row) = r.next_record()? {
                let id = f(&row, Some(sid)).to_string();
                let Some(date) = parse_date(f(&row, Some(dcol))) else {
                    continue;
                };
                span(date, &mut cal);
                match f(&row, Some(ecol)).trim() {
                    "1" => cal.added.entry(date).or_default().push(id),
                    "2" => {
                        cal.removed.insert((id, date));
                    }
                    _ => {}
                }
            }
        }

        if cal.weekly.is_empty() && cal.added.is_empty() {
            return Err(err(
                "feed has neither calendar.txt weekly service nor calendar_dates.txt added dates",
            ));
        }
        Ok(cal)
    }

    /// Service ids active on `date` (weekly pattern minus removals, plus adds).
    fn active_on(&self, date: u32) -> std::collections::HashSet<String> {
        let wd = weekday_index(date);
        let mut set = std::collections::HashSet::new();
        for (id, flags, start, end) in &self.weekly {
            if flags[wd] && *start <= date && date <= *end
                && !self.removed.contains(&(id.clone(), date))
            {
                set.insert(id.clone());
            }
        }
        if let Some(adds) = self.added.get(&date) {
            for id in adds {
                set.insert(id.clone());
            }
        }
        set
    }

    /// The first weekday (Mon–Fri) the calendar covers that has at least one
    /// active service — the converter's default date. No system clock.
    fn first_active_weekday(&self) -> Option<u32> {
        let (min, max) = (self.min_date?, self.max_date?);
        let mut days = date_to_days(min);
        let last = date_to_days(max);
        while days <= last {
            let date = days_to_date(days);
            if weekday_index(date) < 5 && !self.active_on(date).is_empty() {
                return Some(date);
            }
            days += 1;
        }
        None
    }
}

// -----------------------------------------------------------------------------
// Mode mapping — GTFS route_type (base + extended) → the engine's mode byte.
// -----------------------------------------------------------------------------

/// Map a GTFS `route_type` to [`Mode`] (see `transit::Mode` — the `.ftt` mode
/// byte). Base types 0–12 and the extended (Google/NeTEx) 3-digit ranges are
/// covered; anything unknown degrades to `Bus` (the most conservative speed
/// assumption). Suburban-railway extended codes map to `Commuter`.
pub(crate) fn mode_for_route_type(rt: i64) -> Mode {
    match rt {
        106 | 109 => Mode::Commuter,           // suburban / commuter railway
        2 | 100..=199 => Mode::Rail,           // intercity/long-distance rail
        0 | 1 | 5 | 6 | 7 | 12 => Mode::Subway, // tram/metro/cable/funicular/monorail
        3 | 11 => Mode::Bus,                   // bus / trolleybus
        200..=299 => Mode::Coach,              // coach services
        400..=499 | 900..=999 => Mode::Subway, // urban railway / tram services
        700..=899 => Mode::Bus,                // bus / trolleybus services
        _ => Mode::Bus,
    }
}

// -----------------------------------------------------------------------------
// Loading
// -----------------------------------------------------------------------------

/// A loaded service day: the engine [`Timetable`] plus the sidecar labels the
/// CLI (and later the manifest builder) needs. Names/ids are NOT part of the
/// `.ftt` v1 arrays — they stay offline.
pub struct GtfsLoad {
    pub timetable: Timetable,
    /// Dense stop index → GTFS `stop_id`.
    pub stop_ids: Vec<String>,
    /// Dense stop index → `stop_name` (may be empty).
    pub stop_names: Vec<String>,
    /// Engine route index → human label ("28 Route 28" style).
    pub route_names: Vec<String>,
    /// The service date actually built (YYYYMMDD).
    pub service_date: u32,
    /// GTFS trips active on the date (before frequency expansion).
    pub n_gtfs_trips: usize,
    /// Concrete trips in the timetable (after frequency expansion).
    pub n_trips: usize,
    /// Total stop-events (the memory-dominant count).
    pub n_events: usize,
    /// Extra engine routes created because trips overtook within a pattern.
    pub n_overtake_splits: usize,
    /// Trips dropped (fewer than 2 usable stops, or missing endpoint times).
    pub n_dropped_trips: usize,
    /// Dense stop index → number of trip visits (busyness, for stop picking).
    pub stop_visits: Vec<u32>,
}

/// One trip's working data while grouping.
struct RawTrip {
    route: u32, // index into the GTFS routes vec
    pattern: Vec<u32>,
    events: TripEvents,
}

/// Load an unzipped GTFS directory into a single-service-day [`Timetable`].
/// `date` is `YYYYMMDD`; `None` uses the first weekday the calendar covers
/// with active service (never the system clock — wrappers pass "today" in).
pub fn load_gtfs(dir: &Path, date: Option<u32>) -> Result<GtfsLoad, GtfsError> {
    if !dir.is_dir() {
        return Err(err(format!("not a directory: {}", dir.display())));
    }

    // --- stops.txt → dense ids. All rows kept (stations/entrances included;
    // only stops referenced by trips/transfers ever matter to RAPTOR). ---
    let (h, mut r) = open_csv(dir, "stops.txt")?
        .ok_or_else(|| err("stops.txt missing or empty"))?;
    let c_id = h.req("stop_id", "stops.txt")?;
    let (c_name, c_lat, c_lon) = (h.get("stop_name"), h.get("stop_lat"), h.get("stop_lon"));
    let mut stop_ids: Vec<String> = Vec::new();
    let mut stop_names: Vec<String> = Vec::new();
    let mut stop_latlon: Vec<(i32, i32)> = Vec::new();
    let mut stop_index: HashMap<String, u32> = HashMap::new();
    while let Some(row) = r.next_record()? {
        let id = f(&row, Some(c_id));
        if id.is_empty() || stop_index.contains_key(id) {
            continue;
        }
        let lat = f(&row, c_lat).parse::<f64>().unwrap_or(0.0);
        let lon = f(&row, c_lon).parse::<f64>().unwrap_or(0.0);
        stop_index.insert(id.to_string(), stop_ids.len() as u32);
        stop_ids.push(id.to_string());
        stop_names.push(f(&row, c_name).to_string());
        stop_latlon.push(((lat * 1e6).round() as i32, (lon * 1e6).round() as i32));
    }
    if stop_ids.is_empty() {
        return Err(err("stops.txt has no stops"));
    }

    // --- routes.txt → mode + label. ---
    let (h, mut r) = open_csv(dir, "routes.txt")?
        .ok_or_else(|| err("routes.txt missing or empty"))?;
    let c_id = h.req("route_id", "routes.txt")?;
    let (c_type, c_short, c_long) = (
        h.get("route_type"),
        h.get("route_short_name"),
        h.get("route_long_name"),
    );
    let mut route_modes: Vec<Mode> = Vec::new();
    let mut gtfs_route_names: Vec<String> = Vec::new();
    let mut route_index: HashMap<String, u32> = HashMap::new();
    while let Some(row) = r.next_record()? {
        let id = f(&row, Some(c_id));
        if id.is_empty() || route_index.contains_key(id) {
            continue;
        }
        let rt: i64 = f(&row, c_type).trim().parse().unwrap_or(3);
        let short = f(&row, c_short);
        let long = f(&row, c_long);
        let name = if short.is_empty() {
            long.to_string()
        } else if long.is_empty() || long == short {
            short.to_string()
        } else {
            format!("{short} {long}")
        };
        route_index.insert(id.to_string(), route_modes.len() as u32);
        route_modes.push(mode_for_route_type(rt));
        gtfs_route_names.push(name);
    }

    // --- calendar → the service date and its active service_ids. ---
    let cal = ServiceCalendar::load(dir)?;
    let service_date = match date {
        Some(d) => d,
        None => cal
            .first_active_weekday()
            .ok_or_else(|| err("calendar covers no weekday with active service"))?,
    };
    let active = cal.active_on(service_date);
    if active.is_empty() {
        return Err(err(format!(
            "no service active on {service_date}; feed calendar covers {}..{}",
            cal.min_date.unwrap_or(0),
            cal.max_date.unwrap_or(0)
        )));
    }

    // --- trips.txt: keep only trips whose service runs on the date. ---
    let (h, mut r) = open_csv(dir, "trips.txt")?
        .ok_or_else(|| err("trips.txt missing or empty"))?;
    let c_trip = h.req("trip_id", "trips.txt")?;
    let c_route = h.req("route_id", "trips.txt")?;
    let c_service = h.req("service_id", "trips.txt")?;
    // trip_id -> gtfs route index
    let mut active_trips: HashMap<String, u32> = HashMap::new();
    while let Some(row) = r.next_record()? {
        let service = f(&row, Some(c_service));
        if !active.contains(service) {
            continue;
        }
        let trip = f(&row, Some(c_trip));
        let Some(&route) = route_index.get(f(&row, Some(c_route))) else {
            continue; // trip references an unknown route
        };
        if !trip.is_empty() {
            active_trips.insert(trip.to_string(), route);
        }
    }
    let n_gtfs_trips = active_trips.len();

    // --- stop_times.txt (streamed): rows for active trips only. ---
    let (h, mut r) = open_csv(dir, "stop_times.txt")?
        .ok_or_else(|| err("stop_times.txt missing or empty"))?;
    let c_trip = h.req("trip_id", "stop_times.txt")?;
    let c_stop = h.req("stop_id", "stop_times.txt")?;
    let c_seq = h.req("stop_sequence", "stop_times.txt")?;
    let (c_arr, c_dep) = (h.get("arrival_time"), h.get("departure_time"));
    // trip_id -> rows of (seq, stop, arr?, dep?)
    type StopTimeRow = (u32, u32, Option<Time>, Option<Time>);
    let mut trip_rows: HashMap<String, Vec<StopTimeRow>> = HashMap::new();
    let mut stop_visits = vec![0u32; stop_ids.len()];
    while let Some(row) = r.next_record()? {
        let trip = f(&row, Some(c_trip));
        if !active_trips.contains_key(trip) {
            continue;
        }
        let Some(&stop) = stop_index.get(f(&row, Some(c_stop))) else {
            continue; // row references an unknown stop
        };
        let Ok(seq) = f(&row, Some(c_seq)).trim().parse::<u32>() else {
            continue;
        };
        let arr = parse_gtfs_time(f(&row, c_arr));
        let dep = parse_gtfs_time(f(&row, c_dep));
        trip_rows
            .entry(trip.to_string())
            .or_default()
            .push((seq, stop, arr, dep));
    }

    // --- frequencies.txt (optional): trip -> (start, end, headway) windows. ---
    // Expansion bounds: a headway under 10 s or over a day is not real
    // service, and a single window may not expand into more concrete trips
    // than any real route runs — one malformed row must not balloon the
    // converter's memory (each expanded trip clones the pattern + events).
    const MIN_HEADWAY_SECS: Time = 10;
    const MAX_HEADWAY_SECS: Time = 86_400;
    const MAX_TRIPS_PER_WINDOW: Time = 5_000;
    let mut freq: HashMap<String, Vec<(Time, Time, Time)>> = HashMap::new();
    if let Some((h, mut r)) = open_csv(dir, "frequencies.txt")? {
        let c_trip = h.req("trip_id", "frequencies.txt")?;
        let (c_start, c_end, c_head) = (
            h.get("start_time"),
            h.get("end_time"),
            h.get("headway_secs"),
        );
        while let Some(row) = r.next_record()? {
            let trip = f(&row, Some(c_trip)).to_string();
            let (Some(start), Some(end)) =
                (parse_gtfs_time(f(&row, c_start)), parse_gtfs_time(f(&row, c_end)))
            else {
                continue;
            };
            let Ok(head) = f(&row, c_head).trim().parse::<Time>() else {
                continue;
            };
            if !(MIN_HEADWAY_SECS..=MAX_HEADWAY_SECS).contains(&head)
                || end <= start
                || (end - start).div_ceil(head) > MAX_TRIPS_PER_WINDOW
            {
                continue; // malformed window; skipping beats a loop or a blowup
            }
            freq.entry(trip).or_default().push((start, end, head));
        }
    }

    // --- Assemble concrete trips: order stops, fill blank times, expand
    // frequencies. Deterministic: trips processed in sorted trip_id order. ---
    let mut n_dropped = 0usize;
    let mut raw: Vec<RawTrip> = Vec::new();
    let mut trip_ids_sorted: Vec<&String> = trip_rows.keys().collect();
    trip_ids_sorted.sort();
    for trip_id in trip_ids_sorted {
        let route = active_trips[trip_id.as_str()];
        let mut rows = trip_rows[trip_id.as_str()].clone();
        rows.sort_by_key(|r| r.0);
        rows.dedup_by_key(|r| r.0); // duplicate stop_sequence: keep first
        if rows.len() < 2 {
            n_dropped += 1;
            continue;
        }
        // Per-stop times: use the given side when only one of arr/dep is set.
        let mut times: Vec<Option<(Time, Time)>> = rows
            .iter()
            .map(|&(_, _, arr, dep)| match (arr, dep) {
                (Some(a), Some(d)) => Some((a, d.max(a))),
                (Some(a), None) => Some((a, a)),
                (None, Some(d)) => Some((d, d)),
                (None, None) => None,
            })
            .collect();
        // GTFS requires timed first/last stops; drop the trip if they're blank.
        if times.first().copied().flatten().is_none()
            || times.last().copied().flatten().is_none()
        {
            n_dropped += 1;
            continue;
        }
        // Linearly interpolate blank interior (non-timepoint) stops.
        let mut i = 0usize;
        while i < times.len() {
            if times[i].is_some() {
                i += 1;
                continue;
            }
            let prev = i - 1; // first/last are known, so prev/next exist
            let mut next = i;
            while times[next].is_none() {
                next += 1;
            }
            let t0 = times[prev].unwrap().1;
            let t1 = times[next].unwrap().0;
            let gap = (next - prev) as u32;
            for (step, slot) in times.iter_mut().enumerate().take(next).skip(i) {
                let k = (step - prev) as u32;
                let t = t0 + ((t1.saturating_sub(t0)) as u64 * k as u64 / gap as u64) as u32;
                *slot = Some((t, t));
            }
            i = next;
        }
        // Enforce forward monotonicity within the trip (guards feed anomalies).
        let mut events: TripEvents = Vec::with_capacity(rows.len());
        let mut floor: Time = 0;
        for t in &times {
            let (a, d) = t.unwrap();
            let a = a.max(floor);
            let d = d.max(a);
            floor = d;
            events.push(StopEvent { arr: a, dep: d });
        }
        let pattern: Vec<u32> = rows.iter().map(|r| r.1).collect();

        if let Some(windows) = freq.get(trip_id.as_str()) {
            // frequencies.txt: the scheduled trip is a TEMPLATE; emit one
            // concrete trip per headway departure in [start, end).
            let first_dep = events[0].dep;
            let mut emitted = 0u32;
            for &(start, end, headway) in windows {
                let mut t = start;
                while t < end {
                    let shift = t as i64 - first_dep as i64;
                    let shifted: Option<TripEvents> = events
                        .iter()
                        .map(|e| {
                            let a = e.arr as i64 + shift;
                            let d = e.dep as i64 + shift;
                            if a < 0 || d < 0 {
                                None
                            } else {
                                Some(StopEvent { arr: a as Time, dep: d as Time })
                            }
                        })
                        .collect();
                    if let Some(evs) = shifted {
                        raw.push(RawTrip { route, pattern: pattern.clone(), events: evs });
                        emitted += 1;
                    }
                    t = t.saturating_add(headway);
                }
            }
            // Busyness counts CONCRETE trips: a headway shuttle serving a
            // stop 200x/day must weigh 200, same as 200 scheduled trips.
            for &s in &pattern {
                stop_visits[s as usize] += emitted;
            }
        } else {
            for &s in &pattern {
                stop_visits[s as usize] += 1;
            }
            raw.push(RawTrip { route, pattern, events });
        }
    }
    drop(trip_rows);

    // --- The RAPTOR derivation: group by (GTFS route, exact stop sequence),
    // sort by first departure, split overtaking trips into separate engine
    // routes so departure-at-every-stop is non-decreasing in trip index —
    // `earliest_trip`'s binary-search invariant. ---
    let mut groups: HashMap<(u32, Vec<u32>), Vec<TripEvents>> = HashMap::new();
    for rt in raw {
        groups.entry((rt.route, rt.pattern)).or_default().push(rt.events);
    }
    let mut keys: Vec<(u32, Vec<u32>)> = groups.keys().cloned().collect();
    keys.sort(); // deterministic engine-route order

    let mut builder = TimetableBuilder::new();
    for &(lat, lon) in &stop_latlon {
        builder.add_stop(lat, lon);
    }

    let mut route_names: Vec<String> = Vec::new();
    let mut n_trips = 0usize;
    let mut n_events = 0usize;
    let mut n_overtake_splits = 0usize;
    for key in keys {
        let mut trips = groups.remove(&key).unwrap();
        // Total deterministic order: first departure, then the full (dep, arr)
        // sequence as a tiebreak.
        trips.sort_by(|a, b| {
            a.iter()
                .map(|e| (e.dep, e.arr))
                .cmp(b.iter().map(|e| (e.dep, e.arr)))
        });
        // Greedy chain split: place each trip in the first chain whose last
        // trip it does not overtake (dep AND arr no earlier at every stop).
        // Every chain is then totally ordered stop-wise => binary search holds.
        let mut chains: Vec<Vec<TripEvents>> = Vec::new();
        'trips: for trip in trips {
            for chain in &mut chains {
                let last = chain.last().unwrap();
                let fits = last
                    .iter()
                    .zip(trip.iter())
                    .all(|(x, y)| x.dep <= y.dep && x.arr <= y.arr);
                if fits {
                    chain.push(trip);
                    continue 'trips;
                }
            }
            chains.push(vec![trip]);
        }
        n_overtake_splits += chains.len() - 1;
        let (gtfs_route, pattern) = key;
        let label = gtfs_route_names
            .get(gtfs_route as usize)
            .cloned()
            .unwrap_or_default();
        for chain in chains {
            n_trips += chain.len();
            n_events += chain.len() * pattern.len();
            builder.add_route(&pattern, chain, route_modes[gtfs_route as usize]);
            route_names.push(label.clone());
        }
    }

    // --- transfers.txt (optional) → directed footpaths. ---
    if let Some((h, mut r)) = open_csv(dir, "transfers.txt")? {
        let (c_from, c_to, c_type, c_min) = (
            h.get("from_stop_id"),
            h.get("to_stop_id"),
            h.get("transfer_type"),
            h.get("min_transfer_time"),
        );
        const DEFAULT_TRANSFER_SECS: Time = 120;
        while let Some(row) = r.next_record()? {
            // Types 0/1/2 are walkable; 3 = not possible; 4/5 are in-seat
            // (trip-level, not a footpath).
            let ty = f(&row, c_type).trim();
            if matches!(ty, "3" | "4" | "5") {
                continue;
            }
            let (Some(&from), Some(&to)) = (
                stop_index.get(f(&row, c_from)),
                stop_index.get(f(&row, c_to)),
            ) else {
                continue;
            };
            if from == to {
                continue;
            }
            let secs = f(&row, c_min)
                .trim()
                .parse::<Time>()
                .unwrap_or(DEFAULT_TRANSFER_SECS);
            builder.add_footpath(from, to, secs);
        }
    }

    Ok(GtfsLoad {
        timetable: builder.build(),
        stop_ids,
        stop_names,
        route_names,
        service_date,
        n_gtfs_trips,
        n_trips,
        n_events,
        n_overtake_splits,
        n_dropped_trips: n_dropped,
        stop_visits,
    })
}

// Re-exported for the CLI: format seconds-since-service-midnight as HH:MM:SS
// (hours may exceed 24 for past-midnight service).
pub fn fmt_time(t: Time) -> String {
    format!("{:02}:{:02}:{:02}", t / 3600, (t / 60) % 60, t % 60)
}

// -----------------------------------------------------------------------------
// Tests — CSV edge cases, times >24h, calendar filtering, frequency expansion,
// the overtaking split, and a synthetic end-to-end GTFS -> plan -> ftt check.
// -----------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use crate::transit::raptor::earliest_arrival;
    use crate::transit::{ftt, plan, LegKind};
    use std::fs;
    use std::io::Cursor;
    use std::path::PathBuf;

    fn records(csv: &str) -> Vec<Vec<String>> {
        let mut r = CsvReader::new(Cursor::new(csv.as_bytes().to_vec()));
        let mut out = Vec::new();
        while let Some(rec) = r.next_record().unwrap() {
            out.push(rec);
        }
        out
    }

    #[test]
    fn csv_quoted_commas_escaped_quotes_and_newlines() {
        let rows = records("a,b,c\n\"1,5\",\"say \"\"hi\"\"\",\"two\nlines\"\nx,,z\n");
        assert_eq!(rows[0], vec!["a", "b", "c"]);
        assert_eq!(rows[1], vec!["1,5", "say \"hi\"", "two\nlines"]);
        assert_eq!(rows[2], vec!["x", "", "z"]);
    }

    #[test]
    fn csv_crlf_bom_blank_lines_and_missing_final_newline() {
        let rows = records("\u{feff}stop_id,stop_name\r\n\r\n1,Main St\r\n\n2,Second");
        assert_eq!(rows[0], vec!["stop_id", "stop_name"]); // BOM stripped
        assert_eq!(rows[1], vec!["1", "Main St"]);
        assert_eq!(rows[2], vec!["2", "Second"]); // record at EOF without \n
        assert_eq!(rows.len(), 3); // blank lines skipped
    }

    #[test]
    fn csv_stray_quote_cannot_buffer_unbounded() {
        // EOF while still inside quotes: the collected bytes become the last
        // field instead of an error (a truncated download stays readable).
        let rows = records("a,b\n\"no close,x\n");
        assert_eq!(rows[1], vec!["no close,x"]);
        // A runaway field (stray quote swallowing megabytes) fails loudly
        // instead of accumulating the rest of the stream in memory.
        let mut big = String::from("h1,h2\n\"");
        big.push_str(&"y".repeat(MAX_FIELD_BYTES + 64));
        let mut r = CsvReader::new(Cursor::new(big.into_bytes()));
        assert!(r.next_record().unwrap().is_some(), "header record");
        assert!(r.next_record().is_err(), "oversized field must be an error");
    }

    #[test]
    fn csv_short_rows_and_missing_optional_columns_read_as_empty() {
        let rows = records("a,b,c\n1\n");
        assert_eq!(rows[1], vec!["1"]);
        assert_eq!(f(&rows[1], Some(2)), ""); // short row
        assert_eq!(f(&rows[1], None), ""); // absent optional column
    }

    #[test]
    fn gtfs_times_including_past_midnight() {
        assert_eq!(parse_gtfs_time("08:30:15"), Some(8 * 3600 + 30 * 60 + 15));
        assert_eq!(parse_gtfs_time("8:30:15"), Some(8 * 3600 + 30 * 60 + 15));
        assert_eq!(parse_gtfs_time("24:00:00"), Some(86_400));
        assert_eq!(parse_gtfs_time("25:30:00"), Some(91_800), ">24h service past midnight");
        assert_eq!(parse_gtfs_time(" 07:05:00 "), Some(7 * 3600 + 5 * 60));
        assert_eq!(parse_gtfs_time(""), None);
        assert_eq!(parse_gtfs_time("12:60:00"), None);
        assert_eq!(parse_gtfs_time("12:00"), None);
        assert_eq!(parse_gtfs_time("banana"), None);
    }

    #[test]
    fn weekday_math_is_correct() {
        assert_eq!(weekday_index(20260710), 4, "2026-07-10 is a Friday");
        assert_eq!(weekday_index(20260712), 6, "2026-07-12 is a Sunday");
        assert_eq!(weekday_index(20260713), 0, "2026-07-13 is a Monday");
        assert_eq!(weekday_index(19700101), 3, "epoch day is a Thursday");
        assert_eq!(days_to_date(date_to_days(20260710) + 1), 20260711);
        assert_eq!(days_to_date(date_to_days(20261231) + 1), 20270101, "year rollover");
        assert_eq!(days_to_date(date_to_days(20280228) + 1), 20280229, "leap day");
    }

    // ---- Synthetic-feed helpers. ----

    fn write_feed(name: &str, files: &[(&str, &str)]) -> PathBuf {
        let mut dir = std::env::temp_dir();
        dir.push(format!("flows_gtfs_{}_{}", name, std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        for (fname, content) in files {
            fs::write(dir.join(fname), content).unwrap();
        }
        dir
    }

    const STOPS: &str = "stop_id,stop_name,stop_lat,stop_lon\n\
        A,\"Alpha, Main\",43.07,-89.40\n\
        B,Beta,43.08,-89.39\n\
        C,Gamma,43.09,-89.38\n";
    const ROUTES: &str = "route_id,route_short_name,route_long_name,route_type\n\
        R1,10,Crosstown,3\n";
    const CALENDAR: &str = "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n\
        WK,1,1,1,1,1,0,0,20260706,20260731\n";

    #[test]
    fn service_date_filtering_weekday_and_exceptions() {
        let dir = write_feed(
            "calfilter",
            &[
                ("stops.txt", STOPS),
                ("routes.txt", ROUTES),
                (
                    "calendar.txt",
                    "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n\
                     WK,1,1,1,1,1,0,0,20260706,20260731\n\
                     SAT,0,0,0,0,0,1,0,20260706,20260731\n",
                ),
                (
                    "calendar_dates.txt",
                    "service_id,date,exception_type\n\
                     WK,20260710,2\n\
                     SAT,20260710,1\n", // holiday: weekday service removed, Saturday service added
                ),
                (
                    "trips.txt",
                    "route_id,service_id,trip_id\nR1,WK,wk1\nR1,SAT,sat1\n",
                ),
                (
                    "stop_times.txt",
                    "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n\
                     wk1,08:00:00,08:00:00,A,1\n\
                     wk1,08:10:00,08:10:00,B,2\n\
                     sat1,09:00:00,09:00:00,A,1\n\
                     sat1,09:20:00,09:20:00,B,2\n",
                ),
            ],
        );
        // Thursday 2026-07-09: WK runs, SAT does not.
        let thu = load_gtfs(&dir, Some(20260709)).unwrap();
        assert_eq!(thu.n_gtfs_trips, 1);
        let js = plan(&thu.timetable, 0, 1, 0, 8);
        assert_eq!(js[0].arrival, 8 * 3600 + 600);
        // Friday 2026-07-10: WK removed by exception, SAT added by exception.
        let fri = load_gtfs(&dir, Some(20260710)).unwrap();
        assert_eq!(fri.n_gtfs_trips, 1);
        let js = plan(&fri.timetable, 0, 1, 0, 8);
        assert_eq!(js[0].arrival, 9 * 3600 + 1200, "only the exception-added trip runs");
        // Saturday 2026-07-11: SAT weekly.
        let sat = load_gtfs(&dir, Some(20260711)).unwrap();
        assert_eq!(sat.n_gtfs_trips, 1);
        // Sunday: nothing → error.
        assert!(load_gtfs(&dir, Some(20260712)).is_err());
        // Default date = first covered weekday with service (Mon 2026-07-06).
        let dflt = load_gtfs(&dir, None).unwrap();
        assert_eq!(dflt.service_date, 20260706);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn calendar_dates_only_feed_works() {
        // NYC-subway style: no calendar.txt at all.
        let dir = write_feed(
            "caldatesonly",
            &[
                ("stops.txt", STOPS),
                ("routes.txt", ROUTES),
                (
                    "calendar_dates.txt",
                    "service_id,date,exception_type\nS1,20260708,1\n",
                ),
                ("trips.txt", "route_id,service_id,trip_id\nR1,S1,t1\n"),
                (
                    "stop_times.txt",
                    "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n\
                     t1,10:00:00,10:00:00,A,1\n\
                     t1,10:15:00,10:15:00,C,2\n",
                ),
            ],
        );
        let load = load_gtfs(&dir, Some(20260708)).unwrap();
        assert_eq!(load.n_gtfs_trips, 1);
        assert!(load_gtfs(&dir, Some(20260709)).is_err(), "no service the next day");
        // Default-date scan also lands on the only (weekday) date.
        assert_eq!(load_gtfs(&dir, None).unwrap().service_date, 20260708);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn past_midnight_times_survive_into_the_timetable() {
        let dir = write_feed(
            "pastmidnight",
            &[
                ("stops.txt", STOPS),
                ("routes.txt", ROUTES),
                ("calendar.txt", CALENDAR),
                ("trips.txt", "route_id,service_id,trip_id\nR1,WK,owl\n"),
                (
                    "stop_times.txt",
                    "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n\
                     owl,23:55:00,23:55:00,A,1\n\
                     owl,25:30:00,25:30:00,B,2\n", // arrives 1:30 AM next day
                ),
            ],
        );
        let load = load_gtfs(&dir, Some(20260708)).unwrap();
        let js = plan(&load.timetable, 0, 1, 23 * 3600, 8);
        assert_eq!(js[0].arrival, 91_800, "25:30:00 kept as 91800s, not wrapped");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn blank_interior_times_are_interpolated() {
        let dir = write_feed(
            "interp",
            &[
                ("stops.txt", STOPS),
                ("routes.txt", ROUTES),
                ("calendar.txt", CALENDAR),
                ("trips.txt", "route_id,service_id,trip_id\nR1,WK,t1\n"),
                (
                    "stop_times.txt",
                    "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n\
                     t1,08:00:00,08:00:00,A,1\n\
                     t1,,,B,2\n\
                     t1,08:20:00,08:20:00,C,3\n",
                ),
            ],
        );
        let load = load_gtfs(&dir, Some(20260708)).unwrap();
        // B is halfway between 08:00 and 08:20 → 08:10.
        let js = plan(&load.timetable, 0, 1, 0, 8);
        assert_eq!(js[0].arrival, 8 * 3600 + 600);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn overtaking_trips_are_split_into_separate_routes() {
        // Same pattern A->B->C, but the "express" leaves A later and arrives at
        // C earlier — merged into one RAPTOR route this breaks earliest_trip's
        // binary search; the loader MUST split them.
        let dir = write_feed(
            "overtake",
            &[
                ("stops.txt", STOPS),
                ("routes.txt", ROUTES),
                ("calendar.txt", CALENDAR),
                (
                    "trips.txt",
                    "route_id,service_id,trip_id\nR1,WK,slow\nR1,WK,express\n",
                ),
                (
                    "stop_times.txt",
                    "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n\
                     slow,08:00:00,08:00:00,A,1\n\
                     slow,08:30:00,08:30:00,B,2\n\
                     slow,09:00:00,09:00:00,C,3\n\
                     express,08:10:00,08:10:00,A,1\n\
                     express,08:20:00,08:20:00,B,2\n\
                     express,08:40:00,08:40:00,C,3\n",
                ),
            ],
        );
        let load = load_gtfs(&dir, Some(20260708)).unwrap();
        assert_eq!(load.n_overtake_splits, 1, "one extra route from the split");
        assert_eq!(load.timetable.n_routes(), 2, "slow and express separated");
        // Depart 08:05 from A: only the express is catchable at 08:10 → C 08:40.
        // (Merged wrongly, binary search on a dep-sorted-at-A order would see
        // deps [08:00, 08:10] but C-arrivals [09:00, 08:40] — trip order breaks.)
        assert_eq!(
            earliest_arrival(&load.timetable, 0, 2, 8 * 3600 + 300, 8),
            8 * 3600 + 40 * 60
        );
        // Depart 08:00 exactly: the slow one boards at 08:00 but express still
        // arrives first — RAPTOR must pick 08:40, not 09:00.
        assert_eq!(earliest_arrival(&load.timetable, 0, 2, 8 * 3600, 8), 8 * 3600 + 40 * 60);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn non_overtaking_trips_stay_one_route() {
        let dir = write_feed(
            "noovertake",
            &[
                ("stops.txt", STOPS),
                ("routes.txt", ROUTES),
                ("calendar.txt", CALENDAR),
                ("trips.txt", "route_id,service_id,trip_id\nR1,WK,t1\nR1,WK,t2\n"),
                (
                    "stop_times.txt",
                    "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n\
                     t2,08:30:00,08:30:00,A,1\n\
                     t2,09:00:00,09:00:00,B,2\n\
                     t1,08:00:00,08:00:00,A,1\n\
                     t1,08:30:00,08:30:00,B,2\n",
                ),
            ],
        );
        let load = load_gtfs(&dir, Some(20260708)).unwrap();
        assert_eq!(load.timetable.n_routes(), 1, "well-behaved trips share a route");
        assert_eq!(load.n_overtake_splits, 0);
        assert_eq!(load.n_trips, 2);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn frequencies_expand_to_concrete_trips() {
        let dir = write_feed(
            "freq",
            &[
                ("stops.txt", STOPS),
                ("routes.txt", ROUTES),
                ("calendar.txt", CALENDAR),
                ("trips.txt", "route_id,service_id,trip_id\nR1,WK,shuttle\n"),
                (
                    "stop_times.txt",
                    "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n\
                     shuttle,06:00:00,06:00:00,A,1\n\
                     shuttle,06:15:00,06:15:00,B,2\n",
                ),
                (
                    "frequencies.txt",
                    "trip_id,start_time,end_time,headway_secs\n\
                     shuttle,08:00:00,09:00:00,1200\n", // 08:00, 08:20, 08:40
                ),
            ],
        );
        let load = load_gtfs(&dir, Some(20260708)).unwrap();
        assert_eq!(load.n_trips, 3, "three headway departures in [08:00, 09:00)");
        // Depart 08:05 → catch the 08:20 → arrive 08:35 (template ride = 15 min).
        assert_eq!(
            earliest_arrival(&load.timetable, 0, 1, 8 * 3600 + 300, 8),
            8 * 3600 + 35 * 60
        );
        // The 06:00 template itself must NOT run as a scheduled trip.
        assert_eq!(earliest_arrival(&load.timetable, 0, 1, 0, 8), 8 * 3600 + 15 * 60);
        // Busyness counts the CONCRETE departures, not the template.
        assert_eq!(load.stop_visits, vec![3, 3, 0]);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn malformed_frequency_windows_are_skipped() {
        // Sub-10s headway and an expansion past the per-window trip cap are
        // both rejected; the template then runs as an ordinary scheduled trip
        // (the same degradation as the existing head==0 guard).
        let dir = write_feed(
            "freqbad",
            &[
                ("stops.txt", STOPS),
                ("routes.txt", ROUTES),
                ("calendar.txt", CALENDAR),
                ("trips.txt", "route_id,service_id,trip_id\nR1,WK,shuttle\n"),
                (
                    "stop_times.txt",
                    "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n\
                     shuttle,06:00:00,06:00:00,A,1\n\
                     shuttle,06:15:00,06:15:00,B,2\n",
                ),
                (
                    "frequencies.txt",
                    "trip_id,start_time,end_time,headway_secs\n\
                     shuttle,08:00:00,09:00:00,1\n\
                     shuttle,00:00:00,48:00:00,10\n", // 17280 trips > cap
                ),
            ],
        );
        let load = load_gtfs(&dir, Some(20260708)).unwrap();
        assert_eq!(load.n_trips, 1, "both windows rejected, template kept");
        assert_eq!(earliest_arrival(&load.timetable, 0, 1, 0, 8), 6 * 3600 + 15 * 60);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn transfers_become_directed_footpaths() {
        let dir = write_feed(
            "transfers",
            &[
                ("stops.txt", STOPS),
                (
                    "routes.txt",
                    "route_id,route_short_name,route_long_name,route_type\n\
                     R1,10,East,3\nR2,20,North,3\n",
                ),
                ("calendar.txt", CALENDAR),
                ("trips.txt", "route_id,service_id,trip_id\nR1,WK,t1\nR2,WK,t2\n"),
                (
                    "stop_times.txt",
                    "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n\
                     t1,08:00:00,08:00:00,A,1\n\
                     t1,08:10:00,08:10:00,B,2\n\
                     t2,08:20:00,08:20:00,C,1\n\
                     t2,08:40:00,08:40:00,A,2\n",
                ),
                (
                    "transfers.txt",
                    "from_stop_id,to_stop_id,transfer_type,min_transfer_time\n\
                     B,C,2,180\n\
                     A,B,3,\n", // type 3 = not possible: must be ignored
                ),
            ],
        );
        let load = load_gtfs(&dir, Some(20260708)).unwrap();
        // A --t1--> B --walk 180s--> C --t2--> A? No: t2 goes C->A. Use A->B,
        // walk B->C (arr 08:10 + 3:00 = 08:13), ride t2 dep 08:20 → back to A…
        // Simpler assertion: A→C requires the walk (no ride ends at C).
        let js = plan(&load.timetable, 0, 2, 0, 8);
        assert!(!js.is_empty(), "C reachable only via the transfer footpath");
        let j = &js[0];
        assert!(j.legs.iter().any(|l| l.kind == LegKind::Walk && l.arr - l.dep == 180));
        assert_eq!(j.arrival, 8 * 3600 + 600 + 180);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn mode_mapping_covers_base_and_extended_types() {
        assert_eq!(mode_for_route_type(0), Mode::Subway); // tram
        assert_eq!(mode_for_route_type(1), Mode::Subway); // metro
        assert_eq!(mode_for_route_type(2), Mode::Rail);
        assert_eq!(mode_for_route_type(3), Mode::Bus);
        assert_eq!(mode_for_route_type(11), Mode::Bus); // trolleybus
        assert_eq!(mode_for_route_type(101), Mode::Rail); // high-speed rail
        assert_eq!(mode_for_route_type(106), Mode::Commuter); // suburban railway
        assert_eq!(mode_for_route_type(204), Mode::Coach); // regional coach
        assert_eq!(mode_for_route_type(402), Mode::Subway); // underground service
        assert_eq!(mode_for_route_type(715), Mode::Bus); // demand & response bus
        assert_eq!(mode_for_route_type(-1), Mode::Bus); // junk → conservative
    }

    #[test]
    fn synthetic_end_to_end_gtfs_to_ftt_to_identical_plans() {
        // Two bus lines + a transfer walk; convert → .ftt → reload → plans equal.
        let dir = write_feed(
            "endtoend",
            &[
                ("stops.txt", STOPS),
                (
                    "routes.txt",
                    "route_id,route_short_name,route_long_name,route_type\n\
                     R1,10,East,3\nR2,20,North,3\n",
                ),
                ("calendar.txt", CALENDAR),
                (
                    "trips.txt",
                    "route_id,service_id,trip_id\nR1,WK,e1\nR1,WK,e2\nR2,WK,n1\n",
                ),
                (
                    "stop_times.txt",
                    "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n\
                     e1,08:00:00,08:01:00,A,1\n\
                     e1,08:15:00,08:16:00,B,2\n\
                     e2,09:00:00,09:01:00,A,1\n\
                     e2,09:15:00,09:16:00,B,2\n\
                     n1,08:25:00,08:25:00,B,1\n\
                     n1,08:45:00,08:45:00,C,2\n",
                ),
                ("transfers.txt", "from_stop_id,to_stop_id,transfer_type,min_transfer_time\nB,B,2,120\n"),
            ],
        );
        let load = load_gtfs(&dir, Some(20260709)).unwrap();
        let tt = &load.timetable;
        assert_eq!(load.stop_ids, vec!["A", "B", "C"]);
        assert_eq!(load.stop_names[0], "Alpha, Main", "quoted comma name survives");

        let mut path = std::env::temp_dir();
        path.push(format!("flows_gtfs_e2e_{}.ftt", std::process::id()));
        ftt::write_ftt(tt, &path).unwrap();
        let tt2 = ftt::read_ftt(&path).unwrap();
        assert_eq!(ftt::to_bytes(tt), ftt::to_bytes(&tt2));
        for s in 0..3u32 {
            for t in 0..3u32 {
                if s == t {
                    continue;
                }
                for depart in [0u32, 8 * 3600 + 120, 9 * 3600] {
                    assert_eq!(plan(tt, s, t, depart, 8), plan(&tt2, s, t, depart, 8));
                }
            }
        }
        // And the journey itself is sane: A→C = ride + transfer + ride.
        let js = plan(&tt2, 0, 2, 0, 8);
        assert_eq!(js[0].arrival, 8 * 3600 + 45 * 60);
        assert_eq!(js[0].n_transfers, 1);
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_file(&path);
    }
}
