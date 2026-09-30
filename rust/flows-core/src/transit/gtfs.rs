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
use std::io::{self, BufRead};
use std::path::Path;

use super::inflate;
use super::{Mode, StopEvent, Time, Timetable, TimetableBuilder, TripEvents};
use crate::seasonal::haversine_km;

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

/// One CSV record, held in buffers that are reused from row to row: the
/// fields' text back to back, and where each one ends. Chicago's
/// `stop_times.txt` is 5.9 million rows of eight fields; a fresh `String`
/// per field was most of the time spent building its timetable.
#[derive(Default)]
pub(crate) struct Record {
    text: String,
    ends: Vec<usize>,
}

impl Record {
    fn clear(&mut self) {
        self.text.clear();
        self.ends.clear();
    }

    /// Close a field: its bytes, as UTF-8 (lossy) and trimmed.
    fn push(&mut self, bytes: &[u8]) {
        self.text.push_str(String::from_utf8_lossy(bytes).trim());
        self.ends.push(self.text.len());
    }

    pub(crate) fn len(&self) -> usize {
        self.ends.len()
    }

    pub(crate) fn get(&self, i: usize) -> Option<&str> {
        let end = *self.ends.get(i)?;
        let start = if i == 0 { 0 } else { self.ends[i - 1] };
        Some(&self.text[start..end])
    }

    pub(crate) fn to_vec(&self) -> Vec<String> {
        (0..self.len())
            .filter_map(|i| self.get(i).map(str::to_string))
            .collect()
    }
}

/// Streaming RFC-4180 CSV record reader over any [`BufRead`]. Handles quoted
/// fields containing commas, `""`-escaped quotes, and embedded newlines; CRLF
/// and LF line endings; a UTF-8 BOM on the first record; and skips blank
/// lines. Never loads the whole file (NYC-scale `stop_times.txt` is ~2 GB);
/// a field past [`MAX_FIELD_BYTES`] is an error, not an allocation.
pub(crate) struct CsvReader<R: BufRead> {
    r: R,
    first: bool,
    line: Vec<u8>,
    field: Vec<u8>,
}

impl<R: BufRead> CsvReader<R> {
    pub(crate) fn new(r: R) -> Self {
        CsvReader {
            r,
            first: true,
            line: Vec::new(),
            field: Vec::new(),
        }
    }

    /// Next record, or `None` at EOF. Blank lines are skipped.
    pub(crate) fn next_record(&mut self) -> io::Result<Option<Vec<String>>> {
        let mut rec = Record::default();
        Ok(self.next_into(&mut rec)?.then(|| rec.to_vec()))
    }

    /// Next record into `rec`, reusing its buffers; `false` at EOF. Blank
    /// lines are skipped.
    pub(crate) fn next_into(&mut self, rec: &mut Record) -> io::Result<bool> {
        loop {
            if !self.raw_into(rec)? {
                return Ok(false);
            }
            if rec.len() == 1 && rec.text.is_empty() {
                continue; // blank line
            }
            return Ok(true);
        }
    }

    fn raw_into(&mut self, rec: &mut Record) -> io::Result<bool> {
        rec.clear();
        self.field.clear();
        let mut in_quotes = false;
        let mut consumed_anything = false;

        loop {
            // Bound the READ, not just the field. `read_until` grows until it
            // finds a newline, so a feed with CR-only line endings (or a file
            // that is not the CSV it claims to be) was pulled into memory
            // whole — the MAX_FIELD_BYTES check below could only fire after
            // the bytes were already resident, which is the opposite of the
            // 1 MiB ceiling this reader advertises to its callers.
            self.line.clear();
            let budget = (MAX_FIELD_BYTES + 1).saturating_sub(self.field.len()) as u64;
            // UFCS so the receiver is `&mut R` (which is `Read` by the
            // blanket impl) rather than auto-dereffing into `R` and moving it.
            let mut limited = std::io::Read::take(&mut self.r, budget);
            let n = limited.read_until(b'\n', &mut self.line)?;
            if n as u64 == budget && self.line.last() != Some(&b'\n') {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "csv: record exceeds the 1 MiB cap (unbalanced quote?)",
                ));
            }
            if n == 0 {
                // EOF: emit the pending record, if any bytes were consumed.
                if !consumed_anything {
                    return Ok(false);
                }
                rec.push(&self.field);
                self.field.clear();
                return Ok(true);
            }
            consumed_anything = true;
            let mut start = 0usize;
            if self.first {
                self.first = false;
                if self.line.starts_with(&[0xEF, 0xBB, 0xBF]) {
                    start = 3; // strip UTF-8 BOM
                }
            }

            let line = &self.line;
            let field = &mut self.field;
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
                        b',' => {
                            rec.push(field);
                            field.clear();
                        }
                        b'\r' => {} // CRLF (or stray CR): dropped
                        b'\n' => {
                            rec.push(field);
                            field.clear();
                            return Ok(true);
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
fn f(row: &Record, i: Option<usize>) -> &str {
    i.and_then(|i| row.get(i)).unwrap_or("")
}

/// A named GTFS file, opened: its parsed header + a line reader (None when
/// the file is absent — most GTFS extras are optional).
type OpenedCsv = Option<(Header, CsvReader<Box<dyn BufRead>>)>;

/// The file as the publisher wrote it, or packed as their archive stored it
/// (`stop_times.txt.fz`) and unpacked as it is read — see [`super::inflate`].
fn open_csv(dir: &Path, name: &str) -> Result<OpenedCsv, GtfsError> {
    let Some(reader) = inflate::open_member(dir, name)? else {
        return Ok(None);
    };
    let mut r = CsvReader::new(reader);
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
    // GTFS allows hours past 24 for trips after midnight. A cap keeps a garbage
    // hour from wrapping u32 into a valid-looking time — but it must clear the
    // longest real trip: a cap of 48 dropped every Amtrak train whose last stop
    // is past 48:59:59 (70 trips, the Sunset Limited and Texas Eagle among
    // them, whose through cars reach 80:00:00).
    if h > MAX_GTFS_HOURS || m > 59 || sec > 59 {
        return None;
    }
    Some(h * 3600 + m * 60 + sec)
}

/// The latest hour a stop time may carry: a week, far past any real trip and
/// far below where `h * 3600` could overflow.
const MAX_GTFS_HOURS: u32 = 7 * 24;

/// How many service days back a trip may still be running. GTFS files a trip
/// under the day it starts, so a bus leaving at 11:50 PM is `24:10:00` at its
/// last stop and the 2 AM owl bus is `26:00:00` — both on YESTERDAY's
/// service. A timetable of today's trips alone had none of them after
/// midnight. Amtrak's longest reach `80:00:00`, three days on.
const CARRY_DAYS: u32 = 3;

const DAY_SECS: Time = 86_400;

/// In a trip's days mask (bit k: runs k days before the service date), the
/// bit saying every row is kept whatever day it ran — a frequencies.txt
/// template, whose windows say when it runs.
const ALL_ROWS: u8 = 0x80;

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
            let mut row = Record::default();
            while r.next_into(&mut row)? {
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
            let mut row = Record::default();
            while r.next_into(&mut row)? {
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
            if flags[wd]
                && *start <= date
                && date <= *end
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
/// assumption). Suburban-railway extended codes map to `Commuter`. Boats are
/// `Ship` — they fell through to `Bus`, and the Staten Island Ferry read "Bus"
/// on a card and was boarded by riders who had chosen the bus.
pub(crate) fn mode_for_route_type(rt: i64) -> Mode {
    match rt {
        106 | 109 => Mode::Commuter,            // suburban / commuter railway
        2 | 100..=199 => Mode::Rail,            // intercity/long-distance rail
        0 | 1 | 5 | 6 | 7 | 12 => Mode::Subway, // tram/metro/cable/funicular/monorail
        3 | 11 => Mode::Bus,                    // bus / trolleybus
        4 | 1000..=1099 | 1200..=1299 => Mode::Ship, // ferry / water transport
        200..=299 => Mode::Coach,               // coach services
        400..=499 | 900..=999 => Mode::Subway,  // urban railway / tram services
        700..=899 => Mode::Bus,                 // bus / trolleybus services
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
    /// Dense stop index → IANA zone from `stop_timezone`, falling back to
    /// [`GtfsLoad::agency_timezone`] when the row leaves it blank (the GTFS
    /// default). Never empty when the agency declares one.
    ///
    /// This is for DISPLAY only. Per the GTFS reference, every time in
    /// `stop_times.txt` is in the agency's timezone no matter where the stop
    /// is — so the clock a rider reads at a stop is
    /// `agency-midnight + seconds`, *rendered* in this zone. Amtrak's feed is
    /// the worked example: one agency zone (`America/New_York`) and four stop
    /// zones, so a Los Angeles departure stored as `12:55:00` is 9:55 AM on
    /// the platform. Getting this backwards prints every western time hours
    /// off, which is why the zone travels with the shard.
    pub stop_zones: Vec<String>,
    /// Engine route index → human label ("28 Route 28" style).
    pub route_names: Vec<String>,
    /// The service date actually built (YYYYMMDD).
    pub service_date: u32,
    /// `agency.txt`'s `agency_timezone` — the zone EVERY stop time in the feed
    /// is measured from. Empty when the feed omits agency.txt.
    pub agency_timezone: String,
    /// When the publisher cut this feed (YYYYMMDD), from `feed_info.txt`
    /// (`feed_version` when it is a date, else `feed_start_date`). 0 when the
    /// feed says nothing — the UI needs it to say "Times as of ‹date›".
    pub feed_published: u32,
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
    /// Dense stop index → which input feed it came from (always 0 for
    /// [`load_gtfs`]). A merged timetable credits each operator by this.
    pub stop_feed: Vec<u16>,
    /// Walking links FLOWS added: stops of different feeds close enough to
    /// change operator, and stops within a city feed close enough to change
    /// route on foot (see `link_feeds`). Counted as pairs; each is two
    /// footpaths. Always 0 for a single feed.
    pub n_feed_links: usize,
    /// Secondary feeds that could not be used, with the reason. The first
    /// feed is never skipped: if it fails, the whole load fails.
    pub skipped_feeds: Vec<(usize, String)>,
}

/// One trip's working data while grouping.
struct RawTrip {
    route: u32, // index into the GTFS routes vec
    pattern: Vec<u32>,
    events: TripEvents,
}

/// The part of a trip that began `since` seconds before today's service day
/// and is still running in it: the stops it leaves at or after today's
/// midnight, on today's clock. None when fewer than two stops are left — a
/// trip whose last stop is today's first can take no one anywhere.
fn carried(pattern: &[u32], events: &[StopEvent], since: Time) -> Option<(Vec<u32>, TripEvents)> {
    // Nearly every trip is over by midnight: answer those without a scan.
    if events.last()?.dep < since {
        return None;
    }
    let first = events.iter().position(|e| e.dep >= since)?;
    if events.len() - first < 2 {
        return None;
    }
    let events = events[first..]
        .iter()
        .map(|e| StopEvent {
            // It pulled in before midnight and leaves after: boarded from 0.
            arr: e.arr.max(since) - since,
            dep: e.dep - since,
        })
        .collect();
    Some((pattern[first..].to_vec(), events))
}

/// One feed's service day, parsed but not yet merged. Every index in here is
/// LOCAL to the feed — stop 0 is this feed's first stop — and every time is
/// in this feed's own agency zone. [`assemble`] offsets and shifts them.
struct FeedParts {
    stop_ids: Vec<String>,
    stop_names: Vec<String>,
    stop_zones: Vec<String>,
    stop_latlon: Vec<(i32, i32)>,
    stop_visits: Vec<u32>,
    route_modes: Vec<Mode>,
    route_names: Vec<String>,
    raw: Vec<RawTrip>,
    /// transfers.txt, as (from, to, seconds) in local stop indices.
    transfers: Vec<(u32, u32, Time)>,
    service_date: u32,
    agency_timezone: String,
    feed_published: u32,
    n_gtfs_trips: usize,
    n_dropped: usize,
}

/// The farthest FLOWS asks someone to walk between two operators' stops to
/// make a connection. Four hundred metres is a city block or two — the bus
/// stop across the street from the station, not one in the next district.
/// Past this, a "connection" is really a separate walk the rider should plan.
pub const MAX_LINK_METERS: f64 = 400.0;

/// The farthest FLOWS asks someone to walk from one OPERATOR's stop to
/// another's — a train station to the city bus. Longer than a hop between
/// bus stops ([`MAX_LINK_METERS`]) because stations are few and their bus
/// stops are often a block or two off: Milwaukee's station is ~550 m from
/// Wisconsin Avenue, and with a 400 m reach the planner rode a two-minute bus
/// to cover it. Stations are few, so the wider reach adds few links; the
/// planner still prefers a ride when it is genuinely better.
pub const MAX_STATION_LINK_METERS: f64 = 800.0;

/// Walking pace for a connection, in metres a second. Slower than a free walk
/// (about 1.4) on purpose: this is someone with a bag, leaving a platform and
/// looking for a stop they have never seen. Too fast a pace plans connections
/// people miss, which is the worse mistake.
pub const LINK_WALK_MPS: f64 = 1.1;

/// Time added to every connection before the walk itself: getting off,
/// finding the exit, finding the other stop. The same two minutes GTFS
/// assumes when a transfers.txt row gives no time.
pub const LINK_BUFFER_SECS: Time = 120;

/// One input to [`load_gtfs_many`]: a feed directory and how far to shift its
/// times so they are measured in the FIRST feed's clock.
///
/// Every feed stores its times from midnight in its own agency's zone, so a
/// Milwaukee bus at 08:00 Central is 09:00 in an Amtrak (Eastern) timetable.
/// The shift is supplied by the caller because working it out needs a
/// timezone database, which Swift has and this crate deliberately does not.
/// Put the EASTERNMOST feed first so every shift is zero or positive — a
/// negative shift can push an early trip before midnight, and such a trip is
/// dropped rather than wrapped onto the wrong day.
#[derive(Clone, Copy, Debug)]
pub struct FeedInput<'a> {
    pub dir: &'a Path,
    pub shift_secs: i32,
}

/// The zone a feed measures ALL its stop times from, from `agency.txt` alone.
///
/// Separate from [`load_gtfs`] because it answers a question that has to come
/// first: "which service day is it right now?" is a question in the operator's
/// zone, not the device's. At 9pm in Honolulu, Amtrak is already on tomorrow's
/// timetable, and building today's would show a rider trains that have run.
/// Reading one small file costs nothing next to parsing the feed.
///
/// `None` when the feed omits agency.txt or leaves the column blank.
pub fn agency_timezone(dir: &Path) -> Option<String> {
    read_agency_timezone(dir).ok().flatten()
}

fn read_agency_timezone(dir: &Path) -> Result<Option<String>, GtfsError> {
    // Multi-agency feeds (Amtrak ships 20 rows) are required by GTFS to agree
    // on the zone, so the first non-empty one speaks for the file.
    if let Some((h, mut r)) = open_csv(dir, "agency.txt")? {
        let c_tz = h.get("agency_timezone");
        let mut row = Record::default();
        while r.next_into(&mut row)? {
            let tz = f(&row, c_tz).trim();
            if !tz.is_empty() {
                return Ok(Some(tz.to_string()));
            }
        }
    }
    Ok(None)
}

/// Load an unzipped GTFS directory into a single-service-day [`Timetable`].
/// `date` is `YYYYMMDD`; `None` uses the first weekday the calendar covers
/// with active service (never the system clock — wrappers pass "today" in).
pub fn load_gtfs(dir: &Path, date: Option<u32>) -> Result<GtfsLoad, GtfsError> {
    let feed = parse_feed(dir, date)?;
    Ok(assemble(vec![(feed, 0)], Vec::new()))
}

/// Load SEVERAL feeds into one timetable for one service day, so a single
/// query can ride one operator's train and another's bus.
///
/// Why one timetable and not several: RAPTOR's rounds are what make a change
/// of vehicle cheap to find, and they only see routes in the same timetable.
/// Two timetables side by side have no way to change between them.
///
/// Why walking links: feeds never reference each other. Amtrak's Chicago
/// station and the city bus stop across the street are two unrelated stops to
/// two unrelated publishers, and no `transfers.txt` joins them. So every pair
/// of stops from DIFFERENT feeds within [`MAX_LINK_METERS`] gets a footpath
/// both ways, timed at [`LINK_WALK_MPS`] plus [`LINK_BUFFER_SECS`]. Only
/// stops a trip actually calls at are linked. Stops within one feed are left
/// exactly as that feed describes them.
///
/// The first feed is the reference: its zone is the result's zone, its
/// failure is the load's failure. A later feed that cannot be used — its
/// calendar has lapsed, its files are malformed — is skipped and reported in
/// [`GtfsLoad::skipped_feeds`], because a city's broken bus feed must never
/// cost a rider their train times.
pub fn load_gtfs_many(feeds: &[FeedInput], date: u32) -> Result<GtfsLoad, GtfsError> {
    let (first, rest) = feeds.split_first().ok_or_else(|| err("no feeds to load"))?;
    let mut parts = vec![(parse_feed(first.dir, Some(date))?, first.shift_secs)];
    let mut skipped = Vec::new();
    for (i, input) in rest.iter().enumerate() {
        match parse_feed(input.dir, Some(date)) {
            Ok(p) => parts.push((p, input.shift_secs)),
            Err(e) => skipped.push((i + 1, e.0)),
        }
    }
    Ok(assemble(parts, skipped))
}

/// Parse one feed's service day into [`FeedParts`], with nothing merged.
fn parse_feed(dir: &Path, date: Option<u32>) -> Result<FeedParts, GtfsError> {
    if !dir.is_dir() {
        return Err(err(format!("not a directory: {}", dir.display())));
    }

    // --- agency.txt → the zone every stop time in the feed is measured from.
    // Optional: a feed may omit it, and then times carry no zone at all and the
    // caller renders them as local-to-the-stop. Multi-agency feeds (Amtrak ships
    // 20 rows) are required by GTFS to agree on the zone, so the first non-empty
    // one speaks for the file. ---
    let agency_timezone = read_agency_timezone(dir)?.unwrap_or_default();

    // --- feed_info.txt → the publication date, for "Times as of ‹date›". ---
    let mut feed_published = 0u32;
    if let Some((h, mut r)) = open_csv(dir, "feed_info.txt")? {
        let (c_ver, c_start) = (h.get("feed_version"), h.get("feed_start_date"));
        let mut row = Record::default();
        if r.next_into(&mut row)? {
            // feed_version is free-form; Amtrak puts a YYYYMMDD in it, others
            // put "1.2.3". Take it only when it reads as a plausible date.
            feed_published = parse_date(f(&row, c_ver)).unwrap_or(0);
            if feed_published == 0 {
                feed_published = parse_date(f(&row, c_start)).unwrap_or(0);
            }
        }
    }

    // --- stops.txt → dense ids. All rows kept (stations/entrances included;
    // only stops referenced by trips/transfers ever matter to RAPTOR). ---
    let (h, mut r) =
        open_csv(dir, "stops.txt")?.ok_or_else(|| err("stops.txt missing or empty"))?;
    let c_id = h.req("stop_id", "stops.txt")?;
    let (c_name, c_lat, c_lon) = (h.get("stop_name"), h.get("stop_lat"), h.get("stop_lon"));
    let c_tz = h.get("stop_timezone");
    let mut stop_ids: Vec<String> = Vec::new();
    let mut stop_names: Vec<String> = Vec::new();
    let mut stop_zones: Vec<String> = Vec::new();
    let mut stop_latlon: Vec<(i32, i32)> = Vec::new();
    let mut stop_index: HashMap<String, u32> = HashMap::new();
    let mut row = Record::default();
    while r.next_into(&mut row)? {
        let id = f(&row, Some(c_id));
        if id.is_empty() || stop_index.contains_key(id) {
            continue;
        }
        // Reject, do not rewrite. `unwrap_or(0.0)` turned an unparseable or
        // missing coordinate into (0, 0) — a real point in the Gulf of
        // Guinea — so a malformed stop entered the timetable as a place
        // 5,000 km from the agency and quietly distorted every walk-transfer
        // radius computed against it.
        let (lat, lon) = match (f(&row, c_lat).parse::<f64>(), f(&row, c_lon).parse::<f64>()) {
            (Ok(a), Ok(o))
                if a.is_finite()
                    && o.is_finite()
                    && (-90.0..=90.0).contains(&a)
                    && (-180.0..=180.0).contains(&o) =>
            {
                (a, o)
            }
            _ => continue, // skip the stop; the feed keeps its other rows
        };
        stop_index.insert(id.to_string(), stop_ids.len() as u32);
        stop_ids.push(id.to_string());
        stop_names.push(f(&row, c_name).to_string());
        let zone = f(&row, c_tz).trim();
        stop_zones.push(if zone.is_empty() {
            agency_timezone.clone()
        } else {
            zone.to_string()
        });
        stop_latlon.push(((lat * 1e6).round() as i32, (lon * 1e6).round() as i32));
    }
    if stop_ids.is_empty() {
        return Err(err("stops.txt has no stops"));
    }

    // --- routes.txt → mode + label. ---
    let (h, mut r) =
        open_csv(dir, "routes.txt")?.ok_or_else(|| err("routes.txt missing or empty"))?;
    let c_id = h.req("route_id", "routes.txt")?;
    let (c_type, c_short, c_long) = (
        h.get("route_type"),
        h.get("route_short_name"),
        h.get("route_long_name"),
    );
    let mut route_modes: Vec<Mode> = Vec::new();
    let mut gtfs_route_names: Vec<String> = Vec::new();
    let mut route_index: HashMap<String, u32> = HashMap::new();
    let mut row = Record::default();
    while r.next_into(&mut row)? {
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
    // The days before, whose trips may still be running today (CARRY_DAYS).
    let earlier: Vec<std::collections::HashSet<String>> = (1..=CARRY_DAYS)
        .map(|k| cal.active_on(days_to_date(date_to_days(service_date) - i64::from(k))))
        .collect();

    // --- trips.txt: keep trips whose service runs on the date, or on a day
    // before it (bit k of the mask = runs k days before). ---
    let (h, mut r) =
        open_csv(dir, "trips.txt")?.ok_or_else(|| err("trips.txt missing or empty"))?;
    let c_trip = h.req("trip_id", "trips.txt")?;
    let c_route = h.req("route_id", "trips.txt")?;
    let c_service = h.req("service_id", "trips.txt")?;
    // trip_id -> (gtfs route index, days mask)
    let mut active_trips: HashMap<String, (u32, u8)> = HashMap::new();
    let mut row = Record::default();
    while r.next_into(&mut row)? {
        let service = f(&row, Some(c_service));
        let mut days = u8::from(active.contains(service));
        for (k, set) in earlier.iter().enumerate() {
            if set.contains(service) {
                days |= 1 << (k + 1);
            }
        }
        if days == 0 {
            continue;
        }
        let trip = f(&row, Some(c_trip));
        let Some(&route) = route_index.get(f(&row, Some(c_route))) else {
            continue; // trip references an unknown route
        };
        if !trip.is_empty() {
            // A trip id listed twice (malformed, but seen) keeps every day it
            // runs, and today's row names its route, as it always did.
            active_trips
                .entry(trip.to_string())
                .and_modify(|e| {
                    if days & 1 != 0 {
                        e.0 = route;
                    }
                    e.1 |= days;
                })
                .or_insert((route, days));
        }
    }
    let n_gtfs_trips = active_trips
        .values()
        .filter(|&&(_, days)| days & 1 != 0)
        .count();

    // --- frequencies.txt (optional): trip -> (start, end, headway) windows.
    // Read before stop_times, because a template trip's rows are all kept. ---
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
        let mut row = Record::default();
        while r.next_into(&mut row)? {
            let trip = f(&row, Some(c_trip)).to_string();
            let (Some(start), Some(end)) = (
                parse_gtfs_time(f(&row, c_start)),
                parse_gtfs_time(f(&row, c_end)),
            ) else {
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
    // A template's rows are all kept whatever day it ran: its windows, not
    // its own times, say when it runs.
    for trip in freq.keys() {
        if let Some(v) = active_trips.get_mut(trip) {
            v.1 |= ALL_ROWS;
        }
    }

    // --- stop_times.txt (streamed): rows for active trips only. A trip that
    // runs only on an earlier day keeps just the rows that can still be
    // today, plus untimed ones to be filled in between: the rest of it has
    // already run, and keeping it would hold every day-type's trips at once.
    // Its last timed stop before today is kept as an anchor, so the untimed
    // stops just after midnight are filled in from it. ---
    let (h, mut r) =
        open_csv(dir, "stop_times.txt")?.ok_or_else(|| err("stop_times.txt missing or empty"))?;
    let c_trip = h.req("trip_id", "stop_times.txt")?;
    let c_stop = h.req("stop_id", "stop_times.txt")?;
    let c_seq = h.req("stop_sequence", "stop_times.txt")?;
    let (c_arr, c_dep) = (h.get("arrival_time"), h.get("departure_time"));
    // trip_id -> rows of (seq, stop, arr?, dep?)
    type StopTimeRow = (u32, u32, Option<Time>, Option<Time>);
    let mut trip_rows: HashMap<String, Vec<StopTimeRow>> = HashMap::new();
    let mut anchors: HashMap<String, StopTimeRow> = HashMap::new();
    // The anchor candidate of the trip being read, held in reused buffers
    // until the trip turns out to reach today. Most earlier-day trips never
    // do; a stop lookup and a map entry for each of their rows cost a big
    // city's build a fifth more time. Every real feed lists a trip's rows
    // together; one that interleaves them only loses the fill-in.
    let mut candidate_trip = String::new();
    let mut candidate_stop = String::new();
    let mut candidate: Option<(u32, Option<Time>, Option<Time>)> = None;
    let mut stop_visits = vec![0u32; stop_ids.len()];
    let mut row = Record::default();
    while r.next_into(&mut row)? {
        let trip = f(&row, Some(c_trip));
        let Some(&(_, days)) = active_trips.get(trip) else {
            continue;
        };
        let earlier_only = days & (1 | ALL_ROWS) == 0;
        let (arr, dep) = (
            parse_gtfs_time(f(&row, c_arr)),
            parse_gtfs_time(f(&row, c_dep)),
        );
        if earlier_only {
            let today_starts = DAY_SECS * days.trailing_zeros();
            if arr.max(dep).is_some_and(|t| t < today_starts) {
                let Ok(seq) = f(&row, Some(c_seq)).trim().parse::<u32>() else {
                    continue;
                };
                if candidate_trip != trip {
                    candidate_trip.clear();
                    candidate_trip.push_str(trip);
                    candidate = None;
                }
                if candidate.is_none_or(|(s, _, _)| seq > s) {
                    candidate = Some((seq, arr, dep));
                    candidate_stop.clear();
                    candidate_stop.push_str(f(&row, Some(c_stop)));
                }
                continue;
            }
        }
        let Some(&stop) = stop_index.get(f(&row, Some(c_stop))) else {
            continue; // row references an unknown stop
        };
        let Ok(seq) = f(&row, Some(c_seq)).trim().parse::<u32>() else {
            continue;
        };
        if earlier_only && candidate_trip == trip {
            if let (Some((s, a, d)), Some(&at)) =
                (candidate.take(), stop_index.get(candidate_stop.as_str()))
            {
                anchors.insert(trip.to_string(), (s, at, a, d));
            }
        }
        trip_rows
            .entry(trip.to_string())
            .or_default()
            .push((seq, stop, arr, dep));
    }

    // --- Assemble concrete trips: order stops, fill blank times, expand
    // frequencies. Deterministic: trips processed in sorted trip_id order. ---
    let mut n_dropped = 0usize;
    let mut raw: Vec<RawTrip> = Vec::new();
    let mut trip_ids_sorted: Vec<&String> = trip_rows.keys().collect();
    trip_ids_sorted.sort();
    for trip_id in trip_ids_sorted {
        let (route, days) = active_trips[trip_id.as_str()];
        let mut rows = trip_rows[trip_id.as_str()].clone();
        if let Some(anchor) = anchors.remove(trip_id.as_str()) {
            rows.push(anchor);
        }
        rows.sort_by_key(|r| r.0);
        rows.dedup_by_key(|r| r.0); // duplicate stop_sequence: keep first
        if days & (1 | ALL_ROWS) == 0 {
            // Only its late rows (and the anchor) were kept, so it begins at
            // the first timed one and ends at the last; fewer than two means
            // it is not running today at all — not a broken trip.
            let untimed = |r: &StopTimeRow| r.2.is_none() && r.3.is_none();
            let lead = rows.iter().take_while(|r| untimed(r)).count();
            rows.drain(..lead);
            while rows.last().is_some_and(untimed) {
                rows.pop();
            }
            if rows.len() < 2 {
                continue;
            }
        }
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
        if times.first().copied().flatten().is_none() || times.last().copied().flatten().is_none() {
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

        // Each concrete trip goes in once for every day it runs: as it is for
        // today, and for an earlier day as the part still running after
        // today's midnight. Busyness counts CONCRETE trips: a headway shuttle
        // serving a stop 200x/day must weigh 200, same as 200 scheduled trips.
        let mut emit = |pattern: Vec<u32>, events: TripEvents| {
            for k in 1..=CARRY_DAYS {
                if days & (1 << k) == 0 {
                    continue;
                }
                if let Some((pattern, events)) = carried(&pattern, &events, DAY_SECS * k) {
                    for &s in &pattern {
                        stop_visits[s as usize] += 1;
                    }
                    raw.push(RawTrip {
                        route,
                        pattern,
                        events,
                    });
                }
            }
            if days & 1 != 0 {
                for &s in &pattern {
                    stop_visits[s as usize] += 1;
                }
                raw.push(RawTrip {
                    route,
                    pattern,
                    events,
                });
            }
        };

        if let Some(windows) = freq.get(trip_id.as_str()) {
            // frequencies.txt: the scheduled trip is a TEMPLATE; emit one
            // concrete trip per headway departure in [start, end).
            let first_dep = events[0].dep;
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
                                Some(StopEvent {
                                    arr: a as Time,
                                    dep: d as Time,
                                })
                            }
                        })
                        .collect();
                    if let Some(evs) = shifted {
                        emit(pattern.clone(), evs);
                    }
                    t = t.saturating_add(headway);
                }
            }
        } else {
            emit(pattern, events);
        }
    }
    drop(trip_rows);
    drop(anchors);

    // --- transfers.txt (optional) → directed footpaths, kept in this feed's
    // own stop indices; they are resolved here because only this feed knows
    // what its stop_ids mean. ---
    let mut transfers: Vec<(u32, u32, Time)> = Vec::new();
    if let Some((h, mut r)) = open_csv(dir, "transfers.txt")? {
        let (c_from, c_to, c_type, c_min) = (
            h.get("from_stop_id"),
            h.get("to_stop_id"),
            h.get("transfer_type"),
            h.get("min_transfer_time"),
        );
        const DEFAULT_TRANSFER_SECS: Time = 120;
        let mut row = Record::default();
        while r.next_into(&mut row)? {
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
            transfers.push((from, to, secs));
        }
    }

    Ok(FeedParts {
        stop_ids,
        stop_names,
        stop_zones,
        stop_latlon,
        stop_visits,
        route_modes,
        route_names: gtfs_route_names,
        raw,
        transfers,
        service_date,
        agency_timezone,
        feed_published,
        n_gtfs_trips,
        n_dropped,
    })
}

/// Merge parsed feeds into one [`GtfsLoad`]. The first feed is the
/// reference; each feed's times move by its shift into the reference's clock.
///
/// For a single feed with a zero shift this is exactly the old single-feed
/// load, byte for byte — every offset is zero, no trip moves, and there is no
/// second feed to link to. That identity is tested against real shards.
fn assemble(feeds: Vec<(FeedParts, i32)>, skipped: Vec<(usize, String)>) -> GtfsLoad {
    let service_date = feeds[0].0.service_date;
    let agency_timezone = feeds[0].0.agency_timezone.clone();
    // The oldest schedule in the mix is the one a rider should be warned
    // about, so "Times as of" reports the earliest publication date known.
    let feed_published = feeds
        .iter()
        .map(|(p, _)| p.feed_published)
        .filter(|&d| d > 0)
        .min()
        .unwrap_or(0);

    let mut stop_ids: Vec<String> = Vec::new();
    let mut stop_names: Vec<String> = Vec::new();
    let mut stop_zones: Vec<String> = Vec::new();
    let mut stop_latlon: Vec<(i32, i32)> = Vec::new();
    let mut stop_visits: Vec<u32> = Vec::new();
    let mut stop_feed: Vec<u16> = Vec::new();
    let mut route_modes: Vec<Mode> = Vec::new();
    let mut gtfs_route_names: Vec<String> = Vec::new();
    let mut raw: Vec<RawTrip> = Vec::new();
    let mut transfers: Vec<(u32, u32, Time)> = Vec::new();
    let mut n_gtfs_trips = 0usize;
    let mut n_dropped = 0usize;

    for (feed_no, (p, shift)) in feeds.into_iter().enumerate() {
        let stop_base = stop_ids.len() as u32;
        let route_base = route_modes.len() as u32;
        n_gtfs_trips += p.n_gtfs_trips;
        n_dropped += p.n_dropped;
        stop_feed.extend(std::iter::repeat_n(feed_no as u16, p.stop_ids.len()));
        stop_ids.extend(p.stop_ids);
        stop_names.extend(p.stop_names);
        stop_zones.extend(p.stop_zones);
        stop_latlon.extend(p.stop_latlon);
        stop_visits.extend(p.stop_visits);
        route_modes.extend(p.route_modes);
        gtfs_route_names.extend(p.route_names);
        for (from, to, secs) in p.transfers {
            transfers.push((stop_base + from, stop_base + to, secs));
        }
        for mut t in p.raw {
            // Into the reference clock. A trip the shift would push before
            // midnight is dropped, never wrapped: wrapping would put it on
            // the wrong day with a time that looks perfectly ordinary.
            if shift != 0 {
                let moved: Option<TripEvents> = t
                    .events
                    .iter()
                    .map(|e| {
                        let a = e.arr as i64 + shift as i64;
                        let d = e.dep as i64 + shift as i64;
                        (a >= 0 && d >= 0 && d <= Time::MAX as i64).then_some(StopEvent {
                            arr: a as Time,
                            dep: d as Time,
                        })
                    })
                    .collect();
                match moved {
                    Some(ev) => t.events = ev,
                    None => {
                        n_dropped += 1;
                        continue;
                    }
                }
            }
            t.route += route_base;
            for s in &mut t.pattern {
                *s += stop_base;
            }
            raw.push(t);
        }
    }

    // --- The RAPTOR derivation: group by (GTFS route, exact stop sequence),
    // sort by first departure, split overtaking trips into separate engine
    // routes so departure-at-every-stop is non-decreasing in trip index —
    // `earliest_trip`'s binary-search invariant. ---
    let mut groups: HashMap<(u32, Vec<u32>), Vec<TripEvents>> = HashMap::new();
    for rt in raw {
        groups
            .entry((rt.route, rt.pattern))
            .or_default()
            .push(rt.events);
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

    // --- Each feed's own transfers.txt, in the order it listed them. ---
    for (from, to, secs) in transfers {
        builder.add_footpath(from, to, secs);
    }

    // --- Walking links BETWEEN feeds (none when there is only one). ---
    let n_feed_links = link_feeds(&mut builder, &stop_latlon, &stop_visits, &stop_feed);

    GtfsLoad {
        timetable: builder.build(),
        stop_ids,
        stop_names,
        stop_zones,
        route_names,
        service_date,
        agency_timezone,
        feed_published,
        n_gtfs_trips,
        n_trips,
        n_events,
        n_overtake_splits,
        n_dropped_trips: n_dropped,
        stop_visits,
        stop_feed,
        n_feed_links,
        skipped_feeds: skipped,
    }
}

/// Join nearby stops with a footpath both ways, where a rider would walk and
/// no publisher said so. Returns how many pairs were joined.
///
/// Two kinds of pair:
///
/// - stops of DIFFERENT feeds within [`MAX_STATION_LINK_METERS`] — Amtrak's platform and the city bus bay
///   across the street, which two unrelated publishers never connect; and
/// - stops of the same CITY feed (any feed after the first) within
///   [`MAX_LINK_METERS`]. A bus network is
///   full of stops a few steps apart — the two sides of a street, the corner
///   where two routes cross — and publishers rarely list them as transfers.
///   Without these, the only way from one bus line to a stop 150 m away was
///   a one-minute ride on a third (seen live: Chicago to UW-Milwaukee took
///   three changes, the last a single stop, instead of a two-minute walk).
///
/// The FIRST feed's own stops are left exactly as its publisher described
/// them: Amtrak models each station deliberately, and a shard of Amtrak alone
/// stays byte-identical to what it has always been.
///
/// Stops are sorted by latitude and each one scans only the band a link could
/// reach, so a city of ten thousand stops beside Amtrak's six hundred is a
/// few milliseconds, not a hundred million distance checks. Deterministic:
/// the same feeds always produce the same links in the same order.
fn link_feeds(
    builder: &mut TimetableBuilder,
    latlon: &[(i32, i32)],
    visits: &[u32],
    feed: &[u16],
) -> usize {
    if feed
        .iter()
        .all(|&f| f == feed.first().copied().unwrap_or(0))
    {
        return 0; // one feed: nothing to join, and its footpaths stay as published
    }
    // Only stops something calls at. An entrance or a parent station with no
    // trips is not somewhere to change vehicles.
    let mut served: Vec<(i32, u32)> = (0..latlon.len())
        .filter(|&s| visits[s] > 0)
        .map(|s| (latlon[s].0, s as u32))
        .collect();
    served.sort_unstable();

    // One degree of latitude is 111.32 km everywhere, so a fixed band in
    // micro-degrees bounds the scan; longitude is checked by true distance.
    let band_e6 = (MAX_STATION_LINK_METERS.max(MAX_LINK_METERS) / 111_320.0 * 1e6).ceil() as i32;
    let mut pairs = 0usize;
    for (i, &(lat_a, a)) in served.iter().enumerate() {
        let (la, lo) = latlon[a as usize];
        for &(lat_b, b) in &served[i + 1..] {
            if lat_b - lat_a > band_e6 {
                break;
            }
            if feed[a as usize] == feed[b as usize] && feed[a as usize] == 0 {
                continue; // the first feed's own walks are its publisher's business
            }
            let (lb, lob) = latlon[b as usize];
            let meters = haversine_km(
                la as f64 / 1e6,
                lo as f64 / 1e6,
                lb as f64 / 1e6,
                lob as f64 / 1e6,
            ) * 1000.0;
            let reach = if feed[a as usize] == feed[b as usize] {
                MAX_LINK_METERS
            } else {
                MAX_STATION_LINK_METERS
            };
            if meters > reach {
                continue;
            }
            let secs = LINK_BUFFER_SECS + (meters / LINK_WALK_MPS).ceil() as Time;
            builder.add_footpath(a, b, secs);
            builder.add_footpath(b, a, secs);
            pairs += 1;
        }
    }
    pairs
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
        let mut r = CsvReader::new(Cursor::new(b"a,b,c\n1\n".to_vec()));
        let mut row = Record::default();
        assert!(r.next_into(&mut row).unwrap(), "header");
        assert!(r.next_into(&mut row).unwrap(), "the short row");
        assert_eq!(f(&row, Some(0)), "1");
        assert_eq!(f(&row, Some(2)), ""); // short row
        assert_eq!(f(&row, None), ""); // absent optional column
        assert!(!r.next_into(&mut row).unwrap(), "end of file");
    }

    #[test]
    fn gtfs_times_including_past_midnight() {
        assert_eq!(parse_gtfs_time("08:30:15"), Some(8 * 3600 + 30 * 60 + 15));
        assert_eq!(parse_gtfs_time("8:30:15"), Some(8 * 3600 + 30 * 60 + 15));
        assert_eq!(parse_gtfs_time("24:00:00"), Some(86_400));
        assert_eq!(
            parse_gtfs_time("25:30:00"),
            Some(91_800),
            ">24h service past midnight"
        );
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
        assert_eq!(
            days_to_date(date_to_days(20261231) + 1),
            20270101,
            "year rollover"
        );
        assert_eq!(
            days_to_date(date_to_days(20280228) + 1),
            20280229,
            "leap day"
        );
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
    const CALENDAR: &str =
        "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n\
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
        assert_eq!(
            js[0].arrival,
            9 * 3600 + 1200,
            "only the exception-added trip runs"
        );
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
        assert!(
            load_gtfs(&dir, Some(20260709)).is_err(),
            "no service the next day"
        );
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
        assert_eq!(
            js[0].arrival, 91_800,
            "25:30:00 kept as 91800s, not wrapped"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn last_nights_bus_still_runs_after_midnight() {
        // GTFS files the owl bus under the day it LEAVES: 23:30 at A, then
        // 24:40 at B and 25:30 at C. At 12:30 AM on Wednesday, Tuesday's bus
        // is still coming to B — a timetable of Wednesday's trips alone said
        // the next bus to C was Wednesday night's.
        let dir = write_feed(
            "owlcarry",
            &[
                ("stops.txt", STOPS),
                ("routes.txt", ROUTES),
                ("calendar.txt", CALENDAR),
                ("trips.txt", "route_id,service_id,trip_id\nR1,WK,owl\n"),
                (
                    "stop_times.txt",
                    "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n\
                     owl,23:30:00,23:30:00,A,1\n\
                     owl,24:40:00,24:40:00,B,2\n\
                     owl,25:30:00,25:30:00,C,3\n",
                ),
            ],
        );
        let wed = load_gtfs(&dir, Some(20260708)).unwrap();
        let js = plan(&wed.timetable, 1, 2, 30 * 60, 8);
        assert_eq!(js[0].arrival, 5_400, "Tuesday's bus reaches C at 1:30 AM");
        let js = plan(&wed.timetable, 0, 2, 23 * 3600, 8);
        assert_eq!(js[0].arrival, 91_800, "Wednesday's own bus is still there");
        assert_eq!(wed.n_gtfs_trips, 1, "trips counted are the day's own");
        assert_eq!(wed.n_dropped_trips, 0);

        // Monday: Sunday runs no WK service, so nothing carries over.
        let mon = load_gtfs(&dir, Some(20260706)).unwrap();
        let js = plan(&mon.timetable, 1, 2, 30 * 60, 8);
        assert_eq!(js[0].arrival, 91_800, "only Monday night's bus");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_train_days_long_keeps_every_stop_and_every_day() {
        // Amtrak's Sunset Limited ends at 56:35:00 and the Texas Eagle's
        // through cars at 80:00:00. Hours past 48 used to blank the time,
        // and a trip with a blank last stop was dropped — whole trains gone.
        let dir = write_feed(
            "longtrain",
            &[
                ("stops.txt", STOPS),
                ("routes.txt", ROUTES),
                (
                    "calendar.txt",
                    "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n\
                     WK,1,1,1,1,1,0,0,20260706,20260731\n\
                     TRI,1,0,1,0,1,0,0,20260706,20260731\n",
                ),
                (
                    "trips.txt",
                    "route_id,service_id,trip_id\nR1,WK,local\nR1,TRI,sunset\n",
                ),
                (
                    "stop_times.txt",
                    "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n\
                     local,08:00:00,08:00:00,A,1\n\
                     local,08:10:00,08:10:00,B,2\n\
                     sunset,10:00:00,10:00:00,A,1\n\
                     sunset,50:00:00,50:00:00,B,2\n\
                     sunset,56:35:00,56:35:00,C,3\n",
                ),
            ],
        );
        // Wednesday: its own train (A 10:00 → C 56:35), and Monday's, now two
        // days out, due at B at 2:00 AM and C at 8:35 AM.
        let wed = load_gtfs(&dir, Some(20260708)).unwrap();
        assert_eq!(wed.n_dropped_trips, 0);
        let js = plan(&wed.timetable, 0, 2, 9 * 3600, 8);
        assert_eq!(js[0].arrival, 56 * 3600 + 35 * 60, "the day's own train");
        let js = plan(&wed.timetable, 1, 2, 0, 8);
        assert_eq!(
            js[0].arrival,
            8 * 3600 + 35 * 60,
            "Monday's train, still running"
        );

        // Thursday runs no train of its own; Wednesday's passes B at 2:00
        // AM Friday and reaches C at 8:35 AM Friday, both Thursday-relative.
        let thu = load_gtfs(&dir, Some(20260709)).unwrap();
        assert_eq!(thu.n_gtfs_trips, 1, "only the local runs Thursday");
        assert_eq!(
            thu.n_dropped_trips, 0,
            "a train not running today is not broken"
        );
        let js = plan(&thu.timetable, 1, 2, 0, 8);
        assert_eq!(js[0].arrival, 32 * 3600 + 35 * 60);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn untimed_stops_after_midnight_are_filled_from_the_last_timed_one() {
        // Wednesday's owl bus is timed at A (23:00) and C (25:00) only; B,
        // halfway, is untimed. On Thursday only its rows after midnight are
        // kept, and B is still filled in from A — 24:00, midnight.
        let dir = write_feed(
            "owluntimed",
            &[
                ("stops.txt", STOPS),
                ("routes.txt", ROUTES),
                (
                    "calendar.txt",
                    "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n\
                     WK,1,1,1,1,1,0,0,20260706,20260731\n\
                     WED,0,0,1,0,0,0,0,20260706,20260731\n",
                ),
                (
                    "trips.txt",
                    "route_id,service_id,trip_id\nR1,WK,day\nR1,WED,owl\n",
                ),
                (
                    "stop_times.txt",
                    "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n\
                     day,08:00:00,08:00:00,A,1\n\
                     day,08:10:00,08:10:00,C,2\n\
                     owl,23:00:00,23:00:00,A,1\n\
                     owl,,,B,2\n\
                     owl,25:00:00,25:00:00,C,3\n",
                ),
            ],
        );
        let thu = load_gtfs(&dir, Some(20260709)).unwrap();
        let js = plan(&thu.timetable, 1, 2, 0, 8);
        assert_eq!(
            js[0].arrival, 3_600,
            "board at B at midnight, reach C at 1:00 AM"
        );
        assert_eq!(thu.n_dropped_trips, 0);
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
        assert_eq!(
            earliest_arrival(&load.timetable, 0, 2, 8 * 3600, 8),
            8 * 3600 + 40 * 60
        );
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
                (
                    "trips.txt",
                    "route_id,service_id,trip_id\nR1,WK,t1\nR1,WK,t2\n",
                ),
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
        assert_eq!(
            load.timetable.n_routes(),
            1,
            "well-behaved trips share a route"
        );
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
        assert_eq!(
            load.n_trips, 3,
            "three headway departures in [08:00, 09:00)"
        );
        // Depart 08:05 → catch the 08:20 → arrive 08:35 (template ride = 15 min).
        assert_eq!(
            earliest_arrival(&load.timetable, 0, 1, 8 * 3600 + 300, 8),
            8 * 3600 + 35 * 60
        );
        // The 06:00 template itself must NOT run as a scheduled trip.
        assert_eq!(
            earliest_arrival(&load.timetable, 0, 1, 0, 8),
            8 * 3600 + 15 * 60
        );
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
        assert_eq!(
            earliest_arrival(&load.timetable, 0, 1, 0, 8),
            6 * 3600 + 15 * 60
        );
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
                (
                    "trips.txt",
                    "route_id,service_id,trip_id\nR1,WK,t1\nR2,WK,t2\n",
                ),
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
        assert!(j
            .legs
            .iter()
            .any(|l| l.kind == LegKind::Walk && l.arr - l.dep == 180));
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
        assert_eq!(mode_for_route_type(4), Mode::Ship); // ferry
        assert_eq!(mode_for_route_type(1000), Mode::Ship); // water transport service
        assert_eq!(mode_for_route_type(1200), Mode::Ship); // ferry service
        assert_eq!(
            mode_for_route_type(1100),
            Mode::Bus,
            "air service is not a ship"
        );
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
                (
                    "transfers.txt",
                    "from_stop_id,to_stop_id,transfer_type,min_transfer_time\nB,B,2,120\n",
                ),
            ],
        );
        let load = load_gtfs(&dir, Some(20260709)).unwrap();
        let tt = &load.timetable;
        assert_eq!(load.stop_ids, vec!["A", "B", "C"]);
        assert_eq!(
            load.stop_names[0], "Alpha, Main",
            "quoted comma name survives"
        );

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

    // ---- Several feeds in one timetable. ----

    /// A train operator on Eastern time with one daily run into "Union", and a
    /// city bus operator on Central time whose stop "UNIONBUS" stands ~150 m
    /// from the train station (0.00135° of latitude). Built so the only way
    /// from "Start" to "Uptown" is train, walk, bus.
    fn rail_feed(name: &str) -> PathBuf {
        write_feed(
            name,
            &[
                (
                    "agency.txt",
                    "agency_id,agency_name,agency_timezone\n1,Rail,America/New_York\n",
                ),
                (
                    "feed_info.txt",
                    "feed_publisher_name,feed_publisher_url,feed_lang,feed_version\n\
                     Rail,http://example.invalid,en,20260920\n",
                ),
                (
                    "stops.txt",
                    "stop_id,stop_name,stop_timezone,stop_lat,stop_lon\n\
                     START,Start,America/Chicago,42.00000,-88.00000\n\
                     UNION,Union,America/Chicago,41.87890,-87.63990\n",
                ),
                (
                    "routes.txt",
                    "route_id,route_short_name,route_long_name,route_type\nR,,Lakeshore,2\n",
                ),
                ("calendar.txt", CALENDAR),
                ("trips.txt", "route_id,service_id,trip_id\nR,WK,r1\n"),
                (
                    // Eastern: 09:00 -> 10:00, i.e. 8:00 -> 9:00 Central.
                    "stop_times.txt",
                    "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n\
                     r1,09:00:00,09:00:00,START,1\n\
                     r1,10:00:00,10:00:00,UNION,2\n",
                ),
            ],
        )
    }

    fn bus_feed(name: &str, bus_stop_lat: &str, published: &str) -> PathBuf {
        write_feed(
            name,
            &[
                (
                    "agency.txt",
                    "agency_id,agency_name,agency_timezone\n1,City Bus,America/Chicago\n",
                ),
                (
                    "feed_info.txt",
                    &format!(
                        "feed_publisher_name,feed_publisher_url,feed_lang,feed_version\n\
                         Bus,http://example.invalid,en,{published}\n"
                    ),
                ),
                (
                    // No stop_timezone column at all: every stop keeps the
                    // agency's zone, which is Central, not the merge's Eastern.
                    "stops.txt",
                    &format!(
                        "stop_id,stop_name,stop_lat,stop_lon\n\
                         UNIONBUS,Union Bus Bay,{bus_stop_lat},-87.63990\n\
                         UPTOWN,Uptown,41.96500,-87.65500\n\
                         DEPOT,Depot,41.80000,-87.60000\n"
                    ),
                ),
                (
                    "routes.txt",
                    "route_id,route_short_name,route_long_name,route_type\nB,22,Clark,3\n",
                ),
                ("calendar.txt", CALENDAR),
                (
                    "trips.txt",
                    "route_id,service_id,trip_id\nB,WK,b1\nB,WK,b2\n",
                ),
                (
                    // Central: the 09:10 leaves ten minutes after the train
                    // gets in (10:00 Eastern = 9:00 Central). DEPOT is a stop
                    // no trip calls at, to prove unserved stops are not linked.
                    "stop_times.txt",
                    "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n\
                     b1,09:10:00,09:10:00,UNIONBUS,1\n\
                     b1,09:40:00,09:40:00,UPTOWN,2\n\
                     b2,08:10:00,08:10:00,UNIONBUS,1\n\
                     b2,08:40:00,08:40:00,UPTOWN,2\n",
                ),
            ],
        )
    }

    fn stop(load: &GtfsLoad, id: &str) -> u32 {
        load.stop_ids.iter().position(|s| s == id).unwrap() as u32
    }

    /// Central is one hour behind Eastern in July.
    const CENTRAL_INTO_EASTERN: i32 = 3600;

    #[test]
    fn a_train_then_a_city_bus_is_one_trip() {
        let rail = rail_feed("many_rail");
        let bus = bus_feed("many_bus", "41.88025", "20260915");
        let load = load_gtfs_many(
            &[
                FeedInput {
                    dir: &rail,
                    shift_secs: 0,
                },
                FeedInput {
                    dir: &bus,
                    shift_secs: CENTRAL_INTO_EASTERN,
                },
            ],
            20260709,
        )
        .unwrap();

        assert!(load.skipped_feeds.is_empty());
        assert_eq!(
            load.n_feed_links, 1,
            "only the station and the bus bay are close"
        );
        let js = plan(
            &load.timetable,
            stop(&load, "START"),
            stop(&load, "UPTOWN"),
            0,
            8,
        );
        let j = js.first().expect("train, walk, bus");
        let kinds: Vec<LegKind> = j.legs.iter().map(|l| l.kind).collect();
        assert_eq!(kinds, vec![LegKind::Ride, LegKind::Walk, LegKind::Ride]);
        // The bus's 09:10 Central is 10:10 in the merged Eastern clock; it
        // arrives 09:40 Central = 10:40 Eastern. The earlier 08:10 bus left
        // before the train got in and must not be the one chosen.
        assert_eq!(j.legs[2].dep, 10 * 3600 + 10 * 60);
        assert_eq!(j.arrival, 10 * 3600 + 40 * 60);
        // The walk is the fixed allowance plus ~150 m at the connection pace.
        let walk = j.legs[1].arr - j.legs[1].dep;
        assert!(
            (LINK_BUFFER_SECS + 130..=LINK_BUFFER_SECS + 145).contains(&walk),
            "walk took {walk}s"
        );
        let _ = fs::remove_dir_all(&rail);
        let _ = fs::remove_dir_all(&bus);
    }

    #[test]
    fn a_city_stop_keeps_its_own_clock_not_the_merged_one() {
        // The bus feed names no stop zones, so its stops take ITS agency's
        // zone. Falling back to the merged (Eastern) zone would print every
        // bus time an hour late on the card.
        let rail = rail_feed("many_zone_rail");
        let bus = bus_feed("many_zone_bus", "41.88025", "20260915");
        let load = load_gtfs_many(
            &[
                FeedInput {
                    dir: &rail,
                    shift_secs: 0,
                },
                FeedInput {
                    dir: &bus,
                    shift_secs: CENTRAL_INTO_EASTERN,
                },
            ],
            20260709,
        )
        .unwrap();
        assert_eq!(
            load.agency_timezone, "America/New_York",
            "the reference's clock"
        );
        assert_eq!(
            load.stop_zones[stop(&load, "UPTOWN") as usize],
            "America/Chicago"
        );
        assert_eq!(load.stop_feed[stop(&load, "START") as usize], 0);
        assert_eq!(load.stop_feed[stop(&load, "UPTOWN") as usize], 1);
        let _ = fs::remove_dir_all(&rail);
        let _ = fs::remove_dir_all(&bus);
    }

    #[test]
    fn a_stop_across_town_is_not_a_connection() {
        // Bus bay moved ~1.1 km away: past MAX_LINK_METERS, so no link, and
        // no way from the train to the bus.
        let rail = rail_feed("many_far_rail");
        let bus = bus_feed("many_far_bus", "41.88890", "20260915");
        let load = load_gtfs_many(
            &[
                FeedInput {
                    dir: &rail,
                    shift_secs: 0,
                },
                FeedInput {
                    dir: &bus,
                    shift_secs: CENTRAL_INTO_EASTERN,
                },
            ],
            20260709,
        )
        .unwrap();
        assert_eq!(load.n_feed_links, 0);
        assert!(plan(
            &load.timetable,
            stop(&load, "START"),
            stop(&load, "UPTOWN"),
            0,
            8
        )
        .is_empty());
        let _ = fs::remove_dir_all(&rail);
        let _ = fs::remove_dir_all(&bus);
    }

    #[test]
    fn one_feed_through_the_merge_is_the_plain_load_byte_for_byte() {
        let rail = rail_feed("many_same_rail");
        let plain = load_gtfs(&rail, Some(20260709)).unwrap();
        let merged = load_gtfs_many(
            &[FeedInput {
                dir: &rail,
                shift_secs: 0,
            }],
            20260709,
        )
        .unwrap();
        assert_eq!(
            ftt::to_bytes(&plain.timetable),
            ftt::to_bytes(&merged.timetable)
        );
        assert_eq!(plain.stop_ids, merged.stop_ids);
        assert_eq!(plain.stop_zones, merged.stop_zones);
        assert_eq!(plain.route_names, merged.route_names);
        assert_eq!(merged.n_feed_links, 0);
        let _ = fs::remove_dir_all(&rail);
    }

    #[test]
    fn a_shift_before_midnight_drops_the_trip_instead_of_wrapping_it() {
        // Back 9 hours, the 08:10 bus lands before midnight and the 09:10 at
        // 00:10: exactly one is dropped. Back 10 hours, both are. A dropped
        // trip is counted, never wrapped onto the previous evening.
        let rail = rail_feed("many_neg_rail");
        let bus = bus_feed("many_neg_bus", "41.88025", "20260915");
        let one_early = load_gtfs_many(
            &[
                FeedInput {
                    dir: &rail,
                    shift_secs: 0,
                },
                FeedInput {
                    dir: &bus,
                    shift_secs: -9 * 3600,
                },
            ],
            20260709,
        )
        .unwrap();
        assert_eq!(
            one_early.n_dropped_trips, 1,
            "08:10 - 9h is before midnight"
        );
        let load = load_gtfs_many(
            &[
                FeedInput {
                    dir: &rail,
                    shift_secs: 0,
                },
                FeedInput {
                    dir: &bus,
                    shift_secs: -10 * 3600,
                },
            ],
            20260709,
        )
        .unwrap();
        assert_eq!(load.n_dropped_trips, 2, "and so is 09:10 - 10h");
        assert!(plan(
            &load.timetable,
            stop(&load, "START"),
            stop(&load, "UPTOWN"),
            0,
            8
        )
        .is_empty());
        let _ = fs::remove_dir_all(&rail);
        let _ = fs::remove_dir_all(&bus);
    }

    #[test]
    fn a_broken_city_feed_costs_nothing_but_itself() {
        // The second feed has no service that day. The trains must still load;
        // the bus feed is reported, not silently lost and not fatal.
        let rail = rail_feed("many_skip_rail");
        let bus = bus_feed("many_skip_bus", "41.88025", "20260915");
        let load = load_gtfs_many(
            &[
                FeedInput {
                    dir: &rail,
                    shift_secs: 0,
                },
                FeedInput {
                    dir: &bus,
                    shift_secs: CENTRAL_INTO_EASTERN,
                },
            ],
            20260711, // a Saturday: CALENDAR runs weekdays only
        );
        // ...but the rail feed has no Saturday service either, and it is the
        // reference, so THAT is an error.
        assert!(load.is_err(), "the reference feed failing fails the load");

        let missing = std::env::temp_dir().join("flows_gtfs_no_such_feed_dir");
        let load = load_gtfs_many(
            &[
                FeedInput {
                    dir: &rail,
                    shift_secs: 0,
                },
                FeedInput {
                    dir: &missing,
                    shift_secs: 0,
                },
            ],
            20260709,
        )
        .unwrap();
        assert_eq!(load.skipped_feeds.len(), 1);
        assert_eq!(load.skipped_feeds[0].0, 1);
        assert!(load.skipped_feeds[0].1.contains("not a directory"));
        assert!(!load.stop_ids.is_empty(), "the trains are all still there");
        let _ = fs::remove_dir_all(&rail);
        let _ = fs::remove_dir_all(&bus);
    }

    #[test]
    fn times_as_of_reports_the_oldest_schedule_in_the_mix() {
        let rail = rail_feed("many_pub_rail"); // published 20260920
        let bus = bus_feed("many_pub_bus", "41.88025", "20260915");
        let load = load_gtfs_many(
            &[
                FeedInput {
                    dir: &rail,
                    shift_secs: 0,
                },
                FeedInput {
                    dir: &bus,
                    shift_secs: CENTRAL_INTO_EASTERN,
                },
            ],
            20260709,
        )
        .unwrap();
        assert_eq!(load.feed_published, 20260915, "warn about the staler one");
        let _ = fs::remove_dir_all(&rail);
        let _ = fs::remove_dir_all(&bus);
    }

    #[test]
    fn a_city_feeds_neighbouring_stops_are_walkable_but_the_first_feeds_are_not() {
        // Two rail stops 100 m apart in the FIRST feed stay unjoined (Amtrak
        // models its stations on purpose); two bus stops 100 m apart in a
        // CITY feed are joined, so a rider can walk across the street.
        let calendar_wk = CALENDAR;
        let rail = write_feed(
            "many_intra_rail",
            &[
                (
                    "agency.txt",
                    "agency_id,agency_name,agency_timezone\n1,Rail,America/New_York\n",
                ),
                (
                    "stops.txt",
                    "stop_id,stop_name,stop_lat,stop_lon\n\
                     R1,Rail One,41.00000,-88.00000\n\
                     R2,Rail Two,41.00090,-88.00000\n\
                     R3,Rail Far,42.00000,-88.00000\n",
                ),
                (
                    "routes.txt",
                    "route_id,route_short_name,route_long_name,route_type\nR,,Line,2\n",
                ),
                ("calendar.txt", calendar_wk),
                (
                    "trips.txt",
                    "route_id,service_id,trip_id\nR,WK,r1\nR,WK,r2\n",
                ),
                (
                    "stop_times.txt",
                    "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n\
                     r1,09:00:00,09:00:00,R1,1\nr1,10:00:00,10:00:00,R3,2\n\
                     r2,09:00:00,09:00:00,R2,1\nr2,10:00:00,10:00:00,R3,2\n",
                ),
            ],
        );
        let bus = write_feed(
            "many_intra_bus",
            &[
                (
                    "agency.txt",
                    "agency_id,agency_name,agency_timezone\n1,Bus,America/New_York\n",
                ),
                (
                    "stops.txt",
                    "stop_id,stop_name,stop_lat,stop_lon\n\
                     B1,North Side,30.00000,-90.00000\n\
                     B2,South Side,30.00090,-90.00000\n\
                     B3,Away,31.00000,-90.00000\n",
                ),
                (
                    "routes.txt",
                    "route_id,route_short_name,route_long_name,route_type\nB,1,One,3\n",
                ),
                ("calendar.txt", calendar_wk),
                (
                    "trips.txt",
                    "route_id,service_id,trip_id\nB,WK,b1\nB,WK,b2\n",
                ),
                (
                    "stop_times.txt",
                    "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n\
                     b1,09:00:00,09:00:00,B1,1\nb1,09:30:00,09:30:00,B3,2\n\
                     b2,09:00:00,09:00:00,B2,1\nb2,09:30:00,09:30:00,B3,2\n",
                ),
            ],
        );
        let load = load_gtfs_many(
            &[
                FeedInput {
                    dir: &rail,
                    shift_secs: 0,
                },
                FeedInput {
                    dir: &bus,
                    shift_secs: 0,
                },
            ],
            20260709,
        )
        .unwrap();
        assert_eq!(load.n_feed_links, 1, "only the bus stops across the street");
        let tt = &load.timetable;
        let walks_from = |id: &str| {
            let s = stop(&load, id);
            (0..tt.n_stops() as u32).filter(|&t| t != s).any(|t| {
                plan(tt, s, t, 0, 1)
                    .iter()
                    .any(|j| j.legs.iter().all(|l| l.kind == LegKind::Walk))
            })
        };
        assert!(walks_from("B1"), "north side to south side on foot");
        assert!(!walks_from("R1"), "Amtrak's stops are as published");
        let _ = fs::remove_dir_all(&rail);
        let _ = fs::remove_dir_all(&bus);
    }

    #[test]
    fn no_feeds_is_an_error_not_a_panic() {
        assert!(load_gtfs_many(&[], 20260709).is_err());
    }
}
