// -----------------------------------------------------------------------------
// Copyright (c) 2026 David B. Foster. All rights reserved.
// Contact: wizeman555@gmail.com
// Unauthorized copying, distribution, modification, or use of this file, in
// whole or in part, is strictly prohibited without the express written
// permission of the copyright holder.
// -----------------------------------------------------------------------------

//! The words FLOWS reads: OpenStreetMap and FEMA route tags, the tire-sensor
//! and OBD fuel replies, a driver's spoken yes, no or pick, broadcast radio
//! station tags and dial positions, and the radio directory's rules —
//! `RouteAttributes.swift`, `VehicleLink.swift`, `VoiceReply.swift`,
//! `BroadcastRadio.swift` and `RadioBrowser.swift` at commit b4b8cd1, the last
//! before their facade switch.
//!
//! | here | Swift |
//! |---|---|
//! | [`max_grade_percent`], [`clearance_meters`], [`weight_limit_lbs`], [`is_high_risk_flood_zone`] | `RouteAttributes` |
//! | [`posted_limit_way_counts`], [`limits_on_route`] | new: which posted limits restrict a route (not ports) |
//! | [`parse_tpms_advertisement`], [`displayed_psi`], [`parse_fuel_reply`], [`looks_like_obd_adapter`] | `VehicleLink` |
//! | [`interpret_yes_no`], [`wants_weather_radio`], [`choose`], [`place_reply`] | `YesNoWords`, `VoiceCommands`, `VoicePick` |
//! | [`RadioKind`], [`kind_for_tags`], [`dial_label`], [`ranked_stations`] | `BroadcastRadio` |
//! | [`is_allowed_mirror`], [`merged_stations`], [`kept_station_rows`], [`unique_server_names`], [`genre_words`], [`state_name`], [`ranked_nearest`] | `RadioBrowser` |
//!
//! # Fidelity
//!
//! Pinned by `flows-bridge/tests/fixtures/swift_tags_and_replies_oracle.tsv`.
//! Every text rule is Swift's, from [`st`]: `lowercased()` and `uppercased()`
//! map scalar by scalar; `==`, `Set` and `Dictionary` keys compare by
//! canonical equivalence; `hasPrefix`, `hasSuffix`, `dropLast`, `dropFirst`,
//! `prefix` and `count` work on grapheme clusters; `isLetter` and `isNumber`
//! read a cluster's first scalar; Foundation's `contains`, `range(of:)` and
//! `replacingOccurrences` match whole clusters; `trimmingCharacters` trims
//! scalars; `Double(String)` is `strtod` behind Swift's checks. Sorts are
//! Swift's own ([`swift_sort_by`]); `max(by:)` keeps its first winner.
//!
//! What stays in Swift: the network fetchers and JSON decoding, CoreBluetooth
//! and the OBD conversation, the microphone, station and ticket links, the
//! kind titles and symbols, and the wording around a tire's position.

use crate::fcmp::smax;
use crate::geo::meters;
use crate::learning::swift_sort_by;
use crate::places_text::asked_name_matches;
use crate::swift_text as st;

/// A point as (latitude, longitude), degrees.
pub type Point = (f64, f64);

// ------------------------------------------------------------------ helpers

/// The text without its last `n` clusters (`String(text.dropLast(n))`).
fn drop_last_clusters(text: &str, n: usize) -> &str {
    let starts: Vec<usize> = st::graphemes(text)
        .scan(0usize, |at, cluster| {
            let start = *at;
            *at += cluster.len();
            Some(start)
        })
        .collect();
    if n >= starts.len() {
        ""
    } else {
        &text[..starts[starts.len() - n]]
    }
}

/// Whether `text` is new to `seen` under Swift `==`, recording it if so: a
/// `Set<String>.insert(_:).inserted`.
fn first_time(seen: &mut Vec<String>, text: &str) -> bool {
    if seen.iter().any(|s| st::eq(s, text)) {
        false
    } else {
        seen.push(text.to_string());
        true
    }
}

// ================================================================ RouteAttributes

/// `RouteAttributes.lowClearanceThresholdMeters`: 13'6".
pub const LOW_CLEARANCE_THRESHOLD_METERS: f64 = 4.115;
/// `RouteAttributes.weightLimitCapLbs`: posted limits at or above this
/// restrict nothing FLOWS models.
pub const WEIGHT_LIMIT_CAP_LBS: f64 = 100_000.0;

const INCH_METERS: f64 = 0.0254;
const FOOT_METERS: f64 = 0.3048;
const LBS_PER_TONNE: f64 = 2204.62;

/// `RouteAttributes.maxGradePercent(elevations:spacingMeters:)`: the largest
/// `|b - a| / spacing * 100` over consecutive samples both present, by
/// Swift's `max`; `None` when the spacing is not `> 0` (NaN included) or no
/// consecutive pair is present.
///
/// Deterministic; panics: none.
#[must_use]
pub fn max_grade_percent(elevations: &[Option<f64>], spacing_meters: f64) -> Option<f64> {
    if spacing_meters > 0.0 {
        let mut max_grade = 0.0;
        let mut saw_pair = false;
        for pair in elevations.windows(2) {
            if let (Some(a), Some(b)) = (pair[0], pair[1]) {
                saw_pair = true;
                max_grade = smax(max_grade, (b - a).abs() / spacing_meters * 100.0);
            }
        }
        saw_pair.then_some(max_grade)
    } else {
        None
    }
}

/// An empty tag or one of the OSM "no value" spellings.
fn is_unset(t: &str) -> bool {
    t.is_empty() || ["default", "none", "unsigned"].iter().any(|s| st::eq(t, s))
}

/// `RouteAttributes.clearanceMeters(fromOSM:)`: an OSM `maxheight` in meters.
///
/// The tag is trimmed and lowercased. Feet and inches split at the first
/// `'` cluster (inches with `"` removed; missing or unreadable inches are 0,
/// unreadable feet answer `None`); a tag ending in `ft` or `feet` loses both
/// words and reads as feet; otherwise one trailing metric unit is dropped
/// (longest first) and a decimal comma becomes a point.
///
/// Deterministic; panics: none.
#[must_use]
pub fn clearance_meters(tag: &str) -> Option<f64> {
    let t = st::lowercased(st::trim_whitespace(tag));
    if is_unset(&t) {
        return None;
    }
    let mut at = 0usize;
    for cluster in st::graphemes(&t) {
        if cluster == "'" {
            let feet = st::swift_double(st::trim_whitespace(&t[..at]));
            let rest_owned = st::replacing(&t[at + cluster.len()..], "\"", "");
            let rest = st::trim_whitespace(&rest_owned);
            let inches = if rest.is_empty() {
                0.0
            } else {
                st::swift_double(rest).unwrap_or(0.0)
            };
            return feet.map(|feet| (feet * 12.0 + inches) * INCH_METERS);
        }
        at += cluster.len();
    }
    if st::has_suffix(&t, "ft") || st::has_suffix(&t, "feet") {
        let v = st::replacing(&st::replacing(&t, "feet", ""), "ft", "");
        return st::swift_double(st::trim_whitespace(&v)).map(|x| x * FOOT_METERS);
    }
    let mut v: &str = &t;
    for unit in ["metres", "meters", "metre", "meter", "m"] {
        if st::has_suffix(v, unit) {
            v = drop_last_clusters(v, st::cluster_count(unit));
            break;
        }
    }
    st::swift_double(&st::replacing(st::trim_whitespace(v), ",", "."))
}

/// `RouteAttributes.weightLimitLbs(fromOSM:)`: an OSM `maxweight` in pounds.
///
/// The tag is trimmed and lowercased. The first matching suffix of tonnes,
/// tonne, tons and ton (short tons, 2,000 lb), lbs, lb, kg, st (short tons)
/// and t is dropped and the rest read as a number (trimmed, decimal comma to
/// point); a bare number is metric tonnes.
///
/// Deterministic; panics: none.
#[must_use]
pub fn weight_limit_lbs(tag: &str) -> Option<f64> {
    const UNITS: [(&str, f64); 9] = [
        ("tonnes", LBS_PER_TONNE),
        ("tonne", LBS_PER_TONNE),
        ("tons", 2000.0),
        ("ton", 2000.0),
        ("lbs", 1.0),
        ("lb", 1.0),
        ("kg", 2.20462),
        ("st", 2000.0),
        ("t", LBS_PER_TONNE),
    ];
    let t = st::lowercased(st::trim_whitespace(tag));
    if is_unset(&t) {
        return None;
    }
    let number = |s: &str| st::swift_double(&st::replacing(st::trim_whitespace(s), ",", "."));
    for (suffix, lbs_per_unit) in UNITS {
        if st::has_suffix(&t, suffix) {
            return number(drop_last_clusters(&t, st::cluster_count(suffix)))
                .map(|x| x * lbs_per_unit);
        }
    }
    number(&t).map(|x| x * LBS_PER_TONNE)
}

/// `RouteAttributes.isHighRiskFloodZone(_:)`: the trimmed, uppercased FEMA
/// zone starts with an `A` or `V` cluster.
///
/// Deterministic; panics: none.
#[must_use]
pub fn is_high_risk_flood_zone(zone: &str) -> bool {
    let z = st::uppercased(st::trim_whitespace(zone));
    st::has_prefix(&z, "A") || st::has_prefix(&z, "V")
}

// ------------------------------------------------- posted limits on the route

// Not ports: which posted height and weight limits restrict a route. The
// corridor boxes FLOWS asks OpenStreetMap about also hold parking garages,
// driveways and roads that cross under or over the route; counting their
// signs said no route into downtown Milwaukee cleared a 13'6" truck (a 6'5"
// garage bar beside the last street).

/// A restricted road's vertex this close to the route's line is on it:
/// OpenStreetMap and Apple draw the same road a few metres apart.
pub const LIMIT_ON_ROUTE_METERS: f64 = 20.0;
/// How far along the route a restricted road must run with it to be the road
/// the route drives. A road crossing under or over the route runs along it
/// for next to nothing; a shorter restricted road needs half its own length.
pub const LIMIT_ALONG_METERS: f64 = 30.0;

/// Whether an OpenStreetMap way's posted height or weight limit belongs to a
/// road a route can drive: it has a `highway` tag that isn't a path, and it
/// isn't a parking aisle, a driveway, a car park, a building or a private
/// road. `tags` are the way's (key, value) pairs.
///
/// Anything else stays counted: missing a real low bridge is worse than an
/// extra warning.
///
/// Deterministic; panics: none.
#[must_use]
pub fn posted_limit_way_counts(tags: &[(&str, &str)]) -> bool {
    let tag = |key: &str| tags.iter().find(|(k, _)| *k == key).map(|(_, v)| *v);
    let Some(highway) = tag("highway") else {
        return false;
    };
    let not_driven = [
        "footway",
        "cycleway",
        "path",
        "pedestrian",
        "steps",
        "bridleway",
        "corridor",
        "platform",
        "elevator",
    ];
    if not_driven.contains(&highway) {
        return false;
    }
    if matches!(
        tag("service"),
        Some("parking_aisle" | "driveway" | "drive-through" | "parking")
    ) {
        return false;
    }
    if tag("amenity") == Some("parking") || tag("parking").is_some() || tag("building").is_some() {
        return false;
    }
    !matches!(tag("access"), Some("private" | "no" | "customers"))
}

/// A route's line indexed for nearby-segment lookups: segments filed under
/// every grid cell their box (grown by [`LIMIT_ON_ROUTE_METERS`]) touches,
/// and the meters along the route to each vertex.
struct RouteIndex<'a> {
    line: &'a [Point],
    along: Vec<f64>,
    cells: std::collections::HashMap<(i64, i64), Vec<usize>>,
}

/// About 550 m of latitude: a grid cell of the route index.
const ROUTE_CELL_DEGREES: f64 = 0.005;

fn route_cell(p: Point) -> (i64, i64) {
    (
        (p.0 / ROUTE_CELL_DEGREES).floor() as i64,
        (p.1 / ROUTE_CELL_DEGREES).floor() as i64,
    )
}

impl<'a> RouteIndex<'a> {
    fn new(line: &'a [Point]) -> Self {
        let mut along = Vec::with_capacity(line.len());
        let mut total = 0.0;
        for (i, &p) in line.iter().enumerate() {
            if i > 0 {
                total += meters(line[i - 1].0, line[i - 1].1, p.0, p.1);
            }
            along.push(total);
        }
        let mut cells: std::collections::HashMap<(i64, i64), Vec<usize>> =
            std::collections::HashMap::new();
        // The margin in degrees, generous in longitude at any latitude FLOWS
        // drives (cos 70° ≈ 0.34).
        let lat_margin = LIMIT_ON_ROUTE_METERS / 111_320.0;
        let lon_margin = lat_margin / 0.34;
        for s in 0..line.len().saturating_sub(1) {
            let (a, b) = (line[s], line[s + 1]);
            if !(a.0.is_finite() && a.1.is_finite() && b.0.is_finite() && b.1.is_finite()) {
                continue;
            }
            let lo = route_cell((a.0.min(b.0) - lat_margin, a.1.min(b.1) - lon_margin));
            let hi = route_cell((a.0.max(b.0) + lat_margin, a.1.max(b.1) + lon_margin));
            for y in lo.0..=hi.0 {
                for x in lo.1..=hi.1 {
                    cells.entry((y, x)).or_default().push(s);
                }
            }
        }
        RouteIndex { line, along, cells }
    }

    /// Meters along the route to the nearest point of its line within
    /// [`LIMIT_ON_ROUTE_METERS`] of `p`; `None` when the line is farther.
    fn along_if_near(&self, p: Point) -> Option<f64> {
        if !(p.0.is_finite() && p.1.is_finite()) {
            return None;
        }
        let segments = self.cells.get(&route_cell(p))?;
        let m_lat = 111_320.0;
        let m_lon = m_lat * (p.0 * std::f64::consts::PI / 180.0).cos();
        let mut best: Option<(f64, f64)> = None;
        for &s in segments {
            let (a, b) = (self.line[s], self.line[s + 1]);
            let (bx, by) = ((b.1 - a.1) * m_lon, (b.0 - a.0) * m_lat);
            let (px, py) = ((p.1 - a.1) * m_lon, (p.0 - a.0) * m_lat);
            let len2 = bx * bx + by * by;
            let t = if len2 > 0.0 {
                ((px * bx + py * by) / len2).clamp(0.0, 1.0)
            } else {
                0.0
            };
            let (dx, dy) = (px - t * bx, py - t * by);
            let off = (dx * dx + dy * dy).sqrt();
            if off <= LIMIT_ON_ROUTE_METERS && best.is_none_or(|(o, _)| off < o) {
                let seg = self.along[s + 1] - self.along[s];
                best = Some((off, self.along[s] + t * seg));
            }
        }
        best.map(|(_, along)| along)
    }
}

/// Metres between the points a restricted road is walked at: OpenStreetMap
/// ways can be long straight runs with no vertex where the route meets them.
const LIMIT_WALK_METERS: f64 = 10.0;
/// A stretch of road on the route counts only when it runs with the route:
/// the route distance it spans is at least this share of the road distance.
/// A road crossing at angle θ spans cos θ of it, so crossings steeper than
/// about 25° never count.
const LIMIT_PARALLEL_SHARE: f64 = 0.9;

/// Whether a restricted road runs along the route: walked every
/// [`LIMIT_WALK_METERS`], a stretch of it in a row within
/// [`LIMIT_ON_ROUTE_METERS`] of the route's line spans at least
/// [`LIMIT_ALONG_METERS`] of the route (or half the road's own length, when
/// that is shorter), running with the route rather than across it. Only the
/// route's segments near each point are measured, so a long route costs
/// little per road.
fn runs_along(index: &RouteIndex, way: &[Point]) -> bool {
    if way.len() < 2 {
        return false;
    }
    // The road walked at even steps: (point, meters along the road).
    let mut walk: Vec<(Point, f64)> = vec![(way[0], 0.0)];
    let mut length = 0.0;
    for w in way.windows(2) {
        let hop = meters(w[0].0, w[0].1, w[1].0, w[1].1);
        if !hop.is_finite() {
            return false;
        }
        let steps = (hop / LIMIT_WALK_METERS).ceil().max(1.0) as usize;
        for k in 1..=steps {
            let t = k as f64 / steps as f64;
            let p = (
                w[0].0 + (w[1].0 - w[0].0) * t,
                w[0].1 + (w[1].1 - w[0].1) * t,
            );
            walk.push((p, length + hop * t));
        }
        length += hop;
    }
    let needed = LIMIT_ALONG_METERS.min(length / 2.0);
    // The current stretch on the route: route span (lo, hi) and where it
    // started along the road.
    let mut run: Option<(f64, f64, f64)> = None;
    for &(p, on_road) in &walk {
        let Some(a) = index.along_if_near(p) else {
            run = None;
            continue;
        };
        let (lo, hi, from) = run.map_or((a, a, on_road), |(lo, hi, from)| {
            (lo.min(a), hi.max(a), from)
        });
        let span = hi - lo;
        if span > 0.0 && span >= needed && span >= LIMIT_PARALLEL_SHARE * (on_road - from) {
            return true;
        }
        run = Some((lo, hi, from));
    }
    false
}

/// A restricted OpenStreetMap way: its line, and its (key, value) tags.
pub type RestrictedWay<'a> = (&'a [Point], Vec<(&'a str, &'a str)>);

/// For each restricted OpenStreetMap way (its line and its (key, value) tags),
/// whether its posted limit restricts a route along `route`: a drivable public
/// road ([`posted_limit_way_counts`]) that runs along the route's line.
///
/// Deterministic; panics: none.
#[must_use]
pub fn limits_on_route(route: &[Point], ways: &[RestrictedWay]) -> Vec<bool> {
    if route.len() < 2 {
        return vec![false; ways.len()];
    }
    let index = RouteIndex::new(route);
    ways.iter()
        .map(|(line, tags)| posted_limit_way_counts(tags) && runs_along(&index, line))
        .collect()
}

// ================================================================ VehicleLink

/// `VehicleLink.lowPressurePsi`: the low-tire chip's threshold.
pub const LOW_PRESSURE_PSI: f64 = 28.0;
const KPA_TO_PSI: f64 = 0.145038;

/// One valve-cap sensor's reading.
#[derive(Clone, Debug, PartialEq)]
pub struct TireReading {
    /// The fifth cluster of the advertised name (the kit's position digit),
    /// or `?` when the name is four clusters long.
    pub position: String,
    /// Pressure in psi.
    pub psi: f64,
    /// Temperature in degrees Celsius.
    pub celsius: f64,
}

/// `VehicleLink.parseTPMSAdvertisement(name:manufacturerData:)`.
///
/// The uppercased name must start with `TPMS` and the data hold at least 16
/// bytes: pressure is a little-endian `u32` at 8 in 1/1000 kPa, temperature
/// a little-endian `i32` at 12 in 1/100 °C. Readings outside 3 to 200 psi
/// (exclusive) are refused. The position comes from the name as advertised,
/// not uppercased.
///
/// Deterministic; panics: none.
#[must_use]
pub fn parse_tpms_advertisement(name: Option<&str>, data: Option<&[u8]>) -> Option<TireReading> {
    let name = name?;
    if !st::has_prefix(&st::uppercased(name), "TPMS") {
        return None;
    }
    let data = data?;
    let pressure: [u8; 4] = data.get(8..12)?.try_into().ok()?;
    let temperature: [u8; 4] = data.get(12..16)?.try_into().ok()?;
    let kpa = f64::from(u32::from_le_bytes(pressure)) / 1000.0;
    let celsius = f64::from(i32::from_le_bytes(temperature)) / 100.0;
    let psi = kpa * KPA_TO_PSI;
    if psi > 3.0 && psi < 200.0 {
        Some(TireReading {
            position: st::graphemes(name).nth(4).unwrap_or("?").to_string(),
            psi,
            celsius,
        })
    } else {
        None
    }
}

/// The pressure as the tire list stores it: `(psi * 10).rounded() / 10`.
///
/// Deterministic; panics: none.
#[must_use]
pub fn displayed_psi(psi: f64) -> f64 {
    (psi * 10.0).round() / 10.0
}

/// Swift's `UInt8(text, radix: 16)`: an optional `+` or `-`, then at least
/// one ASCII hex digit, the value within `0...255`; a minus allows only zero.
fn parse_u8_hex(text: &str) -> Option<u8> {
    let bytes = text.as_bytes();
    let (negative, digits) = match bytes.first()? {
        b'+' => (false, &bytes[1..]),
        b'-' => (true, &bytes[1..]),
        _ => (false, bytes),
    };
    if digits.is_empty() {
        return None;
    }
    let mut value = 0u32;
    for &d in digits {
        value = value * 16 + char::from(d).to_digit(16)?;
        if value > 255 {
            return None;
        }
    }
    if negative && value != 0 {
        return None;
    }
    u8::try_from(value).ok()
}

/// `VehicleLink.parseFuelReply(_:)`: the ELM327 `41 2F xx` fuel level, `A/255`.
///
/// The reply is uppercased and its spaces removed; the two clusters after the
/// first `412F` are read as a hexadecimal byte.
///
/// Deterministic; panics: none.
#[must_use]
pub fn parse_fuel_reply(line: &str) -> Option<f64> {
    let hex = st::replacing(&st::uppercased(line), " ", "");
    let (_, end) = st::find(&hex, "412F")?;
    let mut after = st::graphemes(&hex[end..]);
    let width = after.next()?.len() + after.next()?.len();
    parse_u8_hex(&hex[end..end + width]).map(|a| f64::from(a) / 255.0)
}

/// Whether a discovered Bluetooth name looks like an OBD adapter: its
/// lowercased form contains `obd`, `vlink`, `veepeak` or `elm` (the check in
/// `VehicleLink`'s discovery callback; a missing name is empty).
///
/// Deterministic; panics: none.
#[must_use]
pub fn looks_like_obd_adapter(name: &str) -> bool {
    let lower = st::lowercased(name);
    let index = st::ClusterIndex::new(&lower);
    ["obd", "vlink", "veepeak", "elm"]
        .iter()
        .any(|w| index.find(w).is_some())
}

// ================================================================ VoiceReply

/// `YesNoWords.yesWords`.
pub const YES_WORDS: [&str; 12] = [
    "yes",
    "yeah",
    "yep",
    "yup",
    "sure",
    "okay",
    "ok",
    "go ahead",
    "take it",
    "do it",
    "please",
    "affirmative",
];
/// `YesNoWords.noWords`.
pub const NO_WORDS: [&str; 10] = [
    "no",
    "nope",
    "nah",
    "cancel",
    "don't",
    "negative",
    "stay",
    "keep this route",
    "not now",
    "never mind",
];
/// `VoicePick.backWords`.
pub const BACK_WORDS: [&str; 7] = [
    "go back",
    "back",
    "start over",
    "different",
    "something else",
    "change it",
    "other food",
];

/// `lower.split(whereSeparator: { !$0.isLetter && $0 != "'" })`: the runs of
/// letter and apostrophe clusters, empty runs omitted.
fn reply_words(lower: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start: Option<usize> = None;
    let mut at = 0usize;
    for cluster in st::graphemes(lower) {
        let keeps = st::is_letter_start(cluster) || cluster == "'";
        match (keeps, start) {
            (true, None) => start = Some(at),
            (false, Some(s)) => {
                out.push(&lower[s..at]);
                start = None;
            }
            _ => {}
        }
        at += cluster.len();
    }
    if let Some(s) = start {
        out.push(&lower[s..]);
    }
    out
}

/// A vocabulary entry heard: a phrase (it holds a space) anywhere in the
/// lowercased reply, a single word as a whole word.
fn heard(lower: &str, words: &[&str], vocabulary: &[&str]) -> bool {
    vocabulary.iter().any(|entry| {
        if entry.contains(' ') {
            st::contains(lower, entry)
        } else {
            words.iter().any(|w| st::eq(w, entry))
        }
    })
}

/// `YesNoWords.interpret(_:)`: `Some(false)` when a no is heard (a mixed
/// reply is a refusal), `Some(true)` when a yes is, `None` otherwise.
///
/// Deterministic; panics: none.
#[must_use]
pub fn interpret_yes_no(transcript: &str) -> Option<bool> {
    let lower = st::lowercased(transcript);
    let words = reply_words(&lower);
    if heard(&lower, &words, &NO_WORDS) {
        Some(false)
    } else if heard(&lower, &words, &YES_WORDS) {
        Some(true)
    } else {
        None
    }
}

/// `VoiceCommands.wantsWeatherRadio(_:)`: the lowercased transcript contains
/// `weather` or `noaa`.
///
/// Deterministic; panics: none.
#[must_use]
pub fn wants_weather_radio(transcript: &str) -> bool {
    let lower = st::lowercased(transcript);
    st::contains(&lower, "weather") || st::contains(&lower, "noaa")
}

/// `VoicePick.Outcome`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PickOutcome {
    /// The offered option at this index.
    Picked(usize),
    /// A no.
    Declined,
    /// Nothing clear: never guessed.
    Unclear,
}

/// `VoicePick.PlaceOutcome`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlaceOutcome {
    /// The offered place at this index.
    Picked(usize),
    /// The cuisine at this index replaces the earlier answer.
    SwitchCuisine(usize),
    /// Back to the cuisine question.
    BackToCuisine,
    /// A no.
    Declined,
    /// Nothing clear: never guessed.
    Unclear,
}

/// The index of the longest name (in clusters) the reply names as standalone
/// words, the first on a tie: `filter` then `max(by: count <)`.
fn longest_named(reply: &str, names: &[&str]) -> Option<usize> {
    let mut best: Option<(usize, usize)> = None;
    for (i, name) in names.iter().enumerate() {
        if !asked_name_matches(name, reply) {
            continue;
        }
        let clusters = st::cluster_count(name);
        if best.is_none_or(|(_, longest)| longest < clusters) {
            best = Some((i, clusters));
        }
    }
    best.map(|(i, _)| i)
}

/// `VoicePick.choose(reply:options:)`: a named option, else the first option
/// on a yes, declined on a no, unclear otherwise.
///
/// Deterministic; panics: none.
#[must_use]
pub fn choose(reply: &str, options: &[&str]) -> PickOutcome {
    if let Some(i) = longest_named(reply, options) {
        return PickOutcome::Picked(i);
    }
    match interpret_yes_no(reply) {
        Some(true) => PickOutcome::Picked(0),
        Some(false) => PickOutcome::Declined,
        None => PickOutcome::Unclear,
    }
}

/// `VoicePick.placeReply(_:places:cuisines:)`: a named place, else a named
/// cuisine, else a back-word, else the first place on a yes, declined on a
/// no, unclear otherwise.
///
/// Deterministic; panics: none.
#[must_use]
pub fn place_reply(reply: &str, places: &[&str], cuisines: &[&str]) -> PlaceOutcome {
    if let Some(i) = longest_named(reply, places) {
        return PlaceOutcome::Picked(i);
    }
    if let Some(i) = longest_named(reply, cuisines) {
        return PlaceOutcome::SwitchCuisine(i);
    }
    let lower = st::lowercased(reply);
    if heard(&lower, &reply_words(&lower), &BACK_WORDS) {
        return PlaceOutcome::BackToCuisine;
    }
    match interpret_yes_no(reply) {
        Some(true) => PlaceOutcome::Picked(0),
        Some(false) => PlaceOutcome::Declined,
        None => PlaceOutcome::Unclear,
    }
}

// ================================================================ BroadcastRadio

/// `BroadcastRadio.Kind`, in declaration order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RadioKind {
    /// News and talk.
    News,
    /// Country.
    Country,
    /// Rock.
    Rock,
    /// Pop and hits.
    Pop,
    /// Hip-hop and R&B.
    HipHop,
    /// Oldies.
    Oldies,
    /// Classical.
    Classical,
    /// Jazz.
    Jazz,
    /// Spanish-language.
    Latin,
    /// Sports.
    Sports,
    /// Christian.
    Christian,
}

impl RadioKind {
    /// Every kind, in declaration order (`Kind.allCases`).
    pub const ALL: [RadioKind; 11] = [
        RadioKind::News,
        RadioKind::Country,
        RadioKind::Rock,
        RadioKind::Pop,
        RadioKind::HipHop,
        RadioKind::Oldies,
        RadioKind::Classical,
        RadioKind::Jazz,
        RadioKind::Latin,
        RadioKind::Sports,
        RadioKind::Christian,
    ];

    /// `Kind.matchOrder`: narrow kinds before broad ones.
    pub const MATCH_ORDER: [RadioKind; 11] = [
        RadioKind::Sports,
        RadioKind::Christian,
        RadioKind::Latin,
        RadioKind::Classical,
        RadioKind::Jazz,
        RadioKind::News,
        RadioKind::Country,
        RadioKind::HipHop,
        RadioKind::Oldies,
        RadioKind::Rock,
        RadioKind::Pop,
    ];

    /// `Kind.tagWords`: the directory tags that mean this kind.
    #[must_use]
    pub fn tag_words(self) -> &'static [&'static str] {
        match self {
            RadioKind::Sports => &["sport", "sports talk"],
            RadioKind::Christian => &["christian", "gospel", "worship", "catholic", "religio"],
            RadioKind::Latin => &[
                "spanish",
                "latin",
                "regional mexican",
                "reggaeton",
                "salsa",
                "ranchera",
                "tejano",
                "banda",
                "espanol",
                "espa\u{F1}ol",
            ],
            RadioKind::Classical => &["classical", "opera", "symphon", "baroque", "orchestr"],
            RadioKind::Jazz => &["jazz", "bebop", "swing", "big band", "blues"],
            RadioKind::News => &[
                "news",
                "talk",
                "npr",
                "public radio",
                "current affairs",
                "information",
                "politics",
            ],
            RadioKind::Country => &["country", "bluegrass", "americana", "honky", "western"],
            RadioKind::Oldies => &[
                "oldies",
                "classic hits",
                "50s",
                "60s",
                "70s",
                "80s",
                "nostalgia",
                "adult hits",
                "doo-wop",
                "motown",
            ],
            RadioKind::HipHop => &[
                "hip hop", "hip-hop", "hiphop", "rap", "r&b", "rnb", "rhythm", "urban", "soul",
                "funk",
            ],
            RadioKind::Rock => &["rock", "metal", "punk", "grunge", "alternative", "indie"],
            RadioKind::Pop => &[
                "pop",
                "top 40",
                "top40",
                "hits",
                "dance",
                "electronic",
                "house",
                "chart",
                "contempo",
            ],
        }
    }
}

/// `BroadcastRadio.kind(forTags:)`: the first kind in match order one of
/// whose tag words the lowercased tags contain; `None` for empty tags or no
/// match.
///
/// Deterministic; panics: none.
#[must_use]
pub fn kind_for_tags(tags: &str) -> Option<RadioKind> {
    let hay = st::lowercased(tags);
    if hay.is_empty() {
        return None;
    }
    let index = st::ClusterIndex::new(&hay);
    RadioKind::MATCH_ORDER
        .into_iter()
        .find(|kind| kind.tag_words().iter().any(|w| index.find(w).is_some()))
}

/// One token of number and `.` clusters, considered as a dial position.
fn consider_dial_token(token: &str, best: &mut Option<String>) {
    if token.is_empty() || best.is_some() {
        return;
    }
    // A `.` is always a cluster of its own, so a byte test is Swift's
    // `token.contains(".")` here.
    if token.contains('.') {
        if let Some(v) = st::swift_double(token).filter(|v| *v >= 87.5 && *v <= 108.0) {
            *best = Some(format!("{v:.1} FM"));
        }
    } else if let Some(v) = st::parse_swift_int(token).filter(|v| (530..=1_700).contains(v)) {
        *best = Some(format!("{v} AM"));
    }
}

/// `BroadcastRadio.dialLabel(from:)`: the first dial position in a station
/// name. Runs of number and `.` clusters are tokens; a token with a `.` is
/// FM from 87.5 to 108 (`%.1f FM`), one without is AM from 530 to 1,700.
///
/// Deterministic; panics: none.
#[must_use]
pub fn dial_label(name: &str) -> Option<String> {
    let mut best = None;
    let mut token = String::new();
    for cluster in st::graphemes(name) {
        if st::is_number_start(cluster) || cluster == "." {
            token.push_str(cluster);
        } else {
            consider_dial_token(&token, &mut best);
            token.clear();
        }
    }
    consider_dial_token(&token, &mut best);
    best
}

/// A station as the ranking reads it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RadioStation {
    /// Transmitter latitude, when listed.
    pub lat: Option<f64>,
    /// Transmitter longitude, when listed.
    pub lon: Option<f64>,
    /// Bitrate (or directory votes, for the directory's own list).
    pub bitrate: i64,
}

/// `BroadcastRadio.ranked(_:near:)`: station indices, located stations
/// nearest first, then the rest; equal or missing distances by higher
/// bitrate. Swift's sort, so NaN distances order as the app did.
///
/// Deterministic; panics: none.
#[must_use]
pub fn ranked_stations(stations: &[RadioStation], position: Option<Point>) -> Vec<usize> {
    let distance: Vec<Option<f64>> = stations
        .iter()
        .map(|s| {
            let (lat, lon) = position?;
            Some(meters(s.lat?, s.lon?, lat, lon))
        })
        .collect();
    let mut order: Vec<usize> = (0..stations.len()).collect();
    swift_sort_by(&mut order, |a, b| match (distance[a], distance[b]) {
        (Some(x), Some(y)) if x != y => x < y,
        (None, Some(_)) => false,
        (Some(_), None) => true,
        _ => stations[a].bitrate > stations[b].bitrate,
    });
    order
}

// ================================================================ RadioBrowser

/// `RadioBrowser.nearbyRadiusMeters`: about a day's driving.
pub const NEARBY_RADIUS_METERS: i64 = 400_000;

/// `RadioBrowser.commonGenres`.
pub const COMMON_GENRES: [&str; 26] = [
    "country",
    "classic country",
    "bluegrass",
    "folk",
    "rock",
    "classic rock",
    "metal",
    "pop",
    "top 40",
    "oldies",
    "80s",
    "90s",
    "jazz",
    "blues",
    "classical",
    "hip-hop",
    "r&b",
    "soul",
    "dance",
    "gospel",
    "christian",
    "spanish",
    "regional mexican",
    "news",
    "talk",
    "sports",
];

/// `RadioBrowser.allowedMirrorCountries`, sorted: the only mirror countries
/// the app talks to.
pub const ALLOWED_MIRROR_COUNTRIES: [&str; 17] = [
    "at", "be", "ca", "ch", "cz", "de", "dk", "fi", "fr", "gb", "ie", "nl", "no", "pl", "se", "uk",
    "us",
];

const MIRROR_SUFFIX: &str = ".api.radio-browser.info";

/// `RadioBrowser.isAllowedMirror(_:)`: a lowercased host ending in
/// `.api.radio-browser.info` whose label is two letter clusters naming an
/// allowed country followed only by number clusters.
///
/// Deterministic; panics: none.
#[must_use]
pub fn is_allowed_mirror(host: &str) -> bool {
    let h = st::lowercased(host);
    if !st::has_suffix(&h, MIRROR_SUFFIX) {
        return false;
    }
    let label: Vec<&str> =
        st::graphemes(drop_last_clusters(&h, st::cluster_count(MIRROR_SUFFIX))).collect();
    let letters = label.iter().take_while(|c| st::is_letter_start(c)).count();
    let country = label[..letters].concat();
    letters == 2
        && ALLOWED_MIRROR_COUNTRIES.iter().any(|c| st::eq(&country, c))
        && label.iter().skip(2).all(|c| st::is_number_start(c))
}

/// A station as the free-text merge reads it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DirectoryStation<'a> {
    /// The station name.
    pub name: &'a str,
    /// The stream URL (the station's id).
    pub url: &'a str,
}

/// `RadioBrowser.merged(nameHits:tagHits:)`: indices into the name hits
/// followed by the tag hits, keeping each station whose URL and lowercased
/// name are both new (a repeated URL never records its name); `None` when
/// both searches failed.
///
/// Deterministic; panics: none.
#[must_use]
pub fn merged_stations(
    name_hits: Option<&[DirectoryStation<'_>]>,
    tag_hits: Option<&[DirectoryStation<'_>]>,
) -> Option<Vec<usize>> {
    if name_hits.is_none() && tag_hits.is_none() {
        return None;
    }
    let mut seen_urls = Vec::new();
    let mut seen_names = Vec::new();
    Some(
        name_hits
            .unwrap_or(&[])
            .iter()
            .chain(tag_hits.unwrap_or(&[]))
            .enumerate()
            .filter(|(_, s)| {
                first_time(&mut seen_urls, s.url)
                    && first_time(&mut seen_names, &st::lowercased(s.name))
            })
            .map(|(i, _)| i)
            .collect(),
    )
}

/// A directory row's fields as `parseStations` read them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DirectoryRow<'a> {
    /// `row["name"] as? String`.
    pub name: Option<&'a str>,
    /// `row["url_resolved"] as? String`.
    pub url: Option<&'a str>,
}

/// `RadioBrowser.parseStations(_:)`'s rules over decoded rows: the kept
/// rows' indices with their names trimmed of whitespace and newlines. A row
/// is kept when its trimmed name is not empty, its URL starts with
/// `https://`, and then its URL and its lowercased name are both new, in
/// that order.
///
/// Deterministic; panics: none.
#[must_use]
pub fn kept_station_rows<'a>(rows: &[DirectoryRow<'a>]) -> Vec<(usize, &'a str)> {
    let mut seen_urls = Vec::new();
    let mut seen_names = Vec::new();
    rows.iter()
        .enumerate()
        .filter_map(|(i, row)| {
            let name = st::trim_whitespace_newlines(row.name?);
            let url = row.url?;
            let kept = !name.is_empty()
                && st::has_prefix(url, "https://")
                && first_time(&mut seen_urls, url)
                && first_time(&mut seen_names, &st::lowercased(name));
            kept.then_some((i, name))
        })
        .collect()
}

/// `RadioBrowser.parseServers(_:)`'s rule over decoded names: the indices of
/// the present, non-empty names not seen before.
///
/// Deterministic; panics: none.
#[must_use]
pub fn unique_server_names(names: &[Option<&str>]) -> Vec<usize> {
    let mut seen = Vec::new();
    names
        .iter()
        .enumerate()
        .filter(|(_, name)| name.is_some_and(|n| !n.is_empty() && first_time(&mut seen, n)))
        .map(|(i, _)| i)
        .collect()
}

/// `RadioBrowser.genreWords(fromTags:)`: the first three non-empty
/// comma-separated tags, trimmed, joined with ` · `.
///
/// Deterministic; panics: none.
#[must_use]
pub fn genre_words(tags: &str) -> String {
    let mut pieces: Vec<&str> = Vec::new();
    let mut start = 0usize;
    let mut at = 0usize;
    for cluster in st::graphemes(tags) {
        if cluster == "," {
            pieces.push(&tags[start..at]);
            start = at + cluster.len();
        }
        at += cluster.len();
    }
    pieces.push(&tags[start..]);
    pieces
        .into_iter()
        .filter(|p| !p.is_empty())
        .map(st::trim_whitespace)
        .filter(|p| !p.is_empty())
        .take(3)
        .collect::<Vec<_>>()
        .join(" \u{B7} ")
}

/// `RadioBrowser.stateName(_:)`'s table: two-letter code and full name.
pub const STATE_NAMES: [(&str, &str); 51] = [
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
];

/// `RadioBrowser.stateName(_:)`: the full name for an uppercased code
/// (compared canonically, so `ıd` is Idaho), `None` otherwise.
///
/// Deterministic; panics: none.
#[must_use]
pub fn state_name(code: &str) -> Option<&'static str> {
    let upper = st::uppercased(code);
    STATE_NAMES
        .iter()
        .find(|(c, _)| st::eq(&upper, c))
        .map(|&(_, name)| name)
}

/// `RadioBrowser.rankedNearest(_:near:)`: [`ranked_stations`] by distance and
/// votes, each ranked station replaced by the first station sharing its URL
/// (the directory's id), as indices into the list.
///
/// Deterministic; panics: none.
#[must_use]
pub fn ranked_nearest(stations: &[RadioStation], urls: &[&str], position: Point) -> Vec<usize> {
    let n = stations.len().min(urls.len());
    ranked_stations(&stations[..n], Some(position))
        .into_iter()
        .map(|i| (0..=i).find(|&j| st::eq(urls[j], urls[i])).unwrap_or(i))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `n` points `step` metres apart from `start`, heading `bearing_deg`
    /// (0 = north, 90 = east), near Madison.
    fn line(start: Point, bearing_deg: f64, n: usize, step: f64) -> Vec<Point> {
        let (s, c) = bearing_deg.to_radians().sin_cos();
        let m_lon = 111_320.0 * (start.0.to_radians()).cos();
        (0..n)
            .map(|i| {
                let d = i as f64 * step;
                (start.0 + d * c / 111_320.0, start.1 + d * s / m_lon)
            })
            .collect()
    }

    fn offset(p: Point, north_m: f64, east_m: f64) -> Point {
        let m_lon = 111_320.0 * (p.0.to_radians()).cos();
        (p.0 + north_m / 111_320.0, p.1 + east_m / m_lon)
    }

    const ROAD: [(&str, &str); 1] = [("highway", "primary")];

    #[test]
    fn only_a_drivable_public_road_carries_a_route_limit() {
        assert!(posted_limit_way_counts(&ROAD));
        assert!(posted_limit_way_counts(&[("highway", "service")]));
        assert!(posted_limit_way_counts(&[
            ("highway", "residential"),
            ("bridge", "yes")
        ]));
        // A garage, its aisle, a driveway, a building, a path, a private road.
        assert!(!posted_limit_way_counts(&[
            ("amenity", "parking"),
            ("maxheight", "1.96")
        ]));
        assert!(!posted_limit_way_counts(&[
            ("highway", "service"),
            ("service", "parking_aisle")
        ]));
        assert!(!posted_limit_way_counts(&[
            ("highway", "service"),
            ("service", "driveway")
        ]));
        assert!(!posted_limit_way_counts(&[
            ("highway", "service"),
            ("parking", "multi-storey")
        ]));
        assert!(!posted_limit_way_counts(&[
            ("highway", "service"),
            ("building", "parking")
        ]));
        assert!(!posted_limit_way_counts(&[("highway", "footway")]));
        assert!(!posted_limit_way_counts(&[
            ("highway", "tertiary"),
            ("access", "private")
        ]));
        assert!(!posted_limit_way_counts(&[]));
    }

    #[test]
    fn a_limit_counts_only_on_a_road_the_route_drives_along() {
        let start = (43.07, -89.40);
        // The route: 2 km north.
        let route = line(start, 0.0, 21, 100.0);
        let road = || ROAD.to_vec();
        // 300 m of the same road, drawn a few metres over: counts.
        let along: Vec<Point> = line(offset(start, 500.0, 6.0), 0.0, 4, 100.0);
        // A road crossing under it at right angles: does not.
        let across = line(offset(start, 1_000.0, -100.0), 90.0, 3, 100.0);
        // One running beside it 60 m east: does not.
        let beside = line(offset(start, 500.0, 60.0), 0.0, 4, 100.0);
        // A garage bar on the route's own line: does not.
        let garage = along.clone();
        // A crossing at 45 degrees: runs with it too little.
        let slant = line(offset(start, 800.0, -150.0), 45.0, 5, 100.0);
        // A 20 m bridge on the route: half its own length is enough.
        let bridge = line(offset(start, 1_500.0, 0.0), 0.0, 3, 10.0);
        let ways: Vec<RestrictedWay> = vec![
            (&along, road()),
            (&across, road()),
            (&beside, road()),
            (
                &garage,
                vec![("highway", "service"), ("service", "parking_aisle")],
            ),
            (&slant, road()),
            (&bridge, road()),
        ];
        assert_eq!(
            limits_on_route(&route, &ways),
            vec![true, false, false, false, false, true]
        );
        // A route too short to judge restricts nothing.
        assert_eq!(limits_on_route(&route[..1], &ways), vec![false; 6]);
    }

    #[test]
    fn a_long_straight_road_counts_where_the_route_drives_part_of_it() {
        let start = (43.07, -89.40);
        // The route: 500 m north, then 1 km east.
        let mut route = line(start, 0.0, 6, 100.0);
        route.extend(
            line(offset(start, 500.0, 0.0), 90.0, 11, 100.0)
                .into_iter()
                .skip(1),
        );
        // A posted road drawn as ONE 1 km segment north from the start: the
        // route drives its first half, where it has no vertex.
        let posted = [start, offset(start, 1_000.0, 0.0)];
        assert_eq!(
            limits_on_route(&route, &[(&posted[..], ROAD.to_vec())]),
            vec![true]
        );
    }

    #[test]
    fn osm_heights_and_weights_read_as_the_app_read_them() {
        let close = |a: Option<f64>, b: f64| a.is_some_and(|a| (a - b).abs() < 1e-9);
        assert!(close(
            clearance_meters("13'6\""),
            (13.0 * 12.0 + 6.0) * 0.0254
        ));
        assert!(close(clearance_meters("4.1 m"), 4.1));
        assert!(close(clearance_meters("3,5 m"), 3.5));
        assert!(close(clearance_meters("13 ft"), 13.0 * 0.3048));
        assert_eq!(clearance_meters("default"), None);
        assert!(close(weight_limit_lbs("5 st"), 10_000.0));
        assert!(close(weight_limit_lbs("7.5"), 7.5 * 2204.62));
        assert!(close(weight_limit_lbs("3500 kg"), 3500.0 * 2.20462));
        assert!(is_high_risk_flood_zone(" ae"));
        assert!(!is_high_risk_flood_zone("X"));
        assert_eq!(
            max_grade_percent(&[Some(100.0), None, Some(50.0)], 10.0),
            None
        );
        assert_eq!(
            max_grade_percent(&[Some(100.0), Some(110.0)], 100.0),
            Some(10.0)
        );
        assert_eq!(max_grade_percent(&[Some(1.0), Some(2.0)], f64::NAN), None);
    }

    #[test]
    fn sensor_replies_parse_and_refuse_what_they_should() {
        let mut data = [0u8; 16];
        data[8..12].copy_from_slice(&241_317u32.to_le_bytes());
        data[12..16].copy_from_slice(&(-250i32).to_le_bytes());
        let reading = parse_tpms_advertisement(Some("TPMS1_ABC"), Some(&data)).expect("reading");
        assert_eq!(reading.position, "1");
        assert_eq!(reading.celsius, -2.5);
        assert!((reading.psi - 35.0).abs() < 0.01);
        assert_eq!(
            parse_tpms_advertisement(Some("TPMS"), Some(&data))
                .expect("reading")
                .position,
            "?"
        );
        assert_eq!(parse_tpms_advertisement(Some("CAR"), Some(&data)), None);
        assert_eq!(
            parse_tpms_advertisement(Some("TPMS1"), Some(&data[..15])),
            None
        );
        assert_eq!(parse_fuel_reply("41 2F 80\r>"), Some(128.0 / 255.0));
        assert_eq!(parse_fuel_reply("412F-0"), Some(0.0));
        assert_eq!(parse_fuel_reply("412F-1"), None);
        assert_eq!(parse_fuel_reply("41 2F"), None);
        assert!(looks_like_obd_adapter("Veepeak OBDCheck"));
        assert!(!looks_like_obd_adapter("Car Stereo"));
        assert_eq!(displayed_psi(35.04), 35.0);
    }

    #[test]
    fn spoken_replies_say_no_before_yes_and_never_guess() {
        assert_eq!(interpret_yes_no("yeah, no"), Some(false));
        assert_eq!(interpret_yes_no("Sure thing"), Some(true));
        assert_eq!(interpret_yes_no("go ahead"), Some(true));
        assert_eq!(interpret_yes_no("noah"), None);
        assert_eq!(interpret_yes_no("don't"), Some(false));
        assert!(wants_weather_radio("NOAA radio"));
        assert_eq!(
            choose("let's go to Taco Bell", &["El Rays", "Taco Bell"]),
            PickOutcome::Picked(1)
        );
        assert_eq!(
            choose("yes", &["El Rays", "Taco Bell"]),
            PickOutcome::Picked(0)
        );
        assert_eq!(
            place_reply("actually Mexican", &["Taco Bell"], &["Italian", "Mexican"]),
            PlaceOutcome::SwitchCuisine(1)
        );
        assert_eq!(
            place_reply("go back", &["Taco Bell"], &["Mexican"]),
            PlaceOutcome::BackToCuisine
        );
    }

    #[test]
    fn stations_file_by_their_narrowest_kind_and_read_their_dial() {
        assert_eq!(kind_for_tags("christian rock"), Some(RadioKind::Christian));
        assert_eq!(kind_for_tags("Classic Rock"), Some(RadioKind::Rock));
        assert_eq!(kind_for_tags(""), None);
        assert_eq!(dial_label("WAPL 105.7").as_deref(), Some("105.7 FM"));
        assert_eq!(dial_label("WTMJ 620").as_deref(), Some("620 AM"));
        assert_eq!(dial_label("88.25").as_deref(), Some("88.2 FM"));
        assert_eq!(dial_label("2024 hits"), None);
        let s = |lat: Option<f64>, bitrate| RadioStation {
            lat,
            lon: lat,
            bitrate,
        };
        let stations = [
            s(None, 320),
            s(Some(1.0), 64),
            s(Some(0.1), 64),
            s(None, 128),
        ];
        assert_eq!(
            ranked_stations(&stations, Some((0.0, 0.0))),
            vec![2, 1, 0, 3]
        );
    }

    #[test]
    fn the_directory_keeps_allowed_mirrors_and_new_stations_only() {
        assert!(is_allowed_mirror("de1.api.radio-browser.info"));
        assert!(is_allowed_mirror("DE.api.radio-browser.info"));
        assert!(!is_allowed_mirror("ru1.api.radio-browser.info"));
        assert!(!is_allowed_mirror("de1a.api.radio-browser.info"));
        assert!(!is_allowed_mirror("all.api.radio-browser.info"));
        let a = DirectoryStation {
            name: "WAPL",
            url: "https://a",
        };
        let b = DirectoryStation {
            name: "wapl",
            url: "https://b",
        };
        assert_eq!(merged_stations(Some(&[a]), Some(&[a, b])), Some(vec![0]));
        assert_eq!(merged_stations(None, None), None);
        assert_eq!(
            genre_words("country, news,,talk,pop"),
            "country \u{B7} news \u{B7} talk"
        );
        assert_eq!(state_name("wi"), Some("Wisconsin"));
        assert_eq!(state_name("\u{131}d"), Some("Idaho"));
        let rows = [
            DirectoryRow {
                name: Some(" WAPL "),
                url: Some("https://a"),
            },
            DirectoryRow {
                name: Some("wapl"),
                url: Some("https://b"),
            },
            DirectoryRow {
                name: Some("KQRS"),
                url: Some("http://c"),
            },
        ];
        assert_eq!(kept_station_rows(&rows), vec![(0, "WAPL")]);
        assert_eq!(
            unique_server_names(&[Some("de1"), Some(""), None, Some("de1"), Some("at1")]),
            vec![0, 4]
        );
    }
}
